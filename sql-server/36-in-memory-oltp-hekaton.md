# In-Memory OLTP (Hekaton)

[Back to SQL Server Index](./README.md)

---

## Overview

In-Memory OLTP (code-named **Hekaton**) is a memory-optimized database engine integrated into SQL Server since SQL Server 2014. It is designed for high-throughput, low-latency OLTP workloads by keeping data entirely in memory and using lock-free, latch-free data structures. Memory-optimized tables eliminate the traditional buffer pool model and page-based storage, replacing them with row-versioned, pointer-based structures that reside entirely in RAM.

---

## Key Concepts

### In-Memory OLTP Architecture

The traditional SQL Server storage engine uses:
- Pages and extents in buffer pool
- Lock manager for concurrency
- Latches for internal data structure protection
- Write-ahead logging (WAL) to the transaction log

In-Memory OLTP replaces all of this with:
- **Row-based in-memory storage** — no pages, no buffer pool
- **Optimistic multi-version concurrency control (MVCC)** — no locks, no latches
- **Natively compiled stored procedures** — T-SQL compiled to machine code via C/DLL
- **Checkpoint file pairs** — for durability and recovery (not traditional data files)

The result is dramatically reduced contention and higher throughput for suitable workloads — often **5x to 30x** improvement for latch-heavy OLTP patterns.

### Memory-Optimized Tables

Memory-optimized tables live entirely in memory. They are created with the `MEMORY_OPTIMIZED = ON` option.

```sql
-- First, add a memory-optimized filegroup to the database
ALTER DATABASE SalesDB
ADD FILEGROUP SalesDB_InMem CONTAINS MEMORY_OPTIMIZED_DATA;

ALTER DATABASE SalesDB
ADD FILE (
    NAME = 'SalesDB_InMem_File',
    FILENAME = 'D:\Data\SalesDB_InMem'
) TO FILEGROUP SalesDB_InMem;

-- Create a memory-optimized table
CREATE TABLE dbo.ShoppingCart (
    CartID       INT IDENTITY(1,1) NOT NULL,
    SessionID    UNIQUEIDENTIFIER NOT NULL,
    ProductID    INT NOT NULL,
    Quantity     INT NOT NULL,
    AddedDate    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT PK_ShoppingCart PRIMARY KEY NONCLUSTERED HASH (CartID)
        WITH (BUCKET_COUNT = 1048576),

    INDEX IX_SessionID NONCLUSTERED HASH (SessionID)
        WITH (BUCKET_COUNT = 262144),

    INDEX IX_AddedDate NONCLUSTERED (AddedDate)
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);
```

**Key characteristics of memory-optimized tables:**

- All rows are always in memory — no buffer pool eviction.
- Rows are versioned — each update creates a new row version, and old versions are cleaned up by garbage collection.
- No page structures — rows are connected through index pointers.
- Indexes exist only in memory and are rebuilt on server restart.
- Cannot be altered after creation in older versions (SQL Server 2014). SQL Server 2016+ supports `ALTER TABLE` for memory-optimized tables.

### Durability Options

| Option | Behavior | Use Case |
|--------|----------|----------|
| **SCHEMA_AND_DATA** | Full durability. Data survives server restart. Transactions are logged. | Production OLTP data that must not be lost |
| **SCHEMA_ONLY** | Only the table schema is durable. All data is lost on restart. No transaction logging for this table. | Staging tables, session state, tempdb replacement, ETL scratch tables |

```sql
-- Fully durable table
CREATE TABLE dbo.Orders (
    OrderID INT NOT NULL PRIMARY KEY NONCLUSTERED HASH
        WITH (BUCKET_COUNT = 1048576),
    OrderDate DATETIME2 NOT NULL,
    Amount DECIMAL(18,2) NOT NULL
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);

-- Schema-only table (data lost on restart, but extremely fast)
CREATE TABLE dbo.SessionState (
    SessionKey NVARCHAR(128) NOT NULL PRIMARY KEY NONCLUSTERED HASH
        WITH (BUCKET_COUNT = 65536),
    SessionValue NVARCHAR(MAX) NOT NULL,
    ExpiresAt DATETIME2 NOT NULL
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY);
```

