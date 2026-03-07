# Snowflake Architecture Overview (Multi-Cluster Shared Data)

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### The Three-Layer Architecture

Snowflake's architecture is built on three independent layers, each of which can scale independently:

```
┌─────────────────────────────────────────────┐
│           CLOUD SERVICES LAYER              │
│  (Authentication, Metadata, Query Parsing,  │
│   Optimization, Access Control, Security)   │
├─────────────────────────────────────────────┤
│           COMPUTE LAYER                     │
│  (Virtual Warehouses - Independent MPP      │
│   Clusters that execute queries)            │
├─────────────────────────────────────────────┤
│           STORAGE LAYER                     │
│  (Centralized, Persistent Cloud Storage -   │
│   S3, Azure Blob, GCS)                      │
└─────────────────────────────────────────────┘
```

Each layer serves a distinct purpose and operates independently of the others, which is the cornerstone of Snowflake's elasticity and cost model.

---

### 1. Storage Layer

The storage layer is where all data lives persistently. Snowflake stores data in cloud-native object storage provided by the underlying cloud platform:

| Cloud Provider | Object Storage Backend |
|----------------|----------------------|
| AWS            | Amazon S3            |
| Azure          | Azure Blob Storage   |
| GCP            | Google Cloud Storage |

**Key characteristics:**

- Data is organized into **micro-partitions** — compressed, columnar, immutable files ranging from 50 to 500 MB each.
- Data is stored in Snowflake's proprietary columnar format, which is optimized for analytical queries.
- Users do not manage storage directly — Snowflake handles all file organization, compression, and metadata.
- Storage is billed separately from compute, based on the average amount of compressed data stored per month.

**Why this matters:** Because data is stored in cheap, highly durable cloud object storage, Snowflake achieves near-infinite storage scaling at a fraction of the cost of traditional databases that couple storage to compute nodes.

---

### 2. Compute Layer (Virtual Warehouses)

The compute layer consists of one or more **virtual warehouses** — independent MPP (Massively Parallel Processing) clusters of compute nodes provisioned from the cloud provider.

**Key characteristics:**

- Each virtual warehouse is a separate cluster that does not share compute resources with other warehouses.
- Multiple warehouses can simultaneously read from the same data in the storage layer without contention.
- Warehouses can be started, stopped, and resized independently and on-demand.
- No data is stored at the compute layer permanently — only ephemeral caching (local SSD cache) is used.

```sql
-- Create a warehouse
CREATE WAREHOUSE analytics_wh
  WITH WAREHOUSE_SIZE = 'LARGE'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 3
  SCALING_POLICY = 'STANDARD';
```

**Why this matters:** The separation of compute from storage means you can have a small warehouse for light ETL and a large warehouse for heavy BI dashboards, both reading the same tables, without any interference.

---

### 3. Cloud Services Layer

The cloud services layer is the "brain" of Snowflake. It runs across all accounts and is managed entirely by Snowflake. It handles:

| Service                    | Description                                                                 |
|----------------------------|-----------------------------------------------------------------------------|
| **Authentication**         | User login, MFA, SSO (SAML/OAuth), key-pair authentication                  |
| **Access Control**         | RBAC (Role-Based Access Control), privilege management                      |
| **Infrastructure Mgmt**   | Warehouse provisioning, auto-scaling decisions                              |
| **Metadata Management**   | Tracks micro-partition statistics, table schemas, row counts                |
| **Query Parsing & Optimization** | SQL compilation, cost-based optimization, query plan generation       |
| **Transaction Management** | ACID compliance, concurrency control, locking                              |
| **Result Caching**         | 24-hour result cache for repeated queries                                   |

**Important:** The cloud services layer is always running (it does not suspend). Snowflake does not charge for cloud services usage unless it exceeds 10% of daily warehouse credit consumption.

---

### Separation of Storage and Compute

This is the single most important architectural concept in Snowflake and a very common interview topic.

**Traditional architectures tie storage and compute together:**

- **Shared-nothing (e.g., Hadoop, Redshift):** Each node owns a slice of the data. To add storage, you must add compute nodes (and vice versa). Resizing requires data reshuffling.
- **Shared-disk (e.g., Oracle RAC):** All nodes access a shared storage system, but compete for I/O and require complex cache-coherence protocols.

**Snowflake's multi-cluster shared data architecture:**

- Storage and compute are fully decoupled.
- Any warehouse can read any data without owning it.
- You can scale storage independently of compute, and compute independently of storage.
- You pay for storage at rest and compute only when queries are running.

```
Shared-Nothing:        Shared-Disk:         Snowflake (Multi-Cluster Shared Data):
┌──────┐ ┌──────┐    ┌──────┐ ┌──────┐    ┌──────┐ ┌──────┐ ┌──────┐
│Node 1│ │Node 2│    │Node 1│ │Node 2│    │ WH A │ │ WH B │ │ WH C │
│Data 1│ │Data 2│    │      │ │      │    │      │ │      │ │      │
└──────┘ └──────┘    └──┬───┘ └──┬───┘    └──┬───┘ └──┬───┘ └──┬───┘
  (each node owns       │       │            │       │       │
   its own data)     ┌──┴───────┴──┐      ┌──┴───────┴───────┴──┐
                     │ Shared Disk │      │  Cloud Object Store  │
                     └─────────────┘      │  (S3/Blob/GCS)       │
                                          └──────────────────────┘
```

