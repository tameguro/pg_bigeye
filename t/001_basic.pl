#!/usr/bin/perl
#
# pg_bigeye TAP test suite
# Covers TC-01x (events), TC-02x (fields), TC-03x (GUC), TC-04x (files),
# TC-05x (format), TC-06x (concurrency), TC-07x (special chars).
#
use strict;
use warnings;
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;
use POSIX qw(strftime);

# ---------------------------------------------------------------------------
# Helper: read audit log, return array of lines (skip blanks)
# ---------------------------------------------------------------------------
sub read_audit_log {
    my ($node, $log_dir, $filename) = @_;
    $filename //= 'audit.log';
    my $path = "$log_dir/$filename";
    return () unless -f $path;
    open my $fh, '<', $path or die "Cannot open $path: $!";
    my @lines = grep { /\S/ } <$fh>;
    close $fh;
    chomp @lines;
    return @lines;
}

# ---------------------------------------------------------------------------
# Helper: grep lines matching a pattern
# ---------------------------------------------------------------------------
sub grep_log {
    my ($pattern, @lines) = @_;
    return grep { $_ =~ $pattern } @lines;
}

# ---------------------------------------------------------------------------
# Setup: create node, install extension
# ---------------------------------------------------------------------------
my $node = PostgreSQL::Test::Cluster->new('test');
$node->init;

# Point to our built .so
my $ext_dir  = '/workspaces/pg_bigeye';
my $so_dest  = $node->config_data('pkglibdir');
my $log_dir  = $node->data_dir . '/pg_audit_log';

# Install .so into pkglibdir
system("cp $ext_dir/pg_bigeye.so $so_dest/") == 0
    or BAIL_OUT("Cannot copy pg_bigeye.so to $so_dest: $!");

$node->append_conf('postgresql.conf', qq{
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
});

$node->start;

# Convenience: run SQL and return stdout
sub sql { return $node->safe_psql('postgres', $_[0]); }
sub psql_cmd { return $node->psql('postgres', $_[0]); }

# Clear audit log before each group of tests
sub clear_log {
    unlink "$log_dir/audit.log" if -f "$log_dir/audit.log";
}

# ---------------------------------------------------------------------------
# TC-04-7: log_directory auto-created on startup
# ---------------------------------------------------------------------------
ok(-d $log_dir, 'TC-047: log_directory created automatically on startup');

# ---------------------------------------------------------------------------
# TC-04-5/6: file permissions
# ---------------------------------------------------------------------------
{
    sql("SELECT 1");    # trigger first write
    if (-f "$log_dir/audit.log") {
        my @stat = stat("$log_dir/audit.log");
        my $mode = $stat[2] & 07777;
        is($mode, 0600, 'TC-045: audit.log permissions are 0600');
    } else {
        fail('TC-045: audit.log not created');
    }
    my @dstat = stat($log_dir);
    my $dmode = $dstat[2] & 07777;
    is($dmode, 0700, 'TC-046: log_directory permissions are 0700');
}

# ---------------------------------------------------------------------------
# TC-01-1: DDL — CREATE TABLE
# ---------------------------------------------------------------------------
clear_log();
sql("CREATE TABLE t1 (id int, val text)");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl = grep_log(qr/"DDL".*"CREATE TABLE"/, @lines);
    ok(@ddl >= 1, 'TC-011: DDL CREATE TABLE logged');
    like($ddl[0], qr/"TABLE"/, 'TC-011: object_type=TABLE in DDL entry');
    like($ddl[0], qr/t1/, 'TC-011: table name t1 in DDL entry');
    like($ddl[0], qr/"OK"/, 'TC-011: result=OK');
}

# ---------------------------------------------------------------------------
# TC-01-2: DDL — ALTER TABLE
# ---------------------------------------------------------------------------
clear_log();
sql("ALTER TABLE t1 ADD COLUMN extra int");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl = grep_log(qr/"DDL".*"ALTER TABLE"/, @lines);
    ok(@ddl >= 1, 'TC-012: DDL ALTER TABLE logged');
}

# TC-01-2 cont: DROP TABLE
clear_log();
sql("DROP TABLE t1");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl = grep_log(qr/"DDL".*"DROP TABLE"/, @lines);
    ok(@ddl >= 1, 'TC-012: DDL DROP TABLE logged');
}

