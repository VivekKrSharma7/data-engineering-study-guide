# eMBS and Loan-Level Disclosure Data

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. eMBS Platform Overview

eMBS (Electronic MBS) is a leading data aggregator and distributor for agency mortgage-backed securities disclosure data. It serves as a centralized platform that collects, normalizes, and redistributes data published by the three agencies: Fannie Mae, Freddie Mac, and Ginnie Mae.

**Core Value Proposition:**

- **Normalization:** Each agency publishes data in its own format, with different field names, layouts, and delivery schedules. eMBS normalizes this into a consistent schema, allowing users to analyze agency MBS across all three issuers using a single data model.
- **Timeliness:** eMBS processes and redistributes agency data within hours of publication, providing faster access than working directly with each agency's raw files.
- **Historical Archive:** eMBS maintains a complete historical archive of agency disclosure data going back to the inception of disclosure programs.

**User Base:** Broker-dealers, asset managers, hedge funds, GSEs, rating agencies, data vendors (including Bloomberg, which sources some MBS data from eMBS), and analytics firms.

### 2. Agency Disclosure: What Gets Published

The agencies (Fannie Mae, Freddie Mac, Ginnie Mae) are required to disclose information about the mortgage pools backing their MBS to promote transparency and facilitate secondary market trading.

**Levels of Disclosure:**

| Level | Description | Update Frequency |
|---|---|---|
| Pool-Level (Issuance) | Characteristics of the pool at issuance: original face, coupon, WAC, WAM, weighted average LTV, weighted average FICO, geographic distribution, loan count | At issuance, then monthly updates |
| Loan-Level | Individual loan attributes and monthly performance for every loan in a pool | Monthly |
| Factor Data | The pool factor (remaining balance / original balance) for each pool | Monthly (around the 4th-6th business day) |
| Remittance Data | Cash flows paid to investors: scheduled principal, unscheduled principal (prepayments), interest, and losses | Monthly |
| Supplemental | Additional data such as modification details, forbearance status, delinquency breakdowns | Monthly or quarterly |

### 3. Pool-Level Data

Pool-level data provides summary statistics for each agency MBS pool.

**Key Pool-Level Fields:**

| Field | Description |
|---|---|
| Pool Number / CUSIP | Unique identifier for the pool |
| Original Face | Total original principal balance of the pool at issuance |
| Current Face | Current outstanding principal balance |
| Factor | Current face / Original face |
| Pool Coupon (Pass-Through Rate) | The interest rate paid to MBS investors |
| WAC (Weighted Average Coupon) | Average note rate of the underlying loans, weighted by balance |
| WAM (Weighted Average Maturity) | Average remaining term in months |
| WALA (Weighted Average Loan Age) | Average seasoning in months |
| Weighted Average LTV | Balance-weighted average LTV at origination |
| Weighted Average FICO | Balance-weighted average FICO at origination |
| Loan Count | Number of active loans in the pool |
| Geographic Distribution | Percentage of pool balance by state (top states) |
| Servicer | Name of the servicer(s) |
| Issue Date | Date the pool was issued |
| Maturity Date | Scheduled final maturity date |

**Pool Types by Agency:**

- **Fannie Mae:** MBS (single-class pass-through), Megas (resecuritizations), REMICs (structured tranches). Pool prefixes indicate product type (CL = 30yr fixed, CI = 15yr fixed, CT = 20yr fixed, etc.).
- **Freddie Mac:** Participation Certificates (PCs), Giants, REMICs (structured). Pool prefixes also encode product type.
- **Ginnie Mae:** Ginnie I (single-issuer pools, 15-day delay) and Ginnie II (multi-issuer pools, 20-day delay). Pool prefixes start with issuer number.

### 4. Loan-Level Disclosure Data

Loan-level disclosure is the most granular data published by the agencies. Each agency has its own program:

**Fannie Mae Loan-Level Disclosure:**

- **Dataset:** Published monthly, covers virtually all Fannie Mae single-family MBS.
- **Key Fields:** Loan sequence number, origination date, original UPB, current UPB, original LTV, original CLTV, FICO, DTI, first-time homebuyer flag, loan purpose (purchase/refi/cash-out), property type, occupancy, state, ZIP (3-digit), number of units, channel (retail/broker/correspondent/TPO), loan status (current/30/60/90+/foreclosure), modification flag, forbearance flag, zero balance code (prepaid/third-party sale/short sale/REO/etc.), zero balance effective date.
- **Delivery:** Monthly flat files via Fannie Mae's data portal (available to registered users). Files are pipe-delimited with fixed field positions.
- **Historical Depth:** Data goes back to 1999 for acquisitions, with monthly performance from 2000 onward.

