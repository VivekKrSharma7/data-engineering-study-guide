# Resource Monitors & Cost Control

[Back to Snowflake Index](./README.md)

---

## Overview

Cost management is a critical responsibility for Snowflake administrators and data engineers. Snowflake's consumption-based pricing model means that without proper controls, costs can escalate quickly. Resource monitors, tagging, and an understanding of the full cost model are essential tools for keeping spending under control while maintaining performance.

---

## Snowflake Pricing Model

Snowflake costs fall into three main categories:

### 1. Compute Costs (Credits)

Compute is the largest cost driver for most Snowflake accounts.

| Component | Billing Model |
|-----------|--------------|
| Virtual Warehouses | Credits per second (minimum 60 seconds) |
| Serverless Features | Credits (Snowflake-managed compute) |
| Cloud Services | Credits (free up to 10% of daily warehouse usage) |

**Warehouse credit consumption by size:**

| Size | Credits/Hour |
|------|-------------|
| X-Small | 1 |
| Small | 2 |
| Medium | 4 |
| Large | 8 |
| X-Large | 16 |
| 2X-Large | 32 |
| 3X-Large | 64 |
| 4X-Large | 128 |
| 5X-Large | 256 |
| 6X-Large | 512 |

### 2. Storage Costs

- Charged per TB per month
- Includes: active data, Time Travel data, Fail-safe data
- On-demand pricing vs. pre-purchased capacity
- Compressed storage — you pay for compressed size, not raw size

### 3. Data Transfer Costs

- Charged for data moving **out** of a Snowflake region
- Egress between regions or clouds
- No charge for data ingestion (loading into Snowflake)
- No charge for queries within the same region

### Serverless Feature Costs

These features use Snowflake-managed compute (no user warehouse needed) and are billed at a serverless credit rate:

| Feature | Billing |
|---------|---------|
| Snowpipe | Per-file processing credits |
| Automatic Clustering | Credits for reclustering |
| Materialized View Maintenance | Credits for refresh |
| Search Optimization Service | Credits for maintenance |
| Replication | Credits for data sync |
| Tasks (serverless) | Credits per run |

---

## Resource Monitors

Resource monitors are Snowflake's primary mechanism for controlling and tracking credit usage.

### What is a Resource Monitor?

A resource monitor sets a **credit quota** for a specified interval and can trigger actions (notifications, suspensions) when usage reaches defined thresholds.

### Creating Resource Monitors

```sql
-- Account-level resource monitor
CREATE OR REPLACE RESOURCE MONITOR account_monthly_monitor
  WITH
    CREDIT_QUOTA = 5000            -- 5,000 credits per interval
    FREQUENCY = MONTHLY            -- Reset monthly
    START_TIMESTAMP = '2026-03-01 00:00 UTC'
    END_TIMESTAMP = NULL           -- No end date (runs indefinitely)
  TRIGGERS
    ON 75 PERCENT DO NOTIFY        -- Alert at 75%
    ON 90 PERCENT DO NOTIFY        -- Alert at 90%
    ON 100 PERCENT DO SUSPEND      -- Suspend at 100% (finish running queries)
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;  -- Kill queries at 110%

-- Assign to account
ALTER ACCOUNT SET RESOURCE_MONITOR = account_monthly_monitor;
```

```sql
-- Warehouse-level resource monitor
CREATE OR REPLACE RESOURCE MONITOR etl_warehouse_monitor
  WITH
    CREDIT_QUOTA = 1000
    FREQUENCY = WEEKLY
    START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 80 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;

-- Assign to a specific warehouse
ALTER WAREHOUSE etl_wh SET RESOURCE_MONITOR = etl_warehouse_monitor;
```

### Trigger Actions

| Action | Behavior |
|--------|----------|
| `NOTIFY` | Sends a notification (email) to account admins. Warehouse continues running. |
| `SUSPEND` | Suspends the warehouse after all currently running queries complete. New queries are queued/rejected. |
| `SUSPEND_IMMEDIATE` | Immediately suspends the warehouse, **canceling all running queries**. Use with caution. |

