# TBA Market & Delivery Mechanics

[Back to Secondary Market Index](./README.md)

---

## Overview

The TBA (To-Be-Announced) market is the most liquid and critical trading mechanism for agency mortgage-backed securities (MBS) in the United States. It functions as a forward market where buyers and sellers agree on the general characteristics of pools to be delivered at a future settlement date, but the specific pool identities are not disclosed until shortly before settlement. The TBA market provides essential liquidity for mortgage originators, enabling them to hedge pipeline risk and lock rates for borrowers well before loans close and are securitized.

---

## Key Concepts

### 1. TBA Structure and Forward Settlement

A TBA trade is essentially a forward contract on agency MBS. The seller agrees to deliver a pool (or pools) of agency pass-through securities to the buyer on a specified future settlement date. Because the exact pools are not identified at trade time, TBA trades allow fungibility among pools that meet the agreed-upon parameters.

- **Forward nature**: TBA trades typically settle one to three months forward, though the most actively traded settlement is the next upcoming month.
- **Market participants**: Mortgage originators use TBA sales to hedge pipeline risk; broker-dealers provide market-making; asset managers and REITs are active buyers; the Federal Reserve has historically been a major participant.
- **Liquidity**: The TBA market trades approximately $200-300 billion in notional volume per day, making it one of the most liquid fixed-income markets globally.

### 2. The Six Parameters

Every TBA trade is defined by exactly six parameters agreed upon at execution:

| Parameter | Description | Example |
|-----------|-------------|---------|
| **Agency / Issuer** | Fannie Mae (FNMA), Freddie Mac (FHLMC), or Ginnie Mae (GNMA) | FNMA |
| **Maturity / Term** | Original loan term, typically 15-year or 30-year | 30-year |
| **Coupon** | The pass-through coupon rate on the MBS | 5.0% |
| **Price** | The agreed dollar price per $100 of face value | 101-16 (101 and 16/32nds) |
| **Par Amount (Face)** | The total face value of the trade | $10 million |
| **Settlement Date** | The specific future date for delivery and payment | March 12, 2026 |

Everything else -- the actual pools, number of loans, WAC, WAM, WALA, geographic distribution -- is unknown until pool allocation.

### 3. Good Delivery Guidelines (SIFMA)

The Securities Industry and Financial Markets Association (SIFMA) publishes the **Uniform Practices for the Clearance and Settlement of Mortgage-Backed Securities**, which define good delivery rules. These ensure standardization and fungibility across TBA-eligible pools.

**Key good delivery requirements include:**

- **Variance (Tolerance)**: The delivered face amount must be within +/- 0.01% (one basis point) of the agreed par amount per million. In practice, SIFMA allows a delivery variance of +/- 0.01% per pool but the total delivery must be within a specified tolerance of the trade face amount. The commonly cited rule is that delivery must be within **+/- 2.499999%** of the trade amount (i.e., for a $1 million trade, the delivered face can range from $975,000.01 to $1,024,999.99).
- **Pool count limits**: The maximum number of pools that can be delivered per $1 million of face amount is limited (typically 3 pools per million for fixed-rate TBAs).
- **48-hour rule**: The seller must notify the buyer of the specific pools being delivered by 3:00 PM ET, two business days prior to the settlement date (the "48-hour day" or "notification day").
- **Eligible pools**: Only pools meeting the agency's standard program criteria for the specified coupon and term are deliverable.

### 4. Variance

Variance refers to the permissible difference between the agreed trade face amount and the actual face amount delivered:

- **Purpose**: Because MBS pools have specific face amounts that rarely match a round trade size exactly, variance allows practical settlement.
- **Calculation**: If a trade is for $5,000,000 face at a price of 101-00, and the seller delivers $5,100,000 face (within variance), the buyer pays the agreed price applied to the actual delivered amount: $5,100,000 x 1.03125 = $5,259,375 plus accrued interest.
- **Cost of carry**: Variance creates a slight over- or under-delivery, and the economic impact depends on whether the security is at a premium or discount.

### 5. Stipulated Trades (Stips)

