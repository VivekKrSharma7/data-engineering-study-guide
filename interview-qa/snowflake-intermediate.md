# Snowflake - Intermediate Q&A (STAR Method)

[Back to Q&A Index](README.md)

---

25 intermediate questions with answers using the **STAR methodology** (Situation, Task, Action, Result) plus an **AI Vision** — real-world US secondary mortgage market examples.

---

### Q1. How do you use Streams to capture CDC on a loan performance table?

**Situation:** Fannie Mae's loan performance data in `MORTGAGE_DB.STAGING.LOAN_PERFORMANCE` receives daily bulk updates — roughly 30 million rows of payment status, delinquency codes, and current UPB. Downstream analytics teams need to process only changed records rather than re-scanning the entire table each day.

**Task:** Implement Change Data Capture (CDC) using Snowflake Streams so that incremental changes (inserts, updates, deletes) are captured automatically and consumed by downstream ETL processes without full-table scans.

**Action:**
First, create a standard stream on the loan performance table:

```sql
USE DATABASE MORTGAGE_DB;
USE SCHEMA ANALYTICS;

CREATE OR REPLACE STREAM LOAN_PERF_CDC_STREAM
  ON TABLE STAGING.LOAN_PERFORMANCE
  APPEND_ONLY = FALSE
  SHOW_INITIAL_ROWS = FALSE
  COMMENT = 'CDC stream for daily loan performance updates from Fannie Mae';
```

The stream tracks three metadata columns: `METADATA$ACTION` (INSERT/DELETE), `METADATA$ISUPDATE` (TRUE if the row is part of an update), and `METADATA$ROW_ID`. For updates, Snowflake emits a DELETE + INSERT pair with `METADATA$ISUPDATE = TRUE`.

Consume the stream in a downstream merge operation:

```sql
MERGE INTO ANALYTICS.LOAN_PERFORMANCE_CURRENT AS tgt
USING (
    SELECT
        LOAN_ID,
        REPORTING_PERIOD,
        CURRENT_UPB,
        DELINQUENCY_STATUS,
        LOAN_AGE,
        MOD_FLAG,
        METADATA$ACTION AS CDC_ACTION,
        METADATA$ISUPDATE AS CDC_IS_UPDATE
    FROM LOAN_PERF_CDC_STREAM
    WHERE METADATA$ACTION = 'INSERT'  -- captures inserts and the "new" side of updates
) AS src
ON tgt.LOAN_ID = src.LOAN_ID AND tgt.REPORTING_PERIOD = src.REPORTING_PERIOD
WHEN MATCHED THEN UPDATE SET
    tgt.CURRENT_UPB = src.CURRENT_UPB,
    tgt.DELINQUENCY_STATUS = src.DELINQUENCY_STATUS,
    tgt.LOAN_AGE = src.LOAN_AGE,
    tgt.MOD_FLAG = src.MOD_FLAG,
    tgt.LAST_UPDATED = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    LOAN_ID, REPORTING_PERIOD, CURRENT_UPB, DELINQUENCY_STATUS,
    LOAN_AGE, MOD_FLAG, LAST_UPDATED
) VALUES (
    src.LOAN_ID, src.REPORTING_PERIOD, src.CURRENT_UPB, src.DELINQUENCY_STATUS,
    src.LOAN_AGE, src.MOD_FLAG, CURRENT_TIMESTAMP()
);
```

Verify the stream is consumed (offset advances after a DML transaction commits):

```sql
SELECT SYSTEM$STREAM_HAS_DATA('LOAN_PERF_CDC_STREAM');
-- Returns FALSE after successful consumption
```

**Result:** Daily incremental processing dropped from 45 minutes (full-table scan of 30M rows) to under 3 minutes (processing only ~500K changed records). Warehouse credit consumption fell by 80% for the daily pipeline.

**AI Vision:** An ML anomaly detector could monitor stream volume and change patterns — flagging unusual spikes in delinquency status changes that might indicate a data quality issue or an emerging credit event in a specific loan cohort.

---

### Q2. How do you build task trees to automate a daily loan data pipeline?

**Situation:** Freddie Mac's daily loan-level data pipeline involves multiple sequential steps: ingest raw files, cleanse and validate, compute derived metrics (LTV ratios, DTI recalculations), update reporting tables, and refresh materialized views. Each step depends on the prior one completing successfully.

**Task:** Orchestrate a multi-step DAG using Snowflake Tasks with predecessor dependencies, error handling, and scheduling so the entire pipeline runs automatically at 6 AM ET daily.

**Action:**
Create the root task with a CRON schedule:

```sql
CREATE OR REPLACE TASK MORTGAGE_DB.PIPELINE.TASK_ROOT_DAILY_INGEST
  WAREHOUSE = ETL_WH_MEDIUM
  SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
  COMMENT = 'Root task: triggers daily Freddie Mac loan pipeline'
  ALLOW_OVERLAPPING_EXECUTION = FALSE
AS
  CALL PIPELINE.SP_INGEST_RAW_LOAN_FILES();
```

Create child tasks with predecessor chains:

```sql
-- Step 2: Cleanse and validate (depends on ingest)
CREATE OR REPLACE TASK MORTGAGE_DB.PIPELINE.TASK_CLEANSE_LOANS
  WAREHOUSE = ETL_WH_MEDIUM
  AFTER MORTGAGE_DB.PIPELINE.TASK_ROOT_DAILY_INGEST
AS
  CALL PIPELINE.SP_CLEANSE_LOAN_DATA();

-- Step 3: Compute derived metrics (depends on cleanse)
CREATE OR REPLACE TASK MORTGAGE_DB.PIPELINE.TASK_COMPUTE_METRICS
  WAREHOUSE = ETL_WH_LARGE
  AFTER MORTGAGE_DB.PIPELINE.TASK_CLEANSE_LOANS
AS
  CALL PIPELINE.SP_COMPUTE_LOAN_METRICS();

-- Step 4a: Update reporting tables (depends on metrics)
CREATE OR REPLACE TASK MORTGAGE_DB.PIPELINE.TASK_UPDATE_REPORTING
  WAREHOUSE = ETL_WH_MEDIUM
  AFTER MORTGAGE_DB.PIPELINE.TASK_COMPUTE_METRICS
AS
  CALL PIPELINE.SP_UPDATE_REPORTING_TABLES();

-- Step 4b: Refresh MV aggregations (also depends on metrics, runs in parallel with 4a)
CREATE OR REPLACE TASK MORTGAGE_DB.PIPELINE.TASK_REFRESH_AGGREGATIONS
  WAREHOUSE = ETL_WH_MEDIUM
  AFTER MORTGAGE_DB.PIPELINE.TASK_COMPUTE_METRICS
AS
  ALTER MATERIALIZED VIEW ANALYTICS.MV_POOL_SUMMARY REBUILD;
```

Add a finalizer task for error handling:

```sql
CREATE OR REPLACE TASK MORTGAGE_DB.PIPELINE.TASK_PIPELINE_FINALIZER
  WAREHOUSE = ETL_WH_SMALL
  FINALIZE = MORTGAGE_DB.PIPELINE.TASK_ROOT_DAILY_INGEST
AS
BEGIN
    LET root_state STRING := (SELECT SYSTEM$GET_PREDECESSOR_RETURN_VALUE(
        'MORTGAGE_DB.PIPELINE.TASK_ROOT_DAILY_INGEST'));
    IF (root_state = 'FAILED') THEN
        CALL PIPELINE.SP_SEND_ALERT('LOAN_PIPELINE_FAILURE', root_state);
    END IF;
END;
```

Resume all tasks (they are created in suspended state):

```sql
ALTER TASK MORTGAGE_DB.PIPELINE.TASK_PIPELINE_FINALIZER RESUME;
ALTER TASK MORTGAGE_DB.PIPELINE.TASK_REFRESH_AGGREGATIONS RESUME;
ALTER TASK MORTGAGE_DB.PIPELINE.TASK_UPDATE_REPORTING RESUME;
ALTER TASK MORTGAGE_DB.PIPELINE.TASK_COMPUTE_METRICS RESUME;
ALTER TASK MORTGAGE_DB.PIPELINE.TASK_CLEANSE_LOANS RESUME;
ALTER TASK MORTGAGE_DB.PIPELINE.TASK_ROOT_DAILY_INGEST RESUME;  -- root resumed LAST
```

Monitor task execution history:

```sql
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -24, CURRENT_TIMESTAMP()),
    TASK_NAME => 'TASK_ROOT_DAILY_INGEST'
))
ORDER BY SCHEDULED_TIME DESC;
```

**Result:** The five-step pipeline completes in 22 minutes end-to-end, runs reliably at 6 AM ET, and the finalizer task sends Slack alerts within 30 seconds of any failure. Manual orchestration effort dropped to zero.

**AI Vision:** A reinforcement learning agent could dynamically adjust warehouse sizes for each task based on observed data volumes and historical runtimes, minimizing credit cost while meeting SLA deadlines.

---

### Q3. How do you set up Snowpipe for continuous loading of real-time servicer feeds?

**Situation:** A mortgage servicer sends loan payment remittance files to an S3 bucket every 15 minutes as delimited CSV files. Ginnie Mae's analytics platform needs near-real-time visibility into payment receipt data for same-day reporting on Government National Mortgage Association pools.

**Task:** Configure Snowpipe for auto-ingest so that each new file landing in S3 is automatically loaded into `MORTGAGE_DB.RAW.SERVICER_REMITTANCE` within minutes, with no manual intervention or scheduled jobs.

**Action:**
Create the target table and file format:

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.RAW.SERVICER_REMITTANCE (
    POOL_ID             VARCHAR(20),
    LOAN_ID             VARCHAR(12),
    REMITTANCE_DATE     DATE,
    SCHEDULED_PAYMENT   NUMBER(14,2),
    PRINCIPAL_PAID      NUMBER(14,2),
    INTEREST_PAID       NUMBER(14,2),
    PREPAYMENT_AMOUNT   NUMBER(14,2),
    LOSS_AMOUNT         NUMBER(14,2),
    SERVICER_CODE       VARCHAR(10),
    FILE_NAME           VARCHAR(256),
    LOAD_TIMESTAMP      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE FILE FORMAT MORTGAGE_DB.RAW.CSV_REMITTANCE
    TYPE = 'CSV'
    FIELD_DELIMITER = '|'
    SKIP_HEADER = 1
    NULL_IF = ('', 'NULL', 'N/A')
    DATE_FORMAT = 'YYYY-MM-DD'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    TRIM_SPACE = TRUE;
```

Create the external stage pointing to S3:

```sql
CREATE OR REPLACE STAGE MORTGAGE_DB.RAW.STG_SERVICER_REMITTANCE
    URL = 's3://gnma-servicer-feeds/remittance/'
    STORAGE_INTEGRATION = GNMA_S3_INTEGRATION
    FILE_FORMAT = MORTGAGE_DB.RAW.CSV_REMITTANCE;
```

Create the Snowpipe with auto-ingest enabled:

```sql
CREATE OR REPLACE PIPE MORTGAGE_DB.RAW.PIPE_SERVICER_REMITTANCE
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-ingest pipe for GNMA servicer remittance feeds'
AS
COPY INTO MORTGAGE_DB.RAW.SERVICER_REMITTANCE (
    POOL_ID, LOAN_ID, REMITTANCE_DATE, SCHEDULED_PAYMENT,
    PRINCIPAL_PAID, INTEREST_PAID, PREPAYMENT_AMOUNT,
    LOSS_AMOUNT, SERVICER_CODE, FILE_NAME
)
FROM (
    SELECT
        $1, $2, $3, $4, $5, $6, $7, $8, $9,
        METADATA$FILENAME
    FROM @MORTGAGE_DB.RAW.STG_SERVICER_REMITTANCE
);
```

Retrieve the SQS ARN for the S3 event notification setup:

```sql
SELECT SYSTEM$PIPE_STATUS('MORTGAGE_DB.RAW.PIPE_SERVICER_REMITTANCE');
SHOW PIPES LIKE 'PIPE_SERVICER_REMITTANCE';
-- Use the notification_channel column value to configure S3 -> SQS event notification
```

Monitor pipe load history:

```sql
SELECT FILE_NAME, PIPE_RECEIVED_TIME, FIRST_COMMIT_TIME, ROW_COUNT, ERROR_COUNT
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SERVICER_REMITTANCE',
    START_TIME => DATEADD(HOUR, -6, CURRENT_TIMESTAMP())
))
ORDER BY PIPE_RECEIVED_TIME DESC;
```

**Result:** Remittance files are loaded within 2-3 minutes of landing in S3. The pipeline processes approximately 200 files per day with zero manual intervention. Data freshness improved from T+1 batch to near-real-time, enabling same-day pool factor reporting.

**AI Vision:** An NLP model could parse unstructured servicer commentary that sometimes accompanies remittance files, extracting loss mitigation notes and modification details to enrich the structured payment data automatically.

---

### Q4. How do you use clustering keys to optimize queries on loan origination date?

**Situation:** The `MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION` table contains 500 million rows of Fannie Mae and Freddie Mac origination data spanning 25 years. Analysts frequently query by `ORIGINATION_DATE` range and `PROPERTY_STATE`, but queries take 8+ minutes because micro-partitions are naturally ordered by load time, not business date.

**Task:** Define clustering keys to physically co-locate data by the most frequently filtered columns, reducing scan volume and query runtime for origination date range and geographic queries.

**Action:**
Analyze current clustering depth before making changes:

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION',
    '(ORIGINATION_DATE, PROPERTY_STATE)'
);
```

The output shows a high `average_overlap` (e.g., 12.5) and low `average_depth` is poor, meaning partitions are not well-organized by these columns.

Define the clustering key:

```sql
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION
  CLUSTER BY (DATE_TRUNC('MONTH', ORIGINATION_DATE), PROPERTY_STATE);
```

Using `DATE_TRUNC('MONTH', ...)` rather than the raw date reduces cardinality from ~9,000 distinct dates to ~300 months, which produces better clustering. Snowflake's Automatic Clustering service (serverless) will reorganize micro-partitions in the background.

Monitor reclustering progress:

```sql
-- Check clustering status over time
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION',
    '(DATE_TRUNC(MONTH, ORIGINATION_DATE), PROPERTY_STATE)'
);

-- Monitor Automatic Clustering credit usage
SELECT *
FROM TABLE(INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY(
    DATE_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP()),
    TABLE_NAME => 'MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION'
))
ORDER BY START_TIME DESC;
```

Validate performance with a typical analyst query:

```sql
SELECT
    PROPERTY_STATE,
    COUNT(*) AS LOAN_COUNT,
    SUM(ORIGINAL_UPB) AS TOTAL_UPB,
    AVG(ORIGINAL_INTEREST_RATE) AS AVG_RATE,
    AVG(ORIGINAL_LTV) AS AVG_LTV
FROM MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION
WHERE ORIGINATION_DATE BETWEEN '2023-01-01' AND '2023-12-31'
  AND PROPERTY_STATE IN ('CA', 'TX', 'FL', 'NY')
GROUP BY PROPERTY_STATE;
```

**Result:** After automatic reclustering completed (approximately 48 hours for the full table), the query scan dropped from 500M rows to 8M rows — a 98% pruning rate. Average query time dropped from 8 minutes to 12 seconds. Automatic clustering costs approximately 2.5 credits/day for ongoing maintenance.

**AI Vision:** A workload analysis model could continuously evaluate query logs, recommend optimal clustering keys as query patterns evolve, and predict the cost-benefit ratio of reclustering before committing to changes.

---

### Q5. How do you use Search Optimization Service to accelerate CUSIP lookups?

**Situation:** Traders and risk analysts at a Freddie Mac CMBS desk perform thousands of point lookups daily on `MORTGAGE_DB.SECURITIES.MBS_DEALS` searching by CUSIP (a 9-character identifier for each mortgage-backed security tranche). The table has 2 billion rows across 15 years of deal data. Even with clustering on deal date, CUSIP lookups still scan heavily.

**Task:** Enable the Search Optimization Service (SOS) on the CUSIP column to build a secondary search access path, reducing point-lookup query latency from minutes to seconds.

**Action:**
Enable Search Optimization on the table for the CUSIP column:

```sql
ALTER TABLE MORTGAGE_DB.SECURITIES.MBS_DEALS
  ADD SEARCH OPTIMIZATION
  ON EQUALITY(CUSIP);
```

You can also add search optimization for substring searches if traders search by partial CUSIPs:

```sql
ALTER TABLE MORTGAGE_DB.SECURITIES.MBS_DEALS
  ADD SEARCH OPTIMIZATION
  ON SUBSTRING(CUSIP),
  ON EQUALITY(DEAL_NAME),
  ON EQUALITY(TRANCHE_ID);
```

Monitor the SOS build progress:

```sql
SHOW TABLES LIKE 'MBS_DEALS' IN SCHEMA MORTGAGE_DB.SECURITIES;
-- Check the search_optimization_progress column (0-100%)

SELECT *
FROM TABLE(INFORMATION_SCHEMA.SEARCH_OPTIMIZATION_HISTORY(
    DATE_RANGE_START => DATEADD(DAY, -1, CURRENT_TIMESTAMP()),
    TABLE_NAME => 'MORTGAGE_DB.SECURITIES.MBS_DEALS'
));
```

Test a typical CUSIP lookup query:

```sql
SELECT
    CUSIP,
    DEAL_NAME,
    TRANCHE_ID,
    ORIGINAL_BALANCE,
    CURRENT_BALANCE,
    COUPON_RATE,
    MATURITY_DATE,
    CREDIT_RATING,
    WAL_YEARS
FROM MORTGAGE_DB.SECURITIES.MBS_DEALS
WHERE CUSIP = '31329QAC3';
```

Check that the query profile shows "search optimization access" rather than full table scan:

```sql
-- After running the query, inspect the query profile in Snowsight
-- Look for the "Search Optimization Access" node in the plan
SELECT QUERY_ID, PARTITIONS_SCANNED, PARTITIONS_TOTAL, BYTES_SCANNED
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE QUERY_TEXT ILIKE '%31329QAC3%'
ORDER BY START_TIME DESC
LIMIT 1;
```

**Result:** CUSIP point lookups dropped from 45 seconds (scanning 120K partitions) to under 500 milliseconds (scanning 2-3 partitions). SOS maintenance cost runs approximately 1.8 credits/day, which is justified by thousands of daily lookups. Trader workflow latency improved dramatically.

**AI Vision:** A recommendation engine could analyze query patterns across the trading desk and automatically suggest which columns should have search optimization enabled, balancing lookup frequency against maintenance cost.

---

### Q6. How do you create materialized views to pre-compute pool aggregations?

**Situation:** Ginnie Mae pool-level reporting requires aggregating loan-level data from `MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE` — computing metrics like total UPB, weighted-average coupon (WAC), weighted-average maturity (WAM), and delinquency percentages per pool. Analysts run these aggregations hundreds of times daily, each time scanning 200 million loan rows.

**Task:** Create materialized views that pre-compute pool-level aggregations and are automatically maintained by Snowflake as the underlying loan data changes, eliminating redundant aggregation scans.

**Action:**
Create the materialized view for pool-level summary:

```sql
CREATE OR REPLACE MATERIALIZED VIEW MORTGAGE_DB.ANALYTICS.MV_GNMA_POOL_SUMMARY
  CLUSTER BY (POOL_ID)
  COMMENT = 'Pre-computed GNMA pool-level aggregations refreshed automatically'
AS
SELECT
    POOL_ID,
    REPORTING_PERIOD,
    COUNT(*)                                         AS LOAN_COUNT,
    SUM(CURRENT_UPB)                                 AS TOTAL_UPB,
    SUM(CURRENT_UPB * INTEREST_RATE)
        / NULLIF(SUM(CURRENT_UPB), 0)               AS WAC,
    SUM(CURRENT_UPB * REMAINING_MONTHS)
        / NULLIF(SUM(CURRENT_UPB), 0)               AS WAM,
    SUM(CASE WHEN DELINQUENCY_STATUS = '0'
        THEN CURRENT_UPB ELSE 0 END)
        / NULLIF(SUM(CURRENT_UPB), 0) * 100         AS PCT_CURRENT,
    SUM(CASE WHEN DELINQUENCY_STATUS IN ('1','2','3')
        THEN CURRENT_UPB ELSE 0 END)
        / NULLIF(SUM(CURRENT_UPB), 0) * 100         AS PCT_DQ_30_90,
    SUM(CASE WHEN CAST(DELINQUENCY_STATUS AS INT) > 3
        THEN CURRENT_UPB ELSE 0 END)
        / NULLIF(SUM(CURRENT_UPB), 0) * 100         AS PCT_SERIOUSLY_DQ,
    SUM(CASE WHEN ZERO_BALANCE_CODE IS NOT NULL
        THEN 1 ELSE 0 END)                          AS LIQUIDATION_COUNT
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE
GROUP BY POOL_ID, REPORTING_PERIOD;
```

Verify the MV is being maintained:

```sql
SHOW MATERIALIZED VIEWS LIKE 'MV_GNMA_POOL_SUMMARY'
  IN SCHEMA MORTGAGE_DB.ANALYTICS;
-- Check is_up_to_date column and behind_by_bytes

SELECT *
FROM TABLE(INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY(
    DATE_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP()),
    TABLE_NAME => 'MV_GNMA_POOL_SUMMARY'
));
```

Analysts now query the MV directly:

```sql
SELECT *
FROM MORTGAGE_DB.ANALYTICS.MV_GNMA_POOL_SUMMARY
WHERE POOL_ID = 'MA8675'
  AND REPORTING_PERIOD >= '2025-01-01'
ORDER BY REPORTING_PERIOD;
```

**Result:** Pool-level queries that previously scanned 200M rows in 3 minutes now return in under 1 second from the pre-computed MV. The MV refresh is serverless and costs approximately 1.2 credits/day. Analyst productivity increased measurably with interactive-speed responses.

**AI Vision:** A forecasting model could use the MV aggregation data to predict pool-level prepayment speeds and delinquency trajectories, updating predictions automatically each time the MV refreshes with new monthly data.

---

### Q7. How do you use Dynamic Tables to build incremental loan analytics?

**Situation:** Freddie Mac's analytics team needs a multi-layer data pipeline: raw loan data flows to cleansed data, then to enriched loan-level analytics, and finally to portfolio summary tables. Traditional ETL with tasks and streams requires significant orchestration code and manual dependency management.

**Task:** Replace the task-based pipeline with Dynamic Tables that declaratively define transformations and let Snowflake manage incremental refresh, scheduling, and dependency ordering automatically.

**Action:**
Create the first dynamic table layer — cleansed loans:

```sql
CREATE OR REPLACE DYNAMIC TABLE MORTGAGE_DB.ANALYTICS.DT_LOANS_CLEANSED
  TARGET_LAG = '15 minutes'
  WAREHOUSE = TRANSFORM_WH
AS
SELECT
    LOAN_ID,
    TRIM(SELLER_NAME)                           AS SELLER_NAME,
    CAST(ORIGINATION_DATE AS DATE)              AS ORIGINATION_DATE,
    CAST(ORIGINAL_UPB AS NUMBER(14,2))          AS ORIGINAL_UPB,
    COALESCE(ORIGINAL_LTV, 0)                   AS ORIGINAL_LTV,
    COALESCE(ORIGINAL_CLTV, ORIGINAL_LTV, 0)   AS ORIGINAL_CLTV,
    NULLIF(BORROWER_CREDIT_SCORE, 9999)         AS CREDIT_SCORE,
    UPPER(PROPERTY_STATE)                       AS PROPERTY_STATE,
    PROPERTY_TYPE,
    LOAN_PURPOSE,
    REPORTING_PERIOD,
    CURRENT_UPB,
    DELINQUENCY_STATUS,
    INTEREST_RATE
FROM MORTGAGE_DB.RAW.LOAN_PERFORMANCE_RAW
WHERE LOAN_ID IS NOT NULL
  AND ORIGINAL_UPB > 0;
```

Create the second layer — enriched analytics:

```sql
CREATE OR REPLACE DYNAMIC TABLE MORTGAGE_DB.ANALYTICS.DT_LOAN_ENRICHED
  TARGET_LAG = '30 minutes'
  WAREHOUSE = TRANSFORM_WH
AS
SELECT
    l.*,
    l.CURRENT_UPB / NULLIF(l.ORIGINAL_UPB, 0)       AS PAYDOWN_FACTOR,
    DATEDIFF('MONTH', l.ORIGINATION_DATE,
             l.REPORTING_PERIOD)                      AS LOAN_AGE_MONTHS,
    CASE
        WHEN l.DELINQUENCY_STATUS = '0' THEN 'Current'
        WHEN l.DELINQUENCY_STATUS IN ('1','2') THEN 'Early DQ'
        WHEN l.DELINQUENCY_STATUS IN ('3','4','5','6') THEN 'Serious DQ'
        ELSE 'Default/REO'
    END                                               AS DQ_BUCKET,
    z.MEDIAN_HOME_VALUE,
    z.UNEMPLOYMENT_RATE
FROM MORTGAGE_DB.ANALYTICS.DT_LOANS_CLEANSED l
LEFT JOIN MORTGAGE_DB.REFERENCE.ZIP_ECONOMICS z
    ON l.PROPERTY_ZIP = z.ZIP_CODE
    AND l.REPORTING_PERIOD = z.AS_OF_DATE;
```

Create the third layer — portfolio summary:

```sql
CREATE OR REPLACE DYNAMIC TABLE MORTGAGE_DB.ANALYTICS.DT_PORTFOLIO_SUMMARY
  TARGET_LAG = '1 hour'
  WAREHOUSE = TRANSFORM_WH
AS
SELECT
    REPORTING_PERIOD,
    SELLER_NAME,
    PROPERTY_STATE,
    DQ_BUCKET,
    COUNT(*)                         AS LOAN_COUNT,
    SUM(CURRENT_UPB)                 AS TOTAL_UPB,
    AVG(CREDIT_SCORE)                AS AVG_CREDIT_SCORE,
    AVG(ORIGINAL_LTV)                AS AVG_LTV,
    AVG(PAYDOWN_FACTOR)              AS AVG_PAYDOWN_FACTOR
FROM MORTGAGE_DB.ANALYTICS.DT_LOAN_ENRICHED
GROUP BY REPORTING_PERIOD, SELLER_NAME, PROPERTY_STATE, DQ_BUCKET;
```

Monitor the dynamic table pipeline:

```sql
SELECT NAME, TARGET_LAG, SCHEDULING_STATE, LAST_COMPLETED_REFRESH,
       DATA_TIMESTAMP, REFRESH_MODE
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME_PREFIX => 'MORTGAGE_DB.ANALYTICS.DT_'
))
ORDER BY DATA_TIMESTAMP DESC;
```

**Result:** The three-layer pipeline replaced 12 tasks, 3 streams, and 300+ lines of orchestration SQL. Target lag guarantees ensure the portfolio summary is never more than 1 hour behind raw data. Pipeline maintenance effort dropped by 70%.

**AI Vision:** An intelligent optimizer could learn from refresh patterns and dynamically adjust `TARGET_LAG` per table — tightening lag during trading hours when analysts need fresher data and relaxing it overnight to save compute credits.

---

### Q8. How do you use FLATTEN to parse nested JSON deal structures from Intex?

**Situation:** Intex delivers mortgage-backed security deal structures as deeply nested JSON files into `MORTGAGE_DB.RAW.INTEX_DEAL_JSON`. Each deal contains nested arrays of tranches, each tranche has nested waterfall rules, and each waterfall rule has nested payment priorities. The raw VARIANT column needs to be relationalized for analytics.

**Task:** Use Snowflake's FLATTEN function to explode nested JSON arrays into relational rows, extracting deal, tranche, and waterfall rule data for the structured analytics tables.

**Action:**
First inspect the JSON structure:

```sql
SELECT
    RAW_JSON:dealName::STRING AS DEAL_NAME,
    RAW_JSON:dealDate::DATE AS DEAL_DATE,
    RAW_JSON:issuer::STRING AS ISSUER,
    RAW_JSON:totalBalance::NUMBER(14,2) AS TOTAL_BALANCE,
    ARRAY_SIZE(RAW_JSON:tranches) AS TRANCHE_COUNT
FROM MORTGAGE_DB.RAW.INTEX_DEAL_JSON
WHERE RAW_JSON:dealName::STRING = 'FHLMC_2025-K156'
LIMIT 1;
```

