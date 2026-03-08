# Advanced SQL Server - Q&A (Part 1: Architecture and Internals)

[Back to Index](README.md)

---

### Q1. How would you troubleshoot severe RESOURCE_SEMAPHORE waits affecting mortgage batch processing?

**Situation:** At a mortgage servicer processing Fannie Mae and Freddie Mac loan deliveries, our nightly batch that computed borrower payment histories across 200M+ loans started queuing. Operators reported jobs piling up after midnight. SQL Server DMVs showed hundreds of sessions in RESOURCE_SEMAPHORE wait, meaning queries were waiting for memory grants before they could even begin execution.

**Task:** Identify why memory grants were being exhausted and restore the nightly batch SLA of completing within a 4-hour window before the upstream Intex CDI feed arrived at 5 AM.

**Action:** I started by capturing the current memory grant landscape and identifying the offending queries:
```sql
-- Snapshot of pending and active memory grants
SELECT session_id, request_time, grant_time, requested_memory_kb,
       granted_memory_kb, required_memory_kb, wait_time_ms, queue_id,
       t.text AS query_text, qp.query_plan
FROM sys.dm_exec_query_memory_grants mg
CROSS APPLY sys.dm_exec_sql_text(mg.sql_handle) t
CROSS APPLY sys.dm_exec_query_plan(mg.plan_handle) qp
ORDER BY requested_memory_kb DESC;
```
I discovered three problems: (1) A poorly written loan-level pivot query requesting 4 GB grants each due to massively overestimated row counts—the statistics on the `LoanPerformance` table were stale because we only did a weekly stats update. (2) Resource Governor was not configured, so ad-hoc analytical queries from the risk team were competing with batch workloads. (3) `max server memory` was set to the OS default, leaving only 4 GB for a 128 GB server. I updated statistics with `FULLSCAN` on the key partitions, implemented Resource Governor with two workload groups—`BatchProcessing` (70% memory cap) and `AdHocAnalytics` (25% cap)—and set `max server memory` to 112 GB. I also refactored the pivot query to use `CROSS APPLY` with a pre-aggregated CTE, dropping the grant requirement from 4 GB to 180 MB.

**Result:** RESOURCE_SEMAPHORE waits dropped to zero. The nightly batch completed in 2.5 hours (down from 6+ hours with timeouts). Memory grant wait time across all sessions fell from an average of 45 seconds to under 200 ms. The risk team's ad-hoc queries also stabilized because Resource Governor prevented them from starving batch processes.

**AI Vision:** Snowflake Cortex Anomaly Detection could monitor memory grant patterns in real time and predict RESOURCE_SEMAPHORE events before they cascade. An Azure ML model trained on historical DMV snapshots could recommend optimal Resource Governor pool percentages as workload mixes shift seasonally—e.g., heavier analytics during quarter-end GSE reporting cycles.

---

### Q2. Explain how you optimized buffer pool usage for a database storing 500M+ loan records.

**Situation:** A secondary market analytics platform held 500M+ residential loan records spanning 20 years of Fannie Mae, Freddie Mac, and Ginnie Mae performance data. The buffer pool hit ratio had degraded to 88% on a 256 GB server, causing excessive physical reads during CoreLogic property valuation joins and prepayment model queries.

**Task:** Increase the buffer pool hit ratio above 99% and reduce physical I/O to ensure sub-second response times for the interactive dashboard used by MBS traders.

