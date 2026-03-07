# File Formats & Semi-Structured Data (JSON, Parquet, Avro, ORC)

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### Named File Format Objects

Snowflake allows you to create **named file format objects** that encapsulate all the settings for parsing a specific file type. This avoids repeating format options in every COPY INTO statement and centralizes configuration management.

```sql
-- Create a named file format
CREATE OR REPLACE FILE FORMAT my_csv_format
  TYPE = 'CSV'
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('NULL', 'null', '\\N', '')
  COMMENT = 'Pipe-delimited CSV with header row';

-- Use the named format in COPY INTO
COPY INTO my_table
FROM @my_stage/data/
FILE_FORMAT = (FORMAT_NAME = my_csv_format);
```

Named file formats live within a schema and follow standard Snowflake privilege controls. You can grant USAGE on a file format to other roles.

---

### CSV File Format Options

CSV is the most commonly used format for bulk loading. Snowflake provides granular control over parsing behavior.

| Option | Default | Description |
|--------|---------|-------------|
| `FIELD_DELIMITER` | `,` | Character separating fields |
| `RECORD_DELIMITER` | `\n` | Character separating records |
| `SKIP_HEADER` | `0` | Number of header lines to skip |
| `FIELD_OPTIONALLY_ENCLOSED_BY` | `NONE` | Character enclosing fields (e.g., `'"'` or `"'"`) |
| `ESCAPE` | `NONE` | Escape character for enclosed fields |
| `ESCAPE_UNENCLOSED_FIELD` | `\\` | Escape character for unenclosed fields |
| `NULL_IF` | `('\\N')` | Strings to interpret as SQL NULL |
| `TRIM_SPACE` | `FALSE` | Remove leading/trailing whitespace |
| `ERROR_ON_COLUMN_COUNT_MISMATCH` | `TRUE` | Error if file columns differ from table columns |
| `ENCODING` | `UTF8` | Character encoding of the file |
| `COMPRESSION` | `AUTO` | Compression type (GZIP, BZ2, BROTLI, ZSTD, etc.) |
| `DATE_FORMAT` | `AUTO` | Format for parsing date strings |
| `TIME_FORMAT` | `AUTO` | Format for parsing time strings |
| `TIMESTAMP_FORMAT` | `AUTO` | Format for parsing timestamp strings |

```sql
-- A production-grade CSV file format
CREATE OR REPLACE FILE FORMAT prod_csv_format
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  RECORD_DELIMITER = '\n'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ESCAPE = '\\'
  ESCAPE_UNENCLOSED_FIELD = '\\'
  TRIM_SPACE = TRUE
  NULL_IF = ('NULL', 'null', '', '\\N', 'NA', 'N/A')
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
  COMPRESSION = 'AUTO'
  DATE_FORMAT = 'YYYY-MM-DD'
  TIMESTAMP_FORMAT = 'YYYY-MM-DD HH24:MI:SS.FF3';
```

---

### JSON File Format Options

Snowflake has native support for JSON data. Key options control how JSON is parsed and loaded.

| Option | Default | Description |
|--------|---------|-------------|
| `STRIP_OUTER_ARRAY` | `FALSE` | Remove the outer array brackets `[ ]` and treat each element as a separate row |
| `STRIP_NULL_VALUES` | `FALSE` | Remove JSON keys with `null` values (saves storage) |
| `ALLOW_DUPLICATE` | `FALSE` | Allow duplicate keys in JSON objects |
| `ENABLE_OCTAL` | `FALSE` | Allow octal number notation |
| `IGNORE_UTF8_ERRORS` | `FALSE` | Replace invalid UTF-8 characters instead of erroring |
| `DATE_FORMAT` | `AUTO` | Format for parsing date strings |
| `TIME_FORMAT` | `AUTO` | Format for parsing time strings |
| `TIMESTAMP_FORMAT` | `AUTO` | Format for parsing timestamp strings |

