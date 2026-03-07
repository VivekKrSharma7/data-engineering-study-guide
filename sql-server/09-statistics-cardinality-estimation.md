# Statistics & Cardinality Estimation

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Why Statistics Matter](#why-statistics-matter)
2. [Auto-Create Statistics](#auto-create-statistics)
3. [Auto-Update Statistics](#auto-update-statistics)
4. [Statistics Components: Histogram, Density Vector, String Index](#statistics-components-histogram-density-vector-string-index)
5. [DBCC SHOW_STATISTICS](#dbcc-show_statistics)
6. [Filtered Statistics](#filtered-statistics)
7. [Manual Statistics Management](#manual-statistics-management)
8. [UPDATE STATISTICS and sp_updatestats](#update-statistics-and-sp_updatestats)
9. [Trace Flag 2371: Dynamic Auto-Update Threshold](#trace-flag-2371-dynamic-auto-update-threshold)
10. [The Ascending Key Problem](#the-ascending-key-problem)
11. [Legacy vs New Cardinality Estimator (CE70 vs CE120+)](#legacy-vs-new-cardinality-estimator-ce70-vs-ce120)
12. [Statistics on Computed Columns](#statistics-on-computed-columns)
13. [Multi-Column Statistics](#multi-column-statistics)
14. [sys.dm_db_stats_properties](#sysdm_db_stats_properties)
15. [Common Interview Questions](#common-interview-questions)
16. [Tips for Senior Engineers](#tips-for-senior-engineers)

---

## Why Statistics Matter

Statistics are the **foundation of query optimization** in SQL Server. The query optimizer uses statistics to estimate how many rows will flow through each operator in an execution plan -- this is called **cardinality estimation**.

If statistics are accurate, the optimizer makes good decisions:
- Correct join algorithm (nested loops vs hash vs merge).
- Correct join order.
- Appropriate memory grants for sorts and hash operations.
- Correct degree of parallelism.

If statistics are stale or inaccurate:
- Underestimated rows -> insufficient memory grants -> spills to tempdb.
- Overestimated rows -> excessive memory grants -> wasted memory, potential RESOURCE_SEMAPHORE waits.
- Wrong join type -> nested loops on millions of rows instead of hash match.
- Wrong join order -> exponential cost increase.

**Statistics are not optional. They are the single most impactful factor in query plan quality.**

---

## Auto-Create Statistics

When `AUTO_CREATE_STATISTICS` is enabled (default: ON), SQL Server automatically creates statistics on columns referenced in query predicates that do not already have statistics.

```sql
-- Check current setting
SELECT name, is_auto_create_stats_on
FROM sys.databases WHERE name = DB_NAME();

-- Enable (default)
ALTER DATABASE AdventureWorks SET AUTO_CREATE_STATISTICS ON;

-- Disable (rarely recommended)
ALTER DATABASE AdventureWorks SET AUTO_CREATE_STATISTICS OFF;
```

### How Auto-Create Works

1. A query references column `X` in a WHERE clause.
2. The optimizer checks for existing statistics on column `X`.
3. If none exist, statistics are created **synchronously** (the query waits).
4. The auto-created statistics object is named `_WA_Sys_<hex>_<hex>`.

### Asynchronous Auto-Create (SQL Server 2016 SP1+)

```sql
-- Enable incremental statistics with auto-create
ALTER DATABASE AdventureWorks
SET AUTO_CREATE_STATISTICS ON (INCREMENTAL = ON);
```

### When Auto-Create Does NOT Happen

- `AUTO_CREATE_STATISTICS` is OFF.
- The column already has statistics (from an index or manually created).
- The query uses a table variable (no statistics on table variables -- one of many reasons to prefer temp tables for large datasets).

---

## Auto-Update Statistics

When `AUTO_UPDATE_STATISTICS` is enabled (default: ON), SQL Server automatically updates statistics when they become **stale** -- meaning enough data modifications have occurred.

```sql
-- Check current setting
SELECT name, is_auto_update_stats_on, is_auto_update_stats_async_on
FROM sys.databases WHERE name = DB_NAME();

-- Enable (default)
ALTER DATABASE AdventureWorks SET AUTO_UPDATE_STATISTICS ON;
```

### Staleness Threshold (Pre-2016 / Trace Flag 2371)

The **legacy threshold** for auto-update is:

| Table Rows | Modifications Required to Trigger Update |
|------------|------------------------------------------|
| 0 rows | First row inserted |
| < 500 rows | 500 modifications |
| >= 500 rows | 500 + 20% of table rows |

**Example:** A table with 1,000,000 rows requires **200,500 modifications** (20% + 500) before statistics auto-update. This means statistics can be severely stale for large tables.

### Synchronous vs Asynchronous Auto-Update

**Synchronous (default):**
- The query that triggers the auto-update **waits** for the statistics update to complete.
- The query is then recompiled with new statistics.
- Safe but can cause noticeable delays.

**Asynchronous:**
- The triggering query proceeds with the **stale** statistics.
- The statistics update happens in the background.
- Subsequent queries benefit from updated statistics.
- Better for user experience but the triggering query may use a suboptimal plan.

```sql
-- Enable asynchronous auto-update
ALTER DATABASE AdventureWorks SET AUTO_UPDATE_STATISTICS_ASYNC ON;
```

---

## Statistics Components: Histogram, Density Vector, String Index

Every statistics object in SQL Server contains three components, viewable via `DBCC SHOW_STATISTICS`.

### 1. Histogram

The histogram describes the **distribution of values** for the first column (leading column) of the statistics key.

- Contains up to **200 steps** (buckets), regardless of table size.
- Each step covers a range of values with summary information.

| Column | Meaning |
|--------|---------|
| RANGE_HI_KEY | Upper boundary value of this step |
| RANGE_ROWS | Estimated rows between previous step's HI_KEY and this step's HI_KEY (exclusive of both) |
| EQ_ROWS | Estimated rows exactly equal to RANGE_HI_KEY |
| DISTINCT_RANGE_ROWS | Estimated distinct values in the range |
| AVG_RANGE_ROWS | Average rows per distinct value in the range (RANGE_ROWS / DISTINCT_RANGE_ROWS) |

**Key limitation:** Only **200 steps** for potentially billions of distinct values. Values between steps are estimated using interpolation. This is where estimation errors originate for skewed data.

### 2. Density Vector

The density vector provides information about **combinations of columns** in the statistics key.

- **Density** = 1 / (number of distinct values).
- Used for estimating GROUP BY, DISTINCT, and join cardinality when the query predicate does not match a histogram step.

```
All density    |  Average Length  |  Columns
-------------------------------------------
0.0001         |  4               |  CustomerID
0.00005        |  8               |  CustomerID, OrderDate
0.00001        |  12              |  CustomerID, OrderDate, Status
```

**Density of 0.0001 for CustomerID** means there are ~10,000 distinct customers. For a table with 1,000,000 rows, the estimated rows for `WHERE CustomerID = @variable` (unknown value) = 1,000,000 * 0.0001 = **100 rows**.

### 3. String Index

A string summary for **CHAR** and **VARCHAR** columns that helps estimate `LIKE` predicates with leading wildcards. This component is internal and not directly visible; its presence is indicated by the `String Index` field in the statistics header.

---

## DBCC SHOW_STATISTICS

The primary tool for examining statistics details.

```sql
-- Full output (header + density vector + histogram)
DBCC SHOW_STATISTICS ('Sales.Orders', 'IX_Orders_CustomerID');

-- Header only
DBCC SHOW_STATISTICS ('Sales.Orders', 'IX_Orders_CustomerID') WITH STAT_HEADER;

-- Density vector only
DBCC SHOW_STATISTICS ('Sales.Orders', 'IX_Orders_CustomerID') WITH DENSITY_VECTOR;

-- Histogram only
DBCC SHOW_STATISTICS ('Sales.Orders', 'IX_Orders_CustomerID') WITH HISTOGRAM;

-- No output formatting / result set format (useful for queries)
DBCC SHOW_STATISTICS ('Sales.Orders', 'IX_Orders_CustomerID') WITH NO_INFOMSGS;
```

### Reading the Header

```
Name            | Updated              | Rows    | Rows Sampled | Steps | Density | String Index | ...
IX_Orders_Cust  | 2025-12-15 10:30:00  | 1000000 | 500000       | 200   | 0       | NO           |
                | Average Key Length | Filter Expression | Unfiltered Rows
                | 4                  | NULL               | 1000000
```

Key fields:
- **Updated**: When statistics were last updated.
- **Rows**: Total rows at time of update.
- **Rows Sampled**: Rows actually read to build the statistics (sampling).
- **Steps**: Number of histogram steps (max 200).
- **Filter Expression**: For filtered statistics, the predicate.
- **Unfiltered Rows**: Total rows before filter (for filtered statistics).

### Sampling

By default, `UPDATE STATISTICS` uses **sampling** (reads a percentage of rows). For small tables, it may do a full scan. For very large tables, it samples as few as needed for reasonable accuracy.

```sql
-- Force full scan (most accurate but slowest)
UPDATE STATISTICS Sales.Orders IX_Orders_CustomerID WITH FULLSCAN;

-- Specify sample percentage
UPDATE STATISTICS Sales.Orders IX_Orders_CustomerID WITH SAMPLE 50 PERCENT;

-- Specify sample rows
UPDATE STATISTICS Sales.Orders IX_Orders_CustomerID WITH SAMPLE 100000 ROWS;
```

---

## Filtered Statistics

Filtered statistics cover a **subset of rows** defined by a WHERE predicate. They provide more precise histograms for data subsets that queries frequently target.

```sql
-- Create filtered statistics for active orders only
CREATE STATISTICS ST_Orders_Active_CustomerID
ON Sales.Orders (CustomerID)
WHERE Status = 'Active';

-- Create filtered statistics for recent data
CREATE STATISTICS ST_Orders_Recent
ON Sales.Orders (OrderDate)
WHERE OrderDate >= '2025-01-01';
```

### When Filtered Statistics Help

- **Skewed data distributions**: A table where 5% of rows are `Status = 'Active'` and 95% are `Status = 'Closed'`. The standard histogram may not accurately represent the active subset.
- **Correlated columns**: When the distribution of column A varies significantly depending on column B's value.
- **Partitioned-like queries**: Queries that always filter on a specific value.

### Automatic Filtered Statistics

SQL Server does **not** auto-create filtered statistics. You must create them manually. However, SQL Server **does** create filtered statistics automatically for **indexed views** and **filtered indexes**.

### Interaction with Parameterized Queries

Like filtered indexes, filtered statistics are most effective when queries use **literal values** that match the filter. Parameterized queries may not benefit because the optimizer cannot guarantee the parameter matches the filter at compile time.

---

## Manual Statistics Management

### Creating Statistics Manually

```sql
-- Single-column statistics
CREATE STATISTICS ST_Orders_OrderDate
ON Sales.Orders (OrderDate);

-- Multi-column statistics
CREATE STATISTICS ST_Orders_Cust_Date
ON Sales.Orders (CustomerID, OrderDate);

-- With full scan
CREATE STATISTICS ST_Orders_Cust_Date
ON Sales.Orders (CustomerID, OrderDate)
WITH FULLSCAN;

-- With specific sample
CREATE STATISTICS ST_Orders_Cust_Date
ON Sales.Orders (CustomerID, OrderDate)
WITH SAMPLE 50 PERCENT;

-- Filtered statistics
CREATE STATISTICS ST_Orders_Active
ON Sales.Orders (CustomerID)
WHERE Status = 'Active';
```

### Dropping Statistics

```sql
DROP STATISTICS Sales.Orders.ST_Orders_OrderDate;
```

### Renaming Statistics

```sql
-- Statistics cannot be renamed directly; drop and recreate
```

### Disabling Auto Statistics on a Specific Index

```sql
-- Prevent auto-update on a specific statistics object
UPDATE STATISTICS Sales.Orders IX_Orders_CustomerID WITH NORECOMPUTE;

-- Re-enable by updating without NORECOMPUTE
UPDATE STATISTICS Sales.Orders IX_Orders_CustomerID;
```

---

## UPDATE STATISTICS and sp_updatestats

### UPDATE STATISTICS

Manually updates statistics for a table or specific statistics object.

```sql
-- Update all statistics on a table (index and column statistics)
UPDATE STATISTICS Sales.Orders;

-- Update a specific statistics object
UPDATE STATISTICS Sales.Orders IX_Orders_CustomerID;

-- Update only index statistics
UPDATE STATISTICS Sales.Orders WITH INDEX;

-- Update only column statistics (non-index)
UPDATE STATISTICS Sales.Orders WITH COLUMNS;

-- Full scan (most accurate)
UPDATE STATISTICS Sales.Orders WITH FULLSCAN;

-- Specific sample rate
UPDATE STATISTICS Sales.Orders WITH SAMPLE 30 PERCENT;

-- Update all statistics and resample at the existing sample rate
UPDATE STATISTICS Sales.Orders WITH RESAMPLE;

-- With PERSIST_SAMPLE_PERCENT (SQL Server 2016 SP2+)
-- Future auto-updates will use this sample rate instead of the default
UPDATE STATISTICS Sales.Orders IX_Orders_CustomerID
WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON;
```

### sp_updatestats

Updates **all** statistics in the current database, but only for statistics that have been modified since the last update.

```sql
-- Update all stale statistics in the database
EXEC sp_updatestats;

-- With RESAMPLE (preserves existing sample rates)
EXEC sp_updatestats 'resample';
```

**sp_updatestats behavior:**
- Checks the `modification_counter` in `sys.dm_db_stats_properties`.
- Only updates statistics where modifications have occurred.
- Uses the **default sample rate** (unless `'resample'` is specified).
- Efficient for a quick "refresh everything that needs it" approach.

### When to Use Which

| Scenario | Approach |
|----------|----------|
| Specific table after large data load | `UPDATE STATISTICS TableName WITH FULLSCAN` |
| Entire database routine maintenance | `EXEC sp_updatestats` or Ola Hallengren's scripts |
| Specific problematic statistics | `UPDATE STATISTICS TableName StatName WITH FULLSCAN` |
| After index rebuild | Not needed (REBUILD updates statistics with FULLSCAN automatically) |
| After index reorganize | Needed (REORGANIZE does NOT update statistics) |

---

## Trace Flag 2371: Dynamic Auto-Update Threshold

### The Problem with the Default Threshold

The default auto-update threshold of **20% of rows** is too high for large tables:

| Table Rows | Modifications to Trigger | Practical Impact |
|------------|-------------------------|------------------|
| 100 | 520 | Fine |
| 10,000 | 2,500 | Fine |
| 1,000,000 | 200,500 | May be stale |
| 100,000,000 | 20,000,500 | Severely stale |
| 1,000,000,000 | 200,000,500 | Catastrophically stale |

### Trace Flag 2371

Introduced in SQL Server 2008 R2 SP1, trace flag 2371 changes the threshold to a **dynamic, decreasing percentage** as the table grows:

```
For a table with n rows, the threshold becomes approximately:
sqrt(1000 * n)

Example:
  1,000,000 rows   -> ~31,623 modifications (3.2% instead of 20%)
  100,000,000 rows  -> ~316,228 modifications (0.3% instead of 20%)
  1,000,000,000 rows -> ~1,000,000 modifications (0.1% instead of 20%)
```

### Enabling Trace Flag 2371

```sql
-- Enable globally (survives restart if set as startup parameter)
DBCC TRACEON (2371, -1);

-- Check if enabled
DBCC TRACESTATUS (2371);

-- As a startup parameter: add -T2371 to SQL Server service startup parameters
```

### SQL Server 2016+ Behavior

Starting with **SQL Server 2016** (compatibility level 130+), the dynamic threshold behavior of TF 2371 is **enabled by default**. You no longer need to enable the trace flag explicitly if you are running at compatibility level 130 or higher.

```sql
-- Check your compatibility level
SELECT name, compatibility_level FROM sys.databases;
-- 130+ = dynamic threshold is the default
-- < 130 = still uses 20% threshold unless TF 2371 is on
```

---

## The Ascending Key Problem

### What It Is

When a column has a monotonically increasing pattern (identity, datetime, sequence), newly inserted values fall **beyond the range of the current histogram**. The histogram's last step has a RANGE_HI_KEY that was the maximum value at the time statistics were last updated.

When a query filters on a value newer than the last histogram step:

- **Legacy CE (CE 70)**: Estimates **1 row** for values beyond the histogram. This is usually a severe underestimate.
- **New CE (CE 120+)**: Uses the density vector to estimate rows for out-of-histogram values, typically producing a better (though still imperfect) estimate.

### Example

```sql
-- Table with identity-based OrderID, statistics last updated when max OrderID = 1,000,000
-- 50,000 new orders inserted (OrderID 1,000,001 to 1,050,000)

-- This query has ascending key problem:
SELECT * FROM Sales.Orders WHERE OrderID > 1,000,000;
-- Actual rows: 50,000
-- CE 70 estimate: 1 row (catastrophic underestimate)
-- CE 120+ estimate: ~50 rows to few hundred (better but still potentially underestimated)
```

### Mitigations

1. **Update statistics more frequently** after bulk inserts.
2. **Use trace flag 2371** (or compatibility level 130+) for more frequent auto-updates.
3. **Use the new cardinality estimator** (compatibility level 120+).
4. **Add `OPTION (RECOMPILE)`** for critical queries that always filter on recent data.
5. **Create filtered statistics** on recent data ranges (and periodically recreate).

```sql
-- Manual update after bulk insert
INSERT INTO Sales.Orders (...) SELECT ... FROM StagingTable;
UPDATE STATISTICS Sales.Orders WITH FULLSCAN;
```

---

## Legacy vs New Cardinality Estimator (CE70 vs CE120+)

### Overview

SQL Server has two cardinality estimator models:

| Aspect | Legacy CE (CE 70) | New CE (CE 120+) |
|--------|-------------------|-------------------|
| Introduced | SQL Server 7.0 (1998) | SQL Server 2014 |
| Default when | Compat level < 120 | Compat level >= 120 |
| Philosophy | Conservative, many hard-coded assumptions | More flexible, model-based |

### Key Differences in Assumptions

#### 1. Independence vs Correlation

**CE 70 (Independence assumption):**
Multiple predicates on different columns are assumed to be **independent**. Selectivities are multiplied:

```sql
-- CE 70: P(A AND B) = P(A) * P(B)
WHERE Country = 'USA' AND State = 'CA'
-- If P(Country='USA') = 0.3 and P(State='CA') = 0.05
-- CE 70 estimates: 0.3 * 0.05 = 0.015 (1.5% of rows)
-- Reality: States are correlated with countries! CA is only in USA.
-- Actual might be 5% of rows (or 0.05)
```

**CE 120+ (Exponential backoff):**
Uses a formula that assumes **partial correlation**. The most selective predicate gets full weight, additional predicates get diminishing weight:

```
Selectivity = S1 * S2^(1/2) * S3^(1/4) * S4^(1/8) ...
(where S1 <= S2 <= S3 ... most selective first)
```

This produces higher estimates than pure independence but lower than full correlation.

#### 2. Containment Assumption

**CE 70 (Simple containment):**
For joins, assumes that every value in the smaller table has a matching value in the larger table.

**CE 120+ (Base containment):**
Does not always assume full containment; uses statistics to make more nuanced join estimates.

#### 3. Ascending Key Handling

**CE 70:** Values beyond the histogram range estimate as **1 row** (the "ascending key problem").

**CE 120+:** Uses density-based estimation for beyond-histogram values, producing more reasonable estimates.

### Controlling the CE Version

```sql
-- Database-level: set compatibility level
ALTER DATABASE AdventureWorks SET COMPATIBILITY_LEVEL = 160;  -- SQL Server 2022, CE 160

-- Query-level: force a specific CE version
SELECT * FROM Sales.Orders
WHERE OrderDate > '2025-01-01'
OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'));  -- Force CE 70

SELECT * FROM Sales.Orders
WHERE OrderDate > '2025-01-01'
OPTION (USE HINT ('FORCE_DEFAULT_CARDINALITY_ESTIMATION'));  -- Force CE matching compat level

-- Query-level with trace flag
SELECT * FROM Sales.Orders
WHERE OrderDate > '2025-01-01'
OPTION (QUERYTRACEON 9481);  -- Force CE 70

SELECT * FROM Sales.Orders
WHERE OrderDate > '2025-01-01'
OPTION (QUERYTRACEON 2312);  -- Force CE 120+

-- Database-scoped configuration (SQL Server 2016+)
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = ON;  -- CE 70
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = OFF; -- New CE (default)
```

### Migration Considerations

When upgrading from CE 70 to CE 120+:

- **Most queries improve or stay the same.**
- **Some queries may regress** -- the new CE's assumptions may produce worse estimates for certain data patterns.
- **Strategy**: Upgrade the compatibility level, use Query Store to detect regressions, and force old plans for regressed queries while investigating fixes.
- **Do not stay on CE 70 forever** to avoid one or two regressions. The new CE improves with each version (CE 130, 140, 150, 160).

---

## Statistics on Computed Columns

SQL Server can create statistics on **computed columns**, even if the column is not persisted.

```sql
-- Computed column (not persisted)
ALTER TABLE Sales.Orders
ADD TotalWithTax AS (TotalAmount * 1.1);

-- Auto-create or manually create statistics
CREATE STATISTICS ST_Orders_TotalWithTax
ON Sales.Orders (TotalWithTax);

-- Now queries filtering on the computed expression can use these statistics
SELECT * FROM Sales.Orders WHERE TotalAmount * 1.1 > 5000;
-- The optimizer may match this expression to the computed column's statistics
```

### Important Notes

- The computed column must be **deterministic** and **precise** for statistics/index creation.
- Statistics on computed columns help when queries use the same expression, even without referencing the computed column by name.
- Creating an index on a computed column also creates statistics.

---

## Multi-Column Statistics

### Why Multi-Column Statistics Exist

Single-column statistics cannot capture **correlation between columns**. When two columns are correlated (e.g., City and State), the optimizer may severely underestimate or overestimate cardinality using single-column statistics alone.

### How They Work

- The **histogram** is built only on the **first (leading) column**.
- The **density vector** contains densities for all column combinations: `(Col1)`, `(Col1, Col2)`, `(Col1, Col2, Col3)`, etc.
- For predicates on non-leading columns, only the density vector is available (not the histogram).

```sql
-- Create multi-column statistics
CREATE STATISTICS ST_Orders_Cust_Status
ON Sales.Orders (CustomerID, Status);

-- This creates:
-- Histogram on CustomerID only
-- Density vector for (CustomerID) and (CustomerID, Status)
```

### When Multi-Column Statistics Help

```sql
-- Query with correlated predicates
SELECT COUNT(*) FROM Sales.Orders
WHERE CustomerID = 42 AND Status = 'Active';

-- With single-column statistics:
-- Optimizer uses independence: P(Cust=42) * P(Status='Active') * TotalRows
-- This may be wrong if customer 42's active rate differs from the average

-- With multi-column statistics (CustomerID, Status):
-- Optimizer can use the density of (CustomerID, Status) combination
-- Estimate = TotalRows * Density(CustomerID, Status) = potentially more accurate
```

### Auto-Created Multi-Column Statistics

SQL Server **does not** auto-create multi-column statistics. It only auto-creates single-column statistics. You must create multi-column statistics manually or via indexes (an index on `(A, B)` automatically has statistics on both columns).

### Creating Indexes vs Stand-Alone Statistics

If you need multi-column statistics but do not need the index:

```sql
-- Lightweight: just statistics, no index overhead
CREATE STATISTICS ST_Orders_City_State ON Sales.Orders (City, State);

-- Heavier: index (which includes statistics) -- only if queries also benefit from the index
CREATE INDEX IX_Orders_City_State ON Sales.Orders (City, State);
```

---

## sys.dm_db_stats_properties

This DMV provides detailed metadata about each statistics object, including modification counters and last update time.

```sql
-- View statistics properties for a specific table
SELECT
    OBJECT_NAME(sp.object_id) AS table_name,
    s.name AS statistics_name,
    s.auto_created,
    s.user_created,
    s.filter_definition,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.steps,                    -- histogram steps used
    sp.modification_counter,     -- modifications since last update
    sp.persisted_sample_percent  -- SQL Server 2016 SP2+
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE s.object_id = OBJECT_ID('Sales.Orders')
ORDER BY sp.modification_counter DESC;
```

### Finding Stale Statistics

```sql
-- Statistics with high modification counts relative to row count
SELECT
    OBJECT_SCHEMA_NAME(s.object_id) + '.' + OBJECT_NAME(s.object_id) AS table_name,
    s.name AS stats_name,
    sp.last_updated,
    sp.rows,
    sp.rows_sampled,
    sp.modification_counter,
    CAST(sp.modification_counter AS FLOAT) / NULLIF(sp.rows, 0) * 100
        AS modification_pct
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
WHERE sp.modification_counter > 0
  AND OBJECTPROPERTY(s.object_id, 'IsUserTable') = 1
ORDER BY modification_pct DESC;
```

### Incremental Statistics (Partitioned Tables, SQL Server 2014+)

For partitioned tables, incremental statistics maintain **per-partition statistics** that can be merged:

```sql
-- Create incremental statistics
CREATE STATISTICS ST_FactSales_Date
ON dbo.FactSales (SalesDate)
WITH FULLSCAN, INCREMENTAL = ON;

-- Update only the changed partition
UPDATE STATISTICS dbo.FactSales ST_FactSales_Date
WITH RESAMPLE ON PARTITIONS (5, 6);

-- View per-partition details
SELECT *
FROM sys.dm_db_incremental_stats_properties(
    OBJECT_ID('dbo.FactSales'),
    (SELECT stats_id FROM sys.stats
     WHERE object_id = OBJECT_ID('dbo.FactSales')
       AND name = 'ST_FactSales_Date')
);
```

---

## Common Interview Questions

### Q1: What are statistics in SQL Server and why are they important?

**A:** Statistics are objects that contain information about the distribution of values in one or more columns. They consist of a **histogram** (up to 200 steps showing value distribution for the leading column), a **density vector** (showing distinct value counts for column combinations), and optionally a **string index**. The query optimizer uses statistics to estimate cardinality (row counts) at each step of an execution plan. Accurate statistics lead to optimal plan choices; stale or missing statistics cause poor estimates, resulting in wrong join types, insufficient memory grants, and suboptimal execution plans.

### Q2: When do statistics get automatically updated?

**A:** Statistics auto-update when the **modification counter** exceeds a threshold. The legacy threshold (compatibility level < 130 without TF 2371) is **500 + 20% of table rows**. With TF 2371 or compatibility level 130+, the threshold is dynamic and decreasing -- approximately `sqrt(1000 * n)` modifications, which means large tables get updated much more frequently as a percentage. Auto-update is triggered at the beginning of the next query compilation that uses the stale statistics. It can be synchronous (default -- query waits) or asynchronous (query proceeds with old statistics).

### Q3: Explain the difference between the legacy and new cardinality estimator.

**A:** The **legacy CE (CE 70)** assumes independence between predicates (selectivities are multiplied), uses simple containment for joins, and estimates 1 row for values beyond the histogram range (ascending key problem). The **new CE (CE 120+)**, introduced in SQL Server 2014, uses exponential backoff to model partial correlation between predicates, has more nuanced join containment assumptions, and uses density-based estimation for beyond-histogram values. The new CE generally produces better estimates, especially for correlated predicates and ascending key patterns. It is controlled via database compatibility level or query-level hints.

### Q4: What is the ascending key problem?

**A:** When a column has monotonically increasing values (identity, datetime), new inserts create values beyond the last histogram step. The legacy CE estimates 1 row for these beyond-range values, causing severe underestimates. The new CE uses the density vector instead, producing better (though still imperfect) estimates. Mitigations include: frequent statistics updates after bulk loads, using TF 2371 or compat level 130+ for dynamic auto-update thresholds, using the new CE, and adding `OPTION (RECOMPILE)` for critical queries on recent data.

### Q5: What does DBCC SHOW_STATISTICS tell you?

**A:** It displays three components: (1) The **header** showing when statistics were last updated, total rows, rows sampled, number of histogram steps, and filter expression. (2) The **density vector** showing the density (1/distinct values) for each prefix combination of statistics columns. (3) The **histogram** with up to 200 steps, each showing the range high key, rows equal to that key, rows in the range between steps, distinct values in the range, and average rows per distinct value. This information tells you how the optimizer will estimate cardinality for various predicate values.

### Q6: When would you create multi-column statistics manually?

**A:** When queries frequently filter on **correlated columns** where the independence assumption produces bad estimates. For example, if queries filter on `City` and `State` together, the optimizer using separate single-column statistics would multiply selectivities (assuming independence), but these columns are highly correlated. Multi-column statistics on `(State, City)` provide a density vector for the combination that reflects the actual correlation. Note that the histogram is still only on the leading column. Multi-column statistics are also created automatically when you create a composite index.

### Q7: What is the difference between UPDATE STATISTICS and sp_updatestats?

**A:** `UPDATE STATISTICS` operates on a **specific table** (or specific statistics object within a table). You can control the sample rate, specify FULLSCAN, and target index or column statistics separately. `sp_updatestats` operates on the **entire database** and only updates statistics whose modification counters indicate changes since the last update. It uses the default sample rate unless `'resample'` is specified. Use `UPDATE STATISTICS` for targeted, precise control; use `sp_updatestats` for a quick broad refresh.

### Q8: How does sampling affect statistics accuracy?

**A:** By default, `UPDATE STATISTICS` samples a subset of rows to build the histogram. For small tables, it may scan all rows. For large tables, the default sample rate can be quite low. Sampling introduces approximation -- the histogram may miss data skew that a full scan would capture. **FULLSCAN** reads every row and produces the most accurate statistics, but takes longer and consumes more I/O. For critical tables with known skew, FULLSCAN is recommended. `PERSIST_SAMPLE_PERCENT` (SQL Server 2016 SP2+) ensures future auto-updates use the specified sample rate instead of the default.

### Q9: How do filtered statistics help query optimization?

**A:** Filtered statistics provide a histogram covering only a subset of rows (e.g., `WHERE Status = 'Active'`). This gives the optimizer a more precise distribution for queries targeting that subset, which is especially valuable for skewed data. For example, if only 2% of orders are 'Active', the standard histogram may not have enough granularity for that subset. Filtered statistics with 200 histogram steps dedicated to those 2% of rows provide much better estimates. However, filtered statistics are not auto-created and have limited interaction with parameterized queries.

### Q10: What should you check when a query suddenly starts performing badly?

**A:** Start with statistics: (1) Check `sys.dm_db_stats_properties` for high modification counters and stale `last_updated` dates. (2) Compare estimated vs actual rows in the actual execution plan -- large mismatches indicate statistics issues. (3) Look for implicit conversions causing non-SARGable predicates (new data types from application changes). (4) Check if a plan regression occurred using Query Store. (5) Verify if a large data load occurred without statistics updates. (6) For ascending key scenarios, check if new data is beyond the histogram range. The fix is often as simple as `UPDATE STATISTICS ... WITH FULLSCAN`.

---

## Tips for Senior Engineers

1. **Statistics are the #1 cause of bad plans.** Before blaming the optimizer, always check if statistics are current and accurate. A simple `UPDATE STATISTICS WITH FULLSCAN` resolves a surprisingly large percentage of "optimizer bugs."

2. **Always use compatibility level 130+ for the dynamic auto-update threshold.** The legacy 20% threshold is unacceptable for any table over a few million rows. If you cannot upgrade the compatibility level, enable TF 2371.

3. **FULLSCAN is worth it for critical tables.** The extra I/O during statistics update is negligible compared to hours of suboptimal query execution from sampled statistics that miss data skew.

4. **Use PERSIST_SAMPLE_PERCENT** (SQL Server 2016 SP2+) when you set a specific sample rate. Without it, the next auto-update reverts to the default sample rate, undoing your careful tuning.

5. **Update statistics after ETL loads.** A nightly ETL that loads millions of rows may not trigger auto-update thresholds until hours later. Add `UPDATE STATISTICS ... WITH FULLSCAN` as the last step of every ETL process.

6. **Understand the histogram's 200-step limit.** For tables with millions of distinct values, interpolation between steps is inevitable. Filtered statistics can provide better granularity for critical subsets.

7. **Multi-column statistics are underused.** If you have correlated columns and see cardinality mismatches on multi-predicate queries, create multi-column statistics. They are lightweight (no index maintenance overhead) and can significantly improve estimates.

8. **When upgrading CE versions, use Query Store as a safety net.** Enable Query Store before changing compatibility level. If a query regresses, force the old plan while you investigate. Never roll back the entire compatibility level for a few regressions.

9. **sys.dm_db_stats_properties is your monitoring friend.** Query it regularly to find statistics with high modification counts relative to row count. Proactive updates prevent the reactive "why is this query suddenly slow?" investigation.

10. **Index rebuilds update statistics; reorganize does not.** If your maintenance plan uses only reorganize for moderate fragmentation, you need a separate statistics update step. Ola Hallengren's maintenance solution handles this correctly with the `@UpdateStatistics` parameter.
