# Window Functions & Analytical Queries

[Back to Snowflake Index](./README.md)

---

## Key Concepts

### What Are Window Functions?

Window functions perform calculations across a set of rows (a "window") related to the current row, without collapsing the result set like GROUP BY does. Every row retains its identity while gaining access to aggregate or positional information about its neighbors.

**Syntax:**
```sql
function_name(args) OVER (
  [PARTITION BY partition_expression, ...]
  [ORDER BY sort_expression [ASC|DESC], ...]
  [window_frame_clause]
)
```

- **PARTITION BY**: Divides rows into groups (like GROUP BY but without collapsing)
- **ORDER BY**: Defines the row ordering within each partition
- **Window frame**: Defines which rows within the partition to include relative to the current row

---

### Ranking Functions

#### ROW_NUMBER()

Assigns a unique sequential integer to each row within a partition. No ties -- if rows are identical in the ORDER BY columns, the assignment is non-deterministic.

```sql
SELECT
  employee_id,
  department,
  salary,
  ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) AS dept_rank
FROM employees;
```

#### RANK()

Like ROW_NUMBER but assigns the same rank to ties and leaves gaps. If two rows tie at rank 1, the next row is rank 3.

```sql
SELECT
  student_name,
  score,
  RANK() OVER (ORDER BY score DESC) AS rank
FROM exam_results;
-- Scores: 95, 95, 90 -> Ranks: 1, 1, 3
```

#### DENSE_RANK()

Like RANK but without gaps. If two rows tie at rank 1, the next row is rank 2.

```sql
SELECT
  student_name,
  score,
  DENSE_RANK() OVER (ORDER BY score DESC) AS dense_rank
FROM exam_results;
-- Scores: 95, 95, 90 -> Dense ranks: 1, 1, 2
```

#### NTILE(n)

Distributes rows into `n` approximately equal buckets. Useful for percentile analysis and data segmentation.

```sql
-- Divide customers into 4 spending quartiles
SELECT
  customer_id,
  total_spend,
  NTILE(4) OVER (ORDER BY total_spend DESC) AS spend_quartile
FROM customer_summary;
```

**Comparison of all ranking functions:**

```sql
SELECT
  name,
  score,
  ROW_NUMBER() OVER (ORDER BY score DESC) AS row_num,    -- 1, 2, 3, 4, 5
  RANK()       OVER (ORDER BY score DESC) AS rank,        -- 1, 1, 3, 4, 4
  DENSE_RANK() OVER (ORDER BY score DESC) AS dense_rank,  -- 1, 1, 2, 3, 3
  NTILE(3)     OVER (ORDER BY score DESC) AS tile         -- 1, 1, 2, 2, 3
FROM (VALUES ('A',95),('B',95),('C',90),('D',85),('E',85)) AS t(name, score);
```

---

### Offset Functions: LEAD and LAG

#### LAG(expr, offset, default)

Accesses a value from a **previous** row (looking backward).

#### LEAD(expr, offset, default)

Accesses a value from a **following** row (looking forward).

```sql
-- Track month-over-month revenue changes
SELECT
  month_date,
  revenue,
  LAG(revenue, 1)  OVER (ORDER BY month_date)  AS prev_month_revenue,
  LEAD(revenue, 1) OVER (ORDER BY month_date)  AS next_month_revenue,
  revenue - LAG(revenue, 1) OVER (ORDER BY month_date) AS mom_change,
  ROUND(
    (revenue - LAG(revenue, 1) OVER (ORDER BY month_date))
    / NULLIF(LAG(revenue, 1) OVER (ORDER BY month_date), 0) * 100,
    2
  ) AS mom_pct_change
FROM monthly_revenue
ORDER BY month_date;

-- With default value to avoid NULLs for first/last row
SELECT
  event_date,
  event_type,
  LAG(event_type, 1, 'NO_PREVIOUS') OVER (
    PARTITION BY user_id ORDER BY event_date
  ) AS previous_event
FROM user_events;

-- Calculate time between events
SELECT
  user_id,
  event_time,
  DATEDIFF('second',
    LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time),
    event_time
  ) AS seconds_since_last_event
FROM user_events;
```