**Freddie Mac Loan-Level Disclosure:**

- **Dataset:** Similar scope and depth to Fannie Mae, covering Freddie Mac single-family MBS.
- **Key Fields:** Very similar to Fannie Mae but with some differences in field naming, coding conventions, and available attributes. Freddie Mac's Single Family Loan-Level Dataset includes origination and monthly performance files.
- **Delivery:** Available through Freddie Mac's data portal. Also pipe-delimited flat files.

**Ginnie Mae Loan-Level Disclosure:**

- **Dataset:** Covers FHA, VA, USDA, and PIH (Public and Indian Housing) loans in Ginnie Mae pools.
- **Unique Aspects:** Ginnie Mae pools include government-insured/guaranteed loans, which have different credit characteristics (lower FICOs, higher LTVs, FHA mortgage insurance) and different default resolution mechanisms (FHA claims process).
- **Delivery:** Through Ginnie Mae's disclosure portal (GNMA_Disclosure).

### 5. Factor Data

The pool factor is the single most important number for MBS settlement and accounting.

**Definition:**

```
Factor = Current Remaining Principal Balance / Original Principal Balance
```

**Publication Schedule:**

- Factors are published monthly, typically around the 4th-6th business day of the month.
- The factor reflects the pool balance as of the prior month's record date.
- Factor publication triggers the calculation of paydowns (current factor vs. prior factor) that are settled on the next MBS payment date.

**Factor Calculation Example:**

```
Original Face:        $100,000,000
Prior Month Factor:   0.85432100
Current Month Factor: 0.84210500

Paydown = Original Face * (Prior Factor - Current Factor)
Paydown = $100,000,000 * (0.85432100 - 0.84210500)
Paydown = $100,000,000 * 0.01221600
Paydown = $1,221,600

This $1,221,600 consists of:
  - Scheduled principal amortization
  - Unscheduled prepayments (borrower refinances, curtailments)
  - Liquidation proceeds (from defaulted loans)
```

**Data Engineering Relevance:**

- Factor data must be loaded promptly each month as it drives portfolio accounting, settlement calculations, and position reconciliation.
- Factors are published to 8 decimal places; truncation or rounding errors can cause material dollar discrepancies on large positions.
- Pre-factor and post-factor reconciliation is a standard monthly process: verify that the factor received matches the expected paydown from loan-level data.

### 6. Remittance Data

Remittance data details the actual cash flows distributed to MBS investors each month.

**Components:**

- **Scheduled Principal:** The amortization portion of the monthly payment, per the loan's amortization schedule.
- **Unscheduled Principal (Prepayments):** Full payoffs (refinances, home sales), partial prepayments (curtailments), and liquidation proceeds.
- **Gross Interest:** Interest paid to the investor at the pool's pass-through rate.
- **Servicing Fee:** The spread between WAC and pass-through rate retained by the servicer (and guarantee fee retained by the agency).
- **Losses/Shortfalls:** For Ginnie Mae and some non-agency structures, any shortfalls in collections that affect cash flows.

**Payment Delay:**

- **Fannie Mae:** 55-day delay (e.g., January payments received on February 25th).
- **Freddie Mac:** 75-day delay (Gold PCs) or 45-day delay (newer structures). Note: with the Uniform MBS (UMBS) initiative, both Fannie and Freddie now issue UMBS with a 55-day delay.
- **Ginnie Mae I:** 15-day delay. Ginnie Mae II: 20-day delay.

**Data Engineering Relevance:** Remittance data feeds into portfolio accounting systems to record principal paydowns, interest income, and any premium/discount amortization. The data engineer must correctly map remittance components to accounting entries and ensure timing alignment with the settlement calendar.

### 7. Data Formats and Delivery Schedules

**eMBS Data Delivery:**

| Format | Description |
|---|---|
| Flat Files (Pipe/CSV) | Standard bulk delivery format. Monthly snapshots with header/trailer records for validation. |
| XML | Available for some data products. More structured but larger file sizes. |
| API (REST) | eMBS offers API access for on-demand queries. Used for smaller data requests and real-time lookups. |
| Web Portal | Interactive query interface for ad-hoc pool and loan lookups. |

**Agency Direct Delivery Formats:**

