# SEC Regulation AB-II & Disclosure Requirements

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Regulation AB-II Overview

**Regulation AB-II** (formally the amendments to Regulation AB under the Securities Act of 1933) was adopted by the SEC in August 2014, with compliance dates phased in from November 2015 through 2016. It represents the most significant overhaul of asset-backed securities (ABS) disclosure requirements since the original Regulation AB was adopted in 2004.

**Historical Context:**

| Timeline | Event |
|----------|-------|
| 2004 | Original Regulation AB adopted |
| 2008 | Financial crisis exposes inadequate ABS disclosures |
| 2010 | Dodd-Frank Act Section 942(b) mandates asset-level disclosure |
| 2011 | SEC proposes Reg AB-II (Re-proposal) |
| 2014 | Final Reg AB-II rule adopted |
| 2015-2016 | Phased compliance dates |

**Core Objectives of Reg AB-II:**
1. Provide investors with asset-level data to perform independent credit analysis
2. Reduce reliance on credit ratings for investment decisions
3. Standardize disclosure formats across issuers
4. Improve ongoing reporting for outstanding ABS
5. Enhance the shelf registration process to ensure issuer accountability

**Scope — Covered Asset Classes:**
- Residential mortgage-backed securities (RMBS)
- Commercial mortgage-backed securities (CMBS)
- Auto loans and leases
- Equipment loans and leases
- Student loans
- Floorplan financings
- Credit card receivables (pool-level disclosure only due to revolving nature)

---

### Asset-Level Disclosure Requirements

The cornerstone of Reg AB-II is the requirement for **asset-level data disclosure** for each asset in a securitization pool at the time of offering and on an ongoing basis.

**Key Principles:**

- **Loan-level granularity:** Each asset in the pool must be individually reported (no aggregation or stratification as a substitute)
- **Standardized fields:** SEC defined specific data fields for each asset class with standardized definitions and code values
- **Machine-readable format:** All data must be filed in XML format on EDGAR
- **Ongoing reporting:** Asset-level data must be updated with each periodic distribution report (typically monthly)
- **Unique asset identifier:** Each asset must have a unique identifier, but PII (borrower name, SSN, property address) must be excluded or anonymized

**Disclosure Timing:**

| Disclosure Type | Timing | Filing |
|-----------------|--------|--------|
| Prospectus (offering) | At or before first sale | Form SF-1 or SF-3 |
| Asset-level data (offering) | At or before first sale | Schedule AL (XML on EDGAR) |
| Ongoing periodic reports | Monthly (per trust agreement) | Form 10-D with Schedule AL |
| Annual reports | Annually | Form 10-K |
| Current reports | Material events | Form 8-K |

---

### The 270+ Required Data Fields

For RMBS specifically, the SEC defined approximately **270+ data fields** organized into logical groups. These fields span the entire lifecycle of a residential mortgage loan.

**Field Categories for RMBS (Schedule AL — Item 1):**

| Category | Example Fields | Approximate Count |
|----------|---------------|-------------------|
| Asset Identifiers | Asset number, group ID, original sequence | ~10 |
| Origination | Origination date, original balance, original rate, original term | ~15 |
| Loan Characteristics | Loan purpose, occupancy, property type, documentation type | ~20 |
| Property | State, ZIP (3-digit), MSA, property value, valuation method | ~15 |
| Borrower | Credit score at origination, co-borrower indicator, first-time buyer | ~10 |
| Underwriting | Original LTV, original CLTV, DTI, income verification | ~15 |
| ARM/Rate Details | Index type, margin, rate adjustment frequency, caps, floors | ~25 |
| Current Loan Status | Current balance, current rate, payment status, delinquency | ~20 |
| Payment Activity | Scheduled payment, actual payment, principal applied, interest applied | ~20 |
| Modification | Modification flag, modification date, modification type, modified terms | ~25 |
| Loss Mitigation | Workout type, forbearance date, trial period | ~15 |
| Liquidation/REO | Liquidation date, liquidation proceeds, REO flag, REO expenses | ~20 |
| Servicing | Current servicer, master servicer, servicing fee rate, subservicer | ~10 |
| Credit Enhancement | MI coverage, pool insurance, subordination amount | ~10 |
| Performance | Months delinquent, cumulative loss, recovery amounts | ~15 |
| Additional | Prepayment penalty flag, geographic concentration, channel | ~25 |

