# Delinquency Analysis

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Delinquency Buckets

Mortgage delinquency is categorized into standardized buckets based on how many payments the borrower has missed:

| Bucket | Description | Industry Shorthand |
|--------|-------------|-------------------|
| **Current** | All payments up to date | 0 DPD (Days Past Due) |
| **30 DQ** | 1 payment missed (30 days past due) | 30 DPD |
| **60 DQ** | 2 payments missed (60 days past due) | 60 DPD |
| **90 DQ** | 3 payments missed (90 days past due) | 90 DPD |
| **120+ DQ** | 4+ payments missed | 120+ DPD |
| **FC (Foreclosure)** | Foreclosure proceedings initiated | Active FC |
| **BK (Bankruptcy)** | Borrower has filed bankruptcy | BK filed |
| **REO** | Property acquired by lender/servicer | Real Estate Owned |

**Serious Delinquency (SDQ):** Typically defined as 90+ DPD, including FC, BK, and REO. This is a critical threshold because:
- It triggers default definitions in many models.
- It is a standard regulatory reporting metric.
- Recovery probability drops sharply beyond 90 DPD.

### MBA vs. OTS Delinquency Counting Methods

Two competing standards exist for counting when a loan is delinquent, and confusing them is a common source of data errors.

**MBA Method (Mortgage Bankers Association):**
- A loan is delinquent the day after a payment is missed.
- A payment due on June 1 that is not received by July 1 is reported as "30 days delinquent" in the July reporting period.
- Most GSE reporting, MBA National Delinquency Survey, and industry-standard datasets use this method.

**OTS Method (Office of Thrift Supervision):**
- A loan is delinquent only after two payments are missed.
- A payment due on June 1 that is not received by July 1 is still reported as "current" under OTS because only one payment has been missed.
- The loan becomes "30 days delinquent" under OTS only when the August payment is also missed.

**Key implication:**

```
OTS 30 DQ ≈ MBA 60 DQ
OTS 60 DQ ≈ MBA 90 DQ
OTS 90 DQ ≈ MBA 120 DQ
```

**Data Engineering Warning:** When integrating data from multiple servicers or vendors, confirm which method each uses. Mixing MBA and OTS data without adjustment will produce materially incorrect delinquency rates. Always standardize to one convention (MBA is the industry default).

### Ever-Delinquent vs. Currently Delinquent

**Currently Delinquent:** The loan's status as of the reporting date. A loan that was 90 DQ last month but cured this month is NOT currently delinquent.

**Ever-Delinquent:** A cumulative flag indicating whether the loan has EVER been in a given delinquency status. Once set to true, it never reverts.

```sql
-- Ever-delinquent flags
SELECT
    loan_id,
    MAX(CASE WHEN days_delinquent >= 30 THEN 1 ELSE 0 END) AS ever_30dq,
    MAX(CASE WHEN days_delinquent >= 60 THEN 1 ELSE 0 END) AS ever_60dq,
    MAX(CASE WHEN days_delinquent >= 90 THEN 1 ELSE 0 END) AS ever_90dq,
    MIN(CASE WHEN days_delinquent >= 90 THEN report_month END)
        AS first_90dq_date
FROM loan_performance_monthly
GROUP BY loan_id;
```

**Why this distinction matters:**
- Current delinquency shows the point-in-time portfolio health.
- Ever-delinquent rates show cumulative credit damage and are used for vintage analysis.
- A high ever-90DQ rate with a low current-90DQ rate indicates many loans cured (possibly via modification) but still carry elevated re-default risk.

### Delinquency Pipeline

The delinquency pipeline is the concept that today's delinquent loans are a leading indicator of tomorrow's defaults and losses. Each bucket feeds the next:

```
Current → 30 DQ → 60 DQ → 90 DQ → 120+ DQ → FC → REO → Liquidation
              ↑        ↑        ↑                            ↓
              |        |        |                         Loss Realized
              +--Cure--+--Cure--+--Cure (decreasing probability)
```

