# Storage Layer & Micro-Partitions

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### Cloud Object Storage Backends

Snowflake does not manage its own storage infrastructure. Instead, it stores all data in the cloud provider's native object storage service:

| Cloud Platform         | Storage Backend          | Durability              |
|------------------------|--------------------------|-------------------------|
| AWS                    | Amazon S3                | 99.999999999% (11 nines)|
| Microsoft Azure        | Azure Blob Storage       | 99.999999999%           |
| Google Cloud Platform  | Google Cloud Storage     | 99.999999999%           |

**Key implications:**

- Storage scales automatically and is virtually unlimited — you never need to provision disks or manage capacity.
- Snowflake handles all interactions with the object store — users never see S3 bucket paths or storage containers.
- Data is always encrypted at rest (AES-256) and in transit (TLS 1.2).
- Storage costs are billed separately from compute, on a per-TB-per-month basis based on the average compressed data stored.

```
Typical Snowflake Storage Costs (approximate, varies by edition/region):
- On-Demand: ~$40/TB/month
- Capacity (pre-purchased): ~$23/TB/month
- Data is billed in compressed size (Snowflake compresses aggressively)
```

---

### What Is a Micro-Partition?

A micro-partition is the fundamental unit of data storage in Snowflake. Every table's data is automatically organized into micro-partitions.

**Characteristics:**

| Property          | Detail                                                                 |
|-------------------|------------------------------------------------------------------------|
| **Size**          | 50 to 500 MB of compressed data (typically ~16 MB uncompressed per column section) |
| **Format**        | Snowflake's proprietary columnar format                                |
| **Immutability**  | Once written, a micro-partition is never modified — only replaced       |
| **Organization**  | Data is partitioned automatically based on insertion order              |
| **Compression**   | Each column is compressed independently using type-specific algorithms  |
| **Encryption**    | Encrypted with AES-256 at rest                                         |

```
Table: ORDERS (1 billion rows, ~200 GB compressed)
┌──────────────────────────────────────────────────────┐
│                                                      │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐     ┌──────┐   │
│  │ MP 1 │ │ MP 2 │ │ MP 3 │ │ MP 4 │ ... │MP 800│   │
│  │~250MB│ │~250MB│ │~250MB│ │~250MB│     │~250MB│   │
│  └──────┘ └──────┘ └──────┘ └──────┘     └──────┘   │
│                                                      │
│  Each MP contains a contiguous range of rows         │
│  organized in columnar format                        │
└──────────────────────────────────────────────────────┘
```

---

### Columnar Storage Within Micro-Partitions

Within each micro-partition, data is stored **column-by-column**, not row-by-row.

**Row-oriented storage (traditional RDBMS):**
```
Row 1: [order_id=1, date=2025-01-01, customer=42, amount=100.00]
Row 2: [order_id=2, date=2025-01-01, customer=17, amount=250.50]
Row 3: [order_id=3, date=2025-01-02, customer=42, amount=75.00]
```

**Columnar storage (Snowflake micro-partition):**
```
order_id column:  [1, 2, 3, ...]        <- stored together, compressed
date column:      [2025-01-01, 2025-01-01, 2025-01-02, ...]
customer column:  [42, 17, 42, ...]
amount column:    [100.00, 250.50, 75.00, ...]
```

**Why columnar storage matters for analytics:**

1. **Column pruning:** A query that selects only 3 out of 50 columns reads only those 3 columns' data — the other 47 are never read from storage.
2. **Better compression:** Values in a single column tend to be similar (same data type, similar ranges), leading to much higher compression ratios than row-oriented storage.
3. **Vectorized processing:** The compute engine processes columns in batches (vectors), leveraging CPU cache lines and SIMD instructions for faster execution.

```sql
-- This query only reads 2 columns from potentially hundreds
-- Snowflake reads only the 'region' and 'revenue' column data from each micro-partition
SELECT region, SUM(revenue)
FROM sales_fact
GROUP BY region;
```

---

### Immutable Micro-Partitions

Micro-partitions are **immutable** — they are never modified in place. This is a foundational design principle that enables several key Snowflake features.

**What happens during DML operations:**

