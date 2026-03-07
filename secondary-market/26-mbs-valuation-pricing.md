# MBS Valuation & Pricing

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Yield Calculation for MBS

Unlike traditional bonds with fixed cash flows, MBS yield calculations must account for uncertain prepayment behavior. The yield on an MBS is the discount rate that equates the present value of projected cash flows (principal, interest, and prepayments) to the current market price. Because cash flows depend on a prepayment assumption (e.g., a specific CPR or PSA speed), the yield is always stated **given** that assumption.

**Cash Flow Yield (CFY)** is the internal rate of return on the projected MBS cash flows, typically computed on a monthly compounding basis. To compare with semiannual bond yields, the CFY must be converted to a **bond-equivalent yield (BEY)**:

```
BEY = 2 * [(1 + monthly CFY)^6 - 1]
```

Cash flow yield has three reinvestment assumptions baked in:
1. The projected cash flows are actually received (prepayment model is correct).
2. Cash flows are reinvested at the CFY rate.
3. The investor holds the MBS until the final projected cash flow.

### Nominal Spread

The **nominal spread** (or static spread) is the difference in basis points between the MBS cash flow yield and the yield of an interpolated-maturity Treasury benchmark (usually the on-the-run Treasury matching the MBS weighted-average life). It is the simplest spread measure but has significant limitations:

- It uses a single discount rate rather than the full term structure.
- It does not account for the option cost embedded in the MBS (the borrower's prepayment option).
- It changes as the prepayment assumption changes.

### I-Spread (Interpolated Spread)

The **I-spread** measures the difference between the MBS yield and the swap rate (or Treasury rate) interpolated to the same maturity point on the curve. It is a market-convention measure for relative value but, like nominal spread, ignores optionality.

### Z-Spread (Zero-Volatility Spread)

The **Z-spread** is the constant spread added to each point on the benchmark zero-coupon (spot) curve that makes the present value of the MBS projected cash flows equal to the market price. It improves upon the nominal spread by using the entire term structure rather than a single point.

```
Price = SUM [ CF(t) / (1 + z(t) + Z-spread)^t ]
```

Where `z(t)` is the Treasury (or swap) spot rate for period `t` and `CF(t)` is the projected cash flow at time `t`.

**Limitation:** The Z-spread still uses a single prepayment path. It does not capture the value of the prepayment option.

### OAS (Option-Adjusted Spread)

The **option-adjusted spread (OAS)** is the gold-standard valuation measure for MBS. It is derived from a Monte Carlo simulation that generates hundreds or thousands of interest rate paths, models prepayment behavior along each path, and discounts the resulting cash flows. The OAS is the constant spread added to each simulated path's discount rates such that the average present value across all paths equals the market price.

```
Price = (1/N) * SUM_paths [ SUM_t CF(path, t) / (1 + r(path, t) + OAS)^t ]
```

Key relationships:
- **Z-spread = OAS + Option Cost**
- When OAS > Z-spread, the option has negative cost (rare; occurs for certain IO strips).
- For premium MBS (coupon > current market rate), option cost is large, so OAS << Z-spread.
- For discount MBS, option cost is small, so OAS is closer to Z-spread.

**Monte Carlo Process for OAS:**
1. Generate risk-neutral interest rate paths using a term structure model (e.g., Hull-White, BDT, LIBOR Market Model).
2. For each path, project month-by-month prepayment rates using a prepayment model (e.g., Andrew Davidson, BlackRock, Yield Book).
3. Calculate monthly cash flows (scheduled principal, interest, prepayments) on each path.
4. Discount cash flows back using path-specific short rates plus OAS.
5. Average the present values across all paths.
6. Solve for the OAS that equates the average PV to the observed market price.

### Negative Convexity

MBS exhibit **negative convexity** because of the embedded prepayment option held by the borrower. When interest rates fall, borrowers refinance, returning principal at par and capping the price appreciation of the MBS. When rates rise, prepayments slow and the MBS extends, amplifying price declines.

The price/yield profile of an MBS looks like an inverted "S" compared to an option-free bond's convex curve. At low yields, the MBS price is "compressed" toward par (or slightly above), while at high yields, the MBS underperforms due to extension.

**Implications for investors:**
- MBS holders are short a call option to borrowers.
- MBS underperform in rallies (price compression) and underperform in sell-offs (extension).
- Negative convexity means hedging costs are higher; the hedge must be rebalanced more frequently.

### Current Coupon and Par Coupon

- **Current coupon** is the coupon rate on a hypothetical new-production MBS that would trade at par. It is derived by interpolating between the prices of TBA coupons above and below par.
- **Par coupon** is sometimes used interchangeably but can also refer to the note rate on the mortgage (current coupon + servicing fee + guarantee fee).
- The current coupon rate is a critical benchmark; the spread of the current coupon MBS yield to the 10-year Treasury or 5/10 blend is the **primary/secondary spread** indicator.

### TBA Pricing

**To-Be-Announced (TBA)** is the dominant trading convention for agency MBS. In a TBA trade, only six parameters are agreed upon at trade time:

1. Agency (Fannie Mae, Freddie Mac, Ginnie Mae)
2. Maturity (e.g., 30-year, 15-year)
3. Coupon
4. Face amount
5. Price
6. Settlement date

The actual pools to be delivered are not specified until 48 hours before settlement (the "48-hour rule"). TBA prices are quoted in points and 32nds of face value (e.g., 101-16 means 101 and 16/32nds = 101.50% of par).

**Dollar rolls** are the financing mechanism for TBAs — essentially a simultaneous sale of a TBA for one settlement month and repurchase for the next month. The price difference (the "drop") reflects carry and the value of cheapest-to-deliver optionality.

### Specified Pool Pay-Ups

**Specified pools** trade at a premium ("pay-up") over TBA prices because they have characteristics that make them less likely to prepay (reducing the negative impact of the prepayment option). Common pay-up stories include:

| Story | Description | Why It Pays Up |
|-------|-------------|----------------|
| Low Loan Balance (LLB) | Pools with avg loan balance < $150K-$200K | Fixed refinancing costs are high relative to savings |
| New York/PR/GU | Pools from high-cost or slow-processing states | Higher taxes, longer timelines slow refinancing |
| High LTV | Loans with LTV > 80% at origination | Harder to refinance without equity |
| Low FICO | Borrowers with lower credit scores | Less likely to qualify for refinancing |
| Investor Property | Non-owner-occupied loans | Less rate-sensitive borrowers |
| Seasoned | Older pools that have self-selected for slow prepayers | Burnout effect |
| Max Loan Size | Loans near the conforming limit | Already have favorable rates |

Pay-ups are quoted in ticks (32nds) over TBA. For example, a low-balance specified pool might trade at "8 up" meaning 8/32nds (0.25 points) above the TBA price.

### Pricing in 32nds and Basis Points

MBS are quoted in points and 32nds (and sometimes 64ths, 128ths, or 256ths):
- **101-16** = 101 + 16/32 = 101.500
- **101-16+** = 101 + 16.5/32 = 101.515625 (the "+" means an additional half-tick)
- **101-163** = 101 + 16.375/32 ≈ 101.51171875 (trailing digit is 8ths of a 32nd)

Spread measures are quoted in **basis points (bps)**, where 1 bp = 0.01%.

### Bloomberg Pricing Fields (Common)

| Bloomberg Field | Description |
|----------------|-------------|
| PX_LAST | Last traded price |
| PX_MID | Mid price (bid/ask average) |
| YAS_OAS_SPREAD | OAS from Bloomberg's YAS function |
| YAS_ZSPREAD | Z-spread |
| OAS_SPREAD_BID / OAS_SPREAD_ASK | OAS at bid and ask prices |
| WAL | Weighted average life |
| MTG_CASH_FLOW_YLD | Cash flow yield |
| DURATION / OAD | Option-adjusted duration |
| CONVEXITY / OAC | Option-adjusted convexity |
| CPR_VECTOR | Prepayment speed (CPR) assumption |
| PREPAY_SPEED_PSA | PSA prepayment speed |

Bloomberg functions: **YAS** (Yield & Spread Analysis), **OAS1** (OAS Calculator), **CFLOW** (Cash Flow Projections), **TBA** (TBA Monitor), **MTGE** (Mortgage Securities Menu).

---

## Real-World Examples

### Example 1: Comparing Spread Measures

A FNMA 30-year 4.0% MBS is priced at 101-08 (101.25) with a WAL of 6.2 years at 165 PSA.

| Spread Measure | Value | Benchmark |
|---------------|-------|-----------|
| Nominal Spread | +112 bps | 7-year Treasury |
| Z-Spread | +108 bps | Treasury spot curve |
| OAS | +42 bps | Treasury spot curve (Monte Carlo) |
| Option Cost | +66 bps | Z-spread minus OAS |

The 66 bps option cost reflects the value of the homeowner's prepayment option. An investor comparing this to a corporate bond at Z+100 must recognize that the MBS's 108 bps Z-spread overstates its true compensation because 66 bps "pays" for the option the investor is short.

### Example 2: TBA Dollar Roll Economics

A trader sells FNMA 30yr 5.0 for March settlement at 102-24 and buys for April settlement at 102-16. The drop is 8/32 = 0.25 points. This implies a financing rate; if that implied rate is below the repo rate, the roll is "trading special" and it is cheaper to finance via dollar roll than repo.

### Example 3: Specified Pool Valuation

A portfolio manager evaluates a FNMA 30yr 3.5% specified pool of low-loan-balance loans (avg $110K). The TBA price is 98-00. The specified pool trades at 98-12, a pay-up of 12 ticks (12/32 = 0.375 points). The manager must determine if the prepayment protection justifies the premium by modeling the pool under various rate scenarios and comparing the OAS to TBA.

---

## Common Interview Questions & Answers

### Q1: What is the difference between Z-spread and OAS? Why does it matter for MBS?

**Answer:** The Z-spread is the constant spread over the entire spot curve that discounts a single set of projected cash flows to the market price. It uses one prepayment assumption and ignores the borrower's option to prepay. The OAS uses Monte Carlo simulation to generate many interest rate paths, models prepayments dynamically on each path, and finds the spread that equates the average PV across all paths to the price. The difference (Z-spread minus OAS) equals the option cost. For MBS, this distinction is critical because the prepayment option can be worth 50-100+ bps, meaning Z-spread dramatically overstates the true risk-adjusted compensation. OAS is the appropriate measure for comparing MBS to other fixed-income instruments.

### Q2: Why do MBS exhibit negative convexity? How does this affect pricing?

**Answer:** MBS are negatively convex because the investor is short a call option (the borrower's right to prepay). When rates fall, prepayments accelerate and cap price upside — the MBS price converges toward par as borrowers refinance. When rates rise, prepayments slow and the bond extends, magnifying price declines. This creates a concave price/yield profile. For pricing, investors demand a higher OAS (more spread) to compensate for negative convexity, and hedging costs are elevated because the duration changes adversely in both rate directions.

### Q3: Explain the Monte Carlo simulation used in OAS calculation.

**Answer:** The process involves: (1) Calibrating a short-rate or forward-rate model to the current term structure and volatility surface. (2) Generating thousands of risk-neutral interest rate paths using random draws. (3) On each path, running a prepayment model month by month that responds to the rate environment (incentive to refinance, burnout, seasonality, etc.). (4) Computing monthly cash flows along each path. (5) Discounting each path's cash flows using that path's short rates plus a trial spread. (6) Averaging the PVs across all paths. (7) Iterating on the spread (using Newton-Raphson or bisection) until the average PV equals the market price. That spread is the OAS.

### Q4: What is a TBA, and why is it important for MBS pricing?

**Answer:** A TBA (To-Be-Announced) is a forward contract to buy or sell agency MBS where the specific pools are not identified until shortly before settlement. TBAs provide liquidity, price discovery, and a benchmark for the MBS market. They also enable the "originate-to-distribute" model: lenders hedge pipeline risk by selling TBAs forward. TBA pricing creates the cheapest-to-deliver dynamic — the seller delivers the worst pools (highest expected prepayments), which the TBA price reflects. Specified pools with favorable prepayment characteristics trade at a pay-up over TBA precisely because they would not be delivered into a TBA contract.

### Q5: How would you calculate the pay-up breakeven for a specified pool?

**Answer:** The pay-up breakeven is the prepayment speed at which the specified pool's return equals the TBA's return over a given horizon. Start with the specified pool's higher dollar price and the TBA price, then model cash flows under various prepayment scenarios. The breakeven CPR is where the additional carry from slower prepayments exactly offsets the extra price paid upfront. If the pool is expected to prepay slower than breakeven, the pay-up is justified. This is typically done by running the specified pool and TBA through an OAS model and comparing option-adjusted returns or by computing the breakeven speed directly from a horizon total return analysis.

### Q6: What does it mean when a dollar roll is "trading special"?

**Answer:** A dollar roll trades "special" when the implied financing rate from the roll transaction is below general collateral repo rates. This means it is cheaper to finance a long MBS position via dollar roll (selling front month, buying back month) than through repo. Rolls trade special when there is high demand for the specific TBA coupon (e.g., for settlement fails, Fed purchases, or dealer short covering). When a roll is special, holders of that coupon benefit from the favorable financing, and the roll value should be factored into total return calculations.

---

## Tips

- **Always clarify the prepayment assumption** when discussing MBS yields. A yield number is meaningless without knowing the CPR or PSA speed used.
- **OAS is the only apples-to-apples comparison** between MBS and other fixed-income sectors. Never compare Z-spreads of MBS to Z-spreads of non-callable corporate bonds.
- **Understand the hierarchy:** Nominal spread is the roughest measure, Z-spread accounts for curve shape, OAS accounts for both curve shape and optionality.
- **Know your 32nds math cold.** Interviewers will expect you to convert between decimal and 32nds pricing instantly. Practice: 101-24+ = 101 + 24.5/32 = 101.765625.
- **For data engineering interviews,** be prepared to discuss how OAS and other spread measures flow from analytics engines (Bloomberg, Intex, Yield Book) into databases, how pricing snapshots are stored (which fields, timestamps, settlement dates), and how to build time series of spread measures.
- **Dollar roll economics** come up frequently; understand that TBA pricing, roll value, and specified pool pay-ups are all interconnected.
- **Negative convexity** is arguably the single most important concept distinguishing MBS from other bonds. Be ready to draw the price/yield curve and explain the asymmetric behavior.
