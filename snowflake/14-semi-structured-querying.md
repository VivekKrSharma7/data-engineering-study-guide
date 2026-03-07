# Semi-Structured Data Querying (VARIANT, OBJECT, ARRAY)

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Overview of Semi-Structured Types](#overview-of-semi-structured-types)
2. [VARIANT Data Type](#variant-data-type)
3. [OBJECT Data Type](#object-data-type)
4. [ARRAY Data Type](#array-data-type)
5. [Accessing Data: Dot and Bracket Notation](#accessing-data-dot-and-bracket-notation)
6. [FLATTEN Function](#flatten-function)
7. [LATERAL FLATTEN Pattern](#lateral-flatten-pattern)
8. [Array Functions](#array-functions)
9. [Object Functions](#object-functions)
10. [Type Checking and Casting](#type-checking-and-casting)
11. [IS_NULL_VALUE vs IS NULL](#is_null_value-vs-is-null)
12. [Nested JSON Querying](#nested-json-querying)
13. [Schema-on-Read Patterns](#schema-on-read-patterns)
14. [Materializing Semi-Structured into Relational Columns](#materializing-semi-structured-into-relational-columns)
15. [Common Interview Questions](#common-interview-questions)
16. [Tips](#tips)

---

## Overview of Semi-Structured Types

Snowflake natively supports semi-structured data through three specialized data types. These types allow you to ingest JSON, Avro, Parquet, ORC, and XML data without requiring a predefined schema.

| Type | Description | Example |
|---|---|---|
| **VARIANT** | Can hold any data type: scalar, array, or object | `'hello'::VARIANT`, `PARSE_JSON('{"a":1}')` |
| **OBJECT** | A collection of key-value pairs (keys are strings, values are VARIANT) | `{'name': 'Alice', 'age': 30}` |
| **ARRAY** | An ordered list of VARIANT values | `[1, 2, 'three', null]` |

All three types are stored internally in an efficient columnar format. Snowflake automatically analyzes semi-structured data to extract commonly-accessed paths and store them in a columnar representation for performance (a process called **columnar auto-detection**).

---

## VARIANT Data Type

VARIANT is the universal container type. It can hold:

- Scalars: strings, numbers, booleans, null
- Objects (key-value pairs)
- Arrays (ordered lists)

### Creating VARIANT Values

```sql
-- From JSON string
SELECT PARSE_JSON('{"name": "Alice", "scores": [95, 87, 92]}') AS data;

-- From literal with casting
SELECT 42::VARIANT AS num_variant;

-- Using TO_VARIANT
SELECT TO_VARIANT('hello') AS str_variant;

-- Using OBJECT_CONSTRUCT and ARRAY_CONSTRUCT
SELECT OBJECT_CONSTRUCT('name', 'Alice', 'age', 30) AS obj;
SELECT ARRAY_CONSTRUCT(1, 2, 3) AS arr;
```

### VARIANT Column in a Table

```sql
CREATE TABLE raw_events (
    event_id INT AUTOINCREMENT,
    received_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    payload VARIANT
);

INSERT INTO raw_events (payload)
SELECT PARSE_JSON('{
    "event_type": "page_view",
    "user_id": 12345,
    "properties": {
        "page": "/home",
        "referrer": "google.com",
        "tags": ["organic", "new_user"]
    }
}');
```

### Internal Storage

Snowflake stores VARIANT data in a highly compressed columnar format. Frequently accessed paths (like `payload:event_type`) are automatically extracted into dedicated internal columns, giving near-relational performance for common query patterns. This is transparent -- you do not need to configure it.

---

## OBJECT Data Type

An OBJECT is a collection of key-value pairs. Keys are always strings; values are VARIANT.

```sql
-- Construct an OBJECT
SELECT OBJECT_CONSTRUCT(
    'first_name', 'Alice',
    'last_name',  'Smith',
    'age',        30,
    'active',     TRUE
) AS user_obj;

-- Result: {"active":true,"age":30,"first_name":"Alice","last_name":"Smith"}
-- Note: keys are sorted alphabetically in the output
```

### OBJECT_CONSTRUCT Behavior

- `NULL` values are **excluded** by default. Use `OBJECT_CONSTRUCT_KEEP_NULL` to retain them.
- Keys are always strings; non-string keys are cast to strings.

```sql
-- Keep null values
SELECT OBJECT_CONSTRUCT_KEEP_NULL(
    'name', 'Alice',
    'middle', NULL,
    'age', 30
) AS obj_with_null;
-- Result: {"age":30,"middle":null,"name":"Alice"}
```

---

## ARRAY Data Type

An ARRAY is an ordered collection of VARIANT values.

```sql
-- Construct an ARRAY
SELECT ARRAY_CONSTRUCT(1, 2, 'three', NULL, TRUE) AS arr;
-- Result: [1, 2, "three", undefined, true]

-- Note: SQL NULL in an array becomes JSON "undefined" (not JSON null)
-- To insert JSON null, use PARSE_JSON('null')
```

### Array Indexing

Arrays are 0-based:

```sql
SELECT arr[0] FROM (SELECT ARRAY_CONSTRUCT(10, 20, 30) AS arr);
-- Result: 10
```

---

## Accessing Data: Dot and Bracket Notation

### Dot Notation

Use dot notation to traverse into objects. Field names are **case-insensitive** when unquoted:

```sql
SELECT
    payload:event_type,           -- top-level key
    payload:properties.page,      -- nested key
    payload:properties.tags[0]    -- nested key then array index
FROM raw_events;
```

### Bracket Notation

Bracket notation supports dynamic key access and case-sensitive keys:

```sql
SELECT
    payload['event_type'],                      -- equivalent to dot notation
    payload['properties']['page'],              -- nested access
    payload['properties']['tags'][0],           -- nested with array
    payload['Case_Sensitive_Key']               -- preserves exact case
FROM raw_events;
```

### Key Differences

| Feature | Dot Notation | Bracket Notation |
|---|---|---|
| Case sensitivity | Case-insensitive | Case-sensitive |
| Special characters in keys | Not supported | Supported: `payload['my-key']` |
| Dynamic key names | Not supported | Supported with expressions |
| Readability | More concise | More explicit |

### Return Type

All path-access expressions return **VARIANT**. You must cast to the desired type for comparisons, joins, and aggregations:

```sql
SELECT
    payload:user_id::INT AS user_id,
    payload:event_type::STRING AS event_type,
    payload:properties.page::STRING AS page
FROM raw_events;
```

---

## FLATTEN Function

`FLATTEN` explodes a VARIANT array or object into rows. It is a **table function** and is almost always used with `LATERAL`.

### Syntax

```sql
FLATTEN(
    INPUT => <variant_expression>,
    PATH => '<optional_path>',      -- path within the input to flatten
    OUTER => TRUE | FALSE,          -- default FALSE; TRUE preserves empty/null inputs
    RECURSIVE => TRUE | FALSE,      -- default FALSE; TRUE recursively flattens nested structures
    MODE => 'OBJECT' | 'ARRAY' | 'BOTH'  -- default 'BOTH'
)
```

### Output Columns

| Column | Type | Description |
|---|---|---|
| `SEQ` | INT | Unique sequence number for each input row |
| `KEY` | VARCHAR | Object key (for objects) or NULL (for arrays) |
| `PATH` | VARCHAR | Path to the element in the source structure |
| `INDEX` | INT | Array index (0-based) or NULL (for objects) |
| `VALUE` | VARIANT | The value of the element |
| `THIS` | VARIANT | The entire structure being flattened at this level |

### Basic Example: Flatten an Array

```sql
-- Given: payload:properties.tags = ["organic", "new_user"]
SELECT
    e.event_id,
    f.index,
    f.value::STRING AS tag
FROM raw_events e,
    LATERAL FLATTEN(input => e.payload:properties.tags) f;
```

| event_id | index | tag |
|---|---|---|
| 1 | 0 | organic |
| 1 | 1 | new_user |

### Flatten an Object

```sql
-- Flatten all key-value pairs of an object
SELECT
    f.key,
    f.value
FROM TABLE(FLATTEN(input => PARSE_JSON('{"a": 1, "b": 2, "c": 3}'))) f;
```

| key | value |
|---|---|
| a | 1 |
| b | 2 |
| c | 3 |

### OUTER => TRUE

```sql
-- Without OUTER: rows with NULL/empty arrays are dropped
-- With OUTER: rows are preserved with NULL flatten columns

SELECT
    p.product_id,
    f.value::STRING AS tag
FROM products p,
    LATERAL FLATTEN(input => p.tags, OUTER => TRUE) f;

-- Products with no tags will appear with tag = NULL
```

### RECURSIVE => TRUE

Recursively flattens all nested arrays and objects into leaf-level values:

```sql
SELECT
    f.path,
    f.key,
    f.value
FROM TABLE(FLATTEN(
    input => PARSE_JSON('{
        "name": "Alice",
        "address": {
            "city": "Seattle",
            "zip": "98101"
        },
        "phones": ["555-1234", "555-5678"]
    }'),
    RECURSIVE => TRUE
)) f;
```

| path | key | value |
|---|---|---|
| name | name | "Alice" |
| address.city | city | "Seattle" |
| address.zip | zip | "98101" |
| phones[0] | | "555-1234" |
| phones[1] | | "555-5678" |

### MODE Parameter

```sql
-- Only flatten objects (skip arrays)
FLATTEN(input => data, RECURSIVE => TRUE, MODE => 'OBJECT')

-- Only flatten arrays (skip objects)
FLATTEN(input => data, RECURSIVE => TRUE, MODE => 'ARRAY')

-- Flatten both (default)
FLATTEN(input => data, RECURSIVE => TRUE, MODE => 'BOTH')
```

---

## LATERAL FLATTEN Pattern

The idiomatic Snowflake pattern for exploding semi-structured data. `LATERAL` allows `FLATTEN` to reference columns from the left-hand table.

### Standard Pattern

```sql
SELECT
    t.id,
    f.value::STRING AS element
FROM my_table t,
    LATERAL FLATTEN(input => t.variant_col:array_key) f;
```

### Multi-Level Flatten (Nested Arrays)

```sql
-- JSON: {"orders": [{"id": 1, "items": ["A", "B"]}, {"id": 2, "items": ["C"]}]}
SELECT
    raw.id,
    order_f.value:id::INT AS order_id,
    item_f.value::STRING AS item
FROM raw_data raw,
    LATERAL FLATTEN(input => raw.data:orders) order_f,
    LATERAL FLATTEN(input => order_f.value:items) item_f;
```

| id | order_id | item |
|---|---|---|
| 1 | 1 | A |
| 1 | 1 | B |
| 1 | 2 | C |

---

## Array Functions

### ARRAY_AGG

Aggregates values into an array:

```sql
SELECT
    department,
    ARRAY_AGG(employee_name) AS employees,
    ARRAY_AGG(DISTINCT employee_name) AS unique_employees
FROM employees
GROUP BY department;
```

With ordering:

```sql
SELECT
    department,
    ARRAY_AGG(employee_name) WITHIN GROUP (ORDER BY hire_date) AS employees_by_seniority
FROM employees
GROUP BY department;
```

### ARRAY_SIZE

Returns the number of elements:

```sql
SELECT ARRAY_SIZE(ARRAY_CONSTRUCT(1, 2, 3, 4));
-- Result: 4

SELECT ARRAY_SIZE(payload:properties.tags) AS tag_count
FROM raw_events;
```

### ARRAY_CONTAINS

Checks if a value exists in an array. **Note the argument order**: value first, then array.

```sql
SELECT ARRAY_CONTAINS('organic'::VARIANT, payload:properties.tags) AS has_organic
FROM raw_events;
-- Returns TRUE or FALSE
```

### Other Useful Array Functions

```sql
-- ARRAY_APPEND: add element to end
SELECT ARRAY_APPEND(ARRAY_CONSTRUCT(1, 2), 3);
-- [1, 2, 3]

-- ARRAY_PREPEND: add element to beginning
SELECT ARRAY_PREPEND(ARRAY_CONSTRUCT(2, 3), 1);
-- [1, 2, 3]

-- ARRAY_CAT: concatenate two arrays
SELECT ARRAY_CAT(ARRAY_CONSTRUCT(1, 2), ARRAY_CONSTRUCT(3, 4));
-- [1, 2, 3, 4]

-- ARRAY_COMPACT: remove NULL/undefined values
SELECT ARRAY_COMPACT(ARRAY_CONSTRUCT(1, NULL, 2, NULL, 3));
-- [1, 2, 3]

-- ARRAY_DISTINCT: remove duplicates
SELECT ARRAY_DISTINCT(ARRAY_CONSTRUCT(1, 2, 2, 3, 3, 3));
-- [1, 2, 3]

-- ARRAY_INTERSECTION: common elements
SELECT ARRAY_INTERSECTION(
    ARRAY_CONSTRUCT(1, 2, 3),
    ARRAY_CONSTRUCT(2, 3, 4)
);
-- [2, 3]

-- ARRAY_SLICE: extract sub-array (from, to)
SELECT ARRAY_SLICE(ARRAY_CONSTRUCT(10, 20, 30, 40, 50), 1, 3);
-- [20, 30]

-- ARRAYS_OVERLAP: check if arrays share any element
SELECT ARRAYS_OVERLAP(
    ARRAY_CONSTRUCT(1, 2),
    ARRAY_CONSTRUCT(2, 3)
);
-- TRUE

-- ARRAY_TO_STRING: join array elements into a string
SELECT ARRAY_TO_STRING(ARRAY_CONSTRUCT('a', 'b', 'c'), ', ');
-- 'a, b, c'
```

---

## Object Functions

### OBJECT_KEYS

Returns an array of all keys in an object:

```sql
SELECT OBJECT_KEYS(PARSE_JSON('{"name": "Alice", "age": 30, "city": "Seattle"}'));
-- ["age", "city", "name"]  (alphabetically sorted)
```

### GET

Retrieves a value from a VARIANT object by key or from an array by index:

```sql
SELECT GET(PARSE_JSON('{"a": 1, "b": 2}'), 'a');
-- 1

-- GET is equivalent to bracket notation:
SELECT payload['event_type'] FROM raw_events;
-- same as: SELECT GET(payload, 'event_type') FROM raw_events;
```

### GET_PATH / :

Retrieves a value at a specified path:

```sql
SELECT GET_PATH(payload, 'properties.page') FROM raw_events;
-- Equivalent to: payload:properties.page
```

This is useful when the path is dynamic (stored in a variable or column).

### Other Object Functions

```sql
-- OBJECT_INSERT: add or update a key-value pair
SELECT OBJECT_INSERT(
    PARSE_JSON('{"a": 1, "b": 2}'),
    'c',
    3
);
-- {"a": 1, "b": 2, "c": 3}

-- OBJECT_INSERT with overwrite (4th param TRUE)
SELECT OBJECT_INSERT(
    PARSE_JSON('{"a": 1, "b": 2}'),
    'a',
    99,
    TRUE
);
-- {"a": 99, "b": 2}

-- OBJECT_DELETE: remove a key
SELECT OBJECT_DELETE(
    PARSE_JSON('{"a": 1, "b": 2, "c": 3}'),
    'b'
);
-- {"a": 1, "c": 3}

-- OBJECT_PICK: select specific keys
SELECT OBJECT_PICK(
    PARSE_JSON('{"a": 1, "b": 2, "c": 3}'),
    'a', 'c'
);
-- {"a": 1, "c": 3}
```

---

## Type Checking and Casting

### TYPEOF

Returns the type of a VARIANT value as a string:

```sql
SELECT
    TYPEOF(PARSE_JSON('42')),          -- 'INTEGER'
    TYPEOF(PARSE_JSON('"hello"')),     -- 'VARCHAR'
    TYPEOF(PARSE_JSON('true')),        -- 'BOOLEAN'
    TYPEOF(PARSE_JSON('null')),        -- 'NULL_VALUE'
    TYPEOF(PARSE_JSON('[1,2]')),       -- 'ARRAY'
    TYPEOF(PARSE_JSON('{"a":1}')),     -- 'OBJECT'
    TYPEOF(PARSE_JSON('3.14'));        -- 'DECIMAL'
```

### Casting from VARIANT

VARIANT values must be cast to relational types for most operations:

```sql
SELECT
    payload:user_id::INT AS user_id,
    payload:event_type::STRING AS event_type,
    payload:timestamp::TIMESTAMP_NTZ AS event_ts,
    payload:amount::FLOAT AS amount,
    payload:is_active::BOOLEAN AS is_active
FROM raw_events;
```

### Casting Methods

```sql
-- Double-colon syntax (most common)
payload:name::STRING

-- CAST function
CAST(payload:name AS STRING)

-- TRY_CAST (returns NULL instead of error on failure)
TRY_CAST(payload:age AS INT)

-- Specific conversion functions
TO_VARCHAR(payload:name)
TO_NUMBER(payload:amount)
TO_TIMESTAMP(payload:ts)
TRY_TO_NUMBER(payload:amount)  -- safe version
```

---

## IS_NULL_VALUE vs IS NULL

This is a critical distinction in Snowflake semi-structured data querying.

### The Two Kinds of "Null"

1. **SQL NULL** -- the key is **missing** from the JSON object entirely.
2. **JSON null** -- the key **exists** but its value is explicitly `null`.

```sql
-- Consider this JSON:
-- {"name": "Alice", "middle_name": null}

-- "name" exists and has a value
-- "middle_name" exists but is JSON null
-- "nickname" does not exist at all (SQL NULL)
```

### Behavior

```sql
WITH test AS (
    SELECT PARSE_JSON('{"name": "Alice", "middle_name": null}') AS data
)
SELECT
    data:name IS NULL,           -- FALSE (has a value)
    data:middle_name IS NULL,    -- FALSE! (key exists, JSON null is not SQL NULL)
    data:nickname IS NULL,        -- TRUE (key is missing -> SQL NULL)

    IS_NULL_VALUE(data:name),          -- FALSE
    IS_NULL_VALUE(data:middle_name),   -- TRUE (detects JSON null)
    IS_NULL_VALUE(data:nickname)       -- FALSE! (key is missing, not JSON null)
FROM test;
```

### Summary Table

| Expression | Key exists, has value | Key exists, JSON null | Key missing |
|---|---|---|---|
| `IS NULL` | FALSE | FALSE | **TRUE** |
| `IS_NULL_VALUE()` | FALSE | **TRUE** | FALSE |

### Checking for Both

To check if a field is either missing or JSON null:

```sql
WHERE data:field IS NULL OR IS_NULL_VALUE(data:field)

-- Or equivalently:
WHERE data:field::STRING IS NULL
-- Casting JSON null to STRING yields SQL NULL
```

---

## Nested JSON Querying

### Deep Path Access

```sql
-- Deeply nested JSON
SELECT
    payload:user.profile.address.city::STRING AS city,
    payload:user.profile.preferences.notifications.email::BOOLEAN AS email_notif,
    payload:user.profile.scores[0]::INT AS first_score
FROM events;
```

### Combining Flatten with Nested Access

```sql
-- JSON: {"user": "Alice", "orders": [
--   {"id": 1, "items": [{"sku": "A", "qty": 2}, {"sku": "B", "qty": 1}]},
--   {"id": 2, "items": [{"sku": "C", "qty": 5}]}
-- ]}

SELECT
    raw.data:user::STRING AS user_name,
    o.value:id::INT AS order_id,
    i.value:sku::STRING AS sku,
    i.value:qty::INT AS qty
FROM raw_table raw,
    LATERAL FLATTEN(input => raw.data:orders) o,
    LATERAL FLATTEN(input => o.value:items) i;
```

### Dynamic Key Access

When keys are not known ahead of time, use OBJECT_KEYS + FLATTEN:

```sql
-- Pivot all keys in a JSON object into rows
SELECT
    t.id,
    kv.key,
    kv.value::STRING AS val
FROM my_table t,
    LATERAL FLATTEN(input => t.data) kv;
```

### Handling Arrays of Varying Depth

```sql
-- Some elements are scalars, some are nested objects
SELECT
    f.path,
    f.key,
    TYPEOF(f.value) AS val_type,
    CASE
        WHEN TYPEOF(f.value) IN ('OBJECT', 'ARRAY') THEN 'complex'
        ELSE f.value::STRING
    END AS val
FROM TABLE(FLATTEN(input => PARSE_JSON('{
    "a": 1,
    "b": {"c": 2},
    "d": [3, 4]
}'), RECURSIVE => TRUE)) f;
```

---

## Schema-on-Read Patterns

Schema-on-read means storing raw semi-structured data and applying structure at query time rather than at ingestion.

### Raw Ingestion Pattern

```sql
-- Stage 1: Land raw JSON into a single VARIANT column
CREATE TABLE raw_events (
    load_id INT AUTOINCREMENT,
    loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    src_file VARCHAR,
    raw VARIANT
);

-- Load from stage
COPY INTO raw_events (src_file, raw)
FROM @my_stage
FILE_FORMAT = (TYPE = 'JSON')
ON_ERROR = 'CONTINUE';
```

### Query-Time Structuring with Views

```sql
-- Stage 2: Create a view that projects relational columns from raw JSON
CREATE OR REPLACE VIEW v_events AS
SELECT
    load_id,
    loaded_at,
    raw:event_id::STRING AS event_id,
    raw:event_type::STRING AS event_type,
    raw:user_id::INT AS user_id,
    raw:timestamp::TIMESTAMP_NTZ AS event_ts,
    raw:properties::VARIANT AS properties,
    raw:properties.page::STRING AS page,
    raw:properties.referrer::STRING AS referrer
FROM raw_events;
```

### Benefits of Schema-on-Read

| Benefit | Explanation |
|---|---|
| **Fast ingestion** | No transformation needed at load time |
| **Schema evolution** | New fields appear automatically; old queries still work |
| **No data loss** | All fields are preserved, even unexpected ones |
| **Flexibility** | Different consumers can interpret the data differently |

### Drawbacks

| Drawback | Explanation |
|---|---|
| **Query complexity** | Every query must handle casting and path navigation |
| **Performance** | Deeper paths may not benefit from columnar auto-detection |
| **Data quality** | Errors surface at query time, not ingestion time |

---

## Materializing Semi-Structured into Relational Columns

For performance-critical or frequently accessed data, materialize semi-structured data into relational tables.

### CTAS Approach

```sql
CREATE TABLE events_structured AS
SELECT
    raw:event_id::STRING AS event_id,
    raw:event_type::STRING AS event_type,
    raw:user_id::INT AS user_id,
    raw:timestamp::TIMESTAMP_NTZ AS event_ts,
    raw:properties.page::STRING AS page,
    raw:properties.referrer::STRING AS referrer,
    raw:properties.tags AS tags_array  -- keep as VARIANT for flexible querying
FROM raw_events;
```

### Hybrid Pattern (Relational + Raw)

A common best practice is to extract the most-used fields into relational columns while keeping the full raw payload for ad-hoc analysis:

```sql
CREATE TABLE events_hybrid (
    event_id STRING,
    event_type STRING,
    user_id INT,
    event_ts TIMESTAMP_NTZ,
    page STRING,
    -- Keep the original for flexibility
    raw_payload VARIANT
);

INSERT INTO events_hybrid
SELECT
    raw:event_id::STRING,
    raw:event_type::STRING,
    raw:user_id::INT,
    raw:timestamp::TIMESTAMP_NTZ,
    raw:properties.page::STRING,
    raw
FROM raw_events;
```

### Materialized Views (Limited Semi-Structured Support)

Snowflake materialized views support some semi-structured access patterns. However, they have restrictions (e.g., no FLATTEN, limited function support). For complex transformations, use scheduled tasks with CTAS or MERGE instead.

### Automated Column Detection

When loading Parquet, Avro, or ORC data, Snowflake can **auto-detect the schema** and create relational columns automatically:

```sql
-- Detect schema from staged files
SELECT *
FROM TABLE(INFER_SCHEMA(
    LOCATION => '@my_stage',
    FILE_FORMAT => 'my_parquet_format'
));

-- Create table matching the detected schema
CREATE TABLE my_table
USING TEMPLATE (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
    FROM TABLE(INFER_SCHEMA(
        LOCATION => '@my_stage',
        FILE_FORMAT => 'my_parquet_format'
    ))
);
```

---

## Common Interview Questions

### Q1: What are the three semi-structured data types in Snowflake?

**A:** VARIANT, OBJECT, and ARRAY. VARIANT is the universal container that can hold any value (scalar, object, or array). OBJECT is a collection of key-value pairs (string keys, VARIANT values). ARRAY is an ordered list of VARIANT values. In practice, VARIANT is the most commonly used because it can hold any of the other types, and JSON data loaded into Snowflake typically goes into a VARIANT column.

### Q2: Explain the difference between IS NULL and IS_NULL_VALUE for VARIANT data.

**A:** This is a subtle but important distinction:
- `expr IS NULL` returns TRUE when the key is **missing entirely** from the JSON object (SQL NULL).
- `IS_NULL_VALUE(expr)` returns TRUE when the key **exists** but its value is the JSON literal `null`.

For example, given `{"name": "Alice", "middle": null}`, the field `middle` is JSON null (`IS_NULL_VALUE` returns TRUE, `IS NULL` returns FALSE), while a non-existent field like `suffix` is SQL NULL (`IS NULL` returns TRUE, `IS_NULL_VALUE` returns FALSE). A practical way to check for both is to cast to a concrete type: `field::STRING IS NULL` will be TRUE in both cases.

### Q3: How does FLATTEN work and what columns does it produce?

**A:** FLATTEN is a table function that explodes a VARIANT array or object into individual rows. It produces six columns: `SEQ` (sequence number per input row), `KEY` (object key name or NULL for arrays), `PATH` (path to the element), `INDEX` (0-based array index or NULL for objects), `VALUE` (the element as VARIANT), and `THIS` (the structure being flattened). Key parameters include `OUTER` (preserves rows with NULL/empty input), `RECURSIVE` (deeply flattens nested structures), and `MODE` (OBJECT, ARRAY, or BOTH).

### Q4: What is the LATERAL FLATTEN pattern and why is it so common?

**A:** LATERAL FLATTEN is the standard Snowflake idiom for exploding semi-structured columns. `LATERAL` allows the FLATTEN table function to reference a column from the left-hand table in the FROM clause. Without LATERAL, FLATTEN cannot access columns from other tables in the query. The pattern is:
```sql
SELECT t.id, f.value
FROM my_table t, LATERAL FLATTEN(input => t.variant_col:array_key) f;
```
It is ubiquitous because JSON/array data is extremely common in modern data pipelines.

### Q5: How do you handle schema evolution with semi-structured data?

**A:** Schema-on-read is the primary approach: store raw JSON in a VARIANT column and apply structure at query time using views. When the source schema changes (new fields added, fields removed), the raw data automatically contains the changes. Views can be updated to expose new fields, and existing queries referencing old fields continue to work. For downstream consumption, a hybrid table pattern (relational columns for common fields + raw VARIANT column for everything else) provides both performance and flexibility.

### Q6: Does Snowflake automatically optimize semi-structured data?

**A:** Yes. Snowflake performs **columnar auto-detection** on VARIANT data during ingestion. It statistically analyzes the data to identify commonly occurring paths and their types, then extracts those paths into dedicated columnar storage. This means queries filtering on frequently accessed paths (e.g., `WHERE data:event_type::STRING = 'click'`) can benefit from pruning and columnar performance without any user intervention. However, very deeply nested or rarely accessed paths may not be auto-detected, in which case materialization into relational columns is recommended.

### Q7: How do you aggregate data back into an array or object after flattening?

**A:** Use `ARRAY_AGG` to reconstruct arrays and `OBJECT_AGG` to reconstruct objects:

```sql
-- Reconstruct an array
SELECT customer_id, ARRAY_AGG(order_id) AS order_ids
FROM orders
GROUP BY customer_id;

-- Reconstruct an object
SELECT customer_id, OBJECT_AGG(key, value) AS properties
FROM customer_attrs
GROUP BY customer_id;
```

### Q8: What is the difference between dot notation and bracket notation?

**A:** Dot notation (`data:key.subkey`) is concise but case-insensitive and cannot handle keys with special characters (spaces, hyphens, etc.). Bracket notation (`data['Key']['sub-key']`) is case-sensitive and supports special characters and dynamic key names. Both return VARIANT. Use bracket notation when keys have special characters or when case sensitivity matters.

### Q9: How would you query the keys of a JSON object without knowing them in advance?

**A:** Use `OBJECT_KEYS()` to get an array of keys, or `FLATTEN` to explode the object into key-value rows:

```sql
-- Get keys as an array
SELECT OBJECT_KEYS(data) FROM my_table;

-- Explode into rows
SELECT f.key, f.value
FROM my_table t, LATERAL FLATTEN(input => t.data) f;
```

### Q10: Why should you cast VARIANT values when using them in WHERE, JOIN, or GROUP BY?

**A:** VARIANT comparisons use generic comparison rules that may not match the behavior of native types. For example, VARIANT string `"42"` and VARIANT integer `42` are not equal in VARIANT comparison. Casting ensures type-appropriate comparisons, enables predicate pushdown for pruning, and avoids subtle bugs. Additionally, joins on VARIANT values are slower than joins on native types because the optimizer cannot use the same optimizations.

---

## Tips

1. **Always cast VARIANT to native types** in your final SELECT, WHERE, JOIN, and GROUP BY clauses. This improves performance, enables pruning, and prevents type-mismatch bugs.

2. **Use OUTER => TRUE in FLATTEN** when you need to preserve rows that have NULL or empty arrays. Forgetting this is a common source of silently dropped rows.

3. **Understand IS_NULL_VALUE vs IS NULL** -- this is one of the most commonly asked Snowflake interview questions. The casting trick (`field::STRING IS NULL`) handles both cases.

4. **Favor the hybrid table pattern** for production pipelines: extract frequently queried fields into relational columns, keep the raw VARIANT for ad-hoc analysis and future field discovery.

5. **Use INFER_SCHEMA for Parquet/Avro/ORC** -- Snowflake can auto-detect and create the table schema, saving manual column definition.

6. **ARRAY_CONTAINS argument order** is value-first, array-second. This trips up many people: `ARRAY_CONTAINS(value::VARIANT, array_col)`.

7. **Recursive FLATTEN** is powerful for exploring unknown JSON structures. Combine it with `TYPEOF` to identify all leaf paths and their types across your dataset.

8. **OBJECT_CONSTRUCT omits NULLs** by default. Use `OBJECT_CONSTRUCT_KEEP_NULL` when you need to preserve null values in generated JSON output.

9. **Schema-on-read is not zero cost** -- while flexible, it pushes all transformation logic to query time. For high-frequency queries, materialize the data.

10. **Test with edge cases**: empty arrays (`[]`), JSON null vs missing keys, nested nulls, and mixed types within the same array. These are common sources of production bugs.

---
