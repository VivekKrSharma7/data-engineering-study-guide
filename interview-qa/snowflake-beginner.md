# Snowflake - Beginner Q&A (STAR Method)

[Back to Q&A Index](README.md)

---

25 beginner questions with answers using the **STAR methodology** (Situation, Task, Action, Result) plus an **AI Vision** — real-world US secondary mortgage market examples.

---

### Q1. What is Snowflake's three-layer architecture and how would you set it up for a mortgage analytics platform?

**Situation:** Fannie Mae's data engineering team needed a centralized analytics platform to consolidate loan acquisition data, monthly performance snapshots, and investor reporting across multiple business units. The legacy on-premises data warehouse was struggling with concurrent analyst queries during month-end close.

**Task:** Design and deploy a Snowflake environment leveraging the three-layer architecture — Cloud Services, Compute (Virtual Warehouses), and Storage — to serve as the foundation for a new mortgage analytics platform handling 50M+ loan records.

**Action:**
Snowflake's three-layer architecture separates concerns cleanly:

1. **Storage Layer** — Created the centralized database and schemas:
```sql
CREATE DATABASE MORTGAGE_ANALYTICS_DB;

CREATE SCHEMA MORTGAGE_ANALYTICS_DB.LOAN_ACQUISITION;
CREATE SCHEMA MORTGAGE_ANALYTICS_DB.LOAN_PERFORMANCE;
CREATE SCHEMA MORTGAGE_ANALYTICS_DB.INVESTOR_REPORTING;
```

2. **Compute Layer** — Provisioned dedicated virtual warehouses per workload:
```sql
CREATE WAREHOUSE ETL_LOADER_WH
  WAREHOUSE_SIZE = 'LARGE'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE;

CREATE WAREHOUSE ANALYST_QUERY_WH
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE;

CREATE WAREHOUSE REPORTING_WH
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;
```

3. **Cloud Services Layer** — Handles authentication, metadata, query optimization, and access control automatically. No provisioning required — Snowflake manages this layer transparently.

**Result:** The three-layer separation meant ETL loads running on `ETL_LOADER_WH` never impacted analyst queries on `ANALYST_QUERY_WH`. Month-end reporting ran concurrently without resource contention. Storage costs were decoupled from compute, reducing annual spend by 35% compared to the legacy always-on appliance.

**AI Vision:** An AI-driven workload classifier could monitor query patterns across all three layers, automatically recommending warehouse consolidation or splitting based on usage trends — for example, detecting that the reporting warehouse is idle 90% of the month and suggesting on-demand scaling only during the 3-day close window.

---

### Q2. How do you right-size virtual warehouses for loan tape processing workloads?

**Situation:** Freddie Mac's data team was processing quarterly loan-level disclosure tapes — each file containing 25M+ rows of loan attributes including credit scores, LTV ratios, and delinquency status. The initial X-Small warehouse was timing out during peak loads, while a 2X-Large warehouse sat underutilized most of the time.

**Task:** Determine the optimal warehouse size for the loan tape ingestion pipeline by benchmarking different sizes against actual workload characteristics, balancing cost against processing speed.

**Action:**
Ran benchmark tests across warehouse sizes with the same loan tape file:

```sql
-- Test with X-Small warehouse
USE WAREHOUSE LOAN_TAPE_XS;
ALTER WAREHOUSE LOAN_TAPE_XS SET WAREHOUSE_SIZE = 'XSMALL';

COPY INTO LOAN_PERFORMANCE.QUARTERLY_DISCLOSURE
FROM @LOAN_STAGE/freddie_mac_q4_2025.csv
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
-- Result: 47 minutes, 1 credit

-- Test with Medium warehouse
ALTER WAREHOUSE LOAN_TAPE_XS SET WAREHOUSE_SIZE = 'MEDIUM';

COPY INTO LOAN_PERFORMANCE.QUARTERLY_DISCLOSURE
FROM @LOAN_STAGE/freddie_mac_q4_2025.csv
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
-- Result: 6 minutes, 4 credits

-- Test with Large warehouse
ALTER WAREHOUSE LOAN_TAPE_XS SET WAREHOUSE_SIZE = 'LARGE';

COPY INTO LOAN_PERFORMANCE.QUARTERLY_DISCLOSURE
FROM @LOAN_STAGE/freddie_mac_q4_2025.csv
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
-- Result: 3 minutes, 8 credits
```

Analyzed the cost-performance ratio and selected Medium as the sweet spot:

```sql
-- Final configuration with auto-suspend
ALTER WAREHOUSE LOAN_TAPE_WH SET
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE
  COMMENT = 'Optimized for quarterly loan tape loads - 25M rows in ~6 min';
```

**Result:** The Medium warehouse delivered the best cost-to-speed ratio — 8x faster than X-Small at only 4x the credit cost. Processing 25M loan records in 6 minutes met the SLA with margin, and auto-suspend at 5 minutes ensured no idle burn. Annual compute savings of $12K compared to running Large continuously.

**AI Vision:** A reinforcement learning agent could continuously tune warehouse size in real-time based on incoming file sizes — automatically scaling up for the quarterly 25M-row full disclosure tapes and scaling down for the weekly 500K-row incremental updates, optimizing cost per record loaded.

---

### Q3. How do you organize databases and schemas for MBS data by agency?

**Situation:** A mortgage data aggregator serving institutional investors needed to manage loan-level and deal-level data from Fannie Mae, Freddie Mac, and Ginnie Mae. Each agency has distinct data formats, disclosure timelines, and regulatory requirements. Analysts needed to query across agencies while maintaining clear data lineage.

**Task:** Design a database and schema hierarchy in Snowflake that logically separates data by agency while enabling cross-agency analytics, following the three-part naming convention (`database.schema.object`).

**Action:**
Implemented a hub-and-spoke model with a shared analytics layer:

```sql
-- Agency-specific databases for raw ingestion
CREATE DATABASE FANNIE_MAE_DB COMMENT = 'Fannie Mae Single-Family loan data';
CREATE DATABASE FREDDIE_MAC_DB COMMENT = 'Freddie Mac Single-Family loan data';
CREATE DATABASE GINNIE_MAE_DB COMMENT = 'Ginnie Mae MBS pool data';

-- Schemas within each agency database
CREATE SCHEMA FANNIE_MAE_DB.RAW_ACQUISITION;
CREATE SCHEMA FANNIE_MAE_DB.RAW_PERFORMANCE;
CREATE SCHEMA FANNIE_MAE_DB.STAGING;

CREATE SCHEMA FREDDIE_MAC_DB.RAW_ORIGINATION;
CREATE SCHEMA FREDDIE_MAC_DB.RAW_MONTHLY;
CREATE SCHEMA FREDDIE_MAC_DB.STAGING;

CREATE SCHEMA GINNIE_MAE_DB.RAW_POOL_LEVEL;
CREATE SCHEMA GINNIE_MAE_DB.RAW_LOAN_LEVEL;
CREATE SCHEMA GINNIE_MAE_DB.STAGING;

-- Cross-agency analytics database
CREATE DATABASE MORTGAGE_ANALYTICS_DB;
CREATE SCHEMA MORTGAGE_ANALYTICS_DB.HARMONIZED;
CREATE SCHEMA MORTGAGE_ANALYTICS_DB.REPORTING;
CREATE SCHEMA MORTGAGE_ANALYTICS_DB.SANDBOX;

-- Example: cross-agency query using fully qualified names
SELECT
    'FNMA' AS agency,
    loan_id,
    orig_upb,
    credit_score
FROM FANNIE_MAE_DB.RAW_ACQUISITION.LOAN_MASTER
UNION ALL
SELECT
    'FHLMC' AS agency,
    loan_seq_num,
    orig_upb,
    borrower_credit_score
FROM FREDDIE_MAC_DB.RAW_ORIGINATION.LOAN_MASTER;
```

**Result:** The hierarchy gave each agency its own isolated namespace for raw data while the `MORTGAGE_ANALYTICS_DB.HARMONIZED` schema provided a unified view. Analysts queried across 150M+ loans from all three agencies using the three-part naming convention. Data lineage was traceable from raw source to harmonized layer, satisfying audit requirements.

**AI Vision:** An NLP-powered metadata cataloging system could automatically map columns across agency schemas — recognizing that Fannie Mae's `credit_score` and Freddie Mac's `borrower_credit_score` represent the same attribute — and auto-generate harmonization views without manual column mapping.

---

### Q4. How do micro-partitions improve loan data storage efficiency in Snowflake?

**Situation:** CoreLogic maintained a loan performance table with 2 billion rows spanning 15 years of monthly snapshots. Analysts typically queried by `reporting_period` (monthly date) and `loan_status` (current, 30-day delinquent, 60-day, etc.). Full table scans were consuming excessive credits despite the data being in Snowflake.

**Task:** Understand and leverage Snowflake's micro-partition architecture to optimize query performance on the massive loan performance dataset without manual indexing or partitioning schemes.

**Action:**
Snowflake automatically organizes data into micro-partitions (50-100MB compressed, immutable columnar files). Examined the existing clustering:

```sql
-- Check current clustering information
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE',
    '(REPORTING_PERIOD, LOAN_STATUS)'
);
-- Output showed clustering_depth of 128 (poor clustering)

-- Query with partition pruning - Snowflake metadata tracks
-- min/max values per micro-partition per column
SELECT
    loan_id,
    current_upb,
    loan_status,
    delinquency_days
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE reporting_period = '2025-12-01'
  AND loan_status IN ('30_DAY', '60_DAY', '90_PLUS');
-- Query profile showed: 4,200 of 185,000 partitions scanned (97.7% pruned)

-- Improve clustering for common query patterns
ALTER TABLE MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
  CLUSTER BY (REPORTING_PERIOD, LOAN_STATUS);

-- After reclustering completes:
-- Same query scans only 320 of 185,000 partitions (99.8% pruned)
```

Verified micro-partition metadata:
```sql
-- Each micro-partition stores columnar data with metadata:
-- MIN/MAX values per column, distinct count, null count
-- Snowflake uses this to skip irrelevant partitions at query time

SELECT
    SYSTEM$CLUSTERING_DEPTH(
        'MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE',
        '(REPORTING_PERIOD, LOAN_STATUS)'
    ) AS clustering_depth;
-- After reclustering: depth = 3 (excellent)
```

**Result:** After defining the clustering key on `(REPORTING_PERIOD, LOAN_STATUS)`, the typical analyst query pruned 99.8% of micro-partitions — scanning 320 partitions instead of 4,200. Query runtime dropped from 45 seconds to 2.1 seconds. The 2-billion-row table felt like querying a small dataset. No indexes to maintain, no manual partition management required.

**AI Vision:** A predictive partition advisor could analyze query logs and automatically recommend clustering keys — detecting that 85% of queries filter on `reporting_period` first, then `loan_status`, and proactively reclustering tables before month-end when query volumes spike.

---

### Q5. How do you use internal stages to stage Fannie Mae loan files for loading?

**Situation:** Fannie Mae publishes quarterly Single-Family Loan-Level Dataset files containing acquisition and performance data. The data engineering team received flat files (`Acquisition_2025Q4.txt` and `Performance_2025Q4.txt`) that needed to be staged in Snowflake before loading into structured tables.

**Task:** Create and manage internal stages in Snowflake to securely stage Fannie Mae loan files, enabling repeatable and auditable data loading pipelines.

**Action:**
Created named internal stages with appropriate file format definitions:

```sql
-- Create a named internal stage for Fannie Mae files
CREATE OR REPLACE STAGE FANNIE_MAE_DB.STAGING.FNMA_LOAN_STAGE
  COMMENT = 'Internal stage for Fannie Mae quarterly loan files';

-- Upload files using SnowSQL CLI
-- PUT file:///data/fannie_mae/Acquisition_2025Q4.txt
--     @FANNIE_MAE_DB.STAGING.FNMA_LOAN_STAGE/acquisition/;

-- PUT file:///data/fannie_mae/Performance_2025Q4.txt
--     @FANNIE_MAE_DB.STAGING.FNMA_LOAN_STAGE/performance/;

-- List staged files to verify upload
LIST @FANNIE_MAE_DB.STAGING.FNMA_LOAN_STAGE;
-- +----------------------------------------------------+----------+-----+
-- | name                                               | size     | md5 |
-- +----------------------------------------------------+----------+-----+
-- | fnma_loan_stage/acquisition/Acquisition_2025Q4.txt | 2.4 GB   | ... |
-- | fnma_loan_stage/performance/Performance_2025Q4.txt | 18.7 GB  | ... |
-- +----------------------------------------------------+----------+-----+

-- Preview staged data before loading
SELECT $1, $2, $3, $4, $5
FROM @FANNIE_MAE_DB.STAGING.FNMA_LOAN_STAGE/acquisition/Acquisition_2025Q4.txt
(FILE_FORMAT => 'FANNIE_MAE_DB.STAGING.FNMA_PIPE_DELIMITED')
LIMIT 10;

-- Create file format matching Fannie Mae's pipe-delimited layout
CREATE OR REPLACE FILE FORMAT FANNIE_MAE_DB.STAGING.FNMA_PIPE_DELIMITED
  TYPE = 'CSV'
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 0
  NULL_IF = ('')
  EMPTY_FIELD_AS_NULL = TRUE
  COMMENT = 'Fannie Mae standard pipe-delimited format';
```

Organized stages by data vintage:
```sql
-- Stage files into date-partitioned paths
-- PUT file:///data/fannie_mae/Acquisition_2025Q4.txt
--     @FANNIE_MAE_DB.STAGING.FNMA_LOAN_STAGE/2025/Q4/acquisition/;

-- Remove staged files after successful load
REMOVE @FANNIE_MAE_DB.STAGING.FNMA_LOAN_STAGE/2025/Q4/acquisition/Acquisition_2025Q4.txt;
```

**Result:** The internal stage provided a secure, managed landing zone within Snowflake — no external cloud storage credentials needed. The 18.7 GB performance file was automatically compressed and encrypted at rest. File listing and preview capabilities allowed validation before loading. The pipeline processed 4 quarterly files per year with full auditability of what was staged and when.

**AI Vision:** An intelligent file watcher with anomaly detection could validate staged files before loading — flagging if a quarterly Fannie Mae file is 40% smaller than expected (indicating truncation) or if column counts differ from the standard 31-field acquisition layout, preventing bad data from entering the pipeline.

---

### Q6. How do you use COPY INTO to bulk load monthly remittance data?

**Situation:** Freddie Mac's monthly investor remittance data — containing payment amounts, scheduled balances, and prepayment information for 12M+ active MBS pools — needed to be loaded into Snowflake on the 25th of each month. The data arrived as multiple compressed CSV files from an SFTP server.

**Task:** Implement a reliable COPY INTO pipeline to bulk load the monthly remittance files into a structured Snowflake table, handling data quality issues and maintaining an audit trail of loaded files.

**Action:**
Built the target table and executed the COPY INTO command:

```sql
-- Target table for remittance data
CREATE TABLE IF NOT EXISTS FREDDIE_MAC_DB.RAW_MONTHLY.REMITTANCE_MONTHLY (
    pool_number        VARCHAR(10),
    reporting_period   DATE,
    scheduled_upb      NUMBER(15,2),
    actual_upb         NUMBER(15,2),
    scheduled_interest NUMBER(12,2),
    principal_paid     NUMBER(12,2),
    interest_paid      NUMBER(12,2),
    prepayment_amount  NUMBER(15,2),
    default_amount     NUMBER(15,2),
    loss_amount        NUMBER(12,2),
    modification_flag  VARCHAR(1),
    load_timestamp     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Bulk load from stage with error handling
COPY INTO FREDDIE_MAC_DB.RAW_MONTHLY.REMITTANCE_MONTHLY (
    pool_number, reporting_period, scheduled_upb, actual_upb,
    scheduled_interest, principal_paid, interest_paid,
    prepayment_amount, default_amount, loss_amount, modification_flag
)
FROM @FREDDIE_MAC_DB.STAGING.FHLMC_REMITTANCE_STAGE/2025/12/
FILE_FORMAT = (
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    DATE_FORMAT = 'YYYY-MM-DD'
    NULL_IF = ('', 'NA', 'NULL')
    ERROR_ON_COLUMN_COUNT_MISMATCH = TRUE
)
PATTERN = '.*remittance_202512.*[.]csv[.]gz'
ON_ERROR = 'CONTINUE'
FORCE = FALSE
PURGE = FALSE;

-- Check load history
SELECT
    file_name,
    status,
    rows_parsed,
    rows_loaded,
    error_count,
    first_error_message
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'REMITTANCE_MONTHLY',
    START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP())
));
```

**Result:** COPY INTO loaded 12.4M remittance records across 48 compressed files in 3 minutes 12 seconds using a Medium warehouse. The `ON_ERROR = 'CONTINUE'` setting captured 237 malformed rows (0.002%) into the load metadata without failing the entire batch. Snowflake's built-in deduplication via `FORCE = FALSE` prevented reloading already-processed files on pipeline retries. Monthly loads ran consistently under the 15-minute SLA.

**AI Vision:** An ML-powered data quality gate could run inline during COPY INTO — validating that prepayment amounts fall within historical norms for each pool type (e.g., 30-year fixed vs. ARM), flagging statistical outliers before they propagate into downstream analytics and investor reports.

---

### Q7. How do you define file formats for processing loan tapes in CSV and Parquet?

**Situation:** Intex Solutions delivered deal-level cash flow data in two formats: legacy CSV exports for backward compatibility and optimized Parquet files for large-scale analytics. The data engineering team at a mortgage REIT needed to support both formats for loading collateral performance data into Snowflake.

**Task:** Create reusable Snowflake file format objects for both CSV and Parquet that handle the specific characteristics of Intex loan tape data, including mixed data types, nullable fields, and embedded special characters.

**Action:**
Defined both file format objects with production-grade settings:

```sql
-- CSV file format for legacy Intex exports
CREATE OR REPLACE FILE FORMAT MORTGAGE_DB.LOAN_SCHEMA.INTEX_CSV_FORMAT
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  RECORD_DELIMITER = '\n'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'N/A', 'NULL', '#N/A')
  TRIM_SPACE = TRUE
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  DATE_FORMAT = 'MM/DD/YYYY'
  TIMESTAMP_FORMAT = 'MM/DD/YYYY HH24:MI:SS'
  ESCAPE_UNENCLOSED_FIELD = '\\'
  COMMENT = 'Intex CSV loan tape format with quoted fields and mixed nulls';

-- Parquet file format for optimized Intex exports
CREATE OR REPLACE FILE FORMAT MORTGAGE_DB.LOAN_SCHEMA.INTEX_PARQUET_FORMAT
  TYPE = 'PARQUET'
  COMPRESSION = 'SNAPPY'
  BINARY_AS_TEXT = FALSE
  COMMENT = 'Intex Parquet format - schema-on-read with Snappy compression';

-- Verify format definitions
SHOW FILE FORMATS IN SCHEMA MORTGAGE_DB.LOAN_SCHEMA;

-- Preview CSV data using the format
SELECT $1 AS deal_id, $2 AS tranche_id, $3 AS collateral_balance,
       $4 AS coupon_rate, $5 AS wac, $6 AS wam
FROM @MORTGAGE_DB.LOAN_SCHEMA.INTEX_STAGE/cashflows_2025Q4.csv
(FILE_FORMAT => 'MORTGAGE_DB.LOAN_SCHEMA.INTEX_CSV_FORMAT')
LIMIT 5;

-- Preview Parquet data using the format (schema auto-detected)
SELECT
    $1:deal_id::VARCHAR AS deal_id,
    $1:tranche_id::VARCHAR AS tranche_id,
    $1:collateral_balance::NUMBER(15,2) AS collateral_balance,
    $1:coupon_rate::NUMBER(6,4) AS coupon_rate,
    $1:wac::NUMBER(6,4) AS wac,
    $1:wam::INTEGER AS wam
FROM @MORTGAGE_DB.LOAN_SCHEMA.INTEX_STAGE/cashflows_2025Q4.parquet
(FILE_FORMAT => 'MORTGAGE_DB.LOAN_SCHEMA.INTEX_PARQUET_FORMAT')
LIMIT 5;
```

Compared loading performance:
```sql
-- CSV load: 8.2M rows in 4 min 30 sec
COPY INTO MORTGAGE_DB.LOAN_SCHEMA.DEAL_CASHFLOWS
FROM @MORTGAGE_DB.LOAN_SCHEMA.INTEX_STAGE/cashflows_2025Q4.csv
FILE_FORMAT = MORTGAGE_DB.LOAN_SCHEMA.INTEX_CSV_FORMAT;

-- Parquet load: 8.2M rows in 1 min 15 sec (3.6x faster)
COPY INTO MORTGAGE_DB.LOAN_SCHEMA.DEAL_CASHFLOWS
FROM @MORTGAGE_DB.LOAN_SCHEMA.INTEX_STAGE/cashflows_2025Q4.parquet
FILE_FORMAT = MORTGAGE_DB.LOAN_SCHEMA.INTEX_PARQUET_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

**Result:** Both file formats were stored as reusable objects, eliminating format specification duplication across 30+ COPY INTO statements. Parquet loads ran 3.6x faster than CSV due to columnar storage and built-in compression. The `MATCH_BY_COLUMN_NAME` option for Parquet eliminated column ordering issues that caused data mapping bugs with CSV. The team standardized on Parquet for all new Intex deliveries while maintaining CSV support for historical reloads.

**AI Vision:** A schema evolution detector could compare incoming Parquet file schemas against the target table definition, automatically generating ALTER TABLE statements when Intex adds new fields (e.g., a new ESG risk score column) — keeping the pipeline running without manual intervention.

---

### Q8. How do you use Time Travel to recover accidentally deleted pool data?

**Situation:** A junior analyst at Ginnie Mae ran a DELETE statement without a WHERE clause on the `POOL_MASTER` table during a data cleanup task, accidentally removing all 850,000 active Ginnie Mae II MBS pool records. The deletion was discovered 2 hours later when downstream reports returned empty results.

**Task:** Use Snowflake's Time Travel feature to recover the deleted pool records without restoring from backup, minimizing downtime for the investor reporting pipeline.

**Action:**
Leveraged Time Travel to query and restore the data as it existed before the deletion:

```sql
-- Step 1: Verify the table is now empty
SELECT COUNT(*) FROM GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER;
-- Returns: 0

