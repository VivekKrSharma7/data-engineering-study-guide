# Partitioning (Table & Index)

[Back to SQL Server Index](./README.md)

---

## Overview

Table and index partitioning in SQL Server allows you to divide large tables and indexes into smaller, more manageable units called **partitions**. Each partition can be stored on a separate filegroup, enabling targeted maintenance operations, faster data loading, and efficient data lifecycle management. Partitioning is transparent to queries — the optimizer handles partition elimination automatically when filter predicates align with the partitioning column.

---

## Key Concepts

### Partitioning Architecture

Partitioning in SQL Server requires three components:

1. **Partition Function** — Defines *how* data is divided (the boundary values).
2. **Partition Scheme** — Defines *where* each partition is stored (which filegroups).
3. **Partitioned Table or Index** — The table or index created on the partition scheme.

```
Partition Function (boundary values)
        |
        v
Partition Scheme (filegroup mapping)
        |
        v
Table / Index (created ON the scheme)
```

### Partition Function

A partition function defines the boundary points that split data into partitions. The number of partitions is always **boundary values + 1**.

```sql
-- Creates 13 partitions: one per month in 2025 + a catch-all on each end
CREATE PARTITION FUNCTION pf_OrderDate (DATE)
AS RANGE RIGHT FOR VALUES (
    '2025-01-01', '2025-02-01', '2025-03-01',
    '2025-04-01', '2025-05-01', '2025-06-01',
    '2025-07-01', '2025-08-01', '2025-09-01',
    '2025-10-01', '2025-11-01', '2025-12-01'
);
```

### RANGE LEFT vs. RANGE RIGHT

This is one of the most commonly confused aspects of partitioning.

| Type | Boundary Belongs To | Typical Use |
|------|---------------------|-------------|
| **RANGE LEFT** | Boundary value belongs to the **left** (current) partition | End-of-period boundaries (e.g., `'2025-01-31'`) |
| **RANGE RIGHT** | Boundary value belongs to the **right** (next) partition | Start-of-period boundaries (e.g., `'2025-02-01'`) |

**Example with RANGE RIGHT:**

```sql
-- RANGE RIGHT: boundary value is the FIRST value in the new partition
CREATE PARTITION FUNCTION pf_RangeRight (INT)
AS RANGE RIGHT FOR VALUES (100, 200, 300);

-- Partition 1:          values < 100
-- Partition 2: 100 <= values < 200
-- Partition 3: 200 <= values < 300
-- Partition 4: 300 <= values
```

**Example with RANGE LEFT:**

```sql
-- RANGE LEFT: boundary value is the LAST value in the current partition
CREATE PARTITION FUNCTION pf_RangeLeft (INT)
AS RANGE LEFT FOR VALUES (100, 200, 300);

-- Partition 1: values <= 100
-- Partition 2: 100 < values <= 200
-- Partition 3: 200 < values <= 300
-- Partition 4: 300 < values
```

**Best practice for date-based partitioning:** Use **RANGE RIGHT** with the first day of each period as boundaries. This is the most intuitive approach and aligns well with the sliding window pattern.

### Partition Scheme

The partition scheme maps partitions to filegroups.

```sql
-- All partitions on PRIMARY filegroup (simple)
CREATE PARTITION SCHEME ps_OrderDate
AS PARTITION pf_OrderDate
ALL TO ([PRIMARY]);

-- Different filegroups per partition
CREATE PARTITION SCHEME ps_OrderDate
AS PARTITION pf_OrderDate
TO (
    FG_Archive,   -- Partition 1: < 2025-01-01
    FG_2025_Q1, FG_2025_Q1, FG_2025_Q1,   -- Jan, Feb, Mar
    FG_2025_Q2, FG_2025_Q2, FG_2025_Q2,   -- Apr, May, Jun
    FG_2025_Q3, FG_2025_Q3, FG_2025_Q3,   -- Jul, Aug, Sep
    FG_2025_Q4, FG_2025_Q4, FG_2025_Q4    -- Oct, Nov, Dec
);
```

**Important:** You must specify exactly `N+1` filegroups where `N` is the number of boundary values. You also need a **NEXT USED** filegroup designated before performing a SPLIT operation.

```sql
-- Designate the filegroup for the next SPLIT
ALTER PARTITION SCHEME ps_OrderDate
NEXT USED FG_2026_Q1;
```

### Partitioning Column Selection

Choosing the right partitioning column is critical:

- **Date columns** are the most common choice — they align with natural data lifecycle (archive old data, add new partitions).
- The column must be part of the clustered index key (or the table must be a heap).
- The column should appear frequently in `WHERE` clauses to enable partition elimination.
- Must be a single column (not a computed expression), though it can be a persisted computed column.
- NULL values go to the leftmost partition (RANGE LEFT) or leftmost partition (RANGE RIGHT).

### Creating a Partitioned Table

```sql
-- Step 1: Partition function
CREATE PARTITION FUNCTION pf_SalesDate (DATE)
AS RANGE RIGHT FOR VALUES (
    '2024-01-01', '2024-04-01', '2024-07-01', '2024-10-01',
    '2025-01-01', '2025-04-01', '2025-07-01', '2025-10-01'
);

-- Step 2: Partition scheme
CREATE PARTITION SCHEME ps_SalesDate
AS PARTITION pf_SalesDate
ALL TO ([PRIMARY]);

-- Step 3: Create table on the partition scheme
CREATE TABLE Sales.Orders (
    OrderID        BIGINT IDENTITY(1,1),
    OrderDate      DATE NOT NULL,
    CustomerID     INT NOT NULL,
    TotalAmount    DECIMAL(18,2),
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderDate, OrderID)
) ON ps_SalesDate(OrderDate);
```

**Note:** The partitioning column (`OrderDate`) must be part of every unique index and primary key on the table. This is a hard requirement.

### Partition Elimination

Partition elimination is the optimizer's ability to skip partitions that cannot contain relevant data. This is the primary performance benefit of partitioning for queries.

```sql
-- This query only scans the partition containing Q1 2025
SELECT OrderID, TotalAmount
FROM Sales.Orders
WHERE OrderDate >= '2025-01-01' AND OrderDate < '2025-04-01';
```

Check the execution plan for `Actual Partition Count` vs `Actual Partitions Accessed` to verify elimination is occurring.

**What enables partition elimination:**

- Direct comparisons on the partitioning column (`=`, `<`, `>`, `BETWEEN`)
- `IN` lists on the partitioning column
- Joins where the join column matches the partitioning column and the other table has a known range

**What breaks partition elimination:**

- Functions applied to the partitioning column: `WHERE YEAR(OrderDate) = 2025`
- Implicit type conversions
- Parameterized queries where the optimizer cannot determine the value at compile time (parameter sniffing effects)
- `OR` conditions that span unrelated columns

### The $PARTITION Function

Use `$PARTITION` to determine which partition a value maps to.

```sql
-- Which partition does a specific date fall into?
SELECT $PARTITION.pf_SalesDate('2025-03-15') AS PartitionNumber;

-- Count rows per partition
SELECT
    $PARTITION.pf_SalesDate(OrderDate) AS PartitionNumber,
    COUNT(*) AS RowCount,
    MIN(OrderDate) AS MinDate,
    MAX(OrderDate) AS MaxDate
FROM Sales.Orders
GROUP BY $PARTITION.pf_SalesDate(OrderDate)
ORDER BY PartitionNumber;
```

### sys.partitions and Metadata

```sql
-- View partition details for a table
SELECT
    p.partition_number,
    p.rows,
    fg.name AS filegroup_name,
    prv.value AS boundary_value
FROM sys.partitions p
JOIN sys.allocation_units au ON p.partition_id = au.container_id
JOIN sys.filegroups fg ON au.data_space_id = fg.data_space_id
LEFT JOIN sys.partition_range_values prv
    ON p.partition_number = prv.boundary_id + 1  -- for RANGE RIGHT
    AND prv.function_id = (
        SELECT function_id FROM sys.partition_functions WHERE name = 'pf_SalesDate'
    )
WHERE p.object_id = OBJECT_ID('Sales.Orders')
  AND p.index_id IN (0, 1)  -- heap or clustered index
ORDER BY p.partition_number;

-- Complete partition metadata query
SELECT
    t.name AS table_name,
    i.name AS index_name,
    p.partition_number,
    p.rows,
    pf.name AS partition_function,
    ps.name AS partition_scheme,
    prv.value AS boundary_value,
    fg.name AS filegroup_name
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id <= 1
JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
JOIN sys.partition_functions pf ON ps.function_id = pf.function_id
LEFT JOIN sys.partition_range_values prv
    ON pf.function_id = prv.function_id AND p.partition_number = prv.boundary_id + 1
JOIN sys.allocation_units au ON p.partition_id = au.container_id
JOIN sys.filegroups fg ON au.data_space_id = fg.data_space_id
WHERE t.name = 'Orders'
ORDER BY p.partition_number;
```

