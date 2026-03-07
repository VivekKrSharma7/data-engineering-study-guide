# Access History & Auditing

[Back to Snowflake Index](./README.md)

---

## 1. Overview

Snowflake provides comprehensive auditing and access tracking capabilities through system views in the `SNOWFLAKE.ACCOUNT_USAGE` and `SNOWFLAKE.ORGANIZATION_USAGE` schemas. These views record who accessed what data, when, and how -- enabling compliance reporting, security monitoring, and data governance. For senior Data Engineers, understanding these views, their retention periods, and how to build audit solutions is essential.

---

## 2. Key Auditing Views in ACCOUNT_USAGE

The `SNOWFLAKE.ACCOUNT_USAGE` schema is a shared database that provides detailed metadata about account activity. It has a latency of up to **45 minutes** for most views (data is not real-time).

| View | Purpose | Retention |
|---|---|---|
| `ACCESS_HISTORY` | Tracks read/write operations at column level | 365 days |
| `LOGIN_HISTORY` | Records all login attempts (success and failure) | 365 days |
| `QUERY_HISTORY` | Logs all queries executed in the account | 365 days |
| `SESSIONS` | Active and historical session information | 365 days |
| `POLICY_REFERENCES` | Shows where masking/row access policies are applied | Current state |
| `WAREHOUSE_METERING_HISTORY` | Credit consumption by warehouse | 365 days |
| `COPY_HISTORY` | Data loading operations | 365 days |
| `TASK_HISTORY` | Task execution records | 365 days |

> **Access requirement:** Only users with the `ACCOUNTADMIN` role (or roles granted `IMPORTED PRIVILEGES` on the `SNOWFLAKE` database) can query these views.

```sql
-- Grant access to a custom audit role
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE audit_role;
```

---

## 3. ACCESS_HISTORY View

The `ACCESS_HISTORY` view is the most powerful auditing tool in Snowflake. It provides **column-level tracking** of all data read and write operations.

### Key columns:

| Column | Description |
|---|---|
| `QUERY_ID` | Unique identifier of the query |
| `QUERY_START_TIME` | When the query started |
| `USER_NAME` | Who ran the query |
| `DIRECT_OBJECTS_ACCESSED` | Tables/views directly referenced in the query |
| `BASE_OBJECTS_ACCESSED` | Underlying base tables (resolves views) |
| `OBJECTS_MODIFIED` | Tables written to (INSERT, UPDATE, DELETE, MERGE) |
| `OBJECT_MODIFIED_BY_DDL` | Objects altered by DDL statements |
| `POLICIES_REFERENCED` | Masking/row access policies evaluated during query |

### Column-Level Read Tracking

```sql
-- Find all users who accessed the 'salary' column in the last 30 days
SELECT
    query_start_time,
    user_name,
    query_id,
    obj.value:objectName::STRING AS table_name,
    col.value:columnName::STRING AS column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
    LATERAL FLATTEN(input => base_objects_accessed) obj,
    LATERAL FLATTEN(input => obj.value:columns) col
WHERE col.value:columnName::STRING = 'SALARY'
    AND query_start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY query_start_time DESC;
```

### Write Tracking

```sql
-- Track all write operations (INSERT, UPDATE, DELETE, MERGE) to a specific table
SELECT
    query_start_time,
    user_name,
    query_id,
    modified.value:objectName::STRING AS modified_table,
    modified.value:objectDomain::STRING AS object_type,
    col.value:columnName::STRING AS modified_column
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
    LATERAL FLATTEN(input => objects_modified) modified,
    LATERAL FLATTEN(input => modified.value:columns, OUTER => TRUE) col
WHERE modified.value:objectName::STRING = 'HR.PUBLIC.EMPLOYEES'
    AND query_start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY query_start_time DESC;
```

### Data Lineage Through Access History

One of the most valuable features: `ACCESS_HISTORY` captures both source (read) and target (write) in the same record, enabling **data lineage** tracking.

```sql
-- Build lineage: what source tables feed into a target table
SELECT DISTINCT
    src.value:objectName::STRING AS source_table,
    tgt.value:objectName::STRING AS target_table,
    user_name,
    query_start_time
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
    LATERAL FLATTEN(input => base_objects_accessed) src,
    LATERAL FLATTEN(input => objects_modified) tgt
WHERE tgt.value:objectName::STRING = 'ANALYTICS.PUBLIC.FACT_SALES'
    AND query_start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY query_start_time DESC;
```

