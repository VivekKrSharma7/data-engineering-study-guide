# Loan-Level Data Fields & Schema Design

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. Origination Data Fields

Origination fields capture the characteristics of a loan at the time it was funded. These fields are static (or slowly changing) and form the foundation of loan-level analytics.

#### Core Origination Fields

| Field | Description | Typical Values / Notes |
|-------|-------------|----------------------|
| **Loan Amount** | Original principal balance at origination | Dollar amount; drives conforming vs jumbo classification |
| **Interest Rate** | Note rate at origination | Fixed or initial adjustable rate; expressed as annualized percentage |
| **FICO Score** | Borrower credit score at origination | 300-850; often the "representative" or "decision" FICO |
| **Co-Borrower FICO** | Credit score of the co-borrower if present | May be NULL; some schemas store min/max/avg of all borrowers |
| **LTV (Loan-to-Value)** | Loan amount / appraised property value | Percentage; key risk metric; 80% is a common threshold |
| **CLTV (Combined LTV)** | (First lien + subordinate liens) / appraised value | Captures total leverage including second liens |
| **DTI (Debt-to-Income)** | Monthly debt obligations / gross monthly income | Front-end (housing only) vs back-end (total debt) |
| **Property Type** | Classification of the collateral | SF (single-family), PUD, condo, co-op, manufactured, 2-4 unit |
| **Occupancy Type** | Borrower's intended use | Primary residence, second home, investment property |
| **Loan Purpose** | Reason for the loan | Purchase, rate-term refinance, cash-out refinance |
| **Channel** | How the loan was originated | Retail, wholesale (broker), correspondent, direct-to-consumer |
| **Mortgage Insurance (MI)** | Private MI coverage percentage | Required when LTV > 80%; expressed as coverage percentage (e.g., 25%) |
| **Loan Term** | Original term in months | 180 (15-year), 360 (30-year) |
| **Amortization Type** | Payment structure | Fixed, ARM (5/1, 7/1, 10/1), IO (interest-only), balloon |
| **First Payment Date** | Date of first scheduled payment | Used to derive loan age |
| **Origination Date** | Date the loan was funded | May differ from note date |
| **Property State / MSA** | Geographic location of collateral | State code, ZIP, CBSA/MSA code |
| **Number of Units** | Units in the property | 1-4 for residential conforming |
| **Seller Name** | Entity that sold the loan into the pool | Originator or aggregator |
| **Servicer Name** | Entity responsible for collecting payments | May change over loan life |
| **Prepayment Penalty Flag** | Whether loan has a prepayment penalty | Yes/No; includes penalty term and structure |
| **First-Time Homebuyer** | Whether borrower is a first-time buyer | Yes/No/Unknown |

#### ARM-Specific Fields

| Field | Description |
|-------|-------------|
| **Initial Fixed Period** | Months before first rate adjustment |
| **Adjustment Frequency** | How often the rate resets after initial period |
| **Index** | Reference rate (SOFR, 1-Year Treasury, etc.) |
| **Margin** | Spread added to the index |
| **Initial Rate Cap** | Max rate change at first adjustment |
| **Periodic Rate Cap** | Max rate change per subsequent adjustment |
| **Lifetime Rate Cap** | Maximum rate over the life of the loan |
| **Lifetime Rate Floor** | Minimum rate over the life of the loan |

### 2. Performance Data Fields

Performance fields track how the loan behaves over time. These are time-series data points reported monthly.

#### Core Performance Fields

| Field | Description | Notes |
|-------|-------------|-------|
| **Current UPB** | Current unpaid principal balance | Decreases with amortization; may increase with negative amortization |
| **Loan Status** | Current state of the loan | Current, 30-day, 60-day, 90+ day delinquent, foreclosure, REO, paid-off |
| **Delinquency Status** | Number of months delinquent | 0, 1, 2, 3, ... mapped to DQ buckets |
| **Monthly Reporting Period** | The as-of date for the performance snapshot | Typically month-end |
| **Actual Loss** | Net loss realized on liquidation | Calculated after all recoveries |
| **Scheduled Principal** | Scheduled principal portion of payment | Per amortization schedule |
| **Actual Principal Collected** | Principal actually received | May differ from scheduled if borrower pays more or less |
| **Interest Collected** | Interest portion of payment received | Gross interest before servicing fee |
| **Current Interest Rate** | Rate in effect for the reporting period | May differ from origination rate for ARMs or modified loans |
| **Remaining Term** | Months remaining to maturity | Decreases monthly; resets on modification |

#### Modification Fields

