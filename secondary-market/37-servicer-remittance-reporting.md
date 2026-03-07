# Servicer & Remittance Reporting

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. The Role of the Servicer

The servicer is the entity responsible for the day-to-day management of mortgage loans on behalf of investors (the trust/deal). Servicing involves collecting payments from borrowers, managing escrow accounts, handling delinquencies, and remitting funds to investors.

**Core Servicing Functions:**
- Collecting monthly P&I payments from borrowers
- Managing escrow for taxes and insurance
- Sending monthly statements to borrowers
- Handling payment processing and allocation
- Managing delinquent loans (loss mitigation, workouts)
- Executing foreclosure when necessary
- Reporting loan-level and pool-level data to investors and trustees
- Remitting funds to the trust per the pooling and servicing agreement (PSA)

### 2. Servicer Types

#### Master Servicer

The master servicer oversees the entire servicing operation for a deal. Responsibilities include:
- Ensuring sub-servicers comply with the PSA
- Aggregating data from multiple sub-servicers into unified investor reports
- Making advancing decisions (advancing P&I when borrowers do not pay)
- Reconciling remittances to the trustee
- Monitoring servicer performance and compliance

In agency MBS, Fannie Mae and Freddie Mac act as master servicers for their guaranteed pools.

#### Sub-Servicer

The sub-servicer handles the actual borrower-facing operations (collecting payments, sending statements, managing escrow) under contract with the master servicer or the loan owner. The investor may not even know who the sub-servicer is.

**Key distinction:** The master servicer is contractually responsible to the trust. The sub-servicer is contractually responsible to the master servicer.

#### Special Servicer

The special servicer handles loans that have become seriously delinquent (typically 90+ days) or are in default. Responsibilities include:
- Loss mitigation (loan modifications, forbearance plans, short sales)
- Foreclosure management
- REO property management and disposition
- Maximizing recovery for the trust

**Transfer to special servicing triggers:**
- Loan reaches 90+ days delinquent
- Borrower files for bankruptcy
- Borrower requests a modification
- Imminent default is identified

**Special servicer compensation:** Typically earns a higher servicing fee (e.g., 25 bps vs 6.5 bps for performing loans) plus workout fees and liquidation fees.

#### Primary Servicer vs. Named Servicer

- **Primary servicer**: The servicer of record with the agency (Fannie/Freddie/Ginnie)
- **Named servicer**: The servicer identified in the PSA for private-label deals

### 3. Remittance Types

The remittance type defines when and how the servicer forwards borrower payments to the trust. This is a critical concept because it affects cash flow timing, servicer economics, and investor reporting.

#### Actual/Actual (A/A)

- **Principal**: Servicer remits actual principal collected from borrowers
- **Interest**: Servicer remits actual interest collected from borrowers
- **Timing**: Servicer remits what was actually received
- **Used by**: Some private-label RMBS deals
- **Impact**: Investors bear the timing risk of late or missed payments. If a borrower pays late, the investor receives less that month.

#### Scheduled/Scheduled (S/S)

- **Principal**: Servicer remits scheduled principal regardless of what was collected
- **Interest**: Servicer remits scheduled interest regardless of what was collected
- **Timing**: Investor receives full scheduled payment every month
- **Used by**: Fannie Mae MBS (for principal), many agency programs
- **Impact**: Servicer must advance both P&I for delinquent loans. Higher advancing obligation creates more servicer risk but provides the investor with predictable cash flows.

#### Scheduled/Actual (S/A)

- **Principal**: Servicer remits actual principal collected
- **Interest**: Servicer remits scheduled interest regardless of collection
- **Timing**: Interest is guaranteed, principal depends on actual collections
- **Used by**: Freddie Mac Gold PCs (historically), some private-label deals
- **Impact**: Servicer advances interest but not principal. Moderate advancing obligation.

#### Comparison Table

| Attribute | Actual/Actual | Scheduled/Actual | Scheduled/Scheduled |
|-----------|--------------|-------------------|---------------------|
| Principal remitted | Actual collected | Actual collected | Scheduled amount |
| Interest remitted | Actual collected | Scheduled amount | Scheduled amount |
| Servicer advancing | None | Interest only | Both P&I |
| Investor cash flow predictability | Low | Medium | High |
| Servicer liquidity risk | Low | Medium | High |
| Common usage | Some PLS | Freddie Mac (historical) | Fannie Mae |

### 4. Remittance Reporting Cycle

The monthly reporting cycle follows a structured timeline:

```
Day 1-28: Borrower payments collected throughout the month
    │
    ▼
Cut-off Date (typically last business day of collection month)
    │  Servicer aggregates all payments received
    ▼
Determination Date (typically 4th business day of next month)
    │  Servicer calculates amounts due to the trust
    │  Runs delinquency and advancing calculations
    ▼
Remittance Date (typically 15th-18th of the month)
    │  Servicer wires funds to the trustee/paying agent
    ▼
Distribution Date (typically 25th of the month)
    │  Trustee distributes P&I to investors
    │  Distribution Date Statement published
    ▼
Investor Reporting (within days of distribution)
    │  Trustee publishes factor files, pool reports
    │  Rating agencies receive updated data
```

### 5. Investor Reporting: Distribution Date Statements

The Distribution Date Statement (DDS) is the primary investor report produced each month. It contains:

#### Deal-Level Summary
- Total collections (P&I, prepayments, liquidation proceeds, recoveries)
- Total distributions to tranches
- Total losses allocated
- Reserve fund balance
- Trigger test results (delinquency triggers, cumulative loss triggers)
- Overcollateralization balance

#### Tranche-Level Detail
- Prior period balance
- Principal distributed (scheduled + prepay + liquidation)
- Interest distributed (accrued interest at coupon rate)
- Realized losses allocated
- Current balance (after distributions and losses)
- Current factor
- Current credit enhancement

#### Collateral-Level Summary
- Beginning and ending pool balance
- Scheduled principal collected
- Prepayments
- Liquidation proceeds
- Losses
- Delinquency statistics (30, 60, 90+, foreclosure, REO)
- Modification count and UPB
- CPR, CDR, loss severity

### 6. Servicer Advances

Servicer advances are funds paid by the servicer to the trust when borrowers fail to make payments. This is one of the most financially significant aspects of servicing.

#### Types of Advances

| Advance Type | Description |
|-------------|-------------|
| **P&I Advance** | Scheduled principal and interest advanced for delinquent loans |
| **Escrow Advance (T&I)** | Taxes and insurance paid on behalf of delinquent borrowers to protect the collateral |
| **Corporate Advance** | Property preservation costs, legal fees, inspection fees, appraisals |

#### Advance Recoverability

The PSA typically requires advances only if they are deemed "recoverable." The servicer must assess whether the advance will eventually be repaid from liquidation proceeds or future borrower payments.

```
Advance Decision Logic:
1. Is the loan delinquent? → If no, no advance needed
2. Is the advance recoverable from future proceeds? → If yes, advance
3. Has the property value declined below total advances? → If yes, stop advancing
4. Declare advance non-recoverable → Stop future advances
5. Existing non-recoverable advances → Reimburse from trust collections (top of waterfall)
```

**Advance reimbursement priority:** Advances are typically reimbursed at the top of the cash flow waterfall, before any distributions to tranches. This means advance reimbursements reduce the cash available to investors.

### 7. P&I Distribution Mechanics

The flow of funds from borrower to investor:

```
Borrower Payment ($1,500/month)
    │
    ├── Servicing Fee: $1,500 × (0.25% / 12) = $3.13
    │   (retained by servicer)
    │
    ├── Guarantee Fee: $1,500 × (0.20% / 12) = $2.50
    │   (retained by agency, if agency MBS)
    │
    ├── Interest to Investors: $1,500 × (4.00% / 12) × UPB factor
    │   (pass-through rate × remaining balance)
    │
    └── Principal to Investors: Amortization portion
        (allocated to tranches per waterfall rules)
```

**Net interest margin breakdown (example):**
- Borrower note rate: 4.50%
- Servicing fee: 0.25%
- Guarantee fee: 0.20%
- Excess spread: 0.05%
- Pass-through rate to investors: 4.00%

### 8. Escrow Administration

Servicers manage escrow accounts for property taxes and hazard insurance:

| Function | Description |
|----------|-------------|
| **Collection** | Monthly escrow amount collected as part of borrower payment |
| **Analysis** | Annual escrow analysis to ensure sufficient funds |
| **Disbursement** | Payments to tax authorities and insurance companies |
| **Shortage/Surplus** | Adjust monthly escrow when actual costs differ from estimates |
| **RESPA Compliance** | Cannot hold more than 2-month cushion per federal law |

For delinquent loans, the servicer must advance escrow payments (T&I advances) to prevent tax liens or insurance lapses, which would impair the collateral.

### 9. Servicer Data Fields

Key data fields reported by servicers in their monthly reporting:

#### Loan-Level Servicer Fields

| Field | Description |
|-------|-------------|
| **Servicer Loan Number** | Servicer's internal identifier |
| **Investor Loan Number** | Trust/deal-level identifier |
| **Payment Status** | Current, 30, 60, 90+, FC, REO |
| **Next Due Date** | Date of next payment due |
| **Last Payment Received Date** | Date of most recent borrower payment |
| **Last Payment Amount** | Dollar amount of last payment |
| **Total Amount Due** | All past-due payments plus current |
| **Escrow Balance** | Current escrow account balance |
| **Escrow Advance Outstanding** | Cumulative T&I advances not yet recovered |
| **Corporate Advance Outstanding** | Cumulative corporate advances not yet recovered |
| **P&I Advance Outstanding** | Cumulative P&I advances not yet recovered |
| **Modification Flag** | Whether loan has been modified |
| **Workout Type** | Forbearance, modification, repayment plan, short sale |
| **Loss Mitigation Status** | Pre-referral, active review, approved, denied |
| **Foreclosure Referral Date** | Date loan was referred to foreclosure |
| **Bankruptcy Filing Date** | Date of borrower bankruptcy filing |
| **Bankruptcy Chapter** | Chapter 7, 11, or 13 |

### 10. Transfer of Servicing (TOS)

When servicing rights are sold from one servicer to another, a complex data transfer occurs.

#### Data Transfer Requirements

1. **Loan-level data tape**: All origination and current performance fields
2. **Payment history**: Complete payment history for each loan
3. **Escrow data**: Current balances, upcoming disbursement schedule, escrow analysis
4. **Advance data**: Outstanding P&I, T&I, and corporate advances with detail
5. **Insurance data**: Hazard, flood, MI policy information
6. **Tax data**: Parcel numbers, tax authority, next due dates, amounts
7. **Loss mitigation files**: Active workout agreements, trial period plans, modification documents
8. **Document images**: Notes, deeds, assignments
9. **Investor mapping**: Which loans belong to which pools/deals

#### Data Engineering Challenges in TOS

| Challenge | Description |
|-----------|-------------|
| **Field mapping** | Old servicer and new servicer use different field names and codes |
| **Data gaps** | Missing or incomplete records in the transfer tape |
| **Advance reconciliation** | Ensuring advance balances agree between old and new servicer |
| **Payment application** | Payments in transit during the transfer period |
| **Borrower notification** | RESPA requires 15-day advance notice; data must support mailing |
| **Parallel run** | Both servicers may report for the transfer month |
| **Investor reporting continuity** | No gap in monthly reporting to the trust |

---

## Real-World Examples

### Example 1: Building a Servicer Data Integration Pipeline

**Scenario:** Your firm is a master servicer receiving data from 12 sub-servicers, each with different formats.

**Pipeline design:**

```
Sub-Servicer A (CSV)  ──┐
Sub-Servicer B (XML)  ──┤
Sub-Servicer C (Fixed)──┤──► Ingestion Layer ──► Canonical Format ──► Validation
Sub-Servicer D (API)  ──┤                        (standardized       (business rules,
...                     ──┘                         field names,        reconciliation)
                                                    unified codes)
                                                         │
                                                         ▼
                                                  Master Servicer
                                                  Data Warehouse
                                                         │
                                                         ▼
                                              ┌──────────┼──────────┐
                                              │          │          │
                                         Investor    Agency     Trustee
                                         Reporting   Reporting  Reporting
```

**Key components:**
1. **Format adapters**: One adapter per sub-servicer that converts raw format to canonical schema
2. **Code mapping**: Unified lookup tables for status codes, property types, etc.
3. **Reconciliation engine**: Compare sub-servicer reported UPB against expected UPB, validate payment amounts against scheduled amounts
4. **Exception handling**: Flag loans with data issues for manual review
5. **Advance tracking**: Calculate and track advances across all sub-servicers

### Example 2: Remittance Reconciliation

**Scenario:** Monthly reconciliation of servicer remittance against expected amounts.