Flatten tranches (first level):

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.ANALYTICS.DEAL_TRANCHES AS
SELECT
    d.RAW_JSON:dealName::STRING                    AS DEAL_NAME,
    d.RAW_JSON:dealDate::DATE                      AS DEAL_DATE,
    d.RAW_JSON:issuer::STRING                      AS ISSUER,
    t.INDEX                                         AS TRANCHE_SEQ,
    t.VALUE:trancheId::STRING                      AS TRANCHE_ID,
    t.VALUE:cusip::STRING                          AS CUSIP,
    t.VALUE:className::STRING                      AS CLASS_NAME,
    t.VALUE:originalBalance::NUMBER(14,2)          AS ORIGINAL_BALANCE,
    t.VALUE:couponRate::NUMBER(8,6)                AS COUPON_RATE,
    t.VALUE:couponType::STRING                     AS COUPON_TYPE,
    t.VALUE:maturityDate::DATE                     AS MATURITY_DATE,
    t.VALUE:creditRating::STRING                   AS CREDIT_RATING,
    t.VALUE:subordination::NUMBER(8,4)             AS SUBORDINATION_PCT,
    ARRAY_SIZE(t.VALUE:waterfallRules)             AS RULE_COUNT
FROM MORTGAGE_DB.RAW.INTEX_DEAL_JSON d,
    LATERAL FLATTEN(INPUT => d.RAW_JSON:tranches) t;
```

Flatten waterfall rules (second level, nested within tranches):

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.ANALYTICS.DEAL_WATERFALL AS
SELECT
    d.RAW_JSON:dealName::STRING                     AS DEAL_NAME,
    t.VALUE:trancheId::STRING                       AS TRANCHE_ID,
    t.VALUE:cusip::STRING                           AS CUSIP,
    w.INDEX                                          AS RULE_SEQ,
    w.VALUE:ruleType::STRING                        AS RULE_TYPE,
    w.VALUE:priority::INT                           AS PRIORITY,
    w.VALUE:paymentType::STRING                     AS PAYMENT_TYPE,
    w.VALUE:capRate::NUMBER(8,6)                    AS CAP_RATE,
    w.VALUE:floorRate::NUMBER(8,6)                  AS FLOOR_RATE,
    w.VALUE:triggerEvent::STRING                    AS TRIGGER_EVENT,
    w.VALUE:allocationPct::NUMBER(8,4)             AS ALLOCATION_PCT
FROM MORTGAGE_DB.RAW.INTEX_DEAL_JSON d,
    LATERAL FLATTEN(INPUT => d.RAW_JSON:tranches) t,
    LATERAL FLATTEN(INPUT => t.VALUE:waterfallRules) w;
```

Handle optional nested arrays safely with OUTER FLATTEN:

```sql
SELECT
    d.RAW_JSON:dealName::STRING AS DEAL_NAME,
    t.VALUE:trancheId::STRING AS TRANCHE_ID,
    ce.VALUE:eventType::STRING AS CREDIT_EVENT_TYPE,
    ce.VALUE:threshold::NUMBER(8,4) AS THRESHOLD
FROM MORTGAGE_DB.RAW.INTEX_DEAL_JSON d,
    LATERAL FLATTEN(INPUT => d.RAW_JSON:tranches) t,
    LATERAL FLATTEN(INPUT => t.VALUE:creditEvents, OUTER => TRUE) ce;
```

**Result:** Successfully parsed 15,000 Intex deal files containing 180,000 tranches and 2.1 million waterfall rules into clean relational tables. Analysts can now query deal structures with standard SQL JOINs. JSON parsing time averages 4 minutes for the full corpus.

**AI Vision:** A graph neural network could model the complex waterfall payment dependencies as a directed graph, enabling rapid simulation of cash flow paths under stress scenarios without re-parsing the raw JSON.

---

### Q9. How do you use MERGE for SCD Type 2 to maintain loan status history?

**Situation:** Fannie Mae loan servicing data arrives monthly. When a loan's status changes (e.g., from Current to 30 Days Delinquent, or from Active to Modified), the analytics team needs to preserve the full history of each state transition with effective dates — a Slowly Changing Dimension Type 2 pattern.

**Task:** Implement SCD Type 2 using Snowflake's MERGE statement to close out old records and insert new ones whenever a loan's key attributes change, maintaining a complete audit trail.

**Action:**
Define the SCD Type 2 dimension table:

```sql
CREATE TABLE IF NOT EXISTS MORTGAGE_DB.ANALYTICS.DIM_LOAN_STATUS_HIST (
    LOAN_STATUS_SK        NUMBER AUTOINCREMENT,
    LOAN_ID               VARCHAR(12),
    DELINQUENCY_STATUS    VARCHAR(2),
    LOAN_STATUS           VARCHAR(20),
    SERVICER_NAME         VARCHAR(100),
    INTEREST_RATE         NUMBER(8,6),
    CURRENT_UPB           NUMBER(14,2),
    EFFECTIVE_DATE        DATE,
    END_DATE              DATE DEFAULT '9999-12-31',
    IS_CURRENT            BOOLEAN DEFAULT TRUE,
    RECORD_HASH           VARCHAR(64)
);
```

Execute the MERGE with hash-based change detection:

```sql
MERGE INTO MORTGAGE_DB.ANALYTICS.DIM_LOAN_STATUS_HIST AS tgt
USING (
    SELECT
        LOAN_ID,
        DELINQUENCY_STATUS,
        LOAN_STATUS,
        SERVICER_NAME,
        INTEREST_RATE,
        CURRENT_UPB,
        REPORTING_PERIOD AS EFFECTIVE_DATE,
        SHA2(CONCAT(
            COALESCE(DELINQUENCY_STATUS, ''),
            COALESCE(LOAN_STATUS, ''),
            COALESCE(SERVICER_NAME, ''),
            COALESCE(TO_VARCHAR(INTEREST_RATE), ''),
            COALESCE(TO_VARCHAR(CURRENT_UPB), '')
        ), 256) AS RECORD_HASH
    FROM MORTGAGE_DB.STAGING.MONTHLY_LOAN_UPDATE
) AS src
ON tgt.LOAN_ID = src.LOAN_ID AND tgt.IS_CURRENT = TRUE

-- Case 1: Existing current record whose attributes have changed -> close it out
WHEN MATCHED AND tgt.RECORD_HASH != src.RECORD_HASH THEN
    UPDATE SET
        tgt.END_DATE = DATEADD(DAY, -1, src.EFFECTIVE_DATE),
        tgt.IS_CURRENT = FALSE

-- Case 2: No current record exists -> insert new record
WHEN NOT MATCHED THEN
    INSERT (LOAN_ID, DELINQUENCY_STATUS, LOAN_STATUS, SERVICER_NAME,
            INTEREST_RATE, CURRENT_UPB, EFFECTIVE_DATE, END_DATE,
            IS_CURRENT, RECORD_HASH)
    VALUES (src.LOAN_ID, src.DELINQUENCY_STATUS, src.LOAN_STATUS,
            src.SERVICER_NAME, src.INTEREST_RATE, src.CURRENT_UPB,
            src.EFFECTIVE_DATE, '9999-12-31', TRUE, src.RECORD_HASH);
```

Since MERGE cannot both UPDATE and INSERT for the same matched row, insert the new version in a separate step:

```sql
INSERT INTO MORTGAGE_DB.ANALYTICS.DIM_LOAN_STATUS_HIST (
    LOAN_ID, DELINQUENCY_STATUS, LOAN_STATUS, SERVICER_NAME,
    INTEREST_RATE, CURRENT_UPB, EFFECTIVE_DATE, END_DATE,
    IS_CURRENT, RECORD_HASH
)
SELECT
    src.LOAN_ID, src.DELINQUENCY_STATUS, src.LOAN_STATUS,
    src.SERVICER_NAME, src.INTEREST_RATE, src.CURRENT_UPB,
    src.EFFECTIVE_DATE, '9999-12-31', TRUE, src.RECORD_HASH
FROM MORTGAGE_DB.STAGING.MONTHLY_LOAN_UPDATE src
JOIN MORTGAGE_DB.ANALYTICS.DIM_LOAN_STATUS_HIST tgt
    ON src.LOAN_ID = tgt.LOAN_ID
    AND tgt.END_DATE = DATEADD(DAY, -1, src.EFFECTIVE_DATE)
    AND tgt.IS_CURRENT = FALSE
WHERE SHA2(CONCAT(
        COALESCE(src.DELINQUENCY_STATUS, ''),
        COALESCE(src.LOAN_STATUS, ''),
        COALESCE(src.SERVICER_NAME, ''),
        COALESCE(TO_VARCHAR(src.INTEREST_RATE), ''),
        COALESCE(TO_VARCHAR(src.CURRENT_UPB), '')
    ), 256) != tgt.RECORD_HASH;
```

Query the history for a specific loan:

```sql
SELECT *
FROM MORTGAGE_DB.ANALYTICS.DIM_LOAN_STATUS_HIST
WHERE LOAN_ID = 'F30Q12345678'
ORDER BY EFFECTIVE_DATE;
```

**Result:** The SCD Type 2 dimension now tracks 18 months of status transitions for 12 million active loans, totaling 85 million historical records. Auditors can reconstruct the exact state of any loan at any point in time. The monthly MERGE + INSERT completes in 8 minutes.

**AI Vision:** A transition-probability model trained on the SCD history could predict the likelihood of a loan moving from 30-day DQ to 60-day DQ vs. curing back to current, feeding early-warning dashboards for portfolio managers.

---

### Q10. How do you build a stored procedure for a monthly waterfall calculator?

**Situation:** Freddie Mac structured deals distribute monthly cash flows through a waterfall — principal and interest are allocated to tranches in priority order based on deal rules. The calculation must process each tranche sequentially, applying triggers and coverage tests that depend on prior tranche allocations.

**Task:** Create a Snowflake stored procedure in SQL that executes the monthly waterfall calculation for a given deal, allocating cash flows to each tranche according to the priority structure stored in `MORTGAGE_DB.ANALYTICS.DEAL_WATERFALL`.

**Action:**
Create the stored procedure using Snowflake Scripting (SQL):

```sql
CREATE OR REPLACE PROCEDURE MORTGAGE_DB.ANALYTICS.SP_CALCULATE_WATERFALL(
    P_DEAL_NAME VARCHAR,
    P_REPORTING_PERIOD DATE
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_total_principal NUMBER(14,2);
    v_total_interest NUMBER(14,2);
    v_remaining_principal NUMBER(14,2);
    v_remaining_interest NUMBER(14,2);
    v_tranche_id VARCHAR;
    v_priority INT;
    v_payment_type VARCHAR;
    v_allocation_pct NUMBER(8,4);
    v_tranche_balance NUMBER(14,2);
    v_allocated_amount NUMBER(14,2);

    c_waterfall CURSOR FOR
        SELECT TRANCHE_ID, PRIORITY, PAYMENT_TYPE, ALLOCATION_PCT
        FROM MORTGAGE_DB.ANALYTICS.DEAL_WATERFALL
        WHERE DEAL_NAME = :P_DEAL_NAME
        ORDER BY PRIORITY ASC;
BEGIN
    -- Get total available cash from collateral pool
    SELECT SUM(PRINCIPAL_COLLECTED), SUM(INTEREST_COLLECTED)
    INTO :v_total_principal, :v_total_interest
    FROM MORTGAGE_DB.ANALYTICS.POOL_COLLECTIONS
    WHERE DEAL_NAME = :P_DEAL_NAME
      AND REPORTING_PERIOD = :P_REPORTING_PERIOD;

    v_remaining_principal := v_total_principal;
    v_remaining_interest := v_total_interest;

    -- Clean prior results for this period
    DELETE FROM MORTGAGE_DB.ANALYTICS.WATERFALL_RESULTS
    WHERE DEAL_NAME = :P_DEAL_NAME
      AND REPORTING_PERIOD = :P_REPORTING_PERIOD;

    -- Iterate through waterfall rules in priority order
    OPEN c_waterfall;
    FOR record IN c_waterfall DO
        v_tranche_id := record.TRANCHE_ID;
        v_priority := record.PRIORITY;
        v_payment_type := record.PAYMENT_TYPE;
        v_allocation_pct := record.ALLOCATION_PCT;

        -- Get current tranche balance
        SELECT CURRENT_BALANCE INTO :v_tranche_balance
        FROM MORTGAGE_DB.ANALYTICS.TRANCHE_BALANCES
        WHERE DEAL_NAME = :P_DEAL_NAME
          AND TRANCHE_ID = :v_tranche_id;

        -- Calculate allocation based on payment type
        IF (v_payment_type = 'INTEREST') THEN
            v_allocated_amount := LEAST(
                v_remaining_interest * v_allocation_pct,
                v_tranche_balance * 0.05 / 12  -- monthly coupon cap
            );
            v_remaining_interest := v_remaining_interest - v_allocated_amount;
        ELSEIF (v_payment_type = 'PRINCIPAL') THEN
            v_allocated_amount := LEAST(
                v_remaining_principal * v_allocation_pct,
                v_tranche_balance
            );
            v_remaining_principal := v_remaining_principal - v_allocated_amount;
        END IF;

        -- Record the allocation
        INSERT INTO MORTGAGE_DB.ANALYTICS.WATERFALL_RESULTS (
            DEAL_NAME, REPORTING_PERIOD, TRANCHE_ID, PRIORITY,
            PAYMENT_TYPE, ALLOCATED_AMOUNT, REMAINING_PRINCIPAL,
            REMAINING_INTEREST, CALCULATED_AT
        ) VALUES (
            :P_DEAL_NAME, :P_REPORTING_PERIOD, :v_tranche_id, :v_priority,
            :v_payment_type, :v_allocated_amount, :v_remaining_principal,
            :v_remaining_interest, CURRENT_TIMESTAMP()
        );
    END FOR;
    CLOSE c_waterfall;

    RETURN 'Waterfall calculated for ' || P_DEAL_NAME || ' period ' || P_REPORTING_PERIOD::VARCHAR;
END;
$$;
```

Execute the waterfall:

```sql
CALL MORTGAGE_DB.ANALYTICS.SP_CALCULATE_WATERFALL('FHLMC_2025-K156', '2025-06-01');

-- View results
SELECT * FROM MORTGAGE_DB.ANALYTICS.WATERFALL_RESULTS
WHERE DEAL_NAME = 'FHLMC_2025-K156'
  AND REPORTING_PERIOD = '2025-06-01'
ORDER BY PRIORITY;
```

**Result:** The stored procedure processes a 15-tranche deal waterfall in under 2 seconds. Running across 500 active deals for month-end takes 12 minutes. Previously, this was done in Excel and took an analyst 2 full days.

**AI Vision:** A Monte Carlo simulation engine powered by ML-predicted prepayment and default vectors could call this waterfall procedure thousands of times with different scenarios, generating probabilistic cash flow distributions for OAS pricing.

---

### Q11. How do you create UDFs for CPR/SMM conversion?

**Situation:** Mortgage analytics requires constant conversion between Conditional Prepayment Rate (CPR, annual) and Single Monthly Mortality (SMM, monthly). Analysts frequently make errors computing this by hand, and the formula appears in dozens of queries across the Fannie Mae analytics platform.

**Task:** Create reusable scalar UDFs for CPR-to-SMM and SMM-to-CPR conversions, plus a UDF that computes CPR from actual prepayment data, standardizing the calculation across all queries.

**Action:**
Create the CPR to SMM conversion UDF:

```sql
CREATE OR REPLACE FUNCTION MORTGAGE_DB.ANALYTICS.CPR_TO_SMM(CPR_ANNUAL FLOAT)
RETURNS FLOAT
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Converts annual CPR to monthly SMM. Formula: SMM = 1 - (1 - CPR)^(1/12)'
AS
$$
    CASE
        WHEN CPR_ANNUAL IS NULL THEN NULL
        WHEN CPR_ANNUAL < 0 OR CPR_ANNUAL > 1 THEN NULL
        ELSE 1.0 - POWER(1.0 - CPR_ANNUAL, 1.0/12.0)
    END
$$;
```

Create the SMM to CPR conversion UDF:

```sql
CREATE OR REPLACE FUNCTION MORTGAGE_DB.ANALYTICS.SMM_TO_CPR(SMM_MONTHLY FLOAT)
RETURNS FLOAT
LANGUAGE SQL
IMMUTABLE
COMMENT = 'Converts monthly SMM to annual CPR. Formula: CPR = 1 - (1 - SMM)^12'
AS
$$
    CASE
        WHEN SMM_MONTHLY IS NULL THEN NULL
        WHEN SMM_MONTHLY < 0 OR SMM_MONTHLY > 1 THEN NULL
        ELSE 1.0 - POWER(1.0 - SMM_MONTHLY, 12.0)
    END
$$;
```

Create a UDF that computes actual SMM from pool data:

```sql
CREATE OR REPLACE FUNCTION MORTGAGE_DB.ANALYTICS.CALC_ACTUAL_SMM(
    BEGINNING_BALANCE FLOAT,
    SCHEDULED_PRINCIPAL FLOAT,
    UNSCHEDULED_PRINCIPAL FLOAT
)
RETURNS FLOAT
LANGUAGE SQL
IMMUTABLE
COMMENT = 'SMM = Unscheduled Principal / (Beginning Balance - Scheduled Principal)'
AS
$$
    CASE
        WHEN BEGINNING_BALANCE IS NULL OR BEGINNING_BALANCE = 0 THEN NULL
        WHEN (BEGINNING_BALANCE - SCHEDULED_PRINCIPAL) = 0 THEN NULL
        ELSE UNSCHEDULED_PRINCIPAL / (BEGINNING_BALANCE - SCHEDULED_PRINCIPAL)
    END
$$;
```

Use the UDFs in analytics queries:

```sql
SELECT
    POOL_ID,
    REPORTING_PERIOD,
    BEGINNING_UPB,
    SCHEDULED_PRINCIPAL,
    UNSCHEDULED_PRINCIPAL,
    MORTGAGE_DB.ANALYTICS.CALC_ACTUAL_SMM(
        BEGINNING_UPB, SCHEDULED_PRINCIPAL, UNSCHEDULED_PRINCIPAL
    ) AS ACTUAL_SMM,
    MORTGAGE_DB.ANALYTICS.SMM_TO_CPR(
        MORTGAGE_DB.ANALYTICS.CALC_ACTUAL_SMM(
            BEGINNING_UPB, SCHEDULED_PRINCIPAL, UNSCHEDULED_PRINCIPAL
        )
    ) AS ACTUAL_CPR,
    MORTGAGE_DB.ANALYTICS.CPR_TO_SMM(0.06) AS BENCHMARK_6PCT_SMM
FROM MORTGAGE_DB.ANALYTICS.POOL_MONTHLY_FACTORS
WHERE REPORTING_PERIOD = '2025-06-01'
ORDER BY ACTUAL_CPR DESC
LIMIT 20;
```

**Result:** Standardized CPR/SMM calculations across 47 reports and dashboards, eliminating inconsistencies that previously caused a 3-basis-point discrepancy in prepayment speed reporting. The IMMUTABLE flag enables Snowflake to cache results and fold the UDF into query plans for optimal performance.

**AI Vision:** A prepayment model could be wrapped in a more complex UDTF that takes loan characteristics as input and returns predicted CPR vectors across multiple rate scenarios, making model output directly queryable in SQL.

---

### Q12. How do you use external functions to call a prepayment model API?

**Situation:** The quantitative team at Freddie Mac has deployed a prepayment model as a REST API on AWS API Gateway. The model accepts loan-level features (LTV, FICO, rate incentive, loan age) and returns a predicted CPR. Analytics queries need to call this model inline to enrich loan records with projected prepayment speeds.

**Task:** Create a Snowflake external function that invokes the prepayment model API, allowing SQL queries to call the model directly and receive predicted CPR values per loan.

**Action:**
Create the API integration (done by ACCOUNTADMIN):

```sql
CREATE OR REPLACE API INTEGRATION PREPAYMENT_MODEL_API
    API_PROVIDER = AWS_API_GATEWAY
    API_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-prepay-model'
    API_ALLOWED_PREFIXES = ('https://api.fhlmc-models.example.com/v2/')
    ENABLED = TRUE;
```

Create the external function:

```sql
CREATE OR REPLACE EXTERNAL FUNCTION MORTGAGE_DB.ANALYTICS.PREDICT_CPR(
    LOAN_AGE_MONTHS INT,
    ORIGINAL_LTV FLOAT,
    CREDIT_SCORE INT,
    RATE_INCENTIVE FLOAT,
    LOAN_PURPOSE VARCHAR,
    PROPERTY_TYPE VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
API_INTEGRATION = PREPAYMENT_MODEL_API
HEADERS = ('Content-Type' = 'application/json')
MAX_BATCH_ROWS = 500
COMPRESSION = AUTO
AS 'https://api.fhlmc-models.example.com/v2/predict-cpr';
```

Use the external function in a query:

```sql
SELECT
    LOAN_ID,
    POOL_ID,
    LOAN_AGE,
    ORIGINAL_LTV,
    CREDIT_SCORE,
    INTEREST_RATE - 0.0525 AS RATE_INCENTIVE,
    MORTGAGE_DB.ANALYTICS.PREDICT_CPR(
        LOAN_AGE, ORIGINAL_LTV, CREDIT_SCORE,
        INTEREST_RATE - 0.0525, LOAN_PURPOSE, PROPERTY_TYPE
    ):predicted_cpr::FLOAT AS PREDICTED_CPR,
    MORTGAGE_DB.ANALYTICS.PREDICT_CPR(
        LOAN_AGE, ORIGINAL_LTV, CREDIT_SCORE,
        INTEREST_RATE - 0.0525, LOAN_PURPOSE, PROPERTY_TYPE
    ):confidence_interval_low::FLOAT AS CPR_CI_LOW,
    MORTGAGE_DB.ANALYTICS.PREDICT_CPR(
        LOAN_AGE, ORIGINAL_LTV, CREDIT_SCORE,
        INTEREST_RATE - 0.0525, LOAN_PURPOSE, PROPERTY_TYPE
    ):confidence_interval_high::FLOAT AS CPR_CI_HIGH
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE
WHERE POOL_ID = 'FN_MA8675'
  AND REPORTING_PERIOD = '2025-06-01';
```

Optimized version using a CTE to avoid repeated function calls:

```sql
WITH predictions AS (
    SELECT
        LOAN_ID,
        POOL_ID,
        LOAN_AGE,
        ORIGINAL_LTV,
        CREDIT_SCORE,
        INTEREST_RATE - 0.0525 AS RATE_INCENTIVE,
        MORTGAGE_DB.ANALYTICS.PREDICT_CPR(
            LOAN_AGE, ORIGINAL_LTV, CREDIT_SCORE,
            INTEREST_RATE - 0.0525, LOAN_PURPOSE, PROPERTY_TYPE
        ) AS MODEL_OUTPUT
    FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE
    WHERE POOL_ID = 'FN_MA8675'
      AND REPORTING_PERIOD = '2025-06-01'
)
SELECT
    LOAN_ID,
    POOL_ID,
    LOAN_AGE,
    ORIGINAL_LTV,
    CREDIT_SCORE,
    RATE_INCENTIVE,
    MODEL_OUTPUT:predicted_cpr::FLOAT AS PREDICTED_CPR,
    MODEL_OUTPUT:confidence_interval_low::FLOAT AS CPR_CI_LOW,
    MODEL_OUTPUT:confidence_interval_high::FLOAT AS CPR_CI_HIGH,
    MODEL_OUTPUT:model_version::STRING AS MODEL_VERSION
FROM predictions;
```

**Result:** Analysts can now enrich any loan query with model-predicted CPR inline without exporting data. The external function processes 500 loans per API batch call, completing a 10,000-loan pool in approximately 30 seconds. This replaced a manual export-to-Python workflow that took 2 hours.

**AI Vision:** The API endpoint itself could host an ensemble of competing prepayment models (logistic regression, gradient boosting, neural network), with an A/B testing layer that dynamically routes traffic and measures prediction accuracy against actual outcomes to continuously select the best model.

---

### Q13. How do you configure Secure Data Sharing to share pool data with counterparties?

**Situation:** Ginnie Mae needs to share pool-level performance data with approved counterparties — servicers, investors, and rating agencies — without copying data. Each counterparty should see only the pools they are authorized to access, and data must be up-to-date in near-real-time.

**Task:** Set up Snowflake Secure Data Sharing using shares and secure views with row-level filtering so each consumer account sees only their authorized pool data.

**Action:**
Create a secure view with counterparty-based row filtering:

```sql
CREATE OR REPLACE SECURE VIEW MORTGAGE_DB.SHARING.SV_POOL_PERFORMANCE
AS
SELECT
    p.POOL_ID,
    p.REPORTING_PERIOD,
    p.POOL_UPB,
    p.LOAN_COUNT,
    p.WAC,
    p.WAM,
    p.PCT_CURRENT,
    p.PCT_DQ_30,
    p.PCT_DQ_60,
    p.PCT_DQ_90_PLUS,
    p.CPR_1M,
    p.CPR_3M,
    p.CDR_1M,
    p.LOSS_SEVERITY
FROM MORTGAGE_DB.ANALYTICS.POOL_PERFORMANCE p
INNER JOIN MORTGAGE_DB.REFERENCE.COUNTERPARTY_POOL_ACCESS a
    ON p.POOL_ID = a.POOL_ID
    AND a.COUNTERPARTY_ACCOUNT = CURRENT_ACCOUNT();
```

Create the share and add objects:

```sql
CREATE OR REPLACE SHARE GNMA_POOL_PERFORMANCE_SHARE
  COMMENT = 'GNMA pool performance data shared with authorized counterparties';

-- Grant usage on database and schema
GRANT USAGE ON DATABASE MORTGAGE_DB TO SHARE GNMA_POOL_PERFORMANCE_SHARE;
GRANT USAGE ON SCHEMA MORTGAGE_DB.SHARING TO SHARE GNMA_POOL_PERFORMANCE_SHARE;
GRANT USAGE ON SCHEMA MORTGAGE_DB.REFERENCE TO SHARE GNMA_POOL_PERFORMANCE_SHARE;

-- Grant SELECT on the secure view
GRANT SELECT ON VIEW MORTGAGE_DB.SHARING.SV_POOL_PERFORMANCE
  TO SHARE GNMA_POOL_PERFORMANCE_SHARE;

-- Grant SELECT on the mapping table (needed for the secure view's join)
GRANT SELECT ON TABLE MORTGAGE_DB.REFERENCE.COUNTERPARTY_POOL_ACCESS
  TO SHARE GNMA_POOL_PERFORMANCE_SHARE;
```

Add consumer accounts to the share:

```sql
ALTER SHARE GNMA_POOL_PERFORMANCE_SHARE
  ADD ACCOUNTS = WF_SERVICING_ACCT, JPM_INVESTOR_ACCT, MOODYS_RATING_ACCT;
```

On the consumer side, create a database from the share:

```sql
-- Executed in the consumer account (e.g., WF_SERVICING_ACCT)
CREATE OR REPLACE DATABASE GNMA_SHARED_DATA
  FROM SHARE GNMA_PROVIDER_ACCT.GNMA_POOL_PERFORMANCE_SHARE;

SELECT * FROM GNMA_SHARED_DATA.SHARING.SV_POOL_PERFORMANCE
WHERE REPORTING_PERIOD >= '2025-01-01'
ORDER BY POOL_ID, REPORTING_PERIOD;
```

**Result:** Three counterparties now access live pool performance data with zero data copying or file transfers. Data is always current (no replication lag). The secure view ensures Wells Fargo sees only their serviced pools, JPMorgan sees only their invested pools, and Moody's sees only pools under their rated deals. Eliminated monthly file delivery processes that cost 40 person-hours.

**AI Vision:** A graph-based access control model could automatically determine which pools each counterparty should see based on ownership chains, servicing agreements, and deal participation — maintaining the access mapping table dynamically as deals change hands.

---

### Q14. How do you use secure views to expose masked loan data to auditors?

**Situation:** External auditors from a Big Four firm need access to Fannie Mae loan-level data for annual examinations. They need to see loan performance attributes but must not see borrower PII (names, SSNs) or certain proprietary fields. The data must be queryable in Snowflake but without exposing the underlying table structure.

