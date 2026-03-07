# Duration & Convexity for MBS

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### Duration Overview

Duration measures the sensitivity of a bond's price to changes in interest rates. For MBS, duration is more complex than for vanilla bonds because cash flows change as rates move (due to prepayment behavior). Several duration measures exist, each with different assumptions and use cases.

### Macaulay Duration

**Macaulay duration** is the weighted-average time to receipt of cash flows, where each cash flow's weight is its present value as a fraction of total present value.

```
D_mac = SUM [ t * PV(CF_t) ] / Price
```

For MBS, Macaulay duration is computed under a single prepayment scenario and is of limited practical use because it does not capture how cash flows shift when rates change. It is primarily a theoretical building block.

### Modified Duration

**Modified duration** adjusts Macaulay duration to express the percentage price change for a given yield change, assuming cash flows do not change:

```
D_mod = D_mac / (1 + y/k)
```

Where `y` is the yield and `k` is the compounding frequency.

**For MBS, modified duration is flawed** because it holds cash flows constant. When rates change, prepayments change, and so do cash flows. Modified duration systematically overstates the rate sensitivity of premium MBS (where prepayments would increase if rates fall) and understates it for discount MBS.

### Effective Duration (Option-Adjusted Duration / OAD)

**Effective duration** is the correct duration measure for MBS. It measures price sensitivity by explicitly re-pricing the bond when rates shift up and down, allowing cash flows to change with the new rate environment:

```
D_eff = (P_down - P_up) / (2 * P_0 * delta_y)
```

Where:
- `P_down` = price when rates shift down by `delta_y`
- `P_up` = price when rates shift up by `delta_y`
- `P_0` = current price
- `delta_y` = rate shift (typically 25 or 50 bps)

In an OAS framework, the entire Monte Carlo simulation is re-run for both the up and down shifts, holding OAS constant and allowing prepayment models to respond to the new rate paths. This is why effective duration is also called **option-adjusted duration (OAD)**.

**Typical values:**
- 30-year FNMA current coupon: OAD ~ 4.5-6.5 years (vs. ~7-9 for a comparable Treasury)
- 15-year FNMA: OAD ~ 2.5-4.5 years
- MBS OAD is shorter than Treasury duration of similar maturity due to prepayments

### Key Rate Durations (KRDs)

**Key rate durations** decompose a bond's interest rate sensitivity across multiple points on the yield curve (e.g., 6M, 1Y, 2Y, 3Y, 5Y, 7Y, 10Y, 20Y, 30Y). Each KRD measures the price sensitivity to a shift at that specific maturity point, holding all other rates constant.

For MBS, key rate durations are essential because:
- MBS cash flows span a wide maturity spectrum.
- Prepayments create sensitivity concentrations at specific curve points.
- The primary rate driver for prepayments is the 5-year to 10-year part of the curve (where primary mortgage rates are most correlated).
- KRDs enable more precise hedging by matching exposures at each curve point.

**Example KRD profile for a 30-year FNMA 5.0%:**

| Key Rate Point | KRD (years) |
|---------------|-------------|
| 2Y | 0.15 |
| 3Y | 0.40 |
| 5Y | 1.20 |
| 7Y | 1.80 |
| 10Y | 1.50 |
| 20Y | 0.30 |
| 30Y | 0.05 |
| **Total** | **5.40** |

The sum of KRDs equals the total effective duration. The concentration in the 5Y-10Y bucket reflects where mortgage rate sensitivity is greatest.

### Negative Convexity: Why MBS Is Negatively Convex

**Convexity** measures how duration changes as rates change — it is the second derivative of the price/rate relationship. For option-free bonds, convexity is always positive, meaning price gains from rate drops exceed price losses from rate increases of the same magnitude.

MBS have **negative convexity** because:

1. **Rate decrease scenario:** When rates fall, refinancing incentive increases. Borrowers prepay, returning principal at par. The MBS price cannot rise much above par because each refinancing effectively "calls" the loan. Duration shortens (because cash flows accelerate), so just when you want long duration to benefit from a rally, the MBS gets shorter.

2. **Rate increase scenario:** When rates rise, prepayments slow dramatically. The MBS extends — cash flows shift further out. Duration lengthens, so just when you want short duration to limit losses in a sell-off, the MBS gets longer.

