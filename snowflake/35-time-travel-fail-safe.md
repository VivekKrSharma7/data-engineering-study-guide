# Time Travel & Fail-Safe

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Time Travel Concept](#time-travel-concept)
2. [DATA_RETENTION_TIME_IN_DAYS Parameter](#data_retention_time_in_days-parameter)
3. [Querying Historical Data](#querying-historical-data)
4. [UNDROP Command](#undrop-command)
5. [Cloning at a Point in Time](#cloning-at-a-point-in-time)
6. [Time Travel Storage Costs](#time-travel-storage-costs)
7. [Fail-Safe](#fail-safe)
8. [Time Travel vs Fail-Safe](#time-travel-vs-fail-safe)
9. [Transient vs Permanent vs Temporary Tables](#transient-vs-permanent-vs-temporary-tables)
10. [Storage Cost Management](#storage-cost-management)
11. [Common Interview Questions](#common-interview-questions)
12. [Tips](#tips)

---

## Time Travel Concept

**Time Travel** is a Snowflake feature that allows you to access historical data — data that has been changed or deleted — within a defined retention period. It enables:

- Querying data as it existed at any point within the retention window.
- Restoring tables, schemas, and databases that have been dropped.
- Creating clones of objects as they existed at a past point in time.

Time Travel works automatically. Snowflake maintains historical versions of data in its micro-partitions. When data is modified or deleted, the old micro-partitions are preserved for the duration of the retention period.

### How It Works (Under the Hood)

1. Snowflake stores data in immutable **micro-partitions**.
2. When a DML operation (INSERT, UPDATE, DELETE, MERGE) modifies data, new micro-partitions are created while the old ones are retained.
3. During the retention period, Snowflake can reconstruct the state of a table at any past point by referencing the appropriate set of micro-partitions.
4. After the retention period expires, old micro-partitions move into **Fail-Safe** (for permanent tables) and are no longer accessible via Time Travel.

---

## DATA_RETENTION_TIME_IN_DAYS Parameter

This parameter controls how long historical data is retained for Time Travel. It can be set at multiple levels: **account**, **database**, **schema**, and **table**.

### Retention Limits by Edition

| Snowflake Edition | Minimum | Maximum | Default |
|-------------------|---------|---------|---------|
| **Standard** | 0 | 1 day | 1 day |
| **Enterprise** | 0 | 90 days | 1 day |
| **Business Critical** | 0 | 90 days | 1 day |
| **VPS** | 0 | 90 days | 1 day |

### Setting the Parameter

```sql
-- Set at the account level (ACCOUNTADMIN required)
ALTER ACCOUNT SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- Set at the database level
ALTER DATABASE analytics_db SET DATA_RETENTION_TIME_IN_DAYS = 14;

-- Set at the schema level
ALTER SCHEMA analytics_db.staging SET DATA_RETENTION_TIME_IN_DAYS = 1;

-- Set at the table level
ALTER TABLE analytics_db.staging.raw_events SET DATA_RETENTION_TIME_IN_DAYS = 7;

-- Disable Time Travel for a table (0 days)
ALTER TABLE analytics_db.staging.temp_loads SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- Check the current setting
SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN TABLE analytics_db.staging.raw_events;
```

### Inheritance Hierarchy

The parameter follows this precedence (most specific wins):

```
Table > Schema > Database > Account
```

If a table does not have the parameter explicitly set, it inherits from its schema, then database, then account.

---

## Querying Historical Data

Snowflake provides several methods to query data as it existed in the past using the `AT` and `BEFORE` clauses.

### Method 1: AT with TIMESTAMP

Query data as it existed **at** a specific timestamp.

```sql
-- Query the orders table as it was at a specific time
SELECT *
FROM orders
AT (TIMESTAMP => '2026-03-06 14:30:00'::TIMESTAMP_LTZ);

-- Using a variable
SET ts = '2026-03-06 14:30:00'::TIMESTAMP_LTZ;
SELECT * FROM orders AT (TIMESTAMP => $ts);
```

### Method 2: BEFORE with TIMESTAMP

Query data as it existed **just before** a specific timestamp.

```sql
-- Query data just before a specific time
SELECT *
FROM orders
BEFORE (TIMESTAMP => '2026-03-06 14:30:00'::TIMESTAMP_LTZ);
```

### Method 3: AT/BEFORE with OFFSET

Query data as it existed a specified number of **seconds** ago.

```sql
-- Query data as it was 1 hour ago (3600 seconds)
SELECT *
FROM orders
AT (OFFSET => -3600);

-- Query data as it was 30 minutes ago
SELECT *
FROM orders
AT (OFFSET => -1800);
```

### Method 4: AT/BEFORE with STATEMENT (Query ID)

Query data as it existed just before or at the point when a specific statement was executed. This is extremely useful for recovering from accidental DML.

```sql
-- Oops! Accidentally deleted all rows
DELETE FROM orders WHERE 1 = 1;  -- Query ID: '01a2b3c4-...'

-- Recover by querying the state before that DELETE
SELECT *
FROM orders
BEFORE (STATEMENT => '01a2b3c4-0000-0000-0000-000000000001');

-- Restore the table by inserting the historical data back
INSERT INTO orders
SELECT *
FROM orders
BEFORE (STATEMENT => '01a2b3c4-0000-0000-0000-000000000001');
```

### AT vs BEFORE

| Clause | Behavior |
|--------|----------|
| `AT` | Returns data as it existed **at** the specified point (inclusive) |
| `BEFORE` | Returns data as it existed **just before** the specified point (exclusive) |

### Real-World Recovery Example

```sql
-- Step 1: An accidental UPDATE corrupts data
UPDATE customers SET email = 'wrong@email.com';
-- Query ID: '01aabbcc-dddd-eeee-ffff-000000000001'

-- Step 2: Identify the query ID from QUERY_HISTORY
SELECT query_id, query_text, start_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE query_text ILIKE '%UPDATE customers%'
ORDER BY start_time DESC
LIMIT 5;

-- Step 3: Verify the historical data looks correct
SELECT * FROM customers
BEFORE (STATEMENT => '01aabbcc-dddd-eeee-ffff-000000000001')
LIMIT 10;

-- Step 4: Restore the data
CREATE OR REPLACE TABLE customers AS
SELECT * FROM customers
BEFORE (STATEMENT => '01aabbcc-dddd-eeee-ffff-000000000001');
```

---

## UNDROP Command

`UNDROP` restores objects (tables, schemas, databases) that were dropped within the Time Travel retention period.

### UNDROP TABLE

```sql
-- Drop a table
DROP TABLE orders;

-- Restore the table
UNDROP TABLE orders;
```

### UNDROP SCHEMA

```sql
-- Drop a schema
DROP SCHEMA staging;

-- Restore the schema (and all its objects)
UNDROP SCHEMA staging;
```

### UNDROP DATABASE

```sql
-- Drop a database
DROP DATABASE analytics_db;

-- Restore the database (and all schemas/objects within)
UNDROP DATABASE analytics_db;
```

### Important UNDROP Behaviors

- **Name conflicts**: If a new object with the same name exists, UNDROP will fail. You must rename or drop the conflicting object first.
- **Cascading restore**: UNDROP on a schema restores all tables within it. UNDROP on a database restores all schemas and tables.
- **Retention window**: UNDROP only works within the `DATA_RETENTION_TIME_IN_DAYS` window.

```sql
-- Handling name conflicts
-- Scenario: You dropped "orders", then created a new "orders" table
DROP TABLE orders;                -- Drops original
CREATE TABLE orders (id INT);     -- Creates a new one
UNDROP TABLE orders;              -- ERROR: object already exists

-- Solution: Rename the new table first
ALTER TABLE orders RENAME TO orders_new;
UNDROP TABLE orders;              -- Restores the original
```

### Multiple Drops of the Same Name

If a table with the same name is dropped multiple times, each `UNDROP` restores the **most recently dropped** version first.

```sql
CREATE TABLE test (v INT);
INSERT INTO test VALUES (1);
DROP TABLE test;

CREATE TABLE test (v INT);
INSERT INTO test VALUES (2);
DROP TABLE test;

UNDROP TABLE test;  -- Restores the version with v=2
DROP TABLE test;    -- Drop it again
UNDROP TABLE test;  -- Now restores the version with v=1
```

---

## Cloning at a Point in Time

You can combine `CREATE ... CLONE` with Time Travel to create a clone of an object as it existed at a past point.

```sql
-- Clone a table as it was 1 hour ago
CREATE TABLE orders_backup
CLONE orders
AT (OFFSET => -3600);

-- Clone a table as it was at a specific timestamp
CREATE TABLE orders_snapshot
CLONE orders
AT (TIMESTAMP => '2026-03-06 10:00:00'::TIMESTAMP_LTZ);

-- Clone a table as it was before a specific statement
CREATE TABLE orders_pre_delete
CLONE orders
BEFORE (STATEMENT => '01aabbcc-dddd-eeee-ffff-000000000001');

-- Clone an entire schema at a past point
CREATE SCHEMA staging_backup
CLONE staging
AT (TIMESTAMP => '2026-03-05 00:00:00'::TIMESTAMP_LTZ);

-- Clone an entire database at a past point
CREATE DATABASE analytics_backup
CLONE analytics_db
AT (TIMESTAMP => '2026-03-01 00:00:00'::TIMESTAMP_LTZ);
```

---

## Time Travel Storage Costs

Time Travel incurs storage costs because Snowflake retains historical micro-partitions that have been modified or deleted.

### How Costs Are Calculated

- You pay for the **changed micro-partitions only**, not the entire table.
- If you update 10% of a table, the old versions of the affected micro-partitions are retained.
- Storage is charged at the standard Snowflake storage rate for your account.

### Monitoring Storage

```sql
-- Check Time Travel storage at the table level
SELECT
    TABLE_CATALOG,
    TABLE_SCHEMA,
    TABLE_NAME,
    ACTIVE_BYTES,
    TIME_TRAVEL_BYTES,
    FAILSAFE_BYTES,
    RETAINED_FOR_CLONE_BYTES
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TIME_TRAVEL_BYTES > 0
ORDER BY TIME_TRAVEL_BYTES DESC
LIMIT 20;

-- Check total storage by database
SELECT
    TABLE_CATALOG AS database_name,
    SUM(ACTIVE_BYTES) / POWER(1024, 3) AS active_gb,
    SUM(TIME_TRAVEL_BYTES) / POWER(1024, 3) AS time_travel_gb,
    SUM(FAILSAFE_BYTES) / POWER(1024, 3) AS failsafe_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
GROUP BY TABLE_CATALOG
ORDER BY time_travel_gb DESC;
```

### Cost Implications

| Retention Days | Relative Storage Cost | Notes |
|---------------|----------------------|-------|
| 0 | None | No Time Travel; no recovery possible |
| 1 (default) | Low | Suitable for most staging/transient data |
| 7 | Moderate | Good balance for production tables |
| 30 | High | Use for critical, frequently modified data |
| 90 | Very High | Typically reserved for compliance/audit tables |

---

## Fail-Safe

**Fail-Safe** is a Snowflake-managed data recovery feature that provides a **7-day, non-configurable** window of protection **after** the Time Travel period expires.

### Key Characteristics

| Property | Detail |
|----------|--------|
| **Duration** | 7 days (fixed, cannot be changed) |
| **Access** | Snowflake support only — users cannot query or restore data directly |
| **Purpose** | Disaster recovery for catastrophic events |
| **Applies to** | Permanent tables only (not transient or temporary tables) |
| **Cost** | You pay storage for Fail-Safe data |
| **Recovery** | Contact Snowflake support; recovery is best-effort and may take hours |

### Fail-Safe Timeline

```
|<---- Time Travel ---->|<---- Fail-Safe ---->|  Data Purged
|    (0-90 days)        |     (7 days)        |
|  User-accessible      | Snowflake-only      |
|  (AT/BEFORE/UNDROP)   | (Support ticket)    |
```

### Requesting Fail-Safe Recovery

1. Open a support ticket with Snowflake.
2. Provide the object name, approximate time of data loss, and account details.
3. Snowflake attempts recovery (best-effort, not guaranteed).
4. Recovery can take several hours depending on data volume.

---

## Time Travel vs Fail-Safe

| Feature | Time Travel | Fail-Safe |
|---------|-------------|-----------|
| **Duration** | 0-90 days (configurable) | 7 days (fixed) |
| **When it starts** | Immediately after data change | After Time Travel period ends |
| **User accessible** | Yes (SQL queries, UNDROP, CLONE) | No (Snowflake support only) |
| **Cost** | Storage for retained micro-partitions | Storage for retained micro-partitions |
| **Configurable** | Yes (`DATA_RETENTION_TIME_IN_DAYS`) | No |
| **Recovery method** | Self-service via SQL | Support ticket, best-effort |
| **Applies to permanent tables** | Yes | Yes |
| **Applies to transient tables** | Yes (max 1 day) | No |
| **Applies to temporary tables** | Yes (max 1 day) | No |

### Total Protection Window (Permanent Table Example)

```
Retention = 14 days:
|<-- 14 days Time Travel -->|<-- 7 days Fail-Safe -->|  = 21 days total protection

Retention = 90 days:
|<--- 90 days Time Travel --->|<-- 7 days Fail-Safe -->|  = 97 days total protection

Retention = 0 days:
|<-- 7 days Fail-Safe -->|  = 7 days (Fail-Safe only, no self-service recovery)
```

---

## Transient vs Permanent vs Temporary Tables

The table type you choose directly impacts Time Travel and Fail-Safe behavior.

### Comparison

| Property | Permanent Table | Transient Table | Temporary Table |
|----------|----------------|-----------------|-----------------|
| **Created with** | `CREATE TABLE` | `CREATE TRANSIENT TABLE` | `CREATE TEMPORARY TABLE` |
| **Time Travel max** | 90 days (Enterprise+) | 1 day | 1 day |
| **Time Travel default** | 1 day | 1 day | 1 day |
| **Fail-Safe** | Yes (7 days) | No | No |
| **Persists across sessions** | Yes | Yes | No (session-scoped) |
| **UNDROP** | Yes (within retention) | Yes (within retention) | No (dropped at session end) |
| **Storage cost** | Highest (data + TT + FS) | Medium (data + TT) | Lowest (data + TT, session-only) |
| **Best for** | Production, critical data | Staging, ETL intermediate | Session-specific scratch data |

### Transient Databases and Schemas

When you create a transient database or schema, **all tables created within them are automatically transient**.

```sql
-- Create a transient database (all objects inside will be transient)
CREATE TRANSIENT DATABASE staging_db;

-- Create a transient schema
CREATE TRANSIENT SCHEMA etl_scratch;

-- Create a transient table explicitly
CREATE TRANSIENT TABLE staging_db.public.raw_events (
    event_id STRING,
    event_data VARIANT,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Temporary table (exists only for the current session)
CREATE TEMPORARY TABLE session_temp (
    id INT,
    value STRING
);
```

### Real-World Guidance

```
Production fact/dimension tables  -->  Permanent (14-90 day retention)
Staging/landing zone tables       -->  Transient (0-1 day retention)
ETL intermediate results          -->  Transient or Temporary
Ad-hoc analysis scratch tables    -->  Temporary
```

---

## Storage Cost Management

### Strategies to Minimize Time Travel and Fail-Safe Costs

1. **Right-size retention periods**: Not every table needs 90 days. Use shorter retention for staging and transient workloads.

```sql
-- Staging tables: minimal retention
ALTER TABLE staging.raw_events SET DATA_RETENTION_TIME_IN_DAYS = 0;

-- Production tables: moderate retention
ALTER TABLE production.orders SET DATA_RETENTION_TIME_IN_DAYS = 7;

-- Audit tables: maximum retention
ALTER TABLE compliance.audit_log SET DATA_RETENTION_TIME_IN_DAYS = 90;
```

2. **Use transient tables** for non-critical data to eliminate Fail-Safe costs entirely.

3. **Use temporary tables** for session-scoped work to avoid any persistent storage overhead.

4. **Monitor storage regularly** to identify tables with unexpectedly high Time Travel or Fail-Safe costs.

```sql
-- Find tables with the highest Time Travel storage
SELECT
    TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME AS full_name,
    ROUND(ACTIVE_BYTES / POWER(1024, 3), 2) AS active_gb,
    ROUND(TIME_TRAVEL_BYTES / POWER(1024, 3), 2) AS tt_gb,
    ROUND(FAILSAFE_BYTES / POWER(1024, 3), 2) AS fs_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_CATALOG IS NOT NULL
  AND (TIME_TRAVEL_BYTES > 0 OR FAILSAFE_BYTES > 0)
ORDER BY (TIME_TRAVEL_BYTES + FAILSAFE_BYTES) DESC
LIMIT 20;
```

5. **Avoid frequent large-scale DML** on tables with long retention. Each UPDATE/DELETE creates new micro-partitions while retaining the old ones.

6. **Use COPY INTO + TRUNCATE patterns** instead of DELETE for bulk reloads — or use transient tables for staging.

---

## Common Interview Questions

### Q1: What is Time Travel in Snowflake and how does it work?

**A:** Time Travel allows querying, restoring, and cloning historical data within a configurable retention period (0-90 days depending on edition). It works by retaining old micro-partitions that are replaced during DML operations. Users can access historical data using `AT` or `BEFORE` clauses with a timestamp, offset (seconds), or statement ID. It also enables `UNDROP` for dropped objects and point-in-time cloning.

---

### Q2: What is the maximum Time Travel retention for each Snowflake edition?

**A:** Standard Edition supports a maximum of **1 day**. Enterprise, Business Critical, and VPS editions support up to **90 days**. The default for all editions is **1 day**. Transient and temporary tables are limited to a maximum of **1 day** regardless of edition.

---

### Q3: What is the difference between AT and BEFORE in Time Travel queries?

**A:** `AT` returns data as it existed **at** the specified point in time (inclusive of changes made at that exact moment). `BEFORE` returns data as it existed **just before** the specified point (exclusive). When using `BEFORE (STATEMENT => ...)`, it returns data as it was immediately before that statement executed — this is the most common method for recovering from accidental DML.

---

### Q4: What is Fail-Safe and how does it differ from Time Travel?

**A:** Fail-Safe is a **7-day, non-configurable** recovery window that begins **after** the Time Travel period expires. Unlike Time Travel, Fail-Safe data is **not accessible to users** — recovery requires a Snowflake support ticket and is best-effort. Fail-Safe applies only to **permanent tables** (not transient or temporary). It serves as a last-resort disaster recovery mechanism.

---

### Q5: How do transient and temporary tables affect Time Travel and Fail-Safe?

**A:** Transient tables support Time Travel up to a **maximum of 1 day** and have **no Fail-Safe**. Temporary tables also have a maximum of 1 day Time Travel and no Fail-Safe, but additionally they only exist for the **duration of the session**. Permanent tables support up to 90 days of Time Travel (Enterprise+) and always have 7 days of Fail-Safe. Using transient tables for non-critical data can significantly reduce storage costs.

---

### Q6: Can you UNDROP a table if a new table with the same name already exists?

**A:** No. UNDROP will fail if an object with the same name already exists. You must first **rename or drop** the conflicting object, then run UNDROP. If the same table name was dropped multiple times, each UNDROP restores the most recently dropped version first (LIFO order).

---

### Q7: How do you recover data after an accidental DELETE or UPDATE?

**A:** Use Time Travel with the `BEFORE (STATEMENT => '<query_id>')` clause to access data as it existed before the accidental statement. You can find the query ID from `INFORMATION_SCHEMA.QUERY_HISTORY()`. Then either `INSERT INTO` the table from the historical query, or use `CREATE OR REPLACE TABLE ... AS SELECT ... BEFORE (STATEMENT => ...)` to fully restore the table.

---

### Q8: What is the total data protection window for a permanent table with 14 days of Time Travel?

**A:** The total protection is **21 days**: 14 days of Time Travel (user-accessible, self-service recovery) plus 7 days of Fail-Safe (Snowflake-support-only recovery). After 21 days, historical data is permanently purged.

---

### Q9: How do you monitor Time Travel storage costs?

**A:** Query the `SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS` view, which provides `ACTIVE_BYTES`, `TIME_TRAVEL_BYTES`, and `FAILSAFE_BYTES` per table. Aggregate these values by database or schema to identify areas with high historical data storage. Use this data to right-size retention periods.

---

## Tips

1. **Always check the query ID** before running recovery. Use `INFORMATION_SCHEMA.QUERY_HISTORY()` or `SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY` to find the exact statement that caused data loss.
2. **Use `BEFORE (STATEMENT => ...)` for recovery** — it is the most precise method because it captures data exactly before the problematic operation.
3. **Do not rely on Fail-Safe** as a backup strategy. It is best-effort, slow, and requires Snowflake support intervention. Use Time Travel and proper backup procedures instead.
4. **Set retention at the schema level** for consistency. Override at the table level only when specific tables need different retention.
5. **Transient tables are your friend** for ETL staging. They save significant storage costs by eliminating Fail-Safe while still providing 1 day of Time Travel.
6. **Test your recovery procedures** before you need them. Practice UNDROP and Time Travel queries in a dev environment so you are confident during an actual incident.
7. **Remember the Standard Edition limit** — only 1 day of Time Travel. If your organization needs longer retention, Enterprise Edition or higher is required.
8. **High-churn tables are expensive** with long retention. If a table is updated millions of rows daily, a 90-day retention will accumulate massive Time Travel storage. Evaluate if that retention is truly necessary.

---
