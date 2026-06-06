/*
 * audit_writer.c
 *   File I/O, rotation, and shared memory management for pg_bigeye.
 *
 * Design:
 *   - Each backend writes directly to the audit log file (no central writer).
 *   - flock(LOCK_EX) serialises concurrent writes.
 *   - A small shared memory struct tracks when the active file was opened,
 *     used for time-based rotation checks.
 *   - Rotation:
 *       fixed-name mode  : rename audit.log → audit.log.TIMESTAMP, open new
 *       pattern mode     : strftime-expand log_filename for the new filename
 */
#include "postgres.h"

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "pg_bigeye.h"
#include "miscadmin.h"

/* Compatibility macros for PG versions that predate these conveniences */
#ifndef AmRegularBackendProcess
#define AmRegularBackendProcess() (MyBackendType == B_BACKEND)
#endif
#ifndef AmWalSenderProcess
#define AmWalSenderProcess() (MyBackendType == B_WAL_SENDER)
#endif
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/timestamp.h"

/* ----------------------------------------------------------------
 * Shared memory
 * ---------------------------------------------------------------- */
typedef struct AuditWriterState
{
	LWLockPadded lock;
	TimestampTz	 file_open_time;		/* when the active file was opened */
} AuditWriterState;

static AuditWriterState *audit_state = NULL;

/* ----------------------------------------------------------------
 * Per-backend state
 * ---------------------------------------------------------------- */
static int	audit_fd = -1;
static char audit_fd_path[MAXPGPATH] = "";

/* ----------------------------------------------------------------
 * Forward declarations
 * ---------------------------------------------------------------- */
static char *compute_active_path(void);
static char *compute_rotated_path(const char *active_path);
static bool	 rotation_needed(void);
static void	 do_rotation(void);
static void	 ensure_fd_open(const char *path);

/* ----------------------------------------------------------------
 * Shared memory callbacks
 * ---------------------------------------------------------------- */

void
audit_writer_shmem_request(void *arg)
{
#if PG_VERSION_NUM >= 190000
	ShmemRequestStruct(.name = "pg_bigeye",
					   .size = sizeof(AuditWriterState),
					   .ptr = (void **) &audit_state,
		);
#else
	RequestAddinShmemSpace(sizeof(AuditWriterState));
#endif
}

void
audit_writer_shmem_init(void *arg)
{
	int			tranche_id;

#if PG_VERSION_NUM < 190000
	bool		found;

	audit_state = ShmemInitStruct("pg_bigeye",
								  sizeof(AuditWriterState), &found);
	if (found)
		return;					/* already initialized by another backend */
	memset(audit_state, 0, sizeof(AuditWriterState));
#else
	Assert(!IsUnderPostmaster);
#endif

#if PG_VERSION_NUM >= 190000
	tranche_id = LWLockNewTrancheId("pg_bigeye");
#else
	tranche_id = LWLockNewTrancheId();
	LWLockRegisterTranche(tranche_id, "pg_bigeye");
#endif
	LWLockInitialize(&audit_state->lock.lock, tranche_id);
	audit_state->file_open_time = GetCurrentTimestamp();
}

/* ----------------------------------------------------------------
 * Path helpers
 * ---------------------------------------------------------------- */

/*
 * Build the absolute path for the log directory.
 * Relative paths are interpreted relative to $PGDATA.
 */
static char *
build_log_dir(void)
{
	if (is_absolute_path(audit_log_directory))
		return pstrdup(audit_log_directory);
	return psprintf("%s/%s", DataDir, audit_log_directory);
}

/*
 * Returns the path of the currently active log file.
 * In fixed-name mode (no '%' in log_filename), this is always the same.
 * In pattern mode the caller uses the shared file_open_time to expand.
 */
static char *
compute_active_path(void)
{
	char   *dir = build_log_dir();

	if (strchr(audit_log_filename, '%') == NULL)
	{
		/* Fixed-name mode */
		return psprintf("%s/%s", dir, audit_log_filename);
	}
	else
	{
		/* Pattern mode: use file_open_time from shared state */
		char	tbuf[MAXPGPATH];
		time_t	t;
		struct tm tm_info;

		LWLockAcquire(&audit_state->lock.lock, LW_SHARED);
		t = timestamptz_to_time_t(audit_state->file_open_time);
		LWLockRelease(&audit_state->lock.lock);

		localtime_r(&t, &tm_info);
		strftime(tbuf, sizeof(tbuf), audit_log_filename, &tm_info);
		return psprintf("%s/%s", dir, tbuf);
	}
}

/*
 * In fixed-name mode, returns the rename target (active + ".TIMESTAMP").
 * In pattern mode, returns the new filename (strftime with current time).
 */
static char *
compute_rotated_path(const char *active_path)
{
	char   *dir = build_log_dir();

	if (strchr(audit_log_filename, '%') == NULL)
	{
		/* Fixed-name: append ".YYYY-MM-DD_HHMMSS" to current active path */
		char		tbuf[32];
		time_t		t = time(NULL);
		struct tm	tm_info;

		localtime_r(&t, &tm_info);
		strftime(tbuf, sizeof(tbuf), "%Y-%m-%d_%H%M%S", &tm_info);
		return psprintf("%s.%s", active_path, tbuf);
	}
	else
	{
		/* Pattern mode: new filename based on current time */
		char		tbuf[MAXPGPATH];
		time_t		t = time(NULL);
		struct tm	tm_info;

		localtime_r(&t, &tm_info);
		strftime(tbuf, sizeof(tbuf), audit_log_filename, &tm_info);
		return psprintf("%s/%s", dir, tbuf);
	}
}

