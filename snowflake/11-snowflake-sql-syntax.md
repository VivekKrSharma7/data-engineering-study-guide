# Snowflake SQL Syntax & Differences from ANSI SQL

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### Snowflake SQL Overview

Snowflake supports ANSI SQL with numerous extensions and some behavioral differences from other platforms like SQL Server, PostgreSQL, Oracle, and MySQL. Understanding these differences is critical for data engineers migrating workloads or working across platforms.

---

### Case Sensitivity and Identifier Handling

This is one of the most common sources of confusion in Snowflake.

**Rules:**
- **Unquoted identifiers** are stored and resolved as **UPPERCASE**. Writing `my_table` is the same as `MY_TABLE`.
- **Double-quoted identifiers** preserve exact case and allow special characters. `"my_table"` is different from `MY_TABLE`.
- Once you create an object with double quotes and lowercase letters, you must **always** use double quotes to reference it.

```sql
-- These are all the same object
CREATE TABLE my_table (id INT);
SELECT * FROM my_table;
SELECT * FROM MY_TABLE;
SELECT * FROM My_Table;

-- This is a DIFFERENT object (lowercase, case-preserved)
CREATE TABLE "my_table" (id INT);
SELECT * FROM "my_table";  -- Works
SELECT * FROM my_table;     -- References the UPPERCASE version, NOT the quoted one
```

**Best practice:** Avoid double-quoted identifiers unless absolutely necessary. Use UPPERCASE or snake_case (which Snowflake normalizes to uppercase) consistently.

---

### QUALIFY Clause

The `QUALIFY` clause filters the result of window functions, analogous to how `HAVING` filters aggregates. This is a Snowflake extension (also supported by some other platforms like Teradata and BigQuery).

```sql
-- Without QUALIFY (subquery required)
SELECT * FROM (
  SELECT
    employee_id,
    department,
    salary,
    ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS rn
  FROM employees
) sub
WHERE rn = 1;

-- With QUALIFY (clean and concise)
SELECT
  employee_id,
  department,
  salary
FROM employees
QUALIFY ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) = 1;
```

**QUALIFY works with any window function** -- not just `ROW_NUMBER()`:

```sql
-- Keep rows where running total exceeds 10000
SELECT
  order_date,
  amount,
  SUM(amount) OVER (ORDER BY order_date) AS running_total
FROM orders
QUALIFY SUM(amount) OVER (ORDER BY order_date) > 10000;
```

**Clause evaluation order:** `FROM` -> `WHERE` -> `GROUP BY` -> `HAVING` -> `WINDOW` -> `QUALIFY` -> `ORDER BY` -> `LIMIT`

---

### SAMPLE / TABLESAMPLE

Snowflake supports sampling directly in the FROM clause for quick data exploration.

```sql
-- Row-based sampling: ~10% of rows (Bernoulli method)
SELECT * FROM large_table SAMPLE (10);

-- Block-based sampling: ~10% of micro-partitions (faster, less precise)
SELECT * FROM large_table SAMPLE BLOCK (10);

-- Fixed row count: exactly 100 rows
SELECT * FROM large_table SAMPLE (100 ROWS);

-- Repeatable sampling with a seed
SELECT * FROM large_table SAMPLE (10) SEED (42);

-- TABLESAMPLE is an alias for SAMPLE
SELECT * FROM large_table TABLESAMPLE (5);
```

---

### FLATTEN Function

`FLATTEN` explodes VARIANT arrays or objects into rows. It is one of the most important functions for working with semi-structured data.

