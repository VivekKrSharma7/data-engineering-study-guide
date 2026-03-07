# Prepayment Drivers

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Overview of Prepayment Components

Prepayments are not a single phenomenon. They are the aggregate of several distinct borrower behaviors, each driven by different factors. Sophisticated prepayment models decompose total prepayment into components:

```
Total Prepayment = Refinance + Turnover (Housing) + Curtailments + Defaults (Involuntary)
```

Understanding each component separately is critical for accurate modeling and for interpreting observed speeds.

### Refinance-Driven Prepayments

Refinancing is typically the largest and most volatile component of prepayments.

**Rate/Term Refinance:**
The borrower replaces their existing mortgage with a new one at a lower rate and/or shorter term. The primary motivation is reducing monthly payments or total interest cost. No cash is extracted.

**Cash-Out Refinance:**
The borrower takes a new, larger mortgage and extracts home equity as cash. Motivated by liquidity needs (home improvement, debt consolidation) rather than purely by rate savings. Cash-out refi is less rate-sensitive than rate/term refi and responds more to home price appreciation (which creates extractable equity).

**Key distinction for modeling:** Rate/term refi is highly correlated with the rate environment. Cash-out refi is correlated with both rates and home prices. In a rising-rate/rising-home-price environment, rate/term refi collapses but cash-out refi can persist.

### Refinance Incentive

The refinance incentive is the single most important variable in prepayment modeling. It measures how economically attractive it is for borrowers to refinance.

**Basic Definition:**

```
Refinance Incentive = Pool WAC - Current Mortgage Rate
```

**Example:**

| Pool WAC | Current 30yr Rate | Incentive | Expected Behavior |
|----------|-------------------|-----------|-------------------|
| 3.00%    | 6.50%             | -350bp    | No refi activity; deep lock-in |
| 4.50%    | 5.00%             | -50bp     | Minimal refi; some cash-out |
| 5.50%    | 5.00%             | +50bp     | Modest refi; breakeven for many borrowers |
| 6.50%    | 5.00%             | +150bp    | Strong refi wave |
| 7.50%    | 5.00%             | +250bp    | Maximum refi; limited by burnout/credit |

**Refinements to the basic incentive measure:**

- **Closing costs matter:** A borrower needs enough rate savings to recoup closing costs (typically $3,000-$8,000) within a reasonable time horizon. This creates a minimum incentive threshold, typically 50-75bp.
- **Loan size amplifies incentive:** A 100bp rate reduction on a $500,000 loan saves $5,000/year, but on a $150,000 loan saves only $1,500/year. The larger borrower is more likely to act.
- **FICO/LTV constraints:** Even with strong incentive, borrowers with low credit scores or high LTV may not qualify for a new loan.

### SATO (Spread at Origination)

SATO measures how much above (or below) the prevailing market rate a borrower's loan was originated at.

```
SATO = Loan Note Rate - Market Rate at Origination Date
```

**Why SATO matters:**

- **High SATO borrowers** (rate well above market at origination) typically have weaker credit profiles, higher LTV, or other risk factors that caused them to receive a higher rate. These borrowers are less likely to refinance because they face the same barriers when trying to get a new loan.
- **Low or negative SATO borrowers** obtained favorable rates, suggesting strong credit profiles. They are more responsive to refinancing opportunities.

**Data Engineering Application:**

```sql
SELECT
    loan_id,
    note_rate,
    origination_date,
    m.market_rate_30yr AS market_rate_at_orig,
    note_rate - m.market_rate_30yr AS sato
FROM loans l
JOIN market_rates m
    ON l.origination_date = m.rate_date
ORDER BY sato DESC;
```

SATO is a powerful predictor that should be included as a feature in any prepayment model.

### Turnover (Housing Turnover)

Turnover prepayments result from home sales — borrowers sell the property and the existing mortgage is paid off. This component is relatively stable and less rate-sensitive than refinancing.

**Key drivers of turnover:**

| Driver | Effect on Turnover |
|--------|-------------------|
| Job mobility / relocation | Increases turnover |
| Divorce / life changes | Increases turnover |
| Home price appreciation | Increases (trade-up buyers) |
| Rising rates | Decreases (lock-in effect) |
| Housing inventory | Higher inventory enables moves |
| Season (summer) | Peak turnover |
| Loan age (seasoning) | Turnover increases for first 3-5 years then stabilizes |

**Typical turnover CPR:** 5-10% CPR in normal environments, declining to 3-5% during high-rate lock-in periods.

### Curtailments

Curtailments are partial prepayments — borrowers make extra principal payments beyond their scheduled amount without fully paying off the loan.

**Characteristics:**