---

### Value Functions: FIRST_VALUE, LAST_VALUE, NTH_VALUE

#### FIRST_VALUE(expr)

Returns the first value in the window frame.

#### LAST_VALUE(expr)

Returns the last value in the window frame. **Caution:** The default frame is `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, which means LAST_VALUE returns the current row's value, not the actual last value in the partition. Always specify the frame explicitly.

#### NTH_VALUE(expr, n)

Returns the nth value in the window frame.

```sql
SELECT
  employee_id,
  department,
  salary,

  -- Highest salary in department
  FIRST_VALUE(salary) OVER (
    PARTITION BY department ORDER BY salary DESC
  ) AS highest_salary,

  -- Lowest salary in department (MUST specify full frame)
  LAST_VALUE(salary) OVER (
    PARTITION BY department ORDER BY salary DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
  ) AS lowest_salary,

  -- Second highest salary
  NTH_VALUE(salary, 2) OVER (
    PARTITION BY department ORDER BY salary DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
  ) AS second_highest_salary,

  -- Name of highest earner
  FIRST_VALUE(employee_name) OVER (
    PARTITION BY department ORDER BY salary DESC
  ) AS top_earner_name

FROM employees;
```

---

### Window Frame Specification

The window frame defines which rows relative to the current row are included in the calculation.

**Syntax:**
```
{ ROWS | RANGE } BETWEEN frame_start AND frame_end
```

**Frame boundaries:**
- `UNBOUNDED PRECEDING` -- first row of the partition
- `N PRECEDING` -- N rows before current row
- `CURRENT ROW` -- the current row
- `N FOLLOWING` -- N rows after current row
- `UNBOUNDED FOLLOWING` -- last row of the partition

**ROWS vs RANGE:**
- `ROWS`: Physical row count (exact number of rows)
- `RANGE`: Logical value range (groups rows with equal ORDER BY values together)

```sql
-- Default frame (when ORDER BY is specified):
-- RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW

-- Running total (default frame works here)
SELECT
  order_date,
  amount,
  SUM(amount) OVER (ORDER BY order_date) AS running_total
FROM orders;

-- 3-day moving average (physical rows)
SELECT
  sale_date,
  daily_revenue,
  AVG(daily_revenue) OVER (
    ORDER BY sale_date
    ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
  ) AS moving_avg_3day
FROM daily_sales;

