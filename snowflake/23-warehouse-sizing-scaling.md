# Warehouse Sizing & Scaling (Auto-Scale, Multi-Cluster)

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### Warehouse Sizes and Credit Consumption

Each warehouse size determines the number of compute nodes and the credits consumed per hour.

| Size | Nodes | Credits/Hour | Typical Use Case |
|---|---|---|---|
| X-Small (XS) | 1 | 1 | Light queries, development, testing |
| Small (S) | 2 | 2 | Small-to-medium analytical queries |
| Medium (M) | 4 | 4 | Moderate dashboards, medium ETL |
| Large (L) | 8 | 8 | Complex transformations, large scans |
| X-Large (XL) | 16 | 16 | Heavy ETL, large aggregations |
| 2X-Large | 32 | 32 | Very large data processing |
| 3X-Large | 64 | 64 | Extreme workloads |
| 4X-Large | 128 | 128 | Maximum single-warehouse compute |
| 5X-Large | 256 | 256 | Largest available size |
| 6X-Large | 512 | 512 | Largest available size |

> **Key insight:** Each step up doubles the compute resources and doubles the credit cost. In theory, a query that takes 8 minutes on a Small warehouse should take about 4 minutes on a Medium — same total credits, faster execution.

---

### Scaling Up vs. Scaling Out

This is a critical distinction for both real-world architecture and interviews.

#### Scaling Up (Vertical Scaling)

- **What:** Increasing the warehouse size (e.g., Medium to Large).
- **When:** Queries are individually slow due to complexity or data volume.
- **Effect:** More compute power per query — each query gets more nodes.
- **Use case:** A single complex query or ETL job that scans billions of rows.

```sql
-- Scale up for a heavy nightly ETL job
ALTER WAREHOUSE etl_wh SET WAREHOUSE_SIZE = 'X-LARGE';

-- Scale back down after the job completes
ALTER WAREHOUSE etl_wh SET WAREHOUSE_SIZE = 'SMALL';
```

#### Scaling Out (Horizontal Scaling)

- **What:** Adding more clusters to a multi-cluster warehouse.
- **When:** Many concurrent queries are queuing because the warehouse is busy.
- **Effect:** More clusters handle more concurrent users — each cluster has the same size.
- **Use case:** 50 analysts hitting dashboards at the same time during business hours.

```sql
-- Scale out: configure multi-cluster warehouse
ALTER WAREHOUSE analytics_wh SET
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 6;
```

**Decision framework:**

| Symptom | Solution |
|---|---|
| Single query is slow | Scale UP (larger warehouse size) |
| Queries are queuing / high concurrency | Scale OUT (multi-cluster) |
| Both slow queries and queuing | Scale up AND scale out |

---

### Multi-Cluster Warehouse Configuration

Multi-cluster warehouses run multiple copies of the same-sized warehouse to handle concurrent workloads.

```sql
CREATE WAREHOUSE reporting_wh WITH
    WAREHOUSE_SIZE = 'MEDIUM'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 5
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE;
```

**Parameters:**

| Parameter | Description |
|---|---|
| `MIN_CLUSTER_COUNT` | Minimum number of clusters always running (1 = can scale to zero). |
| `MAX_CLUSTER_COUNT` | Maximum number of clusters that can be started. |
| `SCALING_POLICY` | Controls how aggressively clusters are added/removed. |

> **Note:** Multi-cluster warehouses are available in **Enterprise Edition** and above.

---

### Auto-Scale Mode vs. Maximized Mode

#### Auto-Scale Mode (MIN < MAX)

```sql
-- Auto-scale: clusters start/stop based on demand
ALTER WAREHOUSE reporting_wh SET
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 5;
```

- Clusters are added when queries begin to queue.
- Clusters are removed when load decreases.
- Cost-efficient — you only pay for active clusters.

#### Maximized Mode (MIN = MAX)

```sql
-- Maximized: all clusters run at all times
ALTER WAREHOUSE reporting_wh SET
    MIN_CLUSTER_COUNT = 5
    MAX_CLUSTER_COUNT = 5;
```

- All clusters start immediately and remain running.
- Best for predictable, consistently high-concurrency workloads.
- Higher cost but zero latency for cluster spin-up.

---

### Scaling Policy: Standard vs. Economy

| Aspect | Standard | Economy |
|---|---|---|
| Add cluster trigger | A query is queued or estimated to queue | System waits until enough load to keep a new cluster busy for 6 minutes |
| Remove cluster trigger | After 2-3 consecutive checks show reduced load | After 5-6 consecutive checks show reduced load |
| Responsiveness | Fast — favors performance | Slow — favors cost savings |
| Best for | User-facing workloads where latency matters | Batch or non-interactive workloads where cost matters more |

