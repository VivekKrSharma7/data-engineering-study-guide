# Interest Rate Risk & Hedging

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Types of Risk in MBS

MBS portfolios face several distinct categories of interest rate and related risks:

#### Extension Risk

**Extension risk** is the risk that prepayments slow more than expected, causing the MBS weighted-average life and duration to lengthen. This typically occurs when rates rise. Extension risk is most acute for:

- **Discount MBS** (coupon below current market rates): Borrowers have no incentive to refinance, so prepayments are driven only by housing turnover, which also slows in rising-rate environments.
- **Seasoned premium MBS** with burnout: Even though the coupon is above market, the remaining borrowers have demonstrated insensitivity to refinancing incentives.

**Consequences of extension:**
- Duration increases, amplifying losses in a rising-rate environment.
- Reinvestment of cash flows occurs at higher rates (partial offset), but the principal is locked up longer.
- Portfolio duration targets are breached, requiring rebalancing.
- For banks, the ALM mismatch between assets (extending MBS) and liabilities (potentially shorter-duration deposits) widens.

#### Contraction Risk

**Contraction risk** is the opposite of extension — the risk that prepayments accelerate faster than expected, shortening the MBS life. This occurs when rates fall. Contraction risk is worst for:

- **Premium MBS** (coupon above current market rates): Borrowers have a strong financial incentive to refinance.
- **Newly originated pools** without burnout.
- **Pools with favorable prepayment characteristics** (high loan balances, high FICO, states with low transaction costs).

**Consequences of contraction:**
- Principal is returned at par, capping price appreciation.
- Reinvestment occurs at lower prevailing rates ("reinvestment risk").
- Duration shortens, reducing the portfolio's ability to benefit from the rally.

#### Prepayment Risk

**Prepayment risk** encompasses both extension and contraction risk. It is the uncertainty about the timing and amount of cash flows due to voluntary and involuntary prepayments. Key drivers:

- Refinancing incentive (the spread between the borrower's note rate and current market rates).
- Housing turnover (driven by the economy, demographics, home prices).
- Borrower characteristics (FICO, LTV, loan age, geography).
- Seasonality (prepayments peak in summer months).
- Policy changes (HARP, streamline refis, changes in GSE fees).

#### Basis Risk

**Basis risk** is the risk that the hedge instrument moves differently than the hedged MBS position. Sources include:

- **MBS/Treasury basis:** The spread between MBS and Treasuries can widen or tighten, causing hedging losses even if the rate level moves as expected.
- **Swap spread risk:** If hedging with swaps, the swap spread relative to Treasuries can change.
- **Coupon basis:** Different MBS coupon stacks can move by different amounts during a rate shock.
- **Convexity-driven basis:** MBS prices respond differently to rate changes than the linear hedge instrument (Treasury or swap).
- **Roll basis:** TBA roll values can change, affecting the carry of hedged positions.

Basis risk can be reduced but rarely eliminated entirely. It is one of the most underappreciated risks in MBS portfolio management.

### Hedging Instruments

#### Treasuries

- **Most common hedge** for MBS interest rate risk.
- Available across the curve (2Y, 3Y, 5Y, 7Y, 10Y, 20Y, 30Y).
- Highly liquid and transparent.
- **Limitation:** Treasuries have positive convexity, while MBS have negative convexity. Hedging MBS with Treasuries creates a residual short-convexity position.
- **Implementation:** Short Treasuries (or Treasury futures) against long MBS.

#### Interest Rate Swaps

- **Pay-fixed, receive-floating swaps** serve the same hedging function as shorting Treasuries.
- Advantages: No upfront cash outlay (unlike shorting a bond), customizable maturity, efficient use of capital.
- Common maturities: 2Y, 5Y, 7Y, 10Y swaps.
- Post-2022, swaps reference SOFR rather than LIBOR.
- **Cross-currency basis** can be a factor for non-USD hedging.

#### Swaptions

- **Options on interest rate swaps.** Buying a payer swaption (right to pay fixed) profits when rates rise.
- **Critical for hedging negative convexity.** Buying swaptions adds positive convexity (gamma) to offset the negative convexity of the MBS.
- Common structures:
  - **Payer swaptions** to hedge extension risk (rates up).
  - **Receiver swaptions** to hedge contraction risk (rates down).
  - **Straddles or strangles** to hedge both directions.
- **Cost:** Swaptions require paying an upfront premium, which is a direct drag on portfolio return. The trade-off between premium cost and convexity protection is a core portfolio management decision.

#### Caps and Floors

- **Interest rate caps:** Pay off when a reference rate (SOFR) exceeds a strike rate. Used to hedge floating-rate MBS or ARMs against rate increases.
- **Interest rate floors:** Pay off when the reference rate falls below a strike. Less common for MBS hedging.
- Caps are a series of caplets, each covering one reset period.

#### Futures

- **Treasury futures** (2Y, 5Y, 10Y, Ultra 10Y, Bond, Ultra Bond) are widely used for MBS hedging.
- Advantages: Exchange-traded, high liquidity, margined (capital efficient), precise DV01 matching.
- **Cheapest-to-deliver (CTD)** dynamics affect the hedge ratio because the futures contract's DV01 depends on which Treasury note is CTD.
- **SOFR futures** (3-month and 1-month) can hedge short-end rate exposure.

### Hedge Ratios

The hedge ratio determines how much of the hedging instrument to use:

```
Hedge Ratio = DV01_MBS / DV01_Hedge
```

Where DV01 = Price * Duration * 0.0001 * Notional.

**Example:**
- Long $100M MBS with OAD = 5.2, price = 101.00. DV01 = 101.00 * 5.2 * 0.0001 * $1M = $52,520.
- Hedge with 10Y Treasury (DV01 per $1M = $85). Need to short $52,520 / $85 = $618 * $1M = ~$62M face of 10Y Treasuries.

**Important:** Because MBS duration changes with rates (negative convexity), the hedge ratio must be recalculated and rebalanced regularly. A hedge that is correct today will be wrong after a 50 bp rate move.

### Dynamic Hedging

**Dynamic hedging** (also called delta-gamma hedging) involves continuously rebalancing the hedge as market conditions change. For MBS:

1. **Delta hedging:** Adjust the Treasury/swap hedge to maintain zero net DV01. Required because MBS duration shifts with rates.
2. **Gamma hedging:** Use swaptions or other options to neutralize the convexity mismatch. If MBS has negative convexity of -2 and the swaption has positive convexity of +4, then 50% notional of swaptions neutralizes the gamma.
3. **Vega hedging:** Manage exposure to implied volatility changes. MBS valuations (OAS) are sensitive to assumed volatility.

**Rebalancing frequency** depends on the size of rate moves, the portfolio's convexity, and transaction costs. Many MBS hedge programs rebalance daily, or intraday in volatile markets.

**Path-dependence:** The total cost of dynamic hedging depends on the realized rate path, not just the endpoint. In high-volatility environments, rebalancing costs (buying high, selling low) are higher — this is the realized cost of being short convexity.

### Mortgage Banker Pipeline Hedging

Mortgage originators face a unique hedging problem: they have committed to lending at a specific rate to borrowers (rate locks) but have not yet sold the loans. The **pipeline** consists of rate-locked loans in various stages of processing.

**Pipeline Risk:**
- **Interest rate risk:** If rates rise between rate lock and loan sale, the loan is worth less.
- **Fallout risk:** Not all rate-locked loans close (borrowers can walk away). The pull-through rate (typically 60-90%) must be estimated.
- **Best execution risk:** Choosing between TBA delivery, whole loan sale, or securitization.

**Pipeline Hedging Instruments:**
- **Forward TBA sales:** Sell TBA for future settlement. Most common hedge.
- **Put options on TBAs:** Protect against rate increases while preserving upside if rates fall.
- **Treasury/swap hedges:** For the portion of rate risk not captured by TBAs.

**Pipeline Hedge Ratio:**
```
Hedge Notional = Pipeline Notional * Pull-Through Rate * Hedge Coverage Ratio
```

For example, $200M pipeline with 75% pull-through and 100% hedge coverage: Hedge $150M TBA.

**Mark-to-market:** Pipeline hedging creates daily P&L volatility (hedge gains/losses offset by pipeline value changes). Pipeline mark-to-market is complex because the loans are not yet tradeable securities.

### Servicing Portfolio and MSR Hedging

**Mortgage Servicing Rights (MSRs)** represent the right to collect servicing fees (typically 25 bps/year) on a pool of mortgages. MSRs behave like IO strips:

- **When rates fall:** Prepayments increase, shortening the expected servicing period. MSR value declines.
- **When rates rise:** Prepayments slow, extending the servicing period. MSR value increases.
- **MSRs have negative duration** (typically -3 to -8 years effective duration).

**MSR Hedging Instruments:**
- **Receive-fixed swaps** (or long Treasury positions): Offset the negative duration. When rates fall, the swap gains value as the MSR loses value.
- **Receiver swaptions:** Hedge the nonlinear (convexity) behavior of MSRs. MSR losses accelerate in a rally, so swaptions provide the convex payoff needed.
- **IO strips:** Behave similarly to MSRs and can be used as a partial hedge, though they introduce additional credit/prepayment complexity.
- **Short TBA (forward MBS):** Selling TBAs benefits from rate declines (as rates fall, the TBA buyer gets a below-market coupon). Less precise than swaps for MSR hedging.

**MSR Hedging Challenges:**
- MSR valuation requires a prepayment model, making it model-dependent.
- Basis risk between MSR behavior and swap/Treasury hedges.
- Accounting treatment (LOCOM vs. fair value) affects hedge strategy.
- Large notional positions — a $200B servicing book can have DV01 of $50M+, requiring substantial hedge notionals.
- Rebalancing frequency: Daily in practice, due to large gamma exposure.

### Key Rate Duration Hedging

**Key rate duration (KRD) hedging** decomposes the portfolio's interest rate risk across the curve and hedges each point independently:

**Process:**
1. Compute KRDs for the MBS portfolio at each key rate point (e.g., 2Y, 5Y, 7Y, 10Y, 30Y).
2. Compute KRDs for each available hedge instrument.
3. Solve a system of equations (or optimization) to find the hedge notionals that minimize residual KRD exposure at each point.

**Example:**

| Key Rate | Portfolio KRD ($) | 5Y Swap KRD ($) | 10Y Swap KRD ($) | Required Notional |
|----------|------------------|-----------------|-------------------|-------------------|
| 2Y | +$50K | +$8K per $100M | 0 | Use 2Y instrument |
| 5Y | +$180K | +$95K per $100M | +$5K per $100M | ~$189M 5Y swaps |
| 10Y | +$320K | +$2K per $100M | +$88K per $100M | ~$364M 10Y swaps |

In practice, this is solved using a constrained optimization that minimizes total hedge cost (transaction costs, margin) while keeping residual KRDs within tolerance.

**Advantages:**
- Protects against curve reshaping (steepening, flattening, butterfly).
- More precise than using a single hedge instrument for the total DV01.

**Disadvantages:**
- Requires more instruments and more frequent rebalancing.
- KRDs are model-dependent (different OAS models produce different KRDs).
- Transaction costs increase with the number of hedge instruments.

---

## Real-World Examples

### Example 1: Extension Risk in 2022

In 2022, the Federal Reserve raised rates aggressively (0% to 5.25% Fed Funds in 18 months). MBS duration extended dramatically:

- 30-year FNMA 2.0% MBS: OAD extended from ~4.5 years to ~9.5 years as the coupon moved deep into discount territory and prepayments collapsed to <5 CPR.
- Banks holding these MBS in HTM portfolios (like Silicon Valley Bank) faced massive unrealized losses.
- The OAS of 30-year current coupon widened from ~30 bps to ~70+ bps, compounding price losses.
- Hedged portfolios were partially protected, but basis risk (MBS spreads widening vs. Treasury hedge) created additional losses.

### Example 2: Mortgage Banker Pipeline Hedge

A lender locks $300M in 30-year 6.5% mortgages over a two-week period. The pull-through rate is estimated at 78%. The hedging desk:

1. Sells $234M ($300M x 78%) of FNMA 30yr 6.0% TBA for 60-day settlement (note: hedge coupon is 50 bps below note rate due to servicing/guarantee fee strip).
2. As rate locks are funded (loans close), the pull-through estimate is updated daily and the TBA hedge is adjusted.
3. Loans that close are delivered into the TBA contract or sold as specified pools.
4. If rates rise 25 bps before delivery, the TBA hedge gains ~$2.6M (offsetting the ~$2.6M decline in pipeline value).
5. Fallout risk: If only 70% of locks pull through (instead of 78%), the hedge is over-hedged by $24M, creating a small loss if rates have moved.

### Example 3: MSR Hedging Program

A large servicer has $400B in servicing UPB with an MSR value of $5.2B. The MSR has an effective duration of -5.5 years and convexity of +3.0 (positive convexity because MSR losses accelerate in a rally — similar to long an option on rates).

The hedge portfolio:
- **$22B receive-fixed 7Y swaps:** Neutralizes the duration (-5.5 x $5.2B / 7.0 / 0.0001... approximately calibrated via DV01 matching).
- **$4B 5Y10Y receiver swaptions:** Provides positive convexity to match the MSR's convex profile in a rally.
- **Daily rebalancing:** The desk adjusts swap notionals based on overnight rate moves and updated OAD estimates.
- **Monthly model recalibration:** Prepayment model is updated with latest CPR data, which can shift MSR duration by 0.5-1.0 years.

### Example 4: Dynamic Hedging Cost in a Volatile Market

A fund holds $1B of 30-year FNMA 4.5% MBS hedged with 10Y Treasury shorts. Over a volatile month with 50 bps of total rate movement (rates initially fall 30 bps, then rise 20 bps, net -10 bps):

- Initial hedge ratio: short $560M 10Y Treasuries (matching DV01).
- After rates fall 30 bps: MBS duration shortens from 5.2 to 4.6 years. The desk reduces the Treasury short by $60M to rebalance.
- After rates rise 20 bps: MBS duration extends from 4.6 to 5.0 years. The desk increases the Treasury short by $40M.
- Net result: The fund sold Treasuries after they rallied (locking in a loss) and bought Treasuries after they sold off (again at a loss). This is the **realized cost of hedging negative convexity** — estimated at ~$1.5M for the month.

This cost would have been avoided (or hedged separately) by owning swaptions to offset the gamma.

---

## Common Interview Questions & Answers

### Q1: What is the difference between extension risk and contraction risk?

**Answer:** Extension risk occurs when rates rise and prepayments slow, causing the MBS to extend in duration. The investor is locked into a below-market coupon for longer, and the bond's price declines more than a comparable non-callable bond because of the duration extension. Contraction risk occurs when rates fall and prepayments accelerate, shortening the MBS life. Principal is returned at par, capping price appreciation, and must be reinvested at lower rates. Both are manifestations of the borrower's prepayment option and represent the two sides of negative convexity. The risk that dominates depends on where the MBS coupon sits relative to current rates — premium MBS have more contraction risk, discount MBS have more extension risk.

### Q2: Why can't you perfectly hedge MBS with Treasuries?

**Answer:** Three main reasons. First, **basis risk**: MBS spreads to Treasuries are not constant — they can widen or tighten due to supply/demand, Fed activity, or volatility changes, causing the hedge to gain or lose independently. Second, **convexity mismatch**: Treasuries have positive convexity while MBS have negative convexity, so the price response to rate changes is asymmetric — the Treasury hedge overperforms in one direction and underperforms in the other. Third, **model risk**: The MBS hedge ratio depends on OAD, which is model-derived and can be wrong. To address these gaps, sophisticated hedgers layer in swaptions (for convexity), basis trades, and dynamic rebalancing.

### Q3: How does swaption hedging address negative convexity in MBS?

**Answer:** MBS negative convexity means the investor is short an option (the borrower's prepayment option). Buying swaptions adds long-option (positive gamma/convexity) exposure. A payer swaption profits when rates rise, offsetting the MBS extension losses. A receiver swaption profits when rates fall aggressively, offsetting the scenario where the MBS contraction is most extreme. By buying the right notional and strike of swaptions, the hedger can neutralize the portfolio's convexity, turning the MBS into a more bond-like linear risk profile. The cost is the swaption premium, which is effectively the insurance premium against large rate moves. The decision of how much convexity to hedge is a function of risk appetite, view on volatility, and the premium cost relative to OAS income.

### Q4: Explain mortgage banker pipeline hedging.

**Answer:** Mortgage bankers face interest rate risk between the time they lock a rate with a borrower and the time they sell the loan. If rates rise during this period (typically 30-60 days), the loan is worth less. The primary hedge is selling TBA MBS forward — the TBA short gains value when rates rise, offsetting the pipeline loss. Key complexities include: (1) **Pull-through estimation** — not all rate-locked loans close, so hedging 100% of locks would be over-hedging. The desk models pull-through rates (typically 65-85%) and hedges accordingly. (2) **Coupon mapping** — the TBA coupon is lower than the note rate by the servicing/guarantee fee strip. (3) **Best execution** — deciding whether to deliver into TBA, sell as specified pools (for pay-up), or securitize. (4) **Daily rebalancing** as new locks come in, loans close, and pull-through estimates update.

### Q5: How would you hedge an MSR portfolio? Why is it challenging?

**Answer:** MSRs have negative duration (value rises when rates rise, falls when rates fall) because higher rates slow prepayments and extend the servicing fee stream. The primary hedge is receive-fixed swaps, which gain value when rates fall. However, MSR hedging is uniquely challenging because: (1) MSR value is nonlinear — losses accelerate in a sharp rally, requiring swaption overlays for convexity hedging. (2) MSR valuation is model-dependent, creating model risk in the hedge ratio. (3) MSR basis risk — MSR values can move based on prepayment model updates, originator-specific behavior, or servicing market dynamics unrelated to rate markets. (4) The notionals are enormous — a $300B servicing book might require $20B+ in swap notionals. (5) Accounting treatment matters — under fair value accounting, P&L volatility from MSR and hedge is immediate, requiring precise matching.

### Q6: What is basis risk in MBS hedging, and how do you manage it?

**Answer:** Basis risk is the risk that the MBS position and its hedge move by different amounts, generating unexpected P&L. For MBS, the primary basis risks are: (1) **MBS/Treasury spread** — the OAS or nominal spread between MBS and Treasuries can change, causing the MBS to underperform even if the Treasury hedge captures the rate move. (2) **Coupon basis** — different MBS coupon stacks have different spread and prepayment dynamics. (3) **Roll basis** — TBA dollar roll values can shift. Management approaches include: monitoring basis exposures daily, setting basis risk limits, using MBS-specific hedges (e.g., TBA vs. TBA coupon swaps) alongside rate hedges, diversifying across hedge instruments, and potentially accepting some basis risk as part of the investment thesis (earning the OAS as compensation).

---

## Tips

- **Understand the complete risk taxonomy** for MBS: extension, contraction, prepayment, basis, model, liquidity, and convexity risk. Interviewers often ask you to name and explain each one.
- **Swaption hedging** is a frequent topic in MBS interviews because it directly addresses the most distinctive feature of MBS (negative convexity). Know the difference between payer and receiver swaptions and when each is used.
- **Pipeline hedging** is a specialty topic that demonstrates deep industry knowledge. If you can clearly explain rate lock, pull-through, TBA hedge, and best execution, it signals strong domain expertise.
- **MSR hedging** is another differentiator. Many candidates can discuss MBS hedging but not MSR hedging. Know that MSRs behave like IOs (negative duration) and require receive-fixed swaps plus receiver swaptions.
- **For data engineering interviews,** focus on how hedging data flows: trade capture systems, real-time DV01/KRD calculations, hedge effectiveness reporting, P&L attribution (how much P&L came from the hedge vs. the position vs. basis moves), and regulatory reporting of hedging relationships.
- **Dynamic hedging cost** is the realized cost of being short convexity. Understanding this concept demonstrates quantitative sophistication.
- **The 2022 rate environment** is a topical and powerful real-world example of extension risk, basis widening, and the consequences of inadequate hedging. Reference it in interviews when discussing risk scenarios.
