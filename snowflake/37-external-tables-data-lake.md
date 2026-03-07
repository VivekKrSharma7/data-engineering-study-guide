# External Tables & Data Lake Integration

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### What Are External Tables?

External tables are **read-only** tables in Snowflake that reference data stored in an **external stage** (Amazon S3, Azure Blob Storage, or Google Cloud Storage). Unlike regular managed tables, Snowflake does not store or manage the underlying data — it only stores the **metadata** (file locations, partition information, column definitions).

This allows Snowflake to act as a powerful **query engine over your data lake** without requiring you to ingest (COPY INTO) the data first.

```
+---------------------+          +----------------------------+
|   Snowflake         |          |   External Storage         |
|                     |          |                            |
|  External Table     | -------> |  S3 / ADLS / GCS           |
|  (metadata only)    |          |  (Parquet, JSON, CSV, ORC) |
+---------------------+          +----------------------------+
```

### Why Use External Tables?

- **No data duplication** — query data in place without loading it into Snowflake.
- **Cost savings** — avoid Snowflake storage costs for large, rarely queried datasets.
- **Multi-engine access** — other tools (Spark, Presto, Databricks) can also read the same files.
- **Data lake patterns** — Snowflake becomes one of many consumers of a centralized data lake.
- **Regulatory/compliance** — data stays in a customer-managed bucket.

---

## Creating External Tables

### Prerequisites

1. An **external stage** pointing to the cloud storage location.
2. A **file format** definition (or inline specification).
3. Appropriate IAM / service principal permissions for Snowflake to read the bucket.

### Basic Example (Parquet on S3)

```sql
-- 1. Create a file format
CREATE OR REPLACE FILE FORMAT my_parquet_format
  TYPE = PARQUET;

-- 2. Create an external stage
CREATE OR REPLACE STAGE my_s3_stage
  URL = 's3://my-data-lake/events/'
  STORAGE_INTEGRATION = my_s3_integration
  FILE_FORMAT = my_parquet_format;

-- 3. Create the external table
CREATE OR REPLACE EXTERNAL TABLE events_ext (
    event_id    VARCHAR AS (VALUE:event_id::VARCHAR),
    event_type  VARCHAR AS (VALUE:event_type::VARCHAR),
    event_ts    TIMESTAMP_NTZ AS (VALUE:event_ts::TIMESTAMP_NTZ),
    payload     VARIANT AS (VALUE:payload::VARIANT)
)
WITH LOCATION = @my_s3_stage
FILE_FORMAT = my_parquet_format
AUTO_REFRESH = TRUE;
```

**Key points:**
- Columns are defined as **virtual columns** using expressions over the `VALUE` pseudo-column (the raw semi-structured row).
- `VALUE` represents one row from the underlying file.
- The `AS (expression)` clause defines how each column is extracted.

### CSV Example

```sql
CREATE OR REPLACE EXTERNAL TABLE orders_ext (
    order_id    NUMBER   AS (VALUE:c1::NUMBER),
    customer_id NUMBER   AS (VALUE:c2::NUMBER),
    order_date  DATE     AS (VALUE:c3::DATE),
    amount      FLOAT    AS (VALUE:c4::FLOAT)
)
WITH LOCATION = @my_csv_stage
FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1);
```

For CSV files, columns are referenced positionally as `c1, c2, c3, ...`.

---

## Partitioned External Tables

Partitioning external tables is critical for performance. It allows Snowflake to **prune files** based on partition columns derived from the file path.

### Auto-Detected Partitions (Hive-Style)

If your files follow **Hive-style partitioning** (e.g., `year=2025/month=03/day=15/`), Snowflake can detect partitions automatically:

```sql
CREATE OR REPLACE EXTERNAL TABLE events_partitioned_ext (
    event_id   VARCHAR AS (VALUE:event_id::VARCHAR),
    event_type VARCHAR AS (VALUE:event_type::VARCHAR),
    event_ts   TIMESTAMP_NTZ AS (VALUE:event_ts::TIMESTAMP_NTZ)
)
PARTITION BY (year VARCHAR, month VARCHAR, day VARCHAR)
WITH LOCATION = @my_s3_stage
FILE_FORMAT = my_parquet_format
AUTO_REFRESH = TRUE;
```

