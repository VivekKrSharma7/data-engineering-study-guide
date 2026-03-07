# 48. Data Quality & Validation in Mortgage Data

[Back to Secondary Market Index](./README.md)

---

## Overview

Data quality is the backbone of every downstream process in the secondary mortgage market. Inaccurate or incomplete loan-level data can cascade into mispriced securities, incorrect investor reports, regulatory violations, and flawed risk models. A senior data engineer must design and maintain robust validation frameworks that catch issues early, enforce business rules, and provide transparent DQ scoring to stakeholders.

---

## Key Concepts

### 1. Common Data Quality Issues in Mortgage Data

Mortgage datasets — whether origination tapes, monthly performance files, or servicer remittance data — are plagued by recurring quality problems.

| Category | Examples |
|---|---|
| **Missing Values** | NULL FICO score, missing property valuation, blank servicer name, no origination date |
| **Invalid Dates** | Maturity date before origination date, future dates in historical fields, `1900-01-01` placeholders |
| **UPB Mismatches** | Scheduled UPB does not reconcile with prior month UPB minus principal paid minus losses plus curtailments |
| **Inconsistent Statuses** | Loan marked "current" but has 90+ days past due, loan marked "liquidated" but still reporting UPB > 0 |
| **Out-of-Range Values** | FICO score of 999 or 0, LTV > 200%, negative interest rate, coupon rate of 0 on a performing loan |
| **Duplicate Records** | Same loan ID appearing twice in a monthly tape with different attributes |
| **Referential Integrity Breaks** | Loan in performance file has no matching record in origination file; pool ID does not exist in the deal table |
| **Stale Data** | Servicer continues to report the same data month after month without updates |
| **Encoding / Format Issues** | State codes mixing 2-letter abbreviations with full names, date formats switching between `MM/DD/YYYY` and `YYYY-MM-DD` |

#### Real-World Example — Missing FICO

Freddie Mac's Single-Family Loan-Level Dataset uses a credit score of `9999` to indicate missing data. If your pipeline does not filter or flag these, average FICO calculations will be dramatically skewed upward, making pools appear less risky than they actually are.

```sql
-- Identify loans with missing or placeholder FICO scores
SELECT
    loan_id,
    credit_score,
    CASE
        WHEN credit_score IS NULL THEN 'NULL'
        WHEN credit_score IN (0, 9999) THEN 'PLACEHOLDER'
        WHEN credit_score < 300 OR credit_score > 850 THEN 'OUT_OF_RANGE'
        ELSE 'VALID'
    END AS fico_quality_flag
FROM loan_origination
WHERE credit_score IS NULL
   OR credit_score NOT BETWEEN 300 AND 850;
```

---

### 2. Validation Rules by Field Type

Organizing validation rules by data type ensures systematic coverage.

#### Numeric Fields

| Rule | Example |
|---|---|
| Non-null check | `UPB IS NOT NULL` |
| Range check | `interest_rate BETWEEN 0.01 AND 20.0` |
| Precision check | `UPB = ROUND(UPB, 2)` — no excess decimal places |
| Sign check | `UPB >= 0` |
| Reasonableness | `original_loan_amount BETWEEN 10000 AND 5000000` |

#### Date Fields

| Rule | Example |
|---|---|
| Non-null | `origination_date IS NOT NULL` |
| Valid calendar date | No February 30 or month 13 |
| Chronological order | `maturity_date > origination_date` |
| Reasonable range | `origination_date BETWEEN '1990-01-01' AND CURRENT_DATE` |
| Consistent with term | `DATEDIFF(MONTH, origination_date, maturity_date) = original_loan_term` |

#### Categorical / Code Fields

| Rule | Example |
|---|---|
| Allowed values | `property_type IN ('SF', 'CO', 'MH', 'PU', '2F', '3F', '4F')` |
| Consistency | If `occupancy_type = 'I'` (investor), then `property_type` should not be `'MH'` (manufactured housing) for most programs |
| Standard codes | State must be a valid 2-letter US postal code |

#### String Fields

