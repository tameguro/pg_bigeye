/*
 * pg_bigeye.c
 *   Main module: GUC definitions, hook installations, event capture.
 *
 * Hooks used:
 *   ProcessUtility_hook      → DDL and PRIVILEGE events
 *   ExecutorStart_hook       → record DML start time
 *   ExecutorEnd_hook         → emit DML audit entry
 *   ClientAuthentication_hook → AUTH / CONNECT events
 *   emit_log_hook            → ERROR events
 *   on_proc_exit callback    → DISCONNECT event
 */
#include "postgres.h"

#include <sys/file.h>
#include <time.h>
#include <unistd.h>

#include "access/parallel.h"
#include "catalog/objectaccess.h"
#include "executor/executor.h"
#include "fmgr.h"
#include "libpq/auth.h"
#include "libpq/libpq-be.h"
#include "miscadmin.h"
#include "nodes/bitmapset.h"
#include "nodes/parsenodes.h"
#include "parser/parsetree.h"
#include "storage/ipc.h"
#include "storage/shmem.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/elog.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"

#include "pg_bigeye.h"

/* Compatibility macros for PG versions that predate these conveniences */
#ifndef AmRegularBackendProcess
#define AmRegularBackendProcess() (MyBackendType == B_BACKEND)
#endif
#ifndef AmWalSenderProcess
#define AmWalSenderProcess() (MyBackendType == B_WAL_SENDER)
#endif

#if PG_VERSION_NUM >= 190000
PG_MODULE_MAGIC_EXT(
					.name = "pg_bigeye",
					.version = PG_BIGEYE_VERSION
);
#else
PG_MODULE_MAGIC;
#endif

/* ----------------------------------------------------------------
 * GUC variables
 * ---------------------------------------------------------------- */
char	   *audit_log_directory = NULL;
char	   *audit_log_filename = NULL;
int			audit_log_rotation_age = 1440;	/* 1 day in minutes */
int			audit_log_rotation_size = 102400;	/* 100 MB in kB */
int			audit_log_format = AUDIT_FORMAT_CSV;
int			audit_log_statements = AUDIT_STMT_DDL;
int			audit_log_errors = ERROR;
bool		audit_log_auth = true;
bool		audit_log_query_text = true;
int			audit_log_query_max_length = 0;
char	   *audit_exclude_roles = NULL;

/* ----------------------------------------------------------------
 * GUC option arrays
 * ---------------------------------------------------------------- */
static const struct config_enum_entry audit_stmt_options[] = {
	{"none", AUDIT_STMT_NONE, false},
	{"ddl", AUDIT_STMT_DDL, false},
	{"dml", AUDIT_STMT_DML, false},
	{"all", AUDIT_STMT_ALL, false},
	{NULL, 0, false}
};

static const struct config_enum_entry audit_format_options[] = {
	{"csv", AUDIT_FORMAT_CSV, false},
	{"json", AUDIT_FORMAT_JSON, false},
	{"text", AUDIT_FORMAT_TEXT, false},
	{NULL, 0, false}
};

static const struct config_enum_entry audit_errors_options[] = {
	{"none", -1, false},
	{"debug5", DEBUG5, false},
	{"debug4", DEBUG4, false},
	{"debug3", DEBUG3, false},
	{"debug2", DEBUG2, false},
	{"debug1", DEBUG1, false},
	{"info", INFO, false},
	{"notice", NOTICE, false},
	{"warning", WARNING, false},
	{"error", ERROR, false},
	{"fatal", FATAL, false},
	{"panic", PANIC, false},
	{NULL, 0, false}
};

/* ----------------------------------------------------------------
 * Previous hooks (for chaining)
 * ---------------------------------------------------------------- */
static ProcessUtility_hook_type prev_ProcessUtility = NULL;
static ExecutorStart_hook_type prev_ExecutorStart = NULL;
static ExecutorEnd_hook_type prev_ExecutorEnd = NULL;
static ClientAuthentication_hook_type prev_ClientAuthentication = NULL;
static emit_log_hook_type prev_emit_log = NULL;

/* ----------------------------------------------------------------
 * Forward declarations
 * ---------------------------------------------------------------- */
