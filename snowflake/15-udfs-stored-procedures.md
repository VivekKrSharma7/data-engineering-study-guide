# User-Defined Functions (UDFs) & Stored Procedures

[Back to Snowflake Index](./README.md)

---

## 1. Overview

Snowflake allows developers to extend its built-in functionality through **User-Defined Functions (UDFs)** and **Stored Procedures**. UDFs return values and can be used inline within SQL statements, while stored procedures encapsulate procedural logic and are invoked with `CALL`. Understanding the differences, supported languages, and best practices is essential for any senior Data Engineer.

---

## 2. User-Defined Functions (UDFs)

### 2.1 SQL UDFs

#### Scalar SQL UDFs

Return a single value for each input row.

```sql
CREATE OR REPLACE FUNCTION mask_email(email STRING)
  RETURNS STRING
  LANGUAGE SQL
AS
$$
  CONCAT(LEFT(email, 2), '****@', SPLIT_PART(email, '@', 2))
$$;

-- Usage
SELECT mask_email('john.doe@company.com');
-- Result: jo****@company.com
```

#### Tabular (Table) SQL UDFs

Return a result set (table). Used with the `TABLE()` wrapper in `FROM` clauses.

```sql
CREATE OR REPLACE FUNCTION get_recent_orders(days_back INT)
  RETURNS TABLE (order_id INT, customer_id INT, order_date DATE, amount DECIMAL(10,2))
  LANGUAGE SQL
AS
$$
  SELECT order_id, customer_id, order_date, amount
  FROM orders
  WHERE order_date >= DATEADD('day', -days_back, CURRENT_DATE())
$$;

-- Usage
SELECT * FROM TABLE(get_recent_orders(30));
```

### 2.2 JavaScript UDFs

Useful for complex string manipulation, JSON processing, or logic not easily expressed in SQL.

```sql
CREATE OR REPLACE FUNCTION parse_user_agent(ua STRING)
  RETURNS VARIANT
  LANGUAGE JAVASCRIPT
AS
$$
  var result = {};
  if (UA.indexOf('Chrome') !== -1) {
    result.browser = 'Chrome';
  } else if (UA.indexOf('Firefox') !== -1) {
    result.browser = 'Firefox';
  } else {
    result.browser = 'Other';
  }
  result.is_mobile = UA.indexOf('Mobile') !== -1;
  return result;
$$;

SELECT parse_user_agent('Mozilla/5.0 ... Chrome/91.0 ...');
```

> **Note:** JavaScript UDF arguments are automatically uppercased inside the function body.

### 2.3 Python UDFs

Available via the Python runtime in Snowflake (Snowpark). Great for leveraging Python libraries.

```sql
CREATE OR REPLACE FUNCTION sentiment_score(text STRING)
  RETURNS FLOAT
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.10'
  PACKAGES = ('textblob')
  HANDLER = 'compute_sentiment'
AS
$$
from textblob import TextBlob

def compute_sentiment(text):
    if text is None:
        return 0.0
    return TextBlob(text).sentiment.polarity
$$;

SELECT review_text, sentiment_score(review_text) AS sentiment
FROM product_reviews;
```

### 2.4 Java UDFs

Useful for reusing existing Java libraries or complex computations.

```sql
CREATE OR REPLACE FUNCTION hash_value(input STRING)
  RETURNS STRING
  LANGUAGE JAVA
  RUNTIME_VERSION = '11'
  HANDLER = 'HashHelper.computeHash'
AS
$$
import java.security.MessageDigest;
import java.util.HexFormat;

class HashHelper {
    public static String computeHash(String input) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] hash = md.digest(input.getBytes("UTF-8"));
        return HexFormat.of().formatHex(hash);
    }
}
$$;
```

### 2.5 UDF Overloading

Snowflake supports overloading -- multiple UDFs with the same name but different argument signatures.

```sql
CREATE OR REPLACE FUNCTION format_amount(val FLOAT)
  RETURNS STRING
  LANGUAGE SQL
AS $$ TO_CHAR(val, '$999,999.00') $$;

CREATE OR REPLACE FUNCTION format_amount(val FLOAT, currency STRING)
  RETURNS STRING
  LANGUAGE SQL
AS $$ CONCAT(currency, ' ', TO_CHAR(val, '999,999.00')) $$;

-- Both work
SELECT format_amount(1500.50);          -- $1,500.50
SELECT format_amount(1500.50, 'EUR');   -- EUR 1,500.50
```

