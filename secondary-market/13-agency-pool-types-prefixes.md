# Agency Pool Types & Prefixes

[Back to Secondary Market Index](./README.md)

---

## Introduction

In the US secondary mortgage market, agency mortgage-backed securities (MBS) are organized into **pools** — groups of mortgage loans bundled together and securitized by one of the three government-sponsored or government-backed agencies: **Fannie Mae**, **Freddie Mac**, and **Ginnie Mae**. Every pool is assigned a **prefix** (sometimes called a pool type or pool prefix code) that encodes critical information about the underlying collateral: the product type, amortization term, loan size category, and other structural characteristics.

For data engineers working in mortgage analytics, understanding pool prefixes is essential. They serve as the primary key for mapping raw pool-level data to the correct product category, determining TBA (To-Be-Announced) eligibility, building aggregation pipelines, and ensuring accurate reporting. Misclassifying a pool prefix can cascade errors through prepayment models, risk analytics, and investor reporting systems.

---

## Key Concepts

### 1. What Is a Pool Prefix?

A pool prefix is a short alphanumeric code (typically 2 characters) assigned by the issuing agency at the time a pool is created. It tells market participants:

- **Issuing agency** (Fannie Mae, Freddie Mac, Ginnie Mae)
- **Product type** (fixed-rate, ARM, balloon, etc.)
- **Amortization term** (30-year, 20-year, 15-year, 10-year, etc.)
- **Loan balance category** (conforming, high-balance/super conforming, jumbo conforming, etc.)
- **Lender structure** (single-lender vs. multi-lender)
- **Program type** (HARP, RefiNow, UMBS, etc.)

### 2. Fannie Mae Pool Prefixes

Fannie Mae uses a well-defined set of two-character prefixes. Key examples include:

| Prefix | Product Description |
|--------|-------------------|
| **CL** | 30-year fixed-rate, standard balance |
| **CI** | 15-year fixed-rate, standard balance |
| **CT** | 20-year fixed-rate, standard balance |
| **CS** | 30-year fixed-rate, super conforming (high-balance / jumbo conforming) |
| **CJ** | 15-year fixed-rate, super conforming |
| **CU** | 20-year fixed-rate, super conforming |
| **CN** | 30-year fixed-rate, HARP (Home Affordable Refinance Program) |
| **CB** | 15-year fixed-rate, HARP |
| **AL** | 30-year ARM (adjustable-rate mortgage) |
| **AR** | ARM, various terms |
| **XS** | 30-year fixed, RefiNow / Refi Possible high-LTV pools |
| **BL** | 30-year fixed-rate, multi-lender mega pool |
| **BI** | 15-year fixed-rate, multi-lender mega pool |
| **MA** | Fannie Mae Megas (mega pools combining existing pools) |

**Important Notes on Fannie Mae Prefixes:**
- Fannie Mae transitioned to the **UMBS (Uniform Mortgage-Backed Security)** format starting June 3, 2019. Prefixes like CL, CI, CT continue but are now issued as UMBS.
- Some prefixes have been **superseded** (e.g., older prefixes used before the UMBS transition) and are no longer issued for new pools but still appear in historical data.
- Super conforming prefixes (CS, CJ, CU) identify loans that exceed the base conforming loan limit but fall within the high-cost area limit.

### 3. Freddie Mac Pool Prefixes

Freddie Mac similarly assigns two-character prefixes (often a letter followed by a number or two letters):

| Prefix | Product Description |
|--------|-------------------|
| **C1** | 30-year fixed-rate, standard (Gold PC, now UMBS) |
| **G1** | 30-year fixed-rate, standard (older Gold designation) |
| **Q1** | 30-year fixed-rate, super conforming / high-balance |
| **C2** | 15-year fixed-rate, standard |
| **G2** | 15-year fixed-rate (older Gold designation) |
| **Q2** | 15-year fixed-rate, super conforming |
| **C5** | 20-year fixed-rate, standard |
| **Q5** | 20-year fixed-rate, super conforming |
| **C9** | 10-year fixed-rate |
| **QA** | 30-year fixed, HARP |
| **QB** | 15-year fixed, HARP |
| **5A** | 5/1 ARM |
| **7A** | 7/1 ARM |
| **M1** | Freddie Mac Mega (30-year fixed) |
| **M2** | Freddie Mac Mega (15-year fixed) |