### Account-Level vs Warehouse-Level Monitors

| Aspect | Account-Level | Warehouse-Level |
|--------|--------------|-----------------|
| Scope | All warehouses in the account | Specific warehouse(s) |
| Assignment | `ALTER ACCOUNT SET RESOURCE_MONITOR = ...` | `ALTER WAREHOUSE ... SET RESOURCE_MONITOR = ...` |
| Quota | Total credits across all warehouses | Credits for the assigned warehouse only |
| Limit | One per account | One per warehouse, many per account |
| Best For | Overall budget control | Per-team or per-workload cost control |

**Important:** A warehouse can have both an account-level and a warehouse-level monitor. Both are evaluated independently — whichever triggers first takes effect.

### Resource Monitor Frequency Options

```sql
-- Available frequency options
FREQUENCY = MONTHLY    -- Resets on the same day each month
FREQUENCY = WEEKLY     -- Resets on the same day each week
FREQUENCY = DAILY      -- Resets daily
FREQUENCY = NEVER      -- One-time quota, never resets
```

### Modifying Resource Monitors

```sql
-- Change the credit quota
ALTER RESOURCE MONITOR etl_warehouse_monitor SET CREDIT_QUOTA = 1500;

-- Add or change triggers
ALTER RESOURCE MONITOR etl_warehouse_monitor SET
  TRIGGERS
    ON 50 PERCENT DO NOTIFY
    ON 85 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

-- View resource monitors
SHOW RESOURCE MONITORS;
```

---

## Credit Usage Tracking

### Account Usage Views

```sql
-- Warehouse credit usage (last 30 days)
SELECT
  warehouse_name,
  SUM(credits_used) AS total_credits,
  SUM(credits_used_compute) AS compute_credits,
  SUM(credits_used_cloud_services) AS cloud_services_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- Daily credit trend
SELECT
  DATE_TRUNC('DAY', start_time) AS usage_date,
  warehouse_name,
  SUM(credits_used) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- Serverless feature credit usage
SELECT
  service_type,
  SUM(credits_used) AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY service_type
ORDER BY total_credits DESC;

-- Automatic clustering costs
SELECT
  table_name,
  SUM(credits_used) AS clustering_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY table_name
ORDER BY clustering_credits DESC;

-- Storage costs
SELECT
  usage_date,
  storage_bytes / POWER(1024, 4) AS storage_tb,
  stage_bytes / POWER(1024, 4) AS stage_tb,
  failsafe_bytes / POWER(1024, 4) AS failsafe_tb
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY usage_date DESC;

-- Data transfer costs
SELECT
  usage_date,
  source_cloud,
  source_region,
  target_cloud,
  target_region,
  bytes_transferred
FROM SNOWFLAKE.ACCOUNT_USAGE.DATA_TRANSFER_HISTORY
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY usage_date DESC;
```

### Organization Usage Views (Multi-Account)

```sql
-- Credit usage across all accounts in the organization
SELECT
  account_name,
  service_type,
  SUM(credits_used) AS total_credits
FROM SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY account_name, service_type
ORDER BY total_credits DESC;
```

---

## Tagging for Cost Allocation

Object tagging lets you assign metadata to Snowflake objects for cost tracking and chargeback.

### Setting Up Cost Allocation Tags

```sql
-- Create tags
CREATE OR REPLACE TAG cost_center ALLOWED_VALUES 'engineering', 'data_science', 'marketing', 'finance';
CREATE OR REPLACE TAG project COMMENT = 'Project name for cost allocation';
CREATE OR REPLACE TAG environment ALLOWED_VALUES 'production', 'staging', 'development';

-- Apply tags to warehouses
ALTER WAREHOUSE etl_wh SET TAG cost_center = 'engineering';
ALTER WAREHOUSE etl_wh SET TAG project = 'data_platform';
ALTER WAREHOUSE etl_wh SET TAG environment = 'production';

ALTER WAREHOUSE analytics_wh SET TAG cost_center = 'data_science';
ALTER WAREHOUSE analytics_wh SET TAG project = 'ml_pipeline';
ALTER WAREHOUSE analytics_wh SET TAG environment = 'production';

-- Apply tags to databases, schemas, or tables
ALTER DATABASE marketing_db SET TAG cost_center = 'marketing';
```