**Pipeline analysis is essential for loss forecasting:**

```sql
-- Delinquency pipeline analysis
SELECT
    report_month,
    SUM(CASE WHEN dq_status = 'CURRENT' THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS pct_current,
    SUM(CASE WHEN dq_status = '30DQ' THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS pct_30dq,
    SUM(CASE WHEN dq_status = '60DQ' THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS pct_60dq,
    SUM(CASE WHEN dq_status = '90DQ' THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS pct_90dq,
    SUM(CASE WHEN dq_status IN ('120DQ','FC','BK') THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS pct_120plus_fc_bk,
    SUM(CASE WHEN dq_status = 'REO' THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS pct_reo,
    SUM(CASE WHEN dq_status IN ('90DQ','120DQ','FC','BK','REO')
        THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS serious_dq_rate
FROM loan_performance_monthly
GROUP BY report_month
ORDER BY report_month;
```

### Cure Rates by Bucket

Cure rates vary dramatically by delinquency depth:

| Bucket | Typical Cure Rate (to Current) | Notes |
|--------|-------------------------------|-------|
| 30 DQ | 40-55% | Many are timing-related (payment processing delays) |
| 60 DQ | 15-25% | Borrower is struggling; some catch up |
| 90 DQ | 5-12% | Unlikely without intervention/modification |
| 120+ DQ | 3-8% | Very unlikely without loss mitigation |
| FC | 2-5% | Typically only via reinstatement or modification |
| REO | 0% | Property already acquired; loan is terminated |

**SQL to compute monthly cure rates by bucket:**

```sql
WITH transitions AS (
    SELECT
        l1.loan_id,
        l1.dq_status AS from_status,
        l2.dq_status AS to_status,
        l1.report_month,
        l1.current_upb
    FROM loan_monthly l1
    JOIN loan_monthly l2
        ON l1.loan_id = l2.loan_id
        AND l2.report_month = l1.report_month + INTERVAL '1 month'
)
SELECT
    report_month,
    from_status,
    COUNT(*) AS total_loans,
    SUM(CASE WHEN to_status = 'CURRENT' THEN 1 ELSE 0 END) AS cured_count,
    SUM(CASE WHEN to_status = 'CURRENT' THEN 1 ELSE 0 END) * 100.0
        / COUNT(*) AS cure_rate_pct,
    SUM(CASE WHEN to_status = 'CURRENT' THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS cure_rate_upb_weighted
FROM transitions
WHERE from_status IN ('30DQ', '60DQ', '90DQ', '120DQ', 'FC')
GROUP BY report_month, from_status
ORDER BY report_month, from_status;
```

### Seasonal Patterns in Delinquency

Delinquency exhibits consistent seasonal patterns:

| Period | Pattern | Driver |
|--------|---------|--------|
| January-February | Rising delinquency | Holiday spending strain, heating costs |
| March-April | Improving (cures) | Tax refunds enable catch-up payments |
| May-August | Stable to improving | Summer employment, housing activity |
| September-November | Gradual increase | Back-to-school costs, seasonal employment ends |
| December | Spike in new 30DQ | Holiday spending, skipped payments |

**Tax refund effect:** The single largest driver of seasonal cures. In February-April, many low-to-moderate-income borrowers use tax refunds to catch up on missed payments, producing a noticeable dip in early-stage delinquency.

### Delinquency Analysis Dimensions

Delinquency should be analyzed across multiple dimensions for comprehensive portfolio monitoring:

**By Vintage:**
```sql
SELECT
    EXTRACT(YEAR FROM origination_date) AS vintage_year,
    loan_age_months,
    AVG(CASE WHEN dq_status IN ('90DQ','120DQ','FC','BK','REO')
        THEN 1.0 ELSE 0.0 END) * 100 AS sdq_rate
FROM loan_performance
WHERE report_month = '2025-12-01'
GROUP BY 1, 2
ORDER BY vintage_year, loan_age_months;
```

