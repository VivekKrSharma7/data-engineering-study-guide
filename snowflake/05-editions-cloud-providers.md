# Snowflake Editions & Cloud Providers

[Back to Snowflake Index](./README.md)

---

## Overview

Snowflake is available in multiple **editions** with increasing levels of features and support, and is deployed across three major **cloud providers**. Understanding the differences between editions and cloud deployment options is essential for architecture decisions and is a common topic in interviews.

---

## Key Concepts

### 1. Snowflake Editions

Snowflake offers four editions, each building on the features of the previous one:

#### Standard Edition
- Entry-level offering with full SQL data warehouse capabilities
- Complete DML/DDL support
- Automatic encryption (AES-256) of data at rest and in transit
- Time Travel up to **1 day**
- Disaster recovery through standard fail-safe (7 days)
- Basic resource monitors
- Community-level support available

#### Enterprise Edition
- Everything in Standard, plus:
- Time Travel up to **90 days**
- Multi-cluster virtual warehouses (auto-scaling)
- Materialized views
- Column-level security (dynamic data masking, external tokenization)
- Row access policies
- Search optimization service
- Data sharing with non-Snowflake users (reader accounts)
- Periodic rekeying of encrypted data
- Object tagging and tag-based masking
- Access history and object dependencies tracking (ACCOUNT_USAGE views)