| Rule | Example |
|---|---|
| Length check | `LEN(zip_code) IN (5, 9)` |
| Pattern check | ZIP code matches `^\d{5}(-\d{4})?$` |
| Trimmed whitespace | `servicer_name = LTRIM(RTRIM(servicer_name))` |

```sql
-- Comprehensive field-level validation example
SELECT
    loan_id,
    -- Numeric validations
    CASE WHEN original_upb IS NULL THEN 'FAIL'
         WHEN original_upb <= 0 THEN 'FAIL'
         WHEN original_upb > 5000000 THEN 'WARN'
         ELSE 'PASS' END AS upb_check,
    -- Date validations
    CASE WHEN origination_date IS NULL THEN 'FAIL'
         WHEN origination_date > GETDATE() THEN 'FAIL'
         WHEN maturity_date <= origination_date THEN 'FAIL'
         ELSE 'PASS' END AS date_check,
    -- Categorical validations
    CASE WHEN property_type NOT IN ('SF','CO','MH','PU','2F','3F','4F') THEN 'FAIL'
         ELSE 'PASS' END AS property_type_check,
    -- String validations
    CASE WHEN LEN(zip_code) NOT IN (5, 9) THEN 'FAIL'
         WHEN zip_code LIKE '%[^0-9]%' THEN 'FAIL'
         ELSE 'PASS' END AS zip_check
FROM loan_origination;
```

---

### 3. Referential Integrity Checks

In the secondary market, data spans multiple related entities: loans, pools, deals, servicers, and trustees. Referential integrity ensures these relationships are valid.

```sql
-- Loans in performance file that have no origination record
SELECT p.loan_id, p.reporting_period
FROM monthly_performance p
LEFT JOIN loan_origination o ON p.loan_id = o.loan_id
WHERE o.loan_id IS NULL;

-- Loans assigned to pools that do not exist in the deal table
SELECT lp.loan_id, lp.pool_id
FROM loan_pool_mapping lp
LEFT JOIN deal d ON lp.pool_id = d.pool_id
WHERE d.pool_id IS NULL;

-- Servicer codes in performance data not found in servicer master
SELECT DISTINCT p.servicer_id
FROM monthly_performance p
LEFT JOIN servicer_master s ON p.servicer_id = s.servicer_id
WHERE s.servicer_id IS NULL;
```

#### Cross-File Consistency

When loading GSE data (Fannie Mae, Freddie Mac), the origination file and performance file must be reconciled:

- Every `loan_id` in performance should exist in origination.
- `original_upb` in performance should match the origination record.
- `origination_date` should be consistent across both files.

---

### 4. Business Rule Validation

Business rules go beyond simple field checks — they enforce domain logic specific to mortgage servicing and securitization.

#### Key Business Rules

| Rule | SQL Logic |
|---|---|
| Foreclosure date must be after first delinquency date | `foreclosure_date > first_delinquency_date` |
| REO disposition date must be after foreclosure date | `disposition_date > foreclosure_date` |
| If loan status = 'Prepaid', then `current_upb` must be 0 | `WHEN loan_status = 'P' AND current_upb <> 0 THEN 'FAIL'` |
| If delinquency status = 0, then `days_delinquent` must be 0 | `WHEN delinquency_status = 0 AND days_delinquent > 0 THEN 'FAIL'` |
| Modification flag = 'Y' requires a modification date | `WHEN mod_flag = 'Y' AND mod_date IS NULL THEN 'FAIL'` |
| Interest rate after modification should differ from original | `WHEN mod_flag = 'Y' AND current_rate = original_rate THEN 'WARN'` |
| Curtailment cannot exceed current UPB | `WHEN curtailment_amount > current_upb THEN 'FAIL'` |
| Loan age must reconcile with origination date and reporting period | `DATEDIFF(MONTH, origination_date, reporting_period) = loan_age` |

