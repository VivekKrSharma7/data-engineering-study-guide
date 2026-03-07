# Dynamic Tables

[Back to Snowflake Index](./README.md)

---

## Overview

Dynamic Tables are a declarative data transformation feature in Snowflake that simplifies data pipeline development. Instead of writing imperative logic with streams and tasks, you define the **desired end state** of your data using a SQL query, and Snowflake automatically manages the refresh process to keep the data up to date within a specified lag target.

---

## Key Concepts

### Declarative Data Transformation

With Dynamic Tables, you write a single SQL query that describes **what** the result should look like, not **how** to compute incremental changes. Snowflake handles the orchestration, scheduling, and refresh logic internally.

```sql
-- Traditional approach: Streams + Tasks (imperative)
-- 1. Create a stream to capture changes
-- 2. Create a task to process changes
-- 3. Write MERGE logic to handle inserts/updates/deletes
-- 4. Manage scheduling and dependencies

-- Dynamic Table approach: (declarative)
CREATE OR REPLACE DYNAMIC TABLE customer_orders
  TARGET_LAG = '10 minutes'
  WAREHOUSE = transform_wh
AS
  SELECT
    c.customer_id,
    c.customer_name,
    c.email,
    COUNT(o.order_id) AS total_orders,
    SUM(o.order_amount) AS total_spend,
    MAX(o.order_date) AS last_order_date
  FROM raw.customers c
  LEFT JOIN raw.orders o ON c.customer_id = o.customer_id
  GROUP BY c.customer_id, c.customer_name, c.email;
```

### TARGET_LAG Setting

`TARGET_LAG` defines the **maximum acceptable staleness** of the dynamic table's data relative to its base tables. Snowflake uses this to determine the refresh frequency.

```sql
-- Refresh within 1 minute of base table changes
CREATE DYNAMIC TABLE dt_near_realtime
  TARGET_LAG = '1 minute'
  WAREHOUSE = etl_wh
AS SELECT ...;

-- Refresh within 1 hour
CREATE DYNAMIC TABLE dt_hourly
  TARGET_LAG = '1 hour'
  WAREHOUSE = etl_wh
AS SELECT ...;

-- Downstream dynamic table: automatically matches upstream lag
CREATE DYNAMIC TABLE dt_downstream
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = etl_wh
AS SELECT * FROM dt_near_realtime WHERE ...;
```

**Important details about TARGET_LAG:**

| Setting | Behavior |
|---------|----------|
| `'N minutes'` | Snowflake refreshes as needed to keep data within N minutes of the base tables |
| `'N hours'` | Same, but in hours |
| `DOWNSTREAM` | The dynamic table refreshes based on the lag requirements of downstream dynamic tables that depend on it |

- Snowflake **does not guarantee exact timing** — it aims to keep lag within the target
- Shorter lag = more frequent refreshes = higher compute cost
- If there are no changes in the base tables, no refresh is triggered (efficient)

### Refresh Modes: Incremental vs Full

Snowflake automatically determines the most efficient refresh strategy:

**Incremental Refresh:**
- Processes only the **changed data** since the last refresh
- Much faster and cheaper for large tables with small changes
- Snowflake attempts this whenever possible
- Supported for many common SQL patterns (filters, joins, aggregations)

**Full Refresh:**
- Recomputes the **entire result set** from scratch
- Required when the query uses constructs that prevent incremental processing
- Examples that force full refresh: certain window functions, non-deterministic functions, UNION operations, subqueries in some positions

```sql
-- Check which refresh mode a dynamic table uses
SELECT name, refresh_mode, refresh_mode_reason
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
  NAME => 'MY_DYNAMIC_TABLE'
));
```

You can also force a specific mode:

```sql
-- Force incremental refresh (will error if not possible)
CREATE DYNAMIC TABLE dt_incremental
  TARGET_LAG = '10 minutes'
  WAREHOUSE = etl_wh
  REFRESH_MODE = INCREMENTAL
AS SELECT ...;

-- Force full refresh
CREATE DYNAMIC TABLE dt_full
  TARGET_LAG = '1 hour'
  WAREHOUSE = etl_wh
  REFRESH_MODE = FULL
AS SELECT ...;

-- Let Snowflake decide (default)
CREATE DYNAMIC TABLE dt_auto
  TARGET_LAG = '10 minutes'
  WAREHOUSE = etl_wh
  REFRESH_MODE = AUTO
AS SELECT ...;
```

---

## Dynamic Table Pipelines (Chaining)

