# Private Label RMBS Deal Structures

[Back to Secondary Market Index](./README.md)

---

## Introduction

Private label RMBS deal structures define how cash flows from the underlying mortgage pool are distributed to bondholders and how losses are allocated. Understanding these structures is essential for data engineers working in MBS analytics, as every cash flow model, performance report, and risk analysis depends on correctly implementing the deal's structural rules. The structure determines who gets paid first, who absorbs losses, and under what conditions the priority of payments changes.

---

## Key Concepts

### 1. Senior/Subordinate Structure

The senior/subordinate (senior/sub) structure is the foundational architecture of virtually all private-label RMBS deals. It creates a hierarchy of bond classes (tranches) with different risk and return profiles.

```
Capital Structure Example:

+---------------------------+
|   Class A (Senior)        |  AAA rated  |  75% of deal
|   First to receive cash   |
+---------------------------+
|   Class M-1 (Mezzanine)   |  AA rated   |   8% of deal
+---------------------------+
|   Class M-2 (Mezzanine)   |  A rated    |   5% of deal
+---------------------------+
|   Class M-3 (Mezzanine)   |  BBB rated  |   4% of deal
+---------------------------+
|   Class B-1 (Subordinate) |  BB rated   |   3% of deal
+---------------------------+
|   Class B-2 (First Loss)  |  NR/B rated |   3% of deal
+---------------------------+
|   Over-collateralization   |             |   2% of deal
+---------------------------+
```

**Key principles:**
- **Interest**: Paid top-down (senior first, then mezzanine, then subordinate).
- **Principal**: Distribution depends on the payment mode (sequential vs. pro-rata) and whether triggers are in effect.
- **Losses**: Allocated bottom-up (first-loss piece absorbs losses first, then subordinate, then mezzanine, then senior).

### 2. Credit Tranching

Credit tranching divides the capital structure into layers with progressively higher credit risk:

| Tranche Type | Role | Typical Rating | Investor Profile |
|-------------|------|---------------|-----------------|
| **Super Senior** | Most protected; may have additional structural features | AAA | Banks, insurance companies, money managers |
| **Senior Support** | Supports the super senior; still investment grade | AAA/AA | Institutional investors |
| **Mezzanine** | Absorbs losses after subordinate is exhausted | AA to BBB | Hedge funds, specialty managers |
| **Subordinate/B-piece** | Primary loss absorber below mezzanine | BB to B | B-piece buyers, distressed debt funds |
| **First Loss / Residual** | First to absorb losses; receives excess spread | NR (not rated) | Sponsor, hedge funds, REITs |

### 3. Shifting Interest Mechanism

Shifting interest is a critical structural feature that governs how principal payments are shared between senior and subordinate tranches over time.

**How it works:**
- In the **early years** (lockout period, typically 36–60 months), **all principal** (both scheduled and prepayments) goes to the senior tranche. This rapidly builds credit enhancement for the senior bonds.
- After the lockout, subordinate tranches begin receiving a **gradually increasing share** of principal, provided performance triggers are satisfied.
- If triggers **fail** (collateral performance deteriorates), the lockout effectively continues — all principal remains directed to the senior tranche.

**Typical shifting interest schedule (post-crisis):**

| Month | Subordinate Share of Prepayments |
|-------|--------------------------------|
| 0–60 | 0% (full lockout) |
| 61–72 | 30% |
| 73–84 | 40% |
| 85–96 | 60% |
| 97–108 | 80% |
| 109+ | 100% (pro-rata with senior) |

**Pre-crisis vs. post-crisis differences:**
- Pre-crisis deals often had shorter lockout periods (24–36 months) and more aggressive shifting interest schedules.
- Post-crisis deals have longer lockouts (48–60 months) and more conservative step-down percentages.
- Performance triggers are stricter in post-crisis deals.

### 4. Sequential vs. Pro-Rata Payment

#### Sequential Pay

Principal is paid to tranches in strict order — the most senior tranche must be fully retired before the next tranche receives any principal.

```
Principal Flow (Sequential):

Collateral Principal --> Class A1 (until retired)
                     --> Class A2 (until retired)
                     --> Class M1 (until retired)
                     --> Class M2 (until retired)
                     --> Class B1 (until retired)
                     --> Class B2 (until retired)
```

- **Effect**: Senior tranches have shorter average lives; junior tranches are longer and riskier.
- **When used**: During the lockout period and when triggers have failed.

#### Pro-Rata Pay

Principal is distributed proportionally based on each tranche's current outstanding balance.

```
Principal Flow (Pro-Rata):

Collateral Principal --> Distributed proportionally:
                         Class A: 75% of principal
                         Class M1: 8% of principal
                         Class M2: 5% of principal
                         ... etc.
```

