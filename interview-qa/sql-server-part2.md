# Advanced SQL Server - Q&A (Part 2: Query Optimization and Indexing)

[Back to Index](README.md)

---

### Q11. How do you approach tuning a query that joins loan-level data across 10+ tables with 100M+ rows?

**Situation:** Our Fannie Mae loan performance reporting system joined `LoanMaster`, `MonthlyPerformance`, `PropertyValuation`, `BorrowerCredit`, `Servicer`, `Pool`, `Tranche`, `CashFlow`, `Delinquency`, `Modification`, and `Disposition` tables. The nightly job producing investor-facing reports was running 4+ hours, breaching the SLA window. The `MonthlyPerformance` table alone held 380M rows spanning 15 years of history.

**Task:** Reduce the execution time to under 45 minutes while maintaining data accuracy for GSE regulatory reporting.

**Action:** I started by capturing the actual execution plan and identifying the costliest operators. The plan showed hash joins spilling to tempdb because of cardinality estimation errors on multi-column joins. I took a layered approach:

```sql
-- Step 1: Broke the monolith into staged CTEs with materialization hints
-- and replaced the 10-way join with incremental builds
WITH ActiveLoans AS (
    SELECT LoanID, PoolID, CurrentUPB, LoanStatus
    FROM dbo.LoanMaster WITH (INDEX(IX_LoanMaster_Status_Pool))
    WHERE LoanStatus IN ('C','3','6','9')  -- Current, 30/60/90 DPD
),
RecentPerformance AS (
    SELECT lp.LoanID, lp.ReportingPeriod, lp.ActualUPB, lp.DaysDelinquent
    FROM dbo.MonthlyPerformance lp
    INNER JOIN ActiveLoans al ON lp.LoanID = al.LoanID
    WHERE lp.ReportingPeriod >= DATEADD(MONTH, -24, GETDATE())
)
-- Continue building incrementally, filtering early...

-- Step 2: Created covering indexes to eliminate key lookups
CREATE NONCLUSTERED INDEX IX_MonthlyPerf_Loan_Period
ON dbo.MonthlyPerformance (LoanID, ReportingPeriod)
INCLUDE (ActualUPB, DaysDelinquent, InterestRate)
WITH (DATA_COMPRESSION = PAGE, ONLINE = ON);

-- Step 3: Added OPTION hints to stabilize the plan
OPTION (HASH JOIN, MAXDOP 8, RECOMPILE);
```

I also partitioned `MonthlyPerformance` by `ReportingPeriod` year-month so joins could leverage partition elimination. Staging intermediate results into indexed temp tables for the largest joins allowed the optimizer to produce accurate cardinality estimates for subsequent operations.

**Result:** Total runtime dropped from 4.2 hours to 28 minutes. Tempdb spills were eliminated entirely, logical reads decreased by 73%, and the batch consistently finished 90 minutes before the SLA deadline. The approach was adopted as our standard pattern for all multi-table GSE reporting queries.

**AI Vision:** An ML-driven query advisor could analyze historical execution plans, detect recurring spill patterns, and auto-suggest materialization boundaries. A reinforcement learning agent could test different join order permutations on a shadow copy to find the optimal plan without manual trial-and-error.

---

### Q12. Describe a scenario where parameter sniffing caused production issues in your loan reporting system.

**Situation:** Our stored procedure `usp_GetPoolPerformance` accepted `@PoolID` and `@ReportDate` parameters and was used by both on-demand analyst queries (single pool, ~500 loans) and batch reporting jobs (mega-pools with 150K+ loans). One Monday morning, the batch job that normally completed in 12 minutes suddenly ran for 3.5 hours. The procedure had been recompiled over the weekend after a statistics update, and the first execution came from an analyst querying a tiny test pool of 8 loans.

**Task:** Restore batch performance immediately and implement a permanent fix preventing recurrence for this and 40+ similar procedures.

**Action:** I confirmed parameter sniffing by checking the plan cache:

```sql
-- Identified the sniffed values vs runtime values
SELECT qs.plan_handle, qp.query_plan,
       TRY_CONVERT(XML, p.value).value('(@ParameterCompiledValue)[1]','NVARCHAR(50)') AS SniffedValue,
       TRY_CONVERT(XML, p.value).value('(@ParameterRuntimeValue)[1]','NVARCHAR(50)') AS RuntimeValue
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
CROSS APPLY STRING_SPLIT(CONVERT(NVARCHAR(MAX), qp.query_plan), '<ColumnReference') p
WHERE qp.query_plan LIKE '%usp_GetPoolPerformance%';

-- Immediate fix: cleared the bad plan
DBCC FREEPROCCACHE(0x06000700A1C2B230...);

-- Permanent solution: OPTIMIZE FOR UNKNOWN on volatile parameters,
-- combined with dynamic branching for dramatically different data shapes
CREATE OR ALTER PROCEDURE dbo.usp_GetPoolPerformance
    @PoolID VARCHAR(20), @ReportDate DATE
AS
BEGIN
    DECLARE @LoanCount INT;
    SELECT @LoanCount = COUNT(*) FROM dbo.PoolLoans WHERE PoolID = @PoolID;

    IF @LoanCount > 10000
        EXEC dbo.usp_GetPoolPerformance_Large @PoolID, @ReportDate;
    ELSE
        EXEC dbo.usp_GetPoolPerformance_Small @PoolID, @ReportDate;
END;
```

The "Large" variant used batch-mode processing with hash joins and parallelism, while the "Small" variant used nested-loop plans optimized for OLTP-style access. I also enabled Query Store plan forcing for the top 10 most critical procedures as a safety net.

**Result:** Batch job immediately returned to 11-minute runtime. Over the next quarter, zero parameter sniffing incidents occurred across the 40+ refactored procedures. Analyst queries also improved because they no longer inherited plans optimized for batch workloads. The pattern became a best practice documented in our team's SQL development standards.

**AI Vision:** An anomaly detection model trained on plan cache telemetry could detect when a cached plan's estimated vs. actual row counts diverge beyond a threshold, triggering automatic plan eviction or forcing before users notice degradation.

---

### Q13. How would you design an indexing strategy for a Fannie Mae loan-level dataset with 50+ columns?

**Situation:** We ingested Fannie Mae's Single-Family Loan-Level Dataset -- approximately 55 columns per record across origination and performance files. The origination table held 42M loans and the monthly performance table exceeded 900M rows. Analysts ran ad-hoc queries filtering on any combination of `OrigDate`, `State`, `CreditScore`, `LTV`, `LoanPurpose`, `PropertyType`, `SellerName`, and more. Index bloat had grown to 3.2x the data size, yet key queries still scanned.

**Task:** Redesign the indexing strategy to support diverse query patterns while keeping index storage under 1.5x data size and maintaining sub-second response for the 20 most common query patterns.

**Action:** I started with a data-driven approach rather than guessing:

```sql
-- Mined actual query patterns from Query Store
SELECT TOP 50
    qsq.query_hash,
    SUBSTRING(qt.query_sql_text, 1, 200) AS query_pattern,
    SUM(rs.count_executions) AS total_executions,
    AVG(rs.avg_logical_io_reads) AS avg_reads,
    AVG(rs.avg_duration) / 1000000.0 AS avg_duration_sec
FROM sys.query_store_query qsq
JOIN sys.query_store_query_text qt ON qsq.query_text_id = qt.query_text_id
JOIN sys.query_store_plan qsp ON qsq.query_id = qsp.query_id
JOIN sys.query_store_runtime_stats rs ON qsp.plan_id = rs.plan_id
WHERE qt.query_sql_text LIKE '%FannieLoanOrigination%'
GROUP BY qsq.query_hash, SUBSTRING(qt.query_sql_text, 1, 200)
ORDER BY SUM(rs.count_executions) * AVG(rs.avg_logical_io_reads) DESC;

-- Designed a tiered index strategy:
-- Tier 1: Clustered columnstore for bulk analytics (the dominant workload)
CREATE CLUSTERED COLUMNSTORE INDEX CCI_FanniePerformance
ON dbo.FannieMonthlyPerformance
WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE, MAXDOP = 8);

-- Tier 2: Targeted B-tree indexes for point lookups and operational queries
CREATE NONCLUSTERED INDEX IX_Orig_State_Score
ON dbo.FannieLoanOrigination (State, CreditScoreBucket)
INCLUDE (LoanAmount, OrigDate, LTV)
WHERE CreditScoreBucket IS NOT NULL
WITH (DATA_COMPRESSION = PAGE);

-- Tier 3: Dropped 18 redundant/overlapping indexes identified via:
SELECT i.name, ius.user_seeks, ius.user_scans, ius.user_updates
FROM sys.dm_db_index_usage_stats ius
JOIN sys.indexes i ON ius.object_id = i.object_id AND ius.index_id = i.index_id
WHERE ius.database_id = DB_ID() AND ius.user_seeks + ius.user_scans = 0
  AND ius.user_updates > 1000;
```

