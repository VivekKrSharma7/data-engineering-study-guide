# Advanced SQL Server - Q&A (Part 4: Security, ETL and Administration)

[Back to Index](README.md)

---

### Q31. How did you implement column-level encryption for PII fields (SSN, income) in a loan origination database while maintaining query performance?

**Situation:** Our loan origination system stored over 12 million borrower records with SSN, annual income, and credit scores — all classified as PII under GLBA and CCPA. Auditors flagged that these columns were stored in plaintext, creating regulatory exposure. The system supported real-time underwriting lookups averaging 200ms SLA, so any encryption approach had to avoid degrading query paths.

**Task:** Encrypt SSN, income, and credit score columns at rest and in transit while keeping underwriting and servicing queries within the 200ms threshold. We also needed deterministic encryption on SSN to allow equality joins for duplicate borrower detection across Fannie Mae and Freddie Mac pipelines.

**Action:** I implemented Always Encrypted with a split approach — deterministic encryption for SSN (to allow equality searches) and randomized encryption for income and credit score (higher security, no search needed). I configured the Column Master Key in Azure Key Vault with HSM backing, and the Column Encryption Key within SQL Server.

```sql
-- Create Column Master Key backed by Azure Key Vault
CREATE COLUMN MASTER KEY CMK_LoanPII
WITH (
    KEY_STORE_PROVIDER_NAME = 'AZURE_KEY_VAULT',
    KEY_PATH = 'https://mortgagevault.vault.azure.net/keys/LoanPII-CMK/abc123'
);

-- Create Column Encryption Key
CREATE COLUMN ENCRYPTION KEY CEK_LoanPII
WITH VALUES (
    COLUMN_MASTER_KEY = CMK_LoanPII,
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x01700000016C006F00...
);

-- Encrypt columns with appropriate encryption types
ALTER TABLE dbo.Borrower
ALTER COLUMN SSN NVARCHAR(11)
ENCRYPTED WITH (
    ENCRYPTION_TYPE = DETERMINISTIC,
    ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256',
    COLUMN_ENCRYPTION_KEY = CEK_LoanPII
);

ALTER TABLE dbo.Borrower
ALTER COLUMN AnnualIncome DECIMAL(15,2)
ENCRYPTED WITH (
    ENCRYPTION_TYPE = RANDOMIZED,
    ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256',
    COLUMN_ENCRYPTION_KEY = CEK_LoanPII
);
```

I then created a non-encrypted hash column (`SSN_Hash`) using a salted SHA-256 for fast lookups in non-AE-enabled applications, indexed it, and modified the .NET underwriting application to use `SqlConnection` with `Column Encryption Setting=Enabled`. For reporting workloads that needed income ranges, I built a pre-aggregated summary table with bucketed income bands that avoided decrypting individual rows.

**Result:** Passed the GLBA compliance audit with zero findings. Underwriting query latency increased only from 180ms to 195ms — well within SLA. Duplicate borrower detection across GSE pipelines continued to work via deterministic SSN matching. The approach eliminated a $2.4M annual risk exposure identified by the compliance team.

**AI Vision:** An ML-based access anomaly detector could monitor decryption patterns — flagging unusual bulk SSN decryptions that might indicate insider threats or compromised service accounts, triggering automated Key Vault access revocation.

---

### Q32. Describe your approach to building an SSIS-based ETL pipeline for processing monthly Fannie Mae loan-level disclosure files.

**Situation:** Fannie Mae publishes monthly loan-level performance files covering 30+ million active loans across their MBS trust portfolio. Each monthly release contained approximately 80 flat files totaling 40–60 GB, with pipe-delimited records spanning 100+ columns including loan status, delinquency, modification flags, and loss mitigation outcomes. Our analytics team needed this data loaded into SQL Server within a 6-hour weekend window for Monday morning portfolio risk reporting.

**Task:** Design and implement an end-to-end SSIS pipeline that downloads, validates, transforms, and loads the Fannie Mae disclosure files, applying business rules for loan status transitions, prepayment speed calculations (CPR/CDR), and integration with our existing CUSIP-level MBS trust mapping tables.

**Action:** I designed a master-child SSIS architecture with three phases. The master package orchestrated the workflow while child packages handled parallel file processing.

```sql
-- Staging table matching Fannie Mae disclosure file layout
CREATE TABLE staging.FannieLoanPerformance (
    LoanID              VARCHAR(12),
    ReportingPeriod     VARCHAR(6),
    ServicerName        VARCHAR(80),
    CurrentInterestRate DECIMAL(8,5),
    CurrentUPB          DECIMAL(14,2),
    LoanAge             INT,
    MonthsToMaturity    INT,
    DelinquencyStatus   VARCHAR(3),
    ModificationFlag    CHAR(1),
    ZeroBalanceCode     VARCHAR(2),
    ZeroBalanceDate     VARCHAR(6),
    -- ... 90+ additional columns
    LoadBatchID         INT,
    LoadTimestamp       DATETIME2 DEFAULT SYSDATETIME()
);

-- Post-load transformation: calculate monthly CPR from SMM
CREATE PROCEDURE etl.CalculatePrepaymentSpeeds
    @ReportingPeriod VARCHAR(6)
AS
BEGIN
    WITH MonthlyPrepay AS (
        SELECT
            t.CUSIP,
            curr.ReportingPeriod,
            SUM(CASE WHEN curr.ZeroBalanceCode = '01' THEN prev.CurrentUPB ELSE 0 END)
                / NULLIF(SUM(prev.CurrentUPB), 0) AS SMM
        FROM staging.FannieLoanPerformance curr
        INNER JOIN staging.FannieLoanPerformance prev
            ON curr.LoanID = prev.LoanID
            AND prev.ReportingPeriod = FORMAT(
                DATEADD(MONTH, -1, CONVERT(DATE, curr.ReportingPeriod + '01')), 'yyyyMM')
        INNER JOIN dbo.TrustLoanMapping t ON curr.LoanID = t.LoanID
        WHERE curr.ReportingPeriod = @ReportingPeriod
        GROUP BY t.CUSIP, curr.ReportingPeriod
    )
    INSERT INTO analytics.MonthlyCPR (CUSIP, ReportingPeriod, SMM, CPR)
    SELECT CUSIP, ReportingPeriod, SMM,
           1 - POWER(1 - SMM, 12) AS CPR
    FROM MonthlyPrepay;
END;
```

