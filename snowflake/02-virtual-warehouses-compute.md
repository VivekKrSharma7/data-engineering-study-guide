# Virtual Warehouses & Compute Layer

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### What Is a Virtual Warehouse?

A virtual warehouse is a named, independently scalable cluster of compute resources in Snowflake. It is the engine that executes all SQL queries and DML operations. A warehouse does not store data — it reads data from the centralized storage layer, processes it, and returns results.

When you create a warehouse, Snowflake provisions a cluster of cloud-based compute nodes (EC2 instances on AWS, VMs on Azure/GCP) behind the scenes. You never interact with individual nodes — only with the warehouse abstraction.

```sql
-- Create a basic virtual warehouse
CREATE WAREHOUSE reporting_wh
  WITH WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 300        -- seconds of inactivity before suspending
  AUTO_RESUME = TRUE        -- automatically resume when a query arrives
  INITIALLY_SUSPENDED = TRUE;
```

---

### Warehouse Sizes and Credit Consumption

Each warehouse size determines the number of compute nodes in the cluster and the credits consumed per hour of operation.

| Warehouse Size | Nodes (Servers) | Credits/Hour | Relative Performance |
|---------------|-----------------|-------------|---------------------|
| **X-Small**   | 1               | 1           | Baseline            |
| **Small**     | 2               | 2           | ~2x                 |
| **Medium**    | 4               | 4           | ~4x                 |
| **Large**     | 8               | 8           | ~8x                 |
| **X-Large**   | 16              | 16          | ~16x                |
| **2X-Large**  | 32              | 32          | ~32x                |
| **3X-Large**  | 64              | 64          | ~64x                |
| **4X-Large**  | 128             | 128         | ~128x               |
| **5X-Large**  | 256             | 256         | ~256x               |
| **6X-Large**  | 512             | 512         | ~512x               |

**Key points:**

- Each size doubles the nodes and credits compared to the previous size.
- Doubling the size roughly halves the execution time for most queries (linear scaling for scan-heavy workloads).
- Credits are billed per second, with a minimum of 60 seconds each time the warehouse starts.

```sql
-- Resize a warehouse on the fly (no downtime, immediate effect)
ALTER WAREHOUSE reporting_wh SET WAREHOUSE_SIZE = 'LARGE';

-- Check current size
SHOW WAREHOUSES LIKE 'reporting_wh';
```

**Cost example:** If your Snowflake edition charges $3/credit and you run a LARGE warehouse for 2 hours:
- 8 credits/hour x 2 hours = 16 credits x $3 = **$48**

---

### Multi-Cluster Warehouses

A multi-cluster warehouse consists of multiple copies (clusters) of the same warehouse, enabling Snowflake to handle concurrent query loads that exceed the capacity of a single cluster.

```sql
-- Create a multi-cluster warehouse
CREATE WAREHOUSE bi_dashboard_wh
  WITH WAREHOUSE_SIZE = 'MEDIUM'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 5
  SCALING_POLICY = 'STANDARD'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE;
```

#### Auto-Scale Mode vs. Maximized Mode

| Mode          | MIN/MAX Clusters          | Behavior                                                                 |
|---------------|---------------------------|--------------------------------------------------------------------------|
| **Auto-Scale** | MIN < MAX (e.g., 1 to 5) | Clusters are added/removed dynamically based on query load.              |
| **Maximized** | MIN = MAX (e.g., 3 to 3) | All clusters run at all times the warehouse is active. Maximum concurrency, higher cost. |

**Auto-Scale mode** is the most common choice — it scales out when query concurrency increases and scales in when demand drops.

#### Scaling Policies

| Policy       | Behavior                                                                                   |
|--------------|--------------------------------------------------------------------------------------------|
| **Standard** | Adds a cluster after a query has been queued for 20 seconds. Shuts down a cluster after 2-3 consecutive checks (every 60 seconds) show the cluster can be removed. **Favors cost savings.** |
| **Economy**  | Adds a cluster only after estimating enough load to keep the new cluster busy for at least 6 minutes. Shuts down aggressively. **Favors maximum cost savings at the expense of occasional queuing.** |

