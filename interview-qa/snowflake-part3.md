# Advanced Snowflake - Q&A (Part 3: Performance and Optimization)

[Back to Index](README.md)

---

### Q21. How did you use Search Optimization Service to accelerate point-lookups on loan-level data by CUSIP and loan number?

**Situation:** Our mortgage surveillance platform housed 2.8 billion loan-level records in a `LOAN_PERFORMANCE` table partitioned by reporting period. Analysts and downstream APIs frequently ran point-lookups by `CUSIP_ID` and `LOAN_NUMBER` to retrieve individual loan positions for Fannie Mae and Freddie Mac MBS pools. These queries averaged 8–12 seconds because they scanned hundreds of micro-partitions despite clustering on `REPORTING_PERIOD`.

**Task:** Reduce point-lookup latency to sub-second for the API layer feeding our real-time loan inquiry dashboard used by traders and risk analysts, without re-clustering the entire table on different keys.

**Action:** I enabled Search Optimization Service on the specific columns used for lookups:
```sql
ALTER TABLE MORTGAGE_DW.LOAN_PERFORMANCE
  ADD SEARCH OPTIMIZATION ON EQUALITY(CUSIP_ID, LOAN_NUMBER);

-- Verified the search optimization build progress
SELECT * FROM TABLE(INFORMATION_SCHEMA.SEARCH_OPTIMIZATION_HISTORY(
  DATE_RANGE_START => DATEADD('hour', -4, CURRENT_TIMESTAMP()),
  TABLE_NAME => 'MORTGAGE_DW.LOAN_PERFORMANCE'
));

-- Typical point-lookup query that now leverages the search access path
SELECT LOAN_NUMBER, CUSIP_ID, CURRENT_UPB, DELINQUENCY_STATUS,
       LOAN_AGE, REMAINING_MONTHS, CREDIT_SCORE
FROM MORTGAGE_DW.LOAN_PERFORMANCE
WHERE CUSIP_ID = 'FN AB1234' AND LOAN_NUMBER = '0012345678'
ORDER BY REPORTING_PERIOD DESC LIMIT 1;
```
I also added `SUBSTRING` and `GEO` search optimization on the `PROPERTY_ZIP` column for regional analytics queries. I monitored the incremental storage cost (~12% overhead) against the compute savings and confirmed the ROI within the first week.

**Result:** Point-lookup queries dropped from 8–12 seconds to 200–400 milliseconds — a 30x improvement. The API p99 latency fell below the 1-second SLA. Warehouse compute costs for the lookup workload dropped 60% because queries pruned 99.7% of micro-partitions. Analysts reported the loan inquiry dashboard felt "instantaneous."

**AI Vision:** An ML-based query routing layer could automatically decide whether to enable or disable Search Optimization on specific columns by analyzing query log patterns — identifying columns with high point-lookup frequency and low scan-ratio, then recommending SOS enablement with projected cost-benefit analysis.

---

### Q22. Describe your approach to using Materialized Views for pre-aggregating MBS pool-level metrics from loan-level data.

**Situation:** Our secondary market analytics team ran the same pool-level aggregations hundreds of times daily — computing weighted-average coupon (WAC), weighted-average maturity (WAM), total UPB, delinquency buckets, and CPR/CDR rates from a 3.2-billion-row loan-level table. Each full aggregation took 4–6 minutes on an XL warehouse, and the results rarely changed between the hourly data loads from Fannie Mae and Freddie Mac.

**Task:** Eliminate redundant compute by pre-materializing pool-level summaries while ensuring they stayed consistent with the underlying loan data after each load cycle.

**Action:** I created materialized views for the most frequently requested aggregations:
```sql
CREATE MATERIALIZED VIEW MORTGAGE_DW.MV_POOL_SUMMARY AS
SELECT
    CUSIP_ID,
    REPORTING_PERIOD,
    COUNT(*)                                          AS LOAN_COUNT,
    SUM(CURRENT_UPB)                                  AS TOTAL_UPB,
    SUM(CURRENT_UPB * INTEREST_RATE) / NULLIF(SUM(CURRENT_UPB), 0) AS WAC,
    SUM(CURRENT_UPB * REMAINING_MONTHS) / NULLIF(SUM(CURRENT_UPB), 0) AS WAM,
    SUM(CASE WHEN DELINQUENCY_STATUS = '0' THEN CURRENT_UPB ELSE 0 END)
        / NULLIF(SUM(CURRENT_UPB), 0)                AS CURRENT_PCT,
    SUM(CASE WHEN DELINQUENCY_STATUS IN ('3','4','5','6') THEN CURRENT_UPB ELSE 0 END)
        / NULLIF(SUM(CURRENT_UPB), 0)                AS SERIOUS_DQ_PCT
FROM MORTGAGE_DW.LOAN_PERFORMANCE
GROUP BY CUSIP_ID, REPORTING_PERIOD;
```
I ensured the base table's clustering key on `(REPORTING_PERIOD, CUSIP_ID)` aligned with the MV's GROUP BY for optimal incremental maintenance. I also set up a monitoring query against `MATERIALIZED_VIEW_REFRESH_HISTORY` to track refresh costs and lag.