```sql
-- Basic array flattening
SELECT
  f.seq,        -- Sequence number (unique per input row)
  f.key,        -- Key (for objects) or NULL (for arrays)
  f.path,       -- Path to the element
  f.index,      -- Array index (0-based) or NULL
  f.value,      -- The actual value
  f.this         -- The element being flattened
FROM TABLE(FLATTEN(input => PARSE_JSON('["a","b","c"]'))) f;

-- Flatten with LATERAL for table data
SELECT
  o.order_id,
  item.value:product::STRING AS product,
  item.value:qty::INT AS qty
FROM orders o,
  LATERAL FLATTEN(input => o.line_items) item;

-- Recursive flattening for deeply nested structures
SELECT
  f.path,
  f.key,
  f.value
FROM TABLE(FLATTEN(
  input => PARSE_JSON('{"a":{"b":{"c":1}}}'),
  RECURSIVE => TRUE
)) f;

-- Flatten with OUTER => TRUE to preserve rows with empty/null arrays
SELECT
  o.order_id,
  f.value:tag::STRING AS tag
FROM orders o,
  LATERAL FLATTEN(input => o.tags, OUTER => TRUE) f;
```

**FLATTEN parameters:**
- `INPUT`: The VARIANT expression to flatten
- `PATH`: Optional path within the input to flatten
- `OUTER`: If TRUE, produces a row even when input is empty/null (like LEFT JOIN)
- `RECURSIVE`: If TRUE, flattens all nested levels
- `MODE`: `'OBJECT'`, `'ARRAY'`, or `'BOTH'` (default)

---

### GENERATOR Function

`GENERATOR` produces rows without a source table -- useful for creating sequences, date spines, and test data.

```sql
-- Generate 1000 rows
SELECT SEQ4() AS row_num
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

-- Generate a date spine
SELECT
  DATEADD('day', SEQ4(), '2024-01-01'::DATE) AS calendar_date
FROM TABLE(GENERATOR(ROWCOUNT => 366))
ORDER BY calendar_date;

-- Generate test data with random values
SELECT
  SEQ4() AS id,
  UNIFORM(1, 100, RANDOM())::INT AS random_int,
  UUID_STRING() AS unique_id,
  DATEADD('second', UNIFORM(0, 86400*365, RANDOM()), '2024-01-01'::TIMESTAMP) AS random_ts
FROM TABLE(GENERATOR(ROWCOUNT => 10000));

-- Time-based generation (generates rows for N seconds of wall clock time)
SELECT COUNT(*)
FROM TABLE(GENERATOR(TIMELIMIT => 1));
```

---

### OBJECT_CONSTRUCT, ARRAY_CONSTRUCT, and PARSE_JSON

These functions create and manipulate semi-structured data.

```sql
-- Build a JSON object from columns
SELECT OBJECT_CONSTRUCT(
  'id', employee_id,
  'name', first_name || ' ' || last_name,
  'department', department,
  'salary', salary
) AS employee_json
FROM employees;

-- OBJECT_CONSTRUCT automatically omits NULL values
SELECT OBJECT_CONSTRUCT('a', 1, 'b', NULL, 'c', 3);
-- Result: {"a": 1, "c": 3}

-- Use OBJECT_CONSTRUCT_KEEP_NULL to retain NULLs
SELECT OBJECT_CONSTRUCT_KEEP_NULL('a', 1, 'b', NULL, 'c', 3);
-- Result: {"a": 1, "b": null, "c": 3}

-- Build a JSON object from all columns using *
SELECT OBJECT_CONSTRUCT(*) FROM employees LIMIT 5;

-- Build an array
SELECT ARRAY_CONSTRUCT(1, 2, 3, 4, 5) AS my_array;

-- Aggregate into an array
SELECT
  department,
  ARRAY_AGG(employee_name) AS team_members
FROM employees
GROUP BY department;

-- Aggregate into an object
SELECT
  OBJECT_AGG(key_column, value_column) AS config_map
FROM config_table;

-- Parse a JSON string
SELECT PARSE_JSON('{"key": "value", "num": 42}') AS parsed;
```

---

### TRY_ Functions (Safe Casting and Conversion)

Snowflake provides `TRY_` variants of conversion functions that return NULL instead of raising an error on invalid input.