Dynamic tables can be **chained** together to form multi-step pipelines. Each dynamic table reads from upstream sources (which can include other dynamic tables), creating a DAG (directed acyclic graph) of transformations.

```sql
-- Layer 1: Cleaned raw data
CREATE OR REPLACE DYNAMIC TABLE bronze_orders
  TARGET_LAG = '5 minutes'
  WAREHOUSE = etl_wh
AS
  SELECT
    order_id,
    customer_id,
    TRY_TO_NUMBER(amount) AS amount,
    TRY_TO_TIMESTAMP(order_ts) AS order_timestamp,
    CURRENT_TIMESTAMP() AS processed_at
  FROM raw.orders_stream_landing
  WHERE TRY_TO_NUMBER(amount) IS NOT NULL;

-- Layer 2: Enriched data (reads from Layer 1)
CREATE OR REPLACE DYNAMIC TABLE silver_orders
  TARGET_LAG = '10 minutes'
  WAREHOUSE = etl_wh
AS
  SELECT
    o.order_id,
    o.customer_id,
    c.customer_name,
    c.segment,
    o.amount,
    o.order_timestamp,
    r.region_name
  FROM bronze_orders o
  JOIN dim_customers c ON o.customer_id = c.customer_id
  JOIN dim_regions r ON c.region_id = r.region_id;

-- Layer 3: Aggregated metrics (reads from Layer 2)
CREATE OR REPLACE DYNAMIC TABLE gold_daily_sales
  TARGET_LAG = '30 minutes'
  WAREHOUSE = etl_wh
AS
  SELECT
    DATE_TRUNC('DAY', order_timestamp) AS order_date,
    segment,
    region_name,
    COUNT(*) AS order_count,
    SUM(amount) AS total_revenue,
    AVG(amount) AS avg_order_value
  FROM silver_orders
  GROUP BY 1, 2, 3;
```

Snowflake automatically manages the refresh dependencies. When `bronze_orders` refreshes, Snowflake knows to subsequently refresh `silver_orders` and then `gold_daily_sales` as needed to meet their respective lag targets.

---

## Dynamic Tables vs Other Approaches

### Dynamic Tables vs Streams + Tasks

| Aspect | Dynamic Tables | Streams + Tasks |
|--------|---------------|-----------------|
| Paradigm | Declarative (define WHAT) | Imperative (define HOW) |
| Incremental Logic | Automatic | Manual (write MERGE/INSERT) |
| Dependency Management | Automatic (DAG) | Manual (task trees, predecessors) |
| Error Handling | Built-in retry and recovery | Manual implementation |
| Flexibility | SQL query only | Full procedural logic (JS, Python, SQL) |
| Complex Transformations | Limited by SQL query support | Unlimited — stored procs, UDFs |
| State Management | Automatic | Manual (stream offsets, etc.) |
| Best For | Standard ETL/ELT pipelines | Complex logic, conditional branching |

### Dynamic Tables vs Materialized Views

| Aspect | Dynamic Tables | Materialized Views |
|--------|---------------|-------------------|
| Refresh Control | TARGET_LAG (user-defined) | Automatic (near real-time, no control) |
| Warehouse | User-specified warehouse | Serverless (Snowflake-managed) |
| Query Complexity | Broad SQL support (joins, aggregations, CTEs) | Limited (no joins, limited aggregations) |
| Cost Model | Warehouse compute costs | Serverless credit costs |
| Chaining | Can chain dynamic tables | Cannot chain materialized views |
| Use Case | Data pipelines, complex transforms | Simple aggregations, query acceleration |

---

## Monitoring Dynamic Tables

### DYNAMIC_TABLE_REFRESH_HISTORY

```sql
-- View refresh history for a specific dynamic table
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
  NAME => 'GOLD_DAILY_SALES',
  DATA_TIMESTAMP_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
));

-- Key columns in the result:
-- NAME: Dynamic table name
-- REFRESH_TRIGGER: What triggered the refresh
-- REFRESH_ACTION: INCREMENTAL or FULL
-- STATE: SUCCEEDED, FAILED, CANCELLED
-- STATE_MESSAGE: Error details if failed
-- DATA_TIMESTAMP: The freshness timestamp after refresh
-- STATISTICS: Rows inserted/updated/deleted
```

### DYNAMIC_TABLE_GRAPH_HISTORY

```sql
-- View the dependency graph and pipeline health
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_GRAPH_HISTORY());
```

### Checking Current Lag

```sql
-- See current dynamic tables and their lag
SHOW DYNAMIC TABLES;

-- Key columns:
-- TARGET_LAG: configured lag
-- SCHEDULING_STATE: RUNNING, SUSPENDED
-- DATA_TIMESTAMP: last refresh data freshness
-- REFRESH_MODE: AUTO, INCREMENTAL, FULL
```