| Operation   | What Snowflake Does                                                                              |
|-------------|--------------------------------------------------------------------------------------------------|
| **INSERT**  | Creates new micro-partitions containing the inserted rows.                                       |
| **DELETE**  | Marks affected micro-partitions for replacement. Creates new micro-partitions containing only the surviving rows from affected partitions. Unaffected partitions are untouched. |
| **UPDATE**  | Treated as DELETE + INSERT. Affected micro-partitions are replaced with new ones containing the modified rows. |
| **MERGE**   | Combination of INSERT/UPDATE/DELETE. Affected micro-partitions are replaced; unaffected ones remain. |

```
UPDATE orders SET status = 'SHIPPED' WHERE order_id = 500;

Before:
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│  MP 1          │  │  MP 2          │  │  MP 3          │
│  rows 1-1000   │  │  rows 1001-2000│  │  rows 2001-3000│
│  (order 500    │  │                │  │                │
│   is here)     │  │                │  │                │
└────────────────┘  └────────────────┘  └────────────────┘

After:
┌────────────────┐  ┌────────────────┐  ┌────────────────┐
│  MP 1 (old)    │  │  MP 2          │  │  MP 3          │
│  RETAINED for  │  │  (unchanged)   │  │  (unchanged)   │
│  Time Travel   │  │                │  │                │
└────────────────┘  └────────────────┘  └────────────────┘
┌────────────────┐
│  MP 1' (new)   │
│  rows 1-1000   │
│  order 500 now │
│  has status    │
│  'SHIPPED'     │
└────────────────┘
```

**Features enabled by immutability:**

- **Time Travel** — old micro-partitions are retained, allowing queries against historical data.
- **Fail-Safe** — after Time Travel expires, micro-partitions are kept for 7 additional days for disaster recovery (Snowflake-managed).
- **Zero-Copy Cloning** — a clone shares the same micro-partitions as the source; only divergent changes create new partitions.
- **ACID transactions** — snapshot isolation is achieved by referencing the correct set of micro-partitions at a point in time.

---

### Automatic Partitioning

Unlike traditional databases where you must define partition keys and partition schemes, Snowflake partitions data **automatically based on insertion order**.

**How it works:**

- As data is loaded (via INSERT, COPY INTO, or Snowpipe), Snowflake groups rows into micro-partitions in the order they arrive.
- No partition key is required.
- If data is loaded in a natural order (e.g., by date), the micro-partitions will be naturally clustered by that column.

```sql
-- Loading time-series data in chronological order results in well-clustered partitions
COPY INTO sales_fact
FROM @my_stage/sales_2025/
FILE_FORMAT = (TYPE = 'PARQUET')
ORDER BY sale_date;  -- Data arriving in date order → good natural clustering
```

**When natural ordering is not enough:**

For very large tables (multi-TB) where queries filter on specific columns but data was not loaded in that order, you can define **clustering keys** to reorganize micro-partitions.

```sql
-- Define a clustering key to reorganize data by date and region
ALTER TABLE sales_fact CLUSTER BY (sale_date, region);

-- Check clustering quality
SELECT SYSTEM$CLUSTERING_INFORMATION('sales_fact', '(sale_date, region)');

-- Clustering is maintained automatically by Automatic Clustering (background service)
-- Billed separately via serverless credits
```

---

### Partition Metadata

For every micro-partition, Snowflake's cloud services layer maintains detailed metadata:

| Metadata Type              | Description                                                                         |
|----------------------------|-------------------------------------------------------------------------------------|
| **Min value**              | The minimum value of each column in the micro-partition                              |
| **Max value**              | The maximum value of each column in the micro-partition                              |
| **Distinct value count**   | The number of distinct values per column                                            |
| **Null count**             | The number of NULL values per column                                                |
| **Row count**              | Total number of rows in the micro-partition                                         |
| **Byte size**              | Compressed and uncompressed sizes                                                   |
| **Expression metadata**    | Min/max for expressions used in clustering keys                                     |

This metadata is stored in the cloud services layer (not in the micro-partitions themselves) and is always up-to-date.

```sql
-- View table-level storage metrics
SELECT TABLE_NAME,
       ROW_COUNT,
       BYTES,
       BYTES / POWER(1024, 3) AS SIZE_GB,
       ACTIVE_BYTES,
       TIME_TRAVEL_BYTES,
       FAILSAFE_BYTES,
       RETAINED_FOR_CLONE_BYTES
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME = 'SALES_FACT'
  AND TABLE_CATALOG = 'MY_DATABASE'
ORDER BY ACTIVE_BYTES DESC;
```