```sql
-- Standard CAST raises an error on bad data
SELECT CAST('not_a_number' AS INT);  -- ERROR

-- TRY_CAST returns NULL
SELECT TRY_CAST('not_a_number' AS INT);  -- NULL

-- TRY_ variants of common functions
SELECT TRY_TO_NUMBER('$1,234.56');      -- NULL (invalid format)
SELECT TRY_TO_NUMBER('1234.56');        -- 1234.56
SELECT TRY_TO_DATE('2024-13-01');       -- NULL (invalid month)
SELECT TRY_TO_DATE('2024-01-15');       -- 2024-01-15
SELECT TRY_TO_TIMESTAMP('not a date');  -- NULL
SELECT TRY_TO_BOOLEAN('maybe');         -- NULL
SELECT TRY_TO_DECIMAL('abc', 10, 2);   -- NULL

-- Real-world use: data quality checks
SELECT
  raw_value,
  TRY_TO_NUMBER(raw_value) AS parsed_number,
  CASE WHEN TRY_TO_NUMBER(raw_value) IS NULL THEN 'INVALID' ELSE 'VALID' END AS status
FROM raw_data;

-- TRY_PARSE_JSON for safe JSON parsing
SELECT TRY_PARSE_JSON('invalid json {');  -- NULL instead of error
```

---

### IDENTIFIER() Function

`IDENTIFIER()` resolves a string expression to an object identifier at runtime, enabling dynamic SQL patterns in views and functions.

```sql
-- Use a session variable as a table name
SET my_table = 'SALES.PUBLIC.ORDERS';
SELECT * FROM IDENTIFIER($my_table) LIMIT 10;

-- Use in a dynamic context
SET target_col = 'REVENUE';
SELECT IDENTIFIER($target_col) FROM sales_summary;

-- Useful in stored procedures for dynamic table references
CREATE OR REPLACE PROCEDURE process_table(table_name STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
  CREATE OR REPLACE TABLE results AS
    SELECT * FROM IDENTIFIER(:table_name) WHERE status = 'ACTIVE';
  RETURN 'Done';
END;
$$;
```

---

### Date/Time Handling Differences

Snowflake date/time behavior differs from many other platforms.

```sql
-- Snowflake timestamp types
-- TIMESTAMP_NTZ: No time zone (default TIMESTAMP type, configurable)
-- TIMESTAMP_LTZ: Local time zone (uses session time zone)
-- TIMESTAMP_TZ: Stores time zone with the value

-- The TIMESTAMP_TYPE_MAPPING parameter controls which type TIMESTAMP resolves to
ALTER SESSION SET TIMESTAMP_TYPE_MAPPING = 'TIMESTAMP_NTZ';

-- Date arithmetic
SELECT
  CURRENT_DATE()                                    AS today,
  DATEADD('day', 7, CURRENT_DATE())                AS next_week,
  DATEADD('month', -3, CURRENT_DATE())             AS three_months_ago,
  DATEDIFF('day', '2024-01-01', '2024-12-31')      AS days_between,
  DATEDIFF('month', '2024-01-15', '2024-04-15')    AS months_between,
  DATE_TRUNC('month', CURRENT_DATE())              AS first_of_month,
  LAST_DAY(CURRENT_DATE())                         AS last_of_month,
  LAST_DAY(CURRENT_DATE(), 'week')                 AS last_day_of_week;

-- Date parts
SELECT
  YEAR(CURRENT_TIMESTAMP())       AS yr,
  MONTH(CURRENT_TIMESTAMP())      AS mo,
  DAY(CURRENT_TIMESTAMP())        AS dy,
  DAYOFWEEK(CURRENT_DATE())       AS dow,    -- 0=Sunday in Snowflake (configurable)
  DAYOFYEAR(CURRENT_DATE())       AS doy,
  WEEKOFYEAR(CURRENT_DATE())      AS woy,
  QUARTER(CURRENT_DATE())         AS qtr;

-- Key difference from SQL Server:
-- Snowflake uses DATEADD/DATEDIFF with string part names, not datepart keywords
-- SQL Server: DATEADD(dd, 7, GETDATE())
-- Snowflake: DATEADD('day', 7, CURRENT_DATE())

-- TO_CHAR for formatting (similar to Oracle)
SELECT TO_CHAR(CURRENT_TIMESTAMP(), 'YYYY-MM-DD HH24:MI:SS.FF3 TZH:TZM');

-- TO_DATE / TO_TIMESTAMP for parsing
SELECT TO_DATE('15/03/2024', 'DD/MM/YYYY');
SELECT TO_TIMESTAMP('2024-03-15 14:30:00', 'YYYY-MM-DD HH24:MI:SS');
```

