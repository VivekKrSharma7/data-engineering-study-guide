# Result Set Caching & Query Caching

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### The Three Levels of Caching in Snowflake

Snowflake employs a multi-layered caching architecture that dramatically improves query performance and reduces compute costs. Understanding these layers is essential for senior Data Engineers.

#### 1. Result Cache (Query Result Cache)

- **Location:** Snowflake Cloud Services layer (shared across all warehouses).
- **Scope:** Global — results are available to any warehouse as long as conditions are met.
- **Duration:** Results are cached for **24 hours** from the last query that used them. The timer resets each time the cached result is accessed.
- **Cost:** Free — no warehouse credits are consumed when a result is served from this cache.

**Conditions for a result cache hit:**

| Condition | Detail |
|---|---|
| Identical SQL text | The query string must match exactly (whitespace and case-sensitive). |
| Same role | The executing role must be the same as the role that produced the cached result. |
| No underlying data changes | The tables referenced must not have been modified (INSERT, UPDATE, DELETE, MERGE, TRUNCATE, or micro-partition reclustering). |
| No change to referenced objects | Views, UDFs, or external functions must be unchanged. |
| Same query parameters | Session-level parameters that affect results (e.g., timezone, date format) must match. |
| Within 24-hour window | The cached result must not have expired. |

```sql
-- These two queries will NOT share a result cache hit (different whitespace):
SELECT name, salary FROM employees WHERE dept = 'ENG';
SELECT  name, salary  FROM employees  WHERE dept = 'ENG';

-- These two queries will NOT share a result cache hit (different case):
SELECT name FROM employees;
select name from employees;
```

#### 2. Local Disk Cache (Warehouse SSD Cache)

- **Location:** SSD storage attached to the compute nodes within a virtual warehouse.
- **Scope:** Local to a specific warehouse — not shared across warehouses.
- **Duration:** Persists as long as the warehouse is running (suspended warehouses lose this cache).
- **Behavior:** When a warehouse reads micro-partitions from remote storage, it caches them on local SSD. Subsequent queries that need the same micro-partitions can read from SSD instead of remote storage.
- **Eviction:** Uses an LRU (Least Recently Used) eviction policy when local disk fills up.
- **Cost:** The warehouse must be running, so compute credits apply.

```sql
-- First query: reads from remote storage, populates SSD cache
SELECT customer_id, SUM(amount)
FROM sales
WHERE sale_date >= '2025-01-01'
GROUP BY customer_id;

-- Second query (different aggregation, same partitions): benefits from SSD cache
SELECT region, COUNT(*)
FROM sales
WHERE sale_date >= '2025-01-01'
GROUP BY region;
```

#### 3. Remote Disk Cache (Cloud Storage)

- **Location:** The cloud provider's object storage (S3, Azure Blob, GCS).
- **Scope:** This is the persistent storage layer — all data lives here.
- **Behavior:** This is not a "cache" in the traditional sense but the source of truth for all table data stored as micro-partitions. The other caches sit in front of this layer.

### How a Query Traverses the Cache Layers

```
Query Submitted
      |
      v
[Result Cache Hit?] --YES--> Return result (0 credits)
      |
      NO
      v
[Warehouse SSD Cache Hit?] --YES--> Read from local SSD (faster, credits apply)
      |
      NO (full or partial miss)
      v
[Read from Remote Cloud Storage] --> Populate SSD cache --> Return result
```

---

## The USE_CACHED_RESULT Parameter

This session-level parameter controls whether the result cache is used.

```sql
-- Disable result caching for the current session
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Re-enable result caching
ALTER SESSION SET USE_CACHED_RESULT = TRUE;

-- Check current setting
SHOW PARAMETERS LIKE 'USE_CACHED_RESULT' IN SESSION;
```

**When to disable result caching:**

- Benchmarking query performance (you want to measure actual compute time).
- Debugging data freshness issues.
- Ensuring queries always hit the warehouse for testing resource consumption.

> **Note:** Even when `USE_CACHED_RESULT = FALSE`, the local SSD cache is still used. There is no parameter to disable the SSD cache short of suspending and resuming the warehouse.

---

## When the Result Cache Is Invalidated

