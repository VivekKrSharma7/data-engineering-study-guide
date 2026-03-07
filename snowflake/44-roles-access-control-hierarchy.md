# Snowflake Roles & Access Control Hierarchy

[Back to Snowflake Index](./README.md)

---

## 1. Overview

Snowflake uses a **Role-Based Access Control (RBAC)** model combined with **Discretionary Access Control (DAC)**. Every action in Snowflake is authorized through privileges granted to roles, and roles are granted to users or other roles, forming a hierarchy. Understanding this hierarchy is essential for designing secure, maintainable access control in production environments.

---

## 2. System-Defined Roles Hierarchy

Snowflake provides six built-in system roles, arranged in a hierarchy where higher roles inherit the privileges of lower ones:

```
ORGADMIN
    │
ACCOUNTADMIN
    ├── SECURITYADMIN
    │       └── USERADMIN
    └── SYSADMIN
            └── (custom roles should be granted here)
                    └── PUBLIC
```

### 2.1 Role Descriptions

| Role | Purpose | Key Privileges |
|------|---------|---------------|
| **ORGADMIN** | Organization-level management | Manage accounts within the organization, view organization usage, enable replication |
| **ACCOUNTADMIN** | Top-level account role; combines SECURITYADMIN + SYSADMIN | Full control over the account. Should be used sparingly and with MFA |
| **SECURITYADMIN** | Manages grants and roles | MANAGE GRANTS globally, can manage any grant in the account. Parent of USERADMIN |
| **USERADMIN** | Manages users and roles | CREATE USER, CREATE ROLE. Can create users and roles but cannot grant privileges on objects |
| **SYSADMIN** | Manages all database objects | CREATE DATABASE, CREATE WAREHOUSE. All custom roles should roll up to SYSADMIN |
| **PUBLIC** | Default role granted to every user | Minimal privileges. Every role inherits PUBLIC's privileges |

### 2.2 Why Custom Roles Should Roll Up to SYSADMIN

If custom roles are not granted to SYSADMIN (directly or through a chain), then ACCOUNTADMIN cannot manage the objects owned by those roles through SYSADMIN. This creates orphaned privilege chains and operational difficulties.

```sql
-- CORRECT: Custom role rolls up to SYSADMIN
CREATE ROLE data_engineer_role;
GRANT ROLE data_engineer_role TO ROLE sysadmin;

-- INCORRECT: Orphaned role (no parent besides ACCOUNTADMIN by default)
CREATE ROLE rogue_role;
-- This role's objects are only accessible via ACCOUNTADMIN directly
```

---

## 3. Privilege Inheritance

Privileges flow **upward** through the role hierarchy. If Role A is granted to Role B, then Role B inherits all of Role A's privileges.

```
SYSADMIN
   ├── ANALYTICS_ADMIN
   │       ├── ANALYST_ROLE
   │       └── REPORT_ROLE
   └── DATA_ENGINEERING_ADMIN
           ├── ETL_ROLE
           └── STAGING_ROLE
```

In this example:
- `SYSADMIN` inherits all privileges from every role below it.
- `ANALYTICS_ADMIN` inherits from `ANALYST_ROLE` and `REPORT_ROLE`.
- `ANALYST_ROLE` does not inherit from `REPORT_ROLE` (they are siblings).

```sql
-- Build the hierarchy
CREATE ROLE analytics_admin;
CREATE ROLE analyst_role;
CREATE ROLE report_role;
CREATE ROLE data_engineering_admin;
CREATE ROLE etl_role;
CREATE ROLE staging_role;

GRANT ROLE analyst_role TO ROLE analytics_admin;
GRANT ROLE report_role TO ROLE analytics_admin;
GRANT ROLE etl_role TO ROLE data_engineering_admin;
GRANT ROLE staging_role TO ROLE data_engineering_admin;
GRANT ROLE analytics_admin TO ROLE sysadmin;
GRANT ROLE data_engineering_admin TO ROLE sysadmin;
```

---

## 4. Custom Role Design Patterns

### 4.1 Functional Roles vs. Access Roles

A best practice is to separate **functional roles** (assigned to users based on their job function) from **access roles** (granted specific object privileges).

```
Functional Roles          Access Roles            Objects
─────────────────     ─────────────────     ─────────────────
SENIOR_ANALYST   ──>  ANALYTICS_READ   ──>  SELECT on analytics_db.*
                 ──>  STAGING_WRITE    ──>  INSERT on staging_db.raw.*

JUNIOR_ANALYST   ──>  ANALYTICS_READ   ──>  SELECT on analytics_db.*

DATA_ENGINEER    ──>  STAGING_WRITE    ──>  INSERT on staging_db.raw.*
                 ──>  PROD_DDL         ──>  CREATE TABLE on production_db.*
                 ──>  ANALYTICS_READ   ──>  SELECT on analytics_db.*
```