**Action:** I first profiled what was actually sitting in the buffer pool:
```sql
-- Identify which objects dominate the buffer pool
SELECT o.name AS object_name, i.name AS index_name, i.type_desc,
       COUNT(*) * 8 / 1024 AS cached_mb,
       SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END) AS dirty_pages
FROM sys.dm_os_buffer_descriptors bd
JOIN sys.allocation_units au ON bd.allocation_unit_id = au.allocation_unit_id
JOIN sys.partitions p ON au.container_id = p.hobt_id
JOIN sys.objects o ON p.object_id = o.object_id
JOIN sys.indexes i ON p.object_id = i.object_id AND p.index_id = i.index_id
WHERE bd.database_id = DB_ID('MBSAnalytics')
GROUP BY o.name, i.name, i.type_desc
ORDER BY cached_mb DESC;
```
I found that a rarely-used archive index on `LoanOrigination_Archive` was consuming 60 GB of buffer pool. I moved that table to a separate filegroup and created a filtered nonclustered index covering only active vintages (2018–2026). I also implemented columnstore indexes on the `MonthlyPerformance` fact table, which compressed 380 GB down to 52 GB, allowing far more data to fit in memory. For the CoreLogic property join, I created an indexed view pre-joining the FIPS-level data to avoid repeated large hash joins polluting the buffer pool.

**Result:** Buffer pool hit ratio climbed to 99.7%. Physical reads dropped by 91%. The trader dashboard query P95 latency went from 3.2 seconds to 280 ms. The columnstore compression also saved 328 GB of disk, reducing storage costs by $14K/year on the SAN.

**AI Vision:** An LLM-driven index advisor (powered by Azure OpenAI) could continuously analyze buffer pool composition and workload patterns, recommending index consolidation or columnstore migration candidates. Snowflake Cortex could provide natural-language queries over the same dataset, offloading exploratory analytics entirely from the SQL Server tier.

---

### Q3. How do you handle tempdb contention during month-end MBS pool factor calculations?

**Situation:** Every month-end, the agency MBS operations team ran pool factor calculations across 50,000+ Ginnie Mae and Fannie Mae pools. The process used massive `GROUP BY` aggregations with spills, table variables, and temporary staging tables. We observed severe latch contention on PFS, GAM, and SGAM pages in tempdb—`PAGELATCH_UP` and `PAGELATCH_EX` waits spiked to 800 ms average.

**Task:** Eliminate tempdb contention so pool factor calculations could complete within the 2-hour window required for next-day settlement reporting to DTCC.

**Action:** I attacked this at multiple levels. First, hardware configuration:
```sql
-- Verify tempdb file count vs. logical CPUs (target: 1 file per core, up to 8)
SELECT name, physical_name, size * 8 / 1024 AS size_mb
FROM sys.master_files WHERE database_id = 2;

-- We had 1 file on a 16-core server. Added 7 more equally sized files:
ALTER DATABASE tempdb ADD FILE (NAME = 'tempdev2', FILENAME = 'T:\tempdb\tempdev2.ndf', SIZE = 8192MB, FILEGROWTH = 1024MB);
-- ... repeated for tempdev3 through tempdev8
```
I enabled trace flag 1118 (uniform extent allocation) and TF 1117 (equal file growth). Second, I refactored the pool factor stored procedures: replaced table variables with temp tables (so the optimizer could see row counts), added appropriate indexes on `#PoolStaging`, and converted the largest spilling sort into a pre-sorted CTE using a covering index. Third, I moved the sort spill–heavy queries to use `OPTION (MIN_GRANT_PERCENT = 5, MAX_GRANT_PERCENT = 15)` to right-size memory grants and avoid spills altogether.

**Result:** `PAGELATCH` waits on tempdb allocation pages dropped from 800 ms average to under 2 ms. Pool factor calculation runtime fell from 3.5 hours to 48 minutes. The operations team could publish factors to Bloomberg and DTCC well before the 7 AM cutoff. Tempdb throughput as measured by `sys.dm_io_virtual_file_stats` improved by 12x.

**AI Vision:** A Cortex-powered forecasting model could predict month-end tempdb pressure based on pool count growth and preemptively scale tempdb files or shift workloads. Azure AI could auto-classify which stored procedures are tempdb-heavy and suggest rewrites to minimize spill probability.

---

### Q4. Describe your approach to designing a partitioning strategy for loan performance time-series data.

**Situation:** We maintained a `LoanMonthlyPerformance` table receiving 40M rows per month from Fannie Mae and Freddie Mac monthly loan-level disclosures. The table held 8 years of history (3.8 billion rows). Queries typically filtered by `ReportingPeriod` (month) and `PoolID`. Full table scans during vintage analysis took 45+ minutes, and partition-switching for new data loads was not possible because the table was a heap.

