# Query Optimization Best Practices

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### Understanding Snowflake's Query Execution

Snowflake stores data in **micro-partitions** — immutable, compressed columnar files (50-500 MB uncompressed). Every optimization in Snowflake ultimately boils down to: **scan fewer micro-partitions and process fewer columns.**

---

## Partition Pruning Optimization

Partition pruning is Snowflake's most powerful automatic optimization. Snowflake maintains metadata for each micro-partition (min/max values, null counts, distinct count estimates). When a query includes filter predicates, Snowflake uses this metadata to skip irrelevant micro-partitions entirely.

```sql
-- GOOD: Filters on a naturally ordered column (e.g., date) enable effective pruning
SELECT order_id, customer_id, amount
FROM orders
WHERE order_date BETWEEN '2025-06-01' AND '2025-06-30';
-- If orders are naturally ordered by order_date, Snowflake may scan only
-- a small fraction of the table's micro-partitions.

-- BAD: Wrapping the filter column in a function defeats pruning
SELECT order_id, customer_id, amount
FROM orders
WHERE YEAR(order_date) = 2025 AND MONTH(order_date) = 6;
-- The function call prevents Snowflake from using min/max metadata.
```

### Checking Pruning Effectiveness

```sql
-- Use the query profile or EXPLAIN to see partitions scanned vs total
-- In the query profile, look for:
--   "Partitions scanned: X out of Y"
-- A low ratio means pruning is working well.
```

---

## Predicate Pushdown

Snowflake automatically pushes filter predicates as close to the data scan as possible. However, certain query patterns can prevent this optimization.

```sql
-- GOOD: Filter is pushed down to the base table scan
SELECT c.name, o.amount
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE o.order_date >= '2025-01-01';

-- BAD: Filtering on a derived column from a subquery may prevent pushdown
SELECT *
FROM (
    SELECT customer_id, SUM(amount) AS total_amount
    FROM orders
    GROUP BY customer_id
) sub
WHERE total_amount > 1000;
-- The filter on total_amount cannot be pushed into the scan; the aggregation
-- must complete first. This is expected behavior, not an anti-pattern,
-- but understand that the full table is scanned.

-- BETTER: Add an early filter to reduce data before aggregation
SELECT *
FROM (
    SELECT customer_id, SUM(amount) AS total_amount
    FROM orders
    WHERE order_date >= '2025-01-01'  -- reduces data before aggregation
    GROUP BY customer_id
) sub
WHERE total_amount > 1000;
```

---

## Join Optimization

Snowflake uses two primary join strategies:

### Broadcast Join (Replicate)

- The smaller table is broadcast (replicated) to all nodes.
- Effective when one table is significantly smaller than the other.
- Snowflake chooses this automatically based on table sizes.

### Hash Join

- Both tables are partitioned by the join key and distributed across nodes.
- Used when both tables are large.
- More network-intensive but handles large-large joins.

### Best Practices for Joins

```sql
-- GOOD: Filter tables before joining to reduce data movement
SELECT c.name, o.order_id, o.amount
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE c.region = 'EMEA'
  AND o.order_date >= '2025-01-01';

-- BAD: Joining full tables then filtering
SELECT c.name, o.order_id, o.amount
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE c.region = 'EMEA'
  AND o.order_date >= '2025-01-01';
-- NOTE: Snowflake's optimizer usually handles this correctly, but
-- with complex subqueries or CTEs, manually filtering early helps.

-- GOOD: Use explicit join conditions, avoid implicit cross joins
SELECT a.id, b.id
FROM table_a a
JOIN table_b b ON a.key = b.key;

-- BAD: Cartesian product (even if accidental)
SELECT a.id, b.id
FROM table_a a, table_b b;
-- No join condition = full cross join. This is almost never intended
-- and can produce explosive result sets.
```

### Join Order

Snowflake's optimizer automatically determines join order, but you can help by:

- Placing the largest table first in the FROM clause (Snowflake uses this as a hint).
- Ensuring join keys have compatible data types to avoid implicit casting.

```sql
-- BAD: Implicit type casting on join key
SELECT *
FROM table_a a  -- a.id is INTEGER
JOIN table_b b ON a.id = b.id;  -- b.id is VARCHAR
-- Implicit casting applies a function to every row, potentially hurting performance.

-- GOOD: Ensure matching types
SELECT *
FROM table_a a
JOIN table_b b ON a.id = b.id::INTEGER;  -- Explicit cast on the smaller table
```

