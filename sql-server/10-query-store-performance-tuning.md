# Query Store & Performance Tuning

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [What is Query Store?](#what-is-query-store)
2. [Query Store Architecture](#query-store-architecture)
3. [Configuring Query Store](#configuring-query-store)
4. [Capturing Queries and Plans](#capturing-queries-and-plans)
5. [Query Store Catalog Views](#query-store-catalog-views)
6. [Plan Forcing](#plan-forcing)
7. [Regressed Queries Report](#regressed-queries-report)
8. [Top Resource Consuming Queries](#top-resource-consuming-queries)
9. [Plan Comparison](#plan-comparison)
10. [Wait Statistics in Query Store](#wait-statistics-in-query-store)
11. [Query Store Hints](#query-store-hints)
12. [A/B Testing with Query Store](#ab-testing-with-query-store)
13. [Cleanup Policies](#cleanup-policies)
14. [Integrating Query Store with Performance Tuning Workflow](#integrating-query-store-with-performance-tuning-workflow)
15. [Common Interview Questions](#common-interview-questions)
16. [Tips](#tips)

---

## What is Query Store?

Query Store is a built-in performance monitoring feature introduced in SQL Server 2016 that automatically captures a history of queries, execution plans, and runtime statistics. Think of it as a "flight data recorder" for your database -- it persists data across server restarts because it stores information directly in the user database, not in memory.

### Why Query Store Matters

Before Query Store, diagnosing plan regression required combining data from multiple DMVs (Dynamic Management Views) that were volatile -- they were cleared on restart, during memory pressure, or when the plan cache was flushed. Query Store solves this by providing:

- **Persistent storage** of query text, plans, and statistics inside the database itself
- **Historical comparison** of execution plans over time
- **Plan forcing** to lock a known-good plan to a query
- **Automatic regression detection** to identify queries that have gotten worse

---

## Query Store Architecture

Query Store operates with an asynchronous write model:

```
Query Execution
      |
      v
  In-Memory Buffers (aggregation happens here)
      |
      v  (async flush based on DATA_FLUSH_INTERVAL_SECONDS)
  On-Disk Storage (inside the user database)
      |
      v
  Query Store Catalog Views (sys.query_store_*)
```

### Key Architectural Components

| Component | Description |
|-----------|-------------|
| **Query Text** | The normalized SQL text of each captured query |
| **Query** | A logical grouping -- same query text maps to one query_id |
| **Plan** | Each unique execution plan for a given query gets a plan_id |
| **Runtime Stats** | Aggregated metrics (CPU, duration, reads, writes, rows, memory) per plan per interval |
| **Wait Stats** | Aggregated wait statistics per plan per interval (SQL Server 2017+) |

### How Data Flows

1. A query executes and its compile/execution data is captured in memory.
2. Runtime statistics are aggregated in memory over the configured `INTERVAL_LENGTH_MINUTES`.
3. Periodically (per `DATA_FLUSH_INTERVAL_SECONDS`), the in-memory data is flushed to disk.
4. The on-disk data is queryable through `sys.query_store_*` catalog views.

---

## Configuring Query Store

### Enabling Query Store

```sql
-- Enable Query Store on a database
ALTER DATABASE [AdventureWorks]
SET QUERY_STORE = ON;

-- Full configuration example
ALTER DATABASE [AdventureWorks]
SET QUERY_STORE = ON (
    OPERATION_MODE = READ_WRITE,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 30),
    DATA_FLUSH_INTERVAL_SECONDS = 900,          -- 15 minutes
    INTERVAL_LENGTH_MINUTES = 60,                -- 1 hour aggregation
    MAX_STORAGE_SIZE_MB = 1024,                  -- 1 GB
    QUERY_CAPTURE_MODE = AUTO,                   -- Only capture relevant queries
    SIZE_BASED_CLEANUP_MODE = AUTO,              -- Auto-cleanup when near max size
    MAX_PLANS_PER_QUERY = 200,
    WAIT_STATS_CAPTURE_MODE = ON                 -- SQL Server 2017+
);
```

### Configuration Parameters Explained

| Parameter | Default | Description |
|-----------|---------|-------------|
| `OPERATION_MODE` | READ_WRITE | READ_WRITE = active capture; READ_ONLY = no new data captured |
| `DATA_FLUSH_INTERVAL_SECONDS` | 900 | How often in-memory data is flushed to disk |
| `INTERVAL_LENGTH_MINUTES` | 60 | Aggregation window for runtime stats |
| `MAX_STORAGE_SIZE_MB` | 100 | Maximum disk space for Query Store data |
| `QUERY_CAPTURE_MODE` | ALL | ALL = every query; AUTO = ignore trivial/infrequent; CUSTOM (2019+) |
| `STALE_QUERY_THRESHOLD_DAYS` | 30 | How long to retain data |
| `SIZE_BASED_CLEANUP_MODE` | AUTO | Automatically purge oldest data when approaching MAX_STORAGE_SIZE_MB |
| `MAX_PLANS_PER_QUERY` | 200 | Maximum number of plans retained per query |
| `WAIT_STATS_CAPTURE_MODE` | ON | Capture wait statistics (SQL Server 2017+) |

### Custom Capture Mode (SQL Server 2019+)

```sql
ALTER DATABASE [AdventureWorks]
SET QUERY_STORE = ON (
    QUERY_CAPTURE_MODE = CUSTOM,
    QUERY_CAPTURE_POLICY = (
        STALE_CAPTURE_POLICY_THRESHOLD = 24 HOURS,
        EXECUTION_COUNT = 30,
        TOTAL_COMPILE_CPU_TIME_MS = 1000,
        TOTAL_EXECUTION_CPU_TIME_MS = 100
    )
);
```

### Checking Current Configuration

```sql
SELECT *
FROM sys.database_query_store_options;
```

Key columns to monitor:

- `actual_state_desc` -- If you set READ_WRITE but this shows READ_ONLY, Query Store switched to read-only (often because it hit `MAX_STORAGE_SIZE_MB`).
- `current_storage_size_mb` -- Current disk usage.
- `readonly_reason` -- Why Query Store went to read-only mode.

---

## Capturing Queries and Plans

### What Gets Captured

Query Store captures:

- **Parameterized query text** -- The normalized form (parameters replaced with placeholders)
- **Execution plans** in XML format
- **Runtime statistics** aggregated per interval (avg, min, max, last, stdev for each metric)
- **Compile-time statistics**

### Query Capture Modes

- **ALL**: Every query is captured. Can be noisy on busy systems.
- **AUTO**: SQL Server filters out ad-hoc queries with insignificant resource usage. This is the recommended default.
- **NONE**: Stops capturing new queries but continues recording stats for already-tracked queries.
- **CUSTOM** (2019+): Fine-grained control over what gets captured.

### Viewing Captured Data

```sql
-- See all captured queries
SELECT
    q.query_id,
    qt.query_sql_text,
    q.count_compiles,
    q.avg_compile_duration,
    q.last_execution_time
FROM sys.query_store_query AS q
JOIN sys.query_store_query_text AS qt
    ON q.query_text_id = qt.query_text_id
ORDER BY q.last_execution_time DESC;

-- See plans for a specific query
SELECT
    p.plan_id,
    p.query_id,
    p.is_forced_plan,
    p.last_execution_time,
    TRY_CAST(p.query_plan AS XML) AS query_plan_xml
FROM sys.query_store_plan AS p
WHERE p.query_id = 42;
```

---

## Query Store Catalog Views

These are the core views that store all Query Store data:

| View | Description |
|------|-------------|
| `sys.query_store_query_text` | Stores the actual SQL text and its hash |
| `sys.query_store_query` | Query metadata (context settings, compile stats, last execution) |
| `sys.query_store_plan` | Execution plans associated with queries |
| `sys.query_store_runtime_stats` | Aggregated runtime statistics per plan per interval |
| `sys.query_store_runtime_stats_interval` | Defines the time intervals for aggregation |
| `sys.query_store_wait_stats` | Wait statistics per plan per interval (2017+) |
| `sys.database_query_store_options` | Current Query Store configuration |
| `sys.query_store_query_hints` | Query Store hints (2022+) |

### Comprehensive Query: Top Resource Consumers

```sql
SELECT TOP 20
    q.query_id,
    qt.query_sql_text,
    p.plan_id,
    rs.avg_duration,
    rs.avg_cpu_time,
    rs.avg_logical_io_reads,
    rs.avg_logical_io_writes,
    rs.avg_rowcount,
    rs.count_executions,
    rs.avg_duration * rs.count_executions AS total_duration,
    TRY_CAST(p.query_plan AS XML) AS query_plan_xml,
    rsi.start_time,
    rsi.end_time
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan AS p
    ON rs.plan_id = p.plan_id
JOIN sys.query_store_query AS q
    ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt
    ON q.query_text_id = qt.query_text_id
WHERE rsi.start_time >= DATEADD(HOUR, -24, GETUTCDATE())
ORDER BY total_duration DESC;
```

---

## Plan Forcing

Plan forcing is one of the most powerful features of Query Store. It lets you "lock" a specific execution plan to a query, ensuring the optimizer always uses that plan.

### When to Force a Plan

- A query regressed after a plan change and the old plan was objectively better.
- You need a temporary fix while investigating the root cause.
- The optimizer consistently picks a suboptimal plan due to data skew or parameter sniffing.

### Forcing and Unforcing Plans

```sql
-- Force a specific plan
EXEC sp_query_store_force_plan
    @query_id = 42,
    @plan_id = 7;

-- Unforce a plan
EXEC sp_query_store_unforce_plan
    @query_id = 42,
    @plan_id = 7;

-- Check all forced plans
SELECT
    q.query_id,
    p.plan_id,
    p.is_forced_plan,
    p.force_failure_count,
    p.last_force_failure_reason_desc,
    qt.query_sql_text
FROM sys.query_store_plan AS p
JOIN sys.query_store_query AS q
    ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt
    ON q.query_text_id = qt.query_text_id
WHERE p.is_forced_plan = 1;
```

### How Plan Forcing Works Internally

When a plan is forced, SQL Server stores the plan's "shape" (the plan guide equivalent). During compilation, the optimizer first generates its own plan, then checks if there is a forced plan. If the forced plan is still valid (indexes still exist, schema unchanged), it uses the forced plan. If not, it uses the optimizer's plan and increments `force_failure_count`.

### Important Considerations

- Forced plans survive server restarts (they are persisted in the database).
- If the underlying schema changes (e.g., a required index is dropped), the forced plan will fail gracefully -- the query still executes, just with the optimizer's chosen plan.
- Monitor `force_failure_count` and `last_force_failure_reason_desc` to detect broken forced plans.

---

## Regressed Queries Report

The Regressed Queries report identifies queries whose performance has degraded over time -- typically because the optimizer chose a different (worse) execution plan.

### Finding Regressed Queries with T-SQL

```sql
-- Find queries where recent performance is worse than historical
WITH RecentStats AS (
    SELECT
        p.query_id,
        p.plan_id,
        AVG(rs.avg_duration) AS recent_avg_duration,
        SUM(rs.count_executions) AS recent_executions
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON rs.plan_id = p.plan_id
    WHERE rsi.start_time >= DATEADD(HOUR, -2, GETUTCDATE())
    GROUP BY p.query_id, p.plan_id
),
HistoricalStats AS (
    SELECT
        p.query_id,
        p.plan_id,
        AVG(rs.avg_duration) AS historical_avg_duration,
        SUM(rs.count_executions) AS historical_executions
    FROM sys.query_store_runtime_stats AS rs
    JOIN sys.query_store_runtime_stats_interval AS rsi
        ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
    JOIN sys.query_store_plan AS p
        ON rs.plan_id = p.plan_id
    WHERE rsi.start_time >= DATEADD(DAY, -7, GETUTCDATE())
      AND rsi.start_time < DATEADD(HOUR, -2, GETUTCDATE())
    GROUP BY p.query_id, p.plan_id
)
SELECT
    r.query_id,
    qt.query_sql_text,
    r.plan_id AS recent_plan_id,
    r.recent_avg_duration,
    h.plan_id AS historical_plan_id,
    h.historical_avg_duration,
    CAST(r.recent_avg_duration / NULLIF(h.historical_avg_duration, 0) AS DECIMAL(10,2)) AS regression_factor
FROM RecentStats r
JOIN HistoricalStats h ON r.query_id = h.query_id
JOIN sys.query_store_query AS q ON r.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
WHERE r.recent_avg_duration > h.historical_avg_duration * 2  -- 2x regression
  AND r.recent_executions >= 10                                -- Minimum executions
ORDER BY regression_factor DESC;
```

---

## Top Resource Consuming Queries

### By Total CPU Time

```sql
SELECT TOP 10
    q.query_id,
    qt.query_sql_text,
    SUM(rs.avg_cpu_time * rs.count_executions) AS total_cpu_time,
    SUM(rs.count_executions) AS total_executions,
    AVG(rs.avg_cpu_time) AS avg_cpu_time,
    COUNT(DISTINCT p.plan_id) AS plan_count
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_plan AS p ON rs.plan_id = p.plan_id
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(DAY, -1, GETUTCDATE())
GROUP BY q.query_id, qt.query_sql_text
ORDER BY total_cpu_time DESC;
```

### By Total Logical Reads (I/O Pressure)

```sql
SELECT TOP 10
    q.query_id,
    qt.query_sql_text,
    SUM(rs.avg_logical_io_reads * rs.count_executions) AS total_logical_reads,
    SUM(rs.count_executions) AS total_executions,
    AVG(rs.avg_logical_io_reads) AS avg_logical_reads
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_plan AS p ON rs.plan_id = p.plan_id
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(DAY, -1, GETUTCDATE())
GROUP BY q.query_id, qt.query_sql_text
ORDER BY total_logical_reads DESC;
```

---

## Plan Comparison

Plan comparison lets you look at two execution plans for the same query side by side to understand why performance changed.

### Identifying Queries with Multiple Plans

```sql
-- Queries with the most plan variations
SELECT
    q.query_id,
    qt.query_sql_text,
    COUNT(DISTINCT p.plan_id) AS number_of_plans,
    MIN(rs.avg_duration) AS best_avg_duration,
    MAX(rs.avg_duration) AS worst_avg_duration
FROM sys.query_store_plan AS p
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_runtime_stats AS rs ON p.plan_id = rs.plan_id
GROUP BY q.query_id, qt.query_sql_text
HAVING COUNT(DISTINCT p.plan_id) > 1
ORDER BY number_of_plans DESC;
```

### Comparing Specific Plans

```sql
-- Get the two most recent plans for a query and their stats
SELECT
    p.plan_id,
    p.is_forced_plan,
    p.engine_version,
    p.compatibility_level,
    rs.avg_duration,
    rs.avg_cpu_time,
    rs.avg_logical_io_reads,
    rs.avg_rowcount,
    rs.count_executions,
    TRY_CAST(p.query_plan AS XML) AS plan_xml
FROM sys.query_store_plan AS p
JOIN sys.query_store_runtime_stats AS rs ON p.plan_id = rs.plan_id
WHERE p.query_id = 42
ORDER BY p.last_execution_time DESC;
```

In SSMS, the Query Store built-in reports provide a visual plan comparison feature that highlights differences between two plans (changed operators, different join types, missing index usage, etc.).

---

## Wait Statistics in Query Store

Available since SQL Server 2017, wait statistics in Query Store let you understand not just how long a query ran, but what it was waiting on.

### Wait Categories

Query Store groups waits into categories rather than individual wait types:

| Category | Description | Examples |
|----------|-------------|----------|
| CPU | Query actively consuming CPU | SOS_SCHEDULER_YIELD |
| Lock | Blocked by locks | LCK_M_X, LCK_M_S |
| Latch | Buffer latch contention | PAGELATCH_*, PAGEIOLATCH_* |
| Network | Waiting for client to consume results | ASYNC_NETWORK_IO |
| Parallelism | Exchange/CXPACKET waits | CXPACKET, CXCONSUMER |
| Memory | Memory grant waits | RESOURCE_SEMAPHORE |
| Buffer IO | Physical I/O waits | PAGEIOLATCH_SH |
| Log IO | Transaction log writes | WRITELOG |

### Querying Wait Stats

```sql
SELECT
    q.query_id,
    qt.query_sql_text,
    ws.wait_category_desc,
    ws.avg_query_wait_time_ms,
    ws.total_query_wait_time_ms,
    ws.execution_type_desc
FROM sys.query_store_wait_stats AS ws
JOIN sys.query_store_plan AS p ON ws.plan_id = p.plan_id
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON ws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -24, GETUTCDATE())
ORDER BY ws.total_query_wait_time_ms DESC;
```

### Finding Lock-Heavy Queries

```sql
SELECT
    q.query_id,
    qt.query_sql_text,
    SUM(ws.total_query_wait_time_ms) AS total_lock_wait_ms
FROM sys.query_store_wait_stats AS ws
JOIN sys.query_store_plan AS p ON ws.plan_id = p.plan_id
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
JOIN sys.query_store_query_text AS qt ON q.query_text_id = qt.query_text_id
WHERE ws.wait_category_desc = 'Lock'
GROUP BY q.query_id, qt.query_sql_text
ORDER BY total_lock_wait_ms DESC;
```

---

## Query Store Hints

Introduced in SQL Server 2022, Query Store hints allow you to apply query hints to queries without modifying application code. This is a major improvement over plan guides.

### Applying a Hint

```sql
-- Add a MAXDOP hint to a query
EXEC sys.sp_query_store_set_hints
    @query_id = 42,
    @query_hints = N'OPTION (MAXDOP 2)';

-- Add RECOMPILE hint
EXEC sys.sp_query_store_set_hints
    @query_id = 99,
    @query_hints = N'OPTION (RECOMPILE)';

-- Add multiple hints
EXEC sys.sp_query_store_set_hints
    @query_id = 55,
    @query_hints = N'OPTION (MAXDOP 1, OPTIMIZE FOR UNKNOWN)';

-- Remove a hint
EXEC sys.sp_query_store_clear_hints @query_id = 42;
```

### Viewing Applied Hints

```sql
SELECT
    query_hint_id,
    query_id,
    query_hint_text,
    last_query_hint_failure_reason_desc,
    source_desc
FROM sys.query_store_query_hints;
```

### Query Store Hints vs Plan Forcing vs Plan Guides

| Feature | Query Store Hints | Plan Forcing | Plan Guides |
|---------|------------------|--------------|-------------|
| Granularity | Hint-level | Entire plan | Hint or plan |
| Flexibility | High | Low (exact plan) | Medium |
| Ease of use | Simple | Simple | Complex |
| Survives schema changes | Yes | May fail | May fail |
| Version requirement | SQL Server 2022+ | SQL Server 2016+ | SQL Server 2005+ |

---

## A/B Testing with Query Store

Query Store enables you to do controlled experiments comparing execution plan performance.

### Workflow for A/B Testing

1. **Baseline**: Let Query Store capture performance metrics for the current state.
2. **Make a change**: Add an index, update statistics, change compatibility level, etc.
3. **Compare**: Use Query Store data to compare before and after.

### Example: Testing an Index Change

```sql
-- Step 1: Record the current timestamp
DECLARE @before_change DATETIME2 = SYSUTCDATETIME();

-- Step 2: Wait for your baseline period to accumulate stats...
-- (e.g., run during peak hours for representative data)

-- Step 3: Make your change
CREATE NONCLUSTERED INDEX IX_Orders_CustomerDate
ON Sales.Orders (CustomerID, OrderDate)
INCLUDE (TotalAmount);

-- Step 4: Wait for post-change data to accumulate...

-- Step 5: Compare before vs after
DECLARE @change_time DATETIME2 = '2026-03-07 14:00:00';

SELECT
    'Before' AS period,
    q.query_id,
    AVG(rs.avg_duration) AS avg_duration,
    AVG(rs.avg_cpu_time) AS avg_cpu,
    AVG(rs.avg_logical_io_reads) AS avg_reads
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan AS p ON rs.plan_id = p.plan_id
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
WHERE rsi.end_time < @change_time
  AND rsi.start_time >= DATEADD(DAY, -1, @change_time)
GROUP BY q.query_id

UNION ALL

SELECT
    'After' AS period,
    q.query_id,
    AVG(rs.avg_duration) AS avg_duration,
    AVG(rs.avg_cpu_time) AS avg_cpu,
    AVG(rs.avg_logical_io_reads) AS avg_reads
FROM sys.query_store_runtime_stats AS rs
JOIN sys.query_store_runtime_stats_interval AS rsi
    ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_plan AS p ON rs.plan_id = p.plan_id
JOIN sys.query_store_query AS q ON p.query_id = q.query_id
WHERE rsi.start_time >= @change_time
GROUP BY q.query_id
ORDER BY query_id, period;
```

---

## Cleanup Policies

### Automatic Cleanup

Query Store has two cleanup mechanisms:

1. **Time-based cleanup** (`STALE_QUERY_THRESHOLD_DAYS`): Removes data older than the threshold.
2. **Size-based cleanup** (`SIZE_BASED_CLEANUP_MODE = AUTO`): When storage approaches `MAX_STORAGE_SIZE_MB`, the oldest data is purged. Cleanup targets approximately 80% of max size.

### Manual Cleanup

```sql
-- Purge ALL Query Store data (nuclear option)
ALTER DATABASE [AdventureWorks] SET QUERY_STORE CLEAR;

-- Remove data for a specific query
EXEC sp_query_store_remove_query @query_id = 42;

-- Remove a specific plan
EXEC sp_query_store_remove_plan @plan_id = 7;

-- Reset runtime stats for a specific query (keep plans)
EXEC sp_query_store_reset_exec_stats @plan_id = 7;
```

### Monitoring Storage Usage

```sql
SELECT
    actual_state_desc,
    desired_state_desc,
    readonly_reason,
    current_storage_size_mb,
    max_storage_size_mb,
    CAST(current_storage_size_mb * 100.0 / max_storage_size_mb AS DECIMAL(5,2)) AS pct_used,
    stale_query_threshold_days,
    size_based_cleanup_mode_desc
FROM sys.database_query_store_options;
```

### What Happens When Query Store Is Full

If `SIZE_BASED_CLEANUP_MODE = AUTO`, Query Store automatically purges old data. If cleanup is OFF, Query Store switches to `READ_ONLY` mode and stops capturing new data. The `readonly_reason` column tells you why.

---

## Integrating Query Store with Performance Tuning Workflow

### Recommended Workflow

```
1. IDENTIFY   -->  Use Top Resource Consuming Queries report
                   to find expensive queries.

2. DIAGNOSE   -->  Look at plan history: did the plan change?
                   Check wait stats: is it CPU, I/O, or locks?
                   Compare plans side by side.

3. QUICK FIX  -->  Force the last known good plan to stop
                   the bleeding immediately.

4. ROOT CAUSE -->  Investigate: outdated statistics? missing
                   index? parameter sniffing? schema change?

5. PERMANENT  -->  Fix the root cause (update stats, add
                   index, rewrite query). Unforce the plan
                   once the root cause is resolved.

6. VALIDATE   -->  Use Query Store to confirm the fix by
                   comparing before/after metrics.
```

### Real-World Scenario: Upgrade Testing

Query Store is invaluable during SQL Server upgrades or compatibility level changes:

```sql
-- Before upgrade: capture baseline with current compat level
ALTER DATABASE [AdventureWorks] SET QUERY_STORE = ON;
-- Wait for representative workload...

-- After upgrade: change compat level
ALTER DATABASE [AdventureWorks] SET COMPATIBILITY_LEVEL = 160;

-- If any queries regress, force the old plan while investigating
-- Query Store plans from the old compat level are still available
```

---

## Common Interview Questions

### Q1: What is Query Store, and why was it introduced?

**A:** Query Store is a feature introduced in SQL Server 2016 that captures and retains query text, execution plans, and runtime statistics inside the user database. It was introduced to solve the problem of diagnosing plan regressions. Before Query Store, plan cache data was volatile and lost on restarts or cache evictions. Query Store persists this data on disk, allowing historical comparison and plan forcing.

### Q2: How does Query Store differ from plan cache DMVs like sys.dm_exec_cached_plans?

**A:** Plan cache DMVs show only what is currently in memory. Data is lost on restart, during memory pressure, or when plans are evicted. Query Store persists data to disk inside the database, retains historical data based on retention policy, and survives restarts. Additionally, Query Store aggregates runtime statistics per time interval, making trend analysis possible.

### Q3: What happens when Query Store reaches its maximum storage size?

**A:** If `SIZE_BASED_CLEANUP_MODE = AUTO`, Query Store purges the oldest data to make room (targeting 80% of max size). If size-based cleanup is OFF, Query Store transitions to `READ_ONLY` mode and stops capturing new data. You can check `actual_state_desc` and `readonly_reason` in `sys.database_query_store_options` to detect this.

### Q4: Explain plan forcing. When would you use it, and what are the risks?

**A:** Plan forcing tells the optimizer to use a specific execution plan for a query, identified by query_id and plan_id. You would use it as an immediate fix when a query regresses due to a plan change. Risks include: the forced plan may become invalid if schema changes (e.g., a required index is dropped), and it may not be optimal for all parameter values. Always treat plan forcing as a temporary measure and investigate the root cause.

### Q5: What is the difference between QUERY_CAPTURE_MODE = ALL, AUTO, and CUSTOM?

**A:** `ALL` captures every query (can produce a lot of data). `AUTO` lets SQL Server filter out ad-hoc queries with trivial resource consumption. `CUSTOM` (SQL Server 2019+) gives you fine-grained control with thresholds for execution count, CPU time, and staleness. For most production systems, `AUTO` is recommended; `CUSTOM` is ideal when you need precise control.

### Q6: How would you use Query Store to diagnose a sudden performance degradation?

**A:** First, check the Regressed Queries report (or write a query against `sys.query_store_runtime_stats`) to find queries with increased duration or CPU. Then examine plan history to see if a new plan was chosen. Compare the old and new plans to identify differences (e.g., scan vs seek, different join types). Force the old plan as a quick fix while investigating root cause (stale statistics, parameter sniffing, data growth).

### Q7: Can Query Store data be moved with the database?

**A:** Yes. Because Query Store data is stored inside the user database, it travels with the database during backup/restore, detach/attach, and database copy operations. This is extremely useful for reproducing production issues in test environments.

### Q8: What are Query Store hints, and how do they differ from plan guides?

**A:** Query Store hints (SQL Server 2022) let you apply query hints to a query identified by its query_id without modifying application code. Unlike plan guides, which require matching query text patterns, Query Store hints use the query_id and are much simpler to manage. They are also more resilient to schema changes than forced plans because they guide the optimizer with hints rather than dictating an exact plan shape.

### Q9: How do wait statistics in Query Store help performance tuning?

**A:** Wait statistics (SQL Server 2017+) tell you what a query is waiting on, not just how long it took. If a query has high duration but low CPU, the wait stats might reveal it is waiting on locks, I/O, or memory grants. This narrows down the investigation: lock waits suggest concurrency issues, I/O waits suggest missing indexes or insufficient memory, and memory waits suggest excessive memory grants from cardinality estimation errors.

### Q10: What is the recommended Query Store configuration for a production OLTP system?

**A:** A good starting point: `OPERATION_MODE = READ_WRITE`, `QUERY_CAPTURE_MODE = AUTO`, `MAX_STORAGE_SIZE_MB = 1024` (or higher for large workloads), `INTERVAL_LENGTH_MINUTES = 30` (balance between granularity and storage), `DATA_FLUSH_INTERVAL_SECONDS = 900`, `STALE_QUERY_THRESHOLD_DAYS = 30`, `SIZE_BASED_CLEANUP_MODE = AUTO`, `WAIT_STATS_CAPTURE_MODE = ON`. Monitor `current_storage_size_mb` regularly and adjust as needed.

---

## Tips

1. **Always enable Query Store on production databases.** Starting with SQL Server 2022, it is ON by default for new databases. There is minimal performance overhead (typically 1-3%).

2. **Monitor the actual state.** Query Store can silently switch to READ_ONLY if it runs out of space. Build an alert on `actual_state_desc <> desired_state_desc`.

3. **Use AUTO capture mode** for most workloads. ALL mode can bloat the store with one-off ad-hoc queries.

4. **Do not rely solely on plan forcing.** It is a band-aid. Always investigate and fix the root cause -- stale statistics, missing indexes, parameter sniffing, or bad query design.

5. **Leverage Query Store for upgrades.** Before changing compatibility levels or upgrading SQL Server, let Query Store build a baseline. After the change, use the Regressed Queries report to quickly find and fix regressions.

6. **Set an appropriate MAX_STORAGE_SIZE_MB.** The default of 100 MB is too small for most production systems. 1 GB to 10 GB is typical depending on workload diversity.

7. **Use shorter aggregation intervals for troubleshooting.** Temporarily set `INTERVAL_LENGTH_MINUTES = 5` or `1` during active investigations, then return to 30 or 60 for normal operations.

8. **Query Store travels with the database.** Restore a production backup to a test server and you have all the Query Store data for analysis.

9. **Combine Query Store with Extended Events** for deep-dive analysis. Query Store gives you the "what" (which queries, which plans, what performance). Extended Events gives you the "why" (specific events, parameters, locking chains).

10. **Clean up forced plans periodically.** Review all forced plans monthly. If the root cause has been fixed, unforce the plan to let the optimizer adapt to future data changes.