**By State:**
```sql
SELECT
    property_state,
    COUNT(*) AS loan_count,
    SUM(current_upb) / 1e9 AS total_upb_bn,
    AVG(CASE WHEN days_delinquent >= 30 THEN 1.0 ELSE 0.0 END) * 100
        AS dq30_plus_rate,
    AVG(CASE WHEN days_delinquent >= 90 THEN 1.0 ELSE 0.0 END) * 100
        AS sdq_rate
FROM loan_performance
WHERE report_month = '2025-12-01'
GROUP BY property_state
ORDER BY sdq_rate DESC;
```

**By Product:**
```sql
SELECT
    product_type,
    CASE
        WHEN note_rate < 3.5 THEN 'Below 3.5%'
        WHEN note_rate < 4.5 THEN '3.5% - 4.5%'
        WHEN note_rate < 5.5 THEN '4.5% - 5.5%'
        WHEN note_rate < 6.5 THEN '5.5% - 6.5%'
        ELSE '6.5%+'
    END AS rate_bucket,
    COUNT(*) AS loan_count,
    AVG(CASE WHEN days_delinquent >= 90 THEN 1.0 ELSE 0.0 END) * 100
        AS sdq_rate
FROM loan_performance
WHERE report_month = '2025-12-01'
GROUP BY product_type, 2
ORDER BY product_type, rate_bucket;
```

**By FICO Band:**
```sql
SELECT
    CASE
        WHEN orig_fico < 620 THEN 'Subprime (<620)'
        WHEN orig_fico < 660 THEN 'Near-prime (620-659)'
        WHEN orig_fico < 700 THEN 'Prime-low (660-699)'
        WHEN orig_fico < 740 THEN 'Prime (700-739)'
        WHEN orig_fico < 780 THEN 'Super-prime (740-779)'
        ELSE 'Ultra-prime (780+)'
    END AS fico_band,
    COUNT(*) AS loan_count,
    AVG(CASE WHEN days_delinquent >= 90 THEN 1.0 ELSE 0.0 END) * 100
        AS sdq_rate,
    AVG(CASE WHEN ever_90dq = 'Y' THEN 1.0 ELSE 0.0 END) * 100
        AS ever_sdq_rate
FROM loan_performance
WHERE report_month = '2025-12-01'
GROUP BY 1
ORDER BY MIN(orig_fico);
```

### Comprehensive SQL Queries for Delinquency Analysis

**Delinquency Trend Dashboard Query:**

```sql
WITH monthly_dq AS (
    SELECT
        report_month,
        dq_status,
        COUNT(*) AS loan_count,
        SUM(current_upb) AS total_upb
    FROM loan_performance_monthly
    WHERE report_month >= DATE_TRUNC('year', CURRENT_DATE) - INTERVAL '2 years'
    GROUP BY report_month, dq_status
),
monthly_totals AS (
    SELECT
        report_month,
        SUM(loan_count) AS total_loans,
        SUM(total_upb) AS total_portfolio_upb
    FROM monthly_dq
    GROUP BY report_month
)
SELECT
    d.report_month,
    d.dq_status,
    d.loan_count,
    d.total_upb / 1e6 AS upb_millions,
    d.loan_count * 100.0 / t.total_loans AS pct_by_count,
    d.total_upb * 100.0 / t.total_portfolio_upb AS pct_by_upb
FROM monthly_dq d
JOIN monthly_totals t ON d.report_month = t.report_month
ORDER BY d.report_month, d.dq_status;
```

**New Delinquency Inflow Analysis:**

