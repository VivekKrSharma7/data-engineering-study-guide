# CoreLogic Data for Mortgage Analytics

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. LoanPerformance (LP) Database

CoreLogic's LoanPerformance database is the industry's most comprehensive repository of securitized loan-level mortgage data. It covers both agency and non-agency (private-label) mortgage-backed securities.

**Core Components:**

- **LP Securities Database:** Loan-level data on securitized mortgages, covering over 97% of the outstanding non-agency RMBS market and a substantial portion of agency MBS. Each record ties a loan to its securitization trust, tranche structure, and servicer.
- **LP ABS Database:** Asset-backed securities data including home equity lines of credit (HELOCs), manufactured housing, and other consumer ABS collateral.
- **LP Servicing Database:** Non-securitized loan performance data collected directly from mortgage servicers, providing a broader view of the mortgage market beyond what is securitized.

**Key Data Fields in LP:**

| Field Category | Example Fields |
|---|---|
| Loan Characteristics | Original balance, current balance, interest rate, loan type (FRM/ARM), term, origination date, LTV, CLTV, FICO at origination |
| Property Info | Property type, occupancy status, zip code, state, CBSA/MSA code, property valuation |
| Borrower Info | FICO score (origination and updated), DTI ratio, documentation type, borrower count |
| Performance | Current loan status, delinquency status, months delinquent, modification flag, foreclosure date, REO date, liquidation date, loss amount |
| Securitization | Deal name, tranche ID, pool number, servicer name, master servicer, trustee |

**Data History:** LP data extends back to the mid-1990s for non-agency and provides a rich time series for modeling default, prepayment, and loss severity across multiple credit cycles including the 2007-2009 financial crisis.

### 2. LLMA (Loan-Level Market Analytics)

LLMA is CoreLogic's platform for analyzing and querying loan-level data. It provides:

- **Query Builder:** Enables analysts and data engineers to construct complex filters on loan characteristics (e.g., vintage year, LTV band, FICO range, geography) and extract cohort-level data.
- **Transition Matrices:** Track loan status changes month-over-month (current to 30-day delinquent, 60-day to 90-day, etc.).
- **Vintage Analysis:** Compare performance of loan cohorts by origination year, allowing credit cycle analysis.
- **Custom Aggregations:** Users can group loans by any combination of attributes and compute summary statistics (CDR, CPR, loss severity, delinquency rates).

**Practical Use Case:** A data engineer might use LLMA to extract all subprime loans originated in 2006 with CLTV > 90% in California, then compute cumulative default rates by month-on-book to calibrate a credit model.

### 3. Property Data

CoreLogic is the largest aggregator of US property data, which is essential for mortgage analytics:

- **Tax Assessor Data:** Covers virtually every US parcel. Includes assessed value, tax amount, property characteristics (square footage, lot size, bedrooms, year built), legal description, and ownership information. Updated on a county-by-county basis as jurisdictions publish rolls.
- **Deed Recordings (Public Records):** Transaction history including sale price, buyer/seller, recording date, mortgage amount, lender name, and document type. Critical for establishing property value timelines and identifying cash-out refinances vs. rate-term refinances.
- **MLS (Multiple Listing Service) Data:** Listing price, days on market, listing status, agent information, and property marketing details. CoreLogic aggregates MLS data from hundreds of local boards, enabling national-level analysis of housing inventory and pricing trends.
- **AVM (Automated Valuation Models):** CoreLogic's proprietary AVMs use the property data above plus repeat-sales analytics to produce current property value estimates, which feed into updated LTV/CLTV calculations for portfolio surveillance.

### 4. CoreLogic HPI (House Price Index)

The CoreLogic Home Price Index is a repeat-sales index methodology (similar conceptually to Case-Shiller) that measures single-family home price changes over time.

**Key Characteristics:**

- **Geographic Granularity:** National, state, CBSA/MSA, county, and zip-code level indices.
- **Tiers:** Available segmented by price tier (low, middle, high) and by property type (attached, detached).
- **Frequency:** Monthly publication with a roughly two-month lag.
- **Methodology:** Uses a weighted repeat-sales approach, filtering out non-arm's-length transactions, foreclosure sales (distressed vs. non-distressed versions available), and statistical outliers.