### 2.6 SECURE UDFs

Prevent the UDF definition from being visible to users who have usage privileges but not ownership. Critical for protecting proprietary business logic.

```sql
CREATE OR REPLACE SECURE FUNCTION calculate_pricing(cost FLOAT, tier STRING)
  RETURNS FLOAT
  LANGUAGE SQL
AS
$$
  CASE tier
    WHEN 'enterprise' THEN cost * 1.15
    WHEN 'standard'   THEN cost * 1.30
    WHEN 'basic'      THEN cost * 1.50
    ELSE cost * 1.75
  END
$$;
```

> **Key point:** `SECURE` UDFs also bypass certain query optimizations because the optimizer cannot inline the function body. Use only when needed.

### 2.7 IMMUTABLE vs VOLATILE

| Property | Description |
|---|---|
| **IMMUTABLE** | Same inputs always produce same outputs. Snowflake can cache and optimize aggressively. |
| **VOLATILE** | May return different results for same inputs (e.g., uses CURRENT_TIMESTAMP). Default behavior. |

```sql
CREATE OR REPLACE FUNCTION clean_text(input STRING)
  RETURNS STRING
  LANGUAGE SQL
  IMMUTABLE
AS
$$
  UPPER(TRIM(REGEXP_REPLACE(input, '[^a-zA-Z0-9 ]', '')))
$$;
```

---

## 3. Stored Procedures

### 3.1 JavaScript Stored Procedures

The original procedural language supported in Snowflake stored procedures.

```sql
CREATE OR REPLACE PROCEDURE archive_old_orders(cutoff_date STRING)
  RETURNS STRING
  LANGUAGE JAVASCRIPT
  EXECUTE AS CALLER
AS
$$
  var sql_cmd = `
    INSERT INTO orders_archive
    SELECT * FROM orders WHERE order_date < '${CUTOFF_DATE}'
  `;
  snowflake.execute({sqlText: sql_cmd});

  var del_cmd = `DELETE FROM orders WHERE order_date < '${CUTOFF_DATE}'`;
  var result = snowflake.execute({sqlText: del_cmd});
  result.next();
  var rows_deleted = result.getColumnValue(1);

  return `Archived and deleted ${rows_deleted} orders before ${CUTOFF_DATE}`;
$$;

CALL archive_old_orders('2024-01-01');
```

### 3.2 Python Stored Procedures

```sql
CREATE OR REPLACE PROCEDURE load_and_validate(stage_name STRING, target_table STRING)
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.10'
  PACKAGES = ('snowflake-snowpark-python')
  HANDLER = 'run'
AS
$$
def run(session, stage_name, target_table):
    df = session.read.option("type", "csv").schema("col1 STRING, col2 INT").csv(f"@{stage_name}")
    valid = df.filter(df.col2 > 0)
    invalid_count = df.count() - valid.count()
    valid.write.mode("append").save_as_table(target_table)
    return f"Loaded {valid.count()} rows, rejected {invalid_count} rows"
$$;
```

### 3.3 Java & Scala Stored Procedures

```sql
CREATE OR REPLACE PROCEDURE compute_stats(table_name STRING)
  RETURNS STRING
  LANGUAGE JAVA
  RUNTIME_VERSION = '11'
  PACKAGES = ('com.snowflake:snowpark:latest')
  HANDLER = 'StatsComputer.run'
AS
$$
import com.snowflake.snowpark_java.*;

class StatsComputer {
    public static String run(Session session, String tableName) {
        DataFrame df = session.table(tableName);
        long count = df.count();
        return "Row count for " + tableName + ": " + count;
    }
}
$$;
```

### 3.4 Caller's Rights vs Owner's Rights

| Aspect | Caller's Rights (`EXECUTE AS CALLER`) | Owner's Rights (`EXECUTE AS OWNER`) |
|---|---|---|
| **Privileges used** | Those of the calling user | Those of the procedure owner |
| **Default** | No (must specify) | Yes (default) |
| **Use case** | Administrative scripts, dynamic SQL on caller's objects | Controlled data access, security enforcement |
| **Session context** | Caller's warehouse, database, schema | Caller's session but owner's privileges |