- Small individually but can contribute 1-3% CPR in aggregate for seasoned pools.
- More common for borrowers approaching retirement (accelerating payoff).
- Higher for pools with larger loan balances and higher borrower incomes.
- Not rate-sensitive — driven by personal financial behavior.

**Data Engineering Note:** Curtailments are often combined with full prepayments in reported SMM/CPR. If your loan-level data separates partial and full payoffs, model them independently for better accuracy.

### Defaults as Involuntary Prepayments

From a cash flow perspective, defaults that result in liquidation remove loans from the pool, similar to a prepayment. However, the principal recovered is typically less than the outstanding balance (loss severity applies).

**Key distinction:**

- **Voluntary prepayment:** Full principal balance is returned.
- **Involuntary prepayment (default/liquidation):** Only partial recovery (100% - Loss Severity)% is returned. The difference is a loss to the trust/investor.

In MBS modeling, defaults are sometimes included in prepayment projections (gross CPR) and sometimes excluded (voluntary CPR only). Clarity on the convention is essential.

### Loan Characteristics Affecting Prepayments

| Characteristic | Impact on Prepayments |
|---------------|----------------------|
| **Loan Size** | Larger loans prepay faster (greater dollar savings from refi) |
| **FICO Score** | Higher FICO = more refi-responsive; easier to qualify |
| **LTV/CLTV** | Lower LTV = easier to refi; more equity enables cash-out |
| **Loan Age** | Seasoning ramp: speeds increase over first 30 months |
| **Property Type** | Single-family faster than condo/multi-family |
| **Occupancy** | Owner-occupied faster than investor properties |
| **Loan Purpose** | Purchase loans have lower early prepay than refi loans |
| **Geography** | States with higher home prices / job growth prepay faster |
| **Number of Borrowers** | Co-borrowers may have more resources for refi |
| **Documentation Type** | Full doc borrowers more likely to qualify for refi |
| **Channel** | Retail tends to prepay faster than correspondent/broker |

### Borrower Demographics

Demographic factors create persistent differences in prepayment behavior:

- **Income level:** Higher-income borrowers are more financially sophisticated and responsive to refinance opportunities.
- **Age:** Younger borrowers move more often (higher turnover); older borrowers make more curtailments.
- **First-time vs. repeat homebuyer:** First-time buyers tend to stay longer but are less likely to refinance proactively.
- **Financial literacy:** Awareness of refinancing options varies significantly across populations.

### Policy Changes Affecting Prepayments

**HARP (Home Affordable Refinance Program):**
- Launched 2009, expanded 2012 (HARP 2.0).
- Allowed borrowers with LTV above 80% (even >125%) to refinance GSE-backed mortgages.
- Removed a major barrier for underwater borrowers.
- Created a spike in prepayments for high-LTV pools that were previously locked out of refinancing.

**Streamline Refinance Programs:**
- FHA Streamline: Reduced documentation, no appraisal required for FHA-to-FHA refi.
- VA IRRRL (Interest Rate Reduction Refinance Loan): Minimal documentation for VA-to-VA refi.
- These programs lower friction and increase refi speeds for government loan pools.

**COVID-era Impacts:**
- Forbearance programs temporarily suppressed prepayments for affected borrowers.
- Post-forbearance, some borrowers cured and refinanced, creating delayed prepayment surges.
- Historically low rates in 2020-2021 drove record prepayment speeds.

### Modeling Components Separately

Best practice in prepayment modeling is to estimate each component independently:

```
Total CPR(t) = Refi_CPR(t) + Turnover_CPR(t) + Curtailment_CPR(t)
```

**Refinance component model inputs:**
- Refinance incentive (WAC - market rate)
- Burnout factor (cumulative incentive exposure)
- SATO
- Loan size
- FICO / credit score
- LTV (current, using HPI-adjusted values)
- Loan age (seasoning)
- Media effect (recent rate changes)

**Turnover component model inputs:**
- Loan age / seasoning
- Season of year
- Lock-in effect (market rate - note rate; negative incentive)
- Geographic factors (state, MSA)
- Home price trends
- Property type, occupancy

**Curtailment component model inputs:**
- Loan age
- Loan size
- Borrower income (proxy: original loan amount relative to area median)
- Pool factor

**Data pipeline architecture:**

```
Raw Loan Data --> Feature Engineering --> Component Models --> Aggregation
                       |                      |
                  Market Data             Model Coefficients
                  HPI Data                (retrained quarterly)
                  Rate Data
```

---

## Real-World Examples

### Example 1: Decomposing Prepayment Speeds

