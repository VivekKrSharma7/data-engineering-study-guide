# Clustering Keys & Data Clustering

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### Natural Clustering in Snowflake

When data is loaded into a Snowflake table, it is stored in micro-partitions. The order in which data is inserted determines how it is naturally clustered. For example, if data is loaded chronologically, rows with similar dates tend to reside in the same micro-partitions. This natural clustering can be highly effective for queries that filter on the column(s) aligned with the load order.

Over time, as DML operations (INSERT, UPDATE, DELETE, MERGE) modify a table, the natural clustering can degrade. Micro-partitions that once held tightly grouped data may become fragmented, causing Snowflake's pruning engine to scan more partitions than necessary.

### Clustering Depth

**Clustering depth** measures how many overlapping micro-partitions exist for a given column or set of columns. A lower clustering depth means data is well-clustered — fewer micro-partitions overlap for a given value range, so the query engine can prune more aggressively.

- **Depth of 1**: Ideal. Each value range maps to a minimal, non-overlapping set of micro-partitions.
- **Depth of N (large)**: Poor clustering. Many micro-partitions contain overlapping value ranges, forcing broader scans.

### Clustering Ratio

The **clustering ratio** represents the proportion of micro-partitions that are well-clustered (non-overlapping) relative to the total number of micro-partitions. A ratio closer to **1.0** indicates excellent clustering; a ratio closer to **0.0** indicates poor clustering.

### Defining Clustering Keys

You can explicitly define clustering keys on a table to instruct Snowflake to organize (and reorganize) micro-partitions around the specified columns.

```sql
-- Define clustering key during table creation
CREATE TABLE sales (
    sale_id       BIGINT,
    sale_date     DATE,
    region        VARCHAR(50),
    product_id    BIGINT,
    amount        DECIMAL(12, 2)
)
CLUSTER BY (sale_date, region);

-- Add or change clustering key on an existing table
ALTER TABLE sales CLUSTER BY (sale_date, region);

-- Remove (drop) a clustering key
ALTER TABLE sales DROP CLUSTERING KEY;
```

### Multi-Column Clustering Keys

You can specify multiple columns in a clustering key. The order matters — Snowflake prioritizes clustering on the first column listed, then the second, and so on. General guidance:

- Place the column with **lower cardinality** first (e.g., `region` with a few dozen values).
- Place the column with **higher cardinality** second (e.g., `sale_date`).

```sql
-- Low-cardinality column first, high-cardinality second
ALTER TABLE sales CLUSTER BY (region, sale_date);
```

This helps Snowflake create micro-partitions where each partition contains only one or two regions and a narrow date range, maximizing pruning for queries filtering on either or both columns.

### Clustering on Expressions

Clustering keys are not limited to raw columns. You can use expressions, including functions:

```sql
-- Cluster by the month portion of a timestamp
ALTER TABLE events CLUSTER BY (DATE_TRUNC('MONTH', event_timestamp), event_type);

-- Cluster by a CAST expression
ALTER TABLE logs CLUSTER BY (CAST(log_date AS DATE));

-- Cluster by a substring
ALTER TABLE users CLUSTER BY (SUBSTRING(last_name, 1, 2));
```

This is especially useful when queries consistently filter on a derived value rather than the raw column.

### Automatic Reclustering (Background Service)

Once a clustering key is defined, Snowflake's **Automatic Clustering** service runs in the background to maintain the clustering. Key characteristics:

- It is a **serverless** operation — Snowflake manages the compute resources automatically.
- Reclustering runs transparently and does not compete with your virtual warehouses.
- It activates when the clustering quality of a table degrades beyond an internal threshold.
- You do not need to schedule or trigger it manually.

### Reclustering Costs

Automatic reclustering consumes **serverless compute credits**. The costs depend on:

- **Table size**: Larger tables require more work to recluster.
- **DML frequency**: Tables with frequent inserts/updates/deletes require more reclustering cycles.
- **Number of clustering key columns**: More columns can increase the reclustering workload.
- **Data volatility**: Highly volatile data leads to more frequent reclustering.

You can monitor costs via the `AUTOMATIC_CLUSTERING_HISTORY` view:

```sql
-- Check reclustering credit consumption
SELECT *
FROM TABLE(INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END   => CURRENT_TIMESTAMP()
));
```

### When to Use Clustering Keys

