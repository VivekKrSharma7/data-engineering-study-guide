# Stages (Internal, External, Named)

[Back to Snowflake Index](./README.md)

---

## Overview

In Snowflake, a **stage** is a location where data files are stored (staged) before being loaded into tables or after being unloaded from tables. Stages are the bridge between external file systems and Snowflake tables. Understanding the different types of stages, how to create and manage them, and their properties is critical for data engineering roles.

---

## Key Concepts

### 1. Types of Stages

Snowflake supports three categories of stages:

| Stage Type | Prefix | Scope | Created Automatically? | Use Case |
|---|---|---|---|---|
| **User stage** | `@~` | Per user | Yes (every user has one) | Quick personal file uploads |
| **Table stage** | `@%table_name` | Per table | Yes (every table has one) | Load files specific to one table |
| **Named internal stage** | `@stage_name` | Schema-level object | No (must be created) | Shared staging area, most flexible |
| **Named external stage** | `@stage_name` | Schema-level object | No (must be created) | References cloud storage (S3, Azure Blob, GCS) |

### 2. User Stages (`@~`)

Every Snowflake user is automatically allocated a personal stage.

```sql
-- List files in your user stage
LIST @~;

-- Upload a file to your user stage (from SnowSQL client)
PUT file:///tmp/data/employees.csv @~;

-- Load data from your user stage into a table
COPY INTO employees
FROM @~
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

**Limitations:**
- Cannot be altered or dropped
- Cannot set file format options on the stage itself (must specify in COPY)
- Only accessible by the owning user
- Cannot be shared with other users
- Cannot use `GRANT` to provide access

### 3. Table Stages (`@%tablename`)

Every table automatically has an associated stage.

```sql
-- List files in a table stage
LIST @%employees;

-- Upload a file to a table stage
PUT file:///tmp/data/employees.csv @%employees;

-- Load from the table stage
COPY INTO employees
FROM @%employees
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

**Limitations:**
- Cannot be altered or dropped
- Cannot set file format options on the stage itself
- Tied to a specific table — files here are intended for that table only
- Other users with appropriate table privileges can access the stage
- Does not support transformations during COPY (e.g., column reordering)

### 4. Named Internal Stages

Named internal stages are the most flexible option for internal (Snowflake-managed) storage.

```sql
-- Create a named internal stage
CREATE OR REPLACE STAGE my_csv_stage
    FILE_FORMAT = (TYPE = 'CSV' FIELD_DELIMITER = ',' SKIP_HEADER = 1)
    COMMENT = 'Stage for CSV file ingestion';

-- Create a stage with specific encryption (default is SNOWFLAKE_FULL)
CREATE STAGE encrypted_stage
    ENCRYPTION = (TYPE = 'SNOWFLAKE_FULL');

-- Create a stage with a named file format
CREATE FILE FORMAT my_csv_format
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    NULL_IF = ('NULL', 'null', '')
    EMPTY_FIELD_AS_NULL = TRUE
    COMPRESSION = 'GZIP';

CREATE STAGE my_stage
    FILE_FORMAT = my_csv_format;

-- List files
LIST @my_stage;

-- Upload files
PUT file:///tmp/data/*.csv @my_stage/2025/12/ AUTO_COMPRESS = TRUE;

-- Load data
COPY INTO employees
FROM @my_stage/2025/12/
PATTERN = '.*employees.*[.]csv[.]gz';
```

**Advantages:**
- Can specify default file format
- Can be shared via GRANT (role-based access)
- Supports directory tables
- Supports path prefixes for file organization
- Most commonly used internal stage type in production

### 5. External Stages

External stages reference data files stored in cloud storage outside Snowflake.

