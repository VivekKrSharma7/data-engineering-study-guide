# Intex Solutions

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Overview of Intex Solutions

**Intex Solutions** is the industry-standard provider of structured finance cash flow modeling and analytics. Virtually every institutional investor, bank, insurance company, and asset manager that holds non-agency RMBS, CMBS, ABS, CDO, or CLO positions relies on Intex for deal modeling. Intex's core value proposition is that it maintains a library of thousands of structured deals with their complete waterfall logic, enabling users to run cash flow projections under any assumption set.

For data engineers, Intex is a critical data source — the analytics output from Intex flows into position management systems, risk engines, regulatory reporting, and portfolio analytics platforms.

### Intex Products

#### INTEXcalc

**INTEXcalc** is the flagship desktop application. It provides:

- Cash flow projection for any deal/tranche in the Intex library.
- Interactive scenario analysis (change prepayment, default, severity, recovery lag assumptions and immediately see updated cash flows).
- Yield table generation (price vs. speed matrices).
- Tranche-level and collateral-level output.
- Bond math calculations (yield, spread, duration, WAL).
- Waterfall visualization.
- Collateral detail (loan-level data where available).

INTEXcalc is the primary tool for portfolio analysts and traders doing ad hoc analysis.

#### INTEXnet

**INTEXnet** is the web-based version of Intex analytics. It provides similar functionality to INTEXcalc through a browser interface, making it accessible without desktop installation. INTEXnet is often used by:

- Compliance and middle-office teams that need periodic access.
- Remote workers without VPN access to the desktop application.
- Smaller teams that do not justify a full CDI API integration.

#### CDI API (Cash Flow Data Interface)

The **CDI API** is Intex's programmatic interface for running cash flows at scale. This is the most important Intex product for data engineers. The CDI API allows:

- **Batch processing:** Submit thousands of tranche/scenario combinations programmatically.
- **Integration:** Embed Intex analytics into custom applications, databases, and data pipelines.
- **Automation:** Schedule nightly/weekly runs for portfolio analytics and regulatory reporting.
- **Language support:** Available as C/C++ libraries, .NET, Java, and Python wrappers.
- **Input:** Deal ID, tranche ID, pricing date, settlement date, prepayment/default/severity/recovery assumptions.
- **Output:** Monthly (or periodic) cash flow projections, yield/spread metrics, WAL, duration, factor.

**CDI API Architecture:**
```
[Your Application] --> [CDI API Library] --> [Intex Deal Library (local cache)]
                                         --> [Intex Data Server (updates)]
```

The CDI API reads from a locally cached copy of the deal library, which is updated periodically from Intex servers. The deal library contains the structural rules (waterfall logic) and collateral data for each deal.

#### Deal Library

The Intex **deal library** is a comprehensive database of structured finance transactions, containing:

- **RMBS:** Agency CMO, non-agency RMBS (subprime, Alt-A, prime, scratch-and-dent).
- **CMBS:** Conduit and single-asset/single-borrower deals.
- **ABS:** Auto, credit card, student loan, equipment.
- **CDO/CLO:** Cash and synthetic CDOs, broadly syndicated CLOs.
- **European/APAC deals:** Covered bonds, European RMBS.

As of recent counts, the library includes **30,000+ deals** with **300,000+ tranches**.

The library is updated as new deals are issued and as existing deal factors (principal paydowns) are reported by trustees.

### Deal ID System

Intex uses a systematic deal identification scheme:

**Deal ID format:** Typically an alphanumeric code based on the shelf name, year, and series.

| Example Deal ID | Issuer | Year | Series |
|----------------|--------|------|--------|
| FNMA 2024-001 | Fannie Mae | 2024 | 001 |
| ACE 2006-HE3 | ACE Securities | 2006 | HE3 |
| JPMCC 2019-LTV1 | JP Morgan | 2019 | LTV1 |
| WAMU 2005-AR1 | Washington Mutual | 2005 | AR1 |
| CWALT 2006-OC9 | Countrywide Alt-A | 2006 | OC9 |

**Tranche ID:** Within a deal, tranches are identified by class name (e.g., A1, A2, M1, M2, B1, CE) and sometimes by CUSIP.