---

### Metadata Management

Snowflake's cloud services layer automatically collects and maintains rich metadata about every micro-partition:

- **Min/Max values** per column per micro-partition
- **Number of distinct values** per column
- **Null count** per column
- **Total number of rows** per micro-partition

This metadata powers:

1. **Partition pruning** — Snowflake skips micro-partitions that cannot contain relevant rows based on query predicates, using the min/max ranges.
2. **Cost-based query optimization** — The optimizer uses cardinality estimates derived from metadata to choose optimal join strategies and execution plans.
3. **Instant COUNT/MIN/MAX** — Some aggregation queries can be answered from metadata alone without scanning any data.

```sql
-- See micro-partition and pruning statistics for a table
SELECT SYSTEM$CLUSTERING_INFORMATION('my_database.my_schema.my_table');

-- Example output shows total micro-partitions, clustering depth, overlap, etc.
```

---

### Query Compilation and Optimization

When a query is submitted, the cloud services layer handles the full lifecycle:

1. **Parsing** — SQL is parsed into an abstract syntax tree (AST).
2. **Semantic Analysis** — Table names, column names, and permissions are validated using metadata.
3. **Optimization** — The cost-based optimizer generates an execution plan, choosing join order, join type (hash, merge, broadcast), and aggregation strategies.
4. **Code Generation** — The optimized plan is compiled into executable code.
5. **Dispatch** — The plan is dispatched to the assigned virtual warehouse for execution.
6. **Result Caching** — If the same query has been run before and the underlying data has not changed, the result is returned from the 24-hour result cache (no warehouse is required).

```sql
-- View the query execution plan
EXPLAIN
SELECT c.customer_name, SUM(o.total_amount)
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE o.order_date >= '2025-01-01'
GROUP BY c.customer_name;
```

---

### Automatic Scaling

Snowflake provides automatic scaling at multiple levels:

| Scaling Type             | Mechanism                                                        |
|--------------------------|------------------------------------------------------------------|
| **Storage scaling**      | Fully automatic — cloud object storage scales without limits.    |
| **Compute scaling (up)** | Resize a warehouse (e.g., from MEDIUM to LARGE) for more power per query. |
| **Compute scaling (out)**| Multi-cluster warehouses add or remove clusters based on concurrency demand. |
| **Concurrency scaling**  | Additional transient clusters spun up automatically to handle query queue overflow. |

No manual data redistribution or rebalancing is ever required.

---

### Micro-Partitions and Columnar Storage

All data in Snowflake is automatically divided into micro-partitions:

- Each micro-partition is a contiguous unit of storage (50–500 MB compressed).
- Within each micro-partition, data is stored in a **columnar format** — each column is stored together, enabling efficient compression and vectorized scanning.
- Micro-partitions are **immutable** — any DML operation (INSERT, UPDATE, DELETE, MERGE) creates new micro-partitions rather than modifying existing ones.

```
Micro-Partition Structure:
┌──────────────────────────────┐
│ Header (metadata, min/max)   │
├──────┬──────┬──────┬─────────┤
│ Col A│ Col B│ Col C│ Col D   │
│ vals │ vals │ vals │ vals    │
│  :   │  :   │  :   │  :     │
│  :   │  :   │  :   │  :     │
└──────┴──────┴──────┴─────────┘
(Each column stored contiguously,
 compressed independently)
```

---

### ACID Transactions

Snowflake fully supports ACID transactions:

| Property        | Snowflake Implementation                                                                                  |
|-----------------|----------------------------------------------------------------------------------------------------------|
| **Atomicity**   | All statements in a transaction succeed or all are rolled back. Snowflake supports multi-statement transactions via `BEGIN ... COMMIT`. |
| **Consistency** | Constraints (NOT NULL, UNIQUE, PRIMARY KEY, FOREIGN KEY) are defined but only NOT NULL is enforced. Data integrity is maintained through immutable micro-partitions. |
| **Isolation**   | Snowflake uses **Snapshot Isolation** (SI). Each statement sees a consistent snapshot of the data as of the transaction start. Read operations never block write operations. |
| **Durability**  | Once committed, data is persisted in cloud object storage, which provides 99.999999999% (11 nines) durability. |

```sql
-- Explicit multi-statement transaction
BEGIN;

INSERT INTO orders (order_id, customer_id, total_amount)
VALUES (1001, 42, 250.00);

UPDATE customers
SET last_order_date = CURRENT_TIMESTAMP()
WHERE customer_id = 42;

COMMIT;
-- Both statements succeed or both roll back
```

**Key point about isolation:** Snowflake does not use traditional row-level locking. Instead, it leverages its immutable micro-partition model — writes create new micro-partitions, and concurrent readers continue to see the old partitions until the transaction commits.

