# Database Maintenance Plans & Index Maintenance

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Index Fragmentation](#index-fragmentation)
2. [REORGANIZE vs REBUILD](#reorganize-vs-rebuild)
3. [Online vs Offline Rebuilds](#online-vs-offline-rebuilds)
4. [Fill Factor Tuning](#fill-factor-tuning)
5. [Statistics Update Strategies](#statistics-update-strategies)
6. [Integrity Checks (DBCC CHECKDB)](#integrity-checks-dbcc-checkdb)
7. [Maintenance Plan Wizard vs Custom Scripts](#maintenance-plan-wizard-vs-custom-scripts)
8. [Ola Hallengren Maintenance Solution](#ola-hallengren-maintenance-solution)
9. [Database Shrink and Auto-Shrink](#database-shrink-and-auto-shrink)
10. [Maintenance Windows Planning](#maintenance-windows-planning)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## Index Fragmentation

Index fragmentation is the primary driver of index maintenance. Understanding its types and causes is fundamental.

### What Is Fragmentation?

Fragmentation occurs when the logical order of pages in an index does not match the physical order on disk, or when pages have excessive free space. It degrades performance by causing additional I/O operations during scans and range queries.

### Two Types of Fragmentation

| Type | Also Called | Description | Impact |
|------|------------|-------------|--------|
| **External (Logical) Fragmentation** | Extent-level fragmentation | Index pages are not in contiguous order on disk. The logical next page is not the physical next page. | Degrades sequential I/O and read-ahead operations. Range scans suffer most. |
| **Internal Fragmentation** | Page-level fragmentation | Pages have excessive free space due to deletes, updates, or page splits. | Wastes memory (buffer pool) and disk space. More pages must be read for the same data. |

### Detecting Fragmentation

```sql
-- Check fragmentation for all indexes in a database
SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) AS schema_name,
    OBJECT_NAME(ips.object_id) AS table_name,
    i.name AS index_name,
    i.type_desc AS index_type,
    ips.index_type_desc,
    ips.avg_fragmentation_in_percent,     -- External fragmentation
    ips.avg_page_space_used_in_percent,   -- Inverse of internal fragmentation
    ips.page_count,
    ips.fragment_count,
    ips.avg_fragment_size_in_pages
FROM sys.dm_db_index_physical_stats(
    DB_ID(),    -- Current database
    NULL,       -- All tables
    NULL,       -- All indexes
    NULL,       -- All partitions
    'LIMITED'   -- Sampling mode: LIMITED, SAMPLED, or DETAILED
) ips
INNER JOIN sys.indexes i
    ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.page_count > 1000           -- Only indexes with meaningful size
    AND ips.avg_fragmentation_in_percent > 5
ORDER BY ips.avg_fragmentation_in_percent DESC;
```

### Scanning Modes

| Mode | Speed | Accuracy | Use When |
|------|-------|----------|----------|
| `LIMITED` | Fast | Reads only non-leaf level pages. No `avg_page_space_used_in_percent`. | Routine checks; assessing external fragmentation |
| `SAMPLED` | Medium | Samples 1% of pages (or all pages if < 10,000 pages) | Balancing speed and accuracy |
| `DETAILED` | Slow | Reads all pages | Need full accuracy, including internal fragmentation metrics |

### Common Causes of Fragmentation

- **INSERT** operations on non-sequential keys (e.g., GUIDs as clustering keys) cause page splits.
- **UPDATE** operations that increase row size force rows to move, leaving gaps.
- **DELETE** operations leave empty space on pages.
- **Page splits**: When a page is full and a new row must be inserted in the middle, SQL Server splits the page in half, creating two half-full pages and breaking physical order.

---

## REORGANIZE vs REBUILD

These are the two primary index maintenance operations. Choosing between them depends on the level of fragmentation and operational constraints.

### ALTER INDEX REORGANIZE

```sql
-- Reorganize a specific index
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders REORGANIZE;

-- Reorganize all indexes on a table
ALTER INDEX ALL ON dbo.Orders REORGANIZE;
```

**Characteristics:**
- **Online operation** -- always. Does not block concurrent queries.
- **Minimal logging** -- uses minimal transaction log space.
- **Defragments leaf-level pages** only by physically reordering them.
- **Compacts pages** by removing gaps from deleted rows.
- **Interruptible** -- can be stopped at any time without losing work already done.
- **Does NOT update statistics.**
- **Less resource-intensive** but slower for heavily fragmented indexes.

### ALTER INDEX REBUILD

```sql
-- Rebuild a specific index (offline, default)
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders REBUILD;

-- Rebuild all indexes on a table
ALTER INDEX ALL ON dbo.Orders REBUILD;

-- Rebuild with options
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders
REBUILD WITH (
    ONLINE = ON,
    SORT_IN_TEMPDB = ON,
    FILLFACTOR = 90,
    MAXDOP = 4,
    DATA_COMPRESSION = PAGE
);
```

**Characteristics:**
- **Drops and recreates** the index entirely.
- Can be **online or offline** (see next section).
- **Fully logged** in full recovery model (generates significant log activity).
- **Updates statistics** automatically with a full scan (equivalent to `UPDATE STATISTICS ... WITH FULLSCAN`).
- **Cannot be stopped midway** without rolling back (unless using resumable rebuild).
- **More resource-intensive** but most effective for heavy fragmentation.

### Decision Matrix

| Fragmentation Level | Recommended Action | Rationale |
|---------------------|--------------------|-----------|
| < 5% | Do nothing | Overhead of maintenance outweighs benefit |
| 5% - 30% | REORGANIZE | Light fragmentation; online, interruptible, low impact |
| > 30% | REBUILD | Heavy fragmentation; rebuild is more efficient at this level |
| Index with < 1,000 pages | Do nothing | Small indexes gain little from defragmentation |

### Automated Index Maintenance Script

```sql
DECLARE @SchemaName NVARCHAR(128), @TableName NVARCHAR(128),
        @IndexName NVARCHAR(128), @Fragmentation FLOAT, @SQL NVARCHAR(MAX);

DECLARE index_cursor CURSOR FOR
SELECT
    OBJECT_SCHEMA_NAME(ips.object_id),
    OBJECT_NAME(ips.object_id),
    i.name,
    ips.avg_fragmentation_in_percent
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.page_count > 1000
    AND ips.avg_fragmentation_in_percent > 5
    AND i.name IS NOT NULL;

OPEN index_cursor;
FETCH NEXT FROM index_cursor INTO @SchemaName, @TableName, @IndexName, @Fragmentation;

WHILE @@FETCH_STATUS = 0
BEGIN
    IF @Fragmentation > 30
        SET @SQL = N'ALTER INDEX ' + QUOTENAME(@IndexName) + N' ON '
                 + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName)
                 + N' REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON);';
    ELSE
        SET @SQL = N'ALTER INDEX ' + QUOTENAME(@IndexName) + N' ON '
                 + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName)
                 + N' REORGANIZE;';

    PRINT @SQL;
    EXEC sp_executesql @SQL;

    FETCH NEXT FROM index_cursor INTO @SchemaName, @TableName, @IndexName, @Fragmentation;
END

CLOSE index_cursor;
DEALLOCATE index_cursor;
```

---

## Online vs Offline Rebuilds

### Offline Rebuild (Default)

```sql
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders REBUILD;
-- Acquires a Schema Modification (Sch-M) lock for the entire duration
```

- **Blocks all queries** against the table for the duration of the rebuild.
- **Faster** than online because there is no need to maintain two versions of the index.
- **Less resource usage** -- no need for a "mapping table" or version store.
- **Available in all editions** of SQL Server.

### Online Rebuild

```sql
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders
REBUILD WITH (ONLINE = ON);
```

- Table remains **fully accessible** during the rebuild.
- Builds a new copy of the index while the old one serves queries.
- **Schema Modification (Sch-M) lock** is only held briefly at the start and end of the operation.
- **Requires more resources** (tempdb space, CPU, memory).
- **Enterprise Edition only** (or Developer Edition).
- Some limitations: cannot online-rebuild indexes containing LOB columns (pre-SQL Server 2012), or disabled indexes.

### Resumable Index Rebuild (SQL Server 2017+)

```sql
-- Start a resumable rebuild
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders
REBUILD WITH (ONLINE = ON, RESUMABLE = ON, MAX_DURATION = 60);
-- MAX_DURATION in minutes; pauses automatically when exceeded

-- Check status
SELECT * FROM sys.index_resumable_operations;

-- Resume after pause
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders RESUME;

-- Abort a resumable rebuild
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders ABORT;
```

**Benefits of resumable rebuilds:**
- Can be **paused and resumed** across maintenance windows.
- If the server crashes mid-rebuild, work is not lost -- resume from where it stopped.
- Reduces log space requirements because completed work is committed in batches.

### Wait-at-Low-Priority (SQL Server 2014+)

```sql
ALTER INDEX IX_Orders_CustomerID ON dbo.Orders
REBUILD WITH (
    ONLINE = ON,
    WAIT_AT_LOW_PRIORITY (
        MAX_DURATION = 10 MINUTES,
        ABORT_AFTER_WAIT = SELF  -- NONE, SELF, or BLOCKERS
    )
);
```

This reduces blocking at the brief moments when an online rebuild needs the Sch-M lock:
- `NONE`: Keep waiting at low priority.
- `SELF`: Abort the rebuild if the lock cannot be acquired.
- `BLOCKERS`: Kill the blocking sessions (use with extreme caution).

---

## Fill Factor Tuning

**Fill factor** determines what percentage of each leaf-level page is filled with data during an index rebuild. The remaining space is reserved for future inserts and updates, reducing page splits.

### How It Works

| Fill Factor | Behavior |
|-------------|----------|
| 100 (or 0, the default) | Pages are filled completely. No free space reserved. |
| 90 | Pages are filled to 90%; 10% free space per page. |
| 70 | Pages are filled to 70%; 30% free space per page. |

### Setting Fill Factor

```sql
-- Set fill factor during index creation
CREATE NONCLUSTERED INDEX IX_Orders_OrderDate
ON dbo.Orders (OrderDate)
WITH (FILLFACTOR = 90);

-- Change fill factor during rebuild
ALTER INDEX IX_Orders_OrderDate ON dbo.Orders
REBUILD WITH (FILLFACTOR = 85);

-- Set server-wide default fill factor (applies to all new index operations
-- that don't specify an explicit fill factor)
EXEC sp_configure 'fill factor (%)', 90;
RECONFIGURE;
```

### Fill Factor Guidelines

| Scenario | Recommended Fill Factor |
|----------|------------------------|
| Read-only or read-heavy table, sequential inserts | 100 (default) |
| Table with moderate updates/random inserts | 85-95 |
| Table with heavy random inserts (e.g., GUID clustering key) | 70-85 |
| Heap (no clustered index) | N/A -- fill factor applies only to indexes |

### Important Notes

- Fill factor is applied **only during a rebuild** (or index creation). It is NOT maintained automatically during normal INSERT operations.
- After a REORGANIZE, the fill factor setting has no effect -- REORGANIZE compacts pages to fill them as much as possible.
- Lower fill factor = more pages = larger index = more memory in buffer pool. It is a trade-off between read performance and page-split reduction.
- Monitor page splits using the `page_split_for_internal_fragmentation` counter from `sys.dm_db_index_operational_stats` to determine if your fill factor is appropriate.

```sql
-- Check page splits per index
SELECT
    OBJECT_NAME(ios.object_id) AS table_name,
    i.name AS index_name,
    ios.leaf_allocation_count AS page_splits,
    ios.nonleaf_allocation_count AS nonleaf_page_splits
FROM sys.dm_db_index_operational_stats(DB_ID(), NULL, NULL, NULL) ios
INNER JOIN sys.indexes i ON ios.object_id = i.object_id AND ios.index_id = i.index_id
WHERE ios.leaf_allocation_count > 0
ORDER BY ios.leaf_allocation_count DESC;
```

---

## Statistics Update Strategies

Statistics are metadata objects that describe the distribution of data values in columns. The query optimizer relies heavily on statistics to generate efficient execution plans.

### Auto-Update Statistics

SQL Server automatically updates statistics when:
- A sufficient number of rows have changed (the threshold varies by SQL Server version).
- **Pre-2016 threshold**: 20% of rows + 500 rows.
- **2016+ with Trace Flag 2371 or database compatibility level 130+**: Dynamic threshold that decreases as the table grows (e.g., for a 1-million-row table, approximately `SQRT(1000 * table_rows)` changes trigger an update).

```sql
-- Check current auto-update settings
SELECT
    name,
    is_auto_update_stats_on,
    is_auto_update_stats_async_on,
    is_auto_create_stats_on
FROM sys.databases
WHERE name = DB_NAME();
```

### Manual Statistics Update

```sql
-- Update all statistics on a table with full scan
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;

-- Update a specific statistics object
UPDATE STATISTICS dbo.Orders IX_Orders_CustomerID WITH FULLSCAN;

-- Update all statistics in the database
EXEC sp_updatestats;  -- Uses the default sample rate

-- Update with a specific sample percentage
UPDATE STATISTICS dbo.Orders WITH SAMPLE 50 PERCENT;
```

### Update Strategies for Data Engineers

| Strategy | When to Use |
|----------|-------------|
| **Rely on auto-update** | Small to medium tables with gradual changes |
| **Post-ETL full scan update** | After bulk loads that significantly change data distribution |
| **Scheduled nightly update** | Large OLTP databases where auto-update may use inadequate sampling |
| **Asynchronous auto-update** | OLTP systems where you cannot afford the latency of synchronous statistics updates during queries |

### Post-ETL Statistics Update Pattern

```sql
-- After a large data load, update statistics on affected tables
-- with FULLSCAN for the best optimizer accuracy
UPDATE STATISTICS dbo.FactSales WITH FULLSCAN, NORECOMPUTE;
UPDATE STATISTICS dbo.FactInventory WITH FULLSCAN, NORECOMPUTE;
-- NORECOMPUTE prevents auto-update from overwriting with a sampled update
-- before the next scheduled full-scan update
```

### Asynchronous Statistics Update

```sql
-- Enable asynchronous auto-update
ALTER DATABASE [SalesDB] SET AUTO_UPDATE_STATISTICS_ASYNC ON;
```

When enabled, queries that trigger a statistics update will **not wait** for the update to complete. They use the stale statistics for the current compilation. The update happens in the background. This reduces query latency but may result in suboptimal plans until the update completes.

---

## Integrity Checks (DBCC CHECKDB)

DBCC CHECKDB is the most important database integrity command. It verifies the logical and physical consistency of all objects in a database.

### What DBCC CHECKDB Verifies

1. **DBCC CHECKALLOC**: Consistency of disk space allocation structures.
2. **DBCC CHECKTABLE**: Structural integrity of every table and indexed view.
3. **DBCC CHECKCATALOG**: Consistency of system catalog metadata.

### Running DBCC CHECKDB

```sql
-- Full integrity check
DBCC CHECKDB ('SalesDB') WITH NO_INFOMSGS;

-- Check without locking (uses an internal database snapshot)
DBCC CHECKDB ('SalesDB') WITH NO_INFOMSGS, TABLOCK;

-- Physical-only check (faster, skips logical checks)
DBCC CHECKDB ('SalesDB') WITH PHYSICAL_ONLY;

-- Check a single table
DBCC CHECKTABLE ('dbo.Orders') WITH NO_INFOMSGS;
```

### PHYSICAL_ONLY vs Full Check

| Check Type | Duration | What It Finds |
|-----------|----------|---------------|
| Full CHECKDB | Long (scans every page and verifies logical structures) | Page integrity, allocation errors, metadata consistency, computed column validation, Service Broker validation |
| PHYSICAL_ONLY | Shorter (reads pages, checks checksums/torn pages) | Corrupt pages, torn writes, hardware-related corruption |

### Scheduling Strategy

For large databases where a full CHECKDB takes too long for a single maintenance window:

```sql
-- Week 1: Full CHECKDB on Sunday
DBCC CHECKDB ('SalesDB') WITH NO_INFOMSGS;

-- Weeks 2-4: PHYSICAL_ONLY on Sunday (much faster)
DBCC CHECKDB ('SalesDB') WITH PHYSICAL_ONLY, NO_INFOMSGS;

-- Daily: Check one table per day (rotate through all tables)
DBCC CHECKTABLE ('dbo.Orders') WITH NO_INFOMSGS;
```

### Handling Corruption

```sql
-- If corruption is found, attempt repair (LAST RESORT -- may lose data)
ALTER DATABASE [SalesDB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DBCC CHECKDB ('SalesDB', REPAIR_ALLOW_DATA_LOSS);
ALTER DATABASE [SalesDB] SET MULTI_USER;

-- REPAIR_ALLOW_DATA_LOSS is the nuclear option
-- Always prefer restoring from a known-good backup
```

### Key Rule

> **DBCC CHECKDB should run regularly on every production database.** If you do not check for corruption, you will not know it exists until data is lost or queries return wrong results. The recommended frequency is at least weekly for a full check.

---

## Maintenance Plan Wizard vs Custom Scripts

### Maintenance Plan Wizard (GUI-Based)

The Maintenance Plan Wizard in SSMS provides a point-and-click interface to create common maintenance tasks:

- Back Up Database
- Check Database Integrity
- Reorganize Index
- Rebuild Index
- Update Statistics
- Clean Up History
- Shrink Database
- Execute SQL Server Agent Job
- Maintenance Cleanup Task

**Pros:**
- Easy to set up for DBAs unfamiliar with T-SQL scripting.
- Visual drag-and-drop workflow designer.
- Built-in logging to msdb.

**Cons:**
- **Limited control** -- cannot implement conditional logic (e.g., rebuild only if fragmentation > 30%).
- Rebuilds or reorganizes ALL indexes regardless of fragmentation level.
- No built-in support for online rebuilds or fill factor per index.
- Difficult to version-control (stored as SSIS packages in msdb).
- Performance: often does unnecessary work.

### Custom T-SQL Scripts

Custom scripts provide full flexibility and are the approach recommended by most senior DBAs and Data Engineers.

**Pros:**
- Conditional logic based on fragmentation levels, page counts, and other metrics.
- Per-index settings for online rebuild, fill factor, and compression.
- Easy to version-control in source control.
- Can log detailed execution information to custom tables.
- Integrates with any monitoring/alerting system.

**Cons:**
- Requires T-SQL knowledge to write and maintain.
- Must handle error cases explicitly.

### Recommendation

For production environments, **always use custom scripts or the Ola Hallengren solution** (see next section). The maintenance plan wizard is acceptable only for simple environments or learning purposes.

---

## Ola Hallengren Maintenance Solution

The [Ola Hallengren SQL Server Maintenance Solution](https://ola.hallengren.com) is a widely adopted, free, open-source set of stored procedures and SQL Agent jobs for database maintenance. It is considered the industry standard for SQL Server maintenance.

### Components

| Procedure | Purpose |
|-----------|---------|
| `dbo.IndexOptimize` | Index rebuild/reorganize based on fragmentation thresholds |
| `dbo.DatabaseBackup` | Full, differential, and transaction log backups |
| `dbo.DatabaseIntegrityCheck` | DBCC CHECKDB and related checks |
| `dbo.CommandLog` | Logging table that records every action taken |
| `dbo.CommandExecute` | Helper procedure for executing and logging commands |

### IndexOptimize Example

```sql
-- Smart index maintenance: reorganize at 5-30%, rebuild above 30%
-- Online rebuild for Enterprise Edition, skip tiny indexes
EXECUTE dbo.IndexOptimize
    @Databases = 'USER_DATABASES',
    @FragmentationLow = NULL,                    -- Do nothing below 5%
    @FragmentationMedium = 'INDEX_REORGANIZE',   -- Reorganize 5-30%
    @FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',  -- Try online first
    @FragmentationLevel1 = 5,
    @FragmentationLevel2 = 30,
    @MinNumberOfPages = 1000,
    @UpdateStatistics = 'ALL',
    @OnlyModifiedStatistics = 'Y',
    @SortInTempdb = 'Y',
    @MaxDOP = 4,
    @LogToTable = 'Y';
```

### DatabaseIntegrityCheck Example

```sql
-- Full integrity check on all user databases
EXECUTE dbo.DatabaseIntegrityCheck
    @Databases = 'USER_DATABASES',
    @CheckCommands = 'CHECKDB',
    @LogToTable = 'Y';

-- Physical-only check (faster, for mid-week runs)
EXECUTE dbo.DatabaseIntegrityCheck
    @Databases = 'USER_DATABASES',
    @CheckCommands = 'CHECKDB',
    @PhysicalOnly = 'Y',
    @LogToTable = 'Y';
```

### Reviewing the Command Log

```sql
-- Review recent maintenance actions
SELECT
    DatabaseName,
    ObjectName,
    IndexName,
    CommandType,
    Command,
    StartTime,
    EndTime,
    DATEDIFF(SECOND, StartTime, EndTime) AS DurationSeconds,
    ErrorNumber,
    ErrorMessage
FROM dbo.CommandLog
WHERE StartTime >= DATEADD(DAY, -1, GETDATE())
ORDER BY StartTime DESC;
```

### Why Ola Hallengren Is Preferred

1. **Intelligent**: Only acts on indexes that need maintenance based on actual fragmentation.
2. **Configurable**: Dozens of parameters for fine-grained control.
3. **Logged**: Every command is logged to a table for auditing and troubleshooting.
4. **Battle-tested**: Used by thousands of organizations worldwide.
5. **Free and open-source**: No licensing cost.
6. **Actively maintained**: Regular updates for new SQL Server versions.

---

## Database Shrink and Auto-Shrink

### Why Shrinking Is Almost Always Wrong

```sql
-- The command you should almost never run:
DBCC SHRINKDATABASE ('SalesDB', 10);  -- Shrink to 10% free space

DBCC SHRINKFILE ('SalesDB_Data', 50000);  -- Shrink data file to 50 GB
```

### What Happens During a Shrink

1. SQL Server moves pages from the **end** of the file to the **beginning** to free space at the end.
2. This movement **massively fragments every index** in the database.
3. After shrinking, you typically need to rebuild all indexes, which **grows the file back to near its original size**.
4. The net result: hours of I/O, CPU usage, transaction log activity, and you end up roughly where you started -- but with degraded performance until you rebuild.

### The Shrink-Rebuild Anti-Pattern

```
File is 100 GB (60 GB data, 40 GB free)
    |
    v  DBCC SHRINKDATABASE
File is 66 GB (60 GB data, 6 GB free) -- All indexes now severely fragmented
    |
    v  ALTER INDEX ALL ... REBUILD
File is 95 GB (60 GB data, 35 GB free) -- Back to nearly original size
```

### When Shrinking Is Acceptable

- After a **one-time large delete** operation that permanently reduced the data volume (e.g., archiving old data that will never come back).
- After **dropping a large table** that will not be recreated.
- Even then, shrink incrementally and rebuild indexes afterward.

### Auto-Shrink: A Configuration That Should Always Be OFF

```sql
-- Check if auto-shrink is enabled
SELECT name, is_auto_shrink_on FROM sys.databases;

-- Disable auto-shrink (do this on every database)
ALTER DATABASE [SalesDB] SET AUTO_SHRINK OFF;
```

**Why auto-shrink is dangerous:**
- Runs periodically in the background without warning.
- Causes massive fragmentation.
- Generates heavy I/O and log activity unpredictably.
- File grows back due to normal activity, then auto-shrink fires again -- an endless destructive cycle.
- Microsoft themselves recommend leaving it OFF.

---

## Maintenance Windows Planning

A well-designed maintenance window ensures all critical tasks complete without impacting production workloads.

### Typical Maintenance Task Priority

| Priority | Task | Frequency | Typical Duration |
|----------|------|-----------|-----------------|
| 1 (Critical) | DBCC CHECKDB | Weekly (full), daily (physical_only) | Minutes to hours depending on DB size |
| 2 (High) | Backup (Full/Diff/Log) | Full: weekly, Diff: daily, Log: every 15 min | Varies |
| 3 (High) | Index Maintenance | Weekly or nightly | Minutes to hours |
| 4 (Medium) | Statistics Update | After ETL loads or nightly | Minutes |
| 5 (Low) | History Cleanup | Weekly | Seconds to minutes |

### Sample Weekly Maintenance Schedule

```
Sunday 00:00 - Full backup (all databases)
Sunday 02:00 - DBCC CHECKDB (all user databases)
Sunday 04:00 - Index rebuild/reorganize (all user databases)
Sunday 06:00 - Statistics update (only if not done by rebuild)

Monday-Saturday:
  00:00 - Differential backup
  00:30 - Index reorganize (indexes with >10% fragmentation only)
  01:00 - Statistics update (modified statistics only)
  Every 15 min - Transaction log backups (all databases in FULL recovery)

Daily:
  06:00 - DBCC CHECKDB with PHYSICAL_ONLY
  23:00 - Cleanup old backup files, job history, maintenance logs
```

### Key Planning Considerations

- **Know your SLAs**: If the application must be available 24/7, all maintenance must be online-compatible (online rebuilds, non-blocking CHECKDB using database snapshots).
- **Measure baseline durations**: Time each maintenance task in your environment before committing to a schedule.
- **Stagger across databases**: If you have 50 databases, do not rebuild indexes on all of them at the same time.
- **Monitor tempdb**: Online rebuilds and SORT_IN_TEMPDB use tempdb heavily.
- **Account for ETL windows**: Index maintenance after an ETL load is ideal because the data just changed significantly.
- **Leave buffer time**: If CHECKDB typically takes 2 hours, do not schedule the next task to start at exactly 2 hours. Allow 50% buffer.

---

## Common Interview Questions

### Q1: What is the difference between index REORGANIZE and REBUILD?

**A:** REORGANIZE is an online, interruptible operation that defragments leaf-level pages by physically reordering them. It is lightweight and does not update statistics. REBUILD drops and recreates the entire index, resulting in zero fragmentation. Rebuild can be online (Enterprise Edition) or offline, is more resource-intensive, and automatically updates statistics with a full scan. The general guideline is: REORGANIZE for 5-30% fragmentation, REBUILD for >30%.

---

### Q2: A 500 GB table needs index maintenance but the maintenance window is only 2 hours. What do you do?

**A:** Several strategies:
1. **Use resumable index rebuild** (SQL Server 2017+) -- start the rebuild, let it run for the maintenance window, pause it, and resume the next night.
2. **Prioritize**: Only rebuild the most fragmented indexes or those in the most performance-critical query paths.
3. **Use online rebuild** so the table remains available, and extend the window if needed.
4. **Partition the table** by date -- only rebuild partitions with recent data that have high fragmentation.
5. **Use REORGANIZE** instead -- it is slower for heavily fragmented indexes but can be stopped at any time without losing progress.

---

### Q3: Why should you avoid shrinking databases? When is it acceptable?

**A:** Shrinking causes massive index fragmentation because it moves pages from the end of the file to fill gaps at the beginning, destroying the physical ordering of every index. After shrinking, you typically need to rebuild indexes, which grows the file back close to its original size -- making the shrink pointless. It is acceptable only after a permanent, one-time data reduction (e.g., archiving historical data to another database) where the space will never be needed again.

---

### Q4: What is fill factor and how would you tune it?

**A:** Fill factor is the percentage of leaf-level page space filled with data during an index rebuild. The remaining space accommodates future inserts without causing page splits. To tune it: monitor page splits using `sys.dm_db_index_operational_stats`. If an index has high page split counts, lower the fill factor (e.g., from 100 to 90). If page splits are minimal, keep it at 100 to minimize wasted space. The optimal value depends on the insert/update pattern of the table.

---

### Q5: How does DBCC CHECKDB work internally? What is the impact on production?

**A:** CHECKDB reads every page in the database and verifies physical integrity (page checksums, torn page detection), allocation consistency, and logical structure (row-level checks, computed columns, Service Broker). In SQL Server 2005+, it creates an **internal database snapshot** on a volume that has enough free space, so it does not block user queries. However, it generates heavy read I/O and CPU usage. For very large databases, PHYSICAL_ONLY checks can be run more frequently, with full checks less often.

---

### Q6: Explain the Ola Hallengren maintenance solution and why it is preferred over maintenance plans.

**A:** The Ola Hallengren solution is a free, open-source set of stored procedures (`IndexOptimize`, `DatabaseBackup`, `DatabaseIntegrityCheck`) that provide intelligent, parameterized maintenance. Unlike maintenance plans, which rebuild all indexes regardless of fragmentation, Ola's `IndexOptimize` evaluates each index's fragmentation and page count, then takes the appropriate action (nothing, reorganize, or rebuild). It supports online rebuilds, fill factor per index, LOB compaction, statistics updates, and detailed logging to a `CommandLog` table. It is version-controlled, well-documented, and widely trusted in the SQL Server community.

---

### Q7: When should you manually update statistics vs relying on auto-update?

**A:** Manual updates are important after:
1. **Large bulk loads/ETL operations** -- auto-update may not trigger immediately, and when it does, it may use an inadequate sample size.
2. **Ascending key patterns** -- newly inserted values beyond the histogram's range are not reflected until statistics are updated.
3. **Before critical reporting queries** -- ensure the optimizer has the freshest distribution data.
4. **After REORGANIZE** -- since REORGANIZE does not update statistics like REBUILD does.

Use `WITH FULLSCAN` after ETL loads for best accuracy. For routine nightly updates on large tables, `SAMPLE 50 PERCENT` is a reasonable trade-off between accuracy and speed.

---

### Q8: What is the difference between internal and external fragmentation?

**A:** External (logical) fragmentation means index pages are out of physical order on disk -- the logical next page is not stored contiguously. This hurts sequential reads and range scans because the disk head must seek to non-adjacent locations. Internal (page-level) fragmentation means pages contain excessive empty space, typically from deletes or variable-length column updates. This wastes buffer pool memory because more pages must be read to get the same amount of data. Both are reported by `sys.dm_db_index_physical_stats`: `avg_fragmentation_in_percent` (external) and `avg_page_space_used_in_percent` (internal, inverse).

---

## Tips

- **Never include SHRINKDATABASE in a maintenance plan.** This is a common mistake in the maintenance plan wizard, which offers it as a task. Remove it if you inherit such a plan.

- **Run CHECKDB before your full backup** (or at least on the same day). A backup of a corrupt database is a corrupt backup -- knowing about corruption early gives you more recovery options.

- **After every large ETL load**, update statistics with FULLSCAN on the affected tables. Do not rely on auto-update for data warehouse fact tables.

- **Track maintenance history.** Whether using Ola Hallengren's `CommandLog` or your own logging table, record what was done, when, and how long it took. This data is invaluable for capacity planning and troubleshooting.

- **Test your maintenance scripts in a non-production environment first.** An accidentally dropped index or a rebuild that fills the transaction log can cause an outage.

- **For partitioned tables**, target maintenance at the partition level. Only rebuild partitions that have changed (typically the most recent partition in a date-partitioned table):

```sql
ALTER INDEX IX_FactSales_Date ON dbo.FactSales
REBUILD PARTITION = 12 WITH (ONLINE = ON);
```

- **Monitor tempdb during maintenance.** Online rebuilds with `SORT_IN_TEMPDB = ON` can significantly grow tempdb. Ensure adequate space.

- **Consider columnstore indexes differently.** Columnstore indexes use a different internal structure (rowgroups and segments). They do not fragment like B-tree indexes. Use `ALTER INDEX ... REORGANIZE` to compress open delta rowgroups, not to defragment in the traditional sense.

---
