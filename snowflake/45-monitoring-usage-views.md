# Monitoring & Usage Views in Snowflake

[Back to Snowflake Index](./README.md)

---

## 1. Overview

Snowflake provides built-in metadata databases and schemas that allow you to monitor resource consumption, query performance, storage, logins, and more — without setting up external monitoring infrastructure. The two primary sources are the **SNOWFLAKE database** (shared, account-level metadata) and the **INFORMATION_SCHEMA** (per-database, real-time metadata).

Understanding these views is critical for:
- Cost management and chargeback reporting
- Performance tuning and query optimization
- Security auditing and compliance
- Capacity planning and forecasting

---

## 2. SNOWFLAKE Database — ACCOUNT_USAGE Schema

The `SNOWFLAKE` database is a system-provided, shared database available in every Snowflake account. Its most important schema is **ACCOUNT_USAGE**.

### Key Characteristics

| Property | Detail |
|---|---|
| **Latency** | Views have a **45-minute to 3-hour latency** depending on the view (data is not real-time) |
| **Retention** | Data is retained for **1 year (365 days)** for most views |
| **Scope** | Account-wide — covers all databases, schemas, warehouses |
| **Access** | Requires the `IMPORTED PRIVILEGES` grant on the `SNOWFLAKE` database (granted to `ACCOUNTADMIN` by default) |
| **Dropped Objects** | Includes records for dropped objects |

```sql
-- Grant access to a custom role
USE ROLE ACCOUNTADMIN;
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE DATA_ENGINEER;
```

### Important ACCOUNT_USAGE Views

| View | Description | Latency |
|---|---|---|
| `QUERY_HISTORY` | All queries executed in the account | 45 min |
| `WAREHOUSE_METERING_HISTORY` | Credit consumption per warehouse | 3 hours |
| `STORAGE_USAGE` | Account-level storage (bytes) over time | 3 hours |
| `TABLE_STORAGE_METRICS` | Per-table storage including Time Travel & Fail-safe | 3 hours |
| `LOGIN_HISTORY` | All login attempts (success/failure) | 2 hours |
| `COPY_HISTORY` | COPY INTO load history | 2 hours |
| `PIPE_USAGE_HISTORY` | Snowpipe credit consumption | 3 hours |
| `TASK_HISTORY` | Task execution history | 45 min |
| `ACCESS_HISTORY` | Column-level data access lineage | 3 hours |
| `STAGES` | All stages in the account | 2 hours |
| `COLUMNS` | All columns across all tables | 2 hours |

---

## 3. INFORMATION_SCHEMA (Per-Database, Real-Time)

Every database in Snowflake contains an **INFORMATION_SCHEMA** that provides real-time metadata about objects within that specific database.

### Key Characteristics

| Property | Detail |
|---|---|
| **Latency** | **Real-time** (no delay) |
| **Retention** | Varies: 7 days to 14 days for history views; current-state for object views |
| **Scope** | **Single database** only |
| **Access** | Available to any role with access to the database |
| **Dropped Objects** | Does **NOT** include dropped objects |

### Common INFORMATION_SCHEMA Views & Table Functions

```sql
-- Real-time query history (last 7 days via table function)
SELECT *
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATE_RANGE_START => DATEADD('hours', -24, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 100
));

-- List all tables in the current database
SELECT * FROM MY_DATABASE.INFORMATION_SCHEMA.TABLES;

-- List all columns
SELECT * FROM MY_DATABASE.INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'ORDERS';
```

---

## 4. ACCOUNT_USAGE vs INFORMATION_SCHEMA — Comparison

| Feature | ACCOUNT_USAGE | INFORMATION_SCHEMA |
|---|---|---|
| **Latency** | 45 min — 3 hours | Real-time |
| **Data Retention** | 365 days | 7–14 days (history); current (objects) |
| **Scope** | Entire account | Single database |
| **Dropped Objects** | Yes | No |
| **Access** | IMPORTED PRIVILEGES required | Database-level access |
| **Best For** | Historical analysis, auditing, cost reporting | Real-time troubleshooting, object discovery |

**Rule of thumb:** Use `INFORMATION_SCHEMA` for real-time operational checks. Use `ACCOUNT_USAGE` for historical trend analysis, cost reporting, and auditing.

---

## 5. Key Views — Deep Dive

### 5.1 QUERY_HISTORY

The most commonly referenced view for performance analysis.