---

### Partition Pruning

Partition pruning is Snowflake's most important query optimization technique. It uses micro-partition metadata (min/max values) to skip partitions that cannot contain relevant data.

**Example:**

```sql
-- Query with a date filter
SELECT customer_id, SUM(amount)
FROM orders
WHERE order_date = '2025-06-15'
GROUP BY customer_id;
```

**How pruning works step by step:**

1. The optimizer reads the min/max metadata for the `order_date` column across all micro-partitions.
2. A micro-partition with `min(order_date) = 2025-07-01` and `max(order_date) = 2025-07-31` is **pruned** because `2025-06-15` is outside its range.
3. A micro-partition with `min(order_date) = 2025-06-01` and `max(order_date) = 2025-06-30` is **not pruned** because `2025-06-15` falls within its range.
4. Only non-pruned partitions are read from storage.

```
Table: ORDERS (1,000 micro-partitions)

Query: WHERE order_date = '2025-06-15'

MP 1:   min=2025-01-01, max=2025-01-15  → PRUNED ✓
MP 2:   min=2025-01-16, max=2025-01-31  → PRUNED ✓
...
MP 332: min=2025-06-10, max=2025-06-18  → SCANNED (contains target date)
MP 333: min=2025-06-14, max=2025-06-20  → SCANNED (contains target date)
MP 334: min=2025-06-19, max=2025-06-30  → PRUNED ✓
...
MP 1000: min=2025-12-20, max=2025-12-31 → PRUNED ✓

Result: Only 2 out of 1,000 partitions scanned (99.8% pruning efficiency)
```

**Pruning works best when:**
- Data within partitions has narrow min/max ranges for the filtered column (good clustering).
- The WHERE clause uses equality (`=`), range (`BETWEEN`, `<`, `>`), or `IN` predicates.
- The filtered column is part of the clustering key (if defined).

**Pruning does NOT work well when:**
- Data is randomly distributed across partitions (wide, overlapping min/max ranges).
- Functions are applied to the filtered column (e.g., `WHERE YEAR(order_date) = 2025` prevents pruning on `order_date`).
- The predicate uses `LIKE`, `ILIKE`, or complex expressions.

```sql
-- GOOD: Pruning works
SELECT * FROM orders WHERE order_date BETWEEN '2025-06-01' AND '2025-06-30';

-- BAD: Pruning may not work — function wraps the column
SELECT * FROM orders WHERE DATE_TRUNC('month', order_date) = '2025-06-01';

-- BETTER: Rewrite to enable pruning
SELECT * FROM orders
WHERE order_date >= '2025-06-01' AND order_date < '2025-07-01';
```

---

### How DML Operations Create New Micro-Partitions

Understanding how DML interacts with micro-partitions is critical for performance tuning and cost management.

#### INSERT

New micro-partitions are created. No existing partitions are affected.

```sql
-- Inserting 10 million rows might create ~40-80 new micro-partitions
INSERT INTO orders
SELECT * FROM staging.new_orders;
```

#### DELETE

Affected micro-partitions are logically replaced. New partitions are created containing only the surviving rows. Old partitions are retained for Time Travel.

```sql
-- If order_id = 500 is in MP 7, then:
-- 1. MP 7 is retired (kept for Time Travel)
-- 2. MP 7' is created with all rows from MP 7 EXCEPT order_id = 500
DELETE FROM orders WHERE order_id = 500;
```

#### UPDATE

An UPDATE is internally executed as a DELETE followed by an INSERT within the same transaction. Each affected micro-partition is rewritten.

```sql
-- Updating a single row rewrites the entire micro-partition containing that row
UPDATE orders SET status = 'CANCELLED' WHERE order_id = 500;
```

**Performance implication:** Updating a single column in a single row still rewrites the entire micro-partition (~50-500 MB). Frequent small updates are expensive in Snowflake compared to bulk operations.

#### MERGE

Combines INSERT, UPDATE, and DELETE logic. Affected partitions are rewritten.

