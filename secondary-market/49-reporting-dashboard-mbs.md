# 49. Reporting & Dashboard Design for MBS

[Back to Secondary Market Index](./README.md)

---

## Overview

Reporting and dashboard design in the mortgage-backed securities space is a critical function that bridges raw loan-level data with actionable insights for portfolio managers, risk analysts, investors, and regulators. A senior data engineer must understand not just how to build pipelines, but what the business needs to see, how metrics are calculated, and how to deliver reports reliably at scale. This topic covers the key reports, KPIs, dashboard design patterns, drill-down capabilities, and tooling used in MBS portfolio monitoring.

---

## Key Concepts

### 1. Key Reports for MBS

#### Portfolio Summary Report

The highest-level view of an MBS portfolio or book of business.

| Metric | Description |
|---|---|
| Total UPB | Sum of current unpaid principal balance across all active loans |
| Loan Count | Number of active loans |
| WAC (Weighted Average Coupon) | UPB-weighted average interest rate |
| WAM (Weighted Average Maturity) | UPB-weighted average remaining term in months |
| WALA (Weighted Average Loan Age) | UPB-weighted average loan age |
| WA FICO | UPB-weighted average credit score at origination |
| WA LTV | UPB-weighted average loan-to-value ratio |
| Geographic Concentration | Top 5 states by UPB |
| Product Mix | Fixed vs. ARM, 30-year vs. 15-year |

```sql
-- Portfolio summary report
SELECT
    reporting_period,
    COUNT(DISTINCT loan_id) AS active_loans,
    SUM(current_upb) AS total_upb,
    -- Weighted Average Coupon
    SUM(current_interest_rate * current_upb) / NULLIF(SUM(current_upb), 0) AS wac,
    -- Weighted Average Maturity (remaining months)
    SUM(remaining_term * current_upb) / NULLIF(SUM(current_upb), 0) AS wam,
    -- Weighted Average Loan Age
    SUM(loan_age * current_upb) / NULLIF(SUM(current_upb), 0) AS wala,
    -- Weighted Average FICO
    SUM(orig_credit_score * current_upb) / NULLIF(SUM(current_upb), 0) AS wa_fico,
    -- Weighted Average LTV
    SUM(orig_ltv * current_upb) / NULLIF(SUM(current_upb), 0) AS wa_ltv
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.current_upb > 0
GROUP BY mp.reporting_period;
```

#### Delinquency Report

Tracks the health of the portfolio by delinquency bucket.

```sql
-- Delinquency report by bucket (count and UPB)
SELECT
    reporting_period,
    CASE delinquency_status
        WHEN 0 THEN 'Current'
        WHEN 1 THEN '30 DPD'
        WHEN 2 THEN '60 DPD'
        WHEN 3 THEN '90 DPD'
        WHEN 4 THEN '120+ DPD'
        WHEN 'F' THEN 'Foreclosure'
        WHEN 'R' THEN 'REO'
        ELSE 'Other'
    END AS delinquency_bucket,
    COUNT(*) AS loan_count,
    SUM(current_upb) AS bucket_upb,
    CAST(SUM(current_upb) * 100.0 /
         SUM(SUM(current_upb)) OVER (PARTITION BY reporting_period)
         AS DECIMAL(7,4)) AS pct_of_total_upb
FROM monthly_performance
WHERE reporting_period = '2026-02-01'
GROUP BY reporting_period, delinquency_status
ORDER BY
    CASE delinquency_status
        WHEN 0 THEN 0 WHEN 1 THEN 1 WHEN 2 THEN 2
        WHEN 3 THEN 3 WHEN 4 THEN 4 WHEN 'F' THEN 5
        WHEN 'R' THEN 6 ELSE 7
    END;
```

#### Prepayment Report

Measures voluntary prepayment speed, critical for investors in pass-through securities.

