# HMDA Data & Fair Lending

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### HMDA — Home Mortgage Disclosure Act

The **Home Mortgage Disclosure Act (HMDA)** was enacted by Congress in 1975 (12 U.S.C. 2801-2810) and is implemented by **Regulation C** (12 CFR Part 1003), currently administered by the CFPB. HMDA is the single most important public data source for understanding mortgage lending patterns in the United States.

**Legislative Purpose:**
1. Help determine whether financial institutions are serving the housing needs of their communities
2. Assist public officials in distributing public-sector investment to attract private investment
3. Assist in identifying possible discriminatory lending patterns and enforcing antidiscrimination statutes

**Key Milestones:**

| Year | Event |
|------|-------|
| 1975 | HMDA enacted; basic geographic lending data required |
| 1989 | FIRREA amendments added loan-level data, race, income, action taken |
| 2002 | Regulation C amendments added pricing data (rate spread) for HPML |
| 2010 | Dodd-Frank transferred HMDA rulemaking from Federal Reserve to CFPB |
| 2015 | CFPB finalized major HMDA rule revisions (effective 2018) |
| 2018 | Expanded HMDA data collection began (~110 fields) |
| 2020 | EGRRCPA partial rollback for smaller institutions |

**Who Must Report:**
- Depository institutions (banks, thrifts, credit unions) meeting asset and activity thresholds
- Non-depository mortgage lenders meeting activity thresholds
- Thresholds: Generally, institutions that originated at least 100 closed-end mortgage loans or 200 open-end lines of credit in each of the two preceding calendar years

---

### LAR — Loan Application Register

The **Loan Application Register (LAR)** is the core data structure for HMDA reporting. Each row represents one mortgage application or loan, and each institution submits its LAR annually to its supervisory agency (which forwards it to the CFPB).

**LAR Record Structure (Post-2018 HMDA Rule):**

The modernized LAR contains approximately **110 data fields** organized into these categories:

**Application/Loan Information:**
- Universal Loan Identifier (ULI) — replaced LAR Sequence Number
- Application date
- Loan type (Conventional, FHA, VA, USDA)
- Loan purpose (Purchase, Refinance, Cash-out Refinance, Home Improvement, Other)
- Preapproval status
- Construction method (Site-built, Manufactured)
- Occupancy type (Principal residence, Second residence, Investment)

**Property Information:**
- Property address (street, city, state, ZIP)
- County FIPS code
- Census tract (11-digit)
- Property value
- Number of units (1-4)
- Manufactured home details (land property interest, secured property type)

**Loan Terms:**
- Loan amount
- Combined loan-to-value ratio (CLTV)
- Interest rate
- Rate spread (APR minus APOR)
- HOEPA status
- Loan term
- Introductory rate period
- Non-amortizing features (balloon, interest-only, negative amortization, other)
- Prepayment penalty term

**Borrower Demographics:**
- Ethnicity (applicant and co-applicant, disaggregated subcategories)
- Race (applicant and co-applicant, disaggregated subcategories)
- Sex (applicant and co-applicant)
- Age (applicant and co-applicant)
- Income (in thousands)
- Credit score (applicant and co-applicant, plus scoring model used)
- Debt-to-income ratio (ranges)

**Action and Status:**
- Action taken (see below)
- Action taken date
- Denial reasons (up to 4)
- Purchaser type (identifying secondary market channel)

**Originator and Channel:**
- Legal Entity Identifier (LEI)
- NMLS identifier
- Automated underwriting system (AUS) used and result
- Reverse mortgage flag
- Open-end line of credit flag
- Business or commercial purpose flag

**Action Taken Codes:**

| Code | Description |
|------|-------------|
| 1 | Loan originated |
| 2 | Application approved but not accepted |
| 3 | Application denied |
| 4 | Application withdrawn by applicant |
| 5 | File closed for incompleteness |
| 6 | Purchased loan |
| 7 | Preapproval request denied |
| 8 | Preapproval request approved but not accepted |