```sql
-- Identify loans entering delinquency for the first time
SELECT
    report_month,
    COUNT(*) AS new_dq_loans,
    SUM(current_upb) / 1e6 AS new_dq_upb_mm,
    AVG(orig_fico) AS avg_fico_new_dq,
    AVG(orig_ltv) AS avg_ltv_new_dq,
    AVG(note_rate) AS avg_rate_new_dq,
    AVG(dti) AS avg_dti_new_dq
FROM (
    SELECT
        l.loan_id,
        l.report_month,
        l.current_upb,
        l.orig_fico,
        l.orig_ltv,
        l.note_rate,
        l.dti,
        LAG(l.dq_status) OVER (PARTITION BY l.loan_id ORDER BY l.report_month)
            AS prior_status
    FROM loan_performance_monthly l
) sub
WHERE dq_status = '30DQ'
    AND (prior_status = 'CURRENT' OR prior_status IS NULL)
    AND report_month >= '2024-01-01'
GROUP BY report_month
ORDER BY report_month;
```

**Delinquency Aging / Waterfall Report:**

```sql
-- Track how a cohort of loans entering 30DQ in a specific month
-- progress through the delinquency pipeline
WITH cohort AS (
    SELECT DISTINCT loan_id
    FROM loan_performance_monthly
    WHERE report_month = '2025-01-01'
        AND dq_status = '30DQ'
),
cohort_tracking AS (
    SELECT
        lp.report_month,
        lp.dq_status,
        COUNT(*) AS loan_count,
        SUM(lp.current_upb) AS total_upb
    FROM loan_performance_monthly lp
    JOIN cohort c ON lp.loan_id = c.loan_id
    WHERE lp.report_month BETWEEN '2025-01-01' AND '2026-01-01'
    GROUP BY lp.report_month, lp.dq_status
)
SELECT
    report_month,
    dq_status,
    loan_count,
    total_upb / 1e6 AS upb_mm,
    loan_count * 100.0 / SUM(loan_count) OVER (PARTITION BY report_month)
        AS pct_of_cohort
FROM cohort_tracking
ORDER BY report_month, dq_status;
```

---

## Real-World Examples

### Example 1: Building an Automated Delinquency Dashboard

A data engineering team needs to produce a monthly delinquency dashboard that tracks portfolio health across multiple dimensions.

**Pipeline Architecture:**

```
Servicer Raw Files --> Ingestion (S3/ADLS) --> Staging (Snowflake/Redshift)
                                                      |
                                               Standardization Layer
                                               (MBA convention, status mapping)
                                                      |
                                               Delinquency Fact Table
                                                      |
                                          +------+----+----+------+
                                          |      |         |      |
                                      By State  By Vintage  By Product  By FICO
                                          |      |         |      |
                                          +------+----+----+------+
                                                      |
                                               Dashboard (Tableau/Looker)
```

**Key design decisions:**
- Standardize all servicer data to MBA counting method before loading the fact table.
- Store both loan count and UPB-weighted metrics (they can tell different stories).
- Pre-compute month-over-month changes and trend indicators.
- Include cohort tracking tables for pipeline analysis.

### Example 2: Early Warning System for Credit Deterioration

```sql
-- Alert query: identify portfolios with accelerating early-stage DQ
WITH monthly_rates AS (
    SELECT
        portfolio_id,
        report_month,
        SUM(CASE WHEN dq_status = '30DQ' THEN current_upb ELSE 0 END)
            / SUM(current_upb) * 100 AS dq30_rate,
        SUM(CASE WHEN dq_status IN ('30DQ','60DQ') THEN current_upb ELSE 0 END)
            / SUM(current_upb) * 100 AS dq60_rate
    FROM loan_performance_monthly
    GROUP BY portfolio_id, report_month
),
with_trend AS (
    SELECT
        *,
        dq30_rate - LAG(dq30_rate, 1) OVER (
            PARTITION BY portfolio_id ORDER BY report_month
        ) AS mom_change_30dq,
        dq30_rate - LAG(dq30_rate, 3) OVER (
            PARTITION BY portfolio_id ORDER BY report_month
        ) AS three_month_change_30dq,
        AVG(dq30_rate) OVER (
            PARTITION BY portfolio_id
            ORDER BY report_month ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING
        ) AS trailing_12m_avg_30dq
    FROM monthly_rates
)
SELECT
    portfolio_id,
    report_month,
    dq30_rate,
    mom_change_30dq,
    three_month_change_30dq,
    trailing_12m_avg_30dq,
    CASE
        WHEN three_month_change_30dq > 0.5
            AND dq30_rate > trailing_12m_avg_30dq * 1.25
        THEN 'RED'
        WHEN three_month_change_30dq > 0.25
            OR dq30_rate > trailing_12m_avg_30dq * 1.10
        THEN 'YELLOW'
        ELSE 'GREEN'
    END AS alert_status
FROM with_trend
WHERE report_month = (SELECT MAX(report_month) FROM with_trend)
ORDER BY alert_status, three_month_change_30dq DESC;
```

