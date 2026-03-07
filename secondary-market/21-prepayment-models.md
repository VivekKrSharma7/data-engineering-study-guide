# Prepayment Models (CPR, PSA, SMM)

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Single Monthly Mortality (SMM)

SMM represents the percentage of the outstanding mortgage pool balance that prepays in a single month. It is the most granular measure of prepayment speed.

**Formula:**

```
SMM = 1 - (Ending Balance after Prepayments / Beginning Balance after Scheduled Principal)
```

Or equivalently:

```
SMM = Prepayment Amount / (Beginning Balance - Scheduled Principal)
```

**Example:** If a pool has a beginning balance of $100,000,000, scheduled principal of $200,000, and actual prepayments of $500,000:

```
SMM = $500,000 / ($100,000,000 - $200,000) = 0.005010 = 0.501%
```

### Conditional Prepayment Rate (CPR)

CPR is the annualized version of SMM. It represents the percentage of the remaining pool balance that would prepay over a full year if the current monthly rate persisted.

**CPR-to-SMM Conversion:**

```
SMM = 1 - (1 - CPR)^(1/12)
```

**SMM-to-CPR Conversion:**

```
CPR = 1 - (1 - SMM)^12
```

**Example Conversions:**

| CPR  | SMM     |
|------|---------|
| 6%   | 0.5143% |
| 10%  | 0.8742% |
| 20%  | 1.8419% |
| 30%  | 2.9314% |
| 50%  | 5.6125% |

> **Data Engineering Note:** Always store and compute at the SMM level for monthly cash flow projections. CPR is a reporting/communication convenience. Never simply divide CPR by 12 to get SMM — this linear approximation introduces meaningful error at higher speeds.

### PSA Benchmark (Public Securities Association)

The PSA model is a standardized prepayment ramp used as a benchmark for quoting and comparing MBS prepayment behavior.

**100% PSA Definition:**

- Month 1: CPR starts at 0.2%
- Months 2-30: CPR increases by 0.2% each month (linear ramp)
- Month 30 onward: CPR plateaus at 6.0%

**Formula:**

```
If month <= 30:  CPR = 0.2% * month
If month > 30:   CPR = 6.0%
```

**Speeds Above and Below PSA:**

| PSA Speed | Month 1 CPR | Month 15 CPR | Month 30+ CPR |
|-----------|-------------|---------------|----------------|
| 50% PSA   | 0.1%        | 1.5%          | 3.0%           |
| 100% PSA  | 0.2%        | 3.0%          | 6.0%           |
| 150% PSA  | 0.3%        | 4.5%          | 9.0%           |
| 200% PSA  | 0.4%        | 6.0%          | 12.0%          |
| 300% PSA  | 0.6%        | 9.0%          | 18.0%          |

**Interpreting PSA Multiples:**

- **Below 100% PSA:** Slower-than-benchmark prepayments. Often seen with higher-coupon pools when rates are rising, or new-production "locked-in" borrowers.
- **Above 100% PSA:** Faster-than-benchmark prepayments. Typical in refinance waves when rates drop significantly below pool WAC.

### Historical Prepayment Speeds

Typical ranges observed across market environments:

| Market Condition              | Typical CPR Range |
|-------------------------------|-------------------|
| Rising rate environment       | 4% - 8%          |
| Stable rate environment       | 8% - 15%         |
| Moderate rate decline         | 15% - 30%        |
| Aggressive refi wave          | 40% - 70%+       |
| Post-refi burnout seasoned    | 3% - 6%          |

### The Prepayment S-Curve

