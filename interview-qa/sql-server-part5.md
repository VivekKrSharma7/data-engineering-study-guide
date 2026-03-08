# Advanced SQL Server - Q&A (Part 5: Advanced Features and Modern SQL)

[Back to Index](README.md)

---

### Q41. How did you use columnstore indexes to accelerate historical loan performance analytics across 2 billion+ rows?

**Situation:** Our mortgage analytics platform housed 2.4 billion rows of monthly loan performance data sourced from Fannie Mae and Freddie Mac public loan-level datasets spanning 20+ years. Analysts running delinquency trend reports, prepayment curves (CPR/CDR), and vintage loss analysis were experiencing query times of 30-45 minutes on traditional rowstore tables, making interactive analysis impossible and delaying monthly investor reporting.

**Task:** Reduce query response time from 30+ minutes to under 60 seconds for aggregate analytics across the full historical dataset while maintaining the ability to load ~15 million new rows monthly without disrupting read operations.

**Action:** I implemented a clustered columnstore index (CCI) strategy with careful partition alignment. The fact table was partitioned by `performance_month` (monthly boundaries) to enable partition elimination and efficient data loading via partition switching.

```sql
-- Partitioned table with clustered columnstore
CREATE TABLE dbo.LoanPerformance (
    loan_id              BIGINT NOT NULL,
    performance_month    DATE NOT NULL,
    current_upb          DECIMAL(14,2),
    delinquency_status   TINYINT,
    loan_age             SMALLINT,
    remaining_months     SMALLINT,
    zero_balance_code    CHAR(2),
    modification_flag    BIT,
    origination_vintage  AS (YEAR(DATEADD(MONTH, -loan_age, performance_month))) PERSISTED
) ON ps_monthly(performance_month);

CREATE CLUSTERED COLUMNSTORE INDEX CCI_LoanPerformance
ON dbo.LoanPerformance
WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE) -- Archive compression for older partitions
ON ps_monthly(performance_month);

-- Monthly load via partition switching (zero-reader-blocking)
ALTER TABLE dbo.LoanPerformance_Staging
SWITCH TO dbo.LoanPerformance PARTITION $PARTITION.pf_monthly('2025-12-01');

-- Vintage loss curve query now runs in seconds
SELECT origination_vintage,
       loan_age,
       SUM(CASE WHEN zero_balance_code = '03' THEN current_upb ELSE 0 END)
         / NULLIF(SUM(current_upb), 0) AS cumulative_loss_rate
FROM dbo.LoanPerformance
WHERE performance_month >= '2020-01-01'
GROUP BY origination_vintage, loan_age
ORDER BY origination_vintage, loan_age;
```

I also created nonclustered rowstore B-tree indexes on `loan_id` for singleton lookups in the OLTP path, giving us a hybrid analytical/transactional design. Columnstore archive compression on partitions older than 5 years reduced storage from 1.8 TB to 310 GB.

**Result:** Vintage loss curve queries dropped from 38 minutes to 22 seconds (103x improvement). Monthly data loads completed in 4 minutes via partition switching with zero blocking. Storage reduced by 83%. Analysts shifted from batch-scheduled reports to interactive, self-service exploration, enabling same-day investor reporting instead of T+3.

**AI Vision:** An ML model trained on the compressed columnstore data could produce real-time CPR/CDR predictions per vintage cohort. Columnstore's batch-mode execution pairs naturally with in-database ML scoring (sp_execute_external_script) to generate forward-looking loss curves without data movement.

---

### Q42. Describe your implementation of In-Memory OLTP (Hekaton) for real-time MBS pricing calculations.

**Situation:** Our trading desk priced mortgage-backed securities using a SQL Server-backed engine that performed cashflow waterfall calculations for RMBS deals. During market hours, the system needed to reprice 5,000+ tranches every 15 minutes as prepayment assumptions (CPR vectors) and yield curves shifted. Disk-based tables with pessimistic locking caused lock contention and the repricing cycle was taking 22 minutes, meaning traders operated on stale prices.

**Task:** Reduce the full repricing cycle to under 5 minutes to ensure traders always worked with current valuations, while maintaining ACID compliance for audit and regulatory requirements.

**Action:** I migrated the hot-path pricing tables to memory-optimized tables and rewrote the waterfall calculation as a natively compiled stored procedure.

