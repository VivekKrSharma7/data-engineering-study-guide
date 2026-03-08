# SQL Server Intermediate Q&A (25 Questions)

[Back to Index](README.md)

---

### Q1. How do window functions work? Explain ROW_NUMBER, RANK, DENSE_RANK, NTILE with examples

**Situation:** Our secondary mortgage market analytics team needed to rank residential loan pools by delinquency rate across Fannie Mae and Freddie Mac servicers, identify top-performing tranches, and bucket MBS deals into quartiles for investor reporting.

**Task:** Build a ranking report that assigned unique row numbers, handled ties in delinquency rates, provided dense sequential ranks, and grouped pools into quartiles -- all partitioned by agency (FNMA, FHLMC, GNMA).

**Action:** Used window functions against our loan-level performance dataset:
```sql
SELECT
    agency_code,
    pool_number,
    servicer_name,
    current_delinquency_rate,
    ROW_NUMBER() OVER (PARTITION BY agency_code ORDER BY current_delinquency_rate ASC) AS row_num,
    RANK()       OVER (PARTITION BY agency_code ORDER BY current_delinquency_rate ASC) AS rank_val,
    DENSE_RANK() OVER (PARTITION BY agency_code ORDER BY current_delinquency_rate ASC) AS dense_rank_val,
    NTILE(4)     OVER (PARTITION BY agency_code ORDER BY current_delinquency_rate ASC) AS quartile
FROM dbo.MBS_PoolPerformance
WHERE reporting_month = '2025-12-01';
```
ROW_NUMBER gives every row a unique sequential number even for ties. RANK skips numbers after ties (1,1,3), DENSE_RANK does not skip (1,1,2). NTILE(4) divides the partition into four roughly equal buckets. We also used a named WINDOW clause in newer SQL Server 2022 builds to avoid repeating PARTITION/ORDER clauses.

**Result:** The quartile bucketing let our risk team instantly identify the worst-performing 25% of pools per agency. Report generation dropped from 45 minutes of manual Excel work to a 3-second query, and portfolio managers received daily automated rankings covering 12,000+ active pools.

**AI Vision:** An ML model could predict future quartile movements based on macroeconomic indicators, flagging pools likely to shift from Q1 to Q3/Q4 before delinquency spikes materialize.

---

### Q2. Explain CTEs (Common Table Expressions) and recursive CTEs

**Situation:** We had a hierarchical servicer-subservicer relationship table for Ginnie Mae pools where a master servicer could have multiple subservicers, who in turn had sub-subservicers. Analysts needed to trace the full chain from any loan back to the ultimate master servicer for regulatory reporting.

**Task:** Flatten the multi-level servicer hierarchy into a single result set showing depth level, and also build a running total of unpaid principal balance (UPB) rolling up from leaf-level subservicers to the master.

**Action:** Implemented a recursive CTE to walk the hierarchy:
```sql
WITH ServicerHierarchy AS (
    -- Anchor: top-level master servicers (no parent)
    SELECT servicer_id, servicer_name, parent_servicer_id, upb_total, 1 AS depth_level,
           CAST(servicer_name AS VARCHAR(1000)) AS hierarchy_path
    FROM dbo.ServicerRelationship
    WHERE parent_servicer_id IS NULL

    UNION ALL

    -- Recursive member
    SELECT c.servicer_id, c.servicer_name, c.parent_servicer_id, c.upb_total, p.depth_level + 1,
           CAST(p.hierarchy_path + ' > ' + c.servicer_name AS VARCHAR(1000))
    FROM dbo.ServicerRelationship c
    INNER JOIN ServicerHierarchy p ON c.parent_servicer_id = p.servicer_id
)
SELECT * FROM ServicerHierarchy
OPTION (MAXRECURSION 10);
```
Non-recursive CTEs were used extensively to break complex MBS cash-flow waterfall calculations into readable stages -- each CTE represented one tranche priority level.

**Result:** Replaced a 400-line nested subquery with five clearly named CTEs, reducing code review time by 60%. The recursive CTE resolved all 6 levels of servicer hierarchy in under 2 seconds for 1,800 servicer nodes, satisfying Ginnie Mae's HMBS reporting deadline.

**AI Vision:** NLP could parse unstructured servicer transfer notices to automatically update the hierarchy table when subservicing rights change hands.

---

### Q3. What are the different transaction isolation levels and their tradeoffs?

**Situation:** Our loan boarding system processed nightly bulk inserts of 50,000+ newly originated residential mortgages while simultaneously the pricing engine read the same tables to generate next-day rate sheets for Fannie Mae and Freddie Mac loan deliveries.

**Task:** Choose the correct isolation level so the pricing engine never read partially-committed loan batches (dirty reads), while not blocking the boarding process with excessive locking.

**Action:** Evaluated all five isolation levels in context:
```sql
-- READ UNCOMMITTED: fastest but allows dirty reads; used only for approximate pool counts
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SELECT COUNT(*) FROM dbo.LoanMaster WITH (NOLOCK); -- quick dashboard count

-- READ COMMITTED (default): prevents dirty reads; used for standard CRUD
-- REPEATABLE READ: prevents non-repeatable reads; used during rate-lock calculations
-- SERIALIZABLE: full isolation; used for month-end Freddie Mac delivery reconciliation

-- Our solution: RCSI (Read Committed Snapshot Isolation)
ALTER DATABASE MortgageWarehouse SET READ_COMMITTED_SNAPSHOT ON;
```
RCSI uses row versioning in tempdb so readers get a consistent snapshot without blocking writers. We sized tempdb on fast NVMe storage to handle the version store overhead.

**Result:** After enabling RCSI, blocking incidents during the nightly boarding window dropped from 35 per night to zero. Pricing engine queries returned in consistent 200ms instead of timing out at 30 seconds. Tempdb grew by roughly 8 GB during peak loads, well within our allocated capacity.

**AI Vision:** An anomaly-detection model monitoring version store growth and blocking patterns could proactively recommend isolation level changes before contention impacts SLAs.

---

### Q4. How does indexing affect INSERT/UPDATE/DELETE performance?

**Situation:** Our loan payment history table (dbo.PaymentActivity) received 2 million INSERT rows nightly from servicer remittance files and had 14 nonclustered indexes supporting various Fannie Mae and Freddie Mac investor reporting queries.

**Task:** Reduce the nightly load window from 4 hours to under 90 minutes without dropping indexes that were critical for daytime reporting.

**Action:** Analyzed index maintenance overhead and restructured the approach:
```sql
-- Identified unused/duplicate indexes
SELECT i.name, s.user_seeks, s.user_scans, s.user_updates
FROM sys.dm_db_index_usage_stats s
JOIN sys.indexes i ON s.object_id = i.object_id AND s.index_id = i.index_id
WHERE s.object_id = OBJECT_ID('dbo.PaymentActivity')
ORDER BY s.user_updates DESC;

-- Dropped 5 redundant indexes (overlapping key columns)
-- Disabled 3 indexes used only for month-end, re-enabled them on the 1st
ALTER INDEX IX_PaymentActivity_InvestorCode ON dbo.PaymentActivity DISABLE;

-- Used bulk insert with minimal logging
ALTER DATABASE MortgageWarehouse SET RECOVERY BULK_LOGGED;
BULK INSERT dbo.PaymentActivity FROM '\\share\remittance_202512.dat'
    WITH (TABLOCK, BATCHSIZE = 100000, ORDER(loan_number));
ALTER DATABASE MortgageWarehouse SET RECOVERY FULL;
```
Every index on a table adds write overhead because each INSERT must update the B-tree for every nonclustered index. UPDATE and DELETE also must maintain all affected indexes.

**Result:** Removing 5 redundant indexes and disabling 3 month-end-only indexes reduced the nightly load from 4 hours to 52 minutes. Daytime query performance was unaffected since the removed indexes were truly redundant (confirmed via missing index DMVs and usage stats over 90 days).

**AI Vision:** ML-driven index advisory tools (like SQL Server 2022 intelligent tuning) could continuously recommend index consolidation based on actual workload patterns rather than periodic manual reviews.

---

### Q5. Explain MERGE statement for upsert operations

**Situation:** CoreLogic delivered daily property valuation updates for 500,000 properties backing our residential mortgage portfolio. Records could be new properties, updated valuations, or properties removed from the CoreLogic universe.

**Task:** Implement a single atomic upsert operation that inserts new properties, updates changed valuations, and soft-deletes removed properties in the dbo.PropertyValuation table.

**Action:** Built a MERGE statement with all three match conditions:
```sql
MERGE dbo.PropertyValuation AS tgt
USING staging.CoreLogic_Daily AS src
    ON tgt.property_id = src.property_id
WHEN MATCHED AND (tgt.avm_value <> src.avm_value OR tgt.confidence_score <> src.confidence_score) THEN
    UPDATE SET tgt.avm_value = src.avm_value,
               tgt.confidence_score = src.confidence_score,
               tgt.last_updated = GETDATE()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (property_id, avm_value, confidence_score, last_updated, is_active)
    VALUES (src.property_id, src.avm_value, src.confidence_score, GETDATE(), 1)
WHEN NOT MATCHED BY SOURCE AND tgt.is_active = 1 THEN
    UPDATE SET tgt.is_active = 0, tgt.deactivated_date = GETDATE()
OUTPUT $action, INSERTED.property_id, INSERTED.avm_value
INTO dbo.PropertyValuation_AuditLog;
```
Key considerations: always use a HOLDLOCK hint or serializable isolation to prevent race conditions with MERGE, and terminate with a semicolon. We logged all changes via the OUTPUT clause for audit trails.

**Result:** Replaced three separate INSERT/UPDATE/DELETE stored procedures with one MERGE, reducing daily processing from 18 minutes to 6 minutes. The OUTPUT-based audit log captured every change, satisfying FHFA examination requirements for property valuation traceability.

**AI Vision:** An ML model could flag suspicious AVM jumps (e.g., >30% change in 30 days) in the OUTPUT audit log, automatically quarantining those records for manual review before they impact LTV calculations.

---

### Q6. What is deadlocking and how do you prevent/resolve it?

**Situation:** During month-end processing, two critical stored procedures ran concurrently: one updated loan-level prepayment speeds (CPR/CDR) for Intex modeling, and the other recalculated bond factor tables for Fannie Mae MBS pools. Both accessed dbo.LoanCashFlow and dbo.PoolFactor tables but in opposite order.

**Task:** Eliminate recurring deadlocks that caused one or both processes to fail, requiring manual restart and delaying investor reporting by 2-3 hours.

**Action:** Diagnosed using the deadlock graph and restructured access patterns:
```sql
-- Enabled deadlock trace flag for XML deadlock graphs
DBCC TRACEON(1222, -1);

-- Captured deadlock info from system_health extended event
SELECT XEvent.query('(event/data/value/deadlock)[1]') AS deadlock_graph
FROM (
    SELECT CAST(target_data AS XML) AS TargetData
    FROM sys.dm_xe_session_targets st
    JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address
    WHERE s.name = 'system_health'
) AS Data
CROSS APPLY TargetData.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData(XEvent);

-- Fix 1: Ensured both procs access tables in same order (LoanCashFlow first, then PoolFactor)
-- Fix 2: Added UPDLOCK hints to the first read to prevent conversion deadlocks
SELECT * FROM dbo.LoanCashFlow WITH (UPDLOCK, ROWLOCK) WHERE pool_id = @PoolId;
-- Fix 3: Reduced transaction scope by breaking large updates into 10,000-row batches
```
Deadlocks occur when two sessions hold locks the other needs. SQL Server automatically kills the lower-cost victim. Prevention strategies: consistent access ordering, shorter transactions, appropriate lock hints, and RCSI.

**Result:** Deadlocks dropped from 15-20 per month-end cycle to zero after enforcing consistent table access order. Month-end processing completed 2.5 hours earlier, and the Intex cash-flow models received timely inputs for next-day investor reporting.

**AI Vision:** A time-series anomaly detector on lock wait statistics could predict deadlock-prone windows and automatically throttle or resequence conflicting batch jobs.

---

### Q7. Explain CROSS APPLY and OUTER APPLY with practical examples

**Situation:** Each Freddie Mac loan record in our warehouse had a JSON-like delimited field containing up to 12 months of historical delinquency statuses, and we also had a table-valued function that computed projected loss severity for a given loan based on its current LTV, FICO, and state.

**Task:** Parse the delimited delinquency history into individual rows per loan and also invoke the loss-severity function for each loan in a 200,000-row portfolio query.

**Action:** Used CROSS APPLY for the TVF and OUTER APPLY for the string parsing (to keep loans even if the history field was NULL):
```sql
-- CROSS APPLY: invokes TVF per row; excludes rows where TVF returns empty
SELECT l.loan_number, l.current_upb, ls.projected_loss, ls.severity_pct
FROM dbo.FreddieMac_Loans l
CROSS APPLY dbo.fn_CalcLossSeverity(l.current_ltv, l.fico_score, l.property_state) ls
WHERE l.pool_id = @PoolId;

-- OUTER APPLY: like LEFT JOIN to a TVF; keeps all loans even if no history exists
SELECT l.loan_number, h.month_offset, h.delinquency_status
FROM dbo.FreddieMac_Loans l
OUTER APPLY (
    SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS month_offset, value AS delinquency_status
    FROM STRING_SPLIT(l.delinquency_history_csv, ',')
) h
WHERE l.origination_date >= '2024-01-01';
```
CROSS APPLY is like an INNER JOIN to a correlated subquery or TVF -- rows with no match are excluded. OUTER APPLY is like a LEFT JOIN -- the left side rows are preserved with NULLs.

**Result:** The loss-severity calculation across 200,000 loans ran in 8 seconds with CROSS APPLY versus 45 seconds using a scalar function in the SELECT list. OUTER APPLY parsed delinquency histories inline, eliminating a separate ETL step that previously took 20 minutes.

**AI Vision:** The loss-severity TVF could be replaced by an ML scoring endpoint called via CROSS APPLY to sp_invoke_external_resource, enabling real-time AI-driven loss projections per loan.

---

### Q8. How do you implement pagination in SQL Server?

**Situation:** Our internal loan servicing portal displayed search results for mortgage loans matching various criteria (servicer, pool, state, delinquency status). The result sets could be 500,000+ rows, and the UI needed page-by-page navigation with 50 loans per page.

**Task:** Implement efficient server-side pagination that scaled to large result sets without fetching all rows and discarding most of them.

**Action:** Used OFFSET-FETCH (SQL Server 2012+) as the primary approach and a keyset approach for deep pagination:
```sql
-- Approach 1: OFFSET-FETCH (simple, good for first ~1000 pages)
DECLARE @PageNumber INT = 5, @PageSize INT = 50;

SELECT loan_number, borrower_name, current_upb, loan_status, servicer_name
FROM dbo.LoanMaster
WHERE pool_type = 'FNMA' AND loan_status = 'Active'
ORDER BY loan_number
OFFSET (@PageNumber - 1) * @PageSize ROWS
FETCH NEXT @PageSize ROWS ONLY;

-- Approach 2: Keyset pagination (much faster for deep pages)
SELECT TOP 50 loan_number, borrower_name, current_upb, loan_status, servicer_name
FROM dbo.LoanMaster
WHERE pool_type = 'FNMA' AND loan_status = 'Active'
  AND loan_number > @LastLoanNumberFromPreviousPage
ORDER BY loan_number;
```
OFFSET-FETCH is readable but performance degrades on deep pages because SQL Server must scan and discard OFFSET rows. Keyset pagination uses a WHERE filter on the last-seen key, giving consistent performance on any page depth. We indexed (pool_type, loan_status, loan_number) INCLUDE (borrower_name, current_upb, servicer_name) as a covering index.

**Result:** Page 1 loaded in 50ms with both approaches. At page 10,000, OFFSET-FETCH took 12 seconds while keyset returned in 50ms. We used OFFSET-FETCH for the first 100 pages and auto-switched to keyset beyond that, giving users sub-100ms response times throughout.

**AI Vision:** A recommendation engine could predict which filter combinations and pages users are most likely to visit, pre-caching those result sets for instant display.

---

### Q9. What is the difference between EXISTS and IN? When is each faster?

**Situation:** We needed to find all active Fannie Mae loans that had at least one payment record in the current month's remittance file (a staging table with 3 million rows). The LoanMaster table had 1.2 million rows. Developers debated whether to use IN or EXISTS.

**Task:** Determine which approach performed better for this specific data distribution and establish a team guideline for future queries.

**Action:** Tested both approaches and examined execution plans:
```sql
-- EXISTS: short-circuits on first match; typically better when subquery table is large
SELECT l.loan_number, l.current_upb
FROM dbo.LoanMaster l
WHERE l.agency_code = 'FNMA'
  AND EXISTS (
    SELECT 1 FROM staging.MonthlyRemittance r
    WHERE r.loan_number = l.loan_number AND r.remit_month = '2025-12-01'
  );

-- IN: materializes the full list; can be better when subquery returns few distinct values
SELECT l.loan_number, l.current_upb
FROM dbo.LoanMaster l
WHERE l.agency_code = 'FNMA'
  AND l.loan_status IN (
    SELECT DISTINCT loan_status FROM dbo.StatusLookup WHERE is_performing = 1
  );
```
Key differences: EXISTS returns TRUE/FALSE and stops scanning on first match. IN builds a complete list then checks membership. With NULLs, IN can produce unexpected results (NOT IN with NULLs returns no rows). The modern optimizer often generates identical plans for both, but EXISTS is safer with nullable columns and preferred for large correlated checks.

**Result:** For the remittance match query, EXISTS ran in 1.8 seconds vs. IN at 2.1 seconds -- similar because the optimizer converted both to a semi-join. For the NOT IN vs. NOT EXISTS case against a nullable column, NOT IN returned zero rows (wrong) while NOT EXISTS returned the correct 45,000 rows. We standardized on EXISTS for correlated checks.

