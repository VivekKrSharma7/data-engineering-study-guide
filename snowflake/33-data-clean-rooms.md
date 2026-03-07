# Data Clean Rooms

[Back to Snowflake Index](./README.md)

---

## Overview

A Data Clean Room is a secure, controlled environment where two or more parties can collaborate on data analytics **without exposing their raw, underlying data to each other**. Snowflake provides native clean room capabilities that enable privacy-preserving analytics -- a critical capability for industries subject to strict data regulations. This is an advanced topic that signals deep platform knowledge in interviews.

---

## Key Concepts

### Data Clean Room Concept

The fundamental problem clean rooms solve: **Two organizations want to derive joint insights from their combined data, but neither party is willing (or legally able) to share raw data with the other.**

Traditional approach (problematic):
1. Party A exports data to Party B.
2. Party B joins it with their data.
3. Privacy risk: Party B now has Party A's raw data.

Clean room approach:
1. Both parties contribute data to a governed environment.
2. Only **pre-approved, aggregate queries** can run against the combined data.
3. Neither party sees the other's raw records.
4. Only approved outputs (aggregations, counts, statistical results) leave the clean room.

```
+------------------+          Clean Room          +------------------+
|   PARTY A        |   +--------------------+     |   PARTY B        |
|   (Advertiser)   |-->| Overlap Analysis   |<----|   (Publisher)     |
|                  |   | Aggregate Queries  |     |                  |
|   Raw CRM Data   |   | Privacy Policies   |     |   Audience Data  |
|   (Never Shared) |   +--------------------+     |   (Never Shared) |
+------------------+          |                   +------------------+
                              v
                    +-------------------+
                    |  Approved Outputs  |
                    |  (Aggregates Only) |
                    +-------------------+
```

### Snowflake's Clean Room Framework

Snowflake provides clean rooms through a combination of:

- **Secure Data Sharing:** Each party shares specific tables/views into the clean room.
- **Row Access Policies and Masking Policies:** Control what data is visible.
- **Secure UDFs and Stored Procedures:** Encapsulate approved analysis logic.
- **Reader Accounts or Multi-Party Shares:** Facilitate access without full account sharing.
- **Snowflake Native App Framework:** Package clean room logic as an installable app.

The key architectural principle: **data stays in each party's account**; only metadata, policies, and approved queries cross boundaries.

### Privacy-Preserving Analytics

Clean rooms enforce privacy through multiple layers:

1. **Query Restrictions:** Only pre-approved query templates can run (no ad-hoc SELECT *).
2. **Aggregation Minimums:** Results must meet minimum group sizes (e.g., k-anonymity -- no group smaller than 25 records).
3. **Column Masking:** Sensitive fields are hashed or masked before any join operations.
4. **Output Validation:** Results are checked against privacy thresholds before being returned.
5. **Audit Logging:** Every query and result is logged for compliance.

```sql
-- Example: Secure UDF that enforces minimum aggregation thresholds
CREATE OR REPLACE SECURE FUNCTION clean_room_db.analysis.safe_count(group_count INT)
RETURNS INT
LANGUAGE SQL
AS
$$
    CASE
        WHEN group_count < 25 THEN NULL  -- Suppress small groups
        ELSE group_count
    END
$$;
```

### Setting Up Clean Rooms

Here is a simplified example of setting up a two-party clean room in Snowflake:

#### Party A (Advertiser) Setup

```sql
-- Party A creates a clean room database and shares relevant data
CREATE DATABASE clean_room_advertiser;
CREATE SCHEMA clean_room_advertiser.shared;

-- Create a hashed version of PII for privacy-safe matching
CREATE OR REPLACE SECURE VIEW clean_room_advertiser.shared.v_hashed_customers AS
SELECT
    SHA2(LOWER(TRIM(email)), 256) AS hashed_email,  -- Hashed identifier
    age_bracket,           -- Aggregatable attribute
    income_bracket,        -- Aggregatable attribute
    product_category,      -- What they purchased
    purchase_count         -- Purchase frequency
FROM advertiser_db.crm.customers;

-- Share with the clean room
CREATE SHARE advertiser_cleanroom_share;
GRANT USAGE ON DATABASE clean_room_advertiser TO SHARE advertiser_cleanroom_share;
GRANT USAGE ON SCHEMA clean_room_advertiser.shared TO SHARE advertiser_cleanroom_share;
GRANT SELECT ON VIEW clean_room_advertiser.shared.v_hashed_customers
    TO SHARE advertiser_cleanroom_share;
```

