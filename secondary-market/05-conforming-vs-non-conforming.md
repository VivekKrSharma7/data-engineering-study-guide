# Conforming vs Non-Conforming Loans

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### What Makes a Loan "Conforming"?

A **conforming loan** is a mortgage that meets the underwriting guidelines and loan limits established by Fannie Mae and Freddie Mac (the GSEs). Conforming loans are eligible for purchase by the GSEs and, once purchased, can be securitized into agency MBS (UMBS). This GSE eligibility is what gives conforming loans their favorable pricing — the implied government backing reduces investor risk, translating to lower interest rates for borrowers.

A loan must satisfy **two categories** of requirements to be conforming:

1. **Loan limit compliance**: The loan amount must fall within the conforming loan limit set by FHFA.
2. **Underwriting guideline compliance**: The loan must meet GSE requirements for credit score, LTV, DTI, property type, occupancy, documentation, and other factors.

---

### Conforming Loan Limits

The **Federal Housing Finance Agency (FHFA)** sets conforming loan limits annually, based on changes in the national average home price as measured by the FHFA House Price Index (HPI).

#### Baseline Conforming Limit
- The standard limit for most counties in the US.
- For 2025, the baseline limit is **$806,500** for a one-unit property (it is adjusted annually and the 2026 figure will be announced in Q4 2025).
- Higher limits apply for 2-unit ($1,032,650), 3-unit ($1,248,150), and 4-unit ($1,551,250) properties.

#### High-Cost Area Limit
- In designated high-cost areas (where the local median home value exceeds 115% of the baseline), the limit is set at **150% of the baseline**.
- For 2025, the high-cost ceiling is **$1,209,750** for a one-unit property.
- High-cost areas include counties in California (Los Angeles, San Francisco, San Diego), New York metro, Washington DC metro, Hawaii, Alaska (all counties), and others.

#### Super-Conforming Loans
- Loans between the baseline limit and the high-cost ceiling are sometimes called **super-conforming** or **high-balance conforming** loans.
- These loans are GSE-eligible but typically carry slightly higher interest rates and fees (LLPAs — Loan-Level Price Adjustments) than standard conforming loans.
- From a data perspective, super-conforming loans require county-level limit lookups to determine eligibility. This means the data pipeline must maintain a current FHFA county limit table and join it to loan data by FIPS code.

#### FHFA Annual Adjustment Process
- Each November, FHFA announces the next year's limits based on Q3-to-Q3 HPI changes.
- The limits have increased every year since 2017 (after being frozen at $417,000 from 2006-2016 in most areas).
- Data engineers must update limit tables annually and handle the transition (loans locked in December for January closing may need to use the new limits).

---

### GSE Eligibility Requirements

Beyond loan amount, conforming loans must meet GSE underwriting guidelines. Key parameters include:

#### Credit Score
- **Minimum FICO**: Generally 620 for Fannie Mae and Freddie Mac (with limited exceptions).
- Higher scores receive better pricing (lower LLPAs).
- The **representative credit score** is the middle of three bureau scores for a single borrower, or the lower of the two borrowers' representative scores for joint applications.

#### Loan-to-Value (LTV)
- Maximum LTV varies by transaction type:
  - **Purchase**: Up to 97% LTV (with restrictions — first-time homebuyers, income limits).
  - **Rate/term refinance**: Up to 97% LTV (Fannie Mae) or 95% (Freddie Mac, varies by program).
  - **Cash-out refinance**: Up to 80% LTV.
- LTV impacts LLPA pricing and mortgage insurance requirements.

#### Debt-to-Income (DTI)
- Maximum DTI is generally **50%** for loans run through AUS (DU/LPA), though higher DTIs may be approved with strong compensating factors.
- Manual underwriting typically caps DTI at 36%-45%.

#### Property Type
- Eligible: single-family, PUD, condo (warrantable), co-op, manufactured housing (with restrictions), 2-4 unit.
- Ineligible: non-warrantable condos, condotels, commercial properties, mixed-use (with limited exceptions).

#### Occupancy
- Primary residence, second home, and investment property are all eligible, but pricing and LTV limits differ significantly.
- Investment property loans have the highest LLPAs and most restrictive LTV limits.

