# Window Functions & Advanced Analytics

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [Window Function Syntax](#window-function-syntax)
3. [Ranking Functions](#ranking-functions)
4. [Offset Functions](#offset-functions)
5. [Aggregate Window Functions](#aggregate-window-functions)
6. [Distribution Functions](#distribution-functions)
7. [Window Frame Specification](#window-frame-specification)
8. [Running Totals](#running-totals)
9. [Moving Averages](#moving-averages)
10. [Gaps and Islands Problem](#gaps-and-islands-problem)
11. [De-Duplication Patterns](#de-duplication-patterns)
12. [Top-N Per Group](#top-n-per-group)
13. [Sessionization](#sessionization)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## Introduction

Window functions perform calculations across a set of rows that are related to the current row, without collapsing the result set like GROUP BY does. They are one of the most powerful features in T-SQL for analytical queries and are essential knowledge for any senior Data Engineer.

Window functions were introduced in SQL Server 2005 (basic ranking and aggregates) and significantly enhanced in SQL Server 2012 (offset functions, frame specifications, statistical functions).

---

## Window Function Syntax

```sql
function_name (expression)
OVER (
    [PARTITION BY partition_expression, ...]
    [ORDER BY sort_expression [ASC|DESC], ...]
    [frame_clause]
)
```

### Components

| Component | Purpose | Required? |
|-----------|---------|-----------|
| `PARTITION BY` | Divides the result set into groups (like GROUP BY but without collapsing rows) | Optional |
| `ORDER BY` | Defines the logical order within each partition | Required for ranking/offset functions; optional for aggregates |
| Frame clause | Defines the subset of rows within the partition for the calculation | Optional (has defaults) |

---

## Ranking Functions

### ROW_NUMBER()

Assigns a unique sequential integer to each row within its partition. No ties; always unique.

```sql
SELECT
    EmployeeID,
    Department,
    Salary,
    ROW_NUMBER() OVER (PARTITION BY Department ORDER BY Salary DESC) AS RowNum
FROM dbo.Employees;

-- Result:
-- EmployeeID | Department  | Salary  | RowNum
-- 5          | Engineering | 120000  | 1
-- 3          | Engineering | 110000  | 2
-- 7          | Engineering | 110000  | 3  <-- tie broken arbitrarily
-- 1          | Marketing   | 95000   | 1
-- 4          | Marketing   | 85000   | 2
```

### RANK()

Assigns rank with gaps for ties. If two rows tie for rank 1, the next rank is 3 (not 2).

```sql
SELECT
    EmployeeID,
    Department,
    Salary,
    RANK() OVER (PARTITION BY Department ORDER BY Salary DESC) AS Rnk
FROM dbo.Employees;

-- Result:
-- EmployeeID | Department  | Salary  | Rnk
-- 5          | Engineering | 120000  | 1
-- 3          | Engineering | 110000  | 2
-- 7          | Engineering | 110000  | 2   <-- tied
-- 2          | Engineering | 100000  | 4   <-- rank 3 skipped
```

### DENSE_RANK()

Assigns rank without gaps for ties. If two rows tie for rank 1, the next rank is 2.

```sql
SELECT
    EmployeeID,
    Department,
    Salary,
    DENSE_RANK() OVER (PARTITION BY Department ORDER BY Salary DESC) AS DenseRnk
FROM dbo.Employees;

-- Result:
-- EmployeeID | Department  | Salary  | DenseRnk
-- 5          | Engineering | 120000  | 1
-- 3          | Engineering | 110000  | 2
-- 7          | Engineering | 110000  | 2   <-- tied
-- 2          | Engineering | 100000  | 3   <-- no gap
```

### NTILE(n)

Divides the partition into `n` approximately equal groups and assigns the group number.

```sql
SELECT
    EmployeeID,
    Salary,
    NTILE(4) OVER (ORDER BY Salary) AS Quartile
FROM dbo.Employees;

-- Divides employees into 4 salary quartiles
-- If 10 rows: groups of 3, 3, 2, 2 (extra rows go to earlier groups)
```

### Comparison Table

| Function | Ties | Gaps | Unique Values |
|----------|------|------|---------------|
| ROW_NUMBER | Broken arbitrarily | No | Always unique |
| RANK | Same rank | Yes | May repeat |
| DENSE_RANK | Same rank | No | May repeat |
| NTILE | N/A (bucket assignment) | N/A | Bucket numbers 1..n |

---

## Offset Functions

Offset functions access values from other rows relative to the current row without a self-join.

### LEAD and LAG

```sql
-- LAG: access previous row's value
-- LEAD: access next row's value
SELECT
    OrderDate,
    DailyRevenue,
    LAG(DailyRevenue, 1, 0) OVER (ORDER BY OrderDate) AS PrevDayRevenue,
    LEAD(DailyRevenue, 1, 0) OVER (ORDER BY OrderDate) AS NextDayRevenue,
    DailyRevenue - LAG(DailyRevenue, 1, 0) OVER (ORDER BY OrderDate) AS DayOverDayChange
FROM dbo.DailyRevenue;

-- Syntax: LAG(expression, offset, default_value) OVER (...)
-- offset: number of rows back (default 1)
-- default_value: returned when LAG/LEAD goes beyond the partition boundary (default NULL)
```

### FIRST_VALUE and LAST_VALUE

```sql
SELECT
    EmployeeID,
    Department,
    Salary,
    FIRST_VALUE(EmployeeID) OVER (
        PARTITION BY Department
        ORDER BY Salary DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS HighestPaidEmployee,
    LAST_VALUE(EmployeeID) OVER (
        PARTITION BY Department
        ORDER BY Salary DESC
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS LowestPaidEmployee
FROM dbo.Employees;
```

> **Critical**: `LAST_VALUE` with the default frame (`RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`) only looks up to the current row, so it returns the current row's value. You almost always need to specify `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` to get the true last value.

---

## Aggregate Window Functions

Standard aggregate functions can be used as window functions by adding an OVER clause.

```sql
SELECT
    OrderDate,
    ProductCategory,
    Amount,
    -- Total amount across all rows
    SUM(Amount) OVER () AS GrandTotal,
    -- Total amount per category
    SUM(Amount) OVER (PARTITION BY ProductCategory) AS CategoryTotal,
    -- Percentage of category total
    CAST(Amount * 100.0 / SUM(Amount) OVER (PARTITION BY ProductCategory) AS DECIMAL(5,2)) AS PctOfCategory,
    -- Running total within category (ordered by date)
    SUM(Amount) OVER (PARTITION BY ProductCategory ORDER BY OrderDate
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RunningTotal,
    -- Count of orders per category
    COUNT(*) OVER (PARTITION BY ProductCategory) AS CategoryOrderCount,
    -- Min and Max within category
    MIN(Amount) OVER (PARTITION BY ProductCategory) AS CategoryMin,
    MAX(Amount) OVER (PARTITION BY ProductCategory) AS CategoryMax,
    -- Average within category
    AVG(Amount) OVER (PARTITION BY ProductCategory) AS CategoryAvg
FROM dbo.Orders;
```

### Key Insight: Window Aggregates vs GROUP BY

```sql
-- GROUP BY: collapses rows (one row per group)
SELECT ProductCategory, SUM(Amount) AS Total
FROM dbo.Orders
GROUP BY ProductCategory;

-- Window aggregate: preserves all rows, adds the aggregate as a column
SELECT ProductCategory, Amount,
       SUM(Amount) OVER (PARTITION BY ProductCategory) AS Total
FROM dbo.Orders;
-- Every original row is preserved; Total is repeated for rows in the same category
```

---

## Distribution Functions

### PERCENT_RANK()

Returns the relative rank of a row as a percentage: `(rank - 1) / (total_rows - 1)`.

```sql
SELECT
    EmployeeID,
    Salary,
    PERCENT_RANK() OVER (ORDER BY Salary) AS PercentRank
FROM dbo.Employees;
-- First row: 0.0, Last row: 1.0
-- Useful for: "What percentile is this employee's salary?"
```

### CUME_DIST()

Returns the cumulative distribution: proportion of rows with values <= the current row's value.

```sql
SELECT
    EmployeeID,
    Salary,
    CUME_DIST() OVER (ORDER BY Salary) AS CumeDist
FROM dbo.Employees;
-- "What fraction of employees earn this salary or less?"
-- Always between 0 (exclusive) and 1 (inclusive)
```

### PERCENTILE_CONT and PERCENTILE_DISC

These are **inverse distribution functions** (find the value at a given percentile).

```sql
-- PERCENTILE_CONT: continuous (interpolates between values)
-- PERCENTILE_DISC: discrete (returns an actual value from the dataset)

SELECT DISTINCT
    Department,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY Salary) OVER (PARTITION BY Department) AS MedianSalaryCont,
    PERCENTILE_DISC(0.5) WITHIN GROUP (ORDER BY Salary) OVER (PARTITION BY Department) AS MedianSalaryDisc
FROM dbo.Employees;

-- Example with 4 salaries: 60000, 70000, 90000, 100000
-- PERCENTILE_CONT(0.5) = 80000 (interpolated midpoint between 70000 and 90000)
-- PERCENTILE_DISC(0.5) = 70000 (actual value at or just above the 50th percentile)
```

> **Note**: These use `WITHIN GROUP (ORDER BY ...)` syntax rather than the standard `OVER (ORDER BY ...)` syntax. The `OVER` clause only takes `PARTITION BY`.

---

## Window Frame Specification

The frame clause defines which rows within the partition are included in the window function's calculation.

### Syntax

```sql
{ ROWS | RANGE } BETWEEN frame_start AND frame_end

-- frame_start / frame_end options:
-- UNBOUNDED PRECEDING   (first row of partition)
-- N PRECEDING           (N rows before current)
-- CURRENT ROW
-- N FOLLOWING           (N rows after current)
-- UNBOUNDED FOLLOWING   (last row of partition)
```

### ROWS vs RANGE

| Aspect | ROWS | RANGE |
|--------|------|-------|
| Unit | Physical rows | Logical values |
| Ties | Each row processed individually | All tied rows treated as a group |
| Performance | Generally faster | Can be slower (must handle ties) |
| Default (when ORDER BY is present) | N/A | `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |

```sql
-- Default frame when ORDER BY is specified:
-- RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
-- This means tied values are ALL included, which may not be what you expect!

-- Example showing the difference
DECLARE @t TABLE (Val INT);
INSERT INTO @t VALUES (1),(2),(2),(3);

-- ROWS: each physical row is distinct
SELECT Val, SUM(Val) OVER (ORDER BY Val ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RowsSum
FROM @t;
-- Val=1: 1, Val=2: 3, Val=2: 5, Val=3: 8

-- RANGE (default): ties are grouped together
SELECT Val, SUM(Val) OVER (ORDER BY Val RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RangeSum
FROM @t;
-- Val=1: 1, Val=2: 5, Val=2: 5, Val=3: 8
-- Both Val=2 rows see the same sum because RANGE includes all peers
```

### Common Frame Examples

```sql
-- All rows in partition (no ORDER BY needed for this)
SUM(Amount) OVER (PARTITION BY Category)

-- Running total (explicitly stated)
SUM(Amount) OVER (ORDER BY OrderDate ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)

-- 3-row moving average
AVG(Amount) OVER (ORDER BY OrderDate ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING)

-- 7-day moving average
AVG(Amount) OVER (ORDER BY OrderDate ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)

-- Remaining total (current row to end)
SUM(Amount) OVER (ORDER BY OrderDate ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)

-- Entire partition (override default frame)
SUM(Amount) OVER (ORDER BY OrderDate ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
```

---

## Running Totals

Running totals (cumulative sums) are one of the most common analytical patterns.

```sql
-- Running total of daily revenue
SELECT
    OrderDate,
    DailyRevenue,
    SUM(DailyRevenue) OVER (
        ORDER BY OrderDate
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS RunningTotal
FROM dbo.DailyRevenue;

-- Running total partitioned by year
SELECT
    OrderDate,
    DailyRevenue,
    SUM(DailyRevenue) OVER (
        PARTITION BY YEAR(OrderDate)
        ORDER BY OrderDate
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS YTDRevenue
FROM dbo.DailyRevenue;

-- Running count and running average
SELECT
    OrderDate,
    Amount,
    COUNT(*) OVER (ORDER BY OrderDate ROWS UNBOUNDED PRECEDING) AS RunningCount,
    AVG(Amount) OVER (ORDER BY OrderDate ROWS UNBOUNDED PRECEDING) AS RunningAvg,
    SUM(Amount) OVER (ORDER BY OrderDate ROWS UNBOUNDED PRECEDING) AS RunningSum
FROM dbo.Orders;
```

> **Performance Note**: Prior to SQL Server 2012, running totals required correlated subqueries, self-joins, or cursors. Window functions with frame specifications are dramatically faster and more readable.

---

## Moving Averages

Moving (rolling) averages smooth out short-term fluctuations to reveal trends.

```sql
-- 7-day moving average
SELECT
    OrderDate,
    DailyRevenue,
    AVG(DailyRevenue) OVER (
        ORDER BY OrderDate
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS MovingAvg7Day,
    -- 30-day moving average
    AVG(DailyRevenue) OVER (
        ORDER BY OrderDate
        ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
    ) AS MovingAvg30Day,
    -- Centered 5-day moving average
    AVG(DailyRevenue) OVER (
        ORDER BY OrderDate
        ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING
    ) AS CenteredMovingAvg5
FROM dbo.DailyRevenue
ORDER BY OrderDate;

-- Moving sum and moving count (to verify the window size)
SELECT
    OrderDate,
    DailyRevenue,
    SUM(DailyRevenue) OVER (ORDER BY OrderDate ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS MovingSum7,
    COUNT(*) OVER (ORDER BY OrderDate ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS WindowSize
FROM dbo.DailyRevenue;
-- WindowSize will be < 7 for the first 6 rows (not enough preceding rows)
```

### Handling Gaps in Dates

The ROWS frame counts physical rows, not calendar days. If dates have gaps, use a calendar table.

```sql
-- Ensure complete date coverage with a calendar table
SELECT
    c.CalendarDate,
    COALESCE(r.DailyRevenue, 0) AS DailyRevenue,
    AVG(COALESCE(r.DailyRevenue, 0)) OVER (
        ORDER BY c.CalendarDate
        ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
    ) AS MovingAvg7Day
FROM dbo.Calendar c
LEFT JOIN dbo.DailyRevenue r ON c.CalendarDate = r.OrderDate
WHERE c.CalendarDate BETWEEN '2026-01-01' AND '2026-03-31'
ORDER BY c.CalendarDate;
```

---

## Gaps and Islands Problem

The **gaps and islands** problem involves identifying contiguous sequences (islands) and missing values (gaps) in ordered data. This is a classic analytical challenge.

### Islands: Consecutive Date Ranges

```sql
-- Sample data: employee attendance dates (not every day)
-- Find contiguous attendance streaks

-- Method 1: ROW_NUMBER difference
WITH Numbered AS (
    SELECT
        EmployeeID,
        AttendanceDate,
        DATEADD(DAY,
            -ROW_NUMBER() OVER (PARTITION BY EmployeeID ORDER BY AttendanceDate),
            AttendanceDate
        ) AS GroupKey
    FROM dbo.Attendance
)
SELECT
    EmployeeID,
    MIN(AttendanceDate) AS IslandStart,
    MAX(AttendanceDate) AS IslandEnd,
    DATEDIFF(DAY, MIN(AttendanceDate), MAX(AttendanceDate)) + 1 AS ConsecutiveDays
FROM Numbered
GROUP BY EmployeeID, GroupKey
ORDER BY EmployeeID, IslandStart;
```

**How it works**: For consecutive dates, subtracting a sequential ROW_NUMBER produces the same result. Dates {Jan 5, Jan 6, Jan 7} with row numbers {1, 2, 3} yields {Jan 4, Jan 4, Jan 4}. This constant becomes the grouping key.

### Islands: Consecutive Integer Sequences

```sql
-- Find consecutive number ranges
WITH Numbered AS (
    SELECT
        Value,
        Value - ROW_NUMBER() OVER (ORDER BY Value) AS GroupKey
    FROM dbo.Numbers
)
SELECT
    MIN(Value) AS RangeStart,
    MAX(Value) AS RangeEnd,
    COUNT(*) AS RangeLength
FROM Numbered
GROUP BY GroupKey
ORDER BY RangeStart;

-- Input:  1, 2, 3, 7, 8, 12, 13, 14, 15
-- Output: [1-3], [7-8], [12-15]
```

### Gaps: Finding Missing Values

```sql
-- Find gaps in a sequence of order numbers
SELECT
    OrderNum + 1 AS GapStart,
    NextOrderNum - 1 AS GapEnd,
    NextOrderNum - OrderNum - 1 AS GapSize
FROM (
    SELECT
        OrderNum,
        LEAD(OrderNum) OVER (ORDER BY OrderNum) AS NextOrderNum
    FROM dbo.Orders
) t
WHERE NextOrderNum - OrderNum > 1;
```

### Islands with LAG (Alternative Method)

```sql
-- Use LAG to detect island boundaries
WITH Flagged AS (
    SELECT
        EmployeeID,
        AttendanceDate,
        CASE
            WHEN DATEDIFF(DAY,
                LAG(AttendanceDate) OVER (PARTITION BY EmployeeID ORDER BY AttendanceDate),
                AttendanceDate) = 1
            THEN 0  -- continuation
            ELSE 1  -- new island
        END AS IsNewIsland
    FROM dbo.Attendance
),
Grouped AS (
    SELECT
        EmployeeID,
        AttendanceDate,
        SUM(IsNewIsland) OVER (PARTITION BY EmployeeID ORDER BY AttendanceDate) AS IslandID
    FROM Flagged
)
SELECT
    EmployeeID,
    IslandID,
    MIN(AttendanceDate) AS IslandStart,
    MAX(AttendanceDate) AS IslandEnd
FROM Grouped
GROUP BY EmployeeID, IslandID;
```

---

## De-Duplication Patterns

Window functions are the standard approach for removing duplicate rows.

### Basic De-Duplication with ROW_NUMBER

```sql
-- Keep the most recent record per customer
WITH Ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY CustomerID
            ORDER BY ModifiedDate DESC
        ) AS rn
    FROM dbo.CustomerStaging
)
-- Keep only the first row per customer
SELECT * FROM Ranked WHERE rn = 1;

-- Delete duplicates (keep the most recent)
WITH Ranked AS (
    SELECT
        ROW_NUMBER() OVER (
            PARTITION BY CustomerID
            ORDER BY ModifiedDate DESC
        ) AS rn
    FROM dbo.CustomerStaging
)
DELETE FROM Ranked WHERE rn > 1;
```

### De-Duplication with Multiple Criteria

```sql
-- Complex tie-breaking: keep the row with the highest priority source,
-- then most recent date, then lowest ID (as final tiebreaker)
WITH Ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY Email
            ORDER BY
                SourcePriority ASC,     -- 1 = CRM, 2 = Web, 3 = Import
                LastUpdated DESC,
                RecordID ASC
        ) AS rn
    FROM dbo.ContactStaging
)
SELECT * FROM Ranked WHERE rn = 1;
```

### Identifying Duplicates (Without Deleting)

```sql
-- Flag duplicates for review
SELECT
    *,
    COUNT(*) OVER (PARTITION BY Email) AS DuplicateCount,
    ROW_NUMBER() OVER (PARTITION BY Email ORDER BY CreatedDate) AS DuplicateSequence,
    CASE
        WHEN ROW_NUMBER() OVER (PARTITION BY Email ORDER BY CreatedDate) = 1
        THEN 'Keep'
        ELSE 'Duplicate'
    END AS DuplicateStatus
FROM dbo.Contacts;
```

---

## Top-N Per Group

Retrieving the top N rows from each group is one of the most common window function patterns.

### Top-N Using ROW_NUMBER

```sql
-- Top 3 highest-paid employees per department
WITH Ranked AS (
    SELECT
        Department,
        EmployeeID,
        EmployeeName,
        Salary,
        ROW_NUMBER() OVER (PARTITION BY Department ORDER BY Salary DESC) AS rn
    FROM dbo.Employees
)
SELECT Department, EmployeeID, EmployeeName, Salary
FROM Ranked
WHERE rn <= 3
ORDER BY Department, rn;
```

### Top-N with Ties Using RANK or DENSE_RANK

```sql
-- Top 3 salaries per department (including ties)
WITH Ranked AS (
    SELECT
        Department,
        EmployeeID,
        EmployeeName,
        Salary,
        DENSE_RANK() OVER (PARTITION BY Department ORDER BY Salary DESC) AS dr
    FROM dbo.Employees
)
SELECT Department, EmployeeID, EmployeeName, Salary
FROM Ranked
WHERE dr <= 3;
-- If 2 employees tie for 3rd highest salary, both are included
```

### Top-1 Per Group (Latest Record)

```sql
-- Most recent order per customer
-- Method 1: ROW_NUMBER + CTE
WITH Latest AS (
    SELECT
        CustomerID,
        OrderID,
        OrderDate,
        Amount,
        ROW_NUMBER() OVER (PARTITION BY CustomerID ORDER BY OrderDate DESC) AS rn
    FROM dbo.Orders
)
SELECT CustomerID, OrderID, OrderDate, Amount
FROM Latest
WHERE rn = 1;

-- Method 2: CROSS APPLY with TOP (alternative, sometimes faster)
SELECT
    c.CustomerID,
    c.CustomerName,
    o.OrderID,
    o.OrderDate,
    o.Amount
FROM dbo.Customers c
CROSS APPLY (
    SELECT TOP 1 OrderID, OrderDate, Amount
    FROM dbo.Orders o
    WHERE o.CustomerID = c.CustomerID
    ORDER BY o.OrderDate DESC
) o;
```

---

## Sessionization

Sessionization is the process of grouping sequential events into logical sessions, typically based on a time-gap threshold. This is essential for clickstream analysis, IoT data, and user behavior analytics.

### Basic Sessionization (30-Minute Timeout)

```sql
-- Assign session IDs based on 30-minute inactivity gaps
WITH EventsWithGap AS (
    SELECT
        UserID,
        EventTime,
        EventType,
        DATEDIFF(MINUTE,
            LAG(EventTime) OVER (PARTITION BY UserID ORDER BY EventTime),
            EventTime
        ) AS MinutesSinceLastEvent
    FROM dbo.UserEvents
),
SessionBoundaries AS (
    SELECT
        UserID,
        EventTime,
        EventType,
        MinutesSinceLastEvent,
        CASE
            WHEN MinutesSinceLastEvent IS NULL OR MinutesSinceLastEvent > 30
            THEN 1  -- new session
            ELSE 0
        END AS IsNewSession
    FROM EventsWithGap
),
SessionAssigned AS (
    SELECT
        UserID,
        EventTime,
        EventType,
        SUM(IsNewSession) OVER (
            PARTITION BY UserID
            ORDER BY EventTime
            ROWS UNBOUNDED PRECEDING
        ) AS SessionNum
    FROM SessionBoundaries
)
SELECT
    UserID,
    SessionNum,
    EventTime,
    EventType,
    MIN(EventTime) OVER (PARTITION BY UserID, SessionNum) AS SessionStart,
    MAX(EventTime) OVER (PARTITION BY UserID, SessionNum) AS SessionEnd,
    COUNT(*) OVER (PARTITION BY UserID, SessionNum) AS EventsInSession
FROM SessionAssigned
ORDER BY UserID, EventTime;
```

### Session Summary Statistics

```sql
-- Building on the SessionAssigned CTE above
SELECT
    UserID,
    SessionNum,
    MIN(EventTime) AS SessionStart,
    MAX(EventTime) AS SessionEnd,
    DATEDIFF(MINUTE, MIN(EventTime), MAX(EventTime)) AS SessionDurationMinutes,
    COUNT(*) AS EventCount,
    COUNT(DISTINCT EventType) AS UniqueEventTypes
FROM SessionAssigned
GROUP BY UserID, SessionNum
ORDER BY UserID, SessionNum;
```

### Sessionization Pattern Breakdown

The technique follows three steps:

1. **Calculate gaps**: Use `LAG` to find the time difference between consecutive events per user.
2. **Flag boundaries**: Mark events where the gap exceeds the threshold as new session starts (1/0 flag).
3. **Assign session IDs**: Use a running `SUM` of the boundary flags to generate incrementing session numbers.

---

## Common Interview Questions

### Q1: What is the difference between ROW_NUMBER, RANK, and DENSE_RANK?

**A**: All three assign ordinal numbers within partitions. `ROW_NUMBER` always produces unique values even for ties (tiebreaker is nondeterministic unless the ORDER BY is fully unique). `RANK` assigns the same number to ties but leaves gaps (e.g., 1, 2, 2, 4). `DENSE_RANK` assigns the same number to ties without gaps (e.g., 1, 2, 2, 3). Use ROW_NUMBER for de-duplication, RANK for competitive ranking with gaps, DENSE_RANK for ranking when you need consecutive rank values.

### Q2: Explain the difference between ROWS and RANGE in window frame specifications.

**A**: `ROWS` operates on physical row positions relative to the current row. `RANGE` operates on logical values, grouping all rows with the same ORDER BY value (peers) together. The key difference appears with ties: `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` processes each physical row individually, while `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (the default when ORDER BY is present) includes all rows with the same ORDER BY value as the current row. ROWS is generally preferred for predictable behavior and better performance.

### Q3: Why does LAST_VALUE often return unexpected results?

**A**: Because the default window frame when ORDER BY is specified is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. This means LAST_VALUE only sees rows up to and including the current row, so it always returns the current row's value. To get the true last value in the partition, you must explicitly specify `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`. FIRST_VALUE does not have this problem because the first row is always within the default frame.

### Q4: How would you calculate a running total in SQL Server?

**A**: Use `SUM() OVER (ORDER BY ... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. The `ROWS` frame with `UNBOUNDED PRECEDING` ensures all rows from the start of the partition through the current row are summed. Always use `ROWS` instead of `RANGE` for running totals to avoid unexpected behavior with ties and for better performance. Prior to SQL Server 2012, running totals required self-joins, correlated subqueries, or cursors.

### Q5: Explain the gaps and islands problem and how to solve it.

**A**: The gaps and islands problem involves finding contiguous sequences (islands) and missing values (gaps) in ordered data. The classic solution for islands uses the ROW_NUMBER subtraction technique: subtract a sequential ROW_NUMBER from each value. For consecutive values, this produces a constant that becomes the grouping key. For gaps, use `LEAD` to find the next value and identify where the difference exceeds 1. An alternative island detection method uses `LAG` to flag boundary rows, then a running SUM to assign group IDs.

### Q6: How do you remove duplicates from a table using window functions?

**A**: Use `ROW_NUMBER() OVER (PARTITION BY <duplicate_key_columns> ORDER BY <preference_columns>)` in a CTE, then DELETE all rows where the row number exceeds 1. The PARTITION BY defines what constitutes a duplicate, and the ORDER BY determines which row to keep (e.g., most recent, highest priority). This is both efficient and readable.

### Q7: What is sessionization and how do you implement it with window functions?

**A**: Sessionization groups sequential events into logical sessions based on a time-gap threshold. Implementation uses three steps: (1) LAG to compute the time gap between consecutive events per user, (2) a CASE expression to flag events where the gap exceeds the threshold as new session starts, (3) a running SUM of those flags to assign session IDs. This is a common pattern in clickstream analysis and user behavior tracking.

### Q8: How do you get the top-N rows per group?

**A**: Use `ROW_NUMBER() OVER (PARTITION BY group_column ORDER BY ranking_column DESC)` in a CTE, then filter `WHERE rn <= N`. Use `DENSE_RANK` instead of `ROW_NUMBER` if you want to include ties. An alternative for top-1 per group is `CROSS APPLY` with `TOP 1`, which can sometimes be faster due to better index utilization. For very large datasets, benchmark both approaches.

### Q9: What is the difference between PERCENTILE_CONT and PERCENTILE_DISC?

**A**: `PERCENTILE_CONT` calculates a continuous percentile by interpolating between values. For the median of {10, 20, 30, 40}, it returns 25 (midpoint between 20 and 30). `PERCENTILE_DISC` returns an actual discrete value from the dataset. For the same set, it returns 20 (the value at or just above the 50th percentile position). PERCENTILE_CONT is more mathematically precise; PERCENTILE_DISC always returns a value that exists in the data.

### Q10: Can window functions be used in WHERE clauses?

**A**: No. Window functions are evaluated after WHERE, GROUP BY, and HAVING. They can only appear in the SELECT and ORDER BY clauses. To filter on a window function result, wrap the query in a CTE or subquery and filter in the outer query. For example, to filter on `ROW_NUMBER`, use `WITH cte AS (SELECT *, ROW_NUMBER() OVER (...) AS rn FROM T) SELECT * FROM cte WHERE rn = 1`.

---

## Tips

- **Always use ROWS instead of RANGE** for running totals and moving averages unless you explicitly need peer grouping. ROWS is faster and more predictable.
- **Beware the default frame.** When you add ORDER BY to a window aggregate, the default frame is `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, not the entire partition. This catches many developers off guard.
- **Make ROW_NUMBER deterministic** by ensuring the ORDER BY clause uniquely identifies each row. Add a tiebreaker column (like a primary key) to avoid nondeterministic results.
- **Window functions cannot be nested.** You cannot write `SUM(ROW_NUMBER() OVER (...)) OVER (...)`. Use CTEs or subqueries to layer window function calculations.
- **Multiple window functions with the same OVER clause** are optimized by SQL Server to share a single sort operation. Reuse identical OVER specifications when possible.
- **For large datasets**, ensure supporting indexes exist. A window function with `PARTITION BY A ORDER BY B` benefits from an index on `(A, B)`.
- **NTILE distributes remainders to earlier groups.** For 10 rows and NTILE(3), groups have 4, 3, 3 rows. Be aware of this uneven distribution.
- **Use window functions instead of correlated subqueries** for running calculations. They are almost always faster and more readable.
- **The sessionization pattern** (LAG to detect gaps, CASE to flag boundaries, running SUM to assign IDs) is a fundamental technique that applies to many domains beyond clickstream analysis: manufacturing line tracking, network packet analysis, and more.
- **Test window function performance** with actual data volumes. Small test datasets may not reveal sorting and memory grant issues that appear at scale. Check for Sort spills in execution plans.