```sql
-- Memory-optimized table for live pricing assumptions
CREATE TABLE dbo.PrepayAssumptions (
    scenario_id    INT NOT NULL PRIMARY KEY NONCLUSTERED HASH WITH (BUCKET_COUNT = 50000),
    tranche_id     INT NOT NULL,
    month_offset   SMALLINT NOT NULL,
    cpr_vector     FLOAT NOT NULL,
    cdr_vector     FLOAT NOT NULL,
    severity       FLOAT NOT NULL,
    INDEX ix_tranche NONCLUSTERED (tranche_id, month_offset)
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);

-- Natively compiled procedure for cashflow waterfall
CREATE PROCEDURE dbo.usp_CalculateTranchePrice
    @tranche_id INT, @discount_rate FLOAT
WITH NATIVE_COMPILATION, SCHEMABINDING, EXECUTE AS OWNER
AS BEGIN ATOMIC WITH (TRANSACTION ISOLATION LEVEL = SNAPSHOT, LANGUAGE = N'English')
    DECLARE @pv FLOAT = 0.0, @month SMALLINT = 1, @balance FLOAT, @cf FLOAT;
    SELECT @balance = current_face FROM dbo.TranchePositions WHERE tranche_id = @tranche_id;

    WHILE @month <= 360
    BEGIN
        SELECT @cf = @balance * (cpr_vector / 12.0 + cdr_vector * severity / 12.0)
        FROM dbo.PrepayAssumptions
        WHERE tranche_id = @tranche_id AND month_offset = @month;

        SET @pv += @cf / POWER(1.0 + @discount_rate / 12.0, @month);
        SET @balance -= @cf;
        SET @month += 1;
    END;

    UPDATE dbo.TranchePositions SET mark_to_model = @pv WHERE tranche_id = @tranche_id;
END;
```

I parallelized execution across tranches using Service Broker activation with 16 concurrent queue readers, each calling the natively compiled procedure. Lock-free optimistic concurrency in Hekaton eliminated all latch contention.

**Result:** Full repricing cycle dropped from 22 minutes to 3 minutes 10 seconds (7x improvement). Latch waits dropped to zero. Traders received updated marks every 5 minutes during volatile markets. The system processed 12 million cashflow projections per cycle with sub-millisecond per-tranche latency. Risk management confirmed pricing accuracy within 0.02 bps of the legacy system.

**AI Vision:** Neural network-based prepayment models could feed real-time CPR vectors directly into the memory-optimized assumption tables, creating a closed-loop system where ML-predicted borrower behavior instantly flows into tranche-level pricing without batch ETL.

---

### Q43. How would you use temporal tables for loan data versioning and regulatory point-in-time reporting?

**Situation:** Federal regulators and GSE counterparties (Fannie Mae, Freddie Mac) required our servicing platform to reproduce the exact state of any loan as of any historical date for CFPB audits, loss mitigation reviews, and HMDA resubmissions. Our existing approach relied on CDC tables and complex self-joins that were error-prone, slow, and had caused two regulatory findings for incorrect point-in-time data reconstruction.

**Task:** Implement an auditable, tamper-resistant loan versioning system that could instantly reconstruct any loan's attributes as of any historical date, satisfying CFPB examination requirements and GSE delivery validation timelines.

**Action:** I converted the core loan servicing tables to system-versioned temporal tables with a dedicated history schema for separation of concerns.

```sql
-- Convert loan master to temporal table
ALTER TABLE dbo.LoanMaster ADD
    SysStartTime DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN DEFAULT SYSUTCDATETIME(),
    SysEndTime   DATETIME2 GENERATED ALWAYS AS ROW END   HIDDEN DEFAULT CONVERT(DATETIME2, '9999-12-31 23:59:59.9999999');

ALTER TABLE dbo.LoanMaster SET (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = history.LoanMaster,
    DATA_CONSISTENCY_CHECK = ON,
    HISTORY_RETENTION_PERIOD = 10 YEARS
));

-- Point-in-time query for CFPB audit: loan state as of specific date
SELECT loan_number, borrower_name, current_upb, interest_rate,
       delinquency_status, loss_mit_type, investor_code
FROM dbo.LoanMaster FOR SYSTEM_TIME AS OF '2024-06-30T23:59:59'
WHERE loan_number = '1098234567';

-- HMDA resubmission: all loans that were active during a reporting period
SELECT loan_number, property_state, loan_purpose, occupancy_type
FROM dbo.LoanMaster FOR SYSTEM_TIME FROM '2024-01-01' TO '2024-12-31'
WHERE action_taken_code IN (1, 2, 3)
  AND investor_code IN ('FNM', 'FRE');

-- Audit trail: full change history for a specific loan
SELECT *, SysStartTime AS effective_from, SysEndTime AS effective_to
FROM dbo.LoanMaster FOR SYSTEM_TIME ALL
WHERE loan_number = '1098234567'
ORDER BY SysStartTime;
```

I indexed the history table on `(loan_number, SysStartTime, SysEndTime)` with a columnstore index for range scans. I also implemented a retention policy that archived history beyond 10 years to Azure Blob via external tables.

**Result:** Point-in-time reconstruction queries dropped from 45 seconds (CDC-based) to under 1 second. The next CFPB examination completed with zero data findings for the first time in 3 years. HMDA resubmission turnaround improved from 5 days to 4 hours. Developer effort for audit queries reduced by 80% since temporal syntax eliminated complex self-join logic.