/* ----------------------------------------------------------------
 * Rotation logic
 * ---------------------------------------------------------------- */

static bool
rotation_needed(void)
{
	/* Size-based check */
	if (audit_log_rotation_size > 0 && audit_fd >= 0)
	{
		struct stat st;

		if (fstat(audit_fd, &st) == 0)
		{
			if (st.st_size >= (off_t) audit_log_rotation_size * 1024)
				return true;
		}
	}

	/* Time-based check */
	if (audit_log_rotation_age > 0 && audit_state != NULL)
	{
		TimestampTz	file_open_time;
		long		diff_ms;

		LWLockAcquire(&audit_state->lock.lock, LW_SHARED);
		file_open_time = audit_state->file_open_time;
		LWLockRelease(&audit_state->lock.lock);

		diff_ms = TimestampDifferenceMilliseconds(file_open_time,
												  GetCurrentTimestamp());
		if (diff_ms >= (long) audit_log_rotation_age * 60 * 1000)
			return true;
	}

	return false;
}

/*
 * Perform log rotation while the caller holds flock(LOCK_EX) on audit_fd.
 * After this function returns, audit_fd refers to the new log file.
 */
static void
do_rotation(void)
{
	char *active_path;
	char *new_path;

	if (audit_fd < 0)
		return;

	active_path = compute_active_path();

	if (strchr(audit_log_filename, '%') == NULL)
	{
		/* Fixed-name mode: rename active → active.TIMESTAMP, then open new */
		new_path = compute_rotated_path(active_path);
		if (rename(active_path, new_path) != 0)
		{
			ereport(WARNING,
					(errcode_for_file_access(),
					 errmsg("pg_bigeye: could not rename \"%s\" to \"%s\": %m",
							active_path, new_path)));
			pfree(new_path);
			pfree(active_path);
			return;
		}
		/* New active file has the same fixed name */
		pfree(new_path);
		/* active_path is the path to (re)open */
	}
	else
	{
		/* Pattern mode: new_path is a different expanded name */
		new_path = compute_rotated_path(active_path);
		pfree(active_path);
		active_path = new_path;
	}

	/* Close the old fd (it may now point to the renamed file) */
	close(audit_fd);
	audit_fd = -1;
	audit_fd_path[0] = '\0';

	/* Update shared state with new open time */
	if (audit_state != NULL)
	{
		LWLockAcquire(&audit_state->lock.lock, LW_EXCLUSIVE);
		audit_state->file_open_time = GetCurrentTimestamp();
		LWLockRelease(&audit_state->lock.lock);
	}

	/* Open the new active file */
	ensure_fd_open(active_path);
	pfree(active_path);
}

/* ----------------------------------------------------------------
 * File open helper
 * ---------------------------------------------------------------- */

static void
ensure_log_dir(const char *dir)
{
	struct stat st;

	if (stat(dir, &st) == 0)
		return;					/* already exists */

	if (mkdir(dir, 0700) != 0 && errno != EEXIST)
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("pg_bigeye: could not create directory \"%s\": %m",
						dir)));
}

static void
ensure_fd_open(const char *path)
{
	char *dir;

	if (audit_fd >= 0 && strcmp(audit_fd_path, path) == 0)
		return;					/* already open for this path */

	if (audit_fd >= 0)
	{
		close(audit_fd);
		audit_fd = -1;
		audit_fd_path[0] = '\0';
	}

	dir = build_log_dir();
	ensure_log_dir(dir);
	pfree(dir);

	audit_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
	if (audit_fd < 0)
	{
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("pg_bigeye: could not open log file \"%s\": %m",
						path)));
		return;
	}

	strlcpy(audit_fd_path, path, MAXPGPATH);
}

/* ----------------------------------------------------------------
 * Public write entry point
 * ---------------------------------------------------------------- */

void
audit_write_entry(const AuditEntry *entry)
{
	char *path;
	char *formatted;

	/* Skip non-regular backends and parallel workers */
	if (!AmRegularBackendProcess() && !AmWalSenderProcess())
		return;

	/* Format the entry */
	formatted = audit_format_entry(entry, audit_log_format);
	if (!formatted)
		return;

	/* Get the current active log path */
	path = compute_active_path();

	/*
	 * Open the file if not already open, or if the path has changed (e.g.,
	 * after a rotation by another backend in pattern mode).
	 */
	if (audit_fd < 0 || strcmp(audit_fd_path, path) != 0)
		ensure_fd_open(path);

	pfree(path);

	if (audit_fd < 0)
	{
		pfree(formatted);
		return;
	}

	/* Acquire exclusive file lock for write + potential rotation */
	if (flock(audit_fd, LOCK_EX) != 0)
	{
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("pg_bigeye: flock failed: %m")));
		pfree(formatted);
		return;
	}

	/* Check if rotation is needed while holding the lock */
	if (rotation_needed())
	{
		do_rotation();
		/* After rotation, audit_fd points to the new file (or -1 on error) */
		if (audit_fd < 0)
		{
			pfree(formatted);
			return;
		}
		/* Re-acquire lock on the new fd */
		if (flock(audit_fd, LOCK_EX) != 0)
		{
			ereport(WARNING,
					(errcode_for_file_access(),
					 errmsg("pg_bigeye: flock on new file failed: %m")));
			pfree(formatted);
			return;
		}
	}

	/* Write the formatted entry */
	{
		size_t		len = strlen(formatted);
		ssize_t		written = write(audit_fd, formatted, len);

		if (written != (ssize_t) len)
			ereport(WARNING,
					(errcode_for_file_access(),
					 errmsg("pg_bigeye: write failed: %m")));
	}

	flock(audit_fd, LOCK_UN);
	pfree(formatted);
}
