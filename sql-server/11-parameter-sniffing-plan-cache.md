# Parameter Sniffing & Plan Cache

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [What is Parameter Sniffing?](#what-is-parameter-sniffing)
2. [When Parameter Sniffing Helps](#when-parameter-sniffing-helps)
3. [When Parameter Sniffing Hurts](#when-parameter-sniffing-hurts)
4. [Plan Cache Architecture](#plan-cache-architecture)
5. [Ad-Hoc vs Prepared Plans](#ad-hoc-vs-prepared-plans)
6. [Plan Cache Bloat](#plan-cache-bloat)
7. [Solutions for Parameter Sniffing](#solutions-for-parameter-sniffing)
8. [The Local Variable Trap](#the-local-variable-trap)
9. [Plan Guides](#plan-guides)
10. [Forced Parameterization vs Simple Parameterization](#forced-parameterization-vs-simple-parameterization)
11. [sp_executesql vs EXEC](#sp_executesql-vs-exec)
12. [Plan Cache DMVs](#plan-cache-dmvs)
13. [DBCC FREEPROCCACHE](#dbcc-freeproccache)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## What is Parameter Sniffing?

Parameter sniffing is the SQL Server optimizer's behavior of examining ("sniffing") the actual parameter values passed during the first execution of a stored procedure or parameterized query, and generating an execution plan optimized for those specific values. That plan is then cached and reused for all subsequent executions, regardless of the parameter values passed.

### How It Works

```
First Execution: EXEC GetOrders @CustomerID = 12345
                         |
                         v
              Optimizer "sniffs" value 12345
                         |
                         v
        Generates plan optimized for CustomerID = 12345
        (e.g., 3 rows expected -> Index Seek + Nested Loop)
                         |
                         v
              Plan is cached in plan cache
                         |
                         v
Second Execution: EXEC GetOrders @CustomerID = 99
                         |
                         v
              Reuses cached plan (no recompilation)
              (still uses Index Seek + Nested Loop,
               even if CustomerID = 99 has 500,000 rows)
```

### The Core Concept

SQL Server does this for a good reason: compiling an execution plan is expensive (CPU-intensive). By caching and reusing plans, SQL Server avoids repeated compilation costs. The problem arises only when data distribution is highly skewed -- meaning different parameter values would benefit from fundamentally different plans.

---

## When Parameter Sniffing Helps

Parameter sniffing is beneficial the majority of the time. It produces optimal or near-optimal plans when:

- **Data is uniformly distributed**: If most customers have roughly the same number of orders, a plan optimized for any one customer works well for all.
- **The sniffed value is representative**: If the first execution uses a typical parameter value, the cached plan works well for subsequent executions.
- **Compilation cost is high**: For complex queries with many joins, avoiding repeated compilation saves significant CPU.

### Example: Uniform Distribution

```sql
-- Customer orders are evenly distributed (100-200 orders each)
-- Parameter sniffing works perfectly here
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY OrderDate DESC;
END;

-- First call sniffs @CustomerID = 1001 (150 rows) -> Index Seek plan
-- All subsequent calls reuse this plan efficiently
-- because every customer has a similar row count
```

---

## When Parameter Sniffing Hurts

Parameter sniffing becomes problematic with **skewed data distribution** -- when different parameter values produce vastly different numbers of rows.

### Classic Example: The Large Customer

```sql
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY OrderDate DESC;
END;
```

Consider this data distribution:

| CustomerID | Number of Orders |
|-----------|-----------------|
| 1 (Wholesale) | 2,000,000 |
| 2-9999 (Retail) | 10-50 each |

**Scenario A -- Small customer executes first:**

```sql
EXEC GetCustomerOrders @CustomerID = 5000;  -- 25 rows
-- Plan: Index Seek + Nested Loop + Key Lookup (GREAT for 25 rows)

EXEC GetCustomerOrders @CustomerID = 1;     -- 2,000,000 rows
-- Reuses Index Seek + Key Lookup plan (TERRIBLE for 2M rows)
-- 2 million key lookups = extreme I/O, query runs for minutes
```

**Scenario B -- Large customer executes first:**

```sql
EXEC GetCustomerOrders @CustomerID = 1;     -- 2,000,000 rows
-- Plan: Clustered Index Scan + Hash Join (GREAT for 2M rows)

EXEC GetCustomerOrders @CustomerID = 5000;  -- 25 rows
-- Reuses Scan plan (WASTEFUL for 25 rows, but not catastrophic)
-- Scans entire table to find 25 rows -- slow but not disastrous
```

The asymmetry matters: a scan plan for a small result set is suboptimal but tolerable, while a seek + lookup plan for millions of rows is catastrophic.

### Real-World Indicators of Parameter Sniffing Problems

- Query performance is inconsistent: "Sometimes it runs in 1 second, sometimes 30 minutes"
- Performance improves after restarting SQL Server or clearing the plan cache
- The first execution after a cache clear is fast, but later executions are slow (or vice versa)
- Execution plan shows estimated rows that are wildly different from actual rows

---

## Plan Cache Architecture

The plan cache (also called the procedure cache) is a region of the SQL Server buffer pool that stores compiled execution plans for reuse.

### Plan Cache Structure

```
Plan Cache
├── CACHESTORE_SQLCP    (SQL Plans - parameterized/prepared)
├── CACHESTORE_OBJCP    (Object Plans - stored procedures, triggers, functions)
├── CACHESTORE_PHDR     (Bound Trees - algebrized query trees)
└── CACHESTORE_XPROC    (Extended Procedures)
```

### What is Stored in a Cached Plan?

Each cached plan contains:

- **Compiled Plan**: The query tree, operator choices, and metadata. Shared across all sessions.
- **Execution Context**: Per-session runtime state (parameter values, variable values, SET options). Each concurrent execution gets its own execution context.

### Plan Cache Lifetime

Plans are evicted from cache when:

- Memory pressure occurs (SQL Server needs the memory for other purposes)
- The plan is invalidated (schema change, statistics update, `sp_recompile`)
- `DBCC FREEPROCCACHE` is executed
- The plan has a low "cost" value and has not been reused recently

### Viewing Plan Cache Contents

```sql
-- Overview of plan cache by type
SELECT
    objtype,
    cacheobjtype,
    COUNT(*) AS plan_count,
    SUM(size_in_bytes) / 1024 / 1024 AS size_mb,
    SUM(usecounts) AS total_uses
FROM sys.dm_exec_cached_plans
GROUP BY objtype, cacheobjtype
ORDER BY size_mb DESC;
```

---

## Ad-Hoc vs Prepared Plans

### Ad-Hoc Plans

Ad-hoc queries are SQL statements submitted directly (not through stored procedures or `sp_executesql`). Each unique text string gets its own plan cache entry.

```sql
-- These are THREE separate plan cache entries:
SELECT * FROM Orders WHERE CustomerID = 100;
SELECT * FROM Orders WHERE CustomerID = 200;
SELECT * FROM Orders WHERE CustomerID = 300;
```

### Prepared Plans

Parameterized queries share a single plan cache entry regardless of the parameter value.

```sql
-- This produces ONE plan cache entry, reused for all values:
EXEC sp_executesql
    N'SELECT * FROM Orders WHERE CustomerID = @CustID',
    N'@CustID INT',
    @CustID = 100;
```

### Simple Auto-Parameterization

SQL Server can automatically parameterize simple ad-hoc queries under the SIMPLE parameterization setting (the default). It does this only for "safe" queries where parameterization would not change the optimal plan.

```sql
-- SQL Server might auto-parameterize this:
SELECT * FROM Orders WHERE OrderID = 12345;
-- Internally becomes: SELECT * FROM Orders WHERE OrderID = @0

-- SQL Server will NOT auto-parameterize complex queries like:
SELECT * FROM Orders WHERE CustomerID = 100 AND OrderDate > '2025-01-01';
-- Too complex for safe auto-parameterization under SIMPLE mode
```

---

## Plan Cache Bloat

Plan cache bloat occurs when the plan cache fills up with thousands of single-use plans, wasting memory and causing frequent cache evictions.

### Common Causes

1. **Ad-hoc queries with literal values**: ORMs or applications that concatenate values into SQL strings instead of using parameters.
2. **Dynamic SQL without parameterization**: Building SQL strings with embedded values.
3. **Queries with different SET options**: Different `SET ANSI_NULLS` or `SET QUOTED_IDENTIFIER` settings produce separate plans.

### Detecting Plan Cache Bloat

```sql
-- Find single-use plans
SELECT
    objtype,
    COUNT(*) AS number_of_plans,
    SUM(size_in_bytes) / 1024 / 1024 AS size_mb
FROM sys.dm_exec_cached_plans
WHERE usecounts = 1
GROUP BY objtype
ORDER BY size_mb DESC;

-- Compare single-use vs multi-use
SELECT
    CASE WHEN usecounts = 1 THEN 'Single Use' ELSE 'Multi Use' END AS plan_type,
    COUNT(*) AS number_of_plans,
    SUM(size_in_bytes) / 1024 / 1024 AS total_size_mb,
    AVG(size_in_bytes) / 1024 AS avg_size_kb
FROM sys.dm_exec_cached_plans
GROUP BY CASE WHEN usecounts = 1 THEN 'Single Use' ELSE 'Multi Use' END;
```

### Solution: Optimize for Ad-Hoc Workloads

```sql
-- Enable optimize for ad hoc workloads (server-level setting)
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;
```

This stores only a "stub" plan on first execution. The full plan is cached only after the second execution of the same query text. This dramatically reduces memory used by single-use plans.

---

## Solutions for Parameter Sniffing

### 1. OPTIMIZE FOR Hint

Tells the optimizer to compile the plan as if a specific value was passed.

```sql
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY OrderDate DESC
    OPTION (OPTIMIZE FOR (@CustomerID = 5000));  -- Optimize for a "typical" customer
END;
```

**Pros**: Simple, targeted fix. Plan is optimized for a representative value.
**Cons**: Requires knowing a good representative value. Still one plan for all executions.

### 2. OPTIMIZE FOR UNKNOWN

Tells the optimizer to ignore the sniffed value and use average statistics (density-based estimation) instead.

```sql
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY OrderDate DESC
    OPTION (OPTIMIZE FOR UNKNOWN);
END;
```

**Pros**: No need to pick a specific value. Uses statistical averages.
**Cons**: The "average" plan may not be optimal for any actual value. Often produces mediocre plans -- not great for anyone.

### 3. OPTION(RECOMPILE)

Forces the query to be recompiled every time it executes, using the actual parameter values each time.

```sql
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY OrderDate DESC
    OPTION (RECOMPILE);
END;
```

**Pros**: Always gets the optimal plan for the actual values. Also enables "parameter embedding optimization" -- the optimizer can simplify predicates, eliminate branches, etc.
**Cons**: Compilation cost on every execution. Do not use for queries that execute thousands of times per second. The compilation overhead is typically a few milliseconds but adds up at high frequency.

### 4. Dynamic SQL with sp_executesql

Split the procedure into different code paths based on parameter values.

```sql
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    DECLARE @sql NVARCHAR(MAX);

    IF @CustomerID = 1  -- Known large customer
    BEGIN
        SET @sql = N'SELECT OrderID, OrderDate, TotalAmount
                     FROM Sales.Orders WITH (INDEX(IX_Orders_CustDate))
                     WHERE CustomerID = @CustID
                     ORDER BY OrderDate DESC';
    END
    ELSE
    BEGIN
        SET @sql = N'SELECT OrderID, OrderDate, TotalAmount
                     FROM Sales.Orders
                     WHERE CustomerID = @CustID
                     ORDER BY OrderDate DESC';
    END;

    EXEC sp_executesql @sql, N'@CustID INT', @CustID = @CustomerID;
END;
```

### 5. Multiple Procedures (Plan Separation)

```sql
-- Separate procedures for different workloads
CREATE PROCEDURE GetCustomerOrders_Small
    @CustomerID INT
AS
BEGIN
    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY OrderDate DESC;
END;

CREATE PROCEDURE GetCustomerOrders_Large
    @CustomerID INT
AS
BEGIN
    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @CustomerID
    ORDER BY OrderDate DESC;
END;

-- Router procedure
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    IF @CustomerID = 1
        EXEC GetCustomerOrders_Large @CustomerID;
    ELSE
        EXEC GetCustomerOrders_Small @CustomerID;
END;
```

Each sub-procedure gets its own cached plan, so the plan for large customers does not interfere with the plan for small customers.

### Comparison of Solutions

| Solution | Compilation Cost | Plan Quality | Complexity | Best For |
|----------|-----------------|-------------|------------|----------|
| OPTIMIZE FOR | Once | Good for chosen value | Low | Known representative value |
| OPTIMIZE FOR UNKNOWN | Once | Mediocre | Low | Quick fix |
| OPTION(RECOMPILE) | Every execution | Optimal every time | Low | Low-frequency queries with skew |
| Dynamic SQL | Per variant | Good | Medium | Complex branching logic |
| Multiple Procedures | Once per variant | Optimal per variant | High | Extreme skew, high frequency |

---

## The Local Variable Trap

A common but misguided "fix" for parameter sniffing is to assign parameters to local variables.

```sql
-- THE LOCAL VARIABLE TRAP - DO NOT DO THIS
CREATE PROCEDURE GetCustomerOrders
    @CustomerID INT
AS
BEGIN
    DECLARE @LocalCustID INT = @CustomerID;

    SELECT OrderID, OrderDate, TotalAmount
    FROM Sales.Orders
    WHERE CustomerID = @LocalCustID  -- Uses local variable, not parameter
    ORDER BY OrderDate DESC;
END;
```

### Why This Is a Trap

- The optimizer cannot sniff the value of a local variable at compile time.
- It falls back to **density-based estimation** (average number of rows per distinct value).
- This is effectively the same as `OPTIMIZE FOR UNKNOWN` -- you get a "one size fits none" plan.
- It removes parameter sniffing entirely, which hurts the 95% of cases where parameter sniffing was helping.
- The resulting plan is compiled once and cached, just like before -- but now it is always the "average" plan.

### When People Think It Works

The local variable trick sometimes appears to "fix" the problem because it produces a different plan than the problematic sniffed plan. But it does not produce the optimal plan -- it produces the average plan, which happens to be better than the worst-case sniffed plan. Use `OPTIMIZE FOR UNKNOWN` explicitly if this is the behavior you want -- at least the intent is documented.

---

## Plan Guides

Plan guides let you attach query hints to queries without modifying the application code.

### Types of Plan Guides

| Type | Description |
|------|-------------|
| **SQL** | Matches standalone SQL statements |
| **OBJECT** | Matches queries inside stored procedures, functions, or triggers |
| **TEMPLATE** | Controls parameterization behavior for a query pattern |

### Creating a Plan Guide

```sql
-- Add RECOMPILE hint to a stored procedure query
EXEC sp_create_plan_guide
    @name = N'PG_GetCustomerOrders_Recompile',
    @stmt = N'SELECT OrderID, OrderDate, TotalAmount
              FROM Sales.Orders
              WHERE CustomerID = @CustomerID
              ORDER BY OrderDate DESC',
    @type = N'OBJECT',
    @module_or_batch = N'GetCustomerOrders',
    @params = NULL,
    @hints = N'OPTION (RECOMPILE)';
```

### Managing Plan Guides

```sql
-- View all plan guides
SELECT * FROM sys.plan_guides;

-- Validate a plan guide
SELECT * FROM sys.fn_validate_plan_guide(plan_guide_id)
FROM sys.plan_guides
WHERE name = 'PG_GetCustomerOrders_Recompile';

-- Drop a plan guide
EXEC sp_control_plan_guide @operation = N'DROP',
    @name = N'PG_GetCustomerOrders_Recompile';

-- Disable a plan guide
EXEC sp_control_plan_guide @operation = N'DISABLE',
    @name = N'PG_GetCustomerOrders_Recompile';
```

### Plan Guides vs Query Store Hints (SQL Server 2022)

Plan guides require exact text matching and are brittle. Query Store hints (covered in the Query Store topic) are simpler -- they use `query_id` instead of text matching. Prefer Query Store hints on SQL Server 2022+.

---

## Forced Parameterization vs Simple Parameterization

### Simple Parameterization (Default)

SQL Server auto-parameterizes only trivial, "safe" queries:

```sql
-- Auto-parameterized under SIMPLE:
SELECT * FROM Products WHERE ProductID = 42;
-- Becomes: SELECT * FROM Products WHERE ProductID = @0

-- NOT auto-parameterized (too complex):
SELECT * FROM Products WHERE CategoryID = 5 AND Price > 100;
-- Stays as literal values, gets its own plan cache entry
```

### Forced Parameterization

```sql
ALTER DATABASE [AdventureWorks] SET PARAMETERIZATION FORCED;
```

With forced parameterization, SQL Server auto-parameterizes almost all queries, even complex ones. Literal values are replaced with parameters.

### When to Use Forced Parameterization

| Scenario | Recommendation |
|----------|---------------|
| High plan cache bloat from ad-hoc queries | Consider FORCED |
| OLTP with many similar queries differing only in literal values | FORCED can help |
| Data warehouse with complex analytical queries | Avoid FORCED |
| Queries with skewed data distribution | Avoid FORCED (it enables parameter sniffing for all queries) |

### Risks of Forced Parameterization

- Queries that need different plans for different literal values will all share one plan.
- You lose the optimizer's ability to use literal values for partition elimination, constant folding, etc.
- Cannot be applied selectively to individual queries (it is database-wide).

### Template Plan Guides as a Middle Ground

You can use template plan guides to force parameterization on specific query patterns while leaving the database in SIMPLE mode:

```sql
-- Force parameterization only for this specific pattern
EXEC sp_create_plan_guide
    @name = N'TPG_ProductLookup',
    @stmt = N'SELECT * FROM Products WHERE ProductID = @0',
    @type = N'TEMPLATE',
    @module_or_batch = NULL,
    @params = N'@0 INT',
    @hints = N'OPTION (PARAMETERIZATION FORCED)';
```

---

## sp_executesql vs EXEC

### sp_executesql

```sql
-- Parameterized execution - promotes plan reuse
DECLARE @sql NVARCHAR(MAX) = N'SELECT * FROM Orders WHERE CustomerID = @CustID';
EXEC sp_executesql @sql, N'@CustID INT', @CustID = 100;
```

**Benefits:**
- Parameters are typed -- prevents SQL injection when used correctly.
- Plan is cached and reused for different parameter values (same plan cache entry).
- Subject to parameter sniffing (which is usually good).

### EXEC (String Concatenation)

```sql
-- Non-parameterized execution - each value gets its own plan
DECLARE @sql NVARCHAR(MAX) = N'SELECT * FROM Orders WHERE CustomerID = ' + CAST(@CustID AS NVARCHAR(10));
EXEC(@sql);
```

**Drawbacks:**
- Each unique string is a separate plan cache entry (plan cache bloat).
- SQL injection risk if values come from user input.
- No plan reuse across different values.
- Each execution may trigger compilation.

### Key Difference in Plan Caching

```sql
-- sp_executesql: ONE plan cache entry, reused
EXEC sp_executesql N'SELECT * FROM T WHERE ID = @id', N'@id INT', @id = 1;
EXEC sp_executesql N'SELECT * FROM T WHERE ID = @id', N'@id INT', @id = 2;
EXEC sp_executesql N'SELECT * FROM T WHERE ID = @id', N'@id INT', @id = 3;
-- Result: 1 plan, usecounts = 3

-- EXEC: THREE plan cache entries
EXEC('SELECT * FROM T WHERE ID = 1');
EXEC('SELECT * FROM T WHERE ID = 2');
EXEC('SELECT * FROM T WHERE ID = 3');
-- Result: 3 plans, each with usecounts = 1
```

### Best Practice

Always prefer `sp_executesql` with parameters over `EXEC()` with string concatenation. It is safer (SQL injection prevention), more memory-efficient (plan reuse), and performs better.

---

## Plan Cache DMVs

### sys.dm_exec_cached_plans

The primary DMV for examining the plan cache.

```sql
-- Top 20 most expensive cached plans by total CPU
SELECT TOP 20
    cp.objtype,
    cp.usecounts,
    cp.size_in_bytes / 1024 AS size_kb,
    qs.total_worker_time / 1000 AS total_cpu_ms,
    qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000 AS avg_cpu_ms,
    qs.total_elapsed_time / 1000 AS total_duration_ms,
    qs.total_logical_reads,
    qs.execution_count,
    SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
        (CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
        END - qs.statement_start_offset) / 2 + 1) AS query_text,
    qp.query_plan
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
JOIN sys.dm_exec_cached_plans AS cp
    ON qs.plan_handle = cp.plan_handle
ORDER BY qs.total_worker_time DESC;
```

### sys.dm_exec_query_stats

Runtime statistics aggregated per query statement in the plan cache.

```sql
-- Find queries with the most variation in execution time
-- (potential parameter sniffing victims)
SELECT TOP 20
    qs.query_hash,
    qs.query_plan_hash,
    qs.execution_count,
    qs.min_worker_time / 1000 AS min_cpu_ms,
    qs.max_worker_time / 1000 AS max_cpu_ms,
    (qs.max_worker_time - qs.min_worker_time) / 1000 AS cpu_variance_ms,
    qs.min_elapsed_time / 1000 AS min_duration_ms,
    qs.max_elapsed_time / 1000 AS max_duration_ms,
    qs.min_logical_reads,
    qs.max_logical_reads,
    SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
        (CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
        END - qs.statement_start_offset) / 2 + 1) AS query_text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE qs.execution_count > 100
ORDER BY (qs.max_elapsed_time - qs.min_elapsed_time) DESC;
```

### sys.dm_exec_plan_attributes

Examine the attributes that make a plan unique:

```sql
-- See what makes cached plans different for similar queries
SELECT
    pa.attribute,
    pa.value,
    pa.is_cache_key
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_plan_attributes(cp.plan_handle) AS pa
WHERE cp.plan_handle = 0x06000600... -- specific plan handle
  AND pa.is_cache_key = 1;
```

### Finding Plans for a Specific Stored Procedure

```sql
SELECT
    cp.usecounts,
    cp.size_in_bytes,
    qs.total_worker_time,
    qs.execution_count,
    qp.query_plan
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS st
JOIN sys.dm_exec_query_stats AS qs
    ON cp.plan_handle = qs.plan_handle
WHERE st.objectid = OBJECT_ID('dbo.GetCustomerOrders')
  AND st.dbid = DB_ID('AdventureWorks');
```

---

## DBCC FREEPROCCACHE

### Clearing the Entire Plan Cache

```sql
-- DANGER: Clears ALL cached plans on the entire instance
DBCC FREEPROCCACHE;
```

This causes every query to be recompiled on next execution. On a busy production server, this can cause a CPU spike from mass recompilation.

### Targeted Cache Clearing

```sql
-- Clear a specific plan by plan_handle
DBCC FREEPROCCACHE(0x06000600ABC123...);

-- Clear all plans for a specific SQL handle
DBCC FREEPROCCACHE(sql_handle);

-- Clear plans for a specific resource pool (Resource Governor)
DBCC FREEPROCCACHE('pool_name');
```

### Recompiling a Specific Object

```sql
-- Mark a stored procedure for recompilation on next execution
EXEC sp_recompile 'dbo.GetCustomerOrders';

-- Mark a table -- all plans referencing this table will recompile
EXEC sp_recompile 'Sales.Orders';
```

`sp_recompile` is much safer than `DBCC FREEPROCCACHE` because it only affects specific objects.

### When to Clear the Plan Cache

| Scenario | Recommended Action |
|----------|-------------------|
| One problematic stored procedure | `EXEC sp_recompile 'ProcName'` |
| One problematic plan | `DBCC FREEPROCCACHE(plan_handle)` |
| After major statistics update | `EXEC sp_recompile 'TableName'` |
| After major index rebuild | Usually automatic; use sp_recompile if needed |
| Testing/development | `DBCC FREEPROCCACHE` is acceptable |
| Production emergency | `DBCC FREEPROCCACHE` as last resort |

---

## Common Interview Questions

### Q1: What is parameter sniffing? Is it good or bad?

**A:** Parameter sniffing is the optimizer's behavior of using the actual parameter values from the first execution of a parameterized query to generate the execution plan. It is neither inherently good nor bad -- it is a performance optimization that works well most of the time. It becomes a problem only when data distribution is highly skewed, meaning different parameter values would benefit from very different execution plans. The cached plan (optimized for the first value) is then suboptimal for other values.

### Q2: How do you detect parameter sniffing issues?

**A:** Key indicators: (1) Large variance between `min_elapsed_time` and `max_elapsed_time` in `sys.dm_exec_query_stats`. (2) Execution plan shows estimated rows vastly different from actual rows. (3) Performance is inconsistent -- sometimes fast, sometimes slow -- and improves after clearing the plan cache. (4) In Query Store, multiple plans for the same query with very different performance metrics.

### Q3: Explain the difference between OPTIMIZE FOR, OPTIMIZE FOR UNKNOWN, and OPTION(RECOMPILE).

**A:** `OPTIMIZE FOR (@param = value)` compiles the plan for a specific value you choose -- good when you know a representative value. `OPTIMIZE FOR UNKNOWN` ignores the sniffed value and uses density-based estimation (statistical average) -- produces a "middle ground" plan that is optimal for nobody. `OPTION(RECOMPILE)` recompiles on every execution using actual values -- always optimal but pays compilation cost each time. For low-frequency queries with severe skew, RECOMPILE is usually the best choice.

### Q4: What is the "local variable trap" and why should you avoid it?

**A:** The local variable trap is when developers assign parameters to local variables and use the local variables in queries, thinking it will fix parameter sniffing. The optimizer cannot sniff local variable values at compile time, so it falls back to density-based estimation -- exactly like `OPTIMIZE FOR UNKNOWN`. The plan is still compiled once and cached. It does not solve the problem; it just trades one suboptimal behavior for another. If you want this behavior, use `OPTIMIZE FOR UNKNOWN` explicitly so the intent is documented.

### Q5: What is plan cache bloat and how do you fix it?

**A:** Plan cache bloat occurs when thousands of single-use ad-hoc query plans consume plan cache memory, reducing space for frequently-used plans and causing evictions. It is commonly caused by applications that concatenate literal values into SQL strings. Solutions: (1) Enable "optimize for ad hoc workloads" (`sp_configure`) to store only stubs for first-time queries. (2) Fix the application to use parameterized queries (`sp_executesql`). (3) Consider forced parameterization for OLTP workloads with many similar ad-hoc queries.

### Q6: When would you use sp_executesql over EXEC()?

**A:** Always prefer `sp_executesql` when executing dynamic SQL. It supports parameterization, which enables plan reuse (one cached plan for all parameter values), prevents SQL injection, and provides proper data typing. `EXEC()` with string concatenation creates a new plan cache entry for every unique string, causes plan cache bloat, and is vulnerable to SQL injection. The only scenario where `EXEC()` is acceptable is when the entire SQL structure (not just values) changes dynamically.

### Q7: How does forced parameterization differ from simple parameterization?

**A:** Simple parameterization (the default) auto-parameterizes only trivial queries where the optimizer is certain parameterization is safe. Forced parameterization auto-parameterizes nearly all queries, replacing literal values with parameters. Forced parameterization reduces plan cache bloat but introduces parameter sniffing for all queries and removes the optimizer's ability to use literal values for optimizations like partition elimination or constant folding. It is a database-wide setting and cannot be applied to individual queries (but template plan guides offer per-query control).

### Q8: What is the difference between DBCC FREEPROCCACHE and sp_recompile?

**A:** `DBCC FREEPROCCACHE` (without arguments) immediately removes all plans from the cache, causing a mass recompilation spike. `sp_recompile` marks a specific object (procedure or table) for recompilation on its next execution -- the current plan stays in cache until then. `sp_recompile` is much safer for production use. `DBCC FREEPROCCACHE` can also target a specific plan handle, which is the safest approach when you need to evict one specific plan.

### Q9: How do SET options affect plan caching?

**A:** Plans are cached based on a combination of the query text AND the session's SET options (like ANSI_NULLS, QUOTED_IDENTIFIER, ANSI_PADDING, etc.). Two identical queries with different SET options produce separate plan cache entries. This is a common source of plan cache bloat, especially when different client drivers (ADO.NET, ODBC, OLEDB) connect with different default SET options. You can identify this by querying `sys.dm_exec_plan_attributes` and checking the `set_options` attribute.

### Q10: Describe a systematic approach to diagnosing and fixing a parameter sniffing problem in production.

**A:** (1) **Identify**: Use Query Store or `sys.dm_exec_query_stats` to find queries with high duration variance. (2) **Confirm**: Get the execution plan and compare estimated vs actual rows. If wildly different, parameter sniffing is likely. (3) **Quick fix**: Force a known-good plan via Query Store, or `EXEC sp_recompile` on the procedure. (4) **Analyze**: Examine data distribution of the filtered columns. Is it skewed? (5) **Choose a permanent fix**: For low-frequency queries, add `OPTION(RECOMPILE)`. For high-frequency queries with known skew, use `OPTIMIZE FOR` or split into multiple procedures. (6) **Validate**: Monitor Query Store to confirm the fix resolved the variance.

---

## Tips

1. **Parameter sniffing is your friend 95% of the time.** Do not blindly disable it (e.g., with trace flags or local variables). Only address it when you have confirmed it is causing problems for specific queries.

2. **Use Query Store to detect parameter sniffing.** Look for queries with multiple plans where performance varies drastically between plans. This is the most reliable detection method.

3. **OPTION(RECOMPILE) is the safest general fix**, but only for queries that do not execute thousands of times per second. The compilation cost is typically 1-5ms, which is negligible for queries running a few times per minute.

4. **Never use DBCC FREEPROCCACHE without arguments in production** unless you fully understand the consequences. A mass recompilation spike can bring a busy server to its knees. Use targeted approaches: `sp_recompile` or `DBCC FREEPROCCACHE(plan_handle)`.

5. **Enable "optimize for ad hoc workloads"** on virtually every SQL Server instance. There is almost no downside, and it prevents single-use plans from consuming plan cache memory.

6. **Always use sp_executesql for dynamic SQL.** It is safer (parameterized = no SQL injection), more efficient (plan reuse), and easier to debug.

7. **The local variable trick is an anti-pattern.** If you see it in code, replace it with an explicit `OPTIMIZE FOR UNKNOWN` or, better, an `OPTION(RECOMPILE)` based on analysis of the query's frequency and the data's skew.

8. **Monitor plan cache pressure.** If `sys.dm_os_memory_clerks` shows CACHESTORE_SQLCP consuming gigabytes, investigate for plan cache bloat.

9. **Updated statistics reduce parameter sniffing impact.** When statistics accurately reflect data distribution, the optimizer makes better initial estimates, and the sniffed plan is more likely to be acceptable for a wider range of values.

10. **Consider Adaptive Joins and Adaptive Memory Grants** (SQL Server 2017+, compatibility level 140+). These Intelligent Query Processing features can mitigate some parameter sniffing scenarios by adjusting plan behavior at runtime.