**Purchaser Type Codes (Secondary Market Channel):**

| Code | Purchaser |
|------|-----------|
| 0 | Not applicable (not sold in reporting year) |
| 1 | Fannie Mae |
| 2 | Ginnie Mae |
| 3 | Freddie Mac |
| 4 | Farmer Mac |
| 5 | Private securitizer |
| 6 | Commercial bank, savings bank, or savings association |
| 71 | Credit union, mortgage company, or finance company |
| 72 | Life insurance company |
| 8 | Affiliate institution |
| 9 | Other type of purchaser |

---

### HMDA Data Fields Deep Dive

**Race and Ethnicity (Post-2018 Disaggregated Categories):**

The 2018 HMDA rule introduced disaggregated race and ethnicity categories to capture more granular demographic data:

**Ethnicity:**
- Hispanic or Latino
  - Mexican
  - Puerto Rican
  - Cuban
  - Other Hispanic or Latino (with free-form text)
- Not Hispanic or Latino
- Information not provided
- Not applicable

**Race:**
- American Indian or Alaska Native (with tribal enrollment or principal tribe free-form)
- Asian
  - Asian Indian, Chinese, Filipino, Japanese, Korean, Vietnamese, Other Asian
- Black or African American
- Native Hawaiian or Other Pacific Islander
  - Native Hawaiian, Guamanian or Chamorro, Samoan, Other Pacific Islander
- White
- Information not provided
- Not applicable

**Data Engineering Implications of Disaggregated Demographics:**
- Multiple race and ethnicity selections per applicant (up to 5 race categories)
- Free-form text fields for tribal affiliation and "Other" subcategories
- Complex logic required to aggregate to summary categories for analysis
- Privacy considerations when working with small geographies or rare subcategories

**Credit Score and DTI (New in 2018):**
- Credit score reported as numeric value (300-850 range typically)
- Scoring model name (e.g., "Equifax Beacon 5.0", "FICO Score 9")
- DTI reported in ranges (e.g., "36%-49%", "50%-60%", ">60%")
- These fields were not available in pre-2018 HMDA data

**Automated Underwriting System (AUS):**
- AUS name: Desktop Underwriter (DU), Loan Prospector (LP), Technology Open to Approved Lenders (TOTAL), Guaranteed Underwriting System (GUS), Other
- AUS result: Approve/Eligible, Approve/Ineligible, Refer/Eligible, Refer/Ineligible, etc.

---

### CFPB HMDA Data Portal

The CFPB maintains the primary public portal for HMDA data at **https://ffiec.cfpb.gov/**.

**Available Data Products:**

| Product | Description | Format |
|---------|-------------|--------|
| Modified LAR | Institution-level, loan-level data (PII redacted) | CSV, Pipe-delimited |
| Aggregate Reports | MSA/county-level summary tables by lender | HTML, CSV |
| Disclosure Reports | Institution-specific summary reports | HTML, CSV |
| Snapshot National Loan-Level Dataset | All reporters, all records for a year | CSV (very large) |
| Dynamic National Loan-Level Dataset | Updated throughout filing period | CSV |
| HMDA Data Browser | Interactive query tool with API | Web, CSV, API |

**HMDA Data Browser API:**
The CFPB provides a public API for querying HMDA data programmatically:
```
GET https://ffiec.cfpb.gov/v2/data-browser-api/view/csv
    ?states=MD
    &years=2023
    &actions_taken=1
    &loan_types=1
```

**Scale of HMDA Data:**
- Approximately **20-25 million records per year** across all reporters
- 2022 HMDA data: ~22 million records from ~5,000 reporting institutions
- National snapshot file is typically 5-10 GB (CSV)
- Historical data available back to 2007 on the CFPB portal (prior years from FFIEC)