```sql
-- Change scaling policy
ALTER WAREHOUSE bi_dashboard_wh SET SCALING_POLICY = 'ECONOMY';
```

---

### Auto-Suspend and Auto-Resume

These two features are critical for cost management.

**Auto-Suspend:** Automatically suspends (shuts down) the warehouse after a specified number of seconds of inactivity (no running or queued queries).

**Auto-Resume:** Automatically resumes (starts up) the warehouse when a new query is submitted.

```sql
-- Set auto-suspend to 1 minute (60 seconds) — aggressive for dev/test
ALTER WAREHOUSE dev_wh SET AUTO_SUSPEND = 60;

-- Set auto-suspend to 10 minutes (600 seconds) — typical for production
ALTER WAREHOUSE prod_wh SET AUTO_SUSPEND = 600;

-- Disable auto-suspend (warehouse runs until manually suspended — use with caution)
ALTER WAREHOUSE always_on_wh SET AUTO_SUSPEND = 0;

-- Manually suspend/resume
ALTER WAREHOUSE dev_wh SUSPEND;
ALTER WAREHOUSE dev_wh RESUME;
```

**Best practices for auto-suspend:**

| Workload                         | Recommended Auto-Suspend |
|----------------------------------|--------------------------|
| ETL/batch (runs then idles)      | 60 seconds               |
| BI dashboards (sporadic queries) | 300–600 seconds           |
| Interactive/ad hoc               | 300 seconds              |
| Continuous workloads (streaming) | 0 or very high           |

**Note:** When a warehouse suspends, its local disk cache (SSD cache) is lost. Setting auto-suspend too aggressively on a warehouse where cache reuse is valuable (e.g., BI dashboards hitting the same tables repeatedly) can hurt performance due to constant cache cold-starts.

---

### Query Queuing

When all threads on a warehouse are busy executing queries, new incoming queries are placed in a **queue**. Queries in the queue wait until a thread becomes available.

- Default max concurrency per cluster depends on query complexity and resources, but Snowflake generally targets **8 concurrent queries** per cluster for optimal performance.
- If queries consistently queue, consider:
  1. Scaling up the warehouse (larger size).
  2. Using a multi-cluster warehouse (scaling out).
  3. Enabling concurrency scaling.

```sql
-- Monitor queued and running queries
SELECT query_id, warehouse_name, execution_status, queued_overload_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE queued_overload_time > 0
ORDER BY start_time DESC
LIMIT 20;
```

---

### Warehouse Utilization Monitoring

Snowflake provides several tools for monitoring warehouse performance and cost.

```sql
-- Credit usage by warehouse over the past 30 days
SELECT warehouse_name,
       SUM(credits_used) AS total_credits,
       SUM(credits_used_compute) AS compute_credits,
       SUM(credits_used_cloud_services) AS cloud_services_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- Average query execution time and queuing by warehouse
SELECT warehouse_name,
       COUNT(*) AS total_queries,
       AVG(execution_time) / 1000 AS avg_exec_seconds,
       AVG(queued_overload_time) / 1000 AS avg_queue_seconds,
       MAX(execution_time) / 1000 AS max_exec_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
GROUP BY warehouse_name
ORDER BY total_queries DESC;

-- Warehouse load over time (useful for right-sizing)
SELECT TO_DATE(start_time) AS query_date,
       warehouse_name,
       COUNT(*) AS query_count,
       SUM(credits_used) AS daily_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
GROUP BY query_date, warehouse_name
ORDER BY query_date DESC;
```

---

### Warehouse Types

Snowflake offers two warehouse types:

| Type                     | Use Case                                                                    |
|--------------------------|-----------------------------------------------------------------------------|
| **Standard**             | General-purpose queries — SQL, DML, data loading, BI, reporting. Default.   |
| **Snowpark-Optimized**   | Memory-intensive workloads — ML model training, large-scale data transformations using Snowpark (Python/Java/Scala), UDFs with large data. Provides 16x memory per node compared to standard. |

