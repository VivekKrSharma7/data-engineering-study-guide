# Transaction Isolation Levels

[Back to SQL Server Index](./README.md)

---

## Overview

Transaction isolation levels control how transactions interact with each other -- specifically, how and when changes made by one transaction become visible to other concurrent transactions. Choosing the right isolation level is a fundamental trade-off between **data consistency** and **concurrency/performance**.

SQL Server supports six isolation levels: four pessimistic (lock-based) and two optimistic (row versioning-based).

---

## Concurrency Phenomena

Before examining each isolation level, understand the three phenomena they are designed to prevent:

### Dirty Read

A transaction reads data that has been modified by another transaction but not yet committed. If the modifying transaction rolls back, the reading transaction has read data that never actually existed.

```
Transaction A:  UPDATE Accounts SET Balance = 500 WHERE ID = 1;  (was 1000)
Transaction B:  SELECT Balance FROM Accounts WHERE ID = 1;       --> reads 500 (dirty!)
Transaction A:  ROLLBACK;  (Balance reverts to 1000)
-- Transaction B used a value (500) that was never committed
```

### Non-Repeatable Read

A transaction reads the same row twice and gets different values because another transaction modified and committed the row in between.

```
Transaction A:  SELECT Balance FROM Accounts WHERE ID = 1;  --> reads 1000
Transaction B:  UPDATE Accounts SET Balance = 500 WHERE ID = 1; COMMIT;
Transaction A:  SELECT Balance FROM Accounts WHERE ID = 1;  --> reads 500 (different!)
```

### Phantom Read

A transaction executes the same query twice and gets different sets of rows because another transaction inserted or deleted rows that match the query's WHERE clause.

```
Transaction A:  SELECT * FROM Orders WHERE Status = 'Pending';  --> 10 rows
Transaction B:  INSERT INTO Orders (...) VALUES (..., 'Pending'); COMMIT;
Transaction A:  SELECT * FROM Orders WHERE Status = 'Pending';  --> 11 rows (phantom!)
```

---

## Isolation Levels at a Glance

| Isolation Level | Dirty Reads | Non-Repeatable Reads | Phantoms | Concurrency Model |
|---|---|---|---|---|
| READ UNCOMMITTED | Yes | Yes | Yes | Pessimistic (no shared locks) |
| READ COMMITTED (default) | No | Yes | Yes | Pessimistic |
| REPEATABLE READ | No | No | Yes | Pessimistic |
| SERIALIZABLE | No | No | No | Pessimistic |
| SNAPSHOT | No | No | No | Optimistic (row versioning) |
| READ COMMITTED SNAPSHOT (RCSI) | No | Yes | Yes | Optimistic (row versioning) |

---

## Pessimistic Isolation Levels (Lock-Based)

### READ UNCOMMITTED

The lowest isolation level. Readers do not acquire shared locks and ignore exclusive locks held by writers. This means reads can see uncommitted (dirty) data.

```sql
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

SELECT * FROM dbo.Orders WHERE Status = 'Pending';

-- Equivalent using a table hint:
SELECT * FROM dbo.Orders WITH (NOLOCK) WHERE Status = 'Pending';
```

**When to use:**
- Rough estimates, dashboards, or monitoring queries where absolute accuracy is not required
- Large table scans where blocking would be unacceptable and minor inaccuracy is tolerable
- Reading from tables that are append-only (no updates or deletes)

**Risks:** You can read rows that are partially updated, rows that will be rolled back, or even get errors from reading pages that are being split.

---

### READ COMMITTED (Default)

The default isolation level in SQL Server. Readers acquire shared locks that are released immediately after each row is read (not held for the duration of the transaction). Writers hold exclusive locks until commit.

```sql
-- This is the default; explicitly setting it:
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

BEGIN TRANSACTION;
    SELECT Balance FROM dbo.Accounts WHERE ID = 1;
    -- Shared lock acquired and released immediately
    -- Another transaction could change the row here
    SELECT Balance FROM dbo.Accounts WHERE ID = 1;
    -- May see a different value (non-repeatable read)
COMMIT;
```

**Behavior:** Prevents dirty reads because shared locks conflict with exclusive locks. Does not prevent non-repeatable reads because shared locks are released after each read, allowing other transactions to modify the data.

---

### REPEATABLE READ

Shared locks are held for the duration of the transaction (not released after each read). This prevents other transactions from modifying rows that have been read.