**Result:** Downstream pool-level queries that previously took 4–6 minutes now returned in 2–5 seconds — over a 100x speedup. Monthly compute costs for the analytics workload decreased by $18K. The MV incremental refresh cost was only $1.2K/month. Analysts could build interactive dashboards on pool summaries without warehouse contention.

**AI Vision:** A recommendation engine could analyze aggregation query patterns across the organization and automatically propose materialized view definitions that maximize compute savings relative to maintenance cost — essentially an auto-MV advisor tuned to mortgage data access patterns.

---

### Q23. How would you diagnose and fix a query that's scanning too many micro-partitions despite having clustering keys?

**Situation:** A critical Ginnie Mae loan performance query was clustered on `(ISSUER_ID, REPORTING_PERIOD)`, yet the Query Profile showed it scanning 85% of micro-partitions (420K out of 495K). The query filtered on `POOL_PREFIX`, `REPORTING_PERIOD`, and `DELINQUENCY_STATUS` — only one of which matched the clustering key. The query powered a daily delinquency report for government loan servicers and had regressed from 45 seconds to 12 minutes after data volume doubled.

**Task:** Diagnose why clustering wasn't providing adequate pruning and implement a solution to restore query performance to under 60 seconds.

**Action:** I ran a systematic diagnosis:
```sql
-- Step 1: Check clustering quality
SELECT SYSTEM$CLUSTERING_INFORMATION('MORTGAGE_DW.GNMA_LOAN_PERF',
  '(ISSUER_ID, REPORTING_PERIOD)');
-- Result: average_depth = 12.4, overlap = 78% — poor clustering effectiveness

-- Step 2: Analyze the actual query filter columns vs clustering key
-- The query filtered on POOL_PREFIX + REPORTING_PERIOD, but POOL_PREFIX was NOT in the cluster key

-- Step 3: Check cardinality alignment
SELECT COUNT(DISTINCT ISSUER_ID), COUNT(DISTINCT POOL_PREFIX),
       COUNT(DISTINCT REPORTING_PERIOD)
FROM MORTGAGE_DW.GNMA_LOAN_PERF;
-- ISSUER_ID: 340, POOL_PREFIX: 8, REPORTING_PERIOD: 240

-- Step 4: Recluster to match dominant query patterns
ALTER TABLE MORTGAGE_DW.GNMA_LOAN_PERF
  CLUSTER BY (REPORTING_PERIOD, POOL_PREFIX, ISSUER_ID);
-- Low-cardinality columns first for maximum pruning

-- Step 5: Force initial recluster and monitor
ALTER TABLE MORTGAGE_DW.GNMA_LOAN_PERF RESUME RECLUSTER;

SELECT SYSTEM$CLUSTERING_INFORMATION('MORTGAGE_DW.GNMA_LOAN_PERF',
  '(REPORTING_PERIOD, POOL_PREFIX, ISSUER_ID)');
-- After recluster: average_depth = 1.8, overlap = 6%
```
I also added a secondary approach using Search Optimization on `DELINQUENCY_STATUS` for the status-filtered queries, since that column had only 10 distinct values but appeared in WHERE clauses frequently.

**Result:** Micro-partition scanning dropped from 85% to 3.2%. The query execution time went from 12 minutes to 28 seconds. Recluster credits consumed were a one-time 1,200 credits, with ongoing maintenance at ~80 credits/month. The delinquency report SLA was restored with headroom.

**AI Vision:** An ML model trained on query logs and micro-partition metadata could continuously recommend optimal clustering key combinations — running simulated pruning ratios on historical query patterns and suggesting recluster operations only when the predicted improvement exceeds a cost threshold.