I bucketed `CreditScore` into ranges (300-579, 580-669, 670-739, 740+) as a computed column to reduce index key cardinality and improve seek efficiency.

**Result:** Index storage dropped from 3.2x to 1.1x data size. The top 20 queries averaged 0.4 seconds (down from 8.2 seconds). The columnstore index enabled batch-mode processing that cut aggregate analytics by 92%. Monthly data loads also sped up by 40% due to fewer indexes to maintain.

**AI Vision:** An automated index tuning agent could continuously analyze workload patterns, simulate index candidates using hypothetical indexes (`DBCC AUTOPILOT`), and propose additions/removals via a CI/CD pipeline with A/B testing on a read replica before promoting to production.

---

### Q14. Explain how you used Query Store to identify and fix plan regressions in prepayment calculation procedures.

**Situation:** Our prepayment speed calculation engine (`usp_CalcCPR_SMM`) modeled Conditional Prepayment Rate and Single Monthly Mortality across 12M active Ginnie Mae GNMA-II loans. After a SQL Server cumulative update, the procedure's runtime jumped from 6 minutes to 47 minutes. No code changes had been deployed -- the regression was purely plan-related.

**Task:** Identify the exact plan regression, restore performance, and build a monitoring framework to catch future regressions within minutes rather than hours.

**Action:**

```sql
-- Identified the regression point using Query Store
SELECT qsp.plan_id, qsp.query_id,
    qsp.last_compile_start_time,
    rs.avg_duration / 1000000.0 AS avg_sec,
    rs.avg_logical_io_reads,
    rs.count_executions,
    TRY_CONVERT(XML, qsp.query_plan) AS plan_xml
FROM sys.query_store_plan qsp
JOIN sys.query_store_runtime_stats rs ON qsp.plan_id = rs.plan_id
JOIN sys.query_store_runtime_stats_interval rsi ON rs.runtime_stats_interval_id = rsi.runtime_stats_interval_id
JOIN sys.query_store_query qsq ON qsp.query_id = qsq.query_id
JOIN sys.query_store_query_text qt ON qsq.query_text_id = qt.query_text_id
WHERE qt.query_sql_text LIKE '%CalcCPR_SMM%'
ORDER BY rsi.start_time DESC;

-- Found plan_id 847 (good, pre-CU) vs plan_id 1203 (bad, post-CU)
-- Bad plan used a nested loop with 12M key lookups instead of hash join + columnstore scan
-- Forced the known-good plan immediately
EXEC sp_query_store_force_plan @query_id = 4521, @plan_id = 847;

-- Built a proactive monitoring alert
CREATE EVENT SESSION [PlanRegressionMonitor] ON SERVER
ADD EVENT qds.query_store_plan_regression(
    SET max_plans = 10,
    ACTION(sqlserver.database_name, sqlserver.sql_text));
```

I also configured Query Store policies: `QUERY_CAPTURE_MODE = AUTO`, `SIZE_BASED_CLEANUP_MODE = AUTO`, and `MAX_STORAGE_SIZE_MB = 4096` to ensure adequate history retention for our workload.

**Result:** Plan forcing restored the 6-minute runtime immediately with zero code changes. The monitoring framework caught two more regressions in the following quarter -- both resolved within 15 minutes via automated alerts. The team avoided an estimated 12 hours of cumulative downtime that quarter. Microsoft acknowledged the cardinality estimator regression and fixed it in the next CU.

**AI Vision:** A predictive model could analyze plan topology changes (operator types, estimated rows, memory grants) before a CU is applied to a staging environment and flag high-risk regressions, enabling proactive plan pinning before production deployment.