```sql
-- Access roles (object-level privileges)
CREATE ROLE analytics_read;
GRANT USAGE ON DATABASE analytics_db TO ROLE analytics_read;
GRANT USAGE ON ALL SCHEMAS IN DATABASE analytics_db TO ROLE analytics_read;
GRANT SELECT ON ALL TABLES IN DATABASE analytics_db TO ROLE analytics_read;
GRANT SELECT ON FUTURE TABLES IN DATABASE analytics_db TO ROLE analytics_read;

CREATE ROLE staging_write;
GRANT USAGE ON DATABASE staging_db TO ROLE staging_write;
GRANT USAGE ON SCHEMA staging_db.raw TO ROLE staging_write;
GRANT INSERT, UPDATE ON ALL TABLES IN SCHEMA staging_db.raw TO ROLE staging_write;
GRANT INSERT, UPDATE ON FUTURE TABLES IN SCHEMA staging_db.raw TO ROLE staging_write;

CREATE ROLE prod_ddl;
GRANT USAGE ON DATABASE production_db TO ROLE prod_ddl;
GRANT CREATE TABLE, CREATE VIEW ON ALL SCHEMAS IN DATABASE production_db TO ROLE prod_ddl;

-- Functional roles (combine access roles)
CREATE ROLE senior_analyst;
GRANT ROLE analytics_read TO ROLE senior_analyst;
GRANT ROLE staging_write TO ROLE senior_analyst;

CREATE ROLE junior_analyst;
GRANT ROLE analytics_read TO ROLE junior_analyst;

CREATE ROLE data_engineer;
GRANT ROLE staging_write TO ROLE data_engineer;
GRANT ROLE prod_ddl TO ROLE data_engineer;
GRANT ROLE analytics_read TO ROLE data_engineer;

-- Roll up to SYSADMIN
GRANT ROLE senior_analyst TO ROLE sysadmin;
GRANT ROLE junior_analyst TO ROLE sysadmin;
GRANT ROLE data_engineer TO ROLE sysadmin;
```

### 4.2 Benefits of This Pattern

- **Reusability**: Access roles can be shared across functional roles.
- **Maintainability**: Adding a new table only requires updating the relevant access role.
- **Auditability**: Clear separation makes it easy to answer "who has access to what."
- **Least privilege**: Each functional role gets only the access roles it needs.

---

## 5. Ownership and MANAGE GRANTS

### 5.1 Ownership

Every securable object in Snowflake has an **owner** role. The owner has full control over the object, including the ability to grant privileges on it to other roles.

```sql
-- Check ownership
SHOW GRANTS ON TABLE production_db.public.orders;

-- Transfer ownership
GRANT OWNERSHIP ON TABLE production_db.public.orders
  TO ROLE data_engineering_admin
  REVOKE CURRENT GRANTS;

-- Transfer ownership with COPY CURRENT GRANTS (preserves existing grants)
GRANT OWNERSHIP ON TABLE production_db.public.orders
  TO ROLE data_engineering_admin
  COPY CURRENT GRANTS;
```

### 5.2 MANAGE GRANTS Privilege

The `MANAGE GRANTS` global privilege allows a role to grant or revoke privileges on any object, regardless of ownership. **SECURITYADMIN** has this by default.

```sql
-- Grant MANAGE GRANTS to a custom security role
GRANT MANAGE GRANTS ON ACCOUNT TO ROLE security_team;
```

> **Warning**: `MANAGE GRANTS` is extremely powerful. Grant it only to security-focused roles, never to general-purpose roles.

---

## 6. Database Roles

**Database roles** are roles scoped to a specific database. They simplify privilege management within a database and are especially useful with Snowflake **Secure Data Sharing**.

```sql
-- Create a database role
CREATE DATABASE ROLE analytics_db.db_reader;

-- Grant privileges to the database role
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_db.public
  TO DATABASE ROLE analytics_db.db_reader;
GRANT SELECT ON FUTURE TABLES IN SCHEMA analytics_db.public
  TO DATABASE ROLE analytics_db.db_reader;

-- Grant the database role to an account role
GRANT DATABASE ROLE analytics_db.db_reader TO ROLE analyst_role;
```

**Key characteristics:**
- Database roles exist within a database and cannot span multiple databases.
- They can be granted to other database roles within the same database or to account-level roles.
- They are replicated with the database during database replication.
- They are the recommended way to manage shared database access in data sharing scenarios.

---

## 7. Instance Roles

**Instance roles** are roles associated with a specific class instance, such as Snowpark Container Services or Snowflake-managed applications. They control access to operations on that specific instance.

