/*
 * audit_format.c
 *   CSV / JSON / text formatters for pg_bigeye.
 */
#include "postgres.h"

#include "pg_bigeye.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"

/* ----------------------------------------------------------------
 * Internal helpers
 * ---------------------------------------------------------------- */

/*
 * Append a CSV-quoted string to a StringInfo.
 * All strings are double-quoted; internal double-quotes are doubled.
 */
static void
csv_append_string(StringInfo buf, const char *s)
{
	appendStringInfoChar(buf, '"');
	if (s)
	{
		for (const char *p = s; *p; p++)
		{
			if (*p == '"')
				appendStringInfoChar(buf, '"');
			appendStringInfoChar(buf, *p);
		}
	}
	appendStringInfoChar(buf, '"');
}

/*
 * Append a JSON-escaped string value (with surrounding quotes) to a
 * StringInfo.  Handles control characters and the JSON escape sequences.
 */
static void
json_append_string(StringInfo buf, const char *s)
{
	appendStringInfoChar(buf, '"');
	if (s)
	{
		for (const char *p = s; *p; p++)
		{
			unsigned char c = (unsigned char) *p;
			if (c == '"')
				appendStringInfoString(buf, "\\\"");
			else if (c == '\\')
				appendStringInfoString(buf, "\\\\");
			else if (c == '\n')
				appendStringInfoString(buf, "\\n");
			else if (c == '\r')
				appendStringInfoString(buf, "\\r");
			else if (c == '\t')
				appendStringInfoString(buf, "\\t");
			else if (c < 0x20)
				appendStringInfo(buf, "\\u%04x", c);
			else
				appendStringInfoChar(buf, *p);
		}
	}
	appendStringInfoChar(buf, '"');
}

/*
 * Format a TimestampTz as "YYYY-MM-DD HH:MM:SS.mmm TZ"
 */
static void
format_timestamp(StringInfo buf, TimestampTz ts)
{
	const char *str = timestamptz_to_str(ts);
	appendStringInfoString(buf, str);
}

/* ----------------------------------------------------------------
 * CSV formatter
 * ---------------------------------------------------------------- */
static char *
format_csv(const AuditEntry *e)
{
	StringInfoData buf;

	initStringInfo(&buf);

	/* 1: timestamp */
	appendStringInfoChar(&buf, '"');
	format_timestamp(&buf, e->timestamp);
	appendStringInfoChar(&buf, '"');
	appendStringInfoChar(&buf, ',');

	/* 2: pid */
	appendStringInfo(&buf, "%d,", e->pid);

	/* 3-7: string fields */
	csv_append_string(&buf, e->user_name);
	appendStringInfoChar(&buf, ',');
	csv_append_string(&buf, e->database_name);
	appendStringInfoChar(&buf, ',');
	csv_append_string(&buf, e->client_addr);
	appendStringInfoChar(&buf, ',');

	/* 6: client_port (integer) */
	if (e->client_port > 0)
		appendStringInfo(&buf, "%d", e->client_port);
	appendStringInfoChar(&buf, ',');

	/* 7: application_name */
	csv_append_string(&buf, e->application_name);
	appendStringInfoChar(&buf, ',');

	/* 8-12 */
	csv_append_string(&buf, e->event_type);
	appendStringInfoChar(&buf, ',');
	csv_append_string(&buf, e->command_tag);
	appendStringInfoChar(&buf, ',');
	csv_append_string(&buf, e->object_type);
	appendStringInfoChar(&buf, ',');
	csv_append_string(&buf, e->object_name);
	appendStringInfoChar(&buf, ',');
	csv_append_string(&buf, e->query_text);
	appendStringInfoChar(&buf, ',');

	/* 13: result */
	appendStringInfoString(&buf, e->result_ok ? "\"OK\"" : "\"FAIL\"");
	appendStringInfoChar(&buf, ',');

	/* 14-15: error fields */
	csv_append_string(&buf, e->error_code);
	appendStringInfoChar(&buf, ',');
	csv_append_string(&buf, e->error_message);
	appendStringInfoChar(&buf, ',');

	/* 16: duration_ms */
	if (e->has_duration)
		appendStringInfo(&buf, "%.3f", e->duration_ms);
	appendStringInfoChar(&buf, ',');

	/* 17: rows_affected */
	if (e->has_rows)
		appendStringInfo(&buf, INT64_FORMAT, e->rows_affected);

	appendStringInfoChar(&buf, '\n');

	return buf.data;
}

/* ----------------------------------------------------------------
 * JSON formatter (one JSON object per line)
 * ---------------------------------------------------------------- */
