# Advanced Snowflake - Q&A (Part 2: Data Loading, Semi-Structured and SQL Features)

[Back to Index](README.md)

---

### Q11. How did you design a Snowpipe-based continuous ingestion pipeline for real-time loan status updates from multiple servicers?

**Situation:** Our secondary market platform received daily and intra-day loan status updates from 12+ servicers (Wells Fargo, JPMorgan, PennyMac, etc.) via S3 drops. Each servicer used a slightly different file layout, and we needed near-real-time visibility into delinquency transitions, prepayments, and loss events across a $400B servicing book to meet Fannie Mae and Freddie Mac investor reporting deadlines.

**Task:** Design a continuous ingestion pipeline that auto-detects new files per servicer, applies the correct schema mapping, and lands data into Snowflake within 5 minutes of arrival -- replacing a legacy batch ETL that ran once nightly.

**Action:** I created a multi-pipe architecture with servicer-specific external stages and file formats:
```sql
-- Servicer-specific stage with auto-ingest Snowpipe
CREATE OR REPLACE STAGE stg_servicer_wellsfargo
  URL = 's3://mortgage-feeds/wellsfargo/loan_status/'
  STORAGE_INTEGRATION = si_mortgage_feeds
  FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"'
                 NULL_IF = ('', 'NULL', 'N/A') DATE_INPUT_FORMAT = 'MM/DD/YYYY');

CREATE OR REPLACE PIPE pipe_wf_loan_status AUTO_INGEST = TRUE AS
  COPY INTO raw.loan_status_wellsfargo
  FROM @stg_servicer_wellsfargo
  MATCH_PATTERN = '.*loan_status_\\d{8}\\.csv'
  ON_ERROR = 'SKIP_FILE_3%';  -- tolerate minor servicer data quality issues

-- Unified view across all servicer pipes with standardized column mapping
CREATE OR REPLACE VIEW curated.v_loan_status_unified AS
SELECT loan_number, 'WF' AS servicer_code, current_upb, delinquency_status,
       loan_age, remaining_term, next_payment_date, file_load_ts
FROM raw.loan_status_wellsfargo
UNION ALL
SELECT loan_id, 'JPM', unpaid_balance, dlq_bucket,
       months_since_origination, rem_months, nxt_pmt_dt, _load_ts
FROM raw.loan_status_jpmorgan;
-- ... additional servicers

-- SQS event notification on the S3 bucket triggers auto-ingest
-- Monitor pipe health
SELECT SYSTEM$PIPE_STATUS('pipe_wf_loan_status');
```
I configured S3 event notifications (SQS) per servicer prefix, added a monitoring Task that checked `COPY_HISTORY` every 10 minutes for load failures, and built an alerting layer using Snowflake alerts that notified the ops team via AWS SNS when any pipe stalled or error rates exceeded 3%.

**Result:** Loan status data was available in Snowflake within 2-4 minutes of S3 arrival, down from 8-12 hours with the old batch process. This enabled same-day delinquency reporting to GSEs, reduced investor inquiry resolution time by 70%, and identified $12M in early prepayment trends that the portfolio team used to adjust hedging positions.

**AI Vision:** An ML anomaly detection model (Isolation Forest) trained on historical load patterns could flag unusual file sizes, record counts, or schema drift in real time. A classifier could also auto-detect servicer file formats, eliminating the need for servicer-specific pipe definitions and adapting to layout changes without manual intervention.

---

### Q12. Describe your approach to processing semi-structured Intex deal cashflow data (JSON/XML) in Snowflake.

**Situation:** Our MBS analytics team needed to ingest Intex CDI (Cashflow Data Interface) outputs -- deeply nested XML files containing deal structures, tranche definitions, collateral groups, and monthly projected cashflows for 3,000+ RMBS/CMBS deals. Each deal file was 50-200MB of nested XML with up to 8 levels of hierarchy, and analysts were manually exporting subsets to Excel, creating a 3-day lag in deal surveillance.

**Task:** Build an automated pipeline to parse Intex XML/JSON cashflow data into queryable relational tables in Snowflake, enabling analysts to run tranche-level cashflow projections, prepayment scenario comparisons, and loss waterfall analysis directly in SQL.

