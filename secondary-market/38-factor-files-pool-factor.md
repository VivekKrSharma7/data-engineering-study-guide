# Factor Files & Pool Factor Calculations

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. Pool Factor Definition

The pool factor is a decimal number between 0 and 1 that represents the proportion of the original principal balance that remains outstanding for a mortgage-backed security.

**Formula:**

```
Pool Factor = Current Remaining Principal Balance / Original Principal Balance
```

**Example:**
```
Original pool balance:  $500,000,000
Current pool balance:   $375,000,000
Pool factor:            $375,000,000 / $500,000,000 = 0.75000000
```

The pool factor is essential because MBS trade based on their original face value. An investor who owns $1,000,000 in original face of a pool with a 0.75 factor actually has $750,000 in remaining principal. The factor converts between face (par) amount and current economic exposure.

### 2. How Pool Factors Change

The pool factor decreases over time due to three forces:

| Driver | Description | Impact on Factor |
|--------|-------------|-----------------|
| **Scheduled amortization** | Regular principal payments per the amortization schedule | Gradual, predictable decrease |
| **Prepayments** | Borrowers paying off loans early (refinance, home sale, curtailments) | Accelerates factor decline |
| **Liquidations** | Defaults resulting in principal reduction (short sales, REO, charge-offs) | Reduces factor; losses allocated to specific tranches in CMOs |

**Factor cannot increase** for standard pass-throughs. For some deal structures (e.g., with capitalized interest or negative amortization), the collateral balance can temporarily increase, but this is rare in current production.

### 3. Monthly Factor Updates

Pool factors are updated monthly, following the remittance cycle:

```
Timeline (for a typical Fannie Mae MBS):
─────────────────────────────────────────
Month N:
  Day 1-28     Borrower payments collected
  Day ~25      Distribution to investors (Month N distribution date)

Month N+1:
  Day ~4       Fannie Mae publishes updated factors
               (reflecting Month N paydowns)
  Day ~5-10    Bloomberg, Intex, other vendors update factor data
  Day ~25      Month N+1 distribution date
```

**Key point:** The factor published in a given month reflects principal reductions that occurred in the prior month. There is always a one-month reporting lag.

### 4. Factor File Sources

#### Agency Disclosures

| Source | Description | Format | Frequency |
|--------|-------------|--------|-----------|
| **Fannie Mae PoolTalk / ESR** | Monthly pool-level disclosures including factors | Flat file, API | Monthly, ~4th business day |
| **Freddie Mac** | Monthly pool-level factor data | Flat file, API | Monthly, ~4th business day |
| **Ginnie Mae** | HMBS and standard MBS factor data | Flat file, SFTP | Monthly |
| **Trustees (PLS)** | Distribution date statements for private-label deals | PDF, CSV, XML | Monthly, on distribution date |

#### Vendor Sources

| Vendor | Description |
|--------|-------------|
| **Bloomberg** | `POOL_FACTOR` field updated monthly; also publishes factor history |
| **Intex** | Factor data embedded in deal models; updated monthly |
| **Black Knight (ICE)** | Factor data through McDash and servicing platforms |
| **eMBS** | Agency MBS factor and disclosure data aggregator |

### 5. Factor File Structure

A typical agency factor file contains:

```
CUSIP          | POOL_NUMBER | FACTOR_DATE | POOL_FACTOR  | CURRENT_UPB      | ORIGINAL_UPB
3138ABCD5      | AB1234      | 2025-06-01  | 0.74532100   | 372,660,500.00   | 500,000,000.00
3138EFGH9      | CD5678      | 2025-06-01  | 0.62145300   | 186,435,900.00   | 300,000,000.00
3140WXYZ2      | EF9012      | 2025-06-01  | 0.91234500   | 456,172,500.00   | 500,000,000.00
```

**Common fields in factor files:**

| Field | Description |
|-------|-------------|
| **CUSIP** | 9-character security identifier |
| **Pool Number** | Agency pool number |
| **Factor Date** | As-of date for the factor |
| **Pool Factor** | Decimal to 8 places |
| **Current UPB** | Dollar amount of remaining balance |
| **Original UPB** | Dollar amount at issuance |
| **WA Coupon** | Weighted average note rate |
| **WA Maturity** | Weighted average remaining term |
| **WA Loan Age** | Weighted average age (WALA) in months |
| **Loan Count** | Number of active loans in the pool |
| **CPR (1-month)** | Single-month conditional prepayment rate |
| **Factor Change** | Current factor minus prior factor |