---

## Sliding Window Pattern

The sliding window is the most important maintenance pattern for partitioned tables. It allows you to efficiently add new partitions and remove (archive) old partitions with minimal logging and locking.

### Overview

```
[Archive Old] <--- | P1 | P2 | P3 | P4 | P5 | ---> [Add New]
     SWITCH OUT                                  SPLIT + SWITCH IN
```

### Step-by-Step: Adding a New Partition (Right Side)

```sql
-- 1. Set the NEXT USED filegroup
ALTER PARTITION SCHEME ps_SalesDate
NEXT USED [PRIMARY];

-- 2. SPLIT to create a new empty partition
ALTER PARTITION FUNCTION pf_SalesDate()
SPLIT RANGE ('2026-01-01');
-- This adds a new boundary, creating a new partition for Q1 2026
```

**Important:** Always SPLIT an empty partition. If you split a partition containing data, SQL Server must physically move rows, which is extremely expensive and fully logged.

### Step-by-Step: Archiving an Old Partition (Left Side)

```sql
-- 1. Create a staging table with identical schema ON THE SAME FILEGROUP
CREATE TABLE Sales.Orders_Archive_Staging (
    OrderID        BIGINT,
    OrderDate      DATE NOT NULL,
    CustomerID     INT NOT NULL,
    TotalAmount    DECIMAL(18,2),
    CONSTRAINT PK_Orders_Archive_Staging
        PRIMARY KEY CLUSTERED (OrderDate, OrderID)
) ON [PRIMARY];   -- Must match the source partition's filegroup

-- 2. Add a CHECK constraint matching the partition boundary
ALTER TABLE Sales.Orders_Archive_Staging
ADD CONSTRAINT CK_Archive_DateRange
CHECK (OrderDate >= '2024-01-01' AND OrderDate < '2024-04-01');

-- 3. SWITCH the partition out (metadata-only, instant)
ALTER TABLE Sales.Orders
SWITCH PARTITION 2 TO Sales.Orders_Archive_Staging;

-- 4. MERGE to remove the now-empty boundary
ALTER PARTITION FUNCTION pf_SalesDate()
MERGE RANGE ('2024-04-01');

-- 5. Archive or drop the staging table
-- INSERT INTO ArchiveDB.Sales.Orders SELECT * FROM Sales.Orders_Archive_Staging;
-- DROP TABLE Sales.Orders_Archive_Staging;
```

### SWITCH Requirements

For `ALTER TABLE ... SWITCH` to succeed:

- Source and target must have **identical schemas** (columns, data types, nullability).
- Target table must be **empty** (when switching in) or source partition must match target exactly.
- Both must be on the **same filegroup**.
- Check constraints on the target must **align with the partition boundary**.
- Same indexes must exist on both tables.
- If the source has a clustered columnstore index, the target must too.
- Foreign keys referencing the source table must be dropped or the table cannot participate in SWITCH.

### SPLIT and MERGE

```sql
-- SPLIT: adds a new boundary value, creating a new partition
ALTER PARTITION FUNCTION pf_SalesDate()
SPLIT RANGE ('2026-04-01');

-- MERGE: removes a boundary value, combining two adjacent partitions
ALTER PARTITION FUNCTION pf_SalesDate()
MERGE RANGE ('2024-01-01');
```

**SPLIT on a non-empty partition is dangerous** — it causes a full data movement, takes a schema modification lock (Sch-M), and is fully logged. Always SWITCH data out before SPLIT or MERGE on partitions that contain data.

---

## Aligned vs. Non-Aligned Indexes

### Aligned Indexes

An index is **aligned** when it is created on the same partition scheme as the base table (or a scheme that uses the same partition function).

```sql
-- Aligned nonclustered index (partitioned the same way)
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID
ON Sales.Orders (CustomerID)
ON ps_SalesDate(OrderDate);    -- Same partition scheme
```

**Advantages of aligned indexes:**

- Required for `ALTER TABLE ... SWITCH` operations.
- Enable partition-level index rebuilds.
- Allow parallel partition operations.
- Required for partition elimination on the nonclustered index.

### Non-Aligned Indexes

A non-aligned index is stored on a different partition scheme or on a single filegroup.