---

### Q24. Explain your strategy for leveraging result set caching to reduce costs on repetitive mortgage reporting queries.

**Situation:** Our mortgage reporting suite generated 200+ standardized reports daily for Fannie Mae and Freddie Mac loan performance — waterfall reports, delinquency transition matrices, and prepayment summaries. Many reports ran identical SQL because multiple users and scheduled jobs triggered the same queries within a 24-hour window. We were spending $35K/month in compute on what was effectively redundant work.

**Task:** Maximize result set cache hit rates to eliminate redundant compute while ensuring reports always reflected the latest data after each load cycle.

**Action:** I implemented a multi-layered caching strategy:
```sql
-- Ensure result caching is enabled at account and session level
ALTER ACCOUNT SET USE_CACHED_RESULT = TRUE;

-- Standardize report queries to maximize cache hits by:
-- 1. Using deterministic SQL (no CURRENT_TIMESTAMP(), UUID, etc. in SELECT)
-- 2. Parameterizing with fixed reporting_period rather than relative dates

-- BAD: Cache-busting pattern (every execution generates a new query hash)
SELECT *, CURRENT_TIMESTAMP() AS run_time FROM LOAN_SUMMARY WHERE period >= DATEADD('month', -3, CURRENT_DATE());

-- GOOD: Cache-friendly pattern (identical SQL text = cache hit)
SELECT CUSIP_ID, TOTAL_UPB, WAC, WAM, DQ_30, DQ_60, DQ_90
FROM MORTGAGE_DW.POOL_SUMMARY_RPT
WHERE REPORTING_PERIOD BETWEEN '2025-10-01' AND '2026-01-01';

-- Structured the ETL to signal cache invalidation naturally:
-- Data loads insert into the base table, which invalidates dependent caches
-- Reports scheduled 30 min AFTER load completion to allow one "warm" query to populate cache

-- Monitor cache effectiveness
SELECT QUERY_ID, QUERY_TEXT, WAREHOUSE_NAME,
       BYTES_SCANNED, PARTITIONS_SCANNED,
       CASE WHEN BYTES_SCANNED = 0 THEN 'CACHE_HIT' ELSE 'CACHE_MISS' END AS CACHE_STATUS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TYPE = 'SELECT' AND START_TIME > DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC;
```
I also introduced a "cache warmer" task that ran key report queries once after each data load, ensuring all subsequent users received cached results.

**Result:** Cache hit rate rose from 12% to 68% on reporting queries. Monthly warehouse compute costs for the reporting workload dropped from $35K to $14K — a 60% savings. Report delivery latency for cached queries dropped to under 1 second regardless of complexity. No accuracy compromises since cache invalidates automatically on underlying data changes.

**AI Vision:** A predictive caching system could use ML to forecast which queries will be requested in the next time window based on historical patterns, proactively warming the cache before users even submit requests — especially valuable during month-end mortgage reporting cycles.

---

### Q25. How did you tune warehouse sizing for a complex prepayment model calculation that processes 500M+ loan-months?

**Situation:** Our quantitative analytics team ran monthly CPR/CDR/severity calculations using a Snowflake stored procedure that processed 540 million loan-month records across Fannie Mae, Freddie Mac, and Ginnie Mae portfolios. The model computed single-month mortality (SMM), conditional prepayment rates, and voluntary/involuntary separation using Intex cashflow assumptions. On a 2XL warehouse, it took 3.5 hours and cost ~$840 per run. Business wanted it under 1 hour for same-day risk reporting.

**Task:** Right-size the warehouse and optimize the computation to achieve sub-60-minute execution while minimizing cost per run.