| Field | Description |
|-------|-------------|
| **Modification Flag** | Whether the loan has been modified |
| **Modification Date** | Date modification took effect |
| **Modification Type** | Rate reduction, term extension, principal forbearance, principal forgiveness |
| **Modified Rate** | New interest rate post-modification |
| **Modified UPB** | New balance post-modification (may include capitalized arrearages) |
| **Modified Term** | New remaining term post-modification |
| **Non-Interest-Bearing UPB** | Forborne principal amount (deferred, non-interest-bearing) |
| **Step-Rate Flag** | Whether the modified rate steps up over time |

#### Foreclosure & Disposition Fields

| Field | Description |
|-------|-------------|
| **Foreclosure Date** | Date foreclosure proceedings began |
| **REO Acquisition Date** | Date property became real estate owned |
| **Disposition Date** | Date of final liquidation (sale, short sale, etc.) |
| **Disposition Type** | Third-party sale, short sale, REO sale, deed-in-lieu |
| **Net Sale Proceeds** | Gross proceeds minus selling expenses |
| **MI Recovery** | Amount recovered from mortgage insurance |
| **Total Credit Loss** | UPB at default minus all recoveries |
| **Expenses** | Legal fees, property preservation, taxes advanced |

#### Zero Balance Code

The Zero Balance Code indicates why a loan's balance went to zero. This is a critical field for loss and prepayment analysis.

| Code | Meaning |
|------|---------|
| **01** | Prepaid or matured (voluntary payoff) |
| **02** | Third-party sale (foreclosure auction to third party) |
| **03** | Short sale |
| **06** | Repurchased from pool |
| **09** | REO disposition (Fannie Mae convention) |
| **15** | Note sale |
| **16** | Reperforming loan sale |

*Note: Exact codes vary between Fannie Mae and Freddie Mac.*

### 3. Schema Design for a Loan Data Warehouse

#### Fact vs. Dimension Tables

A well-designed loan data warehouse separates static origination attributes from time-varying performance data.

**Dimension Tables (slowly changing):**

```
dim_loan
--------
loan_id (PK, surrogate key)
loan_number (natural key)
original_upb
original_rate
fico_score
co_borrower_fico
ltv
cltv
dti
property_type_code
occupancy_code
loan_purpose_code
channel_code
mi_percentage
loan_term
amortization_type_code
first_payment_date
origination_date
maturity_date
property_state
property_zip
msa_code
number_of_units
seller_id (FK -> dim_seller)
servicer_id (FK -> dim_servicer)
prepayment_penalty_flag
first_time_homebuyer_flag
load_date
effective_from
effective_to
is_current
```

**Fact Tables (event/periodic):**

```
fact_loan_performance (monthly grain)
-------------------------------------
performance_id (PK, surrogate key)
loan_id (FK -> dim_loan)
reporting_period (FK -> dim_date)
current_upb
current_rate
loan_status_code
delinquency_months
scheduled_principal
actual_principal_collected
interest_collected
modification_flag
non_interest_bearing_upb
zero_balance_code
zero_balance_date
net_sale_proceeds
mi_recovery
credit_loss
load_date
```

**Supporting Dimension Tables:**

```
dim_property_type (property_type_code, description)
dim_occupancy (occupancy_code, description)
dim_loan_purpose (purpose_code, description)
dim_channel (channel_code, description)
dim_amortization_type (amort_type_code, description)
dim_servicer (servicer_id, servicer_name, eff_from, eff_to)
dim_seller (seller_id, seller_name)
dim_date (date_key, calendar_month, quarter, year, ...)
dim_loan_status (status_code, status_description, dq_bucket)
```

### 4. Slowly Changing Dimensions (SCD) for Loan Data

Loan data has both static and changing attributes, making SCD design critical.

#### SCD Type 1 — Overwrite

Used for corrections (e.g., fixing a data entry error on FICO score). The old value is lost.

```sql
UPDATE dim_loan
SET fico_score = 720
WHERE loan_number = 'LN-2025-001234';
```

#### SCD Type 2 — Historical Tracking

Used when you need to preserve history of changes such as servicer transfers or loan modifications.

```
loan_id | loan_number      | servicer_id | effective_from | effective_to | is_current
--------|------------------|-------------|----------------|--------------|----------
1001    | LN-2025-001234   | SVC_A       | 2025-01-01     | 2025-06-30   | N
1002    | LN-2025-001234   | SVC_B       | 2025-07-01     | 9999-12-31   | Y
```

This pattern is essential for:
- **Servicer transfers**: Tracking which servicer owned the relationship at any point in time
- **Loan modifications**: Preserving pre- and post-modification attributes
- **Rating agency lookback**: Auditing what data was known at a given date

#### SCD Type 3 — Previous Value Column

Used when you need the current and one prior value (e.g., previous servicer).