- **Fannie Mae:** Pipe-delimited flat files with fixed schema. Available via SFTP or web download from Fannie Mae Connect / MBS data portal. Includes separate files for origination (static loan attributes) and performance (monthly updates).
- **Freddie Mac:** Pipe-delimited flat files. Available through Freddie Mac's Single Family Loan-Level Dataset portal. Similar origination/performance split.
- **Ginnie Mae:** Multiple file types (pool-level, loan-level, factor). Available via Ginnie Mae's disclosure website and bulk download.

**Delivery Schedule (Typical Monthly Cycle):**

| Business Day | Event |
|---|---|
| BD 1-3 | Servicers report to agencies (payment data for prior month) |
| BD 4-6 | Agencies publish pool factors |
| BD 5-8 | eMBS processes and redistributes factor data |
| BD 10-15 | Agencies publish updated pool-level statistics (WAC, WAM, delinquency) |
| BD 15-20 | Loan-level performance data published |
| BD 20-25 | Supplemental data (modifications, forbearance details) |
| Month-end | eMBS publishes full monthly refresh including all data products |

**Note:** Exact schedules vary by agency and month. Ginnie Mae's disclosure is typically later in the cycle than Fannie Mae or Freddie Mac.

### 8. Monthly Reporting Cycle in Detail

Understanding the monthly reporting cycle is critical for data engineers building MBS data pipelines.

**Cycle Overview:**

```
Month N (e.g., January)
  - Borrowers make January payments (due Jan 1st, with grace period to Jan 15th)
  - Servicers process payments, record delinquencies

Month N+1 (e.g., February)
  - BD 1-3: Servicers report January activity to agencies
  - BD 4-6: Agencies calculate and publish January factors
  - BD 10-15: Pool-level January statistics published
  - BD 15-20: Loan-level January performance published
  - Feb 25: Fannie Mae pays January interest/principal to investors (55-day delay)

Month N+2 (e.g., March)
  - Late-reporting data for January may still trickle in
  - Historical revisions to January data may be published
```

**Data Pipeline Implications:**

1. **Staggered Ingestion:** Data arrives in waves throughout the month. The pipeline must be designed to handle partial data, with clear tracking of which agencies and data types have been received.
2. **Factor-First Processing:** Factor data arrives earliest and is the highest priority for portfolio accounting. Build a fast-path pipeline for factor data that runs independently of the more complex loan-level processing.
3. **Revision Handling:** Agencies occasionally revise previously published data (corrected factors, updated loan-level attributes). The pipeline must detect and apply revisions without duplicating records.
4. **Cross-Agency Normalization:** When eMBS data is not used, the data engineer must build normalization logic to map Fannie Mae, Freddie Mac, and Ginnie Mae field names and codes to a common schema.
5. **Audit Trail:** Regulatory requirements demand that data lineage is maintained. Track when each file was received, the file's record count and checksum, and any transformations applied.

### 9. Fannie Mae / Freddie Mac / Ginnie Mae Disclosure Differences

**Fannie Mae Specifics:**

- **LLPA (Loan-Level Price Adjustment) Data:** Discloses the pricing adjustments applied at acquisition based on risk attributes (LTV, FICO, property type). Useful for understanding the economics of GSE credit pricing.
- **CAS (Connecticut Avenue Securities) Disclosure:** For credit risk transfer deals, Fannie Mae publishes enhanced disclosure with loss and delinquency data tied to CAS reference pools.
- **Portal:** Fannie Mae DataDynamics provides interactive visualization and download of loan-level data.

**Freddie Mac Specifics:**

- **STACR (Structured Agency Credit Risk) Disclosure:** Freddie Mac's CRT program with similar enhanced disclosure for reference pools.
- **Single Family Loan-Level Dataset:** Publicly available dataset with loan-level origination and performance data. Widely used in academic research and model development. Freely downloadable (with registration).
- **Loan Advisor Suite Data:** Additional origination-quality data for loans processed through Freddie Mac's automated tools.

**Ginnie Mae Specifics:**

- **Government Loan Attributes:** Includes FHA/VA/USDA program-specific fields not present in Fannie/Freddie data: FHA case number, VA entitlement, USDA guarantee percentage, upfront and annual mortgage insurance premiums.
- **Issuer-Level Data:** Ginnie Mae discloses data at the issuer level (the entity that assembled the pool), which provides insight into originator/servicer performance.
- **Buyout Reporting:** Reports on loans bought out of Ginnie Mae pools by issuers (typically when loans become 90+ days delinquent). Buyout activity is a unique feature of Ginnie Mae MBS and materially affects pool-level CPR.
- **Multi-Issuer Pools (Ginnie II):** A single Ginnie II pool can contain loans from multiple issuers, creating additional complexity in performance attribution.

