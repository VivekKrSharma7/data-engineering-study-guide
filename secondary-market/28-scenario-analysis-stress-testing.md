# Scenario Analysis & Stress Testing

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Overview of Scenario Analysis

Scenario analysis for MBS portfolios involves projecting cash flows, valuations, and losses under alternative economic environments. Unlike single-point analytics (e.g., current OAS or OAD), scenario analysis examines how a portfolio performs across a range of possible futures. This is essential for MBS because the embedded prepayment option creates path-dependent, nonlinear behavior that cannot be captured by a single risk metric.

### Interest Rate Scenarios

Interest rate scenarios define how the yield curve evolves over a projection horizon. Common approaches include:

**Parallel Shifts:**
- Instantaneous parallel moves of +/- 50, 100, 200, 300 bps.
- Simple but unrealistic; used as a baseline stress.

**Non-Parallel (Twist) Scenarios:**
- Steepening: Short rates fall, long rates rise or stay flat.
- Flattening: Short rates rise, long rates fall or stay flat.
- Critical for MBS because the 2s/10s slope affects the refinancing incentive differently than a parallel move.

**Ramp Scenarios:**
- Rates gradually shift over 12-24 months rather than instantaneously.
- More realistic; used in ALM (asset-liability management) and for CCAR/DFAST.

**Historical Replay:**
- Apply rate changes from a specific historical episode (e.g., 2013 Taper Tantrum, 2020 COVID rally, 2022 hiking cycle).
- Tests how the portfolio would have performed in a known stress period.

**Stochastic Scenarios:**
- Thousands of Monte Carlo rate paths generated from a term structure model.
- Used for OAS valuation, VaR, and expected shortfall calculations.

### Prepayment Scenarios

Since MBS cash flows depend critically on prepayments, scenario analysis must stress prepayment assumptions:

**Constant Prepayment Scenarios:**
- Run cash flows at various CPR levels (e.g., 5%, 10%, 15%, 25%, 40% CPR).
- Simple sensitivity analysis showing how WAL, duration, and yield change.

**Model-Driven Prepayments:**
- Use a prepayment model (e.g., Andrew Davidson, BlackRock, Intex) that responds to the rate scenario.
- Captures the dynamic interaction between rates and prepayments.

**Prepayment Vector Stress:**
- Override the model with specific CPR vectors (e.g., front-loaded speeds to simulate a refi wave, or very slow speeds to simulate extension).
- Apply PSA multiples (e.g., 50% PSA for extension, 500% PSA for rapid prepayment).

**Burnout Scenarios:**
- Model pools that have already been through a refinancing wave and have lower future prepayment sensitivity.

### Credit Stress

For non-agency MBS and credit-sensitive agency products, credit stress is essential:

**Default Scenarios:**
- Apply CDR (Conditional Default Rate) vectors: base case (2% CDR), adverse (5% CDR), severely adverse (8%+ CDR).
- Vary timing: front-loaded defaults stress liquidity; back-loaded defaults stress total loss.

**Severity Scenarios:**
- Loss severity (loss given default) assumptions: base case (35%), adverse (50%), severely adverse (65%+).
- Severity depends on property values, foreclosure timelines, and liquidation costs.

**Delinquency Transition Matrices:**
- Model loans transitioning between current, 30-day, 60-day, 90-day delinquent, foreclosure, and REO states.
- Stress the transition probabilities (e.g., higher roll rates from 60-day to 90-day).

**Home Price Index (HPI) Scenarios:**
- HPI directly affects LTV, which drives both default probability and loss severity.
- Base case: +3% annual HPI growth.
- Adverse: -10% over 2 years.
- Severely adverse: -25% over 3 years (modeled after 2007-2009).

### DFAST and CCAR

**Dodd-Frank Act Stress Tests (DFAST)** and **Comprehensive Capital Analysis and Review (CCAR)** are regulatory stress testing frameworks mandated by the Federal Reserve for large bank holding companies.

**Scenario Design:**

| Scenario | Economic Conditions | Purpose |
|----------|-------------------|---------|
| **Baseline** | Consensus economic forecast | Normal operating conditions |
| **Adverse** | Moderate recession: GDP -2%, unemployment 7-8%, HPI -10%, rates down 100 bps | Tests resilience under stress |
| **Severely Adverse** | Deep recession: GDP -5%, unemployment 10%+, HPI -25%, rates down 200+ bps | Tests survival under extreme stress |

**Key Variables in Supervisory Scenarios:**
- GDP growth (real)
- Unemployment rate
- House Price Index (HPI) — national and regional
- Commercial Real Estate Price Index
- Treasury rates (3M, 5Y, 10Y)
- BBB corporate spread
- Mortgage rate
- Stock market (Dow/VIX)
- International variables (EUR area GDP, etc.)

