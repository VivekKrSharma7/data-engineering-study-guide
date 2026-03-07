# Loan Tape Processing & Reconciliation

[Back to Secondary Market Index](./README.md)

---

## Table of Contents

1. [Key Concepts](#key-concepts)
2. [Loan Tape Definition and Structure](#loan-tape-definition-and-structure)
3. [Types of Loan Tapes](#types-of-loan-tapes)
4. [Tape-to-Tape Reconciliation](#tape-to-tape-reconciliation)
5. [Field Mapping Across Vendors](#field-mapping-across-vendors)
6. [Common Data Quality Issues](#common-data-quality-issues)
7. [UPB Reconciliation](#upb-reconciliation)
8. [Loan Count Reconciliation](#loan-count-reconciliation)
9. [Automated Validation Frameworks](#automated-validation-frameworks)
10. [Real-World Examples](#real-world-examples)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## Key Concepts

### What Is a Loan Tape?

A loan tape is a structured dataset containing detailed information about a portfolio of residential mortgage loans. The term "tape" is a legacy reference to magnetic tape data storage, but today these are typically flat files (CSV, pipe-delimited, or fixed-width), Excel spreadsheets, or database extracts.

Loan tapes are the foundational data exchange mechanism in the secondary mortgage market. They are used in:

- **Securitization**: Originators provide tapes to underwriters and rating agencies during deal structuring
- **Whole loan trading**: Sellers provide bid tapes to prospective buyers for pricing
- **Due diligence**: Third-party review firms receive tapes to sample and audit loans
- **Servicing**: Servicers produce monthly performance tapes for investors and trustees
- **Regulatory reporting**: Agencies and regulators require periodic loan-level disclosures

### Why Tape Processing Is a Core Data Engineering Skill

In the secondary market, tape processing is not just a data task -- it is a business-critical workflow. Errors in tape processing directly impact:

- **Pricing accuracy**: Incorrect UPB or delinquency data leads to mispriced trades
- **Compliance**: Regulatory filings (SEC Reg AB, FHFA quarterly filings) depend on accurate tape data
- **Investor reporting**: Trustees and investors rely on tape data for remittance calculations
- **Risk management**: Portfolio analytics are only as good as the underlying tape data

A senior data engineer must be able to ingest tapes from dozens of sources, normalize them to a canonical schema, validate data quality, and reconcile across independent sources.

---

## Loan Tape Definition and Structure

### Standard Loan Tape Fields

A comprehensive loan tape includes origination attributes, current performance data, and property information. Below are the key field categories:

#### Loan Identification

| Field | Description | Example |
|-------|-------------|---------|
| Loan Number | Unique identifier assigned by originator/servicer | 1234567890 |
| Original Loan Number | Pre-transfer loan number (if applicable) | 9876543210 |
| Investor Loan Number | ID used by agency or investor | FN001234567 |
| Pool ID / CUSIP | Security pool or CUSIP the loan is assigned to | MA4567 / 31410GXY2 |
| Deal Name | Securitization trust name | FNMS 2024-C01 |

#### Origination Attributes

| Field | Description | Typical Values |
|-------|-------------|---------------|
| Origination Date | Date the loan was originated | 2022-03-15 |
| First Payment Date | Date of first scheduled payment | 2022-05-01 |
| Maturity Date | Scheduled final payment date | 2052-04-01 |
| Original Loan Amount | UPB at origination | $350,000.00 |
| Original Interest Rate | Note rate at origination | 3.750% |
| Original Loan Term | Term in months | 360 |
| Loan Purpose | Purchase, rate/term refi, or cash-out refi | Purchase |
| Occupancy Type | Primary residence, second home, investment | Primary |
| Property Type | SFR, condo, co-op, PUD, manufactured housing | SFR |
| Number of Units | 1-4 for residential | 1 |
| Channel | Retail, wholesale, correspondent | Retail |

#### Borrower/Credit Attributes

| Field | Description | Typical Values |
|-------|-------------|---------------|
| Borrower Credit Score | FICO at origination | 745 |
| Co-Borrower Credit Score | Co-borrower FICO if applicable | 720 |
| DTI Ratio | Debt-to-income ratio | 38.5% |
| LTV Ratio | Loan-to-value at origination | 80.0% |
| CLTV Ratio | Combined LTV (includes subordinate liens) | 80.0% |
| Number of Borrowers | Count of borrowers on the note | 2 |
| First-Time Homebuyer | Flag indicating first-time buyer | Y/N |
| Documentation Type | Full doc, alt doc, no doc | Full |

#### Current Performance Attributes

| Field | Description | Typical Values |
|-------|-------------|---------------|
| Current UPB | Outstanding principal balance as of reporting date | $325,432.18 |
| Scheduled UPB | Expected UPB based on amortization schedule | $325,100.00 |
| Current Interest Rate | Note rate (may differ from original if modified or ARM) | 3.750% |
| P&I Payment Amount | Monthly principal and interest payment | $1,620.91 |
| Next Payment Due Date | Date of next scheduled payment | 2025-04-01 |
| Last Payment Received Date | Date of most recent payment | 2025-02-28 |
| Payment Status | Current, 30/60/90/120+ DPD, FC, REO, Paid Off | Current |
| Months Delinquent | Number of months of missed payments | 0 |
| Loan Age | Months since origination | 35 |
| Remaining Term | Months to maturity | 325 |

#### Property/Collateral Attributes

| Field | Description | Typical Values |
|-------|-------------|---------------|
| Property State | State where property is located | CA |
| Property ZIP Code | ZIP code of property | 90210 |
| Property County | County name or FIPS code | Los Angeles |
| MSA/CBSA Code | Metropolitan statistical area code | 31080 |
| Original Appraised Value | Appraised value at origination | $437,500.00 |
| Current Property Value | Updated value (BPO, AVM, or new appraisal) | $480,000.00 |
| Valuation Date | Date of current value estimate | 2024-11-15 |
| Valuation Method | AVM, BPO, Full Appraisal, Drive-by | AVM |

---

## Types of Loan Tapes

### Due Diligence Tapes

**Purpose**: Provided during the pre-securitization or pre-sale process for third-party due diligence review.

**Characteristics**:
- Most comprehensive tape -- includes full origination data, credit attributes, and collateral details
- Represents a point-in-time snapshot of the proposed pool
- Used by due diligence firms (e.g., Clayton, AMC, Opus) to select and review a sample of loans
- Rating agencies use these tapes to run their loss models
- May include scanned document inventories

**Key fields unique to DD tapes**: Document checklist flags, exception codes, re-underwriting results, compliance review status.

```sql
-- Example: Due diligence tape staging table
CREATE TABLE stg_dd_tape (
    loan_number             VARCHAR(20),
    origination_date        VARCHAR(10),
    original_amount         VARCHAR(15),
    original_rate           VARCHAR(10),
    original_term           VARCHAR(5),
    fico_score              VARCHAR(5),
    ltv                     VARCHAR(8),
    cltv                    VARCHAR(8),
    dti                     VARCHAR(8),
    property_type           VARCHAR(5),
    occupancy               VARCHAR(5),
    property_state          VARCHAR(2),
    property_zip            VARCHAR(10),
    loan_purpose            VARCHAR(5),
    documentation_type      VARCHAR(10),
    appraised_value         VARCHAR(15),
    income                  VARCHAR(15),
    employer_name           VARCHAR(100),
    mi_coverage_pct         VARCHAR(8),
    mi_company              VARCHAR(50),
    -- DD-specific fields
    dd_sample_flag          VARCHAR(1),
    dd_grade                VARCHAR(5),     -- A, B, C, D, E
    dd_exception_count      VARCHAR(5),
    dd_compliance_result    VARCHAR(20),
    dd_credit_result        VARCHAR(20),
    dd_collateral_result    VARCHAR(20),
    -- Metadata
    source_file             VARCHAR(255),
    load_timestamp          DATETIME DEFAULT GETDATE()
);
```

### Servicing Tapes (Monthly Performance Tapes)

**Purpose**: Monthly reporting by servicers to investors, trustees, and master servicers showing current loan status.

**Characteristics**:
- Produced monthly, tied to the remittance cycle
- Focus on current performance: UPB, delinquency, payment activity
- Each servicer has their own format (this is the #1 pain point for data engineers)
- Used to calculate pool factors, remittance amounts, and performance metrics
- Must reconcile with trustee reports

```sql
-- Example: Monthly servicing tape with common fields
CREATE TABLE stg_servicing_tape (
    servicer_loan_id        VARCHAR(20),
    investor_loan_id        VARCHAR(20),
    pool_id                 VARCHAR(20),
    reporting_date          VARCHAR(10),
    current_upb             VARCHAR(15),
    scheduled_upb           VARCHAR(15),
    interest_rate           VARCHAR(10),
    pi_payment              VARCHAR(15),
    next_due_date           VARCHAR(10),
    last_paid_date          VARCHAR(10),
    payment_status          VARCHAR(10),
    months_delinquent       VARCHAR(5),
    -- Payment breakdown
    principal_collected     VARCHAR(15),
    interest_collected      VARCHAR(15),
    escrow_collected        VARCHAR(15),
    late_fees_collected     VARCHAR(15),
    curtailment_amount      VARCHAR(15),
    payoff_amount           VARCHAR(15),
    -- Loss mitigation
    modification_flag       VARCHAR(1),
    forbearance_flag        VARCHAR(1),
    repayment_plan_flag     VARCHAR(1),
    bankruptcy_flag         VARCHAR(1),
    bankruptcy_chapter      VARCHAR(5),
    foreclosure_flag        VARCHAR(1),
    foreclosure_start_date  VARCHAR(10),
    reo_flag                VARCHAR(1),
    -- Metadata
    servicer_id             VARCHAR(10),
    source_file             VARCHAR(255),
    load_timestamp          DATETIME DEFAULT GETDATE()
);
```

### Trial Balance Tapes

**Purpose**: Accounting-level detail for each loan showing scheduled payments, actual collections, advances, and shortfalls.

**Characteristics**:
- Used primarily by master servicers and trustees for remittance reconciliation
- Contains detailed payment accounting: scheduled vs. collected, P&I breakdown, advances
- Ties to the trust's waterfall calculations
- More granular than standard servicing tapes

```sql
-- Example: Trial balance tape
CREATE TABLE stg_trial_balance (
    loan_number             VARCHAR(20),
    pool_id                 VARCHAR(20),
    reporting_period        VARCHAR(10),
    -- Scheduled amounts
    scheduled_principal     VARCHAR(15),
    scheduled_interest      VARCHAR(15),
    scheduled_total_pi      VARCHAR(15),
    -- Collected amounts
    collected_principal     VARCHAR(15),
    collected_interest      VARCHAR(15),
    collected_escrow        VARCHAR(15),
    collected_late_fees     VARCHAR(15),
    -- Advances
    principal_advance       VARCHAR(15),
    interest_advance        VARCHAR(15),
    tax_advance             VARCHAR(15),
    insurance_advance       VARCHAR(15),
    corporate_advance       VARCHAR(15),
    -- Balances
    beginning_upb           VARCHAR(15),
    ending_upb              VARCHAR(15),
    escrow_balance          VARCHAR(15),
    suspense_balance        VARCHAR(15),
    -- Curtailments and prepayments
    curtailment_amount      VARCHAR(15),
    full_prepayment_amount  VARCHAR(15),
    -- Loss activity
    loss_amount             VARCHAR(15),
    recovery_amount         VARCHAR(15),
    mi_claim_amount         VARCHAR(15),
    -- Metadata
    source_file             VARCHAR(255),
    load_timestamp          DATETIME DEFAULT GETDATE()
);
```

### Bid Tapes

**Purpose**: Subset of loan data shared with prospective buyers for pricing whole loan trades or scratch-and-dent pools.

**Characteristics**:
- Typically anonymized (no borrower PII)
- Contains enough data to price: UPB, rate, FICO, LTV, property state, delinquency status
- May exclude sensitive fields for confidentiality until after NDA signing
- Often in Excel format

### Investor Reporting Tapes

**Purpose**: Monthly or quarterly loan-level disclosures required by SEC Reg AB II for publicly offered ABS.

**Characteristics**:
- Standardized XML format per SEC requirements
- Covers all loans in the trust
- Published on EDGAR and deal-specific websites
- Includes extensive performance history

---

## Tape-to-Tape Reconciliation

### What Is Tape Reconciliation?

Tape reconciliation is the process of comparing two independent data sources for the same portfolio to identify and resolve discrepancies. This is one of the most critical data quality processes in the secondary market.

### Common Reconciliation Pairs

| Source A | Source B | Purpose |
|----------|----------|---------|
| Servicer tape | Trustee report | Verify servicer reporting accuracy |
| Servicer tape (current month) | Servicer tape (prior month) | Month-over-month consistency |
| Seller due diligence tape | Buyer due diligence tape | Ensure both parties agree on pool composition |
| Agency disclosure file | Internal database | Verify data warehouse accuracy |
| Trial balance tape | Remittance report | Verify cash flow calculations |
| Sub-servicer tape | Master servicer tape | Validate sub-servicer reporting |

### Reconciliation Methodology

```sql
-- Step 1: Match loans between two sources
WITH matched_loans AS (
    SELECT
        COALESCE(a.loan_id, b.loan_id) AS loan_id,
        a.loan_id AS source_a_loan_id,
        b.loan_id AS source_b_loan_id,
        a.current_upb AS upb_source_a,
        b.current_upb AS upb_source_b,
        a.interest_rate AS rate_source_a,
        b.interest_rate AS rate_source_b,
        a.delinquency_status AS dlq_source_a,
        b.delinquency_status AS dlq_source_b,
        CASE
            WHEN a.loan_id IS NULL THEN 'IN_B_ONLY'
            WHEN b.loan_id IS NULL THEN 'IN_A_ONLY'
            ELSE 'MATCHED'
        END AS match_status
    FROM servicer_tape a
    FULL OUTER JOIN trustee_report b
        ON a.loan_id = b.loan_id
        AND a.reporting_period = b.reporting_period
    WHERE a.reporting_period = '2025-03-01'
       OR b.reporting_period = '2025-03-01'
)

-- Step 2: Identify discrepancies
SELECT
    loan_id,
    match_status,
    upb_source_a,
    upb_source_b,
    ABS(ISNULL(upb_source_a, 0) - ISNULL(upb_source_b, 0)) AS upb_variance,
    CASE
        WHEN ABS(ISNULL(upb_source_a, 0) - ISNULL(upb_source_b, 0)) > 0.01
        THEN 'UPB_MISMATCH'
        ELSE 'UPB_OK'
    END AS upb_recon_status,
    rate_source_a,
    rate_source_b,
    CASE
        WHEN ABS(ISNULL(rate_source_a, 0) - ISNULL(rate_source_b, 0)) > 0.001
        THEN 'RATE_MISMATCH'
        ELSE 'RATE_OK'
    END AS rate_recon_status,
    dlq_source_a,
    dlq_source_b,
    CASE
        WHEN ISNULL(dlq_source_a, '') <> ISNULL(dlq_source_b, '')
        THEN 'DLQ_MISMATCH'
        ELSE 'DLQ_OK'
    END AS dlq_recon_status
FROM matched_loans;
```

### Reconciliation Report Summary

```sql
-- Generate reconciliation summary
SELECT
    'Loan Count' AS metric,
    COUNT(CASE WHEN match_status = 'MATCHED' THEN 1 END) AS matched,
    COUNT(CASE WHEN match_status = 'IN_A_ONLY' THEN 1 END) AS source_a_only,
    COUNT(CASE WHEN match_status = 'IN_B_ONLY' THEN 1 END) AS source_b_only,
    COUNT(*) AS total
FROM matched_loans
UNION ALL
SELECT
    'Total UPB',
    SUM(CASE WHEN match_status = 'MATCHED' THEN upb_source_a END),
    SUM(CASE WHEN match_status = 'IN_A_ONLY' THEN upb_source_a END),
    SUM(CASE WHEN match_status = 'IN_B_ONLY' THEN upb_source_b END),
    SUM(COALESCE(upb_source_a, upb_source_b))
FROM matched_loans
UNION ALL
SELECT
    'UPB Mismatches (matched loans)',
    COUNT(CASE WHEN match_status = 'MATCHED'
                AND ABS(upb_source_a - upb_source_b) > 0.01 THEN 1 END),
    NULL, NULL,
    COUNT(CASE WHEN match_status = 'MATCHED' THEN 1 END)
FROM matched_loans;
```

---

## Field Mapping Across Vendors

### The Field Mapping Challenge

Every servicer, vendor, and agency uses different field names, codes, and formats for the same data. A data engineer must maintain mappings across all sources.

### Example: Delinquency Status Mapping

| Canonical Value | Servicer A | Servicer B | Fannie Mae | Freddie Mac | Ginnie Mae |
|----------------|------------|------------|------------|-------------|------------|
| Current | `0` | `CUR` | `0` | `0` | `C` |
| 30 DPD | `1` | `30` | `1` | `1` | `1` |
| 60 DPD | `2` | `60` | `2` | `2` | `2` |
| 90 DPD | `3` | `90` | `3` | `3` | `3` |
| 120+ DPD | `4` | `120` | `4` | `4` | `4` |
| Foreclosure | `F` | `FC` | `RA` | `F` | `F` |
| REO | `R` | `REO` | `09` | `R` | `R` |

### Metadata-Driven Mapping Framework

```sql
-- Master field mapping table
CREATE TABLE field_mapping (
    mapping_id          INT IDENTITY PRIMARY KEY,
    source_system       VARCHAR(50),        -- 'SERVICER_A', 'FNMA', 'FHLMC'
    source_field_name   VARCHAR(100),        -- Field name in source
    source_field_position INT,               -- For fixed-width files
    source_field_length INT,                 -- For fixed-width files
    target_field_name   VARCHAR(100),        -- Canonical field name
    data_type           VARCHAR(50),         -- Target data type
    transformation_rule VARCHAR(500),        -- SQL expression or function name
    is_required         BIT DEFAULT 0,
    default_value       VARCHAR(100),
    effective_date      DATE,
    expiration_date     DATE DEFAULT '9999-12-31'
);

-- Value mapping table (for code translations)
CREATE TABLE value_mapping (
    mapping_id          INT IDENTITY PRIMARY KEY,
    source_system       VARCHAR(50),
    field_name          VARCHAR(100),
    source_value        VARCHAR(100),
    target_value        VARCHAR(100),
    effective_date      DATE,
    expiration_date     DATE DEFAULT '9999-12-31'
);

-- Populate example mappings
INSERT INTO value_mapping (source_system, field_name, source_value, target_value, effective_date)
VALUES
-- Servicer A delinquency mapping
('SERVICER_A', 'delinquency_status', '0', 'Current', '2020-01-01'),
('SERVICER_A', 'delinquency_status', '1', '30 DPD', '2020-01-01'),
('SERVICER_A', 'delinquency_status', '2', '60 DPD', '2020-01-01'),
('SERVICER_A', 'delinquency_status', '3', '90 DPD', '2020-01-01'),
('SERVICER_A', 'delinquency_status', 'F', 'Foreclosure', '2020-01-01'),
('SERVICER_A', 'delinquency_status', 'R', 'REO', '2020-01-01'),
-- Servicer B delinquency mapping
('SERVICER_B', 'delinquency_status', 'CUR', 'Current', '2020-01-01'),
('SERVICER_B', 'delinquency_status', '30', '30 DPD', '2020-01-01'),
('SERVICER_B', 'delinquency_status', '60', '60 DPD', '2020-01-01'),
('SERVICER_B', 'delinquency_status', '90', '90 DPD', '2020-01-01'),
('SERVICER_B', 'delinquency_status', 'FC', 'Foreclosure', '2020-01-01'),
('SERVICER_B', 'delinquency_status', 'REO', 'REO', '2020-01-01');
```

### Dynamic Transformation Using Mappings

```sql
-- Generic transformation procedure using metadata-driven mappings
CREATE PROCEDURE usp_transform_tape
    @source_system VARCHAR(50),
    @reporting_period DATE
AS
BEGIN
    -- Build dynamic SQL from field mappings
    DECLARE @sql NVARCHAR(MAX);

    SELECT @sql = 'INSERT INTO xfm_loan_tape (' +
        STRING_AGG(target_field_name, ', ') + ')' +
        ' SELECT ' +
        STRING_AGG(
            CASE
                WHEN transformation_rule IS NOT NULL
                THEN transformation_rule
                ELSE 'CAST(' + source_field_name + ' AS ' + data_type + ')'
            END,
            ', '
        ) +
        ' FROM stg_' + LOWER(@source_system) + '_tape' +
        ' WHERE load_reporting_period = ''' + CAST(@reporting_period AS VARCHAR) + ''''
    FROM field_mapping
    WHERE source_system = @source_system
      AND @reporting_period BETWEEN effective_date AND expiration_date
    ORDER BY mapping_id;

    EXEC sp_executesql @sql;
END;
```

### Property Type Mapping Example

```sql
-- Property type varies widely across sources
INSERT INTO value_mapping (source_system, field_name, source_value, target_value, effective_date)
VALUES
('SERVICER_A', 'property_type', 'SF',    'Single Family',      '2020-01-01'),
('SERVICER_A', 'property_type', 'CO',    'Condo',              '2020-01-01'),
('SERVICER_A', 'property_type', 'PU',    'PUD',                '2020-01-01'),
('SERVICER_A', 'property_type', 'CP',    'Co-op',              '2020-01-01'),
('SERVICER_A', 'property_type', 'MH',    'Manufactured Home',  '2020-01-01'),
('SERVICER_B', 'property_type', '1',     'Single Family',      '2020-01-01'),
('SERVICER_B', 'property_type', '2',     'Condo',              '2020-01-01'),
('SERVICER_B', 'property_type', '3',     'PUD',                '2020-01-01'),
('SERVICER_B', 'property_type', '4',     'Co-op',              '2020-01-01'),
('SERVICER_B', 'property_type', '5',     'Manufactured Home',  '2020-01-01'),
('FNMA',       'property_type', 'SF',    'Single Family',      '2020-01-01'),
('FNMA',       'property_type', 'CO',    'Condo',              '2020-01-01'),
('FNMA',       'property_type', 'PU',    'PUD',                '2020-01-01'),
('FNMA',       'property_type', 'CP',    'Co-op',              '2020-01-01'),
('FNMA',       'property_type', 'MH',    'Manufactured Home',  '2020-01-01');
```

---

## Common Data Quality Issues

### Missing Values

| Field | Impact of Missing Data | Remediation Strategy |
|-------|----------------------|---------------------|
| Credit Score | Cannot stratify by FICO band; models may fail | Use co-borrower score; flag as "Not Available" |
| Property State | Cannot calculate geographic concentration | Cross-reference with ZIP code lookup |
| LTV | Cannot assess collateral risk | Calculate from loan amount / appraised value |
| Delinquency Status | Cannot determine portfolio health | Critical error -- reject record or escalate |
| Current UPB | Cannot calculate pool factor | Critical error -- must resolve before processing |

### Format Inconsistencies

```sql
-- Common format issues and fixes
-- Issue 1: Dates in multiple formats
SELECT
    loan_id,
    raw_date_field,
    CASE
        WHEN raw_date_field LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'
            THEN TRY_CONVERT(DATE, raw_date_field, 101)     -- MM/DD/YYYY
        WHEN raw_date_field LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
            THEN TRY_CONVERT(DATE, raw_date_field, 23)      -- YYYY-MM-DD
        WHEN raw_date_field LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
            THEN TRY_CONVERT(DATE, raw_date_field, 112)     -- YYYYMMDD
        WHEN raw_date_field LIKE '[0-9][0-9]/[0-9][0-9][0-9][0-9]'
            THEN TRY_CONVERT(DATE, raw_date_field + '/01', 101) -- MM/YYYY -> MM/01/YYYY
        ELSE NULL
    END AS parsed_date
FROM stg_loan_tape;

-- Issue 2: UPB with formatting characters
SELECT
    loan_id,
    raw_upb,
    TRY_CAST(
        REPLACE(REPLACE(REPLACE(raw_upb, '$', ''), ',', ''), ' ', '')
        AS DECIMAL(15,2)
    ) AS cleaned_upb
FROM stg_loan_tape;

-- Issue 3: Interest rate as percentage vs decimal
SELECT
    loan_id,
    raw_rate,
    CASE
        WHEN TRY_CAST(raw_rate AS DECIMAL(10,6)) > 1.0
        THEN TRY_CAST(raw_rate AS DECIMAL(10,6))           -- Already in percent form (3.75)
        WHEN TRY_CAST(raw_rate AS DECIMAL(10,6)) <= 1.0
        THEN TRY_CAST(raw_rate AS DECIMAL(10,6)) * 100     -- Decimal form (0.0375)
        ELSE NULL
    END AS normalized_rate
FROM stg_loan_tape;

-- Issue 4: State codes vs full names
SELECT
    loan_id,
    raw_state,
    COALESCE(
        CASE WHEN LEN(TRIM(raw_state)) = 2 THEN UPPER(TRIM(raw_state)) END,
        (SELECT state_code FROM ref_states WHERE state_name = TRIM(raw_state)),
        'XX'  -- Unknown
    ) AS state_code
FROM stg_loan_tape;
```

### Data Anomalies Specific to MBS

```sql
-- Anomaly 1: Zombie loans (zero UPB but still reported as active)
SELECT loan_id, reporting_period, current_upb, delinquency_status
FROM loan_tape
WHERE current_upb = 0
  AND delinquency_status NOT IN ('Paid Off', 'Liquidated', 'REO Disposition');

-- Anomaly 2: Negative amortization (UPB increased without modification)
SELECT
    curr.loan_id,
    curr.reporting_period,
    prev.current_upb AS prev_upb,
    curr.current_upb AS curr_upb,
    curr.current_upb - prev.current_upb AS upb_increase
FROM loan_tape curr
JOIN loan_tape prev
    ON curr.loan_id = prev.loan_id
    AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
WHERE curr.current_upb > prev.current_upb * 1.001  -- Allow rounding tolerance
  AND curr.modification_flag <> 'Y';

-- Anomaly 3: Delinquency status jumps (e.g., from Current to 90 DPD in one month)
SELECT
    curr.loan_id,
    curr.reporting_period,
    prev.months_delinquent AS prev_months_dlq,
    curr.months_delinquent AS curr_months_dlq
FROM loan_tape curr
JOIN loan_tape prev
    ON curr.loan_id = prev.loan_id
    AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
WHERE curr.months_delinquent > prev.months_delinquent + 1;

-- Anomaly 4: Rate changes on fixed-rate loans
SELECT
    curr.loan_id,
    curr.reporting_period,
    prev.interest_rate AS prev_rate,
    curr.interest_rate AS curr_rate
FROM loan_tape curr
JOIN loan_tape prev
    ON curr.loan_id = prev.loan_id
    AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
JOIN dim_product p ON curr.product_key = p.product_key
WHERE p.rate_type = 'Fixed'
  AND curr.interest_rate <> prev.interest_rate
  AND curr.modification_flag <> 'Y';
```

---

## UPB Reconciliation

### Why UPB Reconciliation Is Critical

The Unpaid Principal Balance is the single most important financial field in any loan tape. UPB drives:
- Pool factor calculations (remaining UPB / original UPB)
- Investor cash flow distribution
- Pricing of MBS trades
- Regulatory capital calculations
- Portfolio risk metrics

A UPB error, even small, can cascade through downstream calculations and reports.

### Loan-Level UPB Reconciliation

```sql
-- Reconcile UPB between servicer tape and trustee report
CREATE PROCEDURE usp_reconcile_upb
    @reporting_period DATE
AS
BEGIN
    -- Loan-level comparison
    INSERT INTO recon_upb_detail (
        loan_id, reporting_period,
        servicer_upb, trustee_upb, variance,
        variance_pct, recon_status
    )
    SELECT
        COALESCE(s.loan_id, t.loan_id) AS loan_id,
        @reporting_period,
        s.current_upb AS servicer_upb,
        t.current_upb AS trustee_upb,
        ISNULL(s.current_upb, 0) - ISNULL(t.current_upb, 0) AS variance,
        CASE
            WHEN t.current_upb > 0
            THEN (ISNULL(s.current_upb, 0) - t.current_upb) / t.current_upb * 100
            ELSE NULL
        END AS variance_pct,
        CASE
            WHEN s.loan_id IS NULL THEN 'MISSING_IN_SERVICER'
            WHEN t.loan_id IS NULL THEN 'MISSING_IN_TRUSTEE'
            WHEN ABS(s.current_upb - t.current_upb) <= 0.01 THEN 'MATCHED'
            WHEN ABS(s.current_upb - t.current_upb) <= 1.00 THEN 'ROUNDING_DIFF'
            ELSE 'MATERIAL_VARIANCE'
        END AS recon_status
    FROM servicer_tape s
    FULL OUTER JOIN trustee_report t
        ON s.loan_id = t.loan_id
    WHERE s.reporting_period = @reporting_period
       OR t.reporting_period = @reporting_period;

    -- Pool-level summary
    INSERT INTO recon_upb_summary (
        pool_id, reporting_period,
        servicer_loan_count, trustee_loan_count, count_variance,
        servicer_total_upb, trustee_total_upb, upb_variance,
        upb_variance_pct, recon_status
    )
    SELECT
        pool_id,
        @reporting_period,
        COUNT(CASE WHEN servicer_upb IS NOT NULL THEN 1 END),
        COUNT(CASE WHEN trustee_upb IS NOT NULL THEN 1 END),
        COUNT(CASE WHEN servicer_upb IS NOT NULL THEN 1 END)
            - COUNT(CASE WHEN trustee_upb IS NOT NULL THEN 1 END),
        SUM(ISNULL(servicer_upb, 0)),
        SUM(ISNULL(trustee_upb, 0)),
        SUM(ISNULL(servicer_upb, 0)) - SUM(ISNULL(trustee_upb, 0)),
        (SUM(ISNULL(servicer_upb, 0)) - SUM(ISNULL(trustee_upb, 0)))
            / NULLIF(SUM(ISNULL(trustee_upb, 0)), 0) * 100,
        CASE
            WHEN ABS(SUM(ISNULL(servicer_upb, 0)) - SUM(ISNULL(trustee_upb, 0)))
                / NULLIF(SUM(ISNULL(trustee_upb, 0)), 0) <= 0.0001
            THEN 'CLEAN'
            WHEN ABS(SUM(ISNULL(servicer_upb, 0)) - SUM(ISNULL(trustee_upb, 0)))
                / NULLIF(SUM(ISNULL(trustee_upb, 0)), 0) <= 0.001
            THEN 'MINOR_VARIANCE'
            ELSE 'MATERIAL_VARIANCE'
        END
    FROM recon_upb_detail
    WHERE reporting_period = @reporting_period
    GROUP BY pool_id;
END;
```

### Month-Over-Month UPB Roll-Forward

```sql
-- Verify that beginning UPB + activity = ending UPB
SELECT
    loan_id,
    reporting_period,
    prior_upb,
    scheduled_principal,
    curtailment_amount,
    prepayment_amount,
    loss_amount,
    modification_upb_change,
    current_upb AS reported_ending_upb,
    prior_upb
        - scheduled_principal
        - ISNULL(curtailment_amount, 0)
        - ISNULL(prepayment_amount, 0)
        - ISNULL(loss_amount, 0)
        + ISNULL(modification_upb_change, 0)
    AS calculated_ending_upb,
    current_upb - (
        prior_upb
        - scheduled_principal
        - ISNULL(curtailment_amount, 0)
        - ISNULL(prepayment_amount, 0)
        - ISNULL(loss_amount, 0)
        + ISNULL(modification_upb_change, 0)
    ) AS roll_forward_variance
FROM (
    SELECT
        curr.loan_id,
        curr.reporting_period,
        prev.current_upb AS prior_upb,
        curr.scheduled_principal,
        curr.curtailment_amount,
        curr.prepayment_amount,
        curr.loss_amount,
        curr.modification_upb_change,
        curr.current_upb
    FROM loan_tape curr
    JOIN loan_tape prev
        ON curr.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
) roll
WHERE ABS(current_upb - (
    prior_upb
    - scheduled_principal
    - ISNULL(curtailment_amount, 0)
    - ISNULL(prepayment_amount, 0)
    - ISNULL(loss_amount, 0)
    + ISNULL(modification_upb_change, 0)
)) > 0.01;
```

---

## Loan Count Reconciliation

### Why Loan Counts Matter

Loan count reconciliation ensures no loans are missing or duplicated. Even small discrepancies can indicate:
- Loans dropped during ETL processing
- Duplicate records from file resubmission
- Loans incorrectly excluded by filter logic
- Timing differences (loan terminated in one system but not yet reflected in another)

### Loan Count Reconciliation Queries

```sql
-- Reconcile loan counts across three sources
SELECT
    'Agency Disclosure' AS source,
    COUNT(DISTINCT loan_id) AS loan_count,
    SUM(current_upb) AS total_upb
FROM agency_disclosure
WHERE reporting_period = @period

UNION ALL

SELECT
    'Servicer Tape' AS source,
    COUNT(DISTINCT loan_id) AS loan_count,
    SUM(current_upb) AS total_upb
FROM servicer_tape_consolidated
WHERE reporting_period = @period

UNION ALL

SELECT
    'Internal Database' AS source,
    COUNT(DISTINCT loan_id) AS loan_count,
    SUM(current_upb) AS total_upb
FROM fact_loan_performance
WHERE reporting_period = @period;

-- Find orphan loans (in one source but not another)
SELECT
    a.loan_id AS agency_loan_id,
    s.loan_id AS servicer_loan_id,
    CASE
        WHEN a.loan_id IS NULL THEN 'Missing from Agency'
        WHEN s.loan_id IS NULL THEN 'Missing from Servicer'
    END AS discrepancy_type
FROM agency_disclosure a
FULL OUTER JOIN servicer_tape_consolidated s
    ON a.loan_id = s.loan_id
    AND a.reporting_period = s.reporting_period
WHERE (a.loan_id IS NULL OR s.loan_id IS NULL)
  AND COALESCE(a.reporting_period, s.reporting_period) = @period;
```

### Tracking Loan Population Changes

```sql
-- Month-over-month loan population analysis
WITH curr AS (
    SELECT DISTINCT loan_id
    FROM loan_tape
    WHERE reporting_period = @current_period
),
prev AS (
    SELECT DISTINCT loan_id
    FROM loan_tape
    WHERE reporting_period = DATEADD(MONTH, -1, @current_period)
)
SELECT
    'Continuing loans'  AS category,
    COUNT(*) AS loan_count
FROM curr c JOIN prev p ON c.loan_id = p.loan_id

UNION ALL

SELECT
    'New loans (additions)',
    COUNT(*)
FROM curr c
LEFT JOIN prev p ON c.loan_id = p.loan_id
WHERE p.loan_id IS NULL

UNION ALL

SELECT
    'Terminated loans (removals)',
    COUNT(*)
FROM prev p
LEFT JOIN curr c ON p.loan_id = c.loan_id
WHERE c.loan_id IS NULL;
```

---

## Automated Validation Frameworks

### Framework Architecture

```
+------------------+     +-------------------+     +------------------+
|  Validation      |     |  Execution        |     |  Reporting       |
|  Rules Config    |---->|  Engine           |---->|  & Alerting      |
+------------------+     +-------------------+     +------------------+
|                  |     |                   |     |                  |
| Rule definitions |     | Run rules against |     | Dashboard        |
| Thresholds       |     | staged data       |     | Email alerts     |
| Severity levels  |     | Log results       |     | Slack/Teams      |
| Scope (loan/pool)|     | Apply dispositions|     | Audit reports    |
+------------------+     +-------------------+     +------------------+
```

### Rule Configuration

```sql
CREATE TABLE validation_rule_config (
    rule_id             INT IDENTITY PRIMARY KEY,
    rule_name           VARCHAR(100) NOT NULL,
    rule_description    VARCHAR(500),
    rule_category       VARCHAR(50),         -- COMPLETENESS, ACCURACY, CONSISTENCY, TIMELINESS
    rule_type           VARCHAR(30),         -- FIELD_LEVEL, RECORD_LEVEL, AGGREGATE, CROSS_SOURCE
    target_table        VARCHAR(100),
    rule_sql            NVARCHAR(MAX),       -- SQL that returns failing records
    severity            VARCHAR(10),         -- CRITICAL, HIGH, MEDIUM, LOW
    threshold_type      VARCHAR(20),         -- COUNT, PERCENTAGE, AMOUNT
    threshold_value     DECIMAL(15,4),       -- Max acceptable failures
    is_blocking         BIT DEFAULT 0,       -- If TRUE, blocks pipeline progression
    is_active           BIT DEFAULT 1,
    owner               VARCHAR(100),
    created_date        DATE DEFAULT GETDATE(),
    modified_date       DATE
);

-- Example rules
INSERT INTO validation_rule_config
(rule_name, rule_category, rule_type, target_table, rule_sql, severity, threshold_type, threshold_value, is_blocking)
VALUES
-- Critical: No null UPB for active loans
('UPB_NOT_NULL', 'COMPLETENESS', 'FIELD_LEVEL', 'stg_loan_tape',
 'SELECT loan_id, reporting_period FROM stg_loan_tape WHERE current_upb IS NULL AND payment_status NOT IN (''Paid Off'', ''Liquidated'')',
 'CRITICAL', 'COUNT', 0, 1),

-- Critical: Pool-level UPB within tolerance
('POOL_UPB_TOLERANCE', 'ACCURACY', 'AGGREGATE', 'stg_loan_tape',
 'SELECT pool_id, ABS(SUM(current_upb) - expected_upb) / expected_upb AS variance_pct FROM stg_loan_tape t JOIN ref_pool_factors p ON t.pool_id = p.pool_id GROUP BY pool_id, expected_upb HAVING ABS(SUM(current_upb) - expected_upb) / expected_upb > 0.001',
 'CRITICAL', 'COUNT', 0, 1),

-- High: Credit score in valid range
('FICO_RANGE', 'ACCURACY', 'FIELD_LEVEL', 'stg_loan_tape',
 'SELECT loan_id FROM stg_loan_tape WHERE credit_score NOT BETWEEN 300 AND 850 AND credit_score IS NOT NULL',
 'HIGH', 'PERCENTAGE', 1.0, 0),

-- Medium: Rate consistency for fixed-rate loans
('FIXED_RATE_STABLE', 'CONSISTENCY', 'RECORD_LEVEL', 'stg_loan_tape',
 'SELECT c.loan_id FROM stg_loan_tape c JOIN fact_loan_performance p ON c.loan_id = p.loan_id AND p.reporting_period = DATEADD(MONTH, -1, c.reporting_period) WHERE c.product_type = ''Fixed'' AND c.interest_rate <> p.current_interest_rate AND c.modification_flag <> ''Y''',
 'MEDIUM', 'COUNT', 100, 0);
```

### Validation Execution Engine

```sql
-- Stored procedure to execute all active validation rules
CREATE PROCEDURE usp_execute_validation_rules
    @pipeline_run_id BIGINT,
    @reporting_period DATE
AS
BEGIN
    DECLARE @rule_id INT, @rule_sql NVARCHAR(MAX), @severity VARCHAR(10);
    DECLARE @is_blocking BIT, @threshold_type VARCHAR(20), @threshold_value DECIMAL(15,4);
    DECLARE @fail_count INT, @total_count INT, @has_blocking_failure BIT = 0;

    DECLARE rule_cursor CURSOR FOR
        SELECT rule_id, rule_sql, severity, is_blocking, threshold_type, threshold_value
        FROM validation_rule_config
        WHERE is_active = 1
        ORDER BY
            CASE severity
                WHEN 'CRITICAL' THEN 1
                WHEN 'HIGH' THEN 2
                WHEN 'MEDIUM' THEN 3
                WHEN 'LOW' THEN 4
            END;

    OPEN rule_cursor;
    FETCH NEXT FROM rule_cursor INTO @rule_id, @rule_sql, @severity, @is_blocking,
                                      @threshold_type, @threshold_value;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Execute the rule and count failures
        DECLARE @count_sql NVARCHAR(MAX) =
            N'SELECT @cnt = COUNT(*) FROM (' + @rule_sql + N') sub';

        EXEC sp_executesql @count_sql, N'@cnt INT OUTPUT', @cnt = @fail_count OUTPUT;

        -- Log result
        INSERT INTO validation_run_results (
            pipeline_run_id, rule_id, reporting_period,
            fail_count, execution_timestamp,
            pass_fail, notes
        )
        VALUES (
            @pipeline_run_id, @rule_id, @reporting_period,
            @fail_count, GETDATE(),
            CASE WHEN @fail_count <= @threshold_value THEN 'PASS' ELSE 'FAIL' END,
            CASE WHEN @fail_count > @threshold_value
                 THEN CAST(@fail_count AS VARCHAR) + ' records failed (threshold: '
                      + CAST(@threshold_value AS VARCHAR) + ')'
                 ELSE 'All records passed'
            END
        );

        -- Check for blocking failures
        IF @is_blocking = 1 AND @fail_count > @threshold_value
            SET @has_blocking_failure = 1;

        FETCH NEXT FROM rule_cursor INTO @rule_id, @rule_sql, @severity, @is_blocking,
                                          @threshold_type, @threshold_value;
    END;

    CLOSE rule_cursor;
    DEALLOCATE rule_cursor;

    -- Return overall status
    IF @has_blocking_failure = 1
        THROW 50001, 'Pipeline blocked: Critical validation failures detected.', 1;
END;
```

### dbt-Based Validation Framework

```yaml
# schema.yml - dbt test definitions for loan tape validation
version: 2

models:
  - name: stg_loan_tape
    description: Staged raw loan tape data
    columns:
      - name: loan_id
        tests:
          - not_null
          - unique:
              config:
                severity: error
      - name: current_upb
        tests:
          - not_null:
              where: "payment_status NOT IN ('Paid Off', 'Liquidated')"
              config:
                severity: error
          - dbt_utils.accepted_range:
              min_value: 0
              max_value: 5000000
              config:
                severity: warn
      - name: interest_rate
        tests:
          - dbt_utils.accepted_range:
              min_value: 0
              max_value: 15
              config:
                severity: warn
      - name: credit_score
        tests:
          - dbt_utils.accepted_range:
              min_value: 300
              max_value: 850
              config:
                severity: warn
                where: "credit_score IS NOT NULL"
      - name: property_state
        tests:
          - accepted_values:
              values: ['AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA',
                       'HI','ID','IL','IN','IA','KS','KY','LA','ME','MD',
                       'MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ',
                       'NM','NY','NC','ND','OH','OK','OR','PA','RI','SC',
                       'SD','TN','TX','UT','VT','VA','WA','WV','WI','WY',
                       'DC','PR','GU','VI']
              config:
                severity: warn
```

---

## Real-World Examples

### Example 1: Onboarding a New Servicer

A loan aggregator acquires servicing rights from a new servicer. The data engineering team must:

1. **Obtain the data dictionary**: Request the servicer's tape layout documentation. Review field definitions, data types, code values, and file format.

2. **Create field mappings**: Map every source field to the canonical schema. Document transformation rules (e.g., "Servicer reports rate as decimal 0.0375; multiply by 100 to get 3.75%").

3. **Build the staging layer**: Create a new staging table matching the servicer's exact format. Load the first tape in VARCHAR-only mode.

4. **Validate against known data**: If the acquired portfolio was previously tracked by another servicer, reconcile the new tape against the last tape from the old servicer. Expect minor differences due to timing but flag any material UPB or loan count discrepancies.

5. **Run parallel processing**: Process 2-3 months in parallel with manual review before moving to automated production processing.

6. **Document and monitor**: Add the new servicer to the monitoring dashboard with tape arrival SLAs and validation thresholds.

### Example 2: Securitization Data Room Preparation

An originator is preparing to securitize a pool of 5,000 loans. The data engineering team must produce the due diligence tape:

1. **Extract from LOS**: Pull origination data from the Loan Origination System for the proposed pool
2. **Enrich with servicing data**: Join current performance data from the servicing system
3. **Validate completeness**: Ensure all 120+ required fields are populated per rating agency requirements
4. **Run compliance checks**: Verify TRID, ATR/QM, and state-specific compliance flags
5. **Cross-reference with collateral**: Match against title company data, appraisal data, and MI certificates
6. **Generate the tape**: Output in the specified format (usually Excel with multiple tabs or MISMO XML)
7. **Reconcile counts**: Confirm the tape contains exactly 5,000 loans with aggregate UPB matching the proposed deal size

---

## Common Interview Questions

### Q1: What is a loan tape and why is it important in the secondary market?

**Answer**: A loan tape is a structured dataset containing detailed loan-level information for a portfolio of residential mortgages. It includes origination attributes (loan amount, rate, FICO, LTV, property details), current performance data (UPB, delinquency status, payment history), and collateral information.

Loan tapes are the primary mechanism for data exchange in the secondary market. They are used in securitization (for rating agencies and due diligence firms), whole loan trading (for pricing), investor reporting (monthly performance to trustees and bondholders), and regulatory compliance (SEC Reg AB II disclosures). The accuracy and completeness of a loan tape directly affects pricing, risk assessment, and regulatory compliance. A single error -- such as incorrect UPB totals -- can lead to mispriced trades, incorrect pool factor publications, or regulatory findings.

### Q2: How would you handle receiving loan tapes from 20 different servicers, each in a different format?

**Answer**: I would implement a metadata-driven normalization framework:

1. **Field mapping registry**: Maintain a database table mapping each servicer's field names, positions, and data types to a canonical schema. Each servicer gets its own mapping record set, versioned with effective dates to handle format changes over time.

2. **Value translation tables**: Store code translations (e.g., Servicer A uses "SF" for single family, Servicer B uses "1") in a separate value mapping table.

3. **Generic parser**: Build a parameterized ingestion module that reads the mapping for a given servicer and dynamically parses the file -- extracting fields by name (CSV/pipe-delimited) or position (fixed-width).

4. **Servicer-specific staging**: Each servicer gets its own staging table matching their exact layout. Raw data is loaded as-is in VARCHAR columns.

5. **Unified transformation**: A transformation layer reads from each staging table, applies the field and value mappings, and writes to a single canonical target table.

6. **Onboarding process**: When a new servicer is added, the team creates the mapping configuration and validates it against a sample tape. No code changes are required -- only configuration.

This approach scales efficiently because adding a new servicer is a configuration task, not a development project.

### Q3: Explain UPB reconciliation. Why is it critical and how would you implement it?

**Answer**: UPB reconciliation is the process of verifying that the total Unpaid Principal Balance calculated from loan-level data matches an independent control total -- typically from a trustee report, agency factor file, or prior month's data plus activity.

It is critical because UPB is the basis for pool factor calculations (which determine investor cash flows), MBS pricing, and regulatory capital requirements. A UPB error that propagates to a published pool factor can affect every investor holding that security.

I implement UPB reconciliation at three levels:

**Loan-level**: Full outer join between servicer tape and trustee report on loan ID. Flag loans missing from either source and loans where UPB differs beyond a tolerance (typically $0.01 for rounding).

**Pool-level**: Sum loan-level UPB from the servicer tape and compare to the published pool factor times original face. The variance should be within 0.01% (1 basis point).

**Roll-forward**: Beginning UPB minus scheduled principal, curtailments, prepayments, and losses (plus any modification increases) should equal ending UPB. Any variance indicates missing activity or incorrect calculations.

Results are logged to a reconciliation table with timestamps and dispositions. Material variances (above threshold) trigger alerts and block downstream processing until resolved.

### Q4: What are the most common data quality issues you encounter in loan tapes, and how do you handle them?

**Answer**: The most common issues I have encountered:

1. **Missing critical fields**: Null UPB, missing credit scores, blank state codes. I handle these with tiered rules -- null UPB on an active loan is a blocking error (halt processing), while a missing credit score is a warning (flag and continue, assign "Not Available" code).

2. **Format inconsistencies**: Dates in MM/DD/YYYY vs. YYYY-MM-DD, rates as percentages vs. decimals, UPB with or without currency formatting. I implement format detection and normalization in the transformation layer, with explicit parsing logic for each known pattern.

3. **Stale data**: Servicer submits last month's data again, or fails to update terminated loans. I detect this by comparing the tape's reporting date and key metrics against the prior month -- if 99%+ of UPB values are identical, the tape is likely stale.

4. **Duplicate records**: Same loan appearing multiple times. I implement deduplication using business rules (keep the record with the most recent activity date, or the highest UPB if the loan was paid down mid-month).

5. **Inconsistent coding**: Different servicers using different codes for the same concept (especially delinquency status, property type, and loan purpose). I maintain a comprehensive value mapping table with versioning.

6. **Temporal anomalies**: Delinquency status jumping from current to 90+ DPD in one month, or loan age not incrementing. I flag these with cross-record validation rules and route to a data quality review queue.

### Q5: How would you build an automated tape validation framework?

**Answer**: I would build a rule-based validation engine with four components:

**Rule configuration**: A database table defining each validation rule with its SQL logic, severity level, failure threshold, and whether it is a blocking rule. Rules are categorized as completeness (are required fields populated?), accuracy (are values in valid ranges?), consistency (does the data agree across fields and time periods?), and timeliness (is the data for the expected period?).

**Execution engine**: A stored procedure or Python module that iterates through active rules, executes each against the staged data, counts failures, and logs results to a run history table. Blocking rules that exceed their threshold raise an exception to halt the pipeline.

**Reporting layer**: A dashboard showing rule pass/fail rates over time, trending data quality scores by servicer, and drill-down capability to see specific failing records. Alerts go to the data quality team via email or Slack when failures exceed thresholds.

**Feedback loop**: A workflow for the data quality team to investigate failures, classify them (data issue vs. rule issue), and either request corrections from the servicer or update the validation rules. All dispositions are tracked for audit.

This framework is extensible -- adding a new rule requires only an INSERT into the configuration table. It is also self-monitoring -- if a rule suddenly starts failing for all servicers, it likely indicates a rule change is needed rather than a universal data problem.

---

## Tips

1. **Never trust the header**: Always validate that the file contents match the expected layout. Servicers occasionally change formats without notice. Check column counts, sample a few records, and compare against the registered schema before full ingestion.

2. **Store raw tapes permanently**: Retain the original files (or at least a copy in staging) for at least 7 years for regulatory compliance. You will need to reprocess from raw data when business rules change or disputes arise.

3. **Build reconciliation into the pipeline, not after it**: Reconciliation should be an automated step that runs as part of the ETL pipeline, not a manual exercise performed days later. Make it a gate -- if reconciliation fails, downstream processing stops.

4. **Version your mappings**: When a servicer changes their tape format, do not overwrite the old mapping. Create a new version with an effective date. This ensures you can reprocess historical tapes using the correct mapping for that period.

5. **Create a "data quality score" per servicer**: Track validation pass rates over time by servicer. This provides objective evidence when you need to escalate data quality issues to business stakeholders or push back on a servicer.

6. **Handle the "tape of tapes" problem**: When consolidating data from multiple servicers, be aware that the same loan may appear in tapes from both the prior servicer (as terminated) and the new servicer (as boarded). Build deduplication logic that handles the transition period.

7. **Document every field mapping decision**: When a source field is ambiguous (e.g., does "balance" mean current UPB or scheduled UPB?), document your interpretation and the source of truth. This prevents rework when different team members make different assumptions.

8. **Automate file arrival monitoring**: Do not wait for someone to notice a tape is missing. Implement file sensors that alert the team if a servicer's tape has not arrived by the expected date.

9. **Test reconciliation with known discrepancies**: Intentionally introduce controlled errors into test data to verify your reconciliation logic catches them. This is particularly important for edge cases like zero-UPB loans, newly boarded loans, and mid-month payoffs.

10. **Understand the business context of every field**: A field labeled "interest_rate" might be the note rate, the net rate (after servicing fee), or the pass-through rate. Understanding the business meaning prevents subtle but costly mapping errors.
