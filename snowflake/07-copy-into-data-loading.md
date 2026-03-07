# COPY INTO & Data Loading Patterns

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [COPY INTO Table Syntax](#copy-into-table-syntax)
2. [File Format Options](#file-format-options)
3. [COPY Options](#copy-options)
4. [Loading from Stages](#loading-from-stages)
5. [Loading from External Locations Directly](#loading-from-external-locations-directly)
6. [Transformation During Load](#transformation-during-load)
7. [Load Metadata Columns](#load-metadata-columns)
8. [Load History](#load-history)
9. [Validation with VALIDATE Function](#validation-with-validate-function)
10. [Best Practices for Data Loading Performance](#best-practices-for-data-loading-performance)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## COPY INTO Table Syntax

The `COPY INTO <table>` command is Snowflake's primary mechanism for bulk-loading data from staged files into tables. It supports loading from internal stages, external stages, and direct external locations.

### Basic Syntax

```sql
COPY INTO <table_name>
  FROM { internalStage | externalStage | externalLocation }
  [ FILES = ( '<file_name>' [ , '<file_name>' ... ] ) ]
  [ PATTERN = '<regex_pattern>' ]
  [ FILE_FORMAT = ( { FORMAT_NAME = '<file_format_name>' |
                       TYPE = { CSV | JSON | AVRO | ORC | PARQUET | XML } } ) ]
  [ <copy_options> ]
  [ VALIDATION_MODE = RETURN_<n>_ROWS | RETURN_ERRORS | RETURN_ALL_ERRORS ];
```

### Minimal Examples

```sql
-- Load from a named internal stage
COPY INTO my_table
  FROM @my_internal_stage;

-- Load from a named external stage
COPY INTO my_table
  FROM @my_s3_stage/path/to/files/;

-- Load specific files
COPY INTO my_table
  FROM @my_stage
  FILES = ('data_2026_01.csv', 'data_2026_02.csv');

-- Load files matching a pattern
COPY INTO my_table
  FROM @my_stage
  PATTERN = '.*2026.*[.]csv';
```

### Key Behaviors

- **Idempotent by Default**: Snowflake tracks which files have been loaded via load metadata. Re-running the same COPY INTO will skip already-loaded files (within 64 days).
- **Atomic**: Each COPY INTO statement is atomic per file -- if a file fails (depending on ON_ERROR), successfully loaded files are committed.
- **Parallel Execution**: Snowflake automatically parallelizes loading across available compute nodes in the warehouse.

---

## File Format Options

File formats define how Snowflake parses source data. You can specify them inline or reference a named file format object.

### Creating Named File Formats

```sql
-- CSV file format
CREATE OR REPLACE FILE FORMAT my_csv_format
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  NULL_IF = ('NULL', 'null', '')
  EMPTY_FIELD_AS_NULL = TRUE
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ESCAPE = 'NONE'
  ESCAPE_UNENCLOSED_FIELD = '\\'
  DATE_FORMAT = 'YYYY-MM-DD'
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS'
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE;

-- JSON file format
CREATE OR REPLACE FILE FORMAT my_json_format
  TYPE = 'JSON'
  COMPRESSION = 'AUTO'
  STRIP_OUTER_ARRAY = TRUE
  STRIP_NULL_VALUES = FALSE
  IGNORE_UTF8_ERRORS = FALSE
  ALLOW_DUPLICATE = FALSE;

-- Parquet file format
CREATE OR REPLACE FILE FORMAT my_parquet_format
  TYPE = 'PARQUET'
  COMPRESSION = 'SNAPPY'
  BINARY_AS_TEXT = FALSE;
```

### Inline File Format Specification

```sql
COPY INTO my_table
  FROM @my_stage
  FILE_FORMAT = (
    TYPE = 'CSV'
    FIELD_DELIMITER = '|'
    SKIP_HEADER = 1
    NULL_IF = ('\\N', '')
  );
```

### Common Format Type Options

| Format Type | Key Options |
|-------------|------------|
| **CSV** | FIELD_DELIMITER, RECORD_DELIMITER, SKIP_HEADER, FIELD_OPTIONALLY_ENCLOSED_BY, ESCAPE, NULL_IF, EMPTY_FIELD_AS_NULL, ERROR_ON_COLUMN_COUNT_MISMATCH, TRIM_SPACE |
| **JSON** | STRIP_OUTER_ARRAY, STRIP_NULL_VALUES, ALLOW_DUPLICATE, IGNORE_UTF8_ERRORS, ENABLE_OCTAL |
| **PARQUET** | COMPRESSION (SNAPPY, LZO, AUTO), BINARY_AS_TEXT, TRIM_SPACE |
| **AVRO** | COMPRESSION (AUTO, DEFLATE, SNAPPY, ZSTD), TRIM_SPACE |
| **ORC** | TRIM_SPACE, NULL_IF |

---

## COPY Options

COPY options control how the load operation behaves in terms of error handling, file management, and data matching.

### ON_ERROR

Controls what happens when an error is encountered during loading.

```sql
-- Abort the entire load on first error (default for COPY INTO)
COPY INTO my_table FROM @my_stage
  ON_ERROR = 'ABORT_STATEMENT';

-- Skip the file that contains errors
COPY INTO my_table FROM @my_stage
  ON_ERROR = 'SKIP_FILE';

-- Skip file if error count exceeds threshold
COPY INTO my_table FROM @my_stage
  ON_ERROR = 'SKIP_FILE_3';       -- Skip file if 3+ errors

COPY INTO my_table FROM @my_stage
  ON_ERROR = 'SKIP_FILE_0.5%';    -- Skip file if >0.5% rows have errors

-- Continue loading, skip individual bad rows
COPY INTO my_table FROM @my_stage
  ON_ERROR = 'CONTINUE';
```

| ON_ERROR Value | Behavior |
|----------------|----------|
| `ABORT_STATEMENT` | Default. Aborts the entire COPY operation on first error. |
| `CONTINUE` | Skips bad rows, loads everything else. |
| `SKIP_FILE` | Skips entire files that contain any error. |
| `SKIP_FILE_<n>` | Skips file if number of errors reaches `n`. |
| `SKIP_FILE_<n>%` | Skips file if percentage of error rows exceeds `n%`. |

### SIZE_LIMIT

Limits the total amount of data loaded (in bytes). The COPY command stops loading after the threshold is exceeded (it finishes the current file).

```sql
COPY INTO my_table FROM @my_stage
  SIZE_LIMIT = 5368709120;  -- ~5 GB limit
```

### PURGE

Automatically deletes staged files after successful loading.

```sql
COPY INTO my_table FROM @my_stage
  PURGE = TRUE;
```

> **Note**: PURGE is best-effort. If the load succeeds but the purge fails, the files remain. Use with caution in production -- consider managing file cleanup separately.

### FORCE

Forces reloading of files that have already been loaded (bypasses the 64-day load metadata tracking).

```sql
COPY INTO my_table FROM @my_stage
  FORCE = TRUE;
```

> **Warning**: Using FORCE can result in duplicate data if files were previously loaded successfully.

### MATCH_BY_COLUMN_NAME

Matches columns in semi-structured data files (Parquet, JSON, Avro, ORC) to table columns by name rather than by position.

```sql
-- Match Parquet columns to table columns by name (case-insensitive)
COPY INTO my_table FROM @my_stage
  FILE_FORMAT = (TYPE = 'PARQUET')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Case-sensitive matching
COPY INTO my_table FROM @my_stage
  FILE_FORMAT = (TYPE = 'PARQUET')
  MATCH_BY_COLUMN_NAME = CASE_SENSITIVE;
```

| Value | Behavior |
|-------|----------|
| `NONE` | Default. Columns matched by position. |
| `CASE_SENSITIVE` | Match by exact column name. |
| `CASE_INSENSITIVE` | Match by column name, ignoring case. |

### Other Notable COPY Options

```sql
COPY INTO my_table FROM @my_stage
  RETURN_FAILED_ONLY = TRUE       -- Only return rows for files that had errors
  ENFORCE_LENGTH = TRUE            -- Enforce VARCHAR length constraints
  TRUNCATECOLUMNS = TRUE           -- Truncate strings that exceed target column length
  LOAD_UNCERTAIN_FILES = TRUE;     -- Re-evaluate files with uncertain load status
```

---

## Loading from Stages

### Internal Stages

Snowflake provides three types of internal stages:

```sql
-- User stage (each user has one automatically, prefixed with @~)
PUT file:///tmp/data/sales.csv @~;
COPY INTO my_table FROM @~/sales.csv;

-- Table stage (each table has one automatically, prefixed with @%<table>)
PUT file:///tmp/data/sales.csv @%my_table;
COPY INTO my_table FROM @%my_table;

-- Named internal stage
CREATE OR REPLACE STAGE my_internal_stage
  FILE_FORMAT = my_csv_format;

PUT file:///tmp/data/sales.csv @my_internal_stage;
COPY INTO my_table FROM @my_internal_stage;
```

### External Stages

```sql
-- S3 external stage
CREATE OR REPLACE STAGE my_s3_stage
  URL = 's3://my-bucket/path/'
  STORAGE_INTEGRATION = my_s3_integration
  FILE_FORMAT = my_csv_format;

COPY INTO my_table FROM @my_s3_stage;

-- Azure external stage
CREATE OR REPLACE STAGE my_azure_stage
  URL = 'azure://myaccount.blob.core.windows.net/mycontainer/path/'
  STORAGE_INTEGRATION = my_azure_integration
  FILE_FORMAT = my_csv_format;

COPY INTO my_table FROM @my_azure_stage;

-- GCS external stage
CREATE OR REPLACE STAGE my_gcs_stage
  URL = 'gcs://my-bucket/path/'
  STORAGE_INTEGRATION = my_gcs_integration
  FILE_FORMAT = my_csv_format;

COPY INTO my_table FROM @my_gcs_stage;
```

---

## Loading from External Locations Directly

You can reference external cloud storage directly without creating a stage object, though this is generally not recommended for production use.

```sql
-- Direct S3 load with credentials
COPY INTO my_table
  FROM 's3://my-bucket/data/'
  CREDENTIALS = (AWS_KEY_ID = '...' AWS_SECRET_KEY = '...')
  FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);

-- Direct Azure load
COPY INTO my_table
  FROM 'azure://myaccount.blob.core.windows.net/container/data/'
  CREDENTIALS = (AZURE_SAS_TOKEN = '...')
  FILE_FORMAT = (TYPE = 'PARQUET');
```

> **Best Practice**: Always use storage integrations and named stages in production. Direct credentials in SQL statements are a security risk and are harder to maintain.

---

## Transformation During Load

One of Snowflake's powerful features is the ability to transform data during the COPY INTO operation using a SELECT statement. This avoids needing a staging table for many use cases.

### Column Reordering and Selection

```sql
-- Select and reorder columns from a CSV
COPY INTO target_table (col_a, col_b, col_c)
  FROM (
    SELECT $3, $1, $2
    FROM @my_stage/data.csv
  )
  FILE_FORMAT = (TYPE = 'CSV');
```

### Type Casting

```sql
COPY INTO orders (order_id, order_date, amount, customer_id)
  FROM (
    SELECT
      $1::INTEGER,
      TO_DATE($2, 'MM/DD/YYYY'),
      $3::DECIMAL(12,2),
      $4::INTEGER
    FROM @my_stage
  )
  FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

### Using Functions and Expressions

```sql
COPY INTO customers (full_name, email, created_at, source_file)
  FROM (
    SELECT
      TRIM($1) || ' ' || TRIM($2),
      LOWER(TRIM($3)),
      CURRENT_TIMESTAMP(),
      METADATA$FILENAME
    FROM @my_stage
  )
  FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

### Loading Semi-Structured Data with Flattening

```sql
-- Load specific fields from JSON into a relational table
COPY INTO events (event_id, event_type, user_id, event_time)
  FROM (
    SELECT
      $1:event_id::VARCHAR,
      $1:event_type::VARCHAR,
      $1:user.id::INTEGER,
      $1:timestamp::TIMESTAMP_NTZ
    FROM @my_json_stage
  )
  FILE_FORMAT = (TYPE = 'JSON');
```

### Limitations of SELECT in COPY

- No JOIN operations
- No GROUP BY or aggregation
- No subqueries
- No FLATTEN (you can access nested fields with colon notation, but full FLATTEN is not supported in COPY)
- Supported: column selection, reordering, casting, simple functions, METADATA columns

---

## Load Metadata Columns

Snowflake provides special metadata columns that give you information about the source files during loading. These are extremely useful for auditing and lineage.

### Positional References ($1, $2, ...)

For delimited files (CSV), columns are referenced by ordinal position:

```sql
-- $1 = first column, $2 = second column, etc.
SELECT $1, $2, $3 FROM @my_stage/data.csv (FILE_FORMAT => 'my_csv_format');
```

For semi-structured files (JSON, Parquet), `$1` refers to the entire record:

```sql
-- Access fields within a JSON record
SELECT $1:name, $1:age, $1:address.city FROM @my_stage/data.json;
```

### METADATA$FILENAME

Returns the name (path) of the staged file being loaded.

```sql
COPY INTO audit_table (data_col, source_file)
  FROM (
    SELECT $1, METADATA$FILENAME
    FROM @my_stage
  )
  FILE_FORMAT = (TYPE = 'CSV');
```

### METADATA$FILE_ROW_NUMBER

Returns the row number within the file for each record.

```sql
COPY INTO audit_table (data_col, source_file, file_row_num)
  FROM (
    SELECT $1, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER
    FROM @my_stage
  )
  FILE_FORMAT = (TYPE = 'CSV');
```

### METADATA$FILE_CONTENT_KEY

Returns a unique hash of the staged file content (useful for deduplication tracking).

### METADATA$FILE_LAST_MODIFIED

Returns the last modified timestamp of the staged file.

### METADATA$START_SCAN_TIME

Returns the timestamp when Snowflake started scanning the file.

### Real-World Audit Pattern

```sql
CREATE OR REPLACE TABLE raw_sales (
  sale_id         INTEGER,
  product_id      INTEGER,
  quantity         INTEGER,
  amount           DECIMAL(12,2),
  sale_date        DATE,
  _source_file     VARCHAR,
  _file_row_number INTEGER,
  _loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

COPY INTO raw_sales (sale_id, product_id, quantity, amount, sale_date, _source_file, _file_row_number)
  FROM (
    SELECT
      $1::INTEGER,
      $2::INTEGER,
      $3::INTEGER,
      $4::DECIMAL(12,2),
      TO_DATE($5, 'YYYY-MM-DD'),
      METADATA$FILENAME,
      METADATA$FILE_ROW_NUMBER
    FROM @sales_stage
  )
  FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

---

## Load History

Snowflake tracks the history of all COPY INTO operations, providing visibility into what was loaded, when, and whether errors occurred.

### COPY_HISTORY Table Function

The `INFORMATION_SCHEMA.COPY_HISTORY` table function returns load activity for the last 14 days.

```sql
-- Query load history for a specific table
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(HOURS, -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- Check for files with errors
SELECT
  FILE_NAME,
  STATUS,
  ROWS_PARSED,
  ROWS_LOADED,
  ERROR_COUNT,
  FIRST_ERROR_MESSAGE,
  FIRST_ERROR_LINE_NUM,
  FIRST_ERROR_CHARACTER_POS
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(DAYS, -7, CURRENT_TIMESTAMP())
))
WHERE STATUS = 'LOAD_FAILED'
ORDER BY LAST_LOAD_TIME DESC;
```

### LOAD_HISTORY View (Account Usage)

The `SNOWFLAKE.ACCOUNT_USAGE.LOAD_HISTORY` view provides load history with up to 365 days of retention (with up to 2-hour latency).

```sql
-- Long-term load history analysis
SELECT
  TABLE_NAME,
  SCHEMA_NAME,
  FILE_NAME,
  LAST_LOAD_TIME,
  STATUS,
  ROW_COUNT,
  ROW_PARSED,
  FIRST_ERROR_MESSAGE
FROM SNOWFLAKE.ACCOUNT_USAGE.LOAD_HISTORY
WHERE LAST_LOAD_TIME >= DATEADD(DAYS, -30, CURRENT_TIMESTAMP())
  AND TABLE_NAME = 'MY_TABLE'
ORDER BY LAST_LOAD_TIME DESC;
```

### Key Differences

| Feature | COPY_HISTORY (Info Schema) | LOAD_HISTORY (Account Usage) |
|---------|---------------------------|------------------------------|
| Retention | 14 days | 365 days |
| Latency | Near real-time | Up to 2 hours |
| Scope | Specific database | Entire account |
| Access | Database-level privilege | SNOWFLAKE shared database access |

---

## Validation with VALIDATE Function

The `VALIDATE` function lets you inspect errors from a previous COPY INTO operation, or you can use `VALIDATION_MODE` to dry-run a load before committing.

### VALIDATION_MODE (Dry Run)

```sql
-- Return the first 10 rows without actually loading
COPY INTO my_table FROM @my_stage
  FILE_FORMAT = my_csv_format
  VALIDATION_MODE = 'RETURN_10_ROWS';

-- Return all errors without loading any data
COPY INTO my_table FROM @my_stage
  FILE_FORMAT = my_csv_format
  VALIDATION_MODE = 'RETURN_ERRORS';

-- Return all errors across all files
COPY INTO my_table FROM @my_stage
  FILE_FORMAT = my_csv_format
  VALIDATION_MODE = 'RETURN_ALL_ERRORS';
```

> **Important**: When VALIDATION_MODE is specified, no data is actually loaded. This is strictly a validation/preview mechanism.

### VALIDATE Function (Post-Load Error Inspection)

```sql
-- Get errors from the last COPY INTO execution using the query ID
SELECT *
FROM TABLE(VALIDATE(my_table, JOB_ID => '<query_id>'));

-- Use LAST_QUERY_ID() for the most recent operation
COPY INTO my_table FROM @my_stage
  ON_ERROR = 'CONTINUE';

SELECT *
FROM TABLE(VALIDATE(my_table, JOB_ID => LAST_QUERY_ID()));
```

The VALIDATE function returns columns including:
- `ERROR` -- the error message
- `FILE` -- the source file name
- `LINE` -- the line number in the file
- `CHARACTER` -- the character position of the error
- `BYTE_OFFSET` -- byte offset in the file
- `CATEGORY` -- error category
- `CODE` -- error code
- `COLUMN_NAME` -- the column that caused the error
- `ROW_NUMBER` -- the row number in the file
- `ROW_START_LINE` -- starting line of the problematic row
- `REJECTED_RECORD` -- the raw rejected record content

---

## Best Practices for Data Loading Performance

### 1. File Sizing

Aim for compressed files between **100 MB and 250 MB** each. This allows Snowflake to distribute load across multiple nodes efficiently.

```sql
-- If you have very large files, use SIZE_LIMIT or pre-split them
-- If you have many small files, combine them before staging
```

### 2. Use Appropriate Warehouse Size

- More files benefit from larger warehouses (more nodes = more parallel file processing).
- A small number of large files may not benefit from a very large warehouse.
- Each node processes one or more files independently.

### 3. Prefer Columnar Formats

Parquet is generally faster than CSV for loading because:
- It includes schema information
- It supports efficient compression
- Snowflake can leverage column pruning

### 4. Compress Your Files

Snowflake supports automatic detection and decompression of GZIP, BZ2, DEFLATE, RAW_DEFLATE, ZSTD, and SNAPPY. Always compress files before staging.

### 5. Dedicated Loading Warehouse

Use a separate warehouse for data loading to avoid contention with query workloads.

```sql
CREATE WAREHOUSE loading_wh
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

USE WAREHOUSE loading_wh;
COPY INTO my_table FROM @my_stage;
```

### 6. Avoid FORCE = TRUE

Repeated use of FORCE can cause duplicates. Prefer idempotent loading patterns.

### 7. Organize Stage Paths by Date

```
s3://my-bucket/data/year=2026/month=01/day=15/
```

This allows you to load selectively using path patterns:

```sql
COPY INTO my_table FROM @my_stage/year=2026/month=01/
  PATTERN = '.*[.]parquet';
```

### 8. Use MATCH_BY_COLUMN_NAME for Schema Evolution

When loading Parquet or other semi-structured formats, use MATCH_BY_COLUMN_NAME to handle column ordering differences across file versions.

### 9. Pre-Sort Data (When Possible)

If data is sorted by the clustering key before loading, Snowflake can build more efficient micro-partitions, improving query performance on the loaded table.

### 10. Monitor and Retry

```sql
-- Check what files failed
SELECT FILE_NAME, FIRST_ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(HOURS, -1, CURRENT_TIMESTAMP())
))
WHERE STATUS != 'LOADED';
```

---

## Common Interview Questions

### Q1: What happens if you run the same COPY INTO command twice?

**Answer**: By default, Snowflake tracks which files have been loaded using load metadata (stored for 64 days). Running the same COPY INTO again will skip files that have already been loaded successfully. This makes COPY INTO idempotent by default. To force reloading, you must use `FORCE = TRUE`, but this risks creating duplicate data.

---

### Q2: What is the difference between ON_ERROR = 'CONTINUE' and ON_ERROR = 'SKIP_FILE'?

**Answer**: `CONTINUE` skips individual erroneous rows and loads all valid rows from every file. `SKIP_FILE` skips the entire file if it contains any error, meaning even valid rows in that file are not loaded. `SKIP_FILE` is more conservative and is useful when data integrity within a file must be all-or-nothing.

---

### Q3: How do you handle schema changes in source files when loading Parquet data?

**Answer**: Use `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE` (or `CASE_SENSITIVE`). This matches source file columns to target table columns by name, not position. If the source file has extra columns, they are ignored. If the target table has extra columns, they receive NULL. This provides resilience against column ordering changes and partial schema evolution.

---

### Q4: What is the purpose of VALIDATION_MODE and when would you use it?

**Answer**: VALIDATION_MODE performs a dry run of the COPY INTO without actually loading data. `RETURN_ROWS` previews data, `RETURN_ERRORS` and `RETURN_ALL_ERRORS` identify problematic records before committing. Use it in development, testing new file formats, or debugging load failures -- especially when loading from a new data source for the first time.

---

### Q5: How do METADATA columns help in a production data pipeline?

**Answer**: METADATA$FILENAME and METADATA$FILE_ROW_NUMBER enable data lineage tracking by recording exactly which file and row each record originated from. This is critical for debugging data quality issues, auditing, reprocessing specific files, and building reconciliation reports. METADATA$FILE_CONTENT_KEY enables deduplication, and METADATA$FILE_LAST_MODIFIED helps track data freshness.

---

### Q6: What is the recommended file size for optimal COPY INTO performance and why?

**Answer**: Snowflake recommends compressed files between 100 MB and 250 MB. This is because each node in the warehouse processes files independently. Files that are too small (e.g., 1 MB) create overhead from processing too many files and underutilize compute. Files that are too large cannot be distributed across multiple nodes effectively. The sweet spot allows maximum parallelism across the warehouse cluster.

---

### Q7: How would you reload data for a specific date partition after discovering a data quality issue?

**Answer**:
1. Delete the bad data: `DELETE FROM my_table WHERE load_date = '2026-01-15'`
2. Re-load with FORCE (since the files were already loaded):
```sql
COPY INTO my_table
  FROM @my_stage/year=2026/month=01/day=15/
  FORCE = TRUE
  FILE_FORMAT = my_format;
```
Alternatively, use a staging table pattern: load into a temp table, validate, then MERGE or INSERT into the target.

---

### Q8: Explain the difference between COPY_HISTORY and LOAD_HISTORY.

**Answer**: `INFORMATION_SCHEMA.COPY_HISTORY` is a table function scoped to a specific database with 14 days of retention and near real-time latency. `SNOWFLAKE.ACCOUNT_USAGE.LOAD_HISTORY` is a view with account-wide scope, 365 days of retention, but up to 2 hours of latency. Use COPY_HISTORY for operational monitoring and LOAD_HISTORY for long-term analysis and compliance reporting.

---

## Tips

- **Always test with VALIDATION_MODE first** when loading from a new source or after format changes. It is much cheaper than loading, finding errors, and reloading.
- **Track source file metadata** (METADATA$FILENAME, METADATA$FILE_ROW_NUMBER) in every raw/landing table. This investment pays dividends when debugging data issues months later.
- **Use named file format objects** instead of inline specifications. This centralizes format definitions, makes them reusable, and simplifies maintenance.
- **Size your warehouse based on file count**, not data volume alone. More files benefit from more nodes (larger warehouse), while fewer large files may not.
- **Avoid PURGE = TRUE in production** unless you have a secondary copy of the source data. Instead, manage file cleanup in a separate step after confirming load success.
- **Use ON_ERROR = 'ABORT_STATEMENT' for critical loads** where partial data is worse than no data. Use 'CONTINUE' only when you have a downstream process to handle rejected records.
- **Leverage COPY transformations** to cast types and add audit columns during load, avoiding the need for an intermediate staging table when the transformations are simple.
- **Remember the 64-day metadata window**: Snowflake only tracks loaded files for 64 days. After that, re-running COPY INTO will reload those files unless the files were removed from the stage.