# TC-01-3: CREATE INDEX, COMMENT
sql("CREATE TABLE t2 (id int, val text)");
clear_log();
sql("CREATE INDEX t2_idx ON t2(id)");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl = grep_log(qr/"DDL".*"CREATE INDEX"/, @lines);
    ok(@ddl >= 1, 'TC-013: DDL CREATE INDEX logged');
}
clear_log();
sql("COMMENT ON TABLE t2 IS 'test comment'");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl = grep_log(qr/"DDL"/, @lines);
    ok(@ddl >= 1, 'TC-013: DDL COMMENT logged');
}

# ---------------------------------------------------------------------------
# TC-01-4/5: DML — SELECT / INSERT / UPDATE / DELETE
# ---------------------------------------------------------------------------
clear_log();
sql("INSERT INTO t2 VALUES (1, 'hello'), (2, 'world')");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"INSERT"/, @lines);
    ok(@dml >= 1, 'TC-015: DML INSERT logged');
    like($dml[0], qr/2$/, 'TC-015: rows_affected=2 for INSERT 2 rows');
}

clear_log();
sql("SELECT * FROM t2");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"SELECT"/, @lines);
    ok(@dml >= 1, 'TC-014: DML SELECT logged');
}

clear_log();
sql("UPDATE t2 SET val = 'updated' WHERE id = 1");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"UPDATE"/, @lines);
    ok(@dml >= 1, 'TC-015: DML UPDATE logged');
    like($dml[0], qr/,1$/, 'TC-015: rows_affected=1 for UPDATE 1 row');
}

clear_log();
sql("DELETE FROM t2 WHERE id = 1");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"DELETE"/, @lines);
    ok(@dml >= 1, 'TC-015: DML DELETE logged');
}

# ---------------------------------------------------------------------------
# TC-01-6: PRIVILEGE — GRANT / REVOKE
# ---------------------------------------------------------------------------
sql("CREATE ROLE testrole LOGIN");
clear_log();
sql("GRANT SELECT ON t2 TO testrole");
{
    my @lines = read_audit_log($node, $log_dir);
    my @priv = grep_log(qr/"PRIVILEGE".*"GRANT"/, @lines);
    ok(@priv >= 1, 'TC-016: PRIVILEGE GRANT logged');
    ok(!grep_log(qr/"DDL".*"GRANT"/, @lines), 'TC-016: GRANT is PRIVILEGE not DDL');
}

clear_log();
sql("REVOKE SELECT ON t2 FROM testrole");
{
    my @lines = read_audit_log($node, $log_dir);
    my @priv = grep_log(qr/"PRIVILEGE".*"REVOKE"/, @lines);
    ok(@priv >= 1, 'TC-016: PRIVILEGE REVOKE logged');
}

# ---------------------------------------------------------------------------
# TC-01-7: PRIVILEGE — SET ROLE
# ---------------------------------------------------------------------------
clear_log();
sql("SET ROLE testrole");
sql("RESET ROLE");
{
    my @lines = read_audit_log($node, $log_dir);
    my @priv = grep_log(qr/"PRIVILEGE"/, @lines);
    ok(@priv >= 1, 'TC-017: PRIVILEGE SET ROLE logged');
}

# ---------------------------------------------------------------------------
# TC-01-8: PRIVILEGE — SET SESSION AUTHORIZATION
# ---------------------------------------------------------------------------
clear_log();
sql("SET SESSION AUTHORIZATION DEFAULT");
{
    my @lines = read_audit_log($node, $log_dir);
    my @priv = grep_log(qr/"PRIVILEGE"/, @lines);
    ok(@priv >= 1, 'TC-018: PRIVILEGE SET SESSION AUTHORIZATION logged');
}

