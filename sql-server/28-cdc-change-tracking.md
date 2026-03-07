# Change Data Capture (CDC) & Change Tracking

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Change Data Capture (CDC) Overview](#change-data-capture-cdc-overview)
2. [CDC Architecture](#cdc-architecture)
3. [Enabling CDC](#enabling-cdc)
4. [CDC Schema Tables](#cdc-schema-tables)
5. [Querying CDC Data](#querying-cdc-data)
6. [LSN Functions](#lsn-functions)
7. [CDC Cleanup Job](#cdc-cleanup-job)
8. [CDC and AlwaysOn Availability Groups](#cdc-and-alwayson-availability-groups)
9. [CDC for ETL and Data Warehouse Loading](#cdc-for-etl-and-data-warehouse-loading)
10. [Change Tracking (CT) Overview](#change-tracking-ct-overview)
11. [Enabling Change Tracking](#enabling-change-tracking)
12. [CHANGETABLE Function](#changetable-function)
13. [CDC vs Change Tracking Comparison](#cdc-vs-change-tracking-comparison)
14. [Performance Impact](#performance-impact)
15. [Common Interview Questions](#common-interview-questions)
16. [Tips](#tips)

---

## Change Data Capture (CDC) Overview

Change Data Capture (CDC) is a SQL Server feature that records INSERT, UPDATE, and DELETE activity on tables by reading the transaction log asynchronously. It captures both the fact that changes occurred and the actual column data that changed, storing this information in dedicated change tables within the `cdc` schema.

### Key Characteristics

- **Asynchronous** - CDC reads the transaction log after commits, not inline with DML operations.
- **Non-invasive** - No triggers or schema modifications to the source table are required.
- **Full column history** - Captures before and after images of changed rows.
- **Available in Enterprise Edition** (SQL Server 2008+), and in Standard Edition starting with SQL Server 2016 SP1.

---

## CDC Architecture

CDC relies on several internal components working together:

1. **Transaction Log Reader** - The CDC capture process reads the SQL Server transaction log to identify changes to enabled tables.
2. **Capture Job** - A SQL Server Agent job (`cdc.<database_name>_capture`) that continuously scans the log.
3. **Change Tables** - Destination tables in the `cdc` schema that store the captured change data.
4. **Cleanup Job** - A SQL Server Agent job (`cdc.<database_name>_cleanup`) that purges old change records.

### Data Flow

```
Source Table DML --> Transaction Log --> CDC Capture Process --> cdc.<capture_instance>_CT (Change Table)
```

The capture process uses the log reader agent concept (similar to transactional replication) and translates log records into rows in the change tables.

---

## Enabling CDC

### Step 1: Enable CDC at the Database Level

```sql
-- Must be a member of sysadmin or db_owner
USE YourDatabase;
GO

EXEC sys.sp_cdc_enable_db;
GO

-- Verify CDC is enabled
SELECT name, is_cdc_enabled
FROM sys.databases
WHERE name = 'YourDatabase';
```

When you enable CDC on a database, SQL Server creates:
- The `cdc` schema
- The `cdc.change_tables` metadata table
- The `cdc.captured_columns` metadata table
- The `cdc.ddl_history` table
- The `cdc.index_columns` table
- The `cdc.lsn_time_mapping` table
- Two SQL Server Agent jobs (capture and cleanup)

### Step 2: Enable CDC on Individual Tables

```sql
-- Enable CDC on a specific table
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name   = N'Customers',
    @role_name     = N'cdc_reader',       -- Security role for accessing change data
    @capture_instance = N'dbo_Customers', -- Optional; defaults to schema_table
    @supports_net_changes = 1,            -- Enable net changes (requires unique index)
    @index_name    = N'PK_Customers',     -- Unique index for net changes
    @captured_column_list = N'CustomerID, Name, Email, ModifiedDate',  -- Optional subset
    @filegroup_name = N'CDC_FG';          -- Optional dedicated filegroup
GO

-- Verify table is enabled
SELECT name, is_tracked_by_cdc
FROM sys.tables
WHERE name = 'Customers';
```

### Key Parameters

| Parameter | Description |
|-----------|-------------|
| `@role_name` | Database role that gates access to change data. Pass NULL to skip role-based security. |
| `@capture_instance` | Name for this CDC instance. Maximum of 2 capture instances per table (useful during schema migrations). |
| `@supports_net_changes` | If 1, enables `cdc.fn_cdc_get_net_changes` (requires a unique index). |
| `@index_name` | Unique index used to uniquely identify rows for net changes. |
| `@captured_column_list` | Comma-separated list of columns to capture. NULL means all columns. |

---

## CDC Schema Tables

### Change Table Structure (cdc.<capture_instance>_CT)

When CDC is enabled on a table, a corresponding change table is created:

```sql
-- Example: cdc.dbo_Customers_CT
SELECT * FROM cdc.dbo_Customers_CT;
```

Each change table includes these metadata columns:

| Column | Description |
|--------|-------------|
| `__$start_lsn` | Log Sequence Number (LSN) of the transaction that committed the change |
| `__$end_lsn` | Always NULL in SQL Server (reserved) |
| `__$seqval` | Sequence value to order changes within the same transaction |
| `__$operation` | 1 = Delete, 2 = Insert, 3 = Update (before image), 4 = Update (after image) |
| `__$update_mask` | Bitmask indicating which columns were updated |

### Operation Codes

```sql
-- Understanding __$operation values
SELECT
    __$operation,
    CASE __$operation
        WHEN 1 THEN 'DELETE'
        WHEN 2 THEN 'INSERT'
        WHEN 3 THEN 'UPDATE (Before)'
        WHEN 4 THEN 'UPDATE (After)'
    END AS OperationType,
    CustomerID,
    Name,
    Email
FROM cdc.dbo_Customers_CT
ORDER BY __$start_lsn, __$seqval;
```

### Metadata Tables

```sql
-- List all CDC-enabled tables and their capture instances
SELECT
    source_schema,
    source_name,
    capture_instance,
    object_id,
    supports_net_changes,
    index_name,
    create_date
FROM cdc.change_tables;

-- List captured columns for each instance
SELECT
    capture_instance,
    column_name,
    column_ordinal,
    column_type
FROM cdc.captured_columns;

-- LSN-to-time mapping
SELECT TOP 10
    start_lsn,
    tran_begin_time,
    tran_end_time,
    tran_id
FROM cdc.lsn_time_mapping
ORDER BY tran_end_time DESC;
```

---

## Querying CDC Data

### cdc.fn_cdc_get_all_changes_<capture_instance>

Returns one row for each change (including both before and after images for updates).

```sql
DECLARE @from_lsn binary(10), @to_lsn binary(10);

-- Get LSN range for a time window
SET @from_lsn = sys.fn_cdc_map_time_to_lsn('smallest greater than or equal', '2026-03-01 00:00:00');
SET @to_lsn   = sys.fn_cdc_map_time_to_lsn('largest less than or equal', '2026-03-07 23:59:59');

-- 'all' returns before and after images for updates
SELECT
    __$operation,
    __$update_mask,
    CustomerID,
    Name,
    Email,
    ModifiedDate
FROM cdc.fn_cdc_get_all_changes_dbo_Customers(@from_lsn, @to_lsn, N'all');

-- 'all update old' includes old values for updates (operation 3 and 4 pairs)
SELECT *
FROM cdc.fn_cdc_get_all_changes_dbo_Customers(@from_lsn, @to_lsn, N'all update old');
```

**Row Filter Options:**
- `'all'` - Returns all changes. Updates appear as operation 4 only (after image).
- `'all update old'` - Returns all changes. Updates appear as operation 3 (before) and 4 (after) pairs.

### cdc.fn_cdc_get_net_changes_<capture_instance>

Returns one row per distinct primary key, reflecting the net effect of all changes in the LSN range. Requires `@supports_net_changes = 1`.

```sql
DECLARE @from_lsn binary(10), @to_lsn binary(10);

SET @from_lsn = sys.fn_cdc_map_time_to_lsn('smallest greater than or equal', '2026-03-01 00:00:00');
SET @to_lsn   = sys.fn_cdc_map_time_to_lsn('largest less than or equal', '2026-03-07 23:59:59');

-- Net changes: one row per key showing final state
SELECT
    __$operation,
    __$update_mask,
    CustomerID,
    Name,
    Email,
    ModifiedDate
FROM cdc.fn_cdc_get_net_changes_dbo_Customers(@from_lsn, @to_lsn, N'all');
```

**Row Filter Options for Net Changes:**
- `'all'` - Returns final operation (1=delete, 2=insert, 4=update) and final column values.
- `'all with mask'` - Same as `'all'` but also includes the update mask showing which columns changed.
- `'all with merge'` - Merges inserts and updates into operation 5 (merge). Useful for MERGE statements in ETL.

### Checking Which Columns Changed (Update Mask)

```sql
-- Determine if a specific column was updated
DECLARE @from_lsn binary(10), @to_lsn binary(10);
SET @from_lsn = sys.fn_cdc_get_min_lsn('dbo_Customers');
SET @to_lsn   = sys.fn_cdc_get_max_lsn();

SELECT
    __$operation,
    CustomerID,
    Name,
    Email,
    -- Check if 'Email' column was modified
    sys.fn_cdc_has_column_changed('dbo_Customers', 'Email', __$update_mask) AS EmailChanged,
    sys.fn_cdc_has_column_changed('dbo_Customers', 'Name', __$update_mask) AS NameChanged
FROM cdc.fn_cdc_get_all_changes_dbo_Customers(@from_lsn, @to_lsn, N'all')
WHERE __$operation = 4;  -- After-image of updates
```

---

## LSN Functions

LSN (Log Sequence Number) functions are essential for navigating CDC data.

```sql
-- Get the minimum valid LSN for a capture instance
SELECT sys.fn_cdc_get_min_lsn('dbo_Customers') AS MinLSN;

-- Get the maximum LSN in the database (current log position)
SELECT sys.fn_cdc_get_max_lsn() AS MaxLSN;

-- Map a datetime to an LSN
SELECT sys.fn_cdc_map_time_to_lsn('smallest greater than or equal', '2026-03-01 00:00:00');
SELECT sys.fn_cdc_map_time_to_lsn('largest less than or equal', '2026-03-07 23:59:59');

-- Map an LSN to a datetime
DECLARE @lsn binary(10) = sys.fn_cdc_get_min_lsn('dbo_Customers');
SELECT sys.fn_cdc_map_lsn_to_time(@lsn) AS ChangeTime;

-- Increment/decrement an LSN (useful for pagination or moving past already-processed data)
DECLARE @last_processed_lsn binary(10) = 0x00000025000001E00003;
SELECT sys.fn_cdc_increment_lsn(@last_processed_lsn) AS NextLSN;
SELECT sys.fn_cdc_decrement_lsn(@last_processed_lsn) AS PreviousLSN;
```

### Time-to-LSN Relational Phrases

| Phrase | Meaning |
|--------|---------|
| `'smallest greater than'` | Smallest LSN with a value greater than the specified time |
| `'smallest greater than or equal'` | Smallest LSN with a value greater than or equal to the specified time |
| `'largest less than'` | Largest LSN with a value less than the specified time |
| `'largest less than or equal'` | Largest LSN with a value less than or equal to the specified time |

---

## CDC Cleanup Job

CDC change data accumulates over time and must be periodically purged. SQL Server automatically creates a cleanup agent job.

### Default Behavior

- **Retention period**: 3 days (4320 minutes) by default.
- **Cleanup job** runs every 2 hours by default (at 2:00 AM initially, then every 2 hours).
- Removes entries from the change table that are older than the retention period.

### Configuring Cleanup

```sql
-- Change retention to 7 days (10080 minutes)
EXEC sys.sp_cdc_change_job
    @job_type = N'cleanup',
    @retention = 10080;   -- minutes
GO

-- Change cleanup interval (run every 4 hours = 240 minutes)
EXEC sys.sp_cdc_change_job
    @job_type = N'cleanup',
    @pollinginterval = 240;
GO

-- Stop and restart the cleanup job for changes to take effect
EXEC sys.sp_cdc_stop_job @job_type = N'cleanup';
EXEC sys.sp_cdc_start_job @job_type = N'cleanup';

-- View current job parameters
EXEC sys.sp_cdc_help_jobs;
```

### Manual Cleanup

```sql
-- Manually clean up change data older than a specific LSN
DECLARE @lsn binary(10);
SET @lsn = sys.fn_cdc_map_time_to_lsn('largest less than or equal', '2026-03-01 00:00:00');

EXEC sys.sp_cdc_cleanup_change_table
    @capture_instance = N'dbo_Customers',
    @low_water_mark = @lsn,
    @threshold = 5000;  -- Max rows to delete per batch
```

### Monitoring CDC Latency

```sql
-- Check if capture process is keeping up with the log
EXEC sys.sp_cdc_help_change_data_capture;

-- Check current CDC log scan position vs. end of log
SELECT
    latency,
    command_count,
    status,
    log_record_count,
    empty_scan_count
FROM sys.dm_cdc_log_scan_sessions
ORDER BY start_time DESC;
```

---

## CDC and AlwaysOn Availability Groups

### Key Considerations

- CDC is supported on AlwaysOn Availability Group databases.
- The **CDC capture and cleanup agent jobs exist on every replica**, but they only run on the **primary replica** by default.
- After a **failover**, the new primary automatically starts the capture and cleanup processes.
- The CDC capture process on the new primary picks up from where the old primary left off (using the last committed LSN).

### Important Points

```sql
-- After failover, verify CDC jobs are running on the new primary
EXEC sys.sp_cdc_help_jobs;

-- If logreader latency appears after failover, restart the capture job
EXEC sys.sp_cdc_stop_job @job_type = N'capture';
EXEC sys.sp_cdc_start_job @job_type = N'capture';
```

- CDC metadata is replicated to secondary replicas automatically.
- Change tables on readable secondaries are accessible for queries.
- If using CDC with a readable secondary for reporting, be aware that data is read-only and may have some replication lag.

---

## CDC for ETL and Data Warehouse Loading

CDC is one of the most powerful mechanisms for incremental ETL loading into data warehouses.

### Typical ETL Pattern Using CDC

```sql
-- Step 1: Record the current max LSN as the high-water mark
DECLARE @extraction_lsn binary(10) = sys.fn_cdc_get_max_lsn();

-- Step 2: Retrieve the last processed LSN (stored from previous ETL run)
DECLARE @last_lsn binary(10);
SELECT @last_lsn = LastProcessedLSN FROM ETL.WatermarkTable WHERE TableName = 'Customers';

-- Step 3: Get the next LSN after the last processed one
SET @last_lsn = sys.fn_cdc_increment_lsn(@last_lsn);

-- Step 4: Validate the LSN range
IF @last_lsn IS NOT NULL AND @extraction_lsn IS NOT NULL
   AND @last_lsn <= @extraction_lsn
BEGIN
    -- Step 5: Extract net changes (one row per key)
    SELECT
        __$operation,
        CustomerID,
        Name,
        Email,
        ModifiedDate
    INTO #StagingChanges
    FROM cdc.fn_cdc_get_net_changes_dbo_Customers(
        @last_lsn, @extraction_lsn, N'all with merge'
    );

    -- Step 6: Apply changes to the data warehouse dimension
    MERGE dw.DimCustomer AS target
    USING #StagingChanges AS source
    ON target.CustomerID = source.CustomerID
    WHEN MATCHED AND source.__$operation = 4 THEN
        UPDATE SET
            target.Name = source.Name,
            target.Email = source.Email,
            target.ModifiedDate = source.ModifiedDate
    WHEN NOT MATCHED AND source.__$operation IN (2, 5) THEN
        INSERT (CustomerID, Name, Email, ModifiedDate)
        VALUES (source.CustomerID, source.Name, source.Email, source.ModifiedDate)
    WHEN MATCHED AND source.__$operation = 1 THEN
        DELETE;

    -- Step 7: Update the watermark
    UPDATE ETL.WatermarkTable
    SET LastProcessedLSN = @extraction_lsn
    WHERE TableName = 'Customers';
END
```

### SSIS Integration

- SSIS provides a **CDC Source** and **CDC Splitter** component specifically designed for CDC.
- The CDC Source component handles LSN tracking automatically.
- The CDC Splitter routes rows to Insert, Update, and Delete outputs.
- CDC Control Task manages LSN bookmarking between package executions.

---

## Change Tracking (CT) Overview

Change Tracking is a **lightweight** synchronous mechanism that records which rows changed, but **does not** capture the actual data values that changed. It is designed for synchronization scenarios where the application can query the current state of the source table to get the latest values.

### Key Characteristics

- **Synchronous** - Tracked inline as part of the DML operation (adds slight overhead to writes).
- **No historical data** - Only tracks that a row changed, not what the old or new values were.
- **Lightweight** - Much less storage and I/O than CDC.
- **Available in all editions** of SQL Server (including Standard and Express).
- **Primary key required** on tracked tables.

---

## Enabling Change Tracking

### Step 1: Enable at the Database Level

```sql
ALTER DATABASE YourDatabase
SET CHANGE_TRACKING = ON
(
    CHANGE_RETENTION = 3 DAYS,       -- How long to keep tracking info
    AUTO_CLEANUP = ON                 -- Automatically purge old tracking data
);

-- Verify
SELECT
    DB_NAME(database_id) AS DatabaseName,
    is_auto_cleanup_on,
    retention_period,
    retention_period_units_desc
FROM sys.change_tracking_databases;
```

### Step 2: Enable on Individual Tables

```sql
-- Table must have a primary key
ALTER TABLE dbo.Products
ENABLE CHANGE_TRACKING
WITH (TRACK_COLUMNS_UPDATED = ON);  -- Optional: track which columns changed

-- Verify
SELECT
    OBJECT_NAME(object_id) AS TableName,
    is_track_columns_updated_on,
    min_valid_version,
    begin_version
FROM sys.change_tracking_tables;
```

---

## CHANGETABLE Function

### CHANGETABLE(CHANGES ...)

Returns all changes since a specified version number.

```sql
-- Get the current change tracking version
DECLARE @current_version BIGINT = CHANGE_TRACKING_CURRENT_VERSION();
DECLARE @last_sync_version BIGINT = 1500;  -- Stored from last sync

-- Get all changed rows since last sync
SELECT
    ct.ProductID,
    ct.SYS_CHANGE_VERSION,
    ct.SYS_CHANGE_OPERATION,     -- 'I' = Insert, 'U' = Update, 'D' = Delete
    ct.SYS_CHANGE_CREATION_VERSION,
    ct.SYS_CHANGE_COLUMNS,       -- Bitmask of changed columns (if TRACK_COLUMNS_UPDATED = ON)
    ct.SYS_CHANGE_CONTEXT,       -- Optional application context
    p.ProductName,
    p.Price
FROM CHANGETABLE(CHANGES dbo.Products, @last_sync_version) AS ct
LEFT JOIN dbo.Products AS p ON p.ProductID = ct.ProductID;
-- LEFT JOIN because deleted rows won't exist in the source table
```

### CHANGETABLE(VERSION ...)

Returns the latest change tracking information for specific rows.

```sql
-- Get current version info for specific rows
SELECT
    p.ProductID,
    p.ProductName,
    ct.SYS_CHANGE_VERSION,
    ct.SYS_CHANGE_CONTEXT
FROM dbo.Products AS p
CROSS APPLY CHANGETABLE(VERSION dbo.Products, (ProductID), (p.ProductID)) AS ct;
```

### Version Validation

```sql
-- Always validate that the last sync version is still within the retention window
DECLARE @last_sync_version BIGINT = 1500;
DECLARE @min_valid_version BIGINT = CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID('dbo.Products'));

IF @last_sync_version < @min_valid_version
BEGIN
    -- Tracking data has been cleaned up; full resync required
    RAISERROR('Change tracking data expired. Full synchronization required.', 16, 1);
END
```

### Using CHANGE_TRACKING_IS_COLUMN_IN_MASK

```sql
-- Check if a specific column was updated (requires TRACK_COLUMNS_UPDATED = ON)
DECLARE @last_sync_version BIGINT = 1500;

SELECT
    ct.ProductID,
    ct.SYS_CHANGE_OPERATION,
    CHANGE_TRACKING_IS_COLUMN_IN_MASK(
        COLUMNPROPERTY(OBJECT_ID('dbo.Products'), 'Price', 'ColumnId'),
        ct.SYS_CHANGE_COLUMNS
    ) AS PriceChanged
FROM CHANGETABLE(CHANGES dbo.Products, @last_sync_version) AS ct;
```

---

## CDC vs Change Tracking Comparison

| Feature | CDC | Change Tracking |
|---------|-----|-----------------|
| **Data captured** | Full before/after column values | Only that a row changed (PK + operation) |
| **Mechanism** | Asynchronous (reads transaction log) | Synchronous (inline with DML) |
| **Storage** | High (full row data in change tables) | Low (version numbers and PKs) |
| **SQL Server Agent** | Required (capture and cleanup jobs) | Not required |
| **Edition** | Enterprise (Standard from 2016 SP1) | All editions including Express |
| **Primary key** | Not required (but recommended) | Required |
| **DDL tracking** | Yes (cdc.ddl_history) | No |
| **Column-level tracking** | Yes (__$update_mask with full values) | Yes (bitmask only, no values) |
| **Performance overhead** | Low-moderate (async log read) | Low (sync but lightweight) |
| **Retention** | Time-based (default 3 days) | Time-based (configurable) |
| **AlwaysOn support** | Yes | Yes |
| **Max instances per table** | 2 capture instances | 1 |

### When to Use CDC

- ETL and data warehouse incremental loading
- Auditing where you need to know what values changed
- Data replication to external systems
- Event-driven architectures (stream changes to Kafka, Event Hubs, etc.)
- Regulatory compliance requiring full change history

### When to Use Change Tracking

- Application synchronization (mobile/offline sync)
- Detecting changed rows to refresh a cache
- Lightweight "what changed" detection where current values suffice
- Express or Standard edition where CDC is unavailable
- High-throughput OLTP where CDC overhead is a concern

---

## Performance Impact

### CDC Performance Considerations

- **Transaction log growth** - CDC reads the log, but log records persist until the capture process reads them. Monitor log usage.
- **Capture latency** - If the capture job falls behind, the transaction log cannot be truncated for those records. This can cause log file growth.
- **Change table storage** - High-volume tables can accumulate large change tables. Use a dedicated filegroup.
- **Polling interval** - Default is 5 seconds. Shorter intervals reduce latency but increase CPU usage.

```sql
-- Configure capture job polling
EXEC sys.sp_cdc_change_job
    @job_type = N'capture',
    @pollinginterval = 5,       -- seconds between log scans
    @maxtrans = 500,            -- max transactions per scan cycle
    @maxscans = 10,             -- max scan cycles per polling interval
    @continuous = 1;            -- run continuously
```

### Change Tracking Performance Considerations

- **Inline overhead** - Each DML operation has a small additional cost to maintain the internal tracking tables.
- **Autocleanup** - Runs in the background but can cause I/O spikes on large tables.
- **Side tables** - SQL Server maintains internal side tables that grow with the number of changes within the retention window.

---

## Common Interview Questions

### Q1: What is CDC and how does it differ from triggers for auditing?

**A:** CDC is an asynchronous feature that reads the transaction log to capture INSERT, UPDATE, and DELETE changes to tracked tables. Unlike triggers, CDC does not execute inline with DML operations, so it has minimal impact on write performance. CDC also does not require custom audit table design -- it automatically creates change tables with before/after images. Triggers are synchronous and can impact performance under high load, but offer real-time auditing and the ability to enforce business logic or roll back transactions.

### Q2: How would you set up CDC for incremental data warehouse loading?

**A:** The approach involves: (1) Enable CDC on the source database and target tables. (2) On each ETL run, retrieve the last processed LSN from a watermark/control table. (3) Use `sys.fn_cdc_increment_lsn()` to get the starting LSN for the current batch. (4) Use `sys.fn_cdc_get_max_lsn()` as the ending LSN. (5) Call `cdc.fn_cdc_get_net_changes` with `'all with merge'` to get one row per key. (6) Apply changes to the data warehouse using MERGE or separate INSERT/UPDATE/DELETE logic. (7) Save the ending LSN as the new watermark. This pattern ensures exactly-once delivery of changes and efficient incremental loading.

### Q3: What happens to CDC when you perform a schema change on a tracked table?

**A:** When you add or drop columns on a CDC-enabled table, the DDL change is recorded in `cdc.ddl_history`. However, the existing change table structure is NOT automatically modified. To capture new columns, you must create a second capture instance (each table supports up to 2) with the updated column list, then disable the old instance. This allows a smooth transition without data loss during schema migrations.

```sql
-- Create new instance with added column
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name   = N'Customers',
    @capture_instance = N'dbo_Customers_v2',
    @supports_net_changes = 1,
    @index_name = N'PK_Customers',
    @role_name = NULL;

-- After ETL is updated to use v2, disable the old instance
EXEC sys.sp_cdc_disable_table
    @source_schema = N'dbo',
    @source_name   = N'Customers',
    @capture_instance = N'dbo_Customers';
```

### Q4: What is Change Tracking and when would you prefer it over CDC?

**A:** Change Tracking is a lightweight synchronous mechanism that records which rows changed (by primary key) and the type of operation, but does not capture the actual data values. It is available in all SQL Server editions and has lower overhead than CDC. You would prefer it when: (a) you only need to know which rows changed and can query current values from the source, (b) you are building application-level synchronization (e.g., offline clients syncing back), (c) you are running Standard or Express edition, or (d) write performance is critical and you want minimal overhead.

### Q5: How do you handle CDC log growth and troubleshoot a capture process that falls behind?

**A:** If the CDC capture process falls behind, the transaction log cannot truncate the unread portion, leading to log growth. To troubleshoot: (1) Check `sys.dm_cdc_log_scan_sessions` for latency and error information. (2) Verify the capture agent job is running (`sp_cdc_help_jobs`). (3) Increase `@maxtrans` and `@maxscans` parameters to process more changes per cycle. (4) Reduce the polling interval. (5) Ensure the server has adequate CPU and I/O. (6) Consider disabling CDC on low-priority tables. (7) If the log has grown uncontrollably, as a last resort you may need to temporarily stop and restart the capture job after resolving the bottleneck.

### Q6: Can you use CDC with AlwaysOn Availability Groups?

**A:** Yes. CDC is fully supported with AlwaysOn AG. The capture and cleanup jobs exist on every replica but only run on the current primary. After failover, the new primary automatically resumes capture from the last committed LSN. CDC change tables are replicated to secondaries and are queryable on readable secondaries. One caveat: after failover, there may be a brief period of increased capture latency as the new primary catches up.

### Q7: What is the CHANGETABLE function and how is it used?

**A:** `CHANGETABLE` is the primary function for querying Change Tracking data. It has two forms: `CHANGETABLE(CHANGES table, version)` returns all rows that changed since a given version number, including the operation type (I/U/D) and primary key values. `CHANGETABLE(VERSION table, (columns), (values))` returns the current version information for specific rows. The typical pattern is to store the `CHANGE_TRACKING_CURRENT_VERSION()` after each sync, then pass it to `CHANGETABLE(CHANGES ...)` on the next sync to get the delta.

### Q8: What happens if Change Tracking cleanup removes data you have not yet synced?

**A:** If the retention period expires and cleanup removes tracking data before your application reads it, calling `CHANGETABLE(CHANGES ...)` with an old version will fail. You should always validate using `CHANGE_TRACKING_MIN_VALID_VERSION()` before querying. If your last sync version is below the minimum valid version, you must perform a full resynchronization of the table.

---

## Tips

- **Always use a dedicated filegroup** for CDC change tables on high-volume systems to isolate I/O.
- **Monitor the capture job** continuously. If it stops, the transaction log will grow without bound.
- **Set appropriate retention periods** -- too short and you risk missing data in ETL; too long and change tables consume excessive storage.
- **Use net changes** (`fn_cdc_get_net_changes`) for ETL to minimize the volume of data processed. A row inserted and then updated 10 times will appear as a single insert.
- **Two capture instances** are your friend during schema migrations. Enable the new instance before disabling the old one.
- **For Change Tracking**, always validate the minimum valid version before querying to avoid silent data loss.
- **Prefer CDC** when you need historical before/after values or are feeding external systems. Prefer **Change Tracking** for lightweight sync scenarios.
- **CDC and transactional replication** both use the log reader; having both on the same database is supported but increases log reader workload.
- **Test failover scenarios** with CDC and AlwaysOn to ensure your ETL processes handle LSN continuity correctly.
- **Index the change tables** if you query them directly by adding custom indexes on the `__$start_lsn` column for time-range queries.