This "heads I lose, tails I lose" behavior is the defining characteristic of negative convexity. The MBS investor is short a call option on rates.

**Price/Yield behavior:**

```
Price
  |          Option-free bond
  |         /
  |        /
  |       /  ...MBS price (capped)
  |      /.-'
  |     /.'
  |    /'
  |   /
  |  /
  | /
  |/
  +--------------------------- Yield
```

The MBS price curve lies below the option-free bond curve in both directions from the current price, with the gap widening as rates move.

### Effective Convexity

**Effective convexity** for MBS is calculated similarly to effective duration but captures the curvature:

```
C_eff = (P_down + P_up - 2*P_0) / (P_0 * delta_y^2)
```

For MBS, this value is typically **negative** (e.g., -1.5 to -3.0 for current-coupon 30-year MBS), while comparable Treasuries have positive convexity (e.g., +0.5 to +1.0).

In the OAS framework, this is the **option-adjusted convexity (OAC)**, computed by re-running the Monte Carlo simulation for up and down rate shifts.

### Duration Drift

**Duration drift** is the change in a portfolio's duration over time without any change in interest rates. For MBS, duration drift occurs because:

- **Aging/seasoning:** As loans age, prepayment behavior changes (e.g., seasoning ramp, burnout).
- **Amortization:** Scheduled principal payments shorten remaining cash flows.
- **Prepayment model updates:** As new prepayment data arrives, model recalibrations can shift duration.

Portfolio managers must monitor duration drift and rebalance hedges periodically even if rates have not moved.

### Empirical Duration

**Empirical duration** is estimated by regressing observed MBS price changes against observed rate changes over a historical window:

```
dP/P = alpha + beta * dY + epsilon
```

The estimated `beta` (with sign adjustment) is the empirical duration. It differs from model duration because:
- It captures real-world hedging behavior and market technicals.
- It may reflect supply/demand dynamics not in models.
- It is backward-looking and can change as market regimes shift.
- It is noisy due to spread changes, convexity hedging flows, and Fed activity.

Empirical duration is useful as a **reality check** against model duration. Large divergences may indicate model miscalibration or unusual market conditions.

### Hedge Ratios

A **hedge ratio** expresses how much of a hedging instrument is needed to offset the rate sensitivity of an MBS position:

```
Hedge Ratio = (DV01_MBS * Notional_MBS) / (DV01_Hedge * Notional_Hedge)
```

Where **DV01** (dollar value of a basis point) = Duration * Price * 0.0001.

For MBS hedging:
- Use effective (OA) duration, not modified duration.
- The hedge ratio is **dynamic** — it changes as rates move because MBS duration changes (negative convexity).
- Hedging with Treasuries introduces **basis risk** because MBS spreads can move independently.
- Key rate duration hedging uses multiple instruments to match the KRD profile.

### MBS Duration vs. Treasury Duration

| Characteristic | MBS | Treasury |
|---------------|-----|----------|
| Duration type needed | Effective/OAD | Modified or Macaulay |
| Convexity | Negative | Positive |
| Duration stability | Unstable (changes with rates) | Relatively stable |
| Response to rally | Shortens (prepayments accelerate) | Slightly shortens (normal roll-down) |
| Response to sell-off | Extends (prepayments slow) | Slightly shortens |
| Hedge frequency | Frequent rebalancing needed | Less frequent |

### IO and PO Duration

When an MBS is stripped into an **Interest-Only (IO)** and **Principal-Only (PO)** strip, the duration characteristics diverge dramatically:

**PO Strip (Principal-Only):**
- Receives only principal payments (scheduled + prepayments).
- When rates fall, prepayments increase, returning principal faster at a fixed price. PV increases. PO has **very long positive duration** (can be 15-25 years effective).
- PO price increases when rates fall — it benefits from faster prepayments.
- PO has **extreme positive convexity** at certain rate levels.

**IO Strip (Interest-Only):**
- Receives only interest payments on the declining balance.
- When rates fall, prepayments increase, and the notional balance shrinks faster. Future interest payments vanish. PV decreases.
- IO has **negative duration** — its price rises when rates rise and falls when rates fall.
- IO effective duration can be -5 to -15 years.
- IO is used to hedge against rising rates or to hedge servicing portfolios (MSRs behave like IOs).