Stipulated trades add additional constraints beyond the six standard TBA parameters. Common stipulations include:

| Stipulation | Description |
|-------------|-------------|
| **Loan balance** | Max original loan balance (e.g., max $200K, max $150K) |
| **Geography** | Specific state concentrations (e.g., NY-heavy, CA-heavy) |
| **Loan count** | Minimum number of loans in the pool |
| **FICO** | Minimum weighted-average credit score |
| **LTV** | Maximum weighted-average LTV |
| **Seasoning** | WALA constraints (e.g., newly originated only) |
| **Loan purpose** | Purchase-only or refi-only pools |

Stipulated trades typically command a **pay-up** over TBA prices because the buyer is receiving pools with more favorable prepayment characteristics.

### 6. Specified Pools

Specified pool trading is the opposite end of the spectrum from generic TBA trading. The buyer knows exactly which pool(s) they are purchasing, including all loan-level characteristics.

- **Pay-ups**: Specified pools trade at a premium (pay-up) relative to TBA prices, reflecting their superior convexity or prepayment protection.
- **Common specified pool stories**:
  - Low loan balance (LLB): Pools with low average loan sizes prepay slower because fixed refinancing costs are proportionally higher.
  - High LTV: Borrowers with less equity are less likely to refinance.
  - New York / Puerto Rico: States with high mortgage recording taxes discourage refinancing.
  - Investor properties: Lower refinance incentive.
  - Low FICO: Borrowers may have less access to refinancing.
- **Data engineering relevance**: Tracking pay-ups requires maintaining pool-level characteristic databases, often sourced from eMBS, agency disclosures, or proprietary analytics platforms.

### 7. Dollar Rolls

A dollar roll is a financing transaction specific to the MBS market. It is economically similar to a repo but involves the TBA market:

- **Mechanics**: The holder of MBS sells a TBA position for one settlement month and simultaneously buys back a TBA position for a later settlement month (same coupon and term).
- **Drop**: The price difference between the front month and the back month is called the "drop." The drop reflects: (a) foregone coupon and principal payments, (b) reinvestment of those cash flows, and (c) financing cost.
- **Implied financing rate**: The drop can be converted into an implied financing rate. When the implied rate is lower than alternative repo rates, dollar rolls are "special" and attractive for holders.
- **Accounting**: Under GAAP, dollar rolls may be treated as financing transactions or as paired trades (sale + purchase) depending on whether the same pools are expected to be returned.

**Dollar Roll Example:**
- Sell FNMA 30yr 5.0% for March settlement at 101-16
- Buy FNMA 30yr 5.0% for April settlement at 101-04
- Drop = 12/32nds = 0.375 points
- The seller collects March principal and interest; the drop compensates the buyer for missing those cash flows

### 8. TBA Pricing

TBA prices are quoted in 32nds (and sometimes 64ths or 256ths) of a point:

- **Example**: 101-16 means 101 and 16/32nds = 101.50 per $100 face
- **Example**: 99-24+ means 99 and 24.5/32nds = 99.765625 per $100 face (the "+" adds 1/64th)
- **Factors affecting TBA price**: Prevailing interest rates, expected prepayment speeds, yield spread to Treasuries, supply/demand dynamics, and the cheapest-to-deliver option value.

### 9. Settlement Dates

SIFMA publishes a monthly **notification and settlement calendar** for TBA trades:

- Settlement dates are specific to each product class (GNMA I, GNMA II, Fannie 30yr, Freddie 30yr, Fannie 15yr, etc.).
- Each class settles on a designated business day, generally mid-month.
- The 48-hour notification day is two business days before the settlement date.
- Settlement occurs via the Fed's Fedwire Securities Service (for GNMA) or through the Fixed Income Clearing Corporation (FICC) for conventional MBS.

### 10. Cheapest-to-Deliver (CTD)

Because TBA trades allow the seller to deliver any eligible pool, the seller has an embedded delivery option similar to Treasury futures:

- **CTD concept**: The rational seller will deliver the pools that are least valuable -- those with the worst prepayment characteristics (fastest expected prepayments for premium coupons, slowest for discount coupons).
- **Premium coupons**: Sellers deliver pools with the highest prepayment risk (high FICO, low LTV, high loan balance, rate-term refis) because these pools are worth less to the buyer.
- **Discount coupons**: Sellers deliver pools with the slowest prepayments (extension risk) because these are least desirable.
- **Impact on TBA pricing**: The CTD dynamic depresses TBA prices relative to a theoretical average pool, creating the economic basis for specified pool pay-ups.
- **Data engineering implication**: CTD analysis requires modeling prepayment speeds for various pool cohorts and comparing their present values at current OAS levels.

### 11. Pool Allocation

Pool allocation is the process by which the seller identifies the specific pools for delivery:

- **FICC's EPN (Electronic Pool Notification)**: The standard electronic system for submitting pool allocations for TBA trades clearing through FICC.
- **Allocation timing**: Must occur by 3:00 PM ET on the 48-hour day.
- **Pool factors**: Each pool has a current factor (remaining principal as a fraction of original face) that determines the actual current face. Delivered face = original face x factor.
- **Reconciliation**: Buyers must verify that allocated pools meet good delivery requirements (pool count, variance, eligibility).

---

## Real-World Examples

### Example 1: Mortgage Originator Hedging

A mortgage lender locks $50 million in 30-year fixed-rate mortgages at 5.25% for borrowers. To hedge the pipeline:

1. The lender sells $50 million FNMA 30yr 5.0% TBA for forward settlement.
2. As loans close over the next 60 days, they are delivered to Fannie Mae for securitization.
3. The resulting FNMA pools are used to satisfy the TBA delivery obligation.
4. If rates rise, the TBA short position gains value, offsetting the decline in pipeline value.

### Example 2: Dollar Roll Financing

An asset manager holds $100 million of FNMA 30yr 4.5% MBS. Rather than financing via repo:

1. Sells $100 million FNMA 4.5% TBA for February settlement at 98-20.
2. Buys $100 million FNMA 4.5% TBA for March settlement at 98-08.
3. Drop = 12/32nds. The implied financing rate is calculated to be 2.8%, compared to 3.1% in MBS repo.
4. The roll is "special" by 30 bps, making it an attractive financing alternative.

### Example 3: CTD Impact on Data Engineering

A trading desk asks the data engineering team to build a CTD analysis pipeline:

1. Ingest daily pool-level data from eMBS and agency disclosures.
2. Compute weighted-average characteristics (FICO, LTV, loan size, servicer) for each TBA-eligible pool.
3. Run prepayment models to project speeds for each pool at current rates.
4. Calculate the present value of each pool and rank them to identify the cheapest-to-deliver cohort.
5. Report the CTD pool characteristics and the implied pay-up for non-CTD specified pool stories.

---

## Common Interview Questions & Answers

### Q1: What is a TBA trade and why is it important for mortgage markets?

**A:** A TBA trade is a forward contract to buy or sell agency MBS where the specific pools are not identified until two days before settlement. It is critical because it provides liquidity for mortgage originators to hedge their pipeline risk, enables price discovery for agency MBS, and allows the mortgage market to function efficiently. The TBA market's deep liquidity (hundreds of billions per day) keeps mortgage rates lower than they would otherwise be by reducing the risk premium originators must charge.

### Q2: What are the six parameters of a TBA trade?

**A:** The six parameters are: (1) Agency/issuer (Fannie, Freddie, or Ginnie), (2) maturity/term (e.g., 30-year, 15-year), (3) coupon rate, (4) price, (5) par amount/face value, and (6) settlement date. These are the only characteristics agreed upon at trade execution; everything else about the underlying pools remains unspecified until allocation.

### Q3: Explain the cheapest-to-deliver concept in TBA trading.

**A:** Since the TBA seller can deliver any eligible pool, they will rationally deliver the least valuable pools. For premium coupons (above par), the cheapest-to-deliver pools are those expected to prepay fastest (high FICO, low LTV, high loan balance, rate-term refis), because fast prepayments on premium securities destroy value. For discount coupons, CTD pools are those expected to prepay slowest (extension risk). This delivery option depresses TBA prices relative to average pools, creating the pay-up basis for specified pool trading.