```sql
-- Business rule validation: Foreclosure timeline integrity
SELECT
    loan_id,
    first_delinquency_date,
    foreclosure_date,
    disposition_date,
    CASE
        WHEN foreclosure_date IS NOT NULL
             AND first_delinquency_date IS NOT NULL
             AND foreclosure_date < first_delinquency_date
        THEN 'FAIL: FC before delinquency'

        WHEN disposition_date IS NOT NULL
             AND foreclosure_date IS NOT NULL
             AND disposition_date < foreclosure_date
        THEN 'FAIL: Disposition before FC'

        WHEN disposition_date IS NOT NULL
             AND foreclosure_date IS NULL
        THEN 'FAIL: Disposition without FC'

        ELSE 'PASS'
    END AS timeline_check
FROM monthly_performance
WHERE foreclosure_date IS NOT NULL
   OR disposition_date IS NOT NULL;
```

#### UPB Rollforward Validation

One of the most critical business validations — ensuring month-over-month UPB changes are explainable:

```sql
-- UPB rollforward reconciliation
WITH upb_changes AS (
    SELECT
        curr.loan_id,
        curr.reporting_period,
        prev.current_upb AS prior_upb,
        curr.current_upb,
        curr.scheduled_principal,
        curr.curtailment_amount,
        curr.loss_amount,
        curr.modification_upb_change,
        -- Expected UPB
        prev.current_upb
            - ISNULL(curr.scheduled_principal, 0)
            - ISNULL(curr.curtailment_amount, 0)
            - ISNULL(curr.loss_amount, 0)
            + ISNULL(curr.modification_upb_change, 0) AS expected_upb,
        -- Difference
        curr.current_upb - (
            prev.current_upb
            - ISNULL(curr.scheduled_principal, 0)
            - ISNULL(curr.curtailment_amount, 0)
            - ISNULL(curr.loss_amount, 0)
            + ISNULL(curr.modification_upb_change, 0)
        ) AS variance
    FROM monthly_performance curr
    JOIN monthly_performance prev
        ON curr.loan_id = prev.loan_id
        AND curr.reporting_period = DATEADD(MONTH, 1, prev.reporting_period)
)
SELECT *
FROM upb_changes
WHERE ABS(variance) > 0.01  -- tolerance threshold
ORDER BY ABS(variance) DESC;
```

---

### 5. Automated DQ Frameworks

A production-grade DQ framework automates discovery, validation, alerting, and reporting.

#### Framework Architecture

```
Source Data --> Ingestion --> DQ Engine --> DQ Results Store
                                |                |
                                v                v
                          Alert System     DQ Dashboard
                          (email/Slack)    (scoring & trends)
```

#### Components of a DQ Framework

1. **Rule Registry**: Central metadata table defining every validation rule, its severity, applicable fields, and thresholds.
2. **DQ Engine**: Executes rules against incoming data, produces pass/fail results.
3. **Results Store**: Persists every rule execution outcome for trend analysis.
4. **Alerting**: Triggers notifications when critical rules fail or DQ scores drop below thresholds.
5. **Quarantine**: Isolates records that fail critical validations so they do not pollute downstream analytics.

```sql
-- DQ Rule Registry table
CREATE TABLE dq_rule_registry (
    rule_id         INT IDENTITY(1,1) PRIMARY KEY,
    rule_name       VARCHAR(200) NOT NULL,
    rule_category   VARCHAR(50),   -- 'COMPLETENESS','VALIDITY','CONSISTENCY','TIMELINESS'
    target_table    VARCHAR(100),
    target_column   VARCHAR(100),
    rule_sql        NVARCHAR(MAX),
    severity        VARCHAR(10),   -- 'CRITICAL','HIGH','MEDIUM','LOW'
    threshold_pct   DECIMAL(5,2),  -- acceptable failure rate
    is_active       BIT DEFAULT 1,
    created_date    DATETIME DEFAULT GETDATE()
);

-- DQ Execution Results
CREATE TABLE dq_execution_results (
    execution_id    BIGINT IDENTITY(1,1) PRIMARY KEY,
    rule_id         INT REFERENCES dq_rule_registry(rule_id),
    run_date        DATE,
    reporting_period DATE,
    total_records   BIGINT,
    passed_records  BIGINT,
    failed_records  BIGINT,
    pass_rate_pct   DECIMAL(7,4),
    status          VARCHAR(10),   -- 'PASS','WARN','FAIL'
    execution_time_ms INT,
    sample_failures NVARCHAR(MAX)  -- JSON array of example failures
);

-- Insert a sample rule
INSERT INTO dq_rule_registry (rule_name, rule_category, target_table, target_column, rule_sql, severity, threshold_pct)
VALUES (
    'FICO score must be between 300 and 850',
    'VALIDITY',
    'loan_origination',
    'credit_score',
    'SELECT loan_id FROM loan_origination WHERE credit_score NOT BETWEEN 300 AND 850 OR credit_score IS NULL',
    'HIGH',
    2.00  -- allow up to 2% failure
);
```