**Important Notes on Freddie Mac Prefixes:**
- With the UMBS transition, Freddie Mac pools use **mirror prefixes** that are fungible with corresponding Fannie Mae UMBS pools on the TBA market.
- Legacy Gold PCs (participation certificates) used G-series prefixes; newer issuance uses C-series under UMBS.
- Freddie Mac's prefix scheme changed materially with UMBS — data engineers must handle both legacy and current mappings.

### 4. Ginnie Mae Pool Prefixes

Ginnie Mae securities are backed by government-insured or government-guaranteed loans (FHA, VA, USDA, PIH). Ginnie Mae has two programs:

**GNMA I (Ginnie Mae I):**
- Single-issuer pools
- All loans from one issuer, same loan type, same interest rate
- Payment delay: 45 days

**GNMA II (Ginnie Mae II):**
- Multi-issuer pools allowed (also single-issuer)
- Loans may have varying interest rates (within a range)
- Payment delay: 50 days

| Prefix | Product Description |
|--------|-------------------|
| **SF** | Single-family, 30-year fixed, GNMA II |
| **MA** | Multi-family, GNMA I |
| **JB** | Jumbo pools (GNMA II) |
| **BD** | Buydown pools |
| **PL** | Manufactured housing / project loans |

Ginnie Mae prefix structures are more complex and include three-digit pool type codes in their data feeds. Common single-family pool type codes include:

- **SF30** — Single-family 30-year fixed
- **SF15** — Single-family 15-year fixed
- **SF20** — Single-family 20-year fixed
- **SFAR** — Single-family ARM

### 5. UMBS Pool Prefixes

The **Uniform Mortgage-Backed Security (UMBS)** was introduced in June 2019 to unify Fannie Mae and Freddie Mac MBS into a single, fungible security. Key points:

- Both Fannie Mae and Freddie Mac issue UMBS with aligned prefixes.
- UMBS pools trade on the TBA market as interchangeable securities regardless of issuer.
- The prefix identifies the product but no longer differentiates between the two GSEs at the TBA level.
- **Supers** (multi-pool securities combining UMBS pools from either or both agencies) have their own prefix designations.

Common UMBS-aligned prefixes:

| Term | Fannie Prefix | Freddie Prefix | Product |
|------|--------------|---------------|---------|
| 30-year | CL | C1 | Fixed-rate, standard balance |
| 15-year | CI | C2 | Fixed-rate, standard balance |
| 20-year | CT | C5 | Fixed-rate, standard balance |

### 6. Single-Lender vs. Multi-Lender Pools

- **Single-lender pools**: All loans in the pool originated by (or acquired from) a single seller/servicer. Most standard agency MBS pools are single-lender.
- **Multi-lender pools**: Loans from multiple originators aggregated into one pool. Ginnie Mae II explicitly supports multi-lender pools. Fannie Mae and Freddie Mac achieve multi-lender aggregation primarily through **mega pools** and **supers**.

**Why it matters for data engineering:**
- Single-lender pools allow servicer-level attribution of prepayment and credit performance.
- Multi-lender pools require disaggregation logic or loan-level data to attribute performance.
- Pool prefix alone can indicate whether a pool is a mega/multi-lender structure.

### 7. Mega Pools and Supers

A **mega pool** (or **super**) is a re-securitization that combines multiple underlying pools into a single larger security:

- **Fannie Mae Megas** (prefix MA or BL/BI): Combine multiple Fannie Mae pools of the same product type and coupon.
- **Freddie Mac Megas** (prefix M1, M2): Combine Freddie Mac pools.
- **UMBS Supers**: Can combine pools from both Fannie Mae and Freddie Mac.

Mega pools and supers increase liquidity and simplify portfolio management. For data engineers, they add a layer of complexity: you must resolve the mega/super down to its constituent pools (and ultimately to loan-level data) for accurate analytics.

### 8. Superseded Pool Types

Over the decades, both Fannie Mae and Freddie Mac have retired or superseded older pool prefixes:

- Freddie Mac's original **Gold PC** prefixes (G-series) were replaced by C-series under UMBS.
- Fannie Mae's pre-UMBS MBS prefixes were remapped when the single security initiative launched.
- HARP-specific prefixes (CN, CB, QA, QB) are no longer issued since HARP expired in December 2018, but pools with these prefixes still exist and pay down over time.