```sql
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;

BEGIN TRANSACTION;
    SELECT Balance FROM dbo.Accounts WHERE ID = 1;
    -- Shared lock HELD on this row until COMMIT/ROLLBACK
    -- No other transaction can UPDATE or DELETE this row
    WAITFOR DELAY '00:00:05';
    SELECT Balance FROM dbo.Accounts WHERE ID = 1;
    -- Guaranteed to see the same value
COMMIT;
-- Shared locks released here
```

**Limitation:** Prevents modifications to rows already read, but does not prevent inserts of new rows that match the query's WHERE clause (phantoms). Another transaction could insert a new row with `ID = 2` that the next SELECT might pick up if the WHERE clause were broader.

**Deadlock risk:** Higher than READ COMMITTED because locks are held longer.

---

### SERIALIZABLE

The highest pessimistic isolation level. In addition to holding shared locks for the transaction duration, it acquires key-range locks to prevent phantom inserts.

```sql
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;

BEGIN TRANSACTION;
    SELECT * FROM dbo.Orders WHERE Status = 'Pending';
    -- Key-range locks held on the index range for Status = 'Pending'
    -- No other transaction can INSERT, UPDATE, or DELETE rows
    -- that would match Status = 'Pending'
    WAITFOR DELAY '00:00:05';
    SELECT * FROM dbo.Orders WHERE Status = 'Pending';
    -- Guaranteed same result set (no phantoms)
COMMIT;
```

**Key-range locks:** Lock the range of index keys covered by the query, preventing inserts into that range. This requires an appropriate index on the filtered column. Without an index, SQL Server may escalate to table-level locks.

```sql
-- Equivalent using table hint:
SELECT * FROM dbo.Orders WITH (HOLDLOCK) WHERE Status = 'Pending';
```

**Risks:**
- Significantly reduced concurrency
- High deadlock potential
- Can cause severe blocking under OLTP workloads

---

## Optimistic Isolation Levels (Row Versioning-Based)

Optimistic isolation levels use **row versioning** instead of locks to provide consistency. When a row is modified, SQL Server stores the previous version in the **version store** (located in tempdb). Readers read from the version store instead of being blocked by writers.

### SNAPSHOT Isolation

Provides a transaction-consistent view of data as it existed at the start of the transaction. All reads within the transaction see the same snapshot, regardless of concurrent modifications.

**Setup (database-level, one-time):**

```sql
ALTER DATABASE MyDatabase SET ALLOW_SNAPSHOT_ISOLATION ON;
```

**Usage:**

```sql
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;

BEGIN TRANSACTION;
    -- All reads in this transaction see data as of this moment
    SELECT Balance FROM dbo.Accounts WHERE ID = 1;  --> 1000

    -- Even if another transaction commits a change:
    -- (concurrent) UPDATE Accounts SET Balance = 500 WHERE ID = 1; COMMIT;

    SELECT Balance FROM dbo.Accounts WHERE ID = 1;  --> still 1000
COMMIT;
```

**Update conflict detection:** If two concurrent snapshot transactions try to update the same row, the second one to commit receives an update conflict error (Error 3960):

```
Msg 3960: Snapshot isolation transaction aborted due to update conflict.
```

The application must handle this by retrying the transaction.

**Characteristics:**
- Readers never block writers; writers never block readers
- Readers never see dirty, non-repeatable, or phantom data
- Writers can still block other writers (exclusive locks are still used for writes)
- Update conflicts must be handled by the application

---

### READ COMMITTED SNAPSHOT Isolation (RCSI)

A modified version of READ COMMITTED that uses row versioning instead of shared locks. Each statement (not transaction) sees a consistent snapshot of data as of the start of that statement.

**Setup (database-level, one-time):**

```sql
-- This changes the behavior of ALL READ COMMITTED transactions in the database
-- No code changes needed in applications
ALTER DATABASE MyDatabase SET READ_COMMITTED_SNAPSHOT ON;
```

> **Important:** This ALTER requires exclusive database access (no other connections). Plan for a maintenance window or use single-user mode briefly.

**Behavior after enabling:**

```sql
-- No SET TRANSACTION ISOLATION LEVEL needed; READ COMMITTED now uses versioning
BEGIN TRANSACTION;
    SELECT Balance FROM dbo.Accounts WHERE ID = 1;  --> 1000 (statement-level snapshot)
    -- Another transaction commits: Balance = 500
    SELECT Balance FROM dbo.Accounts WHERE ID = 1;  --> 500 (new statement, new snapshot)
    -- Non-repeatable read is still possible, but no blocking occurred
COMMIT;
```