#### Amazon S3 External Stage
```sql
-- Create a storage integration (recommended — avoids storing credentials in the stage)
CREATE STORAGE INTEGRATION s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-access-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://my-bucket/data/', 's3://my-bucket/archive/')
    STORAGE_BLOCKED_LOCATIONS = ('s3://my-bucket/data/sensitive/');

-- Describe the integration to get the AWS IAM user and external ID
-- (needed to configure the trust relationship in AWS)
DESC INTEGRATION s3_integration;

-- Create external stage using storage integration
CREATE OR REPLACE STAGE s3_data_stage
    STORAGE_INTEGRATION = s3_integration
    URL = 's3://my-bucket/data/'
    FILE_FORMAT = (TYPE = 'PARQUET');
```

#### Azure Blob Storage External Stage
```sql
-- Create Azure storage integration
CREATE STORAGE INTEGRATION azure_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'AZURE'
    ENABLED = TRUE
    AZURE_TENANT_ID = 'a]1b2c3d4-e5f6-7890-abcd-ef1234567890'
    STORAGE_ALLOWED_LOCATIONS = ('azure://myaccount.blob.core.windows.net/mycontainer/data/');

-- Create external stage for Azure
CREATE STAGE azure_data_stage
    STORAGE_INTEGRATION = azure_integration
    URL = 'azure://myaccount.blob.core.windows.net/mycontainer/data/'
    FILE_FORMAT = (TYPE = 'JSON');
```

#### Google Cloud Storage External Stage
```sql
-- Create GCS storage integration
CREATE STORAGE INTEGRATION gcs_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'GCS'
    ENABLED = TRUE
    STORAGE_ALLOWED_LOCATIONS = ('gcs://my-gcs-bucket/data/');

-- Create external stage for GCS
CREATE STAGE gcs_data_stage
    STORAGE_INTEGRATION = gcs_integration
    URL = 'gcs://my-gcs-bucket/data/'
    FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

### 6. Storage Integration Objects

Storage integrations are the **recommended, secure** way to connect Snowflake to cloud storage:

- **Avoid embedding credentials** directly in stage definitions
- Created once by `ACCOUNTADMIN` and referenced by multiple stages
- Use cloud-native IAM mechanisms (AWS IAM roles, Azure service principals, GCP service accounts)
- `STORAGE_ALLOWED_LOCATIONS` restricts which paths can be accessed (principle of least privilege)
- `STORAGE_BLOCKED_LOCATIONS` explicitly denies access to specific paths

```sql
-- Grant usage on a storage integration to a role
GRANT USAGE ON INTEGRATION s3_integration TO ROLE data_engineer_role;

-- View all storage integrations
SHOW INTEGRATIONS;

-- View details of a specific integration
DESCRIBE INTEGRATION s3_integration;
```

**Best Practice:** Always use storage integrations rather than embedding access keys or SAS tokens directly in stage definitions.

### 7. Stage Properties

Stages have several configurable properties:

```sql
-- View stage properties
DESCRIBE STAGE my_stage;
SHOW STAGES;

-- Alter stage properties
ALTER STAGE my_stage SET
    FILE_FORMAT = (TYPE = 'CSV' FIELD_DELIMITER = '|')
    COMMENT = 'Updated delimiter to pipe';

-- Alter external stage URL
ALTER STAGE s3_data_stage SET
    URL = 's3://my-bucket/data/v2/';
```

**Key properties:**

| Property | Description |
|---|---|
| `URL` | Cloud storage location (external stages only) |
| `STORAGE_INTEGRATION` | Reference to storage integration object |
| `FILE_FORMAT` | Default file format for the stage |
| `ENCRYPTION` | Encryption type (internal: `SNOWFLAKE_FULL`, `SNOWFLAKE_SSE`; external: cloud-native encryption) |
| `DIRECTORY` | Enable directory table for the stage |
| `COMMENT` | Descriptive comment |

### 8. Listing Files in Stages (LIST)

```sql
-- List all files in a stage
LIST @my_stage;

-- List with a path prefix
LIST @my_stage/2025/12/;

-- List files matching a pattern
LIST @s3_data_stage PATTERN = '.*[.]parquet';

