# Bloomberg MBS Analytics

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. Bloomberg Terminal for MBS

The Bloomberg Terminal is the primary platform used by MBS traders, analysts, and portfolio managers for pricing, analytics, and data retrieval on mortgage-backed securities.

**Key MBS Screens:**

| Screen | Command | Description |
|---|---|---|
| MTGE | `MTGE <GO>` | Mortgage-backed securities main menu. Entry point for MBS analytics, pool lookup, and structured product analysis. |
| BMA | `BMA <GO>` | Bloomberg Mortgage Analytics. Provides scenario analysis, OAS computation, and prepayment/default projections for a specific MBS. |
| YAS | `YAS <GO>` | Yield Analysis for any fixed-income security including MBS. Calculates yield, spread, duration, and convexity. |
| DES | `DES <GO>` | Security description. Displays all static and dynamic attributes of a bond or pool. |
| POOL | `<CUSIP> Mtge <GO>` | Pool-level detail for an agency MBS pool, showing original/current face, WAC, WAM, WALA, factor, and geographic distribution. |
| TBA | `TBA <GO>` | To-Be-Announced market screen for agency MBS forward trading. Shows prices for TBA coupons across settlement months. |
| CMO | `CMO <GO>` | Structured product analysis for CMOs/REMICs. Displays deal structure, tranche waterfall, and cash flow analysis. |
| PORT | `PORT <GO>` | Portfolio analytics. Aggregates holdings and computes portfolio-level risk metrics, duration, and attribution. |

**Navigation Pattern:** Typically, an analyst types a security identifier (CUSIP, ticker, or pool number), then a market sector key (e.g., `Mtge` for mortgage), then the function (e.g., `BMA`, `YAS`, `DES`).

### 2. Pricing and Analytics

**MBS Pricing Fundamentals:**

- **Dollar Price:** MBS trade as a percentage of current face (not original face). A price of 101-16 means 101.5% of the current outstanding principal balance.
- **Current Face vs. Original Face:** As borrowers prepay and amortize, the pool's outstanding balance (current face) declines. The factor (current face / original face) tracks this paydown.
- **Accrued Interest:** MBS typically use 30/360 day count for accrual. Settlement is usually on the PSA (Public Securities Association) settlement calendar.
- **TBA vs. Specified Pools:** TBA (To-Be-Announced) is the forward market for generic agency MBS. Specified pools trade at a "pay-up" premium over TBA for desirable characteristics (low loan balance, geographic concentration in slow-prepay areas, high LTV).

**Key Analytics Metrics:**

- **Weighted Average Coupon (WAC):** Average interest rate of the underlying loans, weighted by current balance.
- **Weighted Average Maturity (WAM):** Average remaining term in months.
- **Weighted Average Loan Age (WALA):** Average seasoning in months.
- **CPR (Conditional Prepayment Rate):** Annualized single-month prepayment rate. 1-month, 3-month, 6-month, 12-month, and life CPR are standard.
- **CDR (Conditional Default Rate):** Annualized default rate, analogous to CPR for defaults.
- **Factor:** Current face / Original face. Published monthly by the agencies.

### 3. Yield Analysis

Bloomberg's YAS function computes multiple yield and spread measures for MBS:

- **Yield to Maturity (YTM):** Assumes no prepayments beyond scheduled amortization. Rarely used for MBS because prepayments are the dominant risk.
- **Yield at a Given PSA Speed:** Calculates yield assuming a constant prepayment speed (e.g., 150 PSA, 200 PSA). Useful for scenario analysis.
- **Cash Flow Yield:** Internal rate of return of projected cash flows under a specific prepayment and default assumption.
- **Spread to Treasury:** Nominal spread over the interpolated Treasury curve.
- **Spread to Swaps:** Spread over the interest rate swap curve, commonly used for agency MBS.
- **I-Spread, Z-Spread:** Static spread measures that account for the full term structure.

**Bond-Equivalent Yield vs. Mortgage Yield:** MBS pay monthly, so the stated yield must be converted to a bond-equivalent (semiannual) basis for comparison with Treasuries and corporate bonds. Bloomberg handles this conversion automatically.

### 4. OAS (Option-Adjusted Spread) Analysis

OAS is the gold standard spread measure for MBS because it accounts for the embedded prepayment option (borrowers can refinance when rates fall).

**How Bloomberg Computes OAS:**