---

## Real-World Example: Why Architecture Matters

**Scenario:** A retail company has three teams — Data Engineering, Analytics, and Data Science — all working with the same 10 TB sales dataset.

**In a traditional shared-nothing system (e.g., Redshift):**
- All teams share the same cluster.
- Data Science runs a massive ML feature extraction query that saturates the cluster.
- Analytics dashboards slow to a crawl. Data Engineering ETL jobs back up.
- Scaling means resizing the single cluster, which impacts everyone.

**In Snowflake:**
```sql
-- Each team gets its own warehouse
CREATE WAREHOUSE etl_wh        WITH WAREHOUSE_SIZE = 'MEDIUM' AUTO_SUSPEND = 60;
CREATE WAREHOUSE analytics_wh   WITH WAREHOUSE_SIZE = 'SMALL'  AUTO_SUSPEND = 300;
CREATE WAREHOUSE data_science_wh WITH WAREHOUSE_SIZE = 'XLARGE' AUTO_SUSPEND = 120;

-- All three warehouses read the same tables simultaneously
-- No contention, no interference, independent scaling
USE WAREHOUSE etl_wh;
INSERT INTO sales_fact SELECT * FROM staging.raw_sales;

USE WAREHOUSE analytics_wh;
SELECT region, SUM(revenue) FROM sales_fact GROUP BY region;

USE WAREHOUSE data_science_wh;
SELECT * FROM sales_fact WHERE category = 'electronics';  -- feeds ML pipeline
```

Each warehouse is billed independently. When Data Science is done, their warehouse auto-suspends and stops incurring cost.

---

## Common Interview Questions

### Q1: Describe Snowflake's architecture. How does it differ from shared-nothing and shared-disk?

**Answer:** Snowflake uses a multi-cluster shared data architecture with three independent layers: storage (cloud object storage), compute (virtual warehouses), and cloud services (metadata, optimization, security). Unlike shared-nothing architectures where each node owns a data partition (requiring reshuffling to scale), Snowflake decouples storage from compute — all warehouses access a shared, centralized data store. Unlike shared-disk architectures, each warehouse is an independent MPP cluster with no resource contention against other warehouses. This allows independent scaling of storage, compute power, and concurrency.

### Q2: What does the cloud services layer do, and does it cost anything?

**Answer:** The cloud services layer handles authentication, access control, metadata management, query parsing and optimization, transaction management, and result caching. It runs continuously and is managed by Snowflake. There is no charge unless cloud services consumption exceeds 10% of the daily total warehouse credit consumption, in which case only the excess is billed.

### Q3: How does Snowflake handle ACID transactions given its immutable storage model?

**Answer:** Snowflake uses snapshot isolation. When a transaction modifies data, it does not alter existing micro-partitions. Instead, new micro-partitions are created with the updated data. Concurrent readers continue to see the original micro-partitions (their consistent snapshot) until the writing transaction commits. At commit, table metadata is atomically updated to point to the new set of micro-partitions. This approach eliminates read-write contention and traditional row-level locking.

### Q4: Can multiple teams query the same data at the same time without interference?

**Answer:** Yes. Because storage is decoupled from compute, multiple virtual warehouses can read the same tables simultaneously. Each warehouse is an independent compute cluster — one warehouse's workload has zero impact on another's performance. This is a key advantage of the multi-cluster shared data architecture.

### Q5: What is partition pruning and how does metadata enable it?

**Answer:** Partition pruning is Snowflake's mechanism for skipping micro-partitions that cannot contain data relevant to a query's filter predicates. The cloud services layer maintains min/max values, distinct counts, and null counts for every column in every micro-partition. When a query includes a WHERE clause, Snowflake consults this metadata to eliminate micro-partitions whose value ranges do not overlap with the predicate, dramatically reducing the amount of data scanned.

### Q6: What is the result cache in Snowflake?

**Answer:** The result cache is maintained in the cloud services layer. When a query is executed, its result is cached for 24 hours. If the exact same query is submitted again and the underlying data has not changed, Snowflake returns the cached result instantly — no warehouse needs to be running, and no credits are consumed. The result cache is per-user by default but can be shared across users with the same role.

---

## Tips

- **Always lead with the three layers** when describing Snowflake architecture in an interview. This shows you understand the fundamental design.
- **Emphasize decoupling** — the ability to scale storage, compute, and concurrency independently is the primary differentiator.
- **Know the cost model** — storage is billed by TB/month, compute is billed by credit-seconds, and cloud services is free up to 10% of compute spend.
- **Understand immutability** — it is the foundation for Time Travel, Fail-Safe, zero-copy cloning, and Snowflake's approach to ACID transactions.
- **Be prepared to compare** Snowflake to Redshift (shared-nothing), BigQuery (serverless), and Databricks (lakehouse) — interviewers frequently ask for architectural comparisons.
- **Result cache vs. warehouse cache** — know the difference. Result cache lives in cloud services (free, 24-hour TTL, exact query match). Warehouse cache (local disk cache) lives on the warehouse's SSD and is lost when the warehouse suspends.
