# Account & Database Replication

[Back to Snowflake Index](./README.md)

---

## Overview

Snowflake replication enables you to copy databases, schemas, and account-level objects across regions and cloud providers for disaster recovery (DR), data locality, and business continuity. Replication ensures that a secondary deployment can take over if the primary becomes unavailable, with support for both planned and unplanned failover.

---

## Key Concepts

### Cross-Region and Cross-Cloud Replication

Snowflake supports replication between:
- **Same cloud, different regions** (e.g., AWS us-east-1 to AWS eu-west-1)
- **Different cloud providers** (e.g., AWS to Azure, Azure to GCP)

This is a unique Snowflake capability — your data platform is not locked to a single cloud or region.

```
Primary Account (AWS us-east-1)
    │
    ├── Replication Group ──► Secondary Account (AWS eu-west-1)    [Cross-region]
    │
    └── Replication Group ──► Secondary Account (Azure westus2)    [Cross-cloud]
```

### Replication Groups vs Failover Groups

**Replication Group:**
- Replicates objects from a primary account to one or more secondary accounts
- Provides **read-only** access to replicated objects on the secondary
- Used for data distribution and read scaling

**Failover Group:**
- Everything a replication group does, PLUS the ability to **promote** the secondary to primary
- Enables DR — the secondary can become the new primary if the original fails
- Supports **client redirect** so applications can automatically connect to the new primary

```sql
-- Create a failover group (supports both replication and failover)
CREATE FAILOVER GROUP my_failover_group
  OBJECT_TYPES = DATABASES, USERS, ROLES, WAREHOUSES, INTEGRATIONS
  ALLOWED_DATABASES = production, analytics
  ALLOWED_ACCOUNTS = org_name.secondary_account
  REPLICATION_SCHEDULE = '10 MINUTE';

-- Create a replication group (replication only, no failover)
CREATE REPLICATION GROUP my_replication_group
  OBJECT_TYPES = DATABASES
  ALLOWED_DATABASES = analytics
  ALLOWED_ACCOUNTS = org_name.reporting_account
  REPLICATION_SCHEDULE = '60 MINUTE';
```

### What Can Be Replicated?

| Object Type | Replication Group | Failover Group |
|-------------|:-:|:-:|
| Databases (and all contained objects) | Yes | Yes |
| Users | Yes | Yes |
| Roles | Yes | Yes |
| Grants | Yes | Yes |
| Warehouses | Yes | Yes |
| Resource Monitors | No | No |
| Integrations | Yes | Yes |
| Network Policies | Yes | Yes |
| Parameters | Yes | Yes |
| Shares (outbound) | Yes | Yes |

---

## Setting Up Replication

### Step 1: Enable Replication on the Primary Account

```sql
-- Run on the PRIMARY account

-- Enable replication for the organization
-- (This is typically done at the organization level by ORGADMIN)
SELECT SYSTEM$GLOBAL_ACCOUNT_SET_PARAMETER(
  'org_name.primary_account', 'ENABLE_ACCOUNT_DATABASE_REPLICATION', 'true'
);
```

### Step 2: Create a Failover Group on the Primary

```sql
-- Run on the PRIMARY account
CREATE FAILOVER GROUP production_dr
  OBJECT_TYPES = DATABASES, USERS, ROLES, WAREHOUSES, INTEGRATIONS
  ALLOWED_DATABASES = production, analytics, common
  ALLOWED_ACCOUNTS = org_name.dr_account
  REPLICATION_SCHEDULE = '10 MINUTE';
```

### Step 3: Create the Secondary Failover Group

```sql
-- Run on the SECONDARY account
CREATE FAILOVER GROUP production_dr
  AS REPLICA OF org_name.primary_account.production_dr;
```

### Step 4: Initial and Ongoing Replication

The initial replication copies all data and metadata. Subsequent refreshes are **incremental** — only changes since the last refresh are transferred.

```sql
-- Manual refresh (if not using a schedule)
ALTER FAILOVER GROUP production_dr REFRESH;

-- Check refresh status
SELECT *
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_PROGRESS('PRODUCTION_DR'));
```

