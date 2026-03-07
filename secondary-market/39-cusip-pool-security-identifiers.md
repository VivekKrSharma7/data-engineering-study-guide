# CUSIP, Pool Number & Security Identifiers

[Back to Secondary Market Index](./README.md)

---

## Key Concepts

### 1. CUSIP Structure

CUSIP (Committee on Uniform Securities Identification Procedures) is the standard 9-character alphanumeric identifier for securities in North America. It is administered by CUSIP Global Services, a subsidiary of the American Bankers Association operated by FactSet.

#### Anatomy of a CUSIP

```
3 1 3 8  E  G  5  M  7
│ │ │ │  │  │  │  │  │
└─┴─┴─┴──┴──┘  │  │  └── Check Digit (position 9)
   Issuer ID    │  └───── Issue Number (positions 7-8)
  (positions    └──────── Issue Number (positions 7-8)
   1-6)

Position 1-6:  Issuer identifier (6 characters)
Position 7-8:  Issue identifier (2 characters)
Position 9:    Check digit (calculated using Luhn algorithm variant)
```

#### Issuer Identifier (Positions 1-6)

The first six characters identify the issuer. For MBS:

| Issuer Code Prefix | Issuer |
|--------------------|--------|
| **3138** | Fannie Mae (FNMA) MBS pools |
| **3132** | Freddie Mac (FHLMC) PCs |
| **36179** | Ginnie Mae (GNMA) pools |
| **3136** | Fannie Mae REMIC tranches (various) |
| **3137** | Freddie Mac REMIC tranches (various) |

*Note: These are common prefixes; the full 6-digit issuer code varies across programs and vintages.*

#### Issue Identifier (Positions 7-8)

The two-character issue identifier, combined with the issuer, uniquely identifies a specific security. For MBS, this differentiates pools or tranches within an issuer's program.

#### Check Digit (Position 9)

The check digit is calculated using a modified Luhn algorithm to detect transcription errors. It ensures that a single character change in the CUSIP is detectable.

**Check digit calculation:**

```
For each position (1-8):
  1. If the character is a digit, use its value
  2. If the character is a letter, convert: A=10, B=11, ..., Z=35
  3. If the character is at an even position (2, 4, 6, 8), double the value
  4. If the doubled value >= 10, sum the digits (e.g., 14 -> 1+4 = 5)
  5. Sum all values
  6. Check digit = (10 - (sum mod 10)) mod 10
```

### 2. Pool Numbers

Pool numbers are agency-specific identifiers for mortgage pass-through pools.

#### Fannie Mae Pool Numbers

| Prefix | Pool Type |
|--------|-----------|
| **AL** | Long-term, fixed-rate (30-year) |
| **AS** | Short-term, fixed-rate (15-year) |
| **AR** | ARM pools |
| **BL** | Jumbo conforming |
| **MA** | Mega pools (multi-lender) |
| **CA/CB/CI** | Various CAS reference pools |

Fannie Mae pool numbers are typically 6 characters: 2-letter prefix + 4-digit sequence.

#### Freddie Mac Pool Numbers

| Prefix | Pool Type |
|--------|-----------|
| **Q0-Q9** | Gold PCs (fixed-rate) |
| **G0-G9** | ARM PCs |
| **U0-U9** | UMBS-eligible pools |
| **ZT** | Giants (multi-pool aggregation) |

Freddie Mac pool numbers are typically 6 characters.

#### Ginnie Mae Pool Numbers

| Prefix | Pool Type |
|--------|-----------|
| **MA** | Ginnie Mae II multi-issuer |
| **Various** | Ginnie Mae I single-issuer, 6-digit numeric |

### 3. Agency Pool-CUSIP Mapping

Each agency pool has a corresponding CUSIP. The mapping is deterministic:

```
Fannie Mae:
  Pool Number: AL1234
  CUSIP: 3138XXXX[check]   (6-digit issuer prefix + 2 derived from pool + check)

Freddie Mac:
  Pool Number: Q01234
  CUSIP: 3132XXXX[check]

Ginnie Mae:
  Pool Number: MA1234
  CUSIP: 36179XXX[check]
```

