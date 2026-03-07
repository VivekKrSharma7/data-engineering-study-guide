# Loan Types: Fixed, ARM, Hybrid, IO, and Balloon Mortgages

[Back to Secondary Market Index](./README.md)

---

## Overview

Understanding mortgage loan types is foundational for any data engineer working in the US secondary market. Each loan type carries distinct amortization schedules, rate structures, and risk profiles that directly influence prepayment speeds, default probabilities, and how loans are pooled into mortgage-backed securities (MBS). The data fields, calculations, and behavioral models differ significantly across these types, making this knowledge critical for building accurate pipelines and analytics.

---

## Key Concepts

### 1. Fixed-Rate Mortgages (FRM)

A fixed-rate mortgage locks in the interest rate for the entire life of the loan. The monthly principal and interest (P&I) payment remains constant, making these the most straightforward loan type from both a borrower and data perspective.

**Common Terms:**

| Term | Typical Use Case | Market Share |
|------|-----------------|--------------|
| **30-year fixed** | Most popular; lower monthly payments, higher total interest | ~70-75% of originations |
| **20-year fixed** | Middle ground; moderate payments, significant interest savings | ~3-5% |
| **15-year fixed** | Aggressive paydown; higher monthly payment, much lower total interest | ~10-15% |
| **10-year fixed** | Rare for purchase; common for refinance by older borrowers | <2% |

**Amortization Mechanics:**

- Fully amortizing: every scheduled payment includes both principal and interest such that the balance reaches zero at maturity.
- Early payments are interest-heavy; later payments are principal-heavy (standard amortization schedule).
- Monthly payment formula: `M = P * [r(1+r)^n] / [(1+r)^n - 1]` where P = principal, r = monthly rate, n = number of payments.

**Key Data Fields:**

| Field | Description | Example |
|-------|-------------|---------|
| `note_rate` | The fixed interest rate on the note | 6.500% |
| `original_loan_term` | Term in months | 360 |
| `original_loan_amount` | Initial UPB at origination | $350,000 |
| `maturity_date` | Date of final scheduled payment | 2055-03-01 |
| `amortization_type` | Fixed-rate indicator | "FRM" or "Fixed" |
| `first_payment_date` | Date of the borrower's first payment | 2025-05-01 |
| `scheduled_balance` | Expected UPB based on amortization schedule | Varies monthly |

---

### 2. Adjustable-Rate Mortgages (ARM)

An ARM has an interest rate that resets periodically based on a reference index plus a margin. The borrower's payment changes at each reset, introducing interest rate risk.

**Core Components:**

#### Index
The benchmark rate the ARM is tied to. Common indices include:

| Index | Description | Status |
|-------|-------------|--------|
| **SOFR (Secured Overnight Financing Rate)** | Based on overnight Treasury repo transactions | Current standard (replaced LIBOR) |
| **1-Year Treasury (CMT)** | Constant Maturity Treasury yield | Still used for some legacy products |
| **LIBOR** | London Interbank Offered Rate | Discontinued as of June 2023; legacy loans transitioned to SOFR |
| **11th District COFI** | Cost of Funds Index | Rare; mostly legacy West Coast ARMs |
| **Prime Rate** | Base lending rate published by banks | Used in some HELOCs and second liens |

#### Margin
A fixed spread added to the index to determine the fully indexed rate. Typical margins range from 1.75% to 3.00%. The margin never changes over the life of the loan.

```
Fully Indexed Rate = Current Index Value + Margin
Example: 4.50% (SOFR 30-day avg) + 2.25% (margin) = 6.75%
```

#### Caps Structure
Caps limit how much the rate can change, protecting borrowers from payment shock:

| Cap Type | Description | Typical Value |
|----------|-------------|---------------|
| **Initial Adjustment Cap** | Maximum rate increase at the first reset | 2% or 5% |
| **Periodic Adjustment Cap** | Maximum rate change at each subsequent reset | 1% or 2% |
| **Lifetime Cap** | Maximum rate over the life of the loan (above initial rate) | 5% or 6% |
| **Floor** | Minimum rate (often the margin itself) | 2.25% (margin) |