**Mapping Deal IDs to CUSIPs:** Each tranche has a unique CUSIP. Intex maintains the mapping between Intex deal/tranche IDs and CUSIPs. Data engineers must build and maintain this mapping table for portfolio integration.

### Running Cash Flows

The core Intex operation is running projected cash flows for a tranche under specific collateral assumptions.

#### Collateral Assumptions

**Prepayment Assumptions:**
- **Constant CPR:** A single annualized prepayment rate (e.g., 15 CPR).
- **PSA:** A standard prepayment ramp (e.g., 150 PSA = 150% of the standard model).
- **CPR vector:** Month-by-month CPR values (e.g., `5 5 8 10 15 20 20 18 15 12 10 8`).
- **Model-based:** Use an integrated prepayment model (some Intex configurations support Andrew Davidson or other model outputs).

**Default Assumptions:**
- **Constant CDR:** Annualized conditional default rate (e.g., 3 CDR).
- **CDR vector:** Month-by-month default rates.
- **SDA (Standard Default Assumption):** Similar to PSA but for defaults — a ramp that peaks and then declines.

**Loss Severity:**
- **Constant severity:** A single loss-given-default percentage (e.g., 40%).
- **Severity vector:** Time-varying severity rates.
- Severity is applied to the defaulted balance to determine the loss amount.

**Recovery Lag:**
- The number of months between a default event and the recovery of liquidation proceeds.
- Typical values: 12-24 months (varies by state — judicial foreclosure states have longer lags).
- Affects the timing of cash flows and the present value of recoveries.

**Other Assumptions:**
- **Delinquency assumptions:** For deals with advancing provisions, delinquency timing affects cash flow distribution.
- **Interest rate curves:** For floating-rate tranches, a forward curve or flat rate assumption for the index (SOFR, formerly LIBOR).
- **Pricing speed:** The settlement date and pricing date determine accrued interest and next payment calculations.

#### Example CDI API Call (Pseudocode)

```python
import intex_cdi as cdi

# Initialize connection to deal library
session = cdi.Session(library_path="/data/intex/deallib")

# Specify deal and tranche
deal = session.get_deal("ACE 2006-HE3")
tranche = deal.get_tranche("A1")

# Set assumptions
assumptions = cdi.Assumptions(
    settle_date="2026-03-15",
    prepay_type="CPR",
    prepay_vector=[5, 5, 8, 10, 15, 20, 20, 18, 15, 12, 10, 8],
    default_type="CDR",
    default_vector=[0, 1, 2, 3, 4, 5, 5, 4, 3, 2, 1, 0],
    severity=0.40,
    recovery_lag=18
)

# Run cash flows
cashflows = tranche.run(assumptions)

# Access output
for period in cashflows:
    print(f"Date: {period.date}, "
          f"Principal: {period.principal:.2f}, "
          f"Interest: {period.interest:.2f}, "
          f"Prepay: {period.prepayment:.2f}, "
          f"Loss: {period.loss:.2f}, "
          f"Balance: {period.ending_balance:.2f}")

# Get summary metrics
metrics = tranche.metrics(assumptions, price=95.50)
print(f"Yield: {metrics.yield_pct:.4f}%")
print(f"WAL: {metrics.wal:.2f} years")
print(f"Mod Duration: {metrics.mod_duration:.2f}")
```

### Tranche-Level Output

Intex generates detailed periodic (usually monthly) output for each tranche:

| Output Field | Description |
|-------------|-------------|
| Period Date | Payment date for each period |
| Beginning Balance | Outstanding principal at start of period |
| Scheduled Principal | Amortization payment |
| Prepayment Principal | Principal from prepayments |
| Total Principal | Scheduled + Prepayment |
| Interest Payment | Coupon interest paid to tranche holder |
| Interest Shortfall | Any interest not paid (for subordinate tranches under stress) |
| Realized Loss | Credit losses allocated to the tranche |
| Write-down | Principal write-down due to losses |
| Ending Balance | Outstanding principal at end of period |
| Factor | Ending Balance / Original Face (indicates how much has paid down) |
| Cumulative Loss | Total losses allocated through this period |