```sql
-- Caller's rights: user must have privileges on underlying objects
CREATE OR REPLACE PROCEDURE admin_truncate(table_name STRING)
  RETURNS STRING
  LANGUAGE SQL
  EXECUTE AS CALLER
AS
BEGIN
  EXECUTE IMMEDIATE 'TRUNCATE TABLE ' || table_name;
  RETURN 'Truncated: ' || table_name;
END;

-- Owner's rights: procedure owner's privileges are used
CREATE OR REPLACE PROCEDURE get_sensitive_summary()
  RETURNS TABLE (department STRING, avg_salary FLOAT)
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
BEGIN
  RETURN TABLE(
    SELECT department, AVG(salary) AS avg_salary
    FROM hr.employees
    GROUP BY department
  );
END;
```

---

## 4. Snowflake Scripting (SQL-Based Procedural Logic)

Snowflake Scripting lets you write stored procedures in pure SQL with procedural constructs.

### 4.1 Variables, Branching, and Loops

```sql
CREATE OR REPLACE PROCEDURE process_daily_batches()
  RETURNS STRING
  LANGUAGE SQL
AS
DECLARE
  batch_date DATE DEFAULT CURRENT_DATE();
  batch_count INT;
  status STRING DEFAULT 'SUCCESS';
BEGIN
  SELECT COUNT(*) INTO :batch_count FROM staging.daily_load WHERE load_date = :batch_date;

  IF (batch_count = 0) THEN
    status := 'NO DATA';
  ELSEIF (batch_count > 100000) THEN
    -- Process in chunks
    FOR i IN 1 TO CEIL(batch_count / 50000) DO
      INSERT INTO production.fact_table
        SELECT * FROM staging.daily_load
        WHERE load_date = :batch_date
        LIMIT 50000 OFFSET ((i - 1) * 50000);
    END FOR;
  ELSE
    INSERT INTO production.fact_table
      SELECT * FROM staging.daily_load WHERE load_date = :batch_date;
  END IF;

  RETURN status || ': processed ' || batch_count || ' rows';
END;
```

### 4.2 EXECUTE IMMEDIATE

Executes dynamically constructed SQL strings.

```sql
CREATE OR REPLACE PROCEDURE create_monthly_partition(year INT, month INT)
  RETURNS STRING
  LANGUAGE SQL
AS
DECLARE
  table_name STRING;
  sql_text STRING;
BEGIN
  table_name := 'events_' || year || '_' || LPAD(month, 2, '0');
  sql_text := 'CREATE TABLE IF NOT EXISTS ' || table_name ||
              ' AS SELECT * FROM events WHERE YEAR(event_date) = ' || year ||
              ' AND MONTH(event_date) = ' || month;
  EXECUTE IMMEDIATE sql_text;
  RETURN 'Created table: ' || table_name;
END;
```

### 4.3 RESULTSET and Cursors

```sql
CREATE OR REPLACE PROCEDURE generate_table_stats()
  RETURNS TABLE (table_name STRING, row_count INT, size_bytes INT)
  LANGUAGE SQL
AS
DECLARE
  res RESULTSET;
  cur CURSOR FOR SELECT table_name FROM information_schema.tables WHERE table_schema = 'PUBLIC';
  tbl_name STRING;
  stats_query STRING;
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE tmp_stats (table_name STRING, row_count INT, size_bytes INT);

  OPEN cur;
  FOR record IN cur DO
    tbl_name := record.table_name;
    INSERT INTO tmp_stats
      SELECT :tbl_name, COUNT(*), 0 FROM IDENTIFIER(:tbl_name);
  END FOR;
  CLOSE cur;

  res := (SELECT * FROM tmp_stats);
  RETURN TABLE(res);
END;
```

### 4.4 Exception Handling

