# Dynamic Management Views (DMVs)

[Back to SQL Server Index](./README.md)

---

## Overview

Dynamic Management Views (DMVs) and Dynamic Management Functions (DMFs) are system views and functions introduced in SQL Server 2005 that return server state information. They provide a window into the internal workings of SQL Server, exposing data about query execution, index usage, memory, I/O, waits, and more. For a senior Data Engineer, DMVs are indispensable tools for performance tuning, troubleshooting, and capacity planning.

All DMVs reside in the `sys` schema and follow the naming convention `sys.dm_*`. They require `VIEW SERVER STATE` permission (server-scoped) or `VIEW DATABASE STATE` permission (database-scoped).

---

## Categories of DMVs

DMVs are organized into logical categories based on the subsystem they expose:

| Category | Prefix | Description |
|---|---|---|
| **Execution-related** | `sys.dm_exec_*` | Currently running queries, sessions, connections, cached plans |
| **Index-related** | `sys.dm_db_index_*` | Index usage stats, physical stats, missing indexes |
| **OS-related** | `sys.dm_os_*` | Wait stats, memory, schedulers, threads |
| **Database-related** | `sys.dm_db_*` | File space, partition stats, database mirroring |
| **Transaction-related** | `sys.dm_tran_*` | Active transactions, locks, version store |
| **I/O-related** | `sys.dm_io_*` | Pending I/O, virtual file stats |
| **CLR-related** | `sys.dm_clr_*` | CLR execution information |
| **Service Broker** | `sys.dm_broker_*` | Service Broker queue and message info |
| **Full-Text** | `sys.dm_fts_*` | Full-text indexing information |
| **Always On** | `sys.dm_hadr_*` | Availability group and replica state |

### Server-Scoped vs. Database-Scoped

- **Server-scoped DMVs** return data across the entire instance (e.g., `sys.dm_os_wait_stats`). They require `VIEW SERVER STATE`.
- **Database-scoped DMVs** return data for the current database only (e.g., `sys.dm_db_index_usage_stats`). They require `VIEW DATABASE STATE`.

> **Important:** Most DMV data is reset when SQL Server restarts. Always note the instance uptime (`sys.dm_os_sys_info`) when interpreting DMV results.

---

## Most Important DMVs for Performance Tuning

### 1. sys.dm_exec_requests

Shows every currently executing request in the SQL Server instance. This is your go-to view for "what is running right now?"

```sql
-- Currently executing queries with wait info
SELECT
    r.session_id,
    r.status,
    r.command,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    r.blocking_session_id,
    r.cpu_time,
    r.total_elapsed_time,
    r.reads,
    r.writes,
    r.logical_reads,
    DB_NAME(r.database_id) AS database_name,
    t.text AS sql_text,
    SUBSTRING(t.text,
        (r.statement_start_offset / 2) + 1,
        ((CASE r.statement_end_offset
            WHEN -1 THEN DATALENGTH(t.text)
            ELSE r.statement_end_offset
        END - r.statement_start_offset) / 2) + 1
    ) AS current_statement,
    p.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) p
WHERE r.session_id > 50  -- exclude system sessions
ORDER BY r.total_elapsed_time DESC;
```

**Key columns:**
- `blocking_session_id` -- nonzero means this request is blocked
- `wait_type` / `wait_time` -- what the request is currently waiting on
- `statement_start_offset` / `statement_end_offset` -- used to extract the exact statement from a batch

---

### 2. sys.dm_exec_sessions

Returns one row per authenticated session. Includes both active and idle sessions.

```sql
-- Active sessions with resource usage
SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    s.status,
    s.cpu_time,
    s.memory_usage,
    s.reads,
    s.writes,
    s.logical_reads,
    s.total_elapsed_time,
    s.last_request_start_time,
    s.last_request_end_time,
    DB_NAME(s.database_id) AS database_name
FROM sys.dm_exec_sessions s
WHERE s.is_user_process = 1
ORDER BY s.cpu_time DESC;
```

**Tip:** Join `sys.dm_exec_sessions` with `sys.dm_exec_requests` and `sys.dm_exec_connections` for a complete picture of who is connected, what they are running, and what they last ran.

---

### 3. sys.dm_exec_query_stats

