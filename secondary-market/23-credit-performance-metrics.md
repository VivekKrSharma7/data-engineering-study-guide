# Credit Performance Metrics (CDR, MDR, Severity, Loss)

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Conditional Default Rate (CDR)

CDR is the annualized rate at which loans in a mortgage pool default. It is the credit analogue of CPR for prepayments.

**Formula:**

```
CDR = 1 - (1 - MDR)^12
```

Where MDR is the Monthly Default Rate.

**Interpretation:** A CDR of 5% means that, if the current monthly default rate persisted for a full year, 5% of the remaining pool balance would default.

### Monthly Default Rate (MDR)

MDR is the fraction of the outstanding pool balance that defaults in a given month.

**Formula:**

```
MDR = Default Amount (UPB) in Month / Beginning-of-Month Performing Balance
```

**CDR-to-MDR Conversion:**

```
MDR = 1 - (1 - CDR)^(1/12)
```

**Example:**

| CDR  | MDR     |
|------|---------|
| 1%   | 0.0837% |
| 3%   | 0.2535% |
| 5%   | 0.4265% |
| 10%  | 0.8742% |
| 20%  | 1.8419% |

> **Data Engineering Note:** The CDR/MDR relationship is mathematically identical to CPR/SMM. The same conversion formula applies. Store monthly observations (MDR) and annualize (CDR) for reporting.

### Default Definitions

"Default" has multiple definitions depending on context:

| Definition | Description | Common Usage |
|-----------|-------------|--------------|
| **60+ days delinquent** | Loan is 2+ payments behind | Early warning metric |
| **90+ days delinquent** | Loan is 3+ payments behind | Common industry default trigger |
| **First-time 90+ DQ** | First occurrence of 90+ DQ | Credit event definition for modeling |
| **Foreclosure filing** | Legal action initiated | Regulatory/legal default |
| **REO acquisition** | Lender/servicer takes property | Liquidation event |
| **Charge-off** | Balance written off | Accounting default |
| **180+ days delinquent** | Loan is 6+ payments behind | CECL/IFRS 9 default definition |

**Critical for data engineering:** Ensure consistency in default definitions across data sources. GSE data (Fannie, Freddie) may use different thresholds than private-label RMBS or bank portfolio data.

### Loss Severity

Loss severity (also called loss-given-default, LGD) measures the percentage of outstanding balance lost when a defaulted loan is liquidated.

**Formula:**

```
Loss Severity = Total Loss / UPB at Default
```

Where:

```
Total Loss = UPB at Default
           + Accrued Interest
           + Foreclosure Costs (legal, property maintenance, taxes)
           + Selling Costs (broker commissions, transfer taxes)
           - Property Sale Proceeds
           - Mortgage Insurance Recovery
           - Other Recoveries
```

### Net vs. Gross Loss

**Gross Loss:** The total economic loss before any recoveries.

```
Gross Loss = UPB at Default + Accrued Interest + Expenses - Liquidation Proceeds
```

**Net Loss:** Loss after accounting for all recoveries including mortgage insurance (MI), credit enhancement, and other recoverables.

```
Net Loss = Gross Loss - MI Proceeds - Other Recoveries
```

**Example:**

| Item | Amount |
|------|--------|
| UPB at Default | $300,000 |
| Accrued Interest | $12,000 |
| Foreclosure/Legal Costs | $25,000 |
| Property Maintenance | $8,000 |
| Property Sale Proceeds | ($230,000) |
| **Gross Loss** | **$115,000** |
| Gross Severity | 38.3% |
| MI Recovery (25% coverage) | ($75,000) |
| **Net Loss** | **$40,000** |
| Net Severity | 13.3% |

### Recovery Rates

Recovery rate is the complement of loss severity:

```
Recovery Rate = 1 - Loss Severity
```

Or equivalently:

```
Recovery Rate = Amount Recovered / UPB at Default
```

**Typical recovery rates by property type (historical averages):**

| Property Type | Avg. Gross Recovery | Avg. Net Recovery (with MI) |
|--------------|--------------------|-----------------------------|
| Single-Family | 60-70% | 75-90% |
| Condo | 55-65% | 70-85% |
| 2-4 Unit | 50-60% | 65-80% |
| Manufactured Housing | 40-55% | 55-70% |