---

## Avoiding SELECT *

```sql
-- BAD: Scans all columns from a wide table
SELECT * FROM customer_events;
-- If the table has 200 columns, all are decompressed and scanned.

-- GOOD: Select only the columns you need
SELECT event_id, customer_id, event_type, event_timestamp
FROM customer_events;
-- Snowflake's columnar storage means unselected columns are never read.
```

**Why this matters in Snowflake:**

- Snowflake uses **columnar storage** — each column is stored separately within micro-partitions.
- Selecting fewer columns means fewer bytes scanned and decompressed.
- This directly reduces execution time and improves cache efficiency.

---

## Reducing Data Scanning

### Filter Early

```sql
-- GOOD: CTE filters data before expensive operations
WITH recent_orders AS (
    SELECT *
    FROM orders
    WHERE order_date >= DATEADD('month', -3, CURRENT_DATE)
)
SELECT customer_id, COUNT(*) AS order_count, SUM(amount) AS total
FROM recent_orders
GROUP BY customer_id
HAVING total > 500;
```

### Use LIMIT Wisely

```sql
-- LIMIT reduces the result set but Snowflake may still scan all data
-- for aggregations or sorts.

-- GOOD: LIMIT with ORDER BY on a clustered column
SELECT order_id, amount
FROM orders
ORDER BY order_date DESC
LIMIT 100;

-- NOTE: Snowflake optimizes LIMIT by stopping early when possible,
-- but this depends on the query plan.
```

### Avoid Unnecessary UNION (Use UNION ALL)

```sql
-- BAD: UNION deduplicates, requiring a sort
SELECT customer_id FROM source_a
UNION
SELECT customer_id FROM source_b;

-- GOOD: UNION ALL if duplicates are acceptable or impossible
SELECT customer_id FROM source_a
UNION ALL
SELECT customer_id FROM source_b;
```

---

## Leveraging Clustering

### Natural Clustering vs. Explicit Clustering Keys

Data is naturally clustered by the order in which it is inserted. For time-series data loaded chronologically, the date column is naturally well-clustered.

```sql
-- Check natural clustering quality
SELECT SYSTEM$CLUSTERING_INFORMATION('orders', '(order_date)');
-- Returns: average_depth, total_partitions, and a histogram
-- Lower average_depth = better clustering
```

### When to Define Explicit Clustering Keys

- Tables larger than **1 TB** where query filters consistently use specific columns.
- Queries frequently filter on columns that are NOT well-clustered naturally.
- High `average_depth` from `SYSTEM$CLUSTERING_INFORMATION`.

```sql
-- Define a clustering key
ALTER TABLE orders CLUSTER BY (order_date);

-- Multi-column clustering key (for queries that filter on both)
ALTER TABLE events CLUSTER BY (event_date, event_type);

-- Drop a clustering key (stop automatic reclustering)
ALTER TABLE orders DROP CLUSTERING KEY;
```

**Clustering costs:**

- Automatic reclustering runs in the background and consumes serverless credits.
- Only apply clustering keys to tables where the performance benefit justifies the cost.
- Tables smaller than a few hundred GB rarely benefit from explicit clustering.

---

## EXPLAIN PLAN Analysis

```sql
-- Generate an explain plan without executing the query
EXPLAIN USING TABULAR
SELECT customer_id, SUM(amount)
FROM orders
WHERE order_date >= '2025-01-01'
GROUP BY customer_id;
```

**Key things to look for in the explain plan:**

| Component | What to Check |
|---|---|
| TableScan | Number of partitions scanned vs. total partitions |
| Filter | Whether predicates are applied at scan level |
| Join | Join type (broadcast vs. hash), estimated row counts |
| Aggregate | Whether aggregation is done locally before shuffling |
| Sort | Large sorts indicate potential memory/spill issues |

```sql
-- Use the Query Profile in the Snowflake UI for a visual breakdown:
-- 1. Run the query
-- 2. Click on the Query ID in History
-- 3. Open the "Profile" tab
-- Look for: spilling to local/remote storage, partition pruning ratio,
-- join explosion, and operator timings.
```