**Critical Fields for Data Engineers:**

```
Asset Number Identifier                 (assetNumber)
Reporting Period Begin Date             (reportingPeriodBeginDate)
Reporting Period End Date               (reportingPeriodEndDate)
Original Loan Amount                    (originalLoanAmount)
Original Interest Rate                  (originalInterestRate)
Original Loan Term                      (originalLoanTerm)
Origination Date                        (originationDate)
Original LTV                            (originalLTV)
Borrower Credit Score at Origination    (obligorCreditScore)
Current Loan Balance                    (currentActualBalance)
Current Interest Rate                   (currentInterestRate)
Payment Status                          (paymentStatus)
Months Delinquent                       (numberOfMonthsDelinquent)
Modification Flag                       (modificationFlag)
Liquidation Proceeds                    (liquidationProceeds)
Loss Amount                             (realizedLossAmount)
```

---

### XML Reporting Format

Reg AB-II mandates that all asset-level data be filed on EDGAR in **XML format** using SEC-defined schemas (XSD files).

**XML Schema Structure:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<assetData xmlns="http://www.sec.gov/edgar/document/absee">
  <reportingPeriodBeginDate>2025-01-01</reportingPeriodBeginDate>
  <reportingPeriodEndDate>2025-01-31</reportingPeriodEndDate>
  <assetRelatedDocument>
    <asset>
      <assetNumber>LOAN-001</assetNumber>
      <originalLoanAmount>250000.00</originalLoanAmount>
      <originalInterestRate>6.500</originalInterestRate>
      <originationDate>2024-03-15</originationDate>
      <currentActualBalance>245832.17</currentActualBalance>
      <currentInterestRate>6.500</currentInterestRate>
      <paymentStatus>Current</paymentStatus>
      <!-- ... 270+ fields ... -->
    </asset>
    <asset>
      <!-- Next loan ... -->
    </asset>
  </assetRelatedDocument>
</assetData>
```

**XML Schema (XSD) Key Points:**
- SEC publishes separate XSD files for each asset class (RMBS, CMBS, Auto, etc.)
- Fields have defined data types (string, decimal, date, enumeration)
- Enumerated fields use SEC-defined code values (e.g., Property Type: "SF" = Single Family, "CO" = Condo)
- Some fields are conditionally required (e.g., ARM fields only required if the loan is adjustable rate)
- Validation against the XSD is performed by EDGAR upon filing

**Filing Process:**
1. Issuer/trustee generates asset-level data from servicing systems
2. Data is transformed into XML conforming to SEC XSD schema
3. XML is validated locally (schema validation + business rules)
4. Filed on EDGAR as an exhibit to Form 10-D (ongoing) or as Schedule AL (offering)
5. EDGAR performs technical validation and accepts or rejects the filing

---

### EDGAR Filing

**EDGAR (Electronic Data Gathering, Analysis, and Retrieval)** is the SEC's filing system where all Reg AB-II disclosures are publicly available.

**Key EDGAR Components for ABS:**

| Component | Description |
|-----------|-------------|
| Form SF-1 | Registration statement for ABS offerings (non-shelf) |
| Form SF-3 | Shelf registration statement for ABS offerings |
| Form 10-D | Periodic distribution report (monthly, with asset-level XML) |
| Form 10-K | Annual report for ABS trusts |
| Form 8-K | Current report for material events |
| Form ABS-15G | Asset representations reviewer report |
| XBRL/XML exhibits | Machine-readable asset-level data |

**Accessing EDGAR Data:**
- EDGAR full-text search: `https://efts.sec.gov/LATEST/search-index?q=...`
- EDGAR XBRL viewer for structured data
- Bulk download via EDGAR FTP: `ftp://ftp.sec.gov/edgar/`
- SEC EDGAR API for programmatic access
- Third-party data providers (Bloomberg, Intex, CoreLogic) aggregate and normalize EDGAR data