```sql
-- Standard policy: spin up fast, prioritize performance
ALTER WAREHOUSE reporting_wh SET SCALING_POLICY = 'STANDARD';

-- Economy policy: spin up conservatively, prioritize cost
ALTER WAREHOUSE batch_wh SET SCALING_POLICY = 'ECONOMY';
```

---

### Concurrency and Queuing

- Each warehouse cluster can execute **up to 8 queries concurrently** by default (though this is workload-dependent and managed internally by Snowflake).
- When all execution threads are occupied, additional queries are **queued**.
- Queued queries wait until a thread becomes available or (in multi-cluster mode) a new cluster is started.
- Default maximum queue time is **8 hours** (configurable via `STATEMENT_QUEUED_TIMEOUT_IN_SECONDS`).

```sql
-- Set a shorter queue timeout to fail fast instead of waiting
ALTER WAREHOUSE analytics_wh SET STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 300; -- 5 minutes

-- Set maximum statement execution time
ALTER WAREHOUSE analytics_wh SET STATEMENT_TIMEOUT_IN_SECONDS = 3600; -- 1 hour
```

---

### Query Acceleration Service (QAS)

The Query Acceleration Service offloads portions of a query to serverless compute resources managed by Snowflake. It is particularly effective for queries with large scans that benefit from parallelism.

```sql
-- Enable QAS on a warehouse
ALTER WAREHOUSE analytics_wh SET ENABLE_QUERY_ACCELERATION = TRUE;

-- Set a scale factor (limits the max serverless compute used)
ALTER WAREHOUSE analytics_wh SET QUERY_ACCELERATION_MAX_SCALE_FACTOR = 8;
-- Scale factor of 8 means QAS can use up to 8x the warehouse compute
-- Scale factor of 0 means no limit
```

**When QAS helps:**

- Queries with disproportionately large scan/filter phases.
- Ad-hoc queries with unpredictable data volumes.
- Outlier queries that occasionally scan far more data than typical queries.

**When QAS does NOT help:**

- Queries that are already well-optimized.
- Workloads dominated by small, fast queries.
- Queries bottlenecked by operations other than scanning (e.g., complex joins, large sorts).

```sql
-- Check which queries would benefit from QAS
SELECT query_id, eligible_query_acceleration_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_ELIGIBLE
WHERE warehouse_name = 'ANALYTICS_WH'
  AND eligible_query_acceleration_time > 0
ORDER BY eligible_query_acceleration_time DESC
LIMIT 20;
```

---

### Warehouse Monitoring

#### WAREHOUSE_METERING_HISTORY

```sql
-- View credit consumption by warehouse over the past 30 days
SELECT warehouse_name,
       SUM(credits_used) AS total_credits,
       SUM(credits_used_compute) AS compute_credits,
       SUM(credits_used_cloud_services) AS cloud_services_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;
```

#### Monitoring Multi-Cluster Behavior

```sql
-- See cluster scaling events
SELECT warehouse_name, cluster_number,
       start_time, end_time, credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE warehouse_name = 'REPORTING_WH'
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY start_time DESC;
```

#### Queuing Analysis

```sql
-- Identify warehouses with queuing problems
SELECT warehouse_name,
       COUNT(*) AS total_queries,
       AVG(QUEUED_OVERLOAD_TIME) AS avg_queue_time_ms,
       MAX(QUEUED_OVERLOAD_TIME) AS max_queue_time_ms,
       COUNT(CASE WHEN QUEUED_OVERLOAD_TIME > 0 THEN 1 END) AS queued_query_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
HAVING queued_query_count > 0
ORDER BY avg_queue_time_ms DESC;
```

---

## Workload Isolation Patterns

A well-designed Snowflake environment uses separate warehouses for different workloads to prevent resource contention.

```sql
-- ETL / Data Loading: sized for throughput, can scale up during loads
CREATE WAREHOUSE etl_wh WITH
    WAREHOUSE_SIZE = 'LARGE'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'ETL and data loading workloads';

-- BI / Dashboards: multi-cluster for concurrency
CREATE WAREHOUSE bi_wh WITH
    WAREHOUSE_SIZE = 'SMALL'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 4
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    COMMENT = 'BI dashboards and reporting';

-- Data Science / Ad-hoc: medium size, single cluster
CREATE WAREHOUSE ds_wh WITH
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    COMMENT = 'Data science and ad-hoc exploration';

-- DevOps / Admin: X-Small for light monitoring tasks
CREATE WAREHOUSE admin_wh WITH
    WAREHOUSE_SIZE = 'X-SMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'Admin and monitoring queries';
```