```sql
-- Full lineage graph: all source-to-target mappings in the account
SELECT
    src.value:objectName::STRING AS source_object,
    src.value:objectDomain::STRING AS source_type,
    tgt.value:objectName::STRING AS target_object,
    tgt.value:objectDomain::STRING AS target_type,
    COUNT(DISTINCT query_id) AS query_count,
    MIN(query_start_time) AS first_seen,
    MAX(query_start_time) AS last_seen
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
    LATERAL FLATTEN(input => base_objects_accessed) src,
    LATERAL FLATTEN(input => objects_modified) tgt
WHERE query_start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3, 4
ORDER BY query_count DESC;
```

---

## 4. LOGIN_HISTORY

Records every authentication attempt to the Snowflake account.

```sql
-- Failed login attempts in the last 24 hours (potential brute force detection)
SELECT
    event_timestamp,
    user_name,
    client_ip,
    reported_client_type,
    error_code,
    error_message
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE is_success = 'NO'
    AND event_timestamp >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY event_timestamp DESC;

-- Login frequency by user (spot anomalies)
SELECT
    user_name,
    COUNT(*) AS login_count,
    COUNT(DISTINCT client_ip) AS unique_ips,
    COUNT(DISTINCT reported_client_type) AS client_types
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE is_success = 'YES'
    AND event_timestamp >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY user_name
ORDER BY login_count DESC;
```

### Real-Time Login History

For real-time monitoring (no latency), use the `INFORMATION_SCHEMA` version:

```sql
-- Real-time login history (last 7 days only)
SELECT *
FROM TABLE(INFORMATION_SCHEMA.LOGIN_HISTORY(
    TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())
))
ORDER BY EVENT_TIMESTAMP DESC;
```

---

## 5. QUERY_HISTORY

Logs every query executed in the account with execution details.

```sql
-- Most expensive queries in the last 7 days
SELECT
    query_id,
    user_name,
    role_name,
    warehouse_name,
    query_text,
    total_elapsed_time / 1000 AS elapsed_seconds,
    bytes_scanned,
    rows_produced,
    credits_used_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    AND execution_status = 'SUCCESS'
ORDER BY total_elapsed_time DESC
LIMIT 20;

-- Queries by a specific user on sensitive tables
SELECT
    query_id,
    start_time,
    query_text,
    execution_status,
    total_elapsed_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE user_name = 'JOHN_DOE'
    AND UPPER(query_text) LIKE '%CUSTOMER_PII%'
    AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

---

## 6. SESSIONS View

Tracks session-level details including authentication method and client information.

```sql
-- Active sessions analysis
SELECT
    session_id,
    user_name,
    created_on,
    authentication_method,
    client_application_id,
    client_environment
FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
WHERE created_on >= DATEADD('day', -1, CURRENT_TIMESTAMP())
ORDER BY created_on DESC;

-- Sessions by authentication method (check for weak auth)
SELECT
    authentication_method,
    COUNT(*) AS session_count,
    COUNT(DISTINCT user_name) AS unique_users
FROM SNOWFLAKE.ACCOUNT_USAGE.SESSIONS
WHERE created_on >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY authentication_method
ORDER BY session_count DESC;
```

---

## 7. POLICY_REFERENCES

Shows where masking policies and row access policies are applied across the account.

```sql
-- All active masking policy assignments
SELECT
    policy_name,
    policy_kind,
    ref_database_name,
    ref_schema_name,
    ref_entity_name AS table_name,
    ref_column_name AS column_name,
    policy_status
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE policy_kind = 'MASKING_POLICY'
ORDER BY ref_entity_name, ref_column_name;

-- Tables with row access policies
SELECT
    policy_name,
    ref_database_name || '.' || ref_schema_name || '.' || ref_entity_name AS full_table_name,
    policy_status
FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE policy_kind = 'ROW_ACCESS_POLICY';

-- Find columns that are NOT protected by masking policies (gap analysis)
SELECT
    t.table_catalog, t.table_schema, t.table_name, c.column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLES t
JOIN SNOWFLAKE.ACCOUNT_USAGE.COLUMNS c
    ON t.table_catalog = c.table_catalog
    AND t.table_schema = c.table_schema
    AND t.table_name = c.table_name
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES pr
    ON pr.ref_database_name = c.table_catalog
    AND pr.ref_schema_name = c.table_schema
    AND pr.ref_entity_name = c.table_name
    AND pr.ref_column_name = c.column_name
    AND pr.policy_kind = 'MASKING_POLICY'
WHERE c.column_name IN ('SSN', 'EMAIL', 'PHONE', 'CREDIT_CARD', 'SALARY')
    AND t.deleted IS NULL
    AND pr.policy_name IS NULL;