-- The LIST output includes:
-- name (file path), size (bytes), md5 (checksum), last_modified
```

**Output columns:**

| Column | Description |
|---|---|
| `name` | Full path of the file within the stage |
| `size` | File size in bytes |
| `md5` | MD5 hash of the file |
| `last_modified` | Timestamp of last modification |

### 9. Removing Files from Stages (REMOVE)

```sql
-- Remove a specific file from an internal stage
REMOVE @my_stage/2025/12/employees.csv.gz;

-- Remove all files in a path
REMOVE @my_stage/2025/12/;

-- Remove files matching a pattern
REMOVE @my_stage PATTERN = '.*[.]csv[.]gz';

-- Remove files from a table stage
REMOVE @%employees;

-- Purge files automatically after successful COPY INTO
COPY INTO employees
FROM @my_stage
FILE_FORMAT = (TYPE = 'CSV')
PURGE = TRUE;   -- Automatically removes files after successful load
```

### 10. PUT and GET Commands (Internal Stages Only)

`PUT` uploads files from a local machine to an internal stage. `GET` downloads files from an internal stage to a local machine. These commands are **only available in SnowSQL** (CLI client) or connectors — not in the Snowflake web UI.

```sql
-- PUT: Upload local files to internal stage
-- Syntax: PUT file://<local_path> @<stage_name>/<path>/
PUT file:///tmp/data/orders.csv @my_stage/orders/ AUTO_COMPRESS = TRUE;

-- Upload multiple files with wildcard
PUT file:///tmp/data/orders_*.csv @my_stage/orders/;

-- PUT with options
PUT file:///tmp/data/large_file.csv @my_stage
    AUTO_COMPRESS = TRUE          -- Compress with gzip before upload (default: TRUE)
    SOURCE_COMPRESSION = NONE     -- Source file is not pre-compressed
    PARALLEL = 4                  -- Number of parallel upload threads
    OVERWRITE = TRUE;             -- Overwrite if file already exists

-- GET: Download files from internal stage to local directory
GET @my_stage/orders/orders.csv.gz file:///tmp/downloads/;

-- GET with options
GET @my_stage/orders/ file:///tmp/downloads/
    PARALLEL = 4                  -- Number of parallel download threads
    PATTERN = '.*orders.*[.]csv[.]gz';
```

**Important Notes on PUT/GET:**
- `PUT` and `GET` only work with **internal stages** (user, table, or named internal)
- They do NOT work with external stages (files in S3/Azure/GCS are managed through cloud tools)
- `PUT` automatically compresses files with gzip by default (`AUTO_COMPRESS = TRUE`)
- `PUT` automatically encrypts files before uploading
- Files are split into chunks and uploaded in parallel for large files

### 11. Directory Tables on Stages

Directory tables provide a catalog of staged files with automatic metadata refresh capabilities.

```sql
-- Create a stage with directory table enabled
CREATE OR REPLACE STAGE my_stage_with_dir
    DIRECTORY = (ENABLE = TRUE)
    FILE_FORMAT = (TYPE = 'CSV');

-- Enable directory table on an existing stage
ALTER STAGE my_stage SET DIRECTORY = (ENABLE = TRUE);

-- Manually refresh the directory table (needed for internal stages)
ALTER STAGE my_stage REFRESH;

-- For external stages, auto-refresh can be configured with cloud event notifications
ALTER STAGE s3_data_stage SET DIRECTORY = (
    ENABLE = TRUE
    AUTO_REFRESH = TRUE   -- Uses event notifications (S3 SNS, Azure Event Grid, GCP Pub/Sub)
);

-- Query the directory table
SELECT * FROM DIRECTORY(@my_stage);

-- Directory table columns:
-- RELATIVE_PATH, SIZE, LAST_MODIFIED, MD5, ETAG, FILE_URL, SCOPED_FILE_URL

-- Use directory tables to build dynamic file processing
SELECT
    RELATIVE_PATH,
    SIZE,
    LAST_MODIFIED,
    BUILD_SCOPED_FILE_URL(@my_stage, RELATIVE_PATH) AS scoped_url