**Important:** The pool number and CUSIP are different identifiers for the same security. Your database must support lookup by either. Some systems use pool number as the primary key (agency-centric) while others use CUSIP (market-centric).

### 4. Tranche CUSIPs

For CMO/REMIC deals, each tranche has its own CUSIP distinct from the deal-level identifier.

```
Deal: FNR 2025-C01

Tranche    CUSIP         Type
A1         3136ABCD1     Sequential Senior
A2         3136ABCD2     Sequential Senior
A-IO       3136ABCF5     Interest Only (Notional)
M1         3136ABCG3     Mezzanine
M2         3136ABCH1     Mezzanine
B1         3136ABCJ7     Subordinate
CE         3136ABCK4     Credit Enhancement (Residual)
```

**Key points:**
- Each tranche within a deal has a unique CUSIP
- The issuer prefix is shared across tranches of the same deal
- The issue identifier (positions 7-8) differentiates tranches
- Exchange classes and combination CUSIPs create additional identifiers for the same economic exposure

### 5. ISIN (International Securities Identification Number)

ISIN is the global identifier standard (ISO 6166), used for international trading and settlement.

**Structure:**

```
US  3138EG5M7  3
│   │          │
│   │          └── ISIN Check Digit
│   └──────────── CUSIP (9 characters)
└──────────────── Country Code (2 characters)

ISIN = Country Code + CUSIP + ISIN Check Digit
```

For US securities, the ISIN is simply "US" + the 9-character CUSIP + a check digit. The conversion is mechanical and deterministic.

**Conversion rules:**
- US ISIN = "US" + CUSIP + check digit (12 characters total)
- Canadian ISIN = "CA" + CINS + check digit
- ISIN check digit uses a different Luhn variant than CUSIP check digit

### 6. FIGI (Financial Instrument Global Identifier)

FIGI (formerly Bloomberg Global Identifier / BBGID) is an open-source identifier managed by the Object Management Group (OMG).

**Structure:**

```
BBG  000BPH459
│    │
│    └── 9-character alphanumeric
└────── Prefix (3 characters, always "BBG" for Bloomberg-assigned)
```

**Characteristics:**
- 12 characters total
- Freely available (unlike CUSIP which requires a license)
- Maps 1:1 to trading venues (a single CUSIP can have multiple FIGIs for different exchanges)
- Useful as a join key when CUSIP licensing is cost-prohibitive

### 7. Security Master Database Design

A security master is the central reference database for all security identifiers and attributes.

#### Schema Design

```sql
-- Core security master table
CREATE TABLE dim_security (
    security_id         BIGINT PRIMARY KEY,  -- surrogate key
    cusip               CHAR(9),
    isin                CHAR(12),
    figi                CHAR(12),
    pool_number         VARCHAR(10),
    security_type       VARCHAR(20),  -- PASS_THROUGH, CMO_TRANCHE, CRT, IO, PO
    issuer_code         VARCHAR(10),  -- FNMA, FHLMC, GNMA, PLS
    deal_name           VARCHAR(50),
    tranche_name        VARCHAR(20),
    original_face       DECIMAL(18,2),
    issue_date          DATE,
    maturity_date       DATE,
    coupon_rate         DECIMAL(8,5),
    coupon_type         VARCHAR(15),  -- FIXED, FLOAT, STEP
    description         VARCHAR(200),
    status              VARCHAR(10),  -- ACTIVE, MATURED, CALLED, PAID_OFF
    effective_from      DATE,
    effective_to        DATE,
    is_current          CHAR(1) DEFAULT 'Y',
    created_timestamp   TIMESTAMP,
    updated_timestamp   TIMESTAMP,
    UNIQUE (cusip, effective_from)
);

-- Identifier cross-reference table
CREATE TABLE xref_security_identifier (
    xref_id             BIGINT PRIMARY KEY,
    security_id         BIGINT REFERENCES dim_security(security_id),
    identifier_type     VARCHAR(20),  -- CUSIP, ISIN, FIGI, POOL_NUMBER, INTEX_ID, BLOOMBERG_TICKER
    identifier_value    VARCHAR(50) NOT NULL,
    effective_from      DATE,
    effective_to        DATE,
    source              VARCHAR(20),
    created_timestamp   TIMESTAMP,
    UNIQUE (identifier_type, identifier_value, effective_from)
);

-- Create indexes for fast lookups by any identifier
CREATE INDEX idx_xref_type_value ON xref_security_identifier (identifier_type, identifier_value);
CREATE INDEX idx_security_cusip ON dim_security (cusip);
CREATE INDEX idx_security_pool ON dim_security (pool_number);
CREATE INDEX idx_security_isin ON dim_security (isin);
```

