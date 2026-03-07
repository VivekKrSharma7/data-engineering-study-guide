# Data Unloading & Export

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [COPY INTO Location Syntax](#copy-into-location-syntax)
2. [Unloading to Stages and External Locations](#unloading-to-stages-and-external-locations)
3. [File Format Options for Export](#file-format-options-for-export)
4. [Partitioning Output Files](#partitioning-output-files)
5. [Single File vs Multiple Files](#single-file-vs-multiple-files)
6. [MAX_FILE_SIZE](#max_file_size)
7. [HEADER Option](#header-option)
8. [OVERWRITE](#overwrite)
9. [Unloading to JSON, Parquet, and CSV](#unloading-to-json-parquet-and-csv)
10. [GET Command for Downloading](#get-command-for-downloading)
11. [Data Unloading Patterns and Performance Optimization](#data-unloading-patterns-and-performance-optimization)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## COPY INTO Location Syntax

The `COPY INTO <location>` command exports data from a Snowflake table (or query result) into files in a stage or external cloud storage location. This is the reverse of `COPY INTO <table>`.

### Basic Syntax

```sql
COPY INTO { internalStage | externalStage | externalLocation }
  FROM { <table_name> | ( <query> ) }
  [ PARTITION BY <expr> ]
  [ FILE_FORMAT = ( { FORMAT_NAME = '<name>' | TYPE = { CSV | JSON | PARQUET } } ) ]
  [ MAX_FILE_SIZE = <bytes> ]
  [ HEADER = TRUE | FALSE ]
  [ SINGLE = TRUE | FALSE ]
  [ OVERWRITE = TRUE | FALSE ]
  [ INCLUDE_QUERY_ID = TRUE | FALSE ]
  [ DETAILED_OUTPUT = TRUE | FALSE ]
  [ <copy_options> ];
```

### Minimal Examples

```sql
-- Unload a table to a named internal stage
COPY INTO @my_internal_stage/export/
  FROM my_table;

-- Unload a query result to an external stage
COPY INTO @my_s3_stage/output/
  FROM (SELECT col1, col2, col3 FROM my_table WHERE date_col >= '2026-01-01')
  FILE_FORMAT = (TYPE = 'PARQUET');

-- Unload with a prefix
COPY INTO @my_stage/daily_export/2026/03/07/
  FROM my_table
  FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'GZIP')
  HEADER = TRUE;
```

---

## Unloading to Stages and External Locations

### Internal Stages

```sql
-- Unload to a named internal stage
COPY INTO @my_internal_stage/exports/sales/
  FROM sales_table
  FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'GZIP')
  HEADER = TRUE;

-- Unload to a user stage
COPY INTO @~/my_export/
  FROM (SELECT * FROM sales_table WHERE region = 'EMEA');

-- Unload to a table stage
COPY INTO @%sales_table/backup/
  FROM sales_table;
```

### External Stages (S3, Azure, GCS)

```sql
-- Unload to S3 via external stage
CREATE OR REPLACE STAGE my_s3_export_stage
  URL = 's3://my-export-bucket/data/'
  STORAGE_INTEGRATION = my_s3_integration
  FILE_FORMAT = (TYPE = 'PARQUET');

COPY INTO @my_s3_export_stage/sales/
  FROM sales_table;

-- Unload to Azure Blob via external stage
COPY INTO @my_azure_stage/exports/
  FROM (SELECT * FROM orders WHERE order_date >= '2026-03-01')
  FILE_FORMAT = (TYPE = 'CSV')
  HEADER = TRUE;

-- Unload to GCS via external stage
COPY INTO @my_gcs_stage/output/
  FROM my_table
  FILE_FORMAT = (TYPE = 'JSON');
```

### Direct External Locations (Without Named Stage)

```sql
-- Direct unload to S3
COPY INTO 's3://my-bucket/exports/sales/'
  FROM sales_table
  STORAGE_INTEGRATION = my_s3_integration
  FILE_FORMAT = (TYPE = 'PARQUET')
  HEADER = TRUE;

-- Direct unload to Azure
COPY INTO 'azure://myaccount.blob.core.windows.net/container/exports/'
  FROM sales_table
  CREDENTIALS = (AZURE_SAS_TOKEN = '...')
  FILE_FORMAT = (TYPE = 'CSV');
```

> **Best Practice**: Use named stages with storage integrations for production. Avoid inline credentials.

---

## File Format Options for Export

When unloading, file format options control how the output files are structured.

### CSV Export Options

```sql
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (
    TYPE = 'CSV'
    COMPRESSION = 'GZIP'              -- GZIP, BZ2, BROTLI, ZSTD, DEFLATE, RAW_DEFLATE, NONE
    FIELD_DELIMITER = ','              -- Column separator
    RECORD_DELIMITER = '\n'            -- Row separator
    ESCAPE = '\\'                      -- Escape character
    ESCAPE_UNENCLOSED_FIELD = '\\'     -- Escape for unenclosed fields
    FIELD_OPTIONALLY_ENCLOSED_BY = '"' -- Quote character
    NULL_IF = ('NULL')                 -- String representation of NULL
    EMPTY_FIELD_AS_NULL = FALSE        -- Whether empty fields become NULL
    DATE_FORMAT = 'YYYY-MM-DD'
    TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF3'
  )
  HEADER = TRUE;
```

### JSON Export Options

```sql
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (
    TYPE = 'JSON'
    COMPRESSION = 'GZIP'
  );
```

### Parquet Export Options

```sql
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (
    TYPE = 'PARQUET'
    COMPRESSION = 'SNAPPY'    -- SNAPPY, LZO, GZIP, ZSTD, NONE (default: SNAPPY)
  );
```

### Compression Options Summary

| Compression | CSV | JSON | Parquet |
|-------------|-----|------|---------|
| GZIP | Yes (default) | Yes (default) | Yes |
| SNAPPY | No | No | Yes (default) |
| ZSTD | Yes | Yes | Yes |
| BZ2 | Yes | Yes | No |
| BROTLI | Yes | Yes | No |
| LZO | No | No | Yes |
| NONE | Yes | Yes | Yes |

---

## Partitioning Output Files

The `PARTITION BY` clause organizes output files into a directory structure based on column values or expressions. This is essential for creating Hive-compatible partition layouts consumed by external tools like Spark, Athena, or Presto.

### Basic PARTITION BY

```sql
-- Partition by a column expression
COPY INTO @my_stage/sales/
  FROM sales_table
  PARTITION BY ('year=' || TO_VARCHAR(DATE_TRUNC('YEAR', sale_date), 'YYYY') ||
                '/month=' || TO_VARCHAR(DATE_TRUNC('MONTH', sale_date), 'MM'))
  FILE_FORMAT = (TYPE = 'PARQUET')
  MAX_FILE_SIZE = 268435456  -- 256 MB
  HEADER = TRUE;
```

This produces a directory structure like:

```
sales/year=2026/month=01/data_0_0_0.snappy.parquet
sales/year=2026/month=02/data_0_0_0.snappy.parquet
sales/year=2026/month=03/data_0_0_0.snappy.parquet
```

### Using a Subquery with PARTITION BY

```sql
COPY INTO @my_stage/events/
  FROM (
    SELECT
      event_id,
      event_type,
      event_time,
      payload,
      'dt=' || TO_VARCHAR(event_time, 'YYYY-MM-DD') AS partition_col
    FROM events_table
    WHERE event_time >= '2026-03-01'
  )
  PARTITION BY (partition_col)
  FILE_FORMAT = (TYPE = 'PARQUET')
  INCLUDE_QUERY_ID = FALSE;
```

### Important Notes on PARTITION BY

- The partition expression is evaluated for each row and determines the subdirectory.
- The partition column itself is **included** in the output file unless you exclude it from the SELECT.
- PARTITION BY works with CSV, JSON, and Parquet.
- When using PARTITION BY, Snowflake may generate multiple files per partition depending on data volume.

---

## Single File vs Multiple Files

By default, Snowflake generates **multiple files** during unload for parallel performance. You can control this behavior.

### Default Behavior (Multiple Files)

```sql
-- Default: multiple files, auto-sized
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (TYPE = 'CSV');

-- Produces files like:
-- output/data_0_0_0.csv.gz
-- output/data_0_1_0.csv.gz
-- output/data_0_2_0.csv.gz
-- ...
```

Multiple files are generated because Snowflake parallelizes the unload across the nodes of the warehouse. Each node writes its own output file(s).

### Single File Output

```sql
-- Force a single output file
COPY INTO @my_stage/output/report
  FROM my_table
  FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'NONE')
  SINGLE = TRUE
  HEADER = TRUE
  MAX_FILE_SIZE = 5368709120;  -- 5 GB max
```

### When to Use SINGLE = TRUE

- Producing a report file for downstream consumption by a non-distributed system.
- Creating a file that must be consumed atomically (e.g., a configuration export).
- Small datasets where parallelism is unnecessary.

### When to Avoid SINGLE = TRUE

- Large datasets (performance will be significantly worse since only one thread writes).
- Data meant for distributed processing (Spark, etc.) -- multiple files allow parallel reads.

> **Note**: When `SINGLE = TRUE`, the maximum unloaded file size is limited by the available memory on the warehouse node. For very large tables, this will fail.

---

## MAX_FILE_SIZE

Controls the maximum size (in bytes) of each output file when generating multiple files.

```sql
-- Set max file size to 256 MB
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (TYPE = 'PARQUET')
  MAX_FILE_SIZE = 268435456;  -- 256 MB

-- Set max file size to 16 MB (for many small output files)
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (TYPE = 'CSV')
  MAX_FILE_SIZE = 16777216;   -- 16 MB
```

### Default Values

| Format | Default MAX_FILE_SIZE |
|--------|----------------------|
| CSV | 16 MB |
| JSON | 16 MB |
| Parquet | 16 MB |

### Guidelines

- For **downstream Snowflake loading** (Snowpipe), target 10-100 MB.
- For **Spark/EMR consumption**, target 128-256 MB for optimal HDFS block alignment.
- For **Athena/Presto queries**, target 128 MB to balance parallelism and file overhead.
- Larger files reduce the number of output files but may limit downstream read parallelism.

---

## HEADER Option

Controls whether a header row is included in the output files.

```sql
-- Include header row (CSV only)
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (TYPE = 'CSV')
  HEADER = TRUE;
```

### Behavior by Format

| Format | HEADER Support | Default |
|--------|---------------|---------|
| CSV | Yes | FALSE |
| JSON | N/A (not applicable) | N/A |
| Parquet | N/A (schema is embedded in the file) | N/A |

### Important Notes

- When unloading to **multiple files**, each file gets its own header row. This is correct behavior since each file should be independently readable.
- The header uses the column names or aliases from the source query.

```sql
-- Control header names using aliases
COPY INTO @my_stage/output/
  FROM (
    SELECT
      customer_id AS "Customer ID",
      first_name AS "First Name",
      last_name AS "Last Name",
      email AS "Email Address"
    FROM customers
  )
  FILE_FORMAT = (TYPE = 'CSV')
  HEADER = TRUE;
```

---

## OVERWRITE

Controls whether existing files in the target location are overwritten.

```sql
-- Overwrite existing files
COPY INTO @my_stage/output/daily_report
  FROM my_table
  FILE_FORMAT = (TYPE = 'CSV')
  OVERWRITE = TRUE
  SINGLE = TRUE
  HEADER = TRUE;
```

### Behavior

| OVERWRITE Value | Behavior |
|-----------------|----------|
| `TRUE` | Replaces existing files with the same name in the target location. |
| `FALSE` (default) | If files with the same name exist, the COPY INTO generates new unique file names. Files are never deleted. |

### Considerations

- **Internal stages**: OVERWRITE applies directly. Set it to TRUE for idempotent export patterns (e.g., daily report overwrites yesterday's version).
- **External stages (cloud storage)**: OVERWRITE works, but be aware that cloud storage eventually-consistent behavior may cause brief periods where the old file is still visible.
- With `SINGLE = TRUE`, the output filename is predictable, making OVERWRITE more useful.
- With `SINGLE = FALSE`, Snowflake appends unique suffixes to filenames, so OVERWRITE is less meaningful unless you clean the directory first.

---

## Unloading to JSON, Parquet, and CSV

### Unloading to CSV

```sql
-- Standard CSV export
COPY INTO @my_stage/csv_export/
  FROM (
    SELECT
      order_id,
      customer_id,
      order_date,
      total_amount,
      status
    FROM orders
    WHERE order_date >= '2026-01-01'
  )
  FILE_FORMAT = (
    TYPE = 'CSV'
    COMPRESSION = 'GZIP'
    FIELD_DELIMITER = ','
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('')
  )
  HEADER = TRUE
  MAX_FILE_SIZE = 67108864  -- 64 MB
  OVERWRITE = TRUE;
```

### Unloading to JSON

When unloading to JSON, each row becomes a JSON object, and the output is newline-delimited JSON (NDJSON).

```sql
-- Unload to JSON
COPY INTO @my_stage/json_export/
  FROM (
    SELECT
      order_id,
      customer_id,
      order_date,
      total_amount,
      OBJECT_CONSTRUCT(
        'line_items', line_items,
        'shipping', shipping_info
      ) AS details
    FROM orders
    WHERE order_date >= '2026-03-01'
  )
  FILE_FORMAT = (TYPE = 'JSON' COMPRESSION = 'GZIP');
```

**Output format** (one JSON object per line):
```json
{"ORDER_ID":1001,"CUSTOMER_ID":42,"ORDER_DATE":"2026-03-01","TOTAL_AMOUNT":149.99,"DETAILS":{"line_items":[...],"shipping":{...}}}
{"ORDER_ID":1002,"CUSTOMER_ID":17,"ORDER_DATE":"2026-03-02","TOTAL_AMOUNT":89.50,"DETAILS":{"line_items":[...],"shipping":{...}}}
```

### Unloading to Parquet

```sql
-- Unload to Parquet
COPY INTO @my_stage/parquet_export/
  FROM (
    SELECT
      event_id,
      event_type,
      user_id,
      event_time,
      properties  -- VARIANT column
    FROM events
    WHERE event_time >= '2026-03-01'
  )
  FILE_FORMAT = (TYPE = 'PARQUET' COMPRESSION = 'SNAPPY')
  MAX_FILE_SIZE = 268435456  -- 256 MB
  HEADER = TRUE;
```

### Format Selection Guide

| Criterion | CSV | JSON | Parquet |
|-----------|-----|------|---------|
| **Human Readable** | Yes | Yes | No (binary) |
| **Schema Embedded** | No (optional header) | Implicit | Yes (full schema) |
| **Compression Ratio** | Low-Medium | Low-Medium | High |
| **Column Pruning** | No | No | Yes |
| **Nested Data** | No | Yes | Yes |
| **Downstream: Spark** | OK | OK | Best |
| **Downstream: Excel** | Best | No | No |
| **Downstream: APIs** | OK | Best | No |

---

## GET Command for Downloading

The `GET` command downloads files from an internal stage to a local file system. It only works with **internal stages** (not external stages).

### Syntax

```sql
GET <internal_stage_path> file://<local_directory>/
  [ PARALLEL = <integer> ]
  [ PATTERN = '<regex>' ];
```

### Examples

```sql
-- Download all files from a stage to local directory
GET @my_internal_stage/exports/ file:///tmp/downloads/;

-- Download with parallelism
GET @my_internal_stage/exports/ file:///tmp/downloads/
  PARALLEL = 10;

-- Download files matching a pattern
GET @my_internal_stage/exports/ file:///tmp/downloads/
  PATTERN = '.*2026-03.*[.]csv[.]gz';

-- Download from a user stage
GET @~/my_export/ file:///home/user/exports/;

-- Download from a table stage
GET @%my_table/backup/ file:///tmp/table_backup/;
```

### Key Behaviors

- **Automatic decompression is NOT performed**. Files are downloaded as-is (compressed if they were compressed).
- **PARALLEL** controls how many threads are used for download (default: 10).
- GET is a **SnowSQL / client** command -- it runs from the Snowflake client, not from SQL worksheets in the web UI.
- For **external stages**, use the cloud provider's native tools (aws s3 cp, azcopy, gsutil) instead of GET.

### Complete Unload-and-Download Pattern

```sql
-- Step 1: Unload to internal stage
COPY INTO @my_internal_stage/report/
  FROM (SELECT * FROM monthly_report WHERE month = '2026-03')
  FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'GZIP')
  SINGLE = TRUE
  HEADER = TRUE
  OVERWRITE = TRUE;

-- Step 2: Download locally
GET @my_internal_stage/report/ file:///tmp/reports/;

-- Step 3: Clean up the stage
REMOVE @my_internal_stage/report/;
```

---

## Data Unloading Patterns and Performance Optimization

### Pattern 1: Daily Partitioned Export for Data Lake

```sql
-- Export daily data into a partitioned structure for external consumption
COPY INTO @my_s3_stage/data_lake/events/
  FROM (
    SELECT
      event_id,
      event_type,
      user_id,
      event_time,
      payload,
      'dt=' || TO_VARCHAR(event_time::DATE, 'YYYY-MM-DD') AS dt
    FROM events
    WHERE event_time BETWEEN '2026-03-01' AND '2026-03-07'
  )
  PARTITION BY (dt)
  FILE_FORMAT = (TYPE = 'PARQUET' COMPRESSION = 'SNAPPY')
  MAX_FILE_SIZE = 268435456  -- 256 MB
  OVERWRITE = TRUE;
```

### Pattern 2: Incremental Export with Change Tracking

```sql
-- Export only changed records since last export
COPY INTO @my_stage/incremental/
  FROM (
    SELECT *
    FROM my_table
    WHERE updated_at > (SELECT MAX(last_export_time) FROM export_log)
  )
  FILE_FORMAT = (TYPE = 'PARQUET')
  DETAILED_OUTPUT = TRUE;

-- DETAILED_OUTPUT = TRUE returns per-file details (file name, size, row count)
-- Log the export for the next incremental run
INSERT INTO export_log (last_export_time, exported_at)
VALUES (CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
```

### Pattern 3: Cross-Cloud Data Transfer

```sql
-- Unload from Snowflake in one cloud to a stage in another cloud
-- (Snowflake supports cross-cloud external stages)
COPY INTO @target_cloud_stage/migration/
  FROM source_table
  FILE_FORMAT = (TYPE = 'PARQUET' COMPRESSION = 'ZSTD')
  MAX_FILE_SIZE = 536870912;  -- 512 MB for large transfers
```

### Pattern 4: Report Generation

```sql
-- Generate a single, human-readable CSV report
COPY INTO @reports_stage/monthly_sales_report
  FROM (
    SELECT
      region AS "Region",
      product_category AS "Category",
      SUM(revenue) AS "Total Revenue",
      COUNT(DISTINCT customer_id) AS "Unique Customers",
      ROUND(AVG(order_value), 2) AS "Avg Order Value"
    FROM sales_summary
    WHERE sale_month = '2026-03'
    GROUP BY region, product_category
    ORDER BY region, "Total Revenue" DESC
  )
  FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'NONE')
  SINGLE = TRUE
  HEADER = TRUE
  OVERWRITE = TRUE;
```

### Performance Optimization Strategies

#### 1. Use a Larger Warehouse

Unloading is parallelized across warehouse nodes. More nodes mean more parallel file writers.

```sql
-- Scale up for large unloads
ALTER WAREHOUSE export_wh SET WAREHOUSE_SIZE = 'XLARGE';

COPY INTO @my_stage/large_export/
  FROM huge_table
  FILE_FORMAT = (TYPE = 'PARQUET');

-- Scale back down
ALTER WAREHOUSE export_wh SET WAREHOUSE_SIZE = 'SMALL';
```

#### 2. Optimize MAX_FILE_SIZE

- Too small (1 MB): excessive file overhead, many files to manage.
- Too large (1 GB): reduces parallelism, slower individual file writes.
- Sweet spot: **64 MB to 256 MB** for most use cases.

#### 3. Use Columnar Formats for Large Exports

Parquet with Snappy compression provides the best balance of compression ratio and write speed.

#### 4. Filter Before Unloading

Always use a subquery to filter data rather than unloading an entire table and filtering downstream.

```sql
-- Good: Filter in the query
COPY INTO @my_stage/output/
  FROM (SELECT * FROM events WHERE event_date = '2026-03-07')
  FILE_FORMAT = (TYPE = 'PARQUET');

-- Bad: Unload everything, filter later
COPY INTO @my_stage/output/
  FROM events
  FILE_FORMAT = (TYPE = 'PARQUET');
```

#### 5. Use DETAILED_OUTPUT for Monitoring

```sql
COPY INTO @my_stage/output/
  FROM my_table
  FILE_FORMAT = (TYPE = 'PARQUET')
  DETAILED_OUTPUT = TRUE;

-- Returns: FILE_NAME, FILE_SIZE, ROW_COUNT for each output file
```

#### 6. Separate Unload Warehouse

Use a dedicated warehouse for export operations to avoid impacting query workloads.

#### 7. Schedule Large Exports During Off-Peak Hours

```sql
CREATE OR REPLACE TASK nightly_export
  WAREHOUSE = export_wh
  SCHEDULE = 'USING CRON 0 2 * * * America/New_York'  -- 2 AM daily
AS
  COPY INTO @my_s3_stage/daily_export/
  FROM (
    SELECT * FROM events
    WHERE event_date = DATEADD(DAY, -1, CURRENT_DATE())
  )
  PARTITION BY ('dt=' || TO_VARCHAR(event_date, 'YYYY-MM-DD'))
  FILE_FORMAT = (TYPE = 'PARQUET')
  MAX_FILE_SIZE = 268435456
  OVERWRITE = TRUE;
```

---

## Common Interview Questions

### Q1: What is the difference between COPY INTO <table> and COPY INTO <location>?

**Answer**: `COPY INTO <table>` loads data from files into a Snowflake table (data ingestion). `COPY INTO <location>` exports data from a Snowflake table or query result into files at a stage or external storage location (data unloading). They share similar syntax but serve opposite purposes. The loading version supports ON_ERROR, MATCH_BY_COLUMN_NAME, and VALIDATION_MODE. The unloading version supports PARTITION BY, SINGLE, MAX_FILE_SIZE, HEADER, and OVERWRITE.

---

### Q2: How does PARTITION BY work in COPY INTO <location> and why is it important?

**Answer**: PARTITION BY evaluates an expression for each row and uses the result to determine the subdirectory where that row's data is written. For example, partitioning by date creates `dt=2026-03-01/`, `dt=2026-03-02/` directories. This is critical for creating Hive-compatible partition layouts that enable partition pruning in downstream tools like Spark, Athena, Presto, and Databricks. Without proper partitioning, downstream queries must scan all files instead of only the relevant partitions.

---

### Q3: When would you use SINGLE = TRUE and what are its limitations?

**Answer**: Use SINGLE = TRUE when you need exactly one output file, typically for reports, small exports consumed by non-distributed systems, or configuration data. Limitations include: (1) it disables parallel writing so it is significantly slower for large datasets, (2) the file size is limited by the memory available on a single warehouse node, (3) it cannot be combined with PARTITION BY. For large datasets, always use the default multi-file output.

---

### Q4: How do you unload data from Snowflake to a local machine?

**Answer**: It is a two-step process: (1) Use `COPY INTO @<internal_stage>` to unload data from the table to an internal stage. (2) Use the `GET` command from SnowSQL to download the files from the internal stage to the local filesystem. GET only works with internal stages and must be run from a Snowflake client (SnowSQL), not from the web UI. For external stages, use the cloud provider's CLI tools (aws s3 cp, azcopy, gsutil) instead.

---

### Q5: What file format would you recommend for unloading data that will be consumed by Apache Spark?

**Answer**: Parquet with Snappy compression. Parquet is columnar, so Spark can leverage column pruning (only reading needed columns). It embeds the schema, eliminating schema inference overhead. Snappy provides a good balance between compression ratio and decompression speed. I would target MAX_FILE_SIZE of 128-256 MB to align with typical HDFS block sizes and use PARTITION BY to enable partition pruning in Spark.

---

### Q6: How does OVERWRITE interact with SINGLE = TRUE vs SINGLE = FALSE?

**Answer**: With `SINGLE = TRUE`, the output file has a predictable name, so `OVERWRITE = TRUE` reliably replaces the previous export. This is ideal for idempotent patterns like daily reports. With `SINGLE = FALSE` (default), Snowflake generates files with unique suffixes (e.g., `data_0_0_0`, `data_0_1_0`). OVERWRITE will replace files with matching names, but since names may vary between runs, old files from previous exports may persist. For clean overwrites with multiple files, either clean the directory before exporting or use a date-based path structure.

---

### Q7: How would you optimize unloading a 500 GB table?

**Answer**: Optimization strategy:
1. **Use a large warehouse** (XLARGE or larger) to maximize parallelism across nodes.
2. **Use Parquet with Snappy** for best compression and write performance.
3. **Set MAX_FILE_SIZE to 256 MB** for balanced parallelism.
4. **Use PARTITION BY** if the data has a natural partition key (date, region), which also helps downstream consumers.
5. **Filter unnecessary columns** in the FROM subquery to reduce data volume.
6. **Use a dedicated warehouse** to avoid impacting other workloads.
7. **Schedule during off-peak** to get maximum cluster resources.
8. Use `DETAILED_OUTPUT = TRUE` to verify the output and monitor progress.

---

### Q8: Explain the DETAILED_OUTPUT option and its use cases.

**Answer**: `DETAILED_OUTPUT = TRUE` changes the COPY INTO result to return per-file details instead of a single summary row. Each row in the result represents one output file and includes the file name, file size, and row count. Use cases include: (1) auditing what was exported, (2) logging file-level metadata for downstream orchestration, (3) verifying that all data was exported (summing row counts), and (4) passing the list of generated files to downstream processes. Without it, you only get a single aggregate result.

---

## Tips

- **COPY INTO <location> does NOT track previously unloaded data**. Unlike COPY INTO <table>, there is no idempotency built in. Running it twice produces duplicate output files (unless OVERWRITE = TRUE with SINGLE = TRUE).
- **Parquet is almost always the best choice** for machine-to-machine data exchange. Use CSV only when a human or Excel needs to read the file.
- **PARTITION BY is your most important tool** for creating well-organized data lake exports. Always partition by a field that downstream consumers will filter on.
- **HEADER = TRUE affects every file** in a multi-file export. Each file gets its own header row, which is the correct behavior for independent file consumption but can be a nuisance if you plan to concatenate files.
- **GET only works with internal stages**. For external stages, there is no Snowflake command to download -- use the cloud provider's CLI.
- **OVERWRITE = TRUE does not delete extra files** from a previous run that might have generated more files. It only overwrites files with matching names. For a clean export, remove old files first with `REMOVE @stage/path/` or use a unique path per export run.
- **Use INCLUDE_QUERY_ID = FALSE** when you want predictable file names. By default, Snowflake may include the query ID in the file path.
- **Monitor unload costs**: Unloading uses warehouse compute credits. Large, frequent exports can be surprisingly expensive. Optimize with proper filtering and scheduling.
- **The FROM clause supports full query syntax**: JOINs, CTEs, window functions, aggregations -- anything you can write in a SELECT. This means you can produce fully transformed export files without needing an intermediate table.