### Timeline from Default to Liquidation

The default-to-liquidation timeline is critical for modeling the timing of losses and cash flow impacts.

**Typical Timeline (varies significantly by state):**

```
Delinquency     Foreclosure      REO           Liquidation
Onset           Filing           Acquisition    (Sale)
  |               |                |              |
  v               v                v              v
  |---6-12 mo--->|---6-24 mo----->|--3-12 mo--->|

Total timeline: 15-48 months from first missed payment to liquidation
```

**Judicial vs. Non-Judicial States:**

| Foreclosure Type | Typical Timeline | Example States |
|-----------------|------------------|----------------|
| Non-Judicial | 6-12 months | TX, CA, GA, VA, AZ |
| Judicial | 18-36+ months | NY, NJ, FL, IL, OH |

**Data Engineering Implication:** When computing CDR, the lag between when a loan first defaults and when the loss is realized can be years. Pipelines must track default date, foreclosure date, REO date, and liquidation date as separate fields.

### Cumulative Losses and Loss Curves

Cumulative loss is the total losses realized over the life of a pool as a percentage of original balance.

```
Cumulative Loss % = Sum of All Losses to Date / Original Pool Balance
```

**Loss Curve Shape:**
Losses follow a characteristic pattern over pool age:

```
Cumulative
Loss %
    |                              _____________
    |                            /
    |                          /
    |                        /
    |                     /
    |                  /
    |               /
    |            /
    |         /
    |      /
    |   /
    |_/
    +------------------------------------------>
    0    12    24    36    48    60    72    84
                  Loan Age (Months)
```

- **Months 0-12:** Minimal losses (newly originated loans rarely default immediately).
- **Months 12-36:** Losses begin to accelerate. Early payment defaults (EPDs) appear.
- **Months 36-60:** Peak loss velocity. Loans that were marginal at origination are failing.
- **Months 60-84:** Loss rate begins to decelerate. Remaining borrowers are more stable.
- **Months 84+:** Losses taper off. Pool has been "seasoned" and cleaned of weak borrowers.

### Vintage Analysis

Vintage analysis compares credit performance across origination cohorts to identify trends in underwriting quality and economic conditions.

```sql
SELECT
    DATE_TRUNC('quarter', origination_date) AS vintage,
    loan_age_months,
    SUM(cumulative_loss) / SUM(original_upb) * 100 AS cum_loss_pct,
    SUM(CASE WHEN days_delinquent >= 90 THEN current_upb ELSE 0 END)
        / SUM(current_upb) * 100 AS serious_dq_rate,
    COUNT(CASE WHEN ever_90_plus_dq = 'Y' THEN 1 END) * 1.0
        / COUNT(*) * 100 AS ever_90_dq_pct
FROM loan_performance
GROUP BY 1, 2
ORDER BY vintage, loan_age_months;
```

**Key vintage observations:**

- **2005-2007 vintages:** Catastrophic losses (10-30%+ cumulative for subprime).
- **2009-2013 vintages:** Exceptionally clean (tight post-crisis underwriting, rising home prices).
- **2020-2021 vintages:** Low default rates supported by home price gains, but lock-in effect creates a unique risk profile.

### Transition Matrices

A transition matrix shows the probability of a loan moving between delinquency states from one period to the next.

**Example Monthly Transition Matrix:**

| From \ To | Current | 30 DQ | 60 DQ | 90 DQ | FC | REO | Prepaid | Liquidated |
|-----------|---------|-------|-------|-------|-----|-----|---------|------------|
| Current | 97.5% | 1.5% | 0.0% | 0.0% | 0.0% | 0.0% | 1.0% | 0.0% |
| 30 DQ | 45.0% | 25.0% | 25.0% | 0.0% | 0.0% | 0.0% | 5.0% | 0.0% |
| 60 DQ | 15.0% | 10.0% | 20.0% | 50.0% | 0.0% | 0.0% | 3.0% | 2.0% |
| 90 DQ | 5.0% | 3.0% | 2.0% | 60.0% | 25.0% | 0.0% | 2.0% | 3.0% |
| FC | 2.0% | 0.0% | 0.0% | 5.0% | 70.0% | 18.0% | 2.0% | 3.0% |
| REO | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | 75.0% | 0.0% | 25.0% |