Phase 1 (Download & Validate): A Script Task called the Fannie Mae SFTP endpoint, downloaded files, and validated row counts against the manifest. Phase 2 (Parallel Load): I used a ForEach Loop container with 8 parallel Data Flow Tasks, each with a Flat File Source configured for pipe delimiters with error row redirection. I applied bulk insert with `TABLOCK` and minimal logging into staging tables partitioned by reporting period. Phase 3 (Transform & Merge): Stored procedures computed loan status transitions, prepayment speeds, and severity calculations, then merged into production fact tables using partition switching for zero-downtime loads.

**Result:** Reduced the monthly load window from 14 hours (previous manual process) to 3.5 hours — well within the 6-hour SLA. Error rejection rates dropped from 2.3% to 0.04% with proper data type handling. Monday morning risk reports were consistently available by 6 AM, enabling the trading desk to act on updated CPR/CDR vectors before market open.

**AI Vision:** An NLP model could parse Fannie Mae's monthly release notes and data dictionary changes to auto-detect schema drift, generating ALTER TABLE scripts and Data Flow Task updates before the load even begins.

---

### Q33. How would you implement Row-Level Security for a multi-servicer loan database where each servicer sees only their portfolio?

**Situation:** Our centralized loan servicing platform hosted data for 14 different servicers — including Wells Fargo, PennyMac, and Mr. Cooper-affiliated sub-servicers — totaling 8.2 million active loans. Regulatory requirements (Reg AB-II, CFPB servicing rules) mandated strict data segregation. A servicer must never see another servicer's borrower data, delinquency pipelines, or loss mitigation activity, yet our internal analytics team needed cross-servicer visibility.

**Task:** Implement row-level data isolation at the database engine level that was transparent to application code, worked across all access paths (SSMS, Power BI, custom apps), and required no changes to existing stored procedures or views.

**Action:** I implemented SQL Server Row-Level Security with inline table-valued security predicates, combined with a servicer-context mapping table.

```sql
-- Servicer-to-user mapping table
CREATE TABLE security.ServicerAccess (
    DatabaseUser    SYSNAME,
    ServicerCode    VARCHAR(10),
    AccessLevel     VARCHAR(20)  -- 'SERVICER', 'ANALYTICS', 'ADMIN'
);

-- Populate mappings
INSERT INTO security.ServicerAccess VALUES
('PennyMac_SvcUser', 'PMC', 'SERVICER'),
('WF_SvcUser', 'WF', 'SERVICER'),
('AnalyticsTeam', NULL, 'ANALYTICS'),  -- NULL = sees all
('DBAdmin', NULL, 'ADMIN');

-- Security predicate function
CREATE FUNCTION security.fn_LoanAccessPredicate(@ServicerCode VARCHAR(10))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT 1 AS AccessGranted
    WHERE
        -- Servicers see only their own loans
        EXISTS (
            SELECT 1 FROM security.ServicerAccess sa
            WHERE sa.DatabaseUser = USER_NAME()
              AND sa.ServicerCode = @ServicerCode
              AND sa.AccessLevel = 'SERVICER'
        )
        -- Analytics and Admin see everything
        OR EXISTS (
            SELECT 1 FROM security.ServicerAccess sa
            WHERE sa.DatabaseUser = USER_NAME()
              AND sa.AccessLevel IN ('ANALYTICS', 'ADMIN')
        );

-- Apply security policy across all loan tables
CREATE SECURITY POLICY security.ServicerIsolationPolicy
    ADD FILTER PREDICATE security.fn_LoanAccessPredicate(ServicerCode)
        ON dbo.LoanMaster,
    ADD FILTER PREDICATE security.fn_LoanAccessPredicate(ServicerCode)
        ON dbo.PaymentHistory,
    ADD FILTER PREDICATE security.fn_LoanAccessPredicate(ServicerCode)
        ON dbo.DelinquencyPipeline,
    ADD BLOCK PREDICATE security.fn_LoanAccessPredicate(ServicerCode)
        ON dbo.LoanMaster AFTER INSERT,
    WITH (STATE = ON);
```

I indexed the `ServicerAccess` table on `(DatabaseUser, AccessLevel)` and added `ServicerCode` as a leading key in clustered indexes on all loan tables to align predicate evaluation with physical data layout. I also cached the security function results using `OPTION (RECOMPILE)` hints only on queries with parameter-sniffing issues — avoiding blanket recompile overhead. For testing, I built a validation harness using `EXECUTE AS` to confirm each servicer user saw exactly the correct row counts.

