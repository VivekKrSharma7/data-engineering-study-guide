# Fannie Mae Loan-Level Data & Disclosure

[Back to Secondary Market Index](./README.md)

---

## Overview

Fannie Mae provides one of the most comprehensive public loan-level datasets in the mortgage industry: the **Single-Family Loan Performance Data**. This dataset, freely available through Fannie Mae's website, contains detailed acquisition and monthly performance information for a significant portion of Fannie Mae's single-family mortgage book. It is widely used by researchers, investors, data scientists, and data engineers for prepayment and credit modeling, risk assessment, and regulatory analysis. Understanding this dataset -- its structure, fields, quirks, and limitations -- is essential for any data engineer working in the secondary mortgage market.

---

## Key Concepts

### 1. Dataset Structure: Two Core Files

The Fannie Mae Single-Family Loan Performance Data consists of two file types that are linked by a common loan identifier:

#### Acquisition File (One Record Per Loan)
Contains static characteristics captured at the time of loan origination/acquisition. Each loan appears exactly once.

#### Performance File (One Record Per Loan Per Month)
Contains time-series data showing the monthly status of each loan from acquisition through the observation period. A loan with 60 months of history will have 60 records in the performance file.

**Relationship**: The files are joined on `Loan Sequence Number`, which serves as the unique loan identifier across both files.

### 2. Key Acquisition File Fields

| Field | Description | Typical Values | Data Engineering Notes |
|-------|-------------|----------------|----------------------|
| **Loan Sequence Number** | Unique identifier for each loan | F000Q1234567 | Primary key; prefix indicates Fannie Mae |
| **Credit Score (FICO)** | Borrower's credit score at origination | 620-850 | May be missing for older vintages; use co-borrower score if primary is null |
| **First-Time Home Buyer Flag** | Whether borrower is first-time buyer | Y, N, U | "U" = Unknown; significant for credit modeling |
| **DTI (Debt-to-Income Ratio)** | Monthly debt payments / gross monthly income | 0-65+ | Whole number; can be missing; key underwriting metric |
| **Original UPB** | Original unpaid principal balance | $50K-$750K+ | Reflects conforming loan limits at time of origination |
| **Original LTV** | Original loan-to-value ratio | 1-105 | Whole number percentage; >80 typically requires MI |
| **Original CLTV** | Combined LTV (includes subordinate liens) | 1-200 | May equal LTV if no second lien; important for credit risk |
| **Original Interest Rate** | Note rate at origination | 2.0%-12.0% | Fixed rate for fixed loans; initial rate for ARMs |
| **Origination Date** | Month and year of origination | MMYYYY | Key for vintage analysis |
| **First Payment Date** | Date of first scheduled payment | MMYYYY | Usually 1-2 months after origination |
| **Loan Purpose** | Purpose of the loan | P=Purchase, C=Cash-out Refi, N=No Cash-out Refi, U=Unknown | Critical segmentation variable for prepayment and credit models |
| **Property Type** | Type of property | SF=Single Family, CO=Condo, CP=Co-op, MH=Manufactured, PU=PUD | Affects collateral risk assessment |
| **Number of Units** | Units in the property | 1-4 | 2-4 units = multi-family characteristics |
| **Occupancy Status** | Borrower's occupancy | P=Primary, S=Second Home, I=Investment | Investment properties have higher default risk |
| **Channel** | Origination channel | R=Retail, B=Broker, C=Correspondent, T=TPO Not Specified | Broker-originated loans historically had higher default rates |
| **Property State** | State where property is located | 2-letter code | Key for geographic risk analysis; judicial vs. non-judicial foreclosure states |
| **MSA** | Metropolitan Statistical Area code | 5-digit code | May be missing for rural properties |
| **Mortgage Insurance Percentage** | MI coverage percentage | 0-55 | 0 if LTV <= 80; higher for high-LTV loans |
| **Number of Borrowers** | Count of borrowers on the loan | 1-10+ | Affects income calculation |
| **Seller Name** | Name of the originating seller | Text | Useful for seller performance analysis |
| **Servicer Name** | Name of the loan servicer | Text | Changes over time tracked in performance file |

### 3. Key Performance File Fields

