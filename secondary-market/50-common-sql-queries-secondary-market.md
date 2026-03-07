# 50. Common SQL Queries for Secondary Market Analysis

[Back to Secondary Market Index](./README.md)

---

## Overview

This guide provides production-ready SQL queries for the most common analytical tasks in secondary mortgage market data engineering. Each query is annotated with business context, includes both SQL Server and Snowflake syntax variations where they differ, and is designed to work against a typical loan-level data model with origination and monthly performance tables. These are the queries that come up repeatedly in interviews, on the job, and in technical assessments.

---

## Assumed Data Model

All queries reference the following core tables:

```sql
-- loan_origination: One row per loan, static attributes
--   loan_id, origination_date, original_upb, orig_credit_score, orig_ltv,
--   orig_dti, property_state, property_type, occupancy_type, loan_purpose,
--   product_type, original_term, original_interest_rate, channel, seller_name,
--   servicer_name, zip_code, msa

-- monthly_performance: One row per loan per reporting period
--   loan_id, reporting_period, current_upb, current_interest_rate,
--   loan_age, remaining_term, delinquency_status, loan_status,
--   scheduled_principal, curtailment_amount, prepayment_amount,
--   modification_flag, modification_date, zero_balance_code,
--   zero_balance_date, loss_amount, net_loss_amount, foreclosure_date,
--   disposition_date, recovery_amount

-- loan_pool_mapping: Maps loans to securitization pools
--   loan_id, pool_id, original_pool_balance
```

---

## 1. Calculating CPR / SMM from Loan Data

**Business Context**: CPR (Conditional Prepayment Rate) is the annualized voluntary prepayment speed. SMM (Single Monthly Mortality) is the monthly rate. These are among the most-watched metrics for MBS investors because prepayments directly impact bond duration and yield.

### SQL Server

```sql
WITH monthly_agg AS (
    SELECT
        curr.reporting_period,
        lp.pool_id,
        SUM(prev.current_upb)         AS beginning_upb,
        SUM(curr.scheduled_principal)  AS scheduled_principal,
        -- Prepayments: full payoffs (zero_balance_code = '01') + partial curtailments
        SUM(
            CASE
                WHEN curr.zero_balance_code = '01'
                THEN ISNULL(prev.current_upb, 0)
                ELSE ISNULL(curr.curtailment_amount, 0)
            END
        ) AS prepayment_amount
    FROM monthly_performance curr
    INNER JOIN monthly_performance prev
        ON curr.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
    INNER JOIN loan_pool_mapping lp
        ON curr.loan_id = lp.loan_id
    WHERE curr.reporting_period BETWEEN '2025-03-01' AND '2026-02-01'
    GROUP BY curr.reporting_period, lp.pool_id
)
SELECT
    reporting_period,
    pool_id,
    beginning_upb,
    prepayment_amount,
    -- SMM = Prepayment / (Beginning UPB - Scheduled Principal)
    CAST(
        prepayment_amount / NULLIF(beginning_upb - scheduled_principal, 0)
        AS DECIMAL(10, 8)
    ) AS smm,
    -- CPR = 1 - (1 - SMM) ^ 12
    CAST(
        1.0 - POWER(
            1.0 - prepayment_amount / NULLIF(beginning_upb - scheduled_principal, 0),
            12
        )
        AS DECIMAL(10, 8)
    ) AS cpr
FROM monthly_agg
ORDER BY pool_id, reporting_period;
```

### Snowflake Variation

```sql
-- Key differences: DATEADD syntax, IFNULL instead of ISNULL, POW instead of POWER
WITH monthly_agg AS (
    SELECT
        curr.reporting_period,
        lp.pool_id,
        SUM(prev.current_upb)         AS beginning_upb,
        SUM(curr.scheduled_principal)  AS scheduled_principal,
        SUM(
            CASE
                WHEN curr.zero_balance_code = '01'
                THEN IFNULL(prev.current_upb, 0)
                ELSE IFNULL(curr.curtailment_amount, 0)
            END
        ) AS prepayment_amount
    FROM monthly_performance curr
    INNER JOIN monthly_performance prev
        ON curr.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD('MONTH', -1, curr.reporting_period)
    INNER JOIN loan_pool_mapping lp
        ON curr.loan_id = lp.loan_id
    WHERE curr.reporting_period BETWEEN '2025-03-01' AND '2026-02-01'
    GROUP BY curr.reporting_period, lp.pool_id
)
SELECT
    reporting_period,
    pool_id,
    beginning_upb,
    prepayment_amount,
    prepayment_amount / NULLIF(beginning_upb - scheduled_principal, 0) AS smm,
    1.0 - POW(
        1.0 - prepayment_amount / NULLIF(beginning_upb - scheduled_principal, 0),
        12
    ) AS cpr
FROM monthly_agg
ORDER BY pool_id, reporting_period;
```

---

## 2. Delinquency Bucket Transition Matrix

**Business Context**: The transition matrix shows how loans move between delinquency states month-over-month. It reveals cure rates (delinquent loans returning to current), roll rates (loans progressing deeper into delinquency), and prepayment/default exits. This is essential for loss forecasting and stress testing.

### SQL Server

```sql
WITH transitions AS (
    SELECT
        prev.delinquency_status AS from_status,
        curr.delinquency_status AS to_status,
        COUNT(*)                AS loan_count,
        SUM(prev.current_upb)   AS transition_upb
    FROM monthly_performance curr
    INNER JOIN monthly_performance prev
        ON curr.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
    WHERE curr.reporting_period = '2026-02-01'
    GROUP BY prev.delinquency_status, curr.delinquency_status
),
from_totals AS (
    SELECT
        from_status,
        SUM(loan_count) AS total_from_count,
        SUM(transition_upb) AS total_from_upb
    FROM transitions
    GROUP BY from_status
)
SELECT
    t.from_status,
    t.to_status,
    t.loan_count,
    t.transition_upb,
    -- Transition probability (by count)
    CAST(t.loan_count * 100.0 / NULLIF(f.total_from_count, 0) AS DECIMAL(7,2))
        AS transition_pct_count,
    -- Transition probability (by UPB)
    CAST(t.transition_upb * 100.0 / NULLIF(f.total_from_upb, 0) AS DECIMAL(7,2))
        AS transition_pct_upb
FROM transitions t
JOIN from_totals f ON t.from_status = f.from_status
ORDER BY t.from_status, t.to_status;
```