**Result:** Deployed across 14 servicers with zero application code changes. Query overhead from RLS was under 3% on filtered queries because the predicate aligned with the clustered index leading key. Passed the SOC 2 Type II audit and CFPB examination with the examiner specifically noting the engine-level enforcement as a best practice. Eliminated the previous approach of 14 separate database copies, saving $180K annually in storage and maintenance.

**AI Vision:** A graph neural network could model cross-servicer data access patterns to detect potential data leakage vectors — for instance, if a shared stored procedure inadvertently bypasses RLS through ownership chaining.

---

### Q34. Explain how you designed SQL Agent jobs for automated loan tape validation and reconciliation.

**Situation:** Our secondary market operations processed nightly loan tapes from 9 correspondent lenders, each containing 5,000–50,000 loans destined for Fannie Mae, Freddie Mac, or Ginnie Mae securitization. These tapes had to match investor delivery requirements — UPB reconciliation to the penny, eligibility field validation against GSE guidelines (LTV limits, FICO thresholds, DTI caps), and deduplication checks. Manual validation was consuming 4 FTEs and still missing errors that caused buyback demands averaging $1.2M per quarter.

**Task:** Automate the entire loan tape validation and reconciliation process using SQL Server Agent jobs, with exception-based alerting so the operations team only handled true discrepancies.

**Action:** I designed a multi-step Agent job architecture with three chained jobs coordinated via token-based dependencies.

```sql
-- Step 1: Schema and completeness validation
CREATE PROCEDURE validation.ValidateLoanTapeSchema
    @TapeID INT
AS
BEGIN
    INSERT INTO validation.TapeExceptions (TapeID, LoanNumber, RuleCode, RuleDesc, Severity)
    -- Check required fields are populated
    SELECT @TapeID, LoanNumber, 'REQFLD', 'Missing ' + col.ColumnName, 'CRITICAL'
    FROM staging.LoanTape lt
    CROSS APPLY (VALUES
        ('BorrowerSSN', CASE WHEN lt.BorrowerSSN IS NULL THEN 1 ELSE 0 END),
        ('PropertyZip', CASE WHEN lt.PropertyZip IS NULL THEN 1 ELSE 0 END),
        ('OrigUPB', CASE WHEN lt.OriginalUPB IS NULL THEN 1 ELSE 0 END),
        ('NoteRate', CASE WHEN lt.NoteRate IS NULL THEN 1 ELSE 0 END)
    ) col(ColumnName, IsMissing)
    WHERE lt.TapeID = @TapeID AND col.IsMissing = 1

    UNION ALL

    -- GSE eligibility rules: Fannie Mae conventional conforming
    SELECT @TapeID, lt.LoanNumber, 'FNMA_LTV',
        CONCAT('LTV ', lt.LTV, ' exceeds limit ', er.MaxValue, ' for program ', lt.ProductType),
        'HIGH'
    FROM staging.LoanTape lt
    INNER JOIN ref.EligibilityRules er
        ON er.Agency = 'FNMA' AND er.RuleField = 'LTV' AND er.ProductType = lt.ProductType
    WHERE lt.TapeID = @TapeID
      AND lt.InvestorCode = 'FNMA'
      AND lt.LTV > er.MaxValue

    UNION ALL

    -- UPB reconciliation against source system
    SELECT @TapeID, lt.LoanNumber, 'UPB_MISMATCH',
        CONCAT('Tape UPB $', FORMAT(lt.CurrentUPB,'N2'), ' vs Servicing $', FORMAT(s.CurrentUPB,'N2')),
        CASE WHEN ABS(lt.CurrentUPB - s.CurrentUPB) > 100 THEN 'CRITICAL' ELSE 'WARNING' END
    FROM staging.LoanTape lt
    INNER JOIN servicing.LoanBalance s ON lt.LoanNumber = s.LoanNumber
    WHERE lt.TapeID = @TapeID
      AND ABS(lt.CurrentUPB - s.CurrentUPB) > 0.01;
END;

-- Step 2: Aggregate reconciliation summary
CREATE PROCEDURE validation.ReconcileTapeAggregates
    @TapeID INT
AS
BEGIN
    INSERT INTO validation.ReconciliationSummary
    SELECT @TapeID, lt.InvestorCode,
        COUNT(*) AS TapeLoanCount,
        inv.ExpectedCount,
        SUM(lt.CurrentUPB) AS TapeUPB,
        inv.ExpectedUPB,
        ABS(SUM(lt.CurrentUPB) - inv.ExpectedUPB) AS UPBVariance
    FROM staging.LoanTape lt
    INNER JOIN ref.InvestorExpectedTotals inv
        ON lt.TapeID = inv.TapeID AND lt.InvestorCode = inv.InvestorCode
    WHERE lt.TapeID = @TapeID
    GROUP BY lt.InvestorCode, inv.ExpectedCount, inv.ExpectedUPB;
END;
```

The Agent job ran nightly at 11 PM with three steps: (1) Iterate each tape file in the staging folder via a CmdExec step that triggered bulk import, (2) Execute the schema validation and eligibility rule checks, (3) Run aggregate reconciliation and generate exception reports. On completion, a final step queried `validation.TapeExceptions` and sent HTML-formatted emails via Database Mail — critical exceptions paged the on-call analyst while warnings queued for morning review.

