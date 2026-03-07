# Secure Data Sharing (Direct Share)

[Back to Snowflake Index](./README.md)

---

## Overview

Snowflake Secure Data Sharing enables organizations to share live, ready-to-query data with other Snowflake accounts **without any data movement or copying**. The data remains in the provider's account, and consumers access it in place through metadata pointers. This is one of Snowflake's most powerful differentiators and a frequent topic in senior Data Engineer interviews.

---

## Key Concepts

### Data Sharing Architecture: No Data Movement or Copy

Snowflake's sharing architecture is fundamentally different from traditional approaches (FTP, APIs, ETL pipelines). When you share data:

- **No data is copied** from the provider to the consumer.
- The consumer account creates a **read-only database** backed by the provider's underlying micro-partitions in cloud storage.
- The consumer uses their **own compute (virtual warehouses)** to query the shared data -- the provider pays nothing for consumer queries.
- Data is always **live and up-to-date** -- there is no synchronization lag or stale extracts.

```
+---------------------+          Metadata Pointers          +---------------------+
|   PROVIDER ACCOUNT  | -------------------------------------> CONSUMER ACCOUNT   |
|                     |                                      |                     |
|  [Database]         |   (No data physically moves)         |  [Shared Database]  |
|  [Schema]           |                                      |  (Read-Only)        |
|  [Tables/Views]     |                                      |                     |
|  [Cloud Storage]    | <--- Consumer queries execute here   |  [Own Warehouse]    |
+---------------------+          using consumer compute      +---------------------+
```

### Creating Shares

A **share** is a Snowflake object that encapsulates data you want to make available to other accounts.

```sql
-- Create a share
CREATE SHARE sales_data_share
  COMMENT = 'Monthly sales data shared with analytics partners';

-- View existing shares
SHOW SHARES;
```

Only the **ACCOUNTADMIN** role (or a role with the CREATE SHARE privilege) can create shares.

### Adding Objects to Shares

You grant access to specific database objects within a share. You must grant in order: database -> schema -> objects.

```sql
-- Step 1: Grant usage on the database
GRANT USAGE ON DATABASE analytics_db TO SHARE sales_data_share;

-- Step 2: Grant usage on the schema
GRANT USAGE ON SCHEMA analytics_db.public TO SHARE sales_data_share;

-- Step 3: Grant SELECT on specific tables or views
GRANT SELECT ON TABLE analytics_db.public.monthly_sales TO SHARE sales_data_share;
GRANT SELECT ON TABLE analytics_db.public.product_catalog TO SHARE sales_data_share;

-- You can also grant on all tables in a schema
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_db.public TO SHARE sales_data_share;

-- Grant on a secure view (recommended for controlled access)
GRANT SELECT ON VIEW analytics_db.public.v_sales_summary TO SHARE sales_data_share;
```

**Important constraints:**
- You can only share objects from **one database** per share.
- You can share: tables, external tables, secure views, secure materialized views, and secure UDFs.
- Regular (non-secure) views **cannot** be shared.

### Granting Shares to Consumer Accounts

```sql
-- Add consumer accounts to the share
ALTER SHARE sales_data_share ADD ACCOUNTS = org1.consumer_account_1, org1.consumer_account_2;

-- You can also specify share restrictions
ALTER SHARE sales_data_share ADD ACCOUNTS = org1.consumer_account_1
  SHARE_RESTRICTIONS = FALSE;  -- Allows sharing with Business Critical to non-Business Critical accounts

-- Remove a consumer account
ALTER SHARE sales_data_share REMOVE ACCOUNTS = org1.consumer_account_2;
```

### Consumer Account Setup

On the consumer side, an ACCOUNTADMIN creates a database from the share:

```sql
-- View available shares (inbound)
SHOW SHARES;

-- Create a database from the inbound share
CREATE DATABASE partner_sales_data FROM SHARE provider_org.provider_account.sales_data_share;

-- Grant access to roles in the consumer account
GRANT IMPORTED PRIVILEGES ON DATABASE partner_sales_data TO ROLE analyst_role;

-- Now analysts can query the shared data
USE ROLE analyst_role;
SELECT * FROM partner_sales_data.public.monthly_sales
WHERE sale_date >= '2026-01-01';
```

The resulting database is **read-only** -- consumers cannot INSERT, UPDATE, DELETE, or create objects within it.

### Secure Views for Sharing

