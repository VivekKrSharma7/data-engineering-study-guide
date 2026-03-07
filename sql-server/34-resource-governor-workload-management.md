# Resource Governor & Workload Management

[Back to SQL Server Index](./README.md)

---

## Overview

Resource Governor is a SQL Server feature (available in Enterprise Edition) that allows you to manage and throttle resource consumption — CPU, memory, and I/O — for incoming workloads. It gives DBAs fine-grained control over how server resources are allocated across different classes of users, applications, or query types, preventing any single workload from monopolizing the server.

---

## Key Concepts

### Resource Governor Architecture

Resource Governor operates through three core components that work together in a pipeline:

1. **Classifier Function** — A scalar UDF that evaluates each incoming session and routes it to a workload group.
2. **Workload Groups** — Logical containers that group sessions sharing the same resource policies.
3. **Resource Pools** — Physical resource boundaries (CPU, memory, I/O) that one or more workload groups draw from.

The flow is:

```
Incoming Session --> Classifier Function --> Workload Group --> Resource Pool
```

### Resource Pools

A resource pool represents a virtual subset of the physical resources of the server. SQL Server has three built-in pools and supports user-defined pools.

#### Built-In Pools

| Pool | Description |
|------|-------------|
| **Internal** | Used exclusively by SQL Server engine internals (e.g., lazy writer, checkpoint). Cannot be modified or monitored through Resource Governor DMVs in a meaningful way. |
| **Default** | Catches all sessions not classified into another pool. Always exists and cannot be dropped. |

#### User-Defined Pools

You create these to carve out dedicated resource allocations for specific workloads.

```sql
-- Create a resource pool for ETL workloads
CREATE RESOURCE POOL PoolETL
WITH (
    MIN_CPU_PERCENT = 10,
    MAX_CPU_PERCENT = 50,
    MIN_MEMORY_PERCENT = 10,
    MAX_MEMORY_PERCENT = 40,
    CAP_CPU_PERCENT = 60,           -- Hard cap (SQL Server 2012+)
    MIN_IOPS_PER_VOLUME = 50,       -- I/O governance (SQL Server 2014+)
    MAX_IOPS_PER_VOLUME = 200
);

-- Create a pool for ad-hoc reporting users
CREATE RESOURCE POOL PoolReporting
WITH (
    MIN_CPU_PERCENT = 5,
    MAX_CPU_PERCENT = 30,
    CAP_CPU_PERCENT = 40,
    MIN_MEMORY_PERCENT = 5,
    MAX_MEMORY_PERCENT = 25,
    MIN_IOPS_PER_VOLUME = 0,
    MAX_IOPS_PER_VOLUME = 100
);
```

**Important distinctions:**

- `MAX_CPU_PERCENT` — A soft cap. The pool can exceed this when no other pools need the CPU.
- `CAP_CPU_PERCENT` — A hard cap. The pool can **never** exceed this, even if CPU is idle elsewhere.
- `MIN_CPU_PERCENT` / `MIN_MEMORY_PERCENT` — Guaranteed minimums under contention. The sum of all MIN values across pools must not exceed 100.

### Workload Groups

Workload groups live inside resource pools and provide additional session-level policies.

```sql
-- Workload group for ETL processes
CREATE WORKLOAD GROUP GroupETL
WITH (
    IMPORTANCE = MEDIUM,
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 25,
    REQUEST_MAX_CPU_TIME_SEC = 0,           -- 0 = unlimited
    REQUEST_MEMORY_GRANT_TIMEOUT_SEC = 120,
    MAX_DOP = 4,
    GROUP_MAX_REQUESTS = 0                  -- 0 = unlimited
)
USING PoolETL;

-- Workload group for ad-hoc queries with strict limits
CREATE WORKLOAD GROUP GroupAdHoc
WITH (
    IMPORTANCE = LOW,
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 10,
    REQUEST_MAX_CPU_TIME_SEC = 300,         -- Kill query after 5 min CPU
    REQUEST_MEMORY_GRANT_TIMEOUT_SEC = 60,
    MAX_DOP = 2,
    GROUP_MAX_REQUESTS = 20                 -- Max 20 concurrent requests
)
USING PoolReporting;
```

**Workload Group Settings Explained:**

| Setting | Purpose |
|---------|---------|
| `IMPORTANCE` | LOW, MEDIUM, HIGH — determines scheduling priority within the same pool |
| `REQUEST_MAX_MEMORY_GRANT_PERCENT` | Max percentage of the pool's memory a single request can consume |
| `REQUEST_MAX_CPU_TIME_SEC` | CPU time limit per request (generates event, does not kill by default) |
| `REQUEST_MEMORY_GRANT_TIMEOUT_SEC` | How long a request waits for a memory grant before failing |
| `MAX_DOP` | Max degree of parallelism for requests in this group |
| `GROUP_MAX_REQUESTS` | Max concurrent requests allowed in the group (queues the rest) |