**Action:** I ingested the raw files into a VARIANT column, then used Snowflake's semi-structured functions to extract and flatten the hierarchy:
```sql
-- Stage and load raw Intex XML (converted to JSON via pre-processing Lambda)
CREATE OR REPLACE TABLE raw.intex_deal_cashflows (
  deal_id        VARCHAR,
  run_date       DATE,
  scenario_id    VARCHAR,
  raw_payload    VARIANT,
  _loaded_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Extract tranche-level cashflow projections from nested JSON
CREATE OR REPLACE TABLE curated.tranche_cashflows AS
SELECT
  raw_payload:deal_info:deal_name::STRING            AS deal_name,
  raw_payload:deal_info:cusip::STRING                AS deal_cusip,
  t.value:tranche_id::STRING                         AS tranche_id,
  t.value:tranche_class::STRING                      AS tranche_class,
  t.value:original_balance::NUMBER(18,2)             AS original_balance,
  cf.value:period::INT                               AS period,
  cf.value:period_date::DATE                         AS period_date,
  cf.value:scheduled_principal::NUMBER(18,2)          AS scheduled_principal,
  cf.value:interest_payment::NUMBER(18,2)             AS interest_payment,
  cf.value:prepayment::NUMBER(18,2)                   AS prepayment_amount,
  cf.value:loss_allocated::NUMBER(18,2)               AS loss_allocated,
  cf.value:ending_balance::NUMBER(18,2)               AS ending_balance,
  scenario_id, run_date
FROM raw.intex_deal_cashflows,
  LATERAL FLATTEN(input => raw_payload:tranches) t,
  LATERAL FLATTEN(input => t.value:cashflows)    cf
WHERE run_date = CURRENT_DATE();
```
I built a three-layer model: raw VARIANT storage, a curated layer with extracted tranche/collateral/waterfall tables, and a presentation layer with pre-aggregated views for common analytics like weighted-average life (WAL) and yield tables. Materialized views handled the most frequent queries.

**Result:** Analysts went from 3-day turnaround to querying any deal's cashflow projections in under 10 seconds. The pipeline processed all 3,000+ deals nightly in 45 minutes. Portfolio managers could now run side-by-side CPR/CDR scenario comparisons across entire deal shelves (e.g., all Fannie Mae CAS deals), which directly supported a $2B trading decision by identifying mispriced tranches.

**AI Vision:** An NLP model could parse the unstructured deal prospectus supplements alongside structured cashflow data, extracting trigger events, clean-up call provisions, and step-down conditions that affect waterfall logic. A time-series forecasting model could predict actual vs. projected cashflows to flag deals deviating from expected performance.

---

### Q13. How would you implement a MERGE-based SCD Type 2 pattern for tracking loan attribute changes over time?

**Situation:** In our Freddie Mac loan-level data warehouse, loan attributes such as current interest rate, servicer name, property value, and modification status changed over time. Regulatory reporting (HMDA, Reg AB II) and investor analytics required a full audit trail of every attribute change with effective date ranges. The loan universe was 25M+ active loans with monthly updates from the Single Family Loan-Level Dataset.

**Task:** Implement an efficient SCD Type 2 pattern that captures every attribute change as a new versioned row, maintains `effective_from`/`effective_to` date ranges, and supports both current-state and point-in-time queries without degrading query performance.

**Action:** I designed a MERGE-based SCD2 pattern using Snowflake Streams to detect changes:
```sql
-- Target dimension table
CREATE TABLE dim.loan_attributes (
  loan_sk          NUMBER AUTOINCREMENT,
  loan_number      VARCHAR(12),
  current_rate     NUMBER(6,3),
  servicer_name    VARCHAR(100),
  property_value   NUMBER(14,2),
  modification_flag BOOLEAN,
  ltv_ratio        NUMBER(6,2),
  effective_from   DATE NOT NULL,
  effective_to     DATE DEFAULT '9999-12-31',
  is_current       BOOLEAN DEFAULT TRUE,
  _hash_diff       VARCHAR(64)  -- SHA2 hash of tracked attributes for change detection
);

-- Stream captures CDC from staging table
CREATE STREAM stm_loan_staging ON TABLE staging.loan_monthly_update;

-- MERGE: expire old rows and insert new versions
MERGE INTO dim.loan_attributes tgt
USING (
  SELECT loan_number, current_rate, servicer_name, property_value,
         modification_flag, ltv_ratio, reporting_period,
         SHA2(CONCAT_WS('|', current_rate, servicer_name, property_value,
                        modification_flag, ltv_ratio)) AS _hash_diff
  FROM stm_loan_staging
  WHERE METADATA$ACTION = 'INSERT'
) src
ON tgt.loan_number = src.loan_number AND tgt.is_current = TRUE
   AND tgt._hash_diff = src._hash_diff   -- no change, skip
WHEN MATCHED AND tgt._hash_diff != src._hash_diff THEN
  UPDATE SET tgt.effective_to = src.reporting_period, tgt.is_current = FALSE
WHEN NOT MATCHED THEN
  INSERT (loan_number, current_rate, servicer_name, property_value,
          modification_flag, ltv_ratio, effective_from, is_current, _hash_diff)
  VALUES (src.loan_number, src.current_rate, src.servicer_name, src.property_value,
          src.modification_flag, src.ltv_ratio, src.reporting_period, TRUE, src._hash_diff);

-- Insert new version for changed records (second pass)
INSERT INTO dim.loan_attributes
SELECT NULL, loan_number, current_rate, servicer_name, property_value,
       modification_flag, ltv_ratio, reporting_period, '9999-12-31', TRUE, _hash_diff
FROM stm_loan_staging_changed;  -- filtered stream view of changed records
```
I partitioned the table by `effective_from` using clustering keys `(loan_number, effective_from)` which optimized both current-state lookups and time-travel queries. The hash-diff approach avoided expensive column-by-column comparisons on 25M rows.

**Result:** The SCD2 process handled 25M monthly loan records in 12 minutes, with change detection adding only 15% overhead vs. a simple overwrite. Audit queries like "show me all rate modifications for loans in Freddie Mac pool X between 2022-2024" ran in under 8 seconds. This directly supported $50M in regulatory compliance reporting and eliminated 3 manual reconciliation processes.