```sql
-- Monthly prepayment report: SMM and CPR by pool
WITH pool_data AS (
    SELECT
        lp.pool_id,
        mp.reporting_period,
        SUM(mp.current_upb) AS ending_upb,
        SUM(prev.current_upb) AS beginning_upb,
        SUM(mp.scheduled_principal) AS scheduled_principal,
        SUM(
            CASE WHEN mp.zero_balance_code IN ('01')  -- Prepaid in full
                 THEN prev.current_upb
                 ELSE ISNULL(mp.curtailment_amount, 0)
            END
        ) AS prepayment_amount
    FROM monthly_performance mp
    JOIN monthly_performance prev
        ON mp.loan_id = prev.loan_id
        AND mp.reporting_period = DATEADD(MONTH, 1, prev.reporting_period)
    JOIN loan_pool_mapping lp ON mp.loan_id = lp.loan_id
    WHERE mp.reporting_period = '2026-02-01'
    GROUP BY lp.pool_id, mp.reporting_period
)
SELECT
    pool_id,
    reporting_period,
    beginning_upb,
    prepayment_amount,
    -- SMM = Prepayment / (Beginning UPB - Scheduled Principal)
    prepayment_amount / NULLIF(beginning_upb - scheduled_principal, 0) AS smm,
    -- CPR = 1 - (1 - SMM)^12
    1.0 - POWER(
        1.0 - prepayment_amount / NULLIF(beginning_upb - scheduled_principal, 0),
        12
    ) AS cpr
FROM pool_data
ORDER BY pool_id;
```

#### Loss Report

Tracks realized losses from liquidations, short sales, and charge-offs.

```sql
-- Monthly loss report
SELECT
    mp.reporting_period,
    lo.origination_year,
    COUNT(*) AS liquidation_count,
    SUM(mp.loss_amount) AS gross_loss,
    SUM(mp.net_loss_amount) AS net_loss,
    SUM(mp.loss_upb) AS loss_upb,
    -- Loss severity = Net Loss / Loss UPB
    SUM(mp.net_loss_amount) / NULLIF(SUM(mp.loss_upb), 0) AS loss_severity,
    -- Cumulative losses
    SUM(SUM(mp.net_loss_amount)) OVER (
        PARTITION BY lo.origination_year
        ORDER BY mp.reporting_period
    ) AS cumulative_net_loss
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.zero_balance_code IN ('03', '06', '09')  -- liquidation codes
  AND mp.reporting_period BETWEEN '2025-03-01' AND '2026-02-01'
GROUP BY mp.reporting_period, lo.origination_year
ORDER BY mp.reporting_period, lo.origination_year;
```

#### Vintage Analysis Report

Compares performance of loans originated in different time periods, the single most important analytical lens in MBS.

```sql
-- Vintage curve: Cumulative default rate by origination year and loan age
WITH vintage AS (
    SELECT
        YEAR(lo.origination_date) AS vintage,
        mp.loan_age,
        COUNT(DISTINCT mp.loan_id) AS active_loans,
        SUM(CASE WHEN mp.delinquency_status >= 3 THEN 1 ELSE 0 END) AS seriously_delinquent,
        SUM(CASE WHEN mp.zero_balance_code IN ('03','06','09') THEN 1 ELSE 0 END) AS defaulted
    FROM monthly_performance mp
    JOIN loan_origination lo ON mp.loan_id = lo.loan_id
    GROUP BY YEAR(lo.origination_date), mp.loan_age
)
SELECT
    vintage,
    loan_age,
    active_loans,
    seriously_delinquent,
    CAST(seriously_delinquent * 100.0 / NULLIF(active_loans, 0) AS DECIMAL(7,4)) AS sdq_rate,
    SUM(defaulted) OVER (PARTITION BY vintage ORDER BY loan_age) AS cumulative_defaults
FROM vintage
ORDER BY vintage, loan_age;
```

#### Stratification Tables

Break the portfolio into segments across multiple dimensions.