**Action:** I ran a systematic sizing experiment and restructured the computation:
```sql
-- Step 1: Profile the workload on different warehouse sizes
-- Tested XL, 2XL, 3XL, 4XL with identical query on a sample month

-- Results:
-- XL:  210 min, $252  | 2XL: 115 min, $276  | 3XL: 58 min, $348  | 4XL: 42 min, $504

-- Step 2: The query wasn't scaling linearly — identified a serialization bottleneck
-- Query Profile showed a single-threaded ORDER BY feeding into a window function

-- Step 3: Restructured to eliminate the serial bottleneck
CREATE OR REPLACE TABLE MORTGAGE_DW.PREPAY_METRICS AS
WITH loan_transitions AS (
    SELECT LOAN_NUMBER, REPORTING_PERIOD, CUSIP_ID, CURRENT_UPB,
           LAG(CURRENT_UPB) OVER (PARTITION BY LOAN_NUMBER ORDER BY REPORTING_PERIOD) AS PREV_UPB,
           LAG(ZERO_BALANCE_CODE) OVER (PARTITION BY LOAN_NUMBER ORDER BY REPORTING_PERIOD) AS PREV_ZB
    FROM MORTGAGE_DW.LOAN_PERFORMANCE
    WHERE REPORTING_PERIOD BETWEEN '2025-01-01' AND '2026-01-01'
),
smm_calc AS (
    SELECT CUSIP_ID, REPORTING_PERIOD,
           SUM(CASE WHEN PREV_UPB > 0 AND CURRENT_UPB = 0 AND PREV_ZB = '01'
                    THEN PREV_UPB ELSE 0 END) AS VOLUNTARY_PREPAY,
           SUM(PREV_UPB) AS BEGINNING_BALANCE
    FROM loan_transitions
    GROUP BY CUSIP_ID, REPORTING_PERIOD
)
SELECT CUSIP_ID, REPORTING_PERIOD,
       VOLUNTARY_PREPAY / NULLIF(BEGINNING_BALANCE, 0) AS SMM,
       1 - POWER(1 - VOLUNTARY_PREPAY / NULLIF(BEGINNING_BALANCE, 0), 12) AS CPR
FROM smm_calc;

-- Step 4: After restructuring, retested — 3XL now completed in 38 min
-- Settled on 2XL which completed in 52 min at $208/run

-- Step 5: Auto-suspend to avoid idle costs
ALTER WAREHOUSE PREPAY_COMPUTE SET AUTO_SUSPEND = 60 AUTO_RESUME = TRUE;
```

**Result:** Execution time dropped from 3.5 hours to 52 minutes on a 2XL warehouse — meeting the sub-60-minute SLA. Cost per run decreased from $840 to $208 (75% reduction). The restructured SQL also improved parallelism, achieving near-linear scaling across nodes. The quant team could now run intra-month scenario analyses that were previously cost-prohibitive.

**AI Vision:** An auto-tuning system could use reinforcement learning to dynamically select warehouse size per query stage — spinning up a 4XL for the partition-parallel scan phase and scaling down to XL for the final aggregation, optimizing the cost-performance Pareto frontier automatically.

---

### Q26. Describe how you used Query Profile to identify and resolve a 10x performance regression in a loan aggregation pipeline.

**Situation:** Our nightly Freddie Mac loan aggregation pipeline — which computed pool-level statistics across 1.6 billion rows — suddenly regressed from 18 minutes to over 3 hours. No code changes had been deployed. The pipeline fed downstream risk models and the delay was cascading into morning trading desk reports. The on-call team escalated to me at 2 AM.

**Task:** Identify the root cause of the 10x regression and restore pipeline performance before the 6 AM trading desk deadline.

**Action:** I used the Query Profile to perform a systematic investigation:
```sql
-- Step 1: Pull the slow query ID from history
SELECT QUERY_ID, TOTAL_ELAPSED_TIME, BYTES_SCANNED, PARTITIONS_SCANNED, PARTITIONS_TOTAL
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TEXT ILIKE '%FREDDIE_POOL_AGG%'
ORDER BY START_TIME DESC LIMIT 5;

-- Compared last night vs previous night:
-- Previous: PARTITIONS_SCANNED = 42K / 1.2M (3.5% scan ratio)
-- Last night: PARTITIONS_SCANNED = 1.1M / 1.2M (91.7% scan ratio) <-- FULL SCAN

-- Step 2: In Query Profile UI, identified the TableScan node showing:
-- "Pruning was not possible" on the LOAN_PERFORMANCE_FREDDIE table

-- Step 3: Checked clustering health
SELECT SYSTEM$CLUSTERING_INFORMATION('MORTGAGE_DW.LOAN_PERFORMANCE_FREDDIE',
  '(REPORTING_PERIOD, SELLER_NAME)');
-- average_overlap: 342.7 (was 2.1 last week) — clustering had degraded catastrophically

-- Step 4: Root cause — a backfill job had bulk-loaded 18 months of corrected data
-- out of natural clustering order, destroying micro-partition alignment

-- Step 5: Immediate fix — force recluster
ALTER TABLE MORTGAGE_DW.LOAN_PERFORMANCE_FREDDIE RESUME RECLUSTER;

-- Step 6: While recluster ran, used a temp workaround for the urgent pipeline
-- Added explicit micro-partition hints via time-bounded filtering
SELECT /*+ USE_CLUSTERING_KEYS */ ...
FROM MORTGAGE_DW.LOAN_PERFORMANCE_FREDDIE
WHERE REPORTING_PERIOD >= '2025-12-01'  -- narrowed the scan window
  AND _METADATA$PARTITION_KEY IS NOT NULL;  -- force pruning path
```
I also found a secondary issue in the Query Profile: a hash join spilling to disk (8GB spillage) due to a Cartesian-like join condition caused by a missing predicate after a recent schema change in a reference table.