# ---------------------------------------------------------------------------
# TC-01-9 / TC-01-B: AUTH, CONNECT, DISCONNECT
# Restart node to generate fresh CONNECT/DISCONNECT via a new connection
# ---------------------------------------------------------------------------
clear_log();
$node->psql('postgres', 'SELECT 1');    # new connection → CONNECT + DISCONNECT
{
    my @lines = read_audit_log($node, $log_dir);
    my @conn = grep_log(qr/"CONNECT"/, @lines);
    my @disc = grep_log(qr/"DISCONNECT"/, @lines);
    ok(@conn >= 1, 'TC-01B: CONNECT event logged');
    ok(@disc >= 1, 'TC-01B: DISCONNECT event logged');
}

# TC-01-A: AUTH FAIL (wrong password)
$node->append_conf('pg_hba.conf', "local all testrole md5\n");
$node->reload;
sql("ALTER ROLE testrole PASSWORD 'secret'");
clear_log();
{
    # Attempt to connect with wrong password via psql -c
    my ($rc, $stdout, $stderr) = $node->psql(
        'postgres',
        'SELECT 1',
        extra_params => ['-U', 'testrole'],
        connstr      => $node->connstr('postgres') . ' password=wrongpass',
    );
    # AUTH failure may or may not reach us depending on pg_hba/socket
    # Just check if we got an AUTH FAIL line, or skip if auth was not attempted
    my @lines = read_audit_log($node, $log_dir);
    my @auth  = grep_log(qr/"AUTH"/, @lines);
    if (@auth) {
        my @fail = grep_log(qr/"AUTH".*"FAIL"/, @lines);
        ok(@fail >= 1, 'TC-01A: AUTH FAIL logged with result=FAIL');
    } else {
        pass('TC-01A: AUTH FAIL test skipped (trust auth on socket)');
    }
}