#### Identifier Cross-Reference Example

```
security_id | identifier_type  | identifier_value | effective_from | effective_to
------------|------------------|------------------|----------------|-------------
100001      | CUSIP            | 3138EG5M7        | 2025-01-15     | 9999-12-31
100001      | ISIN             | US3138EG5M73     | 2025-01-15     | 9999-12-31
100001      | FIGI             | BBG000BPH459     | 2025-01-15     | 9999-12-31
100001      | POOL_NUMBER      | AL5678           | 2025-01-15     | 9999-12-31
100001      | BLOOMBERG_TICKER | FN AL5678        | 2025-01-15     | 9999-12-31
100001      | INTEX_ID         | FNA AL5678       | 2025-01-15     | 9999-12-31
```

### 8. Identifier Cross-Referencing

Cross-referencing identifiers is a critical data engineering function because different systems use different identifiers:

| System | Preferred Identifier |
|--------|---------------------|
| Trading systems | CUSIP or Bloomberg ticker |
| Settlement (DTCC) | CUSIP |
| International settlement | ISIN |
| Agency reporting | Pool number |
| Intex analytics | Intex deal/tranche ID |
| Bloomberg terminal | Bloomberg ticker (FN, FG, GN prefix + pool) |
| Internal portfolio | Internal security ID (surrogate key) |

**Cross-referencing challenges:**
- Multiple identifiers for the same economic security (CUSIP, ISIN, FIGI, pool number)
- Some identifiers change over time (CUSIP reissuance)
- Some identifiers are venue-specific (FIGI)
- Some identifiers are paid/licensed (CUSIP) vs. free (FIGI)
- Historical lookups require effective date awareness

### 9. CUSIP Lookup Services

| Service | Description | Access Method |
|---------|-------------|---------------|
| **CUSIP Global Services** | Authoritative source; requires subscription | Web portal, API, bulk files |
| **Bloomberg** | CUSIP data via terminal and API | `DES` function, Data License |
| **DTCC** | Identifier data through trade processing | Embedded in trade/settlement messages |
| **eMBS** | Agency MBS identifier data | API, bulk files |
| **EDGAR/SEC** | CUSIP data in filing documents | Free, but unstructured |
| **OpenFIGI** | Free FIGI-to-CUSIP mapping | REST API (api.openfigi.com) |

**CUSIP Licensing Note:** CUSIP numbers are copyrighted by the American Bankers Association. Redistributing CUSIPs without a license is a legal issue. Many firms use FIGI as an alternative or supplement to reduce licensing costs.

### 10. CUSIP Changes and Reissuance

CUSIPs can change for several reasons:

#### Reasons for CUSIP Changes

| Reason | Description |
|--------|-------------|
| **Corporate action** | Issuer reorganization or merger |
| **Exchange/swap** | Tranche exchanged for new combination tranches |
| **Reissuance** | Security retired and CUSIP reassigned to a new security (after a waiting period) |
| **CUSIP conflict** | Data error where two securities share a CUSIP (extremely rare, but must be handled) |
| **UMBS transition** | In 2019, Fannie and Freddie pools migrated to Uniform MBS (UMBS); some received new CUSIPs |

#### Handling CUSIP Changes in the Database