static void bigeye_on_disconnect(int code, Datum arg);

/* ----------------------------------------------------------------
 * Per-backend executor timing state
 * ---------------------------------------------------------------- */
typedef struct
{
	TimestampTz start_time;
	bool		active;
} ExecTimingState;

static ExecTimingState exec_timing = {0, false};

/* ----------------------------------------------------------------
 * Shared memory callbacks (PG19+) / hooks (PG17-18)
 * ---------------------------------------------------------------- */
#if PG_VERSION_NUM >= 190000
static const ShmemCallbacks audit_shmem_callbacks = {
	.request_fn = audit_writer_shmem_request,
	.init_fn	= audit_writer_shmem_init,
};
#else
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

static void
bigeye_shmem_request_compat(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();
	audit_writer_shmem_request(NULL);
}

static void
bigeye_shmem_startup_compat(void)
{
	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();
	audit_writer_shmem_init(NULL);
}
#endif

/* ----------------------------------------------------------------
 * Helper: check whether the current user is in exclude_roles
 * ---------------------------------------------------------------- */
static bool
is_excluded_role(void)
{
	const char *username;
	char	   *rolelist;
	char	   *tok;
	char	   *saveptr;

	if (!audit_exclude_roles || audit_exclude_roles[0] == '\0')
		return false;

	username = GetUserNameFromId(GetUserId(), true);
	if (!username)
		return false;

	rolelist = pstrdup(audit_exclude_roles);
	tok = strtok_r(rolelist, ",", &saveptr);
	while (tok)
	{
		/* trim whitespace */
		while (*tok == ' ')
			tok++;
		{
			char *end = tok + strlen(tok) - 1;
			while (end > tok && *end == ' ')
				*end-- = '\0';
		}
		if (strcmp(tok, username) == 0)
		{
			pfree(rolelist);
			return true;
		}
		tok = strtok_r(NULL, ",", &saveptr);
	}
	pfree(rolelist);
	return false;
}

/* ----------------------------------------------------------------
 * Helper: fill common fields from MyProcPort
 * ---------------------------------------------------------------- */
static void
fill_connection_fields(AuditEntry *entry)
{
	entry->timestamp = GetCurrentTimestamp();
	entry->pid = MyProcPid;

	if (MyProcPort)
	{
		entry->user_name = MyProcPort->user_name ? MyProcPort->user_name : "";
		entry->database_name = MyProcPort->database_name ? MyProcPort->database_name : "";
		entry->client_addr = MyProcPort->remote_host ? MyProcPort->remote_host : "";
		entry->client_port = MyProcPort->remote_port ? atoi(MyProcPort->remote_port) : 0;
	}
	else
	{
		entry->user_name = "";
		entry->database_name = "";
		entry->client_addr = "";
		entry->client_port = 0;
	}

	entry->application_name = application_name ? application_name : "";
	entry->object_type = "";
	entry->object_name = "";
	entry->query_text = "";
	entry->result_ok = true;
	entry->error_code = "";
	entry->error_message = "";
	entry->has_duration = false;
	entry->duration_ms = 0.0;
	entry->has_rows = false;
	entry->rows_affected = 0;
}

/* ----------------------------------------------------------------
 * Helper: truncate query text if log_query_max_length is set
 * ---------------------------------------------------------------- */
static const char *
maybe_truncate_query(const char *query)
{
	if (!audit_log_query_text || !query)
		return "";

	if (audit_log_query_max_length > 0 &&
		(int) strlen(query) > audit_log_query_max_length)
	{
		char *buf = palloc(audit_log_query_max_length + 4);

		memcpy(buf, query, audit_log_query_max_length);
		buf[audit_log_query_max_length] = '.';
		buf[audit_log_query_max_length + 1] = '.';
		buf[audit_log_query_max_length + 2] = '.';
		buf[audit_log_query_max_length + 3] = '\0';
		return buf;
	}
	return query;
}

/* ----------------------------------------------------------------
 * Helper: get object type string from ObjectType enum
 * ---------------------------------------------------------------- */