**AI Vision:** An anomaly detection model could continuously monitor the temporal change stream, flagging suspicious patterns such as rapid-fire loan modifications before default, which might indicate servicing fraud or data quality issues warranting regulatory attention.

---

### Q44. Explain how you designed a graph database model in SQL Server for modeling deal-tranche-loan relationships in securitization.

**Situation:** Our RMBS analytics platform needed to model complex securitization structures where loans pool into deals, deals contain multiple tranches with waterfall priorities, tranches have counterparty relationships (swap providers, trustees, servicers), and loans can be repurchased and re-securitized. The relational model required 8-table joins to traverse from a borrower to the ultimate investor, and Intex deal structure queries were timing out when analysts tried to trace exposure paths.

**Task:** Build a queryable graph model that could traverse securitization hierarchies in real time, enabling analysts to answer questions like "What is Investor X's total exposure to Florida ARM loans across all deal structures?" in under 5 seconds.

**Action:** I implemented SQL Server's graph tables (nodes and edges) to model the securitization ecosystem alongside the existing relational schema.

```sql
-- Node tables
CREATE TABLE dbo.Loan AS NODE (loan_number VARCHAR(20), upb DECIMAL(14,2), state CHAR(2), product_type VARCHAR(10));
CREATE TABLE dbo.Pool AS NODE (pool_id VARCHAR(15), pool_type VARCHAR(20), aggregate_upb DECIMAL(18,2));
CREATE TABLE dbo.Deal AS NODE (deal_name VARCHAR(50), shelf VARCHAR(20), closing_date DATE, deal_source VARCHAR(10)); -- Intex, CoreLogic
CREATE TABLE dbo.Tranche AS NODE (tranche_id VARCHAR(30), class_name VARCHAR(10), original_face DECIMAL(18,2), coupon FLOAT, priority INT);
CREATE TABLE dbo.Counterparty AS NODE (entity_name VARCHAR(100), role VARCHAR(30));

-- Edge tables
CREATE TABLE dbo.PooledIn AS EDGE;        -- Loan -> Pool
CREATE TABLE dbo.SecuritizedAs AS EDGE;   -- Pool -> Deal
CREATE TABLE dbo.StructuredInto AS EDGE;  -- Deal -> Tranche
CREATE TABLE dbo.InvestedBy AS EDGE;      -- Tranche -> Counterparty
CREATE TABLE dbo.ServicedBy AS EDGE;      -- Deal -> Counterparty

-- Traverse: Florida ARM exposure for a specific investor
SELECT c.entity_name, d.deal_name, t.class_name, SUM(l.upb) AS exposed_upb
FROM dbo.Counterparty AS c,
     dbo.InvestedBy AS ib,
     dbo.Tranche AS t,
     dbo.StructuredInto AS si,
     dbo.Deal AS d,
     dbo.SecuritizedAs AS sa,
     dbo.Pool AS p,
     dbo.PooledIn AS pi,
     dbo.Loan AS l
WHERE MATCH(c<-(ib)-t<-(si)-d<-(sa)-p<-(pi)-l)
  AND c.entity_name = 'PIMCO Total Return Fund'
  AND l.state = 'FL' AND l.product_type = 'ARM'
GROUP BY c.entity_name, d.deal_name, t.class_name;
```

I maintained the graph edges via triggers on the relational base tables so the graph stayed synchronized without dual-write complexity. Edge indexes on `($from_id, $to_id)` ensured traversal efficiency.

**Result:** Exposure path queries dropped from 35 seconds (8-table relational join) to 2.1 seconds via graph traversal. Analysts could interactively trace securitization chains during deal review meetings. The graph model also uncovered 12 previously unknown circular re-securitization paths that represented concentration risk, a finding that directly influenced portfolio strategy.

**AI Vision:** Graph neural networks (GNNs) could be trained on the securitization graph to predict tranche downgrade risk based on structural features and neighborhood loan performance, enabling proactive risk management rather than reactive surveillance.

---

### Q45. How did you leverage JSON processing in SQL Server for handling semi-structured CoreLogic property data feeds?

**Situation:** CoreLogic delivered property valuation and risk data via JSON-formatted API responses and bulk file feeds. Each property record contained 200+ attributes, but the schema varied by property type (single-family had different fields than condo or manufactured housing). Our prior approach of parsing into a fully normalized relational schema required schema changes every quarter when CoreLogic added fields, causing 2-3 week delays in onboarding new attributes that underwriters needed.

**Task:** Design a flexible storage and query strategy that could ingest CoreLogic JSON feeds without schema changes while maintaining SQL-queryable access for loan origination and due diligence workflows.

**Action:** I implemented a hybrid relational-JSON design: core indexed fields as columns, extended attributes stored as a JSON column with computed columns and JSON indexes for frequently queried paths.