### Example 3: Geographic Hotspot Detection

```sql
-- Identify MSAs with deteriorating credit performance
SELECT
    msa_code,
    msa_name,
    property_state,
    COUNT(*) AS loan_count,
    SUM(current_upb) / 1e6 AS upb_mm,
    AVG(CASE WHEN days_delinquent >= 30 THEN 1.0 ELSE 0.0 END) * 100
        AS current_30plus_rate,
    AVG(CASE WHEN days_delinquent >= 90 THEN 1.0 ELSE 0.0 END) * 100
        AS current_sdq_rate,
    -- Compare to 6 months ago
    AVG(CASE WHEN days_delinquent >= 90 THEN 1.0 ELSE 0.0 END) * 100
        - msa_hist.sdq_6mo_ago AS sdq_change_6mo
FROM loan_performance lp
LEFT JOIN (
    SELECT
        msa_code AS hist_msa,
        AVG(CASE WHEN days_delinquent >= 90 THEN 1.0 ELSE 0.0 END) * 100
            AS sdq_6mo_ago
    FROM loan_performance_monthly
    WHERE report_month = CURRENT_DATE - INTERVAL '6 months'
    GROUP BY msa_code
) msa_hist ON lp.msa_code = msa_hist.hist_msa
WHERE lp.report_month = '2025-12-01'
GROUP BY msa_code, msa_name, property_state, msa_hist.sdq_6mo_ago
HAVING COUNT(*) >= 100  -- minimum sample size
ORDER BY sdq_change_6mo DESC
LIMIT 25;
```

---

## Common Interview Questions & Answers

### Q1: What is the difference between MBA and OTS delinquency counting methods, and why does it matter?

**A:** Under the MBA method, a loan is 30 days delinquent after missing one payment, while under OTS, a loan is not considered delinquent until two payments are missed. This means OTS 30DQ roughly equals MBA 60DQ. It matters enormously for data engineering because mixing data from servicers using different conventions without standardization will produce incorrect portfolio metrics. For example, a portfolio's SDQ rate could be understated by half if some servicers report on OTS while the dashboard assumes MBA. I always standardize to MBA convention as part of the data ingestion pipeline and document the source convention for each servicer feed.

### Q2: How would you design a delinquency pipeline analysis to forecast future losses?

**A:** I would build a three-stage pipeline. First, capture the current delinquency distribution by bucket (30DQ, 60DQ, 90DQ, 120+, FC, REO), segmented by relevant risk dimensions (vintage, FICO, LTV, state). Second, apply transition probabilities (roll rates and cure rates) monthly to project how today's delinquent loans will flow through the pipeline over the next 12-24 months, estimating how many will reach liquidation. Third, apply loss severity assumptions (segmented by state/property type) to the projected liquidations to estimate dollar losses and timing. The key advantage of this approach is that it uses observable leading indicators (early-stage delinquency) rather than just extrapolating historical loss rates.

### Q3: What seasonal patterns exist in mortgage delinquency data, and how do you account for them?