Aggregated performance statistics for cached query plans. Each row represents a single statement within a cached plan, with cumulative metrics since the plan was cached.

```sql
-- Top 20 queries by total CPU time
SELECT TOP 20
    qs.total_worker_time / 1000 AS total_cpu_ms,
    qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.total_elapsed_time / 1000 AS total_elapsed_ms,
    qs.total_logical_reads,
    qs.total_logical_reads / qs.execution_count AS avg_logical_reads,
    qs.total_physical_reads,
    qs.creation_time,
    t.text AS sql_text,
    SUBSTRING(t.text,
        (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(t.text)
            ELSE qs.statement_end_offset
        END - qs.statement_start_offset) / 2) + 1
    ) AS individual_statement,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
ORDER BY qs.total_worker_time DESC;
```

**Key insight:** You can change the `ORDER BY` to find queries by different criteria:
- `total_worker_time` -- CPU-intensive queries
- `total_logical_reads` -- I/O-intensive queries
- `execution_count` -- Most frequently executed queries
- `total_elapsed_time` -- Longest running queries overall

---

### 4. sys.dm_os_wait_stats

Cumulative wait statistics for the entire instance since last restart (or last manual reset). This is the foundation of **wait-based performance tuning**.

```sql
-- Top waits excluding benign/idle waits
WITH WaitStats AS (
    SELECT
        wait_type,
        wait_time_ms,
        waiting_tasks_count,
        signal_wait_time_ms,
        wait_time_ms - signal_wait_time_ms AS resource_wait_time_ms,
        100.0 * wait_time_ms / SUM(wait_time_ms) OVER () AS pct,
        ROW_NUMBER() OVER (ORDER BY wait_time_ms DESC) AS rn
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        -- Filter out benign waits
        'CLR_SEMAPHORE', 'LAZYWRITER_SLEEP', 'RESOURCE_QUEUE',
        'SLEEP_TASK', 'SLEEP_SYSTEMTASK', 'SQLTRACE_BUFFER_FLUSH',
        'WAITFOR', 'LOGMGR_QUEUE', 'CHECKPOINT_QUEUE',
        'REQUEST_FOR_DEADLOCK_SEARCH', 'XE_TIMER_EVENT',
        'BROKER_TO_FLUSH', 'BROKER_TASK_STOP', 'CLR_MANUAL_EVENT',
        'CLR_AUTO_EVENT', 'DISPATCHER_QUEUE_SEMAPHORE',
        'FT_IFTS_SCHEDULER_IDLE_WAIT', 'XE_DISPATCHER_WAIT',
        'XE_DISPATCHER_JOIN', 'BROKER_EVENTHANDLER',
        'TRACEWRITE', 'FT_IFTSHC_MUTEX', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        'BROKER_RECEIVE_WAITFOR', 'ONDEMAND_TASK_QUEUE',
        'DBMIRROR_EVENTS_QUEUE', 'DBMIRRORING_CMD',
        'HADR_CLUSAPI_CALL', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'HADR_LOGCAPTURE_WAIT', 'HADR_NOTIFICATION_DEQUEUE',
        'HADR_TIMER_TASK', 'HADR_WORK_QUEUE',
        'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'SP_SERVER_DIAGNOSTICS_SLEEP'
    )
    AND waiting_tasks_count > 0
)
SELECT
    wait_type,
    CAST(wait_time_ms / 1000.0 AS DECIMAL(18,2)) AS wait_time_sec,
    waiting_tasks_count,
    CAST(resource_wait_time_ms / 1000.0 AS DECIMAL(18,2)) AS resource_wait_sec,
    CAST(signal_wait_time_ms / 1000.0 AS DECIMAL(18,2)) AS signal_wait_sec,
    CAST(pct AS DECIMAL(5,2)) AS pct
FROM WaitStats
WHERE rn <= 20
ORDER BY wait_time_ms DESC;
```

**Interpreting waits:**