**Key difference from SNAPSHOT:**

| Aspect | SNAPSHOT | RCSI |
|---|---|---|
| Snapshot point | Start of transaction | Start of each statement |
| Non-repeatable reads | Prevented | Possible |
| Phantom reads | Prevented | Possible |
| Update conflicts | Yes (error 3960) | No (uses latest committed value) |
| Must set isolation level | Yes (explicit SET) | No (transparent replacement) |
| Database setting | `ALLOW_SNAPSHOT_ISOLATION` | `READ_COMMITTED_SNAPSHOT` |

---

## Pessimistic vs. Optimistic Concurrency

### Pessimistic (Lock-Based)

- **Philosophy:** Assume conflicts will happen. Prevent them by acquiring locks.
- **Readers block writers** (shared vs. exclusive lock conflict) at READ COMMITTED and above.
- **Writers block readers** at READ COMMITTED and above.
- **Pros:** No tempdb overhead, no update conflict errors, well-understood behavior.
- **Cons:** Blocking, deadlocks, reduced throughput under high concurrency.

### Optimistic (Row Versioning-Based)

- **Philosophy:** Assume conflicts are rare. Allow concurrent access; detect conflicts only when they occur.
- **Readers never block writers.** Readers read from the version store.
- **Writers never block readers.** Writers still acquire exclusive locks (writers can still block other writers).
- **Pros:** Dramatically reduced blocking, better throughput for read-heavy workloads.
- **Cons:** tempdb overhead (version store), increased tempdb I/O, update conflicts (SNAPSHOT), slight CPU overhead for version chain traversal.

---

## Setting Isolation Levels

### Session Level

```sql
-- Set for the current session (persists until changed or session ends)
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
```

### Query-Level Hints

Table hints override the session isolation level for a specific table within a query.

```sql
-- NOLOCK = READ UNCOMMITTED
SELECT * FROM dbo.Orders WITH (NOLOCK);

-- HOLDLOCK = SERIALIZABLE
SELECT * FROM dbo.Orders WITH (HOLDLOCK) WHERE Status = 'Pending';

-- READCOMMITTEDLOCK = force lock-based READ COMMITTED (useful when RCSI is enabled)
SELECT * FROM dbo.Orders WITH (READCOMMITTEDLOCK);

-- READPAST: skip locked rows (only reads unlocked rows)
SELECT TOP 1 * FROM dbo.TaskQueue WITH (READPAST, UPDLOCK, ROWLOCK)
WHERE Status = 'Pending' ORDER BY Priority;

-- UPDLOCK: acquire update locks (prevent conversion deadlocks)
SELECT * FROM dbo.Accounts WITH (UPDLOCK) WHERE AccountID = 1;
```

### Checking Current Isolation Level

```sql
-- Method 1: DBCC
DBCC USEROPTIONS;  -- look for 'isolation level' row

-- Method 2: System function
SELECT
    CASE transaction_isolation_level
        WHEN 0 THEN 'Unspecified'
        WHEN 1 THEN 'READ UNCOMMITTED'
        WHEN 2 THEN 'READ COMMITTED'
        WHEN 3 THEN 'REPEATABLE READ'
        WHEN 4 THEN 'SERIALIZABLE'
        WHEN 5 THEN 'SNAPSHOT'
    END AS isolation_level
FROM sys.dm_exec_sessions
WHERE session_id = @@SPID;
```

---

## Version Store in tempdb

When SNAPSHOT or RCSI is enabled, SQL Server maintains a **version store** in tempdb that holds previous versions of modified rows.

### How It Works

1. When a transaction modifies a row, the original (pre-modification) version is copied to the version store in tempdb.
2. A 14-byte version tag is appended to each row in the user database, pointing to the version chain in tempdb.
3. Readers that need an older version follow the version chain to find the appropriate snapshot.
4. A background cleanup process periodically purges version store entries that are no longer needed by any active transaction.

### Monitoring the Version Store

```sql
-- Version store size
SELECT
    SUM(version_store_reserved_page_count) * 8 / 1024 AS version_store_mb
FROM sys.dm_db_file_space_usage;

-- Version store generation and cleanup rates
SELECT
    cntr_value,
    counter_name
FROM sys.dm_os_performance_counters
WHERE counter_name IN (
    'Version Store Size (KB)',
    'Version Generation rate (KB/s)',
    'Version Cleanup rate (KB/s)'
);

-- Long-running transactions holding version store growth
SELECT
    t.transaction_id,
    t.elapsed_time_seconds,
    s.session_id,
    s.login_name,
    s.host_name,
    st.text AS sql_text
FROM sys.dm_tran_active_snapshot_database_transactions t
INNER JOIN sys.dm_exec_sessions s
    ON t.session_id = s.session_id
OUTER APPLY sys.dm_exec_sql_text(s.most_recent_sql_handle) st
ORDER BY t.elapsed_time_seconds DESC;
```