-- 7-day moving average
SELECT
  sale_date,
  daily_revenue,
  AVG(daily_revenue) OVER (
    ORDER BY sale_date
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS moving_avg_7day
FROM daily_sales;

-- Centered moving average (look back and forward)
SELECT
  sale_date,
  daily_revenue,
  AVG(daily_revenue) OVER (
    ORDER BY sale_date
    ROWS BETWEEN 3 PRECEDING AND 3 FOLLOWING
  ) AS centered_avg_7day
FROM daily_sales;

-- Cumulative max
SELECT
  trade_date,
  price,
  MAX(price) OVER (
    ORDER BY trade_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_max_price
FROM stock_prices;

-- Full partition aggregate (every row sees the same value)
SELECT
  employee_id,
  department,
  salary,
  AVG(salary) OVER (
    PARTITION BY department
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
  ) AS dept_avg_salary
FROM employees;
-- Equivalent shorthand (no ORDER BY = full partition):
-- AVG(salary) OVER (PARTITION BY department)
```

---

### Aggregate Window Functions

Any standard aggregate function can be used as a window function by adding an OVER clause.

```sql
SELECT
  department,
  employee_name,
  salary,

  -- Aggregate window functions
  SUM(salary)   OVER (PARTITION BY department) AS dept_total_salary,
  AVG(salary)   OVER (PARTITION BY department) AS dept_avg_salary,
  COUNT(*)      OVER (PARTITION BY department) AS dept_employee_count,
  MIN(salary)   OVER (PARTITION BY department) AS dept_min_salary,
  MAX(salary)   OVER (PARTITION BY department) AS dept_max_salary,

  -- Percent of department total
  ROUND(salary / SUM(salary) OVER (PARTITION BY department) * 100, 2) AS pct_of_dept,

  -- Percent of company total
  ROUND(salary / SUM(salary) OVER () * 100, 4) AS pct_of_company,

  -- Deviation from department average
  salary - AVG(salary) OVER (PARTITION BY department) AS deviation_from_avg

FROM employees
ORDER BY department, salary DESC;
```

---

### QUALIFY Clause for Filtering Window Results

`QUALIFY` is the most elegant way to filter on window function results in Snowflake, avoiding the need for subqueries.

```sql
-- Top earner per department
SELECT department, employee_name, salary
FROM employees
QUALIFY ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) = 1;

-- Top 3 earners per department
SELECT department, employee_name, salary
FROM employees
QUALIFY ROW_NUMBER() OVER (PARTITION BY department ORDER BY salary DESC) <= 3;

-- Remove duplicates (keep latest record per entity)
SELECT *
FROM customer_updates
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY customer_id
  ORDER BY updated_at DESC
) = 1;

-- Keep rows where value is above the partition average
SELECT *
FROM sales
QUALIFY amount > AVG(amount) OVER (PARTITION BY region);

-- QUALIFY with a named window alias
SELECT
  employee_id,
  department,
  salary,
  RANK() OVER w AS salary_rank
FROM employees
WINDOW w AS (PARTITION BY department ORDER BY salary DESC)
QUALIFY salary_rank <= 5;
```

---

### Cumulative Distribution Functions

```sql
-- PERCENT_RANK: Relative rank as a percentage (0 to 1)
-- Formula: (rank - 1) / (total_rows - 1)
SELECT
  employee_name,
  salary,
  PERCENT_RANK() OVER (ORDER BY salary) AS pct_rank
FROM employees;

-- CUME_DIST: Cumulative distribution (fraction of rows <= current row)
-- Formula: count of rows <= current / total rows
SELECT
  employee_name,
  salary,
  CUME_DIST() OVER (ORDER BY salary) AS cume_dist
FROM employees;

-- PERCENTILE_CONT: Continuous percentile (interpolates)
SELECT
  department,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY salary) OVER (PARTITION BY department) AS median_salary,
  PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY salary) OVER (PARTITION BY department) AS p90_salary
FROM employees;

-- PERCENTILE_DISC: Discrete percentile (returns an actual value)
SELECT DISTINCT
  department,
  PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY salary) OVER (PARTITION BY department) AS median_salary
