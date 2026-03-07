# Materialized Views

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### Materialized View Concept in Snowflake

A **materialized view** is a pre-computed result set that is physically stored and automatically maintained by Snowflake. Unlike a regular view (which is just a saved SQL query that runs at query time), a materialized view stores actual data. When you query a materialized view, Snowflake reads from the stored result rather than re-executing the underlying query — providing faster results for expensive transformations, aggregations, or filters.

Snowflake handles materialized views differently from traditional databases: the refresh process is **fully automatic** and runs as a background serverless service. You do not need to schedule or trigger refreshes manually.

### Creating Materialized Views

```sql
-- Basic materialized view
CREATE MATERIALIZED VIEW mv_daily_sales AS
SELECT
    DATE_TRUNC('DAY', sale_timestamp) AS sale_date,
    region,
    product_category,
    COUNT(*)                          AS num_sales,
    SUM(amount)                       AS total_amount,
    AVG(amount)                       AS avg_amount
FROM raw_sales
GROUP BY 1, 2, 3;

-- Materialized view with a filter (common pattern)
CREATE MATERIALIZED VIEW mv_active_customers AS
SELECT customer_id, customer_name, email, signup_date
FROM customers
WHERE is_active = TRUE;

-- Materialized view with a clustering key
CREATE MATERIALIZED VIEW mv_orders_by_region
    CLUSTER BY (region)
AS
SELECT order_id, order_date, region, total_amount
FROM orders
WHERE order_date >= '2025-01-01';
```

### Automatic Refresh (Background Maintenance)

When the base table changes (INSERT, UPDATE, DELETE, MERGE), Snowflake's background service automatically refreshes the materialized view to keep it consistent. Key characteristics:

- **Serverless**: Refresh uses Snowflake-managed compute, not your virtual warehouses.
- **Incremental**: Snowflake only processes the changes (delta), not the entire base table.
- **Transparent**: No user action required — it just happens.
- **Near real-time**: There may be a small lag between base table changes and materialized view updates, but Snowflake keeps the view eventually consistent.

If you query a materialized view during a refresh, Snowflake ensures correct results by combining the stale materialized data with any recent base table changes — you always get accurate results even if the view is slightly behind.

### Query Rewrite

One of the most powerful features of Snowflake materialized views is **automatic query rewrite**. When you query the **base table**, Snowflake's optimizer may transparently rewrite the query to use the materialized view instead, if it determines the view can satisfy the query more efficiently.

```sql
-- You write this query against the base table:
SELECT region, SUM(amount)
FROM raw_sales
WHERE sale_timestamp >= '2025-01-01'
GROUP BY region;

-- Snowflake may automatically rewrite it to use mv_daily_sales
-- if that materialized view can satisfy the query.
-- This happens transparently — you do not need to change your query.
```

Query rewrite works when:

- The materialized view's columns and aggregations cover the query.
- The query's filters are compatible with (or a subset of) the view's filters.
- The optimizer determines using the view is more efficient.

You can verify query rewrite in the **Query Profile** — look for a scan on the materialized view instead of the base table.

### Supported Operations in Materialized Views

Materialized views in Snowflake support:

- **SELECT** from a single table
- **WHERE** filters (including complex predicates)
- **GROUP BY** with aggregate functions: `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`
- **DISTINCT**
- **Expressions and functions** on columns (e.g., `DATE_TRUNC`, `UPPER`, casts)
- **CLUSTER BY** on the materialized view itself
- **Nested views**: A materialized view can reference a regular view (as long as the view resolves to a single table)

### Limitations

Materialized views have significant restrictions compared to regular views:

| Limitation | Detail |
|-----------|--------|
| **No JOINs** | Cannot join multiple tables. Must reference a single base table. |
| **No subqueries** | Cannot contain subqueries in SELECT, FROM, or WHERE. |
| **No window functions** | `ROW_NUMBER()`, `RANK()`, `LAG()`, `LEAD()` etc. are not supported. |
| **No HAVING clause** | Not supported. |
| **No ORDER BY** | Cannot include ORDER BY (use CLUSTER BY instead for physical ordering). |
| **No LIMIT** | Cannot restrict row count. |
| **No UDFs** | User-defined functions are not allowed. |
| **No non-deterministic functions** | `CURRENT_TIMESTAMP()`, `RANDOM()`, `UUID_STRING()`, etc. are not allowed. |
| **Single table only** | The view must query exactly one base table. |
| **Base table changes** | If the base table is dropped and recreated, the materialized view becomes invalid. |

### Materialized View Costs

Materialized views incur three types of costs:

1. **Storage**: The materialized result set is physically stored, consuming storage space. This is proportional to the result set size, not the base table size.

