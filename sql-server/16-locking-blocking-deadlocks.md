# Locking, Blocking & Deadlocks

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [Lock Modes](#lock-modes)
3. [Lock Granularity](#lock-granularity)
4. [Lock Escalation](#lock-escalation)
5. [Lock Compatibility Matrix](#lock-compatibility-matrix)
6. [Blocking](#blocking)
7. [Identifying Blocking Chains](#identifying-blocking-chains)
8. [Deadlocks](#deadlocks)
9. [Deadlock Detection and Analysis](#deadlock-detection-and-analysis)
10. [Minimizing Deadlocks](#minimizing-deadlocks)
11. [NOLOCK vs Proper Isolation](#nolock-vs-proper-isolation)
12. [Lock Timeout Settings](#lock-timeout-settings)
13. [Common Interview Questions](#common-interview-questions)
14. [Tips](#tips)

---

## Introduction

SQL Server uses a lock-based concurrency control mechanism to ensure data integrity when multiple transactions access the same data simultaneously. Understanding locking behavior is critical for diagnosing performance problems, resolving blocking issues, and preventing deadlocks in production environments.

Every time a transaction reads or modifies data, SQL Server acquires locks to protect that data. The type and duration of locks depend on the isolation level, the operation being performed, and the query plan chosen by the optimizer.

---

## Lock Modes

SQL Server supports several lock modes, each serving a different purpose.

### Shared Locks (S)

- Acquired when reading data (SELECT statements).
- Multiple transactions can hold shared locks on the same resource simultaneously.
- Under READ COMMITTED (the default), shared locks are released as soon as the data is read. Under REPEATABLE READ or SERIALIZABLE, they are held until the transaction ends.

### Exclusive Locks (X)

- Acquired when modifying data (INSERT, UPDATE, DELETE).
- Only one transaction can hold an exclusive lock on a resource at a time.
- Incompatible with all other lock types -- no other transaction can read (under locking isolation) or write the same resource.
- Held until the end of the transaction.

### Update Locks (U)

- A transitional lock used during UPDATE operations.
- Prevents a common deadlock scenario: two transactions both acquire shared locks, then both try to convert to exclusive locks.
- Only one transaction can hold an update lock on a resource at a time.
- Compatible with shared locks but not with other update or exclusive locks.
- When the actual modification occurs, the update lock is converted to an exclusive lock.

```sql
-- Update locks are acquired during the read phase of an UPDATE
UPDATE Orders
SET Status = 'Shipped'
WHERE OrderID = 1001;
-- Phase 1: U lock acquired on the row to find OrderID = 1001
-- Phase 2: U lock converted to X lock for the modification
```

### Intent Locks (IS, IX, SIX)

Intent locks are placed on higher-level resources (page, table) to signal that a transaction holds or intends to acquire locks at a lower level.

- **Intent Shared (IS)**: Indicates a transaction intends to acquire shared locks on rows within the page or table.
- **Intent Exclusive (IX)**: Indicates a transaction intends to acquire exclusive locks on rows within the page or table.
- **Shared with Intent Exclusive (SIX)**: The transaction holds a shared lock on the entire resource AND intends to acquire exclusive locks on some lower-level resources. Only one SIX lock is allowed at a time.

Intent locks improve performance by allowing SQL Server to check lock compatibility at the table or page level without scanning every row-level lock.

### Schema Locks (Sch-S, Sch-M)

- **Schema Stability (Sch-S)**: Acquired during query compilation and execution. Prevents schema changes (like ALTER TABLE) while a query is running. Multiple Sch-S locks can coexist.
- **Schema Modification (Sch-M)**: Acquired during DDL operations (ALTER TABLE, DROP INDEX, etc.). Blocks all other access to the table. No other lock type is compatible with Sch-M.

```sql
-- This ALTER will acquire a Sch-M lock, blocking all concurrent queries
ALTER TABLE Orders ADD ShippedDate DATETIME NULL;
```

### Bulk Update Locks (BU)

- Used during bulk import operations (BULK INSERT, bcp) when the TABLOCK hint is specified.
- Allows multiple bulk operations to load data concurrently into the same table.
- Prevents non-bulk operations from accessing the table during the load.

```sql
BULK INSERT StagingTable
FROM 'C:\Data\import.csv'
WITH (TABLOCK, FIELDTERMINATOR = ',', ROWTERMINATOR = '\n');
```

---

## Lock Granularity

SQL Server can lock resources at various levels of granularity, from fine-grained (row) to coarse-grained (database).

| Granularity | Resource        | Description                                      |
|-------------|-----------------|--------------------------------------------------|
| RID/KEY     | Row             | A single row in a heap (RID) or index (KEY)      |
| PAGE        | Page            | An 8 KB data or index page                       |
| EXTENT      | Extent          | A group of 8 contiguous pages                    |
| HoBT        | Heap or B-Tree  | An entire heap or index partition                |
| TABLE       | Table           | The entire table including all indexes            |
| DATABASE    | Database        | The entire database (used during recovery, etc.) |

### How SQL Server Chooses Granularity

- The query optimizer estimates the number of rows and pages to be accessed.
- For small operations, row-level locks are preferred (high concurrency, higher overhead).
- For large scans, page or table locks may be chosen (lower overhead, reduced concurrency).
- You can influence this with lock hints, but SQL Server ultimately manages escalation.

```sql
-- Force row-level locking
SELECT * FROM Orders WITH (ROWLOCK) WHERE CustomerID = 500;

-- Force page-level locking
SELECT * FROM Orders WITH (PAGLOCK) WHERE Region = 'West';

-- Force table-level locking
SELECT * FROM Orders WITH (TABLOCK) WHERE OrderDate > '2025-01-01';
```

---

## Lock Escalation

Lock escalation is the process by which SQL Server converts many fine-grained locks (row or page) into a single coarse-grained lock (table) to conserve memory.

### When Does It Happen?

- When a single transaction acquires approximately **5,000 locks** on a single table.
- When the total number of locks held by the SQL Server instance exceeds a memory threshold (based on the lock memory configuration).

### Lock Escalation Behavior

SQL Server attempts to escalate to a table lock. If a conflicting lock exists at the table level, escalation fails and SQL Server retries after acquiring another 1,250 locks.

### Controlling Lock Escalation

```sql
-- Disable lock escalation on a specific table
ALTER TABLE Orders SET (LOCK_ESCALATION = DISABLE);

-- Allow escalation to partition level (for partitioned tables)
ALTER TABLE Orders SET (LOCK_ESCALATION = AUTO);

-- Default behavior: escalate to table level
ALTER TABLE Orders SET (LOCK_ESCALATION = TABLE);
```

### Real-World Scenario

A nightly batch job updates 100,000 rows in a large table. Lock escalation kicks in after ~5,000 row locks, converting to a table lock. This blocks all other users from accessing the table. Solution: process the updates in smaller batches of 2,000-4,000 rows to stay below the escalation threshold.

```sql
DECLARE @BatchSize INT = 2000;
DECLARE @RowsAffected INT = 1;

WHILE @RowsAffected > 0
BEGIN
    UPDATE TOP (@BatchSize) Orders
    SET ProcessedFlag = 1
    WHERE ProcessedFlag = 0
      AND OrderDate < '2025-01-01';

    SET @RowsAffected = @@ROWCOUNT;
END
```

---

## Lock Compatibility Matrix

This matrix shows which lock modes are compatible with each other. "Y" means compatible (both can be held simultaneously); "N" means incompatible.

| Requested \ Held | IS  | S   | U   | IX  | SIX | X   |
|-------------------|-----|-----|-----|-----|-----|-----|
| **IS**            | Y   | Y   | Y   | Y   | Y   | N   |
| **S**             | Y   | Y   | Y   | N   | N   | N   |
| **U**             | Y   | Y   | N   | N   | N   | N   |
| **IX**            | Y   | N   | N   | Y   | N   | N   |
| **SIX**           | Y   | N   | N   | N   | N   | N   |
| **X**             | N   | N   | N   | N   | N   | N   |

Key takeaways:
- **Exclusive locks (X)** are incompatible with everything.
- **Shared locks (S)** are compatible with other shared and update locks, but not with exclusive or intent-exclusive locks.
- **Intent locks** allow coexistence at higher levels for different lower-level lock types.

---

## Blocking

Blocking occurs when one transaction holds a lock that another transaction needs. The blocked transaction must wait until the lock is released. Blocking is normal and expected; it becomes a problem when it lasts too long or cascades into long chains.

### Common Causes of Blocking

1. **Long-running transactions**: A transaction that holds locks for an extended period blocks others.
2. **Missing indexes**: A query does a full table scan, acquiring more locks than necessary.
3. **Escalation**: Lock escalation to a table lock blocks unrelated queries.
4. **Uncommitted transactions**: An open transaction in SSMS that was not committed or rolled back.
5. **Application-level issues**: Transactions held open while waiting for user input or external API calls.

---

## Identifying Blocking Chains

### sp_who2

A classic but limited approach.

```sql
EXEC sp_who2;
-- Look for rows where BlkBy is not blank -- those sessions are blocked.
-- The BlkBy column shows the SPID of the blocker.
```

### sys.dm_exec_requests

More detailed and scriptable.

```sql
SELECT
    r.session_id,
    r.blocking_session_id,
    r.wait_type,
    r.wait_time,
    r.wait_resource,
    t.text AS query_text,
    r.status,
    r.command
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id > 0
ORDER BY r.wait_time DESC;
```

### sys.dm_tran_locks

Shows all currently held and waiting locks.

```sql
SELECT
    tl.resource_type,
    tl.resource_description,
    tl.request_mode,
    tl.request_status,  -- GRANT, WAIT, CONVERT
    tl.request_session_id,
    t.text AS query_text
FROM sys.dm_tran_locks tl
LEFT JOIN sys.dm_exec_requests r
    ON tl.request_session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE tl.resource_database_id = DB_ID()
ORDER BY tl.request_session_id;
```

### Building a Blocking Chain

```sql
-- Recursive CTE to find the full blocking chain
WITH BlockingChain AS (
    SELECT
        session_id,
        blocking_session_id,
        wait_type,
        wait_time,
        0 AS level
    FROM sys.dm_exec_requests
    WHERE blocking_session_id = 0
      AND session_id IN (
          SELECT blocking_session_id
          FROM sys.dm_exec_requests
          WHERE blocking_session_id > 0
      )

    UNION ALL

    SELECT
        r.session_id,
        r.blocking_session_id,
        r.wait_type,
        r.wait_time,
        bc.level + 1
    FROM sys.dm_exec_requests r
    INNER JOIN BlockingChain bc
        ON r.blocking_session_id = bc.session_id
)
SELECT * FROM BlockingChain
ORDER BY level, session_id;
```

---

## Deadlocks

A deadlock occurs when two or more transactions form a circular dependency, each waiting for a lock held by another. SQL Server automatically detects deadlocks and terminates one transaction (the "deadlock victim") to break the cycle.

### Classic Deadlock Scenario

```
Transaction A:                          Transaction B:
BEGIN TRAN                              BEGIN TRAN
UPDATE Orders SET ... WHERE ID = 1      UPDATE Products SET ... WHERE ID = 100
-- holds X lock on Orders row           -- holds X lock on Products row
...                                     ...
UPDATE Products SET ... WHERE ID = 100  UPDATE Orders SET ... WHERE ID = 1
-- BLOCKED: needs X on Products row     -- BLOCKED: needs X on Orders row
-- DEADLOCK!
```

### Deadlock Victim Selection

SQL Server chooses the victim based on:
1. **DEADLOCK_PRIORITY**: You can set this per session (LOW, NORMAL, HIGH, or a numeric value from -10 to 10). The session with the lower priority is chosen as the victim.
2. **Cost of rollback**: If priorities are equal, the transaction with the least amount of work to roll back is chosen.

```sql
-- Make this session less likely to be chosen as deadlock victim
SET DEADLOCK_PRIORITY HIGH;

-- Make this session more likely to be the victim
SET DEADLOCK_PRIORITY LOW;

-- Numeric range: -10 (most likely victim) to 10 (least likely)
SET DEADLOCK_PRIORITY -5;
```

---

## Deadlock Detection and Analysis

### Trace Flag 1222

Writes detailed deadlock information to the SQL Server error log in XML format.

```sql
-- Enable globally (persistent until restart)
DBCC TRACEON (1222, -1);

-- Check if enabled
DBCC TRACESTATUS (1222);

-- Disable
DBCC TRACEOFF (1222, -1);
```

The output includes:
- Process information (SPID, isolation level, locks held/requested)
- The SQL statements involved
- The resource causing the deadlock

### Trace Flag 1204

An older, text-based deadlock output (less detailed than 1222).

```sql
DBCC TRACEON (1204, -1);
```

### Extended Events for Deadlocks (Recommended)

The modern and preferred approach. SQL Server has a built-in system health session that captures deadlocks by default.

```sql
-- Query deadlocks from the system_health session
SELECT
    xdr.value('@timestamp', 'DATETIME2') AS deadlock_time,
    xdr.query('.') AS deadlock_graph
FROM (
    SELECT CAST(target_data AS XML) AS target_data
    FROM sys.dm_xe_session_targets st
    INNER JOIN sys.dm_xe_sessions s
        ON s.address = st.event_session_address
    WHERE s.name = 'system_health'
      AND st.target_name = 'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS xed(xdr)
ORDER BY deadlock_time DESC;
```

### Custom Extended Events Session for Deadlocks

```sql
CREATE EVENT SESSION [DeadlockMonitor] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.event_file (
    SET filename = N'C:\Logs\Deadlocks.xel',
        max_file_size = 50,
        max_rollover_files = 10
)
WITH (
    MAX_MEMORY = 4096 KB,
    STARTUP_STATE = ON
);
GO

ALTER EVENT SESSION [DeadlockMonitor] ON SERVER STATE = START;
```

### Reading Deadlock Graphs in SSMS

1. Capture the deadlock XML from Extended Events or trace flags.
2. Save it as a `.xdl` file.
3. Open the file in SSMS -- it renders a visual deadlock graph showing the processes, resources, and the victim (marked with a blue X).

---

## Minimizing Deadlocks

### Strategy 1: Access Objects in a Consistent Order

The most effective deadlock prevention technique. If all transactions access tables in the same order (e.g., always Orders before Products), circular dependencies cannot form.

### Strategy 2: Keep Transactions Short

Minimize the time locks are held. Move any non-database logic (API calls, file I/O) outside the transaction.

```sql
-- BAD: Long transaction
BEGIN TRAN;
UPDATE Orders SET Status = 'Processing' WHERE OrderID = @id;
-- ... application logic, API calls ...
UPDATE Inventory SET Qty = Qty - 1 WHERE ProductID = @pid;
COMMIT;

-- GOOD: Short transaction
-- Do application logic first, then:
BEGIN TRAN;
UPDATE Orders SET Status = 'Processing' WHERE OrderID = @id;
UPDATE Inventory SET Qty = Qty - 1 WHERE ProductID = @pid;
COMMIT;
```

### Strategy 3: Use Appropriate Indexes

Good indexes reduce the number of rows scanned and locked, narrowing the window for conflicts.

### Strategy 4: Use READ COMMITTED SNAPSHOT Isolation (RCSI)

Readers do not acquire shared locks under RCSI, eliminating reader-writer deadlocks entirely. See the [Concurrency Control & MVCC](./17-concurrency-control-mvcc.md) topic.

### Strategy 5: Use UPDLOCK Hint Where Appropriate

In scenarios where you read-then-update, using UPDLOCK prevents the classic S-to-X conversion deadlock.

```sql
BEGIN TRAN;
SELECT @CurrentQty = Quantity
FROM Inventory WITH (UPDLOCK, ROWLOCK)
WHERE ProductID = @pid;

-- Now convert the U lock to X for the update
UPDATE Inventory
SET Quantity = @CurrentQty - 1
WHERE ProductID = @pid;
COMMIT;
```

### Strategy 6: Retry Logic in the Application

Deadlocks cannot be eliminated entirely. Applications should include retry logic.

```sql
-- Pseudocode pattern
DECLARE @retries INT = 3;
WHILE @retries > 0
BEGIN
    BEGIN TRY
        BEGIN TRAN;
        -- ... operations ...
        COMMIT;
        SET @retries = 0; -- success
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 1205 -- Deadlock victim
        BEGIN
            ROLLBACK;
            SET @retries = @retries - 1;
            WAITFOR DELAY '00:00:00.100'; -- brief pause before retry
        END
        ELSE
        BEGIN
            ROLLBACK;
            THROW;
        END
    END CATCH
END
```

---

## NOLOCK vs Proper Isolation

### The Temptation of NOLOCK

`NOLOCK` (equivalent to `READ UNCOMMITTED`) is frequently used as a "performance fix" for blocking, but it introduces serious data quality issues.

### What NOLOCK Actually Does

- Reads data without acquiring shared locks.
- Can read uncommitted (dirty) data that may later be rolled back.
- Can read data twice or skip rows entirely during page splits or allocation order scans.
- Can encounter corrupt reads in rare scenarios involving LOB data.

```sql
-- Commonly seen, but dangerous
SELECT * FROM Orders WITH (NOLOCK) WHERE CustomerID = @cid;
```

### When NOLOCK Is (Arguably) Acceptable

- Ad hoc reporting queries where approximate results are tolerable.
- Monitoring or dashboards where exact counts are not critical.
- Never in financial, transactional, or data-integrity-sensitive operations.

### Proper Alternatives

| Approach                  | Description                                              |
|---------------------------|----------------------------------------------------------|
| READ COMMITTED SNAPSHOT   | Readers get a consistent snapshot without blocking writers |
| SNAPSHOT isolation         | Transaction-level consistency without shared locks        |
| Optimized indexes          | Reduce scan scope and lock footprint                     |
| Shorter transactions       | Release locks sooner                                     |

---

## Lock Timeout Settings

### SET LOCK_TIMEOUT

Controls how long a session waits for a lock before returning an error.

```sql
-- Wait up to 5 seconds for a lock, then error out
SET LOCK_TIMEOUT 5000;  -- milliseconds

-- Wait indefinitely (default behavior)
SET LOCK_TIMEOUT -1;

-- Do not wait at all; return immediately if lock is unavailable
SET LOCK_TIMEOUT 0;
```

When a lock timeout occurs, SQL Server raises error 1222:

```
Msg 1222, Level 16, State 51
Lock request time out period exceeded.
```

Note: A lock timeout does NOT automatically roll back the transaction. The application must handle the error and decide whether to retry or rollback.

### sp_configure: locks

You can configure the maximum number of locks available to the SQL Server instance.

```sql
-- View current setting (0 = dynamic, SQL Server manages automatically)
EXEC sp_configure 'locks';

-- Typically left at 0 (dynamic) in modern SQL Server
```

---

## Common Interview Questions

### Q1: What is the difference between blocking and a deadlock?

**Blocking** is a normal situation where one transaction waits for another to release a lock. The blocked transaction will eventually proceed once the blocker finishes. **A deadlock** is a special case where two or more transactions form a circular wait -- none can proceed. SQL Server must terminate one transaction (the victim) to resolve it. Blocking is sequential waiting; a deadlock is a cycle.

### Q2: How does SQL Server detect deadlocks?

SQL Server runs a background thread called the **Lock Monitor** that periodically checks for deadlock cycles (every 5 seconds by default, but it can ramp up to checking every 100 milliseconds under high deadlock frequency). When a cycle is detected, the Lock Monitor chooses a victim based on `DEADLOCK_PRIORITY` settings and rollback cost, then terminates the victim session with error 1205.

### Q3: Explain lock escalation. Can you prevent it?

Lock escalation occurs when a transaction accumulates approximately 5,000 locks on a single table. SQL Server converts these to a single table-level lock to save memory. You can prevent it by setting `LOCK_ESCALATION = DISABLE` on the table, processing data in smaller batches, or for partitioned tables, using `LOCK_ESCALATION = AUTO` to escalate to partition level instead of table level.

### Q4: What is an Update (U) lock and why is it needed?

An update lock is a special lock mode used during the search phase of an UPDATE statement. Without it, two transactions could both acquire shared locks on the same row, then both attempt to convert to exclusive locks -- resulting in a deadlock. The update lock is compatible with shared locks (readers are not blocked) but is not compatible with other update locks (only one updater can target the same row). Once the modification begins, the U lock is promoted to an X lock.

### Q5: Your production database is experiencing severe blocking. Walk through your troubleshooting approach.

1. Identify the head blocker using `sys.dm_exec_requests` (find sessions where `blocking_session_id > 0`, trace the chain to the root).
2. Examine the head blocker's query using `sys.dm_exec_sql_text` and check if it is an active or sleeping session (`sys.dm_exec_sessions`).
3. Check if the blocker has an open uncommitted transaction (`sys.dm_tran_active_transactions`).
4. Look at wait types (`LCK_M_S`, `LCK_M_X`, etc.) to understand the lock contention.
5. Check for missing indexes that might cause unnecessary scans and broader locks.
6. Consider whether lock escalation is occurring (check `lock_escalation` events in Extended Events).
7. For immediate relief: consider killing the head blocker (with business approval) or implement RCSI.
8. Long term: optimize queries, add indexes, shorten transactions, implement RCSI.

### Q6: What are the risks of using NOLOCK?

Dirty reads (reading uncommitted data), non-repeatable reads, phantom reads, skipped rows, duplicate reads (during page splits), and potential corruption with LOB columns. NOLOCK does not mean "no locks" -- it still acquires Sch-S locks. It is not a performance silver bullet and should not be used where data accuracy matters.

### Q7: How do you capture and analyze deadlock graphs?

The recommended approach is Extended Events. The `system_health` session captures deadlock reports by default. You can query the ring buffer or event file targets to extract `xml_deadlock_report` events. Save the XML as a `.xdl` file and open it in SSMS for a visual graph. Alternatively, enable Trace Flag 1222 for detailed deadlock information in the error log. The deadlock graph shows the processes involved, the resources they locked/requested, and which process was chosen as the victim.

### Q8: How would you handle a deadlock in application code?

Implement retry logic. Catch SQL error 1205 specifically, rollback the transaction, wait briefly (with optional exponential backoff), and retry. Typically, 3 retries is sufficient. Additionally, review the deadlock graph to understand the root cause and apply prevention strategies (consistent object access order, shorter transactions, appropriate indexing, RCSI).

---

## Tips

- **Always check for open transactions first when investigating blocking.** A sleeping session with an open transaction is a common culprit -- often caused by application code that begins a transaction but does not commit or rollback due to an error path.

- **The system_health Extended Events session captures deadlocks by default** starting with SQL Server 2012. You do not need to enable trace flags or create custom sessions to capture deadlocks, though a custom session gives you more control over retention.

- **Lock escalation is a memory protection feature, not a bug.** Do not disable it globally. If you must disable it, do so on specific high-contention tables and ensure you have enough memory for the additional row/page locks.

- **Batch your large operations.** Instead of updating millions of rows in one statement, process them in batches of 2,000-5,000 rows. This avoids lock escalation, reduces blocking duration, and keeps the transaction log manageable.

- **RCSI eliminates most reader-writer blocking without application changes.** It is one of the most impactful changes you can make to a blocking-heavy OLTP workload. See the next topic on [Concurrency Control & MVCC](./17-concurrency-control-mvcc.md).

- **Deadlocks are not always a "bug" to fix** -- they can be a natural consequence of high concurrency. The goal is to minimize their frequency and handle them gracefully with retry logic, not to eliminate them entirely.

- **Use `sys.dm_tran_locks` for real-time lock analysis**, but be aware that querying this DMV under heavy lock contention can itself be slow due to the volume of lock data.

- **Never use `KILL` as a long-term solution to blocking.** Killing sessions can cause long rollbacks and does not address the root cause. Investigate why the session is blocking and fix the underlying issue.