| Field | Description | Typical Values | Data Engineering Notes |
|-------|-------------|----------------|----------------------|
| **Loan Sequence Number** | Links to acquisition file | F000Q1234567 | Foreign key to acquisition file |
| **Monthly Reporting Period** | The month of observation | MMDDYYYY | Use this as the time dimension |
| **Current UPB** | Outstanding principal balance | Decreasing over time | Null when loan reaches zero balance |
| **Current Loan Delinquency Status** | Months delinquent | 0, 1, 2, ... , RA | 0=Current, 1=30-day, RA=REO Acquisition; string field despite numeric appearance |
| **Loan Age** | Months since origination | 0, 1, 2, ... | Derived field; can also compute from dates |
| **Remaining Months to Maturity** | Months until scheduled payoff | Decreasing | Original term minus loan age (approximately) |
| **Modification Flag** | Whether loan has been modified | Y, N | Critical for identifying modified loans; affects prepayment analysis |
| **Zero Balance Code** | Reason for loan termination | 01=Prepaid/Matured, 02=Third Party Sale, 03=Short Sale, 06=Repurchased, 09=REO Disposition, 15=Note Sale, 16=Reperforming Sale | Key for default/prepayment categorization |
| **Zero Balance Effective Date** | When the loan reached zero balance | MMYYYY | Used to calculate loss timing |
| **Current Interest Rate** | Current note rate | May differ from original if modified | Track rate modifications over time |
| **Current Deferred UPB** | Deferred balance from modification | Dollar amount | Added post-modification; important for loss calculation |
| **Borrower Assistance Status Code** | Type of loss mitigation | F=Forbearance, T=Trial Modification, R=Repayment Plan | Added during COVID-19 era |
| **Net Sales Proceeds** | Proceeds from property disposition | Dollar amount | Used for loss severity calculation |
| **MI Recoveries** | Mortgage insurance claim proceeds | Dollar amount | Reduces net loss |
| **Expenses** | Foreclosure costs, property preservation | Dollar amount | Added to net loss |
| **Foreclosure Date** | Date foreclosure proceedings completed | MMYYYY | Used for timeline analysis |

### 4. Data Frequency and Coverage

- **Release cadence**: Quarterly updates (though individual monthly records are included within each release).
- **Vintage coverage**: Loans originated from 2000 through recent quarters (the dataset has expanded over time).
- **Population**: Not the full Fannie Mae book -- it covers a substantial sample of 30-year fixed-rate and 15-year fixed-rate loans. ARMs and other products may be excluded or limited.
- **Lag**: Data is released with approximately a 3-6 month lag from the most recent observation period.
- **File format**: Pipe-delimited (|) text files without headers. A separate data dictionary/layout file maps column positions to field names.
- **File sizes**: The performance file is extremely large (hundreds of GB uncompressed across all vintages). Each vintage year is typically provided as a separate downloadable file.

### 5. CAS (Connecticut Avenue Securities) Disclosure

Fannie Mae's **Credit Risk Transfer (CRT)** program, branded as **Connecticut Avenue Securities (CAS)**, involves issuing bonds that transfer credit risk on reference pools of loans to private investors.

**CAS Disclosure data includes:**
- Loan-level data for the reference pool underlying each CAS deal.
- Monthly performance updates showing delinquency, modification, and loss events.
- Deal-level reporting showing credit event triggers and tranche write-downs.

**Data engineering relevance:**
- CAS reference pools require tracking against a specific set of loans.
- Credit events (serious delinquency, default) on reference pool loans trigger payments from or write-downs to CAS bonds.
- Building a CAS monitoring system requires joining loan-level performance data with deal-specific reference pool definitions and waterfall rules.

### 6. Data Dictionary

Fannie Mae publishes a detailed data dictionary (sometimes called the "Glossary" or "File Layout") that defines:

- Every field name, position, data type, and length.
- Valid values and their meanings.
- Business rules for field population (e.g., when a field is null vs. populated).
- Changes across dataset versions (fields added or modified over time).

**Critical data engineering considerations:**
- The data dictionary is versioned. Older vintage files may not contain fields added in newer releases.
- Some fields are populated only for loans meeting certain criteria (e.g., modification fields only populated post-modification).
- Field definitions may differ subtly from Freddie Mac's equivalent dataset, requiring careful mapping for cross-agency analysis.

---

## Real-World Examples

### Example 1: Building a Prepayment Model Pipeline