The S-curve describes the relationship between the refinance incentive (difference between the borrower's current rate and prevailing market rates) and prepayment speed.

```
Prepayment Speed (CPR)
       |                          ___________
       |                         /
       |                        /
       |                      /
       |                    /
       |                  /
       |               /
       |        _____/
       |_______/
       +-------------------------------------------
              -100bp    0    +100bp   +200bp   +300bp
                    Refinance Incentive (WAC - Market Rate)
```

**Key characteristics:**

- **Left tail (negative incentive):** Speeds driven by turnover/housing activity only; refinancing is uneconomic. Floor around 4-8% CPR.
- **Steep middle:** As incentive moves from 0bp to +150bp, speeds increase rapidly. This is where small rate changes cause large speed changes — the region of maximum negative convexity.
- **Right tail (deep in-the-money):** Speeds flatten due to burnout, credit constraints, and behavioral friction. Not all borrowers can or will refinance even with large incentives.

### Burnout Effect

Burnout refers to the phenomenon where a mortgage pool that has been exposed to favorable refinancing conditions for an extended period shows progressively declining prepayment speeds, even if the incentive remains constant.

**Mechanism:**

1. Most responsive borrowers (good credit, equity, financial awareness) refinance first.
2. Remaining borrowers are less likely or able to refinance (credit issues, low equity, smaller loan sizes, inertia).
3. The pool's "refinanceability" degrades over time.

**Data Engineering Implications:**

- Track cumulative refinance opportunity (months exposed to a given incentive level).
- Maintain pool factor history to measure how much principal has already paid down.
- Burnout adjustments are critical for accurate cash flow modeling of seasoned pools.

### Seasonal Patterns

Prepayment speeds exhibit consistent seasonal variation:

| Month Range | Pattern | Driver |
|-------------|---------|--------|
| January-February | Low speeds | Post-holiday slowdown, winter weather |
| March-May | Rising speeds | Spring buying season begins |
| June-August | Peak speeds | Peak home purchase season, highest turnover |
| September-October | Declining | Fall slowdown |
| November-December | Trough | Holiday season, minimal activity |

**Seasonal multipliers** (approximate, relative to annual average):

```
Jan: 0.80  Feb: 0.85  Mar: 0.95  Apr: 1.05
May: 1.10  Jun: 1.15  Jul: 1.15  Aug: 1.10
Sep: 1.00  Oct: 0.95  Nov: 0.85  Dec: 0.80
```

### Media Effect and Lock-In Effect

**Media Effect:** A sudden drop in mortgage rates generates widespread media coverage, prompting a surge of refinancing activity beyond what the pure economic incentive would predict. Speeds spike temporarily.

**Lock-In Effect:** Borrowers with rates significantly below market rates are economically disincentivized from moving or refinancing. This suppresses both turnover and refinancing prepayments. The 2020-2021 low-rate cohort experienced extreme lock-in as rates rose in 2022-2024.

### Cash Flow Projections Using Prepayment Models

For each month in a cash flow projection:

```
1. Calculate SMM from assumed CPR (or PSA speed for that month):
   SMM = 1 - (1 - CPR)^(1/12)

2. Compute scheduled principal (amortization):
   Scheduled_Principal = Monthly_Payment - (Balance * WAC/12)

3. Compute prepayment amount:
   Prepayment = SMM * (Balance - Scheduled_Principal)

4. Total principal = Scheduled_Principal + Prepayment

5. New balance:
   Ending_Balance = Beginning_Balance - Scheduled_Principal - Prepayment

6. Interest to investors:
   Interest = Beginning_Balance * Pass-Through_Rate / 12
```

**SQL Example — Monthly Cash Flow Projection Table:**

```sql
WITH RECURSIVE cash_flow AS (
    SELECT
        0 AS month_num,
        original_balance AS beginning_balance,
        0.0 AS scheduled_principal,
        0.0 AS prepayment,
        0.0 AS interest
    FROM pool_info

    UNION ALL

    SELECT
        cf.month_num + 1,
        cf.beginning_balance - cf.scheduled_principal - cf.prepayment,
        /* Simplified scheduled principal calculation */
        (cf.beginning_balance - cf.scheduled_principal - cf.prepayment)
            * (p.wac / 12.0)
            / (1 - POWER(1 + p.wac / 12.0, -(p.wam - cf.month_num)))
            - (cf.beginning_balance - cf.scheduled_principal - cf.prepayment)
            * (p.wac / 12.0),
        /* Prepayment */
        (1 - POWER(1 - ps.cpr, 1.0/12))
            * ((cf.beginning_balance - cf.scheduled_principal - cf.prepayment)
               - /* next month scheduled principal (simplified) */ 0),
        /* Interest */
        (cf.beginning_balance - cf.scheduled_principal - cf.prepayment)
            * p.pass_through_rate / 12.0
    FROM cash_flow cf
    CROSS JOIN pool_info p
    CROSS JOIN prepay_scenario ps
    WHERE cf.month_num < p.wam
        AND cf.beginning_balance > 0.01
)
SELECT * FROM cash_flow;
```

---

## Real-World Examples

### Example 1: Comparing Pool Speeds Across Coupons

A data engineer is asked to build a dashboard comparing 1-month and 3-month CPR across FNMA 30-year TBA coupons.

```sql
SELECT
    coupon,
    report_month,
    AVG(cpr_1mo) AS avg_cpr_1mo,
    AVG(cpr_3mo) AS avg_cpr_3mo,
    AVG(cpr_1mo) / (0.2 * LEAST(wam_orig - wam + 1, 30) / 100.0 * 6.0)
        AS psa_speed_approx
FROM pool_prepay_history
WHERE agency = 'FNMA'
    AND product = '30YR'
    AND report_month >= '2025-01-01'
GROUP BY coupon, report_month
ORDER BY report_month, coupon;
```

### Example 2: Detecting Burnout in Seasoned Pools

```sql
SELECT
    pool_id,
    wac,
    loan_age_months,
    current_factor,
    cpr_1mo,
    cpr_3mo,
    cpr_6mo,
    cpr_12mo,
    CASE
        WHEN cpr_3mo < cpr_12mo * 0.7
            AND wac - current_market_rate > 1.0
        THEN 'BURNOUT_DETECTED'
        ELSE 'NORMAL'
    END AS burnout_flag
FROM pool_performance
WHERE wac - current_market_rate > 0.50
ORDER BY burnout_flag DESC, wac DESC;
```

### Example 3: Seasonal Adjustment of Prepayment Speeds

```python
SEASONAL_FACTORS = {
    1: 0.80, 2: 0.85, 3: 0.95, 4: 1.05,
    5: 1.10, 6: 1.15, 7: 1.15, 8: 1.10,
    9: 1.00, 10: 0.95, 11: 0.85, 12: 0.80
}

def seasonally_adjust_cpr(raw_cpr, month):
    """Remove seasonal effect to get underlying trend."""
    return raw_cpr / SEASONAL_FACTORS[month]

def apply_seasonal_factor(base_cpr, month):
    """Apply seasonal pattern to a base prepayment projection."""
    return base_cpr * SEASONAL_FACTORS[month]
```

---

## Common Interview Questions & Answers

### Q1: What is the relationship between CPR and SMM, and why can you not simply divide CPR by 12?

**A:** CPR is the annualized conditional prepayment rate; SMM is the monthly rate. The relationship is compounding, not linear:

`SMM = 1 - (1 - CPR)^(1/12)`

Dividing CPR by 12 ignores the compounding effect. At low speeds the error is small (6% CPR / 12 = 0.50% vs. actual SMM of 0.5143%), but at high speeds the error becomes significant (50% CPR / 12 = 4.17% vs. actual SMM of 5.61%). In production cash flow engines, always use the exponential formula.

### Q2: Explain the PSA benchmark model and what "200% PSA" means.

**A:** The PSA standard benchmark assumes prepayments start at 0.2% CPR in month 1, ramp linearly by 0.2% per month, and plateau at 6% CPR from month 30 onward. This is 100% PSA. At 200% PSA, every value doubles: 0.4% CPR in month 1, ramping by 0.4% per month, plateauing at 12% CPR from month 30 onward. PSA multiples provide a simple, single-number way to communicate relative prepayment speed assumptions for an entire pool's life.

### Q3: What is the prepayment S-curve and why does it matter for MBS valuation?

**A:** The S-curve plots prepayment speed against refinance incentive (WAC minus current mortgage rate). It has three zones: (1) a floor at negative incentive where only housing turnover drives prepayments; (2) a steep middle zone where speeds are highly sensitive to rate changes, creating negative convexity for MBS holders; and (3) a flattening at deep positive incentive due to burnout and borrower frictions. The S-curve matters because it is the core behavioral function inside any prepayment model used for OAS, duration, and convexity calculations.

### Q4: What is burnout and how would you detect it in data?

**A:** Burnout is the progressive decline in prepayment speeds for a pool that has been persistently in-the-money for refinancing. The most responsive borrowers leave first, leaving a residual pool of less rate-sensitive borrowers. To detect it, compare recent short-term speeds (1-month or 3-month CPR) against longer-term speeds (life CPR or 12-month CPR) for pools with positive refinance incentive. If short-term speeds are materially below the longer-term average despite stable or increasing incentive, the pool is exhibiting burnout. Additional signals include a low pool factor (much of the original balance has already paid down) and high loan age.

### Q5: How do seasonal patterns affect prepayment analysis, and how would you account for them in a data pipeline?

**A:** Prepayments peak in summer (June-August) driven by the home-buying season and trough in winter (November-February). In a data pipeline, I would maintain a seasonal factor table and compute both raw and seasonally-adjusted CPR. The adjusted CPR reveals underlying trends (changes in refinance behavior, policy effects) stripped of predictable calendar-driven variation. This is critical for time-series forecasting: training a model on raw CPR without seasonal adjustment would produce biased predictions.

### Q6: Walk through how you would build a monthly cash flow engine for an MBS pool.

**A:** The engine iterates monthly over the pool's remaining life. Each month: (1) start with beginning balance; (2) calculate interest at the pass-through rate; (3) compute scheduled amortization from the WAC and remaining term; (4) derive SMM from the CPR assumption for that month (which could come from a PSA ramp, a vector of CPRs, or a dynamic model); (5) calculate prepayment as SMM times the balance after scheduled principal; (6) sum scheduled principal and prepayment for total principal; (7) ending balance equals beginning balance minus total principal. I would store each month's record with all components for downstream analytics. In production, I would use vectorized computation (NumPy/Pandas or Spark) rather than row-by-row iteration for performance.

---

## Tips

- **Always validate CPR/SMM conversion** in your pipelines. Off-by-one or linear-approximation bugs are common and compound over 360 months of projected cash flows.
- **Store raw factor data** (pool factor, scheduled factor) and derive CPR from actual balance changes rather than relying on vendor-reported CPR, which may use different conventions.
- **PSA is a communication tool, not a forecasting model.** Real prepayment models (like those from Andrew Davidson, BlackRock, or Yield Book) are far more sophisticated. But PSA fluency is essential for industry communication.
- **When building dashboards**, always show CPR alongside pool factor and WAC-vs-market-rate context. A CPR number in isolation is meaningless.
- **For data quality checks**, flag any SMM above 15% or below 0% as potential data errors. Also flag pools where reported prepayments exceed the maximum possible balance reduction.
- **Understand the reporting lag.** FNMA/FHLMC pool factor data typically reflects activity with a 1-2 month delay. Align your date fields carefully in time-series analysis.
