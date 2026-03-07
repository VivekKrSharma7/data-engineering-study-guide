# Streams & Tasks (Change Data Capture)

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Streams Overview](#streams-overview)
2. [Types of Streams](#types-of-streams)
3. [Stream Metadata Columns](#stream-metadata-columns)
4. [Stream Offset and Staleness](#stream-offset-and-staleness)
5. [Consuming Streams](#consuming-streams)
6. [Streams on Views, External Tables, and Shared Tables](#streams-on-views-external-tables-and-shared-tables)
7. [Tasks Overview](#tasks-overview)
8. [Task Trees (DAGs)](#task-trees-dags)
9. [Task Scheduling](#task-scheduling)
10. [Serverless Tasks vs Warehouse Tasks](#serverless-tasks-vs-warehouse-tasks)
11. [Task Management and Monitoring](#task-management-and-monitoring)
12. [Error Handling in Tasks](#error-handling-in-tasks)
13. [Combining Streams and Tasks for CDC Pipelines](#combining-streams-and-tasks-for-cdc-pipelines)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## Streams Overview

A **stream** in Snowflake is a schema-level object that records data manipulation language (DML) changes made to a table — inserts, updates, and deletes. Streams enable **Change Data Capture (CDC)** by tracking the delta of changes between two points in time (transactional offsets).

Key characteristics:

- A stream does **not** store a copy of the data. It stores metadata about changes and points to the underlying table's change tracking system.
- Streams are **transactional** — consuming a stream (reading it within a DML transaction) advances the offset automatically upon successful commit.
- A single table can have **multiple streams**, each tracking changes independently from their own offset.

```sql
-- Create a standard stream on a table
CREATE OR REPLACE STREAM my_stream ON TABLE my_database.my_schema.orders;

-- View the stream contents (does NOT consume the stream)
SELECT * FROM my_stream;
```

### How Streams Work Internally

Snowflake leverages its internal versioning system (micro-partitions and metadata) to identify which rows have changed since the stream's current offset. When a stream is created, its offset is set to the current transactional version of the source table.

---

## Types of Streams

### 1. Standard Streams (Default)

Track all DML changes: **INSERT**, **UPDATE**, and **DELETE**. An update is represented as a pair of DELETE + INSERT rows.

```sql
CREATE OR REPLACE STREAM std_stream ON TABLE customers;
```

- Captures inserts, updates, and deletes.
- An UPDATE produces two rows in the stream: one with `METADATA$ACTION = 'DELETE'` (the old row) and one with `METADATA$ACTION = 'INSERT'` (the new row), both with `METADATA$ISUPDATE = TRUE`.

### 2. Append-Only Streams

Track **only INSERT** operations. Updates and deletes are **not** captured.

```sql
CREATE OR REPLACE STREAM append_stream ON TABLE events
  APPEND_ONLY = TRUE;
```

- Ideal for event/log tables where data is only appended and never modified.
- More efficient than standard streams when you only care about new rows.
- If a row is inserted and then deleted before the stream is consumed, the row does **not** appear in the stream.

### 3. Insert-Only Streams

Available **only on external tables**. Track inserts resulting from new files being loaded into the external stage.

```sql
CREATE OR REPLACE STREAM insert_stream ON EXTERNAL TABLE ext_sales
  INSERT_ONLY = TRUE;
```

- External tables only support insert-only streams.
- Detects when new files appear in the external stage location.

### Comparison Table

| Feature | Standard | Append-Only | Insert-Only |
|---|---|---|---|
| Supported on tables | Yes | Yes | No |
| Supported on external tables | No | No | Yes |
| Supported on views | Yes | Yes | No |
| Tracks INSERTs | Yes | Yes | Yes |
| Tracks UPDATEs | Yes | No | No |
| Tracks DELETEs | Yes | No | No |

---

## Stream Metadata Columns

Every stream exposes three metadata columns alongside the source table columns:

### METADATA$ACTION

- **`INSERT`** — The row was inserted (or is the "new" version of an updated row).
- **`DELETE`** — The row was deleted (or is the "old" version of an updated row).

### METADATA$ISUPDATE

- **`TRUE`** — The INSERT/DELETE pair is part of an UPDATE operation.
- **`FALSE`** — The change is a pure insert or pure delete.

### METADATA$ROW_ID

- A unique and immutable ID for each row in the source table.
- Useful for matching DELETE/INSERT pairs that belong to the same UPDATE.

```sql
-- Example: Viewing stream content with metadata
SELECT
    METADATA$ACTION     AS action,
    METADATA$ISUPDATE   AS is_update,
    METADATA$ROW_ID     AS row_id,
    order_id,
    customer_id,
    amount,
    status
FROM orders_stream;
```

**Sample output after an UPDATE on the `status` column:**

| action | is_update | row_id | order_id | customer_id | amount | status |
|--------|-----------|--------|----------|-------------|--------|--------|
| DELETE | TRUE | abc123 | 1001 | 50 | 250.00 | pending |
| INSERT | TRUE | abc123 | 1001 | 50 | 250.00 | shipped |

Notice the same `row_id` for both rows, confirming they represent the before/after of a single update.

---

## Stream Offset and Staleness

### Stream Offset

The **offset** is the transactional point-in-time marker that tells the stream where it last "read up to." When a stream is consumed inside a DML transaction and that transaction commits, the offset advances.

- You can check the current offset using `DESCRIBE STREAM` or `SHOW STREAMS`.
- The offset is **not** advanced by a simple `SELECT` on the stream — only by DML that reads from the stream within a committed transaction.

```sql
-- Check stream details including offset
SHOW STREAMS LIKE 'my_stream' IN SCHEMA my_schema;
```

### Stream Staleness

A stream becomes **stale** when the change tracking data for the source table no longer covers the stream's offset. This happens when the retention period (controlled by `DATA_RETENTION_TIME_IN_DAYS`) is exceeded without consuming the stream.

```sql
-- Check if a stream is stale
SELECT SYSTEM$STREAM_HAS_DATA('my_stream');
-- Returns TRUE if there is unconsumed data, FALSE otherwise.
-- A stale stream will throw an error when queried.
```

**Key points on staleness:**

- Default `DATA_RETENTION_TIME_IN_DAYS` is 1 day (up to 90 days on Enterprise Edition).
- The staleness period for a stream extends up to 14 days **beyond** the table's data retention period (with an offset-based extended window).
- Once a stream is stale, it **cannot be recovered** — you must recreate it.
- To prevent staleness, consume your streams regularly or increase the table's retention period.

```sql
-- Extend the data retention to help prevent staleness
ALTER TABLE orders SET DATA_RETENTION_TIME_IN_DAYS = 14;
```

---

## Consuming Streams

A stream is "consumed" when it is read within a **DML statement** (INSERT, MERGE, UPDATE, DELETE, etc.) inside a **successful transaction**.

```sql
-- Consuming a stream via INSERT ... SELECT
BEGIN;

INSERT INTO orders_history (order_id, customer_id, amount, status, change_action, change_time)
SELECT
    order_id,
    customer_id,
    amount,
    status,
    METADATA$ACTION,
    CURRENT_TIMESTAMP()
FROM orders_stream;

COMMIT;
-- After COMMIT, the stream offset advances. Querying the stream now returns empty results
-- (until new changes arrive).
```

### Important Consumption Rules

1. **Only DML within a transaction** advances the offset. A bare `SELECT` does not.
2. If the transaction **rolls back**, the offset does **not** advance.
3. Multiple statements in the same transaction can reference the same stream and will all see the same snapshot of changes.
4. If **no data** exists in the stream (`SYSTEM$STREAM_HAS_DATA` returns FALSE), the DML still succeeds (processes zero rows) and the offset still advances.

### Using MERGE with Streams (Most Common Pattern)

```sql
MERGE INTO customers_dim AS target
USING customers_stream AS source
ON target.customer_id = source.customer_id
WHEN MATCHED AND source.METADATA$ACTION = 'DELETE' AND source.METADATA$ISUPDATE = FALSE
    THEN DELETE
WHEN MATCHED AND source.METADATA$ACTION = 'INSERT' AND source.METADATA$ISUPDATE = TRUE
    THEN UPDATE SET
        target.name = source.name,
        target.email = source.email,
        target.updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED AND source.METADATA$ACTION = 'INSERT'
    THEN INSERT (customer_id, name, email, created_at, updated_at)
    VALUES (source.customer_id, source.name, source.email, CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
```

---

## Streams on Views, External Tables, and Shared Tables

### Streams on Views

You can create streams on **views** (including secure views), provided that the underlying base tables have change tracking enabled.

```sql
-- Enable change tracking on the base table first
ALTER TABLE raw_orders SET CHANGE_TRACKING = TRUE;

-- Create a view
CREATE OR REPLACE VIEW v_active_orders AS
SELECT * FROM raw_orders WHERE status != 'cancelled';

-- Create a stream on the view
CREATE OR REPLACE STREAM active_orders_stream ON VIEW v_active_orders;
```

- The view must be a **non-materialized** view.
- Only standard and append-only stream types are supported on views.
- All base tables referenced by the view must have `CHANGE_TRACKING = TRUE`.

### Streams on External Tables

External tables support only **insert-only** streams. These detect new files added to the external stage.

```sql
CREATE OR REPLACE STREAM ext_stream ON EXTERNAL TABLE my_ext_table
  INSERT_ONLY = TRUE;
```

- Useful for triggering pipelines when new data lands in cloud storage (S3, GCS, Azure Blob).
- Often combined with tasks for automated ingestion.

### Streams on Shared Tables (Data Sharing)

- Streams **cannot** be created directly on shared (imported) tables from a data share.
- Workaround: Create a **view** on the shared table, enable change tracking on the underlying shared database (if the provider allows), or replicate the data locally first.

---

## Tasks Overview

A **task** is a schema-level object that defines a schedule and a SQL statement (or stored procedure call) to execute. Tasks automate recurring SQL workloads.

```sql
-- Create a basic task
CREATE OR REPLACE TASK load_orders_task
  WAREHOUSE = compute_wh
  SCHEDULE = '5 MINUTE'
AS
  INSERT INTO orders_archive
  SELECT * FROM orders_stream
  WHERE SYSTEM$STREAM_HAS_DATA('orders_stream');
```

### Key Properties

| Property | Description |
|---|---|
| `WAREHOUSE` | The virtual warehouse used to execute the task |
| `SCHEDULE` | Execution interval or CRON expression (root tasks only) |
| `AFTER` | Specifies parent task(s) in a DAG (child tasks only) |
| `WHEN` | Boolean condition — task SQL runs only if this evaluates to TRUE |
| `ERROR_INTEGRATION` | Notification integration for error alerts |
| `SUSPEND_TASK_AFTER_NUM_FAILURES` | Auto-suspend after N consecutive failures |

### The WHEN Condition

The `WHEN` clause is evaluated **without** consuming warehouse credits (it runs in the cloud services layer). Commonly used with `SYSTEM$STREAM_HAS_DATA()`.

```sql
CREATE OR REPLACE TASK process_changes_task
  WAREHOUSE = etl_wh
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS
  MERGE INTO target_table t
  USING my_stream s
  ON t.id = s.id
  WHEN MATCHED THEN UPDATE SET t.value = s.value
  WHEN NOT MATCHED THEN INSERT (id, value) VALUES (s.id, s.value);
```

If `SYSTEM$STREAM_HAS_DATA` returns `FALSE`, the task is **skipped** (no warehouse is resumed, no credits consumed).

---

## Task Trees (DAGs)

Tasks can be organized into **Directed Acyclic Graphs (DAGs)** where a root task triggers a chain of dependent child tasks.

```
         root_task (scheduled)
           /        \
     child_task_1   child_task_2
          |
     child_task_3
```

### Creating a Task DAG

```sql
-- Root task (has SCHEDULE)
CREATE OR REPLACE TASK root_task
  WAREHOUSE = etl_wh
  SCHEDULE = 'USING CRON 0 */2 * * * America/New_York'
AS
  CALL extract_raw_data();

-- Child task 1 (runs AFTER root_task)
CREATE OR REPLACE TASK transform_task_1
  WAREHOUSE = etl_wh
  AFTER root_task
AS
  CALL transform_customers();

-- Child task 2 (also runs AFTER root_task, in parallel with child_task_1)
CREATE OR REPLACE TASK transform_task_2
  WAREHOUSE = etl_wh
  AFTER root_task
AS
  CALL transform_orders();

-- Grandchild task (runs after transform_task_1 completes)
CREATE OR REPLACE TASK load_task
  WAREHOUSE = etl_wh
  AFTER transform_task_1
AS
  CALL load_to_presentation();
```

### DAG Rules

- Only the **root task** has a `SCHEDULE`. Child tasks use `AFTER`.
- A child task can depend on **multiple parent tasks** (runs when ALL parents complete).
- A DAG can have up to **1,000 tasks** (including the root).
- Child tasks inherit the root task's schedule context but can use different warehouses.

### Enabling/Resuming a DAG

```sql
-- Enable all tasks in the DAG at once (starting from the root)
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('root_task');

-- Or manually resume each task (must resume children first, then root)
ALTER TASK load_task RESUME;
ALTER TASK transform_task_1 RESUME;
ALTER TASK transform_task_2 RESUME;
ALTER TASK root_task RESUME;
```

`SYSTEM$TASK_DEPENDENTS_ENABLE` is a convenience function that recursively resumes all tasks in the DAG.

---

## Task Scheduling

### CRON-Based Scheduling

Uses standard CRON syntax with a required timezone.

```sql
-- Every day at 6:00 AM UTC
SCHEDULE = 'USING CRON 0 6 * * * UTC'

-- Every Monday at 9:00 AM Eastern
SCHEDULE = 'USING CRON 0 9 * * 1 America/New_York'

-- Every 15 minutes (CRON way)
SCHEDULE = 'USING CRON */15 * * * * UTC'

-- First day of every month at midnight
SCHEDULE = 'USING CRON 0 0 1 * * UTC'
```

**CRON format:** `minute hour day_of_month month day_of_week timezone`

### Interval-Based Scheduling

Specified as a number of minutes. The interval begins from the time the task is resumed.

```sql
-- Run every 5 minutes
SCHEDULE = '5 MINUTE'

-- Run every 60 minutes
SCHEDULE = '60 MINUTE'
```

**Key difference:** Interval-based scheduling starts timing from when the task was last resumed (or last executed), while CRON runs at specific clock times regardless of when the task was enabled.

---

## Serverless Tasks vs Warehouse Tasks

### Warehouse Tasks

- Use a specified virtual warehouse (`WAREHOUSE = my_wh`).
- You manage warehouse sizing, auto-suspend, concurrency, etc.
- Cost is based on warehouse credit consumption.

```sql
CREATE OR REPLACE TASK wh_task
  WAREHOUSE = etl_wh
  SCHEDULE = '10 MINUTE'
AS
  INSERT INTO target SELECT * FROM source_stream;
```

### Serverless Tasks

- Snowflake manages the compute resources automatically.
- Specified with `USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE` instead of `WAREHOUSE`.
- Snowflake dynamically adjusts compute size based on workload.
- Billed using **serverless credit rates** (which differ from standard warehouse rates).

```sql
CREATE OR REPLACE TASK serverless_task
  USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
  SCHEDULE = '5 MINUTE'
AS
  CALL process_incremental_data();
```

### When to Use Which

| Consideration | Warehouse Tasks | Serverless Tasks |
|---|---|---|
| Resource management | Manual | Automatic |
| Cost predictability | Higher (fixed warehouse) | Variable |
| Ideal for | Heavy, predictable workloads | Variable, lightweight workloads |
| Startup latency | May have warehouse resume time | Managed by Snowflake |
| Right-sizing | Manual tuning | Auto-scaled |

---

## Task Management and Monitoring

### Viewing Task History

```sql
-- Query task history for the last 24 hours
SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('DAY', -1, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 100
))
ORDER BY SCHEDULED_TIME DESC;

-- Task history from ACCOUNT_USAGE (up to 365 days, with latency)
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE SCHEDULED_TIME > DATEADD('DAY', -7, CURRENT_TIMESTAMP())
ORDER BY SCHEDULED_TIME DESC;
```

### Key Task States

| State | Meaning |
|---|---|
| `SCHEDULED` | Task is queued to run |
| `EXECUTING` | Task is currently running |
| `SUCCEEDED` | Task completed successfully |
| `FAILED` | Task encountered an error |
| `SKIPPED` | Task was skipped (WHEN condition was FALSE) |
| `CANCELLED` | Task was manually cancelled |

### Common Management Commands

```sql
-- Suspend a task
ALTER TASK my_task SUSPEND;

-- Resume a task
ALTER TASK my_task RESUME;

-- Show all tasks
SHOW TASKS IN SCHEMA my_schema;

-- Describe a task
DESCRIBE TASK my_task;

-- Drop a task
DROP TASK my_task;

-- Modify task schedule
ALTER TASK my_task SET SCHEDULE = '10 MINUTE';

-- Modify task SQL
ALTER TASK my_task MODIFY AS
  CALL new_procedure();
```

---

## Error Handling in Tasks

### SUSPEND_TASK_AFTER_NUM_FAILURES

Automatically suspends a task after a specified number of consecutive failures, preventing runaway errors.

```sql
CREATE OR REPLACE TASK my_task
  WAREHOUSE = etl_wh
  SCHEDULE = '10 MINUTE'
  SUSPEND_TASK_AFTER_NUM_FAILURES = 3
AS
  CALL my_etl_procedure();
```

### Error Notification Integration

Tasks can send error notifications to cloud messaging services (e.g., SNS, Azure Event Grid) via notification integrations.

```sql
-- Create a notification integration
CREATE OR REPLACE NOTIFICATION INTEGRATION task_error_notify
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = AWS_SNS
  ENABLED = TRUE
  AWS_SNS_TOPIC_ARN = 'arn:aws:sns:us-east-1:123456789:task-errors'
  AWS_SNS_ROLE_ARN = 'arn:aws:iam::123456789:role/snowflake-sns-role';

-- Assign to a task
ALTER TASK my_task SET ERROR_INTEGRATION = task_error_notify;
```

### Error Handling Within Task SQL (Stored Procedures)

```sql
CREATE OR REPLACE PROCEDURE safe_etl_process()
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    BEGIN
        INSERT INTO target_table
        SELECT * FROM source_stream;
        RETURN 'SUCCESS: ' || SQLROWCOUNT || ' rows processed';
    EXCEPTION
        WHEN OTHER THEN
            INSERT INTO etl_error_log (error_time, error_message, error_code)
            VALUES (CURRENT_TIMESTAMP(), SQLERRM, SQLCODE);
            RETURN 'FAILED: ' || SQLERRM;
    END;
END;
```

---

## Combining Streams and Tasks for CDC Pipelines

The most powerful pattern in Snowflake CDC is combining streams (what changed) with tasks (when to process). This creates a near-real-time, automated pipeline.

### End-to-End CDC Pipeline Example

```sql
-- Step 1: Source table
CREATE OR REPLACE TABLE raw_customers (
    customer_id INT,
    name        VARCHAR,
    email       VARCHAR,
    region      VARCHAR,
    updated_at  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Step 2: Target dimension table (SCD Type 1 for simplicity)
CREATE OR REPLACE TABLE dim_customers (
    customer_id INT PRIMARY KEY,
    name        VARCHAR,
    email       VARCHAR,
    region      VARCHAR,
    loaded_at   TIMESTAMP_NTZ,
    updated_at  TIMESTAMP_NTZ
);

-- Step 3: Create a stream on the source
CREATE OR REPLACE STREAM raw_customers_stream ON TABLE raw_customers;

-- Step 4: Create a task that processes the stream
CREATE OR REPLACE TASK sync_customers_task
  WAREHOUSE = etl_wh
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('raw_customers_stream')
AS
  MERGE INTO dim_customers AS tgt
  USING (
      SELECT customer_id, name, email, region
      FROM raw_customers_stream
      WHERE METADATA$ACTION = 'INSERT'
  ) AS src
  ON tgt.customer_id = src.customer_id
  WHEN MATCHED THEN
      UPDATE SET
          tgt.name       = src.name,
          tgt.email      = src.email,
          tgt.region     = src.region,
          tgt.updated_at = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN
      INSERT (customer_id, name, email, region, loaded_at, updated_at)
      VALUES (src.customer_id, src.name, src.email, src.region,
              CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());

-- Step 5: Resume the task
ALTER TASK sync_customers_task RESUME;
```

### Multi-Stage CDC Pipeline (DAG)

```sql
-- Root: Extract from stream
CREATE OR REPLACE TASK extract_task
  WAREHOUSE = etl_wh
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('source_stream')
AS
  INSERT INTO staging_table
  SELECT *, METADATA$ACTION, METADATA$ISUPDATE, CURRENT_TIMESTAMP() AS captured_at
  FROM source_stream;

-- Child: Transform
CREATE OR REPLACE TASK transform_task
  WAREHOUSE = etl_wh
  AFTER extract_task
AS
  CALL apply_business_rules();

-- Grandchild: Load to final
CREATE OR REPLACE TASK load_task
  WAREHOUSE = etl_wh
  AFTER transform_task
AS
  CALL upsert_to_dim_tables();

-- Enable the full DAG
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('extract_task');
```

---

## Common Interview Questions

### Q1: What is a stream in Snowflake and how does it work?

**A:** A stream is a change tracking object that records DML changes (inserts, updates, deletes) made to a table. It does not store a copy of the data — it uses Snowflake's internal versioning to identify rows that changed between the stream's current offset and the table's current version. When consumed in a DML transaction, the offset advances automatically.

### Q2: What happens when a stream is consumed? How does the offset advance?

**A:** The offset advances only when the stream is read within a DML statement (INSERT, MERGE, etc.) inside a transaction that successfully commits. A plain SELECT does not advance the offset. If the transaction rolls back, the offset remains unchanged and the changes are still available.

### Q3: What is stream staleness and how do you prevent it?

**A:** A stream becomes stale when its offset falls outside the table's data retention window, meaning the historical change data is no longer available. Once stale, the stream cannot be queried and must be recreated. Prevention strategies include: consuming streams frequently, increasing `DATA_RETENTION_TIME_IN_DAYS` on the source table, and monitoring stream health with alerts.

### Q4: Explain the difference between standard, append-only, and insert-only streams.

**A:** Standard streams capture all DML (INSERT, UPDATE, DELETE). Append-only streams capture only INSERTs and are ideal for event/log tables. Insert-only streams are exclusive to external tables and detect new files in external stages. Updates are represented in standard streams as a DELETE + INSERT pair with `METADATA$ISUPDATE = TRUE`.

### Q5: What is a task DAG and how do you enable it?

**A:** A task DAG (Directed Acyclic Graph) is a tree of tasks where a scheduled root task triggers dependent child tasks. Only the root has a SCHEDULE; children use the AFTER clause. You enable the entire DAG with `SYSTEM$TASK_DEPENDENTS_ENABLE('root_task')`, which recursively resumes all tasks in the tree.

### Q6: How does the WHEN clause in a task work, and why is it important?

**A:** The WHEN clause defines a boolean condition evaluated in the cloud services layer (no warehouse credits consumed). If it evaluates to FALSE, the task is skipped entirely. The most common usage is `WHEN SYSTEM$STREAM_HAS_DATA('stream_name')`, which prevents the task from spinning up a warehouse when there are no changes to process, saving costs.

### Q7: When would you choose serverless tasks over warehouse-based tasks?

**A:** Serverless tasks are ideal when workloads are variable, lightweight, or unpredictable. Snowflake auto-scales the compute, eliminating the need for warehouse sizing. Warehouse tasks are better for heavy, predictable workloads where you want cost predictability and control over compute resources.

### Q8: Can you create a stream on a view? What are the requirements?

**A:** Yes, you can create a stream on a non-materialized view. The requirement is that all base tables referenced by the view must have `CHANGE_TRACKING = TRUE` enabled. Standard and append-only stream types are supported on views.

### Q9: Design a CDC pipeline that captures changes from a source table and maintains a slowly changing dimension.

**A:** Create a stream on the source table to capture changes. Create a task with a WHEN condition checking `SYSTEM$STREAM_HAS_DATA`. The task body uses a MERGE statement that: (1) handles DELETEs from the stream to expire records, (2) handles INSERT+ISUPDATE to update existing dimension records, and (3) handles new INSERTs to add new dimension records. For SCD Type 2, insert new rows with current effective dates and update old rows' expiry dates.

### Q10: What happens if two tasks read from the same stream simultaneously?

**A:** Only one transaction can consume a stream at a time. Snowflake uses locking to ensure that the first committed transaction advances the offset. The second transaction will either see the updated offset (fewer or no changes) or may need to retry. This is why each consumer pipeline should generally have its own dedicated stream.

---

## Tips

1. **One stream per consumer.** If multiple processes need to consume changes from the same table, create separate streams for each consumer. Each stream maintains its own independent offset.

2. **Always use WHEN with SYSTEM$STREAM_HAS_DATA.** This prevents unnecessary warehouse startups and saves significant costs in production environments.

3. **Monitor for staleness.** Set up alerts on stream staleness using `STALE_AFTER` from `SHOW STREAMS`. Stale streams are unrecoverable and require recreation plus a full data reconciliation.

4. **Use MERGE for idempotent CDC.** The MERGE pattern with streams handles inserts, updates, and deletes in a single atomic statement, making your pipeline robust and simple.

5. **Start tasks from leaf to root.** When manually resuming tasks in a DAG, resume child tasks first, then the root. When suspending, do the opposite — suspend the root first.

6. **Test with EXECUTE TASK.** You can manually trigger a task for testing: `EXECUTE TASK my_task`. This runs the task immediately regardless of schedule or WHEN condition.

7. **Keep task SQL lightweight.** Offload complex logic to stored procedures that the task calls. This makes debugging and updating easier.

8. **Set SUSPEND_TASK_AFTER_NUM_FAILURES.** Always configure this to prevent a broken task from running indefinitely and consuming credits while failing repeatedly.