#### Pivoted Transition Matrix (SQL Server)

```sql
-- Pivot to create a traditional matrix format
SELECT
    from_status,
    ISNULL([0], 0)  AS to_current,
    ISNULL([1], 0)  AS to_30dpd,
    ISNULL([2], 0)  AS to_60dpd,
    ISNULL([3], 0)  AS to_90dpd,
    ISNULL([4], 0)  AS to_120plus
FROM (
    SELECT
        prev.delinquency_status AS from_status,
        curr.delinquency_status AS to_status,
        CAST(COUNT(*) * 100.0 /
             SUM(COUNT(*)) OVER (PARTITION BY prev.delinquency_status)
             AS DECIMAL(7,2)) AS pct
    FROM monthly_performance curr
    INNER JOIN monthly_performance prev
        ON curr.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
    WHERE curr.reporting_period = '2026-02-01'
    GROUP BY prev.delinquency_status, curr.delinquency_status
) src
PIVOT (
    MAX(pct) FOR to_status IN ([0], [1], [2], [3], [4])
) pvt
ORDER BY from_status;
```

### Snowflake Variation (Conditional Aggregation Instead of PIVOT)

```sql
SELECT
    from_status,
    ROUND(SUM(CASE WHEN to_status = 0 THEN loan_count ELSE 0 END) * 100.0
          / NULLIF(SUM(loan_count), 0), 2) AS to_current,
    ROUND(SUM(CASE WHEN to_status = 1 THEN loan_count ELSE 0 END) * 100.0
          / NULLIF(SUM(loan_count), 0), 2) AS to_30dpd,
    ROUND(SUM(CASE WHEN to_status = 2 THEN loan_count ELSE 0 END) * 100.0
          / NULLIF(SUM(loan_count), 0), 2) AS to_60dpd,
    ROUND(SUM(CASE WHEN to_status = 3 THEN loan_count ELSE 0 END) * 100.0
          / NULLIF(SUM(loan_count), 0), 2) AS to_90dpd,
    ROUND(SUM(CASE WHEN to_status >= 4 THEN loan_count ELSE 0 END) * 100.0
          / NULLIF(SUM(loan_count), 0), 2) AS to_120plus
FROM (
    SELECT
        prev.delinquency_status AS from_status,
        curr.delinquency_status AS to_status,
        COUNT(*) AS loan_count
    FROM monthly_performance curr
    INNER JOIN monthly_performance prev
        ON curr.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD('MONTH', -1, curr.reporting_period)
    WHERE curr.reporting_period = '2026-02-01'
    GROUP BY prev.delinquency_status, curr.delinquency_status
) transitions
GROUP BY from_status
ORDER BY from_status;
```

---

## 3. Vintage Curve Analysis

**Business Context**: Vintage curves plot cumulative performance (defaults, losses, prepayments) against loan age, grouped by origination period. They are the primary tool for comparing underwriting quality across time periods and projecting future performance.

```sql
-- Cumulative default rate by vintage and loan age
WITH vintage_monthly AS (
    SELECT
        YEAR(lo.origination_date) AS vintage_year,
        mp.loan_age,
        COUNT(DISTINCT lo.loan_id) AS original_loan_count,
        SUM(CASE
            WHEN mp.zero_balance_code IN ('03', '06', '09')  -- default/liquidation codes
            THEN 1 ELSE 0
        END) AS monthly_defaults,
        SUM(CASE
            WHEN mp.zero_balance_code IN ('03', '06', '09')
            THEN ISNULL(mp.net_loss_amount, 0) ELSE 0
        END) AS monthly_net_loss
    FROM monthly_performance mp
    INNER JOIN loan_origination lo ON mp.loan_id = lo.loan_id
    GROUP BY YEAR(lo.origination_date), mp.loan_age
),
vintage_totals AS (
    SELECT
        YEAR(origination_date) AS vintage_year,
        COUNT(*) AS vintage_orig_count,
        SUM(original_upb) AS vintage_orig_upb
    FROM loan_origination
    GROUP BY YEAR(origination_date)
)
SELECT
    vm.vintage_year,
    vm.loan_age,
    vm.monthly_defaults,
    -- Cumulative defaults (running sum by vintage)
    SUM(vm.monthly_defaults) OVER (
        PARTITION BY vm.vintage_year ORDER BY vm.loan_age
        ROWS UNBOUNDED PRECEDING
    ) AS cumulative_defaults,
    -- Cumulative default rate
    CAST(
        SUM(vm.monthly_defaults) OVER (
            PARTITION BY vm.vintage_year ORDER BY vm.loan_age
            ROWS UNBOUNDED PRECEDING
        ) * 100.0 / NULLIF(vt.vintage_orig_count, 0)
        AS DECIMAL(7, 4)
    ) AS cumulative_default_rate_pct,
    -- Cumulative net loss
    SUM(vm.monthly_net_loss) OVER (
        PARTITION BY vm.vintage_year ORDER BY vm.loan_age
        ROWS UNBOUNDED PRECEDING
    ) AS cumulative_net_loss,
    -- CNL as % of original UPB
    CAST(
        SUM(vm.monthly_net_loss) OVER (
            PARTITION BY vm.vintage_year ORDER BY vm.loan_age
            ROWS UNBOUNDED PRECEDING
        ) * 100.0 / NULLIF(vt.vintage_orig_upb, 0)
        AS DECIMAL(7, 4)
    ) AS cnl_pct
FROM vintage_monthly vm
JOIN vintage_totals vt ON vm.vintage_year = vt.vintage_year
WHERE vm.vintage_year BETWEEN 2019 AND 2025
ORDER BY vm.vintage_year, vm.loan_age;
```

