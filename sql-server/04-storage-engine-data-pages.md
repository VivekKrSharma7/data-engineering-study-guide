# Storage Engine & Data Pages

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Page Structure](#page-structure)
2. [Page Types](#page-types)
3. [Extents](#extents)
4. [Data Row Structure](#data-row-structure)
5. [Row-Overflow and LOB Data](#row-overflow-and-lob-data)
6. [Allocation Units](#allocation-units)
7. [Heaps vs Clustered Tables](#heaps-vs-clustered-tables)
8. [Forwarding Pointers](#forwarding-pointers)
9. [Page Splits](#page-splits)
10. [Fill Factor](#fill-factor)
11. [Filegroups](#filegroups)
12. [Diagnostic Tools](#diagnostic-tools)
13. [Common Interview Questions](#common-interview-questions)
14. [Tips for the Interview](#tips-for-the-interview)

---

## Page Structure

The **page** is the fundamental unit of data storage in SQL Server. Every page is exactly **8 KB (8,192 bytes)** in size. This is non-configurable and has been the same since SQL Server 7.0.

### Anatomy of a Page

| Section | Size | Description |
|---------|------|-------------|
| **Page Header** | 96 bytes | Metadata about the page (page number, page type, free space, object ID, etc.) |
| **Data Area** | 8,060 bytes | Actual row data |
| **Row Offset Array** | Variable (2 bytes per row) | Array of 2-byte entries pointing to the start of each row; grows from the end of the page backward |

**Key header fields include:**

- `m_pageId` — File number and page number within that file
- `m_type` — The page type (1 = data, 2 = index, etc.)
- `m_flagBits` — Flags indicating page status
- `m_objId` — Allocation unit ID (not the user object_id)
- `m_freeData` — Offset to the first free byte on the page
- `m_freeCnt` — Number of free bytes on the page
- `m_slotCnt` — Number of rows (slots) on the page
- `m_lsn` — Log sequence number of the last log record that changed the page
- `m_tornBits` — Used for torn page detection

### Maximum Row Size

Because the data area is 8,060 bytes and the row offset array consumes 2 bytes per row, the **maximum in-row data size for a single row is 8,060 bytes**. Rows that exceed this limit use row-overflow or LOB storage.

---

## Page Types

SQL Server uses several specialized page types:

### Data and Index Pages

| Type ID | Page Type | Purpose |
|---------|-----------|---------|
| 1 | **Data page** | Stores in-row data for heaps and clustered indexes |
| 2 | **Index page** | Stores index rows for non-clustered indexes and internal levels of clustered indexes |

### Allocation and Tracking Pages

| Type ID | Page Type | Purpose |
|---------|-----------|---------|
| 3 | **Text/Image page** | Stores LOB data (text, ntext, image, varchar(max), etc.) |
| 8 | **GAM (Global Allocation Map)** | Tracks which extents are allocated. One bit per extent; 1 = free, 0 = allocated. Covers ~4 GB of data per GAM page. |
| 9 | **SGAM (Shared GAM)** | Tracks mixed extents with at least one free page. 1 = mixed extent with free pages. |
| 10 | **IAM (Index Allocation Map)** | Maps which extents belong to a specific allocation unit (table/index partition). Each IAM page covers ~4 GB. |
| 11 | **PFS (Page Free Space)** | Tracks allocation status and free space for each page. One byte per page; covers ~8,000 pages (~64 MB). Byte encodes: allocated or not, % full (0%, 1-50%, 51-80%, 81-95%, 96-100%), ghost records, IAM page flag. |

### Special Pages

| Type ID | Page Type | Purpose |
|---------|-----------|---------|
| 13 | **Boot page** | Page 9 of file 1 only; stores database metadata |
| 15 | **File header page** | Page 0 of every database file |
| 17 | **Differential changed map (DCM)** | Tracks extents modified since last full backup |
| 16 | **Bulk changed map (BCM)** | Tracks extents modified by bulk-logged operations since last log backup |

### How Allocation Pages Work Together

When SQL Server needs to allocate a new page:

1. **PFS** is checked to find pages with enough free space in already-allocated extents
2. **GAM** is checked to find completely free extents (for uniform extent allocation)
3. **SGAM** is checked to find mixed extents with available pages (for small tables)
4. **IAM** chains track which pages/extents belong to a specific object

---

## Extents

An **extent** is a group of **8 contiguous pages (64 KB)**. Extents are the basic unit of space allocation.

### Uniform Extents

- All 8 pages belong to a **single object**
- Used once a table or index grows beyond 8 pages
- Allocated via the GAM page

### Mixed Extents

- Pages can belong to **different objects**
- Used for small tables/indexes (up to 8 pages) to avoid wasting space
- Tracked by the SGAM page

```
Mixed Extent Example:
+--------+--------+--------+--------+--------+--------+--------+--------+
| Page 0 | Page 1 | Page 2 | Page 3 | Page 4 | Page 5 | Page 6 | Page 7 |
| Tbl A  | Tbl B  | Tbl A  | Tbl C  | (free) | Tbl B  | (free) | Tbl D  |
+--------+--------+--------+--------+--------+--------+--------+--------+
```

**Important behavior change:** Starting with SQL Server 2016 and using trace flag 1118 (or by default in tempdb), SQL Server allocates uniform extents immediately, skipping mixed extents. In SQL Server 2016+, this is the **default behavior for tempdb**. For user databases, TF 1118 makes this the default.

---

## Data Row Structure

Each data row on a page has the following internal structure:

```
+------------------+-------------------+---------------------+---------------------+
| Status Bits (2B) | Fixed-length data | Null Bitmap         | Variable-length data|
+------------------+-------------------+---------------------+---------------------+
```

### Detailed Breakdown

| Component | Size | Description |
|-----------|------|-------------|
| **Status Bits A** | 1 byte | Row type (data row, ghost, forwarded, etc.) |
| **Status Bits B** | 1 byte | Additional flags |
| **Fixed-length data offset** | 2 bytes | Pointer to end of fixed-length columns |
| **Fixed-length columns** | Variable | All fixed-length column values in column order |
| **Null bitmap column count** | 2 bytes | Number of columns in the row |
| **Null bitmap** | 1 bit per column | One bit per column; 1 = NULL. Present even if no columns allow NULL. |
| **Variable-length column count** | 2 bytes | Number of variable-length columns |
| **Variable-length offset array** | 2 bytes per column | End offset of each variable-length column |
| **Variable-length data** | Variable | Actual variable-length column values |

### Row Overhead

Minimum row overhead is approximately **9 bytes** (status bits + fixed data offset + null bitmap count + null bitmap for up to 8 columns). This means even a table with a single `tinyint` column uses more than 1 byte per row.

---

## Row-Overflow and LOB Data

### Row-Overflow Data

When a row's total in-row data exceeds **8,060 bytes**, SQL Server pushes one or more variable-length columns to **row-overflow pages**:

- The column value is replaced with a **24-byte pointer** on the in-row data page
- The actual data is stored on a separate **text/image page** (type 3)
- Applies to `varchar(n)`, `nvarchar(n)`, `varbinary(n)`, `sql_variant`, and CLR UDT columns where `n` is large enough that the row could exceed 8,060 bytes

```sql
-- Example: a table that can trigger row-overflow
CREATE TABLE dbo.WideRow (
    ID        INT NOT NULL,
    Col1      VARCHAR(5000),
    Col2      VARCHAR(5000)
);
-- A single row with Col1 = 4000 chars and Col2 = 4500 chars exceeds 8060 bytes.
-- SQL Server will push one column off-row automatically.
```

### LOB Data

Large Object data types are **always** stored off-row (or partially in-row):

- `text`, `ntext`, `image` — Always off-row (deprecated; avoid in new designs)
- `varchar(max)`, `nvarchar(max)`, `varbinary(max)` — Stored in-row if the value fits within the 8,060-byte limit; otherwise off-row
- `xml` — Same behavior as `varchar(max)`

The **`large value types out of row`** table option forces `max` types to always be stored off-row:

```sql
EXEC sp_tableoption 'dbo.MyTable', 'large value types out of row', 'ON';
```

### LOB Storage Structures

- **Small LOB values** (up to 8,000 bytes if row space allows): stored in-row
- **Medium LOB values** (up to 32 KB - 40 KB): stored in a **LOB B-tree** with a root pointer in the row
- **Large LOB values** (> ~40 KB): stored in a **LOB B-tree** which may span many text/image pages

---

## Allocation Units

Every table or index partition has up to **three allocation units**, each with its own IAM chain:

| Allocation Unit | Stores | Conditions |
|----------------|--------|------------|
| **IN_ROW_DATA** | Data rows and index rows that fit within 8,060 bytes | Always present |
| **ROW_OVERFLOW_DATA** | Variable-length columns that overflow the 8,060-byte row limit | Created on demand |
| **LOB_DATA** | Large object data (text, ntext, image, varchar(max), etc.) | Created on demand |

```sql
-- View allocation units for a specific table
SELECT
    o.name AS table_name,
    p.partition_number,
    au.type_desc AS allocation_unit_type,
    au.total_pages,
    au.used_pages,
    au.data_pages
FROM sys.allocation_units au
JOIN sys.partitions p ON au.container_id = p.hobt_id
JOIN sys.objects o ON p.object_id = o.object_id
WHERE o.name = 'YourTableName';
```

---

## Heaps vs Clustered Tables

### Heaps

A **heap** is a table without a clustered index. Data has **no logical order**; pages are tracked only by the IAM chain.

**Characteristics:**
- Rows are identified by a **Row Identifier (RID)**: `FileID:PageID:SlotNumber`
- Non-clustered index leaf rows contain the RID as the row locator
- Inserts go to any page with available space (found via PFS)
- No ordering is maintained
- Table scans follow the IAM chain (not page linkage)

**When heaps can be appropriate:**
- Staging tables for ETL where data is bulk-loaded and then dropped/truncated
- Very small lookup tables
- Tables that are always fully scanned

### Clustered Tables

A table with a **clustered index** stores data in the leaf level of a B-tree, ordered by the clustering key.

**Characteristics:**
- Leaf-level pages are doubly linked in logical key order
- Non-clustered index leaf rows contain the clustering key as the row locator
- Inserts go to the correct logical position based on key value
- Range scans are efficient because data is ordered

```sql
-- Determine if a table is a heap or has a clustered index
SELECT
    o.name,
    i.index_id,
    i.type_desc
FROM sys.indexes i
JOIN sys.objects o ON i.object_id = o.object_id
WHERE o.name = 'YourTableName' AND i.index_id IN (0, 1);
-- index_id = 0 => Heap
-- index_id = 1 => Clustered Index
```

### Key Differences Summary

| Aspect | Heap | Clustered Table |
|--------|------|-----------------|
| Row locator | RID (FileID:PageID:Slot) | Clustering key |
| Data ordering | None | Ordered by clustering key |
| NCI bookmark | RID (8 bytes) | Clustering key value |
| NCI bookmark lookup | RID lookup (single I/O) | Key lookup (B-tree traversal) |
| Fragmentation concern | Forwarding pointers | Page splits |
| INSERT behavior | Any available page | Correct key-order position |

---

## Forwarding Pointers

Forwarding pointers are a **heap-only** phenomenon.

### How They Work

1. A row in a heap is updated and the new row size no longer fits on the original page
2. SQL Server moves the row to a new page with enough space
3. A **forwarding pointer** (a stub) is left at the original RID location, pointing to the new location
4. Non-clustered indexes still reference the old RID and follow the forwarding pointer

### Why They Exist

Without forwarding pointers, SQL Server would need to update **every** non-clustered index that references the moved row. Forwarding pointers avoid this cost.

### The Problem

Forwarding pointers cause **extra I/O** — a logical read hits the original page, follows the pointer, and reads the new page. Chains can even form (forwarding to forwarding), though SQL Server limits this to one hop by updating the pointer.

### Detection and Resolution

```sql
-- Detect forwarding pointers
SELECT
    object_name(object_id) AS table_name,
    forwarded_record_count,
    page_count
FROM sys.dm_db_index_physical_stats(
    DB_ID(), OBJECT_ID('dbo.YourHeap'), 0, NULL, 'DETAILED'
);

-- Fix: rebuild the heap (SQL Server 2008+)
ALTER TABLE dbo.YourHeap REBUILD;

-- Or: create a clustered index, then drop it
CREATE CLUSTERED INDEX CIX_Temp ON dbo.YourHeap(SomeColumn);
DROP INDEX CIX_Temp ON dbo.YourHeap;
```

---

## Page Splits

Page splits occur in **clustered indexes and non-clustered indexes** (not heaps) when a new row must be inserted into a page that is full.

### Types of Page Splits

**Good page splits (append at the end):**
- When inserting into an ever-increasing key (e.g., `IDENTITY`, sequential `GUID`)
- A new page is allocated and the new row goes there
- Minimal overhead

**Bad page splits (mid-page):**
- When inserting into the middle of an ordered set of pages
- SQL Server allocates a new page and **moves approximately 50% of the rows** from the full page to the new page
- Both pages are logged (expensive)
- Causes **logical fragmentation** (pages no longer physically contiguous)
- Causes **low page density** (pages are ~50% full after the split)

### Monitoring Page Splits

```sql
-- Performance counter
SELECT cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name = 'Page Splits/sec'
  AND object_name LIKE '%Access Methods%';

-- Extended events
CREATE EVENT SESSION [PageSplits] ON SERVER
ADD EVENT sqlserver.transaction_log(
    WHERE operation = 11  -- LOP_DELETE_SPLIT
)
ADD TARGET package0.ring_buffer;
```

### Mitigating Page Splits

1. Use a **sequential clustering key** (IDENTITY, sequence)
2. Set an appropriate **fill factor** (see below)
3. Rebuild indexes regularly to restore page density
4. Avoid random GUIDs as clustering keys (use `NEWSEQUENTIALID()` if GUID is required)

---

## Fill Factor

**Fill factor** determines the percentage of space on each **leaf-level page** that is filled with data when an index is created or rebuilt.

### Key Points

- Default is **0 (or 100)** — pages are filled completely
- A fill factor of **80** means 20% free space is left on each leaf page during rebuild
- Only applies during `CREATE INDEX` or `ALTER INDEX REBUILD` — not during normal operations
- **Non-leaf (intermediate) pages** are always filled to accommodate at least two rows regardless of fill factor
- Server-wide default can be set with `sp_configure 'fill factor'`

```sql
-- Set fill factor on a specific index
CREATE NONCLUSTERED INDEX IX_Orders_OrderDate
ON dbo.Orders(OrderDate)
WITH (FILLFACTOR = 80);

-- Rebuild with a fill factor
ALTER INDEX IX_Orders_OrderDate ON dbo.Orders
REBUILD WITH (FILLFACTOR = 80);

-- Check current fill factor
SELECT name, fill_factor
FROM sys.indexes
WHERE object_id = OBJECT_ID('dbo.Orders');
```

### Guidelines

| Scenario | Recommended Fill Factor |
|----------|------------------------|
| IDENTITY / sequential key, mostly inserts | 100 (default) |
| Random inserts, heavy updates that change row size | 70-80 |
| Read-heavy, rarely modified | 100 |
| Highly volatile with random keys | 50-70 (rare; investigate root cause) |

**Trade-off:** Lower fill factor = fewer page splits but more pages to read (more I/O for scans). Always test and measure.

---

## Filegroups

Filegroups are logical containers for database files, providing a way to organize and manage data placement.

### Types

| Filegroup | Description |
|-----------|-------------|
| **PRIMARY** | Default filegroup; contains the primary data file (.mdf) and system tables |
| **User-defined** | Additional filegroups for organizing user data |
| **FILESTREAM** | Special filegroup for FILESTREAM data stored in the file system |
| **Memory-optimized** | For In-Memory OLTP tables (SQL Server 2014+) |

### Key Concepts

```sql
-- Create a filegroup and add a file
ALTER DATABASE MyDB ADD FILEGROUP FG_Archive;
ALTER DATABASE MyDB ADD FILE (
    NAME = 'MyDB_Archive',
    FILENAME = 'D:\Data\MyDB_Archive.ndf',
    SIZE = 1GB,
    FILEGROWTH = 256MB
) TO FILEGROUP FG_Archive;

-- Place a table on a specific filegroup
CREATE TABLE dbo.ArchiveData (
    ID INT PRIMARY KEY,
    Data VARCHAR(500)
) ON FG_Archive;

-- Place an index on a different filegroup
CREATE NONCLUSTERED INDEX IX_Data
ON dbo.ArchiveData(Data)
ON FG_Indexes;
```

### Benefits of Multiple Filegroups

1. **Performance** — Place filegroups on different physical disks for I/O parallelism
2. **Partial backup/restore** — Back up and restore individual filegroups (piecemeal restore)
3. **Partitioned tables** — Map partition functions to different filegroups
4. **Read-only filegroups** — Mark historical data as read-only (skipped during backup after first backup)
5. **Administrative flexibility** — Manage storage growth by filegroup

---

## Diagnostic Tools

### DBCC PAGE

Undocumented but invaluable command for inspecting page internals:

```sql
-- Enable trace flag to send output to console
DBCC TRACEON(3604);

-- Syntax: DBCC PAGE(database_id, file_id, page_id, print_option)
-- print_option: 0 = header only, 1 = header + rows, 2 = header + hex dump, 3 = header + detailed rows
DBCC PAGE(N'MyDatabase', 1, 288, 3) WITH TABLERESULTS;
```

**Print options explained:**

| Option | Output |
|--------|--------|
| 0 | Page header only |
| 1 | Page header + row data (formatted) |
| 2 | Page header + full hex dump of page |
| 3 | Page header + detailed per-row interpretation (most useful) |

### sys.dm_db_index_physical_stats

The primary DMV for assessing physical storage health:

```sql
SELECT
    OBJECT_NAME(ps.object_id) AS table_name,
    i.name AS index_name,
    ps.index_type_desc,
    ps.alloc_unit_type_desc,
    ps.avg_fragmentation_in_percent,
    ps.avg_page_space_used_in_percent,
    ps.page_count,
    ps.record_count,
    ps.forwarded_record_count,
    ps.ghost_record_count
FROM sys.dm_db_index_physical_stats(
    DB_ID(), NULL, NULL, NULL, 'DETAILED'
) ps
JOIN sys.indexes i ON ps.object_id = i.object_id AND ps.index_id = i.index_id
WHERE ps.page_count > 100
ORDER BY ps.avg_fragmentation_in_percent DESC;
```

**Scan modes:**

| Mode | Speed | Detail |
|------|-------|--------|
| `LIMITED` | Fast | Scans non-leaf level pages only; no `avg_page_space_used_in_percent` |
| `SAMPLED` | Medium | Scans 1% sample of pages for large objects |
| `DETAILED` | Slow | Scans all pages; most accurate; required for `forwarded_record_count` |

### Other Useful Commands

```sql
-- Undocumented: see page allocations for a table
DBCC IND(N'MyDatabase', N'dbo.MyTable', -1);
-- -1 = all indexes; returns page IDs, types, index IDs

-- DMV alternative (SQL Server 2012+)
SELECT * FROM sys.dm_db_database_page_allocations(
    DB_ID(), OBJECT_ID('dbo.MyTable'), NULL, NULL, 'DETAILED'
);

-- Check table/index size
EXEC sp_spaceused 'dbo.MyTable';
```

---

## Common Interview Questions

### Q1: What is the size of a page in SQL Server, and can it be changed?

**A:** A page is 8 KB (8,192 bytes). This is fixed and cannot be changed. Of the 8,192 bytes, 96 bytes are the page header, leaving 8,096 bytes — but the usable space for row data is 8,060 bytes because of the row offset array overhead and internal structures.

### Q2: What happens when a row exceeds 8,060 bytes?

**A:** If a row has variable-length columns that cause it to exceed 8,060 bytes, SQL Server moves one or more variable-length columns to **row-overflow pages**, leaving a 24-byte pointer in the original row. If the table has LOB columns (varchar(max), varbinary(max), xml, etc.), large values go to **LOB pages**. A table definition where the *fixed-length* columns alone exceed 8,060 bytes will be rejected at CREATE TABLE time.

### Q3: What is the difference between a GAM and an SGAM page?

**A:** A **GAM** page tracks whether each extent in a 4 GB range is allocated or free (1 bit per extent; 1 = free). An **SGAM** page tracks mixed extents that have at least one free page (1 = mixed extent with free pages). Together they allow SQL Server to quickly find free space for new allocations: GAM for uniform extent allocation, SGAM for mixed extent allocation.

### Q4: What are forwarding pointers and why are they a problem?

**A:** Forwarding pointers occur in **heaps only** when an updated row no longer fits on its original page. A stub is left at the original location pointing to the new location. The problem is extra I/O — every access via a non-clustered index follows the original RID, hits the forwarding pointer, and then reads the new page. Fix by rebuilding the heap (`ALTER TABLE ... REBUILD`) or converting to a clustered index.

### Q5: Explain the difference between a page split and fragmentation.

**A:** A **page split** is the event — SQL Server must split a full page to accommodate a new row, moving ~50% of rows to a new page. **Fragmentation** is the result — after splits, the logical order of pages (by index key) no longer matches the physical order on disk. This causes random I/O during range scans. Fragmentation is measured by `avg_fragmentation_in_percent` in `sys.dm_db_index_physical_stats`.

### Q6: When would you use a heap instead of a clustered index?

**A:** Heaps are suitable for: (1) staging/ETL tables that are bulk-loaded and truncated, (2) very small tables where a full scan is always done, (3) tables with exclusively singleton RID lookups from non-clustered indexes (slightly faster than key lookups). In general, most tables benefit from a clustered index, and heaps should be a deliberate, justified choice.

### Q7: How does fill factor work, and does it persist after a rebuild?

**A:** Fill factor is the percentage of leaf-page space to fill during an index create or rebuild. It is a **metadata property** of the index, so it persists. When you run `ALTER INDEX REBUILD`, SQL Server uses the stored fill factor value. During normal DML operations, pages can fill to 100% regardless of the fill factor — it only applies at build/rebuild time.

### Q8: What are the different allocation units and when do they appear?

**A:** **IN_ROW_DATA** is always present for every table/index. **ROW_OVERFLOW_DATA** is created when a variable-length column value causes a row to exceed 8,060 bytes and the column is pushed off-row. **LOB_DATA** is created when the table has LOB data types (text, image, varchar(max), xml, etc.) or when LOB values are stored. Each allocation unit has its own IAM chain tracking its pages.

### Q9: What is a PFS page and why is it a contention point?

**A:** A PFS (Page Free Space) page uses one byte per data page to track allocation status and approximate free space. In high-concurrency INSERT workloads (especially in tempdb), PFS page contention occurs because many sessions try to update the same PFS page simultaneously to find free space. SQL Server 2019 introduced **PFS page concurrency enhancements** and the ability to have multiple tempdb data files to spread contention across multiple PFS pages.

### Q10: How do you identify and fix index fragmentation?

**A:**
```sql
-- Identify
SELECT * FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED')
WHERE avg_fragmentation_in_percent > 10 AND page_count > 1000;

-- Fix: Reorganize (online, lightweight, for 10-30% fragmentation)
ALTER INDEX IX_MyIndex ON dbo.MyTable REORGANIZE;

-- Fix: Rebuild (heavier, for >30% fragmentation)
ALTER INDEX IX_MyIndex ON dbo.MyTable REBUILD WITH (ONLINE = ON);
```

---

## Tips for the Interview

1. **Know your numbers:** 8 KB pages, 8,060-byte max row size, 96-byte header, 8 pages per extent (64 KB). These come up constantly.

2. **Understand the heap vs. clustered trade-off deeply.** Be prepared to justify when each is appropriate. Most interviewers expect you to favor clustered indexes and articulate why.

3. **Page splits are a favorite topic.** Know the difference between "good" end-of-index splits and "bad" mid-page splits. Be ready to explain mitigation strategies beyond just fill factor.

4. **DBCC PAGE is a power-user tool.** Even if you've never used it in production, knowing it exists and how to use it signals deep SQL Server knowledge. Practice reading page header output.

5. **Connect storage to performance.** Interviewers love when you link physical storage concepts to query performance: "Row-overflow data requires additional I/O, so if you frequently SELECT that column, consider normalizing it to a separate table or reviewing the data model."

6. **Filegroups matter for enterprise discussions.** Be ready to discuss piecemeal restore, partial database availability, and how to use filegroups with partitioning for a large-scale data warehouse.

7. **Mention the version-specific improvements** you know: TF 1118 behavior becoming default in SQL Server 2016 for tempdb, PFS concurrency improvements in 2019, etc. This shows you keep current.

8. **Practice querying sys.dm_db_index_physical_stats** and interpreting its output. Be able to explain what `avg_fragmentation_in_percent` and `avg_page_space_used_in_percent` mean and how they relate to page splits and fill factor.