#### Party B (Publisher) Setup

```sql
-- Party B similarly prepares their data
CREATE DATABASE clean_room_publisher;
CREATE SCHEMA clean_room_publisher.shared;

CREATE OR REPLACE SECURE VIEW clean_room_publisher.shared.v_hashed_audience AS
SELECT
    SHA2(LOWER(TRIM(email)), 256) AS hashed_email,  -- Same hashing for join
    content_category,      -- What content they consume
    engagement_score,      -- How engaged they are
    platform,              -- Which platform
    impression_count       -- Ad impression data
FROM publisher_db.audience.profiles;

CREATE SHARE publisher_cleanroom_share;
GRANT USAGE ON DATABASE clean_room_publisher TO SHARE publisher_cleanroom_share;
GRANT USAGE ON SCHEMA clean_room_publisher.shared TO SHARE publisher_cleanroom_share;
GRANT SELECT ON VIEW clean_room_publisher.shared.v_hashed_audience
    TO SHARE publisher_cleanroom_share;
```

#### Clean Room Analysis (Approved Queries Only)

```sql
-- This stored procedure runs in the clean room and enforces privacy rules
CREATE OR REPLACE SECURE PROCEDURE clean_room_db.analysis.overlap_analysis()
RETURNS TABLE (age_bracket VARCHAR, content_category VARCHAR, overlap_count INT)
LANGUAGE SQL
AS
$$
DECLARE
    result RESULTSET;
BEGIN
    result := (
        SELECT
            a.age_bracket,
            b.content_category,
            CASE
                WHEN COUNT(DISTINCT a.hashed_email) >= 25 THEN COUNT(DISTINCT a.hashed_email)
                ELSE NULL  -- Suppress groups below privacy threshold
            END AS overlap_count
        FROM advertiser_data.shared.v_hashed_customers a
        INNER JOIN publisher_data.shared.v_hashed_audience b
            ON a.hashed_email = b.hashed_email
        GROUP BY a.age_bracket, b.content_category
        HAVING COUNT(DISTINCT a.hashed_email) >= 25
    );
    RETURN TABLE(result);
END;
$$;

-- Execute the approved analysis
CALL clean_room_db.analysis.overlap_analysis();
```

### Clean Room Policies

Policies are the governance backbone of any clean room:

```sql
-- Row Access Policy: Restrict which rows are accessible in the clean room
CREATE OR REPLACE ROW ACCESS POLICY clean_room_db.policies.restrict_to_consented
    AS (consent_flag BOOLEAN) RETURNS BOOLEAN ->
    consent_flag = TRUE;  -- Only include records with user consent

ALTER TABLE clean_room_advertiser.shared.customers
    ADD ROW ACCESS POLICY clean_room_db.policies.restrict_to_consented
    ON (has_consent);

-- Column Masking Policy: Mask sensitive columns
CREATE OR REPLACE MASKING POLICY clean_room_db.policies.hash_pii
    AS (val STRING) RETURNS STRING ->
    SHA2(val, 256);

ALTER TABLE clean_room_advertiser.shared.customers
    MODIFY COLUMN email
    SET MASKING POLICY clean_room_db.policies.hash_pii;
```

**Key policy types in clean rooms:**
- **Join policies:** Restrict which columns can be used as join keys (typically only hashed identifiers).
- **Aggregation policies:** Enforce minimum group sizes in output.
- **Column policies:** Define which columns each party can see or use.
- **Query policies:** Whitelist specific query templates or stored procedures.
- **Output policies:** Validate results before returning to the requesting party.

### Overlap Analysis

