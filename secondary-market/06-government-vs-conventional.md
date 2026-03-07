# Government vs Conventional Loans

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Overview

US residential mortgage loans fall into two broad categories based on whether they carry a government insurance or guaranty:

- **Government loans**: Insured or guaranteed by a federal agency — FHA (Federal Housing Administration), VA (Department of Veterans Affairs), or USDA (US Department of Agriculture Rural Development).
- **Conventional loans**: Not insured or guaranteed by the government. They may be conforming (GSE-eligible) or non-conforming (jumbo, non-QM).

This distinction is foundational to secondary market data engineering because government and conventional loans follow entirely different securitization paths, have different data requirements, and exhibit different performance characteristics.

---

### FHA Loans (Federal Housing Administration)

FHA loans are insured by the FHA, a division of the Department of Housing and Urban Development (HUD). FHA insurance protects the **lender** (and ultimately the investor) against borrower default.

#### Key Characteristics
- **Down payment**: Minimum 3.5% (96.5% LTV) with a credit score of 580+; 10% down required for scores 500-579.
- **Credit score**: Minimum 500 (though most lenders overlay a 580 or 620 minimum).
- **DTI**: Up to 57% for AUS-approved loans (generous compared to conventional).
- **Property**: Must be owner-occupied primary residence (no investment properties or second homes).
- **Loan limits**: Set by FHA per county, based on a percentage of the conforming limit. Floor is 65% of conforming ($524,225 for 2025); ceiling is 150% of conforming ($1,209,750 for 2025, same as high-cost conforming).
- **Assumable**: FHA loans are assumable with lender qualification of the new borrower.

#### Mortgage Insurance Premium (MIP)
FHA loans require both upfront and annual mortgage insurance:

- **UFMIP (Upfront Mortgage Insurance Premium)**: 1.75% of the base loan amount, typically financed into the loan.
- **Annual MIP**: Ranges from 0.15% to 0.75% of the outstanding balance, paid monthly. For the most common scenario (30-year term, LTV > 95%, loan amount <= $726,200), the annual MIP is **0.55%**.
- **Duration**: For loans with original LTV > 90%, MIP is required for the **life of the loan** (cannot be canceled). For LTV <= 90%, MIP drops off after 11 years.
- This lifetime MIP rule (implemented in 2013) is a key driver of FHA-to-conventional refinance activity.

#### FHA Streamline Refinance
- Allows FHA borrowers to refinance with **reduced documentation** — no appraisal, no income verification, no credit qualifying (for "non-credit qualifying" streamlines).
- Requires a **net tangible benefit** (rate reduction of at least 0.5% or conversion from ARM to fixed).
- Must be at least 210 days from closing and 6 payments made on the existing FHA loan.
- Data implication: Streamline refinances have minimal data because so many standard fields are waived. Pipelines must handle nullable/optional fields that are normally required.

#### FHA Data Sources
- **FHA Connection (FHAC)**: Portal for case number assignment, AUS (TOTAL Scorecard), endorsement, and claims.
- **Neighborhood Watch**: FHA's early warning system for lender/appraiser performance.
- **FHA case number**: Unique identifier assigned at application; tracked through the loan's entire lifecycle.
- **Endorsement**: FHA's formal acceptance of insurance on a closed loan. Post-closing, the loan must be "endorsed" — submission of loan data and documents to FHA for insurance activation. Failure to endorse leaves the lender uninsured.

---

### VA Loans (Department of Veterans Affairs)

VA loans are **guaranteed** (not insured — a distinction) by the VA for eligible veterans, active-duty service members, and surviving spouses.

#### Key Characteristics
- **Down payment**: **0% down** — VA is the most prominent zero-down-payment program.
- **No monthly mortgage insurance**: Unlike FHA and conventional (with PMI), VA loans have no monthly MI premium.
- **Credit score**: VA does not set a minimum FICO; individual lenders typically require 580-620.
- **DTI**: Guideline maximum of 41%, but the **residual income test** is the more important qualification — VA requires sufficient monthly income remaining after all obligations.
- **Property**: Primary residence only.
- **Loan limits**: For veterans with full entitlement, there is **no loan limit** (since the Blue Water Navy Act of 2019). For veterans with reduced entitlement (e.g., existing VA loan), county-level limits still apply.
- **Assumable**: VA loans are assumable (one of their unique features).
- **VA appraisal**: Conducted by a VA-assigned appraiser; the **Minimum Property Requirements (MPRs)** are more stringent than conventional appraisal standards.

