# Snowflake Marketplace

[Back to Snowflake Index](./README.md)

---

## Overview

The Snowflake Marketplace is a centralized platform where data providers can publish and consumers can discover live, ready-to-query datasets and data applications -- all within the Snowflake ecosystem. It eliminates the need for ETL pipelines, file transfers, or API integrations. As a senior Data Engineer, understanding the Marketplace is essential for both consuming third-party data and architecting data products for distribution.

---

## Key Concepts

### Marketplace Architecture

The Snowflake Marketplace is built on top of Snowflake's Secure Data Sharing infrastructure. When a consumer "gets" a dataset from the Marketplace:

1. A **shared database** is created in the consumer's account (no data is copied).
2. The consumer queries the data using their **own warehouse**.
3. Data updates from the provider are **instantly available** to consumers.

This is fundamentally different from traditional data marketplaces that distribute files or API endpoints.

### Listing Types

#### Free Listings

- No cost to the consumer beyond their own Snowflake compute.
- Provider publishes data to increase visibility, build partnerships, or support open data initiatives.
- Common for reference datasets (ZIP codes, country codes, public COVID data, etc.).

```sql
-- After getting a free listing, consume it directly
SELECT *
FROM weather_data_free.public.daily_forecasts
WHERE city = 'New York'
  AND forecast_date = CURRENT_DATE();
```

#### Personalized Listings (Private)

- Shared with **specific consumer accounts** rather than publicly.
- Often used for B2B data delivery where terms are negotiated offline.
- Data may be customized per consumer.

#### Paid Listings

- Consumers pay the provider for data access.
- Pricing models include: per-query, monthly subscription, or one-time purchase.
- Snowflake handles **billing and payment processing** through the Marketplace.
- Providers set their own pricing and terms.

### Becoming a Provider

To publish on the Marketplace, a provider must:

1. **Become a Snowflake provider:** Register as a provider through the Snowflake web interface (under Data > Provider Studio).
2. **Create a listing:** Define metadata, descriptions, sample queries, usage examples, and terms of use.
3. **Attach a share:** Link one or more shares to the listing.
4. **Set pricing (if paid):** Configure pricing model and amount.
5. **Publish:** Submit the listing for Snowflake review (Snowflake validates quality and compliance).

```sql
-- Provider prepares data for the marketplace
-- Step 1: Create a dedicated database for shared data
CREATE DATABASE marketplace_products;

-- Step 2: Create a schema and populate with curated data
CREATE SCHEMA marketplace_products.weather;

CREATE TABLE marketplace_products.weather.historical_weather AS
SELECT
    location_id,
    measurement_date,
    avg_temp_celsius,
    precipitation_mm,
    humidity_pct
FROM internal_db.raw.weather_measurements
WHERE measurement_date >= '2020-01-01';

-- Step 3: Create a secure view for controlled access
CREATE OR REPLACE SECURE VIEW marketplace_products.weather.v_weather_data AS
SELECT * FROM marketplace_products.weather.historical_weather;

-- Step 4: Create a share and add objects
CREATE SHARE marketplace_weather_share;
GRANT USAGE ON DATABASE marketplace_products TO SHARE marketplace_weather_share;
GRANT USAGE ON SCHEMA marketplace_products.weather TO SHARE marketplace_weather_share;
GRANT SELECT ON VIEW marketplace_products.weather.v_weather_data TO SHARE marketplace_weather_share;

-- The listing itself is configured through the Snowflake UI (Provider Studio)
```

### Consumer Experience

From the consumer perspective:

1. **Browse:** Search and discover listings in the Marketplace UI.
2. **Preview:** View sample data, documentation, and usage examples.
3. **Get / Subscribe:** Request access (free) or purchase (paid).
4. **Query:** A shared database appears in the consumer's account, ready to query immediately.

```sql
-- Consumer: Once the listing is "gotten", query the shared database
-- The database name is chosen by the consumer during setup
USE DATABASE acquired_weather_data;

-- Explore available schemas and tables
SHOW SCHEMAS IN DATABASE acquired_weather_data;
SHOW TABLES IN SCHEMA acquired_weather_data.weather;

-- Query the data
SELECT
    location_id,
    AVG(avg_temp_celsius) AS mean_temp,
    SUM(precipitation_mm) AS total_precipitation
FROM acquired_weather_data.weather.v_weather_data
WHERE measurement_date BETWEEN '2025-01-01' AND '2025-12-31'
GROUP BY location_id
ORDER BY mean_temp DESC;

-- Join marketplace data with internal data -- the real power
SELECT
    s.store_id,
    s.store_city,
    s.daily_revenue,
    w.avg_temp_celsius,
    w.precipitation_mm
FROM internal_db.sales.daily_store_sales s
JOIN acquired_weather_data.weather.v_weather_data w
  ON s.location_id = w.location_id
  AND s.sale_date = w.measurement_date
WHERE s.sale_date >= '2026-01-01';
```

### Private Listings