---

## Scheduling Replication

```sql
-- Set a replication schedule (minimum 10 minutes)
ALTER FAILOVER GROUP production_dr SET
  REPLICATION_SCHEDULE = '10 MINUTE';

-- Use CRON for specific scheduling
ALTER FAILOVER GROUP production_dr SET
  REPLICATION_SCHEDULE = 'USING CRON 0 */2 * * * America/New_York';  -- Every 2 hours
```

### Scheduling Considerations

- Minimum interval: **10 minutes**
- Snowflake manages the replication compute — no user warehouse required
- Replication is **incremental** after the initial sync
- If a refresh is still running when the next scheduled refresh is due, it is skipped

---

## Failover and Failback

### Planned Failover (Controlled Switchover)

```sql
-- Step 1: On the SECONDARY account, promote it to primary
ALTER FAILOVER GROUP production_dr PRIMARY;

-- The secondary is now the primary.
-- The former primary automatically becomes a secondary.
-- Client redirect (if configured) routes traffic to the new primary.
```

### Unplanned Failover (Disaster Recovery)

If the primary account or region becomes unavailable:

```sql
-- On the SECONDARY account, force promotion
ALTER FAILOVER GROUP production_dr PRIMARY;

-- Note: There may be data loss up to the last successful replication
-- (RPO = replication schedule interval)
```

### Failback (Returning to Original Primary)

After the original primary is restored:

```sql
-- On the ORIGINAL primary (now secondary), catch up with changes
ALTER FAILOVER GROUP production_dr REFRESH;

-- Once caught up, promote it back
ALTER FAILOVER GROUP production_dr PRIMARY;
```

---

## Client Redirect

Client redirect enables applications to automatically connect to the promoted secondary without changing connection strings.

### How It Works

1. You configure a **connection URL** that is region-independent
2. Snowflake maintains a DNS mapping to the current primary
3. When failover occurs, the DNS is updated to point to the new primary
4. Applications reconnect automatically (after existing connections drop)

```sql
-- Enable client redirect on the failover group
ALTER FAILOVER GROUP production_dr SET
  ALLOWED_ACCOUNTS = org_name.dr_account
  ENABLE_CLIENT_REDIRECT = TRUE;
```

### Connection URL Format

```
# Standard connection (region-specific)
org_name-primary_account.snowflakecomputing.com

# Connection URL for client redirect (organization-level)
org_name-connection_name.snowflakecomputing.com
```

```sql
-- Create a connection object
CREATE CONNECTION my_connection
  AS REPLICA OF org_name.primary_account.my_connection;

-- Alter the connection to enable failover
ALTER CONNECTION my_connection PRIMARY;
```

---

## Monitoring Replication

### Replication Usage History

```sql
-- Monitor replication costs
SELECT
  database_name,
  credits_used,
  bytes_transferred,
  start_time,
  end_time
FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

-- Daily replication costs
SELECT
  DATE_TRUNC('DAY', start_time) AS replication_date,
  SUM(credits_used) AS total_credits,
  SUM(bytes_transferred) / POWER(1024, 3) AS total_gb_transferred
FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1;
```

### Replication Group Refresh History

```sql
-- Check refresh status and history
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY
WHERE replication_group_name = 'PRODUCTION_DR'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;

-- Check current refresh progress (real-time)
SELECT *
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_PROGRESS('PRODUCTION_DR'));
```

### Replication Lag Monitoring

```sql
-- Check how far behind the secondary is
-- Run on the SECONDARY account
SELECT
  replication_group_name,
  phase_name,
  start_time,
  end_time,
  progress,
  details
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_PROGRESS('PRODUCTION_DR'));

-- Alternatively, compare timestamps
-- On secondary, check the last refresh time
SHOW REPLICATION GROUPS;
-- Look at the 'replication_schedule' and 'next_scheduled_refresh' columns
```

---

## Costs of Replication