### Classifier Function

The classifier function is the "router" — a single scalar UDF in the `master` database that determines which workload group each new session belongs to. Only one classifier function can be active at a time.

```sql
USE master;
GO

CREATE FUNCTION dbo.fn_ResourceGovernorClassifier()
RETURNS SYSNAME
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @WorkloadGroup SYSNAME;

    -- Classify based on application name
    IF APP_NAME() LIKE '%SSIS%' OR APP_NAME() LIKE '%ETL%'
        SET @WorkloadGroup = 'GroupETL';

    -- Classify based on login
    ELSE IF SUSER_SNAME() IN ('ReportUser', 'AnalystLogin')
        SET @WorkloadGroup = 'GroupAdHoc';

    -- Classify based on host name
    ELSE IF HOST_NAME() LIKE 'RPTSERVER%'
        SET @WorkloadGroup = 'GroupAdHoc';

    -- Everything else goes to default
    ELSE
        SET @WorkloadGroup = 'default';

    RETURN @WorkloadGroup;
END;
GO
```

**Key rules for the classifier function:**

- Must be deterministic-safe and fast — it runs for **every** new session.
- Must return a valid workload group name (SYSNAME).
- If it returns NULL or an invalid name, the session goes to the **default** group.
- If the function throws an error, the session goes to the **default** group.
- Cannot use temp tables, table variables, or cursors.
- Available metadata functions: `SUSER_SNAME()`, `SUSER_SID()`, `APP_NAME()`, `HOST_NAME()`, `LOGINPROPERTY()`, `IS_SRVROLEMEMBER()`, `IS_MEMBER()`.

### Configuring Resource Governor

```sql
-- Step 1: Create resource pool(s)
CREATE RESOURCE POOL PoolETL
WITH (MIN_CPU_PERCENT = 10, MAX_CPU_PERCENT = 50, CAP_CPU_PERCENT = 60);

-- Step 2: Create workload group(s) mapped to pool(s)
CREATE WORKLOAD GROUP GroupETL
WITH (IMPORTANCE = HIGH, MAX_DOP = 8)
USING PoolETL;

-- Step 3: Create and register classifier function
ALTER RESOURCE GOVERNOR
WITH (CLASSIFIER_FUNCTION = dbo.fn_ResourceGovernorClassifier);

-- Step 4: Apply all configuration changes
ALTER RESOURCE GOVERNOR RECONFIGURE;

-- Enable Resource Governor (if not already enabled)
ALTER RESOURCE GOVERNOR ENABLE;
```

**Critical:** `ALTER RESOURCE GOVERNOR RECONFIGURE` must be called after any change to pools, groups, or the classifier function. Without it, changes remain in-memory metadata only and are not applied.

```sql
-- Disable Resource Governor entirely
ALTER RESOURCE GOVERNOR DISABLE;

-- Remove classifier function
ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

### CPU, Memory, and I/O Governance

#### CPU Governance

- **MIN_CPU_PERCENT**: Guaranteed average CPU bandwidth under contention.
- **MAX_CPU_PERCENT**: Soft ceiling — exceeded when other pools are idle.
- **CAP_CPU_PERCENT** (SQL Server 2012+): Hard ceiling — never exceeded regardless of server load.

#### Memory Governance

- Controls the **query execution memory grants** (sort and hash memory), not buffer pool pages.
- `MIN_MEMORY_PERCENT` / `MAX_MEMORY_PERCENT` on the pool level.
- `REQUEST_MAX_MEMORY_GRANT_PERCENT` on the workload group level (percentage of the pool's allocation).

#### I/O Governance (SQL Server 2014+)

- `MIN_IOPS_PER_VOLUME` / `MAX_IOPS_PER_VOLUME` — per physical disk volume.
- Governs physical I/O only, not logical reads from buffer pool.

### External Resource Pools

Starting with SQL Server 2016, **external resource pools** govern resources for external processes such as R and Python scripts executed via `sp_execute_external_script`.

```sql
CREATE EXTERNAL RESOURCE POOL PoolML
WITH (
    MAX_CPU_PERCENT = 30,
    MAX_MEMORY_PERCENT = 20
);