**SCHEMA_ONLY tables are essentially a high-performance replacement for temp tables** — they have zero logging overhead and are ideal for volatile data.

### Hash Indexes vs. Nonclustered Indexes for Memory-Optimized Tables

Memory-optimized tables support two index types, both of which are fundamentally different from traditional disk-based indexes.

#### Hash Indexes

Hash indexes use a hash table structure and are optimized for **point lookups** (equality predicates).

```sql
INDEX IX_CustomerID NONCLUSTERED HASH (CustomerID)
    WITH (BUCKET_COUNT = 1048576)
```

**Hash index characteristics:**

- O(1) lookup time for equality predicates.
- **BUCKET_COUNT** must be configured — ideally **1x to 2x the expected number of distinct values**.
- Too few buckets = long hash chains = poor performance.
- Too many buckets = wasted memory.
- **Not effective for range scans**, inequality predicates (`>`, `<`, `BETWEEN`), or `ORDER BY`.
- **Not effective for partial key lookups** — all columns in the hash index must be specified in the WHERE clause.

```sql
-- Hash index is effective for:
SELECT * FROM dbo.ShoppingCart WHERE CartID = 12345;

-- Hash index is NOT effective for:
SELECT * FROM dbo.ShoppingCart WHERE CartID > 1000 AND CartID < 2000;
SELECT * FROM dbo.ShoppingCart WHERE AddedDate > '2025-01-01';
```

#### Nonclustered (BW-Tree) Indexes

Memory-optimized nonclustered indexes use a **Bw-tree** (latch-free B-tree variant) and support both equality and range operations.

```sql
INDEX IX_AddedDate NONCLUSTERED (AddedDate)
```

**Nonclustered index characteristics:**

- Supports equality, range scans, inequality, and ORDER BY.
- No BUCKET_COUNT configuration needed.
- More versatile than hash indexes.
- Slightly slower than hash indexes for pure point lookups.
- Better for columns with unknown or highly variable cardinality.

#### Choosing Between Them

| Criterion | Hash Index | Nonclustered Index |
|-----------|------------|-------------------|
| Point lookups (=) | Excellent | Good |
| Range scans (>, <, BETWEEN) | Poor | Excellent |
| ORDER BY | Not supported | Supported |
| Partial key match | Not supported (all key columns needed) | Supported (leftmost prefix) |
| Memory | Fixed (based on BUCKET_COUNT) | Dynamic (grows with data) |
| Best for | Primary key lookups, known cardinality | General purpose, range queries |

**General recommendation:** Use nonclustered indexes unless you have a clear point-lookup-only pattern with known cardinality. Nonclustered indexes are safer and more flexible.

### Natively Compiled Stored Procedures

Natively compiled stored procedures are T-SQL procedures compiled directly to machine code (DLL) at creation time. They bypass the SQL Server query interpreter entirely.

```sql
CREATE PROCEDURE dbo.usp_AddToCart
    @SessionID UNIQUEIDENTIFIER,
    @ProductID INT,
    @Quantity INT
WITH NATIVE_COMPILATION, SCHEMABINDING
AS
BEGIN ATOMIC WITH (
    TRANSACTION ISOLATION LEVEL = SNAPSHOT,
    LANGUAGE = N'English'
)
    INSERT INTO dbo.ShoppingCart (SessionID, ProductID, Quantity)
    VALUES (@SessionID, @ProductID, @Quantity);
END;
GO
```

**Key rules for natively compiled procedures:**

- Must use `NATIVE_COMPILATION` and `SCHEMABINDING`.
- Must have `BEGIN ATOMIC` block with isolation level and language specified.
- The `BEGIN ATOMIC` block wraps the entire procedure in a single transaction.
- Can only reference **memory-optimized tables** (not disk-based tables).
- Support a **subset of T-SQL** — many constructs are not supported (see Limitations section).
- Compiled to a DLL on disk — recompiled on server restart.
- Provide the biggest performance gains — often 10x or more over interpreted T-SQL on memory-optimized tables.

### Memory-Optimized Table Types

Table-valued parameters (TVPs) can be memory-optimized, providing significant performance gains for passing sets of data to stored procedures.