```
loan_number      | current_servicer | previous_servicer | servicer_change_date
-----------------|------------------|-------------------|---------------------
LN-2025-001234   | SVC_B            | SVC_A             | 2025-07-01
```

### 5. Temporal Modeling for Loan Data

Temporal modeling is essential because loan data is inherently time-series:

- **Transaction time**: When the data was loaded into the warehouse (audit trail)
- **Valid time**: When the data was true in the real world (business time)
- **Bi-temporal**: Tracks both, enabling "as-of" and "as-known" queries

**Bi-temporal example for loan status:**

```sql
CREATE TABLE loan_status_bitemporal (
    loan_id             BIGINT,
    loan_status_code    VARCHAR(2),
    valid_from          DATE,       -- when status became true
    valid_to            DATE,       -- when status ceased to be true
    transaction_from    TIMESTAMP,  -- when record was inserted
    transaction_to      TIMESTAMP,  -- when record was superseded
    PRIMARY KEY (loan_id, valid_from, transaction_from)
);
```

This supports queries like:
- "What was the loan status as of March 2025?" (valid time query)
- "What did we believe the loan status was on March 15, 2025, at the time of reporting?" (bi-temporal query)
- Retroactive corrections without losing the audit trail

---

## Real-World Examples

### Example 1: Building an Agency Loan-Level Extract Pipeline

Fannie Mae and Freddie Mac publish quarterly loan-level datasets for credit risk transfer (CRT) analysis.

**Pipeline steps:**
1. Download fixed-width or pipe-delimited files from agency SFTP/portals
2. Parse origination file (static fields) and performance file (monthly time series)
3. Apply data quality checks: FICO range validation, LTV bounds, date logic
4. Load origination data into `dim_loan` (SCD Type 2 for servicer changes)
5. Load performance data into `fact_loan_performance` (append-only monthly partitioned)
6. Build derived metrics: ever-60-DQ flag, cumulative default rate, voluntary CPR

**Data volumes:**
- Fannie Mae CAS dataset: ~40 million active loans, ~1 billion+ performance records
- Monthly refresh adds ~40 million performance rows
- Partitioning by `reporting_period` is critical for query performance

### Example 2: Servicer Transfer Impact Analysis

When a servicing portfolio transfers, the data engineer must:
1. Identify all loans with a servicer change between consecutive monthly files
2. Create new SCD Type 2 rows in `dim_loan` with updated servicer
3. Validate UPB continuity across the transfer boundary
4. Flag any loans with status discrepancies (e.g., loan was "current" under old servicer, suddenly "60-day" under new servicer)
5. Reconcile loan counts and aggregate UPB between old and new servicer reports

### Example 3: Modification Tracking Pipeline

```sql
-- Identify newly modified loans in the monthly feed
SELECT
    lp.loan_id,
    lp.reporting_period,
    lp.current_upb AS post_mod_upb,
    prev.current_upb AS pre_mod_upb,
    lp.current_rate AS post_mod_rate,
    prev.current_rate AS pre_mod_rate,
    lp.non_interest_bearing_upb
FROM fact_loan_performance lp
JOIN fact_loan_performance prev
    ON lp.loan_id = prev.loan_id
    AND prev.reporting_period = DATE_ADD(lp.reporting_period, INTERVAL -1 MONTH)
WHERE lp.modification_flag = 'Y'
  AND prev.modification_flag = 'N';
```

---

## Common Interview Questions & Answers

### Q1: What is the difference between LTV and CLTV, and why does it matter for secondary market data?

**Answer:** LTV (Loan-to-Value) measures only the first lien mortgage amount against the appraised property value. CLTV (Combined Loan-to-Value) includes all liens on the property, such as second mortgages or HELOCs.

In the secondary market, CLTV is critical because a loan with an 80% LTV but 95% CLTV has significantly more risk than one with 80% LTV and no subordinate liens. For MBS pools, both metrics are used in credit risk stratification. A data engineer must ensure both fields are captured accurately and handle cases where CLTV data is missing (common in older vintages). The GSEs require CLTV reporting for CRT deals, and discrepancies between LTV and CLTV can indicate data quality issues.

### Q2: How would you design a schema to track loan modifications over time?

**Answer:** I would use a combination of approaches:

1. **SCD Type 2 on `dim_loan`**: Create a new row whenever a modification occurs, capturing the new rate, term, and UPB with effective date ranges. This lets analysts join performance data to the correct loan attributes at any point in time.

2. **Dedicated `dim_loan_modification` table**: Store each modification event with pre-modification and post-modification values, modification type (rate reduction, term extension, principal forbearance, forgiveness), and effective date. This supports modification-specific analytics.

3. **Performance fact table**: Include `modification_flag` and `non_interest_bearing_upb` columns so monthly snapshots reflect the loan's modified state.