**Result:** Reduced loan tape validation from 6 hours of manual effort to a 22-minute automated process. Buyback demands dropped from $1.2M to $85K per quarter within two quarters. The ops team was reallocated from data scrubbing to exception resolution, and we caught 340+ eligibility violations in the first month that would have been delivered to the GSEs.

**AI Vision:** A classification model trained on historical buyback reasons could assign probability scores to each exception, prioritizing the ops queue by predicted buyback risk rather than simple severity codes.

---

### Q35. How did you handle a scenario where TDE encryption caused performance degradation on loan batch processing?

**Situation:** After enabling Transparent Data Encryption on our loan servicing database (2.1 TB, 45 million loans) for FFIEC compliance, nightly batch processing — which computed interest accruals, escrow disbursements, and investor remittance calculations for all active loans — degraded from a 3-hour window to nearly 7 hours. The batch had to complete before the 6 AM cutoff for Freddie Mac's Golden Investor Reporting (GIR) file generation. The root cause was TDE's CPU overhead on sequential page reads during large table scans.

**Task:** Restore batch processing to the 3-hour window without disabling TDE, since encryption at rest was a non-negotiable regulatory requirement.

**Action:** I profiled the batch using `sys.dm_exec_query_stats` and `sys.dm_os_wait_stats` and confirmed the bottleneck was `PAGEIOLATCH_SH` waits combined with CPU saturation from AES-256 decryption during sequential scans. I attacked the problem on three fronts.

```sql
-- 1. Switch TDE to AES-128 (NIST-approved, 40% less CPU than AES-256)
-- After consultation with InfoSec confirming AES-128 meets FFIEC requirements
USE master;
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_128
ENCRYPTION BY SERVER CERTIFICATE TDE_LoanServicing_Cert;

-- 2. Restructure the monolithic batch into partition-aligned parallel streams
-- Before: single cursor-based loop over all loans
-- After: parallel execution per payment partition
DECLARE @PartitionCount INT = 12; -- monthly payment date partitions
DECLARE @i INT = 1;

WHILE @i <= @PartitionCount
BEGIN
    -- Each partition processed by separate Service Broker activation
    SEND ON CONVERSATION @ConvHandle
        MESSAGE TYPE BatchPartitionMsg
        (CAST(@i AS VARBINARY(4)));
    SET @i += 1;
END;

-- 3. Converted large scan queries to batch-mode-eligible patterns
-- Added columnstore indexes on hot batch tables
CREATE NONCLUSTERED COLUMNSTORE INDEX NCCI_LoanAccrual
ON dbo.LoanAccrualDetail (
    LoanNumber, AccrualDate, InterestAccrued,
    PrincipalApplied, EscrowBalance, InvestorRemittanceAmt
)
WHERE AccrualStatus = 'PENDING';
```

Additionally, I enabled hardware AES-NI acceleration by working with the infrastructure team to verify the CPU feature was enabled in BIOS (it had been disabled during a firmware update). I also moved `tempdb` to NVMe storage since the batch's spill-heavy sort operations were amplified by TDE's encryption of tempdb pages. Finally, I pre-staged the Freddie Mac GIR extract into an unencrypted export database on a separate filegroup — data left the encrypted boundary only as the final investor-formatted flat file.

**Result:** Batch processing dropped from 7 hours back to 2 hours 40 minutes — faster than the pre-TDE baseline. AES-NI alone recovered 60% of the CPU overhead. The columnstore indexes eliminated 4 large table scans that had been the worst TDE offenders. The GIR file was consistently delivered by 5:15 AM, giving the ops team a 45-minute buffer before the Freddie Mac submission deadline.

**AI Vision:** A reinforcement learning agent could dynamically adjust batch parallelism and partition allocation based on real-time CPU and I/O telemetry, optimizing throughput under TDE encryption load as data volumes grow monthly.

---

### Q36. Describe your Resource Governor configuration for isolating mortgage analytics queries from OLTP loan processing.

**Situation:** Our primary loan servicing database served both real-time loan origination and servicing transactions (800 concurrent users, sub-second SLA) and a growing analytics workload from portfolio managers running ad-hoc Fannie Mae/Freddie Mac conforming loan analysis, vintage performance curves, and delinquency roll-rate models. A single unoptimized analytics query scanning the 45-million-row payment history table would spike CPU to 100% and cause lock-out timeouts for loan officers mid-origination.

**Task:** Implement workload isolation guaranteeing that OLTP loan processing always had priority access to CPU and memory, while still allowing analytics to function during business hours rather than being restricted to after-hours windows.

**Action:** I designed a three-tier Resource Governor configuration with classifier-based routing.

