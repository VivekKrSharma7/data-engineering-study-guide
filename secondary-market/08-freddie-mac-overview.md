# Freddie Mac (FHLMC) - Overview, Programs & Data

[Back to Secondary Market Index](./README.md)

---

## Table of Contents

1. [History and Role](#history-and-role)
2. [Core Business Model](#core-business-model)
3. [Loan Product Advisor (LPA)](#loan-product-advisor-lpa)
4. [Gold PCs and UMBS Transition](#gold-pcs-and-umbs-transition)
5. [Pool Types](#pool-types)
6. [Securitization Process](#securitization-process)
7. [Single Family Loan-Level Dataset](#single-family-loan-level-dataset)
8. [STACR (Structured Agency Credit Risk)](#stacr-structured-agency-credit-risk)
9. [Data Disclosures](#data-disclosures)
10. [Key Differences from Fannie Mae](#key-differences-from-fannie-mae)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips for Data Engineers](#tips-for-data-engineers)

---

## History and Role

### Origins

Freddie Mac -- the **Federal Home Loan Mortgage Corporation (FHLMC)** -- was established in **1970** by Congress through the Emergency Home Finance Act. It was created to provide a secondary market for conventional mortgages, breaking Fannie Mae's monopoly and expanding the flow of capital to mortgage lenders.

### Key Historical Milestones

| Year | Event |
|------|-------|
| 1970 | Created by Congress; initially owned by the Federal Home Loan Bank System |
| 1971 | Issued its first mortgage-backed security -- the Participation Certificate (PC) |
| 1989 | Became a publicly traded, shareholder-owned corporation under FIRREA |
| 1993 | Introduced Loan Prospector (now Loan Product Advisor), its automated underwriting system |
| 2003 | Accounting scandal; restatement of $5 billion in earnings |
| 2008 | Placed into conservatorship under FHFA alongside Fannie Mae |
| 2019 | Transitioned to UMBS under the Single Security Initiative; legacy Gold PCs replaced |

### Role in the Secondary Market

Freddie Mac's role mirrors Fannie Mae's in many respects. It:

1. **Purchases** conforming conventional mortgage loans from approved Seller/Servicers.
2. **Securitizes** those loans into mortgage-backed securities and guarantees timely payment of principal and interest.
3. **Manages** credit risk through underwriting standards, quality control, and credit risk transfer programs (STACR).

Freddie Mac's charter and mission are essentially the same as Fannie Mae's: to provide liquidity, stability, and affordability to the U.S. housing market. Both operate under the supervision of FHFA and are subject to the same conforming loan limits.

### Freddie Mac vs. Fannie Mae: Structural Origins

While both are GSEs, their origins differ:
- **Fannie Mae** was created in 1938 as a government agency and later privatized.
- **Freddie Mac** was created in 1970 specifically to provide competition and was initially tied to the Federal Home Loan Bank System (serving savings and loan institutions, or thrifts).

This historical difference led to slightly different lender bases: Fannie Mae historically worked more with large banks and mortgage companies, while Freddie Mac had stronger ties to thrifts and smaller community lenders. Today, these distinctions have largely disappeared, and both GSEs serve the same broad lender base.

---

## Core Business Model

Freddie Mac's revenue model is structurally identical to Fannie Mae's:

- **Guaranty Fees (G-Fees):** Ongoing fees charged to sellers/servicers for the credit guarantee on securitized loans.
- **Net Interest Income:** Earned on the retained mortgage portfolio.
- **Other Income:** Technology platform fees, transaction fees, and credit risk transfer activities.

### Approved Sellers and Servicers

Like Fannie Mae, Freddie Mac requires lenders to be **approved Seller/Servicers**. They must comply with the **Freddie Mac Single-Family Seller/Servicer Guide**, which governs:

- Eligibility requirements for sellers and servicers
- Loan product eligibility criteria
- Underwriting standards
- Delivery and documentation requirements
- Servicing standards and default management

---

## Loan Product Advisor (LPA)

### Overview

**Loan Product Advisor (LPA)** -- formerly known as **Loan Prospector (LP)** -- is Freddie Mac's proprietary **automated underwriting system (AUS)**. It serves the same purpose as Fannie Mae's Desktop Underwriter (DU): evaluating borrower creditworthiness and loan eligibility.

### How LPA Works

1. Lender submits borrower and loan data through their LOS or directly through the LPA interface.
2. LPA evaluates:
   - Credit history and credit score
   - Income and employment stability
   - Assets and reserves
   - Debt-to-income ratios
   - Property and collateral
   - Loan terms and product type
3. LPA returns a **risk classification**:
   - **Accept:** The loan meets Freddie Mac's guidelines and is eligible for purchase.
   - **Caution:** The loan has risk factors that require additional review or may not be eligible.
   - **A-Minus:** (Legacy designation) Indicated elevated risk.

### LPA vs. DU: Key Differences

| Feature | LPA (Freddie Mac) | DU (Fannie Mae) |
|---------|-------------------|-----------------|
| **Name History** | Formerly "Loan Prospector" | Always "Desktop Underwriter" |
| **Recommendations** | Accept / Caution | Approve/Eligible / Refer with Caution |
| **Asset & Income Verification** | LPA Asset & Income Modeler (AIM) | DU Validation Service |
| **Credit Model** | Uses its own proprietary credit model in addition to FICO | Primarily relies on Classic FICO |
| **Risk Assessment** | Emphasizes statistical modeling of default probability | Emphasizes rules-based eligibility checks combined with statistical models |
| **Feedback Certificates** | LPA Feedback Certificate | DU Findings Report |

### LPA Data Outputs

- **LPA Feedback Certificate:** The primary output document summarizing the risk assessment, recommendation, conditions, and messages.
- **LPA Key Number:** A unique identifier for each LPA submission, analogous to the DU Casefile ID.
- **AIM (Asset & Income Modeler):** Leverages third-party data to assess and validate borrower assets and income.

### Relevance for Data Engineers

- The LPA Key Number links origination and underwriting data in downstream systems.
- LPA recommendation codes must be mapped and stored in data warehouses for risk analysis.
- Some lenders run loans through both DU and LPA to determine the best execution (selling to Fannie Mae vs. Freddie Mac). Data models must accommodate dual AUS results.

---

## Gold PCs and UMBS Transition

### Legacy: Gold Participation Certificates (Gold PCs)

Before June 2019, Freddie Mac issued **Gold Participation Certificates (Gold PCs)** as its primary MBS product. Key characteristics:

- **45-day payment delay:** Investors received payments 45 days after the start of the accrual period (vs. Fannie Mae's 55-day delay on legacy MBS).
- This shorter delay was actually a **disadvantage** because it meant Freddie Mac PCs traded at a slight premium to Fannie Mae MBS (the "Freddie discount"), leading to lower liquidity in the TBA market.
- Gold PCs were similar in structure to Fannie Mae MBS (pass-through securities backed by pools of conforming loans).

### The Single Security Initiative and UMBS

To address the liquidity disadvantage, FHFA mandated the **Single Security Initiative**, which resulted in the creation of the **Uniform Mortgage-Backed Security (UMBS)**.

**Key aspects of the transition:**

| Aspect | Detail |
|--------|--------|
| **Launch Date** | June 3, 2019 |
| **Payment Delay** | Standardized to 55 days for both GSEs (Freddie Mac had to extend from 45 to 55 days) |
| **Fungibility** | UMBS issued by Fannie Mae and Freddie Mac are interchangeable in the TBA market |
| **Legacy Gold PCs** | Could be exchanged for UMBS through a "mirror securities" process |
| **Common Securitization Platform (CSP)** | Joint platform operated by Common Securitization Solutions (CSS) handles issuance and administration |
| **Impact** | Eliminated the Freddie Mac TBA price disadvantage, improved market liquidity |

### Mirror Securities and Supers

- **Mirror Security (M-Security):** When a legacy Freddie Mac Gold PC is exchanged for a UMBS, a "mirror certificate" is created. The M-security represents the same underlying pool but with the UMBS payment delay.
- **Supers:** Multi-pool MBS that aggregate multiple UMBS pools into a single security, similar to Fannie Mae's Mega pools.

### Data Implications

For data engineers working with historical MBS data:
- Pre-June 2019: Freddie Mac securities are Gold PCs with 45-day delay.
- Post-June 2019: Freddie Mac issues UMBS with 55-day delay.
- Legacy Gold PCs may have been exchanged for UMBS (M-securities).
- Pool-level data must track both legacy and UMBS identifiers.

---

## Pool Types

Freddie Mac uses its own set of **pool prefixes** to categorize MBS pools. While the concepts are similar to Fannie Mae, the specific prefixes differ.

### Major Pool Prefixes

| Prefix | Description | Comparable Fannie Mae Prefix |
|--------|-------------|------------------------------|
| **QA** | 30-year fixed-rate, single-family | CL |
| **QB** | 15-year fixed-rate, single-family | CI |
| **QC** | 20-year fixed-rate, single-family | CT |
| **QD** | 10-year fixed-rate, single-family | CS |
| **QI** | ARM, single-family | AL/AR |
| **QM** | Multifamily (not covered in this guide) | -- |
| **QS** | Super (multi-pool resecuritization) | MA (Mega) |
| **QN** | Non-TBA eligible pools | Various |

### UMBS Pool Prefixes

After the UMBS transition, Freddie Mac pools that back UMBS use the same pool prefix conventions but are identified as UMBS-eligible based on their characteristics and delivery to the CSP.

### Pool Characteristics

Like Fannie Mae, Freddie Mac pool data includes:
- Pool number (unique identifier)
- Pool prefix (product type)
- Issue date
- Maturity date
- Original and current UPB
- Pass-through rate (coupon)
- WAC, WAM, WALA
- Loan count
- Geographic distribution
- Seller and servicer information

---

## Securitization Process

### End-to-End Flow

```
1. Lender originates a conforming conventional mortgage loan
2. Lender submits the loan through LPA for automated underwriting
3. Lender delivers the loan to Freddie Mac via Loan Selling Advisor
4. Freddie Mac validates the loan data against eligibility criteria
5. Loan is pooled with similar loans based on product type, coupon, etc.
6. Freddie Mac issues UMBS backed by the pool through the CSP
7. UMBS are sold in the TBA market or through specified pool trades
8. Freddie Mac guarantees timely payment of P&I to investors
9. Servicer collects borrower payments and remits to Freddie Mac
10. Freddie Mac passes payments through to investors (net of G-fee)
```

### Loan Selling Advisor

**Loan Selling Advisor** is Freddie Mac's platform for loan delivery, analogous to Fannie Mae's Loan Delivery system. Key functions include:

- **Loan Submission:** Electronic submission of loan data using ULDD format.
- **Data Validation:** Automated edits and hard/soft stops.
- **Commitment Tracking:** Managing mandatory and best-efforts commitments.
- **Settlement:** Tracking loan delivery against commitments and calculating pair-off fees if applicable.

### ULDD Alignment

Both Freddie Mac and Fannie Mae use the **Uniform Loan Delivery Dataset (ULDD)** for loan data submission. This ensures that:
- Lenders use the same data format regardless of which GSE they are selling to.
- Data definitions are standardized (same field names, valid values, and business rules).
- Systems can be built once and used for delivery to either GSE.

### Pricing and Commitments

Freddie Mac's pricing structure mirrors Fannie Mae's:
- **Base price** driven by TBA market levels for UMBS.
- **G-fee** deducted from the pass-through rate.
- **LLPAs** applied based on loan-level risk characteristics.
- **Mandatory and best-efforts commitments** with similar economics.
- **Buyup/buydown** options for G-fee adjustments.

---

## Single Family Loan-Level Dataset

### Overview

Freddie Mac's **Single Family Loan-Level Dataset** is a publicly available dataset that provides detailed loan-level information for a subset of Freddie Mac's single-family mortgage portfolio. It is one of the most widely used datasets in mortgage analytics and academic research.

### Dataset Structure

The dataset consists of two main file types:

#### 1. Origination Data

Static attributes captured at the time of loan origination:

| Field | Description |
|-------|-------------|
| Credit Score | Borrower's credit score at origination |
| First Payment Date | Date of the first mortgage payment |
| First Time Homebuyer Flag | Whether the borrower is a first-time buyer |
| Maturity Date | Scheduled maturity date of the loan |
| MSA | Metropolitan Statistical Area code |
| MI Percentage | Mortgage insurance coverage percentage |
| Number of Units | Number of units in the property (1-4) |
| Occupancy Status | Owner-occupied, second home, or investment |
| Original CLTV | Original combined loan-to-value ratio |
| Original DTI | Original debt-to-income ratio |
| Original UPB | Original unpaid principal balance |
| Original LTV | Original loan-to-value ratio |
| Original Interest Rate | Note rate at origination |
| Channel | Retail, broker, or correspondent |
| Prepayment Penalty Flag | Whether the loan has a prepayment penalty |
| Product Type | Fixed-rate or ARM |
| Property State | Two-letter state code |
| Property Type | Single-family, condo, co-op, manufactured, PUD |
| Postal Code (3-digit) | First three digits of the zip code |
| Loan Sequence Number | Unique loan identifier |
| Loan Purpose | Purchase, cash-out refinance, or no-cash-out refinance |
| Original Loan Term | Original term in months |
| Number of Borrowers | Number of borrowers on the loan |
| Seller Name | Name of the originating seller |
| Servicer Name | Name of the current servicer |

#### 2. Monthly Performance Data

Time-series records tracking each loan's performance over its life:

| Field | Description |
|-------|-------------|
| Loan Sequence Number | Links to origination data |
| Monthly Reporting Period | The month of the performance record |
| Current Actual UPB | Current unpaid principal balance |
| Current Loan Delinquency Status | Number of months delinquent (0, 1, 2, 3, ..., or special codes) |
| Loan Age | Number of months since origination |
| Remaining Months to Maturity | Months remaining until scheduled maturity |
| Repurchase Flag | Whether the loan was repurchased |
| Modification Flag | Whether the loan has been modified |
| Zero Balance Code | Reason for zero balance (prepaid, foreclosure, REO, short sale, etc.) |
| Zero Balance Effective Date | Date the loan reached zero balance |
| Current Interest Rate | Current note rate (may differ from original if modified) |
| Current Deferred UPB | Deferred principal balance (if modified with forbearance) |
| Due Date of Last Paid Installment | Date of the last payment received |
| MI Recoveries | Mortgage insurance recoveries (if applicable) |
| Net Sale Proceeds | Net proceeds from property disposition |
| Non-MI Recoveries | Non-MI recoveries (e.g., from borrower) |
| Expenses | Costs incurred (maintenance, legal, etc.) |
| Legal Costs | Legal expenses |
| Maintenance and Preservation Costs | Property upkeep costs |
| Taxes and Insurance | Property taxes and hazard insurance costs |
| Miscellaneous Expenses | Other expenses |
| Actual Loss Calculation | Net loss or gain on the loan |
| Modification Cost | Cost of loan modification |

### Dataset Characteristics

| Attribute | Detail |
|-----------|--------|
| **Coverage** | Fixed-rate loans (primarily 30-year) originated from 1999 onward |
| **Update Frequency** | Quarterly |
| **Format** | Pipe-delimited (`|`) text files, no headers |
| **Size** | Origination: millions of loans; Performance: hundreds of millions of monthly records |
| **Access** | Free download from Freddie Mac's website (registration required) |
| **Documentation** | Detailed user guide and data dictionary published alongside the data |

### Comparison with Fannie Mae's Dataset

| Feature | Freddie Mac | Fannie Mae |
|---------|-------------|------------|
| **Loan Identifier** | Loan Sequence Number | Loan Sequence Number |
| **Format** | Pipe-delimited, no headers | Pipe-delimited, no headers |
| **Coverage Start** | 1999 | 2000 |
| **Products** | Primarily 30-year fixed | 30-year and 15-year fixed |
| **Loss Fields** | Detailed loss breakdown | Detailed loss breakdown |
| **Modification Fields** | Included | Included |
| **Geographic Detail** | 3-digit zip, MSA, state | 3-digit zip, state |
| **Seller/Servicer** | Named | Named |

---

## STACR (Structured Agency Credit Risk)

### Overview

**Structured Agency Credit Risk (STACR)** is Freddie Mac's primary **credit risk transfer (CRT)** program, analogous to Fannie Mae's CAS program. STACR notes transfer mortgage credit risk from Freddie Mac (and ultimately taxpayers) to private investors.

### How STACR Works

```
1. Freddie Mac identifies a reference pool of recently acquired loans
2. Freddie Mac issues STACR notes in multiple tranches
3. Investors purchase STACR notes and receive floating-rate coupon payments
4. If loans in the reference pool experience credit losses, those losses
   are allocated to STACR investors starting with the lowest tranche
5. Freddie Mac's exposure to credit losses on the reference pool is reduced
```

### STACR Tranche Structure

| Tranche | Description |
|---------|-------------|
| **A-H** | Senior tranche retained by Freddie Mac; not subject to credit losses until all subordinate tranches are exhausted |
| **M-1** | Senior mezzanine; investment-grade rated |
| **M-2** | Junior mezzanine; absorbs losses after M-1 is exhausted |
| **B-1** | Senior subordinate; absorbs losses after M-2 |
| **B-2** | First-loss tranche; bears the first credit losses; highest yield |

### STACR Sub-Programs

Freddie Mac has issued STACR under different sub-labels:

| Sub-Program | Description |
|-------------|-------------|
| **STACR DNA (Debt Note, Actual Loss)** | Losses based on actual realized losses on the reference pool |
| **STACR HQA (High LTV, Quality Adjusted)** | Targets loans with higher LTV ratios (80-97%) |
| **STACR Trust** | Uses a trust structure rather than direct Freddie Mac debt |

### STACR Data for Data Engineers

- **Reference Pool Data:** Loan-level data at issuance and monthly updates, similar in structure to the public loan-level dataset but specific to the STACR deal's reference pool.
- **Monthly Remittance Reports:** Performance data including delinquencies, defaults, recoveries, and tranche-level writedowns.
- **Deal Documents:** Offering circulars detailing the waterfall, triggers, and structural features.
- **Data Access:** Available through Freddie Mac's website, Bloomberg, and third-party analytics providers.

---

## Data Disclosures

Freddie Mac provides a comprehensive set of data disclosures for investors, analysts, and researchers.

### 1. MBS Pool-Level Disclosures

- **Monthly Factor Files:** Current factor (remaining principal ratio) for each pool.
- **Pool Statistics:** WAC, WAM, WALA, loan count, average loan size, geographic distribution.
- **Supplemental Disclosures:** Delinquency distributions, prepayment speeds, and other pool-level metrics.

### 2. Investor Reporting

- **Monthly Investor Reports:** Detailed performance data for each UMBS pool.
- **Remittance Data:** Payment amounts passed through to investors.
- **Available through:** Freddie Mac's Investor Access portal and the CSS platform.

### 3. Selling Guide and Servicing Guide

- **Freddie Mac Single-Family Seller/Servicer Guide:** The comprehensive policy manual governing all aspects of loan origination, delivery, and servicing for Freddie Mac.
- **Available online:** Fully searchable, with regular updates via Bulletins.

### 4. LLPA Grids

- Published in the Seller/Servicer Guide under the pricing section.
- Cover the same risk dimensions as Fannie Mae (credit score, LTV, loan purpose, property type, occupancy, etc.).
- Updated periodically; typically aligned closely with Fannie Mae's grids (FHFA has pushed for alignment).

### 5. STACR Disclosures

- Loan-level reference pool data for each STACR deal.
- Monthly trustee reports and performance summaries.
- Accessible through Freddie Mac's CRT page and third-party platforms.

### 6. Freddie Mac Research and Data Products

| Product | Description |
|---------|-------------|
| **Primary Mortgage Market Survey (PMMS)** | Weekly survey of mortgage rates; the most widely cited mortgage rate benchmark in the U.S. |
| **House Price Index (FHFA HPI)** | While technically FHFA's product, it is based on Freddie Mac and Fannie Mae data |
| **Quarterly Foreclosure Prevention Reports** | Data on loan workouts, modifications, and foreclosure alternatives |
| **Outlook and Economic Research** | Macroeconomic and housing market forecasts |

---

## Key Differences from Fannie Mae

While Fannie Mae and Freddie Mac serve nearly identical roles, there are meaningful differences that data engineers should understand:

### Structural and Operational Differences

| Dimension | Freddie Mac | Fannie Mae |
|-----------|-------------|------------|
| **Founded** | 1970 | 1938 |
| **AUS** | Loan Product Advisor (LPA) | Desktop Underwriter (DU) |
| **Legacy MBS** | Gold Participation Certificates (PCs) | Fannie Mae MBS |
| **Legacy Payment Delay** | 45 days | 55 days |
| **CRT Program** | STACR | CAS |
| **Loan Delivery Platform** | Loan Selling Advisor | Loan Delivery |
| **Seller/Servicer Guide** | Single-Family Seller/Servicer Guide | Selling Guide + Servicing Guide (separate) |
| **Investor Portal** | Freddie Mac Investor Access | Fannie Mae Connect |
| **Market Share** | ~35-40% of GSE volume | ~60-65% of GSE volume |

### Underwriting and Eligibility Differences

Although FHFA has pushed for alignment, subtle differences remain:

| Area | Freddie Mac | Fannie Mae |
|------|-------------|------------|
| **Credit Score Requirements** | Some differences in minimum score thresholds for certain products | Slightly different thresholds |
| **Income Calculation** | May accept different income documentation in certain scenarios | Different income calc methods for edge cases |
| **Property Types** | Minor differences in eligibility for certain property types (e.g., manufactured housing) | Slightly different manufactured housing policies |
| **Condo Requirements** | Different condo project review requirements | Different condo project review processes |
| **Renovation Loans** | CHOICERenovation program | HomeStyle Renovation program |
| **Affordable Programs** | Home Possible (3% down) | HomeReady (3% down) |

### Data Format Differences

| Aspect | Freddie Mac | Fannie Mae |
|--------|-------------|------------|
| **Loan Sequence Number Format** | Different format and length | Different format and length |
| **Pool Number Format** | Different prefix conventions (QA, QB, etc.) | Different prefix conventions (CL, CI, etc.) |
| **Public Dataset Fields** | Slightly different field set | Slightly different field set |
| **Geographic Detail** | Includes MSA in public data | MSA not in standard public data |
| **ULDD** | Same format (standardized) | Same format (standardized) |

### Pricing Differences

- **LLPA grids** are largely aligned between the two GSEs due to FHFA guidance, but minor differences may exist for specific loan characteristics.
- **G-fees** are set independently by each GSE but must comply with FHFA directives on pricing.
- **Before UMBS:** Freddie Mac PCs traded at a discount to Fannie Mae MBS due to the liquidity difference. This "Freddie Mac basis" is now largely eliminated.

---

## Common Interview Questions

### Conceptual Questions

**Q1: What is Freddie Mac and how does it differ from Fannie Mae?**

> **A:** Freddie Mac (Federal Home Loan Mortgage Corporation) is a government-sponsored enterprise created in 1970 to provide competition to Fannie Mae and expand secondary market liquidity. Both GSEs purchase conforming conventional mortgages, securitize them into MBS, and guarantee timely payment of P&I. Key differences include: Freddie Mac uses Loan Product Advisor (LPA) vs. Fannie Mae's Desktop Underwriter (DU); Freddie Mac's CRT program is STACR vs. CAS; Freddie Mac historically issued Gold PCs with a 45-day delay vs. Fannie Mae's 55-day delay (now both issue UMBS at 55 days); and Freddie Mac has a smaller market share (~35-40% vs. ~60-65%).

**Q2: Explain the UMBS transition and why it mattered.**

> **A:** Before 2019, Fannie Mae MBS and Freddie Mac Gold PCs were separate, non-fungible securities. Because Fannie Mae had higher volume and its MBS were more liquid, Freddie Mac PCs traded at a discount (the "Freddie Mac basis"). This raised Freddie Mac's effective cost of doing business. The Single Security Initiative, mandated by FHFA, created the Uniform Mortgage-Backed Security (UMBS), which both GSEs issue through a Common Securitization Platform. UMBS are fungible -- an investor doesn't care whether the underlying pool was originated through Fannie Mae or Freddie Mac. The transition required Freddie Mac to extend its payment delay from 45 to 55 days. The result was improved market liquidity, reduced costs, and fair competition between the GSEs.

**Q3: What is STACR and how does it transfer credit risk?**

> **A:** STACR (Structured Agency Credit Risk) is Freddie Mac's credit risk transfer program. Freddie Mac issues notes whose performance is linked to a reference pool of recently acquired mortgage loans. The notes are tranched (B-2, B-1, M-2, M-1), with the B-2 tranche absorbing first losses. If loans in the reference pool default and losses are realized, those losses reduce the principal balance of the STACR notes, starting with the most junior tranche. This transfers credit risk from Freddie Mac's balance sheet (and taxpayers) to private investors who are compensated with higher yields for bearing that risk.

**Q4: What is Loan Product Advisor (LPA) and how does it compare to DU?**

> **A:** LPA is Freddie Mac's automated underwriting system. Like Fannie Mae's DU, it evaluates borrower creditworthiness and loan eligibility for GSE purchase. LPA returns "Accept" or "Caution" recommendations (vs. DU's "Approve/Eligible" or "Refer with Caution"). LPA uses its own proprietary credit model and has different approaches to income and asset verification (AIM vs. DU Validation Service). Many lenders run loans through both systems to determine which GSE offers better execution.

### Data Engineering Questions

**Q5: You need to build a unified data model that supports both Fannie Mae and Freddie Mac loan-level datasets. What are the key challenges?**

> **A:** Key challenges include:
> - **Schema Alignment:** While both datasets have similar fields, the exact field names, positions, and valid values differ. You need a mapping layer that normalizes both into a common schema.
> - **Loan Identifiers:** Loan sequence numbers have different formats. You need a surrogate key strategy and source system identifiers.
> - **Field Coverage Differences:** Freddie Mac includes MSA; Fannie Mae does not in its standard public dataset. You must decide whether to include GSE-specific fields or only common fields.
> - **Temporal Alignment:** Both update quarterly but may not release on the same schedule. Your pipeline must handle asynchronous updates.
> - **Volume:** The combined dataset is enormous. You need partitioning (by source, vintage, or time period), columnar storage, and efficient join strategies.
> - **Business Rules:** Delinquency status codes, zero balance codes, and modification flags may have slightly different definitions. You need a standardized code mapping.

**Q6: How would you design an ETL pipeline for the Freddie Mac Single Family Loan-Level Dataset?**

> **A:**
> - **Extract:** Download quarterly files from Freddie Mac's website (automated via scripting; files are pipe-delimited with no headers). Maintain a manifest of downloaded files.
> - **Load (Staging):** Load raw files into a staging area, applying the schema from the published data dictionary. Use a tool like Spark, dbt, or a cloud-native ELT framework.
> - **Transform:**
>   1. Apply data types (dates, numerics, strings).
>   2. Validate against expected ranges and valid values.
>   3. Split into origination dimension and performance fact tables.
>   4. Calculate derived metrics (months delinquent bucket, cumulative loss, modification type).
>   5. Build vintage cohorts for time-series analysis.
> - **Quality:** Check for duplicate loan sequence numbers in origination, monotonically decreasing UPB (unless modified), valid delinquency transitions, and referential integrity between origination and performance.
> - **Serve:** Materialize analytical views: default curves, prepayment curves, loss severity by vintage/geography/LTV/FICO.

**Q7: The Freddie Mac dataset includes a "Zero Balance Code" field. What does it represent and how would you use it in a data model?**

> **A:** The Zero Balance Code indicates the reason a loan reached a zero unpaid principal balance:
> - **01:** Prepaid or matured (voluntary payoff)
> - **02:** Third-party sale (short sale or foreclosure sale to third party)
> - **03:** Foreclosure (REO -- Freddie Mac acquired the property)
> - **06:** Repurchased (loan bought back by the seller due to a defect)
> - **09:** REO disposition
> - **15:** Note sale (Freddie Mac sold the non-performing loan)
>
> In a data model, I would use this field to:
> 1. Calculate **cumulative default rates** (codes 02, 03, 09 indicate credit events).
> 2. Calculate **voluntary prepayment rates** (code 01).
> 3. Calculate **loss severity** (using loss fields filtered to default-related zero balance codes).
> 4. Build **loan termination analysis** views that segment by termination reason.
> 5. Track **repurchase activity** (code 06) for quality control and seller performance monitoring.

**Q8: How would you handle the Gold PC to UMBS transition in a historical MBS data warehouse?**

> **A:** I would implement the following:
> - **Pool Identifier Mapping:** Maintain a crosswalk table mapping legacy Gold PC pool numbers to UMBS pool numbers (for pools that were exchanged via M-securities).
> - **Security Type Dimension:** Include a security type field (Gold PC, UMBS, M-Security) in the pool dimension to distinguish legacy from current instruments.
> - **Payment Delay Handling:** Store the payment delay (45 or 55 days) as a pool-level attribute to correctly calculate cash flow timing.
> - **Time-Based Logic:** Use the June 3, 2019 cutoff date to apply different business rules for pre- and post-transition pools.
> - **Factor Continuity:** Ensure that monthly factor data is continuous across the transition for exchanged pools.

---

## Tips for Data Engineers

### Working with Freddie Mac Data

1. **Leverage the alignment with Fannie Mae data.** Since both GSEs use ULDD for loan delivery and have similar public datasets, you can often reuse pipeline code with minor modifications. Build abstraction layers that handle GSE-specific differences.

2. **Use the Freddie Mac User Guide religiously.** The public loan-level dataset documentation is detailed and includes field definitions, valid values, and important caveats. Changes between quarterly releases are noted in release notes.

3. **Handle the no-header format carefully.** Like Fannie Mae, Freddie Mac's files have no column headers. You must apply the schema from the data dictionary. Any schema changes between releases can silently break your pipeline if you hard-code column positions.

4. **Partition by vintage year.** The dataset is naturally organized by origination vintage (year and quarter). Partitioning your storage and processing by vintage enables efficient incremental loads and targeted queries.

5. **Understand the Freddie Mac Primary Mortgage Market Survey (PMMS).** If you work with interest rate data, the PMMS is a critical reference dataset. It is published weekly and is the most widely cited source for average U.S. mortgage rates.

6. **Monitor STACR deal issuance for CRT analysis.** Each STACR deal has a unique reference pool. If you build CRT analytics, you need to track deal issuance dates, reference pool compositions, and tranche structures as they are issued.

7. **Reconcile pool-level and loan-level data.** Pool factors, WAC, and other aggregate statistics published in pool disclosures should reconcile with aggregations of the loan-level data for the same pool. Use this as a data quality check.

8. **Plan for the UMBS era.** New analyses should assume UMBS as the default. Legacy Gold PC data is historical. Ensure your data model supports both, but optimize for the current UMBS paradigm.

9. **Use Freddie Mac's API and data feeds where available.** Freddie Mac has been expanding programmatic access to its data. Check for API endpoints before building screen-scraping or manual download processes.

10. **Track FHFA alignment directives.** FHFA periodically mandates alignment between Fannie Mae and Freddie Mac on pricing, eligibility, and data standards. Staying current with FHFA directives helps you anticipate schema and business rule changes.

---

*This document provides an overview of Freddie Mac's structure, programs, and data for data engineering interview preparation. For the most current information, always refer to Freddie Mac's official Single-Family Seller/Servicer Guide, investor disclosures, and data product documentation.*
