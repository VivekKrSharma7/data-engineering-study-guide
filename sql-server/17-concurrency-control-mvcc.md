# Concurrency Control & MVCC (RCSI)

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [Pessimistic vs Optimistic Concurrency](#pessimistic-vs-optimistic-concurrency)
3. [Multi-Version Concurrency Control (MVCC)](#multi-version-concurrency-control-mvcc)
4. [Row Versioning and the Version Store](#row-versioning-and-the-version-store)
5. [READ COMMITTED SNAPSHOT Isolation (RCSI)](#read-committed-snapshot-isolation-rcsi)
6. [SNAPSHOT Isolation](#snapshot-isolation)
7. [RCSI vs SNAPSHOT Comparison](#rcsi-vs-snapshot-comparison)
8. [Version Chain Traversal](#version-chain-traversal)
9. [Version Cleanup](#version-cleanup)
10. [Tempdb Pressure from Versioning](#tempdb-pressure-from-versioning)
11. [Monitoring the Version Store](#monitoring-the-version-store)
12. [Migration Considerations](#migration-considerations)
13. [Performance Implications](#performance-implications)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## Introduction

Concurrency control determines how SQL Server manages simultaneous access to the same data by multiple transactions. SQL Server offers both pessimistic (lock-based) and optimistic (version-based) concurrency models. Understanding when and how to use each model is essential for building high-performance data systems.

The introduction of row versioning in SQL Server 2005 was a landmark change, enabling Multi-Version Concurrency Control (MVCC) through READ COMMITTED SNAPSHOT and SNAPSHOT isolation levels.

---

## Pessimistic vs Optimistic Concurrency

### Pessimistic Concurrency (Lock-Based)

The traditional SQL Server approach. Transactions acquire locks to prevent other transactions from making conflicting changes.

- **Readers block writers, writers block readers** (under standard READ COMMITTED with locking).
- Writers always block other writers on the same resource.
- High contention workloads suffer from blocking and reduced throughput.
- Data consistency is guaranteed by lock duration and isolation level.

```sql
-- Under default READ COMMITTED (locking):
-- Session 1
BEGIN TRAN;
UPDATE Accounts SET Balance = Balance - 100 WHERE AccountID = 1;
-- X lock held on the row until COMMIT

-- Session 2 (blocked until Session 1 commits)
SELECT Balance FROM Accounts WHERE AccountID = 1;
-- Waits for the X lock to be released
```

### Optimistic Concurrency (Version-Based)

Transactions do not block each other for reads. Instead, readers see a point-in-time snapshot of the data based on row versions.

- **Readers do not block writers, writers do not block readers.**
- Writers still block other writers (exclusive locks are always required for modifications).
- Older versions of rows are stored in the version store (in tempdb).
- Slightly higher overhead for writes (version maintenance) but significantly better read concurrency.

```sql
-- Under RCSI:
-- Session 1
BEGIN TRAN;
UPDATE Accounts SET Balance = Balance - 100 WHERE AccountID = 1;
-- X lock held, but a version of the old row is stored in tempdb

-- Session 2 (NOT blocked)
SELECT Balance FROM Accounts WHERE AccountID = 1;
-- Reads the pre-update version from the version store
-- Returns the old balance, not blocked
```

---

## Multi-Version Concurrency Control (MVCC)

MVCC is a concurrency technique where the database maintains multiple physical versions of each row. When a row is modified, the previous version is preserved so that concurrent readers can see the data as it existed at a specific point in time.

### How MVCC Works in SQL Server

1. When a row is modified (INSERT, UPDATE, DELETE), SQL Server copies the previous version of the row to the **version store** in tempdb.
2. A 14-byte versioning tag is added to each modified row in the data page, pointing to the version chain in tempdb.
3. Readers that need an older version follow the version chain to find the appropriate version based on their transaction's start time or statement start time.
4. Writers still acquire exclusive locks -- MVCC only changes how reads are handled.

### The 14-Byte Row Versioning Overhead

When RCSI or SNAPSHOT is enabled on a database, every row in the database gains a potential 14-byte overhead:
- This is added to the row when it is first modified after versioning is enabled.
- It contains a pointer to the version store and a transaction sequence number (XSN).
- Rows that have never been modified since versioning was enabled do not have this tag.
- This can cause page splits if rows are near the page size limit.

---

## Row Versioning and the Version Store

### Where Versions Are Stored

Row versions are stored in the **version store**, a dedicated area within **tempdb**. This is not a table or file you can directly query -- it is managed internally by the SQL Server engine.

### Version Store Structure

- The version store uses tempdb allocation units.
- Each version record contains: the database ID, the row's original data, and a transaction sequence number.
- Versions are linked in a chain: the current row points to its most recent version, which points to the next older version, and so on.

### Lifecycle of a Row Version

1. Transaction T1 begins and modifies a row.
2. The old row data is copied to the version store in tempdb.
3. The modified row in the data page gets a 14-byte pointer to the version store entry.
4. If Transaction T2 needs to read the row, it follows the pointer to find the version that was current when T2's statement (or transaction) started.
5. When no active transaction needs the version, the background cleanup process removes it.

---

## READ COMMITTED SNAPSHOT Isolation (RCSI)

RCSI changes the behavior of the default READ COMMITTED isolation level from lock-based to version-based. It is a **database-level** setting.

### Enabling RCSI

```sql
-- Requires exclusive database access (single-user mode not needed, but
-- no active connections should exist for the ALTER to proceed)
ALTER DATABASE YourDatabase
SET READ_COMMITTED_SNAPSHOT ON;
```

To check if RCSI is enabled:

```sql
SELECT name, is_read_committed_snapshot_on
FROM sys.databases
WHERE name = 'YourDatabase';
```

### How RCSI Behaves

- Every SELECT statement under READ COMMITTED sees a **statement-level snapshot** -- the data as it existed at the moment the statement began executing.
- No shared locks are acquired for reads.
- Writers still acquire exclusive locks (write-write conflicts still result in blocking).
- The isolation level name is still READ COMMITTED; the behavior changes transparently.

```sql
-- With RCSI enabled, this is automatic for all READ COMMITTED transactions

-- Session 1
BEGIN TRAN;
UPDATE Products SET Price = 29.99 WHERE ProductID = 1;
-- Row version created in tempdb

-- Session 2
BEGIN TRAN;
SELECT Price FROM Products WHERE ProductID = 1;
-- Returns the OLD price (before Session 1's update)
-- No blocking occurs

-- Session 1
COMMIT;

-- Session 2 (new statement in the same transaction)
SELECT Price FROM Products WHERE ProductID = 1;
-- NOW returns 29.99 (Session 1 committed, and RCSI uses statement-level snapshots)
```

### Key Characteristic: Statement-Level Consistency

Each individual statement sees a consistent snapshot as of its start time. Different statements within the same transaction may see different data if other transactions commit between them. This is different from SNAPSHOT isolation, which provides transaction-level consistency.

---

## SNAPSHOT Isolation

SNAPSHOT isolation provides **transaction-level consistency**. All reads within the transaction see data as it existed at the moment the transaction began, regardless of subsequent commits by other transactions.

### Enabling SNAPSHOT Isolation

```sql
-- Enable SNAPSHOT isolation (this is separate from RCSI)
ALTER DATABASE YourDatabase
SET ALLOW_SNAPSHOT_ISOLATION ON;
```

### Using SNAPSHOT Isolation

Unlike RCSI, SNAPSHOT isolation must be explicitly requested per transaction.

```sql
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;

BEGIN TRAN;
SELECT Price FROM Products WHERE ProductID = 1;
-- Returns the price as of the transaction start time

-- Even if another session commits a price change here...

SELECT Price FROM Products WHERE ProductID = 1;
-- Still returns the SAME price as the first SELECT
-- Transaction-level consistency is maintained

COMMIT;
```

### Update Conflicts Under SNAPSHOT

SNAPSHOT isolation detects write-write conflicts. If a transaction running under SNAPSHOT attempts to modify a row that has been changed by another transaction since the SNAPSHOT transaction began, SQL Server raises an error.

```sql
-- Session 1 (SNAPSHOT)
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRAN;
SELECT Quantity FROM Inventory WHERE ProductID = 1; -- Returns 50

-- Session 2 (any isolation level)
UPDATE Inventory SET Quantity = 45 WHERE ProductID = 1;
COMMIT;

-- Session 1 attempts to update the same row
UPDATE Inventory SET Quantity = 48 WHERE ProductID = 1;
-- ERROR 3960: Snapshot isolation transaction aborted due to update conflict.
-- The transaction must be rolled back and retried.
```

This is the "first writer wins" strategy. Applications using SNAPSHOT isolation must handle error 3960 with retry logic.

---

## RCSI vs SNAPSHOT Comparison

| Feature                          | RCSI                                  | SNAPSHOT                              |
|----------------------------------|---------------------------------------|---------------------------------------|
| **Consistency level**            | Statement-level                       | Transaction-level                     |
| **Enabled at**                   | Database level (transparent)          | Database level + per-transaction      |
| **Application changes needed**   | None (drop-in replacement)            | Yes (SET ISOLATION LEVEL SNAPSHOT)    |
| **Shared locks for reads**       | No                                    | No                                    |
| **Write-write blocking**         | Yes (same as locking)                 | Yes (plus update conflict detection)  |
| **Update conflict errors**       | No                                    | Yes (error 3960)                      |
| **Phantom protection**           | No                                    | Yes                                   |
| **Version store usage**          | Typically less (shorter retention)    | Potentially more (longer retention)   |
| **Best for**                     | General OLTP, replacing locking READ COMMITTED | Reporting requiring transaction-level consistency |

### When to Use Which

- **RCSI** is the most common choice. It is transparent to applications, eliminates reader-writer blocking, and has been adopted by most modern SQL Server deployments (including Azure SQL Database, where it is on by default).
- **SNAPSHOT** is used when you need transaction-level read consistency, such as complex reporting transactions that must see a stable view of data across multiple queries.

---

## Version Chain Traversal

When a reader needs to find the correct version of a row, it traverses the version chain.

### How Traversal Works

1. The reader checks the current row in the data page.
2. If the row's XSN (transaction sequence number) is newer than the reader's snapshot point, it follows the 14-byte pointer to the version store.
3. In the version store, it checks the next version. If this version is still too new, it continues to the next link in the chain.
4. This continues until it finds a version with an XSN that is older than or equal to the reader's snapshot point.

### Performance Implications

- Short version chains are fast (one or two hops).
- Long version chains occur when rows are updated frequently and long-running transactions prevent version cleanup.
- Long chains cause performance degradation for reads because each hop requires an I/O operation against tempdb.

```sql
-- Check for long version chains
SELECT
    DB_NAME(database_id) AS database_name,
    SUM(record_length_first_part_in_bytes + record_length_second_part_in_bytes) AS version_store_bytes
FROM sys.dm_tran_version_store
GROUP BY database_id;
```

---

## Version Cleanup

### Background Cleanup Thread

SQL Server runs a background thread every minute that cleans up version store records that are no longer needed by any active transaction.

### What Prevents Cleanup?

A version record is retained as long as any active transaction might need it. The most common causes of version store bloat:

1. **Long-running transactions**: A transaction that started 2 hours ago prevents cleanup of all versions created since that time.
2. **Long-running queries**: Even a single SELECT that runs for a long time keeps its snapshot point alive.
3. **Orphaned transactions**: An open, uncommitted transaction in an idle session.
4. **Replication or Change Data Capture (CDC)**: The log reader agent may require old versions.

### Monitoring the Oldest Active Transaction

```sql
-- Find the oldest active transaction affecting version cleanup
SELECT
    transaction_id,
    transaction_sequence_num,
    elapsed_time_seconds
FROM sys.dm_tran_active_snapshot_database_transactions
ORDER BY elapsed_time_seconds DESC;
```

---

## Tempdb Pressure from Versioning

### Why Tempdb Is Critical

Since the version store resides in tempdb, enabling RCSI or SNAPSHOT isolation increases tempdb usage. If tempdb runs out of space, write operations can fail because new versions cannot be created.

### Sizing Tempdb for Version Store

There is no exact formula, but guidelines include:

- Monitor the `Version Store Size (KB)` performance counter over time during typical workload.
- Start with tempdb sized at 10-20% of your largest database and adjust based on monitoring.
- Ensure tempdb is on fast storage (SSD/NVMe preferred).
- Configure multiple tempdb data files (one per logical CPU core, up to 8, then add in groups of 4 if contention persists).

### Tempdb Contention and Version Store

```sql
-- Check version store size
SELECT
    SUM(version_store_reserved_page_count) * 8 / 1024 AS version_store_mb
FROM sys.dm_db_file_space_usage;

-- Check tempdb space usage breakdown
SELECT
    SUM(user_object_reserved_page_count) * 8 / 1024 AS user_objects_mb,
    SUM(internal_object_reserved_page_count) * 8 / 1024 AS internal_objects_mb,
    SUM(version_store_reserved_page_count) * 8 / 1024 AS version_store_mb,
    SUM(unallocated_extent_page_count) * 8 / 1024 AS free_space_mb
FROM sys.dm_db_file_space_usage;
```

### Accelerated Database Recovery (ADR) -- SQL Server 2019+

Starting with SQL Server 2019, you can enable **Accelerated Database Recovery** which moves the version store from tempdb to a **Persistent Version Store (PVS)** within the user database itself. This reduces tempdb pressure for RCSI/SNAPSHOT workloads.

```sql
ALTER DATABASE YourDatabase SET ACCELERATED_DATABASE_RECOVERY = ON;
```

---

## Monitoring the Version Store

### Key DMVs

#### sys.dm_tran_version_store

Shows individual version records (can be very large; use with caution in production).

```sql
SELECT TOP 100
    database_id,
    transaction_sequence_num,
    version_sequence_num,
    record_length_first_part_in_bytes,
    record_length_second_part_in_bytes
FROM sys.dm_tran_version_store
ORDER BY transaction_sequence_num DESC;
```

#### sys.dm_tran_version_store_space_usage (SQL Server 2017+)

A lightweight alternative that shows per-database version store space consumption without enumerating individual records.

```sql
SELECT
    DB_NAME(database_id) AS database_name,
    reserved_page_count,
    reserved_space_kb
FROM sys.dm_tran_version_store_space_usage
ORDER BY reserved_space_kb DESC;
```

#### sys.dm_tran_active_snapshot_database_transactions

Shows transactions that are using row versioning.

```sql
SELECT
    session_id,
    transaction_id,
    transaction_sequence_num,
    first_snapshot_sequence_num,
    elapsed_time_seconds,
    commit_sequence_num
FROM sys.dm_tran_active_snapshot_database_transactions
ORDER BY elapsed_time_seconds DESC;
```

### Performance Monitor Counters

| Counter                                          | Description                                        |
|--------------------------------------------------|----------------------------------------------------|
| SQLServer:Transactions\Version Store Size (KB)   | Current size of the version store                  |
| SQLServer:Transactions\Version Generation Rate   | Rate at which new versions are created (KB/s)      |
| SQLServer:Transactions\Version Cleanup Rate      | Rate at which old versions are cleaned up (KB/s)   |
| SQLServer:Transactions\Longest Transaction Running Time | Longest running snapshot transaction (seconds) |
| SQLServer:Transactions\Update Conflict Ratio     | Ratio of update conflicts (SNAPSHOT isolation)     |

---

## Migration Considerations

### Enabling RCSI on an Existing Production Database

1. **Test thoroughly in a non-production environment first.** While RCSI is largely transparent, subtle behavioral changes can affect application logic.

2. **The ALTER DATABASE command acquires a database-level exclusive lock.** It waits for all active transactions to complete. Plan this during a maintenance window or low-activity period.

```sql
-- Check for active transactions before enabling
SELECT * FROM sys.dm_tran_active_transactions;

-- Enable RCSI
ALTER DATABASE YourDatabase SET READ_COMMITTED_SNAPSHOT ON;
```

3. **14-byte row overhead.** After enabling, rows gain a 14-byte versioning tag when first modified. This can cause:
   - Page splits on near-full pages.
   - Increased I/O during the initial period after enabling.
   - Slightly larger table sizes over time.

4. **Tempdb sizing.** Ensure tempdb has adequate space and is properly configured before enabling.

5. **Behavioral changes to watch for:**

   - **Trigger behavior**: After-triggers under RCSI see the "before" image of updated rows (consistent with the statement snapshot), which may differ from lock-based READ COMMITTED.
   - **Blocking assumptions**: Code that relied on blocking for synchronization (e.g., "poor man's queue" patterns using SELECT with locking) may break.
   - **AFTER triggers reading the base table**: May see the old version of the row, not the just-modified version.

```sql
-- Example: Pattern that breaks under RCSI
-- "Poor man's queue" using blocking for synchronization
BEGIN TRAN;
SELECT TOP 1 @TaskID = TaskID
FROM TaskQueue WITH (UPDLOCK, READPAST)
WHERE Status = 'Pending'
ORDER BY Priority;
-- Under locking READ COMMITTED, this works for queue processing.
-- Under RCSI, the UPDLOCK hint still works, but test thoroughly.
COMMIT;
```

6. **Azure SQL Database**: RCSI is enabled by default and cannot be turned off. If you are migrating to Azure SQL, your application should already be RCSI-compatible.

---

## Performance Implications

### Benefits

- **Dramatically reduced blocking**: Readers never block writers and vice versa.
- **Improved throughput**: High-concurrency OLTP workloads see significant performance gains.
- **Fewer deadlocks**: Reader-writer deadlocks are eliminated entirely.
- **More predictable query response times**: No more unpredictable waits on locks.

### Costs

- **Increased tempdb I/O**: The version store adds read/write load to tempdb.
- **14-byte per-row overhead**: Increases storage slightly and can cause page splits.
- **Version chain traversal overhead**: Long chains degrade read performance.
- **Write overhead**: Each modification must write a version record to tempdb.
- **More CPU usage**: Maintaining and traversing versions requires additional CPU cycles.

### Real-World Performance Profile

In most OLTP workloads, the benefits far outweigh the costs. A typical before/after comparison:

| Metric                     | Before RCSI        | After RCSI          |
|----------------------------|--------------------|--------------------|
| Average query wait time    | 250ms              | 15ms               |
| Lock waits per second      | 1,200              | 50                 |
| Deadlocks per hour         | 15                 | 2                  |
| Tempdb usage               | 2 GB               | 5 GB               |
| Transaction throughput     | 800 TPS            | 1,400 TPS          |

The numbers vary by workload, but the pattern is consistent: significant reductions in blocking and deadlocks, moderate increase in tempdb usage.

---

## Common Interview Questions

### Q1: Explain the difference between pessimistic and optimistic concurrency control.

**Pessimistic concurrency** assumes conflicts are likely and prevents them by acquiring locks before accessing data. Readers acquire shared locks, blocking writers; writers acquire exclusive locks, blocking readers and other writers. **Optimistic concurrency** assumes conflicts are rare and allows concurrent access using row versioning. Readers see a snapshot of the data without acquiring locks, so they never block writers and vice versa. Writers still acquire exclusive locks, so write-write conflicts still result in blocking.

### Q2: What is the version store and where does it reside?

The version store is an area within **tempdb** (or within the user database if Accelerated Database Recovery is enabled) where SQL Server stores previous versions of rows that have been modified. When RCSI or SNAPSHOT isolation is enabled and a row is updated, the old version is copied to the version store. Readers that need to see older data follow a pointer chain from the current row to the appropriate version in the store. Versions are cleaned up by a background thread once no active transaction needs them.

### Q3: What is the difference between RCSI and SNAPSHOT isolation?

**RCSI** provides **statement-level** consistency -- each statement sees a snapshot as of the moment it begins executing. Different statements within the same transaction may see different data if other transactions commit between them. RCSI is a database-level setting that transparently changes READ COMMITTED behavior; no application code changes are needed.

**SNAPSHOT** provides **transaction-level** consistency -- all reads within the transaction see data as of the transaction start time. SNAPSHOT must be explicitly set per transaction (`SET TRANSACTION ISOLATION LEVEL SNAPSHOT`). SNAPSHOT also detects update conflicts (error 3960), while RCSI does not.

### Q4: How does enabling RCSI affect tempdb?

Enabling RCSI causes the version store to be maintained in tempdb. Every row modification generates a version record in tempdb, increasing I/O and space usage. Long-running transactions prevent version cleanup, causing the version store to grow. You must ensure tempdb is adequately sized (monitor with `sys.dm_db_file_space_usage`), placed on fast storage, and configured with multiple data files to handle the additional load. SQL Server 2019's Accelerated Database Recovery can move the version store to the user database to reduce tempdb pressure.

### Q5: What happens if tempdb fills up due to the version store?

If tempdb runs out of space, SQL Server cannot create new version records. Write operations will fail with errors. Existing transactions may also be affected. To mitigate: ensure tempdb auto-growth is configured, monitor version store size, identify and terminate long-running transactions that prevent cleanup, and right-size tempdb for your workload. In extreme cases, you may need to add more tempdb data files or storage.

### Q6: Explain the 14-byte row versioning overhead.

When RCSI or SNAPSHOT is enabled, SQL Server adds a 14-byte versioning tag to each row when it is first modified. This tag contains a pointer to the version store and a transaction sequence number (XSN). The overhead is added lazily -- only when a row is actually updated, not to all rows immediately. This can cause page splits on pages that were nearly full, temporarily increasing I/O. Over time, as rows are updated, the additional space is accounted for in page allocation.

### Q7: A user reports slow reads after enabling RCSI. What could be the cause?

The most likely cause is **long version chains**. If rows are frequently updated and there are long-running transactions preventing version cleanup, readers must traverse many version chain links to find the appropriate version. Each link traversal involves a tempdb read. Check for long-running snapshot transactions using `sys.dm_tran_active_snapshot_database_transactions`, examine the version store size, and investigate tempdb I/O performance. Other causes include tempdb contention (insufficient data files) or inadequate tempdb storage performance.

### Q8: Can you have both RCSI and SNAPSHOT isolation enabled on the same database?

Yes. They are controlled by two separate database options: `READ_COMMITTED_SNAPSHOT ON` for RCSI and `ALLOW_SNAPSHOT_ISOLATION ON` for SNAPSHOT. Both can be enabled simultaneously. RCSI affects all READ COMMITTED transactions transparently, while SNAPSHOT must be explicitly requested per transaction. Both use the same version store infrastructure in tempdb.

---

## Tips

- **RCSI should be your default for new SQL Server deployments.** Azure SQL Database has it on by default, and most modern OLTP workloads benefit significantly from it. The question should not be "why enable RCSI?" but rather "is there a specific reason NOT to?"

- **Monitor tempdb continuously after enabling RCSI.** Set up alerts on version store size, tempdb free space, and tempdb I/O latency. The biggest risk is an unexpected long-running transaction causing version store bloat.

- **Long-running transactions are the enemy of MVCC.** A transaction that stays open for hours prevents version cleanup for the entire duration. Implement alerts for transactions older than a threshold (e.g., 30 minutes) and investigate promptly.

- **Use `sys.dm_tran_version_store_space_usage` (2017+) instead of `sys.dm_tran_version_store`** for monitoring. The latter enumerates every version record and can be extremely slow on busy systems.

- **SNAPSHOT isolation requires application awareness.** Unlike RCSI, applications must handle update conflict errors (3960). Do not enable SNAPSHOT isolation without ensuring the application has retry logic for these conflicts.

- **The "poor man's queue" pattern** using SELECT with UPDLOCK and READPAST still works under RCSI because the UPDLOCK hint explicitly requests a locking behavior. However, test queue-based patterns thoroughly when migrating to RCSI.

- **Consider Accelerated Database Recovery (ADR) on SQL Server 2019+** to move the version store out of tempdb and into the user database. This is especially valuable for workloads with heavy versioning or limited tempdb capacity.

- **When troubleshooting RCSI performance, check these in order**: (1) long-running transactions, (2) tempdb space and I/O, (3) version chain length, (4) tempdb file count and contention.