### 6. Calculating Pool Factor

#### Basic Calculation

```
Factor(t) = UPB(t) / Original_UPB
```

#### Deriving Factor from Monthly Cash Flows

```
Factor(t) = Factor(t-1) - (Scheduled_Principal(t) + Prepayments(t) + Losses(t)) / Original_UPB
```

#### Calculating Current Position Value from Factor

```
Current_Value = Original_Face_Owned × Current_Factor × Price / 100

Example:
  Original face owned:  $5,000,000
  Current factor:       0.72000000
  Market price:         101.50 (per $100 par)

  Current principal:    $5,000,000 × 0.72 = $3,600,000
  Market value:         $3,600,000 × 101.50 / 100 = $3,654,000
```

### 7. Factor vs. Face Value

Understanding the distinction between face and current value is critical:

| Concept | Definition | Example |
|---------|-----------|---------|
| **Original Face** | The par amount at issuance | $10,000,000 |
| **Current Face** | Original face × current factor | $10,000,000 × 0.65 = $6,500,000 |
| **Market Value** | Current face × price / 100 | $6,500,000 × 102.00 / 100 = $6,630,000 |
| **Settlement Amount** | Current face at settlement factor × price / 100 + accrued interest | Depends on settlement date and factor |

**Settlement factor complication:** When an MBS trade settles, the factor used for settlement is the most recently published factor, not the factor as of the trade date. This is because factors are published with a lag. Trades executed before the new factor is published will settle at the old factor.

```
Trade date:           June 5
Settlement date:      June 12
May factor published: June 4  (reflects April paydowns)
June factor:          Not yet published

Settlement uses:      May factor (most recent available)
```

This means the buyer receives a slightly different principal amount than expected. The difference is handled through "factor risk" or "factor delay" in trading.

### 8. Using Factors for Position Tracking

In a portfolio management system, factors are essential for accurate position tracking:

```sql
-- Daily position valuation using factors
SELECT
    p.portfolio_id,
    p.cusip,
    p.original_face,
    f.pool_factor,
    p.original_face * f.pool_factor AS current_face,
    p.original_face * f.pool_factor * m.clean_price / 100 AS market_value,
    p.original_face * f.pool_factor * m.clean_price / 100
        + p.original_face * f.pool_factor * (m.accrued_days * t.coupon_rate / 360) AS dirty_value
FROM positions p
JOIN latest_factors f ON p.cusip = f.cusip
JOIN market_prices m ON p.cusip = m.cusip AND m.price_date = CURRENT_DATE
JOIN dim_tranche t ON p.cusip = t.tranche_cusip;
```

**Monthly position reconciliation:**

```
Expected current face = Prior month current face
                      - Principal received this month
                      - Loss principal allocated this month

Actual current face   = Original face × new factor

Difference should be zero (or within tolerance for rounding).
```

### 9. Factor Data in Databases

#### Schema Design for Factor History

```sql
CREATE TABLE fact_pool_factor (
    factor_id           BIGINT PRIMARY KEY,
    cusip               CHAR(9) NOT NULL,
    factor_date         DATE NOT NULL,
    pool_factor         DECIMAL(12,10) NOT NULL,
    current_upb         DECIMAL(18,2),
    original_upb        DECIMAL(18,2),
    prior_factor        DECIMAL(12,10),
    factor_change       DECIMAL(12,10),
    scheduled_principal DECIMAL(18,2),
    prepayment_principal DECIMAL(18,2),
    loss_principal      DECIMAL(18,2),
    loan_count          INT,
    wa_coupon           DECIMAL(8,5),
    wa_maturity_months  INT,
    wa_loan_age_months  INT,
    cpr_1m              DECIMAL(8,5),
    cpr_3m              DECIMAL(8,5),
    cpr_6m              DECIMAL(8,5),
    cpr_12m             DECIMAL(8,5),
    source              VARCHAR(20),
    load_timestamp      TIMESTAMP,
    UNIQUE (cusip, factor_date)
);

-- Index for common query patterns
CREATE INDEX idx_factor_cusip_date ON fact_pool_factor (cusip, factor_date DESC);
CREATE INDEX idx_factor_date ON fact_pool_factor (factor_date);
```

#### Optimized Design for Large-Scale Factor Data

For firms tracking factors across hundreds of thousands of CUSIPs:

```sql
-- Partitioned by factor_date for efficient monthly loading and querying
CREATE TABLE fact_pool_factor (
    cusip               CHAR(9) NOT NULL,
    factor_date         DATE NOT NULL,
    pool_factor         DECIMAL(12,10) NOT NULL,
    current_upb         DECIMAL(18,2),
    original_upb        DECIMAL(18,2),
    source              VARCHAR(20),
    load_timestamp      TIMESTAMP
)
PARTITION BY RANGE (factor_date);

-- Create monthly partitions
CREATE TABLE fact_pool_factor_202506 PARTITION OF fact_pool_factor
    FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
```

### 10. Reconciliation

Factor reconciliation is a critical data quality process:

#### Factor-to-UPB Reconciliation

```sql
-- Verify factor × original UPB = current UPB
SELECT
    cusip,
    factor_date,
    pool_factor,
    original_upb,
    current_upb,
    pool_factor * original_upb AS calculated_upb,
    ABS(current_upb - pool_factor * original_upb) AS difference
FROM fact_pool_factor
WHERE ABS(current_upb - pool_factor * original_upb) > 1.00  -- tolerance: $1
  AND factor_date = '2025-06-01';
```

#### Cross-Source Reconciliation

```sql
-- Compare factors from two sources (e.g., agency vs Bloomberg)
SELECT
    a.cusip,
    a.factor_date,
    a.pool_factor AS agency_factor,
    b.pool_factor AS bloomberg_factor,
    ABS(a.pool_factor - b.pool_factor) AS factor_difference
FROM fact_pool_factor a
JOIN fact_pool_factor_bloomberg b
    ON a.cusip = b.cusip
    AND a.factor_date = b.factor_date
WHERE ABS(a.pool_factor - b.pool_factor) > 0.00000100  -- tolerance: 0.0001%
ORDER BY factor_difference DESC;
```

#### Month-over-Month Factor Consistency

```sql
-- Flag pools where factor increased (should never happen for standard MBS)
SELECT
    cusip,
    factor_date,
    pool_factor,
    prior_factor,
    pool_factor - prior_factor AS factor_change
FROM fact_pool_factor
WHERE pool_factor > prior_factor
  AND prior_factor IS NOT NULL
  AND factor_date = '2025-06-01';
```

---

## Real-World Examples

### Example 1: Automated Factor Ingestion Pipeline

**Scenario:** Build a daily pipeline that ingests agency factor files and updates the position management system.

**Pipeline:**

```
1. Monitor agency SFTP/API for new factor files (scheduled ~4th business day)
2. Download and stage raw factor file
3. Parse file (handle format variations between Fannie, Freddie, Ginnie)
4. Validate:
   a. Factor between 0 and 1
   b. Factor <= prior month factor (for standard pools)
   c. Factor × original UPB = reported current UPB (within tolerance)
   d. No missing CUSIPs vs. prior month (unless pool paid off)
5. Load into fact_pool_factor table
6. Calculate derived fields (factor change, CPR)
7. Update position system:
   a. current_face = original_face × new_factor
   b. Recalculate market values
   c. Generate P&I receivable entries (expected principal paydown)
8. Run reconciliation:
   a. Factor source comparison (agency vs. Bloomberg vs. Intex)
   b. Position-level: expected paydown vs. actual cash received
9. Generate exception report for operations team
```

### Example 2: CPR Calculation from Factors

The Conditional Prepayment Rate (CPR) can be derived from factor changes:

```
SMM (Single Monthly Mortality) = 1 - (Factor(t) / Factor(t-1)) adjusted for scheduled amortization

More precisely:
  Scheduled_Factor(t) = Factor(t-1) - (Scheduled_Principal(t) / Original_UPB)
  SMM = 1 - (Factor(t) / Scheduled_Factor(t))
  CPR = 1 - (1 - SMM)^12

Example:
  Factor(May) = 0.80000000
  Factor(June) = 0.78500000
  Scheduled principal = $5,000,000
  Original UPB = $500,000,000

  Scheduled_Factor = 0.80000000 - (5,000,000 / 500,000,000) = 0.79000000
  SMM = 1 - (0.78500000 / 0.79000000) = 1 - 0.993671 = 0.006329
  CPR = 1 - (1 - 0.006329)^12 = 1 - 0.92683 = 0.07317 = 7.317%
```

