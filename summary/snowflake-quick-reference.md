# Snowflake - Quick Reference & Essential Q&A

[Back to Summary Index](README.md)

---

> **One-stop study guide** covering architecture, data loading, SQL features, performance tuning, security, data sharing, data engineering, time travel, administration, and integrations. Key numbers and SQL snippets included throughout.

---

## Table of Contents

1. [Architecture](#1-architecture)
2. [Data Loading & Unloading](#2-data-loading--unloading)
3. [SQL Features](#3-sql-features)
4. [Performance & Optimization](#4-performance--optimization)
5. [Security](#5-security)
6. [Data Sharing & Marketplace](#6-data-sharing--marketplace)
7. [Data Engineering Features](#7-data-engineering-features)
8. [Time Travel & Data Protection](#8-time-travel--data-protection)
9. [Administration & Monitoring](#9-administration--monitoring)
10. [Integration & Ecosystem](#10-integration--ecosystem)

---

## 1. Architecture

### Key Highlights

- **Three independent layers**: Cloud Services, Compute (Virtual Warehouses), Storage — each scales independently
- **Storage**: Data stored in cloud-native object storage (S3 / Azure Blob / GCS) in a proprietary columnar format
- **Micro-partitions**: 50–500 MB compressed (~16 MB uncompressed target), immutable, columnar, auto-created — the fundamental unit of storage
- **Metadata store**: Tracks min/max values per column per micro-partition, enabling partition pruning without scanning
- **Cloud Services layer** handles: authentication, access control, query parsing & optimization, metadata management, transaction management — charged only if usage exceeds 10% of daily warehouse credits
- **Virtual Warehouses**: Independent MPP clusters; T-shirt sizes XS through 6XL; each size doubles credits/nodes from prior
- **Multi-cluster warehouses** (Enterprise+): Auto-scale 1–10 clusters; economy vs. maximize mode
- **Auto-suspend**: Minimum 60 seconds (previously 5 min for some); auto-resume on query submission
- **Editions**: Standard → Enterprise → Business Critical → VPS (Virtual Private Snowflake)
  - Enterprise adds: multi-cluster warehouses, 90-day time travel, materialized views, dynamic data masking, search optimization
  - Business Critical adds: HIPAA/PCI/SOC 2 Type II, Tri-Secret Secure, database failover/failback
  - VPS: Completely isolated environment, dedicated metadata store

| Warehouse Size | Credits/Hour | Approx. Nodes |
|---------------|-------------|---------------|
| X-Small       | 1           | 1             |
| Small         | 2           | 2             |
| Medium        | 4           | 4             |
| Large         | 8           | 8             |
| X-Large       | 16          | 16            |
| 2X-Large      | 32          | 32            |
| 3X-Large      | 64          | 64            |
| 4X-Large      | 128         | 128           |

### Essential Q&A

**Q: What are the three layers of Snowflake's architecture?**
A: (1) **Storage** — centralized, persistent cloud object storage in proprietary columnar format. (2) **Compute** — virtual warehouses (MPP clusters) that execute queries independently. (3) **Cloud Services** — brain of the system handling auth, metadata, query optimization, transaction management. Each layer scales independently.

**Q: What is a micro-partition and why does it matter?**
A: An immutable, compressed columnar storage unit of 50–500 MB. Snowflake automatically organizes data into micro-partitions during ingestion. Each partition stores metadata (min/max, distinct count, null count per column) enabling partition pruning — the query engine skips partitions that cannot contain relevant data.

**Q: How does Snowflake's compute model differ from traditional data warehouses?**
A: Each virtual warehouse is an independent MPP cluster that does not share compute resources with other warehouses. Multiple warehouses can access the same data simultaneously without contention because storage is decoupled. This enables workload isolation (e.g., separate ETL and reporting warehouses).

**Q: What is the difference between scaling up and scaling out?**
A: **Scaling up** = increasing warehouse size (Small → Medium → Large) for complex/heavy queries. **Scaling out** = adding clusters via multi-cluster warehouses (Enterprise+) for high concurrency. Scale up for performance; scale out for throughput.

**Q: When does Snowflake charge for the Cloud Services layer?**
A: Cloud Services compute is free up to 10% of the daily total warehouse credit consumption. Only the excess beyond 10% is billed. Serverless features (Snowpipe, auto-clustering, etc.) are billed separately.

**Q: What are key differences between Enterprise and Business Critical editions?**
A: Enterprise adds: multi-cluster warehouses, 90-day time travel, materialized views, dynamic data masking, column-level security, search optimization, periodic rekeying. Business Critical adds: HIPAA/PCI/FedRAMP compliance, Tri-Secret Secure (customer-managed key + Snowflake key), database failover/failback, AWS PrivateLink / Azure Private Link support.

---

## 2. Data Loading & Unloading

### Key Highlights

- **Stages**: Internal (table/user/named) stored in Snowflake-managed storage; External (S3, Azure Blob, GCS) reference customer storage
- **COPY INTO `<table>`**: Bulk loading from stage → table; tracks loaded file metadata for 64 days to prevent duplicate loading
- **COPY INTO `<location>`**: Unloading from table → stage/file
- **Snowpipe**: Serverless continuous loading triggered by cloud event notifications (SQS, Event Grid, Pub/Sub) or REST API; billed per-file (serverless credits)
- **Snowpipe Streaming** (Snowpipe SDK): Low-latency row-level ingestion via API without staging files; uses offset tokens for exactly-once semantics
- **Supported file formats**: CSV, JSON, Avro, ORC, Parquet, XML
- **Key COPY options**: `ON_ERROR` (CONTINUE, SKIP_FILE, ABORT_STATEMENT), `PURGE = TRUE`, `FORCE = TRUE` (reload already-loaded files), `VALIDATION_MODE` (RETURN_ERRORS, RETURN_n_ROWS)
- **File sizing best practice**: 100–250 MB compressed for optimal parallel loading
- **PUT command**: Upload local files to internal stages (client-side encryption, auto-compression)
- **GET command**: Download files from internal stages to local filesystem

```sql
-- Bulk load from external stage
COPY INTO my_table
FROM @my_s3_stage/path/
FILE_FORMAT = (TYPE = 'PARQUET')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Create Snowpipe
CREATE PIPE my_pipe AUTO_INGEST = TRUE AS
  COPY INTO my_table FROM @my_stage
  FILE_FORMAT = (TYPE = 'JSON');

-- Unload to external stage
COPY INTO @my_stage/export/
FROM my_table
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'GZIP')
HEADER = TRUE
OVERWRITE = TRUE;
```

### Essential Q&A

**Q: What are the three types of internal stages?**
A: (1) **User stage** (`@~`) — auto-created per user, cannot be altered/dropped. (2) **Table stage** (`@%table_name`) — auto-created per table. (3) **Named internal stage** (`@my_stage`) — explicitly created, most flexible, supports file formats and can be shared across users/tables.

**Q: How does Snowpipe differ from COPY INTO for data loading?**
A: COPY INTO is a manual/scheduled bulk operation using a specified warehouse (you pay warehouse credits). Snowpipe is serverless, event-driven, continuous — loads files as they arrive in a stage, uses Snowflake-managed compute (serverless credits ~1.5x overhead vs warehouse). Snowpipe is ideal for streaming/near-real-time; COPY INTO for batch.

**Q: How does Snowflake prevent loading the same file twice?**
A: COPY INTO tracks file metadata (name, size, ETag/checksum) for **64 days**. Within this window, re-running COPY INTO on the same files is a no-op. Use `FORCE = TRUE` to override. Snowpipe uses a similar mechanism and also maintains its own load history.

**Q: What is the recommended file size for loading?**
A: **100–250 MB compressed**. Files too small create overhead; files too large prevent parallelism. Split large files into this range before loading.

**Q: What does VALIDATION_MODE do?**
A: It validates data files without actually loading them. Options: `RETURN_ERRORS` (returns all errors), `RETURN_n_ROWS` (returns first n rows that would be loaded). Useful for dry-run validation before production loads.

**Q: How do you load semi-structured data like JSON?**
A: Load into a VARIANT column using `COPY INTO` with `FILE_FORMAT = (TYPE = 'JSON')`, or load as raw and parse. For Parquet/Avro/ORC, use `MATCH_BY_COLUMN_NAME` to auto-map to relational columns, or load into VARIANT and flatten later.

---

## 3. SQL Features

### Key Highlights

- **Semi-structured types**: `VARIANT` (any JSON/XML value), `OBJECT` (key-value pairs), `ARRAY` (ordered list)
- **Dot notation & bracket notation**: `col:key::string`, `col['key']`, `col[0]`
- **FLATTEN**: Table function to explode arrays/objects into rows; supports `RECURSIVE => TRUE`
- **LATERAL**: Required with FLATTEN to reference prior table in FROM clause
- **QUALIFY**: Filter on window function results without subquery (Snowflake extension)
- **MERGE**: Upsert operations — `WHEN MATCHED THEN UPDATE`, `WHEN NOT MATCHED THEN INSERT`
- **Sequences**: `CREATE SEQUENCE` — not gap-free, not necessarily ordered within a statement
- **Window functions**: Full support — ROW_NUMBER, RANK, DENSE_RANK, NTILE, LAG, LEAD, FIRST_VALUE, LAST_VALUE, NTH_VALUE, plus aggregate windows
- **Recursive CTEs**: `WITH RECURSIVE` for hierarchical queries
- **GENERATOR**: Table function to generate rows — `GENERATOR(ROWCOUNT => 1000)` or `GENERATOR(TIMELIMIT => 5)`
- **TRY_ functions**: `TRY_CAST`, `TRY_TO_NUMBER`, `TRY_TO_DATE` — return NULL instead of error on conversion failure
- **OBJECT_CONSTRUCT / ARRAY_AGG / ARRAY_CONSTRUCT**: Build semi-structured data in queries

```sql
-- FLATTEN a JSON array
SELECT f.value:name::STRING AS name, f.value:age::INT AS age
FROM my_table, LATERAL FLATTEN(input => json_col:people) f;

-- QUALIFY to deduplicate
SELECT *
FROM orders
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date DESC) = 1;

-- MERGE / Upsert
MERGE INTO target t USING source s ON t.id = s.id
WHEN MATCHED AND s.updated > t.updated THEN UPDATE SET t.val = s.val
WHEN NOT MATCHED THEN INSERT (id, val) VALUES (s.id, s.val);

-- Recursive CTE for hierarchy
WITH RECURSIVE org AS (
  SELECT id, name, manager_id, 1 AS level FROM employees WHERE manager_id IS NULL
  UNION ALL
  SELECT e.id, e.name, e.manager_id, o.level + 1
  FROM employees e JOIN org o ON e.manager_id = o.id
)
SELECT * FROM org;
```

### Essential Q&A

**Q: What is the VARIANT data type and when is it used?**
A: VARIANT can store any semi-structured value — JSON objects, arrays, scalars. Maximum size 16 MB compressed. Used for ingesting JSON/XML data, schema-on-read patterns, and storing flexible/evolving schemas. Queried using colon notation: `col:key:nested_key::datatype`.

**Q: How does FLATTEN work and when do you use LATERAL?**
A: FLATTEN is a table function that expands an array or object into rows. LATERAL is required when FLATTEN references a column from a preceding table in the same FROM clause (correlated). Key output columns: `SEQ`, `KEY`, `PATH`, `INDEX`, `VALUE`, `THIS`.

**Q: What is QUALIFY and why is it useful?**
A: QUALIFY filters rows based on window function results, similar to how HAVING filters aggregate results. It eliminates the need for a subquery/CTE just to filter on ROW_NUMBER() or RANK(). Execution order: WHERE → GROUP BY → HAVING → QUALIFY.

**Q: How do sequences behave in Snowflake?**
A: Sequences generate unique numbers but are **not gap-free** and **not necessarily ordered** within a multi-row INSERT. Use `seq_col.NEXTVAL` in INSERT/SELECT. For gap-free numbering, use ROW_NUMBER() window function instead.

**Q: What is the difference between MERGE and INSERT ... ON CONFLICT?**
A: Snowflake does not support `INSERT ... ON CONFLICT`. Use MERGE for upsert logic. MERGE supports multiple WHEN MATCHED / WHEN NOT MATCHED clauses with conditions, and can perform UPDATE, DELETE, or INSERT actions.

**Q: How do you handle type conversion errors gracefully?**
A: Use `TRY_` variants: `TRY_CAST(x AS INT)`, `TRY_TO_NUMBER(x)`, `TRY_TO_DATE(x)`. These return NULL on failure instead of raising an error, making them ideal for semi-structured or dirty data.

---

## 4. Performance & Optimization

### Key Highlights

- **Result cache**: Persists for **24 hours** (resets on underlying data change); served from Cloud Services layer — no warehouse needed; must match exact query text + context
- **Metadata cache**: Cloud Services layer caches micro-partition metadata (min/max, row count, etc.) — enables COUNT(*), MIN, MAX without warehouse
- **Warehouse local disk cache (SSD)**: Caches data read from remote storage; cleared on warehouse suspend; persists across queries while warehouse is running
- **Partition pruning**: Primary optimization — uses micro-partition metadata to skip irrelevant partitions
- **Clustering keys**: Define sort order for large tables (multi-TB); Snowflake auto-maintains via background reclustering (serverless credits); check with `SYSTEM$CLUSTERING_INFORMATION('table')`
- **Search Optimization Service** (Enterprise+): Serverless, accelerates selective point lookups, `IN` lists, substring/regex (`LIKE`, `ILIKE`), VARIANT field access, geospatial; maintained automatically
- **Materialized Views** (Enterprise+): Pre-computed, auto-refreshed (serverless credits); best for expensive aggregations on large tables that change infrequently; cannot contain joins/UDFs/HAVING/LIMIT
- **Query Profile**: Visual execution plan in web UI — shows operator tree, statistics, spilling, pruning ratios
- **Spilling**: When a query exceeds warehouse memory → spills to local SSD → then to remote storage; sign to scale up warehouse
- **Pruning ratio**: Aim for high pruning — `Partitions scanned` / `Partitions total` should be low

| Cache Type | Duration | Scope | Invalidation |
|-----------|----------|-------|-------------|
| Result cache | 24 hours | Per-user + role | Data change or DDL |
| Metadata cache | Persistent | Cloud Services | Metadata change |
| Warehouse cache (SSD) | Until suspend | Per-warehouse | Warehouse suspend/resize |

```sql
-- Check clustering quality
SELECT SYSTEM$CLUSTERING_INFORMATION('my_table', '(date_col, region)');

-- Add clustering key
ALTER TABLE my_table CLUSTER BY (date_col, region);

-- Enable search optimization
ALTER TABLE my_table ADD SEARCH OPTIMIZATION
  ON EQUALITY(user_id), SUBSTRING(email);

-- Create materialized view
CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT date_trunc('day', sale_date) AS day, region, SUM(amount) AS total
FROM sales
GROUP BY 1, 2;
```

### Essential Q&A

**Q: What are the three levels of caching in Snowflake?**
A: (1) **Result cache** (24h) — exact query results stored in Cloud Services, no warehouse needed. (2) **Metadata cache** — min/max/count per micro-partition, answers simple aggregates instantly. (3) **Warehouse local disk cache** — SSD cache of remote storage data, cleared on suspend.

**Q: When should you add a clustering key?**
A: On tables that are **multi-TB** in size with queries that frequently filter/join on specific columns but have poor natural clustering. Check `SYSTEM$CLUSTERING_INFORMATION` first. Good candidates: date columns, high-cardinality join keys. Do NOT add clustering keys to small tables — the reclustering cost outweighs benefit.

**Q: How does clustering differ from indexing in traditional databases?**
A: Clustering keys define the physical sort order of micro-partitions — they reorganize data so that rows with similar key values are co-located. There are no B-tree indexes. Snowflake uses micro-partition pruning (metadata min/max) instead of index seeks. Clustering improves pruning effectiveness.

**Q: What does spilling indicate and how do you fix it?**
A: Spilling means the query ran out of warehouse memory and wrote intermediate results to local SSD (acceptable) or remote storage (bad for performance). Fixes: (1) Scale up the warehouse size. (2) Optimize the query to reduce data volume (better filters, fewer joins). (3) Break the query into smaller steps.

**Q: When should you use a materialized view vs. a regular table with scheduled refresh?**
A: Use materialized views when you need automatic, transactionally consistent refresh without managing ETL. Use a regular summary table when the query includes joins, UDFs, or complex logic that materialized views don't support, or when you need control over refresh timing/cost.

**Q: What is the Search Optimization Service and when is it beneficial?**
A: A serverless background service (Enterprise+) that builds optimized search access paths. Best for highly selective queries (point lookups, `IN` lists with few values, substring searches) on large tables. Not beneficial for full table scans or broad range filters. Costs serverless credits for maintenance.

---

## 5. Security

### Key Highlights

- **Access control model**: Combines **RBAC** (Role-Based) and **DAC** (Discretionary) — every object has an owner role
- **System-defined roles** (hierarchy): ACCOUNTADMIN → SECURITYADMIN → USERADMIN / SYSADMIN → PUBLIC
- **ACCOUNTADMIN**: Top-level role; should have MFA, limited usage, not used for day-to-day tasks
- **SYSADMIN**: Should own all databases/warehouses; custom roles should be granted to SYSADMIN
- **Encryption**: End-to-end AES-256 encryption; all data encrypted at rest and in transit by default
- **Key rotation**: Automatic annual rekeying (Enterprise+); customer-managed keys via **Tri-Secret Secure** (Business Critical+)
- **Network policies**: IP allow/block lists; applied at account or user level
- **Dynamic Data Masking** (Enterprise+): Column-level masking policies applied at query time based on role
- **Row Access Policies** (Enterprise+): Row-level security — filter rows based on querying role/user
- **External Tokenization**: Integrates with external tokenization services for PCI/sensitive data
- **Data classification**: Auto-classifies sensitive data (PII, etc.); tag-based governance with `SYSTEM$CLASSIFY`
- **Tags**: Key-value metadata on objects; support tag-based masking policies
- **Object tagging + masking**: Tag a column as "PII" → masking policy automatically applies

```sql
-- Create and apply masking policy
CREATE MASKING POLICY mask_ssn AS (val STRING)
RETURNS STRING ->
  CASE WHEN CURRENT_ROLE() IN ('HR_ROLE') THEN val
       ELSE '***-**-' || RIGHT(val, 4)
  END;

ALTER TABLE employees MODIFY COLUMN ssn SET MASKING POLICY mask_ssn;

-- Row access policy
CREATE ROW ACCESS POLICY region_filter AS (region_val VARCHAR)
RETURNS BOOLEAN ->
  CURRENT_ROLE() = 'ADMIN_ROLE'
  OR region_val = CURRENT_SESSION()::VARIANT:region::VARCHAR;

ALTER TABLE sales ADD ROW ACCESS POLICY region_filter ON (region);

-- Network policy
CREATE NETWORK POLICY office_only
  ALLOWED_IP_LIST = ('203.0.113.0/24')
  BLOCKED_IP_LIST = ('203.0.113.99');
ALTER ACCOUNT SET NETWORK_POLICY = office_only;
```

### Essential Q&A

**Q: How does Snowflake's role hierarchy work?**
A: ACCOUNTADMIN is the top role (inherits all). SECURITYADMIN manages grants and roles. USERADMIN creates users/roles. SYSADMIN manages all objects (databases, warehouses). PUBLIC is granted to all users by default. Custom roles should be granted up to SYSADMIN so it can manage all objects.

**Q: What is the difference between RBAC and DAC in Snowflake?**
A: **RBAC**: Privileges are granted to roles, roles are granted to users. You access objects through your active role. **DAC**: Every object has an owner (the role that created it), and the owner can grant privileges to other roles. Snowflake uses both simultaneously.

**Q: What is Tri-Secret Secure?**
A: A Business Critical+ feature where data is encrypted with a composite key derived from (1) a Snowflake-managed key and (2) a customer-managed key (in AWS KMS / Azure Key Vault / GCP KMS). The customer can revoke their key to make data unreadable — providing full control over data access.

**Q: How does Dynamic Data Masking work?**
A: A masking policy is a SQL function attached to a column. At query time, Snowflake evaluates the policy based on the querying role/user and returns masked or unmasked data. Policies are centrally managed and apply regardless of how data is accessed (direct query, view, clone).

**Q: What is a Row Access Policy and how does it differ from a secure view?**
A: A Row Access Policy is a centralized, reusable policy object that filters rows based on the querying context (role, user). Unlike secure views, RAPs are applied directly to tables and work across all queries — no need to force users through a specific view. RAPs are more scalable and maintainable for multi-tenant or region-based access control.

**Q: How does data encryption work at rest and in transit?**
A: All data at rest is AES-256 encrypted by default — micro-partitions, stages, result caches. All data in transit uses TLS 1.2+. Keys are managed by Snowflake with automatic annual rotation (Enterprise+). No configuration needed; encryption is always on.

---

## 6. Data Sharing & Marketplace

### Key Highlights

- **Secure Data Sharing**: Share live, read-only data across Snowflake accounts with **zero-copy** — no data movement, no ETL
- **Shares**: Provider creates a share, adds databases/schemas/tables/views, grants to consumer accounts
- **Consumer** creates a database from the share — queries execute on consumer's warehouse
- **Shared objects**: Tables, external tables, secure views, secure UDFs — not raw views (must be secure)
- **Reader accounts**: Snowflake accounts created by the provider for non-Snowflake consumers; provider pays compute costs
- **Data Exchange**: Private, governed hub for multiple organizations to share data bidirectionally
- **Snowflake Marketplace**: Public/private listings; free and paid data sets; powered by secure data sharing
- **Data Clean Rooms**: Privacy-preserving analytics — multiple parties analyze overlapping data without exposing raw records; built on secure shares + policies
- **Listings** can be: free, paid (usage-based or flat-fee), or personalized (request-based)
- **Cross-region/cross-cloud sharing**: Requires database replication; data must be replicated to the consumer's region/cloud first

```sql
-- Provider: create and populate a share
CREATE SHARE sales_share;
GRANT USAGE ON DATABASE analytics_db TO SHARE sales_share;
GRANT USAGE ON SCHEMA analytics_db.public TO SHARE sales_share;
GRANT SELECT ON TABLE analytics_db.public.sales TO SHARE sales_share;
ALTER SHARE sales_share ADD ACCOUNTS = 'consumer_acct';

-- Consumer: create database from share
CREATE DATABASE shared_sales FROM SHARE provider_acct.sales_share;
SELECT * FROM shared_sales.public.sales; -- uses consumer's warehouse
```

### Essential Q&A

**Q: What does "zero-copy" mean in Snowflake data sharing?**
A: The consumer accesses the provider's actual storage layer — no data is copied, moved, or duplicated. The consumer sees live, up-to-date data. The provider controls access and can revoke at any time. The consumer pays only for their warehouse compute.

**Q: What is the difference between a standard consumer and a reader account?**
A: A **standard consumer** has their own Snowflake account and pays their own costs. A **reader account** is a Snowflake account created and managed by the provider for non-Snowflake consumers; the provider pays for the reader account's compute (warehouse) costs.

**Q: Why must shared views be SECURE views?**
A: Secure views hide the view definition and prevent data leakage through optimization. Without SECURE, a consumer could potentially infer underlying data or view logic through query plan inspection. Snowflake requires SECURE views in shares to enforce this protection.

**Q: Can you share data across clouds or regions?**
A: Not directly. Cross-region/cross-cloud sharing requires **database replication** — the provider replicates the database to the consumer's region/cloud, then shares from the replicated copy. This involves additional storage and compute costs.

**Q: What is a Data Clean Room?**
A: A secure environment where multiple parties can perform joint analytics (e.g., audience overlap, attribution) on combined datasets without either party seeing the other's raw data. Built using secure shares, row access policies, and restricted query patterns.

---

## 7. Data Engineering Features

### Key Highlights

- **Streams**: Track DML changes (INSERT, UPDATE, DELETE) on a table — Snowflake's native CDC mechanism
  - Types: Standard (default, tracks all), Append-only (inserts only), Insert-only (for external tables)
  - Streams create a "change table" view with `METADATA$ACTION`, `METADATA$ISUPDATE`, `METADATA$ROW_ID`
  - Consumed within a DML transaction — offset advances after successful commit
- **Tasks**: Schedule SQL execution — cron or interval-based; supports DAG (tree) dependencies
  - Serverless tasks (no warehouse needed) or warehouse-backed
  - Must be explicitly `RESUME`d after creation (created in suspended state)
- **Dynamic Tables**: Declarative data pipelines — define the target as a SQL query + target lag
  - Snowflake auto-manages refresh; replaces Streams + Tasks for many ETL patterns
  - `TARGET_LAG = '10 minutes'` or `DOWNSTREAM` (refresh as needed by downstream consumers)
- **Snowpark**: DataFrame API for Python, Java, Scala — pushes computation to Snowflake (no data movement)
  - Supports UDFs, UDTFs, stored procedures in Python/Java/Scala
  - Snowpark ML for feature engineering and model training
- **External Tables**: Read-only tables over files in external stages (S3/Azure/GCS); metadata in Snowflake, data stays external
  - Auto-refresh via cloud event notifications
  - Query with partition columns for pruning
- **Iceberg Tables**: Snowflake-managed tables using open Apache Iceberg format
  - Interoperable with Spark, Flink, Trino — open table format
  - Supports Snowflake as catalog or external catalog (AWS Glue, etc.)
- **UDFs**: SQL, JavaScript, Python, Java, Scala; scalar or tabular (UDTF)
- **Stored Procedures**: Support JavaScript, Python, Java, Scala, Snowflake Scripting (SQL)
  - Can run with caller's rights or owner's rights

```sql
-- Stream + Task CDC pattern
CREATE STREAM orders_stream ON TABLE orders;

CREATE TASK process_orders
  WAREHOUSE = etl_wh
  SCHEDULE = 'USING CRON 0 * * * * UTC'  -- every hour
  WHEN SYSTEM$STREAM_HAS_DATA('orders_stream')
AS
  INSERT INTO orders_history
  SELECT *, CURRENT_TIMESTAMP() AS loaded_at
  FROM orders_stream
  WHERE METADATA$ACTION = 'INSERT';

ALTER TASK process_orders RESUME;

-- Dynamic Table
CREATE DYNAMIC TABLE daily_agg
  TARGET_LAG = '30 minutes'
  WAREHOUSE = transform_wh
AS
  SELECT date_trunc('day', order_date) AS day, SUM(amount) AS total
  FROM orders
  GROUP BY 1;

-- Python UDF
CREATE FUNCTION sentiment(text VARCHAR)
RETURNS FLOAT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.8'
HANDLER = 'analyze'
AS $$
def analyze(text):
    return 0.5  -- placeholder
$$;
```

### Essential Q&A

**Q: How do Snowflake Streams work for CDC?**
A: A stream creates a change-tracking view on a table. It records INSERT, UPDATE, DELETE changes with metadata columns (`METADATA$ACTION`, `METADATA$ISUPDATE`). When a DML transaction reads from the stream and commits successfully, the stream offset advances. If the transaction fails, changes remain in the stream. Streams have no additional storage cost — they use table versioning.

**Q: What is the relationship between Streams and Tasks?**
A: Streams capture **what changed**; Tasks define **when to process it**. Typical pattern: a Task runs on a schedule, checks `SYSTEM$STREAM_HAS_DATA()` in its WHEN clause, and processes the stream's changes. Together they form a serverless CDC pipeline.

**Q: How do Dynamic Tables simplify pipelines compared to Streams + Tasks?**
A: Dynamic Tables are declarative — you define the desired result as a SQL query and set a target lag. Snowflake automatically determines when and how to refresh. No need to manually manage stream offsets, task scheduling, error handling, or DAG ordering. Ideal for multi-step transformation pipelines.

**Q: What is the difference between an external table and a regular table?**
A: External tables are read-only, metadata-only references to files in external storage. Data stays in your cloud storage; Snowflake stores only the metadata. Regular tables store data in Snowflake's managed storage. External tables are slower but avoid data duplication; useful for data lake query patterns.

**Q: What are Iceberg Tables and why are they significant?**
A: Iceberg Tables use the open Apache Iceberg format, making data interoperable with other engines (Spark, Flink, Trino) while still being fully managed by Snowflake. They support ACID transactions, time travel, and schema evolution. Key for avoiding vendor lock-in and enabling multi-engine architectures.

**Q: What is Snowpark and when would you use it?**
A: Snowpark is a developer framework providing DataFrame APIs in Python, Java, and Scala. Code executes inside Snowflake (pushdown) — no data leaves Snowflake. Use it when SQL is insufficient for complex transformations, ML feature engineering, or when developers prefer imperative programming. Also used for writing UDFs and stored procedures in Python.

**Q: What is the difference between a UDF and a stored procedure?**
A: **UDFs** are called within SQL (SELECT, WHERE) and return values per row; they cannot perform DDL/DML. **Stored procedures** are called with CALL, can execute DDL/DML, manage transactions, contain procedural logic, and support owner's/caller's rights.

---

## 8. Time Travel & Data Protection

### Key Highlights

- **Time Travel**: Query or restore data as it existed at a point in the past
  - Standard edition: 0–1 day retention
  - Enterprise+: 0–90 days retention (configurable via `DATA_RETENTION_TIME_IN_DAYS`)
  - Works on tables, schemas, databases
  - Methods: `AT(TIMESTAMP => ...)`, `AT(OFFSET => ...)`, `BEFORE(STATEMENT => '...')`
- **Fail-Safe**: **7-day** period after Time Travel expires; Snowflake-managed, not user-accessible — only Snowflake Support can recover data; incurs storage cost
- **Zero-Copy Cloning**: `CREATE ... CLONE` — instant, metadata-only clone; shares storage until divergence
  - Works on tables, schemas, databases, stages, file formats, sequences, streams, tasks
  - Cloned data is independent — changes to clone do not affect source
  - Clones inherit grants only for databases/schemas (not table-level)
- **Storage cost**: Time Travel + Fail-Safe storage is additive to active storage
- **UNDROP**: Restore dropped tables/schemas/databases within Time Travel period

```sql
-- Time Travel queries
SELECT * FROM orders AT(TIMESTAMP => '2026-03-07 10:00:00'::TIMESTAMP);
SELECT * FROM orders AT(OFFSET => -3600);  -- 1 hour ago
SELECT * FROM orders BEFORE(STATEMENT => '<query_id>');

-- Restore a table to a previous state
CREATE TABLE orders_restored CLONE orders AT(TIMESTAMP => '2026-03-07 10:00:00'::TIMESTAMP);

-- UNDROP
DROP TABLE orders;
UNDROP TABLE orders;

-- Zero-copy clone
CREATE DATABASE dev_db CLONE prod_db;
CREATE TABLE test_orders CLONE orders;
```

### Essential Q&A

**Q: What is the difference between Time Travel and Fail-Safe?**
A: **Time Travel** is user-accessible — you can query or clone data at a past point within the retention period (1–90 days). **Fail-Safe** is an additional 7-day period after Time Travel expires that is **only accessible by Snowflake Support** for disaster recovery. Both incur storage costs for historical data.

**Q: How does zero-copy cloning work internally?**
A: Cloning creates a new metadata entry pointing to the same micro-partitions as the source. No data is physically copied at clone time — it is instant and free. As either source or clone is modified, new micro-partitions are created independently. Storage cost applies only to diverged (changed) data.

**Q: Can you clone a running/active database for development?**
A: Yes — this is a primary use case. `CREATE DATABASE dev CLONE prod` creates an instant copy of the entire database (all schemas, tables, views, etc.) that developers can modify freely without affecting production. Cost-effective for testing and development environments.

**Q: What happens to Time Travel data when you change the retention period?**
A: Reducing retention immediately removes historical data beyond the new retention window — it cannot be recovered (except during Fail-Safe). Increasing retention only applies to new changes going forward; it does not recover already-purged historical data.

**Q: How much storage does Time Travel consume?**
A: Time Travel stores changed micro-partitions (not full copies). For a table with heavy updates/deletes, storage can be significant since every changed micro-partition version is retained. For append-only tables, Time Travel storage is minimal. Check `TABLE_STORAGE_METRICS` view for details.

---

## 9. Administration & Monitoring

### Key Highlights

- **ACCOUNT_USAGE** schema (`SNOWFLAKE` database): 365-day history for most views; 45-minute latency
  - Key views: `QUERY_HISTORY`, `WAREHOUSE_METERING_HISTORY`, `LOGIN_HISTORY`, `STORAGE_USAGE`, `ACCESS_HISTORY`, `COPY_HISTORY`
- **INFORMATION_SCHEMA**: Real-time but limited history (7–14 days); per-database
  - Key views: `TABLES`, `COLUMNS`, `VIEWS`, `TABLE_PRIVILEGES`, `USAGE_PRIVILEGES`
- **Resource Monitors**: Set credit quotas on warehouses or accounts; actions: Notify, Suspend, Suspend Immediately
  - Thresholds at percentage levels (e.g., 75% notify, 90% suspend)
  - Reset frequency: Daily, Weekly, Monthly, Yearly, Never
- **Warehouse monitoring**: Track credit consumption, query load, queuing, auto-scaling events
- **Cost management levers**: Warehouse auto-suspend, right-sizing, resource monitors, serverless cost tracking
- **Access History**: Tracks which columns/objects were accessed by which user/role — crucial for auditing and compliance

```sql
-- Top 10 most expensive queries (last 30 days)
SELECT query_id, query_text, warehouse_name,
       total_elapsed_time/1000 AS seconds,
       credits_used_cloud_services
FROM snowflake.account_usage.query_history
WHERE start_time > DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 10;

-- Credit consumption by warehouse
SELECT warehouse_name, SUM(credits_used) AS total_credits
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time > DATEADD('month', -1, CURRENT_TIMESTAMP())
GROUP BY 1 ORDER BY 2 DESC;

-- Resource monitor
CREATE RESOURCE MONITOR etl_monitor
  WITH CREDIT_QUOTA = 500
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 90 PERCENT DO SUSPEND
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE etl_wh SET RESOURCE_MONITOR = etl_monitor;
```

### Essential Q&A

**Q: What is the difference between ACCOUNT_USAGE and INFORMATION_SCHEMA?**
A: **ACCOUNT_USAGE** (in `SNOWFLAKE` database): account-wide, 365-day history, 45-minute data latency, requires ACCOUNTADMIN or granted access. **INFORMATION_SCHEMA** (per database): real-time data, limited to 7–14 days history, available to any role with database access. Use ACCOUNT_USAGE for historical analysis; INFORMATION_SCHEMA for real-time metadata queries.

**Q: How do Resource Monitors control costs?**
A: Resource Monitors track credit consumption against a defined quota for a warehouse or account. When usage hits configured thresholds, actions trigger: **Notify** (email alert), **Suspend** (finish running queries then suspend), **Suspend Immediately** (kill running queries). Set multiple thresholds for escalating responses.

**Q: What are the most important ACCOUNT_USAGE views for cost management?**
A: `WAREHOUSE_METERING_HISTORY` (warehouse credits), `AUTOMATIC_CLUSTERING_HISTORY` (reclustering credits), `MATERIALIZED_VIEW_REFRESH_HISTORY`, `SEARCH_OPTIMIZATION_HISTORY`, `SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY`, `STORAGE_USAGE` (storage costs), `SERVERLESS_TASK_HISTORY`. Together, these cover all billable dimensions.

**Q: How should you structure the role hierarchy for a production environment?**
A: Create functional roles (DATA_ENGINEER, ANALYST, etc.) and grant them to SYSADMIN. Create a separate role for sensitive operations (e.g., SECURITY_ADMIN). Keep ACCOUNTADMIN usage minimal — use it only for account-level settings. Use custom roles for applications and service accounts. Never grant ACCOUNTADMIN to automated processes.

**Q: How do you identify and fix slow queries?**
A: (1) Use `QUERY_HISTORY` views to find high-elapsed-time queries. (2) Open the Query Profile in the web UI — check for full table scans, low pruning ratios, spilling, exploding joins. (3) Add/improve filters, use clustering keys for large tables, check warehouse sizing. (4) Look at `BYTES_SPILLED_TO_LOCAL_STORAGE` and `BYTES_SPILLED_TO_REMOTE_STORAGE` columns.

---

## 10. Integration & Ecosystem

### Key Highlights

- **Python Connector**: `snowflake-connector-python` — supports pandas DataFrames via `fetch_pandas_all()`, async queries, key-pair auth
- **Spark Connector**: Bidirectional pushdown between Spark and Snowflake; reads/writes via `net.snowflake.spark.snowflake`
- **Kafka Connector**: Snowflake Kafka Connector sinks data from Kafka topics into Snowflake tables via internal stages + Snowpipe
  - Supports schema registry (Avro, JSON, Protobuf)
  - Exactly-once delivery semantics
- **dbt (data build tool)**: First-class support via `dbt-snowflake` adapter
  - Models, tests, snapshots, seeds, incremental materializations
  - `dbt run`, `dbt test`, `dbt build` — manages transformation DAGs
- **CI/CD**: SchemaChange (Flyway-style SQL migration), Terraform Snowflake provider, Snowflake CLI (`snow`)
- **Cortex AI/ML**: Built-in LLM functions (`SNOWFLAKE.CORTEX.COMPLETE`, `SUMMARIZE`, `SENTIMENT`, `TRANSLATE`), ML functions (`FORECAST`, `ANOMALY_DETECTION`, `CLASSIFICATION`)
- **SnowSQL**: CLI client for Snowflake; supports variables, scripting, PUT/GET
- **Snowflake CLI (`snow`)**: Modern CLI for managing Snowflake objects, Snowpark, Streamlit apps, Native Apps
- **Key-pair authentication**: For service accounts — RSA 2048-bit minimum; avoids password-based auth for automation

```sql
-- Cortex AI examples
SELECT SNOWFLAKE.CORTEX.SENTIMENT('This product is amazing!');  -- returns score
SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large', 'Summarize: ' || text_col)
FROM documents;

-- ML forecasting
CREATE SNOWFLAKE.ML.FORECAST model_sales(
  INPUT_DATA => SYSTEM$REFERENCE('TABLE', 'sales_ts'),
  TIMESTAMP_COLNAME => 'ds',
  TARGET_COLNAME => 'revenue'
);
CALL model_sales!FORECAST(FORECASTING_PERIODS => 30);
```

```python
# Python Connector
import snowflake.connector
conn = snowflake.connector.connect(
    account='myaccount', user='myuser',
    password='mypass', warehouse='wh',
    database='db', schema='public'
)
cur = conn.cursor()
cur.execute("SELECT * FROM my_table LIMIT 10")
df = cur.fetch_pandas_all()
```

### Essential Q&A

**Q: How does the Kafka Connector load data into Snowflake?**
A: The connector reads messages from Kafka topics, buffers them, writes to an internal stage as files, then uses Snowpipe to load into target tables. It supports Avro/JSON/Protobuf schemas via schema registry and provides exactly-once delivery through offset tracking.

**Q: What is the recommended approach for CI/CD with Snowflake?**
A: Use **SchemaChange** (Python-based, Flyway-style) for SQL migrations — versioned SQL scripts applied in order. For infrastructure-as-code, use the **Terraform Snowflake provider** to manage warehouses, roles, grants, databases. Combine with Git + CI pipelines (GitHub Actions, Azure DevOps) for automated deployment.

**Q: How does dbt work with Snowflake?**
A: dbt compiles SQL model files into CREATE TABLE/VIEW AS SELECT statements and executes them in dependency order. It manages materializations (view, table, incremental, ephemeral), runs tests (unique, not_null, relationships, custom), and generates documentation. dbt handles the T in ELT — transformations inside Snowflake.

**Q: What are Cortex AI functions and when would you use them?**
A: Cortex provides serverless AI/ML functions callable directly in SQL. **LLM functions**: COMPLETE (text generation), SUMMARIZE, SENTIMENT, TRANSLATE — no model management needed. **ML functions**: FORECAST, ANOMALY_DETECTION, CLASSIFICATION — built-in time series and supervised learning. Use them when you need AI capabilities without external infrastructure.

**Q: What is the difference between the Snowflake Python Connector and Snowpark Python?**
A: The **Python Connector** is a traditional database driver — sends SQL strings, gets results back as Python objects/DataFrames. **Snowpark** is a DataFrame API that builds query plans lazily and executes them in Snowflake — pushes Python logic to the server. Use the connector for simple queries; use Snowpark for complex transformations, UDFs, and ML pipelines.

**Q: How should service accounts authenticate to Snowflake?**
A: Use **key-pair authentication** (RSA 2048-bit+) instead of passwords. Generate a key pair, assign the public key to the Snowflake user (`ALTER USER SET RSA_PUBLIC_KEY=...`), and use the private key in the connector configuration. This avoids password rotation issues and is more secure for automated pipelines.

---

## Quick-Reference Numbers Cheat Sheet

| Metric | Value |
|--------|-------|
| Micro-partition size (compressed) | 50–500 MB |
| VARIANT max size | 16 MB |
| Result cache duration | 24 hours |
| Fail-Safe period | 7 days (non-configurable) |
| Time Travel max (Enterprise+) | 90 days |
| Time Travel max (Standard) | 1 day |
| COPY INTO file tracking | 64 days |
| Recommended file size for loading | 100–250 MB compressed |
| Max warehouse size | 6X-Large (in some clouds) |
| Cloud Services free threshold | 10% of daily warehouse credits |
| Network policy applies to | Account or individual user |
| ACCOUNT_USAGE data latency | 45 minutes |
| ACCOUNT_USAGE retention | 365 days |
| INFORMATION_SCHEMA retention | 7–14 days |
| Key-pair minimum key size | 2048-bit RSA |
| Max clusters (multi-cluster WH) | 10 |
| Encryption standard | AES-256, end-to-end |
| Key rotation (Enterprise+) | Annual automatic rekeying |

---

*This quick reference covers the essential concepts across all major Snowflake domains. For detailed explanations and examples, refer to the individual topic files in the [Snowflake section](../snowflake/README.md).*
