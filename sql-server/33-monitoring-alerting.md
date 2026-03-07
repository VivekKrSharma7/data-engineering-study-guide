# Monitoring & Alerting

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Overview](#overview)
2. [Extended Events (XEvents) Architecture](#extended-events-xevents-architecture)
3. [Creating XEvent Sessions](#creating-xevent-sessions)
4. [Common XEvent Targets](#common-xevent-targets)
5. [XEvents vs SQL Trace and Profiler](#xevents-vs-sql-trace-and-profiler)
6. [Performance Counters](#performance-counters)
7. [Data Collector and Management Data Warehouse](#data-collector-and-management-data-warehouse)
8. [Third-Party Monitoring Tools](#third-party-monitoring-tools)
9. [Baseline Creation](#baseline-creation)
10. [Wait Statistics Monitoring](#wait-statistics-monitoring)
11. [System Health Session](#system-health-session)
12. [sp_server_diagnostics](#sp_server_diagnostics)
13. [Common Interview Questions](#common-interview-questions)
14. [Tips](#tips)

---

## Overview

Monitoring and alerting are critical responsibilities for any Data Engineer or DBA working with SQL Server. Effective monitoring means knowing the normal behavior of your system (baseline) and detecting deviations before they become outages. This topic covers the built-in tools SQL Server provides for monitoring, diagnostics, and proactive alerting.

Key monitoring areas:

- **Query performance** -- identifying slow, resource-intensive, or frequently executed queries
- **Wait statistics** -- understanding what SQL Server is waiting on (CPU, I/O, locks, memory)
- **Resource utilization** -- CPU, memory, disk I/O, network
- **Blocking and deadlocks** -- detecting and resolving concurrency issues
- **System health** -- overall server status, errors, connectivity issues
- **Storage** -- database growth, file utilization, tempdb contention

---

## Extended Events (XEvents) Architecture

Extended Events is SQL Server's lightweight, highly scalable event-handling framework. Introduced in SQL Server 2008, it has been the recommended tracing and diagnostics platform since SQL Server 2012, fully replacing SQL Trace and Profiler for all new work.

### Architecture Components

```
Extended Events Architecture:

+-----------------------------------------------------------+
|  Extended Events Engine                                    |
|                                                            |
|  +--------+     +-----------+     +--------+     +------+ |
|  | Events  | --> | Predicates| --> | Actions| --> |Targets| |
|  +--------+     +-----------+     +--------+     +------+ |
|                                                            |
|  Events: "Something happened" (e.g., query completed)     |
|  Predicates: Filters (e.g., duration > 1 second)          |
|  Actions: Additional data to collect when event fires      |
|  Targets: Where to store/display the event data            |
+-----------------------------------------------------------+
```

### Key Concepts

| Component | Description |
|-----------|-------------|
| **Package** | A container for XEvent objects. SQL Server has several built-in packages (`sqlserver`, `sqlos`, `package0`). |
| **Event** | A defined point of interest in the code. When execution reaches that point, the event fires. Examples: `sql_statement_completed`, `rpc_completed`, `lock_deadlock`. |
| **Predicate** | A filter applied to an event. Only events matching the predicate are processed. This is key for low overhead. |
| **Action** | Additional data collected when an event fires and passes the predicate. Examples: `sql_text`, `session_id`, `database_name`, `query_hash`, `query_plan_hash`. |
| **Target** | A consumer of event data. Targets store, aggregate, or display event information. |
| **Session** | A configuration unit that binds events, predicates, actions, and targets together. Sessions can be started/stopped independently. |
| **Map** | A lookup table mapping internal integer values to human-readable strings (e.g., wait type IDs to names). |
| **Type** | Defines the data type for event columns and action outputs. |
| **Channel** | Categorizes events by intended audience: Admin, Operational, Analytic, Debug. |

### Discovering Available Events and Actions

```sql
-- List all available events
SELECT p.name AS package_name,
       o.name AS event_name,
       o.description
FROM sys.dm_xe_objects o
JOIN sys.dm_xe_packages p ON o.package_guid = p.guid
WHERE o.object_type = 'event'
ORDER BY p.name, o.name;

-- List all available actions
SELECT p.name AS package_name,
       o.name AS action_name,
       o.description
FROM sys.dm_xe_objects o
JOIN sys.dm_xe_packages p ON o.package_guid = p.guid
WHERE o.object_type = 'action'
ORDER BY p.name, o.name;

-- List all available targets
SELECT p.name AS package_name,
       o.name AS target_name,
       o.description
FROM sys.dm_xe_objects o
JOIN sys.dm_xe_packages p ON o.package_guid = p.guid
WHERE o.object_type = 'target'
ORDER BY p.name, o.name;

-- Get columns (payload) for a specific event
SELECT c.name AS column_name,
       c.type_name,
       c.column_type,   -- readonly = event data, customizable = predicate/action
       c.description
FROM sys.dm_xe_object_columns c
WHERE c.object_name = 'sql_statement_completed'
  AND c.column_type <> 'readonly'
ORDER BY c.name;
```

---

## Creating XEvent Sessions

### Basic Session: Capture Long-Running Queries

```sql
-- Create a session to capture queries running longer than 5 seconds
CREATE EVENT SESSION [LongRunningQueries] ON SERVER
ADD EVENT sqlserver.sql_statement_completed (
    SET collect_statement = (1)
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.username,
        sqlserver.client_hostname,
        sqlserver.client_app_name,
        sqlserver.query_hash,
        sqlserver.plan_handle
    )
    WHERE (
        duration > 5000000  -- duration is in microseconds: 5,000,000 = 5 seconds
        AND sqlserver.is_system = 0  -- exclude system sessions
    )
),
ADD EVENT sqlserver.rpc_completed (
    SET collect_statement = (1)
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.username,
        sqlserver.client_hostname,
        sqlserver.client_app_name,
        sqlserver.query_hash,
        sqlserver.plan_handle
    )
    WHERE (
        duration > 5000000
        AND sqlserver.is_system = 0
    )
)
ADD TARGET package0.event_file (
    SET filename = N'C:\XEvents\LongRunningQueries.xel',
        max_file_size = (100),         -- MB per file
        max_rollover_files = (10)      -- keep 10 files, then roll over
)
WITH (
    MAX_MEMORY = 4096 KB,              -- memory buffer for events
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,  -- allow dropping events under pressure
    MAX_DISPATCH_LATENCY = 30 SECONDS, -- flush to target every 30 seconds
    STARTUP_STATE = ON                 -- auto-start when SQL Server starts
);
GO

-- Start the session
ALTER EVENT SESSION [LongRunningQueries] ON SERVER STATE = START;
GO
```

### Session: Capture Deadlocks

```sql
CREATE EVENT SESSION [DeadlockMonitor] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report (
    ACTION (
        sqlserver.database_name,
        sqlserver.session_id
    )
)
ADD TARGET package0.event_file (
    SET filename = N'C:\XEvents\Deadlocks.xel',
        max_file_size = (50),
        max_rollover_files = (5)
)
WITH (
    MAX_MEMORY = 2048 KB,
    EVENT_RETENTION_MODE = NO_EVENT_LOSS,  -- deadlocks are critical; do not lose
    MAX_DISPATCH_LATENCY = 10 SECONDS,
    STARTUP_STATE = ON
);
GO

ALTER EVENT SESSION [DeadlockMonitor] ON SERVER STATE = START;
GO
```

### Session: Monitor Blocking

```sql
CREATE EVENT SESSION [BlockingMonitor] ON SERVER
ADD EVENT sqlserver.blocked_process_report (
    ACTION (
        sqlserver.database_name,
        sqlserver.session_id
    )
)
ADD TARGET package0.event_file (
    SET filename = N'C:\XEvents\Blocking.xel',
        max_file_size = (100),
        max_rollover_files = (5)
)
WITH (
    MAX_MEMORY = 4096 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 15 SECONDS,
    STARTUP_STATE = ON
);
GO

-- IMPORTANT: You must also configure the blocked process threshold
-- This defines how many seconds a process must be blocked before the event fires
EXEC sp_configure 'blocked process threshold (s)', 10;
RECONFIGURE;

ALTER EVENT SESSION [BlockingMonitor] ON SERVER STATE = START;
GO
```

### Reading XEvent Data

```sql
-- Read from an event file target
SELECT
    event_data_xml.value('(event/@name)[1]', 'NVARCHAR(100)') AS event_name,
    event_data_xml.value('(event/@timestamp)[1]', 'DATETIME2') AS event_time,
    event_data_xml.value('(event/data[@name="duration"]/value)[1]', 'BIGINT') / 1000000.0 AS duration_seconds,
    event_data_xml.value('(event/data[@name="cpu_time"]/value)[1]', 'BIGINT') / 1000000.0 AS cpu_seconds,
    event_data_xml.value('(event/data[@name="logical_reads"]/value)[1]', 'BIGINT') AS logical_reads,
    event_data_xml.value('(event/data[@name="physical_reads"]/value)[1]', 'BIGINT') AS physical_reads,
    event_data_xml.value('(event/data[@name="row_count"]/value)[1]', 'BIGINT') AS row_count,
    event_data_xml.value('(event/action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text,
    event_data_xml.value('(event/action[@name="database_name"]/value)[1]', 'NVARCHAR(128)') AS database_name,
    event_data_xml.value('(event/action[@name="username"]/value)[1]', 'NVARCHAR(128)') AS username,
    event_data_xml.value('(event/action[@name="session_id"]/value)[1]', 'INT') AS session_id
FROM (
    SELECT CAST(event_data AS XML) AS event_data_xml
    FROM sys.fn_xe_file_target_read_file(
        'C:\XEvents\LongRunningQueries*.xel',
        NULL, NULL, NULL
    )
) AS xevents
ORDER BY event_time DESC;

-- Read from a ring_buffer target (in-memory)
SELECT
    xed.event_data.value('(@name)[1]', 'NVARCHAR(256)') AS event_name,
    xed.event_data.value('(@timestamp)[1]', 'DATETIME2') AS event_time,
    xed.event_data.value('(data[@name="duration"]/value)[1]', 'BIGINT') AS duration_us,
    xed.event_data.value('(action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text
FROM (
    SELECT CAST(target_data AS XML) AS target_xml
    FROM sys.dm_xe_session_targets t
    JOIN sys.dm_xe_sessions s ON t.event_session_address = s.address
    WHERE s.name = 'LongRunningQueries'
      AND t.target_name = 'ring_buffer'
) AS session_data
CROSS APPLY target_xml.nodes('RingBufferTarget/event') AS xed(event_data);
```

### Managing Sessions

```sql
-- Stop a session
ALTER EVENT SESSION [LongRunningQueries] ON SERVER STATE = STOP;

-- Drop a session
DROP EVENT SESSION [LongRunningQueries] ON SERVER;

-- View all active sessions
SELECT name, create_time, total_regular_buffers, total_buffer_size,
       dropped_event_count, blocked_event_fire_time
FROM sys.dm_xe_sessions;

-- View session events and targets configuration
SELECT es.name AS session_name,
       ese.event_name,
       est.target_name
FROM sys.server_event_sessions es
JOIN sys.server_event_session_events ese ON es.event_session_id = ese.event_session_id
JOIN sys.server_event_session_targets est ON es.event_session_id = est.event_session_id;
```

---

## Common XEvent Targets

### ring_buffer

An in-memory circular buffer that holds events. When full, oldest events are overwritten.

| Property | Detail |
|----------|--------|
| Storage | In-memory (RAM) |
| Persistence | Lost on session stop or server restart |
| Max size | Configurable (`max_memory` on session), default ~4MB |
| Use case | Quick ad-hoc diagnostics, short-term troubleshooting |
| Query method | `sys.dm_xe_session_targets` + XML parsing |

```sql
ADD TARGET package0.ring_buffer (
    SET max_memory = (4096)   -- 4 MB
)
```

**Advantages:** No disk I/O overhead, instant access, great for real-time troubleshooting.
**Disadvantages:** Data is volatile, limited size, XML parsing can be heavy on large buffers.

### event_file

Writes events to `.xel` files on disk with automatic rollover.

| Property | Detail |
|----------|--------|
| Storage | Disk (`.xel` files) |
| Persistence | Survives session stop and server restart |
| Max size | Configurable per file and number of rollover files |
| Use case | Long-term monitoring, audit trails, production diagnostics |
| Query method | `sys.fn_xe_file_target_read_file()` |

```sql
ADD TARGET package0.event_file (
    SET filename = N'C:\XEvents\MySession.xel',
        max_file_size = (100),       -- 100 MB per file
        max_rollover_files = (10)    -- 10 files max (1 GB total)
)
```

**Advantages:** Persistent, large capacity, efficient asynchronous writes.
**Disadvantages:** Requires disk space, slightly higher latency than ring_buffer.

### histogram

Aggregates events into buckets, counting occurrences by a grouping column. Does not store individual events.

| Property | Detail |
|----------|--------|
| Storage | In-memory |
| Persistence | Lost on session stop |
| Use case | Counting event frequency, finding hot spots (most executed queries, most waited-on wait types) |
| Query method | `sys.dm_xe_session_targets` + XML parsing |

```sql
-- Count queries by database_name
ADD TARGET package0.histogram (
    SET filtering_event_name = N'sqlserver.sql_statement_completed',
        source_type = (1),           -- 0 = event column, 1 = action
        source = N'database_name'    -- group by this action
)
```

**Advantages:** Very low overhead, summarized data, great for identifying patterns.
**Disadvantages:** No individual event detail, in-memory only.

### Other Targets

| Target | Description |
|--------|-------------|
| `package0.event_counter` | Counts events (no detail) -- useful for measuring event frequency |
| `package0.pair_matching` | Matches begin/end event pairs to find orphaned events (e.g., sessions that started but never ended) |
| `package0.etw_classic_sync_target` | Sends events to Event Tracing for Windows (ETW) for correlation with OS events |

---

## XEvents vs SQL Trace and Profiler

### SQL Trace / Profiler (Deprecated)

SQL Trace is the server-side trace infrastructure; SQL Server Profiler is the GUI client that reads SQL Trace data. Both have been **deprecated since SQL Server 2012** and will be removed in a future version.

### Comparison

| Aspect | SQL Trace / Profiler | Extended Events |
|--------|---------------------|-----------------|
| Status | **Deprecated** | Current, actively developed |
| Overhead | High (significant performance impact) | Very low (lightweight, in-process) |
| Filtering | Server-side filters, but still captures more than needed | Predicate-based filtering at event source (minimal data captured) |
| Scalability | Poor under load | Designed for high-throughput production |
| Events available | ~180 trace events | 1000+ events (growing with each version) |
| Targets | Trace file, table, Profiler GUI | ring_buffer, event_file, histogram, ETW, pair_matching, etc. |
| Integration | Standalone | Integrated with SSMS (XEvent Profiler, Session Viewer) |
| Programmability | `sp_trace_create`, `sp_trace_setevent` | DDL (`CREATE EVENT SESSION`), DMVs |
| Platform | Being removed | Only option going forward |

### Migration Guidance

```sql
-- Common Profiler-to-XEvents equivalents:

-- Profiler: SP:StmtCompleted
-- XEvents:  sqlserver.sp_statement_completed

-- Profiler: SQL:StmtCompleted
-- XEvents:  sqlserver.sql_statement_completed

-- Profiler: RPC:Completed
-- XEvents:  sqlserver.rpc_completed

-- Profiler: Deadlock Graph
-- XEvents:  sqlserver.xml_deadlock_report

-- Profiler: Showplan XML
-- XEvents:  sqlserver.query_post_execution_showplan (CAUTION: high overhead)

-- Profiler: Audit Login / Logout
-- XEvents:  sqlserver.login / sqlserver.logout

-- SSMS includes an "XEvent Profiler" (SSMS 17.3+) that provides
-- Profiler-like live streaming using XEvents under the hood.
-- Two built-in sessions: "Standard" and "TSQL" -- use these instead of Profiler.
```

---

## Performance Counters

Performance counters (PerfMon / Windows Performance Monitor) provide system and SQL Server-specific metrics. They are essential for baselining and monitoring.

### Critical SQL Server Performance Counters

#### Buffer Manager

| Counter | What It Tells You | Healthy Value |
|---------|-------------------|---------------|
| `Buffer cache hit ratio` | Percentage of pages found in buffer pool without disk read | > 99% for OLTP |
| `Page life expectancy (PLE)` | Seconds a page stays in buffer pool before eviction | > 300 (rule of thumb); scale with RAM |
| `Checkpoint pages/sec` | Pages flushed to disk by checkpoint | Should be steady, not spiky |
| `Lazy writes/sec` | Pages written to disk by lazy writer (memory pressure) | Should be near 0; sustained > 0 indicates memory pressure |
| `Free pages` | Pages available in buffer pool | Should not be near 0 |

#### SQL Statistics

| Counter | What It Tells You | Healthy Value |
|---------|-------------------|---------------|
| `Batch Requests/sec` | Workload volume (batches submitted per second) | Baseline-dependent |
| `SQL Compilations/sec` | Rate of query compilations | Should be low relative to Batch Requests |
| `SQL Re-Compilations/sec` | Rate of plan recompilations | Should be very low |

#### General Statistics

| Counter | What It Tells You | Healthy Value |
|---------|-------------------|---------------|
| `User Connections` | Current number of connected users | Baseline-dependent |
| `Processes blocked` | Number of currently blocked processes | 0 ideally |

#### Locks

| Counter | What It Tells You | Healthy Value |
|---------|-------------------|---------------|
| `Lock Waits/sec` | Lock requests that required the caller to wait | Should be low |
| `Lock Wait Time (ms)` | Total wait time for locks | Should be low |
| `Number of Deadlocks/sec` | Deadlock rate | 0 ideally |
| `Lock Timeouts/sec` | Lock requests that timed out | 0 ideally |

#### Memory Manager

| Counter | What It Tells You | Healthy Value |
|---------|-------------------|---------------|
| `Memory Grants Pending` | Queries waiting for memory grant | 0 (any > 0 means memory pressure) |
| `Total Server Memory (KB)` | Current memory usage | Should stabilize; compare with Target |
| `Target Server Memory (KB)` | Memory SQL Server wants | Should equal or exceed Total |

#### Access Methods

| Counter | What It Tells You | Healthy Value |
|---------|-------------------|---------------|
| `Full Scans/sec` | Full table/index scans per second | Should be low; high indicates missing indexes |
| `Page Splits/sec` | Page splits due to insert/update operations | High values suggest fill factor or fragmentation issues |
| `Index Searches/sec` | Index seek operations per second | Higher is better (efficient index usage) |

#### OS-Level Counters

| Counter | Object | Healthy Value |
|---------|--------|---------------|
| `% Processor Time` | Processor | < 80% sustained |
| `Available MBytes` | Memory | > 500 MB free for OS |
| `Disk sec/Read` | PhysicalDisk | < 10ms for OLTP |
| `Disk sec/Write` | PhysicalDisk | < 10ms for OLTP |
| `Disk Queue Length` | PhysicalDisk | < 2 per disk |
| `Network Bytes Total/sec` | Network Interface | Below link capacity |

### Querying Performance Counters via T-SQL

```sql
-- SQL Server exposes PerfMon counters through a DMV:
SELECT
    object_name,
    counter_name,
    instance_name,
    cntr_value,
    cntr_type
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Buffer Manager%'
   OR object_name LIKE '%SQL Statistics%'
   OR object_name LIKE '%Memory Manager%'
ORDER BY object_name, counter_name;

-- Page Life Expectancy
SELECT cntr_value AS page_life_expectancy_seconds
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Buffer Manager%'
  AND counter_name = 'Page life expectancy';

-- Batch Requests/sec (this is a cumulative counter; take two snapshots to get rate)
SELECT cntr_value AS batch_requests_total
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%SQL Statistics%'
  AND counter_name = 'Batch Requests/sec';

-- Memory Grants Pending (any non-zero value is a red flag)
SELECT cntr_value AS memory_grants_pending
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Memory Manager%'
  AND counter_name = 'Memory Grants Pending';
```

---

## Data Collector and Management Data Warehouse

### Data Collector

The Data Collector is a built-in SQL Server component that collects performance data on a scheduled basis and stores it in a central Management Data Warehouse (MDW).

**Built-in Collection Sets:**

| Collection Set | Data Collected | Default Schedule |
|----------------|---------------|-----------------|
| Disk Usage | Database file sizes, disk space | Every 6 hours (upload every 6 hours) |
| Query Statistics | Top queries by CPU, duration, I/O (from Query Store / DMVs) | Every 15 minutes |
| Server Activity | Wait stats, PerfMon counters, DMV snapshots | Every 15 seconds (upload every 15 minutes) |

### Management Data Warehouse (MDW)

The MDW is a SQL Server database that stores the collected data and provides built-in SSRS reports for analysis.

```sql
-- Set up the Management Data Warehouse:
-- 1. In SSMS: Management -> Data Collection -> right-click -> Configure Management Data Warehouse
-- 2. Select or create a database for MDW
-- 3. Enable collection sets

-- MDW provides built-in reports accessible via SSMS:
-- - Server Activity History
-- - Disk Usage Summary
-- - Query Statistics History
-- These reports show trends over time for capacity planning and troubleshooting

-- Alternatively, query the MDW database directly:
-- Key tables/views include:
--   snapshots.query_stats
--   snapshots.os_wait_stats
--   snapshots.performance_counters
--   snapshots.disk_usage
```

### Limitations

- The Data Collector has limited customization and can have performance overhead on busy systems.
- Many organizations prefer third-party tools or custom collection solutions.
- The MDW reports are useful but basic; custom reporting often needed.

---

## Third-Party Monitoring Tools

Understanding the monitoring landscape is valuable in interviews, even if your experience is with specific tools.

### Common Third-Party Tools

| Tool | Vendor | Key Features |
|------|--------|-------------|
| SolarWinds Database Performance Analyzer (DPA) | SolarWinds | Wait-based analysis, query-level drill-down, cross-platform |
| SentryOne / SQL Sentry | SolarWinds | Real-time dashboards, advisory conditions, query plan analysis |
| Redgate SQL Monitor | Redgate | Web-based dashboard, alerting, global overview across instances |
| Idera SQL Diagnostic Manager | Idera | Real-time monitoring, predictive alerting, query analysis |
| Quest Foglight | Quest | Cross-platform, virtualization-aware, workload analysis |
| Datadog | Datadog | Cloud-native, integrates SQL Server with full-stack observability |
| Prometheus + Grafana | Open source | Custom exporters (sql_exporter), flexible dashboards, alerting |
| Azure Monitor + SQL Insights | Microsoft | Cloud-native for Azure SQL, on-prem via Azure Arc |

### What to Know for Interviews

- You do not need deep expertise in every tool, but understand the **concepts they all share**: baseline comparison, wait-based analysis, query-level performance tracking, alerting thresholds, and historical trending.
- Know the **native SQL Server tools** thoroughly (XEvents, DMVs, PerfMon, Query Store) because these underpin what all third-party tools use.
- Be prepared to discuss how you would build a **basic monitoring solution** using only native tools if no third-party tool is available.

---

## Baseline Creation

A baseline is a documented snapshot of normal system performance against which you compare current metrics. Without a baseline, you cannot determine if a metric is "good" or "bad."

### What to Baseline

| Category | Key Metrics |
|----------|-------------|
| CPU | Average and peak CPU utilization by hour/day |
| Memory | Buffer cache hit ratio, PLE, memory grants pending |
| Disk I/O | Reads/writes per second, latency per database file |
| Waits | Top 10 wait types and their average wait time |
| Queries | Top 20 queries by CPU, duration, reads (from Query Store) |
| Throughput | Batch requests/sec, transactions/sec |
| Connections | User connection count by hour |
| tempdb | tempdb file usage, version store size, contention events |
| Database sizes | Database and log file growth rate |

### Baseline Collection Script

```sql
-- Snapshot wait statistics (run periodically, e.g., every 15 minutes)
-- Compare snapshots to calculate per-interval wait times

-- Step 1: Create a baseline table
CREATE TABLE dbo.Baseline_WaitStats (
    CaptureTime         DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    WaitType            NVARCHAR(120) NOT NULL,
    WaitingTasksCount   BIGINT NOT NULL,
    WaitTimeMs          BIGINT NOT NULL,
    SignalWaitTimeMs    BIGINT NOT NULL
);

-- Step 2: Capture snapshot (scheduled via SQL Agent)
INSERT INTO dbo.Baseline_WaitStats (WaitType, WaitingTasksCount, WaitTimeMs, SignalWaitTimeMs)
SELECT
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    -- Exclude benign/idle waits
    'SLEEP_TASK', 'BROKER_TASK_STOP', 'BROKER_EVENTHANDLER',
    'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'LAZYWRITER_SLEEP',
    'RESOURCE_QUEUE', 'SQLTRACE_BUFFER_FLUSH', 'WAITFOR',
    'XE_TIMER_EVENT', 'XE_DISPATCHER_WAIT', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
    'LOGMGR_QUEUE', 'CHECKPOINT_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'DIRTY_PAGE_POLL',
    'BROKER_TO_FLUSH', 'SP_SERVER_DIAGNOSTICS_SLEEP',
    'DISPATCHER_QUEUE_SEMAPHORE', 'ONDEMAND_TASK_QUEUE',
    'PREEMPTIVE_OS_AUTHENTICATIONOPS', 'BROKER_RECEIVE_WAITFOR'
)
AND waiting_tasks_count > 0;

-- Step 3: Calculate delta between two snapshots
-- (Use LAG or self-join on consecutive capture times)

-- Baseline for PerfMon counters
CREATE TABLE dbo.Baseline_PerfCounters (
    CaptureTime   DATETIME2 NOT NULL DEFAULT SYSDATETIME(),
    ObjectName    NVARCHAR(128),
    CounterName   NVARCHAR(128),
    InstanceName  NVARCHAR(128),
    CounterValue  BIGINT
);

INSERT INTO dbo.Baseline_PerfCounters (ObjectName, CounterName, InstanceName, CounterValue)
SELECT
    RTRIM(object_name),
    RTRIM(counter_name),
    RTRIM(instance_name),
    cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN (
    'Page life expectancy',
    'Batch Requests/sec',
    'SQL Compilations/sec',
    'SQL Re-Compilations/sec',
    'Memory Grants Pending',
    'Buffer cache hit ratio',
    'User Connections',
    'Processes blocked',
    'Lock Waits/sec',
    'Full Scans/sec'
);
```

### Baseline Best Practices

1. **Collect over a representative period** -- at minimum one full business cycle (week or month).
2. **Capture at regular intervals** -- every 15 minutes is common.
3. **Include peak and off-peak** -- performance during month-end close differs from a quiet Sunday.
4. **Re-baseline after major changes** -- hardware upgrades, application releases, schema changes.
5. **Automate collection and alerting** -- trigger alerts when metrics deviate beyond a threshold (e.g., PLE drops below 50% of baseline, CPU exceeds 90% for 5+ minutes).

---

## Wait Statistics Monitoring

Wait statistics are the single most important diagnostic tool in SQL Server. Every thread that cannot proceed is assigned a wait type. Analyzing accumulated waits tells you what SQL Server spends its time waiting on.

### Core Concept

When a SQL Server worker thread needs a resource that is not immediately available, it waits. The wait is categorized by type and the duration is accumulated. By analyzing the top waits, you identify the primary bottleneck.

### Key Wait Types and Their Meaning

| Wait Type | Category | Indicates |
|-----------|----------|-----------|
| `CXPACKET` / `CXCONSUMER` | Parallelism | Parallel query execution; excessive waits may indicate bad plans or MAXDOP issues |
| `PAGEIOLATCH_SH/EX` | Disk I/O | Reading data pages from disk; possible memory pressure or slow I/O subsystem |
| `WRITELOG` | Log I/O | Transaction log writes; slow log disk or excessive logging |
| `LCK_M_*` | Locking | Lock contention; blocking queries, poor transaction design |
| `ASYNC_NETWORK_IO` | Network/Client | SQL Server waiting for client to consume results; slow client or large result sets |
| `SOS_SCHEDULER_YIELD` | CPU | CPU pressure; threads yielding after 4ms quantum |
| `RESOURCE_SEMAPHORE` | Memory | Waiting for memory grant; memory pressure, large sorts/hashes |
| `LATCH_EX/SH` | Internal | Internal synchronization; often tempdb contention on allocation pages |
| `PAGELATCH_EX/SH` | Buffer Latch | In-memory page access contention; tempdb contention, hot pages |
| `IO_COMPLETION` | Disk I/O | Non-data-page I/O operations (e.g., sort spills to tempdb) |
| `THREADPOOL` | Thread Pool | No available worker threads; very serious -- indicates thread starvation |
| `HADR_SYNC_COMMIT` | Availability Groups | Synchronous commit to AG replica; network/replica latency |

### Querying Wait Statistics

```sql
-- Current accumulated wait statistics (since last restart or DBCC SQLPERF clear)
-- This is the "gold standard" query for wait analysis

WITH WaitStats AS (
    SELECT
        wait_type,
        waiting_tasks_count,
        wait_time_ms,
        signal_wait_time_ms,
        wait_time_ms - signal_wait_time_ms AS resource_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN (
        -- Exclude benign/background waits (use Paul Randal's exclusion list)
        'SLEEP_TASK', 'BROKER_TASK_STOP', 'BROKER_EVENTHANDLER',
        'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'LAZYWRITER_SLEEP',
        'RESOURCE_QUEUE', 'SQLTRACE_BUFFER_FLUSH', 'WAITFOR',
        'XE_TIMER_EVENT', 'XE_DISPATCHER_WAIT', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
        'LOGMGR_QUEUE', 'CHECKPOINT_QUEUE', 'REQUEST_FOR_DEADLOCK_SEARCH',
        'DIRTY_PAGE_POLL', 'BROKER_TO_FLUSH', 'SP_SERVER_DIAGNOSTICS_SLEEP',
        'DISPATCHER_QUEUE_SEMAPHORE', 'ONDEMAND_TASK_QUEUE',
        'BROKER_RECEIVE_WAITFOR', 'PREEMPTIVE_XE_GETTARGETSTATE',
        'PWAIT_ALL_COMPONENTS_INITIALIZED', 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        'QDS_ASYNC_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'PREEMPTIVE_OS_AUTHENTICATIONOPS'
    )
    AND waiting_tasks_count > 0
)
SELECT TOP 20
    wait_type,
    waiting_tasks_count,
    CAST(wait_time_ms / 1000.0 AS DECIMAL(18,2)) AS wait_time_seconds,
    CAST(resource_wait_time_ms / 1000.0 AS DECIMAL(18,2)) AS resource_wait_seconds,
    CAST(signal_wait_time_ms / 1000.0 AS DECIMAL(18,2)) AS signal_wait_seconds,
    CAST(100.0 * wait_time_ms / NULLIF(SUM(wait_time_ms) OVER(), 0)
         AS DECIMAL(5,2)) AS pct_of_total_waits,
    CAST(wait_time_ms / NULLIF(waiting_tasks_count, 0) AS DECIMAL(18,2)) AS avg_wait_ms
FROM WaitStats
ORDER BY wait_time_ms DESC;

-- Reset wait statistics (use with caution; only for fresh measurement window)
DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);
```

### Per-Query Wait Statistics (SQL Server 2016+)

```sql
-- Query Store captures per-query wait statistics (SQL 2017+)
-- Or use sys.dm_exec_session_wait_stats for session-level waits

SELECT
    session_id,
    wait_type,
    waiting_tasks_count,
    wait_time_ms,
    signal_wait_time_ms
FROM sys.dm_exec_session_wait_stats
WHERE session_id = @@SPID  -- current session, or specify another
ORDER BY wait_time_ms DESC;
```

---

## System Health Session

The `system_health` session is a default Extended Events session that starts automatically with SQL Server. It captures critical diagnostic events with minimal overhead.

### What It Captures

| Event / Data | Description |
|--------------|-------------|
| `sp_server_diagnostics` output | Component health snapshots |
| Errors with severity >= 20 | Critical errors |
| Deadlocks (`xml_deadlock_report`) | Full deadlock graphs |
| Sessions waiting > 15 seconds | Long waits |
| Memory broker events | Memory pressure events |
| Scheduler health | Non-yielding schedulers, scheduler monitor events |
| System errors | Access violations, out-of-memory conditions |
| Buffer pool activity | Large memory changes |
| `wait_info` events for specific waits | Certain significant waits exceeding thresholds |

### Querying the System Health Session

```sql
-- The system_health session writes to both ring_buffer and event_file targets

-- Read deadlocks from system_health ring buffer
SELECT
    xed.value('@timestamp', 'DATETIME2') AS deadlock_time,
    xed.query('.') AS deadlock_graph
FROM (
    SELECT CAST(target_data AS XML) AS target_xml
    FROM sys.dm_xe_session_targets t
    JOIN sys.dm_xe_sessions s ON t.event_session_address = s.address
    WHERE s.name = 'system_health'
      AND t.target_name = 'ring_buffer'
) AS ring
CROSS APPLY target_xml.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS xevents(xed);

-- Read from system_health event files (more reliable for historical data)
SELECT
    CAST(event_data AS XML).value('(event/@timestamp)[1]', 'DATETIME2') AS event_time,
    CAST(event_data AS XML).value('(event/@name)[1]', 'NVARCHAR(256)') AS event_name,
    CAST(event_data AS XML) AS event_xml
FROM sys.fn_xe_file_target_read_file(
    'system_health*.xel',
    NULL, NULL, NULL
)
WHERE CAST(event_data AS XML).value('(event/@name)[1]', 'NVARCHAR(256)') = 'xml_deadlock_report'
ORDER BY event_time DESC;

-- Check system_health for error events (severity >= 20)
SELECT
    CAST(event_data AS XML).value('(event/@timestamp)[1]', 'DATETIME2') AS error_time,
    CAST(event_data AS XML).value('(event/data[@name="error_number"]/value)[1]', 'INT') AS error_number,
    CAST(event_data AS XML).value('(event/data[@name="severity"]/value)[1]', 'INT') AS severity,
    CAST(event_data AS XML).value('(event/data[@name="message"]/value)[1]', 'NVARCHAR(MAX)') AS error_message
FROM sys.fn_xe_file_target_read_file(
    'system_health*.xel',
    NULL, NULL, NULL
)
WHERE CAST(event_data AS XML).value('(event/@name)[1]', 'NVARCHAR(256)') = 'error_reported'
ORDER BY error_time DESC;
```

### Key Points for Interviews

- The `system_health` session is **always running** by default -- never disable it in production.
- It provides **free diagnostics** including deadlock history, error history, and long waits.
- It is often the first place to look when diagnosing an issue after the fact.
- The ring_buffer target has limited retention; the event_file target retains more history.

---

## sp_server_diagnostics

`sp_server_diagnostics` is a system stored procedure that continuously reports the health of SQL Server components. It is used by Always On Availability Groups for health detection but is also valuable for standalone monitoring.

### Usage

```sql
-- Run once (returns a single snapshot of all component health)
EXEC sp_server_diagnostics;

-- Run continuously, reporting every 10 seconds (press Ctrl+C to stop)
EXEC sp_server_diagnostics @repeat_interval = 10;
```

### Output Components

The procedure returns one row per component:

| Component | What It Reports |
|-----------|----------------|
| `system` | CPU utilization, memory status, total/available physical memory, page faults |
| `resource` | Memory broker state, buffer pool memory, stolen memory, plan cache |
| `query_processing` | Top wait stats, blocked processes, long-running queries, active requests, CPU utilization per scheduler |
| `io_subsystem` | I/O latency, pending I/Os, longest pending I/O |
| `events` | Key XEvent ring_buffer data (errors, memory, non-yielding schedulers) |

### Health States

Each component returns a state:

| State | Meaning |
|-------|---------|
| `0` - Clean | No known issues |
| `1` - Warning | Potential issue detected |
| `2` - Error | Critical issue |
| `3` - Unknown | Component state cannot be determined |

### Parsing the Output

```sql
-- The data column contains XML with detailed diagnostics
-- Example: Parse the system component

DECLARE @Results TABLE (
    create_time DATETIME,
    component_type SYSNAME,
    component_name SYSNAME,
    state INT,
    state_desc SYSNAME,
    data XML
);

INSERT INTO @Results
EXEC sp_server_diagnostics;

-- System component: CPU and memory
SELECT
    component_name,
    state_desc,
    data.value('(system/@systemCpuUtilization)[1]', 'INT') AS system_cpu_pct,
    data.value('(system/@sqlCpuUtilization)[1]', 'INT') AS sql_cpu_pct,
    data.value('(system/@totalPhysicalMemory_kb)[1]', 'BIGINT') / 1024 AS total_memory_mb,
    data.value('(system/@availablePhysicalMemory_kb)[1]', 'BIGINT') / 1024 AS available_memory_mb,
    data.value('(system/@committedMemory_kb)[1]', 'BIGINT') / 1024 AS committed_memory_mb
FROM @Results
WHERE component_name = 'system';

-- IO subsystem component: latency
SELECT
    component_name,
    state_desc,
    data.value('(ioSubsystem/@ioLatchTimeouts)[1]', 'BIGINT') AS io_latch_timeouts,
    data.value('(ioSubsystem/@totalLongIos)[1]', 'BIGINT') AS total_long_ios,
    data.value('(ioSubsystem/longestPendingRequests/pendingRequest/@duration)[1]', 'BIGINT') AS longest_pending_io_ms
FROM @Results
WHERE component_name = 'io_subsystem';

-- Query processing: blocked processes and active waits
SELECT
    component_name,
    state_desc,
    data.value('(queryProcessing/@maxWorkers)[1]', 'INT') AS max_workers,
    data.value('(queryProcessing/@workersCreated)[1]', 'INT') AS workers_created,
    data.value('(queryProcessing/@blockedProcesses)[1]', 'INT') AS blocked_processes,
    data.value('(queryProcessing/@hasUnresolvableDeadlockOccurred)[1]', 'INT') AS unresolvable_deadlock
FROM @Results
WHERE component_name = 'query_processing';
```

### Integration with Always On

- Always On Availability Groups use `sp_server_diagnostics` for automatic failover decisions.
- The **failure condition level** (1-5) determines which component failures trigger failover.
- The **health check timeout** (default 30 seconds) controls how long before a non-responsive check triggers action.
- Understanding this is important for interviews involving HA/DR architectures.

---

## Common Interview Questions

### Q1: What are Extended Events and why are they preferred over SQL Trace/Profiler?

**A:** Extended Events (XEvents) is SQL Server's modern, lightweight event-handling framework for diagnostics and performance monitoring. It is preferred over SQL Trace/Profiler because: (1) It has significantly lower overhead -- events are filtered at the source via predicates, minimizing data collection. (2) It offers far more events (1000+ vs ~180). (3) It provides flexible targets (ring_buffer for in-memory, event_file for persistence, histogram for aggregation). (4) It is integrated into SSMS and actively developed. (5) SQL Trace and Profiler are deprecated since SQL Server 2012 and will be removed in a future version. Any new monitoring work should use XEvents exclusively.

### Q2: How would you troubleshoot a suddenly slow SQL Server instance?

**A:** I follow a systematic approach:

1. **Check wait statistics** (`sys.dm_os_wait_stats`) to identify the primary bottleneck category (CPU, I/O, memory, locking).
2. **Check for blocking** (`sys.dm_exec_requests`, `sys.dm_os_waiting_tasks`) to see if queries are stuck waiting on locks.
3. **Review active queries** (`sys.dm_exec_requests` + `sys.dm_exec_sql_text` + `sys.dm_exec_query_plan`) to find resource-intensive running queries.
4. **Check system resources** -- CPU via `sp_server_diagnostics` or PerfMon, memory via PLE and Memory Grants Pending, disk latency via `sys.dm_io_virtual_file_stats`.
5. **Review the system_health XEvent session** for recent errors, deadlocks, or long waits.
6. **Compare to baseline** -- if metrics deviate from known-good baseline values, that points to what changed.
7. **Check for recent changes** -- new code deployments, configuration changes, index maintenance, statistics updates.

### Q3: What is Page Life Expectancy (PLE) and why is it important?

**A:** PLE is a performance counter that indicates the average number of seconds a data page stays in the buffer pool before being evicted. A declining PLE suggests memory pressure -- SQL Server is evicting pages from cache faster than normal, forcing more physical disk reads. The classic threshold of 300 seconds is outdated for modern servers with large memory. A better approach is to baseline PLE for your specific workload and alert on significant drops (e.g., PLE drops below 50% of baseline). A sudden PLE drop often correlates with a large scan query pushing useful pages out of the buffer pool.

### Q4: What are the most important wait types to know and what do they indicate?

**A:** The critical wait types are:

- **CXPACKET/CXCONSUMER** -- parallelism; review MAXDOP settings and query plans.
- **PAGEIOLATCH_SH** -- reading pages from disk; memory pressure or slow I/O.
- **WRITELOG** -- slow transaction log writes; check log disk latency.
- **LCK_M_*** -- lock contention; find and optimize blocking queries.
- **ASYNC_NETWORK_IO** -- client not consuming results fast enough.
- **SOS_SCHEDULER_YIELD** -- CPU pressure; optimize expensive queries.
- **RESOURCE_SEMAPHORE** -- memory grant waits; queries needing large memory grants.
- **THREADPOOL** -- thread starvation; very serious, needs immediate attention.

Each wait type points to a specific subsystem, which narrows the investigation to the correct area.

### Q5: How would you set up monitoring for a SQL Server environment with no third-party tools?

**A:** Using only native tools: (1) Ensure the **system_health XEvent session** is running (it is by default). (2) Create custom **XEvent sessions** for long-running queries, deadlocks, and blocking. (3) Set up a **SQL Agent job** that captures wait statistics, performance counters, and file I/O stats to baseline tables every 15 minutes. (4) Create **SQL Server Alerts** on performance conditions (e.g., PLE drop, Memory Grants Pending > 0, Processes Blocked > 5) that send email via Database Mail. (5) Use **Query Store** for query performance tracking. (6) Optionally enable the **Data Collector** with Management Data Warehouse for built-in reports. (7) Create a simple SSRS dashboard or Power BI report on the baseline tables for trend analysis.

### Q6: What is the system_health session and what does it capture?

**A:** The `system_health` session is a default Extended Events session that starts automatically with SQL Server and should never be disabled. It captures critical diagnostic data with minimal overhead: deadlock graphs (`xml_deadlock_report`), errors with severity 20 or higher, sessions waiting longer than 15 seconds, memory pressure events, scheduler health issues (non-yielding schedulers), and `sp_server_diagnostics` output. It writes to both a ring_buffer (limited retention) and event_file (longer retention). It is often the first place to look when investigating an issue after the fact because it provides a history of critical events without any setup required.

### Q7: Explain the difference between resource waits and signal waits.

**A:** When a thread cannot proceed, it enters a wait state. The total wait has two components: (1) **Resource wait** -- the time spent waiting for the actual resource to become available (e.g., waiting for a lock to be released, waiting for a disk I/O to complete). (2) **Signal wait** -- the time spent waiting to be scheduled on a CPU after the resource becomes available. The thread is "runnable" but waiting for a CPU time slice. High signal wait times (e.g., signal waits > 25% of total waits) indicate CPU pressure -- there are more runnable threads than available CPU schedulers. In `sys.dm_os_wait_stats`, `wait_time_ms` is the total, `signal_wait_time_ms` is the signal portion, and the difference is the resource wait.

### Q8: How do you use sp_server_diagnostics for health monitoring?

**A:** `sp_server_diagnostics` reports health across five components: system (CPU, memory), resource (buffer pool, plan cache), query_processing (blocked processes, top waits, active requests), io_subsystem (latency, pending I/Os), and events (critical errors from ring_buffer). Each component returns a state: clean, warning, or error. It can run once for a snapshot or continuously at a specified interval. It is used by Always On Availability Groups for automatic failover decisions based on configurable failure condition levels. For custom monitoring, you can capture its output into a table periodically and alert on non-clean states. The XML data column provides detailed metrics that can be parsed for specific values like CPU utilization, available memory, and I/O latency.

### Q9: What performance counters would you monitor for a production SQL Server?

**A:** My top priority counters are: **Buffer Manager: Page Life Expectancy** (memory pressure indicator), **Memory Manager: Memory Grants Pending** (should be 0; non-zero is immediate concern), **SQL Statistics: Batch Requests/sec** (workload volume), **General Statistics: Processes Blocked** (blocking indicator), **Locks: Number of Deadlocks/sec** (should be 0), **Access Methods: Full Scans/sec** (missing indexes), **Buffer Manager: Lazy Writes/sec** (memory pressure if sustained > 0). At the OS level: **Processor: % Processor Time** (< 80%), **Physical Disk: Avg Disk sec/Read and Write** (< 10ms for OLTP), and **Memory: Available MBytes** (sufficient for OS). I baseline these counters and set alerts on deviations.

### Q10: How do you handle the "benign waits" problem when analyzing wait statistics?

**A:** SQL Server has many wait types associated with idle background processes that accumulate large wait times but do not indicate any problem (e.g., `SLEEP_TASK`, `BROKER_TASK_STOP`, `LAZYWRITER_SLEEP`, `WAITFOR`, `XE_DISPATCHER_WAIT`, `REQUEST_FOR_DEADLOCK_SEARCH`). If you do not exclude these, they dominate the wait stats output and obscure real issues. The standard approach is to maintain an exclusion list of known benign waits (Paul Randal's list is the widely accepted reference) and filter them out in your query. Additionally, I focus on waits where `waiting_tasks_count > 0` and look at both total wait time and average wait time per task, as a small number of very long waits is different from many short waits.

---

## Tips

1. **Extended Events first** -- In any interview discussion about tracing, diagnostics, or monitoring, always lead with Extended Events. Mentioning Profiler without qualifying it as deprecated can signal outdated knowledge.

2. **Know the system_health session** -- It is free, always on, and captures deadlocks, severe errors, and long waits. Demonstrating knowledge of how to query it shows practical experience.

3. **Wait statistics are your diagnostic compass** -- Learn the top 10-15 wait types and what each indicates. In interviews, being able to say "I would check wait stats first and if I see PAGEIOLATCH_SH as the top wait, that tells me we have an I/O bottleneck, likely due to memory pressure or slow disks" is very powerful.

4. **Always compare to baseline** -- Never say a metric is "bad" without context. PLE of 500 might be fine for a small server but terrible for a 512 GB server. Train yourself to say "compared to our baseline of X, the current value of Y indicates..."

5. **Know the DMVs behind the tools** -- `sys.dm_os_wait_stats`, `sys.dm_exec_requests`, `sys.dm_exec_query_stats`, `sys.dm_io_virtual_file_stats`, `sys.dm_os_performance_counters`. These are what every monitoring tool uses under the hood.

6. **Understand signal waits** -- If signal waits are a high percentage of total waits (over 20-25%), that indicates CPU pressure regardless of what the top wait type is. This is a nuanced point that impresses interviewers.

7. **XEvent predicates are key to low overhead** -- Always emphasize that you filter at the event source (predicate) rather than collecting everything and filtering after. This is what makes XEvents production-safe.

8. **Practice the XML parsing** -- XEvent data is stored as XML. Being comfortable with `value()`, `query()`, `nodes()`, and `CROSS APPLY` for XML parsing is essential for working with XEvent data and `sp_server_diagnostics` output.

9. **Alerting strategy matters** -- Discuss a tiered alerting approach: informational alerts (logged only), warning alerts (email to team), critical alerts (page on-call). Alert fatigue from too many false positives is a real operational problem to address.

10. **Connect monitoring to action** -- Monitoring is only valuable if it leads to action. In interviews, show that you do not just collect data but use it to drive decisions: index tuning, query optimization, capacity planning, configuration changes.