Secure views are the **recommended practice** for sharing data. They prevent consumers from seeing the underlying query definition and protect sensitive logic.

```sql
-- Create a secure view that filters data per consumer
CREATE OR REPLACE SECURE VIEW analytics_db.public.v_shared_sales AS
SELECT
    sale_id,
    product_name,
    sale_amount,
    sale_date,
    region
FROM analytics_db.internal.raw_sales
WHERE region IN ('US-EAST', 'US-WEST')  -- Only share specific regions
  AND is_deleted = FALSE;                -- Hide soft-deleted records

-- Share the secure view (not the underlying table)
GRANT SELECT ON VIEW analytics_db.public.v_shared_sales TO SHARE sales_data_share;
```

**Why secure views matter for sharing:**
- The view definition is hidden from consumers (they cannot run `SHOW VIEWS` or `GET_DDL` to see the SQL).
- The Snowflake optimizer does not expose filtered-out data through query plan optimizations.
- You control exactly which rows and columns are exposed.

### Share vs Data Replication

| Feature | Data Sharing | Data Replication |
|---------|-------------|-----------------|
| **Data Movement** | None -- metadata pointers only | Full copy of data to target account |
| **Latency** | Real-time (live data) | Near-real-time (replication lag) |
| **Consumer Compute** | Consumer pays for queries | Consumer pays for queries + replication costs |
| **Cross-Region** | Same region only (without replication) | Designed for cross-region |
| **Read/Write** | Read-only for consumer | Full read/write on replica |
| **Use Case** | Sharing with external partners | DR, geo-distributed workloads |

### Sharing Across Regions and Clouds

Direct shares only work within the **same cloud region**. To share across regions or cloud providers, you combine sharing with **database replication**:

```sql
-- Provider: Enable replication on the database
ALTER DATABASE analytics_db ENABLE REPLICATION TO ACCOUNTS org1.target_account;

-- Provider: The target account replicates the database
-- (On the target/remote account)
CREATE DATABASE analytics_db AS REPLICA OF org1.source_account.analytics_db;

-- Refresh the replica
ALTER DATABASE analytics_db REFRESH;

-- Now create a share from the replicated database in the target region
CREATE SHARE regional_sales_share;
GRANT USAGE ON DATABASE analytics_db TO SHARE regional_sales_share;
-- ... grant schemas and objects as usual
```

**Cost implication:** Cross-region sharing incurs data transfer and storage costs for the replicated data.

### Share Management

```sql
-- Describe the contents of a share (provider side)
DESC SHARE sales_data_share;

-- Show all outbound shares (provider)
SHOW SHARES LIKE 'sales%';

-- Show all inbound shares (consumer)
SHOW SHARES;

-- Show all grants in a share
SHOW GRANTS TO SHARE sales_data_share;

-- Show all grants of a share (which accounts have access)
SHOW GRANTS OF SHARE sales_data_share;

-- Modify share comment
ALTER SHARE sales_data_share SET COMMENT = 'Updated sales data share for Q1 2026';
```

### Revoking Access

```sql
-- Revoke SELECT on a specific table from the share
REVOKE SELECT ON TABLE analytics_db.public.monthly_sales FROM SHARE sales_data_share;

-- Remove a consumer account from the share
ALTER SHARE sales_data_share REMOVE ACCOUNTS = org1.consumer_account_1;

-- Drop the share entirely
DROP SHARE sales_data_share;
```

When access is revoked, the consumer's shared database immediately becomes inaccessible. No data cleanup is needed because no data was ever copied.

### Data Sharing Governance

- **ACCOUNTADMIN** role is required to create shares and manage consumer access.
- Use **secure views** to enforce row-level and column-level security.
- Audit sharing activity using the **SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY** view.
- Implement a **naming convention** for shares (e.g., `SHR_<DEPARTMENT>_<DATASET>_<VERSION>`).
- Document what is shared, with whom, and why -- maintain a sharing registry.
- Consider **data classification** before sharing (PII, PHI, financial data).
- Use **SHARE_RESTRICTIONS** cautiously -- sharing from Business Critical to non-Business Critical accounts may have compliance implications.

```sql
-- Audit: Who is consuming shared data?
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
WHERE transfer_type = 'REPLICATION'
ORDER BY start_time DESC;

-- Monitor share usage
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE database_name = 'PARTNER_SALES_DATA'  -- shared database
ORDER BY start_time DESC
LIMIT 100;
```

---

## Real-World Use Cases