-- Step 2: Check when the DELETE happened using query history
SELECT query_id, query_text, start_time, rows_produced
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE query_text ILIKE '%DELETE%POOL_MASTER%'
ORDER BY start_time DESC
LIMIT 5;
-- Found: DELETE executed at 2025-12-15 10:23:45

-- Step 3: Query the table as it existed BEFORE the delete
SELECT COUNT(*)
FROM GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER
AT(TIMESTAMP => '2025-12-15T10:20:00'::TIMESTAMP);
-- Returns: 850,247 (all records present)

-- Step 4: Restore using CLONE with Time Travel
CREATE TABLE GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER_RESTORED
  CLONE GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER
  AT(TIMESTAMP => '2025-12-15T10:20:00'::TIMESTAMP);

-- Step 5: Verify restored data
SELECT COUNT(*) FROM GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER_RESTORED;
-- Returns: 850,247

-- Step 6: Swap the tables
ALTER TABLE GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER
  RENAME TO GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER_DELETED;

ALTER TABLE GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER_RESTORED
  RENAME TO GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER;

-- Step 7: Cleanup
DROP TABLE GINNIE_MAE_DB.RAW_POOL_LEVEL.POOL_MASTER_DELETED;
```

**Result:** All 850,247 Ginnie Mae pool records were fully restored in under 5 minutes using Time Travel, with zero data loss. No backup restoration was needed. The investor reporting pipeline resumed on schedule. The team subsequently implemented a governance policy requiring all DELETE operations to go through a stored procedure with mandatory WHERE clause validation.

**AI Vision:** A real-time anomaly detection system could monitor DML operations and instantly alert (or block) when a DELETE or UPDATE affects more than a configurable percentage of rows — catching the accidental full-table DELETE before it committed and saving the 2-hour detection delay.

---

### Q9. How does Fail-safe work for mortgage data compliance and disaster recovery?

**Situation:** A mortgage servicer's compliance team needed to understand the data retention guarantees in Snowflake for regulatory purposes. FHFA regulations require that loan-level performance data be recoverable for at least 7 years. The team needed to understand the relationship between Time Travel and Fail-safe and how they protect against data loss.

**Task:** Document and demonstrate how Snowflake's Fail-safe layer provides an additional 7-day non-configurable safety net beyond Time Travel, and design retention settings that satisfy mortgage compliance requirements.

**Action:**
Configured Time Travel and understood Fail-safe boundaries:

```sql
-- Set Time Travel retention to maximum 90 days for critical tables
ALTER TABLE MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
  SET DATA_RETENTION_TIME_IN_DAYS = 90;

-- Verify retention settings
SHOW TABLES LIKE 'LOAN_PERFORMANCE' IN SCHEMA MORTGAGE_DB.LOAN_SCHEMA;
-- retention_time = 90

-- Time Travel timeline:
-- Day 0-90:  Time Travel (user-accessible recovery)
-- Day 91-97: Fail-safe (Snowflake support only, 7 days)
-- Day 98+:   Data permanently purged

-- Check storage costs including Fail-safe
SELECT
    TABLE_NAME,
    ACTIVE_BYTES / POWER(1024, 3) AS active_gb,
    TIME_TRAVEL_BYTES / POWER(1024, 3) AS time_travel_gb,
    FAILSAFE_BYTES / POWER(1024, 3) AS failsafe_gb,
    (ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES)
        / POWER(1024, 3) AS total_gb
FROM MORTGAGE_DB.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_NAME = 'LOAN_PERFORMANCE';
-- active_gb: 45.2, time_travel_gb: 12.8, failsafe_gb: 6.3, total_gb: 64.3

-- For long-term compliance: use TRANSIENT tables for staging,
-- PERMANENT tables for compliance-critical data
CREATE TRANSIENT TABLE MORTGAGE_DB.LOAN_SCHEMA.LOAN_STAGING (
    -- No Fail-safe, reduced storage cost for temporary data
    loan_id VARCHAR(20),
    raw_data VARIANT
);

-- Permanent table retains Fail-safe protection
CREATE TABLE MORTGAGE_DB.LOAN_SCHEMA.LOAN_COMPLIANCE_ARCHIVE (
    loan_id            VARCHAR(20),
    reporting_period   DATE,
    loan_status        VARCHAR(20),
    current_upb        NUMBER(15,2),
    archive_timestamp  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) DATA_RETENTION_TIME_IN_DAYS = 90;
```

**Result:** The compliance team documented that Snowflake provides up to 97 days of built-in recoverability (90 days Time Travel + 7 days Fail-safe) for permanent tables. For the 7-year FHFA requirement, the team complemented Snowflake's native features with automated monthly exports to long-term cloud storage. Fail-safe storage added only 14% overhead to the critical compliance tables — an acceptable cost for the regulatory safety net.

**AI Vision:** An AI compliance monitor could continuously verify that all regulatory-critical tables maintain proper retention settings, automatically detecting and remediating configuration drift — for example, alerting when someone changes a compliance table from permanent to transient, which would remove Fail-safe protection.

---

### Q10. How do you set up role-based access control (RBAC) for loan analysts vs. administrators?

**Situation:** A secondary mortgage market analytics firm had 50+ users accessing Snowflake — including loan analysts who needed read access to performance data, data engineers who needed write access for ETL, and administrators who managed the entire platform. Without proper RBAC, all users had been sharing a single admin account, creating audit and security risks.

**Task:** Implement a role hierarchy following Snowflake's RBAC model that enforces least-privilege access, separating loan analysts (read-only), data engineers (read-write), and administrators (full control) with proper inheritance.

**Action:**
Designed and implemented the role hierarchy:

```sql
-- Create functional roles
CREATE ROLE LOAN_ANALYST_ROLE
  COMMENT = 'Read-only access to loan performance and pool data';

CREATE ROLE DATA_ENGINEER_ROLE
  COMMENT = 'Read-write access for ETL pipelines';

CREATE ROLE MORTGAGE_ADMIN_ROLE
  COMMENT = 'Full administrative access to mortgage databases';

-- Build role hierarchy (inheritance flows upward)
GRANT ROLE LOAN_ANALYST_ROLE TO ROLE DATA_ENGINEER_ROLE;
GRANT ROLE DATA_ENGINEER_ROLE TO ROLE MORTGAGE_ADMIN_ROLE;
GRANT ROLE MORTGAGE_ADMIN_ROLE TO ROLE SYSADMIN;

-- Grant warehouse usage
GRANT USAGE ON WAREHOUSE ANALYST_QUERY_WH TO ROLE LOAN_ANALYST_ROLE;
GRANT USAGE ON WAREHOUSE ETL_LOADER_WH TO ROLE DATA_ENGINEER_ROLE;
GRANT ALL ON WAREHOUSE ETL_LOADER_WH TO ROLE MORTGAGE_ADMIN_ROLE;

-- Analyst permissions: read-only
GRANT USAGE ON DATABASE MORTGAGE_DB TO ROLE LOAN_ANALYST_ROLE;
GRANT USAGE ON ALL SCHEMAS IN DATABASE MORTGAGE_DB TO ROLE LOAN_ANALYST_ROLE;
GRANT SELECT ON ALL TABLES IN SCHEMA MORTGAGE_DB.LOAN_SCHEMA TO ROLE LOAN_ANALYST_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA MORTGAGE_DB.LOAN_SCHEMA TO ROLE LOAN_ANALYST_ROLE;

-- Engineer permissions: read-write on staging and production
GRANT ALL ON SCHEMA MORTGAGE_DB.STAGING TO ROLE DATA_ENGINEER_ROLE;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA MORTGAGE_DB.LOAN_SCHEMA
  TO ROLE DATA_ENGINEER_ROLE;

-- Admin permissions: full control
GRANT ALL ON DATABASE MORTGAGE_DB TO ROLE MORTGAGE_ADMIN_ROLE;

-- Assign roles to users
GRANT ROLE LOAN_ANALYST_ROLE TO USER jsmith_analyst;
GRANT ROLE LOAN_ANALYST_ROLE TO USER mchen_analyst;
GRANT ROLE DATA_ENGINEER_ROLE TO USER kpatel_engineer;
GRANT ROLE MORTGAGE_ADMIN_ROLE TO USER admin_user;

-- Sensitive PII masking for analysts
CREATE OR REPLACE MASKING POLICY MORTGAGE_DB.LOAN_SCHEMA.SSN_MASK AS
  (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('MORTGAGE_ADMIN_ROLE', 'DATA_ENGINEER_ROLE')
    THEN val
    ELSE '***-**-' || SUBSTR(val, 8, 4)
  END;

ALTER TABLE MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
  MODIFY COLUMN borrower_ssn SET MASKING POLICY MORTGAGE_DB.LOAN_SCHEMA.SSN_MASK;
```

**Result:** The 50+ users were cleanly segmented: 35 analysts with read-only access, 10 engineers with ETL privileges, and 5 admins with full control. The role hierarchy meant engineers automatically inherited analyst permissions. The SSN masking policy ensured analysts only saw last-4 digits, satisfying GLBA privacy requirements. Audit logs now showed individual user accountability for every query.

**AI Vision:** An access analytics engine could monitor actual query patterns per role and recommend privilege reduction — detecting that 12 of 35 analysts never query the `DEAL_MASTER` table and suggesting more granular role splitting, continuously enforcing least-privilege as team responsibilities evolve.

---

### Q11. How do you design a loan performance table using CREATE TABLE in Snowflake?

**Situation:** Fannie Mae's data platform team needed to create the core `LOAN_PERFORMANCE` table to store monthly loan-level snapshots from the Single-Family Loan Performance Dataset. The table would hold 15+ years of monthly data — approximately 3 billion rows — and serve as the foundation for prepayment modeling, delinquency tracking, and loss severity analysis.

**Task:** Design and create a production-grade `LOAN_PERFORMANCE` table with appropriate column definitions, constraints, clustering, and metadata that reflects Fannie Mae's actual data dictionary.

**Action:**
Created the table with carefully chosen data types and clustering:

```sql
CREATE OR REPLACE TABLE MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE (
    -- Primary identifiers
    loan_sequence_number    VARCHAR(12)     NOT NULL,
    reporting_period        DATE            NOT NULL,

    -- Loan characteristics (point-in-time)
    current_upb             NUMBER(15,2),
    loan_age                SMALLINT,
    remaining_months        SMALLINT,
    adjusted_remaining      SMALLINT,
    maturity_date           DATE,
    msa_code                VARCHAR(5),
    current_interest_rate   NUMBER(6,3),

    -- Delinquency tracking
    current_loan_status     VARCHAR(10),
    delinquency_status      VARCHAR(3),
    days_delinquent         SMALLINT        DEFAULT 0,
    modification_flag       BOOLEAN         DEFAULT FALSE,

    -- Loss mitigation
    zero_balance_code       VARCHAR(2),
    zero_balance_date       DATE,
    last_paid_installment   DATE,
    foreclosure_date        DATE,
    disposition_date        DATE,
    foreclosure_costs       NUMBER(12,2),
    property_preservation   NUMBER(12,2),
    asset_recovery_costs    NUMBER(12,2),
    misc_expenses           NUMBER(12,2),
    associated_taxes        NUMBER(12,2),
    net_sale_proceeds       NUMBER(15,2),
    credit_enhancement      NUMBER(12,2),
    repurchase_make_whole   NUMBER(15,2),
    actual_loss             NUMBER(15,2),

    -- Metadata
    load_batch_id           VARCHAR(36),
    load_timestamp          TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),

    -- Constraints
    CONSTRAINT pk_loan_perf PRIMARY KEY (loan_sequence_number, reporting_period)
)
CLUSTER BY (reporting_period, current_loan_status)
DATA_RETENTION_TIME_IN_DAYS = 90
COMMENT = 'Fannie Mae Single-Family Loan Performance - monthly snapshots';

-- Add table-level tags for governance
ALTER TABLE MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
  SET TAG data_classification = 'CONFIDENTIAL',
      data_domain = 'LOAN_PERFORMANCE',
      source_system = 'FANNIE_MAE';
```

**Result:** The table design accommodated all 30+ fields from Fannie Mae's loan performance data dictionary with appropriate precision. The composite primary key on `(loan_sequence_number, reporting_period)` enforced one record per loan per month. Clustering on `(reporting_period, current_loan_status)` optimized the two most common query patterns. With 90-day Time Travel, any accidental data corruption could be reversed within three months. The table successfully held 3.1 billion rows consuming 142 GB of compressed storage.

**AI Vision:** A data modeling assistant could analyze incoming Fannie Mae data dictionary updates and automatically generate ALTER TABLE migration scripts — detecting new columns, changed data types, or deprecated fields and producing version-controlled DDL changes with impact analysis on downstream views and reports.

---

### Q12. How do you choose appropriate Snowflake data types for mortgage data fields?

**Situation:** A data engineer at Freddie Mac was migrating loan origination data from SQL Server to Snowflake. The source system used SQL Server-specific types like `MONEY`, `DATETIME2`, `BIT`, and `NVARCHAR(MAX)`. Choosing incorrect Snowflake types could lead to precision loss on financial amounts, storage waste, or query performance issues.

**Task:** Map each mortgage-specific field to the optimal Snowflake data type, considering precision requirements for financial calculations, storage efficiency, and query performance across a 500M-row origination dataset.

**Action:**
Performed a systematic type mapping for mortgage fields:

```sql
CREATE OR REPLACE TABLE FREDDIE_MAC_DB.RAW_ORIGINATION.LOAN_MASTER (
    -- Identifiers: VARCHAR with constrained length
    -- SQL Server NVARCHAR(20) -> Snowflake VARCHAR(20)
    loan_seq_number        VARCHAR(20)     NOT NULL,
    seller_name            VARCHAR(100),
    servicer_name          VARCHAR(100),

    -- Financial amounts: NUMBER with explicit precision
    -- SQL Server MONEY (4 decimal) -> NUMBER(15,2) for UPB
    orig_upb               NUMBER(15,2)    NOT NULL,  -- max $999 trillion
    orig_interest_rate     NUMBER(6,3),    -- e.g., 6.375
    orig_ltv               NUMBER(5,2),    -- e.g., 80.00
    orig_cltv              NUMBER(5,2),    -- combined LTV
    dti_ratio              NUMBER(5,2),    -- debt-to-income

    -- Credit scores: SMALLINT (range 300-850)
    -- SQL Server INT -> SMALLINT saves storage at scale
    borrower_credit_score  SMALLINT,
    coborrower_credit_score SMALLINT,

    -- Dates: DATE (not TIMESTAMP) for date-only fields
    -- SQL Server DATETIME2 -> DATE when time is irrelevant
    first_payment_date     DATE,
    maturity_date          DATE,
    origination_date       DATE,

    -- Categorical: VARCHAR with tight lengths
    loan_purpose           VARCHAR(1),     -- P=Purchase, R=Refi, C=Cash-out
    property_type          VARCHAR(2),     -- SF, CO, CP, MH, PU
    occupancy_status       VARCHAR(1),     -- P=Primary, S=Second, I=Investment
    channel                VARCHAR(1),     -- R=Retail, B=Broker, C=Correspondent
    state                  VARCHAR(2),     -- US state code
    zip_3                  VARCHAR(3),     -- 3-digit ZIP

    -- Flags: BOOLEAN (not BIT or CHAR(1))
    -- SQL Server BIT -> BOOLEAN
    first_time_buyer_flag  BOOLEAN,
    prepayment_penalty_flag BOOLEAN,

    -- Counts: INTEGER or SMALLINT based on range
    number_of_units        SMALLINT,       -- 1-4 for residential
    number_of_borrowers    SMALLINT,
    loan_term              SMALLINT,       -- 180 or 360 months

    -- Metadata timestamps: TIMESTAMP_NTZ for internal tracking
    load_timestamp         TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP(),
    source_file_name       VARCHAR(256)
);

-- Verify storage impact of type choices
SELECT
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    NUMERIC_PRECISION,
    NUMERIC_SCALE
FROM FREDDIE_MAC_DB.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'LOAN_MASTER'
  AND TABLE_SCHEMA = 'RAW_ORIGINATION'