---

## 4. Loan-Level to Pool-Level Aggregation

**Business Context**: Securitization pools are analyzed at the aggregate level. Transforming loan-level data to pool-level metrics is a fundamental operation for investor reporting, deal surveillance, and pool comparison.

```sql
SELECT
    lp.pool_id,
    mp.reporting_period,
    -- Counts
    COUNT(DISTINCT mp.loan_id) AS active_loans,
    -- Balances
    SUM(mp.current_upb) AS pool_upb,
    -- Pool factor
    SUM(mp.current_upb) / NULLIF(lp2.original_pool_balance, 0) AS pool_factor,
    -- Weighted averages
    SUM(mp.current_interest_rate * mp.current_upb)
        / NULLIF(SUM(mp.current_upb), 0) AS wac,
    SUM(mp.remaining_term * mp.current_upb)
        / NULLIF(SUM(mp.current_upb), 0) AS wam,
    SUM(mp.loan_age * mp.current_upb)
        / NULLIF(SUM(mp.current_upb), 0) AS wala,
    SUM(lo.orig_credit_score * mp.current_upb)
        / NULLIF(SUM(mp.current_upb), 0) AS wa_fico,
    SUM(lo.orig_ltv * mp.current_upb)
        / NULLIF(SUM(mp.current_upb), 0) AS wa_ltv,
    -- Delinquency distribution
    SUM(CASE WHEN mp.delinquency_status = 0 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS pct_current,
    SUM(CASE WHEN mp.delinquency_status = 1 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS pct_30dpd,
    SUM(CASE WHEN mp.delinquency_status = 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS pct_60dpd,
    SUM(CASE WHEN mp.delinquency_status >= 3 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS pct_90plus,
    -- Monthly activity
    SUM(mp.scheduled_principal) AS total_sched_principal,
    SUM(ISNULL(mp.curtailment_amount, 0)) AS total_curtailments,
    SUM(ISNULL(mp.net_loss_amount, 0)) AS total_net_loss,
    -- Modification count
    SUM(CASE WHEN mp.modification_flag = 'Y' THEN 1 ELSE 0 END) AS modified_loans
FROM monthly_performance mp
INNER JOIN loan_origination lo ON mp.loan_id = lo.loan_id
INNER JOIN loan_pool_mapping lp ON mp.loan_id = lp.loan_id
INNER JOIN (
    SELECT pool_id, SUM(original_upb) AS original_pool_balance
    FROM loan_pool_mapping lpm
    JOIN loan_origination lo2 ON lpm.loan_id = lo2.loan_id
    GROUP BY pool_id
) lp2 ON lp.pool_id = lp2.pool_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.current_upb > 0
GROUP BY lp.pool_id, mp.reporting_period, lp2.original_pool_balance
ORDER BY lp.pool_id;
```

---

## 5. UPB Rollforward

**Business Context**: The UPB rollforward reconciles the beginning balance to the ending balance through all activities (scheduled payments, curtailments, prepayments, losses, modifications). This is the fundamental reconciliation tool — if the rollforward does not balance, something is wrong with the data.

```sql
-- Pool-level UPB rollforward
WITH current_month AS (
    SELECT
        lp.pool_id,
        SUM(mp.current_upb) AS ending_upb,
        SUM(mp.scheduled_principal) AS scheduled_principal,
        SUM(ISNULL(mp.curtailment_amount, 0)) AS curtailments,
        -- Full prepayments (loans that paid off)
        SUM(CASE WHEN mp.zero_balance_code = '01'
                 THEN prev.current_upb ELSE 0 END) AS full_prepayments,
        -- Liquidation / default removals
        SUM(CASE WHEN mp.zero_balance_code IN ('03','06','09')
                 THEN prev.current_upb ELSE 0 END) AS liquidation_upb,
        -- Net losses on liquidated loans
        SUM(CASE WHEN mp.zero_balance_code IN ('03','06','09')
                 THEN ISNULL(mp.net_loss_amount, 0) ELSE 0 END) AS net_losses,
        -- Recovery (liquidation UPB - net loss)
        SUM(CASE WHEN mp.zero_balance_code IN ('03','06','09')
                 THEN prev.current_upb - ISNULL(mp.net_loss_amount, 0)
                 ELSE 0 END) AS recoveries
    FROM monthly_performance mp
    INNER JOIN monthly_performance prev
        ON mp.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, mp.reporting_period)
    INNER JOIN loan_pool_mapping lp ON mp.loan_id = lp.loan_id
    WHERE mp.reporting_period = '2026-02-01'
    GROUP BY lp.pool_id
),
prior_month AS (
    SELECT
        lp.pool_id,
        SUM(mp.current_upb) AS beginning_upb
    FROM monthly_performance mp
    INNER JOIN loan_pool_mapping lp ON mp.loan_id = lp.loan_id
    WHERE mp.reporting_period = '2026-01-01'
      AND mp.current_upb > 0
    GROUP BY lp.pool_id
)
SELECT
    p.pool_id,
    p.beginning_upb,
    c.scheduled_principal,
    c.curtailments,
    c.full_prepayments,
    c.liquidation_upb,
    c.net_losses,
    c.ending_upb,
    -- Rollforward check
    p.beginning_upb
        - c.scheduled_principal
        - c.curtailments
        - c.full_prepayments
        - c.liquidation_upb AS expected_ending_upb,
    -- Variance
    c.ending_upb - (
        p.beginning_upb
        - c.scheduled_principal
        - c.curtailments
        - c.full_prepayments
        - c.liquidation_upb
    ) AS variance,
    CASE
        WHEN ABS(c.ending_upb - (
            p.beginning_upb
            - c.scheduled_principal
            - c.curtailments
            - c.full_prepayments
            - c.liquidation_upb
        )) < 1.00 THEN 'RECONCILED'
        ELSE 'BREAK'
    END AS recon_status
FROM prior_month p
JOIN current_month c ON p.pool_id = c.pool_id
ORDER BY ABS(c.ending_upb - (
    p.beginning_upb - c.scheduled_principal - c.curtailments
    - c.full_prepayments - c.liquidation_upb
)) DESC;
```

