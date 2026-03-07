# Black Knight / ICE Mortgage Technology

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. Black Knight (Now Part of ICE)

Black Knight Financial Services was acquired by Intercontinental Exchange (ICE) in September 2023, creating a combined entity spanning mortgage technology, data, and analytics. The legacy Black Knight products continue under the ICE umbrella.

**Key Black Knight / ICE Divisions:**

- **ICE Mortgage Technology:** Encompasses origination platforms (Encompass), secondary market tools (Optimal Blue), servicing systems (MSP), and data/analytics (McDash, Black Knight HPI).
- **ICE Data Services:** Broader data and connectivity offerings including pricing, reference data, and analytics across fixed income, equities, and derivatives.

### 2. McDash Loan-Level Data

McDash is Black Knight's (now ICE's) premier loan-level mortgage performance database, considered alongside CoreLogic LP as one of the two major sources of US mortgage data.

**Key Characteristics:**

- **Coverage:** Approximately 70%+ of the US first-lien mortgage market by loan count. Data is sourced from mortgage servicers who use Black Knight's MSP platform and from voluntary data contributors.
- **Content:** Loan-level attributes and monthly performance data similar to CoreLogic LP but with some unique fields.

**Core Data Fields:**

| Category | Fields |
|---|---|
| Loan | Loan amount, note rate, loan type (FRM/ARM), term, origination date, purpose (purchase/refi/cash-out), channel (retail/wholesale/correspondent) |
| Property | Property type, state, ZIP, FIPS county, occupancy type, number of units |
| Borrower | FICO at origination, FICO updated, DTI, documentation type |
| Valuation | Appraised value, LTV at origination, CLTV at origination |
| Performance | Current UPB, payment status (current/30/60/90/FC/REO/paid-off), modification flag, forbearance flag, next payment due date |
| Servicing | Servicer name, investor type (GSE, Ginnie, private, portfolio), pool number |

**McDash vs. CoreLogic LP:**

| Dimension | McDash | CoreLogic LP |
|---|---|---|
| Primary Source | Servicer-reported (via MSP) | Trustee reports + servicer data |
| Coverage Focus | Broader market (portfolio + securitized) | Securitized loans (LP Securities) + servicing |
| Securitization Detail | Limited deal/tranche linkage | Strong deal/tranche linkage |
| Servicer Bias | Skewed toward MSP users (large servicers) | Broader servicer representation |
| Timeliness | Monthly, ~30-45 day lag | Monthly, ~30-60 day lag |

**Data Engineering Considerations:** McDash data is delivered as monthly snapshots via SFTP in fixed-width or delimited flat files. The data dictionary specifies field positions, lengths, and valid values. A typical monthly file contains 50-60 million loan records. Building a historical database requires appending monthly snapshots and implementing change-data-capture logic to track loan-level transitions.

### 3. MSP (Mortgage Servicing Platform)

MSP is Black Knight's flagship loan servicing system used by many of the largest US mortgage servicers (including major banks and non-bank servicers).

**What MSP Does:**

- **Payment Processing:** Records and applies borrower monthly payments, handles escrow disbursements (taxes, insurance), manages late fees and penalties.
- **Investor Reporting:** Generates remittance reports for investors (Fannie Mae, Freddie Mac, Ginnie Mae, private-label trusts). Calculates and reports scheduled and unscheduled principal, interest, and curtailments.
- **Default Management:** Tracks delinquent loans through the default lifecycle: early-stage delinquency, loss mitigation (modifications, forbearance, repayment plans), foreclosure, and REO disposition.
- **Regulatory Compliance:** Produces required regulatory reports (HMDA, CFPB servicing rules, state-specific reporting).
- **Escrow Administration:** Manages escrow accounts for property taxes and insurance, including annual escrow analysis.

**Why Data Engineers Care About MSP:**