#### VA Funding Fee
Instead of monthly MI, VA loans require a **one-time funding fee**:
- First use, 0% down: **2.15%** of the loan amount.
- Subsequent use, 0% down: **3.30%**.
- The fee decreases with larger down payments (e.g., 1.25% with 10%+ down for first use).
- **Exempt borrowers**: Veterans with service-connected disabilities, Purple Heart recipients, and surviving spouses are exempt from the funding fee.
- The funding fee can be financed into the loan amount.

#### VA IRRRL (Interest Rate Reduction Refinance Loan)
- Also called a **VA Streamline Refinance**.
- Similar to FHA streamline — minimal documentation, no appraisal required.
- Must result in a lower interest rate (exception: ARM-to-fixed conversion).
- Must be at least 210 days from closing and 6 payments made.
- **Churning protections**: VA has implemented recoupment requirements (the borrower must recoup closing costs within 36 months) and seasoning requirements to prevent predatory serial refinancing.

#### VA Data Sources
- **VA WebLGY**: Portal for Certificate of Eligibility (COE), loan tracking, and guaranty management.
- **VA loan number**: Assigned via WebLGY; tracks the loan through guaranty, servicing, and potential claim.
- **Entitlement tracking**: The veteran's remaining entitlement must be calculated — this requires understanding of basic entitlement ($36,000) and bonus entitlement, and how prior VA loans affect available guaranty.

---

### USDA Loans (US Department of Agriculture)

USDA Rural Development loans serve borrowers in **rural and suburban areas** with low-to-moderate income.

#### Key Characteristics
- **Down payment**: **0% down** (like VA).
- **Income limits**: Household income cannot exceed 115% of the area median income (AMI). This is a unique restriction — most programs limit DTI but not absolute income.
- **Geographic eligibility**: Property must be in a USDA-designated rural area (the USDA eligibility map determines this — surprisingly, many suburban areas qualify).
- **Guarantee fee**: 1.0% upfront (financed) + 0.35% annual.
- **Credit score**: Minimum 640 for GUS (Guaranteed Underwriting System) approval.
- **Property**: Primary residence only, single-family.

#### USDA Programs
- **Section 502 Guaranteed**: The main program — loans originated by approved lenders and guaranteed by USDA (similar to FHA/VA model). This is the one relevant to the secondary market.
- **Section 502 Direct**: USDA lends directly to very-low-income borrowers. Not relevant to secondary market.

---

### Conventional Loans

Conventional loans are not backed by a government agency. They may be **conforming** (meeting GSE guidelines) or **non-conforming** (jumbo, non-QM).

#### Key Characteristics
- **Down payment**: As low as 3% (Fannie Mae HomeReady, Freddie Mac Home Possible) for qualifying borrowers; standard minimum is 5%.
- **Credit score**: Minimum 620 for GSE eligibility; lender overlays may require 640-680.
- **DTI**: Up to 50% via AUS.
- **Property types**: Primary, second home, and investment property all eligible.
- **Loan limits**: Subject to FHFA conforming limits (for GSE-eligible loans).

#### Private Mortgage Insurance (PMI)
- Required when LTV exceeds **80%**.
- Provided by private MI companies: Arch MI, Essent, MGIC, National MI, Enact (formerly Genworth), Radian.
- **Monthly PMI**: Most common; added to the monthly payment.
- **Single-premium PMI**: Paid upfront (by borrower or lender) in a lump sum.
- **Lender-paid PMI (LPMI)**: Lender pays the premium and charges a higher interest rate.
- **Cancellation**: Under the Homeowners Protection Act (HPA), borrower-paid PMI must be automatically terminated when LTV reaches **78%** of original value (based on amortization schedule). Borrowers can request cancellation at **80%** LTV.
- PMI cancellation is a key data tracking requirement — the servicing system must monitor LTV progression and trigger cancellation at the appropriate threshold.

---

### Ginnie Mae Securitization

**Government loans (FHA, VA, USDA) are securitized through Ginnie Mae**, not Fannie Mae or Freddie Mac.