FROM employees;
```

---

## Practical Analytical Query Patterns

### Pattern 1: Running Total

```sql
SELECT
  transaction_date,
  amount,
  SUM(amount) OVER (
    ORDER BY transaction_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS running_total
FROM transactions
ORDER BY transaction_date;

-- Running total per account
SELECT
  account_id,
  transaction_date,
  amount,
  SUM(amount) OVER (
    PARTITION BY account_id
    ORDER BY transaction_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS account_running_balance
FROM transactions;
```

### Pattern 2: Moving Average

```sql
-- 30-day moving average of daily revenue
SELECT
  sale_date,
  daily_revenue,
  AVG(daily_revenue) OVER (
    ORDER BY sale_date
    ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
  ) AS moving_avg_30d,
  COUNT(*) OVER (
    ORDER BY sale_date
    ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
  ) AS days_in_window  -- Useful to know when window is not yet full
FROM daily_sales;
```

### Pattern 3: Percent of Total

```sql
-- Revenue contribution by product within each category
SELECT
  category,
  product_name,
  revenue,
  SUM(revenue) OVER (PARTITION BY category) AS category_total,
  ROUND(revenue / SUM(revenue) OVER (PARTITION BY category) * 100, 2) AS pct_of_category,
  ROUND(revenue / SUM(revenue) OVER () * 100, 2) AS pct_of_grand_total
FROM product_revenue
ORDER BY category, revenue DESC;
```

### Pattern 4: Top-N Per Group

```sql
-- Top 3 selling products per category
SELECT
  category,
  product_name,
  total_sales
FROM product_sales
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY category
  ORDER BY total_sales DESC
) <= 3
ORDER BY category, total_sales DESC;

-- Top 1 per group with ties (use RANK instead of ROW_NUMBER)
SELECT
  category,
  product_name,
  total_sales
FROM product_sales
QUALIFY RANK() OVER (
  PARTITION BY category
  ORDER BY total_sales DESC
) = 1;
```

### Pattern 5: Gap and Island Detection

```sql
-- Detect consecutive sequences (islands) in event data
WITH numbered AS (
  SELECT
    user_id,
    event_date,
    event_date - ROW_NUMBER() OVER (
      PARTITION BY user_id ORDER BY event_date
    )::INT AS island_group
  FROM user_logins
)
SELECT
  user_id,
  MIN(event_date) AS streak_start,
  MAX(event_date) AS streak_end,
  COUNT(*) AS streak_length
FROM numbered
GROUP BY user_id, island_group
HAVING COUNT(*) >= 3  -- Streaks of 3+ days
ORDER BY user_id, streak_start;
```

### Pattern 6: Year-over-Year Comparison

```sql
SELECT
  month_date,
  revenue,
  LAG(revenue, 12) OVER (ORDER BY month_date) AS revenue_last_year,
  revenue - LAG(revenue, 12) OVER (ORDER BY month_date) AS yoy_change,
  ROUND(
    (revenue - LAG(revenue, 12) OVER (ORDER BY month_date))
    / NULLIF(LAG(revenue, 12) OVER (ORDER BY month_date), 0) * 100,
    2
  ) AS yoy_pct_change
FROM monthly_revenue
ORDER BY month_date;
```

### Pattern 7: Sessionization

```sql
-- Create sessions from clickstream data (new session after 30 min of inactivity)
WITH click_gaps AS (
  SELECT
    user_id,
    event_time,
    page_url,
    DATEDIFF('minute',
      LAG(event_time) OVER (PARTITION BY user_id ORDER BY event_time),
      event_time
    ) AS minutes_since_last
  FROM clickstream
),
session_starts AS (
  SELECT
    *,
    CASE
      WHEN minutes_since_last IS NULL OR minutes_since_last > 30
      THEN 1 ELSE 0
    END AS is_new_session
  FROM click_gaps
)
SELECT
  user_id,
  event_time,
  page_url,
  SUM(is_new_session) OVER (
    PARTITION BY user_id ORDER BY event_time
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS session_id
FROM session_starts;
```

### Pattern 8: Cumulative Distribution Analysis

```sql
-- What percentage of orders account for 80% of revenue? (Pareto analysis)
SELECT
  order_id,
  revenue,
  SUM(revenue) OVER (ORDER BY revenue DESC) AS cumulative_revenue,
  SUM(revenue) OVER () AS total_revenue,
  ROUND(
    SUM(revenue) OVER (ORDER BY revenue DESC) / SUM(revenue) OVER () * 100,
    2
  ) AS cumulative_pct,
  COUNT(*) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING) AS order_rank,
  COUNT(*) OVER () AS total_orders
FROM orders
QUALIFY cumulative_pct <= 80
   OR ROW_NUMBER() OVER (ORDER BY revenue DESC) = 1  -- Always include at least 1
ORDER BY revenue DESC;
```

---

## Real-World Examples

### Example 1: SCD Type 2 Processing with Window Functions

```sql
-- Identify the current record and set valid_from/valid_to for SCD Type 2
CREATE OR REPLACE VIEW v_customer_scd2 AS
SELECT
  customer_id,
  customer_name,
  email,
  city,
  updated_at AS valid_from,
  COALESCE(
    LEAD(updated_at) OVER (PARTITION BY customer_id ORDER BY updated_at) - INTERVAL '1 second',
    '9999-12-31'::TIMESTAMP_NTZ
  ) AS valid_to,
  CASE
    WHEN ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC) = 1
    THEN TRUE
    ELSE FALSE
  END AS is_current