**Task:** Create secure views that expose auditor-appropriate columns with PII fields masked or excluded, while preventing auditors from reverse-engineering the view logic or accessing the base tables.

**Action:**
Create the secure view for auditor access:

```sql
CREATE OR REPLACE SECURE VIEW MORTGAGE_DB.AUDIT.SV_LOAN_DETAIL_AUDIT
  COMMENT = 'Auditor-facing loan view with PII removed and fields masked'
AS
SELECT
    -- Loan identifiers (pseudonymized)
    SHA2(LOAN_ID, 256)                           AS LOAN_ID_HASH,
    POOL_ID,
    REPORTING_PERIOD,

    -- Origination attributes (safe to share)
    ORIGINATION_DATE,
    ORIGINAL_UPB,
    CURRENT_UPB,
    ORIGINAL_INTEREST_RATE,
    CURRENT_INTEREST_RATE,
    ORIGINAL_LOAN_TERM,
    REMAINING_MONTHS,
    ORIGINAL_LTV,

    -- Borrower attributes (binned, not exact)
    CASE
        WHEN BORROWER_CREDIT_SCORE < 620 THEN 'Below 620'
        WHEN BORROWER_CREDIT_SCORE BETWEEN 620 AND 679 THEN '620-679'
        WHEN BORROWER_CREDIT_SCORE BETWEEN 680 AND 739 THEN '680-739'
        WHEN BORROWER_CREDIT_SCORE >= 740 THEN '740+'
    END AS CREDIT_SCORE_BAND,

    -- Geography (state only, no address)
    PROPERTY_STATE,
    PROPERTY_TYPE,
    OCCUPANCY_STATUS,
    LOAN_PURPOSE,

    -- Performance
    DELINQUENCY_STATUS,
    LOAN_STATUS,
    MOD_FLAG,
    ZERO_BALANCE_CODE,
    ZERO_BALANCE_DATE,

    -- Exclude: BORROWER_NAME, SSN, INCOME, EMPLOYER, FULL_ADDRESS, PHONE
    'REDACTED' AS BORROWER_NAME,
    'XXX-XX-' || RIGHT(SSN, 4) AS SSN_LAST_4

FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE
WHERE REPORTING_PERIOD >= DATEADD(YEAR, -3, CURRENT_DATE());
```

Grant access to the auditor role:

```sql
CREATE ROLE IF NOT EXISTS EXTERNAL_AUDITOR_ROLE;
GRANT USAGE ON DATABASE MORTGAGE_DB TO ROLE EXTERNAL_AUDITOR_ROLE;
GRANT USAGE ON SCHEMA MORTGAGE_DB.AUDIT TO ROLE EXTERNAL_AUDITOR_ROLE;
GRANT SELECT ON VIEW MORTGAGE_DB.AUDIT.SV_LOAN_DETAIL_AUDIT
  TO ROLE EXTERNAL_AUDITOR_ROLE;

-- Explicitly deny access to base tables
-- (no grants needed — default deny)
-- Auditors cannot see view definition because it is SECURE
```

Verify the view is truly secure (view definition hidden):

```sql
-- As auditor role:
SHOW VIEWS LIKE 'SV_LOAN_DETAIL_AUDIT' IN SCHEMA MORTGAGE_DB.AUDIT;
-- The TEXT column will show NULL for secure views when queried by non-owners

-- Verify EXPLAIN PLAN does not leak base table details
EXPLAIN SELECT * FROM MORTGAGE_DB.AUDIT.SV_LOAN_DETAIL_AUDIT LIMIT 10;
```

**Result:** Auditors gained self-service SQL access to 3 years of loan data (36 million records) without seeing any PII. Audit data requests that previously took 2 weeks of manual extraction now take seconds. The secure view prevents auditors from seeing the view definition, eliminating the risk of schema discovery.

**AI Vision:** An automated compliance engine could continuously validate that no PII leaks through the secure view by running adversarial queries (e.g., cross-joins with public data) and flagging any re-identification risks.

---

### Q15. How do you implement Dynamic Data Masking to protect borrower PII?

**Situation:** The `MORTGAGE_DB.ANALYTICS.LOAN_DETAIL` table contains sensitive borrower PII — SSN, income, employer name, and full property address. Different roles need different levels of access: data engineers see full data for debugging, analysts see partially masked data, and business users see fully masked data.

**Task:** Implement Snowflake's Dynamic Data Masking policies to apply role-based masking at query time, ensuring PII is protected without creating multiple copies of the data.

**Action:**
Create masking policies for each sensitive column type:

```sql
-- SSN masking policy
CREATE OR REPLACE MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_SSN
  AS (val VARCHAR) RETURNS VARCHAR ->
  CASE
    WHEN CURRENT_ROLE() IN ('DATA_ENGINEER', 'SYSADMIN') THEN val
    WHEN CURRENT_ROLE() IN ('SENIOR_ANALYST') THEN 'XXX-XX-' || RIGHT(val, 4)
    ELSE '***-**-****'
  END;

-- Income masking policy (numeric)
CREATE OR REPLACE MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_INCOME
  AS (val NUMBER) RETURNS NUMBER ->
  CASE
    WHEN CURRENT_ROLE() IN ('DATA_ENGINEER', 'SYSADMIN') THEN val
    WHEN CURRENT_ROLE() IN ('SENIOR_ANALYST') THEN
        ROUND(val / 10000) * 10000  -- round to nearest $10K
    ELSE 0
  END;

-- Borrower name masking policy
CREATE OR REPLACE MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_BORROWER_NAME
  AS (val VARCHAR) RETURNS VARCHAR ->
  CASE
    WHEN CURRENT_ROLE() IN ('DATA_ENGINEER', 'SYSADMIN') THEN val
    WHEN CURRENT_ROLE() IN ('SENIOR_ANALYST') THEN
        LEFT(val, 1) || REPEAT('*', LENGTH(val) - 1)
    ELSE '********'
  END;

-- Property address masking (show only state + zip)
CREATE OR REPLACE MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_ADDRESS
  AS (val VARCHAR) RETURNS VARCHAR ->
  CASE
    WHEN CURRENT_ROLE() IN ('DATA_ENGINEER', 'SYSADMIN') THEN val
    ELSE REGEXP_REPLACE(val, '.*,\\s*([A-Z]{2})\\s+(\\d{5}).*', '\\1 \\2')
  END;
```

Apply masking policies to columns:

```sql
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN SSN
  SET MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_SSN;

ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN BORROWER_INCOME
  SET MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_INCOME;

ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN BORROWER_NAME
  SET MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_BORROWER_NAME;

ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN PROPERTY_ADDRESS
  SET MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_ADDRESS;
```

Verify masking works per role:

```sql
-- As SENIOR_ANALYST:
SELECT LOAN_ID, SSN, BORROWER_NAME, BORROWER_INCOME, PROPERTY_ADDRESS
FROM MORTGAGE_DB.ANALYTICS.LOAN_DETAIL LIMIT 3;
-- SSN: XXX-XX-1234, Name: J*****, Income: 80000, Address: CA 90210

-- As BUSINESS_USER:
-- SSN: ***-**-****, Name: ********, Income: 0, Address: CA 90210
```

**Result:** A single table now serves all three access tiers without data duplication. Compliance with GLBA (Gramm-Leach-Bliley Act) and CCPA borrower privacy requirements is enforced at the platform level. Prior approach of maintaining three separate table copies is eliminated, saving 2TB of storage and the associated sync complexity.

**AI Vision:** A privacy-preserving analytics layer could use differential privacy techniques to allow aggregate statistical analysis on masked columns without ever exposing individual borrower data — enabling ML model training on privacy-protected data.

---

### Q16. How do you implement Row Access Policies to restrict data by servicer?

**Situation:** Fannie Mae's multi-servicer analytics platform stores loan data from 15 different servicers in a single `MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE` table. Each servicer's analyst team should only see their own loans. The compliance team and Fannie Mae internal users should see all loans.

**Task:** Implement Snowflake Row Access Policies (RAP) to enforce row-level security at the platform level, so queries automatically filter data based on the user's servicer affiliation without relying on application-layer filtering.

**Action:**
Create a mapping table that links roles to servicer codes:

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.GOVERNANCE.ROLE_SERVICER_MAPPING (
    ROLE_NAME           VARCHAR,
    SERVICER_CODE       VARCHAR,
    ACCESS_LEVEL        VARCHAR  -- 'ALL' or 'OWN'
);

INSERT INTO MORTGAGE_DB.GOVERNANCE.ROLE_SERVICER_MAPPING VALUES
    ('WELLS_FARGO_ANALYST',    'WF001',  'OWN'),
    ('JPMORGAN_ANALYST',       'JPM002', 'OWN'),
    ('PENNYMAC_ANALYST',       'PNY003', 'OWN'),
    ('FNMA_INTERNAL',          NULL,     'ALL'),
    ('COMPLIANCE_TEAM',        NULL,     'ALL'),
    ('SYSADMIN',               NULL,     'ALL');
```

Create the row access policy:

```sql
CREATE OR REPLACE ROW ACCESS POLICY MORTGAGE_DB.GOVERNANCE.RAP_SERVICER_FILTER
  AS (SERVICER_CODE VARCHAR) RETURNS BOOLEAN ->
  CASE
    -- Full access roles see all rows
    WHEN CURRENT_ROLE() IN ('FNMA_INTERNAL', 'COMPLIANCE_TEAM', 'SYSADMIN', 'ACCOUNTADMIN')
        THEN TRUE
    -- Servicer-specific roles see only their loans
    WHEN EXISTS (
        SELECT 1
        FROM MORTGAGE_DB.GOVERNANCE.ROLE_SERVICER_MAPPING m
        WHERE m.ROLE_NAME = CURRENT_ROLE()
          AND m.SERVICER_CODE = SERVICER_CODE
          AND m.ACCESS_LEVEL = 'OWN'
    ) THEN TRUE
    ELSE FALSE
  END;
```

Apply the policy to the table:

```sql
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE
  ADD ROW ACCESS POLICY MORTGAGE_DB.GOVERNANCE.RAP_SERVICER_FILTER
  ON (SERVICER_CODE);
```

Also apply to related tables for consistent enforcement:

```sql
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION
  ADD ROW ACCESS POLICY MORTGAGE_DB.GOVERNANCE.RAP_SERVICER_FILTER
  ON (SERVICER_CODE);

ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_MODIFICATIONS
  ADD ROW ACCESS POLICY MORTGAGE_DB.GOVERNANCE.RAP_SERVICER_FILTER
  ON (SERVICER_CODE);
```

Verify row-level filtering:

```sql
-- As WELLS_FARGO_ANALYST role:
SELECT COUNT(*), COUNT(DISTINCT SERVICER_CODE)
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE;
-- Returns: 3,200,000 loans, 1 servicer (WF001 only)

-- As FNMA_INTERNAL role:
SELECT COUNT(*), COUNT(DISTINCT SERVICER_CODE)
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE;
-- Returns: 30,000,000 loans, 15 servicers
```

**Result:** Row-level security is now enforced transparently across all queries, views, and BI tools — no application code changes needed. Eliminated 15 separate servicer-specific views that were previously maintained manually. Regulatory audit passed without findings on data segregation.

**AI Vision:** An access analytics model could detect anomalous query patterns — such as a servicer analyst role running unusually broad queries or accessing data at unusual hours — flagging potential credential compromise or insider threats.

---

### Q17. How do you use Query Profile to optimize a slow MBS valuation query?

**Situation:** A critical MBS valuation query that joins deal structures, collateral pools, market rates, and prepayment vectors runs for 25 minutes on an XL warehouse. Month-end portfolio valuation depends on this query completing within the 2-hour processing window, and it currently consumes 60% of the available time.

**Task:** Use the Snowflake Query Profile to identify performance bottlenecks and optimize the query to run within 5 minutes.

**Action:**
Run the slow query and capture the query ID:

```sql
-- Original slow query (simplified for illustration)
SELECT
    d.DEAL_NAME,
    d.TRANCHE_ID,
    d.CUSIP,
    t.CURRENT_BALANCE,
    v.DISCOUNT_RATE,
    SUM(cf.PROJECTED_CASHFLOW *
        POWER(1 + v.DISCOUNT_RATE/12, -cf.PERIOD_NUM)) AS PRESENT_VALUE
FROM MORTGAGE_DB.ANALYTICS.DEAL_TRANCHES d
JOIN MORTGAGE_DB.ANALYTICS.TRANCHE_BALANCES t
    ON d.DEAL_NAME = t.DEAL_NAME AND d.TRANCHE_ID = t.TRANCHE_ID
JOIN MORTGAGE_DB.ANALYTICS.PROJECTED_CASHFLOWS cf
    ON d.DEAL_NAME = cf.DEAL_NAME AND d.TRANCHE_ID = cf.TRANCHE_ID
JOIN MORTGAGE_DB.ANALYTICS.VALUATION_RATES v
    ON d.CREDIT_RATING = v.RATING_BUCKET AND d.COUPON_TYPE = v.COUPON_TYPE
WHERE t.AS_OF_DATE = '2025-06-30'
GROUP BY d.DEAL_NAME, d.TRANCHE_ID, d.CUSIP, t.CURRENT_BALANCE, v.DISCOUNT_RATE;

-- Capture query ID
SET LAST_QID = LAST_QUERY_ID();
```

Analyze performance using system views:

```sql
-- Check partition pruning and spilling
SELECT
    OPERATOR_ID,
    OPERATOR_TYPE,
    OPERATOR_ATTRIBUTES,
    EXECUTION_TIME_BREAKDOWN,
    OPERATOR_STATISTICS
FROM TABLE(GET_QUERY_OPERATOR_STATS($LAST_QID))
ORDER BY OPERATOR_ID;

-- Check for data spilling
SELECT
    QUERY_ID,
    BYTES_SPILLED_TO_LOCAL_STORAGE,
    BYTES_SPILLED_TO_REMOTE_STORAGE,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    BYTES_SCANNED,
    ROWS_PRODUCED
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_ID = $LAST_QID;
```

The Query Profile reveals three issues:
1. The `PROJECTED_CASHFLOWS` table (360 periods x 180K tranches = 65M rows) has no pruning — full table scan.
2. The JOIN between `DEAL_TRANCHES` and `PROJECTED_CASHFLOWS` spills 40GB to remote storage.
3. The `VALUATION_RATES` table is tiny (200 rows) but forces a broadcast join.

Apply optimizations:

```sql
-- Fix 1: Add clustering key on the cashflow table
ALTER TABLE MORTGAGE_DB.ANALYTICS.PROJECTED_CASHFLOWS
  CLUSTER BY (DEAL_NAME, TRANCHE_ID);

-- Fix 2: Rewrite the query with a CTE to filter early and reduce join cardinality
WITH active_tranches AS (
    SELECT d.DEAL_NAME, d.TRANCHE_ID, d.CUSIP, d.CREDIT_RATING,
           d.COUPON_TYPE, t.CURRENT_BALANCE
    FROM MORTGAGE_DB.ANALYTICS.DEAL_TRANCHES d
    JOIN MORTGAGE_DB.ANALYTICS.TRANCHE_BALANCES t
        ON d.DEAL_NAME = t.DEAL_NAME AND d.TRANCHE_ID = t.TRANCHE_ID
    WHERE t.AS_OF_DATE = '2025-06-30'
      AND t.CURRENT_BALANCE > 0
),
rated_tranches AS (
    SELECT at.*, v.DISCOUNT_RATE
    FROM active_tranches at
    JOIN MORTGAGE_DB.ANALYTICS.VALUATION_RATES v
        ON at.CREDIT_RATING = v.RATING_BUCKET
        AND at.COUPON_TYPE = v.COUPON_TYPE
)
SELECT
    rt.DEAL_NAME,
    rt.TRANCHE_ID,
    rt.CUSIP,
    rt.CURRENT_BALANCE,
    rt.DISCOUNT_RATE,
    SUM(cf.PROJECTED_CASHFLOW *
        POWER(1 + rt.DISCOUNT_RATE/12, -cf.PERIOD_NUM)) AS PRESENT_VALUE
FROM rated_tranches rt
JOIN MORTGAGE_DB.ANALYTICS.PROJECTED_CASHFLOWS cf
    ON rt.DEAL_NAME = cf.DEAL_NAME AND rt.TRANCHE_ID = cf.TRANCHE_ID
GROUP BY 1, 2, 3, 4, 5;
```

**Result:** The optimized query runs in 3 minutes 40 seconds — an 85% improvement. Spilling dropped from 40GB to zero. Partition pruning on the cashflow table improved from 0% to 92% after clustering. Month-end valuation pipeline now completes with a 75% time buffer.

**AI Vision:** An automated query optimization advisor (built on ML analysis of thousands of query profiles) could proactively suggest index strategies, clustering keys, and query rewrites before slow queries impact production SLAs.

---

### Q18. How do you configure warehouse scaling policies for month-end surge?

**Situation:** Freddie Mac's analytics platform experiences a 5x surge in query volume during the last three business days of each month as portfolio managers, risk analysts, and regulators run month-end reports. During the rest of the month, a Medium warehouse handles the load. At month-end, queries queue for 10+ minutes.

**Task:** Configure multi-cluster warehouse auto-scaling and resource monitors to handle month-end surge efficiently while controlling costs during normal periods.

**Action:**
Create a multi-cluster warehouse with auto-scaling:

```sql
CREATE OR REPLACE WAREHOUSE ANALYTICS_WH
  WAREHOUSE_SIZE = 'MEDIUM'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 6
  SCALING_POLICY = 'STANDARD'       -- scale out when queries queue
  AUTO_SUSPEND = 120                 -- suspend after 2 minutes idle
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = FALSE
  COMMENT = 'Analytics warehouse with month-end auto-scaling to 6 clusters';
```

Create a dedicated warehouse for heavy month-end ETL:

```sql
CREATE OR REPLACE WAREHOUSE MONTHEND_ETL_WH
  WAREHOUSE_SIZE = 'X-LARGE'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 1
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'XL warehouse for month-end batch processing, suspended when idle';
```

Set up resource monitors to control spending:

```sql
CREATE OR REPLACE RESOURCE MONITOR ANALYTICS_MONTHLY_MONITOR
  WITH CREDIT_QUOTA = 2000
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 90 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE ANALYTICS_WH
  SET RESOURCE_MONITOR = ANALYTICS_MONTHLY_MONITOR;

CREATE OR REPLACE RESOURCE MONITOR MONTHEND_ETL_MONITOR
  WITH CREDIT_QUOTA = 500
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 80 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE MONTHEND_ETL_WH
  SET RESOURCE_MONITOR = MONTHEND_ETL_MONITOR;
```

Monitor warehouse performance and scaling:

```sql
-- Check cluster scaling events
SELECT
    CLUSTER_NUMBER,
    EVENT_NAME,
    EVENT_TIMESTAMP,
    EVENT_REASON
FROM TABLE(INFORMATION_SCHEMA.WAREHOUSE_EVENTS_HISTORY(
    DATE_RANGE_START => DATEADD(DAY, -5, CURRENT_TIMESTAMP()),
    WAREHOUSE_NAME => 'ANALYTICS_WH'
))
WHERE EVENT_NAME IN ('SCALE_OUT', 'SCALE_IN')
ORDER BY EVENT_TIMESTAMP DESC;

-- Check queuing vs. execution times
SELECT
    DATE_TRUNC('HOUR', START_TIME) AS HOUR,
    COUNT(*) AS QUERY_COUNT,
    AVG(QUEUED_OVERLOAD_TIME) / 1000 AS AVG_QUEUE_SECONDS,
    AVG(TOTAL_ELAPSED_TIME) / 1000 AS AVG_ELAPSED_SECONDS,
    MAX(CLUSTER_NUMBER) AS MAX_CLUSTERS_USED
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE WAREHOUSE_NAME = 'ANALYTICS_WH'
  AND START_TIME >= DATEADD(DAY, -3, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1;
```

**Result:** Month-end query queuing dropped from 10+ minutes to under 15 seconds as the warehouse scaled from 1 to 5 clusters during peak. Total monthly cost increased by only 18% because scaling is elastic — clusters shut down within 2 minutes of demand subsiding. The ETL warehouse processes month-end batch jobs 4x faster than the medium warehouse, completing within the overnight window.

**AI Vision:** A predictive scaling model trained on historical month-end patterns could pre-warm additional clusters 30 minutes before the expected surge, eliminating even the initial scaling latency and providing a seamless experience for early-bird analysts.

---

### Q19. How do you configure network policies to restrict access to the compliance team?

**Situation:** Fannie Mae's compliance and regulatory reporting environment in Snowflake contains sensitive HMDA (Home Mortgage Disclosure Act) data and fair lending analysis results. Regulatory requirements mandate that this data be accessible only from the corporate network and specific compliance team VPN IP ranges.

**Task:** Implement Snowflake network policies to restrict access to the compliance schema to approved IP address ranges, blocking all other network locations including personal devices and public Wi-Fi.

**Action:**
Create a network policy for the compliance team:

```sql
CREATE OR REPLACE NETWORK POLICY COMPLIANCE_NETWORK_POLICY
  ALLOWED_IP_LIST = (
    '10.100.0.0/16',       -- Corporate HQ network
    '10.200.50.0/24',      -- Compliance floor VPN range
    '172.16.30.0/24',      -- Compliance remote VPN pool
    '52.23.145.0/28'       -- AWS PrivateLink endpoint range
  )
  BLOCKED_IP_LIST = (
    '10.100.99.0/24'       -- Guest Wi-Fi subnet (explicitly blocked)
  )
  COMMENT = 'Restricts compliance users to corporate and VPN networks only';
```

Apply the network policy at the user level for compliance team members:

```sql
-- Apply to individual compliance users
ALTER USER COMPLIANCE_ANALYST_1
  SET NETWORK_POLICY = COMPLIANCE_NETWORK_POLICY;

ALTER USER COMPLIANCE_ANALYST_2
  SET NETWORK_POLICY = COMPLIANCE_NETWORK_POLICY;

ALTER USER COMPLIANCE_MANAGER
  SET NETWORK_POLICY = COMPLIANCE_NETWORK_POLICY;
```

For broader enforcement, create a separate account-level policy for the compliance-dedicated account:

```sql
-- If using a separate Snowflake account for compliance:
ALTER ACCOUNT SET NETWORK_POLICY = COMPLIANCE_NETWORK_POLICY;
```

Monitor blocked access attempts:

```sql
SELECT
    EVENT_TIMESTAMP,
    USER_NAME,
    CLIENT_IP,
    REPORTED_CLIENT_TYPE,
    ERROR_CODE,
    ERROR_MESSAGE,
    IS_SUCCESS
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE IS_SUCCESS = 'NO'
  AND ERROR_MESSAGE ILIKE '%network policy%'
  AND EVENT_TIMESTAMP >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())
ORDER BY EVENT_TIMESTAMP DESC;
```

Audit current network policy assignments:

```sql
SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN USER COMPLIANCE_ANALYST_1;
SHOW NETWORK POLICIES;

-- List all users with network policies
SELECT USER_NAME, NETWORK_POLICY
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE NETWORK_POLICY IS NOT NULL;
```

**Result:** All compliance team access is now restricted to approved network ranges. 12 unauthorized access attempts from personal devices were blocked in the first month. The network policy passed the OCC (Office of the Comptroller of the Currency) security audit without findings. No legitimate access was disrupted because VPN ranges were correctly included.

**AI Vision:** A network behavior analytics model could establish baseline access patterns for each compliance user and dynamically flag suspicious deviations — such as access from a new IP range that is technically allowed but statistically anomalous.

---

### Q20. How do you use external tables to query S3 loan archives without loading?

**Situation:** Freddie Mac retains 20 years of historical loan origination data in S3 as compressed Parquet files — approximately 50TB total. This data is queried only for occasional regulatory lookback analyses. Loading it into Snowflake would be expensive in storage, and it changes infrequently (quarterly additions only).

**Task:** Create external tables that allow SQL queries directly against the S3 Parquet files, using partition columns to prune efficiently by origination year and quarter.

**Action:**
Create the storage integration and external stage:

```sql
CREATE OR REPLACE STAGE MORTGAGE_DB.RAW.STG_LOAN_ARCHIVE
    URL = 's3://fhlmc-loan-archive/origination/'
    STORAGE_INTEGRATION = FHLMC_S3_ARCHIVE_INT
    FILE_FORMAT = (TYPE = PARQUET);
```

The S3 path structure is: `s3://fhlmc-loan-archive/origination/year=YYYY/quarter=Q/files.parquet`

Create the external table with partition columns:

```sql
CREATE OR REPLACE EXTERNAL TABLE MORTGAGE_DB.RAW.EXT_LOAN_ORIGINATION_ARCHIVE (
    ORIGINATION_YEAR   INT      AS (SPLIT_PART(METADATA$FILENAME, '/', 2)::INT),
    ORIGINATION_QTR    VARCHAR  AS (SPLIT_PART(METADATA$FILENAME, '/', 3)),
    LOAN_ID            VARCHAR  AS (VALUE:loan_id::VARCHAR),
    SELLER_NAME        VARCHAR  AS (VALUE:seller_name::VARCHAR),
    ORIGINATION_DATE   DATE     AS (VALUE:origination_date::DATE),
    ORIGINAL_UPB       NUMBER(14,2) AS (VALUE:original_upb::NUMBER(14,2)),
    ORIGINAL_INTEREST_RATE NUMBER(8,6) AS (VALUE:interest_rate::NUMBER(8,6)),
    ORIGINAL_LTV       INT      AS (VALUE:ltv::INT),
    CREDIT_SCORE       INT      AS (VALUE:credit_score::INT),
    DTI                INT      AS (VALUE:dti::INT),
    PROPERTY_STATE     VARCHAR  AS (VALUE:property_state::VARCHAR),
    PROPERTY_TYPE      VARCHAR  AS (VALUE:property_type::VARCHAR),
    LOAN_PURPOSE       VARCHAR  AS (VALUE:loan_purpose::VARCHAR),
    NUM_BORROWERS      INT      AS (VALUE:num_borrowers::INT),
    FIRST_TIME_BUYER   VARCHAR  AS (VALUE:first_time_buyer::VARCHAR)
)
PARTITION BY (ORIGINATION_YEAR, ORIGINATION_QTR)
LOCATION = @MORTGAGE_DB.RAW.STG_LOAN_ARCHIVE
AUTO_REFRESH = TRUE
FILE_FORMAT = (TYPE = PARQUET)
COMMENT = '20-year loan origination archive on S3, partitioned by year/quarter';
```

Refresh the external table metadata:

```sql
ALTER EXTERNAL TABLE MORTGAGE_DB.RAW.EXT_LOAN_ORIGINATION_ARCHIVE REFRESH;
```

Query with partition pruning:

```sql
-- Regulatory lookback: 2008 crisis originations in high-sand-state markets
SELECT
    ORIGINATION_QTR,
    PROPERTY_STATE,
    COUNT(*) AS LOAN_COUNT,
    SUM(ORIGINAL_UPB) AS TOTAL_UPB,
    AVG(ORIGINAL_LTV) AS AVG_LTV,
    AVG(CREDIT_SCORE) AS AVG_FICO,
    AVG(DTI) AS AVG_DTI
FROM MORTGAGE_DB.RAW.EXT_LOAN_ORIGINATION_ARCHIVE
WHERE ORIGINATION_YEAR BETWEEN 2006 AND 2008
  AND PROPERTY_STATE IN ('AZ', 'CA', 'FL', 'NV')
GROUP BY ORIGINATION_QTR, PROPERTY_STATE
ORDER BY ORIGINATION_QTR, PROPERTY_STATE;
```

**Result:** Regulatory analysis queries against 3 years of archived data complete in 45 seconds by scanning only 12 of 80 partitions. The 50TB archive remains in S3 at low-cost object storage pricing instead of being loaded into Snowflake managed storage. Quarterly refreshes cost under $5 in credits.

**AI Vision:** An intelligent query router could determine whether a query should target the external table (cold archive) or internal table (hot data) based on the date range, automatically rewriting the query to use the optimal source for cost and performance.

---

### Q21. How do you use directory tables to manage incoming file manifests?

**Situation:** Ginnie Mae receives daily file deliveries from 15 servicers. Each delivery should include a manifest file listing expected data files, their row counts, and checksums. The data engineering team needs to validate that all expected files arrived before triggering the ingestion pipeline.

**Task:** Use Snowflake directory tables on stages to inventory incoming files, compare against manifest expectations, and generate a completeness report before processing.