#### Loan-Level Price Adjustments (LLPAs)
- LLPAs are risk-based pricing add-ons (or credits) applied based on the combination of credit score, LTV, occupancy, property type, loan purpose, and other factors.
- Published in the Fannie Mae LLPA matrix and Freddie Mac Postsettlement Delivery Fee tables.
- LLPAs are critical for data engineers building pricing pipelines — they must be accurately calculated from loan attributes and applied to the base price.

---

### Non-Conforming Loans

Loans that do **not** meet GSE requirements fall into the non-conforming category. These loans cannot be sold to Fannie Mae or Freddie Mac and must find alternative secondary market paths (private investors, bank portfolios, or private-label securitization).

#### Jumbo Loans
- Loans that exceed the conforming limit for the property's county.
- A $1,000,000 loan in a county with a $806,500 limit is a jumbo.
- Jumbo loans are typically held on bank balance sheets or securitized in the private-label market.
- Characteristics: higher credit quality borrowers (700+ FICO typical), lower LTVs, larger down payments.
- Jumbo pricing can sometimes be competitive with conforming rates when bank balance sheets are flush with capital.

#### Alt-A Loans
- Historically, **Alternative-A** loans were made to borrowers with good credit but non-standard documentation (e.g., stated income, no-doc).
- The Alt-A market was virtually eliminated after the 2008 financial crisis.
- Modern equivalents exist in the **non-QM** market (see below).

#### Subprime Loans
- Loans to borrowers with impaired credit (FICO below 620, recent bankruptcy/foreclosure, high DTI).
- The traditional subprime market collapsed in 2007-2008 and has not returned in its pre-crisis form.
- Modern non-QM lenders serve some of this market segment with tighter controls and risk-retention requirements.

---

### Qualified Mortgage (QM) vs Non-Qualified Mortgage (Non-QM)

The **Ability-to-Repay (ATR) rule** and **Qualified Mortgage (QM)** standards were established by the Dodd-Frank Act and implemented by the CFPB (now under Regulation Z).

#### Ability-to-Repay (ATR) Rule
- Requires lenders to make a **reasonable, good-faith determination** that the borrower can repay the loan.
- Eight underwriting factors must be considered: income, assets, employment, credit history, DTI, monthly payment, other loan obligations, and payment on other simultaneous loans.
- Applies to virtually all residential mortgage loans (some exemptions for HELOCs, construction-only, etc.).

#### Qualified Mortgage (QM)
A QM is a loan that meets specific product feature and underwriting requirements, providing the lender with a **legal safe harbor** (or rebuttable presumption) against ATR lawsuits:

**General QM requirements**:
- No negative amortization, interest-only, or balloon features (with narrow exceptions).
- Loan term no longer than 30 years.
- Points and fees do not exceed 3% of the loan amount (for loans over $100,000).
- Under the current **price-based** General QM rule (effective October 2022): the APR cannot exceed APOR (Average Prime Offer Rate) by 2.25 percentage points or more (for first-lien loans over $100,000). This replaced the prior 43% DTI hard cap.

**GSE Patch / Temporary QM (expired)**: Previously, any loan eligible for GSE purchase was automatically QM, regardless of DTI. This expired when the price-based QM rule took effect.

**Seasoned QM**: Loans held in portfolio for 36 months with no more than two 30-day delinquencies and no 60+ day delinquencies can attain QM status retroactively.

#### Non-QM Loans
Non-QM loans intentionally fall outside the QM definition. They are **not illegal** — the lender simply does not receive the QM safe harbor and must document ATR compliance independently.

Common non-QM products:
- **Bank statement loans**: Income documented via 12-24 months of bank statements instead of tax returns (common for self-employed borrowers).
- **DSCR loans (Debt Service Coverage Ratio)**: Investment property loans qualified based on rental income covering the mortgage payment. No personal income verification.
- **Interest-only loans**: The interest-only feature disqualifies from QM.
- **Asset depletion/asset qualifier**: Borrower's liquid assets are used to impute income.
- **Foreign national loans**: For non-resident borrowers.
- **Recent credit event loans**: Borrowers with recent bankruptcy, foreclosure, or short sale who do not meet GSE seasoning requirements.

Data implication: Non-QM loans require additional data fields (bank statement analysis, DSCR calculations, ATR documentation) that are not part of the standard ULDD. Data engineers building pipelines for non-QM lenders must handle these proprietary datasets and ensure they flow correctly to private-label securitization or whole-loan sale channels.