2. **Serverless compute for refresh**: Each refresh cycle consumes serverless credits. The cost depends on:
   - Frequency of base table changes
   - Size of incremental changes
   - Complexity of the materialized view definition (aggregations are more expensive)

3. **Serverless compute for clustering** (if CLUSTER BY is defined on the materialized view): Additional cost for maintaining clustering on the view.

Monitor costs with:

```sql
-- Materialized view refresh history
SELECT *
FROM TABLE(INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END   => CURRENT_TIMESTAMP()
));
```

### Secure Materialized Views

Like regular views, materialized views can be created as **secure** to prevent the view definition from being exposed to consumers:

```sql
CREATE SECURE MATERIALIZED VIEW mv_customer_summary AS
SELECT
    region,
    COUNT(*)   AS customer_count,
    SUM(total_spend) AS total_regional_spend
FROM customers
GROUP BY region;
```

Secure materialized views:

- Hide the view definition from non-owner roles (`SHOW VIEWS` will not reveal the SQL).
- Are essential when sharing data via Snowflake Secure Data Sharing.
- May have a slight performance penalty because the optimizer cannot expose internal details to the query planner in the same way.
- Still support automatic query rewrite.

### Monitoring Materialized Views

```sql
-- List materialized views in the current schema
SHOW MATERIALIZED VIEWS;

-- Check detailed properties
SHOW MATERIALIZED VIEWS LIKE 'mv_daily%';

-- Refresh history and credit consumption
SELECT *
FROM TABLE(INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END   => CURRENT_TIMESTAMP(),
    TABLE_NAME       => 'MV_DAILY_SALES'
));

-- Check if a materialized view is stale or being refreshed
-- The "is_secure", "behind", "refreshing" columns in SHOW MATERIALIZED VIEWS output

-- Suspend/resume automatic maintenance
ALTER MATERIALIZED VIEW mv_daily_sales SUSPEND;  -- Pauses refresh
ALTER MATERIALIZED VIEW mv_daily_sales RESUME;   -- Resumes refresh
```

### Materialized Views vs. Regular Views vs. Tables

| Aspect | Regular View | Materialized View | Table |
|--------|-------------|-------------------|-------|
| Stores data | No (query alias) | Yes (pre-computed) | Yes |
| Automatic refresh | N/A | Yes (serverless) | No (manual ETL) |
| Query rewrite | No | Yes (automatic) | N/A |
| Maintenance cost | None | Serverless credits + storage | Depends on ETL |
| Staleness | Never stale (always live) | Briefly stale (auto-refreshed) | Can be stale (depends on ETL) |
| JOINs supported | Yes | No (single table only) | N/A |
| Complexity | Any valid SQL | Limited (no joins, no window funcs) | N/A |
| Best for | Simplifying complex queries, access control | Expensive aggregations on single tables | Persistent data storage |

### When to Use Materialized Views

**Good use cases:**

- Pre-aggregating large fact tables (e.g., daily/monthly summaries) when queries repeatedly compute the same aggregations.
- Filtering a large table to a commonly queried subset (e.g., only active records, recent data).
- Replacing manually maintained summary tables that require scheduled ETL jobs.
- Improving dashboard performance when dashboards query predictable aggregations.
- Providing a clustered view of data with a different clustering strategy than the base table.

**Poor use cases:**

- Queries requiring JOINs across multiple tables (not supported).
- Complex transformations needing window functions, UDFs, or subqueries.
- Base tables with extremely high DML rates (refresh costs may be excessive).
- Small tables where the base query is already fast.

---

## Real-World Examples

### Example 1: Dashboard Acceleration

A BI dashboard shows regional sales summaries. The base `sales` table has 2 billion rows and every dashboard load runs an expensive GROUP BY query:

```sql
-- Create materialized view for dashboard aggregation
CREATE MATERIALIZED VIEW mv_regional_sales_summary AS
SELECT
    DATE_TRUNC('DAY', sale_timestamp) AS sale_date,
    region,
    product_category,
    COUNT(*)       AS transaction_count,
    SUM(amount)    AS total_revenue,
    AVG(amount)    AS avg_transaction_value,
    MIN(amount)    AS min_transaction,
    MAX(amount)    AS max_transaction
FROM sales
GROUP BY 1, 2, 3;
```

Dashboard query before: 45 seconds (scans 2B rows).
Dashboard query after (with query rewrite): 1.2 seconds (reads pre-computed result).

### Example 2: Active Records Filter

An application frequently queries only active users from a 200M-row users table:

```sql
CREATE MATERIALIZED VIEW mv_active_users AS
SELECT user_id, username, email, last_login, account_tier
FROM users
WHERE is_active = TRUE AND is_verified = TRUE;
```

The materialized view contains only ~15M rows, making lookups dramatically faster. As users are deactivated or verified in the base table, the view updates automatically.

### Example 3: Different Clustering Strategy

