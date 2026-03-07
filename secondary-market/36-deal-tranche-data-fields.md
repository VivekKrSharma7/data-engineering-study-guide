# Deal/Tranche-Level Data Fields

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. Deal-Level Data Fields

A deal (or trust) is the legal entity that holds a pool of mortgage loans and issues securities (tranches) backed by those loans. Deal-level fields describe the overall securitization.

#### Core Deal Fields

| Field | Description | Example |
|-------|-------------|---------|
| **Deal Name** | Identifier for the securitization | FNMS 2025-C01, FHMS K-150, CAS 2025-R03 |
| **Deal CUSIP** | Master CUSIP for the deal (sometimes the first tranche) | 3136ABCD0 |
| **Issuer** | Entity that structured and issued the deal | Fannie Mae, Freddie Mac, private-label issuer |
| **Shelf** | Registration shelf under which the deal was issued | Fannie Mae CAS, Freddie Mac STACR |
| **Series** | Series designation within the shelf | 2025-R03 |
| **Settlement Date** | Date the deal was priced and securities delivered | 2025-06-15 |
| **First Distribution Date** | Date of the first P&I payment to investors | 2025-07-25 |
| **Collateral Type** | Type of loans backing the deal | 30-year fixed, 15-year fixed, ARM, mixed |
| **Original Deal Balance** | Sum of all tranche original balances | $1,250,000,000 |
| **Original Collateral Balance** | Total UPB of the underlying loan pool at cut-off | May differ from deal balance (overcollateralization) |
| **Cut-Off Date** | Date as of which the collateral pool is defined | 2025-05-01 |
| **Closing Date** | Date the trust was legally established | 2025-06-12 |
| **Distribution Frequency** | How often payments are made | Monthly (most RMBS), quarterly (some CRT) |
| **Trustee** | Entity that holds assets on behalf of investors | U.S. Bank, Wilmington Trust, Bank of New York Mellon |
| **Master Servicer** | Entity responsible for overseeing servicing | Wells Fargo, Computershare |
| **Deal Type** | Classification | Pass-through, CMO, CRT, REMIC, FASIT |
| **Tax Election** | Trust tax status | REMIC, grantor trust |
| **Paying Agent** | Entity that distributes payments to investors | Often the trustee |

#### Agency-Specific Deal Identifiers

| Agency | Identifier Format | Example |
|--------|-------------------|---------|
| **Fannie Mae MBS** | Pool number (6-digit) | Pool #AL1234 |
| **Fannie Mae REMIC** | FNR series-class | FNR 2025-C01 |
| **Freddie Mac PC** | Pool number (6-digit) | Pool #Q12345 |
| **Freddie Mac REMIC** | FHR series-class | FHR 5200 |
| **Ginnie Mae** | Pool number | Pool #MA1234 |
| **Ginnie Mae REMIC** | GNR series-class | GNR 2025-001 |

### 2. Tranche-Level Data Fields

A tranche is an individual security within a deal, with specific payment rules, credit priority, and risk profile.

#### Core Tranche Fields

