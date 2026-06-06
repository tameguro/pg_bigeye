#ifndef PG_BIGEYE_H
#define PG_BIGEYE_H

#define PG_BIGEYE_VERSION "0.1.0"

#define PG_BIGEYE_VERSION "0.1.0"

#include "postgres.h"
#include "datatype/timestamp.h"

/* ----------------------------------------------------------------
 * Log statement level constants (log_statements GUC)
 * ---------------------------------------------------------------- */
#define AUDIT_STMT_NONE  0
#define AUDIT_STMT_DDL   1
#define AUDIT_STMT_DML   2
#define AUDIT_STMT_ALL   3

/* ----------------------------------------------------------------
 * Log format constants (log_format GUC)
 * ---------------------------------------------------------------- */
#define AUDIT_FORMAT_CSV  0
#define AUDIT_FORMAT_JSON 1
#define AUDIT_FORMAT_TEXT 2

/* ----------------------------------------------------------------
 * AuditEntry: one audit log record
 * ---------------------------------------------------------------- */
typedef struct AuditEntry
{
	TimestampTz timestamp;
	int			pid;
	const char *user_name;
	const char *database_name;
	const char *client_addr;
	int			client_port;
	const char *application_name;

	/* event classification */
	const char *event_type;		/* DDL / DML / PRIVILEGE / AUTH / CONNECT / DISCONNECT / ERROR */
	const char *command_tag;
	const char *object_type;	/* empty when not applicable */
	const char *object_name;	/* empty when not applicable */

	/* query text (may be truncated) */
	const char *query_text;

	/* result */
	bool		result_ok;
	const char *error_code;		/* SQLSTATE string, empty on success */
	const char *error_message;	/* empty on success */

	/* metrics (set has_* to false when not applicable) */
	bool		has_duration;
	double		duration_ms;

	bool		has_rows;
	int64		rows_affected;
} AuditEntry;

/* ----------------------------------------------------------------
 * GUC variables (defined in pg_bigeye.c, read by audit_writer.c)
 * ---------------------------------------------------------------- */
extern char *audit_log_directory;
extern char *audit_log_filename;
extern int	 audit_log_rotation_age;	/* minutes */
extern int	 audit_log_rotation_size;	/* kB */
extern int	 audit_log_format;
extern int	 audit_log_statements;
extern int	 audit_log_errors;
extern bool	 audit_log_auth;
extern bool	 audit_log_query_text;
extern int	 audit_log_query_max_length;
extern char *audit_exclude_roles;

/* ----------------------------------------------------------------
 * audit_writer API (audit_writer.c)
 * ---------------------------------------------------------------- */
extern void audit_writer_shmem_request(void *arg);
extern void audit_writer_shmem_init(void *arg);
extern void audit_write_entry(const AuditEntry *entry);

/* ----------------------------------------------------------------
 * audit_format API (audit_format.c)
 * ---------------------------------------------------------------- */
extern char *audit_format_entry(const AuditEntry *entry, int format);

#endif							/* PG_BIGEYE_H */