---

## 6. Loss Severity Calculation

**Business Context**: Loss severity measures the percentage of the loan balance lost when a loan defaults and is liquidated. It is a key input to credit risk models and determines how much principal investors lose. Severity varies by LTV, property type, state (judicial vs. non-judicial foreclosure), and timeline.

```sql
-- Loan-level loss severity for all liquidated loans
SELECT
    mp.loan_id,
    lo.origination_date,
    lo.orig_credit_score,
    lo.orig_ltv,
    lo.property_state,
    lo.property_type,
    mp.zero_balance_date AS liquidation_date,
    mp.zero_balance_code AS liquidation_type,
    -- Key amounts
    mp.current_upb AS pre_liquidation_upb,  -- UPB just before liquidation
    ISNULL(mp.loss_amount, 0) AS gross_loss,
    ISNULL(mp.recovery_amount, 0) AS recovery,
    ISNULL(mp.net_loss_amount, 0) AS net_loss,
    -- Severity
    CAST(
        ISNULL(mp.net_loss_amount, 0) * 100.0
        / NULLIF(mp.current_upb, 0)
        AS DECIMAL(7, 2)
    ) AS loss_severity_pct,
    -- Timeline
    DATEDIFF(MONTH, mp.foreclosure_date, mp.disposition_date) AS fc_to_disposition_months,
    DATEDIFF(MONTH, lo.origination_date, mp.zero_balance_date) AS months_to_liquidation
FROM monthly_performance mp
INNER JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.zero_balance_code IN ('03', '06', '09')  -- Default / Short Sale / REO
  AND mp.zero_balance_date IS NOT NULL
ORDER BY mp.zero_balance_date DESC;

-- Aggregate loss severity by dimension
SELECT
    lo.property_state,
    COUNT(*) AS liquidation_count,
    SUM(mp.current_upb) AS total_liquidation_upb,
    SUM(ISNULL(mp.net_loss_amount, 0)) AS total_net_loss,
    CAST(
        SUM(ISNULL(mp.net_loss_amount, 0)) * 100.0
        / NULLIF(SUM(mp.current_upb), 0)
        AS DECIMAL(7, 2)
    ) AS avg_loss_severity,
    AVG(DATEDIFF(MONTH, mp.foreclosure_date, mp.disposition_date))
        AS avg_fc_timeline_months
FROM monthly_performance mp
INNER JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.zero_balance_code IN ('03', '06', '09')
  AND mp.zero_balance_date >= '2024-01-01'
GROUP BY lo.property_state
HAVING COUNT(*) >= 10  -- minimum sample size
ORDER BY avg_loss_severity DESC;
```

---

## 7. Stratification Tables

**Business Context**: Stratification tables (strats) break a portfolio into segments to reveal concentration risk and performance patterns. Every MBS pre-sale report and monthly investor supplement contains strats by FICO, LTV, state, product type, and other dimensions.

### By FICO Band

```sql
SELECT
    CASE
        WHEN lo.orig_credit_score < 620  THEN '01: < 620'
        WHEN lo.orig_credit_score < 660  THEN '02: 620-659'
        WHEN lo.orig_credit_score < 700  THEN '03: 660-699'
        WHEN lo.orig_credit_score < 740  THEN '04: 700-739'
        WHEN lo.orig_credit_score < 780  THEN '05: 740-779'
        WHEN lo.orig_credit_score <= 850 THEN '06: 780+'
        ELSE '07: Missing/Invalid'
    END AS fico_band,
    COUNT(*) AS loan_count,
    CAST(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS pct_count,
    SUM(mp.current_upb) AS total_upb,
    CAST(SUM(mp.current_upb) * 100.0 / SUM(SUM(mp.current_upb)) OVER ()
         AS DECIMAL(5,2)) AS pct_upb,
    AVG(mp.current_upb) AS avg_loan_size,
    SUM(mp.current_interest_rate * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wac,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60plus_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01' AND mp.current_upb > 0
GROUP BY
    CASE
        WHEN lo.orig_credit_score < 620  THEN '01: < 620'
        WHEN lo.orig_credit_score < 660  THEN '02: 620-659'
        WHEN lo.orig_credit_score < 700  THEN '03: 660-699'
        WHEN lo.orig_credit_score < 740  THEN '04: 700-739'
        WHEN lo.orig_credit_score < 780  THEN '05: 740-779'
        WHEN lo.orig_credit_score <= 850 THEN '06: 780+'
        ELSE '07: Missing/Invalid'
    END
ORDER BY 1;
```

### By LTV Band

```sql
SELECT
    CASE
        WHEN lo.orig_ltv <= 60  THEN '01: <= 60%'
        WHEN lo.orig_ltv <= 70  THEN '02: 60.01-70%'
        WHEN lo.orig_ltv <= 80  THEN '03: 70.01-80%'
        WHEN lo.orig_ltv <= 90  THEN '04: 80.01-90%'
        WHEN lo.orig_ltv <= 95  THEN '05: 90.01-95%'
        WHEN lo.orig_ltv <= 100 THEN '06: 95.01-100%'
        ELSE '07: > 100%'
    END AS ltv_band,
    COUNT(*) AS loan_count,
    SUM(mp.current_upb) AS total_upb,
    CAST(SUM(mp.current_upb) * 100.0 / SUM(SUM(mp.current_upb)) OVER ()
         AS DECIMAL(5,2)) AS pct_upb,
    SUM(lo.orig_credit_score * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wa_fico,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60plus_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01' AND mp.current_upb > 0
GROUP BY
    CASE
        WHEN lo.orig_ltv <= 60  THEN '01: <= 60%'
        WHEN lo.orig_ltv <= 70  THEN '02: 60.01-70%'
        WHEN lo.orig_ltv <= 80  THEN '03: 70.01-80%'
        WHEN lo.orig_ltv <= 90  THEN '04: 80.01-90%'
        WHEN lo.orig_ltv <= 95  THEN '05: 90.01-95%'
        WHEN lo.orig_ltv <= 100 THEN '06: 95.01-100%'
        ELSE '07: > 100%'
    END
ORDER BY 1;
```