| Field | Description | Notes |
|-------|-------------|-------|
| **Tranche Name** | Identifier within the deal | A1, A2, M1, M2, B1, B2, CE |
| **Tranche CUSIP** | Unique 9-character security identifier | 3136ABCD1 (differs from deal CUSIP by check digit or issue number) |
| **Original Balance** | Face amount at issuance | $500,000,000 |
| **Current Balance** | Outstanding principal as of reporting date | Decreases with paydowns |
| **Coupon Rate** | Interest rate paid to investors | Fixed (e.g., 4.50%) or floating (SOFR + 200bps) |
| **Coupon Type** | Fixed, floating, inverse floating, step-up | Determines how interest is calculated |
| **Tranche Type** | Structural classification | Sequential, PAC, TAC, support/companion, Z-bond, IO, PO, residual |
| **Credit Rating** | Rating at issuance and current | AAA, AA, A, BBB, BB, B, NR |
| **Rating Agency** | Which agency rated | S&P, Moody's, Fitch, DBRS, Kroll |
| **Credit Enhancement (CE)** | Subordination level protecting this tranche | Expressed as percentage of deal balance |
| **WAL (Weighted Average Life)** | Expected average time to receive principal | In years; depends on prepayment assumption |
| **Payment Window** | First and last expected principal payment dates | E.g., Jul 2025 - Mar 2028 |
| **Principal Type** | How principal is allocated | Pro-rata, sequential, targeted (PAC/TAC schedule) |
| **Interest Accrual Method** | 30/360, actual/360, actual/actual | Determines interest calculation |
| **Day Count Convention** | Specific day count for interest | 30/360 is standard for agency RMBS |
| **Notional Flag** | Whether the tranche has notional (not actual) principal | IO tranches are notional |
| **ERISA Eligible** | Whether the tranche qualifies for pension fund investment | Based on rating and structure |
| **Original WAC** | Weighted average coupon of underlying collateral | Used for WAC-capped tranche calculations |
| **Original WAM** | Weighted average maturity of underlying collateral | In months |
| **Original WALA** | Weighted average loan age of underlying collateral | In months at cut-off |
| **Factor** | Current balance / original balance | Updated monthly |
| **Lockout Period** | Period during which no principal is paid | Common for credit tranches |
| **Expected Maturity** | Modeled maturity at a given prepayment speed | At pricing speed assumption |
| **Legal Final Maturity** | Latest possible date for final payment | Contractual backstop |

### 3. Group-Level Data

Some deals divide their collateral into groups that map to specific tranche sets.

```
Deal: FNR 2025-C01
├── Group 1 (30-year fixed, 3.5% - 4.0% WAC)
│   ├── Tranche A1 (sequential, senior)
│   ├── Tranche A2 (sequential, senior)
│   └── Tranche A-IO (interest-only, notional)
├── Group 2 (30-year fixed, 4.0% - 4.5% WAC)
│   ├── Tranche B1 (sequential, senior)
│   └── Tranche B2 (sequential, senior)
└── Group X (Exchange classes / combined)
    ├── Tranche XA (exchangeable)
    └── Tranche XB (exchangeable)
```

**Group-Level Fields:**

| Field | Description |
|-------|-------------|
| **Group ID** | Identifier (1, 2, A, B, etc.) |
| **Group Collateral Balance** | Total UPB of loans assigned to this group |
| **Group WAC** | Weighted average coupon for the group's collateral |
| **Group WAM** | Weighted average maturity |
| **Group Factor** | Current group balance / original group balance |

### 4. Collateral Summary Fields

Collateral summaries provide aggregate statistics about the loan pool backing the deal.

| Field | Description |
|-------|-------------|
| **Number of Loans** | Total loan count in the pool |
| **Average Loan Balance** | Total UPB / loan count |
| **WA FICO** | Weighted average FICO (by UPB) |
| **WA LTV** | Weighted average LTV (by UPB) |
| **WA CLTV** | Weighted average CLTV (by UPB) |
| **WA DTI** | Weighted average DTI (by UPB) |
| **WA Coupon** | Weighted average note rate |
| **Geographic Concentration** | Top states by UPB percentage |
| **Property Type Distribution** | Percentage by SF, condo, PUD, etc. |
| **Occupancy Distribution** | Percentage by owner-occupied, investor, second home |
| **Loan Purpose Distribution** | Percentage by purchase, refi, cash-out |
| **Delinquency Distribution** | Current, 30-day, 60-day, 90+ by count and UPB |
| **CPR (1-month, 3-month, 6-month, life)** | Conditional prepayment rates |
| **CDR** | Conditional default rate |
| **Cumulative Loss** | Total losses to date as percentage of original balance |

### 5. Mapping Deals, Tranches, and Collateral

The relationship between deals, tranches, and collateral is a many-to-many structure that requires careful modeling.