**SQL to compute transition matrices:**

```sql
WITH transitions AS (
    SELECT
        l1.loan_id,
        l1.delinquency_status AS from_status,
        l2.delinquency_status AS to_status,
        l1.current_upb AS upb
    FROM loan_monthly l1
    JOIN loan_monthly l2
        ON l1.loan_id = l2.loan_id
        AND l2.report_month = l1.report_month + INTERVAL '1 month'
    WHERE l1.report_month = '2025-11-01'
)
SELECT
    from_status,
    to_status,
    COUNT(*) AS loan_count,
    SUM(upb) AS total_upb,
    COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY from_status)
        AS transition_pct
FROM transitions
GROUP BY from_status, to_status
ORDER BY from_status, to_status;
```

### Roll Rates

Roll rates measure the probability that a delinquent loan "rolls" forward to a worse delinquency status (as opposed to curing or remaining in the same status).

```
Roll Rate (30→60) = Loans moving from 30 DQ to 60 DQ / Total loans at 30 DQ
```

**Typical roll rates:**

| Transition | Normal Environment | Stressed Environment |
|-----------|-------------------|---------------------|
| Current → 30 DQ | 1.0% - 2.0% | 3.0% - 5.0% |
| 30 DQ → 60 DQ | 20% - 30% | 40% - 60% |
| 60 DQ → 90 DQ | 40% - 55% | 60% - 75% |
| 90 DQ → FC | 20% - 30% | 35% - 50% |

### Cure Rates

Cure rate is the probability that a delinquent loan returns to current status.

```
Cure Rate = Loans that return to Current / Total loans in delinquency bucket
```

**Key patterns:**

- Cure rates decrease dramatically as delinquency deepens.
- 30-day DQ cure rate: 40-50% (many are just timing issues).
- 60-day DQ cure rate: 15-25%.
- 90+ DQ cure rate: 5-15% (without modification).
- Post-modification cure rates depend heavily on modification type and depth.

---

## Real-World Examples

### Example 1: Building a Monthly CDR/MDR Pipeline

```sql
-- Monthly CDR calculation at pool level
WITH monthly_defaults AS (
    SELECT
        pool_id,
        report_month,
        SUM(CASE
            WHEN default_flag = 'Y'
                AND prior_month_default_flag = 'N'
            THEN current_upb
            ELSE 0
        END) AS new_default_upb,
        SUM(CASE
            WHEN delinquency_status NOT IN ('DEFAULT', 'FC', 'REO', 'LIQUIDATED')
            THEN current_upb
            ELSE 0
        END) AS performing_balance
    FROM loan_performance_monthly
    GROUP BY pool_id, report_month
)
SELECT
    pool_id,
    report_month,
    new_default_upb,
    performing_balance,
    CASE WHEN performing_balance > 0
         THEN new_default_upb / performing_balance
         ELSE 0
    END AS mdr,
    CASE WHEN performing_balance > 0
         THEN 1 - POWER(1 - (new_default_upb / performing_balance), 12)
         ELSE 0
    END AS cdr
FROM monthly_defaults
ORDER BY pool_id, report_month;
```

### Example 2: Loss Severity Calculation Pipeline