ORDER BY ORDINAL_POSITION;
```

**Result:** The type mapping reduced storage by 22% compared to a naive migration using VARCHAR and NUMBER without precision constraints. Financial fields retained full cent-level precision using `NUMBER(15,2)` — critical for loss calculations. Using `SMALLINT` for credit scores (range 300-850) instead of `INTEGER` was more semantically clear. `BOOLEAN` types for flags enabled cleaner query syntax (`WHERE first_time_buyer_flag` vs. `WHERE first_time_buyer_flag = 'Y'`). The 500M-row table consumed 18.4 GB compressed.

**AI Vision:** An automated schema inference engine could analyze sample data from new Freddie Mac file deliveries, recommend optimal Snowflake types by examining value distributions (e.g., detecting that `loan_term` only contains values 180 and 360, suggesting an ENUM-style constraint), and flag potential precision loss before migration.

---

### Q13. How do you use the VARIANT data type to store semi-structured deal metadata?

**Situation:** Intex Solutions provided MBS deal waterfall metadata in JSON format — containing complex nested structures for tranche definitions, trigger events, credit enhancement rules, and payment priority waterfalls. Each deal had a unique structure, making traditional relational modeling impractical for the 45,000+ active deals in the database.

**Task:** Store the semi-structured Intex deal metadata in Snowflake using the VARIANT data type, enabling flexible querying across deals with different structures without requiring schema changes for each deal type.

**Action:**
Created a VARIANT-based table and demonstrated querying nested JSON:

```sql
-- Table with VARIANT column for flexible deal metadata
CREATE TABLE MORTGAGE_DB.LOAN_SCHEMA.DEAL_MASTER (
    deal_id          VARCHAR(30)     NOT NULL PRIMARY KEY,
    agency           VARCHAR(10),    -- FNMA, FHLMC, GNMA, PLS
    deal_name        VARCHAR(100),
    closing_date     DATE,
    deal_metadata    VARIANT,        -- Full Intex JSON structure
    load_timestamp   TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- Insert deal with complex nested JSON metadata
INSERT INTO MORTGAGE_DB.LOAN_SCHEMA.DEAL_MASTER
  (deal_id, agency, deal_name, closing_date, deal_metadata)
SELECT
    'FNR-2025-C04',
    'FNMA',
    'Fannie Mae REMIC Trust 2025-C04',
    '2025-09-15',
    PARSE_JSON('{
        "issuer": "Fannie Mae",
        "trustee": "US Bank",
        "total_balance": 1250000000.00,
        "collateral": {
            "loan_count": 4532,
            "wac": 5.875,
            "wam": 342,
            "avg_loan_size": 275770.00,
            "geo_concentration": {
                "CA": 0.22, "TX": 0.14, "FL": 0.11, "NY": 0.09
            }
        },
        "tranches": [
            {"tranche_id": "A1", "class": "Senior", "balance": 750000000, "coupon": 4.50, "rating": "AAA"},
            {"tranche_id": "A2", "class": "Senior", "balance": 300000000, "coupon": 5.00, "rating": "AAA"},
            {"tranche_id": "M1", "class": "Mezzanine", "balance": 125000000, "coupon": 5.75, "rating": "AA"},
            {"tranche_id": "B1", "class": "Subordinate", "balance": 75000000, "coupon": 6.50, "rating": "BBB"}
        ],
        "triggers": {
            "delinquency_trigger": 0.045,
            "cumulative_loss_trigger": 0.025,
            "credit_enhancement_floor": 0.05
        }
    }');

-- Query VARIANT data using dot notation and lateral flatten
-- Find deals with California concentration above 20%
SELECT
    deal_id,
    deal_name,
    deal_metadata:collateral.loan_count::INT AS loan_count,
    deal_metadata:collateral.wac::NUMBER(6,3) AS wac,
    deal_metadata:collateral.geo_concentration.CA::NUMBER(4,2) AS ca_pct
FROM MORTGAGE_DB.LOAN_SCHEMA.DEAL_MASTER
WHERE deal_metadata:collateral.geo_concentration.CA::FLOAT > 0.20;

-- Flatten nested tranche array to query individual tranches
SELECT
    d.deal_id,
    d.deal_name,
    t.value:tranche_id::VARCHAR AS tranche_id,
    t.value:class::VARCHAR AS tranche_class,
    t.value:balance::NUMBER(15,2) AS tranche_balance,
    t.value:coupon::NUMBER(6,3) AS coupon_rate,
    t.value:rating::VARCHAR AS rating
FROM MORTGAGE_DB.LOAN_SCHEMA.DEAL_MASTER d,
LATERAL FLATTEN(input => d.deal_metadata:tranches) t
WHERE t.value:class::VARCHAR = 'Senior';
```

**Result:** The VARIANT column stored 45,000+ deal structures — each with unique tranche configurations, trigger definitions, and waterfall rules — without any schema changes. Queries using dot notation and FLATTEN ran in sub-second times thanks to Snowflake's internal columnar representation of VARIANT data. The team no longer needed to redesign tables when Intex introduced new metadata fields (like ESG scores or climate risk factors). Storage was only 15% larger than equivalent relational tables due to Snowflake's efficient VARIANT compression.

**AI Vision:** A knowledge graph built on the VARIANT deal metadata could automatically identify structural similarities between deals — clustering deals by waterfall type, trigger configurations, and tranche structures to enable "similar deals" analysis for pricing new issuances based on comparable transaction structures.

---

### Q14. How do you query delinquent loans using SELECT, WHERE, and ORDER BY?

**Situation:** Fannie Mae's loss mitigation team needed a daily report of loans transitioning into serious delinquency (60+ days past due) for the December 2025 reporting period. The report needed to prioritize high-balance loans in judicial foreclosure states, as these represent the greatest potential loss exposure.

**Task:** Write a production query using SELECT, WHERE, and ORDER BY to extract delinquent loans meeting specific criteria, formatted for the loss mitigation team's daily review queue.

**Action:**
Built the query with layered filtering and meaningful sorting:

```sql
-- Daily delinquency report for loss mitigation team
SELECT
    lp.loan_sequence_number,
    lp.reporting_period,
    lp.current_upb,
    lp.current_interest_rate,
    lp.days_delinquent,
    lp.current_loan_status,
    lp.delinquency_status,
    lp.msa_code,
    lo.state,
    lo.property_type,
    lo.orig_upb,
    lo.borrower_credit_score AS orig_credit_score,
    ROUND((lp.current_upb / lo.orig_upb) * 100, 2) AS current_to_orig_pct,
    DATEDIFF('month', lo.origination_date, lp.reporting_period) AS loan_age_months
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
    INNER JOIN MORTGAGE_DB.LOAN_SCHEMA.LOAN_ORIGINATION lo
        ON lp.loan_sequence_number = lo.loan_sequence_number
WHERE lp.reporting_period = '2025-12-01'
  AND lp.days_delinquent >= 60
  AND lp.current_upb > 0
  AND lp.zero_balance_code IS NULL
  AND lo.state IN ('NY', 'NJ', 'CT', 'FL', 'IL', 'HI', 'IN', 'KY', 'LA',
                    'ME', 'MD', 'NE', 'NM', 'ND', 'OH', 'OK', 'PA', 'SC', 'VT', 'WI')
ORDER BY
    lp.days_delinquent DESC,
    lp.current_upb DESC,
    lo.state ASC;

-- Result summary statistics
SELECT
    current_loan_status,
    COUNT(*) AS loan_count,
    SUM(current_upb) AS total_upb,
    AVG(current_upb) AS avg_upb,
    MIN(days_delinquent) AS min_days_dlq,
    MAX(days_delinquent) AS max_days_dlq
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE reporting_period = '2025-12-01'
  AND days_delinquent >= 60
  AND current_upb > 0
GROUP BY current_loan_status
ORDER BY total_upb DESC;
```

**Result:** The query returned 23,847 loans with 60+ days delinquency across judicial foreclosure states, totaling $7.2B in outstanding balance. Sorting by delinquency severity and then balance ensured the highest-risk loans appeared at the top of the review queue. The loss mitigation team prioritized 142 loans with 180+ days delinquent and balance exceeding $500K — representing $98M in concentrated exposure. Query executed in 3.4 seconds against 180M performance records thanks to micro-partition pruning on `reporting_period`.

**AI Vision:** A loan-level default prediction model could augment this query with ML-generated probability-of-default scores, automatically ranking the delinquency queue by expected loss severity rather than simple balance and days-past-due — enabling the loss mitigation team to focus on loans where early intervention has the highest dollar-weighted impact.

---

### Q15. How do you use JOINs to link loan data with property valuations?

**Situation:** CoreLogic's analytics team needed to combine loan performance data with updated property valuations (Automated Valuation Models — AVMs) to calculate current loan-to-value (LTV) ratios. High current-LTV loans (underwater loans where value dropped below the mortgage balance) are critical for credit risk assessment and loss-given-default modeling.

**Task:** Join the loan performance table with the CoreLogic property valuation table to identify underwater loans, using appropriate join types to handle loans with and without updated valuations.

**Action:**
Implemented multiple join types for different analytical needs:

```sql
-- INNER JOIN: Loans with matching property valuations
SELECT
    lp.loan_id,
    lp.current_upb,
    lp.origination_date,
    lp.orig_ltv,
    pv.avm_value,
    pv.avm_confidence_score,
    pv.valuation_date,
    ROUND((lp.current_upb / pv.avm_value) * 100, 2) AS current_ltv,
    CASE
        WHEN lp.current_upb > pv.avm_value THEN 'UNDERWATER'
        WHEN lp.current_upb > pv.avm_value * 0.80 THEN 'HIGH_LTV'
        WHEN lp.current_upb > pv.avm_value * 0.60 THEN 'MODERATE_LTV'
        ELSE 'LOW_LTV'
    END AS ltv_category
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
INNER JOIN MORTGAGE_DB.LOAN_SCHEMA.PROPERTY_VALUATIONS pv
    ON lp.property_id = pv.property_id
WHERE lp.reporting_period = '2025-12-01'
  AND lp.current_upb > 0
  AND pv.valuation_date >= '2025-10-01'  -- Recent valuations only
ORDER BY current_ltv DESC;

-- LEFT JOIN: All loans, including those without valuations
SELECT
    lp.loan_id,
    lp.current_upb,
    lp.property_id,
    pv.avm_value,
    CASE
        WHEN pv.avm_value IS NULL THEN 'NO_VALUATION'
        WHEN lp.current_upb > pv.avm_value THEN 'UNDERWATER'
        ELSE 'ABOVE_WATER'
    END AS valuation_status,
    COALESCE(
        ROUND((lp.current_upb / NULLIF(pv.avm_value, 0)) * 100, 2),
        lp.orig_ltv  -- Fall back to original LTV if no AVM
    ) AS best_available_ltv
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
LEFT JOIN MORTGAGE_DB.LOAN_SCHEMA.PROPERTY_VALUATIONS pv
    ON lp.property_id = pv.property_id
    AND pv.valuation_date = (
        SELECT MAX(valuation_date)
        FROM MORTGAGE_DB.LOAN_SCHEMA.PROPERTY_VALUATIONS pv2
        WHERE pv2.property_id = pv.property_id
    )
WHERE lp.reporting_period = '2025-12-01'
  AND lp.current_upb > 0;

-- Summary: underwater loan exposure by state
SELECT
    lo.state,
    COUNT(*) AS underwater_count,
    SUM(lp.current_upb) AS total_underwater_upb,
    AVG(ROUND((lp.current_upb / pv.avm_value) * 100, 2)) AS avg_current_ltv,
    MAX(ROUND((lp.current_upb / pv.avm_value) * 100, 2)) AS max_current_ltv
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
INNER JOIN MORTGAGE_DB.LOAN_SCHEMA.PROPERTY_VALUATIONS pv
    ON lp.property_id = pv.property_id
INNER JOIN MORTGAGE_DB.LOAN_SCHEMA.LOAN_ORIGINATION lo
    ON lp.loan_id = lo.loan_id
WHERE lp.reporting_period = '2025-12-01'
  AND lp.current_upb > pv.avm_value
  AND pv.valuation_date >= '2025-10-01'
GROUP BY lo.state
ORDER BY total_underwater_upb DESC
LIMIT 10;
```

**Result:** The INNER JOIN identified 47,200 underwater loans (current LTV > 100%) with a combined balance of $14.8B. The LEFT JOIN revealed that 8% of active loans lacked recent AVM valuations — these were flagged for manual review. The state-level summary showed Florida, Nevada, and Arizona had the highest concentrations of underwater loans by dollar volume. The three-table join executed in 6.2 seconds across 50M loan records and 35M property valuations.

**AI Vision:** A computer vision model processing satellite imagery and street-view data could generate real-time property condition adjustments to AVM values — detecting deferred maintenance, neighborhood deterioration, or new construction that traditional AVM algorithms miss, improving current-LTV accuracy for credit risk models.

---

### Q16. How do you use aggregate functions to calculate pool-level statistics?

**Situation:** Ginnie Mae's investor reporting team needed to produce monthly pool factor reports for 400,000+ active MBS pools. Each pool's statistics — including remaining balance, weighted average coupon (WAC), weighted average maturity (WAM), and delinquency rates — must be calculated from the underlying loan-level data and published to investors by the 15th of each month.

**Task:** Write aggregate queries that calculate pool-level statistics from loan-level performance data, including weighted averages and conditional aggregations for delinquency bucketing.

**Action:**
Built comprehensive pool-level aggregation queries:

```sql
-- Pool-level statistics with weighted averages
SELECT
    pool_number,
    reporting_period,
    COUNT(*) AS loan_count,
    SUM(current_upb) AS pool_remaining_balance,
    SUM(original_upb) AS pool_original_balance,
    ROUND(SUM(current_upb) / NULLIF(SUM(original_upb), 0), 8) AS pool_factor,

    -- Weighted Average Coupon (WAC): weighted by current UPB
    ROUND(
        SUM(current_interest_rate * current_upb) / NULLIF(SUM(current_upb), 0),
    3) AS wac,

    -- Weighted Average Maturity (WAM): weighted by current UPB
    ROUND(
        SUM(remaining_months * current_upb) / NULLIF(SUM(current_upb), 0),
    1) AS wam,

    -- Weighted Average Loan Age (WALA)
    ROUND(
        SUM(loan_age * current_upb) / NULLIF(SUM(current_upb), 0),
    1) AS wala,

    -- Weighted Average Credit Score (WACS)
    ROUND(
        SUM(orig_credit_score * current_upb) / NULLIF(SUM(current_upb), 0),
    0) AS wacs,

    -- Average loan size
    ROUND(AVG(current_upb), 2) AS avg_loan_balance,
    MIN(current_upb) AS min_loan_balance,
    MAX(current_upb) AS max_loan_balance

FROM GINNIE_MAE_DB.RAW_LOAN_LEVEL.POOL_LOAN_MAPPING plm
    INNER JOIN MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
        ON plm.loan_id = lp.loan_sequence_number
WHERE lp.reporting_period = '2025-12-01'
  AND lp.current_upb > 0
GROUP BY pool_number, reporting_period;

-- Delinquency bucketing per pool using conditional aggregation
SELECT
    pool_number,
    COUNT(*) AS total_loans,
    SUM(current_upb) AS total_upb,

    -- Delinquency buckets by count
    COUNT_IF(days_delinquent = 0) AS current_count,
    COUNT_IF(days_delinquent BETWEEN 30 AND 59) AS dlq_30_count,
    COUNT_IF(days_delinquent BETWEEN 60 AND 89) AS dlq_60_count,
    COUNT_IF(days_delinquent >= 90) AS dlq_90_plus_count,

    -- Delinquency buckets by UPB
    SUM(IFF(days_delinquent >= 60, current_upb, 0)) AS serious_dlq_upb,

    -- Delinquency rates
    ROUND(COUNT_IF(days_delinquent >= 60) * 100.0 / COUNT(*), 2) AS serious_dlq_rate_pct,
    ROUND(SUM(IFF(days_delinquent >= 90, current_upb, 0)) * 100.0
        / NULLIF(SUM(current_upb), 0), 2) AS dlq_90_plus_upb_pct

FROM GINNIE_MAE_DB.RAW_LOAN_LEVEL.POOL_LOAN_MAPPING plm
    INNER JOIN MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
        ON plm.loan_id = lp.loan_sequence_number
WHERE lp.reporting_period = '2025-12-01'
GROUP BY pool_number
HAVING COUNT(*) >= 10  -- Exclude very small pools
ORDER BY serious_dlq_rate_pct DESC;
```

**Result:** The aggregation calculated pool factors for 412,000 active Ginnie Mae pools in 48 seconds. The weighted average calculations properly reflected that higher-balance loans have more impact on pool characteristics. Conditional aggregation using `COUNT_IF` and `IFF` eliminated the need for multiple subqueries — reducing the delinquency bucketing query from 6 separate passes to a single table scan. The investor report was published 3 days ahead of the 15th deadline.

**AI Vision:** A time-series forecasting model trained on historical pool factor trajectories could predict next month's pool statistics — enabling investors to estimate prepayment speeds (CPR/CDR) and generating early warnings when a pool's projected delinquency rate exceeds its trigger threshold.

---

### Q17. What are the key differences between Snowflake SQL and ANSI SQL relevant to a mortgage data migration?

**Situation:** A mortgage servicer was migrating from Oracle 19c to Snowflake. The existing Oracle codebase contained 500+ stored procedures and views using Oracle-specific syntax (CONNECT BY, ROWNUM, NVL2, DECODE, MERGE with complex conditions). The migration team needed to understand Snowflake's SQL dialect differences to estimate conversion effort.

**Task:** Identify and document the key Snowflake SQL features and deviations from ANSI/Oracle SQL that impact the migration of mortgage analytics queries, providing Snowflake equivalents for common patterns.

**Action:**
Cataloged critical syntax differences with mortgage-relevant examples:

```sql
-- 1. QUALIFY clause (Snowflake-specific, replaces subquery pattern)
-- Oracle: SELECT * FROM (SELECT ..., ROW_NUMBER() ...) WHERE rn = 1
-- Snowflake:
SELECT loan_id, reporting_period, current_upb, servicer_name
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY loan_id ORDER BY reporting_period DESC
) = 1;

-- 2. FLATTEN replaces Oracle's CONNECT BY for hierarchical/JSON data
SELECT
    d.deal_id,
    t.value:tranche_id::VARCHAR AS tranche_id,
    t.value:balance::NUMBER(15,2) AS balance
FROM MORTGAGE_DB.LOAN_SCHEMA.DEAL_MASTER d,
LATERAL FLATTEN(input => d.deal_metadata:tranches) t;

-- 3. IFF() and IFF/DECODE equivalents
-- Oracle: DECODE(loan_status, 'C', 'Current', 'D', 'Default', 'Unknown')
-- Snowflake supports DECODE but also:
SELECT loan_id,
    IFF(days_delinquent = 0, 'CURRENT', 'DELINQUENT') AS simple_status,
    DECODE(loan_purpose, 'P', 'Purchase', 'R', 'Refinance',
           'C', 'Cash-Out Refi', 'Unknown') AS purpose_desc
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_ORIGINATION;

-- 4. NVL2 not supported, use CASE or IFF
-- Oracle: NVL2(foreclosure_date, 'FORECLOSED', 'ACTIVE')
-- Snowflake:
SELECT loan_id,
    IFF(foreclosure_date IS NOT NULL, 'FORECLOSED', 'ACTIVE') AS fc_status
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE;

-- 5. MERGE syntax (Snowflake supports ANSI MERGE)
MERGE INTO MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE tgt
USING MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_STAGE src
    ON tgt.loan_sequence_number = src.loan_sequence_number
    AND tgt.reporting_period = src.reporting_period
WHEN MATCHED THEN UPDATE SET
    tgt.current_upb = src.current_upb,
    tgt.days_delinquent = src.days_delinquent,
    tgt.current_loan_status = src.current_loan_status
WHEN NOT MATCHED THEN INSERT (
    loan_sequence_number, reporting_period, current_upb,
    days_delinquent, current_loan_status
) VALUES (
    src.loan_sequence_number, src.reporting_period, src.current_upb,
    src.days_delinquent, src.current_loan_status
);

-- 6. String functions: Snowflake uses || for concat (ANSI standard)
SELECT loan_id,
    state || '-' || zip_3 || '-' || property_type AS geo_key
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_ORIGINATION;

-- 7. Date functions differ from Oracle
-- Oracle: ADD_MONTHS(origination_date, 360)
-- Snowflake:
SELECT loan_id,
    DATEADD('month', 360, origination_date) AS maturity_date,
    DATEDIFF('month', origination_date, CURRENT_DATE()) AS loan_age,
    LAST_DAY(reporting_period) AS month_end_date
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_ORIGINATION;
```

**Result:** The migration team identified 7 major syntax categories requiring conversion across 500+ procedures. QUALIFY alone eliminated 120 subquery wrappers (24% of all procedures). The MERGE syntax was nearly identical, requiring minimal changes. Date function conversions were mechanical but widespread (every procedure). The estimated conversion effort was reduced from 6 months to 3 months by prioritizing the highest-impact patterns. All 500+ procedures were successfully migrated with 100% result parity verified through automated reconciliation.

**AI Vision:** An LLM-powered SQL transpiler could automatically convert Oracle PL/SQL procedures to Snowflake SQL — parsing the abstract syntax tree, applying transformation rules for each dialect difference, and generating test cases that verify row-level output parity between Oracle and Snowflake for every migrated query.

---

### Q18. How do you use the Information Schema to monitor table sizes in a loan database?

**Situation:** The Freddie Mac data platform team was experiencing unexpected storage cost increases. The `MORTGAGE_DB` database had grown from 500 GB to 2.1 TB over three months, but no one could identify which tables were driving the growth. The team needed visibility into table-level storage consumption including Time Travel and Fail-safe overhead.

**Task:** Query Snowflake's Information Schema and Account Usage views to identify the largest tables, understand storage growth trends, and pinpoint the source of the 1.6 TB increase.

**Action:**
Used Information Schema and Account Usage to analyze storage:

```sql
-- Current table sizes using Information Schema
SELECT
    table_catalog AS database_name,
    table_schema,
    table_name,
    row_count,
    ROUND(bytes / POWER(1024, 3), 2) AS active_size_gb,
    ROUND(bytes / NULLIF(row_count, 0), 0) AS bytes_per_row,
    created,
    last_altered
FROM MORTGAGE_DB.INFORMATION_SCHEMA.TABLES
WHERE table_schema != 'INFORMATION_SCHEMA'
  AND table_type = 'BASE TABLE'
ORDER BY bytes DESC
LIMIT 20;

-- Detailed storage breakdown including Time Travel and Fail-safe
SELECT
    table_name,
    table_schema,
    ROUND(ACTIVE_BYTES / POWER(1024, 3), 2) AS active_gb,
    ROUND(TIME_TRAVEL_BYTES / POWER(1024, 3), 2) AS time_travel_gb,
    ROUND(FAILSAFE_BYTES / POWER(1024, 3), 2) AS failsafe_gb,
    ROUND((ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES)
        / POWER(1024, 3), 2) AS total_gb,
    ROUND(TIME_TRAVEL_BYTES * 100.0
        / NULLIF(ACTIVE_BYTES, 0), 1) AS tt_overhead_pct
FROM MORTGAGE_DB.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE ACTIVE_BYTES > 0
ORDER BY (ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES) DESC
LIMIT 15;

-- Storage growth over time from Account Usage (latency: up to 3 hours)
SELECT
    usage_date,
    ROUND(SUM(AVERAGE_DATABASE_BYTES) / POWER(1024, 4), 2) AS active_tb,
    ROUND(SUM(AVERAGE_FAILSAFE_BYTES) / POWER(1024, 4), 2) AS failsafe_tb,
    ROUND(SUM(AVERAGE_DATABASE_BYTES + AVERAGE_FAILSAFE_BYTES)
        / POWER(1024, 4), 2) AS total_tb
FROM SNOWFLAKE.ACCOUNT_USAGE.DATABASE_STORAGE_USAGE_HISTORY
WHERE DATABASE_NAME = 'MORTGAGE_DB'
  AND usage_date >= DATEADD('month', -3, CURRENT_DATE())
GROUP BY usage_date
ORDER BY usage_date;

-- Identify tables with excessive Time Travel storage
SELECT
    table_name,
    ROUND(ACTIVE_BYTES / POWER(1024, 3), 2) AS active_gb,
    ROUND(TIME_TRAVEL_BYTES / POWER(1024, 3), 2) AS tt_gb,
    ROUND(TIME_TRAVEL_BYTES * 100.0 / NULLIF(ACTIVE_BYTES, 0), 0) AS tt_pct
FROM MORTGAGE_DB.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TIME_TRAVEL_BYTES > ACTIVE_BYTES
ORDER BY TIME_TRAVEL_BYTES DESC;
```

**Result:** The analysis revealed three key findings: (1) `LOAN_PERFORMANCE` was 890 GB active with 640 GB in Time Travel due to daily full-table UPDATEs — switching to incremental inserts reduced Time Travel by 85%. (2) A forgotten `LOAN_STAGING_TEMP` table held 280 GB of stale data — it was dropped immediately. (3) Fail-safe overhead on 90-day retention tables accounted for 190 GB. Total identified savings: 1.1 TB, reducing monthly storage costs by $18K. The team implemented a weekly storage monitoring dashboard.

**AI Vision:** A cost anomaly detection system could continuously monitor table storage metrics and automatically alert when a table's Time Travel bytes exceed its active bytes — indicating destructive update patterns — and recommend table redesign strategies (e.g., append-only with soft deletes instead of in-place updates).

---

### Q19. How do you set up resource monitors to control warehouse costs?

**Situation:** A mid-size mortgage analytics firm was surprised by a $45,000 Snowflake bill after a runaway query from a data scientist spun up an X-Large warehouse for 72 hours over a weekend. The CFO mandated immediate cost controls without disrupting production ETL pipelines that run 24/7.

**Task:** Implement resource monitors at the account and warehouse levels to enforce spending limits, provide early warnings, and automatically suspend runaway warehouses while protecting critical production workloads.

**Action:**
Created tiered resource monitors with notification and suspension triggers:

```sql
-- Account-level resource monitor (overall safety net)
CREATE RESOURCE MONITOR ACCOUNT_MONTHLY_LIMIT
  WITH
    CREDIT_QUOTA = 5000                     -- 5,000 credits/month (~$20K)
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY             -- Alert at 75%
        ON 90 PERCENT DO NOTIFY             -- Urgent alert at 90%
        ON 100 PERCENT DO SUSPEND_IMMEDIATE; -- Hard stop at 100%

ALTER ACCOUNT SET RESOURCE_MONITOR = ACCOUNT_MONTHLY_LIMIT;

-- Production ETL warehouse: higher limit, softer controls
CREATE RESOURCE MONITOR ETL_PRODUCTION_MONITOR
  WITH
    CREDIT_QUOTA = 2000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 95 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;          -- Graceful suspend (finish running queries)

ALTER WAREHOUSE ETL_LOADER_WH SET RESOURCE_MONITOR = ETL_PRODUCTION_MONITOR;

-- Analyst/ad-hoc warehouse: strict controls
CREATE RESOURCE MONITOR ANALYST_ADHOC_MONITOR
  WITH
    CREDIT_QUOTA = 500
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 50 PERCENT DO NOTIFY
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO SUSPEND_IMMEDIATE; -- Hard stop before limit

ALTER WAREHOUSE ANALYST_QUERY_WH SET RESOURCE_MONITOR = ANALYST_ADHOC_MONITOR;

-- Data science sandbox: very strict daily equivalent
CREATE RESOURCE MONITOR DS_SANDBOX_MONITOR
  WITH
    CREDIT_QUOTA = 200
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 50 PERCENT DO NOTIFY
        ON 80 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE DS_SANDBOX_WH SET RESOURCE_MONITOR = DS_SANDBOX_MONITOR;