```sql
-- SQL implementation of CPR from factor history
WITH factor_pairs AS (
    SELECT
        cusip,
        factor_date,
        pool_factor AS current_factor,
        LAG(pool_factor) OVER (PARTITION BY cusip ORDER BY factor_date) AS prior_factor,
        scheduled_principal,
        original_upb
    FROM fact_pool_factor
)
SELECT
    cusip,
    factor_date,
    current_factor,
    prior_factor,
    prior_factor - (scheduled_principal / original_upb) AS scheduled_factor,
    1 - (current_factor / (prior_factor - scheduled_principal / original_upb)) AS smm,
    1 - POWER(
        current_factor / (prior_factor - scheduled_principal / original_upb),
        12
    ) AS cpr
FROM factor_pairs
WHERE prior_factor IS NOT NULL
  AND prior_factor > 0;
```

### Example 3: Settlement Factor Determination

**Scenario:** A trader sells $10M original face of FNMA 4.0% pool on June 3 for settlement June 11. Which factor applies?

```
June 1:  Trade ticket created: Sell $10M original face FNMA 4.0%
June 3:  Trade confirmed; settlement June 11
June 4:  Fannie Mae publishes June factor (reflecting May paydowns)
         New factor: 0.68234500 (prior: 0.69712300)
June 11: Settlement

Settlement uses June factor (0.68234500) because it was published before settlement date.

Settlement amount calculation:
  Current face:    $10,000,000 × 0.68234500 = $6,823,450.00
  Price: 101.25
  Principal value: $6,823,450.00 × 101.25 / 100 = $6,908,743.13
  Accrued interest: $6,823,450.00 × 4.00% × (10/360) = $7,581.61
  Total settlement: $6,908,743.13 + $7,581.61 = $6,916,324.74
```

**Data engineering implication:** The settlement system must track which factor was "in effect" on the settlement date and handle the timing of factor publication. If the new factor is published between trade date and settlement date, the settlement amount changes.

---

## Common Interview Questions & Answers

### Q1: What is a pool factor and why is it important?

**Answer:** A pool factor is a decimal between 0 and 1 representing the ratio of the current remaining principal balance to the original principal balance of a mortgage-backed security. It is calculated as:

```
Pool Factor = Current UPB / Original UPB
```

It is important for three reasons:
1. **Position valuation**: MBS positions are tracked in original face amount. The factor converts face to current principal exposure. Without accurate factors, portfolio market values would be wrong.
2. **Settlement**: When MBS trade, the settlement amount is calculated using original face times the factor times the price. An incorrect factor leads to incorrect settlement amounts.
3. **Cash flow tracking**: The change in factor from month to month represents the total principal reduction (amortization + prepayments + losses). This drives prepayment rate calculations (CPR) and return analytics.

Factors are published monthly by agencies and trustees with a one-month lag. A data engineer must build pipelines that ingest factor files promptly, validate them, and propagate updated factors to all downstream systems (positions, accounting, risk).

### Q2: How would you design a database to store historical factor data for 500,000+ CUSIPs?

**Answer:** At 500,000+ CUSIPs with monthly factors, the table grows by ~500,000 rows per month (6 million per year). Here is my design:

**Table design:**
- Partition by `factor_date` (monthly range partitions) for efficient loading and time-based queries
- Cluster/sort key on `cusip` within each partition for efficient CUSIP lookups
- Use `DECIMAL(12,10)` for the factor to preserve precision (factors have up to 8 significant decimal places)

**Indexing:**
- Primary access pattern: single CUSIP, full history -> index on `(cusip, factor_date)`
- Secondary access pattern: all CUSIPs for a given month -> partition pruning on `factor_date`

**Data loading:**
- Monthly bulk insert into the appropriate partition
- Idempotent load: `INSERT ... ON CONFLICT (cusip, factor_date) DO UPDATE` to handle reloads and corrections

**Retention:**
- Keep full history (factors do not change retroactively, so storage is bounded)
- Compress older partitions with columnar compression (Parquet or database-native compression)

**Estimated storage:** 500,000 CUSIPs x 12 months x ~200 bytes/row = ~1.2 GB/year uncompressed. Very manageable, even for 20+ years of history.

### Q3: How do you reconcile factor data from multiple sources?

**Answer:** I implement a multi-source reconciliation framework:

1. **Golden source designation**: Agency disclosures (Fannie Mae, Freddie Mac, Ginnie Mae) are the authoritative source for their respective pools. Trustee reports are authoritative for private-label deals.