**Summary Metrics:**
- Yield (at a given price)
- WAL (Weighted Average Life)
- Modified Duration
- Macaulay Duration
- Spread (nominal, Z-spread)
- Window (first principal payment to last principal payment dates)
- Average Life Volatility (how WAL changes across scenarios)

### Waterfall Modeling

The **waterfall** is the set of structural rules that determine how collateral cash flows are distributed to tranches. Intex encodes the complete waterfall logic for each deal, which can include:

**Sequential Pay Structure:**
```
Collateral Cash Flows
  |
  v
[Senior Fees: Trustee, Servicer]
  |
  v
[Interest: A1 -> A2 -> M1 -> M2 -> B1]  (pro rata or sequential)
  |
  v
[Principal: A1 (until retired) -> A2 (until retired) -> M1 -> M2 -> B1]
  |
  v
[Excess Spread -> OC Account or Released]
```

**Key Waterfall Features:**
- **Overcollateralization (OC) tests:** If the deal's credit enhancement falls below a threshold, cash flows are redirected from subordinate to senior classes (turbo principal).
- **Interest coverage (IC) tests:** If interest payments to senior classes are at risk, cash flow priorities shift.
- **Triggers:** Performance triggers (e.g., cumulative loss exceeds X%) can change the waterfall from pro-rata to sequential, protecting senior classes.
- **Step-down provisions:** After a seasoning period (e.g., 36 months), if performance tests are met, subordinate classes begin receiving principal.
- **Clean-up calls:** Optional redemption when the pool balance falls below 10% of original (concentrates credit risk).
- **Advancing:** Servicers may advance principal and interest on delinquent loans, which affects cash flow timing.

Intex's value is that it has reverse-engineered and coded the waterfall rules from the prospectus and deal documents for each deal, saving users from having to build this logic themselves.

### Intex vs. Bloomberg

| Feature | Intex | Bloomberg |
|---------|-------|-----------|
| **Primary strength** | Non-agency structured products, detailed waterfall modeling | Agency MBS, broad fixed-income analytics |
| **Deal coverage** | 30,000+ structured deals with full waterfall | Broad security coverage but less detailed waterfall logic |
| **Cash flow projections** | Granular, tranche-level, full waterfall | Available but less detailed for complex structures |
| **API/Batch capability** | CDI API — purpose-built for batch processing | BPIPE/BAPI — general purpose, less optimized for structured products |
| **Collateral data** | Loan-level data for many deals | Security-level data; loan-level via separate products |
| **Prepayment models** | Supports external models; focused on cash flow engine | Integrated prepayment models (Bloomberg Prepayment Model) |
| **Pricing** | Cash flow engine; relies on external pricing | Real-time pricing, composite prices, BVAL |
| **User base** | Structured finance desks, risk teams | Universal across fixed income |
| **Cost** | Separate license; can be expensive | Part of Bloomberg terminal subscription |
| **OAS analytics** | Limited built-in; typically done externally | Full OAS analytics (YAS, OAS1 functions) |

**In practice,** most sophisticated MBS investors use **both**: Intex for waterfall modeling and cash flow projections on non-agency deals, and Bloomberg for pricing, OAS analytics, and agency MBS analytics.

### Database Integration

Integrating Intex output into databases is a core data engineering task for MBS teams.

**Common Database Schema Design:**

