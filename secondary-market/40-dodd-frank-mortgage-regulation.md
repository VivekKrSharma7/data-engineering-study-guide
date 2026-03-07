# Dodd-Frank & Mortgage Regulation

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Dodd-Frank Act Overview

The **Dodd-Frank Wall Street Reform and Consumer Protection Act** (2010) was the most sweeping financial regulatory overhaul since the 1930s, enacted in direct response to the 2008 financial crisis. For secondary market data engineers, Dodd-Frank fundamentally reshaped the data landscape by imposing transparency, reporting, and compliance requirements across every stage of the mortgage lifecycle.

**Core Titles Relevant to Mortgage Markets:**

| Title | Name | Relevance |
|-------|------|-----------|
| Title I | Financial Stability | FSOC systemic risk oversight, stress testing data |
| Title VII | Wall Street Transparency | Derivatives/swap regulation affecting MBS hedging |
| Title IX | Investor Protections | SEC authority over ABS, credit rating reform |
| Title X | CFPB Creation | Consumer protection, origination standards |
| Title XIV | Mortgage Reform | ATR/QM rules, origination standards, servicing |

**Key Statistics:**
- Over 2,300 pages of legislation
- Required 398 rulemakings across 20+ agencies
- Created the Consumer Financial Protection Bureau (CFPB)
- Established the Financial Stability Oversight Council (FSOC)

---

### CFPB Creation and Role

The **Consumer Financial Protection Bureau (CFPB)** was created under Title X of Dodd-Frank as an independent bureau within the Federal Reserve System. It consolidated consumer financial protection authority previously scattered across seven federal agencies.

**CFPB Responsibilities in Mortgage Markets:**

- **Rulemaking:** ATR/QM rules, TRID (TILA-RESPA Integrated Disclosure), HMDA modernization, servicing rules
- **Supervision:** Examination of banks with assets >$10 billion, nonbank mortgage lenders and servicers
- **Enforcement:** Civil investigative demands, consent orders, civil penalties
- **Data Collection:** HMDA data, consumer complaint database, market monitoring

**Data Engineering Implications:**
- The CFPB's complaint database is a publicly available dataset with mortgage complaint records
- HMDA data modernization (effective 2018) expanded required fields from ~30 to ~110
- Loan Estimate and Closing Disclosure (TRID) changed the document data model for origination systems
- The CFPB publishes regulations in machine-readable formats, enabling automated compliance checks

---

### Ability-to-Repay (ATR) and Qualified Mortgage (QM) Rules

The **ATR rule** (Regulation Z, 12 CFR 1026.43) requires creditors to make a reasonable, good-faith determination that a borrower can repay a mortgage loan before or when the loan is consummated.

**Eight ATR Underwriting Factors:**

1. Current or reasonably expected income or assets
2. Current employment status
3. Monthly mortgage payment (fully indexed rate)
4. Monthly payment on simultaneous loans
5. Monthly payment for property taxes, insurance, HOA
6. Current debt obligations, alimony, child support
7. Monthly debt-to-income ratio (DTI)
8. Credit history

**Qualified Mortgage (QM) Definition:**

A QM is a category of mortgage that meets specific product feature and underwriting requirements, providing lenders with a legal safe harbor or rebuttable presumption against ATR liability.

**QM Requirements (General QM as revised in 2021):**

| Requirement | Detail |
|-------------|--------|
| DTI / Price-Based | Loan APR cannot exceed APOR by 2.25% (first-lien, ≥$110K) |
| Points and Fees | Cannot exceed 3% of loan amount (for loans ≥$110K) |
| Loan Term | Maximum 30 years |
| Negative Amortization | Not permitted |
| Interest-Only | Not permitted |
| Balloon Payments | Not permitted (exception for small creditors in rural areas) |
| Income/Asset Verification | Required — must consider and verify |

**QM Categories:**

- **General QM:** Meets the price-based threshold and product restrictions
- **GSE Patch QM (expired):** Loans eligible for purchase by Fannie Mae/Freddie Mac (expired October 2022)
- **Small Creditor QM:** For creditors with <$2 billion in assets and originating ≤2,000 first-lien mortgages per year
- **Seasoned QM:** Loans that meet certain performance requirements over a 36-month seasoning period