1. **Interest Rate Model:** Bloomberg uses a term structure model (typically a lognormal short-rate model) calibrated to the current swap/Treasury curve and swaption volatilities.
2. **Monte Carlo Simulation:** Generates hundreds or thousands of interest rate paths.
3. **Prepayment Model:** Along each path, the Bloomberg Prepayment Model (BPM) projects monthly prepayments based on the rate environment, loan characteristics, and behavioral factors.
4. **Cash Flow Projection:** For each path, monthly cash flows (principal, interest, prepayments, defaults, losses) are generated.
5. **Discounting:** Cash flows are discounted back using the path-specific short rates plus a spread. The OAS is the spread that equates the average present value across all paths to the market price.

**Key OAS-Related Metrics:**

- **OAS Duration (OAD):** Sensitivity of price to a parallel shift in rates, accounting for the prepayment option. Calculated by bumping the curve +/- a small amount and re-running the Monte Carlo.
- **OAS Convexity (OAC):** Second-order rate sensitivity. MBS typically exhibit negative convexity because prepayments accelerate when rates fall (limiting price appreciation) and slow when rates rise (extending duration).
- **Key Rate Durations:** Sensitivity to individual points on the yield curve (2y, 5y, 10y, etc.).
- **Vega:** Sensitivity to changes in implied volatility.

### 5. Bloomberg Prepayment Model (BPM)

BPM is Bloomberg's proprietary prepayment model, widely used for MBS valuation.

**Model Components:**

- **Refinance Incentive:** The primary driver. Measures the borrower's rate incentive to refinance based on the spread between the loan's note rate and current market rates.
- **Turnover (Housing):** Baseline prepayments from home sales, driven by seasonality, home price appreciation, and lock-in effects.
- **Curtailments:** Partial prepayments (extra principal payments by borrowers). More prevalent for seasoned loans approaching maturity.
- **Burnout:** As a pool ages and rates remain favorable, the most rate-sensitive borrowers prepay first, leaving a "burned out" pool that prepays more slowly even if rates drop further.
- **Media Effect:** Spikes in refinancing activity driven by media attention to low rates.
- **Credit/FICO Effect:** Higher-FICO borrowers refinance more efficiently.
- **Loan Size Effect:** Larger loans have higher refinance incentives relative to fixed transaction costs.
- **Geography Effect:** State-level variation in refinance activity due to title/escrow practices and market competition.

**Default Component:** BPM also includes a default sub-model that projects CDR based on credit characteristics (LTV, FICO, documentation type), economic variables (unemployment, HPA), and loan seasoning.

### 6. Pool-Level and Tranche-Level Analysis

**Pool-Level (Pass-Through) Analysis:**

- Agency pass-throughs (e.g., FNMA 30yr 5.0%) distribute principal and interest pro-rata to all holders.
- Bloomberg's POOL function shows collateral composition: distribution of loan balances, LTVs, FICOs, geographic concentration, servicer breakdown.
- CPR and CDR history are displayed alongside projections under current rate scenarios.

**Tranche-Level (CMO/REMIC) Analysis:**

- CMOs re-allocate the cash flows from an underlying pool into tranches with different risk/return profiles: sequential pay, planned amortization class (PAC), support/companion, interest-only (IO), principal-only (PO), Z-bonds, floaters/inverse floaters.
- Bloomberg's CMO screen (`CMO <GO>`) displays the deal structure, priority of payments (waterfall), and tranche-specific cash flow projections.
- Each tranche has its own OAS, duration, and convexity profile that differs from the underlying collateral.

### 7. Bloomberg Data Feeds

**B-PIPE (Bloomberg Real-Time Feed):**

- Streaming real-time pricing data for MBS and other securities.
- Used by trading desks and automated trading systems.
- Delivers tick-by-tick price updates, trade reports, and quote updates.
- Requires Bloomberg Enterprise infrastructure and licensing.

**SFTP (Bulk Data Delivery):**

- Bloomberg delivers end-of-day pricing, analytics snapshots, index composition, and reference data via scheduled SFTP transfers.
- Common formats: CSV, pipe-delimited flat files.
- Used by data engineering teams to load Bloomberg data into internal data warehouses and risk systems.

**Data License:**

- Bloomberg's enterprise data product for bulk access to reference data, pricing, analytics, and historical time series.
- Accessed via SFTP, API, or Bloomberg's cloud-hosted Data License platform (DLPS).
- Data engineers use Data License to extract fields like OAS, OAD, CPR, price, and factor for thousands of MBS positions nightly.

### 8. PORT Function (Portfolio Analytics)

