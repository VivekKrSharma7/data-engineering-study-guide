# Snowpipe & Continuous Data Loading

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Snowpipe Architecture](#snowpipe-architecture)
2. [Auto-Ingest with Cloud Event Notifications](#auto-ingest-with-cloud-event-notifications)
3. [REST API-Based Snowpipe](#rest-api-based-snowpipe)
4. [Snowpipe Streaming](#snowpipe-streaming)
5. [Pipe Definition and Management](#pipe-definition-and-management)
6. [Monitoring with PIPE_USAGE_HISTORY](#monitoring-with-pipe_usage_history)
7. [Monitoring Pipe Status with SYSTEM$PIPE_STATUS](#monitoring-pipe-status-with-systempipe_status)
8. [Snowpipe Costs](#snowpipe-costs)
9. [Error Handling](#error-handling)
10. [Snowpipe vs Scheduled COPY INTO](#snowpipe-vs-scheduled-copy-into)
11. [Best Practices](#best-practices)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## Snowpipe Architecture

Snowpipe is Snowflake's continuous, serverless data ingestion service. It loads data within minutes of files arriving in a stage, without requiring a user-managed virtual warehouse.

### How It Works

1. **File Notification**: A new file lands in a cloud storage location (S3, Azure Blob, GCS).
2. **Event Trigger**: A cloud event notification (or REST API call) tells Snowpipe about the new file.
3. **Queue**: Snowpipe places the file into an internal ingestion queue.
4. **Serverless Compute**: Snowflake provisions serverless compute resources to load the file.
5. **Load Execution**: The data is loaded into the target table using the COPY statement defined in the pipe.
6. **Metadata Update**: Load metadata is recorded, preventing duplicate loads.

### Key Architectural Points

- **Serverless**: No virtual warehouse is needed. Snowflake manages the compute automatically.
- **Near Real-Time**: Typical latency is 1-2 minutes from file arrival to data availability.
- **File-Level Tracking**: Each file is tracked individually; Snowpipe will not re-load files it has already processed (within 14 days).
- **Queue-Based**: Files are queued and processed in order. Under heavy load, Snowflake auto-scales the serverless resources.
- **Micro-Batch**: Snowpipe loads files in micro-batches, accumulating files briefly before loading to optimize compute usage.

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ Cloud Storage │────>│ Event Notification│────>│  Snowpipe Queue │
│  (S3/Azure/  │     │  (SQS/Event Grid/ │     │                 │
│   GCS)       │     │   Pub/Sub)        │     │                 │
└──────────────┘     └──────────────────┘     └────────┬────────┘
                                                        │
                                                        v
                                              ┌─────────────────┐
                                              │ Serverless       │
                                              │ Compute (Load)   │
                                              └────────┬────────┘
                                                        │
                                                        v
                                              ┌─────────────────┐
                                              │  Target Table    │
                                              └─────────────────┘
```

---

## Auto-Ingest with Cloud Event Notifications

Auto-ingest is the most common Snowpipe configuration. It uses cloud-native event notifications to detect new files and trigger loading automatically.

### AWS S3 with SQS

**Step 1**: Create a pipe with AUTO_INGEST enabled.

```sql
CREATE OR REPLACE PIPE my_s3_pipe
  AUTO_INGEST = TRUE
  AS
  COPY INTO my_table
  FROM @my_s3_stage
  FILE_FORMAT = (TYPE = 'PARQUET')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

**Step 2**: Retrieve the SQS queue ARN from the pipe.

```sql
SHOW PIPES LIKE 'my_s3_pipe';
-- Note the notification_channel column -- this is the SQS queue ARN
```

**Step 3**: Configure S3 event notifications to send to the Snowpipe SQS queue.

- Go to the S3 bucket > Properties > Event Notifications
- Create a new notification for `s3:ObjectCreated:*` events
- Set the destination to the SQS queue ARN from Step 2

### Azure Blob Storage with Event Grid

**Step 1**: Create the pipe.

```sql
CREATE OR REPLACE PIPE my_azure_pipe
  AUTO_INGEST = TRUE
  INTEGRATION = 'my_azure_notification_integration'
  AS
  COPY INTO my_table
  FROM @my_azure_stage
  FILE_FORMAT = my_csv_format;
```

**Step 2**: Create a notification integration.

```sql
CREATE OR REPLACE NOTIFICATION INTEGRATION my_azure_notification_integration
  ENABLED = TRUE
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = AZURE_EVENT_GRID
  DIRECTION = INBOUND
  AZURE_STORAGE_QUEUE_PRIMARY_URI = 'https://<account>.queue.core.windows.net/<queue>'
  AZURE_TENANT_ID = '<tenant_id>';
```

### GCS with Pub/Sub

**Step 1**: Create a notification integration.

```sql
CREATE OR REPLACE NOTIFICATION INTEGRATION my_gcs_notification_integration
  ENABLED = TRUE
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = GCP_PUBSUB
  DIRECTION = INBOUND
  GCP_PUBSUB_SUBSCRIPTION_NAME = 'projects/<project>/subscriptions/<subscription>';
```

**Step 2**: Create the pipe.

```sql
CREATE OR REPLACE PIPE my_gcs_pipe
  AUTO_INGEST = TRUE
  INTEGRATION = 'my_gcs_notification_integration'
  AS
  COPY INTO my_table
  FROM @my_gcs_stage
  FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = TRUE);
```

---

## REST API-Based Snowpipe

For scenarios where cloud event notifications are not feasible, you can trigger Snowpipe programmatically using the Snowpipe REST API (also called the insertFiles API).

### How It Works

1. Your application detects new files (or generates them).
2. Your application calls the Snowpipe REST API with the list of file names.
3. Snowpipe queues and loads the files.

### Pipe Definition (no AUTO_INGEST)

```sql
CREATE OR REPLACE PIPE my_rest_pipe
  AS
  COPY INTO my_table
  FROM @my_stage
  FILE_FORMAT = my_csv_format;
```

### REST API Call (Python Example)

```python
from snowflake.ingest import SimpleIngestManager
from snowflake.ingest import StagedFile

# Configure the ingest manager
ingest_manager = SimpleIngestManager(
    account='my_account',
    host='my_account.snowflakecomputing.com',
    user='my_user',
    pipe='my_db.my_schema.my_rest_pipe',
    private_key=private_key  # RSA key pair authentication
)

# Submit files for ingestion
staged_files = [
    StagedFile('path/to/file1.csv', None),
    StagedFile('path/to/file2.csv', None),
]

response = ingest_manager.ingest_files(staged_files)
print(response)

# Check ingestion history
history = ingest_manager.get_history()
print(history)
```

### Key Points About REST API Snowpipe

- Requires **key pair authentication** (not password-based).
- The pipe must be created WITHOUT `AUTO_INGEST = TRUE`.
- You are responsible for tracking which files need to be submitted.
- Useful when you have custom orchestration or non-standard event sources.

---

## Snowpipe Streaming

Snowpipe Streaming is a newer capability that allows row-level data ingestion via the Snowflake Ingest SDK, bypassing the need for staged files entirely.

### Key Characteristics

- **No Staging Required**: Data is sent directly as rows via the SDK -- no files in cloud storage.
- **Lower Latency**: Sub-second latency compared to Snowpipe's 1-2 minute latency.
- **SDK-Based**: Uses the Snowflake Ingest SDK (Java-based).
- **Serverless**: Compute is managed by Snowflake.
- **Exactly-Once Semantics**: Achieved via offset tokens for deduplication.

### Architecture

```
┌──────────────────┐     ┌─────────────────────┐     ┌─────────────────┐
│ Application /    │────>│ Snowflake Ingest SDK │────>│  Target Table    │
│ Kafka / Stream   │     │ (Snowpipe Streaming) │     │                 │
└──────────────────┘     └─────────────────────┘     └─────────────────┘
```

### Java SDK Example

```java
import net.snowflake.ingest.streaming.*;

// Create a client
SnowflakeStreamingIngestClientFactory.Builder builder =
    SnowflakeStreamingIngestClientFactory.builder("MY_CLIENT");
builder.setProperties(props);  // Connection properties
SnowflakeStreamingIngestClient client = builder.build();

// Open a channel to a target table
OpenChannelRequest request = OpenChannelRequest.builder("MY_CHANNEL")
    .setDBName("MY_DB")
    .setSchemaName("MY_SCHEMA")
    .setTableName("MY_TABLE")
    .setOnErrorOption(OpenChannelRequest.OnErrorOption.CONTINUE)
    .build();

SnowflakeStreamingIngestChannel channel = client.openChannel(request);

// Insert rows
Map<String, Object> row = new HashMap<>();
row.put("col1", "value1");
row.put("col2", 42);

InsertValidationResponse response = channel.insertRow(row, "offset_token_1");

// Close when done
channel.close().get();
client.close();
```

### Snowpipe Streaming with Kafka

The **Snowflake Kafka Connector** (version 2.0+) uses Snowpipe Streaming under the hood for low-latency ingestion from Apache Kafka topics.

```properties
# Kafka connector configuration for Snowpipe Streaming
snowflake.ingestion.method=SNOWPIPE_STREAMING
snowflake.enable.schematization=true
```

### Snowpipe Streaming vs Classic Snowpipe

| Feature | Classic Snowpipe | Snowpipe Streaming |
|---------|-----------------|-------------------|
| Input | Files in stages | Rows via SDK |
| Latency | ~1-2 minutes | Sub-second |
| Compute | Serverless | Serverless |
| Use Case | File-based ingestion | Real-time streaming |
| Deduplication | File-level (14 days) | Offset-token based |
| SDK | REST API / Auto-ingest | Java Ingest SDK |

---

## Pipe Definition and Management

### Creating Pipes

```sql
-- Basic pipe
CREATE OR REPLACE PIPE my_pipe
  AUTO_INGEST = TRUE
  COMMENT = 'Loads daily sales data from S3'
  AS
  COPY INTO sales
  FROM @my_s3_stage/sales/
  FILE_FORMAT = my_csv_format
  ON_ERROR = 'SKIP_FILE';
```

### Pipe with Transformations

```sql
CREATE OR REPLACE PIPE my_transform_pipe
  AUTO_INGEST = TRUE
  AS
  COPY INTO sales (sale_id, amount, sale_date, source_file, loaded_at)
  FROM (
    SELECT
      $1::INTEGER,
      $2::DECIMAL(12,2),
      TO_DATE($3, 'YYYY-MM-DD'),
      METADATA$FILENAME,
      CURRENT_TIMESTAMP()
    FROM @my_s3_stage/sales/
  )
  FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

### Managing Pipes

```sql
-- List pipes
SHOW PIPES;
SHOW PIPES LIKE 'sales%';
SHOW PIPES IN SCHEMA my_db.my_schema;

-- Describe a pipe
DESCRIBE PIPE my_pipe;

-- Pause a pipe (stop processing new files)
ALTER PIPE my_pipe SET PIPE_EXECUTION_PAUSED = TRUE;

-- Resume a pipe
ALTER PIPE my_pipe SET PIPE_EXECUTION_PAUSED = FALSE;

-- Refresh a pipe (manually re-scan stage for missed files within 7 days)
ALTER PIPE my_pipe REFRESH;

-- Refresh for a specific prefix and time range
ALTER PIPE my_pipe REFRESH
  PREFIX = 'sales/2026/03/'
  MODIFIED_AFTER = '2026-03-01T00:00:00Z';

-- Drop a pipe
DROP PIPE my_pipe;
```

### Important Notes on ALTER PIPE REFRESH

- Used to recover from missed notifications or to backfill.
- Only processes files that arrived in the last **7 days**.
- Does not re-load files already tracked in load metadata (14-day window).
- Should be used sparingly; not a replacement for proper event notification setup.

---

## Monitoring with PIPE_USAGE_HISTORY

The `PIPE_USAGE_HISTORY` function and view provide insights into Snowpipe activity and credit consumption.

### PIPE_USAGE_HISTORY Table Function (Information Schema)

```sql
-- Recent pipe usage for the last 24 hours
SELECT
  PIPE_NAME,
  START_TIME,
  END_TIME,
  CREDITS_USED,
  BYTES_INSERTED,
  FILES_INSERTED
FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
  DATE_RANGE_START => DATEADD(HOUR, -24, CURRENT_TIMESTAMP()),
  DATE_RANGE_END => CURRENT_TIMESTAMP()
))
ORDER BY START_TIME DESC;

-- Usage for a specific pipe
SELECT *
FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
  DATE_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP()),
  PIPE_NAME => 'MY_DB.MY_SCHEMA.MY_PIPE'
))
ORDER BY START_TIME DESC;
```

### PIPE_USAGE_HISTORY View (Account Usage)

```sql
-- Account-level Snowpipe usage (up to 365 days)
SELECT
  PIPE_NAME,
  DATE_TRUNC('DAY', START_TIME) AS usage_date,
  SUM(CREDITS_USED) AS total_credits,
  SUM(BYTES_INSERTED) AS total_bytes,
  SUM(FILES_INSERTED) AS total_files
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE START_TIME >= DATEADD(MONTH, -1, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 2 DESC, 3 DESC;
```

---

## Monitoring Pipe Status with SYSTEM$PIPE_STATUS

`SYSTEM$PIPE_STATUS` returns the current operational status of a pipe, including the number of files pending in the queue.

```sql
SELECT SYSTEM$PIPE_STATUS('my_db.my_schema.my_pipe');
```

### Sample Output

```json
{
  "executionState": "RUNNING",
  "pendingFileCount": 3,
  "notificationChannelName": "arn:aws:sqs:us-east-1:123456789:sf-snowpipe-...",
  "numOutstandingMessagesOnChannel": 5,
  "lastReceivedMessageTimestamp": "2026-03-07T10:15:30.123Z",
  "lastForwardedMessageTimestamp": "2026-03-07T10:15:28.456Z",
  "lastPulledFromChannelTimestamp": "2026-03-07T10:15:30.123Z"
}
```

### Key Fields

| Field | Description |
|-------|-------------|
| `executionState` | RUNNING, PAUSED, or STALLED |
| `pendingFileCount` | Number of files in the queue awaiting load |
| `notificationChannelName` | The cloud notification channel (e.g., SQS ARN) |
| `numOutstandingMessagesOnChannel` | Messages not yet processed from the notification channel |
| `lastReceivedMessageTimestamp` | When the last notification was received |
| `lastForwardedMessageTimestamp` | When the last file was forwarded for loading |

### Operational Monitoring Pattern

```sql
-- Create a task to periodically check pipe status
CREATE OR REPLACE TASK monitor_pipe_status
  WAREHOUSE = monitoring_wh
  SCHEDULE = 'USING CRON 0/15 * * * * UTC'  -- Every 15 minutes
AS
INSERT INTO pipe_status_log (pipe_name, status_json, checked_at)
SELECT
  'my_pipe',
  PARSE_JSON(SYSTEM$PIPE_STATUS('my_db.my_schema.my_pipe')),
  CURRENT_TIMESTAMP();
```

---

## Snowpipe Costs

Snowpipe uses **serverless compute credits**, which are billed differently from virtual warehouse credits.

### Cost Model

- **Per-second billing** for the serverless compute used to load files.
- **Overhead charge**: A small overhead of approximately **0.06 credits per 1000 files** for file notification management.
- **Serverless credit rate**: Serverless credits cost more per credit than standard warehouse credits (typically ~1.5x the warehouse credit rate, varies by edition and region).

### Cost Estimation

```sql
-- Estimate Snowpipe costs for the last 30 days
SELECT
  PIPE_NAME,
  SUM(CREDITS_USED) AS total_credits,
  SUM(FILES_INSERTED) AS total_files,
  SUM(BYTES_INSERTED) / POWER(1024, 3) AS total_gb_loaded,
  SUM(CREDITS_USED) / NULLIF(SUM(FILES_INSERTED), 0) AS credits_per_file
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE START_TIME >= DATEADD(DAY, -30, CURRENT_TIMESTAMP())
GROUP BY PIPE_NAME
ORDER BY total_credits DESC;
```

### When Snowpipe Is Cost-Effective vs Not

| Scenario | Recommendation |
|----------|---------------|
| Continuous trickle of small files throughout the day | Snowpipe (ideal use case) |
| A few large batch loads per day | Scheduled COPY INTO with warehouse |
| Many tiny files (<1 KB each) | Snowpipe overhead is high; batch files first |
| Real-time latency required | Snowpipe Streaming |
| Predictable, scheduled loads | COPY INTO with Tasks |

---

## Error Handling

### Viewing Snowpipe Errors

```sql
-- Check COPY_HISTORY for Snowpipe load errors
SELECT
  PIPE_NAME,
  FILE_NAME,
  STATUS,
  FIRST_ERROR_MESSAGE,
  FIRST_ERROR_LINE_NUM,
  FIRST_ERROR_CHARACTER_POS,
  FIRST_ERROR_COLUMN_NAME,
  ERROR_COUNT,
  ERROR_LIMIT,
  ROWS_PARSED,
  ROWS_LOADED
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP()),
  RESULT_LIMIT => 100
))
WHERE STATUS != 'LOADED'
ORDER BY LAST_LOAD_TIME DESC;
```

### Error Notification Integration

You can configure error notifications to be sent to a cloud queue (SNS, Event Grid) when Snowpipe encounters errors.

```sql
-- Create an error notification integration
CREATE OR REPLACE NOTIFICATION INTEGRATION my_error_notif
  ENABLED = TRUE
  TYPE = QUEUE
  NOTIFICATION_PROVIDER = AWS_SNS
  DIRECTION = OUTBOUND
  AWS_SNS_TOPIC_ARN = 'arn:aws:sns:us-east-1:123456789:snowpipe-errors'
  AWS_SNS_ROLE_ARN = 'arn:aws:iam::123456789:role/snowpipe-error-role';

-- Attach error integration to a pipe
ALTER PIPE my_pipe SET
  ERROR_INTEGRATION = my_error_notif;
```

### ON_ERROR Behavior in Snowpipe

The `ON_ERROR` option in the pipe's COPY statement works the same as in regular COPY INTO:

```sql
CREATE OR REPLACE PIPE resilient_pipe
  AUTO_INGEST = TRUE
  AS
  COPY INTO my_table FROM @my_stage
  FILE_FORMAT = my_format
  ON_ERROR = 'SKIP_FILE';  -- Skip entire files with errors
```

> **Recommendation**: For production Snowpipe, use `ON_ERROR = 'SKIP_FILE'` and set up error notification integrations to alert on failures. This prevents bad data from entering the table while ensuring you are notified to investigate.

---

## Snowpipe vs Scheduled COPY INTO

| Feature | Snowpipe | Scheduled COPY INTO (via Tasks) |
|---------|----------|-------------------------------|
| **Trigger** | Event-driven (file arrival) | Time-based (cron schedule) |
| **Latency** | ~1-2 minutes | Depends on schedule (minutes to hours) |
| **Compute** | Serverless (managed by Snowflake) | Virtual warehouse (user-managed) |
| **Cost Model** | Serverless credits + per-file overhead | Warehouse credits |
| **Best For** | Continuous, unpredictable file arrivals | Predictable batch loads |
| **File Size** | Works best with many small/medium files | Works best with fewer larger files |
| **Control** | Less control over timing and compute | Full control over warehouse size and schedule |
| **Error Handling** | Error integration notifications | Task error streams, COPY_HISTORY |
| **Scaling** | Auto-scales serverless compute | Manual warehouse sizing |
| **Max File Tracking** | 14-day dedup window | 64-day dedup window (standard COPY INTO) |

### Scheduled COPY INTO Pattern

```sql
-- Create a task that runs COPY INTO every 15 minutes
CREATE OR REPLACE TASK load_sales_data
  WAREHOUSE = loading_wh
  SCHEDULE = 'USING CRON 0/15 * * * * America/New_York'
AS
  COPY INTO sales
  FROM @my_s3_stage/sales/
  FILE_FORMAT = my_csv_format
  ON_ERROR = 'SKIP_FILE';

-- Enable the task
ALTER TASK load_sales_data RESUME;
```

### Decision Guide

- **Choose Snowpipe** when data files arrive continuously and unpredictably, and you need near real-time availability.
- **Choose scheduled COPY INTO** when loads happen at known intervals, you want cost predictability, and a few minutes of additional latency is acceptable.
- **Choose Snowpipe Streaming** when you need sub-second latency and data comes from a streaming source (Kafka, application events).

---

## Best Practices

### 1. File Sizing for Snowpipe

Aim for files between **10 MB and 100 MB** (compressed). Snowpipe is optimized for many small-to-medium files. Very large files reduce the benefit of continuous loading.

### 2. Avoid Too Many Tiny Files

Each file has a small processing overhead. Thousands of sub-KB files per minute will generate significant overhead costs. Buffer and batch on the producer side if possible.

### 3. Organize Stage Paths

```
s3://bucket/pipeline/entity/year=YYYY/month=MM/day=DD/
```

This enables targeted REFRESH operations and makes troubleshooting easier.

### 4. Set Up Error Notification Integrations

Always configure error notification integrations for production pipes. Silent failures are the most dangerous failures.

### 5. Monitor Pipe Health Regularly

```sql
-- Quick health check
SELECT
  PARSE_JSON(SYSTEM$PIPE_STATUS('my_db.my_schema.my_pipe')):executionState::STRING AS state,
  PARSE_JSON(SYSTEM$PIPE_STATUS('my_db.my_schema.my_pipe')):pendingFileCount::INTEGER AS pending;
```

### 6. Use REFRESH Sparingly

`ALTER PIPE REFRESH` is for recovery, not routine operation. If you find yourself refreshing frequently, investigate why notifications are being missed.

### 7. Include Audit Columns in the Pipe Definition

```sql
CREATE OR REPLACE PIPE audit_pipe AUTO_INGEST = TRUE AS
COPY INTO my_table (col1, col2, _source_file, _file_row, _loaded_at)
FROM (
  SELECT $1, $2, METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, CURRENT_TIMESTAMP()
  FROM @my_stage
)
FILE_FORMAT = my_format;
```

### 8. Test Pipe Definition Before Enabling Auto-Ingest

```sql
-- Validate the COPY statement works
COPY INTO my_table FROM @my_stage
  FILE_FORMAT = my_format
  VALIDATION_MODE = 'RETURN_ERRORS';
```

### 9. Pause Pipes During Maintenance

```sql
ALTER PIPE my_pipe SET PIPE_EXECUTION_PAUSED = TRUE;
-- Perform maintenance (schema changes, etc.)
ALTER PIPE my_pipe SET PIPE_EXECUTION_PAUSED = FALSE;
-- Refresh to catch any files that arrived during the pause
ALTER PIPE my_pipe REFRESH;
```

### 10. Track Snowpipe Costs Separately

Create alerts for unexpected spikes in Snowpipe credits to catch runaway producers or misconfigured event notifications.

---

## Common Interview Questions

### Q1: How does Snowpipe differ from a scheduled COPY INTO using Tasks?

**Answer**: Snowpipe is event-driven and serverless -- it triggers automatically when new files arrive and uses Snowflake-managed compute. Scheduled COPY INTO uses a virtual warehouse on a cron schedule. Snowpipe offers lower latency (~1-2 minutes) but costs more per credit (serverless rate). Scheduled COPY INTO offers more control over compute resources and is more cost-effective for predictable, batch-oriented loads. Snowpipe also has a 14-day file deduplication window compared to 64 days for standard COPY INTO.

---

### Q2: What happens when a Snowpipe encounters an error loading a file?

**Answer**: The behavior depends on the ON_ERROR option in the pipe's COPY statement. With SKIP_FILE (recommended for production), the entire file is skipped and the error is logged in COPY_HISTORY. With CONTINUE, bad rows are skipped but valid rows are loaded. With ABORT_STATEMENT, the load for that particular batch fails. Regardless of the ON_ERROR setting, error details are visible in COPY_HISTORY, and you can configure error notification integrations to send alerts to SNS, Event Grid, or Pub/Sub.

---

### Q3: Explain Snowpipe Streaming and how it differs from classic Snowpipe.

**Answer**: Classic Snowpipe loads data from staged files and has ~1-2 minute latency. Snowpipe Streaming accepts row-level data directly via the Java Ingest SDK, bypassing file staging entirely, with sub-second latency. Streaming uses offset tokens for exactly-once semantics. The primary use case is real-time data from Kafka or application event streams. The Snowflake Kafka Connector v2.0+ leverages Snowpipe Streaming under the hood for low-latency Kafka ingestion.

---

### Q4: How would you troubleshoot a Snowpipe that stopped loading data?

**Answer**: Systematic troubleshooting approach:
1. **Check pipe status**: `SELECT SYSTEM$PIPE_STATUS('pipe_name')` -- look at executionState (RUNNING, PAUSED, STALLED) and pendingFileCount.
2. **Verify the pipe is not paused**: `SHOW PIPES LIKE 'pipe_name'` and check the `is_paused` column.
3. **Check event notifications**: Verify the cloud notification channel is properly configured and receiving events (check SQS queue, Event Grid subscription, etc.).
4. **Check COPY_HISTORY**: Look for error statuses to see if files are arriving but failing.
5. **Verify stage accessibility**: Confirm the storage integration and stage are still valid.
6. **Check file format**: Ensure source files match the expected format.
7. **Try REFRESH**: `ALTER PIPE my_pipe REFRESH` to re-scan for missed files.
8. **Recreate if necessary**: In extreme cases, drop and recreate the pipe.

---

### Q5: What is the cost model for Snowpipe and when might it become expensive?

**Answer**: Snowpipe charges serverless compute credits (at a higher rate than standard warehouse credits, approximately 1.5x) and a small overhead of about 0.06 credits per 1,000 files for notification management. It becomes expensive when: (1) processing a very large number of tiny files (high per-file overhead), (2) loading large volumes that would be cheaper with a dedicated warehouse, or (3) the event notification is misconfigured, causing repeated processing attempts. For predictable, large batch loads, a scheduled COPY INTO with a right-sized warehouse is typically more cost-effective.

---

### Q6: How do you handle schema changes when using Snowpipe?

**Answer**: When the target table schema changes:
1. **Pause the pipe**: `ALTER PIPE my_pipe SET PIPE_EXECUTION_PAUSED = TRUE`
2. **Apply schema changes** to the target table (ALTER TABLE ADD COLUMN, etc.)
3. **Recreate the pipe** with an updated COPY statement if the COPY SQL needs to change (pipes are immutable -- you cannot ALTER the AS clause)
4. **Resume or refresh** the new pipe
5. If using `MATCH_BY_COLUMN_NAME`, minor schema evolution (new columns in source files) can be handled without pipe changes, as unmatched columns are simply ignored.

---

### Q7: What is ALTER PIPE REFRESH and when should you use it?

**Answer**: `ALTER PIPE REFRESH` manually scans the stage for files that Snowpipe may have missed. It processes files from the last 7 days that have not been loaded yet. Use it to: (1) recover from missed event notifications, (2) catch up after a pipe was paused, (3) load historical files that were staged before the pipe was created. It should not be used as a routine operation -- if you need to refresh frequently, the root cause (missed notifications) should be investigated and fixed.

---

### Q8: How does Snowpipe prevent duplicate data loading?

**Answer**: Snowpipe tracks loaded files in internal metadata for 14 days using the file name and a content hash. If the same file (same name and content) arrives again within this window, it is skipped. However, if a file with the same name but different content arrives, it will be loaded. After 14 days, file tracking expires, and the same file could potentially be reloaded. For Snowpipe Streaming, deduplication relies on offset tokens provided by the client application to ensure exactly-once semantics.

---

## Tips

- **Snowpipe file dedup is 14 days, not 64 days**. This is a common interview gotcha. Standard COPY INTO tracks files for 64 days; Snowpipe only tracks for 14 days.
- **Pipe definitions are immutable** with respect to the COPY statement. To change the COPY logic, you must recreate the pipe. The only things you can ALTER are PIPE_EXECUTION_PAUSED, ERROR_INTEGRATION, and COMMENT.
- **Snowpipe uses its own serverless compute**, completely separate from any virtual warehouse. Warehouse suspension or busy warehouses do not affect Snowpipe performance.
- **For Kafka integration**, the Snowflake Kafka Connector with Snowpipe Streaming is the recommended approach for new deployments (lower latency, no staging files).
- **Always have an error notification integration** in production. Snowpipe failures can go unnoticed for days without proper alerting.
- **Snowpipe is not transactional across files**. Each file is loaded independently. If you need all-or-nothing loading for a batch of related files, use scheduled COPY INTO instead.
- **SYSTEM$PIPE_STATUS is your best friend** for quick operational checks. Script it into your monitoring dashboards.
- **Auto-ingest pipes cannot use the REST API** and vice versa. A pipe is either auto-ingest or REST API-driven, not both.