Key differences from GSE securitization:

| Attribute | Ginnie Mae (GNMA) | Fannie Mae / Freddie Mac |
|---|---|---|
| Loan types | FHA, VA, USDA only | Conventional conforming only |
| Business model | **Guarantor only** — does not buy loans | Purchase loans from sellers |
| Issuer role | The lender/servicer is the **issuer** of the MBS | GSE is the issuer |
| Risk | Full faith and credit of the US government | Implied government support (FHFA conservatorship) |
| Servicing | Issuer must be an approved Ginnie Mae issuer and retain servicing | Servicer can be separated from seller |
| Pool types | Ginnie Mae I (single issuer, 50 bps servicing minimum) and Ginnie Mae II (multiple issuers, 25 bps minimum, more common) | UMBS (single security via CSP) |
| Programs | HMBS (Home Equity Conversion Mortgages / reverse mortgages) also securitized through Ginnie Mae | N/A |

Ginnie Mae issuers face unique operational and financial requirements:
- Must maintain **minimum net worth** (based on portfolio size).
- Must advance **principal and interest** to investors even when borrowers are delinquent (this is a significant liquidity burden, especially during forbearance events like COVID-19).
- Must report monthly to Ginnie Mae via the **Reporting and Feedback (RFS) system**.

Data implication: Ginnie Mae data flows differ significantly from GSE flows. The issuer is responsible for pool formation, monthly reporting, and investor pass-through calculations. Data engineers at Ginnie Mae issuers must build pipelines for pool certification, monthly Factor Data (pool-level) and Loan-Level Disclosure (LLD) reporting, and reconciliation with Ginnie Mae's systems.

---

### Default and Prepayment Comparison

Understanding how government and conventional loans perform differently is critical for secondary market analytics:

#### Default Rates
- **FHA loans** have the highest serious delinquency rates (historically 2-5x conventional rates) due to lower credit score and higher LTV borrowers.
- **VA loans** perform better than FHA but worse than conventional, with strong servicer intervention and VA's partial claim loss mitigation.
- **Conventional loans** have the lowest default rates, particularly those with high credit scores and low LTVs.

#### Prepayment Behavior
- **FHA loans** prepay faster than conventional because: (1) FHA borrowers tend to refinance into conventional once they build sufficient equity (to eliminate lifetime MIP); (2) FHA streamline refinances are easy to execute when rates drop.
- **VA loans** also prepay quickly due to the IRRRL program's low barriers and strong veteran outreach by lenders.
- **Conventional loans** prepay at rates driven primarily by interest rate movements, with high-LTV and low-balance loans prepaying slower (less refinance incentive).
- **GNMA MBS** (backed by government loans) are known for faster, more volatile prepayment speeds compared to **UMBS** (backed by conventional loans). This prepayment difference is a major factor in MBS pricing and risk management.

#### Loss Mitigation Differences
- **FHA**: Offers partial claims (a silent second lien from HUD), loan modifications (FHA-HAMP), and special forbearance. FHA also has a unique **claims process** — when a foreclosure occurs, the lender files a claim with FHA for the insured amount.
- **VA**: Offers supplemental servicing, VA partial claims (since 2024 — the VA Servicing Purchase program), and refunding (VA purchase of defaulted loans from Ginnie Mae pools). VA also assigns a **Loan Technician** to assist with workouts.
- **Conventional (GSE)**: Fannie Mae and Freddie Mac have flex modification programs, payment deferral options, and Freddie Mac's Flex Modification. No government insurance claim — losses are absorbed by MI companies (up to coverage limits) and then the GSE guarantee.

---

## Real-World Examples

### Example 1: Government Loan Endorsement Pipeline
A large FHA lender originates 3,000 FHA loans per month. After closing, each loan must be endorsed by FHA within 60 days. The data engineering team builds a pipeline that extracts closed FHA loan data from the LOS, validates all required fields against FHA's endorsement requirements (case number, borrower data, property data, MIP certification, TOTAL Scorecard findings), transforms the data into FHA Connection's required format, and submits for endorsement via the FHA Connection API. Loans that fail endorsement are flagged with specific rejection codes and routed to a remediation queue. The team tracks endorsement rates, average days to endorse, and rejection reasons on a weekly dashboard. Unendorsed loans beyond 60 days represent uninsured risk exposure.

