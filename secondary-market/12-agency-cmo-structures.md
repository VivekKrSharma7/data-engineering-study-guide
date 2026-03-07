# Agency CMO Structures

[Back to Secondary Market Index](./README.md)

---

## Overview

Collateralized Mortgage Obligations (CMOs) are structured securities backed by pools of mortgage pass-through securities or whole loans. Agency CMOs are issued by or guaranteed by Fannie Mae, Freddie Mac, or Ginnie Mae. The fundamental innovation of CMOs is the **redistribution of cash flows** from the underlying collateral into multiple tranches (classes) with different risk/return profiles. This tranching process does not eliminate prepayment risk or credit risk -- it reallocates them among investors with different preferences. For data engineers in the MBS space, understanding CMO structures is essential for building cash flow engines, data models, and analytics platforms.

---

## Key Concepts

### 1. Sequential Pay CMOs

The simplest and earliest CMO structure. Principal payments (both scheduled and prepaid) are directed to tranches in strict sequential order.

**How it works:**
- All tranches receive interest based on their outstanding balance.
- All principal (scheduled amortization + prepayments) goes to Tranche A until it is fully retired.
- Then all principal goes to Tranche B, then Tranche C, and so on.
- The last tranche has the longest average life and most extension/contraction risk.

**Example:**

| Tranche | Original Face | Avg Life (base case) | Receives Principal |
|---------|--------------|----------------------|-------------------|
| A | $50M | 2.1 years | First |
| B | $75M | 5.3 years | Second |
| C | $60M | 8.7 years | Third |
| D | $40M | 15.2 years | Last |

**Key insight:** Sequential pay structures separate the collateral's average life into short, intermediate, and long segments, allowing investors to match their duration preferences. However, all tranches still bear significant prepayment variability.

### 2. PAC Bonds (Planned Amortization Class)

PAC bonds are designed to provide the most predictable cash flows among CMO tranches. They achieve this by defining a **principal payment schedule** that holds as long as prepayment speeds remain within a specified band.

**PAC band mechanics:**
- Two prepayment speed assumptions define the band (e.g., 100 PSA to 300 PSA).
- At each month, the minimum principal that would be generated at either end of the band determines the PAC scheduled payment.
- The PAC tranche receives its scheduled principal as long as actual prepayments fall within the band.
- Excess principal (above the PAC schedule) is absorbed by the companion/support tranche.
- Shortfall in principal (below the PAC schedule) is compensated by redirecting principal from the companion tranche.

**PAC band drift:**
- Over time, if prepayments are consistently at one end of the band, the effective band narrows.
- Fast prepayments shrink the companion tranche, reducing future support for the PAC.
- This is called "band drift" or "broken PAC" in extreme cases.

**PAC II bonds:** A second tier of PAC bonds that receive protection from a narrower band. They sit between PAC I bonds and support tranches in priority.

### 3. Support (Companion) Tranches

Support tranches absorb the prepayment variability that PAC and TAC bonds are insulated from:

- **Fast prepayments**: Support tranches receive excess principal, shortening their average life dramatically.
- **Slow prepayments**: Support tranches receive little or no principal, extending their average life significantly.
- **Volatility**: Support tranches have the widest average life variability of any CMO tranche -- they can range from 2 years to 20+ years depending on prepayment speeds.
- **Yield premium**: Because of this volatility, support tranches offer higher yields to compensate investors.

**Companion tranche average life sensitivity example:**

| Prepayment Speed | PAC Avg Life | Support Avg Life |
|-----------------|-------------|-----------------|
| 100 PSA | 7.2 years | 18.5 years |
| 200 PSA | 7.1 years | 8.3 years |
| 300 PSA | 7.0 years | 3.1 years |
| 400 PSA | 6.5 years | 1.8 years |

The PAC is stable; the companion absorbs all the variability.

### 4. TAC Bonds (Targeted Amortization Class)

TAC bonds provide protection against prepayment acceleration but **not** against extension:

- A TAC schedule is defined based on a single prepayment speed assumption (e.g., 200 PSA).
- If speeds exceed the target, excess principal flows to the support tranche, protecting the TAC.
- If speeds are slower than the target, the TAC extends because there is no mechanism to accelerate principal to it.
- TACs offer less protection than PACs but more than sequential tranches.
- TAC bonds are sometimes called "one-sided PACs."

### 5. Z-Bonds (Accrual Bonds)

Z-bonds do not receive current interest payments. Instead, their accrued interest is added to their principal balance (accretion) and used to accelerate principal payments to earlier tranches.