```sql
-- Memory-optimized table type
CREATE TYPE dbo.OrderLineType AS TABLE (
    ProductID INT NOT NULL,
    Quantity INT NOT NULL,
    UnitPrice DECIMAL(18,2) NOT NULL,

    INDEX IX_ProductID NONCLUSTERED HASH (ProductID)
        WITH (BUCKET_COUNT = 1024)
) WITH (MEMORY_OPTIMIZED = ON);
GO

-- Use in a natively compiled procedure
CREATE PROCEDURE dbo.usp_InsertOrderLines
    @OrderID INT,
    @Lines dbo.OrderLineType READONLY
WITH NATIVE_COMPILATION, SCHEMABINDING
AS
BEGIN ATOMIC WITH (
    TRANSACTION ISOLATION LEVEL = SNAPSHOT,
    LANGUAGE = N'English'
)
    INSERT INTO dbo.OrderLines (OrderID, ProductID, Quantity, UnitPrice)
    SELECT @OrderID, ProductID, Quantity, UnitPrice
    FROM @Lines;
END;
GO
```

**Memory-optimized table types are also valuable for replacing temp tables** in interpreted T-SQL, as they avoid tempdb contention entirely.

### Garbage Collection

Since In-Memory OLTP uses row versioning (MVCC), old row versions accumulate and must be cleaned up. This is handled by the **garbage collector**.

- **Cooperative garbage collection:** User threads help clean up stale row versions as they traverse index chains.
- **Main garbage collection thread:** A background system thread that periodically scans for and removes stale rows that no active transaction can reference.
- Rows become eligible for garbage collection when no active transaction holds a reference to them.
- If garbage collection falls behind, memory consumption grows and performance degrades.

**Monitoring garbage collection:**

```sql
-- Check garbage collection state
SELECT
    name,
    value,
    description
FROM sys.dm_db_xtp_gc_cycle_stats;

-- Check row version lifecycle
SELECT
    object_id,
    OBJECT_NAME(object_id) AS table_name,
    rows_returned,
    rows_expired,
    rows_expired_removed
FROM sys.dm_db_xtp_index_stats;
```

### Checkpoint File Pairs

For durable memory-optimized tables (`SCHEMA_AND_DATA`), SQL Server uses **checkpoint file pairs** instead of traditional data and log files:

- **Data files** — Contain inserted rows. Rows are appended sequentially.
- **Delta files** — Contain deleted row references (row IDs that have been removed).
- Files are paired: each data file has a corresponding delta file.
- During recovery, SQL Server reads the data files and applies the delta files to reconstruct the in-memory state.
- A **merge** process periodically combines older file pairs to reclaim space and improve recovery time.

```sql
-- View checkpoint file pairs
SELECT
    checkpoint_file_id,
    file_type_desc,
    state_desc,
    lower_bound_tsn,
    upper_bound_tsn,
    file_size_in_bytes / 1024 / 1024 AS size_mb
FROM sys.dm_db_xtp_checkpoint_files
ORDER BY checkpoint_file_id;
```

---

## Migration Considerations

### Evaluating Tables for Migration

Not every table benefits from In-Memory OLTP. Ideal candidates:

1. **High-contention tables** — Frequent latch waits (PAGELATCH_EX, PAGELATCH_SH on hot pages).
2. **Tempdb-heavy workloads** — Temp tables and table variables that can become SCHEMA_ONLY memory-optimized.
3. **Simple OLTP patterns** — Short transactions with point lookups and inserts.
4. **Session state / caching tables** — Frequently read/written small tables.

**Use the Transaction Performance Analysis reports** (SSMS) or the **Memory Optimization Advisor** to identify candidates.

```sql
-- Identify hot tables with latch contention
SELECT
    OBJECT_NAME(page_info.object_id) AS table_name,
    wt.wait_type,
    wt.wait_duration_ms,
    wt.resource_description
FROM sys.dm_os_waiting_tasks wt
CROSS APPLY sys.dm_exec_requests r ON wt.session_id = r.session_id
CROSS APPLY sys.fn_PageResCracker(r.page_resource) AS page_info
WHERE wt.wait_type LIKE 'PAGELATCH%';
```

### Migration Steps