Private listings are shared with **specific, named accounts** rather than the general public.

- Used for **B2B data delivery** where both parties have a relationship.
- Provider selects specific consumer accounts to receive the listing.
- Not discoverable in the public Marketplace search.
- Can be free or paid.
- Useful for enterprises sharing data across business units on separate Snowflake accounts.

### Data Products vs Data Services

| Aspect | Data Products | Data Services |
|--------|--------------|---------------|
| **Nature** | Static or regularly refreshed datasets | Live, continuously updated data feeds |
| **Example** | Historical census data, financial filings | Real-time stock prices, live weather |
| **Update Frequency** | Periodic (daily, weekly, monthly) | Continuous or near-real-time |
| **Consumer Expectation** | Point-in-time snapshots | Always-current data |
| **Pricing** | Often one-time or periodic subscription | Typically subscription-based |

Both are delivered through the same Marketplace infrastructure, but the provider's backend refresh cadence differs significantly.

### Snowflake Native Apps on Marketplace

The Marketplace also supports **Snowflake Native Apps**, which go beyond data sharing:

- **Native Apps** are full applications (code + data + UI) that run inside the consumer's Snowflake account.
- Built using the **Snowflake Native App Framework**.
- Can include stored procedures, UDFs, Streamlit dashboards, and data.
- The app's **code runs in the consumer's account** but the provider's intellectual property is protected.
- Enables providers to deliver analytics, ML models, and data transformations -- not just raw data.

```sql
-- Consumer installs a Native App from the Marketplace
-- (Installation is done through the UI, but the app appears as a database)

-- Example: Using a Native App that provides sentiment analysis
CALL sentiment_analyzer_app.analysis.analyze_text(
    'The quarterly earnings exceeded all expectations.'
);
-- Returns: { "sentiment": "positive", "confidence": 0.94 }
```

**Use cases for Native Apps:**
- Data enrichment (geocoding, entity resolution)
- Pre-built analytics dashboards
- ML model inference
- Data quality and profiling tools

### Monetization Options

Providers have several monetization models:

1. **Free:** Build brand awareness, drive adoption, complement paid offerings.
2. **Paid -- Usage-based:** Charge per query or per compute credit consumed.
3. **Paid -- Subscription:** Monthly or annual flat fee.
4. **Paid -- Custom:** Negotiate terms per consumer (common for enterprise deals).
5. **Freemium:** Offer a limited free tier with paid upgrades.

Snowflake takes a **revenue share** from paid listings.

### Marketplace Analytics

Providers can track listing performance using **Provider Studio analytics**:

- Number of consumers who viewed the listing.
- Number of "get" / installation requests.
- Query volume on shared data.
- Consumer account details (for direct shares).
- Revenue from paid listings.

```sql
-- Providers can also query Snowflake's data sharing usage metadata
SELECT
    listing_name,
    consumer_account,
    query_count,
    credits_consumed
FROM SNOWFLAKE.DATA_SHARING_USAGE.MARKETPLACE_PAID_USAGE_DAILY
WHERE listing_name = 'Weather Data Premium'
  AND usage_date >= DATEADD('day', -30, CURRENT_DATE());
```

### Data Quality Expectations

Consumers on the Marketplace expect:

- **Documentation:** Clear descriptions of every table, column, and data source.
- **Freshness:** Defined and met SLAs for data refresh frequency.
- **Schema Stability:** No breaking changes to table structures without versioning or notice.
- **Sample Queries:** Ready-to-run queries that demonstrate common use cases.
- **Data Dictionaries:** Explanation of codes, enumerations, and business logic.
- **Support:** Contact information or support channels for issues.

Providers with poor data quality get low ratings and poor adoption.

### Popular Marketplace Datasets

Common categories and examples:

| Category | Example Providers | Data Available |
|----------|------------------|----------------|
| **Weather** | Weather Source, Planalytics | Historical and forecast weather data |
| **Financial** | FactSet, Refinitiv, S&P Global | Stock prices, company financials, ESG scores |
| **Geospatial** | SafeGraph, CARTO | POI data, foot traffic, mobility |
| **Demographics** | Experian, Acxiom | Consumer demographics, market segmentation |
| **Healthcare** | IQVIA, Definitive Healthcare | Provider data, claims, drug pricing |
| **Economic** | Cybersyn, Knoema | Government statistics, economic indicators |
| **Identity** | LiveRamp, Neustar | Identity resolution, audience data |

---

## Real-World Examples

### Example 1: Enriching Internal Sales Data with Weather

A retail company wants to understand weather impact on sales:

```sql
-- Internal sales table + Marketplace weather data
SELECT
    s.region,
    s.product_category,
    DATE_TRUNC('week', s.sale_date) AS sale_week,
    SUM(s.revenue) AS weekly_revenue,
    AVG(w.avg_temp_celsius) AS avg_weekly_temp,
    SUM(w.precipitation_mm) AS total_weekly_rain
FROM internal_db.sales.transactions s
JOIN marketplace_weather.public.daily_conditions w
    ON s.store_zip = w.zip_code
    AND s.sale_date = w.observation_date
WHERE s.sale_date >= '2025-01-01'
GROUP BY 1, 2, 3
ORDER BY sale_week;
```