---

### Q15. How do you handle statistics maintenance for tables with skewed data distributions (e.g., loan status columns)?

**Situation:** Our `LoanPerformance` table (450M rows) had a `LoanStatus` column where 89% of rows were `'C'` (Current), 6% were `'P'` (Paid Off), and the remaining 5% were spread across 8 delinquency buckets (`'30'`, `'60'`, `'90'`, `'120+'`, `'FC'`, `'REO'`, `'SS'`, `'MOD'`). Auto-statistics consistently underestimated the delinquent population, producing nested-loop plans that timed out when compliance analysts queried seriously delinquent loans (`'90'` and `'120+'`), which represented only ~1.2% of data but were the most business-critical queries.

**Task:** Ensure the optimizer produced accurate estimates for both majority and minority status values, enabling consistent sub-10-second response for delinquency reporting.

**Action:**

```sql
-- Step 1: Created filtered statistics for each critical minority bucket
CREATE STATISTICS STAT_LoanPerf_Status90
ON dbo.LoanPerformance (LoanStatus, ReportingMonth, ServicerID)
WHERE LoanStatus = '90'
WITH FULLSCAN, NORECOMPUTE;

CREATE STATISTICS STAT_LoanPerf_Status120Plus
ON dbo.LoanPerformance (LoanStatus, ReportingMonth, ServicerID)
WHERE LoanStatus = '120+'
WITH FULLSCAN, NORECOMPUTE;

-- Step 2: Incremental stats on partitioned table for efficient updates
ALTER DATABASE MortgageAnalytics SET AUTO_CREATE_STATISTICS ON;
UPDATE STATISTICS dbo.LoanPerformance (STAT_LoanPerf_Status90)
WITH FULLSCAN, PERSIST_SAMPLE_PERCENT = ON, SAMPLE 100 PERCENT;

-- Step 3: Custom maintenance job with adaptive sampling
-- For skewed columns, default 20% sample misses minority values
-- Used dynamic SQL to update stats only on partitions with recent DML
DECLARE @sql NVARCHAR(MAX) = '';
SELECT @sql += 'UPDATE STATISTICS dbo.LoanPerformance ('
    + s.name + ') WITH RESAMPLE ON PARTITIONS('
    + CAST(p.partition_number AS VARCHAR) + '); '
FROM sys.stats s
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
JOIN sys.partitions p ON p.object_id = s.object_id
WHERE s.object_id = OBJECT_ID('dbo.LoanPerformance')
  AND sp.modification_counter > 50000;
EXEC sp_executesql @sql;
```

I also increased the statistics histogram resolution by creating multi-column stats on frequently co-filtered combinations like `(LoanStatus, State, ProductType)`.

**Result:** Cardinality estimates for delinquent loan queries improved from 200x underestimation to within 15% accuracy. Query durations for `'90'` and `'120+'` status filters dropped from 90+ seconds to 3-4 seconds. Statistics maintenance overhead decreased by 60% because we only resampled modified partitions rather than the entire table. Compliance reporting SLAs were met consistently for 6 consecutive quarters.

**AI Vision:** A distribution-aware statistics engine could use clustering algorithms to detect natural data segments and automatically create filtered statistics for underrepresented cohorts, adapting as the distribution shifts (e.g., during a foreclosure wave when `'FC'` percentage spikes).

---

### Q16. Describe your approach to optimizing window functions for calculating rolling delinquency rates across millions of loans.

**Situation:** The risk analytics team needed rolling 3-month, 6-month, and 12-month delinquency transition rates across 18M active Freddie Mac loans. The existing query used three separate self-joins with `GROUP BY` and subqueries, running for 2.5 hours and consuming 180GB of tempdb. It calculated transition matrices showing how loans moved between current, 30-day, 60-day, 90-day, and 120+ day delinquency states month over month.

**Task:** Rewrite the calculation to run under 20 minutes, eliminate tempdb pressure, and support on-demand execution for ad-hoc cohort analysis.

**Action:**