**Use in Mortgage Analytics:** HPI is used to mark-to-market property values in a loan portfolio. By applying the HPI appreciation/depreciation since origination to the original appraised value, analysts calculate an updated property value and therefore an updated LTV/CLTV. This is critical for loss forecasting and credit risk assessment.

**Example Calculation:**

```
Original Appraised Value (2020-Q1): $300,000
CoreLogic HPI for ZIP 90210:
  - 2020-Q1 index: 250.0
  - 2024-Q4 index: 310.0

Appreciation Factor = 310.0 / 250.0 = 1.24
Estimated Current Value = $300,000 * 1.24 = $372,000

Current UPB = $260,000
Updated LTV = $260,000 / $372,000 = 69.9%
```

### 5. CBSA/MSA Geographic Data

Understanding geographic hierarchies is essential for CoreLogic data work:

- **CBSA (Core-Based Statistical Area):** Defined by the Office of Management and Budget (OMB). A geographic area consisting of one or more counties anchored by an urban center of at least 10,000 population.
- **MSA (Metropolitan Statistical Area):** A CBSA with a core urban area population of 50,000 or more.
- **Micropolitan Statistical Area:** A CBSA with a core urban area population between 10,000 and 49,999.
- **FIPS Codes:** Federal Information Processing Standards codes used to identify states (2-digit) and counties (5-digit: 2-digit state + 3-digit county). CoreLogic data is keyed to FIPS codes.

**Data Engineering Relevance:** When building databases from CoreLogic feeds, you must maintain a mapping table between ZIP codes, FIPS county codes, CBSA/MSA codes, and state codes. ZIP-to-county mappings are many-to-many (a ZIP can span multiple counties), which requires careful handling in joins and aggregations.

### 6. CLTV Calculation

**Combined Loan-to-Value (CLTV)** is the ratio of all mortgage liens against a property to the property value. It is a critical risk metric.

```
CLTV = (First Lien UPB + Second Lien UPB + HELOC Drawn Amount) / Property Value
```

**Challenges for Data Engineers:**

- **Lien Matching:** CoreLogic's LP database primarily tracks securitized first liens. Identifying subordinate liens requires matching across datasets using property identifiers (APN, address) or borrower identifiers, which is fuzzy and error-prone.
- **Property Value Determination:** Must decide whether to use original appraisal, AVM, or HPI-adjusted value. Each introduces different biases.
- **Point-in-Time Accuracy:** CLTV changes monthly as balances amortize and property values shift. Building a time-series CLTV requires monthly snapshots of both loan balances and property values.

### 7. Data Delivery Formats and Building Databases

**Delivery Formats:**

- **Flat Files (Pipe-Delimited or CSV):** The most common format for bulk data delivery. Files can be very large (multi-GB) and arrive monthly as full snapshots or incremental updates.
- **XML Feeds:** Used for some real-time or near-real-time data products.
- **API Access:** CoreLogic offers RESTful APIs for property data lookups (e.g., property details by address or APN).
- **LLMA Web Interface:** For ad-hoc queries and smaller extracts.

**Building a Database from CoreLogic Feeds:**

1. **Schema Design:** Map CoreLogic's data dictionary to your relational or columnar schema. LP data has hundreds of fields; select only those relevant to your use case to reduce storage and query cost.
2. **Staging Layer:** Ingest raw flat files into a staging area. Validate record counts, check for header/trailer consistency, and flag null or out-of-range values.
3. **Deduplication:** CoreLogic loan IDs are anonymized. Within a deal, loans are unique, but the same physical loan can appear in multiple products (e.g., LP Securities and LP Servicing) with different identifiers.
4. **Historical Snapshots:** LP data is delivered as monthly loan-level snapshots. Store these in a partitioned table (by reporting period) to enable time-series analysis without scanning the entire history.
5. **Slowly Changing Dimensions:** Loan-level attributes that change over time (e.g., servicer transfers, modifications, updated FICO) should be tracked using SCD Type 2 or snapshot-based approaches.
6. **Geography Enrichment:** Join CoreLogic loan data with FIPS/CBSA reference tables and HPI indices to enrich records with geographic context and updated property values.
7. **Quality Checks:** Implement automated checks for data completeness (expected loan count vs. delivered), field-level validation (e.g., interest rates within plausible range), and cross-month consistency (loan should not revert from foreclosure to current without a modification flag).