A quantitative analytics team needs a prepayment model using Fannie Mae loan-level data:

1. **Ingestion**: Download quarterly acquisition and performance files from Fannie Mae's website. Parse pipe-delimited files using a schema definition derived from the data dictionary.
2. **Storage**: Load acquisition data into a `fannie_acquisitions` table (one row per loan). Load performance data into a `fannie_performance` table partitioned by `monthly_reporting_period`.
3. **Feature engineering**: Join acquisition and performance tables on `loan_sequence_number`. Create features: current LTV (using home price index adjustment), refinance incentive (current rate minus market rate), loan age, burnout indicator, seasonality.
4. **Labeling**: Define prepayment events using `zero_balance_code = '01'` and monthly conditional prepayment rate (CPR).
5. **Model training**: Feed features into a logistic regression or gradient boosting model to predict monthly prepayment probability.

### Example 2: COVID-19 Forbearance Analysis

During the COVID-19 pandemic, millions of loans entered forbearance. Using Fannie Mae data:

1. Filter performance records where `borrower_assistance_status_code = 'F'` (forbearance).
2. Track the transition from forbearance to: (a) reinstatement (current status), (b) modification, (c) repayment plan, or (d) serious delinquency.
3. Segment by vintage, FICO, LTV, and geography to identify which borrower cohorts recovered vs. deteriorated.
4. Calculate forbearance rates as a percentage of active UPB over time.

### Example 3: Loss Severity Calculation

For credit risk analysis, calculate loss severity on liquidated loans:

```
Loss = Original UPB at Default
     - Net Sales Proceeds
     - MI Recoveries
     + Expenses (Legal, Property Preservation, etc.)
     + Accrued Interest

Loss Severity = Loss / UPB at Default
```

Using Fannie Mae data:
1. Identify loans with `zero_balance_code` in ('02', '03', '09') indicating distressed disposition.
2. Pull `net_sales_proceeds`, `mi_recoveries`, and `expenses` from the performance file.
3. Calculate severity and aggregate by vintage, LTV bucket, FICO bucket, and state.

---

## Common Interview Questions & Answers

### Q1: Describe the structure of Fannie Mae's Single-Family Loan Performance Data.

**A:** The dataset consists of two core files: the Acquisition file and the Performance file. The Acquisition file contains one record per loan with static origination characteristics -- credit score, DTI, LTV, CLTV, interest rate, loan purpose, property type, occupancy, channel, state, seller, and servicer. The Performance file contains one record per loan per month, tracking the loan's ongoing status -- current UPB, delinquency status, modification flag, current rate, and upon termination, the zero balance code and disposition details. The two files are joined on the Loan Sequence Number. The files are pipe-delimited, released quarterly, and cover loans originated from 2000 onward.

### Q2: How would you handle the size of the Fannie Mae performance file?

**A:** The performance file is massive -- potentially hundreds of gigabytes across all vintages. My approach would be: (1) Partition the data by monthly reporting period or origination vintage to enable efficient querying of specific time ranges. (2) Use columnar storage formats like Parquet or Delta Lake rather than raw CSV/pipe-delimited files to leverage compression and column pruning. (3) Process using distributed frameworks like Spark if the full dataset is needed, or use incremental loading to process only new monthly observations. (4) Create materialized summary tables for common analytical queries (e.g., monthly CPR by vintage, delinquency transition matrices). (5) Apply proper data typing -- many fields that look numeric (like delinquency status) are actually strings due to values like 'RA', and handling this correctly prevents processing errors.

### Q3: What is the Zero Balance Code and why is it important?

**A:** The Zero Balance Code indicates why a loan was removed from the active portfolio. Key values include: 01 (prepaid or matured), 02 (third-party sale, usually foreclosure auction), 03 (short sale), 06 (repurchased by seller due to defect), 09 (REO disposition), 15 (note sale), and 16 (reperforming loan sale). This field is critical because it distinguishes voluntary prepayments from involuntary terminations (defaults), which is fundamental for both prepayment and credit modeling. A common mistake is treating all zero-balance events as prepayments -- codes 02, 03, and 09 represent credit events with associated losses, while code 01 represents voluntary prepayment with no loss.

### Q4: How do you calculate delinquency transitions using this data?