### Q4: How does a dollar roll work, and when is it attractive?

**A:** A dollar roll involves selling MBS for near-month TBA settlement and simultaneously buying for a later month at a lower price. The price difference (drop) compensates the buyer for missing one month of principal and interest. The drop can be converted to an implied financing rate. When this implied rate is below the prevailing repo rate, the roll is "special" and represents cheap financing for the MBS holder. Dollar rolls are particularly attractive in environments where the Fed is actively purchasing MBS, suppressing the implied financing rate.

### Q5: What is the SIFMA 48-hour rule?

**A:** The 48-hour rule requires TBA sellers to notify buyers of the specific pools being delivered no later than 3:00 PM ET two business days before the settlement date. This is done electronically through FICC's Electronic Pool Notification (EPN) system. The rule gives buyers time to verify that the allocated pools meet good delivery guidelines before settlement.

### Q6: As a data engineer, how would you build a system to track specified pool pay-ups?

**A:** I would build a pipeline that: (1) Ingests daily TBA pricing from market data vendors (e.g., Tradeweb, Bloomberg) as the baseline. (2) Ingests specified pool trade data with attributes (loan balance bucket, geography, LTV, FICO, etc.). (3) Computes pay-ups as the difference between specified pool trade prices and interpolated TBA prices for the same coupon. (4) Stores time series of pay-ups by story type and coupon in a structured data warehouse. (5) Provides analytics dashboards showing pay-up trends by story, seasonal patterns, and relative value. (6) Joins pool-level characteristic data from agency disclosures to enable drill-down into pool attributes driving the pay-up.

### Q7: What are good delivery variance rules and why do they matter?

**A:** SIFMA good delivery rules allow the delivered face amount to vary by approximately +/- 2.5% from the agreed trade amount, and limit the number of pools to generally 3 per $1 million face. These rules matter because MBS pools have irregular face amounts that rarely match round trade sizes. Without variance tolerance, settlement would be impractical. For data engineers, variance calculations are essential in trade settlement systems -- you need to validate that proposed allocations fall within tolerance and calculate the correct settlement amount based on actual delivered face.

### Q8: What is the difference between a TBA trade and a specified pool trade?

**A:** In a TBA trade, the buyer only knows the six parameters (agency, term, coupon, price, face, settlement date) and must accept any eligible pool the seller delivers. In a specified pool trade, the buyer selects and agrees to receive a specific pool with known characteristics (CUSIP, WAC, WAM, WALA, loan count, geography, etc.). Specified pools trade at pay-ups over TBA because they typically have better prepayment protection. TBA trades are more liquid and standardized; specified pools offer customization but less liquidity.

---

## Tips

1. **Understand the economics**: In interviews, demonstrating that you understand *why* the TBA market exists (originator hedging, liquidity provision) is as important as knowing the mechanics.

2. **Know the data flows**: Be prepared to discuss how TBA trade data flows from execution (TradeWeb, Bloomberg) through allocation (FICC/EPN) to settlement (Fedwire/FICC), and where data engineering fits at each stage.

3. **Connect CTD to prepayment models**: The cheapest-to-deliver concept links trading mechanics to prepayment analytics. Show that you understand both sides.

4. **Dollar roll math**: Practice calculating implied financing rates from dollar roll drops. This is a common quantitative question.

5. **SIFMA calendar awareness**: Know that settlement dates vary by product class and that SIFMA publishes the official calendar. This is a detail that separates candidates with real MBS experience.

6. **Data engineering angle**: Emphasize your ability to build systems that handle the unique aspects of MBS data -- pool factors that change monthly, 48-hour notification workflows, variance validation, and pay-up tracking across multiple story types.

7. **Regulatory context**: Be aware that FICC central clearing of TBA trades is a major infrastructure component, and that margin requirements for TBA trades increased post-2008 under FICC's rules.

---