1. **Assess:** Use Memory Optimization Advisor to check table compatibility.
2. **Add filegroup:** Create a memory-optimized filegroup in the database.
3. **Modify schema:** Adjust table definitions (add required indexes, remove unsupported features).
4. **Migrate data:** Use `SELECT INTO` or BCP to populate the new memory-optimized table.
5. **Convert procedures:** Optionally convert critical stored procedures to natively compiled.
6. **Test thoroughly:** Validate correctness, measure performance, stress test.
7. **Plan memory:** Ensure the server has enough RAM (memory-optimized tables + 2x for row versions).

**Memory planning rule of thumb:** Allocate **2x the data size** for memory-optimized tables to account for row versioning, indexes, and overhead.

---

## Limitations

### Memory-Optimized Table Limitations

- **No TRUNCATE TABLE** (use DELETE without WHERE clause instead).
- **No ALTER TABLE** in SQL Server 2014 (resolved in SQL Server 2016+).
- **No FOREIGN KEY constraints** in SQL Server 2014 (supported from SQL Server 2016).
- **No CHECK constraints** in SQL Server 2014 (supported from SQL Server 2016).
- **Max 8 indexes** per table in SQL Server 2014 (raised to no hard limit in SQL Server 2016).
- **No DML triggers** in SQL Server 2014 (supported from SQL Server 2016).
- **No IDENTITY columns with non-default seed/increment** in older versions.
- **No computed columns** in SQL Server 2014 (supported from SQL Server 2017).
- **No cross-database transactions** — memory-optimized tables cannot participate in distributed transactions.
- **No parallel plans** for queries on memory-optimized tables (serial execution only).
- **No MERGE statement** targeting memory-optimized tables.
- **Row size limit:** 8,060 bytes for in-row data (LOB columns supported from SQL Server 2016).
- **Cannot be partitioned** — no table/index partitioning for memory-optimized tables.

### Natively Compiled Procedure Limitations

- Can only access memory-optimized tables and memory-optimized table types.
- No TRY/CATCH in SQL Server 2014 (supported from SQL Server 2016).
- No EXECUTE AS in SQL Server 2014.
- No CASE expressions in SQL Server 2014 (supported from SQL Server 2016).
- No subqueries in SQL Server 2014 (supported from SQL Server 2016).
- No OUTER JOIN in SQL Server 2014 (supported from SQL Server 2016).
- No OR and NOT operators in WHERE clause in SQL Server 2014.
- Limited built-in function support (expanding with each SQL Server release).
- Cannot reference disk-based tables at all.

**The surface area has improved significantly with each release.** SQL Server 2016 and later versions removed many of the original limitations. Always check the current documentation for your specific version.

---

## Use Cases

### Use Case 1: High-Throughput OLTP

An e-commerce platform processing thousands of orders per second experiences PAGELATCH contention on the OrderQueue table.

```sql
CREATE TABLE dbo.OrderQueue (
    QueueID      BIGINT IDENTITY(1,1) NOT NULL,
    OrderData    NVARCHAR(4000) NOT NULL,
    Status       TINYINT NOT NULL DEFAULT 0,
    CreatedAt    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT PK_OrderQueue PRIMARY KEY NONCLUSTERED HASH (QueueID)
        WITH (BUCKET_COUNT = 2097152),

    INDEX IX_Status_Created NONCLUSTERED (Status, CreatedAt)
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);
GO

CREATE PROCEDURE dbo.usp_EnqueueOrder
    @OrderData NVARCHAR(4000)
WITH NATIVE_COMPILATION, SCHEMABINDING
AS
BEGIN ATOMIC WITH (
    TRANSACTION ISOLATION LEVEL = SNAPSHOT,
    LANGUAGE = N'English'
)
    INSERT INTO dbo.OrderQueue (OrderData)
    VALUES (@OrderData);
END;
GO
```

### Use Case 2: Tempdb Offloading

Replace heavily used temp tables and table variables with SCHEMA_ONLY memory-optimized tables to eliminate tempdb latch contention.