**Result:** The missing join predicate fix alone brought the query from 3 hours to 35 minutes. After reclustering completed (4 hours later), performance returned to 16 minutes — even better than the original 18 minutes. I added a clustering health monitor that alerts when `average_overlap` exceeds a threshold of 10, preventing future silent regressions. The trading desk received reports by 5:45 AM.

**AI Vision:** An anomaly detection model monitoring query execution metrics (scan ratio, spill bytes, elapsed time) could automatically flag performance regressions within minutes of occurrence and correlate them with recent data operations — providing instant root-cause hypotheses before a human even investigates.

---

### Q27. How would you implement query tagging and monitoring to attribute compute costs to specific mortgage analytics projects?

**Situation:** Our Snowflake account served 14 teams across mortgage origination analytics, servicing surveillance, capital markets trading, and regulatory reporting. The monthly bill was $280K but finance had zero visibility into which project consumed what. Chargebacks were allocated by headcount — grossly unfair since the quant team's prepayment models consumed 40% of compute while representing 8% of headcount.

**Task:** Implement granular cost attribution by project, team, and workload type so finance could allocate Snowflake costs accurately and teams could optimize their own spend.

**Action:** I built a comprehensive tagging and monitoring framework:
```sql
-- Step 1: Enforce query tagging via session parameters
-- Each application/service sets tags at session start
ALTER SESSION SET QUERY_TAG = '{"team":"capital_markets","project":"prepay_model","env":"prod"}';

-- Step 2: For dbt and scheduled jobs, set tags in the orchestration layer
-- dbt_project.yml: query_tag: '{"team":"servicing","project":"dq_transition","env":"prod"}'

-- Step 3: Create a cost attribution view
CREATE OR REPLACE VIEW FINANCE.COST_ATTRIBUTION AS
WITH tagged_queries AS (
    SELECT
        QUERY_ID, WAREHOUSE_NAME, WAREHOUSE_SIZE,
        TOTAL_ELAPSED_TIME, CREDITS_USED_CLOUD_SERVICES,
        TRY_PARSE_JSON(QUERY_TAG) AS TAG,
        EXECUTION_TIME / 1000 / 3600 AS EXEC_HOURS
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE START_TIME > DATEADD('month', -1, CURRENT_TIMESTAMP())
      AND QUERY_TAG IS NOT NULL AND QUERY_TAG != ''
)
SELECT
    TAG:team::STRING AS TEAM,
    TAG:project::STRING AS PROJECT,
    WAREHOUSE_NAME,
    COUNT(*) AS QUERY_COUNT,
    ROUND(SUM(EXEC_HOURS) *
      CASE WAREHOUSE_SIZE
        WHEN 'X-Small' THEN 1 WHEN 'Small' THEN 2 WHEN 'Medium' THEN 4
        WHEN 'Large' THEN 8 WHEN 'X-Large' THEN 16 WHEN '2X-Large' THEN 32
      END, 2) AS ESTIMATED_CREDITS,
    ROUND(ESTIMATED_CREDITS * 3.50, 2) AS ESTIMATED_COST_USD
FROM tagged_queries
GROUP BY 1, 2, 3
ORDER BY ESTIMATED_COST_USD DESC;

-- Step 4: Resource monitor guardrails per team
CREATE RESOURCE MONITOR CAPITAL_MARKETS_MONITOR
  WITH CREDIT_QUOTA = 8000
  TRIGGERS ON 75 PERCENT DO NOTIFY
           ON 90 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND;
```

**Result:** Within the first month, we identified that the prepay model team consumed 38% of total spend ($106K) while the regulatory reporting team — previously charged equally — used only 7% ($19.6K). Cost allocation shifted to usage-based chargebacks. Teams self-optimized: the prepay team restructured their model runs and reduced their spend by 25% once they saw the actual costs. Overall monthly spend dropped from $280K to $215K purely through visibility-driven behavior change.

