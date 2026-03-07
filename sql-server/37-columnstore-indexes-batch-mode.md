# Columnstore Indexes & Batch Mode

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [Columnstore Architecture](#columnstore-architecture)
3. [Row Groups & Column Segments](#row-groups--column-segments)
4. [Dictionaries](#dictionaries)
5. [Delta Store & Tuple Mover](#delta-store--tuple-mover)
6. [Clustered vs Nonclustered Columnstore](#clustered-vs-nonclustered-columnstore)
7. [Batch Mode Processing](#batch-mode-processing)
8. [Batch Mode on Rowstore (SQL Server 2019+)](#batch-mode-on-rowstore-sql-server-2019)
9. [Columnstore Compression](#columnstore-compression)
10. [Supported Data Types](#supported-data-types)
11. [Maintenance: REORGANIZE & REBUILD](#maintenance-reorganize--rebuild)
12. [Filtered Nonclustered Columnstore Indexes](#filtered-nonclustered-columnstore-indexes)
13. [Real-Time Operational Analytics](#real-time-operational-analytics)
14. [Columnstore DMVs](#columnstore-dmvs)
15. [Performance Benefits for Analytics](#performance-benefits-for-analytics)
16. [Common Interview Questions](#common-interview-questions)
17. [Tips](#tips)

---

## Introduction

Columnstore indexes were introduced in SQL Server 2012 and have evolved significantly through subsequent releases. They store and query data in a columnar format rather than the traditional row-based format. This design delivers massive performance gains for analytical and data warehouse workloads by enabling high compression ratios, segment elimination, and batch mode execution.

Understanding columnstore technology is critical for any senior Data Engineer working with SQL Server, as it represents the primary mechanism for optimizing large-scale analytical queries.

---

## Columnstore Architecture

Traditional rowstore indexes store data row-by-row on 8KB pages. Columnstore indexes fundamentally change this by storing data **column-by-column** in compressed segments.

### High-Level Architecture

```
Columnstore Index
├── Row Group 1 (up to ~1,048,576 rows)
│   ├── Column Segment: OrderID (compressed)
│   ├── Column Segment: CustomerID (compressed)
│   ├── Column Segment: OrderDate (compressed)
│   └── Column Segment: Amount (compressed)
├── Row Group 2
│   ├── Column Segment: OrderID (compressed)
│   ├── ...
├── Delta Store (open / closed)
│   └── B-tree rowstore structure for recent inserts
└── Delete Bitmap
    └── Tracks logically deleted rows
```

### Why Columnar Storage Matters

- **Compression**: Values in the same column tend to be similar, yielding excellent compression (often 10x or more).
- **I/O Reduction**: Queries that touch only a few columns read only those column segments, not entire rows.
- **Segment Elimination**: Min/max metadata per segment allows the engine to skip entire segments that cannot satisfy a predicate.
- **Batch Mode Execution**: Processing ~900 rows at a time instead of row-by-row.

---

## Row Groups & Column Segments

### Row Groups

A **row group** is a logical partition of rows within the columnstore index. Each row group contains up to **1,048,576 rows** (approximately 1 million).

- The quality of a columnstore index depends heavily on the fullness of its row groups.
- Row groups with significantly fewer rows than the maximum are considered **trimmed** and may degrade performance.
- Row groups can be in one of several states: OPEN, CLOSED, COMPRESSED, or TOMBSTONE.

### Column Segments

Each column in a row group is stored as a separate **column segment**. A column segment is a contiguous unit of compressed data stored as a LOB (Large Object).

Key properties of segments:
- Each segment has **min and max values** stored as metadata (used for segment elimination).
- Segments are compressed using various encoding schemes (value encoding, dictionary encoding, run-length encoding).
- A segment maps to exactly one column in one row group.

```sql
-- Check segment details
SELECT
    s.name AS SchemaName,
    t.name AS TableName,
    i.name AS IndexName,
    cs.column_id,
    c.name AS ColumnName,
    cs.row_count,
    cs.min_data_id,
    cs.max_data_id,
    cs.on_disk_size AS SegmentSizeBytes,
    cs.encoding_type
FROM sys.column_store_segments cs
JOIN sys.partitions p ON cs.hobt_id = p.hobt_id
JOIN sys.indexes i ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.tables t ON i.object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.columns c ON t.object_id = c.object_id AND cs.column_id = c.column_id
WHERE t.name = 'FactSales';
```

---

## Dictionaries

Columnstore indexes use **dictionaries** for string and certain other data types to map repeated values to compact integer keys.

### Types of Dictionaries

| Dictionary Type | Description |
|----------------|-------------|
| **Global Dictionary** | Shared across all row groups; built during index creation or rebuild |
| **Local Dictionary** | Specific to a single row group/segment; built when global dictionary overflows |

### How Dictionaries Work

1. Unique values in a column are assigned integer IDs in the dictionary.
2. The column segment stores integer IDs instead of actual values.
3. At query time, the engine maps IDs back to values when needed.

```sql
-- View dictionary information
SELECT
    t.name AS TableName,
    d.column_id,
    c.name AS ColumnName,
    d.dictionary_id,
    d.type_desc AS DictionaryType,
    d.entry_count,
    d.on_disk_size AS DictionarySizeBytes
FROM sys.column_store_dictionaries d
JOIN sys.partitions p ON d.hobt_id = p.hobt_id
JOIN sys.tables t ON p.object_id = t.object_id
JOIN sys.columns c ON t.object_id = c.object_id AND d.column_id = c.column_id
WHERE t.name = 'FactSales';
```

---

## Delta Store & Tuple Mover

### Delta Store

The **delta store** is a rowstore B-tree structure that temporarily holds rows before they are compressed into columnstore row groups. This mechanism enables efficient insert operations without the overhead of immediately compressing small batches.

- **Open Delta Store**: Actively accepting new inserts.
- **Closed Delta Store**: Has reached the threshold (~1,048,576 rows) or has been manually closed; waiting for compression.

### Tuple Mover

The **tuple mover** is a background process that compresses closed delta stores into columnstore row groups.

- Runs approximately every 5 minutes.
- Compresses closed delta stores into compressed row groups.
- Starting in SQL Server 2016, the tuple mover runs with more parallelism and urgency.

```sql
-- Check delta store status
SELECT
    t.name AS TableName,
    rg.state_desc,
    rg.total_rows,
    rg.deleted_rows,
    rg.size_in_bytes,
    rg.trim_reason_desc
FROM sys.dm_db_column_store_row_group_physical_stats rg
JOIN sys.tables t ON rg.object_id = t.object_id
ORDER BY t.name, rg.row_group_id;
```

### Insert Behavior

| Insert Size | Behavior |
|-------------|----------|
| < 102,400 rows | Goes to delta store |
| >= 102,400 rows | Directly compressed into columnstore row groups |

> **Tip**: For bulk loading, always aim for batch sizes >= 102,400 rows (ideally close to 1,048,576) to bypass the delta store entirely.

---

## Clustered vs Nonclustered Columnstore

### Clustered Columnstore Index (CCI)

- The **entire table** is stored in columnar format.
- Replaces the heap or clustered rowstore index.
- Only **one** CCI allowed per table.
- Ideal for data warehouse fact tables.

```sql
-- Create a clustered columnstore index
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactSales
ON dbo.FactSales
WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE); -- optional: higher compression

-- Create with specific order (SQL Server 2022+)
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactSales
ON dbo.FactSales
ORDER (OrderDate, CustomerID);
```

### Nonclustered Columnstore Index (NCCI)

- Created **alongside** an existing rowstore table (heap or clustered index).
- Can include a **subset of columns**.
- Multiple NCCIs allowed per table.
- Enables hybrid transactional/analytical (HTAP) workloads.

```sql
-- Create a nonclustered columnstore index on selected columns
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactSales_Analytics
ON dbo.FactSales (OrderDate, ProductID, Quantity, Amount);

-- Filtered NCCI
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_FactSales_Recent
ON dbo.FactSales (OrderDate, ProductID, Quantity, Amount)
WHERE OrderDate >= '2025-01-01';
```

### Comparison

| Feature | Clustered Columnstore | Nonclustered Columnstore |
|---------|----------------------|-------------------------|
| Table storage | Entire table is columnar | Separate structure alongside rowstore |
| Number per table | 1 | Multiple |
| Column subset | No (all columns) | Yes |
| Filter predicate | No | Yes |
| Primary use case | Data warehouse / analytics | Hybrid OLTP + analytics |
| Updateable | Yes (SQL 2014+) | Yes (SQL 2016+) |

---

## Batch Mode Processing

### What Is Batch Mode?

Batch mode is an execution engine optimization where SQL Server processes **~900 rows at a time** as a batch instead of one row at a time. This is fundamentally more efficient for analytical queries.

### Row Mode vs Batch Mode

| Aspect | Row Mode | Batch Mode |
|--------|----------|------------|
| Processing unit | 1 row | ~900 rows |
| CPU efficiency | Lower (per-row overhead) | Higher (vectorized, SIMD-friendly) |
| Operators | All operators | Subset of operators |
| Typical speedup | Baseline | 2x - 10x or more |

### Batch Mode Operators

The following operators support batch mode:
- Columnstore Index Scan
- Hash Join / Hash Aggregate
- Sort
- Filter
- Compute Scalar (limited)
- Window Aggregate
- Concatenation (UNION ALL)
- Batch Mode Adaptive Join (SQL 2017+)
- Batch Mode Memory Grant Feedback (SQL 2017+)

```sql
-- Check if a query uses batch mode
SET STATISTICS XML ON;
-- Run your query, then inspect the execution plan for:
-- ActualExecutionMode="Batch" vs ActualExecutionMode="Row"
SET STATISTICS XML OFF;
```

---

## Batch Mode on Rowstore (SQL Server 2019+)

SQL Server 2019 introduced **batch mode on rowstore**, which allows batch mode execution even when no columnstore index exists on the table. This is part of the Intelligent Query Processing (IQP) family.

### Requirements

- Database compatibility level 150 or higher.
- The query optimizer must estimate that batch mode will be beneficial.
- Works with rowstore heap or B-tree indexes.
- No columnstore index required.

### Scenarios Where It Helps

- Analytical queries against rowstore tables where creating a columnstore index is not feasible.
- Queries with large scans, hash joins, and aggregations.
- OLTP databases that occasionally run analytical queries.

```sql
-- Enable batch mode on rowstore (via compatibility level)
ALTER DATABASE AdventureWorksDW
SET COMPATIBILITY_LEVEL = 150;

-- Force batch mode via hint (if needed)
SELECT
    ProductID,
    SUM(Quantity) AS TotalQty,
    AVG(UnitPrice) AS AvgPrice
FROM dbo.FactSales
GROUP BY ProductID
OPTION (USE HINT('ALLOW_BATCH_MODE'));
```

### How to Verify

In the execution plan, look for operators with `ActualExecutionMode="Batch"` even though the underlying scan is a rowstore index scan.

---

## Columnstore Compression

Columnstore indexes use a multi-stage compression pipeline:

### Compression Stages

1. **Encoding**: Values are encoded using the most efficient method:
   - **Value Encoding**: Stores deltas from a base value (great for sequential/sorted data).
   - **Dictionary Encoding**: Maps repeated values to integer keys.
   - **Run-Length Encoding (RLE)**: Stores consecutive repeated values as (value, count) pairs.

2. **Bit Packing**: After encoding, values are packed into the minimum number of bits required.

3. **COLUMNSTORE_ARCHIVE Compression**: Optional additional compression using the xPress algorithm (similar to LZ77). Trades CPU for even higher compression.

```sql
-- Standard columnstore compression
CREATE CLUSTERED COLUMNSTORE INDEX CCI_Archive
ON dbo.FactSalesHistory;

-- Archive compression for cold data
ALTER INDEX CCI_Archive ON dbo.FactSalesHistory
REBUILD PARTITION = 3
WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE);
```

### Compression Ratios

| Scenario | Typical Compression Ratio |
|----------|--------------------------|
| Columnstore (standard) | 5x - 15x vs rowstore |
| Columnstore Archive | 10x - 30x vs rowstore |
| Sorted/ordered data | Higher ratios due to better RLE |

---

## Supported Data Types

### Fully Supported

- `int`, `bigint`, `smallint`, `tinyint`
- `decimal` / `numeric` (precision <= 18)
- `float`, `real`
- `money`, `smallmoney`
- `bit`
- `char`, `varchar` (non-MAX)
- `nchar`, `nvarchar` (non-MAX)
- `date`, `datetime`, `datetime2`, `smalldatetime`, `datetimeoffset`, `time`
- `binary`, `varbinary` (non-MAX)
- `uniqueidentifier`

### Not Supported (or with Limitations)

| Data Type | Status |
|-----------|--------|
| `varchar(max)`, `nvarchar(max)`, `varbinary(max)` | Supported in SQL Server 2017+ (with limitations) |
| `text`, `ntext`, `image` | Not supported |
| `xml` | Not supported |
| `sql_variant` | Not supported |
| `hierarchyid` | Not supported |
| `geography`, `geometry` | Not supported |
| `CLR UDTs` | Not supported |
| `decimal/numeric` with precision > 18 | Supported in SQL Server 2017+ |

---

## Maintenance: REORGANIZE & REBUILD

### REORGANIZE

An **online** operation that performs incremental maintenance:

- Compresses closed delta stores into compressed row groups.
- Merges smaller compressed row groups together.
- Physically removes rows marked for deletion in the delete bitmap.

```sql
-- Reorganize all row groups
ALTER INDEX CCI_FactSales ON dbo.FactSales REORGANIZE;

-- Reorganize with compressing all row groups (including open delta stores)
ALTER INDEX CCI_FactSales ON dbo.FactSales
REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
```

### REBUILD

A more thorough operation that **recreates the entire index**:

- Removes all deleted rows.
- Produces optimally sized row groups.
- Recalculates global dictionaries.
- Can be done online (SQL Server 2019 Enterprise+) or offline.

```sql
-- Offline rebuild
ALTER INDEX CCI_FactSales ON dbo.FactSales REBUILD;

-- Online rebuild (SQL Server 2019+ Enterprise)
ALTER INDEX CCI_FactSales ON dbo.FactSales
REBUILD WITH (ONLINE = ON);

-- Rebuild a specific partition
ALTER INDEX CCI_FactSales ON dbo.FactSales
REBUILD PARTITION = 5
WITH (DATA_COMPRESSION = COLUMNSTORE);
```

### When to Use Which

| Scenario | Recommended Action |
|----------|-------------------|
| Routine maintenance | REORGANIZE |
| Many small/trimmed row groups | REBUILD |
| High percentage of deleted rows (> 10%) | REORGANIZE first; REBUILD if needed |
| Need to change compression type | REBUILD |
| Must stay online | REORGANIZE (always online) or REBUILD with ONLINE = ON (2019+) |

### Monitoring Row Group Health

```sql
-- Identify row groups needing maintenance
SELECT
    OBJECT_NAME(rg.object_id) AS TableName,
    rg.index_id,
    rg.row_group_id,
    rg.state_desc,
    rg.total_rows,
    rg.deleted_rows,
    CAST(rg.deleted_rows * 100.0 / NULLIF(rg.total_rows, 0) AS DECIMAL(5,2)) AS DeletePct,
    rg.size_in_bytes,
    rg.trim_reason_desc
FROM sys.dm_db_column_store_row_group_physical_stats rg
WHERE rg.state_desc = 'COMPRESSED'
  AND (rg.deleted_rows * 100.0 / NULLIF(rg.total_rows, 0) > 10
       OR rg.total_rows < 100000)
ORDER BY DeletePct DESC;
```

---

## Filtered Nonclustered Columnstore Indexes

A **filtered NCCI** includes only rows that match a WHERE clause, reducing storage and maintenance overhead.

### Use Cases

- Analytical queries that focus on recent data while the table grows with historical data.
- Partitioned sliding-window patterns where only the current partition needs analytics.
- Reducing the impact of columnstore maintenance on OLTP workloads.

```sql
-- Filtered NCCI: only rows from the last year
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_RecentOrders
ON dbo.Orders (OrderDate, CustomerID, TotalAmount, ProductCategory)
WHERE OrderDate >= '2025-01-01';

-- As time progresses, drop and recreate with updated filter
DROP INDEX NCCI_RecentOrders ON dbo.Orders;

CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_RecentOrders
ON dbo.Orders (OrderDate, CustomerID, TotalAmount, ProductCategory)
WHERE OrderDate >= '2026-01-01';
```

### Limitations

- The filter predicate must be a simple comparison (no functions, no subqueries).
- The filter predicate cannot reference computed columns.
- The filter is not automatically updated; you must manually drop and recreate.

---

## Real-Time Operational Analytics

**Real-time operational analytics** is a pattern that combines a traditional clustered rowstore index (for OLTP) with a nonclustered columnstore index (for analytics) on the same table.

### Architecture

```
Table: dbo.Orders
├── Clustered Rowstore Index (PK) -- serves OLTP singleton lookups/inserts
└── Nonclustered Columnstore Index -- serves analytical scans/aggregations
```

### Benefits

- **No ETL required**: Analytical queries run directly against the OLTP table.
- **Minimal OLTP impact**: The NCCI is maintained asynchronously via the delta store.
- **Real-time data**: Analytics always reflect the latest committed data.

### Implementation

```sql
-- Step 1: OLTP table with clustered rowstore
CREATE TABLE dbo.SensorReadings (
    ReadingID BIGINT IDENTITY PRIMARY KEY,
    SensorID INT NOT NULL,
    ReadingTime DATETIME2 NOT NULL,
    Temperature DECIMAL(5,2),
    Humidity DECIMAL(5,2),
    Pressure DECIMAL(7,2)
);

-- Step 2: Add NCCI for analytics
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_SensorAnalytics
ON dbo.SensorReadings (SensorID, ReadingTime, Temperature, Humidity, Pressure);

-- OLTP query (uses rowstore clustered index)
SELECT * FROM dbo.SensorReadings WHERE ReadingID = 12345;

-- Analytical query (uses columnstore NCCI with batch mode)
SELECT
    SensorID,
    CAST(ReadingTime AS DATE) AS ReadingDate,
    AVG(Temperature) AS AvgTemp,
    MAX(Humidity) AS MaxHumidity
FROM dbo.SensorReadings
WHERE ReadingTime >= DATEADD(DAY, -7, GETDATE())
GROUP BY SensorID, CAST(ReadingTime AS DATE);
```

### Considerations

- The NCCI adds overhead to DML operations (INSERT, UPDATE, DELETE).
- Monitor the delta store size; too many open delta stores affect performance.
- Use `COMPRESS_ALL_ROW_GROUPS = ON` periodically to flush delta stores.

---

## Columnstore DMVs

### Key Dynamic Management Views

| DMV | Purpose |
|-----|---------|
| `sys.dm_db_column_store_row_group_physical_stats` | Row group states, sizes, and trim reasons |
| `sys.column_store_segments` | Per-segment metadata (min/max, size, encoding) |
| `sys.column_store_dictionaries` | Dictionary details (size, entry count, type) |
| `sys.dm_db_column_store_row_group_operational_stats` | Operational counters (scans, locks, latches) |

### Comprehensive Health Check Query

```sql
-- Columnstore index health dashboard
SELECT
    OBJECT_SCHEMA_NAME(rg.object_id) + '.' + OBJECT_NAME(rg.object_id) AS TableName,
    i.name AS IndexName,
    rg.partition_number,
    rg.state_desc,
    COUNT(*) AS RowGroupCount,
    SUM(rg.total_rows) AS TotalRows,
    SUM(rg.deleted_rows) AS DeletedRows,
    SUM(rg.size_in_bytes) / 1024 / 1024 AS SizeMB,
    AVG(rg.total_rows) AS AvgRowsPerGroup,
    SUM(CASE WHEN rg.total_rows < 100000 THEN 1 ELSE 0 END) AS SmallRowGroups,
    SUM(CASE WHEN rg.deleted_rows * 100.0 / NULLIF(rg.total_rows, 0) > 10 THEN 1 ELSE 0 END) AS HighDeleteGroups
FROM sys.dm_db_column_store_row_group_physical_stats rg
JOIN sys.indexes i ON rg.object_id = i.object_id AND rg.index_id = i.index_id
GROUP BY rg.object_id, i.name, rg.partition_number, rg.state_desc
ORDER BY TableName, rg.partition_number, rg.state_desc;
```

### Segment Elimination Tracking

```sql
-- Check if segment elimination is occurring
SELECT
    OBJECT_NAME(os.object_id) AS TableName,
    i.name AS IndexName,
    SUM(os.segment_reads) AS TotalSegmentReads,
    SUM(os.segment_skips) AS TotalSegmentSkips,
    CAST(SUM(os.segment_skips) * 100.0 /
         NULLIF(SUM(os.segment_reads) + SUM(os.segment_skips), 0) AS DECIMAL(5,2)) AS SkipPct
FROM sys.dm_db_column_store_row_group_operational_stats os
JOIN sys.indexes i ON os.object_id = i.object_id AND os.index_id = i.index_id
GROUP BY os.object_id, i.name
ORDER BY SkipPct;
```

---

## Performance Benefits for Analytics

### Typical Performance Improvements

| Metric | Improvement |
|--------|------------|
| Storage size | 5x - 15x smaller |
| Analytical query speed | 10x - 100x faster |
| I/O reduction | 80% - 95% fewer reads |
| Memory efficiency | Compressed data stays in buffer pool |

### Best Practices for Maximum Performance

1. **Sort data before loading**: Sorted data yields better RLE compression and more effective segment elimination.
2. **Load in large batches**: Aim for multiples of 1,048,576 rows to create full row groups.
3. **Use ordered columnstore (SQL 2022+)**: The `ORDER` clause on CCI ensures segment quality.
4. **Partition large tables**: Combine partitioning with columnstore for partition-level maintenance.
5. **Avoid narrow row groups**: Monitor `trim_reason_desc` to diagnose why row groups are small.

```sql
-- Ordered CCI for optimal segment elimination (SQL Server 2022+)
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FactSales
ON dbo.FactSales
ORDER (OrderDate)
WITH (MAXDOP = 1); -- MAXDOP=1 ensures global sort order during build
```

---

## Common Interview Questions

### Q1: What is a columnstore index and how does it differ from a rowstore index?

**A**: A columnstore index stores data column-by-column rather than row-by-row. Each column is compressed independently into segments. This is beneficial for analytical queries because: (1) only the columns needed are read from disk, (2) values within a column are similar and compress well, (3) segment elimination can skip irrelevant data, and (4) batch mode execution processes ~900 rows at a time. Rowstore indexes are better for OLTP point lookups and small range scans.

### Q2: What is segment elimination and how can you maximize it?

**A**: Segment elimination is the ability of the query engine to skip entire column segments based on the min/max metadata stored for each segment. If a query predicate filters on a value outside the min-max range of a segment, that segment is never read. To maximize it: (1) load data in sorted order on commonly filtered columns, (2) use ordered columnstore indexes in SQL 2022+, (3) rebuild the index after significant changes, (4) monitor segment elimination using `sys.dm_db_column_store_row_group_operational_stats`.

### Q3: Explain the delta store and tuple mover.

**A**: The delta store is a hidden B-tree (rowstore) structure that buffers small inserts before they are compressed into the columnstore. When a delta store reaches ~1M rows or is manually closed, it becomes a "closed" delta store. The tuple mover is a background thread that compresses closed delta stores into compressed row groups. In SQL 2016+, the tuple mover was improved to handle multiple delta stores concurrently.

### Q4: When would you use a nonclustered columnstore index instead of a clustered one?

**A**: Use an NCCI when: (1) the table primarily serves OLTP workloads but occasionally needs analytical queries (real-time operational analytics), (2) you only need to accelerate queries on a subset of columns, (3) you want to apply a filter to limit which rows are included, (4) you cannot change the existing table structure. A CCI is preferred for dedicated analytics/warehouse tables.

### Q5: What is batch mode on rowstore and when is it used?

**A**: Introduced in SQL Server 2019, batch mode on rowstore allows the query optimizer to use batch mode execution even when no columnstore index exists. It requires compatibility level 150+. The optimizer will choose it when it estimates a significant benefit, typically for queries with large scans, hash joins, or aggregations. This helps analytical queries on OLTP tables without the overhead of maintaining a columnstore index.

### Q6: How do you maintain a columnstore index?

**A**: Two primary operations: (1) `REORGANIZE` is an online operation that compresses delta stores, merges small row groups, and physically removes deleted rows. Use `COMPRESS_ALL_ROW_GROUPS = ON` to force open delta stores into compressed format. (2) `REBUILD` recreates the entire index, producing optimal row groups and fresh dictionaries. It can be done online in SQL 2019+ Enterprise. Routine maintenance should use REORGANIZE; periodic or structural changes warrant REBUILD.

### Q7: What are the trim reasons for row groups, and why do they matter?

**A**: Trim reasons explain why a row group has fewer than the maximum 1,048,576 rows. Common reasons include: `DICTIONARY_SIZE` (dictionary exceeded 16MB), `MEMORY_LIMITATION` (insufficient memory during compression), `BULKLOAD` (bulk insert batch didn't have enough rows), `RESIDUAL_ROW_GROUP` (leftover rows from load). They matter because trimmed row groups reduce compression ratios and query performance. Monitor via `sys.dm_db_column_store_row_group_physical_stats.trim_reason_desc`.

### Q8: Can you update a table with a clustered columnstore index?

**A**: Yes, since SQL Server 2014. UPDATE and DELETE operations use a delete bitmap to mark existing rows as deleted, then INSERT the new version (for updates). This is efficient for moderate DML. Heavy update/delete workloads will cause the delete bitmap to grow, requiring REORGANIZE to reclaim space. Direct inserts go through the delta store (small batches) or directly into compressed row groups (large batches).

---

## Tips

- **Always check row group quality after loading data.** Small or trimmed row groups are the number one performance killer for columnstore queries.
- **Use partition switching with columnstore** for efficient data lifecycle management in large fact tables.
- **Combine columnstore with In-Memory OLTP** for the highest performance in HTAP scenarios (SQL Server 2016+).
- **Monitor segment elimination rates.** Low skip percentages mean your data is not well-sorted for the predicates being used.
- **For initial loads, use `MAXDOP = 1`** when building ordered columnstore indexes to guarantee the sort order across all row groups.
- **Archive compression (`COLUMNSTORE_ARCHIVE`)** is excellent for cold partitions that are rarely queried but must remain online.
- **Test batch mode on rowstore** before adding a columnstore index. SQL 2019+ may give you adequate analytical performance without the maintenance overhead.
- **String columns with high cardinality** compress poorly in columnstore. Consider normalizing them into lookup tables with integer keys.