### Row Versioning Overhead

1. **14-byte row overhead:** Every row in a table with versioning active gets a 14-byte pointer appended. This increases row size and can cause page splits during the first update after enabling.
2. **tempdb I/O:** Version store reads and writes add I/O load to tempdb. Ensure tempdb is on fast storage with multiple data files.
3. **Version chain length:** Long version chains (from long-running transactions) increase the cost of reading versioned rows, as readers must traverse the chain.
4. **tempdb space:** Long-running snapshot transactions prevent version cleanup, causing tempdb growth. Monitor and set alerts.

### Sizing tempdb for Row Versioning

- Monitor `version_store_reserved_page_count` from `sys.dm_db_file_space_usage` over a representative period.
- Add 20-30% headroom for peak workload.
- Use multiple tempdb data files (one per logical CPU core, up to 8).
- Pre-size tempdb data files to avoid autogrowth during production hours.

---

## Choosing the Right Isolation Level

### Decision Framework

```
Start here:
  |
  +--> Can you tolerate dirty reads?
  |      YES --> READ UNCOMMITTED (reporting, rough estimates)
  |      NO  |
  |          +--> Do readers blocking writers (and vice versa) cause problems?
  |                YES --> Use optimistic isolation:
  |                |       +--> Need statement-level consistency? --> RCSI
  |                |       +--> Need transaction-level consistency? --> SNAPSHOT
  |                NO  --> Use pessimistic isolation:
  |                        +--> Default behavior sufficient? --> READ COMMITTED
  |                        +--> Must re-read same values? --> REPEATABLE READ
  |                        +--> Must prevent phantoms too? --> SERIALIZABLE
```

### Real-World Recommendations

| Scenario | Recommended Level | Reasoning |
|---|---|---|
| **OLTP application (general)** | RCSI | Eliminates reader-writer blocking with minimal code changes |
| **Financial transactions** | SNAPSHOT or SERIALIZABLE | Need full consistency; SNAPSHOT avoids blocking |
| **Data warehouse reads** | READ UNCOMMITTED or RCSI | Large scans should not block ETL loads |
| **ETL/data loading** | READ COMMITTED (default) | Standard; use TABLOCK for bulk operations |
| **Queue processing table** | READ COMMITTED + READPAST hint | Skip locked rows to allow concurrent dequeuing |
| **Reporting on OLTP database** | SNAPSHOT | Consistent point-in-time reads without blocking OLTP |
| **Aggregation queries** | RCSI or SNAPSHOT | Avoid inconsistent aggregates from changing data |

---

## Real-World Scenarios and Trade-Offs

### Scenario 1: Moving from Pessimistic to RCSI

**Problem:** An OLTP application experiences heavy blocking. SELECT queries block UPDATE queries and vice versa. Users report timeouts.

**Solution:** Enable RCSI.

```sql
-- Step 1: Verify no active connections (or plan maintenance window)
ALTER DATABASE MyOLTPDatabase SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;

-- Step 2: Verify
SELECT is_read_committed_snapshot_on, snapshot_isolation_state_desc
FROM sys.databases
WHERE name = 'MyOLTPDatabase';
```

**Trade-offs:**
- Blocking virtually eliminated for reader-writer conflicts
- tempdb usage increases (monitor and pre-size)
- Non-repeatable reads still possible (same as before with READ COMMITTED)
- Application code requires zero changes (transparent)
- Trigger behavior may change if triggers read from `INSERTED`/`DELETED` and rely on blocking

### Scenario 2: SNAPSHOT for Consistent Reporting

**Problem:** A financial report runs a multi-table join that takes 30 seconds. During execution, underlying data changes, causing the report to show inconsistent balances (e.g., money counted in one account but not yet deducted from another).

**Solution:** Use SNAPSHOT isolation for the report.

```sql
ALTER DATABASE FinanceDB SET ALLOW_SNAPSHOT_ISOLATION ON;

-- In the reporting application:
SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
BEGIN TRANSACTION;

    SELECT AccountID, Balance FROM dbo.Accounts;
    SELECT TransactionID, Amount FROM dbo.Transactions WHERE TransactionDate = CAST(GETDATE() AS DATE);
    -- Both queries see data as of the BEGIN TRANSACTION moment

COMMIT;
```