### Example 2: Ginnie Mae Monthly Reporting
A mid-size Ginnie Mae issuer services 15,000 government loans across 200 Ginnie Mae II pools. Each month, the data engineering pipeline must: (1) Calculate the current pool factor for each pool based on loan-level activity (payments, prepayments, liquidations); (2) Generate the Pool Disclosure Data and Loan-Level Disclosure files in Ginnie Mae's required format; (3) Reconcile the calculated pass-through amounts with the servicer advance amounts (the issuer must advance P&I for delinquent loans); (4) Submit all data to Ginnie Mae's RFS system by the reporting deadline. The advance obligation means the pipeline must also feed a liquidity forecasting model — the CFO needs to know how much cash will be required to cover delinquent loan advances next month.

### Example 3: PMI Cancellation Tracking
A servicer manages 100,000 conventional loans, 40,000 of which have active PMI. The data engineering team builds an automated PMI monitoring pipeline that: (1) Tracks each loan's current LTV based on the amortization schedule (using the original appraised value); (2) Flags loans approaching the 80% threshold (borrower request eligible) and 78% threshold (automatic termination); (3) Generates borrower notification letters at the 80% threshold; (4) Automatically cancels PMI and adjusts the monthly payment at 78% LTV; (5) Handles borrower-initiated cancellation requests based on new appraisals (current market value). The pipeline must also track the HPA midpoint test — PMI must be terminated at the midpoint of the amortization schedule regardless of LTV.

---

## Common Interview Questions and Answers

### Q1: What are the key differences between FHA, VA, and conventional loans?
**A:** **FHA** loans are insured by the Federal Housing Administration, allow credit scores as low as 500, require 3.5% minimum down payment, and charge both upfront (1.75%) and annual mortgage insurance premiums — with lifetime MIP for LTV > 90%. **VA** loans are guaranteed by the Department of Veterans Affairs for eligible veterans, offer 0% down payment, charge no monthly MI (but have a funding fee of 2.15-3.30%), and use a residual income test alongside DTI. **Conventional** loans have no government backing, require PMI when LTV > 80% (which can be canceled at 78-80% LTV), typically need a 620+ credit score, and offer the most flexibility for property type and occupancy. From a data engineering perspective, each type has different data fields, different regulatory systems (FHA Connection, VA WebLGY, GSE portals), and different securitization paths (Ginnie Mae for government, Fannie/Freddie for conventional).

### Q2: Explain the Ginnie Mae securitization model and how it differs from Fannie Mae/Freddie Mac.
**A:** Ginnie Mae is a **guarantor only** — it does not buy loans. Instead, approved Ginnie Mae **issuers** (lenders/servicers) pool their own government loans (FHA, VA, USDA), form MBS, and sell those securities to investors. Ginnie Mae provides a full-faith-and-credit government guarantee on the timely payment of principal and interest. By contrast, Fannie Mae and Freddie Mac **purchase** loans from sellers and issue their own MBS. The key data difference is that with Ginnie Mae, the issuer is responsible for all pool formation, monthly reporting, and advance obligations — requiring robust data pipelines at the issuer level. With Fannie/Freddie, the GSE handles securitization after purchasing the loan, and the seller's data responsibility largely ends at delivery (aside from servicing reporting if they retain servicing).

### Q3: Why do GNMA MBS prepay faster than conventional UMBS, and why does this matter?
**A:** GNMA securities are backed by FHA and VA loans, which have structural features that drive faster prepayments: (1) FHA streamline and VA IRRRL programs allow easy refinancing with minimal documentation; (2) FHA borrowers who build equity often refinance into conventional loans to eliminate lifetime MIP; (3) Government loan borrowers tend to have more rate-sensitive profiles. This matters because faster, more volatile prepayments increase the **negative convexity** of GNMA MBS — when rates drop, prepayments spike and investors receive principal back early (reinvestment risk); when rates rise, prepayments slow. MBS traders price GNMA pools differently from UMBS, and data engineers building analytics or pricing pipelines must model government and conventional prepayment speeds separately using loan-level attributes (FICO, LTV, loan age, rate incentive, geography).