| Wait Type | Indicates | Action |
|---|---|---|
| `CXPACKET` / `CXCONSUMER` | Parallelism skew | Review MAXDOP, CTFP settings, check for skewed data |
| `PAGEIOLATCH_*` | Disk I/O pressure | Add memory, improve indexes, move to faster storage |
| `SOS_SCHEDULER_YIELD` | CPU pressure | Tune expensive queries, add CPU |
| `LCK_M_*` | Lock contention | Review isolation levels, transaction length, indexing |
| `WRITELOG` | Transaction log write latency | Move log to faster disk, batch commits |
| `ASYNC_NETWORK_IO` | Client consuming results slowly | Check application, network, result set sizes |
| `PAGELATCH_*` | In-memory page contention (tempdb or last-page insert) | tempdb files, partitioning |

**Signal wait vs. resource wait:**
- **Resource wait** = time waiting for the resource (disk, lock, memory)
- **Signal wait** = time waiting for a CPU scheduler after the resource became available
- High signal waits relative to total waits indicate CPU pressure

---

### 5. sys.dm_db_index_usage_stats

Tracks how indexes are being used -- seeks, scans, lookups, and updates -- since the last SQL Server restart.

```sql
-- Unused indexes (candidates for removal)
SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc,
    ISNULL(us.user_seeks, 0) AS user_seeks,
    ISNULL(us.user_scans, 0) AS user_scans,
    ISNULL(us.user_lookups, 0) AS user_lookups,
    ISNULL(us.user_updates, 0) AS user_updates,
    ISNULL(us.last_user_seek, '1900-01-01') AS last_user_seek,
    ISNULL(us.last_user_scan, '1900-01-01') AS last_user_scan
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats us
    ON i.object_id = us.object_id
    AND i.index_id = us.index_id
    AND us.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
    AND i.index_id > 1  -- non-clustered only
    AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0) + ISNULL(us.user_lookups, 0) = 0
    AND ISNULL(us.user_updates, 0) > 0
ORDER BY us.user_updates DESC;
```

```sql
-- Most heavily used indexes
SELECT TOP 20
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    us.user_seeks + us.user_scans + us.user_lookups AS total_reads,
    us.user_updates AS total_writes,
    CAST(us.user_seeks + us.user_scans + us.user_lookups AS FLOAT) /
        NULLIF(us.user_updates, 0) AS read_to_write_ratio
FROM sys.indexes i
INNER JOIN sys.dm_db_index_usage_stats us
    ON i.object_id = us.object_id
    AND i.index_id = us.index_id
WHERE us.database_id = DB_ID()
    AND OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
ORDER BY total_reads DESC;
```

---

### 6. sys.dm_db_index_physical_stats

Returns fragmentation and page density information for indexes. This is a function, not a view, taking parameters for database, object, index, partition, and scan mode.

```sql
-- Index fragmentation report
SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) + '.' + OBJECT_NAME(ips.object_id) AS table_name,
    i.name AS index_name,
    ips.index_type_desc,
    ips.alloc_unit_type_desc,
    ips.avg_fragmentation_in_percent,
    ips.avg_page_space_used_in_percent,
    ips.page_count,
    ips.fragment_count,
    CASE
        WHEN ips.avg_fragmentation_in_percent < 5 THEN 'None'
        WHEN ips.avg_fragmentation_in_percent < 30 THEN 'REORGANIZE'
        ELSE 'REBUILD'
    END AS recommended_action
FROM sys.dm_db_index_physical_stats(
    DB_ID(),    -- current database
    NULL,       -- all tables
    NULL,       -- all indexes
    NULL,       -- all partitions
    'LIMITED'   -- scan mode: LIMITED, SAMPLED, or DETAILED
) ips
INNER JOIN sys.indexes i
    ON ips.object_id = i.object_id
    AND ips.index_id = i.index_id
WHERE ips.page_count > 1000  -- skip small indexes
    AND ips.avg_fragmentation_in_percent > 5
ORDER BY ips.avg_fragmentation_in_percent DESC;
```

**Scan modes:**
- `LIMITED` -- fastest, reads only parent-level pages; good for fragmentation checks
- `SAMPLED` -- reads 1% of pages for large indexes; provides `avg_page_space_used_in_percent`
- `DETAILED` -- reads all pages; most accurate but slowest; required for all columns

> **Warning:** Running `DETAILED` mode on large tables during production hours can cause I/O pressure. Use `LIMITED` or `SAMPLED` for routine checks.

---