**Benefits of workload isolation:**

- ETL jobs do not slow down dashboards.
- Each workload can be sized and scaled independently.
- Cost attribution is straightforward per team or function.
- Different auto-suspend and timeout policies per workload type.

---

## Right-Sizing Warehouses

### Step-by-Step Approach

1. **Start small** — begin with X-Small or Small.
2. **Measure** — check query execution times, queue times, and bytes scanned.
3. **Scale up if queries are slow** — double the size and compare execution times.
4. **Check for diminishing returns** — if doubling the size does not halve the query time, the bottleneck may be elsewhere (e.g., query design, clustering).
5. **Scale out if queries are queuing** — add multi-cluster configuration.
6. **Re-evaluate periodically** — workloads change over time.

```sql
-- Analyze query performance on a warehouse
SELECT warehouse_size,
       COUNT(*) AS query_count,
       AVG(execution_time) / 1000 AS avg_exec_sec,
       MEDIAN(execution_time) / 1000 AS median_exec_sec,
       AVG(BYTES_SCANNED) / (1024*1024*1024) AS avg_gb_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE warehouse_name = 'ANALYTICS_WH'
  AND start_time >= DATEADD('day', -14, CURRENT_TIMESTAMP())
  AND execution_status = 'SUCCESS'
GROUP BY warehouse_size
ORDER BY warehouse_size;
```

---

## Cost Optimization Strategies

| Strategy | Implementation |
|---|---|
| Set appropriate auto-suspend | Short (60s) for ad-hoc; longer (300-600s) for bursty BI workloads |
| Use auto-resume | Always TRUE — no manual intervention needed |
| Right-size warehouses | Benchmark periodically, avoid oversizing |
| Use resource monitors | Set credit quotas per warehouse, send alerts at thresholds |
| Separate workloads | Prevents one workload from inflating another's warehouse |
| Schedule scale-up for ETL | Resize before heavy jobs, resize down after completion |
| Use economy scaling policy | For batch workloads that can tolerate minor queuing |
| Leverage result caching | Reduces warehouse usage for repeated queries |

```sql
-- Create a resource monitor to cap spending
CREATE RESOURCE MONITOR monthly_limit WITH
    CREDIT_QUOTA = 5000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

-- Assign the monitor to a warehouse
ALTER WAREHOUSE analytics_wh SET RESOURCE_MONITOR = monthly_limit;
```

---

## Real-World Examples

### Example 1: E-Commerce Peak Hours

An e-commerce company sees 10x query volume during business hours (9 AM - 6 PM). Their BI warehouse uses:

```sql
ALTER WAREHOUSE bi_wh SET
    WAREHOUSE_SIZE = 'SMALL'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 10
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300;
```

During off-hours, only 1 cluster runs. During peak, it auto-scales up to 10 clusters to handle concurrency, then scales back down.

### Example 2: Nightly ETL Scaling Pattern

A data team uses a task-driven ETL pipeline that scales the warehouse before heavy loads:

```sql
-- Task 1: Scale up before the nightly load
CREATE TASK scale_up_etl
    WAREHOUSE = admin_wh
    SCHEDULE = 'USING CRON 0 2 * * * America/New_York'
AS
    ALTER WAREHOUSE etl_wh SET WAREHOUSE_SIZE = 'X-LARGE';

-- Task 2: Run the ETL pipeline (depends on Task 1)
-- (actual ETL logic here)

-- Task 3: Scale down after ETL completes
CREATE TASK scale_down_etl
    WAREHOUSE = admin_wh
    AFTER etl_pipeline_complete
AS
    ALTER WAREHOUSE etl_wh SET WAREHOUSE_SIZE = 'SMALL';
```

### Example 3: Query Acceleration for Ad-Hoc Analytics

A data science team runs unpredictable ad-hoc queries. Most are small, but occasionally someone scans a multi-TB table:

```sql
ALTER WAREHOUSE ds_wh SET
    WAREHOUSE_SIZE = 'MEDIUM'
    ENABLE_QUERY_ACCELERATION = TRUE
    QUERY_ACCELERATION_MAX_SCALE_FACTOR = 4;
```

The warehouse stays Medium-sized for typical queries, but QAS bursts extra compute for the rare heavy scan, avoiding the need to permanently over-provision.

---

## Common Interview Questions & Answers

### Q1: What is the difference between scaling up and scaling out in Snowflake?