- McDash data originates from MSP. Understanding MSP's data model helps interpret field definitions and data quality patterns.
- MSP data exports (for internal analytics or regulatory reporting) follow specific file layouts. Data engineers often build pipelines to ingest MSP extracts into analytical databases.
- MSP uses mainframe-based architecture (COBOL/VSAM on IBM z/OS). Data extraction may involve batch file generation from the mainframe, which imposes constraints on file formats and delivery schedules.
- Servicer transitions (when servicing rights transfer between companies) create data continuity challenges -- a loan's history may start in one servicer's MSP instance and continue in another's, with potential field mapping differences.

### 4. Encompass and Empower (Origination Platforms)

**Encompass (formerly Ellie Mae, now ICE Mortgage Technology):**

- The dominant loan origination system (LOS) in the US market, used by thousands of mortgage lenders.
- Manages the entire origination workflow: application intake, credit pull, automated underwriting (DU/LP), disclosure generation, document management, closing, and delivery to secondary market.
- Produces a rich dataset of origination-time loan attributes: full borrower profile, property details, income verification, asset verification, credit scores, appraisal data, and pricing details.

**Empower (legacy Black Knight LOS):**

- Black Knight's origination platform, used by large bank originators.
- Similar functionality to Encompass but different data model and integration patterns.
- Following the ICE acquisition, the long-term product strategy may favor Encompass, but Empower remains in production at many institutions.

**Data Engineering Relevance:**

- Origination data from Encompass/Empower feeds downstream systems: servicing (MSP), secondary market delivery (to GSEs), compliance reporting (HMDA), and internal analytics.
- Data engineers build ETL pipelines from the LOS to data warehouses, standardizing field names and codes across different LOS platforms when a firm uses both.
- Encompass data is available via the Encompass Partner Connect API or batch file exports. The API uses REST with OAuth 2.0 authentication.

### 5. ICE Data Services

ICE Data Services provides pricing, reference data, and analytics across asset classes.

**MBS-Relevant Offerings:**

- **End-of-Day Pricing:** Evaluated prices for agency and non-agency MBS, CMOs, and ABS. Serves as an alternative or complement to Bloomberg BVAL pricing.
- **Reference Data:** Security master data for MBS (CUSIP, deal name, tranche, collateral attributes, factor).
- **Analytics:** Prepayment and credit models, OAS analytics, scenario analysis. Competes with Bloomberg BMA and Intex for structured product analytics.
- **Indices:** ICE BofA indices (formerly Merrill Lynch indices) are widely used fixed-income benchmarks. The ICE BofA US Mortgage-Backed Securities Index is a key MBS benchmark.

**Data Delivery:** Via SFTP bulk files, APIs, or direct connectivity. Data engineers integrate ICE pricing and reference data alongside Bloomberg data, often using ICE as a secondary pricing source for validation or gap-filling.

### 6. Black Knight HPI (Home Price Index)

Black Knight produces its own home price index based on repeat-sales methodology using data from the McDash servicing database and public records.

**Comparison with CoreLogic HPI:**

| Feature | Black Knight HPI | CoreLogic HPI |
|---|---|---|
| Data Source | McDash + public records | CoreLogic property data + MLS |
| Methodology | Repeat-sales, seasonally adjusted | Repeat-sales, multiple tiers |
| Geographic Granularity | National, state, CBSA, ZIP | National, state, CBSA, county, ZIP |
| Distressed Adjustment | Provides distressed and non-distressed | Provides with/without distressed |
| Update Frequency | Monthly | Monthly |

**Use Case:** Black Knight HPI is used similarly to CoreLogic HPI for updating property values in loan portfolios. Some firms use both indices and compare results as a cross-check.

### 7. Optimal Blue

Optimal Blue (acquired by Black Knight in 2020, now part of ICE) is the leading product and pricing engine (PPE) for the mortgage industry.

**What It Does:**