```sql
-- Deal reference table
CREATE TABLE intex_deals (
    deal_id         VARCHAR(50) PRIMARY KEY,
    deal_name       VARCHAR(200),
    issuer          VARCHAR(100),
    issue_date      DATE,
    deal_type       VARCHAR(50),  -- RMBS, CMBS, ABS, CLO
    collateral_type VARCHAR(50),  -- Prime, Subprime, Alt-A
    original_balance DECIMAL(18,2),
    last_updated    TIMESTAMP
);

-- Tranche reference table
CREATE TABLE intex_tranches (
    tranche_id      VARCHAR(50) PRIMARY KEY,
    deal_id         VARCHAR(50) REFERENCES intex_deals(deal_id),
    class_name      VARCHAR(20),  -- A1, A2, M1, etc.
    cusip           VARCHAR(9),
    original_face   DECIMAL(18,2),
    coupon_rate     DECIMAL(8,6),
    coupon_type     VARCHAR(20),  -- Fixed, Float, IO, PO
    index_name      VARCHAR(20),  -- SOFR, Prime, etc.
    spread          DECIMAL(8,4),
    rating_moody    VARCHAR(10),
    rating_sp       VARCHAR(10),
    rating_fitch    VARCHAR(10)
);

-- Cash flow projections (the big table)
CREATE TABLE intex_cashflows (
    run_id          BIGINT,
    tranche_id      VARCHAR(50),
    scenario_id     INT,
    as_of_date      DATE,
    period_date     DATE,
    beginning_bal   DECIMAL(18,2),
    scheduled_prin  DECIMAL(18,2),
    prepay_prin     DECIMAL(18,2),
    total_principal DECIMAL(18,2),
    interest        DECIMAL(18,2),
    int_shortfall   DECIMAL(18,2),
    realized_loss   DECIMAL(18,2),
    ending_bal      DECIMAL(18,2),
    factor          DECIMAL(12,10),
    cumulative_loss DECIMAL(18,2),
    PRIMARY KEY (run_id, tranche_id, scenario_id, period_date)
);

-- Scenario definitions
CREATE TABLE intex_scenarios (
    scenario_id     INT PRIMARY KEY,
    scenario_name   VARCHAR(100),
    prepay_type     VARCHAR(10),  -- CPR, PSA, Vector
    prepay_value    VARCHAR(500), -- JSON or delimited vector
    default_type    VARCHAR(10),
    default_value   VARCHAR(500),
    severity        DECIMAL(6,4),
    recovery_lag    INT,
    rate_curve      VARCHAR(50),
    created_date    TIMESTAMP
);

-- Summary metrics per tranche/scenario
CREATE TABLE intex_metrics (
    run_id          BIGINT,
    tranche_id      VARCHAR(50),
    scenario_id     INT,
    as_of_date      DATE,
    price           DECIMAL(10,6),
    yield_pct       DECIMAL(8,6),
    wal             DECIMAL(8,4),
    mod_duration    DECIMAL(8,4),
    z_spread        DECIMAL(8,2),
    first_pay_date  DATE,
    last_pay_date   DATE,
    current_factor  DECIMAL(12,10),
    PRIMARY KEY (run_id, tranche_id, scenario_id)
);
```

**Data Volume Considerations:**
- A single tranche/scenario run produces ~360 rows of monthly cash flows (30-year deal).
- A portfolio of 2,000 tranches x 15 scenarios = 30,000 runs x 360 months = **10.8 million rows per run date.**
- Monthly snapshots over a year = **~130 million rows** just for cash flows.
- Use **columnar storage** (Parquet, Delta Lake) with partitioning by as_of_date and scenario_id.
- Consider **time-series databases** or **data lakehouse** architectures for efficient querying.

### API Integration for Data Engineering

**Batch Processing Pipeline:**

```
[Scheduler: Airflow/Prefect]
         |
         v
[Extract: Pull positions from portfolio system]
         |
         v
[Map: Match CUSIPs to Intex deal/tranche IDs]
         |
         v
[Configure: Build assumption sets for each scenario]
         |
         v
[Execute: Submit to CDI API (parallelized)]
         |
         v
[Collect: Gather cash flow output and metrics]
         |
         v
[Validate: Check for errors, missing data, anomalies]
         |
         v
[Load: Write to database/data lake (Parquet/Delta)]
         |
         v
[Report: Generate downstream analytics/reports]
```

**Key Engineering Considerations:**

1. **Parallelization:** CDI API calls are CPU-intensive. Distribute across multiple cores/nodes. Typical throughput: 50-200 tranche-scenarios per minute per core, depending on deal complexity.

2. **Error handling:** Some deals fail (corrupted data, unsupported structures). Implement retry logic with exponential backoff and quarantine failed runs for manual review.

3. **Deal library updates:** Intex releases monthly factor updates. Schedule library refreshes and re-run analytics when factors change.

4. **Idempotency:** Design pipelines so re-runs produce identical results. Store the exact assumption set and library version used for each run.

5. **CUSIP-to-Intex mapping:** Not always 1:1. Some CUSIPs map to multiple Intex tranches (e.g., exchangeable classes). Maintain a curated mapping table with manual overrides.