- **Effect**: All tranches pay down simultaneously; subordinate tranches receive principal sooner.
- **When used**: After the lockout period expires and all performance triggers are passing.
- **Risk**: Pro-rata distribution reduces credit enhancement over time as subordinate tranches pay down.

### 5. Over-Collateralization (OC)

Over-collateralization is the amount by which the collateral balance exceeds the total bond balance:

```
OC = Collateral Balance - Total Bond Balance

Example:
  Collateral Balance:  $510,000,000
  Total Bond Balance:  $500,000,000
  OC Amount:           $10,000,000  (2.0% initial OC)
```

**OC mechanics:**
- **Initial OC**: Set at closing; created by issuing bonds for less than the collateral value.
- **Target OC**: The level OC must reach/maintain; excess spread is used to build OC to target.
- **OC floor**: Minimum OC level that cannot be breached (often 0.50–1.00% of original balance).
- **OC release**: When actual OC exceeds target, excess can be released to the residual holder.

### 6. Excess Spread

Excess spread is the difference between the weighted average coupon (WAC) on the collateral and the weighted average coupon paid to bondholders plus fees:

```
Excess Spread = Collateral WAC - Bond WAC - Servicing Fee - Trustee/Other Fees

Example:
  Collateral WAC:    5.50%
  Bond WAC:          4.25%
  Servicing Fee:     0.25%
  Other Fees:        0.10%
  Excess Spread:     0.90% per annum
```

**Uses of excess spread (priority):**
1. Cover current-period losses (first line of defense)
2. Reimburse previously written-down bond principal
3. Build over-collateralization to target level
4. Release to residual/equity holder if all targets met

### 7. Deal Triggers

Triggers are performance tests that determine whether the deal remains in its intended payment mode or reverts to a more protective mode. Common triggers:

#### Cumulative Loss Trigger
```
Test: Cumulative Realized Losses / Original Pool Balance < Threshold

Example thresholds by month:
  Month 12:  Cumulative losses < 1.00%
  Month 24:  Cumulative losses < 2.25%
  Month 36:  Cumulative losses < 3.50%
  Month 48:  Cumulative losses < 4.75%
```

#### Delinquency Trigger
```
Test: (60+ Day Delinquent Balance + REO + Foreclosure) / Current Pool Balance < Threshold

Typical threshold: 25–50% of initial subordination
```

#### Credit Enhancement Trigger
```
Test: Current CE% >= Target CE%

If subordination as a percentage of current pool balance
falls below target, trigger fails.
```

**Consequences of trigger failure:**
- Principal payment reverts from pro-rata to sequential (protecting seniors).
- Shifting interest schedule resets to full lockout.
- Excess spread is trapped and used to build OC rather than released.
- Remains in effect until triggers are cured (often cannot be cured once breached in pre-crisis deals).

### 8. Step-Down Dates

Step-down dates are predetermined dates after which the deal's payment structure may shift from sequential to pro-rata, subject to trigger satisfaction:

- **Step-down date**: Typically 36–60 months after closing.
- **Conditions**: All performance triggers must be passing on the step-down date.
- **Effect**: If conditions are met, subordinate tranches begin receiving principal per the shifting interest schedule.
- **Step-down failure**: If triggers are failing on the step-down date, sequential pay continues.

### 9. Pre-Crisis vs. Post-Crisis Structures

| Feature | Pre-Crisis (2004–2007) | Post-Crisis (2012+) |
|---------|----------------------|-------------------|
| **Initial CE (AAA)** | 15–20% (subprime), 4–8% (prime) | 25–35% (non-QM), 5–8% (prime jumbo) |
| **Lockout period** | 24–36 months | 48–60 months |
| **Shifting interest** | Aggressive step-down | Conservative step-down |
| **Triggers** | Weak, easily passed | Stringent, multiple types |
| **Senior structure** | NAS (non-accelerated senior) common | Simple sequential more common |
| **OC target** | Often low | Higher targets, floors maintained |
| **Due diligence** | Limited, often 10–25% sample | 100% review common for non-QM |
| **Loan-level data** | Limited disclosure | Full Reg AB II loan-level disclosure |
| **Risk retention** | None required | 5% (horizontal, vertical, or L-shaped) |
| **Rating agencies** | Often single rating | Typically two or more ratings |

### 10. Deal Documents

#### Pooling and Servicing Agreement (PSA)

The PSA is the master governing document of a securitization trust:

- **Defines**: All parties (depositor, servicer, master servicer, trustee, certificate administrator), their roles and responsibilities.
- **Contains**: Complete waterfall rules, trigger definitions, representations and warranties, servicing standards, reporting requirements.
- **Data engineering relevance**: The PSA is the source of truth for implementing cash flow models and waterfall logic. Every calculation in your system should be traceable to a PSA provision.

#### Prospectus Supplement (ProSupp)

The prospectus supplement is the investor disclosure document filed with the SEC:

- **Contains**: Pool characteristics (stratification tables), structural summary, risk factors, tax considerations, legal structure.
- **Stratification tables**: Distribution of loans by FICO, LTV, DTI, loan purpose, property type, geography, documentation type.
- **Data engineering relevance**: The ProSupp provides the initial loan tape summary and structural terms needed for deal setup in analytics systems.

#### Other Key Documents

| Document | Purpose |
|----------|---------|
| **Mortgage Loan Purchase Agreement (MLPA)** | Terms of loan sale from originator to depositor |
| **Representations & Warranties** | Originator's assertions about loan quality; breach triggers repurchase |
| **Servicing Agreement** | Servicer obligations, advancing requirements, fee structure |
| **Trust Agreement** | Legal creation of the trust entity |

---

## Real-World Examples

### Example 1: Post-Crisis Prime Jumbo — Sequential to Pro-Rata

**Deal**: JPMMT 2024-5 (hypothetical)

```
Closing Date: March 2024
Collateral: $500M prime jumbo, WAC 6.25%, WA FICO 775, WA LTV 65%

Capital Structure:
  Class A-1:  $250M  (AAA)  Fixed, Sequential within seniors
  Class A-2:  $100M  (AAA)  Fixed, Sequential within seniors
  Class A-3:   $25M  (AAA)  Floater
  Class B-1:   $40M  (AA)
  Class B-2:   $30M  (A)
  Class B-3:   $25M  (BBB)
  Class B-4:   $15M  (BB)
  Class B-5:   $15M  (NR)
  Total:      $500M

Initial CE on A classes: 25.0% (B-1 through B-5 subordination)
Step-down date: Month 48
```

**Payment flow:**
- Months 1–48: All principal to A classes (sequential among A-1, A-2, A-3).
- Month 48+: If triggers pass, B classes begin receiving principal per shifting interest schedule.
- If triggers fail: Sequential pay continues indefinitely.

### Example 2: Pre-Crisis Subprime — NAS Structure

**Deal**: HEAT 2006-4 (hypothetical)

```
Collateral: $1B subprime, WAC 8.50%, WA FICO 615, WA CLTV 85%

Capital Structure:
  Class A-1:  $400M  (AAA)  NAS (non-accelerated senior)
  Class A-2:  $300M  (AAA)  Sequential
  Class M-1:  $100M  (AA)
  Class M-2:   $55M  (A)
  Class M-3:   $40M  (BBB)
  Class M-4:   $25M  (BBB-)
  Class B-1:   $30M  (BB)
  Class B-2:   $25M  (NR)
  OC:          $25M  (2.5% initial)
  Total bonds: $975M

Initial CE on A classes: 18.0%
```

**What went wrong:**
- Cumulative losses reached 42%, far exceeding the 18% CE.
- All subordinate and mezzanine tranches were completely written down by 2009.
- Even AAA tranches suffered realized losses.
- NAS structure accelerated losses to mezzanine classes, but the sheer magnitude overwhelmed the entire structure.

### Example 3: Non-QM Deal — Modern Structure

**Deal**: VERUS 2025-2 (hypothetical)

```
Collateral: $400M non-QM, WAC 7.00%, WA FICO 740, WA LTV 70%
  Mix: 40% DSCR investor, 30% bank statement, 20% full doc non-QM, 10% other

Capital Structure:
  Class A-1:  $264M  (AAA)  34.0% CE
  Class A-2:   $24M  (AA)   28.0% CE
  Class A-3:   $22M  (A)    22.5% CE
  Class M-1:   $20M  (BBB+) 17.5% CE
  Class B-1:   $18M  (BBB-) 13.0% CE
  Class B-2:   $16M  (BB)    9.0% CE
  Class B-3:   $36M  (NR)    —
  Total:      $400M

Step-down: Month 48
5% risk retention: Horizontal (B-3 class retained by sponsor)
```

**Structural features:**
- Higher CE than pre-crisis (34% vs. 18%) reflects regulatory and market lessons.
- 100% third-party due diligence review.
- Loan-level data published monthly per Reg AB II.
- Multiple triggers (cumulative loss, delinquency, CE test).

---

## Common Interview Questions & Answers

### Q1: Explain the senior/subordinate structure and how it protects senior bondholders.

**Answer**: The senior/subordinate structure creates a hierarchy of bond classes where losses are absorbed from the bottom up. Subordinate tranches (B classes) take losses first, then mezzanine (M classes), and finally senior (A classes). This means the senior tranche has credit enhancement equal to the sum of all subordinate and mezzanine tranche balances plus any over-collateralization. For example, if subordinate tranches represent 25% of the deal, the senior tranche can withstand 25% cumulative losses before experiencing any principal loss. Interest is paid top-down (senior first), and principal distribution depends on whether the deal is in sequential or pro-rata mode based on performance triggers. The shifting interest mechanism further protects seniors by directing prepayments to the senior tranche during the lockout period, which increases CE as a percentage of the remaining pool balance.