```sql
MERGE INTO target_orders t
USING staging_orders s
ON t.order_id = s.order_id
WHEN MATCHED AND s.status = 'CANCELLED' THEN DELETE
WHEN MATCHED THEN UPDATE SET t.status = s.status, t.amount = s.amount
WHEN NOT MATCHED THEN INSERT (order_id, status, amount)
  VALUES (s.order_id, s.status, s.amount);
```

**Write amplification:** If a MERGE affects rows spread across many micro-partitions, all of those partitions must be rewritten. To minimize write amplification:

- Cluster your target table on the join key used in the MERGE.
- Batch changes to minimize the number of affected partitions.
- Load data in the same order as the table's natural clustering.

---

### Storage Costs and Data Lifecycle

Snowflake data goes through a lifecycle that affects storage costs:

```
Data Lifecycle:
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────┐
│   ACTIVE     │───>│ TIME TRAVEL  │───>│  FAIL-SAFE   │───>│ PURGED   │
│              │    │              │    │              │    │          │
│ Current data │    │ 0-90 days    │    │ 7 days       │    │ Gone     │
│ accessible   │    │ (configurable│    │ (Snowflake-  │    │ forever  │
│ for queries  │    │  per table)  │    │  managed,    │    │          │
│              │    │              │    │  not user-   │    │          │
│              │    │              │    │  accessible) │    │          │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────┘
     Billed              Billed              Billed          Not billed
```

| Storage Type      | Description                                                           | Duration                      | User Accessible |
|-------------------|-----------------------------------------------------------------------|-------------------------------|-----------------|
| **Active**        | Current, live data — the latest version of all micro-partitions       | Indefinite                    | Yes             |
| **Time Travel**   | Old micro-partitions retained after DML changes                       | 0-90 days (default: 1 day, up to 90 for Enterprise+) | Yes             |
| **Fail-Safe**     | Retained by Snowflake after Time Travel expires for disaster recovery | 7 days (non-configurable)     | No (Snowflake support only) |

```sql
-- Set Time Travel retention to 30 days for a specific table
ALTER TABLE orders SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- Query historical data using Time Travel
SELECT * FROM orders AT(TIMESTAMP => '2025-06-01 12:00:00'::TIMESTAMP);

-- Query data as it was 1 hour ago
SELECT * FROM orders AT(OFFSET => -3600);

-- Restore a dropped table
UNDROP TABLE orders;

-- Check storage breakdown
SELECT TABLE_NAME,
       ACTIVE_BYTES / POWER(1024, 3) AS ACTIVE_GB,
       TIME_TRAVEL_BYTES / POWER(1024, 3) AS TIME_TRAVEL_GB,
       FAILSAFE_BYTES / POWER(1024, 3) AS FAILSAFE_GB,
       (ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES) / POWER(1024, 3) AS TOTAL_GB
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG = 'MY_DATABASE'
  AND ACTIVE_BYTES > 0
ORDER BY TOTAL_GB DESC;
```

**Cost management tips:**

- Use `DATA_RETENTION_TIME_IN_DAYS = 0` for staging/temp tables to avoid unnecessary Time Travel storage.
- Use **transient tables** (`CREATE TRANSIENT TABLE ...`) to eliminate Fail-Safe (7 days of free storage savings).
- Use **temporary tables** (`CREATE TEMPORARY TABLE ...`) for session-scoped data — no Time Travel, no Fail-Safe.

```sql
-- Transient table: Time Travel (0-1 day), NO Fail-Safe
CREATE TRANSIENT TABLE staging.raw_events (
    event_id INT,
    event_data VARIANT,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
)
DATA_RETENTION_TIME_IN_DAYS = 0;

-- Temporary table: Session-scoped, no Time Travel, no Fail-Safe
CREATE TEMPORARY TABLE session_results AS
SELECT * FROM orders WHERE order_date = CURRENT_DATE();
```

---

### Comparing Snowflake Micro-Partitions to Traditional Partitioning