**AI Vision:** A drift detection model could learn typical attribute change patterns (e.g., rate modifications cluster after Fed rate decisions) and flag anomalous changes -- such as a servicer transfer affecting 10,000 loans simultaneously -- for quality review before committing to the dimension table.

---

### Q14. Explain how you used FLATTEN and LATERAL joins to parse nested CoreLogic property data feeds.

**Situation:** We subscribed to CoreLogic's property-level data feeds for collateral valuation and risk scoring across our $200B MBS portfolio. The feeds arrived as deeply nested JSON with property details, tax assessments, transaction history, mortgage liens, and AVM (Automated Valuation Model) estimates -- each property could have 5+ historical transactions and 3+ active liens, resulting in complex nested arrays.

**Task:** Parse and normalize the nested CoreLogic JSON into star-schema relational tables that analysts could join to loan-level data for LTV recalculation, collateral risk scoring, and property-level surveillance without writing any JSON path expressions themselves.

**Action:** I designed a multi-level FLATTEN strategy to handle the nested arrays:
```sql
-- Raw ingestion into VARIANT
CREATE TABLE raw.corelogic_property_feed (
  file_date   DATE,
  raw_data    VARIANT,
  _loaded_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Level 1: Property base attributes
-- Level 2: LATERAL FLATTEN on transaction history array
-- Level 3: LATERAL FLATTEN on lien array within each property
CREATE OR REPLACE VIEW curated.v_property_enriched AS
SELECT
  p.value:property_id::STRING                          AS property_id,
  p.value:address:street::STRING                       AS street_address,
  p.value:address:city::STRING                         AS city,
  p.value:address:state::STRING                        AS state_code,
  p.value:address:zip::STRING                          AS zip_code,
  p.value:avm:estimated_value::NUMBER(14,2)            AS avm_value,
  p.value:avm:confidence_score::NUMBER(5,2)            AS avm_confidence,
  p.value:avm:valuation_date::DATE                     AS avm_date,
  p.value:tax_assessment:assessed_value::NUMBER(14,2)  AS assessed_value,
  -- Transaction history (Level 2 flatten)
  tx.value:transaction_date::DATE                      AS sale_date,
  tx.value:sale_price::NUMBER(14,2)                    AS sale_price,
  tx.value:transaction_type::STRING                    AS transaction_type,
  -- Active liens (Level 3 flatten)
  ln.value:lien_position::INT                          AS lien_position,
  ln.value:original_amount::NUMBER(14,2)               AS lien_original_amount,
  ln.value:lender_name::STRING                         AS lien_lender,
  ln.value:origination_date::DATE                      AS lien_orig_date
FROM raw.corelogic_property_feed,
  LATERAL FLATTEN(input => raw_data:properties) p,
  LATERAL FLATTEN(input => p.value:transaction_history, OUTER => TRUE) tx,
  LATERAL FLATTEN(input => p.value:active_liens, OUTER => TRUE) ln
WHERE file_date >= DATEADD(DAY, -7, CURRENT_DATE());
```
The `OUTER => TRUE` was critical -- it preserved properties with no transaction history or no liens (common for new construction). I materialized the most-queried combinations into physical tables partitioned by state and refreshed daily, while keeping the full-depth view available for ad hoc analysis.

**Result:** Analysts could now join CoreLogic property data to our loan universe with a simple `JOIN ON property_id` instead of writing complex JSON parsing logic. The combined LTV recalculation across the portfolio (matching AVM values to current UPB) ran in 3 minutes vs. 4 hours in the old system. This powered a collateral risk dashboard that identified $800M in loans with LTV > 100% due to declining property values, enabling proactive loss mitigation outreach.

**AI Vision:** Computer vision models applied to property images (available in CoreLogic feeds) could provide independent condition assessments, supplementing AVM confidence scores. An ML model could also predict property value trajectories using the historical transaction data, improving mark-to-market accuracy for non-agency MBS portfolios.

---

### Q15. How did you optimize COPY INTO for loading monthly Fannie Mae/Freddie Mac loan-level disclosure files (100M+ records)?

**Situation:** Every month, Fannie Mae and Freddie Mac publish loan-level performance files through their public disclosure programs. The Fannie Mae dataset alone was 37+ columns, 100M+ records in pipe-delimited text files totaling 80GB+ uncompressed. Our initial naive `COPY INTO` took 4+ hours on an XL warehouse and frequently timed out, blocking downstream analytics for investor reporting.

**Task:** Reduce the monthly bulk load time from 4+ hours to under 30 minutes while maintaining data quality validation and supporting full historical reloads for backfill scenarios.