```sql
-- CUSIP change history table
CREATE TABLE cusip_change_history (
    change_id           BIGINT PRIMARY KEY,
    security_id         BIGINT REFERENCES dim_security(security_id),
    old_cusip           CHAR(9),
    new_cusip           CHAR(9),
    change_date         DATE,
    change_reason       VARCHAR(50),
    source              VARCHAR(20),
    created_timestamp   TIMESTAMP
);

-- Query: find current CUSIP for a historical CUSIP
SELECT
    s.security_id,
    s.cusip AS current_cusip,
    c.old_cusip,
    c.change_date,
    c.change_reason
FROM cusip_change_history c
JOIN dim_security s ON c.security_id = s.security_id AND s.is_current = 'Y'
WHERE c.old_cusip = '3138WXYZ1';
```

**Data engineering best practice:** Always use a surrogate key (internal security_id) as the primary reference in your data model. CUSIPs, pool numbers, and other external identifiers should be attributes that can change. The surrogate key provides a stable join key that survives identifier changes.

---

## Real-World Examples

### Example 1: Building a Security Master from Multiple Sources

**Scenario:** Your firm needs a unified security master for MBS covering agency pass-throughs, agency CMOs, and private-label deals.

**Sources:**
1. Fannie Mae monthly disclosure (pool number, CUSIP, pool attributes)
2. Freddie Mac monthly disclosure (pool number, CUSIP, pool attributes)
3. Ginnie Mae disclosure (pool number, CUSIP)
4. Bloomberg reference data (CUSIP, ISIN, FIGI, descriptions, ratings)
5. Intex deal library (Intex deal ID, tranche ID, CUSIPs)
6. Internal trade system (positions with CUSIPs)

**Pipeline:**

```
1. Load each source into staging tables
2. Match across sources on CUSIP (primary key)
3. Resolve conflicts using golden source hierarchy:
   - CUSIP, pool number, issue date: Agency disclosure (authoritative)
   - ISIN, FIGI: Bloomberg
   - Deal structure, tranche attributes: Intex
   - Ratings: Rating agency feeds
4. Create/update dim_security and xref_security_identifier
5. Handle new securities (CUSIPs in trade system not in security master)
6. Handle retired securities (factor = 0, mark as PAID_OFF)
7. Publish updated security master to downstream systems
```

### Example 2: CUSIP Validation in Trade Processing

**Scenario:** The trading desk enters a trade with CUSIP "3138EG5M8". The system must validate this.

```
Step 1: Check digit validation
  Characters: 3, 1, 3, 8, E, G, 5, M
  E = 14, G = 16, M = 22

  Position 1 (odd):  3  → 3
  Position 2 (even): 1  → 1×2 = 2
  Position 3 (odd):  3  → 3
  Position 4 (even): 8  → 8×2 = 16 → 1+6 = 7
  Position 5 (odd):  14 → 14 → 1+4 = 5
  Position 6 (even): 16 → 16×2 = 32 → 3+2 = 5
  Position 7 (odd):  5  → 5
  Position 8 (even): 22 → 22×2 = 44 → 4+4 = 8

  Sum = 3 + 2 + 3 + 7 + 5 + 5 + 5 + 8 = 38
  Check digit = (10 - (38 mod 10)) mod 10 = (10 - 8) mod 10 = 2

  Entered check digit: 8
  Calculated check digit: 2
  MISMATCH → Reject trade, notify trader

  Correct CUSIP should be: 3138EG5M2
```

*Note: This is a simplified illustration. Actual Luhn-mod-10 implementations may differ slightly in their treatment of alpha-to-numeric conversion.*

### Example 3: UMBS Transition Data Migration

**Scenario:** In June 2019, Fannie Mae and Freddie Mac pools became fungible under the Uniform MBS (UMBS) program. This required data engineering changes.

**Before UMBS:**
```
Fannie Mae Pool AL1234 → CUSIP 3138XXXX1 → Traded as "Fannie 4.0%"
Freddie Mac Pool Q01234 → CUSIP 3132YYYY2 → Traded as "Freddie 4.0%"
```