### By State (Top 15)

```sql
SELECT TOP 15
    lo.property_state,
    COUNT(*) AS loan_count,
    SUM(mp.current_upb) AS total_upb,
    CAST(SUM(mp.current_upb) * 100.0 / SUM(SUM(mp.current_upb)) OVER ()
         AS DECIMAL(5,2)) AS pct_upb,
    SUM(mp.current_interest_rate * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wac,
    SUM(lo.orig_credit_score * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wa_fico,
    SUM(lo.orig_ltv * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wa_ltv,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60plus_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01' AND mp.current_upb > 0
GROUP BY lo.property_state
ORDER BY SUM(mp.current_upb) DESC;
```

**Snowflake**: Replace `TOP 15` with `LIMIT 15` at the end of the query.

### By Product Type

```sql
SELECT
    lo.product_type,
    CASE lo.original_term
        WHEN 360 THEN '30-Year'
        WHEN 180 THEN '15-Year'
        WHEN 240 THEN '20-Year'
        ELSE CAST(lo.original_term AS VARCHAR) + '-Month'
    END AS term_bucket,
    COUNT(*) AS loan_count,
    SUM(mp.current_upb) AS total_upb,
    CAST(SUM(mp.current_upb) * 100.0 / SUM(SUM(mp.current_upb)) OVER ()
         AS DECIMAL(5,2)) AS pct_upb,
    SUM(mp.current_interest_rate * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wac,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60plus_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01' AND mp.current_upb > 0
GROUP BY lo.product_type,
    CASE lo.original_term
        WHEN 360 THEN '30-Year'
        WHEN 180 THEN '15-Year'
        WHEN 240 THEN '20-Year'
        ELSE CAST(lo.original_term AS VARCHAR) + '-Month'
    END
ORDER BY SUM(mp.current_upb) DESC;
```

---

## 8. Cohort Analysis

**Business Context**: Cohort analysis groups loans by a shared characteristic at origination (vintage quarter, FICO band, LTV band, channel) and tracks their performance over time. It is similar to vintage analysis but can be sliced by any origination attribute.

```sql
-- Cohort: FICO band at origination, tracked by loan age
WITH cohort AS (
    SELECT
        CASE
            WHEN lo.orig_credit_score < 680 THEN 'Below 680'
            WHEN lo.orig_credit_score < 720 THEN '680-719'
            WHEN lo.orig_credit_score < 760 THEN '720-759'
            ELSE '760+'
        END AS fico_cohort,
        mp.loan_age,
        COUNT(DISTINCT mp.loan_id) AS active_loans,
        SUM(mp.current_upb) AS cohort_upb,
        SUM(CASE WHEN mp.delinquency_status >= 3 THEN 1 ELSE 0 END)
            AS sdq_count,
        SUM(CASE WHEN mp.delinquency_status >= 3 THEN mp.current_upb ELSE 0 END)
            AS sdq_upb
    FROM monthly_performance mp
    JOIN loan_origination lo ON mp.loan_id = lo.loan_id
    WHERE lo.orig_credit_score BETWEEN 300 AND 850
    GROUP BY
        CASE
            WHEN lo.orig_credit_score < 680 THEN 'Below 680'
            WHEN lo.orig_credit_score < 720 THEN '680-719'
            WHEN lo.orig_credit_score < 760 THEN '720-759'
            ELSE '760+'
        END,
        mp.loan_age
)
SELECT
    fico_cohort,
    loan_age,
    active_loans,
    cohort_upb,
    sdq_count,
    CAST(sdq_count * 100.0 / NULLIF(active_loans, 0) AS DECIMAL(7,4)) AS sdq_rate_count,
    CAST(sdq_upb * 100.0 / NULLIF(cohort_upb, 0) AS DECIMAL(7,4)) AS sdq_rate_upb
FROM cohort
WHERE loan_age <= 60  -- first 5 years
ORDER BY fico_cohort, loan_age;
```

---

## 9. Identifying Data Quality Issues

**Business Context**: Before any analysis, the data must be validated. These queries surface the most common data quality problems found in mortgage performance data.

```sql
-- ============================================================
-- DQ Check 1: Missing or invalid FICO scores
-- ============================================================
SELECT
    'Invalid FICO' AS dq_check,
    COUNT(*) AS affected_loans,
    SUM(current_upb) AS affected_upb,
    CAST(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM loan_origination)
         AS DECIMAL(5,2)) AS pct_of_portfolio
FROM loan_origination
WHERE orig_credit_score IS NULL
   OR orig_credit_score NOT BETWEEN 300 AND 850

UNION ALL

-- ============================================================
-- DQ Check 2: UPB reported as negative or unreasonably high
-- ============================================================
SELECT
    'Invalid UPB' AS dq_check,
    COUNT(*),
    SUM(ABS(current_upb)),
    CAST(COUNT(*) * 100.0 / (
        SELECT COUNT(*) FROM monthly_performance WHERE reporting_period = '2026-02-01'
    ) AS DECIMAL(5,2))
FROM monthly_performance
WHERE reporting_period = '2026-02-01'
  AND (current_upb < 0 OR current_upb > 10000000)

UNION ALL

-- ============================================================
-- DQ Check 3: Maturity date before origination date
-- ============================================================
SELECT
    'Bad Date Sequence' AS dq_check,
    COUNT(*),
    SUM(original_upb),
    CAST(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM loan_origination)
         AS DECIMAL(5,2))
FROM loan_origination
WHERE DATEADD(MONTH, original_term, origination_date) < origination_date
   OR origination_date > GETDATE()

UNION ALL

-- ============================================================
-- DQ Check 4: Status / delinquency mismatch
-- ============================================================
SELECT
    'Status Mismatch' AS dq_check,
    COUNT(*),
    SUM(current_upb),
    CAST(COUNT(*) * 100.0 / (
        SELECT COUNT(*) FROM monthly_performance WHERE reporting_period = '2026-02-01'
    ) AS DECIMAL(5,2))
FROM monthly_performance
WHERE reporting_period = '2026-02-01'
  AND (
      (loan_status = 'C' AND delinquency_status >= 3)   -- "Current" but 90+ DPD
   OR (loan_status = 'P' AND current_upb > 0)           -- "Prepaid" with remaining UPB
   OR (zero_balance_code IS NOT NULL AND current_upb > 0) -- Zero balance code but UPB > 0
  )

UNION ALL

-- ============================================================
-- DQ Check 5: Duplicate loan records in same period
-- ============================================================
SELECT
    'Duplicate Records' AS dq_check,
    COUNT(*) - COUNT(DISTINCT loan_id),
    0,
    CAST((COUNT(*) - COUNT(DISTINCT loan_id)) * 100.0 / COUNT(*)
         AS DECIMAL(5,2))
FROM monthly_performance
WHERE reporting_period = '2026-02-01'

UNION ALL

-- ============================================================
-- DQ Check 6: Orphaned performance records (no origination match)
-- ============================================================
SELECT
    'Orphaned Records' AS dq_check,
    COUNT(*),
    SUM(mp.current_upb),
    CAST(COUNT(*) * 100.0 / (
        SELECT COUNT(*) FROM monthly_performance WHERE reporting_period = '2026-02-01'
    ) AS DECIMAL(5,2))
FROM monthly_performance mp
LEFT JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND lo.loan_id IS NULL;
```