```sql
-- Stratification by FICO band
SELECT
    CASE
        WHEN lo.orig_credit_score < 620  THEN '< 620'
        WHEN lo.orig_credit_score < 660  THEN '620-659'
        WHEN lo.orig_credit_score < 700  THEN '660-699'
        WHEN lo.orig_credit_score < 740  THEN '700-739'
        WHEN lo.orig_credit_score < 780  THEN '740-779'
        ELSE '780+'
    END AS fico_band,
    COUNT(*) AS loan_count,
    SUM(mp.current_upb) AS total_upb,
    CAST(SUM(mp.current_upb) * 100.0 / SUM(SUM(mp.current_upb)) OVER ()
         AS DECIMAL(5,2)) AS pct_upb,
    SUM(mp.current_interest_rate * mp.current_upb) / NULLIF(SUM(mp.current_upb), 0) AS wac,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60plus_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.current_upb > 0
GROUP BY
    CASE
        WHEN lo.orig_credit_score < 620  THEN '< 620'
        WHEN lo.orig_credit_score < 660  THEN '620-659'
        WHEN lo.orig_credit_score < 700  THEN '660-699'
        WHEN lo.orig_credit_score < 740  THEN '700-739'
        WHEN lo.orig_credit_score < 780  THEN '740-779'
        ELSE '780+'
    END
ORDER BY MIN(lo.orig_credit_score);
```

---

### 2. Dashboard Design for Portfolio Monitoring

#### Dashboard Layout Principles

A well-designed MBS dashboard follows the **inverted pyramid** approach:

```
+----------------------------------------------------------+
|                  EXECUTIVE SUMMARY                        |
|  Total UPB | Loan Count | 60+ DQ% | CPR | CDR | Losses  |
+----------------------------------------------------------+
|  TREND CHARTS (12-month rolling)                          |
|  [DQ Trend] [Prepayment Trend] [Loss Trend]              |
+----------------------------------------------------------+
|  STRATIFICATION / BREAKDOWN                               |
|  [By Vintage] [By State] [By Product] [By Servicer]      |
+----------------------------------------------------------+
|  DETAIL / DRILL-DOWN                                      |
|  [Loan-level search] [Exception list] [Watch list]        |
+----------------------------------------------------------+
```

#### Design Best Practices

1. **KPIs at the top**: Large, bold numbers with MoM change arrows. Green/red color coding for improvement/deterioration.
2. **Consistent time axis**: All trend charts should share the same x-axis (reporting period) and cover the same date range.
3. **Benchmark lines**: Show historical averages or industry benchmarks on charts so users can contextualize current performance.
4. **Filters as first-class citizens**: Global filters for reporting period, pool/deal, vintage, servicer, and state should persist across all dashboard tabs.
5. **Responsive drill-down**: Clicking on a bar in a vintage chart should filter other visualizations to that vintage.
6. **Avoid chart junk**: No 3D charts, no excessive colors. Use a consistent, muted color palette with one accent color for "alert" states.
7. **Data freshness indicator**: Always show when the data was last loaded and which reporting period is current.

---

### 3. Key Performance Indicators (KPIs)

#### Delinquency KPIs

| KPI | Formula | Typical Range |
|---|---|---|
| **30+ DQ%** | UPB of 30+ DPD loans / Total UPB | 2-5% (prime), 10-20% (subprime) |
| **60+ DQ%** | UPB of 60+ DPD loans / Total UPB | 1-3% (prime) |
| **90+ DQ%** (SDQ) | UPB of 90+ DPD + FC + REO / Total UPB | 0.5-2% (prime) |
| **Transition Rate** | % of 30 DPD loans rolling to 60 DPD | 30-50% typical |
| **Cure Rate** | % of 30 DPD loans returning to Current | 50-70% typical |

#### Prepayment KPIs

| KPI | Formula | Description |
|---|---|---|
| **SMM** | Prepayment / (Beg UPB - Sched Principal) | Single Monthly Mortality — monthly prepayment rate |
| **CPR** | 1 - (1 - SMM)^12 | Conditional Prepayment Rate — annualized SMM |
| **PSA Speed** | CPR / (0.2% * min(loan_age, 30)) * 100 | Prepayment as % of PSA benchmark model |

#### Default & Loss KPIs

| KPI | Formula | Description |
|---|---|---|
| **CDR** | 1 - (1 - MDR)^12 | Conditional Default Rate — annualized monthly default rate |
| **MDR** | Liquidation UPB / Beginning UPB | Monthly Default Rate |
| **Loss Severity** | Net Loss / Liquidation UPB | Average loss per defaulted dollar |
| **Cumulative Loss** | Total Net Losses / Original Pool Balance | Total losses as % of original deal size |
| **CNL** | Same as cumulative loss | Cumulative Net Loss — most-watched metric for ABS investors |