```sql
-- Non-aligned nonclustered index
CREATE NONCLUSTERED INDEX IX_Orders_CustomerID
ON Sales.Orders (CustomerID)
ON [PRIMARY];    -- Different from table's partition scheme
```

**Consequences of non-aligned indexes:**

- `ALTER TABLE ... SWITCH` is blocked — you must drop the non-aligned index first.
- Cannot perform partition-level index maintenance.
- Unique constraints that do not include the partitioning column require non-aligned indexes (since the partitioning column must be in every unique aligned index).

---

## Partition-Level Operations

SQL Server 2014+ supports online partition-level operations:

```sql
-- Rebuild a single partition online
ALTER INDEX PK_Orders ON Sales.Orders
REBUILD PARTITION = 5
WITH (ONLINE = ON, DATA_COMPRESSION = PAGE);

-- Rebuild all partitions
ALTER INDEX PK_Orders ON Sales.Orders
REBUILD PARTITION = ALL
WITH (ONLINE = ON);

-- Compression per partition
ALTER TABLE Sales.Orders
REBUILD PARTITION = 1 WITH (DATA_COMPRESSION = PAGE);

ALTER TABLE Sales.Orders
REBUILD PARTITION = 5 WITH (DATA_COMPRESSION = ROW);
```

**Partition-level statistics update (SQL Server 2014+):**

```sql
UPDATE STATISTICS Sales.Orders
WITH RESAMPLE ON PARTITIONS (5, 6, 7);
```

---

## Partitioning for Data Lifecycle Management

Partitioning excels at managing the lifecycle of time-series data:

```
Hot Data (current quarter) --> Warm Data (past year) --> Cold Data (archive)
     PAGE compression           PAGE compression         SWITCH out to archive
     Fast SSD filegroup          Standard storage         Cheap storage / delete
```

```sql
-- Different compression tiers per partition
-- Recent partitions: ROW compression (fast insert)
ALTER TABLE Sales.Orders REBUILD PARTITION = 8 WITH (DATA_COMPRESSION = ROW);

-- Older partitions: PAGE compression (save space)
ALTER TABLE Sales.Orders REBUILD PARTITION = 3 WITH (DATA_COMPRESSION = PAGE);

-- Oldest partitions: SWITCH out to archive or delete
ALTER TABLE Sales.Orders SWITCH PARTITION = 1 TO Sales.Orders_Archive;
```

---

## Performance Implications

### When Partitioning Helps

- **Data lifecycle management** — SWITCH operations are metadata-only and instant.
- **Partition elimination** — Queries filtering on the partitioning column skip irrelevant partitions.
- **Partition-level maintenance** — Rebuild indexes, update statistics, backup/restore individual filegroups.
- **Parallel partition loading** — Bulk insert into a staging table, then SWITCH in.
- **Reduced lock contention** — Lock escalation can be set to partition level.

```sql
-- Enable partition-level lock escalation
ALTER TABLE Sales.Orders SET (LOCK_ESCALATION = AUTO);
```

### When Partitioning Hurts

- **Queries that don't filter on the partitioning column** — All partitions must be scanned.
- **Small tables** — Partitioning overhead outweighs benefits.
- **OLTP singleton lookups** — An extra level of indirection for every seek.
- **Non-aligned unique constraints** — Cannot include non-partitioning columns in unique indexes that are aligned.
- **Cross-partition queries** — Aggregations and joins across many partitions can be slower than a single table scan.

**Partitioning is primarily an administrative/manageability feature, not a performance feature.** The performance benefit comes from partition elimination and efficient data lifecycle operations, not from "making queries faster" in general.

---

## Partitioning vs. Archiving Strategies

| Strategy | Approach | Best For |
|----------|----------|----------|
| **Partition SWITCH** | Move data to archive table instantly | Large volumes, frequent archive cycles |
| **DELETE with batching** | Delete old rows in loops | Small volumes, no partitioning |
| **Stretch Database** (deprecated) | Transparently move cold data to Azure | Hybrid cloud (pre-deprecation) |
| **Temporal table + archive** | Automatic history table | Audit/versioning scenarios |
| **Partitioned views** | UNION ALL across multiple tables | Distributed data, cross-server |

```sql
-- Partitioned view alternative (when true partitioning is not available)
CREATE VIEW Sales.AllOrders AS
    SELECT * FROM Sales.Orders_2024
    UNION ALL
    SELECT * FROM Sales.Orders_2025
    UNION ALL
    SELECT * FROM Sales.Orders_2026;
```