### Example 2: Financial Data for Risk Analysis

```sql
-- Join internal portfolio with marketplace financial data
SELECT
    p.ticker,
    p.shares_held,
    p.cost_basis,
    m.current_price,
    (m.current_price * p.shares_held) AS market_value,
    (m.current_price * p.shares_held) - p.cost_basis AS unrealized_pnl,
    m.beta,
    m.volatility_30d
FROM internal_db.portfolio.holdings p
JOIN marketplace_financials.equities.daily_metrics m
    ON p.ticker = m.ticker
    AND m.metric_date = CURRENT_DATE()
WHERE p.portfolio_id = 'GROWTH_2026';
```

---

## Common Interview Questions and Answers

### Q1: What is the Snowflake Marketplace and how does it differ from traditional data marketplaces?

**A:** The Snowflake Marketplace is a platform for discovering and consuming live data and applications directly within Snowflake. Unlike traditional marketplaces that distribute files (CSV, Parquet) or provide API endpoints, Snowflake Marketplace uses Secure Data Sharing -- meaning no data is copied. Consumers get a live, read-only database in their account that always reflects the provider's latest data. This eliminates ETL pipelines, reduces latency, and ensures data freshness. It also supports Native Apps, which deliver code and analytics alongside data.

### Q2: How would you evaluate a Marketplace dataset before recommending it to your organization?

**A:** I would evaluate across several dimensions:
- **Data Quality:** Check for completeness, accuracy, and freshness by running exploratory queries.
- **Schema Documentation:** Ensure columns are well-documented with clear data types and business definitions.
- **Refresh Frequency:** Verify the update SLA matches our requirements.
- **Historical Depth:** Ensure sufficient history for our analytical needs.
- **Coverage:** Validate the dataset covers our geographic regions, industries, or time periods.
- **Provider Reputation:** Check provider ratings, number of consumers, and reviews.
- **Cost:** Compare pricing against the business value and alternative sources.
- **Joinability:** Test how well the data joins with our internal datasets (matching keys, granularity).

### Q3: As a provider, how would you architect a Marketplace listing that serves multiple consumer segments?

**A:** I would:
1. Create **secure views** that present different slices of the underlying data for different listing tiers (e.g., basic vs. premium).
2. Use **separate shares** for each listing tier, each containing different views.
3. Provide comprehensive **sample queries** and **data dictionaries** in the listing description.
4. Set up **automated refresh pipelines** using tasks and streams to keep shared data current.
5. Monitor consumer query patterns via Provider Studio to understand usage and improve the product.
6. Version the schema and communicate changes through listing updates.

### Q4: What is the difference between a Marketplace listing and a direct share?

**A:** A direct share is a low-level Snowflake object that grants specific accounts access to specific database objects. A Marketplace listing wraps a share with a rich metadata layer: title, description, sample queries, terms of use, pricing, and a discoverable presence in the Marketplace catalog. Direct shares require you to know the consumer's account identifier; Marketplace listings allow self-service discovery. Listings also support paid access, ratings, and analytics that direct shares do not.

### Q5: How do Snowflake Native Apps on the Marketplace differ from data listings?

**A:** Data listings provide **read-only access to tables and views**. Native Apps provide **executable code** (stored procedures, UDFs, Streamlit UIs) that runs inside the consumer's account alongside optional data. Native Apps can transform data, run ML models, create dashboards, and interact with the consumer's own data -- all while keeping the provider's intellectual property protected. The provider's source code is not visible to the consumer.

### Q6: What are the cost implications of consuming Marketplace data?

**A:** For free listings, the consumer pays only for their own compute (warehouse credits) when querying. For paid listings, there is an additional fee set by the provider (subscription or usage-based). There are no storage costs for the consumer because data remains in the provider's account. However, if the consumer materializes shared data (e.g., `CREATE TABLE AS SELECT` from a shared view), they then pay for that storage. Cross-region listings may involve replication costs.

---

## Tips

- The Marketplace is a **senior-level topic** -- interviewers expect you to discuss it in the context of data strategy, not just mechanics.
- Understand the **provider vs. consumer** perspective; senior engineers may need to architect solutions on both sides.
- Be ready to discuss **data product thinking**: how to curate, document, version, and support data as a product.
- Know that Marketplace listings are **governed by Snowflake** -- there is a review process before a listing goes public.
- Native Apps are a rapidly evolving feature; mention them to demonstrate current Snowflake knowledge.
- In interviews, connect Marketplace knowledge to **business value**: reduced time-to-insight, elimination of ETL, real-time data enrichment.
- Practice joining Marketplace data with internal data in SQL -- this is the core value proposition and a likely practical interview scenario.

---