```sql
-- KPI summary query for dashboard top-line metrics
WITH kpi_data AS (
    SELECT
        mp.reporting_period,
        SUM(mp.current_upb) AS total_upb,
        COUNT(DISTINCT mp.loan_id) AS loan_count,
        -- Delinquency
        SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END) AS dq60_upb,
        SUM(CASE WHEN mp.delinquency_status >= 3 THEN mp.current_upb ELSE 0 END) AS dq90_upb,
        -- Prepayment (requires prior month join — simplified here)
        SUM(CASE WHEN mp.zero_balance_code = '01' THEN prev.current_upb ELSE 0 END) AS prepay_upb,
        SUM(prev.current_upb) AS beg_upb,
        SUM(mp.scheduled_principal) AS sched_prin,
        -- Losses
        SUM(CASE WHEN mp.zero_balance_code IN ('03','06','09')
                 THEN mp.net_loss_amount ELSE 0 END) AS net_loss,
        SUM(CASE WHEN mp.zero_balance_code IN ('03','06','09')
                 THEN prev.current_upb ELSE 0 END) AS default_upb
    FROM monthly_performance mp
    LEFT JOIN monthly_performance prev
        ON mp.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, mp.reporting_period)
    WHERE mp.reporting_period = '2026-02-01'
    GROUP BY mp.reporting_period
)
SELECT
    reporting_period,
    total_upb,
    loan_count,
    -- DQ metrics
    dq60_upb * 100.0 / NULLIF(total_upb, 0) AS dq60_pct,
    dq90_upb * 100.0 / NULLIF(total_upb, 0) AS dq90_pct,
    -- SMM & CPR
    prepay_upb / NULLIF(beg_upb - sched_prin, 0) AS smm,
    1.0 - POWER(1.0 - prepay_upb / NULLIF(beg_upb - sched_prin, 0), 12) AS cpr,
    -- MDR & CDR
    default_upb / NULLIF(beg_upb, 0) AS mdr,
    1.0 - POWER(1.0 - default_upb / NULLIF(beg_upb, 0), 12) AS cdr,
    -- Loss severity
    net_loss / NULLIF(default_upb, 0) AS loss_severity
FROM kpi_data;
```

---

### 4. Drill-Down Capabilities

Drill-down is what separates a useful dashboard from a static report. Users need to move from summary to detail seamlessly.

#### Drill-Down Dimensions

| Dimension | Use Case |
|---|---|
| **Vintage** | Compare 2020 originations vs. 2023 — did underwriting tighten? |
| **State / MSA** | Geographic concentration risk, state-level economic sensitivity |
| **Product Type** | Fixed 30-year vs. ARM vs. 15-year — different prepayment and default behavior |
| **Servicer** | Compare delinquency rates across servicers — servicer quality matters |
| **FICO Band** | Risk segmentation — subprime vs. prime performance |
| **LTV Band** | Equity position drives default and loss severity |
| **Occupancy** | Owner-occupied vs. investor properties have very different risk profiles |
| **Channel** | Retail vs. wholesale vs. correspondent origination |
| **Deal / Pool** | Drill from portfolio to specific securitization |
| **Loan-Level** | Ultimate granularity — individual loan payment history |

#### Implementation Pattern

```sql
-- Parameterized drill-down query: Delinquency by vintage, then by state
-- Level 1: By Vintage
SELECT
    YEAR(lo.origination_date) AS vintage,
    SUM(mp.current_upb) AS total_upb,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.current_upb > 0
GROUP BY YEAR(lo.origination_date)
ORDER BY vintage;

-- Level 2: User clicks on vintage 2023 — drill into state breakdown
SELECT
    lo.property_state,
    COUNT(*) AS loan_count,
    SUM(mp.current_upb) AS total_upb,
    SUM(CASE WHEN mp.delinquency_status >= 2 THEN mp.current_upb ELSE 0 END)
        * 100.0 / NULLIF(SUM(mp.current_upb), 0) AS dq60_pct
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND mp.current_upb > 0
  AND YEAR(lo.origination_date) = 2023   -- filtered by user click
GROUP BY lo.property_state
ORDER BY dq60_pct DESC;

-- Level 3: User clicks on Florida — drill to loan list
SELECT
    mp.loan_id,
    lo.origination_date,
    lo.orig_credit_score,
    lo.orig_ltv,
    mp.current_upb,
    mp.current_interest_rate,
    mp.delinquency_status,
    mp.loan_age
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND YEAR(lo.origination_date) = 2023
  AND lo.property_state = 'FL'
  AND mp.delinquency_status >= 2
ORDER BY mp.current_upb DESC;
```