```

---

## 8. Monitoring Privileged Access

Track usage by privileged roles (ACCOUNTADMIN, SECURITYADMIN, SYSADMIN).

```sql
-- All queries run by ACCOUNTADMIN in the last 30 days
SELECT
    q.query_id,
    q.user_name,
    q.role_name,
    q.start_time,
    q.query_type,
    q.query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
WHERE q.role_name = 'ACCOUNTADMIN'
    AND q.start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY q.start_time DESC;

-- Users who used ACCOUNTADMIN role (and how often)
SELECT
    user_name,
    COUNT(*) AS accountadmin_queries,
    MIN(start_time) AS first_use,
    MAX(start_time) AS last_use
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE role_name = 'ACCOUNTADMIN'
    AND start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY user_name
ORDER BY accountadmin_queries DESC;

-- GRANT statements (privilege changes)
SELECT
    query_id,
    user_name,
    role_name,
    start_time,
    query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_type = 'GRANT'
    AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

---

## 9. Compliance Reporting

### GDPR: Data Subject Access Report

```sql
-- All access to a specific customer's data
SELECT
    ah.query_start_time,
    ah.user_name,
    ah.query_id,
    obj.value:objectName::STRING AS accessed_table,
    qh.query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
    LATERAL FLATTEN(input => ah.base_objects_accessed) obj
JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
    ON ah.query_id = qh.query_id
WHERE obj.value:objectName::STRING LIKE '%CUSTOMER%'
    AND ah.query_start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
ORDER BY ah.query_start_time DESC;
```

### SOC 2: User Activity Summary

```sql
-- Monthly user activity report
SELECT
    DATE_TRUNC('month', start_time) AS month,
    user_name,
    role_name,
    COUNT(*) AS total_queries,
    SUM(CASE WHEN query_type IN ('INSERT', 'UPDATE', 'DELETE', 'MERGE') THEN 1 ELSE 0 END) AS write_queries,
    SUM(CASE WHEN query_type = 'SELECT' THEN 1 ELSE 0 END) AS read_queries,
    SUM(bytes_scanned) AS total_bytes_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('month', -6, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3
ORDER BY 1 DESC, total_queries DESC;
```

---

## 10. Building Audit Dashboards

### Comprehensive Audit Summary View

```sql
-- Create a materialized audit summary (refresh periodically via task)
CREATE OR REPLACE TABLE audit_db.public.daily_audit_summary AS
SELECT
    DATE(query_start_time) AS audit_date,
    user_name,
    COUNT(DISTINCT query_id) AS total_operations,

    -- Read operations
    COUNT(DISTINCT CASE
        WHEN ARRAY_SIZE(base_objects_accessed) > 0
        AND ARRAY_SIZE(objects_modified) = 0
        THEN query_id END) AS read_operations,

    -- Write operations
    COUNT(DISTINCT CASE
        WHEN ARRAY_SIZE(objects_modified) > 0
        THEN query_id END) AS write_operations,

    -- Unique tables read
    COUNT(DISTINCT src.value:objectName::STRING) AS unique_tables_accessed,

    -- Sensitive table access
    COUNT(DISTINCT CASE
        WHEN src.value:objectName::STRING LIKE '%PII%'
          OR src.value:objectName::STRING LIKE '%SENSITIVE%'
        THEN query_id END) AS sensitive_table_accesses

FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
    LATERAL FLATTEN(input => base_objects_accessed, OUTER => TRUE) src
WHERE query_start_time >= DATEADD('day', -90, CURRENT_TIMESTAMP())
GROUP BY 1, 2;

-- Automate with a task
CREATE OR REPLACE TASK refresh_audit_summary
  WAREHOUSE = audit_wh
  SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
AS
  INSERT INTO audit_db.public.daily_audit_summary
  SELECT
    DATE(query_start_time) AS audit_date,
    user_name,
    COUNT(DISTINCT query_id) AS total_operations,
    COUNT(DISTINCT CASE
        WHEN ARRAY_SIZE(base_objects_accessed) > 0
        AND ARRAY_SIZE(objects_modified) = 0
        THEN query_id END) AS read_operations,
    COUNT(DISTINCT CASE
        WHEN ARRAY_SIZE(objects_modified) > 0
        THEN query_id END) AS write_operations,
    COUNT(DISTINCT src.value:objectName::STRING) AS unique_tables_accessed,
    COUNT(DISTINCT CASE
        WHEN src.value:objectName::STRING LIKE '%PII%'
          OR src.value:objectName::STRING LIKE '%SENSITIVE%'
        THEN query_id END) AS sensitive_table_accesses
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY,
      LATERAL FLATTEN(input => base_objects_accessed, OUTER => TRUE) src
  WHERE query_start_time >= DATEADD('day', -1, CURRENT_DATE())
    AND query_start_time < CURRENT_DATE()
  GROUP BY 1, 2;
```