```sql
-- Top 20 most expensive queries by execution time (last 30 days)
SELECT
    query_id,
    query_text,
    user_name,
    warehouse_name,
    execution_status,
    total_elapsed_time / 1000 AS elapsed_seconds,
    bytes_scanned,
    rows_produced,
    compilation_time / 1000 AS compile_seconds,
    execution_time / 1000 AS exec_seconds,
    queued_overload_time / 1000 AS queue_seconds,
    partitions_scanned,
    partitions_total,
    bytes_spilled_to_local_storage,
    bytes_spilled_to_remote_storage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
ORDER BY total_elapsed_time DESC
LIMIT 20;

-- Identify queries with high spillage (performance concern)
SELECT
    query_id,
    query_text,
    warehouse_name,
    bytes_spilled_to_local_storage,
    bytes_spilled_to_remote_storage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND (bytes_spilled_to_local_storage > 0 OR bytes_spilled_to_remote_storage > 0)
ORDER BY bytes_spilled_to_remote_storage DESC
LIMIT 50;

-- Queries with poor partition pruning
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
ORDER BY partitions_total DESC;
```

### 5.2 WAREHOUSE_METERING_HISTORY

Tracks credit consumption per warehouse — essential for cost management.

```sql
-- Daily credit consumption per warehouse (last 30 days)
SELECT
    warehouse_name,
    DATE_TRUNC('day', start_time) AS usage_date,
    SUM(credits_used) AS total_credits,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_used_cloud_services) AS cloud_services_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, usage_date
ORDER BY usage_date DESC, total_credits DESC;

-- Identify the most expensive warehouses
SELECT
    warehouse_name,
    SUM(credits_used) AS total_credits_30d,
    ROUND(SUM(credits_used) * 3.00, 2) AS estimated_cost_usd  -- adjust rate
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits_30d DESC;
```

### 5.3 STORAGE_USAGE

Account-level storage consumption over time.

```sql
-- Monthly storage trend
SELECT
    DATE_TRUNC('month', usage_date) AS month,
    AVG(storage_bytes) / POWER(1024, 4) AS avg_storage_tb,
    AVG(stage_bytes) / POWER(1024, 4) AS avg_stage_tb,
    AVG(failsafe_bytes) / POWER(1024, 4) AS avg_failsafe_tb
FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE
WHERE usage_date >= DATEADD('month', -12, CURRENT_DATE())
GROUP BY month
ORDER BY month;
```

### 5.4 TABLE_STORAGE_METRICS

Per-table storage breakdown including active bytes, Time Travel bytes, and Fail-safe bytes.

```sql
-- Top 20 largest tables by total storage
SELECT
    table_catalog AS database_name,
    table_schema,
    table_name,
    active_bytes / POWER(1024, 3) AS active_gb,
    time_travel_bytes / POWER(1024, 3) AS time_travel_gb,
    failsafe_bytes / POWER(1024, 3) AS failsafe_gb,
    (active_bytes + time_travel_bytes + failsafe_bytes) / POWER(1024, 3) AS total_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE active_bytes > 0
ORDER BY total_gb DESC
LIMIT 20;

-- Tables with high Time Travel / Fail-safe overhead
SELECT
    table_catalog, table_schema, table_name,
    ROUND(time_travel_bytes / NULLIF(active_bytes, 0) * 100, 1) AS tt_pct_of_active,
    ROUND(failsafe_bytes / NULLIF(active_bytes, 0) * 100, 1) AS fs_pct_of_active
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE active_bytes > 1073741824  -- > 1 GB
ORDER BY tt_pct_of_active DESC
LIMIT 20;
```

### 5.5 LOGIN_HISTORY

Security auditing — all authentication attempts.

```sql
-- Failed login attempts in the last 7 days
SELECT
    event_timestamp,
    user_name,
    client_ip,
    reported_client_type,
    error_code,
    error_message,
    is_success
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE event_timestamp >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND is_success = 'NO'
ORDER BY event_timestamp DESC;

-- Login frequency by user (detect unusual patterns)
SELECT
    user_name,
    COUNT(*) AS login_count,
    COUNT_IF(is_success = 'NO') AS failed_count,
    ROUND(failed_count / NULLIF(login_count, 0) * 100, 1) AS failure_rate_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE event_timestamp >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY user_name
ORDER BY failed_count DESC;
```