- **Rate Lock Pricing:** Provides real-time mortgage rate pricing from hundreds of investors (GSEs, aggregators, private investors). Lenders use it to price and lock loans.
- **Secondary Market Analytics:** Tracks rate lock volume, market share, and pricing trends across the industry.
- **Mortgage Market Indices:** The Optimal Blue Mortgage Market Indices (OBMMI) provide daily average rate data by product type (30yr fixed, 15yr fixed, ARM), based on actual lock data rather than survey data (unlike Freddie Mac's PMMS).

**Data Engineering Relevance:**

- Optimal Blue data provides a leading indicator of mortgage origination volume and rate trends (locks precede closings by 30-60 days).
- Data engineers may integrate Optimal Blue lock data into analytics platforms for volume forecasting and competitive analysis.
- The lock-level data is granular: rate, points, LTV, FICO, loan amount, property type, state, investor, and lock date.

### 8. LOS Data and Servicing System Data Integration

One of the most complex data engineering challenges in mortgage is integrating origination (LOS) and servicing system data.

**Key Challenges:**

- **Identifier Mismatch:** The LOS assigns one loan number at origination. When the loan boards onto the servicing system (MSP), it receives a new servicing loan number. Mapping between the two requires a crosswalk table or intermediate identifier.
- **Field Semantic Differences:** The same concept may be stored differently. For example, "loan purpose" may be coded as "Purchase/Refi/CashOut" in the LOS and "P/R/C" in MSP, or may use different numeric codes.
- **Timing Gaps:** There is a gap between loan closing (in the LOS) and loan boarding (in the servicing system), during which the loan's data exists in neither system's production tables.
- **Data Completeness:** The LOS has rich origination data (full borrower financials, appraisal details) that may not transfer fully to the servicing system, which focuses on ongoing payment performance.
- **Multiple Servicers:** If servicing rights are sold, the loan's data migrates from one MSP instance to another. Historical data may not transfer completely, creating gaps in the performance time series.

**Integration Architecture:**

```
Encompass (LOS)                    MSP (Servicing)
    |                                  |
    v                                  v
Origination Data Lake            Servicing Data Lake
    |                                  |
    +----------> Unified Loan ID <-----+
                      |
                      v
              Enterprise Mortgage
               Data Warehouse
                      |
        +-------------+-------------+
        |             |             |
    Analytics    Regulatory      Risk
    Platform     Reporting      Models
```

### 9. Data Integration Challenges Specific to Black Knight / ICE

**Mainframe Legacy:**

- MSP runs on IBM mainframe (z/OS). Data extracts are generated as EBCDIC-encoded fixed-width files that must be converted to ASCII/UTF-8 for modern data platforms.
- Packed decimal fields, COBOL-style sign conventions, and implicit decimal points require careful parsing logic.

**Vendor Lock-In and Licensing:**

- Access to McDash data requires a commercial license, and usage is governed by strict terms. Data engineers must ensure that derived datasets and reports comply with redistribution restrictions.
- MSP data extracts may have licensing limitations on what fields can be stored in downstream analytics systems.

**Data Reconciliation:**

- Because McDash data comes from servicers and may overlap with CoreLogic LP (the same loan can appear in both), reconciling across vendors requires careful deduplication logic based on loan characteristics (original balance, origination date, rate, property ZIP) rather than common identifiers.

**Migration and Consolidation:**

- As ICE integrates Black Knight's products, data formats, APIs, and delivery mechanisms are evolving. Data engineers must plan for schema changes and potential product consolidation.

---

## Real-World Examples

### Example 1: Building a National Mortgage Performance Database

A government regulator needs to monitor mortgage performance across the US market:

- Licenses both McDash and CoreLogic LP to maximize coverage.
- The data engineering team builds a deduplication pipeline that matches loans across the two sources using a composite key (origination date, original balance, rate, property state, ZIP, loan type).
- Matched loans are consolidated into a single record; unmatched loans from each source are retained.
- The combined database covers approximately 85-90% of the US first-lien mortgage market.
- Monthly pipeline ingests both sources, applies the matching logic, and produces national and state-level delinquency and foreclosure metrics.

### Example 2: Servicer Data Migration

A large bank acquires the servicing rights for 200,000 loans from a non-bank servicer:

- The selling servicer exports loan data from their MSP instance in the Black Knight standard transfer format.
- The data engineering team at the acquiring bank maps the transfer file fields to their own MSP instance's data model.
- Historical payment records, escrow balances, modification terms, and correspondence logs must all be migrated.
- A reconciliation process compares pre- and post-migration balances, rates, and statuses to ensure data integrity.
- Post-migration, the data engineer updates the internal data warehouse to redirect loan lookups to the new servicing system.

### Example 3: Rate Lock Volume Analytics

A mortgage originator wants to understand market trends and competitive positioning:

- Integrates Optimal Blue lock data with internal Encompass origination data.
- Builds a daily pipeline that compares the firm's lock volume, average rate, and product mix against Optimal Blue's market-wide benchmarks.
- Creates dashboards showing market share by product type, geography, and channel.
- Uses lock data as a leading indicator to forecast funded loan volume 45-60 days forward.

---

## Common Interview Questions and Answers

### Q1: What is the McDash database and how does it differ from CoreLogic LoanPerformance?

**Answer:** McDash is Black Knight's (now ICE's) loan-level mortgage performance database covering approximately 70% of the US first-lien mortgage market. Data is primarily sourced from servicers using Black Knight's MSP servicing platform. It includes both securitized and portfolio loans, providing broad market coverage. CoreLogic LP, by contrast, has stronger coverage of the securitized market (especially non-agency RMBS) with explicit linkage to deal and tranche structures. The key differences are: McDash has broader overall market coverage (including portfolio loans) but limited securitization detail, while CoreLogic LP excels at securitization-level analysis with deal/tranche mapping. McDash's servicer coverage is skewed toward large MSP users, while CoreLogic aggregates from a wider range of servicers and trustee reports. In practice, many sophisticated analytics shops license both datasets and use deduplication logic to create the most comprehensive view of the market.