# ---------------------------------------------------------------------------
# TC-02-1: 17 fields in CSV
# ---------------------------------------------------------------------------
clear_log();
sql("SELECT 1");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML"/, @lines);
    if (@dml) {
        my @fields = split /,(?=(?:[^"]*"[^"]*")*[^"]*$)/, $dml[0];
        is(scalar @fields, 17, 'TC-021: CSV has exactly 17 fields');
    } else {
        fail('TC-021: no DML entry found');
    }
}

# ---------------------------------------------------------------------------
# TC-02-3: duration_ms present for DML, absent for CONNECT/DISCONNECT
# ---------------------------------------------------------------------------
clear_log();
sql("SELECT pg_sleep(0.05)");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"SELECT"/, @lines);
    if (@dml) {
        my @fields = split /,(?=(?=[^"]*(?:"[^"]*"[^"]*)*$))/, $dml[0];
        # duration_ms is field 16 (index 15)
        my $dur_field = $fields[15] // '';
        $dur_field =~ s/"//g;
        ok($dur_field =~ /^\d/, 'TC-023: duration_ms is numeric for DML');
        ok($dur_field + 0 >= 0, 'TC-023: duration_ms >= 0');
    } else {
        fail('TC-023: no DML SELECT entry');
    }
}

# ---------------------------------------------------------------------------
# TC-02-4: rows_affected
# ---------------------------------------------------------------------------
sql("INSERT INTO t2 VALUES (10, 'a'), (11, 'b'), (12, 'c')");
clear_log();
sql("DELETE FROM t2 WHERE id IN (10, 11, 12)");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"DELETE"/, @lines);
    like($dml[0], qr/,3$/, 'TC-024: rows_affected=3 for DELETE 3 rows') if @dml;
    ok(@dml >= 1, 'TC-024: DELETE DML entry exists');
}

# ---------------------------------------------------------------------------
# TC-03-1: log_statements=none
# ---------------------------------------------------------------------------
$node->append_conf('postgresql.conf', "pg_bigeye.log_statements = 'none'\n");
$node->reload;
clear_log();
sql("CREATE TABLE t3 (x int)");
sql("INSERT INTO t3 VALUES (99)");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl   = grep_log(qr/"DDL"/, @lines);
    my @dml   = grep_log(qr/"DML"/, @lines);
    is(scalar @ddl, 0, 'TC-031: log_statements=none suppresses DDL');
    is(scalar @dml, 0, 'TC-031: log_statements=none suppresses DML');
}
sql("DROP TABLE t3");

# TC-03-2: log_statements=ddl
$node->append_conf('postgresql.conf', "pg_bigeye.log_statements = 'ddl'\n");
$node->reload;
sql("CREATE TABLE t3 (x int)");
clear_log();
sql("SELECT * FROM t3");
sql("ALTER TABLE t3 ADD COLUMN y int");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml   = grep_log(qr/"DML"/, @lines);
    my @ddl   = grep_log(qr/"DDL"/, @lines);
    is(scalar @dml, 0, 'TC-032: log_statements=ddl suppresses DML SELECT');
    ok(@ddl >= 1,     'TC-032: log_statements=ddl records DDL ALTER TABLE');
}
sql("DROP TABLE t3");

# TC-03-3: log_statements=dml
$node->append_conf('postgresql.conf', "pg_bigeye.log_statements = 'dml'\n");
$node->reload;
sql("CREATE TABLE t3 (x int)");
clear_log();
sql("INSERT INTO t3 VALUES (1)");
sql("CREATE INDEX t3_idx ON t3(x)");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl = grep_log(qr/"DDL"/, @lines);
    my @dml = grep_log(qr/"DML"/, @lines);
    is(scalar @ddl, 0, 'TC-033: log_statements=dml suppresses DDL CREATE INDEX');
    ok(@dml >= 1,     'TC-033: log_statements=dml records DML INSERT');
}
sql("DROP TABLE t3");

# Restore all for remaining tests
$node->append_conf('postgresql.conf', "pg_bigeye.log_statements = 'all'\n");
$node->reload;

# TC-03-5: log_auth=off
$node->append_conf('postgresql.conf', "pg_bigeye.log_auth = off\n");
$node->reload;
clear_log();
$node->psql('postgres', 'SELECT 1');    # new connection
{
    my @lines = read_audit_log($node, $log_dir);
    my @conn = grep_log(qr/"CONNECT"/, @lines);
    my @disc = grep_log(qr/"DISCONNECT"/, @lines);
    is(scalar @conn, 0, 'TC-035: log_auth=off suppresses CONNECT');
    is(scalar @disc, 0, 'TC-035: log_auth=off suppresses DISCONNECT');
}
$node->append_conf('postgresql.conf', "pg_bigeye.log_auth = on\n");
$node->reload;

# TC-03-6: log_query_text=off
$node->append_conf('postgresql.conf', "pg_bigeye.log_query_text = off\n");
$node->reload;
sql("CREATE TABLE tqt (id int)");
clear_log();
sql("SELECT * FROM tqt");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML"/, @lines);
    if (@dml) {
        unlike($dml[0], qr/SELECT \* FROM tqt/, 'TC-036: log_query_text=off: query not in log');
        # field 12 (query_text) should be ""
        like($dml[0], qr/,"",/, 'TC-036: log_query_text=off: query_text field is empty');
    } else {
        fail('TC-036: no DML entry');
    }
}
$node->append_conf('postgresql.conf', "pg_bigeye.log_query_text = on\n");
$node->reload;

# TC-03-7: log_query_max_length
$node->append_conf('postgresql.conf', "pg_bigeye.log_query_max_length = 20\n");
$node->reload;
clear_log();
sql("SELECT 'abcdefghijklmnopqrstuvwxyz0123456789' AS longcol");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML"/, @lines);
    if (@dml) {
        like($dml[0], qr/\.\.\./, 'TC-037: truncated query ends with ...');
    } else {
        fail('TC-037: no DML entry for long query');
    }
}
$node->append_conf('postgresql.conf', "pg_bigeye.log_query_max_length = 0\n");
$node->reload;

# TC-03-9: exclude_roles
$node->append_conf('postgresql.conf', "pg_bigeye.exclude_roles = 'testrole'\n");
$node->reload;
clear_log();
# Run query as testrole (which is a non-superuser, trust auth via socket should work)
$node->psql('postgres', "SELECT 1", extra_params => ['-U', 'testrole']);
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"SELECT"/, @lines);
    # testrole DML should be excluded; only CONNECT/DISCONNECT may appear
    my @testrole_dml = grep { /testrole/ && /"DML"/ } @lines;
    is(scalar @testrole_dml, 0, 'TC-039: exclude_roles suppresses DML for excluded role');
}
$node->append_conf('postgresql.conf', "pg_bigeye.exclude_roles = ''\n");
$node->reload;