### 7. sys.dm_exec_sql_text and sys.dm_exec_query_plan

These are Dynamic Management Functions (DMFs) used with `CROSS APPLY` to retrieve the SQL text and XML query plan from a handle.

```sql
-- Get SQL text from a sql_handle
SELECT t.text
FROM sys.dm_exec_sql_text(0x020000...) t;  -- pass actual sql_handle

-- Get query plan from a plan_handle
SELECT qp.query_plan
FROM sys.dm_exec_query_plan(0x060000...) qp;  -- pass actual plan_handle

-- Common pattern: combine with requests
SELECT
    r.session_id,
    t.text AS full_batch,
    qp.query_plan
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(r.plan_handle) qp
WHERE r.session_id > 50;
```

---

## Wait Statistics Analysis

Wait-based tuning is the most effective methodology for SQL Server performance tuning. The approach is straightforward:

1. **Collect wait stats** -- Query `sys.dm_os_wait_stats` to identify the top waits.
2. **Filter noise** -- Remove benign/background waits.
3. **Diagnose the category** -- Determine if the bottleneck is CPU, I/O, memory, locking, or network.
4. **Drill down** -- Use category-specific DMVs to find the root cause.
5. **Fix and validate** -- Apply the fix and compare wait profiles.

### Resetting Wait Stats for a Baseline

```sql
-- Reset wait stats (use cautiously in production)
DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);

-- Then collect after a representative workload period
```

### Per-Query Wait Stats (SQL Server 2016+)

Starting with SQL Server 2016, Query Store can capture per-query wait statistics, but you can also use `sys.dm_exec_session_wait_stats` for per-session waits:

```sql
-- Wait stats for a specific session
SELECT *
FROM sys.dm_exec_session_wait_stats
WHERE session_id = @@SPID
ORDER BY wait_time_ms DESC;
```

---

## Commonly Used Diagnostic Queries

### Missing Index Recommendations

```sql
-- Top 25 missing indexes by improvement measure
SELECT TOP 25
    DB_NAME(mid.database_id) AS database_name,
    OBJECT_SCHEMA_NAME(mid.object_id, mid.database_id) + '.' +
        OBJECT_NAME(mid.object_id, mid.database_id) AS table_name,
    migs.unique_compiles,
    migs.user_seeks,
    migs.avg_total_user_cost,
    migs.avg_user_impact,
    migs.user_seeks * migs.avg_total_user_cost * (migs.avg_user_impact / 100.0) AS improvement_measure,
    'CREATE NONCLUSTERED INDEX [IX_' +
        OBJECT_NAME(mid.object_id, mid.database_id) + '_' +
        REPLACE(REPLACE(REPLACE(ISNULL(mid.equality_columns, ''), ', ', '_'), '[', ''), ']', '') +
    '] ON ' + mid.statement +
    ' (' + ISNULL(mid.equality_columns, '') +
        CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL
            THEN ', ' ELSE '' END +
        ISNULL(mid.inequality_columns, '') +
    ')' +
    ISNULL(' INCLUDE (' + mid.included_columns + ')', '') AS create_index_statement
FROM sys.dm_db_missing_index_groups mig
INNER JOIN sys.dm_db_missing_index_group_stats migs
    ON mig.index_group_handle = migs.group_handle
INNER JOIN sys.dm_db_missing_index_details mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY improvement_measure DESC;
```

> **Caution:** Missing index DMVs are recommendations, not mandates. Always evaluate whether the suggested index is truly beneficial, check for overlapping indexes, and test in a non-production environment.

### Blocking Chain Detection

```sql
-- Find blocking chains
SELECT
    r.session_id AS blocked_session,
    r.blocking_session_id AS blocking_session,
    r.wait_type,
    r.wait_time / 1000.0 AS wait_time_sec,
    r.wait_resource,
    blocked_text.text AS blocked_sql,
    blocking_text.text AS blocking_sql
FROM sys.dm_exec_requests r
INNER JOIN sys.dm_exec_sessions s
    ON r.session_id = s.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) blocked_text
OUTER APPLY (
    SELECT t.text
    FROM sys.dm_exec_requests r2
    CROSS APPLY sys.dm_exec_sql_text(r2.sql_handle) t
    WHERE r2.session_id = r.blocking_session_id
) blocking_text(text)
WHERE r.blocking_session_id > 0
ORDER BY r.wait_time DESC;
```