**Action:**
Enable the directory table on the stage:

```sql
CREATE OR REPLACE STAGE MORTGAGE_DB.RAW.STG_SERVICER_INBOX
    URL = 's3://gnma-servicer-inbox/'
    STORAGE_INTEGRATION = GNMA_S3_INTEGRATION
    DIRECTORY = (ENABLE = TRUE AUTO_REFRESH = TRUE);

-- Manual refresh if needed
ALTER STAGE MORTGAGE_DB.RAW.STG_SERVICER_INBOX REFRESH;
```

Query the directory table to list all files:

```sql
SELECT
    RELATIVE_PATH,
    SIZE,
    LAST_MODIFIED,
    MD5,
    FILE_URL,
    -- Parse servicer code from path: servicer_code/YYYY-MM-DD/filename
    SPLIT_PART(RELATIVE_PATH, '/', 1) AS SERVICER_CODE,
    SPLIT_PART(RELATIVE_PATH, '/', 2) AS DELIVERY_DATE,
    SPLIT_PART(RELATIVE_PATH, '/', 3) AS FILE_NAME
FROM DIRECTORY(@MORTGAGE_DB.RAW.STG_SERVICER_INBOX)
WHERE LAST_MODIFIED >= DATEADD(DAY, -1, CURRENT_TIMESTAMP())
ORDER BY SERVICER_CODE, RELATIVE_PATH;
```

Load and parse manifest files to compare against actual deliveries:

```sql
-- Create a table for parsed manifest expectations
CREATE OR REPLACE TEMPORARY TABLE MANIFEST_EXPECTED AS
SELECT
    m.$1::VARCHAR AS SERVICER_CODE,
    m.$2::VARCHAR AS EXPECTED_FILE,
    m.$3::INT AS EXPECTED_ROW_COUNT,
    m.$4::VARCHAR AS EXPECTED_MD5
FROM @MORTGAGE_DB.RAW.STG_SERVICER_INBOX/manifest/
    (FILE_FORMAT => 'CSV_PIPE_DELIMITED') m
WHERE METADATA$FILENAME LIKE '%manifest%';

-- Compare expected vs. actual
SELECT
    e.SERVICER_CODE,
    e.EXPECTED_FILE,
    e.EXPECTED_ROW_COUNT,
    e.EXPECTED_MD5,
    d.SIZE AS ACTUAL_SIZE,
    d.MD5 AS ACTUAL_MD5,
    d.LAST_MODIFIED,
    CASE
        WHEN d.RELATIVE_PATH IS NULL THEN 'MISSING'
        WHEN d.MD5 != e.EXPECTED_MD5 THEN 'CHECKSUM_MISMATCH'
        ELSE 'OK'
    END AS VALIDATION_STATUS
FROM MANIFEST_EXPECTED e
LEFT JOIN DIRECTORY(@MORTGAGE_DB.RAW.STG_SERVICER_INBOX) d
    ON d.RELATIVE_PATH LIKE '%' || e.SERVICER_CODE || '%' || e.EXPECTED_FILE || '%'
ORDER BY e.SERVICER_CODE, VALIDATION_STATUS DESC;
```

Create a stored procedure to run the validation and gate the pipeline:

```sql
CREATE OR REPLACE PROCEDURE MORTGAGE_DB.PIPELINE.SP_VALIDATE_DELIVERY(
    P_DELIVERY_DATE DATE
)
RETURNS TABLE (SERVICER_CODE VARCHAR, STATUS VARCHAR, MISSING_FILES INT)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    ALTER STAGE MORTGAGE_DB.RAW.STG_SERVICER_INBOX REFRESH;

    res := (
        SELECT
            e.SERVICER_CODE,
            CASE WHEN COUNT_IF(d.RELATIVE_PATH IS NULL) = 0 THEN 'COMPLETE'
                 ELSE 'INCOMPLETE' END AS STATUS,
            COUNT_IF(d.RELATIVE_PATH IS NULL) AS MISSING_FILES
        FROM MANIFEST_EXPECTED e
        LEFT JOIN DIRECTORY(@MORTGAGE_DB.RAW.STG_SERVICER_INBOX) d
            ON d.RELATIVE_PATH LIKE '%' || e.SERVICER_CODE || '%/' ||
               :P_DELIVERY_DATE::VARCHAR || '/%' || e.EXPECTED_FILE || '%'
        GROUP BY e.SERVICER_CODE
    );
    RETURN TABLE(res);
END;
$$;
```

**Result:** File delivery validation runs in 10 seconds across 15 servicers and 200+ expected files. Missing file detection is immediate — the pipeline no longer starts processing incomplete deliveries. Reduced data quality incidents by 95% because incomplete servicer submissions are caught before ingestion.

**AI Vision:** A pattern recognition model could learn each servicer's typical delivery timing and file sizes, predicting late or anomalous deliveries before the deadline and proactively alerting the operations team to follow up.

---

### Q22. How do you use Snowpark to build loan cohort analysis in Python?

**Situation:** Freddie Mac's analytics team needs to perform vintage cohort analysis on loan performance — grouping loans by origination quarter (vintage) and tracking cumulative default rates over loan age. The logic involves complex window functions and pivot operations that are easier to express in Python with Snowpark than in raw SQL.

**Task:** Use Snowpark for Python to build the cohort analysis DataFrame pipeline that runs entirely on Snowflake's compute, pushing all operations down to the warehouse without extracting data to a client.

**Action:**
Create the Snowpark session and build the pipeline:

```sql
-- First, create a stored procedure that uses Snowpark Python
CREATE OR REPLACE PROCEDURE MORTGAGE_DB.ANALYTICS.SP_COHORT_ANALYSIS(
    START_VINTAGE VARCHAR,
    END_VINTAGE VARCHAR
)
RETURNS TABLE()
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run_cohort_analysis'
AS
$$
from snowflake.snowpark import Session
from snowflake.snowpark.functions import (
    col, sum as sum_, count, when, lit, date_trunc,
    datediff, round as round_, avg
)
from snowflake.snowpark.window import Window

def run_cohort_analysis(session: Session, start_vintage: str, end_vintage: str):
    # Read loan performance data
    loans = session.table("MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE")

    # Filter to vintages of interest
    loans_filtered = loans.filter(
        (col("ORIGINATION_DATE") >= start_vintage) &
        (col("ORIGINATION_DATE") <= end_vintage)
    )

    # Add vintage quarter and loan age columns
    cohort_base = loans_filtered.with_column(
        "VINTAGE_QTR",
        date_trunc("QUARTER", col("ORIGINATION_DATE"))
    ).with_column(
        "LOAN_AGE_MONTHS",
        datediff("MONTH", col("ORIGINATION_DATE"), col("REPORTING_PERIOD"))
    )

    # Bucket loan age into 6-month intervals
    cohort_base = cohort_base.with_column(
        "AGE_BUCKET",
        (col("LOAN_AGE_MONTHS") / lit(6)).cast("INT") * lit(6)
    )

    # Calculate default rates per vintage-age bucket
    cohort_metrics = cohort_base.group_by(
        "VINTAGE_QTR", "AGE_BUCKET"
    ).agg(
        count("*").alias("LOAN_COUNT"),
        sum_(col("CURRENT_UPB")).alias("TOTAL_UPB"),
        sum_(when(col("ZERO_BALANCE_CODE").isin(["03", "06", "09"]),
                  col("ORIGINAL_UPB")).otherwise(lit(0))
        ).alias("DEFAULT_UPB"),
        avg(col("CREDIT_SCORE")).alias("AVG_FICO"),
        avg(col("ORIGINAL_LTV")).alias("AVG_LTV")
    )

    # Compute cumulative default rate per vintage
    vintage_window = Window.partition_by("VINTAGE_QTR").order_by("AGE_BUCKET")

    result = cohort_metrics.with_column(
        "CUMULATIVE_DEFAULT_UPB",
        sum_(col("DEFAULT_UPB")).over(vintage_window)
    ).with_column(
        "VINTAGE_ORIGINAL_UPB",
        sum_(col("TOTAL_UPB")).over(
            Window.partition_by("VINTAGE_QTR")
        )
    ).with_column(
        "CUMULATIVE_DEFAULT_RATE",
        round_(
            col("CUMULATIVE_DEFAULT_UPB") / col("VINTAGE_ORIGINAL_UPB") * lit(100),
            4
        )
    ).sort("VINTAGE_QTR", "AGE_BUCKET")

    return result
$$;
```

Execute the cohort analysis:

```sql
CALL MORTGAGE_DB.ANALYTICS.SP_COHORT_ANALYSIS('2020-01-01', '2024-12-31');
```

Save results to a table for dashboarding:

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.ANALYTICS.COHORT_RESULTS AS
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
```

**Result:** The Snowpark cohort analysis processes 120 million loan-month records across 20 vintages in 4 minutes — all computation pushed to the Snowflake warehouse. The Python code is more maintainable than the equivalent 200-line SQL window function query. Analysts can iterate on the logic in Snowpark notebooks without data extraction.

**AI Vision:** The Snowpark pipeline could feed into a scikit-learn model (also running in Snowpark) that fits a survival curve to each vintage cohort, projecting lifetime default rates and enabling automated credit risk reporting with confidence intervals.

---

### Q23. How do you set up Alerts to monitor data freshness for daily feeds?

**Situation:** Fannie Mae's downstream reporting systems depend on daily loan performance data being loaded by 8 AM ET. If the data is stale (not updated since the prior business day), reports will contain incorrect numbers. The data engineering team needs automated monitoring rather than manual checks.

**Task:** Create Snowflake Alerts that continuously check data freshness and notify the team via email when the daily feed is late or missing.

**Action:**
Create an alert that checks if today's data has arrived:

```sql
CREATE OR REPLACE ALERT MORTGAGE_DB.MONITORING.ALERT_LOAN_FEED_FRESHNESS
  WAREHOUSE = MONITORING_WH_XS
  SCHEDULE = 'USING CRON 0 8,9,10 * * 1-5 America/New_York'  -- 8, 9, 10 AM ET weekdays
  IF (EXISTS (
      SELECT 1
      WHERE NOT EXISTS (
          SELECT 1
          FROM MORTGAGE_DB.RAW.LOAN_PERFORMANCE_RAW
          WHERE LOAD_TIMESTAMP >= CURRENT_DATE()
      )
  ))
  THEN
      CALL SYSTEM$SEND_EMAIL(
          'LOAN_PIPELINE_NOTIFICATION',
          'data-engineering@fanniemae.example.com',
          'ALERT: Daily loan performance feed not loaded',
          'The LOAN_PERFORMANCE_RAW table has no records loaded today (' ||
              CURRENT_DATE()::VARCHAR || ') as of ' ||
              CURRENT_TIMESTAMP()::VARCHAR || '. Last load: ' ||
              (SELECT MAX(LOAD_TIMESTAMP)::VARCHAR
               FROM MORTGAGE_DB.RAW.LOAN_PERFORMANCE_RAW) ||
              '. Please investigate the Snowpipe and upstream servicer feed.'
      );
```

Create a second alert for row count anomalies:

```sql
CREATE OR REPLACE ALERT MORTGAGE_DB.MONITORING.ALERT_LOAN_ROW_COUNT_ANOMALY
  WAREHOUSE = MONITORING_WH_XS
  SCHEDULE = 'USING CRON 30 9 * * 1-5 America/New_York'
  IF (EXISTS (
      SELECT 1
      FROM (
          SELECT
              COUNT(*) AS TODAY_COUNT,
              (SELECT COUNT(*)
               FROM MORTGAGE_DB.RAW.LOAN_PERFORMANCE_RAW
               WHERE LOAD_TIMESTAMP BETWEEN DATEADD(DAY, -1, CURRENT_DATE())
                                        AND CURRENT_DATE()) AS YESTERDAY_COUNT
          FROM MORTGAGE_DB.RAW.LOAN_PERFORMANCE_RAW
          WHERE LOAD_TIMESTAMP >= CURRENT_DATE()
      )
      WHERE ABS(TODAY_COUNT - YESTERDAY_COUNT) / NULLIF(YESTERDAY_COUNT, 0) > 0.10
  ))
  THEN
      CALL SYSTEM$SEND_EMAIL(
          'LOAN_PIPELINE_NOTIFICATION',
          'data-engineering@fanniemae.example.com',
          'ALERT: Loan feed row count deviation > 10%',
          'Today''s loan feed row count deviates more than 10% from yesterday. Investigate for missing servicer data or duplicate loads.'
      );