**Example Data Pipeline Architecture:**

```
CoreLogic SFTP --> Landing Zone (S3/ADLS)
    --> Staging (raw ingest, validation)
    --> Transformation (cleaning, enrichment, CLTV calc)
    --> Curated Layer (partitioned by reporting_period, indexed by deal/loan)
    --> Analytical Views (cohort summaries, transition matrices)
    --> BI / Model Consumption
```

---

## Real-World Examples

### Example 1: Building a Non-Agency RMBS Surveillance Database

A fixed-income asset manager needs to monitor the performance of 500+ non-agency RMBS deals. The data engineer:

- Ingests monthly CoreLogic LP Securities flat files (~40 million loan-month records).
- Loads into a Snowflake data warehouse partitioned by `reporting_period`.
- Joins with CoreLogic HPI data at the ZIP level to calculate updated LTVs.
- Builds dbt models to compute deal-level CDR, CPR, and loss severity by month.
- Creates Tableau dashboards showing delinquency pipelines and loss projections.

### Example 2: Property Value Refresh for a Mortgage Portfolio

A bank holding $50 billion in residential mortgages must update property values quarterly for CECL (Current Expected Credit Loss) accounting:

- Uses CoreLogic AVM data (batch delivery) to obtain current estimated values for each property.
- Falls back to HPI-adjusted values where AVM coverage is insufficient.
- Calculates updated LTV and CLTV for every loan.
- Feeds results into the bank's credit loss model to estimate lifetime expected losses.

### Example 3: Geographic Concentration Risk Analysis

A GSE risk team wants to identify geographic concentration in a pool of loans being considered for securitization:

- Maps each loan's property ZIP to CBSA/MSA using CoreLogic geography reference tables.
- Aggregates UPB by CBSA to identify concentration in specific metro areas.
- Cross-references with CoreLogic HPI trends to flag metros with above-average price declines.
- Reports top-10 MSA exposures with current and historical price index overlays.

---

## Common Interview Questions and Answers

### Q1: What is the CoreLogic LoanPerformance database and how is it used in MBS analytics?

**Answer:** CoreLogic LoanPerformance (LP) is the industry-standard source for loan-level data on securitized residential mortgages. The LP Securities database covers the vast majority of the non-agency RMBS market and contains detailed loan characteristics (origination balance, rate, LTV, FICO, property type, geography) along with monthly performance data (delinquency status, modification flags, liquidation outcomes, loss amounts). Analysts and data engineers use LP to construct transition matrices (tracking how loans move between performance states month-over-month), compute conditional default rates (CDR) and conditional prepayment rates (CPR), perform vintage analysis (comparing cohorts by origination year), and calibrate credit and prepayment models. The data is delivered as monthly flat files and is typically loaded into a data warehouse for time-series analysis.

### Q2: How would you calculate an updated LTV using CoreLogic HPI data?

**Answer:** To update LTV, you take the original appraised value from loan origination and apply the CoreLogic HPI appreciation or depreciation for the loan's geographic area (typically at the ZIP or CBSA level) between the origination date and the current period. Specifically: Updated Property Value = Original Appraisal * (Current HPI / HPI at Origination). Then Updated LTV = Current UPB / Updated Property Value. Important considerations include: choosing the right geographic granularity (ZIP-level HPI may be noisy for low-volume areas, so CBSA or county may be more stable), handling cases where HPI data is not available for a specific geography (use a broader geographic fallback), and recognizing that HPI reflects average market trends and does not capture property-specific renovations or deterioration.

### Q3: What challenges do you face when building a database from CoreLogic data feeds?

**Answer:** Key challenges include: (1) Volume -- monthly LP snapshots contain tens of millions of records, requiring efficient partitioning and incremental load strategies. (2) Data quality -- fields may have missing values, especially for older vintages or smaller servicers; data validation rules must be robust. (3) Schema evolution -- CoreLogic periodically adds or modifies fields in their data dictionary, requiring flexible schema management. (4) Identifier matching -- CoreLogic uses anonymized loan IDs that differ across products, making cross-product matching (e.g., LP Securities vs. LP Servicing) difficult. (5) Geographic mapping -- ZIP-to-county-to-CBSA mappings are many-to-many and change over time as OMB redefines CBSAs. (6) Timeliness -- data arrives with a 1-2 month lag, and different servicers report at different times within the month, so partial-month data must be handled. (7) Storage cost -- maintaining a full history of monthly snapshots for millions of loans over 20+ years requires thoughtful storage tiering and compression strategies.