**MBS-Specific Stress Testing for DFAST/CCAR:**
1. Map supervisory macro scenarios to interest rate paths and prepayment model inputs.
2. Run cash flow projections for each MBS position under each scenario over a 9-quarter planning horizon.
3. Project credit losses for non-agency holdings using HPI and unemployment scenarios.
4. Calculate market value changes (P&L impact) for available-for-sale and trading book positions.
5. Estimate NII (Net Interest Income) impact on held-to-maturity positions.
6. Aggregate results for capital adequacy assessment (CET1 ratio, leverage ratio, etc.).

### MBS Portfolio Stress Testing

Beyond regulatory mandates, internal stress testing for MBS portfolios typically includes:

**Market Risk Stress:**
- Rate scenarios (parallel, twist, butterfly).
- Spread widening (OAS +50, +100, +200 bps).
- Volatility shocks (swaption vol up 20%, 50%).
- Combined scenarios (rates up + spreads wide, as in 2022).

**Liquidity Stress:**
- Model bid/ask widening under stress.
- Estimate time-to-liquidate for less liquid positions (non-agency, specified pools).
- Assess cash flow availability under adverse prepayment scenarios.

**Concentration Risk:**
- Test exposure to a single coupon stack (e.g., all 30-year 3.0% MBS).
- Geographic concentration (California earthquake scenario, Florida hurricane scenario).
- Servicer concentration (what if a servicer fails?).

### HPI Scenarios and Loss Projection

Home Price Index scenarios are central to credit loss modeling:

**Loss Projection Methodology:**
1. Start with loan-level data: current UPB, LTV, FICO, loan age, state, property type.
2. Apply HPI scenario to update property values and current LTV.
3. Use updated LTV (and other risk factors) in a default model to project default probability.
4. Apply loss severity model based on updated LTV, state (judicial vs. non-judicial foreclosure), and liquidation timeline.
5. **Expected Loss = PD * LGD * EAD** for each loan.
6. Aggregate to pool, tranche, and portfolio level.
7. Run through the deal waterfall (for structured MBS) to allocate losses to tranches.

**HPI data sources:**
- CoreLogic, FHFA HPI, S&P/Case-Shiller.
- FHFA publishes state-level and MSA-level indices.
- Supervisory scenarios provide specific HPI paths for stress testing.

### Intex Scenario Modeling

Intex is the industry-standard tool for running structured MBS and ABS cash flows under scenarios:

**How Intex Scenario Modeling Works:**
1. Select a deal from the Intex deal library using the deal ID (e.g., ACE 2006-HE3).
2. Specify collateral assumptions:
   - Prepayment vector (CPR or PSA, by month).
   - Default vector (CDR, by month).
   - Loss severity vector (by month).
   - Recovery lag (months from default to recovery).
3. Run the deal waterfall engine, which applies the collateral cash flows through the structural rules (senior/sub, OC/IC tests, triggers, etc.).
4. Extract tranche-level output: principal balance, interest, losses, cash flow timing.
5. Repeat for each scenario.

**Intex Scenario Inputs (Common Formats):**
- **CPR vector:** `5 5 5 10 15 20 20 20 15 10 5 5` (monthly or annual)
- **CDR vector:** `0 0 1 2 3 4 4 3 2 1 0 0`
- **Severity:** `35` (flat) or `30 35 40 45 50 50 45 40 35 30` (vector)
- **Recovery lag:** `18` months (typical for judicial states)

**Intex Scenario Batching:**
- For stress testing, analysts run dozens of scenarios (e.g., base + 5 rate shifts x 3 credit stresses = 18 scenarios per deal).
- The CDI API supports programmatic batch execution for large portfolio stress tests.
- Output data volumes can be enormous: monthly cash flows x number of tranches x number of scenarios.

### Data Requirements for Stress Testing

A robust stress testing infrastructure requires:

**Input Data:**
- **Position data:** CUSIP, face amount, price, settlement date, account/portfolio mapping.
- **Security reference:** Deal structure, tranche terms, collateral characteristics.
- **Collateral tape:** Loan-level data with LTV, FICO, loan balance, state, origination date, rate, occupancy, documentation type.
- **Market data:** Yield curves (Treasury, swap, SOFR), MBS prices, spreads, implied volatility.
- **Scenario definitions:** Rate paths, HPI paths, unemployment paths, CDR/severity assumptions.

**Output Data:**
- **Cash flow projections:** Monthly P&I, prepayments, defaults, losses, recoveries for each tranche/scenario.
- **Valuation:** Market value under each scenario, P&L change from base.
- **Risk metrics:** Duration, convexity, KRDs under each scenario.
- **Loss estimates:** Cumulative credit loss, timing of losses, tranche-level write-downs.
- **Capital impact:** Change in regulatory capital ratios under each scenario.