The base `events` table is clustered by `event_timestamp`, but some queries filter primarily by `user_id`:

```sql
CREATE MATERIALIZED VIEW mv_events_by_user
    CLUSTER BY (user_id)
AS
SELECT event_id, event_timestamp, user_id, event_type, event_data
FROM events
WHERE event_timestamp >= DATEADD('MONTH', -6, CURRENT_DATE());
```

This provides a user-clustered view of recent events while the base table remains clustered by timestamp.

---

## Common Interview Questions & Answers

### Q1: What is a materialized view in Snowflake and how does it differ from a regular view?

**A:** A materialized view stores pre-computed results physically, while a regular view is just a saved SQL definition that executes at query time. Materialized views provide faster reads because the data is already computed, but they consume storage and require background compute to stay refreshed. Regular views have no storage cost but compute the result on every query.

### Q2: How does Snowflake refresh materialized views?

**A:** Snowflake refreshes materialized views automatically using a serverless background process. The refresh is incremental — only the delta (changed data) is processed, not the entire base table. This happens transparently without user intervention. There may be a brief lag between base table changes and materialized view updates, but queries always return correct results because Snowflake compensates for any staleness at query time.

### Q3: What is query rewrite and how does it work with materialized views?

**A:** Query rewrite is an optimizer feature where Snowflake automatically redirects a query written against the base table to use the materialized view instead, if the view can satisfy the query more efficiently. The user does not need to modify their query or even know the materialized view exists. This is powerful because existing applications and dashboards can benefit from materialized views without code changes.

### Q4: What are the main limitations of materialized views in Snowflake?

**A:** The key limitations are: (1) they can only reference a single base table (no JOINs), (2) no window functions, (3) no subqueries, (4) no UDFs, (5) no non-deterministic functions, (6) no HAVING, ORDER BY, or LIMIT clauses. These restrictions exist because Snowflake needs to incrementally maintain the view, which is only feasible with a constrained set of operations.

### Q5: What are the costs associated with materialized views?

**A:** Three cost components: (1) **Storage** for the pre-computed result set, (2) **Serverless compute credits** for automatic refresh when the base table changes, and (3) optionally, **additional serverless compute** for maintaining a CLUSTER BY defined on the materialized view. Costs increase with the frequency of base table DML and the complexity of the view's aggregations.

### Q6: When would you choose a materialized view over a manually maintained summary table?

**A:** Choose a materialized view when: the aggregation is over a single table, the supported operations are sufficient (no joins or window functions needed), and you want zero-maintenance automatic refresh. Choose a manual summary table when you need JOINs, window functions, UDFs, or complete control over refresh timing and logic. Materialized views eliminate the need for scheduling and orchestrating ETL refresh pipelines.

### Q7: Can you suspend and resume materialized view maintenance?

**A:** Yes. Use `ALTER MATERIALIZED VIEW <name> SUSPEND` to pause automatic refresh (useful when running bulk loads to avoid excessive refresh cycles) and `ALTER MATERIALIZED VIEW <name> RESUME` to restart it. While suspended, the view becomes increasingly stale, but Snowflake still returns correct results by compensating with base table data at query time.

### Q8: What is a secure materialized view?

**A:** A secure materialized view is created with `CREATE SECURE MATERIALIZED VIEW`. It hides the view definition from users who are not the owner, which is critical for data sharing scenarios where you do not want consumers to see the underlying SQL logic. Secure materialized views still support automatic refresh and query rewrite.

---

## Tips

- **Profile before creating.** Identify queries that are slow due to repeated aggregations on large single tables. These are your best candidates for materialized views.
- **Consider the refresh cost.** If the base table has very high DML rates, the continuous refresh cost may outweigh the query performance benefit. Use `MATERIALIZED_VIEW_REFRESH_HISTORY` to monitor.
- **Use SUSPEND during bulk loads.** When performing large batch loads into the base table, suspend the materialized view to avoid triggering many small refresh cycles. Resume after the load completes for a single efficient refresh.
- **Leverage query rewrite.** You do not need to rewrite application queries to point to the materialized view. Snowflake's optimizer will use the view automatically when beneficial.
- **Combine with clustering.** You can define a CLUSTER BY on a materialized view to further optimize queries against the view, especially if the clustering strategy differs from the base table.
- **Drop and recreate if the base table schema changes.** Materialized views become invalid if the base table is dropped/recreated or if referenced columns are altered. Plan for this in your DDL migration workflows.
- **Keep view definitions simple.** Simpler materialized views (fewer aggregations, fewer columns) are cheaper to maintain and more likely to be used by query rewrite.
- **Check for query rewrite in the Query Profile.** If you expect query rewrite to kick in but it does not, verify that the materialized view's definition is compatible with the query's filters and aggregations.