```sql
-- Example: Grant an instance role from a Snowflake Native App
GRANT APPLICATION ROLE my_app.app_viewer TO ROLE analyst_role;
```

Instance roles are most relevant when working with:
- Snowflake Native Apps (application roles)
- Snowpark Container Services

---

## 8. Role Activation: Primary and Secondary Roles

When a user has multiple roles granted to them, Snowflake allows using a **primary role** and optionally **secondary roles** within a session.

### Primary Role
The active role that determines object ownership for new objects created in the session.

```sql
-- Set primary role
USE ROLE data_engineer;
```

### Secondary Roles
Additional roles whose privileges are combined with the primary role. This allows a user to access objects across multiple roles without switching.

```sql
-- Enable all granted roles as secondary
USE SECONDARY ROLES ALL;

-- Disable secondary roles
USE SECONDARY ROLES NONE;
```

**Example scenario:**
- User has `DATA_ENGINEER` (primary) and `ANALYST_ROLE` (secondary).
- With secondary roles enabled, the user can both write to staging tables (via DATA_ENGINEER) and read from analytics tables (via ANALYST_ROLE) in the same session.
- New objects created will be owned by `DATA_ENGINEER` (the primary role).

```sql
-- Check current roles in session
SELECT CURRENT_ROLE();           -- Primary role
SELECT CURRENT_SECONDARY_ROLES(); -- Secondary roles
```

---

## 9. Auditing Role Usage

### SHOW GRANTS Commands

```sql
-- Show all privileges granted TO a role
SHOW GRANTS TO ROLE data_engineer;

-- Show all privileges granted ON an object
SHOW GRANTS ON DATABASE production_db;

-- Show all roles granted to a user
SHOW GRANTS TO USER john_doe;

-- Show all roles granted to a role (role hierarchy)
SHOW GRANTS OF ROLE data_engineer;

-- Show all future grants in a schema
SHOW FUTURE GRANTS IN SCHEMA production_db.public;
```

### Using ACCOUNT_USAGE for Auditing

```sql
-- Find all users who used ACCOUNTADMIN in the last 30 days
SELECT DISTINCT user_name, role_name, MIN(start_time) AS first_used, MAX(start_time) AS last_used
FROM snowflake.account_usage.query_history
WHERE role_name = 'ACCOUNTADMIN'
  AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY user_name, role_name
ORDER BY last_used DESC;

-- Review all grants made in the last 7 days
SELECT *
FROM snowflake.account_usage.grants_to_roles
WHERE created_on >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY created_on DESC;

-- Find roles with excessive privileges
SELECT grantee_name AS role_name,
       privilege,
       COUNT(*) AS grant_count
FROM snowflake.account_usage.grants_to_roles
WHERE deleted_on IS NULL
GROUP BY grantee_name, privilege
ORDER BY grant_count DESC
LIMIT 20;

-- Identify users with ACCOUNTADMIN
SELECT grantee_name AS user_name, role, created_on
FROM snowflake.account_usage.grants_to_users
WHERE role = 'ACCOUNTADMIN'
  AND deleted_on IS NULL;
```

---

## 10. Separation of Duties

Separation of duties ensures that no single role or user has unchecked power.

### Principles

| Principle | Implementation |
|-----------|---------------|
| Limit ACCOUNTADMIN usage | Require MFA, use only when necessary, audit all usage |
| Separate security from data management | SECURITYADMIN manages grants; SYSADMIN manages objects |
| Separate ETL ownership from consumption | ETL roles own and write data; analyst roles only read |
| No direct user-to-privilege grants | Always grant privileges to roles, then roles to users |
| Require approval for elevated access | Use external workflows for ACCOUNTADMIN or SECURITYADMIN access |

```sql
-- ANTI-PATTERN: Granting privilege directly to a user
GRANT SELECT ON TABLE orders TO USER john_doe; -- DO NOT DO THIS

-- CORRECT: Grant to a role, then role to user
GRANT SELECT ON TABLE orders TO ROLE analyst_role;
GRANT ROLE analyst_role TO USER john_doe;
```

---

## 11. Least Privilege Principle

Grant only the minimum privileges required for a role to perform its function.

```sql
-- OVER-PRIVILEGED (avoid)
GRANT ALL PRIVILEGES ON DATABASE production_db TO ROLE analyst_role;

-- LEAST PRIVILEGE (preferred)
GRANT USAGE ON DATABASE production_db TO ROLE analyst_role;
GRANT USAGE ON SCHEMA production_db.public TO ROLE analyst_role;
GRANT SELECT ON ALL TABLES IN SCHEMA production_db.public TO ROLE analyst_role;
GRANT SELECT ON FUTURE TABLES IN SCHEMA production_db.public TO ROLE analyst_role;
```

