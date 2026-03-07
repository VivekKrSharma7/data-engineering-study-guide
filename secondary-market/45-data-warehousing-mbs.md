# Data Warehousing for MBS Analytics

[Back to Secondary Market Index](./README.md)

---

## Table of Contents

1. [Key Concepts](#key-concepts)
2. [Dimensional Modeling for MBS Data](#dimensional-modeling-for-mbs-data)
3. [Star Schema Design](#star-schema-design)
4. [Dimension Tables](#dimension-tables)
5. [Slowly Changing Dimensions](#slowly-changing-dimensions)
6. [Aggregate Tables](#aggregate-tables)
7. [Materialized Views for Analytics](#materialized-views-for-analytics)
8. [Partitioning Strategies](#partitioning-strategies)
9. [Performance Optimization](#performance-optimization)
10. [Real-World Examples](#real-world-examples)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## Key Concepts

### Why Data Warehousing Matters for MBS

Mortgage-Backed Securities generate enormous volumes of structured data -- loan origination attributes, monthly performance snapshots, deal structures, cash flow waterfalls, and market prices. A well-designed data warehouse enables:

- **Portfolio analytics**: Aggregate loan-level data to understand risk exposure by geography, vintage, product type, or servicer
- **Performance surveillance**: Track delinquency, prepayment, and loss trends across pools and deals
- **Regulatory reporting**: Produce accurate, auditable reports for SEC, FHFA, and other regulators
- **Investment decisions**: Enable traders and portfolio managers to query historical performance efficiently
- **Risk modeling**: Provide clean, consistent data for prepayment, default, and loss severity models

### Data Warehouse vs. Operational Systems

In MBS operations, loan servicing systems (e.g., Black Knight MSP, ICE Mortgage Technology) are optimized for transactional processing -- individual loan lookups, payment posting, and escrow management. The data warehouse, by contrast, is optimized for analytical queries across millions of loans, spanning years of history.

### Kimball vs. Inmon in MBS Context

**Kimball (Dimensional Modeling)**: Star schemas with denormalized dimensions. Best for MBS analytics where users query by common dimensions (date, geography, product) and need fast aggregation. This is the dominant approach in MBS data warehousing.

**Inmon (Enterprise Data Warehouse)**: Normalized 3NF model feeding departmental data marts. More appropriate when the same loan data serves multiple, very different business functions (servicing, securitization, compliance) with distinct transformation requirements.

In practice, most MBS data warehouses use a hybrid: a normalized staging/integration layer (ODS) feeding Kimball-style dimensional marts for analytics.

---

## Dimensional Modeling for MBS Data

### Identifying the Business Processes

| Business Process | Grain | Key Facts | Key Dimensions |
|-----------------|-------|-----------|----------------|
| **Loan Origination** | One row per loan at origination | Original UPB, original rate, LTV, DTI, FICO | Date, geography, product, originator, property |
| **Monthly Performance** | One row per loan per month | Current UPB, delinquency status, payment amount | Date, loan, geography, servicer, product |
| **Prepayment** | One row per prepayment event | SMM, CPR, curtailment amount, payoff amount | Date, loan, pool, vintage |
| **Default/Loss** | One row per default event | Default UPB, loss amount, loss severity | Date, loan, geography, product, servicer |
| **Deal Cash Flow** | One row per tranche per payment date | Principal distribution, interest distribution | Date, deal, tranche, waterfall step |
| **Pool Factor** | One row per pool per month | Pool factor, remaining UPB, WAC, WAM | Date, pool, agency |

### The Grain Decision

The grain is the most critical design decision. For MBS analytics, the most common grain is **one row per loan per reporting period** (the monthly snapshot). This grain supports virtually all analytical queries:

- Point-in-time portfolio snapshots
- Transition matrices (delinquency migration)
- Cohort/vintage analysis
- Survival analysis
- Trend analysis

---

## Star Schema Design

### Loan Performance Fact Table

```sql
CREATE TABLE fact_loan_performance (
    loan_performance_key    BIGINT IDENTITY PRIMARY KEY,
    -- Foreign keys to dimensions
    date_key                INT NOT NULL,           -- FK to dim_date
    loan_key                INT NOT NULL,           -- FK to dim_loan
    geography_key           INT NOT NULL,           -- FK to dim_geography
    product_key             INT NOT NULL,           -- FK to dim_product
    servicer_key            INT NOT NULL,           -- FK to dim_servicer
    pool_key                INT NOT NULL,           -- FK to dim_pool
    -- Degenerate dimensions
    reporting_period        DATE NOT NULL,
    -- Measures (facts)
    current_upb             DECIMAL(15,2),
    scheduled_upb           DECIMAL(15,2),
    current_interest_rate   DECIMAL(6,3),
    monthly_pi_payment      DECIMAL(12,2),
    principal_paid          DECIMAL(12,2),
    interest_paid           DECIMAL(12,2),
    curtailment_amount      DECIMAL(12,2),
    prepayment_amount       DECIMAL(12,2),
    escrow_balance          DECIMAL(12,2),
    -- Delinquency measures
    months_delinquent       SMALLINT,
    days_past_due           INT,
    delinquency_status      VARCHAR(10),            -- Current, 30, 60, 90, 120+, FC, REO
    -- Age and term
    loan_age                SMALLINT,
    remaining_term          SMALLINT,
    -- Flags
    modification_flag       BIT DEFAULT 0,
    forbearance_flag        BIT DEFAULT 0,
    bankruptcy_flag         BIT DEFAULT 0,
    -- Metadata
    etl_load_date           DATETIME DEFAULT GETDATE(),
    source_system           VARCHAR(20),
    -- Composite index for common access patterns
    INDEX ix_loan_period (loan_key, reporting_period),
    INDEX ix_date_product (date_key, product_key),
    INDEX ix_servicer_date (servicer_key, date_key)
);
```

### Deal Cash Flow Fact Table

```sql
CREATE TABLE fact_deal_cashflow (
    cashflow_key            BIGINT IDENTITY PRIMARY KEY,
    -- Foreign keys
    date_key                INT NOT NULL,
    deal_key                INT NOT NULL,           -- FK to dim_deal
    tranche_key             INT NOT NULL,           -- FK to dim_tranche
    -- Measures
    beginning_balance       DECIMAL(18,2),
    principal_distributed   DECIMAL(18,2),
    interest_distributed    DECIMAL(18,2),
    loss_allocated          DECIMAL(18,2),
    ending_balance          DECIMAL(18,2),
    tranche_factor          DECIMAL(12,10),
    coupon_rate             DECIMAL(6,3),
    -- Overcollateralization / credit enhancement
    credit_support          DECIMAL(8,4),
    -- Metadata
    reporting_period        DATE,
    etl_load_date           DATETIME DEFAULT GETDATE()
);
```

### Pool Factor Fact Table

```sql
CREATE TABLE fact_pool_factor (
    pool_factor_key         BIGINT IDENTITY PRIMARY KEY,
    date_key                INT NOT NULL,
    pool_key                INT NOT NULL,
    -- Measures
    pool_factor             DECIMAL(12,10),
    remaining_upb           DECIMAL(18,2),
    original_upb            DECIMAL(18,2),
    active_loan_count       INT,
    wac                     DECIMAL(6,3),           -- Weighted Average Coupon
    wam                     INT,                     -- Weighted Average Maturity
    wala                    INT,                     -- Weighted Average Loan Age
    avg_fico                DECIMAL(6,1),
    avg_ltv                 DECIMAL(6,2),
    -- Performance metrics
    cpr_1m                  DECIMAL(8,4),            -- 1-month CPR
    cpr_3m                  DECIMAL(8,4),            -- 3-month CPR
    cdr_1m                  DECIMAL(8,4),            -- 1-month CDR
    severity                DECIMAL(8,4),
    -- Delinquency distribution
    pct_current             DECIMAL(8,4),
    pct_30dpd               DECIMAL(8,4),
    pct_60dpd               DECIMAL(8,4),
    pct_90plus_dpd          DECIMAL(8,4),
    pct_foreclosure         DECIMAL(8,4),
    pct_reo                 DECIMAL(8,4),
    -- Metadata
    reporting_period        DATE,
    etl_load_date           DATETIME DEFAULT GETDATE()
);
```

---

## Dimension Tables

### Date Dimension

```sql
CREATE TABLE dim_date (
    date_key                INT PRIMARY KEY,         -- YYYYMMDD format
    full_date               DATE NOT NULL,
    calendar_year           SMALLINT,
    calendar_quarter        TINYINT,
    calendar_month          TINYINT,
    calendar_month_name     VARCHAR(15),
    day_of_month            TINYINT,
    day_of_week             TINYINT,
    day_name                VARCHAR(10),
    is_business_day         BIT,
    is_month_end            BIT,
    is_quarter_end          BIT,
    is_year_end             BIT,
    -- MBS-specific date attributes
    is_factor_date          BIT,                     -- Pool factor publication dates
    is_remittance_date      BIT,                     -- Monthly remittance dates
    is_settlement_date      BIT,                     -- TBA settlement dates
    reporting_period        DATE,                    -- First of month for the reporting cycle
    fiscal_year             SMALLINT,
    fiscal_quarter          TINYINT
);
```

### Geography Dimension

```sql
CREATE TABLE dim_geography (
    geography_key           INT IDENTITY PRIMARY KEY,
    state_code              CHAR(2),
    state_name              VARCHAR(50),
    county_name             VARCHAR(100),
    county_fips             CHAR(5),
    cbsa_code               VARCHAR(10),
    cbsa_name               VARCHAR(200),
    metro_division          VARCHAR(200),
    census_region           VARCHAR(20),             -- Northeast, Midwest, South, West
    census_division         VARCHAR(30),
    zip_code_3digit         CHAR(3),
    -- Housing market indicators (updated periodically)
    hpi_index_value         DECIMAL(10,2),
    hpi_as_of_date          DATE,
    judicial_foreclosure    BIT,                     -- Judicial vs non-judicial state
    -- Flood/disaster zone indicators
    fema_disaster_area      BIT,
    fema_disaster_date      DATE
);
```

### Product Dimension

```sql
CREATE TABLE dim_product (
    product_key             INT IDENTITY PRIMARY KEY,
    product_type            VARCHAR(50),             -- Fixed, ARM, Hybrid ARM, IO, Balloon
    amortization_type       VARCHAR(30),             -- Fully Amortizing, IO, Neg Am
    rate_type               VARCHAR(20),             -- Fixed, Adjustable
    loan_purpose            VARCHAR(30),             -- Purchase, Rate/Term Refi, Cash-Out Refi
    occupancy_type          VARCHAR(20),             -- Primary, Second Home, Investment
    property_type           VARCHAR(30),             -- SFR, Condo, Co-op, PUD, MH, 2-4 Unit
    channel                 VARCHAR(20),             -- Retail, Wholesale, Correspondent
    lien_position           VARCHAR(10),             -- First, Second
    original_term_bucket    VARCHAR(20),             -- 10yr, 15yr, 20yr, 30yr, 40yr
    -- Government program flags
    is_fha                  BIT DEFAULT 0,
    is_va                   BIT DEFAULT 0,
    is_usda                 BIT DEFAULT 0,
    is_conventional         BIT DEFAULT 0,
    -- Conforming status
    is_conforming           BIT DEFAULT 0,
    is_jumbo                BIT DEFAULT 0,
    is_harp                 BIT DEFAULT 0,           -- HARP refi
    is_hamp                 BIT DEFAULT 0            -- HAMP modification
);
```

### Servicer Dimension

```sql
CREATE TABLE dim_servicer (
    servicer_key            INT IDENTITY PRIMARY KEY,
    servicer_id             VARCHAR(20),
    servicer_name           VARCHAR(200),
    servicer_type           VARCHAR(50),             -- Bank, Non-bank, Subservicer
    parent_company          VARCHAR(200),
    -- SCD Type 2 fields
    effective_date          DATE,
    expiration_date         DATE DEFAULT '9999-12-31',
    is_current              BIT DEFAULT 1,
    -- Ratings and rankings
    sp_servicer_rating      VARCHAR(10),
    moodys_servicer_rating  VARCHAR(10),
    fitch_servicer_rating   VARCHAR(10),
    -- Contact / regulatory
    nmls_id                 VARCHAR(20),
    primary_regulator       VARCHAR(50)
);
```

### Loan Dimension

```sql
CREATE TABLE dim_loan (
    loan_key                INT IDENTITY PRIMARY KEY,
    loan_id                 VARCHAR(20) NOT NULL,
    -- Origination attributes (static)
    origination_date        DATE,
    first_payment_date      DATE,
    maturity_date           DATE,
    original_upb            DECIMAL(15,2),
    original_interest_rate  DECIMAL(6,3),
    original_term           SMALLINT,
    original_ltv            DECIMAL(6,2),
    original_cltv           DECIMAL(6,2),
    original_dti            DECIMAL(6,2),
    credit_score_orig       SMALLINT,
    co_borrower_credit_score SMALLINT,
    num_borrowers           TINYINT,
    num_units               TINYINT,
    first_time_buyer_flag   CHAR(1),
    -- Underwriting
    documentation_type      VARCHAR(30),             -- Full Doc, Alt Doc, No Doc
    mi_pct                  DECIMAL(6,2),            -- Mortgage insurance percentage
    mi_type                 VARCHAR(30),             -- Borrower-paid, Lender-paid
    -- Seller/originator
    seller_name             VARCHAR(200),
    originator_name         VARCHAR(200),
    -- Pool/deal assignment
    pool_id                 VARCHAR(20),
    deal_name               VARCHAR(50),
    -- SCD Type 2 for attributes that change (servicer transfers, modifications)
    effective_date          DATE,
    expiration_date         DATE DEFAULT '9999-12-31',
    is_current              BIT DEFAULT 1,
    -- Natural key for lookups
    INDEX ix_loan_id (loan_id)
);
```

### Pool/Deal Dimension

```sql
CREATE TABLE dim_pool (
    pool_key                INT IDENTITY PRIMARY KEY,
    pool_id                 VARCHAR(20) NOT NULL,
    pool_prefix             VARCHAR(10),
    agency                  VARCHAR(20),             -- FNMA, FHLMC, GNMA
    pool_type               VARCHAR(50),             -- 30yr Fixed, 15yr Fixed, ARM
    issue_date              DATE,
    original_face           DECIMAL(18,2),
    original_loan_count     INT,
    original_wac            DECIMAL(6,3),
    original_wam            INT,
    pass_through_rate       DECIMAL(6,3),
    -- Deal information (for PLS/non-agency)
    deal_name               VARCHAR(100),
    deal_type               VARCHAR(50),             -- Agency MBS, PLS, CRT, CLO
    shelf_name              VARCHAR(100),
    issuer_name             VARCHAR(200),
    trustee_name            VARCHAR(200),
    master_servicer         VARCHAR(200),
    closing_date            DATE
);
```

---

## Slowly Changing Dimensions

### SCD Types in MBS Context

| SCD Type | MBS Use Case | Example |
|----------|-------------|---------|
| **Type 0** | Fixed at origination | Loan original UPB, origination date, original FICO |
| **Type 1** | Overwrite (corrections) | Corrected property type, corrected state code |
| **Type 2** | Track history | Servicer transfers, loan modifications, rate changes |
| **Type 3** | Previous value column | Previous servicer alongside current servicer |
| **Type 6** | Hybrid (1+2+3) | Servicer with current, previous, and full history |

### SCD Type 2 Implementation for Servicer Transfers

Servicer transfers are a critical dimension change in MBS. When a loan is transferred from one servicer to another, you need to track this for performance attribution.

```sql
-- Procedure to handle servicer transfer (SCD Type 2)
CREATE PROCEDURE usp_process_servicer_transfer
    @loan_id        VARCHAR(20),
    @new_servicer_id VARCHAR(20),
    @transfer_date  DATE
AS
BEGIN
    -- Expire the current record
    UPDATE dim_loan
    SET expiration_date = DATEADD(DAY, -1, @transfer_date),
        is_current = 0
    WHERE loan_id = @loan_id
      AND is_current = 1;

    -- Insert new record with updated servicer
    INSERT INTO dim_loan (
        loan_id, origination_date, first_payment_date, maturity_date,
        original_upb, original_interest_rate, original_term,
        original_ltv, original_cltv, original_dti, credit_score_orig,
        seller_name, originator_name, pool_id, deal_name,
        effective_date, expiration_date, is_current
    )
    SELECT
        loan_id, origination_date, first_payment_date, maturity_date,
        original_upb, original_interest_rate, original_term,
        original_ltv, original_cltv, original_dti, credit_score_orig,
        seller_name, originator_name, pool_id, deal_name,
        @transfer_date, '9999-12-31', 1
    FROM dim_loan
    WHERE loan_id = @loan_id
      AND expiration_date = DATEADD(DAY, -1, @transfer_date);

    -- Also update the servicer_key on fact records going forward
    -- (This is handled by the ETL joining on effective/expiration dates)
END;
```

### SCD Type 2 for Loan Modifications

```sql
-- When a loan is modified, key attributes change: rate, term, UPB
-- Track as SCD Type 2 on the loan dimension
-- Query to find loans that were modified and their pre/post attributes
SELECT
    pre.loan_id,
    pre.original_interest_rate AS pre_mod_rate,
    post.original_interest_rate AS post_mod_rate,
    pre.original_upb AS pre_mod_upb,
    post.original_upb AS post_mod_upb,
    pre.original_term AS pre_mod_term,
    post.original_term AS post_mod_term,
    post.effective_date AS modification_date
FROM dim_loan pre
JOIN dim_loan post
    ON pre.loan_id = post.loan_id
    AND pre.expiration_date = DATEADD(DAY, -1, post.effective_date)
WHERE pre.is_current = 0
  AND post.effective_date > pre.effective_date
  -- Detect actual modifications (not just servicer transfers)
  AND (pre.original_interest_rate <> post.original_interest_rate
       OR pre.original_upb <> post.original_upb
       OR pre.original_term <> post.original_term);
```

---

## Aggregate Tables

### Why Aggregate Tables for MBS?

Querying billions of loan-month records for portfolio-level analytics is expensive. Pre-computed aggregate tables dramatically speed up common queries while maintaining consistency.

### Pool-Level Monthly Aggregates

```sql
CREATE TABLE agg_pool_monthly (
    pool_key                INT NOT NULL,
    date_key                INT NOT NULL,
    reporting_period        DATE NOT NULL,
    -- Aggregate measures
    active_loan_count       INT,
    total_current_upb       DECIMAL(18,2),
    total_scheduled_upb     DECIMAL(18,2),
    -- Weighted averages
    wac                     DECIMAL(6,3),
    wam                     INT,
    wala                    INT,
    avg_credit_score        DECIMAL(6,1),
    avg_ltv                 DECIMAL(6,2),
    avg_dti                 DECIMAL(6,2),
    -- Performance metrics
    smm                     DECIMAL(10,8),
    cpr                     DECIMAL(8,4),
    cdr                     DECIMAL(8,4),
    -- Delinquency distribution by UPB
    upb_current             DECIMAL(18,2),
    upb_30dpd               DECIMAL(18,2),
    upb_60dpd               DECIMAL(18,2),
    upb_90plus_dpd          DECIMAL(18,2),
    upb_foreclosure         DECIMAL(18,2),
    upb_reo                 DECIMAL(18,2),
    -- Delinquency distribution by count
    cnt_current             INT,
    cnt_30dpd               INT,
    cnt_60dpd               INT,
    cnt_90plus_dpd          INT,
    cnt_foreclosure         INT,
    cnt_reo                 INT,
    -- Loss metrics
    total_losses            DECIMAL(18,2),
    total_recoveries        DECIMAL(18,2),
    net_losses              DECIMAL(18,2),
    avg_loss_severity       DECIMAL(8,4),
    -- Metadata
    etl_load_date           DATETIME DEFAULT GETDATE(),
    PRIMARY KEY (pool_key, date_key)
);

-- Populate aggregate table
INSERT INTO agg_pool_monthly
SELECT
    f.pool_key,
    f.date_key,
    f.reporting_period,
    COUNT(*) AS active_loan_count,
    SUM(f.current_upb) AS total_current_upb,
    SUM(f.scheduled_upb) AS total_scheduled_upb,
    -- WAC = sum(rate * upb) / sum(upb)
    SUM(f.current_interest_rate * f.current_upb) / NULLIF(SUM(f.current_upb), 0) AS wac,
    -- WAM = sum(remaining_term * upb) / sum(upb)
    CAST(SUM(CAST(f.remaining_term AS BIGINT) * f.current_upb)
         / NULLIF(SUM(f.current_upb), 0) AS INT) AS wam,
    CAST(SUM(CAST(f.loan_age AS BIGINT) * f.current_upb)
         / NULLIF(SUM(f.current_upb), 0) AS INT) AS wala,
    SUM(l.credit_score_orig * f.current_upb) / NULLIF(SUM(f.current_upb), 0) AS avg_credit_score,
    SUM(l.original_ltv * f.current_upb) / NULLIF(SUM(f.current_upb), 0) AS avg_ltv,
    SUM(l.original_dti * f.current_upb) / NULLIF(SUM(f.current_upb), 0) AS avg_dti,
    -- SMM and CPR calculated separately
    NULL, NULL, NULL,
    -- Delinquency UPB buckets
    SUM(CASE WHEN f.delinquency_status = 'Current' THEN f.current_upb ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = '30' THEN f.current_upb ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = '60' THEN f.current_upb ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status IN ('90', '120+') THEN f.current_upb ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = 'FC' THEN f.current_upb ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = 'REO' THEN f.current_upb ELSE 0 END),
    -- Delinquency count buckets
    SUM(CASE WHEN f.delinquency_status = 'Current' THEN 1 ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = '30' THEN 1 ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = '60' THEN 1 ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status IN ('90', '120+') THEN 1 ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = 'FC' THEN 1 ELSE 0 END),
    SUM(CASE WHEN f.delinquency_status = 'REO' THEN 1 ELSE 0 END),
    NULL, NULL, NULL, NULL,
    GETDATE()
FROM fact_loan_performance f
JOIN dim_loan l ON f.loan_key = l.loan_key AND l.is_current = 1
GROUP BY f.pool_key, f.date_key, f.reporting_period;
```

### Vintage Cohort Aggregates

```sql
CREATE TABLE agg_vintage_cohort (
    origination_year        SMALLINT NOT NULL,
    origination_quarter     TINYINT NOT NULL,
    product_key             INT NOT NULL,
    geography_key           INT NOT NULL,
    reporting_period        DATE NOT NULL,
    seasoning_months        INT,                     -- Months since origination
    -- Cohort measures
    original_loan_count     INT,
    original_upb            DECIMAL(18,2),
    current_loan_count      INT,
    current_upb             DECIMAL(18,2),
    -- Cumulative metrics
    cum_default_rate        DECIMAL(8,4),
    cum_prepay_rate         DECIMAL(8,4),
    cum_loss_rate           DECIMAL(8,4),
    cum_loss_severity       DECIMAL(8,4),
    -- Period metrics
    period_smm              DECIMAL(10,8),
    period_mdr              DECIMAL(10,8),
    -- Delinquency rates
    serious_delinq_rate     DECIMAL(8,4),            -- 90+ DPD as % of current UPB
    PRIMARY KEY (origination_year, origination_quarter, product_key,
                 geography_key, reporting_period)
);
```

---

## Materialized Views for Analytics

### Common Analytical Queries as Materialized Views

```sql
-- Materialized view: Current portfolio snapshot
CREATE MATERIALIZED VIEW mv_current_portfolio AS
SELECT
    l.loan_id,
    p.pool_id,
    p.agency,
    pr.product_type,
    pr.rate_type,
    g.state_code,
    g.cbsa_name,
    s.servicer_name,
    l.origination_date,
    l.original_upb,
    l.original_interest_rate,
    l.credit_score_orig,
    l.original_ltv,
    f.current_upb,
    f.current_interest_rate,
    f.delinquency_status,
    f.months_delinquent,
    f.loan_age,
    f.remaining_term,
    f.modification_flag,
    f.reporting_period
FROM fact_loan_performance f
JOIN dim_loan l ON f.loan_key = l.loan_key AND l.is_current = 1
JOIN dim_pool p ON f.pool_key = p.pool_key
JOIN dim_product pr ON f.product_key = pr.product_key
JOIN dim_geography g ON f.geography_key = g.geography_key
JOIN dim_servicer s ON f.servicer_key = s.servicer_key AND s.is_current = 1
WHERE f.reporting_period = (
    SELECT MAX(reporting_period) FROM fact_loan_performance
);

-- Materialized view: Delinquency trend by state (last 24 months)
CREATE MATERIALIZED VIEW mv_delinquency_trend_state AS
SELECT
    g.state_code,
    g.state_name,
    f.reporting_period,
    COUNT(*) AS total_loans,
    SUM(f.current_upb) AS total_upb,
    SUM(CASE WHEN f.months_delinquent >= 3 THEN f.current_upb ELSE 0 END)
        / NULLIF(SUM(f.current_upb), 0) AS serious_delinq_rate,
    SUM(CASE WHEN f.months_delinquent >= 1 THEN 1 ELSE 0 END)
        * 100.0 / NULLIF(COUNT(*), 0) AS any_delinq_pct
FROM fact_loan_performance f
JOIN dim_geography g ON f.geography_key = g.geography_key
WHERE f.reporting_period >= DATEADD(MONTH, -24, (
    SELECT MAX(reporting_period) FROM fact_loan_performance
))
GROUP BY g.state_code, g.state_name, f.reporting_period;
```

### Snowflake-Specific Materialized Views

```sql
-- In Snowflake, materialized views auto-refresh
CREATE OR REPLACE MATERIALIZED VIEW mv_pool_performance
CLUSTER BY (reporting_period, agency)
AS
SELECT
    p.pool_id,
    p.agency,
    p.pool_type,
    apm.reporting_period,
    apm.active_loan_count,
    apm.total_current_upb,
    apm.wac,
    apm.wam,
    apm.cpr,
    apm.upb_current / NULLIF(apm.total_current_upb, 0) AS pct_current,
    apm.upb_30dpd / NULLIF(apm.total_current_upb, 0) AS pct_30dpd,
    apm.upb_60dpd / NULLIF(apm.total_current_upb, 0) AS pct_60dpd,
    apm.upb_90plus_dpd / NULLIF(apm.total_current_upb, 0) AS pct_90plus
FROM agg_pool_monthly apm
JOIN dim_pool p ON apm.pool_key = p.pool_key;
```

### Refresh Strategy

| Materialized View | Refresh Frequency | Trigger |
|-------------------|-------------------|---------|
| Current portfolio snapshot | After each monthly load | ETL pipeline completion |
| Delinquency trends | Monthly after performance data load | Scheduled post-ETL |
| Pool performance | Monthly | Scheduled post-aggregate build |
| Vintage cohort metrics | Monthly | Scheduled post-aggregate build |
| Deal-level summary | Monthly after cash flow load | ETL pipeline completion |

---

## Partitioning Strategies

### Partitioning by Reporting Period

The most common and effective strategy for MBS loan-level data.

```sql
-- SQL Server: Partition by reporting period
CREATE PARTITION FUNCTION pf_reporting_month (DATE)
AS RANGE RIGHT FOR VALUES (
    '2015-01-01', '2015-02-01', '2015-03-01', '2015-04-01',
    '2015-05-01', '2015-06-01', '2015-07-01', '2015-08-01',
    '2015-09-01', '2015-10-01', '2015-11-01', '2015-12-01',
    -- ... continue through current period ...
    '2026-01-01', '2026-02-01', '2026-03-01'
);

CREATE PARTITION SCHEME ps_reporting_month
AS PARTITION pf_reporting_month
ALL TO ([PRIMARY]);

-- Apply to fact table
CREATE CLUSTERED INDEX cix_loan_perf ON fact_loan_performance (reporting_period, loan_key)
ON ps_reporting_month(reporting_period);
```

```sql
-- Snowflake: Clustering key (micro-partitioning is automatic)
ALTER TABLE fact_loan_performance
CLUSTER BY (reporting_period, pool_key);

-- BigQuery: Partition by reporting period, cluster by pool
CREATE TABLE fact_loan_performance (
    ...
)
PARTITION BY reporting_period
CLUSTER BY pool_key, geography_key;
```

### Partitioning by Agency

Useful when agency-specific queries dominate the workload.

```sql
-- Sub-partition: reporting period + agency
CREATE TABLE fact_loan_performance (
    ...
)
PARTITION BY RANGE (reporting_period)
SUBPARTITION BY LIST (agency_code)
(
    PARTITION p202501 VALUES LESS THAN ('2025-02-01') (
        SUBPARTITION p202501_fnma VALUES ('FNMA'),
        SUBPARTITION p202501_fhlmc VALUES ('FHLMC'),
        SUBPARTITION p202501_gnma VALUES ('GNMA'),
        SUBPARTITION p202501_pls VALUES ('PLS')
    ),
    ...
);
```

### Partition Maintenance

```sql
-- Monthly maintenance: Add new partition, archive old data
-- Step 1: Add partition for next month
ALTER PARTITION FUNCTION pf_reporting_month()
SPLIT RANGE ('2026-04-01');

-- Step 2: Archive old data (e.g., move partitions older than 10 years)
-- Switch partition to archive table
ALTER TABLE fact_loan_performance
SWITCH PARTITION $partition.pf_reporting_month('2015-01-01')
TO fact_loan_performance_archive PARTITION $partition.pf_reporting_month('2015-01-01');
```

---

## Performance Optimization

### Indexing Strategy

```sql
-- Covering index for common portfolio queries
CREATE NONCLUSTERED INDEX ix_perf_portfolio
ON fact_loan_performance (reporting_period, product_key, geography_key)
INCLUDE (current_upb, delinquency_status, months_delinquent, loan_age);

-- Index for loan-level history lookups
CREATE NONCLUSTERED INDEX ix_perf_loan_history
ON fact_loan_performance (loan_key, reporting_period)
INCLUDE (current_upb, current_interest_rate, delinquency_status);

-- Index for servicer performance analysis
CREATE NONCLUSTERED INDEX ix_perf_servicer
ON fact_loan_performance (servicer_key, reporting_period)
INCLUDE (current_upb, delinquency_status, months_delinquent);
```

### Columnstore Indexes

For very large fact tables (billions of rows), columnstore indexes provide massive compression and analytical query performance.

```sql
-- Clustered columnstore index on the fact table
CREATE CLUSTERED COLUMNSTORE INDEX ccix_loan_performance
ON fact_loan_performance;

-- With row groups aligned to partitions
CREATE CLUSTERED COLUMNSTORE INDEX ccix_loan_performance
ON fact_loan_performance
WITH (MAXDOP = 4, DATA_COMPRESSION = COLUMNSTORE_ARCHIVE)
ON ps_reporting_month(reporting_period);
```

### Query Optimization Examples

```sql
-- INEFFICIENT: Scanning entire fact table for one pool
SELECT reporting_period, SUM(current_upb)
FROM fact_loan_performance f
JOIN dim_pool p ON f.pool_key = p.pool_key
WHERE p.pool_id = 'MA4567'
GROUP BY reporting_period;

-- EFFICIENT: Use aggregate table instead
SELECT reporting_period, total_current_upb
FROM agg_pool_monthly apm
JOIN dim_pool p ON apm.pool_key = p.pool_key
WHERE p.pool_id = 'MA4567'
ORDER BY reporting_period;

-- EFFICIENT: For loan-level, push predicate to partition key
SELECT f.reporting_period, f.current_upb, f.delinquency_status
FROM fact_loan_performance f
WHERE f.reporting_period BETWEEN '2025-01-01' AND '2025-12-01'
  AND f.pool_key = (SELECT pool_key FROM dim_pool WHERE pool_id = 'MA4567');
```

### Compression

```sql
-- SQL Server: Page compression on fact tables
ALTER TABLE fact_loan_performance
REBUILD WITH (DATA_COMPRESSION = PAGE);

-- Snowflake: Automatic compression, but choose optimal data types
-- Use NUMBER(15,2) instead of FLOAT for UPB
-- Use DATE instead of TIMESTAMP for reporting_period
-- Use VARCHAR(10) instead of VARCHAR(255) for short codes
```

### Statistics and Query Plans

```sql
-- Keep statistics fresh after monthly loads
UPDATE STATISTICS fact_loan_performance WITH FULLSCAN;
UPDATE STATISTICS dim_loan WITH FULLSCAN;

-- Create filtered statistics for common query patterns
CREATE STATISTICS stat_active_loans
ON fact_loan_performance (delinquency_status, current_upb)
WHERE delinquency_status <> 'Liquidated';
```

---

## Real-World Examples

### Example 1: Building a Star Schema for Agency MBS Surveillance

A buy-side firm holds $50B in agency MBS across 15,000 pools. They need to:
- Track delinquency trends by vintage, geography, and servicer
- Compare pool performance against cohort benchmarks
- Generate monthly board reporting with aggregated risk metrics

**Design approach:**
1. **Fact table**: `fact_loan_performance` at loan-month grain, partitioned by `reporting_period`
2. **Key dimensions**: `dim_date`, `dim_loan`, `dim_pool`, `dim_geography`, `dim_product`, `dim_servicer`
3. **Aggregate tables**: `agg_pool_monthly` for pool-level dashboards, `agg_vintage_cohort` for vintage analysis
4. **Materialized views**: Current portfolio snapshot, delinquency heatmap by state, servicer scorecard

The entire warehouse processes approximately 300 million loan-month records (10 years of history for ~2.5 million active loans) and refreshes monthly within a 4-hour batch window.

### Example 2: Non-Agency RMBS Data Warehouse

A special situations hedge fund invests in non-agency RMBS. Their data warehouse must handle:
- Deal waterfall structures with complex rules
- Tranche-level cash flow tracking
- Loan-to-deal mapping through multiple levels (loan -> group -> tranche)
- Historical trustee reports in varying formats

**Additional schema elements:**

```sql
-- Deal structure dimension
CREATE TABLE dim_tranche (
    tranche_key         INT IDENTITY PRIMARY KEY,
    deal_key            INT,
    tranche_id          VARCHAR(20),
    cusip               CHAR(9),
    tranche_type        VARCHAR(30),      -- Senior, Mezzanine, Subordinate, Residual
    class_name          VARCHAR(20),       -- A1, A2, M1, M2, B1, etc.
    original_balance    DECIMAL(18,2),
    coupon_type         VARCHAR(20),       -- Fixed, Floating, IO, PO
    coupon_rate         DECIMAL(6,3),
    coupon_spread       DECIMAL(6,3),      -- Spread over index for floaters
    index_name          VARCHAR(30),       -- SOFR, 1M LIBOR (legacy)
    credit_rating_orig  VARCHAR(10),
    credit_rating_curr  VARCHAR(10),
    seniority_order     INT,
    has_credit_support  BIT
);

-- Waterfall bridge table (many-to-many: tranches receive from multiple sources)
CREATE TABLE bridge_waterfall (
    waterfall_step      INT,
    source_type         VARCHAR(30),       -- Principal, Interest, Loss, Recovery
    receiving_tranche_key INT,
    allocation_rule     VARCHAR(200),      -- Pro rata, Sequential, Turbo
    trigger_condition   VARCHAR(500)       -- OC test, delinquency test, etc.
);
```

---

## Common Interview Questions

### Q1: How would you design a star schema for MBS loan-level analytics?

**Answer**: I would identify the primary business process as monthly loan performance and set the grain at one row per loan per reporting period.

**Fact table**: `fact_loan_performance` containing measures like current UPB, scheduled UPB, payment amounts, delinquency status (as both a code and months delinquent), loan age, and remaining term. Foreign keys link to all dimension tables.

**Dimension tables**:
- `dim_date`: Calendar attributes plus MBS-specific attributes (factor dates, remittance dates, settlement dates)
- `dim_loan`: Origination attributes (original UPB, rate, FICO, LTV, DTI) implemented as SCD Type 2 to track modifications and servicer transfers
- `dim_geography`: State, county, CBSA, census region, plus judicial/non-judicial foreclosure flag
- `dim_product`: Loan type, amortization, occupancy, property type, channel, government program flags
- `dim_servicer`: Servicer name, type, parent company, ratings, implemented as SCD Type 2
- `dim_pool`: Pool ID, agency, issue date, original face, pass-through rate, deal information

I would partition the fact table by `reporting_period` and build aggregate tables at the pool-month and vintage-cohort levels to support common dashboard queries without scanning billions of loan-level rows.

### Q2: Explain slowly changing dimensions in the context of MBS data. Give specific examples.

**Answer**: SCDs handle attributes that change over time in dimension tables.

**Type 0 (Fixed)**: Origination attributes that never change -- original loan amount, origination date, original FICO score, original LTV. These are "born" with the loan and are immutable.

**Type 1 (Overwrite)**: Used for corrections to reference data. If a property type was incorrectly coded as "Condo" and should be "PUD," we overwrite it. Historical queries will see the corrected value, which is acceptable for error corrections.

**Type 2 (Track History)**: Critical for servicer transfers and loan modifications. When Servicer A transfers a loan to Servicer B, we expire the current `dim_loan` record and create a new one with the updated servicer key. This allows us to correctly attribute performance to the servicer that was actually managing the loan at each point in time. The fact table joins to the dimension using the effective/expiration date range.

**Type 3 (Previous Value)**: Sometimes used for servicer -- keeping a `previous_servicer` column alongside `current_servicer` for quick comparison without joining multiple dimension records.

The choice matters practically. If you use Type 1 for servicer transfers, you lose the ability to measure whether a servicer's portfolio performance deteriorated after they acquired a specific book of loans -- a very common analytical question.

### Q3: How would you optimize query performance on a fact table with 5 billion rows?

**Answer**: Multiple complementary strategies:

1. **Partitioning**: Partition by `reporting_period` (monthly). This enables partition pruning -- a query for the last 12 months only scans 12 partitions instead of the full table. Also enables efficient partition swap for monthly loads and archival.

2. **Columnstore indexes**: For analytical workloads, clustered columnstore indexes provide 10-100x compression and enable batch-mode execution. Row groups of ~1 million rows each, aligned with partitions.

3. **Aggregate tables**: Pre-compute pool-level and cohort-level aggregates. Most dashboard queries do not need loan-level detail. This reduces query volume from billions of rows to thousands.

4. **Materialized views**: For frequently-run complex queries (e.g., current portfolio snapshot with all dimension attributes joined), materialized views avoid repeated joins.

5. **Proper data types**: Use DECIMAL(15,2) instead of FLOAT for UPB. Use DATE instead of DATETIME for `reporting_period`. Use SMALLINT for `loan_age` and `remaining_term`. Smaller data types mean more rows per page and better cache utilization.

6. **Statistics and index maintenance**: After each monthly load, update statistics with FULLSCAN and rebuild fragmented indexes. Create filtered statistics for common predicate patterns.

7. **Query design**: Push filters to the fact table partition key early. Avoid bringing large dimension tables into hash joins unnecessarily. Use EXISTS instead of IN for semi-joins.

### Q4: What is the difference between a fact table and an aggregate table? When would you use each?

**Answer**: A fact table stores measures at the lowest grain of the business process. In MBS, the loan performance fact table has one row per loan per month. It is the "source of truth" for detailed analysis.

An aggregate table stores pre-computed summaries at a higher grain -- for example, one row per pool per month, or per vintage cohort per month. Aggregate tables are derived from fact tables and must be refreshed when the underlying facts change.

**When to use the fact table:**
- Drill-down queries: "Show me all 90+ delinquent loans in CA in this pool"
- Loan-level analysis: survival curves, transition matrices at individual loan grain
- Ad-hoc research questions that were not anticipated in the aggregate design

**When to use aggregate tables:**
- Dashboard metrics: "What is the total UPB by agency as of this month?"
- Trend charts: "Show me the 90+ delinquency rate by state over the last 24 months"
- Portfolio summary reports: "What are the WAC, WAM, and delinquency rates for each pool?"
- Any query where you do not need individual loan detail

The key design principle is that aggregate tables should always be derivable from the underlying fact table. If they diverge, there is a data integrity issue.

### Q5: How would you handle the data warehouse design for both agency and non-agency MBS?

**Answer**: The core loan performance schema is largely the same -- both agency and non-agency loans have monthly UPB, delinquency status, and payment attributes. However, non-agency adds complexity:

1. **Deal structure**: Non-agency deals have complex tranche structures with waterfall rules. I would add `dim_tranche` and `bridge_waterfall` tables, plus a `fact_deal_cashflow` table at the tranche-month grain.

2. **Data quality**: Non-agency data is messier -- more missing fields, less standardized formats. The dimension tables need additional "Unknown" or "Not Reported" member handling.

3. **Credit enhancement**: Non-agency deals have overcollateralization, subordination, and other credit enhancement features that must be tracked. Add these as measures on the deal cash flow fact.

4. **Conformed dimensions**: Use the same `dim_date`, `dim_geography`, and `dim_product` dimensions across both agency and non-agency marts. This enables cross-universe queries (e.g., compare delinquency rates for 2019 vintage 30yr fixed across agency and non-agency).

5. **Separate marts, shared dimensions**: Physical separation via different fact tables (agency vs. non-agency) but shared conformed dimensions per the Kimball bus architecture. This prevents agency queries from being slowed by non-agency data volumes and vice versa.

---

## Tips

1. **Start with the grain**: Every data warehouse design conversation should begin with "What is the grain of the fact table?" In MBS, loan-month is almost always the right answer for performance data.

2. **Build aggregate tables early**: Do not wait until queries are slow. Plan aggregate tables as part of the initial design. Pool-monthly and vintage-cohort aggregates cover 80% of analytical queries.

3. **Use conformed dimensions across subject areas**: The same `dim_date`, `dim_geography`, and `dim_product` should serve loan origination, monthly performance, and deal cash flow facts. This is the foundation of cross-functional analytics.

4. **Plan for SCD Type 2 from the start**: Retrofitting history tracking into dimension tables after the fact is painful. Servicer transfers and loan modifications are guaranteed to occur -- design for them upfront.

5. **Partition by reporting period**: This is non-negotiable for large MBS datasets. It enables efficient monthly loads (partition swap), query pruning, and data lifecycle management (archival of old partitions).

6. **Denormalize judiciously in dimensions**: Include derived attributes in dimensions that would otherwise require complex joins. For example, include `judicial_foreclosure` flag in `dim_geography` rather than forcing a join to a separate legal reference table.

7. **Maintain a data dictionary**: MBS terminology is specialized. Document what every field means, how it is calculated, and where it comes from. New team members and auditors will thank you.

8. **Test with realistic data volumes**: A star schema that performs well with 1 million rows may fail at 1 billion. Always benchmark with production-scale data before going live.

9. **Design for the most common query pattern first**: If 80% of queries filter by reporting period and product type, optimize for that pattern with partitioning and indexing. Do not over-index for rare query patterns.

10. **Keep fact tables narrow**: Move descriptive attributes to dimensions. A fact table should contain keys, measures, and degenerate dimensions only. This maximizes rows per page and compression ratios.