**Action:** I applied a systematic optimization strategy across file preparation, staging, and load configuration:
```sql
-- 1. Pre-split and compress files (external pre-processing via Python/Lambda)
--    Split 80GB file into 256MB gzip chunks (~320 files) for maximum parallelism

-- 2. Optimized file format with precise type hints
CREATE OR REPLACE FILE FORMAT ff_fannie_disclosure
  TYPE = CSV
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 0
  NULL_IF = ('')
  EMPTY_FIELD_AS_NULL = TRUE
  COMPRESSION = GZIP
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;  -- handle trailing delimiters

-- 3. Sized warehouse to match file count for optimal parallelism
-- 320 files / 8 nodes per cluster = 40 files per node (XL = 16 nodes, 2X-Large ideal)
ALTER WAREHOUSE wh_bulk_load SET WAREHOUSE_SIZE = 'X2LARGE';

-- 4. COPY INTO with performance tuning
COPY INTO staging.fannie_loan_performance
FROM @stg_fannie_disclosure/monthly/2025/
  FILE_FORMAT = ff_fannie_disclosure
  PATTERN = '.*perf_\\d{6}_chunk_.*\\.csv\\.gz'
  ON_ERROR = 'SKIP_FILE_0.1%'     -- strict: reject file if >0.1% errors
  FORCE = FALSE                     -- skip already-loaded files
  LOAD_UNCERTAIN_FILES = FALSE      -- respect load metadata
  PURGE = FALSE;                    -- keep source for audit

-- 5. Post-load validation
SELECT COUNT(*) AS total_rows,
       COUNT(DISTINCT loan_sequence_number) AS unique_loans,
       SUM(CASE WHEN current_upb IS NULL AND loan_age > 0 THEN 1 ELSE 0 END) AS suspect_rows,
       MIN(monthly_reporting_period) AS min_period,
       MAX(monthly_reporting_period) AS max_period
FROM staging.fannie_loan_performance
WHERE _loaded_at >= CURRENT_DATE();

-- 6. Scale down after load
ALTER WAREHOUSE wh_bulk_load SET WAREHOUSE_SIZE = 'XSMALL';
ALTER WAREHOUSE wh_bulk_load SUSPEND;
```
Key optimizations: (a) pre-splitting into ~256MB gzip chunks aligned with Snowflake's optimal file size, (b) sizing the warehouse so each node processed 20-40 files for balanced parallelism, (c) using `FORCE=FALSE` to enable idempotent reruns, and (d) automating warehouse scaling via a Task wrapper that sized up before load and suspended after.

**Result:** Monthly load time dropped from 4+ hours to 18 minutes on a 2X-Large warehouse. The cost per load decreased by 60% (shorter runtime offset the larger warehouse) from ~$120 to ~$48 in compute credits. The idempotent design eliminated 3 manual restart incidents per quarter, and the validation step caught a Freddie Mac schema change (new column added) before it corrupted downstream tables.

**AI Vision:** An ML workload optimizer could analyze historical load metrics (file sizes, record counts, cluster utilization) and dynamically recommend optimal warehouse size and file split strategy per load. Predictive scheduling could pre-warm warehouses based on GSE publication timing patterns.

---

### Q16. Describe your implementation of Streams and Tasks for CDC-based incremental processing of loan performance data.

**Situation:** Our loan data warehouse received continuous updates -- servicer feeds, GSE disclosures, loss mitigation outcomes, and modification events -- all landing in staging tables. Downstream consumers (risk models, investor reports, regulatory feeds) needed incrementally processed data without full-table rescans. The nightly full-refresh ETL was costing $800/day in compute and creating a 6-hour data freshness gap.

**Task:** Replace the full-refresh ETL with an incremental CDC pipeline using Snowflake Streams and Tasks that processes only changed data, runs every 15 minutes, and maintains exactly-once processing semantics.

**Action:** I built a multi-stream, multi-task DAG for incremental loan performance processing:
```sql
-- Streams on source tables to capture CDC
CREATE OR REPLACE STREAM stm_loan_performance
  ON TABLE staging.loan_performance
  APPEND_ONLY = FALSE;   -- capture updates and deletes too

CREATE OR REPLACE STREAM stm_loss_mitigation
  ON TABLE staging.loss_mitigation_events
  APPEND_ONLY = TRUE;    -- event table, inserts only

-- Task 1: Incremental merge into curated loan performance fact
CREATE OR REPLACE TASK tsk_process_loan_perf
  WAREHOUSE = wh_etl_medium
  SCHEDULE = '15 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('stm_loan_performance')
AS
MERGE INTO curated.fact_loan_performance tgt
USING (
  SELECT loan_number, reporting_period, current_upb, delinquency_status,
         loan_age, interest_rate, remaining_term, zero_balance_code,
         METADATA$ACTION, METADATA$ISUPDATE
  FROM stm_loan_performance
  WHERE METADATA$ACTION = 'INSERT'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY loan_number, reporting_period
                             ORDER BY _loaded_at DESC) = 1
) src
ON tgt.loan_number = src.loan_number
   AND tgt.reporting_period = src.reporting_period
WHEN MATCHED THEN UPDATE SET
  tgt.current_upb = src.current_upb,
  tgt.delinquency_status = src.delinquency_status,
  tgt.interest_rate = src.interest_rate,
  tgt._updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
  (loan_number, reporting_period, current_upb, delinquency_status,
   loan_age, interest_rate, remaining_term, zero_balance_code)
  VALUES (src.loan_number, src.reporting_period, src.current_upb,
          src.delinquency_status, src.loan_age, src.interest_rate,
          src.remaining_term, src.zero_balance_code);

-- Task 2: Child task for aggregation (runs after Task 1)
CREATE OR REPLACE TASK tsk_refresh_portfolio_summary
  WAREHOUSE = wh_etl_small
  AFTER tsk_process_loan_perf
AS
  INSERT OVERWRITE INTO curated.portfolio_summary_daily
  SELECT servicer_code, product_type, delinquency_bucket,
         COUNT(*) AS loan_count, SUM(current_upb) AS total_upb,
         AVG(interest_rate) AS wa_rate, CURRENT_TIMESTAMP() AS refreshed_at
  FROM curated.fact_loan_performance
  WHERE is_current = TRUE
  GROUP BY 1, 2, 3;

ALTER TASK tsk_refresh_portfolio_summary RESUME;
ALTER TASK tsk_process_loan_perf RESUME;
```
The `WHEN SYSTEM$STREAM_HAS_DATA` condition ensured zero-cost idle periods -- the task checked every 15 minutes but only consumed warehouse credits when new data existed. The stream's transactional guarantees ensured exactly-once processing even if a task failed mid-execution.