A common cap structure notation is **2/2/5** (initial/periodic/lifetime) or **5/2/5**.

#### Reset Frequency
How often the rate adjusts after the initial fixed period:
- **Monthly:** Rate changes every month (rare, seen in option ARMs)
- **Semi-annually:** Every 6 months
- **Annually:** Most common for standard ARMs
- **Less frequent:** Some products reset every 3 or 5 years

**Key Data Fields for ARMs:**

| Field | Description | Example |
|-------|-------------|---------|
| `index_type` | Reference index code | "SOFR_30DAY" |
| `margin` | Fixed spread over index | 2.250% |
| `initial_cap` | First adjustment cap | 2.000% |
| `periodic_cap` | Subsequent adjustment cap | 2.000% |
| `lifetime_cap` | Maximum rate ceiling | 11.500% |
| `lifetime_floor` | Minimum rate floor | 2.250% |
| `next_rate_adjustment_date` | Date of next rate change | 2030-05-01 |
| `rate_adjustment_frequency` | Months between adjustments | 12 |
| `current_interest_rate` | Rate in the current period | 6.750% |
| `lookback_period` | Days before reset to capture index | 45 |

---

### 3. Hybrid ARMs (3/1, 5/1, 7/1, 10/1)

Hybrid ARMs combine a fixed-rate initial period with an adjustable-rate period for the remainder of the term. They are the most common form of ARM originated today.

**Naming Convention:** The first number is the fixed period in years; the second is the adjustment frequency in years.

| Product | Fixed Period | Then Adjusts | Typical Cap Structure | Common Use Case |
|---------|-------------|-------------|----------------------|-----------------|
| **3/1 ARM** | 3 years | Annually | 2/2/6 | Short-term ownership plans |
| **5/1 ARM** | 5 years | Annually | 2/2/5 or 5/2/5 | Most popular hybrid ARM |
| **7/1 ARM** | 7 years | Annually | 5/2/5 | Moderate-term ownership |
| **10/1 ARM** | 10 years | Annually | 5/2/5 | Near-fixed-rate alternative |
| **5/6 ARM** | 5 years | Every 6 months | 2/1/5 | Newer GSE product |

**Less common variants:** 3/3 ARM (adjusts every 3 years after initial 3-year period), 5/5 ARM.

**Data Considerations:**
- During the fixed period, the loan behaves identically to an FRM from a cash flow perspective.
- The `initial_fixed_period_months` field (e.g., 60 for a 5/1) is critical for determining when rate resets begin.
- Many borrowers refinance or sell before the first reset, leading to elevated prepayment speeds as the reset date approaches.

---

### 4. Interest-Only (IO) Loans

During the interest-only period, the borrower pays only interest with no principal reduction. After the IO period expires, the loan converts to a fully amortizing schedule over the remaining term.

**Structure:**

```
Example: 30-year loan with 10-year IO period
- Years 1-10: Pay interest only on the full balance
- Years 11-30: Fully amortizing payments over 20 years (higher payment)
```

**Payment Shock Calculation:**

```
Assume: $400,000 loan at 6.50%

IO Period Monthly Payment:
  $400,000 * 0.065 / 12 = $2,166.67

Amortizing Period Monthly Payment (20-year remaining):
  $400,000 * [0.005417(1.005417)^240] / [(1.005417)^240 - 1] = $2,981.56

Payment Increase: +$814.89 (+37.6%)
```

**Key Data Fields:**

| Field | Description | Example |
|-------|-------------|---------|
| `io_flag` | Whether the loan has an IO feature | Y/N |
| `io_period_months` | Length of the interest-only period | 120 |
| `io_expiration_date` | When IO period ends | 2035-05-01 |
| `amortizing_term_months` | Remaining term after IO ends | 240 |

**Risk Profile:**
- Higher default risk at IO-to-amortizing transition due to payment shock.
- No equity build-up during the IO period (beyond appreciation).
- Common in jumbo and non-QM segments; rare in conforming post-2010.

---

### 5. Balloon Mortgages