| Aspect                  | Traditional Partitioning (e.g., Hive, Redshift) | Snowflake Micro-Partitions                    |
|-------------------------|--------------------------------------------------|-----------------------------------------------|
| **Partition definition** | Manual — user defines partition key and scheme (range, list, hash) | Automatic — Snowflake determines partition boundaries based on ingestion order |
| **Partition size**       | User-defined (can vary wildly — some huge, some tiny) | Consistent (50-500 MB compressed)             |
| **Partition format**     | Files or data blocks in various formats            | Snowflake's proprietary columnar format        |
| **Mutability**           | Mutable (data can be updated in place)             | Immutable (DML creates new partitions)         |
| **Skew**                 | Common problem — uneven partition sizes cause slow queries | Eliminated — Snowflake controls partition sizing |
| **Pruning**              | Based on partition key only                        | Based on min/max metadata for ALL columns      |
| **Maintenance**          | Manual (add/drop partitions, rebalance)            | Zero maintenance — fully automatic             |
| **Clustering control**   | Partition key determines layout                    | Optional clustering keys for optimization      |

**Key differentiator:** In traditional systems, partition pruning only works on the declared partition key column. In Snowflake, pruning uses min/max metadata for **every column**, so even unpartitioned (unclustered) columns benefit from pruning if the data happens to be naturally ordered.

---

## Real-World Example: Optimizing a Slowly Degrading Fact Table

**Scenario:** A 5 TB `customer_transactions` table has been receiving incremental loads for 2 years. Queries filtering on `transaction_date` have slowed from 5 seconds to 45 seconds.

**Diagnosis:**

```sql
-- Check clustering quality
SELECT SYSTEM$CLUSTERING_INFORMATION(
  'analytics_db.public.customer_transactions',
  '(transaction_date)'
);
```

**Output indicates:**
```json
{
  "cluster_by_keys": "LINEAR(transaction_date)",
  "total_partition_count": 20000,
  "total_constant_partition_count": 500,
  "average_overlaps": 85.3,
  "average_depth": 42.7
}
```

An `average_depth` of 42.7 means that on average, a single `transaction_date` value spans ~43 micro-partitions. For a point query, Snowflake must scan ~43 partitions instead of 1-2. The `average_overlaps` of 85.3 confirms severe overlap.

**Root cause:** Incremental loads over 2 years have mixed old and new date values into the same partitions. Data was not loaded in strict chronological order.

**Solution:**

```sql
-- Define clustering key (Automatic Clustering will reorganize in the background)
ALTER TABLE analytics_db.public.customer_transactions
  CLUSTER BY (transaction_date);

-- Monitor reclustering progress over the next hours/days
SELECT SYSTEM$CLUSTERING_INFORMATION(
  'analytics_db.public.customer_transactions',
  '(transaction_date)'
);

-- After reclustering completes:
-- average_overlaps: 2.1
-- average_depth: 1.5
-- Query goes from 45 seconds back to ~3 seconds
```

**Cost consideration:** Automatic Clustering runs in the background using serverless compute and is billed per-credit. For a 5 TB table, initial reclustering might cost $100-500 in credits. Ongoing maintenance for incremental loads is much cheaper.

---

## Common Interview Questions

### Q1: What is a micro-partition in Snowflake?

**Answer:** A micro-partition is the fundamental unit of storage in Snowflake. It is a compressed, columnar, immutable file stored in cloud object storage (S3, Azure Blob, or GCS), typically between 50 and 500 MB in compressed size. Snowflake automatically organizes all table data into micro-partitions based on insertion order. Each micro-partition stores data in a columnar format, meaning each column is stored and compressed independently. The cloud services layer maintains rich metadata (min/max values, distinct count, null count) for every column in every micro-partition, which powers partition pruning.

### Q2: How does partition pruning work in Snowflake?

**Answer:** When a query includes filter predicates (WHERE clauses), the query optimizer consults the min/max metadata stored for each column in each micro-partition. If a micro-partition's min/max range for the filtered column does not overlap with the predicate value, that partition is pruned (skipped entirely). For example, if a partition has `min(date) = 2025-07-01` and `max(date) = 2025-07-31`, a query filtering for `date = 2025-06-15` will skip it. Pruning works across all columns (not just a declared partition key), which is a major advantage over traditional partitioning schemes.

### Q3: Why are micro-partitions immutable, and what are the implications?

**Answer:** Micro-partitions are immutable by design — they are never updated in place. When a DML operation (UPDATE, DELETE, MERGE) modifies data, the affected micro-partitions are replaced with new ones containing the modified data. The old partitions are retained for Time Travel and then Fail-Safe. This immutability enables: (1) Time Travel — querying historical data, (2) zero-copy cloning — sharing partitions between source and clone, (3) snapshot isolation for ACID transactions — readers see a consistent set of partitions, and (4) simplified concurrency — no row-level locking needed.