```

Resume the alerts:

```sql
ALTER ALERT MORTGAGE_DB.MONITORING.ALERT_LOAN_FEED_FRESHNESS RESUME;
ALTER ALERT MORTGAGE_DB.MONITORING.ALERT_LOAN_ROW_COUNT_ANOMALY RESUME;
```

Monitor alert history:

```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.ALERT_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP()),
    ALERT_NAME => 'ALERT_LOAN_FEED_FRESHNESS'
))
ORDER BY SCHEDULED_TIME DESC;
```

**Result:** The freshness alert caught 3 late deliveries in the first month, triggering email notifications at 8 AM instead of being discovered at 10 AM during the reporting window. Average incident detection time improved from 2 hours to 0 minutes. The row count anomaly alert caught a duplicate load event that would have inflated UPB figures by $2.3 billion.

**AI Vision:** A time-series forecasting model could predict expected file arrival times per servicer and expected row counts with confidence bands, making the alert thresholds adaptive rather than static — reducing false positives while catching subtle anomalies earlier.

---

### Q24. How do you use object tagging to classify PII columns in loan tables?

**Situation:** Fannie Mae's Snowflake environment contains 400+ tables across multiple schemas with borrower PII scattered throughout. Regulatory audits require a complete inventory of PII columns, and governance policies (masking, access controls) need to be consistently applied. Manual tracking in spreadsheets is unreliable and out of date.

**Task:** Implement Snowflake object tagging to systematically classify PII columns, enabling automated governance policy application and audit reporting.

**Action:**
Create a tag hierarchy for data classification:

```sql
CREATE OR REPLACE TAG MORTGAGE_DB.GOVERNANCE.DATA_CLASSIFICATION
  ALLOWED_VALUES = ('PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'RESTRICTED');

CREATE OR REPLACE TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE
  ALLOWED_VALUES = ('SSN', 'NAME', 'DOB', 'INCOME', 'ADDRESS', 'PHONE', 'EMAIL', 'ACCOUNT_NUMBER');

CREATE OR REPLACE TAG MORTGAGE_DB.GOVERNANCE.REGULATORY_SCOPE
  ALLOWED_VALUES = ('GLBA', 'CCPA', 'HMDA', 'ECOA', 'FCRA');
```

Apply tags to PII columns across loan tables:

```sql
-- Tag SSN columns
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN SSN
  SET TAG MORTGAGE_DB.GOVERNANCE.DATA_CLASSIFICATION = 'RESTRICTED',
      TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE = 'SSN',
      TAG MORTGAGE_DB.GOVERNANCE.REGULATORY_SCOPE = 'GLBA';

-- Tag borrower name columns
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN BORROWER_NAME
  SET TAG MORTGAGE_DB.GOVERNANCE.DATA_CLASSIFICATION = 'CONFIDENTIAL',
      TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE = 'NAME',
      TAG MORTGAGE_DB.GOVERNANCE.REGULATORY_SCOPE = 'CCPA';

-- Tag income columns
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN BORROWER_INCOME
  SET TAG MORTGAGE_DB.GOVERNANCE.DATA_CLASSIFICATION = 'CONFIDENTIAL',
      TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE = 'INCOME',
      TAG MORTGAGE_DB.GOVERNANCE.REGULATORY_SCOPE = 'HMDA';

-- Tag property address
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_DETAIL
  MODIFY COLUMN PROPERTY_ADDRESS
  SET TAG MORTGAGE_DB.GOVERNANCE.DATA_CLASSIFICATION = 'CONFIDENTIAL',
      TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE = 'ADDRESS',
      TAG MORTGAGE_DB.GOVERNANCE.REGULATORY_SCOPE = 'CCPA';

-- Bulk-tag additional tables
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_ORIGINATION
  MODIFY COLUMN BORROWER_SSN
  SET TAG MORTGAGE_DB.GOVERNANCE.DATA_CLASSIFICATION = 'RESTRICTED',
      TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE = 'SSN',
      TAG MORTGAGE_DB.GOVERNANCE.REGULATORY_SCOPE = 'GLBA';

ALTER TABLE MORTGAGE_DB.RAW.SERVICER_REMITTANCE
  MODIFY COLUMN BORROWER_ACCOUNT_NUM
  SET TAG MORTGAGE_DB.GOVERNANCE.DATA_CLASSIFICATION = 'RESTRICTED',
      TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE = 'ACCOUNT_NUMBER',
      TAG MORTGAGE_DB.GOVERNANCE.REGULATORY_SCOPE = 'GLBA';
```

Query the tag references for audit reporting:

```sql
-- Generate PII inventory report for auditors
SELECT
    TAG_DATABASE,
    TAG_SCHEMA,
    TAG_NAME,
    TAG_VALUE,
    OBJECT_DATABASE,
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COLUMN_NAME,
    DOMAIN
FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE TAG_NAME IN ('DATA_CLASSIFICATION', 'PII_TYPE', 'REGULATORY_SCOPE')
  AND DOMAIN = 'COLUMN'
ORDER BY TAG_VALUE, OBJECT_NAME, COLUMN_NAME;
```

Use tag-based masking policy application:

```sql
-- Associate masking policy with tag (applies to ALL columns with the tag)
ALTER TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE
  SET MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_SSN
  FOR TAG VALUE 'SSN';

ALTER TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE
  SET MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_BORROWER_NAME
  FOR TAG VALUE 'NAME';

ALTER TAG MORTGAGE_DB.GOVERNANCE.PII_TYPE
  SET MASKING POLICY MORTGAGE_DB.GOVERNANCE.MASK_INCOME
  FOR TAG VALUE 'INCOME';
```

**Result:** 847 PII columns across 400+ tables are now tagged and tracked in the Snowflake metadata layer. Tag-based masking automatically applies the correct masking policy when new columns are tagged — no per-column ALTER needed. The audit PII inventory report generates in seconds instead of the 2-week manual process. Regulatory compliance posture improved from "partial documentation" to "fully automated and verifiable."

**AI Vision:** An automated PII discovery engine using NLP and pattern recognition could scan untagged columns (analyzing column names, sample data patterns, and data distributions) and suggest appropriate tags — catching PII that was missed during manual classification.

---

### Q25. How do you consume CoreLogic property data from Snowflake Marketplace?

**Situation:** Freddie Mac's credit risk team needs property valuation data (automated valuation models, comparable sales, property characteristics) to recalculate current LTV ratios for their loan portfolio. CoreLogic publishes this data on the Snowflake Marketplace, eliminating the need for traditional data vendor file transfers.

**Task:** Subscribe to the CoreLogic property data listing on Snowflake Marketplace, create a shared database, and join it with internal loan data to compute current LTV estimates.

**Action:**
After requesting and being approved for the CoreLogic listing in Snowsight Marketplace UI, create the shared database:

```sql
-- This is done via Snowsight UI typically, but the resulting object is:
-- A read-only database created from the provider's share
-- Example name after mounting:
-- CORELOGIC_PROPERTY_DATA

-- Verify available schemas and tables
SHOW SCHEMAS IN DATABASE CORELOGIC_PROPERTY_DATA;
SHOW TABLES IN SCHEMA CORELOGIC_PROPERTY_DATA.PROPERTY_ANALYTICS;
```

Explore the CoreLogic data:

```sql
-- Property valuation data
SELECT *
FROM CORELOGIC_PROPERTY_DATA.PROPERTY_ANALYTICS.AVM_VALUATIONS
LIMIT 10;

-- Property characteristics
SELECT *
FROM CORELOGIC_PROPERTY_DATA.PROPERTY_ANALYTICS.PROPERTY_ATTRIBUTES
WHERE STATE = 'CA' AND COUNTY = 'LOS ANGELES'
LIMIT 10;
```

Join with internal loan data to compute current LTV:

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.ANALYTICS.LOAN_CURRENT_LTV AS
SELECT
    l.LOAN_ID,
    l.POOL_ID,
    l.ORIGINATION_DATE,
    l.ORIGINAL_UPB,
    l.CURRENT_UPB,
    l.ORIGINAL_APPRAISED_VALUE,
    l.ORIGINAL_LTV,
    l.PROPERTY_STATE,
    l.PROPERTY_ZIP,
    cl.AVM_VALUE AS CURRENT_PROPERTY_VALUE,
    cl.AVM_CONFIDENCE_SCORE,
    cl.AVM_AS_OF_DATE,
    cl.LAST_SALE_PRICE,
    cl.LAST_SALE_DATE,
    -- Compute current LTV
    ROUND(l.CURRENT_UPB / NULLIF(cl.AVM_VALUE, 0) * 100, 2)
        AS CURRENT_LTV,
    -- Compute LTV change
    ROUND(l.CURRENT_UPB / NULLIF(cl.AVM_VALUE, 0) * 100, 2) - l.ORIGINAL_LTV
        AS LTV_CHANGE,
    -- Flag underwater loans
    CASE
        WHEN l.CURRENT_UPB / NULLIF(cl.AVM_VALUE, 0) > 1.0 THEN TRUE
        ELSE FALSE
    END AS IS_UNDERWATER
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE l
LEFT JOIN CORELOGIC_PROPERTY_DATA.PROPERTY_ANALYTICS.AVM_VALUATIONS cl
    ON l.PROPERTY_FIPS = cl.FIPS_CODE
    AND l.PROPERTY_APN = cl.APN
    AND cl.AVM_AS_OF_DATE = (
        SELECT MAX(AVM_AS_OF_DATE)
        FROM CORELOGIC_PROPERTY_DATA.PROPERTY_ANALYTICS.AVM_VALUATIONS cl2
        WHERE cl2.FIPS_CODE = cl.FIPS_CODE AND cl2.APN = cl.APN
    )
WHERE l.REPORTING_PERIOD = '2025-06-01'
  AND l.CURRENT_UPB > 0;
```

Build a risk summary using the enriched data:

```sql
SELECT
    PROPERTY_STATE,
    COUNT(*) AS LOAN_COUNT,
    SUM(CURRENT_UPB) AS TOTAL_UPB,
    AVG(CURRENT_LTV) AS AVG_CURRENT_LTV,
    AVG(LTV_CHANGE) AS AVG_LTV_CHANGE,
    COUNT_IF(IS_UNDERWATER) AS UNDERWATER_COUNT,
    COUNT_IF(IS_UNDERWATER) / COUNT(*) * 100 AS PCT_UNDERWATER,
    AVG(AVM_CONFIDENCE_SCORE) AS AVG_AVM_CONFIDENCE
FROM MORTGAGE_DB.ANALYTICS.LOAN_CURRENT_LTV
GROUP BY PROPERTY_STATE
HAVING COUNT(*) > 1000
ORDER BY PCT_UNDERWATER DESC;
```

**Result:** CoreLogic property data is now available with zero ETL — no file transfers, no staging tables, no refresh jobs. The current LTV calculation covers 8.5 million active loans matched against CoreLogic's AVM database. The join completes in 6 minutes. Identified 42,000 loans (0.5%) that are currently underwater based on latest AVM values, enabling proactive credit risk management. Data vendor file delivery infrastructure was decommissioned, saving $150K/year in transfer and processing costs.

**AI Vision:** A home price forecasting model could combine CoreLogic's historical property data with macroeconomic indicators to project property values 12-24 months forward, enabling the credit risk team to estimate future LTV distributions under stress scenarios and adjust capital reserves proactively.

---

### Q26. How do you use Snowpipe with auto-ingest to load loan files from S3 automatically?

**Situation:** Fannie Mae delivers daily loan-level files (CSV, ~5GB each) to an S3 bucket `s3://fnma-loan-delivery/daily/`. The operations team wants these files loaded into `MORTGAGE_DB.STAGING.LOAN_ACQUISITION` within minutes of arrival, without manual intervention or scheduled batch jobs that introduce latency.

**Task:** Configure Snowpipe with auto-ingest so that S3 event notifications trigger automatic loading of loan files as soon as they land in the bucket, eliminating the need for COPY INTO schedules and reducing data freshness lag from hours to minutes.

**Action:**
First, create the external stage pointing to S3:

```sql
USE DATABASE MORTGAGE_DB;
USE SCHEMA STAGING;

CREATE OR REPLACE STAGE FNMA_DAILY_STAGE
  URL = 's3://fnma-loan-delivery/daily/'
  STORAGE_INTEGRATION = FNMA_S3_INTEGRATION
  FILE_FORMAT = (
      TYPE = 'CSV'
      FIELD_DELIMITER = '|'
      SKIP_HEADER = 1
      NULL_IF = ('')
      FIELD_OPTIONALLY_ENCLOSED_BY = '"'
      DATE_FORMAT = 'MM/DD/YYYY'
      ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  )
  COMMENT = 'Fannie Mae daily loan acquisition file delivery bucket';
```

Create the Snowpipe with auto-ingest enabled:

```sql
CREATE OR REPLACE PIPE MORTGAGE_DB.STAGING.FNMA_LOAN_ACQUISITION_PIPE
  AUTO_INGEST = TRUE
  ERROR_INTEGRATION = LOAN_PIPELINE_ERRORS_SNS
  COMMENT = 'Auto-ingest pipe for Fannie Mae daily loan acquisition files'
AS
COPY INTO MORTGAGE_DB.STAGING.LOAN_ACQUISITION (
    LOAN_ID, ORIGINATION_DATE, SELLER_NAME, ORIGINAL_UPB,
    ORIGINAL_INTEREST_RATE, ORIGINAL_LOAN_TERM, LTV, CLTV, DTI,
    BORROWER_CREDIT_SCORE, PROPERTY_STATE, PROPERTY_TYPE,
    LOAN_PURPOSE, NUMBER_OF_UNITS, OCCUPANCY_STATUS
)
FROM @FNMA_DAILY_STAGE
FILE_FORMAT = (FORMAT_NAME = 'FNMA_PIPE_DELIMITED')
ON_ERROR = 'SKIP_FILE';
```

Retrieve the SQS queue ARN to configure S3 event notifications:

```sql
SHOW PIPES LIKE 'FNMA_LOAN_ACQUISITION_PIPE' IN SCHEMA MORTGAGE_DB.STAGING;
-- Note the notification_channel column — this is the SQS ARN
-- Configure S3 bucket event notification to send to this SQS queue
```

Monitor pipe status and load history:

```sql
-- Check current pipe status
SELECT SYSTEM$PIPE_STATUS('MORTGAGE_DB.STAGING.FNMA_LOAN_ACQUISITION_PIPE');

-- Review load history for the past 24 hours
SELECT
    FILE_NAME,
    STAGE_LOCATION,
    ROW_COUNT,
    ROW_PARSED,
    ERROR_COUNT,
    FIRST_ERROR_MESSAGE,
    PIPE_RECEIVED_TIME,
    LAST_LOAD_TIME,
    DATEDIFF('second', PIPE_RECEIVED_TIME, LAST_LOAD_TIME) AS LOAD_LATENCY_SEC
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'MORTGAGE_DB.STAGING.LOAN_ACQUISITION',
    START_TIME => DATEADD('hours', -24, CURRENT_TIMESTAMP())
))
ORDER BY PIPE_RECEIVED_TIME DESC;
```

**Result:** Loan acquisition files are loaded within 2-3 minutes of landing in S3. The operations team eliminated a cron-based COPY INTO job that ran every 30 minutes. The error integration sends SNS alerts when files fail to load, enabling rapid triage. Average daily throughput is 15 million rows across 3 files, all auto-ingested without human intervention.

**AI Vision:** An anomaly detection model could monitor Snowpipe load metrics — file sizes, row counts, arrival times — and flag deviations such as missing files, unexpected file sizes, or late deliveries that may indicate upstream data pipeline failures at Fannie Mae.

---

### Q27. How do you use Time Travel for auditing to query historical loan states at specific timestamps?

**Situation:** Freddie Mac's risk management team needs to audit what the loan performance data looked like at a specific point in time — for example, the exact state of all loans as of the end of Q2 2025 — to reconcile reports submitted to regulators. The data in `MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT` is continuously updated, so the current state no longer reflects what was reported.

**Task:** Use Snowflake Time Travel to query the table as it existed at a specific timestamp, enabling auditors to reproduce historical states without maintaining separate snapshot tables or complex SCD logic.

**Action:**
Query the table as it existed at a specific timestamp using the AT clause:

```sql
-- Query loan performance as of end of Q2 2025 reporting
SELECT
    LOAN_ID,
    REPORTING_PERIOD,
    CURRENT_UPB,
    DELINQUENCY_STATUS,
    LOAN_AGE,
    ZERO_BALANCE_CODE,
    MODIFICATION_FLAG
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
    AT(TIMESTAMP => '2025-06-30 23:59:59'::TIMESTAMP_NTZ)
WHERE REPORTING_PERIOD = '2025-06-01'
ORDER BY LOAN_ID;
```

Compare current state to the historical state to identify retroactive changes:

```sql
SELECT
    curr.LOAN_ID,
    curr.REPORTING_PERIOD,
    hist.DELINQUENCY_STATUS AS STATUS_AS_REPORTED,
    curr.DELINQUENCY_STATUS AS STATUS_CURRENT,
    hist.CURRENT_UPB AS UPB_AS_REPORTED,
    curr.CURRENT_UPB AS UPB_CURRENT,
    ABS(curr.CURRENT_UPB - hist.CURRENT_UPB) AS UPB_DIFFERENCE
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT AS curr
JOIN MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
    AT(TIMESTAMP => '2025-06-30 23:59:59'::TIMESTAMP_NTZ) AS hist
    ON curr.LOAN_ID = hist.LOAN_ID
    AND curr.REPORTING_PERIOD = hist.REPORTING_PERIOD
WHERE curr.REPORTING_PERIOD = '2025-06-01'
  AND (curr.DELINQUENCY_STATUS != hist.DELINQUENCY_STATUS
       OR ABS(curr.CURRENT_UPB - hist.CURRENT_UPB) > 0.01);
```

Use the BEFORE clause with a specific query ID for precise auditing:

```sql
-- Query the table state just before a known problematic ETL run
SELECT COUNT(*) AS LOAN_COUNT, SUM(CURRENT_UPB) AS TOTAL_UPB
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
    BEFORE(STATEMENT => '01b2e3f4-0001-a8c2-0000-00050001b0a2');
```

**Result:** Auditors confirmed that 1,247 loans had retroactive delinquency status corrections applied after the Q2 2025 regulatory filing. The Time Travel comparison report was provided to compliance within an hour, versus the 2-3 days it previously took using archived backup files. The 90-day retention window covers the full regulatory audit cycle.

**AI Vision:** An automated reconciliation engine could run nightly comparisons between the current table state and the state as of the last regulatory filing date, using ML classification to categorize changes as corrections, late-arriving data, or potential errors requiring human review.

---

### Q28. How do you use UNDROP to recover accidentally dropped loan tables?

**Situation:** A junior data engineer on the Ginnie Mae MBS analytics team accidentally executed `DROP TABLE MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS` during a schema cleanup script. This table contains 5 years of monthly pool factor data for all Ginnie Mae II MBS pools — roughly 120 million rows — and is critical for next-day investor reporting.

**Task:** Recover the dropped table immediately using Snowflake's UNDROP capability, and implement safeguards to prevent accidental drops in the future.

**Action:**
Recover the table using UNDROP:

```sql
-- Immediately recover the dropped table
UNDROP TABLE MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS;

-- Verify the table is restored with full data
SELECT
    COUNT(*) AS TOTAL_ROWS,
    MIN(REPORTING_PERIOD) AS EARLIEST_PERIOD,
    MAX(REPORTING_PERIOD) AS LATEST_PERIOD,
    COUNT(DISTINCT POOL_ID) AS UNIQUE_POOLS
FROM MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS;
-- Expected: ~120M rows, spanning 2020-01 to 2025-06, ~85K pools
```

If the table name was reused (a new table created with the same name), rename first:

```sql
-- If a replacement table was already created with the same name
ALTER TABLE MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS
    RENAME TO MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS_TEMP;

-- Now undrop the original
UNDROP TABLE MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS;

-- Verify and drop the temp table if not needed
DROP TABLE MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS_TEMP;
```

Implement safeguards to prevent future accidental drops:

```sql
-- Protect critical tables with restrictive grants
REVOKE ALL ON TABLE MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS
    FROM ROLE DATA_ENGINEER_JUNIOR;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON TABLE MORTGAGE_DB.ANALYTICS.GINNIE_POOL_FACTORS
    TO ROLE DATA_ENGINEER_JUNIOR;
-- DROP requires OWNERSHIP, which juniors should not have

-- Also works for schemas and databases
-- UNDROP SCHEMA MORTGAGE_DB.ANALYTICS;
-- UNDROP DATABASE MORTGAGE_DB;
```

**Result:** The table was fully restored within 30 seconds, including all 120 million rows and associated grants. Investor reporting proceeded on schedule with zero data loss. The incident prompted a policy change: OWNERSHIP on production tables is now restricted to a dedicated `PROD_ADMIN` role, and all DROP operations in production require a two-person approval workflow.

**AI Vision:** A governance bot could monitor the Snowflake query history for DROP statements on production schemas, automatically alerting the team lead and logging the event in a compliance tracker, while also recommending whether UNDROP is still available based on the table's retention period.

---

### Q29. How do you manage Time Travel data retention and storage costs for large loan datasets?

**Situation:** The `MORTGAGE_DB` database contains 40+ tables with Fannie Mae and Freddie Mac loan-level data, totaling 8 TB of active storage. With the default 1-day Time Travel retention plus 7-day Fail-safe, the total storage footprint has ballooned to 35 TB, costing over $40K/month. Not all tables require the same retention — staging tables are ephemeral, while production analytics tables need full audit trails.

**Task:** Implement a tiered retention strategy that balances audit and recovery needs against storage costs, reducing the overall storage footprint while maintaining appropriate protection for critical loan data.

**Action:**
Analyze current storage costs by table:

```sql
-- Identify biggest storage consumers including Time Travel and Fail-safe
SELECT
    TABLE_CATALOG,
    TABLE_SCHEMA,
    TABLE_NAME,
    ROW_COUNT,
    ROUND(BYTES / POWER(1024, 3), 2) AS ACTIVE_GB,
    ROUND(TIME_TRAVEL_BYTES / POWER(1024, 3), 2) AS TIME_TRAVEL_GB,
    ROUND(FAILSAFE_BYTES / POWER(1024, 3), 2) AS FAILSAFE_GB,
    ROUND((BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES) / POWER(1024, 3), 2) AS TOTAL_GB,
    RETENTION_TIME
FROM MORTGAGE_DB.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE CATALOG_DROPPED IS NULL
ORDER BY TOTAL_GB DESC
LIMIT 20;
```

Apply tiered retention based on table criticality:

```sql
-- Tier 1: Production analytics tables — 90-day retention (Enterprise edition)
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
    SET DATA_RETENTION_TIME_IN_DAYS = 90;
ALTER TABLE MORTGAGE_DB.ANALYTICS.POOL_MONTHLY_FACTORS
    SET DATA_RETENTION_TIME_IN_DAYS = 90;

-- Tier 2: Curated reporting tables — 14-day retention
ALTER TABLE MORTGAGE_DB.REPORTING.MONTHLY_DELINQUENCY_SUMMARY
    SET DATA_RETENTION_TIME_IN_DAYS = 14;
ALTER TABLE MORTGAGE_DB.REPORTING.POOL_PERFORMANCE_DASHBOARD
    SET DATA_RETENTION_TIME_IN_DAYS = 14;

-- Tier 3: Staging and temp tables — 0-day retention (no Time Travel)
ALTER TABLE MORTGAGE_DB.STAGING.LOAN_ACQUISITION_RAW
    SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER TABLE MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_RAW
    SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- Set schema-level defaults for new tables
ALTER SCHEMA MORTGAGE_DB.STAGING
    SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER SCHEMA MORTGAGE_DB.ANALYTICS
    SET DATA_RETENTION_TIME_IN_DAYS = 90;
ALTER SCHEMA MORTGAGE_DB.REPORTING
    SET DATA_RETENTION_TIME_IN_DAYS = 14;
```

Use transient tables for intermediate processing:

```sql
-- Transient tables have no Fail-safe period, saving 7 days of storage
CREATE OR REPLACE TRANSIENT TABLE MORTGAGE_DB.STAGING.LOAN_PERF_DAILY_LOAD (
    LOAN_ID VARCHAR(20),
    REPORTING_PERIOD DATE,
    CURRENT_UPB NUMBER(14,2),
    DELINQUENCY_STATUS VARCHAR(3),
    LOAD_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
DATA_RETENTION_TIME_IN_DAYS = 1;
```

**Result:** Storage costs dropped from $40K/month to $18K/month — a 55% reduction. Staging tables accounted for 60% of the Time Travel storage but had zero audit requirements. Critical production tables retained full 90-day Time Travel for regulatory compliance. The tiered strategy was documented and enforced via a Terraform module that sets retention based on schema naming conventions.

**AI Vision:** A cost optimization model could analyze table access patterns, change frequency, and regulatory requirements to automatically recommend optimal retention periods per table, projecting monthly savings and flagging tables where retention is misaligned with actual usage.

---

### Q30. How do you create table streams on views for CDC on complex loan analytics views?

**Situation:** The Freddie Mac analytics team has a complex view `MORTGAGE_DB.ANALYTICS.VW_LOAN_RISK_PROFILE` that joins loan performance, borrower credit, and property valuation tables to produce a unified risk profile. Downstream systems need CDC on this derived dataset, but streams can only be created on tables and certain types of views.

**Task:** Create a stream on a materialized or secure view to capture changes in the derived loan risk profile, enabling incremental processing of the complex joined dataset without re-scanning all source tables.

**Action:**
First, create the underlying view (streams on views require the view to be on a single table, or you use a dynamic table):

```sql
-- Option 1: Create a stream-compatible view on a single base table
-- with the complex logic expressed in the stream consumer
CREATE OR REPLACE VIEW MORTGAGE_DB.ANALYTICS.VW_LOAN_PERFORMANCE_BASE AS
SELECT
    lp.LOAN_ID,
    lp.REPORTING_PERIOD,
    lp.CURRENT_UPB,
    lp.DELINQUENCY_STATUS,
    lp.LOAN_AGE,
    lp.ZERO_BALANCE_CODE,
    lp.MODIFICATION_FLAG,
    lp.CURRENT_INTEREST_RATE
FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE lp
WHERE lp.REPORTING_PERIOD >= '2023-01-01';

-- Create stream on the view
CREATE OR REPLACE STREAM MORTGAGE_DB.ANALYTICS.LOAN_RISK_STREAM
    ON VIEW MORTGAGE_DB.ANALYTICS.VW_LOAN_PERFORMANCE_BASE
    APPEND_ONLY = FALSE
    SHOW_INITIAL_ROWS = FALSE
    COMMENT = 'CDC stream on loan performance view for risk profile updates';
```

Option 2 — use a Dynamic Table as the CDC source for complex joins:

```sql
-- Dynamic Table auto-refreshes the joined result
CREATE OR REPLACE DYNAMIC TABLE MORTGAGE_DB.ANALYTICS.DT_LOAN_RISK_PROFILE
    TARGET_LAG = '30 minutes'
    WAREHOUSE = ANALYTICS_WH
AS
SELECT
    lp.LOAN_ID,
    lp.REPORTING_PERIOD,
    lp.CURRENT_UPB,
    lp.DELINQUENCY_STATUS,
    b.CREDIT_SCORE_CURRENT,
    b.DTI_RATIO,
    p.AVM_VALUE,
    ROUND(lp.CURRENT_UPB / NULLIF(p.AVM_VALUE, 0) * 100, 2) AS CURRENT_LTV,
    CASE
        WHEN lp.DELINQUENCY_STATUS IN ('03','04','05','06') THEN 'SERIOUSLY_DELINQUENT'
        WHEN lp.DELINQUENCY_STATUS IN ('01','02') THEN 'DELINQUENT'
        ELSE 'CURRENT'
    END AS RISK_CATEGORY
FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE lp
LEFT JOIN MORTGAGE_DB.ANALYTICS.BORROWER_CREDIT b ON lp.LOAN_ID = b.LOAN_ID
LEFT JOIN MORTGAGE_DB.ANALYTICS.PROPERTY_VALUATIONS p ON lp.LOAN_ID = p.LOAN_ID;

-- Create stream on the dynamic table
CREATE OR REPLACE STREAM MORTGAGE_DB.ANALYTICS.RISK_PROFILE_CDC_STREAM
    ON DYNAMIC TABLE MORTGAGE_DB.ANALYTICS.DT_LOAN_RISK_PROFILE
    APPEND_ONLY = FALSE
    COMMENT = 'CDC stream on dynamic table for complex risk profile changes';
```

Consume the stream in downstream processing:

```sql
-- Process only changed risk profiles
INSERT INTO MORTGAGE_DB.REPORTING.RISK_ALERTS
SELECT
    LOAN_ID,
    REPORTING_PERIOD,
    RISK_CATEGORY,
    CURRENT_LTV,
    CURRENT_TIMESTAMP() AS ALERT_TIMESTAMP,
    'RISK_PROFILE_CHANGE' AS ALERT_TYPE
FROM MORTGAGE_DB.ANALYTICS.RISK_PROFILE_CDC_STREAM
WHERE METADATA$ACTION = 'INSERT'
  AND RISK_CATEGORY = 'SERIOUSLY_DELINQUENT'
  AND CURRENT_LTV > 100;
```

**Result:** The dynamic table refreshes every 30 minutes, and the stream captures only the changed risk profiles — typically 50K-100K rows per cycle versus 12 million in the full joined result. Downstream alert processing dropped from 20 minutes to under 1 minute per cycle. The approach eliminated complex custom CDC logic that previously required tracking source table versions manually.

**AI Vision:** A predictive model could consume the risk profile CDC stream in near-real-time, scoring each changed loan for probability of default within the next 90 days and automatically routing high-risk loans to the loss mitigation team's workflow.

---

### Q31. How do you implement task error handling for managing failures in automated loan pipelines?

**Situation:** The nightly Freddie Mac loan data pipeline in `MORTGAGE_DB` consists of a task tree with 6 tasks: stage loading, deduplication, validation, transformation, aggregation, and reporting. When the validation task fails due to data quality issues, the entire downstream tree halts silently, and the team only discovers the failure the next morning when reports are missing.

**Task:** Implement robust error handling in the task tree so that failures are detected, logged, and alerted on immediately, and downstream tasks behave appropriately when predecessors fail.

**Action:**
Create an error logging table and alert integration:

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.OPS.TASK_ERROR_LOG (
    TASK_NAME VARCHAR,
    ERROR_CODE NUMBER,
    ERROR_MESSAGE VARCHAR,
    ERROR_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    QUERY_ID VARCHAR,
    PIPELINE_RUN_ID VARCHAR
);

CREATE OR REPLACE NOTIFICATION INTEGRATION LOAN_PIPELINE_ALERTS
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('pipeline-alerts@mortgagecorp.com');
```

Wrap task logic in stored procedures with TRY/CATCH:

```sql
CREATE OR REPLACE PROCEDURE MORTGAGE_DB.OPS.SP_VALIDATE_LOAN_DATA(PIPELINE_RUN_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    invalid_count INTEGER;
    error_msg VARCHAR;
BEGIN
    -- Validate critical fields
    SELECT COUNT(*) INTO :invalid_count
    FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_DEDUPED
    WHERE LOAN_ID IS NULL
       OR REPORTING_PERIOD IS NULL
       OR CURRENT_UPB < 0
       OR DELINQUENCY_STATUS NOT IN ('00','01','02','03','04','05','06','RA');

    IF (invalid_count > 1000) THEN
        error_msg := 'Validation failed: ' || invalid_count || ' invalid records exceed threshold of 1000';
        INSERT INTO MORTGAGE_DB.OPS.TASK_ERROR_LOG (TASK_NAME, ERROR_CODE, ERROR_MESSAGE, PIPELINE_RUN_ID)
        VALUES ('VALIDATE_LOAN_DATA', 1001, :error_msg, :PIPELINE_RUN_ID);
        CALL SYSTEM$SEND_EMAIL(
            'LOAN_PIPELINE_ALERTS',
            'pipeline-alerts@mortgagecorp.com',
            'ALERT: Loan Validation Failed - ' || CURRENT_DATE(),
            :error_msg
        );
        RETURN 'FAILED: ' || error_msg;
    END IF;

    -- Quarantine invalid records
    INSERT INTO MORTGAGE_DB.STAGING.LOAN_QUARANTINE
    SELECT *, CURRENT_TIMESTAMP() AS QUARANTINED_AT, :PIPELINE_RUN_ID AS RUN_ID
    FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_DEDUPED
    WHERE LOAN_ID IS NULL OR CURRENT_UPB < 0;

    DELETE FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_DEDUPED
    WHERE LOAN_ID IS NULL OR CURRENT_UPB < 0;

    RETURN 'SUCCESS: ' || invalid_count || ' records quarantined';
EXCEPTION
    WHEN OTHER THEN
        INSERT INTO MORTGAGE_DB.OPS.TASK_ERROR_LOG (TASK_NAME, ERROR_CODE, ERROR_MESSAGE, PIPELINE_RUN_ID)
        VALUES ('VALIDATE_LOAN_DATA', SQLCODE, SQLERRM, :PIPELINE_RUN_ID);
        RETURN 'ERROR: ' || SQLERRM;
END;
$$;
```

Configure the task with error handling:

```sql
CREATE OR REPLACE TASK MORTGAGE_DB.OPS.TASK_VALIDATE_LOANS
    WAREHOUSE = ETL_WH
    AFTER MORTGAGE_DB.OPS.TASK_DEDUPLICATE_LOANS
    WHEN SYSTEM$STREAM_HAS_DATA('MORTGAGE_DB.STAGING.LOAN_PERF_CDC_STREAM')
AS
    CALL MORTGAGE_DB.OPS.SP_VALIDATE_LOAN_DATA(
        TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS')
    );
```

Monitor task execution history:

```sql
SELECT
    NAME,
    STATE,
    ERROR_CODE,
    ERROR_MESSAGE,
    SCHEDULED_TIME,
    COMPLETED_TIME,
    DATEDIFF('minute', SCHEDULED_TIME, COMPLETED_TIME) AS DURATION_MIN
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 50
))
WHERE DATABASE_NAME = 'MORTGAGE_DB'
ORDER BY SCHEDULED_TIME DESC;
```

**Result:** Pipeline failures are now detected within 2 minutes via email alerts, down from 8+ hours. The quarantine pattern isolates bad records without halting the pipeline for minor issues, while the threshold-based abort prevents corrupted data from propagating. Over 3 months, the error log helped identify a recurring upstream data quality issue in Freddie Mac's servicer reporting that was corrected at the source.

**AI Vision:** An ML model trained on historical task error logs could predict pipeline failures before they occur by detecting patterns in upstream data characteristics — such as unusual file sizes, late arrivals, or schema drift — enabling preemptive intervention.

---

### Q32. How do you use JavaScript UDFs for complex waterfall payment calculations?

**Situation:** Intex provides CMO (Collateralized Mortgage Obligation) deal structures where monthly cash flows must be distributed across tranches using waterfall rules — senior tranches receive principal first, then mezzanine, then subordinate. The waterfall logic involves conditional branching, running balances, and iterative allocation that is cumbersome in pure SQL.

**Task:** Implement a JavaScript UDF that computes waterfall payment allocations for a CMO deal, handling the sequential priority of payments across tranches with overcollateralization and interest shortfall rules.

**Action:**
Create a JavaScript UDF for waterfall allocation:

```sql
CREATE OR REPLACE FUNCTION MORTGAGE_DB.ANALYTICS.WATERFALL_ALLOCATION(
    TOTAL_PRINCIPAL FLOAT,
    TOTAL_INTEREST FLOAT,
    TRANCHE_BALANCES ARRAY,
    TRANCHE_COUPONS ARRAY,
    TRANCHE_TYPES ARRAY
)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
COMMENT = 'Allocates CMO cash flows across tranches using sequential waterfall rules'
AS
$$
    var result = [];
    var remainingPrincipal = TOTAL_PRINCIPAL;
    var remainingInterest = TOTAL_INTEREST;
    var numTranches = TRANCHE_BALANCES.length;

    // Phase 1: Allocate interest to all tranches (pro-rata by coupon)
    for (var i = 0; i < numTranches; i++) {
        var interestDue = TRANCHE_BALANCES[i] * (TRANCHE_COUPONS[i] / 12.0);
        var interestPaid = Math.min(interestDue, remainingInterest);
        var interestShortfall = interestDue - interestPaid;
        remainingInterest -= interestPaid;

        result.push({
            tranche_index: i,
            tranche_type: TRANCHE_TYPES[i],
            beginning_balance: TRANCHE_BALANCES[i],
            interest_due: Math.round(interestDue * 100) / 100,
            interest_paid: Math.round(interestPaid * 100) / 100,
            interest_shortfall: Math.round(interestShortfall * 100) / 100,
            principal_paid: 0,
            ending_balance: TRANCHE_BALANCES[i]
        });
    }

    // Phase 2: Allocate principal sequentially (senior-first)
    for (var i = 0; i < numTranches; i++) {
        if (TRANCHE_TYPES[i] === 'SEQUENTIAL' || TRANCHE_TYPES[i] === 'SENIOR') {
            var principalCapacity = result[i].beginning_balance;
            var principalPaid = Math.min(principalCapacity, remainingPrincipal);
            result[i].principal_paid = Math.round(principalPaid * 100) / 100;
            result[i].ending_balance = Math.round(
                (result[i].beginning_balance - principalPaid) * 100
            ) / 100;
            remainingPrincipal -= principalPaid;
        }
    }

    // Phase 3: Remaining principal to subordinate tranches
    for (var i = 0; i < numTranches; i++) {
        if (TRANCHE_TYPES[i] === 'SUBORDINATE' || TRANCHE_TYPES[i] === 'MEZZANINE') {
            var principalCapacity = result[i].beginning_balance;
            var principalPaid = Math.min(principalCapacity, remainingPrincipal);
            result[i].principal_paid = Math.round(principalPaid * 100) / 100;
            result[i].ending_balance = Math.round(
                (result[i].beginning_balance - principalPaid) * 100
            ) / 100;
            remainingPrincipal -= principalPaid;
        }
    }

    return {
        allocations: result,
        excess_principal: Math.round(remainingPrincipal * 100) / 100,
        excess_interest: Math.round(remainingInterest * 100) / 100
    };
$$;
```

Use the UDF in deal cash flow analysis:

```sql
SELECT
    d.DEAL_ID,
    d.REPORTING_PERIOD,
    d.TOTAL_PRINCIPAL_COLLECTED,
    d.TOTAL_INTEREST_COLLECTED,
    MORTGAGE_DB.ANALYTICS.WATERFALL_ALLOCATION(
        d.TOTAL_PRINCIPAL_COLLECTED,
        d.TOTAL_INTEREST_COLLECTED,
        ARRAY_CONSTRUCT(t.A1_BALANCE, t.A2_BALANCE, t.M1_BALANCE, t.B1_BALANCE),
        ARRAY_CONSTRUCT(t.A1_COUPON, t.A2_COUPON, t.M1_COUPON, t.B1_COUPON),
        ARRAY_CONSTRUCT('SENIOR', 'SENIOR', 'MEZZANINE', 'SUBORDINATE')
    ) AS WATERFALL_RESULT,
    WATERFALL_RESULT:allocations[0]:principal_paid::FLOAT AS A1_PRINCIPAL,
    WATERFALL_RESULT:allocations[0]:ending_balance::FLOAT AS A1_ENDING_BAL,
    WATERFALL_RESULT:excess_principal::FLOAT AS EXCESS_PRINCIPAL
FROM MORTGAGE_DB.ANALYTICS.DEAL_MONTHLY_CASHFLOWS d
JOIN MORTGAGE_DB.ANALYTICS.TRANCHE_BALANCES t
    ON d.DEAL_ID = t.DEAL_ID AND d.REPORTING_PERIOD = t.REPORTING_PERIOD
WHERE d.DEAL_ID = 'FNR-2024-C05'
ORDER BY d.REPORTING_PERIOD;
```

**Result:** The JavaScript UDF replaced 400+ lines of nested SQL CASE statements with a maintainable 60-line function. Waterfall calculations for a 500-deal portfolio (36 months each) complete in 45 seconds. The UDF output as VARIANT allows flexible extraction of per-tranche results, and the logic matches Intex's cashflow engine output to within $0.01 per tranche per period.

**AI Vision:** A reinforcement learning model could simulate various prepayment and default scenarios through the waterfall UDF, optimizing tranche structuring decisions for new CMO deals by maximizing senior tranche credit enhancement while minimizing subordinate tranche required yield.

---

### Q33. How do you use SQL UDTFs to generate loan amortization schedules?

**Situation:** The Fannie Mae loan servicing analytics team needs to generate projected amortization schedules for individual loans — showing monthly principal, interest, and remaining balance for the full remaining term. Generating these row-by-row schedules for millions of loans requires a table-valued function that emits multiple rows per input loan.

**Task:** Create a SQL UDTF (User-Defined Table Function) that takes loan parameters as input and returns a complete amortization schedule as a multi-row result set, enabling set-based amortization analysis across the entire portfolio.

**Action:**
Create the UDTF for amortization schedule generation:

```sql
CREATE OR REPLACE FUNCTION MORTGAGE_DB.ANALYTICS.GENERATE_AMORTIZATION(
    LOAN_ID_INPUT VARCHAR,
    CURRENT_UPB_INPUT FLOAT,
    INTEREST_RATE_ANNUAL FLOAT,
    REMAINING_TERM_MONTHS INTEGER
)
RETURNS TABLE (
    LOAN_ID VARCHAR,
    PAYMENT_NUMBER INTEGER,
    PAYMENT_DATE DATE,
    BEGINNING_BALANCE FLOAT,
    MONTHLY_PAYMENT FLOAT,
    PRINCIPAL_PORTION FLOAT,
    INTEREST_PORTION FLOAT,
    ENDING_BALANCE FLOAT,
    CUMULATIVE_INTEREST FLOAT
)
LANGUAGE SQL
COMMENT = 'Generates a full amortization schedule for a given loan'
AS
$$
    WITH RECURSIVE AMORT AS (
        -- Base case: first payment
        SELECT
            LOAN_ID_INPUT AS LOAN_ID,
            1 AS PAYMENT_NUMBER,
            DATEADD('month', 1, CURRENT_DATE()) AS PAYMENT_DATE,
            CURRENT_UPB_INPUT AS BEGINNING_BALANCE,
            ROUND(CURRENT_UPB_INPUT *
                (INTEREST_RATE_ANNUAL / 1200.0) *
                POWER(1 + INTEREST_RATE_ANNUAL / 1200.0, REMAINING_TERM_MONTHS) /
                (POWER(1 + INTEREST_RATE_ANNUAL / 1200.0, REMAINING_TERM_MONTHS) - 1)
            , 2) AS MONTHLY_PAYMENT,
            ROUND(CURRENT_UPB_INPUT *
                (INTEREST_RATE_ANNUAL / 1200.0) *
                POWER(1 + INTEREST_RATE_ANNUAL / 1200.0, REMAINING_TERM_MONTHS) /
                (POWER(1 + INTEREST_RATE_ANNUAL / 1200.0, REMAINING_TERM_MONTHS) - 1)
                - CURRENT_UPB_INPUT * (INTEREST_RATE_ANNUAL / 1200.0)
            , 2) AS PRINCIPAL_PORTION,
            ROUND(CURRENT_UPB_INPUT * (INTEREST_RATE_ANNUAL / 1200.0), 2) AS INTEREST_PORTION,
            ROUND(CURRENT_UPB_INPUT -
                (CURRENT_UPB_INPUT *
                (INTEREST_RATE_ANNUAL / 1200.0) *
                POWER(1 + INTEREST_RATE_ANNUAL / 1200.0, REMAINING_TERM_MONTHS) /
                (POWER(1 + INTEREST_RATE_ANNUAL / 1200.0, REMAINING_TERM_MONTHS) - 1)
                - CURRENT_UPB_INPUT * (INTEREST_RATE_ANNUAL / 1200.0))
            , 2) AS ENDING_BALANCE,
            ROUND(CURRENT_UPB_INPUT * (INTEREST_RATE_ANNUAL / 1200.0), 2) AS CUMULATIVE_INTEREST
        UNION ALL
        -- Recursive case
        SELECT
            LOAN_ID,
            PAYMENT_NUMBER + 1,
            DATEADD('month', 1, PAYMENT_DATE),
            ENDING_BALANCE,
            MONTHLY_PAYMENT,
            ROUND(MONTHLY_PAYMENT - ENDING_BALANCE * (INTEREST_RATE_ANNUAL / 1200.0), 2),
            ROUND(ENDING_BALANCE * (INTEREST_RATE_ANNUAL / 1200.0), 2),
            ROUND(ENDING_BALANCE - (MONTHLY_PAYMENT - ENDING_BALANCE * (INTEREST_RATE_ANNUAL / 1200.0)), 2),
            ROUND(CUMULATIVE_INTEREST + ENDING_BALANCE * (INTEREST_RATE_ANNUAL / 1200.0), 2)
        FROM AMORT
        WHERE PAYMENT_NUMBER < REMAINING_TERM_MONTHS
          AND ENDING_BALANCE > 0.01
    )
    SELECT * FROM AMORT