| Event | Effect |
|---|---|
| DML on underlying table (INSERT, UPDATE, DELETE, MERGE) | Cache invalidated for queries referencing that table. |
| TRUNCATE TABLE | Cache invalidated. |
| Table recreation (CREATE OR REPLACE TABLE) | Cache invalidated. |
| Micro-partition reclustering | Cache invalidated (data physically changed). |
| ALTER TABLE changes (add/drop column, rename) | Cache invalidated. |
| 24 hours since last access | Cache entry expires. |
| Different role executes same query | No cache hit (role mismatch). |
| Changed session parameters (e.g., TIMEZONE) | No cache hit if the parameter affects results. |

---

## Caching and Cost Impact

| Cache Layer | Compute Cost | Storage Cost | Latency |
|---|---|---|---|
| Result Cache | None (served from Cloud Services) | Included in Snowflake overhead | Milliseconds |
| Local SSD Cache | Warehouse must be running (credits consumed) | None (ephemeral) | Low (local I/O) |
| Remote Cloud Storage | Warehouse must be running (credits consumed) | Standard storage costs | Higher (network I/O) |

**Cost optimization through caching:**

- Result cache hits consume zero credits — designing cache-friendly query patterns can significantly reduce costs.
- A warm warehouse (SSD cache populated) is faster than a cold start — consider auto-suspend timeouts carefully.

---

## Cache-Friendly Query Patterns

### 1. Standardize Query Text

```sql
-- BAD: Multiple developers write the same query differently
-- Developer A:
SELECT name, email FROM users WHERE status = 'active';
-- Developer B:
select name,email from users where status='active';

-- GOOD: Use a shared SQL template or view
CREATE OR REPLACE VIEW v_active_users AS
SELECT name, email FROM users WHERE status = 'active';

-- All developers query the view with identical text:
SELECT * FROM v_active_users;
```

### 2. Use Consistent Roles

```sql
-- Ensure reporting queries run under the same role for cache reuse
USE ROLE reporting_role;
SELECT region, SUM(revenue) FROM sales_summary GROUP BY region;
```

### 3. Warm the SSD Cache with Predictable Workloads

```sql
-- Schedule a "warm-up" query after warehouse resume to pre-populate SSD cache
-- for the date range that dashboards will query
SELECT * FROM fact_orders
WHERE order_date >= DATEADD('day', -7, CURRENT_DATE)
LIMIT 0;  -- reads partitions but returns nothing
```

### 4. Consider Auto-Suspend Duration

```sql
-- Short auto-suspend (1 min) saves credits but loses SSD cache quickly
ALTER WAREHOUSE analytics_wh SET AUTO_SUSPEND = 60;

-- Longer auto-suspend (10 min) keeps SSD cache warm for bursty workloads
ALTER WAREHOUSE analytics_wh SET AUTO_SUSPEND = 600;
```

---

## Monitoring Cache Usage

### Query History and Profile

```sql
-- Check if a query used the result cache
SELECT query_id, query_text,
       BYTES_SCANNED,
       PERCENTAGE_SCANNED_FROM_CACHE,
       EXECUTION_STATUS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC;
```

- **BYTES_SCANNED = 0** and very fast execution time typically indicates a result cache hit.
- **PERCENTAGE_SCANNED_FROM_CACHE** shows how much data came from the warehouse SSD cache vs. remote storage.

### Using the Query Profile UI

In the Snowflake web UI, the **Query Profile** for a result-cache hit shows minimal steps and near-zero execution time. Look for the label "QUERY RESULT REUSE" in the profile.

```sql
-- Tag queries for easier monitoring
ALTER SESSION SET QUERY_TAG = 'dashboard_daily_sales';

SELECT region, SUM(revenue)
FROM sales
WHERE sale_date = CURRENT_DATE
GROUP BY region;

-- Later, filter by tag
SELECT query_id, query_tag, BYTES_SCANNED, PERCENTAGE_SCANNED_FROM_CACHE
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TAG = 'dashboard_daily_sales'
  AND START_TIME >= DATEADD('day', -7, CURRENT_TIMESTAMP());
```

---

## Real-World Examples

### Example 1: Dashboard Caching Strategy

A BI dashboard refreshes every 5 minutes with the same queries under the same role. With result caching:

- The first execution scans data and populates the result cache.
- Subsequent refreshes within 24 hours (with no data changes) return instantly at zero cost.
- After an ETL pipeline loads new data, the next dashboard refresh scans fresh data and re-populates the cache.