**Data Engineering Relevance:**
- ATR/QM status must be tracked as a loan-level attribute in origination and secondary market databases
- QM determination logic involves calculations against APOR (Average Prime Offer Rate) published weekly by the CFPB/FFIEC
- Points-and-fees calculations require aggregating multiple fee fields
- Non-QM loans trade at different spreads and require separate pipeline tracking

---

### Risk Retention — 5% Skin in the Game

**Section 941 of Dodd-Frank** established credit risk retention requirements for securitizers of asset-backed securities, codified in the joint agency final rule (effective December 2016).

**Core Requirement:**
Securitizers must retain not less than **5% of the credit risk** of assets they securitize.

**Retention Forms:**

| Form | Description |
|------|-------------|
| Vertical | Retain 5% of each tranche issued |
| Horizontal | Retain the most subordinate 5% (first-loss position) |
| L-Shaped | Combination of vertical and horizontal |
| Representative Sample | Retain 5% of a random, representative sample of the pool |

**Qualified Residential Mortgage (QRM) Exemption:**

The final rule defined **QRM = QM**, meaning loans meeting the Qualified Mortgage standard are exempt from risk retention requirements. This was a significant simplification from original proposals that would have required 20% down payments.

**Other Key Exemptions:**

- **GSE exemption:** Fannie Mae and Freddie Mac MBS are exempt while in conservatorship (since the government effectively holds the credit risk)
- **Federal agency exemption:** Ginnie Mae securities (FHA, VA, USDA loans) are exempt
- **CMBS B-piece buyer exception:** Specific provisions for commercial MBS

**Data Engineering Implications:**
- Securitization databases must track risk retention form (vertical, horizontal, L-shaped)
- Fair value calculations for retained interests require mark-to-market data pipelines
- QRM/QM exemption status must be determined at the loan level
- Retention compliance reporting requires ongoing monitoring of retained tranche performance

---

### Volcker Rule Impact on MBS

**Section 619 of Dodd-Frank** (the Volcker Rule) prohibits banking entities from engaging in proprietary trading and limits their investments in hedge funds and private equity funds, including certain securitization vehicles.

**Impact on MBS Markets:**

- **Covered funds definition:** Initially threatened to classify CLOs and certain CDOs as "covered funds," reducing bank participation
- **Market-making exemption:** Banks can still make markets in MBS but must demonstrate inventory is related to near-term customer demand
- **Reduced liquidity:** Some market participants argue the Volcker Rule reduced secondary market liquidity in less liquid tranches (e.g., non-agency CMBS, CLO equity)
- **Securitization exemption (2020 amendment):** Loan securitizations were clarified as exempt from the covered fund definition

**Data Tracking Requirements:**
- Trading desks must maintain metrics demonstrating market-making activity vs. proprietary positions
- Inventory aging reports, customer-facing trade ratios, and risk limits must be tracked
- MBS trading platforms must flag Volcker-covered positions

---

### Servicing Rules

Dodd-Frank directed the CFPB to establish servicing rules under RESPA (Regulation X) and TILA (Regulation Z), which took effect January 2014 with amendments in subsequent years.

**Key Servicing Requirements:**

| Rule | Requirement |
|------|-------------|
| Early Intervention | Contact delinquent borrowers by 36th day; written notice by 45th day |
| Continuity of Contact | Assign dedicated personnel for delinquent borrowers |
| Loss Mitigation | Evaluate complete applications within 30 days; no dual tracking |
| Error Resolution | Acknowledge within 5 business days; resolve within 30 days |
| Periodic Statements | Monthly statements with payment breakdown, transaction activity |
| Force-Placed Insurance | Two notices required before charging; must terminate within 15 days of borrower proof |
| Payment Crediting | Credit payments as of date received if conforming payment |
| Escrow | Wait 12 months before canceling escrow on higher-priced mortgages |