```sql
SELECT
    l.loan_id,
    l.default_upb,
    l.accrued_interest,
    l.foreclosure_costs,
    l.property_maintenance_costs,
    l.selling_costs,
    l.property_sale_proceeds,
    l.mi_recovery,
    l.other_recoveries,
    -- Gross loss
    (l.default_upb + l.accrued_interest + l.foreclosure_costs
     + l.property_maintenance_costs + l.selling_costs
     - l.property_sale_proceeds) AS gross_loss,
    -- Gross severity
    (l.default_upb + l.accrued_interest + l.foreclosure_costs
     + l.property_maintenance_costs + l.selling_costs
     - l.property_sale_proceeds)
     / NULLIF(l.default_upb, 0) AS gross_severity,
    -- Net loss
    (l.default_upb + l.accrued_interest + l.foreclosure_costs
     + l.property_maintenance_costs + l.selling_costs
     - l.property_sale_proceeds - l.mi_recovery - l.other_recoveries)
        AS net_loss,
    -- Net severity
    (l.default_upb + l.accrued_interest + l.foreclosure_costs
     + l.property_maintenance_costs + l.selling_costs
     - l.property_sale_proceeds - l.mi_recovery - l.other_recoveries)
     / NULLIF(l.default_upb, 0) AS net_severity,
    -- Timeline metrics
    DATEDIFF('month', l.first_90dq_date, l.foreclosure_date)
        AS months_to_foreclosure,
    DATEDIFF('month', l.foreclosure_date, l.reo_date)
        AS months_in_foreclosure,
    DATEDIFF('month', l.reo_date, l.liquidation_date)
        AS months_in_reo,
    DATEDIFF('month', l.first_90dq_date, l.liquidation_date)
        AS total_resolution_months
FROM liquidated_loans l
WHERE l.liquidation_date >= '2025-01-01';
```

### Example 3: Vintage Loss Curve Comparison

```python
import pandas as pd
import matplotlib.pyplot as plt

def plot_vintage_loss_curves(loan_data):
    """Generate cumulative loss curves by vintage for comparison."""
    vintages = loan_data.groupby(['vintage_year', 'loan_age_months']).agg(
        cum_loss=('cumulative_loss', 'sum'),
        orig_balance=('original_upb', 'sum')
    ).reset_index()

    vintages['cum_loss_pct'] = vintages['cum_loss'] / vintages['orig_balance'] * 100

    fig, ax = plt.subplots(figsize=(12, 6))
    for vintage in sorted(vintages['vintage_year'].unique()):
        v_data = vintages[vintages['vintage_year'] == vintage]
        ax.plot(v_data['loan_age_months'], v_data['cum_loss_pct'],
                label=f'{vintage}')

    ax.set_xlabel('Loan Age (Months)')
    ax.set_ylabel('Cumulative Loss (%)')
    ax.set_title('Cumulative Loss Curves by Vintage')
    ax.legend()
    return fig
```

### Example 4: State-Level Severity Analysis

```sql
SELECT
    property_state,
    foreclosure_type,
    COUNT(*) AS liquidation_count,
    AVG(gross_severity) AS avg_gross_severity,
    AVG(net_severity) AS avg_net_severity,
    AVG(total_resolution_months) AS avg_resolution_months,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gross_severity)
        AS median_gross_severity,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY gross_severity)
        AS p95_gross_severity
FROM liquidated_loans
WHERE liquidation_date >= '2024-01-01'
GROUP BY property_state, foreclosure_type
ORDER BY avg_gross_severity DESC;
```

---

## Common Interview Questions & Answers

### Q1: What is CDR and how does it relate to MDR? Why is the relationship not linear?

**A:** CDR (Conditional Default Rate) is the annualized probability that loans in a pool will default. MDR (Monthly Default Rate) is the single-month equivalent. The relationship is: `CDR = 1 - (1 - MDR)^12`. It is not linear because defaulting is a compounding event — each month's default rate applies to the remaining non-defaulted balance, not the original balance. Dividing CDR by 12 would overestimate MDR at high rates and underestimate the compounding effect. The formula is mathematically identical to the CPR/SMM relationship.

### Q2: Walk through how you would calculate loss severity for a liquidated loan.

**A:** Start with the UPB at the time of default. Add accrued but unpaid interest, foreclosure costs (legal fees, filing fees), property preservation costs (maintenance, taxes, insurance during the foreclosure period), and selling costs (broker commissions, transfer taxes). Subtract the property sale proceeds. This gives gross loss. Then subtract mortgage insurance recoveries and any other recoverables (PMI claims, guarantor payments) to get net loss. Divide by UPB at default to get severity as a percentage. For example: $300K UPB + $45K costs - $230K sale proceeds = $115K gross loss = 38.3% gross severity. After $75K MI recovery, net loss = $40K = 13.3% net severity.

