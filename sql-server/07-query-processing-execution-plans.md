# Query Processing & Execution Plans

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Query Processing Pipeline](#query-processing-pipeline)
2. [Parsing Phase](#parsing-phase)
3. [Binding (Algebrizer) Phase](#binding-algebrizer-phase)
4. [Query Optimization](#query-optimization)
5. [Trivial Plan Optimization](#trivial-plan-optimization)
6. [Full Optimization (Search Phases 0, 1, 2)](#full-optimization-search-phases-0-1-2)
7. [Estimated vs Actual Execution Plans](#estimated-vs-actual-execution-plans)
8. [Common Execution Plan Operators](#common-execution-plan-operators)
9. [Reading Execution Plans](#reading-execution-plans)
10. [SET STATISTICS IO and TIME](#set-statistics-io-and-time)
11. [SARGability](#sargability)
12. [Key Lookups](#key-lookups)
13. [Plan Guides and Forced Parameterization](#plan-guides-and-forced-parameterization)
14. [Plan Freezing](#plan-freezing)
15. [XML Showplan and Graphical Plan Analysis](#xml-showplan-and-graphical-plan-analysis)
16. [Common Interview Questions](#common-interview-questions)
17. [Tips for Senior Engineers](#tips-for-senior-engineers)

---

## Query Processing Pipeline

Every T-SQL statement that SQL Server executes follows a well-defined pipeline before any data is returned. Understanding this pipeline is critical for diagnosing performance issues and explaining optimizer behavior in interviews.

The high-level stages are:

1. **Parsing** - Syntax validation, production of a parse tree
2. **Binding (Algebrizer)** - Name resolution, type derivation, aggregate binding
3. **Optimization** - Cost-based plan selection
4. **Execution** - The chosen plan is executed by the storage engine

```
T-SQL Statement
    |
    v
[ Parser ] --> Parse Tree
    |
    v
[ Algebrizer ] --> Query Processor Tree (Algebrizer Tree)
    |
    v
[ Optimizer ] --> Execution Plan (compiled plan stored in plan cache)
    |
    v
[ Execution Engine ] --> Results
```

---

## Parsing Phase

The **Parser** is the first component to handle a submitted query. Its job is purely syntactic:

- Validates T-SQL syntax against grammar rules.
- Tokenizes the input into language elements (keywords, identifiers, operators, literals).
- Produces a **parse tree** (also called a syntax tree).
- Does **not** check whether tables, columns, or other objects actually exist.

A parsing error results in a message like:

```
Msg 102, Level 15, State 1
Incorrect syntax near '...'.
```

**Key point:** Because parsing does not check object existence, you can parse a query referencing a table that does not exist and it will pass parsing. The error will come in the next phase.

---

## Binding (Algebrizer) Phase

After parsing, the **Algebrizer** (sometimes called the Binder) takes the parse tree and performs:

- **Name resolution** - Verifies that referenced tables, columns, functions, and other objects actually exist in the database.
- **Type derivation** - Determines data types of expressions and checks for implicit conversions.
- **Aggregate binding** - Associates aggregate functions (SUM, COUNT, etc.) with the correct GROUP BY scope.
- **Subquery unnesting** - Where possible, converts correlated subqueries into joins.

The output is a **query processor tree** (algebrizer tree), which is a logical representation of the query. This tree is passed to the optimizer.

Errors at this stage look like:

```
Msg 208, Level 16, State 1
Invalid object name 'dbo.NonExistentTable'.

Msg 207, Level 16, State 1
Invalid column name 'NonExistentColumn'.
```

---

## Query Optimization

The SQL Server **Query Optimizer** is a cost-based optimizer. It does not search every possible plan; instead, it uses heuristics to explore a subset of the plan space and picks the plan with the lowest estimated cost.

### How Cost Is Estimated

- The optimizer uses **statistics** (histograms, density vectors) to estimate the number of rows (cardinality) flowing through each operator.
- Each operator has a CPU cost and an I/O cost formula.
- The total plan cost is the sum of all operator costs.
- Costs are expressed in abstract **cost units** (not seconds or bytes), calibrated to an older hardware profile.

### Optimization Stages

The optimizer proceeds through distinct stages, and may stop early if a "good enough" plan is found:

1. **Simplification** - Applies logical transformations (e.g., predicate pushdown, contradiction detection, constant folding).
2. **Trivial Plan** - Checks if there is an obviously optimal plan.
3. **Full Optimization** - Cost-based search through three phases.

---

## Trivial Plan Optimization

Before investing in full cost-based optimization, SQL Server checks whether there is only one reasonable plan for the query. This is the **Trivial Plan** stage.

**Conditions that typically produce a trivial plan:**

- Simple SELECT on a heap with no indexes (full table scan is the only option).
- Single-table INSERT with no triggers.
- Queries where no meaningful alternative plans exist.

**Conditions that prevent a trivial plan:**

- Joins (multiple join orders possible).
- Subqueries.
- Hints.
- Multiple candidate indexes.

You can see whether a query received a trivial plan by examining the execution plan's properties:

```sql
-- In the execution plan XML, look for:
-- StatementOptmLevel="TRIVIAL"
-- vs
-- StatementOptmLevel="FULL"
```

**Why it matters:** Trivial plans are very cheap to compile. They skip the expensive cost-based search entirely, keeping compile times minimal for simple queries.

---

## Full Optimization (Search Phases 0, 1, 2)

When a trivial plan is not possible, the optimizer enters **Full Optimization**, which consists of up to three search phases. Each phase applies increasingly aggressive (and expensive) transformation rules.

### Search Phase 0 - Transaction Processing

- Applies a limited set of transformation rules.
- Targets simple OLTP-style queries (a few joins, basic predicates).
- If the best plan found has a cost below the **Phase 0 threshold**, optimization stops here.
- Very fast; handles the majority of typical OLTP queries.

### Search Phase 1 - Quick Plan

- Expands the set of transformation rules.
- Explores more join orders and access path alternatives.
- Includes parallel plan consideration.
- If the best plan cost is below the **Phase 1 threshold**, optimization stops.

### Search Phase 2 - Full Optimization

- Uses the complete set of transformation rules.
- Explores complex strategies: indexed view matching, advanced join reordering, additional parallelism strategies.
- Runs when the query is genuinely complex (many joins, complex subqueries).
- Has a time-based budget; may still stop before exploring all possibilities.

You can determine which phase was used via the execution plan XML:

```xml
<StatementOptmEarlyAbortReason="GoodEnoughPlanFound" />
<!-- or -->
<StatementOptmEarlyAbortReason="TimeOut" />
```

```sql
-- Check optimization level and early abort reason in plan properties
-- Right-click on the root SELECT operator in SSMS graphical plan
-- Look at:
--   "Optimization Level"  => TRIVIAL or FULL
--   "Reason for Early Termination" => Good Enough Plan Found, Time Out, or empty
```

---

## Estimated vs Actual Execution Plans

### Estimated Execution Plan

- Generated **without executing** the query.
- Shows the optimizer's chosen plan based on statistics and cardinality estimates.
- Displays **estimated rows**, **estimated cost**, **estimated executions**.
- Obtained via:

```sql
-- SSMS: Ctrl+L or Display Estimated Execution Plan button
SET SHOWPLAN_XML ON;
GO
SELECT * FROM Sales.Orders WHERE OrderDate > '2025-01-01';
GO
SET SHOWPLAN_XML OFF;
GO

-- Or text format:
SET SHOWPLAN_TEXT ON;
GO
SELECT * FROM Sales.Orders WHERE OrderDate > '2025-01-01';
GO
SET SHOWPLAN_TEXT OFF;
GO
```

### Actual Execution Plan

- Generated **after executing** the query.
- Contains everything the estimated plan has, **plus** runtime statistics: actual rows, actual executions, actual elapsed time, memory grants, actual I/O, wait stats (SQL Server 2016+).
- Critical for finding **estimation errors** (estimated vs actual row mismatch).
- Obtained via:

```sql
-- SSMS: Ctrl+M or Include Actual Execution Plan button, then execute
SET STATISTICS XML ON;
GO
SELECT * FROM Sales.Orders WHERE OrderDate > '2025-01-01';
GO
SET STATISTICS XML OFF;
GO
```

### Live Query Statistics (SQL Server 2016+)

- Shows the execution plan with real-time row flow during query execution.
- Useful for long-running queries to see where time is being spent.
- Available via SSMS: Query > Include Live Query Statistics.

### Key Differences Summary

| Aspect | Estimated Plan | Actual Plan |
|--------|---------------|-------------|
| Query Executed? | No | Yes |
| Actual Rows | Not available | Available |
| Actual Elapsed Time | Not available | Available |
| Memory Grant Info | Estimated only | Estimated + Actual used |
| Wait Statistics | Not available | Available (2016+) |
| Safe on Production? | Yes (no execution) | Caution (executes the query) |

---

## Common Execution Plan Operators

### Data Access Operators

#### Table Scan
- Reads **every row** of a heap (table without a clustered index).
- Not necessarily bad for small tables; problematic for large tables.

#### Clustered Index Scan
- Reads **every row** via the clustered index leaf level.
- Logically equivalent to a table scan but on a table with a clustered index.

#### Clustered Index Seek
- Uses the B-tree structure to navigate directly to specific rows.
- Highly efficient; indicates a good predicate matching the clustered index key.

#### Non-Clustered Index Scan
- Reads the entire non-clustered index leaf level.
- Cheaper than a clustered index scan if the index is narrower (fewer columns) and covers the query.

#### Non-Clustered Index Seek
- Navigates the non-clustered B-tree to find specific rows.
- Often followed by a **Key Lookup** if additional columns are needed.

#### Key Lookup (Bookmark Lookup)
- Occurs when a non-clustered index seek finds the rows but the index does not contain all columns needed by the query.
- Performs a point lookup into the clustered index for each row.
- Extremely expensive at scale (row-by-row random I/O).

```sql
-- Example that causes a key lookup
-- Index on OrderDate, but query also needs CustomerName
CREATE INDEX IX_Orders_OrderDate ON Sales.Orders(OrderDate);

SELECT OrderDate, CustomerName
FROM Sales.Orders
WHERE OrderDate = '2025-06-15';
-- Plan: Index Seek (IX_Orders_OrderDate) + Key Lookup (clustered index)

-- Fix: covering index
CREATE INDEX IX_Orders_OrderDate_Covering
ON Sales.Orders(OrderDate)
INCLUDE (CustomerName);
```

### Join Operators

#### Nested Loops Join
- For each row in the **outer (top) input**, scans the **inner (bottom) input**.
- Best when the outer input is small and the inner input has an efficient seek.
- O(N * M) worst case but with seeks on inner input effectively O(N * log M).
- Supports all join types; the only operator that supports non-equi joins efficiently.

#### Hash Match Join
- Builds a **hash table** from the smaller (build) input.
- Probes the hash table with each row from the larger (probe) input.
- Requires memory grant; can **spill to tempdb** if estimate is wrong.
- Best for large, unsorted inputs with no useful indexes.
- Only supports equi-joins.

#### Merge Join
- Requires both inputs to be **sorted** on the join key (or an index provides the order).
- Walks through both inputs simultaneously.
- Very efficient for large, pre-sorted datasets.
- Only supports equi-joins (and inequality with many-to-many).
- O(N + M) when inputs are already sorted.

```
Join Selection Heuristic (simplified):
- Small outer, indexed inner  --> Nested Loops
- Large unsorted inputs        --> Hash Match
- Large pre-sorted inputs      --> Merge Join
```

### Other Common Operators

#### Sort
- Orders rows; requires a **memory grant**.
- Can spill to tempdb if memory is insufficient, severely degrading performance.
- Watch for unexpected sorts -- often indicates a missing index.

#### Stream Aggregate
- Computes aggregates (SUM, COUNT, etc.) on pre-sorted input.
- Efficient; processes one row at a time.

#### Hash Aggregate (Hash Match - Aggregate)
- Computes aggregates using a hash table.
- Used when input is not sorted on the grouping columns.
- Requires memory grant; can spill.

#### Spool (Table Spool / Index Spool)
- Stores intermediate results in a worktable (tempdb).
- **Eager Spool**: Reads all rows first, then replays.
- **Lazy Spool**: Reads and caches on demand.
- Can indicate suboptimal plans or Halloween Protection.

#### Compute Scalar
- Evaluates scalar expressions (calculations, type conversions).
- Usually lightweight but watch for expensive function calls.

#### Filter
- Applies a predicate that could not be pushed further down.
- May indicate residual predicates after an index seek.

#### Parallelism (Distribute Streams / Gather Streams / Repartition Streams)
- **Distribute Streams**: Splits rows across parallel threads.
- **Gather Streams**: Combines parallel threads back to one.
- **Repartition Streams**: Redistributes rows among threads (e.g., for a parallel hash join on a different key).

#### Adaptive Join (SQL Server 2017+)
- Defers the choice between Nested Loops and Hash Match until runtime.
- If actual row count is below a threshold, uses Nested Loops; otherwise Hash Match.

---

## Reading Execution Plans

### Direction of Data Flow

- In the graphical plan, data flows from **right to left**.
- Operators on the right produce rows; operators on the left consume them.
- The leftmost operator is the final result (SELECT, INSERT, UPDATE, DELETE).

### Arrow Thickness

- Arrow thickness represents **estimated row count** (estimated plan) or **actual row count** (actual plan).
- A sudden thick arrow becoming thin (or vice versa) indicates a cardinality estimation error.

### Operator Cost Percentages

- Each operator shows a **relative cost percentage** within the plan.
- Useful for quickly identifying the most expensive operator.
- **Warning**: These are estimated costs even in an actual plan; actual time may differ.

### Warning Signs in Plans

| Warning | Meaning |
|---------|---------|
| Yellow triangle (!) | Warning on an operator (missing statistics, implicit conversion, etc.) |
| Fat arrows | Large number of rows flowing -- potential performance concern |
| Key Lookup | Index not covering; row-by-row lookups into clustered index |
| Sort with spill | Memory grant insufficient; spillover to tempdb |
| Hash spill | Hash join/aggregate ran out of memory |
| Estimated vs Actual row mismatch | Statistics are stale or cardinality estimator made a bad guess |
| Parallelism with skew | One thread does all the work; others idle |

### Systematic Approach to Plan Analysis

1. **Start at the leftmost operator** -- check total estimated cost and subtree cost.
2. **Identify the most expensive operator** by cost percentage.
3. **Compare estimated vs actual rows** at every operator (actual plan only).
4. **Look for warnings** (yellow triangles).
5. **Check for Key Lookups** -- can they be eliminated with covering indexes?
6. **Check for Scans** -- should they be Seeks?
7. **Examine join types** -- are they appropriate for the data volumes?
8. **Check for Sort spills** via actual plan properties.
9. **Review memory grant** -- was the granted memory used or wasted?

---

## SET STATISTICS IO and TIME

These are essential tools for measuring query performance beyond execution plans.

### SET STATISTICS IO ON

Shows the logical and physical I/O for each table referenced:

```sql
SET STATISTICS IO ON;
GO

SELECT o.OrderID, c.CustomerName
FROM Sales.Orders o
JOIN Sales.Customers c ON o.CustomerID = c.CustomerID
WHERE o.OrderDate > '2025-01-01';
GO

SET STATISTICS IO OFF;
GO
```

**Sample output:**

```
Table 'Orders'. Scan count 1, logical reads 423, physical reads 12,
  read-ahead reads 400, lob logical reads 0, lob physical reads 0,
  lob read-ahead reads 0.
Table 'Customers'. Scan count 0, logical reads 3540, physical reads 0,
  read-ahead reads 0, lob logical reads 0, lob physical reads 0,
  lob read-ahead reads 0.
```

**Key metrics:**

| Metric | Meaning |
|--------|---------|
| **Scan count** | Number of seeks/scans initiated. 0 = single lookup per row (nested loops inner). 1 = one scan. N = N seeks from nested loops. |
| **Logical reads** | Pages read from the buffer pool (memory). **Primary tuning metric.** |
| **Physical reads** | Pages read from disk (cold cache). |
| **Read-ahead reads** | Pages read proactively by the read-ahead mechanism. |
| **LOB reads** | Pages for large object data (text, image, varchar(max), etc.). |

**Why logical reads matter most:** Logical reads reflect the total I/O workload regardless of caching. A query that does 50,000 logical reads is doing 50,000 page accesses. Even if all are from cache, at scale and concurrency this impacts CPU and latch contention.

### SET STATISTICS TIME ON

Shows parse/compile time and execution time:

```sql
SET STATISTICS TIME ON;
GO

SELECT * FROM Sales.Orders WHERE OrderDate > '2025-01-01';
GO

SET STATISTICS TIME OFF;
GO
```

**Sample output:**

```
SQL Server parse and compile time:
   CPU time = 12 ms, elapsed time = 45 ms.

SQL Server Execution Times:
   CPU time = 156 ms, elapsed time = 203 ms.
```

**Key distinction:**
- **CPU time** = actual processor time consumed.
- **Elapsed time** = wall-clock time (includes waits for I/O, locks, memory, network, etc.).
- If elapsed >> CPU, the query is waiting on something (disk, blocking, memory grant).
- If CPU >> elapsed (rare in serial plans, common in parallel plans), multiple threads are working.

---

## SARGability

**SARG** = **S**earch **ARG**ument. A predicate is **SARGable** if SQL Server can use an index seek to evaluate it.

### SARGable Predicates

```sql
-- SARGable: index on OrderDate can be seeked
WHERE OrderDate >= '2025-01-01'
WHERE OrderDate BETWEEN '2025-01-01' AND '2025-12-31'
WHERE OrderDate = '2025-06-15'
WHERE CustomerName LIKE 'Smith%'     -- leading wildcard-free
WHERE CustomerID IN (1, 2, 3)
```

### Non-SARGable Predicates

```sql
-- Non-SARGable: function on column prevents seek
WHERE YEAR(OrderDate) = 2025
WHERE CONVERT(VARCHAR, OrderDate, 112) = '20250615'
WHERE LEFT(CustomerName, 3) = 'Smi'
WHERE CustomerName LIKE '%Smith%'    -- leading wildcard
WHERE OrderTotal * 1.1 > 1000       -- expression on column
WHERE ISNULL(ShipDate, '1900-01-01') > '2025-01-01'
```

### Fixing Non-SARGable Predicates

```sql
-- Instead of YEAR(OrderDate) = 2025:
WHERE OrderDate >= '2025-01-01' AND OrderDate < '2026-01-01'

-- Instead of CONVERT(VARCHAR, OrderDate, 112) = '20250615':
WHERE OrderDate = '2025-06-15'

-- Instead of LEFT(CustomerName, 3) = 'Smi':
WHERE CustomerName LIKE 'Smi%'

-- Instead of ISNULL(ShipDate, '1900-01-01') > '2025-01-01':
WHERE ShipDate > '2025-01-01'
-- (if NULL rows should be included, use OR ShipDate IS NULL separately)

-- Instead of OrderTotal * 1.1 > 1000:
WHERE OrderTotal > 1000 / 1.1
```

### Implicit Conversions and SARGability

Implicit conversions can silently destroy SARGability:

```sql
-- Column is VARCHAR, parameter is NVARCHAR
-- SQL Server must convert every row's VARCHAR to NVARCHAR (lower precedence -> higher)
-- This makes the predicate non-SARGable!
DECLARE @SearchName NVARCHAR(100) = N'Smith';
SELECT * FROM Customers WHERE LastName = @SearchName;
-- LastName is VARCHAR(100) -- implicit CONVERT(NVARCHAR, LastName) applied per row

-- Fix: match the data type
DECLARE @SearchName VARCHAR(100) = 'Smith';
SELECT * FROM Customers WHERE LastName = @SearchName;
```

---

## Key Lookups

A **Key Lookup** (called **Bookmark Lookup** in older versions) occurs when:

1. A non-clustered index seek or scan finds the rows matching the predicate.
2. But the non-clustered index does not contain all columns needed (SELECT list, other predicates, ORDER BY, etc.).
3. SQL Server must go back to the clustered index (or heap via RID Lookup) to fetch the missing columns.

### Why Key Lookups Are Expensive

- Each lookup is a **random I/O** operation into the clustered index B-tree.
- For N rows from the index seek, N separate key lookups are performed.
- At small scale (tens of rows), the cost is negligible.
- At large scale (thousands+ rows), the optimizer may switch to a full clustered index scan instead, which is a red flag that your index strategy needs improvement.

### Identifying Key Lookups

In the execution plan, you will see:
- **Nested Loops** joining an **Index Seek** (outer) with a **Key Lookup** (inner).
- The Key Lookup operator's properties show the **Output List** -- these are the columns that were missing from the non-clustered index.

### Eliminating Key Lookups

```sql
-- Original: Key Lookup needed for CustomerName and TotalAmount
CREATE INDEX IX_Orders_OrderDate ON Sales.Orders(OrderDate);

SELECT OrderDate, CustomerName, TotalAmount
FROM Sales.Orders
WHERE OrderDate = '2025-06-15';

-- Solution 1: INCLUDE the missing columns
CREATE INDEX IX_Orders_OrderDate_v2
ON Sales.Orders(OrderDate)
INCLUDE (CustomerName, TotalAmount);

-- Solution 2: Make it a composite key (if columns are used in predicates/sorting)
CREATE INDEX IX_Orders_OrderDate_Customer
ON Sales.Orders(OrderDate, CustomerName)
INCLUDE (TotalAmount);
```

---

## Plan Guides and Forced Parameterization

### Plan Guides

Plan guides allow you to attach query hints to queries **without modifying the application code**. This is valuable when you cannot change the SQL being submitted (third-party application, ORM-generated queries).

Three types of plan guides:

#### 1. OBJECT Plan Guide
Matches queries inside a specific stored procedure or function:

```sql
EXEC sp_create_plan_guide
    @name = N'PG_GetOrders_ForceSeek',
    @stmt = N'SELECT OrderID, OrderDate
              FROM Sales.Orders
              WHERE OrderDate > @StartDate',
    @type = N'OBJECT',
    @module_or_batch = N'dbo.GetOrders',
    @params = NULL,
    @hints = N'OPTION (TABLE HINT(Sales.Orders, FORCESEEK))';
```

#### 2. SQL Plan Guide
Matches a specific standalone SQL statement:

```sql
EXEC sp_create_plan_guide
    @name = N'PG_AdHoc_Orders',
    @stmt = N'SELECT * FROM Sales.Orders WHERE Status = @p0',
    @type = N'SQL',
    @module_or_batch = NULL,
    @params = N'@p0 INT',
    @hints = N'OPTION (RECOMPILE)';
```

#### 3. TEMPLATE Plan Guide
Forces parameterization behavior for a query template:

```sql
DECLARE @stmt NVARCHAR(MAX);
DECLARE @params NVARCHAR(MAX);

EXEC sp_get_query_template
    N'SELECT * FROM Sales.Orders WHERE OrderID = 42',
    @stmt OUTPUT,
    @params OUTPUT;

EXEC sp_create_plan_guide
    @name = N'PG_Template_OrderByID',
    @stmt = @stmt,
    @type = N'TEMPLATE',
    @module_or_batch = NULL,
    @params = @params,
    @hints = N'OPTION (PARAMETERIZATION FORCED)';
```

### Managing Plan Guides

```sql
-- Validate plan guides
SELECT * FROM sys.plan_guides;

-- Validate a specific guide
SELECT plan_guide_id, name, is_disabled
FROM sys.plan_guides;

-- Drop a plan guide
EXEC sp_control_plan_guide N'DROP', N'PG_GetOrders_ForceSeek';

-- Disable a plan guide
EXEC sp_control_plan_guide N'DISABLE', N'PG_GetOrders_ForceSeek';

-- Drop all plan guides
EXEC sp_control_plan_guide N'DROP ALL';
```

### Forced Parameterization

By default, SQL Server uses **Simple Parameterization** -- only trivially simple queries get auto-parameterized. This can lead to excessive plan compilation for ad-hoc workloads.

```sql
-- Enable forced parameterization at the database level
ALTER DATABASE AdventureWorks SET PARAMETERIZATION FORCED;

-- Check current setting
SELECT name, is_parameterization_forced
FROM sys.databases
WHERE name = 'AdventureWorks';
```

**When to use Forced Parameterization:**
- High-volume OLTP systems with many ad-hoc queries that differ only in literal values.
- Plan cache bloat from thousands of unique plans for essentially the same query.

**Risks:**
- Can cause parameter sniffing problems (one plan for all parameter values).
- May choose a poor plan for skewed data distributions.
- Cannot be selectively applied (except via TEMPLATE plan guides to override specific queries back to SIMPLE).

---

## Plan Freezing

**Plan freezing** (also called plan forcing) locks a specific execution plan for a query, preventing the optimizer from choosing a different plan.

### Using Query Store (SQL Server 2016+) -- Recommended Approach

```sql
-- Enable Query Store
ALTER DATABASE AdventureWorks SET QUERY_STORE = ON;

-- Force a specific plan
EXEC sp_query_store_force_plan @query_id = 42, @plan_id = 7;

-- Unforce a plan
EXEC sp_query_store_unforce_plan @query_id = 42, @plan_id = 7;

-- View forced plans
SELECT q.query_id, p.plan_id, p.is_forced_plan, qt.query_sql_text
FROM sys.query_store_plan p
JOIN sys.query_store_query q ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE p.is_forced_plan = 1;
```

### Using USE PLAN Hint

```sql
-- Capture the XML plan first, then force it
DECLARE @xml_plan NVARCHAR(MAX) = N'<ShowPlanXML ...>...</ShowPlanXML>';

SELECT OrderID, OrderDate
FROM Sales.Orders
WHERE OrderDate > '2025-01-01'
OPTION (USE PLAN @xml_plan);
```

### Risks of Plan Freezing

- The frozen plan may become suboptimal as data changes.
- Schema changes that invalidate the plan will cause errors.
- Must be monitored and periodically reviewed.

---

## XML Showplan and Graphical Plan Analysis

### Retrieving XML Plans

```sql
-- Method 1: SET SHOWPLAN_XML (estimated plan, does not execute)
SET SHOWPLAN_XML ON;
GO
SELECT * FROM Sales.Orders WHERE OrderDate > '2025-01-01';
GO
SET SHOWPLAN_XML OFF;
GO

-- Method 2: SET STATISTICS XML (actual plan, executes the query)
SET STATISTICS XML ON;
GO
SELECT * FROM Sales.Orders WHERE OrderDate > '2025-01-01';
GO
SET STATISTICS XML OFF;
GO

-- Method 3: From plan cache
SELECT
    qs.execution_count,
    qs.total_logical_reads,
    qs.total_elapsed_time,
    qp.query_plan,  -- XML plan
    st.text          -- SQL text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
ORDER BY qs.total_logical_reads DESC;

-- Method 4: From Query Store
SELECT
    qt.query_sql_text,
    p.query_plan  -- XML plan
FROM sys.query_store_plan p
JOIN sys.query_store_query q ON p.query_id = q.query_id
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id;
```

### Key Elements in XML Showplan

```xml
<ShowPlanXML>
  <BatchSequence>
    <Batch>
      <Statements>
        <StmtSimple StatementText="..."
                    StatementOptmLevel="FULL"
                    StatementSubTreeCost="0.234"
                    StatementEstRows="150">
          <QueryPlan DegreeOfParallelism="4"
                     MemoryGrant="1024"
                     CachedPlanSize="48">
            <RelOp NodeId="0" PhysicalOp="Clustered Index Seek"
                   LogicalOp="Clustered Index Seek"
                   EstimateRows="150"
                   EstimateIO="0.05"
                   EstimateCPU="0.001"
                   AvgRowSize="120"
                   EstimatedTotalSubtreeCost="0.051"
                   ActualRows="148"          <!-- actual plan only -->
                   ActualExecutions="1">     <!-- actual plan only -->
              ...
            </RelOp>
          </QueryPlan>
        </StmtSimple>
      </Statements>
    </Batch>
  </BatchSequence>
</ShowPlanXML>
```

### Graphical Plan Analysis Tips

1. **Right-click the root (SELECT) operator** to see overall plan properties: optimization level, memory grant, degree of parallelism, parameter list with compiled and runtime values.
2. **Hover over arrows** to see row estimates and actual rows.
3. **Hover over operators** to see detailed properties: output list, predicates, seek predicates, estimated vs actual rows.
4. **Look for thick arrows** that suddenly become thin -- this signals a bad estimate.
5. **Check the Properties window** (F4) for full details including actual time statistics per operator (SQL Server 2016+ with actual plan).

### Tools for Plan Analysis

- **SSMS** - Built-in graphical plan viewer.
- **Azure Data Studio** - Plan viewer extension.
- **Plan Explorer (SentryOne)** - Free, advanced plan analysis tool with statement-level metrics.
- **Paste The Plan (Brent Ozar)** - Online plan sharing and analysis at pastetheplan.com.

---

## Common Interview Questions

### Q1: Walk me through what happens when SQL Server receives a query.

**A:** The query passes through four stages: (1) **Parsing** validates syntax and produces a parse tree. (2) **Binding/Algebrizer** resolves object names, validates column references, derives data types, and produces a query processor tree. (3) **Optimization** takes the logical tree and searches for an efficient physical execution plan using cost-based optimization -- it starts with simplification, tries a trivial plan, and if needed enters full optimization with up to three search phases. (4) **Execution** runs the chosen plan against the storage engine, returning results to the client. The compiled plan is typically cached for reuse.

### Q2: What is the difference between an estimated and actual execution plan?

**A:** An estimated plan is generated without executing the query and shows only estimated row counts and costs. An actual plan is generated after execution and includes runtime metrics: actual rows, actual executions, memory grant used, wait statistics (2016+), and elapsed time per operator. The actual plan is essential for diagnosing estimation errors. One critical point: the **cost percentages** shown in an actual plan are still *estimated* costs, not actual measured costs.

### Q3: When would you see a Hash Match join vs a Nested Loops join?

**A:** **Nested Loops** is preferred when the outer input is small and the inner input has an efficient index seek -- it excels in OLTP point-lookup scenarios. **Hash Match** is chosen when both inputs are large, unsorted, and there are no useful indexes on the join columns. Hash Match builds a hash table from the smaller input and probes it with the larger input. It requires a memory grant and only supports equi-joins. **Merge Join** is a third option, chosen when both inputs are already sorted on the join key.

### Q4: What is SARGability and why does it matter?

**A:** SARGability (Search ARGument ability) refers to whether a predicate allows the optimizer to use an index seek. A predicate is SARGable when the column appears without modification (no functions, no expressions, no implicit conversions on the column side). Non-SARGable predicates force index or table scans. For example, `WHERE YEAR(OrderDate) = 2025` is non-SARGable because the function wraps the column, but `WHERE OrderDate >= '2025-01-01' AND OrderDate < '2026-01-01'` is SARGable and allows an index seek.

### Q5: How do you eliminate a Key Lookup?

**A:** A Key Lookup occurs when a non-clustered index does not contain all columns needed by the query. To eliminate it, create a **covering index** by adding the missing columns as INCLUDE columns (if they are only needed in the SELECT or as residual predicates) or as key columns (if they participate in WHERE, ORDER BY, or JOIN conditions). Check the Key Lookup operator's Output List in the plan to see exactly which columns are missing.

### Q6: What is the difference between logical reads and physical reads? Which is more important for tuning?

**A:** **Logical reads** count pages accessed from the buffer pool (memory). **Physical reads** count pages that had to be fetched from disk because they were not cached. For tuning, **logical reads are the primary metric** because they represent the total I/O workload regardless of caching state. A query with high logical reads will always consume significant resources; physical reads depend on what happens to be in cache, which varies.

### Q7: Explain plan guides. When would you use them?

**A:** Plan guides attach query hints to SQL statements without modifying application code. They are useful when you cannot change the SQL (third-party apps, ORM-generated queries) but need to influence plan selection -- for example, forcing a recompile, adding index hints, or changing parameterization behavior. There are three types: OBJECT (targets queries in specific procedures), SQL (targets standalone statements), and TEMPLATE (controls parameterization). With Query Store available in SQL Server 2016+, **plan forcing via Query Store is generally preferred** over plan guides.

### Q8: What is forced parameterization and when is it appropriate?

**A:** Forced parameterization makes SQL Server parameterize virtually all literal values in ad-hoc queries, allowing plan reuse across different literal values. It is appropriate for high-volume OLTP workloads suffering from plan cache bloat due to thousands of nearly identical ad-hoc queries. The risk is that it can introduce parameter sniffing problems where a single cached plan is suboptimal for some parameter values. It is a database-level setting and cannot be selectively applied except through TEMPLATE plan guides that override specific queries back to simple parameterization.

### Q9: How do the optimizer's search phases work, and why does it matter?

**A:** After failing to find a trivial plan, the optimizer enters full optimization with three search phases. **Phase 0** (Transaction Processing) uses limited rules targeting simple OLTP queries and stops if a cheap enough plan is found. **Phase 1** (Quick Plan) uses more rules and considers parallelism. **Phase 2** (Full) uses all rules including indexed view matching and advanced join reordering, with a time-based budget. Understanding this helps explain why the optimizer sometimes misses a better plan -- complex queries may hit the time budget in Phase 2 before exploring the optimal solution, which is why hints or plan guides are occasionally necessary.

### Q10: How do you use Query Store for plan regression troubleshooting?

**A:** Query Store captures query text, execution plans, and runtime statistics over time. To troubleshoot plan regression: (1) Use the "Regressed Queries" report in SSMS to find queries whose performance degraded. (2) Compare the old (fast) plan with the new (slow) plan. (3) Force the known-good plan using `sp_query_store_force_plan`. (4) Investigate why the regression occurred (stale statistics, schema change, parameter sniffing). Query Store effectively makes plan freezing a first-class, manageable feature.

---

## Tips for Senior Engineers

1. **Always use actual execution plans for tuning** -- estimated plans hide the truth about row estimates vs reality. Use estimated plans only when you cannot afford to execute the query (e.g., expensive DML on production).

2. **Logical reads are your single best tuning metric.** Compare logical reads before and after index or query changes. If logical reads drop significantly, performance has improved regardless of timing fluctuations.

3. **Do not chase cost percentages blindly.** The cost shown on operators is the optimizer's estimate, not actual measured time. A 1% cost operator can be the actual bottleneck if its estimates are wrong.

4. **SARGability is the #1 index-usage killer.** Always check predicates for functions on columns, implicit conversions, and expressions. A well-indexed table is worthless if the query prevents seeking.

5. **Key Lookups are the most common "easy win."** Check the Output List on Key Lookup operators and add INCLUDE columns to existing indexes. This is often the simplest and highest-impact optimization.

6. **Use Query Store instead of plan guides when possible.** Query Store provides a more maintainable and visible mechanism for plan forcing, regression detection, and performance baselining.

7. **Beware of parameter sniffing in conjunction with plan caching.** The first execution's parameter values determine the cached plan. Use `OPTION (RECOMPILE)`, `OPTIMIZE FOR`, or Query Store to manage this.

8. **Learn to read XML plans.** Graphical plans in SSMS are useful but limited. The XML contains details not visible in the graphical view: actual time per operator, thread distribution in parallel plans, residual predicates vs seek predicates.

9. **Combine STATISTICS IO with execution plans.** The plan shows you the shape; STATISTICS IO gives you the hard numbers. Together they tell the complete story.

10. **Document your baselines.** Before making any change, record the plan, logical reads, CPU time, and elapsed time. After the change, compare. This discipline prevents guesswork and demonstrates value to stakeholders.