### Memory Pressure Detection

```sql
-- Buffer pool usage by database
SELECT
    DB_NAME(database_id) AS database_name,
    COUNT(*) * 8 / 1024 AS buffer_pool_mb,
    SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END) * 8 / 1024 AS dirty_pages_mb
FROM sys.dm_os_buffer_descriptors
WHERE database_id > 4  -- exclude system databases
GROUP BY database_id
ORDER BY buffer_pool_mb DESC;

-- Page Life Expectancy (PLE)
SELECT
    object_name,
    counter_name,
    cntr_value AS page_life_expectancy_seconds
FROM sys.dm_os_performance_counters
WHERE counter_name = 'Page life expectancy'
    AND object_name LIKE '%Buffer Manager%';
```

### Currently Held Locks

```sql
-- Active locks with details
SELECT
    l.request_session_id,
    DB_NAME(l.resource_database_id) AS database_name,
    l.resource_type,
    l.resource_description,
    l.request_mode,
    l.request_status,
    OBJECT_NAME(p.object_id) AS object_name,
    t.text AS sql_text
FROM sys.dm_tran_locks l
LEFT JOIN sys.partitions p
    ON l.resource_associated_entity_id = p.hobt_id
    AND l.resource_type IN ('KEY', 'PAGE', 'RID')
OUTER APPLY (
    SELECT text FROM sys.dm_exec_requests r
    CROSS APPLY sys.dm_exec_sql_text(r.sql_handle)
    WHERE r.session_id = l.request_session_id
) t
WHERE l.request_session_id > 50
ORDER BY l.request_session_id, l.resource_type;
```

---

## Glenn Berry's Diagnostic Queries

Glenn Berry's **SQL Server Diagnostic Information Queries** are a well-known, community-maintained set of DMV queries that provide a comprehensive health check for any SQL Server instance. They are updated regularly for each SQL Server version.

### What They Cover

- Instance-level configuration and settings
- CPU utilization history (from `sys.dm_os_ring_buffers`)
- Database file sizes, growth settings, and VLF counts
- Wait statistics analysis
- Index usage and missing indexes
- Plan cache analysis
- Memory clerk usage
- I/O latency per database file (`sys.dm_io_virtual_file_stats`)
- Top queries by CPU, reads, duration

### How to Use Them