6. **Caching:** Cache results for scenarios that do not change frequently. Invalidate cache when positions change or new factor data arrives.

7. **Monitoring:** Track run times, success rates, and output data quality metrics. Alert on anomalies (e.g., a tranche that suddenly shows zero cash flows, or WAL that changes dramatically between runs).

### Common Fields and Database Mapping

When building an Intex data pipeline, map these fields from the CDI API output to your database:

| CDI API Field | Database Column | Data Type | Notes |
|--------------|----------------|-----------|-------|
| DealID | deal_id | VARCHAR | Intex deal identifier |
| TrancheID | tranche_id | VARCHAR | Intex tranche identifier |
| CUSIP | cusip | CHAR(9) | Map to portfolio holdings |
| PeriodDate | period_date | DATE | Monthly payment date |
| BeginBal | beginning_bal | DECIMAL | Period starting balance |
| SchedPrin | scheduled_prin | DECIMAL | Amortization principal |
| PrepayPrin | prepay_prin | DECIMAL | Prepayment principal |
| TotalPrin | total_principal | DECIMAL | = SchedPrin + PrepayPrin |
| Interest | interest | DECIMAL | Coupon payment |
| IntShortfall | int_shortfall | DECIMAL | Unpaid interest (stress scenarios) |
| Loss | realized_loss | DECIMAL | Credit loss allocated |
| EndBal | ending_bal | DECIMAL | Period ending balance |
| Factor | factor | DECIMAL(12,10) | EndBal / OriginalFace |
| CumLoss | cumulative_loss | DECIMAL | Running total of losses |
| CPR | period_cpr | DECIMAL | Effective CPR for the period |
| CDR | period_cdr | DECIMAL | Effective CDR for the period |
| Severity | period_severity | DECIMAL | Effective severity for the period |

**Derived Fields (calculated in your pipeline):**
- `total_cashflow` = total_principal + interest
- `principal_return_pct` = total_principal / beginning_bal
- `loss_rate` = realized_loss / beginning_bal
- `yield` (computed from price and cash flow stream)
- `wal` (computed as weighted average of principal payment timing)
- `duration` (computed from yield and cash flow timing)

---

## Real-World Examples

### Example 1: Building an Intex Data Pipeline

A hedge fund acquires a $500M portfolio of 150 non-agency RMBS tranches from legacy deals (2005-2007 vintage). The data engineering team builds a pipeline:

1. **Position file:** 150 rows with CUSIP, face amount, purchase price, settlement date.
2. **CUSIP mapping:** Match each CUSIP to an Intex deal/tranche ID using the Intex CUSIP lookup. Three CUSIPs fail to map (private placements not in Intex library) — flagged for manual modeling.
3. **Scenario grid:** 12 scenarios combining 4 prepayment speeds (8, 15, 25, 40 CPR) x 3 credit stresses (2/35, 5/50, 8/65 CDR/severity).
4. **Batch execution:** 147 tranches x 12 scenarios = 1,764 runs submitted to CDI API. Runtime: ~35 minutes on an 8-core server.
5. **Output:** ~635K rows of monthly cash flows loaded into a Parquet-based data lake, plus 1,764 rows of summary metrics.
6. **Downstream:** Risk team queries the data lake to compute portfolio-level WAL, expected loss, and scenario P&L. Results feed the fund's risk report and investor letter.

### Example 2: Regulatory Stress Testing with Intex

A regional bank holds $3B in non-agency RMBS and CMBS across 400 deals. For DFAST reporting:

1. **Scenario mapping:** Translate the Fed's supervisory scenarios (macro variables) into Intex-compatible inputs:
   - Base: 10 CPR, 2 CDR, 35% severity, 15-month recovery lag.
   - Adverse: 8 CPR, 5 CDR, 50% severity, 18-month lag.
   - Severely adverse: 5 CPR, 8 CDR, 65% severity, 24-month lag.
2. **Execution:** 800 tranches x 3 scenarios = 2,400 runs.
3. **Aggregation:** Sum projected losses by quarter over the 9-quarter planning horizon.
4. **Capital impact:** Losses reduce CET1 capital; the bank must show it remains above minimum ratios.
5. **Auditability:** Every input (scenario definition, deal library version, run date, assumption) is logged with a unique run ID traceable to the final regulatory filing.