static char *
format_json(const AuditEntry *e)
{
	StringInfoData buf;
	StringInfoData ts_buf;

	initStringInfo(&ts_buf);
	format_timestamp(&ts_buf, e->timestamp);

	initStringInfo(&buf);
	appendStringInfoChar(&buf, '{');

	appendStringInfoString(&buf, "\"timestamp\":");
	json_append_string(&buf, ts_buf.data);
	pfree(ts_buf.data);

	appendStringInfo(&buf, ",\"pid\":%d", e->pid);

	appendStringInfoString(&buf, ",\"user_name\":");
	json_append_string(&buf, e->user_name);

	appendStringInfoString(&buf, ",\"database_name\":");
	json_append_string(&buf, e->database_name);

	appendStringInfoString(&buf, ",\"client_addr\":");
	json_append_string(&buf, e->client_addr);

	if (e->client_port > 0)
		appendStringInfo(&buf, ",\"client_port\":%d", e->client_port);
	else
		appendStringInfoString(&buf, ",\"client_port\":null");

	appendStringInfoString(&buf, ",\"application_name\":");
	json_append_string(&buf, e->application_name);

	appendStringInfoString(&buf, ",\"event_type\":");
	json_append_string(&buf, e->event_type);

	appendStringInfoString(&buf, ",\"command_tag\":");
	json_append_string(&buf, e->command_tag);

	appendStringInfoString(&buf, ",\"object_type\":");
	json_append_string(&buf, e->object_type);

	appendStringInfoString(&buf, ",\"object_name\":");
	json_append_string(&buf, e->object_name);

	appendStringInfoString(&buf, ",\"query_text\":");
	json_append_string(&buf, e->query_text);

	appendStringInfo(&buf, ",\"result\":\"%s\"", e->result_ok ? "OK" : "FAIL");

	appendStringInfoString(&buf, ",\"error_code\":");
	if (e->error_code && e->error_code[0])
		json_append_string(&buf, e->error_code);
	else
		appendStringInfoString(&buf, "null");

	appendStringInfoString(&buf, ",\"error_message\":");
	if (e->error_message && e->error_message[0])
		json_append_string(&buf, e->error_message);
	else
		appendStringInfoString(&buf, "null");

	if (e->has_duration)
		appendStringInfo(&buf, ",\"duration_ms\":%.3f", e->duration_ms);
	else
		appendStringInfoString(&buf, ",\"duration_ms\":null");

	if (e->has_rows)
		appendStringInfo(&buf, ",\"rows_affected\":" INT64_FORMAT, e->rows_affected);
	else
		appendStringInfoString(&buf, ",\"rows_affected\":null");

	appendStringInfoString(&buf, "}\n");

	return buf.data;
}

/* ----------------------------------------------------------------
 * Text formatter
 * ---------------------------------------------------------------- */
static char *
format_text(const AuditEntry *e)
{
	StringInfoData buf;
	StringInfoData ts_buf;

	initStringInfo(&ts_buf);
	format_timestamp(&ts_buf, e->timestamp);

	initStringInfo(&buf);
	appendStringInfo(&buf,
					 "%s [%d] %s@%s %s:%s %s result=%s",
					 ts_buf.data,
					 e->pid,
					 e->user_name ? e->user_name : "-",
					 e->database_name ? e->database_name : "-",
					 e->event_type ? e->event_type : "-",
					 e->command_tag ? e->command_tag : "-",
					 e->query_text && e->query_text[0] ? e->query_text : "(none)",
					 e->result_ok ? "OK" : "FAIL");

	if (e->object_name && e->object_name[0])
		appendStringInfo(&buf, " object=%s", e->object_name);

	if (!e->result_ok && e->error_code && e->error_code[0])
		appendStringInfo(&buf, " sqlstate=%s msg=%s",
						 e->error_code,
						 e->error_message ? e->error_message : "");

	if (e->has_duration)
		appendStringInfo(&buf, " duration=%.3fms", e->duration_ms);

	if (e->has_rows)
		appendStringInfo(&buf, " rows=" INT64_FORMAT, e->rows_affected);

	pfree(ts_buf.data);
	appendStringInfoChar(&buf, '\n');

	return buf.data;
}

/* ----------------------------------------------------------------
 * Public entry point
 * ---------------------------------------------------------------- */

/*
 * Format an AuditEntry into a palloc'd string.
 * format: AUDIT_FORMAT_CSV / AUDIT_FORMAT_JSON / AUDIT_FORMAT_TEXT
 */
char *
audit_format_entry(const AuditEntry *entry, int format)
{
	switch (format)
	{
		case AUDIT_FORMAT_JSON:
			return format_json(entry);
		case AUDIT_FORMAT_TEXT:
			return format_text(entry);
		case AUDIT_FORMAT_CSV:
		default:
			return format_csv(entry);
	}
}