### Manually Defined Partition Columns

When file paths don't follow Hive conventions, extract partition values from the `METADATA$FILENAME` pseudo-column:

```sql
CREATE OR REPLACE EXTERNAL TABLE logs_ext (
    log_date   DATE    AS (TO_DATE(SPLIT_PART(METADATA$FILENAME, '/', 1), 'YYYY-MM-DD')),
    log_level  VARCHAR AS (VALUE:level::VARCHAR),
    message    VARCHAR AS (VALUE:message::VARCHAR)
)
PARTITION BY (log_date)
WITH LOCATION = @my_logs_stage
FILE_FORMAT = my_parquet_format;
```

### Auto-Refresh vs Manual Refresh

| Feature | Auto-Refresh | Manual Refresh |
|---|---|---|
| **Mechanism** | Cloud event notifications (SQS, Event Grid, Pub/Sub) | `ALTER EXTERNAL TABLE ... REFRESH` |
| **Latency** | Near-real-time metadata sync | On-demand |
| **Cost** | Small ongoing compute for event processing | Only when you trigger it |
| **Setup** | Requires event notification configuration | None beyond the table |

```sql
-- Manual refresh
ALTER EXTERNAL TABLE events_ext REFRESH;

-- Manual refresh for specific subpath
ALTER EXTERNAL TABLE events_ext REFRESH 'year=2025/month=03/';
```

---

## External Table Metadata Columns

Every external table exposes these **pseudo-columns** automatically:

| Column | Type | Description |
|---|---|---|
| `METADATA$FILENAME` | VARCHAR | Full path of the source file (relative to stage) |
| `METADATA$FILE_ROW_NUMBER` | NUMBER | Row number within the source file |
| `METADATA$FILE_CONTENT_KEY` | VARCHAR | Checksum of the file |
| `METADATA$FILE_LAST_MODIFIED` | TIMESTAMP_LTZ | Last modified timestamp of the file |
| `METADATA$START_SCAN_TIME` | TIMESTAMP_LTZ | Wallclock time when the scan started |
| `VALUE` | VARIANT | The raw row data (for semi-structured formats) |

```sql
SELECT
    METADATA$FILENAME AS source_file,
    METADATA$FILE_ROW_NUMBER AS row_num,
    event_id,
    event_type
FROM events_ext
WHERE METADATA$FILENAME LIKE '%2025/03/%'
LIMIT 100;
```

---

## Querying External Tables

External tables are queried just like any other table:

```sql
-- Simple query
SELECT event_type, COUNT(*) AS cnt
FROM events_partitioned_ext
WHERE year = '2025' AND month = '03'
GROUP BY event_type
ORDER BY cnt DESC;

-- Join with managed table
SELECT
    e.event_id,
    e.event_type,
    c.customer_name
FROM events_ext e
JOIN customers c ON e.customer_id = c.customer_id
WHERE e.event_ts >= '2025-01-01';
```

### Performance Considerations

1. **Partition pruning is essential** — always filter on partition columns to avoid full scans.
2. **File format matters** — Parquet and ORC are columnar and allow column pruning; CSV and JSON require reading entire rows.
3. **File sizing** — aim for files between **100 MB and 250 MB** (compressed) for optimal parallel scanning.
4. **Too many small files** degrades performance severely (high metadata overhead, many micro-scans).
5. **No micro-partitioning or clustering** — Snowflake's query optimizer cannot rearrange or cluster external data.
6. **No caching of data** — results cache works, but there is no local SSD caching of external file data like managed tables enjoy.

---

## Materialized Views on External Tables

You can create **materialized views** over external tables to improve query performance for frequently accessed data:

```sql
CREATE OR REPLACE MATERIALIZED VIEW events_mv AS
SELECT
    event_id,
    event_type,
    event_ts,
    year,
    month
FROM events_partitioned_ext
WHERE year = '2025';
```

**Benefits:**
- Data is physically stored and micro-partitioned inside Snowflake.
- Queries against the MV are significantly faster than hitting external storage.
- The MV auto-refreshes when the external table metadata is updated.

**Trade-offs:**
- Storage cost for the materialized data.
- Maintenance cost (serverless compute) for auto-refresh.
- Useful as a **hot layer** for frequently queried subsets of external data.