```sql
CREATE TABLE dbo.PropertyValuation (
    property_id       BIGINT IDENTITY PRIMARY KEY,
    corelogic_clip    VARCHAR(20) NOT NULL,
    appraisal_date    DATE NOT NULL,
    avm_value         DECIMAL(14,2),
    confidence_score  DECIMAL(5,2),
    property_type     VARCHAR(20),
    extended_attrs    NVARCHAR(MAX) CHECK (ISJSON(extended_attrs) = 1),
    -- Computed columns for hot-path JSON attributes
    flood_zone AS JSON_VALUE(extended_attrs, '$.risk.flood_zone'),
    hpi_index  AS CAST(JSON_VALUE(extended_attrs, '$.market.hpi_current') AS DECIMAL(10,4)),
    INDEX ix_flood NONCLUSTERED (flood_zone) WHERE flood_zone IS NOT NULL
);

-- Bulk ingest from CoreLogic JSON file using OPENROWSET + OPENJSON
INSERT INTO dbo.PropertyValuation (corelogic_clip, appraisal_date, avm_value, confidence_score, property_type, extended_attrs)
SELECT j.clip, CONVERT(DATE, j.appraisal_dt), j.avm, j.confidence, j.prop_type, j.raw_json
FROM OPENROWSET(BULK 'D:\feeds\corelogic\2025Q4_valuations.json', SINGLE_CLOB) AS f
CROSS APPLY OPENJSON(f.BulkColumn, '$.properties') WITH (
    clip          VARCHAR(20)   '$.corelogic_clip',
    appraisal_dt  VARCHAR(10)   '$.appraisal_date',
    avm           DECIMAL(14,2) '$.avm_value',
    confidence    DECIMAL(5,2)  '$.confidence_score',
    prop_type     VARCHAR(20)   '$.property_type',
    raw_json      NVARCHAR(MAX) '$' AS JSON
) AS j;

-- Query: underwriter pulls flood risk with nested JSON attributes
SELECT pv.corelogic_clip, pv.avm_value, pv.flood_zone,
       JSON_VALUE(pv.extended_attrs, '$.risk.wildfire_score') AS wildfire_score,
       JSON_VALUE(pv.extended_attrs, '$.structure.year_built') AS year_built,
       r.*
FROM dbo.PropertyValuation pv
CROSS APPLY OPENJSON(pv.extended_attrs, '$.risk.hazard_events') WITH (
    event_type VARCHAR(30), event_date DATE, severity VARCHAR(10)
) r
WHERE pv.corelogic_clip = 'CLIP-00291837';
```

I created a schema registry table that cataloged available JSON paths per property type, enabling a front-end dynamic query builder. New CoreLogic attributes were immediately queryable upon ingest without any DDL changes.

**Result:** New attribute onboarding dropped from 2-3 weeks (DDL + ETL changes) to zero elapsed time. Ingestion throughput reached 500K property records per hour. Underwriter query response stayed under 2 seconds for single-property lookups. The flexible schema survived 4 consecutive quarterly CoreLogic format changes with zero code modifications. Storage was 40% less than the equivalent fully normalized model.

**AI Vision:** A property valuation ML model could consume the JSON attributes directly via `sp_execute_external_script`, scoring properties for automated appraisal waiver eligibility, feeding predictions back as a new JSON attribute without schema changes.

---

### Q46. Describe your approach to migrating on-premise mortgage databases to Azure SQL with minimal downtime.

**Situation:** Our primary mortgage servicing database (4.2 TB, 800+ tables, 200+ stored procedures) ran on SQL Server 2017 Enterprise on-premise. The data center lease was expiring in 8 months, and leadership mandated cloud migration. The system processed $45 billion in monthly payment transactions and had a contractual SLA of 99.95% uptime with GSE counterparties (Fannie/Freddie), meaning maximum allowable downtime was approximately 22 minutes per month.

**Task:** Migrate the full mortgage servicing platform to Azure SQL Managed Instance with under 30 minutes of total cutover downtime while maintaining data integrity for in-flight payment processing and GSE reporting cycles.

**Action:** I designed a phased migration using Azure Database Migration Service (DMS) in online mode with a comprehensive pre-migration assessment and cutover orchestration plan.

```sql
-- Phase 1: Pre-migration compatibility assessment
-- Ran Data Migration Assistant (DMA) to identify breaking changes
-- Key findings: 3 cross-database queries, 2 CLR assemblies, 1 Service Broker dependency

-- Phase 2: Remediate incompatibilities before migration
-- Replaced cross-database queries with elastic queries
-- Converted CLR string functions to STRING_AGG and STRING_SPLIT (SQL 2017+)
-- Replaced Service Broker with Azure Service Bus (app-layer change)

-- Phase 3: DMS continuous sync (online migration mode)
-- Initial full backup + restore to Managed Instance (18 hours)
-- Continuous log shipping to keep target within seconds of source
-- Validated row counts and checksums on critical tables
SELECT t.name AS table_name,
       SUM(p.rows) AS row_count,
       CHECKSUM_AGG(BINARY_CHECKSUM(*)) AS data_checksum
FROM sys.tables t
JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0, 1)
GROUP BY t.name
ORDER BY row_count DESC;

-- Phase 4: Cutover rehearsal (performed 3 times before actual cutover)
-- 1. Stop application writes (connection string swap to read-only)
-- 2. Wait for DMS to drain remaining log backups (< 2 min)
-- 3. Final consistency validation
-- 4. Switch DNS CNAME to Azure SQL MI endpoint
-- 5. Re-enable application writes

-- Phase 5: Post-migration optimization
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = OFF;
-- Rebuilt statistics with fullscan after migration
EXEC sp_MSforeachtable 'UPDATE STATISTICS ? WITH FULLSCAN';
```