```sql
-- Create a Snowpark-optimized warehouse
CREATE WAREHOUSE ml_training_wh
  WITH WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 120;
```

---

### Concurrency Scaling

Concurrency scaling is an automatic feature that adds transient warehouse clusters when the regular warehouse is overwhelmed with concurrent queries.

**How it works:**

1. Queries begin to queue on the warehouse.
2. Snowflake automatically provisions additional transient clusters (up to a configurable limit).
3. Queued queries are offloaded to these transient clusters.
4. Transient clusters shut down once the backlog clears.

**Key details:**

- Each Snowflake account gets **1 free credit per cluster per day** of concurrency scaling (accrued, not per-warehouse).
- Beyond the free credit, concurrency scaling is billed at the standard credit rate.
- Concurrency scaling supports **SELECT queries** and some DML (INSERT, COPY INTO) depending on configuration.

```sql
-- Enable concurrency scaling on a warehouse
ALTER WAREHOUSE bi_dashboard_wh
  SET ENABLE_QUERY_ACCELERATION = FALSE;  -- separate feature

-- Concurrency scaling is enabled at the account level and controlled per warehouse
-- Check concurrency scaling credit usage
SELECT warehouse_name,
       SUM(credits_used) AS concurrency_scaling_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_type = 'SELECT'
  AND is_concurrency_scaling = TRUE
GROUP BY warehouse_name;
```

---

### Query Acceleration Service (QAS)

The Query Acceleration Service offloads portions of a query to shared, serverless compute resources. Unlike concurrency scaling (which handles too many queries), QAS accelerates **individual large queries** that would otherwise be bottlenecked.

**Best suited for:**
- Queries with large scans and selective filters
- Queries that spend significant time scanning partitions
- Ad hoc and exploratory analytics

```sql
-- Enable Query Acceleration Service on a warehouse
ALTER WAREHOUSE analytics_wh
  SET ENABLE_QUERY_ACCELERATION = TRUE
  QUERY_ACCELERATION_MAX_SCALE_FACTOR = 8;
  -- Scale factor limits the max serverless compute (relative to warehouse size)
  -- 0 = no limit, 1-10 = proportional limit

-- Check which queries benefited from QAS
SELECT query_id,
       query_acceleration_bytes_scanned,
       query_acceleration_partitions_scanned,
       query_acceleration_upper_limit_scale_factor
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_acceleration_bytes_scanned > 0
ORDER BY start_time DESC
LIMIT 10;

-- Check if a warehouse would benefit from QAS
SELECT *
FROM TABLE(INFORMATION_SCHEMA.QUERY_ACCELERATION_ELIGIBLE('analytics_wh', 24));
```

**Concurrency Scaling vs. Query Acceleration Service:**

| Feature               | Concurrency Scaling                        | Query Acceleration Service               |
|-----------------------|--------------------------------------------|------------------------------------------|
| **Problem solved**    | Too many concurrent queries (queuing)       | Individual slow queries (large scans)    |
| **Mechanism**         | Adds full warehouse clusters               | Offloads scan portions to serverless     |
| **Billing**           | Per-credit (1 free/day per cluster)         | Per-credit (serverless rate)             |
| **Scope**             | Entire queries redirected to new cluster    | Portions of a single query offloaded     |

---

### Warehouse Caching (Local Disk Cache)

Each warehouse maintains a **local SSD cache** (also called local disk cache or warehouse cache) on its compute nodes.

**How it works:**

1. When a query reads micro-partitions from remote cloud storage, the data is cached on local SSDs.
2. Subsequent queries that read the same micro-partitions hit the local cache instead of going to remote storage.
3. The cache uses an LRU (Least Recently Used) eviction policy.

**Important caching behaviors:**