#### Great Expectations (Python-Based DQ)

For teams using Python/PySpark, Great Expectations is a popular open-source framework:

```python
# Pseudocode — Great Expectations suite for mortgage data
import great_expectations as gx

context = gx.get_context()
suite = context.add_expectation_suite("mortgage_performance_suite")

# Completeness
suite.add_expectation(
    gx.expectations.ExpectColumnValuesToNotBeNull(column="loan_id")
)
# Validity
suite.add_expectation(
    gx.expectations.ExpectColumnValuesToBeBetween(
        column="credit_score", min_value=300, max_value=850
    )
)
# Uniqueness
suite.add_expectation(
    gx.expectations.ExpectCompoundColumnsToBeUnique(
        column_list=["loan_id", "reporting_period"]
    )
)
# Referential integrity
suite.add_expectation(
    gx.expectations.ExpectColumnValuesToBeInSet(
        column="property_state",
        value_set=["AL","AK","AZ",...,"WY"]  # all 50 states + DC + territories
    )
)
```

---

### 6. DQ Scoring & Reporting

#### DQ Score Calculation

A DQ score quantifies the overall quality of a dataset in a single metric, typically on a 0–100 scale.

```sql
-- Calculate weighted DQ score for a reporting period
WITH rule_results AS (
    SELECT
        r.rule_category,
        r.severity,
        e.pass_rate_pct,
        CASE r.severity
            WHEN 'CRITICAL' THEN 4.0
            WHEN 'HIGH'     THEN 3.0
            WHEN 'MEDIUM'   THEN 2.0
            WHEN 'LOW'      THEN 1.0
        END AS weight
    FROM dq_execution_results e
    JOIN dq_rule_registry r ON e.rule_id = r.rule_id
    WHERE e.reporting_period = '2026-02-01'
)
SELECT
    -- Overall weighted DQ score
    SUM(pass_rate_pct * weight) / SUM(weight) AS overall_dq_score,
    -- By category
    rule_category,
    AVG(pass_rate_pct) AS category_avg_pass_rate,
    MIN(pass_rate_pct) AS category_worst_rule
FROM rule_results
GROUP BY ROLLUP(rule_category);
```

#### DQ Trend Dashboard Metrics

| Metric | Description |
|---|---|
| **Overall DQ Score** | Weighted average pass rate across all rules |
| **Critical Failures** | Count of critical-severity rules that failed |
| **Trend (MoM)** | DQ score change vs. prior month |
| **Top Offenders** | Rules with the highest failure counts |
| **By Source** | DQ score broken down by servicer or data source |
| **Quarantine Volume** | Number of records held in quarantine |

---

### 7. Data Profiling

Data profiling is the process of examining source data to understand its structure, content, and quality before building validation rules.

#### Profiling Dimensions

```sql
-- Comprehensive column profiling query
SELECT
    'credit_score'               AS column_name,
    COUNT(*)                     AS total_rows,
    SUM(CASE WHEN credit_score IS NULL THEN 1 ELSE 0 END) AS null_count,
    CAST(SUM(CASE WHEN credit_score IS NULL THEN 1.0 ELSE 0.0 END)
         / COUNT(*) * 100 AS DECIMAL(5,2)) AS null_pct,
    COUNT(DISTINCT credit_score) AS distinct_count,
    MIN(credit_score)            AS min_value,
    MAX(credit_score)            AS max_value,
    AVG(CAST(credit_score AS FLOAT)) AS avg_value,
    STDEV(CAST(credit_score AS FLOAT)) AS stddev_value,
    -- Percentiles (SQL Server syntax)
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY credit_score)
        OVER () AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY credit_score)
        OVER () AS median,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY credit_score)
        OVER () AS p75
FROM loan_origination;
```