A balloon mortgage has scheduled payments that do not fully amortize the loan by the maturity date. The remaining balance (the "balloon payment") is due in full at maturity.

**Common Structures:**

| Product | Amortization Schedule | Balloon Due At | Description |
|---------|----------------------|----------------|-------------|
| **5/25 Balloon** | 30-year amortization | 5 years | Low early payments; large balloon at year 5 |
| **7/23 Balloon** | 30-year amortization | 7 years | Similar but with 7-year runway |
| **15-year Balloon** | 30-year amortization | 15 years | Longer horizon; still has large payoff |

**Key Data Fields:**

| Field | Description | Example |
|-------|-------------|---------|
| `balloon_flag` | Whether loan has a balloon feature | Y/N |
| `balloon_date` | Date balloon payment is due | 2030-05-01 |
| `balloon_amount` | Estimated balloon payment | $342,000 |
| `amortization_term` | Schedule used for payment calculation | 360 months |
| `actual_term` | When balloon is due | 60 months |

**Market Context:**
- Largely fell out of favor after the 2008 crisis.
- Not eligible for QM status under CFPB rules.
- Still occasionally seen in portfolio lending and commercial crossover products.

---

### 6. Graduated Payment Mortgages (GPM)

GPMs feature payments that start low and increase at a predetermined rate over a set period, then level off for the remaining term.

**Structure:**
- Payments increase annually (typically 2-7.5% per year) for the first 5-10 years.
- After the graduation period, payments remain fixed.
- Early payments may be less than the interest due, causing **negative amortization**.

**FHA GPM Plans (Historical):**

| Plan | Annual Increase | Graduation Period |
|------|----------------|-------------------|
| Plan I | 2.5% | 5 years |
| Plan II | 5.0% | 5 years |
| Plan III | 7.5% | 5 years |
| Plan IV | 2.0% | 10 years |
| Plan V | 3.0% | 10 years |

**Data Considerations:**
- Rare in modern origination but present in legacy servicing portfolios.
- Negative amortization means the `current_upb` can exceed the `original_loan_amount`.
- Maximum negative amortization cap is typically 110-125% of the original balance.

---

### 7. Negative Amortization Loans

Negative amortization occurs when the scheduled payment is less than the interest due, causing the unpaid interest to be added to the principal balance.

**Products That Can Negatively Amortize:**
- Payment Option ARMs (Pick-a-Pay): Borrower chooses from multiple payment options monthly.
- GPMs (during the early graduation period).
- Some IO ARMs if the rate rises but the payment is capped.

**Recast Triggers:**
- The balance reaches a predetermined cap (e.g., 110% or 115% of original balance).
- A scheduled recast date (e.g., every 5 years).
- The loan recasts to a fully amortizing payment over the remaining term.

**Key Data Fields:**

| Field | Description | Example |
|-------|-------------|---------|
| `neg_am_flag` | Negative amortization feature | Y/N |
| `neg_am_cap` | Maximum balance as % of original | 115% |
| `neg_am_recast_period` | Months between mandatory recasts | 60 |
| `deferred_interest` | Accumulated unpaid interest | $12,500 |

---

### 8. Fully Amortizing vs. Partially Amortizing

| Characteristic | Fully Amortizing | Partially Amortizing |
|---------------|-----------------|---------------------|
| **Balance at maturity** | $0 | > $0 (balloon or residual) |
| **Payment structure** | P&I from day one | May have IO period, balloon, or neg-am |
| **Examples** | 30yr FRM, standard ARM | Balloon, IO loans, GPMs |
| **QM eligible** | Generally yes | Generally no (balloon, neg-am) |
| **Scheduled factor path** | Monotonically decreasing | May be flat or increasing before decreasing |

---

### 9. Impact on Prepayment and Default Behavior

Understanding how loan type affects borrower behavior is essential for building risk models and accurate cash flow engines.

#### Prepayment Behavior