```sql
-- Assuming loan-level data with payoff reason codes
SELECT
    pool_id,
    report_month,
    -- Full payoffs with refi indicators
    SUM(CASE WHEN payoff_reason = 'REFINANCE' THEN upb END)
        / SUM(beginning_upb) * 100 AS refi_smm_pct,
    -- Full payoffs from home sales
    SUM(CASE WHEN payoff_reason = 'HOME_SALE' THEN upb END)
        / SUM(beginning_upb) * 100 AS turnover_smm_pct,
    -- Curtailments
    SUM(curtailment_amount)
        / SUM(beginning_upb) * 100 AS curtailment_smm_pct,
    -- Involuntary (liquidations)
    SUM(CASE WHEN payoff_reason = 'LIQUIDATION' THEN upb END)
        / SUM(beginning_upb) * 100 AS default_smm_pct
FROM loan_level_performance
WHERE report_month = '2025-12-01'
GROUP BY pool_id, report_month;
```

### Example 2: Refinance Incentive Bucketing Analysis

```sql
SELECT
    CASE
        WHEN wac - current_market_rate < -1.0 THEN 'Deep OTM (< -100bp)'
        WHEN wac - current_market_rate < -0.5 THEN 'OTM (-100 to -50bp)'
        WHEN wac - current_market_rate < 0    THEN 'Slight OTM (-50 to 0bp)'
        WHEN wac - current_market_rate < 0.5  THEN 'Slight ITM (0 to +50bp)'
        WHEN wac - current_market_rate < 1.0  THEN 'ITM (+50 to +100bp)'
        WHEN wac - current_market_rate < 1.5  THEN 'Deep ITM (+100 to +150bp)'
        ELSE 'Very Deep ITM (> +150bp)'
    END AS incentive_bucket,
    COUNT(DISTINCT pool_id) AS num_pools,
    SUM(current_upb) / 1e9 AS total_upb_billions,
    AVG(cpr_3mo) AS avg_3mo_cpr
FROM pool_analytics
WHERE report_month = '2025-12-01'
    AND product = '30YR_FIXED'
GROUP BY 1
ORDER BY MIN(wac - current_market_rate);
```

### Example 3: SATO Distribution and Its Impact on Speeds

```python
import pandas as pd
import numpy as np

def compute_sato_impact(loans_df, market_rates_df):
    """Analyze how SATO correlates with prepayment behavior."""
    # Merge to get market rate at origination
    loans = loans_df.merge(
        market_rates_df[['date', 'rate_30yr']],
        left_on='orig_date',
        right_on='date',
        how='left'
    )
    loans['sato'] = loans['note_rate'] - loans['rate_30yr']

    # Bucket SATO and compute average prepay speed
    loans['sato_bucket'] = pd.cut(
        loans['sato'],
        bins=[-1.0, -0.25, 0, 0.25, 0.50, 0.75, 1.0, 2.0, 4.0],
        labels=[
            '<-25bp', '-25 to 0', '0 to +25bp', '+25 to +50bp',
            '+50 to +75bp', '+75 to +100bp', '+100 to +200bp', '>+200bp'
        ]
    )

    summary = loans.groupby('sato_bucket').agg(
        count=('loan_id', 'count'),
        avg_fico=('fico', 'mean'),
        avg_ltv=('oltv', 'mean'),
        avg_cpr=('cpr_1mo', 'mean'),
        total_upb=('current_upb', 'sum')
    ).reset_index()

    return summary
```

### Example 4: Measuring Lock-In Effect

```sql
-- Quantify the lock-in effect on turnover speeds
SELECT
    vintage_year,
    AVG(note_rate) AS avg_note_rate,
    AVG(note_rate) - 6.50 AS avg_incentive_to_move,
    -- Negative means borrower would get a worse rate
    COUNT(CASE WHEN payoff_reason = 'HOME_SALE'
          AND payoff_month BETWEEN '2025-01-01' AND '2025-12-01'
          THEN 1 END) * 1.0
        / COUNT(*) AS annual_turnover_rate,
    SUM(current_upb) / 1e9 AS upb_billions
FROM loan_universe
WHERE loan_status = 'CURRENT'
    AND product = '30YR_FIXED'
GROUP BY vintage_year
ORDER BY vintage_year;
-- Expect 2020-2021 vintages to show very low turnover
-- due to extreme lock-in (3% note rates vs 6.5% market)
```

---

## Common Interview Questions & Answers

### Q1: What are the main components of mortgage prepayments, and which is most volatile?

**A:** The four main components are: (1) refinancing (rate/term and cash-out), (2) housing turnover (home sales), (3) curtailments (partial prepayments), and (4) defaults/liquidations (involuntary). Refinancing is by far the most volatile because it is highly sensitive to interest rate movements. In a falling-rate environment, refinancing can push total CPR above 50%, while in a rising-rate environment it can fall to near zero, leaving only the baseline turnover and curtailment components (typically 5-10% CPR combined).

