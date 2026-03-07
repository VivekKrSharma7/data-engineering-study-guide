# Database Mirroring & Log Shipping

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [Database Mirroring Overview](#database-mirroring-overview)
3. [High-Safety vs High-Performance Mode](#high-safety-vs-high-performance-mode)
4. [Witness Server and Automatic Failover](#witness-server-and-automatic-failover)
5. [Setting Up Database Mirroring](#setting-up-database-mirroring)
6. [Database Mirroring Failover](#database-mirroring-failover)
7. [Log Shipping Overview](#log-shipping-overview)
8. [Log Shipping Architecture](#log-shipping-architecture)
9. [Setting Up Log Shipping](#setting-up-log-shipping)
10. [Log Shipping Delay Configuration](#log-shipping-delay-configuration)
11. [Log Shipping Switchover vs Failover](#log-shipping-switchover-vs-failover)
12. [Monitoring Log Shipping](#monitoring-log-shipping)
13. [Comparing Mirroring vs Log Shipping vs AG](#comparing-mirroring-vs-log-shipping-vs-ag)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## Introduction

Before Availability Groups became the standard HA/DR solution (SQL Server 2012+), **Database Mirroring** and **Log Shipping** were the primary database-level high availability and disaster recovery technologies. While both are considered legacy features, they are still encountered in production environments and are frequently asked about in interviews.

- **Database Mirroring** — deprecated since SQL Server 2012, but still functional. Provides real-time or near-real-time synchronization between two copies of a single database.
- **Log Shipping** — not deprecated and is still a valid, simple DR solution. Uses backup-copy-restore of transaction log backups to maintain one or more standby databases.

---

## Database Mirroring Overview

Database mirroring maintains two copies of a single database on two different SQL Server instances.

### Key Terminology

| Term | Description |
|---|---|
| **Principal** | The primary database that accepts read-write workloads |
| **Mirror** | The standby copy that receives transaction log records from the principal |
| **Witness** | Optional third instance that enables automatic failover (high-safety mode only) |
| **Endpoint** | A dedicated TCP endpoint on each instance used for mirroring communication |
| **Mirroring Session** | The active relationship between principal and mirror |

### How Mirroring Works

1. Every transaction that commits on the principal generates log records.
2. These log records are sent to the mirror server over the mirroring endpoint.
3. The mirror applies (redoes) the log records to keep its copy synchronized.
4. Depending on the mode, the principal either waits for acknowledgment from the mirror (synchronous) or does not (asynchronous).

### Requirements

- The database must be in **FULL recovery model**.
- Both instances must run the same SQL Server edition and compatible versions.
- A mirroring endpoint must be configured on each instance.
- The mirror database is initialized by restoring a full backup + log backup(s) of the principal database WITH NORECOVERY.

---

## High-Safety vs High-Performance Mode

### High-Safety Mode (Synchronous)

```
Principal ──── Log records ────> Mirror
Principal <──── Acknowledgment ── Mirror
(Transaction commits only after mirror confirms receipt)
```

- **SAFETY = FULL** (the default).
- The principal waits for the mirror to harden (write to disk) the log records before acknowledging the commit to the client.
- Guarantees **zero data loss** — no committed transaction can be lost.
- Introduces **latency** because each commit must round-trip to the mirror.
- Supports **automatic failover** when a witness is present.

### High-Performance Mode (Asynchronous)

```
Principal ──── Log records ────> Mirror
(Transaction commits immediately; does not wait for mirror)
```

- **SAFETY = OFF**.
- The principal commits transactions without waiting for the mirror.
- **No data loss guarantee** — transactions committed on the principal but not yet received by the mirror are lost during failover.
- Lower latency on the principal, better for high-throughput or long-distance scenarios.
- **No automatic failover** — only manual (forced) failover is possible.
- Enterprise Edition only.

### Comparison

| Feature | High-Safety (Synchronous) | High-Performance (Asynchronous) |
|---|---|---|
| Data loss | Zero | Possible |
| Commit latency | Higher (round-trip) | Lower (no wait) |
| Automatic failover | Yes (with witness) | No |
| Edition | Standard or Enterprise | Enterprise only |
| Best for | Local HA | Cross-datacenter DR |

---

## Witness Server and Automatic Failover

The **witness** is an optional SQL Server instance that acts as a quorum voter, enabling automatic failover in high-safety mode.

### How Automatic Failover Works

1. The principal, mirror, and witness form a quorum of three.
2. If the principal becomes unreachable, the mirror and witness must both agree (2 of 3 quorum).
3. The mirror automatically promotes itself to principal.
4. Client connections using the **failover partner** in the connection string can automatically redirect.

### Quorum Rules

| Scenario | Quorum | Result |
|---|---|---|
| Principal + Mirror + Witness online | 3/3 | Normal operation |
| Principal fails; Mirror + Witness online | 2/3 | Automatic failover |
| Mirror fails; Principal + Witness online | 2/3 | Principal continues; no mirroring |
| Witness fails; Principal + Mirror online | 2/3 | Mirroring continues; no auto-failover |
| Principal + Witness fail | 1/3 | Mirror does NOT auto-failover (no quorum) |

### Configuring the Failover Partner in Connection Strings

```csharp
// .NET connection string with failover partner
"Server=PrincipalServer;Database=MyDB;
 Failover Partner=MirrorServer;
 Integrated Security=True;"
```

> **Important:** The failover partner is cached by the client driver. On first connection, the driver learns the partner name from the server. This only works for the initial redirect — it is not as robust as an AG listener.

---

## Setting Up Database Mirroring

### Step 1: Create Endpoints on Both Instances

```sql
-- On the Principal instance
CREATE ENDPOINT MirroringEndpoint
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE = PARTNER);

-- On the Mirror instance
CREATE ENDPOINT MirroringEndpoint
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE = PARTNER);

-- On the Witness instance (if using automatic failover)
CREATE ENDPOINT MirroringEndpoint
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE = WITNESS);
```

### Step 2: Prepare the Mirror Database

```sql
-- On the Principal: back up the database and transaction log
BACKUP DATABASE SalesDB TO DISK = '\\Share\SalesDB_Full.bak' WITH INIT;
BACKUP LOG SalesDB TO DISK = '\\Share\SalesDB_Log.trn' WITH INIT;

-- On the Mirror: restore WITH NORECOVERY
RESTORE DATABASE SalesDB FROM DISK = '\\Share\SalesDB_Full.bak'
    WITH NORECOVERY, MOVE 'SalesDB' TO 'D:\Data\SalesDB.mdf',
    MOVE 'SalesDB_Log' TO 'E:\Logs\SalesDB_log.ldf';

RESTORE LOG SalesDB FROM DISK = '\\Share\SalesDB_Log.trn'
    WITH NORECOVERY;
```

### Step 3: Establish the Mirroring Session

```sql
-- On the Mirror: set the partner (point to the principal)
ALTER DATABASE SalesDB
    SET PARTNER = 'TCP://PrincipalServer.domain.com:5022';

-- On the Principal: set the partner (point to the mirror)
ALTER DATABASE SalesDB
    SET PARTNER = 'TCP://MirrorServer.domain.com:5022';

-- Optionally, set the witness for automatic failover
ALTER DATABASE SalesDB
    SET WITNESS = 'TCP://WitnessServer.domain.com:5022';
```

### Step 4: Verify the Session

```sql
-- Check mirroring status
SELECT
    DB_NAME(database_id) AS DatabaseName,
    mirroring_state_desc,
    mirroring_role_desc,
    mirroring_safety_level_desc,
    mirroring_partner_name,
    mirroring_witness_name,
    mirroring_partner_instance
FROM sys.database_mirroring
WHERE mirroring_guid IS NOT NULL;
```

---

## Database Mirroring Failover

### Types of Failover

| Type | Initiated By | Data Loss | Requirements |
|---|---|---|---|
| **Automatic** | Witness + Mirror agreement | None | High-safety mode + witness |
| **Manual** | DBA on principal | None | Both partners synchronized |
| **Forced (with possible data loss)** | DBA on mirror | Possible | Only when principal is unavailable |

### Manual Failover (No Data Loss)

```sql
-- Run on the current principal
-- Both partners must be synchronized
ALTER DATABASE SalesDB SET PARTNER FAILOVER;
```

### Forced Failover (Possible Data Loss)

```sql
-- Run on the mirror when the principal is unavailable
-- WARNING: may lose data
ALTER DATABASE SalesDB SET PARTNER FORCE_SERVICE_ALLOW_DATA_LOSS;
```

### After Forced Failover — Resynchronizing

After a forced failover, the old principal (when it comes back online) becomes the mirror in a SUSPENDED state. To resume:

```sql
-- On the new principal, resume the mirroring session
ALTER DATABASE SalesDB SET PARTNER RESUME;
```

If the databases are too far apart, you may need to break mirroring, re-prepare the mirror from a fresh backup, and re-establish the session.

---

## Log Shipping Overview

Log shipping is a straightforward disaster recovery solution that uses SQL Server Agent jobs to automate the backup, copy, and restore of transaction log backups from a primary database to one or more secondary databases.

### Key Characteristics

- Simple, reliable, and easy to understand.
- Uses standard backup/restore — no special endpoints or features.
- Secondary can be in **STANDBY** (read-only) or **NORECOVERY** (inaccessible) mode.
- Supports **multiple secondaries** from a single primary.
- Built-in delay capability — you can intentionally delay restores to protect against accidental data changes.
- Works across any SQL Server edition (including Standard and Express with limitations).
- The secondary is always behind the primary by at least the backup interval.

---

## Log Shipping Architecture

### Components

```
┌──────────────┐     Backup Job      ┌───────────────┐
│   Primary    │ ──────────────────> │  Backup Share  │
│   Server     │  (every 15 min)     │  (\\Share\LS)  │
└──────────────┘                     └───────┬───────┘
                                             │ Copy Job
                                             │ (every 15 min)
                                     ┌───────▼───────┐
                                     │  Secondary     │
                                     │  Local Folder  │
                                     └───────┬───────┘
                                             │ Restore Job
                                             │ (every 15 min)
                                     ┌───────▼───────┐
                                     │  Secondary     │
                                     │  Database      │
                                     └───────────────┘

┌──────────────┐
│   Monitor    │  (Optional) Tracks backup/copy/restore history
│   Server     │  Alerts if jobs fall behind threshold
└──────────────┘
```

### Three Jobs

| Job | Runs On | Purpose |
|---|---|---|
| **Backup Job** | Primary server | Backs up the transaction log to a network share |
| **Copy Job** | Secondary server | Copies the backup file from the share to a local directory |
| **Restore Job** | Secondary server | Restores the copied backup to the secondary database |

### Monitor Server

- An optional separate SQL Server instance that tracks log shipping status.
- Stores history in `msdb` system tables.
- Can raise alerts when backup, copy, or restore operations fall behind configurable thresholds.

---

## Setting Up Log Shipping

### Step 1: Ensure Prerequisites

```sql
-- The primary database MUST be in FULL or BULK_LOGGED recovery model
ALTER DATABASE SalesDB SET RECOVERY FULL;

-- Take a full backup of the primary database
BACKUP DATABASE SalesDB TO DISK = '\\Share\SalesDB_Full.bak' WITH INIT;
```

### Step 2: Configure via SSMS (Recommended) or T-SQL

Using T-SQL (for complete control):

```sql
-- On the Primary: enable log shipping and configure the backup job
EXEC master.dbo.sp_add_log_shipping_primary_database
    @database = N'SalesDB',
    @backup_directory = N'\\Share\LogShipping',
    @backup_share = N'\\Share\LogShipping',
    @backup_job_name = N'LS_Backup_SalesDB',
    @backup_retention_period = 4320,        -- 3 days in minutes
    @backup_threshold = 60,                  -- Alert if no backup in 60 min
    @threshold_alert_enabled = 1,
    @history_retention_period = 5760,        -- 4 days
    @backup_compression = 1;

-- On the Secondary: restore the full backup
RESTORE DATABASE SalesDB FROM DISK = '\\Share\SalesDB_Full.bak'
    WITH STANDBY = 'D:\Standby\SalesDB_Undo.ldf',  -- For read-only access
    MOVE 'SalesDB' TO 'D:\Data\SalesDB.mdf',
    MOVE 'SalesDB_Log' TO 'E:\Logs\SalesDB_log.ldf';

-- On the Secondary: configure the copy and restore jobs
EXEC master.dbo.sp_add_log_shipping_secondary_primary
    @primary_server = N'PrimaryServer',
    @primary_database = N'SalesDB',
    @backup_source_directory = N'\\Share\LogShipping',
    @backup_destination_directory = N'D:\LogShippingCopy',
    @copy_job_name = N'LS_Copy_SalesDB',
    @restore_job_name = N'LS_Restore_SalesDB',
    @file_retention_period = 4320;

EXEC master.dbo.sp_add_log_shipping_secondary_database
    @secondary_database = N'SalesDB',
    @primary_server = N'PrimaryServer',
    @primary_database = N'SalesDB',
    @restore_delay = 0,                     -- No intentional delay
    @restore_mode = 1,                      -- 1 = STANDBY, 0 = NORECOVERY
    @disconnect_users = 1,                  -- Disconnect users before restore
    @restore_threshold = 45,                -- Alert if restore behind 45 min
    @threshold_alert_enabled = 1;
```

### Step 3: Verify Log Shipping Status

```sql
-- Check log shipping status on the primary
SELECT * FROM msdb.dbo.log_shipping_monitor_primary;

-- Check log shipping status on the secondary
SELECT * FROM msdb.dbo.log_shipping_monitor_secondary;

-- Detailed history
SELECT
    primary_server,
    primary_database,
    last_backup_date,
    last_backup_file,
    last_copied_date,
    last_copied_file,
    last_restored_date,
    last_restored_file
FROM msdb.dbo.log_shipping_monitor_secondary;
```

---

## Log Shipping Delay Configuration

One of the most valuable features of log shipping is the ability to **intentionally delay restores**. This protects against accidental data modifications (e.g., someone runs `DELETE` without a `WHERE` clause).

### How Delay Works

```sql
-- Set a 2-hour delay on the secondary restore job
EXEC master.dbo.sp_change_log_shipping_secondary_database
    @secondary_database = N'SalesDB',
    @restore_delay = 120;  -- Delay in minutes
```

With a 2-hour delay:
- Transaction log backups are still copied to the secondary immediately.
- The restore job only applies backups that are at least 2 hours old.
- If a catastrophic user error occurs, you have a 2-hour window to recover from the secondary.

### Recovery with Delay

```sql
-- To recover data from the delayed secondary:
-- 1. Disable the restore job to stop further restores
-- 2. Optionally restore remaining log backups up to the point
--    just before the error
RESTORE LOG SalesDB FROM DISK = 'D:\LogShippingCopy\SalesDB_20260307_1200.trn'
    WITH STOPAT = '2026-03-07T11:55:00', RECOVERY;

-- 3. The secondary database is now online at the desired point in time
-- 4. Extract the needed data or use this as the new primary
```

---

## Log Shipping Switchover vs Failover

### Planned Switchover (No Data Loss)

A planned switchover is graceful — you bring the primary workload to a clean stop and promote the secondary.

```sql
-- Step 1: On the primary, set the database to read-only or stop application access

-- Step 2: On the primary, take a final tail-log backup
BACKUP LOG SalesDB TO DISK = '\\Share\LogShipping\SalesDB_Final.trn'
    WITH NORECOVERY;  -- This takes the primary offline

-- Step 3: Copy and restore the final log backup on the secondary
RESTORE LOG SalesDB FROM DISK = 'D:\LogShippingCopy\SalesDB_Final.trn'
    WITH RECOVERY;  -- Brings the secondary online as read-write

-- Step 4: Redirect applications to the new primary (formerly secondary)

-- Step 5: Optionally reconfigure log shipping in the reverse direction
```

### Unplanned Failover (Possible Data Loss)

When the primary is unavailable unexpectedly:

```sql
-- Step 1: Restore all copied log backups on the secondary
RESTORE LOG SalesDB FROM DISK = 'D:\LogShippingCopy\SalesDB_Latest.trn'
    WITH NORECOVERY;

-- Step 2: If you have access to the primary's log file (unlikely if
-- the server is down), take a tail-log backup and restore it.
-- Otherwise, proceed with possible data loss.

-- Step 3: Bring the secondary online
RESTORE DATABASE SalesDB WITH RECOVERY;

-- Data since the last restored log backup is LOST
```

---

## Monitoring Log Shipping

### System Tables and Views

```sql
-- Primary monitoring
SELECT
    primary_database,
    last_backup_date,
    last_backup_utc,
    backup_threshold,
    threshold_alert_enabled
FROM msdb.dbo.log_shipping_monitor_primary;

-- Secondary monitoring
SELECT
    secondary_database,
    last_copied_date,
    last_restored_date,
    last_restored_latency,  -- Minutes behind
    restore_threshold
FROM msdb.dbo.log_shipping_monitor_secondary;

-- Backup history detail
SELECT TOP 20
    database_name,
    backup_start_date,
    backup_finish_date,
    DATEDIFF(SECOND, backup_start_date, backup_finish_date) AS DurationSec,
    backup_size / 1048576.0 AS BackupSizeMB,
    compressed_backup_size / 1048576.0 AS CompressedMB
FROM msdb.dbo.backupset
WHERE database_name = 'SalesDB'
    AND type = 'L'  -- Log backups
ORDER BY backup_start_date DESC;
```

### Alert Configuration

```sql
-- SQL Server Agent alerts for log shipping
-- Alert 14420: Log shipping primary threshold exceeded
-- Alert 14421: Log shipping secondary threshold exceeded

EXEC msdb.dbo.sp_add_alert
    @name = N'Log Shipping - Backup Threshold',
    @message_id = 14420,
    @severity = 0,
    @enabled = 1,
    @delay_between_responses = 3600;

EXEC msdb.dbo.sp_add_alert
    @name = N'Log Shipping - Restore Threshold',
    @message_id = 14421,
    @severity = 0,
    @enabled = 1,
    @delay_between_responses = 3600;
```

### Custom Monitoring Query

```sql
-- Comprehensive log shipping health check
SELECT
    p.primary_database,
    s.secondary_server,
    s.secondary_database,
    p.last_backup_date AS PrimaryLastBackup,
    s.last_copied_date AS SecondaryLastCopy,
    s.last_restored_date AS SecondaryLastRestore,
    DATEDIFF(MINUTE, p.last_backup_date, GETDATE()) AS MinSinceBackup,
    DATEDIFF(MINUTE, s.last_restored_date, GETDATE()) AS MinSinceRestore,
    CASE
        WHEN DATEDIFF(MINUTE, s.last_restored_date, GETDATE()) > s.restore_threshold
        THEN 'ALERT: Behind threshold'
        ELSE 'OK'
    END AS RestoreStatus
FROM msdb.dbo.log_shipping_monitor_primary p
LEFT JOIN msdb.dbo.log_shipping_monitor_secondary s
    ON p.primary_database = s.primary_database;
```

---

## Comparing Mirroring vs Log Shipping vs AG

| Feature | Database Mirroring | Log Shipping | Availability Groups |
|---|---|---|---|
| **Status** | Deprecated (SQL 2012+) | Active, supported | Current standard |
| **Sync mode** | Sync or Async | Async only (backup-based) | Sync or Async |
| **Data loss possible** | No (sync) / Yes (async) | Yes (last backup interval) | No (sync) / Yes (async) |
| **Automatic failover** | Yes (with witness) | No | Yes (with WSFC) |
| **Readable secondary** | Via database snapshot | Yes (STANDBY mode) | Yes (native) |
| **Number of secondaries** | 1 mirror | Multiple | Up to 8 |
| **Databases per group** | 1 | 1 | Multiple (fail over together) |
| **System databases** | No | No | No |
| **Encryption in transit** | Yes (endpoint) | No (unless backup encryption) | Yes (endpoint) |
| **Network bandwidth** | Continuous stream | Periodic (backup size) | Continuous stream |
| **Complexity** | Moderate | Low | High |
| **Edition** | Standard (sync) / Enterprise (async) | All editions | Enterprise (full) / Standard (basic) |
| **Delay capability** | No | Yes (restore delay) | No (but can use log shipping alongside) |
| **Best use case** | Legacy systems not yet migrated to AG | Simple DR, delayed recovery, low budget | Primary HA/DR for modern environments |

---

## Common Interview Questions

### Q1: Why is database mirroring deprecated, and what replaced it?

**Answer:** Database mirroring was deprecated starting with SQL Server 2012 because Availability Groups provide a superset of its functionality. AGs support multiple databases in a single failover group, multiple secondary replicas (up to 8), readable secondaries without snapshots, and a listener for transparent client connectivity. Microsoft recommends migrating from database mirroring to AGs. However, mirroring still works in current SQL Server versions and is commonly encountered in legacy environments.

---

### Q2: What is the difference between a planned switchover and an unplanned failover in log shipping?

**Answer:** A planned switchover is graceful: you stop application traffic to the primary, take a final tail-log backup WITH NORECOVERY (which takes the primary offline), copy and restore this final backup on the secondary WITH RECOVERY, and redirect applications. This results in zero data loss. An unplanned failover occurs when the primary is unavailable. You restore all available copied log backups on the secondary and then bring it online WITH RECOVERY. Any transactions that occurred after the last available log backup are lost.

---

### Q3: How does the witness server enable automatic failover in database mirroring?

**Answer:** The witness acts as a third voting member, forming a quorum of three (principal, mirror, witness). If the principal becomes unreachable, the mirror and witness together constitute a 2-of-3 majority and can agree to fail over. Without the witness, the mirror cannot unilaterally decide that the principal has failed (it could be a network partition). The witness resolves this ambiguity. Automatic failover only works in high-safety (synchronous) mode because the mirror must have all committed transactions.

---

### Q4: When would you choose log shipping over Availability Groups?

**Answer:** Log shipping is preferred when:
1. **Simplicity is key** — log shipping is easy to set up, understand, and troubleshoot.
2. **Intentional delay is needed** — log shipping's restore delay feature provides a safety net against accidental data modifications (e.g., erroneous DELETEs).
3. **Budget constraints** — log shipping works on Standard and even Express editions without the Enterprise-only features of full AGs.
4. **Multiple secondaries with different delay periods** — you can have one secondary with zero delay and another with a 4-hour delay.
5. **Cross-version or cross-edition** — log shipping is more flexible with version/edition compatibility.
6. **No WSFC available** — log shipping does not require Windows Server Failover Clustering.

---

### Q5: Can you read from a log shipping secondary? What are the limitations?

**Answer:** Yes, if the secondary is in **STANDBY** mode (restored with the `STANDBY` option). In standby mode, the database is read-only between restores. However, when the restore job runs, it must disconnect all users from the secondary database to apply the next log backup. This means read access is periodically interrupted. If the secondary is in **NORECOVERY** mode, it is completely inaccessible. Applications using the standby secondary must handle periodic disconnections gracefully.

---

### Q6: Explain the high-safety and high-performance modes in database mirroring.

**Answer:** In **high-safety mode** (SAFETY = FULL, synchronous), the principal sends log records to the mirror and waits for the mirror to harden them to disk before acknowledging the commit to the client. This guarantees zero data loss but adds latency. In **high-performance mode** (SAFETY = OFF, asynchronous), the principal commits immediately without waiting for the mirror's acknowledgment. This reduces latency but means that transactions not yet received by the mirror can be lost during failover. High-safety mode supports automatic failover with a witness; high-performance mode only supports forced (manual) failover.

---

### Q7: How would you troubleshoot log shipping that has fallen behind?

**Answer:** Systematic troubleshooting approach:
1. **Check which job is failing** — is it the backup, copy, or restore job? Check SQL Server Agent job history on both servers.
2. **Backup job issues** — check disk space on the backup share, verify the primary database is in FULL recovery model, check for long-running transactions holding the log open.
3. **Copy job issues** — check network connectivity between secondary and the backup share, verify share permissions, check disk space on the secondary's local folder.
4. **Restore job issues** — check if users are connected to the standby database (blocking the restore), check for long-running read queries on standby, verify the log backup chain is intact.
5. **Monitor the lag** — query `msdb.dbo.log_shipping_monitor_secondary` to see `last_restored_latency`.
6. **Check thresholds** — ensure alert thresholds are appropriately configured.

---

### Q8: What happens to database mirroring if the witness goes down?

**Answer:** If only the witness goes down (principal and mirror are both online), mirroring continues to function normally — transactions are synchronized, and the database remains available. However, automatic failover is disabled because the mirror cannot form a quorum without the witness. If the principal subsequently fails while the witness is still down, the mirror will NOT automatically promote itself. A DBA would need to perform a forced failover manually. This is why monitoring witness health is important.

---

## Tips

- **Database mirroring is deprecated but still appears in interviews** — know it well enough to explain the modes, failover types, and why it was replaced by AG.
- **Log shipping is underrated** — its simplicity is a strength. For DR-only scenarios, it is often the most cost-effective solution.
- **Use restore delay as a safety net** — a 1-2 hour delay on a log shipping secondary can save you from disastrous accidental data modifications.
- **Monitor log shipping proactively** — the built-in alerting is basic. Supplement with custom monitoring queries and integration with your alerting platform.
- **Test failover procedures regularly** — both log shipping switchover and mirroring failover should be documented and practiced.
- **Know the migration path** — be prepared to discuss how you would migrate from mirroring or log shipping to Availability Groups.
- **Log shipping works alongside AG** — you can use log shipping to feed a delayed secondary even when your primary HA is AG-based.
- **Connection strings matter for mirroring** — the `Failover Partner` parameter is essential for automatic client redirect, but it is not as robust as an AG listener.
- **Back up the tail log during switchover** — forgetting the tail-log backup during a planned log shipping switchover is a common mistake that leads to data loss.
- **STANDBY vs NORECOVERY** — choose STANDBY if reporting on the secondary is needed; choose NORECOVERY if you want the secondary ready for AG or mirroring later.

---

[Back to SQL Server Index](./README.md)