### Querying Cost by Tags

```sql
-- Credit usage by cost center
SELECT
  tag_value AS cost_center,
  SUM(credits_used) AS total_credits
FROM (
  SELECT
    wmh.warehouse_name,
    wmh.credits_used,
    tv.tag_value
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
  JOIN SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES tv
    ON wmh.warehouse_name = tv.object_name
    AND tv.tag_name = 'COST_CENTER'
    AND tv.domain = 'WAREHOUSE'
  WHERE wmh.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
)
GROUP BY tag_value
ORDER BY total_credits DESC;
```

---

## Cost Optimization Strategies

### 1. Warehouse Configuration

```sql
-- Enable auto-suspend (seconds of inactivity before suspending)
ALTER WAREHOUSE analytics_wh SET AUTO_SUSPEND = 60;   -- 1 minute

-- Enable auto-resume
ALTER WAREHOUSE analytics_wh SET AUTO_RESUME = TRUE;

-- Right-size: start small, scale up only if needed
ALTER WAREHOUSE analytics_wh SET WAREHOUSE_SIZE = 'SMALL';

-- Use multi-cluster warehouses for concurrency, not size
ALTER WAREHOUSE analytics_wh SET
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 3
  SCALING_POLICY = 'STANDARD';
```

### 2. Query Optimization

```sql
-- Use query profiling to find expensive queries
SELECT
  query_id,
  query_text,
  warehouse_name,
  total_elapsed_time / 1000 AS elapsed_seconds,
  bytes_scanned / POWER(1024, 3) AS gb_scanned,
  partitions_scanned,
  partitions_total,
  credits_used_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
ORDER BY elapsed_seconds DESC
LIMIT 20;

-- Identify queries with poor pruning (scanning too many partitions)
SELECT
  query_id,
  query_text,
  partitions_scanned,
  partitions_total,
  ROUND(partitions_scanned / NULLIF(partitions_total, 0) * 100, 2) AS pct_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND partitions_total > 100
  AND partitions_scanned / NULLIF(partitions_total, 0) > 0.8
ORDER BY partitions_scanned DESC
LIMIT 20;
```

### 3. Storage Optimization

```sql
-- Reduce Time Travel for non-critical tables (default is 1 day)
ALTER TABLE staging_raw SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- Use transient tables for staging/temporary data (no Fail-safe)
CREATE TRANSIENT TABLE staging_load (...);

-- Drop unused tables and old clones
-- Check table storage metrics
SELECT
  table_catalog,
  table_schema,
  table_name,
  active_bytes / POWER(1024, 3) AS active_gb,
  time_travel_bytes / POWER(1024, 3) AS time_travel_gb,
  failsafe_bytes / POWER(1024, 3) AS failsafe_gb,
  retained_for_clone_bytes / POWER(1024, 3) AS clone_retained_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE active_bytes > 0
ORDER BY active_bytes DESC
LIMIT 20;
```

### 4. Workload Isolation

```sql
-- Separate warehouses for different workloads
CREATE WAREHOUSE etl_wh
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  COMMENT = 'ETL pipeline workloads';

CREATE WAREHOUSE bi_wh
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 4
  SCALING_POLICY = 'STANDARD'
  COMMENT = 'BI and dashboard queries';

CREATE WAREHOUSE ds_wh
  WAREHOUSE_SIZE = 'LARGE'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE
  COMMENT = 'Data science/ML workloads';
```

### 5. Leveraging Caching

Snowflake has three layers of caching that reduce compute costs:

| Cache Layer | Scope | Duration | Benefit |
|------------|-------|----------|---------|
| **Result Cache** | Cloud Services | 24 hours | Identical queries return instantly, zero warehouse cost |
| **Local Disk Cache** | Warehouse SSD | Until warehouse suspends | Repeated data access is faster |
| **Remote Disk Cache** | Shared storage | Persistent | Micro-partitions cached for access |