**Dual Tracking Prohibition:**
Servicers cannot pursue foreclosure while a borrower's complete loss mitigation application is pending review. This requires tight integration between loss mitigation workflow systems and foreclosure timeline tracking.

**Data Engineering Implications:**
- Servicing systems must track regulatory timelines (36-day call, 45-day letter, 30-day loss mitigation review)
- Loss mitigation application completeness status must be tracked as a data attribute
- Dual-tracking prevention requires real-time integration between loss mitigation and foreclosure systems
- Periodic statement generation requires accurate payment waterfall data, escrow analysis, and delinquency status

---

### Origination Standards

Dodd-Frank imposed significant new origination requirements that directly impact data captured at loan origination.

**Loan Originator Compensation (LO Comp) Rules:**
- Prohibit compensation based on loan terms (rate, margin, etc.)
- Prohibit dual compensation (both borrower and creditor paying the LO)
- Require tracking of compensation structure in origination systems

**TILA-RESPA Integrated Disclosure (TRID):**
- Replaced GFE/TIL with Loan Estimate (LE) and HUD-1/Final TIL with Closing Disclosure (CD)
- Three-business-day delivery requirements for both LE and CD
- Tolerance thresholds for fee changes (0%, 10%, unlimited categories)
- Changed date fields that must be tracked (application date, LE sent date, CD sent date, consummation date)

**Higher-Priced Mortgage Loans (HPML):**
- Loans with APR exceeding APOR + 1.5% (first-lien) or + 3.5% (subordinate-lien)
- Require escrow accounts for at least 5 years
- Require interior property appraisal
- HPML status is a critical data flag in loan origination and secondary market systems

---

### Regulatory Impact on Secondary Market Data Requirements

Dodd-Frank created a cascade of data requirements that fundamentally transformed secondary market data engineering:

**Pre-Dodd-Frank vs. Post-Dodd-Frank Data Landscape:**

| Dimension | Pre-Dodd-Frank | Post-Dodd-Frank |
|-----------|---------------|-----------------|
| Loan-level fields | ~50-100 typical | 200-400+ depending on channel |
| Disclosure frequency | Quarterly or ad-hoc | Monthly, sometimes real-time |
| Data quality standards | Voluntary, market-driven | Regulatory mandates with penalties |
| Standardization | Minimal (MISMO emerging) | MISMO, ULDD, UCDP, Reg AB-II XML |
| Audit trail | Limited | Complete audit trail required |
| Fair lending data | HMDA basics | Expanded HMDA + pricing data |
| Risk retention tracking | Not applicable | Required with ongoing reporting |
| Servicing data | Investor reporting only | Regulatory + investor + consumer |

**Key Data Pipelines Created by Dodd-Frank:**

1. **QM/ATR determination pipeline** — Calculates QM eligibility from origination data, APOR lookups, and points-and-fees aggregation
2. **HMDA LAR pipeline** — Collects and validates 110+ fields per application for annual CFPB submission
3. **Risk retention monitoring pipeline** — Tracks retained interest fair values, compliance thresholds
4. **Servicing timeline pipeline** — Monitors regulatory deadlines for borrower contact, loss mitigation, and foreclosure
5. **TRID compliance pipeline** — Tracks fee tolerances, disclosure timing, and change-of-circumstance events

---

## Real-World Examples

### Example 1: Building a QM Determination Engine

A large mortgage originator needs a system to determine QM eligibility for every loan in real time during underwriting.

**Architecture:**
```
Loan Data (LOS) --> QM Engine --> QM Status Flag
                        |
              +---------+---------+
              |         |         |
         APOR Lookup  Fee Calc  Product Check
              |         |         |
     FFIEC Weekly   Points &   Term ≤ 30yr
      Rate Table    Fees ≤ 3%  No neg-am
                               No IO
                               No balloon
```

**Key Data Inputs:**
- Loan APR (from rate lock or pricing engine)
- APOR (weekly table from FFIEC — must be version as of rate lock date)
- All origination fees and charges (for points-and-fees test)
- Loan amount (determines points-and-fees threshold)
- Product type (fixed, ARM, term, amortization type)
- Creditor size (for small creditor QM eligibility)

