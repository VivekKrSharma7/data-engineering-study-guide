# Agency MBS Structure & Pass-Through Securities

[Back to Secondary Market Index](./README.md)

---

## Table of Contents

1. [Overview](#overview)
2. [What Is a Pass-Through Security?](#what-is-a-pass-through-security)
3. [Key Pool-Level Metrics](#key-pool-level-metrics)
4. [Fee Structure: G-Fee, Servicing Fee, and Net Coupon](#fee-structure-g-fee-servicing-fee-and-net-coupon)
5. [Principal Distribution: Scheduled vs Unscheduled](#principal-distribution-scheduled-vs-unscheduled)
6. [Original Face vs Current Face and Pool Factor](#original-face-vs-current-face-and-pool-factor)
7. [Uniform MBS (UMBS) and TBA Eligibility](#uniform-mbs-umbs-and-tba-eligibility)
8. [Prepayment Risk in Pass-Throughs](#prepayment-risk-in-pass-throughs)
9. [Real-World Examples](#real-world-examples)
10. [Common Interview Questions & Answers](#common-interview-questions--answers)
11. [Tips](#tips)

---

## Overview

Agency mortgage-backed securities (MBS) are bonds issued and guaranteed by one of the three US housing agencies: **Ginnie Mae (GNMA)**, **Fannie Mae (FNMA)**, and **Freddie Mac (FHLMC)**. The most fundamental type is the **pass-through security**, in which monthly cash flows from an underlying pool of residential mortgages are collected by a servicer and "passed through" to investors on a pro-rata basis. Understanding the mechanics of these securities is essential for any data engineer working in the secondary mortgage market.

---

## What Is a Pass-Through Security?

A pass-through MBS represents an undivided ownership interest in a pool of residential mortgage loans. Each investor holds a proportional share of the pool and receives:

- **Interest** on the outstanding principal balance (at the net coupon rate).
- **Scheduled principal** (the amortization component of borrowers' monthly payments).
- **Unscheduled principal** (prepayments, including refinances, curtailments, and liquidations).

### Cash Flow Timeline

1. Borrowers make monthly payments (or prepay) to the loan servicer.
2. The servicer remits funds to the agency (e.g., Fannie Mae).
3. The agency passes through the net cash flows to MBS investors, typically with a **stated delay** (e.g., Fannie Mae 55-day delay, Freddie Mac 75-day delay for Gold PCs, GNMA 45-day delay for GNMA I).

### Pro-Rata Distribution

Every investor in a given pool receives the same proportion of every dollar of interest and principal. If you own 1% of the pool, you get 1% of every payment — there is no tranching or prioritization in a plain pass-through.

---

## Key Pool-Level Metrics

### Weighted Average Coupon (WAC)

The **WAC** is the weighted average of the gross note rates of all loans in the pool, weighted by their current unpaid principal balance (UPB).

```
WAC = SUM(loan_note_rate * loan_upb) / SUM(loan_upb)
```

- WAC changes over time as loans prepay at different rates.
- A pool with a WAC of 5.25% might have loans ranging from 4.75% to 5.75%.
- WAC is always higher than the pass-through coupon (net coupon) because of servicing and guaranty fees.

### Weighted Average Maturity (WAM)

The **WAM** is the weighted average of the remaining term to maturity (in months) of all loans in the pool, weighted by current UPB.

```
WAM = SUM(remaining_months * loan_upb) / SUM(loan_upb)
```

- A newly issued 30-year pool has a WAM near 360 months.
- WAM decreases over time as loans age (and faster if longer-term loans prepay first).
- WAM affects duration and price sensitivity.

### Weighted Average Loan Age (WALA)

The **WALA** is the weighted average number of months since origination for all loans in the pool, weighted by current UPB.

```
WALA = SUM(loan_age_months * loan_upb) / SUM(loan_upb)
```

- WALA + WAM approximately equals the original loan term (e.g., 360 for a 30-year pool), though this is not exact because different loans may have had different original terms.
- Seasoned pools (higher WALA) tend to have different prepayment characteristics than new pools.

### Relationship Between WAC, WAM, and WALA

| Metric | Driven By | Changes Over Time? | Impact |
|--------|-----------|-------------------|--------|
| WAC | Loan note rates & UPB weights | Yes (as loans prepay) | Determines cash flow yield |
| WAM | Remaining months & UPB weights | Yes (decreases with aging/prepayments) | Affects duration |
| WALA | Loan age & UPB weights | Yes (increases with aging) | Indicates seasoning |

---

## Fee Structure: G-Fee, Servicing Fee, and Net Coupon

The difference between what borrowers pay (the gross note rate) and what investors receive (the pass-through coupon) is consumed by two fees:

### Guaranty Fee (G-Fee)

- Charged by the agency (Fannie Mae, Freddie Mac) for guaranteeing timely payment of principal and interest.
- Typically ranges from **15 to 60+ basis points** depending on the risk profile of the loans, the lender, and market conditions.
- Post-2012 reforms (including the FHFA-directed increase and the Temporary Payroll Tax Cut Continuation Act "TCCA fee") raised g-fees significantly.
- G-fees are a critical revenue source for the GSEs and a key input in loan pricing.

### Servicing Fee

- Compensation to the loan servicer for collecting payments, managing escrow, handling delinquencies, and reporting.
- Minimum servicing fee is typically **25 basis points** for Fannie Mae and Freddie Mac conventional loans, **6.25 basis points** for GNMA multi-issuer pools (GNMA II) with a 19 bps base plus 6.25 bps minimum.
- Excess servicing (above the minimum) can be retained or sold separately.

### Net Coupon (Pass-Through Rate)

```
Net Coupon = WAC - G-Fee - Servicing Fee
```

**Example:**
- WAC: 5.50%
- Servicing Fee: 0.25%
- G-Fee: 0.45%
- Net Coupon (Pass-Through Rate): 5.50% - 0.25% - 0.45% = **4.80%**

However, in practice, agency MBS are issued with standardized coupons in 50 bps increments (e.g., 4.0%, 4.5%, 5.0%). The actual WAC of the underlying loans will vary, and the resulting g-fee/servicing strip absorbs the difference.

---

## Principal Distribution: Scheduled vs Unscheduled

### Scheduled Principal

- The portion of a borrower's monthly payment that reduces the loan balance according to the original amortization schedule.
- Predictable and follows a known amortization formula.
- In the early years of a 30-year mortgage, scheduled principal is a small fraction of the monthly payment; it grows over time.

### Unscheduled Principal (Prepayments)

Unscheduled principal comes from any principal payment that is **not** part of the regular amortization schedule:

| Type | Description |
|------|-------------|
| **Full Prepayment (Payoff)** | Borrower refinances or sells the home, paying off the entire remaining balance. |
| **Curtailment** | Borrower makes an extra principal payment beyond the scheduled amount. |
| **Liquidation** | Loan is resolved through foreclosure, short sale, or REO disposition; remaining principal is recovered (or covered by the agency guarantee). |
| **Repurchase** | Servicer or originator buys back a defective loan from the pool, returning principal to investors. |

### Why This Matters for Data Engineers

- Loan-level data feeds (e.g., Fannie Mae's Loan Performance dataset) distinguish between these types.
- Prepayment models (CPR, PSA, SMM) attempt to forecast unscheduled principal.
- Data pipelines must correctly attribute principal payments to the right category for accurate analytics and reporting.

---

## Original Face vs Current Face and Pool Factor

### Original Face

The **original face** (also called original balance or original UPB) is the total principal balance of the pool at issuance. It never changes.

### Current Face

The **current face** is the remaining outstanding principal balance of the pool at a given point in time. It decreases as borrowers make scheduled payments and prepayments.

### Pool Factor

The **pool factor** is the ratio of the current face to the original face, expressed as a decimal between 0 and 1.

```
Pool Factor = Current Face / Original Face
```

**Example:**
- Original Face: $500,000,000
- Current Face after 36 months: $420,000,000
- Pool Factor: 420,000,000 / 500,000,000 = **0.84**

### Practical Usage

- Pool factors are published monthly by the agencies (Fannie Mae PoolTalk, Freddie Mac FactorSource, GNMA Disclosure).
- When you buy/sell an MBS, the trade is executed based on original face, but the actual dollar settlement is based on the **current face** (original face multiplied by the pool factor at settlement).
- Data engineers must track factor dates and ensure that cash flow calculations use the correct factor for the correct period.

---

## Uniform MBS (UMBS) and TBA Eligibility

### The Single Security Initiative

In June 2019, the **FHFA Single Security Initiative** was implemented, creating the **Uniform MBS (UMBS)**:

- Fannie Mae MBS and Freddie Mac PCs were aligned into a single, fungible security.
- Both agencies now issue UMBS with a **55-day payment delay** (Freddie Mac moved from 75 days to 55 days).
- UMBS trade in the TBA market under a single set of stipulations, increasing liquidity.

### TBA Eligibility Requirements

For an MBS pool to be **TBA-eligible** (deliverable into a TBA trade), it must meet specific criteria:

- **Agency**: GNMA, Fannie Mae, or Freddie Mac (UMBS for the latter two).
- **Loan Type**: Conventional fixed-rate (for UMBS) or government fixed-rate (for GNMA).
- **Original Term**: Must match the TBA contract (e.g., 30-year, 15-year, 20-year).
- **Pool Size**: Minimum and maximum constraints per SIFMA guidelines.
- **Coupon**: Must match the TBA coupon (in 50 bps increments).
- **Variance**: Delivered face value must be within 0.01% of the agreed trade amount (per good delivery rules).

### Why UMBS Matters

- Before UMBS, Fannie Mae MBS traded at a slight premium to Freddie Mac PCs due to the more favorable payment delay — this created a "Fannie/Freddie spread."
- UMBS eliminated this discrepancy, making the two interchangeable in the TBA market.
- Data engineers working with historical data must account for the pre-UMBS vs post-UMBS transition (June 2019).

---

## Prepayment Risk in Pass-Throughs

### What Is Prepayment Risk?

Prepayment risk is the risk that borrowers will pay off their mortgages earlier (or later) than expected, disrupting the expected cash flow profile of the MBS.

### Two Sides of Prepayment Risk

| Risk | Scenario | Impact on Investor |
|------|----------|--------------------|
| **Contraction Risk** | Interest rates fall; borrowers refinance rapidly | Principal is returned early; investor must reinvest at lower rates |
| **Extension Risk** | Interest rates rise; borrowers hold onto their mortgages | Principal is returned more slowly; investor is locked into a lower-yielding asset for longer |

### Key Prepayment Measures

- **SMM (Single Monthly Mortality)**: The percentage of the pool's beginning-of-month balance that prepays in a given month.
- **CPR (Conditional Prepayment Rate)**: The annualized version of SMM. `CPR = 1 - (1 - SMM)^12`
- **PSA (Public Securities Association) Model**: A standardized prepayment ramp. 100% PSA assumes CPR increases by 0.2% per month for the first 30 months, reaching 6% CPR, then remains flat. Pools are quoted as a percentage of PSA (e.g., 150% PSA means 1.5x the standard ramp).

### Factors Driving Prepayments

1. **Interest Rate Environment**: The dominant driver. When rates drop, refinancing surges.
2. **Borrower Incentive**: The difference between the borrower's note rate and current market rates (the "refi incentive").
3. **Seasoning**: New loans prepay slowly (the "seasoning ramp"); prepayment speeds increase over the first 2-5 years.
4. **Burnout**: Pools that have been through a refinancing wave tend to slow down — the most rate-sensitive borrowers have already left.
5. **Seasonality**: Home sales (and thus prepayments from home turnover) peak in summer months.
6. **Geography & Loan Size**: Jumbo-balance borrowers tend to be more responsive to rate incentives.
7. **Credit Score & LTV**: Higher-credit borrowers refinance more easily.

### Data Engineering Implications

- Prepayment data arrives monthly from the agencies via factor files and loan-level disclosures.
- Prepayment models require historical loan-level data, interest rate curves, and macro-economic indicators.
- Data pipelines must handle the **delay** between when a borrower prepays and when the factor reflects the change.

---

## Real-World Examples

### Example 1: Anatomy of a UMBS 5.0 Pool

```
Pool ID:          FM AB1234 (Fannie Mae)
Original Face:    $350,000,000
Issue Date:       March 2025
Pass-Through Rate: 5.0%
WAC:              5.68%
WAM:              356 months
WALA:             4 months
Number of Loans:  1,247
Avg Loan Size:    $280,673
Pool Factor:      0.9876 (as of Feb 2026)
Current Face:     $345,660,000
```

**Fee Breakdown:**
- WAC: 5.68%
- Net Coupon: 5.00%
- Total Strip: 0.68% (= 5.68% - 5.00%)
  - Servicing Fee: 0.25%
  - G-Fee: 0.43%

**Monthly Cash Flow to Investor (simplified for $1M face):**
- Interest: $1,000,000 x 0.9876 x (5.00% / 12) = **$4,115**
- Scheduled Principal: ~$1,200 (early in life, mostly interest)
- Prepayments (at 8% CPR): ~$5,300
- Total Monthly Cash Flow: ~$10,615

### Example 2: Seasoned GNMA Pool

```
Pool ID:          GN MA5678 (GNMA I)
Original Face:    $500,000,000
Issue Date:       January 2020
Pass-Through Rate: 3.5%
WAC:              4.12%
WAM:              288 months
WALA:             72 months (6 years seasoned)
Pool Factor:      0.4235
Current Face:     $211,750,000
```

This pool has lost over half its balance in 6 years, indicating heavy prepayments — likely driven by the historically low rates in 2020-2021. The remaining borrowers are "burned out" (less likely to refinance), so current prepayment speeds are likely much slower.

### Example 3: SQL Query — Compute WAC, WAM, WALA

```sql
SELECT
    pool_id,
    SUM(note_rate * current_upb) / SUM(current_upb) AS wac,
    SUM(remaining_term * current_upb) / SUM(current_upb) AS wam,
    SUM(loan_age * current_upb) / SUM(current_upb) AS wala,
    SUM(current_upb) AS current_face,
    SUM(current_upb) / MAX(original_pool_face) AS pool_factor
FROM loan_level_data
WHERE pool_id = 'AB1234'
  AND reporting_period = '2026-02-01'
GROUP BY pool_id;
```

---

## Common Interview Questions & Answers

### Q1: What is a pass-through MBS and how do cash flows work?

**A:** A pass-through MBS represents a pro-rata ownership share in a pool of mortgage loans. Each month, borrowers make payments to a servicer, who forwards the net cash flows (after deducting servicing and guaranty fees) to investors. Each investor receives their proportional share of interest, scheduled principal, and any unscheduled principal (prepayments). The key characteristic is that all investors receive the same proportional cash flow — there is no subordination or tranching.

### Q2: Explain the relationship between WAC, servicing fee, g-fee, and net coupon.

**A:** The WAC is the weighted average gross note rate paid by borrowers. From the WAC, two fees are deducted: the servicing fee (paid to the servicer for loan administration, typically 25 bps minimum) and the guaranty fee (paid to the agency for credit protection). What remains is the net coupon, or pass-through rate, which is what MBS investors receive. Formula: Net Coupon = WAC - Servicing Fee - G-Fee.

### Q3: What is the pool factor and why does it matter?

**A:** The pool factor is the ratio of a pool's current outstanding balance to its original face value, expressed as a decimal. It decreases over time as borrowers make scheduled payments and prepayments. It matters because MBS trades are quoted on original face, but the actual dollar amount that changes hands at settlement is the original face multiplied by the pool factor. If you buy $10M face of a pool with a factor of 0.85, you actually pay for $8.5M of current balance (times the agreed price). Data engineers must track factors monthly for accurate P&L, risk, and cash flow calculations.

### Q4: What is the difference between contraction risk and extension risk?

**A:** Contraction risk occurs when interest rates decline and borrowers prepay faster than expected. The investor receives principal back sooner and must reinvest at lower prevailing rates — effectively losing a high-yielding asset. Extension risk is the opposite: when rates rise, borrowers slow prepayments, and the investor is stuck holding a below-market-rate asset for longer than expected. Pass-through investors are exposed to both risks simultaneously, which is why MBS exhibit "negative convexity."

### Q5: What was the purpose of the UMBS/Single Security Initiative?

**A:** Before June 2019, Fannie Mae MBS and Freddie Mac PCs were separate, non-fungible securities. Freddie Mac PCs had a 75-day payment delay compared to Fannie Mae's 55-day delay, causing Freddie Mac PCs to trade at a discount. This reduced liquidity and increased Freddie Mac's cost of securitization. The Single Security Initiative created UMBS — a uniform security standard with a 55-day delay for both agencies. Now Fannie Mae and Freddie Mac pools are interchangeable in the TBA market, increasing liquidity and eliminating the pricing disadvantage.

### Q6: How would you build a data pipeline to track MBS pool factors and compute WAC/WAM/WALA over time?

**A:** I would design a pipeline with three main components:
1. **Ingestion**: Pull monthly loan-level disclosure files from agency sources (Fannie Mae, Freddie Mac, GNMA) and factor files. Parse the fixed-width or delimited files and load them into a staging area (e.g., S3 + Glue, or a staging schema in a data warehouse).
2. **Transformation**: Join loan-level data to pool mappings, compute weighted averages (WAC, WAM, WALA) per pool per reporting period, calculate pool factors by summing current UPB and dividing by original face. Handle edge cases like loan removals, repurchases, and modifications.
3. **Serving**: Materialize the results into a fact table (pool-month grain) with columns for pool_id, reporting_period, current_face, pool_factor, wac, wam, wala, cpr, etc. Build incremental processing so only new months are computed. Add data quality checks to flag anomalies (e.g., factor increases, negative CPR).

### Q7: What is SMM and how does it relate to CPR?

**A:** SMM (Single Monthly Mortality) is the fraction of a pool's outstanding balance that prepays in a single month. CPR (Conditional Prepayment Rate) is the annualized equivalent. The conversion is: CPR = 1 - (1 - SMM)^12, or equivalently, SMM = 1 - (1 - CPR)^(1/12). For example, if a pool has a CPR of 12%, the monthly SMM is approximately 1.06%. These metrics are essential for projecting future cash flows and for validating prepayment models.

### Q8: Why does seasoning matter for prepayment analysis?

**A:** New mortgage borrowers rarely prepay immediately — they just went through the effort of obtaining a loan. Prepayment speeds tend to ramp up over the first 30 months (the "seasoning ramp" described by the PSA model) before leveling off. After that, a pool's prepayment behavior is driven more by rate incentives, borrower demographics, and burnout effects. WALA tells you where a pool sits on this seasoning curve, which directly impacts prepayment projections and pricing.

---

## Tips

1. **Know your delays**: Fannie Mae UMBS = 55 days, GNMA I = 45 days, GNMA II = 50 days. This delay between the borrower's payment date and the investor's receipt date affects yield calculations and cash flow timing.

2. **Factor dates are critical**: Pool factors are published on specific dates (usually mid-month for the prior month's activity). When building data pipelines, always join on the correct factor date to avoid stale or future-looking data.

3. **WAC is not static**: As faster-paying or slower-paying loans prepay out of a pool, the WAC, WAM, and WALA all shift. This is sometimes called "composition drift" and it means these metrics must be recalculated every month.

4. **Understand the fee waterfall**: In interviews, being able to clearly walk through Borrower Rate -> minus Servicing Fee -> minus G-Fee -> equals Net Coupon demonstrates strong domain knowledge.

5. **MBS coupons trade in 50 bps increments**: A UMBS 5.0 has a pass-through rate of 5.0%, but the underlying loans will have a WAC that is typically 50-80 bps higher. The "coupon stack" (the set of actively traded coupons) shifts as interest rates move.

6. **GNMA vs Conventional**: GNMA pools are backed by government-insured loans (FHA, VA, USDA) and carry the full faith and credit of the US government. Fannie/Freddie UMBS are not explicitly government-guaranteed but carry an implied guarantee and are currently in conservatorship. This distinction matters for credit risk modeling and regulatory capital treatment.

7. **For data engineering roles**: Be prepared to discuss how you would model loan-level vs pool-level data, handle monthly factor updates, compute derived metrics, and ensure data quality. Agencies publish detailed file layouts — knowing where to find them (e.g., Fannie Mae's Loan-Level Disclosure documentation) signals real experience.

8. **Negative convexity**: Pass-throughs exhibit negative convexity because prepayments accelerate when rates fall (capping price upside) and slow when rates rise (amplifying price downside). This is the fundamental reason CMOs were invented — to redistribute this prepayment risk into tranches with more predictable behavior.