**Infrastructure Considerations:**
- **Compute:** Monte Carlo OAS + scenario grid = massive computation. Typically uses grid computing or cloud (AWS/Azure).
- **Storage:** Tranche-level monthly cash flows x scenarios x history = terabytes. Use columnar formats (Parquet) and partitioning.
- **Orchestration:** Scenario runs are batch processes, often scheduled nightly or weekly. Tools: Airflow, Prefect, Control-M.
- **Lineage:** Regulators require full traceability from scenario assumptions through cash flow projections to capital impact. Data lineage is non-negotiable.

---

## Real-World Examples

### Example 1: Rate Scenario Impact on MBS Portfolio

A portfolio holds $2B face of 30-year agency MBS across coupon stacks:

| Coupon | Face ($M) | Base OAD | OAD (-100bp) | OAD (+100bp) | Base MV ($M) | MV (-100bp) | MV (+100bp) |
|--------|----------|----------|-------------|-------------|-------------|------------|------------|
| 3.0% | 500 | 6.5 | 4.8 | 8.2 | 470 | 498 | 434 |
| 4.0% | 800 | 5.2 | 3.5 | 6.8 | 788 | 822 | 746 |
| 5.0% | 700 | 3.8 | 2.2 | 5.1 | 714 | 734 | 690 |
| **Total** | **2,000** | | | | **1,972** | **2,054** | **1,870** |

In the -100bp scenario, the portfolio gains $82M but underperforms a comparable Treasury portfolio (which would gain ~$170M) due to negative convexity. In the +100bp scenario, the portfolio loses $102M — more than a duration-matched Treasury would lose — due to extension.

### Example 2: DFAST Credit Stress on Non-Agency Portfolio

A bank holds $500M of legacy non-agency RMBS (vintages 2005-2007). Under the severely adverse scenario:

- **HPI decline:** -25% over 8 quarters.
- **Unemployment:** peaks at 10.5%.
- **Current weighted-average LTV:** 75%. After HPI stress: 100% (underwater).
- **Projected CDR:** peaks at 8% annually.
- **Loss severity:** 55% (due to high LTV, foreclosure costs, depressed market).
- **Projected 9-quarter cumulative loss:** $68M on the $500M portfolio (13.6% of face).
- **After waterfall:** Senior tranches absorb $0 loss; mezzanine absorbs $42M; subordinate absorbs $26M (wiped out).

This analysis directly feeds the bank's capital planning submission.

### Example 3: Intex Batch Scenario Run

A data engineering team runs quarterly stress tests for a $10B non-agency portfolio (800 unique deals, 2,400 tranches). The process:

1. **Extract** position data from the portfolio system (holdings as of quarter-end).
2. **Map** each holding to an Intex deal ID and tranche.
3. **Define** 15 scenarios (5 rate shifts x 3 credit stresses).
4. **Submit** to Intex CDI API: 2,400 tranches x 15 scenarios = 36,000 runs.
5. **Collect** monthly cash flows (360 months x 36,000 = ~13M rows per monthly field).
6. **Store** results in Parquet files partitioned by scenario/deal.
7. **Compute** present values using scenario-specific discount rates.
8. **Aggregate** to portfolio level and produce regulatory reports.
9. **Total runtime:** ~4 hours on a 64-node compute cluster.

---

## Common Interview Questions & Answers

### Q1: What is the difference between sensitivity analysis and scenario analysis?

**Answer:** Sensitivity analysis varies a single input parameter while holding all others constant to isolate its impact (e.g., shifting rates by +100 bps with no change to credit assumptions). Scenario analysis changes multiple correlated variables simultaneously to simulate a coherent economic narrative (e.g., rates fall 200 bps AND unemployment rises to 10% AND HPI declines 25%, which together represent a recession). Scenario analysis is more realistic because in practice, economic variables move together. For MBS, scenario analysis is superior because rate changes drive prepayments, HPI changes drive defaults, and these interact — a rate rally with HPI decline produces different MBS behavior than either factor alone.

### Q2: How do you design a stress scenario for an MBS portfolio?

**Answer:** Start with the portfolio's key risk exposures: for agency MBS, the primary risks are interest rate and prepayment; for non-agency, add credit risk. Design scenarios around historical episodes of stress (2008 financial crisis, 2013 taper tantrum, 2020 COVID, 2022 rate shock) and hypothetical extremes. For each scenario, specify: (1) the interest rate path (level and shape of the curve), (2) prepayment response (model-driven or overridden vectors), (3) credit variables (HPI, unemployment, default rates, severity), and (4) spread assumptions (OAS widening under stress). Ensure scenarios are internally consistent — e.g., a deep recession with sharply rising rates is unlikely (more plausible: recession with rate cuts). Include both base, adverse, and severely adverse cases, and consider reverse stress testing to find the scenario that causes a specific loss threshold to be breached.