The key design decision is ensuring that the performance fact table can join to the correct version of the loan dimension using the reporting period and the SCD effective date range.

### Q3: Explain the Zero Balance Code and its significance in prepayment and loss analysis.

**Answer:** The Zero Balance Code indicates why a loan's UPB reached zero. It is the most critical field for separating voluntary prepayments from involuntary terminations:

- **Code 01 (Prepaid/Matured)**: Voluntary payoff. This drives CPR (Conditional Prepayment Rate) calculations. It includes refinances, home sales, and natural maturity.
- **Codes 02, 03, 09 (Third-party sale, Short sale, REO)**: Credit events. These drive CDR (Conditional Default Rate) and loss severity calculations.
- **Code 06 (Repurchase)**: The loan was bought back, typically due to a representation and warranty breach. These must be excluded from both CPR and CDR to avoid skewing metrics.

As a data engineer, I ensure the Zero Balance Code is properly mapped across different agency formats (Fannie and Freddie use different code sets), validated against related fields (e.g., a Code 03 should have disposition proceeds), and used correctly in downstream analytics pipelines.

### Q4: How do you partition and index a loan performance table with billions of rows?

**Answer:** For a monthly loan performance table at scale:

**Partitioning Strategy:**
- Primary partition by `reporting_period` (monthly range partitioning). This aligns with how data arrives and how most queries filter.
- Sub-partition by `loan_status_code` or `property_state` if query patterns justify it.

**Indexing Strategy:**
- Clustered index or sort key on `(loan_id, reporting_period)` for efficient loan-history lookups
- Secondary index on `reporting_period` for cohort-level queries
- Composite index on `(reporting_period, loan_status_code)` for delinquency reporting

**Storage Optimization:**
- Columnar format (Parquet/ORC) for analytical queries
- Compression (Snappy or ZSTD) given high redundancy in status codes
- In cloud warehouses (Redshift, BigQuery, Snowflake), use the distribution/cluster key on `loan_id` for join performance

**Retention and Archival:**
- Hot tier: last 24 months of performance data
- Warm tier: full history in compressed columnar storage
- Aggregate tables for trend analysis to avoid scanning billions of rows

### Q5: What data quality checks would you implement for incoming loan-level data?

**Answer:** I would implement multi-layered validation:

**Field-Level Checks:**
- FICO: 300-850 range, not null for origination records
- LTV/CLTV: 0-200% range, CLTV >= LTV
- DTI: 0-100% range (flag but do not reject outliers above 65%)
- UPB: positive, decreasing over time for performing fixed-rate loans
- Dates: origination date < first payment date < maturity date
- Interest rate: positive, within reasonable bounds (0.5%-15%)

**Cross-Field Checks:**
- If LTV > 80% and MI percentage = 0, flag as potential data issue
- If occupancy = investment property and LTV > 85%, flag (exceeds typical guidelines)
- If zero balance code is populated, current UPB should be zero

**Temporal Checks:**
- UPB should not increase month-over-month for fully amortizing loans (unless modified)
- Delinquency should progress logically (a loan cannot jump from current to 90-day in one month without explanation)
- Loan should not report performance data after zero balance date

**Aggregate Checks:**
- Total UPB reconciles with pool-level factor reports
- Loan count matches expected count from deal documents
- Distribution of FICO, LTV, and DTI should be consistent with prior months (flag sudden shifts)

---

## Tips

1. **Know your agency file layouts**: Fannie Mae and Freddie Mac publish detailed data dictionaries for their CAS/STACR loan-level disclosures. Familiarize yourself with the field names, formats, and update frequencies.

2. **Design for late-arriving data**: Servicer reports sometimes arrive late or with corrections. Your schema should handle retroactive updates without corrupting historical snapshots. Bi-temporal modeling is the gold standard.

3. **NULL handling is critical**: Many loan-level fields are conditionally required. For example, ARM fields are NULL for fixed-rate loans, and co-borrower FICO is NULL for single-borrower loans. Never treat NULL as zero in calculations.

4. **Understand the grain**: The origination table has one row per loan. The performance table has one row per loan per reporting month. Mixing these grains in a single query is a common source of errors (e.g., double-counting origination UPB across months).

5. **Map codes across sources**: Fannie Mae and Freddie Mac use different code sets for property type, occupancy, and loan status. If your warehouse combines both, create a unified code mapping layer.

6. **Version your schemas**: Loan-level disclosure formats change over time (new fields are added, codes are redefined). Maintain schema version metadata so you can correctly parse historical files.

7. **Performance data is append-heavy**: Use insert-only patterns for the performance fact table. Avoid UPDATEs on large fact tables; instead, use a staging/merge pattern that handles corrections via soft deletes or versioned rows.