### Detecting Spilling

When a query runs out of memory, it **spills to local SSD**, and if that fills up, to **remote storage**. Spilling dramatically slows queries.

```sql
-- Check for queries that spilled
SELECT query_id, query_text,
       BYTES_SPILLED_TO_LOCAL_STORAGE,
       BYTES_SPILLED_TO_REMOTE_STORAGE,
       execution_time / 1000 AS exec_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE BYTES_SPILLED_TO_LOCAL_STORAGE > 0
   OR BYTES_SPILLED_TO_REMOTE_STORAGE > 0
ORDER BY BYTES_SPILLED_TO_REMOTE_STORAGE DESC
LIMIT 20;
```

**Solutions for spilling:**

- Scale up the warehouse (more memory per node).
- Reduce the data volume with better filters.
- Break the query into smaller steps using temp tables.
- Optimize joins to reduce intermediate result sizes.

---

## Common Anti-Patterns to Avoid

### 1. HAVING vs. WHERE

```sql
-- BAD: Using HAVING for non-aggregate filters
SELECT department, COUNT(*)
FROM employees
GROUP BY department
HAVING department != 'TEMP';
-- HAVING is applied AFTER aggregation, so all rows are scanned and grouped first.

-- GOOD: Use WHERE for non-aggregate filters
SELECT department, COUNT(*)
FROM employees
WHERE department != 'TEMP'
GROUP BY department;
-- WHERE filters BEFORE aggregation, reducing the data processed.
```

### 2. Functions on Filter Columns

```sql
-- BAD: Function on the filtered column prevents pruning
SELECT * FROM events WHERE DATE(event_timestamp) = '2025-06-15';
SELECT * FROM events WHERE UPPER(event_name) = 'LOGIN';

-- GOOD: Keep the column bare in the filter
SELECT * FROM events
WHERE event_timestamp >= '2025-06-15'
  AND event_timestamp < '2025-06-16';

-- GOOD: Store normalized values if you frequently filter on them
-- (e.g., add a computed column or materialize in ETL)
```

### 3. Overusing ORDER BY

```sql
-- BAD: Sorting large result sets unnecessarily
SELECT * FROM events ORDER BY event_timestamp;
-- Sorting billions of rows is expensive. Only sort when the consumer needs it.

-- GOOD: Use ORDER BY only with LIMIT or when order is required
SELECT * FROM events ORDER BY event_timestamp DESC LIMIT 100;
```

### 4. Non-Sargable Predicates

```sql
-- BAD: Arithmetic on the column side
SELECT * FROM orders WHERE amount * 1.1 > 1000;

-- GOOD: Arithmetic on the constant side
SELECT * FROM orders WHERE amount > 1000 / 1.1;
```

### 5. Unnecessary DISTINCT

```sql
-- BAD: Using DISTINCT to mask a bad join that produces duplicates
SELECT DISTINCT c.customer_id, c.name
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id;

-- GOOD: Fix the join or use EXISTS
SELECT c.customer_id, c.name
FROM customers c
WHERE EXISTS (
    SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id
);
```

---

## Micro-Partition Aware Query Design

### Design Queries Around Data Layout

```sql
-- If a table is clustered by (region, event_date):

-- GOOD: Filter on the clustering key columns
SELECT COUNT(*) FROM events
WHERE region = 'US' AND event_date = '2025-06-15';
-- Excellent pruning — both clustering columns are filtered.

-- DECENT: Filter on the first clustering column
SELECT COUNT(*) FROM events WHERE region = 'US';
-- Good pruning on the first key.

-- POOR: Filter on only the second clustering column
SELECT COUNT(*) FROM events WHERE event_date = '2025-06-15';
-- Less effective pruning — the first key is not constrained.
```

### Partition-Friendly Data Types

```sql
-- Use DATE instead of TIMESTAMP for date-only filters (better metadata overlap)
-- Use INTEGER keys instead of VARCHAR keys (more efficient comparison)
```

---

## Transient Tables

Transient tables reduce storage costs by not maintaining Fail-safe protection (only Time Travel, no 7-day Fail-safe).