```sql
-- Replaced self-joins with window functions and batch-mode processing
-- Key insight: use LAG to look back at prior status instead of self-join
WITH LoanTransitions AS (
    SELECT
        LoanID,
        ReportingMonth,
        DelinquencyStatus AS CurrentStatus,
        LAG(DelinquencyStatus, 1) OVER (PARTITION BY LoanID ORDER BY ReportingMonth) AS Status_1M_Ago,
        LAG(DelinquencyStatus, 3) OVER (PARTITION BY LoanID ORDER BY ReportingMonth) AS Status_3M_Ago,
        LAG(DelinquencyStatus, 6) OVER (PARTITION BY LoanID ORDER BY ReportingMonth) AS Status_6M_Ago,
        LAG(DelinquencyStatus, 12) OVER (PARTITION BY LoanID ORDER BY ReportingMonth) AS Status_12M_Ago
    FROM dbo.FreddieLoanPerformance
    WHERE ReportingMonth >= DATEADD(MONTH, -24, @AsOfDate)
),
TransitionRates AS (
    SELECT
        ReportingMonth,
        Status_1M_Ago AS FromStatus,
        CurrentStatus AS ToStatus,
        COUNT(*) AS TransitionCount,
        COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY ReportingMonth, Status_1M_Ago) AS TransitionPct
    FROM LoanTransitions
    WHERE Status_1M_Ago IS NOT NULL
    GROUP BY ReportingMonth, Status_1M_Ago, CurrentStatus
)
SELECT * FROM TransitionRates ORDER BY ReportingMonth, FromStatus, ToStatus
OPTION (MAXDOP 8);

-- Forced batch-mode execution via columnstore (even for row store data)
-- by creating an empty filtered CCI as a "batch mode enabler"
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_BatchMode_Enable
ON dbo.FreddieLoanPerformance (DelinquencyStatus)
WHERE LoanID = -1;  -- always empty, zero storage cost
```

The empty columnstore index trick enabled batch-mode window aggregate operators, which process ~900 rows per CPU cycle versus ~1 row in row mode. I also ensured the `PARTITION BY LoanID ORDER BY ReportingMonth` window had a supporting index: `(LoanID, ReportingMonth) INCLUDE (DelinquencyStatus)`.

**Result:** Runtime dropped from 2.5 hours to 11 minutes. Tempdb usage dropped from 180GB to 8GB because batch-mode window aggregates use memory grants instead of spools. The risk team could now run ad-hoc cohort analyses during business hours. The transition matrix powered a new early-warning dashboard that identified deteriorating loan segments 2 months earlier than the prior quarterly reporting cycle.

**AI Vision:** A time-series forecasting model (LSTM or Transformer-based) could consume these transition matrices to predict future delinquency rates at the cohort level, enabling proactive loss mitigation outreach before loans reach 90+ DPD.

---

### Q17. How would you troubleshoot a query that performs well in dev but poorly in production for MBS pool analytics?

**Situation:** A query calculating weighted-average coupon (WAC), weighted-average maturity (WAM), and weighted-average FICO for Ginnie Mae MBS pools ran in 4 seconds in our dev environment but took 22 minutes in production. The production database held 8x more data, but the query was parameterized by `@PoolID` and returned the same ~3,000 loans per pool. The code was identical across environments.

**Task:** Identify and resolve all root causes, then implement safeguards to prevent dev/prod performance divergence for critical analytics.

**Action:** I conducted a systematic comparison across six dimensions:

```sql
-- 1. Compare execution plans side by side
-- Dev: Nested loop + index seek (estimated 3,200 rows, actual 3,100)
-- Prod: Hash match + clustered index scan (estimated 890,000 rows, actual 3,100)
-- Root cause: stale statistics on production PoolLoans table

-- 2. Check statistics freshness
DBCC SHOW_STATISTICS ('dbo.PoolLoans', 'IX_PoolLoans_PoolID')
WITH STAT_HEADER;
-- Last updated: 47 days ago. 2.1M rows modified since.

-- 3. Compare server configurations
-- Production had MAXDOP 0 (unlimited) vs dev MAXDOP 4
-- Production had cost threshold for parallelism = 5 (default!) vs dev = 50

-- 4. Immediate fixes applied
UPDATE STATISTICS dbo.PoolLoans (IX_PoolLoans_PoolID) WITH FULLSCAN;

-- 5. Fixed server-level settings
EXEC sp_configure 'cost threshold for parallelism', 50;
EXEC sp_configure 'max degree of parallelism', 8;
RECONFIGURE;

-- 6. Created a "dev-prod parity" validation script
-- Compared: compatibility level, CE model, trace flags, MAXDOP,
-- memory grants, statistics age, index fragmentation, tempdb config
```