```sql
-- Instead of: DECLARE @Results TABLE (ID INT, Value DECIMAL(18,2))
-- Use a memory-optimized table type:
CREATE TYPE dbo.ResultsType AS TABLE (
    ID INT NOT NULL,
    Value DECIMAL(18,2) NOT NULL,
    INDEX IX_ID NONCLUSTERED (ID)
) WITH (MEMORY_OPTIMIZED = ON);
GO

-- Usage in procedures:
DECLARE @Results dbo.ResultsType;
INSERT INTO @Results (ID, Value)
SELECT ProductID, SUM(Amount)
FROM Sales.Transactions
GROUP BY ProductID;
```

### Use Case 3: Session State Management

Web application session state stored in SQL Server — high read/write frequency, data loss on restart is acceptable.

```sql
CREATE TABLE dbo.WebSessionState (
    SessionID     NVARCHAR(128) NOT NULL,
    ItemKey       NVARCHAR(256) NOT NULL,
    ItemValue     NVARCHAR(MAX) NOT NULL,
    LastAccessed  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),

    CONSTRAINT PK_WebSession PRIMARY KEY NONCLUSTERED HASH (SessionID, ItemKey)
        WITH (BUCKET_COUNT = 524288)
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_ONLY);
GO

-- Natively compiled upsert procedure
CREATE PROCEDURE dbo.usp_SetSessionItem
    @SessionID NVARCHAR(128),
    @ItemKey NVARCHAR(256),
    @ItemValue NVARCHAR(MAX)
WITH NATIVE_COMPILATION, SCHEMABINDING
AS
BEGIN ATOMIC WITH (
    TRANSACTION ISOLATION LEVEL = SNAPSHOT,
    LANGUAGE = N'English'
)
    DELETE FROM dbo.WebSessionState
    WHERE SessionID = @SessionID AND ItemKey = @ItemKey;

    INSERT INTO dbo.WebSessionState (SessionID, ItemKey, ItemValue)
    VALUES (@SessionID, @ItemKey, @ItemValue);
END;
GO
```

---

## Monitoring Memory-Optimized Objects

### Memory Consumption

```sql
-- Overall memory usage by memory-optimized tables
SELECT
    OBJECT_NAME(object_id) AS table_name,
    memory_allocated_for_table_kb / 1024 AS table_mb,
    memory_used_by_table_kb / 1024 AS table_used_mb,
    memory_allocated_for_indexes_kb / 1024 AS index_mb,
    memory_used_by_indexes_kb / 1024 AS index_used_mb
FROM sys.dm_db_xtp_table_memory_stats
WHERE object_id > 0;

-- Memory clerk breakdown for In-Memory OLTP
SELECT
    type,
    name,
    pages_kb / 1024 AS memory_mb
FROM sys.dm_os_memory_clerks
WHERE type LIKE '%xtp%'
ORDER BY pages_kb DESC;

-- Resource pool binding (memory bound for In-Memory OLTP)
SELECT
    pool_id,
    name,
    min_memory_percent,
    max_memory_percent,
    used_memory_kb / 1024 AS used_mb,
    target_memory_kb / 1024 AS target_mb
FROM sys.dm_resource_governor_resource_pools
WHERE name = 'default';  -- or your bound pool
```

### Index Statistics

```sql
-- Hash index stats — check bucket utilization
SELECT
    OBJECT_NAME(hs.object_id) AS table_name,
    i.name AS index_name,
    hs.total_bucket_count,
    hs.empty_bucket_count,
    hs.avg_chain_length,
    hs.max_chain_length,
    CAST(hs.empty_bucket_count AS FLOAT) / hs.total_bucket_count * 100
        AS empty_bucket_pct
FROM sys.dm_db_xtp_hash_index_stats hs
JOIN sys.indexes i ON hs.object_id = i.object_id AND hs.index_id = i.index_id;

-- Good: empty_bucket_pct between 33-66%, avg_chain_length close to 1
-- Bad: empty_bucket_pct < 10% (too few buckets) or > 90% (too many buckets)
-- Bad: avg_chain_length > 10 (bucket count too low or poor hash distribution)

-- Nonclustered index stats
SELECT
    OBJECT_NAME(s.object_id) AS table_name,
    i.name AS index_name,
    s.delta_pages,
    s.internal_pages,
    s.leaf_pages,
    s.rows_returned,
    s.rows_expired,
    s.rows_expired_removed
FROM sys.dm_db_xtp_index_stats s
JOIN sys.indexes i ON s.object_id = i.object_id AND s.index_id = i.index_id;
```