**Task:** Design and implement a partitioning strategy that enabled instant data loads via partition switching, sub-second partition elimination for time-range queries, and efficient archival of aged data.

**Action:** I designed a monthly partition scheme on `ReportingPeriod` (date):
```sql
CREATE PARTITION FUNCTION pf_ReportingMonth (DATE)
AS RANGE RIGHT FOR VALUES ('2018-01-01','2018-02-01', ... ,'2026-12-01');

CREATE PARTITION SCHEME ps_ReportingMonth
AS PARTITION pf_ReportingMonth TO
  (FG_Archive, FG_2018, FG_2018, ... , FG_Current, FG_Future);
```
I placed older vintages (pre-2022) on slower archive storage filegroups and current data on NVMe-backed filegroups. The clustered index was `(ReportingPeriod, LoanID)` to align with the partition key and the dominant query pattern. For monthly loads, I built a staging table on the `FG_Future` filegroup with identical schema and constraints, bulk-inserted the new month's data, then used `ALTER TABLE ... SWITCH PARTITION` for an instantaneous metadata-only operation. I also created aligned nonclustered columnstore indexes for analytical aggregation queries (CPR, CDR, severity calculations). For archival, I used `SWITCH PARTITION` to move data older than 7 years into an archive table on compressed filegroups, then marked those filegroups `READONLY`.

**Result:** Monthly data loads went from a 90-minute INSERT operation to a sub-second partition switch. Vintage analysis queries that previously scanned 3.8B rows now scanned only relevant partitions—query time dropped from 45 minutes to 22 seconds. Archive filegroups marked READONLY were excluded from backups, reducing backup time by 60% and saving 4 TB of backup storage.

**AI Vision:** Snowflake Cortex could run prepayment and default prediction models (CPR/CDR) directly against time-series partitions using built-in ML functions, eliminating ETL to a separate ML platform. An LLM agent could generate partition maintenance scripts automatically based on natural-language policies like "archive anything older than 7 years and compress it."

---

### Q5. How would you investigate and resolve WRITELOG waits during high-volume loan tape imports?

**Situation:** A loan aggregator received daily loan tape files from 30+ correspondent lenders—each file containing 50K–500K loan records. During the 6 PM–10 PM import window, `WRITELOG` waits averaged 35 ms per flush, and the transaction log on the `LoanAcquisition` database grew to 200 GB despite simple recovery model. The imports fed downstream Fannie Mae Loan Delivery processes and had a hard deadline.

**Task:** Reduce `WRITELOG` waits below 2 ms and ensure all loan tapes were imported and validated within the 4-hour window.

**Action:** I diagnosed the I/O subsystem and log configuration:
```sql
-- Check write latency on log files
SELECT database_id, file_id, io_stall_write_ms, num_of_writes,
       io_stall_write_ms / NULLIF(num_of_writes, 0) AS avg_write_latency_ms
FROM sys.dm_io_virtual_file_stats(DB_ID('LoanAcquisition'), NULL)
WHERE file_id = 2; -- log file

-- Check VLF count
DBCC LOGINFO('LoanAcquisition'); -- returned 2,400 VLFs
```
The root causes were: (1) the log file was on a shared SAN LUN with other databases, (2) the log had 2,400 VLFs from repeated autogrowth events at 64 MB increments, and (3) each loan record was inserted in its own transaction (row-by-row from an SSIS package). I moved the log to a dedicated NVMe-backed LUN with write-back caching. I shrunk and regrew the log file in a single 50 GB allocation to consolidate VLFs down to 64. I refactored the SSIS packages to use `BULK INSERT` with batch sizes of 50,000 rows, wrapping each batch in an explicit transaction. I also enabled delayed durability for the staging phase (acceptable because the source files were idempotent and reloadable):
```sql
ALTER DATABASE LoanAcquisition SET DELAYED_DURABILITY = ALLOWED;
-- In the import proc:
BEGIN TRANSACTION; ... COMMIT WITH (DELAYED_DURABILITY = ON);
```