### Future Grants

Future grants automatically apply privileges to objects created in the future, preventing gaps when new tables or views are added.

```sql
-- Grant SELECT on all future tables in a schema
GRANT SELECT ON FUTURE TABLES IN SCHEMA analytics_db.public TO ROLE analyst_role;

-- Grant SELECT on all future views in a database
GRANT SELECT ON FUTURE VIEWS IN DATABASE analytics_db TO ROLE analyst_role;
```

---

## 12. Common Interview Questions & Answers

### Q1: Explain the Snowflake system-defined role hierarchy.

**A:** Snowflake has six system roles. At the top is **ORGADMIN** for organization-level tasks. **ACCOUNTADMIN** is the top account-level role combining **SECURITYADMIN** (which manages grants and inherits **USERADMIN** for user/role creation) and **SYSADMIN** (which manages all database objects and warehouses). **PUBLIC** is the base role automatically granted to every user. Custom roles should be granted to SYSADMIN so that ACCOUNTADMIN inherits access to all objects through the hierarchy.

---

### Q2: What is the difference between functional roles and access roles?

**A:** **Access roles** are granted specific object-level privileges (e.g., SELECT on a set of tables). **Functional roles** represent job functions and are composed of one or more access roles. Users are assigned functional roles. This pattern provides reusability (multiple functional roles can share the same access role), clarity, and easier maintenance.

---

### Q3: Why should custom roles roll up to SYSADMIN?

**A:** If custom roles do not roll up to SYSADMIN, the objects they own become accessible only through ACCOUNTADMIN directly. This breaks the intended hierarchy, creates management blind spots, and forces more frequent use of the highly privileged ACCOUNTADMIN role — which is a security risk.

---

### Q4: What are database roles and when would you use them?

**A:** Database roles are scoped to a single database. They are ideal for managing access within a database, especially in **data sharing** scenarios — when you share a database, the database roles are shared with it, allowing the consumer to inherit the correct privileges. They also simplify privilege management by keeping role definitions close to the objects they govern.

---

### Q5: How do secondary roles work?

**A:** By default, a Snowflake session uses a single **primary role**. With `USE SECONDARY ROLES ALL`, a user activates all their other granted roles as secondary. The session then has the **union** of privileges from the primary and all secondary roles. Objects created in the session are owned by the primary role. This eliminates the need to switch roles frequently.

---

### Q6: How would you audit who has access to a sensitive table?

**A:**
1. Run `SHOW GRANTS ON TABLE <table>` to see all roles with direct grants.
2. For each role, run `SHOW GRANTS OF ROLE <role>` to see which users and parent roles inherit that access.
3. For a comprehensive historical view, query `SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES` and `GRANTS_TO_USERS`.
4. Check for secondary role activation by reviewing `QUERY_HISTORY` for queries that accessed the table.

---

### Q7: What is MANAGE GRANTS and why is it dangerous?

**A:** `MANAGE GRANTS` is a global privilege that allows a role to grant or revoke privileges on **any** object in the account, regardless of ownership. It effectively bypasses ownership-based access control. It is held by SECURITYADMIN by default. Granting it to other roles should be done with extreme caution, as it can be used to escalate privileges.

---

### Q8: How do you implement separation of duties in Snowflake?

**A:**
- Use SECURITYADMIN for managing grants and roles; use SYSADMIN for managing objects.
- Restrict ACCOUNTADMIN to break-glass scenarios with MFA enforcement.
- Never grant privileges directly to users — always use roles.
- Separate ETL/write roles from analytics/read roles.
- Use access roles + functional roles pattern.
- Audit role usage regularly using ACCOUNT_USAGE views.

---

## 13. Tips

- **Never use ACCOUNTADMIN as a default role** for any user. Set default roles to the least-privileged role needed for daily work.
- **Always use future grants** when setting up access roles — otherwise new tables will be inaccessible until manually granted.
- **Enforce MFA on ACCOUNTADMIN** — this is a Snowflake security best practice and increasingly an audit requirement.
- **Document your role hierarchy** — maintain a diagram or data dictionary of roles, their purpose, and their grants.
- **Audit regularly** — schedule quarterly reviews of role grants, especially for privileged roles.
- **Use `SHOW GRANTS` liberally during development** — it is the fastest way to debug "insufficient privileges" errors.
- **Be careful with OWNERSHIP transfers** — transferring ownership with `REVOKE CURRENT GRANTS` removes all existing grants on the object, which can break access for other roles.
- **Name roles consistently** — use prefixes like `AR_` for access roles and `FR_` for functional roles to make the hierarchy self-documenting.
- **Test role configurations in a non-production account** before deploying to production.

---