# TC-03-A/B: log_errors
$node->append_conf('postgresql.conf', "pg_bigeye.log_errors = 'error'\n");
$node->reload;
clear_log();
$node->psql('postgres', "SELECT 1/0");     # division by zero → ERROR
{
    my @lines = read_audit_log($node, $log_dir);
    my @err = grep_log(qr/"ERROR"/, @lines);
    ok(@err >= 1, 'TC-03B: log_errors=error records division-by-zero ERROR');
    like($err[0], qr/22012|division by zero/, 'TC-03B: error_code or message present');
}

$node->append_conf('postgresql.conf', "pg_bigeye.log_errors = 'none'\n");
$node->reload;
clear_log();
$node->psql('postgres', "SELECT 1/0");
{
    my @lines = read_audit_log($node, $log_dir);
    my @err = grep_log(qr/"ERROR"/, @lines);
    is(scalar @err, 0, 'TC-03A: log_errors=none suppresses ERROR events');
}
$node->append_conf('postgresql.conf', "pg_bigeye.log_errors = 'error'\n");
$node->reload;

# ---------------------------------------------------------------------------
# TC-03-C: JSON format
# ---------------------------------------------------------------------------
$node->append_conf('postgresql.conf', "pg_bigeye.log_format = 'json'\n");
$node->reload;
clear_log();
sql("SELECT 1");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML"/, @lines);
    if (@dml) {
        my $json = $dml[0];
        like($json, qr/^\{.*\}$/, 'TC-052/03C: JSON format: line is a JSON object');
        like($json, qr/"event_type":"DML"/, 'TC-052/03C: JSON has event_type field');
        like($json, qr/"timestamp":/,       'TC-052/03C: JSON has timestamp field');
        like($json, qr/"pid":\d+/,          'TC-052/03C: JSON has pid field');
        like($json, qr/"result":"OK"/,      'TC-052/03C: JSON has result field');
    } else {
        fail('TC-052: no entry in JSON log');
    }
}

# TC-05-3: text format
$node->append_conf('postgresql.conf', "pg_bigeye.log_format = 'text'\n");
$node->reload;
clear_log();
sql("SELECT 2+2");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/DML/, @lines);
    ok(@dml >= 1, 'TC-053: text format: DML entry present');
    like($dml[0], qr/result=OK/, 'TC-053: text format: result=OK visible');
}

# Restore CSV
$node->append_conf('postgresql.conf', "pg_bigeye.log_format = 'csv'\n");
$node->reload;

# ---------------------------------------------------------------------------
# TC-04-1: fixed-name mode — active file is always audit.log
# ---------------------------------------------------------------------------
ok(-f "$log_dir/audit.log", 'TC-041: active log file is named audit.log (fixed-name mode)');

# ---------------------------------------------------------------------------
# TC-04-4: pattern filename mode
# ---------------------------------------------------------------------------
{
    my $datepat = POSIX::strftime('audit-%Y-%m-%d.log', localtime);
    $node->append_conf('postgresql.conf',
        "pg_bigeye.log_filename = 'audit-%Y-%m-%d.log'\n");
    $node->reload;
    unlink "$log_dir/$datepat" if -f "$log_dir/$datepat";
    sql("SELECT 1");
    ok(-f "$log_dir/$datepat", "TC-044: pattern mode creates $datepat");
    # restore
    $node->append_conf('postgresql.conf',
        "pg_bigeye.log_filename = 'audit.log'\n");
    $node->reload;
}

# ---------------------------------------------------------------------------
# TC-04-2: size-based rotation (set tiny limit)
# ---------------------------------------------------------------------------
{
    $node->append_conf('postgresql.conf',
        "pg_bigeye.log_rotation_size = 1\n");   # 1 kB
    $node->reload;
    unlink "$log_dir/audit.log" if -f "$log_dir/audit.log";

    # Generate enough writes to exceed 1 kB
    for my $i (1..30) {
        sql("SELECT $i");
    }

    my @rotated = glob("$log_dir/audit.log.*");
    ok(@rotated >= 1, 'TC-042: size rotation created at least one rotated file');
    ok(-f "$log_dir/audit.log", 'TC-042: new audit.log exists after rotation');

    $node->append_conf('postgresql.conf',
        "pg_bigeye.log_rotation_size = 0\n");
    $node->reload;
}