```sql
-- Resource pools with guaranteed minimums and hard caps
CREATE RESOURCE POOL OLTPPool WITH (
    MIN_CPU_PERCENT = 60,
    MAX_CPU_PERCENT = 100,
    MIN_MEMORY_PERCENT = 60,
    MAX_MEMORY_PERCENT = 85,
    CAP_CPU_PERCENT = 100
);

CREATE RESOURCE POOL AnalyticsPool WITH (
    MIN_CPU_PERCENT = 10,
    MAX_CPU_PERCENT = 40,
    MIN_MEMORY_PERCENT = 10,
    MAX_MEMORY_PERCENT = 35,
    CAP_CPU_PERCENT = 40   -- Hard cap prevents runaway queries
);

CREATE RESOURCE POOL ETLPool WITH (
    MIN_CPU_PERCENT = 5,
    MAX_CPU_PERCENT = 30,
    MIN_MEMORY_PERCENT = 5,
    MAX_MEMORY_PERCENT = 20,
    CAP_CPU_PERCENT = 30
);

-- Workload groups with query-level guardrails
CREATE WORKLOAD GROUP OLTPGroup WITH (
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 15,
    REQUEST_MAX_CPU_TIME_SEC = 30,
    MAX_DOP = 4,
    GROUP_MAX_REQUESTS = 500
) USING OLTPPool;

CREATE WORKLOAD GROUP AnalyticsGroup WITH (
    REQUEST_MAX_MEMORY_GRANT_PERCENT = 50,
    REQUEST_MAX_CPU_TIME_SEC = 600,
    MAX_DOP = 8,
    GROUP_MAX_REQUESTS = 20
) USING AnalyticsPool;

-- Classifier function routing by login and application
CREATE FUNCTION dbo.fn_ResourceClassifier()
RETURNS SYSNAME WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN SUSER_NAME() LIKE '%_svc_origination' THEN 'OLTPGroup'
        WHEN SUSER_NAME() LIKE '%_svc_servicing'   THEN 'OLTPGroup'
        WHEN APP_NAME() LIKE 'SSIS%'               THEN 'ETLGroup'
        WHEN APP_NAME() LIKE '%Power BI%'           THEN 'AnalyticsGroup'
        WHEN SUSER_NAME() LIKE '%_analytics%'       THEN 'AnalyticsGroup'
        ELSE 'OLTPGroup'  -- Default to OLTP for safety
    END;
END;

ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = dbo.fn_ResourceClassifier);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

I also set `REQUEST_MAX_CPU_TIME_SEC = 600` on the AnalyticsGroup to kill runaway queries after 10 minutes, and configured Database Mail alerts when analytics queries were throttled more than 50 times per hour — signaling that the workload needed its own read replica.

**Result:** OLTP P99 latency dropped from 1.8 seconds (during peak analytics) to a stable 220ms. Analytics queries ran 15% slower than before isolation but operated predictably without impacting production. Zero loan origination timeouts post-deployment versus 30+ per week prior. The trading desk could run intraday prepayment analysis without the operations team filing priority incidents.

**AI Vision:** A predictive workload scheduler could analyze query submission patterns and dynamically adjust pool percentages — expanding analytics allocation during low OLTP periods (weekends, evenings) and contracting during peak origination hours.

---

### Q37. How would you design an audit framework to track all changes to loan data for SEC Regulation AB-II compliance?

**Situation:** Our firm was an MBS issuer required to comply with SEC Regulation AB-II, which mandates asset-level disclosure and full auditability of loan data changes from origination through securitization. The SEC examiner needed to trace any change to loan terms (rate modifications, forbearance, principal forgiveness) back to the exact user, timestamp, before/after values, and business justification. We had 120 tables across origination, underwriting, and servicing schemas with no existing audit trail.

**Task:** Build a comprehensive, tamper-evident audit framework covering all 120 loan tables that captured before/after values for every DML operation, supported point-in-time reconstruction of any loan's state, and generated SEC-ready audit reports — all without degrading OLTP performance by more than 5%.

**Action:** I implemented a hybrid approach combining SQL Server temporal tables for automatic history tracking with custom trigger-based change capture for business context.

```sql
-- Convert critical loan tables to system-versioned temporal tables
ALTER TABLE dbo.LoanTerms ADD
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START DEFAULT SYSUTCDATETIME(),
    ValidTo   DATETIME2 GENERATED ALWAYS AS ROW END   DEFAULT CONVERT(DATETIME2, '9999-12-31'),
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo);

ALTER TABLE dbo.LoanTerms
SET (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = audit.LoanTerms_History,
    DATA_CONSISTENCY_CHECK = ON,
    HISTORY_RETENTION_PERIOD = 10 YEARS
));

-- Business context capture via slim trigger (only metadata, not full row)
CREATE TRIGGER trg_LoanTerms_AuditContext ON dbo.LoanTerms
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO audit.ChangeContext (
        TableName, LoanNumber, ModifiedBy, ModifiedDate,
        ApplicationName, ChangeReason, WorkflowTicket
    )
    SELECT 'LoanTerms', i.LoanNumber, SUSER_SNAME(), SYSUTCDATETIME(),
        APP_NAME(),
        -- Pull business reason from session context set by application
        CONVERT(VARCHAR(200), SESSION_CONTEXT(N'ChangeReason')),
        CONVERT(VARCHAR(50), SESSION_CONTEXT(N'WorkflowTicket'))
    FROM inserted i;
END;

-- Point-in-time loan reconstruction for SEC examiner queries
CREATE PROCEDURE audit.ReconstructLoanState
    @LoanNumber VARCHAR(20),
    @AsOfDate DATETIME2
AS
BEGIN
    SELECT lt.*, lm.BorrowerName, lm.PropertyAddress
    FROM dbo.LoanTerms
        FOR SYSTEM_TIME AS OF @AsOfDate lt
    INNER JOIN dbo.LoanMaster
        FOR SYSTEM_TIME AS OF @AsOfDate lm
        ON lt.LoanNumber = lm.LoanNumber
    WHERE lt.LoanNumber = @LoanNumber;

    -- Return full change timeline
    SELECT h.*, cc.ChangeReason, cc.WorkflowTicket, cc.ModifiedBy
    FROM audit.LoanTerms_History h
    LEFT JOIN audit.ChangeContext cc
        ON cc.TableName = 'LoanTerms'
        AND cc.LoanNumber = h.LoanNumber
        AND cc.ModifiedDate BETWEEN DATEADD(MILLISECOND, -100, h.ValidFrom)
            AND DATEADD(MILLISECOND, 100, h.ValidFrom)
    WHERE h.LoanNumber = @LoanNumber
    ORDER BY h.ValidFrom;