### Querying Account Usage

```sql
-- Historical refresh data (up to 365 days)
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY
WHERE DYNAMIC_TABLE_NAME = 'GOLD_DAILY_SALES'
  AND START_TIME > DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC;
```

---

## Managing Dynamic Tables

```sql
-- Suspend a dynamic table (pause refreshes)
ALTER DYNAMIC TABLE gold_daily_sales SUSPEND;

-- Resume a dynamic table
ALTER DYNAMIC TABLE gold_daily_sales RESUME;

-- Change the target lag
ALTER DYNAMIC TABLE gold_daily_sales SET TARGET_LAG = '1 hour';

-- Change the warehouse
ALTER DYNAMIC TABLE gold_daily_sales SET WAREHOUSE = larger_wh;

-- Manually trigger a refresh
ALTER DYNAMIC TABLE gold_daily_sales REFRESH;

-- Drop a dynamic table
DROP DYNAMIC TABLE gold_daily_sales;
```

---

## Cost Considerations

1. **Compute Costs**: Every refresh uses your specified warehouse. Shorter `TARGET_LAG` = more frequent refreshes = higher cost.
2. **Warehouse Sizing**: Right-size the warehouse for the transformation complexity. Over-provisioning wastes credits.
3. **Incremental vs Full**: Incremental refreshes are significantly cheaper. Design queries to be incrementally refreshable when possible.
4. **Storage Costs**: Dynamic tables store their results like regular tables, consuming storage.
5. **No Refresh When Unchanged**: If base data has not changed, Snowflake skips the refresh — this saves compute.

**Cost optimization tips:**

```sql
-- Use DOWNSTREAM lag for intermediate tables
-- Only the final consumer's lag drives the schedule
CREATE DYNAMIC TABLE intermediate_dt
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = etl_wh
AS SELECT ...;

-- Use a smaller warehouse for simpler transforms
CREATE DYNAMIC TABLE simple_filter_dt
  TARGET_LAG = '5 minutes'
  WAREHOUSE = xs_wh   -- XS is enough for simple filters
AS SELECT * FROM source WHERE status = 'ACTIVE';
```

---

## Limitations

- Dynamic tables only support **SQL SELECT queries** as their definition — no procedural logic, no multi-statement transforms
- Cannot use **non-deterministic functions** that change with each evaluation (some exceptions like `CURRENT_TIMESTAMP()` are handled)
- Cannot directly write to a dynamic table (INSERT, UPDATE, DELETE are not allowed)
- Dynamic tables cannot be used as targets for data loading (COPY INTO)
- **Time Travel** on dynamic tables is limited — you cannot set retention independently
- Clustering keys cannot be defined on dynamic tables at creation (but Snowflake may cluster automatically based on refresh)
- External tables cannot be directly referenced in some configurations
- Maximum pipeline depth (chain length) has practical limits for managing lag propagation

---

## Real-World Use Case: Medallion Architecture

```sql
-- BRONZE: Raw ingestion with minimal cleaning
CREATE OR REPLACE DYNAMIC TABLE bronze_events
  TARGET_LAG = '2 minutes'
  WAREHOUSE = etl_wh
AS
  SELECT
    PARSE_JSON(raw_data) AS event_data,
    event_data:event_type::STRING AS event_type,
    event_data:user_id::NUMBER AS user_id,
    event_data:timestamp::TIMESTAMP_NTZ AS event_ts,
    event_data:properties AS properties,
    metadata$filename AS source_file,
    CURRENT_TIMESTAMP() AS ingested_at
  FROM raw.events_landing;

-- SILVER: Business logic, deduplication, enrichment
CREATE OR REPLACE DYNAMIC TABLE silver_user_events
  TARGET_LAG = '5 minutes'
  WAREHOUSE = etl_wh
AS
  SELECT DISTINCT
    e.user_id,
    u.user_name,
    u.account_type,
    e.event_type,
    e.event_ts,
    e.properties:page_url::STRING AS page_url,
    e.properties:session_id::STRING AS session_id
  FROM bronze_events e
  JOIN dim_users u ON e.user_id = u.user_id
  WHERE e.event_type IS NOT NULL;

-- GOLD: Business-ready aggregates
CREATE OR REPLACE DYNAMIC TABLE gold_user_engagement
  TARGET_LAG = '15 minutes'
  WAREHOUSE = etl_wh
AS
  SELECT
    user_id,
    user_name,
    account_type,
    DATE_TRUNC('DAY', event_ts) AS activity_date,
    COUNT(*) AS total_events,
    COUNT(DISTINCT session_id) AS unique_sessions,
    MIN(event_ts) AS first_event,
    MAX(event_ts) AS last_event,
    DATEDIFF('minute', MIN(event_ts), MAX(event_ts)) AS active_minutes
  FROM silver_user_events
  GROUP BY 1, 2, 3, 4;
```