| Loan Type | Prepayment Characteristics |
|-----------|---------------------------|
| **30yr FRM** | Highly sensitive to rate incentive (refinance). S-curve response to rate differential. Baseline CPR ~5-8% in neutral rate environment. |
| **15yr FRM** | Lower refinance sensitivity (borrowers are already aggressive payers). Higher curtailment (partial prepayment) rates. |
| **Hybrid ARM (5/1)** | Elevated prepayment as reset date approaches. Borrowers refinance to avoid uncertainty. CPR can spike to 30-50% near first reset. |
| **IO Loans** | Moderate prepay during IO period. Spike near IO expiration as borrowers refinance to avoid payment shock. |
| **Balloon** | Extremely high prepayment (near 100% CPR) at balloon date since borrowers must refinance or sell. |

#### Default Behavior

| Loan Type | Default Characteristics |
|-----------|------------------------|
| **30yr FRM** | Baseline default; driven by equity (LTV) and ability to pay (DTI, employment). |
| **15yr FRM** | Lower default rates; borrowers are typically more financially stable and build equity faster. |
| **ARM/Hybrid** | Elevated default risk at reset if rates rise significantly (payment shock). |
| **IO Loans** | Higher default at IO-to-amortizing transition. No equity build-up increases strategic default risk. |
| **Neg-Am** | Highest default risk category. Underwater borrowers with increasing balances. Major contributor to 2008 crisis losses. |
| **Balloon** | Default risk concentrates around balloon date if borrower cannot refinance. |

---

## Real-World Examples

### Example 1: Building a Cash Flow Engine

You are building a loan-level cash flow projection engine. A pool contains a mix of 30yr FRM, 5/1 ARMs, and IO loans.

**Challenge:** Each loan type requires a different payment calculation:
- FRM: Static monthly P&I based on note rate and remaining term.
- 5/1 ARM: Static payment during fixed period, then recalculate at each reset using `index + margin`, subject to caps.
- IO: Interest-only payment during IO period, then recalculate fully amortizing payment over remaining term.

**Data Pipeline Approach:**
```
1. Classify loan by amortization_type and features (io_flag, balloon_flag)
2. Route to appropriate payment calculator
3. For ARMs: join to forward rate curve for projected index values
4. Apply cap/floor logic at each reset
5. Output: projected scheduled payment, principal, interest, and balance for each period
```

### Example 2: Prepayment Model Feature Engineering

Your team is building a prepayment model (CPR prediction). Loan type is a critical feature.

**Feature Engineering from Loan Type:**
```sql
SELECT
    loan_id,
    amortization_type,
    CASE
        WHEN amortization_type = 'ARM' AND months_to_first_reset <= 12 THEN 1
        ELSE 0
    END AS approaching_reset_flag,
    CASE
        WHEN io_flag = 'Y' AND months_to_io_expiration <= 6 THEN 1
        ELSE 0
    END AS approaching_io_expiration_flag,
    CASE
        WHEN amortization_type = 'FRM' THEN current_note_rate - current_market_rate
        ELSE current_note_rate - (current_index + margin)
    END AS rate_incentive,
    CASE
        WHEN balloon_flag = 'Y' AND months_to_balloon <= 12 THEN 1
        ELSE 0
    END AS approaching_balloon_flag
FROM loan_level_data;
```

### Example 3: ARM Index Transition (LIBOR to SOFR)

A legacy servicing portfolio contains 50,000 ARMs indexed to 1-month LIBOR. After LIBOR cessation, these must transition to SOFR + a spread adjustment.

**Data Migration Steps:**
```
1. Identify all loans where index_type = 'LIBOR_1M'
2. Apply the ARRC-recommended spread adjustment:
   - 1-month LIBOR -> SOFR + 0.11448%
   - 3-month LIBOR -> SOFR + 0.26161%
   - 6-month LIBOR -> SOFR + 0.42826%
3. Update index_type to 'SOFR_30DAY'
4. Recalculate lifetime floor = margin (SOFR-based)
5. Validate: new fully indexed rate should approximate old rate at transition date
6. Audit trail: preserve original index_type and adjustment in history table
```

---

## Common Interview Questions and Answers

### Q1: How does a 5/1 ARM work, and what data fields do you need to project its cash flows?

**Answer:** A 5/1 ARM has a fixed interest rate for the first 5 years (60 months), then adjusts annually based on a reference index plus a fixed margin. To project cash flows, I need:

- **`note_rate`** (initial fixed rate)
- **`index_type`** and **`margin`** (to calculate the rate at each reset)
- **`initial_fixed_period_months`** (60 for a 5/1)
- **`rate_adjustment_frequency`** (12 months for annual)
- **`initial_cap`**, **`periodic_cap`**, **`lifetime_cap`**, **`floor`** (to constrain rate changes)
- **`remaining_term`** and **`current_upb`** (for amortization calculation)
- A **forward rate curve** for the index to project future rates

At each reset, the new rate is: `min(max(index + margin, floor), previous_rate + periodic_cap, initial_rate + lifetime_cap)`. The payment is then recalculated as a fully amortizing payment over the remaining term at the new rate.

---

### Q2: What is payment shock, and why does it matter for data engineering?

**Answer:** Payment shock is a significant increase in the borrower's monthly payment, typically triggered by an ARM reset, IO period expiration, or negative amortization recast. For example, an IO loan at 6.5% on a $400,000 balance has a payment of ~$2,167. When the IO period ends and the loan amortizes over 20 remaining years, the payment jumps to ~$2,982 -- a 37.6% increase.

From a data engineering perspective, payment shock matters because:
1. **Risk modeling:** We need to calculate projected payment changes to feed default and prepayment models.
2. **Data quality:** We must track `io_expiration_date`, `next_rate_adjustment_date`, and cap structures accurately.
3. **Reporting:** Servicers and investors need early warning reports on loans approaching reset/expiration dates.
4. **Pipeline design:** Cash flow engines must handle the transition logic (IO to amortizing, rate resets with cap application).

---

### Q3: Explain negative amortization. How would you detect it in a loan-level dataset?

**Answer:** Negative amortization occurs when the borrower's scheduled payment is less than the interest accrued, causing unpaid interest to be added to the principal balance. The loan balance actually grows over time instead of shrinking.

To detect it in data:
```sql
-- Direct detection: balance increased month over month without a new disbursement
SELECT loan_id, reporting_period, current_upb, prior_upb
FROM loan_monthly
WHERE current_upb > prior_upb
  AND loan_modification_flag = 'N'
  AND additional_disbursement_amount = 0;

-- Feature-based detection
SELECT loan_id
FROM loan_master
WHERE neg_am_flag = 'Y'
   OR amortization_type = 'NEG_AM'
   OR current_upb > original_loan_amount;
```

I would also look for `neg_am_cap` (e.g., 115%), `deferred_interest` fields, and payment option indicators. For risk reporting, I would track the ratio of `current_upb / original_loan_amount` and flag loans approaching their neg-am cap, as a recast event will cause a sharp payment increase.

---

### Q4: How do prepayment speeds differ between a 30-year fixed and a 5/1 ARM, and why does this matter for MBS investors?

**Answer:**

**30-year FRM prepayment drivers:**
- Dominated by **rate refinancing**: when market rates fall below the note rate, borrowers refinance. The relationship follows an S-curve -- prepayment speeds increase sharply once the rate incentive exceeds ~50-75 bps.
- Baseline voluntary prepayment (turnover from home sales) runs ~5-8% CPR.
- Seasoning effect: speeds ramp up over the first 30 months as borrowers settle in.

**5/1 ARM prepayment drivers:**
- During the fixed period, prepayment is driven by turnover and rate incentive (similar to FRM but lower sensitivity since the initial rate is already lower).
- As the first reset date approaches (months 48-60), speeds accelerate sharply as borrowers refinance to avoid rate uncertainty. CPR can reach 30-50%.
- After reset, if the new rate is unfavorable, prepayment remains elevated; if favorable, speeds moderate.

**Why it matters for MBS:**
- ARM MBS have shorter effective duration and more volatile prepayment profiles.
- Investors price ARM MBS with higher prepayment assumptions, resulting in different yield and spread characteristics.
- As a data engineer, I need to ensure my pipelines correctly classify loan type and track reset dates so that analytics teams can apply the right prepayment model.

---