### Snowflake Variation for Date Functions

```sql
-- Snowflake uses CURRENT_DATE() and DATEADD with quoted date parts
SELECT *
FROM loan_origination
WHERE origination_date > CURRENT_DATE()
   OR DATEADD('MONTH', original_term, origination_date) < origination_date;
```

---

## 10. Top-N Delinquent Servicers / States

**Business Context**: Identifying which servicers or geographies have the worst performance helps focus remediation efforts. Servicer-level analysis can reveal operational deficiencies; state-level analysis highlights geographic risk concentrations.

### Top Delinquent Servicers

```sql
-- SQL Server
SELECT TOP 20
    lo.servicer_name,
    COUNT(DISTINCT mp.loan_id) AS active_loans,
    SUM(mp.current_upb) AS total_upb,
    -- 60+ DQ rate
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60_pct,
    -- 90+ DQ rate
    SUM(CASE WHEN mp.delinquency_status >= 3 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq90_pct,
    -- Foreclosure rate
    SUM(CASE WHEN mp.loan_status = 'F' THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS fc_pct,
    -- Average months in delinquency for DQ loans
    AVG(CASE WHEN mp.delinquency_status >= 1
             THEN mp.delinquency_status ELSE NULL END) AS avg_dq_severity
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.current_upb > 0
GROUP BY lo.servicer_name
HAVING COUNT(DISTINCT mp.loan_id) >= 100  -- minimum portfolio size
ORDER BY dq60_pct DESC;
```

### Top Delinquent States

```sql
SELECT
    lo.property_state,
    COUNT(DISTINCT mp.loan_id) AS active_loans,
    SUM(mp.current_upb) AS total_upb,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60_pct,
    SUM(CASE WHEN mp.delinquency_status >= 3 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq90_pct,
    -- Compare to portfolio average
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0)
    - (SELECT SUM(CASE WHEN delinquency_status >= 2 THEN current_upb ELSE 0 END)
              * 100.0 / NULLIF(SUM(current_upb), 0)
       FROM monthly_performance
       WHERE reporting_period = '2026-02-01' AND current_upb > 0)
        AS dq60_vs_portfolio_avg
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01' AND mp.current_upb > 0
GROUP BY lo.property_state
ORDER BY dq60_pct DESC;
```

**Snowflake**: Replace `TOP 20` with `LIMIT 20`. The rest of the syntax is compatible.

---

## 11. Monthly Performance Trend

**Business Context**: Tracking KPIs over time reveals whether portfolio health is improving or deteriorating. Time series data is the foundation for trend dashboards and early warning systems.

```sql
-- 12-month performance trend with MoM change
WITH monthly_kpis AS (
    SELECT
        mp.reporting_period,
        COUNT(DISTINCT mp.loan_id) AS active_loans,
        SUM(mp.current_upb) AS total_upb,
        -- Delinquency
        SUM(CASE WHEN mp.delinquency_status >= 1 THEN mp.current_upb ELSE 0 END)
            * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq30_pct,
        SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
            * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60_pct,
        SUM(CASE WHEN mp.delinquency_status >= 3 THEN mp.current_upb ELSE 0 END)
            * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq90_pct,
        -- Weighted average coupon
        SUM(mp.current_interest_rate * mp.current_upb) /
            NULLIF(SUM(mp.current_upb), 0) AS wac,
        -- Modifications
        SUM(CASE WHEN mp.modification_flag = 'Y' THEN 1 ELSE 0 END) AS modified_count,
        -- Losses
        SUM(ISNULL(mp.net_loss_amount, 0)) AS monthly_net_loss
    FROM monthly_performance mp
    WHERE mp.reporting_period BETWEEN '2025-03-01' AND '2026-02-01'
      AND mp.current_upb > 0
    GROUP BY mp.reporting_period
)
SELECT
    reporting_period,
    active_loans,
    total_upb,
    dq30_pct,
    dq60_pct,
    dq90_pct,
    wac,
    modified_count,
    monthly_net_loss,
    -- Cumulative loss
    SUM(monthly_net_loss) OVER (ORDER BY reporting_period
                                ROWS UNBOUNDED PRECEDING) AS cumulative_net_loss,
    -- MoM changes
    dq60_pct - LAG(dq60_pct) OVER (ORDER BY reporting_period)
        AS dq60_mom_change,
    total_upb - LAG(total_upb) OVER (ORDER BY reporting_period)
        AS upb_mom_change,
    -- 3-month moving average of DQ
    AVG(dq60_pct) OVER (ORDER BY reporting_period
                        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
        AS dq60_3mo_avg
FROM monthly_kpis
ORDER BY reporting_period;
```