### Q2: What are the data engineering challenges of working with MSP data?

**Answer:** MSP presents several unique challenges. First, it runs on IBM mainframe infrastructure, so data extracts are often EBCDIC-encoded fixed-width files with COBOL data types (packed decimal, signed fields with overpunch conventions). Parsing these requires specialized logic or ETL tools with mainframe format support. Second, MSP's data model is designed for operational servicing, not analytics -- the schema is highly normalized with hundreds of tables and cryptic field names. Understanding which tables and fields map to analytical concepts requires deep domain knowledge or thorough documentation review. Third, extraction timing matters: MSP runs batch cycles (typically nightly), and data extracts taken mid-cycle may contain inconsistent states. Fourth, servicer transitions create data continuity issues -- when loans transfer between servicers, historical data may not migrate completely, creating gaps in performance time series. Fifth, the volume is significant: a large servicer may have 5-10 million active loans, each with monthly performance records spanning years.

### Q3: How would you integrate origination data from Encompass with servicing data from MSP?

**Answer:** The integration requires solving several problems. First, establish a common loan identifier. Encompass assigns a loan number at origination, and MSP assigns a different servicing number at boarding. I would create a crosswalk table populated during the loan boarding process that maps the Encompass loan ID to the MSP loan number. For historical loans where no crosswalk exists, fuzzy matching on loan attributes (borrower name, property address, original balance, origination date) can establish the link. Second, standardize field semantics -- create a canonical data model with consistent field names, codes, and definitions, and build mapping layers from both source systems to this canonical model. Third, handle the timing gap between closing and boarding by establishing a "warehouse" or interim state in the data model for loans that have closed but not yet boarded. Fourth, preserve origination detail -- many origination-time fields (full income documentation, appraisal details, AUS findings) are not carried into MSP, so the origination data lake must be maintained as a permanent store and joined to servicing data via the crosswalk.

### Q4: What is Optimal Blue and why is its data valuable for mortgage analytics?

**Answer:** Optimal Blue is ICE's product and pricing engine used by mortgage lenders to price and lock loans with secondary market investors. Its data is valuable because it captures actual rate lock transactions in real-time, providing the most current and granular view of mortgage market pricing and volume. Unlike survey-based rate data (e.g., Freddie Mac PMMS which surveys lenders weekly), Optimal Blue data reflects actual locked rates with full loan-level detail (rate, points, LTV, FICO, product type, state, investor). This makes it useful for: (1) volume forecasting -- since locks precede closings by 30-60 days, lock volume is a leading indicator of origination volume; (2) competitive analysis -- comparing a firm's pricing and lock volume against market benchmarks; (3) pricing optimization -- analyzing how rate and fee changes affect lock capture rates; and (4) market research -- tracking real-time shifts in product mix, credit quality trends, and geographic patterns in origination activity.