```sql
-- Reconciliation query: compare expected vs actual remittance
WITH expected AS (
    SELECT
        deal_id,
        reporting_period,
        SUM(CASE WHEN loan_status = 'Current'
            THEN scheduled_principal + scheduled_interest
            ELSE 0 END) AS expected_from_current,
        SUM(CASE WHEN loan_status != 'Current'
            THEN scheduled_principal + scheduled_interest
            ELSE 0 END) AS expected_advance_needed,
        SUM(prepayment_amount) AS expected_prepayments,
        SUM(liquidation_proceeds) AS expected_liquidation
    FROM fact_loan_performance
    WHERE reporting_period = '2025-06-01'
    GROUP BY deal_id, reporting_period
),
actual_remittance AS (
    SELECT
        deal_id,
        reporting_period,
        total_pi_remitted,
        total_prepay_remitted,
        total_liquidation_remitted,
        total_advances_made,
        total_advances_reimbursed
    FROM fact_servicer_remittance
    WHERE reporting_period = '2025-06-01'
)
SELECT
    e.deal_id,
    e.expected_from_current,
    e.expected_advance_needed,
    a.total_advances_made,
    e.expected_prepayments,
    a.total_prepay_remitted,
    ABS(e.expected_from_current + a.total_advances_made
        + a.total_prepay_remitted + a.total_liquidation_remitted
        - a.total_pi_remitted) AS reconciliation_difference
FROM expected e
JOIN actual_remittance a ON e.deal_id = a.deal_id
WHERE ABS(e.expected_from_current + a.total_advances_made
    + a.total_prepay_remitted + a.total_liquidation_remitted
    - a.total_pi_remitted) > 100;  -- flag differences > $100
```

### Example 3: Servicing Transfer Data Pipeline

**Scenario:** Migrating 50,000 loans from Servicer A to Servicer B.

**Steps:**
1. Receive transfer tape from Servicer A (loan data, payment history, escrow, advances)
2. Map Servicer A fields to Servicer B schema (150+ field mappings)
3. Validate: loan count, aggregate UPB, advance totals reconcile to Servicer A's last investor report
4. Load into Servicer B systems with parallel tracking
5. Run dual reporting for transfer month (both servicers report)
6. Reconcile: ensure no loans lost, no duplicate reporting, advance balances match
7. Notify investors and agencies of servicer change
8. Archive Servicer A data for audit trail

---

## Common Interview Questions & Answers

### Q1: Explain the difference between actual/actual, scheduled/scheduled, and scheduled/actual remittance types.

**Answer:** These remittance types determine how a servicer forwards borrower payments to the trust:

**Actual/Actual**: The servicer remits only what was actually collected from borrowers. If a borrower misses a payment, the investor receives nothing for that loan. This places maximum cash flow risk on the investor and minimum advancing obligation on the servicer. Used in some private-label deals.

**Scheduled/Scheduled**: The servicer remits full scheduled principal and interest regardless of what was collected. For delinquent loans, the servicer must advance both P&I from its own funds. The investor receives predictable cash flows. This is Fannie Mae's model and places the most liquidity risk on the servicer.

**Scheduled/Actual**: The servicer advances scheduled interest but remits only actual principal collected. This is a middle ground, used historically by Freddie Mac. The servicer has moderate advancing risk (interest only).

From a data engineering perspective, the remittance type affects how I calculate expected distributions, build reconciliation logic, and track servicer advance balances. The remittance type must be stored at the deal level because it determines the cash flow calculation engine.

### Q2: What is a servicer advance, and why does it matter for data engineering?

**Answer:** A servicer advance is a payment made by the servicer to the trust when a borrower fails to pay. There are three types: P&I advances (covering missed principal and interest), T&I advances (covering taxes and insurance), and corporate advances (legal fees, property preservation).

For data engineering, advances matter because:
1. **They are a running balance**: Each loan has cumulative outstanding advances that must be tracked monthly. This requires a balance-forward calculation.
2. **Recoverability assessment**: The servicer must evaluate whether advances are recoverable. This feeds into stop-advance decisions and affects trust-level cash flows.
3. **Waterfall priority**: Advance reimbursements sit at the top of the payment waterfall, reducing cash available to investors. The data pipeline must correctly sequence advance reimbursement before P&I distribution.
4. **Transfer of servicing**: Outstanding advances must transfer correctly between servicers. Reconciliation of advance balances is one of the most error-prone aspects of servicing transfers.

I design the advance tracking as a separate fact table with monthly snapshots:
```sql
fact_advance (loan_id, reporting_period, advance_type,
              beginning_balance, new_advances, reimbursements,
              write_offs, ending_balance)
```

### Q3: How would you handle data from multiple sub-servicers with different formats?

**Answer:** I would implement an adapter pattern with a canonical data model:

1. **Adapter layer**: Build a format-specific adapter for each sub-servicer that reads their native format (CSV, XML, fixed-width, API) and produces a standardized intermediate format.
2. **Canonical schema**: Define a single internal schema with standardized field names and code values. All adapters output to this schema.
3. **Code mapping tables**: Maintain configurable mapping tables that translate each sub-servicer's codes to the canonical codes (e.g., Servicer A uses "CUR" for current while Servicer B uses "0" for current).
4. **Validation layer**: Apply uniform data quality rules to the canonicalized data, regardless of source.
5. **Configuration-driven**: Make the adapter layer metadata-driven so adding a new sub-servicer requires only configuration, not code changes. Store file layouts, column mappings, and code translations in database tables.
6. **Reconciliation**: After canonicalization, reconcile each sub-servicer's aggregate figures (loan count, total UPB, delinquency counts) against their summary reports.

### Q4: Describe the data challenges in a servicing transfer.

**Answer:** Servicing transfers are among the most data-intensive operations in mortgage servicing:

1. **Schema mapping**: The outgoing and incoming servicers use different systems with different field names, data types, and code sets. A 150+ field mapping exercise is typical.
2. **Data completeness**: The transfer tape may have missing fields. Common gaps include escrow analysis details, historical payment breakdown, and document images.
3. **Advance reconciliation**: Outstanding advance balances must match exactly between the two servicers. Discrepancies are common because of timing differences in how advances are calculated.
4. **Payment in transit**: Borrower payments mailed before the transfer effective date may arrive at the wrong servicer. Both servicers need a process to redirect payments.
5. **Dual reporting**: For the transfer month, both servicers may report the same loans to the trust. The data pipeline must handle deduplication and identify the authoritative source for each loan.
6. **Escrow continuity**: The new servicer must have accurate tax and insurance disbursement schedules to avoid missed payments.
7. **Regulatory compliance**: RESPA requires borrower notification with specific data elements. The data pipeline must support mail file generation with accurate servicer information.

### Q5: How does the servicing fee get calculated and where does it appear in the data?

**Answer:** The servicing fee is a percentage of the outstanding UPB, accrued monthly:

**Calculation:**
```
Monthly servicing fee = Current UPB × (annual servicing rate / 12)
Example: $200,000 × (0.25% / 12) = $41.67
```

The servicing fee is deducted from the borrower's interest payment before remitting to the trust. It does not appear as a separate line item in borrower payments. In the data:

- **Deal level**: The PSA specifies the gross WAC (weighted average coupon of the loans) and the net pass-through rate (what investors receive). The difference includes the servicing fee, guarantee fee, and any excess spread.
- **Loan level**: Each loan has a note rate, a net rate (pass-through rate), and the difference is allocated to servicing fee, guarantee fee, and excess.
- **Servicer reporting**: The servicer reports gross interest collected and net interest remitted. The difference includes the servicing fee.

In the database, I store the servicing fee rate on the loan dimension and calculate the monthly dollar amount in the performance fact table. For analytics, the aggregate servicing fee across a portfolio represents the servicing asset's economic value.

---

## Tips

1. **Learn the PSA**: The Pooling and Servicing Agreement is the governing document for every deal. It defines remittance type, advancing obligations, servicing fee, waterfall priority, and trigger tests. A data engineer should be able to read a PSA to understand data requirements.

2. **Advances are the hidden risk**: Servicer advances can accumulate to significant amounts for severely delinquent loans (foreclosure timelines can exceed 3 years in judicial states). Track advance balances at the loan level and flag loans where advances exceed a threshold percentage of the property value.

3. **Distribution date is not payment date**: Borrowers pay on the 1st of the month. The trust distributes to investors on the 25th. There is a roughly 55-day lag from when cash is collected to when it reaches investors. This timing matters for cash flow modeling.

4. **Servicer transfers spike around year-end and quarter-end**: Plan data pipeline capacity for bulk servicing transfers during these periods. A single transfer can involve hundreds of thousands of loans.

5. **Special servicing creates data complexity**: When a loan transfers to special servicing, its data may be reported by both the primary and special servicer. Ensure your data model identifies which servicer is the reporting source for each loan at any point in time.

6. **RESPA and regulatory data**: Servicing is heavily regulated. Data pipelines must support RESPA escrow disclosures, CFPB periodic statements, HMDA reporting, and state-specific requirements. Design flexible reporting capabilities.

7. **Reconcile obsessively**: In servicing, every dollar must be accounted for. Build automated reconciliation into every step of the pipeline: borrower collections to servicer remittance, servicer remittance to trustee receipt, trustee receipt to investor distribution.