---

## 12. Bonus: Comprehensive Pool Comparison Query

**Business Context**: Compare multiple pools or deals side by side — a frequent request from portfolio managers evaluating relative value or assessing which pools need attention.

```sql
SELECT
    lp.pool_id,
    d.deal_name,
    d.closing_date,
    -- Size
    COUNT(DISTINCT mp.loan_id) AS loan_count,
    SUM(mp.current_upb) AS current_upb,
    SUM(mp.current_upb) / NULLIF(d.original_balance, 0) AS pool_factor,
    -- Credit profile
    SUM(lo.orig_credit_score * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wa_fico,
    SUM(lo.orig_ltv * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wa_oltv,
    SUM(mp.current_interest_rate * mp.current_upb) /
        NULLIF(SUM(mp.current_upb), 0) AS wac,
    -- Performance
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60_pct,
    SUM(CASE WHEN mp.delinquency_status >= 3 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS sdq_pct,
    -- Concentration: top state
    MAX(state_conc.top_state_pct) AS top_state_concentration,
    -- Modification %
    SUM(CASE WHEN mp.modification_flag = 'Y' THEN 1.0 ELSE 0 END)
        * 100.0 / NULLIF(COUNT(*), 0) AS modification_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
JOIN loan_pool_mapping lp ON mp.loan_id = lp.loan_id
JOIN deal d ON lp.pool_id = d.pool_id
LEFT JOIN (
    -- Subquery: top state concentration per pool
    SELECT
        lp2.pool_id,
        MAX(state_upb_pct) AS top_state_pct
    FROM (
        SELECT
            lp2.pool_id,
            lo2.property_state,
            SUM(mp2.current_upb) * 100.0 /
                NULLIF(SUM(SUM(mp2.current_upb)) OVER (PARTITION BY lp2.pool_id), 0)
                AS state_upb_pct
        FROM monthly_performance mp2
        JOIN loan_origination lo2 ON mp2.loan_id = lo2.loan_id
        JOIN loan_pool_mapping lp2 ON mp2.loan_id = lp2.loan_id
        WHERE mp2.reporting_period = '2026-02-01' AND mp2.current_upb > 0
        GROUP BY lp2.pool_id, lo2.property_state
    ) sub
    GROUP BY sub.pool_id
) state_conc ON lp.pool_id = state_conc.pool_id
WHERE mp.reporting_period = '2026-02-01' AND mp.current_upb > 0
GROUP BY lp.pool_id, d.deal_name, d.closing_date, d.original_balance
ORDER BY SUM(mp.current_upb) DESC;
```

---

## Common Interview Questions & Answers

### Q1: How would you calculate CPR if the data only gives you beginning and ending UPB, with no prepayment flag?

**A:** If there is no explicit prepayment flag, you can derive prepayments from the UPB rollforward:

```
Prepayments = Beginning_UPB - Ending_UPB - Scheduled_Principal - Losses
```

If scheduled principal is also not available, you can estimate it from the amortization schedule using the loan's interest rate, remaining term, and beginning UPB. Then:

```
SMM = Prepayments / (Beginning_UPB - Scheduled_Principal)
CPR = 1 - (1 - SMM)^12
```

The key concern is distinguishing voluntary prepayments from involuntary payoffs (defaults/liquidations). If loss data is available, subtract it. If not, your CPR will be overstated by the default rate, producing a "total termination rate" rather than a pure prepayment rate.

### Q2: What is a transition matrix and why is it important for MBS analysis?

**A:** A transition matrix is a grid showing the probability that a loan in delinquency state X will move to state Y in the next period. For example, a loan that is 30 DPD has some probability of curing (returning to current), staying at 30 DPD, rolling to 60 DPD, or prepaying.

It is important because:
- **Loss forecasting**: By chaining transition probabilities forward, you can project future defaults and losses. This is the foundation of Markov chain-based credit models.
- **Servicer evaluation**: A servicer with lower roll rates and higher cure rates is performing better.
- **Stress testing**: You can shock transition probabilities (e.g., increase roll rates by 20%) to see impact on portfolio losses.
- **Early warning**: If the 30-to-60 roll rate spikes, it signals that early-stage delinquencies are hardening into serious defaults.

### Q3: How do you handle SQL performance when calculating vintage curves across millions of loans and hundreds of months?

**A:** Several optimization strategies:

1. **Pre-aggregate**: Build a monthly summary table with one row per (vintage, loan_age) that contains counts and UPB by delinquency status. Run the expensive aggregation once during the ETL, not at query time.
2. **Partition the performance table** by `reporting_period`. This ensures that queries scanning specific months only read relevant partitions.
3. **Use columnstore indexes** (SQL Server) for the fact table — analytical queries (SUM, COUNT, GROUP BY) are dramatically faster on columnstore.
4. **Avoid self-joins when possible**: Use `LAG()` window functions instead of joining the performance table to itself for prior-month comparisons.
5. **Materialize the vintage dimension**: Add `origination_year` and `origination_quarter` directly to the performance table (denormalize) so you do not need to join to the origination table for every query.
6. **In Snowflake**: Leverage clustering keys on `(reporting_period, loan_id)` and use the result cache for repeated queries.

### Q4: Write a query to find loans that have been in foreclosure for more than 18 months.

**A:**