Clustering keys are **not needed on every table**. Use them when:

| Scenario | Recommendation |
|----------|---------------|
| Table has billions of rows (multi-terabyte) | Strong candidate |
| Queries consistently filter on specific columns | Strong candidate |
| Table receives frequent DML causing fragmentation | Good candidate |
| Table is small (few GB or less) | Generally not needed |
| Queries are full-table scans (no filters) | No benefit |
| Table is append-only and loaded in natural order | Natural clustering may suffice |

### Monitoring Clustering Information

Snowflake provides two system functions to inspect clustering quality:

#### SYSTEM$CLUSTERING_INFORMATION

Returns detailed clustering metadata for a table on specified columns.

```sql
-- Check clustering info for the defined clustering key
SELECT SYSTEM$CLUSTERING_INFORMATION('sales');

-- Check clustering info for specific columns (even if not the defined key)
SELECT SYSTEM$CLUSTERING_INFORMATION('sales', '(sale_date, region)');
```

Sample output (JSON):

```json
{
  "cluster_by_keys": "LINEAR(sale_date, region)",
  "total_partition_count": 1250,
  "total_constant_partition_count": 820,
  "average_overlaps": 1.8,
  "average_depth": 2.1,
  "partition_depth_histogram": {
    "00000": 0,
    "00001": 820,
    "00002": 300,
    "00003": 100,
    "00004": 30
  }
}
```

Key fields:

- **average_overlaps**: Average number of overlapping micro-partitions. Lower is better.
- **average_depth**: Average clustering depth. Closer to 1 is optimal.
- **total_constant_partition_count**: Partitions where the clustering key has a single distinct value (perfectly clustered for that partition).

#### SYSTEM$CLUSTERING_DEPTH

Returns the average clustering depth for specified columns.

```sql
-- Average clustering depth on the clustering key columns
SELECT SYSTEM$CLUSTERING_DEPTH('sales', '(sale_date, region)');

-- Clustering depth on a single column
SELECT SYSTEM$CLUSTERING_DEPTH('sales', '(sale_date)');
```

### Clustering Keys vs Traditional Indexing

| Aspect | Clustering Keys (Snowflake) | Traditional Indexes (RDBMS) |
|--------|---------------------------|---------------------------|
| Mechanism | Physically reorganizes micro-partitions | Creates separate B-tree or hash structures |
| Storage overhead | Minimal (data is rearranged, not duplicated) | Significant (separate index structure) |
| Maintenance | Automatic (background reclustering) | Manual (REBUILD, REORGANIZE) or auto |
| Multiple keys per table | One clustering key (can include multiple columns) | Many indexes per table |
| Read pattern | Optimizes partition pruning | Optimizes row-level lookups |
| Write impact | Reclustering cost on DML-heavy tables | Index maintenance on every write |

### Best Practices for Choosing Clustering Columns

1. **Analyze query patterns first.** Identify the columns most frequently used in WHERE, JOIN, and ORDER BY clauses.

2. **Prefer low-to-medium cardinality columns.** Columns with thousands to low millions of distinct values are ideal. Extremely high cardinality (e.g., UUID) is rarely a good choice.

3. **Order columns from low to high cardinality** in the clustering key definition.

4. **Limit to 3-4 columns.** More columns increase reclustering cost with diminishing returns.

5. **Consider expressions** when queries filter on derived values (e.g., `DATE_TRUNC`, `TO_DATE`).

6. **Monitor before and after.** Use `SYSTEM$CLUSTERING_INFORMATION` to measure improvement and validate that clustering is worthwhile.

7. **Evaluate cost vs. benefit.** If reclustering credits outweigh query savings, clustering may not be justified.

---

## Real-World Examples

### Example 1: E-Commerce Order Table

An e-commerce company has a `fact_orders` table with 5 billion rows. Most analytic queries filter by `order_date` and `country_code`.

```sql
-- Check natural clustering quality
SELECT SYSTEM$CLUSTERING_INFORMATION('fact_orders', '(order_date, country_code)');
-- Result: average_depth = 12.4 (poor)

-- Define clustering key
ALTER TABLE fact_orders CLUSTER BY (country_code, order_date);

-- After automatic reclustering completes (hours/days depending on size)
SELECT SYSTEM$CLUSTERING_INFORMATION('fact_orders', '(country_code, order_date)');
-- Result: average_depth = 1.6 (excellent)
```