### Q4: What is write amplification and how does it impact Snowflake performance?

**Answer:** Write amplification occurs when a small data change forces the rewriting of a large amount of data. In Snowflake, updating a single row means rewriting the entire micro-partition containing that row (potentially 50-500 MB). If an UPDATE or MERGE touches rows spread across many partitions, all those partitions must be rewritten. This makes frequent, small-scale updates expensive. To mitigate write amplification: batch updates together, cluster tables on the merge/join key to consolidate affected rows into fewer partitions, and use staging patterns (bulk load then swap) instead of row-level updates.

### Q5: How does Snowflake's micro-partition approach differ from traditional database partitioning?

**Answer:** Traditional partitioning requires the user to define a partition key and scheme (range, list, hash), manage partition boundaries, and handle partition maintenance (adding, dropping, rebalancing). Pruning only works on the partition key column. Snowflake's micro-partitions are fully automatic — no partition key is needed, partition sizes are consistent (50-500 MB), and pruning uses min/max metadata for every column, not just a single key. Optional clustering keys can be defined for additional optimization, but the base partitioning is always automatic and maintenance-free.

### Q6: Explain the relationship between micro-partitions, Time Travel, and Fail-Safe.

**Answer:** When DML operations replace micro-partitions, the old versions are retained for Time Travel (configurable from 0 to 90 days depending on Snowflake edition). During the Time Travel window, users can query historical data using `AT` or `BEFORE` syntax, or restore dropped tables with `UNDROP`. After Time Travel expires, partitions enter Fail-Safe for an additional 7 days — during this period, only Snowflake support can recover the data for disaster recovery. After Fail-Safe, old partitions are permanently purged. All retained partitions (Time Travel and Fail-Safe) incur storage costs, which is why transient and temporary tables exist to reduce these costs for non-critical data.

### Q7: How do you diagnose and fix poor clustering in a Snowflake table?

**Answer:** Use `SYSTEM$CLUSTERING_INFORMATION('table_name', '(column)')` to check clustering quality. Key metrics are `average_depth` (how many partitions a single value spans — lower is better) and `average_overlaps` (how many partitions have overlapping ranges — lower is better). If these values are high, queries filtering on that column scan many partitions despite pruning. The fix is to define a clustering key with `ALTER TABLE ... CLUSTER BY (column)`, which enables Automatic Clustering — a background serverless process that reorganizes micro-partitions to minimize overlap. You can also improve clustering by loading data in sorted order and batching incremental loads.

---

## Tips

- **Micro-partition size** — know the "50 to 500 MB compressed" range by heart. It is one of the most commonly asked Snowflake facts in interviews.
- **Immutability is foundational** — many Snowflake features (Time Travel, cloning, ACID) trace back to immutable micro-partitions. Understanding this principle deeply will help you answer multiple interview questions from a single concept.
- **Pruning applies to ALL columns** — this is a critical differentiator from traditional partitioning. Even without a clustering key, Snowflake maintains min/max metadata for every column and can prune on any of them.
- **Avoid small, frequent DML** — Snowflake is optimized for bulk operations. Row-level updates and deletes are expensive because they rewrite entire micro-partitions. Design ETL pipelines for batch processing.
- **Clustering keys are optional** — most tables do not need them. Only add clustering keys to large tables (typically 1+ TB) where queries have clear, consistent filter patterns and `SYSTEM$CLUSTERING_INFORMATION` shows poor clustering depth.
- **Know the table types** — permanent (full Time Travel + Fail-Safe), transient (Time Travel only, max 1 day on Standard edition), and temporary (session-scoped, no Time Travel, no Fail-Safe). Be ready to explain when to use each.
- **Storage cost awareness** — Time Travel and Fail-Safe can significantly increase storage costs for tables with heavy DML. A table with 100 GB active data might have 200 GB in Time Travel from frequent updates. Monitor with `TABLE_STORAGE_METRICS`.
- **Rewrite queries for pruning** — avoid wrapping filter columns in functions (`YEAR(date_col) = 2025`). Instead, use range predicates (`date_col >= '2025-01-01' AND date_col < '2026-01-01'`) to enable partition pruning.