I scheduled the cutover for the last Sunday of the month, after GSE delivery windows closed and before the next payment cycle. The team rehearsed the cutover 3 times on a parallel environment, reducing each rehearsal's downtime until we consistently achieved under 20 minutes.

**Result:** Actual production cutover completed in 17 minutes of downtime, well within the 30-minute target. Zero data loss confirmed via row count and checksum validation across all 800+ tables. Post-migration, query performance improved 15% due to Azure SQL MI's Gen5 hardware. Infrastructure cost decreased 35% compared to the on-premise data center lease. The migration passed GSE audit with no findings, and the first monthly payment cycle on Azure processed $47 billion flawlessly.

**AI Vision:** Azure ML integration with SQL Managed Instance could enable in-database fraud detection on payment transactions, leveraging the cloud-native architecture to score every payment in real time, which was computationally infeasible on the legacy on-premise infrastructure.

---

### Q47. How would you use Intelligent Query Processing features (SQL 2019/2022) to improve mortgage batch processing?

**Situation:** Our nightly batch processing pipeline calculated payment waterfalls, escrow analyses, and investor accounting for 3.2 million active loans. Running on SQL Server 2019 (compatibility level 150), many stored procedures had been written years earlier with parameter sniffing workarounds (`OPTION (RECOMPILE)`, local variable copies) that masked the underlying cardinality estimation issues. The full nightly batch took 6.5 hours, pushing dangerously close to the 7 AM SLA when business users needed updated data.

**Task:** Reduce the nightly batch window from 6.5 hours to under 4 hours by leveraging Intelligent Query Processing (IQP) features without rewriting the 200+ stored procedures, minimizing regression risk.

**Action:** I systematically enabled and validated IQP features across the batch pipeline, testing each feature's impact in a staging environment with production-volume data.

```sql
-- Step 1: Upgrade compatibility level to unlock IQP features
ALTER DATABASE MortgageServicing SET COMPATIBILITY_LEVEL = 160; -- SQL 2022

-- Step 2: Enable Query Store for before/after regression analysis
ALTER DATABASE MortgageServicing SET QUERY_STORE = ON (
    OPERATION_MODE = READ_WRITE,
    MAX_STORAGE_SIZE_MB = 4096,
    QUERY_CAPTURE_MODE = AUTO
);

-- Step 3: Key IQP features that delivered measurable gains:

-- A) Batch Mode on Rowstore: escrow analysis scanned millions of rows
--    with GROUP BY on rowstore tables. Batch mode kicked in automatically.
--    Before: 45 min | After: 12 min (escrow aggregation proc)

-- B) Adaptive Joins: payment waterfall proc had variable loan counts per investor
--    Optimizer now switches between hash and nested loop at runtime
SELECT i.investor_code, SUM(p.principal_amount) AS total_principal,
       SUM(p.interest_amount) AS total_interest
FROM dbo.Payments p
JOIN dbo.InvestorMapping i ON p.loan_id = i.loan_id
WHERE p.payment_date = @batch_date
GROUP BY i.investor_code
OPTION (USE HINT('ENABLE_QUERY_OPTIMIZER_HOTFIXES')); -- ensures latest fixes

-- C) Memory Grant Feedback (Percentile): eliminated the #1 batch bottleneck
--    Investor accounting proc had wildly variable row counts per servicer
--    Persistent memory grant feedback (SQL 2022) stabilized spills to tempdb
--    Before: 800+ tempdb spills/night | After: 12 spills/night

-- D) Parameter Sensitive Plan Optimization (PSP): SQL 2022
--    Eliminated need for OPTION(RECOMPILE) on 37 procedures
--    Multiple plan variants cached per parameter distribution

-- Step 4: Removed legacy workarounds that now conflicted with IQP
-- Removed OPTION(RECOMPILE) from 37 procs (PSP handles plan sensitivity)
-- Removed local variable pattern: SET @local = @param (masked statistics)
-- Before removal, validated via Query Store that new plans were superior
```

I phased the rollout over 3 weeks: week 1 enabled IQP on staging with Query Store comparison, week 2 enabled on production in read-only observation mode, week 3 removed legacy workarounds after confirming regression-free execution.

