# Backup & Restore Strategies

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [Backup Types](#backup-types)
3. [Recovery Models and Their Impact](#recovery-models-and-their-impact)
4. [Backup Compression](#backup-compression)
5. [Backup Encryption](#backup-encryption)
6. [Backup to URL (Azure Blob Storage)](#backup-to-url-azure-blob-storage)
7. [Restore Sequence](#restore-sequence)
8. [RESTORE WITH NORECOVERY / RECOVERY / STANDBY](#restore-with-norecovery--recovery--standby)
9. [Piecemeal Restore](#piecemeal-restore)
10. [Page-Level Restore](#page-level-restore)
11. [Backup Verification](#backup-verification)
12. [Backup System Tables and DMVs](#backup-system-tables-and-dmvs)
13. [Backup Best Practices and Retention Policies](#backup-best-practices-and-retention-policies)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## Introduction

Backup and restore is the most fundamental data protection mechanism in SQL Server. Every data engineer and DBA must understand the different backup types, how recovery models affect backup behavior, and how to design a strategy that meets Recovery Point Objective (RPO) and Recovery Time Objective (RTO) requirements.

**Key definitions:**
- **RPO (Recovery Point Objective):** The maximum acceptable amount of data loss, measured in time. Example: "We can afford to lose at most 15 minutes of data."
- **RTO (Recovery Time Objective):** The maximum acceptable downtime. Example: "The database must be back online within 1 hour."

---

## Backup Types

### Full Backup

Backs up the entire database — all data pages and enough of the transaction log to make the backup internally consistent.

```sql
-- Full database backup
BACKUP DATABASE SalesDB
    TO DISK = 'D:\Backups\SalesDB_Full_20260307.bak'
    WITH INIT, COMPRESSION, CHECKSUM,
    NAME = 'SalesDB Full Backup',
    STATS = 10;
```

- **Does NOT truncate the transaction log.**
- **Does NOT break the log chain.**
- Foundation for all other backup types.
- Typically scheduled daily or weekly depending on database size and RPO.

### Differential Backup

Backs up all data pages that have changed since the last **full** backup (not the last differential).

```sql
-- Differential backup
BACKUP DATABASE SalesDB
    TO DISK = 'D:\Backups\SalesDB_Diff_20260307.bak'
    WITH DIFFERENTIAL, INIT, COMPRESSION, CHECKSUM,
    NAME = 'SalesDB Differential Backup',
    STATS = 10;
```

- **Cumulative** — each differential contains all changes since the last full.
- Only the most recent differential is needed for restore (not all differentials).
- Smaller and faster than a full backup (if changes are modest).
- Grows larger over time as more pages change; resets after the next full backup.

### Transaction Log Backup

Backs up the active portion of the transaction log and then truncates it (marks space for reuse).

```sql
-- Transaction log backup
BACKUP LOG SalesDB
    TO DISK = 'D:\Backups\SalesDB_Log_20260307_1200.trn'
    WITH INIT, COMPRESSION, CHECKSUM,
    NAME = 'SalesDB Log Backup',
    STATS = 10;
```

- **Only available in FULL or BULK_LOGGED recovery models.**
- Enables point-in-time recovery.
- Must be taken regularly to prevent the transaction log file from growing indefinitely.
- Maintains the **log chain** — an unbroken sequence of log backups required for point-in-time recovery.
- Typical frequency: every 5-30 minutes depending on RPO.

### Copy-Only Backup

A backup that does not interfere with the regular backup sequence.

```sql
-- Copy-only full backup
BACKUP DATABASE SalesDB
    TO DISK = 'D:\Backups\SalesDB_CopyOnly.bak'
    WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM;

-- Copy-only log backup
BACKUP LOG SalesDB
    TO DISK = 'D:\Backups\SalesDB_CopyOnly_Log.trn'
    WITH COPY_ONLY, INIT, COMPRESSION;
```

- Does **not** reset the differential base (full copy-only).
- Does **not** truncate the transaction log (log copy-only).
- Does **not** break the log chain.
- Ideal for ad-hoc backups (e.g., before a deployment, for dev/test refresh) without affecting the regular backup strategy.

### Tail-Log Backup

A special transaction log backup taken when preparing for a restore or failover. It captures any log records not yet backed up.

```sql
-- Tail-log backup (database may be damaged or offline)
BACKUP LOG SalesDB
    TO DISK = 'D:\Backups\SalesDB_TailLog.trn'
    WITH NORECOVERY, NO_TRUNCATE;
    -- NORECOVERY: takes the database offline (preparing for restore)
    -- NO_TRUNCATE: attempts to capture the log even if the database is damaged
```

- **Critical step before restoring a database** — without a tail-log backup, you lose all transactions since the last regular log backup.
- `NO_TRUNCATE` allows log backup even when the data files are inaccessible (as long as the log file is intact).
- `NORECOVERY` puts the database into a restoring state, preventing further changes.

### File and Filegroup Backup

Backs up individual files or filegroups rather than the entire database.

```sql
-- Backup a specific filegroup
BACKUP DATABASE SalesDB
    FILEGROUP = 'HistoricalData'
    TO DISK = 'D:\Backups\SalesDB_FG_Historical.bak'
    WITH INIT, COMPRESSION, CHECKSUM;

-- Backup a specific file
BACKUP DATABASE SalesDB
    FILE = 'SalesDB_Data2'
    TO DISK = 'D:\Backups\SalesDB_File2.bak'
    WITH INIT, COMPRESSION, CHECKSUM;
```

- Useful for very large databases (VLDB) where full backups take too long.
- Must still take transaction log backups to ensure consistency.
- Enables **piecemeal restore** — bringing critical filegroups online first.

### Summary of Backup Types

| Backup Type | What It Captures | Truncates Log | Breaks Log Chain | Recovery Model |
|---|---|---|---|---|
| Full | All data pages + log for consistency | No | No | Any |
| Differential | Pages changed since last full | No | No | Any |
| Transaction Log | Active log since last log backup | Yes | No | FULL / BULK_LOGGED |
| Copy-Only Full | All data pages (no sequence impact) | No | No | Any |
| Copy-Only Log | Active log (no sequence impact) | No | No | FULL / BULK_LOGGED |
| Tail-Log | Unbacked log (final log before restore) | Depends on options | No | FULL / BULK_LOGGED |
| File/Filegroup | Specific files or filegroups | No | No | Any |

---

## Recovery Models and Their Impact

The recovery model determines what backup operations are supported and how the transaction log behaves.

### Three Recovery Models

| Recovery Model | Log Truncation | Point-in-Time Recovery | Log Backups Required | Use Case |
|---|---|---|---|---|
| **SIMPLE** | Automatic (at checkpoint) | No | No (not supported) | Dev/test, read-only databases, databases where data loss is acceptable |
| **FULL** | Only after log backup | Yes | Yes (mandatory) | Production databases, any database requiring point-in-time recovery |
| **BULK_LOGGED** | Only after log backup | Limited (not through bulk operations) | Yes | Temporary use during large bulk operations for performance |

```sql
-- View current recovery model
SELECT name, recovery_model_desc
FROM sys.databases
WHERE name = 'SalesDB';

-- Change recovery model
ALTER DATABASE SalesDB SET RECOVERY FULL;
ALTER DATABASE SalesDB SET RECOVERY SIMPLE;
ALTER DATABASE SalesDB SET RECOVERY BULK_LOGGED;
```

### Critical Points

- **SIMPLE recovery model**: No transaction log backups are possible. The log is automatically truncated. Only full and differential backups are available. You can only restore to the time of the last backup — no point-in-time recovery.
- **FULL recovery model**: Transaction log backups are mandatory. If you never take log backups in FULL recovery, the log file will grow indefinitely until the disk is full.
- **BULK_LOGGED recovery model**: Minimally logs bulk operations (BULK INSERT, SELECT INTO, index rebuilds). Log backups are still required, but point-in-time recovery is not possible through intervals that contain minimally logged operations.

### A Common Mistake

Setting a database to FULL recovery model but never taking transaction log backups. This is one of the most common production issues — the log file grows until the disk fills up.

```sql
-- Check for databases in FULL recovery with no recent log backup
SELECT
    d.name AS DatabaseName,
    d.recovery_model_desc,
    MAX(b.backup_finish_date) AS LastLogBackup,
    DATEDIFF(HOUR, MAX(b.backup_finish_date), GETDATE()) AS HoursSinceLastLogBackup
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b
    ON d.name = b.database_name AND b.type = 'L'
WHERE d.recovery_model_desc = 'FULL'
    AND d.name NOT IN ('master', 'model', 'msdb')
    AND d.state_desc = 'ONLINE'
GROUP BY d.name, d.recovery_model_desc
HAVING MAX(b.backup_finish_date) IS NULL
    OR DATEDIFF(HOUR, MAX(b.backup_finish_date), GETDATE()) > 24;
```

---

## Backup Compression

Backup compression reduces the size of backup files, decreasing storage requirements and backup/restore time (since less data is written to disk).

```sql
-- Compressed backup (per-backup)
BACKUP DATABASE SalesDB
    TO DISK = 'D:\Backups\SalesDB_Compressed.bak'
    WITH COMPRESSION, INIT, CHECKSUM;

-- Enable compression as server default
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;

-- Check current setting
SELECT name, value_in_use
FROM sys.configurations
WHERE name = 'backup compression default';
```

### Compression Characteristics

| Aspect | Detail |
|---|---|
| **Typical ratio** | 3:1 to 7:1 depending on data type |
| **CPU impact** | Increases CPU usage during backup |
| **I/O impact** | Reduces I/O significantly |
| **Net effect** | Faster backups in most cases (I/O savings outweigh CPU cost) |
| **Edition** | All editions starting with SQL Server 2008 R2 (restore); backup compression in all editions starting with SQL 2008 Enterprise, all editions from SQL 2016 SP1+ |
| **Highly compressible** | Text, XML, repeated patterns |
| **Poorly compressible** | Already-encrypted data, compressed data, images |

---

## Backup Encryption

SQL Server supports native backup encryption starting with SQL Server 2014.

### Requirements

- A **Database Master Key** in the `master` database.
- A **certificate** or **asymmetric key** for encryption.
- The certificate/key must be backed up separately — if you lose it, the backup is unrecoverable.

```sql
-- Step 1: Create a master key (if not exists)
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'Str0ng_P@ssw0rd!';

-- Step 2: Create a certificate for backup encryption
CREATE CERTIFICATE BackupEncryptionCert
    WITH SUBJECT = 'Backup Encryption Certificate',
    EXPIRY_DATE = '2030-12-31';

-- Step 3: Back up the certificate (CRITICAL - store safely!)
BACKUP CERTIFICATE BackupEncryptionCert
    TO FILE = 'D:\Certs\BackupEncryptionCert.cer'
    WITH PRIVATE KEY (
        FILE = 'D:\Certs\BackupEncryptionCert.pvk',
        ENCRYPTION BY PASSWORD = 'Cert_P@ssw0rd!'
    );

-- Step 4: Create an encrypted backup
BACKUP DATABASE SalesDB
    TO DISK = 'D:\Backups\SalesDB_Encrypted.bak'
    WITH INIT, COMPRESSION, CHECKSUM,
    ENCRYPTION (
        ALGORITHM = AES_256,
        SERVER CERTIFICATE = BackupEncryptionCert
    );
```

### Supported Algorithms

- AES_128, AES_192, AES_256 (recommended)
- TRIPLE_DES_3KEY

### Restoring an Encrypted Backup on Another Server

```sql
-- On the destination server:
-- Step 1: Create a master key
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'Dest_P@ssw0rd!';

-- Step 2: Restore the certificate from the file backup
CREATE CERTIFICATE BackupEncryptionCert
    FROM FILE = 'D:\Certs\BackupEncryptionCert.cer'
    WITH PRIVATE KEY (
        FILE = 'D:\Certs\BackupEncryptionCert.pvk',
        DECRYPTION BY PASSWORD = 'Cert_P@ssw0rd!'
    );

-- Step 3: Restore the encrypted backup
RESTORE DATABASE SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Encrypted.bak'
    WITH RECOVERY;
```

---

## Backup to URL (Azure Blob Storage)

SQL Server supports backing up directly to Azure Blob Storage, eliminating the need for local or network disk targets.

### Using a SAS Token (Recommended)

```sql
-- Step 1: Create a credential using a Shared Access Signature (SAS)
CREATE CREDENTIAL [https://mystorageaccount.blob.core.windows.net/sqlbackups]
    WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
    SECRET = 'sv=2021-06-08&ss=b&srt=co&sp=rwdlac&se=2027-01-01&sig=...';

-- Step 2: Backup to URL
BACKUP DATABASE SalesDB
    TO URL = 'https://mystorageaccount.blob.core.windows.net/sqlbackups/SalesDB_Full_20260307.bak'
    WITH COMPRESSION, CHECKSUM, INIT,
    STATS = 10;

-- Step 3: Restore from URL
RESTORE DATABASE SalesDB
    FROM URL = 'https://mystorageaccount.blob.core.windows.net/sqlbackups/SalesDB_Full_20260307.bak'
    WITH RECOVERY;
```

### Striped Backup to Multiple URLs (Large Databases)

```sql
-- Stripe across multiple block blobs for larger databases
BACKUP DATABASE SalesDB
    TO URL = 'https://mystorageaccount.blob.core.windows.net/sqlbackups/SalesDB_1.bak',
       URL = 'https://mystorageaccount.blob.core.windows.net/sqlbackups/SalesDB_2.bak',
       URL = 'https://mystorageaccount.blob.core.windows.net/sqlbackups/SalesDB_3.bak'
    WITH COMPRESSION, CHECKSUM, INIT;
```

### Azure-Specific Considerations

| Consideration | Detail |
|---|---|
| **Max backup size (block blob)** | 200 GB per file (use striping for larger) |
| **Max backup size (page blob)** | 1 TB (legacy, SQL 2012/2014) |
| **Storage tier** | Use Hot or Cool tier; Archive tier is not directly accessible for restore |
| **Lifecycle management** | Configure Azure Blob lifecycle rules for automated retention |
| **Managed Backup** | SQL Server Managed Backup automates backup scheduling to Azure |

---

## Restore Sequence

Understanding the correct restore sequence is critical. A database restore must follow a specific order.

### Standard Restore Sequence

```
Full Backup → (Latest Differential) → Log Backups (in order) → Recovery
```

### Example: Full + Differential + Log Restores

```sql
-- Step 1: Restore the full backup (WITH NORECOVERY to continue restoring)
RESTORE DATABASE SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Full_Sunday.bak'
    WITH NORECOVERY, REPLACE,
    STATS = 10;

-- Step 2: Restore the latest differential (skips earlier differentials)
RESTORE DATABASE SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Diff_Wednesday.bak'
    WITH NORECOVERY,
    STATS = 10;

-- Step 3: Restore log backups in chronological order
RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log_Wed_1800.trn'
    WITH NORECOVERY;

RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log_Wed_1815.trn'
    WITH NORECOVERY;

RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log_Wed_1830.trn'
    WITH NORECOVERY;

-- Step 4: Point-in-time recovery (optional — stop at a specific time)
RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log_Wed_1845.trn'
    WITH STOPAT = '2026-03-07T18:42:00', RECOVERY;

-- OR simply bring online at the end of all logs:
-- RESTORE DATABASE SalesDB WITH RECOVERY;
```

### Key Rules

1. **Full backup is always the starting point.**
2. **Only the most recent differential is needed** (because differentials are cumulative from the last full).
3. **All log backups after the differential (or after the full if no differential) must be applied in order.**
4. **The log chain must be unbroken** — missing a single log backup breaks point-in-time recovery capability from that point forward.
5. **Use NORECOVERY on all steps except the final one** (or use RECOVERY on the final step).

---

## RESTORE WITH NORECOVERY / RECOVERY / STANDBY

These three options control the state of the database after each restore step.

| Option | Database State | Use Case |
|---|---|---|
| **NORECOVERY** | Restoring (inaccessible) | More backups to apply; used for log shipping, AG initialization |
| **RECOVERY** | Online (read-write) | Final step; no more backups to apply |
| **STANDBY** | Read-only | Want to read data between restores; used for log shipping secondaries |

```sql
-- NORECOVERY: database stays in "Restoring" state
RESTORE DATABASE SalesDB FROM DISK = 'backup.bak' WITH NORECOVERY;

-- RECOVERY: database comes online (default if not specified)
RESTORE DATABASE SalesDB WITH RECOVERY;

-- STANDBY: database is readable, can apply more logs later
RESTORE DATABASE SalesDB FROM DISK = 'backup.bak'
    WITH STANDBY = 'D:\Standby\SalesDB_Undo.ldf';
```

### STANDBY Details

- Creates an **undo file** that stores uncommitted transactions.
- The database is readable between restore operations.
- When the next log is restored, the undo file rolls back the uncommitted transactions first, then applies the new log.
- Users are disconnected during each restore operation.

---

## Piecemeal Restore

Piecemeal restore allows you to restore a database in stages — bringing the primary filegroup online first while restoring other filegroups in the background.

### When to Use

- Very large databases where restoring the entire database would take too long.
- Only the primary filegroup (or specific filegroups) are needed immediately.
- Historical/archive data in secondary filegroups can be restored later.

```sql
-- Step 1: Restore the primary filegroup first
RESTORE DATABASE SalesDB
    FILEGROUP = 'PRIMARY'
    FROM DISK = 'D:\Backups\SalesDB_Full.bak'
    WITH PARTIAL, NORECOVERY;

-- Step 2: Restore log backups to bring primary filegroup current
RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log1.trn'
    WITH NORECOVERY;

RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log2.trn'
    WITH RECOVERY;
-- The database is now ONLINE with the PRIMARY filegroup available.
-- Other filegroups show as RECOVERY_PENDING.

-- Step 3: Restore additional filegroups as needed
RESTORE DATABASE SalesDB
    FILEGROUP = 'HistoricalData'
    FROM DISK = 'D:\Backups\SalesDB_Full.bak'
    WITH NORECOVERY;

RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log1.trn'
    WITH NORECOVERY;

RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log2.trn'
    WITH RECOVERY;
```

### Requirements

- Enterprise Edition only.
- The PRIMARY filegroup must be restored first.
- The `PARTIAL` option indicates a piecemeal restore.
- Log backups must be applied to each filegroup to bring them to a consistent state.

---

## Page-Level Restore

SQL Server can restore individual corrupted pages without taking the entire database offline.

### When to Use

- A small number of pages are corrupted (reported by DBCC CHECKDB or backup checksum errors).
- You want to minimize downtime — restore just the affected pages rather than the entire database.

```sql
-- View suspected pages
SELECT * FROM msdb.dbo.suspect_pages;

-- Step 1: Restore the specific pages from the most recent full backup
RESTORE DATABASE SalesDB
    PAGE = '1:5678, 1:5679'  -- FileId:PageId
    FROM DISK = 'D:\Backups\SalesDB_Full.bak'
    WITH NORECOVERY;

-- Step 2: Apply differential backup (if available)
RESTORE DATABASE SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Diff.bak'
    WITH NORECOVERY;

-- Step 3: Apply all subsequent log backups
RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_Log1.trn'
    WITH NORECOVERY;

-- Step 4: Take a tail-log backup and restore it
BACKUP LOG SalesDB TO DISK = 'D:\Backups\SalesDB_TailLog.trn';
RESTORE LOG SalesDB
    FROM DISK = 'D:\Backups\SalesDB_TailLog.trn'
    WITH RECOVERY;

-- Step 5: Verify integrity
DBCC CHECKDB ('SalesDB') WITH NO_INFOMSGS;
```

### Key Points

- Enterprise Edition only (for online page restore).
- The database remains online during the restore — only the affected pages are inaccessible.
- Requires FULL recovery model (need log backups to bring pages current).
- Check `msdb.dbo.suspect_pages` to identify corrupted pages.

---

## Backup Verification

### RESTORE VERIFYONLY

Verifies the backup is readable and structurally valid, but does **not** restore data or verify that the data within is consistent.

```sql
-- Verify a backup is valid
RESTORE VERIFYONLY
    FROM DISK = 'D:\Backups\SalesDB_Full.bak'
    WITH CHECKSUM;
```

### RESTORE HEADERONLY, FILELISTONLY, LABELONLY

```sql
-- View backup set header information (backup type, date, size, etc.)
RESTORE HEADERONLY
    FROM DISK = 'D:\Backups\SalesDB_Full.bak';

-- View the list of database files in the backup
RESTORE FILELISTONLY
    FROM DISK = 'D:\Backups\SalesDB_Full.bak';

-- View media header information
RESTORE LABELONLY
    FROM DISK = 'D:\Backups\SalesDB_Full.bak';
```

### CHECKSUM During Backup

```sql
-- Create a backup with checksum verification
BACKUP DATABASE SalesDB
    TO DISK = 'D:\Backups\SalesDB_Full.bak'
    WITH CHECKSUM, INIT;
-- This writes a checksum into the backup and verifies page checksums during backup

-- RESTORE VERIFYONLY with CHECKSUM validates those checksums
RESTORE VERIFYONLY
    FROM DISK = 'D:\Backups\SalesDB_Full.bak'
    WITH CHECKSUM;
```

### The Gold Standard: Test Restore

The only true way to verify a backup is to **restore it** to a test server and run `DBCC CHECKDB`. RESTORE VERIFYONLY is not a substitute for actual restore testing.

```sql
-- Restore to a test server with a different name
RESTORE DATABASE SalesDB_Test
    FROM DISK = 'D:\Backups\SalesDB_Full.bak'
    WITH RECOVERY,
    MOVE 'SalesDB' TO 'D:\TestData\SalesDB_Test.mdf',
    MOVE 'SalesDB_Log' TO 'D:\TestData\SalesDB_Test_log.ldf';

-- Verify integrity
DBCC CHECKDB ('SalesDB_Test') WITH NO_INFOMSGS, ALL_ERRORMSGS;

-- Clean up
DROP DATABASE SalesDB_Test;
```

---

## Backup System Tables and DMVs

### Key Tables in msdb

```sql
-- Backup set information (one row per backup operation)
SELECT
    database_name,
    type AS BackupType,  -- D=Full, I=Differential, L=Log
    backup_start_date,
    backup_finish_date,
    backup_size / 1048576.0 AS BackupSizeMB,
    compressed_backup_size / 1048576.0 AS CompressedSizeMB,
    CAST(1.0 - (compressed_backup_size * 1.0 / backup_size) AS DECIMAL(5,2)) AS CompressionRatio,
    is_copy_only,
    recovery_model,
    first_lsn,
    last_lsn,
    checkpoint_lsn,
    database_backup_lsn
FROM msdb.dbo.backupset
WHERE database_name = 'SalesDB'
ORDER BY backup_start_date DESC;

-- Backup media (physical files)
SELECT
    bs.database_name,
    bmf.physical_device_name,
    bs.backup_start_date,
    bs.type
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bs.media_set_id = bmf.media_set_id
WHERE bs.database_name = 'SalesDB'
ORDER BY bs.backup_start_date DESC;

-- Find the most recent backup of each type for each database
SELECT
    database_name,
    type,
    MAX(backup_finish_date) AS LastBackup,
    DATEDIFF(HOUR, MAX(backup_finish_date), GETDATE()) AS HoursAgo
FROM msdb.dbo.backupset
GROUP BY database_name, type
ORDER BY database_name, type;
```

### Restore History

```sql
-- View restore operations
SELECT
    destination_database_name,
    restore_date,
    restore_type,  -- D=Full, I=Diff, L=Log
    user_name,
    backup_set_id
FROM msdb.dbo.restorehistory
ORDER BY restore_date DESC;
```

### Useful DMVs

```sql
-- Currently running backup/restore operations
SELECT
    session_id,
    command,
    percent_complete,
    DATEADD(MILLISECOND, estimated_completion_time, GETDATE()) AS EstimatedCompletion,
    total_elapsed_time / 1000 AS ElapsedSeconds,
    DB_NAME(database_id) AS DatabaseName
FROM sys.dm_exec_requests
WHERE command LIKE '%BACKUP%' OR command LIKE '%RESTORE%';

-- Database file sizes (to estimate backup size)
SELECT
    DB_NAME(database_id) AS DatabaseName,
    name AS FileName,
    type_desc,
    size * 8 / 1024 AS SizeMB,
    FILEPROPERTY(name, 'SpaceUsed') * 8 / 1024 AS UsedMB
FROM sys.master_files
WHERE database_id = DB_ID('SalesDB');
```

---

## Backup Best Practices and Retention Policies

### Backup Strategy Examples

#### Small Database (< 50 GB)

| Backup Type | Frequency | Retention |
|---|---|---|
| Full | Daily at 2:00 AM | 14 days |
| Differential | Every 6 hours | 7 days |
| Transaction Log | Every 15 minutes | 3 days |

#### Large Database (500 GB+)

| Backup Type | Frequency | Retention |
|---|---|---|
| Full | Weekly (Sunday 1:00 AM) | 30 days |
| Differential | Daily at 2:00 AM | 14 days |
| Transaction Log | Every 5-10 minutes | 7 days |

#### Very Large Database (5 TB+)

| Backup Type | Frequency | Retention |
|---|---|---|
| Full | Weekly or bi-weekly | 30-60 days |
| Differential | Daily | 14 days |
| Transaction Log | Every 5 minutes | 7 days |
| File/Filegroup | Rotating schedule across filegroups | 30 days |

### Retention Policy Script

```sql
-- Clean up old backup files using xp_delete_file
-- Parameters: file type (0=backup), folder, extension, cutoff date, subfolder recursion
DECLARE @CutoffDate DATETIME = DATEADD(DAY, -14, GETDATE());

EXEC master.dbo.xp_delete_file
    0,                           -- 0 = backup files
    N'D:\Backups\',              -- Folder path
    N'bak',                      -- File extension
    @CutoffDate,                 -- Delete files older than this
    1;                           -- 1 = include subfolders

-- Also clean up old log backup files
EXEC master.dbo.xp_delete_file
    0,
    N'D:\Backups\',
    N'trn',
    @CutoffDate,
    1;
```

### Best Practices Checklist

| Practice | Rationale |
|---|---|
| **Always use CHECKSUM** | Detects corruption during backup |
| **Always use COMPRESSION** | Reduces storage and backup time |
| **Store backups off-server** | Protects against server-level failure |
| **Follow the 3-2-1 rule** | 3 copies, 2 different media, 1 offsite |
| **Test restores regularly** | The only way to truly validate backups |
| **Monitor backup jobs** | Alert on failures immediately |
| **Document the restore process** | Under pressure, a clear runbook saves time |
| **Encrypt sensitive backups** | Especially backups sent offsite or to cloud |
| **Take tail-log backup before restore** | Prevents data loss |
| **Never rely solely on RESTORE VERIFYONLY** | It checks structure, not data integrity |
| **Monitor log backup frequency** | Prevent log file growth in FULL recovery model |
| **Use COPY_ONLY for ad-hoc backups** | Avoids disrupting the backup chain |

---

## Common Interview Questions

### Q1: What is the difference between a full backup and a differential backup?

**Answer:** A full backup captures all data pages in the database, providing a complete baseline. A differential backup captures only the data pages that have changed since the most recent full backup. Differentials are cumulative — each new differential includes all changes since the last full, not just changes since the last differential. During restore, you need the full backup plus only the most recent differential (not all differentials). Differentials are smaller and faster than full backups, making them ideal for reducing backup windows while maintaining a reasonable restore time.

---

### Q2: Explain the importance of the transaction log backup and the concept of a log chain.

**Answer:** Transaction log backups serve two purposes: they enable point-in-time recovery and they truncate the log (mark space for reuse). The log chain is the unbroken sequence of log backups from one full backup to the present. Each log backup's first LSN must match the last LSN of the previous log backup. If any log backup in the chain is missing or corrupted, point-in-time recovery is only possible up to the gap. Breaking the log chain (e.g., switching to SIMPLE recovery and back) means you must take a new full backup to start a new chain. This is why log backups should be taken frequently and retained according to your RPO.

---

### Q3: What is a tail-log backup and when would you use it?

**Answer:** A tail-log backup captures any transaction log records that have not yet been backed up — the "tail" of the log. You should take a tail-log backup before any restore operation on a database to prevent data loss. For example, if a database is damaged and you need to restore from backups, the tail-log backup (using `NO_TRUNCATE`) captures transactions that occurred after the last regular log backup. Without it, those transactions are lost. The `NORECOVERY` option can be combined to put the database into a restoring state, ready for the restore sequence.

---

### Q4: How do recovery models affect your backup strategy?

**Answer:** In **SIMPLE** recovery model, only full and differential backups are possible. There are no transaction log backups, so you can only recover to the time of the last backup — no point-in-time recovery. In **FULL** recovery model, you must take regular transaction log backups (otherwise the log grows indefinitely). You get point-in-time recovery. In **BULK_LOGGED** recovery model, bulk operations are minimally logged for performance, but you cannot do point-in-time recovery through intervals containing those operations. Most production databases should use FULL recovery model. SIMPLE is appropriate for dev/test or databases where data loss is acceptable.

---

### Q5: What is a copy-only backup, and why is it important?

**Answer:** A copy-only backup is a backup that does not affect the regular backup sequence. A copy-only full backup does not reset the differential base, meaning subsequent differential backups still reference the previous regular full backup. A copy-only log backup does not truncate the log or break the log chain. This is important for ad-hoc scenarios: refreshing a dev/test environment, creating a backup before a deployment, or providing a backup to another team — all without disrupting the production backup strategy.

---

### Q6: Describe a complete restore strategy for a database that suffered corruption at 2:30 PM, given daily full backups at 2 AM, differential every 6 hours, and log backups every 15 minutes.

**Answer:**
1. **Take a tail-log backup** — capture transactions from 2:15 PM (last log backup) to 2:30 PM: `BACKUP LOG SalesDB ... WITH NO_TRUNCATE, NORECOVERY`.
2. **Restore the full backup** from 2:00 AM today: `RESTORE DATABASE ... WITH NORECOVERY`.
3. **Skip the 8:00 AM differential** — instead, restore the latest differential which would be from around 2:00 PM (the most recent before corruption): `RESTORE DATABASE ... WITH NORECOVERY`.
4. **Restore log backups** from 2:00 PM, 2:15 PM in sequence: `RESTORE LOG ... WITH NORECOVERY`.
5. **Restore the tail-log backup** with `STOPAT = '2026-03-07T14:29:59'` to recover up to just before the corruption: `RESTORE LOG ... WITH STOPAT, RECOVERY`.
6. **Verify integrity**: `DBCC CHECKDB`.

This achieves point-in-time recovery with minimal data loss.

---

### Q7: What is piecemeal restore and when would you use it?

**Answer:** Piecemeal restore allows you to restore a database in stages, bringing the primary filegroup online first while other filegroups are restored later. This is used for very large databases where full restore time exceeds the RTO. For example, a 10 TB database might have 500 GB in the primary filegroup (current/active data) and 9.5 TB in a historical archive filegroup. With piecemeal restore, you can bring the primary filegroup online in minutes, allowing applications to resume, then restore the archive filegroup in the background. It requires Enterprise Edition and proper filegroup design.

---

### Q8: How would you design a backup strategy for a 2 TB mission-critical database with an RPO of 5 minutes and RTO of 1 hour?

**Answer:**
- **Full backup:** Weekly, using compression and striping across multiple files for faster backup/restore.
- **Differential backup:** Every 4-6 hours to minimize the number of log files needed during restore.
- **Transaction log backup:** Every 5 minutes (to meet the 5-minute RPO).
- **Storage:** Backup to local fast storage (SSD) and replicate to Azure Blob Storage (for offsite protection).
- **Restore time optimization:** Use striped backups (4 files) for parallel I/O during restore. Test restore regularly to ensure it completes within 1 hour. Consider piecemeal restore if the database uses multiple filegroups.
- **Monitoring:** Alert immediately on any backup failure. Monitor log backup latency.
- **Testing:** Monthly restore drills to validate RTO.
- **Additional HA:** Combine with Availability Groups for near-instant failover; backups serve as the last line of defense.

---

### Q9: What does RESTORE VERIFYONLY actually verify? What are its limitations?

**Answer:** RESTORE VERIFYONLY checks that the backup set is complete, all volumes are readable, header fields are valid, and (with CHECKSUM) the backup checksums are correct. However, it does **not** verify the structure of the data within the backup. It does not guarantee the backup can be successfully restored, nor does it check for logical data corruption. A backup can pass VERIFYONLY and still fail during actual restore. The only reliable way to verify a backup is to restore it to a test server and run DBCC CHECKDB.

---

### Q10: What is the 3-2-1 backup rule?

**Answer:** The 3-2-1 rule is a backup best practice:
- **3** copies of your data (the production database plus 2 backups).
- **2** different storage media (e.g., local disk and cloud storage, or disk and tape).
- **1** copy offsite (geographically separate from production, such as Azure Blob Storage or a remote datacenter).

This protects against various failure scenarios: hardware failure (multiple copies), site-level disaster (offsite copy), and media failure (different storage types).

---

## Tips

- **Always use CHECKSUM and COMPRESSION** on every backup — there is almost no reason not to in modern SQL Server.
- **The log chain is sacred** — never break it accidentally. Be careful with recovery model changes, and always take a full backup after switching to FULL recovery.
- **COPY_ONLY is your friend** — use it for any ad-hoc backup to avoid disrupting the production backup chain.
- **Test your restores** — an untested backup is not a backup. Schedule regular restore drills.
- **Monitor for databases in FULL recovery with no log backups** — this is the number one cause of log file growth incidents.
- **Encrypt backups going offsite** — especially cloud backups. And critically, back up the encryption certificate separately and store it securely.
- **Know your LSNs** — understanding first_lsn, last_lsn, checkpoint_lsn, and database_backup_lsn helps troubleshoot restore chain issues.
- **Use striped backups for large databases** — writing to multiple files in parallel significantly reduces backup and restore time.
- **Tail-log backup before every restore** — make this reflexive. Forgetting the tail-log backup is the most common cause of preventable data loss during restore operations.
- **Document and automate** — backup strategies should be documented, automated via SQL Server Agent or Ola Hallengren's maintenance solution, and monitored with alerts.
- **Consider Ola Hallengren's Maintenance Solution** — a widely-used, free, open-source backup and maintenance framework that handles backup, integrity checks, and index maintenance with best practices built in.

---

[Back to SQL Server Index](./README.md)