- The cache persists as long as the warehouse is running (not suspended).
- When a warehouse **suspends**, the cache is **cleared entirely**.
- When a warehouse is **resized**, the existing cache is retained on current nodes; new nodes start with empty caches.
- The cache is **per-node** — data is distributed across nodes, so the same partition may or may not be on the same node for different queries.

```
Query Execution Cache Hierarchy:
┌────────────────────────────────────────────────┐
│ 1. Result Cache (Cloud Services Layer)         │
│    - Exact query match, data unchanged, 24 hrs │
│    - FREE (no warehouse needed)                │
├────────────────────────────────────────────────┤
│ 2. Local Disk Cache (Warehouse SSD)            │
│    - Micro-partition level, LRU eviction        │
│    - Requires warehouse running, fast I/O      │
├────────────────────────────────────────────────┤
│ 3. Remote Storage (S3/Blob/GCS)                │
│    - Always available, higher latency          │
│    - Full table scan if nothing cached         │
└────────────────────────────────────────────────┘
```

```sql
-- Check cache effectiveness in query profile
-- Use the Snowflake web UI: Query Profile shows
-- "Percentage scanned from cache" per TableScan operator

-- Query to analyze cache hit rates
SELECT warehouse_name,
       AVG(bytes_scanned) AS avg_bytes_scanned,
       AVG(bytes_spilled_to_local_storage) AS avg_bytes_spilled_local,
       AVG(bytes_spilled_to_remote_storage) AS avg_bytes_spilled_remote
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND warehouse_name IS NOT NULL
GROUP BY warehouse_name;
```

---

## Real-World Example: Right-Sizing Warehouses for an E-Commerce Platform

**Scenario:** An e-commerce company has three workload categories:

```sql
-- 1. ETL pipeline: Runs every hour, processes ~5 GB per run, completes in <5 min
CREATE WAREHOUSE etl_wh
  WITH WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  COMMENT = 'Hourly ETL pipeline - small batches';

-- 2. BI dashboards: 50 analysts running reports during business hours (9am-6pm)
CREATE WAREHOUSE bi_wh
  WITH WAREHOUSE_SIZE = 'MEDIUM'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 4
  SCALING_POLICY = 'STANDARD'
  AUTO_SUSPEND = 600
  AUTO_RESUME = TRUE
  COMMENT = 'BI dashboards - multi-cluster for concurrency';

-- 3. Data science: Sporadic large queries for feature engineering
CREATE WAREHOUSE ds_wh
  WITH WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
  WAREHOUSE_SIZE = 'XLARGE'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  COMMENT = 'Data science - Snowpark, large memory needs';

-- Resource monitor to cap spend per month
CREATE RESOURCE MONITOR monthly_cap
  WITH CREDIT_QUOTA = 5000
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 90 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE etl_wh SET RESOURCE_MONITOR = monthly_cap;
ALTER WAREHOUSE bi_wh SET RESOURCE_MONITOR = monthly_cap;
ALTER WAREHOUSE ds_wh SET RESOURCE_MONITOR = monthly_cap;
```

---

## Common Interview Questions

### Q1: What is a virtual warehouse in Snowflake, and how is it different from a traditional database server?

**Answer:** A virtual warehouse is an independently provisioned cluster of compute resources that executes queries. Unlike a traditional database server, it does not store any data permanently — it reads from a centralized storage layer. Warehouses can be created, resized, started, and stopped on-demand without affecting data or other warehouses. Multiple warehouses can access the same data concurrently with zero contention, which is impossible with a single shared database server.

### Q2: How does warehouse sizing affect performance and cost?

**Answer:** Each step up in warehouse size doubles the number of compute nodes and the credits consumed per hour. A LARGE warehouse (8 nodes, 8 credits/hour) has roughly twice the processing power of a MEDIUM (4 nodes, 4 credits/hour). For scan-heavy queries, doubling the size typically halves execution time, so the total credits consumed remains similar — you pay the same but get results faster. However, for small or simple queries, a larger warehouse may not provide proportional speedup due to overhead, so right-sizing is critical.

### Q3: When would you use a multi-cluster warehouse vs. simply sizing up?