Overlap analysis is the most common clean room use case: **How many users do Party A and Party B have in common, and what are their aggregate characteristics?**

```sql
-- Basic overlap: How many shared users?
SELECT COUNT(DISTINCT a.hashed_email) AS total_overlap
FROM advertiser_data.shared.v_hashed_customers a
INNER JOIN publisher_data.shared.v_hashed_audience b
    ON a.hashed_email = b.hashed_email;

-- Enriched overlap: What do overlapping users look like?
SELECT
    a.age_bracket,
    a.income_bracket,
    b.content_category,
    COUNT(DISTINCT a.hashed_email) AS overlap_count,
    AVG(b.engagement_score) AS avg_engagement,
    AVG(a.purchase_count) AS avg_purchases
FROM advertiser_data.shared.v_hashed_customers a
INNER JOIN publisher_data.shared.v_hashed_audience b
    ON a.hashed_email = b.hashed_email
GROUP BY a.age_bracket, a.income_bracket, b.content_category
HAVING COUNT(DISTINCT a.hashed_email) >= 25  -- Privacy threshold
ORDER BY overlap_count DESC;
```

### Joint Analytics Without Raw Data Exposure

The critical principle: **both parties learn aggregate insights without ever seeing the other's raw data.**

What each party can do:
- Run pre-approved aggregate queries.
- See counts, averages, and statistical summaries of overlapping populations.
- Segment overlapping audiences by agreed-upon attributes.

What each party **cannot** do:
- Run `SELECT *` on the other party's data.
- Export individual-level records.
- Reverse-engineer hashed identifiers.
- Run unapproved ad-hoc queries.

```sql
-- Example: Conversion analysis without exposing individual data
-- "Of users who saw our ad on the publisher's platform, what percentage purchased?"

SELECT
    b.content_category AS ad_placement,
    COUNT(DISTINCT a.hashed_email) AS converters,
    COUNT(DISTINCT b.hashed_email) AS total_exposed,
    ROUND(COUNT(DISTINCT a.hashed_email) / COUNT(DISTINCT b.hashed_email) * 100, 2)
        AS conversion_rate_pct
FROM advertiser_data.shared.v_hashed_customers a
INNER JOIN publisher_data.shared.v_hashed_audience b
    ON a.hashed_email = b.hashed_email
WHERE a.purchase_count > 0
  AND b.impression_count > 0
GROUP BY b.content_category
HAVING COUNT(DISTINCT b.hashed_email) >= 50  -- Stronger threshold for rate calculations
ORDER BY conversion_rate_pct DESC;
```

---

## Use Cases by Industry

### Advertising

The original and most common clean room use case:

- **Audience Overlap:** An advertiser matches their CRM list against a publisher's audience to estimate reach.
- **Campaign Measurement:** Measure ad effectiveness by joining ad exposure data with conversion data.
- **Lookalike Modeling:** Build audience segments based on characteristics of overlapping high-value users.
- **Frequency Capping:** Understand cross-platform exposure without sharing user-level data.

### Healthcare

- **Clinical Trial Recruitment:** A pharma company matches patient criteria against a health system's population to estimate eligible patients -- without accessing patient records.
- **Drug Efficacy Studies:** Join claims data from an insurer with clinical data from a hospital to study treatment outcomes.
- **Population Health:** Public health agencies analyze disease patterns across multiple health systems without centralizing PHI.

```sql
-- Healthcare example: Estimate eligible patients for a clinical trial
-- (Both parties only see aggregate results)

SELECT
    h.age_group,
    h.geographic_region,
    COUNT(DISTINCT h.hashed_patient_id) AS eligible_patients
FROM pharma_data.shared.v_trial_criteria p
INNER JOIN health_system_data.shared.v_hashed_patients h
    ON p.condition_code = h.diagnosis_code
WHERE h.age_group BETWEEN '45-54' AND '65-74'
  AND h.last_visit_date >= DATEADD('month', -6, CURRENT_DATE())
GROUP BY h.age_group, h.geographic_region
HAVING COUNT(DISTINCT h.hashed_patient_id) >= 50  -- HIPAA-aligned threshold
ORDER BY eligible_patients DESC;
```