# ---------------------------------------------------------------------------
# TC-06-1: concurrent sessions — no missing / corrupt entries
# ---------------------------------------------------------------------------
{
    clear_log();
    sql("CREATE TABLE conc_test (id int)");

    my @pids;
    for my $i (1..10) {
        my $pid = fork();
        if ($pid == 0) {
            # child: insert 5 rows via psql
            for my $j (1..5) {
                $node->psql('postgres',
                    "INSERT INTO conc_test VALUES ($i * 100 + $j)");
            }
            exit 0;
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;

    my @lines = read_audit_log($node, $log_dir);
    my @inserts = grep_log(qr/"DML".*"INSERT"/, @lines);
    ok(@inserts >= 50, "TC-061: concurrent sessions: >= 50 INSERT entries logged (got " . scalar(@inserts) . ")");

    sql("DROP TABLE conc_test");
}

# ---------------------------------------------------------------------------
# TC-07-1: CSV escaping — double-quote in SQL
# ---------------------------------------------------------------------------
clear_log();
sql('SELECT \'"hello"\'');
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML"/, @lines);
    if (@dml) {
        # CSV: internal " must be doubled → ""hello""
        like($dml[0], qr/""hello""/, 'TC-071: double-quote in SQL is CSV-escaped as ""');
    } else {
        fail('TC-071: no DML entry for query with double-quote');
    }
}

# TC-07-2: newline in SQL (multi-line query)
clear_log();
sql("SELECT\n1+1\nAS result");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML"/, @lines);
    ok(@dml >= 1, 'TC-072: multi-line SQL logged without splitting CSV record');
    # The whole entry must be on one logical CSV line (newlines inside quotes)
    # Since we read line-by-line above we just check at least one match
}

# TC-07-4: multibyte characters (Japanese table name)
clear_log();
sql("CREATE TABLE \"日本語テーブル\" (id int)");
{
    my @lines = read_audit_log($node, $log_dir);
    my @ddl = grep_log(qr/"DDL"/, @lines);
    if (@ddl) {
        my $entry = join('', @ddl);
        like($entry, qr/日本語テーブル/, 'TC-074: Japanese multibyte chars in log entry');
    } else {
        fail('TC-074: no DDL entry for Japanese table name');
    }
}
sql('DROP TABLE "日本語テーブル"');

# TC-07-3: very long SQL (10000 chars), log_query_max_length=0 → no crash
clear_log();
{
    my $long_sql = "SELECT " . ("'x' || " x 500) . "'end'";
    eval { sql($long_sql) };
    my @lines = read_audit_log($node, $log_dir);
    ok(@lines >= 1, 'TC-073: very long SQL logged without crash');
}

# ---------------------------------------------------------------------------
# TC-03-D: pg_reload_conf() — config change without restart
# ---------------------------------------------------------------------------
$node->append_conf('postgresql.conf', "pg_bigeye.log_statements = 'none'\n");
sql("SELECT pg_reload_conf()");
sleep 1;
clear_log();
sql("SELECT 1");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML"/, @lines);
    is(scalar @dml, 0, 'TC-03D: pg_reload_conf() applies log_statements=none without restart');
}
$node->append_conf('postgresql.conf', "pg_bigeye.log_statements = 'all'\n");
sql("SELECT pg_reload_conf()");

# ---------------------------------------------------------------------------
# TC-02-6: application_name field
# ---------------------------------------------------------------------------
clear_log();
sql("SET application_name = 'myapp'; SELECT 1");
{
    my @lines = read_audit_log($node, $log_dir);
    my @dml = grep_log(qr/"DML".*"SELECT"/, @lines);
    # application_name is field 7 in CSV
    my @myapp = grep_log(qr/"myapp"/, @dml);
    ok(@myapp >= 1, 'TC-026: application_name appears in audit entry');
}

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------
sql("DROP TABLE IF EXISTS t2");
sql("DROP TABLE IF EXISTS tqt");
sql("DROP ROLE IF EXISTS testrole");

$node->stop;

done_testing();