```sql
-- JSON file format for API response data (array of objects)
CREATE OR REPLACE FILE FORMAT api_json_format
  TYPE = 'JSON'
  STRIP_OUTER_ARRAY = TRUE
  STRIP_NULL_VALUES = TRUE
  IGNORE_UTF8_ERRORS = TRUE
  COMPRESSION = 'AUTO';

-- JSON file format for newline-delimited JSON (NDJSON)
CREATE OR REPLACE FILE FORMAT ndjson_format
  TYPE = 'JSON'
  STRIP_OUTER_ARRAY = FALSE
  STRIP_NULL_VALUES = FALSE
  COMPRESSION = 'GZIP';
```

**When to use STRIP_OUTER_ARRAY:**

If your JSON file looks like this:
```json
[
  {"id": 1, "name": "Alice"},
  {"id": 2, "name": "Bob"},
  {"id": 3, "name": "Charlie"}
]
```
Set `STRIP_OUTER_ARRAY = TRUE` so each object becomes a separate row in your VARIANT column. Without it, the entire array is loaded as a single row.

---

### Parquet, Avro, and ORC Support

Snowflake supports these columnar/binary formats natively for both loading and unloading.

#### Parquet

```sql
CREATE OR REPLACE FILE FORMAT my_parquet_format
  TYPE = 'PARQUET'
  COMPRESSION = 'SNAPPY'        -- SNAPPY, LZO, GZIP, BROTLI, ZSTD, NONE
  BINARY_AS_TEXT = TRUE          -- Interpret binary columns as text
  USE_VECTORIZED_SCANNER = TRUE; -- Faster scanning (default TRUE in newer versions)
```

Parquet is the **recommended format** for data lake integration because:
- Columnar storage enables efficient column pruning during queries
- Built-in schema metadata
- Efficient compression
- Wide ecosystem support (Spark, Hive, Iceberg, Delta)

#### Avro

```sql
CREATE OR REPLACE FILE FORMAT my_avro_format
  TYPE = 'AVRO'
  COMPRESSION = 'AUTO'          -- AUTO, DEFLATE, SNAPPY, ZSTD, NONE
  TRIM_SPACE = FALSE;
```

Avro is schema-embedded, row-oriented, and commonly used with Kafka and schema registries.

#### ORC

```sql
CREATE OR REPLACE FILE FORMAT my_orc_format
  TYPE = 'ORC'
  TRIM_SPACE = FALSE
  NULL_IF = ();
```

ORC is a columnar format from the Hadoop ecosystem, often used with Hive.

---

### VARIANT Data Type for Semi-Structured Data

The `VARIANT` data type can hold any valid JSON value (object, array, string, number, boolean, null) up to 16 MB compressed. Snowflake also provides `OBJECT` and `ARRAY` types for more specific semi-structured data.

```sql
-- Table with a VARIANT column for raw JSON
CREATE TABLE raw_events (
  event_id      INT AUTOINCREMENT,
  received_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  raw_data      VARIANT
);

-- Load JSON data into VARIANT
COPY INTO raw_events (raw_data)
FROM @my_stage/events/
FILE_FORMAT = (FORMAT_NAME = api_json_format);

-- Query semi-structured data using colon and bracket notation
SELECT
  raw_data:event_type::STRING         AS event_type,
  raw_data:user.id::INT               AS user_id,
  raw_data:user.name::STRING          AS user_name,
  raw_data:properties.amount::FLOAT   AS amount,
  raw_data:tags[0]::STRING            AS first_tag,
  raw_data:metadata.nested.deep::STRING AS deep_value
FROM raw_events
WHERE raw_data:event_type::STRING = 'purchase';
```

**Key rules for VARIANT access:**
- Use `:` (colon) to access top-level keys: `col:key`
- Use `.` (dot) for nested keys: `col:key.subkey`
- Use `[n]` for array elements (zero-based): `col:array[0]`
- Always cast to a specific type using `::TYPE` for proper comparisons and aggregations
- Key names are **case-sensitive** in VARIANT data (unlike regular SQL identifiers)