PORT is Bloomberg's portfolio management and analytics tool:

- **Holdings Upload:** Positions can be entered manually, uploaded via file, or fed from an order management system.
- **Risk Decomposition:** Computes portfolio-level duration, convexity, OAS, and key rate durations. Decomposes risk into interest rate, spread, prepayment, and credit components.
- **Scenario Analysis:** Runs parallel shift, twist, and custom rate scenarios to project portfolio P&L.
- **Attribution:** Performance attribution by sector, coupon, vintage, and other dimensions.
- **Benchmarking:** Compares portfolio risk and return against Bloomberg indices (e.g., Bloomberg US MBS Index).

**Data Engineering Relevance:** PORT data (holdings, risk analytics, performance) can be exported for use in internal reporting and compliance systems. Data engineers often build pipelines to reconcile PORT outputs with internal portfolio accounting systems.

### 9. Bloomberg Indices

**Bloomberg US MBS Index (formerly Barclays):**

- The benchmark index for agency MBS. Includes fixed-rate agency pass-throughs from Fannie Mae, Freddie Mac, and Ginnie Mae.
- Rebalanced monthly with specific inclusion rules (minimum pool size, seasoning, coupon).
- Returns are calculated assuming a specific reinvestment rate and standard settlement.

**Bloomberg US Aggregate Bond Index:**

- The broadest US investment-grade bond benchmark. MBS is the largest component (~27-30% of the index).
- Data engineers must understand how MBS index membership and weighting affect portfolio tracking and rebalancing.

**Index Data Fields:** Market value, duration, OAS, OAD, CPR, monthly return, excess return vs. Treasury duration-matched. These are available via Data License and terminal.

### 10. Bloomberg API (BLPAPI)

BLPAPI is Bloomberg's programmatic interface for extracting data from the Bloomberg platform.

**API Types:**

- **Desktop API (DAPI):** Runs on a machine with a Bloomberg Terminal. Used for ad-hoc scripting (Python, Excel VBA, C++, Java). Requires an active terminal session.
- **Server API (SAPI / B-PIPE API):** Runs on a server without a terminal. Used for production data pipelines. Requires B-PIPE or Server API licensing.

**Common Request Types:**

| Request Type | Description | MBS Example |
|---|---|---|
| Reference Data (`//blp/refdata`) | Static and calculated fields for a security | Get OAS, WAC, WAM, factor for a pool |
| Historical Data | Time series of a field | Get daily price history for a TBA coupon |
| Intraday Bars/Ticks | Real-time or historical tick data | Get intraday price movements for TBA trading |
| Bulk Data (`BulkFieldRequest`) | Multi-row fields | Get geographic distribution of a pool's collateral |

**Python Example (Conceptual):**

```python
import blpapi

session = blpapi.Session()
session.start()
session.openService("//blp/refdata")

service = session.getService("//blp/refdata")
request = service.createRequest("ReferenceDataRequest")

# Request OAS and prepayment speed for a Fannie Mae pool
request.append("securities", "FN MA4567 Mtge")
request.append("fields", "OAS_SPREAD_MID")
request.append("fields", "MTG_PREPAY_TBA_CPR_1MO")
request.append("fields", "MTG_CASH_FLOW_YLD")

session.sendRequest(request)
# ... handle response events
```

**Data Engineering Considerations:**

- Bloomberg API calls are rate-limited. Design batch requests efficiently (multiple securities per request, limit to needed fields).
- Historical data requests have row limits per request. Implement pagination for large date ranges.
- Error handling is critical: securities may not be found (invalid CUSIP), fields may not be applicable (e.g., OAS for a non-MBS security), or the service may be temporarily unavailable.
- Cache Bloomberg data locally to reduce API calls and costs. Store extracted data in your warehouse with clear timestamps indicating when it was pulled.

---

## Real-World Examples

### Example 1: Nightly MBS Portfolio Valuation Pipeline

A fixed-income fund needs daily risk analytics for 2,000 MBS holdings:

- At 6:00 PM ET, a Python job connects to Bloomberg SAPI and sends a `ReferenceDataRequest` for all 2,000 CUSIPs requesting: price, OAS, OAD, OAC, WAC, WAM, WALA, 1-mo CPR, 3-mo CPR, and factor.
- Responses are parsed and loaded into a PostgreSQL staging table.
- A dbt transformation job enriches the data with internal position data (shares held, cost basis) and computes portfolio-level risk metrics.
- Results are published to a Tableau dashboard for portfolio managers by 8:00 AM the following morning.