### Q5: Describe the challenges of deduplicating loans across McDash and CoreLogic LP.

**Answer:** The fundamental challenge is that there is no common loan identifier across the two databases -- both use proprietary anonymized IDs. Deduplication requires probabilistic matching on a composite key of loan attributes. A typical matching strategy uses: original loan amount (exact or within a small tolerance), origination date (exact or within one month), note rate (exact or within 12.5 bps for rounding differences), property state and ZIP code, loan type (fixed/ARM), and loan term. Challenges include: (1) rounding differences in dollar amounts between the two sources; (2) origination date vs. closing date vs. first payment date being used inconsistently; (3) rate changes from modifications creating confusion about original rate; (4) both datasets anonymizing geographic data at different levels of granularity; (5) ARM loans where the rate changes monthly, making rate matching time-dependent. The matching is typically done as a batch process with multiple passes -- first a strict match on all fields, then progressively relaxed criteria for unmatched loans, with manual review of ambiguous matches. Match rates typically reach 80-90% for overlapping populations.

### Q6: How has the ICE acquisition of Black Knight affected the mortgage data landscape?

**Answer:** The acquisition, completed in September 2023, consolidated major mortgage technology and data assets under one entity. ICE now owns the dominant servicing platform (MSP), the leading origination system (Encompass, from the prior Ellie Mae acquisition), the top pricing engine (Optimal Blue), and the McDash data asset, alongside ICE's existing data services and exchange infrastructure. For data engineers, this means: (1) potential for better data integration across origination, servicing, and secondary market workflows as ICE rationalizes its platforms; (2) risk of vendor concentration -- many firms now depend on ICE for multiple critical systems; (3) evolving APIs and data formats as ICE modernizes legacy Black Knight infrastructure; (4) new data products that combine previously siloed datasets (e.g., linking Encompass origination data directly to MSP servicing performance); and (5) pricing changes as ICE leverages its market position. Data engineers should monitor ICE's product roadmap closely and maintain flexible data architectures that can adapt to format and delivery changes.

---

## Tips

1. **Know both vendors.** In interviews, demonstrating familiarity with both CoreLogic and Black Knight/ICE (and their relative strengths) shows depth. Be able to articulate when you would use McDash vs. CoreLogic LP and why.

2. **Understand the servicer's perspective.** Much of Black Knight's data originates from servicer operations. Understanding the servicing lifecycle (boarding, payment processing, escrow, default management, payoff) helps you interpret data quality patterns and field definitions.

3. **Be comfortable with legacy formats.** Mainframe data formats (EBCDIC, packed decimal, fixed-width) still appear in mortgage data engineering. Be able to explain how you have handled or would handle format conversion in a pipeline.

4. **Emphasize reconciliation skills.** Cross-vendor data reconciliation (McDash vs. CoreLogic, internal vs. vendor data) is a highly valued skill. Be prepared to describe matching strategies, tolerance thresholds, and how you handle unresolved discrepancies.

5. **Track the ICE integration.** The Black Knight-ICE merger is reshaping the mortgage technology landscape. Staying current on product changes, API updates, and data format migrations demonstrates market awareness.

6. **Understand the origination-to-servicing data flow.** The ability to trace a loan's data from application (Encompass) through closing, boarding (MSP), securitization, and ongoing servicing performance is a distinguishing skill for a senior mortgage data engineer.

7. **Know the MSP ecosystem.** MSP does not operate in isolation. It integrates with LoanSphere (Black Knight's suite of default management, document management, and compliance tools). Understanding these adjacent systems helps explain data lineage.

8. **Be prepared to discuss data licensing.** Interviewers at firms that license mortgage data may ask about vendor management, data governance, and compliance with redistribution restrictions. Understand that McDash and CoreLogic data have strict usage terms that affect how derived datasets can be shared or published.