```sql
-- SQL Server
SELECT
    mp.loan_id,
    mp.foreclosure_date,
    DATEDIFF(MONTH, mp.foreclosure_date, mp.reporting_period) AS months_in_fc,
    mp.current_upb,
    lo.property_state,
    lo.servicer_name
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.foreclosure_date IS NOT NULL
  AND mp.disposition_date IS NULL          -- not yet liquidated
  AND DATEDIFF(MONTH, mp.foreclosure_date, mp.reporting_period) > 18
ORDER BY DATEDIFF(MONTH, mp.foreclosure_date, mp.reporting_period) DESC;

-- Snowflake
SELECT
    mp.loan_id,
    mp.foreclosure_date,
    DATEDIFF('MONTH', mp.foreclosure_date, mp.reporting_period) AS months_in_fc,
    mp.current_upb,
    lo.property_state,
    lo.servicer_name
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.foreclosure_date IS NOT NULL
  AND mp.disposition_date IS NULL
  AND DATEDIFF('MONTH', mp.foreclosure_date, mp.reporting_period) > 18
ORDER BY months_in_fc DESC;
```

### Q5: How would you write a query to detect loans that "cured" (went from delinquent back to current) and then re-defaulted?

**A:**

```sql
WITH loan_timeline AS (
    SELECT
        loan_id,
        reporting_period,
        delinquency_status,
        LAG(delinquency_status) OVER (
            PARTITION BY loan_id ORDER BY reporting_period
        ) AS prev_status,
        -- Flag: was ever 90+ DPD before this month
        MAX(CASE WHEN delinquency_status >= 3 THEN 1 ELSE 0 END) OVER (
            PARTITION BY loan_id ORDER BY reporting_period
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS was_ever_sdq
    FROM monthly_performance
),
cures AS (
    -- Identify cure events: 90+ -> Current
    SELECT
        loan_id,
        reporting_period AS cure_date
    FROM loan_timeline
    WHERE prev_status >= 3
      AND delinquency_status = 0
),
redefaults AS (
    -- After a cure, did the loan go back to 90+?
    SELECT
        mp.loan_id,
        c.cure_date,
        MIN(mp.reporting_period) AS redefault_date,
        DATEDIFF(MONTH, c.cure_date, MIN(mp.reporting_period)) AS months_to_redefault
    FROM monthly_performance mp
    INNER JOIN cures c ON mp.loan_id = c.loan_id
        AND mp.reporting_period > c.cure_date
    WHERE mp.delinquency_status >= 3
    GROUP BY mp.loan_id, c.cure_date
)
SELECT
    r.loan_id,
    r.cure_date,
    r.redefault_date,
    r.months_to_redefault,
    lo.orig_credit_score,
    lo.property_state,
    lo.servicer_name,
    mp.current_upb
FROM redefaults r
JOIN loan_origination lo ON r.loan_id = lo.loan_id
JOIN monthly_performance mp ON r.loan_id = mp.loan_id
    AND mp.reporting_period = r.redefault_date
ORDER BY r.months_to_redefault;
```

This pattern is called "re-default analysis" and is critical for evaluating the effectiveness of loan modifications — a high re-default rate suggests modifications are not providing lasting relief.

### Q6: What is the difference between `ROWS` and `RANGE` in window frame specifications, and when does it matter for mortgage analytics?

**A:** `ROWS` operates on physical row positions — `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` always looks at exactly 3 rows regardless of values. `RANGE` operates on logical value ranges — `RANGE BETWEEN 2 PRECEDING AND CURRENT ROW` includes all rows with values within 2 of the current row's value.

In mortgage analytics, this matters when:
- **Calculating moving averages of monthly metrics**: Use `ROWS` because you want exactly N months of data, and there is one row per month.
- **Cumulative sums over time**: Both work if there is exactly one row per period, but `ROWS UNBOUNDED PRECEDING` is safer and more performant because the database does not need to evaluate value equality.
- **If months are missing**: `RANGE` could give unexpected results (it would skip the gap), while `ROWS` would include whatever the next physical row is, which might be a different month than expected. In this case, you should fill in missing months with zero-value rows first, then use `ROWS`.

For performance, `ROWS` is almost always faster because the optimizer can use a simple offset rather than value comparison.

---

## Tips

1. **Always use `NULLIF` in denominators.** Division by zero is the most common runtime error in MBS analytics. Wrap every denominator with `NULLIF(expression, 0)`.

2. **Be explicit about UPB > 0 filters.** Terminated loans (prepaid, liquidated) may still have rows in the performance table with UPB = 0. Always filter `current_upb > 0` when counting active loans or computing weighted averages.

3. **Use LAG() instead of self-joins where possible.** For prior-month comparisons, `LAG(column) OVER (PARTITION BY loan_id ORDER BY reporting_period)` is cleaner and usually faster than joining the table to itself.

4. **Index on (loan_id, reporting_period).** This is the natural key for the performance table and supports virtually every analytical query. Make it a clustered index or clustering key.

5. **Know the syntax differences between SQL Server and Snowflake.** The most common differences:
   - `ISNULL` (SQL Server) vs. `IFNULL` (Snowflake) — or use `COALESCE` for portability.
   - `DATEADD(MONTH, -1, date)` (SQL Server) vs. `DATEADD('MONTH', -1, date)` (Snowflake).
   - `TOP N` (SQL Server) vs. `LIMIT N` (Snowflake).
   - `POWER` (SQL Server) vs. `POW` (Snowflake) — though Snowflake also supports `POWER`.
   - `GETDATE()` (SQL Server) vs. `CURRENT_TIMESTAMP()` (Snowflake).

6. **Use CTEs for readability.** MBS queries are inherently complex. Break them into named CTEs that each do one thing. This makes the query self-documenting and easier to debug.

7. **Validate your CPR calculation against published data.** If you are working with agency MBS, Freddie Mac and Fannie Mae publish pool-level factors and speeds. Compare your calculated CPR against the published values to verify correctness.

8. **Watch for lookback bias in vintage curves.** Younger vintages will always appear to perform better because they have not had time to season. Compare vintages at the same loan age, not at the same calendar date.

9. **Materialize expensive aggregations.** If a query takes more than a few seconds interactively, it should be pre-computed in an ETL process and stored in a reporting table. Dashboards should never run multi-minute queries.

10. **Test edge cases.** Loans with zero UPB, loans with NULL dates, loans that appear for only one month, pools with a single loan — these edge cases break fragile queries. Build test cases for them.

---