### Q2: Explain refinance incentive and why it is not just WAC minus current rate.

**A:** The basic refinance incentive is indeed WAC minus current rate, but effective incentive must account for several friction factors: (1) closing costs — borrowers need enough monthly savings to recoup $3K-$8K in fees within a reasonable horizon; (2) loan size — the dollar savings from a given rate reduction scales with balance; (3) credit qualification — borrowers must meet current underwriting standards for FICO, LTV, DTI; (4) behavioral inertia — many borrowers are unaware of or unmotivated by the opportunity. This is why the S-curve flattens even at large incentives: not all borrowers with economic incentive will actually refinance.

### Q3: What is SATO and how would you use it in a prepayment model?

**A:** SATO is the Spread At Origination — the difference between a borrower's note rate and the prevailing market rate on their origination date. High SATO indicates the borrower paid above-market rates, typically due to credit risk factors (lower FICO, higher LTV, non-standard documentation). These borrowers tend to be less responsive to refinancing because they face the same qualifying barriers when applying for a new loan. In a model, SATO serves as a proxy for unobservable borrower credit quality and is included as a feature that reduces predicted refinance probability. It is particularly useful because it captures information beyond what FICO and LTV alone provide.

### Q4: How did the low-rate environment of 2020-2021 affect prepayment behavior for years afterward?

**A:** The 2020-2021 period produced a massive wave of originations and refinancings at historically low rates (2.5%-3.5%). When rates rose sharply in 2022-2024, these borrowers became deeply "locked in" — their existing rate was far below market, creating negative refinance incentive of 200-400bp. This suppressed both refinancing (zero incentive) and housing turnover (borrowers reluctant to give up their low rate to buy at a higher rate). The result was prepayment speeds for these vintages collapsing to 3-5% CPR, among the slowest on record. This also reduced housing inventory nationwide, as homeowners stayed in place, contributing to supply constraints and price pressure.

### Q5: Why should prepayment models estimate refinance and turnover components separately?

**A:** Because the drivers and dynamics are fundamentally different. Refinance is primarily driven by rate incentive, SATO, credit, and burnout — it can swing from 0 to 50%+ CPR. Turnover is driven by job mobility, life events, seasonality, and housing market conditions — it is relatively stable at 5-10% CPR. A single model conflating both would produce poor predictions in extreme environments: it might overestimate speeds when rates rise (turnover does not collapse to zero) or underestimate them in a refi wave (refinance response is non-linear). Separating components also enables better scenario analysis: "What if rates drop 100bp but housing freezes?" can only be answered if the components are modeled independently.

### Q6: How would you model the impact of a government policy change like HARP on prepayments?

**A:** I would approach this in three steps. First, identify the affected population: HARP targeted borrowers with LTV above 80% in GSE-backed loans, so I would flag all loans meeting the eligibility criteria. Second, analyze the historical data around HARP's introduction (2009) and expansion (2012) to estimate the incremental prepayment lift for eligible borrowers versus a control group. Third, incorporate the policy as a model feature — either a binary indicator for eligibility or an adjustment to the effective refinance incentive (since HARP removed the LTV barrier, it effectively widened the eligible population for refinancing). The key data engineering challenge is maintaining loan-level eligibility flags and integrating policy event dates into the feature pipeline.

---

## Tips

- **Always decompose observed speeds.** When speeds change unexpectedly, the first question is "which component changed?" Was it a rate-driven refinance shift, a seasonal turnover change, or a policy-driven effect?
- **SATO is an underappreciated feature.** If your data has origination dates and note rates, compute SATO for every loan. It is one of the strongest predictors of prepayment heterogeneity within a pool.
- **Lock-in is the mirror image of refinance incentive.** Don't model them as separate phenomena — they are the same S-curve viewed from both sides. Negative incentive suppresses both refi and turnover.
- **Maintain a clean market rate history table.** You need daily or weekly primary mortgage market survey rates (Freddie Mac PMMS or similar) for computing incentives and SATO. This is foundational reference data.
- **Cash-out refi responds to HPI, not just rates.** If you only track rate incentive, you will miss cash-out refi activity that accelerates when home prices rise. Include HPI growth as a model feature.
- **Policy changes create regime breaks.** When HARP or similar programs launch, prepayment model coefficients estimated on pre-policy data become unreliable. Flag policy event dates and consider regime-specific model parameters.
- **For production models, retrain quarterly.** Prepayment behavior shifts as the borrower population evolves (new originations, burnout of seasoned pools, policy changes). Stale model coefficients degrade forecast accuracy.