### Example 2: TBA Relative Value Analysis

A trading desk wants to compare relative value across TBA coupons:

- Using Bloomberg's TBA screen, the trader pulls prices for 30-year FNMA coupons from 2.0% to 6.5% across three settlement months.
- The data engineer has built an automated pipeline that extracts TBA prices, OAS, and model speeds via BLPAPI every 15 minutes during trading hours.
- The pipeline computes roll value (price differential between front-month and back-month TBA) and OAS carry for each coupon.
- Results are pushed to a real-time dashboard and an alerting system that notifies traders when OAS exceeds a threshold.

### Example 3: CMO Cash Flow Modeling

An insurance company holds a PAC tranche from a FHLMC REMIC deal:

- The analyst uses Bloomberg's CMO screen to load the deal structure and identify the PAC band (the range of prepayment speeds within which principal payments are stable).
- Using BMA, they run scenario analysis at multiple prepayment speeds (100 PSA, 200 PSA, 400 PSA) to see how the tranche's average life and yield change.
- The data engineer extracts the projected cash flows via BLPAPI's `BulkFieldRequest` for each scenario and loads them into the firm's asset-liability management (ALM) model.

---

## Common Interview Questions and Answers

### Q1: What is OAS and why is it preferred over nominal spread for MBS?

**Answer:** OAS (Option-Adjusted Spread) is the spread over the risk-free rate that an investor earns after accounting for the value of the embedded prepayment option in MBS. Unlike nominal spread (which is a simple spread over a single Treasury benchmark and ignores optionality), OAS uses Monte Carlo simulation to model many possible interest rate paths, projects prepayments along each path using a model like BPM, and calculates the spread that equates the average discounted cash flow across all paths to the market price. OAS is preferred because MBS have significant negative convexity -- when rates fall, prepayments accelerate and the bond shortens, limiting price upside; when rates rise, prepayments slow and the bond extends, amplifying price downside. Nominal spread does not capture this asymmetry. OAS provides a more apples-to-apples comparison across MBS with different collateral characteristics and against other fixed-income sectors.

### Q2: How does the Bloomberg Prepayment Model (BPM) work?

**Answer:** BPM decomposes prepayments into several behavioral components. The dominant component is the refinance incentive, which measures the gap between the loan's note rate and current market refinance rates -- the wider the gap, the greater the incentive to refinance. Turnover captures prepayments from home sales, driven by seasonality (higher in summer), home price appreciation (facilitates mobility), and the lock-in effect (borrowers with below-market rates are less likely to move). Burnout accounts for the fact that after a period of low rates, the most refinance-sensitive borrowers have already prepaid, leaving a slower-paying residual pool. The model also incorporates loan-level characteristics: higher-FICO borrowers refinance more efficiently, larger loans have proportionally lower transaction costs, and geographic factors affect refinancing friction. For non-agency MBS, BPM includes a default component projecting CDR based on credit attributes and macroeconomic conditions. All components are combined and calibrated to historical prepayment data.

### Q3: As a data engineer, how would you build a pipeline to extract MBS analytics from Bloomberg?

**Answer:** I would design it in layers. First, define the security universe -- maintain a table of active CUSIPs from our portfolio and benchmark holdings, updated daily from the portfolio management system. Second, use Bloomberg's Server API (SAPI) or Data License to make batch `ReferenceDataRequest` calls, requesting specific fields (price, OAS, OAD, CPR, factor, etc.) for all CUSIPs. I would batch these into groups of 50-100 securities per request to stay within rate limits. Third, parse the responses and load into a staging table with a timestamp. Fourth, apply data quality checks: verify all requested CUSIPs returned data, flag any that returned errors (matured securities, invalid identifiers), and validate values are within reasonable ranges. Fifth, merge with internal position data and publish to the curated analytics layer. For historical data, I would use `HistoricalDataRequest` with date ranges and store the time series in a partitioned table. I would schedule the pipeline to run post-market close (after 5 PM ET when end-of-day pricing is finalized) and include retry logic for transient Bloomberg service issues.

### Q4: Explain negative convexity in MBS.