```sql
-- Create a transient table for staging or intermediate results
CREATE TRANSIENT TABLE stg_daily_extract (
    id INTEGER,
    payload VARIANT,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Transient tables support Time Travel (up to 1 day) but have NO Fail-safe
-- Use for: staging data, intermediate ETL results, temp aggregations
-- Do NOT use for: critical business data that needs Fail-safe protection
```

**When to use transient tables for performance:**

- Materialized intermediate results in multi-step ETL pipelines.
- Staging layers where data can be reloaded from source.
- Reduces storage costs by 25-30% compared to permanent tables.

---

## COPY Grants

When recreating objects with `CREATE OR REPLACE`, grants are normally lost. Use `COPY GRANTS` to preserve them.

```sql
-- Without COPY GRANTS: all grants are revoked after replacement
CREATE OR REPLACE TABLE sales_summary AS
SELECT region, SUM(amount) FROM sales GROUP BY region;
-- Anyone who had SELECT on sales_summary now loses access.

-- With COPY GRANTS: grants are preserved
CREATE OR REPLACE TABLE sales_summary
COPY GRANTS
AS
SELECT region, SUM(amount) AS total_amount FROM sales GROUP BY region;
```

This is relevant to optimization because `CREATE OR REPLACE` with `COPY GRANTS` is a common pattern for rebuilding materialized summaries without disrupting access.

---

## Query Tags for Monitoring

```sql
-- Tag queries at the session level for cost/performance attribution
ALTER SESSION SET QUERY_TAG = 'etl:daily_load:orders';

-- Run your queries...
INSERT INTO orders_processed SELECT * FROM stg_orders WHERE is_valid = TRUE;

-- Analyze tagged queries
SELECT query_tag,
       COUNT(*) AS query_count,
       SUM(execution_time) / 1000 AS total_exec_seconds,
       SUM(BYTES_SCANNED) / POWER(1024, 3) AS total_gb_scanned,
       AVG(BYTES_SPILLED_TO_LOCAL_STORAGE) AS avg_local_spill
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_tag LIKE 'etl:%'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY query_tag
ORDER BY total_gb_scanned DESC;

-- Reset the tag
ALTER SESSION UNSET QUERY_TAG;
```

**Tag naming conventions:**

- `team:pipeline:step` (e.g., `analytics:revenue_report:aggregation`)
- `app:module:operation` (e.g., `dbt:staging:stg_orders`)

---

## Warehouse Selection Strategies

Choosing the right warehouse for a query is an often-overlooked optimization.

```sql
-- Use a small warehouse for metadata-only queries
USE WAREHOUSE admin_wh;  -- X-Small
SHOW TABLES IN SCHEMA analytics.public;
SELECT COUNT(*) FROM information_schema.tables;

-- Use a larger warehouse for heavy transformations
USE WAREHOUSE etl_wh;  -- X-Large
CREATE TABLE aggregated_sales AS
SELECT region, product_category, DATE_TRUNC('month', sale_date) AS month,
       SUM(amount) AS total_sales
FROM raw_sales
GROUP BY 1, 2, 3;

-- Use a multi-cluster warehouse for concurrent BI queries
USE WAREHOUSE bi_wh;  -- Small, multi-cluster
SELECT * FROM aggregated_sales WHERE region = 'APAC';
```

---

## Common Performance Pitfalls

| Pitfall | Impact | Solution |
|---|---|---|
| SELECT * on wide tables | Scans unnecessary columns | Select only needed columns |
| Functions on filter columns | Prevents partition pruning | Keep columns bare in predicates |
| Cartesian joins (missing ON clause) | Explosive row counts | Always specify join conditions |
| UNION instead of UNION ALL | Unnecessary sort for dedup | Use UNION ALL when dedup is not needed |
| Sorting without LIMIT | Expensive full-table sorts | Only ORDER BY when required |
| Not filtering early in CTEs | Passes too much data downstream | Add WHERE clauses in early CTEs |
| Wrong warehouse size | Too small = slow; too large = wasted credits | Benchmark and right-size |
| Implicit type casts in joins | Prevents optimization | Ensure matching data types |
| Over-clustering small tables | Unnecessary reclustering cost | Only cluster tables > 1 TB |
| Not using transient tables for staging | Extra Fail-safe storage cost | Use TRANSIENT for replaceable data |

---

## Real-World Examples

### Example 1: Optimizing a Slow Dashboard Query

**Before (slow):**