---

## Common Interview Questions

### Q1: What is a Dynamic Table and how does it differ from a regular table?

**A:** A Dynamic Table is a table whose contents are defined by a SQL query and automatically refreshed by Snowflake to stay current with its source data, within a user-specified lag target (`TARGET_LAG`). Unlike a regular table where you explicitly insert, update, or delete rows, a Dynamic Table is read-only and declaratively defined — you specify the desired result, and Snowflake handles the refresh mechanics.

### Q2: How does TARGET_LAG work, and what does setting it to DOWNSTREAM mean?

**A:** `TARGET_LAG` specifies the maximum acceptable data freshness lag. For example, `TARGET_LAG = '10 minutes'` means the data should be no more than 10 minutes behind the base tables. Snowflake automatically schedules refreshes to meet this target. Setting `TARGET_LAG = DOWNSTREAM` means the dynamic table does not have its own lag target — instead, it refreshes on-demand based on the lag requirements of downstream dynamic tables that consume it. This prevents unnecessary intermediate refreshes.

### Q3: What is the difference between incremental and full refresh?

**A:** Incremental refresh processes only the data that has changed since the last refresh, making it fast and efficient. Full refresh recomputes the entire result set from scratch. Snowflake automatically chooses incremental when the query structure supports it. Certain SQL constructs (like some window functions or UNION) force a full refresh. You can check the refresh mode in `DYNAMIC_TABLE_REFRESH_HISTORY`.

### Q4: When would you choose Dynamic Tables over Streams and Tasks?

**A:** Dynamic Tables are ideal for standard SQL-based transformation pipelines where you want simplicity and automatic dependency management. Choose them when your transformations can be expressed as SQL SELECT queries and you want Snowflake to handle scheduling, incremental logic, and error recovery. Choose Streams + Tasks when you need procedural logic, conditional branching, external API calls, complex error handling, or transformations that go beyond what a single SQL query can express.

### Q5: When would you choose a Dynamic Table over a Materialized View?

**A:** Choose Dynamic Tables when you need joins, complex aggregations, CTEs, or chaining of multiple transformation steps. Materialized Views are limited to simple queries on a single table (no joins). Also choose Dynamic Tables when you want explicit control over refresh frequency via `TARGET_LAG` and want to use your own warehouse for compute. Materialized Views refresh automatically using serverless compute with no user control over timing.

### Q6: How do you monitor the health of a Dynamic Table pipeline?

**A:** Use `INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY()` to view refresh status, duration, rows processed, and errors. Use `SHOW DYNAMIC TABLES` to see current lag, scheduling state, and refresh mode. For long-term analysis, query `SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLE_REFRESH_HISTORY`. Monitor for failed refreshes, increasing lag, and unexpected full refreshes.

### Q7: What happens if a Dynamic Table refresh fails?

**A:** Snowflake automatically retries failed refreshes. The dynamic table retains its last successfully refreshed data — it does not become empty or corrupted. The failure is logged in `DYNAMIC_TABLE_REFRESH_HISTORY` with error details. If failures persist, the data will become staler than the `TARGET_LAG` allows, and you should investigate the root cause.

---

## Tips

1. **Start with AUTO refresh mode** — let Snowflake determine whether incremental is possible. Only force a mode if you have a specific reason.

2. **Use DOWNSTREAM for intermediate tables** in a pipeline chain — this avoids unnecessary refreshes and reduces compute costs.

3. **Right-size your warehouse** for each dynamic table. Simple filters need a small warehouse; complex joins and aggregations may need a larger one.

4. **Monitor refresh history regularly** — unexpected full refreshes, increasing durations, or failures are early warning signs.

5. **Design for incremental refresh** — avoid SQL constructs that force full refresh when possible. Simple JOINs, filters, and aggregations are incrementally refreshable.

6. **Dynamic tables are ideal for the medallion architecture** (bronze/silver/gold) because each layer can be a dynamic table chained to the previous one.

7. **Do not over-tighten TARGET_LAG** — setting it to 1 minute when 30 minutes would suffice wastes compute credits. Align lag with actual business requirements.

---