---

### String Functions

```sql
-- Snowflake string functions vs other platforms
SELECT
  -- Concatenation (use || operator, not + like SQL Server)
  first_name || ' ' || last_name                    AS full_name,
  CONCAT(first_name, ' ', last_name)                AS full_name_alt,

  -- Substring (1-based indexing)
  SUBSTR('Hello World', 1, 5)                        AS sub,         -- 'Hello'
  LEFT('Hello World', 5)                             AS left_part,   -- 'Hello'
  RIGHT('Hello World', 5)                            AS right_part,  -- 'World'

  -- Position finding
  POSITION('World' IN 'Hello World')                 AS pos,         -- 7
  CHARINDEX('World', 'Hello World')                  AS char_idx,    -- 7 (SQL Server compat)

  -- Case
  UPPER('hello'),                                                     -- 'HELLO'
  LOWER('HELLO'),                                                     -- 'hello'
  INITCAP('hello world'),                                             -- 'Hello World'

  -- Trimming
  TRIM('  hello  '),                                                  -- 'hello'
  LTRIM('  hello'),                                                   -- 'hello'
  RTRIM('hello  '),                                                   -- 'hello'

  -- Padding
  LPAD('42', 5, '0'),                                                -- '00042'
  RPAD('hi', 5, '.'),                                                -- 'hi...'

  -- Replacement
  REPLACE('foo-bar-baz', '-', '_'),                                  -- 'foo_bar_baz'
  TRANSLATE('abc123', 'abc', 'xyz'),                                 -- 'xyz123'

  -- Split
  SPLIT('a,b,c,d', ','),                                            -- Array: ["a","b","c","d"]
  SPLIT_PART('a.b.c.d', '.', 2),                                    -- 'b'

  -- Length
  LENGTH('Hello'),                                                    -- 5

  -- Repeat
  REPEAT('ab', 3),                                                   -- 'ababab'

  -- Reverse
  REVERSE('hello');                                                   -- 'olleh'

-- STRTOK_TO_ARRAY: Split string into an array
SELECT STRTOK_TO_ARRAY('one|two|three', '|');

-- LISTAGG: Aggregate strings (equivalent to STRING_AGG in SQL Server)
SELECT
  department,
  LISTAGG(employee_name, ', ') WITHIN GROUP (ORDER BY employee_name) AS team
FROM employees
GROUP BY department;
```

---

### Regular Expressions

Snowflake provides comprehensive regex support using POSIX-based regular expressions.

```sql
-- REGEXP_LIKE: Test if a string matches a pattern (returns BOOLEAN)
SELECT *
FROM customers
WHERE REGEXP_LIKE(email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$');

-- RLIKE is an alias for REGEXP_LIKE
SELECT * FROM products WHERE RLIKE(product_code, '^[A-Z]{3}-[0-9]{4}$');

-- REGEXP_REPLACE: Replace pattern matches
SELECT REGEXP_REPLACE('Phone: (555) 123-4567', '[^0-9]', '') AS digits_only;
-- Result: '5551234567'

SELECT REGEXP_REPLACE('John   Smith', '\\s+', ' ') AS cleaned;
-- Result: 'John Smith'

-- REGEXP_SUBSTR: Extract matching substring
SELECT REGEXP_SUBSTR('Order #12345 placed on 2024-01-15', '[0-9]{4}-[0-9]{2}-[0-9]{2}');
-- Result: '2024-01-15'

-- Extract with group capture (6th parameter = group number)
SELECT REGEXP_SUBSTR('name: John, age: 30', 'name: (\\w+)', 1, 1, 'e', 1);
-- Result: 'John'

-- REGEXP_COUNT: Count matches
SELECT REGEXP_COUNT('aaabbbccc', 'a');
-- Result: 3

-- REGEXP_INSTR: Position of match
SELECT REGEXP_INSTR('hello world 123', '[0-9]+');
-- Result: 13

-- Regex parameters:
-- 'c' = case-sensitive (default)
-- 'i' = case-insensitive
-- 'm' = multi-line mode
-- 's' = dotall (. matches newline)
-- 'e' = extract submatches

SELECT * FROM logs WHERE REGEXP_LIKE(message, 'error|warning|critical', 'i');
```