```sql
SELECT *
FROM fact_orders f
JOIN dim_customers c ON f.customer_id = c.customer_id
JOIN dim_products p ON f.product_id = p.product_id
WHERE YEAR(f.order_date) = 2025
ORDER BY f.order_date;
```

**Problems:** `SELECT *` scans all columns; `YEAR()` function prevents pruning; unnecessary `ORDER BY`.

**After (optimized):**

```sql
SELECT f.order_id, f.order_date, f.amount,
       c.customer_name, c.region,
       p.product_name, p.category
FROM fact_orders f
JOIN dim_customers c ON f.customer_id = c.customer_id
JOIN dim_products p ON f.product_id = p.product_id
WHERE f.order_date >= '2025-01-01'
  AND f.order_date < '2026-01-01'
ORDER BY f.order_date DESC
LIMIT 1000;
```

### Example 2: ETL Pipeline Optimization

**Before:** A single massive query joining 8 tables with multiple aggregations, running for 45 minutes on an XL warehouse with heavy spilling.

**After:** Break into staged steps using transient tables:

```sql
-- Step 1: Filter and pre-aggregate at the source
CREATE OR REPLACE TRANSIENT TABLE tmp_recent_orders AS
SELECT customer_id, product_id, SUM(amount) AS total_amount, COUNT(*) AS order_count
FROM raw_orders
WHERE order_date >= DATEADD('month', -3, CURRENT_DATE)
GROUP BY customer_id, product_id;

-- Step 2: Enrich with dimension data
CREATE OR REPLACE TRANSIENT TABLE tmp_enriched_orders
COPY GRANTS
AS
SELECT o.*, c.segment, c.region, p.category
FROM tmp_recent_orders o
JOIN dim_customers c ON o.customer_id = c.customer_id
JOIN dim_products p ON o.product_id = p.product_id;

-- Step 3: Final aggregation
CREATE OR REPLACE TABLE report_customer_summary
COPY GRANTS
AS
SELECT region, segment, category,
       SUM(total_amount) AS revenue,
       SUM(order_count) AS orders
FROM tmp_enriched_orders
GROUP BY 1, 2, 3;

-- Clean up
DROP TABLE IF EXISTS tmp_recent_orders;
DROP TABLE IF EXISTS tmp_enriched_orders;
```

**Result:** Each step runs in under 5 minutes on a Large warehouse, no spilling, and easier to debug.

### Example 3: Monitoring Optimization Impact