**After UMBS:**
```
Both trade as "UMBS 4.0%" in TBA market
Fannie pools retain original CUSIPs but are deliverable into UMBS TBA
Freddie pools exchanged into "mirror" UMBS securities with new CUSIPs
  Original: CUSIP 3132YYYY2 (Freddie Gold PC)
  New:      CUSIP 3132ZZZZ3 (UMBS-mirror security)
```

**Data engineering impact:**
1. Add new CUSIPs for Freddie mirror securities to the security master
2. Create cross-references between original and mirror CUSIPs
3. Update position tracking to handle both old and new CUSIPs
4. Modify TBA delivery logic to accept either Fannie or Freddie UMBS pools
5. Preserve historical data under original CUSIPs while linking to new UMBS identifiers

---

## Common Interview Questions & Answers

### Q1: Explain the structure of a CUSIP and how the check digit is calculated.

**Answer:** A CUSIP is a 9-character alphanumeric identifier consisting of three parts:

- **Positions 1-6 (Issuer ID)**: Identifies the issuer. For MBS, common prefixes include 3138 (Fannie Mae pools), 3132 (Freddie Mac pools), and 36179 (Ginnie Mae pools).
- **Positions 7-8 (Issue ID)**: Identifies the specific security within the issuer's program. Combined with the issuer ID, this uniquely identifies the security.
- **Position 9 (Check Digit)**: Calculated using a modified Luhn algorithm. Each character in positions 1-8 is converted to a numeric value (digits stay as-is, letters map A=10 through Z=35). Characters at even positions are doubled. If any resulting value has two digits, the digits are summed. All values are summed, and the check digit is (10 - sum mod 10) mod 10.

The check digit provides error detection for single-character transcription errors. As a data engineer, I implement check digit validation at the ingestion layer to catch bad CUSIPs before they enter the system.

### Q2: How would you design a security master database for MBS?

**Answer:** I design the security master with three layers:

**Core dimension table (`dim_security`)**: Contains one row per security with a surrogate key, the current CUSIP, security type, issuer, deal/tranche name, coupon, original face, dates, and status. I use SCD Type 2 to track changes (e.g., CUSIP changes, status changes from ACTIVE to PAID_OFF).

**Identifier cross-reference table (`xref_security_identifier`)**: A separate table that maps the surrogate key to all known identifiers (CUSIP, ISIN, FIGI, pool number, Intex ID, Bloomberg ticker). Each row has an identifier type, value, and effective date range. This allows any system to look up the security by whatever identifier it uses.

**Key design principles:**
- The surrogate key is the stable join key used throughout the data warehouse. External identifiers (CUSIP, pool number) can change.
- Index on every identifier type for fast lookups.
- Support historical identifier lookups (a query for an old CUSIP should resolve to the correct security).
- Include a source column on every record for audit purposes.

This design supports the common scenario where a trader queries by CUSIP, the agency reports by pool number, Bloomberg uses FIGI, and the internal system uses the surrogate key. All resolve to the same security.

### Q3: What is the difference between CUSIP, ISIN, and FIGI?

**Answer:**

| Attribute | CUSIP | ISIN | FIGI |
|-----------|-------|------|------|
| **Scope** | North America (US and Canada) | Global (ISO 6166) | Global |
| **Length** | 9 characters | 12 characters | 12 characters |
| **Structure** | 6 issuer + 2 issue + 1 check | 2 country + 9 national ID + 1 check | 3 prefix + 9 alphanumeric |
| **Administrator** | CUSIP Global Services (ABA/FactSet) | National numbering agencies | Object Management Group |
| **Cost** | Licensed (paid subscription) | Licensed | Free and open |
| **Uniqueness** | Unique per security in US/Canada | Globally unique per security | Unique per security per venue |
| **MBS Usage** | Primary identifier in US markets | Used for international settlement | Alternative to CUSIP; used in open data systems |