---

### 5. Reporting Tools & Technology

#### Tool Comparison

| Tool | Strengths | Limitations | Best For |
|---|---|---|---|
| **SSRS (SQL Server Reporting Services)** | Tight SQL Server integration, paginated reports, subscriptions, pixel-perfect formatting | Dated UI, limited interactivity, on-prem focus | Regulatory reports, investor statements, scheduled PDF delivery |
| **Tableau** | Best-in-class visualization, fast exploration, robust drill-down, large community | Expensive licensing, can struggle with very large datasets if not using extracts | Executive dashboards, ad hoc analysis, portfolio monitoring |
| **Power BI** | Microsoft ecosystem integration, affordable, DAX for complex calculations, paginated reports via Power BI Report Builder | Row limits in shared capacity, DAX learning curve, governance complexity | Enterprise reporting with O365 shops, self-service analytics |
| **Looker** | Strong data modeling layer (LookML), governed metrics, embedded analytics | Requires LookML expertise, Google Cloud aligned | Tech-forward organizations, embedded investor portals |
| **Apache Superset** | Open-source, SQL-native, lightweight | Less polish, smaller community for enterprise support | Cost-sensitive teams, internal dashboards |

#### Semantic Layer Design

Regardless of tool, a semantic layer (data mart or metrics layer) should sit between raw data and dashboards:

```
Raw Loan Data --> Staging --> Data Warehouse --> Reporting Data Mart --> Dashboard Tool
                                                       |
                                          Pre-aggregated tables:
                                          - monthly_pool_summary
                                          - vintage_performance
                                          - stratification_cache
                                          - kpi_timeseries
```

```sql
-- Pre-aggregated reporting mart: monthly pool summary
CREATE TABLE rpt_monthly_pool_summary (
    reporting_period   DATE,
    pool_id            VARCHAR(20),
    active_loan_count  INT,
    total_upb          DECIMAL(18,2),
    wac                DECIMAL(7,5),
    wam                DECIMAL(7,2),
    wa_fico            DECIMAL(7,2),
    wa_ltv             DECIMAL(7,2),
    dq30_pct           DECIMAL(7,4),
    dq60_pct           DECIMAL(7,4),
    dq90_pct           DECIMAL(7,4),
    smm                DECIMAL(10,8),
    cpr                DECIMAL(10,8),
    mdr                DECIMAL(10,8),
    cdr                DECIMAL(10,8),
    loss_severity      DECIMAL(7,4),
    monthly_net_loss   DECIMAL(18,2),
    cumulative_net_loss DECIMAL(18,2),
    load_timestamp     DATETIME DEFAULT GETDATE(),
    PRIMARY KEY (reporting_period, pool_id)
);
```

---

### 6. Automated Report Generation

#### Scheduled Report Pipeline

```
1. Data Load Complete (trigger)
       |
       v
2. DQ Validation Passes
       |
       v
3. Reporting Mart Refresh (stored procs / dbt models)
       |
       v
4. Report Generation
       |
       +---> SSRS subscriptions --> PDF/Excel to email
       +---> Tableau extract refresh --> Dashboard auto-update
       +---> Power BI dataset refresh --> Scheduled delivery
       +---> Custom scripts --> CSV/XML to SFTP for investors
       |
       v
5. Delivery Confirmation & Logging
```

#### Key Automation Considerations

- **Idempotency**: Report generation should be re-runnable. If the same period is processed twice, results should be identical.
- **Dependency management**: Reports should only generate after upstream data is validated. Use orchestration tools (Airflow, Azure Data Factory, Control-M).
- **Version control**: Report definitions (SSRS .rdl files, Tableau .twb, Power BI .pbix) should be in source control.
- **Environment parity**: Dev, UAT, and Prod report environments should use the same definitions but point to different data sources.