| Cost Component | Description |
|---------------|-------------|
| **Compute (Credits)** | Snowflake-managed serverless compute for replication operations |
| **Data Transfer** | Network transfer costs for moving data between regions/clouds |
| **Storage** | Secondary account stores a full copy of replicated data |

### Cost Optimization for Replication

```sql
-- Replicate only necessary databases (not everything)
ALTER FAILOVER GROUP production_dr SET
  ALLOWED_DATABASES = production, critical_analytics;
  -- Exclude development, staging, and non-critical databases

-- Use longer replication intervals for less critical data
CREATE REPLICATION GROUP reporting_replication
  OBJECT_TYPES = DATABASES
  ALLOWED_DATABASES = reporting
  ALLOWED_ACCOUNTS = org_name.secondary_account
  REPLICATION_SCHEDULE = '60 MINUTE';  -- Hourly is sufficient for reporting
```

---

## Disaster Recovery Strategy

### Key DR Metrics

| Metric | Definition | Snowflake Replication |
|--------|-----------|----------------------|
| **RPO** (Recovery Point Objective) | Maximum acceptable data loss | Equal to replication schedule interval (minimum 10 min) |
| **RTO** (Recovery Time Objective) | Maximum acceptable downtime | Minutes (time to promote secondary + client redirect) |

### DR Architecture Example

```
                    Normal Operation
                    ================
    Users ──► Primary (AWS us-east-1)
                    │
                    │ Replication every 10 min
                    ▼
              Secondary (AWS eu-west-1) [read-only]


                    After Failover
                    ===============
    Users ──► New Primary (AWS eu-west-1) [read-write]

              Old Primary (AWS us-east-1) [unavailable or demoted]
```

### Comprehensive DR Setup

```sql
-- PRIMARY ACCOUNT SETUP

-- 1. Create failover group with all critical objects
CREATE FAILOVER GROUP enterprise_dr
  OBJECT_TYPES = DATABASES, USERS, ROLES, WAREHOUSES, INTEGRATIONS
  ALLOWED_DATABASES = production, finance, customer_data
  ALLOWED_ACCOUNTS = org_name.dr_west, org_name.dr_eu
  REPLICATION_SCHEDULE = '10 MINUTE';

-- 2. Verify replication is working
SHOW FAILOVER GROUPS;

-- SECONDARY ACCOUNT SETUP (run on each secondary)

-- 3. Create the replica of the failover group
CREATE FAILOVER GROUP enterprise_dr
  AS REPLICA OF org_name.primary_account.enterprise_dr;

-- 4. Verify secondary is receiving data
SHOW FAILOVER GROUPS;
SELECT * FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_PROGRESS('ENTERPRISE_DR'));

-- DR TEST (quarterly recommended)

-- 5. Promote secondary to primary
ALTER FAILOVER GROUP enterprise_dr PRIMARY;

-- 6. Verify applications connect to new primary
-- 7. Run validation queries

-- 8. Fail back to original primary
-- (On original primary, now secondary)
ALTER FAILOVER GROUP enterprise_dr REFRESH;
ALTER FAILOVER GROUP enterprise_dr PRIMARY;
```

---

## Database Replication (Legacy Approach)

Before replication groups and failover groups, Snowflake supported database-level replication. This approach is still functional but less flexible.

```sql
-- Legacy: Replicate a single database
-- On PRIMARY
ALTER DATABASE production ENABLE REPLICATION TO ACCOUNTS org_name.secondary_account;

-- On SECONDARY
CREATE DATABASE production AS REPLICA OF org_name.primary_account.production;

-- Refresh manually
ALTER DATABASE production REFRESH;
```

**Limitations of legacy database replication:**
- Replicates only databases (not users, roles, warehouses)
- No automatic scheduling (must use tasks for scheduling)
- No client redirect
- No failover group coordination

Use **replication groups and failover groups** for new implementations.

---

## Common Interview Questions

### Q1: What is the difference between a Replication Group and a Failover Group?

