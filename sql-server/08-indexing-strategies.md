# Indexing Strategies (Clustered, Non-Clustered, Filtered, Columnstore)

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [B-Tree Structure Fundamentals](#b-tree-structure-fundamentals)
2. [Clustered Indexes](#clustered-indexes)
3. [Non-Clustered Indexes](#non-clustered-indexes)
4. [Covering Indexes and Included Columns](#covering-indexes-and-included-columns)
5. [Composite Indexes and Column Order](#composite-indexes-and-column-order)
6. [Filtered Indexes](#filtered-indexes)
7. [Unique Indexes](#unique-indexes)
8. [Index Intersection](#index-intersection)
9. [Index Key Size Limits](#index-key-size-limits)
10. [Columnstore Indexes (Overview)](#columnstore-indexes-overview)
11. [Index Design Methodology](#index-design-methodology)
12. [Missing Index DMVs](#missing-index-dmvs)
13. [Unused Index Identification](#unused-index-identification)
14. [Index Fragmentation](#index-fragmentation)
15. [Online vs Offline Index Rebuild](#online-vs-offline-index-rebuild)
16. [Index Maintenance Strategies](#index-maintenance-strategies)
17. [Common Interview Questions](#common-interview-questions)
18. [Tips for Senior Engineers](#tips-for-senior-engineers)

---

## B-Tree Structure Fundamentals

SQL Server row-store indexes are organized as **B+ trees** (technically balanced trees with data only at the leaf level).

### Structure

```
                    [Root Page]
                   /     |      \
          [Intermediate] [Intermediate] [Intermediate]
          /    |    \       /    |    \       /    |    \
       [Leaf] [Leaf] [Leaf] [Leaf] [Leaf] [Leaf] [Leaf] [Leaf] [Leaf]
```

- **Root page**: Single page at the top. Contains key values and pointers to intermediate pages.
- **Intermediate pages (non-leaf)**: Navigate between root and leaf levels. May have multiple levels depending on data volume.
- **Leaf pages**: Contain the actual data (for clustered indexes) or index key + row locator (for non-clustered indexes). Leaf pages are linked in a **doubly-linked list** for range scans.

### Key Properties

- The tree is **balanced** -- all leaf pages are at the same depth.
- The depth is typically 2-4 levels for most tables (even billion-row tables rarely exceed 4-5 levels).
- A seek operation navigates root -> intermediate(s) -> leaf, reading one page per level. For a 3-level index, a seek requires exactly 3 logical reads (plus 1 for the data page if a Key Lookup is needed).
- Pages are 8 KB in SQL Server. The number of keys per page determines the tree's **fan-out** and thus its depth.

### Index Navigation Example

To find `OrderID = 12345`:
1. Read root page: keys tell us 12345 is between pointers for ranges 10001-20000.
2. Read intermediate page: keys narrow to the specific leaf page containing 12345.
3. Read leaf page: binary search within the page to find the row.

Total: **3 logical reads** for a seek (typical for millions of rows).

---

## Clustered Indexes

A clustered index **defines the physical storage order** of data in a table. The leaf level of the clustered index **is** the data.

### Key Characteristics

- Only **one** clustered index per table.
- The leaf level contains **all columns** of the table.
- Data is logically sorted by the clustered index key (physically sorted approximately -- fragmentation can cause out-of-order pages).
- If no clustered index exists, the table is a **heap**.
- The clustered index key is included in **every** non-clustered index as the row locator.

### Choosing a Clustered Index Key

The ideal clustered index key is:

| Property | Reason |
|----------|--------|
| **Narrow** | The key is stored in every non-clustered index; a wide key bloats all indexes. |
| **Unique** | If not unique, SQL Server adds a hidden 4-byte **uniquifier**, wasting space. |
| **Static (immutable)** | Changing the key value requires physically moving the row. |
| **Ever-increasing** | Avoids page splits during inserts. Identity columns are ideal. |

```sql
-- Most common pattern: identity column as clustered index (created by PRIMARY KEY by default)
CREATE TABLE Sales.Orders (
    OrderID INT IDENTITY(1,1) NOT NULL,
    OrderDate DATE NOT NULL,
    CustomerID INT NOT NULL,
    TotalAmount DECIMAL(18,2),
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
```

### When NOT to Cluster on Identity

In some cases, a different clustered index key is more appropriate:

```sql
-- Example: Audit/log table always queried by date range
-- Clustering on the date provides range scan efficiency
CREATE TABLE Audit.EventLog (
    EventID BIGINT IDENTITY(1,1) NOT NULL,
    EventDate DATETIME2 NOT NULL,
    EventType TINYINT NOT NULL,
    EventData NVARCHAR(MAX),
    CONSTRAINT PK_EventLog PRIMARY KEY NONCLUSTERED (EventID)
);

CREATE CLUSTERED INDEX CIX_EventLog_EventDate ON Audit.EventLog(EventDate);
```

### Heaps vs Clustered Indexes

| Aspect | Heap | Clustered Index |
|--------|------|-----------------|
| Structure | Unordered pages, tracked by IAM | B-tree, ordered by key |
| Point lookups | RID lookup (file:page:slot) | Key-based seek |
| Range scans | Full table scan only | Efficient ordered range scan |
| Inserts | Fast (append to any page with space) | May cause page splits |
| Forwarding pointers | Yes (after updates expand rows) | No (rows move with page splits instead) |
| Space reclamation | Pages not deallocated after DELETE without explicit shrink/rebuild | Pages reused naturally |

**General guidance:** Almost always prefer a clustered index over a heap. Heaps can develop forwarding pointer chains that severely degrade scan performance.

---

## Non-Clustered Indexes

Non-clustered indexes are separate B-tree structures that contain a subset of columns plus a pointer back to the base table.

### Structure

- **Key columns**: Columns specified in the index definition, stored at all levels.
- **Row locator**: For tables with a clustered index, this is the **clustered index key**. For heaps, this is the **RID** (Row Identifier = FileID:PageID:SlotNumber).
- **Included columns**: Stored only at the leaf level (not in intermediate/root pages).

```sql
-- Basic non-clustered index
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID
ON Sales.Orders (CustomerID);

-- The leaf level contains: CustomerID (key) + OrderID (clustered key as row locator)
```

### When Non-Clustered Index Seek Triggers Key Lookup

```sql
-- This query needs OrderDate and TotalAmount, not in the index
SELECT OrderDate, TotalAmount
FROM Sales.Orders
WHERE CustomerID = 42;

-- Plan: Index Seek on IX_Orders_CustomerID -> Key Lookup on PK_Orders
-- For each row found, a separate lookup into the clustered index
```

### Maximum Non-Clustered Indexes

- Up to **999** non-clustered indexes per table (practical limit is far lower).
- Each index adds overhead to INSERT, UPDATE, DELETE operations.

---

## Covering Indexes and Included Columns

A **covering index** contains all columns needed by a query, eliminating the need for Key Lookups.

### INCLUDE Columns (SQL Server 2005+)

```sql
-- Covering index with INCLUDE columns
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID_Covering
ON Sales.Orders (CustomerID)
INCLUDE (OrderDate, TotalAmount, Status);
```

**Key columns vs INCLUDE columns:**

| Aspect | Key Columns | INCLUDE Columns |
|--------|-------------|-----------------|
| Stored at | All levels (root, intermediate, leaf) | Leaf level only |
| Sorted | Yes | No |
| Used for seeking | Yes | No |
| Used for ordering | Yes | No |
| Count toward key size limit | Yes (900 bytes / 1700 bytes) | No |
| Count toward key column limit | Yes (16 columns) | No |

**When to use INCLUDE vs key columns:**
- Use as **key column** if the column appears in WHERE, JOIN ON, or ORDER BY.
- Use as **INCLUDE** if the column is only in the SELECT list or is a residual predicate that filters after the seek.

```sql
-- Example: Query with WHERE, ORDER BY, and SELECT columns
SELECT OrderDate, TotalAmount
FROM Sales.Orders
WHERE CustomerID = 42
  AND Status = 'Shipped'
ORDER BY OrderDate;

-- Optimal covering index:
-- Key: CustomerID (equality seek), Status (equality seek), OrderDate (ordering)
-- Include: TotalAmount (only in SELECT)
CREATE INDEX IX_Orders_Cust_Status_Date
ON Sales.Orders (CustomerID, Status, OrderDate)
INCLUDE (TotalAmount);
```

---

## Composite Indexes and Column Order

A **composite index** (multi-column index) has multiple key columns. The **order of columns matters significantly**.

### The Leftmost Prefix Rule

A composite index can satisfy seeks on any **leftmost prefix** of its key columns:

```sql
CREATE INDEX IX_Orders_Composite
ON Sales.Orders (CustomerID, OrderDate, Status);

-- Can use this index for seeks on:
WHERE CustomerID = 42                                        -- Yes (first column)
WHERE CustomerID = 42 AND OrderDate = '2025-01-01'           -- Yes (first two columns)
WHERE CustomerID = 42 AND OrderDate > '2025-01-01'           -- Yes (seek + range)
WHERE CustomerID = 42 AND OrderDate = '2025-01-01'
      AND Status = 'Shipped'                                 -- Yes (all three columns)

-- Cannot efficiently seek on:
WHERE OrderDate = '2025-01-01'                               -- No (skips first column)
WHERE Status = 'Shipped'                                     -- No (skips first two columns)
WHERE OrderDate = '2025-01-01' AND Status = 'Shipped'        -- No (skips first column)
```

### Column Order Strategy

**General principle:** Order columns by selectivity of the predicate type:

1. **Equality predicates first** -- columns used with `=` or `IN`.
2. **Range predicates last** -- columns used with `>`, `<`, `BETWEEN`, `LIKE 'prefix%'`.

After a range predicate, subsequent key columns cannot be seeked -- they become residual predicates.

```sql
-- Query:
WHERE CustomerID = 42 AND OrderDate > '2025-01-01' AND Status = 'Shipped'

-- Better index:  (CustomerID, Status, OrderDate)
-- Seek on CustomerID = 42 AND Status = 'Shipped' AND OrderDate > '2025-01-01'
-- All three columns used in the seek predicate!

-- Worse index:  (CustomerID, OrderDate, Status)
-- Seek on CustomerID = 42 AND OrderDate > '2025-01-01'
-- Status = 'Shipped' becomes a residual predicate (filtered after seek)
```

### Sort Order Considerations

```sql
-- If the query needs:
ORDER BY CustomerID ASC, OrderDate DESC

-- The index must match the sort direction:
CREATE INDEX IX_Orders_Sorted
ON Sales.Orders (CustomerID ASC, OrderDate DESC);

-- SQL Server can also reverse-scan an index, but only if ALL columns are reversed:
-- Index (A ASC, B ASC) can satisfy ORDER BY A DESC, B DESC (reverse scan)
-- But NOT: ORDER BY A ASC, B DESC (mixed directions require an explicit matching index)
```

---

## Filtered Indexes

A **filtered index** includes only rows that match a WHERE clause, resulting in a smaller, more efficient index.

```sql
-- Index only active orders (much smaller than indexing all orders)
CREATE NONCLUSTERED INDEX IX_Orders_Active
ON Sales.Orders (CustomerID, OrderDate)
INCLUDE (TotalAmount)
WHERE Status = 'Active';

-- Index only non-NULL values
CREATE NONCLUSTERED INDEX IX_Orders_ShipDate
ON Sales.Orders (ShipDate)
WHERE ShipDate IS NOT NULL;
```

### Benefits

- **Smaller size**: Fewer rows = fewer pages = less storage and memory.
- **Better statistics**: Statistics are more accurate for the filtered subset.
- **Lower maintenance cost**: Fewer rows to maintain during DML.

### Limitations and Gotchas

- The query predicate must **match or be a subset of** the filter predicate for the optimizer to consider the index.
- **Parameterized queries** may not match filtered indexes because the optimizer cannot guarantee the parameter value satisfies the filter at compile time.

```sql
-- This will NOT use the filtered index:
DECLARE @Status VARCHAR(20) = 'Active';
SELECT * FROM Sales.Orders WHERE Status = @Status;
-- Optimizer cannot prove @Status = 'Active' at compile time

-- Workaround 1: Add OPTION (RECOMPILE)
SELECT * FROM Sales.Orders WHERE Status = @Status OPTION (RECOMPILE);

-- Workaround 2: Use literal value
SELECT * FROM Sales.Orders WHERE Status = 'Active';
```

- Cannot use complex expressions; only simple comparisons (=, <>, <, >, <=, >=, IS NULL, IS NOT NULL, IN, AND, OR between these).
- Filtered indexes require the SET options ANSI_NULLS, ANSI_PADDING, etc. to be ON.

---

## Unique Indexes

A **unique index** enforces uniqueness of the key columns and provides the optimizer with a **uniqueness guarantee** that can improve plan quality.

```sql
-- Unique index
CREATE UNIQUE NONCLUSTERED INDEX UX_Customers_Email
ON Sales.Customers (Email);

-- Unique constraint (creates a unique index behind the scenes)
ALTER TABLE Sales.Customers
ADD CONSTRAINT UQ_Customers_Email UNIQUE (Email);
```

### Optimizer Benefits of Uniqueness

- After seeking on a unique index with equality predicates on all key columns, the optimizer knows **at most one row** will be returned. This enables:
  - Nested Loops with a single-row inner seek (very efficient).
  - Elimination of unnecessary GROUP BY or DISTINCT.
  - Better cardinality estimates (exactly 0 or 1 row).

### NULL Handling in Unique Indexes

- A standard unique index allows **one NULL** per set of key columns.
- To allow multiple NULLs, use a **filtered unique index**:

```sql
CREATE UNIQUE NONCLUSTERED INDEX UX_Customers_TaxID
ON Sales.Customers (TaxID)
WHERE TaxID IS NOT NULL;
-- Multiple rows with NULL TaxID are now allowed
```

---

## Index Intersection

**Index intersection** occurs when the optimizer combines two or more non-clustered indexes to satisfy a query, rather than using a single index.

```sql
-- Two separate indexes:
CREATE INDEX IX_Orders_CustomerID ON Sales.Orders (CustomerID);
CREATE INDEX IX_Orders_OrderDate ON Sales.Orders (OrderDate);

-- Query with both predicates:
SELECT OrderID FROM Sales.Orders
WHERE CustomerID = 42 AND OrderDate = '2025-06-15';

-- The optimizer might:
-- 1. Seek IX_Orders_CustomerID for CustomerID = 42 (returns set of OrderIDs)
-- 2. Seek IX_Orders_OrderDate for OrderDate = '2025-06-15' (returns set of OrderIDs)
-- 3. Hash Match (Inner Join) or Merge Join the two sets on OrderID
```

### When Does Intersection Happen?

- When no single index covers both predicates efficiently.
- When the combined selectivity makes it cheaper than a full scan.
- When a composite index is not available.

### Should You Rely on Index Intersection?

**Generally no.** A composite index `(CustomerID, OrderDate)` is almost always better than relying on intersection. Index intersection requires reading two B-trees and joining them, while a composite index requires reading only one B-tree. However, index intersection can be a useful fallback when you cannot add more indexes.

---

## Index Key Size Limits

| Version | Max Key Size (clustered + non-clustered) | Max Key Columns |
|---------|------------------------------------------|-----------------|
| SQL Server 2012 and earlier | 900 bytes | 16 |
| SQL Server 2016+ | 1,700 bytes (non-clustered only) | 32 (non-clustered only) |
| Clustered indexes (all versions) | 900 bytes | 16 |

```sql
-- This will fail if the combined column sizes exceed the limit:
CREATE INDEX IX_WideIndex ON dbo.MyTable (
    Col1 VARCHAR(500),  -- up to 500 bytes
    Col2 VARCHAR(500)   -- up to 500 bytes = 1000 total, exceeds 900
);
-- Warning or error depending on actual data sizes

-- Solution: Use INCLUDE columns for non-seeking columns
CREATE INDEX IX_BetterIndex ON dbo.MyTable (Col1)
INCLUDE (Col2);
```

**Important nuance:** SQL Server may issue a **warning** rather than an error if the maximum *potential* key size exceeds the limit. The index creation succeeds, but INSERT/UPDATE operations will fail at runtime if a specific row's key values actually exceed the limit.

---

## Columnstore Indexes (Overview)

Columnstore indexes store data in a **columnar format** rather than row-based, optimized for analytical queries that scan large volumes of data.

### Key Concepts (Detailed Coverage in a Later Topic)

- **Column segments**: Data is stored column by column, compressed together.
- **Row groups**: Rows are divided into groups of up to ~1 million rows.
- **Compression**: Columnar storage achieves 5x-10x compression ratios.
- **Batch mode execution**: Operations process ~900 rows at a time instead of row-by-row.

### Types

```sql
-- Clustered Columnstore Index (CCI): replaces the table's row storage entirely
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactSales ON dbo.FactSales;

-- Non-Clustered Columnstore Index (NCCI): exists alongside a row-store table
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_Orders_Analytics
ON Sales.Orders (OrderDate, CustomerID, TotalAmount);
```

### When to Use

- **Data warehouse / analytics**: Queries scanning millions of rows with aggregations.
- **Large fact tables**: Star schema patterns.
- **Archival data**: Excellent compression for cold data.
- **HTAP** (SQL Server 2016+): Non-clustered columnstore on an OLTP table for real-time analytics.

### When NOT to Use

- **Point lookups**: Columnstore is not efficient for single-row seeks.
- **Small tables**: Overhead of columnstore structure is not justified.
- **Frequent single-row updates**: Delta store overhead; columnstore is optimized for bulk operations.

---

## Index Design Methodology

A systematic approach to designing indexes for a workload:

### Step 1: Analyze the Workload

- Identify the most critical and frequent queries (use Query Store or trace data).
- Classify queries: point lookups, range scans, aggregations, sorts.
- Note DML patterns (INSERT/UPDATE/DELETE frequency and volume).

### Step 2: Start with the Clustered Index

- Choose the clustered index key based on the most common access pattern.
- Default to a narrow, unique, ever-increasing column (e.g., identity) unless a specific pattern dictates otherwise.

### Step 3: Design Non-Clustered Indexes for Key Queries

For each critical query:
1. Identify columns in **WHERE** (equality first, then range) -> these become key columns.
2. Identify columns in **ORDER BY** -> append after WHERE columns if possible.
3. Identify columns in **SELECT** that are not yet covered -> these become INCLUDE columns.
4. Consider if a **filtered index** is appropriate (WHERE clause on a constant value or common condition).

### Step 4: Consolidate

- Multiple queries may benefit from the same index.
- A single broader index may serve several queries, even if not perfect for any one query.
- Aim for the minimum number of indexes that cover the key workload.

### Step 5: Measure and Iterate

- Deploy indexes and measure impact with actual execution plans and STATISTICS IO.
- Use the Missing Index DMVs and unused index stats to refine.
- Periodically review as the workload evolves.

---

## Missing Index DMVs

SQL Server tracks potential missing indexes in **Dynamic Management Views**. The optimizer records when it encounters a query that could benefit from an index.

```sql
-- Query to find missing indexes with impact score
SELECT
    CONVERT(DECIMAL(18,2),
        migs.avg_total_user_cost * migs.avg_user_impact *
        (migs.user_seeks + migs.user_scans)
    ) AS improvement_measure,
    mid.statement AS [table_name],
    'CREATE NONCLUSTERED INDEX [IX_' +
        REPLACE(REPLACE(REPLACE(mid.statement, '[', ''), ']', ''), '.', '_') +
        '_' + CAST(mid.index_handle AS VARCHAR(10)) + '] ON ' +
        mid.statement + ' (' +
        ISNULL(mid.equality_columns, '') +
        CASE
            WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL
            THEN ', '
            ELSE ''
        END +
        ISNULL(mid.inequality_columns, '') +
        ')' +
        ISNULL(' INCLUDE (' + mid.included_columns + ')', '')
    AS create_index_statement,
    mid.equality_columns,
    mid.inequality_columns,
    mid.included_columns,
    migs.user_seeks,
    migs.user_scans,
    migs.avg_total_user_cost,
    migs.avg_user_impact
FROM sys.dm_db_missing_index_group_stats migs
JOIN sys.dm_db_missing_index_groups mig
    ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details mid
    ON mig.index_handle = mid.index_handle
WHERE mid.database_id = DB_ID()
ORDER BY improvement_measure DESC;
```

### Important Caveats

- **Missing index suggestions are per-query, not per-workload.** They do not consider the impact of the new index on DML operations.
- **They may suggest overlapping indexes.** Multiple queries may suggest indexes that could be consolidated into one.
- **They do not suggest filtered indexes.**
- **They reset on server restart** (unless you use Query Store's missing index feature in SQL Server 2022+).
- **Column order may not be optimal.** The DMV separates equality and inequality columns but does not specify the optimal ordering within each group.
- **Never blindly create all suggested indexes.** Analyze, consolidate, and test.

---

## Unused Index Identification

Indexes that are maintained (costing write performance) but never used for reads are candidates for removal.

```sql
-- Find unused indexes (no seeks, no scans, no lookups since last restart)
SELECT
    OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc,
    ius.user_seeks,
    ius.user_scans,
    ius.user_lookups,
    ius.user_updates,  -- DML maintenance cost
    ius.last_user_seek,
    ius.last_user_scan,
    ius.last_user_lookup,
    ius.last_user_update
FROM sys.indexes i
LEFT JOIN sys.dm_db_index_usage_stats ius
    ON i.object_id = ius.object_id
    AND i.index_id = ius.index_id
    AND ius.database_id = DB_ID()
WHERE OBJECTPROPERTY(i.object_id, 'IsUserTable') = 1
  AND i.type_desc = 'NONCLUSTERED'
  AND i.is_primary_key = 0
  AND i.is_unique_constraint = 0
  AND (ius.user_seeks + ius.user_scans + ius.user_lookups) = 0
  AND ius.user_updates > 0
ORDER BY ius.user_updates DESC;
```

### Understanding sys.dm_db_index_usage_stats

| Column | Meaning |
|--------|---------|
| user_seeks | Index seek operations from user queries |
| user_scans | Index scan operations from user queries |
| user_lookups | Key/RID lookup operations |
| user_updates | DML operations that maintained this index |
| system_seeks/scans/lookups | Internal operations (statistics updates, DBCC, etc.) |

**Important:** These counters **reset on service restart**, failover, index rebuild, and database detach/attach. Before dropping an unused index, ensure the server has been running long enough to cover all workload patterns (monthly reports, quarter-end processing, etc.). A minimum observation period of one full business cycle is recommended.

---

## Index Fragmentation

### Types of Fragmentation

**Logical Fragmentation (External)**
- Index pages are out of logical order on disk.
- Causes extra random I/O during ordered scans.
- Measured as a percentage (0% = perfect order).

**Internal Fragmentation (Page Fullness)**
- Pages are not fully utilized (too much free space).
- Caused by page splits, deletes, or low fill factor.
- Average page density below ~80% may indicate a problem.

### Checking Fragmentation

```sql
-- Check fragmentation for all indexes on a table
SELECT
    i.name AS index_name,
    ips.index_type_desc,
    ips.avg_fragmentation_in_percent,    -- logical fragmentation
    ips.avg_page_space_used_in_percent,  -- page fullness
    ips.page_count,
    ips.fragment_count
FROM sys.dm_db_index_physical_stats(
    DB_ID(), OBJECT_ID('Sales.Orders'), NULL, NULL, 'DETAILED'
) ips
JOIN sys.indexes i
    ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.page_count > 1000  -- skip tiny indexes
ORDER BY ips.avg_fragmentation_in_percent DESC;
```

### Addressing Fragmentation

| Fragmentation Level | Action |
|---------------------|--------|
| < 5% | Do nothing |
| 5% - 30% | REORGANIZE (online, lightweight) |
| > 30% | REBUILD (heavier, resets statistics, can be online or offline) |

```sql
-- Reorganize: online, log-efficient, does not reset statistics
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders REORGANIZE;

-- Rebuild: offline by default, resets fragmentation to ~0%, rebuilds statistics
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders REBUILD;

-- Rebuild ALL indexes on a table
ALTER INDEX ALL ON Sales.Orders REBUILD;
```

### Modern Perspective on Fragmentation

**For SSD/flash storage**, logical fragmentation is far less impactful because random I/O performance is close to sequential. Focus on page fullness (internal fragmentation) and wasted space rather than logical ordering. For cloud-based storage (Azure SQL, remote SANs), the same applies.

---

## Online vs Offline Index Rebuild

### Offline Rebuild (Default)

```sql
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders REBUILD;
```

- Acquires **Schema Modification Lock (Sch-M)** for the duration.
- Blocks ALL concurrent access to the table (reads and writes).
- Fastest option; uses less tempdb space.
- Not suitable for production during business hours.

### Online Rebuild (Enterprise Edition Required)

```sql
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders
REBUILD WITH (ONLINE = ON);
```

- Table remains accessible during the rebuild.
- Acquires Sch-M lock only **very briefly** at the beginning and end.
- Uses a temporary mapping table to handle concurrent DML.
- Slower and uses more tempdb space.
- **Resumable** online index rebuild (SQL Server 2017+):

```sql
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders
REBUILD WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 10 MINUTES);

-- If interrupted, resume later:
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders RESUME;

-- Or abort:
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders ABORT;
```

### Comparison

| Aspect | Offline | Online |
|--------|---------|--------|
| Table availability | Blocked | Available |
| Edition | All editions | Enterprise / Developer (Standard in some Azure tiers) |
| Speed | Faster | Slower |
| Tempdb usage | Less | More |
| Lock duration | Full duration (Sch-M) | Brief Sch-M at start/end |
| Resumable | No | Yes (2017+) |
| LOB columns | Supported | Restricted in older versions; supported in 2012+ with limitations |

---

## Index Maintenance Strategies

### Scheduled Maintenance

A common approach using Ola Hallengren's maintenance scripts (industry standard):

```sql
-- Example using Ola Hallengren's IndexOptimize
EXECUTE dbo.IndexOptimize
    @Databases = 'USER_DATABASES',
    @FragmentationLow = NULL,                          -- do nothing < 5%
    @FragmentationMedium = 'INDEX_REORGANIZE',          -- reorganize 5-30%
    @FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',  -- rebuild > 30%
    @FragmentationLevel1 = 5,
    @FragmentationLevel2 = 30,
    @MinNumberOfPages = 1000,                           -- skip small indexes
    @UpdateStatistics = 'ALL',
    @OnlyModifiedStatistics = 'Y';
```

### Adaptive Maintenance

Instead of fixed schedules, consider:

- **Skipping tiny indexes** (< 1000 pages) -- fragmentation impact is negligible.
- **Skipping on SSD storage** -- reorganize only for page density, not logical fragmentation.
- **Focusing on heavily-modified indexes** rather than rebuilding everything.
- **Using Query Store regression detection** to trigger targeted index rebuilds.

### Fill Factor

```sql
-- Set fill factor to leave 20% free space on leaf pages during rebuild
ALTER INDEX IX_Orders_CustomerID ON Sales.Orders
REBUILD WITH (FILLFACTOR = 80);

-- Default fill factor is 0 (same as 100) - pages are filled completely
```

- Lower fill factor reduces page splits for random inserts/updates.
- But wastes space and increases I/O for scans (more pages to read).
- Recommended only for indexes with heavy random insert/update patterns.
- Sequential inserts (identity column) rarely benefit from a fill factor < 100.

---

## Common Interview Questions

### Q1: What is the difference between a clustered and non-clustered index?

**A:** A **clustered index** defines the physical storage order of the table data. The leaf level of the clustered index IS the data -- there is only one per table. A **non-clustered index** is a separate B-tree structure where the leaf level contains the index key columns plus a pointer back to the base table (the clustered index key, or RID for heaps). You can have up to 999 non-clustered indexes per table. The key implication is that a non-clustered index seek may require an additional Key Lookup to retrieve columns not present in the index, while a clustered index seek always has all columns available.

### Q2: Explain what a covering index is and why it matters.

**A:** A covering index contains all columns required by a query -- in the key columns or the INCLUDE columns. When a query is covered by an index, SQL Server can satisfy the entire query from the non-clustered index alone, eliminating Key Lookups into the clustered index. This is significant because Key Lookups involve random I/O per row, which becomes extremely expensive at scale. INCLUDE columns are stored only at the leaf level and do not count toward the index key size limit, making them ideal for adding columns needed only in the SELECT list.

### Q3: Why does column order matter in a composite index?

**A:** In a composite index, SQL Server can only seek using a **leftmost prefix** of the key columns. An index on `(A, B, C)` can efficiently seek on `A`, or `A, B`, or `A, B, C`, but not on `B` alone or `C` alone. Additionally, after a range predicate on a column, subsequent columns cannot be seeked -- they become residual predicates. So equality columns should come first, followed by range columns, followed by ORDER BY columns. Getting this wrong can mean the difference between a precise seek and a broad scan with residual filtering.

### Q4: What are filtered indexes and what is their main limitation?

**A:** Filtered indexes include only rows matching a WHERE predicate (e.g., `WHERE Status = 'Active'` or `WHERE DeletedDate IS NOT NULL`). They are smaller, faster to maintain, and have more accurate statistics for the filtered subset. The main limitation is with **parameterized queries**: the optimizer cannot use a filtered index when the query predicate uses a parameter, because it cannot guarantee at compile time that the parameter value matches the filter condition. The workaround is `OPTION (RECOMPILE)` or using literal values.

### Q5: How do you identify and handle unused indexes?

**A:** Use `sys.dm_db_index_usage_stats` to find indexes with zero seeks, scans, and lookups but positive updates (being maintained for DML). Before dropping, ensure the server has been running through at least one complete business cycle (the DMV resets on restart). Also check if the index supports a UNIQUE or FOREIGN KEY constraint (which may be needed for data integrity regardless of query usage). Dropping unused indexes reduces DML overhead and storage.

### Q6: When should you reorganize vs rebuild an index?

**A:** **Reorganize** (ALTER INDEX REORGANIZE) is a lightweight, always-online operation that physically reorders leaf pages. Use it for moderate fragmentation (5-30%). **Rebuild** (ALTER INDEX REBUILD) drops and recreates the index, achieving near-zero fragmentation and rebuilding statistics. Use it for high fragmentation (>30%). Rebuilds can be offline (blocking) or online (Enterprise Edition). With modern SSD/cloud storage, logical fragmentation is less impactful -- focus more on page density and statistics staleness as rebuild triggers.

### Q7: Explain the impact of a wide clustered index key on the entire table.

**A:** The clustered index key is embedded in **every** non-clustered index as the row locator. A wide clustered key (e.g., a GUID at 16 bytes, or worse a composite of multiple columns) inflates every non-clustered index, meaning: more pages per index, more I/O for scans and seeks, more memory consumed in the buffer pool, and more storage. For a table with 10 non-clustered indexes and 100 million rows, switching from a 16-byte GUID to a 4-byte INT as the clustered key saves approximately 12 bytes * 100M rows * 10 indexes = ~11 GB of index space.

### Q8: What is the ascending key problem and how does it relate to indexes?

**A:** When an ever-increasing column (identity, datetime) is used as an index key and new data is constantly inserted beyond the range covered by existing statistics, the optimizer may underestimate cardinality for recent data. The histogram's last step does not cover the new values. This leads to poor plan choices. Mitigations include more frequent statistics updates, trace flag 2371 (dynamic auto-update threshold), and using the new cardinality estimator (CE 120+), which handles this scenario better with an "ascending key" assumption.

### Q9: What are Missing Index DMVs and how should they be used?

**A:** The missing index DMVs (`sys.dm_db_missing_index_details`, `sys.dm_db_missing_index_group_stats`) track indexes the optimizer wished existed during query compilation. They show the table, equality/inequality columns, included columns, and an impact score. However, they should be used as **suggestions, not prescriptions**. Limitations: they are per-query (not workload-aware), may suggest overlapping indexes, do not suggest filtered indexes, do not account for DML overhead, and may suggest suboptimal column ordering. Always consolidate, test, and measure before creating.

### Q10: Explain online vs resumable index operations.

**A:** **Online rebuild** keeps the table available during the rebuild by maintaining a temporary mapping structure for concurrent DML, requiring only brief Schema Modification locks at the start and end. It requires Enterprise Edition and uses more tempdb. **Resumable rebuild** (SQL Server 2017+) extends online rebuild by allowing the operation to be paused and resumed. If it fails or is cancelled, progress is preserved and can be continued later. This is valuable for very large indexes on 24/7 systems where a maintenance window may not be long enough to complete the rebuild in one pass.

---

## Tips for Senior Engineers

1. **Index design is about trade-offs.** Every index speeds up reads but slows down writes. The goal is the minimum set of indexes that supports the workload. Quantify both sides.

2. **The clustered index choice ripples through everything.** It is the most consequential index decision. A bad clustered index key (wide, random, volatile) damages every non-clustered index.

3. **INCLUDE columns are your best friend.** They eliminate Key Lookups without bloating non-leaf levels or counting toward key size limits. Use them aggressively.

4. **Column order in composite indexes is not intuitive.** Equality columns first, then range, then ORDER BY. Test with actual execution plans -- do not guess.

5. **Do not trust missing index DMVs blindly.** They are a starting point for investigation, not a to-do list. Consolidate overlapping suggestions and always measure the DML impact.

6. **Measure unused indexes over a full business cycle.** A quarterly reporting index used once every 90 days will appear "unused" in a 30-day observation window.

7. **Fragmentation management is less critical on modern storage.** SSDs and cloud storage make logical fragmentation nearly irrelevant. Focus on page density and statistics freshness.

8. **Use online and resumable operations in production.** Never block a production table with an offline rebuild during business hours.

9. **Filtered indexes are underused.** If most queries target a subset of data (active records, non-NULL values, recent dates), filtered indexes deliver huge savings. Just be aware of the parameterization limitation.

10. **Monitor index operational stats.** `sys.dm_db_index_operational_stats` shows latch waits, page splits, and lock escalations per index -- invaluable for diagnosing concurrency issues.