### 5.6 COPY_HISTORY

Tracks data loading operations via COPY INTO.

```sql
-- Recent load failures
SELECT
    table_name,
    file_name,
    stage_location,
    status,
    row_count,
    row_parsed,
    first_error_message,
    last_load_time
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE last_load_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND status = 'LOAD_FAILED'
ORDER BY last_load_time DESC;
```

### 5.7 PIPE_USAGE_HISTORY

Snowpipe credit consumption monitoring.

```sql
-- Snowpipe daily cost
SELECT
    pipe_name,
    DATE_TRUNC('day', start_time) AS usage_date,
    SUM(credits_used) AS pipe_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY pipe_name, usage_date
ORDER BY usage_date DESC, pipe_credits DESC;
```

### 5.8 TASK_HISTORY

Monitor task executions and failures.

```sql
-- Failed tasks in the last 7 days
SELECT
    name AS task_name,
    database_name,
    schema_name,
    state,
    error_code,
    error_message,
    scheduled_time,
    completed_time
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE scheduled_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND state = 'FAILED'
ORDER BY scheduled_time DESC;
```

---

## 6. ORGANIZATION_USAGE Schema

For multi-account organizations, the `SNOWFLAKE.ORGANIZATION_USAGE` schema provides cross-account visibility.

```sql
-- Credit usage across all accounts in the organization
SELECT
    account_name,
    DATE_TRUNC('month', usage_date) AS month,
    SUM(credits_used) AS total_credits
FROM SNOWFLAKE.ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY
WHERE usage_date >= DATEADD('month', -6, CURRENT_DATE())
GROUP BY account_name, month
ORDER BY month DESC, total_credits DESC;

-- Contract-level remaining balance
SELECT *
FROM SNOWFLAKE.ORGANIZATION_USAGE.REMAINING_BALANCE_DAILY
ORDER BY date DESC
LIMIT 30;
```

> **Note:** Only the **ORGADMIN** role (or a role with IMPORTED PRIVILEGES on the SNOWFLAKE database in the organization account) can access `ORGANIZATION_USAGE`.

---

## 7. Building Monitoring Dashboards

### Strategy for a Cost & Performance Dashboard

1. **Create a dedicated monitoring database and warehouse**
2. **Schedule tasks to materialize key metrics** (avoids repeated expensive queries against ACCOUNT_USAGE)
3. **Expose tables to a BI tool** (Snowsight dashboards, Grafana, Tableau, etc.)

```sql
-- Step 1: Create infrastructure
CREATE DATABASE IF NOT EXISTS MONITORING;
CREATE SCHEMA IF NOT EXISTS MONITORING.METRICS;
CREATE WAREHOUSE IF NOT EXISTS WH_MONITORING
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE;

-- Step 2: Materialized daily credit summary
CREATE OR REPLACE TABLE MONITORING.METRICS.DAILY_CREDITS AS
SELECT
    warehouse_name,
    DATE_TRUNC('day', start_time) AS usage_date,
    SUM(credits_used) AS total_credits,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_used_cloud_services) AS cloud_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
GROUP BY warehouse_name, usage_date;

-- Step 3: Create a task to refresh daily
CREATE OR REPLACE TASK MONITORING.METRICS.REFRESH_DAILY_CREDITS
    WAREHOUSE = WH_MONITORING
    SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
AS
INSERT INTO MONITORING.METRICS.DAILY_CREDITS
SELECT
    warehouse_name,
    DATE_TRUNC('day', start_time) AS usage_date,
    SUM(credits_used),
    SUM(credits_used_compute),
    SUM(credits_used_cloud_services)
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= (SELECT COALESCE(MAX(usage_date), '2020-01-01') FROM MONITORING.METRICS.DAILY_CREDITS)
GROUP BY warehouse_name, usage_date;

ALTER TASK MONITORING.METRICS.REFRESH_DAILY_CREDITS RESUME;
```

### Snowsight Dashboards

Snowflake's built-in UI (Snowsight) supports native dashboards:
- Create SQL worksheets with monitoring queries
- Convert them to dashboard tiles
- Set auto-refresh intervals
- Share with stakeholders via link or role-based access

### Resource Monitors (Proactive Alerting)

