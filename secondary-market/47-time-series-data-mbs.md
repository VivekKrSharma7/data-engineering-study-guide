# Time-Series Data Management for MBS

[Back to Secondary Market Index](./README.md)

---

## Table of Contents

1. [Key Concepts](#key-concepts)
2. [Monthly Performance Snapshots](#monthly-performance-snapshots)
3. [Point-in-Time Queries](#point-in-time-queries)
4. [As-of-Date Analysis](#as-of-date-analysis)
5. [Storing Historical Loan-Level Data Efficiently](#storing-historical-loan-level-data-efficiently)
6. [Partitioning by Reporting Period](#partitioning-by-reporting-period)
7. [Vintage Cohort Analysis Queries](#vintage-cohort-analysis-queries)
8. [Trend Analysis](#trend-analysis)
9. [Temporal Table Design](#temporal-table-design)
10. [Compression Strategies for Time-Series MBS Data](#compression-strategies-for-time-series-mbs-data)
11. [Real-World Examples](#real-world-examples)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## Key Concepts

### Time-Series Nature of MBS Data

MBS data is inherently time-series: every loan in every pool has a monthly observation recording its status -- UPB, delinquency, rate, age, and dozens of other attributes. This creates a massive, steadily growing dataset where:

- Each loan generates one record per month for its entire life (often 10-30 years)
- A single agency pool of 5,000 loans produces 60,000 loan-month records per year
- The entire Fannie Mae universe of ~25 million loans produces ~300 million new records annually
- Historical analysis requires accessing data spanning 10+ years, potentially trillions of rows in aggregate

Understanding how to efficiently store, partition, query, and compress this time-series data is a core competency for data engineers in the MBS space.

### What Makes MBS Time-Series Different

Unlike sensor data or stock prices (which may have sub-second granularity), MBS time-series data has several distinctive characteristics:

- **Fixed monthly cadence**: All observations occur at the same monthly grain, aligned to reporting periods
- **Append-mostly**: New months are added, but past months are rarely updated (exceptions: corrections, late-arriving data)
- **Wide records**: Each observation has 50-100+ attributes, not just a single metric
- **Cohort structure**: Loans are grouped by origination date (vintage), and cohort-level analysis is a primary analytical pattern
- **Survivorship**: Loans exit the dataset through prepayment, default, or maturity, creating a shrinking population over time
- **Regularity**: Unlike IoT data with irregular timestamps, every active loan has exactly one observation per reporting period

---

## Monthly Performance Snapshots

### Snapshot Architecture

```sql
-- Core monthly snapshot table
CREATE TABLE loan_monthly_snapshot (
    -- Composite primary key
    loan_id              VARCHAR(20) NOT NULL,
    reporting_period     DATE NOT NULL,              -- Always 1st of month
    -- Performance measures
    current_upb          DECIMAL(15,2),
    scheduled_upb        DECIMAL(15,2),
    current_interest_rate DECIMAL(6,3),
    monthly_pi_payment   DECIMAL(12,2),
    -- Delinquency
    delinquency_status   VARCHAR(10),
    months_delinquent    SMALLINT,
    -- Age and term
    loan_age             SMALLINT,
    remaining_term       SMALLINT,
    -- Activity flags
    modification_flag    BIT DEFAULT 0,
    forbearance_flag     BIT DEFAULT 0,
    -- Termination
    zero_balance_code    VARCHAR(5),
    zero_balance_date    DATE,
    -- Payment activity
    principal_paid       DECIMAL(12,2),
    interest_paid        DECIMAL(12,2),
    curtailment_amount   DECIMAL(12,2),
    prepayment_amount    DECIMAL(12,2),
    loss_amount          DECIMAL(12,2),
    -- Metadata
    source_system        VARCHAR(20),
    etl_load_timestamp   DATETIME DEFAULT GETDATE(),
    -- Primary key
    CONSTRAINT pk_loan_snapshot PRIMARY KEY (loan_id, reporting_period)
);
```

### Snapshot Population Pattern

```sql
-- Monthly ETL: Populate snapshot for the current reporting period
INSERT INTO loan_monthly_snapshot (
    loan_id, reporting_period, current_upb, scheduled_upb,
    current_interest_rate, monthly_pi_payment,
    delinquency_status, months_delinquent,
    loan_age, remaining_term,
    modification_flag, forbearance_flag,
    zero_balance_code, zero_balance_date,
    principal_paid, interest_paid,
    curtailment_amount, prepayment_amount, loss_amount,
    source_system
)
SELECT
    t.loan_id,
    @reporting_period,
    t.current_upb,
    t.scheduled_upb,
    t.current_interest_rate,
    t.monthly_pi_payment,
    t.delinquency_status,
    t.months_delinquent,
    -- Calculate loan age from origination date
    DATEDIFF(MONTH, l.origination_date, @reporting_period) AS loan_age,
    -- Calculate remaining term
    DATEDIFF(MONTH, @reporting_period, l.maturity_date) AS remaining_term,
    t.modification_flag,
    t.forbearance_flag,
    t.zero_balance_code,
    t.zero_balance_date,
    t.principal_paid,
    t.interest_paid,
    t.curtailment_amount,
    t.prepayment_amount,
    t.loss_amount,
    'SERVICER_TAPE'
FROM xfm_loan_tape t
JOIN dim_loan l ON t.loan_id = l.loan_id AND l.is_current = 1
WHERE t.reporting_period = @reporting_period;
```

### Snapshot Completeness Validation

```sql
-- Ensure every active loan has exactly one record per reporting period
-- Check 1: No missing loans (comparing against prior month's active population)
SELECT prev.loan_id
FROM loan_monthly_snapshot prev
LEFT JOIN loan_monthly_snapshot curr
    ON prev.loan_id = curr.loan_id
    AND curr.reporting_period = @current_period
WHERE prev.reporting_period = DATEADD(MONTH, -1, @current_period)
  AND prev.zero_balance_code IS NULL     -- Was active last month
  AND curr.loan_id IS NULL;              -- Missing this month

-- Check 2: No duplicate records
SELECT loan_id, reporting_period, COUNT(*) AS record_count
FROM loan_monthly_snapshot
WHERE reporting_period = @current_period
GROUP BY loan_id, reporting_period
HAVING COUNT(*) > 1;
```

---

## Point-in-Time Queries

### What Is Point-in-Time Querying?

Point-in-time (PIT) queries retrieve the exact state of the portfolio as it existed on a specific date. This is essential for:

- Regulatory reporting: "What was our 90+ delinquency rate as of December 31, 2024?"
- Audit support: Reproduce any historical report exactly
- Model validation: Backtest models using data that was available at the time

### Portfolio State as of a Specific Date

```sql
-- Portfolio snapshot as of a specific reporting period
SELECT
    l.loan_id,
    l.origination_date,
    l.original_upb,
    l.original_interest_rate,
    l.credit_score_orig,
    l.original_ltv,
    p.pool_id,
    p.agency,
    g.state_code,
    pr.product_type,
    s.reporting_period,
    s.current_upb,
    s.current_interest_rate,
    s.delinquency_status,
    s.months_delinquent,
    s.loan_age,
    s.remaining_term
FROM loan_monthly_snapshot s
JOIN dim_loan l ON s.loan_id = l.loan_id
    -- Join to the dimension version that was active at the time
    AND s.reporting_period BETWEEN l.effective_date AND l.expiration_date
JOIN dim_pool p ON l.pool_id = p.pool_id
JOIN dim_geography g ON l.geography_key = g.geography_key
JOIN dim_product pr ON l.product_key = pr.product_key
WHERE s.reporting_period = '2024-12-01'
  AND s.zero_balance_code IS NULL;    -- Active loans only
```

### Comparing Two Points in Time

```sql
-- Compare portfolio metrics between two dates
WITH pit_start AS (
    SELECT
        COUNT(*) AS loan_count,
        SUM(current_upb) AS total_upb,
        AVG(current_interest_rate) AS avg_rate,
        SUM(CASE WHEN months_delinquent >= 3 THEN current_upb ELSE 0 END)
            / NULLIF(SUM(current_upb), 0) AS serious_dlq_rate
    FROM loan_monthly_snapshot
    WHERE reporting_period = '2024-01-01'
      AND zero_balance_code IS NULL
),
pit_end AS (
    SELECT
        COUNT(*) AS loan_count,
        SUM(current_upb) AS total_upb,
        AVG(current_interest_rate) AS avg_rate,
        SUM(CASE WHEN months_delinquent >= 3 THEN current_upb ELSE 0 END)
            / NULLIF(SUM(current_upb), 0) AS serious_dlq_rate
    FROM loan_monthly_snapshot
    WHERE reporting_period = '2024-12-01'
      AND zero_balance_code IS NULL
)
SELECT
    s.loan_count AS start_loans,
    e.loan_count AS end_loans,
    e.loan_count - s.loan_count AS loan_count_change,
    s.total_upb AS start_upb,
    e.total_upb AS end_upb,
    e.total_upb - s.total_upb AS upb_change,
    s.avg_rate AS start_avg_rate,
    e.avg_rate AS end_avg_rate,
    s.serious_dlq_rate AS start_dlq_rate,
    e.serious_dlq_rate AS end_dlq_rate,
    e.serious_dlq_rate - s.serious_dlq_rate AS dlq_rate_change
FROM pit_start s
CROSS JOIN pit_end e;
```

### Point-in-Time with SCD Type 2 Dimensions

```sql
-- Correctly join to SCD Type 2 dimensions for historical accuracy
-- "Which servicer was responsible for this loan in March 2023?"
SELECT
    s.loan_id,
    s.reporting_period,
    s.current_upb,
    s.delinquency_status,
    svc.servicer_name,
    svc.effective_date AS servicer_start,
    svc.expiration_date AS servicer_end
FROM loan_monthly_snapshot s
JOIN dim_loan l
    ON s.loan_id = l.loan_id
    AND s.reporting_period BETWEEN l.effective_date AND l.expiration_date
JOIN dim_servicer svc
    ON l.servicer_key = svc.servicer_key
WHERE s.reporting_period = '2023-03-01';
```

---

## As-of-Date Analysis

### What Is As-of-Date Analysis?

As-of-date analysis examines what data was known or available at a particular point in time. This is distinct from point-in-time queries because it accounts for data arrival timing and corrections.

For example:
- **Point-in-time**: "What was the portfolio status for the January 2025 reporting period?"
- **As-of-date**: "What did we know about the January 2025 reporting period as of February 15, 2025?" (before late corrections arrived)

### Bi-Temporal Modeling for MBS

```sql
-- Bi-temporal table: tracks both business time and system time
CREATE TABLE loan_snapshot_bitemporal (
    loan_id              VARCHAR(20) NOT NULL,
    -- Business time: the reporting period the data describes
    reporting_period     DATE NOT NULL,
    -- System time: when this version of the data was loaded
    valid_from           DATETIME2 NOT NULL,
    valid_to             DATETIME2 NOT NULL DEFAULT '9999-12-31 23:59:59',
    -- Measures
    current_upb          DECIMAL(15,2),
    delinquency_status   VARCHAR(10),
    months_delinquent    SMALLINT,
    current_interest_rate DECIMAL(6,3),
    -- Version tracking
    version_number       INT,
    change_reason        VARCHAR(100),     -- 'INITIAL_LOAD', 'CORRECTION', 'LATE_DATA'
    source_file          VARCHAR(255),
    -- Keys
    CONSTRAINT pk_bitemporal PRIMARY KEY (loan_id, reporting_period, valid_from)
);
```

### As-of-Date Query Pattern

```sql
-- What did we know about Jan 2025 as of Feb 15, 2025?
-- (This excludes corrections loaded after Feb 15)
SELECT
    loan_id,
    reporting_period,
    current_upb,
    delinquency_status,
    months_delinquent,
    version_number,
    change_reason,
    valid_from
FROM loan_snapshot_bitemporal
WHERE reporting_period = '2025-01-01'
  AND valid_from <= '2025-02-15 23:59:59'
  AND valid_to > '2025-02-15 23:59:59';

-- Compare: What is the current (latest) view of Jan 2025?
SELECT
    loan_id,
    reporting_period,
    current_upb,
    delinquency_status,
    months_delinquent,
    version_number,
    change_reason,
    valid_from
FROM loan_snapshot_bitemporal
WHERE reporting_period = '2025-01-01'
  AND valid_to = '9999-12-31 23:59:59';
```

### Correction Impact Analysis

```sql
-- How many loans were corrected after initial load for a given period?
SELECT
    reporting_period,
    COUNT(DISTINCT loan_id) AS total_loans,
    COUNT(DISTINCT CASE WHEN version_number > 1 THEN loan_id END) AS corrected_loans,
    COUNT(DISTINCT CASE WHEN version_number > 1 THEN loan_id END) * 100.0
        / COUNT(DISTINCT loan_id) AS correction_rate_pct,
    SUM(CASE WHEN version_number = 1 THEN current_upb ELSE 0 END) AS initial_total_upb,
    SUM(CASE WHEN valid_to = '9999-12-31 23:59:59' THEN current_upb ELSE 0 END) AS final_total_upb,
    SUM(CASE WHEN valid_to = '9999-12-31 23:59:59' THEN current_upb ELSE 0 END)
        - SUM(CASE WHEN version_number = 1 THEN current_upb ELSE 0 END) AS upb_correction_impact
FROM loan_snapshot_bitemporal
WHERE reporting_period = '2025-01-01'
GROUP BY reporting_period;
```

---

## Storing Historical Loan-Level Data Efficiently

### Storage Estimation

Understanding storage requirements is essential for capacity planning:

```
Assumptions:
- 25 million active loans
- ~100 bytes per loan per field, ~50 key fields = 5,000 bytes per loan-month record
- 12 months per year
- 10 years of history

Raw storage = 25M loans * 12 months * 10 years * 5KB = ~15 TB (uncompressed)

With columnar compression (10:1): ~1.5 TB
With aggressive compression and archival: ~500 GB for older data
```

### Storage Tier Strategy

| Tier | Data Age | Storage Type | Compression | Access Pattern |
|------|----------|-------------|-------------|----------------|
| **Hot** | 0-24 months | SSD / In-memory | Standard columnar | Frequent queries, dashboards |
| **Warm** | 2-5 years | Standard disk | High compression | Monthly reporting, ad-hoc analysis |
| **Cold** | 5-10 years | Object storage (S3/ADLS) | Archive compression | Annual reviews, regulatory audits |
| **Archive** | 10+ years | Glacier / Archive blob | Maximum compression | Legal holds, rare access |

### Efficient Data Types

Choosing the right data types has a significant impact on storage and query performance:

```sql
-- INEFFICIENT: Oversized data types
CREATE TABLE loan_snapshot_bad (
    loan_id              NVARCHAR(255),          -- 510 bytes
    reporting_period     DATETIME,                -- 8 bytes
    current_upb          FLOAT,                   -- 8 bytes (precision issues!)
    interest_rate        FLOAT,                   -- 8 bytes (precision issues!)
    delinquency_status   NVARCHAR(255),          -- 510 bytes
    months_delinquent    INT,                     -- 4 bytes
    loan_age             INT,                     -- 4 bytes
    remaining_term       INT,                     -- 4 bytes
    state_code           NVARCHAR(255)            -- 510 bytes
);
-- Total per row: ~1,566 bytes

-- EFFICIENT: Right-sized data types
CREATE TABLE loan_snapshot_good (
    loan_id              VARCHAR(20),             -- 20 bytes
    reporting_period     DATE,                    -- 3 bytes
    current_upb          DECIMAL(15,2),           -- 9 bytes (exact precision)
    interest_rate        DECIMAL(6,3),            -- 5 bytes (exact precision)
    delinquency_status   CHAR(3),                -- 3 bytes (use code, not description)
    months_delinquent    TINYINT,                 -- 1 byte (range 0-255 sufficient)
    loan_age             SMALLINT,                -- 2 bytes (range 0-32,767 sufficient)
    remaining_term       SMALLINT,                -- 2 bytes
    state_code           CHAR(2)                  -- 2 bytes
);
-- Total per row: ~47 bytes (97% smaller!)
```

### Delta Encoding / Change-Only Storage

For time-series data where most fields remain unchanged month over month, storing only the changes can dramatically reduce storage:

```sql
-- Instead of storing full snapshots, store only fields that changed
CREATE TABLE loan_snapshot_delta (
    loan_id              VARCHAR(20) NOT NULL,
    reporting_period     DATE NOT NULL,
    -- Only populated fields indicate changes from prior month
    current_upb          DECIMAL(15,2),          -- NULL if unchanged
    delinquency_status   VARCHAR(10),            -- NULL if unchanged
    months_delinquent    SMALLINT,               -- NULL if unchanged
    interest_rate        DECIMAL(6,3),           -- NULL if unchanged
    -- Change tracking
    changed_fields       VARCHAR(500),            -- Comma-separated list of changed fields
    is_full_snapshot     BIT DEFAULT 0,           -- TRUE for the first record of each loan
    CONSTRAINT pk_delta PRIMARY KEY (loan_id, reporting_period)
);

-- Reconstruct full snapshot from deltas (using window functions)
WITH reconstructed AS (
    SELECT
        loan_id,
        reporting_period,
        -- Use LAST_VALUE to carry forward the most recent non-null value
        LAST_VALUE(current_upb) IGNORE NULLS OVER (
            PARTITION BY loan_id
            ORDER BY reporting_period
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS current_upb,
        LAST_VALUE(delinquency_status) IGNORE NULLS OVER (
            PARTITION BY loan_id
            ORDER BY reporting_period
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS delinquency_status,
        LAST_VALUE(interest_rate) IGNORE NULLS OVER (
            PARTITION BY loan_id
            ORDER BY reporting_period
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS interest_rate
    FROM loan_snapshot_delta
)
SELECT * FROM reconstructed
WHERE reporting_period = '2025-01-01';
```

**Trade-off**: Delta encoding saves significant storage but makes point-in-time queries more complex and potentially slower (must reconstruct from history). Use this pattern for archival/cold storage, not for the primary hot analytical layer.

---

## Partitioning by Reporting Period

### Why Partition by Reporting Period?

Reporting period is the natural partitioning dimension for MBS time-series data because:

1. **Query alignment**: Almost every analytical query filters or groups by reporting period
2. **Load alignment**: New data arrives monthly, aligned to reporting periods
3. **Management alignment**: Archival, retention, and deletion are managed by period
4. **Size uniformity**: Each partition is roughly the same size (same loan population, minor monthly attrition)

### Implementation Across Platforms

#### SQL Server

```sql
-- Create partition function with monthly boundaries
CREATE PARTITION FUNCTION pf_month (DATE)
AS RANGE RIGHT FOR VALUES (
    '2015-01-01', '2015-02-01', '2015-03-01',
    -- ... all months through current ...
    '2026-01-01', '2026-02-01', '2026-03-01'
);

-- Assign to filegroups (optional: different storage per age)
CREATE PARTITION SCHEME ps_month
AS PARTITION pf_month TO (
    [FG_ARCHIVE], [FG_ARCHIVE], [FG_ARCHIVE],  -- 2015 on slower storage
    -- ...
    [FG_ACTIVE], [FG_ACTIVE], [FG_ACTIVE]       -- 2026 on fast storage
);

-- Create table on partition scheme
CREATE TABLE loan_monthly_snapshot (
    loan_id              VARCHAR(20) NOT NULL,
    reporting_period     DATE NOT NULL,
    current_upb          DECIMAL(15,2),
    -- ... other columns ...
    CONSTRAINT pk_snapshot PRIMARY KEY (loan_id, reporting_period)
) ON ps_month(reporting_period);

-- Monthly maintenance: Add next month's partition
ALTER PARTITION FUNCTION pf_month()
SPLIT RANGE ('2026-04-01');

-- Query execution plan will show partition elimination
SELECT COUNT(*), SUM(current_upb)
FROM loan_monthly_snapshot
WHERE reporting_period = '2026-01-01';  -- Scans only 1 partition
```

#### Snowflake (Micro-Partitioning with Clustering)

```sql
-- Snowflake auto-partitions, but clustering key guides physical layout
CREATE TABLE loan_monthly_snapshot (
    loan_id              VARCHAR(20),
    reporting_period     DATE,
    current_upb          NUMBER(15,2),
    delinquency_status   VARCHAR(10),
    months_delinquent    NUMBER(3,0),
    loan_age             NUMBER(4,0),
    state_code           CHAR(2),
    pool_id              VARCHAR(20)
)
CLUSTER BY (reporting_period, pool_id);

-- Verify clustering efficiency
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'loan_monthly_snapshot',
    '(reporting_period, pool_id)'
);
```

#### BigQuery

```sql
-- Partition by reporting period, cluster by common filter columns
CREATE TABLE mbs_dataset.loan_monthly_snapshot (
    loan_id              STRING,
    reporting_period     DATE,
    current_upb          NUMERIC,
    delinquency_status   STRING,
    months_delinquent    INT64,
    loan_age             INT64,
    state_code           STRING,
    pool_id              STRING
)
PARTITION BY reporting_period
CLUSTER BY pool_id, state_code
OPTIONS (
    require_partition_filter = true  -- Force users to filter by period
);
```

### Partition Swap for Monthly Loads

```sql
-- Efficient monthly load using partition swap (SQL Server)
-- Step 1: Load new data into a staging table with same structure
CREATE TABLE loan_snapshot_staging (
    loan_id              VARCHAR(20) NOT NULL,
    reporting_period     DATE NOT NULL,
    current_upb          DECIMAL(15,2),
    -- ... same columns as production ...
    CONSTRAINT ck_period CHECK (reporting_period = '2026-03-01')
) ON [FG_ACTIVE];

-- Step 2: Load data into staging
INSERT INTO loan_snapshot_staging (...)
SELECT ... FROM xfm_loan_tape WHERE reporting_period = '2026-03-01';

-- Step 3: Build indexes on staging (matches production)
CREATE UNIQUE CLUSTERED INDEX pk_staging
ON loan_snapshot_staging (loan_id, reporting_period);

-- Step 4: Switch partition (instantaneous metadata operation)
ALTER TABLE loan_snapshot_staging
SWITCH TO loan_monthly_snapshot
PARTITION $partition.pf_month('2026-03-01');

-- This is near-instantaneous regardless of data volume
-- No row-by-row INSERT; no transaction log bloat
```

---

## Vintage Cohort Analysis Queries

### What Is Vintage Analysis?

Vintage (or cohort) analysis groups loans by their origination period and tracks their performance over time. This is the primary analytical framework for:

- Comparing credit quality across origination vintages
- Measuring seasoning curves (how performance evolves as loans age)
- Identifying vintage-specific anomalies (e.g., the 2006-2007 vintages in the pre-crisis era)
- Benchmarking new originations against historical patterns

### Basic Vintage Performance Curve

```sql
-- Cumulative default rate by vintage and seasoning month
SELECT
    YEAR(l.origination_date) AS vintage_year,
    DATEPART(QUARTER, l.origination_date) AS vintage_quarter,
    s.loan_age AS seasoning_month,
    COUNT(DISTINCT l.loan_id) AS original_cohort_size,
    COUNT(DISTINCT CASE
        WHEN s.zero_balance_code IN ('03', '09')  -- Default/REO codes
        THEN l.loan_id
    END) AS cumulative_defaults,
    COUNT(DISTINCT CASE
        WHEN s.zero_balance_code IN ('03', '09')
        THEN l.loan_id
    END) * 100.0 / COUNT(DISTINCT l.loan_id) AS cum_default_rate
FROM dim_loan l
JOIN loan_monthly_snapshot s
    ON l.loan_id = s.loan_id
WHERE l.is_current = 1
  AND YEAR(l.origination_date) BETWEEN 2018 AND 2024
GROUP BY
    YEAR(l.origination_date),
    DATEPART(QUARTER, l.origination_date),
    s.loan_age
ORDER BY vintage_year, vintage_quarter, seasoning_month;
```

### Vintage Prepayment Curves (CPR by Seasoning)

```sql
-- Monthly CPR by vintage and seasoning
WITH monthly_activity AS (
    SELECT
        YEAR(l.origination_date) AS vintage_year,
        s.loan_age AS seasoning_month,
        s.reporting_period,
        SUM(s.current_upb) AS period_end_upb,
        SUM(s.prepayment_amount) AS prepayments,
        -- Get prior month UPB for SMM calculation
        LAG(SUM(s.current_upb + s.prepayment_amount + s.loss_amount
                + s.principal_paid)) OVER (
            PARTITION BY YEAR(l.origination_date), s.loan_age
            ORDER BY s.reporting_period
        ) AS prior_upb
    FROM loan_monthly_snapshot s
    JOIN dim_loan l ON s.loan_id = l.loan_id AND l.is_current = 1
    WHERE YEAR(l.origination_date) BETWEEN 2020 AND 2024
    GROUP BY YEAR(l.origination_date), s.loan_age, s.reporting_period
)
SELECT
    vintage_year,
    seasoning_month,
    prepayments / NULLIF(prior_upb, 0) AS smm,
    1 - POWER(1 - prepayments / NULLIF(prior_upb, 0), 12) AS cpr
FROM monthly_activity
WHERE prior_upb > 0
ORDER BY vintage_year, seasoning_month;
```

### Vintage Delinquency Transition Matrix

```sql
-- Monthly transition matrix: How loans move between delinquency states
WITH transitions AS (
    SELECT
        YEAR(l.origination_date) AS vintage_year,
        prev.delinquency_status AS from_status,
        curr.delinquency_status AS to_status,
        COUNT(*) AS loan_count,
        SUM(curr.current_upb) AS transition_upb
    FROM loan_monthly_snapshot curr
    JOIN loan_monthly_snapshot prev
        ON curr.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, curr.reporting_period)
    JOIN dim_loan l ON curr.loan_id = l.loan_id AND l.is_current = 1
    WHERE curr.reporting_period = '2025-01-01'
      AND YEAR(l.origination_date) = 2022
    GROUP BY
        YEAR(l.origination_date),
        prev.delinquency_status,
        curr.delinquency_status
)
SELECT
    vintage_year,
    from_status,
    to_status,
    loan_count,
    transition_upb,
    loan_count * 100.0 / SUM(loan_count) OVER (PARTITION BY vintage_year, from_status)
        AS transition_pct
FROM transitions
ORDER BY vintage_year, from_status, to_status;
```

### Vintage Comparison with FICO and LTV Stratification

```sql
-- Compare vintage performance by FICO band and LTV band
SELECT
    YEAR(l.origination_date) AS vintage_year,
    CASE
        WHEN l.credit_score_orig >= 760 THEN '760+'
        WHEN l.credit_score_orig >= 720 THEN '720-759'
        WHEN l.credit_score_orig >= 680 THEN '680-719'
        WHEN l.credit_score_orig >= 640 THEN '640-679'
        ELSE '<640'
    END AS fico_band,
    CASE
        WHEN l.original_ltv <= 60 THEN '<=60'
        WHEN l.original_ltv <= 80 THEN '61-80'
        WHEN l.original_ltv <= 90 THEN '81-90'
        WHEN l.original_ltv <= 95 THEN '91-95'
        ELSE '>95'
    END AS ltv_band,
    COUNT(DISTINCT l.loan_id) AS loan_count,
    SUM(l.original_upb) AS original_upb,
    -- Current status (latest reporting period)
    SUM(CASE WHEN s.months_delinquent >= 3 THEN s.current_upb ELSE 0 END)
        / NULLIF(SUM(s.current_upb), 0) AS serious_dlq_rate,
    SUM(CASE WHEN s.zero_balance_code IN ('03', '09') THEN l.original_upb ELSE 0 END)
        / NULLIF(SUM(l.original_upb), 0) AS cum_default_rate
FROM dim_loan l
JOIN loan_monthly_snapshot s
    ON l.loan_id = s.loan_id
    AND s.reporting_period = (SELECT MAX(reporting_period) FROM loan_monthly_snapshot)
WHERE l.is_current = 1
  AND YEAR(l.origination_date) BETWEEN 2018 AND 2024
GROUP BY
    YEAR(l.origination_date),
    CASE
        WHEN l.credit_score_orig >= 760 THEN '760+'
        WHEN l.credit_score_orig >= 720 THEN '720-759'
        WHEN l.credit_score_orig >= 680 THEN '680-719'
        WHEN l.credit_score_orig >= 640 THEN '640-679'
        ELSE '<640'
    END,
    CASE
        WHEN l.original_ltv <= 60 THEN '<=60'
        WHEN l.original_ltv <= 80 THEN '61-80'
        WHEN l.original_ltv <= 90 THEN '81-90'
        WHEN l.original_ltv <= 95 THEN '91-95'
        ELSE '>95'
    END
ORDER BY vintage_year, fico_band, ltv_band;
```

---

## Trend Analysis

### Delinquency Trends

```sql
-- National delinquency trend (monthly, last 36 months)
SELECT
    s.reporting_period,
    COUNT(*) AS total_active_loans,
    SUM(s.current_upb) AS total_upb,
    -- Delinquency rates by count
    SUM(CASE WHEN s.months_delinquent >= 1 THEN 1 ELSE 0 END) * 100.0
        / COUNT(*) AS any_dlq_pct,
    SUM(CASE WHEN s.months_delinquent >= 3 THEN 1 ELSE 0 END) * 100.0
        / COUNT(*) AS serious_dlq_pct,
    -- Delinquency rates by UPB
    SUM(CASE WHEN s.months_delinquent >= 1 THEN s.current_upb ELSE 0 END)
        / NULLIF(SUM(s.current_upb), 0) * 100 AS any_dlq_upb_pct,
    SUM(CASE WHEN s.months_delinquent >= 3 THEN s.current_upb ELSE 0 END)
        / NULLIF(SUM(s.current_upb), 0) * 100 AS serious_dlq_upb_pct,
    -- Delinquency bucket distribution
    SUM(CASE WHEN s.delinquency_status = 'Current' THEN s.current_upb ELSE 0 END)
        / NULLIF(SUM(s.current_upb), 0) * 100 AS pct_current,
    SUM(CASE WHEN s.delinquency_status = '30' THEN s.current_upb ELSE 0 END)
        / NULLIF(SUM(s.current_upb), 0) * 100 AS pct_30dpd,
    SUM(CASE WHEN s.delinquency_status = '60' THEN s.current_upb ELSE 0 END)
        / NULLIF(SUM(s.current_upb), 0) * 100 AS pct_60dpd,
    SUM(CASE WHEN s.delinquency_status IN ('90', '120+') THEN s.current_upb ELSE 0 END)
        / NULLIF(SUM(s.current_upb), 0) * 100 AS pct_90plus
FROM loan_monthly_snapshot s
WHERE s.reporting_period >= DATEADD(MONTH, -36,
    (SELECT MAX(reporting_period) FROM loan_monthly_snapshot))
  AND s.zero_balance_code IS NULL
GROUP BY s.reporting_period
ORDER BY s.reporting_period;
```

### Prepayment Trends (CPR)

```sql
-- Monthly CPR trend by product type
WITH monthly_speeds AS (
    SELECT
        s.reporting_period,
        pr.product_type,
        SUM(s.prepayment_amount + s.curtailment_amount) AS total_prepay,
        SUM(prev.current_upb) AS prior_month_upb
    FROM loan_monthly_snapshot s
    JOIN loan_monthly_snapshot prev
        ON s.loan_id = prev.loan_id
        AND prev.reporting_period = DATEADD(MONTH, -1, s.reporting_period)
    JOIN dim_loan l ON s.loan_id = l.loan_id AND l.is_current = 1
    JOIN dim_product pr ON l.product_key = pr.product_key
    WHERE s.reporting_period >= DATEADD(MONTH, -24,
        (SELECT MAX(reporting_period) FROM loan_monthly_snapshot))
    GROUP BY s.reporting_period, pr.product_type
)
SELECT
    reporting_period,
    product_type,
    total_prepay / NULLIF(prior_month_upb, 0) AS smm,
    1 - POWER(1 - total_prepay / NULLIF(prior_month_upb, 0), 12) AS cpr,
    -- 3-month moving average CPR
    AVG(1 - POWER(1 - total_prepay / NULLIF(prior_month_upb, 0), 12))
        OVER (PARTITION BY product_type
              ORDER BY reporting_period
              ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS cpr_3m_avg
FROM monthly_speeds
ORDER BY product_type, reporting_period;
```

### Geographic Trend Analysis

```sql
-- State-level delinquency trend with year-over-year comparison
WITH state_monthly AS (
    SELECT
        g.state_code,
        s.reporting_period,
        SUM(CASE WHEN s.months_delinquent >= 3 THEN s.current_upb ELSE 0 END)
            / NULLIF(SUM(s.current_upb), 0) AS serious_dlq_rate
    FROM loan_monthly_snapshot s
    JOIN dim_loan l ON s.loan_id = l.loan_id AND l.is_current = 1
    JOIN dim_geography g ON l.geography_key = g.geography_key
    WHERE s.zero_balance_code IS NULL
      AND s.reporting_period >= DATEADD(YEAR, -2,
          (SELECT MAX(reporting_period) FROM loan_monthly_snapshot))
    GROUP BY g.state_code, s.reporting_period
)
SELECT
    curr.state_code,
    curr.reporting_period,
    curr.serious_dlq_rate AS current_dlq_rate,
    yoy.serious_dlq_rate AS prior_year_dlq_rate,
    curr.serious_dlq_rate - yoy.serious_dlq_rate AS yoy_change,
    CASE
        WHEN curr.serious_dlq_rate > yoy.serious_dlq_rate * 1.25
        THEN 'DETERIORATING'
        WHEN curr.serious_dlq_rate < yoy.serious_dlq_rate * 0.75
        THEN 'IMPROVING'
        ELSE 'STABLE'
    END AS trend_classification
FROM state_monthly curr
LEFT JOIN state_monthly yoy
    ON curr.state_code = yoy.state_code
    AND yoy.reporting_period = DATEADD(YEAR, -1, curr.reporting_period)
WHERE curr.reporting_period = (SELECT MAX(reporting_period) FROM loan_monthly_snapshot)
ORDER BY yoy_change DESC;
```

### Loss Severity Trends

```sql
-- Monthly loss severity trend for liquidated loans
SELECT
    s.reporting_period,
    COUNT(*) AS liquidation_count,
    SUM(s.loss_amount) AS total_loss,
    SUM(l.original_upb) AS total_original_upb,
    SUM(s.loss_amount) / NULLIF(SUM(
        CASE WHEN s.loss_amount > 0 THEN s.current_upb + s.loss_amount END
    ), 0) AS avg_loss_severity,
    -- Breakdown by disposition type
    AVG(CASE WHEN s.zero_balance_code = '03' THEN
        s.loss_amount / NULLIF(s.current_upb + s.loss_amount, 0)
    END) AS short_sale_severity,
    AVG(CASE WHEN s.zero_balance_code = '09' THEN
        s.loss_amount / NULLIF(s.current_upb + s.loss_amount, 0)
    END) AS reo_severity
FROM loan_monthly_snapshot s
JOIN dim_loan l ON s.loan_id = l.loan_id AND l.is_current = 1
WHERE s.zero_balance_code IN ('03', '09')
  AND s.zero_balance_date IS NOT NULL
  AND s.reporting_period >= DATEADD(YEAR, -5,
      (SELECT MAX(reporting_period) FROM loan_monthly_snapshot))
GROUP BY s.reporting_period
ORDER BY s.reporting_period;
```

---

## Temporal Table Design

### SQL Server System-Versioned Temporal Tables

SQL Server 2016+ provides built-in temporal table support, ideal for tracking loan data corrections.

```sql
-- Create a system-versioned temporal table
CREATE TABLE loan_snapshot_temporal (
    loan_id              VARCHAR(20) NOT NULL,
    reporting_period     DATE NOT NULL,
    current_upb          DECIMAL(15,2),
    delinquency_status   VARCHAR(10),
    months_delinquent    SMALLINT,
    interest_rate        DECIMAL(6,3),
    modification_flag    BIT,
    -- System-versioning columns
    sys_start            DATETIME2 GENERATED ALWAYS AS ROW START,
    sys_end              DATETIME2 GENERATED ALWAYS AS ROW END,
    PERIOD FOR SYSTEM_TIME (sys_start, sys_end),
    CONSTRAINT pk_temporal PRIMARY KEY (loan_id, reporting_period)
)
WITH (SYSTEM_VERSIONING = ON (
    HISTORY_TABLE = dbo.loan_snapshot_temporal_history,
    DATA_CONSISTENCY_CHECK = ON
));
```

### Querying Temporal Tables

```sql
-- Current data (standard query)
SELECT * FROM loan_snapshot_temporal
WHERE loan_id = '1234567890' AND reporting_period = '2025-01-01';

-- Data as of a specific system time (before a correction was applied)
SELECT * FROM loan_snapshot_temporal
FOR SYSTEM_TIME AS OF '2025-02-15 10:00:00'
WHERE loan_id = '1234567890' AND reporting_period = '2025-01-01';

-- All versions of a record (full audit trail)
SELECT *, sys_start, sys_end
FROM loan_snapshot_temporal
FOR SYSTEM_TIME ALL
WHERE loan_id = '1234567890' AND reporting_period = '2025-01-01'
ORDER BY sys_start;

-- Find all records that were modified between two dates
SELECT *
FROM loan_snapshot_temporal
FOR SYSTEM_TIME BETWEEN '2025-02-01' AND '2025-02-28'
WHERE reporting_period = '2025-01-01';
```

### Temporal Design for Different Platforms

#### Snowflake Time Travel

```sql
-- Snowflake provides automatic time travel (up to 90 days on Enterprise)
-- Query data as it existed at a specific timestamp
SELECT *
FROM loan_monthly_snapshot
AT (TIMESTAMP => '2025-02-15 10:00:00'::TIMESTAMP_TZ)
WHERE loan_id = '1234567890'
  AND reporting_period = '2025-01-01';

-- Query data as it existed before a specific statement
SELECT *
FROM loan_monthly_snapshot
BEFORE (STATEMENT => '8e5d0ca9-005e-44e6-b858-a8f5b37c5726')
WHERE reporting_period = '2025-01-01';

-- Set retention period for the table
ALTER TABLE loan_monthly_snapshot
SET DATA_RETENTION_TIME_IN_DAYS = 90;
```

#### BigQuery Snapshot Decorators

```sql
-- Query a table as of a specific time (up to 7 days)
SELECT *
FROM `project.dataset.loan_monthly_snapshot`
FOR SYSTEM_TIME AS OF TIMESTAMP('2025-02-15 10:00:00 UTC')
WHERE loan_id = '1234567890'
  AND reporting_period = '2025-01-01';
```

---

## Compression Strategies for Time-Series MBS Data

### Columnar Compression

Columnar storage is exceptionally effective for MBS data because:

- Many columns have low cardinality (delinquency_status has ~8 distinct values across millions of rows)
- Numeric columns (UPB, rate) have limited range and precision
- State codes, product types, and flags compress to near-zero overhead
- Run-length encoding is effective when data is sorted by reporting_period (all same value in a partition)

```sql
-- SQL Server Columnstore
CREATE CLUSTERED COLUMNSTORE INDEX ccix_snapshot
ON loan_monthly_snapshot;

-- Check compression ratio
SELECT
    OBJECT_NAME(object_id) AS table_name,
    SUM(on_disk_size) / 1024 / 1024 AS disk_size_mb,
    SUM(in_row_data_page_count) * 8 / 1024 AS uncompressed_est_mb,
    CAST(SUM(in_row_data_page_count) * 8.0 / NULLIF(SUM(on_disk_size / 1024.0), 0) AS DECIMAL(5,1))
        AS compression_ratio
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE OBJECT_NAME(object_id) = 'loan_monthly_snapshot'
GROUP BY object_id;
```

### Page and Row Compression (SQL Server)

```sql
-- Page compression: 50-70% reduction for MBS data
ALTER TABLE loan_monthly_snapshot
REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = PAGE);

-- Check space savings
EXEC sp_estimate_data_compression_savings
    @schema_name = 'dbo',
    @object_name = 'loan_monthly_snapshot',
    @index_id = NULL,
    @partition_number = NULL,
    @data_compression = 'PAGE';
```

### Parquet for Data Lake Storage

```sql
-- Snowflake: Unload to Parquet for archival
COPY INTO @mbs_archive_stage/loan_snapshots/
FROM (
    SELECT *
    FROM loan_monthly_snapshot
    WHERE reporting_period < DATEADD(YEAR, -5, CURRENT_DATE())
)
FILE_FORMAT = (TYPE = 'PARQUET')
HEADER = TRUE
OVERWRITE = TRUE
MAX_FILE_SIZE = 268435456;  -- 256 MB per file
```

### Compression Comparison for MBS Data

| Compression Method | Typical Ratio | Best For | Platform |
|-------------------|--------------|----------|----------|
| **None** | 1:1 | Never for MBS at scale | All |
| **Row compression** | 2:1 - 3:1 | OLTP tables with mixed workloads | SQL Server |
| **Page compression** | 4:1 - 7:1 | Warm analytical tables | SQL Server |
| **Columnstore** | 8:1 - 15:1 | Large fact tables, time-series | SQL Server, Snowflake |
| **Columnstore Archive** | 12:1 - 25:1 | Cold/archive data | SQL Server |
| **Parquet + Snappy** | 6:1 - 10:1 | Data lake storage | Spark, Snowflake, BigQuery |
| **Parquet + ZSTD** | 10:1 - 15:1 | Archive data lake | Spark, Snowflake |
| **ORC + ZLIB** | 8:1 - 12:1 | Hive/Hadoop environments | Hadoop ecosystem |

### Compression Best Practices for MBS

```sql
-- Sort data before compression for maximum benefit
-- Sorting by reporting_period + pool_id clusters similar values together
-- which dramatically improves run-length and dictionary encoding

-- Snowflake: Clustering key determines physical sort order
ALTER TABLE loan_monthly_snapshot
CLUSTER BY (reporting_period, pool_id, state_code);

-- Spark: Sort before writing to Parquet
-- df.repartition('reporting_period') \
--   .sortWithinPartitions('pool_id', 'loan_id') \
--   .write.parquet('/mbs/loan_snapshots/')
```

### Tiered Compression Strategy

```sql
-- Implement age-based compression tiers in SQL Server

-- Hot tier (last 24 months): Standard columnstore
ALTER TABLE loan_monthly_snapshot
REBUILD PARTITION = $partition.pf_month('2025-01-01')
WITH (DATA_COMPRESSION = COLUMNSTORE);

-- Warm tier (2-5 years): Columnstore with archive compression
ALTER TABLE loan_monthly_snapshot
REBUILD PARTITION = $partition.pf_month('2022-01-01')
WITH (DATA_COMPRESSION = COLUMNSTORE_ARCHIVE);

-- Cold tier (5+ years): Move to archive table with maximum compression
-- Or unload to Parquet in data lake
ALTER TABLE loan_monthly_snapshot
SWITCH PARTITION $partition.pf_month('2018-01-01')
TO loan_snapshot_archive PARTITION $partition.pf_month('2018-01-01');
```

---

## Real-World Examples

### Example 1: Building a 10-Year Loan Performance Database

A mortgage analytics firm needs to load and query 10 years of Fannie Mae loan performance data (publicly available). The dataset contains:

- ~45 million unique loans
- ~120 months of potential observations per loan
- ~3 billion total loan-month records

**Architecture decisions:**

1. **Storage**: Snowflake Enterprise with clustering on `(reporting_period, pool_id)`
2. **Partitioning**: Automatic micro-partitioning aligned to reporting_period cluster key
3. **Loading**: Bulk load historical files (one per quarter) using Snowpipe; monthly incremental going forward
4. **Compression**: Snowflake's automatic columnar compression yields ~12:1 ratio, reducing 3 TB uncompressed to ~250 GB
5. **Aggregate layer**: Pre-computed vintage cohort tables and pool-monthly aggregates for dashboard queries
6. **Query patterns**: Vintage analysis queries complete in 5-15 seconds by scanning only the required partitions and leveraging result caching

### Example 2: Real-Time Correction Tracking with Temporal Tables

An MBS trustee needs to track every correction to loan-level data for audit purposes. Requirements:

- Reproduce any report as it was published on any date
- Track who changed what and when
- Support both the "current truth" view and the "as-of" view

**Implementation:**

1. **SQL Server temporal tables** with system versioning enabled
2. Primary table holds current data; history table automatically captures every UPDATE and DELETE
3. `FOR SYSTEM_TIME AS OF` queries reproduce reports at any historical timestamp
4. Custom audit columns track the correction source and reason (supplementing the system-generated timestamps)
5. Monthly reconciliation process compares current data vs. original load to quantify correction volume

```sql
-- Monthly correction report
SELECT
    reporting_period,
    COUNT(*) AS total_corrections,
    SUM(CASE WHEN ABS(h.current_upb - c.current_upb) > 0.01 THEN 1 ELSE 0 END)
        AS upb_corrections,
    SUM(CASE WHEN h.delinquency_status <> c.delinquency_status THEN 1 ELSE 0 END)
        AS dlq_corrections,
    SUM(ABS(c.current_upb - h.current_upb)) AS total_upb_adjustment
FROM loan_snapshot_temporal c
JOIN loan_snapshot_temporal_history h
    ON c.loan_id = h.loan_id
    AND c.reporting_period = h.reporting_period
WHERE c.reporting_period = '2025-01-01'
GROUP BY reporting_period;
```

### Example 3: Multi-Speed Trend Dashboard

A portfolio manager needs a dashboard showing delinquency and prepayment trends at multiple levels of granularity: national, state, MSA, and pool. The challenge is query performance at each level.

**Solution:**

1. **Pre-compute aggregates** at each granularity level during the monthly ETL:
   - `agg_national_monthly`: One row per month
   - `agg_state_monthly`: ~50 rows per month
   - `agg_msa_monthly`: ~400 rows per month
   - `agg_pool_monthly`: ~15,000 rows per month

2. **Materialized views** for the dashboard queries, refreshed monthly

3. **Drill-through to detail**: When a user clicks on a specific pool, query the loan-level snapshot table filtered by pool_key and reporting_period (partition-pruned)

4. **Caching**: Dashboard tool (Tableau/Power BI) caches aggregate-level queries; only drill-through hits the database

---

## Common Interview Questions

### Q1: How would you design a database schema to efficiently store 10 years of monthly loan-level performance data?

**Answer**: I would design around the monthly snapshot pattern with a primary table at the loan-month grain:

**Schema**: One row per loan per reporting period containing all performance attributes (UPB, delinquency, rate, age, term, payment activity). Origination attributes that never change (original FICO, LTV, loan purpose) go in a separate dimension table, not repeated in every snapshot row.

**Partitioning**: Partition by `reporting_period` (monthly). This is the single most impactful design decision because virtually every query filters on reporting period, monthly loads can use partition swap for near-instant loading, and data lifecycle management (archival, purging) operates at partition granularity.

**Compression**: Use columnar storage (columnstore index in SQL Server, automatic in Snowflake/BigQuery). MBS data compresses exceptionally well -- 10:1 or better -- because many columns have low cardinality and values are highly repetitive within partitions.

**Data types**: Right-size every column. Use SMALLINT for loan_age and remaining_term (not INT), DECIMAL(15,2) for UPB (not FLOAT), CHAR(2) for state codes (not VARCHAR(255)). At billions of rows, every byte matters.

**Aggregates**: Pre-compute pool-monthly and vintage-cohort aggregates to serve 80% of analytical queries without touching the loan-level detail table.

**Tiered storage**: Hot (last 2 years, standard compression, SSD), warm (2-5 years, archive compression, standard disk), cold (5+ years, Parquet in data lake or archive compression).

### Q2: Explain point-in-time queries and why they matter for MBS data.

**Answer**: Point-in-time queries retrieve the exact state of the portfolio as it existed on a specific date. For MBS data, this is critical for several reasons:

**Regulatory reporting**: When a regulator asks "What was your 90+ delinquency rate as of December 31, 2024?", you must produce the exact number that was reportable at that time, not a retroactively corrected number.

**Model backtesting**: Prepayment and default models must be validated using data that was available at the time the prediction was made. Using corrected data would introduce look-ahead bias.

**Audit support**: Auditors may need to reproduce any report that was previously published. If you cannot reconstruct historical states, you face audit findings.

I implement point-in-time capability through two mechanisms:

1. **Monthly snapshots**: The `loan_monthly_snapshot` table stores the full state as reported for each period. A simple filter on `reporting_period = '2024-12-01'` returns the December snapshot.

2. **Bi-temporal or system-versioned tables**: For cases where corrections are applied after initial load, I use SQL Server temporal tables or Snowflake Time Travel to distinguish between the "original" view and the "corrected" view. This supports both "what was reported" and "what is currently known" for any historical period.

The key design principle is: never overwrite historical data. Always append or version it.

### Q3: How would you build a vintage analysis query for prepayment speeds?

**Answer**: Vintage analysis tracks cohorts of loans grouped by origination period as they age. For prepayment speeds:

1. **Define the cohort**: Group loans by origination year (or year-quarter for finer granularity) from the loan dimension table.

2. **Calculate SMM per cohort per seasoning month**: For each cohort and each month of age, compute the Single Monthly Mortality rate as (prepayments in the month) / (beginning of month UPB). The beginning-of-month UPB is the prior month's ending UPB.

3. **Annualize to CPR**: Convert SMM to Conditional Prepayment Rate using the standard formula: CPR = 1 - (1 - SMM)^12.

4. **Plot seasoning curves**: The output is a table with columns (vintage, seasoning_month, SMM, CPR) that can be visualized as line charts showing how prepayment speeds evolve as loans season.

The query joins the loan dimension (for origination date) to the monthly snapshot (for current_upb and prepayment amounts), with a self-join to the prior month for the beginning balance. I use `loan_age` as the seasoning axis rather than calendar date, which aligns different vintages to the same x-axis for direct comparison.

Performance considerations: This query scans a large portion of the fact table, so aggregate pre-computation is strongly recommended. I would build an `agg_vintage_monthly` table during the ETL that pre-computes SMM and CPR by vintage and seasoning month.

### Q4: What strategies would you use to compress MBS time-series data?

**Answer**: I use a layered compression strategy:

**Columnar storage**: The foundation. Columnar formats (columnstore indexes, Parquet) are dramatically more effective than row-based storage for MBS data because columns like `delinquency_status` (8 distinct values), `state_code` (51 values), and `property_type` (6 values) compress to near-zero with dictionary encoding. Numeric columns like UPB compress well with delta encoding when sorted by loan_id within a partition.

**Sort order optimization**: Physical sort order matters enormously for compression. I cluster data by `(reporting_period, pool_id)` so that within each partition, similar loans (same pool, similar attributes) are adjacent, maximizing run-length encoding effectiveness.

**Right-sized data types**: Switching from VARCHAR(255) to CHAR(2) for state codes, from INT to SMALLINT for loan age, and from FLOAT to DECIMAL for financial values reduces raw data size by 60-80% before compression even starts.

**Tiered compression**: Recent data (last 24 months) uses standard columnstore compression for a good balance of compression ratio and query speed. Older data uses archive compression (e.g., COLUMNSTORE_ARCHIVE in SQL Server) which provides 2-3x additional compression at the cost of slower decompression. Archival data (5+ years) is offloaded to Parquet with ZSTD compression in a data lake.

**Aggregate tables**: The best compression is not storing data at all. Pre-computed aggregates at the pool and cohort level eliminate the need to query billions of loan-level rows for most analytical workloads.

Typical results: 15 TB of uncompressed MBS data compresses to ~1-1.5 TB in the hot tier with columnstore, ~500 GB in the warm tier with archive compression, and ~200 GB in Parquet for cold storage.

### Q5: How would you handle late-arriving corrections to historical MBS data?

**Answer**: Late corrections are inevitable in MBS -- servicers submit corrections, agencies publish revised disclosure files, and reconciliation processes identify errors that need fixing.

My approach:

1. **Never overwrite in place**: Use system-versioned temporal tables (SQL Server) or bi-temporal design so the original value and the corrected value are both preserved. The `sys_start` and `sys_end` columns track when each version was the "truth."

2. **Correction tracking table**: Log every correction with the loan ID, reporting period, field name, old value, new value, correction source, correction date, and reason. This provides a complete audit trail independent of the temporal mechanism.

3. **Impact assessment**: Before applying corrections, run an impact analysis. How many loans are affected? What is the UPB variance? Does this change any published pool factors? If the impact is material, it may require a formal restatement process.

4. **Downstream propagation**: Maintain a dependency graph. When a loan snapshot is corrected, flag all dependent aggregates, reports, and analytics for refresh. Automated pipelines re-compute affected aggregates.

5. **Window management**: Define a correction window (e.g., corrections within 30 days of initial load are processed automatically; corrections after 30 days require approval). This prevents unbounded reprocessing.

6. **As-of-date querying**: Enable queries like "Show me the data as we knew it on February 15" using temporal table FOR SYSTEM_TIME AS OF clauses. This is critical for reproducing historical reports accurately.

---

## Tips

1. **Partition by reporting period -- always**: This is the single highest-impact design decision for MBS time-series data. It enables partition pruning for queries, partition swap for loads, and partition-level archival. There is no valid reason to skip this.

2. **Separate static from dynamic attributes**: Origination attributes (original FICO, LTV, loan purpose) never change and should live in a dimension table. Monthly performance attributes (UPB, delinquency, rate) change every month and belong in the snapshot fact table. Repeating static attributes in every snapshot row wastes enormous storage.

3. **Pre-compute aggregates for common query patterns**: If 80% of dashboard queries aggregate to pool-level or vintage-level, build those aggregate tables during ETL rather than scanning billions of loan-level rows every time.

4. **Use columnar storage for the fact table**: MBS snapshot data is an ideal use case for columnar storage -- wide tables, low-cardinality columns, aggregation-heavy queries. Compression ratios of 10:1 or better are typical.

5. **Design for the seasoning axis**: Many MBS analyses use loan age (months since origination) as the x-axis rather than calendar date. Store `loan_age` explicitly in the snapshot rather than forcing every query to calculate it from origination date.

6. **Implement bi-temporal tracking from day one**: Adding correction tracking after the fact is painful. Start with system-versioned temporal tables or bi-temporal design so you can always answer "what did we know, and when did we know it."

7. **Monitor partition skew**: If some reporting periods have significantly more data than others (e.g., a large portfolio acquisition), the uneven partition sizes can affect query performance and load times. Consider sub-partitioning if needed.

8. **Right-size your data types**: At billions of rows, the difference between INT (4 bytes) and SMALLINT (2 bytes) for a field like loan_age translates to gigabytes of storage and measurable query performance impact.

9. **Test queries at production scale**: A vintage analysis query that runs in 2 seconds on 1 million rows may take 30 minutes on 3 billion rows. Always benchmark with realistic data volumes and tune partitioning, indexing, and aggregation accordingly.

10. **Archive old data, do not delete it**: Regulatory requirements in the mortgage industry typically require 7+ years of data retention. Implement a tiered storage strategy that moves old data to cheaper, more compressed storage rather than deleting it.