**Answer:** Negative convexity means that as interest rates fall, the price of an MBS increases at a decelerating rate (and may even plateau), unlike a non-callable bond whose price would continue to rise. This happens because falling rates trigger increased prepayments -- borrowers refinance their mortgages at lower rates, returning principal to investors at par. The investor receives par (100) for a pool they may have purchased at a premium (e.g., 103), and must reinvest the returned principal at the now-lower market rates. Conversely, when rates rise, prepayments slow dramatically, and the MBS extends in duration, making it more sensitive to further rate increases. This creates an asymmetric payoff: limited upside when rates fall, amplified downside when rates rise. On Bloomberg, you can see this reflected in the OAC (Option-Adjusted Convexity) being negative for most agency pass-throughs. IO (interest-only) tranches exhibit extreme negative convexity, while PO (principal-only) tranches actually have positive convexity.

### Q5: What is the difference between B-PIPE and Data License?

**Answer:** B-PIPE is Bloomberg's real-time streaming data feed, delivering tick-by-tick price updates, quotes, and trades. It is used for trading applications, real-time risk monitoring, and any system that needs sub-second data delivery. B-PIPE requires dedicated infrastructure (Bloomberg appliances) and is typically consumed by trading desk applications and execution management systems. Data License is Bloomberg's bulk/batch data product for end-of-day and reference data. It delivers comprehensive datasets (pricing, analytics, reference data, index composition) via SFTP or API on a scheduled basis (typically nightly). Data engineers use Data License to populate data warehouses, feed risk systems, and support overnight batch processes. The key distinction: B-PIPE is for real-time, low-latency use cases; Data License is for batch, analytical use cases. In practice, an MBS data pipeline might use B-PIPE for intraday trading analytics and Data License for end-of-day portfolio valuation and reporting.

### Q6: How do you handle Bloomberg data quality issues in a production pipeline?

**Answer:** Bloomberg data quality issues include: missing prices for illiquid securities (common for seasoned non-agency MBS), stale prices (the price has not updated because there is no recent trade), delayed factor updates (agency factors may not be reflected in Bloomberg until mid-month), and field availability differences across security types. My approach is: (1) implement validation rules on every field -- price should be within a historical range (flag if price moves more than 5 points in a day), OAS should be positive for most MBS, CPR should be between 0 and 100. (2) Track data freshness -- compare today's price to yesterday's; if identical for a liquid security, flag as potentially stale. (3) Build fallback logic -- if Bloomberg price is unavailable, use the prior day's price with a stale flag, or source from an alternative vendor. (4) Maintain a data quality dashboard that shows coverage (percentage of positions with valid prices), staleness metrics, and exceptions requiring manual review. (5) Log all Bloomberg API errors and implement alerts for systematic failures (e.g., service outage).

---

## Tips

1. **Learn the terminal keyboard shortcuts.** In interviews, demonstrating fluency with Bloomberg navigation (knowing that `FN AB1234 Mtge BMA <GO>` opens Bloomberg Mortgage Analytics for a specific pool) signals practical experience.

2. **Understand the MBS settlement calendar.** Agency MBS settle on specific dates (PSA settlement dates). Bloomberg's pricing reflects the appropriate settlement date, which affects yield calculations. Know the difference between price for current-month vs. forward settlement.

3. **Know the difference between model and market data.** Bloomberg provides both market-observable data (price, volume) and model-derived data (OAS, projected CPR). Be clear about which fields are model outputs and which are market inputs, as model outputs depend on Bloomberg's assumptions and model version.

4. **Always specify the pricing source.** Bloomberg has multiple pricing sources (BGN, BVAL, TRACE). For MBS, BVAL (Bloomberg Valuation) is commonly used for illiquid securities. Know which source your firm uses and why.

5. **Cache aggressively, refresh strategically.** Bloomberg API calls have cost and rate implications. Cache reference data that changes infrequently (WAC, WAM, origination date) and refresh only pricing and analytics daily.

6. **Test with known securities.** When building a Bloomberg data pipeline, validate your extraction against manually checked values on the terminal. Pull up the same pool on the terminal and verify that your API-extracted OAS, price, and CPR match what is displayed.

7. **Understand Bloomberg field mnemonics.** Bloomberg fields are identified by mnemonic codes (e.g., `PX_LAST` for last price, `OAS_SPREAD_MID` for OAS, `MTG_WAC` for weighted average coupon). Maintain a mapping document of all fields used in your pipeline with their definitions and data types.

8. **For interviews, connect Bloomberg to the bigger picture.** Explain how Bloomberg data fits into the overall analytics architecture: Bloomberg provides the valuation and analytics engine, CoreLogic provides loan-level collateral data, and eMBS provides agency disclosure data. A senior data engineer integrates all three.