The stale statistics caused the optimizer to estimate 890K rows for a pool that contained 3,100, resulting in an unnecessarily parallel hash join scanning the entire clustered index. After updating statistics, the optimizer correctly chose a nested-loop plan with an index seek.

**Result:** Production query returned to 3.8 seconds -- on par with dev. I automated the parity-check script to run weekly, comparing 14 configuration dimensions between environments. Over the next year, it flagged 6 discrepancies before they caused production incidents. The script was adopted enterprise-wide across 4 teams.

**AI Vision:** A digital twin of the production environment could replay query workloads against refreshed statistics snapshots, predicting performance drift before it manifests. An ML classifier trained on plan features could flag "risky" plans at deployment time.

---

### Q18. Explain your strategy for using filtered indexes on loan data (e.g., active loans vs all loans).

**Situation:** Our loan servicing database contained 65M total loans but only 14M were active (`LoanStatus NOT IN ('P','L','S')` -- excluding paid-off, liquidated, and sold). The vast majority of operational queries -- payment processing, escrow analysis, loss mitigation workflows -- targeted only active loans. Full-table indexes were massive and slow to maintain, and key lookups on the 51M inactive rows wasted buffer pool memory.

**Task:** Reduce index storage by 60%+, improve operational query performance, and keep buffer pool utilization focused on hot data.

**Action:**

```sql
-- Replaced broad indexes with filtered equivalents
-- Before: 8 indexes covering all 65M rows = 142 GB index storage

-- Active loan indexes (14M rows, ~22% of data)
CREATE NONCLUSTERED INDEX IX_ActiveLoan_Servicer_State
ON dbo.LoanMaster (ServicerID, PropertyState)
INCLUDE (CurrentUPB, NextPaymentDate, EscrowBalance)
WHERE LoanStatus NOT IN ('P','L','S')
WITH (DATA_COMPRESSION = PAGE, ONLINE = ON);

CREATE NONCLUSTERED INDEX IX_ActiveLoan_DelqBucket
ON dbo.LoanMaster (DelinquencyBucket, ServicerID)
INCLUDE (BorrowerName, LoanAmount, LastPaymentDate)
WHERE LoanStatus NOT IN ('P','L','S') AND DelinquencyBucket > 0
WITH (DATA_COMPRESSION = PAGE, ONLINE = ON);

-- Historical/archive indexes for regulatory lookups (rare queries)
CREATE NONCLUSTERED INDEX IX_HistoricalLoan_Disposition
ON dbo.LoanMaster (DispositionDate, DispositionType)
INCLUDE (OriginalUPB, LossAmount)
WHERE LoanStatus IN ('P','L','S')
WITH (DATA_COMPRESSION = ROW, ONLINE = ON);

-- Critical: ensured stored procedures include the filter predicate
-- so the optimizer can match the filtered index
CREATE OR ALTER PROCEDURE dbo.usp_GetServicerPortfolio
    @ServicerID INT
AS
BEGIN
    SELECT LoanID, PropertyState, CurrentUPB, NextPaymentDate
    FROM dbo.LoanMaster
    WHERE ServicerID = @ServicerID
      AND LoanStatus NOT IN ('P','L','S')  -- must match filter!
    ORDER BY NextPaymentDate;
END;
```

I documented the critical rule that any query wanting to use these filtered indexes MUST include the matching WHERE clause. I also added a code review checklist item and a unit test that verified filter predicate presence in all 23 stored procedures.

**Result:** Total index storage dropped from 142GB to 48GB (66% reduction). Buffer pool hit ratio improved from 91% to 97.5% because inactive loan pages were no longer competing for cache. Active loan queries improved by 35-50% due to smaller, denser indexes. Nightly index maintenance window shrank from 45 minutes to 12 minutes. The savings freed 94GB of SSD storage that deferred a planned storage expansion by 8 months.

