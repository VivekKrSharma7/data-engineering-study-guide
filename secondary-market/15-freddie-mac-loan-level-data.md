# Freddie Mac Loan-Level Data

[Back to Secondary Market Index](./README.md)

---

## Overview

Freddie Mac's **Single Family Loan-Level Dataset** is a publicly available dataset that provides detailed origination and monthly performance data for a substantial portion of Freddie Mac's single-family mortgage portfolio. Alongside Fannie Mae's equivalent dataset, it forms the backbone of mortgage credit and prepayment research in the United States. While structurally similar to Fannie Mae's data, there are important differences in field definitions, naming conventions, coverage, and data quality that data engineers must understand to work effectively across both datasets.

---

## Key Concepts

### 1. Dataset Structure: Two Core Files

Like Fannie Mae, Freddie Mac provides two linked file types:

#### Origination File (One Record Per Loan)
Contains static loan characteristics captured at the time of origination or acquisition by Freddie Mac. Each loan appears exactly once.

#### Monthly Performance File (One Record Per Loan Per Month)
Contains time-series data showing each loan's monthly payment status, balance, and termination details. A loan observed for 72 months will have 72 records.

**Relationship**: Both files are joined on `Loan Sequence Number` (Freddie Mac's unique loan identifier, formatted differently from Fannie Mae's).

### 2. Key Origination File Fields