**Result:** Nightly batch dropped from 6.5 hours to 3 hours 40 minutes (43% improvement) with zero stored procedure rewrites in the initial phase. Tempdb spill events decreased from 800+ to 12 per night. Memory grant accuracy improved from 45% to 94%. Removing `OPTION (RECOMPILE)` from 37 procedures reduced compilation CPU by 60%. The 7 AM SLA was met with a 3+ hour buffer, and the approach was adopted as the template for all database upgrades across the enterprise.

**AI Vision:** SQL Server 2022's Query Store hints combined with ML-driven workload analysis could automatically identify procedures that would benefit from specific IQP features, creating a self-tuning batch pipeline that adapts to seasonal mortgage volume fluctuations (e.g., spring home-buying surge).

---

### Q48. Explain your strategy for implementing cross-database queries between SQL Server and Snowflake for hybrid mortgage analytics.

**Situation:** Our mortgage analytics ecosystem was split: operational/servicing data lived in SQL Server (real-time, transactional), while historical analytics, Fannie/Freddie public datasets, and third-party enrichment data (CoreLogic, Intex) resided in Snowflake. Analysts needed to join real-time servicing data (current delinquency status, UPB) with Snowflake's historical prepayment models and property market data. They were manually exporting CSVs and loading them, introducing 24-48 hour data latency and frequent reconciliation errors.

**Task:** Create a seamless query experience where analysts could join SQL Server and Snowflake data in a single T-SQL query with sub-minute data latency, without requiring them to learn Snowflake SQL or manage data exports.

**Action:** I implemented a multi-layered integration strategy using PolyBase, linked servers, and a lightweight change-data-capture sync layer.

```sql
-- Layer 1: PolyBase external tables for Snowflake data access from T-SQL
CREATE EXTERNAL DATA SOURCE SnowflakeAnalytics WITH (
    LOCATION = 'odbc://myorg-mortgage.snowflakecomputing.com',
    CONNECTION_OPTIONS = 'Driver={Snowflake};Database=MORTGAGE_ANALYTICS;Warehouse=ANALYTICS_WH',
    CREDENTIAL = SnowflakeCredential,
    PUSHDOWN = ON  -- Critical: pushes filters to Snowflake
);

CREATE EXTERNAL TABLE dbo.ext_HistoricalPrepayment (
    vintage_year    INT,
    loan_age        INT,
    product_type    VARCHAR(20),
    avg_cpr         FLOAT,
    avg_cdr         FLOAT,
    observation_count BIGINT
) WITH (DATA_SOURCE = SnowflakeAnalytics, LOCATION = 'ANALYTICS.PUBLIC.PREPAYMENT_CURVES');

-- Layer 2: Hybrid query - real-time SQL Server + Snowflake historical
-- Analysts write pure T-SQL; PolyBase handles federation
SELECT s.investor_code, s.product_type,
       COUNT(*) AS active_loans,
       SUM(s.current_upb) AS total_upb,
       AVG(s.current_rate) AS wavg_rate,
       h.avg_cpr AS historical_cpr,
       h.avg_cdr AS historical_cdr
FROM dbo.LoanServicing s  -- SQL Server (real-time)
JOIN dbo.ext_HistoricalPrepayment h  -- Snowflake (via PolyBase)
  ON YEAR(s.origination_date) = h.vintage_year
  AND s.loan_age_months = h.loan_age
  AND s.product_type = h.product_type
WHERE s.investor_code IN ('FNM', 'FRE', 'GNM')
GROUP BY s.investor_code, s.product_type, h.avg_cpr, h.avg_cdr;

-- Layer 3: CDC sync for hot tables (minimize cross-system query latency)
-- Used SQL Server CDC -> Kafka -> Snowflake Snowpipe for near-real-time sync
-- of high-velocity tables (payments, delinquency status)
-- This ensured Snowflake-side analytics had < 5 min data latency
```

I implemented query predicate pushdown validation to ensure filters were pushed to Snowflake rather than pulling full tables. For the most frequently joined Snowflake tables, I created materialized cache tables in SQL Server refreshed every 15 minutes, with a smart routing layer that directed queries to cache or live PolyBase based on freshness requirements.

**Result:** Analysts went from 24-48 hour data latency with CSV exports to sub-5-minute latency via the hybrid query layer. Query federation across 400 million Snowflake rows + 50 million SQL Server rows completed in 8-15 seconds with pushdown. Manual data export effort was eliminated (previously 20 analyst-hours/week). Reconciliation errors dropped to zero. The architecture became the standard pattern adopted by 3 other business units for their own hybrid analytics.

**AI Vision:** A query routing ML model could learn analyst query patterns and pre-cache Snowflake result sets likely to be requested, predicting which vintage/product combinations would be queried based on market conditions and upcoming GSE reporting deadlines.

---

### Q49. How did you design a dynamic SQL framework for generating ad-hoc loan pool analytics reports?