#### Frequency Distribution

```sql
-- FICO score distribution in bands
SELECT
    CASE
        WHEN credit_score < 620  THEN 'Subprime (<620)'
        WHEN credit_score < 660  THEN 'Near-Prime (620-659)'
        WHEN credit_score < 700  THEN 'Prime Low (660-699)'
        WHEN credit_score < 740  THEN 'Prime (700-739)'
        WHEN credit_score < 780  THEN 'Prime High (740-779)'
        ELSE 'Super Prime (780+)'
    END AS fico_band,
    COUNT(*) AS loan_count,
    SUM(current_upb) AS total_upb,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_of_loans
FROM loan_origination
WHERE credit_score BETWEEN 300 AND 850
GROUP BY
    CASE
        WHEN credit_score < 620  THEN 'Subprime (<620)'
        WHEN credit_score < 660  THEN 'Near-Prime (620-659)'
        WHEN credit_score < 700  THEN 'Prime Low (660-699)'
        WHEN credit_score < 740  THEN 'Prime (700-739)'
        WHEN credit_score < 780  THEN 'Prime High (740-779)'
        ELSE 'Super Prime (780+)'
    END
ORDER BY MIN(credit_score);
```

---

### 8. Handling Data Corrections & Restatements

Servicers and data providers frequently restate historical data. A robust pipeline must handle corrections without losing the audit trail.

#### Strategies

| Strategy | Description | Use Case |
|---|---|---|
| **Type 2 SCD** | Keep all versions with effective/expiry dates | Full audit trail needed (regulatory) |
| **Snapshot + Override** | Monthly snapshots with a corrections table layered on top | Balances storage with auditability |
| **Idempotent Reload** | Reprocess entire reporting period when corrections arrive | Simple but expensive; works for small datasets |
| **Delta Log** | Log every change with before/after values | Granular change tracking |

```sql
-- Type 2 SCD approach for loan performance corrections
CREATE TABLE loan_performance_history (
    surrogate_key   BIGINT IDENTITY(1,1) PRIMARY KEY,
    loan_id         VARCHAR(20),
    reporting_period DATE,
    current_upb     DECIMAL(14,2),
    loan_status     CHAR(2),
    delinquency_status INT,
    -- SCD2 metadata
    effective_date  DATETIME NOT NULL,
    expiry_date     DATETIME NULL,        -- NULL = current record
    is_current      BIT DEFAULT 1,
    source_file     VARCHAR(200),
    load_timestamp  DATETIME DEFAULT GETDATE()
);

-- When a correction arrives, expire the old record and insert the new one
-- Step 1: Expire
UPDATE loan_performance_history
SET expiry_date = GETDATE(),
    is_current = 0
WHERE loan_id = '1234567890'
  AND reporting_period = '2026-01-01'
  AND is_current = 1;

-- Step 2: Insert corrected record
INSERT INTO loan_performance_history
    (loan_id, reporting_period, current_upb, loan_status, delinquency_status,
     effective_date, is_current, source_file)
VALUES
    ('1234567890', '2026-01-01', 245000.00, '03', 3,
     GETDATE(), 1, 'correction_202602_v2.csv');
```

---

### 9. Reconciliation with Trustee Reports

Trustee reports (from entities like US Bank, BNY Mellon, Wells Fargo Corporate Trust) are the "official" numbers for investor reporting. Loan-level data must reconcile to these pool-level totals.

#### Key Reconciliation Points

| Metric | Loan-Level Aggregation | Trustee Report Value |
|---|---|---|
| Pool UPB | `SUM(current_upb)` for all loans in the pool | Total pool balance |
| Loan Count | `COUNT(DISTINCT loan_id)` with active status | Active loan count |
| Scheduled Principal | `SUM(scheduled_principal)` | Total scheduled P&I |
| Prepayments | `SUM(prepayment_amount)` | Total prepayments |
| Losses | `SUM(loss_amount)` | Realized losses |
| Pool Factor | `SUM(current_upb) / original_pool_balance` | Published pool factor |