```
                    ┌─────────────┐
                    │    Deal     │
                    │  (1 trust)  │
                    └──────┬──────┘
                           │ 1:N
                    ┌──────┴──────┐
                    │   Groups    │
                    │ (optional)  │
                    └──────┬──────┘
                      1:N  │  1:N
              ┌────────────┼────────────┐
              │            │            │
        ┌─────┴─────┐ ┌───┴────┐ ┌─────┴──────┐
        │ Tranches  │ │Tranches│ │  Tranches  │
        │ (Group 1) │ │(Grp 2) │ │ (Exchange) │
        └───────────┘ └────────┘ └────────────┘
                           │
                      N:M  │  (collateral mapping)
                    ┌──────┴──────┐
                    │   Loans     │
                    │ (collateral)│
                    └─────────────┘
```

**Key relationships:**
- One deal has many tranches (1:N)
- One deal has one collateral pool, optionally split into groups
- In resecuritizations (re-REMICs), one underlying security can appear in multiple deals (N:M)
- Exchange classes allow investors to swap between tranche combinations

### 6. Intex Deal Fields

Intex is the industry-standard analytics platform for structured finance. Their deal model includes additional fields.

| Intex Field | Description |
|-------------|-------------|
| **Intex Deal ID** | Proprietary deal identifier (e.g., "FNA 25C01") |
| **Intex Tranche ID** | Tranche identifier within Intex model |
| **Deal Model Version** | Version of the cash flow model |
| **Waterfall Rules** | Encoded payment priority rules |
| **Trigger Tests** | Delinquency/loss triggers that shift cash flow priority |
| **Clean-Up Call** | Optional call provision (e.g., 10% of original balance) |
| **Deal Documents** | Prospectus supplement, pooling and servicing agreement |
| **Cash Flow Dates** | Accrual start, payment date, record date |

### 7. Database Schema Design

#### Relational Schema