---

### COLLATION and String Comparison

Collation controls how strings are compared and sorted.

```sql
-- Default collation is based on UTF-8 binary comparison
-- This means 'a' > 'Z' (lowercase letters have higher code points)

-- Specify collation for case-insensitive comparison
SELECT 'abc' = 'ABC';                                    -- FALSE (default)
SELECT COLLATE('abc', 'en-ci') = COLLATE('ABC', 'en-ci'); -- TRUE

-- Set collation at column level
CREATE TABLE ci_table (
  name VARCHAR COLLATE 'en-ci'  -- case-insensitive
);

-- Common collation specifiers:
-- 'en'       : English, case-sensitive, accent-sensitive
-- 'en-ci'    : English, case-insensitive
-- 'en-ci-ai' : English, case-insensitive, accent-insensitive

-- Collation affects ORDER BY, GROUP BY, DISTINCT, and comparisons
SELECT DISTINCT COLLATE(name, 'en-ci') AS name
FROM users;
```

---

### Key Differences from SQL Server and Other Platforms

| Feature | Snowflake | SQL Server | PostgreSQL |
|---------|-----------|------------|------------|
| String concat | `\|\|` or `CONCAT()` | `+` | `\|\|` |
| Identity column | `AUTOINCREMENT` or `IDENTITY` | `IDENTITY` | `SERIAL` / `GENERATED` |
| Top N rows | `LIMIT N` | `TOP N` | `LIMIT N` |
| Current time | `CURRENT_TIMESTAMP()` | `GETDATE()` / `SYSDATETIME()` | `NOW()` |
| IF NULL | `IFNULL()` / `NVL()` / `COALESCE()` | `ISNULL()` / `COALESCE()` | `COALESCE()` |
| String agg | `LISTAGG()` | `STRING_AGG()` | `STRING_AGG()` |
| Temp tables | `CREATE TEMPORARY TABLE` | `#table_name` | `CREATE TEMP TABLE` |
| MERGE | Full ANSI MERGE | Full MERGE | `INSERT ON CONFLICT` |
| QUALIFY | Supported natively | Not supported | Not supported |
| Regex | `REGEXP_LIKE()` etc. | Limited (LIKE, PATINDEX) | `~`, `~*`, `SIMILAR TO` |
| Lateral join | `LATERAL` keyword | `CROSS APPLY` / `OUTER APPLY` | `LATERAL` keyword |
| JSON access | `:` and `.` notation | `JSON_VALUE()`, `OPENJSON()` | `->`, `->>` operators |
| Division | Integer division truncates | Integer division truncates | Integer division truncates |
| Boolean type | `BOOLEAN` (native) | `BIT` | `BOOLEAN` |
| Stored procedures | JavaScript, Python, SQL, Scala, Java | T-SQL | PL/pgSQL |

---

### Double-Quote Behavior: A Deeper Look

```sql
-- DANGER: ORMs and tools often generate double-quoted identifiers
-- If created quoted, must always be referenced quoted

-- This creates column "Revenue" (mixed case, stored as-is)
CREATE TABLE bad_example ("Revenue" INT, "Customer Name" VARCHAR);

-- Now you MUST use:
SELECT "Revenue", "Customer Name" FROM bad_example;

-- This will FAIL (Snowflake looks for uppercase REVENUE):
-- SELECT Revenue FROM bad_example;

-- To avoid this, always use unquoted or all-uppercase identifiers
CREATE TABLE good_example (REVENUE INT, CUSTOMER_NAME VARCHAR);

-- Check existing double-quoted identifiers
SHOW COLUMNS IN TABLE my_schema.my_table;
-- Look at "column_name" in the output for case mismatches
```