```sql
-- Reconciliation query: Loan-level vs. Trustee
WITH loan_level AS (
    SELECT
        lp.pool_id,
        SUM(mp.current_upb)          AS ll_total_upb,
        COUNT(DISTINCT mp.loan_id)   AS ll_loan_count,
        SUM(mp.scheduled_principal)  AS ll_sched_principal,
        SUM(mp.loss_amount)          AS ll_losses
    FROM monthly_performance mp
    JOIN loan_pool_mapping lp ON mp.loan_id = lp.loan_id
    WHERE mp.reporting_period = '2026-02-01'
      AND mp.current_upb > 0
    GROUP BY lp.pool_id
)
SELECT
    t.pool_id,
    t.trustee_upb,
    l.ll_total_upb,
    t.trustee_upb - l.ll_total_upb AS upb_variance,
    ABS(t.trustee_upb - l.ll_total_upb) / NULLIF(t.trustee_upb, 0) * 100
        AS variance_pct,
    CASE
        WHEN ABS(t.trustee_upb - l.ll_total_upb) / NULLIF(t.trustee_upb, 0) > 0.001
        THEN 'BREAK'
        ELSE 'RECONCILED'
    END AS recon_status
FROM trustee_report t
JOIN loan_level l ON t.pool_id = l.pool_id
WHERE t.reporting_period = '2026-02-01'
ORDER BY ABS(t.trustee_upb - l.ll_total_upb) DESC;
```

#### Tolerance Thresholds

- **Hard break**: Variance > 0.1% of pool UPB (must be investigated immediately).
- **Soft break**: Variance between 0.01% and 0.1% (log for review, may be rounding).
- **Reconciled**: Variance < 0.01%.

---

## Common Interview Questions & Answers

### Q1: How would you handle a situation where 15% of loans in a monthly tape are missing FICO scores?

**A:** First, I would determine whether this is a data delivery issue or a legitimate data gap. I would check: (1) Is the source file truncated or corrupted? (2) Is the servicer using a placeholder value like 9999 or 0 instead of NULL? (3) Is this specific to a particular origination vintage or product type (e.g., streamline refis may not re-pull credit)? For the pipeline, I would quarantine these records for separate processing, flag them with a DQ tag, exclude them from FICO-dependent analytics (like risk stratification), and report the gap to stakeholders. I would also check historical trends — if the missing rate jumped from 2% to 15%, that signals a source issue requiring escalation to the servicer. For downstream models, I might impute using the origination FICO if available, but only with clear documentation that imputation was used.

### Q2: Describe how you would design a data quality framework for a mortgage data warehouse.

**A:** I would build a layered framework:

1. **Rule Registry**: A metadata-driven table storing all validation rules with severity levels, thresholds, and SQL expressions. This makes rules configurable without code changes.
2. **Ingestion-Time Checks**: Schema validation, file completeness (row counts, checksums), and critical field non-null checks. Failures here block the file from loading.
3. **Post-Load Validation**: Field-level validity, cross-field business rules, referential integrity, and UPB rollforward reconciliation. Results go to an execution results table.
4. **Reconciliation Layer**: Aggregate loan-level data and compare to trustee/investor reports. Flag breaks above tolerance thresholds.
5. **Scoring & Alerting**: Compute a weighted DQ score per reporting period. Critical failures trigger immediate alerts (PagerDuty/Slack); trending degradation triggers weekly review.
6. **Quarantine & Remediation**: Failed records route to a quarantine schema. Business analysts review and either correct or accept with override. All actions are logged for audit.
7. **Dashboards**: Trend DQ scores over time, break them down by servicer, rule category, and data source. Expose drill-down to individual failing records.

### Q3: A loan shows status "Current" but has a delinquency_status of 3 (90+ days past due). How do you handle this?

**A:** This is a classic cross-field consistency violation. My DQ engine would flag this as a CRITICAL business rule failure. The handling depends on the context:
- If the source is a servicer file, I would quarantine the record and notify the servicer for correction.
- If both fields come from different sources (e.g., status from one system, delinquency from another), the delinquency_status (which is typically calculated from payment history) is more reliable than a manually-set status flag.
- In the pipeline, I would apply a correction rule: if `delinquency_status >= 3`, override `loan_status` to the appropriate delinquent code, and log the override with reason.
- I would track the frequency of this error by servicer — if one servicer has this issue repeatedly, it indicates a systemic reporting problem.

