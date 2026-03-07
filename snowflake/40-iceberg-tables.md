# Iceberg Tables & Open Table Formats

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Apache Iceberg Overview](#apache-iceberg-overview)
2. [Open Table Format Benefits](#open-table-format-benefits)
3. [Snowflake-Managed Iceberg Tables](#snowflake-managed-iceberg-tables)
4. [Externally Managed Iceberg Tables](#externally-managed-iceberg-tables)
5. [Iceberg Table Features in Snowflake](#iceberg-table-features-in-snowflake)
6. [Iceberg Catalog Integration](#iceberg-catalog-integration)
7. [Interoperability with Other Engines](#interoperability-with-other-engines)
8. [Converting Snowflake Tables to Iceberg](#converting-snowflake-tables-to-iceberg)
9. [Metadata Management](#metadata-management)
10. [Storage Considerations](#storage-considerations)
11. [Delta Lake and Hudi Comparison](#delta-lake-and-hudi-comparison)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## Apache Iceberg Overview

Apache Iceberg is an **open table format** designed for large-scale analytic datasets. Originally developed at Netflix and donated to the Apache Software Foundation, Iceberg defines how data files, metadata, and schema are organized on storage (e.g., S3, GCS, Azure Blob).

### Core Principles

- **Open specification**: The table format is engine-agnostic. Any engine that understands Iceberg can read and write the data.
- **ACID transactions**: Iceberg provides serializable isolation using optimistic concurrency with metadata file swaps.
- **Schema evolution**: Add, drop, rename, or reorder columns without rewriting data files.
- **Partition evolution**: Change partitioning strategies on a table without rewriting existing data.
- **Hidden partitioning**: Users write queries using natural column values; Iceberg translates to the physical partition layout automatically.
- **Time travel and snapshot isolation**: Every commit produces a snapshot, enabling point-in-time queries.

### Iceberg Architecture

```
Iceberg Table
  |
  +-- Catalog (points to current metadata file)
  |
  +-- Metadata Layer
  |     +-- metadata files (JSON) -- table schema, partition spec, properties
  |     +-- manifest lists (Avro) -- list of manifest files per snapshot
  |     +-- manifest files (Avro) -- list of data files with column-level stats
  |
  +-- Data Layer
        +-- Parquet / ORC / Avro data files
```

Each **snapshot** points to a **manifest list**, which points to one or more **manifest files**, which in turn reference the actual **data files**. This three-level metadata tree enables efficient query planning and file pruning.

---

## Open Table Format Benefits

| Benefit | Description |
|---|---|
| **No vendor lock-in** | Data is stored in open formats (Parquet) with open metadata; any compatible engine can access it. |
| **Multi-engine access** | Spark, Trino, Flink, Snowflake, Dremio, and others can all read/write the same table. |
| **ACID guarantees** | Safe concurrent reads and writes without corrupting data. |
| **Schema & partition evolution** | Change table structure over time without costly migrations. |
| **Fine-grained metadata** | Column-level min/max stats in manifests enable aggressive file pruning (fewer files scanned). |
| **Time travel** | Query historical snapshots for auditing, debugging, or reproducibility. |

---

## Snowflake-Managed Iceberg Tables

With **Snowflake-managed** Iceberg tables, Snowflake acts as both the **catalog** and the **write engine**. The data is stored in your external cloud storage (S3, GCS, ADLS) in Parquet format using the Iceberg open table format, but Snowflake manages the metadata catalog.

### Creating a Snowflake-Managed Iceberg Table

```sql
-- Step 1: Create an external volume pointing to your cloud storage
CREATE OR REPLACE EXTERNAL VOLUME my_iceberg_volume
  STORAGE_LOCATIONS = (
    (
      NAME = 'my-s3-location'
      STORAGE_BASE_URL = 's3://my-bucket/iceberg-data/'
      STORAGE_PROVIDER = 'S3'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/my-iceberg-role'
    )
  );

-- Step 2: Create the Iceberg table (Snowflake manages the catalog)
CREATE OR REPLACE ICEBERG TABLE my_db.my_schema.customer_iceberg (
    customer_id INT,
    first_name STRING,
    last_name STRING,
    email STRING,
    signup_date DATE,
    region STRING
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'my_iceberg_volume'
  BASE_LOCATION = 'customer_iceberg/';
```

### Key Characteristics

- Snowflake owns the **write path** -- you use standard DML (INSERT, UPDATE, DELETE, MERGE).
- Data is written as **Parquet** files on your external storage.
- Metadata follows the **Iceberg specification**, so other engines can read it.
- Snowflake manages compaction, snapshot management, and metadata updates.
- Supports most Snowflake features (see features section below).

### Inserting and Querying Data

```sql
-- Insert data
INSERT INTO my_db.my_schema.customer_iceberg
VALUES
  (1, 'Alice', 'Chen', 'alice@example.com', '2025-01-15', 'US-EAST'),
  (2, 'Bob', 'Kumar', 'bob@example.com', '2025-02-20', 'EU-WEST'),
  (3, 'Carol', 'Silva', 'carol@example.com', '2025-03-10', 'APAC');

-- Query just like a regular Snowflake table
SELECT * FROM my_db.my_schema.customer_iceberg
WHERE region = 'US-EAST';

-- MERGE is supported
MERGE INTO my_db.my_schema.customer_iceberg AS target
USING staging_customers AS source
  ON target.customer_id = source.customer_id
WHEN MATCHED THEN UPDATE SET
  email = source.email
WHEN NOT MATCHED THEN INSERT
  (customer_id, first_name, last_name, email, signup_date, region)
  VALUES (source.customer_id, source.first_name, source.last_name,
          source.email, source.signup_date, source.region);
```

---

## Externally Managed Iceberg Tables

With **externally managed** Iceberg tables, an external catalog (AWS Glue, Hive Metastore, or a REST-compatible catalog like Polaris/Nessie) owns the metadata. Snowflake reads from these tables but does **not** manage writes.

### Creating an Externally Managed Iceberg Table (AWS Glue Catalog)

```sql
-- Create a catalog integration for AWS Glue
CREATE OR REPLACE CATALOG INTEGRATION glue_catalog_int
  CATALOG_SOURCE = GLUE
  CATALOG_NAMESPACE = 'my_glue_database'
  TABLE_FORMAT = ICEBERG
  GLUE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/my-glue-role'
  GLUE_CATALOG_ID = '123456789012'
  GLUE_REGION = 'us-east-1'
  ENABLED = TRUE;

-- Create the Iceberg table referencing the external catalog
CREATE OR REPLACE ICEBERG TABLE my_db.my_schema.ext_customer_iceberg
  EXTERNAL_VOLUME = 'my_iceberg_volume'
  CATALOG = 'glue_catalog_int'
  CATALOG_TABLE_NAME = 'customer_table';
```

### Creating an Externally Managed Iceberg Table (REST Catalog / Polaris)

```sql
-- Create a catalog integration for a REST-based catalog
CREATE OR REPLACE CATALOG INTEGRATION polaris_catalog_int
  CATALOG_SOURCE = POLARIS
  TABLE_FORMAT = ICEBERG
  CATALOG_NAMESPACE = 'my_namespace'
  REST_CONFIG = (
    CATALOG_URI = 'https://my-polaris-server.example.com/api/catalog'
    WAREHOUSE = 'my_warehouse'
  )
  REST_AUTHENTICATION = (
    TYPE = OAUTH
    OAUTH_CLIENT_ID = 'my-client-id'
    OAUTH_CLIENT_SECRET = 'my-secret'
    OAUTH_TOKEN_URI = 'https://auth.example.com/oauth/token'
  )
  ENABLED = TRUE;

CREATE OR REPLACE ICEBERG TABLE my_db.my_schema.polaris_customer
  EXTERNAL_VOLUME = 'my_iceberg_volume'
  CATALOG = 'polaris_catalog_int'
  CATALOG_TABLE_NAME = 'customer_table';
```

### Key Characteristics

- Snowflake provides **read-only** access (no DML from Snowflake side).
- Another engine (e.g., Spark) manages writes and catalog updates.
- Use `ALTER ICEBERG TABLE ... REFRESH` to sync Snowflake's metadata cache with the external catalog.
- Ideal when Spark/Flink pipelines write data and Snowflake is the analytics/BI query layer.

```sql
-- Refresh metadata after an external engine has written new data
ALTER ICEBERG TABLE my_db.my_schema.ext_customer_iceberg REFRESH;
```

---

## Iceberg Table Features in Snowflake

### Feature Support Matrix (Snowflake-Managed Iceberg Tables)

| Feature | Supported? | Notes |
|---|---|---|
| **Time Travel** | Yes | Up to the configured `DATA_RETENTION_TIME_IN_DAYS` |
| **CLONE** | Yes | Zero-copy clones referencing the same Parquet files |
| **INSERT / UPDATE / DELETE / MERGE** | Yes | Full DML support |
| **Streams** | Yes | CDC via Snowflake streams |
| **Tasks** | Yes | Automate pipelines on Iceberg tables |
| **Dynamic Tables** | Yes | Declarative pipelines targeting Iceberg tables |
| **Row Access Policies** | Yes | Fine-grained security |
| **Masking Policies** | Yes | Column-level data masking |
| **Tags** | Yes | Governance and classification |
| **Clustering** | Yes | Automatic clustering on Iceberg tables |
| **Search Optimization** | No | Not currently supported |
| **Materialized Views** | No | Not currently supported |
| **Fail-safe** | No | Not applicable (data is on external storage) |

### Time Travel on Iceberg Tables

```sql
-- Query a Snowflake-managed Iceberg table at a point in time
SELECT * FROM my_db.my_schema.customer_iceberg
  AT(TIMESTAMP => '2025-12-01 10:00:00'::TIMESTAMP_LTZ);

-- Query using an offset in seconds
SELECT * FROM my_db.my_schema.customer_iceberg
  AT(OFFSET => -3600);

-- Undrop an Iceberg table
UNDROP TABLE my_db.my_schema.customer_iceberg;
```

### Cloning Iceberg Tables

```sql
-- Zero-copy clone of an Iceberg table
CREATE ICEBERG TABLE my_db.my_schema.customer_iceberg_clone
  CLONE my_db.my_schema.customer_iceberg;
```

---

## Iceberg Catalog Integration

Snowflake supports multiple catalog sources for Iceberg tables:

| Catalog Type | Description | Use Case |
|---|---|---|
| **SNOWFLAKE** | Snowflake is the catalog. Full read/write. | Snowflake-first workloads that want open format benefits. |
| **AWS Glue** | AWS Glue Data Catalog manages metadata. | AWS-centric lakehouse with Spark/EMR writing data. |
| **REST Catalog** | Nessie, Polaris, Tabular, or any Iceberg REST catalog. | Multi-engine environments with centralized catalog. |
| **Object Storage** | Metadata files directly on storage (no catalog service). | Simple setups or migration scenarios. |

### Object Storage Catalog Example

```sql
-- Point directly to an Iceberg metadata file on storage
CREATE OR REPLACE ICEBERG TABLE my_db.my_schema.direct_iceberg
  EXTERNAL_VOLUME = 'my_iceberg_volume'
  CATALOG = 'ICEBERG_REST'
  METADATA_FILE_PATH = 'warehouse/customer/metadata/v3.metadata.json';
```

---

## Interoperability with Other Engines

One of the primary reasons to use Iceberg tables is **multi-engine interoperability**.

### Read/Write Patterns

```
               Writes                     Reads
  Spark  ----+                   +---- Snowflake (analytics/BI)
  Flink  ----|---> Iceberg <-----|---- Trino (ad-hoc queries)
  Snowflake -+     Table         +---- Spark (ML feature eng.)
                                 +---- Dremio (data exploration)
```

### Example: Spark Writes, Snowflake Reads

```python
# PySpark: Write data to an Iceberg table
from pyspark.sql import SparkSession

spark = SparkSession.builder \
    .appName("IcebergWriter") \
    .config("spark.sql.catalog.glue_catalog", "org.apache.iceberg.spark.SparkCatalog") \
    .config("spark.sql.catalog.glue_catalog.catalog-impl",
            "org.apache.iceberg.aws.glue.GlueCatalog") \
    .config("spark.sql.catalog.glue_catalog.warehouse", "s3://my-bucket/iceberg-data/") \
    .getOrCreate()

df = spark.read.parquet("s3://my-bucket/raw/customer_data/")

df.writeTo("glue_catalog.my_glue_database.customer_table") \
  .using("iceberg") \
  .createOrReplace()
```

```sql
-- Snowflake: Read the same table written by Spark
ALTER ICEBERG TABLE my_db.my_schema.ext_customer_iceberg REFRESH;

SELECT region, COUNT(*) AS customer_count
FROM my_db.my_schema.ext_customer_iceberg
GROUP BY region
ORDER BY customer_count DESC;
```

### Snowflake Polaris Catalog

**Polaris** (open-sourced by Snowflake) is a REST-based Iceberg catalog that provides:

- Centralized catalog for multi-engine access
- Role-based access control across engines
- Catalog-level governance
- Compatible with Spark, Trino, Flink, Snowflake, and more

---

## Converting Snowflake Tables to Iceberg

You can convert existing Snowflake-native tables to Iceberg format to gain open format benefits.

### Using CREATE ICEBERG TABLE ... AS SELECT

```sql
-- Convert by selecting data from an existing native table
CREATE OR REPLACE ICEBERG TABLE my_db.my_schema.customer_iceberg
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'my_iceberg_volume'
  BASE_LOCATION = 'customer_iceberg/'
AS
SELECT * FROM my_db.my_schema.customer_native;
```

### Using ALTER TABLE ... CONVERT TO ICEBERG

```sql
-- In-place conversion (when supported)
ALTER TABLE my_db.my_schema.customer_native
  CONVERT TO ICEBERG
  EXTERNAL_VOLUME = 'my_iceberg_volume'
  BASE_LOCATION = 'customer_iceberg_converted/';
```

### Considerations for Conversion

- **Data rewrite**: Conversion rewrites data from Snowflake's internal micro-partitions to Parquet files on external storage.
- **Feature differences**: Some features (e.g., Fail-safe, Search Optimization) are not available on Iceberg tables.
- **Performance**: Snowflake-native tables may have slightly better query performance due to internal optimizations (FDN format). Iceberg tables trade some of that for openness.
- **Storage costs**: You now pay for external cloud storage directly, not Snowflake-managed storage.

---

## Metadata Management

### Snapshot Management

Each write operation creates a new Iceberg snapshot. Over time, snapshots accumulate and should be managed.

```sql
-- View snapshot history for a Snowflake-managed Iceberg table
SELECT * FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS(
  TABLE_NAME => 'customer_iceberg',
  SCHEMA_NAME => 'my_schema',
  DATABASE_NAME => 'my_db'
));
```

### Metadata Refresh for External Tables

```sql
-- Manual refresh
ALTER ICEBERG TABLE my_db.my_schema.ext_customer_iceberg REFRESH;

-- Auto-refresh can be configured via event notifications
-- (e.g., S3 event notifications triggering refresh)
```

### Metadata File Compaction

Iceberg metadata files grow over time. Snowflake automatically manages metadata for Snowflake-managed tables. For externally managed tables, you should configure metadata compaction in your writing engine (e.g., Spark's `rewrite_manifests` procedure).

---

## Storage Considerations

### Storage Architecture

| Aspect | Snowflake Native Table | Snowflake-Managed Iceberg Table | Externally Managed Iceberg |
|---|---|---|---|
| **Data format** | Snowflake FDN (proprietary) | Apache Parquet (open) | Apache Parquet (open) |
| **Storage location** | Snowflake-managed storage | Your external cloud storage | Your external cloud storage |
| **Storage cost** | Snowflake storage pricing | Cloud provider storage pricing | Cloud provider storage pricing |
| **Metadata** | Internal micro-partition metadata | Iceberg metadata (manifests + JSON) | Iceberg metadata (external catalog) |
| **Compression** | Automatic, highly optimized | Parquet compression (snappy/zstd) | Parquet compression (snappy/zstd) |

### Cost Implications

- **Compute**: Snowflake charges compute (warehouse credits) for querying Iceberg tables just like native tables.
- **Storage**: You pay your cloud provider directly for storage; Snowflake does not charge its storage markup.
- **External volume egress**: Cross-region or cross-cloud access may incur data transfer fees.
- **Metadata operations**: Refreshing externally managed tables consumes compute.

---

## Delta Lake and Hudi Comparison

| Feature | Apache Iceberg | Delta Lake | Apache Hudi |
|---|---|---|---|
| **Origin** | Netflix | Databricks | Uber |
| **Governance** | Apache Software Foundation | Linux Foundation (Delta Lake 3.0+) | Apache Software Foundation |
| **Engine neutrality** | Excellent -- designed engine-agnostic | Improving (UniForm) but historically Spark-centric | Good but Spark-oriented tooling |
| **Schema evolution** | Full (add, drop, rename, reorder) | Add/rename columns | Add columns |
| **Partition evolution** | Yes (change partitioning without rewrite) | Requires rewrite | Limited |
| **Hidden partitioning** | Yes | No | No |
| **Time travel** | Yes (snapshot-based) | Yes (version-based) | Yes (timeline-based) |
| **Metadata structure** | 3-level (metadata JSON, manifest list, manifest) | Transaction log (JSON + checkpoint Parquet) | Timeline (commits, compactions, cleans) |
| **Snowflake support** | Native Iceberg table support | Read via external tables (Delta Lake on S3) | Limited |
| **File format** | Parquet, ORC, Avro | Parquet only | Parquet, Avro |
| **Community momentum** | Rapidly growing; strong multi-vendor support | Strong, especially in Databricks ecosystem | Active but smaller community |

### Why Snowflake Chose Iceberg

- Engine-neutral design aligns with Snowflake's open data lakehouse strategy.
- Iceberg's metadata structure supports efficient query planning.
- Hidden partitioning and partition evolution reduce operational burden.
- Growing ecosystem adoption (AWS, Google, Apple, Netflix, etc.).

---

## Common Interview Questions

### Q1: What is an Apache Iceberg table and why is it significant for data engineering?

**A:** Apache Iceberg is an open table format that defines how data files, metadata, and schema are organized on cloud object storage. It is significant because it provides ACID transactions, schema/partition evolution, time travel, and engine-agnostic access. This means data stored in Iceberg format is not locked into any single query engine -- Snowflake, Spark, Trino, Flink, and others can all read and write the same tables, enabling a true open lakehouse architecture.

### Q2: What is the difference between a Snowflake-managed and an externally managed Iceberg table?

**A:** With a **Snowflake-managed** Iceberg table, Snowflake acts as the catalog and handles all writes (DML), metadata management, and compaction. You get full feature support (Time Travel, CLONE, Streams, etc.). With an **externally managed** Iceberg table, an external catalog (AWS Glue, REST catalog) owns the metadata, and another engine (e.g., Spark) manages writes. Snowflake provides read-only access and must be refreshed to see new data. The choice depends on which engine needs write ownership.

### Q3: How does Iceberg's partition evolution work, and why is it better than traditional partitioning?

**A:** In traditional Hive-style partitioning, the partition scheme is fixed. Changing it requires rewriting all existing data. Iceberg supports **partition evolution**: you can change the partition strategy (e.g., from daily to hourly) and only new data uses the new scheme. Existing data files retain their original partitioning. Iceberg's query planner understands both old and new partition layouts and prunes files correctly. Additionally, Iceberg uses **hidden partitioning**, so users write queries against natural column values without needing to know the partition structure.

### Q4: Can you use Time Travel on Iceberg tables in Snowflake?

**A:** Yes, for Snowflake-managed Iceberg tables, Time Travel is fully supported. You can query historical data using `AT(TIMESTAMP => ...)` or `AT(OFFSET => ...)` syntax, and you can use `UNDROP TABLE`. The retention period is governed by `DATA_RETENTION_TIME_IN_DAYS`. For externally managed Iceberg tables, Time Travel in Snowflake is not supported because Snowflake does not manage the snapshots.

### Q5: How would you design a lakehouse architecture using Snowflake Iceberg tables?

**A:** A practical design:
1. **Ingestion layer**: Use Spark or Flink to ingest raw data into Iceberg tables on S3/GCS, with an external catalog like Polaris or AWS Glue.
2. **Transformation layer**: Use Snowflake-managed Iceberg tables for curated/transformed data, leveraging Snowflake's SQL engine, Dynamic Tables, and Streams for incremental processing.
3. **Serving layer**: Snowflake serves BI tools and dashboards. ML teams access the same data via Spark.
4. **Governance**: Use Polaris as the central catalog for cross-engine access control. Apply Snowflake row access policies and masking policies on Snowflake-managed tables.
5. **Cost optimization**: Store data in your cloud provider's storage (cheaper than Snowflake-managed storage), use Snowflake compute only for transformations and queries.

### Q6: What are the trade-offs of using Iceberg tables vs. native Snowflake tables?

**A:** Trade-offs include:
- **Performance**: Native tables use Snowflake's proprietary FDN format with deep internal optimizations. Iceberg tables use Parquet, which is excellent but may have slightly higher query overhead in some scenarios.
- **Feature gaps**: Iceberg tables do not support Materialized Views, Search Optimization, or Fail-safe.
- **Storage control**: Iceberg tables store data in your cloud storage (more control, potentially lower cost) vs. Snowflake-managed storage.
- **Openness**: Iceberg tables can be read by any Iceberg-compatible engine, eliminating vendor lock-in.
- **Operational complexity**: Managing external volumes, catalog integrations, and metadata refresh adds operational overhead.

### Q7: How does Snowflake handle metadata for Iceberg tables?

**A:** For Snowflake-managed Iceberg tables, Snowflake maintains the Iceberg metadata (metadata JSON files, manifest lists, and manifest files) on your external storage following the Iceberg specification. Snowflake also maintains an internal metadata cache for fast query planning. For externally managed tables, Snowflake reads metadata from the external catalog and caches it internally; you must call `ALTER ICEBERG TABLE ... REFRESH` to sync the cache after external writes.

---

## Tips

1. **Start with Snowflake-managed Iceberg tables** if your primary query engine is Snowflake. You get the best feature support and simplest operations while still benefiting from open format data.

2. **Use externally managed Iceberg tables** when another engine (Spark, Flink) owns the write path and Snowflake is primarily a read/analytics layer.

3. **Always configure auto-refresh** for externally managed tables in production. Manual `REFRESH` calls are error-prone and add latency.

4. **Monitor metadata growth**. Iceberg metadata (manifests, snapshots) can grow significantly on high-write tables. Ensure compaction and snapshot expiration are configured.

5. **Understand the cost model**. With Iceberg tables, you pay cloud provider rates for storage (often cheaper) but still pay Snowflake compute credits for queries. Factor in data transfer costs for cross-region access.

6. **Test query performance** before migrating critical workloads from native tables to Iceberg. Benchmark with your actual query patterns.

7. **Leverage Polaris catalog** for multi-engine environments. It provides centralized governance and simplifies catalog management across Snowflake, Spark, and Trino.

8. **Use CLONE for development/testing**. Iceberg table clones are zero-copy and share underlying Parquet files, making them cost-effective for creating test environments.

9. **Plan partition strategy carefully**. While Iceberg supports partition evolution, choosing a good initial partition strategy (e.g., by date) reduces the need for future changes and improves query performance.

10. **Keep up with Snowflake releases**. Iceberg support in Snowflake is evolving rapidly, with new features added in nearly every release cycle.
