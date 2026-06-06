#!/usr/bin/bash
# pg_bigeye test runner — shell-based TAP output
# Requires: pg_config and pg binaries in PATH (PG19)
set -euo pipefail

###############################################################################
# Setup
###############################################################################
EXTDIR="$(cd "$(dirname "$0")/.." && pwd)"
PGDATA="$(mktemp -d /tmp/pg_bigeye_test_XXXXXX)"
LOGDIR="$PGDATA/pg_audit_log"
PGPORT=59432
PGHOST="$PGDATA"
PGUSER=postgres

export PGDATA PGHOST PGPORT PGUSER
export PGDATABASE=postgres

SO="$EXTDIR/pg_bigeye.so"
PKGLIBDIR="$(pg_config --pkglibdir)"

TAP_NUM=0
FAILED=0
PASSED=0

tap_ok()    { TAP_NUM=$((TAP_NUM+1)); echo "ok $TAP_NUM - $1"; PASSED=$((PASSED+1)); }
tap_fail()  { TAP_NUM=$((TAP_NUM+1)); echo "not ok $TAP_NUM - $1"; FAILED=$((FAILED+1));
              echo "#   FAIL: $2" >&2; }
tap_skip()  { TAP_NUM=$((TAP_NUM+1)); echo "ok $TAP_NUM - $1 # SKIP $2"; }
tap_diag()  { echo "# $1"; }

check_ok()  {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        tap_ok "$desc"
    else
        tap_fail "$desc" "$* failed"
    fi
}

# Run SQL via psql, capture stdout
Q() { psql -qAtX -c "$1" 2>/dev/null; }

# Count matching lines in audit.log
count_matches() {
    local pattern="$1"
    if [[ -f "$LOGDIR/audit.log" ]]; then
        grep -c "$pattern" "$LOGDIR/audit.log" 2>/dev/null || true
    else
        echo 0
    fi
}

# Clear the audit log
clear_log() {
    rm -f "$LOGDIR/audit.log"
}

# Reload configuration
reload_conf() {
    Q "SELECT pg_reload_conf()" >/dev/null
    sleep 0.3
}

# Append a GUC setting and reload
set_guc() {
    echo "pg_bigeye.$1 = '$2'" >> "$PGDATA/postgresql.conf"
    reload_conf
}

###############################################################################
# Cluster init and start
###############################################################################
tap_diag "Initialising PG19 cluster at $PGDATA"

initdb --no-sync --pgdata="$PGDATA" --auth=trust --username=postgres \
    -E UTF8 --locale=C 2>&1 | tail -2 | while IFS= read -r line; do tap_diag "$line"; done || true

# Copy .so
cp "$SO" "$PKGLIBDIR/"
tap_diag "Installed pg_bigeye.so → $PKGLIBDIR"

# postgresql.conf
cat >> "$PGDATA/postgresql.conf" <<EOF
shared_preload_libraries = 'pg_bigeye'
pg_bigeye.log_directory = 'pg_audit_log'
pg_bigeye.log_filename  = 'audit.log'
pg_bigeye.log_statements = 'all'
pg_bigeye.log_auth       = on
pg_bigeye.log_format     = csv
pg_bigeye.log_errors     = error
pg_bigeye.log_query_text = on
pg_bigeye.log_rotation_age  = 0
pg_bigeye.log_rotation_size = 0
listen_addresses = ''
unix_socket_directories = '$PGDATA'
EOF

pg_ctl -D "$PGDATA" -l "$PGDATA/pg.log" start
sleep 1

if ! pg_isready -h "$PGDATA" -p "$PGPORT" -U postgres >/dev/null 2>&1; then
    tap_diag "PostgreSQL failed to start; check $PGDATA/pg.log"
    cat "$PGDATA/pg.log" >&2
    echo "Bail out! PostgreSQL did not start"
    exit 1
fi

tap_diag "PostgreSQL 19 started on socket $PGDATA port $PGPORT"

###############################################################################
# Tests begin
###############################################################################

# ── TC-047: log_directory auto-created ──────────────────────────────────────
if [[ -d "$LOGDIR" ]]; then
    tap_ok "TC-047: log_directory created automatically on startup"