**Result:** Compute costs dropped from $800/day to $130/day (84% reduction) since we processed only deltas. Data freshness improved from 6 hours to 15 minutes. The task DAG successfully processed 2.5M incremental records/day across all feeds. Zero data loss incidents over 18 months of operation, validated by monthly reconciliation against GSE source counts.

**AI Vision:** A reinforcement learning agent could dynamically adjust task schedules and warehouse sizes based on incoming data volume patterns -- scaling up during month-end servicer reporting surges and down during quiet periods, optimizing the cost-freshness tradeoff automatically.

---

### Q17. How would you use Dynamic Tables to build a real-time loan portfolio analytics layer?

**Situation:** Our portfolio management team needed real-time aggregate views across the loan universe -- current delinquency distributions, prepayment speed trends, geographic concentration risk, and servicer performance scorecards. The existing approach used a chain of 15+ Tasks/Streams maintaining materialized aggregate tables, which was fragile (task failures cascaded), hard to debug, and required a dedicated engineer to maintain the DAG.

**Task:** Replace the brittle Task/Stream chain with Snowflake Dynamic Tables to create a declarative, self-maintaining analytics layer that automatically refreshes as upstream data changes, with configurable freshness targets per business use case.

**Action:** I designed a three-tier Dynamic Table hierarchy with escalating freshness targets:
```sql
-- Tier 1: Near-real-time loan current state (1-minute target lag)
CREATE OR REPLACE DYNAMIC TABLE dt_loan_current_state
  TARGET_LAG = '1 minute'
  WAREHOUSE = wh_dynamic_med
AS
SELECT loan_number, servicer_code, product_type, origination_date,
       current_upb, interest_rate, delinquency_status, property_state,
       CASE WHEN delinquency_status = '0' THEN 'Current'
            WHEN delinquency_status IN ('1','2') THEN 'Early DQ'
            WHEN delinquency_status IN ('3','4','5') THEN 'Serious DQ'
            ELSE 'Default/REO' END AS dq_bucket,
       modification_flag, current_ltv
FROM curated.fact_loan_performance
WHERE is_current = TRUE;

-- Tier 2: Portfolio aggregations (5-minute target lag, depends on Tier 1)
CREATE OR REPLACE DYNAMIC TABLE dt_portfolio_risk_summary
  TARGET_LAG = '5 minutes'
  WAREHOUSE = wh_dynamic_sm
AS
SELECT property_state, dq_bucket, product_type, servicer_code,
       COUNT(*)                                  AS loan_count,
       SUM(current_upb)                          AS total_upb,
       AVG(interest_rate)                        AS wa_coupon,
       AVG(current_ltv)                          AS wa_ltv,
       SUM(CASE WHEN modification_flag THEN current_upb ELSE 0 END)
         / NULLIF(SUM(current_upb), 0) * 100    AS mod_pct_by_upb,
       CURRENT_TIMESTAMP()                       AS snapshot_ts
FROM dt_loan_current_state
GROUP BY 1, 2, 3, 4;

-- Tier 3: Executive KPI layer (downstream = '10 minutes' lag)
CREATE OR REPLACE DYNAMIC TABLE dt_executive_kpis
  TARGET_LAG = '10 minutes'
  WAREHOUSE = wh_dynamic_xs
AS
SELECT
  SUM(total_upb)                                          AS portfolio_upb,
  SUM(CASE WHEN dq_bucket = 'Serious DQ' THEN total_upb ELSE 0 END)
    / NULLIF(SUM(total_upb), 0) * 100                    AS serious_dq_rate,
  SUM(CASE WHEN dq_bucket = 'Current' THEN loan_count ELSE 0 END)
    * 100.0 / NULLIF(SUM(loan_count), 0)                 AS current_pct,
  COUNT(DISTINCT servicer_code)                           AS active_servicers,
  snapshot_ts
FROM dt_portfolio_risk_summary
GROUP BY snapshot_ts;
```
The declarative approach meant Snowflake managed the refresh DAG automatically -- no Task scheduling, no Stream offset management, no failure cascading. I used `TARGET_LAG = DOWNSTREAM` on intermediate tables where freshness was dictated by consumer needs, and explicit lag targets only at the presentation layer.