### Q4: How would you design a data model to handle both government and conventional loans in a single warehouse?
**A:** I would use a **supertype/subtype** design. The core loan fact table contains fields common to all loans: loan amount, rate, term, LTV, FICO, property type, occupancy, loan status, UPB. Subtype tables extend this for each program: an **FHA extension table** (FHA case number, UFMIP amount, annual MIP rate, endorsement status, endorsement date, TOTAL Scorecard finding), a **VA extension table** (VA loan number, funding fee amount, entitlement used, funding fee exempt flag, guaranty percentage), a **USDA extension table** (guarantee fee, income eligibility, geographic eligibility), and a **conventional extension table** (PMI company, PMI certificate number, PMI type, PMI cancellation date, LLPA amounts). The loan type field in the core table drives which extension table is populated. This avoids sparse columns in a single wide table while maintaining a unified view for cross-program analytics. A view or materialized query can flatten the structure for reporting.

### Q5: What is FHA endorsement and why is it critical from a data perspective?
**A:** FHA endorsement is the process by which FHA formally activates insurance coverage on a closed loan. Without endorsement, the lender has no FHA insurance protection if the borrower defaults. Endorsement requires submitting complete and accurate loan data to FHA Connection, including borrower information, property data, loan terms, TOTAL Scorecard findings, MIP certification, and compliance documentation. From a data perspective, endorsement is a critical post-closing milestone that must be tracked with urgency — FHA requires endorsement within 60 days of closing. An unendorsed loan is an uninsured asset on the lender's books. The data pipeline must validate all endorsement-required fields before submission, handle rejection codes from FHA, and provide visibility into the endorsement backlog. Endorsement rate and average time-to-endorse are key operational metrics.

### Q6: How does PMI cancellation work, and what data engineering challenges does it present?
**A:** Under the Homeowners Protection Act (HPA), borrower-paid PMI on conventional loans must be canceled when the loan reaches **78% LTV** based on the original value and amortization schedule (automatic termination), and borrowers can request cancellation at **80% LTV**. Additionally, PMI must be terminated at the **midpoint of the amortization schedule** regardless of LTV. Data engineering challenges include: (1) Maintaining accurate amortization schedules that account for curtailments, recasts, and modifications; (2) Tracking original property value separately from current value (borrower-requested cancellation may use current value via new appraisal or BPO); (3) Coordinating with MI companies to confirm cancellation; (4) Adjusting borrower payment amounts after cancellation; (5) Generating compliant borrower notification letters at required intervals. The pipeline must handle both the scheduled LTV calculation and ad-hoc borrower requests, each with different data requirements and approval workflows.

---

## Tips

- Know the **funding fee and MIP rates** from memory. Interviewers expect a senior candidate in this domain to know that FHA UFMIP is 1.75%, FHA annual MIP is 0.55% (most common tier), and VA funding fee is 2.15% for first use with zero down. These numbers come up constantly.
- Understand the **Ginnie Mae issuer model** deeply. Many candidates understand Fannie/Freddie but are weak on Ginnie Mae. The fact that the issuer (not Ginnie Mae) forms the pools, advances P&I, and bears operational responsibility is a key differentiator — and a significant data engineering challenge.
- The **lifetime MIP** rule for FHA loans with LTV > 90% is one of the most impactful policy decisions in mortgage. It drives a huge volume of FHA-to-conventional refinances and shapes prepayment modeling. Bring this up proactively in interviews to show depth.
- Be prepared to discuss **COVID-era impacts** on government loans. FHA and VA forbearance rates were significantly higher than conventional during 2020-2021. Ginnie Mae issuers faced massive advance obligations. The VA Servicing Purchase program and FHA partial claim enhancements were direct responses. This is recent, relevant history.
- For data engineering interviews, emphasize the **system diversity** — FHA Connection, VA WebLGY, Ginnie Mae RFS, GSE delivery systems. Each has its own data formats, APIs, and submission requirements. A senior data engineer must be comfortable integrating data from all of these sources into a unified platform.
- Understand that **government loans cannot be sold to Fannie Mae or Freddie Mac**. This is a common misconception. FHA/VA/USDA loans go to Ginnie Mae for securitization. Conventional conforming loans go to Fannie/Freddie. Getting this wrong in an interview is a red flag.