1. Download from [sqlserverperformance.wordpress.com](https://sqlserverperformance.wordpress.com) or Glenn Berry's GitHub.
2. Select the version-appropriate script.
3. Run section by section -- they are designed to be executed in pieces, not as one batch.
4. Compare results over time to detect regressions.

### Example: I/O Latency Per Database File

```sql
-- I/O latency per database file (inspired by Glenn Berry's queries)
SELECT
    DB_NAME(vfs.database_id) AS database_name,
    mf.physical_name,
    mf.type_desc,
    vfs.num_of_reads,
    vfs.num_of_writes,
    CAST(vfs.io_stall_read_ms / NULLIF(vfs.num_of_reads, 0) AS DECIMAL(10,2)) AS avg_read_latency_ms,
    CAST(vfs.io_stall_write_ms / NULLIF(vfs.num_of_writes, 0) AS DECIMAL(10,2)) AS avg_write_latency_ms,
    CAST(vfs.io_stall / NULLIF(vfs.num_of_reads + vfs.num_of_writes, 0) AS DECIMAL(10,2)) AS avg_total_latency_ms,
    vfs.size_on_disk_bytes / 1024 / 1024 AS size_on_disk_mb
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
INNER JOIN sys.master_files mf
    ON vfs.database_id = mf.database_id
    AND vfs.file_id = mf.file_id
ORDER BY avg_total_latency_ms DESC;
```

**Target latencies:**
- Data files: < 20 ms reads (< 10 ms ideal)
- Log files: < 5 ms writes (< 2 ms ideal)
- tempdb: < 10 ms overall

---

## Building a Monitoring Baseline with DMVs

A baseline is a snapshot of "normal" system behavior. Without it, you cannot determine whether current performance is abnormal.

### Strategy

1. **Identify key metrics** -- Wait stats, CPU, I/O latency, PLE, batch requests/sec, cache hit ratio.
2. **Create a collection table** and a scheduled job that captures DMV data at regular intervals (e.g., every 15 minutes).
3. **Collect for a representative period** -- at least one full business cycle (daily, weekly, monthly).
4. **Compute deltas** -- Most DMVs are cumulative, so you must subtract consecutive snapshots.
5. **Store and trend** -- Use the data for dashboards and alerting thresholds.

### Example: Snapshot Collection for Wait Stats

```sql
-- Baseline table
CREATE TABLE dbo.WaitStatsBaseline (
    capture_id      INT IDENTITY(1,1) PRIMARY KEY,
    capture_time    DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    wait_type       NVARCHAR(60) NOT NULL,
    wait_time_ms    BIGINT NOT NULL,
    waiting_tasks   BIGINT NOT NULL,
    signal_wait_ms  BIGINT NOT NULL
);

-- Capture procedure (run via SQL Agent every 15 minutes)
CREATE OR ALTER PROCEDURE dbo.usp_CaptureWaitStats
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.WaitStatsBaseline (wait_type, wait_time_ms, waiting_tasks, signal_wait_ms)
    SELECT
        wait_type,
        wait_time_ms,
        waiting_tasks_count,
        signal_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0;
END;
GO
```

```sql
-- Query deltas between two snapshots
WITH Snapshots AS (
    SELECT
        capture_time,
        wait_type,
        wait_time_ms,
        waiting_tasks,
        signal_wait_ms,
        DENSE_RANK() OVER (ORDER BY capture_time DESC) AS snapshot_rank
    FROM dbo.WaitStatsBaseline
)
SELECT
    curr.wait_type,
    curr.wait_time_ms - prev.wait_time_ms AS delta_wait_ms,
    curr.waiting_tasks - prev.waiting_tasks AS delta_tasks,
    curr.signal_wait_ms - prev.signal_wait_ms AS delta_signal_ms
FROM Snapshots curr
INNER JOIN Snapshots prev
    ON curr.wait_type = prev.wait_type
    AND curr.snapshot_rank = 1
    AND prev.snapshot_rank = 2
WHERE curr.wait_time_ms - prev.wait_time_ms > 0
ORDER BY delta_wait_ms DESC;
```

### Key Baseline Metrics to Track

| Metric | DMV/Source | Why |
|---|---|---|
| Top wait types (delta) | `sys.dm_os_wait_stats` | Identify bottleneck shifts |
| Batch requests/sec | `sys.dm_os_performance_counters` | Workload volume |
| CPU utilization | `sys.dm_os_ring_buffers` or `sys.dm_os_schedulers` | CPU pressure |
| Page Life Expectancy | `sys.dm_os_performance_counters` | Memory pressure |
| I/O latency per file | `sys.dm_io_virtual_file_stats` | Storage performance |
| Plan cache hit ratio | `sys.dm_os_performance_counters` | Plan reuse efficiency |
| Active sessions/requests | `sys.dm_exec_sessions` / `sys.dm_exec_requests` | Concurrency levels |

---

## Common Interview Questions and Answers

### Q1: What are DMVs and why are they important?

**A:** DMVs (Dynamic Management Views) and DMFs (Dynamic Management Functions) are system objects that expose internal SQL Server state information. They are critical for performance tuning, troubleshooting, and monitoring because they provide real-time insight into query execution, memory usage, I/O, wait statistics, index usage, and more -- all without requiring external tools or traces. Unlike legacy `DBCC` commands, DMVs return relational result sets that can be joined, filtered, and aggregated using standard T-SQL.

### Q2: How would you identify the most resource-intensive queries on a SQL Server instance?

**A:** I would query `sys.dm_exec_query_stats` joined with `sys.dm_exec_sql_text` and `sys.dm_exec_query_plan` via `CROSS APPLY`. By ordering on `total_worker_time` (CPU), `total_logical_reads` (I/O), or `total_elapsed_time` (duration), I can identify the top offenders. I would also consider the `execution_count` to find frequently executed queries where even small per-execution cost adds up. For currently running queries, I would use `sys.dm_exec_requests` instead.

### Q3: Explain the difference between signal waits and resource waits.

**A:** When a task waits, it goes through two phases. First, it waits for the **resource** to become available (e.g., a lock to be released, a disk read to complete) -- this is the resource wait. Then, once the resource is available, the task is placed in the runnable queue and waits for a CPU scheduler -- this is the signal wait. In `sys.dm_os_wait_stats`, `wait_time_ms` is the total, and `signal_wait_time_ms` is just the CPU scheduling portion. If signal waits are a high percentage (>20-25%) of total waits, it indicates CPU pressure.

### Q4: How do you find unused indexes using DMVs?

**A:** Query `sys.dm_db_index_usage_stats` joined with `sys.indexes`. Indexes where `user_seeks + user_scans + user_lookups = 0` but `user_updates > 0` are being maintained (write overhead) but never read by user queries. These are candidates for removal. However, I always verify that the instance has been running long enough to capture representative workload patterns, including end-of-month or quarterly processes.

### Q5: What is Page Life Expectancy and what does a low value indicate?

**A:** Page Life Expectancy (PLE) measures how long (in seconds) a page is expected to remain in the buffer pool without being referenced. A low or dropping PLE indicates memory pressure -- pages are being flushed from cache too quickly, forcing physical I/O. While the old rule of thumb was 300 seconds, modern servers with large buffer pools should have much higher PLE values. It is more useful to track PLE trends than compare to a fixed threshold.

### Q6: How would you use DMVs to troubleshoot a sudden performance degradation?

**A:** My approach:
1. **Check `sys.dm_exec_requests`** -- see what is running, what is blocked, what waits are occurring.
2. **Compare `sys.dm_os_wait_stats`** against the baseline to identify new or elevated wait types.
3. **Check `sys.dm_exec_query_stats`** for queries with recent `creation_time` (indicating plan recompilation, possibly a bad new plan).
4. **Check `sys.dm_io_virtual_file_stats`** for I/O latency spikes.
5. **Check `sys.dm_os_performance_counters`** for batch requests/sec, PLE, compilations/sec.
6. **Check `sys.dm_tran_locks`** and blocking chains if lock waits are high.

### Q7: What permissions are needed to query DMVs?

**A:** Server-scoped DMVs require `VIEW SERVER STATE` permission. Database-scoped DMVs require `VIEW DATABASE STATE` permission. In Azure SQL Database, some DMVs require `VIEW DATABASE STATE` within the database, and certain server-scoped DMVs are not available or have Azure-specific equivalents (e.g., `sys.dm_db_resource_stats`).

---

## Tips for Interviews and Real-World Practice

1. **Always note uptime.** DMV data is cumulative since the last SQL Server restart. Query `SELECT sqlserver_start_time FROM sys.dm_os_sys_info` before interpreting any DMV results.

2. **Filter benign waits.** When querying `sys.dm_os_wait_stats`, always exclude idle/background waits to avoid misleading results.

3. **Use CROSS APPLY, not JOIN, for DMFs.** Functions like `sys.dm_exec_sql_text()` and `sys.dm_exec_query_plan()` require `CROSS APPLY` (or `OUTER APPLY` if the handle might be NULL).

4. **Understand that `sys.dm_exec_query_stats` is volatile.** Plans can be evicted from cache at any time due to memory pressure, schema changes, or explicit `DBCC FREEPROCCACHE`. The data is not guaranteed to be complete.

5. **Prefer deltas over absolutes.** Raw cumulative numbers from DMVs are rarely useful on their own. Always compute deltas between two time points to get meaningful rates.

6. **Use `sys.dm_exec_query_plan` carefully.** Retrieving XML plans for many queries can be expensive. Limit your result set with `TOP` or `WHERE` filters first.

7. **Know the Azure differences.** In Azure SQL Database, many server-scoped DMVs are unavailable. Use `sys.dm_db_resource_stats`, `sys.dm_exec_query_stats`, and `sys.dm_db_wait_stats` instead of their on-premises counterparts.

8. **Combine DMVs for context.** A single DMV rarely tells the whole story. Join execution DMVs with session DMVs, wait DMVs with I/O DMVs, and index usage DMVs with missing index DMVs to get actionable insights.

---