**Mechanics:**
- During the accrual period, the Z-bond's balance grows as interest accrues.
- The accrued interest amount is paid as additional principal to the currently active sequential tranche.
- Once all prior tranches are retired, the Z-bond begins receiving both interest and principal.
- Z-bonds have very long average lives and behave similarly to zero-coupon bonds during the accrual phase.

**Benefits to the structure:**
- Provides a stable source of additional principal to earlier tranches, creating more front-loaded cash flows.
- Reduces the effective average life of earlier tranches.
- Creates a long-duration instrument attractive to insurance companies and pension funds.

### 6. Floaters and Inverse Floaters

CMO structures can create floating-rate and inverse floating-rate tranches from fixed-rate collateral:

**Floater:**
- Coupon = Reference Rate (e.g., SOFR) + Spread
- Has a cap (maximum coupon) determined by the collateral's fixed rate and the structure.
- Attractive to banks and money market participants seeking floating-rate exposure.

**Inverse Floater:**
- Coupon = Fixed Rate - (Multiplier x Reference Rate)
- Has a floor (usually 0%) and a cap.
- The leverage (multiplier) depends on the ratio of floater face to inverse floater face.
- When rates decline, the inverse floater coupon increases, creating significant upside but also substantial interest rate risk.

**Structural relationship:**
- If a $100M fixed-rate tranche paying 6% is split into a $75M floater and $25M inverse floater:
  - Floater: SOFR + 50 bps, cap = 7.5%
  - Inverse floater: 24% - 3 x SOFR, floor = 0%
  - The weighted average coupon must equal the collateral rate: (0.75 x floater coupon) + (0.25 x inverse coupon) = 6%
  - The leverage ratio for the inverse is 3x (= $75M / $25M).

### 7. IO/PO Strips

Interest-Only (IO) and Principal-Only (PO) strips separate the interest and principal components of MBS cash flows:

**PO Strip:**
- Receives only principal payments (scheduled + prepaid).
- Purchased at a deep discount to par.
- Benefits from fast prepayments (principal returned sooner, higher IRR).
- Behaves like a long position on prepayments and a long position on falling rates.

**IO Strip:**
- Receives only interest payments.
- Purchased based on a notional balance.
- Benefits from slow prepayments (interest stream persists longer).
- Behaves like a short position on prepayments and benefits from rising rates.
- Exhibits **negative duration** -- its value increases when rates rise.

**IO/PO as hedging tools:**
- IOs are used to hedge prepayment risk on servicing portfolios (MSRs behave similarly to IOs).
- POs are used to hedge extension risk or as a leveraged bet on falling rates.

### 8. CMO Waterfall

The waterfall defines the precise rules for distributing cash flows from the collateral to each tranche. A typical CMO waterfall includes:

1. **Collect cash flows**: Monthly principal and interest from the underlying collateral.
2. **Pay trustee/administrative fees**: Small amounts off the top.
3. **Pay interest**: To each tranche based on its coupon rate and current balance (except Z-bonds during accrual).
4. **Distribute principal**:
   - First, satisfy PAC scheduled amounts.
   - Then, apply remaining principal according to sequential or pro-rata rules.
   - Excess principal to support/companion tranches.
   - Z-bond accretion applied to active sequential tranches.
5. **Residual**: Any remaining cash flow to the residual holder (often retained by the issuer).

**Data engineering implications:**
- Building a waterfall engine requires precise implementation of the priority rules.
- Each deal has a unique waterfall defined in the prospectus supplement.
- Data models must track: tranche balances, accrued interest, principal distribution rules, lock-out periods, and trigger conditions.
- Deal-level data is available from sources like Intex, Bloomberg, and agency disclosure files.

### 9. REMIC Tax Structure

The Real Estate Mortgage Investment Conduit (REMIC) is the tax structure under which virtually all modern CMOs are issued:

- **Tax transparency**: A REMIC is not taxed at the entity level; income passes through to investors.
- **Requirements**: Must hold a fixed pool of qualifying real estate mortgages or MBS. Must have one or more classes of "regular interests" (tranches) and exactly one class of "residual interest."
- **Regular interests**: Taxed like debt instruments. Holders report interest income.
- **Residual interest**: Receives any remaining cash flows and bears the "phantom income" tax liability (income may be recognized for tax purposes even when no cash is received).
- **Why it matters**: The REMIC structure enables the creation of complex tranching without adverse tax consequences, which is why it became the standard for CMO issuance after the Tax Reform Act of 1986.

### 10. CMO Data Modeling

Data engineers supporting CMO analytics need to design systems that capture the complex hierarchical relationships:

**Core entities in a CMO data model:**

