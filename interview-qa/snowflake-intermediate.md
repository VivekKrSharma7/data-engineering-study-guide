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

[Back to Q&A Index](README.md)