1. **Data Monetization:** A data provider (e.g., weather data company) shares curated datasets with paying customers via direct shares -- no API infrastructure needed.

2. **Inter-Company Collaboration:** A parent company shares financial reporting data with subsidiaries, all on Snowflake, ensuring every subsidiary sees real-time consolidated numbers.

3. **Vendor Data Feeds:** A marketing analytics firm shares campaign performance data with its clients, using secure views to ensure each client only sees their own data.

4. **Regulatory Reporting:** A bank shares transaction data with an auditing firm's Snowflake account, providing live access without file extracts.

5. **Supply Chain Visibility:** A manufacturer shares inventory and shipment data with logistics partners for real-time supply chain coordination.

---

## Common Interview Questions and Answers

### Q1: How does Snowflake Data Sharing work without copying data?

**A:** Snowflake stores data in cloud storage as immutable micro-partitions. A share is a metadata construct that grants the consumer account read access to the same underlying micro-partitions. The consumer creates a read-only database from the share, and their own virtual warehouse processes queries against the provider's storage. No data physically moves -- only metadata pointers are exchanged. This is possible because of Snowflake's separation of storage and compute.

### Q2: Can you share data with a non-Snowflake user?

**A:** Not directly via a Snowflake share. However, Snowflake offers **reader accounts** (formerly "read-only accounts") that the provider can create and manage. A reader account is a Snowflake account provisioned and paid for by the provider, allowing non-Snowflake users to query shared data. The provider pays for the reader account's compute.

```sql
-- Create a reader account
CREATE MANAGED ACCOUNT reader_partner_1
  ADMIN_NAME = 'partner_admin',
  ADMIN_PASSWORD = 'SecurePass123!',
  TYPE = READER;
```

### Q3: What are the limitations of Snowflake Data Sharing?

**A:** Key limitations include:
- Shares are **read-only** for consumers; they cannot modify shared data.
- A share can only contain objects from **one database**.
- Only **secure views, secure UDFs, tables, and external tables** can be shared (not regular views, procedures, or stages).
- Direct sharing only works within the **same cloud region**; cross-region requires database replication.
- Consumers cannot create **clones** of shared objects.
- Time Travel is **not available** on shared data for the consumer.

### Q4: How do you ensure a consumer only sees their data in a multi-tenant share?

**A:** Use a secure view with a mapping function or the `CURRENT_ACCOUNT()` function:

```sql
CREATE OR REPLACE SECURE VIEW analytics_db.sharing.v_tenant_data AS
SELECT *
FROM analytics_db.internal.multi_tenant_table
WHERE tenant_account = CURRENT_ACCOUNT();
```

This ensures each consumer account only sees rows matching their account identifier, all through a single share.

### Q5: What is the difference between a share and a listing?

**A:** A **share** is the underlying Snowflake object that provides access to data. A **listing** is a higher-level construct used in the Snowflake Marketplace or for private exchange. Listings wrap shares with additional metadata: descriptions, sample queries, usage terms, pricing (for paid listings), and business profiles. Think of shares as the mechanism and listings as the storefront.

### Q6: How would you architect a data sharing solution for 200+ consumer accounts?

**A:** For large-scale sharing:
- Use **secure views** with tenant-aware logic (`CURRENT_ACCOUNT()`) to serve all consumers from one share when possible.
- Leverage the **Snowflake Marketplace** or **private listings** for self-service onboarding.
- Automate share management using **Snowflake's SQL API** or **Terraform provider**.
- Monitor usage with `ACCOUNT_USAGE` views and set up alerts for anomalies.
- Consider **data exchange** (private marketplace) for governed, organization-wide distribution.

---

## Tips

- Always use **secure views** rather than sharing raw tables -- this gives you control over what columns/rows are exposed and hides your logic.
- Remember that the consumer pays for their own compute when querying shared data -- the provider only pays for storage.
- When preparing for interviews, be able to articulate the **zero-copy architecture** clearly -- it is one of Snowflake's headline features.
- Know the difference between **direct shares**, **listings**, **data exchanges**, and **reader accounts** -- interviewers test nuance.
- Cross-region sharing requires **replication**, which adds cost and complexity -- be ready to discuss trade-offs.
- Shares are not versioned -- if you update the underlying table, the consumer sees the update immediately. Plan for this in your data governance strategy.
- Practice the SQL commands for creating and managing shares; interviewers may ask you to write them from memory.

---