**Result:** Eliminated 15 Tasks, 8 Streams, and ~400 lines of orchestration SQL. New metric additions went from 2-day development cycles (modify Task chain, test, deploy) to 30-minute Dynamic Table definitions. Portfolio dashboards showed data within 5 minutes of source updates vs. 15-60 minutes previously. Maintenance incidents dropped from 3/month to zero, freeing one engineer for higher-value analytics work.

**AI Vision:** Dynamic Tables feeding a real-time ML scoring layer could continuously update loan-level default probability scores as attributes change, enabling dynamic risk-based pricing. The portfolio summary layer could also feed an LLM-powered natural language analytics interface where executives ask "What is our California serious delinquency exposure trend this quarter?" and get instant answers.

---

### Q18. Explain your approach to handling late-arriving loan data and out-of-order servicer remittance files.

**Situation:** In the secondary mortgage market, servicer remittance data frequently arrives late or out of order. A servicer might submit February performance data before January corrections are finalized, or a loss mitigation event from 3 months ago gets reported retroactively after a loan modification review. Our data warehouse for Ginnie Mae HMBS (Home Equity Conversion Mortgage-Backed Securities) pools was producing incorrect pool factors and delinquency reports because late data overwrote current records without preserving temporal accuracy.

**Task:** Design an idempotent, temporally-aware ingestion framework that correctly handles late-arriving and out-of-order data, maintains accurate as-of-date reporting, and supports both "latest known state" and "as-reported-on-date" query patterns for regulatory compliance.

**Action:** I implemented a bitemporal data model with event-time and processing-time tracking:
```sql
-- Bitemporal loan performance table
CREATE TABLE curated.loan_performance_bitemporal (
  loan_number         VARCHAR(15),
  reporting_period    DATE,          -- business/event time
  received_date       DATE,          -- when we received this version
  current_upb         NUMBER(14,2),
  delinquency_status  VARCHAR(2),
  pool_id             VARCHAR(20),
  remittance_amount   NUMBER(14,2),
  _valid_from         TIMESTAMP_NTZ, -- system/processing time start
  _valid_to           TIMESTAMP_NTZ DEFAULT '9999-12-31'::TIMESTAMP_NTZ,
  _is_latest_version  BOOLEAN DEFAULT TRUE,
  _source_file        VARCHAR(500)
);

-- Late-arriving data handling: expire previous version, insert new
CREATE OR REPLACE PROCEDURE sp_upsert_loan_performance(p_source_table VARCHAR)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  -- Step 1: Mark existing records as superseded for affected loan+period combos
  UPDATE curated.loan_performance_bitemporal tgt
  SET _valid_to = CURRENT_TIMESTAMP(), _is_latest_version = FALSE
  WHERE EXISTS (
    SELECT 1 FROM IDENTIFIER(:p_source_table) src
    WHERE src.loan_number = tgt.loan_number
      AND src.reporting_period = tgt.reporting_period
  ) AND tgt._is_latest_version = TRUE;

  -- Step 2: Insert new versions (whether late, on-time, or corrected)
  INSERT INTO curated.loan_performance_bitemporal
  SELECT loan_number, reporting_period, received_date,
         current_upb, delinquency_status, pool_id, remittance_amount,
         CURRENT_TIMESTAMP(), '9999-12-31'::TIMESTAMP_NTZ, TRUE, source_file
  FROM IDENTIFIER(:p_source_table);

  RETURN 'Processed ' || SQLROWCOUNT || ' records';
END;
$$;

-- Query: "as-of" reporting date view for Ginnie Mae pool factor calculation
SELECT pool_id, reporting_period,
       SUM(current_upb) AS pool_current_upb,
       pool_current_upb / pool_original_upb AS pool_factor
FROM curated.loan_performance_bitemporal
WHERE _is_latest_version = TRUE          -- latest known state
  AND reporting_period = '2025-06-01'
GROUP BY pool_id, reporting_period;

-- Query: "as-reported-on" view for audit (what did we know on March 5th?)
SELECT * FROM curated.loan_performance_bitemporal
WHERE reporting_period = '2025-01-01'
  AND _valid_from <= '2025-03-05'::TIMESTAMP_NTZ
  AND _valid_to   >  '2025-03-05'::TIMESTAMP_NTZ;
```
I added a reconciliation Task that compared "latest known" pool factors against Ginnie Mae's published factors, flagging discrepancies > 0.01% for manual review. File-level metadata tracking ensured every record was traceable back to its source remittance file.

**Result:** Pool factor accuracy improved from 97.2% to 99.95% match against Ginnie Mae published values. Late-arriving data (affecting ~8% of monthly records) was now seamlessly incorporated without manual intervention. The "as-reported-on" capability satisfied OCC audit requirements and reduced audit preparation time from 2 weeks to 2 days. Zero restatements required over 12 months vs. 4 restatements the prior year.

**AI Vision:** A predictive model trained on historical late-arrival patterns could estimate expected data completeness at any point in the reporting cycle, giving portfolio managers a confidence score on current aggregates. An anomaly detector could flag late-arriving data that materially changes pool factors before it flows to investor reports.