**Situation:** Capital markets analysts needed to slice loan pools by any combination of 40+ attributes (LTV, FICO, state, property type, loan purpose, servicer, vintage, coupon band, etc.) with aggregations (WA coupon, WA FICO, WA LTV, total UPB, count, delinquency distribution) for deal structuring, trading, and investor reporting. Each analyst had unique stratification needs, and the development team was receiving 15+ stored procedure change requests per month for new report variations, creating a maintenance nightmare with 300+ one-off reporting procedures.

**Task:** Build a parameterized dynamic SQL engine that allowed analysts to self-service any stratification of loan pools without developer intervention, while preventing SQL injection and maintaining sub-10-second response times on pools of up to 2 million loans.

**Action:** I designed a metadata-driven dynamic SQL framework with a whitelist validation layer and query plan caching strategy.

```sql
-- Metadata table defining allowed dimensions and measures
CREATE TABLE dbo.PoolAnalyticsDimensions (
    dimension_key   VARCHAR(50) PRIMARY KEY,  -- 'state', 'fico_band', 'ltv_band'
    column_expr     VARCHAR(200) NOT NULL,     -- actual column/expression
    display_name    VARCHAR(100) NOT NULL,
    data_type       VARCHAR(20) NOT NULL
);

-- Core dynamic SQL generator (simplified)
CREATE PROCEDURE dbo.usp_LoanPoolStratification
    @pool_id        INT,
    @dimensions     VARCHAR(500),  -- comma-separated: 'state,fico_band,product_type'
    @filters        NVARCHAR(MAX) = NULL  -- JSON filter spec
AS BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX), @group_cols NVARCHAR(MAX) = '', @where NVARCHAR(MAX) = '';

    -- Whitelist validation: only allow registered dimensions
    SELECT @group_cols = STRING_AGG(d.column_expr, ', ') WITHIN GROUP (ORDER BY d.dimension_key)
    FROM dbo.PoolAnalyticsDimensions d
    JOIN STRING_SPLIT(@dimensions, ',') s ON TRIM(s.value) = d.dimension_key;

    IF @group_cols IS NULL
        THROW 50001, 'Invalid dimension specified. Check PoolAnalyticsDimensions.', 1;

    -- Parse JSON filters safely using parameterized OPENJSON
    IF @filters IS NOT NULL
        SELECT @where = STRING_AGG(
            QUOTENAME(d.column_expr) + ' = @fval_' + CAST(ROW_NUMBER() OVER(ORDER BY f.[key]) AS VARCHAR),
            ' AND '
        )
        FROM OPENJSON(@filters) f
        JOIN dbo.PoolAnalyticsDimensions d ON f.[key] = d.dimension_key;

    SET @sql = N'
    SELECT ' + @group_cols + ',
           COUNT(*) AS loan_count,
           SUM(current_upb) AS total_upb,
           SUM(current_upb * note_rate) / NULLIF(SUM(current_upb), 0) AS wa_coupon,
           SUM(current_upb * fico_score) / NULLIF(SUM(current_upb), 0) AS wa_fico,
           SUM(current_upb * cltv) / NULLIF(SUM(current_upb), 0) AS wa_ltv,
           SUM(CASE WHEN delinq_status >= 3 THEN current_upb ELSE 0 END)
             / NULLIF(SUM(current_upb), 0) AS serious_delinq_pct
    FROM dbo.LoanPool_Detail
    WHERE pool_id = @pool_id' +
    CASE WHEN @where <> '' THEN ' AND ' + @where ELSE '' END + '
    GROUP BY ' + @group_cols + '
    ORDER BY total_upb DESC
    OPTION (MAXDOP 8);';

    EXEC sp_executesql @sql, N'@pool_id INT', @pool_id = @pool_id;
END;

-- Usage: analyst self-service call
EXEC dbo.usp_LoanPoolStratification
    @pool_id = 2847,
    @dimensions = 'state,fico_band,product_type',
    @filters = '{"property_type":"SFR","occupancy":"P"}';
```

I wrapped the framework with a thin web API that presented analysts with a drag-and-drop UI for dimension selection, which called the stored procedure underneath. Query plans were reused via `sp_executesql` parameterization, and I implemented a result cache layer for repeated stratifications.

**Result:** Developer change requests for reporting procedures dropped from 15/month to near zero. The 300+ one-off procedures were retired over 6 months. Analysts could generate any stratification in 3-8 seconds for pools up to 2 million loans. The framework was adopted by the trading desk, investor reporting, and risk management teams. Total developer hours reclaimed: ~120 hours/month redirected to strategic projects.

**AI Vision:** An NLP layer could allow analysts to express stratification requests in natural language ("Show me Florida condos with FICO below 680 grouped by vintage and servicer"), which an LLM would translate into the framework's parameter format, further eliminating the technical barrier to data exploration.

---