**Relationship:**
```
MBS Price = IO Price + PO Price
MBS Duration * MBS Price = IO Duration * IO Price + PO Duration * PO Price
```

Since MBS duration is moderate and positive, and PO duration is strongly positive, IO duration must be negative to balance the equation.

---

## Real-World Examples

### Example 1: Effective Duration Calculation

A FNMA 30yr 4.5% is priced at 102.50 (P_0). Using a 25 bp shift:
- Rates down 25 bps: P_down = 103.75 (prepayments modeled faster)
- Rates up 25 bps: P_up = 101.00 (prepayments modeled slower)

```
D_eff = (103.75 - 101.00) / (2 * 102.50 * 0.0025)
D_eff = 2.75 / 0.5125
D_eff = 5.37 years
```

Note that the price increase (1.25) is less than the price decrease (1.50), reflecting negative convexity.

### Example 2: Negative Convexity in Action

Consider a FNMA 30yr 3.0% (discount) vs. 5.0% (premium) when rates drop 100 bps:

| Coupon | Starting OAD | OAD After -100bp | Price Change |
|--------|-------------|-------------------|--------------|
| 3.0% (discount) | 6.8 yrs | 5.2 yrs | +5.5% |
| 5.0% (premium) | 3.8 yrs | 2.1 yrs | +2.8% |
| 10yr TSY | 8.5 yrs | 8.4 yrs | +8.3% |

The premium MBS gained far less than its starting duration would suggest because prepayments compressed the bond. The discount MBS performed better but still underperformed the Treasury. This demonstrates the cost of negative convexity.

### Example 3: IO/PO Hedge Construction

A portfolio manager holds $500M of FNMA 30yr 4.0% (OAD = 5.5 years) and wants to reduce duration by 2 years. Instead of selling MBS or buying short Treasuries, the manager buys IO strips:

- IO notional needed: The IO strip has effective duration of -12 years.
- Required DV01 reduction: $500M * 2.0 * 0.0001 = $100,000
- IO DV01 per $1M notional: ~$1,200
- IO notional needed: $100,000 / $1,200 per $1M = ~$83M notional

The IO strips provide negative duration that partially offsets the MBS portfolio's positive duration while also hedging some of the negative convexity exposure.

### Example 4: Key Rate Duration Hedging

A fund has $1B of 30-year MBS with the following KRD profile and wants to hedge to zero duration:

| Key Rate | MBS KRD | Hedge Instrument | Hedge DV01 Needed |
|----------|---------|-------------------|-------------------|
| 2Y | 0.20 | 2Y Treasury Note | $20,000 |
| 5Y | 1.30 | 5Y Treasury Note | $130,000 |
| 10Y | 2.80 | 10Y Treasury Note | $280,000 |
| 30Y | 0.10 | 30Y Treasury Bond | $10,000 |

Using KRDs ensures the portfolio is hedged against non-parallel curve shifts, which is especially important for MBS because their cash flow sensitivity is concentrated in the 5-10Y sector.

---

## Common Interview Questions & Answers

### Q1: Why is modified duration inappropriate for MBS? What should you use instead?

**Answer:** Modified duration assumes cash flows do not change when rates change. For MBS, this assumption is violated — when rates fall, prepayments accelerate and cash flows shift earlier; when rates rise, prepayments slow and cash flows extend. Modified duration therefore understates the true sensitivity for discount MBS (where extension risk is greater) and overstates it for premium MBS (where prepayment risk is greater). The correct measure is **effective duration (option-adjusted duration)**, which reprices the MBS under shifted rate scenarios, allowing the prepayment model to respond to the new rate environment. This captures the option-adjusted behavior that modified duration ignores.

### Q2: Explain negative convexity in MBS. How does it affect portfolio management?

