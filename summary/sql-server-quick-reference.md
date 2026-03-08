# SQL Server - Quick Reference & Essential Q&A

[Back to Summary Index](README.md)

> A dense, study-ready reference covering architecture, query processing, indexing, concurrency, HA/DR, security, ETL, administration, advanced features, T-SQL, and modern capabilities. Key numbers and code snippets included throughout.

---

## Table of Contents

1. [Architecture & Internals](#1-architecture--internals)
2. [Query Processing & Optimization](#2-query-processing--optimization)
3. [Indexing Strategies](#3-indexing-strategies)
4. [Concurrency & Transactions](#4-concurrency--transactions)
5. [High Availability & DR](#5-high-availability--dr)
6. [Security](#6-security)
7. [ETL & Data Movement](#7-etl--data-movement)
8. [Administration](#8-administration)
9. [Advanced Features](#9-advanced-features)
10. [T-SQL Essentials](#10-t-sql-essentials)
11. [Migration & Modern Features](#11-migration--modern-features)

---

## 1. Architecture & Internals

### Key Highlights

- **Data page size**: 8 KB (8,192 bytes); usable space ~8,060 bytes after header (96 bytes) and row-offset array.
- **Extent**: 8 contiguous pages = 64 KB. Two types: **uniform** (single object) and **mixed** (up to 8 objects; used for first 8 pages of small tables).
- **Buffer pool**: In-memory cache of data pages. Managed by **Buffer Manager**. Pages are clean or dirty.
- **Lazy Writer**: Frees buffer pool pages when memory pressure exists; writes dirty pages to disk using LRU-K algorithm.
- **Checkpoint**: Writes all dirty pages for a database to disk. Reduces recovery time. Automatic checkpoint targets ~1 minute recovery interval by default.
- **Transaction log (LDF)**: Write-ahead logging (WAL) — log record written before data page change. Sequential, append-only writes. Log records have LSNs (Log Sequence Numbers).
- **SQLOS**: SQL Server's own OS layer. Manages scheduling, memory, I/O. Uses **cooperative (non-preemptive) scheduling**.
- **Schedulers**: One per logical CPU. Each scheduler has a **runnable queue** and **waiter list**. Workers yield voluntarily.
- **Max row size**: 8,060 bytes (in-row). Overflow for varchar(max), nvarchar(max), varbinary(max) — stored in LOB or row-overflow pages.
- **Max columns per table**: 1,024 (30,000 for wide tables with sparse columns).
- **Max database size**: 524 PB (Enterprise). Express edition: 10 GB.

### Essential Q&A

**Q: How does SQL Server process a write operation internally?**
A: (1) Log record written to log buffer, then flushed to transaction log on disk (WAL). (2) Data page modified in buffer pool (now dirty). (3) Checkpoint or lazy writer eventually flushes dirty page to data file. The transaction is durable once the log record is hardened to disk — the data file write can happen later.

**Q: What is the difference between checkpoint and lazy writer?**
A: **Checkpoint** writes all dirty pages of a database to disk to reduce crash recovery time; it does not free memory. **Lazy writer** writes dirty pages to disk AND frees buffer pool memory when the system is under memory pressure, using LRU-K eviction.

**Q: Explain SQLOS and why SQL Server uses non-preemptive scheduling.**
A: SQLOS is an abstraction layer that manages CPU scheduling, memory, and I/O internally. Non-preemptive (cooperative) scheduling means threads voluntarily yield rather than being interrupted. This reduces expensive context switches and gives SQL Server fine-grained control over task execution, which is critical for managing thousands of concurrent queries efficiently.

**Q: What are the components of a data page?**
A: A 96-byte **header** (page number, type, object ID, LSN, etc.), the **data area** (rows stored sequentially), and the **row-offset array** (slot array at the end, growing backward, each 2-byte entry pointing to a row's start position).

**Q: What happens during SQL Server startup/recovery?**
A: The **recovery process** runs per database in three phases: (1) **Analysis** — scans log from last checkpoint to determine dirty pages and active transactions. (2) **Redo** — replays all committed transactions not yet written to data files. (3) **Undo** — rolls back uncommitted transactions. This guarantees ACID durability.

**Q: How does the buffer pool decide which pages to keep?**
A: Uses a clock-based LRU-K (K=2) algorithm. Pages have a reference count. Frequently accessed pages stay longer. When memory pressure occurs, the lazy writer scans buffer pool, decrements reference counts, and evicts pages with zero references.

---

## 2. Query Processing & Optimization

### Key Highlights

- **Query processing phases**: Parsing → Binding (Algebrizer) → Optimization → Execution.
- **Optimizer**: Cost-based. Evaluates candidate plans and picks the one with lowest estimated cost. Uses **transformation rules** and **memo structure**.
- **Trivial plan**: Simple queries skip full optimization (e.g., single-table SELECT with index).
- **Statistics**: Histograms (up to 200 steps) on column data distributions. Auto-created on indexed columns and columns in WHERE clauses.
- **Cardinality Estimation (CE)**: Old CE (pre-2014) vs New CE (2014+). New CE uses model variation and multi-predicate independence assumptions differently.
- **Parameter sniffing**: Optimizer compiles plan based on first execution's parameter values. Can cause performance issues when data is skewed.
- **Plan cache**: Stores compiled plans in memory. Plans evicted under memory pressure. Recompile triggered by schema changes, statistics updates, or `OPTION (RECOMPILE)`.
- **Query Store**: Persists plan history and runtime stats in the database itself. Introduced in SQL Server 2016. Enables plan forcing and regression detection.
- **Key DMVs**: `sys.dm_exec_query_stats`, `sys.dm_exec_requests`, `sys.dm_exec_sql_text`, `sys.dm_exec_query_plan`, `sys.dm_os_wait_stats`.

### Essential Q&A

**Q: What is parameter sniffing and how do you address it?**
A: The optimizer uses the parameter value from the first execution to generate the plan. If data distribution is highly skewed, this plan may be suboptimal for other parameter values. Fixes: `OPTION (RECOMPILE)` — recompiles per execution; `OPTION (OPTIMIZE FOR (@param = value))` — optimizes for a specific value; `OPTION (OPTIMIZE FOR UNKNOWN)` — uses average statistics; **Query Store plan forcing** — pins a known-good plan.

**Q: How do you read an execution plan to find performance issues?**
A: Look for: (1) **Fat arrows** — high row counts flowing between operators. (2) **Estimated vs Actual rows mismatch** — indicates stale statistics. (3) **Key Lookups** — consider covering index. (4) **Table/Index Scans** on large tables — may need better indexing. (5) **Sort/Hash operations with spills to tempdb** — memory grant issues. (6) **Warnings** — missing indexes, implicit conversions, residual predicates.

**Q: What is the Query Store and why is it important?**
A: Query Store captures query text, execution plans, and runtime statistics (CPU, I/O, duration) persistently inside the database. It survives restarts and failovers. Key uses: identify regressed queries, force good plans, track performance over time. Enabled per database: `ALTER DATABASE [db] SET QUERY_STORE = ON`.

**Q: Explain the difference between estimated and actual execution plans.**
A: **Estimated plan**: Generated by the optimizer without executing the query. Shows estimated row counts and costs. Available instantly. **Actual plan**: Produced during execution. Contains actual row counts, actual executions, memory grant info, and runtime warnings (spills, residual I/O). Always prefer actual plans for troubleshooting.

**Q: What are the most useful DMVs for performance tuning?**
A: `sys.dm_exec_query_stats` — aggregated performance stats per plan. `sys.dm_exec_requests` — currently running queries. `sys.dm_os_wait_stats` — cumulative wait statistics (identify bottleneck type: CPU, I/O, locking). `sys.dm_exec_cached_plans` — plan cache contents. `sys.dm_db_index_usage_stats` — index usage patterns. `sys.dm_db_missing_index_details` — optimizer-suggested indexes.

**Q: How do statistics affect query performance?**
A: Statistics tell the optimizer about data distribution, enabling accurate cardinality estimates and good plan choices. Stale or missing statistics cause bad estimates → bad plans (wrong join type, wrong index, wrong parallelism). Auto-update triggers when ~20% of rows change (with modification counter + square root formula in newer versions). You can manually update with `UPDATE STATISTICS` or `sp_updatestats`.

---

## 3. Indexing Strategies

### Key Highlights

- **Clustered index**: Defines physical sort order of data. One per table. Leaf level IS the data. Clustered index key is included in all non-clustered indexes.
- **Non-clustered index**: Separate B-tree structure. Leaf level contains index key columns + row locator (clustered key or RID).
- **Max key columns**: 16 columns, max 900 bytes (1,700 bytes for non-clustered in SQL 2016+).
- **Covering index**: Contains all columns needed for a query, avoiding key lookups.
- **Included columns**: Added to leaf level only (not in B-tree navigation). No 900-byte key size limit. Cannot be used for seeking, only for covering.
- **Filtered index**: Index with a WHERE clause. Smaller, more efficient. Useful for queries on subsets of data.
- **Columnstore index**: Column-based storage with compression. Ideal for analytics/aggregations. **Rowgroups** of up to ~1,048,576 rows, compressed into segments.
- **Fill factor**: Percentage of leaf page fullness at index build/rebuild. Default is 0 (= 100%). Lower fill factor reduces page splits but wastes space.
- **Fragmentation**: **Internal** (low page density) and **External** (logical vs physical order mismatch). Check with `sys.dm_db_index_physical_stats`. Reorganize at 10-30%, rebuild above 30%.

### Essential Q&A

**Q: When would you choose a non-clustered index over a clustered index?**
A: The clustered index should be on columns used for range scans and the most common access pattern (often a narrow, ever-increasing key like IDENTITY). Non-clustered indexes support secondary access patterns — queries filtering on different columns. You can have up to 999 non-clustered indexes per table.

**Q: Explain covering indexes and included columns with an example.**
A: A covering index satisfies a query entirely from the index without touching the base table.
```sql
-- Query:
SELECT Name, Email FROM Users WHERE Status = 'Active';

-- Covering index with included columns:
CREATE NONCLUSTERED INDEX IX_Users_Status
ON Users (Status) INCLUDE (Name, Email);
```
`Status` is the key column (used for seeking). `Name` and `Email` are included (available at leaf level for covering, not part of the B-tree key).

**Q: What are columnstore indexes and when do you use them?**
A: Columnstore indexes store data column-by-column instead of row-by-row. Benefits: (1) High compression (similar values together). (2) Batch-mode execution (processes ~900 rows at a time). (3) Segment elimination (skip irrelevant rowgroups). Use for: analytical queries, data warehouses, aggregations over millions of rows. Avoid for: OLTP point lookups, frequent single-row updates.

**Q: How do you handle index fragmentation?**
A: Check with `sys.dm_db_index_physical_stats`. Strategy: <10% fragmentation — do nothing. 10-30% — `ALTER INDEX REORGANIZE` (online, lightweight, log-friendly). >30% — `ALTER INDEX REBUILD` (can be online with Enterprise edition, resets fill factor and statistics). Schedule maintenance during low-activity windows.

**Q: What is the tipping point and how does it affect index usage?**
A: The tipping point is where the optimizer switches from non-clustered index seek + key lookups to a full clustered index scan. Typically at ~25-33% of table rows (varies by row size). Each key lookup is a random I/O, so at a certain row count, sequential scan becomes cheaper. Solution: make the index covering to avoid lookups.

**Q: What are filtered indexes and their limitations?**
A: Filtered indexes include only rows matching a WHERE predicate, making them smaller and faster.
```sql
CREATE NONCLUSTERED INDEX IX_Orders_Pending
ON Orders (OrderDate) WHERE Status = 'Pending';
```
Limitations: Cannot use complex expressions, OR, or non-deterministic functions. Must use `SET ANSI_NULLS ON` and `SET QUOTED_IDENTIFIER ON`. Parameterized queries may not match — sometimes need `OPTION (RECOMPILE)`.

---

## 4. Concurrency & Transactions

### Key Highlights

- **ACID**: Atomicity, Consistency, Isolation, Durability — guaranteed for every transaction.
- **Default isolation level**: READ COMMITTED.
- **Lock types**: Shared (S), Exclusive (X), Update (U), Intent (IS, IX, IU), Schema (Sch-S, Sch-M), Bulk Update (BU).
- **Lock granularity**: Row → Page → Partition → Table. Lock escalation: from row/page to table (threshold: ~5,000 locks on one object).
- **Deadlock**: Circular wait. SQL Server detects via deadlock monitor (runs every 5 seconds, then every 100ms after detection). Lowest-cost transaction is chosen as victim and rolled back.

| Isolation Level | Dirty Read | Non-Repeatable Read | Phantom | Mechanism |
|---|---|---|---|---|
| READ UNCOMMITTED | Yes | Yes | Yes | No shared locks |
| READ COMMITTED | No | Yes | Yes | S locks released after read |
| REPEATABLE READ | No | No | Yes | S locks held until end of txn |
| SERIALIZABLE | No | No | No | Range locks |
| SNAPSHOT | No | No | No | Row versioning (tempdb) |
| READ COMMITTED SNAPSHOT (RCSI) | No | Yes | Yes | Row versioning (tempdb) |

- **SNAPSHOT vs RCSI**: SNAPSHOT sees data as of transaction start. RCSI sees data as of each statement start. RCSI is set at database level; SNAPSHOT is set per transaction.

### Essential Q&A

**Q: Explain the difference between pessimistic and optimistic concurrency.**
A: **Pessimistic** (default SQL Server): Uses locks to prevent conflicts. Readers block writers and vice versa. Guarantees consistency but reduces throughput. **Optimistic** (SNAPSHOT/RCSI): Uses row versioning in tempdb. Readers never block writers. Conflicts detected at commit time (SNAPSHOT) or avoided by statement-level versioning (RCSI). Higher tempdb usage.

**Q: How do you troubleshoot blocking in SQL Server?**
A: (1) `sys.dm_exec_requests` — check `blocking_session_id`. (2) `sys.dm_tran_locks` — see lock details. (3) `sys.dm_os_waiting_tasks` — active waits. (4) Activity Monitor or `sp_who2`. (5) Look at head blocker — the session at the top of the blocking chain. Common causes: long-running transactions, missing indexes (causing table locks), escalation. Solutions: optimize queries, add indexes, use RCSI, reduce transaction scope.

**Q: How do you handle deadlocks?**
A: **Detection**: Enable trace flag 1222 or use Extended Events (`xml_deadlock_report`). **Prevention**: Access objects in consistent order, keep transactions short, use appropriate isolation level, avoid user interaction mid-transaction. **Handling**: Implement retry logic in application code — the victim gets error 1205.

**Q: What is RCSI and when should you enable it?**
A: Read Committed Snapshot Isolation changes READ COMMITTED to use row versioning instead of locks. Enable with: `ALTER DATABASE [db] SET READ_COMMITTED_SNAPSHOT ON` (requires single-user access briefly). Benefits: readers don't block writers, reduced deadlocks. Costs: tempdb overhead for version store, 14-byte overhead per row in tempdb. Recommended for most OLTP workloads.

**Q: What is lock escalation and how do you control it?**
A: SQL Server escalates row/page locks to a table lock when a single transaction holds ~5,000 locks on one object. This reduces memory usage but can increase blocking. Control with: `ALTER TABLE ... SET (LOCK_ESCALATION = { TABLE | AUTO | DISABLE })`. `AUTO` escalates to partition level for partitioned tables. `DISABLE` prevents escalation (use cautiously — memory impact).

---

## 5. High Availability & DR

### Key Highlights

- **Always On Availability Groups (AG)**: Enterprise feature. Group of databases that fail over together. Up to 9 replicas (1 primary + 8 secondary). Synchronous or asynchronous commit. Readable secondaries. Requires WSFC.
- **Failover Cluster Instance (FCI)**: Shared-storage failover. Single instance that moves between nodes. Automatic failover. Protects against server failure, not storage failure.
- **Log Shipping**: Automated backup-copy-restore of transaction logs. Simple, low cost. Manual failover. Standby or no-recovery mode. RPO depends on backup frequency.
- **Database Mirroring**: Deprecated (use AG instead). Synchronous or async. Automatic failover with witness.
- **RPO (Recovery Point Objective)**: Maximum acceptable data loss. RPO = 0 requires synchronous commit.
- **RTO (Recovery Time Objective)**: Maximum acceptable downtime.
- **Backup types**: Full, Differential (changes since last full), Transaction Log (changes since last log backup). Copy-only backups don't affect backup chain.

### Essential Q&A

**Q: Explain Always On Availability Groups architecture.**
A: An AG consists of: (1) **Availability replicas** — SQL Server instances hosting copies of the database group. (2) **Listener** — virtual network name/IP for client connections. (3) **WSFC** — provides health monitoring and failover infrastructure. Synchronous replicas guarantee zero data loss (RPO=0). Asynchronous replicas allow data loss but reduce latency impact. Secondary replicas can serve read-only workloads.

**Q: How do you design a backup strategy for a critical OLTP database?**
A: Full backup weekly (or nightly for smaller DBs), differential backup daily (reduces restore time), transaction log backup every 5-15 minutes (controls RPO). Use CHECKSUM option. Test restores regularly. Store backups offsite/cloud. Example RPO of 15 minutes requires log backups every 15 minutes. Point-in-time recovery is possible with log backups: `RESTORE LOG ... WITH STOPAT = '2026-03-08T10:30:00'`.

**Q: What is the difference between AG synchronous and asynchronous commit?**
A: **Synchronous**: Primary waits for secondary to harden the log before acknowledging commit to client. Zero data loss guaranteed. Adds latency (round-trip to secondary). Best within same datacenter. **Asynchronous**: Primary commits without waiting for secondary. Possible data loss. Lower latency. Best for remote/DR replicas across WAN.

**Q: How does point-in-time recovery work?**
A: Requires database in FULL or BULK_LOGGED recovery model with an unbroken log backup chain. Steps: (1) Backup the tail of the log (`WITH NORECOVERY`). (2) Restore last full backup (`WITH NORECOVERY`). (3) Restore latest differential (`WITH NORECOVERY`). (4) Restore log backups in sequence, final one with `STOPAT` to the desired time. (5) `RESTORE DATABASE ... WITH RECOVERY`.

**Q: Compare FCI vs AG for high availability.**
A: **FCI**: Shared storage, single data copy, protects against server failure not storage failure, instance-level failover, lower edition requirements. **AG**: Independent storage per replica, database-level failover, protects against storage failure, readable secondaries, more flexible topology but requires Enterprise edition (Basic AG available in Standard for single database).

**Q: What is the difference between Full, Differential, and Log backups?**
A: **Full**: Complete copy of the database. Resets the differential bitmap. **Differential**: Only data extents changed since the last full backup. Cumulative (each differential contains all changes since last full). **Log**: Backs up the transaction log since the last log backup. Sequential — must restore in order. Allows point-in-time recovery. Only available in FULL/BULK_LOGGED recovery models.

---

## 6. Security

### Key Highlights

- **Authentication modes**: Windows Authentication (Kerberos/NTLM, preferred) or Mixed Mode (Windows + SQL logins).
- **TDE (Transparent Data Encryption)**: Encrypts data files, log files, and backups at rest using a Database Encryption Key (DEK) protected by a certificate. No application changes needed. Encrypts at page level during I/O. CPU overhead: 3-5%.
- **Always Encrypted**: Client-side encryption. SQL Server never sees plaintext. Two types: **Deterministic** (same plaintext → same ciphertext, allows equality comparisons) and **Randomized** (more secure, no queries on it). Column Master Key (CMK) stored in client-side key store.
- **Row-Level Security (RLS)**: Filter predicates (control which rows are visible) and block predicates (prevent writes). Uses inline table-valued functions as security predicates.
- **Dynamic Data Masking (DDM)**: Masks data in query results for non-privileged users. Masking types: default, email, random, custom string. Does NOT encrypt data — privileged users or direct queries can bypass.
- **SQL Injection prevention**: Use parameterized queries/stored procedures. Never concatenate user input into SQL strings. Principle of least privilege.

### Essential Q&A

**Q: How does TDE work and what does it protect against?**
A: TDE encrypts the database at rest: data files (.mdf/.ndf), log files (.ldf), and backups. It uses a symmetric DEK stored in the database boot record, encrypted by a certificate in the master database. Hierarchy: Service Master Key → Database Master Key → Certificate → DEK. It protects against physical theft of disks or backup files. It does NOT protect data in memory or in transit (use TLS for that).

**Q: Compare Always Encrypted vs TDE.**
A: **TDE**: Encrypts entire database at rest. SQL Server can see and process plaintext in memory. No application changes. Protects against physical media theft. **Always Encrypted**: Encrypts specific columns. SQL Server never sees plaintext (encrypted in client driver). Requires application/driver changes. Protects against DBA-level threats and compromised server. Much stronger isolation but more complex to implement.

**Q: How do you implement Row-Level Security?**
A:
```sql
-- 1. Create a predicate function
CREATE FUNCTION dbo.fn_SecurityPredicate(@TenantId INT)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN
    SELECT 1 AS result WHERE @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT);

-- 2. Create a security policy
CREATE SECURITY POLICY dbo.TenantFilter
ADD FILTER PREDICATE dbo.fn_SecurityPredicate(TenantId) ON dbo.Orders,
ADD BLOCK PREDICATE dbo.fn_SecurityPredicate(TenantId) ON dbo.Orders
WITH (STATE = ON);
```
Filter predicates silently filter rows. Block predicates prevent unauthorized inserts/updates.

**Q: What is the principle of least privilege in SQL Server?**
A: Grant only the minimum permissions needed. Use database roles instead of direct grants. Avoid `sa` and `db_owner` for applications. Use schemas to organize and secure objects. Use `EXECUTE AS` for stored procedure context. Grant `EXECUTE` on procedures rather than direct table access. Regularly audit permissions with `sys.fn_my_permissions` and `sys.database_permissions`.

**Q: How do you audit database activity in SQL Server?**
A: (1) **SQL Server Audit** (Enterprise): Server-level and database-level audit specifications. Writes to file, Windows Event Log, or Security Log. (2) **Extended Events**: Lightweight event capture. (3) **Change Data Capture (CDC)**: Captures data changes. (4) **Temporal Tables**: Automatic history tracking. (5) **DML Triggers**: Custom auditing logic. SQL Server Audit is the recommended approach for compliance requirements.

---

## 7. ETL & Data Movement

### Key Highlights

- **SSIS (SQL Server Integration Services)**: Full-featured ETL platform. Control flow (tasks) and data flow (transformations). Packages deployed to SSIS Catalog (project deployment model). Supports parallelism, logging, error handling, and variables.
- **BCP (Bulk Copy Program)**: Command-line tool for bulk import/export. Fastest for simple data movement. Native and character modes.
- **BULK INSERT**: T-SQL statement for importing flat files. Faster than row-by-row INSERT. Supports format files.
- **Linked Servers**: Access remote data sources via T-SQL (four-part names). Distributed queries. Performance considerations: predicate pushdown may not work — filter locally.
- **CDC (Change Data Capture)**: Captures INSERT, UPDATE, DELETE operations from the transaction log. Creates change tables. Uses SQL Agent jobs. Provides `cdc.fn_cdc_get_all_changes` and `cdc.fn_cdc_get_net_changes` functions.
- **Change Tracking**: Lightweight alternative to CDC. Tracks which rows changed (not the values). Synchronous, via internal triggers. Good for sync scenarios.
- **Service Broker**: Asynchronous messaging within SQL Server. Reliable, ordered, transactional message delivery. Uses queues, services, contracts, and message types.

### Essential Q&A

**Q: Compare CDC vs Change Tracking.**
A: **CDC**: Captures full before/after column values, reads from transaction log asynchronously, creates separate change tables, higher overhead, ideal for ETL/data warehouse loading. **Change Tracking**: Only tracks that a row changed (and which columns), synchronous with DML, lightweight, no separate tables, ideal for application sync (e.g., mobile offline sync). CDC needs SQL Agent; Change Tracking does not.

**Q: How do you optimize BULK INSERT performance?**
A:
```sql
BULK INSERT dbo.SalesData
FROM 'C:\Data\sales.csv'
WITH (
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    TABLOCK,              -- table-level lock for minimal logging
    BATCHSIZE = 100000,   -- commit every 100K rows
    ORDER (SaleId ASC)    -- match clustered index order
);
```
Key tips: Use `TABLOCK` for minimal logging (requires SIMPLE or BULK_LOGGED recovery). Pre-sort data to match clustered index. Drop non-clustered indexes, bulk load, then rebuild.

**Q: When should you use SSIS vs other methods?**
A: **SSIS**: Complex transformations, multiple sources/destinations, conditional logic, error handling, scheduling. **BCP/BULK INSERT**: Simple, high-volume data loading from flat files. **Linked Servers + INSERT...SELECT**: Small to medium cross-server data movement. **Azure Data Factory**: Cloud-first or hybrid ETL. SSIS is best when you need transformation logic, data quality checks, and enterprise-grade control flow.

**Q: How does CDC work internally?**
A: CDC uses the SQL Agent Log Reader Agent to scan the transaction log. It captures changes to tracked tables and writes them to system change tables (`cdc.<capture_instance>_CT`). Each change record includes: operation type (insert/update/delete), LSN, column values. Cleanup is handled by a separate SQL Agent job (default retention: 3 days). Enable with: `sys.sp_cdc_enable_db` then `sys.sp_cdc_enable_table`.

**Q: What are the performance considerations for Linked Servers?**
A: (1) Predicate pushdown is not guaranteed — SQL Server may pull entire remote tables locally. (2) Use `OPENQUERY` for better predicate pushdown control. (3) Distributed transactions (MSDTC) add overhead. (4) Network latency amplifies per-row operations. (5) Statistics on remote tables are limited, leading to poor plan choices. Best practice: minimize remote data transfer, use staging tables for complex joins.

---

## 8. Administration

### Key Highlights

- **SQL Agent**: Job scheduling and alerting. Jobs have steps (T-SQL, SSIS, PowerShell, OS command). Schedules, alerts, operators. Stored in msdb.
- **Maintenance Plans**: Graphical maintenance task configuration. Tasks include: index rebuild/reorganize, update statistics, integrity check (DBCC CHECKDB), backup, cleanup.
- **Resource Governor**: Limits CPU, memory, and I/O for workload groups. Classifies sessions into groups via classifier function. Enterprise only.
- **tempdb best practices**: Multiple data files (1 per CPU core, up to 8). Equal file size. Trace flag 1118 (uniform extents, default in 2016+). Trace flag 1117 (auto-grow all files equally, default in 2016+). Place on fast SSD/NVMe.
- **Partitioning**: Splits a table into partitions based on a partition function and scheme. Benefits: partition elimination in queries, sliding window for archival, per-partition index maintenance. Maximum 15,000 partitions.
- **Memory configuration**: `max server memory` — set to leave 4 GB + 1 GB per 4 GB RAM for OS (rough guideline). `min server memory` — minimum guaranteed. Lock Pages in Memory (LPIM) — prevents Windows from paging out buffer pool.

### Essential Q&A

**Q: What is DBCC CHECKDB and how often should you run it?**
A: DBCC CHECKDB validates physical and logical integrity of all objects in a database. It checks page structure, index consistency, and allocation. Run at least weekly for critical databases. It is I/O-intensive — schedule during low activity. Use `WITH NO_INFOMSGS, ALL_ERRORMSGS` for clean output. For very large databases, use `DBCC CHECKFILEGROUP` to rotate checks across filegroups throughout the week.

**Q: How do you configure tempdb optimally?**
A: (1) Number of data files: start with 1 per logical CPU core, up to 8. Add more only if contention persists (PAGELATCH waits on PFS/GAM/SGAM pages). (2) All files equal size with equal auto-growth. (3) Place on fastest available storage. (4) Pre-size files to avoid auto-growth during operations. (5) In SQL 2016+, TF 1117 and TF 1118 behavior is default. (6) Consider tempdb metadata memory optimization (SQL 2019+).

**Q: How does table partitioning work?**
A:
```sql
-- 1. Create partition function (defines boundaries)
CREATE PARTITION FUNCTION pf_OrderDate (DATE)
AS RANGE RIGHT FOR VALUES ('2024-01-01', '2025-01-01', '2026-01-01');

-- 2. Create partition scheme (maps to filegroups)
CREATE PARTITION SCHEME ps_OrderDate
AS PARTITION pf_OrderDate ALL TO ([PRIMARY]);

-- 3. Create table on partition scheme
CREATE TABLE Orders (
    OrderId INT, OrderDate DATE, Amount DECIMAL(10,2)
) ON ps_OrderDate(OrderDate);
```
Queries filtering on `OrderDate` benefit from partition elimination — only relevant partitions are scanned.

**Q: What is Resource Governor and when do you use it?**
A: Resource Governor controls CPU, memory, and I/O allocation for different workloads. Use case: prevent a reporting workload from consuming all CPU and impacting OLTP. Create resource pools (define limits), workload groups (associate with pools), and a classifier function (routes sessions to groups). Example: limit reports to 30% CPU, 25% memory.

**Q: How do you handle database growth and auto-growth settings?**
A: Pre-size data and log files to expected size. Set auto-growth in fixed MB amounts (not percentages) — e.g., 512 MB or 1 GB increments. Percentage growth leads to progressively larger, slower growth events. Monitor with `sys.dm_os_performance_counters` or Extended Events for auto-growth events. Use instant file initialization (IFI) for data files — drastically reduces growth time (requires `Perform Volume Maintenance Tasks` privilege).

**Q: What is instant file initialization?**
A: IFI allows SQL Server to allocate data files without zero-filling the disk space. File creation and auto-growth for data files become nearly instant regardless of size. Enabled by granting the SQL Server service account the `Perform Volume Maintenance Tasks` Windows privilege. Does NOT apply to log files (always zero-initialized for recovery safety). Major impact on restore times and auto-growth performance.

---

## 9. Advanced Features

### Key Highlights

- **In-Memory OLTP (Hekaton)**: Memory-optimized tables and natively compiled stored procedures. Lock-free, latch-free architecture. Row versioning with timestamps. Up to 10-30x performance improvement for OLTP workloads. Requires `MEMORY_OPTIMIZED_DATA` filegroup.
- **Columnstore batch mode**: Processes ~900 rows per operator iteration instead of 1 (row mode). Available on columnstore indexes by default; **batch mode on rowstore** (SQL 2019+) extends this to any query.
- **JSON support**: `FOR JSON` (output), `OPENJSON` (parse), `JSON_VALUE`, `JSON_QUERY`, `JSON_MODIFY`. No native JSON data type — stored as NVARCHAR.
- **XML support**: Native XML data type, XQuery, XML indexes (primary + secondary: PATH, VALUE, PROPERTY), `FOR XML`, `OPENXML`.
- **Window functions**: `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `NTILE`, `LAG`, `LEAD`, `FIRST_VALUE`, `LAST_VALUE`, with `OVER (PARTITION BY ... ORDER BY ... ROWS/RANGE ...)`.
- **Graph database**: Node and edge tables (SQL 2017+). `MATCH` clause for graph pattern queries. Useful for social networks, recommendations, hierarchies.
- **CLR integration**: Run .NET code inside SQL Server. Use for complex computations, regex, file I/O not possible in T-SQL. Requires `PERMISSION_SET` (SAFE, EXTERNAL_ACCESS, UNSAFE). Enable with `sp_configure 'clr enabled', 1`.

### Essential Q&A

**Q: When and how do you use In-Memory OLTP?**
A: Best for: high-throughput OLTP (inserts, point lookups), latch/lock contention bottlenecks, tempdb contention (use memory-optimized table variables). Implementation: create filegroup with `CONTAINS MEMORY_OPTIMIZED_DATA`, create table with `MEMORY_OPTIMIZED = ON`. Limitations: no LOB columns (removed in 2017), limited DML triggers, max 8,060-byte row size (raised in 2017), no cross-database queries. Natively compiled procedures: compile T-SQL to C DLL — fastest execution.

**Q: Explain batch mode processing vs row mode.**
A: **Row mode**: Each operator processes one row at a time, calling `GetNext()` on its child. High CPU overhead per row. **Batch mode**: Operators process batches of ~900 rows using vectorized CPU instructions. Dramatically reduces CPU cost for analytical queries. Originally only with columnstore indexes; SQL 2019+ enables batch mode on rowstore when the optimizer determines it's beneficial (typically for scans, aggregations, joins on large datasets).

**Q: How do you work with JSON in SQL Server?**
A:
```sql
-- Parse JSON
DECLARE @json NVARCHAR(MAX) = '[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]';
SELECT * FROM OPENJSON(@json) WITH (id INT, name NVARCHAR(50));

-- Generate JSON
SELECT id, name FROM Users FOR JSON PATH;

-- Modify JSON
SELECT JSON_MODIFY(@json, '$[0].name', 'Charlie');

-- Query scalar value
SELECT JSON_VALUE(@json, '$[0].name');  -- Returns 'Alice'
```
For frequent JSON querying, create computed columns with indexes on extracted values.

**Q: What are window functions and why are they powerful?**
A: Window functions perform calculations across a set of rows related to the current row without collapsing the result set (unlike GROUP BY). They operate over a window defined by `OVER()`.
```sql
SELECT OrderId, CustomerId, Amount,
    SUM(Amount) OVER (PARTITION BY CustomerId ORDER BY OrderDate
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RunningTotal,
    LAG(Amount, 1) OVER (PARTITION BY CustomerId ORDER BY OrderDate) AS PrevAmount,
    RANK() OVER (PARTITION BY CustomerId ORDER BY Amount DESC) AS AmountRank
FROM Orders;
```
Key use cases: running totals, moving averages, top-N per group, gap/island analysis.

**Q: What are temporal tables?**
A: System-versioned temporal tables automatically track full history of data changes. SQL Server maintains a history table with `SysStartTime` and `SysEndTime` period columns. Query historical data with `FOR SYSTEM_TIME AS OF`, `BETWEEN`, `CONTAINED IN`, `FROM...TO`, `ALL`. Ideal for audit trails, point-in-time analysis, and slowly changing dimensions.

---

## 10. T-SQL Essentials

### Key Highlights

- **CTE (Common Table Expression)**: `WITH cte AS (...)` — improves readability, not performance (not materialized). Recursive CTEs for hierarchies.
- **MERGE**: Single statement for INSERT/UPDATE/DELETE (upsert). Use with caution — known concurrency issues, always use `WITH (HOLDLOCK)`.
- **APPLY**: `CROSS APPLY` (inner join behavior) and `OUTER APPLY` (left join behavior) — invoke table-valued function per row or correlate with subquery.
- **PIVOT/UNPIVOT**: Transform rows to columns and vice versa.
- **STRING_AGG** (2017+): Concatenate values with delimiter. Replaces `FOR XML PATH` workaround.
- **IIF / CHOOSE**: Shorthand for CASE expressions.
- **OFFSET-FETCH**: Paging: `ORDER BY col OFFSET 10 ROWS FETCH NEXT 10 ROWS ONLY`.

### Essential Q&A

**Q: Explain recursive CTEs with an example.**
A:
```sql
-- Employee hierarchy
WITH OrgChart AS (
    -- Anchor: top-level manager
    SELECT EmployeeId, Name, ManagerId, 0 AS Level
    FROM Employees WHERE ManagerId IS NULL
    UNION ALL
    -- Recursive: join children
    SELECT e.EmployeeId, e.Name, e.ManagerId, oc.Level + 1
    FROM Employees e INNER JOIN OrgChart oc ON e.ManagerId = oc.EmployeeId
)
SELECT * FROM OrgChart OPTION (MAXRECURSION 100);
```
Default MAXRECURSION is 100. Set to 0 for unlimited (use carefully). Great for hierarchies, bill of materials, graph traversal.

**Q: When do you use CROSS APPLY vs LEFT JOIN?**
A: Use CROSS APPLY when: (1) Calling a table-valued function per row. (2) You need correlated subquery returning multiple columns/rows. (3) Top-N per group patterns. CROSS APPLY filters out rows with no match (like INNER JOIN); OUTER APPLY keeps them (like LEFT JOIN).
```sql
-- Top 3 orders per customer
SELECT c.Name, o.OrderDate, o.Amount
FROM Customers c
CROSS APPLY (
    SELECT TOP 3 OrderDate, Amount
    FROM Orders WHERE CustomerId = c.CustomerId
    ORDER BY Amount DESC
) o;
```

**Q: How does MERGE work and what are the pitfalls?**
A:
```sql
MERGE dbo.Target AS t
USING dbo.Source AS s ON t.Id = s.Id
WHEN MATCHED THEN UPDATE SET t.Name = s.Name, t.Value = s.Value
WHEN NOT MATCHED BY TARGET THEN INSERT (Id, Name, Value) VALUES (s.Id, s.Name, s.Value)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
```
Pitfalls: Race conditions without `HOLDLOCK` hint (use `WITH (HOLDLOCK)` on target). Known bugs in older versions. Always end with semicolon. For high-concurrency upserts, separate INSERT/UPDATE with TRY-CATCH may be more reliable.

**Q: How do you implement efficient pagination?**
A:
```sql
-- Keyset pagination (fastest for large offsets)
SELECT TOP 10 * FROM Orders
WHERE OrderId > @LastOrderId ORDER BY OrderId;

-- OFFSET-FETCH (simpler but slower for large offsets)
SELECT * FROM Orders ORDER BY OrderId
OFFSET 1000 ROWS FETCH NEXT 10 ROWS ONLY;
```
OFFSET-FETCH must still scan and discard offset rows. Keyset pagination uses an index seek — constant performance regardless of page number.

**Q: Explain PIVOT and UNPIVOT with examples.**
A:
```sql
-- PIVOT: rows to columns
SELECT * FROM (
    SELECT Year, Quarter, Revenue FROM Sales
) src PIVOT (
    SUM(Revenue) FOR Quarter IN ([Q1], [Q2], [Q3], [Q4])
) pvt;

-- UNPIVOT: columns to rows
SELECT Year, Quarter, Revenue
FROM SalesPivoted UNPIVOT (
    Revenue FOR Quarter IN ([Q1], [Q2], [Q3], [Q4])
) unpvt;
```
For dynamic column names, use dynamic SQL to build the PIVOT column list.

**Q: What are temporal tables and how do you query them?**
A:
```sql
-- Create temporal table
CREATE TABLE Products (
    ProductId INT PRIMARY KEY,
    Name NVARCHAR(100),
    Price DECIMAL(10,2),
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START,
    SysEndTime DATETIME2 GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dbo.ProductsHistory));

-- Query data as of a specific time
SELECT * FROM Products FOR SYSTEM_TIME AS OF '2025-06-15T12:00:00';

-- Query all changes in a range
SELECT * FROM Products FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-12-31';
```

---

## 11. Migration & Modern Features

### Key Highlights

- **SQL Server 2016**: Query Store, temporal tables, JSON support, R integration, Always Encrypted, dynamic data masking, row-level security, stretch database, polybase.
- **SQL Server 2017**: Graph database, adaptive query processing (batch mode adaptive joins, interleaved execution), automatic tuning (plan regression correction), Linux support, Python integration.
- **SQL Server 2019**: Intelligent Query Processing (IQP) suite, batch mode on rowstore, memory grant feedback (row mode), table variable deferred compilation, scalar UDF inlining, accelerated database recovery (ADR), data virtualization with Polybase V2, UTF-8 support, tempdb metadata optimization.
- **SQL Server 2022**: Ledger tables, parameter-sensitive plan optimization (PSP), Query Store hints, degree of parallelism feedback, cardinality estimation feedback, contained availability groups, Azure Synapse Link, Polybase REST API, buffer pool parallel scan, `WINDOW` clause, `GENERATE_SERIES`, `DATE_BUCKET`, `GREATEST`/`LEAST`, `TRIM` enhancements.
- **Intelligent Query Processing**: Umbrella term for automatic optimizer improvements across 2017-2022. Requires no code changes — just raise database compatibility level.

### Essential Q&A

**Q: What is Intelligent Query Processing and what does it include?**
A: IQP is a family of features that improve query performance automatically, without code changes — just set the appropriate compatibility level. Key features: **Batch mode on rowstore** (compat 150) — batch processing without columnstore. **Adaptive joins** — switch between hash and nested loops at runtime. **Memory grant feedback** — adjusts memory grants based on actual usage. **Table variable deferred compilation** — accurate cardinality for table variables. **Scalar UDF inlining** — converts scalar functions to inline expressions. **Parameter-sensitive plan optimization** (compat 160) — multiple plans per query for different parameter ranges.

**Q: What is Accelerated Database Recovery (ADR)?**
A: ADR (SQL 2019+) redesigns the recovery process using a persistent version store (PVS) in the database. Benefits: (1) Near-instant rollback of long transactions. (2) Aggressive log truncation regardless of active transactions. (3) Fast database recovery after crash. Trade-off: additional storage for PVS, slight overhead for DML. Enable: `ALTER DATABASE [db] SET ACCELERATED_DATABASE_RECOVERY = ON`.

**Q: What are Ledger tables in SQL Server 2022?**
A: Ledger provides tamper-evidence for data. **Updatable ledger tables**: append-only history with cryptographic hashes. **Append-only ledger tables**: INSERT only, no UPDATE/DELETE. Both create a blockchain-like chain of hashes in a ledger view. Can verify data integrity with `sys.sp_verify_database_ledger`. Used for: compliance, audit, financial records, regulatory requirements.

**Q: How do you migrate from on-premises SQL Server to Azure SQL?**
A: (1) **Assessment**: Use Azure Migrate or Data Migration Assistant (DMA) to identify compatibility issues. (2) **Target selection**: Azure SQL Database (PaaS, single/elastic pool), Azure SQL Managed Instance (near-100% feature parity), or SQL Server on Azure VM (full compatibility). (3) **Migration**: Azure Database Migration Service (DMS) for online (minimal downtime) migration, or backup/restore for Managed Instance. (4) Key considerations: features not supported in Azure SQL DB (SQL Agent, cross-database queries, CLR), pricing model (DTU vs vCore), networking (VNet, private endpoints).

**Q: What is parameter-sensitive plan optimization (PSP) in SQL 2022?**
A: PSP addresses parameter sniffing by allowing the optimizer to generate multiple plans for the same query based on parameter value ranges. The optimizer identifies queries that are "sensitive" to parameter values and creates plan variants (dispatchers) that route to different cached plans based on the runtime parameter value. Requires compatibility level 160. Works automatically — no query hints or code changes needed.

**Q: What are Query Store hints (SQL 2022)?**
A: Query Store hints let you apply query hints to queries without modifying application code. Use `sys.sp_query_store_set_hints` to attach hints to a query by its `query_id`.
```sql
EXEC sys.sp_query_store_set_hints
    @query_id = 42,
    @query_hints = N'OPTION (MAXDOP 2, RECOMPILE)';
```
This is powerful for tuning third-party application queries you cannot modify. Hints are persisted in Query Store and survive restarts.

---

## Quick Numbers Reference

| Item | Value |
|---|---|
| Data page size | 8 KB (8,192 bytes) |
| Extent size | 64 KB (8 pages) |
| Max row size (in-row) | 8,060 bytes |
| Max columns per table | 1,024 (30,000 with sparse) |
| Max index key size | 900 bytes (1,700 for NC in 2016+) |
| Max indexes per table | 1 clustered + 999 non-clustered |
| Max columns in index key | 16 |
| Max partitions per table | 15,000 |
| Statistics histogram steps | 200 max |
| Lock escalation threshold | ~5,000 locks per object |
| Columnstore rowgroup size | ~1,048,576 rows |
| Batch mode batch size | ~900 rows |
| Max database size (Enterprise) | 524 PB |
| Max database size (Express) | 10 GB |
| Max memory (Express) | 1,410 MB buffer pool |
| Default MAXRECURSION | 100 |
| AG max replicas | 9 (1 primary + 8 secondary) |
| Default CDC retention | 3 days |
| TDE CPU overhead | ~3-5% |

---

*This reference is optimized for study and preparation. For deeper coverage of each topic, consult the individual detailed topic files.*