---

### Q19. How did you design a multi-format data ingestion framework handling CSV loan tapes, JSON API feeds, and Parquet analytics files?

**Situation:** Our secondary market data platform ingested data from 20+ sources: CSV loan tapes from originators, JSON responses from Fannie Mae's API gateway (DU findings, UCDP appraisal data), Parquet files from internal risk model outputs, and XML from Freddie Mac's Loan Advisor Suite. Each format had different schemas, quality characteristics, and delivery cadences. The team maintained 40+ separate `COPY INTO` scripts, each with hardcoded paths and format definitions -- a maintenance nightmare where a single schema change required touching multiple scripts.

**Task:** Build a metadata-driven, format-agnostic ingestion framework that handles any file format through configuration rather than custom code, with built-in validation, lineage tracking, and error handling.

**Action:** I designed a configuration-driven framework using a metadata control table and parameterized stored procedures:
```sql
-- Metadata control table defining all ingestion sources
CREATE TABLE config.ingestion_registry (
  source_id         VARCHAR(50) PRIMARY KEY,
  source_name       VARCHAR(200),
  file_format_name  VARCHAR(100),   -- references named file format object
  stage_path        VARCHAR(500),
  target_schema     VARCHAR(50),
  target_table      VARCHAR(100),
  file_pattern      VARCHAR(200),
  load_frequency    VARCHAR(20),    -- 'CONTINUOUS','DAILY','MONTHLY'
  validation_rules  VARIANT,        -- JSON array of post-load checks
  is_active         BOOLEAN DEFAULT TRUE
);

-- Unified ingestion procedure
CREATE OR REPLACE PROCEDURE sp_ingest_source(p_source_id VARCHAR)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
  v_stage VARCHAR; v_format VARCHAR; v_target VARCHAR; v_pattern VARCHAR;
  v_rows_loaded INT; v_errors INT;
BEGIN
  -- Fetch config
  SELECT stage_path, file_format_name,
         target_schema || '.' || target_table, file_pattern
  INTO v_stage, v_format, v_target, v_pattern
  FROM config.ingestion_registry WHERE source_id = :p_source_id;

  -- Execute COPY INTO dynamically
  EXECUTE IMMEDIATE
    'COPY INTO ' || v_target ||
    ' FROM @' || v_stage ||
    ' FILE_FORMAT = (FORMAT_NAME = ' || v_format || ')' ||
    ' PATTERN = ''' || v_pattern || '''' ||
    ' ON_ERROR = SKIP_FILE_1%' ||
    ' FORCE = FALSE';

  -- Log results to audit table
  INSERT INTO audit.load_history (source_id, load_ts, rows_loaded, status)
  SELECT :p_source_id, CURRENT_TIMESTAMP(),
         rows_loaded, CASE WHEN errors_seen > 0 THEN 'PARTIAL' ELSE 'SUCCESS' END
  FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => v_target, START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
  ));

  RETURN OBJECT_CONSTRUCT('source', p_source_id, 'status', 'complete');
END;
$$;

-- Named file formats for each data type
CREATE FILE FORMAT ff_csv_loan_tape TYPE=CSV FIELD_DELIMITER='|'
  SKIP_HEADER=1 NULL_IF=('','NA','N/A') FIELD_OPTIONALLY_ENCLOSED_BY='"';
CREATE FILE FORMAT ff_json_api TYPE=JSON STRIP_OUTER_ARRAY=TRUE;
CREATE FILE FORMAT ff_parquet_analytics TYPE=PARQUET;

-- Example registry entries
INSERT INTO config.ingestion_registry VALUES
  ('FNMA_LOAN_TAPE','Fannie Mae Loan Tape','ff_csv_loan_tape',
   'stg_fnma/loan_tapes','raw','fannie_loan_tape','.*\\.csv\\.gz','MONTHLY',
   PARSE_JSON('[{"check":"row_count","min":1000000}]'), TRUE),
  ('DU_FINDINGS','DU API Findings','ff_json_api',
   'stg_fnma_api/du_findings','raw','du_findings_json','.*\\.json','DAILY',
   PARSE_JSON('[{"check":"not_empty"}]'), TRUE),
  ('RISK_SCORES','Model Risk Scores','ff_parquet_analytics',
   'stg_internal/risk_output','raw','risk_model_output','.*\\.parquet','DAILY',
   PARSE_JSON('[{"check":"schema_match"}]'), TRUE);
```
I added a master orchestrator Task that iterated through all active sources, invoked the procedure, and ran post-load validation rules defined in the JSON config. New sources were onboarded by inserting a row into the registry -- zero code changes required.

**Result:** Onboarding new data sources dropped from 2-3 days of development to 30 minutes of configuration. The framework managed 40+ sources reliably, processing 500M+ records/month. Maintenance effort decreased by 80%, freeing two engineers from ETL support to focus on analytics development. The audit table provided complete lineage for SOX compliance, tracing every record to its source file and load timestamp.