### Security Alerts View

```sql
-- Anomaly detection: unusual access patterns
CREATE OR REPLACE VIEW audit_db.public.security_alerts AS

-- Alert 1: Users accessing data outside business hours
SELECT
    'OFF_HOURS_ACCESS' AS alert_type,
    user_name,
    query_start_time,
    query_id,
    'Query executed outside business hours' AS description
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
WHERE (HOUR(query_start_time) < 7 OR HOUR(query_start_time) > 20)
    AND DAYOFWEEK(query_start_time) BETWEEN 1 AND 5
    AND query_start_time >= DATEADD('day', -1, CURRENT_TIMESTAMP())

UNION ALL

-- Alert 2: Excessive failed logins
SELECT
    'BRUTE_FORCE_SUSPECT' AS alert_type,
    user_name,
    MAX(event_timestamp) AS query_start_time,
    NULL AS query_id,
    COUNT(*) || ' failed login attempts' AS description
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE is_success = 'NO'
    AND event_timestamp >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
GROUP BY user_name
HAVING COUNT(*) >= 5

UNION ALL

-- Alert 3: Large data exports
SELECT
    'LARGE_DATA_EXPORT' AS alert_type,
    user_name,
    start_time AS query_start_time,
    query_id,
    'Exported ' || rows_produced || ' rows' AS description
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_type IN ('UNLOAD', 'GET')
    AND rows_produced > 1000000
    AND start_time >= DATEADD('day', -1, CURRENT_TIMESTAMP());
```

---

## 11. ACCOUNT_USAGE Schema Retention Periods

| View | Latency | Retention Period |
|---|---|---|
| ACCESS_HISTORY | Up to 45 min | 365 days |
| LOGIN_HISTORY | Up to 120 min | 365 days |
| QUERY_HISTORY | Up to 45 min | 365 days |
| SESSIONS | Up to 120 min | 365 days |
| WAREHOUSE_METERING_HISTORY | Up to 180 min | 365 days |
| STORAGE_USAGE | Up to 180 min | 365 days |
| COPY_HISTORY | Up to 120 min | 365 days |
| TASK_HISTORY | Up to 45 min | 365 days |
| POLICY_REFERENCES | Up to 120 min | Current state (no historical retention) |
| TABLES / COLUMNS / VIEWS | Up to 120 min | Includes dropped objects (14 days after drop) |

> **Important:** For longer retention, export audit data to a separate table or external storage before the 365-day window expires.

```sql
-- Archive audit data beyond 365 days
CREATE OR REPLACE TASK archive_access_history
  WAREHOUSE = audit_wh
  SCHEDULE = 'USING CRON 0 2 1 * * America/New_York'
AS
  INSERT INTO audit_db.public.access_history_archive
  SELECT *
  FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
  WHERE query_start_time BETWEEN DATEADD('day', -395, CURRENT_TIMESTAMP())
                               AND DATEADD('day', -360, CURRENT_TIMESTAMP());
```

---

## 12. ORGANIZATION_USAGE Schema

For multi-account organizations, the `SNOWFLAKE.ORGANIZATION_USAGE` schema provides cross-account visibility.

```sql
-- Credit usage across all accounts in the organization
SELECT
    account_name,
    service_type,
    SUM(credits_used) AS total_credits
FROM SNOWFLAKE.ORGANIZATION_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('month', -1, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY total_credits DESC;

-- Storage usage across all accounts
SELECT
    account_name,
    usage_date,
    storage_bytes / POWER(1024, 4) AS storage_tb,
    stage_bytes / POWER(1024, 4) AS stage_tb,
    failsafe_bytes / POWER(1024, 4) AS failsafe_tb
FROM SNOWFLAKE.ORGANIZATION_USAGE.STORAGE_USAGE
WHERE usage_date >= DATEADD('day', -30, CURRENT_DATE())
ORDER BY account_name, usage_date;

-- Login history across all accounts (org-wide security monitoring)
SELECT
    account_name,
    user_name,
    event_timestamp,
    is_success,
    client_ip,
    error_message
FROM SNOWFLAKE.ORGANIZATION_USAGE.LOGIN_HISTORY
WHERE event_timestamp >= DATEADD('day', -7, CURRENT_TIMESTAMP())
    AND is_success = 'NO'
ORDER BY event_timestamp DESC;
```

> **Access requirement:** Only the organization account administrator can access `ORGANIZATION_USAGE`. The `ORGADMIN` role is required.

---

## 13. Common Interview Questions & Answers