---

### Agency vs Private-Label Path

| Attribute | Agency Path | Private-Label Path |
|---|---|---|
| Loan type | Conforming (GSE-eligible) | Non-conforming (jumbo, non-QM) |
| Buyer | Fannie Mae, Freddie Mac | Private investors, banks, hedge funds |
| Securitization | UMBS via CSP | Private RMBS via investment bank shelf |
| Guarantee | GSE credit guarantee (backed by FHFA conservatorship) | No government guarantee; credit risk borne by investors via tranching |
| Data standard | ULDD / MISMO | Investor-specific; often proprietary loan tapes |
| Pricing | TBA market, LLPAs | Whole loan bid, spread to benchmark |
| Disclosure | Standardized loan-level (Fannie, Freddie disclosure files) | Varies; often Intex, Bloomberg, trustee reports |
| Risk retention | Exempt (GSE guarantee) | Required under Dodd-Frank (5% risk retention for securitizer, with QM and QRM exemptions) |

---

## Real-World Examples

### Example 1: Conforming Limit Lookup
A lender's pricing engine must determine the conforming status of every new application. For a $900,000 loan on a single-family home in Orange County, CA (2025 high-cost limit: $1,209,750), the loan is **super-conforming** — it exceeds the baseline $806,500 but falls under the high-cost ceiling. It is GSE-eligible but will incur higher LLPAs. The data pipeline must join the loan's property FIPS code (06059 for Orange County) to the FHFA limit table to make this determination automatically. If the same loan were in Dallas County, TX (baseline limit applies), it would be a **jumbo** loan and ineligible for GSE purchase.

### Example 2: Non-QM DSCR Loan Pipeline
A non-QM lender originates 200 DSCR loans per month for real estate investors. Each loan is qualified based on the rental income of the subject property divided by the PITIA (principal, interest, taxes, insurance, association dues) payment — a ratio of 1.0x or higher is typically required. The data pipeline must capture lease agreements, rental income, property management details, and DSCR calculations — none of which exist in the standard GSE data model. These loans are sold whole to a private aggregator who pools them into private-label RMBS. The data engineer builds a custom loan tape with 150+ fields mapped to the aggregator's specifications, plus a separate ATR compliance dataset documenting the lender's ability-to-repay analysis.

### Example 3: LLPA Pricing Calculation
A borrower applies for a conforming loan with a 700 FICO score, 85% LTV, for a single-family primary residence purchase. The secondary marketing system looks up the LLPA matrix: the credit score / LTV combination yields an LLPA of -1.250% (meaning the loan price is 1.25 points below the base price). Additional adjustments may apply for loan amount (super-conforming), subordinate financing, or other factors. The data engineer ensures the LLPA matrix is version-controlled, updated when Fannie Mae publishes changes, and correctly integrated into the pricing engine so that borrower rate quotes are accurate.

---

## Common Interview Questions and Answers

### Q1: What is the difference between a conforming and non-conforming loan?
**A:** A conforming loan meets both the **loan amount limits** set by FHFA and the **underwriting guidelines** of Fannie Mae or Freddie Mac, making it eligible for GSE purchase and agency securitization. A non-conforming loan fails one or both criteria — it may exceed the conforming limit (jumbo), or it may not meet GSE guidelines for credit score, LTV, DTI, documentation, or product features (e.g., interest-only). Non-conforming loans must be held in portfolio or sold through private channels. The distinction is fundamental to data engineering because it determines the entire downstream path: data formats (ULDD vs proprietary), delivery systems (GSE portals vs bulk sale), and reporting requirements.

### Q2: What is a super-conforming or high-balance loan, and what are the data implications?
**A:** A super-conforming loan has an amount between the baseline conforming limit ($806,500 for 2025) and the high-cost area ceiling ($1,209,750 for 2025). It is GSE-eligible only if the property is located in a designated high-cost county. The data implication is that eligibility determination requires a **county-level lookup** — the pipeline must maintain a current FHFA conforming limit table indexed by FIPS code and unit count, join it to each loan's property location, and flag whether the loan is baseline conforming, super-conforming, or jumbo. This table must be refreshed annually when FHFA publishes new limits, and edge cases around the transition date (loans locked in late December) must be handled.

