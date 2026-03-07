# Authentication & Authorization (RBAC, DAC)

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Overview](#overview)
2. [Authentication Methods](#authentication-methods)
3. [Role-Based Access Control (RBAC)](#role-based-access-control-rbac)
4. [System-Defined Roles](#system-defined-roles)
5. [Custom Roles & Role Hierarchy](#custom-roles--role-hierarchy)
6. [Discretionary Access Control (DAC)](#discretionary-access-control-dac)
7. [Privilege Types](#privilege-types)
8. [GRANT and REVOKE Syntax](#grant-and-revoke-syntax)
9. [FUTURE GRANTS](#future-grants)
10. [Ownership Transfer](#ownership-transfer)
11. [SHOW GRANTS](#show-grants)
12. [Access Control Best Practices](#access-control-best-practices)
13. [Common Interview Questions](#common-interview-questions)
14. [Tips](#tips)

---

## Overview

Snowflake uses a hybrid access control model that combines **Role-Based Access Control (RBAC)** and **Discretionary Access Control (DAC)**. This dual approach provides a flexible and secure framework for managing who can access what within a Snowflake account. Authentication determines *who you are*, while authorization determines *what you can do*.

---

## Authentication Methods

Authentication is the process of verifying the identity of a user or service attempting to connect to Snowflake.

### Password-Based Authentication

The simplest method. Users provide a username and password.

```sql
-- Create a user with password authentication
CREATE USER analyst_user
  PASSWORD = 'StrongP@ssw0rd!'
  DEFAULT_ROLE = ANALYST_ROLE
  DEFAULT_WAREHOUSE = COMPUTE_WH
  MUST_CHANGE_PASSWORD = TRUE;
```

### Multi-Factor Authentication (MFA)

Snowflake supports MFA via the Duo Security service (built-in). It adds a second verification step beyond password.

```sql
-- MFA is enrolled by the user through the Snowflake UI (Snowsight)
-- Administrators can enforce MFA for specific users:
ALTER USER analyst_user SET MINS_TO_BYPASS_MFA = 0;

-- Check MFA enrollment status
DESCRIBE USER analyst_user;

-- Enforce MFA for all users via a network/authentication policy (Snowflake 2023+)
CREATE AUTHENTICATION POLICY require_mfa
  MFA_AUTHENTICATION_METHODS = ('TOTP')
  CLIENT_TYPES = ('SNOWFLAKE_UI', 'SNOWSQL', 'DRIVERS')
  MFA_ENROLLMENT = 'REQUIRED';

ALTER ACCOUNT SET AUTHENTICATION POLICY require_mfa;
```

**Real-world example:** A financial services company mandates MFA for every Snowflake user to meet SOC 2 and PCI-DSS compliance requirements.

### Key Pair Authentication

Uses RSA key pairs (2048-bit minimum). The private key stays with the client, the public key is registered in Snowflake. This is the preferred method for service accounts and automated pipelines.

```sql
-- Step 1: Generate RSA key pair (done outside Snowflake)
-- openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
-- openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

-- Step 2: Assign the public key to a user
ALTER USER etl_service_user SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqh...';

-- Step 3: Optionally set a second key for rotation
ALTER USER etl_service_user SET RSA_PUBLIC_KEY_2 = 'MIIBIjANBgkqh...';
```

**Real-world example:** An Airflow-based ETL pipeline uses key pair authentication so no passwords are stored in DAG configurations or environment variables.

### SSO / SAML 2.0

Snowflake supports federated authentication via SAML 2.0 with identity providers such as Okta, Azure AD, ADFS, and PingFederate.

```sql
-- Configure SAML integration
CREATE SECURITY INTEGRATION okta_sso
  TYPE = SAML2
  SAML2_ISSUER = 'http://www.okta.com/exk1234567'
  SAML2_SSO_URL = 'https://company.okta.com/app/snowflake/sso/saml'
  SAML2_PROVIDER = 'OKTA'
  SAML2_X509_CERT = 'MIIC...'
  SAML2_SP_INITIATED_LOGIN_PAGE_LABEL = 'Okta SSO Login'
  SAML2_ENABLE_SP_INITIATED = TRUE;
```

### OAuth (External OAuth & Snowflake OAuth)

Used for programmatic access, BI tools, and third-party applications.

```sql
-- External OAuth integration (e.g., Azure AD)
CREATE SECURITY INTEGRATION azure_oauth
  TYPE = EXTERNAL_OAUTH
  EXTERNAL_OAUTH_TYPE = AZURE
  EXTERNAL_OAUTH_ISSUER = 'https://sts.windows.net/<tenant-id>/'
  EXTERNAL_OAUTH_JWS_KEYS_URL = 'https://login.microsoftonline.com/<tenant-id>/discovery/v2.0/keys'
  EXTERNAL_OAUTH_AUDIENCE_LIST = ('https://<account>.snowflakecomputing.com')
  EXTERNAL_OAUTH_TOKEN_USER_MAPPING_CLAIM = 'upn'
  EXTERNAL_OAUTH_SNOWFLAKE_USER_MAPPING_ATTRIBUTE = 'LOGIN_NAME';
```

### SCIM (System for Cross-domain Identity Management)

SCIM automates user and group provisioning/deprovisioning from an identity provider to Snowflake.

```sql
-- Create a SCIM integration
CREATE SECURITY INTEGRATION okta_scim
  TYPE = SCIM
  SCIM_CLIENT = 'OKTA'
  RUN_AS_ROLE = 'OKTA_PROVISIONER';

-- The IdP uses the generated token to push user/group changes via REST API
SELECT SYSTEM$GENERATE_SCIM_ACCESS_TOKEN('OKTA_SCIM');
```

**Real-world example:** When an employee is terminated in Okta, SCIM automatically disables their Snowflake account within minutes, preventing lingering access.

---

## Role-Based Access Control (RBAC)

RBAC is a security paradigm where access permissions are assigned to **roles**, and roles are assigned to **users**. Users do not receive privileges directly; they inherit them through the roles they hold.

**Key principles:**
- Every session runs under a single **active role** (the user can switch roles).
- A role can be granted to other roles, forming a **role hierarchy**.
- Privileges flow upward through the hierarchy — a parent role inherits all privileges of its child roles.
- Every securable object is owned by a single role.

```
ACCOUNTADMIN
├── SYSADMIN
│   ├── custom_role_a
│   └── custom_role_b
├── SECURITYADMIN
│   └── USERADMIN
└── PUBLIC (granted to every user automatically)
```

---

## System-Defined Roles

Snowflake provides five system-defined roles that cannot be dropped.

### ACCOUNTADMIN

- The **top-level role** that encapsulates SYSADMIN and SECURITYADMIN.
- Can manage all aspects of the account: billing, resource monitors, reader accounts.
- Should be assigned to a **very limited** number of users.
- Always enable MFA for ACCOUNTADMIN users.

```sql
-- View resource monitors (ACCOUNTADMIN only)
USE ROLE ACCOUNTADMIN;
SHOW RESOURCE MONITORS;
```

### SYSADMIN

- Manages all **database objects** (databases, schemas, tables, views, warehouses).
- Recommended as the owner of all custom databases and warehouses.
- All custom roles should ultimately roll up to SYSADMIN.

```sql
USE ROLE SYSADMIN;
CREATE DATABASE analytics_db;
CREATE WAREHOUSE transform_wh
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE;
```

### SECURITYADMIN

- Manages **grants**, **roles**, and **users** (via the MANAGE GRANTS global privilege).
- Can grant or revoke privileges on any object, even if it does not own them.
- Inherits USERADMIN.

```sql
USE ROLE SECURITYADMIN;
GRANT ROLE analyst_role TO USER john_doe;
GRANT USAGE ON WAREHOUSE compute_wh TO ROLE analyst_role;
```

### USERADMIN

- Can **create and manage users and roles**.
- Cannot grant privileges on objects it does not own (unlike SECURITYADMIN).
- Suitable for delegated user management.

```sql
USE ROLE USERADMIN;
CREATE ROLE data_scientist_role;
CREATE USER ds_user_01 PASSWORD = 'Temp1234!' MUST_CHANGE_PASSWORD = TRUE;
GRANT ROLE data_scientist_role TO USER ds_user_01;
```

### PUBLIC

- Automatically granted to **every user** and **every role**.
- Any privilege granted to PUBLIC is effectively available to everyone.
- Use with extreme caution; avoid granting sensitive privileges to PUBLIC.

---

## Custom Roles & Role Hierarchy

### Creating Custom Roles

```sql
-- Create a functional role
CREATE ROLE data_engineer_role
  COMMENT = 'Role for data engineering team members';

-- Create an access role (granular object access)
CREATE ROLE raw_db_read_role
  COMMENT = 'Read access to RAW database';

-- Grant the access role to the functional role
GRANT ROLE raw_db_read_role TO ROLE data_engineer_role;

-- Grant the functional role to SYSADMIN (best practice)
GRANT ROLE data_engineer_role TO ROLE SYSADMIN;
```

### Role Hierarchy Best Practices

1. **Use a two-tier role model:** functional roles (assigned to users) and access roles (hold object privileges).
2. **All custom roles should roll up to SYSADMIN** so that SYSADMIN can manage all objects.
3. **Never grant ACCOUNTADMIN to service accounts** or automated processes.
4. **Keep the hierarchy shallow** — deeply nested hierarchies are hard to audit.
5. **Use naming conventions** — e.g., `<TEAM>_<ACCESS_LEVEL>_ROLE` like `ANALYTICS_READ_ROLE`, `ANALYTICS_WRITE_ROLE`.

```
ACCOUNTADMIN
├── SYSADMIN
│   ├── DATA_ENGINEER_ROLE  (functional)
│   │   ├── RAW_DB_READ_ROLE (access)
│   │   ├── STAGING_DB_WRITE_ROLE (access)
│   │   └── WAREHOUSE_DE_ROLE (access)
│   ├── ANALYST_ROLE (functional)
│   │   ├── ANALYTICS_DB_READ_ROLE (access)
│   │   └── WAREHOUSE_ANALYST_ROLE (access)
│   └── ...
├── SECURITYADMIN
│   └── USERADMIN
└── PUBLIC
```

---

## Discretionary Access Control (DAC)

In DAC, the **owner** of an object controls who else can access it. In Snowflake, every object has an owning role, and that role can grant privileges on the object to other roles.

**Key DAC characteristics in Snowflake:**
- When a role creates an object, that role becomes the **owner**.
- The owner has full control including the ability to GRANT privileges to other roles.
- Ownership can be transferred to another role.
- DAC works alongside RBAC — SECURITYADMIN (via MANAGE GRANTS) can override DAC restrictions.

```sql
-- data_engineer_role creates a table and becomes the owner
USE ROLE data_engineer_role;
CREATE TABLE staging_db.public.raw_events (
  event_id STRING,
  event_ts TIMESTAMP,
  payload VARIANT
);

-- The owner grants SELECT to another role
GRANT SELECT ON TABLE staging_db.public.raw_events TO ROLE analyst_role;
```

---

## Privilege Types

### Account-Level Privileges

```sql
-- Examples of account-level privileges
GRANT CREATE DATABASE ON ACCOUNT TO ROLE sysadmin;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE sysadmin;
GRANT MONITOR USAGE ON ACCOUNT TO ROLE monitor_role;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE etl_role;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE sysadmin;
```

### Database-Level Privileges

```sql
GRANT USAGE ON DATABASE analytics_db TO ROLE analyst_role;
GRANT CREATE SCHEMA ON DATABASE analytics_db TO ROLE data_engineer_role;
GRANT MONITOR ON DATABASE analytics_db TO ROLE monitor_role;
```

### Schema-Level Privileges

```sql
GRANT USAGE ON SCHEMA analytics_db.public TO ROLE analyst_role;
GRANT CREATE TABLE ON SCHEMA analytics_db.staging TO ROLE data_engineer_role;
GRANT CREATE VIEW ON SCHEMA analytics_db.marts TO ROLE data_engineer_role;
GRANT ALL PRIVILEGES ON SCHEMA analytics_db.staging TO ROLE data_engineer_role;
```

### Object-Level Privileges

```sql
-- Table privileges
GRANT SELECT ON TABLE analytics_db.public.dim_customer TO ROLE analyst_role;
GRANT INSERT, UPDATE, DELETE ON TABLE staging_db.public.raw_events TO ROLE etl_role;

-- View privileges
GRANT SELECT ON VIEW analytics_db.marts.v_monthly_revenue TO ROLE analyst_role;

-- Warehouse privileges
GRANT USAGE ON WAREHOUSE compute_wh TO ROLE analyst_role;
GRANT OPERATE ON WAREHOUSE compute_wh TO ROLE admin_role;  -- suspend/resume
GRANT MONITOR ON WAREHOUSE compute_wh TO ROLE monitor_role;

-- Stage privileges
GRANT READ ON STAGE my_stage TO ROLE loader_role;
GRANT WRITE ON STAGE my_stage TO ROLE etl_role;

-- Function/procedure privileges
GRANT USAGE ON FUNCTION my_udf(VARCHAR) TO ROLE analyst_role;
GRANT USAGE ON PROCEDURE load_data() TO ROLE etl_role;
```

---

## GRANT and REVOKE Syntax

### GRANT Syntax

```sql
-- Grant privilege on object to role
GRANT <privilege> ON <object_type> <object_name> TO ROLE <role_name>;

-- Grant role to user
GRANT ROLE <role_name> TO USER <user_name>;

-- Grant role to another role (hierarchy)
GRANT ROLE <child_role> TO ROLE <parent_role>;

-- Grant with GRANT OPTION (allows the grantee to re-grant the privilege)
GRANT SELECT ON TABLE my_table TO ROLE analyst_role WITH GRANT OPTION;

-- Bulk grant
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_db.public TO ROLE analyst_role;
GRANT USAGE ON ALL SCHEMAS IN DATABASE analytics_db TO ROLE analyst_role;
```

### REVOKE Syntax

```sql
-- Revoke privilege
REVOKE SELECT ON TABLE my_table FROM ROLE analyst_role;

-- Revoke with CASCADE (also revokes from anyone the role re-granted to)
REVOKE SELECT ON TABLE my_table FROM ROLE analyst_role CASCADE;

-- Revoke role from user
REVOKE ROLE analyst_role FROM USER john_doe;

-- Bulk revoke
REVOKE SELECT ON ALL TABLES IN SCHEMA analytics_db.public FROM ROLE analyst_role;
```

---

## FUTURE GRANTS

Future grants automatically apply privileges to objects that will be created in the future within a specified scope. This avoids the need to manually grant privileges every time a new table or view is created.

```sql
-- Grant SELECT on all future tables in a schema
GRANT SELECT ON FUTURE TABLES IN SCHEMA analytics_db.public TO ROLE analyst_role;

-- Grant SELECT on all future views in a database
GRANT SELECT ON FUTURE VIEWS IN DATABASE analytics_db TO ROLE analyst_role;

-- Grant USAGE on all future schemas in a database
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE analytics_db TO ROLE analyst_role;

-- View future grants
SHOW FUTURE GRANTS IN SCHEMA analytics_db.public;
SHOW FUTURE GRANTS IN DATABASE analytics_db;

-- Revoke a future grant
REVOKE SELECT ON FUTURE TABLES IN SCHEMA analytics_db.public FROM ROLE analyst_role;
```

**Important nuances:**
- Future grants at the **database** level and **schema** level can conflict. Schema-level future grants take precedence.
- Future grants do not apply retroactively — existing objects are not affected.
- To cover both existing and future objects, combine `GRANT ... ON ALL` with `GRANT ... ON FUTURE`.

```sql
-- Complete pattern: existing + future
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_db.public TO ROLE analyst_role;
GRANT SELECT ON FUTURE TABLES IN SCHEMA analytics_db.public TO ROLE analyst_role;
```

---

## Ownership Transfer

Ownership of an object can be transferred from one role to another. This is critical when reorganizing role hierarchies or when the creating role should not retain ownership.

```sql
-- Transfer ownership of a single object
GRANT OWNERSHIP ON TABLE staging_db.public.raw_events
  TO ROLE data_engineer_role
  COPY CURRENT GRANTS;   -- preserves existing grants

-- Transfer ownership of all tables in a schema
GRANT OWNERSHIP ON ALL TABLES IN SCHEMA staging_db.public
  TO ROLE data_engineer_role
  COPY CURRENT GRANTS;

-- Transfer ownership of future tables
GRANT OWNERSHIP ON FUTURE TABLES IN SCHEMA staging_db.public
  TO ROLE data_engineer_role;

-- Transfer database ownership
GRANT OWNERSHIP ON DATABASE staging_db
  TO ROLE sysadmin
  COPY CURRENT GRANTS;
```

**The `COPY CURRENT GRANTS` clause** is important — without it, all existing grants on the object are revoked during the transfer, which can break downstream access.

---

## SHOW GRANTS

The `SHOW GRANTS` command is essential for auditing and troubleshooting access issues.

```sql
-- Show all privileges granted to a role
SHOW GRANTS TO ROLE analyst_role;

-- Show all privileges granted ON an object
SHOW GRANTS ON TABLE analytics_db.public.dim_customer;

-- Show all roles granted to a user
SHOW GRANTS TO USER john_doe;

-- Show all roles granted to a role (children)
SHOW GRANTS TO ROLE sysadmin;

-- Show who a role has been granted to (parents and users)
SHOW GRANTS OF ROLE analyst_role;

-- Show future grants in a schema
SHOW FUTURE GRANTS IN SCHEMA analytics_db.public;

-- Useful for auditing: check what ACCOUNTADMIN can do
SHOW GRANTS TO ROLE ACCOUNTADMIN;
```

**Real-world example:** During a security audit, you run `SHOW GRANTS TO ROLE PUBLIC` to verify no sensitive tables are accidentally exposed to all users.

---

## Access Control Best Practices

1. **Principle of least privilege** — Grant only the minimum access required for each role.
2. **Never use ACCOUNTADMIN for day-to-day operations** — Reserve it for administrative tasks only.
3. **Always roll custom roles up to SYSADMIN** — Ensures SYSADMIN can manage all objects.
4. **Use functional + access role pattern** — Functional roles for people, access roles for object groups.
5. **Enforce MFA for ACCOUNTADMIN** — Non-negotiable for production environments.
6. **Limit the number of ACCOUNTADMIN users** — Typically 2-3 people, never a service account.
7. **Use FUTURE GRANTS** — Automate privilege assignment for new objects.
8. **Audit grants regularly** — Use `SHOW GRANTS` and the `SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES` view.
9. **Avoid granting privileges to PUBLIC** unless the data is truly non-sensitive.
10. **Use SCIM for user lifecycle management** — Automates provisioning and deprovisioning.
11. **Use key pair authentication for service accounts** — More secure and auditable than passwords.
12. **Set DEFAULT_ROLE and DEFAULT_WAREHOUSE** for every user.

```sql
-- Audit query: find all direct grants to PUBLIC
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES
WHERE GRANTEE_NAME = 'PUBLIC'
  AND DELETED_ON IS NULL
ORDER BY CREATED_ON DESC;

-- Audit query: find users without MFA
SELECT NAME, HAS_MFA, LAST_SUCCESS_LOGIN
FROM SNOWFLAKE.ACCOUNT_USAGE.USERS
WHERE HAS_MFA = 'false'
  AND DISABLED = 'false'
  AND DELETED_ON IS NULL;
```

---

## Common Interview Questions

### Q1: What is the difference between RBAC and DAC in Snowflake?

**Answer:** RBAC assigns privileges to **roles**, and users inherit privileges through role membership. DAC means the **owner** of an object can decide who else can access it. Snowflake combines both: RBAC determines which role a user is operating under, and DAC allows the owning role to grant access to its objects. SECURITYADMIN can override DAC restrictions via the MANAGE GRANTS privilege.

### Q2: What is the recommended role hierarchy in Snowflake?

**Answer:** All custom roles should ultimately be granted to **SYSADMIN** so that SYSADMIN can manage all objects. The recommended pattern uses two tiers: **access roles** (e.g., `RAW_DB_READ`) that hold object-level privileges, and **functional roles** (e.g., `DATA_ENGINEER`) that aggregate access roles and are assigned to users. Functional roles are then granted to SYSADMIN.

### Q3: What happens if a custom role is NOT granted to SYSADMIN?

**Answer:** SYSADMIN (and by extension ACCOUNTADMIN) cannot manage objects owned by that "orphaned" role. This creates a management gap. ACCOUNTADMIN can still use SECURITYADMIN's MANAGE GRANTS privilege to intervene, but it breaks the intended hierarchy. This is a common misconfiguration.

### Q4: Explain the difference between `GRANT ... ON ALL TABLES` and `GRANT ... ON FUTURE TABLES`.

**Answer:** `ON ALL TABLES` grants privileges to **currently existing** tables in the specified scope. `ON FUTURE TABLES` applies the grant automatically to **tables created after** the grant is issued. To fully cover a schema, you need both commands.

### Q5: What is the WITH GRANT OPTION clause?

**Answer:** When a privilege is granted WITH GRANT OPTION, the receiving role can re-grant that same privilege to other roles. This should be used sparingly as it can lead to uncontrolled privilege sprawl.

### Q6: How does key pair authentication differ from password authentication?

**Answer:** Key pair authentication uses asymmetric RSA cryptography. The public key is stored in Snowflake and the private key remains with the client. It is more secure because: (a) no password is transmitted, (b) private keys can be stored in secret managers or HSMs, (c) rotation is simplified with two key slots (RSA_PUBLIC_KEY and RSA_PUBLIC_KEY_2). It is the recommended approach for service accounts and automation.

### Q7: What is SCIM and why is it important?

**Answer:** SCIM (System for Cross-domain Identity Management) is a protocol that automates user provisioning, deprovisioning, and group (role) management between an identity provider (like Okta or Azure AD) and Snowflake. It ensures that when an employee joins, changes teams, or leaves the organization, their Snowflake access is updated automatically — critical for security and compliance.

### Q8: How can you audit who has access to a specific table?

**Answer:** Use `SHOW GRANTS ON TABLE <table_name>` to see all privileges granted on that table. To see the full picture including role hierarchy, also check `SHOW GRANTS OF ROLE <owning_role>`. For historical auditing, query `SNOWFLAKE.ACCOUNT_USAGE.GRANTS_TO_ROLES` and join with `GRANTS_TO_USERS`.

### Q9: What is the difference between SECURITYADMIN and USERADMIN?

**Answer:** USERADMIN can create and manage users and roles but can only grant privileges on objects it owns. SECURITYADMIN inherits USERADMIN and additionally has the MANAGE GRANTS global privilege, which allows it to grant or revoke privileges on **any** object in the account, regardless of ownership.

### Q10: How do FUTURE GRANTS interact at database vs. schema level?

**Answer:** If future grants exist at both levels, the **schema-level** future grants take precedence for objects created in that schema. Database-level future grants apply only to schemas that do not have their own schema-level future grants defined. This is a commonly misunderstood nuance.

---

## Tips

- **Use `SHOW GRANTS OF ROLE <role>` vs `SHOW GRANTS TO ROLE <role>`** — "OF" shows who the role is granted to (users/roles), "TO" shows what privileges the role has. This distinction trips up many engineers.
- **Test privilege changes in a non-production account first** — Revoking a grant in production can break dashboards and pipelines instantly.
- **Set `ABORT_DETACHED_QUERY = TRUE`** on service accounts to prevent runaway queries if the client disconnects.
- **Document your role hierarchy** with a diagram — invaluable during audits and onboarding.
- **Use `COPY CURRENT GRANTS` when transferring ownership** to avoid accidentally revoking access from downstream roles.
- **Remember that `USAGE` is the gateway privilege** — without USAGE on the database, schema, and warehouse, no other privilege is effective.

---