```sql
-- Deal dimension
CREATE TABLE dim_deal (
    deal_id             BIGINT PRIMARY KEY,
    deal_name           VARCHAR(50) NOT NULL,
    deal_cusip          CHAR(9),
    issuer_id           INT REFERENCES dim_issuer(issuer_id),
    shelf               VARCHAR(50),
    series              VARCHAR(20),
    settlement_date     DATE,
    first_dist_date     DATE,
    cut_off_date        DATE,
    closing_date        DATE,
    collateral_type     VARCHAR(30),
    original_deal_balance   DECIMAL(18,2),
    original_coll_balance   DECIMAL(18,2),
    distribution_freq   VARCHAR(10),
    trustee_id          INT REFERENCES dim_trustee(trustee_id),
    master_servicer_id  INT REFERENCES dim_servicer(servicer_id),
    deal_type           VARCHAR(20),
    tax_election        VARCHAR(20),
    intex_deal_id       VARCHAR(30),
    load_date           TIMESTAMP
);

-- Group dimension
CREATE TABLE dim_group (
    group_id            BIGINT PRIMARY KEY,
    deal_id             BIGINT REFERENCES dim_deal(deal_id),
    group_name          VARCHAR(10),
    original_balance    DECIMAL(18,2),
    original_wac        DECIMAL(6,4),
    original_wam        INT,
    load_date           TIMESTAMP
);

-- Tranche dimension
CREATE TABLE dim_tranche (
    tranche_id          BIGINT PRIMARY KEY,
    deal_id             BIGINT REFERENCES dim_deal(deal_id),
    group_id            BIGINT REFERENCES dim_group(group_id),
    tranche_name        VARCHAR(20) NOT NULL,
    tranche_cusip       CHAR(9) UNIQUE,
    original_balance    DECIMAL(18,2),
    coupon_rate         DECIMAL(8,5),
    coupon_type         VARCHAR(20),
    tranche_type        VARCHAR(30),
    principal_type      VARCHAR(20),
    accrual_method      VARCHAR(15),
    notional_flag       CHAR(1),
    legal_final_mat     DATE,
    lockout_end_date    DATE,
    intex_tranche_id    VARCHAR(30),
    load_date           TIMESTAMP
);

-- Tranche performance fact (monthly)
CREATE TABLE fact_tranche_performance (
    perf_id             BIGINT PRIMARY KEY,
    tranche_id          BIGINT REFERENCES dim_tranche(tranche_id),
    reporting_period    DATE,
    current_balance     DECIMAL(18,2),
    factor              DECIMAL(12,10),
    coupon_rate         DECIMAL(8,5),
    principal_paid      DECIMAL(18,2),
    interest_paid       DECIMAL(18,2),
    realized_loss       DECIMAL(18,2),
    credit_enhancement  DECIMAL(8,5),
    current_rating_sp   VARCHAR(10),
    current_rating_mdy  VARCHAR(10),
    current_rating_fch  VARCHAR(10),
    wal_at_current_speed DECIMAL(6,2),
    load_date           TIMESTAMP
);

-- Tranche rating history
CREATE TABLE fact_tranche_rating (
    rating_id           BIGINT PRIMARY KEY,
    tranche_id          BIGINT REFERENCES dim_tranche(tranche_id),
    rating_agency       VARCHAR(20),
    rating_action       VARCHAR(20),  -- initial, upgrade, downgrade, affirm, withdraw
    rating              VARCHAR(10),
    rating_date         DATE,
    load_date           TIMESTAMP
);

-- Collateral-to-deal mapping
CREATE TABLE map_deal_collateral (
    mapping_id          BIGINT PRIMARY KEY,
    deal_id             BIGINT REFERENCES dim_deal(deal_id),
    group_id            BIGINT REFERENCES dim_group(group_id),
    loan_id             BIGINT REFERENCES dim_loan(loan_id),
    as_of_date          DATE,
    load_date           TIMESTAMP
);

-- Collateral summary (monthly aggregate)
CREATE TABLE fact_collateral_summary (
    summary_id          BIGINT PRIMARY KEY,
    deal_id             BIGINT REFERENCES dim_deal(deal_id),
    group_id            BIGINT REFERENCES dim_group(group_id),
    reporting_period    DATE,
    loan_count          INT,
    current_upb         DECIMAL(18,2),
    wa_coupon           DECIMAL(8,5),
    wa_fico             DECIMAL(6,1),
    wa_ltv              DECIMAL(6,2),
    wa_dti              DECIMAL(6,2),
    wa_remaining_term   DECIMAL(6,1),
    cpr_1m              DECIMAL(8,5),
    cpr_3m              DECIMAL(8,5),
    cdr_1m              DECIMAL(8,5),
    cum_loss_pct        DECIMAL(8,5),
    dq_30_pct           DECIMAL(8,5),
    dq_60_pct           DECIMAL(8,5),
    dq_90plus_pct       DECIMAL(8,5),
    load_date           TIMESTAMP
);
```

---

## Real-World Examples

### Example 1: Building a Deal Data Warehouse from Intex

**Scenario:** Your firm subscribes to Intex and needs to load deal/tranche data into an internal warehouse for portfolio analytics.

**Pipeline:**
1. Extract deal structure files from Intex API or bulk exports (CDI format)
2. Parse deal-level attributes: name, settlement date, collateral type, balance
3. Parse tranche-level attributes: CUSIP, type, coupon, original balance, payment rules
4. Map Intex tranche types to internal classification (PAC, sequential, support, IO, etc.)
5. Load into `dim_deal` and `dim_tranche` tables
6. Monthly: extract updated factors, balances, and cash flow projections
7. Load into `fact_tranche_performance`
8. Reconcile Intex balances against trustee reports and Bloomberg data

### Example 2: Credit Enhancement Tracking

Credit enhancement (CE) changes over the life of a deal as losses are allocated and principal is paid down.