static const char *
object_type_str(ObjectType objtype)
{
	switch (objtype)
	{
		case OBJECT_TABLE:
			return "TABLE";
		case OBJECT_INDEX:
			return "INDEX";
		case OBJECT_VIEW:
			return "VIEW";
		case OBJECT_MATVIEW:
			return "MATERIALIZED VIEW";
		case OBJECT_SEQUENCE:
			return "SEQUENCE";
		case OBJECT_SCHEMA:
			return "SCHEMA";
		case OBJECT_FUNCTION:
			return "FUNCTION";
		case OBJECT_PROCEDURE:
			return "PROCEDURE";
		case OBJECT_TYPE:
			return "TYPE";
		case OBJECT_ROLE:
			return "ROLE";
		case OBJECT_DATABASE:
			return "DATABASE";
		case OBJECT_TABLESPACE:
			return "TABLESPACE";
		default:
			return "OBJECT";
	}
}

/* ----------------------------------------------------------------
 * Helper: extract object type and name from a utility statement
 * ---------------------------------------------------------------- */
static void
extract_ddl_object(Node *utilityStmt, const char **obj_type, const char **obj_name)
{
	*obj_type = "";
	*obj_name = "";

	if (utilityStmt == NULL)
		return;

	if (IsA(utilityStmt, CreateStmt))
	{
		CreateStmt *stmt = (CreateStmt *) utilityStmt;

		*obj_type = "TABLE";
		if (stmt->relation)
			*obj_name = stmt->relation->relname;
	}
	else if (IsA(utilityStmt, AlterTableStmt))
	{
		AlterTableStmt *stmt = (AlterTableStmt *) utilityStmt;

		*obj_type = "TABLE";
		if (stmt->relation)
			*obj_name = stmt->relation->relname;
	}
	else if (IsA(utilityStmt, DropStmt))
	{
		DropStmt   *stmt = (DropStmt *) utilityStmt;

		*obj_type = object_type_str(stmt->removeType);
		/* First object name (simplified: single-name extraction) */
		if (stmt->objects != NIL)
		{
			Node	   *first = linitial(stmt->objects);

			if (IsA(first, String))
				*obj_name = strVal(first);
			else if (IsA(first, List))
			{
				/* Qualified name: take the last element */
				List	   *namelist = (List *) first;
				Node	   *last = llast(namelist);

				if (IsA(last, String))
					*obj_name = strVal(last);
			}
		}
	}
	else if (IsA(utilityStmt, IndexStmt))
	{
		IndexStmt  *stmt = (IndexStmt *) utilityStmt;

		*obj_type = "INDEX";
		*obj_name = stmt->idxname ? stmt->idxname : "";
	}
	else if (IsA(utilityStmt, ViewStmt))
	{
		ViewStmt   *stmt = (ViewStmt *) utilityStmt;

		*obj_type = "VIEW";
		if (stmt->view)
			*obj_name = stmt->view->relname;
	}
	else if (IsA(utilityStmt, CreateSchemaStmt))
	{
		CreateSchemaStmt *stmt = (CreateSchemaStmt *) utilityStmt;

		*obj_type = "SCHEMA";
		*obj_name = stmt->schemaname ? stmt->schemaname : "";
	}
	else if (IsA(utilityStmt, CreateSeqStmt))
	{
		CreateSeqStmt *stmt = (CreateSeqStmt *) utilityStmt;

		*obj_type = "SEQUENCE";
		if (stmt->sequence)
			*obj_name = stmt->sequence->relname;
	}
	else if (IsA(utilityStmt, TruncateStmt))
	{
		TruncateStmt *stmt = (TruncateStmt *) utilityStmt;

		*obj_type = "TABLE";
		if (stmt->relations != NIL)
		{
			RangeVar   *rv = linitial_node(RangeVar, stmt->relations);

			*obj_name = rv->relname;
		}
	}
	else if (IsA(utilityStmt, CreateTableAsStmt))
	{
		CreateTableAsStmt *stmt = (CreateTableAsStmt *) utilityStmt;

		*obj_type = stmt->objtype == OBJECT_MATVIEW ? "MATERIALIZED VIEW" : "TABLE";
		if (stmt->into && stmt->into->rel)
			*obj_name = stmt->into->rel->relname;
	}
	else if (IsA(utilityStmt, RenameStmt))
	{
		RenameStmt *stmt = (RenameStmt *) utilityStmt;

		*obj_type = object_type_str(stmt->renameType);
		*obj_name = stmt->newname ? stmt->newname : "";
	}
	else if (IsA(utilityStmt, GrantStmt))
	{
		GrantStmt  *stmt = (GrantStmt *) utilityStmt;

		*obj_type = object_type_str(stmt->objtype);
	}
}