### Q4: Explain the difference between CoreLogic LP Securities and LP Servicing databases.

**Answer:** LP Securities contains loan-level data specifically for loans that have been securitized into RMBS (both agency and non-agency). Each loan record is tied to a specific deal and tranche. The data is sourced from trustee reports and remittance files. LP Servicing, on the other hand, contains loan-level performance data collected directly from mortgage servicers and includes both securitized and non-securitized (portfolio) loans. LP Servicing provides a broader view of the overall mortgage market but does not contain securitization-specific fields (deal name, tranche). For a data engineer building a comprehensive mortgage analytics platform, combining both datasets is valuable but requires careful handling because the same physical loan can appear in both databases with different anonymized identifiers.

### Q5: How do you handle CBSA/MSA geographic mapping in a CoreLogic data pipeline?

**Answer:** I maintain a reference table that maps ZIP codes to FIPS county codes and then to CBSA/MSA codes. This mapping is sourced from the US Census Bureau (ZIP Code Tabulation Areas to counties) and OMB (counties to CBSAs). The key challenge is that ZIP-to-county is a many-to-many relationship -- a single ZIP code can span multiple counties. The standard approach is to use a crosswalk table that assigns a primary county to each ZIP (based on population or address density) or to use a proportional allocation approach where a loan is fractionally assigned to multiple counties. OMB also periodically redefines CBSAs (most recently in 2023), so the pipeline must version these mappings and apply the correct vintage based on the analysis period. In practice, I load the crosswalk tables into the data warehouse, join loan records to them on ZIP or FIPS code, and store both the county and CBSA on the enriched loan record.

### Q6: What is CLTV and why is it harder to calculate than LTV?

**Answer:** LTV (Loan-to-Value) considers only the first lien mortgage balance relative to property value. CLTV (Combined LTV) includes all liens -- first mortgage, second mortgage, HELOCs, and any other encumbrances. CLTV is harder because: (1) subordinate lien data is often held by different servicers and may not be in the same dataset as the first lien, (2) matching a second lien to its corresponding first lien requires property-level matching (using APN or address) which introduces fuzzy-match complexity, (3) HELOC balances fluctuate as borrowers draw and repay, so point-in-time accuracy is difficult, and (4) many subordinate liens are not securitized and therefore not in the LP Securities database at all. CoreLogic's property data (deed recordings) can help identify the existence of subordinate liens from public records, but current balances must be estimated or sourced from servicer data.

---

## Tips

1. **Understand the data dictionary thoroughly.** CoreLogic's LP data dictionary has hundreds of fields. Before building any pipeline, identify the 30-50 fields most relevant to your use case and document their definitions, allowable values, and known data quality issues.

2. **Partition by reporting period.** Always partition your CoreLogic loan performance tables by the monthly reporting period. This is the natural grain of the data and enables efficient time-series queries without full table scans.

3. **Build reconciliation checks early.** Compare your loaded record counts against CoreLogic's control totals. Implement balance checks (sum of current UPB should match expected totals) and status distribution checks (percentage of loans in each delinquency bucket should be reasonable).

4. **Cache geographic lookups.** ZIP-to-CBSA and FIPS-to-HPI lookups are performed on every loan record every month. Pre-join these into a denormalized reference table to avoid repeated lookups during transformation.

5. **Version your HPI indices.** CoreLogic revises historical HPI values. When you receive updated HPI files, store them with a vintage date so you can reproduce prior LTV calculations and understand the impact of revisions.

6. **Know the lag.** CoreLogic data arrives with a reporting lag (typically 1-2 months). Design your pipeline and downstream reports to clearly indicate the as-of date of the data, not the delivery date.

7. **Prepare for schema changes.** Use a flexible ingestion approach (e.g., read all columns as strings in staging, then cast in transformation) so that added or removed columns in CoreLogic's flat files do not break your pipeline.

8. **For interviews, emphasize the full pipeline.** Interviewers want to see that you understand not just the data content but the end-to-end engineering: ingestion, validation, transformation, enrichment, storage optimization, and consumption layer design.