**Data Engineering Opportunity:**
EDGAR ABS filings represent a massive, publicly available dataset. Data engineers can build pipelines to:
- Download and parse XML filings for specific CUSIPs or issuers
- Build loan-level performance databases from monthly 10-D filings
- Track deal performance over time (delinquency curves, loss curves, prepayment speeds)
- Compare performance across issuers, vintages, and collateral characteristics

---

### Shelf Registration Changes

Reg AB-II significantly tightened the requirements for **shelf registration** (Form SF-3), which allows issuers to register securities in advance and issue them over time.

**New Shelf Eligibility Requirements:**

1. **CEO Certification:** CEO must certify that the securitization structure is designed to produce expected cash flows and that disclosure is accurate
2. **CFO Financial Certification:** CFO must certify financial statements
3. **Compliance with Ongoing Reporting:** Issuer must be current on all Exchange Act reporting obligations
4. **Asset Representations Reviewer:** An independent third party must be appointed to review assets upon trigger events (delinquency thresholds)
5. **Dispute Resolution Mechanism:** Trust documents must include provisions for resolving repurchase request disputes
6. **Investor Communication:** Trust documents must include provisions for investor-to-investor communication

**Transaction-Level Requirements for Shelf Takedowns:**
- Preliminary prospectus filed at least 3 business days before first sale
- Asset-level data filed concurrently with preliminary prospectus
- Final prospectus filed within required timeframe

---

### Ongoing Reporting Requirements

Reg AB-II enhanced ongoing reporting for the life of the ABS trust:

**Monthly Reporting (Form 10-D):**
- Asset-level data in XML format (Schedule AL)
- Distribution date information (payments to investors by tranche)
- Pool performance summary (delinquencies, losses, prepayments)
- Trigger test results (if applicable)
- Servicer information and any transfers

**Annual Reporting (Form 10-K):**
- Servicer compliance statements
- Asset representations reviewer report (if triggered)
- Updated pool statistics
- Assessment of compliance with servicing criteria (Regulation AB Item 1122)
- Registered public accounting firm attestation (Item 1122)

**Event-Based Reporting (Form 8-K):**
- Servicer or trustee changes
- Material modifications to deal documents
- Credit enhancement changes
- Early amortization or termination events
- Material changes in sponsor/originator

---

### Reg AB-II Impact on Data Engineering

Reg AB-II created some of the most demanding data engineering challenges in the mortgage industry:

**Data Collection and Standardization:**

| Challenge | Detail |
|-----------|--------|
| Field mapping | Mapping internal loan servicing fields to 270+ SEC-defined fields |
| Code value translation | Converting internal codes to SEC enumeration values |
| Conditional logic | Determining which fields are required based on loan characteristics |
| Historical data | Populating origination-era fields for legacy loans |
| Cross-system integration | Pulling data from origination, servicing, loss mitigation, and REO systems |

**Data Pipeline Architecture for Reg AB-II:**

```
Source Systems          Transformation           Validation           Filing
+------------+     +------------------+     +---------------+     +--------+
| LOS        |---->|                  |     |               |     |        |
+------------+     |  Field Mapping   |     | XSD Schema    |     |        |
| Servicing  |---->|  Code Translate  |---->| Validation    |---->| EDGAR  |
+------------+     |  Business Rules  |     | Business Rule |     | Filing |
| Loss Mit   |---->|  XML Generation  |     | Check         |     |        |
+------------+     |                  |     | Data Quality  |     |        |
| REO        |---->|                  |     | Scoring       |     |        |
+------------+     +------------------+     +---------------+     +--------+
```

**Common Data Quality Issues:**
- Missing origination data for legacy loans (pre-2010 originations may lack full documentation)
- Inconsistent code values between origination and servicing systems
- ARM-specific fields not populated for fixed-rate loans (and vice versa)
- Modification data scattered across multiple systems
- Liquidation/REO data flowing from third-party vendors with different formats
- Timing mismatches between servicer reporting cycle and EDGAR filing deadlines