2. **Cross-source comparison**: Load factors from the golden source and at least one secondary source (Bloomberg, Intex, eMBS). Compare at the CUSIP level with a tolerance of 0.00000100 (one-millionth). Differences beyond tolerance trigger investigation.

3. **Internal consistency checks**:
   - Factor x original UPB should equal reported current UPB (within $1 rounding tolerance)
   - Factor should be less than or equal to prior month factor
   - Factor should be zero for fully paid-off pools
   - Factor should not be exactly equal to prior month (unless the pool is extremely seasoned with minimal remaining balance)

4. **Timing reconciliation**: Different sources may publish at slightly different times. A one-day difference in publication can cause temporary mismatches that self-resolve.

5. **Exception workflow**: Generate a daily exception report showing all CUSIPs with source discrepancies. Categorize by severity (large factor difference = high priority) and route to operations for resolution.

### Q4: Explain how you would calculate CPR from factor data.

**Answer:** CPR (Conditional Prepayment Rate) is the annualized rate at which borrowers prepay their mortgages. It can be derived from monthly factor changes:

**Step 1**: Calculate the scheduled factor (what the factor would have been with only scheduled amortization, no prepayments or losses):
```
Scheduled_Factor(t) = Factor(t-1) - Scheduled_Principal(t) / Original_UPB
```

**Step 2**: Calculate SMM (Single Monthly Mortality), the monthly prepayment rate:
```
SMM = 1 - Factor(t) / Scheduled_Factor(t)
```

**Step 3**: Annualize to get CPR:
```
CPR = 1 - (1 - SMM)^12
```

The challenge for a data engineer is that scheduled principal is not always provided in factor files. In that case, I derive it from the pool's weighted average coupon, weighted average remaining term, and current balance using the standard amortization formula. This requires joining factor data with pool characteristic data.

I compute 1-month, 3-month, 6-month, and 12-month CPR by averaging SMMs over the respective periods and annualizing, which gives analysts multiple smoothing windows to assess prepayment trends.

### Q5: What happens when a factor file is late or contains errors?

**Answer:** Factor file delays and errors are operational realities that the pipeline must handle gracefully:

**Late factors:**
- Use the prior month's factor as a temporary placeholder. Flag all positions using stale factors in the valuation report.
- Implement a monitoring alert that fires if the factor file is not received by a configurable deadline (e.g., 6th business day of the month).
- When the factor arrives late, reprocess all dependent calculations: position values, P&I receivables, CPR, and any client reports.

**Erroneous factors:**
- Validation catches most errors: factor > prior factor, factor outside 0-1 range, factor x original UPB does not equal reported UPB.
- For suspected errors, hold the new factor in a quarantine state and continue using the prior factor until the error is confirmed or corrected.
- Agencies occasionally publish corrected factor files. The pipeline must support reloading factors for a specific CUSIP and date, triggering a recalculation cascade.
- Maintain a factor correction audit trail: store the original erroneous factor, the corrected factor, and the timestamp of the correction.

---

## Tips

1. **Precision matters**: Always store factors with at least 8 decimal places. Truncating to fewer decimals causes rounding errors that compound across large positions. A factor difference of 0.00000001 on a $1 billion pool is $10.

2. **Factor date vs. reporting period**: The factor date is typically the 1st of the month, but it reflects activity from the prior month. Be explicit about which month a factor represents to avoid off-by-one-month errors.

3. **Watch for zero-factor pools**: When a pool's factor reaches 0.00000000, the pool is fully paid off. Remove it from active monitoring but preserve the history. Some pools linger near zero (factor = 0.00000100) for months due to a single remaining loan.

4. **Factor files are the heartbeat of MBS operations**: Nearly every downstream system (trading, settlement, accounting, risk, compliance) depends on accurate, timely factors. Build your pipeline with high reliability and fast failure detection.

5. **Understand the settlement factor convention**: In TBA (to-be-announced) trading, the settlement factor is the one published closest to but before the settlement date. For specified pool trading, the same convention applies. Factor uncertainty between trade date and settlement date is a real source of operational risk.

6. **Cache the latest factor**: For real-time position queries, maintain a materialized view or cache of the latest factor per CUSIP. This avoids expensive joins to the full history table for routine valuation queries.

7. **CMO tranches have factors too**: While this guide focuses on pool-level factors, each tranche in a CMO also has its own factor. Tranche factors are driven by the payment waterfall, not just collateral performance. Ensure your pipeline handles both pool and tranche factors.