### Q3: Explain the QM rule and its significance for secondary market data.
**A:** The Qualified Mortgage rule provides lenders a legal safe harbor against ATR (Ability-to-Repay) lawsuits. Under the current price-based General QM standard, a loan is QM if its APR does not exceed APOR + 2.25% (for standard first liens) and it meets product feature requirements (no negative amortization, no IO, no balloon, term <= 30 years, points/fees <= 3%). For data engineers, QM status must be determined and stored for every loan because it affects: (1) the loan's secondary market value — QM loans trade at tighter spreads; (2) securitization eligibility — risk retention rules differ for QM vs non-QM; (3) regulatory reporting; and (4) the available delivery channels. The APR and APOR comparison must be accurately calculated, which requires the APR from the Closing Disclosure and the APOR from the FFIEC rate table as of the rate lock date.

### Q4: How would you build a data pipeline that handles both conforming and non-QM loans?
**A:** I would design a **bifurcated pipeline** with a shared intake layer and divergent downstream paths. The intake layer ingests all loans from the LOS and enriches them with conforming status (via FHFA limit lookup) and QM status (via APR/APOR comparison and product feature checks). Conforming QM loans are routed to the **agency delivery path**: data is transformed to ULDD format, validated against GSE edit rules, and delivered via GSE systems. Non-conforming or non-QM loans are routed to the **private path**: data is transformed to investor-specific loan tape formats, enriched with non-standard fields (DSCR, bank statement income), and delivered via secure file transfer. Both paths feed a common data warehouse for unified reporting, but the schemas accommodate the superset of fields needed for both markets. The QM/non-QM flag and conforming/non-conforming flag are critical dimensions in the warehouse.

### Q5: What happens to the conforming loan limit data when FHFA announces annual changes?
**A:** When FHFA announces new limits (typically in late November), the data engineering team must: (1) Obtain the updated county-level limit table from FHFA's website; (2) Validate the data for completeness (all US counties plus territories); (3) Load the new limits with an effective date (January 1 of the new year); (4) Update the pricing engine, eligibility engine, and reporting systems to reference the new limits for loans with application dates on or after the effective date; (5) Handle edge cases — some GSEs allow early adoption of new limits for loans closing after a certain date; (6) Maintain historical limit tables for audit and reporting purposes (older loans must be evaluated against the limits in effect at the time of origination). This is a classic slowly changing dimension (SCD Type 2) pattern.

### Q6: What is the difference between the agency and private-label securitization path from a data perspective?
**A:** The agency path (Fannie Mae, Freddie Mac) uses **standardized data formats** (ULDD via MISMO XML), **automated validation** (GSE edit checks), and **standardized disclosure** (monthly loan-level files published by the GSEs). The private-label path uses **investor-specific formats** (CSV/Excel loan tapes with varying schemas), **manual/custom due diligence** (third-party review firms), and **less standardized disclosure** (trustee reports, Intex models, SEC Rule 15Ga-1 filings). For a data engineer, the agency path is more predictable but rigid — every field must match exactly. The private-label path is more flexible but chaotic — each investor may want different fields, different calculations, and different file layouts. Supporting both requires a flexible data transformation layer and robust metadata management.

---

## Tips

- **Memorize the current conforming loan limits**. Interviewers in mortgage expect you to know the baseline ($806,500 for 2025) and high-cost ceiling ($1,209,750). Knowing these numbers demonstrates you are actively engaged with the industry.
- Understand that **conforming vs non-conforming** is about GSE eligibility (loan amount + guidelines), while **QM vs non-QM** is about ATR legal protections (product features + pricing). These are two separate classifications, and a loan can be conforming but non-QM (rare but possible) or non-conforming but QM (a jumbo loan with standard features).
- The **LLPA matrix** is one of the most data-intensive components of mortgage pricing. Be prepared to discuss how you would implement LLPA lookups in a pricing engine — it is essentially a multi-dimensional lookup table that must be version-controlled and auditable.
- Non-QM is a **growing market segment** (2024-2025 origination volume has been increasing). Demonstrating knowledge of DSCR loans, bank statement programs, and private-label securitization shows you are current with industry trends.
- For data engineering roles, emphasize your ability to handle the **county-level geographic dimension** — FIPS codes, MSA codes, and state-level regulatory variations are central to conforming limit determination, high-cost mortgage thresholds (HOEPA), and state-specific compliance requirements.