**AI Vision:** An ML-powered cost forecasting model could predict monthly spend per project based on historical patterns and planned workload changes, alerting teams proactively when they are trending toward budget overruns — and recommending specific optimization actions ranked by impact.

---

### Q28. Explain your approach to optimizing JOIN performance between large loan-level and property-level tables (billions of rows).

**Situation:** A critical pipeline joined the Fannie Mae `LOAN_PERFORMANCE` table (2.4B rows, clustered on `REPORTING_PERIOD`) with a CoreLogic `PROPERTY_ATTRIBUTES` table (850M rows, clustered on `FIPS_CODE`) on `PROPERTY_ZIP` and `LOAN_NUMBER`. The join took 48 minutes on a 3XL warehouse, with the Query Profile showing 120GB of hash join spill to remote storage. This pipeline powered daily LTV recalculations using updated property valuations.

**Task:** Reduce the join execution time to under 10 minutes while eliminating disk spillage, without restructuring upstream data feeds.

**Action:** I applied a multi-pronged join optimization strategy:
```sql
-- Step 1: Analyze join key distribution
SELECT APPROX_COUNT_DISTINCT(LOAN_NUMBER) AS loan_card,
       APPROX_COUNT_DISTINCT(PROPERTY_ZIP) AS zip_card
FROM MORTGAGE_DW.LOAN_PERFORMANCE;
-- loan_card: 58M, zip_card: 42K

-- Step 2: Co-cluster both tables on join keys to enable co-located pruning
ALTER TABLE MORTGAGE_DW.LOAN_PERFORMANCE CLUSTER BY (REPORTING_PERIOD, LOAN_NUMBER);
ALTER TABLE MORTGAGE_DW.PROPERTY_ATTRIBUTES CLUSTER BY (LOAN_NUMBER);

-- Step 3: Reduce the dataset before joining (predicate pushdown)
-- BEFORE (naive join — scans all history then filters):
SELECT l.*, p.AVM_VALUE, p.PROPERTY_TYPE
FROM LOAN_PERFORMANCE l JOIN PROPERTY_ATTRIBUTES p ON l.LOAN_NUMBER = p.LOAN_NUMBER
WHERE l.REPORTING_PERIOD = '2026-01-01';

-- AFTER (CTE pre-filters, optimizer pushes predicates into scan):
WITH active_loans AS (
    SELECT LOAN_NUMBER, CURRENT_UPB, INTEREST_RATE, ORIGINAL_LTV
    FROM MORTGAGE_DW.LOAN_PERFORMANCE
    WHERE REPORTING_PERIOD = '2026-01-01'
      AND CURRENT_UPB > 0  -- exclude liquidated loans, reduces to ~35M rows
),
current_props AS (
    SELECT LOAN_NUMBER, AVM_VALUE, PROPERTY_TYPE, VALUATION_DATE
    FROM MORTGAGE_DW.PROPERTY_ATTRIBUTES
    WHERE VALUATION_DATE >= '2025-10-01'  -- only recent valuations
)
SELECT a.LOAN_NUMBER, a.CURRENT_UPB,
       a.CURRENT_UPB / NULLIF(p.AVM_VALUE, 0) AS CURRENT_LTV,
       p.PROPERTY_TYPE
FROM active_loans a
JOIN current_props p ON a.LOAN_NUMBER = p.LOAN_NUMBER;

-- Step 4: Set join optimization hint for large-to-small pattern
ALTER SESSION SET USE_HASH_JOIN_OPTIMIZATION = TRUE;
```

**Result:** Join execution dropped from 48 minutes to 7 minutes. Hash join spill was eliminated entirely — the Query Profile showed 0 bytes spilled to either local or remote storage. The co-clustering on `LOAN_NUMBER` improved join pruning so that both sides of the join scanned only the relevant micro-partitions. LTV recalculations now completed within the morning processing window, and the 3XL warehouse was downsized to XL for this workload, saving $12K/month.

**AI Vision:** A join advisor powered by ML could analyze table statistics, query patterns, and micro-partition metadata to automatically recommend co-clustering strategies, join reordering, and pre-filter predicates — essentially an intelligent query rewrite engine specialized for multi-table mortgage analytics.

---