---

## Real-World Examples

### Example 1: Dynamic Date Spine with GENERATOR

```sql
-- Create a reusable date dimension using GENERATOR
CREATE OR REPLACE TABLE dim_date AS
WITH date_spine AS (
  SELECT
    DATEADD('day', SEQ4(), '2020-01-01'::DATE) AS calendar_date
  FROM TABLE(GENERATOR(ROWCOUNT => 3653))  -- ~10 years
)
SELECT
  calendar_date,
  YEAR(calendar_date)                                           AS year,
  QUARTER(calendar_date)                                        AS quarter,
  MONTH(calendar_date)                                          AS month,
  MONTHNAME(calendar_date)                                      AS month_name,
  WEEK(calendar_date)                                           AS week_of_year,
  DAYOFWEEK(calendar_date)                                      AS day_of_week,
  DAYNAME(calendar_date)                                        AS day_name,
  DAYOFYEAR(calendar_date)                                      AS day_of_year,
  CASE WHEN DAYOFWEEK(calendar_date) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend,
  DATE_TRUNC('quarter', calendar_date)                          AS quarter_start,
  LAST_DAY(calendar_date, 'quarter')                            AS quarter_end,
  DATE_TRUNC('month', calendar_date)                            AS month_start,
  LAST_DAY(calendar_date)                                       AS month_end,
  ROW_NUMBER() OVER (
    PARTITION BY YEAR(calendar_date), MONTH(calendar_date)
    ORDER BY calendar_date
  ) AS day_of_month_seq
FROM date_spine
WHERE calendar_date <= '2029-12-31';
```

### Example 2: Complex JSON Transformation with FLATTEN

```sql
-- API log data with nested request/response and varying schemas
CREATE OR REPLACE VIEW v_api_logs_flat AS
SELECT
  raw:request_id::STRING                        AS request_id,
  raw:timestamp::TIMESTAMP_TZ                   AS event_time,
  raw:method::STRING                            AS http_method,
  raw:endpoint::STRING                          AS endpoint,
  raw:response.status_code::INT                 AS status_code,
  raw:response.latency_ms::INT                  AS latency_ms,
  -- Flatten query parameters
  qp.value:key::STRING                          AS param_key,
  qp.value:value::STRING                        AS param_value,
  -- Flatten response headers
  rh.key::STRING                                AS header_name,
  rh.value::STRING                              AS header_value
FROM api_logs,
  LATERAL FLATTEN(input => raw:request.query_params, OUTER => TRUE) qp,
  LATERAL FLATTEN(input => raw:response.headers, OUTER => TRUE) rh;
```

### Example 3: Migrating SQL Server Patterns to Snowflake

```sql
-- SQL Server pattern:
-- SELECT TOP 10 * FROM orders WITH (NOLOCK) WHERE ISNULL(status, 'unknown') = 'active'

-- Snowflake equivalent:
SELECT * FROM orders
WHERE NVL(status, 'unknown') = 'active'
LIMIT 10;

-- SQL Server pattern:
-- SELECT * FROM orders CROSS APPLY OPENJSON(line_items)

-- Snowflake equivalent:
SELECT * FROM orders,
  LATERAL FLATTEN(input => line_items);

-- SQL Server pattern:
-- SELECT *, ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) rn
-- FROM employees WHERE rn = 1  -- This doesn't work in SQL Server either!

-- Snowflake with QUALIFY (cleanest solution on any platform):
SELECT * FROM employees
QUALIFY ROW_NUMBER() OVER (PARTITION BY dept ORDER BY salary DESC) = 1;
```

---

## Common Interview Questions & Answers

### Q1: What is the QUALIFY clause and how does it differ from HAVING?

**Answer:** `QUALIFY` filters rows based on window function results, evaluated after the window functions are computed. `HAVING` filters rows based on aggregate function results after `GROUP BY`. The key difference is the evaluation point: HAVING operates on grouped results while QUALIFY operates on windowed results. QUALIFY eliminates the need for subqueries when filtering by window functions, making queries more readable and often more performant.