/* ----------------------------------------------------------------
 * Helper: is this a PRIVILEGE statement (GRANT/REVOKE/SET ROLE)?
 * ---------------------------------------------------------------- */
static bool
is_privilege_stmt(Node *utilityStmt, const char **obj_type_out)
{
	if (utilityStmt == NULL)
		return false;

	if (IsA(utilityStmt, GrantStmt))
	{
		GrantStmt  *stmt = (GrantStmt *) utilityStmt;

		if (obj_type_out)
			*obj_type_out = object_type_str(stmt->objtype);
		return true;
	}

	if (IsA(utilityStmt, GrantRoleStmt))
	{
		if (obj_type_out)
			*obj_type_out = "ROLE";
		return true;
	}

	if (IsA(utilityStmt, VariableSetStmt))
	{
		VariableSetStmt *stmt = (VariableSetStmt *) utilityStmt;

		if (strcmp(stmt->name, "role") == 0 ||
			strcmp(stmt->name, "session_authorization") == 0)
		{
			if (obj_type_out)
				*obj_type_out = "";
			return true;
		}
	}

	return false;
}

/* ----------------------------------------------------------------
 * Helper: get target relation name for DML from QueryDesc
 * ---------------------------------------------------------------- */
static void
get_dml_object(QueryDesc *queryDesc, const char **obj_type, const char **obj_name)
{
	PlannedStmt *pstmt;

	*obj_type = "";
	*obj_name = "";

	if (!queryDesc || !queryDesc->plannedstmt)
		return;

	pstmt = queryDesc->plannedstmt;

	if (pstmt->commandType == CMD_INSERT ||
		pstmt->commandType == CMD_UPDATE ||
		pstmt->commandType == CMD_DELETE ||
		pstmt->commandType == CMD_MERGE)
	{
		{
#if PG_VERSION_NUM >= 190000
			int			rtindex = bms_next_member(pstmt->resultRelationRelids, -1);
#else
			int			rtindex = (pstmt->resultRelations != NIL) ?
								  linitial_int(pstmt->resultRelations) : -1;
#endif
			RangeTblEntry *rte;

			if (rtindex > 0 && rtindex <= list_length(pstmt->rtable))
			{
				rte = rt_fetch((Index) rtindex, pstmt->rtable);
				if (rte->rtekind == RTE_RELATION && OidIsValid(rte->relid))
				{
					char	   *relname = get_rel_name(rte->relid);
					Oid			nspoid = get_rel_namespace(rte->relid);
					char	   *nspname = get_namespace_name(nspoid);

					if (relname)
					{
						*obj_type = "TABLE";
						if (nspname)
							*obj_name = psprintf("%s.%s", nspname, relname);
						else
							*obj_name = relname;
					}
				}
			}
		}
	}
}

/* ----------------------------------------------------------------
 * Hook: ProcessUtility — DDL and PRIVILEGE
 * ---------------------------------------------------------------- */