### Example 3: Intex vs. Bloomberg Workflow

A portfolio analyst needs to evaluate a potential purchase of a tranche from CWALT 2006-OC9, class A2:

**Intex workflow:**
1. Open INTEXcalc, search for deal "CWALT 2006-OC9".
2. Select class A2.
3. Enter assumptions: 15 CPR, 4 CDR, 45% severity, 18-month recovery lag.
4. View monthly cash flow projection, noting the tranche receives no principal until the A1 class is retired (sequential structure).
5. Run a yield table at various prices (e.g., 85, 90, 95) to find the implied yield at each price.
6. Run credit stress scenarios to see when losses reach the A2 tranche (credit enhancement analysis).

**Bloomberg workflow:**
1. Type the CUSIP into Bloomberg, go to YAS (Yield & Spread Analysis).
2. View the current market price (BVAL or composite).
3. Run OAS analysis to get the spread — but Bloomberg's waterfall modeling for this complex non-agency deal may be less precise than Intex.
4. Use Bloomberg for pricing reference and market color; use Intex for detailed cash flow and waterfall analysis.

**Conclusion:** For non-agency structured products, Intex is the authoritative cash flow engine, while Bloomberg provides market pricing and broad analytics.

---

## Common Interview Questions & Answers

### Q1: What is Intex and why is it important for MBS analytics?

**Answer:** Intex Solutions is the industry-standard platform for structured finance cash flow modeling. It maintains a library of 30,000+ securitization deals with their complete waterfall rules encoded programmatically. Users provide collateral assumptions (prepayment speeds, default rates, loss severity, recovery lags), and Intex runs the cash flows through the deal waterfall to produce tranche-level output. This is critical because structured deals have complex rules (sequential/pro-rata pay, OC/IC tests, triggers, step-downs) that determine how collateral cash flows are distributed to investors. Without Intex, each firm would need to independently model these waterfalls from prospectus documents — an enormous and error-prone effort. For data engineers, Intex is a key data source that feeds risk systems, regulatory reporting, and portfolio analytics.

### Q2: Describe how you would integrate Intex into a data pipeline.

**Answer:** The integration has several components: (1) **Input preparation** — extract positions from the portfolio system, map CUSIPs to Intex deal/tranche IDs using a maintained mapping table, and define scenario assumptions. (2) **Execution** — use the CDI API to submit batch runs, parallelizing across multiple cores for throughput. Implement error handling with retries and quarantine for failed runs. (3) **Output processing** — parse the monthly cash flow output and summary metrics, validate data quality (no missing periods, balances foot correctly, factors are consistent), and transform into the target schema. (4) **Storage** — load into a data lake (Parquet/Delta) or database with appropriate partitioning (by as-of date, scenario). (5) **Orchestration** — use Airflow or Prefect to schedule runs (typically monthly after factor updates), manage dependencies, and monitor execution. (6) **Governance** — log every run with its assumptions, library version, and output hash for auditability. This is especially important for regulatory stress testing where full lineage is required.

### Q3: What collateral assumptions do you need to run Intex cash flows, and how do they affect output?

**Answer:** The four primary assumptions are: (1) **Prepayment speed** (CPR, PSA, or a monthly vector) — determines how quickly principal is returned, affecting WAL, yield, and which tranches receive cash flows. Higher prepayments shorten WAL and can trigger step-down provisions. (2) **Default rate** (CDR or vector) — determines how much of the pool defaults, generating losses that may be allocated to subordinate tranches. (3) **Loss severity** (percentage) — determines the loss per dollar defaulted. Combined with CDR, it drives total credit losses. (4) **Recovery lag** (months) — determines the delay between default and recovery, affecting the timing of net cash flows and present values. Additionally, for floating-rate tranches, you need a forward rate curve assumption. These assumptions interact: higher defaults reduce the performing balance, which reduces future prepayments. The waterfall structure then determines how collateral-level cash flows are allocated to each tranche — senior tranches are protected by subordination and OC, while subordinate tranches absorb losses first.

### Q4: How do you handle the CUSIP-to-Intex deal mapping challenge?