**A:** Both replicate objects from a primary account to secondary accounts. The key difference is that a Failover Group additionally supports **promotion** — the secondary can be promoted to become the new primary, enabling disaster recovery. A Replication Group provides read-only copies for data distribution and read scaling but cannot be promoted. Failover Groups also support client redirect for automatic connection rerouting.

### Q2: What is the RPO and RTO achievable with Snowflake replication?

**A:** The RPO equals the replication schedule interval — the minimum is 10 minutes, meaning up to 10 minutes of data could be lost in a disaster. The RTO is typically a few minutes — the time to promote the secondary (a metadata operation) plus the time for client redirect DNS propagation. Combined, you can achieve RPO of 10 minutes and RTO under 5 minutes.

### Q3: Can Snowflake replicate across different cloud providers?

**A:** Yes. Snowflake supports cross-cloud replication — for example, from an AWS account to an Azure account or GCP account. This is a unique capability that enables true multi-cloud disaster recovery. The data is transferred over the network between clouds, so data transfer costs apply.

### Q4: What happens to the secondary account's replicated databases during normal operation?

**A:** Replicated databases on the secondary account are **read-only**. Users can query the data but cannot insert, update, or delete. This makes them suitable for read scaling and reporting. The databases become read-write only when the secondary is promoted to primary via failover.

### Q5: How does client redirect work during failover?

**A:** Client redirect uses an organization-level connection URL that is independent of any specific account or region. Snowflake maintains DNS records mapping this URL to the current primary. When failover promotes a secondary to primary, Snowflake updates the DNS to point to the new primary. Applications using the connection URL automatically route to the new primary after reconnecting. This avoids manual connection string changes.

### Q6: What are the costs associated with replication?

**A:** Replication costs have three components: (1) Compute credits for the serverless replication process, (2) Data transfer costs for moving data between regions or clouds (transfer within the same region is free), and (3) Storage costs on the secondary for the replicated data. To optimize costs, replicate only critical databases, use appropriate scheduling intervals, and avoid replicating development or staging databases.

### Q7: How would you design a DR strategy using Snowflake replication?

**A:**
1. Identify critical databases and account objects needed for recovery
2. Create a Failover Group on the primary including these objects
3. Set up a secondary account in a different region (or different cloud for maximum resilience)
4. Configure a replication schedule aligned with RPO requirements (e.g., 10 minutes)
5. Enable client redirect so applications can automatically switch
6. Monitor replication lag and health using `REPLICATION_USAGE_HISTORY` and refresh progress views
7. Conduct quarterly DR tests: promote secondary, validate, fail back
8. Document the runbook with clear steps for both planned and unplanned failover

### Q8: What is the minimum replication frequency, and what drives the choice of interval?

**A:** The minimum is 10 minutes. The choice depends on your RPO requirement (how much data loss is acceptable), data change volume (more changes = more data to transfer per refresh), cost tolerance (more frequent = higher compute and transfer costs), and the criticality of the data. A financial system might use 10-minute intervals, while a reporting database might use hourly.

---

## Tips

1. **Use Failover Groups over legacy database replication** — they offer scheduling, multi-object replication, failover capability, and client redirect.

2. **Test failover regularly** — a DR plan that has never been tested is not a plan. Perform quarterly failover drills to validate RTO/RTO and ensure your team knows the process.

3. **Replicate only what you need** — every additional database adds replication cost. Exclude development, staging, and non-critical databases from your failover group.

4. **Monitor replication lag continuously** — if replication falls behind, your RPO is effectively worse than configured. Set up alerts for replication failures or excessive lag.

5. **Consider cross-cloud for maximum DR resilience** — replicating to a different cloud provider protects against cloud-wide outages, though it adds transfer costs.

6. **Remember the secondary is read-only** — plan your application architecture accordingly. Read replicas can serve reporting and analytics workloads to offload the primary.

7. **Client redirect requires application cooperation** — applications must use the organization-level connection URL and handle reconnection gracefully. Test this end-to-end.

8. **In interviews, connect replication to business continuity** — speak in terms of RPO, RTO, compliance requirements, and total cost of DR rather than just the technical mechanics.

---