**Answer:** Sizing up (vertical scaling) improves the performance of individual complex queries by adding more compute power per query. Multi-cluster warehouses (horizontal scaling) improve concurrency by adding entire clusters to handle more simultaneous queries. If the problem is that queries are individually slow, scale up. If the problem is that many queries are queuing while the warehouse is busy, scale out with multi-cluster. A common example: 100 BI analysts running small reports should use a multi-cluster SMALL/MEDIUM warehouse rather than a single 4XL warehouse.

### Q4: What is the difference between concurrency scaling and multi-cluster warehouses?

**Answer:** Multi-cluster warehouses are a permanent configuration that proactively scales clusters in and out based on query load. Concurrency scaling is a reactive overflow mechanism — it provisions transient clusters only when queries are actively queuing and cannot be handled by the configured warehouse (including its multi-cluster capacity). In practice, you configure multi-cluster warehouses for predictable concurrency needs and rely on concurrency scaling as a safety net for unexpected spikes. Concurrency scaling includes free daily credits.

### Q5: What happens to the warehouse cache when you suspend a warehouse?

**Answer:** The local disk cache (SSD cache) is entirely lost when a warehouse suspends. When the warehouse resumes, the cache is cold, and the first queries will read data from remote cloud storage, which is slower. This is why setting auto-suspend too aggressively (e.g., 60 seconds) on a warehouse used for interactive BI queries can degrade performance — the cache never warms up. A balance must be struck between cost savings (suspend quickly) and cache effectiveness (keep running longer).

### Q6: What is the Query Acceleration Service and when should you use it?

**Answer:** The Query Acceleration Service (QAS) offloads portions of large scan-heavy queries to serverless compute resources managed by Snowflake. It is ideal for queries where the bottleneck is scanning a large number of micro-partitions with selective filters. It differs from concurrency scaling, which handles too many queries at once. QAS accelerates individual slow queries. You should enable it on warehouses where ad hoc or exploratory queries frequently scan large tables. Use `QUERY_ACCELERATION_ELIGIBLE` to check if a warehouse would benefit.

### Q7: How do you monitor warehouse costs and identify waste?

**Answer:** Use the `SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY` view to track credit consumption per warehouse over time. Look for warehouses with high credits but low query counts (over-provisioned), warehouses with consistently high `queued_overload_time` (under-provisioned), and warehouses that rarely suspend (auto-suspend not configured properly). Resource monitors can be set up to cap spend with alerts at threshold percentages. The `QUERY_HISTORY` view provides per-query execution metrics including bytes scanned, spill amounts, and queue time.

---

## Tips

- **Start small, scale up** — always begin with the smallest warehouse that meets your SLA, then resize based on monitoring data. Snowflake makes resizing instant and non-disruptive.
- **Separate workloads** — create dedicated warehouses for ETL, BI, ad hoc, and data science. This provides workload isolation, independent scaling, and granular cost attribution.
- **Use resource monitors** — always set credit quotas to prevent runaway costs. Configure alerts at 75% and 90%, and auto-suspend at 100%.
- **Auto-suspend trade-off** — shorter auto-suspend saves money but causes cold cache on resume. For BI warehouses with repeat queries, 5-10 minutes is a good balance. For batch ETL, 60 seconds is fine.
- **Multi-cluster vs. sizing up** — a common interview mistake is suggesting a 4XL for concurrency problems. Know the difference between throughput (concurrency, scale out) and latency (query speed, scale up).
- **Know credit math** — be prepared to calculate cost. Credits per hour times hours of usage times price per credit. Understand the 60-second minimum billing per start.
- **Snowpark-optimized warehouses** — mention these when discussing ML or Python/Java UDFs. They demonstrate awareness of Snowflake's modern compute options.
- **Query profile** — in interviews, mention that you use the Query Profile (in the Snowflake UI or via `GET_QUERY_OPERATOR_STATS`) to diagnose performance issues, check cache hit rates, and identify data spilling.