-- Monitor current credit usage
SELECT
    warehouse_name,
    SUM(credits_used) AS total_credits,
    SUM(credits_used) * 4.00 AS estimated_cost_usd  -- Enterprise pricing
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_DATE())
GROUP BY warehouse_name
ORDER BY total_credits DESC;
```

**Result:** Resource monitors prevented any repeat of the $45K incident. The analyst warehouse was capped at 500 credits/month ($2K), and the sandbox warehouse at 200 credits ($800). Production ETL had a comfortable 2,000-credit allocation with graceful suspension that allowed running queries to complete. Email notifications at 75% gave the team 5-7 days to review and request limit increases if needed. Monthly Snowflake costs stabilized at $12K-$15K — a 67% reduction from the peak month.

**AI Vision:** A predictive cost management agent could forecast end-of-month credit consumption based on daily run rates and scheduled workloads — proactively recommending warehouse downsizing when projected costs exceed budget, or temporarily increasing limits when known events (quarter-end reporting) justify higher spend.

---

### Q20. How do you use Snowsight to build loan performance visualizations?

**Situation:** Fannie Mae's portfolio risk management team needed interactive dashboards to monitor loan performance trends — delinquency rates, prepayment speeds, and loss severities — without depending on external BI tools like Tableau or Power BI. The team wanted quick, self-service visualizations directly within Snowflake's web interface.

**Task:** Build a set of Snowsight dashboards and worksheets that visualize key loan performance metrics, enabling the risk team to identify emerging trends and drill into problem areas without writing complex queries.

**Action:**
Created analytical queries optimized for Snowsight visualization:

```sql
-- Dashboard 1: Monthly delinquency trend (Line Chart in Snowsight)
-- Chart type: Line, X-axis: reporting_period, Y-axis: dlq_rate, Series: dlq_bucket
SELECT
    reporting_period,
    '30-Day DLQ' AS dlq_bucket,
    ROUND(COUNT_IF(days_delinquent BETWEEN 30 AND 59) * 100.0 / COUNT(*), 2) AS dlq_rate
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE reporting_period >= '2024-01-01'
  AND current_upb > 0
GROUP BY reporting_period
UNION ALL
SELECT
    reporting_period,
    '60-Day DLQ' AS dlq_bucket,
    ROUND(COUNT_IF(days_delinquent BETWEEN 60 AND 89) * 100.0 / COUNT(*), 2)
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE reporting_period >= '2024-01-01'
  AND current_upb > 0
GROUP BY reporting_period
UNION ALL
SELECT
    reporting_period,
    '90+ Day DLQ' AS dlq_bucket,
    ROUND(COUNT_IF(days_delinquent >= 90) * 100.0 / COUNT(*), 2)
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE reporting_period >= '2024-01-01'
  AND current_upb > 0
GROUP BY reporting_period
ORDER BY reporting_period, dlq_bucket;

-- Dashboard 2: Geographic heatmap data (Snowsight map chart)
-- Chart type: Heatmap by state
SELECT
    lo.state,
    COUNT(*) AS loan_count,
    SUM(lp.current_upb) AS total_upb_millions,
    ROUND(COUNT_IF(lp.days_delinquent >= 60) * 100.0 / COUNT(*), 2) AS serious_dlq_rate,
    ROUND(AVG(lo.borrower_credit_score), 0) AS avg_credit_score
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
JOIN MORTGAGE_DB.LOAN_SCHEMA.LOAN_ORIGINATION lo
    ON lp.loan_sequence_number = lo.loan_sequence_number
WHERE lp.reporting_period = '2025-12-01'
  AND lp.current_upb > 0
GROUP BY lo.state
ORDER BY serious_dlq_rate DESC;

-- Dashboard 3: Prepayment speed (SMM/CPR) trend
-- Chart type: Bar + Line combo
SELECT
    reporting_period,
    ROUND(SUM(prepayment_amount) / NULLIF(SUM(scheduled_upb), 0) * 100, 4) AS smm,
    ROUND(
        (1 - POWER(1 - SUM(prepayment_amount) / NULLIF(SUM(scheduled_upb), 0), 12)) * 100,
    2) AS cpr_annualized,
    SUM(prepayment_amount) / 1000000 AS prepay_amount_mm
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE reporting_period >= '2024-01-01'
GROUP BY reporting_period
ORDER BY reporting_period;

-- Save each query as a Snowsight worksheet, then combine into a Dashboard
-- Snowsight > Dashboards > + New Dashboard > Add tiles from saved worksheets
```

**Result:** Three Snowsight dashboard tiles were created: (1) a line chart showing 30/60/90+ day delinquency trends that revealed a 0.3% uptick in 60-day delinquencies starting October 2025, (2) a geographic heatmap highlighting Mississippi, Louisiana, and West Virginia as the highest serious-delinquency states, and (3) a CPR trend chart showing prepayment speeds declining from 22% to 14% annualized as interest rates rose. The risk team adopted the dashboard for weekly monitoring, eliminating a 4-hour manual Excel reporting process.

**AI Vision:** An AI-powered dashboard assistant could detect anomalies in the visualized data in real time — automatically highlighting when a state's delinquency rate deviates more than 2 standard deviations from its 12-month rolling average, and generating natural language explanations like "Mississippi 60-day delinquency spiked 1.2% in November, coinciding with Hurricane activity in the Gulf Coast region."

---

### Q21. How do you use zero-copy cloning to create dev environments for mortgage data testing?

**Situation:** Freddie Mac's data engineering team needed a development environment to test a major ETL pipeline refactoring that changed how loan modification records were processed. Testing against production data was essential for realistic validation, but creating a full copy of the 800 GB `MORTGAGE_DB` database would take hours and double storage costs.

**Task:** Use Snowflake's zero-copy cloning to create an instant, production-identical development environment that consumes no additional storage until data diverges, enabling safe testing of ETL changes.

**Action:**
Cloned the entire database and tested the pipeline changes:

```sql
-- Clone the entire database: instant, zero additional storage
CREATE DATABASE MORTGAGE_DB_DEV
  CLONE MORTGAGE_DB
  COMMENT = 'Dev clone for ETL refactoring - JIRA-4521 - created 2025-12-15';

-- Verify clone is complete and identical
SELECT
    'PRODUCTION' AS environment,
    COUNT(*) AS table_count,
    SUM(row_count) AS total_rows
FROM MORTGAGE_DB.INFORMATION_SCHEMA.TABLES
WHERE table_type = 'BASE TABLE'
UNION ALL
SELECT
    'DEVELOPMENT',
    COUNT(*),
    SUM(row_count)
FROM MORTGAGE_DB_DEV.INFORMATION_SCHEMA.TABLES
WHERE table_type = 'BASE TABLE';
-- Both show: 47 tables, 3.1B total rows

-- Clone is writable: test destructive changes safely
-- Test the new modification logic
DELETE FROM MORTGAGE_DB_DEV.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE modification_flag = TRUE
  AND reporting_period < '2020-01-01';
-- Deleted 4.2M rows — only these modified micro-partitions
-- consume additional storage (copy-on-write)

-- Run refactored ETL procedure against dev clone
CALL MORTGAGE_DB_DEV.STAGING.SP_PROCESS_MODIFICATIONS();

-- Validate results against production
SELECT
    'PROD' AS env,
    COUNT(*) AS mod_count,
    SUM(current_upb) AS mod_upb
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE modification_flag = TRUE
UNION ALL
SELECT
    'DEV',
    COUNT(*),
    SUM(current_upb)
FROM MORTGAGE_DB_DEV.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE modification_flag = TRUE;

-- Check additional storage consumed by clone
SELECT
    TABLE_NAME,
    ROUND(ACTIVE_BYTES / POWER(1024, 3), 2) AS active_gb
FROM MORTGAGE_DB_DEV.INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_NAME = 'LOAN_PERFORMANCE';
-- Only 2.1 GB additional (the modified micro-partitions)

-- Cleanup when testing is complete
DROP DATABASE MORTGAGE_DB_DEV;
```

Also cloned individual tables for targeted testing:
```sql
-- Clone just the performance table for a quick unit test
CREATE TABLE MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_TEST
  CLONE MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE;

-- Clone with Time Travel: test against data from last week
CREATE TABLE MORTGAGE_DB.STAGING.LOAN_PERF_LAST_WEEK
  CLONE MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
  AT(OFFSET => -7 * 24 * 3600);  -- 7 days ago
```

**Result:** The 800 GB database was cloned in 8 seconds with zero additional storage. Only the 4.2M rows modified during testing consumed incremental storage (2.1 GB). The ETL refactoring was validated against production-identical data, catching 3 edge cases in modification processing that would have been missed with synthetic test data. After successful validation, the dev clone was dropped, reclaiming all incremental storage. Total cost of the testing environment: $0.09 in storage for 2 days.

**AI Vision:** A CI/CD pipeline could automatically clone production databases for each pull request, run integration tests against real mortgage data, compare output against baseline expectations, and post validation results as PR comments — enabling safe, data-driven code review for ETL changes.

---

### Q22. How do you create views for servicer performance summaries?

**Situation:** Fannie Mae's servicer oversight team needed consistent, reusable reporting views to evaluate mortgage servicer performance across delinquency management, loss mitigation outcomes, and timeline compliance. Multiple analysts were writing slightly different versions of the same queries, leading to inconsistent metrics in management reports.

**Task:** Create standard and secure views that encapsulate the official servicer performance metrics, ensuring all analysts and reports use identical calculation logic while restricting access to sensitive borrower data.

**Action:**
Built a hierarchy of views from base metrics to executive summary:

```sql
-- Base view: servicer-level monthly metrics
CREATE OR REPLACE VIEW MORTGAGE_DB.REPORTING.VW_SERVICER_MONTHLY_METRICS AS
SELECT
    lo.servicer_name,
    lp.reporting_period,
    COUNT(DISTINCT lp.loan_sequence_number) AS active_loan_count,
    SUM(lp.current_upb) AS total_servicing_upb,

    -- Delinquency rates
    ROUND(COUNT_IF(lp.days_delinquent BETWEEN 30 AND 59) * 100.0
        / NULLIF(COUNT(*), 0), 2) AS dlq_30_rate,
    ROUND(COUNT_IF(lp.days_delinquent BETWEEN 60 AND 89) * 100.0
        / NULLIF(COUNT(*), 0), 2) AS dlq_60_rate,
    ROUND(COUNT_IF(lp.days_delinquent >= 90) * 100.0
        / NULLIF(COUNT(*), 0), 2) AS dlq_90_plus_rate,

    -- Loss mitigation
    COUNT_IF(lp.modification_flag = TRUE) AS modification_count,
    ROUND(COUNT_IF(lp.modification_flag = TRUE) * 100.0
        / NULLIF(COUNT_IF(lp.days_delinquent >= 60), 0), 2) AS mod_rate_of_dlq,

    -- Liquidation metrics
    COUNT_IF(lp.zero_balance_code = '03') AS foreclosure_count,
    COUNT_IF(lp.zero_balance_code = '09') AS short_sale_count,
    AVG(CASE WHEN lp.actual_loss IS NOT NULL
        THEN lp.actual_loss / NULLIF(lp.current_upb, 0) END) AS avg_loss_severity

FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE lp
JOIN MORTGAGE_DB.LOAN_SCHEMA.LOAN_ORIGINATION lo
    ON lp.loan_sequence_number = lo.loan_sequence_number
WHERE lp.current_upb > 0 OR lp.zero_balance_code IS NOT NULL
GROUP BY lo.servicer_name, lp.reporting_period;

-- Secure view: hides underlying table structure and enforces RLS
CREATE OR REPLACE SECURE VIEW MORTGAGE_DB.REPORTING.VW_SERVICER_SCORECARD AS
SELECT
    servicer_name,
    reporting_period,
    active_loan_count,
    total_servicing_upb,
    dlq_30_rate,
    dlq_60_rate,
    dlq_90_plus_rate,
    mod_rate_of_dlq,
    -- Rank servicers by serious delinquency rate
    RANK() OVER (
        PARTITION BY reporting_period
        ORDER BY dlq_90_plus_rate ASC
    ) AS performance_rank,
    -- Quarter-over-quarter trend
    dlq_90_plus_rate - LAG(dlq_90_plus_rate, 3) OVER (
        PARTITION BY servicer_name ORDER BY reporting_period
    ) AS dlq_90_qoq_change
FROM MORTGAGE_DB.REPORTING.VW_SERVICER_MONTHLY_METRICS
WHERE reporting_period >= DATEADD('year', -2, CURRENT_DATE());

-- Grant access to the secure view without exposing base tables
GRANT SELECT ON MORTGAGE_DB.REPORTING.VW_SERVICER_SCORECARD
  TO ROLE LOAN_ANALYST_ROLE;

-- Query the view
SELECT *
FROM MORTGAGE_DB.REPORTING.VW_SERVICER_SCORECARD
WHERE reporting_period = '2025-12-01'
ORDER BY performance_rank
LIMIT 10;
```

**Result:** The view hierarchy standardized servicer performance metrics across 15 analysts and 8 recurring reports. The `SECURE` designation on the scorecard view prevented analysts from using EXPLAIN or GET_DDL to reverse-engineer the underlying table structures. The `performance_rank` and `dlq_90_qoq_change` columns enabled instant identification of deteriorating servicers — one servicer showed a 0.8% quarter-over-quarter increase in 90+ day delinquency, triggering a formal review. Report generation time dropped from 2 hours of ad-hoc SQL to instant view queries.

**AI Vision:** An NLQ (Natural Language Query) interface could let the servicer oversight team ask questions like "Which servicers had the biggest delinquency increase last quarter in Florida?" and automatically generate the correct SQL against the curated views — democratizing data access for non-technical compliance officers.

---

### Q23. How do you use sequences to generate unique identifiers for deal records?

**Situation:** An MBS trading desk needed to assign unique, sequential deal identifiers to every structured product created internally. The existing approach used application-level UUID generation, but traders and operations staff needed human-readable, sequential IDs for deal tracking, confirmation matching, and regulatory reporting to FINRA TRACE.

**Task:** Implement Snowflake sequences to generate unique, gap-free (as much as possible) deal identifiers that include a prefix for the deal type and a sequential number, supporting concurrent deal creation by multiple traders.

**Action:**
Created sequences and integrated them into the deal creation workflow:

```sql
-- Create sequences for different deal types
CREATE OR REPLACE SEQUENCE MORTGAGE_DB.LOAN_SCHEMA.SEQ_RMBS_DEAL_ID
  START = 100000
  INCREMENT = 1
  COMMENT = 'RMBS deal identifier sequence';

CREATE OR REPLACE SEQUENCE MORTGAGE_DB.LOAN_SCHEMA.SEQ_CMO_DEAL_ID
  START = 500000
  INCREMENT = 1
  COMMENT = 'CMO/REMIC deal identifier sequence';

CREATE OR REPLACE SEQUENCE MORTGAGE_DB.LOAN_SCHEMA.SEQ_TRADE_CONFIRM_ID
  START = 1000000
  INCREMENT = 1
  COMMENT = 'Trade confirmation sequence';

-- Deal master table using sequence for primary key
CREATE OR REPLACE TABLE MORTGAGE_DB.LOAN_SCHEMA.DEAL_REGISTER (
    deal_id            VARCHAR(20)     NOT NULL PRIMARY KEY,
    deal_seq           NUMBER(10)      NOT NULL,
    deal_type          VARCHAR(10)     NOT NULL,
    deal_name          VARCHAR(100),
    agency             VARCHAR(10),
    total_face_value   NUMBER(15,2),
    closing_date       DATE,
    settlement_date    DATE,
    created_by         VARCHAR(50)     DEFAULT CURRENT_USER(),
    created_at         TIMESTAMP_NTZ   DEFAULT CURRENT_TIMESTAMP()
);

-- Insert new RMBS deal using sequence
INSERT INTO MORTGAGE_DB.LOAN_SCHEMA.DEAL_REGISTER (
    deal_id, deal_seq, deal_type, deal_name, agency,
    total_face_value, closing_date, settlement_date
)
SELECT
    'RMBS-' || LPAD(MORTGAGE_DB.LOAN_SCHEMA.SEQ_RMBS_DEAL_ID.NEXTVAL::VARCHAR, 6, '0'),
    MORTGAGE_DB.LOAN_SCHEMA.SEQ_RMBS_DEAL_ID.NEXTVAL,
    'RMBS',
    'Fannie Mae MBS Pool 2025-1215',
    'FNMA',
    750000000.00,
    '2025-12-15',
    '2025-12-18';
-- Generated deal_id: RMBS-100000

-- Insert CMO deal
INSERT INTO MORTGAGE_DB.LOAN_SCHEMA.DEAL_REGISTER (
    deal_id, deal_seq, deal_type, deal_name, agency,
    total_face_value, closing_date, settlement_date
)
SELECT
    'CMO-' || LPAD(MORTGAGE_DB.LOAN_SCHEMA.SEQ_CMO_DEAL_ID.NEXTVAL::VARCHAR, 6, '0'),
    MORTGAGE_DB.LOAN_SCHEMA.SEQ_CMO_DEAL_ID.NEXTVAL,
    'CMO',
    'Freddie Mac REMIC Trust 2025-Q4',
    'FHLMC',
    1250000000.00,
    '2025-12-20',
    '2025-12-23';
-- Generated deal_id: CMO-500000

-- Verify sequence values
SELECT
    MORTGAGE_DB.LOAN_SCHEMA.SEQ_RMBS_DEAL_ID.NEXTVAL AS next_rmbs,
    MORTGAGE_DB.LOAN_SCHEMA.SEQ_CMO_DEAL_ID.NEXTVAL AS next_cmo;

-- Batch insert with sequence for trade confirmations
INSERT INTO MORTGAGE_DB.LOAN_SCHEMA.TRADE_CONFIRMATIONS (
    confirm_id, deal_id, counterparty, trade_date, settle_amount
)
SELECT
    'TC-' || LPAD(MORTGAGE_DB.LOAN_SCHEMA.SEQ_TRADE_CONFIRM_ID.NEXTVAL::VARCHAR, 7, '0'),
    deal_id,
    counterparty,
    trade_date,
    settle_amount
FROM MORTGAGE_DB.STAGING.PENDING_TRADES;
```

**Result:** The sequence-based approach generated human-readable deal IDs (RMBS-100001, CMO-500003, TC-1000047) that traders could reference verbally and in email. Sequences handled concurrent inserts from 12 traders without collisions. The FINRA TRACE reporting team confirmed the sequential IDs simplified reconciliation compared to UUIDs. Over 6 months, 2,400 deals and 18,000 trade confirmations were created with zero duplicate IDs.

**AI Vision:** An intelligent deal numbering system could incorporate deal characteristics into the sequence logic — automatically detecting when a deal structure is a re-REMIC (resecuritization) and assigning it a different prefix, or embedding the vintage year and quarter into the ID format for instant visual classification by traders.

---

### Q24. How do you use the QUALIFY clause to deduplicate loan records efficiently?

**Situation:** CoreLogic's data pipeline received loan records from multiple servicer feeds, often containing duplicate entries for the same loan in the same reporting period. The `LOAN_PERFORMANCE_STAGING` table had 45M rows but contained 2.3M duplicates where the same `loan_id` and `reporting_period` appeared multiple times with slightly different timestamps or field values. The business rule was to keep the most recent record per loan per month.

**Task:** Deduplicate the staging table efficiently using Snowflake's QUALIFY clause — a Snowflake-specific extension that filters window function results without requiring nested subqueries or CTEs.

**Action:**
Used QUALIFY for clean, performant deduplication:

```sql
-- Traditional approach (subquery, less readable):
-- SELECT * FROM (
--   SELECT *, ROW_NUMBER() OVER (...) AS rn
--   FROM staging
-- ) WHERE rn = 1

-- Snowflake QUALIFY approach: cleaner and equally performant
-- Step 1: Identify duplicates
SELECT
    loan_id,
    reporting_period,
    COUNT(*) AS record_count
FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_STAGING
GROUP BY loan_id, reporting_period
HAVING COUNT(*) > 1
ORDER BY record_count DESC
LIMIT 10;
-- Top duplicate: loan_id 'FN-98234571' with 4 records for 2025-12-01

-- Step 2: Preview which records QUALIFY keeps vs. drops
SELECT
    loan_id,
    reporting_period,
    current_upb,
    days_delinquent,
    load_timestamp,
    source_file_name,
    ROW_NUMBER() OVER (
        PARTITION BY loan_id, reporting_period
        ORDER BY load_timestamp DESC
    ) AS rn
FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_STAGING
WHERE loan_id = 'FN-98234571'
  AND reporting_period = '2025-12-01';
-- Shows 4 records; rn=1 is the most recent (keeper)

-- Step 3: Insert deduplicated records into production using QUALIFY
INSERT INTO MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
SELECT
    loan_id,
    reporting_period,
    current_upb,
    current_interest_rate,
    days_delinquent,
    current_loan_status,
    modification_flag,
    zero_balance_code,
    actual_loss,
    load_timestamp,
    source_file_name
FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_STAGING
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY loan_id, reporting_period
    ORDER BY load_timestamp DESC
) = 1;
-- Inserted 42.7M rows (from 45M staging rows, 2.3M duplicates removed)

-- Step 4: QUALIFY with additional business logic
-- Keep record with highest UPB when timestamps are identical
SELECT
    loan_id,
    reporting_period,
    current_upb,
    days_delinquent,
    servicer_name
FROM MORTGAGE_DB.STAGING.LOAN_PERFORMANCE_STAGING
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY loan_id, reporting_period
    ORDER BY load_timestamp DESC, current_upb DESC
) = 1;

-- Step 5: QUALIFY for "latest record per loan" (most recent snapshot)
SELECT
    loan_id,
    reporting_period,
    current_upb,
    days_delinquent,
    current_loan_status
FROM MORTGAGE_DB.LOAN_SCHEMA.LOAN_PERFORMANCE
WHERE current_upb > 0
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY loan_id
    ORDER BY reporting_period DESC
) = 1;
-- Returns the most recent snapshot for each active loan
```

**Result:** QUALIFY deduplicated 45M staging records into 42.7M clean production records in a single SQL statement — no CTEs, no temp tables, no subqueries. The query ran in 28 seconds on a Medium warehouse. Compared to the previous CTE-based approach, QUALIFY reduced the query from 15 lines to 8 lines with identical performance. The 2.3M duplicates (5.1%) were traced to overlapping servicer feed windows, leading to a pipeline fix that reduced future duplicates to 0.02%.

**AI Vision:** An intelligent data quality engine could learn from the deduplication patterns — recognizing that duplicates from Servicer A always have stale `current_upb` while Servicer B has stale `days_delinquent` — and automatically apply field-level "best of breed" merging rather than simple whole-record selection, producing more accurate composite loan records.

---

### Q25. How do you configure multi-cluster warehouses for peak month-end processing?

**Situation:** Ginnie Mae's reporting infrastructure experienced severe performance degradation during the last 3 business days of each month when 200+ analysts and 50+ automated reporting jobs competed for compute resources. During month-end, the single Medium warehouse queued up to 150 concurrent queries, with average wait times exceeding 12 minutes — causing SLA breaches on investor reporting deadlines.

**Task:** Configure multi-cluster warehouses to automatically scale compute capacity during month-end peaks while maintaining cost efficiency during the remaining 85% of the month when demand is normal.

**Action:**
Configured auto-scaling multi-cluster warehouses with economy scaling:

```sql
-- Replace single warehouse with multi-cluster configuration
ALTER WAREHOUSE REPORTING_WH SET
  WAREHOUSE_SIZE = 'MEDIUM'
  MIN_CLUSTER_COUNT = 1           -- Minimum 1 cluster (off-peak)
  MAX_CLUSTER_COUNT = 6           -- Scale up to 6 clusters (month-end)
  SCALING_POLICY = 'ECONOMY'      -- Queue queries briefly before scaling
  AUTO_SUSPEND = 120              -- Suspend idle clusters after 2 min
  AUTO_RESUME = TRUE
  COMMENT = 'Multi-cluster for month-end investor reporting peak';

