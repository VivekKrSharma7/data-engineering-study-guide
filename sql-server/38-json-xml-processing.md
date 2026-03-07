# JSON & XML Processing

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Introduction](#introduction)
2. [JSON Functions](#json-functions)
3. [OPENJSON](#openjson)
4. [FOR JSON](#for-json)
5. [XML Functions](#xml-functions)
6. [FOR XML](#for-xml)
7. [OPENXML](#openxml)
8. [XML Indexes](#xml-indexes)
9. [XQuery Basics](#xquery-basics)
10. [XML Schema Collections](#xml-schema-collections)
11. [Shredding JSON into Relational Tables](#shredding-json-into-relational-tables)
12. [Shredding XML into Relational Tables](#shredding-xml-into-relational-tables)
13. [JSON vs XML: Performance Comparison](#json-vs-xml-performance-comparison)
14. [When to Use Each Format](#when-to-use-each-format)
15. [Common Interview Questions](#common-interview-questions)
16. [Tips](#tips)

---

## Introduction

SQL Server provides native support for both JSON (since SQL Server 2016) and XML (since SQL Server 2005) data processing. While XML has been available much longer and has richer native support (dedicated data type, indexes, schema validation), JSON has become the dominant format for web APIs, NoSQL integration, and modern application development.

A senior Data Engineer must understand both formats deeply: how to parse incoming data, construct output, optimize queries, and choose the right format for each scenario.

---

## JSON Functions

SQL Server stores JSON as plain `NVARCHAR` text. There is no native JSON data type. All JSON functions operate on string columns or variables.

### JSON_VALUE

Extracts a **scalar value** from a JSON string.

```sql
DECLARE @json NVARCHAR(MAX) = N'{
    "employee": {
        "name": "John Smith",
        "age": 42,
        "active": true,
        "skills": ["SQL", "Python", "Azure"]
    }
}';

-- Extract scalar values
SELECT JSON_VALUE(@json, '$.employee.name') AS EmployeeName;
-- Result: John Smith

SELECT JSON_VALUE(@json, '$.employee.age') AS Age;
-- Result: 42

-- Access array elements by index
SELECT JSON_VALUE(@json, '$.employee.skills[0]') AS FirstSkill;
-- Result: SQL

-- Strict vs Lax mode (default is lax)
SELECT JSON_VALUE(@json, 'strict $.employee.salary'); -- Error: property not found
SELECT JSON_VALUE(@json, 'lax $.employee.salary');     -- Returns NULL
```

### JSON_QUERY

Extracts an **object or array** (non-scalar) from a JSON string.

```sql
-- Extract the entire employee object
SELECT JSON_QUERY(@json, '$.employee') AS EmployeeObj;
-- Result: {"name":"John Smith","age":42,"active":true,"skills":["SQL","Python","Azure"]}

-- Extract the skills array
SELECT JSON_QUERY(@json, '$.employee.skills') AS Skills;
-- Result: ["SQL","Python","Azure"]

-- JSON_VALUE vs JSON_QUERY:
-- JSON_VALUE returns scalar values (strings, numbers, booleans) as NVARCHAR(4000)
-- JSON_QUERY returns objects/arrays as NVARCHAR(MAX)
-- Using the wrong one returns NULL (in lax mode) or an error (in strict mode)
```

### JSON_MODIFY

Modifies a value in a JSON string and returns the updated JSON.

```sql
DECLARE @json NVARCHAR(MAX) = N'{"name":"John","age":42,"city":"Seattle"}';

-- Update an existing property
SET @json = JSON_MODIFY(@json, '$.city', 'Portland');
-- {"name":"John","age":42,"city":"Portland"}

-- Add a new property
SET @json = JSON_MODIFY(@json, '$.department', 'Engineering');
-- {"name":"John","age":42,"city":"Portland","department":"Engineering"}

-- Delete a property (set to NULL with strict)
SET @json = JSON_MODIFY(@json, '$.city', NULL);
-- {"name":"John","age":42,"city":null,"department":"Engineering"}

-- Append to an array
DECLARE @jsonArr NVARCHAR(MAX) = N'{"skills":["SQL","Python"]}';
SET @jsonArr = JSON_MODIFY(@jsonArr, 'append $.skills', 'Azure');
-- {"skills":["SQL","Python","Azure"]}

-- Insert a raw JSON object (use JSON_QUERY wrapper to avoid escaping)
SET @json = JSON_MODIFY(@json, '$.address',
    JSON_QUERY('{"street":"123 Main St","zip":"97201"}'));
```

### ISJSON

Validates whether a string contains valid JSON.

```sql
SELECT ISJSON('{"name":"John"}');          -- 1 (valid)
SELECT ISJSON('{"name":}');                -- 0 (invalid)
SELECT ISJSON('"hello"');                  -- 1 (valid JSON scalar)
SELECT ISJSON('hello');                    -- 0 (not valid JSON)
SELECT ISJSON(NULL);                       -- 0

-- SQL Server 2022+ extended: validate specific JSON types
SELECT ISJSON('{"a":1}', OBJECT);          -- 1
SELECT ISJSON('[1,2,3]', ARRAY);           -- 1
SELECT ISJSON('"hello"', SCALAR);          -- 1
SELECT ISJSON('[1,2]', OBJECT);            -- 0

-- Use as a CHECK constraint
ALTER TABLE dbo.Events
ADD CONSTRAINT CK_Events_ValidJSON CHECK (ISJSON(EventData) = 1);
```

---

## OPENJSON

`OPENJSON` is a table-valued function that parses JSON text and returns rows and columns.

### Default Schema (Key-Value Pairs)

```sql
DECLARE @json NVARCHAR(MAX) = N'{
    "name": "John Smith",
    "age": 42,
    "active": true,
    "skills": ["SQL", "Python"]
}';

SELECT * FROM OPENJSON(@json);
-- Returns:
-- key      | value                  | type
-- ---------|------------------------|------
-- name     | John Smith             | 1 (string)
-- age      | 42                     | 2 (number)
-- active   | true                   | 3 (boolean)
-- skills   | ["SQL","Python"]       | 4 (array)
```

### Explicit Schema (WITH Clause)

```sql
DECLARE @json NVARCHAR(MAX) = N'[
    {"id": 1, "name": "Alice", "salary": 95000.00, "hired": "2020-03-15"},
    {"id": 2, "name": "Bob",   "salary": 87500.00, "hired": "2021-06-01"},
    {"id": 3, "name": "Carol", "salary": 102000.00, "hired": "2019-11-20"}
]';

SELECT *
FROM OPENJSON(@json)
WITH (
    EmployeeID   INT            '$.id',
    EmployeeName NVARCHAR(100)  '$.name',
    Salary       DECIMAL(10,2)  '$.salary',
    HireDate     DATE           '$.hired'
);
-- Returns a properly typed result set
```

### Nested JSON

```sql
DECLARE @json NVARCHAR(MAX) = N'{
    "orders": [
        {
            "orderId": 101,
            "customer": "Contoso",
            "items": [
                {"product": "Widget A", "qty": 10, "price": 5.99},
                {"product": "Widget B", "qty": 5,  "price": 12.50}
            ]
        }
    ]
}';

-- Shred nested structure using CROSS APPLY
SELECT
    o.OrderId,
    o.Customer,
    i.Product,
    i.Qty,
    i.Price
FROM OPENJSON(@json, '$.orders')
WITH (
    OrderId  INT           '$.orderId',
    Customer NVARCHAR(100) '$.customer',
    Items    NVARCHAR(MAX) '$.items' AS JSON  -- AS JSON preserves the nested array
) o
CROSS APPLY OPENJSON(o.Items)
WITH (
    Product NVARCHAR(100) '$.product',
    Qty     INT           '$.qty',
    Price   DECIMAL(10,2) '$.price'
) i;
```

---

## FOR JSON

Converts query results into JSON format.

### FOR JSON PATH

Most flexible; uses column aliases as JSON paths.

```sql
-- Simple query
SELECT
    e.EmployeeID AS [id],
    e.FirstName  AS [name.first],
    e.LastName   AS [name.last],
    e.Email      AS [contact.email],
    d.DeptName   AS [department]
FROM dbo.Employees e
JOIN dbo.Departments d ON e.DeptID = d.DeptID
WHERE e.EmployeeID <= 2
FOR JSON PATH, ROOT('employees');

-- Result:
-- {
--   "employees": [
--     {"id":1,"name":{"first":"John","last":"Smith"},"contact":{"email":"john@co.com"},"department":"Engineering"},
--     {"id":2,"name":{"first":"Jane","last":"Doe"},"contact":{"email":"jane@co.com"},"department":"Marketing"}
--   ]
-- }
```

### FOR JSON AUTO

Generates nested JSON based on the table structure in the query.

```sql
SELECT
    d.DeptID,
    d.DeptName,
    e.EmployeeID,
    e.FirstName,
    e.LastName
FROM dbo.Departments d
JOIN dbo.Employees e ON d.DeptID = e.DeptID
FOR JSON AUTO;

-- Automatically nests employees under their department
```

### Key Options

```sql
-- Include NULL values (normally omitted)
SELECT Name, MiddleName FROM dbo.People
FOR JSON PATH, INCLUDE_NULL_VALUES;

-- Without array wrapper (single object)
SELECT TOP 1 Name, Age FROM dbo.People
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;

-- Root element
SELECT Name, Age FROM dbo.People
FOR JSON PATH, ROOT('people');
```

---

## XML Functions

SQL Server has a native `XML` data type with built-in methods.

### nodes()

Shreds XML into relational rows. Returns a rowset with one row per XML node matched.

```sql
DECLARE @xml XML = N'
<employees>
    <employee id="1"><name>Alice</name><salary>95000</salary></employee>
    <employee id="2"><name>Bob</name><salary>87500</salary></employee>
    <employee id="3"><name>Carol</name><salary>102000</salary></employee>
</employees>';

SELECT
    e.value('@id', 'INT') AS EmployeeID,
    e.value('name[1]', 'NVARCHAR(100)') AS EmployeeName,
    e.value('salary[1]', 'DECIMAL(10,2)') AS Salary
FROM @xml.nodes('/employees/employee') AS T(e);
```

### value()

Extracts a single scalar value from an XML instance.

```sql
DECLARE @xml XML = N'<order id="101"><total>1500.00</total></order>';

SELECT @xml.value('(/order/@id)[1]', 'INT') AS OrderID;
-- Result: 101

SELECT @xml.value('(/order/total)[1]', 'DECIMAL(10,2)') AS Total;
-- Result: 1500.00

-- IMPORTANT: The XQuery expression must be a singleton.
-- Use [1] to guarantee a single value.
```

### query()

Returns an XML fragment (subset of the XML document).

```sql
DECLARE @xml XML = N'
<catalog>
    <product category="electronics"><name>Laptop</name><price>999</price></product>
    <product category="books"><name>SQL Guide</name><price>49</price></product>
    <product category="electronics"><name>Monitor</name><price>399</price></product>
</catalog>';

-- Extract all electronics products
SELECT @xml.query('/catalog/product[@category="electronics"]');
-- Result:
-- <product category="electronics"><name>Laptop</name><price>999</price></product>
-- <product category="electronics"><name>Monitor</name><price>399</price></product>
```

### exist()

Returns 1 if the XQuery expression finds at least one node, 0 otherwise.

```sql
DECLARE @xml XML = N'<order><status>shipped</status></order>';

SELECT @xml.exist('/order[status="shipped"]');    -- 1
SELECT @xml.exist('/order[status="cancelled"]');  -- 0

-- Commonly used in WHERE clauses
SELECT *
FROM dbo.Orders
WHERE OrderXml.exist('/order[total > 1000]') = 1;
```

### modify()

Modifies XML data in place using XML DML (insert, delete, replace value of).

```sql
DECLARE @xml XML = N'<employee><name>John</name><age>42</age></employee>';

-- Replace a value
SET @xml.modify('replace value of (/employee/age/text())[1] with 43');

-- Insert a new element
SET @xml.modify('insert <department>Engineering</department> into /employee[1]');

-- Delete an element
SET @xml.modify('delete /employee/age');

SELECT @xml;
-- <employee><name>John</name><department>Engineering</department></employee>
```

---

## FOR XML

Converts query results to XML format.

### FOR XML RAW

Produces a flat XML with each row as a `<row>` element.

```sql
SELECT EmployeeID, FirstName, LastName
FROM dbo.Employees
FOR XML RAW;
-- <row EmployeeID="1" FirstName="John" LastName="Smith" />
-- <row EmployeeID="2" FirstName="Jane" LastName="Doe" />

-- Customize element name
SELECT EmployeeID, FirstName, LastName
FROM dbo.Employees
FOR XML RAW('employee'), ROOT('employees'), ELEMENTS;
-- <employees>
--   <employee><EmployeeID>1</EmployeeID><FirstName>John</FirstName>...</employee>
--   ...
-- </employees>
```

### FOR XML AUTO

Automatically creates nested XML based on table hierarchy.

```sql
SELECT
    d.DeptName,
    e.FirstName,
    e.LastName
FROM dbo.Departments d
JOIN dbo.Employees e ON d.DeptID = e.DeptID
FOR XML AUTO, ROOT('company');
-- <company>
--   <d DeptName="Engineering">
--     <e FirstName="John" LastName="Smith" />
--     <e FirstName="Jane" LastName="Doe" />
--   </d>
-- </company>
```

### FOR XML PATH

Most flexible; uses column aliases as XPath expressions.

```sql
SELECT
    EmployeeID AS '@id',
    FirstName  AS 'name/first',
    LastName   AS 'name/last',
    Email      AS 'contact/email'
FROM dbo.Employees
FOR XML PATH('employee'), ROOT('employees');
-- <employees>
--   <employee id="1">
--     <name>
--       <first>John</first>
--       <last>Smith</last>
--     </name>
--     <contact><email>john@co.com</email></contact>
--   </employee>
-- </employees>
```

### FOR XML EXPLICIT

The most complex mode; provides full control over XML structure using a special column naming convention with tag numbers and directives.

```sql
-- Level 1: Department, Level 2: Employee
SELECT
    1 AS Tag,
    NULL AS Parent,
    DeptID AS [department!1!id],
    DeptName AS [department!1!name],
    NULL AS [employee!2!name],
    NULL AS [employee!2!title]
FROM dbo.Departments
UNION ALL
SELECT
    2 AS Tag,
    1 AS Parent,
    e.DeptID,
    NULL,
    e.FirstName + ' ' + e.LastName,
    e.JobTitle
FROM dbo.Employees e
ORDER BY [department!1!id], Tag
FOR XML EXPLICIT;
```

> **Note**: FOR XML EXPLICIT is rarely used in modern SQL Server. FOR XML PATH can handle almost all scenarios more cleanly.

---

## OPENXML

`OPENXML` is an older approach (SQL Server 2000+) for shredding XML into relational rows. It requires `sp_xml_preparedocument` and `sp_xml_removedocument`.

```sql
DECLARE @xml NVARCHAR(MAX) = N'
<employees>
    <employee id="1" name="Alice" salary="95000" />
    <employee id="2" name="Bob" salary="87500" />
</employees>';

DECLARE @hDoc INT;
EXEC sp_xml_preparedocument @hDoc OUTPUT, @xml;

SELECT *
FROM OPENXML(@hDoc, '/employees/employee', 1)
WITH (
    EmployeeID INT '@id',
    Name NVARCHAR(100) '@name',
    Salary DECIMAL(10,2) '@salary'
);

EXEC sp_xml_removedocument @hDoc;
```

> **Important**: Always call `sp_xml_removedocument` to free memory. OPENXML loads the entire document into memory. For modern code, prefer the `.nodes()` method which is more efficient and does not require memory management.

---

## XML Indexes

XML indexes improve query performance on XML columns. They are only applicable to columns of the `XML` data type.

### Primary XML Index

Creates a shredded, persistent representation of the XML data as an internal B-tree.

```sql
-- Prerequisite: table must have a clustered primary key
CREATE PRIMARY XML INDEX PXI_Orders_OrderXml
ON dbo.Orders(OrderXml);
```

### Secondary XML Indexes

Built on top of the primary XML index to optimize specific query patterns.

| Type | Optimizes | Best For |
|------|-----------|----------|
| **PATH** | Path-based lookups | `value()`, `exist()` with specific paths |
| **VALUE** | Value-based searches | Wildcard searches by value |
| **PROPERTY** | Property retrieval | Extracting multiple values from known paths |

```sql
-- PATH secondary index
CREATE XML INDEX SXI_Orders_Path
ON dbo.Orders(OrderXml)
USING XML INDEX PXI_Orders_OrderXml
FOR PATH;

-- VALUE secondary index
CREATE XML INDEX SXI_Orders_Value
ON dbo.Orders(OrderXml)
USING XML INDEX PXI_Orders_OrderXml
FOR VALUE;

-- PROPERTY secondary index
CREATE XML INDEX SXI_Orders_Property
ON dbo.Orders(OrderXml)
USING XML INDEX PXI_Orders_OrderXml
FOR PROPERTY;
```

### Selective XML Index (SQL Server 2012+)

Indexes only specific paths, reducing storage and maintenance overhead.

```sql
CREATE SELECTIVE XML INDEX SXI_Orders_Selective
ON dbo.Orders(OrderXml)
FOR (
    pathOrderId   = '/order/@id'   AS XQUERY 'xs:integer' SINGLETON,
    pathTotal     = '/order/total' AS XQUERY 'xs:decimal' SINGLETON,
    pathStatus    = '/order/status' AS XQUERY 'xs:string' MAXLENGTH(50) SINGLETON
);
```

---

## XQuery Basics

XQuery is the query language used within SQL Server's XML methods. Key constructs include:

### FLWOR Expressions

```sql
DECLARE @xml XML = N'
<products>
    <product><name>Widget</name><price>9.99</price><qty>100</qty></product>
    <product><name>Gadget</name><price>24.99</price><qty>50</qty></product>
    <product><name>Doohickey</name><price>4.99</price><qty>200</qty></product>
</products>';

-- XQuery with FLWOR (For, Let, Where, Order by, Return)
SELECT @xml.query('
    for $p in /products/product
    where $p/price > 5.00
    order by $p/price descending
    return <item name="{$p/name/text()}" price="{$p/price/text()}" />
');
-- Result:
-- <item name="Gadget" price="24.99" /><item name="Widget" price="9.99" />
```

### Common XQuery Functions

```sql
-- count()
SELECT @xml.value('count(/products/product)', 'INT');  -- 3

-- sum()
SELECT @xml.value('sum(/products/product/price)', 'DECIMAL(10,2)');  -- 39.97

-- min() / max()
SELECT @xml.value('min(/products/product/price)', 'DECIMAL(10,2)');  -- 4.99

-- string operations
SELECT @xml.value('concat(/products/product[1]/name, " - $", /products/product[1]/price)', 'NVARCHAR(100)');

-- contains()
SELECT @xml.query('
    /products/product[contains(name, "get")]
');
```

---

## XML Schema Collections

XML schema collections enforce structure and data types on XML columns.

```sql
-- Create a schema collection
CREATE XML SCHEMA COLLECTION OrderSchema AS N'
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema">
    <xs:element name="order">
        <xs:complexType>
            <xs:sequence>
                <xs:element name="customer" type="xs:string" />
                <xs:element name="total" type="xs:decimal" />
                <xs:element name="status" type="xs:string" />
            </xs:sequence>
            <xs:attribute name="id" type="xs:integer" use="required" />
        </xs:complexType>
    </xs:element>
</xs:schema>';

-- Use typed XML column
CREATE TABLE dbo.OrdersXml (
    OrderID INT PRIMARY KEY,
    OrderData XML(OrderSchema)  -- typed XML
);

-- Valid insert
INSERT INTO dbo.OrdersXml VALUES (1,
    N'<order id="1"><customer>Contoso</customer><total>1500.00</total><status>shipped</status></order>');

-- Invalid insert (missing required attribute) - will throw an error
-- INSERT INTO dbo.OrdersXml VALUES (2,
--     N'<order><customer>Fabrikam</customer><total>500</total><status>pending</status></order>');
```

### Typed vs Untyped XML

| Feature | Typed XML | Untyped XML |
|---------|-----------|-------------|
| Schema validation | Yes | No |
| Data type enforcement | Yes (xs:integer, xs:decimal, etc.) | Everything is text |
| Query optimization | Better (optimizer knows data types) | Limited |
| Flexibility | Lower (schema changes require DDL) | Higher |
| Storage efficiency | Slightly better | Slightly worse |

---

## Shredding JSON into Relational Tables

A common ETL pattern: receive JSON from an API and load it into relational tables.

```sql
-- Incoming JSON payload
DECLARE @json NVARCHAR(MAX) = N'{
    "orders": [
        {
            "orderId": 1001,
            "orderDate": "2026-01-15",
            "customer": {"id": 50, "name": "Contoso Ltd"},
            "items": [
                {"sku": "A100", "qty": 10, "unitPrice": 25.00},
                {"sku": "B200", "qty": 5,  "unitPrice": 42.50}
            ]
        },
        {
            "orderId": 1002,
            "orderDate": "2026-01-16",
            "customer": {"id": 75, "name": "Fabrikam Inc"},
            "items": [
                {"sku": "C300", "qty": 20, "unitPrice": 8.99}
            ]
        }
    ]
}';

-- Shred into Orders table
INSERT INTO dbo.Orders (OrderID, OrderDate, CustomerID, CustomerName)
SELECT
    o.OrderId,
    o.OrderDate,
    o.CustomerId,
    o.CustomerName
FROM OPENJSON(@json, '$.orders')
WITH (
    OrderId      INT            '$.orderId',
    OrderDate    DATE           '$.orderDate',
    CustomerId   INT            '$.customer.id',
    CustomerName NVARCHAR(200)  '$.customer.name'
) o;

-- Shred into OrderItems table
INSERT INTO dbo.OrderItems (OrderID, SKU, Quantity, UnitPrice)
SELECT
    o.OrderId,
    i.SKU,
    i.Qty,
    i.UnitPrice
FROM OPENJSON(@json, '$.orders')
WITH (
    OrderId INT            '$.orderId',
    Items   NVARCHAR(MAX)  '$.items' AS JSON
) o
CROSS APPLY OPENJSON(o.Items)
WITH (
    SKU       NVARCHAR(50)   '$.sku',
    Qty       INT            '$.qty',
    UnitPrice DECIMAL(10,2)  '$.unitPrice'
) i;
```

---

## Shredding XML into Relational Tables

```sql
DECLARE @xml XML = N'
<orders>
    <order id="1001" date="2026-01-15">
        <customer id="50">Contoso Ltd</customer>
        <items>
            <item sku="A100" qty="10" unitPrice="25.00" />
            <item sku="B200" qty="5"  unitPrice="42.50" />
        </items>
    </order>
    <order id="1002" date="2026-01-16">
        <customer id="75">Fabrikam Inc</customer>
        <items>
            <item sku="C300" qty="20" unitPrice="8.99" />
        </items>
    </order>
</orders>';

-- Shred into Orders
INSERT INTO dbo.Orders (OrderID, OrderDate, CustomerID, CustomerName)
SELECT
    o.value('@id', 'INT') AS OrderID,
    o.value('@date', 'DATE') AS OrderDate,
    o.value('customer[1]/@id', 'INT') AS CustomerID,
    o.value('customer[1]', 'NVARCHAR(200)') AS CustomerName
FROM @xml.nodes('/orders/order') AS T(o);

-- Shred into OrderItems (nested)
INSERT INTO dbo.OrderItems (OrderID, SKU, Quantity, UnitPrice)
SELECT
    o.value('../@id', 'INT') AS OrderID,
    o.value('@sku', 'NVARCHAR(50)') AS SKU,
    o.value('@qty', 'INT') AS Quantity,
    o.value('@unitPrice', 'DECIMAL(10,2)') AS UnitPrice
FROM @xml.nodes('/orders/order/items/item') AS T(o);
```

---

## JSON vs XML: Performance Comparison

### Storage and Parsing

| Aspect | JSON | XML |
|--------|------|-----|
| Storage type | `NVARCHAR` (plain text) | Native `XML` data type (optimized internal format) |
| Parsing | Re-parsed on every access | Parsed once on storage |
| Indexing | No native JSON indexes; use computed columns + standard indexes | Primary, secondary, and selective XML indexes |
| Validation | `ISJSON()` check constraint | XML Schema Collections |
| Compression | Standard page/row compression | Stored in optimized binary format |

### Query Performance

```sql
-- JSON: extracting a value requires string parsing every time
SELECT JSON_VALUE(JsonData, '$.customer.name')
FROM dbo.EventsJson
WHERE JSON_VALUE(JsonData, '$.eventType') = 'purchase';
-- Workaround: add a computed column with an index
ALTER TABLE dbo.EventsJson
ADD EventType AS JSON_VALUE(JsonData, '$.eventType');
CREATE INDEX IX_EventType ON dbo.EventsJson(EventType);

-- XML: can use XML indexes for direct path lookups
SELECT XmlData.value('(/event/customer/name)[1]', 'NVARCHAR(200)')
FROM dbo.EventsXml
WHERE XmlData.exist('/event[@eventType="purchase"]') = 1;
-- With a PATH secondary XML index, this is highly optimized
```

### Benchmark Guidelines

| Operation | JSON | XML |
|-----------|------|-----|
| Simple value extraction | Faster (lightweight parsing) | Slightly slower (richer type system) |
| Complex querying | Limited (no XQuery equivalent) | Powerful (full XQuery/FLWOR) |
| Large document indexing | Requires computed columns | Native XML indexes |
| Construction from relational data | FOR JSON (faster) | FOR XML (slower but more features) |
| Document modification | JSON_MODIFY (limited) | XML modify() (full DML) |
| Schema enforcement | CHECK constraint only | XML Schema Collections |

---

## When to Use Each Format

### Use JSON When

- Integrating with web APIs and modern applications.
- Data is semi-structured and the schema evolves frequently.
- Lightweight storage and fast serialization/deserialization are priorities.
- You need simple key-value or array structures.
- The consuming application is JavaScript/Python-based.

### Use XML When

- You need schema validation and enforcement (XML Schema Collections).
- Complex hierarchical querying is required (XQuery/FLWOR).
- You need native indexing on the document content.
- Integrating with legacy enterprise systems (SOAP, BizTalk, SSIS).
- The document has mixed content (text interleaved with elements).
- You need in-place modification of nested structures.

### Use Neither (Normalize Instead) When

- The data has a fixed, well-known structure.
- You need referential integrity, foreign keys, or strong typing.
- The data is frequently queried with complex joins.
- Performance is critical and data volume is large.

---

## Common Interview Questions

### Q1: What are the key differences between JSON_VALUE and JSON_QUERY?

**A**: `JSON_VALUE` extracts a scalar value (string, number, boolean, null) and returns it as `NVARCHAR(4000)`. `JSON_QUERY` extracts a JSON object or array and returns it as `NVARCHAR(MAX)`. If you use `JSON_VALUE` on an object/array, it returns NULL (lax mode) or an error (strict mode). Conversely, using `JSON_QUERY` on a scalar returns NULL or an error. This distinction is critical when building nested JSON output or extracting specific parts of a document.

### Q2: How would you optimize queries against a JSON column?

**A**: Since SQL Server has no native JSON indexes, the primary strategy is to create **computed columns** on frequently queried JSON paths and then index those computed columns. For example: `ALTER TABLE T ADD Col AS JSON_VALUE(JsonData, '$.path')` followed by `CREATE INDEX IX ON T(Col)`. Additionally, you can use full-text indexing for text search within JSON, or extract hot data into regular columns at insert time. In SQL Server 2022+, you can also leverage `JSON_VALUE` with `PERSISTED` computed columns.

### Q3: Explain the different types of XML indexes and when you would use each.

**A**: The **primary XML index** creates a shredded B-tree representation of all XML nodes and is required before creating secondary indexes. **PATH** secondary indexes optimize queries that navigate specific paths (`value()`, `exist()` with known XPath). **VALUE** secondary indexes optimize wildcard value searches across any path. **PROPERTY** secondary indexes optimize queries that retrieve multiple properties from known nodes. **Selective XML indexes** (SQL 2012+) index only specified paths, reducing storage. Choose based on your predominant query pattern.

### Q4: How do you shred a nested JSON array into relational rows?

**A**: Use `OPENJSON` with `CROSS APPLY` for nested arrays. The outer `OPENJSON` extracts the parent-level fields and preserves the nested array using `AS JSON`. Then `CROSS APPLY OPENJSON` on the nested array with its own `WITH` clause to extract child-level fields. This is the most efficient pattern for multi-level JSON shredding.

### Q5: What is the difference between FOR XML PATH and FOR XML AUTO?

**A**: `FOR XML AUTO` automatically determines the XML nesting structure based on the FROM clause table order and creates elements/attributes automatically. `FOR XML PATH` gives full control over the output structure; column aliases define the XPath expression for each value (e.g., `'@id'` for an attribute, `'name/first'` for a nested element). PATH is preferred for most scenarios because of its flexibility and readability.

### Q6: How do you handle JSON data in SQL Server when there is no native JSON data type?

**A**: JSON is stored in `NVARCHAR(MAX)` columns. To ensure data integrity, add a CHECK constraint with `ISJSON()`. For query performance, create persisted computed columns on frequently accessed paths and index them. Use `OPENJSON` for set-based shredding and `FOR JSON` for construction. Consider extracting frequently queried values into dedicated relational columns during ETL for optimal performance.

### Q7: Compare OPENXML with the nodes() method for XML shredding.

**A**: `OPENXML` is the older approach (SQL 2000+) requiring `sp_xml_preparedocument` to load the document into memory and `sp_xml_removedocument` to free it. It is procedural and can cause memory leaks if not properly cleaned up. The `nodes()` method (SQL 2005+) is declarative, integrates naturally with SELECT queries, and does not require explicit memory management. `nodes()` is preferred for all new development. OPENXML may still be found in legacy code.

### Q8: Can you modify a specific value inside a JSON document stored in a column?

**A**: Yes, using `JSON_MODIFY()`. It takes the original JSON string, a path, and a new value, and returns the modified JSON. You can update existing properties, add new ones, delete properties (set to NULL), and append to arrays. However, unlike XML's `modify()` which works in-place, `JSON_MODIFY` returns a new string, so you must use it in an UPDATE statement: `UPDATE T SET JsonCol = JSON_MODIFY(JsonCol, '$.path', newValue)`.

---

## Tips

- **Always validate JSON on input** using `ISJSON()` in a CHECK constraint. Debugging malformed JSON in a large table is painful.
- **Use `AS JSON`** in OPENJSON WITH clauses to preserve nested objects/arrays for further processing with CROSS APPLY.
- **Prefer `strict` mode** in production JSON path expressions. Lax mode silently returns NULL for invalid paths, hiding bugs.
- **Index computed columns for JSON** queries. Without indexes, every JSON query does a full table scan with string parsing on every row.
- **For XML, always pair `sp_xml_preparedocument` with `sp_xml_removedocument`** in a TRY/CATCH block. Better yet, use `nodes()` instead.
- **Selective XML indexes** can save enormous storage compared to full primary XML indexes when you only query specific paths.
- **Do not store large JSON/XML documents** in heavily queried OLTP tables. Consider extracting hot fields into relational columns and keeping the full document for audit/archival.
- **For bulk JSON loading** (e.g., from files), use `OPENROWSET(BULK ...)` combined with `OPENJSON` for efficient file-to-table loading.
- **JSON_MODIFY with nested paths** can be tricky. For complex modifications, consider shredding to relational form, modifying, and reconstructing with FOR JSON.
- **In SQL Server 2022+**, the new `JSON_ARRAY()` and `JSON_OBJECT()` functions simplify JSON construction from scalar values.