END;
```

For tamper evidence, I scheduled a nightly job that computed SHA-256 checksums of each history partition and stored them in a separate, append-only database with different access controls. History tables were partitioned by year with compressed page storage. I excluded high-churn operational columns (last_accessed, cache_flag) from temporal tracking by moving them to a separate non-temporal extension table.

**Result:** Passed the SEC Regulation AB-II examination with the examiner specifically commending the point-in-time reconstruction capability. Full audit trail covered 120 tables with an average OLTP overhead of only 2.8%. The audit history database grew at a manageable 45 GB per year with page compression. Loan modification audit reports that previously took the compliance team 3 days to assemble manually were generated in under 2 minutes.

**AI Vision:** An anomaly detection model could continuously analyze audit streams to flag suspicious patterns — such as a cluster of rate modifications outside business hours or bulk term changes without corresponding workflow tickets — providing proactive compliance monitoring.

---

### Q38. Explain your approach to automating index maintenance on a 24/7 loan servicing system with zero maintenance windows.

**Situation:** Our mission-critical loan servicing system processed payments, escrow disbursements, and investor remittance 24/7 with no acceptable downtime window. The system handled 2.3 million daily payment transactions, and index fragmentation on key tables (PaymentHistory, LoanBalance, EscrowActivity) routinely exceeded 80% — causing the nightly investor reporting batch to miss its Fannie Mae/Freddie Mac delivery deadlines. Traditional `ALTER INDEX REBUILD` with `ONLINE = ON` still caused blocking during the final schema-modification lock phase.

**Task:** Implement a fully automated, non-disruptive index maintenance strategy that kept fragmentation below 30% on critical tables without causing any blocking or noticeable performance impact to the live servicing workload.

**Action:** I implemented a tiered, intelligent maintenance approach using Ola Hallengren's framework as a foundation with significant customizations for our zero-downtime requirement.

```sql
-- Custom index maintenance procedure with adaptive thresholds
CREATE PROCEDURE maintenance.AdaptiveIndexMaintenance
AS
BEGIN
    DECLARE @IndexActions TABLE (
        SchemaName SYSNAME, TableName SYSNAME, IndexName SYSNAME,
        FragPct FLOAT, PageCount BIGINT, Action VARCHAR(20)
    );

    -- Gather fragmentation for indexes > 1000 pages (skip tiny indexes)
    INSERT INTO @IndexActions
    SELECT s.name, t.name, i.name,
        ps.avg_fragmentation_in_percent,
        ps.page_count,
        CASE
            WHEN ps.avg_fragmentation_in_percent < 10 THEN 'NONE'
            WHEN ps.avg_fragmentation_in_percent < 30 THEN 'REORGANIZE'
            WHEN ps.page_count < 100000 THEN 'REBUILD_ONLINE'
            ELSE 'REORGANIZE'  -- Large indexes: always reorg to avoid lock escalation
        END
    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ps
    INNER JOIN sys.indexes i ON ps.object_id = i.object_id AND ps.index_id = i.index_id
    INNER JOIN sys.tables t ON ps.object_id = t.object_id
    INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE ps.page_count > 1000
      AND ps.avg_fragmentation_in_percent > 10
      AND i.type IN (1, 2);  -- Clustered and nonclustered only

    -- Execute with MAXDOP 2 and low priority wait to avoid blocking
    DECLARE @sql NVARCHAR(MAX);
    DECLARE index_cursor CURSOR FOR
        SELECT Action, SchemaName, TableName, IndexName FROM @IndexActions WHERE Action <> 'NONE';

    DECLARE @action VARCHAR(20), @sch SYSNAME, @tbl SYSNAME, @idx SYSNAME;
    OPEN index_cursor;
    FETCH NEXT FROM index_cursor INTO @action, @sch, @tbl, @idx;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @action = 'REORGANIZE'
            SET @sql = CONCAT('ALTER INDEX ', QUOTENAME(@idx), ' ON ',
                QUOTENAME(@sch), '.', QUOTENAME(@tbl), ' REORGANIZE;');
        ELSE
            SET @sql = CONCAT('ALTER INDEX ', QUOTENAME(@idx), ' ON ',
                QUOTENAME(@sch), '.', QUOTENAME(@tbl),
                ' REBUILD WITH (ONLINE = ON (WAIT_AT_LOW_PRIORITY ',
                '(MAX_DURATION = 1 MINUTES, ABORT_AFTER_WAIT = SELF)),',
                ' MAXDOP = 2, SORT_IN_TEMPDB = ON);');

        EXEC sp_executesql @sql;

        -- Log completion for monitoring
        INSERT INTO maintenance.IndexMaintenanceLog
        VALUES (@sch, @tbl, @idx, @action, SYSDATETIME(), 'SUCCESS');

        FETCH NEXT FROM index_cursor INTO @action, @sch, @tbl, @idx;
    END;
    CLOSE index_cursor; DEALLOCATE index_cursor;