### Q29. How did you use QUALIFY and window functions to efficiently deduplicate loan records from multiple data sources?

**Situation:** We ingested loan-level data from three sources: Fannie Mae monthly files, Freddie Mac's SFLP dataset, and our internal servicing system. Due to bulk corrections, retroactive adjustments, and overlapping reporting windows, the staging table contained 45 million duplicate loan-month records — the same `LOAN_NUMBER` + `REPORTING_PERIOD` combination appeared up to 4 times with different `LOAD_TIMESTAMP` and correction flags. Downstream models were double-counting UPB, inflating portfolio metrics by 12%.

**Task:** Implement a deterministic, performant deduplication strategy that always selects the most authoritative and most recent version of each loan-month record.

**Action:** I used `QUALIFY` with a priority-weighted window function:
```sql
-- Deduplication with source priority and recency ranking
CREATE OR REPLACE TABLE MORTGAGE_DW.LOAN_PERFORMANCE_DEDUPED AS
SELECT *
FROM MORTGAGE_DW.LOAN_PERFORMANCE_STAGING
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY LOAN_NUMBER, REPORTING_PERIOD
    ORDER BY
        -- Priority 1: Source authority (GSE files override internal)
        CASE DATA_SOURCE
            WHEN 'FANNIE_MONTHLY'  THEN 1
            WHEN 'FREDDIE_SFLP'   THEN 1
            WHEN 'INTERNAL_SVCR'  THEN 2
        END ASC,
        -- Priority 2: Correction flag (corrections override originals)
        CASE WHEN CORRECTION_FLAG = 'Y' THEN 0 ELSE 1 END ASC,
        -- Priority 3: Most recent load wins
        LOAD_TIMESTAMP DESC
) = 1;

-- Verify dedup results
SELECT 'BEFORE' AS STAGE, COUNT(*) AS ROWS, COUNT(DISTINCT LOAN_NUMBER || REPORTING_PERIOD) AS UNIQUE_KEYS
FROM MORTGAGE_DW.LOAN_PERFORMANCE_STAGING
UNION ALL
SELECT 'AFTER', COUNT(*), COUNT(DISTINCT LOAN_NUMBER || REPORTING_PERIOD)
FROM MORTGAGE_DW.LOAN_PERFORMANCE_DEDUPED;
-- BEFORE: 45M rows, 32M unique keys
-- AFTER:  32M rows, 32M unique keys — zero duplicates

-- For ongoing incremental dedup in the pipeline using MERGE:
MERGE INTO MORTGAGE_DW.LOAN_PERFORMANCE_FINAL AS tgt
USING (
    SELECT * FROM MORTGAGE_DW.LOAN_PERFORMANCE_STAGING
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY LOAN_NUMBER, REPORTING_PERIOD
        ORDER BY CASE DATA_SOURCE WHEN 'FANNIE_MONTHLY' THEN 1 WHEN 'FREDDIE_SFLP' THEN 1 ELSE 2 END,
                 CORRECTION_FLAG DESC, LOAD_TIMESTAMP DESC
    ) = 1
) AS src
ON tgt.LOAN_NUMBER = src.LOAN_NUMBER AND tgt.REPORTING_PERIOD = src.REPORTING_PERIOD
WHEN MATCHED AND src.LOAD_TIMESTAMP > tgt.LOAD_TIMESTAMP THEN UPDATE SET *
WHEN NOT MATCHED THEN INSERT VALUES (src.*);
```

**Result:** Deduplication of 45M rows completed in 90 seconds on a Large warehouse — compared to the previous approach using a self-join + GROUP BY that took 25 minutes. The `QUALIFY` clause eliminated an intermediate subquery and reduced memory consumption by 60%. Portfolio UPB accuracy was restored — the 12% inflation was eliminated. The MERGE-based incremental approach kept the production table deduplicated in real-time with each load cycle.

**AI Vision:** An ML-based entity resolution model could handle fuzzy deduplication — cases where `LOAN_NUMBER` formatting differs between sources (leading zeros, dashes, prefixes) or where property addresses have minor variations — using learned similarity functions rather than exact key matching.

---

### Q30. Describe your strategy for managing Time Travel and storage costs on frequently updated loan performance tables.