```sql
CREATE OR REPLACE PROCEDURE safe_data_load(source STRING, target STRING)
  RETURNS STRING
  LANGUAGE SQL
AS
DECLARE
  row_count INT;
  my_exception EXCEPTION (-20001, 'Custom load error');
BEGIN
  BEGIN
    INSERT INTO IDENTIFIER(:target) SELECT * FROM IDENTIFIER(:source);
    SELECT COUNT(*) INTO :row_count FROM IDENTIFIER(:target);

    IF (row_count = 0) THEN
      RAISE my_exception;
    END IF;

    RETURN 'Load successful: ' || row_count || ' rows';
  EXCEPTION
    WHEN my_exception THEN
      RETURN 'ERROR: No rows loaded from ' || source;
    WHEN STATEMENT_ERROR THEN
      RETURN 'SQL ERROR: ' || SQLERRM;
    WHEN OTHER THEN
      RETURN 'UNEXPECTED ERROR: ' || SQLERRM;
  END;
END;
```

---

## 5. Tasks Calling Stored Procedures

Stored procedures are commonly orchestrated using Snowflake Tasks.

```sql
-- Create a task that calls a stored procedure every hour
CREATE OR REPLACE TASK hourly_etl_task
  WAREHOUSE = etl_wh
  SCHEDULE = 'USING CRON 0 * * * * America/New_York'
AS
  CALL run_hourly_etl_pipeline();

-- Create a dependent (child) task
CREATE OR REPLACE TASK validate_etl_task
  WAREHOUSE = etl_wh
  AFTER hourly_etl_task
AS
  CALL validate_etl_results();

-- Enable tasks (must enable in reverse dependency order)
ALTER TASK validate_etl_task RESUME;
ALTER TASK hourly_etl_task RESUME;
```

---

## 6. UDF vs Stored Procedure: Key Differences

| Feature | UDF | Stored Procedure |
|---|---|---|
| **Returns** | A value (scalar or table) | A single value or table (but primarily used for side effects) |
| **Used in SQL** | Yes, inline in SELECT, WHERE, etc. | No, invoked with `CALL` only |
| **DDL/DML allowed** | No (read-only) | Yes (INSERT, UPDATE, CREATE, etc.) |
| **Transaction control** | No | Yes (COMMIT, ROLLBACK) |
| **Caller/Owner rights** | N/A (runs as owner) | Configurable |
| **Best for** | Data transformation, computation | Orchestration, admin tasks, ETL logic |

---

## 7. Real-World Examples

### Dynamic Data Quality Framework

```sql
CREATE OR REPLACE PROCEDURE run_data_quality_checks(schema_name STRING)
  RETURNS TABLE (check_name STRING, table_name STRING, status STRING, details STRING)
  LANGUAGE SQL
  EXECUTE AS CALLER
AS
DECLARE
  cur CURSOR FOR
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = UPPER(:schema_name) AND table_type = 'BASE TABLE';
BEGIN
  CREATE OR REPLACE TEMPORARY TABLE dq_results (
    check_name STRING, table_name STRING, status STRING, details STRING
  );

  FOR rec IN cur DO
    -- Null check on all columns
    BEGIN
      EXECUTE IMMEDIATE
        'INSERT INTO dq_results
         SELECT ''null_check'', ''' || rec.table_name || ''',
                CASE WHEN COUNT(*) > 0 THEN ''FAIL'' ELSE ''PASS'' END,
                COUNT(*) || '' rows with nulls''
         FROM ' || schema_name || '.' || rec.table_name ||
        ' WHERE ' || rec.table_name || '_id IS NULL';
    EXCEPTION
      WHEN OTHER THEN
        INSERT INTO dq_results VALUES ('null_check', rec.table_name, 'SKIP', SQLERRM);
    END;
  END FOR;

  RETURN TABLE(SELECT * FROM dq_results);
END;
```

### UDF for SCD Type 2 Hash Comparison

```sql
CREATE OR REPLACE SECURE FUNCTION scd2_hash(col1 STRING, col2 STRING, col3 STRING)
  RETURNS STRING
  LANGUAGE SQL
  IMMUTABLE
AS
$$
  SHA2(COALESCE(col1, '') || '|' || COALESCE(col2, '') || '|' || COALESCE(col3, ''))
$$;

-- Usage in MERGE for SCD-2
MERGE INTO dim_customer AS target
USING staging_customer AS source
ON target.customer_id = source.customer_id AND target.is_current = TRUE
WHEN MATCHED AND scd2_hash(target.name, target.email, target.city)
              != scd2_hash(source.name, source.email, source.city)
THEN UPDATE SET is_current = FALSE, end_date = CURRENT_TIMESTAMP()
WHEN NOT MATCHED
THEN INSERT (customer_id, name, email, city, is_current, start_date)
     VALUES (source.customer_id, source.name, source.email, source.city, TRUE, CURRENT_TIMESTAMP());
```