**A:** Scaling up means increasing the warehouse size (e.g., Small to Large), which provides more compute per query. This helps when individual queries are slow due to data volume or complexity. Scaling out means adding clusters to a multi-cluster warehouse, which handles more concurrent queries. This helps when queries are queuing due to high concurrency. Scaling up addresses query speed; scaling out addresses query throughput.

### Q2: Explain the difference between Standard and Economy scaling policies.

**A:** The Standard policy aggressively adds clusters as soon as queries begin to queue, prioritizing performance and low latency. It also releases clusters relatively quickly when load drops. The Economy policy waits until there is enough sustained load to keep a new cluster busy for at least 6 minutes before adding it, and holds clusters longer before releasing. Standard is ideal for user-facing, latency-sensitive workloads. Economy is better for batch processing where cost savings outweigh minor wait times.

### Q3: What is the difference between auto-scale mode and maximized mode?

**A:** Auto-scale mode sets `MIN_CLUSTER_COUNT < MAX_CLUSTER_COUNT`, allowing Snowflake to dynamically add and remove clusters based on demand. This is cost-efficient for variable workloads. Maximized mode sets `MIN_CLUSTER_COUNT = MAX_CLUSTER_COUNT`, so all clusters are always running. This eliminates cluster startup latency and is ideal for predictable, consistently high-concurrency workloads where you want guaranteed capacity.

### Q4: How would you design a warehouse strategy for an organization with ETL, BI, and ad-hoc workloads?

**A:** I would create separate warehouses for each workload type: (1) An ETL warehouse sized Large or XL that can be scaled up/down via tasks around the ETL schedule, with a short auto-suspend. (2) A BI/reporting warehouse configured as multi-cluster with Standard scaling policy, sized Small or Medium based on query complexity, with a moderate auto-suspend (5 min) to preserve SSD cache. (3) An ad-hoc/data science warehouse sized Medium with Query Acceleration Service enabled, single cluster, moderate auto-suspend. (4) A small admin warehouse for monitoring and management tasks. This provides workload isolation, independent scaling, and clear cost attribution.

### Q5: How does the Query Acceleration Service work?

**A:** QAS offloads portions of eligible query processing to additional serverless compute resources managed by Snowflake. It is most effective for queries that have large scan operations that can be parallelized. The `QUERY_ACCELERATION_MAX_SCALE_FACTOR` limits how much additional compute can be used (e.g., a factor of 8 means up to 8x the warehouse's compute). QAS is billed separately based on usage. It helps avoid over-provisioning warehouses for occasional heavy queries.

### Q6: A warehouse is consuming more credits than expected. How would you investigate?

**A:** I would: (1) Check `WAREHOUSE_METERING_HISTORY` for credit trends over time. (2) Analyze `QUERY_HISTORY` for the warehouse to identify expensive queries (high execution time, high bytes scanned). (3) Check for excessive queuing via `QUEUED_OVERLOAD_TIME` — this may indicate the warehouse is undersized, causing long-running queries to block others. (4) Review auto-suspend settings — a long timeout wastes credits during idle periods. (5) Look for runaway queries or inefficient query patterns. (6) Check if multi-cluster is over-provisioned (too many min clusters). (7) Set up a resource monitor to alert and cap future spending.

### Q7: When should you NOT scale up a warehouse?

**A:** Scaling up does not help when: (1) The bottleneck is query design (e.g., Cartesian joins, missing filters) — fix the query instead. (2) The workload is concurrency-bound, not complexity-bound — scale out instead. (3) There are diminishing returns — if doubling size does not halve execution time, the query may be limited by network, compilation, or result serialization. (4) The warehouse is already right-sized but the data needs better clustering. Always diagnose the root cause before scaling.

---

## Tips

- **Always benchmark before and after resizing** — use `QUERY_HISTORY` to compare execution times. Doubling the warehouse size should roughly halve execution time for scan-heavy queries. If it does not, investigate other bottlenecks.
- **Use resource monitors proactively** — set alerts at 75% and suspend at 100% of monthly credit budgets to prevent surprise costs.
- **Multi-cluster is an Enterprise feature** — be prepared to mention this in interviews, as it is edition-dependent.
- **Auto-suspend of 60 seconds** is a good default for most warehouses. Increase to 300+ seconds for BI warehouses where SSD cache warmth matters.
- **Schedule warehouse resizing** around known workloads (e.g., nightly ETL) using Snowflake Tasks rather than maintaining a permanently large warehouse.
- **Monitor queuing metrics regularly** — if `QUEUED_OVERLOAD_TIME` is consistently high, your warehouse is under-provisioned for the concurrency level.
- **The Query Acceleration Service** is billed separately from warehouse credits — factor it into cost analysis.