### Financial Services

- **Fraud Detection:** Banks collaborate to identify fraud patterns across institutions without sharing customer data.
- **Credit Risk:** Combine credit data from multiple sources for risk assessment at the aggregate level.
- **AML/KYC:** Share suspicious activity patterns (not individual records) across compliance teams.

---

## Clean Room vs Data Sharing

| Aspect | Secure Data Sharing | Data Clean Rooms |
|--------|-------------------|-----------------|
| **Data Visibility** | Consumer sees all shared rows/columns | Neither party sees the other's raw data |
| **Query Freedom** | Consumer can run any query | Only pre-approved queries/procedures |
| **Direction** | One-way (provider to consumer) | Bi-directional (both parties contribute) |
| **Privacy Controls** | Secure views, masking | Aggregation thresholds, join policies, output validation |
| **Use Case** | Data distribution, analytics enrichment | Privacy-preserving joint analytics |
| **Complexity** | Low to moderate | High (requires policy design and governance) |
| **Output** | Full query results | Aggregate-only results |

**Key insight for interviews:** Clean rooms are **built on top of** data sharing infrastructure but add a critical governance and privacy layer.

### Samooha Clean Room Platform

**Samooha** (acquired by Snowflake) provides a managed, no-code/low-code clean room platform that simplifies setup and operation:

- **UI-Driven Setup:** Configure clean rooms through a web interface rather than writing SQL.
- **Pre-Built Templates:** Common analyses (overlap, measurement, attribution) are available as templates.
- **Policy Automation:** Privacy policies and thresholds are configured through the UI and automatically enforced.
- **Multi-Party Support:** Supports clean rooms with more than two parties.
- **Differential Privacy:** Offers optional differential privacy mechanisms for stronger guarantees.
- **Audit Dashboard:** Visual audit trail of all clean room activities.

```sql
-- Samooha provides helper procedures for clean room management
-- (These are part of the Samooha app installed from the Marketplace)

-- Provider: Set up a clean room
CALL samooha_by_snowflake_local_db.provider.cleanroom_create(
    'advertising_measurement_room',
    'ADVERTISER_AND_PUBLISHER'
);

-- Provider: Add data to the clean room
CALL samooha_by_snowflake_local_db.provider.link_dataset(
    'advertising_measurement_room',
    'advertiser_db.shared.v_hashed_customers'
);

-- Provider: Define approved analysis templates
CALL samooha_by_snowflake_local_db.provider.add_analysis_template(
    'advertising_measurement_room',
    'overlap_analysis',
    $$
    SELECT
        {{dimensions}},
        COUNT(DISTINCT a.hashed_id) AS overlap_count
    FROM {{source_a}} a
    INNER JOIN {{source_b}} b ON a.hashed_id = b.hashed_id
    GROUP BY {{dimensions}}
    HAVING COUNT(DISTINCT a.hashed_id) >= 25
    $$
);

-- Consumer: Run an approved analysis
CALL samooha_by_snowflake_local_db.consumer.run_analysis(
    'advertising_measurement_room',
    'overlap_analysis',
    ['age_bracket', 'region']  -- Approved dimensions
);
```

**Why Samooha matters for interviews:** It demonstrates Snowflake's commitment to making clean rooms accessible and production-ready. Mentioning it shows you understand the practical, operational side -- not just the theory.

---

## Common Interview Questions and Answers

### Q1: What is a Data Clean Room and why is it needed?

**A:** A Data Clean Room is a secure environment where multiple parties can collaboratively analyze their combined data without exposing raw records to each other. It is needed because regulations like GDPR, CCPA, and HIPAA restrict how personal data can be shared, while business needs demand cross-organizational analytics. Clean rooms solve this by enabling aggregate insights (overlap counts, conversion rates, demographic breakdowns) while enforcing privacy through hashed identifiers, aggregation thresholds, query restrictions, and audit logging.

### Q2: How does a Snowflake clean room differ from a third-party clean room like Google Ads Data Hub?