**AI Vision:** An intelligent schema inference engine using ML could auto-detect file formats, column types, and delimiter patterns for new sources, auto-populating the registry. An LLM-based mapping assistant could suggest column mappings between new source schemas and existing target tables by understanding semantic meaning (e.g., "unpaid_principal_balance" maps to "current_upb").

---

### Q20. Describe how you implemented recursive CTEs for modeling MBS waterfall payment distributions.

**Situation:** Our structured finance team needed to model payment waterfalls for non-agency RMBS deals where principal and interest distributions follow complex sequential and pro-rata rules across 15-30 tranches. Each payment period, available funds flow through a priority-of-payments (PoP) waterfall: senior fees first, then Class A interest, then Class A principal, then mezzanine tranches, with trigger tests determining whether principal shifts from sequential to pro-rata. The existing Excel-based waterfall models could only handle one deal at a time and took 20 minutes per run.

**Task:** Implement a SQL-based waterfall engine in Snowflake using recursive CTEs that could model payment distributions across all tranches for any deal structure, supporting scenario analysis (varying CPR/CDR/severity assumptions) and processing 500+ deals in a single batch run.

**Action:** I modeled the waterfall as a recursive CTE where each recursion level represented one priority step in the payment cascade:
```sql
-- Recursive CTE for sequential waterfall distribution
WITH RECURSIVE waterfall AS (
  -- Base case: total available funds for the period
  SELECT
    d.deal_id, d.period_date, d.period_num,
    1 AS priority_step,
    t.tranche_id, t.tranche_class, t.payment_priority,
    t.beginning_balance,
    d.total_available_funds           AS remaining_funds,
    -- Calculate interest due for this tranche
    t.beginning_balance * t.coupon_rate / 12  AS interest_due,
    LEAST(t.beginning_balance * t.coupon_rate / 12,
          d.total_available_funds)             AS interest_paid,
    0::NUMBER(18,2)                            AS principal_paid,
    d.total_available_funds
      - LEAST(t.beginning_balance * t.coupon_rate / 12,
              d.total_available_funds)         AS funds_after_step
  FROM analytics.deal_period_cashflows d
  JOIN analytics.tranche_schedule t
    ON d.deal_id = t.deal_id AND d.period_num = t.period_num
  WHERE t.payment_priority = 1   -- highest priority tranche

  UNION ALL

  -- Recursive step: pass remaining funds to next priority tranche
  SELECT
    w.deal_id, w.period_date, w.period_num,
    w.priority_step + 1,
    t.tranche_id, t.tranche_class, t.payment_priority,
    t.beginning_balance,
    w.funds_after_step                         AS remaining_funds,
    t.beginning_balance * t.coupon_rate / 12   AS interest_due,
    LEAST(t.beginning_balance * t.coupon_rate / 12,
          w.funds_after_step)                  AS interest_paid,
    -- Principal allocation after all interest is paid
    CASE WHEN t.receives_principal THEN
      LEAST(t.principal_allocation, GREATEST(w.funds_after_step
        - t.beginning_balance * t.coupon_rate / 12, 0))
    ELSE 0 END                                 AS principal_paid,
    w.funds_after_step
      - LEAST(t.beginning_balance * t.coupon_rate / 12, w.funds_after_step)
      - CASE WHEN t.receives_principal THEN
          LEAST(t.principal_allocation, GREATEST(w.funds_after_step
            - t.beginning_balance * t.coupon_rate / 12, 0))
        ELSE 0 END                             AS funds_after_step
  FROM waterfall w
  JOIN analytics.tranche_schedule t
    ON w.deal_id = t.deal_id AND w.period_num = t.period_num
    AND t.payment_priority = w.priority_step + 1
  WHERE w.funds_after_step > 0.01  -- stop when funds exhausted
    AND w.priority_step < 40       -- safety: max tranche depth
)
SELECT deal_id, period_date, tranche_id, tranche_class,
       payment_priority, beginning_balance,
       interest_due, interest_paid,
       interest_due - interest_paid           AS interest_shortfall,
       principal_paid,
       beginning_balance - principal_paid     AS ending_balance,
       remaining_funds, funds_after_step
FROM waterfall
ORDER BY deal_id, period_date, payment_priority;
```
I parameterized the model to accept CPR/CDR/severity assumptions as inputs, enabling the team to run 5+ scenarios per deal in a single query. For trigger-test logic (overcollateralization and interest coverage tests that shift payment rules), I added conditional logic in the recursive step that checked cumulative subordination levels.

**Result:** The SQL waterfall engine processed 500+ deals across 360 projection periods in 8 minutes on a Large warehouse -- replacing an overnight Excel batch that handled 50 deals. Scenario analysis that took analysts a full day (running deal-by-deal in Excel) was reduced to a parameterized query returning results in minutes. This directly supported a $1.5B non-agency RMBS trading strategy where rapid waterfall analysis on distressed deals identified tranches with asymmetric upside from faster-than-expected prepayments.

**AI Vision:** A neural network trained on historical deal performance could predict actual waterfall outcomes and identify structural features (trigger proximity, subordination erosion patterns) that indicate tranche-level mispricing. An LLM could parse deal indenture documents to auto-generate the priority-of-payments logic, replacing manual waterfall coding for new deal structures.

---