### Q1: What is the ACCESS_HISTORY view and why is it important?

**A:** `ACCESS_HISTORY` in `SNOWFLAKE.ACCOUNT_USAGE` tracks all read and write operations at the **column level**. It records which user accessed which columns of which tables, including resolving views to their base tables. It is critical for compliance (GDPR, HIPAA), data governance, data lineage tracking, and security auditing. It retains data for 365 days and has a latency of up to 45 minutes.

### Q2: How does Snowflake enable data lineage tracking?

**A:** Through the `ACCESS_HISTORY` view, which records both `BASE_OBJECTS_ACCESSED` (source tables/columns) and `OBJECTS_MODIFIED` (target tables/columns) for each query. By joining these arrays, you can trace data flow from source to target across your entire pipeline. This is automatic -- no additional configuration or third-party tools are required for basic lineage.

### Q3: What is the difference between ACCOUNT_USAGE and INFORMATION_SCHEMA for auditing?

**A:** `ACCOUNT_USAGE` provides 365-day retention with up to 45-180 minute latency, covers dropped objects, and includes cross-database views. `INFORMATION_SCHEMA` provides real-time data but only retains 7-14 days, is scoped to a single database, and does not include dropped objects. For auditing, `ACCOUNT_USAGE` is preferred; for real-time monitoring, use `INFORMATION_SCHEMA`.

### Q4: How would you detect unauthorized data access?

**A:** Combine multiple ACCOUNT_USAGE views: (1) Use `LOGIN_HISTORY` to detect failed logins and unusual IPs. (2) Use `QUERY_HISTORY` to find queries by privileged roles (ACCOUNTADMIN). (3) Use `ACCESS_HISTORY` to track access to sensitive tables/columns. (4) Use `SESSIONS` to detect unusual authentication methods. Build alerts for off-hours access, excessive failed logins, large data exports, and access from new IP addresses.

### Q5: How do you handle audit data beyond the 365-day retention period?

**A:** Create a scheduled task that periodically exports audit data from `ACCOUNT_USAGE` views to permanent tables in a dedicated audit database or to external storage (S3, Azure Blob). Run this before data ages past 365 days. These archive tables can then be queried for long-term compliance and historical auditing needs.

### Q6: What is the ORGANIZATION_USAGE schema used for?

**A:** `ORGANIZATION_USAGE` provides cross-account visibility for organizations with multiple Snowflake accounts. It includes views for credit usage, storage, login history, and more across all accounts. It requires the `ORGADMIN` role and is useful for centralized billing, security monitoring, and governance across a multi-account deployment.

### Q7: How can you track who has been granted ACCOUNTADMIN privileges?

**A:** Query `QUERY_HISTORY` filtering for `query_type = 'GRANT'` and search for grants involving the ACCOUNTADMIN role. Also use the `GRANTS_TO_ROLES` and `GRANTS_TO_USERS` views in `ACCOUNT_USAGE` to see current privilege assignments, and `ACCESS_HISTORY` to monitor what ACCOUNTADMIN users are accessing.

### Q8: Explain column-level access tracking in Snowflake.

**A:** The `ACCESS_HISTORY` view captures the specific columns accessed in each query, not just the table. The `BASE_OBJECTS_ACCESSED` field contains a nested array with column-level detail, even resolving through views to the underlying base table columns. This enables auditing at the most granular level -- for example, tracking exactly who accessed a `SALARY` or `SSN` column.

---

## 14. Tips for Interviews and Practice

- **Know the latency and retention** for each ACCOUNT_USAGE view. Interviewers often ask about limitations.
- **ACCESS_HISTORY is the star view** for governance and compliance questions. Understand its VARIANT columns and how to use LATERAL FLATTEN.
- **Real-time vs historical:** Use `INFORMATION_SCHEMA` functions (e.g., `LOGIN_HISTORY()`, `QUERY_HISTORY()`) for real-time needs; `ACCOUNT_USAGE` for historical analysis.
- **Always mention data lineage** when discussing ACCESS_HISTORY. It is a key differentiator for Snowflake's governance capabilities.
- **Archival strategy** is important: 365-day retention means you must proactively archive for long-term compliance.
- **ORGANIZATION_USAGE** is the answer for multi-account governance questions.
- **Combine views** for comprehensive auditing: ACCESS_HISTORY + QUERY_HISTORY + LOGIN_HISTORY gives a complete picture of who did what, when, and how.
- **POLICY_REFERENCES** is essential for demonstrating that sensitive data is properly protected. Use it in gap analysis queries.
- **Privileged access monitoring** is a common compliance requirement. Always have a query ready that audits ACCOUNTADMIN usage.

---