### Q3: What is a transition matrix and how would you build one from loan-level data?

**A:** A transition matrix shows the probability of loans moving between delinquency states (Current, 30DQ, 60DQ, 90DQ, Foreclosure, REO, Prepaid, Liquidated) from one month to the next. To build one, I join the loan-level performance table to itself with a one-month offset on loan_id, creating pairs of (from_status, to_status). Then I group by from_status and to_status, counting loans and dividing by the total count for each from_status to get transition probabilities. The matrix can be segmented by product, vintage, geography, or FICO band to identify heterogeneity. It is a fundamental building block for Markov chain default models and stress testing.

### Q4: Explain vintage analysis and why 2005-2007 vintages performed so differently from 2010-2013 vintages.

**A:** Vintage analysis compares credit performance across origination cohorts by plotting metrics (cumulative default, cumulative loss, serious delinquency rate) against loan age. The 2005-2007 vintages performed catastrophically because of loose underwriting standards (no-doc loans, high LTV, teaser rates, subprime expansion) combined with a severe home price decline. Borrowers who were marginally qualified defaulted en masse as they could not refinance and had no equity. The 2010-2013 vintages benefited from dramatically tightened post-crisis underwriting (higher FICO requirements, full documentation, lower LTV), combined with steadily rising home prices that built equity cushions. Vintage analysis is essential for identifying underwriting cycle risk.

### Q5: How does the foreclosure timeline differ across states, and why does it matter for data engineering?

**A:** States follow either judicial foreclosure (requiring court proceedings) or non-judicial foreclosure (power-of-sale through a trustee). Judicial states like New York, New Jersey, and Florida can take 2-3+ years from default to liquidation, while non-judicial states like Texas and California may complete in 6-12 months. This matters for data engineering because: (1) loss timing is state-dependent, requiring state-level severity and timeline assumptions; (2) accrued interest and carrying costs accumulate longer in judicial states, increasing severity; (3) pipeline analysis of currently defaulted loans must account for state-specific expected resolution timelines; and (4) cash flow projections for MBS need state-weighted average loss timelines.

### Q6: What are roll rates and cure rates, and how would you use them for loss forecasting?

**A:** Roll rates measure the probability of a loan moving to a deeper delinquency status (e.g., 30DQ rolling to 60DQ), while cure rates measure the probability of returning to current. Together they form the transition dynamics of a portfolio's credit health. For loss forecasting, I would: (1) compute current delinquency distribution by bucket; (2) apply roll/cure rates monthly to project future delinquency pipeline; (3) at each stage, apply conditional default probability and loss severity to estimate losses. This Markov chain approach captures the pipeline nature of defaults — today's 30DQ population is a leading indicator of future losses. Monitoring roll rate changes over time (especially the 60→90 roll) provides early warning of credit deterioration.

---

## Tips

- **Default definitions vary by data source.** Always document which definition your pipeline uses and ensure consistency when joining GSE, private-label, and servicer data. A loan that is "defaulted" in one system may be "90+ DQ" in another.
- **Severity varies enormously by state, property type, and cycle.** Never use a single national average severity in production models. At minimum, segment by judicial vs. non-judicial state and by LTV band.
- **Loss timing matters as much as loss amount.** For discounted cash flow analysis, a loss realized in month 48 has a very different present value than the same loss in month 18. Track and model the full timeline.
- **Cure rates are volatile and policy-sensitive.** Government forbearance programs (e.g., COVID-19) can dramatically increase cures from deep delinquency, while program expiration can reduce them. Always check for policy regime changes when analyzing historical cure data.
- **Cumulative loss projections should be range-based.** Provide base, optimistic, and stressed scenarios rather than a single point estimate. Historical loss curves from similar vintages provide useful benchmarks.
- **Data quality checks for loss data:** Flag any liquidation with negative loss (profit on liquidation — possible but rare), severity above 100% (common when carrying costs are high), or resolution timelines under 3 months (verify REO was not a short sale or deed-in-lieu).