static void
bigeye_ProcessUtility(PlannedStmt *pstmt,
						  const char *queryString,
						  bool readOnlyTree,
						  ProcessUtilityContext context,
						  ParamListInfo params,
						  QueryEnvironment *queryEnv,
						  DestReceiver *dest,
						  QueryCompletion *qc)
{
	bool		is_priv;
	const char *priv_obj_type = "";
	bool		should_log = false;
	AuditEntry	entry;
	TimestampTz start_time;
	bool		error_occurred = false;
	ErrorData  *edata = NULL;

	/*
	 * Determine event category before execution so we know whether to log.
	 */
	is_priv = is_privilege_stmt(pstmt->utilityStmt, &priv_obj_type);

	if (is_priv)
	{
		/* PRIVILEGE: always log (regardless of log_statements) */
		should_log = true;
	}
	else
	{
		/* DDL: log when log_statements covers DDL */
		should_log = (audit_log_statements == AUDIT_STMT_DDL ||
					  audit_log_statements == AUDIT_STMT_ALL);
	}

	if (!should_log || is_excluded_role())
	{
		/* Just pass through */
		if (prev_ProcessUtility)
			prev_ProcessUtility(pstmt, queryString, readOnlyTree,
								context, params, queryEnv, dest, qc);
		else
			standard_ProcessUtility(pstmt, queryString, readOnlyTree,
									context, params, queryEnv, dest, qc);
		return;
	}

	start_time = GetCurrentTimestamp();

	/* Execute the statement, catching errors */
	PG_TRY();
	{
		if (prev_ProcessUtility)
			prev_ProcessUtility(pstmt, queryString, readOnlyTree,
								context, params, queryEnv, dest, qc);
		else
			standard_ProcessUtility(pstmt, queryString, readOnlyTree,
									context, params, queryEnv, dest, qc);
	}
	PG_CATCH();
	{
		edata = CopyErrorData();
		error_occurred = true;
		FlushErrorState();
	}
	PG_END_TRY();

	/* Build and emit the audit entry */
	fill_connection_fields(&entry);
	entry.timestamp = start_time;

	if (is_priv)
	{
		entry.event_type = "PRIVILEGE";
		entry.command_tag = GetCommandTagName(CreateCommandTag(pstmt->utilityStmt));
		entry.object_type = priv_obj_type;
		entry.object_name = "";
	}
	else
	{
		const char *obj_type;
		const char *obj_name;

		entry.event_type = "DDL";
		entry.command_tag = GetCommandTagName(CreateCommandTag(pstmt->utilityStmt));
		extract_ddl_object(pstmt->utilityStmt, &obj_type, &obj_name);
		entry.object_type = obj_type;
		entry.object_name = obj_name ? obj_name : "";
	}

	entry.query_text = maybe_truncate_query(queryString);
	entry.has_duration = true;
	entry.duration_ms = (double) TimestampDifferenceMilliseconds(start_time,
																  GetCurrentTimestamp());

	if (error_occurred && edata)
	{
		char	   *sqlstate = unpack_sql_state(edata->sqlerrcode);

		entry.result_ok = false;
		entry.error_code = pstrdup(sqlstate);
		entry.error_message = pstrdup(edata->message ? edata->message : "");
		/* Do NOT FreeErrorData here: edata is passed to ReThrowError below */
	}

	audit_write_entry(&entry);

	/*
	 * Re-throw the original error.  We must use ReThrowError(edata) rather
	 * than PG_RE_THROW(), because FlushErrorState() above reset
	 * errordata_stack_depth to -1.  A bare PG_RE_THROW() would longjmp to
	 * the outer handler which then calls EmitErrorReport() and hits
	 * CHECK_STACK_DEPTH() with depth == -1, producing "errstart was not
	 * called".  ReThrowError() pushes edata back onto the stack first.
	 */
	if (error_occurred)
	{
		if (edata)
			ReThrowError(edata);	/* re-pushes error on stack, then longjmps */
		PG_RE_THROW();				/* fallback: should not be reached */
	}
}

/* ----------------------------------------------------------------
 * Hook: ExecutorStart — record start time
 * ---------------------------------------------------------------- */
static void
bigeye_ExecutorStart(QueryDesc *queryDesc, int eflags)
{
	if (prev_ExecutorStart)
		prev_ExecutorStart(queryDesc, eflags);
	else
		standard_ExecutorStart(queryDesc, eflags);

	/* Record start time for DML timing */
	if (queryDesc->operation != CMD_UTILITY)
	{
		exec_timing.start_time = GetCurrentTimestamp();
		exec_timing.active = true;
	}
}

/* ----------------------------------------------------------------
 * Hook: ExecutorEnd — emit DML audit entry
 * ---------------------------------------------------------------- */