**Result:** Average `WRITELOG` latency dropped from 35 ms to 0.8 ms. VLF consolidation eliminated log management overhead. The import window shrank from 3.5 hours to 55 minutes. Transaction log peak size dropped from 200 GB to 18 GB because batched transactions reduced log record volume.

**AI Vision:** An Azure AI anomaly detector monitoring `sys.dm_io_virtual_file_stats` in real time could alert on write latency degradation before it impacts SLAs. An LLM-based code reviewer could analyze SSIS packages and automatically flag row-by-row anti-patterns, suggesting batch alternatives with generated T-SQL.

---

### Q6. Explain checkpoint tuning for a high-transaction loan processing system.

**Situation:** A mortgage loan origination system (LOS) processed 3,000 loans/day, each generating 200+ database transactions (credit pulls, AUS submissions, lock confirmations, disclosures). During checkpoint operations, the system experienced I/O storms—dirty page flushes caused 5-second query freezes visible to loan officers on the front-end. Recovery interval was at the default (0, targeting ~1 minute), and indirect checkpoints were not enabled.

**Task:** Smooth out checkpoint I/O to eliminate user-visible latency spikes while maintaining an acceptable recovery time objective (RTO) of under 60 seconds.

**Action:** I first measured the checkpoint impact:
```sql
-- Monitor checkpoint duration and pages flushed
SELECT checkpoint_begin_time, checkpoint_end_time, pages_flushed,
       DATEDIFF(ms, checkpoint_begin_time, checkpoint_end_time) AS duration_ms
FROM sys.dm_db_checkpoint_stats WHERE database_id = DB_ID('LoanOrigination');

-- Check dirty page ratio in buffer pool
SELECT COUNT(*) AS total_pages,
       SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END) AS dirty_pages,
       CAST(SUM(CASE WHEN is_modified = 1 THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS dirty_pct
FROM sys.dm_os_buffer_descriptors WHERE database_id = DB_ID('LoanOrigination');
```
Dirty page ratio was hitting 40% before each checkpoint, causing massive flush storms. I switched to indirect checkpoints with a target recovery time of 40 seconds, which spreads dirty page writes continuously rather than in bursts:
```sql
ALTER DATABASE LoanOrigination SET TARGET_RECOVERY_TIME = 40 SECONDS;
```
I also moved the data files to storage with consistent write performance (NVMe) and increased the checkpoint worker threads by ensuring `max worker threads` was appropriately sized. I tuned the background writer aggressiveness by monitoring `sys.dm_os_wait_stats` for `HADR_FILESTREAM_IOMGR_IOCOMPLETION` and `LAZY_WRITER_SLEEP` to ensure the lazy writer wasn't competing with checkpoint.

**Result:** I/O spikes during checkpoint disappeared. Max query latency during checkpoint windows dropped from 5 seconds to 120 ms. The dirty page ratio stabilized at 8–12% due to continuous background flushing. Recovery time in a simulated crash test was 32 seconds, well within the 60-second RTO. Loan officers reported zero "screen freeze" complaints after deployment.

**AI Vision:** Azure AI could build a predictive model correlating transaction volume (e.g., rate-lock surges after Fed announcements) with dirty page accumulation, dynamically adjusting `TARGET_RECOVERY_TIME` before spikes occur. Cortex ML could identify which tables generate the most dirty pages and recommend in-memory OLTP migration for hot tables.

---

### Q7. How do you architect SQL Server memory configuration for mixed OLTP/analytical mortgage workloads?

**Situation:** A mid-size mortgage lender ran both the loan origination OLTP system and a secondary market analytics warehouse on the same 512 GB SQL Server instance (budget constraints prevented separate servers). The OLTP workload (lock desks, pipeline management) needed sub-50ms response times, while the analytics workload (prepayment modeling, MSR valuation, Intex deal cashflow projections) ran large hash joins and sorts requiring multi-GB memory grants. The two workloads fought for memory, causing intermittent OLTP timeouts during analytics runs.