Data engineers must maintain a **historical prefix mapping table** that includes both active and superseded prefixes to handle legacy data correctly.

### 9. Pool Prefix to Product Mapping

Building a reliable prefix-to-product mapping is a core data engineering task. A typical mapping table includes:

| Column | Description |
|--------|-------------|
| `prefix` | The 2-character pool prefix code |
| `agency` | FNMA, FHLMC, GNMA |
| `product_type` | FIXED, ARM, BALLOON, HYBRID |
| `amort_term` | 360, 240, 180, 120 (months) |
| `balance_type` | CONFORMING, HIGH_BALANCE, JUMBO |
| `program` | STANDARD, HARP, REFI_NOW |
| `tba_eligible` | TRUE/FALSE |
| `is_mega` | TRUE/FALSE |
| `is_active` | TRUE/FALSE (still issued or superseded) |
| `effective_date` | Date prefix was introduced |
| `superseded_date` | Date prefix was retired (if applicable) |

### 10. How Pool Types Affect TBA Eligibility

The **TBA (To-Be-Announced)** market is the most liquid forward-trading market for agency MBS. Not all pool types are TBA-eligible:

**TBA-Eligible:**
- Standard 30-year, 20-year, 15-year fixed-rate pools (conforming balance)
- UMBS pools from both Fannie Mae and Freddie Mac

**NOT TBA-Eligible (Specified Pools / Stipulated Trades):**
- Super conforming / high-balance pools (CS, CJ, Q1, Q2, etc.)
- HARP pools (CN, CB, QA, QB)
- ARM pools
- Mega pools and supers (trade in their own market)
- Ginnie Mae pools with non-standard characteristics

Data engineers must flag TBA eligibility in pool-level datasets because it directly affects pricing, hedging, and portfolio analytics.

---

## Real-World Examples

### Example 1: Building a Pool Prefix Reference Table

A mortgage analytics platform ingests pool data from all three agencies daily. The data engineering team builds a centralized reference table:

```sql
CREATE TABLE dim_pool_prefix (
    prefix          VARCHAR(4) PRIMARY KEY,
    agency          VARCHAR(10) NOT NULL,
    product_type    VARCHAR(20) NOT NULL,
    amort_term      INT NOT NULL,
    balance_type    VARCHAR(20) NOT NULL,
    tba_eligible    BOOLEAN NOT NULL,
    is_mega         BOOLEAN NOT NULL,
    is_active       BOOLEAN NOT NULL,
    effective_date  DATE,
    superseded_date DATE
);

-- Sample rows
INSERT INTO dim_pool_prefix VALUES
('CL', 'FNMA', 'FIXED', 360, 'CONFORMING', TRUE, FALSE, TRUE, '2019-06-03', NULL),
('CS', 'FNMA', 'FIXED', 360, 'HIGH_BALANCE', FALSE, FALSE, TRUE, '2008-01-01', NULL),
('CI', 'FNMA', 'FIXED', 180, 'CONFORMING', TRUE, FALSE, TRUE, '2019-06-03', NULL),
('C1', 'FHLMC', 'FIXED', 360, 'CONFORMING', TRUE, FALSE, TRUE, '2019-06-03', NULL),
('G1', 'FHLMC', 'FIXED', 360, 'CONFORMING', TRUE, FALSE, FALSE, '1990-01-01', '2019-06-03'),
('Q1', 'FHLMC', 'FIXED', 360, 'HIGH_BALANCE', FALSE, FALSE, TRUE, '2008-01-01', NULL),
('SF', 'GNMA', 'FIXED', 360, 'GOVERNMENT', TRUE, FALSE, TRUE, '1983-01-01', NULL),
('MA', 'FNMA', 'MEGA', 360, 'CONFORMING', FALSE, TRUE, TRUE, '2005-01-01', NULL);
```

This table is joined to every pool-level fact table to enable consistent product classification across the platform.

### Example 2: Resolving Mega Pools to Constituent Pools

An analytics pipeline needs loan-level CPR (Conditional Prepayment Rate) for a Fannie Mae Mega pool (prefix MA). The data engineer:

1. Reads the mega pool factor file to identify the constituent pool IDs.
2. Joins each constituent pool ID to the loan-level disclosure data.
3. Aggregates prepayment speeds at the mega level, weighted by each constituent pool's remaining UPB.

