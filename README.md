# pg_bigeye v0.1.0

PostgreSQL 監査ログを通常ログとは**完全に独立したファイル**へ出力する拡張機能です。

A PostgreSQL extension that writes audit logs to a **fully independent file**, completely separate from the normal server log.

---

## なぜ pg_bigeye か

PostgreSQL には、監査ログだけを別ファイルへ書き出す仕組みがありません。既存の [pgaudit](https://www.pgaudit.org/) は通常の PostgreSQL ログへ混在させる設計です。本拡張機能はその問題を解消します。

| 項目 | pgaudit | pg_bigeye |
|------|---------|--------------|
| 出力先 | 通常ログに混在 | **専用ファイルに分離** |
| ログ分離 | 不可 | 可能（設計の核心） |
| フォーマット | PostgreSQL ログ形式に依存 | CSV / JSON / text を選択可能 |
| ファイルローテーション | 不可 | サイズ・時間ベースに対応 |

## Why pg_bigeye?

PostgreSQL has no built-in mechanism to write audit logs to a separate file. The existing [pgaudit](https://www.pgaudit.org/) extension mixes audit records into the normal server log. pg_bigeye solves this by writing to a dedicated, independently managed file.

| Feature | pgaudit | pg_bigeye |
|---------|---------|-----------|
| Output destination | Mixed into the server log | **Dedicated separate file** |
| Log isolation | Not possible | Yes (core design goal) |
| Format | Tied to PostgreSQL log format | CSV / JSON / text selectable |
| File rotation | Not supported | Size- and time-based rotation |

---

## 動作環境

| 要件 | 詳細 |
|------|------|
| PostgreSQL | 17 以降（PG19beta1 でテスト済み） |
| OS | Linux / macOS（POSIX 準拠環境） |
| ビルド | PGXS（`pg_config --pgxs`） |

## Requirements

| Requirement | Details |
|-------------|---------|
| PostgreSQL | 17 or later (tested on PG19beta1) |
| OS | Linux / macOS (POSIX-compliant environment) |
| Build system | PGXS (`pg_config --pgxs`) |

---

## ファイル構成

```
pg_bigeye/
├── Makefile
├── pg_bigeye.c         # フック登録・GUC 定義・各イベントハンドラ
├── pg_bigeye.h         # 共有ヘッダ（AuditEntry 構造体、GUC extern）
├── audit_writer.c      # ファイル I/O・ローテーション・共有メモリ管理
├── audit_format.c      # CSV / JSON / text フォーマッタ
└── t/
    └── run_tests.sh    # TAP テストスクリプト
```

## Repository Layout

```
pg_bigeye/
├── Makefile
├── pg_bigeye.c         # Hook registration, GUC definitions, event handlers
├── pg_bigeye.h         # Shared header (AuditEntry struct, GUC externs)
├── audit_writer.c      # File I/O, rotation, shared memory management
├── audit_format.c      # CSV / JSON / text formatters
└── t/
    └── run_tests.sh    # TAP test script
```

---

## インストール

```bash
# ビルドと .so のインストール
make
make install

# postgresql.conf に以下を追記して PostgreSQL を再起動
shared_preload_libraries = 'pg_bigeye'
pg_bigeye.log_directory  = 'pg_audit_log'
pg_bigeye.log_statements = 'all'
```

> `shared_preload_libraries` はサーバ再起動が必要です。  
> その他の GUC パラメータはすべて `pg_reload_conf()` でオンライン反映できます。

## Installation

```bash
# Build and install the shared library
make
make install

# Add to postgresql.conf and restart PostgreSQL
shared_preload_libraries = 'pg_bigeye'
pg_bigeye.log_directory  = 'pg_audit_log'
pg_bigeye.log_statements = 'all'
```

> `shared_preload_libraries` requires a server restart.  
> All other GUC parameters can be reloaded online with `pg_reload_conf()`.

---

## 動作確認

```bash
psql -c "CREATE TABLE t1 (id int);"
psql -c "INSERT INTO t1 VALUES (1);"
psql -c "SELECT * FROM t1;"
psql -c "GRANT SELECT ON t1 TO public;"

cat $PGDATA/pg_audit_log/audit.log
```

出力例（CSV フォーマット）:

```csv
"2025-06-05 12:34:56.100 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","CONNECT","","","","","OK","","","",""
"2025-06-05 12:34:56.789 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","DDL","CREATE TABLE","TABLE","public.t1","CREATE TABLE t1 (id int);","OK","","","12.3",""
"2025-06-05 12:34:57.001 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","DML","INSERT","TABLE","public.t1","INSERT INTO t1 VALUES (1);","OK","","","5.2","1"
"2025-06-05 12:34:57.200 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","PRIVILEGE","GRANT","TABLE","public.t1","GRANT SELECT ON t1 TO public;","OK","","","3.1",""
"2025-06-05 12:35:00.500 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","DISCONNECT","","","","","OK","","","","1230.5",""
"2025-06-05 12:35:01.000 JST",12346,"bob","mydb","127.0.0.1",54322,"myapp","AUTH","","","","","FAIL","28P01","password authentication failed for user \"bob\"","",""
```

## Quick Start

```bash
psql -c "CREATE TABLE t1 (id int);"
psql -c "INSERT INTO t1 VALUES (1);"
psql -c "SELECT * FROM t1;"
psql -c "GRANT SELECT ON t1 TO public;"

cat $PGDATA/pg_audit_log/audit.log
```

Sample output (CSV format):

```csv
"2025-06-05 12:34:56.100 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","CONNECT","","","","","OK","","","",""
"2025-06-05 12:34:56.789 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","DDL","CREATE TABLE","TABLE","public.t1","CREATE TABLE t1 (id int);","OK","","","12.3",""
"2025-06-05 12:34:57.001 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","DML","INSERT","TABLE","public.t1","INSERT INTO t1 VALUES (1);","OK","","","5.2","1"
"2025-06-05 12:34:57.200 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","PRIVILEGE","GRANT","TABLE","public.t1","GRANT SELECT ON t1 TO public;","OK","","","3.1",""
"2025-06-05 12:35:00.500 JST",12345,"alice","mydb","127.0.0.1",54321,"psql","DISCONNECT","","","","","OK","","","","1230.5",""
"2025-06-05 12:35:01.000 JST",12346,"bob","mydb","127.0.0.1",54322,"myapp","AUTH","","","","","FAIL","28P01","password authentication failed for user \"bob\"","",""
```

---

## 監査対象イベント

| イベント | フック | 対象操作 |
|---------|--------|----------|
| `DDL` | `ProcessUtility_hook` | CREATE / ALTER / DROP / TRUNCATE / COMMENT 等 |
| `DML` | `ExecutorStart_hook` + `ExecutorEnd_hook` | SELECT / INSERT / UPDATE / DELETE / MERGE |
| `PRIVILEGE` | `ProcessUtility_hook` | GRANT / REVOKE / SET ROLE / SET SESSION AUTHORIZATION |
| `AUTH` | `ClientAuthentication_hook` | 認証成功・失敗 |
| `CONNECT` | `ClientAuthentication_hook`（認証成功後） | セッション接続確立 |
| `DISCONNECT` | `on_proc_exit()` コールバック | セッション終了（セッション継続時間を `duration_ms` に記録） |
| `ERROR` | `emit_log_hook` | 設定した重大度以上のエラー |

## Audited Event Types

| Event | Hook | Operations |
|-------|------|------------|
| `DDL` | `ProcessUtility_hook` | CREATE / ALTER / DROP / TRUNCATE / COMMENT etc. |
| `DML` | `ExecutorStart_hook` + `ExecutorEnd_hook` | SELECT / INSERT / UPDATE / DELETE / MERGE |
| `PRIVILEGE` | `ProcessUtility_hook` | GRANT / REVOKE / SET ROLE / SET SESSION AUTHORIZATION |
| `AUTH` | `ClientAuthentication_hook` | Authentication success and failure |
| `CONNECT` | `ClientAuthentication_hook` (on success) | Session connection established |
| `DISCONNECT` | `on_proc_exit()` callback | Session end (session duration recorded in `duration_ms`) |
| `ERROR` | `emit_log_hook` | Errors at or above the configured severity |

---

## 出力フィールド（17列）

CSV のカラム順（JSON / text でも同じフィールドが出力される）:

| # | フィールド名 | 内容 | 備考 |
|---|------------|------|------|
| 1 | `timestamp` | タイムスタンプ（マイクロ秒精度、ISO 8601） | 常に記録 |
| 2 | `pid` | バックエンドプロセス ID | 常に記録 |
| 3 | `user_name` | ユーザー名 | 常に記録 |
| 4 | `database_name` | データベース名 | 常に記録 |
| 5 | `client_addr` | クライアント IP アドレス | 常に記録 |
| 6 | `client_port` | クライアントポート番号 | 常に記録 |
| 7 | `application_name` | クライアントアプリ名 | 常に記録 |
| 8 | `event_type` | イベント種別 | 常に記録 |
| 9 | `command_tag` | コマンドタグ（`SELECT`, `CREATE TABLE` 等） | 常に記録 |
| 10 | `object_type` | オブジェクト種別（`TABLE`, `INDEX` 等） | DDL/DML のみ |
| 11 | `object_name` | オブジェクト名（`schema.name` 形式） | DDL/DML のみ |
| 12 | `query_text` | SQL 文テキスト | `log_query_text = off` で省略可 |
| 13 | `result` | 実行結果（`OK` / `FAIL`） | 常に記録 |
| 14 | `error_code` | SQLSTATE コード（例: `28P01`） | 失敗時のみ |
| 15 | `error_message` | エラーメッセージ | 失敗時のみ |
| 16 | `duration_ms` | 実行時間（ミリ秒） | DDL / DML のみ |
| 17 | `rows_affected` | 影響行数 | INSERT / UPDATE / DELETE / MERGE のみ |

## Output Fields (17 columns)

Column order in CSV output (JSON and text formats include the same fields):

| # | Field | Description | Notes |
|---|-------|-------------|-------|
| 1 | `timestamp` | Timestamp (microsecond precision, ISO 8601) | Always present |
| 2 | `pid` | Backend process ID | Always present |
| 3 | `user_name` | User name | Always present |
| 4 | `database_name` | Database name | Always present |
| 5 | `client_addr` | Client IP address | Always present |
| 6 | `client_port` | Client port number | Always present |
| 7 | `application_name` | Client application name | Always present |
| 8 | `event_type` | Event type | Always present |
| 9 | `command_tag` | Command tag (`SELECT`, `CREATE TABLE`, etc.) | Always present |
| 10 | `object_type` | Object type (`TABLE`, `INDEX`, etc.) | DDL/DML only |
| 11 | `object_name` | Object name (`schema.name` form) | DDL/DML only |
| 12 | `query_text` | SQL statement text | Omitted when `log_query_text = off` |
| 13 | `result` | Execution result (`OK` / `FAIL`) | Always present |
| 14 | `error_code` | SQLSTATE code (e.g. `28P01`) | Failure only |
| 15 | `error_message` | Error message | Failure only |
| 16 | `duration_ms` | Execution time in milliseconds | DDL / DML only |
| 17 | `rows_affected` | Number of rows affected | INSERT / UPDATE / DELETE / MERGE only |

---

## GUC パラメータ

すべて `PGC_SIGHUP`（`SELECT pg_reload_conf()` でオンライン反映）。

| パラメータ | 型 | デフォルト | 説明 |
|-----------|-----|-----------|------|
| `pg_bigeye.log_directory` | string | `pg_audit_log` | 出力ディレクトリ（相対パスは `$PGDATA` 基準） |
| `pg_bigeye.log_filename` | string | `audit.log` | `%` なし → 固定名モード、`%` あり → strftime パターン |
| `pg_bigeye.log_rotation_age` | int (分) | `1440` | 時間ベースのローテーション間隔（`0` で無効） |
| `pg_bigeye.log_rotation_size` | int (kB) | `102400` | サイズベースのローテーション閾値（`0` で無効） |
| `pg_bigeye.log_format` | enum | `csv` | `csv` / `json` / `text` |
| `pg_bigeye.log_statements` | enum | `ddl` | `none` / `ddl` / `dml` / `all` |
| `pg_bigeye.log_errors` | enum | `error` | `none` / `debug5`〜`panic` |
| `pg_bigeye.log_auth` | bool | `on` | AUTH / CONNECT / DISCONNECT を記録するか |
| `pg_bigeye.log_query_text` | bool | `on` | SQL テキストを含めるか |
| `pg_bigeye.log_query_max_length` | int | `0` | query_text の最大文字数（`0` = 無制限） |
| `pg_bigeye.exclude_roles` | string | `''` | 監査除外ロール名（カンマ区切り） |

## GUC Parameters

All parameters are `PGC_SIGHUP` — reloaded online with `SELECT pg_reload_conf()`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pg_bigeye.log_directory` | string | `pg_audit_log` | Output directory (relative paths are under `$PGDATA`) |
| `pg_bigeye.log_filename` | string | `audit.log` | No `%` → fixed-name mode; with `%` → strftime pattern |
| `pg_bigeye.log_rotation_age` | int (min) | `1440` | Time-based rotation interval (`0` to disable) |
| `pg_bigeye.log_rotation_size` | int (kB) | `102400` | Size-based rotation threshold (`0` to disable) |
| `pg_bigeye.log_format` | enum | `csv` | `csv` / `json` / `text` |
| `pg_bigeye.log_statements` | enum | `ddl` | `none` / `ddl` / `dml` / `all` |
| `pg_bigeye.log_errors` | enum | `error` | `none` / `debug5` through `panic` |
| `pg_bigeye.log_auth` | bool | `on` | Whether to record AUTH / CONNECT / DISCONNECT events |
| `pg_bigeye.log_query_text` | bool | `on` | Whether to include SQL text |
| `pg_bigeye.log_query_max_length` | int | `0` | Maximum length of `query_text` (`0` = unlimited) |
| `pg_bigeye.exclude_roles` | string | `''` | Comma-separated list of roles to exclude from auditing |

---

## ファイルローテーション

`log_filename` に `%` を含めるかどうかで動作が変わります。

### 固定名モード（推奨・デフォルト）

```
pg_bigeye.log_filename = 'audit.log'   # デフォルト
```

アクティブファイルは常に `audit.log`。ローテーション時は旧ファイルを `audit.log.YYYY-MM-DD_HHMMSS` にリネームして新しい `audit.log` を開きます。Fluentd の `tail` プラグインや Filebeat のように **ファイル名が固定されていることを前提にしたログ収集ツール**と相性が良いモードです。

```
pg_audit_log/
├── audit.log                        ← 書き込み中（常にこの名前）
├── audit.log.2025-06-04_000000      ← ローテーション済み
└── audit.log.2025-06-03_000000      ← ローテーション済み
```

### パターン名モード

```
pg_bigeye.log_filename = 'audit-%Y-%m-%d.log'
```

ローテーション時に `strftime` でファイル名を展開して新規ファイルを開きます。

```
pg_audit_log/
├── audit-2025-06-05.log    ← 書き込み中
└── audit-2025-06-04.log    ← ローテーション済み
```

## File Rotation

Behavior depends on whether `log_filename` contains a `%` character.

### Fixed-name mode (recommended, default)

```
pg_bigeye.log_filename = 'audit.log'   # default
```

The active file is always named `audit.log`. On rotation, the old file is renamed to `audit.log.YYYY-MM-DD_HHMMSS` and a new `audit.log` is opened. This mode works well with log collectors such as Fluentd `tail` or Filebeat that **expect a fixed filename**.

```
pg_audit_log/
├── audit.log                        ← currently active (always this name)
├── audit.log.2025-06-04_000000      ← rotated
└── audit.log.2025-06-03_000000      ← rotated
```

### Pattern-name mode

```
pg_bigeye.log_filename = 'audit-%Y-%m-%d.log'
```

On rotation, the filename is expanded with `strftime` and a new file is opened.

```
pg_audit_log/
├── audit-2025-06-05.log    ← currently active
└── audit-2025-06-04.log    ← rotated
```

---

## 出力フォーマット

### CSV（デフォルト）

17 列 RFC 4180 準拠の CSV。文字列フィールドはすべてダブルクォートで囲まれ、内部の `"` は `""` にエスケープされます。

```csv
"timestamp",pid,"user_name","database_name","client_addr",client_port,"application_name","event_type","command_tag","object_type","object_name","query_text","result","error_code","error_message",duration_ms,rows_affected
```

### JSON

1 エントリ 1 行の NDJSON 形式。`null` はフィールドが該当しないことを示します。

```json
{"timestamp":"2025-06-05 12:34:57.001 JST","pid":12345,"user_name":"alice","database_name":"mydb","client_addr":"127.0.0.1","client_port":54321,"application_name":"psql","event_type":"DML","command_tag":"INSERT","object_type":"TABLE","object_name":"public.t1","query_text":"INSERT INTO t1 VALUES (1);","result":"OK","error_code":null,"error_message":null,"duration_ms":5.200,"rows_affected":1}
```

### text

人間が読みやすいラベル付き形式。デバッグや目視確認に適しています。

```
2025-06-05 12:34:57.001 JST [12345] alice@mydb DML:INSERT INSERT INTO t1 VALUES (1); result=OK object=public.t1 duration=5.200ms rows=1
```

## Output Formats

### CSV (default)

17-column RFC 4180 CSV. All string fields are double-quoted; embedded `"` characters are escaped as `""`.

```csv
"timestamp",pid,"user_name","database_name","client_addr",client_port,"application_name","event_type","command_tag","object_type","object_name","query_text","result","error_code","error_message",duration_ms,rows_affected
```

### JSON

One entry per line (NDJSON). `null` indicates the field is not applicable for that event.

```json
{"timestamp":"2025-06-05 12:34:57.001 JST","pid":12345,"user_name":"alice","database_name":"mydb","client_addr":"127.0.0.1","client_port":54321,"application_name":"psql","event_type":"DML","command_tag":"INSERT","object_type":"TABLE","object_name":"public.t1","query_text":"INSERT INTO t1 VALUES (1);","result":"OK","error_code":null,"error_message":null,"duration_ms":5.200,"rows_affected":1}
```

### text

Human-readable labeled format, useful for manual inspection and debugging.

```
2025-06-05 12:34:57.001 JST [12345] alice@mydb DML:INSERT INSERT INTO t1 VALUES (1); result=OK object=public.t1 duration=5.200ms rows=1
```

---

## セキュリティ

- ログファイルのパーミッション: `0600`（オーナーのみ読み書き）
- ログディレクトリのパーミッション: `0700`（自動作成）
- 監査ログ書き込み失敗は `WARNING` に留め、クライアントのクエリを失敗させない
- autovacuum worker と Parallel Worker は監査対象外（意図的除外）

## Security

- Log file permissions: `0600` (owner read/write only)
- Log directory permissions: `0700` (created automatically)
- Audit log write failures are downgraded to `WARNING`; client queries are never aborted
- autovacuum workers and Parallel Workers are intentionally excluded from auditing

---

## 複数バックエンドからの同時書き込み

各バックエンドが直接ファイルに書き込む方式を採用しています（syslogger 経由なし）。

- `O_WRONLY | O_CREAT | O_APPEND` でオープン（POSIX 環境では `O_APPEND` + `write()` はアトミック）
- `flock(2)` による排他ロックで NFS 等の非 POSIX 環境にも対応
- ローテーション判定とファイル開時刻の管理に **共有メモリ**（`ShmemCallbacks` / `LWLock`）を使用

## Concurrent Writes from Multiple Backends

Each backend writes directly to the audit file without going through a central syslogger process.

- Files are opened with `O_WRONLY | O_CREAT | O_APPEND` (`O_APPEND` + `write()` is atomic on POSIX)
- `flock(2)` exclusive locking provides safety on non-POSIX filesystems such as NFS
- Rotation state and file open time are managed in **shared memory** (`ShmemCallbacks` / `LWLock`)

---

## テスト

```bash
PATH=/path/to/pg19/bin:$PATH bash t/run_tests.sh
```

62 件の TAP テストが実行されます（対象: 全7カテゴリのイベント、出力フィールド、GUC パラメータ、ファイルローテーション、フォーマット、並行書き込み、特殊文字）。

## Tests

```bash
PATH=/path/to/pg19/bin:$PATH bash t/run_tests.sh
```

62 TAP tests are executed, covering all 7 event categories, output fields, GUC parameters, file rotation, formats, concurrent writes, and special characters.

```
ok 1 - TC-047: log_directory created automatically on startup
ok 2 - TC-045: audit.log permissions are 0600
...
ok 61 - TC-073: very long SQL logged without crash
ok 62 - TC-062: extension still running after autovacuum activity
1..62
# Results: 61 passed, 0 failed out of 62 tests
```

---

## ライセンス

PostgreSQL License（[LICENSE](LICENSE) 参照）

## License

PostgreSQL License — see [LICENSE](LICENSE).

---

## 将来の予定（V2 以降）

- テーブル・スキーマ単位の粒度制御
- 改ざん検知チェックサム
- リモート syslog / Fluentd 転送
- 行レベルの変更前後値（OLD / NEW）の記録

## Roadmap (v2+)

- Per-table and per-schema granularity controls
- Tamper-detection checksums
- Remote syslog / Fluentd forwarding
- Row-level OLD / NEW value recording