$$;
```

Use the UDTF to generate schedules for individual loans and portfolio analysis:

```sql
-- Single loan amortization
SELECT * FROM TABLE(MORTGAGE_DB.ANALYTICS.GENERATE_AMORTIZATION(
    'FN-2024-001234', 250000.00, 6.75, 348
));

-- Portfolio-level: generate schedules for all active loans in a pool
SELECT a.*
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT lp,
    TABLE(MORTGAGE_DB.ANALYTICS.GENERATE_AMORTIZATION(
        lp.LOAN_ID, lp.CURRENT_UPB, lp.CURRENT_INTEREST_RATE, lp.REMAINING_MONTHS
    )) a
WHERE lp.POOL_ID = 'FN-MA4567'
  AND lp.CURRENT_UPB > 0
  AND lp.ZERO_BALANCE_CODE IS NULL;
```

**Result:** The UDTF generates accurate amortization schedules matching standard mortgage math to the penny. For a pool of 5,000 active loans with an average 280 remaining months, the full schedule generation (1.4 million output rows) completes in 90 seconds on an XS warehouse. This replaced a Python-based batch process that took 25 minutes and required exporting data from Snowflake.

**AI Vision:** A prepayment model could overlay the projected amortization schedules with loan-level prepayment speed predictions (PSA multiples) derived from borrower and property characteristics, producing scenario-adjusted cash flow projections for MBS pricing.

---

### Q34. How do you implement stored procedure error handling with TRY/CATCH patterns for loan ETL?

**Situation:** The nightly Ginnie Mae loan ETL in `MORTGAGE_DB` loads data from multiple servicers, each with slightly different file formats and quality levels. A single bad servicer file should not abort the entire pipeline — failed servicer loads need to be logged and skipped while the remaining servicers proceed normally.

**Task:** Build a stored procedure with comprehensive TRY/CATCH error handling that processes each servicer file independently, logs failures with full context, and produces a summary report of successes and failures.

**Action:**
Create a stored procedure with per-servicer error isolation:

```sql
CREATE OR REPLACE PROCEDURE MORTGAGE_DB.OPS.SP_LOAD_SERVICER_FILES(
    REPORTING_PERIOD DATE,
    DRY_RUN BOOLEAN DEFAULT FALSE
)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    servicer_cursor CURSOR FOR
        SELECT SERVICER_ID, SERVICER_NAME, FILE_PATH
        FROM MORTGAGE_DB.OPS.SERVICER_FILE_MANIFEST
        WHERE REPORTING_PERIOD = :REPORTING_PERIOD
          AND STATUS = 'PENDING';
    v_servicer_id VARCHAR;
    v_servicer_name VARCHAR;
    v_file_path VARCHAR;
    v_rows_loaded INTEGER DEFAULT 0;
    v_success_count INTEGER DEFAULT 0;
    v_failure_count INTEGER DEFAULT 0;
    v_results ARRAY DEFAULT ARRAY_CONSTRUCT();
BEGIN
    FOR record IN servicer_cursor DO
        v_servicer_id := record.SERVICER_ID;
        v_servicer_name := record.SERVICER_NAME;
        v_file_path := record.FILE_PATH;

        BEGIN
            -- Attempt to load the servicer file
            EXECUTE IMMEDIATE '
                COPY INTO MORTGAGE_DB.STAGING.GNMA_LOAN_PERFORMANCE
                FROM @MORTGAGE_DB.STAGING.GNMA_SERVICER_STAGE/' || :v_file_path || '
                FILE_FORMAT = (FORMAT_NAME = MORTGAGE_DB.STAGING.GNMA_PIPE_FORMAT)
                ON_ERROR = ABORT_STATEMENT
                PURGE = FALSE
            ';

            -- Update manifest status
            UPDATE MORTGAGE_DB.OPS.SERVICER_FILE_MANIFEST
            SET STATUS = 'LOADED',
                LOADED_AT = CURRENT_TIMESTAMP(),
                ROWS_LOADED = (SELECT COUNT(*) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())))
            WHERE SERVICER_ID = :v_servicer_id
              AND REPORTING_PERIOD = :REPORTING_PERIOD;

            v_success_count := v_success_count + 1;
            v_results := ARRAY_APPEND(v_results,
                OBJECT_CONSTRUCT('servicer', v_servicer_name, 'status', 'SUCCESS'));

        EXCEPTION
            WHEN OTHER THEN
                -- Log the failure
                INSERT INTO MORTGAGE_DB.OPS.TASK_ERROR_LOG
                    (TASK_NAME, ERROR_CODE, ERROR_MESSAGE, PIPELINE_RUN_ID)
                VALUES (
                    'LOAD_SERVICER_' || :v_servicer_id,
                    SQLCODE,
                    SQLERRM,
                    :REPORTING_PERIOD || '_' || :v_servicer_id
                );

                -- Update manifest with failure
                UPDATE MORTGAGE_DB.OPS.SERVICER_FILE_MANIFEST
                SET STATUS = 'FAILED', ERROR_MESSAGE = SQLERRM
                WHERE SERVICER_ID = :v_servicer_id
                  AND REPORTING_PERIOD = :REPORTING_PERIOD;

                v_failure_count := v_failure_count + 1;
                v_results := ARRAY_APPEND(v_results,
                    OBJECT_CONSTRUCT('servicer', v_servicer_name, 'status', 'FAILED',
                                     'error', SQLERRM));
        END;
    END FOR;

    RETURN OBJECT_CONSTRUCT(
        'reporting_period', REPORTING_PERIOD,
        'total_servicers', v_success_count + v_failure_count,
        'succeeded', v_success_count,
        'failed', v_failure_count,
        'details', v_results
    );
END;
$$;
```

Execute and review results:

```sql
CALL MORTGAGE_DB.OPS.SP_LOAD_SERVICER_FILES('2025-07-01', FALSE);

-- Review failures
SELECT * FROM MORTGAGE_DB.OPS.TASK_ERROR_LOG
WHERE PIPELINE_RUN_ID LIKE '2025-07-01%'
ORDER BY ERROR_TIMESTAMP DESC;
```

**Result:** The procedure processed 45 servicer files in the July 2025 cycle. Two servicer files failed due to schema mismatches (extra column), while the remaining 43 loaded successfully — totaling 18 million rows. Previously, a single bad file would halt the entire batch, delaying all servicers by 12+ hours. The structured error logging enabled rapid root-cause diagnosis and servicer outreach within 30 minutes of the pipeline completing.

**AI Vision:** A classification model trained on historical error patterns could predict which servicer files are likely to fail based on metadata signals — file size anomalies, late delivery, or recent schema changes from that servicer — enabling preemptive validation before the main load begins.

---

### Q35. How do you use EXECUTE IMMEDIATE for dynamic SQL in flexible loan reporting?

**Situation:** Fannie Mae's business analysts need ad-hoc loan performance reports that vary by state, vintage year, loan purpose, and aggregation level. Building individual views or procedures for each combination is impractical — there are hundreds of permutations. The reporting team needs a single parameterized procedure that generates the correct query dynamically.

**Task:** Build a stored procedure using EXECUTE IMMEDIATE that constructs SQL dynamically based on user-supplied parameters, enabling flexible loan reporting without maintaining dozens of static views.

**Action:**
Create a dynamic reporting procedure:

```sql
CREATE OR REPLACE PROCEDURE MORTGAGE_DB.REPORTING.SP_LOAN_PERFORMANCE_REPORT(
    P_STATES ARRAY,
    P_VINTAGE_START INTEGER,
    P_VINTAGE_END INTEGER,
    P_LOAN_PURPOSE VARCHAR DEFAULT 'ALL',
    P_GROUP_BY VARCHAR DEFAULT 'STATE',
    P_OUTPUT_TABLE VARCHAR DEFAULT NULL
)
RETURNS TABLE (
    GROUP_KEY VARCHAR, LOAN_COUNT NUMBER, TOTAL_UPB NUMBER,
    AVG_DELINQUENCY_RATE FLOAT, AVG_INTEREST_RATE FLOAT, WA_LTV FLOAT
)
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_sql VARCHAR;
    v_where VARCHAR DEFAULT '';
    v_group_col VARCHAR;
    rs RESULTSET;