**A:** Snowflake clean rooms keep data in each party's own Snowflake account and allow flexible, custom analysis templates using standard SQL. Third-party clean rooms like Google Ads Data Hub operate within the vendor's infrastructure and are limited to that vendor's data ecosystem. Snowflake's approach is **vendor-neutral** -- any two Snowflake accounts can form a clean room, with any data, using custom-defined policies. It also supports multi-cloud and multi-party configurations, and with Samooha, provides a managed experience.

### Q3: How do you prevent re-identification of individuals in clean room outputs?

**A:** Multiple techniques work together:
- **K-anonymity thresholds:** Suppress any output group with fewer than a minimum number of individuals (commonly 25-50).
- **Hashed identifiers:** Use SHA-256 or similar hashing on PII before any join; raw PII never enters the clean room.
- **Differential privacy:** Add calibrated noise to query results (optional, available via Samooha).
- **Query restrictions:** Only allow pre-approved stored procedures, not ad-hoc queries.
- **Rate limiting:** Prevent repeated queries that could triangulate individuals through subtraction attacks.
- **Output auditing:** Log and review all query results for potential privacy leaks.

### Q4: Walk me through designing a clean room for an advertiser and publisher.

**A:**
1. **Define objectives:** What analyses are needed (overlap, measurement, attribution)?
2. **Agree on join keys:** Both parties hash email addresses using the same algorithm (SHA-256) before sharing.
3. **Prepare secure views:** Each party creates secure views exposing only necessary columns with hashed identifiers.
4. **Design approved queries:** Create stored procedures for each analysis type with built-in aggregation thresholds.
5. **Set up shares:** Each party shares their secure view into the clean room environment.
6. **Implement policies:** Row access policies for consent filtering, masking policies for sensitive attributes.
7. **Test and validate:** Run approved queries, verify privacy thresholds work, confirm outputs are aggregate-only.
8. **Deploy and monitor:** Enable audit logging, set up alerts for unusual query patterns, schedule regular governance reviews.

### Q5: What is the relationship between clean rooms and Snowflake Secure Data Sharing?

**A:** Clean rooms are built on top of Secure Data Sharing as the transport layer. Data Sharing provides the mechanism to make data accessible across accounts without copying. Clean rooms add a governance framework on top: query restrictions via secure stored procedures, privacy policies via row access and masking policies, aggregation enforcement via secure UDFs, and audit logging. You can think of Secure Data Sharing as the infrastructure and clean rooms as the application layer.

### Q6: What are subtraction attacks and how do clean rooms prevent them?

**A:** A subtraction attack occurs when a party runs two nearly identical queries and subtracts the results to isolate an individual. For example: Query 1 returns 1,000 users in a segment; Query 2 adds one more filter and returns 999. The attacker infers the one removed individual's attributes. Clean rooms prevent this through: aggregation minimum thresholds (groups < 25 are suppressed), differential privacy (noise makes exact counts unreliable), query rate limiting, and output comparison checks that flag suspiciously similar sequential queries.

---

## Tips

- Clean rooms are a **hot topic** in Snowflake interviews for 2025-2026. Being able to discuss them fluently demonstrates cutting-edge platform knowledge.
- Always start by explaining the **business problem** (privacy regulations + need for cross-org analytics) before diving into technical implementation.
- Know the difference between **hashing and encryption** in this context -- clean rooms typically use one-way hashing (SHA-256) for matching, not reversible encryption.
- Be prepared to discuss **limitations**: clean rooms add latency and complexity, aggregation thresholds reduce granularity, and hashed matching is not 100% accurate (email variations, multiple accounts).
- Mention **Samooha** by name -- it shows you follow Snowflake's product evolution beyond core warehousing.
- Understand that clean rooms are not just for advertising -- healthcare, financial services, and government are increasingly adopting them.
- In scenario-based interviews, always mention **consent management** -- data should only enter a clean room if users have consented to that use.
- Practice explaining clean rooms to a non-technical audience; senior engineers are often asked to communicate complex concepts to stakeholders.

---