**Output:** QM status (General QM, Small Creditor QM, Non-QM) stored as loan-level attribute and passed downstream to pricing, secondary marketing, and investor delivery systems.

### Example 2: Servicing Regulatory Timeline Tracker

A mortgage servicer builds a data pipeline to prevent regulatory violations on delinquent loans.

**Pipeline Design:**
- Ingest daily loan-level delinquency status from servicing platform
- Calculate days delinquent and compare against regulatory thresholds
- Generate alerts for upcoming deadlines (36-day call, 45-day letter)
- Track loss mitigation application status and completeness
- Flag dual-tracking risk (foreclosure activity + pending loss mitigation)
- Dashboard for compliance officers with drill-down to loan level

**Data Model Key Fields:**
- `last_payment_date`, `days_delinquent`, `delinquency_status`
- `first_contact_date`, `written_notice_date`
- `loss_mit_app_received_date`, `loss_mit_app_complete_date`, `loss_mit_decision_date`
- `foreclosure_referral_date`, `dual_track_flag`

### Example 3: Risk Retention Compliance Reporting

A non-agency securitizer must demonstrate ongoing compliance with 5% risk retention.

**Data Requirements:**
- Original deal structure (tranches, sizes, ratings)
- Retained interest identification (which tranches or horizontal slice)
- Monthly fair value marks on retained positions
- Pool performance data (delinquencies, losses, prepayments)
- Calculation demonstrating retained value ≥ 5% of total credit risk
- Documentation of retention form elected (vertical, horizontal, L-shaped)

---

## Common Interview Questions & Answers

### Q1: What is the difference between QM and QRM, and why does it matter for securitization?

**A:** QM (Qualified Mortgage) is defined under the ATR rule and provides lenders with legal protection against borrower lawsuits claiming the lender did not verify ability to repay. QRM (Qualified Residential Mortgage) is defined under the risk retention rule and determines which loans are exempt from the 5% risk retention requirement when securitized.

In the final rule, regulators aligned QRM with QM (QRM = QM), meaning any loan that qualifies as a QM is also exempt from risk retention. This matters for securitization because it determines whether a securitizer must retain economic exposure to the deal. For data engineers, both QM and QRM status must be tracked as loan-level attributes because they affect pricing, investor eligibility, and regulatory reporting.

### Q2: How did Dodd-Frank change the data requirements for mortgage origination systems?

**A:** Dodd-Frank dramatically expanded data requirements in several ways. The ATR rule requires verification and documentation of eight specific underwriting factors, meaning origination systems must capture and store income, employment, DTI, credit history, and other fields with supporting documentation. TRID replaced the GFE and HUD-1 with the Loan Estimate and Closing Disclosure, changing the fee taxonomy and adding tolerance tracking requirements. HMDA modernization expanded required fields from roughly 30 to over 110, including pricing data, credit scores, DTI, property values, and additional demographic data. The points-and-fees calculation for QM requires aggregating fees across multiple categories with specific inclusion and exclusion rules. All of these changes required significant data model expansion, new validation rules, and new ETL pipelines.

### Q3: Explain the risk retention rule and its exemptions. How does this affect secondary market data pipelines?

**A:** The risk retention rule requires securitizers to retain at least 5% of the credit risk in assets they securitize. This can be held vertically (5% of each tranche), horizontally (first-loss position worth 5%), in an L-shape (combination), or as a representative sample. Key exemptions include the QRM exemption (loans meeting QM standards), the GSE exemption (Fannie/Freddie while in conservatorship), and the federal agency exemption (Ginnie Mae securities).

For data pipelines, this means: (1) loan-level QRM eligibility must be calculated before securitization to determine if retention is required; (2) deal structuring systems must model different retention forms; (3) ongoing monitoring pipelines must track the fair value of retained interests; (4) compliance reporting must demonstrate the retained amount meets or exceeds 5%; and (5) exemption documentation must be maintained with supporting data.

### Q4: What is the Volcker Rule and how does it affect MBS trading and data systems?