---

## External Tables vs Managed Tables

| Aspect | External Table | Managed (Native) Table |
|---|---|---|
| **Data location** | External cloud storage | Snowflake-managed storage |
| **Read/Write** | Read-only | Read-write |
| **Micro-partitioning** | No | Yes |
| **Clustering** | No | Yes (automatic + manual) |
| **Time Travel** | No | Yes (up to 90 days) |
| **Fail-safe** | No | Yes (7 days) |
| **Query performance** | Slower (network I/O, no caching) | Faster (local SSD cache, pruning) |
| **Storage cost** | External (your cloud bill) | Snowflake storage pricing |
| **DML support** | No INSERT/UPDATE/DELETE | Full DML |
| **Data sharing** | Limited | Full support |

**Rule of thumb:** Use external tables for **exploration, staging, or infrequent access**. Use managed tables for **production workloads** requiring performance and DML.

---

## Data Lake Patterns with Snowflake

### Pattern 1: Query in Place

Snowflake queries external tables directly. Best for ad-hoc exploration of raw data.

```
Data Lake (S3) --> External Table --> SQL Query
```

### Pattern 2: ELT with External Tables as Staging

Use external tables as a landing zone, then load into managed tables:

```sql
-- Continuous loading via stream on external table
CREATE OR REPLACE STREAM events_ext_stream ON EXTERNAL TABLE events_ext
  INSERT_ONLY = TRUE;

-- Task to process new files
CREATE OR REPLACE TASK load_events
  WAREHOUSE = etl_wh
  SCHEDULE = '5 MINUTE'
WHEN SYSTEM$STREAM_HAS_DATA('events_ext_stream')
AS
  INSERT INTO events_managed
  SELECT event_id, event_type, event_ts, payload
  FROM events_ext_stream
  WHERE METADATA$ACTION = 'INSERT';
```

### Pattern 3: Materialized View Hot Layer

Create MVs on the most-queried partitions of external data:

```
Data Lake --> External Table --> Materialized View (hot) --> Dashboard
                             --> Direct query (cold)     --> Ad-hoc
```

### Pattern 4: Data Mesh / Multi-Engine

Multiple engines (Snowflake, Spark, Trino) all read the same data lake:

```
                 +--> Snowflake (External Table)
Data Lake (S3) --+--> Spark / Databricks
                 +--> Trino / Athena
```

---

## Apache Iceberg Integration

Snowflake supports **Apache Iceberg tables**, bringing open table format capabilities into Snowflake.

### What is Iceberg?

Apache Iceberg is an **open table format** for large analytic datasets. It provides:
- ACID transactions on data lakes.
- Schema evolution.
- Time travel.
- Partition evolution.
- Engine-agnostic (Spark, Flink, Trino, Snowflake can all read/write).

### Iceberg Tables in Snowflake

```sql
-- Create an Iceberg table using Snowflake as the catalog
CREATE OR REPLACE ICEBERG TABLE customer_events
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'my_s3_volume'
  BASE_LOCATION = 'customer_events/'
AS
SELECT * FROM events_managed WHERE event_type = 'customer';

-- Create an Iceberg table with an external catalog (e.g., AWS Glue)
CREATE OR REPLACE ICEBERG TABLE shared_events
  CATALOG = 'GLUE'
  CATALOG_TABLE_NAME = 'events'
  EXTERNAL_VOLUME = 'my_s3_volume';
```

**Key benefits:**
- **Snowflake-managed Iceberg tables** — full DML, Snowflake manages the Iceberg metadata. Data stored in Parquet on your storage.
- **Externally managed Iceberg tables** — read-only in Snowflake, another engine (Spark) manages writes.
- **Interoperability** — other engines can read Snowflake-managed Iceberg tables via the Iceberg catalog.

### Iceberg vs External Tables vs Managed Tables

| Feature | External Table | Iceberg Table | Managed Table |
|---|---|---|---|
| Open format | Yes (files) | Yes (Iceberg) | No |
| DML | No | Yes (Snowflake catalog) | Yes |
| Time Travel | No | Yes | Yes |
| Multi-engine | Yes | Yes | No |
| Performance | Lower | Good | Best |

---

## Directory Tables

