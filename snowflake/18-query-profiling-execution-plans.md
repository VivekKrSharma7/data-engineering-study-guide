# Query Profiling & Execution Plans

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Query Profile Overview](#query-profile-overview)
2. [Reading the Query Profile (Operator Tree)](#reading-the-query-profile-operator-tree)
3. [Common Operators](#common-operators)
4. [Statistics Tab](#statistics-tab)
5. [Query History](#query-history)
6. [EXPLAIN PLAN](#explain-plan)
7. [Identifying Performance Bottlenecks](#identifying-performance-bottlenecks)
8. [Query Tags](#query-tags)
9. [Common Interview Questions](#common-interview-questions)
10. [Tips](#tips)

---

## Query Profile Overview

The **Query Profile** is Snowflake's visual execution plan tool, accessible through the Snowflake UI (Snowsight or Classic Console). Unlike traditional databases that show text-based explain plans, Snowflake provides a graphical, interactive operator tree with rich statistics.

### How to Access the Query Profile

1. **Snowsight:** Run a query, click on the query in the results pane, then click the **Query Profile** tab.
2. **Classic Console:** Go to **History**, find the query, and click on the **Profile** link.
3. **Programmatic:** Use `QUERY_HISTORY` views to get query metadata (though the visual profile is UI-only).

### What It Shows

- **Operator tree:** A DAG of execution steps (nodes), showing how data flows through the query.
- **Statistics per operator:** Rows produced, bytes processed, partition pruning info, and more.
- **Overall statistics:** Total execution time, bytes scanned, compilation time, warehouse info.
- **Attributes:** Details of each operator (e.g., filter expressions, join keys, sort keys).

---

## Reading the Query Profile (Operator Tree)

The operator tree flows **bottom to top** — data enters at leaf nodes (table scans) and flows upward through transformations to the final result.

### Structure

```
          Result
            |
        Aggregate
          /    \
      Filter    Sort
        |        |
   TableScan  TableScan
   (orders)   (customers)
```

### Key Concepts

- **Nodes/Operators:** Each box represents an operation (scan, filter, join, aggregate, etc.).
- **Edges:** Arrows between operators show data flow. The width of the arrow often correlates with the volume of data.
- **Partitions:** Each operator may show how many partitions were scanned vs. total, indicating pruning efficiency.
- **Execution steps:** Operators may be grouped into **processing steps** that execute on different nodes of the compute cluster.

### Color Coding

- Operators are shaded to indicate their relative cost. Darker or larger nodes consumed more time/resources.
- Look for the **most expensive operator** — this is often where optimization efforts should focus.

---

## Common Operators

### TableScan

Reads data from a table's micro-partitions.

| Statistic | Meaning |
|---|---|
| Partitions scanned | Number of micro-partitions actually read |
| Partitions total | Total micro-partitions in the table |
| Bytes scanned | Volume of data read from storage |

A high ratio of scanned-to-total partitions indicates **poor partition pruning**.

### Filter

Applies a WHERE clause or HAVING predicate to reduce rows.

```sql
-- This generates a Filter operator
SELECT * FROM orders WHERE status = 'shipped' AND amount > 100;
```

The profile shows the filter expression and how many rows were removed.

### Aggregate

Performs GROUP BY operations, COUNT, SUM, AVG, etc.

```sql
-- Generates an Aggregate operator
SELECT region, COUNT(*), SUM(amount)
FROM orders
GROUP BY region;
```

Shows the grouping keys and aggregate functions applied.

### JoinFilter

Represents join operations (INNER, LEFT, RIGHT, FULL, CROSS). Snowflake may use various join algorithms:

- **Hash Join:** One table is hashed (build side), the other is probed (probe side). Common for large-large joins.
- **Merge Join:** Both inputs are sorted on the join key. Used when data is already sorted.
- **Nested Loop Join:** For small tables or cross joins. Can be very expensive for large datasets.
- **Broadcast Join:** Smaller table is broadcast to all nodes. Common for small-large joins.

```sql
-- Generates a Join operator
SELECT o.order_id, c.name
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id;
```

### Sort

Sorts data for ORDER BY, DISTINCT, or as input to merge joins.

```sql
-- Generates a Sort operator
SELECT * FROM orders ORDER BY order_date DESC;
```

Sort operators can be expensive and may cause **spilling** if the data exceeds memory.

### WindowFunction

Applies window/analytic functions (ROW_NUMBER, RANK, LAG, LEAD, SUM OVER, etc.).

```sql
-- Generates a WindowFunction operator
SELECT
    order_id,
    customer_id,
    amount,
    SUM(amount) OVER (PARTITION BY customer_id ORDER BY order_date) AS running_total
FROM orders;
```

### Other Common Operators

| Operator | Description |
|---|---|
| **UnionAll** | Combines results from multiple branches |
| **Limit** | Applies LIMIT/FETCH/TOP to restrict output rows |
| **Flatten** | Unnests semi-structured data (VARIANT arrays/objects) |
| **ExternalScan** | Reads from external tables/stages |
| **WithClause** | Materialized CTE execution |
| **InternalObject** | Reads from result cache or materialized subquery |

---

## Statistics Tab

The statistics panel provides detailed performance metrics for the query. These are critical for diagnosing performance issues.

### Key Statistics

#### Bytes Scanned

Total bytes read from storage (micro-partitions).

- **High bytes scanned** relative to the result size may indicate missing filters or poor pruning.
- Compare with **bytes sent over the network** to understand data amplification.

#### Partitions Scanned vs Total

```
Partitions scanned: 12
Partitions total: 10,000
```

This is the single most important indicator of **partition pruning efficiency**. In this example, only 12 out of 10,000 partitions were scanned — excellent pruning. If the numbers are close (e.g., 9,800 / 10,000), pruning is poor and you should consider clustering.

#### Bytes Spilled to Local Storage

Data that exceeded the in-memory capacity of the warehouse and was written to the **local SSD** of the compute node.

- **Some local spilling** is acceptable for very large operations.
- **Excessive local spilling** indicates the warehouse may be undersized or the query needs optimization.

#### Bytes Spilled to Remote Storage

Data that exceeded both memory and local SSD capacity and was written to **remote cloud storage** (S3, Azure Blob, GCS).

- **Remote spilling is a red flag.** It is orders of magnitude slower than local spilling.
- Almost always indicates the warehouse is too small or the query design is problematic (e.g., exploding joins, massive sorts).

#### Percentage Scanned from Cache

The proportion of data served from the warehouse's **local SSD cache** rather than remote storage. Higher is better.

#### Rows Produced / Rows

Number of rows output by each operator. Useful for identifying data amplification (e.g., a join producing far more rows than either input).

#### Compilation Time vs Execution Time

| Metric | Description |
|---|---|
| Compilation time | Time spent parsing and optimizing the query |
| Execution time | Time spent running the query on the warehouse |
| Queuing time | Time spent waiting for warehouse resources |

If **queuing time** is high, the warehouse is overloaded — consider scaling up or using multi-cluster warehouses.

---

## Query History

### QUERY_HISTORY View (Account Usage)

The `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` view provides a comprehensive log of all queries executed in the account, with up to **365 days** of retention.

```sql
-- Find the slowest queries in the last 7 days
SELECT
    query_id,
    query_text,
    user_name,
    warehouse_name,
    execution_status,
    total_elapsed_time / 1000 AS elapsed_seconds,
    bytes_scanned,
    rows_produced,
    partitions_scanned,
    partitions_total,
    bytes_spilled_to_local_storage,
    bytes_spilled_to_remote_storage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time > DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND execution_status = 'SUCCESS'
ORDER BY total_elapsed_time DESC
LIMIT 20;
```

**Note:** Account Usage views have a **latency of up to 45 minutes**.

### QUERY_HISTORY Table Function (Information Schema)

For **real-time** query history (last 7 days), use the Information Schema table function.

```sql
-- Recent queries in the current session
SELECT *
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATEADD('HOUR', -1, CURRENT_TIMESTAMP()),
    CURRENT_TIMESTAMP(),
    100
))
ORDER BY START_TIME DESC;

-- Queries by a specific user
SELECT *
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_USER(
    USER_NAME => 'ANALYTICS_USER',
    RESULT_LIMIT => 50
));

-- Queries on a specific warehouse
SELECT *
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_WAREHOUSE(
    WAREHOUSE_NAME => 'ETL_WH',
    RESULT_LIMIT => 50
));
```

### Key Columns in QUERY_HISTORY

| Column | Description |
|---|---|
| `QUERY_ID` | Unique identifier for the query |
| `QUERY_TEXT` | The SQL statement |
| `TOTAL_ELAPSED_TIME` | Total time in milliseconds |
| `COMPILATION_TIME` | Parse + optimization time |
| `EXECUTION_TIME` | Actual execution time |
| `QUEUING_TIME` | Time waiting for warehouse |
| `BYTES_SCANNED` | Data read from storage |
| `BYTES_SPILLED_TO_LOCAL_STORAGE` | Spilled to local SSD |
| `BYTES_SPILLED_TO_REMOTE_STORAGE` | Spilled to remote storage |
| `PARTITIONS_SCANNED` | Partitions read |
| `PARTITIONS_TOTAL` | Total partitions in scanned tables |
| `QUERY_TAG` | Custom tag assigned to the query |
| `EXECUTION_STATUS` | SUCCESS, FAIL, INCIDENT |

---

## EXPLAIN PLAN

Snowflake supports `EXPLAIN` to view the logical execution plan **without running** the query.

### Syntax

```sql
-- Text format (default)
EXPLAIN
SELECT o.order_id, c.name, o.amount
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE o.order_date >= '2026-01-01';

-- JSON format
EXPLAIN USING JSON
SELECT * FROM orders WHERE status = 'shipped';

-- Tabular format
EXPLAIN USING TABULAR
SELECT region, SUM(amount) FROM orders GROUP BY region;
```

### Reading EXPLAIN Output

The output shows a tree of operations with:

- **GlobalStats:** Estimated partitions and bytes to scan.
- **Operations:** Each step with its operator type.
- **Expressions:** Filter predicates, join conditions, projection columns.

```
-- Example EXPLAIN output (simplified)
GlobalStats:
    partitionsTotal=10000
    partitionsAssigned=45
    bytesAssigned=12345678

Operations:
1:0  ->Result
1:1      ->Aggregate  groupKeys=[REGION]
1:2          ->Filter  filterExpr=[STATUS = 'shipped']
1:3              ->TableScan  ORDERS  {columns=[REGION, STATUS, AMOUNT]}
```

### EXPLAIN Limitations

- Shows the **logical plan**, not the runtime physical plan.
- Does not show actual execution times or spilling.
- Partition estimates are based on metadata and may differ from actual execution.
- For comprehensive analysis, always complement EXPLAIN with the **Query Profile** from an actual execution.

---

## Identifying Performance Bottlenecks

### 1. Spilling (Local and Remote)

**Symptom:** High values in `BYTES_SPILLED_TO_LOCAL_STORAGE` or `BYTES_SPILLED_TO_REMOTE_STORAGE`.

**Causes:**
- Warehouse too small for the query workload.
- Large sorts, aggregations, or joins that exceed memory.
- Suboptimal query design (e.g., unnecessary ORDER BY on full dataset).

**Solutions:**
```sql
-- Scale up the warehouse
ALTER WAREHOUSE etl_wh SET WAREHOUSE_SIZE = 'XLARGE';

-- Or optimize the query to reduce data volume before expensive operations
SELECT region, SUM(amount)
FROM orders
WHERE order_date >= '2026-01-01'  -- filter early to reduce data
GROUP BY region
ORDER BY SUM(amount) DESC;
```

### 2. Exploding Joins

**Symptom:** A join operator produces vastly more rows than either input table. For example, two 1M-row tables produce 100M rows.

**Causes:**
- Many-to-many join relationships.
- Missing or incorrect join conditions.
- Cartesian/cross joins (intentional or accidental).

**Detection:**
```sql
-- Check row counts in the Query Profile
-- Join input: 1,000,000 rows + 1,000,000 rows
-- Join output: 500,000,000 rows  <-- EXPLODING JOIN!

-- Diagnose with a count
SELECT COUNT(*)
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id;
-- Compare this with individual table counts
```

**Solutions:**
- Verify join keys are correct and represent the intended relationship.
- Add additional join predicates or WHERE clauses to restrict the join.
- Use `DISTINCT` or aggregation before joining if appropriate.

### 3. Poor Partition Pruning

**Symptom:** `Partitions scanned` is close to `Partitions total` despite having WHERE filters.

**Causes:**
- Filtering on columns that don't align with the table's natural clustering.
- Using functions on filter columns (e.g., `WHERE YEAR(date_col) = 2026`).
- Missing clustering keys on large tables.

**Solutions:**
```sql
-- Check current clustering info
SELECT SYSTEM$CLUSTERING_INFORMATION('orders', '(order_date)');

-- Add or change clustering key
ALTER TABLE orders CLUSTER BY (order_date);

-- Avoid wrapping filter columns in functions
-- BAD:  WHERE YEAR(order_date) = 2026
-- GOOD: WHERE order_date >= '2026-01-01' AND order_date < '2027-01-01'
```

### 4. High Queuing Time

**Symptom:** `QUEUING_TIME` is a significant portion of `TOTAL_ELAPSED_TIME`.

**Causes:**
- Warehouse is overloaded with concurrent queries.
- Warehouse auto-suspend/resume delays.
- Single-cluster warehouse at capacity.

**Solutions:**
```sql
-- Enable multi-cluster warehouses
ALTER WAREHOUSE analytics_wh
  SET MAX_CLUSTER_COUNT = 3
      SCALING_POLICY = 'STANDARD';

-- Or use separate warehouses for different workloads
-- ETL -> etl_wh, BI -> analytics_wh, Ad-hoc -> adhoc_wh
```

### 5. Large Compilation Time

**Symptom:** `COMPILATION_TIME` is disproportionately high (several seconds or more).

**Causes:**
- Extremely complex queries with many joins, subqueries, or CTEs.
- Large number of columns in SELECT *.
- Views with deep nesting.

**Solutions:**
- Simplify the query or break it into stages using temporary tables.
- Avoid `SELECT *` in complex queries.
- Reduce view nesting depth.

### Performance Investigation Workflow

```
1. Check TOTAL_ELAPSED_TIME breakdown:
   -> High QUEUING_TIME?     -> Scale warehouse / multi-cluster
   -> High COMPILATION_TIME? -> Simplify query
   -> High EXECUTION_TIME?   -> Continue to step 2

2. Open Query Profile, look for:
   -> Spilling?              -> Scale up warehouse or optimize query
   -> Exploding join?        -> Fix join logic
   -> Poor pruning?          -> Add clustering / fix filters
   -> Full table scan?       -> Add filters / check predicates

3. Check partition pruning ratio:
   -> scanned/total > 50%?   -> Investigate clustering and filter design

4. Check bytes scanned vs result size:
   -> 10GB scanned, 1KB result? -> Filters not selective enough
```

---

## Query Tags

**Query tags** are custom metadata labels you can attach to queries for tracking, auditing, and cost allocation purposes.

### Setting Query Tags

```sql
-- Set at session level (applies to all subsequent queries)
ALTER SESSION SET QUERY_TAG = 'etl_pipeline:orders:daily_load';

-- Set before a specific query, then unset
ALTER SESSION SET QUERY_TAG = 'report:monthly_revenue';
SELECT region, SUM(amount) FROM orders GROUP BY region;
ALTER SESSION UNSET QUERY_TAG;
```

### Querying by Tags

```sql
-- Find all queries with a specific tag
SELECT
    query_id,
    query_text,
    query_tag,
    total_elapsed_time,
    warehouse_name,
    start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_tag = 'etl_pipeline:orders:daily_load'
    AND start_time > DATEADD('DAY', -30, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

-- Aggregate costs by tag prefix
SELECT
    SPLIT_PART(query_tag, ':', 1) AS tag_category,
    COUNT(*) AS query_count,
    SUM(total_elapsed_time) / 1000 AS total_seconds,
    SUM(bytes_scanned) / POWER(1024, 3) AS total_gb_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_tag IS NOT NULL
    AND start_time > DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY tag_category
ORDER BY total_seconds DESC;
```

### Best Practices for Query Tags

Use a consistent tagging convention across your organization:

```
<team>:<project>:<component>:<operation>
-- Examples:
-- data_eng:warehouse_etl:orders:incremental_load
-- analytics:dashboards:revenue:monthly_report
-- ml:feature_store:user_features:training_data
```

---

## Common Interview Questions

### Q1: How do you identify a slow-performing query in Snowflake?

**A:** Start with `QUERY_HISTORY` (from Account Usage or Information Schema) to find queries with high `TOTAL_ELAPSED_TIME`. Then open the Query Profile in the Snowflake UI for the specific query. Analyze the breakdown: check if time is spent on queuing (warehouse overload), compilation (query complexity), or execution (actual processing). Within execution, look at the operator tree for operators with the most time, check partition pruning ratios, and look for spilling indicators.

### Q2: What does spilling mean in Snowflake, and how do you resolve it?

**A:** Spilling occurs when an operation (sort, join, aggregation) exceeds the available memory of the warehouse and writes intermediate results to local SSD (local spilling) or remote cloud storage (remote spilling). Local spilling has moderate impact; remote spilling is severely detrimental to performance. Resolution: scale up the warehouse size (more memory), optimize the query to reduce data volume before expensive operations, or break the query into smaller stages.

### Q3: How do you read partition pruning information from the Query Profile?

**A:** In the TableScan operator, compare "Partitions scanned" with "Partitions total." A low ratio (e.g., 50 / 10,000) indicates effective pruning — the query is only reading relevant micro-partitions. A high ratio (e.g., 9,500 / 10,000) indicates poor pruning, meaning Snowflake is scanning most of the table. Improve pruning by clustering the table on frequently filtered columns and ensuring WHERE clauses use range predicates without wrapping columns in functions.

### Q4: What is the difference between EXPLAIN and the Query Profile?

**A:** `EXPLAIN` shows the **logical** execution plan before the query runs, including estimated partition counts and the operation tree. It is useful for quick checks and does not consume compute resources. The Query Profile shows the **actual** execution plan after the query runs, with real statistics (actual bytes scanned, actual spilling, actual timing per operator). For thorough performance analysis, the Query Profile is far more informative.

### Q5: How would you diagnose an exploding join?

**A:** In the Query Profile, check the join operator's output row count versus its input row counts. If the output is dramatically larger (e.g., 100x the input), it is an exploding join. This usually means a many-to-many relationship or missing join predicates. Diagnose by checking join key cardinality (`SELECT COUNT(DISTINCT join_key) FROM each_table`), verifying join conditions are correct, and looking for unintended cartesian products. Fix by adding proper join conditions, filtering before joining, or deduplicating input tables.

### Q6: What are query tags and how would you use them for cost allocation?

**A:** Query tags are custom string labels attached to queries via `ALTER SESSION SET QUERY_TAG`. By tagging queries with team/project/component identifiers, you can later query `QUERY_HISTORY` to aggregate execution time, bytes scanned, and warehouse usage by tag. This enables cost allocation across teams or projects, performance benchmarking for specific workloads, and identifying resource-heavy pipelines.

### Q7: What tools does Snowflake provide for monitoring query performance at scale?

**A:** (1) `QUERY_HISTORY` views in Account Usage (365 days, 45-min latency) and Information Schema (7 days, real-time). (2) Query Profile in the UI for individual query deep-dives. (3) `WAREHOUSE_METERING_HISTORY` for warehouse-level cost analysis. (4) `ACCESS_HISTORY` for data access patterns. (5) Query tags for custom categorization. (6) Resource Monitors for cost controls. (7) Third-party tools that integrate via Snowflake's views and metadata.

### Q8: A query scans 500 GB but returns only 100 rows. What might be wrong?

**A:** This indicates extremely poor selectivity or missing pruning. Likely causes: (1) No WHERE clause or a filter on a non-clustered column, causing a full table scan. (2) Filter uses a function on the column (e.g., `WHERE UPPER(name) = 'X'`), preventing pruning. (3) The table lacks clustering on the filtered column. (4) The query joins large tables before filtering. Solutions: add selective filters early, cluster the table on frequently queried columns, rewrite filters to avoid functions on columns, and push filters before joins.

### Q9: When would you scale up vs scale out a warehouse?

**A:** **Scale up** (larger warehouse size) when individual queries are slow due to memory pressure, spilling, or complex processing — each query gets more compute and memory. **Scale out** (multi-cluster warehouse) when many concurrent queries are queuing — more clusters handle more parallel queries. If you have a few slow queries: scale up. If you have many fast queries competing for resources: scale out.

### Q10: How does Snowflake's result caching affect query profiling?

**A:** Snowflake has a 24-hour result cache. If a query hits the result cache, it returns almost instantly with no warehouse usage. In the Query Profile, the execution shows as a single "Result" node reading from the cache. `BYTES_SCANNED` will be 0 and `PERCENTAGE_SCANNED_FROM_CACHE` will be irrelevant because no storage I/O occurred. When profiling for performance tuning, ensure you are looking at the **non-cached** execution by running the query with `ALTER SESSION SET USE_CACHED_RESULT = FALSE` first.

---

## Tips

1. **Always check partition pruning first.** It is the number-one optimization lever in Snowflake. A well-pruned query can be 100x faster than a full scan.

2. **Remote spilling is a critical signal.** If you see any bytes spilled to remote storage, treat it as a high-priority issue. Local spilling is tolerable in moderation; remote spilling is not.

3. **Use EXPLAIN for quick sanity checks.** Before running an expensive query, check the EXPLAIN output to see estimated partition counts. If it shows scanning all partitions, fix your filters before executing.

4. **Filter early, aggregate late.** Push WHERE clauses as early as possible in your query to reduce data volume before joins, sorts, and aggregations.

5. **Avoid SELECT * in production.** Snowflake is columnar — selecting only needed columns reduces bytes scanned significantly, especially on wide tables.

6. **Tag everything in production.** Implement a consistent query tagging strategy from day one. Retroactively tagging queries for cost analysis is impossible.

7. **Compare scanned vs cached bytes.** If `PERCENTAGE_SCANNED_FROM_CACHE` is consistently low, your queries are always reading from remote storage. This may indicate workload patterns that don't benefit from the warehouse SSD cache, suggesting you might need to review query scheduling.

8. **Break complex queries into stages.** If a single query has compilation times over 5 seconds or causes remote spilling, consider splitting it into CTEs with intermediate temporary tables. This gives the optimizer simpler plans and reduces memory pressure.

9. **Use QUERY_HISTORY for trending.** Regularly query `QUERY_HISTORY` to track performance trends. A query that was fast last month but slow today often points to data growth, schema changes, or clustering degradation.

10. **Disable result cache when benchmarking.** Always set `USE_CACHED_RESULT = FALSE` when doing performance testing to ensure you measure actual execution time, not cache retrieval.