ALTER RESOURCE GOVERNOR RECONFIGURE;
```

### Monitoring Resource Usage

```sql
-- View resource pool runtime statistics
SELECT
    pool_id,
    name,
    min_cpu_percent,
    max_cpu_percent,
    cap_cpu_percent,
    min_memory_percent,
    max_memory_percent,
    used_memory_kb,
    target_memory_kb,
    min_iops_per_volume,
    max_iops_per_volume,
    read_io_completed_total,
    write_io_completed_total
FROM sys.dm_resource_governor_resource_pools;

-- View workload group runtime statistics
SELECT
    group_id,
    name,
    pool_id,
    total_request_count,
    active_request_count,
    queued_request_count,
    total_cpu_usage_ms,
    total_cpu_limit_violation_count,
    max_request_grant_memory_kb,
    total_reduced_memgrant_count
FROM sys.dm_resource_governor_workload_groups;

-- Check current classifier function
SELECT
    classifier_function_id,
    is_enabled
FROM sys.dm_resource_governor_configuration;

-- Check which group a session belongs to
SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    wg.name AS workload_group,
    rp.name AS resource_pool
FROM sys.dm_exec_sessions s
JOIN sys.dm_resource_governor_workload_groups wg
    ON s.group_id = wg.group_id
JOIN sys.dm_resource_governor_resource_pools rp
    ON wg.pool_id = rp.pool_id
WHERE s.is_user_process = 1;
```

---

## Real-World Use Cases

### Use Case 1: Limiting Ad-Hoc Queries

A common scenario — analysts run expensive ad-hoc queries against a production OLTP database. You want to prevent them from consuming all server resources.

```sql
-- Pool: limited resources for ad-hoc work
CREATE RESOURCE POOL PoolAdHoc
WITH (
    MIN_CPU_PERCENT = 0,
    MAX_CPU_PERCENT = 25,
    CAP_CPU_PERCENT = 30,
    MAX_MEMORY_PERCENT = 20,
    MAX_IOPS_PER_VOLUME = 150
);

-- Group: strict per-request limits
CREATE WORKLOAD GROUP GroupAdHoc
WITH (
    IMPORTANCE = LOW,
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 15,
    REQUEST_MAX_CPU_TIME_SEC = 120,
    MAX_DOP = 2,
    GROUP_MAX_REQUESTS = 10
)
USING PoolAdHoc;
```

### Use Case 2: Controlling ETL Workloads During Business Hours

```sql
-- The classifier can use time-of-day logic
CREATE FUNCTION dbo.fn_ResourceGovernorClassifier()
RETURNS SYSNAME
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @WorkloadGroup SYSNAME = 'default';

    IF APP_NAME() LIKE '%SSIS%'
    BEGIN
        -- During business hours, throttle ETL
        IF DATEPART(HOUR, GETDATE()) BETWEEN 8 AND 18
            SET @WorkloadGroup = 'GroupETL_Throttled';
        ELSE
            SET @WorkloadGroup = 'GroupETL_Full';
    END;

    RETURN @WorkloadGroup;
END;
```

### Use Case 3: Protecting Critical Application Workloads

```sql
-- Guarantee resources for the primary OLTP application
CREATE RESOURCE POOL PoolCriticalApp
WITH (
    MIN_CPU_PERCENT = 40,
    MAX_CPU_PERCENT = 100,
    MIN_MEMORY_PERCENT = 50,
    MAX_MEMORY_PERCENT = 80
);