### Q2: How does Snowflake handle case sensitivity for identifiers?

**Answer:** Unquoted identifiers are automatically folded to uppercase. Double-quoted identifiers preserve exact case and can include spaces and special characters. This means `my_col`, `MY_COL`, and `My_Col` all refer to the same object, but `"my_col"` is different. The best practice is to avoid double-quoted identifiers to prevent confusion. This is especially important when using tools (ORMs, ETL platforms) that may auto-quote identifiers.

### Q3: What is the FLATTEN function and when would you use it?

**Answer:** `FLATTEN` is a table function that explodes a VARIANT array or object into multiple rows. It is used with `LATERAL` to join against a source table. Common use cases include: exploding JSON arrays into rows, unnesting nested objects, and working with key-value pairs from JSON objects. Key parameters include `OUTER` (preserves rows with empty/null input like a LEFT JOIN), `RECURSIVE` (flattens all nesting levels), and `MODE` (controls whether to flatten arrays, objects, or both).

### Q4: How do TRY_ functions work and why are they important for data engineering?

**Answer:** TRY_ functions (TRY_CAST, TRY_TO_NUMBER, TRY_TO_DATE, etc.) return NULL instead of raising an error when conversion fails. They are essential for data engineering because real-world data is messy -- source systems may send unexpected formats, corrupt values, or mixed types. Using TRY_ functions in transformation logic prevents pipeline failures and allows you to gracefully handle bad data by routing it to error tables or applying default values.

### Q5: Explain the GENERATOR function and provide a use case.

**Answer:** `GENERATOR` is a table function that produces rows on demand, either a specific count (`ROWCOUNT => N`) or for a time duration (`TIMELIMIT => N`). Combined with `SEQ4()` or `ROW_NUMBER()`, it creates sequences. The most common data engineering use case is creating a date spine -- a complete sequence of dates used as the left side of a join to ensure no gaps in time-series reporting. It is also used for generating test data and creating number tables for set-based operations.

### Q6: What is IDENTIFIER() and when would you use it?

**Answer:** `IDENTIFIER()` resolves a string expression to a SQL identifier at runtime, enabling dynamic references to tables, columns, schemas, or databases. It is used in stored procedures for dynamic SQL, with session variables for parameterized queries, and in scenarios where object names are determined at runtime. Unlike string interpolation in other platforms, `IDENTIFIER()` is safe from SQL injection because it only resolves to valid identifiers.

---

## Tips

- **Always use `||` for string concatenation** in Snowflake, not `+`. The `+` operator is arithmetic only.
- **Use `QUALIFY`** whenever filtering on window functions -- it produces cleaner SQL than subqueries and is a common interview differentiator showing Snowflake expertise.
- **Use `TRY_CAST` in staging layers** to handle dirty data gracefully. Build your bronze/raw layer to be fault-tolerant.
- **Use `LATERAL FLATTEN` with `OUTER => TRUE`** when you need to preserve rows that have NULL or empty arrays -- similar to the difference between INNER JOIN and LEFT JOIN.
- **Remember that `LISTAGG`** is Snowflake's equivalent of SQL Server's `STRING_AGG` and MySQL's `GROUP_CONCAT`. It also supports `DISTINCT`: `LISTAGG(DISTINCT col, ', ')`.
- **Be careful with `DATEDIFF`** -- Snowflake counts boundaries crossed, not complete intervals. `DATEDIFF('year', '2024-12-31', '2025-01-01')` returns 1 even though only 1 day has passed.
- **`OBJECT_CONSTRUCT(*)`** is a powerful shorthand for converting an entire row to JSON -- great for audit logging or creating payloads.
- **Regex in Snowflake uses POSIX syntax**, not PCRE. Notable differences: no lookaheads/lookbehinds, use `\\` for escape sequences in string literals.
- When debugging identifier issues, use `SHOW TABLES` / `SHOW COLUMNS` and check the exact stored name to spot case-sensitivity problems.