**AI Vision:** A workload-aware index recommendation engine could automatically detect natural data partitions (active vs. archived, performing vs. non-performing) and propose filtered index candidates with predicted storage savings and query improvement estimates.

---

### Q19. How do you approach rewriting cursor-based legacy procedures for batch loan processing into set-based operations?

**Situation:** A legacy stored procedure `usp_ProcessLoanModifications` used a cursor to iterate through 85,000 loan modification requests nightly. For each loan, it recalculated the modified payment schedule, updated 7 related tables, logged an audit trail, and sent a record to the servicer notification queue. The cursor-based approach took 3 hours 40 minutes, and during that window, row-level locks escalated to table locks, blocking the real-time servicing portal.

**Task:** Rewrite to set-based logic, reducing runtime to under 30 minutes and eliminating lock escalation that impacted the customer-facing application.

**Action:**

```sql
-- Phase 1: Replaced row-by-row calculation with set-based math
-- Before: WHILE cursor fetched one loan at a time and called 5 sub-procedures
-- After: Bulk calculation using CROSS APPLY for complex per-row logic

-- Calculate new payment schedules for all mods in one pass
SELECT m.LoanID, m.ModType, m.NewRate, m.NewTerm,
    calc.NewMonthlyPayment, calc.NewTotalInterest
INTO #ModCalculations
FROM dbo.PendingModifications m
CROSS APPLY dbo.fn_CalcAmortization(m.NewPrincipal, m.NewRate, m.NewTerm) calc
WHERE m.ProcessingStatus = 'PENDING';

-- Phase 2: Multi-table update using MERGE for upsert semantics
MERGE dbo.LoanPaymentSchedule AS target
USING #ModCalculations AS source ON target.LoanID = source.LoanID
WHEN MATCHED THEN
    UPDATE SET MonthlyPayment = source.NewMonthlyPayment,
               InterestRate = source.NewRate,
               RemainingTerm = source.NewTerm,
               ModifiedDate = GETDATE()
WHEN NOT MATCHED THEN
    INSERT (LoanID, MonthlyPayment, InterestRate, RemainingTerm, ModifiedDate)
    VALUES (source.LoanID, source.NewMonthlyPayment, source.NewRate, source.NewTerm, GETDATE());

-- Phase 3: Bulk audit logging instead of row-by-row INSERT
INSERT INTO dbo.ModificationAuditLog (LoanID, Action, OldValue, NewValue, Timestamp)
SELECT mc.LoanID, 'PAYMENT_CHANGE',
    CAST(old.MonthlyPayment AS VARCHAR), CAST(mc.NewMonthlyPayment AS VARCHAR),
    GETDATE()
FROM #ModCalculations mc
JOIN dbo.LoanPaymentSchedule_History old ON mc.LoanID = old.LoanID;

-- Phase 4: Replaced Service Broker row-by-row sends with batch
INSERT INTO dbo.ServicerNotificationQueue (LoanID, NotificationType, Payload)
SELECT LoanID, 'MOD_COMPLETE', (SELECT mc.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
FROM #ModCalculations mc;
```

I converted the scalar UDF `fn_CalcAmortization` to an inline table-valued function to avoid the per-row execution penalty. I also added `WITH (TABLOCK)` hints on the temp table inserts to use minimal logging in simple recovery model tempdb.

**Result:** Runtime dropped from 3 hours 40 minutes to 14 minutes -- a 94% improvement. Lock escalation incidents dropped to zero because the bulk operations acquired and released locks in predictable, short-duration batches. The servicing portal experienced zero blocked sessions during the modification window. The rewrite also uncovered 340 loans where the cursor had been silently swallowing errors via a TRY/CATCH that logged but continued -- these were now properly surfaced and handled.

**AI Vision:** An AI-powered code modernization tool could parse cursor-based T-SQL ASTs, identify the data flow patterns, and auto-generate equivalent set-based rewrites with before/after result validation to ensure semantic equivalence.

---

### Q20. Describe how you'd use Extended Events to capture and analyze slow queries in a mortgage data warehouse.

**Situation:** Our mortgage data warehouse supporting Intex deal analytics and CoreLogic property data enrichment was experiencing intermittent performance degradation. Users reported "the system is slow" but couldn't identify specific queries. The DBA team had been using SQL Profiler, which itself added 15-20% overhead and captured too much noise. We needed surgical diagnostics for queries exceeding acceptable thresholds without impacting the already-stressed system.