**Task:** Architect memory configuration to guarantee OLTP responsiveness while allowing analytics to use available memory without starvation.

**Action:** I implemented a layered memory governance strategy:
```sql
-- Set max server memory, reserving 32 GB for OS and CLR
EXEC sp_configure 'max server memory', 480000; RECONFIGURE;

-- Resource Governor: two pools with hard boundaries
CREATE RESOURCE POOL OLTPPool WITH (MIN_MEMORY_PERCENT = 40, MAX_MEMORY_PERCENT = 60);
CREATE RESOURCE POOL AnalyticsPool WITH (MIN_MEMORY_PERCENT = 20, MAX_MEMORY_PERCENT = 55);

CREATE WORKLOAD GROUP OLTPGroup USING OLTPPool;
CREATE WORKLOAD GROUP AnalyticsGroup
  WITH (REQUEST_MAX_MEMORY_GRANT_PERCENT = 25, GROUP_MAX_REQUESTS = 8)
  USING AnalyticsPool;

-- Classifier function routes by application name
CREATE FUNCTION dbo.fn_ResourceClassifier() RETURNS SYSNAME WITH SCHEMABINDING
AS BEGIN
  RETURN CASE WHEN APP_NAME() LIKE '%LOS%' THEN 'OLTPGroup'
              WHEN APP_NAME() LIKE '%Analytics%' THEN 'AnalyticsGroup'
              ELSE 'default' END;
END;
ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.fn_ResourceClassifier);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```
I also enabled lock pages in memory (LPIM) via Windows policy to prevent the OS from paging out SQL Server's buffer pool under pressure. For the analytics workload, I set `REQUEST_MAX_MEMORY_GRANT_PERCENT = 25` to prevent any single query from monopolizing the pool, and `GROUP_MAX_REQUESTS = 8` to limit concurrency. I configured `cost threshold for parallelism` at 50 to prevent small OLTP queries from going parallel, and set `MAXDOP = 4` for the analytics group via Resource Governor.

**Result:** OLTP P99 latency stabilized at 38 ms regardless of analytics activity (previously spiked to 4 seconds). Analytics queries had predictable memory grants and no longer experienced RESOURCE_SEMAPHORE waits. MSR valuation models that previously timed out now completed reliably in 12 minutes. The architecture supported the combined workload for 2 years until budget allowed migration of analytics to Snowflake.

**AI Vision:** Azure OpenAI could power a natural-language interface for the analytics team, translating questions like "What is the projected CPR for 2024 vintage 30-year 6.5% pools?" into optimized SQL routed to the AnalyticsGroup. Snowflake Cortex could eventually absorb the analytical workload entirely, using AI-driven query optimization with zero memory tuning required.

---

### Q8. Describe how you'd use DBCC PAGE and sys.dm_os_buffer_descriptors to diagnose storage issues in loan databases.

**Situation:** A loan servicing database experienced intermittent data corruption alerts—`DBCC CHECKDB` reported consistency errors on the `PaymentHistory` table, which stored 1.2 billion payment records across GSE-serviced loans. The storage team claimed the SAN was healthy, but we suspected silent bit-rot or firmware bugs on the storage controller.

**Task:** Definitively identify whether corruption was at the SQL Server page level, the storage subsystem level, or caused by torn writes, and remediate without data loss.