### Transaction Performance

```sql
-- In-Memory OLTP transaction statistics
SELECT
    xtp_commit_count,
    xtp_rollback_count,
    xtp_write_conflict_count
FROM sys.dm_db_xtp_transactions_stats;

-- Natively compiled procedure execution stats
SELECT
    OBJECT_NAME(object_id) AS procedure_name,
    execution_count,
    total_worker_time / 1000 AS total_cpu_ms,
    total_elapsed_time / 1000 AS total_elapsed_ms,
    total_worker_time / NULLIF(execution_count, 0) / 1000 AS avg_cpu_ms
FROM sys.dm_exec_procedure_stats
WHERE database_id = DB_ID()
  AND OBJECTPROPERTY(object_id, 'ExecIsNativeCompiled') = 1;
```

### Container and Checkpoint File Health

```sql
-- Memory-optimized filegroup container usage
SELECT
    container_id,
    container_guid,
    total_bytes / 1024 / 1024 AS total_mb,
    bytes_used / 1024 / 1024 AS used_mb,
    bytes_free / 1024 / 1024 AS free_mb
FROM sys.dm_db_xtp_checkpoint_stats;

-- Checkpoint file pair details
SELECT
    file_type_desc,
    state_desc,
    COUNT(*) AS file_count,
    SUM(file_size_in_bytes) / 1024 / 1024 AS total_size_mb
FROM sys.dm_db_xtp_checkpoint_files
GROUP BY file_type_desc, state_desc
ORDER BY file_type_desc, state_desc;
```

---

## Common Interview Questions & Answers

### Q1: What is In-Memory OLTP (Hekaton) and how does it differ from the traditional storage engine?

**A:** In-Memory OLTP is a memory-optimized engine in SQL Server where tables reside entirely in RAM, accessed through lock-free, latch-free data structures using optimistic MVCC concurrency. Unlike the traditional engine which uses disk-based pages, a buffer pool, lock manager, and latch protection, In-Memory OLTP eliminates all of these bottlenecks. This makes it ideal for workloads suffering from latch contention and high-frequency short transactions, providing 5x to 30x throughput improvements.

### Q2: What is the difference between SCHEMA_AND_DATA and SCHEMA_ONLY durability?

**A:** `SCHEMA_AND_DATA` provides full ACID durability — data and schema survive a server restart, and transactions are written to the transaction log. `SCHEMA_ONLY` persists only the table definition — all data is lost on restart and no transaction logging occurs for DML on that table. SCHEMA_ONLY is used for staging data, session state, and tempdb replacement scenarios where data loss on restart is acceptable and maximum throughput is needed.

### Q3: When should you use a hash index vs. a nonclustered index on a memory-optimized table?

**A:** Use a hash index when the workload is dominated by point lookups (equality predicates) on all columns of the index key and you can accurately estimate the distinct key count for BUCKET_COUNT. Use a nonclustered (Bw-tree) index for range scans, inequality predicates, ORDER BY, or when the key cardinality is unpredictable. In practice, nonclustered indexes are the safer default choice.

### Q4: How do you determine the correct BUCKET_COUNT for a hash index?

**A:** Set BUCKET_COUNT to 1x to 2x the expected number of distinct values for the index key. Round up to the nearest power of 2 (SQL Server rounds internally). Monitor with `sys.dm_db_xtp_hash_index_stats` — `empty_bucket_pct` should be between 33-66% and `avg_chain_length` should be close to 1. Too few buckets cause long chains (degraded performance); too many waste memory.

### Q5: What are natively compiled stored procedures and why are they faster?

**A:** Natively compiled stored procedures are compiled from T-SQL into machine code (C DLL) at creation time. When executed, they run as native code without the overhead of query interpretation, operator tree evaluation, or the traditional expression evaluation framework. They are constrained to memory-optimized tables and a subset of T-SQL, but for supported operations they can be 10x or more faster than interpreted T-SQL. They must use `BEGIN ATOMIC` blocks, `SCHEMABINDING`, and specify an isolation level.