```sql
-- Disable result cache only if needed for testing
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Keep warehouses running slightly longer to benefit from local disk cache
-- if repeated queries are expected (trade-off with idle costs)
ALTER WAREHOUSE analytics_wh SET AUTO_SUSPEND = 300;  -- 5 minutes
```

---

## Cloud Services Cost Layer

The Cloud Services layer handles:
- Query parsing, optimization, and compilation
- Metadata management
- Access control
- Infrastructure management

**Billing rule:** Cloud Services credits are FREE up to **10% of your total daily warehouse compute usage**. You only pay for the excess.

```sql
-- Check if you are paying for cloud services
SELECT
  DATE_TRUNC('DAY', start_time) AS usage_date,
  SUM(credits_used_compute) AS compute_credits,
  SUM(credits_used_cloud_services) AS cloud_services_credits,
  SUM(credits_used_cloud_services) - (SUM(credits_used_compute) * 0.1) AS billable_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1
HAVING billable_cloud_services > 0
ORDER BY 1;
```

**Common causes of high cloud services costs:**
- Excessive `SHOW` commands or metadata queries
- Many small, short-running queries (high overhead-to-compute ratio)
- Heavy use of `INFORMATION_SCHEMA` queries
- Frequent `CLONE` operations on large hierarchies

---

## Real-World Cost Control Architecture

```sql
-- 1. Create resource monitors for each team
CREATE RESOURCE MONITOR eng_monthly WITH CREDIT_QUOTA = 2000 FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND;

CREATE RESOURCE MONITOR ds_monthly WITH CREDIT_QUOTA = 1500 FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 80 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND;

-- 2. Assign to team warehouses
ALTER WAREHOUSE eng_etl_wh SET RESOURCE_MONITOR = eng_monthly;
ALTER WAREHOUSE eng_adhoc_wh SET RESOURCE_MONITOR = eng_monthly;
ALTER WAREHOUSE ds_training_wh SET RESOURCE_MONITOR = ds_monthly;

-- 3. Create an account-level safety net
CREATE RESOURCE MONITOR account_guard WITH CREDIT_QUOTA = 8000 FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 90 PERCENT DO NOTIFY ON 100 PERCENT DO SUSPEND_IMMEDIATE;
ALTER ACCOUNT SET RESOURCE_MONITOR = account_guard;

-- 4. Tag everything for reporting
ALTER WAREHOUSE eng_etl_wh SET TAG cost_center = 'engineering';
ALTER WAREHOUSE eng_adhoc_wh SET TAG cost_center = 'engineering';
ALTER WAREHOUSE ds_training_wh SET TAG cost_center = 'data_science';

-- 5. Schedule a daily cost report (using a task)
CREATE OR REPLACE TASK daily_cost_report
  WAREHOUSE = admin_wh
  SCHEDULE = 'USING CRON 0 8 * * * America/New_York'
AS
  INSERT INTO admin.cost_reports
  SELECT
    CURRENT_DATE() AS report_date,
    warehouse_name,
    SUM(credits_used) AS daily_credits
  FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
  WHERE start_time >= DATEADD('day', -1, CURRENT_TIMESTAMP())
  GROUP BY warehouse_name;
```

---

## Common Interview Questions

### Q1: What is a Resource Monitor and how does it help control costs?

**A:** A Resource Monitor is a Snowflake object that tracks credit usage against a defined quota over a specified time interval (daily, weekly, monthly, or one-time). When usage reaches configured percentage thresholds, it can trigger actions: NOTIFY (send alerts), SUSPEND (gracefully stop the warehouse after running queries finish), or SUSPEND_IMMEDIATE (cancel all running queries and stop). Resource monitors can be applied at the account level (all warehouses) or at the individual warehouse level.

### Q2: What is the difference between SUSPEND and SUSPEND_IMMEDIATE?

**A:** `SUSPEND` allows all currently executing queries to complete before suspending the warehouse — no work is lost, but credits continue to be consumed until those queries finish. `SUSPEND_IMMEDIATE` cancels all running queries immediately and suspends the warehouse — queries in progress are aborted and must be re-run, but it stops credit consumption instantly. Use SUSPEND for normal limits and SUSPEND_IMMEDIATE as a hard safety net.