**Task:** Implement a lightweight, always-on monitoring solution that captured slow queries with full context (plan, waits, resource usage) at under 2% system overhead, and build an analytical framework to prioritize tuning efforts.

**Action:**

```sql
-- Created a targeted Extended Events session
CREATE EVENT SESSION [MortgageDW_SlowQuery_Monitor] ON SERVER
ADD EVENT sqlserver.sql_batch_completed (
    SET collect_batch_text = (1)
    ACTION (
        sqlserver.database_name,
        sqlserver.username,
        sqlserver.client_app_name,
        sqlserver.query_hash,
        sqlserver.query_plan_hash,
        sqlserver.sql_text
    )
    WHERE (
        [duration] > 5000000  -- > 5 seconds
        AND [database_name] = N'MortgageDW'
        AND [logical_reads] > 100000
    )
),
ADD EVENT sqlos.wait_completed (
    ACTION (sqlserver.sql_text, sqlserver.session_id)
    WHERE (
        [duration] > 1000  -- > 1ms waits
        AND [opcode] = 1   -- end of wait
        AND NOT [wait_type] IN (
            N'WAITFOR', N'BROKER_RECEIVE_WAITFOR',
            N'LAZYWRITER_SLEEP', N'SQLTRACE_BUFFER_FLUSH'
        )
    )
)
ADD TARGET package0.event_file (
    SET filename = N'S:\XEvents\MortgageDW_SlowQuery.xel',
        max_file_size = 512,  -- MB per file
        max_rollover_files = 10
)
WITH (
    MAX_MEMORY = 16384 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    STARTUP_STATE = ON
);

ALTER EVENT SESSION [MortgageDW_SlowQuery_Monitor] ON SERVER STATE = START;

-- Analysis query: weekly top offenders report
SELECT
    query_hash_value,
    MIN(SUBSTRING(sql_text, 1, 200)) AS sample_query,
    COUNT(*) AS occurrence_count,
    AVG(duration_sec) AS avg_duration_sec,
    MAX(duration_sec) AS max_duration_sec,
    SUM(logical_reads) AS total_logical_reads,
    AVG(cpu_time_ms) AS avg_cpu_ms
FROM (
    SELECT
        event_data.value('(event/@timestamp)[1]', 'DATETIME2') AS event_time,
        event_data.value('(event/action[@name="query_hash"]/value)[1]', 'NVARCHAR(50)') AS query_hash_value,
        event_data.value('(event/action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text,
        event_data.value('(event/data[@name="duration"]/value)[1]', 'BIGINT') / 1000000.0 AS duration_sec,
        event_data.value('(event/data[@name="logical_reads"]/value)[1]', 'BIGINT') AS logical_reads,
        event_data.value('(event/data[@name="cpu_time"]/value)[1]', 'BIGINT') / 1000.0 AS cpu_time_ms
    FROM sys.fn_xe_file_target_read_file('S:\XEvents\MortgageDW_SlowQuery*.xel', NULL, NULL, NULL)
    CROSS APPLY (SELECT CAST(event_data AS XML)) AS t(event_data)
) parsed
GROUP BY query_hash_value
ORDER BY SUM(logical_reads) DESC;
```

I built a Power BI dashboard that refreshed hourly from the parsed XE data, showing heatmaps of slow queries by time-of-day, user, and application. This immediately revealed that an Intex cashflow recalculation job overlapping with CoreLogic property data loads was the primary contention source.

**Result:** System overhead measured at 1.3% (vs. 18% with the old Profiler traces). Within the first week, we identified 8 queries responsible for 72% of total I/O. Tuning those 8 queries reduced average system response time by 45%. The time-of-day heatmap led us to reschedule the Intex and CoreLogic jobs to non-overlapping windows, eliminating the intermittent slowdowns entirely. The monitoring framework became our permanent "flight recorder" for the warehouse.

**AI Vision:** An NLP-based query classification model could automatically categorize captured slow queries by business domain (prepayment analytics, deal pricing, property valuation) and route tuning recommendations to the appropriate development team, while an anomaly detection model could alert on emerging patterns before they become systemic issues.