FROM customer_history;
```

### Example 2: Funnel Analysis

```sql
-- E-commerce conversion funnel with drop-off rates
WITH funnel AS (
  SELECT
    step_name,
    step_order,
    COUNT(DISTINCT user_id) AS users_at_step
  FROM user_funnel_events
  GROUP BY step_name, step_order
)
SELECT
  step_name,
  step_order,
  users_at_step,
  FIRST_VALUE(users_at_step) OVER (ORDER BY step_order) AS top_of_funnel,
  LAG(users_at_step) OVER (ORDER BY step_order) AS prev_step_users,
  ROUND(
    users_at_step / NULLIF(LAG(users_at_step) OVER (ORDER BY step_order), 0) * 100,
    2
  ) AS step_conversion_pct,
  ROUND(
    users_at_step / FIRST_VALUE(users_at_step) OVER (ORDER BY step_order) * 100,
    2
  ) AS overall_conversion_pct
FROM funnel
ORDER BY step_order;
```

### Example 3: Anomaly Detection with Moving Statistics

```sql
-- Detect anomalous daily revenue using moving average and standard deviation
WITH daily_stats AS (
  SELECT
    sale_date,
    daily_revenue,
    AVG(daily_revenue) OVER (
      ORDER BY sale_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS moving_avg_30d,
    STDDEV(daily_revenue) OVER (
      ORDER BY sale_date
      ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS moving_stddev_30d
  FROM daily_sales
)
SELECT
  sale_date,
  daily_revenue,
  moving_avg_30d,
  moving_stddev_30d,
  ROUND((daily_revenue - moving_avg_30d) / NULLIF(moving_stddev_30d, 0), 2) AS z_score,
  CASE
    WHEN ABS((daily_revenue - moving_avg_30d) / NULLIF(moving_stddev_30d, 0)) > 2
    THEN 'ANOMALY'
    ELSE 'NORMAL'
  END AS status
FROM daily_stats
WHERE moving_stddev_30d IS NOT NULL
ORDER BY sale_date;
```

---

## Common Interview Questions & Answers

### Q1: What is the difference between ROW_NUMBER, RANK, and DENSE_RANK?

**Answer:** All three assign rankings to rows within a partition. `ROW_NUMBER` always assigns unique sequential numbers -- ties are broken arbitrarily. `RANK` assigns the same number to ties but leaves gaps (1, 1, 3). `DENSE_RANK` assigns the same number to ties without gaps (1, 1, 2). Use `ROW_NUMBER` when you need exactly one row per position (e.g., deduplication). Use `RANK` when you need to know the true position considering ties. Use `DENSE_RANK` when you need to count distinct ranking levels.

### Q2: What is a common mistake with LAST_VALUE and how do you fix it?

**Answer:** The default window frame when ORDER BY is specified is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. This means `LAST_VALUE` returns the current row's value, not the last value in the partition. To get the actual last value, you must explicitly set the frame to `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. This is one of the most common window function bugs. `FIRST_VALUE` does not have this problem because the first row of the default frame is always the partition start.

### Q3: Explain the difference between ROWS and RANGE in window frames.

**Answer:** `ROWS` defines the frame by physical row count -- `ROWS BETWEEN 2 PRECEDING AND CURRENT ROW` always includes exactly 3 rows. `RANGE` defines the frame by logical value proximity -- `RANGE BETWEEN 2 PRECEDING AND CURRENT ROW` includes all rows whose ORDER BY value is within 2 of the current row's value. With `RANGE`, rows with duplicate ORDER BY values are all included together. `ROWS` is generally more predictable and commonly used for moving calculations. `RANGE` is the default when ORDER BY is present, which can cause unexpected results if you are not aware of it.

### Q4: How would you deduplicate a table keeping only the most recent record per key?

**Answer:** Use `ROW_NUMBER` with `QUALIFY`:

```sql
SELECT *
FROM source_table
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY business_key
  ORDER BY updated_at DESC
) = 1;
```

This partitions by the business key, orders by the update timestamp descending, and keeps only the first row (most recent) per partition. This is more efficient than alternatives like self-joins or correlated subqueries, and it is the idiomatic Snowflake pattern.

### Q5: How do you calculate a running total that resets monthly?

**Answer:**

```sql
SELECT
  transaction_date,
  amount,
  SUM(amount) OVER (
    PARTITION BY DATE_TRUNC('month', transaction_date)
    ORDER BY transaction_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS monthly_running_total
FROM transactions;
```

By partitioning on the truncated month, the running total automatically resets at the start of each month.

### Q6: How would you find rows where a value changed from the previous row?

**Answer:**

```sql
SELECT *
FROM status_log
WHERE status != LAG(status) OVER (PARTITION BY entity_id ORDER BY event_time)
   OR LAG(status) OVER (PARTITION BY entity_id ORDER BY event_time) IS NULL;

-- Or more elegantly with QUALIFY:
SELECT *
FROM status_log
QUALIFY status != LAG(status, 1) OVER (PARTITION BY entity_id ORDER BY event_time)
    OR LAG(status, 1) OVER (PARTITION BY entity_id ORDER BY event_time) IS NULL;
```

This compares each row's status with the previous row's status using LAG. The NULL check ensures the first row per entity is always included.

### Q7: How do you compute a median in Snowflake using window functions?

**Answer:** Use `PERCENTILE_CONT(0.5)` as a window function:

```sql
SELECT DISTINCT
  department,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY salary)
    OVER (PARTITION BY department) AS median_salary
FROM employees;
```

`PERCENTILE_CONT` interpolates between values for an exact 50th percentile. Use `PERCENTILE_DISC` instead if you want an actual value from the dataset. The `DISTINCT` is needed because the window function repeats the same median for every row in the partition -- or you can use it as an aggregate function with GROUP BY instead.

---

## Tips

- **QUALIFY is your best friend** in Snowflake. Any time you find yourself wrapping a query in a subquery just to filter on a window function, use QUALIFY instead.
- **Always specify the window frame for LAST_VALUE.** The default frame ending at `CURRENT ROW` is almost never what you want.
- **Use `ROWS` instead of `RANGE`** for moving averages and running calculations unless you specifically need logical grouping of tied values.
- **Window functions are evaluated after WHERE and GROUP BY.** If you need to filter before the window function runs, put the filter in WHERE. If you need to filter after, use QUALIFY.
- **Named windows** reduce repetition when you use the same OVER specification multiple times:
  ```sql
  SELECT
    ROW_NUMBER() OVER w AS rn,
    RANK() OVER w AS rnk,
    SUM(amount) OVER w AS running_sum
  FROM orders
  WINDOW w AS (PARTITION BY customer_id ORDER BY order_date);
  ```
- **Performance consideration:** Window functions with `PARTITION BY` benefit from clustering on the partition columns for large tables.
- **For deduplication**, prefer `ROW_NUMBER() + QUALIFY` over `GROUP BY` with aggregates -- it gives you access to all columns without needing to aggregate each one.
- **Be aware of NULL ordering.** In Snowflake, NULLs sort last in ascending order and first in descending order by default. Use `NULLS FIRST` or `NULLS LAST` to control this explicitly in your window ORDER BY.