For US MBS, CUSIP is the standard. ISIN is derived from CUSIP (ISIN = "US" + CUSIP + check digit). FIGI is increasingly used as a free alternative, especially in data engineering pipelines where CUSIP licensing costs are a concern. However, FIGI has a venue-specific dimension (a security traded on different venues gets different FIGIs), so composite FIGIs are used for non-venue-specific reference.

### Q4: How do you handle CUSIP changes in your data model?

**Answer:** CUSIP changes are rare but must be handled correctly to maintain data integrity:

1. **Surrogate key design**: My data model uses an internal surrogate key (`security_id`) as the primary reference, not CUSIP. This means CUSIP changes do not break joins across the data warehouse.

2. **SCD Type 2 on `dim_security`**: When a CUSIP changes, I create a new row with the new CUSIP, updated effective dates, and `is_current = 'Y'`. The old row gets `effective_to = change_date - 1` and `is_current = 'N'`.

3. **Cross-reference update**: In `xref_security_identifier`, I close out the old CUSIP record (set `effective_to`) and insert a new record with the new CUSIP. Both records point to the same `security_id`.

4. **Change history table**: I maintain a `cusip_change_history` table that explicitly links old and new CUSIPs with the change reason and date. This supports historical lookups ("What is the current CUSIP for this old CUSIP?").

5. **Downstream notification**: When a CUSIP changes, downstream systems (positions, trades, risk) must be notified. I publish CUSIP change events to a message queue that consuming systems subscribe to.

The most common CUSIP changes in MBS are from the UMBS transition (Freddie Mac mirror securities) and from exchange classes in CMOs.

### Q5: What are the data engineering challenges of CUSIP licensing?

**Answer:** CUSIP numbers are copyrighted intellectual property. Key challenges:

1. **Cost**: CUSIP Global Services charges based on usage volume and distribution. For a firm with 500,000+ securities, licensing can be significant.

2. **Redistribution restrictions**: You cannot freely share CUSIPs in reports, APIs, or data feeds without a distribution license. This affects how you design client-facing systems and external data products.

3. **Alternative identifiers**: To reduce CUSIP dependency, I use FIGI (free, open) as a supplementary identifier. For internal-only systems, the surrogate key eliminates the need to expose CUSIPs.

4. **Data pipeline design**: I encapsulate CUSIP usage behind an abstraction layer. External data ingestion resolves CUSIPs to internal IDs at the boundary. Internal systems operate on surrogate keys. CUSIPs are only exposed where legally required (trade confirmations, settlement messages, regulatory reporting).

5. **Compliance**: I maintain metadata about which systems use CUSIPs and under which license. This supports audit and compliance reviews.

---

## Tips

1. **Always validate check digits**: Implement CUSIP and ISIN check digit validation at every data ingestion point. A single transposed character creates a valid-looking but wrong identifier that can cause settlement failures or position mismatches.

2. **Use surrogate keys internally**: Never use CUSIP as a primary key in your data warehouse. CUSIPs change, and using them as foreign keys creates cascading update problems. Use a stable surrogate key and treat CUSIP as an attribute.

3. **Build a robust cross-reference**: The security identifier cross-reference table is one of the most-queried tables in any financial data warehouse. Invest in proper indexing, caching, and data quality for this table.

4. **Know your agency prefixes**: Being able to identify the issuer and program from a CUSIP prefix (3138 = Fannie Mae pool, 3136 = Fannie Mae REMIC, 3132 = Freddie Mac) is a practical skill that speeds up debugging and data analysis.

5. **Handle paid-off securities gracefully**: When a pool or tranche is fully paid off (factor = 0), mark it as PAID_OFF in the security master but do not delete it. Historical trades, positions, and accounting entries reference it.

6. **CUSIP is not globally unique forever**: After a security is retired, its CUSIP can theoretically be reassigned (though there is a long waiting period). Always store the issue date alongside the CUSIP to disambiguate in edge cases with very old historical data.

7. **OpenFIGI is your friend**: For quick CUSIP-to-FIGI lookups during development and testing, the OpenFIGI API (api.openfigi.com) is free and does not require CUSIP licensing. Use it for data enrichment in non-production environments.
