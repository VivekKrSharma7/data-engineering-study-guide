# Failover & Business Continuity

[Back to Snowflake Index](./README.md)

---

## 1. Overview

Business continuity in Snowflake refers to the ability to maintain data availability and operational functionality during planned or unplanned outages. Snowflake provides native features — **failover groups**, **client redirect**, and **replication** — that together enable robust disaster recovery (DR) across regions and even across cloud providers.

A senior Data Engineer must understand how to architect solutions that meet strict **RTO** (Recovery Time Objective) and **RPO** (Recovery Point Objective) targets while balancing cost and complexity.

---

## 2. Key Concepts

### 2.1 RTO and RPO

| Term | Definition | Snowflake Relevance |
|------|-----------|---------------------|
| **RPO** | Maximum acceptable data loss measured in time | Determined by replication frequency and lag |
| **RTO** | Maximum acceptable downtime before services are restored | Determined by failover mechanism (manual vs. automatic) and client redirect |

- **RPO close to zero**: Requires high-frequency replication (e.g., every few minutes).
- **RTO close to zero**: Requires client redirect so applications automatically connect to the secondary account.

### 2.2 Snowflake Editions and SLA

| Edition | Uptime SLA | DR Features Available |
|---------|-----------|----------------------|
| Standard | 99.9% | Time Travel (1 day), Fail-safe (7 days) |
| Enterprise | 99.9% | Multi-cluster warehouses, up to 90 days Time Travel |
| Business Critical | 99.95% | Database replication & failover, client redirect, Tri-Secret Secure, private connectivity |
| Virtual Private Snowflake (VPS) | 99.95% | All Business Critical features in a dedicated environment |

> **Key point**: Database replication and failover features require **Business Critical** edition or higher.

### 2.3 Failover Groups

A **failover group** is a collection of objects in a source account that are replicated as a unit to one or more target accounts, and that can be **failed over** together.

Objects that can be included in a failover group:

- Databases
- Shares (inbound and outbound)
- Roles
- Users
- Warehouses
- Resource monitors
- Integrations (security, storage, notification)
- Network policies
- Parameters

```sql
-- Create a failover group on the SOURCE account
CREATE FAILOVER GROUP my_failover_group
  OBJECT_TYPES = DATABASES, ROLES, USERS, WAREHOUSES, INTEGRATIONS
  ALLOWED_DATABASES = production_db, analytics_db
  ALLOWED_INTEGRATIONS = my_s3_integration
  ALLOWED_ACCOUNTS = myorg.target_account
  REPLICATION_SCHEDULE = '10 MINUTE';
```

```sql
-- On the TARGET account, create a secondary failover group
CREATE FAILOVER GROUP my_failover_group
  AS REPLICA OF myorg.source_account.my_failover_group;
```

```sql
-- Manually refresh the secondary (if not using a schedule)
ALTER FAILOVER GROUP my_failover_group REFRESH;
```

### 2.4 Client Redirect (Connection URL Failover)

Client redirect enables applications to automatically reconnect to a secondary Snowflake account when the primary becomes unavailable. It uses a **connection URL** that abstracts the underlying account.

```sql
-- Create a connection object on the source account
CREATE CONNECTION my_connection;

-- Enable failover of the connection to a target account
ALTER CONNECTION my_connection
  ENABLE FAILOVER TO ACCOUNTS myorg.target_account;
```

```sql
-- On the TARGET account, create a secondary connection
CREATE CONNECTION my_connection
  AS REPLICA OF myorg.source_account.my_connection;
```

```sql
-- Promote the secondary connection to primary (during failover)
ALTER CONNECTION my_connection PRIMARY;
```

Applications use the **connection URL** format:
```
https://<org_name>-<connection_name>.snowflakecomputing.com
```

This URL resolves to whichever account currently holds the **primary** connection, enabling transparent failover without application changes.

### 2.5 Cross-Region Failover

Cross-region failover protects against an entire cloud region becoming unavailable.

**Architecture pattern:**

```
Source Account (AWS us-east-1)
        |
        | Replication (every 10 min)
        v
Target Account (AWS us-west-2)
```

**Steps to configure:**

1. Enable replication for the source account (organization-level).
2. Create a failover group with the desired objects.
3. Set a replication schedule.
4. Create a client redirect connection.
5. Test failover periodically.

```sql
-- Check replication status
SELECT *
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('my_failover_group'))
ORDER BY PHASE_START_TIME DESC;
```

### 2.6 Cross-Cloud Failover

Snowflake supports replication and failover across different cloud providers (e.g., AWS to Azure, or AWS to GCP). This provides the highest level of resilience.