```sql
-- Compare query performance before and after optimization
-- using query tags
SELECT query_tag,
       DATE_TRUNC('day', start_time) AS day,
       COUNT(*) AS runs,
       AVG(execution_time)/1000 AS avg_seconds,
       AVG(BYTES_SCANNED)/POWER(1024,3) AS avg_gb_scanned,
       AVG(PARTITIONS_SCANNED) AS avg_partitions_scanned,
       AVG(PARTITIONS_TOTAL) AS avg_partitions_total,
       AVG(PARTITIONS_SCANNED) / NULLIF(AVG(PARTITIONS_TOTAL), 0) * 100 AS prune_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_tag IN ('dashboard:sales:v1', 'dashboard:sales:v2')
  AND start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## Common Interview Questions & Answers

### Q1: What is partition pruning and how do you optimize for it?

**A:** Partition pruning is Snowflake's ability to skip micro-partitions that do not contain relevant data based on metadata (min/max values per partition). To optimize for it: (1) Filter on columns that are well-clustered (typically date columns that data is loaded in order of). (2) Avoid wrapping filter columns in functions — `WHERE order_date >= '2025-01-01'` enables pruning, but `WHERE YEAR(order_date) = 2025` does not. (3) Use range predicates rather than computed expressions. (4) For frequently filtered columns that are not naturally ordered, consider adding an explicit clustering key. You can verify pruning effectiveness by checking "partitions scanned vs. total" in the Query Profile.

### Q2: When would you add a clustering key to a table?

**A:** I would add a clustering key when: (1) The table is large (typically 1 TB or more). (2) Queries consistently filter on specific columns that are not naturally well-clustered. (3) `SYSTEM$CLUSTERING_INFORMATION` shows a high average depth for the columns used in filters. (4) The performance benefit justifies the ongoing reclustering cost (serverless credits). I would NOT add clustering keys to small tables, frequently changing tables where reclustering costs would be high, or tables where queries do not filter on consistent columns.

### Q3: How do you diagnose and fix a slow query in Snowflake?

**A:** My approach: (1) Check the **Query Profile** for the bottleneck — is it scanning too many partitions, spilling to disk, or experiencing join explosion? (2) Check `BYTES_SCANNED` and partition pruning ratio — if most partitions are scanned, the filters may need improvement. (3) Check for **spilling** — `BYTES_SPILLED_TO_LOCAL_STORAGE` and `BYTES_SPILLED_TO_REMOTE_STORAGE` indicate memory pressure; scale up the warehouse or reduce data volume. (4) Check for **functions on filter columns** preventing pruning. (5) Check for `SELECT *` on wide tables. (6) Verify join conditions are correct and data types match. (7) Consider breaking complex queries into staged intermediate tables. (8) Review warehouse sizing — the warehouse may be too small for the workload.

### Q4: Explain the difference between WHERE and HAVING. Why does it matter for performance?

**A:** `WHERE` filters rows before aggregation — it reduces the data that flows into GROUP BY. `HAVING` filters after aggregation — it operates on the aggregated results. For performance, non-aggregate predicates should always go in `WHERE` because they reduce the volume of data processed in the aggregation step. Putting non-aggregate filters in `HAVING` forces Snowflake to scan, group, and aggregate all the data before discarding rows, wasting compute.

### Q5: What are transient tables and when would you use them?

**A:** Transient tables are like permanent tables but without the 7-day Fail-safe period. They support Time Travel (up to 1 day in standard edition). I use them for: staging data, intermediate ETL results, temporary aggregations, and any data that can be recreated from source. The benefit is reduced storage costs (no Fail-safe overhead). I would NOT use them for critical business data where Fail-safe recovery is needed.

### Q6: How would you optimize a query that joins two very large tables?

**A:** (1) **Filter early** — add WHERE clauses on both tables to reduce row counts before the join. (2) **Select only needed columns** — reduce data movement. (3) **Ensure join keys have matching data types** — implicit casts hurt performance. (4) **Check clustering** — if both tables are clustered on the join key, the join is more efficient. (5) **Consider staging** — pre-aggregate or filter each table into transient tables, then join the smaller intermediates. (6) **Scale up the warehouse** if the join spills to disk. (7) **Use the Query Profile** to verify whether Snowflake chose a hash join (expected for two large tables) and check for data skew.

### Q7: What is spilling and how do you address it?

**A:** Spilling occurs when a query's intermediate results exceed the available memory on the warehouse nodes. Data spills first to local SSD (faster but limited) and then to remote cloud storage (much slower). Spilling dramatically degrades performance. Solutions: (1) Scale up the warehouse for more memory per node. (2) Reduce data volume with better filters. (3) Break complex queries into stages. (4) Optimize joins to reduce intermediate result sizes. (5) Check for data skew causing uneven distribution across nodes. You can monitor spilling via `BYTES_SPILLED_TO_LOCAL_STORAGE` and `BYTES_SPILLED_TO_REMOTE_STORAGE` in `QUERY_HISTORY`.

---

## Tips

- **Check the Query Profile first** — it is the single most valuable diagnostic tool in Snowflake. Learn to read the operator tree, identify the most expensive nodes, and spot partition pruning ratios.
- **Partition pruning is king** — most Snowflake performance gains come from scanning fewer partitions. Design your filters and clustering keys accordingly.
- **Avoid premature optimization** — do not add clustering keys or scale up warehouses before measuring the actual bottleneck. Use data from `QUERY_HISTORY` and the Query Profile.
- **Use query tags religiously** — they make performance analysis, cost attribution, and regression detection much easier over time.
- **COPY GRANTS** is easy to forget and painful when missed — add it to every `CREATE OR REPLACE` as a habit.
- **Transient tables for intermediate ETL steps** reduce storage costs and keep your pipeline modular and debuggable.
- **Test with `EXPLAIN` before running** expensive queries to verify the plan looks reasonable (partition counts, join strategies).
- **In interviews**, always mention the Query Profile and specific metrics (bytes scanned, partitions pruned, spilling) — this shows hands-on experience rather than theoretical knowledge.