### 10. Building a Loan-Level Disclosure Database

**Schema Design:**

A well-designed loan-level disclosure database typically has three main table groups:

```
1. LOAN_ORIGINATION (Static attributes, one row per loan)
   - loan_id (agency-assigned identifier)
   - agency (FNMA / FHLMC / GNMA)
   - pool_number
   - origination_date
   - original_upb
   - original_ltv, original_cltv
   - fico_origination
   - dti
   - loan_purpose, property_type, occupancy
   - state, zip_3digit
   - channel, first_time_buyer_flag
   - seller_name, servicer_name

2. LOAN_PERFORMANCE (Monthly snapshot, one row per loan per month)
   - loan_id
   - reporting_period (YYYYMM)
   - current_upb
   - loan_status (current/30/60/90/FC/REO)
   - current_interest_rate
   - modification_flag
   - forbearance_flag
   - zero_balance_code (null if still active)
   - zero_balance_date

3. POOL_SUMMARY (Monthly pool-level data)
   - pool_number / cusip
   - agency
   - reporting_period
   - factor
   - current_face
   - wac, wam, wala
   - weighted_avg_ltv, weighted_avg_fico
   - loan_count
   - delinquency_30, delinquency_60, delinquency_90plus
   - cpr_1mo, cpr_3mo, cpr_12mo
```

**Partitioning Strategy:**

- Partition `LOAN_PERFORMANCE` by `reporting_period`. This is the most common query filter and enables efficient monthly cohort analysis.
- For very large deployments (all three agencies, full history), the performance table can contain billions of rows. Use columnar storage (Parquet, Delta Lake, Snowflake) with compression.

**Incremental Load Pattern:**

```
1. Download new monthly files from agency portals or eMBS
2. Validate file integrity (record count, checksums)
3. Load into staging tables (raw format)
4. Apply field transformations and type casting
5. Upsert new origination records into LOAN_ORIGINATION
   (new loans appear when new pools are issued)
6. Insert new monthly records into LOAN_PERFORMANCE
   (append-only; each month's data is a new partition)
7. Update POOL_SUMMARY with new factor and statistics
8. Run quality checks:
   - Sum of loan-level current_upb should ≈ pool current_face
   - Factor from pool data should match factor derived from loan data
   - No duplicate loan_id within a single reporting_period
9. Publish to curated layer for analytics consumption
```

---

## Real-World Examples

### Example 1: Building a Prepayment Model Training Dataset

A quantitative analyst needs loan-level data to train a prepayment model:

- The data engineer extracts Fannie Mae and Freddie Mac loan-level disclosure data (freely available with registration) covering 2000-2025.
- The origination file provides risk attributes (FICO, LTV, loan purpose, property type) as model features.
- The performance file provides monthly prepayment outcomes (zero_balance_code indicating full payoff).
- The engineer enriches the data with macroeconomic variables (mortgage rates, unemployment, HPI) by joining on reporting_period and geography.
- The final training dataset has ~2 billion loan-month observations, stored in Parquet format on S3, partitioned by vintage year and reporting period.

### Example 2: Factor Reconciliation Pipeline

A fixed-income operations team needs to reconcile portfolio positions monthly:

- The data engineer builds a pipeline that ingests eMBS factor data on BD 4-6 of each month.
- For each pool held in the portfolio, the pipeline computes: Paydown = Position Original Face * (Prior Factor - New Factor).
- Results are compared against the custodian's paydown report (received separately).
- Discrepancies exceeding $1 are flagged for investigation. Common causes: factor rounding differences (eMBS vs. custodian source), timing differences (factor effective date interpretation), or position discrepancies.
- The pipeline produces a reconciliation report summarizing matches, breaks, and resolution status.

### Example 3: Agency Cross-Sectional Analysis

A research team wants to compare delinquency trends across Fannie Mae, Freddie Mac, and Ginnie Mae:

- The data engineer normalizes loan-level data from all three agencies into a common schema using eMBS as the primary source.
- Fields that differ across agencies (e.g., Ginnie Mae's government loan attributes) are mapped to a unified delinquency status taxonomy.
- Monthly delinquency rates (30+, 60+, 90+) are computed by agency, vintage, FICO band, and LTV band.
- The pipeline produces time-series datasets that power a Tableau dashboard showing relative credit performance across agencies.
- Key insight: Ginnie Mae pools (FHA/VA loans) have structurally higher delinquency rates but different loss outcomes due to government insurance/guarantee.

---

## Common Interview Questions and Answers

### Q1: What is eMBS and why do firms use it instead of going directly to the agencies?

**Answer:** eMBS is a data aggregation and distribution platform that collects mortgage-backed securities disclosure data from Fannie Mae, Freddie Mac, and Ginnie Mae, normalizes it into a consistent format, and redistributes it to subscribers. Firms use eMBS instead of going directly to each agency for several reasons: (1) Normalization -- each agency uses different file formats, field names, codes, and delivery schedules. eMBS harmonizes these into a single schema, saving significant data engineering effort. (2) Timeliness -- eMBS processes and redistributes data quickly, often within hours of agency publication, and provides alerts when new data is available. (3) Historical archive -- eMBS maintains a complete, consistent historical archive that would be costly to build and maintain from raw agency files. (4) Derived analytics -- eMBS computes derived metrics (CPR, CDR, severity) at the pool level that would require additional calculation from raw data. (5) Single vendor relationship -- instead of managing data access agreements and technical connections with three separate agencies, firms deal with one vendor. The trade-off is cost: eMBS licenses can be expensive, and for some use cases (e.g., academic research using freely available Freddie Mac data), going directly to the agency is sufficient.

### Q2: Explain the difference between pool-level and loan-level disclosure data.

**Answer:** Pool-level data provides aggregated summary statistics for each MBS pool: original and current face, factor, WAC, WAM, WALA, weighted average LTV and FICO, loan count, geographic distribution, and delinquency percentages. It tells you the characteristics of the pool as a whole but not the individual loans. Pool-level data is used for pricing, trading, and portfolio-level analytics. Loan-level data provides individual loan attributes and monthly performance for every loan in the pool. It includes origination details (balance, rate, LTV, FICO, loan purpose, property type, borrower characteristics) and monthly updates (current balance, delinquency status, modification status, zero-balance outcomes). Loan-level data enables much more granular analysis: you can build prepayment and default models, perform credit stratification, identify concentration risks at the loan level, and attribute pool performance to specific loan cohorts. The trade-off is volume -- loan-level data is orders of magnitude larger than pool-level data and requires significantly more storage and processing infrastructure.

### Q3: How would you design a data pipeline to ingest monthly agency disclosure data?

**Answer:** I would design the pipeline in several stages. First, a file acquisition job that monitors agency portals and eMBS SFTP servers for new monthly files, downloading them to a landing zone when available. Since data arrives in waves across the month, this job runs daily during the reporting window. Second, a validation stage that checks file integrity (record counts match trailers, no truncation, character encoding is correct), and logs the file metadata (agency, data type, reporting period, receipt timestamp). Third, a staging load that parses the flat files into staging tables, handling format differences across agencies (Fannie pipe-delimited vs. Freddie pipe-delimited with slightly different layouts vs. Ginnie's format). Fourth, a normalization stage that maps agency-specific field names and codes to a canonical schema. Fifth, loading into the production tables: upsert for origination data (new loans), append for performance data (new monthly partition), and update for pool summary. Sixth, quality checks: cross-validate loan-level aggregates against pool-level totals (sum of loan UPBs should approximate pool current face), check for duplicate records, verify factor consistency. Seventh, trigger downstream processes: notify analytics teams, update dashboards, feed risk models. I would orchestrate this with Airflow, with separate DAGs for factor data (fast-path, high priority) and loan-level data (batch, higher volume).

### Q4: What is a pool factor and why is precision important?

**Answer:** A pool factor is the ratio of the current remaining principal balance to the original principal balance of an MBS pool. It is published monthly by the agencies (and redistributed by eMBS) and is used to determine the actual dollar amount of principal paydowns for settlement and accounting. Factors are expressed to 8 decimal places (e.g., 0.84210500). Precision matters enormously because even small rounding differences, when applied to large original face amounts, produce material dollar discrepancies. For example, on a pool with $1 billion original face, a factor difference of 0.00000001 translates to $10. Across a large MBS portfolio with thousands of pools, accumulated rounding errors can create significant reconciliation breaks with custodians and counterparties. Data engineers must ensure that factor values are stored and computed using sufficient numeric precision (at minimum DECIMAL(10,8) or equivalent) and that no intermediate calculation truncates or rounds the factor before final use.

### Q5: What are the key differences between Fannie Mae, Freddie Mac, and Ginnie Mae disclosure data?

**Answer:** The main differences are: (1) Loan populations -- Fannie and Freddie cover conventional conforming loans, while Ginnie Mae covers government-insured/guaranteed loans (FHA, VA, USDA). This means Ginnie Mae data includes government-program-specific fields (FHA case number, VA entitlement, insurance premium details) not present in Fannie/Freddie. (2) Credit profiles -- Ginnie Mae loans typically have lower FICOs, higher LTVs (up to 100% for VA), and first-time homebuyer concentrations, resulting in structurally different prepayment and default behavior. (3) Payment delays -- UMBS (Fannie/Freddie) has a 55-day delay; Ginnie I has a 15-day delay; Ginnie II has a 20-day delay. This affects cash flow timing and yield calculations. (4) Buyout behavior -- Ginnie Mae issuers routinely buy delinquent loans out of pools (which registers as a "prepayment" at the pool level), creating artificially high CPR readings that must be decomposed into voluntary prepayments and involuntary buyouts. Fannie/Freddie do not have an equivalent buyout mechanism. (5) Format differences -- field names, coding conventions, and file layouts differ across agencies, necessitating normalization when combining data. (6) Availability -- Freddie Mac's single-family loan-level dataset is publicly and freely available (a popular academic and research resource), while Fannie Mae's DataDynamics is also publicly accessible. Ginnie Mae data requires registration and has more restricted access.

### Q6: How do you handle the staggered delivery schedule of agency data in your pipeline?

**Answer:** Agency data arrives in waves across the month: factors first (BD 4-6), pool statistics mid-month (BD 10-15), and loan-level data later (BD 15-20+). My pipeline handles this with an event-driven architecture. A file monitor process checks the eMBS SFTP and agency portals on a configurable schedule (every few hours during the reporting window). When a new file is detected, it triggers the appropriate processing DAG in Airflow. Factor data has a dedicated fast-path DAG that runs immediately upon detection, processes within minutes, and publishes to the portfolio accounting system. Pool-level and loan-level data have separate DAGs that run after their respective files arrive. A tracking table records which agencies and data types have been received for each reporting period. Downstream consolidated processes (like cross-agency analytics) only run once all required inputs have arrived -- an Airflow sensor monitors the tracking table and triggers the consolidation DAG when completeness criteria are met. If expected data has not arrived by a configurable deadline (e.g., BD 8 for factors, BD 22 for loan-level), an alert is generated for manual investigation. This design ensures that early-arriving data is processed and available immediately, without waiting for later-arriving data.

---

## Tips

1. **Know the monthly calendar.** In interviews, being able to walk through the monthly MBS data reporting cycle -- when factors publish, when loan-level data arrives, when payments settle -- demonstrates operational depth that distinguishes a senior data engineer from a junior one.

2. **Understand the UMBS initiative.** In 2019, Fannie Mae and Freddie Mac launched the Uniform MBS (UMBS) program, making their securities fungible (interchangeable) in the TBA market. This had significant data implications: Fannie and Freddie pools now share a common security structure (55-day delay), but their disclosure data remains separate. Know this context.

3. **Use freely available data for learning.** Freddie Mac's Single Family Loan-Level Dataset is publicly available and contains millions of loans with monthly performance. Download it, build a database, and practice querying. This is an excellent interview preparation exercise and can be discussed as hands-on experience.

4. **Factor precision is non-negotiable.** Never round or truncate factor data. Store factors with at least 8 decimal places. This is a common gotcha in pipeline design and a topic interviewers may probe.

5. **Decompose Ginnie Mae CPR.** When analyzing Ginnie Mae pools, always distinguish between voluntary prepayments and issuer buyouts. Raw CPR numbers for Ginnie Mae pools can be misleading if buyouts are not separated out. This shows analytical sophistication.

6. **Build for revision handling.** Agencies occasionally publish corrected data. Your pipeline should be able to detect and apply corrections without creating duplicate records. Use a combination of reporting_period + loan_id as a natural key and implement upsert logic.

7. **Cross-validate pool and loan data.** Sum of loan-level current UPBs should approximately equal the pool's current face (small differences arise from rounding). This is a powerful data quality check that catches ingestion errors early.

8. **Know the regulatory context.** Post-crisis reforms (Dodd-Frank, FHFA conservatorship directives) drove the expansion of agency disclosure. Understanding why this data exists (transparency, investor confidence, systemic risk monitoring) provides context for interview discussions about data governance and purpose.