```
Source Account (AWS us-east-1)
        |
        | Replication
        +---> Target Account (Azure East US 2)
        |
        +---> Target Account (GCP us-central1)
```

> **Cost consideration**: Cross-cloud and cross-region data transfer incurs egress charges. Factor this into your DR budget.

```sql
-- Failover group targeting accounts on different clouds
CREATE FAILOVER GROUP multi_cloud_dr
  OBJECT_TYPES = DATABASES, ROLES, USERS
  ALLOWED_DATABASES = production_db
  ALLOWED_ACCOUNTS = myorg.azure_target, myorg.gcp_target
  REPLICATION_SCHEDULE = '30 MINUTE';
```

### 2.7 Monitoring Replication Lag

Replication lag is the time difference between the latest data on the source and what has been replicated to the target. Monitoring lag is critical to understanding your actual RPO.

```sql
-- Check replication lag for databases
SELECT database_name,
       primary_snapshot_timestamp,
       secondary_snapshot_timestamp,
       DATEDIFF('minute',
                secondary_snapshot_timestamp,
                primary_snapshot_timestamp) AS lag_minutes
FROM TABLE(INFORMATION_SCHEMA.DATABASE_REPLICATION_USAGE_HISTORY(
  DATE_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
));
```

```sql
-- Monitor failover group refresh history
SELECT phase_name,
       start_time,
       end_time,
       DATEDIFF('second', start_time, end_time) AS duration_seconds,
       total_bytes,
       object_count
FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('my_failover_group'))
ORDER BY start_time DESC
LIMIT 20;
```

**Alerting pattern using tasks and email notifications:**

```sql
CREATE OR REPLACE TASK monitor_replication_lag
  WAREHOUSE = monitoring_wh
  SCHEDULE = 'USING CRON 0/15 * * * * UTC'  -- Every 15 minutes
AS
CALL SYSTEM$SEND_EMAIL(
  'my_notification_integration',
  'oncall-team@company.com',
  'Replication Lag Alert',
  'Replication lag exceeds threshold. Please investigate.'
)
WHERE EXISTS (
  SELECT 1
  FROM TABLE(INFORMATION_SCHEMA.REPLICATION_GROUP_REFRESH_HISTORY('my_failover_group'))
  WHERE DATEDIFF('minute', start_time, CURRENT_TIMESTAMP()) > 30
    AND phase_name = 'COMPLETED'
  LIMIT 1
);
```

---

## 3. Replication + Failover Combined Strategy

A complete DR strategy combines multiple features:

| Layer | Feature | Purpose |
|-------|---------|---------|
| Data | Database Replication | Keeps data synchronized across accounts |
| Access | Roles/Users Replication (Failover Groups) | Ensures access controls are consistent |
| Connectivity | Client Redirect | Enables transparent application failover |
| Monitoring | Replication lag monitoring + alerting | Ensures RPO is met continuously |
| Testing | Periodic failover drills | Validates RTO and runbooks |

### Recommended Architecture

```
Primary Account (Region A)
  ├── Failover Group (databases, roles, users, warehouses)
  ├── Connection Object (primary)
  └── Replication Schedule: 10 minutes
        │
        ▼
Secondary Account (Region B)
  ├── Failover Group (replica)
  ├── Connection Object (secondary)
  └── Ready for promotion
```

### Failover Execution (Manual)

```sql
-- Step 1: On the TARGET account, promote the failover group
ALTER FAILOVER GROUP my_failover_group PRIMARY;

-- Step 2: Promote the connection to redirect clients
ALTER CONNECTION my_connection PRIMARY;

-- Step 3: Verify
SHOW FAILOVER GROUPS;
SHOW CONNECTIONS;
```

### Failback (Returning to Original Primary)

```sql
-- After the original primary is healthy again:
-- Step 1: On the ORIGINAL account, refresh to catch up
ALTER FAILOVER GROUP my_failover_group REFRESH;

-- Step 2: Promote original account's failover group back to primary
ALTER FAILOVER GROUP my_failover_group PRIMARY;

-- Step 3: Redirect connections back
ALTER CONNECTION my_connection PRIMARY;
```

---

## 4. Failover Testing

Regular failover testing is essential. A mature organization should test DR at least quarterly.

**Testing checklist:**

1. Verify replication is current (check lag).
2. Promote the secondary failover group.
3. Promote the secondary connection.
4. Validate application connectivity via the connection URL.
5. Run smoke tests (key queries, dashboard loads).
6. Measure actual RTO (time from initiation to full application availability).
7. Fail back to the original primary.
8. Document results and update runbooks.