END;
```

Key design decisions: (1) `WAIT_AT_LOW_PRIORITY` with `ABORT_AFTER_WAIT = SELF` — the rebuild kills itself if it cannot get the schema lock within 1 minute rather than blocking users. (2) `MAXDOP = 2` to limit CPU impact. (3) For the largest indexes (PaymentHistory clustered index, 180M+ rows), I implemented incremental partition-level rebuilds — processing one month's partition per night across a rolling schedule. (4) `REORGANIZE` for any index over 100K pages since it is fully online with no lock phase. (5) Statistics updates ran separately with `SAMPLE 20 PERCENT` and `PERSIST_SAMPLE_PERCENT = ON`.

**Result:** Average fragmentation across critical indexes dropped from 78% to 16%. The nightly investor reporting batch completion time improved by 35% due to cleaner index structures. Zero blocking incidents attributed to index maintenance over 18 months of operation. The approach processed approximately 400 indexes nightly in a 90-minute rolling window with zero user impact.

**AI Vision:** A time-series forecasting model could predict fragmentation growth rates per index based on DML patterns, scheduling maintenance proactively on indexes about to exceed thresholds rather than reacting after degradation occurs.

---

### Q39. How did you implement Linked Servers securely for cross-database queries between loan origination, servicing, and analytics systems?

**Situation:** Our mortgage operation ran three separate SQL Server instances: Loan Origination (LOS), Loan Servicing (MSP), and an Analytics data warehouse. Business processes required real-time cross-system queries — for example, the origination system needed servicing payment history to validate refinance eligibility, and analytics needed to join origination and servicing data for Freddie Mac Loan Advisor scoring. Previous developers had configured Linked Servers with `sa` credentials stored in plaintext, and all 300+ users could execute any remote query — a critical security finding in our SOC 2 audit.

**Task:** Redesign the Linked Server architecture to eliminate credential exposure, enforce least-privilege access, prevent ad-hoc remote query abuse, and pass the SOC 2 re-examination.

**Action:** I replaced the insecure configuration with a defense-in-depth approach.

```sql
-- Step 1: Create dedicated low-privilege service accounts per link direction
-- On the Servicing instance, create a restricted login
CREATE LOGIN [SVC_LOS_ReadOnly] WITH PASSWORD = '<managed by CyberArk>';
CREATE USER [SVC_LOS_ReadOnly] FOR LOGIN [SVC_LOS_ReadOnly];

-- Grant only specific object-level permissions (no db_datareader!)
GRANT SELECT ON dbo.PaymentHistory TO [SVC_LOS_ReadOnly];
GRANT SELECT ON dbo.LoanBalance TO [SVC_LOS_ReadOnly];
GRANT EXECUTE ON dbo.usp_GetPaymentSummary TO [SVC_LOS_ReadOnly];
DENY SELECT ON dbo.BorrowerPII TO [SVC_LOS_ReadOnly];

-- Step 2: Configure Linked Server with security delegation
EXEC sp_addlinkedserver
    @server = 'SERVICING_LINK',
    @srvproduct = '',
    @provider = 'SQLNCLI11',
    @datasrc = 'SVCSQL01.mortgage.internal';

-- Map specific local logins to remote credentials (no blanket mapping)
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = 'SERVICING_LINK',
    @useself = 'FALSE',
    @locallogin = 'MORTGAGE\LOS_ServiceAccount',
    @rmtuser = 'SVC_LOS_ReadOnly',
    @rmtpassword = '<managed by CyberArk>';

-- Deny all unmapped users (critical: prevents ad-hoc access)
EXEC sp_addlinkedsrvlogin
    @rmtsrvname = 'SERVICING_LINK',
    @useself = 'FALSE',
    @locallogin = NULL,
    @rmtuser = NULL,
    @rmtpassword = NULL;

-- Step 3: Disable dangerous Linked Server options
EXEC sp_serveroption 'SERVICING_LINK', 'rpc out', 'true';       -- Allow stored proc calls
EXEC sp_serveroption 'SERVICING_LINK', 'rpc', 'false';          -- Block inbound RPC
EXEC sp_serveroption 'SERVICING_LINK', 'remote proc transaction promotion', 'false';

-- Step 4: Encapsulate all cross-system access in controlled stored procedures
CREATE PROCEDURE origination.GetBorrowerPaymentHistory
    @LoanNumber VARCHAR(20)
AS
BEGIN
    -- Controlled remote call — users never write ad-hoc four-part names
    SELECT PaymentDate, Amount, Principal, Interest, Escrow
    FROM OPENQUERY(SERVICING_LINK,
        'EXEC dbo.usp_GetPaymentSummary @LoanNumber')
    WITH (LoanNumber VARCHAR(20) = @LoanNumber);
END;