static void
bigeye_ExecutorEnd(QueryDesc *queryDesc)
{
	bool		should_log = false;
	AuditEntry	entry;
	const char *event_type;
	const char *cmd_tag;

	switch (queryDesc->operation)
	{
		case CMD_SELECT:
			event_type = "DML";
			cmd_tag = "SELECT";
			should_log = (audit_log_statements == AUDIT_STMT_DML ||
						  audit_log_statements == AUDIT_STMT_ALL);
			break;
		case CMD_INSERT:
			event_type = "DML";
			cmd_tag = "INSERT";
			should_log = (audit_log_statements == AUDIT_STMT_DML ||
						  audit_log_statements == AUDIT_STMT_ALL);
			break;
		case CMD_UPDATE:
			event_type = "DML";
			cmd_tag = "UPDATE";
			should_log = (audit_log_statements == AUDIT_STMT_DML ||
						  audit_log_statements == AUDIT_STMT_ALL);
			break;
		case CMD_DELETE:
			event_type = "DML";
			cmd_tag = "DELETE";
			should_log = (audit_log_statements == AUDIT_STMT_DML ||
						  audit_log_statements == AUDIT_STMT_ALL);
			break;
		case CMD_MERGE:
			event_type = "DML";
			cmd_tag = "MERGE";
			should_log = (audit_log_statements == AUDIT_STMT_DML ||
						  audit_log_statements == AUDIT_STMT_ALL);
			break;
		default:
			should_log = false;
			event_type = "DML";
			cmd_tag = "";
			break;
	}

	/*
	 * Capture rows_affected and sourceText BEFORE calling standard_ExecutorEnd,
	 * because standard_ExecutorEnd frees queryDesc->estate (sets it to NULL).
	 */
	{
		uint64		rows_pre = 0;
		bool		has_rows_pre = false;
		const char *source_text = queryDesc->sourceText;
		CmdType		op = queryDesc->operation;
		TimestampTz	end_time;
		const char *obj_type_pre = "";
		const char *obj_name_pre = "";

		if (op != CMD_SELECT && queryDesc->estate)
		{
			has_rows_pre = true;
			rows_pre = queryDesc->estate->es_total_processed;
		}

		get_dml_object(queryDesc, &obj_type_pre, &obj_name_pre);
		end_time = GetCurrentTimestamp();

		/* Call the standard/previous hook — frees queryDesc->estate */
		if (prev_ExecutorEnd)
			prev_ExecutorEnd(queryDesc);
		else
			standard_ExecutorEnd(queryDesc);

		if (!should_log || is_excluded_role() || IsParallelWorker())
		{
			exec_timing.active = false;
			return;
		}

		/* Build entry */
		fill_connection_fields(&entry);

		if (exec_timing.active)
		{
			entry.timestamp = exec_timing.start_time;
			entry.has_duration = true;
			entry.duration_ms = (double) TimestampDifferenceMilliseconds(
														exec_timing.start_time,
														end_time);
			exec_timing.active = false;
		}
		else
		{
			entry.has_duration = false;
		}

		entry.event_type = event_type;
		entry.command_tag = cmd_tag;
		entry.object_type = obj_type_pre;
		entry.object_name = obj_name_pre;
		entry.query_text = maybe_truncate_query(source_text);
		entry.result_ok = true;

		if (has_rows_pre)
		{
			entry.has_rows = true;
			entry.rows_affected = (int64) rows_pre;
		}

		audit_write_entry(&entry);
	}
}

/* ----------------------------------------------------------------
 * Hook: ClientAuthentication — AUTH and CONNECT
 * ---------------------------------------------------------------- */