### Q5: You discover that 15% of the ARM loans in your dataset have NULL values for `initial_cap`, `periodic_cap`, or `lifetime_cap`. How do you handle this?

**Answer:** Missing cap data on ARMs is a serious data quality issue since it makes cash flow projection impossible. My approach:

1. **Investigate the source:** Check if the origination system or prior data vendor simply did not capture caps, or if the NULLs indicate a data load failure.
2. **Cross-reference:** Look up the loan program code or product description -- standard ARM products have well-known cap structures (e.g., 5/2/5 for a 5/1 ARM). I can build a mapping table from product code to expected caps.
3. **Supplement from disclosure data:** If these loans are in GSE pools, Fannie Mae and Freddie Mac loan-level disclosure files include cap information. I would join on loan identifiers to fill gaps.
4. **Apply reasonable defaults with flags:** For remaining gaps, apply industry-standard caps based on the ARM type, but flag these records with a `cap_source = 'IMPUTED'` indicator so downstream consumers know the values are inferred.
5. **Prevent recurrence:** Add data quality checks to the ingestion pipeline: reject or quarantine ARM records missing cap fields.

---

### Q6: What is the difference between a fully amortizing and a partially amortizing loan, and how does this affect your scheduled balance calculations?

**Answer:** A fully amortizing loan's scheduled payments are designed to pay off the entire principal by the maturity date -- the ending balance is zero. A partially amortizing loan has payments calculated on a longer amortization schedule than the actual term (balloon) or has periods with no principal payment (IO), so a residual balance remains at some point.

For scheduled balance calculations:
- **Fully amortizing:** I use the standard amortization formula and can calculate the expected balance at any month `t` deterministically.
- **IO loan:** During the IO period, the scheduled balance equals the original balance (no principal reduction). After IO expiration, I switch to a fully amortizing calculation over the remaining term.
- **Balloon:** I calculate the amortization schedule based on the amortization term (e.g., 30 years) but the actual balance at the balloon date becomes the balloon payment.
- **Neg-am:** The scheduled balance can actually increase, so I need to track deferred interest and apply recast logic.

In my data pipeline, I maintain a `scheduled_upb` field that reflects the expected balance assuming no prepayments or delinquency, calculated with loan-type-specific logic. This is compared against `actual_upb` to derive prepayment (SMM) and curtailment amounts.

---

## Tips for Interview Preparation

1. **Know the math:** Be prepared to calculate a monthly mortgage payment by hand, apply ARM cap logic, and demonstrate how IO-to-amortizing transitions work. Interviewers may give you a whiteboard scenario.

2. **Understand the data model:** For each loan type, know which additional fields are required beyond the base loan attributes. ARMs have 8-10 extra fields compared to FRMs. Build a mental schema.

3. **Connect loan type to behavior:** Always be ready to explain *why* a loan type prepays or defaults differently. The interviewer wants to see that you understand the economic incentives driving borrower behavior.

4. **LIBOR-to-SOFR transition:** This is a hot topic even years after the transition. Know the spread adjustments, the fallback waterfall, and the data migration challenges involved.

5. **Regulatory context matters:** Know that balloon and neg-am loans are generally not QM-eligible. This affects which loans end up in agency vs. private-label securitizations, which determines the data formats and systems you work with.

6. **Practice SQL for loan-type analysis:** Be ready to write queries that segment pools by loan type, calculate weighted average coupon (WAC) by product, identify approaching resets, and detect data quality issues.

7. **Know the abbreviations cold:** FRM, ARM, IO, GPM, neg-am, CPR, SMM, WAC, WAM, SOFR, CMT, COFI -- these will be used freely in interviews without explanation.

8. **Think about edge cases:** What happens when an ARM hits its lifetime cap? What if an IO loan is also an ARM? (IO/ARM hybrids exist and are common in jumbo.) How do you handle a loan that was modified from an ARM to an FRM? These crossover scenarios test depth.

---

*This material covers loan types relevant to US secondary market residential mortgage data engineering. Master the data fields and behavioral differences across these products, as they form the foundation for cash flow modeling, risk analytics, and securitization pipelines.*
