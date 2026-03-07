# Stored Procedures, Functions & Triggers

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Stored Procedures](#stored-procedures)
2. [Parameter Handling](#parameter-handling)
3. [Dynamic SQL and SQL Injection Prevention](#dynamic-sql-and-sql-injection-prevention)
4. [User-Defined Functions](#user-defined-functions)
5. [Function Determinism and Schema Binding](#function-determinism-and-schema-binding)
6. [DML Triggers](#dml-triggers)
7. [DDL Triggers](#ddl-triggers)
8. [Trigger Management and Performance](#trigger-management-and-performance)
9. [Common Interview Questions](#common-interview-questions)
10. [Tips](#tips)

---

## Stored Procedures

Stored procedures are precompiled collections of T-SQL statements stored in the database. They are the primary mechanism for encapsulating business logic on the server side.

### Creating a Basic Stored Procedure

```sql
CREATE OR ALTER PROCEDURE dbo.usp_GetCustomerOrders
    @CustomerID INT,
    @StartDate DATE = NULL,       -- Optional parameter with default
    @EndDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;  -- Suppress "rows affected" messages

    SELECT
        o.OrderID,
        o.OrderDate,
        o.TotalAmount,
        o.Status
    FROM dbo.Orders o
    WHERE o.CustomerID = @CustomerID
      AND (@StartDate IS NULL OR o.OrderDate >= @StartDate)
      AND (@EndDate IS NULL OR o.OrderDate <= @EndDate)
    ORDER BY o.OrderDate DESC;
END;
GO
```

### Why SET NOCOUNT ON Matters

- Without it, SQL Server sends a `DONE_IN_PROC` message for every statement, adding network overhead.
- Some client libraries (especially older ODBC/OLE DB drivers) may misinterpret the row-count messages as result sets.
- Always include `SET NOCOUNT ON` at the top of every stored procedure.

### Stored Procedure Best Practices

| Practice | Reason |
|----------|--------|
| Use the `usp_` prefix (not `sp_`) | `sp_` prefix causes SQL Server to search the `master` database first, adding overhead |
| Always schema-qualify (`dbo.usp_...`) | Avoids plan cache pollution from different default schemas |
| Use `CREATE OR ALTER` (SQL Server 2016 SP1+) | Simplifies deployment scripts |
| Include error handling with `TRY...CATCH` | Prevents unhandled errors from leaving transactions open |
| Avoid `SELECT *` | Schema changes can break callers silently |
| Keep procedures focused (single responsibility) | Easier to maintain, test, and reuse |

---

## Parameter Handling

### Input Parameters

```sql
CREATE OR ALTER PROCEDURE dbo.usp_SearchProducts
    @ProductName NVARCHAR(100) = NULL,
    @CategoryID INT = NULL,
    @MinPrice DECIMAL(10,2) = 0.00,
    @MaxPrice DECIMAL(10,2) = 999999.99
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ProductID, ProductName, Price, CategoryID
    FROM dbo.Products
    WHERE (@ProductName IS NULL OR ProductName LIKE '%' + @ProductName + '%')
      AND (@CategoryID IS NULL OR CategoryID = @CategoryID)
      AND Price BETWEEN @MinPrice AND @MaxPrice;
END;
GO

-- Calling with named parameters (recommended for clarity)
EXEC dbo.usp_SearchProducts
    @CategoryID = 5,
    @MinPrice = 10.00;
```

### Output Parameters

Output parameters allow a procedure to return values to the caller beyond a result set.

```sql
CREATE OR ALTER PROCEDURE dbo.usp_CreateOrder
    @CustomerID INT,
    @ProductID INT,
    @Quantity INT,
    @NewOrderID INT OUTPUT,
    @OrderTotal DECIMAL(10,2) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @UnitPrice DECIMAL(10,2);
        SELECT @UnitPrice = Price FROM dbo.Products WHERE ProductID = @ProductID;

        SET @OrderTotal = @UnitPrice * @Quantity;

        INSERT INTO dbo.Orders (CustomerID, ProductID, Quantity, TotalAmount, OrderDate)
        VALUES (@CustomerID, @ProductID, @Quantity, @OrderTotal, GETDATE());

        SET @NewOrderID = SCOPE_IDENTITY();

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- Calling with output parameters
DECLARE @OrderID INT, @Total DECIMAL(10,2);
EXEC dbo.usp_CreateOrder
    @CustomerID = 101,
    @ProductID = 50,
    @Quantity = 3,
    @NewOrderID = @OrderID OUTPUT,
    @OrderTotal = @Total OUTPUT;

SELECT @OrderID AS NewOrderID, @Total AS OrderTotal;
```

### Return Values

Return values are integers used to indicate success or failure status (not for returning data).

```sql
CREATE OR ALTER PROCEDURE dbo.usp_DeactivateCustomer
    @CustomerID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerID = @CustomerID)
        RETURN -1;  -- Customer not found

    IF EXISTS (SELECT 1 FROM dbo.Orders WHERE CustomerID = @CustomerID AND Status = 'Pending')
        RETURN -2;  -- Has pending orders

    UPDATE dbo.Customers SET IsActive = 0 WHERE CustomerID = @CustomerID;
    RETURN 0;  -- Success
END;
GO

DECLARE @Result INT;
EXEC @Result = dbo.usp_DeactivateCustomer @CustomerID = 101;

IF @Result = 0 PRINT 'Customer deactivated successfully.';
ELSE IF @Result = -1 PRINT 'Customer not found.';
ELSE IF @Result = -2 PRINT 'Customer has pending orders.';
```

---

## Dynamic SQL and SQL Injection Prevention

### The Danger of Concatenated Dynamic SQL

```sql
-- NEVER DO THIS - Vulnerable to SQL injection
CREATE OR ALTER PROCEDURE dbo.usp_SearchUsers_UNSAFE
    @Username NVARCHAR(100)
AS
BEGIN
    DECLARE @SQL NVARCHAR(MAX);
    SET @SQL = N'SELECT * FROM dbo.Users WHERE Username = ''' + @Username + '''';
    EXEC(@SQL);
    -- An attacker passing: ' OR 1=1; DROP TABLE Users; --
    -- would cause catastrophic damage
END;
GO
```

### Safe Dynamic SQL with sp_executesql

`sp_executesql` is the correct way to execute dynamic SQL. It parameterizes input, preventing injection and enabling plan reuse.

```sql
CREATE OR ALTER PROCEDURE dbo.usp_DynamicSearch
    @TableName SYSNAME,
    @ColumnName SYSNAME,
    @SearchValue NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;

    -- Validate object names (cannot be parameterized)
    IF OBJECT_ID(QUOTENAME(@TableName)) IS NULL
    BEGIN
        RAISERROR('Invalid table name: %s', 16, 1, @TableName);
        RETURN;
    END

    -- Use QUOTENAME for identifiers, parameters for values
    DECLARE @SQL NVARCHAR(MAX);
    SET @SQL = N'SELECT * FROM ' + QUOTENAME(@TableName)
             + N' WHERE ' + QUOTENAME(@ColumnName) + N' = @pSearchValue';

    EXEC sp_executesql @SQL,
        N'@pSearchValue NVARCHAR(200)',
        @pSearchValue = @SearchValue;
END;
GO
```

### Key Points for Dynamic SQL

- **Always use `sp_executesql`** over `EXEC()` for parameterized queries.
- **Use `QUOTENAME()`** for dynamic object names (tables, columns) -- it wraps identifiers in brackets and escapes embedded brackets.
- **Validate dynamic object names** against system catalogs before use.
- **`sp_executesql` enables plan caching** because parameterized queries produce reusable plans.

---

## User-Defined Functions

SQL Server supports three types of user-defined functions, each with different characteristics and performance profiles.

### Scalar Functions

Return a single value. Historically a major performance concern in SQL Server.

```sql
CREATE OR ALTER FUNCTION dbo.fn_CalculateTax
(
    @Amount DECIMAL(18,2),
    @TaxRate DECIMAL(5,4)
)
RETURNS DECIMAL(18,2)
WITH SCHEMABINDING
AS
BEGIN
    RETURN @Amount * @TaxRate;
END;
GO

-- Usage (called per row -- can be slow on large datasets)
SELECT
    OrderID,
    TotalAmount,
    dbo.fn_CalculateTax(TotalAmount, 0.0825) AS TaxAmount
FROM dbo.Orders;
```

**Scalar function performance note (SQL Server 2019+):** Scalar UDF Inlining can automatically transform eligible scalar functions into inline expressions within the calling query, dramatically improving performance. The function must meet certain requirements (no loops, no table variables, etc.) to be inlineable.

### Inline Table-Valued Functions (iTVFs)

Return a table based on a single `SELECT` statement. These are the **best-performing** UDF type because the optimizer can inline them into the outer query.

```sql
CREATE OR ALTER FUNCTION dbo.fn_GetCustomerOrders
(
    @CustomerID INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT
        o.OrderID,
        o.OrderDate,
        o.TotalAmount,
        p.ProductName
    FROM dbo.Orders o
    INNER JOIN dbo.Products p ON o.ProductID = p.ProductID
    WHERE o.CustomerID = @CustomerID
);
GO

-- Usage - optimizer treats this like a view/subquery
SELECT *
FROM dbo.fn_GetCustomerOrders(101)
WHERE TotalAmount > 50.00;
```

### Multi-Statement Table-Valued Functions (MSTVFs)

Return a table variable populated by multiple statements. These perform poorly because the optimizer cannot see inside them and typically estimates 1 row (or 100 rows in SQL Server 2017+ with interleaved execution).

```sql
CREATE OR ALTER FUNCTION dbo.fn_GetOrderSummary
(
    @Year INT
)
RETURNS @Summary TABLE
(
    MonthNumber INT,
    MonthName NVARCHAR(20),
    OrderCount INT,
    TotalRevenue DECIMAL(18,2)
)
AS
BEGIN
    INSERT INTO @Summary
    SELECT
        MONTH(OrderDate),
        DATENAME(MONTH, OrderDate),
        COUNT(*),
        SUM(TotalAmount)
    FROM dbo.Orders
    WHERE YEAR(OrderDate) = @Year
    GROUP BY MONTH(OrderDate), DATENAME(MONTH, OrderDate);

    -- Fill in missing months with zeros
    ;WITH Months AS (
        SELECT TOP 12 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS MonthNum
        FROM sys.objects
    )
    INSERT INTO @Summary
    SELECT m.MonthNum, DATENAME(MONTH, DATEFROMPARTS(@Year, m.MonthNum, 1)), 0, 0.00
    FROM Months m
    WHERE m.MonthNum NOT IN (SELECT MonthNumber FROM @Summary);

    RETURN;
END;
GO
```

### Function Type Comparison

| Feature | Scalar | Inline TVF | Multi-Statement TVF |
|---------|--------|-----------|---------------------|
| Returns | Single value | Table (single SELECT) | Table (multiple statements) |
| Performance | Poor (pre-2019) / Good if inlined (2019+) | Excellent (inlined by optimizer) | Poor (opaque to optimizer) |
| Can use in WHERE clause | Yes | Yes (with CROSS/OUTER APPLY) | Yes (with APPLY) |
| Optimizer visibility | Limited | Full | None (cardinality estimates are poor) |
| Recommendation | Use sparingly; prefer iTVFs | Preferred approach | Avoid if possible; rewrite as iTVF |

---

## Function Determinism and Schema Binding

### Determinism

A function is **deterministic** if it always returns the same result for the same input parameters.

- **Deterministic:** `UPPER()`, `DATEDIFF()`, custom functions using only deterministic operations
- **Non-deterministic:** `GETDATE()`, `NEWID()`, `RAND()` (without seed)

Determinism matters because:
- Only deterministic, schema-bound functions can be used in computed columns that are persisted or indexed.
- The optimizer can make better decisions with deterministic functions.

### Schema Binding

`WITH SCHEMABINDING` prevents the underlying objects from being modified in ways that would break the function.

```sql
CREATE OR ALTER FUNCTION dbo.fn_GetFullName
(
    @FirstName NVARCHAR(50),
    @LastName NVARCHAR(50)
)
RETURNS NVARCHAR(101)
WITH SCHEMABINDING   -- Required for indexed computed columns
AS
BEGIN
    RETURN @FirstName + N' ' + @LastName;
END;
GO

-- Now you can use it in a persisted computed column
ALTER TABLE dbo.Employees
    ADD FullName AS dbo.fn_GetFullName(FirstName, LastName) PERSISTED;
```

---

## DML Triggers

DML triggers fire in response to `INSERT`, `UPDATE`, or `DELETE` operations on a table or view.

### AFTER Triggers

Fire after the DML statement completes (but before the transaction commits).

```sql
CREATE OR ALTER TRIGGER trg_Orders_Audit
ON dbo.Orders
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- INSERTED contains new/updated rows
    -- DELETED contains old/deleted rows
    -- UPDATE: both tables populated
    -- INSERT: only INSERTED
    -- DELETE: only DELETED

    INSERT INTO dbo.OrderAudit (OrderID, Action, OldAmount, NewAmount, ChangedBy, ChangedAt)
    SELECT
        COALESCE(i.OrderID, d.OrderID),
        CASE
            WHEN i.OrderID IS NOT NULL AND d.OrderID IS NOT NULL THEN 'UPDATE'
            WHEN i.OrderID IS NOT NULL THEN 'INSERT'
            ELSE 'DELETE'
        END,
        d.TotalAmount,
        i.TotalAmount,
        SUSER_SNAME(),
        GETDATE()
    FROM INSERTED i
    FULL OUTER JOIN DELETED d ON i.OrderID = d.OrderID;
END;
GO
```

### INSTEAD OF Triggers

Replace the triggering DML statement entirely. Commonly used on views to make them updatable.

```sql
-- View that joins two tables
CREATE OR ALTER VIEW dbo.vw_EmployeeDetails
AS
    SELECT e.EmployeeID, e.FirstName, e.LastName, d.DepartmentName
    FROM dbo.Employees e
    INNER JOIN dbo.Departments d ON e.DepartmentID = d.DepartmentID;
GO

-- INSTEAD OF trigger makes the view updatable
CREATE OR ALTER TRIGGER trg_vw_EmployeeDetails_Insert
ON dbo.vw_EmployeeDetails
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.Employees (FirstName, LastName, DepartmentID)
    SELECT
        i.FirstName,
        i.LastName,
        d.DepartmentID
    FROM INSERTED i
    INNER JOIN dbo.Departments d ON i.DepartmentName = d.DepartmentName;
END;
GO
```

### INSERTED and DELETED Pseudo-Tables

| Operation | INSERTED | DELETED |
|-----------|----------|---------|
| INSERT | New rows | Empty |
| DELETE | Empty | Removed rows |
| UPDATE | New row values | Old row values (before update) |

**Key point:** Always write triggers to handle multi-row operations. Never assume a trigger fires once per row -- it fires once per statement, and `INSERTED`/`DELETED` can contain many rows.

```sql
-- WRONG: Assumes single row
CREATE OR ALTER TRIGGER trg_Bad
ON dbo.Orders
AFTER INSERT
AS
BEGIN
    DECLARE @OrderID INT;
    SELECT @OrderID = OrderID FROM INSERTED;  -- Loses rows if multiple inserted!
    -- ...
END;
GO

-- CORRECT: Handles multiple rows
CREATE OR ALTER TRIGGER trg_Good
ON dbo.Orders
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE o
    SET o.ProcessedDate = GETDATE()
    FROM dbo.Orders o
    INNER JOIN INSERTED i ON o.OrderID = i.OrderID;
END;
GO
```

---

## DDL Triggers

DDL triggers fire in response to Data Definition Language events (CREATE, ALTER, DROP, etc.).

### Database-Scoped DDL Trigger

```sql
CREATE TRIGGER trg_PreventTableDrop
ON DATABASE
FOR DROP_TABLE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @EventData XML = EVENTDATA();
    DECLARE @TableName NVARCHAR(256);

    SET @TableName = @EventData.value('(/EVENT_INSTANCE/ObjectName)[1]', 'NVARCHAR(256)');

    -- Prevent dropping tables in production
    PRINT 'DROP TABLE is not allowed. Table: ' + @TableName;
    ROLLBACK;
END;
GO
```

### Server-Scoped DDL Trigger

```sql
CREATE TRIGGER trg_AuditLogins
ON ALL SERVER
FOR CREATE_LOGIN, ALTER_LOGIN, DROP_LOGIN
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO master.dbo.DDLAuditLog (EventData, EventDate, LoginName)
    VALUES (EVENTDATA(), GETDATE(), SUSER_SNAME());
END;
GO
```

### EVENTDATA() Function

Returns XML with details about the DDL event:

```xml
<EVENT_INSTANCE>
    <EventType>DROP_TABLE</EventType>
    <PostTime>2026-03-07T10:30:00.000</PostTime>
    <SPID>55</SPID>
    <ServerName>PROD-SQL01</ServerName>
    <LoginName>domain\admin</LoginName>
    <DatabaseName>SalesDB</DatabaseName>
    <SchemaName>dbo</SchemaName>
    <ObjectName>TempOrders</ObjectName>
    <ObjectType>TABLE</ObjectType>
    <TSQLCommand>
        <CommandText>DROP TABLE dbo.TempOrders</CommandText>
    </TSQLCommand>
</EVENT_INSTANCE>
```

---

## Trigger Management and Performance

### Nested Triggers

Triggers that cause other triggers to fire. Controlled by a server setting.

```sql
-- Check current setting
SELECT CASE WHEN value_in_use = 1 THEN 'Enabled' ELSE 'Disabled' END AS NestedTriggers
FROM sys.configurations
WHERE name = 'nested triggers';

-- Disable nested triggers (server-wide)
EXEC sp_configure 'nested triggers', 0;
RECONFIGURE;
```

Nested triggers can go up to 32 levels deep. Exceeding this causes the entire transaction to roll back.

### Recursive Triggers

A trigger that fires itself (directly or indirectly). Controlled at the database level.

```sql
-- Enable recursive triggers for a database
ALTER DATABASE SalesDB SET RECURSIVE_TRIGGERS ON;

-- Check setting
SELECT is_recursive_triggers_on
FROM sys.databases
WHERE name = 'SalesDB';
```

- **Direct recursion:** Trigger on TableA fires, modifies TableA, fires the same trigger again.
- **Indirect recursion:** Trigger on TableA modifies TableB, whose trigger modifies TableA, firing the original trigger.

### Disabling and Enabling Triggers

```sql
-- Disable a specific trigger
DISABLE TRIGGER trg_Orders_Audit ON dbo.Orders;

-- Enable it back
ENABLE TRIGGER trg_Orders_Audit ON dbo.Orders;

-- Disable ALL triggers on a table
DISABLE TRIGGER ALL ON dbo.Orders;

-- Disable a DDL trigger
DISABLE TRIGGER trg_PreventTableDrop ON DATABASE;
```

### Trigger Performance Impact

| Concern | Details |
|---------|---------|
| Transaction scope | Triggers run inside the triggering transaction; slow triggers hold locks longer |
| Hidden logic | Developers may not realize a simple INSERT triggers complex cascading logic |
| Row-by-row traps | Cursors or scalar logic in triggers can devastate performance |
| Debugging difficulty | Trigger logic is less visible than application code or stored procedures |
| Plan cache | Each trigger has its own execution plan cached separately |

**General guidance:** Use triggers sparingly. Prefer application logic or stored procedures for complex operations. Reserve triggers for auditing, enforcing cross-table constraints, or preventing certain operations.

---

## Common Interview Questions

### Q1: What is the difference between a stored procedure and a function?

**A:** Stored procedures can perform DML, use output parameters, call other procedures, and return multiple result sets. They cannot be used in a SELECT statement. Functions must return a value (scalar or table), cannot perform DML on permanent tables (except table variables), and can be used in SELECT, WHERE, and JOIN clauses. Functions are meant to be deterministic computations; procedures are meant to encapsulate business processes.

### Q2: Why should you avoid the `sp_` prefix for stored procedures?

**A:** When SQL Server encounters a procedure with the `sp_` prefix, it first searches the `master` database before checking the current database. This adds unnecessary overhead on every call and can lead to name collisions with system procedures.

### Q3: What is the difference between `EXEC()` and `sp_executesql`?

**A:** `EXEC()` concatenates and executes a string, offering no parameterization and no plan reuse across different parameter values. `sp_executesql` accepts a parameterized query string with a parameter definition and values, enabling plan reuse and preventing SQL injection for the parameterized values.

### Q4: Why are inline table-valued functions preferred over multi-statement TVFs?

**A:** Inline TVFs contain a single SELECT and are expanded by the optimizer into the calling query, allowing it to choose optimal join strategies and use accurate cardinality estimates. MSTVFs are opaque to the optimizer, which historically estimates 1 row (100 in SQL Server 2017+), often producing terrible execution plans.

### Q5: Can an INSTEAD OF trigger and an AFTER trigger exist on the same table for the same operation?

**A:** Yes. The INSTEAD OF trigger fires first and replaces the original statement. If the INSTEAD OF trigger performs the DML operation itself, the AFTER trigger will then fire on that operation. If the INSTEAD OF trigger does not perform the DML, the AFTER trigger does not fire.

### Q6: How do you determine what changed in an UPDATE trigger?

**A:** Use the `UPDATE()` or `COLUMNS_UPDATED()` functions to check which columns were targeted by the SET clause. Compare INSERTED and DELETED pseudo-tables to see actual value changes.

```sql
CREATE OR ALTER TRIGGER trg_PriceChange
ON dbo.Products
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF UPDATE(Price)
    BEGIN
        INSERT INTO dbo.PriceHistory (ProductID, OldPrice, NewPrice, ChangedAt)
        SELECT d.ProductID, d.Price, i.Price, GETDATE()
        FROM INSERTED i
        INNER JOIN DELETED d ON i.ProductID = d.ProductID
        WHERE i.Price <> d.Price;  -- Only log actual changes
    END
END;
GO
```

### Q7: What happens if a trigger raises an error?

**A:** If an unhandled error occurs in a trigger, the entire triggering transaction is rolled back. The trigger executes within the same transaction context as the DML statement, so any failure in the trigger fails the entire operation.

### Q8: What is Scalar UDF Inlining and when is it available?

**A:** Introduced in SQL Server 2019, Scalar UDF Inlining automatically transforms eligible scalar user-defined functions into inline relational expressions in the calling query. This eliminates the per-row function call overhead. The function must be deterministic, schema-bound (or meet other criteria), and not contain certain constructs (loops, multiple RETURN statements, table variables, etc.).

---

## Tips

- **SET NOCOUNT ON** should be the first line in every stored procedure and trigger. It reduces network traffic and avoids confusing some client drivers.
- **Never use `sp_` prefix** for user procedures. Use `usp_` or another convention.
- **Prefer inline TVFs** over all other function types whenever possible. They are the only function type that performs like a view.
- **Design triggers for set-based operations.** Never assume single-row execution.
- **Use `sp_executesql` exclusively** for dynamic SQL. Pair it with `QUOTENAME()` for dynamic identifiers.
- **Test trigger performance** under realistic concurrency. A trigger that is fast in isolation may cause blocking under load because it extends the transaction duration.
- **Avoid business logic in triggers** when possible. They make systems harder to debug, test, and maintain. Use them primarily for auditing and constraint enforcement.
- **Document all triggers** thoroughly. They are the most "hidden" code in a database and a frequent source of unexpected behavior during troubleshooting.
- **Check for inlineability** on SQL Server 2019+ using `SELECT OBJECT_NAME(object_id), is_inlineable FROM sys.sql_modules WHERE is_inlineable = 1;`