**Answer:** This is a practical data engineering challenge because the mapping is not always straightforward. My approach: (1) Use Intex's own CUSIP lookup as the primary source — the CDI API and INTEXcalc both support CUSIP-based search. (2) Build a persistent mapping table in the database that caches known good mappings. (3) Implement automated matching for new CUSIPs using the Intex API. (4) Flag failures for manual resolution — some CUSIPs do not map because the deal is not in the Intex library (private placements, very new deals not yet loaded, or non-structured securities incorrectly categorized). (5) Handle edge cases: exchangeable classes where one CUSIP maps to multiple Intex tranches, re-REMICs where the underlying is itself a structured tranche, and CUSIPs that change due to corporate actions. (6) Version the mapping table and audit changes. This mapping table becomes a critical reference dataset and should be treated with the same data governance rigor as any master data.

### Q5: What is the difference between running Intex at the collateral level vs. the tranche level?

**Answer:** At the **collateral level**, you are projecting the total pool cash flows — aggregate principal, interest, defaults, losses, and recoveries for the entire pool of underlying loans. This gives you the total cash available for distribution. At the **tranche level**, Intex applies the waterfall rules to distribute those collateral cash flows to each tranche according to the deal structure. The key insight is that collateral cash flows are the same regardless of which tranche you analyze (they depend only on the pool assumptions), but tranche-level cash flows can vary dramatically based on the tranche's position in the waterfall. A senior tranche might receive all principal with zero losses under a moderate stress scenario, while a subordinate tranche in the same deal might be completely wiped out. Running at the tranche level is essential for valuation and risk; running at the collateral level is useful for understanding the deal's overall credit performance.

### Q6: How would you design a database schema to store Intex output efficiently?

**Answer:** The main challenge is data volume — monthly cash flows across thousands of tranches and multiple scenarios produce millions of rows. My design approach: (1) **Separate reference data from analytical data** — deal and tranche attributes in normalized tables (updated infrequently), cash flows in a fact table (append-only, partitioned). (2) **Partition the cash flow table** by as_of_date (run date) and optionally by scenario_id, enabling efficient pruning of queries. (3) **Use columnar storage** (Parquet in a data lake, or columnar database like Redshift/Snowflake) because queries typically select specific columns (e.g., just ending_balance and loss) across many rows. (4) **Include a run_id** that ties to a metadata table logging the exact assumptions, library version, and execution timestamp for auditability. (5) **Store scenario definitions separately** with a scenario_id foreign key, avoiding redundant storage of assumption vectors in every cash flow row. (6) **Create materialized views or summary tables** for common queries (portfolio-level WAL, total projected loss by scenario, tranche-level yield) to avoid re-scanning the full cash flow table. (7) **Implement retention policies** — keep the latest N snapshots in hot storage, archive older runs to cold storage.

---

## Tips

- **Intex knowledge is a major differentiator** for data engineering roles in structured finance. Most candidates know SQL and Python; far fewer know how to integrate Intex into a data pipeline.
- **Understand the deal waterfall conceptually** even if you do not code them yourself. Know what sequential pay, pro-rata, OC tests, and triggers mean, because you need to validate and explain Intex output to stakeholders.
- **The CDI API is the key product for data engineers.** Be able to describe the input parameters, output fields, batch processing workflow, and error handling approach.
- **CUSIP mapping is a real-world pain point** that every Intex integration team deals with. Discussing this in an interview shows practical experience.
- **Data volume management is critical.** Be ready to discuss partitioning strategies, storage format choices (Parquet vs. row-oriented), and query optimization for Intex output tables that can reach hundreds of millions of rows.
- **Auditability and lineage** are non-negotiable in a regulated environment. Every Intex run must be traceable to its inputs and assumptions. Design your pipeline with this requirement from the start, not as an afterthought.
- **Know the Intex vs. Bloomberg distinction.** In interviews, articulate when you would use each: Intex for detailed non-agency waterfall modeling and batch cash flow projections; Bloomberg for pricing, OAS analytics, and agency MBS analysis. Many workflows use both together.
- **Factor updates** are a recurring operational concern. Intex deal library updates monthly with new trustee reports. Your pipeline must handle library refreshes gracefully, re-running analytics when factors change and tracking which library version was used for each historical run.