```
Deal (REMIC)
  |-- Collateral Group(s)
  |     |-- Underlying Pool(s) / Pass-through(s)
  |           |-- Loan-level data
  |
  |-- Tranche(s) / Class(es)
  |     |-- Tranche Type (PAC, SEQ, SUP, TAC, Z, FLT, INV, IO, PO)
  |     |-- Coupon rules (fixed, floating formula, IO notional)
  |     |-- Principal priority rules
  |     |-- Balance history (monthly)
  |     |-- Factor history
  |
  |-- Waterfall Rules
        |-- Priority of payments
        |-- PAC schedules / bands
        |-- Triggers / clean-up calls
```

**Key data modeling considerations:**
- **Temporal data**: Tranche balances, factors, and coupons change monthly. Use slowly changing dimension (SCD Type 2) or time-series tables.
- **Deal complexity**: A single CMO deal can have 30-50+ tranches with interdependent cash flow rules.
- **Source systems**: Intex (CDI files), Bloomberg (deal analytics), agency remittance reports, and trustee reports.
- **Performance metrics**: Track tranche factor, current face, WAL, projected prepayment speed, and cash flow projections.

---

## Real-World Examples

### Example 1: Building a PAC/Support Structure

Collateral: $500M FNMA 30yr 5.5% pass-through, current WAM 348 months.

| Tranche | Type | Face | Coupon | Avg Life (175 PSA) |
|---------|------|------|--------|---------------------|
| A-1 | PAC (Seq) | $80M | 5.5% | 2.3 yrs |
| A-2 | PAC (Seq) | $100M | 5.5% | 5.1 yrs |
| A-3 | PAC (Seq) | $120M | 5.5% | 8.5 yrs |
| S-1 | Support | $150M | 5.5% | 11.2 yrs |
| Z | Z-Bond | $50M | 5.5% | 19.8 yrs |

PAC band: 100-300 PSA. The PAC tranches pay sequentially within the PAC class. Support absorbs variability. Z-bond accretes during the early years, accelerating principal to A-1.

### Example 2: CMO Data Pipeline

A data engineering team builds a CMO analytics platform:

1. **Ingestion**: Load deal structure data from Intex (deal terms, waterfall rules, collateral mapping) and monthly remittance data from agency trustee reports.
2. **Transformation**: Apply waterfall logic to compute projected cash flows for each tranche under multiple prepayment scenarios.
3. **Storage**: Store deal structures in a relational model with deals, tranches, collateral groups, and waterfall rules. Store monthly factor/balance data in time-series tables.
4. **Analytics**: Compute WAL, yield, spread, and OAS for each tranche. Flag PAC bands at risk of breaking.
5. **Reporting**: Dashboard showing tranche performance vs. projections, collateral prepayment speeds, and support tranche depletion.

### Example 3: IO Strip Hedging

A mortgage servicer holds $10 billion in servicing rights (MSRs). MSR value declines when rates fall (faster prepayments reduce the servicing fee stream). The servicer buys $500 million notional of agency IO strips as a hedge:

- When rates fall, prepayments accelerate, reducing MSR value.
- However, the IO strip can be sold at a loss (partially offsetting MSR loss) or the position is structured such that the initial IO purchase was already part of a broader hedge.
- Actually, IOs also lose value when rates fall (faster prepays reduce the interest stream). So IOs are a **natural hedge complement** to MSRs -- both lose value when rates fall, which means IOs would NOT hedge MSRs.
- **Correction**: MSRs and IOs have similar (not opposite) rate exposure. The correct hedge for MSRs is typically PO strips, receiver swaptions, or long Treasury positions. This nuance is frequently tested in interviews.

---

## Common Interview Questions & Answers

### Q1: Explain the difference between a PAC bond and a sequential pay bond.

**A:** A sequential pay bond receives principal in a strict order (A before B before C), but its average life is still sensitive to prepayment speeds because there is no mechanism to redirect excess or shortfall principal. A PAC bond has a defined principal payment schedule protected by a prepayment speed band (e.g., 100-300 PSA). As long as prepayments stay within the band, the PAC receives its scheduled principal regardless of actual speeds. The PAC achieves this stability by having a companion/support tranche absorb the variability. Sequential bonds offer duration separation; PAC bonds offer prepayment stability.

### Q2: What happens to a PAC bond when its band "breaks"?

**A:** A PAC band breaks when prepayments are so extreme (fast or slow) that the support tranches are depleted or insufficient to maintain the PAC schedule. If prepayments are extremely fast, the support tranche may be fully retired, leaving no buffer to absorb further excess principal -- the PAC then begins receiving unscheduled principal and its average life shortens ("busted PAC"). If prepayments are extremely slow, the support tranche may not have enough principal to supplement the PAC schedule, and the PAC extends. Once a band breaks, the PAC effectively becomes a sequential bond with reduced or no protection.

### Q3: Why do inverse floaters have leverage, and how is it determined?