BEGIN
    -- Build GROUP BY column
    CASE (P_GROUP_BY)
        WHEN 'STATE' THEN v_group_col := 'PROPERTY_STATE';
        WHEN 'VINTAGE' THEN v_group_col := 'YEAR(ORIGINATION_DATE)';
        WHEN 'PURPOSE' THEN v_group_col := 'LOAN_PURPOSE';
        WHEN 'SERVICER' THEN v_group_col := 'SERVICER_NAME';
        ELSE v_group_col := 'PROPERTY_STATE';
    END CASE;

    -- Build WHERE filters
    IF (P_LOAN_PURPOSE != 'ALL') THEN
        v_where := v_where || ' AND LOAN_PURPOSE = ''' || P_LOAN_PURPOSE || '''';
    END IF;

    -- Construct the dynamic SQL
    v_sql := '
        SELECT
            ' || v_group_col || '::VARCHAR AS GROUP_KEY,
            COUNT(*) AS LOAN_COUNT,
            SUM(CURRENT_UPB)::NUMBER AS TOTAL_UPB,
            ROUND(AVG(CASE WHEN DELINQUENCY_STATUS != ''00'' THEN 1.0 ELSE 0.0 END) * 100, 2) AS AVG_DELINQUENCY_RATE,
            ROUND(AVG(CURRENT_INTEREST_RATE), 4) AS AVG_INTEREST_RATE,
            ROUND(SUM(CURRENT_UPB * ORIGINAL_LTV) / NULLIF(SUM(CURRENT_UPB), 0), 2) AS WA_LTV
        FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
        WHERE YEAR(ORIGINATION_DATE) BETWEEN ' || P_VINTAGE_START || ' AND ' || P_VINTAGE_END || '
          AND PROPERTY_STATE IN (SELECT VALUE::VARCHAR FROM TABLE(FLATTEN(INPUT => PARSE_JSON(''' || ARRAY_TO_STRING(P_STATES, ',') || '''))))
          ' || v_where || '
        GROUP BY ' || v_group_col || '
        ORDER BY TOTAL_UPB DESC';

    -- Optionally save to a table
    IF (P_OUTPUT_TABLE IS NOT NULL) THEN
        EXECUTE IMMEDIATE 'CREATE OR REPLACE TABLE ' || P_OUTPUT_TABLE || ' AS ' || v_sql;
        RETURN TABLE(rs);
    END IF;

    rs := (EXECUTE IMMEDIATE :v_sql);
    RETURN TABLE(rs);
END;
$$;
```

Call the procedure with various parameter combinations:

```sql
-- Report by state for 2022-2024 vintage purchase loans
CALL MORTGAGE_DB.REPORTING.SP_LOAN_PERFORMANCE_REPORT(
    ARRAY_CONSTRUCT('CA','TX','FL','NY','IL'),
    2022, 2024,
    'PURCHASE', 'STATE', NULL
);

-- Report by vintage year across all loan purposes
CALL MORTGAGE_DB.REPORTING.SP_LOAN_PERFORMANCE_REPORT(
    ARRAY_CONSTRUCT('CA','TX','FL','NY','IL','PA','OH','GA','NC','NJ'),
    2018, 2025,
    'ALL', 'VINTAGE',
    'MORTGAGE_DB.REPORTING.VINTAGE_ANALYSIS_202507'
);
```

**Result:** The single dynamic procedure replaced 35 static views and 12 one-off scripts. Report generation takes 15-30 seconds regardless of parameter combination, and the output table option enables analysts to share results via Snowsight dashboards. SQL injection risk is mitigated by restricting parameter values to predefined enumerations for GROUP BY and using array parameters for state filters.

**AI Vision:** A natural language interface could translate analyst questions like "Show me delinquency rates for 2023 California purchase loans grouped by servicer" into the correct procedure call parameters, making the dynamic reporting accessible to non-technical stakeholders.

---

### Q36. How do you use GET_DDL to extract and version loan schema definitions?

**Situation:** The `MORTGAGE_DB` database has grown to 85 tables, 30 views, 15 procedures, and 12 UDFs across 5 schemas. Schema changes are deployed manually and there is no version history of the database structure. When a deployment introduces a regression, the team cannot easily determine what changed or revert to the previous state.

**Task:** Use GET_DDL to extract complete schema definitions and establish a versioning process for the loan database structure, enabling change tracking and rollback capabilities.

**Action:**
Extract DDL for the entire database and individual objects:

```sql
-- Extract DDL for the entire database (all schemas, tables, views, etc.)
SELECT GET_DDL('DATABASE', 'MORTGAGE_DB');

-- Extract DDL for a specific schema
SELECT GET_DDL('SCHEMA', 'MORTGAGE_DB.ANALYTICS');

-- Extract DDL for individual objects with full detail
SELECT GET_DDL('TABLE', 'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT');
SELECT GET_DDL('VIEW', 'MORTGAGE_DB.ANALYTICS.VW_POOL_SUMMARY');
SELECT GET_DDL('FUNCTION', 'MORTGAGE_DB.ANALYTICS.WATERFALL_ALLOCATION(FLOAT, FLOAT, ARRAY, ARRAY, ARRAY)');
SELECT GET_DDL('PROCEDURE', 'MORTGAGE_DB.OPS.SP_LOAD_SERVICER_FILES(DATE, BOOLEAN)');
```

Create a DDL snapshot procedure for version control:

```sql
CREATE OR REPLACE PROCEDURE MORTGAGE_DB.OPS.SP_SNAPSHOT_DDL(
    SNAPSHOT_LABEL VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
BEGIN
    -- Store DDL snapshots for all schemas
    INSERT INTO MORTGAGE_DB.OPS.DDL_VERSION_HISTORY (
        SNAPSHOT_LABEL, SNAPSHOT_TIMESTAMP, OBJECT_TYPE, SCHEMA_NAME,
        OBJECT_NAME, DDL_TEXT
    )
    SELECT
        :SNAPSHOT_LABEL,
        CURRENT_TIMESTAMP(),
        'TABLE',
        TABLE_SCHEMA,
        TABLE_NAME,
        GET_DDL('TABLE', 'MORTGAGE_DB.' || TABLE_SCHEMA || '.' || TABLE_NAME)
    FROM MORTGAGE_DB.INFORMATION_SCHEMA.TABLES
    WHERE TABLE_SCHEMA NOT IN ('INFORMATION_SCHEMA', 'OPS')
      AND TABLE_TYPE = 'BASE TABLE';

    INSERT INTO MORTGAGE_DB.OPS.DDL_VERSION_HISTORY (
        SNAPSHOT_LABEL, SNAPSHOT_TIMESTAMP, OBJECT_TYPE, SCHEMA_NAME,
        OBJECT_NAME, DDL_TEXT
    )
    SELECT
        :SNAPSHOT_LABEL,
        CURRENT_TIMESTAMP(),
        'VIEW',
        TABLE_SCHEMA,
        TABLE_NAME,
        GET_DDL('VIEW', 'MORTGAGE_DB.' || TABLE_SCHEMA || '.' || TABLE_NAME)
    FROM MORTGAGE_DB.INFORMATION_SCHEMA.VIEWS
    WHERE TABLE_SCHEMA NOT IN ('INFORMATION_SCHEMA', 'OPS');

    RETURN 'Snapshot ' || SNAPSHOT_LABEL || ' created at ' || CURRENT_TIMESTAMP();
END;
$$;
```

Compare DDL between snapshots:

```sql
-- Find objects that changed between two releases
SELECT
    curr.OBJECT_TYPE,
    curr.SCHEMA_NAME,
    curr.OBJECT_NAME,
    CASE
        WHEN prev.DDL_TEXT IS NULL THEN 'ADDED'
        WHEN curr.DDL_TEXT != prev.DDL_TEXT THEN 'MODIFIED'
    END AS CHANGE_TYPE
FROM MORTGAGE_DB.OPS.DDL_VERSION_HISTORY curr
LEFT JOIN MORTGAGE_DB.OPS.DDL_VERSION_HISTORY prev
    ON curr.OBJECT_TYPE = prev.OBJECT_TYPE
    AND curr.SCHEMA_NAME = prev.SCHEMA_NAME
    AND curr.OBJECT_NAME = prev.OBJECT_NAME
    AND prev.SNAPSHOT_LABEL = 'v2.3.0'
WHERE curr.SNAPSHOT_LABEL = 'v2.4.0'
  AND (prev.DDL_TEXT IS NULL OR curr.DDL_TEXT != prev.DDL_TEXT)
ORDER BY CHANGE_TYPE, curr.OBJECT_TYPE;
```

**Result:** DDL snapshots are now captured before every production deployment, providing a complete audit trail of schema evolution. When a v2.4.0 deployment broke the POOL_MONTHLY_FACTORS table by dropping a column, the team identified the change within 5 minutes by comparing snapshots and generated a rollback script directly from the v2.3.0 DDL. The process integrates with the CI/CD pipeline via a SnowSQL step that runs the snapshot procedure pre- and post-deployment.

**AI Vision:** A schema evolution analyzer could compare DDL snapshots across versions, automatically detecting breaking changes (column drops, type changes, renamed objects) and generating impact assessments by cross-referencing with downstream query logs to identify affected consumers.

---

### Q37. How do you use SYSTEM$CLUSTERING_INFORMATION to analyze clustering quality on loan tables?

**Situation:** The `MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY` table has 2 billion rows spanning 10 years of monthly loan performance data. It is clustered on `(REPORTING_PERIOD, LOAN_ID)`, but query performance for state-level analysis has degraded over time. The team suspects the clustering is suboptimal for the evolving query patterns.

**Task:** Use SYSTEM$CLUSTERING_INFORMATION to diagnose the clustering quality, determine if the current clustering key aligns with query patterns, and optimize the clustering strategy for the dominant workload.

**Action:**
Analyze current clustering quality:

```sql
-- Check overall clustering depth and quality
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY'
);
-- Returns JSON with: cluster_by_keys, total_partition_count,
-- total_constant_partition_count, average_overlaps, average_depth

-- Check clustering quality for specific columns
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY',
    '(REPORTING_PERIOD)'
);

SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY',
    '(PROPERTY_STATE, REPORTING_PERIOD)'
);

SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY',
    '(REPORTING_PERIOD, LOAN_ID)'
);
```

Interpret the results and compare clustering strategies:

```sql
-- Parse the clustering info JSON for comparison
WITH clustering_analysis AS (
    SELECT
        'REPORTING_PERIOD, LOAN_ID' AS CLUSTER_KEY,
        PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION(
            'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY',
            '(REPORTING_PERIOD, LOAN_ID)'
        )) AS INFO
    UNION ALL
    SELECT
        'PROPERTY_STATE, REPORTING_PERIOD',
        PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION(
            'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY',
            '(PROPERTY_STATE, REPORTING_PERIOD)'
        ))
    UNION ALL
    SELECT
        'REPORTING_PERIOD',
        PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION(
            'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY',
            '(REPORTING_PERIOD)'
        ))
)
SELECT
    CLUSTER_KEY,
    INFO:total_partition_count::INTEGER AS TOTAL_PARTITIONS,
    INFO:total_constant_partition_count::INTEGER AS CONSTANT_PARTITIONS,
    INFO:average_overlaps::FLOAT AS AVG_OVERLAPS,
    INFO:average_depth::FLOAT AS AVG_DEPTH,
    ROUND(INFO:total_constant_partition_count / INFO:total_partition_count * 100, 1)
        AS PCT_WELL_CLUSTERED
FROM clustering_analysis;
```

Re-cluster based on findings:

```sql
-- If state + period analysis shows better alignment with query patterns
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY
    CLUSTER BY (PROPERTY_STATE, REPORTING_PERIOD);

-- Monitor reclustering progress
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY'
);

-- Check automatic clustering service status
SHOW TABLES LIKE 'LOAN_PERFORMANCE_HISTORY' IN SCHEMA MORTGAGE_DB.ANALYTICS;
-- Review auto_clustering_on column
```

**Result:** The analysis revealed that the original `(REPORTING_PERIOD, LOAN_ID)` key had an average depth of 8.2 — meaning most queries scanned 8x more micro-partitions than necessary for state-level filters. Switching to `(PROPERTY_STATE, REPORTING_PERIOD)` reduced average depth to 1.4 after automatic reclustering completed. State-level queries that filtered on PROPERTY_STATE went from scanning 180K micro-partitions to 22K, reducing query time from 45 seconds to 6 seconds. Monthly reclustering costs are approximately $200 in credits.

**AI Vision:** A workload analysis model could continuously monitor query patterns against clustering metrics, automatically recommending clustering key changes when the dominant query workload shifts — for example, if analysts pivot from state-level to servicer-level analysis patterns.

---

### Q38. How do you analyze query history to identify expensive queries in loan analytics?

**Situation:** The ANALYTICS_WH warehouse serving Fannie Mae loan analytics has seen credit consumption increase 40% month-over-month with no corresponding increase in data volume. The team suspects a few expensive queries are dominating resource usage, but there are thousands of queries per day from 50+ users and BI tools.

**Task:** Analyze Snowflake's query history to identify the most expensive queries, pinpoint inefficient patterns, and recommend optimizations to bring warehouse costs under control.

**Action:**
Identify the most expensive queries by total execution time and data scanned:

```sql
-- Top 20 most expensive queries in the past 30 days
SELECT
    QUERY_ID,
    USER_NAME,
    ROLE_NAME,
    WAREHOUSE_NAME,
    QUERY_TYPE,
    EXECUTION_STATUS,
    TOTAL_ELAPSED_TIME / 1000 AS ELAPSED_SEC,
    BYTES_SCANNED / POWER(1024, 3) AS GB_SCANNED,
    ROWS_PRODUCED,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(PARTITIONS_SCANNED / NULLIF(PARTITIONS_TOTAL, 0) * 100, 1) AS PCT_PARTITIONS_SCANNED,
    PERCENTAGE_SCANNED_FROM_CACHE,
    BYTES_SPILLED_TO_LOCAL_STORAGE / POWER(1024, 3) AS GB_SPILLED_LOCAL,
    BYTES_SPILLED_TO_REMOTE_STORAGE / POWER(1024, 3) AS GB_SPILLED_REMOTE,
    QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE WAREHOUSE_NAME = 'ANALYTICS_WH'
  AND START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
ORDER BY TOTAL_ELAPSED_TIME DESC
LIMIT 20;
```

Find repetitive expensive patterns:

```sql
-- Group similar queries to find repeating expensive patterns
SELECT
    QUERY_PARAMETERIZED_HASH,
    COUNT(*) AS EXECUTION_COUNT,
    AVG(TOTAL_ELAPSED_TIME) / 1000 AS AVG_ELAPSED_SEC,
    SUM(TOTAL_ELAPSED_TIME) / 1000 / 3600 AS TOTAL_HOURS,
    AVG(BYTES_SCANNED) / POWER(1024, 3) AS AVG_GB_SCANNED,
    AVG(PARTITIONS_SCANNED) AS AVG_PARTITIONS_SCANNED,
    AVG(BYTES_SPILLED_TO_REMOTE_STORAGE) / POWER(1024, 3) AS AVG_GB_SPILLED_REMOTE,
    ANY_VALUE(QUERY_TEXT) AS SAMPLE_QUERY,
    ARRAY_AGG(DISTINCT USER_NAME) AS USERS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE WAREHOUSE_NAME = 'ANALYTICS_WH'
  AND START_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
GROUP BY QUERY_PARAMETERIZED_HASH
HAVING COUNT(*) > 10
ORDER BY TOTAL_HOURS DESC
LIMIT 15;
```

Analyze partition pruning efficiency:

```sql
-- Identify queries with poor partition pruning (full table scans)
SELECT
    QUERY_ID,
    USER_NAME,
    TOTAL_ELAPSED_TIME / 1000 AS ELAPSED_SEC,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(PARTITIONS_SCANNED / NULLIF(PARTITIONS_TOTAL, 0) * 100, 1) AS PCT_SCANNED,
    SUBSTR(QUERY_TEXT, 1, 200) AS QUERY_PREVIEW
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE WAREHOUSE_NAME = 'ANALYTICS_WH'
  AND START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND PARTITIONS_TOTAL > 1000
  AND PARTITIONS_SCANNED / NULLIF(PARTITIONS_TOTAL, 0) > 0.80
ORDER BY PARTITIONS_SCANNED DESC
LIMIT 20;
```

**Result:** The analysis identified three root causes: (1) a Tableau dashboard executing a full-table scan every 15 minutes due to a missing REPORTING_PERIOD filter (consuming 35% of credits); (2) a user's ad-hoc query that spilled 500 GB to remote storage due to a Cartesian join; (3) 200+ duplicate queries from a misconfigured dbt job running hourly instead of daily. Fixing these three issues reduced monthly warehouse credits from 8,500 to 4,200 — a 50% reduction.

**AI Vision:** A cost attribution model could allocate warehouse credits to business units based on query ownership, combined with an optimization recommender that automatically suggests query rewrites, missing filters, or warehouse sizing changes to reduce per-query costs.

---

### Q39. How do you implement access control inheritance with MANAGED ACCESS schemas for loan databases?

**Situation:** The `MORTGAGE_DB` database contains sensitive borrower PII (SSN, credit scores, income) in the `ANALYTICS` schema alongside non-sensitive loan performance data. Multiple roles (DATA_ENGINEER, ANALYST, RISK_MANAGER, EXTERNAL_AUDITOR) need different levels of access. Object owners have been granting ad-hoc permissions, creating an ungovernable access matrix.

**Task:** Implement MANAGED ACCESS schemas to centralize access control, ensuring that only the schema owner (or SECURITYADMIN) can grant permissions on objects, preventing privilege sprawl and ensuring consistent enforcement of access policies.

**Action:**
Convert existing schemas to MANAGED ACCESS:

```sql
-- Convert the analytics schema to managed access
ALTER SCHEMA MORTGAGE_DB.ANALYTICS SET IS_MANAGED ACCESS;

-- New schemas should be created with MANAGED ACCESS from the start
CREATE OR REPLACE SCHEMA MORTGAGE_DB.SENSITIVE_ANALYTICS
    WITH MANAGED ACCESS
    DATA_RETENTION_TIME_IN_DAYS = 90
    COMMENT = 'PII-containing loan analytics — MANAGED ACCESS enforced';
```

Set up the role hierarchy and grants centrally:

```sql
-- Only the schema owner or SECURITYADMIN can grant on managed schemas
USE ROLE SECURITYADMIN;

-- Risk managers: full access to all analytics
GRANT USAGE ON DATABASE MORTGAGE_DB TO ROLE RISK_MANAGER;
GRANT USAGE ON SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE RISK_MANAGER;
GRANT SELECT ON ALL TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE RISK_MANAGER;
GRANT USAGE ON SCHEMA MORTGAGE_DB.SENSITIVE_ANALYTICS TO ROLE RISK_MANAGER;
GRANT SELECT ON ALL TABLES IN SCHEMA MORTGAGE_DB.SENSITIVE_ANALYTICS TO ROLE RISK_MANAGER;

-- Analysts: analytics only, no sensitive data
GRANT USAGE ON DATABASE MORTGAGE_DB TO ROLE ANALYST;
GRANT USAGE ON SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE ANALYST;
-- Explicitly NO grants on SENSITIVE_ANALYTICS schema

-- External auditors: read-only on specific tables
GRANT USAGE ON DATABASE MORTGAGE_DB TO ROLE EXTERNAL_AUDITOR;
GRANT USAGE ON SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE EXTERNAL_AUDITOR;
GRANT SELECT ON TABLE MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT TO ROLE EXTERNAL_AUDITOR;
GRANT SELECT ON TABLE MORTGAGE_DB.ANALYTICS.POOL_MONTHLY_FACTORS TO ROLE EXTERNAL_AUDITOR;
-- Auditors cannot see borrower-level PII tables

-- Verify that object owners cannot bypass managed access
-- This will FAIL in a MANAGED ACCESS schema:
-- USE ROLE DATA_ENGINEER;
-- GRANT SELECT ON TABLE MORTGAGE_DB.ANALYTICS.SOME_TABLE TO ROLE ANALYST;
-- Error: Insufficient privileges — only schema owner or SECURITYADMIN can grant
```

Audit current grants for compliance:

```sql
-- Review all grants in the managed schema
SHOW GRANTS ON SCHEMA MORTGAGE_DB.ANALYTICS;
SHOW GRANTS ON ALL TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS;

-- Find any grants that were made before MANAGED ACCESS was enabled
SELECT
    GRANTEE_NAME,
    TABLE_SCHEMA,
    TABLE_NAME,
    PRIVILEGE,
    GRANTED_BY,
    CREATED_ON
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE TABLE_CATALOG = 'MORTGAGE_DB'
  AND DELETED_ON IS NULL
  AND GRANTED_BY NOT IN ('SECURITYADMIN', 'ACCOUNTADMIN')
ORDER BY CREATED_ON DESC;
```

**Result:** After enabling MANAGED ACCESS, all new grants are funneled through SECURITYADMIN, creating a single point of governance. An audit found 47 ad-hoc grants made by object owners that bypassed the intended access policy — 12 of which gave the ANALYST role access to PII tables. These were revoked immediately. The external auditor confirmed the access control model now meets SOC 2 requirements for the mortgage data platform.

**AI Vision:** An access pattern anomaly detector could monitor query logs per role, flagging when a role accesses data outside its normal pattern — for example, if an ANALYST role suddenly queries borrower SSN columns, indicating a potential policy gap or compromised credential.

---

### Q40. How do you use future grants to automate permissions for new loan data objects?

**Situation:** The `MORTGAGE_DB.ANALYTICS` schema receives 3-5 new tables per month as the data engineering team builds out additional loan analytics. Each time a new table is created, a SECURITYADMIN must manually grant SELECT to the ANALYST and RISK_MANAGER roles — a step that is frequently forgotten, causing access issues and support tickets.

**Task:** Configure future grants so that new tables and views automatically inherit the correct permissions upon creation, eliminating manual grant steps and ensuring consistent access control.

**Action:**
Set up future grants for all schemas:

```sql
USE ROLE SECURITYADMIN;

-- Future grants on ANALYTICS schema — any new table gets SELECT for analysts
GRANT SELECT ON FUTURE TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE ANALYST;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE ANALYST;

GRANT SELECT ON FUTURE TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE RISK_MANAGER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE RISK_MANAGER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE EXTERNAL_AUDITOR;

-- Future grants on STAGING schema — engineers get full DML, analysts get nothing
GRANT SELECT, INSERT, UPDATE, DELETE ON FUTURE TABLES
    IN SCHEMA MORTGAGE_DB.STAGING TO ROLE DATA_ENGINEER;

-- Future grants on REPORTING schema — BI tools get SELECT
GRANT SELECT ON FUTURE TABLES IN SCHEMA MORTGAGE_DB.REPORTING TO ROLE BI_SERVICE_ACCOUNT;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA MORTGAGE_DB.REPORTING TO ROLE BI_SERVICE_ACCOUNT;

-- Future grants at database level (applies to all schemas)
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE MORTGAGE_DB TO ROLE ANALYST;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE MORTGAGE_DB TO ROLE RISK_MANAGER;
```

Apply grants to existing objects that were created before future grants:

```sql
-- Backfill grants on existing objects (future grants only apply to NEW objects)
GRANT SELECT ON ALL TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE ANALYST;
GRANT SELECT ON ALL VIEWS IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE RISK_MANAGER;
GRANT SELECT ON ALL VIEWS IN SCHEMA MORTGAGE_DB.ANALYTICS TO ROLE RISK_MANAGER;
```

Verify future grants are configured:

```sql
-- Review all future grants
SHOW FUTURE GRANTS IN SCHEMA MORTGAGE_DB.ANALYTICS;
SHOW FUTURE GRANTS IN SCHEMA MORTGAGE_DB.STAGING;
SHOW FUTURE GRANTS IN SCHEMA MORTGAGE_DB.REPORTING;

-- Test: create a new table and verify automatic grants
USE ROLE DATA_ENGINEER;
CREATE TABLE MORTGAGE_DB.ANALYTICS.TEST_FUTURE_GRANTS (ID INTEGER);

-- Switch to analyst and verify access
USE ROLE ANALYST;
SELECT * FROM MORTGAGE_DB.ANALYTICS.TEST_FUTURE_GRANTS;
-- Should succeed without any manual GRANT

-- Cleanup
USE ROLE DATA_ENGINEER;
DROP TABLE MORTGAGE_DB.ANALYTICS.TEST_FUTURE_GRANTS;
```

**Result:** Future grants eliminated 100% of manual grant requests for new objects — previously 15-20 tickets per month. New tables are immediately accessible to the correct roles upon creation. The onboarding time for new analytics tables dropped from 1-2 days (waiting for SECURITYADMIN availability) to zero. The pattern is now codified in the Terraform IaC configuration, ensuring consistency across environments.

**AI Vision:** A governance dashboard could continuously compare intended access policies (defined in a policy-as-code repository) against actual Snowflake grants, automatically detecting and remediating drift — for example, if a future grant is accidentally removed during a schema recreation.

---

### Q41. How do you use data sharing with filtering to share only specific vintage pools?

**Situation:** Fannie Mae needs to share MBS pool performance data with approved broker-dealers, but each dealer should only see pools they are authorized to trade. Dealer A might only see 2023-2024 vintage 30-year fixed pools, while Dealer B sees all vintages but only ARM pools. Sharing the entire dataset with row-level filtering is required.

**Task:** Configure Snowflake Secure Data Sharing with row-level filtering using secure views, so each consumer account sees only the pools they are authorized to access, without duplicating data.

**Action:**
Create secure views with row-level access control:

```sql
-- Create a mapping table for dealer-to-pool authorization
CREATE OR REPLACE TABLE MORTGAGE_DB.SHARING.DEALER_POOL_ACCESS (
    DEALER_ACCOUNT_LOCATOR VARCHAR,
    POOL_PREFIX VARCHAR,
    VINTAGE_START DATE,
    VINTAGE_END DATE,
    PRODUCT_TYPE VARCHAR,
    AUTHORIZED_BY VARCHAR,
    AUTHORIZED_DATE DATE
);

-- Populate dealer authorizations
INSERT INTO MORTGAGE_DB.SHARING.DEALER_POOL_ACCESS VALUES
    ('DEALER_A_LOCATOR', 'FN%', '2023-01-01', '2024-12-31', '30YR_FIXED', 'ADMIN', '2025-01-15'),
    ('DEALER_B_LOCATOR', 'FN%', '2018-01-01', '2025-12-31', 'ARM', 'ADMIN', '2025-01-15');

-- Create secure view that filters based on consumer account
CREATE OR REPLACE SECURE VIEW MORTGAGE_DB.SHARING.SV_POOL_PERFORMANCE AS
SELECT
    p.POOL_ID,
    p.REPORTING_PERIOD,
    p.POOL_UPB,
    p.POOL_FACTOR,
    p.WAC,
    p.WAM,
    p.WALA,
    p.DELINQUENCY_30_PCT,
    p.DELINQUENCY_60_PCT,
    p.DELINQUENCY_90_PLUS_PCT,
    p.CPR_1M,
    p.CPR_3M,
    p.CDR_1M,
    p.SEVERITY_RATE,
    p.VINTAGE_YEAR,
    p.PRODUCT_TYPE
FROM MORTGAGE_DB.ANALYTICS.POOL_MONTHLY_FACTORS p
INNER JOIN MORTGAGE_DB.SHARING.DEALER_POOL_ACCESS a
    ON p.POOL_ID LIKE a.POOL_PREFIX
    AND p.VINTAGE_YEAR BETWEEN YEAR(a.VINTAGE_START) AND YEAR(a.VINTAGE_END)
    AND p.PRODUCT_TYPE = a.PRODUCT_TYPE
    AND a.DEALER_ACCOUNT_LOCATOR = CURRENT_ACCOUNT();
```

Create and configure the share:

```sql
-- Create the share
CREATE OR REPLACE SHARE FNMA_POOL_PERFORMANCE_SHARE
    COMMENT = 'Fannie Mae MBS pool performance data — filtered by dealer authorization';

-- Grant necessary privileges to the share
GRANT USAGE ON DATABASE MORTGAGE_DB TO SHARE FNMA_POOL_PERFORMANCE_SHARE;
GRANT USAGE ON SCHEMA MORTGAGE_DB.SHARING TO SHARE FNMA_POOL_PERFORMANCE_SHARE;
GRANT SELECT ON VIEW MORTGAGE_DB.SHARING.SV_POOL_PERFORMANCE
    TO SHARE FNMA_POOL_PERFORMANCE_SHARE;

-- Add consumer accounts
ALTER SHARE FNMA_POOL_PERFORMANCE_SHARE ADD ACCOUNTS = DEALER_A_LOCATOR, DEALER_B_LOCATOR;
```

Consumer-side setup:

```sql
-- On the dealer's Snowflake account
CREATE OR REPLACE DATABASE FNMA_SHARED_DATA FROM SHARE FANNIE_MAE_ACCOUNT.FNMA_POOL_PERFORMANCE_SHARE;

-- Dealer A only sees 2023-2024 30YR_FIXED pools
SELECT DISTINCT VINTAGE_YEAR, PRODUCT_TYPE, COUNT(DISTINCT POOL_ID) AS POOL_COUNT
FROM FNMA_SHARED_DATA.SHARING.SV_POOL_PERFORMANCE
GROUP BY VINTAGE_YEAR, PRODUCT_TYPE;
```

**Result:** Five broker-dealers now access Fannie Mae pool performance data through a single share with row-level filtering — no data duplication, no ETL, no file transfers. Each dealer sees only their authorized pools, verified by quarterly access audits. The secure view prevents dealers from reverse-engineering the filtering logic. Adding a new dealer takes 5 minutes: one INSERT into the access table and one ALTER SHARE command.

**AI Vision:** A usage analytics model could monitor query patterns from each dealer account, identifying which pools receive the most analytical attention and correlating this with actual trading activity to predict market demand for specific MBS vintages and product types.

---

### Q42. How do you use reader accounts to provide data access to external auditors?

**Situation:** Freddie Mac's external audit firm needs to query loan performance data and compliance reports directly in Snowflake for quarterly audits. The audit firm does not have a Snowflake account and their contract does not justify purchasing one. They need read-only access to specific tables for a 60-day window during each audit cycle.

**Task:** Create a Snowflake reader (managed) account for the audit firm, provision it with the appropriate shared data and a warehouse, and set up time-limited access with usage controls.

**Action:**
Create the reader account:

```sql
-- Create a managed reader account for the audit firm
CREATE MANAGED ACCOUNT KPMG_AUDIT_2025Q2
    ADMIN_NAME = 'kpmg_admin',
    ADMIN_PASSWORD = 'InitialP@ss2025!',
    TYPE = READER,
    COMMENT = 'KPMG Q2 2025 audit — Freddie Mac loan compliance review';

-- The command returns the account locator and URL
-- Note the LOCATOR for share configuration
```

Set up the share for audit-specific data:

```sql
-- Create audit-specific secure views with only required data
CREATE OR REPLACE SECURE VIEW MORTGAGE_DB.AUDIT.SV_LOAN_COMPLIANCE AS
SELECT
    LOAN_ID,
    REPORTING_PERIOD,
    CURRENT_UPB,
    DELINQUENCY_STATUS,
    LOAN_AGE,
    MODIFICATION_FLAG,
    ZERO_BALANCE_CODE,
    PROPERTY_STATE,
    -- Mask sensitive borrower fields
    'XXX-XX-' || RIGHT(BORROWER_SSN, 4) AS BORROWER_SSN_MASKED,
    CASE WHEN BORROWER_CREDIT_SCORE IS NOT NULL
         THEN FLOOR(BORROWER_CREDIT_SCORE / 50) * 50
         ELSE NULL
    END AS CREDIT_SCORE_BAND
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
WHERE REPORTING_PERIOD BETWEEN '2025-01-01' AND '2025-06-30';

-- Create share and add the reader account
CREATE OR REPLACE SHARE FHLMC_AUDIT_SHARE_2025Q2
    COMMENT = 'Freddie Mac audit data share for KPMG Q2 2025';

GRANT USAGE ON DATABASE MORTGAGE_DB TO SHARE FHLMC_AUDIT_SHARE_2025Q2;
GRANT USAGE ON SCHEMA MORTGAGE_DB.AUDIT TO SHARE FHLMC_AUDIT_SHARE_2025Q2;
GRANT SELECT ON VIEW MORTGAGE_DB.AUDIT.SV_LOAN_COMPLIANCE
    TO SHARE FHLMC_AUDIT_SHARE_2025Q2;

ALTER SHARE FHLMC_AUDIT_SHARE_2025Q2
    ADD ACCOUNTS = KPMG_AUDIT_2025Q2;
```

Configure resource controls on the reader account:

```sql
-- On the reader account (or via provider-managed setup)
-- Create a resource-limited warehouse
CREATE WAREHOUSE AUDIT_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    MAX_CLUSTER_COUNT = 1
    RESOURCE_MONITOR = AUDIT_MONITOR;

-- Create a resource monitor to cap credit usage
CREATE RESOURCE MONITOR AUDIT_MONITOR
    WITH CREDIT_QUOTA = 100
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;
```

Decommission after audit window:

```sql
-- After the 60-day audit window
DROP MANAGED ACCOUNT KPMG_AUDIT_2025Q2;
-- This immediately revokes all access — no lingering credentials
```

**Result:** KPMG's audit team had self-service query access to Freddie Mac's loan data within 30 minutes of account creation. They ran 2,400 queries over the 45-day audit period, consuming 62 credits on the SMALL warehouse. Sensitive borrower data was masked in the secure view, satisfying both audit requirements and data privacy policies. The reader account was dropped after the audit, leaving zero persistent access. This replaced a previous process of exporting 50GB of CSV files via SFTP, which took 3 days to prepare and introduced data handling risks.

**AI Vision:** An audit analytics engine on the provider side could monitor the reader account's query patterns, automatically generating a "data access report" for compliance showing exactly which records the auditors queried, supporting the audit-of-the-audit requirements.

---

### Q43. How do you configure replication for cross-region disaster recovery of loan data?

**Situation:** `MORTGAGE_DB` is the primary database in the US-East-1 (AWS Virginia) region containing all Fannie Mae and Freddie Mac loan data. Regulatory requirements mandate that the mortgage data platform must have a Recovery Time Objective (RTO) of 4 hours and Recovery Point Objective (RPO) of 1 hour in case of a regional outage.

**Task:** Configure Snowflake database replication to a secondary region (US-West-2, AWS Oregon) to meet the RTO/RPO requirements, with automated failover capabilities and regular DR testing.

**Action:**
Enable replication on the primary account and configure the failover group:

```sql
-- On the PRIMARY account (US-East-1)
-- Enable replication for the database
ALTER DATABASE MORTGAGE_DB ENABLE REPLICATION TO ACCOUNTS
    ORG_NAME.ACCOUNT_WEST2;

-- Create a failover group that includes the database and shares
CREATE FAILOVER GROUP MORTGAGE_DR_GROUP
    OBJECT_TYPES = DATABASES, SHARES, ROLES, WAREHOUSES, INTEGRATIONS
    ALLOWED_DATABASES = MORTGAGE_DB
    ALLOWED_SHARES = FNMA_POOL_PERFORMANCE_SHARE
    ALLOWED_ACCOUNTS = ORG_NAME.ACCOUNT_WEST2
    REPLICATION_SCHEDULE = '60 MINUTE'
    COMMENT = 'Mortgage DB disaster recovery — RPO 1 hour to US-West-2';
```

Configure the secondary account:

```sql
-- On the SECONDARY account (US-West-2)
-- Create the replica failover group
CREATE FAILOVER GROUP MORTGAGE_DR_GROUP
    AS REPLICA OF ORG_NAME.ACCOUNT_EAST1.MORTGAGE_DR_GROUP;

-- Manually trigger an initial refresh
ALTER FAILOVER GROUP MORTGAGE_DR_GROUP REFRESH;

-- Monitor replication status
SELECT
    DATABASE_NAME,
    PHASE,
    BYTES_TRANSFERRED,
    NEXT_SCHEDULED_REFRESH,
    PRIMARY_SNAPSHOT_TIMESTAMP,
    SECONDARY_SNAPSHOT_TIMESTAMP
FROM TABLE(INFORMATION_SCHEMA.DATABASE_REPLICATION_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('day', -7, CURRENT_DATE())
));
```

Monitor replication lag and health:

```sql
-- On the SECONDARY account
SHOW REPLICATION DATABASES;
-- Check replication_lag_seconds and last_refreshed_on

-- Set up an alert for replication lag exceeding RPO
CREATE OR REPLACE ALERT MORTGAGE_DB_OPS.ALERTS.REPLICATION_LAG_ALERT
    WAREHOUSE = MONITORING_WH
    SCHEDULE = '30 MINUTE'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(INFORMATION_SCHEMA.DATABASE_REPLICATION_USAGE_HISTORY(
            DATE_RANGE_START => DATEADD('hour', -2, CURRENT_TIMESTAMP())
        ))
        WHERE DATEDIFF('minute', PRIMARY_SNAPSHOT_TIMESTAMP,
                        SECONDARY_SNAPSHOT_TIMESTAMP) > 60
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL('DR_ALERTS', 'dr-team@mortgagecorp.com',
            'ALERT: Replication lag exceeds RPO',
            'MORTGAGE_DB replication lag exceeds 60 minutes. Check secondary account.');
```

Failover procedure:

```sql
-- On the SECONDARY account — execute failover
ALTER FAILOVER GROUP MORTGAGE_DR_GROUP PRIMARY;
-- The secondary becomes the new primary; all objects are now writable
-- Update DNS/connection strings to point to the West2 account
```

**Result:** Replication is configured with a 60-minute schedule, consistently maintaining an RPO of 45-55 minutes. Monthly DR drills confirm failover completes within 15 minutes (well within the 4-hour RTO). The replicated database includes all tables, streams, and tasks. Monthly replication costs are approximately $1,200 in cross-region data transfer and compute, which is a fraction of the cost of maintaining a separate ETL pipeline to a standby database.

**AI Vision:** A predictive availability model could monitor primary region health metrics (latency, error rates, cloud provider status) and proactively initiate failover before an outage is declared, reducing effective RTO from hours to minutes based on early warning signals.

---

### Q44. How do you use stage transformations to transform data during COPY INTO operations?

**Situation:** Freddie Mac delivers raw loan-level files in a legacy fixed-width format with coded values (e.g., "P" for purchase, "R" for refinance, "C" for cash-out refinance). The staging table uses normalized data types and human-readable values. Previously, data was loaded raw and then transformed in a separate step, doubling storage and processing time.

**Task:** Apply transformations directly in the COPY INTO statement to load and transform data in a single step, eliminating the intermediate raw staging table and reducing pipeline latency.

**Action:**
Create the target table with clean data types:

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.STAGING.FHLMC_LOAN_PERFORMANCE (
    LOAN_ID VARCHAR(20),
    REPORTING_PERIOD DATE,
    CURRENT_UPB NUMBER(14,2),
    DELINQUENCY_STATUS VARCHAR(30),
    LOAN_AGE INTEGER,
    REMAINING_MONTHS INTEGER,
    CURRENT_INTEREST_RATE NUMBER(6,4),
    LOAN_PURPOSE VARCHAR(25),
    PROPERTY_STATE VARCHAR(2),
    ZERO_BALANCE_CODE VARCHAR(25),
    MODIFICATION_FLAG BOOLEAN,
    LOAD_TIMESTAMP TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

Use COPY INTO with SELECT transformations from the stage:

```sql
COPY INTO MORTGAGE_DB.STAGING.FHLMC_LOAN_PERFORMANCE (
    LOAN_ID, REPORTING_PERIOD, CURRENT_UPB, DELINQUENCY_STATUS,
    LOAN_AGE, REMAINING_MONTHS, CURRENT_INTEREST_RATE, LOAN_PURPOSE,
    PROPERTY_STATE, ZERO_BALANCE_CODE, MODIFICATION_FLAG
)
FROM (
    SELECT
        -- Clean and trim loan ID
        TRIM($1) AS LOAN_ID,

        -- Parse date from YYYYMM format to proper DATE
        TO_DATE($2 || '01', 'YYYYMMDD') AS REPORTING_PERIOD,

        -- Convert UPB string to number
        TRY_TO_NUMBER($3, 14, 2) AS CURRENT_UPB,

        -- Decode delinquency status
        CASE TRIM($4)
            WHEN '00' THEN 'CURRENT'
            WHEN '01' THEN '30_DAY_DELINQUENT'
            WHEN '02' THEN '60_DAY_DELINQUENT'
            WHEN '03' THEN '90_DAY_DELINQUENT'
            WHEN 'RA' THEN 'REO_ACQUISITION'
            ELSE 'UNKNOWN_' || TRIM($4)
        END AS DELINQUENCY_STATUS,

        TRY_TO_NUMBER($5) AS LOAN_AGE,
        TRY_TO_NUMBER($6) AS REMAINING_MONTHS,
        TRY_TO_NUMBER($7, 6, 4) AS CURRENT_INTEREST_RATE,

        -- Decode loan purpose
        CASE TRIM($8)
            WHEN 'P' THEN 'PURCHASE'
            WHEN 'R' THEN 'RATE_TERM_REFINANCE'
            WHEN 'C' THEN 'CASH_OUT_REFINANCE'
            WHEN 'N' THEN 'NOT_SPECIFIED'
            ELSE 'OTHER'
        END AS LOAN_PURPOSE,

        UPPER(TRIM($9)) AS PROPERTY_STATE,

        -- Decode zero balance code
        CASE TRIM($10)
            WHEN '01' THEN 'PREPAID_VOLUNTARY'
            WHEN '02' THEN 'THIRD_PARTY_SALE'
            WHEN '03' THEN 'SHORT_SALE'
            WHEN '06' THEN 'REO_DISPOSITION'
            WHEN '09' THEN 'REO_DEED_IN_LIEU'
            ELSE NULL
        END AS ZERO_BALANCE_CODE,

        -- Convert Y/N to boolean
        CASE TRIM($11) WHEN 'Y' THEN TRUE ELSE FALSE END AS MODIFICATION_FLAG

    FROM @MORTGAGE_DB.STAGING.FHLMC_PERFORMANCE_STAGE/monthly_perf_2025Q2/
)
FILE_FORMAT = (TYPE = 'CSV' FIELD_DELIMITER = '|' SKIP_HEADER = 0)
ON_ERROR = 'CONTINUE'
FORCE = FALSE;
```

Verify the transformed load:

```sql
SELECT
    LOAN_PURPOSE,
    COUNT(*) AS LOAN_COUNT,
    SUM(CURRENT_UPB) AS TOTAL_UPB,
    COUNT_IF(DELINQUENCY_STATUS != 'CURRENT') AS DELINQUENT_COUNT
FROM MORTGAGE_DB.STAGING.FHLMC_LOAN_PERFORMANCE
WHERE REPORTING_PERIOD = '2025-04-01'
GROUP BY LOAN_PURPOSE
ORDER BY TOTAL_UPB DESC;
```

**Result:** The single-step load-and-transform approach eliminated the intermediate raw staging table (previously 15 GB per monthly file), reduced the pipeline from two steps to one, and cut loading time from 12 minutes to 7 minutes. Coded values are decoded at load time, making the data immediately queryable by analysts without needing a lookup join. The TRY_TO_NUMBER functions gracefully handle malformed numeric fields, converting them to NULL rather than failing the entire load.

**AI Vision:** A data quality model could analyze the distribution of decoded values post-load, automatically flagging when the proportion of "UNKNOWN" or NULL values exceeds historical baselines — indicating potential changes in the upstream file format that need investigation.

---

### Q45. How do you load Parquet and ORC columnar loan archive files into Snowflake?

**Situation:** The Fannie Mae historical loan archive (2000-2020) has been converted from CSV to Parquet format for efficient long-term storage in S3. Each yearly file is 2-8 GB compressed, with embedded schema and column statistics. The team needs to load this 20-year archive into `MORTGAGE_DB.ARCHIVE.HISTORICAL_LOAN_PERFORMANCE` while leveraging the Parquet schema and column pruning for efficient loading.

**Task:** Load Parquet files from S3 into Snowflake, using schema detection to auto-map columns and leveraging columnar format advantages to minimize load time and compute costs for the large historical archive.

**Action:**
Detect the Parquet schema before loading:

```sql
-- Infer schema from Parquet file metadata
SELECT *
FROM TABLE(INFER_SCHEMA(
    LOCATION => '@MORTGAGE_DB.STAGING.FNMA_ARCHIVE_STAGE/parquet/',
    FILE_FORMAT => 'MORTGAGE_DB.STAGING.PARQUET_FORMAT',
    FILES => 'fnma_perf_2020.parquet'
));

-- Create a file format for Parquet
CREATE OR REPLACE FILE FORMAT MORTGAGE_DB.STAGING.PARQUET_FORMAT
    TYPE = 'PARQUET'
    COMPRESSION = 'SNAPPY'
    BINARY_AS_TEXT = FALSE;

-- Create a file format for ORC (for CoreLogic archives)
CREATE OR REPLACE FILE FORMAT MORTGAGE_DB.STAGING.ORC_FORMAT
    TYPE = 'ORC'
    TRIM_SPACE = TRUE;
```

Create the target table using schema detection:

```sql
-- Auto-create table based on Parquet schema
CREATE OR REPLACE TABLE MORTGAGE_DB.ARCHIVE.HISTORICAL_LOAN_PERFORMANCE
USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
        LOCATION => '@MORTGAGE_DB.STAGING.FNMA_ARCHIVE_STAGE/parquet/',
        FILE_FORMAT => 'MORTGAGE_DB.STAGING.PARQUET_FORMAT',
        FILES => 'fnma_perf_2020.parquet'
    ))
);
```

Load the Parquet files with column mapping:

```sql
-- Load all yearly Parquet files
COPY INTO MORTGAGE_DB.ARCHIVE.HISTORICAL_LOAN_PERFORMANCE
FROM @MORTGAGE_DB.STAGING.FNMA_ARCHIVE_STAGE/parquet/
FILE_FORMAT = (FORMAT_NAME = 'MORTGAGE_DB.STAGING.PARQUET_FORMAT')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
PATTERN = '.*fnma_perf_20[0-2][0-9]\.parquet'
ON_ERROR = 'SKIP_FILE';

-- Load ORC files from CoreLogic archive
COPY INTO MORTGAGE_DB.ARCHIVE.CORELOGIC_PROPERTY_HISTORY
FROM (
    SELECT
        $1:FIPS_CODE::VARCHAR AS FIPS_CODE,
        $1:APN::VARCHAR AS APN,
        $1:AVM_VALUE::NUMBER(14,2) AS AVM_VALUE,
        $1:SALE_PRICE::NUMBER(14,2) AS SALE_PRICE,
        $1:SALE_DATE::DATE AS SALE_DATE,
        $1:PROPERTY_TYPE::VARCHAR AS PROPERTY_TYPE,
        $1:SQUARE_FOOTAGE::INTEGER AS SQUARE_FOOTAGE
    FROM @MORTGAGE_DB.STAGING.CORELOGIC_ARCHIVE_STAGE/orc/
)
FILE_FORMAT = (FORMAT_NAME = 'MORTGAGE_DB.STAGING.ORC_FORMAT')
ON_ERROR = 'SKIP_FILE';
```

Verify the load and query the archive:

```sql
-- Verify row counts by vintage year
SELECT
    YEAR(ORIGINATION_DATE) AS VINTAGE_YEAR,
    COUNT(*) AS TOTAL_RECORDS,
    COUNT(DISTINCT LOAN_ID) AS UNIQUE_LOANS,
    SUM(ORIGINAL_UPB) AS TOTAL_ORIGINAL_UPB
FROM MORTGAGE_DB.ARCHIVE.HISTORICAL_LOAN_PERFORMANCE
GROUP BY VINTAGE_YEAR
ORDER BY VINTAGE_YEAR;
```

**Result:** The 20-year Parquet archive (85 GB compressed, 2.1 billion rows) loaded in 35 minutes on an XL warehouse — 4x faster than loading the equivalent CSV files due to Parquet's columnar compression and embedded metadata. MATCH_BY_COLUMN_NAME eliminated manual column position mapping, and INFER_SCHEMA correctly detected all 45 columns including nested types. The ORC-format CoreLogic property history (12 GB, 500 million rows) loaded in 8 minutes. Total archive storage in Snowflake is 42 GB after automatic compression.

**AI Vision:** A schema evolution detector could compare Parquet file schemas across yearly archives, automatically identifying columns that were added, removed, or changed type between vintages, generating a compatibility report before loading to prevent silent data quality issues.

---

### Q46. How do you use MATCH_RECOGNIZE to detect loan payment patterns and trends?

**Situation:** Fannie Mae's loss mitigation team needs to identify loans exhibiting specific payment behavior patterns — such as a loan that was current, became delinquent for 3+ months, then returned to current status (a "cured" delinquency). These patterns are critical for evaluating modification program effectiveness and predicting re-default risk.

**Task:** Use Snowflake's MATCH_RECOGNIZE clause to detect complex sequential payment patterns in loan performance data without writing procedural cursor-based logic, enabling pattern-based analytics at scale across the entire portfolio.

**Action:**
Detect the "cure" pattern — loans that went delinquent and then returned to current:

```sql
SELECT *
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY
MATCH_RECOGNIZE (
    PARTITION BY LOAN_ID
    ORDER BY REPORTING_PERIOD
    MEASURES
        FIRST(CURRENT_PERIOD.REPORTING_PERIOD) AS CURRENT_START,
        FIRST(DELINQUENT.REPORTING_PERIOD) AS DELINQUENCY_START,
        LAST(DELINQUENT.REPORTING_PERIOD) AS DELINQUENCY_END,
        FIRST(CURED.REPORTING_PERIOD) AS CURE_DATE,
        COUNT(DELINQUENT.*) AS MONTHS_DELINQUENT,
        MAX(DELINQUENT.DELINQUENCY_STATUS) AS MAX_DELINQUENCY,
        FIRST(CURRENT_PERIOD.CURRENT_UPB) AS UPB_BEFORE,
        FIRST(CURED.CURRENT_UPB) AS UPB_AFTER
    ONE ROW PER MATCH
    AFTER MATCH SKIP TO LAST CURED
    PATTERN (CURRENT_PERIOD+ DELINQUENT{3,} CURED+)
    DEFINE
        CURRENT_PERIOD AS DELINQUENCY_STATUS = '00',
        DELINQUENT AS DELINQUENCY_STATUS IN ('01','02','03','04','05','06'),
        CURED AS DELINQUENCY_STATUS = '00'
)
WHERE DELINQUENCY_START >= '2023-01-01'
ORDER BY MONTHS_DELINQUENT DESC;
```

Detect the "roll rate" pattern — loans that progressively worsen:

```sql
SELECT *
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY
MATCH_RECOGNIZE (
    PARTITION BY LOAN_ID
    ORDER BY REPORTING_PERIOD
    MEASURES
        FIRST(D30.REPORTING_PERIOD) AS FIRST_30DAY,
        FIRST(D60.REPORTING_PERIOD) AS FIRST_60DAY,
        FIRST(D90.REPORTING_PERIOD) AS FIRST_90DAY,
        FIRST(SEVERE.REPORTING_PERIOD) AS SEVERE_DATE,
        FIRST(D30.CURRENT_UPB) AS UPB_AT_30DAY,
        LAST(SEVERE.CURRENT_UPB) AS UPB_AT_SEVERE,
        DATEDIFF('month', FIRST(D30.REPORTING_PERIOD),
                 FIRST(SEVERE.REPORTING_PERIOD)) AS MONTHS_TO_SEVERE
    ONE ROW PER MATCH
    PATTERN (D30+ D60+ D90+ SEVERE+)
    DEFINE
        D30 AS DELINQUENCY_STATUS = '01',
        D60 AS DELINQUENCY_STATUS = '02',
        D90 AS DELINQUENCY_STATUS = '03',
        SEVERE AS DELINQUENCY_STATUS IN ('04','05','06','RA')
)
WHERE FIRST_30DAY >= '2023-01-01'
ORDER BY MONTHS_TO_SEVERE ASC;
```

Summarize cure rates by modification status:

```sql
WITH cured_loans AS (
    SELECT *
    FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY
    MATCH_RECOGNIZE (
        PARTITION BY LOAN_ID
        ORDER BY REPORTING_PERIOD
        MEASURES
            FIRST(DELINQUENT.REPORTING_PERIOD) AS DQ_START,
            COUNT(DELINQUENT.*) AS DQ_MONTHS,
            FIRST(CURED.REPORTING_PERIOD) AS CURE_DATE,
            ANY_VALUE(DELINQUENT.MODIFICATION_FLAG) AS WAS_MODIFIED
        ONE ROW PER MATCH
        PATTERN (DELINQUENT{2,} CURED{3,})
        DEFINE
            DELINQUENT AS DELINQUENCY_STATUS != '00',
            CURED AS DELINQUENCY_STATUS = '00'
    )
    WHERE DQ_START >= '2022-01-01'
)
SELECT
    WAS_MODIFIED,
    COUNT(*) AS CURED_COUNT,
    AVG(DQ_MONTHS) AS AVG_MONTHS_DELINQUENT,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DQ_MONTHS) AS MEDIAN_DQ_MONTHS
FROM cured_loans
GROUP BY WAS_MODIFIED;
```

**Result:** MATCH_RECOGNIZE identified 145,000 cured delinquencies across the 2023-2025 period, with modified loans curing at 2.3x the rate of unmodified loans. The progressive roll-rate analysis identified 12,000 loans that went from 30-day delinquent to severe within 4 months — a key predictor of loss. This analysis previously required a 500-line Python script running outside Snowflake; the SQL-native approach runs in 3 minutes and is fully integrated into the analytics pipeline.

**AI Vision:** A re-default prediction model could use the MATCH_RECOGNIZE output as training features — encoding the cure pattern characteristics (duration, depth, modification type) — to score currently cured loans for probability of re-entering delinquency within the next 12 months.

---

### Q47. How do you use PIVOT and UNPIVOT to transform loan performance data for reporting?

**Situation:** Fannie Mae's monthly investor report requires loan delinquency data in a pivoted format — one row per pool with columns for each delinquency bucket (Current, 30-day, 60-day, 90+day, Foreclosure, REO). The source data in `MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT` has one row per loan with a delinquency status code. Conversely, some downstream systems need the pivoted report unpivoted back to a normalized format.

**Task:** Use PIVOT to transform loan-level delinquency data into pool-level bucketed reports, and UNPIVOT to convert wide-format reports back to normalized long format for different consumers.

**Action:**
PIVOT loan-level data into pool-level delinquency buckets:

```sql
-- Create the pivoted pool delinquency report
CREATE OR REPLACE TABLE MORTGAGE_DB.REPORTING.POOL_DELINQUENCY_PIVOT AS
WITH loan_buckets AS (
    SELECT
        POOL_ID,
        REPORTING_PERIOD,
        CURRENT_UPB,
        CASE
            WHEN DELINQUENCY_STATUS = '00' THEN 'CURRENT'
            WHEN DELINQUENCY_STATUS = '01' THEN 'DQ_30'
            WHEN DELINQUENCY_STATUS = '02' THEN 'DQ_60'
            WHEN DELINQUENCY_STATUS IN ('03','04','05','06') THEN 'DQ_90_PLUS'
            WHEN DELINQUENCY_STATUS = 'RA' THEN 'REO'
            ELSE 'OTHER'
        END AS DQ_BUCKET
    FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
    WHERE REPORTING_PERIOD = '2025-06-01'
)
SELECT *
FROM (
    SELECT POOL_ID, REPORTING_PERIOD, DQ_BUCKET, CURRENT_UPB
    FROM loan_buckets
)
PIVOT (
    SUM(CURRENT_UPB) FOR DQ_BUCKET IN (
        'CURRENT', 'DQ_30', 'DQ_60', 'DQ_90_PLUS', 'REO', 'OTHER'
    )
) AS p (POOL_ID, REPORTING_PERIOD,
        UPB_CURRENT, UPB_30DAY, UPB_60DAY, UPB_90PLUS, UPB_REO, UPB_OTHER);

-- Add calculated metrics
SELECT
    POOL_ID,
    REPORTING_PERIOD,
    UPB_CURRENT,
    UPB_30DAY,
    UPB_60DAY,
    UPB_90PLUS,
    UPB_REO,
    (UPB_CURRENT + UPB_30DAY + UPB_60DAY + UPB_90PLUS + UPB_REO + UPB_OTHER) AS TOTAL_UPB,
    ROUND((UPB_30DAY + UPB_60DAY + UPB_90PLUS) /
        NULLIF(UPB_CURRENT + UPB_30DAY + UPB_60DAY + UPB_90PLUS + UPB_REO + UPB_OTHER, 0)
        * 100, 2) AS DELINQUENCY_RATE_PCT
FROM MORTGAGE_DB.REPORTING.POOL_DELINQUENCY_PIVOT
ORDER BY DELINQUENCY_RATE_PCT DESC;
```

UNPIVOT the wide report back to long format for downstream systems:

```sql
-- UNPIVOT for systems that need normalized format
SELECT
    POOL_ID,
    REPORTING_PERIOD,
    DQ_BUCKET,
    UPB_AMOUNT
FROM MORTGAGE_DB.REPORTING.POOL_DELINQUENCY_PIVOT
UNPIVOT (
    UPB_AMOUNT FOR DQ_BUCKET IN (
        UPB_CURRENT, UPB_30DAY, UPB_60DAY, UPB_90PLUS, UPB_REO, UPB_OTHER
    )
)
WHERE UPB_AMOUNT > 0
ORDER BY POOL_ID, DQ_BUCKET;
```

Create a time-series pivot for trend analysis:

```sql
-- Pivot delinquency rates over time for a specific pool
SELECT *
FROM (
    SELECT
        POOL_ID,
        TO_CHAR(REPORTING_PERIOD, 'YYYY_MM') AS PERIOD_LABEL,
        ROUND(COUNT_IF(DELINQUENCY_STATUS != '00') * 100.0 / COUNT(*), 2) AS DQ_RATE
    FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_HISTORY
    WHERE POOL_ID = 'FN-MA4567'
      AND REPORTING_PERIOD >= '2024-01-01'
    GROUP BY POOL_ID, REPORTING_PERIOD
)
PIVOT (
    MAX(DQ_RATE) FOR PERIOD_LABEL IN (
        '2024_01','2024_02','2024_03','2024_04','2024_05','2024_06',
        '2024_07','2024_08','2024_09','2024_10','2024_11','2024_12'
    )
) AS monthly_trend;
```

**Result:** The pivoted pool delinquency report is generated in 90 seconds for 85,000 pools and delivered directly to investor reporting via Snowsight dashboard. The UNPIVOT feeds Freddie Mac's downstream risk system which requires normalized input. The time-series pivot enables side-by-side monthly trend comparison in a single row per pool, replacing a manual Excel pivot process that took an analyst 4 hours per month.

**AI Vision:** A trend forecasting model could consume the monthly pivoted delinquency rates as time-series features, predicting next-month delinquency rates per pool and flagging pools where the predicted trajectory crosses critical thresholds for proactive investor communication.

---

### Q48. How do you use geospatial functions for property location analysis in loan portfolios?

**Situation:** Fannie Mae's credit risk team needs to analyze geographic concentration risk in the mortgage portfolio — identifying loan clusters near hurricane zones, flood plains, and wildfire risk areas. Property addresses have been geocoded to latitude/longitude coordinates and stored alongside loan data. FEMA flood zone boundaries and USFS wildfire risk polygons are available as geospatial datasets.

**Task:** Use Snowflake's geospatial functions to compute geographic risk metrics — property clustering, distance to hazard zones, and concentration within risk boundaries — enabling spatial risk analytics without exporting data to a GIS tool.

**Action:**
Create geospatial points from loan property coordinates:

```sql
-- Add geography column to loan data
ALTER TABLE MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
    ADD COLUMN PROPERTY_GEO GEOGRAPHY;

UPDATE MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
SET PROPERTY_GEO = ST_MAKEPOINT(PROPERTY_LONGITUDE, PROPERTY_LATITUDE)
WHERE PROPERTY_LONGITUDE IS NOT NULL
  AND PROPERTY_LATITUDE IS NOT NULL;
```

Analyze geographic concentration and proximity to hazard zones:

```sql
-- Find loans within 10 miles of a hurricane landfall point
-- (e.g., Hurricane example coordinates: -90.1, 29.95 — Southeast Louisiana)
SELECT
    LOAN_ID,
    PROPERTY_STATE,
    PROPERTY_ZIP,
    CURRENT_UPB,
    DELINQUENCY_STATUS,
    ROUND(ST_DISTANCE(
        PROPERTY_GEO,
        ST_MAKEPOINT(-90.1, 29.95)
    ) / 1609.34, 1) AS MILES_FROM_LANDFALL
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
WHERE ST_DISTANCE(
    PROPERTY_GEO,
    ST_MAKEPOINT(-90.1, 29.95)
) <= 16093.4  -- 10 miles in meters
  AND CURRENT_UPB > 0
ORDER BY MILES_FROM_LANDFALL;

-- Identify loans within FEMA flood zone polygons
SELECT
    lp.LOAN_ID,
    lp.PROPERTY_STATE,
    lp.CURRENT_UPB,
    fz.FLOOD_ZONE_CODE,
    fz.ZONE_DESCRIPTION,
    fz.ANNUAL_FLOOD_PROBABILITY
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT lp
INNER JOIN MORTGAGE_DB.REFERENCE.FEMA_FLOOD_ZONES fz
    ON ST_WITHIN(lp.PROPERTY_GEO, fz.ZONE_BOUNDARY)
WHERE fz.FLOOD_ZONE_CODE IN ('A', 'AE', 'AH', 'V', 'VE')  -- High-risk zones
  AND lp.CURRENT_UPB > 0;
```

Compute portfolio-level geographic concentration metrics:

```sql
-- Geographic concentration by census tract using H3 grid
SELECT
    H3_POINT_TO_CELL_STRING(PROPERTY_GEO, 6) AS H3_INDEX,
    COUNT(*) AS LOAN_COUNT,
    SUM(CURRENT_UPB) AS TOTAL_UPB,
    AVG(CURRENT_INTEREST_RATE) AS AVG_RATE,
    COUNT_IF(DELINQUENCY_STATUS != '00') AS DQ_COUNT,
    ROUND(COUNT_IF(DELINQUENCY_STATUS != '00') * 100.0 / COUNT(*), 2) AS DQ_RATE_PCT,
    ST_COLLECT(PROPERTY_GEO) AS CLUSTER_GEOMETRY
FROM MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT
WHERE PROPERTY_GEO IS NOT NULL
  AND CURRENT_UPB > 0
GROUP BY H3_INDEX
HAVING TOTAL_UPB > 10000000  -- Focus on high-exposure cells
ORDER BY TOTAL_UPB DESC
LIMIT 50;
```

**Result:** The geospatial analysis identified $4.2 billion in UPB exposure within high-risk FEMA flood zones across 38,000 loans, with 12% lacking flood insurance documentation. The hurricane proximity analysis flagged $800 million in at-risk UPB within 10 miles of historical Category 4+ landfall points. The H3 grid concentration analysis revealed 15 census-tract-level clusters exceeding the $500M exposure threshold, triggering portfolio diversification review. All analysis ran in Snowflake in under 5 minutes, replacing a 2-day GIS export-and-analyze workflow.

**AI Vision:** A climate risk model could combine geospatial loan positions with forward-looking climate projections (sea level rise, wildfire probability, hurricane intensity forecasts) to estimate the portfolio's climate-adjusted expected loss over 10, 20, and 30-year horizons, informing green bond structuring decisions.

---

### Q49. How do you use POLICY_REFERENCES to audit which policies protect loan data?

**Situation:** `MORTGAGE_DB` has masking policies on borrower SSN and credit score columns, row access policies limiting analyst access to their assigned regions, and multiple tag-based policy associations. During a SOC 2 audit, the compliance team needs a complete inventory of every policy protecting sensitive loan data and every object to which those policies are attached.

**Task:** Use the POLICY_REFERENCES function and related metadata views to generate a comprehensive audit report of all data protection policies, their associations, and any unprotected sensitive columns.

**Action:**
Query all policy references for specific objects:

```sql
-- Find all policies attached to the loan performance table
SELECT *
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => 'MORTGAGE_DB.ANALYTICS.LOAN_PERFORMANCE_CURRENT',
    REF_ENTITY_DOMAIN => 'TABLE'
));

-- Find all objects protected by a specific masking policy
SELECT *
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
    POLICY_NAME => 'MORTGAGE_DB.POLICIES.SSN_MASKING_POLICY'
));

-- Find all objects protected by a row access policy
SELECT *
FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
    POLICY_NAME => 'MORTGAGE_DB.POLICIES.REGIONAL_ACCESS_POLICY'
));
```

Generate a comprehensive policy audit report:

```sql
-- Complete inventory of all masking policies and their targets
CREATE OR REPLACE TABLE MORTGAGE_DB.AUDIT.POLICY_AUDIT_REPORT AS
WITH masking_refs AS (
    SELECT
        POLICY_NAME,
        POLICY_KIND,
        REF_DATABASE_NAME,
        REF_SCHEMA_NAME,
        REF_ENTITY_NAME,
        REF_ENTITY_DOMAIN,
        REF_COLUMN_NAME,
        POLICY_STATUS
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        POLICY_NAME => 'MORTGAGE_DB.POLICIES.SSN_MASKING_POLICY'
    ))
    UNION ALL
    SELECT
        POLICY_NAME,
        POLICY_KIND,
        REF_DATABASE_NAME,
        REF_SCHEMA_NAME,
        REF_ENTITY_NAME,
        REF_ENTITY_DOMAIN,
        REF_COLUMN_NAME,
        POLICY_STATUS
    FROM TABLE(INFORMATION_SCHEMA.POLICY_REFERENCES(
        POLICY_NAME => 'MORTGAGE_DB.POLICIES.CREDIT_SCORE_MASKING_POLICY'
    ))
),
all_sensitive_columns AS (
    -- Find all columns tagged as sensitive via object tagging
    SELECT
        OBJECT_DATABASE,
        OBJECT_SCHEMA,
        OBJECT_NAME,
        COLUMN_NAME,
        TAG_VALUE AS SENSITIVITY_LEVEL
    FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
    WHERE TAG_NAME = 'SENSITIVITY_LEVEL'
      AND TAG_VALUE IN ('PII', 'CONFIDENTIAL')
      AND DOMAIN = 'COLUMN'
      AND OBJECT_DATABASE = 'MORTGAGE_DB'
      AND OBJECT_DELETED IS NULL
)
SELECT
    sc.OBJECT_SCHEMA,
    sc.OBJECT_NAME,
    sc.COLUMN_NAME,
    sc.SENSITIVITY_LEVEL,
    COALESCE(mr.POLICY_NAME, '** UNPROTECTED **') AS MASKING_POLICY,
    COALESCE(mr.POLICY_STATUS, 'NONE') AS POLICY_STATUS
FROM all_sensitive_columns sc
LEFT JOIN masking_refs mr
    ON sc.OBJECT_NAME = mr.REF_ENTITY_NAME
    AND sc.COLUMN_NAME = mr.REF_COLUMN_NAME
ORDER BY MASKING_POLICY DESC, sc.OBJECT_SCHEMA, sc.OBJECT_NAME;
```

Identify gaps — sensitive columns without policies:

```sql
-- Alert on unprotected sensitive columns
SELECT
    OBJECT_SCHEMA,
    OBJECT_NAME,
    COLUMN_NAME,
    SENSITIVITY_LEVEL
FROM MORTGAGE_DB.AUDIT.POLICY_AUDIT_REPORT
WHERE MASKING_POLICY = '** UNPROTECTED **'
ORDER BY SENSITIVITY_LEVEL DESC, OBJECT_SCHEMA, OBJECT_NAME;
```

**Result:** The audit report identified 42 columns across 18 tables protected by masking policies and 8 tables with row access policies — all correctly configured. Critically, it also found 3 sensitive columns (borrower income in 2 newly created tables and a co-borrower SSN field) that were tagged as PII but had no masking policy attached. These gaps were remediated within 24 hours. The compliance team now runs this audit weekly as an automated task, and the report is attached to SOC 2 evidence packages.

**AI Vision:** A policy compliance predictor could monitor schema changes (new tables, new columns) in real-time via streams, automatically cross-referencing column names and data samples against known PII patterns to recommend masking policy attachment before sensitive data goes unprotected.

---

### Q50. How do you use Account Usage views to monitor warehouse credits and storage for cost optimization?

**Situation:** The mortgage data platform runs across 8 Snowflake warehouses serving Fannie Mae ETL, Freddie Mac analytics, risk modeling, BI dashboards, and ad-hoc queries. Monthly Snowflake spend has grown to $85K and leadership has requested a detailed cost attribution and optimization analysis. The team needs to identify which warehouses and user groups drive the most spend.

**Task:** Query Snowflake Account Usage views to build a comprehensive cost monitoring dashboard that attributes credits to business functions, identifies optimization opportunities, and tracks month-over-month trends.

**Action:**
Analyze warehouse credit consumption by warehouse and time period:

```sql
-- Monthly credit consumption by warehouse
SELECT
    WAREHOUSE_NAME,
    DATE_TRUNC('month', START_TIME) AS MONTH,
    SUM(CREDITS_USED) AS TOTAL_CREDITS,
    SUM(CREDITS_USED_COMPUTE) AS COMPUTE_CREDITS,
    SUM(CREDITS_USED_CLOUD_SERVICES) AS CLOUD_SERVICES_CREDITS,
    COUNT(DISTINCT DATE_TRUNC('day', START_TIME)) AS ACTIVE_DAYS,
    ROUND(SUM(CREDITS_USED) / COUNT(DISTINCT DATE_TRUNC('day', START_TIME)), 2)
        AS CREDITS_PER_ACTIVE_DAY
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('month', -6, CURRENT_TIMESTAMP())
GROUP BY WAREHOUSE_NAME, DATE_TRUNC('month', START_TIME)
ORDER BY MONTH DESC, TOTAL_CREDITS DESC;
```

Attribute costs to user groups and roles:

```sql
-- Credit attribution by role and query type
SELECT
    qh.WAREHOUSE_NAME,
    qh.ROLE_NAME,
    qh.USER_NAME,
    DATE_TRUNC('month', qh.START_TIME) AS MONTH,
    COUNT(*) AS QUERY_COUNT,
    SUM(qh.TOTAL_ELAPSED_TIME) / 1000 / 3600 AS TOTAL_HOURS,
    SUM(qh.CREDITS_USED_CLOUD_SERVICES) AS CLOUD_CREDITS,
    -- Estimate compute credit attribution by execution time proportion
    SUM(qh.TOTAL_ELAPSED_TIME) AS USER_ELAPSED,
    ROUND(SUM(qh.TOTAL_ELAPSED_TIME) /
        NULLIF(SUM(SUM(qh.TOTAL_ELAPSED_TIME)) OVER (
            PARTITION BY qh.WAREHOUSE_NAME, DATE_TRUNC('month', qh.START_TIME)
        ), 0) * 100, 1) AS PCT_OF_WAREHOUSE_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
WHERE qh.START_TIME >= DATEADD('month', -3, CURRENT_TIMESTAMP())
  AND qh.WAREHOUSE_NAME IS NOT NULL
GROUP BY qh.WAREHOUSE_NAME, qh.ROLE_NAME, qh.USER_NAME, DATE_TRUNC('month', qh.START_TIME)
ORDER BY MONTH DESC, PCT_OF_WAREHOUSE_TIME DESC;
```

Analyze storage costs:

```sql
-- Storage breakdown: active, Time Travel, Fail-safe, stage
SELECT
    DATE_TRUNC('month', USAGE_DATE) AS MONTH,
    ROUND(AVG(STORAGE_BYTES) / POWER(1024, 4), 2) AS AVG_ACTIVE_TB,
    ROUND(AVG(FAILSAFE_BYTES) / POWER(1024, 4), 2) AS AVG_FAILSAFE_TB,
    ROUND(AVG(STAGE_BYTES) / POWER(1024, 4), 2) AS AVG_STAGE_TB,
    ROUND((AVG(STORAGE_BYTES) + AVG(FAILSAFE_BYTES) + AVG(STAGE_BYTES))
        / POWER(1024, 4), 2) AS AVG_TOTAL_TB,
    ROUND((AVG(STORAGE_BYTES) + AVG(FAILSAFE_BYTES) + AVG(STAGE_BYTES))
        / POWER(1024, 4) * 23, 2) AS ESTIMATED_MONTHLY_COST_USD
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE USAGE_DATE >= DATEADD('month', -6, CURRENT_DATE())
GROUP BY DATE_TRUNC('month', USAGE_DATE)
ORDER BY MONTH DESC;
```

Identify warehouse sizing optimization opportunities:

```sql
-- Warehouse utilization: how often are warehouses idle vs. active?
SELECT
    WAREHOUSE_NAME,
    DATE_TRUNC('month', START_TIME) AS MONTH,
    COUNT(*) AS METERING_EVENTS,
    SUM(CREDITS_USED) AS TOTAL_CREDITS,
    -- Check auto-suspend effectiveness
    SUM(CASE WHEN CREDITS_USED = 0 THEN 1 ELSE 0 END) AS IDLE_PERIODS,
    ROUND(SUM(CASE WHEN CREDITS_USED = 0 THEN 1 ELSE 0 END) * 100.0 /
        NULLIF(COUNT(*), 0), 1) AS PCT_IDLE
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('month', -3, CURRENT_TIMESTAMP())
GROUP BY WAREHOUSE_NAME, DATE_TRUNC('month', START_TIME)
ORDER BY TOTAL_CREDITS DESC;

-- Queries that could benefit from warehouse downsizing
SELECT
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    COUNT(*) AS QUERY_COUNT,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY TOTAL_ELAPSED_TIME) / 1000 AS MEDIAN_SEC,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY TOTAL_ELAPSED_TIME) / 1000 AS P95_SEC,
    AVG(BYTES_SCANNED) / POWER(1024, 3) AS AVG_GB_SCANNED,
    AVG(PERCENTAGE_SCANNED_FROM_CACHE) AS AVG_CACHE_HIT_PCT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('month', -1, CURRENT_TIMESTAMP())
  AND EXECUTION_STATUS = 'SUCCESS'
  AND WAREHOUSE_NAME IS NOT NULL
GROUP BY WAREHOUSE_NAME, WAREHOUSE_SIZE
ORDER BY QUERY_COUNT DESC;
```

**Result:** The analysis revealed: (1) the BI_DASHBOARD_WH (LARGE) was oversized — 90% of queries completed in under 5 seconds, so it was downsized to SMALL, saving 1,800 credits/month; (2) the AD_HOC_WH had auto-suspend set to 10 minutes but queries came in bursts — reducing to 1 minute saved 600 credits/month of idle time; (3) the RISK_MODEL_WH consumed 40% of total credits but was used by only 3 users running weekly batch jobs — switching to a scheduled MEDIUM multi-cluster warehouse reduced credits by 30%. Total monthly spend dropped from $85K to $58K — a 32% reduction.

**AI Vision:** A spend forecasting model could project next-month Snowflake costs based on historical trends, planned data growth, and scheduled workload changes, automatically generating budget alerts and recommending proactive warehouse scaling adjustments before costs exceed targets.

---

[Back to Q&A Index](README.md)
