# Reader Accounts & Data Exchange

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Reader (Managed) Accounts](#reader-managed-accounts)
2. [Creating Reader Accounts](#creating-reader-accounts)
3. [Limitations of Reader Accounts](#limitations-of-reader-accounts)
4. [Resource Monitoring for Reader Accounts](#resource-monitoring-for-reader-accounts)
5. [Snowflake Data Exchange (Private Marketplace)](#snowflake-data-exchange-private-marketplace)
6. [Creating a Data Exchange](#creating-a-data-exchange)
7. [Exchange Administration](#exchange-administration)
8. [Listing Management](#listing-management)
9. [Exchange vs Direct Share vs Marketplace Comparison](#exchange-vs-direct-share-vs-marketplace-comparison)
10. [Common Interview Questions](#common-interview-questions)
11. [Tips](#tips)

---

## Reader (Managed) Accounts

A **Reader Account** (also called a **Managed Account**) is a Snowflake account created by a data provider to allow consumers who do **not** have their own Snowflake account to access shared data. The provider's account hosts, manages, and pays for the compute resources used by the reader account.

### Key Characteristics

- Reader accounts are created and fully managed by the **provider** account.
- The provider is billed for all compute (warehouse) and storage costs incurred by the reader account.
- Reader accounts can only consume data shared **from the provider that created them** — they cannot consume shares from other Snowflake accounts.
- They are ideal for sharing data with external parties (customers, partners, regulators) who do not use Snowflake.

### How It Fits Into Snowflake Sharing

| Scenario | Solution |
|----------|----------|
| Consumer already has a Snowflake account | Direct Share (standard Secure Data Sharing) |
| Consumer does NOT have a Snowflake account | Reader Account |
| Many consumers, including unknown ones | Snowflake Marketplace / Data Exchange |

---

## Creating Reader Accounts

Only **ACCOUNTADMIN** (or a role with the `CREATE ACCOUNT` privilege) on the provider account can create a reader account.

```sql
-- Step 1: Create the reader (managed) account
CREATE MANAGED ACCOUNT data_consumer_acct
  ADMIN_NAME = 'consumer_admin',
  ADMIN_PASSWORD = 'StrongP@ssw0rd!',
  TYPE = READER;

-- Step 2: View managed accounts
SHOW MANAGED ACCOUNTS;

-- Step 3: Create a share and grant privileges
CREATE SHARE sales_share;
GRANT USAGE ON DATABASE sales_db TO SHARE sales_share;
GRANT USAGE ON SCHEMA sales_db.public TO SHARE sales_share;
GRANT SELECT ON TABLE sales_db.public.orders TO SHARE sales_share;

-- Step 4: Add the reader account to the share
ALTER SHARE sales_share ADD ACCOUNTS = data_consumer_acct;
```

### Post-Creation Setup (Inside the Reader Account)

The reader account admin logs in and creates a warehouse and database from the share:

```sql
-- Inside the reader account
CREATE WAREHOUSE reader_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- Create a database from the inbound share
CREATE DATABASE shared_sales_db FROM SHARE provider_account.sales_share;

-- Query shared data
SELECT * FROM shared_sales_db.public.orders LIMIT 100;
```

---

## Limitations of Reader Accounts

Reader accounts have several important restrictions compared to full Snowflake accounts:

| Limitation | Details |
|------------|---------|
| **Single provider only** | Can only consume shares from the provider that created the account |
| **No outbound sharing** | Cannot create shares or share data with others |
| **No replication** | Cannot use database or account replication features |
| **Provider pays compute** | All warehouse costs are billed to the provider account |
| **Limited features** | Cannot use Snowpipe, tasks, streams, or other advanced features |
| **No Marketplace access** | Cannot browse or subscribe to the Snowflake Marketplace |
| **User management** | The provider cannot directly manage users inside the reader account, but can drop the account |
| **No data loading** | Reader accounts cannot load data into the shared database (read-only by design) |

### Real-World Example

A financial analytics firm shares quarterly reports with regulatory bodies. The regulators do not have Snowflake accounts, so the firm creates reader accounts for each regulator, grants access to the relevant share, and monitors compute usage via resource monitors to control costs.

---

## Resource Monitoring for Reader Accounts

Since the **provider pays** for reader account compute, resource monitors are critical to prevent runaway costs.

```sql
-- Create a resource monitor for a reader account
CREATE RESOURCE MONITOR reader_monitor
  WITH
    CREDIT_QUOTA = 100          -- Monthly credit limit
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
      ON 75 PERCENT DO NOTIFY   -- Alert at 75%
      ON 90 PERCENT DO NOTIFY   -- Alert at 90%
      ON 100 PERCENT DO SUSPEND -- Suspend warehouses at 100%
;

-- Assign the resource monitor to the reader account's warehouse
-- (Done from the provider account context)
ALTER WAREHOUSE reader_wh SET RESOURCE_MONITOR = reader_monitor;
```

### Monitoring Usage

```sql
-- Check credit usage by managed accounts
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE SERVICE_TYPE = 'WAREHOUSE_METERING_READER'
ORDER BY USAGE_DATE DESC;

-- View all managed accounts and their status
SHOW MANAGED ACCOUNTS;
```

---

## Snowflake Data Exchange (Private Marketplace)

A **Data Exchange** is a private, invite-only hub for sharing data among a curated group of accounts. Think of it as a **private marketplace** controlled by an administrator.

### Key Concepts

- **Provider**: Publishes data listings to the exchange.
- **Consumer**: Browses and subscribes to data listings within the exchange.
- **Administrator**: Manages membership, approves listings, and governs the exchange.
- Unlike the public Snowflake Marketplace, a Data Exchange is restricted to invited members only.

### Use Cases

| Use Case | Description |
|----------|-------------|
| **Intra-organization** | Share data between business units or subsidiaries across different Snowflake accounts |
| **Industry consortiums** | Healthcare providers sharing anonymized data for research |
| **Vendor-client** | A SaaS vendor sharing usage analytics with enterprise clients |
| **Regulatory reporting** | Financial institutions sharing compliance data with regulators |

---

## Creating a Data Exchange

Data Exchanges are provisioned through Snowflake — you request one via the Snowflake UI or by contacting Snowflake support.

### Steps to Set Up

1. **Request a Data Exchange** from Snowflake (via the Snowsight UI under "Data" > "Private Sharing" > "Data Exchanges").
2. **Assign an Exchange Admin** who manages the exchange.
3. **Invite members** (both providers and consumers).
4. **Providers publish listings** to the exchange.
5. **Consumers discover and subscribe** to listings.

```sql
-- There is no DDL to create a data exchange — it is managed through the UI.
-- However, once set up, providers publish shares as listings.

-- Provider: Create a share to back a listing
CREATE SHARE analytics_share;
GRANT USAGE ON DATABASE analytics_db TO SHARE analytics_share;
GRANT USAGE ON SCHEMA analytics_db.reporting TO SHARE analytics_share;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_db.reporting TO SHARE analytics_share;
```

---

## Exchange Administration

The Exchange Admin has control over the following:

### Membership Management

- **Add/remove members**: Control which Snowflake accounts can participate.
- **Assign roles**: Designate accounts as providers, consumers, or both.
- **Approve listing requests**: Providers submit listings; the admin can review and approve them.

### Governance

| Admin Capability | Description |
|-----------------|-------------|
| **Membership approval** | Invite or remove Snowflake accounts |
| **Listing approval** | Review, approve, or reject published listings |
| **Usage monitoring** | Track which consumers are accessing which listings |
| **Branding** | Customize the exchange name and description |
| **Categories** | Organize listings into categories for easier discovery |

---

## Listing Management

A **listing** is a published data share within the exchange (or the public Marketplace). Listings include metadata that helps consumers understand and discover the data.

### Listing Components

- **Title and description**: What the data is about.
- **Sample queries**: Example SQL to help consumers get started.
- **Data dictionary**: Column descriptions and business context.
- **Refresh frequency**: How often the data is updated.
- **Terms of use**: Legal and usage constraints.
- **Underlying share**: The Snowflake share object backing the listing.

### Listing Types

| Type | Description |
|------|-------------|
| **Standard listing** | Free data shared with exchange members |
| **Personalized listing** | Customized data per consumer (e.g., each client sees only their data) |
| **Paid listing** | Available on the public Marketplace with commercial terms (not applicable to private exchanges) |

### Publishing a Listing (via Snowsight UI)

1. Navigate to **Data** > **Private Sharing** > select your exchange.
2. Click **Publish** > **To Exchange**.
3. Select the share, fill in metadata (title, description, sample queries).
4. Submit for admin approval.
5. Once approved, the listing is visible to exchange members.

---

## Exchange vs Direct Share vs Marketplace Comparison

| Feature | Direct Share | Data Exchange | Snowflake Marketplace |
|---------|-------------|---------------|----------------------|
| **Audience** | Specific known accounts | Curated group of accounts | Any Snowflake customer |
| **Discovery** | None (provider tells consumer) | Private catalog within exchange | Public searchable catalog |
| **Access control** | Provider adds accounts manually | Admin manages membership | Open to all (or request-based) |
| **Listing metadata** | None (just a share) | Rich metadata, descriptions, samples | Rich metadata, descriptions, samples |
| **Monetization** | Not supported | Not natively supported | Supported (paid listings) |
| **Reader accounts** | Supported | Not typically used | Not supported |
| **Setup effort** | Low | Medium (request exchange from Snowflake) | Medium (apply as provider) |
| **Governance** | Provider-controlled | Admin-controlled | Snowflake + provider controlled |
| **Best for** | 1-to-1 or small group sharing | Organization-wide or consortium sharing | Broad public or commercial data sharing |

### Real-World Scenario

A retail conglomerate with 15 brands, each on separate Snowflake accounts, creates a private Data Exchange. The central analytics team publishes curated customer insights, supply chain metrics, and financial KPIs. Each brand subscribes only to the listings relevant to them. The exchange admin ensures data governance and controls membership.

---

## Common Interview Questions

### Q1: What is a Reader Account and when would you use one?

**A:** A Reader Account (managed account) is a Snowflake account created by a data provider for consumers who do not have their own Snowflake account. The provider creates and manages the account, pays for compute and storage, and shares data via standard Snowflake shares. It is used when you need to share data with external parties who are not Snowflake customers.

---

### Q2: Who pays for the compute costs of a Reader Account?

**A:** The **provider** who created the reader account pays for all compute (warehouse) and storage costs. This is why resource monitors are critical — to prevent unexpected charges from reader account activity.

---

### Q3: Can a Reader Account consume data from multiple providers?

**A:** No. A reader account can only consume shares from the single provider account that created it. If a consumer needs data from multiple providers, they need a full Snowflake account.

---

### Q4: What is the difference between a Data Exchange and the Snowflake Marketplace?

**A:** A Data Exchange is a **private, invite-only** hub managed by an administrator where a curated group of accounts can share data. The Snowflake Marketplace is a **public** catalog open to all Snowflake customers, supporting commercial (paid) listings. Data Exchanges are ideal for intra-organization or consortium sharing, while the Marketplace is for broad public data distribution.

---

### Q5: How do you control costs for Reader Accounts?

**A:** Use **resource monitors** to set credit quotas and trigger actions (notify, suspend, suspend immediately) at specified thresholds. Assign the resource monitor to the reader account's warehouse. Additionally, configure **AUTO_SUSPEND** on warehouses to minimize idle compute time.

---

### Q6: Can a Reader Account load its own data?

**A:** No. Reader accounts are designed for **read-only** access to shared data. They cannot load data, create outbound shares, or use features like Snowpipe, tasks, or streams.

---

### Q7: How does a Data Exchange differ from a Direct Share?

**A:** A Direct Share is a point-to-point mechanism where the provider explicitly adds consumer accounts. A Data Exchange provides a **catalog experience** — providers publish listings with metadata, descriptions, and sample queries; consumers browse, discover, and subscribe. The exchange admin governs membership and listing approval. Direct shares are simpler but lack discoverability and governance features.

---

### Q8: What are the steps to share data with a non-Snowflake user?

**A:**
1. Create a managed (reader) account using `CREATE MANAGED ACCOUNT`.
2. Create a share and grant privileges on the desired objects.
3. Add the reader account to the share with `ALTER SHARE ... ADD ACCOUNTS`.
4. Provide the reader account URL and admin credentials to the consumer.
5. The consumer logs in, creates a warehouse, creates a database from the share, and queries the data.
6. Set up resource monitors to control costs.

---

## Tips

1. **Always set resource monitors** on reader account warehouses. Without them, you have no cost controls, and the provider foots the bill.
2. **Reader accounts are not a substitute for full accounts.** If the consumer needs to load data, run transformations, or access multiple shares from different providers, they need a standard Snowflake account.
3. **Data Exchanges require a Snowflake request** — you cannot create one purely via SQL or the API. Plan for lead time.
4. **Use secure views** in your shares to control row-level and column-level access. This applies whether sharing via direct share, exchange, or marketplace.
5. **Document your listings thoroughly.** Good metadata (descriptions, sample queries, data dictionaries) dramatically increases adoption within a Data Exchange.
6. **Monitor reader account activity** using the `SNOWFLAKE.ACCOUNT_USAGE` schema to track credit consumption and query patterns.
7. **Consider the Marketplace** if you want to monetize your data or reach a broader audience beyond your known partners.
8. **Reader accounts have a separate URL** — make sure to communicate it clearly to the consumer along with the initial admin credentials.

---