```sql
-- Useful validation queries after failover
-- Check that databases are accessible
SHOW DATABASES;

-- Verify row counts on key tables
SELECT COUNT(*) FROM production_db.public.orders;

-- Check warehouse availability
SHOW WAREHOUSES;

-- Validate roles
SHOW ROLES;
```

---

## 5. Disaster Recovery Patterns

### Pattern 1: Active-Passive (Most Common)

- Primary account handles all workloads.
- Secondary account is a replica, only activated during failover.
- Lower cost (secondary warehouses are suspended).
- RTO: Minutes to hours depending on automation.

### Pattern 2: Active-Active Read

- Primary account handles writes.
- Secondary account serves read-only analytical workloads using replicated data.
- Reduces load on primary and provides DR readiness.
- Slightly higher cost but better resource utilization.

### Pattern 3: Multi-Region Active-Active (Advanced)

- Multiple accounts across regions each handle localized workloads.
- Data sharing and replication keep data synchronized.
- Most complex, highest availability.
- Suitable for global organizations with regulatory requirements.

---

## 6. Common Interview Questions & Answers

### Q1: What is the difference between database replication and a failover group?

**A:** Database replication copies individual databases to a target account. A **failover group** bundles multiple object types (databases, roles, users, warehouses, integrations) together so they can be replicated and failed over as a **single unit**. Failover groups provide a more holistic DR solution because access controls and compute resources move together with the data.

---

### Q2: What Snowflake edition is required for failover and replication?

**A:** **Business Critical** edition or higher. Standard and Enterprise editions do not support database replication or failover groups.

---

### Q3: How does client redirect work, and why is it important?

**A:** Client redirect uses a **connection object** that provides an abstracted URL. Applications connect using `<org>-<connection_name>.snowflakecomputing.com`. When failover occurs, the connection's primary designation is moved to the target account, and the URL automatically resolves to the new primary. This means **no application code or configuration changes** are needed during failover.

---

### Q4: How would you minimize RPO in a Snowflake DR setup?

**A:**
- Set the replication schedule to the **minimum interval** (e.g., every 1 minute if supported, typically 10 minutes is practical).
- Monitor replication lag continuously and alert if it exceeds the RPO threshold.
- Ensure replication warehouses have sufficient capacity to process changes within the schedule window.
- Consider the volume of data changes — high-change-rate tables may need dedicated optimization.

---

### Q5: Walk me through a failover scenario from start to finish.

**A:**
1. **Detection**: Monitoring detects that the primary account/region is unavailable.
2. **Decision**: The on-call team confirms failover is necessary (or automation triggers it).
3. **Promotion**: `ALTER FAILOVER GROUP ... PRIMARY` is executed on the secondary account.
4. **Redirect**: `ALTER CONNECTION ... PRIMARY` redirects application traffic.
5. **Validation**: Smoke tests confirm data availability and application functionality.
6. **Communication**: Stakeholders are notified of the failover and any data lag.
7. **Failback** (later): Once the original region recovers, data is synced back and the original primary is restored.

---

### Q6: How do you monitor replication lag, and what would you do if it exceeds your RPO?

**A:** Use `REPLICATION_GROUP_REFRESH_HISTORY` and `DATABASE_REPLICATION_USAGE_HISTORY` to track lag. If lag exceeds RPO:
- Check if the replication warehouse is undersized and scale it up.
- Investigate whether large data loads or schema changes are causing replication delays.
- Consider increasing replication frequency.
- Review network throughput (especially for cross-cloud replication).

---

### Q7: Can Snowflake replicate across different cloud providers?

**A:** Yes. Snowflake supports cross-cloud replication (e.g., AWS to Azure, AWS to GCP). This is configured the same way as cross-region replication using failover groups. The main additional consideration is **data transfer cost** (cloud egress fees).

---

## 7. Tips

- **Start with Business Critical edition** if DR is a requirement — replication and failover are not available on lower editions.
- **Automate failover testing** — build a runbook and schedule quarterly DR drills. Measure actual RTO each time.
- **Monitor replication lag proactively** — do not wait for an incident to discover your replication is behind.
- **Use client redirect from day one** — even before you need failover, using connection URLs means you are always ready.
- **Budget for cross-region/cross-cloud transfer costs** — replication moves data across the network and incurs egress charges.
- **Replicate more than just databases** — use failover groups to include roles, users, and integrations so the secondary account is fully functional after failover.
- **Document your failover and failback procedures** — during an actual incident, clear runbooks reduce RTO significantly.
- **Understand that failover is manual** — Snowflake does not automatically fail over. You must execute the promotion commands (or automate them externally).
- **Consider data pipeline impact** — after failover, ensure ETL/ELT pipelines point to the new primary account (Snowpipe, tasks, streams may need reconfiguration).

---