### Example 2: Shared Reporting Across Teams

Two teams run the same summary query but use different roles (`finance_role` vs `analytics_role`). Each role maintains its own result cache entry. To maximize cache reuse, consider having both teams use a shared `reporting_role` for common queries.

### Example 3: Benchmarking a New Clustering Key

```sql
-- Disable result cache to get true performance numbers
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Suspend and resume warehouse to clear SSD cache
ALTER WAREHOUSE dev_wh SUSPEND;
ALTER WAREHOUSE dev_wh RESUME;

-- Now run the benchmark query with a cold cache
SELECT customer_segment, AVG(order_total)
FROM orders
WHERE order_date BETWEEN '2025-01-01' AND '2025-12-31'
GROUP BY customer_segment;

-- Check BYTES_SCANNED and execution time in query profile
```

---

## Common Interview Questions & Answers

### Q1: What are the three levels of caching in Snowflake and where does each reside?

**A:** Snowflake has three caching layers: (1) **Result Cache** — stored in the Cloud Services layer, shared globally, returns identical query results for free within 24 hours; (2) **Local Disk (SSD) Cache** — stored on the compute nodes of a virtual warehouse, caches micro-partitions read from remote storage using LRU eviction; (3) **Remote Disk** — the persistent cloud object storage (S3/Blob/GCS) where all micro-partition data is stored. A query first checks the result cache, then the SSD cache, and finally reads from remote storage.

### Q2: Under what conditions does Snowflake return a result from the result cache?

**A:** All of the following must be true: the SQL text is exactly identical (including whitespace and case), the same role is used, no underlying table data has changed (no DML, DDL, or reclustering), referenced objects (views, UDFs) are unchanged, relevant session parameters (timezone, etc.) match, and the cached result is within the 24-hour window. The 24-hour timer resets each time the cached result is accessed.

### Q3: Does the result cache consume warehouse credits?

**A:** No. Result cache hits are served entirely from the Cloud Services layer and consume zero warehouse credits. This is one of the most cost-effective optimizations in Snowflake.

### Q4: How can you force a query to bypass the result cache?

**A:** Set `ALTER SESSION SET USE_CACHED_RESULT = FALSE;` before executing the query. This is commonly done during performance benchmarking or troubleshooting.

### Q5: What happens to the local SSD cache when a warehouse is suspended?

**A:** The SSD cache is lost when a warehouse is suspended. When the warehouse resumes, it starts with a cold cache and must re-read data from remote storage. This is why auto-suspend timeout should be balanced — too aggressive saves credits but sacrifices cache warmth.

### Q6: A dashboard query was returning results in milliseconds, but today it suddenly takes 30 seconds. The SQL and data have not changed. What could cause this?

**A:** Several possibilities: (1) the warehouse was suspended and resumed, losing the SSD cache; (2) the 24-hour result cache expired without being refreshed; (3) the role used changed; (4) a session parameter (e.g., timezone) changed; (5) although the user says data has not changed, a background reclustering operation may have reorganized micro-partitions, invalidating the result cache. Check `QUERY_HISTORY` for `BYTES_SCANNED` and `PERCENTAGE_SCANNED_FROM_CACHE`.

### Q7: How does reclustering affect the result cache?

**A:** Automatic reclustering physically rewrites micro-partitions. Even though the logical data has not changed, the underlying micro-partitions are different, so Snowflake invalidates the result cache for any queries referencing those tables.

---

## Tips

- **Standardize SQL formatting** across teams (use views or shared query templates) to maximize result cache hits.
- **Choose auto-suspend wisely**: for frequently queried warehouses, a longer auto-suspend (5-10 minutes) preserves SSD cache and reduces cold-start latency.
- **Use PERCENTAGE_SCANNED_FROM_CACHE** in `QUERY_HISTORY` to measure SSD cache effectiveness — values near 100% mean the warehouse is well-warmed.
- **Avoid unnecessary DML** on tables that serve dashboards — even a single no-op UPDATE invalidates the result cache.
- **Schedule warm-up queries** after known warehouse resume events if predictable query patterns exist.
- **Remember:** the result cache is per-role. Consolidate reporting under a shared role when possible to improve cache hit rates.
- **In interviews**, clearly distinguish between result cache (free, Cloud Services layer) and SSD cache (requires running warehouse) — many candidates conflate them.