**A:** Inverse floaters have leverage because they are created by splitting a fixed-rate tranche into a larger floater and a smaller inverse floater. The leverage ratio equals the floater's face divided by the inverse floater's face. For example, if $100M fixed-rate is split into $80M floater and $20M inverse floater, the leverage is 4x. This means a 1% change in the reference rate causes a 4% change in the inverse floater's coupon (in the opposite direction). The leverage arises mechanically from the requirement that the weighted average coupon of the floater and inverse floater must equal the original fixed coupon.

### Q4: What is negative duration, and which CMO tranche exhibits it?

**A:** Negative duration means that a security's price increases when interest rates rise and decreases when rates fall -- the opposite of conventional bonds. IO strips exhibit negative duration because when rates rise, prepayments slow, extending the interest-only cash flow stream and increasing its present value. When rates fall, prepayments accelerate, terminating the interest stream sooner and reducing value. This makes IOs useful for hedging portfolios with positive duration, though their behavior can be complex and path-dependent.

### Q5: How would you design a database schema to store CMO deal data?

**A:** I would design a normalized relational schema with the following core tables: (1) `deals` -- deal ID, REMIC name, issuer, issue date, original collateral face, trustee. (2) `tranches` -- tranche ID, deal ID, class name, tranche type (PAC/SEQ/SUP/TAC/Z/FLT/INV/IO/PO), original face, coupon type, coupon rate or formula, PAC band lower/upper if applicable. (3) `collateral_groups` -- group ID, deal ID, pool CUSIPs, collateral type. (4) `tranche_monthly` -- tranche ID, reporting date, current factor, current face, principal paid, interest paid, prepayment speed. (5) `waterfall_rules` -- deal ID, priority order, rule type, parameters. (6) `pac_schedules` -- tranche ID, month, scheduled principal. I would partition `tranche_monthly` by date for query performance and create indexes on deal ID and tranche type for common analytical queries.

### Q6: Explain Z-bond accretion and its impact on other tranches.

**A:** A Z-bond does not receive cash interest during its accrual period. Instead, the interest that would be paid to the Z-bond is calculated each month and added to the Z-bond's outstanding principal balance (accretion). This accrued interest amount is redirected as additional principal to whichever earlier tranche is currently receiving principal. This creates a predictable, stable source of extra principal for earlier tranches beyond what the collateral naturally produces. Once all prior tranches are retired, the Z-bond (now with a larger balance due to accretion) begins receiving both interest and principal. Z-bonds effectively front-load cash flows to earlier tranches while creating a long-duration, zero-coupon-like instrument.

### Q7: What is the residual interest in a REMIC, and why is it significant?

**A:** The residual interest receives whatever cash flows remain after all regular interest tranches have been paid. It is significant for several reasons: (1) Tax law requires exactly one residual class per REMIC. (2) The residual holder bears "phantom income" -- taxable income can be allocated to the residual even when little or no cash is distributed. (3) The residual may have negative economic value due to this tax burden, and issuers sometimes pay investors to take the residual. (4) For data engineering purposes, the residual is the balancing item in the waterfall -- any discrepancies in cash flow allocation should net to zero at the residual level, making it a useful reconciliation check.

---

## Tips

1. **Draw the waterfall**: In interviews, offer to diagram the cash flow waterfall on a whiteboard. Visual explanations of CMO structures are far more effective than verbal descriptions.

2. **Know the tranche alphabet**: PAC, TAC, SEQ, SUP, Z, IO, PO, FLT, INV, NAS (non-accelerating senior) -- be ready to explain each and their risk profiles.

3. **Connect structure to investor needs**: Banks want short-duration floaters; insurance companies want long-duration Z-bonds; hedge funds trade IOs and inverse floaters. Show you understand who buys what and why.

4. **PAC band math**: Be prepared to explain how PAC schedules are derived from the minimum principal at each end of the band. This is a common technical question.

5. **Data engineering focus**: Emphasize experience with deal-level data sources (Intex, Bloomberg, eMBS), waterfall implementation, and the challenges of modeling 30-50 tranches per deal with interdependent rules.

6. **IO/PO nuance**: Remember that IOs have negative duration (value increases when rates rise). Do not confuse IO behavior with MSR behavior -- while both are sensitive to prepayments, understanding the precise hedging relationships is critical and frequently tested.

7. **REMIC vs. grantor trust**: Know that REMICs allow active tranching while grantor trusts (used for simple pass-throughs) do not. This distinction explains why CMOs use the REMIC structure.

8. **Scale considerations**: A typical agency CMO program may issue hundreds of deals per year, each with dozens of tranches. Data pipelines must handle the volume and complexity efficiently, with proper partitioning and indexing strategies.

---