| Field | Description | Typical Values | Notes |
|-------|-------------|----------------|-------|
| **Loan Sequence Number** | Unique loan identifier | F########### | Freddie Mac format; different prefix/pattern than Fannie Mae |
| **Credit Score** | Borrower credit score at origination | 301-850 | Similar to Fannie Mae; may be missing for older loans |
| **First-Time Home Buyer Indicator** | First-time buyer flag | Y, N | No "Unknown" category (unlike Fannie Mae's "U") |
| **DTI** | Debt-to-income ratio | 1-65+ | Integer; missing values common in older vintages |
| **Original UPB** | Original unpaid principal balance | Dollar amount | Conforming limits apply |
| **Original LTV** | Loan-to-value ratio | 1-105 | Integer percentage |
| **Original CLTV** | Combined LTV including second liens | 1-200 | May not be populated for all loans |
| **Original Interest Rate** | Note rate at origination | Percentage | Fixed rate; dataset primarily covers fixed-rate loans |
| **Origination Date** | Month/year of origination | YYYYMM | **Note**: Freddie uses YYYYMM format vs. Fannie's MMYYYY |
| **First Payment Date** | First scheduled payment date | YYYYMM | Format difference from Fannie Mae |
| **Loan Purpose** | Purpose of the mortgage | P=Purchase, C=Cash-out Refi, N=No Cash-out Refi, U=Refinance Not Specified | Values align closely with Fannie Mae but check definitions |
| **Property Type** | Property classification | SF, CO, CP, MH, PU | Same categories as Fannie Mae |
| **Number of Units** | Units in the property | 1-4 | Same as Fannie Mae |
| **Occupancy Status** | Borrower occupancy type | P=Primary, S=Second, I=Investment | Same as Fannie Mae |
| **Channel** | Origination channel | R=Retail, B=Broker, C=Correspondent | Similar to Fannie Mae |
| **Property State** | State code | 2-letter abbreviation | Same as Fannie Mae |
| **MSA** | Metro area code | 5-digit | May differ in population rate from Fannie Mae |
| **Mortgage Insurance Percentage** | MI coverage | 0-55% | Same concept as Fannie Mae |
| **Seller Name** | Originating seller | Text | Different seller population (Freddie Mac sellers) |
| **Servicer Name** | Current servicer | Text | Tracked at origination; updates in performance file |
| **Prepayment Penalty Mortgage Flag** | Whether loan has prepayment penalty | Y, N | Freddie Mac includes this; Fannie Mae does not in the standard dataset |
| **Product Type** | Loan product | FRM (Fixed Rate Mortgage) | Dataset primarily covers 30-year and 15-year FRMs |

### 3. Key Performance File Fields

| Field | Description | Typical Values | Notes |
|-------|-------------|----------------|-------|
| **Loan Sequence Number** | Links to origination file | Foreign key | |
| **Monthly Reporting Period** | Observation month | YYYYMM | **Format differs from Fannie Mae's MMDDYYYY** |
| **Current UPB** | Outstanding principal balance | Dollar amount | Null after zero balance |
| **Current Loan Delinquency Status** | Months delinquent | 0, 1, 2, 3, ... , RA | Same concept as Fannie Mae; string field |
| **Loan Age** | Months since first payment | Integer | Computed from first payment date |
| **Remaining Months to Legal Maturity** | Months to maturity | Integer | Decreases monthly |
| **Modification Flag** | Loan modification indicator | Y, N | Same as Fannie Mae |
| **Zero Balance Code** | Termination reason | 01, 02, 03, 06, 09, 15, 16 | Values largely align with Fannie Mae but verify definitions |
| **Zero Balance Effective Date** | Termination date | YYYYMM | Note date format |
| **Current Interest Rate** | Current note rate | Percentage | May change post-modification |
| **Current Deferred UPB** | Deferred principal from modification | Dollar amount | Post-modification balance deferral |
| **Foreclosure Date** | Foreclosure completion date | YYYYMM | |
| **Disposition Date** | Date of property disposition | YYYYMM | |
| **Foreclosure Costs** | Legal and foreclosure expenses | Dollar amount | Component of loss calculation |
| **Property Preservation and Repair Costs** | Maintenance expenses | Dollar amount | Component of loss calculation |
| **Asset Recovery Costs** | Recovery-related expenses | Dollar amount | |
| **Miscellaneous Holding Expenses** | Other holding costs | Dollar amount | |
| **Associated Taxes for Holding Property** | Tax expenses during REO period | Dollar amount | |
| **Net Sales Proceeds** | Proceeds from disposition | Dollar amount | Used in loss severity |
| **MI Recoveries** | Mortgage insurance recoveries | Dollar amount | |

### 4. Key Differences from Fannie Mae Data

| Dimension | Fannie Mae | Freddie Mac |
|-----------|-----------|-------------|
| **Date format** | MMYYYY or MMDDYYYY | YYYYMM |
| **Loan ID format** | F + alphanumeric | Different pattern, also starts with F but distinct structure |
| **First-time buyer** | Y, N, U (Unknown) | Y, N (no Unknown) |
| **Prepayment penalty flag** | Not included | Included |
| **Expense detail in performance** | Aggregated expenses field | Broken out into multiple expense categories (foreclosure costs, preservation, recovery, taxes, misc.) |
| **File format** | Pipe-delimited, no headers | Pipe-delimited, no headers |
| **Vintage coverage** | 1999/2000 onward | 1999 onward |
| **Seller/Servicer naming** | Fannie Mae sellers | Freddie Mac sellers (different institutions may appear) |
| **Delinquency field name** | Current Loan Delinquency Status | Current Loan Delinquency Status (same name, same values) |
| **Borrower assistance fields** | Added for COVID-era | Similar fields added, but naming/timing may differ |
| **Data dictionary versioning** | Periodic updates | Periodic updates, independent schedule from Fannie |
| **CLTV population** | Generally well-populated | May have more missing values in older vintages |

**Critical data engineering implication**: When building a unified cross-agency dataset, you must create a mapping layer that harmonizes date formats, loan ID prefixes, field names, expense granularity, and categorical value definitions.

### 5. Vintage Coverage

- **Historical depth**: Freddie Mac's public dataset covers loans originated from approximately 1999 through recent quarters.
- **Expansion over time**: Coverage has expanded -- earlier releases covered fewer vintages. Newer releases include additional historical data.
- **Sample vs. universe**: Like Fannie Mae, this is not the complete Freddie Mac book. It covers the majority of 30-year and 15-year fixed-rate conventional conforming loans.
- **Quarterly releases**: New data is released quarterly with a several-month lag.

### 6. STACR (Structured Agency Credit Risk) Disclosure

Freddie Mac's credit risk transfer program is called **STACR** (Structured Agency Credit Risk), analogous to Fannie Mae's CAS program:

- **Structure**: STACR bonds reference specific pools of Freddie Mac loans. Credit events on the reference pool loans trigger write-downs or interest diversions on STACR tranches.
- **Disclosure**: Freddie Mac provides loan-level data for STACR reference pools, including monthly performance updates.
- **Credit event definitions**: Typically, a loan becomes a credit event at 180+ days delinquent, or upon certain disposition events. Exact definitions vary by deal.
- **Data engineering relevance**: Building STACR monitoring systems requires:
  - Mapping reference pool loans to the broader Freddie Mac dataset.
  - Tracking credit events against deal-specific definitions (which may differ from standard delinquency metrics).
  - Calculating cumulative credit event amounts and comparing against tranche attachment/detachment points.
  - Producing deal-level reporting for investors and risk management.

### 7. Data Quality Considerations

| Issue | Description | Mitigation |
|-------|-------------|------------|
| **Missing values** | FICO, DTI, CLTV frequently missing in older vintages | Imputation or exclusion with documentation; track missingness rate by vintage |
| **Date format inconsistencies** | Some fields may have unexpected formats across releases | Build robust date parsers; validate against expected ranges |
| **Servicer name changes** | Servicers merge, rename, or transfer servicing | Maintain a servicer name mapping/crosswalk table |
| **Modification data gaps** | Pre-HAMP modifications may not be fully captured | Use modification flag + rate/balance changes as supplementary indicators |
| **Retroactive corrections** | Quarterly releases may include corrections to prior periods | Implement change detection; compare current release to prior release for same loans/periods |
| **Field additions** | New fields added over time (e.g., COVID forbearance fields) | Schema must accommodate nullable new columns; version your ingestion pipeline |
| **Truncated data** | Performance history may be truncated for very old loans | Track observation window per loan; document limitations in analysis |

### 8. Joining Origination and Performance Data

The join between origination and performance files is fundamental but requires careful handling:

**Join strategy:**
```
SELECT
    o.loan_sequence_number,
    o.credit_score,
    o.original_ltv,
    o.original_upb,
    o.loan_purpose,
    o.property_state,
    p.monthly_reporting_period,
    p.current_upb,
    p.current_loan_delinquency_status,
    p.zero_balance_code
FROM freddie_origination o
INNER JOIN freddie_performance p
    ON o.loan_sequence_number = p.loan_sequence_number
```

**Considerations:**
- **Cardinality**: This is a one-to-many join (one origination record to many performance records). The result set will be very large.
- **Performance optimization**: For analytical queries, pre-aggregate performance data before joining (e.g., compute ever-delinquent flags, terminal status, or monthly CPR at the loan level first, then join to origination).
- **Partitioning strategy**: Partition performance data by `monthly_reporting_period` for time-based queries, or by origination vintage for cohort analysis.
- **Broadcast join**: In distributed computing (Spark), the origination file is small enough to broadcast; the performance file should be the large/shuffled table.

**Cross-agency unified model:**
To analyze Fannie Mae and Freddie Mac data together:

1. Create a unified schema with standardized field names.
2. Add an `agency` column (FNMA or FHLMC).
3. Harmonize date formats to a standard (e.g., YYYY-MM-DD).
4. Normalize categorical values (verify that 'P', 'C', 'N' mean the same thing in both datasets).
5. Map expense fields (Freddie's granular expenses to Fannie's aggregated format, or vice versa).
6. Prefix or namespace loan IDs to prevent collisions.

---

## Real-World Examples

### Example 1: Cross-Agency Prepayment Study

A research team wants to compare prepayment behavior across Fannie Mae and Freddie Mac:

1. **Ingest** both datasets into a unified data lake with harmonized schemas.
2. **Feature engineering**: Compute monthly CPR for each loan using balance changes and zero balance codes. Create refinance incentive (current rate minus prevailing market rate), loan age, FICO bucket, LTV bucket.
3. **Analysis**: Compare CPR curves by agency, controlling for borrower characteristics. Test whether Fannie and Freddie loans with identical observable characteristics prepay at different rates (which would suggest unobservable selection differences).
4. **Finding**: Historically, differences have been minimal after controlling for observables, validating the "TBA fungibility" assumption between Fannie and Freddie pass-throughs.

### Example 2: STACR Deal Monitoring Pipeline

Building an automated STACR monitoring system:

1. **Deal intake**: Parse STACR deal documents to extract reference pool loan list, credit event definitions, and tranche structure (attachment/detachment points).
2. **Monthly processing**: Ingest updated Freddie Mac performance data. Filter to loans in each STACR reference pool.
3. **Credit event identification**: Apply deal-specific rules (e.g., 180+ days delinquent = credit event). Calculate credit event amounts.
4. **Waterfall application**: Apply cumulative credit events against the deal's capital structure to determine which tranches are affected.
5. **Reporting**: Generate monthly reports showing: cumulative credit events, remaining credit enhancement, tranche principal balance, and projected loss timeline.

### Example 3: Data Quality Dashboard

A data engineering team builds monitoring for the Freddie Mac data pipeline:

1. **Completeness checks**: Track null rates for FICO, DTI, LTV, CLTV by vintage quarter. Alert if null rates exceed historical norms.
2. **Referential integrity**: Verify all performance file loan IDs exist in the origination file. Flag orphaned records.
3. **Transition logic**: Check that delinquency status transitions are valid (e.g., a loan cannot go from '0' to '5' in one month without a system error or a long gap in reporting).
4. **Balance checks**: Verify current_upb is less than or equal to prior month's current_upb (except for modifications with capitalized arrears).
5. **Zero balance validation**: When zero_balance_code is populated, confirm no subsequent performance records exist (or if they do, they are cleanup records with null balances).
6. **Release comparison**: Compare overlapping periods between quarterly releases to detect retroactive corrections. Log and alert on material changes.

---

## Common Interview Questions & Answers

### Q1: How does Freddie Mac's loan-level data differ from Fannie Mae's?

**A:** The key differences are: (1) Date formats -- Freddie Mac uses YYYYMM while Fannie Mae uses MMYYYY or MMDDYYYY. (2) Expense granularity -- Freddie Mac breaks out disposition expenses into separate fields (foreclosure costs, preservation, recovery, taxes, misc.) while Fannie Mae aggregates them. (3) Field availability -- Freddie Mac includes a prepayment penalty flag that Fannie Mae's standard dataset does not. (4) First-time buyer coding -- Fannie Mae includes an "Unknown" category (U) while Freddie Mac only has Y/N. (5) Seller/servicer populations differ because each agency has different approved seller/servicers. (6) Loan ID formats differ. When building cross-agency systems, these differences require a harmonization layer.

### Q2: How would you build a unified dataset combining Fannie Mae and Freddie Mac loan-level data?

**A:** I would create an ETL pipeline with three stages. First, **extraction**: ingest both datasets from their respective sources, applying the correct schema from each agency's data dictionary. Second, **transformation**: create a harmonization layer that standardizes date formats to ISO 8601, maps field names to a unified schema, normalizes categorical codes (verifying that values like 'P' for Purchase mean the same thing), aggregates Freddie Mac's granular expense fields to match Fannie Mae's format (while preserving the detail in a separate table), and adds an agency identifier column. Third, **loading**: store in a partitioned data warehouse (by reporting period and agency) with a unified loan dimension table. I would also build validation checks comparing record counts, null rates, and value distributions across agencies to ensure the harmonization is correct.

### Q3: What is STACR and how does it compare to Fannie Mae's CAS?

**A:** STACR (Structured Agency Credit Risk) is Freddie Mac's credit risk transfer program, while CAS (Connecticut Avenue Securities) is Fannie Mae's equivalent. Both programs issue bonds that reference pools of single-family loans, transferring credit risk to private investors. The structures are similar: both define credit events based on serious delinquency (typically 180+ days) or distressed disposition, and credit losses are allocated through a capital structure with attachment and detachment points. Key differences are in deal naming conventions, specific credit event definitions (which can vary by deal vintage), and reporting formats. For data engineers, both require the same core capabilities: reference pool tracking, credit event identification, and waterfall calculation. The main challenge is building a system flexible enough to handle the distinct deal-specific rules from each program.

### Q4: How would you handle the file size challenge with Freddie Mac's performance data?

**A:** The Freddie Mac performance file, like Fannie Mae's, is extremely large. My approach: (1) Use columnar file formats (Parquet, ORC) for storage -- this typically achieves 10x compression over raw text and enables column pruning for queries that only need a few fields. (2) Partition by origination vintage and/or reporting period depending on access patterns. (3) Use incremental processing -- each quarterly release contains new months of data; only process the delta rather than reloading everything. (4) For analytical queries, pre-compute summary tables (e.g., monthly loan counts by delinquency status, vintage CPR curves, transition matrices) that are orders of magnitude smaller. (5) In Spark environments, use broadcast joins for the origination file (small) and partition the performance file across workers. (6) Consider a tiered storage strategy -- recent data in hot storage (e.g., Delta Lake on SSD) and historical data in cold storage (S3/GCS with on-demand compute).

### Q5: What validation checks would you run when ingesting a new quarterly release?

**A:** I would run the following checks: (1) **Schema validation**: Confirm the file layout matches the expected data dictionary version -- field count, positions, and types. (2) **Record count trending**: Compare loan counts in the origination file to prior releases; flag unexpected increases or decreases. (3) **Referential integrity**: Every loan in the new performance records must exist in the origination file. (4) **Completeness**: Check null rates for key fields by vintage and compare to historical baselines. (5) **Overlap validation**: For periods covered by both the current and prior release, compare values for the same loan-month combinations and flag discrepancies (retroactive corrections). (6) **Range checks**: Validate FICO (300-850), LTV (1-200), DTI (1-65), UPB (positive), and delinquency status (known valid values). (7) **Temporal checks**: Loan age should increase by 1 each month; remaining maturity should decrease; current UPB should generally not increase (except for negative amortization or capitalized modification amounts). (8) **Zero balance consistency**: Loans with a zero balance code should not have subsequent active performance records.

### Q6: Explain how you would compute loss severity using Freddie Mac's data.

**A:** Using Freddie Mac's performance data, I identify loans that terminated with a credit event (zero_balance_code in 02, 03, 09). For each such loan: Total Loss = UPB at time of default + Accrued Interest + Foreclosure Costs + Property Preservation Costs + Asset Recovery Costs + Miscellaneous Holding Expenses + Associated Taxes - Net Sales Proceeds - MI Recoveries. Loss Severity = Total Loss / UPB at Default. Freddie Mac's advantage here is the granular expense breakout, which allows deeper analysis of loss components. I would aggregate severity by vintage, LTV bucket, FICO bucket, state (judicial vs. non-judicial foreclosure), and property type. One important nuance: for modified loans that subsequently default, the UPB at default may reflect the modified balance, and deferred UPB should be included in the loss calculation.

### Q7: How do you handle servicer name changes across time in the dataset?

**A:** Servicer names change due to mergers, acquisitions, and portfolio transfers. My approach: (1) Build a servicer name crosswalk table that maps variant names to a canonical servicer entity (e.g., "Countrywide Home Loans" and "Bank of America" map to the same entity post-acquisition). (2) Source this mapping from FHFA servicer data, SEC filings, and manual curation. (3) Apply the mapping during ETL to create a standardized `canonical_servicer_id` field alongside the raw servicer name. (4) Track servicing transfers at the loan level by comparing servicer names across consecutive performance records. (5) Update the crosswalk table with each quarterly release as new mergers or transfers occur. This is essential for any analysis examining servicer performance, as raw name-based grouping would fragment what is effectively the same entity.

---

## Tips

1. **Compare and contrast**: In interviews, being able to articulate specific differences between Fannie Mae and Freddie Mac datasets immediately signals real-world experience. Memorize at least 5 concrete differences (date format, expense granularity, prepayment penalty flag, first-time buyer coding, loan ID format).

2. **Practice the join**: Be ready to write SQL or PySpark code that joins origination and performance files. This is a common technical screening question. Know the cardinality (one-to-many) and how to optimize it.

3. **Understand both CRT programs**: STACR (Freddie) and CAS (Fannie) are increasingly important. Knowing how to build a CRT monitoring pipeline differentiates you from candidates who only know the raw loan data.

4. **Data quality is a feature**: Interviewers love hearing about data quality challenges and how you solved them. Discuss specific issues like missing FICO in older vintages, servicer name changes, and retroactive corrections.

5. **Scale your solutions**: Always frame your answers in terms of scale. These datasets contain tens of millions of loans and billions of performance records. Solutions that work for 1,000 loans but not 30 million will not impress.

6. **Know the ecosystem**: Freddie Mac data does not exist in isolation. Be prepared to discuss how it connects to: STACR/CAS deals, pool-level MBS data (eMBS, PoolTalk), HPI data (for current LTV estimation), and rate data (for refinance incentive calculation).

7. **Vintage matters**: The 2005-2007 vintages had dramatically worse credit performance than post-crisis vintages. Understanding why (loose underwriting standards, housing bubble) and how this manifests in the data (higher default rates, higher loss severities) is essential context.

8. **Incremental processing**: In production environments, you process new quarterly releases incrementally rather than reloading the full dataset. Be prepared to describe your approach to change detection, delta processing, and backfill handling.

---