**AI Vision:** Query rewrite suggestions powered by AI (similar to SQL Server's intelligent query processing) could automatically recommend EXISTS vs. IN based on cardinality estimates and null-safety analysis.

---

### Q10. Explain PIVOT and UNPIVOT operations

**Situation:** Freddie Mac's monthly investor reporting required a cross-tab report showing each pool's delinquency counts by bucket (Current, 30-Day, 60-Day, 90-Day+) as columns. The source data stored each delinquency status as separate rows in a normalized fact table.

**Task:** Transform row-based delinquency data into a columnar pivot report, and also reverse-transform a wide legacy CoreLogic property file (with columns for each year's valuation) into normalized rows.

**Action:** Used PIVOT for the delinquency report and UNPIVOT for the valuation normalization:
```sql
-- PIVOT: rows to columns
SELECT pool_number, [Current], [30-Day], [60-Day], [90-Day+]
FROM (
    SELECT pool_number, delinquency_bucket, loan_count
    FROM dbo.MonthlyDelinquencyDetail
    WHERE reporting_month = '2025-12-01'
) src
PIVOT (
    SUM(loan_count) FOR delinquency_bucket IN ([Current], [30-Day], [60-Day], [90-Day+])
) pvt;

-- UNPIVOT: columns to rows (CoreLogic wide format to normalized)
SELECT property_id, valuation_year, avm_value
FROM dbo.CoreLogic_WideFormat
UNPIVOT (
    avm_value FOR valuation_year IN ([AVM_2020], [AVM_2021], [AVM_2022], [AVM_2023], [AVM_2024], [AVM_2025])
) unpvt;
```
For dynamic pivot (unknown column values), we built the column list with dynamic SQL from DISTINCT values in the delinquency_bucket column. PIVOT requires an aggregate function; UNPIVOT filters out NULLs by default.

**Result:** The PIVOT query replaced a 200-line CASE-WHEN cross-tab query, improving readability and running 30% faster. The UNPIVOT normalized 8 years of CoreLogic wide-format history (4 million properties) in 45 seconds, feeding our time-series LTV trending dashboard.

**AI Vision:** Automated schema detection using ML could identify wide-format legacy files and auto-generate UNPIVOT scripts during data onboarding, reducing manual ETL development time.

---

### Q11. How does the SQL Server query optimizer choose an execution plan?

**Situation:** A critical query joining dbo.LoanMaster (1.2M rows), dbo.PaymentActivity (80M rows), and dbo.PoolFactor (50K rows) for Ginnie Mae monthly remittance reporting suddenly degraded from 10 seconds to 8 minutes after a statistics auto-update changed the estimated row counts.

**Task:** Understand why the optimizer chose a nested loop join instead of a hash join and restore the original performance without rewriting the query.

**Action:** Investigated the optimizer's decision process:
```sql
-- Step 1: Capture the actual execution plan
SET STATISTICS IO, TIME ON;
-- Run the query with actual plan enabled in SSMS

-- Step 2: Check statistics freshness
DBCC SHOW_STATISTICS('dbo.PaymentActivity', 'IX_PaymentActivity_LoanNumber');

-- Step 3: Force statistics update with full scan
UPDATE STATISTICS dbo.PaymentActivity IX_PaymentActivity_LoanNumber WITH FULLSCAN;

-- Step 4: Examine cardinality estimates vs actuals
SELECT * FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qp.query_plan.value('(//RelOp/@EstimateRows)[1]', 'float') < 100
  AND qs.last_rows > 100000;
```
The optimizer uses cost-based optimization: it generates candidate plans, estimates I/O and CPU costs using statistics histograms, and picks the lowest-cost plan. It considers join types (nested loop for small inputs, hash for large unsorted, merge for pre-sorted), index selection, and parallelism. Stale statistics, parameter sniffing, and cardinality estimation errors are the most common causes of bad plans.

**Result:** After FULLSCAN statistics update, the optimizer correctly chose a hash join and the query returned to 9 seconds. We added a maintenance job running UPDATE STATISTICS WITH FULLSCAN weekly on high-churn tables, and used OPTION (RECOMPILE) on the two most parameter-sensitive remittance queries.

**AI Vision:** SQL Server 2022's intelligent query processing (IQP) with cardinality estimation feedback is an early step; future AI-driven optimizers could learn workload patterns and pre-emptively adjust plans before degradation occurs.

---

### Q12. What are indexed views and when should you use them?

**Situation:** Our Fannie Mae investor reporting dashboard queried a real-time aggregate: total UPB, weighted-average coupon, and weighted-average LTV grouped by pool, servicer, and state. The base table had 1.2 million loans and the aggregate query took 25 seconds, running dozens of times per hour.

**Task:** Materialize the aggregate so dashboard queries could read pre-computed results rather than scanning the full loan table on every request.

**Action:** Created an indexed (materialized) view with a unique clustered index:
```sql
CREATE VIEW dbo.vw_PoolServicerAggregate
WITH SCHEMABINDING
AS
SELECT
    pool_id, servicer_id, property_state,
    COUNT_BIG(*) AS loan_count,
    SUM(current_upb) AS total_upb,
    SUM(current_upb * note_rate) AS weighted_rate_numerator,
    SUM(current_upb * current_ltv) AS weighted_ltv_numerator
FROM dbo.LoanMaster
GROUP BY pool_id, servicer_id, property_state;
GO

CREATE UNIQUE CLUSTERED INDEX IX_PoolServicerAgg
ON dbo.vw_PoolServicerAggregate (pool_id, servicer_id, property_state);
```
Requirements: SCHEMABINDING, deterministic expressions, COUNT_BIG required, no OUTER joins, no subqueries, no non-deterministic functions. The optimizer in Enterprise Edition automatically matches queries to indexed views even without WITH (NOEXPAND). In Standard Edition, you must hint WITH (NOEXPAND).

**Result:** Dashboard queries dropped from 25 seconds to 80 milliseconds -- a 300x improvement. DML overhead on the base LoanMaster table increased by about 5% for inserts/updates, acceptable given the table was updated only during nightly batch loads while the view was queried hundreds of times during business hours.

**AI Vision:** Smart caching layers could use ML to predict which aggregate combinations are queried most and selectively materialize only high-value indexed views, balancing write overhead against read benefit.

---

### Q13. Explain error handling with TRY...CATCH and THROW

**Situation:** Our loan boarding stored procedure processed thousands of new Freddie Mac loans per batch. If a single loan failed validation (e.g., invalid FIPS code, missing FICO), the entire batch was rolling back due to unhandled errors, causing the remaining valid loans to be lost.

**Task:** Implement granular error handling so valid loans were committed while failed loans were logged to an error table with full diagnostics, and critical errors (like deadlocks) would escalate and halt the batch.

**Action:** Wrapped the per-loan processing in TRY...CATCH with conditional re-throw:
```sql
CREATE PROCEDURE dbo.usp_BoardFreddieMacLoans @BatchId INT
AS
BEGIN
    DECLARE @LoanNumber VARCHAR(20);
    DECLARE loan_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT loan_number FROM staging.FreddieMac_Incoming WHERE batch_id = @BatchId;
    OPEN loan_cursor;
    FETCH NEXT FROM loan_cursor INTO @LoanNumber;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;
            EXEC dbo.usp_ValidateAndInsertLoan @LoanNumber;
            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            INSERT INTO dbo.BoardingErrorLog (loan_number, error_number, error_message, error_line, error_proc, logged_at)
            VALUES (@LoanNumber, ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_LINE(), ERROR_PROCEDURE(), GETDATE());
            IF ERROR_NUMBER() = 1205 THROW;  -- Re-throw deadlocks to halt batch
        END CATCH;
        FETCH NEXT FROM loan_cursor INTO @LoanNumber;
    END;
    CLOSE loan_cursor; DEALLOCATE loan_cursor;
END;
```
THROW without parameters re-raises the original error. Always check XACT_STATE() before ROLLBACK since the transaction may already be uncommittable (-1). ERROR_NUMBER(), ERROR_MESSAGE(), ERROR_LINE(), ERROR_PROCEDURE(), and ERROR_SEVERITY() capture full context.

**Result:** Batch success rate improved from 82% (entire batch fail) to 99.6% (only individual bad loans rejected). The error log enabled the data quality team to fix upstream Freddie Mac file issues, reducing boarding errors by 40% over three months through pattern analysis.

**AI Vision:** An NLP model trained on historical error messages could auto-classify boarding failures by root cause category and suggest corrective actions to the operations team.

---

### Q14. How do you use dynamic SQL safely (sp_executesql vs EXEC)?

**Situation:** Our investor reporting platform allowed users to build ad-hoc queries against Fannie Mae loan data by selecting filters (state, servicer, pool type, delinquency range) from dropdowns. The stored procedure needed to construct a WHERE clause dynamically based on which filters were active.

**Task:** Build a flexible dynamic query that supported optional parameters while preventing SQL injection and enabling plan reuse through parameterization.

**Action:** Used sp_executesql with strongly-typed parameters instead of string concatenation:
```sql
CREATE PROCEDURE dbo.usp_LoanSearch
    @State CHAR(2) = NULL, @ServicerName VARCHAR(100) = NULL,
    @MinUPB DECIMAL(18,2) = NULL, @MaxUPB DECIMAL(18,2) = NULL
AS
BEGIN
    DECLARE @SQL NVARCHAR(MAX), @Params NVARCHAR(500);
    SET @SQL = N'SELECT loan_number, borrower_name, current_upb, property_state
                 FROM dbo.LoanMaster WHERE 1=1';

    IF @State IS NOT NULL       SET @SQL += N' AND property_state = @pState';
    IF @ServicerName IS NOT NULL SET @SQL += N' AND servicer_name = @pServicer';
    IF @MinUPB IS NOT NULL      SET @SQL += N' AND current_upb >= @pMinUPB';
    IF @MaxUPB IS NOT NULL      SET @SQL += N' AND current_upb <= @pMaxUPB';

    SET @Params = N'@pState CHAR(2), @pServicer VARCHAR(100), @pMinUPB DECIMAL(18,2), @pMaxUPB DECIMAL(18,2)';
    EXEC sp_executesql @SQL, @Params, @pState=@State, @pServicer=@ServicerName, @pMinUPB=@MinUPB, @pMaxUPB=@MaxUPB;
END;
```
sp_executesql separates code from data (preventing injection), enables plan caching with different parameter values, and supports typed parameters. EXEC(@SQL) concatenates values directly -- never safe with user input -- and generates a new plan each time.

**Result:** Parameterized dynamic SQL eliminated injection vulnerabilities found in a security audit. Plan cache hit rate for search queries increased from 15% (with EXEC) to 88% (with sp_executesql), reducing average CPU time per query by 60% across 5,000+ daily search requests.

**AI Vision:** A natural-language-to-SQL interface (like Azure OpenAI integration) could let users type free-text loan search requests that are automatically converted to safe parameterized queries.

---

### Q15. What are the different backup types (Full, Differential, Log) and when to use each?

**Situation:** Our mortgage data warehouse (2.4 TB) held Fannie Mae, Freddie Mac, and Ginnie Mae loan-level data with a 15-minute RPO (recovery point objective) requirement mandated by the enterprise risk management team, and a 4-hour RTO (recovery time objective).

**Task:** Design a backup strategy that met RPO/RTO requirements while minimizing storage costs and backup window impact on the nightly ETL processing.

**Action:** Implemented a layered backup strategy:
```sql
-- Full backup: weekly Sunday 2 AM (captures entire database)
BACKUP DATABASE MortgageWarehouse
TO DISK = 'D:\Backups\MW_Full_20251207.bak'
WITH COMPRESSION, CHECKSUM, STATS = 10;

-- Differential backup: daily at 2 AM (captures changes since last full)
BACKUP DATABASE MortgageWarehouse
TO DISK = 'D:\Backups\MW_Diff_20251210.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM;

-- Transaction log backup: every 15 minutes (captures all log activity since last log backup)
BACKUP LOG MortgageWarehouse
TO DISK = 'D:\Backups\MW_Log_20251210_0815.trn'
WITH COMPRESSION, CHECKSUM;

-- Restore chain: Full + latest Differential + all subsequent Log backups
RESTORE DATABASE MortgageWarehouse FROM DISK = 'MW_Full.bak' WITH NORECOVERY;
RESTORE DATABASE MortgageWarehouse FROM DISK = 'MW_Diff.bak' WITH NORECOVERY;
RESTORE LOG MortgageWarehouse FROM DISK = 'MW_Log_1.trn' WITH NORECOVERY;
RESTORE LOG MortgageWarehouse FROM DISK = 'MW_Log_2.trn' WITH RECOVERY;  -- final
```
Full backup is the baseline. Differential captures only pages changed since the last full (grows over the week). Log backups capture every transaction, enabling point-in-time recovery. COMPRESSION reduced our 2.4 TB full backup to 380 GB.

**Result:** Met the 15-minute RPO with log backups every 15 minutes. Tested restore RTO at 3 hours 10 minutes (under the 4-hour target). Differential backups averaged 120 GB (vs. 380 GB full), saving 1.8 TB weekly in backup storage. Monthly restore drills confirmed the chain integrity.

**AI Vision:** Predictive analytics on backup duration trends and database growth rates could dynamically adjust backup schedules, switching from weekly to bi-weekly fulls during slow-growth periods to optimize storage.

---

### Q16. Explain triggers (AFTER, INSTEAD OF) and their impact on performance

**Situation:** Regulatory compliance required that every change to a Fannie Mae loan's status (Active, Delinquent, Default, REO, Liquidated) be captured in an audit table with the old value, new value, timestamp, and the user who made the change. Additionally, certain status transitions were prohibited (e.g., jumping from Active directly to REO).

**Task:** Implement automatic audit logging for all loan status changes and enforce business rules that prevented invalid state transitions.

**Action:** Created an AFTER trigger for auditing and an INSTEAD OF trigger for validation:
```sql
-- AFTER trigger: fires after the DML succeeds; captures audit trail
CREATE TRIGGER trg_LoanStatus_Audit ON dbo.LoanMaster
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.LoanStatusAudit (loan_number, old_status, new_status, changed_by, changed_at)
    SELECT d.loan_number, d.loan_status, i.loan_status, SYSTEM_USER, GETDATE()
    FROM inserted i
    INNER JOIN deleted d ON i.loan_number = d.loan_number
    WHERE i.loan_status <> d.loan_status;
END;

-- INSTEAD OF trigger: replaces the original DML; enforces valid transitions
CREATE TRIGGER trg_LoanStatus_Validate ON dbo.vw_LoanStatusUpdate
INSTEAD OF UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (
        SELECT 1 FROM inserted i JOIN deleted d ON i.loan_number = d.loan_number
        WHERE d.loan_status = 'Active' AND i.loan_status = 'REO'
    )
    BEGIN
        THROW 50001, 'Invalid transition: Active cannot jump directly to REO.', 1;
        RETURN;
    END;
    UPDATE lm SET lm.loan_status = i.loan_status
    FROM dbo.LoanMaster lm JOIN inserted i ON lm.loan_number = i.loan_number;
END;
```
AFTER triggers fire after constraints are checked and the DML executes. INSTEAD OF triggers replace the DML entirely -- they are the only way to make a complex view updatable. Triggers operate on the full set of affected rows via the inserted/deleted pseudo-tables, never row-by-row.

**Result:** The audit trigger captured 100% of status changes with negligible overhead (3ms added to batch updates of 10,000 loans). The validation trigger prevented 47 invalid state transitions in the first month, each of which would have caused downstream Fannie Mae delivery file errors requiring manual correction.

**AI Vision:** A process mining model could analyze the audit log to discover the most common status transition paths and flag anomalous patterns (e.g., loans that cycle between Delinquent and Current repeatedly) for servicing review.

---

### Q17. How do you monitor and troubleshoot blocking?

**Situation:** During business hours, our mortgage servicing application experienced intermittent timeouts. The help desk received complaints that loan lookup screens froze for 30+ seconds. Initial investigation pointed to blocking chains where a long-running Freddie Mac reconciliation report held locks that queued up dozens of short OLTP queries.

**Task:** Identify the head blocker, quantify the blocking impact, and implement both immediate resolution and long-term monitoring.

**Action:** Used DMVs and built a monitoring framework:
```sql
-- Identify current blocking chains
SELECT
    r.session_id AS blocked_spid,
    r.blocking_session_id AS blocker_spid,
    r.wait_type, r.wait_time / 1000 AS wait_seconds,
    t.text AS blocked_query,
    (SELECT text FROM sys.dm_exec_sql_text(
        (SELECT most_recent_sql_handle FROM sys.dm_exec_connections WHERE session_id = r.blocking_session_id)
    )) AS blocker_query
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id > 0
ORDER BY r.wait_time DESC;

-- Find head blocker (blocks others but is not blocked itself)
SELECT session_id FROM sys.dm_exec_requests
WHERE session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests WHERE blocking_session_id > 0)
  AND blocking_session_id = 0;

-- Long-term: created an alert job that logs blocking chains > 10 seconds
-- and sends email when any session is blocked > 30 seconds
```
Resolved the immediate issue by adding WITH (NOLOCK) to the reconciliation report (read-only, approximate counts were acceptable) and moving it to a readable AG secondary replica. Implemented blocked process threshold alerts.

**Result:** After moving the report to the secondary replica, average blocking duration dropped from 32 seconds to under 1 second. We configured `sp_configure 'blocked process threshold', 10` with an Extended Events session to capture any blocking over 10 seconds. Monthly blocking incidents dropped from 150+ to fewer than 5.

**AI Vision:** An ML model trained on historical blocking patterns (time of day, query types, table combinations) could predict blocking events 10-15 minutes ahead and proactively kill or throttle the likely offending session.

---

### Q18. What is table partitioning and what are its benefits?

**Situation:** Our dbo.LoanPaymentHistory table stored 5 years of monthly payment records for all agency loans -- 720 million rows, 1.8 TB. Queries filtering by reporting_month performed full table scans even with indexing, and archiving old data required massive DELETE operations that caused log bloat and blocking.

**Task:** Implement table partitioning by reporting_month so queries touched only relevant partitions, and aged data could be archived by switching partitions instead of deleting rows.

**Action:** Created a partition function, scheme, and migrated the table:
```sql
-- Step 1: Partition function defines boundary values
CREATE PARTITION FUNCTION pf_MonthlyPayment (DATE)
AS RANGE RIGHT FOR VALUES ('2021-01-01','2021-02-01', /* ... */ '2025-12-01','2026-01-01');

-- Step 2: Partition scheme maps partitions to filegroups
CREATE PARTITION SCHEME ps_MonthlyPayment
AS PARTITION pf_MonthlyPayment ALL TO ([PRIMARY]);  -- or separate filegroups

-- Step 3: Create partitioned clustered index
CREATE CLUSTERED INDEX CIX_Payment_Month ON dbo.LoanPaymentHistory (reporting_month, loan_number)
ON ps_MonthlyPayment(reporting_month);

-- Step 4: Archive old data via partition switch (instant, metadata-only)
ALTER TABLE dbo.LoanPaymentHistory SWITCH PARTITION 1 TO dbo.LoanPaymentHistory_Archive PARTITION 1;

-- Step 5: Add new partition for next month
ALTER PARTITION FUNCTION pf_MonthlyPayment() SPLIT RANGE ('2026-02-01');
```
Partition elimination means queries with `WHERE reporting_month = '2025-12-01'` scan only that one partition (~12 million rows) instead of all 720 million. SWITCH operations are instantaneous because they only change metadata pointers.

**Result:** Monthly reporting queries improved from 4 minutes (full scan) to 12 seconds (single partition scan). Archiving 12 months of old data took 2 seconds via SWITCH versus 6 hours using DELETE. Index maintenance (REBUILD) could target individual partitions, reducing the weekly maintenance window from 8 hours to 45 minutes.

**AI Vision:** Predictive partition management could use data growth forecasts to automatically split future partitions and recommend when to archive based on query access patterns and storage thresholds.

---

### Q19. Explain computed columns and persisted computed columns

**Situation:** Our Fannie Mae loan table required several derived fields used heavily in queries: a debt-to-income ratio (DTI = monthly_debt / monthly_income), a combined LTV (CLTV = total_liens / property_value), and a risk tier classification based on FICO ranges. Analysts kept writing these formulas inconsistently.

**Task:** Centralize the business logic so every query automatically used the same calculation, and optimize frequently filtered computed values for index support.

**Action:** Added computed columns, persisting those that were expensive or needed indexing:
```sql
ALTER TABLE dbo.FannieMae_Loans ADD
    -- Non-persisted: calculated on read, no storage cost
    dti_ratio AS CAST(monthly_debt_payment / NULLIF(monthly_income, 0) AS DECIMAL(5,2)),

    -- Persisted: stored physically, updated on INSERT/UPDATE, can be indexed
    cltv AS CAST((first_lien_upb + ISNULL(second_lien_upb, 0)) / NULLIF(property_value, 0) * 100
               AS DECIMAL(5,2)) PERSISTED,

    -- Persisted with deterministic CASE logic
    risk_tier AS CAST(
        CASE WHEN fico_score >= 740 THEN 'Prime'
             WHEN fico_score >= 680 THEN 'Near-Prime'
             WHEN fico_score >= 620 THEN 'Subprime'
             ELSE 'Deep Subprime' END AS VARCHAR(15)) PERSISTED;

-- Now we can index the persisted computed columns
CREATE NONCLUSTERED INDEX IX_CLTV ON dbo.FannieMae_Loans (cltv) INCLUDE (loan_number, current_upb);
CREATE NONCLUSTERED INDEX IX_RiskTier ON dbo.FannieMae_Loans (risk_tier) INCLUDE (loan_number, fico_score);
```
Non-persisted computed columns use no disk space but recalculate every read. Persisted columns use storage but are pre-calculated. Only deterministic expressions can be persisted or indexed. PERSISTED columns are automatically maintained by the engine on INSERT/UPDATE.

**Result:** Standardized DTI and CLTV calculations across 30+ reports, eliminating discrepancies found in a Fannie Mae audit. The persisted CLTV index supported a critical high-CLTV exposure report that improved from 18 seconds to 400ms. Storage overhead was 14 MB for the three persisted columns across 1.2 million rows.

**AI Vision:** ML-derived risk scores could be stored as persisted computed columns via CLR functions, embedding real-time model predictions directly into the table schema for downstream reporting.

---

### Q20. How do you use STRING_AGG, STRING_SPLIT, and other modern string functions?

**Situation:** Ginnie Mae HMBS (Home Equity Conversion Mortgage-Backed Securities) pool reports required a comma-separated list of all loan numbers per pool for the pool manifest, and incoming servicer files delivered multiple borrower names in a single pipe-delimited field that needed normalization.

**Task:** Aggregate loan numbers into a single delimited string per pool (for export) and split incoming multi-value fields into separate rows (for normalization), replacing legacy XML PATH and custom split functions.

**Action:** Used SQL Server 2017+ string functions:
```sql
-- STRING_AGG: aggregate loan numbers into comma-separated list per pool
SELECT pool_number,
       STRING_AGG(loan_number, ', ') WITHIN GROUP (ORDER BY loan_number) AS loan_list,
       COUNT(*) AS loan_count
FROM dbo.GNMA_HMBS_Loans
GROUP BY pool_number;

-- STRING_SPLIT: parse pipe-delimited borrower names into rows (SQL Server 2016+)
SELECT l.loan_number, TRIM(ss.value) AS borrower_name
FROM dbo.GNMA_HMBS_Loans l
CROSS APPLY STRING_SPLIT(l.borrower_names_raw, '|') ss
WHERE ss.value <> '';

-- STRING_SPLIT with ordinal (SQL Server 2022+): preserves position
SELECT l.loan_number, ss.ordinal, TRIM(ss.value) AS borrower_name
FROM dbo.GNMA_HMBS_Loans l
CROSS APPLY STRING_SPLIT(l.borrower_names_raw, '|', 1) ss;

-- Other modern functions
SELECT TRANSLATE(phone_number, '()-. ', '     ') AS cleaned,  -- character-level replacement
       CONCAT_WS(', ', address_line1, address_line2, city, state, zip) AS full_address,
       TRIM('  John Doe  ') AS trimmed_name;
```
STRING_AGG replaced the verbose FOR XML PATH(''), TYPE trick. STRING_SPLIT replaced thousands of lines of custom TVF split functions. The ordinal parameter in 2022 was critical because original STRING_SPLIT did not guarantee order.

**Result:** Pool manifest generation using STRING_AGG ran in 3 seconds versus 22 seconds with the old FOR XML PATH approach across 15,000 pools. STRING_SPLIT normalized 2 million multi-borrower records in 8 seconds, replacing a row-by-row CLR function that took 12 minutes.

**AI Vision:** Entity resolution models could process the split borrower names, matching variations (e.g., "Robert Smith" vs. "Bob Smith") across loans to detect co-borrower networks and potential fraud rings.

---

### Q21. What are database snapshots and how would you use them?

**Situation:** Our month-end close process for Freddie Mac investor accounting involved running a sequence of 15 stored procedures that updated pool balances, calculated remittance amounts, and generated settlement files. If any step produced incorrect results, the team needed to see what the data looked like before the process started.

**Task:** Create a point-in-time reference of the database before month-end processing so analysts could compare before/after values and, if needed, revert specific tables without restoring from backup.

**Action:** Created a database snapshot before the month-end run:
```sql
-- Create snapshot before month-end processing begins
CREATE DATABASE MortgageWarehouse_MonthEnd_Snap ON (
    NAME = MortgageWarehouse_Data,
    FILENAME = 'D:\Snapshots\MW_MonthEnd_20251201.ss'
) AS SNAPSHOT OF MortgageWarehouse;

-- Compare before/after pool balances
SELECT s.pool_id, s.total_upb AS before_upb, c.total_upb AS after_upb,
       c.total_upb - s.total_upb AS upb_change
FROM MortgageWarehouse_MonthEnd_Snap.dbo.PoolFactor s
JOIN MortgageWarehouse.dbo.PoolFactor c ON s.pool_id = c.pool_id
WHERE ABS(c.total_upb - s.total_upb) > 1000000;  -- flag large changes

-- Emergency revert of a single table (if month-end calc was wrong)
INSERT INTO MortgageWarehouse.dbo.PoolFactor
SELECT * FROM MortgageWarehouse_MonthEnd_Snap.dbo.PoolFactor;
-- (after truncating the target table)

-- Clean up after month-end verification is complete
DROP DATABASE MortgageWarehouse_MonthEnd_Snap;
```
Snapshots use copy-on-write: only pages that change after snapshot creation are stored in the sparse file. They are read-only and point-in-time. They are NOT a backup replacement (they depend on the source database). Multiple snapshots can exist simultaneously.

**Result:** Month-end verification time dropped from 2 hours (manually comparing backup restores) to 15 minutes (direct snapshot queries). The snapshot consumed only 45 GB of sparse file space (vs. 2.4 TB database) since only 2% of pages changed during processing. Three times in the first year, the team used snapshots to identify and correct month-end calculation errors before investor files shipped.

**AI Vision:** Automated drift detection could compare snapshot-to-current data and use statistical models to flag any pool balance changes that deviate from expected prepayment and curtailment patterns.

---

### Q22. Explain the difference between implicit and explicit transactions

**Situation:** A junior developer wrote a data correction script to update 50,000 Fannie Mae loan records' property types from "SF" to "Single Family." The script ran each UPDATE individually without explicit transaction control. Midway through, a network error killed the session, leaving 28,000 records updated and 22,000 unchanged -- a partial update that caused inconsistencies in downstream reporting.

**Task:** Explain why the partial update occurred, fix the immediate data inconsistency, and establish coding standards to prevent similar issues.

**Action:** Demonstrated the difference between implicit and explicit transactions:
```sql
-- IMPLICIT transaction (auto-commit mode, SQL Server default)
-- Each statement is its own transaction; commits immediately
UPDATE dbo.FannieMae_Loans SET property_type = 'Single Family'
WHERE property_type = 'SF' AND loan_number = '123456';  -- auto-commits on success

-- EXPLICIT transaction: wraps multiple statements atomically
BEGIN TRANSACTION;
    UPDATE dbo.FannieMae_Loans SET property_type = 'Single Family'
    WHERE property_type = 'SF';  -- all 50,000 rows in one atomic operation

    -- Verify before committing
    IF @@ROWCOUNT <> (SELECT COUNT(*) FROM staging.ExpectedUpdates)
    BEGIN
        ROLLBACK TRANSACTION;
        THROW 50001, 'Row count mismatch -- rolling back.', 1;
    END
    ELSE COMMIT TRANSACTION;

-- IMPLICIT_TRANSACTIONS mode (SET IMPLICIT_TRANSACTIONS ON):
-- Every statement starts a transaction automatically but does NOT auto-commit;
-- you must explicitly COMMIT or ROLLBACK. Rarely used; can cause orphan transactions.
```
In auto-commit (default), each statement is an implicit transaction that commits on success. If the session dies mid-batch, completed statements stay committed. Explicit transactions with BEGIN/COMMIT ensure all-or-nothing atomicity. Always scope explicit transactions as tightly as possible to minimize lock duration.

**Result:** Rolled back the partial update by using the pre-change values from an audit table, then re-ran the correction as a single explicit transaction. Established a team policy requiring all bulk data corrections to use explicit transactions with verification counts. Zero partial-update incidents in the following 18 months.

**AI Vision:** Static code analysis tools enhanced with ML could scan stored procedures and scripts for missing explicit transaction wrappers around multi-statement DML, flagging them as risks before deployment.

---

### Q23. How do you implement slowly changing dimensions (SCD Type 1, 2, 3) in SQL Server?

**Situation:** Our mortgage data warehouse tracked servicer information for Fannie Mae and Freddie Mac loans. Servicers changed names (acquisitions), addresses, and contact info over time. Regulatory reporting required both current data and historical point-in-time accuracy for when-as-of queries.

**Task:** Implement SCD handling where servicer name changes were tracked historically (Type 2), phone number was always overwritten (Type 1), and we kept one previous value for primary contact (Type 3).

**Action:** Designed the dim_Servicer table to support all three SCD types:
```sql
-- SCD Type 2: Full history with effective dating
CREATE TABLE dbo.dim_Servicer (
    servicer_key INT IDENTITY PRIMARY KEY,     -- surrogate key
    servicer_id VARCHAR(10) NOT NULL,           -- business key
    servicer_name VARCHAR(100),                 -- Type 2 tracked
    phone_number VARCHAR(20),                   -- Type 1 overwrite
    primary_contact VARCHAR(100),               -- Type 3 (current + previous)
    previous_contact VARCHAR(100),              -- Type 3 previous value
    effective_date DATE NOT NULL,
    expiration_date DATE NOT NULL DEFAULT '9999-12-31',
    is_current BIT NOT NULL DEFAULT 1
);

-- MERGE-based SCD Type 2 processing
MERGE dbo.dim_Servicer AS tgt
USING staging.Servicer_Update AS src ON tgt.servicer_id = src.servicer_id AND tgt.is_current = 1
WHEN MATCHED AND tgt.servicer_name <> src.servicer_name THEN
    UPDATE SET tgt.expiration_date = CAST(GETDATE() AS DATE), tgt.is_current = 0
WHEN MATCHED AND tgt.servicer_name = src.servicer_name THEN
    -- Type 1: overwrite phone; Type 3: rotate contact
    UPDATE SET tgt.phone_number = src.phone_number,
               tgt.previous_contact = tgt.primary_contact,
               tgt.primary_contact = src.primary_contact
WHEN NOT MATCHED BY TARGET THEN
    INSERT (servicer_id, servicer_name, phone_number, primary_contact, effective_date)
    VALUES (src.servicer_id, src.servicer_name, src.phone_number, src.primary_contact, GETDATE());

-- Insert new Type 2 row for name changes (expired above)
INSERT INTO dbo.dim_Servicer (servicer_id, servicer_name, phone_number, primary_contact, effective_date)
SELECT src.servicer_id, src.servicer_name, src.phone_number, src.primary_contact, CAST(GETDATE() AS DATE)
FROM staging.Servicer_Update src
JOIN dbo.dim_Servicer tgt ON src.servicer_id = tgt.servicer_id
WHERE tgt.is_current = 0 AND tgt.expiration_date = CAST(GETDATE() AS DATE);
```
Type 1 overwrites in place (no history). Type 2 creates a new row with effective/expiration dates. Type 3 stores current and one previous value in separate columns.

**Result:** Historical queries could accurately report which servicer name was active for a loan on any given date, satisfying FHFA examination requirements. The SCD2 design added 15% row growth annually but enabled accurate as-of reporting for 10 years of servicer history across 3,400 servicer entities.

**AI Vision:** Change detection models could predict which servicers are likely acquisition targets based on market signals, pre-staging SCD2 updates for smoother processing during bulk servicer transfers.

---

### Q24. What is the OUTPUT clause and how do you use it?

**Situation:** During Freddie Mac loan liquidation processing, we needed to move loans from the active dbo.LoanMaster table to dbo.LoanLiquidated_Archive, capturing the exact rows deleted. Additionally, when inserting new loans, we needed to return the auto-generated surrogate keys to the calling application for downstream processing.

**Task:** Implement atomic move operations (DELETE from source, INSERT to archive) and capture identity values from bulk inserts -- all without using triggers or temporary staging tables.

**Action:** Leveraged the OUTPUT clause in various DML statements:
```sql
-- OUTPUT with DELETE: capture deleted rows into archive
DELETE FROM dbo.LoanMaster
OUTPUT deleted.loan_number, deleted.current_upb, deleted.loan_status,
       deleted.servicer_id, GETDATE() AS archived_date
INTO dbo.LoanLiquidated_Archive (loan_number, final_upb, final_status, servicer_id, archived_date)
WHERE loan_status = 'Liquidated' AND liquidation_date < DATEADD(MONTH, -6, GETDATE());

-- OUTPUT with INSERT: return generated identity keys
DECLARE @NewLoanKeys TABLE (loan_key INT, loan_number VARCHAR(20));

INSERT INTO dbo.LoanMaster (loan_number, borrower_name, current_upb, origination_date)
OUTPUT inserted.loan_key, inserted.loan_number INTO @NewLoanKeys
SELECT loan_number, borrower_name, original_upb, origination_date
FROM staging.NewFreddieMac_Loans;

-- Use the captured keys for downstream inserts
INSERT INTO dbo.LoanAttribute (loan_key, attribute_code, attribute_value)
SELECT k.loan_key, 'POOL_ELIGIBLE', 'Y'
FROM @NewLoanKeys k;

-- OUTPUT with UPDATE: track what changed (like a lightweight audit)
UPDATE dbo.LoanMaster
SET loan_status = 'Default'
OUTPUT inserted.loan_number, deleted.loan_status AS old_status, inserted.loan_status AS new_status
WHERE days_delinquent >= 180 AND loan_status = 'Delinquent';
```
The OUTPUT clause accesses the `inserted` and `deleted` pseudo-tables (similar to triggers). It can output to a table variable, physical table (via INTO), or return results to the client. It executes atomically with the DML statement.

**Result:** The atomic DELETE-to-archive operation processed 35,000 liquidated loans monthly with zero data loss risk, replacing a three-step DELETE/INSERT/verify process that occasionally lost rows during failures. Identity key capture eliminated a round-trip SELECT after each INSERT, reducing loan boarding throughput time by 25%.

**AI Vision:** OUTPUT clause data streams could feed real-time ML scoring pipelines, instantly evaluating newly boarded loans for fraud risk the moment they are inserted.

---

### Q25. Explain how to use SQL Server Profiler vs Extended Events for monitoring

**Situation:** Our production mortgage data warehouse experienced periodic performance degradation during Fannie Mae CAS (Connecticut Avenue Securities) deal modeling runs. We needed to capture the exact queries, their durations, and resource usage to identify the problematic workload -- but could not add significant overhead to an already stressed production server.

**Task:** Implement lightweight production monitoring to capture queries exceeding 5 seconds, identify the heaviest resource consumers, and establish a long-term monitoring framework with minimal performance impact.

**Action:** Migrated from SQL Server Profiler to Extended Events (XE) for production use:
```sql
-- SQL Server Profiler: GUI-based, uses SQL Trace under the hood
-- HIGH overhead (15-25% CPU impact), synchronous collection
-- OK for development/test but NOT recommended for production
-- Deprecated in future SQL Server versions

-- Extended Events: lightweight, asynchronous, production-safe
CREATE EVENT SESSION [SlowQuery_Monitor] ON SERVER
ADD EVENT sqlserver.sql_statement_completed (
    SET collect_statement = (1)
    ACTION (sqlserver.sql_text, sqlserver.session_id, sqlserver.database_name,
            sqlserver.username, sqlserver.client_app_name)
    WHERE duration > 5000000  -- 5 seconds in microseconds
      AND sqlserver.database_name = N'MortgageWarehouse'
),
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.event_file (
    SET filename = N'D:\XEvents\SlowQuery_Monitor.xel', max_file_size = (100),
    max_rollover_files = (5)
)
WITH (MAX_MEMORY = 4096 KB, MAX_DISPATCH_LATENCY = 10 SECONDS);

ALTER EVENT SESSION [SlowQuery_Monitor] ON SERVER STATE = START;

-- Query the captured events
SELECT
    event_data.value('(event/@timestamp)[1]', 'DATETIME2') AS event_time,
    event_data.value('(event/action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text,
    event_data.value('(event/data[@name="duration"]/value)[1]', 'BIGINT') / 1000000.0 AS duration_sec,
    event_data.value('(event/data[@name="logical_reads"]/value)[1]', 'BIGINT') AS logical_reads
FROM (
    SELECT CAST(event_data AS XML) AS event_data
    FROM sys.fn_xe_file_target_read_file('D:\XEvents\SlowQuery_Monitor*.xel', NULL, NULL, NULL)
) x
ORDER BY duration_sec DESC;
```
Extended Events use an asynchronous, in-memory buffered architecture with 1-3% overhead versus Profiler's 15-25%. XE supports filtering at collection time (predicates), multiple targets (file, ring buffer, histogram), and scales to capture millions of events.

**Result:** Extended Events identified three CAS modeling queries averaging 45 seconds each that were causing tempdb contention. After tuning those queries (adding missing indexes and rewriting correlated subqueries), peak processing time dropped by 40%. The XE session ran continuously for 6 months with less than 1% measurable CPU overhead, providing ongoing visibility into slow query trends.

**AI Vision:** ML models trained on Extended Events telemetry could learn normal query duration baselines per workload window and automatically alert on anomalous patterns, distinguishing genuine degradation from expected month-end spikes.

---

### Q26. How do you use UNPIVOT to transform columnar monthly performance data into rows?

**Situation:** Fannie Mae's Single-Family Loan Performance dataset delivered monthly snapshots in a wide format -- each record had columns like `upb_month1`, `upb_month2`, ... `upb_month60` representing 60 months of unpaid principal balance history. Analysts and downstream ML pipelines required a normalized row-per-month structure for time-series modeling.

**Task:** Transform the wide-format columnar data into a tall/narrow table with one row per loan per month, preserving the month identifier and handling NULL months (where the loan did not yet exist or had been liquidated).

**Action:** Used UNPIVOT to rotate the 60 UPB columns into rows:
```sql
-- UNPIVOT wide monthly columns into normalized rows
SELECT
    loan_id,
    origination_date,
    month_label,
    unpaid_principal_balance
FROM dbo.FNMA_LoanPerformance_Wide
UNPIVOT (
    unpaid_principal_balance FOR month_label IN (
        upb_month1,  upb_month2,  upb_month3,  upb_month4,  upb_month5,
        upb_month6,  upb_month7,  upb_month8,  upb_month9,  upb_month10,
        upb_month11, upb_month12, upb_month13, upb_month14, upb_month15,
        upb_month16, upb_month17, upb_month18, upb_month19, upb_month20,
        upb_month21, upb_month22, upb_month23, upb_month24, upb_month25,
        upb_month26, upb_month27, upb_month28, upb_month29, upb_month30
    )
) AS unpvt;

-- Extract numeric month from the label for ordering and joining
SELECT
    loan_id,
    origination_date,
    CAST(REPLACE(month_label, 'upb_month', '') AS INT) AS month_number,
    DATEADD(MONTH, CAST(REPLACE(month_label, 'upb_month', '') AS INT) - 1, origination_date) AS performance_month,
    unpaid_principal_balance
FROM (
    SELECT loan_id, origination_date, month_label, unpaid_principal_balance
    FROM dbo.FNMA_LoanPerformance_Wide
    UNPIVOT (
        unpaid_principal_balance FOR month_label IN (
            upb_month1, upb_month2, upb_month3, upb_month4, upb_month5,
            upb_month6, upb_month7, upb_month8, upb_month9, upb_month10
        )
    ) AS unpvt
) normalized
ORDER BY loan_id, month_number;
```
UNPIVOT requires all rotated columns to share the same data type. NULLs are automatically excluded by UNPIVOT -- if `upb_month15` is NULL for a loan, that row simply does not appear. To include NULLs, replace them with a sentinel value (e.g., -1) before unpivoting and filter afterward.

**Result:** The normalized table grew from 2 million wide rows to 48 million tall rows, enabling standard GROUP BY time-series queries. Monthly delinquency trend reports that previously required dynamic SQL across 60 columns now used simple WHERE clauses on `month_number`, reducing query development time by 70%.

**AI Vision:** Automated schema detection models could identify wide-format columns following naming patterns (like `upb_month*`) and recommend UNPIVOT transformations during data ingestion pipeline setup.

---

### Q27. How do you build a recursive CTE for tranche subordination hierarchies?

**Situation:** Freddie Mac's STACR (Structured Agency Credit Risk) deals contain tranche waterfall structures where credit losses flow from the lowest subordinate tranche upward. Each tranche references its parent in the capital structure -- for example, M-2 absorbs losses before M-1, which absorbs before the senior class. The Intex deal model required us to walk this hierarchy programmatically.

**Task:** Build a recursive query that starts from the first-loss tranche and walks upward through the subordination chain, calculating cumulative credit enhancement at each level.

**Action:** Implemented a recursive CTE to traverse the tranche hierarchy:
```sql
WITH TrancheHierarchy AS (
    -- Anchor: first-loss (equity/residual) tranche at bottom of waterfall
    SELECT
        tranche_id,
        deal_id,
        tranche_name,
        parent_tranche_id,
        original_balance,
        credit_enhancement_pct,
        1 AS subordination_level,
        CAST(tranche_name AS VARCHAR(500)) AS waterfall_path
    FROM dbo.STACR_Tranche
    WHERE parent_tranche_id IS NULL  -- bottom of the stack
      AND deal_id = 'STACR-2025-DNA3'

    UNION ALL

    -- Recursive: walk up the subordination chain
    SELECT
        child.tranche_id,
        child.deal_id,
        child.tranche_name,
        child.parent_tranche_id,
        child.original_balance,
        child.credit_enhancement_pct,
        parent.subordination_level + 1,
        CAST(parent.waterfall_path + ' -> ' + child.tranche_name AS VARCHAR(500))
    FROM dbo.STACR_Tranche child
    INNER JOIN TrancheHierarchy parent
        ON child.parent_tranche_id = parent.tranche_id
)
SELECT
    tranche_name,
    subordination_level,
    original_balance,
    credit_enhancement_pct,
    waterfall_path,
    SUM(original_balance) OVER (ORDER BY subordination_level
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_subordination
FROM TrancheHierarchy
ORDER BY subordination_level
OPTION (MAXRECURSION 20);
```
The anchor member selects the first-loss tranche (no parent). The recursive member joins children to already-found parents. MAXRECURSION 20 prevents runaway recursion -- typical MBS deals have 5-15 tranche levels. The cumulative window sum shows total subordination below each tranche.

**Result:** The recursive waterfall query replaced a 300-line cursor-based stored procedure, executing in 200ms versus 8 seconds. Credit risk analysts could instantly visualize subordination depth for any STACR deal, accelerating deal comparison workflows by 85%.

**AI Vision:** Graph neural networks could ingest these hierarchical tranche structures to predict loss allocation patterns under stress scenarios, learning from historical deal performance.

---

### Q28. How do you use STRING_AGG and STRING_SPLIT for loan pool aggregation and parsing?

**Situation:** Ginnie Mae pool data frequently arrived with multiple loan attributes packed into delimited strings -- for example, a single field containing all CUSIP numbers in a multi-issuer pool separated by pipes. Conversely, reporting required aggregating individual loan numbers into comma-separated lists per pool for downstream consumption by CoreLogic's property matching system.

**Task:** Parse delimited CUSIP fields into individual rows for joining, and aggregate loan numbers per pool into a single string for report generation.

**Action:** Used STRING_SPLIT for parsing and STRING_AGG for aggregation:
```sql
-- STRING_SPLIT: break pipe-delimited CUSIPs into individual rows
SELECT
    p.pool_number,
    p.issuer_name,
    TRIM(cusip.value) AS individual_cusip,
    p.pool_upb
FROM dbo.GNMA_MultiIssuerPool p
CROSS APPLY STRING_SPLIT(p.cusip_list, '|') AS cusip
WHERE p.pool_type = 'Platinum';

-- STRING_AGG: aggregate loan numbers into comma-separated list per pool
SELECT
    pool_number,
    COUNT(*) AS loan_count,
    SUM(current_upb) AS total_upb,
    STRING_AGG(CAST(loan_number AS VARCHAR(20)), ', ')
        WITHIN GROUP (ORDER BY loan_number) AS loan_list
FROM dbo.GNMA_PoolLoans
WHERE pool_issue_date >= '2025-01-01'
GROUP BY pool_number
HAVING COUNT(*) <= 100;  -- limit string length for practical use

-- Combining both: parse incoming feed, then re-aggregate by servicer
SELECT
    l.servicer_id,
    s.servicer_name,
    COUNT(DISTINCT parsed.value) AS unique_property_states,
    STRING_AGG(DISTINCT TRIM(parsed.value), ', ')
        WITHIN GROUP (ORDER BY TRIM(parsed.value)) AS state_list
FROM dbo.GNMA_LoanDetail l
CROSS APPLY STRING_SPLIT(l.property_state_history, ';') AS parsed
INNER JOIN dbo.Servicer s ON l.servicer_id = s.servicer_id
GROUP BY l.servicer_id, s.servicer_name
ORDER BY unique_property_states DESC;
```
STRING_SPLIT returns a table with a `value` column. In SQL Server 2022, it also returns an `ordinal` column when using `STRING_SPLIT(col, delimiter, 1)`. STRING_AGG has an 8000-byte limit for VARCHAR and unlimited for NVARCHAR(MAX). WITHIN GROUP controls sort order of the concatenated result.

**Result:** Replacing XML PATH-based concatenation with STRING_AGG reduced report generation time from 12 minutes to 90 seconds for 500,000 loans. STRING_SPLIT eliminated a CLR function dependency for parsing, simplifying deployment across 15 database servers.

**AI Vision:** NLP models could parse unstructured loan notes and comments into structured delimited fields, which STRING_SPLIT then normalizes into queryable rows for automated compliance checking.

---

### Q29. How do you implement OFFSET-FETCH with dynamic paging for a loan search API?

**Situation:** Our team built a REST API layer over the Freddie Mac loan-level dataset allowing capital markets analysts to search and page through millions of loan records. The front-end displayed 50 loans per page and needed consistent, performant pagination without loading entire result sets into memory.

**Task:** Implement server-side pagination using OFFSET-FETCH that supported dynamic page sizes, maintained consistent ordering, and performed well even on page 10,000+ of large result sets.

**Action:** Built parameterized paging queries with keyset fallback:
```sql
-- Basic OFFSET-FETCH pagination
DECLARE @PageNumber INT = 1;
DECLARE @PageSize INT = 50;

SELECT
    loan_number,
    origination_date,
    original_upb,
    current_interest_rate,
    property_state,
    credit_score,
    loan_status
FROM dbo.FHLMC_LoanLevel
WHERE property_state = 'CA'
  AND origination_date >= '2023-01-01'
ORDER BY loan_number
OFFSET (@PageNumber - 1) * @PageSize ROWS
FETCH NEXT @PageSize ROWS ONLY;

-- Include total count for UI pagination controls
SELECT
    COUNT(*) OVER () AS total_matching_loans,
    loan_number,
    origination_date,
    original_upb,
    current_interest_rate,
    property_state
FROM dbo.FHLMC_LoanLevel
WHERE property_state = 'CA'
  AND origination_date >= '2023-01-01'
ORDER BY loan_number
OFFSET (@PageNumber - 1) * @PageSize ROWS
FETCH NEXT @PageSize ROWS ONLY;

-- Keyset pagination for deep pages (better performance than large OFFSET)
DECLARE @LastLoanNumber BIGINT = 5000000;  -- last loan_number from previous page

SELECT TOP (@PageSize)
    loan_number,
    origination_date,
    original_upb,
    current_interest_rate,
    property_state
FROM dbo.FHLMC_LoanLevel
WHERE property_state = 'CA'
  AND origination_date >= '2023-01-01'
  AND loan_number > @LastLoanNumber
ORDER BY loan_number;
```
OFFSET-FETCH is simple but degrades on deep pages because the server must scan and discard all preceding rows. For page 10,000 at 50 rows/page, it skips 500,000 rows. Keyset pagination uses a WHERE clause on the last seen key value, providing O(1) page access regardless of depth. The trade-off is keyset requires a unique, sequential ordering column.

**Result:** Keyset pagination maintained sub-100ms response times even at page 50,000, whereas OFFSET-FETCH degraded to 3+ seconds beyond page 1,000. The API served 200 concurrent analyst sessions with consistent performance across 45 million loan records.

**AI Vision:** Predictive pre-fetching models could anticipate which pages an analyst will request next based on their browsing patterns, pre-caching results for instant delivery.

---

### Q30. How do GROUPING SETS, CUBE, and ROLLUP work for multi-level MBS reporting?

**Situation:** Monthly investor reporting for Fannie Mae MBS required aggregated UPB totals at multiple levels simultaneously: by agency, by vintage year, by product type, all combinations thereof, plus grand totals. Running separate GROUP BY queries for each level was duplicative and slow.

**Task:** Produce a single result set containing subtotals at every combination level -- agency, vintage, product, and grand total -- for a monthly MBS summary report distributed to institutional investors.

**Action:** Used GROUPING SETS, ROLLUP, and CUBE to generate multi-level aggregations:
```sql
-- GROUPING SETS: explicit control over which grouping combinations
SELECT
    COALESCE(agency_code, 'ALL AGENCIES') AS agency,
    COALESCE(CAST(vintage_year AS VARCHAR), 'ALL YEARS') AS vintage,
    COALESCE(product_type, 'ALL PRODUCTS') AS product,
    COUNT(*) AS pool_count,
    SUM(current_upb) AS total_upb,
    AVG(weighted_avg_coupon) AS avg_coupon,
    GROUPING(agency_code) AS is_agency_agg,
    GROUPING(vintage_year) AS is_vintage_agg,
    GROUPING(product_type) AS is_product_agg
FROM dbo.MBS_PoolSummary
WHERE reporting_month = '2025-12-01'
GROUP BY GROUPING SETS (
    (agency_code, vintage_year, product_type),  -- detail level
    (agency_code, vintage_year),                 -- by agency + vintage
    (agency_code),                               -- by agency only
    ()                                           -- grand total
);

-- ROLLUP: hierarchical subtotals (agency > vintage > product)
SELECT
    agency_code, vintage_year, product_type,
    SUM(current_upb) AS total_upb,
    COUNT(*) AS pool_count
FROM dbo.MBS_PoolSummary
WHERE reporting_month = '2025-12-01'
GROUP BY ROLLUP (agency_code, vintage_year, product_type);

-- CUBE: all possible combinations (2^n groupings)
SELECT
    agency_code, vintage_year, product_type,
    SUM(current_upb) AS total_upb,
    GROUPING_ID(agency_code, vintage_year, product_type) AS grouping_level
FROM dbo.MBS_PoolSummary
WHERE reporting_month = '2025-12-01'
GROUP BY CUBE (agency_code, vintage_year, product_type);
```
ROLLUP generates n+1 groupings in hierarchical order. CUBE generates 2^n groupings for all combinations. GROUPING SETS gives explicit control. The GROUPING() function returns 1 when a column is aggregated (NULL due to grouping, not data). GROUPING_ID() returns a bitmask identifying the grouping level.

**Result:** A single GROUPING SETS query replaced 8 separate GROUP BY queries, reducing the investor report generation from 45 minutes to 6 minutes. The report covered 12,000 pools across 3 agencies, 20 vintages, and 5 product types in one scan of the data.

**AI Vision:** Automated report generation systems could use GROUPING_ID bitmasks to dynamically render drill-down dashboards, with ML models highlighting statistically significant deviations at each aggregation level.

---

### Q31. How do temporal tables (system-versioned) track loan modification history?

**Situation:** Fannie Mae loan modifications (rate reductions, term extensions, forbearance) required full auditability -- regulators needed to see the exact state of any loan at any point in time. Manual history tables maintained by triggers were error-prone and missed concurrent updates.

**Task:** Implement system-versioned temporal tables so that every change to a loan record is automatically captured with valid-from/valid-to timestamps, enabling point-in-time queries without application code changes.

**Action:** Created temporal tables with system versioning:
```sql
-- Create or alter the loan master table with temporal versioning
CREATE TABLE dbo.FNMA_LoanMaster (
    loan_id BIGINT NOT NULL PRIMARY KEY CLUSTERED,
    loan_number VARCHAR(20) NOT NULL,
    current_upb DECIMAL(14,2),
    interest_rate DECIMAL(5,3),
    loan_status VARCHAR(20),
    servicer_id INT,
    modification_flag BIT DEFAULT 0,
    modification_type VARCHAR(50),
    -- System-time columns
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START NOT NULL,
    SysEndTime   DATETIME2 GENERATED ALWAYS AS ROW END NOT NULL,
    PERIOD FOR SYSTEM_TIME (SysStartTime, SysEndTime)
)
WITH (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = dbo.FNMA_LoanMaster_History,
    DATA_CONSISTENCY_CHECK = ON
));

-- Query: what was the loan state on a specific date?
SELECT loan_number, current_upb, interest_rate, loan_status, modification_type
FROM dbo.FNMA_LoanMaster
FOR SYSTEM_TIME AS OF '2025-06-15 00:00:00'
WHERE loan_number = 'FN-2024-001234';

-- Query: all changes to a loan over a date range
SELECT loan_number, current_upb, interest_rate, loan_status,
       SysStartTime, SysEndTime
FROM dbo.FNMA_LoanMaster
FOR SYSTEM_TIME BETWEEN '2025-01-01' AND '2025-12-31'
WHERE loan_number = 'FN-2024-001234'
ORDER BY SysStartTime;

-- Query: track rate reduction modifications over time
SELECT loan_number, interest_rate, modification_type, SysStartTime
FROM dbo.FNMA_LoanMaster
FOR SYSTEM_TIME ALL
WHERE loan_number = 'FN-2024-001234'
  AND modification_flag = 1
ORDER BY SysStartTime;
```
The SQL Server engine automatically moves old row versions to the history table on UPDATE/DELETE. FOR SYSTEM_TIME AS OF returns the exact row state at a timestamp. FOR SYSTEM_TIME BETWEEN returns all versions that overlap a range. The history table can be separately indexed and compressed.

**Result:** Temporal tables eliminated 40 trigger-based audit tables and their maintenance overhead. Point-in-time regulatory queries that previously required complex self-joins across audit logs now ran in under 500ms, enabling same-day response to examiner data requests.

**AI Vision:** Time-series ML models could query temporal tables to analyze loan modification effectiveness over time, predicting which modification types lead to re-default based on historical state transitions.

---

### Q32. How do indexed views pre-compute pool-level summaries?

**Situation:** Analysts queried Freddie Mac pool-level aggregations hundreds of times daily -- total UPB, weighted average coupon, average FICO, delinquency rate per pool. Each query scanned millions of loan-level rows. The aggregations were deterministic and changed only during nightly ETL loads.

**Task:** Create materialized/indexed views that pre-compute pool-level summaries, so the optimizer can satisfy queries directly from the pre-aggregated index without touching the base loan-level table.

**Action:** Built indexed views with the required constraints:
```sql
-- Indexed views require SCHEMABINDING and deterministic expressions
CREATE VIEW dbo.vw_FHLMC_PoolSummary
WITH SCHEMABINDING
AS
SELECT
    p.pool_number,
    p.agency_code,
    p.vintage_year,
    COUNT_BIG(*) AS loan_count,
    SUM(l.current_upb) AS total_upb,
    SUM(l.current_upb * l.current_interest_rate) AS weighted_coupon_numerator,
    SUM(CASE WHEN l.days_delinquent >= 60 THEN 1 ELSE 0 END) AS delinquent_60plus_count,
    SUM(l.original_upb) AS total_original_upb
FROM dbo.FHLMC_LoanDetail l
INNER JOIN dbo.FHLMC_Pool p ON l.pool_number = p.pool_number
GROUP BY p.pool_number, p.agency_code, p.vintage_year;
GO

-- Materialize with a unique clustered index
CREATE UNIQUE CLUSTERED INDEX IX_PoolSummary_PoolNumber
ON dbo.vw_FHLMC_PoolSummary (pool_number);

-- Add nonclustered indexes for common query patterns
CREATE NONCLUSTERED INDEX IX_PoolSummary_Vintage
ON dbo.vw_FHLMC_PoolSummary (vintage_year)
INCLUDE (total_upb, loan_count);

-- Queries automatically use the indexed view (Enterprise Edition)
SELECT
    pool_number,
    loan_count,
    total_upb,
    weighted_coupon_numerator / NULLIF(total_upb, 0) AS weighted_avg_coupon,
    CAST(delinquent_60plus_count AS FLOAT) / loan_count * 100 AS delinquency_rate_pct
FROM dbo.vw_FHLMC_PoolSummary
WHERE vintage_year = 2024;
```
Indexed views require SCHEMABINDING (locking the view to the base table schema), COUNT_BIG (not COUNT), no OUTER JOINs, no subqueries, no non-deterministic functions. SQL Server Enterprise Edition automatically matches queries to indexed views even if the query does not reference the view. Standard Edition requires the NOEXPAND hint.

**Result:** Pool summary queries dropped from 15 seconds (scanning 40 million loan rows) to 50 milliseconds (reading the pre-computed index of 250,000 pool rows). The indexed view added approximately 2 minutes to nightly ETL but saved 4+ hours of cumulative query time per day.

**AI Vision:** Automated workload analysis could identify frequently executed aggregation patterns and recommend indexed view candidates, with ML models predicting the cost/benefit trade-off of materialization versus recomputation.

---

### Q33. How do you partition tables for managing historical loan performance by vintage year?

**Situation:** The Fannie Mae loan performance history table contained 2 billion rows spanning 20 years of vintage data. Queries almost always filtered by vintage year, but full table scans occurred because there was no physical data separation. Maintenance operations (index rebuilds, statistics updates) required 8-hour windows.

**Task:** Implement table partitioning by vintage year so that queries automatically skip irrelevant partitions (partition elimination), and maintenance can target individual years.

**Action:** Created a partition function, scheme, and applied to the table:
```sql
-- Step 1: Create partition function (boundary values for vintage years)
CREATE PARTITION FUNCTION pf_VintageYear (INT)
AS RANGE RIGHT FOR VALUES (
    2005, 2006, 2007, 2008, 2009, 2010, 2011, 2012,
    2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020,
    2021, 2022, 2023, 2024, 2025, 2026
);

-- Step 2: Map partitions to filegroups (one per vintage for I/O isolation)
CREATE PARTITION SCHEME ps_VintageYear
AS PARTITION pf_VintageYear
TO (
    FG_Pre2005, FG_2005, FG_2006, FG_2007, FG_2008, FG_2009,
    FG_2010, FG_2011, FG_2012, FG_2013, FG_2014, FG_2015,
    FG_2016, FG_2017, FG_2018, FG_2019, FG_2020, FG_2021,
    FG_2022, FG_2023, FG_2024, FG_2025, FG_2026, FG_Future
);

-- Step 3: Create partitioned table
CREATE TABLE dbo.FNMA_LoanPerformance (
    loan_id BIGINT NOT NULL,
    vintage_year INT NOT NULL,
    reporting_month DATE NOT NULL,
    current_upb DECIMAL(14,2),
    delinquency_status VARCHAR(5),
    loan_status VARCHAR(20),
    CONSTRAINT PK_LoanPerf PRIMARY KEY CLUSTERED (vintage_year, loan_id, reporting_month)
) ON ps_VintageYear (vintage_year);

-- Query with partition elimination (only scans 2024 partition)
SELECT loan_id, reporting_month, current_upb, delinquency_status
FROM dbo.FNMA_LoanPerformance
WHERE vintage_year = 2024
  AND delinquency_status IN ('30', '60', '90');

-- Maintenance on single partition (rebuild index for vintage 2020 only)
ALTER INDEX PK_LoanPerf ON dbo.FNMA_LoanPerformance
REBUILD PARTITION = 16;  -- partition number for 2020

-- Check partition usage
SELECT partition_number, rows, data_compression_desc
FROM sys.partitions
WHERE object_id = OBJECT_ID('dbo.FNMA_LoanPerformance')
  AND index_id = 1
ORDER BY partition_number;
```
RANGE RIGHT means each boundary value is the lower bound of its partition. The partition key must be part of the clustered index. Partition switching (ALTER TABLE SWITCH) enables instant archival of old vintages to archive tables.

**Result:** Queries filtered by vintage year ran 15x faster due to partition elimination -- scanning 100 million rows in one partition instead of 2 billion. Index rebuilds dropped from 8 hours (full table) to 25 minutes per partition, enabling rolling maintenance within nightly windows.

**AI Vision:** Predictive models could analyze query patterns per partition to recommend dynamic partition splitting or merging, optimizing storage layout based on access frequency.

---

### Q34. How do columnstore indexes accelerate analytical loan queries?

**Situation:** CoreLogic property analytics queries against our 500-million-row loan performance table scanned large volumes of data to compute aggregations -- average LTV by state, total UPB by product type, delinquency trends by quarter. Traditional rowstore indexes were optimized for point lookups, not bulk analytical scans.

**Task:** Implement columnstore indexes to dramatically improve scan performance for analytical queries while maintaining acceptable rowstore performance for OLTP loan boarding operations.

**Action:** Added a nonclustered columnstore index alongside the existing rowstore:
```sql
-- Nonclustered columnstore index (NCCI) on analytical columns
-- Keeps rowstore clustered index for OLTP operations
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_LoanPerformance_Analytics
ON dbo.LoanPerformance (
    loan_number,
    vintage_year,
    property_state,
    product_type,
    current_upb,
    original_ltv,
    credit_score,
    delinquency_status,
    reporting_month
);

-- Analytical query benefits from columnstore (batch mode execution)
SELECT
    property_state,
    vintage_year,
    COUNT(*) AS loan_count,
    SUM(current_upb) AS total_upb,
    AVG(CAST(original_ltv AS FLOAT)) AS avg_ltv,
    AVG(CAST(credit_score AS FLOAT)) AS avg_fico,
    SUM(CASE WHEN delinquency_status >= '60' THEN current_upb ELSE 0 END)
        / NULLIF(SUM(current_upb), 0) * 100 AS serious_delinquency_pct
FROM dbo.LoanPerformance
WHERE reporting_month = '2025-12-01'
GROUP BY property_state, vintage_year
ORDER BY property_state, vintage_year;

-- Check if columnstore was used and batch mode engaged
SELECT
    qs.total_logical_reads,
    qs.total_elapsed_time / 1000 AS elapsed_ms,
    qp.query_plan
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qp.query_plan.exist('//RelOp[@PhysicalOp="Columnstore Index Scan"]') = 1;
```
Columnstore indexes store data column-by-column instead of row-by-row, achieving 10x compression and enabling batch mode execution (processing 900 rows at a time instead of row-by-row). Segment elimination skips entire row groups when min/max values do not match the filter predicate.

**Result:** The state-level delinquency report dropped from 90 seconds (rowstore full scan) to 3 seconds (columnstore with batch mode). Storage for the columnstore index was only 15% of the rowstore equivalent due to columnar compression. Batch mode execution reduced CPU usage by 80%.

**AI Vision:** Columnstore segment metadata (min/max per segment) could feed data distribution models that recommend optimal data ordering for maximum segment elimination, auto-tuning storage layout.

---

### Q35. How does In-Memory OLTP support high-speed real-time deal pricing?

**Situation:** Intex deal pricing required sub-millisecond lookups against reference data tables (yield curves, prepayment vectors, credit curves) during Monte Carlo simulations. Each simulation run made millions of lookups per second, and disk-based tables introduced latch contention that throttled throughput.

**Task:** Migrate hot reference data tables to In-Memory OLTP (memory-optimized tables) to eliminate latch contention and achieve microsecond-level lookup performance for real-time deal pricing.

**Action:** Created memory-optimized tables with natively compiled stored procedures:
```sql
-- Enable In-Memory OLTP on the database
ALTER DATABASE MortgageAnalytics
ADD FILEGROUP InMemory_FG CONTAINS MEMORY_OPTIMIZED_DATA;
ALTER DATABASE MortgageAnalytics
ADD FILE (NAME = 'InMemory_File', FILENAME = 'D:\InMemoryData\InMemory_File')
TO FILEGROUP InMemory_FG;

-- Create memory-optimized yield curve table
CREATE TABLE dbo.YieldCurve_InMem (
    curve_date DATE NOT NULL,
    tenor_months INT NOT NULL,
    yield_rate DECIMAL(8,5) NOT NULL,
    curve_type VARCHAR(20) NOT NULL,

    CONSTRAINT PK_YieldCurve_InMem PRIMARY KEY NONCLUSTERED
        HASH (curve_date, tenor_months, curve_type) WITH (BUCKET_COUNT = 1048576),

    INDEX IX_CurveDate NONCLUSTERED (curve_date)
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);

-- Natively compiled stored procedure for pricing lookups
CREATE PROCEDURE dbo.usp_GetInterpolatedYield
    @CurveDate DATE,
    @TenorMonths INT,
    @CurveType VARCHAR(20)
WITH NATIVE_COMPILATION, SCHEMABINDING, EXECUTE AS OWNER
AS
BEGIN ATOMIC WITH (TRANSACTION ISOLATION LEVEL = SNAPSHOT, LANGUAGE = N'English')
    SELECT yield_rate
    FROM dbo.YieldCurve_InMem
    WHERE curve_date = @CurveDate
      AND tenor_months = @TenorMonths
      AND curve_type = @CurveType;
END;

-- Bulk load yield curve data into memory-optimized table
INSERT INTO dbo.YieldCurve_InMem (curve_date, tenor_months, yield_rate, curve_type)
SELECT curve_date, tenor_months, yield_rate, curve_type
FROM dbo.YieldCurve_DiskBased
WHERE curve_date >= '2020-01-01';
```
Memory-optimized tables eliminate latches and locks entirely using multi-version optimistic concurrency. Natively compiled procedures are compiled to machine code at creation time, bypassing the query interpreter. Hash indexes provide O(1) lookups; BUCKET_COUNT should be 1-2x the expected distinct key count.

**Result:** Yield curve lookups dropped from 50 microseconds (disk-based) to 2 microseconds (in-memory). Monte Carlo simulation throughput increased from 50,000 to 1.2 million scenarios per minute, enabling real-time deal pricing during live trading sessions.

**AI Vision:** In-memory tables could serve as the low-latency inference layer for ML pricing models, storing pre-computed model outputs that update in real-time as market conditions shift.

---

### Q36. When do you use Sequences vs IDENTITY for generating deal and tranche identifiers?

**Situation:** Our deal management system needed to generate identifiers across multiple related tables -- a deal ID shared by the deal header, all its tranches, and associated collateral groups. IDENTITY columns are table-specific and cannot be pre-generated or shared across tables without an INSERT followed by SCOPE_IDENTITY().

**Task:** Implement a shared identifier generation strategy using Sequences that assigns a deal ID before inserting into any table, and compare trade-offs with IDENTITY.

**Action:** Created sequences for deal and tranche numbering:
```sql
-- Create sequences for deal identifiers
CREATE SEQUENCE dbo.seq_DealId
    AS BIGINT
    START WITH 100000
    INCREMENT BY 1
    MINVALUE 100000
    MAXVALUE 999999999
    NO CYCLE
    CACHE 50;  -- pre-allocate 50 values for performance

CREATE SEQUENCE dbo.seq_TrancheId
    AS BIGINT
    START WITH 500000
    INCREMENT BY 1
    CACHE 100;

-- Use sequence to pre-generate deal ID before any inserts
DECLARE @NewDealId BIGINT = NEXT VALUE FOR dbo.seq_DealId;

-- Insert header with known ID
INSERT INTO dbo.Deal_Header (deal_id, deal_name, issuer, settlement_date)
VALUES (@NewDealId, 'FNMA-2025-C05', 'Fannie Mae', '2025-06-15');

-- Insert tranches referencing the same deal ID
INSERT INTO dbo.Deal_Tranche (tranche_id, deal_id, tranche_name, original_balance)
VALUES
    (NEXT VALUE FOR dbo.seq_TrancheId, @NewDealId, 'A-1', 500000000.00),
    (NEXT VALUE FOR dbo.seq_TrancheId, @NewDealId, 'A-2', 300000000.00),
    (NEXT VALUE FOR dbo.seq_TrancheId, @NewDealId, 'M-1', 100000000.00);

-- Sequence in DEFAULT constraint (like IDENTITY but with more control)
CREATE TABLE dbo.CollateralGroup (
    group_id BIGINT DEFAULT (NEXT VALUE FOR dbo.seq_DealId),
    deal_id BIGINT NOT NULL,
    group_name VARCHAR(50)
);

-- Monitor sequence usage
SELECT name, current_value, start_value, increment, cache_size
FROM sys.sequences
WHERE name LIKE 'seq_%';
```
Sequences are independent objects, not tied to a table. They support pre-generation (get the value before INSERT), sharing across tables, cycling, and custom caching. IDENTITY is simpler for single-table auto-increment but cannot pre-generate or share values. Sequences can have gaps (like IDENTITY) if transactions roll back, and CACHE values can be lost on server restart.

**Result:** Pre-generated deal IDs eliminated the INSERT-then-read pattern, reducing deal boarding transaction time by 30%. The shared sequence ensured referential consistency across the deal header, tranche, and collateral tables within a single transaction scope.

**AI Vision:** Sequence usage patterns could feed capacity planning models that predict when identifier ranges will exhaust and automatically trigger range extensions or partition reassignments.

---

### Q37. How do you use APPLY with XML/JSON to shred nested deal structures?

**Situation:** Intex delivered CMBS deal structures as nested XML documents containing deal-level metadata, tranche arrays, and collateral loan arrays nested within each tranche. Similarly, CoreLogic property data arrived as JSON with nested property histories. We needed to flatten these hierarchical structures into relational tables for loading into our data warehouse.

**Task:** Parse and shred nested XML and JSON deal structures into relational rows, handling multiple nesting levels and optional/missing elements.

**Action:** Used CROSS APPLY with XML and JSON shredding functions:
```sql
-- XML shredding: Intex CMBS deal structure
DECLARE @DealXML XML = (SELECT deal_xml FROM dbo.IntexDealFeed WHERE deal_id = 'COMM-2025-01');

SELECT
    deal.value('@dealName', 'VARCHAR(50)') AS deal_name,
    deal.value('@issueDate', 'DATE') AS issue_date,
    tranche.value('@trancheName', 'VARCHAR(20)') AS tranche_name,
    tranche.value('@originalBalance', 'DECIMAL(14,2)') AS original_balance,
    tranche.value('@couponRate', 'DECIMAL(5,3)') AS coupon_rate,
    loan.value('@loanId', 'VARCHAR(30)') AS collateral_loan_id,
    loan.value('@propertyType', 'VARCHAR(30)') AS property_type,
    loan.value('@currentUPB', 'DECIMAL(14,2)') AS current_upb
FROM @DealXML.nodes('/Deal') AS d(deal)
CROSS APPLY deal.nodes('Tranches/Tranche') AS t(tranche)
CROSS APPLY tranche.nodes('CollateralLoans/Loan') AS l(loan);

-- JSON shredding: CoreLogic property data with nested history
SELECT
    p.property_id,
    p.address,
    p.current_value,
    h.sale_date,
    h.sale_price,
    h.buyer_name
FROM dbo.CoreLogic_PropertyFeed f
CROSS APPLY OPENJSON(f.json_payload, '$.properties') WITH (
    property_id VARCHAR(30) '$.id',
    address NVARCHAR(200) '$.address.fullAddress',
    current_value DECIMAL(14,2) '$.valuation.currentValue',
    sale_history NVARCHAR(MAX) '$.saleHistory' AS JSON
) p
CROSS APPLY OPENJSON(p.sale_history) WITH (
    sale_date DATE '$.date',
    sale_price DECIMAL(14,2) '$.price',
    buyer_name NVARCHAR(100) '$.buyer'
) h
WHERE p.current_value > 500000;

-- OUTER APPLY for optional nested elements (left join equivalent)
SELECT
    p.property_id,
    p.address,
    ISNULL(h.sale_date, '1900-01-01') AS last_sale_date
FROM dbo.CoreLogic_PropertyFeed f
CROSS APPLY OPENJSON(f.json_payload, '$.properties') WITH (
    property_id VARCHAR(30) '$.id',
    address NVARCHAR(200) '$.address.fullAddress',
    sale_history NVARCHAR(MAX) '$.saleHistory' AS JSON
) p
OUTER APPLY OPENJSON(p.sale_history) WITH (
    sale_date DATE '$.date'
) h;
```
CROSS APPLY acts like an INNER JOIN to the table-valued function -- rows with no matches are excluded. OUTER APPLY acts like a LEFT JOIN -- parent rows are preserved even when nested elements are missing. The WITH clause defines the relational schema for JSON/XML output.

**Result:** XML shredding replaced a C# deserialization layer, processing 5,000 CMBS deals per hour entirely in T-SQL. JSON OPENJSON was 3x faster than the old CLR-based JSON parser, and OUTER APPLY properly handled properties with no sale history (15% of records) that previously caused NULL reference errors.

**AI Vision:** Schema inference models could auto-detect nested XML/JSON structures and generate optimized CROSS APPLY shredding queries, adapting to schema changes in vendor feeds without manual query updates.

---

### Q38. How does Change Data Capture (CDC) track changes to the loan master table?

**Situation:** Our data lake ingestion pipeline needed to capture all inserts, updates, and deletes from the Fannie Mae loan master table to feed incremental updates to downstream analytics systems. Full table extracts of 50 million rows nightly were too slow and wasteful when only 200,000 rows changed per day.

**Task:** Enable Change Data Capture on the loan master table to capture row-level changes with before/after images, supporting incremental extraction without modifying application code.

**Action:** Enabled and queried CDC on the loan table:
```sql
-- Enable CDC at the database level
EXEC sys.sp_cdc_enable_db;

-- Enable CDC on the loan master table
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name = N'FNMA_LoanMaster',
    @role_name = N'cdc_reader',
    @supports_net_changes = 1,       -- enable net change queries
    @captured_column_list = N'loan_number, current_upb, interest_rate, loan_status, servicer_id, modification_flag';

-- Query all changes since last extraction (using LSN boundaries)
DECLARE @from_lsn BINARY(10) = sys.fn_cdc_get_min_lsn('dbo_FNMA_LoanMaster');
DECLARE @to_lsn BINARY(10) = sys.fn_cdc_get_max_lsn();

-- All changes (shows before/after for updates)
SELECT
    sys.fn_cdc_map_lsn_to_time(__$start_lsn) AS change_time,
    CASE __$operation
        WHEN 1 THEN 'DELETE'
        WHEN 2 THEN 'INSERT'
        WHEN 3 THEN 'UPDATE (Before)'
        WHEN 4 THEN 'UPDATE (After)'
    END AS operation,
    loan_number, current_upb, interest_rate, loan_status
FROM cdc.fn_cdc_get_all_changes_dbo_FNMA_LoanMaster(@from_lsn, @to_lsn, N'all update old');

-- Net changes (only final state per row, ideal for incremental loads)
SELECT
    CASE __$operation
        WHEN 1 THEN 'DELETE'
        WHEN 2 THEN 'INSERT'
        WHEN 5 THEN 'UPDATE'
    END AS net_operation,
    loan_number, current_upb, interest_rate, loan_status
FROM cdc.fn_cdc_get_net_changes_dbo_FNMA_LoanMaster(@from_lsn, @to_lsn, N'all');

-- Map time to LSN for time-based extraction windows
DECLARE @since DATETIME = DATEADD(HOUR, -4, GETDATE());
DECLARE @time_lsn BINARY(10) = sys.fn_cdc_map_time_to_lsn('smallest greater than or equal', @since);
```
CDC reads the transaction log asynchronously via a capture job (SQL Agent). It stores changes in system tables under the `cdc` schema. Net changes collapse multiple changes to the same row into a single final-state row. CDC adds no overhead to the source table DML -- it reads committed log records after the fact.

**Result:** Incremental extraction of 200,000 changed rows took 45 seconds versus 25 minutes for a full 50-million-row extract. The data lake stayed within a 15-minute latency SLA. CDC's before/after images enabled SCD Type 2 processing in the downstream dimension tables.

**AI Vision:** ML anomaly detection models could monitor CDC change velocity -- sudden spikes in modification volume or unexpected status transitions could trigger automated alerts for potential data quality issues.

---

### Q39. How does Change Tracking differ from CDC for lightweight incremental loads?

**Situation:** A secondary reporting database replicated loan status data from the primary OLTP system. Full CDC with before/after images was overkill -- the reporting system only needed to know which loan rows changed (not what changed) so it could re-pull the current state. CDC's transaction log overhead and cleanup jobs were more complexity than needed.

**Task:** Implement a lightweight change detection mechanism that identifies changed rows with minimal overhead, suitable for simple "give me what changed since my last sync" incremental loads.

**Action:** Enabled and queried Change Tracking:
```sql
-- Enable Change Tracking at the database level
ALTER DATABASE MortgageWarehouse
SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 7 DAYS, AUTO_CLEANUP = ON);

-- Enable on the specific table
ALTER TABLE dbo.FHLMC_LoanStatus
ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);

-- Get current sync version (store this after each successful sync)
DECLARE @last_sync_version BIGINT = 0;  -- first run
DECLARE @current_version BIGINT = CHANGE_TRACKING_CURRENT_VERSION();

-- Get all rows that changed since last sync
SELECT
    ct.loan_id,
    ct.SYS_CHANGE_OPERATION,  -- I=Insert, U=Update, D=Delete
    ct.SYS_CHANGE_VERSION,
    l.loan_number,
    l.current_upb,
    l.loan_status,
    l.servicer_id
FROM CHANGETABLE(CHANGES dbo.FHLMC_LoanStatus, @last_sync_version) AS ct
LEFT JOIN dbo.FHLMC_LoanStatus l ON ct.loan_id = l.loan_id  -- LEFT JOIN for deletes
ORDER BY ct.SYS_CHANGE_VERSION;

-- Check if specific columns were updated (when TRACK_COLUMNS_UPDATED = ON)
SELECT
    ct.loan_id,
    CHANGE_TRACKING_IS_COLUMN_IN_MASK(
        COLUMNPROPERTY(OBJECT_ID('dbo.FHLMC_LoanStatus'), 'loan_status', 'ColumnId'),
        ct.SYS_CHANGE_COLUMNS) AS status_changed,
    CHANGE_TRACKING_IS_COLUMN_IN_MASK(
        COLUMNPROPERTY(OBJECT_ID('dbo.FHLMC_LoanStatus'), 'current_upb', 'ColumnId'),
        ct.SYS_CHANGE_COLUMNS) AS upb_changed
FROM CHANGETABLE(CHANGES dbo.FHLMC_LoanStatus, @last_sync_version) AS ct;

-- Save current version after successful sync
-- Store @current_version in your sync metadata table
INSERT INTO dbo.SyncCheckpoint (table_name, last_version, sync_time)
VALUES ('FHLMC_LoanStatus', @current_version, GETDATE());
```
Change Tracking is synchronous (updates inline with DML) but extremely lightweight -- it only records that a row changed and which operation, not the before/after values. It does not read the transaction log (unlike CDC). Retention auto-cleanup removes old tracking data. If your @last_sync_version is older than retention, you must do a full resync.

**Result:** Change Tracking added less than 2% overhead to DML operations versus CDC's 5-8%. The incremental sync process identified 150,000 changed rows in 3 seconds, then pulled only those current values for the reporting replica. Sync frequency improved from hourly (full extract) to every 5 minutes.

**AI Vision:** Smart sync schedulers could use change velocity patterns from Change Tracking metadata to dynamically adjust sync frequency -- more frequent during active trading hours, less during off-hours.

---

### Q40. How do synonyms abstract cross-database loan data references?

**Situation:** Our mortgage data architecture spanned multiple databases -- `LoanOrigination`, `LoanServicing`, and `MBSAnalytics` -- on the same SQL Server instance. Stored procedures in `MBSAnalytics` referenced tables using three-part names like `LoanServicing.dbo.PaymentHistory`. When we migrated `LoanServicing` to a new server, every cross-database reference broke.

**Task:** Create an abstraction layer using synonyms so that database object references can be redirected without modifying application code or stored procedures.

**Action:** Created synonyms to abstract cross-database and cross-server references:
```sql
-- Create synonyms in MBSAnalytics database pointing to LoanServicing tables
USE MBSAnalytics;
GO

CREATE SYNONYM dbo.syn_PaymentHistory
FOR LoanServicing.dbo.PaymentHistory;

CREATE SYNONYM dbo.syn_LoanMaster
FOR LoanServicing.dbo.FNMA_LoanMaster;

CREATE SYNONYM dbo.syn_OriginationData
FOR LoanOrigination.dbo.LoanApplication;

-- Queries use synonyms instead of three-part names
SELECT
    lm.loan_number,
    lm.current_upb,
    ph.payment_date,
    ph.payment_amount,
    ph.principal_applied,
    ph.interest_applied
FROM dbo.syn_LoanMaster lm
INNER JOIN dbo.syn_PaymentHistory ph ON lm.loan_id = ph.loan_id
WHERE lm.servicer_id = 1001
  AND ph.payment_date >= '2025-01-01';

-- When LoanServicing moves to a linked server, just update the synonym
DROP SYNONYM dbo.syn_PaymentHistory;
CREATE SYNONYM dbo.syn_PaymentHistory
FOR [RemoteServer].LoanServicing.dbo.PaymentHistory;

-- Dynamic environment switching (dev/test/prod)
-- Script to update all synonyms for environment promotion
DECLARE @TargetDB NVARCHAR(128) = 'LoanServicing_QA';  -- or _PROD
DECLARE @SQL NVARCHAR(MAX);

SET @SQL = 'DROP SYNONYM IF EXISTS dbo.syn_PaymentHistory; ' +
    'CREATE SYNONYM dbo.syn_PaymentHistory FOR ' + QUOTENAME(@TargetDB) + '.dbo.PaymentHistory;';
EXEC sp_executesql @SQL;
```
Synonyms are metadata-only objects with no storage overhead. They support tables, views, stored procedures, and functions. They cannot be chained (a synonym cannot point to another synonym). Synonyms do not support schema binding, so indexed views cannot reference them.

**Result:** The `LoanServicing` database migration to a new server required updating 8 synonym definitions instead of modifying 150+ stored procedures and 40 SSIS packages. Environment promotion from dev to QA to production became a one-script operation, reducing deployment errors by 90%.

**AI Vision:** Dependency graph analysis could automatically identify all cross-database references and generate synonym creation scripts, with impact analysis predicting which queries will be affected by infrastructure changes.

---

### Q41. How do user-defined types create standardized CUSIP and pool number types?

**Situation:** CUSIP identifiers (9-character alphanumeric) and Ginnie Mae pool numbers (6-character numeric with leading zeros) appeared in over 50 tables across our mortgage data warehouse. Each table defined them inconsistently -- some as VARCHAR(9), others as CHAR(9), NVARCHAR(12), or even VARCHAR(20). This caused implicit conversions in joins that killed index usage.

**Task:** Create user-defined types (UDTs) for CUSIP and pool number to enforce consistent data types across all tables, eliminating implicit conversions and ensuring uniform validation.

**Action:** Created alias types and applied them consistently:
```sql
-- Create user-defined alias types
CREATE TYPE dbo.CUSIP FROM CHAR(9) NOT NULL;
CREATE TYPE dbo.PoolNumber FROM CHAR(6) NOT NULL;
CREATE TYPE dbo.LoanAmount FROM DECIMAL(14,2) NULL;
CREATE TYPE dbo.InterestRate FROM DECIMAL(5,3) NULL;

-- Use UDTs in table definitions
CREATE TABLE dbo.GNMA_PoolMaster (
    pool_number dbo.PoolNumber,
    cusip dbo.CUSIP,
    issue_date DATE NOT NULL,
    original_upb dbo.LoanAmount,
    weighted_avg_coupon dbo.InterestRate,
    pool_type VARCHAR(10),
    CONSTRAINT PK_GNMA_Pool PRIMARY KEY (pool_number)
);

CREATE TABLE dbo.GNMA_TrancheDetail (
    tranche_id INT IDENTITY PRIMARY KEY,
    pool_number dbo.PoolNumber,  -- guaranteed same type as PoolMaster
    cusip dbo.CUSIP,
    tranche_name VARCHAR(20),
    original_balance dbo.LoanAmount,
    coupon_rate dbo.InterestRate,
    CONSTRAINT FK_Tranche_Pool
        FOREIGN KEY (pool_number) REFERENCES dbo.GNMA_PoolMaster(pool_number)
);

-- UDTs in stored procedure parameters
CREATE PROCEDURE dbo.usp_GetPoolByCUSIP
    @CUSIP dbo.CUSIP
AS
BEGIN
    SELECT pool_number, cusip, issue_date, original_upb, weighted_avg_coupon
    FROM dbo.GNMA_PoolMaster
    WHERE cusip = @CUSIP;
END;

-- Table-valued parameter type for bulk operations
CREATE TYPE dbo.CUSIPList AS TABLE (
    cusip dbo.CUSIP PRIMARY KEY
);
GO

-- Use TVP for bulk CUSIP lookups
CREATE PROCEDURE dbo.usp_GetPoolsByCUSIPs
    @CUSIPs dbo.CUSIPList READONLY
AS
BEGIN
    SELECT p.pool_number, p.cusip, p.original_upb
    FROM dbo.GNMA_PoolMaster p
    INNER JOIN @CUSIPs c ON p.cusip = c.cusip;
END;
```
Alias UDTs ensure consistent base types across all usages, preventing implicit conversions in joins and comparisons. Table-valued parameters (TVPs) enable passing sets of typed values to stored procedures. UDTs cannot have CHECK constraints directly -- use constraints on the column or table level. Dropping a UDT requires removing all dependencies first.

**Result:** Standardizing CUSIP as CHAR(9) across 50 tables eliminated VARCHAR/CHAR implicit conversion warnings from execution plans on 30+ cross-table joins. Query performance improved 20-40% on CUSIP-based lookups due to consistent index seek behavior. The TVP bulk lookup processed 10,000 CUSIPs in a single round trip versus 10,000 individual calls.

**AI Vision:** Schema governance models could scan table definitions to detect type inconsistencies for the same logical field and automatically recommend UDT standardization with impact analysis.

---

### Q42. How do you analyze the plan cache to find resource-intensive loan queries?

**Situation:** The mortgage data warehouse experienced periodic CPU spikes during business hours. The DBA team suspected a few poorly-written ad-hoc queries from analysts were consuming excessive resources, but had no visibility into which cached plans were the heaviest hitters without enabling expensive tracing.

**Task:** Query the plan cache to identify the most resource-intensive queries by CPU, logical reads, and execution count, and determine if they had inefficient execution plans.

**Action:** Queried DMVs to analyze cached query plans:
```sql
-- Top 20 queries by total CPU time
SELECT TOP 20
    qs.total_worker_time / 1000 AS total_cpu_ms,
    qs.execution_count,
    qs.total_worker_time / qs.execution_count / 1000 AS avg_cpu_ms,
    qs.total_logical_reads / qs.execution_count AS avg_logical_reads,
    qs.total_elapsed_time / qs.execution_count / 1000 AS avg_elapsed_ms,
    SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset
            WHEN -1 THEN DATALENGTH(st.text)
            ELSE qs.statement_end_offset
        END - qs.statement_start_offset) / 2) + 1) AS query_text,
    qp.query_plan,
    qs.creation_time,
    qs.last_execution_time
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE st.dbid = DB_ID('MortgageWarehouse')
ORDER BY qs.total_worker_time DESC;

-- Find plans with missing index recommendations
SELECT
    SUBSTRING(st.text, (qs.statement_start_offset / 2) + 1, 200) AS query_text,
    qs.execution_count,
    qs.total_logical_reads,
    qp.query_plan.value(
        '(//MissingIndex/@Database)[1]', 'NVARCHAR(128)') AS missing_index_db,
    qp.query_plan.value(
        '(//MissingIndex/@Table)[1]', 'NVARCHAR(128)') AS missing_index_table
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
WHERE qp.query_plan.exist('//MissingIndex') = 1
  AND st.dbid = DB_ID('MortgageWarehouse')
ORDER BY qs.total_logical_reads DESC;

-- Plan cache bloat: single-use plans wasting memory
SELECT
    objtype,
    COUNT(*) AS plan_count,
    SUM(CAST(size_in_bytes AS BIGINT)) / 1024 / 1024 AS total_mb,
    AVG(usecounts) AS avg_use_count
FROM sys.dm_exec_cached_plans
GROUP BY objtype
ORDER BY total_mb DESC;
```
The plan cache is a window into historical query performance without requiring traces or XE sessions. `dm_exec_query_stats` persists until plans are evicted. CROSS APPLY with `dm_exec_sql_text` and `dm_exec_query_plan` retrieves the actual SQL and XML plan. Single-use ad-hoc plans can bloat the cache -- consider enabling "Optimize for Ad Hoc Workloads" to store only plan stubs on first execution.

**Result:** Plan cache analysis revealed three analyst ad-hoc queries consuming 60% of total CPU. One query scanned the full 500M-row loan performance table due to a missing index. Adding the recommended index reduced that query's CPU by 95%. Enabling "Optimize for Ad Hoc Workloads" reclaimed 2 GB of plan cache memory from 50,000 single-use plans.

**AI Vision:** ML models trained on plan cache metrics could learn normal resource consumption patterns per query signature and proactively flag plan regressions when a query's resource usage suddenly increases after a statistics update or schema change.

---

### Q43. How do wait statistics help diagnose performance bottlenecks in loan processing?

**Situation:** The nightly ETL pipeline loading 5 million Freddie Mac loan performance records was taking 4 hours instead of the expected 90 minutes. CPU utilization was only 30%, suggesting the server was spending most of its time waiting on something. We needed to identify the bottleneck category -- I/O, memory, locking, or network.

**Task:** Use wait statistics to identify the dominant wait types during the ETL window and correlate them to specific resource bottlenecks.

**Action:** Captured and analyzed wait statistics using DMVs:
```sql
-- Snapshot wait stats before ETL starts
SELECT wait_type, waiting_tasks_count, wait_time_ms, signal_wait_time_ms
INTO #WaitsBefore
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'SLEEP_TASK', 'BROKER_TO_FLUSH', 'SQLTRACE_BUFFER_FLUSH',
    'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT', 'LAZYWRITER_SLEEP',
    'CHECKPOINT_QUEUE', 'WAITFOR', 'XE_TIMER_EVENT',
    'BROKER_EVENTHANDLER', 'TRACEWRITE', 'DIRTY_PAGE_POLL',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'SP_SERVER_DIAGNOSTICS_SLEEP'
);

-- ... run ETL pipeline ...

-- Snapshot after ETL and calculate delta
SELECT
    a.wait_type,
    a.waiting_tasks_count - ISNULL(b.waiting_tasks_count, 0) AS wait_count,
    (a.wait_time_ms - ISNULL(b.wait_time_ms, 0)) / 1000.0 AS wait_time_sec,
    (a.signal_wait_time_ms - ISNULL(b.signal_wait_time_ms, 0)) / 1000.0 AS signal_wait_sec,
    (a.wait_time_ms - ISNULL(b.wait_time_ms, 0)
     - a.signal_wait_time_ms + ISNULL(b.signal_wait_time_ms, 0)) / 1000.0 AS resource_wait_sec,
    CASE
        WHEN a.wait_type LIKE 'PAGEIOLATCH%' THEN 'Disk I/O'
        WHEN a.wait_type LIKE 'LCK%' THEN 'Locking'
        WHEN a.wait_type LIKE 'PAGELATCH%' THEN 'Memory/TempDB'
        WHEN a.wait_type IN ('WRITELOG', 'LOGBUFFER') THEN 'Transaction Log'
        WHEN a.wait_type LIKE 'CXPACKET%' OR a.wait_type = 'CXCONSUMER' THEN 'Parallelism'
        WHEN a.wait_type IN ('SOS_SCHEDULER_YIELD') THEN 'CPU Pressure'
        WHEN a.wait_type IN ('RESOURCE_SEMAPHORE') THEN 'Memory Grant'
        ELSE 'Other'
    END AS wait_category
FROM sys.dm_os_wait_stats a
LEFT JOIN #WaitsBefore b ON a.wait_type = b.wait_type
WHERE (a.wait_time_ms - ISNULL(b.wait_time_ms, 0)) > 0
ORDER BY wait_time_sec DESC;

-- Check for active sessions with high waits right now
SELECT
    r.session_id,
    r.wait_type,
    r.wait_time,
    r.blocking_session_id,
    t.text AS query_text,
    r.cpu_time,
    r.logical_reads
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.wait_type IS NOT NULL
  AND r.database_id = DB_ID('MortgageWarehouse')
ORDER BY r.wait_time DESC;
```
Signal wait time is time spent in the runnable queue (waiting for CPU). Resource wait time is time waiting for the actual resource (I/O, lock, memory). High PAGEIOLATCH waits indicate disk I/O bottleneck. High LCK waits indicate blocking. High WRITELOG indicates transaction log throughput issues. CXPACKET/CXCONSUMER indicate parallelism skew.

**Result:** Wait analysis revealed WRITELOG waits accounted for 70% of total wait time -- the transaction log disk was a bottleneck. Moving the log file to a faster NVMe drive reduced ETL duration from 4 hours to 75 minutes. Secondary analysis found PAGELATCH_EX contention on tempdb, resolved by adding 4 additional tempdb data files.

**AI Vision:** Continuous wait statistics collection could train time-series models that predict performance degradation before it impacts SLAs, correlating wait patterns with workload volume and infrastructure metrics.

---

### Q44. How do Extended Events basics work for monitoring long-running loan ETL jobs?

**Situation:** Our SSIS-based ETL pipeline loading Fannie Mae CAS deal data into the warehouse had intermittent failures -- certain packages would time out randomly. Standard SQL Agent job history provided only pass/fail status without details on which specific queries within the ETL were slow or blocking.

**Task:** Set up an Extended Events session to capture long-running queries (over 10 seconds), deadlocks, and blocking chains specifically during the ETL window, with minimal production overhead.

**Action:** Created a targeted Extended Events session:
```sql
-- Create XE session for ETL monitoring
CREATE EVENT SESSION [ETL_LoanLoad_Monitor] ON SERVER
ADD EVENT sqlserver.sql_statement_completed (
    SET collect_statement = (1)
    ACTION (
        sqlserver.sql_text,
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.username,
        sqlserver.client_app_name,
        sqlserver.query_hash
    )
    WHERE duration > 10000000  -- 10 seconds in microseconds
      AND sqlserver.database_name = N'MortgageWarehouse'
      AND sqlserver.client_app_name LIKE N'%SSIS%'
),
ADD EVENT sqlserver.blocked_process_report (
    ACTION (sqlserver.sql_text, sqlserver.session_id)
),
ADD EVENT sqlserver.xml_deadlock_report (
    ACTION (sqlserver.sql_text)
),
ADD EVENT sqlserver.lock_escalation (
    ACTION (sqlserver.sql_text, sqlserver.session_id)
    WHERE sqlserver.database_name = N'MortgageWarehouse'
)
ADD TARGET package0.event_file (
    SET filename = N'D:\XEvents\ETL_Monitor.xel',
    max_file_size = (200),      -- 200 MB per file
    max_rollover_files = (10)   -- keep 10 files max
),
ADD TARGET package0.ring_buffer (
    SET max_events_limit = (1000)  -- recent events in memory
)
WITH (
    MAX_MEMORY = 8192 KB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE = OFF  -- manual start during ETL window
);

-- Start before ETL, stop after
ALTER EVENT SESSION [ETL_LoanLoad_Monitor] ON SERVER STATE = START;

-- Query captured events from ring buffer (real-time)
SELECT
    event_data.value('(event/@name)[1]', 'VARCHAR(50)') AS event_name,
    event_data.value('(event/@timestamp)[1]', 'DATETIME2') AS event_time,
    event_data.value('(event/data[@name="duration"]/value)[1]', 'BIGINT') / 1000000.0 AS duration_sec,
    event_data.value('(event/data[@name="logical_reads"]/value)[1]', 'BIGINT') AS logical_reads,
    event_data.value('(event/action[@name="sql_text"]/value)[1]', 'NVARCHAR(MAX)') AS sql_text,
    event_data.value('(event/action[@name="session_id"]/value)[1]', 'INT') AS session_id
FROM (
    SELECT CAST(target_data AS XML) AS target_xml
    FROM sys.dm_xe_session_targets st
    INNER JOIN sys.dm_xe_sessions s ON st.event_session_address = s.address
    WHERE s.name = 'ETL_LoanLoad_Monitor' AND st.target_name = 'ring_buffer'
) raw
CROSS APPLY target_xml.nodes('//RingBufferTarget/event') AS n(event_data)
ORDER BY event_time DESC;

-- Stop after ETL completes
ALTER EVENT SESSION [ETL_LoanLoad_Monitor] ON SERVER STATE = STOP;
```
Extended Events use an asynchronous buffered architecture with 1-3% overhead. EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS prioritizes server performance over capturing every event. The ring_buffer target provides real-time in-memory access; event_file provides durable storage for post-mortem analysis. Predicates filter at collection time, avoiding unnecessary memory use.

**Result:** XE captured a lock escalation event on the loan staging table that correlated exactly with the timeout failures. The SSIS package was performing a bulk insert without TABLOCK hint, causing row-level locks to escalate to table locks that blocked concurrent reads. Adding TABLOCK eliminated escalation and reduced ETL time by 40%.

**AI Vision:** Automated root cause analysis models could correlate XE events (blocking, lock escalation, timeouts) with ETL step metadata to pinpoint failure causes and suggest remediation steps.

---

### Q45. How does data compression (ROW/PAGE) reduce storage for historical loans?

**Situation:** The historical loan performance archive contained 3 billion rows spanning 20 years, consuming 1.8 TB of storage. Most data older than 5 years was rarely queried but had to remain online for regulatory compliance. Storage costs were growing 30% annually and backup windows exceeded 6 hours.

**Task:** Implement data compression on historical partitions to reduce storage footprint and I/O volume, while keeping recent partitions uncompressed for write-heavy ETL operations.

**Action:** Applied ROW and PAGE compression selectively:
```sql
-- Estimate compression savings before applying
EXEC sp_estimate_data_compression_savings
    @schema_name = 'dbo',
    @object_name = 'FNMA_LoanPerformance_Archive',
    @index_id = NULL,  -- all indexes
    @partition_number = NULL,  -- all partitions
    @data_compression = 'PAGE';

-- Apply PAGE compression to historical partitions (vintage < 2021)
-- PAGE compression includes ROW compression plus prefix and dictionary compression
ALTER TABLE dbo.FNMA_LoanPerformance_Archive
REBUILD PARTITION = 1   -- pre-2005 vintage
WITH (DATA_COMPRESSION = PAGE);

ALTER TABLE dbo.FNMA_LoanPerformance_Archive
REBUILD PARTITION = 2   -- 2005 vintage
WITH (DATA_COMPRESSION = PAGE);

-- Apply ROW compression to semi-active partitions (vintage 2021-2023)
-- ROW compression uses variable-length storage for fixed-length types
ALTER TABLE dbo.FNMA_LoanPerformance_Archive
REBUILD PARTITION = 17  -- 2021 vintage
WITH (DATA_COMPRESSION = ROW);

-- Keep recent partitions uncompressed (vintage 2024+) for write performance
-- No action needed -- default is NONE

-- Compressed index on archive table
CREATE NONCLUSTERED INDEX IX_Archive_LoanStatus
ON dbo.FNMA_LoanPerformance_Archive (loan_status, reporting_month)
INCLUDE (current_upb)
WITH (DATA_COMPRESSION = PAGE)
ON ps_VintageYear (vintage_year);

-- Verify compression ratios per partition
SELECT
    p.partition_number,
    p.data_compression_desc,
    p.rows,
    au.total_pages * 8 / 1024 AS size_mb
FROM sys.partitions p
INNER JOIN sys.allocation_units au
    ON p.partition_id = au.container_id
WHERE p.object_id = OBJECT_ID('dbo.FNMA_LoanPerformance_Archive')
  AND p.index_id = 1
ORDER BY p.partition_number;
```
ROW compression stores fixed-length types as variable-length, saving space on integers and short strings. PAGE compression adds prefix compression (common prefixes stored once) and dictionary compression (repeated values stored once per page). PAGE gives 60-80% reduction but costs more CPU on writes. ROW gives 30-50% reduction with lower CPU impact. Compression reduces I/O, so read queries often run faster despite decompression CPU cost.

**Result:** PAGE compression on historical partitions reduced storage from 1.8 TB to 520 GB (71% reduction). Backup duration dropped from 6 hours to 2 hours. Queries against compressed partitions ran 30% faster due to reduced I/O, even accounting for decompression overhead.

**AI Vision:** Storage optimization models could analyze access patterns per partition and automatically recommend the optimal compression level, transitioning partitions from NONE to ROW to PAGE as they age.

---

### Q46. How do sparse columns handle nullable fields in loan attribute tables?

**Situation:** Fannie Mae's expanded loan attribute table had 200 columns, but any individual loan populated only 30-40 of them. For example, FHA-specific fields were NULL for conventional loans, jumbo-specific fields were NULL for conforming loans, and renovation fields were NULL for purchase loans. This sparse data pattern wasted significant storage on NULL overhead.

**Task:** Implement sparse columns to optimize storage for the highly nullable attribute columns while maintaining full query compatibility.

**Action:** Created a table with sparse columns and a column set:
```sql
-- Create table with sparse columns for optional attributes
CREATE TABLE dbo.FNMA_LoanAttributes (
    loan_id BIGINT NOT NULL PRIMARY KEY CLUSTERED,
    loan_number VARCHAR(20) NOT NULL,
    -- Core fields (always populated, NOT sparse)
    origination_date DATE NOT NULL,
    original_upb DECIMAL(14,2) NOT NULL,
    property_state CHAR(2) NOT NULL,

    -- FHA-specific fields (NULL for conventional loans)
    fha_case_number VARCHAR(20) SPARSE NULL,
    fha_insurance_premium DECIMAL(10,2) SPARSE NULL,
    fha_endorsement_date DATE SPARSE NULL,
    fha_mi_pct DECIMAL(5,3) SPARSE NULL,

    -- Jumbo-specific fields (NULL for conforming loans)
    jumbo_spread_bps INT SPARSE NULL,
    jumbo_investor_code VARCHAR(10) SPARSE NULL,
    jumbo_exception_flag BIT SPARSE NULL,

    -- Renovation-specific fields
    renovation_type VARCHAR(30) SPARSE NULL,
    renovation_cost DECIMAL(12,2) SPARSE NULL,
    renovation_completion_date DATE SPARSE NULL,

    -- HARP-specific fields
    harp_refinance_flag BIT SPARSE NULL,
    harp_original_loan_number VARCHAR(20) SPARSE NULL,

    -- Column set for XML access to all sparse columns
    AllAttributes XML COLUMN_SET FOR ALL_SPARSE_COLUMNS
);

-- Insert with only relevant sparse columns populated
INSERT INTO dbo.FNMA_LoanAttributes (loan_id, loan_number, origination_date, original_upb,
    property_state, fha_case_number, fha_insurance_premium, fha_endorsement_date)
VALUES (1, 'FN-2025-00001', '2025-01-15', 350000.00, 'TX',
    'FHA-123456', 6125.00, '2025-02-01');

-- Query sparse columns normally
SELECT loan_number, fha_case_number, fha_insurance_premium
FROM dbo.FNMA_LoanAttributes
WHERE fha_case_number IS NOT NULL;

-- Access all sparse columns via XML column set
SELECT loan_id, loan_number, AllAttributes
FROM dbo.FNMA_LoanAttributes
WHERE loan_id = 1;
-- Returns XML: <fha_case_number>FHA-123456</fha_case_number><fha_insurance_premium>6125.00</fha_insurance_premium>...

-- Insert via XML column set (useful for dynamic attributes)
INSERT INTO dbo.FNMA_LoanAttributes (loan_id, loan_number, origination_date, original_upb,
    property_state, AllAttributes)
VALUES (2, 'FN-2025-00002', '2025-02-01', 750000.00, 'CA',
    '<jumbo_spread_bps>125</jumbo_spread_bps><jumbo_investor_code>INV-44</jumbo_investor_code>');
```
Sparse columns store NULLs with zero bytes (standard columns use a fixed bitmap). The trade-off is non-NULL values cost 4 extra bytes each. The break-even point is approximately 60-80% NULL density depending on data type. Column sets provide XML-based access to all sparse columns as a single virtual column, useful for dynamic attribute patterns.

**Result:** Sparse columns reduced the loan attributes table from 180 GB to 65 GB (64% reduction) because 75% of the 200 columns were NULL on average. The column set enabled a generic attribute viewer in the analyst UI without enumerating all 200 columns.

**AI Vision:** Data profiling models could analyze NULL density per column and automatically recommend sparse column candidates, with threshold optimization based on the specific data type overhead trade-offs.

---

### Q47. How do you use MERGE with OUTPUT for SCD Type 1 updates with audit logging?

**Situation:** The Freddie Mac servicer dimension table required SCD Type 1 processing -- when servicer attributes changed (name, address, contact info), we overwrote the existing values. However, compliance required an audit trail of what changed, when, and what the old values were. The ETL process needed atomic upsert with simultaneous audit capture.

**Task:** Implement MERGE with OUTPUT clause to perform insert/update/delete in a single atomic statement while capturing before/after values into an audit log table.

**Action:** Built a MERGE statement with full audit logging:
```sql
-- Staging table with incoming servicer data from Freddie Mac feed
-- (already loaded by SSIS)
-- Target: dbo.Dim_Servicer (SCD Type 1 dimension)
-- Audit: dbo.Servicer_AuditLog

DECLARE @AuditLog TABLE (
    merge_action VARCHAR(10),
    servicer_id INT,
    old_servicer_name VARCHAR(100),
    new_servicer_name VARCHAR(100),
    old_address VARCHAR(200),
    new_address VARCHAR(200),
    old_phone VARCHAR(20),
    new_phone VARCHAR(20),
    change_timestamp DATETIME2
);

MERGE dbo.Dim_Servicer AS target
USING dbo.Staging_Servicer AS source
ON target.servicer_code = source.servicer_code

WHEN MATCHED AND (
    target.servicer_name <> source.servicer_name OR
    target.address <> source.address OR
    target.phone <> source.phone OR
    target.primary_contact <> source.primary_contact
) THEN UPDATE SET
    target.servicer_name = source.servicer_name,
    target.address = source.address,
    target.phone = source.phone,
    target.primary_contact = source.primary_contact,
    target.last_updated = GETDATE()

WHEN NOT MATCHED BY TARGET THEN INSERT (
    servicer_code, servicer_name, address, phone, primary_contact,
    created_date, last_updated, is_active
) VALUES (
    source.servicer_code, source.servicer_name, source.address,
    source.phone, source.primary_contact, GETDATE(), GETDATE(), 1
)

WHEN NOT MATCHED BY SOURCE AND target.is_active = 1 THEN UPDATE SET
    target.is_active = 0,
    target.deactivated_date = GETDATE()

OUTPUT
    $action,
    ISNULL(deleted.servicer_id, inserted.servicer_id),
    deleted.servicer_name,
    inserted.servicer_name,
    deleted.address,
    inserted.address,
    deleted.phone,
    inserted.phone,
    GETDATE()
INTO @AuditLog;

-- Persist audit log
INSERT INTO dbo.Servicer_AuditLog (merge_action, servicer_id, old_name, new_name,
    old_address, new_address, old_phone, new_phone, change_timestamp)
SELECT * FROM @AuditLog;

-- Summary of changes
SELECT merge_action, COUNT(*) AS record_count
FROM @AuditLog
GROUP BY merge_action;
```
The OUTPUT clause captures `$action` (INSERT, UPDATE, DELETE), plus `inserted.*` (new values) and `deleted.*` (old values). For INSERTs, `deleted` columns are NULL. For DELETEs, `inserted` columns are NULL. The `NOT MATCHED BY SOURCE` clause handles soft-deletes of servicers that disappeared from the feed. Always include a change-detection WHERE on the MATCHED clause to avoid unnecessary updates.

**Result:** The atomic MERGE with OUTPUT replaced a 4-step ETL pattern (staging lookup, update, insert, audit INSERT) with a single statement, reducing servicer dimension load time from 15 minutes to 2 minutes. The audit log captured 100% of changes with zero risk of missed updates, satisfying FHFA examiner requirements for complete change tracking.

**AI Vision:** Anomaly detection models could analyze MERGE audit logs to flag unusual patterns -- such as a servicer's address changing multiple times in a short window or mass deactivations suggesting a data feed error.

---

### Q48. How do you perform cross-database queries to join loan data across databases?

**Situation:** Our architecture separated concerns across three databases on the same SQL Server instance: `LoanOrigination` (application and underwriting data), `LoanServicing` (payment and delinquency data), and `MBSAnalytics` (securitization and pool data). Analysts frequently needed to join origination attributes with servicing performance and pool assignments in a single query.

**Task:** Write cross-database queries that join tables across all three databases, understand the performance implications, and implement strategies for optimizing distributed joins.

**Action:** Used three-part naming and optimization techniques:
```sql
-- Three-part naming: Database.Schema.Table
SELECT
    orig.loan_number,
    orig.borrower_fico,
    orig.original_ltv,
    orig.origination_date,
    serv.current_upb,
    serv.delinquency_status,
    serv.last_payment_date,
    mbs.pool_number,
    mbs.cusip,
    mbs.weighted_avg_coupon
FROM LoanOrigination.dbo.LoanApplication orig
INNER JOIN LoanServicing.dbo.LoanPaymentStatus serv
    ON orig.loan_number = serv.loan_number
LEFT JOIN MBSAnalytics.dbo.PoolLoanMapping plm
    ON orig.loan_number = plm.loan_number
LEFT JOIN MBSAnalytics.dbo.MBS_Pool mbs
    ON plm.pool_number = mbs.pool_number
WHERE orig.origination_date >= '2024-01-01'
  AND serv.delinquency_status IN ('60', '90', '120');

-- Cross-database queries with linked servers (remote databases)
SELECT
    local_loan.loan_number,
    local_loan.current_upb,
    remote_prop.property_value,
    remote_prop.last_appraisal_date
FROM LoanServicing.dbo.LoanPaymentStatus local_loan
INNER JOIN [CoreLogicServer].CoreLogicDB.dbo.PropertyValuation remote_prop
    ON local_loan.property_id = remote_prop.property_id
WHERE local_loan.property_state = 'CA';

-- Optimization: materialize remote data locally to avoid distributed plan
SELECT property_id, property_value, last_appraisal_date
INTO #LocalPropertyCache
FROM [CoreLogicServer].CoreLogicDB.dbo.PropertyValuation
WHERE state_code = 'CA';

CREATE INDEX IX_PropCache ON #LocalPropertyCache (property_id);

SELECT
    l.loan_number,
    l.current_upb,
    p.property_value
FROM LoanServicing.dbo.LoanPaymentStatus l
INNER JOIN #LocalPropertyCache p ON l.property_id = p.property_id;

-- Check cross-database permissions
SELECT
    dp.name AS principal_name,
    dp.type_desc,
    pe.permission_name,
    pe.state_desc
FROM LoanOrigination.sys.database_permissions pe
INNER JOIN LoanOrigination.sys.database_principals dp
    ON pe.grantee_principal_id = dp.principal_id
WHERE pe.permission_name = 'SELECT';
```
Same-instance cross-database queries use three-part names and the optimizer can build a single unified execution plan with proper index usage. Linked server queries (four-part names) are more expensive -- the optimizer may not push predicates to the remote server, causing full table transfers. Materializing remote data into temp tables and indexing it is often faster for linked server joins.

**Result:** The cross-database join query returned delinquent loans with origination attributes and pool assignments in 3 seconds for same-instance databases. For the CoreLogic linked server query, the temp table materialization approach reduced execution from 45 seconds (remote nested loop) to 5 seconds (local hash join).

**AI Vision:** Query optimization models could analyze cross-database join patterns and recommend data co-location strategies or materialized views that bridge database boundaries for frequently accessed join combinations.

---

### Q49. How do TRY_CAST and TRY_CONVERT handle safe type conversion for messy loan feeds?

**Situation:** Vendor feeds from multiple loan originators arrived with inconsistent data quality -- numeric fields sometimes contained text like "N/A", "PENDING", or "#ERROR"; date fields contained invalid values like "00/00/0000" or "TBD". Standard CAST/CONVERT failed the entire batch when encountering these values, requiring manual data cleansing before loading.

**Task:** Implement safe type conversion that gracefully handles invalid data by returning NULL instead of throwing errors, enabling batch processing to continue while flagging problematic records for review.

**Action:** Used TRY_CAST and TRY_CONVERT with data quality reporting:
```sql
-- TRY_CAST: returns NULL for invalid conversions instead of error
SELECT
    raw_loan_number,
    raw_upb,
    TRY_CAST(raw_upb AS DECIMAL(14,2)) AS parsed_upb,
    raw_interest_rate,
    TRY_CAST(raw_interest_rate AS DECIMAL(5,3)) AS parsed_rate,
    raw_origination_date,
    TRY_CAST(raw_origination_date AS DATE) AS parsed_orig_date,
    raw_credit_score,
    TRY_CAST(raw_credit_score AS INT) AS parsed_fico,
    -- Flag records with any parse failures
    CASE WHEN TRY_CAST(raw_upb AS DECIMAL(14,2)) IS NULL
           OR TRY_CAST(raw_interest_rate AS DECIMAL(5,3)) IS NULL
           OR TRY_CAST(raw_origination_date AS DATE) IS NULL
        THEN 1 ELSE 0
    END AS has_parse_error
FROM dbo.RawLoanFeed_Staging;

-- TRY_CONVERT with style codes for date parsing
SELECT
    raw_loan_number,
    raw_date_field,
    TRY_CONVERT(DATE, raw_date_field, 101) AS parsed_mdy,    -- MM/DD/YYYY
    TRY_CONVERT(DATE, raw_date_field, 103) AS parsed_dmy,    -- DD/MM/YYYY
    TRY_CONVERT(DATE, raw_date_field, 112) AS parsed_yyyymmdd, -- YYYYMMDD
    -- Try multiple formats with COALESCE
    COALESCE(
        TRY_CONVERT(DATE, raw_date_field, 101),
        TRY_CONVERT(DATE, raw_date_field, 103),
        TRY_CONVERT(DATE, raw_date_field, 112),
        TRY_CONVERT(DATE, raw_date_field, 23)   -- YYYY-MM-DD
    ) AS best_parsed_date
FROM dbo.RawLoanFeed_Staging;

-- Data quality report: categorize failures
SELECT
    'UPB' AS field_name,
    COUNT(*) AS total_rows,
    SUM(CASE WHEN TRY_CAST(raw_upb AS DECIMAL(14,2)) IS NOT NULL THEN 1 ELSE 0 END) AS valid_count,
    SUM(CASE WHEN TRY_CAST(raw_upb AS DECIMAL(14,2)) IS NULL AND raw_upb IS NOT NULL THEN 1 ELSE 0 END) AS invalid_count,
    SUM(CASE WHEN raw_upb IS NULL THEN 1 ELSE 0 END) AS null_count
FROM dbo.RawLoanFeed_Staging
UNION ALL
SELECT
    'Interest Rate',
    COUNT(*),
    SUM(CASE WHEN TRY_CAST(raw_interest_rate AS DECIMAL(5,3)) IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN TRY_CAST(raw_interest_rate AS DECIMAL(5,3)) IS NULL AND raw_interest_rate IS NOT NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN raw_interest_rate IS NULL THEN 1 ELSE 0 END)
FROM dbo.RawLoanFeed_Staging;

-- Load valid records, quarantine invalid ones
INSERT INTO dbo.FNMA_LoanMaster (loan_number, current_upb, interest_rate, origination_date)
SELECT
    raw_loan_number,
    TRY_CAST(raw_upb AS DECIMAL(14,2)),
    TRY_CAST(raw_interest_rate AS DECIMAL(5,3)),
    TRY_CAST(raw_origination_date AS DATE)
FROM dbo.RawLoanFeed_Staging
WHERE TRY_CAST(raw_upb AS DECIMAL(14,2)) IS NOT NULL
  AND TRY_CAST(raw_origination_date AS DATE) IS NOT NULL;

INSERT INTO dbo.DataQuality_Quarantine (source_table, raw_data, error_reason, quarantine_date)
SELECT
    'RawLoanFeed',
    raw_loan_number + '|' + ISNULL(raw_upb, '') + '|' + ISNULL(raw_interest_rate, ''),
    'Parse failure: UPB=' + ISNULL(raw_upb, 'NULL') + ', Rate=' + ISNULL(raw_interest_rate, 'NULL'),
    GETDATE()
FROM dbo.RawLoanFeed_Staging
WHERE TRY_CAST(raw_upb AS DECIMAL(14,2)) IS NULL
   OR TRY_CAST(raw_origination_date AS DATE) IS NULL;
```
TRY_CAST follows ANSI SQL and does not support style codes. TRY_CONVERT is SQL Server-specific and supports style codes for date/time formatting. Both return NULL on failure instead of raising an error. They are essential for ETL robustness when source data quality cannot be guaranteed. Performance is identical to CAST/CONVERT for valid values.

**Result:** The safe conversion approach allowed 98.5% of the 2-million-row vendor feed to load successfully in a single pass, while quarantining 30,000 problematic records for manual review. Previously, a single bad value in row 1.5 million would fail the entire batch, requiring restart from the beginning after manual cleanup.

**AI Vision:** Data quality ML models could learn common invalid value patterns per vendor (e.g., "N/A" always in the UPB field from Vendor X) and auto-generate cleansing rules that TRY_CAST/TRY_CONVERT applies before loading.

---

### Q50. How do window frame clauses (ROWS/RANGE) compute running totals for pool balances?

**Situation:** Fannie Mae MBS pool analysts needed running totals and moving averages of unpaid principal balance across monthly reporting periods. The default window frame behavior (RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) produced correct results for SUM but used an on-disk spool for execution, performing poorly on the 100-million-row performance table.

**Task:** Implement running totals and moving averages using explicit window frame clauses (ROWS vs RANGE), understanding the performance and semantic differences, and optimizing for large-scale loan datasets.

**Action:** Used ROWS and RANGE frame specifications with window functions:
```sql
-- Running total UPB by pool over months using ROWS (most efficient)
SELECT
    pool_number,
    reporting_month,
    monthly_upb,
    SUM(monthly_upb) OVER (
        PARTITION BY pool_number
        ORDER BY reporting_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_upb,
    -- 3-month moving average
    AVG(monthly_upb) OVER (
        PARTITION BY pool_number
        ORDER BY reporting_month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS moving_avg_3mo,
    -- 12-month moving average
    AVG(monthly_upb) OVER (
        PARTITION BY pool_number
        ORDER BY reporting_month
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
    ) AS moving_avg_12mo
FROM dbo.FNMA_MonthlyPoolPerformance
WHERE vintage_year = 2023;

-- RANGE vs ROWS difference: handling ties
-- RANGE includes all rows with the same ORDER BY value (peers)
-- ROWS treats each row individually regardless of ties
SELECT
    pool_number,
    reporting_month,
    monthly_payment,
    -- ROWS: strictly positional, each row gets its own running total step
    SUM(monthly_payment) OVER (
        PARTITION BY pool_number
        ORDER BY reporting_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_rows,
    -- RANGE: includes all peers (same reporting_month), may jump
    SUM(monthly_payment) OVER (
        PARTITION BY pool_number
        ORDER BY reporting_month
        RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_range
FROM dbo.FNMA_PoolPayments;

-- Advanced: cumulative default rate with look-ahead window
SELECT
    pool_number,
    reporting_month,
    default_count,
    loan_count,
    -- Cumulative defaults from inception
    SUM(default_count) OVER (
        PARTITION BY pool_number
        ORDER BY reporting_month
        ROWS UNBOUNDED PRECEDING
    ) AS cumulative_defaults,
    -- Total loans that will ever default (look-ahead for completed pools)
    SUM(default_count) OVER (
        PARTITION BY pool_number
        ORDER BY reporting_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS lifetime_defaults,
    -- Month-over-month UPB change
    monthly_upb - LAG(monthly_upb) OVER (
        PARTITION BY pool_number ORDER BY reporting_month
    ) AS mom_upb_change,
    -- Percentage of lifetime defaults realized so far
    CAST(SUM(default_count) OVER (
        PARTITION BY pool_number ORDER BY reporting_month
        ROWS UNBOUNDED PRECEDING
    ) AS FLOAT) /
    NULLIF(SUM(default_count) OVER (
        PARTITION BY pool_number
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ), 0) * 100 AS pct_lifetime_defaults_realized
FROM dbo.FNMA_PoolDefaultHistory
WHERE pool_number = 'FN-MA1234';
```
ROWS BETWEEN is physical (counts actual rows) and uses an in-memory spool -- fast and deterministic. RANGE BETWEEN is logical (includes peer rows with the same ORDER BY value) and may use an on-disk spool -- slower but handles ties correctly. When ORDER BY values are unique, ROWS and RANGE produce identical results. Always prefer ROWS for performance unless tie handling is specifically required. The default frame when ORDER BY is present is RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW, which is the slower option.

**Result:** Switching from the implicit RANGE frame to explicit ROWS frame reduced the running total query from 90 seconds to 12 seconds on 100 million rows by eliminating the on-disk work table spool. The 12-month moving average enabled analysts to smooth out seasonal payment patterns, revealing that 2023-vintage pools had a 15% faster prepayment trajectory than 2022 vintages.

**AI Vision:** Time-series forecasting models could consume window function outputs (running totals, moving averages, cumulative rates) as pre-computed features, improving prediction accuracy for pool performance modeling while reducing feature engineering complexity.

---

[Back to Index](README.md)