**Action:** I started by examining the specific corrupted pages reported by CHECKDB:
```sql
-- Identify suspect pages from msdb
SELECT * FROM msdb.dbo.suspect_pages WHERE database_id = DB_ID('LoanServicing');

-- Examine a corrupted page header and content
DBCC TRACEON(3604); -- output to console
DBCC PAGE('LoanServicing', 1, 8675309, 3); -- header + row details
-- Checked: m_tornBits, m_lsn, page checksum vs. stored checksum
```
The page header showed torn bit mismatches—indicating that writes were not atomic. I then cross-referenced with buffer pool state to see if corrupted pages were currently cached:
```sql
SELECT bd.page_id, bd.page_type, bd.is_modified, bd.read_microsec
FROM sys.dm_os_buffer_descriptors bd
WHERE bd.database_id = DB_ID('LoanServicing')
  AND bd.page_id IN (8675309, 8675310, 8675311);
```
Pages in the buffer pool had valid checksums—corruption was occurring during write-to-disk, not in memory. I verified that `PAGE_VERIFY` was set to `CHECKSUM` (it was set to `TORN_PAGE_DETECTION`, a legacy setting). I worked with the SAN team to update the controller firmware, enabled battery-backed write cache, and changed the verify setting:
```sql
ALTER DATABASE LoanServicing SET PAGE_VERIFY CHECKSUM;
```
I restored the corrupted pages from the most recent clean backup using `RESTORE DATABASE ... PAGE = '1:8675309'` with log tail backup to bring them current.

**Result:** Page-level restore recovered all corrupted payment records with zero data loss—no need for a full restore of the 2.8 TB database. After firmware update and CHECKSUM verification, zero corruption events in the following 18 months. The diagnostic approach (DBCC PAGE + buffer descriptor analysis) conclusively proved the storage layer was at fault, giving the infrastructure team the evidence needed to prioritize the firmware upgrade.

**AI Vision:** An LLM-based diagnostic assistant could automate the DBCC PAGE analysis workflow—given a suspect page list, it could automatically extract headers, compare checksums, cross-reference buffer pool state, and produce a root cause report in plain English. Azure AI Anomaly Detector could monitor page verification failures in real time and correlate them with storage subsystem telemetry.

---

### Q9. How would you design a filegroup strategy for a multi-terabyte MBS analytics database?

**Situation:** We built a 12 TB MBS analytics database housing deal-level cashflow projections from Intex, loan-level performance data from GSE disclosures, and CoreLogic property valuations. Everything was in the PRIMARY filegroup on a single LUN. Backups took 14 hours, restores took 18 hours (unacceptable RTO), and I/O contention between OLTP inserts and analytical scans was severe.

**Task:** Design a filegroup architecture that enabled fast partial backups, I/O isolation, efficient storage tiering, and sub-4-hour RTO for critical data.

**Action:** I designed a five-tier filegroup architecture mapped to data lifecycle and access patterns:
```sql
-- Hot data: current deals and recent 2 years of loan performance (NVMe)
ALTER DATABASE MBSAnalytics ADD FILEGROUP FG_Hot;
ALTER DATABASE MBSAnalytics ADD FILE (NAME='Hot_01', FILENAME='N:\data\hot_01.ndf', SIZE=500GB) TO FILEGROUP FG_Hot;
ALTER DATABASE MBSAnalytics ADD FILE (NAME='Hot_02', FILENAME='N:\data\hot_02.ndf', SIZE=500GB) TO FILEGROUP FG_Hot;

-- Warm data: 2-5 year historical performance (SAS SSD)
ALTER DATABASE MBSAnalytics ADD FILEGROUP FG_Warm;

-- Cold data: 5+ year archive, compressed (SAS HDD)
ALTER DATABASE MBSAnalytics ADD FILEGROUP FG_Cold;

-- Columnstore: dedicated filegroup for analytical columnstore indexes
ALTER DATABASE MBSAnalytics ADD FILEGROUP FG_Columnstore;

-- Staging: high-throughput landing zone for Intex/CoreLogic feeds
ALTER DATABASE MBSAnalytics ADD FILEGROUP FG_Staging;
```
I moved tables using partitioned views and `CREATE CLUSTERED INDEX ... WITH (DROP_EXISTING=ON) ON FG_xxx` for non-partitioned tables. Partitioned tables used partition schemes mapped across filegroups by date range. Backup strategy leveraged filegroup backups:
```sql
-- Hot filegroup: full backup daily (1 TB, ~45 min)
BACKUP DATABASE MBSAnalytics FILEGROUP = 'FG_Hot' TO DISK = '...';
-- Cold filegroup: READONLY, backed up once after marking readonly
ALTER DATABASE MBSAnalytics MODIFY FILEGROUP FG_Cold READONLY;
```
I placed two data files per filegroup to enable proportional fill and parallelized I/O. The staging filegroup used simple recovery model semantics via bulk-logged operations.