static void
bigeye_ClientAuthentication(Port *port, int status)
{
	AuditEntry	entry;

	/* Call previous hook first */
	if (prev_ClientAuthentication)
		prev_ClientAuthentication(port, status);

	if (!audit_log_auth)
		return;

	/* AUTH entry */
	memset(&entry, 0, sizeof(entry));
	entry.timestamp = GetCurrentTimestamp();
	entry.pid = MyProcPid;
	entry.user_name = port->user_name ? port->user_name : "";
	entry.database_name = port->database_name ? port->database_name : "";
	entry.client_addr = port->remote_host ? port->remote_host : "";
	entry.client_port = port->remote_port ? atoi(port->remote_port) : 0;
	entry.application_name = application_name ? application_name : "";
	entry.event_type = "AUTH";
	entry.command_tag = "";
	entry.object_type = "";
	entry.object_name = "";
	entry.query_text = "";
	entry.has_duration = false;
	entry.has_rows = false;
	entry.error_code = "";
	entry.error_message = "";

	if (status == STATUS_OK)
	{
		entry.result_ok = true;
	}
	else
	{
		entry.result_ok = false;
		entry.error_code = "28P01";
		entry.error_message = "authentication failed";
	}

	audit_write_entry(&entry);

	/* Emit CONNECT entry on success, and register DISCONNECT callback */
	if (status == STATUS_OK)
	{
		entry.event_type = "CONNECT";
		entry.result_ok = true;
		entry.error_code = "";
		entry.error_message = "";
		audit_write_entry(&entry);

		/*
		 * Register the disconnect callback in THIS backend.
		 * _PG_init() runs in the postmaster; on_exit_reset() clears that
		 * list before each backend starts, so we must re-register here.
		 */
		if (audit_log_auth)
			on_proc_exit(bigeye_on_disconnect, (Datum) 0);
	}
}

/* ----------------------------------------------------------------
 * on_proc_exit callback — DISCONNECT
 * ---------------------------------------------------------------- */
static void
bigeye_on_disconnect(int code, Datum arg)
{
	AuditEntry	entry;

	if (!audit_log_auth)
		return;

	if (!MyProcPort)
		return;

	memset(&entry, 0, sizeof(entry));
	entry.timestamp = GetCurrentTimestamp();
	entry.pid = MyProcPid;
	entry.user_name = MyProcPort->user_name ? MyProcPort->user_name : "";
	entry.database_name = MyProcPort->database_name ? MyProcPort->database_name : "";
	entry.client_addr = MyProcPort->remote_host ? MyProcPort->remote_host : "";
	entry.client_port = MyProcPort->remote_port ? atoi(MyProcPort->remote_port) : 0;
	entry.application_name = application_name ? application_name : "";
	entry.event_type = "DISCONNECT";
	entry.command_tag = "";
	entry.object_type = "";
	entry.object_name = "";
	entry.query_text = "";
	entry.result_ok = true;
	entry.error_code = "";
	entry.error_message = "";

	/* Session duration in duration_ms */
	entry.has_duration = true;
	entry.duration_ms = (double) TimestampDifferenceMilliseconds(MyStartTimestamp,
																  GetCurrentTimestamp());
	entry.has_rows = false;

	audit_write_entry(&entry);
}

/* ----------------------------------------------------------------
 * Hook: emit_log — ERROR events
 * ---------------------------------------------------------------- */
static void
bigeye_emit_log(ErrorData *edata)
{
	AuditEntry	entry;

	/* Call previous hook */
	if (prev_emit_log)
		prev_emit_log(edata);

	/* Check configured minimum severity (-1 means disabled) */
	if (audit_log_errors < 0 || edata->elevel < audit_log_errors)
		return;

	/* Only for regular backends */
	if (!AmRegularBackendProcess())
		return;

	if (is_excluded_role())
		return;

	fill_connection_fields(&entry);
	entry.event_type = "ERROR";
	entry.command_tag = "";
	entry.object_type = "";
	entry.object_name = "";
	entry.query_text = maybe_truncate_query(edata->message);
	entry.result_ok = false;

	{
		char *sqlstate = unpack_sql_state(edata->sqlerrcode);

		entry.error_code = pstrdup(sqlstate);
	}
	entry.error_message = pstrdup(edata->message ? edata->message : "");
	entry.has_duration = false;
	entry.has_rows = false;

	audit_write_entry(&entry);
}

/* ----------------------------------------------------------------
 * Module load / unload
 * ---------------------------------------------------------------- */

void _PG_init(void);
void _PG_fini(void);