```sql
-- FLATTEN: Explode arrays within JSON
SELECT
  e.raw_data:order_id::INT AS order_id,
  f.value:product_id::INT AS product_id,
  f.value:quantity::INT AS quantity,
  f.value:price::DECIMAL(10,2) AS price
FROM raw_events e,
  LATERAL FLATTEN(input => e.raw_data:items) f
WHERE e.raw_data:event_type::STRING = 'order';

-- OBJECT and ARRAY constructors
SELECT
  OBJECT_CONSTRUCT('name', 'Alice', 'age', 30) AS json_obj,
  ARRAY_CONSTRUCT(1, 2, 3, 4, 5) AS json_arr,
  PARSE_JSON('{"key": "value"}') AS parsed;
```

---

### Automatic Schema Detection with INFER_SCHEMA

`INFER_SCHEMA` automatically detects column definitions from staged files (Parquet, Avro, ORC, CSV). This is extremely useful for creating tables that match file structures without manual DDL.

```sql
-- Infer schema from Parquet files
SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@my_stage/data/',
    FILE_FORMAT => 'my_parquet_format',
    FILES => 'sample_data.parquet'
  )
);

-- Returns: COLUMN_NAME, TYPE, NULLABLE, EXPRESSION, FILENAMES, ORDER_ID

-- Create a table from inferred schema
CREATE TABLE auto_table
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@my_stage/data/',
        FILE_FORMAT => 'my_parquet_format'
      )
    )
  );

-- Infer schema from CSV files (requires PARSE_HEADER = TRUE)
CREATE OR REPLACE FILE FORMAT csv_with_header
  TYPE = 'CSV'
  PARSE_HEADER = TRUE;

SELECT *
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@my_stage/csv_data/',
    FILE_FORMAT => 'csv_with_header'
  )
);
```

**INFER_SCHEMA options:**
- `LOCATION`: Stage path containing files
- `FILE_FORMAT`: Named file format or inline format
- `FILES`: Optional specific file(s) to inspect
- `IGNORE_CASE`: Normalize column names to uppercase if TRUE

---

### Altering File Formats

```sql
-- Modify an existing file format
ALTER FILE FORMAT my_csv_format
  SET SKIP_HEADER = 2
      NULL_IF = ('NULL', 'null', '', 'NA');

-- Rename a file format
ALTER FILE FORMAT my_csv_format RENAME TO legacy_csv_format;

-- Describe a file format
DESCRIBE FILE FORMAT my_csv_format;

-- Show all file formats in current schema
SHOW FILE FORMATS IN SCHEMA;

-- Show file formats across the database
SHOW FILE FORMATS IN DATABASE my_db;

-- Drop a file format
DROP FILE FORMAT IF EXISTS old_format;
```

---

### File Format Best Practices

1. **Always use named file formats** rather than inline format options -- they are reusable, version-trackable, and easier to maintain.

2. **For CSV files:**
   - Set `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` if source files may have trailing delimiters.
   - Define a comprehensive `NULL_IF` list matching your source system's null representations.
   - Use `FIELD_OPTIONALLY_ENCLOSED_BY` to handle fields containing delimiters.

3. **For JSON files:**
   - Use `STRIP_OUTER_ARRAY = TRUE` for JSON arrays to get one row per element.
   - Use `STRIP_NULL_VALUES = TRUE` to reduce storage cost for sparse JSON.
   - Load into a single VARIANT column first, then transform with views or downstream ELT.

4. **Prefer Parquet** for data lake integration -- it provides schema, compression, and column pruning benefits.

5. **Use INFER_SCHEMA** for Parquet/Avro/ORC to avoid manual DDL and reduce errors when onboarding new data sources.

6. **Compression:** Let Snowflake auto-detect compression (`COMPRESSION = 'AUTO'`). For unloading, prefer GZIP or ZSTD for broad compatibility.

7. **File sizing:** Aim for compressed files between 100-250 MB for optimal parallel loading performance.

---

## Real-World Examples

### Example 1: Multi-Format Data Ingestion Pipeline