FROM DIRECTORY(@my_stage)
WHERE RELATIVE_PATH LIKE '%.parquet'
  AND LAST_MODIFIED > DATEADD('hour', -24, CURRENT_TIMESTAMP());
```

**Use cases for directory tables:**
- Track which files have been loaded
- Build semi-structured file catalogs
- Power unstructured data workflows (images, PDFs, etc.) with `FILE_URL` and `SCOPED_FILE_URL`
- Integration with Snowpark for file-level processing

### 12. Stage Encryption

All data in internal stages is encrypted:

| Encryption Type | Description | Stage Type |
|---|---|---|
| `SNOWFLAKE_FULL` | Client-side encryption (default for internal stages). Files encrypted before leaving client during PUT. Snowflake manages keys. | Internal |
| `SNOWFLAKE_SSE` | Server-side encryption. Files encrypted at rest in Snowflake storage. | Internal |
| `AWS_CSE` | Client-side encryption using AWS KMS | External (S3) |
| `AWS_SSE_S3` | Server-side encryption with S3-managed keys | External (S3) |
| `AWS_SSE_KMS` | Server-side encryption with AWS KMS-managed keys | External (S3) |
| `AZURE_CSE` | Client-side encryption using Azure Key Vault | External (Azure) |
| `GCS_SSE_KMS` | Server-side encryption with GCP KMS-managed keys | External (GCS) |
| `NONE` | No encryption (external stages only — not recommended) | External |

```sql
-- Internal stage with explicit encryption
CREATE STAGE secure_stage
    ENCRYPTION = (TYPE = 'SNOWFLAKE_FULL');

-- External stage with AWS KMS encryption
CREATE STAGE s3_kms_stage
    STORAGE_INTEGRATION = s3_integration
    URL = 's3://my-bucket/encrypted-data/'
    ENCRYPTION = (TYPE = 'AWS_SSE_KMS' KMS_KEY_ID = 'arn:aws:kms:us-east-1:123456789012:key/abcd-1234');
```

---

## Real-World Example: Complete Data Loading Pipeline

```sql
-- 1. Create a file format
CREATE OR REPLACE FILE FORMAT sales_csv_format
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    NULL_IF = ('NULL', 'null', '\\N', '')
    EMPTY_FIELD_AS_NULL = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    COMPRESSION = 'AUTO';

-- 2. Create a storage integration (done once by admin)
CREATE OR REPLACE STORAGE INTEGRATION sales_s3_int
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-sales-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://company-data-lake/sales/');

-- 3. Create the external stage
CREATE OR REPLACE STAGE sales_ext_stage
    STORAGE_INTEGRATION = sales_s3_int
    URL = 's3://company-data-lake/sales/'
    FILE_FORMAT = sales_csv_format
    DIRECTORY = (ENABLE = TRUE AUTO_REFRESH = TRUE);

-- 4. Verify files are accessible
LIST @sales_ext_stage;

-- 5. Validate data before loading (dry run)
COPY INTO sales_raw
FROM @sales_ext_stage/2025/
VALIDATION_MODE = 'RETURN_ERRORS';

-- 6. Load data
COPY INTO sales_raw
FROM @sales_ext_stage/2025/
PATTERN = '.*sales_[0-9]+[.]csv[.]gz'
ON_ERROR = 'CONTINUE'           -- Skip files with errors
FORCE = FALSE                   -- Don't reload already-loaded files (default)
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE';