```sql
-- Create a resource monitor with alerts and hard limits
CREATE OR REPLACE RESOURCE MONITOR MONTHLY_BUDGET
    WITH CREDIT_QUOTA = 5000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND
        ON 110 PERCENT DO SUSPEND_IMMEDIATE;

-- Assign to a warehouse
ALTER WAREHOUSE ANALYTICS_WH SET RESOURCE_MONITOR = MONTHLY_BUDGET;

-- Assign at account level (ACCOUNTADMIN only)
ALTER ACCOUNT SET RESOURCE_MONITOR = MONTHLY_BUDGET;
```

---

## 8. Common Interview Questions & Answers

### Q1: What is the difference between ACCOUNT_USAGE and INFORMATION_SCHEMA?

**A:** ACCOUNT_USAGE provides account-wide historical data with 45-min to 3-hour latency and 365-day retention. INFORMATION_SCHEMA provides real-time, per-database metadata with 7–14 day retention for history table functions. ACCOUNT_USAGE includes dropped objects; INFORMATION_SCHEMA does not. ACCOUNT_USAGE requires IMPORTED PRIVILEGES on the SNOWFLAKE database; INFORMATION_SCHEMA requires only database-level access.

### Q2: How would you identify the most expensive queries in your Snowflake account?

**A:** Query `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` and sort by `total_elapsed_time`, `bytes_scanned`, or credit attribution. Look at `bytes_spilled_to_remote_storage` for memory pressure, `queued_overload_time` for warehouse contention, and partition pruning ratios (`partitions_scanned` vs `partitions_total`). Cross-reference with `WAREHOUSE_METERING_HISTORY` for credit impact.

### Q3: How do you monitor Snowflake costs and set up alerts?

**A:** Use `WAREHOUSE_METERING_HISTORY` for credit consumption trends, `STORAGE_USAGE` for storage costs, and `PIPE_USAGE_HISTORY` for Snowpipe costs. Set up **Resource Monitors** with NOTIFY and SUSPEND triggers at percentage thresholds. For organization-level monitoring, use `ORGANIZATION_USAGE.USAGE_IN_CURRENCY_DAILY`. Build dashboards using materialized metric tables refreshed by tasks.

### Q4: What is the latency of ACCOUNT_USAGE views, and how does that affect monitoring?

**A:** Latency ranges from 45 minutes (e.g., QUERY_HISTORY) to 3 hours (e.g., WAREHOUSE_METERING_HISTORY, STORAGE_USAGE). This means ACCOUNT_USAGE is not suitable for real-time alerting. For real-time needs, use INFORMATION_SCHEMA table functions (e.g., `QUERY_HISTORY()`, `WAREHOUSE_LOAD_HISTORY()`). For proactive cost control, use Resource Monitors which operate in real-time.

### Q5: How would you detect unauthorized access attempts in Snowflake?

**A:** Query `SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY` filtering on `is_success = 'NO'`. Analyze patterns: multiple failures from the same `client_ip`, unusual `reported_client_type`, logins outside business hours, or login attempts for disabled users. Combine with `ACCESS_HISTORY` for data access auditing and `SESSIONS` for session analysis.

### Q6: What is the ORGANIZATION_USAGE schema and who can access it?

**A:** It provides cross-account visibility for Snowflake organizations — credit consumption, storage, and contract balance across all linked accounts. Only the **ORGADMIN** role can access it. Key views include `USAGE_IN_CURRENCY_DAILY`, `REMAINING_BALANCE_DAILY`, and `WAREHOUSE_METERING_HISTORY`.

---

## 9. Tips

- **Materialize metrics** — Do not query ACCOUNT_USAGE repeatedly in dashboards; create summary tables refreshed by tasks to reduce cost and improve dashboard performance.
- **Combine views** — Join `QUERY_HISTORY` with `WAREHOUSE_METERING_HISTORY` for per-query cost attribution.
- **Monitor spillage** — `bytes_spilled_to_remote_storage > 0` is a strong signal to upsize the warehouse for that workload.
- **Automate alerts** — Use tasks + email notifications or integrate with external alerting (PagerDuty, Slack) via external functions or Snowflake alerts (`CREATE ALERT`).
- **Check partition pruning** — A high `partitions_scanned / partitions_total` ratio suggests missing or suboptimal clustering keys.
- **Retain beyond 365 days** — If you need longer retention, materialize ACCOUNT_USAGE data into your own tables before it ages out.
- **Use Resource Monitors** — They are the only real-time cost control mechanism and should be configured for every production warehouse.

---