**Data Engineering Use Cases with HMDA Data:**
1. Market share analysis by geography, product type, and demographic
2. Peer benchmarking (compare your institution's lending patterns to competitors)
3. Fair lending screening and monitoring
4. CRA (Community Reinvestment Act) performance assessment support
5. Market opportunity analysis for expansion planning
6. Pricing analysis (using rate spread data)
7. Secondary market flow analysis (using purchaser type)

---

### Fair Lending Analysis

Fair lending analysis uses HMDA data and internal loan data to identify potential discriminatory lending patterns. The legal framework is based on:

- **Equal Credit Opportunity Act (ECOA):** Prohibits discrimination on the basis of race, color, religion, national origin, sex, marital status, age, receipt of public assistance, or exercise of rights under the Consumer Credit Protection Act
- **Fair Housing Act (FHA):** Prohibits discrimination in residential real estate transactions on the basis of race, color, national origin, religion, sex, familial status, or disability

**Types of Discrimination:**

| Type | Description | Example |
|------|-------------|---------|
| Overt Discrimination | Explicit use of prohibited basis in decisions | Policy excluding loans in certain ZIP codes |
| Disparate Treatment | Different treatment based on prohibited basis | Requiring additional documentation from minority applicants |
| Disparate Impact | Neutral policy with disproportionate adverse effect | Minimum loan amount policy that disproportionately excludes minority borrowers |

**Statistical Methods Used in Fair Lending Analysis:**

1. **Regression Analysis:** Logistic regression modeling denial probability as a function of legitimate credit factors and prohibited basis variables
   - Dependent variable: Denial (1/0) or rate spread (continuous)
   - Independent variables: Credit score, DTI, LTV, loan amount, property type (legitimate factors)
   - Prohibited basis variables: Race, ethnicity, sex, age
   - Statistically significant prohibited basis coefficient suggests disparate treatment

2. **Matched-Pair Analysis:** Compare outcomes for similarly situated applicants who differ on a prohibited basis characteristic
   - Select minority applicants
   - Match to non-minority applicants with similar credit profiles
   - Compare denial rates, pricing, and terms

3. **Marginal Effect Analysis:** Estimate the practical significance of any statistical disparity
   - Even a statistically significant coefficient may have small practical impact
   - Regulators consider both statistical and practical significance

4. **Benchmarking:** Compare institutional denial rate disparities to peer or market averages
   - HMDA data enables this comparison at the MSA or county level
   - Higher-than-peer disparities may trigger examiner scrutiny

**Key Metrics:**

| Metric | Formula | Threshold |
|--------|---------|-----------|
| Denial Rate Disparity | Minority denial rate / Non-minority denial rate | Ratios > 2.0 draw scrutiny |
| Pricing Disparity | Average rate spread difference (minority vs. non-minority) | Depends on context |
| Approval Odds Ratio | Odds of approval for non-minority / Odds for minority | Ratios significantly > 1.0 |
| Geographic Penetration | % of loans in majority-minority tracts vs. peer | Lower-than-peer may indicate redlining |

---

### Redlining Analysis

**Redlining** refers to the practice of avoiding lending in geographic areas with high concentrations of minority residents. Modern redlining analysis uses HMDA data to detect this pattern statistically.

**Traditional Redlining Analysis Framework:**

1. **Define the assessment area:** Typically the institution's CRA assessment area or MSA
2. **Classify census tracts:** By racial/ethnic composition (majority-minority vs. non-minority) using Census data
3. **Calculate lending penetration:** Number and dollar amount of loans in majority-minority tracts vs. non-minority tracts
4. **Compare to peers:** Benchmark the institution's minority-tract penetration against aggregate HMDA data for all lenders in the area
5. **Control for demand:** Adjust for differences in housing stock, owner-occupied units, and home purchase activity

**Data Sources for Redlining Analysis:**

| Source | Fields Used |
|--------|-------------|
| HMDA | Census tract, action taken, loan amount, race, purchaser type |
| Census / ACS | Tract-level demographics, income, housing characteristics |
| FFIEC Census File | Tract median income, MSA median income, tract income category |
| Institution CRA data | Assessment area definition, branch locations |

**Red Flags for Redlining:**
- Significantly lower application volume in majority-minority tracts compared to peers
- No or minimal marketing activity in majority-minority areas
- Branch closures in minority neighborhoods without offsetting outreach
- Lending volume does not align with housing market activity in minority tracts

**Data Engineering for Redlining Analysis:**
- Join HMDA data to Census tract-level demographics using 11-digit FIPS census tract code
- Build peer comparison datasets by aggregating HMDA data for all lenders in the same MSA
- Calculate penetration ratios and confidence intervals
- Visualize lending patterns with GIS mapping (loans geocoded to census tracts)
- Automate annual monitoring to detect trends

---

### CRA Compliance

The **Community Reinvestment Act (CRA)** of 1977 requires banking regulators to evaluate how well each insured depository institution helps meet the credit needs of its entire community, including low- and moderate-income (LMI) neighborhoods.

**CRA and HMDA Intersection:**

HMDA data is one of the primary data sources used in CRA examinations, particularly for the **Lending Test:**

| CRA Test | Weight | HMDA Relevance |
|----------|--------|----------------|
| Lending Test | 50% | HMDA data used to evaluate geographic distribution, borrower characteristics, and innovative lending |
| Investment Test | 25% | Less directly linked to HMDA |
| Service Test | 25% | Less directly linked to HMDA |

**CRA Income Categories (Census Tract):**

| Category | Tract Median Income / MSA Median Income |
|----------|------------------------------------------|
| Low Income | < 50% |
| Moderate Income | 50% - 79% |
| Middle Income | 80% - 119% |
| Upper Income | ≥ 120% |

**CRA Lending Test Metrics from HMDA Data:**
- Distribution of loans by tract income category (compared to demographics and peer)
- Distribution of loans by borrower income category (low, moderate, middle, upper)
- Market share in LMI tracts compared to overall market share
- Lending trends over examination period

**CRA Modernization (2023-2024 Final Rule):**
- New evaluation framework with retail lending, retail services, community development tests
- Auto-loan data now included in CRA evaluations (separate from HMDA)
- New metrics based on HMDA data including loan count, loan dollar volume, and comparative market analysis
- Increased emphasis on census tract-level analysis

---

### Using HMDA Data for Analytics

HMDA data is a rich resource for data engineers building mortgage analytics platforms:

**Market Analysis:**
```sql
-- Market share analysis by MSA for 2023 originations
SELECT
    lei,
    respondent_name,
    COUNT(*) AS loan_count,
    SUM(loan_amount) AS total_volume,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS market_share_pct
FROM hmda_lar_2023
WHERE action_taken = 1              -- Originated
  AND loan_purpose = 1              -- Purchase
  AND state_code = '24'             -- Maryland
  AND msa_md = '12580'              -- Baltimore MSA
GROUP BY lei, respondent_name
ORDER BY loan_count DESC
LIMIT 20;
```

**Demographic Lending Patterns:**
```sql
-- Denial rates by race for conventional purchase loans
SELECT
    derived_race,
    COUNT(*) AS total_applications,
    SUM(CASE WHEN action_taken = 3 THEN 1 ELSE 0 END) AS denials,
    ROUND(100.0 * SUM(CASE WHEN action_taken = 3 THEN 1 ELSE 0 END)
        / COUNT(*), 2) AS denial_rate_pct
FROM hmda_lar_2023
WHERE loan_type = 1                 -- Conventional
  AND loan_purpose = 1              -- Purchase
  AND action_taken IN (1, 2, 3)     -- Originated, Approved, Denied
  AND derived_race IS NOT NULL
GROUP BY derived_race
ORDER BY denial_rate_pct DESC;
```

**Secondary Market Flow:**
```sql
-- Secondary market purchaser distribution
SELECT
    CASE purchaser_type
        WHEN 1 THEN 'Fannie Mae'
        WHEN 2 THEN 'Ginnie Mae'
        WHEN 3 THEN 'Freddie Mac'
        WHEN 5 THEN 'Private Securitizer'
        WHEN 0 THEN 'Held in Portfolio'
        ELSE 'Other'
    END AS purchaser,
    COUNT(*) AS loan_count,
    SUM(loan_amount) AS total_volume_thousands
FROM hmda_lar_2023
WHERE action_taken IN (1, 6)        -- Originated or Purchased
GROUP BY purchaser_type
ORDER BY loan_count DESC;
```

**Pricing Analysis:**
```sql
-- Average rate spread by race and income for originated conventional loans
SELECT
    derived_race,
    CASE
        WHEN income <= 50 THEN 'Low Income'
        WHEN income <= 80 THEN 'Moderate Income'
        WHEN income <= 120 THEN 'Middle Income'
        ELSE 'Upper Income'
    END AS income_category,
    COUNT(*) AS loan_count,
    ROUND(AVG(rate_spread), 3) AS avg_rate_spread
FROM hmda_lar_2023
WHERE action_taken = 1
  AND loan_type = 1
  AND rate_spread IS NOT NULL
GROUP BY derived_race, income_category
ORDER BY derived_race, income_category;
```

---

## Real-World Examples

### Example 1: Building a Fair Lending Monitoring System

A large retail bank wants to proactively monitor fair lending risk across its mortgage origination business.

**Architecture:**
```
Internal LOS Data ----+
                      |
HMDA LAR Data --------+--> Fair Lending Data Warehouse
                      |         |
Census/ACS Data ------+    +----+----+
                           |         |
                     Regression   Benchmarking
                      Analysis     Analysis
                           |         |
                      +----+----+----+
                           |
                    Risk Dashboard
                           |
              +------------+------------+
              |            |            |
         Denial Rate   Pricing      Geographic
         Disparities   Disparities  Penetration
```

**Pipeline Steps:**
1. **Monthly:** Extract internal loan and application data from LOS; load HMDA public data annually for peer benchmarking
2. **Quarterly:** Run logistic regression models for denial disparities and linear regression for pricing disparities, controlling for legitimate credit factors
3. **Annually:** Generate full fair lending analysis report with peer comparisons and geographic mapping
4. **Ongoing:** Monitor for outlier branches, loan officers, or products

**Key Data Fields for the Model:**
- **Outcome variables:** Denial (binary), rate spread (continuous)
- **Legitimate factors:** Credit score, DTI, LTV, loan amount, loan type, property type, occupancy
- **Prohibited basis:** Race (derived), ethnicity (derived), sex, age
- **Geography:** Census tract, MSA, county

### Example 2: HMDA Data Warehouse for Market Intelligence

A mortgage company builds a comprehensive HMDA analytics platform to support market strategy.

**Data Model:**

**Fact Table: `fact_hmda_application`**
- One row per application/loan
- ~110 HMDA fields plus derived fields
- Partitioned by year

**Dimension Tables:**
- `dim_geography` — Census tract demographics, income classification, urban/rural
- `dim_institution` — LEI, name, type (bank, credit union, non-depository), asset size
- `dim_loan_product` — Loan type, purpose, lien status, occupancy
- `dim_time` — Application date, action date, year, quarter

**Derived Fields:**
- `derived_race` — Simplified race category using CFPB derivation logic
- `derived_ethnicity` — Simplified ethnicity category
- `tract_income_category` — Low, Moderate, Middle, Upper based on FFIEC census file
- `borrower_income_category` — Based on borrower income relative to MSA median
- `market_share_rank` — Institution's rank in each MSA by loan count

### Example 3: Automating Annual HMDA Submission

A data engineer automates the end-to-end HMDA submission process for a mortgage lender.

**Pipeline:**
1. **Data Collection (January):** Extract all applications and originations from the prior calendar year from the LOS, servicing system, and secondary marketing system
2. **Field Population (January-February):** Map internal fields to HMDA fields; look up census tracts via geocoding; calculate rate spread using APOR tables; derive demographic fields from application data
3. **Validation (February):** Run CFPB's HMDA edits (syntactical, validity, quality, and macro quality edits); resolve edit failures
4. **Submission (March 1 deadline):** Submit LAR file through the CFPB's HMDA Platform (beta.ffiec.cfpb.gov)
5. **Post-Submission:** Respond to any resubmission requests; prepare for examiner inquiries

**HMDA Edit Types:**

| Edit Type | Description | Example |
|-----------|-------------|---------|
| Syntactical | File format and structure | Record count mismatch, invalid characters |
| Validity | Individual field values | Invalid action taken code, missing required field |
| Quality | Logical consistency | Rate spread reported for denied application |
| Macro Quality | Aggregate reasonableness | Total loan count changed >20% from prior year |

---

## Common Interview Questions & Answers

### Q1: What is HMDA and why is it important for data engineers in the mortgage industry?

**A:** HMDA is the Home Mortgage Disclosure Act, which requires mortgage lenders to collect and publicly disclose data about their lending activity. It is critically important for data engineers because it represents one of the largest standardized public datasets in the mortgage industry, with approximately 20-25 million records per year and roughly 110 fields per record. Data engineers work with HMDA data in several contexts: building the internal HMDA reporting pipeline for their institution's annual submission, using public HMDA data for market analysis and competitive intelligence, supporting fair lending analysis and CRA compliance, and building analytics platforms that combine HMDA data with Census demographics and other data sources. The 2018 HMDA rule expansion added fields like credit score, DTI, property value, and AUS results, making it even more valuable for analytics.

### Q2: How would you build a pipeline for annual HMDA submission?

**A:** I would build a pipeline with five stages. First, extraction: pull all mortgage applications and originations for the calendar year from the loan origination system, secondary marketing system, and servicing system. Second, transformation: map internal fields to the approximately 110 HMDA fields, geocode property addresses to census tracts using the Census Bureau's geocoder or a commercial geocoding service, calculate rate spread using FFIEC APOR tables, and apply the CFPB's race and ethnicity derivation logic for the derived demographic fields. Third, validation: run the CFPB's published HMDA edits including syntactical, validity, quality, and macro quality checks, then route failures to a remediation workflow. Fourth, submission: format the final LAR file and submit through the CFPB's HMDA Platform before the March 1 deadline. Fifth, reconciliation: compare submitted data against internal records, archive the final submission for audit purposes, and prepare documentation for examiner inquiries. I would automate this pipeline using an orchestration tool like Airflow, with the validation step running iteratively until all edits pass or are explained.

### Q3: Explain how HMDA data is used in fair lending analysis. What statistical methods are involved?

**A:** HMDA data is the foundational dataset for fair lending analysis. The primary methods include logistic regression analysis for denial disparities, where denial is modeled as a function of legitimate credit factors and prohibited basis characteristics, with a statistically significant race or ethnicity coefficient indicating potential disparate treatment. Linear regression is used similarly for pricing analysis, with rate spread as the dependent variable. Matched-pair analysis compares outcomes for minority and non-minority applicants with similar credit profiles. Benchmarking compares the institution's denial rate disparities and geographic penetration to peer averages using public HMDA data. For redlining analysis, HMDA data is joined to census tract demographics to measure lending penetration in majority-minority tracts compared to peers. The challenge for data engineers is building reproducible analytical pipelines that properly handle data quality issues, correctly join HMDA to Census data, and produce results that can withstand regulatory scrutiny.

### Q4: What changed in the 2018 HMDA rule and how did it affect data engineering?

**A:** The 2018 HMDA rule, finalized by the CFPB in 2015, approximately tripled the number of data fields from roughly 30-40 to about 110. Key additions included credit score and scoring model, debt-to-income ratio, combined loan-to-value ratio, property value, loan term, interest rate, rate spread for all loans (not just HPML), automated underwriting system and result, disaggregated race and ethnicity subcategories, age, and the Universal Loan Identifier (ULI) replacing the sequence number. For data engineers, this meant expanding data extraction from origination systems to capture these new fields, building new mapping and derivation logic, updating validation pipelines for new edit checks, redesigning the HMDA data model and warehouse to accommodate the expanded field set, and updating all downstream analytics and reports. The disaggregated race and ethnicity categories were particularly complex because applicants can select multiple categories, requiring careful handling in both storage and analysis.

### Q5: How would you use HMDA data to analyze secondary market flows?

**A:** HMDA data includes a "purchaser type" field that identifies what entity purchased the loan (Fannie Mae, Freddie Mac, Ginnie Mae, private securitizer, portfolio, etc.). I would build an analytics pipeline that aggregates origination volume by purchaser type, sliced by dimensions like loan type, loan purpose, geography, borrower demographics, and time period. This reveals patterns such as what percentage of conventional purchase loans flow to Fannie Mae vs. Freddie Mac, how portfolio retention rates differ by institution size, whether certain loan characteristics (high LTV, low credit score) are more likely to flow to specific GSEs, and how secondary market channel distribution varies by geography. I would combine this with public GSE loan-level performance data (Fannie Mae and Freddie Mac both publish historical loan-level datasets) to connect origination characteristics to secondary market performance. This analysis supports market strategy decisions like which products to originate and which delivery channel to target.

### Q6: What is redlining and how would you build a data pipeline to detect it?

**A:** Redlining is the practice of avoiding lending in areas with high minority concentrations. To detect it, I would build a pipeline that joins HMDA application and origination data with census tract-level demographic data from the American Community Survey. The pipeline would classify census tracts as majority-minority or non-minority based on racial composition, calculate the institution's lending penetration in each tract type (applications per owner-occupied housing unit), compute the same metric for all peer lenders in the MSA using public HMDA data, and compare the institution's minority-tract penetration ratio to the peer ratio. A significantly lower penetration in minority tracts relative to peers, after controlling for factors like branch locations, housing stock, and demand indicators, is a red flag for potential redlining. I would present results in both tabular and geographic (GIS) formats, with mapping showing lending heat maps overlaid with tract demographics.

---

## Tips

1. **Know your HMDA data fields:** You do not need to memorize all 110 fields, but you should know the major categories and be able to discuss key fields like action taken, loan type, loan purpose, race, ethnicity, income, rate spread, credit score, DTI, purchaser type, and census tract.

2. **Understand the derived fields:** The CFPB creates several derived fields in the public data (derived_race, derived_ethnicity, derived_sex, derived_loan_product_type, derived_dwelling_category). Know what these are and why they exist — they simplify analysis by resolving multiple-selection race and ethnicity into a single summary category.

3. **Census tract is the geographic key:** The 11-digit FIPS census tract code is the primary geographic identifier in HMDA data. Know that it consists of 2-digit state FIPS + 3-digit county FIPS + 6-digit tract number, and that it links to Census demographics and FFIEC income classifications.

4. **Rate spread is critical for pricing analysis:** Rate spread (APR minus APOR) is the standard pricing metric in HMDA data. Before 2018, it was only reported for HPML; after 2018, it is reported for all originated loans. This expansion enabled much more robust pricing disparity analysis.

5. **Be ready to discuss privacy:** HMDA modified LAR data redacts certain fields (e.g., exact property address is removed, age is reported as a range, census tract may be removed for very small tracts). Understand why these redactions exist and how they affect analysis.

6. **HMDA data quality is imperfect:** Self-reported data from thousands of institutions means quality varies. Some fields are reported as "NA" or "Exempt" more often than expected. Be prepared to discuss how you handle missing or unreliable data in fair lending analysis.

7. **Connect HMDA to CRA:** CRA examinations heavily rely on HMDA data for the Lending Test. Know the four tract income categories (Low, Moderate, Middle, Upper) and how they are determined using MSA median family income from the FFIEC census file.

8. **Know the regulators' analytical approach:** The DOJ, CFPB, and prudential regulators (OCC, Fed, FDIC) each use HMDA data in fair lending examinations but may emphasize different metrics. The DOJ focuses on pattern-or-practice discrimination cases; the CFPB uses both HMDA and internal data in supervisory exams; prudential regulators incorporate fair lending into safety-and-soundness exams.