### Q4: How do you validate UPB rollforward at scale across millions of loans?

**A:** UPB rollforward validation is a self-join operation comparing each loan's current month to its prior month. At scale:
- Use a windowed approach with `LAG()` to get the prior month's UPB without an explicit self-join.
- Compute `expected_upb = prior_upb - scheduled_principal - curtailments - losses + modification_adjustments`.
- Compare to reported `current_upb` and flag variances above a threshold (e.g., $0.01).
- Aggregate results: what percentage of loans reconcile? What is the total dollar variance?
- For the first month a loan appears, validate against the origination UPB.
- In Spark, this is a window function operation that parallelizes well. In SQL Server, partitioned by loan_id with proper indexing on `(loan_id, reporting_period)`.

### Q5: What is the difference between data profiling and data validation?

**A:** Data profiling is an exploratory, discovery-oriented process — you examine data to understand its structure, distributions, patterns, and anomalies without preconceived rules. You might discover that 8% of ZIP codes are 4 digits (missing leading zero) or that interest rates cluster bimodally. Profiling informs what rules to create.

Data validation is a prescriptive, enforcement-oriented process — you apply predefined rules and check whether data conforms. Profiling answers "what does the data look like?", while validation answers "does the data meet our requirements?" Profiling is typically done during initial onboarding or after source changes; validation runs continuously in production.

### Q6: How would you handle a servicer sending a complete restatement of the last 6 months of data?

**A:** This is a non-trivial operation. My approach:
1. **Ingest into staging** — load the restated data into a separate staging area, not directly into production.
2. **Compare** — diff the restated data against current production data to identify exactly what changed (which loans, which fields, magnitude of changes).
3. **Impact analysis** — determine which downstream tables, reports, and analytics are affected. If UPB changed significantly, investor reports may need correction.
4. **Apply with audit trail** — use a Type 2 SCD pattern to expire old records and insert corrected ones, preserving the original data for audit. Alternatively, maintain a corrections log with before/after values.
5. **Recompute derived metrics** — recalculate any aggregations, DQ scores, CPR/CDR, and loss metrics for the affected periods.
6. **Notify stakeholders** — alert downstream consumers (risk, reporting, finance) that historical data has changed and which periods are affected.
7. **Root cause** — work with the servicer to understand why the restatement was necessary and whether process changes can prevent future occurrences.

---

## Tips

1. **Start with profiling before writing rules.** Many DQ issues are discoverable through simple frequency distributions and null-count analysis. Do not assume you know all the problems.

2. **Use severity tiers.** Not all DQ failures are equal. A missing FICO is HIGH; a missing co-borrower FICO might be LOW. Only block pipelines on CRITICAL failures.

3. **Track DQ trends, not just point-in-time.** A DQ score of 95% means little in isolation. If it was 99% last month, you have a problem. Always monitor month-over-month changes.

4. **Make rules metadata-driven.** Store rules in tables, not hardcoded in ETL scripts. This allows business users to add rules without engineering deployments.

5. **Quarantine, do not discard.** Never silently drop bad records. Quarantine them, count them, and report them. Dropped records create reconciliation nightmares.

6. **Index for DQ performance.** DQ queries (especially rollforward and referential integrity) can be expensive. Ensure proper indexes on `(loan_id, reporting_period)` and foreign key columns.

7. **Reconcile early and often.** Do not wait for investor reporting to discover that your loan-level data does not tie to trustee totals. Build reconciliation into the daily/monthly pipeline.

8. **Document your business rules with business owners.** Every validation rule should trace back to a business requirement, regulation, or data specification. This documentation is invaluable during audits.

9. **Test your DQ framework itself.** Inject known-bad records and verify they are caught. A DQ framework that silently passes bad data is worse than no framework at all.

10. **Consider data contracts with upstream providers.** Formalize expectations about data format, completeness, timeliness, and quality in written agreements with servicers and data vendors. This gives you leverage when quality degrades.

---