### Q3: Explain how HPI scenarios affect loss projections for non-agency MBS.

**Answer:** HPI scenarios directly impact both the probability of default (PD) and loss given default (LGD). When HPI declines, current LTVs increase (or properties go underwater), which raises PD because borrowers have less equity and more incentive to default (especially for non-recourse loans). Higher LTVs also increase LGD because the property collateral is worth less relative to the outstanding loan balance, leading to larger losses upon liquidation. The loss projection process: (1) Apply the HPI path to each loan's property value to compute projected LTV. (2) Feed updated LTV into a default model to get PD. (3) Apply severity model conditioned on LTV. (4) Expected loss = PD x LGD x EAD. (5) Run through the waterfall to allocate losses to tranches. A 25% HPI decline can easily double or triple projected losses compared to a base case with flat HPI.

### Q4: What are the key differences between DFAST and CCAR?

**Answer:** DFAST (Dodd-Frank Act Stress Tests) is a quantitative exercise where banks project losses, revenues, and capital ratios under Fed-prescribed scenarios over a 9-quarter horizon. CCAR (Comprehensive Capital Analysis and Review) is broader — it includes the DFAST quantitative assessment plus a qualitative review of the bank's capital planning processes, risk management, internal controls, and governance. A bank can pass DFAST (maintain capital above minimums) but fail CCAR if the Fed finds deficiencies in its processes. CCAR also incorporates the bank's planned capital actions (dividends, buybacks), and the Fed can object to those plans. For MBS portfolios specifically, both require running the portfolio through the supervisory scenarios, but CCAR demands documentation of model validation, scenario design rationale, data governance, and escalation procedures.

### Q5: How does a data engineer support stress testing for MBS?

**Answer:** Data engineers build the infrastructure that makes stress testing possible at scale. Key responsibilities include: (1) **Data pipelines** to ingest and standardize position data, collateral tapes, market data, and scenario definitions from multiple sources. (2) **Integration with analytics engines** like Intex CDI API — building batch job orchestration, handling API rate limits, managing retries and failures. (3) **Storage architecture** for massive output datasets (monthly cash flows x tranches x scenarios), typically using columnar formats like Parquet with partitioning strategies. (4) **Compute orchestration** using Airflow or similar tools to manage the end-to-end workflow from data extraction through scenario runs to report generation. (5) **Data quality and validation** — implementing checks that catch issues like missing CUSIPs, stale prices, or anomalous cash flow outputs. (6) **Data lineage and auditability** — regulators require traceability from raw inputs to final capital numbers, so the data engineer must implement logging and metadata tracking at every step.

### Q6: What is reverse stress testing and how does it apply to MBS?

**Answer:** Reverse stress testing starts from a defined adverse outcome (e.g., the portfolio loses $500M, or the bank's CET1 ratio falls below 4.5%) and works backward to find the scenario that would cause that outcome. For MBS, this might mean finding the combination of rate changes, spread widening, and credit losses that would breach a risk limit or capital threshold. This approach is valuable because forward stress tests may miss tail risks — the designed scenarios might not be severe enough. Reverse stress testing forces management to confront the question: "What would have to happen for us to fail?" The results inform contingency planning, risk appetite calibration, and hedging strategy. Implementation requires an optimization or search algorithm that iterates over scenario parameters to find the boundary conditions.

---

## Tips

- **Understand the full stress testing workflow** end-to-end: scenario definition, data preparation, analytics execution, aggregation, reporting, and governance. Interviewers at banks expect data engineers to know where they fit in the chain and how their work connects upstream and downstream.
- **Know the three DFAST/CCAR scenarios** (baseline, adverse, severely adverse) and what macroeconomic variables they specify. You do not need to memorize exact numbers but should know the general direction (e.g., severely adverse has rates down, unemployment up, HPI down).
- **For data engineering interviews,** emphasize scalability. Stress testing generates massive data volumes (millions of rows of monthly cash flows). Discuss how you would partition data, choose storage formats, and manage compute resources.
- **Intex scenario modeling is a differentiator.** Most data engineers do not know how to run Intex batch scenarios programmatically. If you can discuss CDI API integration, input formatting, and output parsing, you will stand out.
- **Scenario consistency matters.** Never propose a scenario where rates rise sharply AND HPI rises sharply AND unemployment drops — scenarios must be economically coherent.
- **Data lineage is not optional** in a regulatory context. Be prepared to discuss how you ensure traceability from raw inputs to final outputs, including version control of scenario definitions and model versions.
- **Historical stress events** are common interview material. Know the key MBS-relevant episodes: 1994 (rate sell-off, extension), 1998 (LTCM/spread widening), 2007-2009 (credit crisis), 2013 (taper tantrum), 2020 (COVID volatility), 2022 (rapid rate hikes).