**Situation:** Our Snowflake environment stored 48 loan performance tables that were updated daily via MERGE operations — each update touching 5–15% of rows across Fannie Mae, Freddie Mac, and Ginnie Mae datasets. With the default 1-day Time Travel retention and 7-day Fail-safe, we were consuming 380TB of total storage at $23/TB/month ($8,740/month). The Time Travel overhead alone was 2.8x the active data size because every daily MERGE generated a full set of before-images for modified micro-partitions.

**Task:** Reduce storage costs by 50%+ while maintaining adequate Time Travel coverage for operational recovery and audit requirements.

**Action:** I implemented a tiered retention strategy aligned with data criticality:
```sql
-- Tier 1: Production tables with daily updates — minimize TT overhead
-- These tables have hourly backups to a separate BACKUP schema, so 1-day TT is sufficient
ALTER TABLE MORTGAGE_DW.LOAN_PERF_FANNIE SET DATA_RETENTION_TIME_IN_DAYS = 1;
ALTER TABLE MORTGAGE_DW.LOAN_PERF_FREDDIE SET DATA_RETENTION_TIME_IN_DAYS = 1;
ALTER TABLE MORTGAGE_DW.LOAN_PERF_GINNIE SET DATA_RETENTION_TIME_IN_DAYS = 1;

-- Tier 2: Aggregated/reporting tables — no TT needed (can be rebuilt)
ALTER TABLE MORTGAGE_DW.POOL_SUMMARY_RPT SET DATA_RETENTION_TIME_IN_DAYS = 0;
ALTER TABLE MORTGAGE_DW.DQ_TRANSITION_MATRIX SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- Tier 3: Compliance/audit tables — full 90-day retention
ALTER TABLE MORTGAGE_DW.REGULATORY_SUBMISSIONS SET DATA_RETENTION_TIME_IN_DAYS = 90;

-- Restructured the MERGE to minimize micro-partition churn:
-- BEFORE: Full table MERGE touching every partition
-- AFTER: Partition-aware MERGE that only processes changed reporting periods
MERGE INTO MORTGAGE_DW.LOAN_PERF_FANNIE AS tgt
USING MORTGAGE_DW.LOAN_PERF_FANNIE_STG AS src
ON tgt.LOAN_NUMBER = src.LOAN_NUMBER
   AND tgt.REPORTING_PERIOD = src.REPORTING_PERIOD
   AND tgt.REPORTING_PERIOD >= DATEADD('month', -2, CURRENT_DATE())  -- limit scope
WHEN MATCHED AND (tgt.CURRENT_UPB != src.CURRENT_UPB
               OR tgt.DELINQUENCY_STATUS != src.DELINQUENCY_STATUS)
    THEN UPDATE SET
        tgt.CURRENT_UPB = src.CURRENT_UPB,
        tgt.DELINQUENCY_STATUS = src.DELINQUENCY_STATUS,
        tgt.LOAD_TIMESTAMP = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT VALUES (src.*);

-- Monitor storage breakdown
SELECT TABLE_NAME,
       ACTIVE_BYTES / POWER(1024,4) AS ACTIVE_TB,
       TIME_TRAVEL_BYTES / POWER(1024,4) AS TT_TB,
       FAILSAFE_BYTES / POWER(1024,4) AS FS_TB,
       (TIME_TRAVEL_BYTES + FAILSAFE_BYTES) / NULLIF(ACTIVE_BYTES, 0) AS OVERHEAD_RATIO
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG = 'MORTGAGE_DW'
  AND ACTIVE_BYTES > 0
ORDER BY (TIME_TRAVEL_BYTES + FAILSAFE_BYTES) DESC
LIMIT 20;

-- Transient tables for intermediate/staging data (no Fail-safe)
CREATE TRANSIENT TABLE MORTGAGE_DW.LOAN_PERF_STAGING (...)
  DATA_RETENTION_TIME_IN_DAYS = 0;
```

**Result:** Total storage dropped from 380TB to 155TB — a 59% reduction. Monthly storage costs decreased from $8,740 to $3,565, saving $62K annually. The partition-aware MERGE reduced micro-partition rewrite volume by 70%, which further reduced Time Travel overhead. Compliance tables retained full 90-day audit trails as required by FHFA examination standards. The transient staging tables alone saved 45TB of Fail-safe storage.

**AI Vision:** A storage optimization agent could continuously monitor table-level storage metrics and update patterns, automatically recommending retention tier changes when usage patterns shift — for example, detecting that a table has moved from daily updates to weekly updates and suggesting increased Time Travel retention since the overhead cost would be lower.

---