### Q6: How does garbage collection work in In-Memory OLTP?

**A:** In-Memory OLTP uses MVCC, creating new row versions on every update and delete. Old row versions become stale when no active transaction references them. Garbage collection removes these stale rows through two mechanisms: (1) cooperative GC, where user threads clean up stale rows they encounter during index traversal, and (2) a dedicated background GC thread that periodically scans for and removes expired versions. If GC falls behind, memory consumption grows and performance degrades.

### Q7: Can memory-optimized tables be accessed from regular (interpreted) T-SQL?

**A:** Yes. Memory-optimized tables can be accessed from regular T-SQL, ad-hoc queries, and non-natively-compiled stored procedures using the **interop** engine. You do not need natively compiled procedures to use memory-optimized tables. However, you get the best performance when using natively compiled procedures. The interop path still provides benefits from the lock-free/latch-free architecture but does not eliminate query interpretation overhead.

### Q8: What is the memory requirement for In-Memory OLTP?

**A:** All data and indexes for memory-optimized tables must fit in memory. As a planning guideline, allocate **2x the data size** to account for row versioning overhead, index structures, and transient row versions from concurrent transactions. You can bind a memory-optimized database to a Resource Governor resource pool to cap its memory usage and prevent it from starving other workloads.

```sql
-- Bind database to a resource pool
EXEC sys.sp_xtp_bind_db_resource_pool
    @database_name = 'SalesDB',
    @pool_name = 'PoolInMemory';

-- Take database offline/online to activate binding
ALTER DATABASE SalesDB SET OFFLINE;
ALTER DATABASE SalesDB SET ONLINE;
```

### Q9: What are checkpoint file pairs and how do they differ from traditional checkpoints?

**A:** For durable memory-optimized tables, SQL Server writes insert/delete operations to checkpoint file pairs — a data file (appended inserts) and a delta file (deleted row references). During recovery, SQL Server reads data files and applies delta files to reconstruct the in-memory state. A background merge process consolidates older file pairs to reduce recovery time and reclaim space. This is fundamentally different from traditional checkpoints, which flush dirty buffer pool pages to disk data files.

### Q10: What are the main limitations to consider before adopting In-Memory OLTP?

**A:** Key limitations include: all data must fit in memory (expensive at scale), no table partitioning, no parallel query execution plans, serial execution only, limited T-SQL surface area in natively compiled procedures (improving each release), no cross-database transactions, no MERGE statement, memory-optimized tables cannot be targets of cross-database queries, and the requirement to have a memory-optimized filegroup. Many early limitations (no ALTER TABLE, no foreign keys, limited index count) were removed in SQL Server 2016+, so the version matters significantly.

---

## Tips

- **Start with SCHEMA_ONLY tables** for tempdb offloading — this is the lowest-risk, highest-impact first step for most environments.
- **Use the Memory Optimization Advisor** in SSMS to evaluate existing tables for compatibility before migrating.
- **Monitor hash index bucket utilization** regularly with `sys.dm_db_xtp_hash_index_stats`. Poorly sized buckets are the most common performance issue.
- **Prefer nonclustered indexes over hash indexes** unless you have a confirmed point-lookup-only workload with known cardinality.
- **Plan memory capacity carefully.** If the server runs out of memory for memory-optimized objects, INSERT and UPDATE operations will fail.
- **Bind memory-optimized databases to a Resource Governor pool** to prevent unbounded memory growth from starving the buffer pool and other workloads.
- **Test write-conflict behavior.** In-Memory OLTP uses optimistic concurrency — two concurrent transactions updating the same row will result in one being rolled back. Your application must handle retry logic.
- **Use `SNAPSHOT` isolation level** for natively compiled procedures in most cases. It provides consistent reads without blocking.
- **Natively compiled procedures provide the biggest gains** but have the most restrictions. Use them for your hottest, simplest code paths and keep complex logic in interpreted T-SQL.
- **SQL Server version matters enormously** for In-Memory OLTP. The feature improved dramatically from 2014 to 2016 to 2017+. Many "limitations" you read about may only apply to older versions.
- **Recovery time increases with data size** — all memory-optimized data must be loaded into memory on startup. Plan for this in your HA/DR strategy and server restart procedures.
