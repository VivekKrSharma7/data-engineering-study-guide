# CLR Integration

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [CLR Overview in SQL Server](#clr-overview-in-sql-server)
2. [Enabling CLR Integration](#enabling-clr-integration)
3. [Creating CLR Assemblies](#creating-clr-assemblies)
4. [CLR Stored Procedures](#clr-stored-procedures)
5. [CLR Functions](#clr-functions)
6. [CLR Aggregates](#clr-aggregates)
7. [CLR User-Defined Types](#clr-user-defined-types)
8. [Permission Sets: SAFE, EXTERNAL_ACCESS, UNSAFE](#permission-sets-safe-external_access-unsafe)
9. [CLR in SQL Server 2017+ (Strict Security)](#clr-in-sql-server-2017-strict-security)
10. [CLR vs T-SQL Performance Comparison](#clr-vs-t-sql-performance-comparison)
11. [Use Cases](#use-cases)
12. [Security Considerations](#security-considerations)
13. [Deployment and Management](#deployment-and-management)
14. [Common Interview Questions](#common-interview-questions)
15. [Tips](#tips)

---

## CLR Overview in SQL Server

CLR (Common Language Runtime) integration allows you to write database objects -- stored procedures, functions, aggregates, triggers, and user-defined types -- in .NET languages (C#, VB.NET) instead of T-SQL. The .NET CLR is hosted directly inside the SQL Server process.

### Why CLR Exists

T-SQL is optimized for set-based data operations but is poor at:
- Complex string manipulation and parsing
- Regular expression matching
- Mathematical computations (statistical, scientific)
- Custom aggregations not possible in T-SQL
- Accessing external resources (files, web services, OS features)

CLR fills these gaps by allowing managed .NET code to execute within the SQL Server engine while maintaining security boundaries.

### Architecture

```
+---------------------------------------------------+
|              SQL Server Process                    |
|                                                    |
|  +-------------+    +-------------------------+   |
|  |  SQL Engine  |<-->|  Hosted CLR Runtime      |   |
|  |  (T-SQL)     |    |  (AppDomain per DB)      |   |
|  +-------------+    |  - Loaded Assemblies      |   |
|                      |  - Permission enforcement |   |
|                      +-------------------------+   |
+---------------------------------------------------+
```

- SQL Server hosts the CLR in-process (not out-of-process).
- Each database with CLR objects gets its own AppDomain for isolation.
- SQL Server controls memory allocation, threading, and garbage collection for the hosted CLR.

---

## Enabling CLR Integration

CLR integration is disabled by default and must be explicitly enabled.

```sql
-- Enable CLR integration
EXEC sp_configure 'clr enabled', 1;
RECONFIGURE;

-- Verify
SELECT name, value_in_use
FROM sys.configurations
WHERE name = 'clr enabled';
```

### Additional Requirement for SQL Server 2017+

Starting with SQL Server 2017, CLR assemblies require additional trust configuration due to **strict security** (see dedicated section below).

---

## Creating CLR Assemblies

### Step 1: Write .NET Code (C# Example)

```csharp
using System;
using System.Data.SqlTypes;
using System.Text.RegularExpressions;
using Microsoft.SqlServer.Server;

public class StringUtilities
{
    [SqlFunction(IsDeterministic = true, IsPrecise = true,
                 DataAccess = DataAccessKind.None)]
    public static SqlBoolean RegexMatch(SqlString input, SqlString pattern)
    {
        if (input.IsNull || pattern.IsNull)
            return SqlBoolean.Null;

        return new SqlBoolean(Regex.IsMatch(input.Value, pattern.Value));
    }

    [SqlFunction(IsDeterministic = true, IsPrecise = true,
                 DataAccess = DataAccessKind.None)]
    public static SqlString RegexReplace(SqlString input, SqlString pattern, SqlString replacement)
    {
        if (input.IsNull || pattern.IsNull || replacement.IsNull)
            return SqlString.Null;

        return new SqlString(Regex.Replace(input.Value, pattern.Value, replacement.Value));
    }
}
```

### Step 2: Compile to a DLL

```bash
csc /target:library /out:StringUtilities.dll StringUtilities.cs
```

### Step 3: Register the Assembly in SQL Server

```sql
-- Create the assembly from the DLL file
CREATE ASSEMBLY StringUtilities
FROM 'C:\Assemblies\StringUtilities.dll'
WITH PERMISSION_SET = SAFE;

-- Alternatively, from binary (no file path dependency)
CREATE ASSEMBLY StringUtilities
FROM 0x4D5A900003000000...  -- hex representation of the DLL
WITH PERMISSION_SET = SAFE;
```

### Step 4: Create the SQL Server Objects

```sql
CREATE FUNCTION dbo.fn_RegexMatch
(
    @input NVARCHAR(MAX),
    @pattern NVARCHAR(MAX)
)
RETURNS BIT
AS EXTERNAL NAME StringUtilities.StringUtilities.RegexMatch;
GO

CREATE FUNCTION dbo.fn_RegexReplace
(
    @input NVARCHAR(MAX),
    @pattern NVARCHAR(MAX),
    @replacement NVARCHAR(MAX)
)
RETURNS NVARCHAR(MAX)
AS EXTERNAL NAME StringUtilities.StringUtilities.RegexReplace;
GO

-- Usage
SELECT dbo.fn_RegexMatch(Email, '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z]{2,}$') AS IsValidEmail
FROM dbo.Customers;
```

The `EXTERNAL NAME` syntax follows the pattern: `AssemblyName.ClassName.MethodName`.

---

## CLR Stored Procedures

CLR stored procedures can return result sets, use output parameters, and access data through the in-process ADO.NET provider.

```csharp
using System;
using System.Data;
using System.Data.SqlClient;
using System.Data.SqlTypes;
using Microsoft.SqlServer.Server;

public class DataProcedures
{
    [SqlProcedure]
    public static void GetFilteredResults(SqlString tableName, SqlString filterColumn, SqlString filterPattern)
    {
        using (SqlConnection conn = new SqlConnection("context connection=true"))
        {
            conn.Open();

            // Use parameterized query for the filter value
            // Note: Table/column names still need validation
            string sql = string.Format(
                "SELECT * FROM [{0}] WHERE [{1}] LIKE @pattern",
                tableName.Value.Replace("]", "]]"),
                filterColumn.Value.Replace("]", "]]"));

            using (SqlCommand cmd = new SqlCommand(sql, conn))
            {
                cmd.Parameters.AddWithValue("@pattern", filterPattern.Value);

                using (SqlDataReader reader = cmd.ExecuteReader())
                {
                    // Pipe results directly back to the client
                    SqlContext.Pipe.Send(reader);
                }
            }
        }
    }
}
```

```sql
CREATE PROCEDURE dbo.usp_GetFilteredResults
    @tableName NVARCHAR(128),
    @filterColumn NVARCHAR(128),
    @filterPattern NVARCHAR(256)
AS EXTERNAL NAME StringUtilities.DataProcedures.GetFilteredResults;
GO
```

### The Context Connection

The `"context connection=true"` connection string is special in CLR integration. It uses the same connection, transaction, and security context as the calling T-SQL session. It avoids the overhead of establishing a new connection and participates in the current transaction automatically.

---

## CLR Functions

### CLR Scalar Functions

Shown above in the regex examples. Key attributes:

```csharp
[SqlFunction(
    IsDeterministic = true,      // Same input always returns same output
    IsPrecise = true,            // Does not involve floating-point operations
    DataAccess = DataAccessKind.None,   // Does not read SQL data
    SystemDataAccess = SystemDataAccessKind.None  // Does not access system catalogs
)]
```

### CLR Table-Valued Functions

Return rows to the caller. Require a `FillRow` method to map .NET objects to SQL columns.

```csharp
using System;
using System.Collections;
using System.Data.SqlTypes;
using Microsoft.SqlServer.Server;

public class SplitFunctions
{
    [SqlFunction(
        FillRowMethodName = "FillSplitRow",
        TableDefinition = "Item NVARCHAR(MAX), ItemIndex INT",
        IsDeterministic = true)]
    public static IEnumerable SplitString(SqlString input, SqlString delimiter)
    {
        if (input.IsNull || delimiter.IsNull)
            yield break;

        string[] parts = input.Value.Split(new string[] { delimiter.Value },
                                            StringSplitOptions.None);
        for (int i = 0; i < parts.Length; i++)
        {
            yield return new SplitResult(parts[i], i);
        }
    }

    public static void FillSplitRow(object obj, out SqlString item, out SqlInt32 itemIndex)
    {
        SplitResult result = (SplitResult)obj;
        item = new SqlString(result.Item);
        itemIndex = new SqlInt32(result.Index);
    }

    private class SplitResult
    {
        public string Item;
        public int Index;
        public SplitResult(string item, int index)
        {
            Item = item;
            Index = index;
        }
    }
}
```

```sql
CREATE FUNCTION dbo.fn_SplitString
(
    @input NVARCHAR(MAX),
    @delimiter NVARCHAR(10)
)
RETURNS TABLE (Item NVARCHAR(MAX), ItemIndex INT)
AS EXTERNAL NAME StringUtilities.SplitFunctions.SplitString;
GO

-- Usage
SELECT Item, ItemIndex
FROM dbo.fn_SplitString('apple,banana,cherry', ',');
```

**Note:** In SQL Server 2016+, the built-in `STRING_SPLIT()` function handles simple delimiter splitting, reducing the need for CLR in this specific case.

---

## CLR Aggregates

Custom aggregate functions that work with `GROUP BY`, not possible in pure T-SQL.

```csharp
using System;
using System.Data.SqlTypes;
using System.IO;
using System.Text;
using Microsoft.SqlServer.Server;

[Serializable]
[SqlUserDefinedAggregate(
    Format.UserDefined,
    IsInvariantToNulls = true,
    IsInvariantToDuplicates = false,
    IsInvariantToOrder = false,
    MaxByteSize = -1)]  // -1 means up to 2GB
public class StringAgg : IBinarySerialize
{
    private StringBuilder _accumulator;
    private string _delimiter;

    public void Init()
    {
        _accumulator = new StringBuilder();
        _delimiter = ",";
    }

    public void Accumulate(SqlString value, SqlString delimiter)
    {
        if (!value.IsNull)
        {
            if (_accumulator.Length > 0)
                _accumulator.Append(delimiter.IsNull ? "," : delimiter.Value);
            _accumulator.Append(value.Value);
        }
    }

    public void Merge(StringAgg other)
    {
        if (other._accumulator.Length > 0)
        {
            if (_accumulator.Length > 0)
                _accumulator.Append(_delimiter);
            _accumulator.Append(other._accumulator);
        }
    }

    public SqlString Terminate()
    {
        return new SqlString(_accumulator.ToString());
    }

    public void Read(BinaryReader reader)
    {
        _delimiter = reader.ReadString();
        _accumulator = new StringBuilder(reader.ReadString());
    }

    public void Write(BinaryWriter writer)
    {
        writer.Write(_delimiter);
        writer.Write(_accumulator.ToString());
    }
}
```

```sql
CREATE AGGREGATE dbo.StringAgg
(
    @value NVARCHAR(MAX),
    @delimiter NVARCHAR(10)
)
RETURNS NVARCHAR(MAX)
EXTERNAL NAME StringUtilities.StringAgg;
GO

-- Usage
SELECT
    DepartmentName,
    dbo.StringAgg(EmployeeName, ', ') AS Employees
FROM dbo.Employees e
INNER JOIN dbo.Departments d ON e.DepartmentID = d.DepartmentID
GROUP BY DepartmentName;
```

**Note:** SQL Server 2017+ includes the built-in `STRING_AGG()` function, which makes this particular CLR aggregate unnecessary for new development.

---

## CLR User-Defined Types

Custom data types defined in .NET. Used rarely, but useful for specialized domains (geometry, complex numbers, etc.).

```csharp
[Serializable]
[SqlUserDefinedType(Format.Native, IsByteOrdered = true)]
public struct EmailAddress : INullable
{
    private bool _isNull;
    private string _value;

    public bool IsNull { get { return _isNull; } }

    public static EmailAddress Null
    {
        get { var e = new EmailAddress(); e._isNull = true; return e; }
    }

    public static EmailAddress Parse(SqlString s)
    {
        if (s.IsNull)
            return Null;

        // Validate email format
        var email = new EmailAddress();
        email._value = s.Value;
        email._isNull = false;
        return email;
    }

    public override string ToString()
    {
        return _isNull ? "NULL" : _value;
    }
}
```

UDTs are the least commonly used CLR feature due to complexity and portability concerns.

---

## Permission Sets: SAFE, EXTERNAL_ACCESS, UNSAFE

Permission sets control what operations a CLR assembly is allowed to perform.

### SAFE

The most restrictive level. The assembly can only perform computation and access data through the context connection.

| Allowed | Not Allowed |
|---------|-------------|
| Computation and math | File system access |
| String operations | Network access |
| Context connection to SQL Server | Registry access |
| Managed data types | Threading |
| | Reflection |
| | Unmanaged code |

```sql
CREATE ASSEMBLY MyAssembly FROM '...' WITH PERMISSION_SET = SAFE;
```

### EXTERNAL_ACCESS

Allows the assembly to access external resources such as files, network, environment variables, and the registry.

```sql
-- Database must be marked as trustworthy, or assembly must be signed
ALTER DATABASE MyDB SET TRUSTWORTHY ON;  -- Not recommended for production

CREATE ASSEMBLY MyAssembly FROM '...' WITH PERMISSION_SET = EXTERNAL_ACCESS;
```

### UNSAFE

No restrictions. The assembly can call unmanaged code, perform unrestricted threading, and do anything .NET allows. This is essentially running arbitrary code inside SQL Server.

```sql
CREATE ASSEMBLY MyAssembly FROM '...' WITH PERMISSION_SET = UNSAFE;
```

### Permission Set Comparison

| Capability | SAFE | EXTERNAL_ACCESS | UNSAFE |
|-----------|------|-----------------|--------|
| Internal computation | Yes | Yes | Yes |
| Context connection | Yes | Yes | Yes |
| External connections | No | Yes | Yes |
| File I/O | No | Yes | Yes |
| Network access | No | Yes | Yes |
| Unmanaged code (P/Invoke) | No | No | Yes |
| Custom threading | No | No | Yes |
| Static shared state | Limited | Limited | Yes |

**Rule of thumb:** Always use SAFE unless you have a specific need for higher permissions. UNSAFE should be an absolute last resort with thorough security review.

---

## CLR in SQL Server 2017+ (Strict Security)

SQL Server 2017 introduced **CLR strict security**, which is enabled by default and fundamentally changes how CLR assemblies are trusted.

### What Changed

Before 2017: A `SAFE` assembly could be loaded without any additional trust requirements.

2017+: **All assemblies** (even SAFE) are treated as UNSAFE for trust purposes. You must explicitly establish trust before loading any assembly.

### Options to Establish Trust

**Option 1: Sign the assembly and create a certificate/asymmetric key login (Recommended)**

```sql
-- 1. Create a certificate from the signed assembly
CREATE CERTIFICATE CLRCert
FROM EXECUTABLE FILE = 'C:\Assemblies\StringUtilities.dll';

-- 2. Create a login from the certificate
CREATE LOGIN CLRLogin FROM CERTIFICATE CLRCert;

-- 3. Grant UNSAFE ASSEMBLY permission to the login
GRANT UNSAFE ASSEMBLY TO CLRLogin;

-- 4. Now you can create the assembly
CREATE ASSEMBLY StringUtilities
FROM 'C:\Assemblies\StringUtilities.dll'
WITH PERMISSION_SET = SAFE;
```

**Option 2: Use the trusted assemblies list (hash-based)**

```sql
-- Get the hash of the assembly
DECLARE @hash VARBINARY(64);
SELECT @hash = HASHBYTES('SHA2_512', BulkColumn)
FROM OPENROWSET(BULK 'C:\Assemblies\StringUtilities.dll', SINGLE_BLOB) AS A;

-- Add to trusted assemblies
EXEC sp_add_trusted_assembly @hash,
    N'StringUtilities, version=1.0.0.0';
```

**Option 3: Disable strict security (not recommended)**

```sql
EXEC sp_configure 'clr strict security', 0;
RECONFIGURE;
```

---

## CLR vs T-SQL Performance Comparison

### When CLR is Faster Than T-SQL

| Scenario | Why CLR Wins |
|----------|-------------|
| Regular expressions | No native regex in T-SQL; LIKE/PATINDEX are limited |
| Complex string parsing | T-SQL string functions are cumbersome and slow for complex parsing |
| Mathematical computations | .NET math libraries are optimized and compiled |
| Custom aggregations | CLR avoids the cursor-like workarounds needed in T-SQL |
| Iterative algorithms | .NET loops are compiled; T-SQL WHILE loops are interpreted |
| Binary data manipulation | .NET has rich byte-level manipulation |

### When T-SQL is Faster Than CLR

| Scenario | Why T-SQL Wins |
|----------|---------------|
| Set-based data operations | The SQL Engine optimizer handles set operations far better |
| Simple data retrieval | No CLR marshaling overhead |
| Joins and aggregations | The query optimizer produces efficient execution plans |
| Bulk data modifications | INSERT/UPDATE/DELETE on large datasets |

### The Marshaling Overhead

Every call from T-SQL to CLR incurs a marshaling cost (converting SQL types to .NET types and back). For simple operations called millions of times (e.g., a scalar function on every row), this overhead can negate any benefit. CLR shines when the computation per call is substantial enough to dwarf the marshaling cost.

---

## Use Cases

### Real-World CLR Use Cases

1. **Email/URL validation with regex**
   - T-SQL LIKE patterns are insufficient for proper validation
   - CLR regex provides full Perl-compatible pattern matching

2. **String aggregation (pre-2017)**
   - Before `STRING_AGG()`, CLR was the best-performing option
   - FOR XML PATH trick was the T-SQL alternative but had encoding issues

3. **File system operations**
   - Reading configuration files
   - Writing export files
   - Monitoring directories (EXTERNAL_ACCESS required)

4. **Web service calls**
   - Calling REST APIs from within SQL Server
   - Sending HTTP requests (EXTERNAL_ACCESS required)
   - Note: Generally better handled at the application tier

5. **Custom compression/hashing**
   - Algorithms not available in T-SQL natively
   - Specialized encoding/decoding

6. **Complex mathematical models**
   - Statistical calculations
   - Financial computations (loan amortization, pricing models)
   - Scientific formulas

### When NOT to Use CLR

- Simple CRUD operations
- Set-based data transformations
- Anything that can be done efficiently with built-in T-SQL functions
- When you lack the expertise to maintain .NET code alongside T-SQL
- When deployment complexity is a concern (assembly versioning, trust management)

---

## Security Considerations

| Concern | Recommendation |
|---------|---------------|
| TRUSTWORTHY database setting | Avoid setting `TRUSTWORTHY ON`; use assembly signing instead |
| Permission set escalation | Always start with SAFE; justify any escalation |
| Code review | CLR code runs inside SQL Server process; malicious code can crash the instance |
| Assembly signing | Sign all production assemblies with a strong name and certificate |
| Static variables | SAFE assemblies can use static variables but they are shared across sessions -- a potential data leak |
| Memory consumption | CLR code allocates from SQL Server's memory; uncontrolled allocations can cause memory pressure |
| Thread safety | SQL Server manages threads; CLR code should not create its own threads (except UNSAFE) |

---

## Deployment and Management

### Viewing Registered Assemblies

```sql
-- List all CLR assemblies
SELECT
    a.name AS AssemblyName,
    a.permission_set_desc,
    a.clr_name,
    a.create_date,
    af.name AS FileName
FROM sys.assemblies a
LEFT JOIN sys.assembly_files af ON a.assembly_id = af.assembly_id
WHERE a.is_user_defined = 1;
```

### Updating an Assembly

```sql
ALTER ASSEMBLY StringUtilities
FROM 'C:\Assemblies\StringUtilities_v2.dll';
```

### Dropping CLR Objects

You must drop the T-SQL wrapper objects before dropping the assembly.

```sql
-- Drop the functions first
DROP FUNCTION IF EXISTS dbo.fn_RegexMatch;
DROP FUNCTION IF EXISTS dbo.fn_RegexReplace;

-- Then drop the assembly
DROP ASSEMBLY IF EXISTS StringUtilities;
```

### Troubleshooting

```sql
-- Check CLR configuration
SELECT * FROM sys.configurations WHERE name LIKE '%clr%';

-- View assembly load errors
SELECT * FROM sys.dm_clr_loaded_assemblies;

-- Monitor CLR memory usage
SELECT * FROM sys.dm_clr_properties;

-- View CLR tasks
SELECT * FROM sys.dm_clr_tasks;

-- Check AppDomain status
SELECT * FROM sys.dm_clr_appdomains;
```

---

## Common Interview Questions

### Q1: What is CLR integration and why would you use it?

**A:** CLR integration allows you to create SQL Server database objects (procedures, functions, aggregates, types, triggers) in .NET languages like C#. You would use it when T-SQL is insufficient or inefficient for certain operations -- primarily complex string manipulation (regex), custom aggregations, mathematical computations, or accessing external resources. CLR code runs inside the SQL Server process in a hosted CLR runtime with configurable security restrictions.

### Q2: What are the three permission sets and when would you use each?

**A:** **SAFE** is the default and most restrictive -- allows only computation and data access through the context connection. Use it for regex, string manipulation, and math. **EXTERNAL_ACCESS** additionally allows file system, network, and registry access. Use it when you need to read files or call external services. **UNSAFE** has no restrictions and allows unmanaged code and custom threading. Use it only as a last resort when no other option works, such as calling native C/C++ libraries via P/Invoke.

### Q3: What changed with CLR security in SQL Server 2017?

**A:** SQL Server 2017 introduced `clr strict security`, enabled by default. All assemblies, even those marked SAFE, must be trusted before loading. This is done by signing the assembly with a certificate or asymmetric key, creating a login from that certificate, and granting `UNSAFE ASSEMBLY` permission to that login. The legacy `TRUSTWORTHY` database setting still works but is not recommended. This change was made to prevent untrusted code from running inside the SQL Server process.

### Q4: What is the context connection?

**A:** The context connection (`"context connection=true"`) is a special ADO.NET connection string that reuses the calling session's connection. It runs under the same transaction, security context, and default database as the T-SQL code that invoked the CLR object. It avoids establishing a new connection (no network round trip, no authentication) and is the only connection type available in SAFE assemblies.

### Q5: When should you use CLR instead of T-SQL?

**A:** Use CLR for: (1) regex pattern matching, (2) complex string parsing and manipulation, (3) computationally intensive math or algorithms, (4) custom aggregates that cannot be expressed in T-SQL, and (5) accessing external resources (files, web services). Do not use CLR for set-based data operations, simple CRUD, joins, or standard aggregations -- T-SQL handles these far more efficiently.

### Q6: How does CLR affect SQL Server memory and performance?

**A:** CLR code runs in-process and allocates memory from SQL Server's memory space. Uncontrolled allocations in CLR code can cause memory pressure on the buffer pool. Each database gets its own AppDomain, and assemblies are loaded into memory. There is a marshaling overhead for each T-SQL-to-CLR call (type conversion), so CLR should not be used for trivially simple per-row computations. The benefit must outweigh the marshaling cost.

---

## Tips

- **Start with SAFE permission set** and only escalate if you have a documented, justified need for EXTERNAL_ACCESS or UNSAFE.
- **Use assembly signing** rather than `TRUSTWORTHY ON` to establish trust for CLR assemblies in SQL Server 2017+.
- **Prefer built-in functions** when available. SQL Server 2016+ added `STRING_SPLIT`, 2017+ added `STRING_AGG`, and 2022+ added many more that reduce the need for CLR.
- **Avoid CLR for set-based operations.** The SQL engine is always better at joins, aggregations, and filtering.
- **Keep CLR assemblies small and focused.** Large assemblies with many dependencies increase AppDomain load time and memory consumption.
- **Mark functions as `IsDeterministic = true`** when they are deterministic -- this allows the optimizer to cache results and enables use in indexed computed columns.
- **Use `DataAccess = DataAccessKind.None`** when your function does not access SQL data -- this avoids unnecessary overhead.
- **Test CLR code thoroughly outside SQL Server first** in standard .NET unit tests. Debugging CLR inside SQL Server is significantly harder.
- **Monitor CLR memory** using `sys.dm_clr_properties` and `sys.dm_clr_appdomains` to ensure assemblies are not consuming excessive memory.
- **Document CLR usage** carefully. Many DBAs and developers are unfamiliar with CLR, and it adds a .NET build/deploy step to your database release process.