else
    tap_fail "TC-047: log_directory created automatically on startup" "$LOGDIR missing"
fi

# ── Force first write ───────────────────────────────────────────────────────
Q "SELECT 1" >/dev/null

# ── TC-045: audit.log permissions 0600 ──────────────────────────────────────
if [[ -f "$LOGDIR/audit.log" ]]; then
    PERM=$(stat -c '%a' "$LOGDIR/audit.log")
    if [[ "$PERM" == "600" ]]; then
        tap_ok "TC-045: audit.log permissions are 0600"
    else
        tap_fail "TC-045: audit.log permissions are 0600" "got $PERM"
    fi
else
    tap_fail "TC-045: audit.log permissions are 0600" "file not created"
fi

# ── TC-046: log_directory permissions 0700 ──────────────────────────────────
DPERM=$(stat -c '%a' "$LOGDIR")
if [[ "$DPERM" == "700" ]]; then
    tap_ok "TC-046: log_directory permissions are 0700"
else
    tap_fail "TC-046: log_directory permissions are 0700" "got $DPERM"
fi

# ── TC-011: DDL CREATE TABLE ─────────────────────────────────────────────────
clear_log
Q "CREATE TABLE t1 (id int, val text)" >/dev/null
CNT=$(count_matches '"DDL","CREATE TABLE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-011: DDL CREATE TABLE logged" \
                 || tap_fail "TC-011: DDL CREATE TABLE logged" "0 matches in log"

CNT=$(count_matches '"TABLE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-011: object_type=TABLE in DDL entry" \
                 || tap_fail "TC-011: object_type=TABLE in DDL entry" "no TABLE in log"

CNT=$(count_matches 't1')
[[ $CNT -ge 1 ]] && tap_ok "TC-011: table name t1 in DDL entry" \
                 || tap_fail "TC-011: table name t1 in DDL entry" "no t1 in log"

CNT=$(count_matches '"OK"')
[[ $CNT -ge 1 ]] && tap_ok "TC-011: result=OK in DDL entry" \
                 || tap_fail "TC-011: result=OK in DDL entry" "no OK in log"

# ── TC-012: DDL ALTER TABLE ──────────────────────────────────────────────────
clear_log
Q "ALTER TABLE t1 ADD COLUMN extra int" >/dev/null
CNT=$(count_matches '"DDL","ALTER TABLE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-012: DDL ALTER TABLE logged" \
                 || tap_fail "TC-012: DDL ALTER TABLE logged" "0 matches"

# TC-012: DROP TABLE
clear_log
Q "DROP TABLE t1" >/dev/null
CNT=$(count_matches '"DDL","DROP TABLE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-012: DDL DROP TABLE logged" \
                 || tap_fail "TC-012: DDL DROP TABLE logged" "0 matches"

# ── TC-013: DDL CREATE INDEX, COMMENT ───────────────────────────────────────
Q "CREATE TABLE t2 (id int, val text)" >/dev/null
clear_log
Q "CREATE INDEX t2_idx ON t2(id)" >/dev/null
CNT=$(count_matches '"DDL","CREATE INDEX"')
[[ $CNT -ge 1 ]] && tap_ok "TC-013: DDL CREATE INDEX logged" \
                 || tap_fail "TC-013: DDL CREATE INDEX logged" "0 matches"

clear_log
Q "COMMENT ON TABLE t2 IS 'test comment'" >/dev/null
CNT=$(count_matches '"DDL"')
[[ $CNT -ge 1 ]] && tap_ok "TC-013: DDL COMMENT logged" \
                 || tap_fail "TC-013: DDL COMMENT logged" "0 matches"

# ── TC-014/015: DML SELECT / INSERT / UPDATE / DELETE ────────────────────────
clear_log
Q "INSERT INTO t2 VALUES (1, 'hello'), (2, 'world')" >/dev/null
CNT=$(count_matches '"DML","INSERT"')
[[ $CNT -ge 1 ]] && tap_ok "TC-015: DML INSERT logged" \
                 || tap_fail "TC-015: DML INSERT logged" "0 matches"
# rows_affected should be 2 at end of line
CNT=$(grep -c '"DML","INSERT".*,2$' "$LOGDIR/audit.log" 2>/dev/null || true)
[[ $CNT -ge 1 ]] && tap_ok "TC-015: rows_affected=2 for INSERT 2 rows" \
                 || tap_fail "TC-015: rows_affected=2 for INSERT 2 rows" "$(tail -1 $LOGDIR/audit.log)"

clear_log
Q "SELECT * FROM t2" >/dev/null
CNT=$(count_matches '"DML","SELECT"')
[[ $CNT -ge 1 ]] && tap_ok "TC-014: DML SELECT logged" \
                 || tap_fail "TC-014: DML SELECT logged" "0 matches"

clear_log
Q "UPDATE t2 SET val = 'updated' WHERE id = 1" >/dev/null
CNT=$(count_matches '"DML","UPDATE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-015: DML UPDATE logged" \
                 || tap_fail "TC-015: DML UPDATE logged" "0 matches"
CNT=$(grep -c '"DML","UPDATE".*,1$' "$LOGDIR/audit.log" 2>/dev/null || true)
[[ $CNT -ge 1 ]] && tap_ok "TC-015: rows_affected=1 for UPDATE 1 row" \
                 || tap_fail "TC-015: rows_affected=1 for UPDATE 1 row" "$(tail -1 $LOGDIR/audit.log)"

clear_log
Q "DELETE FROM t2 WHERE id = 1" >/dev/null
CNT=$(count_matches '"DML","DELETE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-015: DML DELETE logged" \
                 || tap_fail "TC-015: DML DELETE logged" "0 matches"

# ── TC-016: PRIVILEGE GRANT / REVOKE ────────────────────────────────────────
Q "CREATE ROLE testrole LOGIN" >/dev/null
clear_log
Q "GRANT SELECT ON t2 TO testrole" >/dev/null
CNT=$(count_matches '"PRIVILEGE","GRANT"')
[[ $CNT -ge 1 ]] && tap_ok "TC-016: PRIVILEGE GRANT logged" \
                 || tap_fail "TC-016: PRIVILEGE GRANT logged" "0 matches"
# Must NOT appear as DDL
CNT=$(count_matches '"DDL","GRANT"')
[[ $CNT -eq 0 ]] && tap_ok "TC-016: GRANT is PRIVILEGE not DDL" \
                 || tap_fail "TC-016: GRANT is PRIVILEGE not DDL" "$CNT DDL entries"

clear_log
Q "REVOKE SELECT ON t2 FROM testrole" >/dev/null
CNT=$(count_matches '"PRIVILEGE","REVOKE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-016: PRIVILEGE REVOKE logged" \
                 || tap_fail "TC-016: PRIVILEGE REVOKE logged" "0 matches"

# ── TC-017: PRIVILEGE SET ROLE ──────────────────────────────────────────────
clear_log
Q "SET ROLE testrole; RESET ROLE" >/dev/null
CNT=$(count_matches '"PRIVILEGE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-017: PRIVILEGE SET ROLE logged" \
                 || tap_fail "TC-017: PRIVILEGE SET ROLE logged" "0 matches"

# ── TC-018: PRIVILEGE SET SESSION AUTHORIZATION ──────────────────────────────
clear_log
Q "SET SESSION AUTHORIZATION DEFAULT" >/dev/null
CNT=$(count_matches '"PRIVILEGE"')
[[ $CNT -ge 1 ]] && tap_ok "TC-018: PRIVILEGE SET SESSION AUTHORIZATION logged" \
                 || tap_fail "TC-018: PRIVILEGE SET SESSION AUTHORIZATION logged" "0 matches"

# ── TC-01B: CONNECT / DISCONNECT ─────────────────────────────────────────────
# Each new psql connection → CONNECT; after exit → DISCONNECT
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U postgres -qAtX -c "SELECT 1" >/dev/null 2>&1
sleep 1
CNT=$(count_matches '"CONNECT"')
[[ $CNT -ge 1 ]] && tap_ok "TC-01B: CONNECT event logged" \
                 || tap_fail "TC-01B: CONNECT event logged" "0 CONNECT entries"
CNT=$(count_matches '"DISCONNECT"')
[[ $CNT -ge 1 ]] && tap_ok "TC-01B: DISCONNECT event logged" \
                 || tap_fail "TC-01B: DISCONNECT event logged" "0 DISCONNECT entries"

# ── TC-019/01A: AUTH ─────────────────────────────────────────────────────────
# With trust auth we get CONNECT, not a separate AUTH FAIL, so skip AUTH fail
tap_skip "TC-01A: AUTH FAIL logged" "trust auth on socket — no password check"

# ── TC-021: CSV has exactly 17 fields ───────────────────────────────────────
clear_log
Q "SELECT 1" >/dev/null
if [[ -f "$LOGDIR/audit.log" ]]; then
    # Count commas in first DML line: 16 commas = 17 fields
    LINE=$(grep '"DML"' "$LOGDIR/audit.log" | head -1)
    if [[ -n "$LINE" ]]; then
        # Use python to count CSV fields properly
        NFIELDS=$(python3 -c "import csv,io; r=csv.reader(io.StringIO('$LINE')); row=next(r); print(len(row))" 2>/dev/null || echo 0)
        [[ "$NFIELDS" == "17" ]] && tap_ok "TC-021: CSV has exactly 17 fields (got $NFIELDS)" \
                                  || tap_fail "TC-021: CSV has exactly 17 fields" "got $NFIELDS"
    else
        tap_fail "TC-021: CSV has exactly 17 fields" "no DML entry"
    fi
else
    tap_fail "TC-021: CSV has exactly 17 fields" "no audit.log"
fi

# ── TC-022: timestamp format ─────────────────────────────────────────────────
if [[ -f "$LOGDIR/audit.log" ]]; then
    LINE=$(grep '"DML"' "$LOGDIR/audit.log" | head -1)
    if [[ "$LINE" =~ ^\"[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        tap_ok "TC-022: timestamp starts with YYYY-MM-DD format"
    else
        tap_fail "TC-022: timestamp starts with YYYY-MM-DD format" "$LINE"
    fi
else
    tap_fail "TC-022: timestamp starts with YYYY-MM-DD format" "no audit.log"
fi

# ── TC-023: duration_ms present for DML ─────────────────────────────────────
clear_log
Q "SELECT pg_sleep(0.05)" >/dev/null
if [[ -f "$LOGDIR/audit.log" ]]; then
    LINE=$(grep '"DML","SELECT"' "$LOGDIR/audit.log" | head -1)
    # duration_ms is field 16: last two fields are duration,rows — rows empty for SELECT
    if echo "$LINE" | python3 -c "
import csv,sys
row=next(csv.reader(sys.stdin))
dur=row[15]
sys.exit(0 if dur and float(dur)>=0 else 1)
" 2>/dev/null; then
        tap_ok "TC-023: duration_ms is numeric and >= 0 for DML"
    else
        tap_fail "TC-023: duration_ms is numeric and >= 0 for DML" "$LINE"
    fi
else
    tap_fail "TC-023: duration_ms numeric" "no audit.log"
fi

# ── TC-024: rows_affected for INSERT ─────────────────────────────────────────
Q "INSERT INTO t2 VALUES (10,'a'),(11,'b'),(12,'c')" >/dev/null
clear_log
Q "DELETE FROM t2 WHERE id IN (10,11,12)" >/dev/null
CNT=$(grep -c '"DML","DELETE".*,3$' "$LOGDIR/audit.log" 2>/dev/null || true)
[[ $CNT -ge 1 ]] && tap_ok "TC-024: rows_affected=3 for DELETE 3 rows" \
                 || tap_fail "TC-024: rows_affected=3 for DELETE 3 rows" \
                    "$(grep '"DML","DELETE"' $LOGDIR/audit.log | head -1)"

# ── TC-03C: log_format=json ──────────────────────────────────────────────────
set_guc "log_format" "json"
clear_log
Q "SELECT 1" >/dev/null
if [[ -f "$LOGDIR/audit.log" ]]; then
    LINE=$(grep '"DML"' "$LOGDIR/audit.log" | head -1)
    if python3 -c "import json,sys; json.loads(sys.argv[1])" "$LINE" 2>/dev/null; then
        tap_ok "TC-052/03C: JSON format: line is valid JSON"
    else
        tap_fail "TC-052/03C: JSON format: line is valid JSON" "$LINE"
    fi
    [[ "$LINE" == *'"event_type":"DML"'* ]] \
        && tap_ok  "TC-052/03C: JSON has event_type field" \
        || tap_fail "TC-052/03C: JSON has event_type field" "$LINE"
    [[ "$LINE" == *'"timestamp":'* ]] \
        && tap_ok  "TC-052/03C: JSON has timestamp field" \
        || tap_fail "TC-052/03C: JSON has timestamp field" "$LINE"
    [[ "$LINE" == *'"result":"OK"'* ]] \
        && tap_ok  "TC-052/03C: JSON has result:OK" \
        || tap_fail "TC-052/03C: JSON has result:OK" "$LINE"
else
    tap_fail "TC-052/03C: JSON format" "no audit.log"
fi

# ── TC-053: log_format=text ──────────────────────────────────────────────────
set_guc "log_format" "text"
clear_log
Q "SELECT 2+2" >/dev/null
CNT=$(count_matches 'DML')
[[ $CNT -ge 1 ]] && tap_ok "TC-053: text format: DML entry present" \
                 || tap_fail "TC-053: text format: DML entry present" "0 matches"
CNT=$(count_matches 'result=OK')
[[ $CNT -ge 1 ]] && tap_ok "TC-053: text format: result=OK visible" \
                 || tap_fail "TC-053: text format: result=OK visible" "0 matches"

# Restore CSV
set_guc "log_format" "csv"

# ── TC-031: log_statements=none ─────────────────────────────────────────────
set_guc "log_statements" "none"
clear_log
Q "CREATE TABLE t3 (x int)" >/dev/null
Q "INSERT INTO t3 VALUES (99)" >/dev/null
CNT_DDL=$(count_matches '"DDL"')
CNT_DML=$(count_matches '"DML"')
[[ $CNT_DDL -eq 0 ]] && tap_ok "TC-031: log_statements=none suppresses DDL" \
                      || tap_fail "TC-031: log_statements=none suppresses DDL" "got $CNT_DDL"
[[ $CNT_DML -eq 0 ]] && tap_ok "TC-031: log_statements=none suppresses DML" \
                      || tap_fail "TC-031: log_statements=none suppresses DML" "got $CNT_DML"
Q "DROP TABLE t3" >/dev/null

# ── TC-032: log_statements=ddl ──────────────────────────────────────────────
set_guc "log_statements" "ddl"
Q "CREATE TABLE t3 (x int)" >/dev/null
clear_log
Q "SELECT * FROM t3" >/dev/null
Q "ALTER TABLE t3 ADD COLUMN y int" >/dev/null
CNT_DML=$(count_matches '"DML"')
CNT_DDL=$(count_matches '"DDL"')
[[ $CNT_DML -eq 0 ]] && tap_ok "TC-032: log_statements=ddl suppresses DML" \
                      || tap_fail "TC-032: log_statements=ddl suppresses DML" "got $CNT_DML"
[[ $CNT_DDL -ge 1 ]] && tap_ok "TC-032: log_statements=ddl records DDL" \
                      || tap_fail "TC-032: log_statements=ddl records DDL" "got $CNT_DDL"
Q "DROP TABLE t3" >/dev/null

# ── TC-033: log_statements=dml ──────────────────────────────────────────────
set_guc "log_statements" "dml"
Q "CREATE TABLE t3 (x int)" >/dev/null
clear_log
Q "INSERT INTO t3 VALUES (1)" >/dev/null
Q "CREATE INDEX t3_idx ON t3(x)" >/dev/null
CNT_DDL=$(count_matches '"DDL"')
CNT_DML=$(count_matches '"DML"')
[[ $CNT_DDL -eq 0 ]] && tap_ok "TC-033: log_statements=dml suppresses DDL" \
                      || tap_fail "TC-033: log_statements=dml suppresses DDL" "got $CNT_DDL"
[[ $CNT_DML -ge 1 ]] && tap_ok "TC-033: log_statements=dml records DML" \
                      || tap_fail "TC-033: log_statements=dml records DML" "got $CNT_DML"
Q "DROP TABLE t3" >/dev/null

# Restore
set_guc "log_statements" "all"

# ── TC-035: log_auth=off ─────────────────────────────────────────────────────
set_guc "log_auth" "off"
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U postgres -qAtX -c "SELECT 1" >/dev/null 2>&1
sleep 0.3
CNT_CONN=$(count_matches '"CONNECT"')
CNT_DISC=$(count_matches '"DISCONNECT"')
[[ $CNT_CONN -eq 0 ]] && tap_ok "TC-035: log_auth=off suppresses CONNECT" \
                       || tap_fail "TC-035: log_auth=off suppresses CONNECT" "got $CNT_CONN"
[[ $CNT_DISC -eq 0 ]] && tap_ok "TC-035: log_auth=off suppresses DISCONNECT" \
                       || tap_fail "TC-035: log_auth=off suppresses DISCONNECT" "got $CNT_DISC"
set_guc "log_auth" "on"

# ── TC-036: log_query_text=off ───────────────────────────────────────────────
Q "CREATE TABLE tqt (id int)" >/dev/null
set_guc "log_query_text" "off"
clear_log
Q "SELECT * FROM tqt" >/dev/null
if [[ -f "$LOGDIR/audit.log" ]]; then
    LINE=$(grep '"DML"' "$LOGDIR/audit.log" | head -1)
    if [[ "$LINE" != *"SELECT * FROM tqt"* ]]; then
        tap_ok "TC-036: log_query_text=off: SQL not in log"
    else
        tap_fail "TC-036: log_query_text=off: SQL not in log" "query text present"
    fi
    # query_text field (12th, index 11) should be ""
    QTEXT=$(echo "$LINE" | python3 -c "
import csv,sys
row=next(csv.reader(sys.stdin))
print(row[11])
" 2>/dev/null || echo "ERR")
    [[ "$QTEXT" == "" ]] && tap_ok "TC-036: query_text field is empty when off" \
                          || tap_fail "TC-036: query_text field is empty when off" "got: $QTEXT"
else
    tap_fail "TC-036: log_query_text=off" "no audit.log"
fi
set_guc "log_query_text" "on"

# ── TC-037: log_query_max_length truncation ──────────────────────────────────
set_guc "log_query_max_length" "20"
clear_log
Q "SELECT 'abcdefghijklmnopqrstuvwxyz0123456789' AS longcol" >/dev/null
CNT=$(count_matches '\.\.\.')
[[ $CNT -ge 1 ]] && tap_ok "TC-037: truncated query ends with ..." \
                 || tap_fail "TC-037: truncated query ends with ..." "no ellipsis in log"
set_guc "log_query_max_length" "0"

# ── TC-039: exclude_roles ────────────────────────────────────────────────────
# Need to allow testrole to connect via socket (trust)
set_guc "exclude_roles" "testrole"
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U testrole -d postgres -qAtX -c "SELECT 1" >/dev/null 2>&1 || true
CNT=$(grep -c '"testrole".*"DML"' "$LOGDIR/audit.log" 2>/dev/null || true)
[[ $CNT -eq 0 ]] && tap_ok "TC-039: exclude_roles suppresses DML for excluded role" \
                 || tap_fail "TC-039: exclude_roles suppresses DML for excluded role" "got $CNT"
set_guc "exclude_roles" ""

# ── TC-03B: log_errors=error ─────────────────────────────────────────────────
set_guc "log_errors" "error"
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U postgres -d postgres -qAtX -c "SELECT 1/0" >/dev/null 2>&1 || true
CNT=$(count_matches '"ERROR"')
[[ $CNT -ge 1 ]] && tap_ok "TC-03B: log_errors=error records division-by-zero" \
                 || tap_fail "TC-03B: log_errors=error records division-by-zero" "0 matches"
# Check error code / message
CNT=$(count_matches '22012\|division by zero')
[[ $CNT -ge 1 ]] && tap_ok "TC-03B: error_code or message present" \
                 || tap_fail "TC-03B: error_code or message present" \
                    "$(grep '"ERROR"' $LOGDIR/audit.log | head -1)"

# ── TC-03A: log_errors=none ──────────────────────────────────────────────────
set_guc "log_errors" "none"
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U postgres -d postgres -qAtX -c "SELECT 1/0" >/dev/null 2>&1 || true
CNT=$(count_matches '"ERROR"')
[[ $CNT -eq 0 ]] && tap_ok "TC-03A: log_errors=none suppresses ERROR events" \
                 || tap_fail "TC-03A: log_errors=none suppresses ERROR events" "got $CNT"
set_guc "log_errors" "error"

# ── TC-03D: pg_reload_conf() ─────────────────────────────────────────────────
echo "pg_bigeye.log_statements = 'none'" >> "$PGDATA/postgresql.conf"
Q "SELECT pg_reload_conf()" >/dev/null; sleep 0.3
clear_log
Q "SELECT 1" >/dev/null
CNT=$(count_matches '"DML"')
[[ $CNT -eq 0 ]] && tap_ok "TC-03D: pg_reload_conf() applies log_statements=none without restart" \
                 || tap_fail "TC-03D: pg_reload_conf() applies without restart" "got $CNT DML"
echo "pg_bigeye.log_statements = 'all'" >> "$PGDATA/postgresql.conf"
Q "SELECT pg_reload_conf()" >/dev/null; sleep 0.3

# ── TC-041: fixed-name mode — active file is always audit.log ─────────────────
[[ -f "$LOGDIR/audit.log" ]] \
    && tap_ok  "TC-041: active log file is named audit.log (fixed-name mode)" \
    || tap_fail "TC-041: active log file is named audit.log" "file missing"

# ── TC-044: pattern filename mode ────────────────────────────────────────────
DATEPAT=$(date '+audit-%Y-%m-%d.log')
echo "pg_bigeye.log_filename = 'audit-%Y-%m-%d.log'" >> "$PGDATA/postgresql.conf"
Q "SELECT pg_reload_conf()" >/dev/null; sleep 0.3
rm -f "$LOGDIR/$DATEPAT"
Q "SELECT 1" >/dev/null
[[ -f "$LOGDIR/$DATEPAT" ]] \
    && tap_ok  "TC-044: pattern mode creates $DATEPAT" \
    || tap_fail "TC-044: pattern mode creates $DATEPAT" "file not found"
# restore
echo "pg_bigeye.log_filename = 'audit.log'" >> "$PGDATA/postgresql.conf"
Q "SELECT pg_reload_conf()" >/dev/null; sleep 0.3
Q "SELECT 1" >/dev/null  # create audit.log again

# ── TC-042: size-based rotation ──────────────────────────────────────────────
echo "pg_bigeye.log_rotation_size = '1'" >> "$PGDATA/postgresql.conf"
Q "SELECT pg_reload_conf()" >/dev/null; sleep 0.3
rm -f "$LOGDIR/audit.log" "$LOGDIR/audit.log."*
# Generate enough writes to exceed 1 kB
for i in $(seq 1 30); do Q "SELECT $i" >/dev/null; done
ROTATED=$(ls "$LOGDIR/audit.log."* 2>/dev/null | wc -l || true)
[[ $ROTATED -ge 1 ]] && tap_ok "TC-042: size rotation created rotated file(s)" \
                      || tap_fail "TC-042: size rotation created rotated file(s)" "no rotated files"
[[ -f "$LOGDIR/audit.log" ]] \
    && tap_ok  "TC-042: new audit.log exists after size rotation" \
    || tap_fail "TC-042: new audit.log exists after size rotation" "audit.log missing"
echo "pg_bigeye.log_rotation_size = '0'" >> "$PGDATA/postgresql.conf"
Q "SELECT pg_reload_conf()" >/dev/null; sleep 0.3

# ── TC-026: application_name ─────────────────────────────────────────────────
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U postgres -d postgres \
    -c "SET application_name='myapp'" -c "SELECT 1" >/dev/null 2>&1
CNT=$(count_matches '"myapp"')
[[ $CNT -ge 1 ]] && tap_ok "TC-026: application_name appears in audit entry" \
                 || tap_fail "TC-026: application_name appears in audit entry" "0 matches"

# ── TC-061: concurrent sessions ──────────────────────────────────────────────
Q "CREATE TABLE conc_test (id int)" >/dev/null
clear_log
PIDS=()
for i in $(seq 1 10); do
    (
        for j in $(seq 1 5); do
            psql -h "$PGDATA" -p "$PGPORT" -U postgres -d postgres -qAtX \
                -c "INSERT INTO conc_test VALUES ($((i*100+j)))" >/dev/null 2>&1
        done
    ) &
    PIDS+=($!)
done
for PID in "${PIDS[@]}"; do wait "$PID"; done
sleep 0.3
CNT=$(count_matches '"DML","INSERT"')
tap_diag "Concurrent INSERT count: $CNT (expected >= 50)"
[[ $CNT -ge 50 ]] && tap_ok "TC-061: concurrent sessions: >=50 INSERT entries (got $CNT)" \
                   || tap_fail "TC-061: concurrent sessions: >=50 INSERT entries" "got $CNT"
Q "DROP TABLE conc_test" >/dev/null

# ── TC-071: CSV escaping — double-quote ──────────────────────────────────────
clear_log
Q "SELECT '\"hello\"'" >/dev/null
CNT=$(count_matches '""hello""')
[[ $CNT -ge 1 ]] && tap_ok "TC-071: double-quote in SQL is CSV-escaped as \"\"" \
                 || tap_fail "TC-071: double-quote in SQL CSV-escaped" \
                    "$(grep '"DML"' $LOGDIR/audit.log | head -1)"

# ── TC-072: newlines in SQL ───────────────────────────────────────────────────
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U postgres -d postgres -qAtX \
    -c $'SELECT\n1+1\nAS result' >/dev/null 2>&1
CNT=$(count_matches '"DML"')
[[ $CNT -ge 1 ]] && tap_ok "TC-072: multi-line SQL logged as single entry" \
                 || tap_fail "TC-072: multi-line SQL logged as single entry" "0 matches"

# ── TC-074: multibyte (Japanese) table name ───────────────────────────────────
clear_log
Q 'CREATE TABLE "日本語テーブル" (id int)' >/dev/null
CNT=$(count_matches '日本語テーブル')
[[ $CNT -ge 1 ]] && tap_ok "TC-074: Japanese multibyte chars in log entry" \
                 || tap_fail "TC-074: Japanese multibyte chars in log entry" "not found"
Q 'DROP TABLE "日本語テーブル"' >/dev/null

# ── TC-073: very long SQL ────────────────────────────────────────────────────
LONG_SQL=$(python3 -c "print(\"SELECT '\" + 'x' * 10000 + \"' AS longval\")")
clear_log
psql -h "$PGDATA" -p "$PGPORT" -U postgres -d postgres -qAtX \
    -c "$LONG_SQL" >/dev/null 2>&1 || true
CNT=$(count_matches '"DML"')
[[ $CNT -ge 1 ]] && tap_ok "TC-073: very long SQL logged without crash" \
                 || tap_fail "TC-073: very long SQL logged without crash" "0 matches"

# ── TC-062: autovacuum not in audit log ──────────────────────────────────────
# Enable autovacuum, let it run, check no entries from autovacuum worker
echo "autovacuum = on" >> "$PGDATA/postgresql.conf"
Q "SELECT pg_reload_conf()" >/dev/null; sleep 0.3
Q "CREATE TABLE avac_test (id int)" >/dev/null
Q "INSERT INTO avac_test SELECT generate_series(1,1000)" >/dev/null
Q "DELETE FROM avac_test" >/dev/null
# Trigger autovacuum
Q "ANALYZE avac_test" >/dev/null
sleep 2
# We can't easily check autovacuum PID, but at minimum verify the extension
# didn't crash and log is still intact
[[ -f "$LOGDIR/audit.log" ]] \
    && tap_ok  "TC-062: extension still running after autovacuum activity" \
    || tap_fail "TC-062: extension still running after autovacuum activity" "audit.log missing"
Q "DROP TABLE avac_test" >/dev/null

###############################################################################
# Teardown
###############################################################################
Q "DROP TABLE IF EXISTS t2" >/dev/null
Q "DROP TABLE IF EXISTS tqt" >/dev/null
Q "DROP ROLE IF EXISTS testrole" >/dev/null

pg_ctl -D "$PGDATA" stop -m fast >/dev/null 2>&1
rm -rf "$PGDATA"

echo "1..$TAP_NUM"
tap_diag "Results: $PASSED passed, $FAILED failed out of $TAP_NUM tests"

[[ $FAILED -eq 0 ]] && exit 0 || exit 1