```sql
-- Audit table for report generation tracking
CREATE TABLE report_generation_log (
    log_id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    report_name      VARCHAR(200),
    reporting_period DATE,
    generation_start DATETIME,
    generation_end   DATETIME,
    status           VARCHAR(20),  -- 'SUCCESS', 'FAILED', 'IN_PROGRESS'
    row_count        INT,
    file_path        VARCHAR(500),
    recipient_list   VARCHAR(MAX),
    error_message    VARCHAR(MAX),
    created_by       VARCHAR(100) DEFAULT SYSTEM_USER
);
```

---

### 7. Investor Reporting Requirements

Investor reports are contractually mandated and have strict format, content, and timing requirements.

#### Common Investor Report Types

| Report | Frequency | Content | Recipient |
|---|---|---|---|
| **Remittance Report** | Monthly | Pool factor, distributions (P&I, losses), advances | Trustee, investors |
| **Loan-Level Performance** | Monthly | Loan-by-loan status, UPB, delinquency, modifications | Rating agencies, investors |
| **Exception Report** | Monthly | Loans triggering deal covenants (concentration limits, DQ thresholds) | Trustee, deal manager |
| **Servicer Certificate** | Monthly | Servicer attestation of data accuracy and compliance | Trustee |
| **Trustee Report** | Monthly | Official pool-level balances, waterfall distributions | All bondholders |
| **10-D / 10-K Filing** | Periodic | SEC-required disclosures for registered securities | SEC, public investors |

#### CREFC (CRE Finance Council) / MISMO Standards

For RMBS, data delivery often follows MISMO (Mortgage Industry Standards Maintenance Organization) XML schemas. Data engineers must map internal data models to these standardized formats.

```sql
-- Generate investor reporting data in required format
SELECT
    mp.loan_id                       AS [LoanIdentifier],
    mp.reporting_period              AS [ReportingPeriod],
    mp.current_upb                   AS [CurrentUPB],
    mp.delinquency_status            AS [DelinquencyStatus],
    CASE mp.loan_status
        WHEN 'C' THEN 'Current'
        WHEN 'P' THEN 'Prepaid'
        WHEN 'T' THEN 'ThirdPartyAcquisition'
        WHEN 'S' THEN 'ShortSale'
        WHEN 'R' THEN 'REO'
        WHEN 'F' THEN 'Foreclosure'
    END                              AS [LoanStatusDescription],
    mp.scheduled_principal           AS [ScheduledPrincipal],
    mp.curtailment_amount            AS [CurtailmentAmount],
    mp.modification_flag             AS [ModificationFlag],
    mp.loss_amount                   AS [NetLossAmount],
    lo.orig_credit_score             AS [OriginationCreditScore],
    lo.orig_ltv                      AS [OriginationLTV],
    lo.property_state                AS [PropertyState],
    lo.property_type                 AS [PropertyType]
FROM monthly_performance mp
JOIN loan_origination lo ON mp.loan_id = lo.loan_id
JOIN loan_pool_mapping lp ON mp.loan_id = lp.loan_id
WHERE mp.reporting_period = '2026-02-01'
  AND lp.pool_id = 'CAS-2024-R01-G1'
ORDER BY mp.loan_id;
```

#### Waterfall Distribution Reporting

For structured MBS deals, the data engineer may need to support the cash flow waterfall — the rules governing how collections are distributed to different tranches.

```
Collections --> Senior Fees --> Senior Interest --> Senior Principal
            --> Mezzanine Interest --> Mezzanine Principal
            --> Subordinate Interest --> Subordinate Principal
            --> Residual / Excess Spread
```

The waterfall logic is typically implemented in a specialized deal engine, but the data engineer ensures the input data (collections, losses, prepayments) is accurate and timely.

---

### 8. Real-World Dashboard Examples

#### Dashboard 1: Portfolio Health Monitor

**Audience**: Portfolio Manager, Risk Team