-- Separate multi-cluster warehouse for ETL with STANDARD policy
ALTER WAREHOUSE ETL_MONTHEND_WH SET
  WAREHOUSE_SIZE = 'LARGE'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 3
  SCALING_POLICY = 'STANDARD'     -- Scale immediately, no queueing
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE
  COMMENT = 'Multi-cluster ETL - STANDARD policy for zero-queue tolerance';

-- Monitor cluster scaling activity
SELECT
    warehouse_name,
    cluster_number,
    start_time,
    end_time,
    credits_used,
    DATEDIFF('minute', start_time, end_time) AS runtime_minutes
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name = 'REPORTING_WH'
  AND start_time >= DATEADD('day', -5, CURRENT_DATE())
ORDER BY start_time DESC;

-- Monitor query queueing to validate scaling is sufficient
SELECT
    DATE_TRUNC('hour', start_time) AS hour_bucket,
    COUNT(*) AS total_queries,
    AVG(DATEDIFF('second', queued_overload_time, start_time))
        AS avg_queue_seconds,
    MAX(DATEDIFF('second', queued_overload_time, start_time))
        AS max_queue_seconds,
    COUNT_IF(DATEDIFF('second', queued_overload_time, start_time) > 30)
        AS queries_queued_over_30s
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'REPORTING_WH'
  AND start_time >= DATEADD('day', -3, CURRENT_DATE())
  AND queued_overload_time IS NOT NULL
GROUP BY hour_bucket
ORDER BY hour_bucket;

-- Resource monitor for the multi-cluster warehouse
CREATE RESOURCE MONITOR REPORTING_MCW_MONITOR
  WITH
    CREDIT_QUOTA = 3000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 70 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE REPORTING_WH SET RESOURCE_MONITOR = REPORTING_MCW_MONITOR;
```

Compared ECONOMY vs STANDARD scaling policies:
```sql
-- ECONOMY: Minimizes costs by tolerating brief queuing
-- - Waits until load fills current cluster before adding another
-- - Better for ad-hoc analyst queries (a few seconds of queue is OK)

-- STANDARD: Minimizes latency by scaling immediately
-- - Adds clusters as soon as a query would queue
-- - Better for ETL/automated jobs with strict SLA requirements

-- Verify the configuration
SHOW WAREHOUSES LIKE 'REPORTING_WH';
-- min_cluster_count: 1, max_cluster_count: 6, scaling_policy: ECONOMY
```

**Result:** During the next month-end close, the `REPORTING_WH` automatically scaled from 1 to 5 clusters to handle 200+ concurrent analyst sessions. Average query wait time dropped from 12 minutes to 8 seconds. The ECONOMY scaling policy kept costs 30% lower than STANDARD by tolerating brief queuing before spinning up additional clusters. During non-peak periods (days 1-25), the warehouse ran on a single cluster, consuming the same credits as before. Monthly warehouse costs increased by only 25% ($3K) while serving 6x more concurrent users during peak periods — a clear win versus provisioning a permanent 2X-Large warehouse.

**AI Vision:** A workload forecasting model trained on 24 months of query history could predict the exact day and hour when month-end volume will spike — pre-warming clusters 30 minutes before the surge arrives rather than reactively scaling after queues form, achieving zero-queue month-end processing while still auto-scaling down during off-peak hours.

---

### Q26. How do you use COPY INTO with transformations to load and reshape loan data in a single step?

**Situation:** Fannie Mae's data engineering team received monthly loan acquisition files as flat CSVs from an upstream system. The raw files contained 50+ columns, but the staging table only needed 12 key loan attributes. Additionally, several columns required type casting and default value substitution before landing in the staging layer. Running a separate transformation step after loading was adding 20 minutes to the pipeline.

**Task:** Combine the data loading and transformation into a single COPY INTO statement, eliminating the intermediate raw table and reducing pipeline complexity and runtime.

**Action:**
Used COPY INTO with a SELECT subquery to transform data during the load:

```sql
-- Stage already has the CSV files
-- Load with inline transformations
COPY INTO FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION (
    loan_id,
    seller_name,
    orig_interest_rate,
    orig_upb,
    orig_loan_term,
    orig_date,
    credit_score,
    dti_ratio,
    ltv_ratio,
    channel,
    property_state,
    load_timestamp
)
FROM (
    SELECT
        $1::STRING                          AS loan_id,
        TRIM($2)::STRING                    AS seller_name,
        $3::FLOAT                           AS orig_interest_rate,
        $4::NUMBER(12,2)                    AS orig_upb,
        $5::INTEGER                         AS orig_loan_term,
        TO_DATE($6, 'MM/YYYY')             AS orig_date,
        NULLIF($7, '')::INTEGER             AS credit_score,
        NULLIF($8, '')::FLOAT              AS dti_ratio,
        NULLIF($9, '')::INTEGER             AS ltv_ratio,
        COALESCE(NULLIF($10, ''), 'UNKNOWN') AS channel,
        $11::STRING                         AS property_state,
        CURRENT_TIMESTAMP()                 AS load_timestamp
    FROM @FANNIE_MAE_DB.RAW_ACQUISITION.LOAN_STAGE/acq_2025Q4.csv
)
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"')
ON_ERROR = 'CONTINUE'
PURGE = TRUE;

-- Verify loaded records
SELECT COUNT(*) AS rows_loaded, MIN(orig_date) AS earliest, MAX(orig_date) AS latest
FROM FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION
WHERE load_timestamp >= DATEADD('hour', -1, CURRENT_TIMESTAMP());
```

**Result:** The single-step COPY INTO with transformations eliminated the intermediate raw table entirely, cutting the pipeline from two stages to one. Load time dropped from 26 minutes (load + transform) to 9 minutes for 8M loan records. Type casting and NULLIF handling during load meant downstream queries never encountered dirty data. The PURGE = TRUE flag auto-cleaned processed files from the stage, saving storage costs.

**AI Vision:** An AI schema-inference engine could analyze incoming CSV files, detect column types and common data quality issues (empty strings, inconsistent date formats), and auto-generate the optimal COPY INTO transformation query — adapting dynamically when Fannie Mae changes their file layout between quarters.

---

### Q27. How do you use the PUT command to upload local loan files to an internal stage?

**Situation:** A CoreLogic data analyst received daily loan valuation files on their local workstation. These property appraisal and AVM (Automated Valuation Model) files needed to be uploaded to Snowflake for integration with loan performance data. The team had been manually uploading files through the Snowflake UI, which was slow and error-prone for batches of 20+ files.

**Task:** Automate the upload of local loan valuation files to a Snowflake internal stage using the PUT command, with proper compression and path organization.

**Action:**
Used PUT from SnowSQL to upload files to a named internal stage:

```sql
-- Create a named internal stage with directory structure
CREATE OR REPLACE STAGE CORELOGIC_DB.STAGING.VALUATION_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'CoreLogic AVM and appraisal files';

-- PUT a single file (auto-compresses with gzip by default)
PUT file:///data/corelogic/avm_daily_20260301.csv
    @CORELOGIC_DB.STAGING.VALUATION_STAGE/2026/03/
    AUTO_COMPRESS = TRUE
    OVERWRITE = FALSE;

-- PUT multiple files using wildcard pattern
PUT file:///data/corelogic/avm_daily_202603*.csv
    @CORELOGIC_DB.STAGING.VALUATION_STAGE/2026/03/
    AUTO_COMPRESS = TRUE
    PARALLEL = 4;

-- PUT with explicit source compression (file already gzipped)
PUT file:///data/corelogic/appraisal_batch_20260301.csv.gz
    @CORELOGIC_DB.STAGING.VALUATION_STAGE/2026/03/appraisals/
    SOURCE_COMPRESSION = GZIP
    OVERWRITE = TRUE;

-- Verify uploads
LIST @CORELOGIC_DB.STAGING.VALUATION_STAGE/2026/03/;
```

**Result:** The PUT command with PARALLEL = 4 uploaded 25 daily files (totaling 3.2 GB) in under 4 minutes versus 35 minutes through the UI. Auto-compression reduced the staged data footprint by 70%. The organized path structure (`/year/month/`) made it easy to target specific date ranges during COPY INTO operations. Setting OVERWRITE = FALSE prevented accidental re-uploads of already-processed files.

**AI Vision:** An intelligent file watcher could monitor the local drop folder, automatically detect new CoreLogic deliveries by filename pattern, validate file integrity (row counts, checksums), and trigger PUT uploads with the correct stage path — sending Slack alerts if a daily file is missing or arrives with anomalous row counts.

---

### Q28. How do you use the LIST command to verify staged files before loading?

**Situation:** Freddie Mac's ETL pipeline loaded monthly loan performance files from an internal stage. On two occasions, incomplete files were loaded — once a partial upload and once a duplicate file from a prior month. These incidents caused data quality issues that took hours to diagnose and remediate. The team needed a pre-load verification step.

**Task:** Implement a LIST-based verification routine to inspect staged files before triggering the COPY INTO, checking for expected file counts, sizes, and naming conventions.

**Action:**
Used LIST to query stage metadata and validate files before loading:

```sql
-- List all files in the stage for the current month
LIST @FREDDIE_MAC_DB.RAW_MONTHLY.PERF_STAGE/2026/03/;

-- Query LIST output as a table for validation
-- LIST returns: name, size, md5, last_modified
SELECT
    "name"                                              AS file_path,
    "size"                                              AS file_bytes,
    ROUND("size" / (1024 * 1024), 2)                   AS file_mb,
    "last_modified"                                     AS upload_time,
    "md5"                                               AS checksum
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";

-- Count files and total size for validation
SELECT
    COUNT(*)                                            AS file_count,
    ROUND(SUM("size") / (1024 * 1024 * 1024), 2)      AS total_gb,
    MIN("last_modified")                                AS earliest_upload,
    MAX("last_modified")                                AS latest_upload
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Check for duplicate or unexpected files
SELECT "name", COUNT(*) AS occurrences
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
GROUP BY "name"
HAVING COUNT(*) > 1;

-- Validate expected naming convention: perf_YYYYMM_NNN.csv.gz
SELECT "name"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" NOT RLIKE '.*perf_[0-9]{6}_[0-9]{3}\\.csv\\.gz$';
```

**Result:** The LIST-based pre-check caught a truncated file (450 KB versus the expected 1.2 GB minimum) before it entered the pipeline. The naming convention regex flagged an accidentally staged file from a different feed. Adding this 30-second validation step to the pipeline prevented two data quality incidents per quarter, each of which previously required 4-6 hours of remediation.

**AI Vision:** A statistical anomaly detector could learn the expected file count, size distribution, and upload timing for each monthly delivery, automatically flagging deviations — such as a file that is 60% smaller than historical average or an upload timestamp outside the normal delivery window — before any loading begins.

---

### Q29. How do you use VALIDATION_MODE for dry-run testing before loading loan tapes?

**Situation:** Ginnie Mae's data team was onboarding a new loan-level disclosure feed from an issuer. The file format documentation was incomplete, and the first three load attempts failed due to data type mismatches, unexpected NULL handling, and date format inconsistencies. Each failed COPY INTO wasted 15 minutes of warehouse compute time before erroring out.

**Task:** Use VALIDATION_MODE to perform dry-run validation of the new loan tape files without actually loading data, identifying all format and type issues upfront.

**Action:**
Ran COPY INTO with VALIDATION_MODE to test without loading:

```sql
-- Dry-run: return first 100 errors without loading any data
COPY INTO GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_DISCLOSURE
FROM @GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_STAGE/new_issuer_202603.csv
FILE_FORMAT = (
    TYPE = 'CSV'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'N/A')
    DATE_INPUT_FORMAT = 'YYYY-MM-DD'
)
VALIDATION_MODE = 'RETURN_ERRORS';

-- Alternative: return all rows (validated, not loaded)
COPY INTO GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_DISCLOSURE
FROM @GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_STAGE/new_issuer_202603.csv
FILE_FORMAT = (
    TYPE = 'CSV'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'N/A')
    DATE_INPUT_FORMAT = 'MM/DD/YYYY'
)
VALIDATION_MODE = 'RETURN_ALL_ERRORS';

-- Inspect specific error details
SELECT
    error,
    file,
    line,
    character,
    rejected_record
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
LIMIT 20;

-- After fixing file format, validate with RETURN_ROWS to preview data
COPY INTO GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_DISCLOSURE
FROM @GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_STAGE/new_issuer_202603.csv
FILE_FORMAT = (
    TYPE = 'CSV'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'N/A')
    DATE_INPUT_FORMAT = 'MM/DD/YYYY'
)
VALIDATION_MODE = 'RETURN_ROWS';
```

**Result:** RETURN_ALL_ERRORS revealed 3,400 rows with date format mismatches (the issuer used MM/DD/YYYY, not YYYY-MM-DD) and 212 rows where a numeric field contained the string "N/A". Fixing the DATE_INPUT_FORMAT and adding 'N/A' to NULL_IF resolved all issues in one iteration. The dry-run approach saved approximately 45 minutes of wasted compute from trial-and-error loading, and the team adopted VALIDATION_MODE as a mandatory step for all new data source onboarding.

**AI Vision:** An AI-powered format detector could scan the first 1,000 rows of any new file, infer date formats, delimiter patterns, quoting styles, and NULL representations, then auto-generate the optimal FILE_FORMAT definition — reducing new source onboarding from hours of trial-and-error to a single validated attempt.

---

### Q30. How do you use Snowflake string functions to parse loan identifiers and CUSIPs?

**Situation:** Intex's deal analytics platform ingested MBS deal data where loan identifiers and CUSIPs (Committee on Uniform Securities Identification Procedures) arrived in inconsistent formats. Some CUSIPs included check digits (9 characters), others did not (8 characters). Loan IDs from different servicers used varying prefix conventions (e.g., "FN-12345678", "FNMA12345678", "12345678-FN"). Downstream reporting required standardized identifiers.

**Task:** Build SQL transformations using Snowflake string functions to parse, standardize, and validate loan identifiers and CUSIPs across multiple source formats.

**Action:**
Applied string functions to normalize identifiers:

```sql
-- Standardize CUSIP: extract base 8-char CUSIP, validate check digit
SELECT
    raw_cusip,
    LEFT(raw_cusip, 6)                         AS issuer_code,
    SUBSTR(raw_cusip, 7, 2)                    AS issue_number,
    CASE
        WHEN LENGTH(TRIM(raw_cusip)) = 9
        THEN RIGHT(raw_cusip, 1)
        ELSE NULL
    END                                         AS check_digit,
    LEFT(TRIM(raw_cusip), 8)                   AS base_cusip,
    LENGTH(TRIM(raw_cusip))                    AS cusip_length
FROM INTEX_DB.RAW_DEALS.TRANCHE_MASTER;

-- Parse loan IDs from multiple servicer formats
SELECT
    raw_loan_id,
    -- Strip all non-numeric characters to get the core ID
    REGEXP_REPLACE(raw_loan_id, '[^0-9]', '')  AS numeric_loan_id,
    -- Extract agency prefix if present
    COALESCE(
        REGEXP_SUBSTR(raw_loan_id, '(FN|FNMA|FM|FHLMC|GN|GNMA)', 1, 1),
        'UNKNOWN'
    )                                           AS agency_prefix,
    -- Standardized format: AGENCY-NUMERICID
    CONCAT(
        COALESCE(
            REGEXP_SUBSTR(raw_loan_id, '(FN|FNMA|FM|FHLMC|GN|GNMA)', 1, 1),
            'UNK'
        ),
        '-',
        LPAD(REGEXP_REPLACE(raw_loan_id, '[^0-9]', ''), 12, '0')
    )                                           AS standardized_loan_id
FROM INTEX_DB.RAW_DEALS.LOAN_XREF;

-- Validate CUSIP format: must be alphanumeric, correct length
SELECT
    raw_cusip,
    CASE
        WHEN raw_cusip RLIKE '^[A-Z0-9]{8,9}$' THEN 'VALID'
        WHEN CONTAINS(raw_cusip, ' ')           THEN 'HAS_SPACES'
        WHEN LENGTH(raw_cusip) < 8              THEN 'TOO_SHORT'
        ELSE 'INVALID_CHARS'
    END                                         AS validation_status
FROM INTEX_DB.RAW_DEALS.TRANCHE_MASTER;
```

**Result:** String function parsing standardized 15M+ loan identifiers across three agency formats into a single canonical format. CUSIP validation flagged 342 records with invalid formats that would have caused join failures in downstream deal analytics. The REGEXP_REPLACE approach handled all known servicer prefix variations without hard-coding each pattern, making the solution extensible as new servicers were onboarded.

**AI Vision:** A machine learning entity resolution model could go beyond pattern matching to probabilistically link loan IDs across systems even when formats differ significantly — identifying that "FN-00123456" and "FNMA_123456_v2" refer to the same loan by learning servicer-specific encoding patterns from historical matched records.

---

### Q31. How do you use Snowflake date functions to calculate loan age and maturity?

**Situation:** Fannie Mae's risk analytics team needed to compute loan seasoning (age in months since origination), remaining term to maturity, and next payment dates for their entire servicing portfolio. These derived date fields were critical inputs to prepayment and default models. The source data stored origination dates and original loan terms but did not pre-compute age or maturity metrics.

**Task:** Build date function expressions to calculate loan age, remaining term, maturity date, and next payment date from raw origination data, handling edge cases like month-end dates and missing values.

**Action:**
Used Snowflake date functions to derive loan timeline metrics:

```sql
SELECT
    loan_id,
    orig_date,
    orig_loan_term,
    first_payment_date,

    -- Loan age in months (seasoning)
    DATEDIFF('month', orig_date, CURRENT_DATE())           AS loan_age_months,

    -- Maturity date: origination + original term
    DATEADD('month', orig_loan_term, orig_date)            AS maturity_date,

    -- Remaining term in months
    GREATEST(
        DATEDIFF('month', CURRENT_DATE(),
                 DATEADD('month', orig_loan_term, orig_date)),
        0
    )                                                       AS remaining_term_months,

    -- Is the loan past maturity?
    IFF(CURRENT_DATE() > DATEADD('month', orig_loan_term, orig_date),
        TRUE, FALSE)                                        AS is_past_maturity,

    -- Next payment date (1st of next month)
    DATE_TRUNC('month', DATEADD('month', 1, CURRENT_DATE())) AS next_payment_date,

    -- Days until next payment
    DATEDIFF('day', CURRENT_DATE(),
             DATE_TRUNC('month', DATEADD('month', 1, CURRENT_DATE())))
                                                            AS days_to_next_payment,

    -- Loan age bucket for cohort analysis
    CASE
        WHEN DATEDIFF('month', orig_date, CURRENT_DATE()) < 12  THEN 'NEW (0-12m)'
        WHEN DATEDIFF('month', orig_date, CURRENT_DATE()) < 36  THEN 'SEASONED (12-36m)'
        WHEN DATEDIFF('month', orig_date, CURRENT_DATE()) < 60  THEN 'MATURE (36-60m)'
        ELSE 'WELL-SEASONED (60m+)'
    END                                                     AS seasoning_bucket

FROM FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION
WHERE orig_date IS NOT NULL;
```

**Result:** Date function calculations populated loan age and maturity fields for 28M active loans in under 90 seconds. The seasoning bucket classification enabled cohort-level prepayment analysis, revealing that loans in the 12-36 month bucket had 2.3x higher prepayment rates than well-seasoned loans. The GREATEST(..., 0) guard prevented negative remaining terms for 14,000 loans that had passed their maturity date but remained in the servicing system.

**AI Vision:** A time-series forecasting model could use the calculated loan age and remaining term alongside macroeconomic indicators (interest rate curves, housing price indices) to predict month-by-month prepayment and default probabilities for each seasoning bucket — enabling dynamic risk-adjusted valuations for the entire portfolio.

---

### Q32. How do you use CASE expressions in Snowflake to categorize loans by risk tier?

**Situation:** Freddie Mac's credit risk team needed to classify their loan portfolio into risk tiers based on multiple borrower and collateral attributes — credit score, LTV ratio, DTI ratio, and loan purpose. The tier assignments drove capital reserve calculations and investor reporting. Previously, the classification logic lived in a Python script that ran outside the database, creating latency and version control issues.

**Task:** Implement multi-factor risk tier classification directly in Snowflake SQL using CASE expressions, replacing the external Python logic with in-database classification that runs at query time.

**Action:**
Built nested and combined CASE expressions for risk classification:

```sql
SELECT
    loan_id,
    credit_score,
    ltv_ratio,
    dti_ratio,
    loan_purpose,

    -- Credit tier based on FICO score
    CASE
        WHEN credit_score >= 760 THEN 'EXCELLENT'
        WHEN credit_score >= 700 THEN 'GOOD'
        WHEN credit_score >= 660 THEN 'FAIR'
        WHEN credit_score >= 620 THEN 'SUBPRIME'
        WHEN credit_score IS NOT NULL THEN 'DEEP_SUBPRIME'
        ELSE 'NO_SCORE'
    END                                             AS credit_tier,

    -- LTV risk flag
    CASE
        WHEN ltv_ratio > 95 THEN 'VERY_HIGH_LTV'
        WHEN ltv_ratio > 80 THEN 'HIGH_LTV'
        WHEN ltv_ratio > 60 THEN 'MODERATE_LTV'
        ELSE 'LOW_LTV'
    END                                             AS ltv_tier,

    -- Composite risk tier combining multiple factors
    CASE
        WHEN credit_score >= 740 AND ltv_ratio <= 80 AND dti_ratio <= 36
            THEN 'TIER_1_PRIME'
        WHEN credit_score >= 700 AND ltv_ratio <= 90 AND dti_ratio <= 43
            THEN 'TIER_2_NEAR_PRIME'
        WHEN credit_score >= 660 AND ltv_ratio <= 95 AND dti_ratio <= 50
            THEN 'TIER_3_EXPANDED'
        WHEN credit_score >= 620
            THEN 'TIER_4_SUBPRIME'
        ELSE 'TIER_5_UNSCORED'
    END                                             AS composite_risk_tier,

    -- Risk weight for capital calculation
    CASE
        WHEN credit_score >= 740 AND ltv_ratio <= 80 THEN 0.20
        WHEN credit_score >= 700 AND ltv_ratio <= 90 THEN 0.35
        WHEN credit_score >= 660 AND ltv_ratio <= 95 THEN 0.50
        WHEN credit_score >= 620                     THEN 0.75
        ELSE 1.00
    END                                             AS risk_weight