-- 7. Check load history
SELECT *
FROM TABLE(information_schema.copy_history(
    TABLE_NAME => 'SALES_RAW',
    START_TIME => DATEADD('hour', -24, CURRENT_TIMESTAMP())
))
ORDER BY last_load_time DESC;
```

---

## Common Interview Questions

### Q1: What are the different types of stages in Snowflake?
**A:** There are four types: **User stages** (`@~`) — personal to each user, created automatically; **Table stages** (`@%tablename`) — associated with each table, created automatically; **Named internal stages** — explicitly created schema objects stored in Snowflake-managed storage; **Named external stages** — explicitly created schema objects pointing to external cloud storage (S3, Azure Blob, GCS).

### Q2: What is a storage integration and why should you use one?
**A:** A storage integration is a Snowflake object that stores cloud provider credentials and access configuration for external stages. You should use them because they avoid storing sensitive credentials (access keys, SAS tokens) directly in stage definitions, use cloud-native IAM (roles/service principals), can restrict allowed/blocked storage locations, and can be shared across multiple stages via GRANT.

### Q3: What is the difference between PUT/GET and LIST/REMOVE?
**A:** `PUT` uploads local files to an internal stage, and `GET` downloads files from an internal stage to a local machine — both only work via SnowSQL or connectors, not the web UI, and only with internal stages. `LIST` shows files in any stage (internal or external), and `REMOVE` deletes files from stages. `LIST` and `REMOVE` work in any Snowflake client.

### Q4: Can you use PUT/GET with external stages?
**A:** No. `PUT` and `GET` only work with internal stages (user, table, or named internal). For external stages, files are managed using the cloud provider's native tools (AWS CLI, Azure Storage Explorer, gsutil, etc.).

### Q5: What is PURGE in the COPY command?
**A:** `PURGE = TRUE` in a `COPY INTO <table>` command automatically removes files from the stage after they are successfully loaded. This is useful for cleaning up staged files to avoid reprocessing. Only applies to internal stages.

### Q6: How does Snowflake track which files have already been loaded?
**A:** Snowflake maintains **load metadata** for 64 days. When you run `COPY INTO`, it checks this metadata and skips files that have already been successfully loaded (unless `FORCE = TRUE` is specified). This metadata includes the file name, size, checksum, and row count.

### Q7: What are directory tables and when would you use them?
**A:** Directory tables are a metadata layer on stages that catalog all files with attributes like path, size, last modified time, and file URLs. They are queried using `SELECT * FROM DIRECTORY(@stage_name)`. Use cases include tracking files for processing, generating scoped URLs for unstructured data access, and building file inventories. External stages support auto-refresh via cloud event notifications.

### Q8: How is data encrypted in stages?
**A:** Internal stages use `SNOWFLAKE_FULL` encryption by default — files are encrypted client-side before upload and Snowflake manages the keys. External stages support cloud-native encryption options: `AWS_SSE_S3`, `AWS_SSE_KMS`, `AWS_CSE` for S3; `AZURE_CSE` for Azure; `GCS_SSE_KMS` for GCS. External stages can also be set to `NONE` (not recommended).

### Q9: What is the difference between a named internal stage and a user/table stage?
**A:** Named internal stages are explicitly created objects that can have default file formats, be shared via role-based access (GRANT), support directory tables, and be organized with path prefixes. User and table stages are automatically created, cannot be altered or dropped, cannot have default file formats, and have more limited access control. Named internal stages are the recommended choice for production workloads.

---

## Tips

- **Always use named stages in production** — user and table stages are convenient for ad-hoc work, but named stages (internal or external) provide better governance, access control, and file format defaults.
- **Use storage integrations for external stages** — never embed credentials directly in stage definitions. Storage integrations are more secure, auditable, and maintainable.
- **Remember that PUT/GET are client-side only** — they run in SnowSQL or connectors, not in worksheets. This is a common trick question in interviews.
- **Leverage PURGE = TRUE** — to keep stages clean after successful loads, preventing file accumulation and re-processing confusion.
- **Use VALIDATION_MODE before loading** — `VALIDATION_MODE = 'RETURN_ERRORS'` lets you preview errors without actually loading data, which is invaluable for debugging file format issues.
- **Auto-compress is on by default for PUT** — files are gzip-compressed before upload. Be aware of this when working with pre-compressed files to avoid double compression.
- **The 64-day load metadata window** — Snowflake remembers loaded files for 64 days. After that, `COPY INTO` may reload the same file unless you track loads separately. Use `FORCE = TRUE` deliberately and with caution.
- **Directory tables + streams** — you can create streams on directory tables to detect new files, enabling event-driven loading pipelines without Snowpipe.