void
_PG_init(void)
{
	if (!process_shared_preload_libraries_in_progress)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("pg_bigeye must be loaded via shared_preload_libraries")));

	/* ---- GUC definitions ---- */

	DefineCustomStringVariable("pg_bigeye.log_directory",
							   "Directory for audit log files.",
							   NULL,
							   &audit_log_directory,
							   "pg_audit_log",
							   PGC_SIGHUP,
							   GUC_SUPERUSER_ONLY,
							   NULL, NULL, NULL);

	DefineCustomStringVariable("pg_bigeye.log_filename",
							   "Audit log file name (fixed name or strftime pattern).",
							   NULL,
							   &audit_log_filename,
							   "audit.log",
							   PGC_SIGHUP,
							   GUC_SUPERUSER_ONLY,
							   NULL, NULL, NULL);

	DefineCustomIntVariable("pg_bigeye.log_rotation_age",
							"Automatic log file rotation after N minutes (0 = disable).",
							NULL,
							&audit_log_rotation_age,
							1440,
							0, INT_MAX / 60,
							PGC_SIGHUP,
							GUC_UNIT_MIN,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pg_bigeye.log_rotation_size",
							"Automatic log file rotation after N kilobytes (0 = disable).",
							NULL,
							&audit_log_rotation_size,
							102400,
							0, INT_MAX / 1024,
							PGC_SIGHUP,
							GUC_UNIT_KB,
							NULL, NULL, NULL);

	DefineCustomEnumVariable("pg_bigeye.log_format",
							 "Audit log output format.",
							 NULL,
							 &audit_log_format,
							 AUDIT_FORMAT_CSV,
							 audit_format_options,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("pg_bigeye.log_statements",
							 "Which statement types to audit.",
							 NULL,
							 &audit_log_statements,
							 AUDIT_STMT_DDL,
							 audit_stmt_options,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("pg_bigeye.log_errors",
							 "Minimum error severity to log (none = disable).",
							 NULL,
							 &audit_log_errors,
							 ERROR,
							 audit_errors_options,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_bigeye.log_auth",
							 "Log authentication, connect and disconnect events.",
							 NULL,
							 &audit_log_auth,
							 true,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomBoolVariable("pg_bigeye.log_query_text",
							 "Include SQL query text in audit log entries.",
							 NULL,
							 &audit_log_query_text,
							 true,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pg_bigeye.log_query_max_length",
							"Maximum length of query_text (0 = unlimited).",
							NULL,
							&audit_log_query_max_length,
							0,
							0, INT_MAX,
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomStringVariable("pg_bigeye.exclude_roles",
							   "Comma-separated list of roles to exclude from auditing.",
							   NULL,
							   &audit_exclude_roles,
							   "",
							   PGC_SIGHUP,
							   GUC_SUPERUSER_ONLY,
							   NULL, NULL, NULL);

	MarkGUCPrefixReserved("pg_bigeye");

	/* ---- Shared memory callbacks ---- */
#if PG_VERSION_NUM >= 190000
	RegisterShmemCallbacks(&audit_shmem_callbacks);
#else
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = bigeye_shmem_request_compat;
	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = bigeye_shmem_startup_compat;
#endif

	/* ---- Install hooks ---- */
	prev_ProcessUtility = ProcessUtility_hook;
	ProcessUtility_hook = bigeye_ProcessUtility;

	prev_ExecutorStart = ExecutorStart_hook;
	ExecutorStart_hook = bigeye_ExecutorStart;

	prev_ExecutorEnd = ExecutorEnd_hook;
	ExecutorEnd_hook = bigeye_ExecutorEnd;

	prev_ClientAuthentication = ClientAuthentication_hook;
	ClientAuthentication_hook = bigeye_ClientAuthentication;

	prev_emit_log = emit_log_hook;
	emit_log_hook = bigeye_emit_log;

	/* Disconnect callback is registered per-backend in ClientAuthentication_hook */
}

void
_PG_fini(void)
{
	/* Restore hooks */
	ProcessUtility_hook = prev_ProcessUtility;
	ExecutorStart_hook = prev_ExecutorStart;
	ExecutorEnd_hook = prev_ExecutorEnd;
	ClientAuthentication_hook = prev_ClientAuthentication;
	emit_log_hook = prev_emit_log;

#if PG_VERSION_NUM < 190000
	if (shmem_request_hook == bigeye_shmem_request_compat)
		shmem_request_hook = prev_shmem_request_hook;
	if (shmem_startup_hook == bigeye_shmem_startup_compat)
		shmem_startup_hook = prev_shmem_startup_hook;
#endif
}