### Scenario 3: Handling Update Conflicts with SNAPSHOT

```sql
-- Application retry logic (pseudo-code pattern)
DECLARE @RetryCount INT = 0, @MaxRetries INT = 3, @Success BIT = 0;

WHILE @RetryCount < @MaxRetries AND @Success = 0
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
        BEGIN TRANSACTION;

            DECLARE @CurrentBalance DECIMAL(18,2);
            SELECT @CurrentBalance = Balance FROM dbo.Accounts WHERE AccountID = 1;

            UPDATE dbo.Accounts
            SET Balance = @CurrentBalance - 100
            WHERE AccountID = 1;

        COMMIT TRANSACTION;
        SET @Success = 1;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        IF ERROR_NUMBER() = 3960  -- snapshot update conflict
        BEGIN
            SET @RetryCount += 1;
            WAITFOR DELAY '00:00:00.100';  -- brief pause before retry
        END
        ELSE
            THROW;  -- non-conflict error, re-throw
    END CATCH;
END;

IF @Success = 0
    THROW 50001, 'Update failed after maximum retries due to snapshot conflicts.', 1;
```

### Scenario 4: Queue Table with READPAST

```sql
-- Multiple workers dequeue concurrently without blocking each other
CREATE OR ALTER PROCEDURE dbo.usp_DequeueTask
    @TaskID INT OUTPUT,
    @Payload NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- READPAST: skip rows locked by other dequeue operations
    -- UPDLOCK + ROWLOCK: lock only the selected row
    UPDATE TOP (1) q
    SET q.Status = 'Processing',
        q.ProcessedBy = @@SPID,
        @TaskID = q.TaskID,
        @Payload = q.Payload
    FROM dbo.TaskQueue q WITH (READPAST, UPDLOCK, ROWLOCK)
    WHERE q.Status = 'Pending';
END;
```

### Scenario 5: Deadlock from Lock Escalation

**Problem:** Two sessions running REPEATABLE READ both read from Table A then update Table A. Session 1 holds shared locks and wants exclusive; Session 2 holds shared locks and wants exclusive. Deadlock.

**Solution options:**
1. Use UPDLOCK hint on the initial read to acquire update locks upfront (prevents conversion deadlock)
2. Switch to RCSI or SNAPSHOT to eliminate shared locks entirely
3. Reduce transaction scope to minimize lock hold time

```sql
-- Option 1: UPDLOCK to prevent conversion deadlock
BEGIN TRANSACTION;
    SELECT * FROM dbo.Accounts WITH (UPDLOCK)
    WHERE AccountID = 1;
    -- Update lock acquired; other sessions can still read but cannot acquire update/exclusive locks
    UPDATE dbo.Accounts SET Balance = Balance - 100 WHERE AccountID = 1;
COMMIT;
```

---

## Common Interview Questions and Answers

### Q1: What is the default isolation level in SQL Server, and what does it prevent?

**A:** The default is READ COMMITTED. It prevents dirty reads by acquiring shared locks during reads that conflict with exclusive locks held by uncommitted writers. However, shared locks are released immediately after each row is read (not held for the transaction), so non-repeatable reads and phantom reads are still possible.

### Q2: What is the difference between SNAPSHOT and READ COMMITTED SNAPSHOT (RCSI)?

**A:** Both use row versioning to avoid reader-writer blocking. SNAPSHOT provides transaction-level consistency: all reads within a transaction see data as of the transaction start time. RCSI provides statement-level consistency: each statement sees data as of the statement start time. SNAPSHOT prevents non-repeatable reads and phantoms; RCSI does not. SNAPSHOT can generate update conflict errors (3960); RCSI does not. RCSI is transparent (no code changes), while SNAPSHOT requires explicitly setting the isolation level.

### Q3: What happens to tempdb when you enable row versioning?

**A:** SQL Server uses a version store in tempdb to maintain previous versions of modified rows. This increases tempdb I/O, CPU (for version chain management), and space consumption. A 14-byte version pointer is added to each row in affected tables. Long-running snapshot transactions prevent version cleanup and can cause tempdb to grow significantly. Proper tempdb sizing, multiple data files, and monitoring of `sys.dm_db_file_space_usage` and `sys.dm_tran_active_snapshot_database_transactions` are essential.