-- Grant execute only to specific application roles
GRANT EXECUTE ON origination.GetBorrowerPaymentHistory TO [LOS_AppRole];
```

I also implemented: (1) Network-level restriction via Windows Firewall rules allowing Linked Server traffic only between the three specific instances on port 1433. (2) TLS 1.2 encryption enforced on all inter-instance connections via SQL Server Network Configuration. (3) CyberArk integration for automated password rotation of the service account credentials every 30 days. (4) An audit trigger on `sys.linked_logins` to alert on any Linked Server configuration changes.

**Result:** Eliminated all SOC 2 findings related to cross-database access. Attack surface reduced from 300 users with unrestricted remote access to 3 dedicated service accounts with object-level permissions. Ad-hoc four-part name queries were blocked entirely — all cross-system access flowed through 22 controlled stored procedures. The Freddie Mac Loan Advisor integration continued seamlessly, and refinance eligibility checks performed within 150ms via the encapsulated procedure path.

**AI Vision:** A behavioral analytics system could baseline normal cross-system query patterns and flag deviations — such as the origination service account suddenly querying servicing tables it never accessed before, indicating potential credential compromise.

---

### Q40. Describe your strategy for handling large-scale data archival of historical loan data while maintaining query access.

**Situation:** Our loan servicing database had grown to 8.5 TB, with 60% of the data belonging to loans that were paid off, liquidated, or transferred more than 7 years ago. Storage costs were $45K/month, backups took 14 hours, and DBCC CHECKDB could no longer complete within the weekend maintenance window. However, SEC Regulation AB-II requires 10-year retention with query access for audit requests, and Intex/CoreLogic historical deal analysis required joins against paid-off loan performance data for vintage curve modeling.

**Task:** Archive historical loan data to reduce the production database to under 3 TB while maintaining query access for compliance and analytics — without requiring application changes for historical data retrieval.

**Action:** I designed a tiered archival strategy using partitioning, stretch database concepts, and distributed views.

```sql
-- Step 1: Partition the largest tables by loan status date
-- PaymentHistory: 4.2 billion rows, largest table
CREATE PARTITION FUNCTION pf_ArchiveDate (DATE)
AS RANGE RIGHT FOR VALUES (
    '2019-01-01', '2020-01-01', '2021-01-01',
    '2022-01-01', '2023-01-01', '2024-01-01', '2025-01-01'
);

CREATE PARTITION SCHEME ps_ArchiveDate
AS PARTITION pf_ArchiveDate
TO (FG_Archive_Pre2019, FG_2019, FG_2020, FG_2021,
    FG_2022, FG_2023, FG_2024, FG_Current);

-- Step 2: Create archive database on cheaper storage (S2D with HDD tier)
-- Partition switch for zero-downtime data movement
ALTER TABLE dbo.PaymentHistory
    SWITCH PARTITION 1 TO archive_db.dbo.PaymentHistory_Pre2019;

-- Step 3: Create distributed partitioned view for transparent access
-- In production database:
CREATE VIEW dbo.vw_PaymentHistory_Complete
AS
    SELECT * FROM dbo.PaymentHistory              -- Current (hot)
    UNION ALL
    SELECT * FROM archive_db.dbo.PaymentHistory_Pre2019  -- Pre-2019 (warm)
    UNION ALL
    SELECT * FROM OPENQUERY(ARCHIVE_COLD_LINK,    -- Pre-2016 (cold/compressed)
        'SELECT * FROM cold_archive.dbo.PaymentHistory_Pre2016');

-- Step 4: Heavily compress archive data
ALTER TABLE archive_db.dbo.PaymentHistory_Pre2019
    REBUILD WITH (DATA_COMPRESSION = COLUMNSTORE);

-- Step 5: Synonym for transparent application access
CREATE SYNONYM dbo.PaymentHistoryAll FOR dbo.vw_PaymentHistory_Complete;

-- Step 6: Smart archival procedure with dependency checking
CREATE PROCEDURE maintenance.ArchivePaidOffLoans
AS
BEGIN
    -- Only archive loans with zero balance for 7+ years and no active disputes
    DECLARE @CutoffDate DATE = DATEADD(YEAR, -7, GETDATE());

    INSERT INTO archive_db.dbo.ArchivedLoans
    SELECT lm.*
    FROM dbo.LoanMaster lm
    WHERE lm.ZeroBalanceDate < @CutoffDate
      AND lm.LoanStatus IN ('PAID_OFF', 'LIQUIDATED', 'TRANSFERRED')
      AND NOT EXISTS (
          SELECT 1 FROM dbo.ActiveDisputes d WHERE d.LoanNumber = lm.LoanNumber
      )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.SECActiveDisclosure s WHERE s.LoanNumber = lm.LoanNumber
      );

    -- Partition switch the moved data out of production
    -- (executed per-partition after data verification)
    DELETE FROM dbo.LoanMaster
    WHERE LoanNumber IN (SELECT LoanNumber FROM archive_db.dbo.ArchivedLoans_Staging);
END;
```

The architecture had three tiers: Hot (current production, SSD, row storage), Warm (archive database on same instance, HDD, columnstore compressed), and Cold (separate low-cost instance, columnstore with archival compression). I created monitoring to track query patterns against the distributed view — if more than 5% of queries hit the cold tier, we promoted that partition to warm. For Intex deal analysis requiring historical vintage curves, I pre-materialized summary tables (monthly CPR/CDR/severity by vintage and product type) in the analytics warehouse so the full historical granularity was rarely needed.

**Result:** Production database shrank from 8.5 TB to 2.8 TB. Backup time dropped from 14 hours to 4.5 hours. DBCC CHECKDB completed in 6 hours. Storage costs decreased from $45K to $18K per month. Archive data compressed at 11:1 ratio with columnstore. SEC audit queries against historical loans returned in under 30 seconds via the warm tier. Zero application changes required — the synonym and distributed view were completely transparent to all 12 consuming applications.

**AI Vision:** A data lifecycle ML model could analyze query access patterns, regulatory hold requirements, and storage cost curves to automatically recommend optimal tier placement for each loan cohort — moving data between hot, warm, and cold tiers based on predicted future access probability.