```sql
-- Scenario: Ingest data from three different sources with different formats

-- Source 1: Legacy ERP system sends pipe-delimited CSV
CREATE OR REPLACE FILE FORMAT erp_csv_format
  TYPE = 'CSV'
  FIELD_DELIMITER = '|'
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('NULL', '', '0000-00-00')
  DATE_FORMAT = 'MM/DD/YYYY'
  TIMESTAMP_FORMAT = 'MM/DD/YYYY HH12:MI:SS AM';

-- Source 2: Streaming platform lands Avro files from Kafka
CREATE OR REPLACE FILE FORMAT kafka_avro_format
  TYPE = 'AVRO'
  COMPRESSION = 'SNAPPY';

-- Source 3: Analytics service exports Parquet from Spark
CREATE OR REPLACE FILE FORMAT spark_parquet_format
  TYPE = 'PARQUET'
  COMPRESSION = 'SNAPPY'
  USE_VECTORIZED_SCANNER = TRUE;

-- Load each source
COPY INTO erp_orders FROM @erp_stage/ FILE_FORMAT = (FORMAT_NAME = erp_csv_format);
COPY INTO kafka_events FROM @kafka_stage/ FILE_FORMAT = (FORMAT_NAME = kafka_avro_format);
COPY INTO analytics_sessions FROM @spark_stage/ FILE_FORMAT = (FORMAT_NAME = spark_parquet_format);
```

### Example 2: Nested JSON Processing with FLATTEN

```sql
-- Scenario: E-commerce order JSON with nested line items and shipping info
-- Sample JSON:
-- {
--   "order_id": 10001,
--   "customer": {"id": 5, "email": "alice@example.com"},
--   "items": [
--     {"sku": "ABC-100", "qty": 2, "price": 29.99},
--     {"sku": "XYZ-200", "qty": 1, "price": 49.99}
--   ],
--   "shipping": {"method": "express", "cost": 12.50}
-- }

CREATE TABLE raw_orders (data VARIANT);

-- Create a flattened view for analytics
CREATE OR REPLACE VIEW v_order_line_items AS
SELECT
  data:order_id::INT                     AS order_id,
  data:customer.id::INT                  AS customer_id,
  data:customer.email::STRING            AS customer_email,
  f.index                                AS line_number,
  f.value:sku::STRING                    AS sku,
  f.value:qty::INT                       AS quantity,
  f.value:price::DECIMAL(10,2)           AS unit_price,
  f.value:qty::INT * f.value:price::DECIMAL(10,2) AS line_total,
  data:shipping.method::STRING           AS shipping_method,
  data:shipping.cost::DECIMAL(10,2)      AS shipping_cost
FROM raw_orders,
  LATERAL FLATTEN(input => data:items) f;
```

### Example 3: Schema Detection and Table Creation from Parquet