FROM FREDDIE_MAC_DB.STAGING.LOAN_MASTER
WHERE current_upb > 0;
```

**Result:** Moving CASE-based classification into SQL eliminated the external Python dependency and reduced classification runtime from 45 minutes (Python on exported CSV) to 22 seconds (in-database on 30M loans). The composite risk tier distribution showed 42% Tier 1, 28% Tier 2, 18% Tier 3, 9% Tier 4, and 3% Tier 5 — aligning within 0.5% of the prior Python output, confirming parity. Capital reserve calculations using the risk_weight column ran in real-time rather than depending on a nightly batch.

**AI Vision:** A gradient-boosted classification model could replace the hard-coded CASE thresholds with a trained model that dynamically adjusts tier boundaries based on observed default rates — for example, tightening the Tier 1 credit score threshold from 740 to 755 if recent cohorts show elevated early payment defaults in the 740-754 range.

---

### Q33. How do you use CTEs in Snowflake to build readable loan analytics queries?

**Situation:** Ginnie Mae's analytics team had a complex reporting query that calculated pool-level statistics by joining five tables, applying multiple aggregations, and filtering on derived columns. The original query was a 200-line nested subquery monster that no one on the team could confidently modify. A new regulatory requirement added yet another calculation layer, and the team was afraid to touch the existing query.

**Task:** Refactor the monolithic query into a series of Common Table Expressions (CTEs) that separate each logical step, making the query readable, testable, and maintainable.

**Action:**
Decomposed the query into sequential CTEs:

```sql
WITH
-- Step 1: Active loans with basic attributes
active_loans AS (
    SELECT
        pool_id,
        loan_id,
        current_upb,
        interest_rate,
        credit_score,
        loan_age_months,
        delinquency_status
    FROM GINNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
    WHERE reporting_period = '2026-03-01'
      AND current_upb > 0
),

-- Step 2: Pool-level aggregations
pool_summary AS (
    SELECT
        pool_id,
        COUNT(*)                                AS loan_count,
        SUM(current_upb)                        AS total_upb,
        AVG(interest_rate)                      AS wavg_rate,
        AVG(credit_score)                       AS avg_credit_score,
        SUM(CASE WHEN delinquency_status >= 3
                 THEN current_upb ELSE 0 END)   AS serious_dq_upb
    FROM active_loans
    GROUP BY pool_id
),

-- Step 3: Delinquency rate calculation
pool_risk_metrics AS (
    SELECT
        ps.*,
        ROUND(serious_dq_upb / NULLIF(total_upb, 0) * 100, 2) AS sdq_rate_pct,
        CASE
            WHEN serious_dq_upb / NULLIF(total_upb, 0) > 0.05 THEN 'HIGH_RISK'
            WHEN serious_dq_upb / NULLIF(total_upb, 0) > 0.02 THEN 'WATCH'
            ELSE 'PERFORMING'
        END AS pool_risk_status
    FROM pool_summary ps
),

-- Step 4: Enrich with pool master data
enriched_pools AS (
    SELECT
        prm.*,
        pm.issuer_name,
        pm.issue_date,
        pm.original_face_value,
        pm.coupon_rate
    FROM pool_risk_metrics prm
    JOIN GINNIE_MAE_DB.STAGING.POOL_MASTER pm
        ON prm.pool_id = pm.pool_id
)

-- Final output
SELECT
    pool_id,
    issuer_name,
    issue_date,
    loan_count,
    total_upb,
    original_face_value,
    ROUND((1 - total_upb / NULLIF(original_face_value, 0)) * 100, 2) AS paydown_pct,
    wavg_rate,
    coupon_rate,
    avg_credit_score,
    sdq_rate_pct,
    pool_risk_status
FROM enriched_pools
ORDER BY sdq_rate_pct DESC;
```

**Result:** The CTE refactor transformed a 200-line nested query into four clearly labeled steps that any team member could follow. Each CTE could be tested independently by adding a `SELECT * FROM <cte_name>` at the bottom. When the new regulatory requirement arrived (adding a paydown percentage calculation), the team added it to the final SELECT in 5 minutes — versus the estimated 2 hours to safely modify the nested version. Query performance was identical since Snowflake optimizes CTEs as inline views.

**AI Vision:** An AI-powered SQL refactoring assistant could automatically decompose any deeply nested query into CTEs by analyzing the logical dependency graph — identifying natural breakpoints where intermediate result sets form, naming CTEs descriptively based on the columns they compute, and even suggesting which CTEs could be materialized as views for reuse across reports.

---

### Q34. How do you use subqueries to find loans exceeding the pool average balance?

**Situation:** Fannie Mae's portfolio analytics team needed to identify outlier loans — those with current unpaid balances significantly above their pool's average. These high-balance loans disproportionately impacted pool-level performance metrics and required individual monitoring. The analysts were exporting data to Excel and manually computing averages, limiting them to one pool at a time.

**Task:** Write SQL with correlated and non-correlated subqueries to efficiently flag loans whose balance exceeds their pool average by a configurable threshold, across all pools simultaneously.

**Action:**
Used subqueries to compare individual loans against pool-level aggregates:

```sql
-- Non-correlated subquery: loans above the global portfolio average
SELECT
    loan_id,
    pool_id,
    current_upb,
    (SELECT AVG(current_upb)
     FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
     WHERE reporting_period = '2026-03-01'
       AND current_upb > 0) AS portfolio_avg_upb
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
WHERE reporting_period = '2026-03-01'
  AND current_upb > (
      SELECT AVG(current_upb) * 2
      FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
      WHERE reporting_period = '2026-03-01'
        AND current_upb > 0
  );

-- Correlated subquery: loans above THEIR OWN pool average
SELECT
    lp.loan_id,
    lp.pool_id,
    lp.current_upb,
    lp.current_upb - pool_avg.avg_upb              AS above_pool_avg,
    ROUND(lp.current_upb / pool_avg.avg_upb, 2)    AS ratio_to_pool_avg
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE lp
JOIN (
    SELECT
        pool_id,
        AVG(current_upb) AS avg_upb,
        STDDEV(current_upb) AS stddev_upb
    FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
    WHERE reporting_period = '2026-03-01'
      AND current_upb > 0
    GROUP BY pool_id
) pool_avg
    ON lp.pool_id = pool_avg.pool_id
WHERE lp.reporting_period = '2026-03-01'
  AND lp.current_upb > pool_avg.avg_upb + (2 * pool_avg.stddev_upb)
ORDER BY above_pool_avg DESC;

-- EXISTS subquery: pools that contain at least one delinquent jumbo loan
SELECT DISTINCT pool_id
FROM FANNIE_MAE_DB.STAGING.POOL_MASTER pm
WHERE EXISTS (
    SELECT 1
    FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE lp
    WHERE lp.pool_id = pm.pool_id
      AND lp.current_upb > 500000
      AND lp.delinquency_status >= 2
      AND lp.reporting_period = '2026-03-01'
);
```

**Result:** The pool-level subquery approach identified 23,000 outlier loans (balance more than 2 standard deviations above their pool mean) across 4,500 pools in a single 35-second query — replacing the analyst's one-pool-at-a-time Excel workflow that took days. The top 50 outlier loans by absolute deviation were flagged for individual credit review, with the largest being a $2.1M balance in a pool averaging $185K. The EXISTS subquery identified 127 pools with delinquent jumbo loans requiring enhanced monitoring.

**AI Vision:** An anomaly detection model could extend beyond simple statistical thresholds to learn multi-dimensional outlier patterns — flagging loans that are unusual not just in balance but in the combination of balance, LTV, credit score, and geography relative to their pool peers, catching risks that single-variable thresholds would miss.

---

### Q35. How do you use UNION and UNION ALL to combine multi-agency loan feeds?

**Situation:** A mortgage data aggregator needed to build a unified loan-level view combining data from Fannie Mae, Freddie Mac, and Ginnie Mae. Each agency used different column names, data types, and delivery formats. Analysts needed a single table to run cross-agency comparisons for investor reporting. Duplicate loans that appeared in multiple agency feeds (due to re-securitization) needed to be handled appropriately.

**Task:** Create a unified loan view using UNION ALL for raw combination and UNION for deduplication, mapping each agency's schema to a common column structure.

**Action:**
Built the unified view with column mapping and agency tagging:

```sql
-- UNION ALL: preserve all rows from all agencies (fast, no dedup)
CREATE OR REPLACE VIEW MORTGAGE_ANALYTICS_DB.HARMONIZED.ALL_AGENCY_LOANS AS

SELECT
    'FNMA'                          AS agency_code,
    loan_id                         AS loan_identifier,
    orig_upb                        AS original_balance,
    current_upb                     AS current_balance,
    credit_score                    AS borrower_fico,
    orig_interest_rate              AS note_rate,
    ltv_ratio                       AS original_ltv,
    property_state                  AS state_code,
    orig_date                       AS origination_date,
    reporting_period                AS as_of_date
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
WHERE reporting_period = '2026-03-01'

UNION ALL

SELECT
    'FHLMC'                         AS agency_code,
    loan_seq_num                    AS loan_identifier,
    orig_upb                        AS original_balance,
    current_upb                     AS current_balance,
    borrower_credit_score           AS borrower_fico,
    orig_interest_rate              AS note_rate,
    oltv                            AS original_ltv,
    property_state                  AS state_code,
    first_payment_date              AS origination_date,
    monthly_reporting_period        AS as_of_date
FROM FREDDIE_MAC_DB.STAGING.LOAN_MONTHLY
WHERE monthly_reporting_period = '2026-03-01'

UNION ALL

SELECT
    'GNMA'                          AS agency_code,
    ginnie_loan_id                  AS loan_identifier,
    original_loan_amount            AS original_balance,
    remaining_balance               AS current_balance,
    fico_score                      AS borrower_fico,
    interest_rate                   AS note_rate,
    ltv                             AS original_ltv,
    state                           AS state_code,
    loan_origination_date           AS origination_date,
    pool_reporting_date             AS as_of_date
FROM GINNIE_MAE_DB.STAGING.LOAN_LEVEL
WHERE pool_reporting_date = '2026-03-01';

-- Cross-agency summary using the unified view
SELECT
    agency_code,
    COUNT(*)                        AS loan_count,
    SUM(current_balance)            AS total_upb,
    AVG(borrower_fico)              AS avg_fico,
    AVG(note_rate)                  AS avg_rate
FROM MORTGAGE_ANALYTICS_DB.HARMONIZED.ALL_AGENCY_LOANS
GROUP BY agency_code
ORDER BY total_upb DESC;

-- UNION (with dedup) to find unique property states across agencies
SELECT property_state FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE WHERE reporting_period = '2026-03-01'
UNION
SELECT property_state FROM FREDDIE_MAC_DB.STAGING.LOAN_MONTHLY WHERE monthly_reporting_period = '2026-03-01'
UNION
SELECT state FROM GINNIE_MAE_DB.STAGING.LOAN_LEVEL WHERE pool_reporting_date = '2026-03-01';
```

**Result:** The UNION ALL view combined 85M loans across three agencies into a single queryable interface in under 60 seconds. Analysts could now run cross-agency comparisons (e.g., average FICO by agency, geographic concentration by state) from one query instead of three. Using UNION ALL instead of UNION avoided the expensive deduplication sort, which was appropriate since each agency's loans are inherently distinct. The view approach meant no data duplication — the unified view referenced the agency staging tables directly.

**AI Vision:** An automated schema mapper could use NLP to match column names across agencies by semantic meaning (e.g., recognizing that "borrower_credit_score", "fico_score", and "credit_score" all represent the same attribute), auto-generating the UNION ALL column mapping when a new agency or data source is onboarded.

---

### Q36. How do you use INSERT, UPDATE, and DELETE to maintain loan reference data?

**Situation:** CoreLogic's property data team maintained a reference table of US county FIPS codes, county names, and associated metropolitan statistical area (MSA) mappings. This reference data was used to enrich loan records with geographic context. Updates arrived quarterly — new counties were added (rare), existing MSA mappings changed, and obsolete entries needed removal. The team needed reliable DML operations with audit trails.

**Task:** Implement INSERT, UPDATE, and DELETE operations for the county reference table with proper validation and change tracking.

**Action:**
Applied standard DML operations with safeguards:

```sql
-- INSERT: Add new county records from the quarterly update
INSERT INTO CORELOGIC_DB.REFERENCE.COUNTY_MSA_XREF
    (fips_code, county_name, state_code, msa_code, msa_name, effective_date, updated_by)
VALUES
    ('48255', 'Karnes County', 'TX', '41700', 'San Antonio-New Braunfels', '2026-01-01', CURRENT_USER()),
    ('48259', 'Kendall County', 'TX', '41700', 'San Antonio-New Braunfels', '2026-01-01', CURRENT_USER());

-- INSERT from a SELECT (bulk load from staging)
INSERT INTO CORELOGIC_DB.REFERENCE.COUNTY_MSA_XREF
    (fips_code, county_name, state_code, msa_code, msa_name, effective_date, updated_by)
SELECT
    fips_code,
    county_name,
    state_code,
    msa_code,
    msa_name,
    '2026-01-01',
    CURRENT_USER()
FROM CORELOGIC_DB.STAGING.COUNTY_UPDATES_Q1_2026
WHERE fips_code NOT IN (
    SELECT fips_code FROM CORELOGIC_DB.REFERENCE.COUNTY_MSA_XREF
);

-- UPDATE: Correct MSA mapping for counties that were reassigned
UPDATE CORELOGIC_DB.REFERENCE.COUNTY_MSA_XREF
SET
    msa_code = '35620',
    msa_name = 'New York-Newark-Jersey City',
    effective_date = '2026-01-01',
    updated_by = CURRENT_USER()
WHERE fips_code IN ('34003', '34017', '34023')
  AND msa_code != '35620';

-- DELETE: Remove obsolete entries (with safety check first)
-- Step 1: Preview what will be deleted
SELECT * FROM CORELOGIC_DB.REFERENCE.COUNTY_MSA_XREF
WHERE effective_date < '2020-01-01'
  AND fips_code NOT IN (
      SELECT DISTINCT fips_code
      FROM CORELOGIC_DB.STAGING.LOAN_MASTER
  );

-- Step 2: Execute delete
DELETE FROM CORELOGIC_DB.REFERENCE.COUNTY_MSA_XREF
WHERE effective_date < '2020-01-01'
  AND fips_code NOT IN (
      SELECT DISTINCT fips_code
      FROM CORELOGIC_DB.STAGING.LOAN_MASTER
  );

-- Verify changes
SELECT COUNT(*) AS total_counties,
       COUNT(DISTINCT msa_code) AS distinct_msas,
       MAX(effective_date) AS latest_effective
FROM CORELOGIC_DB.REFERENCE.COUNTY_MSA_XREF;
```

**Result:** The quarterly reference data update inserted 12 new county records, updated MSA mappings for 47 counties, and removed 8 obsolete entries — all in under 5 seconds. The NOT IN subquery guard on INSERT prevented duplicate FIPS codes. The preview-before-delete pattern caught an overly broad WHERE clause during testing that would have removed 200+ active counties. Snowflake's automatic Time Travel (default 1 day) provided a safety net, allowing the team to recover any accidentally deleted rows.

**AI Vision:** An AI change-impact analyzer could pre-evaluate any UPDATE or DELETE statement against the loan portfolio, showing exactly how many loan records would be affected by the reference data change — for example, warning that updating an MSA mapping would reclassify 45,000 loans in downstream reports, prompting a review before execution.

---

### Q37. How do you use MERGE to upsert daily loan status updates?

**Situation:** Fannie Mae's servicing platform sent daily loan status files containing updates for loans that changed status (new delinquency, payment received, modification applied) plus new loans entering the portfolio. The target table needed to be updated for existing loans and have new rows inserted for new loans. Running separate INSERT and UPDATE statements created a race condition window where the table was in an inconsistent state.

**Task:** Implement a single atomic MERGE statement that upserts daily loan status updates — updating existing records and inserting new ones — ensuring the target table is never in an intermediate state.

**Action:**
Used MERGE for atomic upsert operations:

```sql
-- Daily MERGE: upsert loan status from staging to target
MERGE INTO FANNIE_MAE_DB.STAGING.LOAN_STATUS_CURRENT AS target
USING FANNIE_MAE_DB.STAGING.DAILY_STATUS_FEED AS source
    ON target.loan_id = source.loan_id

-- When loan exists: update its status fields
WHEN MATCHED AND (
    target.delinquency_status != source.delinquency_status
    OR target.current_upb != source.current_upb
    OR target.loan_modification_flag != source.loan_modification_flag
) THEN UPDATE SET
    target.delinquency_status       = source.delinquency_status,
    target.current_upb              = source.current_upb,
    target.current_interest_rate    = source.current_interest_rate,
    target.loan_modification_flag   = source.loan_modification_flag,
    target.last_payment_date        = source.last_payment_date,
    target.updated_at               = CURRENT_TIMESTAMP()

-- When loan is new: insert the full record
WHEN NOT MATCHED THEN INSERT (
    loan_id,
    pool_id,
    delinquency_status,
    current_upb,
    current_interest_rate,
    loan_modification_flag,
    last_payment_date,
    first_seen_date,
    updated_at
) VALUES (
    source.loan_id,
    source.pool_id,
    source.delinquency_status,
    source.current_upb,
    source.current_interest_rate,
    source.loan_modification_flag,
    source.last_payment_date,
    CURRENT_DATE(),
    CURRENT_TIMESTAMP()
);

-- Verify merge results
SELECT
    COUNT(*)                                            AS total_active_loans,
    COUNT(CASE WHEN first_seen_date = CURRENT_DATE()
               THEN 1 END)                             AS new_loans_today,
    COUNT(CASE WHEN updated_at >= CURRENT_TIMESTAMP() - INTERVAL '1 hour'
               THEN 1 END)                             AS updated_today
FROM FANNIE_MAE_DB.STAGING.LOAN_STATUS_CURRENT;
```

**Result:** The daily MERGE processed 350,000 status changes and 2,500 new loans in a single atomic operation completing in 18 seconds. The conditional update clause (`WHEN MATCHED AND ...`) skipped 280,000 rows that appeared in the daily feed but had no actual changes, reducing write amplification by 80%. The atomic nature of MERGE eliminated the 30-second inconsistency window that existed with separate INSERT/UPDATE statements, which had caused two reporting errors in the prior month.

**AI Vision:** An AI-powered change detection system could analyze the daily MERGE patterns to predict expected update volumes — automatically alerting the team when an unusually high number of delinquency status changes occur (potential data quality issue) or when new loan insertions drop below the expected threshold (potential upstream feed failure).

---

### Q38. How do you use transactions in Snowflake for safe batch operations on deal data?

**Situation:** Intex's deal structuring team needed to update multiple related tables when a new MBS deal was finalized — inserting the deal header, tranche details, and waterfall rules as a coordinated unit. During a production incident, a partial failure left a deal header inserted without its tranches, causing downstream pricing models to error on the incomplete data. The team needed all-or-nothing guarantees.

**Task:** Wrap multi-table deal data operations in explicit transactions to ensure atomicity — either all tables are updated consistently or none are, preventing partial deal records.

**Action:**
Used explicit transaction control for coordinated multi-table operations:

```sql
-- Begin explicit transaction for deal creation
BEGIN TRANSACTION;

-- Step 1: Insert deal header
INSERT INTO INTEX_DB.DEAL_DATA.DEAL_HEADER (
    deal_id, deal_name, agency, settlement_date,
    original_face, coupon_rate, created_at
) VALUES (
    'FNMS_2026_C03', 'Fannie Mae 2026-C03', 'FNMA', '2026-04-01',
    1500000000.00, 3.50, CURRENT_TIMESTAMP()
);

-- Step 2: Insert tranche details
INSERT INTO INTEX_DB.DEAL_DATA.TRANCHE_DETAIL (
    deal_id, tranche_id, tranche_class, cusip,
    original_balance, coupon_rate, tranche_type
) VALUES
    ('FNMS_2026_C03', 'T001', 'A1', '3136B1AA0', 750000000.00, 3.25, 'SENIOR'),
    ('FNMS_2026_C03', 'T002', 'A2', '3136B1AB8', 500000000.00, 3.50, 'SENIOR'),
    ('FNMS_2026_C03', 'T003', 'M1', '3136B1AC6', 150000000.00, 4.00, 'MEZZANINE'),
    ('FNMS_2026_C03', 'T004', 'B1', '3136B1AD4', 100000000.00, 5.25, 'SUBORDINATE');

-- Step 3: Insert waterfall rules
INSERT INTO INTEX_DB.DEAL_DATA.WATERFALL_RULES (
    deal_id, rule_sequence, rule_type, target_tranche, rule_description
) VALUES
    ('FNMS_2026_C03', 1, 'INTEREST', 'A1', 'Pay A1 interest first'),
    ('FNMS_2026_C03', 2, 'INTEREST', 'A2', 'Pay A2 interest second'),
    ('FNMS_2026_C03', 3, 'PRINCIPAL', 'A1', 'Sequential principal to A1'),
    ('FNMS_2026_C03', 4, 'PRINCIPAL', 'A2', 'Sequential principal to A2 after A1 retired'),
    ('FNMS_2026_C03', 5, 'LOSS', 'B1', 'Losses allocated to B1 first');