```python
import pandas as pd

# Step 1: Load mega pool composition
mega_composition = pd.read_csv("mega_pool_composition.csv")
# Columns: mega_pool_id, constituent_pool_id, constituent_upb

# Step 2: Join to pool-level prepayment data
pool_speeds = pd.read_csv("pool_cpr_monthly.csv")
# Columns: pool_id, month, cpr_1m, cpr_3m

merged = mega_composition.merge(
    pool_speeds,
    left_on="constituent_pool_id",
    right_on="pool_id"
)

# Step 3: UPB-weighted CPR at mega level
merged["weighted_cpr"] = merged["constituent_upb"] * merged["cpr_1m"]
mega_cpr = merged.groupby(["mega_pool_id", "month"]).apply(
    lambda g: g["weighted_cpr"].sum() / g["constituent_upb"].sum()
).reset_index(name="mega_cpr_1m")
```

### Example 3: Filtering TBA-Eligible Pools for Hedge Analytics

A risk system needs to aggregate only TBA-eligible production for hedging purposes:

```sql
SELECT
    p.prefix,
    pp.agency,
    pp.amort_term,
    p.coupon,
    SUM(p.current_upb) AS total_upb,
    COUNT(DISTINCT p.pool_id) AS pool_count
FROM fact_pool_monthly p
JOIN dim_pool_prefix pp ON p.prefix = pp.prefix
WHERE pp.tba_eligible = TRUE
  AND p.as_of_date = '2026-02-01'
GROUP BY p.prefix, pp.agency, pp.amort_term, p.coupon
ORDER BY pp.agency, pp.amort_term, p.coupon;
```

---

## Common Interview Questions & Answers

### Q1: What is a pool prefix and why does it matter in mortgage data engineering?

**A:** A pool prefix is a short alphanumeric code assigned by the issuing agency (Fannie Mae, Freddie Mac, or Ginnie Mae) to each MBS pool. It encodes the product type (fixed vs. ARM), amortization term (30-year, 15-year, etc.), loan balance category (conforming vs. high-balance), and sometimes the program (HARP, mega pool). It matters because it is the primary classification key used to route pools into the correct analytical category — determining TBA eligibility, prepayment model selection, pricing benchmarks, and regulatory reporting buckets. A data engineer must maintain an accurate and up-to-date prefix mapping table to ensure downstream analytics are correct.

### Q2: What is the difference between Fannie Mae prefix CL and CS?

**A:** Both are 30-year fixed-rate Fannie Mae pools. **CL** contains loans with standard conforming balances (at or below the base conforming loan limit, which is $806,500 for 2025 in most areas). **CS** contains super conforming (high-balance) loans — those that exceed the base conforming limit but fall within the higher limit set for high-cost areas (up to $1,209,750 in 2025). The critical distinction: CL pools are **TBA-eligible** and trade in the liquid TBA market, while CS pools are **not TBA-eligible** and trade as specified pools at a different price. This difference affects liquidity, pricing, and hedging analytics.

### Q3: What changed with the UMBS transition and how does it affect pool prefixes?

**A:** Before June 2019, Fannie Mae MBS and Freddie Mac PCs (participation certificates) traded separately and were not interchangeable. The **Uniform Mortgage-Backed Security (UMBS)** initiative, implemented on June 3, 2019, created a single fungible security. After the transition, both Fannie Mae and Freddie Mac issue UMBS with harmonized prefix structures. Fannie Mae CL and Freddie Mac C1 pools are both deliverable into the same 30-year TBA contract. Freddie Mac retired its Gold PC G-series prefixes in favor of C-series. For data engineers, this means maintaining a prefix mapping that distinguishes pre-UMBS and post-UMBS pools, handling legacy Gold PCs that still exist in portfolios, and ensuring analytics correctly treat UMBS pools as fungible across issuers.

### Q4: How do you distinguish GNMA I from GNMA II pools, and why does it matter?

**A:** GNMA I pools are single-issuer, single-interest-rate pools with a 45-day payment delay. GNMA II pools can be multi-issuer (multiple originators contributing loans to one pool) with varying interest rates within a range and a 50-day payment delay. In the data, the pool prefix and program indicator fields distinguish them. The 5-day difference in payment delay affects cash flow modeling, and the multi-issuer nature of GNMA II affects servicer attribution analysis. Data engineers must account for these differences when building prepayment and cash flow models.