```sql
-- Scenario: A data science team drops new Parquet files you have never seen before.
-- Use INFER_SCHEMA to create the table automatically.

-- Step 1: Inspect the schema
SELECT
  COLUMN_NAME,
  TYPE,
  NULLABLE
FROM TABLE(
  INFER_SCHEMA(
    LOCATION => '@data_science_stage/model_output/',
    FILE_FORMAT => 'spark_parquet_format'
  )
)
ORDER BY ORDER_ID;

-- Step 2: Create the table
CREATE OR REPLACE TABLE model_predictions
  USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(
      INFER_SCHEMA(
        LOCATION => '@data_science_stage/model_output/',
        FILE_FORMAT => 'spark_parquet_format'
      )
    )
  );

-- Step 3: Load the data using MATCH_BY_COLUMN_NAME
COPY INTO model_predictions
FROM @data_science_stage/model_output/
FILE_FORMAT = (FORMAT_NAME = spark_parquet_format)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

---

## Common Interview Questions & Answers

### Q1: What is the difference between loading JSON into a VARIANT column versus flattening it into relational columns during load?

**Answer:** Loading into a single VARIANT column (schema-on-read) is faster to set up and flexible when the JSON structure changes frequently. You query it using colon/dot/bracket notation with explicit casts. Flattening into relational columns during load (schema-on-write) provides better query performance, data type enforcement, and simpler SQL for downstream consumers. The recommended pattern is to load raw JSON into a VARIANT staging table, then use views or downstream transformations (ELT) to materialize flattened relational tables -- giving you both flexibility and performance.

### Q2: What does STRIP_OUTER_ARRAY do and when would you use it?

**Answer:** When `STRIP_OUTER_ARRAY = TRUE`, Snowflake removes the outer `[ ]` brackets from a JSON array and loads each element as a separate row. Use it when your JSON file contains a top-level array of objects (e.g., an API response returning a list). Without it, the entire array is loaded as a single VARIANT value in one row. For newline-delimited JSON (NDJSON), where each line is a separate JSON object, leave `STRIP_OUTER_ARRAY = FALSE` (the default).

### Q3: How does INFER_SCHEMA work, and what are its limitations?

**Answer:** `INFER_SCHEMA` reads file metadata (for Parquet, Avro, ORC) or samples data (for CSV with `PARSE_HEADER = TRUE`) to detect column names and data types. It returns a result set with column name, type, nullable flag, and expression. Limitations include: (1) For CSV, it can only detect column names from headers -- data types default to TEXT unless more sophisticated logic is applied. (2) It samples a limited number of files, so schema variations across files may be missed. (3) Detected types may not always match your desired precision (e.g., INT vs. BIGINT, FLOAT vs. DECIMAL). Always review inferred schemas before production use.

### Q4: How do you handle evolving JSON schemas in Snowflake?

**Answer:** Several strategies: (1) Load into a VARIANT column -- new keys are automatically captured without schema changes. (2) Use views with explicit key extraction that gracefully handle missing keys (returning NULL). (3) Use `STRIP_NULL_VALUES = TRUE` to avoid storing unnecessary nulls. (4) For relational targets, combine VARIANT staging with scheduled transformations that detect new keys via `OBJECT_KEYS()` or `FLATTEN` and alert or adapt. (5) Snowflake's schema evolution feature (`ENABLE_SCHEMA_EVOLUTION = TRUE` on the target table) can automatically add new columns during COPY INTO when using `MATCH_BY_COLUMN_NAME`.

### Q5: What is the maximum size for a VARIANT value, and what happens if your JSON exceeds it?

**Answer:** A single VARIANT value can hold up to **16 MB** of compressed data. If an individual JSON document exceeds this, the COPY INTO command will fail for that row. Mitigation strategies include: splitting large documents into smaller chunks before loading, normalizing deeply nested arrays into separate tables, or pre-processing files to break them down before staging.

### Q6: Compare Parquet vs. CSV for data loading into Snowflake.

**Answer:** Parquet advantages: embedded schema, columnar format enables column pruning, better compression ratios, and native support for complex types. Parquet is ideal for Snowflake's `INFER_SCHEMA` and `MATCH_BY_COLUMN_NAME`. CSV advantages: human-readable, simpler tooling, universally supported, and easier to debug. CSV is better for small, simple datasets or legacy system integrations. For modern data pipelines, Parquet is strongly preferred due to performance and reliability benefits.

---

## Tips

- **Use `MATCH_BY_COLUMN_NAME`** when loading Parquet/Avro/ORC. It matches source columns to target columns by name rather than position, which is much more resilient to schema changes.
- **Validate before loading** with `VALIDATION_MODE = 'RETURN_ERRORS'` or `'RETURN_ALL_ERRORS'` in your COPY INTO statement to preview issues without actually loading data.
- **Check `COPY_HISTORY`** in `INFORMATION_SCHEMA` or `SNOWFLAKE.ACCOUNT_USAGE` to audit load operations and troubleshoot failures.
- When querying VARIANT data, always **cast to specific types** (`::STRING`, `::INT`, `::TIMESTAMP`, etc.) -- without casting, comparisons and joins will use VARIANT comparison semantics, which can produce unexpected results.
- Use `TYPEOF()` to inspect the actual JSON type of a VARIANT value at runtime -- helpful for debugging mixed-type data.
- **OBJECT_KEYS()** returns an array of all keys in a VARIANT object -- useful for schema discovery on semi-structured data.
- For high-volume JSON ingestion, consider **Snowpipe** with auto-ingest to load files continuously as they arrive in your stage.