### Q2: What is shifting interest and why is it important?

**Answer**: Shifting interest controls how prepayments are allocated between senior and subordinate tranches over time. During the lockout period (typically 48–60 months post-crisis), all prepayments go to the senior tranche, causing it to pay down faster than the pool. This effectively increases credit enhancement as a percentage of the remaining balance. After the lockout, subordinate tranches gradually begin receiving a share of prepayments per a predefined schedule — but only if performance triggers are passing. If triggers fail, all prepayments continue going to the senior tranche. Shifting interest is critical because without it, pro-rata principal distribution would maintain constant CE percentages but not increase them. In a deteriorating credit environment, the trigger mechanism ensures the structure reverts to protective mode. For data engineers, implementing shifting interest correctly in waterfall models requires tracking the deal's month, trigger status, and the applicable percentage schedule.

### Q3: What happens when a deal trigger fails?

**Answer**: When a trigger fails, the deal reverts to a more protective payment mode. Specifically: (1) principal distribution switches from pro-rata to sequential, meaning all principal goes to the most senior outstanding tranche; (2) the shifting interest schedule resets, so subordinate tranches stop receiving prepayments; (3) excess spread is trapped and redirected to build over-collateralization rather than being released to the residual holder. Some deals have "hard" triggers that, once breached, can never be cured (common in pre-crisis deals), while post-crisis deals more commonly have "soft" triggers that can be cured if performance improves. The specific trigger definitions and consequences are detailed in the PSA. As a data engineer, trigger monitoring is a key component of surveillance systems — you need to calculate trigger tests each period and flag changes in deal payment mode.

### Q4: How do you model a private-label RMBS waterfall as a data engineer?

**Answer**: Modeling a waterfall requires: (1) **Parsing the PSA** to extract the complete payment priority, trigger definitions, and allocation rules; (2) **Building the collateral model** — project monthly cash flows (scheduled principal, prepayments, defaults, recoveries, interest) from the loan pool based on assumptions (CPR, CDR, severity, lag); (3) **Implementing the waterfall** — for each monthly period, calculate available funds and distribute them according to the priority of payments, checking triggers, applying shifting interest, and allocating losses; (4) **Tracking all state variables** — current balances, deferred interest, cumulative losses, OC level, trigger status; (5) **Validating** against trustee reports and third-party models like Intex. In practice, many firms use Intex as the authoritative waterfall engine and build analytics on top of its outputs. Data engineering work involves building pipelines that feed assumptions into Intex, capture outputs, and store tranche-level cash flows for analysis, reporting, and risk management.

### Q5: What are the key differences between pre-crisis and post-crisis private-label RMBS structures?

**Answer**: The differences are significant across every dimension. **Credit enhancement**: Post-crisis deals have materially higher CE levels (e.g., 30–35% for non-QM AAA vs. 15–20% for pre-crisis subprime AAA). **Lockout periods**: Extended from 24–36 months to 48–60 months. **Triggers**: More stringent, with multiple types (cumulative loss, delinquency, CE test) and lower thresholds. **Due diligence**: Post-crisis requires comprehensive third-party review (often 100% of loans) vs. limited sampling pre-crisis. **Disclosure**: Reg AB II mandates loan-level data disclosure, a dramatic improvement over the limited pool-level stratifications available pre-crisis. **Risk retention**: Dodd-Frank requires sponsors to retain 5% economic interest, aligning incentives. **Structural simplicity**: Post-crisis deals tend to have cleaner structures, moving away from complex features like NAS (non-accelerated senior) bonds. **Ratings**: Multiple rating agencies are standard, reducing reliance on any single agency's assessment.

---

## Tips for Interview Success

1. **Draw the structure**: Be prepared to sketch a capital structure on a whiteboard, showing tranche sizes, CE levels, and cash flow priority. Visual communication is highly valued.

2. **Understand the PSA**: Demonstrate that you know the PSA is the governing document and that every waterfall rule, trigger, and allocation stems from it. Reference specific PSA sections if possible.

3. **Know the timeline mechanics**: Be clear about when principal shifts from sequential to pro-rata, what triggers govern the transition, and what happens when triggers fail.

4. **Connect structure to data**: Explain what data fields you need to model a waterfall (current balances, rates, delinquency status, loss amounts, recovery timing) and how those feed into structural analytics.

5. **Compare eras**: The ability to articulate specific differences between pre-crisis and post-crisis structures demonstrates depth and historical awareness that interviewers value highly.

6. **Mention Intex**: In practice, Intex is the industry-standard waterfall modeling tool. Showing familiarity with it (even conceptually) signals real-world experience.

---
