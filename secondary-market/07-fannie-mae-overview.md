# Fannie Mae (FNMA) - Overview, Programs & Data

[Back to Secondary Market Index](./README.md)

---

## Table of Contents

1. [History and Role](#history-and-role)
2. [Core Business Model](#core-business-model)
3. [MBS Program and Pass-Through Structure](#mbs-program-and-pass-through-structure)
4. [Pool Types](#pool-types)
5. [Desktop Underwriter (DU)](#desktop-underwriter-du)
6. [Loan Delivery System](#loan-delivery-system)
7. [Pricing and Commitment Process](#pricing-and-commitment-process)
8. [Data Disclosures](#data-disclosures)
9. [Fannie Mae Connect](#fannie-mae-connect)
10. [Connecticut Avenue Securities (CAS)](#connecticut-avenue-securities-cas)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips for Data Engineers](#tips-for-data-engineers)

---

## History and Role

### Origins

Fannie Mae -- the **Federal National Mortgage Association (FNMA)** -- was established in **1938** as part of the New Deal in response to the Great Depression. Its original purpose was to provide liquidity to the mortgage market by purchasing FHA-insured loans from lenders, freeing up capital so those lenders could originate more mortgages.

### Key Historical Milestones

| Year | Event |
|------|-------|
| 1938 | Created as a government agency under the National Housing Act |
| 1954 | Re-chartered as a mixed-ownership corporation |
| 1968 | Converted to a privately held, government-sponsored enterprise (GSE) via the Housing and Urban Development Act; Ginnie Mae spun off to remain a government entity |
| 1970 | Began purchasing conventional (non-government-insured) mortgages |
| 1981 | Issued its first mortgage-backed security (MBS) |
| 2008 | Placed into conservatorship under the Federal Housing Finance Agency (FHFA) during the financial crisis |
| 2019 | Transitioned to the Uniform Mortgage-Backed Security (UMBS) with Freddie Mac under the Single Security Initiative |

### Role in the Secondary Market

Fannie Mae operates as a **guarantor** in the secondary mortgage market. It does not originate loans directly to consumers. Instead, it:

1. **Purchases** conforming conventional mortgage loans from approved lenders (banks, credit unions, non-bank mortgage companies).
2. **Securitizes** those loans into mortgage-backed securities (MBS) and guarantees the timely payment of principal and interest to investors.
3. **Retains** some loans in its own portfolio (though this has been reduced under conservatorship directives).

Fannie Mae's guarantee is an **enterprise guarantee**, meaning it is backed by Fannie Mae's own balance sheet -- not the full faith and credit of the U.S. government (unlike Ginnie Mae). However, given the conservatorship and the Treasury's Senior Preferred Stock Purchase Agreement (PSPA), there is an implicit government backstop.

### Charter and Conforming Loan Limits

Fannie Mae can only purchase loans that meet its **conforming loan limits**, which are set annually by FHFA. For 2025, the baseline limit is **$806,500** for a single-unit property in most areas, with higher limits in designated high-cost areas (up to **$1,209,750**).

---

## Core Business Model

Fannie Mae generates revenue primarily through:

- **Guaranty Fees (G-Fees):** Charged to lenders in exchange for Fannie Mae's guarantee on the MBS. This is an ongoing fee expressed in basis points, deducted from the pass-through rate paid to investors. Typical G-fees range from 40-70 basis points depending on loan characteristics and market conditions.
- **Net Interest Income:** Earned on loans and securities held in Fannie Mae's retained portfolio (the spread between the yield on assets and the cost of funding).
- **Transaction Fees:** Fees associated with loan delivery, technology platforms, etc.

### Approved Sellers and Servicers

Lenders must be **approved as Fannie Mae Seller/Servicers** to do business with Fannie Mae. They must meet capital requirements, operational standards, and comply with the Fannie Mae Selling Guide and Servicing Guide.

- **Sellers** deliver loans to Fannie Mae.
- **Servicers** collect payments from borrowers, manage escrow, handle delinquencies, and remit funds to Fannie Mae.

A single entity can be both a seller and a servicer, or these roles can be separated.

---

## MBS Program and Pass-Through Structure

### How Fannie Mae MBS Work

Fannie Mae MBS are **pass-through securities**. This means that the principal and interest payments made by borrowers on the underlying mortgage loans are "passed through" to the investors who hold the MBS, minus the guaranty fee and servicing fee.

**Payment Flow:**

```
Borrower --> Servicer --> Fannie Mae (as guarantor) --> MBS Investor
   |              |                |                        |
   |  Monthly     |  Remits P&I   |  Guarantees timely     |  Receives
   |  mortgage    |  (less svc    |  payment of P&I;       |  monthly
   |  payment     |   fee)        |  passes through net    |  pass-through
   |              |               |  of G-fee              |  payment
```

### Key MBS Characteristics

| Attribute | Description |
|-----------|-------------|
| **Coupon/Pass-Through Rate** | The interest rate paid to the MBS investor; typically the weighted average note rate minus the G-fee and servicing fee |
| **WAC (Weighted Average Coupon)** | The weighted average of the note rates of all loans in the pool |
| **WAM (Weighted Average Maturity)** | The weighted average remaining term of all loans in the pool |
| **WALA (Weighted Average Loan Age)** | The weighted average age of the loans in the pool |
| **Factor** | The proportion of the original principal balance that remains outstanding; published monthly |
| **CPR (Conditional Prepayment Rate)** | The annualized rate at which borrowers are prepaying their loans |
| **CDR (Conditional Default Rate)** | The annualized rate at which loans in the pool are defaulting |

### UMBS (Uniform Mortgage-Backed Security)

Since **June 3, 2019**, Fannie Mae issues **UMBS** rather than legacy Fannie Mae MBS. UMBS is a single, fungible security that can be issued by either Fannie Mae or Freddie Mac, creating a more liquid TBA (To-Be-Announced) market. Key points:

- UMBS replaced Fannie Mae's legacy MBS and Freddie Mac's Gold PCs.
- Both GSEs align their MBS payment delays: UMBS pays on a **55-day delay** (investors receive payment 55 days after the start of the accrual period).
- UMBS are traded on the TBA market, which is one of the most liquid fixed-income markets in the world.
- The **Common Securitization Platform (CSP)**, operated by **Common Securitization Solutions (CSS)** (a joint venture of Fannie and Freddie), handles the issuance, administration, and disclosure of UMBS.

---

## Pool Types

Fannie Mae organizes its MBS into different **pool prefixes** that indicate the type of loans in the pool. Understanding these prefixes is critical for data engineers working with MBS data.

### Major Pool Prefixes

| Prefix | Description | Key Characteristics |
|--------|-------------|---------------------|
| **CL** | Conventional Long-Term, Fixed-Rate | 30-year fixed-rate, single-family; the most common pool type |
| **CI** | Conventional Intermediate-Term, Fixed-Rate | 15-year fixed-rate, single-family |
| **CT** | Conventional Long-Term, Fixed-Rate (specific sub-type) | 20-year fixed-rate, single-family |
| **CS** | Conventional Short-Term, Fixed-Rate | 10-year fixed-rate, single-family |
| **CK** | Conventional Intermediate, Fixed-Rate (other terms) | Other intermediate fixed-rate terms |
| **AL** | ARM (Adjustable-Rate Mortgage) Long-Term | 30-year ARM, single-family |
| **AR** | ARM (Adjustable-Rate Mortgage) | Various ARM products |
| **MA** | Mega (resecuritization) | Pools of pools -- a Mega pool backed by other Fannie Mae MBS |

### Pool Prefix Detail: CL, CI, CT, CS

These four prefixes represent the backbone of Fannie Mae's fixed-rate securitization:

- **CL (30-year fixed):** By far the largest volume. These pools contain loans with original terms of 361-360 months. Most of the TBA market for Fannie Mae 30-year coupons maps to CL pools.
- **CI (15-year fixed):** Second largest by volume. Original terms of 181-240 months. Traded in the 15-year TBA market.
- **CT (20-year fixed):** Growing in popularity. Original terms of 241-300 months. Traded in the 20-year TBA market.
- **CS (10-year fixed):** Smaller volume. Original terms up to 180 months.

### Multi-Lender vs. Single-Lender Pools

- Fannie Mae pools can be **single-lender** (all loans originated or delivered by one seller) or **multi-lender** (aggregated from multiple sellers by Fannie Mae).
- The pool prefix alone does not distinguish single vs. multi-lender; this information is available in pool-level disclosures.

---

## Desktop Underwriter (DU)

### Overview

**Desktop Underwriter (DU)** is Fannie Mae's proprietary **automated underwriting system (AUS)**. It evaluates a borrower's creditworthiness and the loan's eligibility for sale to Fannie Mae.

### How DU Works

1. A loan officer inputs borrower and loan data into the lender's Loan Origination System (LOS).
2. The LOS transmits the data to DU via a standardized interface.
3. DU runs the data through its risk assessment engine, evaluating:
   - Credit history and score
   - Debt-to-income (DTI) ratios
   - Loan-to-value (LTV) ratios
   - Collateral (property type and appraisal)
   - Reserves and assets
   - Occupancy type
4. DU returns a **recommendation**:
   - **Approve/Eligible:** The loan meets Fannie Mae's guidelines.
   - **Approve/Ineligible:** The borrower qualifies, but some loan characteristic makes it ineligible for Fannie Mae purchase.
   - **Refer with Caution:** The loan requires additional manual underwriting review.
   - **Out of Scope:** The loan doesn't fit DU parameters.

### DU Data Outputs

- **DU Findings Report:** A detailed report listing conditions, messages, and the recommendation. This is a key document in the loan file.
- **DU Casefile ID:** A unique identifier for each DU submission, used to track the loan through the Fannie Mae ecosystem.
- **DU Validation Service:** Leverages third-party data sources to validate borrower income, assets, and employment, reducing the need for paper documentation.

### Relevance for Data Engineers

- DU casefile data is referenced during loan delivery. The DU Casefile ID links origination data to the underwriting decision.
- DU findings data feeds into quality control and audit pipelines.
- Understanding DU recommendation codes is essential when building data models that track loan eligibility and risk assessment outcomes.

---

## Loan Delivery System

### Overview

The **Fannie Mae Loan Delivery** system is the platform through which approved sellers deliver loans to Fannie Mae. It handles the electronic submission of loan data, document custody, and the creation of MBS pools.

### Loan Delivery Workflow

```
1. Lender originates and closes the loan
2. Lender submits loan data via Loan Delivery (or bulk upload)
3. Fannie Mae runs automated edits and validations
4. Lender corrects any data errors or missing fields
5. Loan is "committed" against a commitment (trade)
6. Lender delivers the note to the document custodian
7. Fannie Mae certifies the pool and issues MBS
```

### Key Data Elements in Loan Delivery

Loan Delivery requires hundreds of data fields across multiple categories:

- **Borrower Information:** Name, SSN, income, employment, credit score
- **Loan Terms:** Note rate, original balance, term, amortization type, LTV, CLTV
- **Property Information:** Address, property type, occupancy, appraisal value, census tract
- **Underwriting Data:** DU Casefile ID, DTI ratios, documentation type, MI coverage
- **Pricing Data:** SRP (Service Release Premium), LLPA adjustments, base price
- **Servicing Data:** Servicer ID, remittance type, servicing fee

### ULDD (Uniform Loan Delivery Dataset)

The **ULDD** is the standardized dataset used by both Fannie Mae and Freddie Mac for loan delivery. It was developed under the Uniform Mortgage Data Program (UMDP) to create consistency across the GSEs. Key points:

- Uses **MISMO (Mortgage Industry Standards Maintenance Organization)** XML format.
- Covers approximately 600+ data points.
- Ensures that loans delivered to either GSE use the same data definitions and formats.
- Version updates are published jointly by Fannie Mae and Freddie Mac.

### Bulk Delivery and API Integration

- **Bulk Delivery:** Lenders can upload large volumes of loans using standardized file formats.
- **API Integration:** Fannie Mae provides APIs for programmatic integration with lender systems.
- **Data Validation:** The system performs real-time edits (hard stops for critical errors, soft warnings for data quality issues).

---

## Pricing and Commitment Process

### How Pricing Works

When a lender wants to sell a loan to Fannie Mae, the pricing determines how much the lender receives. The key components are:

#### 1. Base Price (Par Price)

The base price for a Fannie Mae MBS is determined by the **TBA market**. For example, a Fannie Mae 30-year 6.0% coupon MBS might trade at 101.50 (101 and 16/32nds) in the TBA market.

#### 2. Guaranty Fee (G-Fee)

The G-fee is the ongoing cost of Fannie Mae's guarantee. It is expressed in basis points per annum and effectively reduces the coupon passed through to investors. A higher G-fee means the lender must deliver a higher note rate to achieve the same pass-through coupon.

#### 3. Loan-Level Price Adjustments (LLPAs)

**LLPAs** are risk-based pricing adjustments applied at the individual loan level. They reflect the credit risk of the specific loan based on its characteristics. LLPAs are expressed in basis points and are typically **negative** (charges to the lender), though some can be positive (credits).

**Key LLPA Grid Dimensions:**

| Factor | Impact |
|--------|--------|
| **Credit Score (FICO)** | Lower scores = higher LLPAs (more expensive) |
| **LTV Ratio** | Higher LTV = higher LLPAs |
| **Loan Purpose** | Cash-out refinances have higher LLPAs than purchases or rate/term refis |
| **Property Type** | Investment properties and multi-unit properties have higher LLPAs |
| **Occupancy** | Non-owner-occupied properties have higher LLPAs |
| **Product Type** | ARMs, interest-only, etc. may have additional LLPAs |
| **First-Time Homebuyer** | Certain combinations may receive reduced LLPAs |
| **Subordinate Financing** | Presence of a second lien increases LLPAs |

**Example LLPA Grid (Simplified):**

| FICO \ LTV | <= 60% | 60.01-70% | 70.01-75% | 75.01-80% | 80.01-85% |
|-------------|--------|-----------|-----------|-----------|-----------|
| >= 780 | 0.000% | 0.000% | -0.125% | -0.250% | -0.250% |
| 760-779 | 0.000% | -0.125% | -0.250% | -0.375% | -0.375% |
| 740-759 | -0.125% | -0.250% | -0.375% | -0.500% | -0.750% |
| 720-739 | -0.250% | -0.375% | -0.500% | -0.750% | -1.000% |
| 700-719 | -0.375% | -0.500% | -0.750% | -1.000% | -1.250% |
| < 700 | -0.500% | -0.750% | -1.000% | -1.500% | -1.750% |

*Note: These values are illustrative. Actual LLPA grids are published by Fannie Mae and updated periodically.*

#### 4. Commitment (Mandatory Delivery)

- **Mandatory Commitment:** The lender commits to deliver a specific dollar amount of loans at a specified coupon within a delivery window. If the lender fails to deliver, they must pay a **pair-off fee**.
- **Best Efforts Commitment:** The lender commits to deliver a specific loan. If the loan doesn't close, there is no pair-off penalty, but the pricing is slightly worse.

### Pricing Formula (Simplified)

```
Net Proceeds to Lender = Base Price + SRP - LLPAs - G-Fee Buyup/Buydown Adjustment
```

Where:
- **SRP (Servicing Released Premium):** If the lender releases servicing to Fannie Mae or a third party, they receive an SRP.
- **Buyup/Buydown:** Lenders can buy up (reduce) or buy down (increase) the G-fee in exchange for upfront price adjustments.

---

## Data Disclosures

Fannie Mae provides extensive data disclosures that are critical for data engineers, analysts, and researchers.

### 1. Loan-Level Performance Data (Single-Family)

Fannie Mae's **Single-Family Loan Performance Dataset** is one of the most comprehensive public mortgage datasets available.

- **Coverage:** Loans acquired by Fannie Mae from 2000 onward (30-year fixed-rate and some 15-year fixed-rate).
- **Size:** Hundreds of millions of records across acquisition and performance files.
- **Update Frequency:** Quarterly.
- **Key Fields:**
  - **Acquisition File:** Credit score, first-time homebuyer flag, DTI, UPB, LTV, interest rate, channel (retail/wholesale/correspondent), property state, zip code (3-digit), loan purpose, property type, number of units, occupancy status, seller name, servicer name.
  - **Performance File (monthly records):** Current UPB, loan age, months to maturity, delinquency status, modification flag, zero balance code (payoff, foreclosure, REO, short sale), foreclosure date, disposition date, foreclosure costs, credit enhancement proceeds, repurchase proceeds, net sale proceeds.

### 2. MBS Pool-Level Disclosures

- **Pool Factor Files:** Monthly factor (remaining balance ratio) for each pool, enabling investors to track paydowns.
- **Pool Summary Statistics:** WAC, WAM, WALA, average loan size, geographic distribution.
- **Supplemental Data:** Loan count, delinquency breakdowns, prepayment speeds by pool.

### 3. LLPA Grids

- Published on Fannie Mae's website under the Selling Guide.
- Updated periodically (major updates often announced months in advance).
- Available as downloadable matrices (PDF and sometimes Excel).

### 4. Credit Risk Transfer (CRT) Disclosures

- Loan-level data for reference pools underlying CAS deals (see below).
- Monthly performance updates for CAS investors.

### 5. MISMO and ULDD Specifications

- Technical specifications for data delivery formats.
- Data dictionaries mapping field names, valid values, and business rules.

---

## Fannie Mae Connect

### Overview

**Fannie Mae Connect** is the enterprise portal through which Fannie Mae distributes data, reports, and analytics to its business partners (lenders, servicers, investors, and other counterparties).

### Key Capabilities

- **Investor Reporting:** MBS holders can access pool-level data, factors, and remittance details.
- **Seller/Servicer Reporting:** Lenders can access loan-level delivery confirmations, commitment tracking, pricing details, and quality control results.
- **Data Downloads:** Bulk downloads of disclosure datasets, LLPA grids, and reference data.
- **Notifications and Alerts:** Automated alerts for data updates, policy changes, and system maintenance.

### Data Delivery Formats

- CSV and pipe-delimited flat files for bulk data.
- XML for structured data exchanges.
- PDF reports for human-readable summaries.
- API access for programmatic integration (increasingly available).

### Relevance for Data Engineers

Fannie Mae Connect is often the **source system** for data pipelines that ingest Fannie Mae data. Data engineers need to:

- Understand the file formats, naming conventions, and delivery schedules.
- Build automated ingestion pipelines (often using SFTP or API pulls).
- Handle incremental updates and full refreshes.
- Map Fannie Mae Connect data fields to internal data models.

---

## Connecticut Avenue Securities (CAS)

### Overview

**Connecticut Avenue Securities (CAS)** are Fannie Mae's primary **credit risk transfer (CRT)** instrument. They are unsecured notes issued by Fannie Mae whose payments are linked to the credit performance of a reference pool of mortgage loans.

### Purpose

CAS was introduced in **2013** as part of the post-crisis effort to shift mortgage credit risk away from taxpayers and toward private capital. FHFA mandated that Fannie Mae and Freddie Mac develop CRT programs to reduce their credit risk exposure.

### How CAS Works

```
1. Fannie Mae identifies a reference pool of recently acquired loans
2. Fannie Mae issues CAS notes in multiple tranches
3. Investors purchase CAS notes and receive coupon payments
4. If loans in the reference pool default, losses are allocated to CAS
   investors (starting with the lowest tranche)
5. Fannie Mae's exposure to credit losses is reduced
```

### CAS Tranche Structure

| Tranche | Risk Level | Description |
|---------|------------|-------------|
| **M-1** | Lower risk (mezzanine, senior) | First loss protection above the B tranche; typically investment-grade rated |
| **M-2** | Medium risk (mezzanine, junior) | Absorbs losses after B tranche is exhausted |
| **B-1** | Higher risk (subordinate) | First to absorb losses from the reference pool |
| **B-2** | Highest risk (first loss) | Very first loss position; highest yield |

### CAS Data for Data Engineers

- **Reference Pool Data:** Loan-level data for the underlying loans, published at issuance and updated monthly.
- **Deal Documents:** Prospectuses and supplements detailing the structure, triggers, and waterfall.
- **Performance Data:** Monthly reports on delinquencies, defaults, severities, and tranche writedowns.
- **Data Feeds:** Available through Fannie Mae Connect and third-party data providers (Bloomberg, Intex, etc.).

### CAS vs. STACR

| Feature | CAS (Fannie Mae) | STACR (Freddie Mac) |
|---------|-------------------|---------------------|
| Issuer | Fannie Mae | Freddie Mac |
| Structure | Unsecured notes (debt of Fannie Mae) | Unsecured notes (debt of Freddie Mac) |
| Reference Pool | Fannie Mae acquisitions | Freddie Mac acquisitions |
| Tranche Names | M-1, M-2, B-1, B-2 | M-1, M-2, B-1, B-2 (similar) |
| First Issuance | 2013 | 2013 |

---

## Common Interview Questions

### Conceptual Questions

**Q1: What is Fannie Mae's role in the secondary mortgage market?**

> **A:** Fannie Mae is a government-sponsored enterprise (GSE) that provides liquidity, stability, and affordability to the U.S. residential mortgage market. It purchases conforming conventional loans from approved lenders, securitizes them into mortgage-backed securities (MBS), and guarantees the timely payment of principal and interest to investors. Fannie Mae does not originate loans directly; it operates in the secondary market as a guarantor and aggregator. Since 2008, it has been in conservatorship under FHFA.

**Q2: What is the difference between Fannie Mae's guarantee and Ginnie Mae's guarantee?**

> **A:** Fannie Mae's guarantee is an enterprise-level guarantee -- it is backed by Fannie Mae's own financial resources and balance sheet. Ginnie Mae's guarantee is backed by the **full faith and credit of the U.S. government**, making it explicitly sovereign-backed. Fannie Mae's guarantee carries an implicit government backstop due to the conservatorship and Treasury support, but it is not an explicit government guarantee.

**Q3: Explain what LLPAs are and why they matter.**

> **A:** Loan-Level Price Adjustments (LLPAs) are risk-based pricing adjustments applied to individual loans based on their risk characteristics (credit score, LTV, loan purpose, property type, occupancy, etc.). They are expressed in basis points and adjust the price a lender receives when selling the loan to Fannie Mae. LLPAs ensure that higher-risk loans carry a higher cost, aligning pricing with expected credit losses. For data engineers, LLPA grids are critical reference data used in pricing engines and loan-level profitability models.

**Q4: What is UMBS and why was it created?**

> **A:** The Uniform Mortgage-Backed Security (UMBS) is a single, fungible MBS that can be issued by either Fannie Mae or Freddie Mac. It was created under the Single Security Initiative (mandated by FHFA) to eliminate the pricing disparity between Fannie Mae MBS and Freddie Mac PCs, improve market liquidity by combining both GSEs' securities into a single TBA-eligible instrument, and reduce overall costs to the mortgage market. UMBS launched on June 3, 2019, and both GSEs now issue UMBS through the Common Securitization Platform (CSP).

### Data Engineering Questions

**Q5: Describe the Fannie Mae Single-Family Loan Performance Dataset. How would you design a pipeline to process it?**

> **A:** The dataset consists of two main file types: (1) **Acquisition files** containing static loan-level attributes at origination (credit score, LTV, DTI, etc.) and (2) **Performance files** containing monthly time-series records for each loan (current UPB, delinquency status, modification flags, etc.). The dataset is released quarterly and covers loans from 2000 onward.
>
> **Pipeline Design:**
> - **Ingestion:** Automate quarterly downloads from Fannie Mae's website. Files are pipe-delimited with no headers; apply schema from the published data dictionary.
> - **Staging:** Load raw files into a staging area (e.g., S3, ADLS). Validate file sizes and record counts.
> - **Transformation:** Parse and type-cast fields, join acquisition and performance data on loan sequence number, handle null values per the data dictionary's conventions.
> - **Modeling:** Build a dimensional model with a loan dimension (acquisition attributes) and a monthly performance fact table. Create derived fields such as months delinquent, ever-modified flag, and loss severity.
> - **Quality:** Implement data quality checks (e.g., UPB should not increase unless modified, delinquency status should follow expected transitions).
> - **Serving:** Materialize aggregated views for analytics (vintage curves, delinquency transition matrices, CPR/CDR by cohort).

**Q6: How would you handle the mapping between DU casefile data and loan delivery data in a data warehouse?**

> **A:** The DU Casefile ID is the primary key linking underwriting data to the delivered loan. In a data warehouse:
> - Create a **DU Findings** dimension or fact table keyed by DU Casefile ID and submission number (a loan may have multiple DU runs).
> - Join to the **Loan** dimension using the DU Casefile ID that was submitted at delivery.
> - Track the history of DU submissions (initial, resubmissions) using a slowly changing dimension (SCD Type 2) or a separate DU history table.
> - Handle the one-to-many relationship between loans and DU runs (a loan may be submitted to DU multiple times before closing).

**Q7: You are building an LLPA pricing engine. How would you model the LLPA grids in a database?**

> **A:** LLPA grids are multi-dimensional matrices. I would model them as a **normalized lookup table**:
> ```sql
> CREATE TABLE llpa_grid (
>     effective_date      DATE,
>     expiration_date     DATE,
>     credit_score_min    INT,
>     credit_score_max    INT,
>     ltv_min             DECIMAL(5,3),
>     ltv_max             DECIMAL(5,3),
>     loan_purpose        VARCHAR(50),
>     property_type       VARCHAR(50),
>     occupancy_type      VARCHAR(50),
>     unit_count          INT,
>     adjustment_pct      DECIMAL(8,5)
> );
> ```
> Each row represents one cell in the grid. The pricing engine would query this table with the loan's attributes and sum all applicable adjustments. Versioning is handled via effective/expiration dates to support historical pricing and auditing.

**Q8: What are the key differences between Fannie Mae's CL, CI, CT, and CS pool types from a data perspective?**

> **A:** The differences are primarily in original loan term:
> - **CL:** 30-year fixed (terms 361-360 months) -- largest volume, most data available
> - **CI:** 15-year fixed (terms 181-240 months) -- faster paydown, lower credit risk profile
> - **CT:** 20-year fixed (terms 241-300 months) -- growing volume, intermediate risk/return
> - **CS:** 10-year fixed (terms up to 180 months) -- smallest volume, fastest amortization
>
> From a data engineering perspective, pool prefix is a critical filter for any pool-level analysis. Each pool type has different prepayment and default behavior patterns, which affects how you model and analyze performance data. The volume differences also affect data processing -- CL pools may have millions of records while CS pools have far fewer.

---

## Tips for Data Engineers

### Working with Fannie Mae Data

1. **Always use the official data dictionary.** Fannie Mae's loan-level datasets come with detailed file layouts and field definitions. Column positions, data types, and valid values are all documented. Never assume field meanings -- always verify against the dictionary.

2. **Handle the pipe-delimited format carefully.** Fannie Mae's public datasets use pipe (`|`) delimiters with no header row. Your ingestion code must apply the schema externally. Watch for trailing delimiters and empty fields.

3. **Understand the quarterly release cycle.** Performance data is updated quarterly with a lag. Plan your pipeline refresh schedules accordingly and implement idempotent loads to handle restatements.

4. **Join on Loan Sequence Number.** The `loan_sequence_number` is the primary key across acquisition and performance files. Ensure your joins are correct (acquisition is one row per loan; performance is one row per loan per month).

5. **Watch for data volume.** The full performance dataset is extremely large (hundreds of millions of rows). Use partitioning (by vintage year or quarter), columnar formats (Parquet, ORC), and incremental processing strategies.

6. **Understand LLPA versioning.** LLPA grids change over time. Always associate a loan's pricing with the LLPA grid that was in effect at the time of lock or delivery, not the current grid.

7. **Know the MISMO/ULDD standards.** If you work with loan delivery data, familiarity with MISMO XML and the ULDD specification is essential. These are complex, deeply nested XML schemas.

8. **CAS reference pool data is a goldmine.** If you need granular loan-level data tied to specific securitization deals, CAS reference pool data provides detailed attributes and monthly performance linked to specific CRT transactions.

9. **Leverage Fannie Mae Connect for automation.** Set up automated data pulls where possible. Understand the folder structure, file naming conventions, and delivery schedules.

10. **Track the UMBS transition.** If you work with historical MBS data, be aware that pre-June 2019 data uses legacy Fannie Mae MBS pool prefixes, while post-June 2019 data uses UMBS conventions. Your data models need to handle this transition seamlessly.

---

*This document provides an overview of Fannie Mae's structure, programs, and data for data engineering interview preparation. For the most current information, always refer to Fannie Mae's official Selling Guide, Servicing Guide, and data disclosure pages.*