**A:** The Volcker Rule prohibits banking entities from proprietary trading and limits their investments in covered funds. For MBS, this means banks can only hold inventory for market-making purposes (near-term customer demand), not for speculative profit. Trading desks must track and report metrics proving their activity is customer-driven, including inventory turnover, customer-facing trade ratios, and risk limits. Data systems must classify positions as market-making vs. proprietary, flag covered fund investments, and generate compliance metrics. The 2020 amendments clarified that loan securitizations are generally exempt from the covered fund definition, but the rule still impacts how banks hold and trade non-agency MBS positions.

### Q5: How do the CFPB servicing rules impact data architecture for loan servicers?

**A:** The CFPB servicing rules require servicers to track specific regulatory timelines and borrower interactions at the loan level. This impacts data architecture by requiring: real-time delinquency calculations with regulatory threshold monitoring (36-day and 45-day deadlines); loss mitigation application tracking with completeness status and decision timelines; dual-tracking prevention logic that integrates loss mitigation and foreclosure workflow data; periodic statement generation requiring accurate payment waterfall breakdowns; force-placed insurance tracking with notice dates and cancellation deadlines; and error resolution tracking with acknowledgment and resolution dates. The architecture typically requires event-driven pipelines that trigger alerts and workflow actions based on date calculations, with a comprehensive audit trail for regulatory examination.

### Q6: What is HPML classification and why is it important in secondary market data?

**A:** A Higher-Priced Mortgage Loan (HPML) is defined as a loan with an APR exceeding the Average Prime Offer Rate (APOR) by 1.5 percentage points for first-lien loans or 3.5 percentage points for subordinate-lien loans. HPML classification triggers additional requirements including mandatory escrow accounts for at least five years and a requirement for an interior appraisal. In secondary market data, HPML status is a critical flag because it affects loan eligibility for certain investor programs, influences pricing and risk assessment, and must be accurately calculated using the APOR as of the rate lock date. Data engineers must maintain a current APOR lookup table (published weekly by the FFIEC) and build comparison logic into origination and secondary marketing pipelines.

---

## Tips

1. **Know the QM evolution:** The QM rule has changed significantly — from the original DTI-based definition, to the GSE Patch, to the 2021 price-based General QM. Be prepared to discuss why the rule shifted from a DTI cap (43%) to a price-based threshold (APR vs. APOR).

2. **Understand the APOR lookup:** Many Dodd-Frank calculations depend on APOR (Average Prime Offer Rate). Know that it is published weekly by the FFIEC, varies by loan type (fixed vs. ARM) and term, and must be matched to the rate lock date — not the application or closing date.

3. **Connect regulation to data pipelines:** Interviewers want to see that you can translate regulatory requirements into data engineering work. For every rule, think about what data fields are needed, what calculations must be performed, what systems are affected, and what reporting is required.

4. **Risk retention is about alignment of incentives:** The policy rationale is that if securitizers must keep "skin in the game," they will be more careful about loan quality. Know the exemptions (QRM, GSE, Ginnie Mae) because they determine which securitizations actually require retention.

5. **TRID tolerance tracking is a common data engineering challenge:** The three tolerance buckets (zero tolerance, 10% cumulative tolerance, and unlimited) require comparing Loan Estimate fees to Closing Disclosure fees, accounting for valid changes of circumstance. This is a frequent source of data quality issues.

6. **Dual tracking is a high-risk compliance area:** The prohibition on simultaneously pursuing foreclosure while evaluating a loss mitigation application requires tight data integration. This is a common topic in servicer data engineering interviews because the consequences of violation are severe (CFPB enforcement actions, borrower lawsuits).

7. **Be aware of regulatory rollbacks:** Some Dodd-Frank provisions have been modified by subsequent legislation (e.g., the Economic Growth, Regulatory Relief, and Consumer Protection Act of 2018 raised the SIFI threshold from $50B to $250B). Stay current on which rules are still in force.

8. **Data lineage and audit trails matter:** Dodd-Frank compliance often requires demonstrating how a regulatory determination was made. Data engineers should be prepared to discuss how they implement lineage tracking, versioning of reference data (like APOR tables), and reproducible calculations.