**Answer:** Negative convexity means the MBS price/yield relationship is concave rather than convex. The investor is short a call option (the borrower's right to prepay). When rates fall, price upside is capped by prepayments; when rates rise, price declines are amplified by extension. This affects portfolio management in several ways: (1) Hedges must be rebalanced frequently because duration changes adversely in both directions. (2) Investors demand higher OAS to compensate for negative convexity. (3) Short-volatility positions are created — the portfolio loses in high-volatility environments. (4) Total return analysis must model multiple scenarios, not just a parallel shift. (5) Convexity hedging using options (swaptions, caps) is needed for precision.

### Q3: What is the difference between empirical duration and model duration?

**Answer:** Model duration (OAD) is derived from a theoretical framework — a term structure model, prepayment model, and Monte Carlo simulation. Empirical duration is estimated by regressing observed price changes against observed rate changes over a historical period. They can diverge for several reasons: (a) the prepayment model may not capture actual borrower behavior accurately, (b) market technicals (supply/demand, Fed purchases, convexity hedging flows) affect prices beyond what models capture, (c) spread changes contaminate empirical estimates, and (d) regime changes may not be reflected in models. Portfolio managers track both and investigate large divergences. Empirical duration is a useful validation tool but is backward-looking and can be noisy.

### Q4: Why do IO strips have negative duration?

**Answer:** An IO strip receives interest payments calculated on the outstanding principal balance. When rates fall, prepayments accelerate, and the outstanding balance declines faster. This reduces future interest payments, causing the IO's value to drop — the opposite of a normal bond. The IO's price moves in the same direction as interest rates (price falls when rates fall, rises when rates rise), which by definition is negative duration. Quantitatively, since MBS = IO + PO, and MBS duration is moderately positive while PO duration is strongly positive, IO duration must be negative to satisfy the weighted-duration equation. IO durations of -5 to -15 years are common, making IOs useful for hedging portfolios against rising rates.

### Q5: How do key rate durations improve MBS hedging compared to using total effective duration alone?

**Answer:** Total effective duration assumes a parallel shift in the yield curve, but real-world curve movements are rarely parallel. MBS have cash flow sensitivity concentrated in specific parts of the curve (primarily the 5-10Y sector for 30-year MBS). Using only total duration, a hedge might match the overall DV01 but leave significant exposure to curve twists and steepening/flattening. Key rate durations decompose sensitivity across the curve, allowing the hedger to match exposures at each point. For example, an MBS portfolio might have minimal 2Y KRD but large 7Y and 10Y KRDs; a hedge using only 5Y notes would leave the 10Y exposure unhedged. KRD hedging is standard practice at sophisticated MBS investors and is required for regulatory interest rate risk calculations.

### Q6: How does the duration of an MBS change in a rally vs. a sell-off?

**Answer:** In a rally (rates falling): MBS duration shortens. Prepayments accelerate, pulling cash flows closer to the present. The investor wants long duration to benefit from falling rates, but the MBS is getting shorter — a harmful dynamic. For a premium MBS, duration can collapse rapidly as it approaches "lockout speed" (maximum prepayment rate). In a sell-off (rates rising): MBS duration extends. Prepayments slow, pushing cash flows further out. The investor wants short duration to limit losses, but the MBS is extending — again harmful. The worst case is "extension risk" in a sharp sell-off, where a portfolio's duration can increase by several years, amplifying losses. This asymmetric duration behavior is the practical manifestation of negative convexity.

---

## Tips

- **Always specify which duration measure you are discussing.** In an interview, saying "duration" without qualification is imprecise. State "effective duration" or "OAD" for MBS.
- **Memorize approximate OADs** for common MBS coupons and maturities. Interviewers expect you to know that a 30-year current coupon MBS has an OAD of roughly 5-6 years, not 15-20 years.
- **The IO/PO decomposition** is a favorite interview topic because it tests deep understanding of how prepayments create opposing risks for different claim structures.
- **Negative convexity is the single most important concept** distinguishing MBS from Treasuries. Practice explaining it in plain English, with a diagram, and with formulas.
- **For data engineering roles,** know how duration and convexity are computed in batch processes, how KRD vectors are stored (as arrays or individual columns), and how these risk measures feed into portfolio management and regulatory reporting systems.
- **Key rate durations sum to total effective duration** — this is a useful sanity check when validating analytics pipelines.
- **Understand that OAD depends on the OAS model.** Different vendors (Bloomberg, Yield Book, BlackRock Aladdin) may produce different OADs for the same bond due to differences in term structure models, prepayment models, and rate volatility assumptions. Data engineers must track model provenance alongside the analytics.