**Layout**:
- **Row 1 (KPI Cards)**: Total UPB, Loan Count, 60+ DQ%, CPR, CDR, Loss Severity
- **Row 2 (Trend Charts)**: 12-month DQ% trend (line), CPR trend (line), Monthly Loss bar chart
- **Row 3 (Maps & Tables)**: Choropleth map of DQ% by state, Top 10 delinquent MSAs table
- **Row 4 (Vintage)**: Vintage curve chart (cumulative default by loan age, colored by vintage year)
- **Filters**: Reporting period (slider), Deal/Pool (multi-select), Servicer, Product Type

#### Dashboard 2: Servicer Scorecard

**Audience**: Servicer Oversight Team

**Layout**:
- **Row 1**: Servicer ranking table (DQ%, cure rate, roll rate, loss severity, modification rate)
- **Row 2**: Servicer comparison charts (selected servicer vs. portfolio average)
- **Row 3**: Trend for selected servicer (12-month DQ%, CPR, timeline to liquidation)
- **Row 4**: Exception list (loans exceeding foreclosure timeline benchmarks)
- **Filters**: Servicer (dropdown), Vintage, State

#### Dashboard 3: Investor Reporting Dashboard

**Audience**: Capital Markets, Investor Relations

**Layout**:
- **Row 1**: Deal-level summary (original balance, current factor, cumulative loss, credit enhancement remaining)
- **Row 2**: Tranche performance (each tranche's current balance, coverage ratio, expected maturity)
- **Row 3**: Collateral performance (DQ distribution, prepayment, loss severity)
- **Row 4**: Trigger/covenant status (are any deal triggers breached?)
- **Filters**: Deal, Reporting Period

---

## Common Interview Questions & Answers

### Q1: What are the most important KPIs you would put on an MBS portfolio dashboard, and why?

**A:** The top-line KPIs I would include are:

1. **60+ DQ%** — The earliest reliable signal of credit deterioration. 30-day delinquencies have high cure rates so they are noisy; 60+ is more predictive.
2. **CPR (Conditional Prepayment Rate)** — Drives duration and yield for investors. A spike in CPR means faster principal return, which is bad for premium bonds and good for discount bonds.
3. **CDR (Conditional Default Rate)** — Measures the rate of credit losses entering the pipeline. Combined with severity, it predicts cash flow shortfalls.
4. **Loss Severity** — How much is actually lost per defaulted loan. Driven by property values, foreclosure costs, and timelines.
5. **Cumulative Net Loss** — The ultimate scorecard for a deal. Investors and rating agencies track this against original projections.

I would show each with a MoM change indicator and a 12-month trend sparkline. Context is everything — a 5% CPR means nothing without knowing whether it was 4% or 8% last month.

### Q2: How would you design a reporting data mart for MBS performance analytics?

**A:** I would create a star schema optimized for the most common query patterns:

- **Fact table**: `fact_monthly_performance` — one row per loan per month, containing UPB, delinquency status, payment amounts, loss amounts, and pre-computed flags.
- **Dimension tables**: `dim_loan` (origination attributes), `dim_pool` (pool/deal attributes), `dim_servicer`, `dim_geography` (state, MSA, ZIP), `dim_date`.
- **Aggregate tables**: `agg_pool_monthly` (pre-computed pool-level KPIs), `agg_vintage_monthly` (vintage curve data), `agg_stratification` (pre-computed strats by FICO/LTV/state).
- **Incremental loading**: Each month, only the new reporting period is appended. Prior months are immutable unless a restatement occurs.
- **Partitioning**: Partition the fact table by `reporting_period` for efficient time-range queries.
- **Indexing**: Clustered index on `(loan_id, reporting_period)`, non-clustered indexes on common filter columns (pool_id, delinquency_status, property_state).

### Q3: A business user asks why the delinquency numbers on the dashboard do not match the trustee report. How do you investigate?

**A:** This is a common reconciliation issue. My investigation steps:

1. **Scope the difference**: Is it a count difference, a UPB difference, or both? How large is the variance?
2. **Check definitions**: The trustee may define "60+ DQ" differently (e.g., including vs. excluding foreclosure and REO). Align definitions first.
3. **Check timing**: Is the dashboard showing the same reporting period as the trustee report? Even a one-day lag in data refresh can cause discrepancies.
4. **Check population**: Are we including the same loans? The trustee report covers a specific pool. The dashboard might be filtering differently (e.g., including removed loans or excluding modifications).
5. **Run reconciliation queries**: Aggregate loan-level data for the exact pool and period, compare to trustee totals for UPB, loan count, and delinquency buckets. Identify the specific loans causing the difference.
6. **Check data corrections**: Was there a servicer restatement that the dashboard consumed but the trustee report predates (or vice versa)?
7. **Document and fix**: Once the root cause is found, document it, fix the mapping or logic, and add a reconciliation check to the automated DQ framework.

### Q4: How do you handle report performance when dashboards need to query billions of rows of loan-level data?

**A:** Several strategies:

1. **Pre-aggregation**: Build reporting marts with pre-computed metrics at the pool, vintage, and stratification level. Most dashboard views do not need loan-level data.
2. **Materialized views / indexed views**: For frequently-used aggregations that are too complex for simple tables.
3. **Partitioning**: Partition fact tables by reporting_period so queries for recent months only scan relevant partitions.
4. **Columnar storage**: Use columnstore indexes (SQL Server) or columnar formats (Parquet in Snowflake/Databricks) for analytical queries.
5. **Incremental extracts**: Tableau extracts or Power BI import mode with incremental refresh — only pull new months.
6. **Query optimization**: Ensure dashboard queries hit pre-aggregated tables for summary views and only touch the fact table for drill-downs.
7. **Caching**: Use dashboard-level caching with appropriate TTL (e.g., data only changes monthly, so cache for 24 hours).
8. **Detail on demand**: Load loan-level detail only when a user explicitly drills down, not on initial page load.

### Q5: What is the difference between a paginated report and an interactive dashboard? When would you use each?

**A:** A **paginated report** (SSRS, Power BI Paginated) is designed for printing or PDF export. It has fixed layouts, page breaks, headers/footers, and renders the complete dataset upfront. It is ideal for regulatory filings, investor statements, and any deliverable that needs pixel-perfect formatting and complete data (e.g., a 200-page loan tape).

An **interactive dashboard** (Tableau, Power BI, Looker) is designed for on-screen exploration. It supports filtering, drill-down, cross-highlighting, and responsive layouts. It is ideal for portfolio monitoring, ad hoc analysis, and executive summaries.

In MBS reporting, you typically need both: interactive dashboards for daily portfolio monitoring and paginated reports for monthly investor deliverables and regulatory submissions.

---

## Tips

1. **Design for the question, not the data.** Start by understanding what decisions users make and what questions they ask. Then design the dashboard to answer those questions directly — do not just dump tables of numbers.

2. **Pre-aggregate aggressively.** In MBS, most reporting is at the pool or vintage level, not loan level. Build reporting marts that pre-compute the metrics users need. Only go to loan-level for drill-downs.

3. **Use consistent definitions.** Document exactly how each KPI is calculated (numerator, denominator, included populations, exclusions). Ambiguity in definitions causes trust issues. Publish a metrics glossary.

4. **Automate end-to-end.** From data load to dashboard refresh to email delivery, the monthly reporting cycle should be fully automated with human intervention only for approvals and exception handling.

5. **Build reconciliation into the pipeline, not after.** If your dashboard numbers do not match the trustee report, you lose credibility. Build reconciliation checks that run before the dashboard is refreshed.

6. **Version your reports.** Treat report definitions (SQL, templates, dashboard files) as code. Store them in Git. Use CI/CD to deploy changes across environments.

7. **Plan for restatements.** Investor reports sometimes need to be corrected and re-issued. Design your pipeline to regenerate any historical report from the data warehouse, not from cached outputs.

8. **Think about data latency.** Clearly label when data was last refreshed. Stale data presented as current is worse than no data.

9. **Separate exploratory from operational dashboards.** Exploratory dashboards are for analysts doing ad hoc investigation. Operational dashboards are for daily monitoring with alerts. Do not try to make one dashboard serve both purposes.

10. **Test with real users.** Before deploying a dashboard, sit with actual portfolio managers and watch them use it. You will discover usability issues and missing features that no amount of design thinking would have uncovered.

---