**Scale Considerations:**
- A single RMBS deal may have 2,000-10,000 loans
- Each loan has 270+ fields
- Monthly reporting means generating this data 12 times per year per deal
- An active issuer may have 50-200+ outstanding deals
- Total data volume: millions of loan-month records per year per issuer

---

### Data Quality Requirements

Reg AB-II implicitly raised the bar for data quality in several ways:

**Explicit Requirements:**
- Asset-level data must be "accurate" (Rule 193 due diligence requirement for registered offerings)
- Representations and warranties in pooling and servicing agreements create legal obligations for data accuracy
- Asset representations reviewer can be triggered to audit data upon delinquency events

**Industry Standards Driven by Reg AB-II:**
- **MISMO (Mortgage Industry Standards Maintenance Organization):** Expanded its data dictionary to align with Reg AB-II fields
- **SFIG (Structured Finance Industry Group):** Published best practices for Reg AB-II compliance including data quality frameworks
- **Rating agencies:** Incorporated Reg AB-II data availability into their surveillance processes

**Data Quality Dimensions to Track:**

| Dimension | Description | Example |
|-----------|-------------|---------|
| Completeness | All required fields populated | Current balance must not be null for active loans |
| Accuracy | Values reflect actual loan status | Payment status matches days delinquent calculation |
| Consistency | Same loan has consistent data across reports | Original balance should not change month to month |
| Timeliness | Data reflects the correct reporting period | Reporting period dates match filing schedule |
| Validity | Values conform to allowed ranges/codes | Property type must be a valid SEC enumeration value |
| Uniqueness | Each asset has a unique identifier | No duplicate asset numbers within a deal |

---

## Real-World Examples

### Example 1: Building a Reg AB-II Filing Pipeline

A mid-size RMBS issuer with 75 outstanding deals needs to generate monthly Form 10-D filings with asset-level XML.

**Architecture:**

**Step 1 — Data Extraction (T+1 to T+3 after distribution date):**
- Extract loan-level data from primary servicer system (MSP, Black Knight)
- Pull modification and loss mitigation data from workout system
- Pull REO/liquidation data from asset management system
- Pull deal structure data from trustee system (Intex, Bloomberg)

**Step 2 — Transformation (T+3 to T+5):**
- Map 150+ internal servicing fields to 270+ SEC fields using a configurable mapping layer
- Apply code value translation tables (e.g., internal property type "SFR" maps to SEC "SF")
- Apply conditional logic (e.g., populate ARM fields only for ARM loans)
- Calculate derived fields (e.g., current LTV from current balance and original property value)
- Generate XML documents per deal conforming to SEC XSD

**Step 3 — Validation (T+5 to T+7):**
- XSD schema validation (ensure XML is well-formed and conforms to schema)
- Business rule validation (e.g., current balance ≤ original balance for non-negative-am loans)
- Cross-field validation (e.g., if payment status = "Foreclosure" then foreclosure date must not be null)
- Historical consistency checks (e.g., original fields should not change between reporting periods)
- Data quality scorecard generation for compliance review

**Step 4 — Filing (T+7 to T+10):**
- Package XML as EDGAR exhibit
- Generate Form 10-D cover page
- Submit via EDGAR filing agent
- Monitor EDGAR acceptance/rejection
- Archive filed data for audit trail

### Example 2: Parsing EDGAR XML for Investment Analytics

An investment firm wants to build a database of non-agency RMBS loan-level performance data from public EDGAR filings.

**Pipeline Design:**
1. **Discovery:** Use EDGAR full-text search API to identify Form 10-D filings for target issuers/CUSIPs
2. **Download:** Programmatically download XML exhibits from EDGAR
3. **Parse:** Parse XML using Python `lxml` or `xml.etree.ElementTree` against SEC XSD schemas
4. **Normalize:** Map parsed data to a standardized relational model
5. **Load:** Insert into a data warehouse (Snowflake, Redshift, BigQuery) partitioned by deal and reporting period
6. **Analyze:** Build analytics on delinquency transitions, loss severity, prepayment speeds, modification rates

