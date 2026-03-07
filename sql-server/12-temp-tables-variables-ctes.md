# Temp Tables vs Table Variables vs CTEs

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Overview](#overview)
2. [Local Temp Tables (#temp)](#local-temp-tables-temp)
3. [Global Temp Tables (##temp)](#global-temp-tables-temp-1)
4. [Table Variables (@table)](#table-variables-table)
5. [Common Table Expressions (CTEs)](#common-table-expressions-ctes)
6. [Recursive CTEs](#recursive-ctes)
7. [When to Use Which](#when-to-use-which)
8. [Statistics and Cardinality Estimation](#statistics-and-cardinality-estimation)
9. [Recompilation Behavior](#recompilation-behavior)
10. [Tempdb Contention](#tempdb-contention)
11. [Memory-Optimized Table Variables](#memory-optimized-table-variables)
12. [Temp Table Caching](#temp-table-caching)
13. [Performance Comparison Scenarios](#performance-comparison-scenarios)
14. [Table-Valued Parameters](#table-valued-parameters)
15. [STRING_SPLIT Alternative Patterns](#string_split-alternative-patterns)
16. [Common Interview Questions](#common-interview-questions)
17. [Tips](#tips)

---

## Overview

SQL Server offers several mechanisms for storing intermediate result sets. Each has different characteristics regarding storage, statistics, scope, and performance.

| Feature | #Temp Table | ##Global Temp | @Table Variable | CTE |
|---------|------------|---------------|----------------|-----|
| Storage | tempdb | tempdb | tempdb (usually) | None (inline) |
| Statistics | Yes (auto-created) | Yes | No (before 2019) | N/A |
| Indexes | Yes (any type) | Yes | Primary key, unique only (inline) | N/A |
| Scope | Session / procedure | All sessions | Batch / procedure | Single statement |
| Transactions | Participates | Participates | Does NOT roll back | N/A |
| Recompilation | Triggers recompile | Triggers recompile | No recompile | N/A |
| Parallelism | Supported | Supported | Supported | Supported |
| Row estimate | Statistics-based | Statistics-based | 1 row (pre-2019) | Derived |

---

## Local Temp Tables (#temp)

Local temp tables are created in tempdb and are visible only to the session that created them. They are automatically dropped when the session ends or when the creating scope (stored procedure) exits.

### Creating Temp Tables

```sql
-- Method 1: Explicit CREATE
CREATE TABLE #CustomerOrders (
    OrderID INT PRIMARY KEY,
    CustomerID INT NOT NULL,
    OrderDate DATE NOT NULL,
    TotalAmount DECIMAL(18,2),
    INDEX IX_CustDate NONCLUSTERED (CustomerID, OrderDate)
);

-- Method 2: SELECT INTO
SELECT
    OrderID,
    CustomerID,
    OrderDate,
    TotalAmount
INTO #CustomerOrders
FROM Sales.Orders
WHERE OrderDate >= '2025-01-01';

-- Method 3: INSERT INTO with pre-created table
INSERT INTO #CustomerOrders (OrderID, CustomerID, OrderDate, TotalAmount)
SELECT OrderID, CustomerID, OrderDate, TotalAmount
FROM Sales.Orders
WHERE OrderDate >= '2025-01-01';
```

### Key Characteristics

- **Stored in tempdb**: Uses tempdb data files for storage.
- **Full DDL support**: You can add indexes, constraints, alter columns after creation.
- **Statistics are auto-created**: The query optimizer creates and maintains statistics, enabling accurate cardinality estimates.
- **Scope**: Visible only within the creating session. If created inside a stored procedure, the table is dropped when the procedure exits. Inner procedures can see temp tables created by outer procedures.
- **Transaction behavior**: Participates in transactions. If you roll back a transaction, inserts into #temp tables are rolled back too.
- **Naming**: The actual name in tempdb is mangled with a unique suffix (e.g., `#CustomerOrders___________00000000001A`).

### Adding Indexes After Population

```sql
-- Create and populate
SELECT OrderID, CustomerID, OrderDate, TotalAmount
INTO #CustomerOrders
FROM Sales.Orders
WHERE OrderDate >= '2025-01-01';

-- Add indexes after population (often faster than inserting into indexed table)
CREATE NONCLUSTERED INDEX IX_CustomerID ON #CustomerOrders (CustomerID);
CREATE NONCLUSTERED INDEX IX_OrderDate ON #CustomerOrders (OrderDate) INCLUDE (TotalAmount);

-- Now use the temp table in queries
SELECT c.CustomerName, t.OrderDate, t.TotalAmount
FROM #CustomerOrders AS t
JOIN Sales.Customers AS c ON t.CustomerID = c.CustomerID
WHERE t.OrderDate >= '2025-06-01';
```

---

## Global Temp Tables (##temp)

Global temp tables are visible to all sessions on the instance.

```sql
-- Created with double hash
CREATE TABLE ##SharedLookup (
    Code VARCHAR(10) PRIMARY KEY,
    Description VARCHAR(200)
);
```

### Key Characteristics

- **Visible to all sessions**: Any connection can read/write the table.
- **Lifetime**: Dropped automatically when the creating session disconnects AND no other sessions are referencing it.
- **Use cases**: Sharing data between sessions, staging tables for ETL that multiple jobs access, debugging.
- **Caution**: Name collisions are possible if multiple processes try to create the same global temp table.

### Real-World Use Case

```sql
-- Session 1: ETL process creates a shared staging table
CREATE TABLE ##StagingData (
    RecordID INT IDENTITY PRIMARY KEY,
    SourceSystem VARCHAR(50),
    RawData NVARCHAR(MAX),
    ProcessedFlag BIT DEFAULT 0
);

-- Bulk load data
BULK INSERT ##StagingData
FROM '\\server\share\data.csv'
WITH (FIELDTERMINATOR = ',', ROWTERMINATOR = '\n');

-- Session 2: Another process reads from the same table
SELECT * FROM ##StagingData WHERE ProcessedFlag = 0;
```

---

## Table Variables (@table)

Table variables are declared using `DECLARE` and behave like variables with a table data type.

```sql
DECLARE @CustomerOrders TABLE (
    OrderID INT PRIMARY KEY CLUSTERED,
    CustomerID INT NOT NULL,
    OrderDate DATE NOT NULL,
    TotalAmount DECIMAL(18,2),
    UNIQUE NONCLUSTERED (CustomerID, OrderDate)
);

INSERT INTO @CustomerOrders (OrderID, CustomerID, OrderDate, TotalAmount)
SELECT OrderID, CustomerID, OrderDate, TotalAmount
FROM Sales.Orders
WHERE OrderDate >= '2025-01-01';
```

### Key Characteristics

- **Stored in tempdb**: Despite common misconceptions, table variables are stored in tempdb, not purely in memory. Very small table variables may stay in memory, but there is no guarantee.
- **No statistics** (before SQL Server 2019): The optimizer estimates 1 row for table variables, regardless of actual content. This leads to poor plan choices for larger datasets.
- **Limited indexing**: Only indexes defined inline at declaration (PRIMARY KEY, UNIQUE constraints). No CREATE INDEX after declaration. SQL Server 2014+ added inline index syntax.
- **No recompilation**: Inserting data into a table variable does not trigger statement-level recompilation. This can be an advantage (less compile overhead) or disadvantage (stale estimates).
- **Transaction behavior**: Table variables do NOT participate in explicit transactions. A ROLLBACK does not undo inserts into table variables. This makes them useful for logging/auditing that must survive rollbacks.
- **Scope**: The declaring batch or stored procedure only. Cannot be passed between procedures (use table-valued parameters instead).

### Inline Index Syntax (SQL Server 2014+)

```sql
DECLARE @Orders TABLE (
    OrderID INT NOT NULL,
    CustomerID INT NOT NULL,
    OrderDate DATE NOT NULL,
    TotalAmount DECIMAL(18,2),

    -- Inline indexes
    INDEX IX_CustomerID NONCLUSTERED (CustomerID),
    INDEX IX_OrderDate NONCLUSTERED (OrderDate),
    PRIMARY KEY CLUSTERED (OrderID)
);
```

### Transaction Behavior Demonstration

```sql
DECLARE @AuditLog TABLE (
    LogMessage VARCHAR(500),
    LogTime DATETIME DEFAULT GETDATE()
);

BEGIN TRANSACTION;
    INSERT INTO @AuditLog (LogMessage) VALUES ('Starting process');
    INSERT INTO SomeTable (Col1) VALUES ('data');

    -- Something goes wrong
ROLLBACK TRANSACTION;

-- The SomeTable insert is rolled back
-- But the @AuditLog insert SURVIVES the rollback
SELECT * FROM @AuditLog;
-- Returns: 'Starting process'
```

---

## Common Table Expressions (CTEs)

CTEs are named, temporary result sets defined within a `WITH` clause. They exist only for the duration of the single statement that follows.

### Basic CTE Syntax

```sql
WITH CustomerTotals AS (
    SELECT
        CustomerID,
        COUNT(*) AS OrderCount,
        SUM(TotalAmount) AS TotalSpent
    FROM Sales.Orders
    GROUP BY CustomerID
)
SELECT
    c.CustomerName,
    ct.OrderCount,
    ct.TotalSpent
FROM CustomerTotals AS ct
JOIN Sales.Customers AS c ON ct.CustomerID = c.CustomerID
WHERE ct.TotalSpent > 10000
ORDER BY ct.TotalSpent DESC;
```

### Key Characteristics

- **Not materialized**: A CTE is essentially an inline view. The query is expanded into the main query by the optimizer. It is NOT stored in tempdb.
- **Single statement scope**: The CTE exists only for the immediately following SELECT, INSERT, UPDATE, DELETE, or MERGE statement.
- **Readability**: CTEs improve readability by breaking complex queries into named logical blocks.
- **Multiple CTEs**: You can define multiple CTEs separated by commas.
- **Self-referencing**: CTEs support recursion (see next section).
- **No performance guarantee**: Because CTEs are inlined, the optimizer may execute the CTE subquery multiple times if it is referenced multiple times.

### Multiple CTEs

```sql
WITH ActiveCustomers AS (
    SELECT CustomerID, CustomerName
    FROM Sales.Customers
    WHERE IsActive = 1
),
RecentOrders AS (
    SELECT CustomerID, COUNT(*) AS RecentOrderCount
    FROM Sales.Orders
    WHERE OrderDate >= DATEADD(MONTH, -3, GETDATE())
    GROUP BY CustomerID
),
CustomerSpending AS (
    SELECT CustomerID, SUM(TotalAmount) AS LifetimeSpent
    FROM Sales.Orders
    GROUP BY CustomerID
)
SELECT
    ac.CustomerName,
    ISNULL(ro.RecentOrderCount, 0) AS RecentOrders,
    ISNULL(cs.LifetimeSpent, 0) AS LifetimeSpent
FROM ActiveCustomers AS ac
LEFT JOIN RecentOrders AS ro ON ac.CustomerID = ro.CustomerID
LEFT JOIN CustomerSpending AS cs ON ac.CustomerID = cs.CustomerID
ORDER BY LifetimeSpent DESC;
```

### CTE Referenced Multiple Times

```sql
-- WARNING: This CTE may be executed TWICE
WITH ExpensiveCalculation AS (
    SELECT CustomerID, SUM(TotalAmount) AS Total
    FROM Sales.Orders
    GROUP BY CustomerID
)
SELECT
    a.CustomerID, a.Total,
    b.CustomerID AS OtherCustomer, b.Total AS OtherTotal
FROM ExpensiveCalculation a
CROSS JOIN ExpensiveCalculation b  -- Referenced twice = potentially executed twice
WHERE a.Total > b.Total;

-- If the CTE is expensive and referenced multiple times,
-- materialize it in a #temp table instead
```

---

## Recursive CTEs

Recursive CTEs allow a CTE to reference itself, enabling hierarchical and iterative queries.

### Anatomy of a Recursive CTE

```sql
WITH RecursiveCTE AS (
    -- Anchor member: the starting point (non-recursive)
    SELECT columns
    FROM BaseTable
    WHERE StartingCondition

    UNION ALL

    -- Recursive member: references the CTE itself
    SELECT columns
    FROM BaseTable
    JOIN RecursiveCTE ON JoinCondition
    WHERE TerminationCondition
)
SELECT * FROM RecursiveCTE;
```

### Example: Organizational Hierarchy

```sql
-- Employee table with self-referencing ManagerID
WITH OrgChart AS (
    -- Anchor: Start with the CEO (no manager)
    SELECT
        EmployeeID,
        EmployeeName,
        ManagerID,
        0 AS HierarchyLevel,
        CAST(EmployeeName AS VARCHAR(MAX)) AS HierarchyPath
    FROM HR.Employees
    WHERE ManagerID IS NULL

    UNION ALL

    -- Recursive: Find direct reports of each level
    SELECT
        e.EmployeeID,
        e.EmployeeName,
        e.ManagerID,
        oc.HierarchyLevel + 1,
        CAST(oc.HierarchyPath + ' > ' + e.EmployeeName AS VARCHAR(MAX))
    FROM HR.Employees AS e
    JOIN OrgChart AS oc ON e.ManagerID = oc.EmployeeID
)
SELECT
    EmployeeID,
    EmployeeName,
    HierarchyLevel,
    HierarchyPath
FROM OrgChart
ORDER BY HierarchyPath
OPTION (MAXRECURSION 100);  -- Safety limit (default is 100, 0 = unlimited)
```

### Example: Date Series Generation

```sql
-- Generate a series of dates
WITH DateSeries AS (
    SELECT CAST('2025-01-01' AS DATE) AS DateValue

    UNION ALL

    SELECT DATEADD(DAY, 1, DateValue)
    FROM DateSeries
    WHERE DateValue < '2025-12-31'
)
SELECT DateValue
FROM DateSeries
OPTION (MAXRECURSION 366);
```

### Example: Bill of Materials (BOM) Explosion

```sql
WITH BOM AS (
    -- Anchor: top-level assemblies
    SELECT
        ProductID,
        ComponentID,
        Quantity,
        1 AS BOMLevel
    FROM Manufacturing.BillOfMaterials
    WHERE ProductID = 1000  -- Top-level product

    UNION ALL

    -- Recursive: subcomponents
    SELECT
        b.ProductID,
        b.ComponentID,
        b.Quantity * bom.Quantity AS Quantity,  -- Accumulate quantities
        bom.BOMLevel + 1
    FROM Manufacturing.BillOfMaterials AS b
    JOIN BOM AS bom ON b.ProductID = bom.ComponentID
)
SELECT
    ComponentID,
    SUM(Quantity) AS TotalQuantityNeeded,
    MAX(BOMLevel) AS DeepestLevel
FROM BOM
GROUP BY ComponentID
ORDER BY TotalQuantityNeeded DESC;
```

### MAXRECURSION

- Default limit is 100 iterations.
- Set to 0 for unlimited recursion (use with caution -- infinite loops will consume resources).
- Always include a proper termination condition in the recursive member.

```sql
-- Override the default limit
SELECT * FROM RecursiveCTE
OPTION (MAXRECURSION 0);  -- Unlimited (dangerous without proper termination)
```

---

## When to Use Which

### Decision Matrix

| Scenario | Best Choice | Why |
|----------|------------|-----|
| Small result set (< 100 rows), used once | Table variable or CTE | Low overhead, no recompile |
| Large result set, complex joins downstream | #Temp table | Statistics enable good plans |
| Need indexes for downstream queries | #Temp table | Full index support |
| Data must survive ROLLBACK | Table variable | Not transaction-bound |
| Simplifying a complex query for readability | CTE | Clean, inline, no temp storage |
| Hierarchical/recursive query | Recursive CTE | Only option for recursion |
| Referenced multiple times in same batch | #Temp table | Materialized once, read many |
| High-concurrency OLTP, small lookups | Table variable | No recompile, no lock overhead |
| Sharing data across sessions | ##Global temp table | Cross-session visibility |
| Passing a set of rows to a procedure | Table-valued parameter | Type-safe, parameterized |

### Quick Rule of Thumb

```
< 100 rows          --> Table variable or CTE
100 - 10,000 rows   --> Either (test both); CTE if used once
> 10,000 rows        --> #Temp table (statistics matter)
Recursive query      --> CTE (only option)
Readability only     --> CTE
Multiple references  --> #Temp table
```

---

## Statistics and Cardinality Estimation

This is one of the most critical differences between temp tables and table variables.

### Temp Tables: Full Statistics

```sql
-- Temp tables get auto-created statistics
CREATE TABLE #Orders (
    OrderID INT PRIMARY KEY,
    CustomerID INT,
    OrderDate DATE
);

INSERT INTO #Orders
SELECT TOP 100000 OrderID, CustomerID, OrderDate
FROM Sales.Orders;

-- Statistics are automatically created
-- The optimizer knows there are ~100,000 rows
-- Cardinality estimates for joins/filters are accurate

-- View statistics on a temp table
DBCC SHOW_STATISTICS ('tempdb..#Orders', 'IX_SomeIndex');
```

### Table Variables: The 1-Row Estimate Problem (Pre-2019)

```sql
DECLARE @Orders TABLE (
    OrderID INT PRIMARY KEY,
    CustomerID INT,
    OrderDate DATE
);

INSERT INTO @Orders
SELECT TOP 100000 OrderID, CustomerID, OrderDate
FROM Sales.Orders;

-- The optimizer estimates 1 ROW for @Orders
-- This leads to catastrophic plan choices:
--   - Nested Loop joins instead of Hash joins
--   - Missing parallelism
--   - Inadequate memory grants (spills to tempdb)

SELECT o.OrderID, c.CustomerName
FROM @Orders AS o
JOIN Sales.Customers AS c ON o.CustomerID = c.CustomerID;
-- Optimizer thinks 1 row from @Orders -> Nested Loop
-- Actually 100,000 rows -> should be Hash Match
```

### SQL Server 2019+ Table Variable Deferred Compilation

Starting with SQL Server 2019 (compatibility level 150), table variable deferred compilation provides accurate row counts:

```sql
-- With compat level 150+ and deferred compilation:
-- The optimizer defers compilation of statements referencing
-- table variables until first execution, at which point
-- the actual row count is known.

-- The estimated rows will match actual rows (e.g., 100,000)
-- instead of always estimating 1 row.
```

This is an Intelligent Query Processing (IQP) feature. It requires:
- SQL Server 2019 or later
- Database compatibility level 150 or higher
- No `OPTION(RECOMPILE)` on the statement (which already solves the estimate problem)

### Practical Impact

```sql
-- BAD: Table variable with 500K rows, pre-2019 or compat < 150
DECLARE @BigTable TABLE (ID INT PRIMARY KEY, Val VARCHAR(100));
-- ... insert 500,000 rows ...

-- Optimizer estimates 1 row for @BigTable
-- Chooses Nested Loop join (good for 1 row, terrible for 500K)
SELECT b.ID, t.Name
FROM @BigTable b
JOIN dbo.LookupTable t ON b.ID = t.ID;
-- Actual execution: 500K nested loop iterations = SLOW

-- GOOD: Temp table with 500K rows
CREATE TABLE #BigTable (ID INT PRIMARY KEY, Val VARCHAR(100));
-- ... insert 500,000 rows ...

-- Optimizer knows 500K rows from statistics
-- Chooses Hash Match join (optimal for 500K rows)
SELECT b.ID, t.Name
FROM #BigTable b
JOIN dbo.LookupTable t ON b.ID = t.ID;
-- Actual execution: efficient hash join
```

---

## Recompilation Behavior

### Temp Tables Trigger Recompilation

When a temp table is modified (significant INSERT, UPDATE, DELETE, or DDL), SQL Server may recompile subsequent statements in the batch. This ensures the optimizer uses current statistics.

```sql
CREATE PROCEDURE ProcessOrders
AS
BEGIN
    CREATE TABLE #Staging (OrderID INT, Amount DECIMAL(18,2));

    -- Insert triggers statistics update on #Staging
    INSERT INTO #Staging
    SELECT OrderID, TotalAmount FROM Sales.Orders WHERE Status = 'New';

    -- This statement may be recompiled because #Staging statistics changed
    SELECT s.OrderID, c.CustomerName
    FROM #Staging s
    JOIN Sales.Customers c ON s.OrderID = c.CustomerID;  -- Uses fresh statistics
END;
```

Recompilation thresholds for temp tables are lower than for permanent tables:
- Temp table with < 6 rows: recompile after any row count change
- Temp table with 6-500 rows: recompile when change exceeds 500 + 20% of rows
- Temp table with > 500 rows: recompile when change exceeds 500 + 20% of rows

### Table Variables Do NOT Trigger Recompilation

```sql
CREATE PROCEDURE ProcessOrders
AS
BEGIN
    DECLARE @Staging TABLE (OrderID INT, Amount DECIMAL(18,2));

    INSERT INTO @Staging
    SELECT OrderID, TotalAmount FROM Sales.Orders WHERE Status = 'New';

    -- This statement is NOT recompiled after the insert
    -- Plan was compiled at procedure creation time with estimate of 1 row
    SELECT s.OrderID, c.CustomerName
    FROM @Staging s
    JOIN Sales.Customers c ON s.OrderID = c.CustomerID;
END;
```

### When No-Recompile is an Advantage

For small, fixed-size lookups that execute frequently:

```sql
-- High-frequency procedure called 1000 times/second
CREATE PROCEDURE QuickLookup
    @StatusCodes VARCHAR(100)
AS
BEGIN
    DECLARE @Codes TABLE (Code VARCHAR(10) PRIMARY KEY);

    -- Always a small number of status codes (3-5)
    INSERT INTO @Codes
    SELECT value FROM STRING_SPLIT(@StatusCodes, ',');

    -- No recompile overhead -- plan is always optimal for small sets
    SELECT o.OrderID, o.Status
    FROM Sales.Orders o
    JOIN @Codes c ON o.Status = c.Code;
END;
```

---

## Tempdb Contention

Both temp tables and table variables use tempdb. Under heavy concurrent usage, tempdb can become a bottleneck.

### Common Contention Points

| Contention Type | Description | Impact |
|----------------|-------------|--------|
| **PFS page contention** | Page Free Space pages track allocation | PAGELATCH_UP waits |
| **GAM/SGAM contention** | Global Allocation Map pages | PAGELATCH_EX waits |
| **Metadata contention** | System table locks during CREATE/DROP | Blocking on system objects |

### Mitigating Tempdb Contention

```sql
-- 1. Multiple tempdb data files (1 per CPU core, up to 8)
-- Configure via SQL Server setup or:
ALTER DATABASE tempdb ADD FILE (
    NAME = 'tempdev2',
    FILENAME = 'T:\tempdb\tempdev2.ndf',
    SIZE = 8GB,
    FILEGROWTH = 1GB
);

-- 2. Enable trace flag 1118 (full extents, pre-2016)
-- In SQL Server 2016+, this is the default behavior

-- 3. Enable trace flag 1117 (uniform file growth, pre-2016)
-- In SQL Server 2016+, use ALTER DATABASE ... MODIFY FILEGROUP ... AUTOGROW_ALL_FILES
```

### Reducing Tempdb Usage

```sql
-- Use table variables for very small datasets (no DDL overhead)
DECLARE @SmallLookup TABLE (ID INT PRIMARY KEY);

-- Avoid SELECT INTO in high-concurrency scenarios (DDL overhead)
-- Prefer pre-created temp tables with INSERT INTO

-- Use CTEs to avoid tempdb entirely when possible
WITH FilteredOrders AS (
    SELECT OrderID, CustomerID FROM Sales.Orders WHERE Status = 'New'
)
SELECT fo.OrderID, c.CustomerName
FROM FilteredOrders fo
JOIN Sales.Customers c ON fo.CustomerID = c.CustomerID;
```

---

## Memory-Optimized Table Variables

SQL Server 2014+ supports memory-optimized table variables that bypass tempdb entirely, storing data in memory using In-Memory OLTP structures.

### Prerequisites

```sql
-- 1. Enable In-Memory OLTP filegroup
ALTER DATABASE [AdventureWorks]
ADD FILEGROUP InMemory CONTAINS MEMORY_OPTIMIZED_DATA;

ALTER DATABASE [AdventureWorks]
ADD FILE (
    NAME = 'InMemFile',
    FILENAME = 'D:\Data\InMemFile'
) TO FILEGROUP InMemory;

-- 2. Create a memory-optimized table type
CREATE TYPE dbo.MemOptOrderType AS TABLE (
    OrderID INT NOT NULL PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 10000),
    CustomerID INT NOT NULL,
    Amount DECIMAL(18,2) NOT NULL,
    INDEX IX_Customer NONCLUSTERED (CustomerID)
) WITH (MEMORY_OPTIMIZED = ON);
```

### Usage

```sql
DECLARE @Orders dbo.MemOptOrderType;

INSERT INTO @Orders (OrderID, CustomerID, Amount)
SELECT OrderID, CustomerID, TotalAmount
FROM Sales.Orders
WHERE OrderDate = CAST(GETDATE() AS DATE);

-- Uses in-memory storage, no tempdb I/O
SELECT o.OrderID, c.CustomerName, o.Amount
FROM @Orders o
JOIN Sales.Customers c ON o.CustomerID = c.CustomerID;
```

### Benefits

- **No tempdb contention**: All data is in memory.
- **No latch contention**: Lock-free data structures.
- **Faster for high-concurrency scenarios**: Especially beneficial when many sessions create/destroy table variables simultaneously.

### Limitations

- Requires In-Memory OLTP filegroup.
- Must define a user-defined table type (cannot use inline DECLARE).
- Hash indexes require estimating bucket count.
- Memory consumption must be monitored.

---

## Temp Table Caching

SQL Server caches temp tables created inside stored procedures to avoid repeated CREATE/DROP overhead.

### How It Works

When a stored procedure creates a temp table, SQL Server may cache the table structure after the procedure finishes. On the next execution, instead of creating a new temp table from scratch, SQL Server renames and reuses the cached structure.

### Conditions for Caching

Temp table caching works when:
- The temp table is created inside a stored procedure (not ad-hoc batches).
- The CREATE TABLE statement uses explicit column definitions (not SELECT INTO).
- No DDL is performed on the temp table after creation (no ALTER TABLE, no CREATE INDEX after the CREATE TABLE).

```sql
-- CACHEABLE: Explicit CREATE + INSERT
CREATE PROCEDURE CacheableProcedure
AS
BEGIN
    CREATE TABLE #Data (
        ID INT PRIMARY KEY,
        Name VARCHAR(100),
        INDEX IX_Name (Name)  -- Inline index is OK
    );

    INSERT INTO #Data SELECT ID, Name FROM SourceTable;
    SELECT * FROM #Data WHERE Name LIKE 'A%';
END;

-- NOT CACHEABLE: SELECT INTO
CREATE PROCEDURE NotCacheableProcedure
AS
BEGIN
    SELECT ID, Name
    INTO #Data
    FROM SourceTable;

    SELECT * FROM #Data WHERE Name LIKE 'A%';
END;

-- NOT CACHEABLE: DDL after CREATE
CREATE PROCEDURE AlsoNotCacheableProcedure
AS
BEGIN
    CREATE TABLE #Data (ID INT, Name VARCHAR(100));
    CREATE INDEX IX_Name ON #Data (Name);  -- DDL after CREATE = no caching

    INSERT INTO #Data SELECT ID, Name FROM SourceTable;
    SELECT * FROM #Data;
END;
```

### Monitoring Temp Table Caching

```sql
-- Check temp table cache hit rate
SELECT
    name AS cache_store,
    type,
    entries_count,
    entries_in_use_count
FROM sys.dm_os_memory_cache_counters
WHERE type = 'CACHESTORE_TEMPTABLES';
```

---

## Performance Comparison Scenarios

### Scenario 1: Small Lookup (10 rows)

```sql
-- All three approaches perform similarly for 10 rows
-- Table variable is marginally preferred (no recompile, no DDL overhead)

-- Approach A: Table Variable (WINNER for small sets)
DECLARE @Codes TABLE (Code VARCHAR(10) PRIMARY KEY);
INSERT INTO @Codes VALUES ('A'), ('B'), ('C');
SELECT * FROM Orders o JOIN @Codes c ON o.Status = c.Code;

-- Approach B: CTE (GOOD - no tempdb at all)
WITH Codes AS (SELECT Code FROM (VALUES ('A'), ('B'), ('C')) AS t(Code))
SELECT * FROM Orders o JOIN Codes c ON o.Status = c.Code;

-- Approach C: Temp Table (OVERHEAD for this size)
CREATE TABLE #Codes (Code VARCHAR(10) PRIMARY KEY);
INSERT INTO #Codes VALUES ('A'), ('B'), ('C');
SELECT * FROM Orders o JOIN #Codes c ON o.Status = c.Code;
DROP TABLE #Codes;
```

### Scenario 2: Large Dataset (500K rows) with Complex Joins

```sql
-- Temp table clearly wins for large datasets

-- Approach A: Temp Table (WINNER for large sets)
SELECT OrderID, CustomerID, OrderDate, TotalAmount
INTO #LargeOrders
FROM Sales.Orders
WHERE OrderDate >= '2024-01-01';

CREATE INDEX IX_Customer ON #LargeOrders (CustomerID);

-- Optimizer knows exact row count and has statistics
SELECT lo.OrderID, c.CustomerName, p.ProductName
FROM #LargeOrders lo
JOIN Sales.Customers c ON lo.CustomerID = c.CustomerID
JOIN Sales.OrderDetails od ON lo.OrderID = od.OrderID
JOIN Sales.Products p ON od.ProductID = p.ProductID
WHERE lo.TotalAmount > 1000;

-- Approach B: Table Variable (POOR for large sets, pre-2019)
-- Optimizer estimates 1 row -> bad join strategies, memory spills
DECLARE @LargeOrders TABLE (OrderID INT, CustomerID INT, OrderDate DATE, TotalAmount DECIMAL(18,2));
INSERT INTO @LargeOrders SELECT ... ;  -- Same query
-- Joins will likely use wrong strategy
```

### Scenario 3: CTE Referenced Multiple Times

```sql
-- BAD: CTE executed twice (potentially)
WITH ExpensiveCTE AS (
    SELECT CustomerID, SUM(TotalAmount) AS Total
    FROM Sales.Orders
    GROUP BY CustomerID
)
SELECT a.CustomerID, a.Total, b.Total AS CompareTotal
FROM ExpensiveCTE a
JOIN ExpensiveCTE b ON a.Total > b.Total;
-- The optimizer MAY execute the aggregation twice

-- GOOD: Materialize in temp table, read twice
SELECT CustomerID, SUM(TotalAmount) AS Total
INTO #CustomerTotals
FROM Sales.Orders
GROUP BY CustomerID;

SELECT a.CustomerID, a.Total, b.Total AS CompareTotal
FROM #CustomerTotals a
JOIN #CustomerTotals b ON a.Total > b.Total;
-- Aggregation happens once, two reads from temp table
```

### Scenario 4: High-Frequency Stored Procedure

```sql
-- For a procedure called 500 times/second with a small parameter set:
-- Table variable wins due to no recompilation

CREATE PROCEDURE HighFrequencyLookup
    @CategoryID INT
AS
BEGIN
    -- Table variable: no recompile, no DDL overhead, small dataset
    DECLARE @SubCategories TABLE (SubCategoryID INT PRIMARY KEY);

    INSERT INTO @SubCategories
    SELECT SubCategoryID
    FROM Products.SubCategories
    WHERE CategoryID = @CategoryID;  -- Always < 20 rows

    SELECT p.ProductID, p.ProductName, p.Price
    FROM Products.Products p
    JOIN @SubCategories sc ON p.SubCategoryID = sc.SubCategoryID
    WHERE p.IsActive = 1;
END;
```

---

## Table-Valued Parameters

Table-valued parameters (TVPs) allow you to pass an entire table of data to a stored procedure.

### Creating and Using a TVP

```sql
-- Step 1: Create a user-defined table type
CREATE TYPE dbo.OrderIDList AS TABLE (
    OrderID INT NOT NULL PRIMARY KEY
);

-- Step 2: Use it as a parameter in a stored procedure
CREATE PROCEDURE GetOrderDetails
    @OrderIDs dbo.OrderIDList READONLY  -- Must be READONLY
AS
BEGIN
    SELECT o.OrderID, o.OrderDate, o.TotalAmount, c.CustomerName
    FROM Sales.Orders o
    JOIN Sales.Customers c ON o.CustomerID = c.CustomerID
    JOIN @OrderIDs ids ON o.OrderID = ids.OrderID;
END;

-- Step 3: Call from T-SQL
DECLARE @IDs dbo.OrderIDList;
INSERT INTO @IDs VALUES (1001), (1002), (1003), (1004), (1005);
EXEC GetOrderDetails @OrderIDs = @IDs;
```

### TVPs vs Other Approaches

```sql
-- OLD WAY: Comma-separated string parameter
CREATE PROCEDURE GetOrderDetails_Old
    @OrderIDList VARCHAR(MAX)  -- '1001,1002,1003'
AS
BEGIN
    SELECT o.OrderID, o.OrderDate
    FROM Sales.Orders o
    JOIN STRING_SPLIT(@OrderIDList, ',') s ON o.OrderID = CAST(s.value AS INT);
END;

-- NEW WAY: Table-valued parameter (preferred)
-- Benefits:
--   Type-safe (INT vs VARCHAR parsing)
--   Better performance (no string parsing)
--   Proper statistics and indexing
--   Clean interface
```

### Limitations

- TVP parameters must be `READONLY` -- you cannot modify the data inside the procedure.
- Subject to the same cardinality estimation issues as table variables (1-row estimate pre-2019).
- The table type must be created before the procedure.

---

## STRING_SPLIT Alternative Patterns

`STRING_SPLIT` (SQL Server 2016+) is commonly used to parse delimited lists, but there are several patterns and alternatives.

### Basic STRING_SPLIT

```sql
-- Simple usage
SELECT value FROM STRING_SPLIT('red,green,blue', ',');

-- With ordinal position (SQL Server 2022+)
SELECT value, ordinal
FROM STRING_SPLIT('red,green,blue', ',', 1)
ORDER BY ordinal;
```

### Using STRING_SPLIT for IN-list Replacement

```sql
-- Instead of dynamic SQL with IN clause:
CREATE PROCEDURE GetProductsByCategory
    @CategoryList VARCHAR(MAX)  -- e.g., '1,5,12,27'
AS
BEGIN
    SELECT p.ProductID, p.ProductName
    FROM Products.Products p
    WHERE p.CategoryID IN (
        SELECT CAST(value AS INT)
        FROM STRING_SPLIT(@CategoryList, ',')
    );
END;
```

### Alternative: JSON-Based Parsing

```sql
-- Parse a JSON array (more flexible for complex data)
CREATE PROCEDURE GetFilteredProducts
    @Filters NVARCHAR(MAX)
    -- Example: '[{"Category":1,"MinPrice":10},{"Category":5,"MinPrice":20}]'
AS
BEGIN
    SELECT p.ProductID, p.ProductName, p.Price
    FROM Products.Products p
    JOIN OPENJSON(@Filters)
        WITH (
            Category INT '$.Category',
            MinPrice DECIMAL(10,2) '$.MinPrice'
        ) AS f ON p.CategoryID = f.Category AND p.Price >= f.MinPrice;
END;
```

### Alternative: XML-Based Parsing (Legacy)

```sql
-- For older SQL Server versions without STRING_SPLIT
CREATE PROCEDURE GetOrdersByIDs_XML
    @OrderIDsXML XML
    -- Example: '<ids><id>1001</id><id>1002</id><id>1003</id></ids>'
AS
BEGIN
    SELECT o.OrderID, o.OrderDate
    FROM Sales.Orders o
    JOIN (
        SELECT item.value('.', 'INT') AS OrderID
        FROM @OrderIDsXML.nodes('/ids/id') AS x(item)
    ) AS ids ON o.OrderID = ids.OrderID;
END;
```

### Alternative: Tally Table Split (Pre-2016)

```sql
-- Classic string split using a numbers/tally table
CREATE FUNCTION dbo.SplitString (
    @List VARCHAR(MAX),
    @Delimiter CHAR(1)
)
RETURNS TABLE
AS
RETURN (
    WITH Tally AS (
        SELECT TOP (LEN(@List))
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS N
        FROM sys.all_columns a
        CROSS JOIN sys.all_columns b
    )
    SELECT
        SUBSTRING(@List, N,
            CHARINDEX(@Delimiter, @List + @Delimiter, N) - N) AS value
    FROM Tally
    WHERE N <= LEN(@List)
      AND SUBSTRING(@Delimiter + @List, N, 1) = @Delimiter
);
```

### Performance Ranking

For splitting delimited strings:

1. **Table-valued parameter** (best -- no parsing needed)
2. **STRING_SPLIT** (built-in, optimized)
3. **JSON with OPENJSON** (flexible, good performance)
4. **XML parsing** (decent, heavier overhead)
5. **While loop / cursor splitting** (worst -- never use)

---

## Common Interview Questions

### Q1: What are the key differences between temp tables, table variables, and CTEs?

**A:** Temp tables are physical tables in tempdb with full statistics, indexing, and DDL support. They trigger recompilation and participate in transactions. Table variables are also stored in tempdb but have no statistics (pre-2019, estimate 1 row), limited indexing, no recompilation, and do not participate in explicit transactions (rollback-proof). CTEs are not stored anywhere -- they are inline query definitions expanded by the optimizer, scoped to a single statement, and primarily used for readability and recursion.

### Q2: When would you choose a temp table over a table variable?

**A:** Choose a temp table when: (1) The result set is large (thousands+ rows) and accurate statistics matter for downstream query optimization. (2) You need non-trivial indexes. (3) You need to reference the data multiple times in different statements. (4) The data needs to participate in transactions. The key driver is statistics -- for large datasets, the optimizer needs accurate row counts to choose efficient join strategies and memory grants.

### Q3: Why does a table variable estimate 1 row, and how does SQL Server 2019 address this?

**A:** Before SQL Server 2019, the optimizer compiled statements referencing table variables before any data was inserted, so it had no row count information and defaulted to 1 row. SQL Server 2019 introduced "table variable deferred compilation" -- compilation of statements referencing table variables is deferred until the first execution, at which point the actual row count is known. This requires compatibility level 150+.

### Q4: Can CTEs improve performance?

**A:** CTEs themselves do not improve performance -- they are syntactic sugar. The optimizer inlines the CTE into the main query, so the execution plan is identical to writing the query without a CTE. CTEs improve readability and maintainability. They can actually hurt performance if referenced multiple times (the subquery may execute repeatedly). For performance, materialize in a temp table. The exception is recursive CTEs, which provide functionality that would otherwise require cursors or loops.

### Q5: What is temp table caching, and what breaks it?

**A:** SQL Server caches temp tables created inside stored procedures. Instead of executing CREATE/DROP for each procedure call, it renames and reuses the cached structure. This works only when: the temp table is in a stored procedure, uses explicit CREATE TABLE (not SELECT INTO), and no DDL (CREATE INDEX, ALTER TABLE) occurs after the CREATE TABLE. SELECT INTO and post-creation DDL break caching. For high-frequency procedures, use explicit CREATE TABLE with inline indexes.

### Q6: How do memory-optimized table variables differ from regular table variables?

**A:** Memory-optimized table variables use In-Memory OLTP structures and never touch tempdb. They eliminate tempdb contention entirely and use lock-free algorithms. They require a pre-defined memory-optimized table type and an In-Memory OLTP filegroup. They are ideal for high-concurrency scenarios where many sessions create temporary data simultaneously. The trade-off is additional setup complexity and memory consumption that must be monitored.

### Q7: Explain a scenario where a table variable outperforms a temp table.

**A:** In a high-frequency stored procedure (called hundreds of times per second) that works with a small, predictable dataset (under 100 rows). The table variable avoids: recompilation overhead (temp tables trigger recompiles when data changes), DDL overhead (no CREATE/DROP in tempdb), and statistics creation overhead. For small datasets, the 1-row estimate is less harmful because the optimizer's plan choice is often acceptable regardless. Combined with the no-recompile behavior, table variables have lower overhead per execution.

### Q8: What happens to a table variable during a ROLLBACK?

**A:** Table variable modifications are NOT rolled back. This is because table variable operations are not logged in the same way as regular table operations -- they are treated more like variable assignments. This makes table variables useful for audit logging, error tracking, or any data that must persist regardless of transaction outcome. Example: inserting error details into a table variable inside a TRY/CATCH block, then using that data after the CATCH rolls back the transaction.

### Q9: How do you handle tempdb contention caused by heavy temp table usage?

**A:** (1) Add multiple tempdb data files -- typically one per CPU core up to 8, all equal in size. (2) On SQL Server 2016+, ensure uniform extent allocation is enabled (default). (3) Replace temp tables with table variables for small datasets. (4) Consider memory-optimized table variables for high-concurrency scenarios. (5) Use CTEs where possible to avoid tempdb entirely. (6) Ensure temp table caching is working (explicit CREATE TABLE, inline indexes). (7) Monitor PAGELATCH waits on tempdb pages to detect contention.

### Q10: What is the difference between STRING_SPLIT and a table-valued parameter for passing lists to procedures?

**A:** STRING_SPLIT parses a delimited string at runtime -- it requires string concatenation by the caller, type casting inside the procedure, and cannot represent complex data types. Table-valued parameters are typed table structures passed directly -- they are type-safe, support multiple columns, have indexes, and require no parsing. TVPs perform better for large lists and are the recommended approach. STRING_SPLIT is simpler for ad-hoc queries and quick scripts but should not be the primary pattern in production stored procedures.

---

## Tips

1. **Default to temp tables for large datasets.** The statistics and accurate cardinality estimation almost always outweigh the recompilation cost. When in doubt, use #temp.

2. **Use table variables for small, fixed-size datasets** (under 100 rows) in high-frequency procedures. The absence of recompilation and DDL overhead makes them faster for this use case.

3. **CTEs are for readability, not performance.** Never assume a CTE materializes results. If you need materialization, use a temp table.

4. **Watch for CTEs referenced multiple times.** The optimizer may evaluate the CTE expression once or multiple times -- you cannot control this. If the CTE is expensive, materialize it.

5. **Use explicit CREATE TABLE instead of SELECT INTO** for temp tables inside stored procedures. This enables temp table caching and inline index definitions.

6. **Add indexes to temp tables after bulk insertion.** It is often faster to insert into a heap and then create indexes than to insert into an already-indexed table.

7. **Monitor tempdb contention** with `sys.dm_os_wait_stats` (look for PAGELATCH waits) and `sys.dm_exec_requests` (wait_resource showing tempdb pages). Multiple equal-sized data files is the primary solution.

8. **Table variable deferred compilation (2019+) changes the calculus.** With compat level 150+, table variables get accurate row estimates, significantly narrowing the performance gap with temp tables. Re-evaluate your patterns if upgrading.

9. **Use table-valued parameters instead of comma-separated strings.** TVPs are type-safe, performant, and support indexing. STRING_SPLIT is fine for ad-hoc work but is not a substitute for proper TVP design in production.

10. **Recursive CTEs have a default MAXRECURSION of 100.** Always set an appropriate limit. Setting it to 0 (unlimited) is dangerous without a guaranteed termination condition -- a bug could consume all tempdb or run indefinitely.

11. **The READONLY restriction on TVPs is by design.** If you need to modify the passed data, insert it into a temp table first and work with the temp table.

12. **Global temp tables are rarely the right answer.** They create hidden dependencies between sessions and are difficult to manage. Consider proper staging tables or Service Broker for cross-session data sharing.