Query before clustering: scanned 8,200 micro-partitions.
Query after clustering: scanned 140 micro-partitions — a **98% reduction**.

### Example 2: IoT Sensor Data with Expression-Based Key

A manufacturing company ingests sensor readings with a `reading_timestamp` column (TIMESTAMP_NTZ). Queries always filter at the daily level.

```sql
ALTER TABLE sensor_readings
    CLUSTER BY (DATE_TRUNC('DAY', reading_timestamp), sensor_group);
```

This clusters data by day rather than the full timestamp precision, aligning physical storage with query filter granularity.

---

## Common Interview Questions & Answers

### Q1: What is a clustering key in Snowflake and why would you use one?

**A:** A clustering key is a subset of columns (or expressions) defined on a table that instructs Snowflake to physically co-locate related data within micro-partitions. The purpose is to improve partition pruning — when a query filters on the clustering key columns, Snowflake can skip irrelevant micro-partitions entirely. This is most beneficial on very large tables (hundreds of GB to TB+) where natural clustering has degraded due to DML activity.

### Q2: How does Snowflake's clustering differ from traditional database indexing?

**A:** Traditional indexes create separate data structures (B-trees, hash tables) that point to rows. Snowflake has no row-level indexes. Instead, clustering physically reorganizes the data within micro-partitions so that the metadata (min/max values per partition) enables effective pruning. There is no separate index structure consuming additional storage; the data itself is rearranged.

### Q3: What is "clustering depth" and what values indicate good clustering?

**A:** Clustering depth is the average number of overlapping micro-partitions for a given value of the clustering key. A depth of 1 is ideal — it means each value or range maps to exactly one micro-partition. Depths of 2-3 are generally acceptable. Depths above 5-10 suggest poor clustering and potential benefit from defining a clustering key.

### Q4: Does Snowflake reclustering happen automatically? What are the costs?

**A:** Yes. Once a clustering key is defined, Snowflake's Automatic Clustering service maintains the clustering in the background using serverless compute. You are charged serverless credits for this work. The cost depends on table size, DML frequency, and the complexity of the clustering key. You can monitor costs through `AUTOMATIC_CLUSTERING_HISTORY` in `INFORMATION_SCHEMA`.

### Q5: When should you NOT use clustering keys?

**A:** Avoid clustering keys when: (1) the table is small (a few GB or less) because pruning already works well; (2) queries do not consistently filter on specific columns; (3) the table is append-only and loaded in natural order that already aligns with query filters; (4) the reclustering cost would exceed the performance savings.

### Q6: Can you cluster on expressions? Give an example.

**A:** Yes. You can use expressions like `DATE_TRUNC('MONTH', timestamp_col)`, `CAST(col AS DATE)`, or `SUBSTRING(col, 1, 3)`. For example, if queries always filter by month: `ALTER TABLE events CLUSTER BY (DATE_TRUNC('MONTH', event_ts));`. This aligns physical data organization with the actual query filter granularity.

### Q7: How do you monitor clustering quality?

**A:** Use `SYSTEM$CLUSTERING_INFORMATION('table_name', '(col1, col2)')` to get detailed metrics including average depth, average overlaps, and a partition depth histogram. Use `SYSTEM$CLUSTERING_DEPTH('table_name', '(col1)')` for a quick average depth value. Monitor reclustering costs with `INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY`.

---

## Tips

- **Do not define clustering keys prematurely.** Load data first, run your typical queries, and check if partition pruning is already effective. Only add clustering keys when you observe poor pruning on large tables.
- **Use QUERY_PROFILE** to see how many partitions are scanned vs. pruned. This is the most practical way to measure clustering effectiveness.
- **Reclustering is not instant.** For very large tables, it may take hours or even days for the background service to fully recluster. Be patient after defining a key.
- **Changing a clustering key triggers a full recluster.** Avoid frequent changes to clustering key definitions.
- **Linear vs. non-linear clustering**: Snowflake uses `LINEAR` clustering by default for multi-column keys, which interleaves column values for more balanced pruning across all columns in the key.
- **Account-level cost monitoring**: Set up resource monitors or review the `AUTOMATIC_CLUSTERING_HISTORY` regularly to prevent unexpected spend on reclustering.