**A:** The most prominent pattern is the "tax refund effect" — delinquency rates drop in February-April as borrowers use tax refunds to catch up on missed payments. Delinquency tends to rise in December-January due to holiday spending and in late fall as seasonal employment ends. To account for this, I compute seasonally adjusted delinquency rates by dividing observed rates by seasonal factors estimated from multi-year historical averages. This allows trend analysis to distinguish genuine deterioration from predictable calendar effects. In dashboards, I display both raw and adjusted metrics, with the adjusted series used for alerts and trend detection.

### Q4: Walk through how you would build a SQL-based transition matrix for a mortgage portfolio.

**A:** I would self-join the monthly loan performance table, matching each loan's status in month T with its status in month T+1. Group by from_status and to_status, count loans (or sum UPB for balance-weighted matrices), then divide by the row total for each from_status to get transition probabilities. Key implementation details: handle edge cases for loans that terminate (prepay or liquidate) as absorbing states; ensure the join only captures consecutive months (no gaps); and validate that each row sums to approximately 100%. I would parameterize the query by report_month and add dimensional cuts (vintage, FICO band, state) to enable segmented analysis. The output feeds directly into Markov chain loss forecasting models.

### Q5: A portfolio manager asks why the delinquency rate is rising but losses are stable. How do you investigate?

**A:** Several explanations are possible, and I would investigate each with data. First, check if the rising delinquency is concentrated in early-stage buckets (30-60DQ) that have high cure rates — this would increase the delinquency rate without producing losses. Second, examine whether loss mitigation activity (modifications, forbearance) has increased, which would hold loans in delinquent status longer but prevent liquidation. Third, check if the foreclosure timeline has lengthened (due to state moratoria, servicer backlogs, or court delays), creating a lag between delinquency and loss realization. Fourth, verify home prices are still supporting high recovery rates, so that the losses on the loans that do liquidate are low. I would present the transition matrix trends, cure rates, modification volumes, and severity trends to identify the actual driver.

### Q6: How would you validate the accuracy of delinquency data received from a new servicer?

**A:** I would perform multiple validation checks: (1) Confirm the DQ counting convention (MBA vs. OTS) by checking whether their 30DQ rates are roughly half the industry benchmark (OTS indicator). (2) Verify that delinquency status changes follow logical progressions — a loan should not jump from current to 90DQ in one month without passing through 30DQ and 60DQ (unless there was a reporting gap). (3) Cross-check that loans in FC/REO status are not also marked as current. (4) Compare portfolio-level delinquency rates against public benchmarks (MBA National Delinquency Survey, GSE performance data) for similar products and geographies. (5) Check for suspicious patterns like all delinquent loans having the same DQ date, or abnormally high cure rates that might indicate data corrections rather than actual borrower behavior. (6) Reconcile loan counts and balances month-over-month to ensure no loans are dropped or duplicated.

---

## Tips

- **MBA convention is the standard.** Unless explicitly told otherwise, assume MBA counting. But always verify with each data source.
- **UPB-weighted vs. loan-count metrics tell different stories.** A few large delinquent loans can dominate UPB-weighted metrics while appearing insignificant by count. Report both.
- **30-day delinquency is noisy.** Many 30DQ occurrences are payment timing issues, not genuine credit stress. Focus on the 60DQ roll rate as a better early warning signal.
- **Always include both point-in-time and trend metrics.** A 2% SDQ rate could be improving from 3% or deteriorating from 1%. Context matters.
- **Partition your delinquency tables by report_month.** Monthly delinquency data grows very fast (millions of rows per month). Proper partitioning is essential for query performance.
- **When building cohort-tracking queries, use window functions liberally.** LAG/LEAD for transitions, running sums for cumulative metrics, and FIRST_VALUE for identifying when loans first entered a given status.
- **Data freshness matters.** Delinquency data is typically reported with a 30-45 day lag. Ensure your dashboards clearly display the as-of date to prevent misinterpretation.