```sql
-- Track CE over time for a specific mezzanine tranche
SELECT
    tp.reporting_period,
    tp.current_balance,
    tp.credit_enhancement,
    tp.credit_enhancement - LAG(tp.credit_enhancement)
        OVER (ORDER BY tp.reporting_period) AS ce_change
FROM fact_tranche_performance tp
JOIN dim_tranche t ON tp.tranche_id = t.tranche_id
WHERE t.tranche_cusip = '3136ABCD5'
ORDER BY tp.reporting_period;
```

CE increases when subordinate tranches absorb losses (their balance decreases, increasing protection for senior tranches). CE decreases when senior tranches pay down faster than subordinate tranches in a pro-rata structure.

### Example 3: Re-REMIC Deal Mapping

A re-REMIC takes existing MBS tranches as collateral and creates new tranches.

```
Original Deal: FNR 2020-010
  └── Tranche A1 (CUSIP: 3136WXYZ1) ─── used as collateral for:

Re-REMIC Deal: FNR 2025-R01
  ├── New Tranche RA (senior, from A1 cash flows)
  └── New Tranche RB (subordinate, from A1 cash flows)
```

The data model must support this recursive structure:

```sql
-- Re-REMIC collateral mapping
CREATE TABLE map_reremic_collateral (
    reremic_deal_id     BIGINT REFERENCES dim_deal(deal_id),
    underlying_tranche_id BIGINT REFERENCES dim_tranche(tranche_id),
    allocation_pct      DECIMAL(8,5),  -- % of underlying tranche used
    load_date           TIMESTAMP
);
```

---

## Common Interview Questions & Answers

### Q1: How would you model the relationship between deals, groups, tranches, and underlying collateral in a database?

**Answer:** The model follows a hierarchical structure with an optional N:M layer:

- **Deal (1) -> Groups (N)**: One deal can have multiple collateral groups. Groups are optional; simple pass-throughs have no groups.
- **Group (1) -> Tranches (N)**: Each group has one or more tranches. Some tranches (exchange classes) may span multiple groups.
- **Deal/Group (1) -> Loans (N)**: The collateral mapping links deals (or groups) to the underlying loan pool. This is a snapshot as of the cut-off date, though loans can be substituted.

For re-REMICs, I add a separate mapping table (`map_reremic_collateral`) that links the re-REMIC deal to underlying tranche CUSIPs from other deals. This creates a recursive structure that requires careful handling in queries (e.g., CTEs for traversing the chain).

I use surrogate keys for all dimension tables and maintain natural key cross-references (CUSIP, deal name, Intex ID) for integration with external systems.

### Q2: What is the difference between a PAC, TAC, and support tranche?

**Answer:** These are CMO tranche types defined by their principal payment rules:

- **PAC (Planned Amortization Class)**: Receives principal according to a fixed schedule as long as prepayments stay within a defined band (e.g., 100-300 PSA). Offers the most predictable cash flows and WAL stability.
- **TAC (Targeted Amortization Class)**: Similar to PAC but protected against only one prepayment speed (either fast or slow), not a band. Less stable than PAC.
- **Support/Companion**: Absorbs the variability in prepayments to protect PAC and TAC tranches. Receives excess principal when speeds are fast, and receives less when speeds are slow. Has the most volatile WAL.

From a data engineering perspective, the tranche type determines which payment rules to encode in the cash flow waterfall model. In the database, I store the tranche type and, for PACs, the upper and lower PSA band as additional attributes.

### Q3: How do you handle CUSIP-level data from multiple sources with potential conflicts?

**Answer:** This is a common data integration challenge. My approach:

1. **Establish a golden source hierarchy**: Trustee reports are authoritative for balances and factors, Intex for structural data, rating agencies for ratings, and Bloomberg for market data.
2. **Build a reconciliation layer**: Load data from each source into staging tables, then compare key fields (balance, factor, coupon) across sources. Flag discrepancies that exceed tolerance thresholds (e.g., balance differs by more than $1).
3. **Create a unified `dim_tranche` table**: Apply golden source rules to resolve conflicts. Store the source of each field in metadata columns for audit purposes.
4. **Maintain a CUSIP cross-reference table**: Map between CUSIPs, Intex IDs, Bloomberg tickers, and internal identifiers. Handle CUSIP changes (e.g., when a tranche is reissued or exchanged).

### Q4: Explain credit enhancement and how you would calculate it from data.

**Answer:** Credit enhancement (CE) is the amount of protection a tranche has against losses in the underlying collateral. For a senior tranche, CE is the sum of all subordinate tranche balances plus any overcollateralization and reserve funds, expressed as a percentage of the total deal balance.

**Calculation:**

```
CE for Tranche A = (Sum of balances of all tranches subordinate to A + OC + reserve)
                   / Current total deal collateral balance

Example:
  Collateral balance: $1,000,000,000
  Tranche A balance:    $800,000,000
  Tranche M balance:    $120,000,000
  Tranche B balance:     $50,000,000
  OC:                    $30,000,000

  CE for A = ($120M + $50M + $30M) / $1,000M = 20.0%
  CE for M = ($50M + $30M) / $1,000M = 8.0%
  CE for B = ($30M) / $1,000M = 3.0%
```

In the database, I store CE as a calculated field in `fact_tranche_performance`, computed monthly as balances change. I also maintain a `tranche_priority` field in `dim_tranche` to define the payment waterfall order, which is essential for the CE calculation.

### Q5: How would you design a data pipeline for monthly deal remittance data?

**Answer:** The pipeline processes trustee distribution date statements, which report monthly cash flows for each deal:

1. **Ingest**: Receive files from trustees (typically CSV, XML, or API) on distribution dates (usually 25th of the month)
2. **Stage**: Load raw data into staging tables with full audit columns (source file, load timestamp, row number)
3. **Validate**: Check that tranche balances reconcile (prior balance - principal paid - losses + any additions = current balance), factors match balance/original balance, total principal distributed equals total principal collected from collateral
4. **Transform**: Calculate derived fields (CE, CPR at tranche level, cumulative losses), update `fact_tranche_performance`
5. **Reconcile**: Compare against independent sources (Intex, Bloomberg) and flag discrepancies
6. **Publish**: Update downstream analytics tables, trigger notifications for significant events (rating changes, trigger breaches, clean-up call eligibility)

The pipeline must handle late data, corrections (amended distribution statements), and deal-specific quirks (different trustees have different file formats).

---

## Tips

1. **Understand the waterfall**: The payment waterfall defines how cash flows are distributed across tranches. As a data engineer, you do not need to build the waterfall model, but you must understand it well enough to validate output and design the schema that stores its results.

2. **CUSIP is not always unique over time**: CUSIPs can be reused after a security is fully paid off. Always combine CUSIP with an effective date range or deal identifier in your data model.

3. **Intex is the lingua franca**: Most buy-side and sell-side firms use Intex for structured product analytics. Familiarity with their data formats (CDI files, API, deal IDs) is a strong differentiator.

4. **Tranche types drive analytics**: The type of tranche (PAC, sequential, IO, PO, support) determines its prepayment sensitivity, extension risk, and contraction risk. Your schema should capture tranche type with enough granularity to support risk analytics.

5. **Deal vintage matters**: The year a deal was issued (vintage) is a critical analytical dimension. Loans originated in 2005-2007 (pre-crisis) behave very differently from 2015-2025 originations. Ensure vintage is easily queryable.

6. **Exchange classes add complexity**: Some agency CMOs allow investors to exchange combinations of tranches. Your data model should track exchange relationships so position reconciliation is accurate.

7. **Legal final maturity vs. expected maturity**: Legal final is the contractual last possible payment date (often 30+ years out). Expected maturity depends on prepayment assumptions. Store both and be clear which one is being queried.
