# Point-in-Time Recovery & Disaster Recovery

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Point-in-Time Recovery Fundamentals](#point-in-time-recovery-fundamentals)
2. [Log Chain Integrity](#log-chain-integrity)
3. [Tail-Log Backups](#tail-log-backups)
4. [Point-in-Time Restore Using STOPAT](#point-in-time-restore-using-stopat)
5. [Database Snapshots for Quick Rollback](#database-snapshots-for-quick-rollback)
6. [Disaster Recovery Planning: RTO vs RPO](#disaster-recovery-planning-rto-vs-rpo)
7. [DR Strategies](#dr-strategies)
8. [Testing DR Plans](#testing-dr-plans)
9. [Creating a DR Runbook](#creating-a-dr-runbook)
10. [Common Interview Questions](#common-interview-questions)
11. [Tips](#tips)

---

## Point-in-Time Recovery Fundamentals

Point-in-time recovery (PITR) allows you to restore a database to a specific moment, recovering data up to just before an unwanted event (accidental DELETE, corruption, bad deployment). This capability depends entirely on your **recovery model** and backup strategy.

### Recovery Models and Their Impact

| Recovery Model | Transaction Log Behavior | Point-in-Time Restore? |
|---|---|---|
| **Full** | All transactions logged; log truncated only by log backup | Yes |
| **Bulk-Logged** | Minimally logs bulk operations; otherwise like Full | Limited (not during bulk-logged intervals) |
| **Simple** | Log auto-truncated at checkpoint | No |

**Key insight:** Point-in-time recovery is only possible under the **Full** recovery model (or Bulk-Logged, with caveats). If you are in Simple recovery mode, you can only restore to the point of your last full or differential backup.

```sql
-- Check the recovery model of all databases
SELECT name, recovery_model_desc
FROM sys.databases;

-- Change recovery model to Full
ALTER DATABASE [YourDatabase] SET RECOVERY FULL;
```

### The Backup Chain

A complete backup chain for point-in-time recovery consists of:

1. **Full backup** -- the baseline
2. **Differential backup** (optional) -- changes since last full
3. **Transaction log backups** -- continuous chain of all logged transactions

```
Full Backup     Diff Backup     Log Backups (every 15 min)
[Sunday 2AM] -> [Wednesday 2AM] -> [T1] -> [T2] -> [T3] -> ... -> [Tn]
```

Without an unbroken chain of log backups from the last full (or differential) backup to the desired restore point, point-in-time recovery is impossible.

---

## Log Chain Integrity

The **log chain** is the unbroken sequence of transaction log backups from a full backup to the present. Every log backup starts where the previous one ended.

### What Breaks a Log Chain

- Switching from Full to Simple recovery model and back
- Taking a full backup with `COPY_ONLY` does NOT break the chain (this is safe)
- Taking a full backup WITHOUT `COPY_ONLY` does NOT break the chain either -- a common misconception
- **Actual chain breakers:** switching to Simple, missing log backups, or a log backup failing silently

```sql
-- View backup history to verify log chain
SELECT
    bs.database_name,
    bs.type AS backup_type,
    bs.first_lsn,
    bs.last_lsn,
    bs.backup_start_date,
    bs.backup_finish_date
FROM msdb.dbo.backupset bs
WHERE bs.database_name = 'YourDatabase'
ORDER BY bs.backup_start_date DESC;
```

### Verifying Log Chain Continuity

For a valid chain, the `first_lsn` of each log backup must match the `last_lsn` of the previous log backup.

```sql
-- Detect log chain gaps
WITH LogBackups AS (
    SELECT
        database_name,
        backup_start_date,
        first_lsn,
        last_lsn,
        LAG(last_lsn) OVER (
            PARTITION BY database_name
            ORDER BY backup_start_date
        ) AS prev_last_lsn
    FROM msdb.dbo.backupset
    WHERE type = 'L'  -- Log backups only
      AND database_name = 'YourDatabase'
)
SELECT *
FROM LogBackups
WHERE prev_last_lsn IS NOT NULL
  AND first_lsn <> prev_last_lsn;
-- If rows are returned, you have a gap in the log chain.
```

---

## Tail-Log Backups

A **tail-log backup** captures the transaction log records that have not yet been backed up -- the "tail" of the log. This is the most critical step before starting a restore sequence if the database is still accessible.

### Why Tail-Log Backups Matter

Without a tail-log backup, you lose all transactions that occurred after the most recent scheduled log backup. If your log backups run every 15 minutes and a disaster strikes 14 minutes after the last backup, those 14 minutes of work are gone unless you take a tail-log backup first.

### Taking a Tail-Log Backup

```sql
-- Standard tail-log backup (database is online)
BACKUP LOG [YourDatabase]
TO DISK = 'D:\Backups\YourDatabase_TailLog.trn'
WITH NORECOVERY, NO_TRUNCATE;
```

- **`NORECOVERY`**: Puts the database in a restoring state, preventing further activity. Use this when you are about to start a restore sequence.
- **`NO_TRUNCATE`**: Attempts to back up the log even if the database is damaged. This is critical when the data files are corrupt but the log file is intact.

### When the Database Is Inaccessible

```sql
-- Tail-log backup when database is damaged
BACKUP LOG [YourDatabase]
TO DISK = 'D:\Backups\YourDatabase_TailLog.trn'
WITH CONTINUE_AFTER_ERROR, NO_TRUNCATE;
```

**Real-world scenario:** A storage failure corrupts the primary data file at 3:47 PM. Your last log backup was at 3:30 PM. If the transaction log file is on a separate, undamaged drive, you can capture a tail-log backup and recover up to 3:47 PM.

---

## Point-in-Time Restore Using STOPAT

The `STOPAT` clause is the mechanism that enables point-in-time recovery. It tells SQL Server to roll forward transactions only up to the specified datetime.

### Full Restore Sequence with STOPAT

```sql
-- Step 1: Take a tail-log backup (if database is still accessible)
BACKUP LOG [YourDatabase]
TO DISK = 'D:\Backups\YourDatabase_TailLog.trn'
WITH NORECOVERY, NO_TRUNCATE;

-- Step 2: Restore the most recent full backup
RESTORE DATABASE [YourDatabase]
FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
WITH NORECOVERY, REPLACE;

-- Step 3: Restore the most recent differential (if available)
RESTORE DATABASE [YourDatabase]
FROM DISK = 'D:\Backups\YourDatabase_Diff.bak'
WITH NORECOVERY;

-- Step 4: Restore log backups in sequence, applying STOPAT on the last one
RESTORE LOG [YourDatabase]
FROM DISK = 'D:\Backups\YourDatabase_Log1.trn'
WITH NORECOVERY;

RESTORE LOG [YourDatabase]
FROM DISK = 'D:\Backups\YourDatabase_Log2.trn'
WITH NORECOVERY;

-- Step 5: Restore the tail-log with STOPAT
RESTORE LOG [YourDatabase]
FROM DISK = 'D:\Backups\YourDatabase_TailLog.trn'
WITH STOPAT = '2026-03-07T14:30:00', RECOVERY;
```

### Important STOPAT Details

- The `STOPAT` datetime is **inclusive** -- transactions committed at or before that time are applied.
- You can apply `STOPAT` on any log restore in the sequence, but typically you apply it on the log backup that spans the target time.
- If the specified time is beyond the last log backup, SQL Server recovers everything available.
- The datetime must be in a format SQL Server recognizes (ISO 8601 is safest).

### Using STOPATMARK and STOPBEFOREMARK

For named transaction recovery:

```sql
-- In your application code, use named transactions
BEGIN TRANSACTION BadDeploy WITH MARK 'Deployment at 2:30 PM';
    -- ... DML statements ...
COMMIT TRANSACTION BadDeploy;

-- Restore up to just before the marked transaction
RESTORE LOG [YourDatabase]
FROM DISK = 'D:\Backups\YourDatabase_Log.trn'
WITH STOPBEFOREMARK = 'BadDeploy', RECOVERY;
```

---

## Database Snapshots for Quick Rollback

Database snapshots provide a read-only, point-in-time view of a database. They are not a replacement for backups but can serve as a quick rollback mechanism for planned changes.

### Creating a Snapshot

```sql
-- Create a snapshot before a deployment
CREATE DATABASE [YourDatabase_BeforeDeploy]
ON (
    NAME = YourDatabase_Data,
    FILENAME = 'D:\Snapshots\YourDatabase_BeforeDeploy.ss'
)
AS SNAPSHOT OF [YourDatabase];
```

### Reverting to a Snapshot

```sql
-- Revert the source database to the snapshot
RESTORE DATABASE [YourDatabase]
FROM DATABASE_SNAPSHOT = 'YourDatabase_BeforeDeploy';
```

### Snapshot Caveats

- Snapshots use **copy-on-write** (sparse files). As the source database changes, the snapshot file grows.
- You cannot revert if more than one snapshot exists on the source database -- drop the others first.
- Full-text indexes are dropped on revert.
- Snapshots are **not a backup** -- if the source database's drive fails, the snapshot is also lost.
- Performance overhead exists because every first-time page modification copies the original page to the snapshot.

### Real-World Usage

```
1. Friday 5 PM: Create snapshot before weekend deployment
2. Friday 6 PM: Run deployment scripts
3. Friday 7 PM: Test application -- find critical bug
4. Friday 7:05 PM: Revert to snapshot (seconds vs. hours for a full restore)
5. Drop snapshot after successful deployment on retry
```

---

## Disaster Recovery Planning: RTO vs RPO

### Definitions

| Metric | Definition | Question It Answers |
|---|---|---|
| **RPO** (Recovery Point Objective) | Maximum acceptable data loss measured in time | "How much data can we afford to lose?" |
| **RTO** (Recovery Time Objective) | Maximum acceptable downtime | "How long can we afford to be offline?" |

### Real-World Examples

| Business Scenario | RPO | RTO | Strategy |
|---|---|---|---|
| E-commerce platform | Near-zero | < 1 minute | Synchronous AG with auto-failover |
| Internal reporting DB | 1 hour | 4 hours | Log shipping + full backups |
| Dev/Test environment | 24 hours | 1 business day | Nightly full backup only |
| Financial trading system | Zero | < 30 seconds | Synchronous AG + geo-replicated AG |

### Calculating Backup Frequency from RPO

If your RPO is 15 minutes, your log backup frequency must be at most every 15 minutes. In practice, you should back up more frequently to provide margin:

```sql
-- Example: Log backup job running every 10 minutes for a 15-minute RPO
-- In SQL Server Agent, create a job with this step:
BACKUP LOG [YourDatabase]
TO DISK = 'D:\Backups\YourDatabase_Log_'
    + CONVERT(VARCHAR(20), GETDATE(), 112)
    + '_'
    + REPLACE(CONVERT(VARCHAR(8), GETDATE(), 108), ':', '')
    + '.trn';
```

---

## DR Strategies

### 1. Backup and Restore

The simplest and most universal DR strategy.

**Pros:** Works on all editions, low cost, backups can be shipped offsite.
**Cons:** Highest RTO (depends on database size and network), highest RPO (depends on backup frequency).

```sql
-- Copy-only backup for offsite without disturbing the log chain
BACKUP DATABASE [YourDatabase]
TO DISK = 'D:\Backups\YourDatabase_CopyOnly.bak'
WITH COPY_ONLY, COMPRESSION, CHECKSUM;

-- Verify backup integrity
RESTORE VERIFYONLY
FROM DISK = 'D:\Backups\YourDatabase_CopyOnly.bak'
WITH CHECKSUM;
```

### 2. Log Shipping

Automated process: back up logs on the primary, copy them to a secondary server, restore them automatically.

**Pros:** Simple to set up, works on Standard edition, secondary can be in standby (read-only) mode.
**Cons:** RPO depends on log shipping frequency (typically 5-15 minutes), manual failover required.

```
Primary Server                    Secondary Server
[YourDatabase] --> Log Backup --> Copy --> Restore (with STANDBY or NORECOVERY)
     (every 5 min)         (copy job)     (restore job)
```

### 3. Availability Groups (AG)

Enterprise-level HA/DR solution using database-level replication.

| Mode | Data Loss | Failover | Use Case |
|---|---|---|---|
| **Synchronous commit** | Zero | Automatic (with listener) | HA within a datacenter |
| **Asynchronous commit** | Possible | Manual only | DR across datacenters |

```sql
-- Check AG health
SELECT
    ag.name AS ag_name,
    ars.role_desc,
    ars.synchronization_health_desc,
    ars.connected_state_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_groups ag ON ars.group_id = ag.group_id;
```

### 4. Geo-Replication (Azure SQL)

For Azure SQL Database, active geo-replication provides asynchronous replication to a different Azure region.

```sql
-- Azure SQL: Create a geo-secondary
ALTER DATABASE [YourDatabase]
ADD SECONDARY ON SERVER [your-dr-server]
WITH (ALLOW_CONNECTIONS = ALL);

-- Failover
ALTER DATABASE [YourDatabase] FAILOVER;
```

### 5. Distributed Availability Groups

Span AGs across Windows Server Failover Clusters (or across on-premises and Azure). Useful for migrations and multi-site DR.

### Strategy Comparison Matrix

| Feature | Backup/Restore | Log Shipping | AG (Sync) | AG (Async) | Geo-Replication |
|---|---|---|---|---|---|
| RPO | Hours | Minutes | Zero | Seconds | Seconds |
| RTO | Hours | Minutes | Seconds | Minutes | Seconds |
| Auto Failover | No | No | Yes | No | Yes (failover group) |
| Edition | All | Standard+ | Enterprise* | Enterprise* | Azure SQL |
| Complexity | Low | Low | High | High | Medium |

*Basic AGs available in Standard edition with 2-node limit.

---

## Testing DR Plans

A disaster recovery plan that has never been tested is not a plan -- it is a hope.

### What to Test

1. **Backup integrity** -- Can you actually restore from your backups?
2. **Restore time** -- Does your actual restore time meet your RTO?
3. **Log chain continuity** -- Is the chain unbroken?
4. **Failover process** -- Does the AG/log shipping failover actually work?
5. **Application connectivity** -- Does the application reconnect after failover?
6. **Runbook accuracy** -- Can a team member follow the runbook without tribal knowledge?

### Automated Restore Testing

```sql
-- Automated restore test (run weekly via SQL Agent)
-- Restore a copy of production to a test server to verify backups

RESTORE DATABASE [YourDatabase_RestoreTest]
FROM DISK = 'D:\Backups\YourDatabase_Full.bak'
WITH MOVE 'YourDatabase_Data' TO 'D:\TestRestore\YourDatabase_Data.mdf',
     MOVE 'YourDatabase_Log' TO 'D:\TestRestore\YourDatabase_Log.ldf',
     REPLACE, RECOVERY, STATS = 10;

-- Run DBCC to verify integrity
DBCC CHECKDB([YourDatabase_RestoreTest]) WITH NO_INFOMSGS;

-- Record the result and drop
DROP DATABASE [YourDatabase_RestoreTest];
```

### DR Drill Checklist

- [ ] Notify stakeholders of the drill
- [ ] Document the current state (timestamps, LSNs)
- [ ] Execute failover per the runbook
- [ ] Validate data integrity on the DR target
- [ ] Test application connectivity
- [ ] Measure actual RTO
- [ ] Fail back to the primary
- [ ] Write a post-drill report with findings
- [ ] Update the runbook with any corrections

---

## Creating a DR Runbook

A DR runbook is a step-by-step operational document that anyone on the team can follow during a disaster.

### Essential Runbook Sections

1. **Contact List** -- Who to call, escalation paths, vendor support numbers
2. **System Inventory** -- Server names, IPs, databases, dependencies
3. **DR Topology Diagram** -- Primary, secondary, network paths, storage
4. **Decision Matrix** -- When to declare a disaster vs. wait for recovery
5. **Step-by-Step Procedures** -- For each DR scenario:
   - Full site failure
   - Single database corruption
   - Storage failure
   - Accidental data deletion
   - Ransomware / security breach
6. **Validation Steps** -- How to confirm the DR environment is working
7. **Failback Procedure** -- How to return to normal operations
8. **Revision History** -- When was it last updated and tested?

### Example Runbook Entry: Accidental Table Drop

```
SCENARIO: Production table accidentally dropped
SEVERITY: Critical
RPO TARGET: Zero data loss
RTO TARGET: 30 minutes

STEPS:
1. STOP the application immediately (prevent further writes)
2. Take a tail-log backup:
   BACKUP LOG [ProdDB] TO DISK = '\\backup\ProdDB_TailLog.trn'
   WITH NORECOVERY, NO_TRUNCATE;

3. Identify the exact time of the DROP from the default trace or
   fn_dblog:
   SELECT TOP 100 *
   FROM fn_dblog(NULL, NULL)
   WHERE Operation = 'LOP_DROP_TABLE'
   ORDER BY [Current LSN] DESC;

4. Restore to a parallel database with STOPAT just before the DROP:
   RESTORE DATABASE [ProdDB_Recovery]
   FROM DISK = '\\backup\ProdDB_Full.bak'
   WITH MOVE ... , NORECOVERY;

   RESTORE LOG [ProdDB_Recovery]
   FROM DISK = '\\backup\ProdDB_Log1.trn'
   WITH STOPAT = '<time_before_drop>', RECOVERY;

5. Copy the table back using INSERT INTO ... SELECT or BCP.
6. Validate row counts and data integrity.
7. Resume the application.
8. Write an incident report.
```

---

## Common Interview Questions

### Q1: Explain the steps to perform a point-in-time recovery in SQL Server.

**A:** Point-in-time recovery requires the Full recovery model and an unbroken log chain. The steps are:
1. Take a tail-log backup (if the database is accessible) using `BACKUP LOG ... WITH NORECOVERY, NO_TRUNCATE`.
2. Restore the most recent full backup with `NORECOVERY`.
3. Restore the most recent differential backup (if available) with `NORECOVERY`.
4. Restore each subsequent transaction log backup with `NORECOVERY`.
5. On the final log restore, use `STOPAT = '<target_datetime>'` with `RECOVERY` to bring the database online at the desired point in time.

### Q2: What is a tail-log backup and why is it critical?

**A:** A tail-log backup captures the portion of the transaction log that has not yet been backed up. Without it, any transactions committed after the last scheduled log backup are permanently lost. It is the first action you should take before beginning any restore sequence, assuming the log file is accessible. The `NO_TRUNCATE` option allows you to back up the log even when the data files are damaged.

### Q3: What breaks a log chain, and how do you detect it?

**A:** A log chain is broken when there is a gap in the sequence of log LSNs. Common causes include switching the recovery model to Simple (which auto-truncates the log), deleting or losing a log backup file, or a failed log backup job that goes unnoticed. You detect it by querying `msdb.dbo.backupset` and comparing the `first_lsn` of each log backup against the `last_lsn` of its predecessor. Any mismatch indicates a break.

### Q4: Compare RTO and RPO. How do they drive your DR strategy?

**A:** RPO defines how much data loss is acceptable (e.g., "we can lose at most 15 minutes of data"), which drives backup frequency and replication mode. RTO defines how much downtime is acceptable (e.g., "we must be back online within 1 hour"), which drives the choice of DR technology. A near-zero RPO and RTO requires synchronous Availability Groups with automatic failover. A 24-hour RPO with an 8-hour RTO might only need nightly backups shipped offsite.

### Q5: When would you use a database snapshot instead of a full restore for rollback?

**A:** Database snapshots are ideal for **planned** changes where you want a quick undo option -- for example, before running a deployment script on a moderately sized database. Reverting to a snapshot is much faster than a full restore because it only copies back the changed pages. However, snapshots are not a substitute for backups: they reside on the same server, depend on the source database's storage, and are lost if the underlying drive fails.

### Q6: You need to design a DR strategy for a business-critical database with RPO < 5 seconds and RTO < 1 minute. What do you recommend?

**A:** I would recommend a synchronous-commit Availability Group with automatic failover for the local HA requirement, combined with an asynchronous-commit replica in a remote datacenter for geographic DR. The synchronous replica ensures zero data loss locally, and the automatic failover meets the sub-minute RTO. For the remote replica, the RPO would typically be a few seconds of asynchronous lag. I would also configure a listener for transparent application failover and run quarterly DR drills to validate the setup.

### Q7: How do you verify that your backups are actually restorable?

**A:** `RESTORE VERIFYONLY` performs basic checks on backup structure and checksum but does not guarantee restorability. The only reliable verification is to actually restore the backup to a test environment and run `DBCC CHECKDB`. I recommend automating this as a weekly SQL Agent job that restores the latest backup to a test database, runs integrity checks, logs the result, and drops the test database.

### Q8: Explain the difference between NORECOVERY, RECOVERY, and STANDBY in a restore sequence.

**A:**
- **NORECOVERY**: Leaves the database in a restoring state so additional backups can be applied. Uncommitted transactions are not rolled back.
- **RECOVERY** (default): Rolls back uncommitted transactions and brings the database online. No further backups can be applied.
- **STANDBY**: Leaves the database in read-only mode. Uncommitted transactions are undone to an undo file, allowing read access. More backups can still be applied (the undo file is re-applied first). This is commonly used with log shipping to allow read access on the secondary.

---

## Tips

- **Always take a tail-log backup before starting a restore sequence.** This is the most commonly forgotten step and the most consequential.
- **Use `CHECKSUM` on all backups** (`WITH CHECKSUM`) and validate with `RESTORE VERIFYONLY ... WITH CHECKSUM`. This catches corruption in the backup file itself.
- **Automate backup integrity testing.** A backup you have never restored is a backup you cannot trust.
- **Monitor log backup jobs aggressively.** A silently failing log backup job for 48 hours means your 15-minute RPO is actually a 48-hour RPO.
- **Use `COPY_ONLY` backups for ad-hoc copies** so you never risk breaking the differential base or confusing the log chain.
- **Store backups on separate storage from the database.** Backups on the same drive as the database are not disaster recovery -- they are convenience recovery.
- **Document and drill your DR plan at least twice a year.** After each drill, update the runbook with lessons learned.
- **Know your actual RTO.** Restoring a 2 TB database over a 1 Gbps link takes approximately 4.5 hours. Do the math before making promises.
- **In interviews, always connect your answer to business impact.** DR is ultimately about protecting the business, not about technology choices.