-- All succeeded: commit the entire deal
COMMIT;

-- If any step fails, roll back everything
-- ROLLBACK;  -- (would be used in error handling)

-- Verify deal integrity
SELECT
    dh.deal_id,
    dh.deal_name,
    COUNT(DISTINCT td.tranche_id)   AS tranche_count,
    COUNT(DISTINCT wr.rule_sequence) AS waterfall_rules,
    SUM(td.original_balance)        AS total_tranche_balance
FROM INTEX_DB.DEAL_DATA.DEAL_HEADER dh
JOIN INTEX_DB.DEAL_DATA.TRANCHE_DETAIL td ON dh.deal_id = td.deal_id
JOIN INTEX_DB.DEAL_DATA.WATERFALL_RULES wr ON dh.deal_id = wr.deal_id
WHERE dh.deal_id = 'FNMS_2026_C03'
GROUP BY dh.deal_id, dh.deal_name;
```

**Result:** The explicit transaction ensured that the deal header, 4 tranches, and 5 waterfall rules were inserted as an atomic unit. When a later deal insertion failed on the tranche step (due to a CUSIP format error), the ROLLBACK prevented the deal header from persisting without its tranches — exactly the scenario that caused the prior production incident. The team adopted transactions for all multi-table deal operations, eliminating partial-record incidents entirely.

**AI Vision:** An AI-driven data integrity checker could define and enforce cross-table consistency rules beyond what transactions alone guarantee — verifying that tranche balances sum to the deal face value, that waterfall rules cover all tranches, and that CUSIP check digits are valid before the COMMIT executes.

---

### Q39. How do you use LIKE and ILIKE for pattern matching on loan descriptions?

**Situation:** Freddie Mac's data governance team needed to search through free-text fields in their loan servicing system — property descriptions, modification comments, and loss mitigation notes. These text fields contained valuable information but were inconsistently formatted, with mixed case, abbreviations, and typos. Standard equality filters missed relevant records.

**Task:** Use LIKE and ILIKE pattern matching to search free-text loan fields effectively, handling case insensitivity and wildcard patterns to find relevant loan subsets.

**Action:**
Applied LIKE and ILIKE with various wildcard patterns:

```sql
-- ILIKE: case-insensitive search for foreclosure-related comments
SELECT
    loan_id,
    modification_comment,
    loss_mitigation_type
FROM FREDDIE_MAC_DB.STAGING.LOAN_SERVICING_NOTES
WHERE modification_comment ILIKE '%foreclosure%'
   OR modification_comment ILIKE '%pre-foreclosure%'
   OR modification_comment ILIKE '%REO%';

-- LIKE with wildcards: find loans with specific property types
SELECT
    loan_id,
    property_description,
    property_type_code
FROM FREDDIE_MAC_DB.STAGING.PROPERTY_MASTER
WHERE property_description LIKE '%CONDO%'           -- exact case
   OR property_description ILIKE '%townhous%'        -- case-insensitive, partial
   OR property_description ILIKE '%co-op%';

-- Pattern matching with _ (single character wildcard)
-- Find loan IDs matching a specific servicer pattern: SVC##-########
SELECT loan_id, servicer_name
FROM FREDDIE_MAC_DB.STAGING.LOAN_MASTER
WHERE loan_id LIKE 'SVC__-________';

-- Escape special characters when searching for literal % or _
SELECT loan_id, modification_comment
FROM FREDDIE_MAC_DB.STAGING.LOAN_SERVICING_NOTES
WHERE modification_comment LIKE '%rate reduced by 0.5\%%' ESCAPE '\\';

-- Combine ILIKE with other filters for targeted searches
SELECT
    loan_id,
    modification_comment,
    delinquency_status,
    current_upb
FROM FREDDIE_MAC_DB.STAGING.LOAN_SERVICING_NOTES lsn
JOIN FREDDIE_MAC_DB.STAGING.LOAN_MASTER lm
    ON lsn.loan_id = lm.loan_id
WHERE (lsn.modification_comment ILIKE '%forbearance%'
       OR lsn.modification_comment ILIKE '%covid%'
       OR lsn.modification_comment ILIKE '%disaster%')
  AND lm.current_upb > 200000
  AND lm.delinquency_status >= 1
ORDER BY lm.current_upb DESC;
```

**Result:** ILIKE pattern searches identified 47,000 loans with foreclosure-related servicing notes across all case variations (Foreclosure, FORECLOSURE, foreclosure). The forbearance/COVID/disaster pattern search uncovered 12,000 high-balance delinquent loans with loss mitigation activity — a subset that required enhanced reporting to FHFA. Using ILIKE instead of LIKE increased match rates by 35% due to inconsistent casing in the free-text fields. The single-character wildcard pattern (`SVC__-________`) precisely filtered loans from a specific servicer without false positives.

**AI Vision:** A natural language understanding model could go beyond keyword matching to semantic search — understanding that "borrower lost income due to pandemic" is related to "COVID forbearance" even without exact keyword overlap, enabling the team to find all relevant servicing notes regardless of how individual servicers phrased their comments.

---

### Q40. How do you use ARRAY and OBJECT functions to work with semi-structured loan attributes?

**Situation:** Ginnie Mae's data platform received loan-level data from issuers in JSON format, where certain fields — such as co-borrower information, property appraisal history, and modification events — were stored as ARRAY and OBJECT types within VARIANT columns. The analytics team needed to query these nested attributes alongside the flat relational columns for regulatory reporting.

**Task:** Use Snowflake's ARRAY and OBJECT functions to construct, query, and manipulate semi-structured loan attributes stored in VARIANT columns.

**Action:**
Applied ARRAY and OBJECT functions for semi-structured data handling:

```sql
-- Create ARRAY and OBJECT values from relational data
SELECT
    loan_id,
    -- Build an OBJECT from loan attributes
    OBJECT_CONSTRUCT(
        'loan_id', loan_id,
        'fico', credit_score,
        'ltv', ltv_ratio,
        'dti', dti_ratio
    )                                           AS loan_attributes_obj,

    -- Build an ARRAY of risk flags
    ARRAY_CONSTRUCT(
        IFF(credit_score < 660, 'LOW_FICO', NULL),
        IFF(ltv_ratio > 95, 'HIGH_LTV', NULL),
        IFF(dti_ratio > 50, 'HIGH_DTI', NULL)
    )                                           AS risk_flags_raw,

    -- Remove NULLs from the risk flags array
    ARRAY_COMPACT(ARRAY_CONSTRUCT(
        IFF(credit_score < 660, 'LOW_FICO', NULL),
        IFF(ltv_ratio > 95, 'HIGH_LTV', NULL),
        IFF(dti_ratio > 50, 'HIGH_DTI', NULL)
    ))                                          AS risk_flags

FROM GINNIE_MAE_DB.STAGING.LOAN_LEVEL
WHERE reporting_date = '2026-03-01'
LIMIT 100;

-- Query OBJECT values from a VARIANT column
SELECT
    loan_id,
    loan_detail_json:borrower.first_name::STRING    AS borrower_first,
    loan_detail_json:borrower.credit_score::INT     AS fico,
    loan_detail_json:property.state::STRING          AS property_state,
    loan_detail_json:property.appraisal_value::FLOAT AS appraisal_value,
    ARRAY_SIZE(loan_detail_json:modification_history) AS num_modifications
FROM GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_JSON_FEED;

-- ARRAY functions: check if a loan has specific flags
SELECT
    loan_id,
    risk_flags_variant,
    ARRAY_SIZE(risk_flags_variant)              AS flag_count,
    ARRAY_CONTAINS('HIGH_LTV'::VARIANT, risk_flags_variant)  AS has_high_ltv,
    ARRAY_TO_STRING(risk_flags_variant, ', ')   AS flags_csv
FROM GINNIE_MAE_DB.STAGING.LOAN_RISK_FLAGS
WHERE ARRAY_SIZE(risk_flags_variant) >= 2;

-- OBJECT_KEYS: list all attributes in a semi-structured record
SELECT
    loan_id,
    OBJECT_KEYS(loan_detail_json)               AS top_level_keys
FROM GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_JSON_FEED
LIMIT 5;
```

**Result:** ARRAY and OBJECT functions enabled the team to query semi-structured JSON loan data with the same ease as relational columns. The risk flags ARRAY approach replaced a six-column boolean flag design with a compact, variable-length list — reducing storage by 40% and making "loans with 2+ risk flags" queries trivial via ARRAY_SIZE. OBJECT_CONSTRUCT allowed the team to package loan snapshots as JSON for downstream API consumers without a separate serialization step. Query performance on VARIANT columns was within 15% of equivalent flat table queries thanks to Snowflake's columnar pruning on semi-structured data.

**AI Vision:** An AI-powered schema evolution tracker could monitor changes in the JSON structure across issuer deliveries — detecting when a new nested attribute appears, an existing field changes type, or an array grows beyond expected bounds — automatically updating downstream parsing logic and alerting the team to breaking changes.

---

### Q41. How do you use lateral flatten to extract arrays from JSON loan records?

**Situation:** Intex's deal analytics platform ingested structured MBS deal data where each deal record contained a JSON array of tranches and each tranche contained a nested array of payment dates. To perform tranche-level and payment-level analysis, the team needed to "explode" these nested arrays into relational rows that could be joined, filtered, and aggregated using standard SQL.

**Task:** Use LATERAL FLATTEN to convert nested JSON arrays in deal records into relational rows, handling both single-level and multi-level array nesting.

**Action:**
Applied LATERAL FLATTEN to unnest JSON arrays:

```sql
-- Sample JSON structure in the VARIANT column:
-- { "deal_id": "FNMS_2026_C03",
--   "tranches": [
--     { "class": "A1", "cusip": "3136B1AA0", "balance": 750000000,
--       "payment_dates": ["2026-04-25", "2026-05-25", "2026-06-25"] },
--     { "class": "A2", "cusip": "3136B1AB8", "balance": 500000000,
--       "payment_dates": ["2026-04-25", "2026-05-25", "2026-06-25"] }
--   ] }

-- Single-level flatten: extract tranches from deal JSON
SELECT
    deal_json:deal_id::STRING                   AS deal_id,
    tranche.index                               AS tranche_index,
    tranche.value:class::STRING                 AS tranche_class,
    tranche.value:cusip::STRING                 AS cusip,
    tranche.value:balance::NUMBER(15,2)         AS tranche_balance,
    ARRAY_SIZE(tranche.value:payment_dates)     AS num_payments
FROM INTEX_DB.DEAL_DATA.DEAL_JSON_FEED,
    LATERAL FLATTEN(input => deal_json:tranches) AS tranche;

-- Multi-level flatten: extract individual payment dates per tranche
SELECT
    deal_json:deal_id::STRING                   AS deal_id,
    tranche.value:class::STRING                 AS tranche_class,
    tranche.value:cusip::STRING                 AS cusip,
    payment.index + 1                           AS payment_number,
    payment.value::DATE                         AS payment_date
FROM INTEX_DB.DEAL_DATA.DEAL_JSON_FEED,
    LATERAL FLATTEN(input => deal_json:tranches) AS tranche,
    LATERAL FLATTEN(input => tranche.value:payment_dates) AS payment;

-- Flatten with OUTER => true to keep deals with empty tranche arrays
SELECT
    deal_json:deal_id::STRING                   AS deal_id,
    tranche.value:class::STRING                 AS tranche_class,
    COALESCE(tranche.value:balance::NUMBER(15,2), 0) AS tranche_balance
FROM INTEX_DB.DEAL_DATA.DEAL_JSON_FEED,
    LATERAL FLATTEN(input => deal_json:tranches, OUTER => TRUE) AS tranche;

-- Aggregate after flatten: total balance by deal
SELECT
    deal_json:deal_id::STRING                   AS deal_id,
    COUNT(DISTINCT tranche.value:class::STRING) AS tranche_count,
    SUM(tranche.value:balance::NUMBER(15,2))    AS total_deal_balance
FROM INTEX_DB.DEAL_DATA.DEAL_JSON_FEED,
    LATERAL FLATTEN(input => deal_json:tranches) AS tranche
GROUP BY deal_json:deal_id::STRING
ORDER BY total_deal_balance DESC;
```

**Result:** LATERAL FLATTEN converted 5,000 deal JSON records (each containing 3-15 tranches) into 42,000 tranche-level rows in 4 seconds. The multi-level flatten produced 1.2M payment-date rows for cash flow analysis. Using OUTER => TRUE preserved 12 deal records that had empty tranche arrays (deals in pre-structuring phase), preventing silent data loss. The flattened relational format enabled standard GROUP BY aggregations and JOIN operations that were impossible against the raw nested JSON.

**AI Vision:** An AI JSON schema analyzer could automatically detect the nesting depth and array structures in new deal feeds, generating the optimal LATERAL FLATTEN query chain without manual inspection — and recommending whether to materialize the flattened data as a table (for frequently queried structures) or keep it as a view (for rarely accessed nested attributes).

---

### Q42. How do you use SAMPLE and TABLESAMPLE to create test subsets of loan data?

**Situation:** Fannie Mae's data science team needed to develop prepayment models on a representative subset of the 30M-loan portfolio. Running model training queries against the full dataset consumed excessive warehouse credits and took hours. The team also needed reproducible samples for regression testing, where the same sample could be regenerated to verify model output stability.

**Task:** Use SAMPLE and TABLESAMPLE to create efficient, representative test subsets of loan data for model development and regression testing, with options for both random and reproducible sampling.

**Action:**
Applied sampling techniques for different use cases:

```sql
-- Row-based sampling: random 1% sample (~300K loans from 30M)
SELECT *
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
    SAMPLE (1);

-- Fixed row count: exactly 50,000 random loans
SELECT *
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
    SAMPLE (50000 ROWS);

-- TABLESAMPLE with BERNOULLI method (row-level probability)
SELECT *
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
    TABLESAMPLE BERNOULLI (0.5);

-- TABLESAMPLE with SYSTEM method (block-level, faster but less uniform)
SELECT *
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
    TABLESAMPLE SYSTEM (5);

-- Reproducible sample using SEED (same seed = same sample)
SELECT *
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE
    SAMPLE (1) SEED (42);

-- Create a materialized test dataset for model development
CREATE OR REPLACE TABLE FANNIE_MAE_DB.SANDBOX.MODEL_TRAINING_SET AS
SELECT
    lp.*,
    la.credit_score,
    la.orig_interest_rate,
    la.dti_ratio,
    la.ltv_ratio
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE lp
    SAMPLE (2) SEED (42)
JOIN FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION la
    ON lp.loan_id = la.loan_id
WHERE lp.reporting_period = '2026-03-01';

-- Verify sample representativeness
SELECT
    'FULL_POPULATION' AS dataset,
    AVG(credit_score) AS avg_fico,
    AVG(ltv_ratio) AS avg_ltv,
    AVG(current_upb) AS avg_balance
FROM FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE lp
JOIN FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION la ON lp.loan_id = la.loan_id
WHERE lp.reporting_period = '2026-03-01'
UNION ALL
SELECT
    'SAMPLE_2PCT' AS dataset,
    AVG(credit_score), AVG(ltv_ratio), AVG(current_upb)
FROM FANNIE_MAE_DB.SANDBOX.MODEL_TRAINING_SET;
```

**Result:** The 2% seeded sample created a 600K-loan training dataset that ran model queries 50x faster than the full population. The SEED parameter ensured identical samples across runs — critical for regression testing where model output needed to be deterministic. Sample representativeness validation showed the 2% sample's average FICO was within 1 point, average LTV within 0.3%, and average balance within $500 of the full population — statistically indistinguishable. The SYSTEM sampling method was 3x faster than BERNOULLI for exploratory work where perfect uniformity was not required.

**AI Vision:** A stratified sampling engine could ensure the sample preserves the population's distribution across key dimensions (state, vintage, risk tier) rather than relying on random sampling — guaranteeing that rare but important subgroups (like high-balance loans in disaster-declared counties) are proportionally represented in the training set.

---

### Q43. How do you use CREATE OR REPLACE to manage development workflow for loan objects?

**Situation:** Freddie Mac's development team was iterating rapidly on staging table definitions and views during a data model redesign. Developers frequently needed to recreate tables with modified column definitions, updated clustering keys, or new default values. Using DROP followed by CREATE left a window where dependent views and tasks would break. The team needed an atomic replacement approach.

**Task:** Use CREATE OR REPLACE for tables, views, and other objects to atomically replace definitions during development without breaking dependent objects or losing the ability to roll back.

**Action:**
Applied CREATE OR REPLACE across different object types:

```sql
-- CREATE OR REPLACE TABLE: atomic table redefinition
-- WARNING: This drops and recreates the table (data is lost!)
CREATE OR REPLACE TABLE FREDDIE_MAC_DB.STAGING.LOAN_MASTER (
    loan_seq_num        STRING      NOT NULL,
    servicer_name       STRING,
    orig_interest_rate  FLOAT,
    orig_upb            NUMBER(12,2),
    orig_loan_term      INTEGER,
    orig_date           DATE,
    credit_score        INTEGER,
    dti_ratio           FLOAT,
    ltv_ratio           INTEGER,
    channel             STRING      DEFAULT 'UNKNOWN',
    property_state      STRING(2),
    property_type       STRING(10),
    loan_purpose        STRING(5),
    -- New columns added in redesign
    mi_percentage       FLOAT,
    borrower_count      INTEGER     DEFAULT 1,
    created_at          TIMESTAMP   DEFAULT CURRENT_TIMESTAMP(),
    updated_at          TIMESTAMP   DEFAULT CURRENT_TIMESTAMP()
);

-- CREATE OR REPLACE VIEW: safe — no data loss, just redefines the query
CREATE OR REPLACE VIEW FREDDIE_MAC_DB.REPORTING.LOAN_SUMMARY_VW AS
SELECT
    property_state,
    loan_purpose,
    COUNT(*)                    AS loan_count,
    SUM(orig_upb)              AS total_orig_upb,
    AVG(credit_score)          AS avg_credit_score,
    AVG(dti_ratio)             AS avg_dti,
    AVG(ltv_ratio)             AS avg_ltv
FROM FREDDIE_MAC_DB.STAGING.LOAN_MASTER
GROUP BY property_state, loan_purpose;

-- CREATE OR REPLACE FILE FORMAT: update parsing rules
CREATE OR REPLACE FILE FORMAT FREDDIE_MAC_DB.STAGING.LOAN_CSV_FORMAT
    TYPE = 'CSV'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('', 'NULL', 'N/A', '.')
    DATE_INPUT_FORMAT = 'MM/YYYY'
    TIMESTAMP_INPUT_FORMAT = 'YYYY-MM-DD HH24:MI:SS'
    TRIM_SPACE = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- CREATE OR REPLACE STAGE: update stage configuration
CREATE OR REPLACE STAGE FREDDIE_MAC_DB.STAGING.LOAN_LOAD_STAGE
    FILE_FORMAT = FREDDIE_MAC_DB.STAGING.LOAN_CSV_FORMAT
    COMMENT = 'Freddie Mac loan tape ingestion stage - v2 format';

-- Verify Time Travel availability for rollback (table only)
SELECT * FROM FREDDIE_MAC_DB.STAGING.LOAN_MASTER
    BEFORE (STATEMENT => LAST_QUERY_ID())
LIMIT 10;
```

**Result:** CREATE OR REPLACE atomically swapped object definitions with zero downtime — dependent views referencing the table were unaffected as long as column names remained compatible. The development cycle dropped from 15 minutes (manual DROP, verify no dependencies, CREATE, re-grant privileges) to 30 seconds per iteration. Time Travel provided a safety net for tables — the team could access data from before the replacement for up to 90 days (on Enterprise edition). For views and file formats, CREATE OR REPLACE was completely safe since no data was at risk.

**AI Vision:** An AI dependency analyzer could map all downstream objects (views, tasks, streams, stored procedures) that reference a table before a CREATE OR REPLACE executes — warning the developer if the schema change would break any dependent object and suggesting compatible column additions or renames.

---

### Q44. How do you use SWAP TABLE for atomic table swaps during loan data refreshes?

**Situation:** CoreLogic's data pipeline rebuilt a large property valuation table nightly by loading fresh AVM data into a staging copy and then replacing the production table. The prior approach used DROP + RENAME, which created a brief window where the production table did not exist — causing query failures for any analysts running reports during the 2 AM refresh window. The team needed a zero-downtime swap.

**Task:** Use ALTER TABLE SWAP WITH to atomically exchange the staging and production tables, eliminating any window where the production table is unavailable.

**Action:**
Implemented the build-then-swap pattern:

```sql
-- Step 1: Create the replacement table with fresh data
CREATE OR REPLACE TABLE CORELOGIC_DB.STAGING.PROPERTY_AVM_NEW
    CLONE CORELOGIC_DB.PRODUCTION.PROPERTY_AVM;

-- Step 2: Truncate the clone and reload with today's data
TRUNCATE TABLE CORELOGIC_DB.STAGING.PROPERTY_AVM_NEW;

COPY INTO CORELOGIC_DB.STAGING.PROPERTY_AVM_NEW
FROM @CORELOGIC_DB.STAGING.AVM_STAGE/daily/2026-03-08/
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1)
ON_ERROR = 'ABORT_STATEMENT';

-- Step 3: Validate the new data before swapping
SELECT
    'NEW_TABLE' AS source,
    COUNT(*)    AS row_count,
    COUNT(DISTINCT property_id) AS unique_properties,
    MIN(valuation_date) AS min_date,
    MAX(valuation_date) AS max_date
FROM CORELOGIC_DB.STAGING.PROPERTY_AVM_NEW
UNION ALL
SELECT
    'CURRENT_PROD',
    COUNT(*),
    COUNT(DISTINCT property_id),
    MIN(valuation_date),
    MAX(valuation_date)
FROM CORELOGIC_DB.PRODUCTION.PROPERTY_AVM;

-- Step 4: Atomic swap — instantaneous, zero downtime
ALTER TABLE CORELOGIC_DB.PRODUCTION.PROPERTY_AVM
    SWAP WITH CORELOGIC_DB.STAGING.PROPERTY_AVM_NEW;

-- After swap:
-- PRODUCTION.PROPERTY_AVM now contains the fresh data
-- STAGING.PROPERTY_AVM_NEW now contains the old production data (as backup)