### Q5: What is a mega pool and how would you handle it in a data pipeline?

**A:** A mega pool is a re-securitization that combines multiple underlying MBS pools of the same product type and coupon into a single larger security. Fannie Mae Megas (prefix MA), Freddie Mac Megas (M1, M2), and UMBS Supers are common examples. In a data pipeline, you need a **composition table** that maps each mega pool ID to its constituent pool IDs and their respective UPB shares. For analytics, you must "look through" the mega to its underlying pools (and potentially to loan-level data) to compute accurate prepayment speeds, credit metrics, and weighted-average characteristics. The pipeline typically: (1) ingests the mega composition file monthly, (2) resolves constituent pools, (3) joins to pool-level or loan-level data, and (4) aggregates metrics back up to the mega level using UPB-weighted calculations.

### Q6: Why are some pool types not TBA-eligible? How do you flag this in your data model?

**A:** TBA eligibility requires that pools meet standardized criteria so buyers and sellers can trade them without specifying exact pool IDs. Pools that deviate from standard characteristics — such as super conforming/high-balance pools (larger loans with different prepayment profiles), HARP pools (high-LTV refinances), ARMs, or mega pools — are excluded because their cash flow behavior differs materially from the standard TBA cohort. In the data model, I add a boolean `tba_eligible` flag in the pool prefix dimension table. This flag is joined to pool-level fact tables so that any downstream query or model can easily filter for TBA-eligible production. The flag is derived from the combination of prefix, agency, and balance type.

### Q7: How would you handle superseded pool prefixes in a historical dataset?

**A:** Superseded prefixes (like Freddie Mac's G1, which was replaced by C1 under UMBS) still appear in historical data because those pools continue to exist and pay down. I would maintain a prefix mapping table with `is_active` and `superseded_date` fields. For historical time-series analysis, I use the prefix that was valid at each point in time. For current reporting, I may map superseded prefixes to their modern equivalents using a `successor_prefix` column. The key is never to drop or ignore superseded prefixes — they represent real securities that investors still hold. I also add data quality checks that alert when an unexpected or unknown prefix appears in an incoming feed.

### Q8: A new pool prefix appears in tomorrow's data feed that is not in your mapping table. What do you do?

**A:** First, the pipeline should have a data quality check that detects unknown prefixes and raises an alert rather than silently failing or dropping records. Upon receiving the alert, I would: (1) check the agency's official prefix documentation and recent bulletins for announcements of new prefixes, (2) consult the agency's data dictionary or contact the agency's help desk, (3) classify the new prefix with all required attributes (product type, term, balance type, TBA eligibility, etc.), (4) add it to the mapping table, and (5) reprocess any affected records. I would also add a process to periodically review agency announcements proactively so new prefixes are added before they appear in data feeds.

---

## Tips

1. **Maintain a single source of truth for prefix mappings.** Store your pool prefix reference table in a version-controlled configuration or database. Every pipeline and report should reference this single table rather than hard-coding prefix logic.

2. **Subscribe to agency announcements.** Fannie Mae, Freddie Mac, and Ginnie Mae publish bulletins when new prefixes are introduced or existing ones change. Build a process to review these quarterly at minimum.

3. **Always include superseded prefixes.** Legacy pools with retired prefixes still exist in portfolios and data feeds. Your mapping table must cover the full history, not just currently-issued prefixes.

4. **Test TBA eligibility logic rigorously.** Errors in TBA classification can cause significant pricing and hedging mistakes. Validate your TBA-eligible flag against published agency guidelines and actual TBA delivery data.

5. **Handle the UMBS transition as a data modeling event.** Pools issued before June 2019 and after have different fungibility characteristics. Your data model should be able to distinguish pre-UMBS and post-UMBS issuance while still allowing unified analytics where appropriate.

6. **Build automated data quality checks for prefix fields.** Validate that every pool record has a recognized prefix, that the prefix is consistent with other pool attributes (e.g., a CL pool should have a 30-year term), and that no null or malformed prefixes slip through.

7. **Document the prefix-to-product mapping logic.** This is a critical piece of institutional knowledge. Ensure it is well-documented so that new team members, auditors, and model validators can understand how pools are classified.

8. **Use prefix as a partitioning or indexing key.** In large pool-level datasets, prefix is an excellent partition or index column because most analytical queries filter by product type, which is directly encoded in the prefix.

---