### Q3: How does Snowflake charge for Cloud Services, and when does it become a cost concern?

**A:** Cloud Services (query parsing, optimization, metadata operations, access control) are billed in credits, but there is a daily adjustment: the first 10% of your daily warehouse compute credits covers Cloud Services at no extra charge. You only pay for Cloud Services usage that exceeds this 10% threshold. It becomes a concern when you have many small/lightweight queries with high overhead, excessive metadata queries, or heavy use of SHOW/DESCRIBE commands relative to actual compute usage.

### Q4: What are the main strategies for optimizing Snowflake costs?

**A:**
1. **Right-size warehouses** — use the smallest size that meets performance needs
2. **Set aggressive auto-suspend** — 60 seconds for most warehouses
3. **Use resource monitors** — set quotas and alerts at both account and warehouse levels
4. **Optimize queries** — ensure proper partition pruning, avoid full table scans
5. **Use transient tables** for non-critical data to eliminate Fail-safe storage costs
6. **Reduce Time Travel retention** for staging and temporary tables
7. **Separate workloads** into dedicated warehouses to enable targeted monitoring and sizing
8. **Leverage caching** — avoid disabling result cache unless necessary
9. **Use tags** for cost allocation and chargeback to create accountability
10. **Monitor serverless costs** — automatic clustering, Snowpipe, and materialized views can accumulate silently

### Q5: Can a single warehouse have both an account-level and a warehouse-level resource monitor?

**A:** Yes. Both monitors are evaluated independently. If either monitor's threshold is reached, its action takes effect. For example, a warehouse-level monitor might suspend at 500 credits, while the account-level monitor might suspend all warehouses at 5,000 total credits. Whichever condition is met first triggers.

### Q6: How do you track costs broken down by team or project?

**A:** Use Snowflake's object tagging feature. Create tags like `cost_center` or `project` and apply them to warehouses, databases, and other objects. Then join the `TAG_REFERENCES` view with usage views like `WAREHOUSE_METERING_HISTORY` to produce cost reports grouped by tag values. This enables chargeback and showback reporting.

### Q7: What serverless features consume credits, and how do you monitor them?

**A:** Serverless features include Snowpipe, Automatic Clustering, Materialized View Maintenance, Search Optimization, serverless Tasks, and Replication. Monitor them through Account Usage views: `PIPE_USAGE_HISTORY`, `AUTOMATIC_CLUSTERING_HISTORY`, `MATERIALIZED_VIEW_REFRESH_HISTORY`, `SEARCH_OPTIMIZATION_HISTORY`, `SERVERLESS_TASK_HISTORY`, and `REPLICATION_USAGE_HISTORY`. These costs are often overlooked because they run without a user-visible warehouse.

---

## Tips

1. **Always set an account-level resource monitor** as a safety net, even if you have warehouse-level monitors. This prevents runaway costs from any source.

2. **Set auto-suspend to 60 seconds** for most warehouses. The default of 600 seconds (10 minutes) wastes credits. Only increase it if you benefit from the local disk cache for repeated queries.

3. **Review the top 20 most expensive queries weekly** — a single poorly written query can consume more credits than hundreds of optimized ones.

4. **Use NOTIFY triggers at lower thresholds** (50%, 75%) and SUSPEND at higher ones (100%). This gives teams time to react before being cut off.

5. **Transient tables are your friend for staging** — they skip the 7-day Fail-safe period, saving significant storage costs for data that can be reloaded.

6. **Monitor the Cloud Services adjustment daily** — if you are consistently paying for Cloud Services beyond the 10% allowance, investigate your metadata query patterns.

7. **Create a cost dashboard** using Snowflake's Account Usage views and share it with stakeholders. Visibility drives accountability.

8. **In interviews, demonstrate awareness of ALL cost dimensions** — compute, storage, data transfer, and serverless. Many candidates only think about warehouse compute.

---