-- Step 5: Verify the swap succeeded
SELECT COUNT(*), MAX(valuation_date)
FROM CORELOGIC_DB.PRODUCTION.PROPERTY_AVM;

-- Step 6: Keep old data as backup for 7 days, then drop
-- DROP TABLE CORELOGIC_DB.STAGING.PROPERTY_AVM_NEW;
-- (or let it serve as rollback for a week)
```

**Result:** The ALTER TABLE SWAP completed in under 1 second for a 45M-row table — it only exchanged metadata pointers, not actual data. Zero analyst queries failed during the nightly refresh, eliminating the 3-5 query failures per night that occurred with the DROP + RENAME approach. The old production data remained available in the staging table for instant rollback if data quality issues were discovered. The build-validate-swap pattern became the team standard for all nightly refreshes, reducing production incidents by 100%.

**AI Vision:** An AI data quality gate could automatically compare the new and old table versions across dozens of statistical metrics (row counts, value distributions, NULL rates, referential integrity) and only approve the SWAP if all checks pass — automatically rolling back to the previous version and alerting the team if anomalies are detected.

---

### Q45. How do you use COMMENT ON to document loan tables and columns?

**Situation:** Fannie Mae's data governance team conducted an audit and found that 80% of tables in the loan analytics database had no descriptions, and none of the columns had comments explaining their business meaning. New analysts spent days asking colleagues what columns like "DLQ_STATUS", "MI_PCT", or "ORIG_CHAN" meant. The lack of documentation was a compliance risk under data governance policies.

**Task:** Add comprehensive comments to loan tables and columns using COMMENT ON, creating a self-documenting data catalog directly in Snowflake metadata.

**Action:**
Applied COMMENT ON statements to tables and columns:

```sql
-- Table-level comments
COMMENT ON TABLE FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION IS
    'Fannie Mae Single-Family Loan Acquisition data. One row per loan at origination. '
    'Source: Fannie Mae quarterly loan-level disclosure files. '
    'Refresh: Quarterly. Grain: loan_id. Owner: Data Engineering.';

COMMENT ON TABLE FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE IS
    'Fannie Mae Single-Family Loan Performance data. Monthly snapshot of loan status. '
    'Source: Fannie Mae monthly performance files. '
    'Refresh: Monthly. Grain: loan_id + reporting_period. Owner: Data Engineering.';

-- Column-level comments
COMMENT ON COLUMN FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION.CREDIT_SCORE IS
    'Borrower FICO credit score at origination. Range: 300-850. '
    'NULL indicates score not available. Used for risk tier classification.';

COMMENT ON COLUMN FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION.ORIG_UPB IS
    'Original Unpaid Principal Balance in USD at loan origination. '
    'Conforming loan limit applies. Precision: NUMBER(12,2).';

COMMENT ON COLUMN FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION.DTI_RATIO IS
    'Debt-to-Income ratio at origination as a percentage (e.g., 43.5 = 43.5%). '
    'Includes all monthly debt obligations divided by gross monthly income. '
    'QM threshold: 43%. NULL if not disclosed.';

COMMENT ON COLUMN FANNIE_MAE_DB.STAGING.LOAN_ACQUISITION.ORIG_CHAN IS
    'Origination Channel. R=Retail, B=Broker, C=Correspondent, T=TPO Not Specified. '
    'Indicates how the loan was originated and sold to Fannie Mae.';

COMMENT ON COLUMN FANNIE_MAE_DB.STAGING.LOAN_PERFORMANCE.DLQ_STATUS IS
    'Delinquency Status. 0=Current, 1=30-day, 2=60-day, 3=90-day, '
    'R=REO, F=Foreclosure, 9=Unknown. String type to accommodate letter codes.';

-- View-level comment
COMMENT ON VIEW FANNIE_MAE_DB.REPORTING.LOAN_SUMMARY_VW IS
    'Aggregated loan summary by state and purpose. Refreshes with base table. '
    'Used by: Monthly investor reporting, FHFA regulatory submissions.';

-- Verify comments are stored
SELECT
    TABLE_NAME,
    COMMENT
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'STAGING'
  AND TABLE_CATALOG = 'FANNIE_MAE_DB'
ORDER BY TABLE_NAME;

-- View column comments
SELECT
    COLUMN_NAME,
    DATA_TYPE,
    COMMENT
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'LOAN_ACQUISITION'
  AND TABLE_SCHEMA = 'STAGING'
  AND TABLE_CATALOG = 'FANNIE_MAE_DB'
ORDER BY ORDINAL_POSITION;
```

**Result:** Comments were added to 15 tables and 120 columns in the loan analytics database in under 10 minutes. New analyst onboarding time dropped from 3 days to half a day because column meanings were discoverable directly in Snowflake's UI and INFORMATION_SCHEMA. The data governance audit score improved from 35% to 92% documentation coverage. Comments were visible in Snowsight, SnowSQL, and any BI tool querying INFORMATION_SCHEMA, creating a single source of truth for metadata.

**AI Vision:** An AI documentation generator could analyze column names, data types, value distributions, and relationships to auto-generate initial COMMENT ON statements — for example, inferring that a column named "FICO_SCORE" with values between 300 and 850 is "Borrower FICO credit score" and suggesting a draft comment for human review, accelerating documentation of undocumented legacy tables.

---

### Q46. How do you use SHOW commands to explore database objects and warehouses?

**Situation:** A new data engineer joined Freddie Mac's analytics team and needed to quickly inventory the Snowflake environment — understanding which databases, schemas, tables, warehouses, and stages existed, their sizes, and ownership. The team's wiki documentation was six months out of date. The engineer needed to explore the live environment directly.

**Task:** Use SHOW commands to discover and inventory Snowflake objects across databases, schemas, warehouses, and stages without relying on external documentation.

**Action:**
Used various SHOW commands to explore the environment:

```sql
-- Show all databases the current role can access
SHOW DATABASES;

-- Show schemas in a specific database
SHOW SCHEMAS IN DATABASE FREDDIE_MAC_DB;

-- Show tables in a schema with filtering
SHOW TABLES IN SCHEMA FREDDIE_MAC_DB.STAGING;

-- Filter SHOW results with LIKE pattern
SHOW TABLES LIKE '%LOAN%' IN SCHEMA FREDDIE_MAC_DB.STAGING;

-- Show views in reporting schema
SHOW VIEWS IN SCHEMA FREDDIE_MAC_DB.REPORTING;

-- Show all warehouses and their configurations
SHOW WAREHOUSES;

-- Query SHOW results as a table using RESULT_SCAN
SHOW TABLES IN SCHEMA FREDDIE_MAC_DB.STAGING;
SELECT
    "name"          AS table_name,
    "rows"          AS row_count,
    "bytes"         AS size_bytes,
    ROUND("bytes" / (1024*1024*1024), 2) AS size_gb,
    "created_on"    AS created_date,
    "comment"       AS description
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "bytes" DESC;

-- Show stages for understanding data loading setup
SHOW STAGES IN SCHEMA FREDDIE_MAC_DB.STAGING;

-- Show file formats
SHOW FILE FORMATS IN SCHEMA FREDDIE_MAC_DB.STAGING;

-- Show grants on a specific table
SHOW GRANTS ON TABLE FREDDIE_MAC_DB.STAGING.LOAN_MASTER;

-- Show roles available to the current user
SHOW ROLES;

-- Show parameters at account and warehouse level
SHOW PARAMETERS IN WAREHOUSE ETL_LOADER_WH;
```

**Result:** The SHOW command exploration provided a complete real-time inventory in 15 minutes: 5 databases, 18 schemas, 47 tables (largest being LOAN_PERFORMANCE at 85 GB with 900M rows), 12 views, 4 warehouses, and 6 stages. Converting SHOW output to queryable results via RESULT_SCAN allowed the engineer to sort tables by size and identify the 3 largest tables consuming 80% of storage. The SHOW GRANTS output revealed that a legacy role still had OWNERSHIP on production tables — a security finding that was immediately escalated. This live exploration was more accurate than the outdated wiki.

**AI Vision:** An AI environment profiler could periodically run SHOW commands, compare results against the prior snapshot, and generate a change report — highlighting new tables created, tables that have grown abnormally, warehouses that were resized, or grants that changed, providing a continuous governance audit trail without manual effort.

---

### Q47. How do you use the DESCRIBE command to inspect table structures and column types?

**Situation:** Ginnie Mae's integration team was building ETL pipelines to load data from multiple issuers. Each issuer's table had slightly different column definitions — varying data types, precision, and nullability. Before writing COPY INTO or INSERT statements, the team needed to understand the exact target table structure, including column types, default values, and constraints.

**Task:** Use DESCRIBE to inspect table and view structures, comparing target schema definitions to understand type compatibility and identify mismatches before data loading.

**Action:**
Applied DESCRIBE across tables and other objects:

```sql
-- Describe a table: shows columns, types, nullability, defaults
DESCRIBE TABLE GINNIE_MAE_DB.STAGING.LOAN_LEVEL;

-- Query DESCRIBE output for detailed analysis
DESCRIBE TABLE GINNIE_MAE_DB.STAGING.LOAN_LEVEL;
SELECT
    "name"          AS column_name,
    "type"          AS data_type,
    "kind"          AS column_kind,
    "null?"         AS is_nullable,
    "default"       AS default_value,
    "comment"       AS column_comment
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Describe a view to see its column output types
DESCRIBE VIEW GINNIE_MAE_DB.REPORTING.POOL_SUMMARY_VW;

-- Describe a stage to see its configuration
DESCRIBE STAGE GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_STAGE;

-- Describe a file format
DESCRIBE FILE FORMAT GINNIE_MAE_DB.STAGING.ISSUER_CSV_FORMAT;

-- Compare two tables: source vs target column alignment
-- Step 1: Describe source
DESCRIBE TABLE GINNIE_MAE_DB.RAW_LOAN_LEVEL.ISSUER_A_RAW;
CREATE TEMPORARY TABLE source_cols AS
SELECT "name" AS col_name, "type" AS col_type
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Step 2: Describe target
DESCRIBE TABLE GINNIE_MAE_DB.STAGING.LOAN_LEVEL;
CREATE TEMPORARY TABLE target_cols AS
SELECT "name" AS col_name, "type" AS col_type
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Step 3: Find mismatches
SELECT
    COALESCE(s.col_name, t.col_name) AS column_name,
    s.col_type AS source_type,
    t.col_type AS target_type,
    CASE
        WHEN s.col_name IS NULL THEN 'MISSING_IN_SOURCE'
        WHEN t.col_name IS NULL THEN 'MISSING_IN_TARGET'
        WHEN s.col_type != t.col_type THEN 'TYPE_MISMATCH'
        ELSE 'MATCHED'
    END AS status
FROM source_cols s
FULL OUTER JOIN target_cols t ON s.col_name = t.col_name
ORDER BY status, column_name;
```

**Result:** The DESCRIBE-based comparison revealed 4 column type mismatches between the source (issuer A raw table) and the target staging table — a VARCHAR(50) versus VARCHAR(100) on servicer_name, a FLOAT versus NUMBER(12,2) on balance, and two DATE format differences. These mismatches would have caused silent truncation or load failures. The team fixed the target table definitions before loading, preventing data quality issues. The DESCRIBE stage output confirmed the file format association and encryption settings, which helped debug a separate loading issue where the wrong file format was attached.

**AI Vision:** An AI schema compatibility checker could automatically DESCRIBE all source and target tables involved in a pipeline, detect type mismatches, precision losses, and nullable conflicts, then auto-generate the necessary CAST expressions or ALTER TABLE statements to achieve compatibility — turning a manual schema alignment task into a one-click operation.

---

### Q48. How do you understand Snowflake account identifiers and URLs for connectivity?

**Situation:** Fannie Mae's data engineering team was configuring multiple tools — SnowSQL CLI, Python connectors, JDBC drivers, dbt, and Airflow — to connect to their Snowflake account. Different tools required different formats for the account identifier, and incorrect configurations caused authentication failures. The team also needed to understand the relationship between the account URL, organization name, and account locator.

**Task:** Document and configure the correct Snowflake account identifiers and connection URLs for all tools in the data engineering stack.

**Action:**
Identified the account identifier components and configured connections:

```sql
-- Query current account details
SELECT
    CURRENT_ACCOUNT()       AS account_locator,
    CURRENT_ORGANIZATION_NAME() AS org_name,
    CURRENT_REGION()        AS cloud_region,
    CURRENT_USER()          AS logged_in_user,
    CURRENT_ROLE()          AS active_role,
    CURRENT_WAREHOUSE()     AS active_warehouse;

-- Account Identifier formats:
-- 1. Preferred format (org-based):
--    <org_name>-<account_name>
--    Example: fannie_mae-prod_analytics
--    URL: https://fannie_mae-prod_analytics.snowflakecomputing.com

-- 2. Legacy format (locator-based):
--    <account_locator>.<region>.<cloud>
--    Example: xy12345.us-east-1.aws
--    URL: https://xy12345.us-east-1.aws.snowflakecomputing.com

-- SnowSQL connection config (~/.snowsql/config):
-- [connections.fannie_prod]
-- accountname = fannie_mae-prod_analytics
-- username = svc_etl_loader
-- rolename = ETL_ROLE
-- warehousename = ETL_LOADER_WH
-- dbname = FANNIE_MAE_DB
-- schemaname = STAGING

-- Python connector configuration
-- import snowflake.connector
-- conn = snowflake.connector.connect(
--     account='fannie_mae-prod_analytics',
--     user='svc_etl_loader',
--     password=os.environ['SNOWFLAKE_PASSWORD'],
--     warehouse='ETL_LOADER_WH',
--     database='FANNIE_MAE_DB',
--     schema='STAGING',
--     role='ETL_ROLE'
-- )

-- JDBC connection string format
-- jdbc:snowflake://fannie_mae-prod_analytics.snowflakecomputing.com
--   ?warehouse=ETL_LOADER_WH&db=FANNIE_MAE_DB&schema=STAGING&role=ETL_ROLE

-- Verify connectivity parameters are correct
SHOW PARAMETERS LIKE '%NETWORK%' IN ACCOUNT;

-- List network policies that may affect connectivity
SHOW NETWORK POLICIES;
```

**Result:** Standardizing on the organization-based account identifier (`fannie_mae-prod_analytics`) resolved connectivity issues across all tools — the legacy locator format had been causing failures in tools that did not properly handle the region suffix. The team created a shared configuration template with the correct account identifier, reducing new tool onboarding from 2 hours of troubleshooting to 5 minutes. Network policy review revealed an outdated IP allowlist that was blocking the new Airflow server, which was added to resolve intermittent connection failures.

**AI Vision:** An AI connectivity diagnostician could analyze failed connection attempts across all tools, correlate error patterns with known configuration issues (wrong account format, missing region suffix, network policy blocks), and suggest the exact fix — eliminating the trial-and-error debugging cycle that plagues multi-tool Snowflake environments.

---

### Q49. How do you configure warehouse auto-suspend and auto-resume for cost optimization?

**Situation:** Freddie Mac's Snowflake account was running a monthly compute bill 40% over budget. Analysis revealed that three warehouses were running 24/7 despite being used only during business hours (8 AM - 6 PM ET) and during nightly ETL windows (1 AM - 3 AM ET). The default auto-suspend of 10 minutes was too aggressive for interactive analysts (frequent resumes caused latency) but too lenient for batch ETL warehouses (10 minutes of idle burn per job).

**Task:** Configure optimal auto-suspend and auto-resume settings for each warehouse type — interactive, ETL, and reporting — balancing cost savings against user experience.

**Action:**
Tuned auto-suspend and auto-resume per workload profile:

```sql
-- Interactive analyst warehouse: longer suspend to avoid resume latency
ALTER WAREHOUSE ANALYST_QUERY_WH SET
    AUTO_SUSPEND = 300      -- 5 minutes: analysts pause between queries
    AUTO_RESUME = TRUE      -- resume instantly when a query arrives
    COMMENT = 'Interactive analyst queries - 5min suspend balances cost vs UX';

-- ETL batch warehouse: aggressive suspend between jobs
ALTER WAREHOUSE ETL_LOADER_WH SET
    AUTO_SUSPEND = 60       -- 1 minute: ETL jobs have gaps between steps
    AUTO_RESUME = TRUE
    COMMENT = 'Batch ETL loads - 1min suspend minimizes idle burn';

-- Reporting warehouse: moderate suspend for scheduled reports
ALTER WAREHOUSE REPORTING_WH SET
    AUTO_SUSPEND = 120      -- 2 minutes: reports run in bursts
    AUTO_RESUME = TRUE
    COMMENT = 'Scheduled reports - 2min suspend';

-- Immediately suspend an idle warehouse (manual override)
ALTER WAREHOUSE ANALYST_QUERY_WH SUSPEND;

-- Verify current warehouse states
SHOW WAREHOUSES;
SELECT
    "name"              AS warehouse_name,
    "size"              AS wh_size,
    "state"             AS current_state,
    "auto_suspend"      AS auto_suspend_secs,
    "auto_resume"       AS auto_resume_flag,
    "running"           AS running_queries,
    "queued"            AS queued_queries
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Monitor warehouse usage to validate settings
SELECT
    warehouse_name,
    DATE_TRUNC('hour', start_time)       AS hour_bucket,
    SUM(credits_used)                     AS credits_consumed,
    COUNT(*)                              AS query_count,
    AVG(DATEDIFF('second', start_time, end_time)) AS avg_query_secs
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_DATE())
GROUP BY warehouse_name, hour_bucket
ORDER BY warehouse_name, hour_bucket;
```

**Result:** Optimized auto-suspend settings reduced monthly compute costs by 28% ($8,400/month). The ETL warehouse's 60-second suspend saved 45 minutes of idle time per nightly run (across the gaps between load steps). The analyst warehouse's 5-minute suspend eliminated the cold-start complaints — analysts no longer experienced 15-second resume delays on every query. The reporting warehouse saved the most by suspending between scheduled report bursts instead of running continuously. Total annual savings were approximately $100K with no impact on query performance or SLA compliance.

**AI Vision:** A predictive auto-suspend optimizer could learn each warehouse's query arrival patterns by day and hour, dynamically adjusting suspend timeouts — for example, keeping the analyst warehouse alive during the 9 AM - 11 AM peak query period (when inter-query gaps are under 2 minutes) but aggressively suspending during lunch hours when gaps exceed 30 minutes.

---

### Q50. How do you understand Snowflake credit usage and billing basics for budgeting?

**Situation:** Ginnie Mae's finance and data engineering teams needed to build a monthly Snowflake cost forecast. The invoice showed charges for compute (credits), storage, and data transfer, but the teams did not understand how credits mapped to warehouse sizes, how storage was metered, or how to identify the top cost drivers. Without this understanding, budget planning was guesswork.

**Task:** Query Snowflake's ACCOUNT_USAGE views to understand credit consumption patterns, storage costs, and billing components, enabling accurate monthly cost forecasting.

**Action:**
Queried usage views to break down costs by component:

```sql
-- Credit pricing context (as of 2026):
-- 1 credit = ~$2-4 depending on Snowflake edition and cloud provider
-- X-Small=1 credit/hr, Small=2, Medium=4, Large=8, X-Large=16, etc.

-- Monthly credit consumption by warehouse
SELECT
    warehouse_name,
    SUM(credits_used)                               AS total_credits,
    ROUND(SUM(credits_used) * 3.00, 2)             AS estimated_cost_usd,
    COUNT(DISTINCT DATE_TRUNC('day', start_time))   AS active_days
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATE_TRUNC('month', CURRENT_DATE())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- Daily credit trend for budget tracking
SELECT
    DATE_TRUNC('day', start_time)                   AS usage_date,
    warehouse_name,
    SUM(credits_used)                               AS daily_credits,
    ROUND(SUM(credits_used) * 3.00, 2)             AS daily_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY usage_date, warehouse_name
ORDER BY usage_date DESC, daily_credits DESC;

-- Storage costs (billed per TB per month)
SELECT
    USAGE_DATE,
    ROUND(STORAGE_BYTES / POWER(1024, 4), 2)       AS storage_tb,
    ROUND(STAGE_BYTES / POWER(1024, 4), 2)          AS stage_tb,
    ROUND(FAILSAFE_BYTES / POWER(1024, 4), 2)      AS failsafe_tb,
    ROUND((STORAGE_BYTES + STAGE_BYTES + FAILSAFE_BYTES)
          / POWER(1024, 4) * 23.00, 2)             AS est_storage_cost_usd
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY USAGE_DATE DESC;

-- Cloud services layer credits (usually free if < 10% of compute)
SELECT
    DATE_TRUNC('day', start_time)                   AS usage_date,
    SUM(credits_used)                               AS compute_credits,
    SUM(credits_used_cloud_services)                AS cloud_svc_credits,
    ROUND(SUM(credits_used_cloud_services) /
          NULLIF(SUM(credits_used), 0) * 100, 1)   AS cloud_svc_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_DATE())
GROUP BY usage_date
ORDER BY usage_date DESC;

-- Top 10 most expensive queries this month
SELECT
    query_id,
    warehouse_name,
    user_name,
    ROUND(total_elapsed_time / 1000, 1)             AS elapsed_secs,
    ROUND(credits_used_cloud_services, 4)           AS cloud_credits,
    query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATE_TRUNC('month', CURRENT_DATE())
ORDER BY total_elapsed_time DESC
LIMIT 10;
```

**Result:** The billing analysis revealed that 65% of monthly credits were consumed by the ETL warehouse (expected), but 20% came from the analyst warehouse running after-hours queries with no auto-suspend — an easy fix worth $2,400/month. Storage costs were 12% of the total bill, with failsafe consuming 30% of storage charges for tables that did not need 7-day failsafe (transient tables were recommended). Cloud services credits stayed under 8% of compute, so they were fully covered by the 10% adjustment credit. The monthly forecast model used 30-day trailing averages by warehouse, projecting $28,000/month total Snowflake spend with a +/-5% confidence interval.

**AI Vision:** An AI cost anomaly detector could continuously monitor credit consumption in real-time, comparing actual usage against the forecast model and immediately alerting when a warehouse burns credits at 3x the expected rate — catching runaway queries, accidental cartesian joins, or misconfigured tasks before they generate a surprise invoice, and automatically suspending offending warehouses if costs exceed a dynamic threshold.

---

[Back to Q&A Index](README.md)