#### Business Critical Edition (formerly Enterprise for Sensitive Data — ESD)
- Everything in Enterprise, plus:
- **HIPAA and PCI DSS** compliance support
- **Customer-managed encryption keys** (Tri-Secret Secure — combination of Snowflake-managed key and customer-managed key in the cloud provider's KMS)
- Enhanced security and compliance features
- **AWS PrivateLink**, **Azure Private Link**, and **Google Cloud Private Service Connect** support
- Database **failover and failback** across regions/clouds for business continuity
- Dedicated metadata store (not shared with other accounts)
- SOC 1 Type II and SOC 2 Type II compliance
- Support priority escalation

#### Virtual Private Snowflake (VPS)
- Everything in Business Critical, plus:
- **Completely isolated Snowflake environment** — dedicated compute, storage, and metadata services
- No shared infrastructure with any other Snowflake account
- Highest level of security for organizations with the strictest requirements (e.g., financial institutions, government agencies)
- Customer-dedicated Snowflake services and metadata store
- Highest cost tier

### 2. Feature Comparison Matrix

| Feature | Standard | Enterprise | Business Critical | VPS |
|---|:---:|:---:|:---:|:---:|
| Time Travel (max days) | 1 | 90 | 90 | 90 |
| Multi-cluster warehouses | No | Yes | Yes | Yes |
| Materialized views | No | Yes | Yes | Yes |
| Dynamic data masking | No | Yes | Yes | Yes |
| Row access policies | No | Yes | Yes | Yes |
| Search optimization | No | Yes | Yes | Yes |
| Periodic rekeying | No | Yes | Yes | Yes |
| Object tagging | No | Yes | Yes | Yes |
| Customer-managed keys (Tri-Secret Secure) | No | No | Yes | Yes |
| Private connectivity (PrivateLink) | No | No | Yes | Yes |
| HIPAA/PCI DSS support | No | No | Yes | Yes |
| Database failover/failback | No | No | Yes | Yes |
| Dedicated metadata store | No | No | No | Yes |
| Isolated environment | No | No | No | Yes |

### 3. Supported Cloud Providers

Snowflake runs natively on three major cloud providers:

#### Amazon Web Services (AWS)
- The original cloud provider for Snowflake
- Largest number of available regions
- External stages use **Amazon S3**
- Storage integration with S3 uses IAM roles
- PrivateLink available (Business Critical+)

#### Microsoft Azure
- External stages use **Azure Blob Storage** or **Azure Data Lake Storage Gen2 (ADLS)**
- Storage integration uses Azure service principals and tenants
- Azure Private Link available (Business Critical+)
- Good choice for organizations already invested in the Microsoft ecosystem

#### Google Cloud Platform (GCP)
- External stages use **Google Cloud Storage (GCS)**
- Storage integration uses GCP service accounts
- Google Cloud Private Service Connect available (Business Critical+)
- Fewer regions compared to AWS and Azure

```sql
-- Check your current account's cloud provider and region
SELECT CURRENT_REGION();
-- Returns format like: AWS_US_WEST_2, AZURE_WESTUS2, GCP_US_CENTRAL1

SELECT CURRENT_ACCOUNT();
```

### 4. Region Availability

Snowflake is available in numerous regions across all three cloud providers:

**AWS Regions (examples):**
- US East (N. Virginia), US East (Ohio), US West (Oregon)
- Canada (Central)
- EU (Ireland, Frankfurt, London, Paris, Stockholm, Zurich)
- Asia Pacific (Tokyo, Osaka, Singapore, Sydney, Mumbai, Seoul, Jakarta)

**Azure Regions (examples):**
- East US 2, West US 2, Central US, South Central US
- Canada Central
- West Europe, North Europe, Switzerland North, UK South
- Southeast Asia, Australia East, Japan East, Central India

**GCP Regions (examples):**
- US Central1 (Iowa), US East4 (N. Virginia)
- Europe West2 (London), Europe West4 (Netherlands)

**Government Regions:**
- **AWS GovCloud** (US-East, US-West) — for FedRAMP, ITAR, DoD workloads
- **Azure Government** (US Gov Virginia, US Gov Texas) — for US government workloads
- These regions require Business Critical or VPS edition
- Data remains within government-authorized infrastructure
- Additional compliance certifications: FedRAMP High, IL4, IL5, CJIS

### 5. Cross-Cloud Capabilities

Snowflake supports cross-cloud and cross-region operations:

#### Database Replication
```sql
-- Enable replication on the source account (Business Critical+)
ALTER DATABASE sales_db ENABLE REPLICATION TO ACCOUNTS org1.target_account;

-- On the target account, create a replica
CREATE DATABASE sales_db_replica
    AS REPLICA OF org1.source_account.sales_db;

-- Refresh the replica (can be automated with tasks)
ALTER DATABASE sales_db_replica REFRESH;
```

#### Account Replication & Failover
```sql
-- Create a failover group (Business Critical+)
CREATE FAILOVER GROUP my_failover_group
    OBJECT_TYPES = USERS, ROLES, WAREHOUSES, DATABASES, INTEGRATIONS
    ALLOWED_DATABASES = sales_db, analytics_db
    ALLOWED_ACCOUNTS = org1.dr_account
    REPLICATION_SCHEDULE = '10 MINUTE';

-- On the target account, promote to primary during disaster
ALTER FAILOVER GROUP my_failover_group PRIMARY;
```

#### Snowflake Secure Data Sharing (Cross-Cloud)
```sql
-- Listing on the Snowflake Marketplace works across clouds
-- Direct shares work within the same region
-- Cross-cloud/cross-region sharing uses auto-fulfillment (data replication behind the scenes)

-- Create a share
CREATE SHARE sales_share;
GRANT USAGE ON DATABASE sales_db TO SHARE sales_share;
GRANT USAGE ON SCHEMA sales_db.public TO SHARE sales_share;
GRANT SELECT ON TABLE sales_db.public.products TO SHARE sales_share;

-- Add accounts (same region)
ALTER SHARE sales_share ADD ACCOUNTS = org1.consumer_account;
```

### 6. Multi-Cloud Strategy

Organizations adopt multi-cloud Snowflake deployments for several reasons:

| Reason | Description |
|---|---|
| **Disaster Recovery** | Run a secondary Snowflake account in a different cloud/region for failover |
| **Data Locality** | Comply with data residency regulations (e.g., GDPR — keep EU data in EU regions) |
| **Vendor Diversification** | Reduce dependency on a single cloud provider |
| **Cost Optimization** | Leverage pricing differences or committed-use discounts across providers |
| **Ecosystem Integration** | Use AWS Snowflake for S3-heavy pipelines, Azure Snowflake for Power BI integration |

**Key Consideration:** Data transfer between clouds/regions incurs **egress charges** from the cloud provider. Factor this into architecture decisions.

### 7. Pricing Differences

Snowflake pricing varies by:

- **Edition** — each higher edition costs more per credit
- **Cloud provider** — slight price variations between AWS, Azure, and GCP
- **Region** — some regions are more expensive than others (e.g., government regions)
- **On-demand vs. pre-purchased capacity** — capacity pricing offers discounts for upfront commitment

**Pricing components:**
1. **Compute** — billed per credit (per-second billing, 60-second minimum)
2. **Storage** — billed per TB per month (on-demand or capacity)
3. **Data transfer** — billed for data egress between regions or cloud providers
4. **Serverless** — separate billing for Snowpipe, auto-clustering, materialized views, etc.

```sql
-- Monitor credit usage by edition-relevant features
-- Check overall consumption
SELECT * FROM snowflake.organization_usage.usage_in_currency_daily
WHERE usage_date >= DATEADD('month', -1, CURRENT_DATE())
ORDER BY usage_date DESC;

-- Check warehouse credit consumption
SELECT warehouse_name,
       SUM(credits_used) AS total_credits,
       SUM(credits_used_compute) AS compute_credits,
       SUM(credits_used_cloud_services) AS cs_credits
FROM snowflake.account_usage.warehouse_metering_history
WHERE start_time >= DATEADD('month', -1, CURRENT_DATE())
GROUP BY warehouse_name
ORDER BY total_credits DESC;
```

### 8. Choosing the Right Edition

**Choose Standard when:**
- Budget is the primary concern
- 1-day Time Travel is sufficient
- No compliance requirements (HIPAA, PCI, etc.)
- Concurrency is low (no need for multi-cluster warehouses)

**Choose Enterprise when:**
- You need extended Time Travel (up to 90 days)
- Concurrency requires multi-cluster auto-scaling
- Column-level security (masking) or row access policies are needed
- Materialized views or search optimization are beneficial
- Most common choice for production workloads

**Choose Business Critical when:**
- Regulatory compliance is required (HIPAA, PCI DSS, SOC)
- Customer-managed encryption keys are mandated
- Private connectivity (PrivateLink) is required by security policy
- Cross-region/cross-cloud failover is needed for DR
- Handling sensitive data (PII, PHI, financial data)

**Choose VPS when:**
- Maximum isolation is required (no shared infrastructure)
- Government or defense sector workloads
- Strictest data security and sovereignty requirements

---

## Real-World Example: Edition Selection for a Healthcare Company

A healthcare analytics company processes patient data (PHI) and must comply with HIPAA:

```
Requirements:
  - HIPAA compliance                    → Business Critical (minimum)
  - Customer-managed encryption keys    → Business Critical
  - Private network connectivity        → Business Critical (PrivateLink)
  - 90-day Time Travel for audit        → Enterprise+ (included in Business Critical)
  - Dynamic data masking on PII         → Enterprise+ (included in Business Critical)
  - Multi-region DR                     → Business Critical (failover groups)

Decision: Business Critical edition on AWS (US East)
          with failover to AWS (US West)
```

---

## Common Interview Questions

### Q1: What are the four Snowflake editions and their key differentiators?
**A:** The four editions are **Standard** (basic features, 1-day Time Travel), **Enterprise** (multi-cluster warehouses, 90-day Time Travel, masking policies, materialized views), **Business Critical** (HIPAA/PCI compliance, Tri-Secret Secure customer-managed keys, PrivateLink, cross-region failover), and **VPS** (fully isolated environment with dedicated infrastructure). Each edition includes all features of the editions below it.

### Q2: Which edition is required for multi-cluster warehouses?
**A:** Enterprise edition or higher. Multi-cluster warehouses enable auto-scaling to handle concurrency spikes.

### Q3: What is Tri-Secret Secure?
**A:** Tri-Secret Secure is a Business Critical feature that combines a Snowflake-managed encryption key with a customer-managed key (stored in the cloud provider's KMS — AWS KMS, Azure Key Vault, or GCP Cloud KMS). Both keys are required to decrypt data, giving the customer the ability to revoke access by disabling their key.

### Q4: Which cloud providers does Snowflake support?
**A:** AWS, Microsoft Azure, and Google Cloud Platform. Snowflake's architecture is cloud-agnostic — the same SQL, features, and behavior work identically across all three providers.

### Q5: Can you share data between Snowflake accounts on different cloud providers?
**A:** Yes. Direct shares work within the same region. For cross-region or cross-cloud sharing, Snowflake uses **auto-fulfillment** which replicates the shared data to the consumer's region. Listings on the Snowflake Marketplace also work across clouds.

### Q6: What is the difference between Business Critical and VPS?
**A:** Business Critical provides compliance features, customer-managed keys, and private connectivity but still runs on shared Snowflake infrastructure (securely isolated through software). VPS provides a **completely dedicated, physically isolated** Snowflake environment — separate compute instances, metadata store, and storage — for organizations with the strictest isolation requirements.

### Q7: How does Time Travel differ across editions?
**A:** Standard edition supports up to 1 day of Time Travel. Enterprise and above support up to 90 days. The Time Travel retention period is configurable per table using the `DATA_RETENTION_TIME_IN_DAYS` parameter.

```sql
-- Set Time Travel to 90 days (Enterprise+)
ALTER TABLE sensitive_data SET DATA_RETENTION_TIME_IN_DAYS = 90;

-- Use Time Travel to query historical data
SELECT * FROM sensitive_data AT(OFFSET => -3600);        -- 1 hour ago
SELECT * FROM sensitive_data AT(TIMESTAMP => '2025-12-01 00:00:00'::TIMESTAMP);
SELECT * FROM sensitive_data BEFORE(STATEMENT => '<query_id>');
```

### Q8: What are government regions and which editions support them?
**A:** Government regions (AWS GovCloud, Azure Government) are isolated cloud regions that meet strict US government compliance requirements (FedRAMP, ITAR, DoD). They require Business Critical or VPS edition and provide additional certifications such as FedRAMP High, IL4/IL5, and CJIS compliance.

---

## Tips

- **Enterprise is the most commonly deployed edition** — it covers the majority of production use cases with multi-cluster warehouses, extended Time Travel, and data governance features.
- **Edition upgrades are non-disruptive** — you can upgrade from Standard to Enterprise (or higher) without downtime or data migration. Downgrades are not supported.
- **PrivateLink requires Business Critical** — this is a common exam question. If an interview mentions "no public internet access to Snowflake," the answer is Business Critical with PrivateLink.
- **Know which features require which edition** — interviewers often ask "which edition do you need for X?" The most commonly tested boundaries are: Standard vs. Enterprise (multi-cluster, materialized views, masking) and Enterprise vs. Business Critical (compliance, Tri-Secret Secure, PrivateLink).
- **Cross-cloud replication incurs data transfer costs** — be aware of egress charges when designing multi-cloud architectures.
- **Region selection matters** — choose regions close to your users/data sources for lower latency and check that your desired features are available in that region.