CREATE WORKLOAD GROUP GroupCriticalApp
WITH (
    IMPORTANCE = HIGH,
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 50,
    MAX_DOP = 8
)
USING PoolCriticalApp;
```

---

## Resource Governor vs. Query Hints

| Aspect | Resource Governor | Query Hints |
|--------|-------------------|-------------|
| **Scope** | Server-wide, all sessions automatically classified | Per-query, must be added to each statement |
| **Control** | CPU, memory grants, I/O, concurrency | Primarily optimizer behavior (MAXDOP, OPTIMIZE FOR) |
| **Enforcement** | Automatic via classifier function | Manual, requires code changes |
| **Maintenance** | Centralized configuration | Scattered across application code |
| **Granularity** | Session-level classification | Statement-level |
| **DBA control** | Full DBA control without app changes | Requires developer cooperation |

Use Resource Governor for workload isolation; use query hints for optimizer guidance. They are complementary, not competing.

---

## Limitations

- **Enterprise Edition only** (or Developer Edition for testing).
- Governs the SQL Server engine only — cannot limit non-engine resource usage (e.g., CLR assemblies using OS resources directly).
- **Only one classifier function** can be active at a time.
- Classifier function must be fast and simple — complex logic increases connection overhead for every session.
- Memory governance applies to **query execution memory grants** only, not buffer pool or other memory clerks.
- I/O governance is approximate, not exact IOPS metering.
- Does not govern **tempdb** usage separately.
- Cannot set per-query row limits or result-set size limits.
- `REQUEST_MAX_CPU_TIME_SEC` generates an event but does **not** automatically kill the query (you need Event Notifications or Extended Events to act on it).
- Changes require `ALTER RESOURCE GOVERNOR RECONFIGURE` — easy to forget.
- Existing sessions are not reclassified after a configuration change; only new sessions pick up the new classification.

---

## Common Interview Questions & Answers

### Q1: What is Resource Governor and when would you use it?

**A:** Resource Governor is a SQL Server Enterprise feature that manages CPU, memory, and I/O allocation across workloads. It is used when you need to prevent one class of users or applications from starving others of resources — for example, preventing ad-hoc reporting queries from degrading OLTP performance, or guaranteeing resources for a critical application while limiting ETL jobs during business hours.

### Q2: Explain the difference between MAX_CPU_PERCENT and CAP_CPU_PERCENT.

**A:** `MAX_CPU_PERCENT` is a soft limit — the pool can exceed it when CPU is available and no other pool needs it. `CAP_CPU_PERCENT` is a hard limit — the pool can never exceed it even if the rest of the server is completely idle. For example, setting `CAP_CPU_PERCENT = 30` means that pool will never use more than 30% of CPU regardless of server load.

### Q3: What happens if the classifier function fails or returns NULL?

**A:** The session is routed to the **default** workload group (which uses the default resource pool). This is a safety mechanism — the classifier function should never block a user from connecting. This is also why the classifier function must be robust, simple, and well-tested.

### Q4: Can Resource Governor limit memory usage by a query?

**A:** Resource Governor controls **query execution memory grants** (memory used for sorts, hashes, and other query operators), not the buffer pool. You can set `MAX_MEMORY_PERCENT` on the resource pool and `REQUEST_MAX_MEMORY_GRANT_PERCENT` on the workload group. It does not limit how much of the buffer pool a query's data pages consume.

### Q5: How do you move a workload group to a different resource pool?

**A:**
```sql
ALTER WORKLOAD GROUP GroupETL USING PoolNewETL;
ALTER RESOURCE GOVERNOR RECONFIGURE;
```
Existing sessions in the old mapping continue until they disconnect. New sessions will use the updated mapping.

### Q6: How would you troubleshoot Resource Governor not classifying sessions correctly?

**A:**
1. Verify the classifier function is registered: `SELECT classifier_function_id FROM sys.dm_resource_governor_configuration`.
2. Verify Resource Governor is enabled: `SELECT is_enabled FROM sys.dm_resource_governor_configuration`.
3. Test the classifier function manually by simulating `APP_NAME()`, `SUSER_SNAME()`, etc.
4. Check `sys.dm_exec_sessions` joined to `sys.dm_resource_governor_workload_groups` to see where sessions are landing.
5. Look for errors in the SQL Server error log related to the classifier function.

### Q7: Can you use Resource Governor to limit tempdb usage?

**A:** No. Resource Governor does not directly govern tempdb usage. To control tempdb, consider other strategies such as limiting sort/hash memory grants (which can reduce tempdb spills), setting `MAX_DOP` to reduce parallel query tempdb usage, or using query-level hints.

---

## Tips

- **Keep the classifier function lightweight.** It runs on every new connection. Avoid table lookups if possible — use built-in functions like `APP_NAME()`, `SUSER_SNAME()`, and `HOST_NAME()`.
- **If you must use a lookup table in the classifier**, make sure it is small, in `master`, and has a covering index. Consider caching via a memory-optimized table.
- **Test classifier changes in a staging environment** first. A broken classifier function can cause all sessions to route to the default pool.
- **Monitor regularly** using the DMVs (`sys.dm_resource_governor_resource_pools`, `sys.dm_resource_governor_workload_groups`) to ensure your allocations match actual usage patterns.
- **Use CAP_CPU_PERCENT for hard isolation** — MAX_CPU_PERCENT alone is not enough if you truly need to cap a workload.
- **Remember that Resource Governor is reactive**, not proactive — it does not prevent a query from starting; it throttles the resources available to it.
- **Document your Resource Governor configuration** including the classifier logic, pool definitions, and group definitions. This configuration is critical infrastructure.
- **Plan for the sum of MIN values** — across all pools, `MIN_CPU_PERCENT` values must total 100 or less, and the same for `MIN_MEMORY_PERCENT`.