**Sample Python Parsing Logic:**
```python
import xml.etree.ElementTree as ET

namespace = {'abs': 'http://www.sec.gov/edgar/document/absee'}

tree = ET.parse('form10d_schedule_al.xml')
root = tree.getroot()

for asset in root.findall('.//abs:asset', namespace):
    asset_number = asset.find('abs:assetNumber', namespace).text
    current_balance = float(asset.find('abs:currentActualBalance', namespace).text)
    payment_status = asset.find('abs:paymentStatus', namespace).text
    # ... process each loan
```

### Example 3: Data Quality Dashboard for Reg AB-II Compliance

A trustee responsible for filing monthly 10-D reports builds a data quality monitoring system.

**Dashboard Metrics:**
- **Completeness score:** Percentage of required fields populated per deal per period
- **Validation pass rate:** Percentage of loans passing all business rule validations
- **Exception count by category:** Missing data, out-of-range values, cross-field inconsistencies
- **Trend analysis:** Data quality scores over time (identifying deterioration)
- **Issuer comparison:** Quality scores benchmarked across issuers using the same trustee
- **Filing timeline:** Days from distribution date to EDGAR filing (target vs. actual)

---

## Common Interview Questions & Answers

### Q1: What is Regulation AB-II and why was it enacted?

**A:** Regulation AB-II is the SEC's 2014 overhaul of disclosure requirements for asset-backed securities. It was enacted in response to the 2008 financial crisis, which exposed that investors in RMBS and other ABS often lacked sufficient information to independently assess the credit quality of underlying assets. Investors had relied heavily on credit ratings, which proved unreliable. Reg AB-II mandates asset-level disclosure in XML format for all publicly registered ABS offerings, covering approximately 270+ data fields for RMBS. It also tightened shelf registration requirements, enhanced ongoing reporting, and established mechanisms for independent asset review. For data engineers, it created one of the most comprehensive standardized loan-level datasets in the mortgage industry.

### Q2: Describe the data pipeline you would build to generate monthly Reg AB-II XML filings.

**A:** I would build a pipeline with four stages. First, data extraction: pull loan-level data from the primary servicing system, modification/loss mitigation system, REO/liquidation system, and deal structure information from the trustee platform. Second, transformation: apply a configurable field-mapping layer to translate internal servicing fields to the 270+ SEC-defined fields, perform code value translations using reference tables, apply conditional logic for field population based on loan characteristics, and generate the XML document per deal conforming to the SEC's XSD schema. Third, validation: run XSD schema validation, business rule checks, cross-field consistency checks, and historical consistency checks, producing a data quality scorecard. Fourth, filing: package the XML as an EDGAR exhibit, generate the Form 10-D wrapper, submit through an EDGAR filing agent, and monitor for acceptance. I would build this as a monthly batch pipeline with orchestration through a tool like Airflow, with exception handling at each stage and a comprehensive audit trail.

### Q3: How would you handle data quality issues in a Reg AB-II filing pipeline?

**A:** I would implement a multi-layered data quality framework. At the extraction layer, validate that source data is complete and within expected ranges. At the transformation layer, flag records where mapping logic produces null or default values for required fields. At the validation layer, run three types of checks: schema validation (XSD conformance), business rules (logical consistency such as current balance not exceeding original balance), and temporal checks (original fields should not change between periods, current fields should reflect expected transitions). I would produce a data quality scorecard for each deal with completeness, accuracy, and consistency metrics. Exceptions would be routed to a triage workflow where data stewards can investigate and correct issues. For systemic issues, I would trace root causes back to source systems and work with servicing operations to fix upstream. Finally, I would maintain a historical record of data quality scores to identify trends and prevent recurring issues.

### Q4: What are the key differences between Regulation AB (2004) and Regulation AB-II (2014)?