**Result:** Full backup time dropped from 14 hours to 45 minutes for the critical hot tier. RTO for critical data went from 18 hours to 2 hours (restore hot + warm only). I/O throughput improved 3x because NVMe, SSD, and HDD tiers were no longer contending on the same LUN. Analytical columnstore scans on the dedicated filegroup stopped interfering with OLTP inserts on the hot tier. Total storage cost dropped 30% by moving 8 TB of cold data to cheaper HDD storage.

**AI Vision:** Snowflake's automatic storage tiering eliminates manual filegroup management entirely—a migration path for this workload. In the SQL Server world, an AI agent could monitor access patterns via `sys.dm_db_index_usage_stats` and automatically recommend data movement between hot/warm/cold tiers, generating the migration scripts via LLM.

---

### Q10. Explain your approach to monitoring and optimizing I/O patterns for mortgage data warehouses.

**Situation:** A mortgage data warehouse supporting Freddie Mac Loan Advisor, risk analytics, and regulatory reporting (HMDA, Call Reports) exhibited unpredictable I/O performance. Some queries completed in seconds while identical queries took minutes at different times. The 8 TB database sat on a SAN with 200K IOPS capacity, but actual utilization patterns were unknown. Business users lost confidence in the platform.

**Task:** Build a comprehensive I/O monitoring framework, identify optimization opportunities, and deliver consistent query performance with P95 latency guarantees.

**Action:** I built a multi-layer monitoring and optimization approach. First, I created a baseline capture job:
```sql
-- Capture I/O stats every 5 minutes into a monitoring table
INSERT INTO dba.IOBaseline (capture_time, database_id, file_id, file_type,
    reads, writes, read_bytes, write_bytes, read_latency_ms, write_latency_ms)
SELECT GETDATE(), database_id, file_id,
    CASE WHEN file_id = 2 THEN 'LOG' ELSE 'DATA' END,
    num_of_reads, num_of_writes, num_of_bytes_read, num_of_bytes_written,
    io_stall_read_ms / NULLIF(num_of_reads,0),
    io_stall_write_ms / NULLIF(num_of_writes,0)
FROM sys.dm_io_virtual_file_stats(NULL, NULL);
```
After two weeks of baselining, I identified the patterns: (1) Read latency spiked to 45 ms during the 2 AM Freddie Mac Loan Performance load because bulk inserts and concurrent index rebuilds saturated the write queue. (2) HMDA reporting queries did full columnstore scans that displaced hot OLTP pages from the buffer pool. (3) Random I/O from missing index seeks on `PropertyValuation.FIPS_Code` caused 300K random reads/hour. I separated the bulk load window from index maintenance using Agent jobs. I added the missing nonclustered index, converting 300K random reads into 4K sequential reads. I implemented read-ahead optimization by ensuring queries used large sequential scans with `OPTION (MAXDOP 4)` for reporting, and I configured storage QoS on the SAN to guarantee minimum IOPS per LUN.

**Result:** Read latency P95 dropped from 45 ms to 4 ms. Write latency P95 dropped from 22 ms to 3 ms. The missing index alone reduced daily I/O volume by 2.1 TB of unnecessary reads. Query performance became consistent—P95 latency for HMDA reports went from 180 seconds to 11 seconds. The monitoring framework caught three subsequent storage degradation events before users noticed, enabling proactive SAN maintenance.

**AI Vision:** Azure AI could consume the I/O baseline data and build a predictive model for I/O saturation—forecasting when latency will breach SLA thresholds based on scheduled workloads and seasonal patterns (e.g., quarter-end regulatory reporting surges). An LLM agent integrated with the monitoring framework could auto-generate incident reports, suggest index changes, and even open storage team tickets when latency anomalies correlate with SAN metrics rather than SQL Server workload changes.