### Q50. Describe your most complex performance troubleshooting scenario in a mortgage data environment and how you resolved it.

**Situation:** During month-end GSE investor accounting, our payment remittance calculation procedure suddenly degraded from a 45-minute normal runtime to 9+ hours, threatening to miss the Fannie Mae actual/actual remittance deadline. The procedure computed principal and interest allocations for 2.8 million loans across 1,200 investor pools. No code had changed; the degradation appeared overnight. The DBA team's initial investigation found no obvious blocking, no hardware failures, and no unusual volume increase. Business stakeholders were escalating every 30 minutes.

**Task:** Diagnose and resolve the performance degradation within 4 hours to meet the GSE remittance submission deadline, then implement permanent preventive measures.

**Action:** I conducted a systematic top-down performance investigation using wait statistics, execution plan analysis, and statistics profiling.

```sql
-- Step 1: Capture wait statistics during the slow execution
SELECT wait_type, wait_time_ms, waiting_tasks_count,
       signal_wait_time_ms, wait_time_ms - signal_wait_time_ms AS resource_wait_ms
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN ('SLEEP_TASK','LAZYWRITER_SLEEP','BROKER_TO_FLUSH')
ORDER BY wait_time_ms DESC;
-- Finding: CXPACKET and HASH_MATCH_SPILL dominated. Massive tempdb spills.

-- Step 2: Pulled actual execution plan from Query Store
SELECT qsp.query_plan, qrs.avg_duration, qrs.avg_tempdb_space_used
FROM sys.query_store_plan qsp
JOIN sys.query_store_runtime_stats qrs ON qsp.plan_id = qrs.plan_id
WHERE qsp.query_id = 48291
ORDER BY qrs.last_execution_time DESC;
-- Finding: Cardinality estimate showed 50K rows; actual was 2.8 million.
-- The optimizer chose a nested loop join instead of hash join.

-- Step 3: Root cause identified - auto-update statistics had not triggered
-- A bulk loan boarding (180K new loans) added rows but stayed below the
-- 20% threshold on the 2.8M row table (only 6.4% change)
DBCC SHOW_STATISTICS('dbo.PaymentAllocation', 'IX_InvestorPool');
-- Last updated: 26 days ago. Histogram completely stale for new pools.

-- Step 4: Immediate fix - update statistics and force recompilation
UPDATE STATISTICS dbo.PaymentAllocation WITH FULLSCAN;
UPDATE STATISTICS dbo.InvestorPoolMapping WITH FULLSCAN;
UPDATE STATISTICS dbo.LoanServicingDetail WITH FULLSCAN;
EXEC sp_recompile 'dbo.usp_CalculateRemittance';

-- Step 5: Re-executed procedure - completed in 38 minutes (normal)

-- Step 6: Permanent preventive measures
-- A) Lowered auto-update threshold for critical tables
ALTER DATABASE MortgageServicing
SET AUTO_UPDATE_STATISTICS ON;
-- Enabled trace flag 2371 for dynamic stats update threshold
DBCC TRACEON(2371, -1); -- Lowers threshold as table grows

-- B) Scheduled pre-batch statistics maintenance
CREATE PROCEDURE dbo.usp_PreBatchStatsRefresh AS
BEGIN
    -- Update stats on tables modified since last batch
    DECLARE @sql NVARCHAR(MAX);
    SELECT @sql = STRING_AGG(
        'UPDATE STATISTICS ' + QUOTENAME(s.name) + '.' + QUOTENAME(t.name)
        + ' WITH SAMPLE 50 PERCENT;', CHAR(10))
    FROM sys.dm_db_stats_properties sp
    JOIN sys.tables t ON sp.object_id = t.object_id
    JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE sp.modification_counter > 10000
      AND sp.last_updated < DATEADD(HOUR, -4, GETDATE());
    EXEC sp_executesql @sql;
END;

-- C) Query Store forced plan as safety net
EXEC sp_query_store_force_plan @query_id = 48291, @plan_id = 1547;
-- Forces the known-good hash join plan
```

I also implemented a real-time monitoring dashboard that tracked statistics staleness, plan regressions via Query Store, and tempdb spill trends, with automated alerts when any metric crossed warning thresholds.

**Result:** The immediate fix restored the remittance procedure to its 38-minute runtime, and we submitted to Fannie Mae with 2 hours to spare before the deadline. The permanent measures (TF 2371, pre-batch stats refresh, Query Store forced plans) prevented recurrence over the following 18 months. Tempdb spill-related incidents dropped from monthly occurrences to zero. The diagnostic methodology was documented and became the standard runbook for all production performance incidents, reducing mean-time-to-resolution from 4 hours to under 45 minutes across the team.

**AI Vision:** An ML-powered anomaly detection system monitoring query execution metrics in real time could have predicted the statistics staleness before it caused the regression, automatically triggering statistics updates when it detected cardinality estimate drift exceeding a learned threshold, preventing the crisis entirely.

---