**A:** I would build a monthly transition matrix by: (1) Joining each loan's performance record with its prior month's record (self-join on loan_sequence_number with month offset). (2) Categorizing states as Current (0), 30-day (1), 60-day (2), 90+ day (3+), Modified, and Terminal (zero balance). (3) Counting transitions from each state to every other state for each monthly period. (4) Computing transition probabilities as the count of transitions from state A to state B divided by the total loans in state A at the start of the month. This produces a Markov transition matrix that can be segmented by vintage, FICO, LTV, or other characteristics to build credit models.

### Q5: What are the key differences between Fannie Mae's acquisition and performance files from a data engineering perspective?

**A:** The acquisition file is a dimension table (one row per loan, relatively static) while the performance file is a fact table (one row per loan per month, time-series). The acquisition file is small enough to fit in memory for most analyses; the performance file is orders of magnitude larger and requires partitioning. The acquisition file has fixed-width characteristics captured at origination; the performance file has time-varying metrics. In a data warehouse design, the acquisition file maps to a loan dimension table with SCD Type 1 (characteristics don't change), while the performance file maps to a monthly fact table partitioned by reporting period.

### Q6: How would you validate data quality in the Fannie Mae dataset?

**A:** Key validation checks include: (1) **Completeness**: Check for null/missing values in critical fields (FICO, LTV, DTI) and understand the business reason for missingness (older vintages have more missing data). (2) **Referential integrity**: Ensure every loan in the performance file exists in the acquisition file. (3) **Temporal consistency**: Verify that loan age increases monotonically, current UPB generally decreases, and delinquency status transitions are logical (a loan shouldn't go from 90+ days delinquent to current without a modification flag or cure). (4) **Range checks**: FICO between 300-850, LTV between 1-200, DTI between 0-65. (5) **Termination logic**: When zero_balance_code is populated, verify that subsequent months have no further performance records. (6) **Cross-field validation**: If loan_purpose is Purchase, CLTV should generally equal LTV (no subordinate liens at purchase, though exceptions exist).

### Q7: Explain CAS disclosure data and how it relates to the loan-level data.

**A:** Connecticut Avenue Securities (CAS) are Fannie Mae's credit risk transfer bonds. Each CAS deal references a specific pool of loans. Fannie Mae discloses loan-level data for these reference pools, along with monthly performance updates. The CAS disclosure data is related to but distinct from the general loan-level data -- CAS reference pools may include loans that are also in the public dataset, but the CAS disclosure provides deal-specific tracking including credit event definitions (e.g., 180+ days delinquent triggers a credit event) and tranche-level impact. A data engineer would need to build a system that links CAS deal definitions to reference pool loans, tracks qualifying credit events per the deal documents, and calculates cumulative losses against deal attachment/detachment points.

---

## Tips

1. **Download and explore the data**: The Fannie Mae dataset is freely available. Nothing demonstrates competence in an interview like being able to discuss specific quirks you encountered while working with the actual data (e.g., the pipe-delimited format with no headers, the string delinquency status field, the sheer size of the performance file).

2. **Know the data dictionary**: Be prepared to discuss at least 10-12 key fields from each file by memory. Interviewers will test whether you have actually worked with this data.

3. **Size matters**: Always address the scale challenge. The performance file for all vintages can exceed 100 GB compressed. Discuss your approach to partitioning, compression, and incremental processing.

4. **Vintage analysis**: Understand why vintage (origination year) is a critical segmentation variable. Loans originated in 2005-2007 had dramatically different performance than those originated in 2010-2013.

5. **Modification complexity**: Post-2008, loan modifications became prevalent. Modified loans create data complexity -- their rate, balance, and term change, and the modification flag is your only indicator. Be prepared to discuss how you handle modified loans in analysis.

6. **Cross-agency comparison**: Be ready to discuss how Fannie Mae data compares to Freddie Mac data (covered in the next section). Key differences in field names, definitions, and coverage are common interview topics.

7. **File format handling**: In technical interviews, you may be asked to write code to parse the pipe-delimited files, apply the data dictionary schema, and load into a database or data frame. Practice this with a small sample file.

8. **Regulatory context**: This data was made public as part of post-2008 transparency initiatives. FHFA (the conservator of Fannie Mae) mandated these disclosures. Understanding the regulatory motivation adds depth to your answers.

---