---

## 8. Common Interview Questions & Answers

### Q1: What is the difference between a UDF and a stored procedure in Snowflake?

**A:** UDFs return a value and can be used inline in SQL statements (SELECT, WHERE, etc.). They are read-only and cannot perform DDL/DML. Stored procedures are invoked with `CALL`, can execute DDL/DML, control transactions, and are used for orchestration and administrative tasks. Stored procedures support caller's rights vs owner's rights execution, while UDFs always execute with the owner's privileges.

### Q2: When would you use a SECURE UDF?

**A:** When the function body contains proprietary business logic (e.g., pricing algorithms, scoring models) that should not be visible to users who have USAGE privilege on the function. The trade-off is that SECURE UDFs may have reduced query optimization since the optimizer cannot inline the function definition.

### Q3: Explain IMMUTABLE vs VOLATILE for UDFs.

**A:** An IMMUTABLE UDF guarantees the same output for the same input, enabling Snowflake to cache results and optimize execution. A VOLATILE UDF (the default) may return different results for the same input across calls (e.g., if it depends on current time or session state). Marking a pure function as IMMUTABLE can significantly improve performance.

### Q4: How does caller's rights differ from owner's rights in stored procedures?

**A:** With caller's rights (`EXECUTE AS CALLER`), the procedure runs using the calling user's privileges -- the caller must have access to all objects referenced. With owner's rights (`EXECUTE AS OWNER`, the default), the procedure uses the owner's privileges, allowing controlled access to objects the caller may not directly have permissions on. Owner's rights is useful for security patterns where you want to grant limited access through a procedure.

### Q5: How do you handle errors in Snowflake Scripting?

**A:** Snowflake Scripting supports structured exception handling with `BEGIN ... EXCEPTION ... END` blocks. You can catch specific exceptions (like `STATEMENT_ERROR`) or use `WHEN OTHER` for a general catch-all. Custom exceptions can be declared with `DECLARE my_ex EXCEPTION (-20001, 'message')` and raised with `RAISE`. The `SQLERRM` variable provides error message details.

### Q6: Can a stored procedure return a table?

**A:** Yes. In Snowflake Scripting, declare the procedure with `RETURNS TABLE (...)`, use a `RESULTSET` variable, and return it with `RETURN TABLE(res)`. The caller uses `SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))` or calls it directly in newer Snowflake versions.

### Q7: What languages are supported for UDFs and stored procedures?

**A:** UDFs support SQL, JavaScript, Python, Java, and Scala. Stored procedures support JavaScript, Snowflake Scripting (SQL), Python, Java, and Scala. Python, Java, and Scala procedures use the Snowpark framework.

### Q8: How do you orchestrate stored procedures in a pipeline?

**A:** Use Snowflake Tasks. A root task runs on a CRON schedule or fixed interval and calls a stored procedure. Child tasks use the `AFTER` clause to create a DAG of dependent procedure calls. Tasks must be explicitly resumed with `ALTER TASK ... RESUME` and are enabled from leaf to root.

---

## 9. Tips for Interviews and Practice

- **Language selection matters:** Use SQL UDFs for simple transformations (best performance), JavaScript for complex string/JSON logic, Python for ML-adjacent workloads, and Java/Scala when reusing existing libraries.
- **Always specify IMMUTABLE** when the function is deterministic -- it enables caching and better optimization.
- **Avoid dynamic SQL injection** in stored procedures: use `IDENTIFIER()` for table/column names and bind variables for values.
- **Use Snowflake Scripting** over JavaScript for new stored procedures -- it is the recommended approach and has better integration with SQL.
- **Stored procedure debugging:** Use `SYSTEM$LOG()` and the event table for logging, or return intermediate results during development.
- **Owner's rights is the default** for stored procedures. Be intentional about which model you choose for security.
- **UDFs in performance-critical paths** can be a bottleneck, especially JavaScript and Python UDFs. Consider vectorized (batch) Python UDFs for large datasets.
- **Know the limits:** UDFs cannot call other UDFs in all language combinations, and stored procedures have a maximum call stack depth.

---