A **directory table** is a built-in, read-only table associated with a stage that catalogs all staged files.

```sql
-- Enable directory table on a stage
ALTER STAGE my_s3_stage SET DIRECTORY = (ENABLE = TRUE);

-- Refresh directory table
ALTER STAGE my_s3_stage REFRESH;

-- Query the directory table
SELECT *
FROM DIRECTORY(@my_s3_stage);
```

Directory tables expose:
- `RELATIVE_PATH` — file path relative to the stage.
- `SIZE` — file size in bytes.
- `LAST_MODIFIED` — last modified timestamp.
- `MD5` — file checksum.
- `ETAG` — cloud provider ETag.

**Use cases:**
- File inventory and monitoring.
- Building file-processing pipelines.
- Pre-filtering files before loading.
- Generating pre-signed URLs for file access:

```sql
SELECT
    RELATIVE_PATH,
    SIZE,
    GET_PRESIGNED_URL(@my_s3_stage, RELATIVE_PATH, 3600) AS download_url
FROM DIRECTORY(@my_s3_stage)
WHERE RELATIVE_PATH LIKE '%.parquet'
ORDER BY LAST_MODIFIED DESC;
```

---

## Common Interview Questions & Answers

### Q1: What is the difference between an external table and a regular table in Snowflake?

**A:** An external table is a read-only metadata layer over data files stored in external cloud storage (S3, ADLS, GCS). Snowflake does not own or manage the data. Regular (managed) tables store data in Snowflake's internal micro-partitioned storage with full DML support, time travel, fail-safe, clustering, and optimized caching. External tables sacrifice performance and features for data residency, cost savings, and multi-engine access.

### Q2: How do you optimize external table query performance?

**A:** (1) Use **partition columns** derived from file paths and always filter on them. (2) Use **columnar formats** like Parquet or ORC instead of CSV/JSON. (3) Ensure files are **properly sized** (100-250 MB compressed). (4) Create **materialized views** on frequently queried subsets. (5) Avoid too many small files. (6) Use **streams on external tables** for incremental processing rather than repeated full scans.

### Q3: Can you create a stream on an external table?

**A:** Yes, but only an **INSERT_ONLY** stream. Since external tables are read-only and data is append-only (new files appear), the stream captures new file arrivals. It does not support tracking updates or deletes. This is ideal for building incremental ELT pipelines from a data lake.

### Q4: When would you choose an Iceberg table over an external table?

**A:** Choose Iceberg when you need DML support (insert, update, delete, merge) on data stored in external storage, when you need time travel on external data, when you need multi-engine interoperability with ACID guarantees, or when you need schema/partition evolution. Choose plain external tables for simple read-only access to existing files where Iceberg overhead is unnecessary.

### Q5: What are the limitations of external tables?

**A:** (1) Read-only — no INSERT, UPDATE, DELETE, or MERGE. (2) No micro-partitioning or clustering. (3) No time travel or fail-safe. (4) Slower query performance due to network I/O and lack of local caching. (5) Limited data sharing capabilities. (6) No support for CLONE. (7) Auto-refresh requires cloud event notification setup.

### Q6: How does AUTO_REFRESH work for external tables?

**A:** When `AUTO_REFRESH = TRUE`, Snowflake sets up a cloud event notification mechanism (SQS for S3, Event Grid for Azure, Pub/Sub for GCS) that sends a message to Snowflake whenever files are added or removed from the external location. Snowflake then automatically updates the external table's metadata to reflect the new file set. This incurs a small serverless compute cost.

---

## Tips

- **Always use Parquet** for external tables unless you have a compelling reason for another format. Columnar pruning dramatically reduces I/O.
- **Name partition columns explicitly** in your external table definition to make query predicates intuitive.
- **Monitor auto-refresh costs** using `EXTERNAL_TABLE_FILE_REGISTRATION_HISTORY` in the Information Schema.
- **Use streams + tasks** on external tables for building reliable incremental pipelines from your data lake.
- **Evaluate Iceberg tables** for new projects where multi-engine access is a requirement — they offer a better experience than plain external tables.
- **Test file sizes** in your specific workload; the 100-250 MB guideline is a starting point, not a hard rule.
- **Combine external and managed tables** in the same query freely — Snowflake handles the join across storage types transparently.

---
