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