### Q4: When would you use SERIALIZABLE isolation?

**A:** SERIALIZABLE is appropriate when you must guarantee that no other transaction can insert, update, or delete data in the range you are reading, effectively making the transaction behave as if it ran alone. Use cases include financial calculations where phantom rows would cause incorrect results, enforcing business rules across related rows, and MERGE operations that need to guarantee uniqueness. However, it significantly reduces concurrency and increases deadlock risk, so it should be used sparingly.

### Q5: Explain the READPAST hint and its use case.

**A:** READPAST causes a query to skip rows that are currently locked by other transactions rather than waiting for the lock to be released. It is commonly used in queue-processing patterns where multiple worker processes dequeue items concurrently. Combined with UPDLOCK and ROWLOCK, it allows each worker to grab a different unlocked row without blocking each other. It only works under READ COMMITTED or REPEATABLE READ isolation levels.

### Q6: How do you diagnose whether blocking is caused by isolation level issues?

**A:** Query `sys.dm_exec_requests` to find sessions with non-zero `blocking_session_id`. Examine the `wait_type` (LCK_M_S, LCK_M_X, etc.) and `wait_resource` to identify the locked resource. Check `sys.dm_tran_locks` for the specific locks held. Check both sessions' isolation levels via `sys.dm_exec_sessions.transaction_isolation_level`. If readers are blocked by writers (LCK_M_S waiting on LCK_M_X), consider enabling RCSI or SNAPSHOT. If writers are blocked by writers, review transaction design and lock granularity.

### Q7: Can you mix isolation levels within the same database?

**A:** Yes. The isolation level is set per session (or per query with table hints). Different sessions can operate at different isolation levels simultaneously on the same database. You can also enable both RCSI and ALLOW_SNAPSHOT_ISOLATION on the same database, allowing some sessions to use RCSI (the default for READ COMMITTED) and others to explicitly use SNAPSHOT when they need transaction-level consistency.

### Q8: What is a conversion deadlock and how do you prevent it?

**A:** A conversion deadlock occurs when two transactions both hold shared locks on the same resource and then both try to convert those locks to exclusive locks. Neither can proceed because the other's shared lock prevents the upgrade. Prevention strategies: use UPDLOCK hint on the initial read to acquire an update lock (compatible with shared locks but not with other update locks), use RCSI/SNAPSHOT to eliminate shared locks, or restructure transactions to access resources in a consistent order.

---

## Tips for Interviews and Real-World Practice

1. **Know the default.** READ COMMITTED is the default. Many developers do not realize this, and many blocking issues stem from misunderstanding what it does and does not prevent.

2. **RCSI is the most impactful single change for OLTP.** Enabling RCSI on a blocking-heavy OLTP database is often the biggest bang-for-the-buck performance improvement. Mention this in interviews as a real-world recommendation.

3. **NOLOCK is not free.** While READ UNCOMMITTED avoids blocking, it can read uncommitted data, partially updated rows, or rows being moved by page splits. It is not simply "faster SELECT" -- it trades correctness for speed.

4. **tempdb is critical for row versioning.** If you recommend RCSI or SNAPSHOT, you must also discuss tempdb sizing, monitoring, and multiple data files. Interviewers expect this connection.

5. **Understand lock compatibility.** Shared locks are compatible with other shared locks but not with exclusive locks. Update locks are compatible with shared but not with other update locks. This knowledge is fundamental to explaining blocking behavior.

6. **SNAPSHOT is not SERIALIZABLE with better concurrency.** While SNAPSHOT prevents dirty reads, non-repeatable reads, and phantoms, it uses optimistic concurrency -- it does not prevent concurrent modifications, it detects conflicts after the fact. SERIALIZABLE prevents conflicts from occurring in the first place.

7. **Always mention deadlock handling in production code.** Set `DEADLOCK_PRIORITY`, implement retry logic, and keep transactions short. This demonstrates production experience.

8. **Know the 14-byte row overhead.** When enabling row versioning, every row gains 14 bytes for the version pointer. For very wide tables this is negligible, but for narrow tables with billions of rows, it can meaningfully increase storage and I/O.

9. **Test isolation level changes thoroughly.** Changing from pessimistic to optimistic concurrency can subtly change application behavior. Code that relied on blocking for synchronization may now produce different results under RCSI.

10. **Use `sys.dm_tran_locks` and `sys.dm_os_wait_stats` to validate your isolation level choice.** After making changes, verify that lock waits have decreased and that tempdb is not under pressure.

---