**A:** The original Regulation AB (2004) required pool-level aggregate data and static pool statistics but did not mandate loan-level disclosure. It relied on prospectus narratives and stratification tables. Reg AB-II introduced mandatory asset-level disclosure with 270+ defined fields in machine-readable XML format filed on EDGAR. Other key differences: Reg AB-II requires CEO certification for shelf eligibility, establishes an asset representations reviewer mechanism, mandates investor communication provisions, tightens ongoing reporting requirements, and requires three-business-day investor review of preliminary offering data. The shift from aggregate to loan-level disclosure was the fundamental change, as it enabled investors to run their own credit models rather than relying on issuer summaries or rating agency assessments.

### Q5: How would you build an analytics platform using publicly available Reg AB-II data from EDGAR?

**A:** I would build an ingestion pipeline that programmatically discovers and downloads Form 10-D XML filings from EDGAR using the SEC's EFTS API, filtered by form type and issuer CIK codes. The parser would use the SEC's XSD schemas to extract loan-level data from each filing's XML exhibits. The data would be loaded into a columnar data warehouse partitioned by deal CUSIP and reporting period, with a standardized schema that normalizes field names and code values across issuers. I would build dimension tables for deal metadata, issuer information, and reference data (state codes, property types). Analytical layers would include delinquency transition matrices, cumulative loss curves, prepayment speed calculations (CPR, PSA), modification rate tracking, and vintage analysis. This platform would enable portfolio managers to benchmark deal performance, identify credit trends, and support investment decisions with loan-level granularity.

### Q6: Explain the conditional field logic in Reg AB-II. How do you handle fields that are only required for certain loan types?

**A:** Reg AB-II includes many fields that are conditionally required based on loan characteristics. For example, ARM fields (index type, margin, rate cap, rate floor, next adjustment date) are only required for adjustable-rate loans. Modification fields are only required for modified loans. Liquidation fields are only required for liquidated loans. I would implement this using a rules engine that evaluates the loan's characteristics (rate type, modification flag, liquidation flag, etc.) and determines which fields are required, optional, or not applicable. During XML generation, non-applicable fields can either be omitted or populated with a standard null/not-applicable indicator depending on the XSD definition. During validation, business rules would only fire for applicable fields — for example, the check "if ARM then index type must not be null" would only apply to adjustable-rate loans. This conditional logic should be externalized in a configuration file or rules table rather than hard-coded, so it can be updated as SEC guidance evolves.

---

## Tips

1. **Know the field count and categories:** You do not need to memorize all 270+ fields, but you should know the major categories (origination, current status, performance, modification, liquidation) and be able to name representative fields in each category.

2. **Understand the XML/XSD ecosystem:** Be prepared to discuss how XML schemas define the structure and data types for each field, how validation works, and how you would parse XML programmatically. Know the difference between schema validation (structural) and business rule validation (logical).

3. **EDGAR is a gold mine for data engineers:** Emphasize your ability to work with publicly available EDGAR data. Many firms build proprietary databases by parsing EDGAR filings, which demonstrates strong data engineering skills (API interaction, XML parsing, data normalization, warehousing).

4. **Connect Reg AB-II to the financial crisis:** Interviewers often want to hear that you understand the "why" behind the regulation. The core issue was information asymmetry — issuers had loan-level data but investors only saw pool-level summaries. Reg AB-II closed that gap.

5. **Data quality is the hardest part:** In practice, generating compliant Reg AB-II filings is less about XML generation (which is straightforward) and more about ensuring data quality across 270+ fields sourced from multiple systems. Be ready to discuss data quality frameworks, exception handling, and root cause analysis.

6. **Scale matters:** When discussing your pipeline design, mention the scale: number of deals, loans per deal, fields per loan, and monthly cadence. This demonstrates you understand the operational complexity.

7. **Distinguish between offering and ongoing disclosure:** Offering disclosure (at the time of securitization) and ongoing disclosure (monthly 10-D filings) have different requirements and different data challenges. Origination data is static; performance data changes monthly.

8. **Know the relationship to other regulations:** Reg AB-II intersects with Dodd-Frank risk retention (Section 941), CFPB servicing rules (which affect the underlying loan data), and HMDA data (which overlaps with some demographic fields, though Reg AB-II anonymizes PII).