Each underlying table has a `CHECK` constraint on the date range, enabling the optimizer to eliminate irrelevant tables.

---

## Common Interview Questions & Answers

### Q1: What is the difference between RANGE LEFT and RANGE RIGHT?

**A:** With RANGE RIGHT, the boundary value is the first value in the next (right) partition. With RANGE LEFT, the boundary value is the last value in the current (left) partition. For date-based monthly partitioning, RANGE RIGHT with first-of-month boundaries (e.g., `'2025-01-01'`, `'2025-02-01'`) is the most intuitive: each partition contains dates from the boundary value up to (but not including) the next boundary.

### Q2: Why must the partitioning column be part of every unique index?

**A:** SQL Server enforces uniqueness per partition, not globally, for aligned indexes. If the partitioning column is not in the unique index, SQL Server cannot guarantee uniqueness across partitions without checking all of them — which would require a non-aligned (global) index. This is a fundamental architectural constraint. To have a truly unique column that is not the partitioning column, you must create a non-aligned unique index, which then prevents SWITCH operations.

### Q3: Explain the sliding window pattern.

**A:** The sliding window maintains a rolling set of partitions (e.g., 24 months of data). On one end, you SWITCH OUT the oldest partition to an archive/staging table (metadata-only, instant), then MERGE to remove the empty boundary. On the other end, you set NEXT USED on the partition scheme, then SPLIT to add a new boundary for incoming data. The key rule is to never SPLIT or MERGE partitions that contain data, as that causes expensive data movement.

### Q4: What is partition elimination and how do you verify it?

**A:** Partition elimination is when the query optimizer determines at compile or run time that certain partitions cannot contain data matching the query's WHERE clause, and skips scanning them. You verify it by examining the execution plan — look at the `Actual Partitions Accessed` property on the table scan/seek operator. If it shows a subset (e.g., `5..5`) rather than all partitions (e.g., `1..12`), elimination is working.

### Q5: What are the requirements for ALTER TABLE SWITCH?

**A:** Both tables must have identical column definitions, identical indexes (including clustered), be on the same filegroup, and the target must be empty (for switch-in). The target needs a CHECK constraint that matches the partition boundary. All indexes must be aligned. Foreign keys referencing the source table must be dropped. No full-text indexes can exist on the table.

### Q6: Should you partition a table purely for query performance?

**A:** Generally no. Partitioning is primarily a manageability and data lifecycle feature. It helps query performance only through partition elimination — and only when queries consistently filter on the partitioning column. For general query performance, proper indexing is far more effective. Partitioning a small table or a table queried without the partitioning column in the WHERE clause can actually degrade performance due to the overhead of the partition scheme.

### Q7: How does partitioning interact with columnstore indexes?

**A:** Partitioned tables can have clustered columnstore indexes. Each partition gets its own set of rowgroups. This works well — you get partition elimination plus columnstore compression. SWITCH operations work with columnstore indexes as long as both source and target have matching columnstore indexes. Partition-level REBUILD compresses the deltastore for that partition into columnstore rowgroups.

### Q8: What is the maximum number of partitions per table?

**A:** SQL Server supports up to **15,000 partitions** per table (since SQL Server 2012). The pre-2012 limit was 1,000. While you can use many partitions, having thousands of partitions increases metadata overhead and can slow down compile times for queries that touch many partitions.

---

## Tips

- **Use RANGE RIGHT with first-of-period boundaries** for date partitioning — it is the most intuitive and widely understood approach.
- **Always SWITCH data out before MERGE, and SPLIT only empty partitions.** Data movement from SPLIT/MERGE on non-empty partitions is catastrophically expensive on large tables.
- **Keep an empty partition on each end** of your range to make the sliding window pattern work cleanly.
- **Set NEXT USED before SPLIT** — failing to do so causes the SPLIT to fail.
- **Use `LOCK_ESCALATION = AUTO`** on partitioned tables to prevent table-level lock escalation from blocking other partitions.
- **Align all indexes** unless you have a specific reason not to (e.g., a global unique constraint). Non-aligned indexes prevent SWITCH.
- **The partitioning column must be in every unique constraint and primary key.** Design your keys with this in mind from the start.
- **Test partition elimination** with actual execution plans before assuming partitioning is helping your queries.
- **Consider data compression per partition** — use ROW compression for frequently modified partitions and PAGE compression for read-heavy or archival partitions.
- **Partitioning is an Enterprise Edition feature** (or Developer Edition). Standard Edition does not support it.
