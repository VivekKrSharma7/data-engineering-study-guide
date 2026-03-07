# Network Policies & Private Connectivity

[Back to Snowflake Index](./README.md)

---

## Table of Contents

1. [Overview](#overview)
2. [Network Policies](#network-policies)
3. [Applying Network Policies](#applying-network-policies)
4. [Network Rules (2023+)](#network-rules-2023)
5. [AWS PrivateLink](#aws-privatelink)
6. [Azure Private Link](#azure-private-link)
7. [GCP Private Service Connect](#gcp-private-service-connect)
8. [Internal Stages and Private Connectivity](#internal-stages-and-private-connectivity)
9. [SYSTEM$GET_PRIVATELINK_CONFIG](#systemget_privatelink_config)
10. [Tri-Secret Secure & Customer-Managed Keys](#tri-secret-secure--customer-managed-keys)
11. [Security Best Practices](#security-best-practices)
12. [Common Interview Questions](#common-interview-questions)
13. [Tips](#tips)

---

## Overview

Network security in Snowflake controls **where** connections can originate from and **how** traffic is routed between clients and the Snowflake service. By default, Snowflake is accessible over the public internet via HTTPS. Network policies and private connectivity features allow organizations to restrict access to trusted networks and eliminate public internet exposure entirely.

---

## Network Policies

A **network policy** restricts access to a Snowflake account based on the originating IP address. It works by defining allowed and blocked IP ranges.

### How Network Policies Work

- A network policy contains an **ALLOWED_IP_LIST** and an optional **BLOCKED_IP_LIST**.
- If an ALLOWED_IP_LIST is specified, **only** IPs in that list are permitted (whitelist model).
- The BLOCKED_IP_LIST is evaluated as an exception within the allowed list — it blocks specific IPs that would otherwise be allowed.
- Evaluation order: (1) check ALLOWED_IP_LIST, (2) then check BLOCKED_IP_LIST.

### Creating Network Policies

```sql
-- Create a basic network policy
CREATE NETWORK POLICY corporate_access
  ALLOWED_IP_LIST = ('203.0.113.0/24', '198.51.100.0/24')
  BLOCKED_IP_LIST = ('203.0.113.99')
  COMMENT = 'Allow corporate office and VPN ranges, block a specific IP';

-- View network policies
SHOW NETWORK POLICIES;

-- Describe a specific policy
DESCRIBE NETWORK POLICY corporate_access;

-- Modify the policy
ALTER NETWORK POLICY corporate_access
  SET ALLOWED_IP_LIST = ('203.0.113.0/24', '198.51.100.0/24', '10.0.0.0/8');

-- Drop a policy
DROP NETWORK POLICY corporate_access;
```

### IP Range Formats

```sql
-- Single IP address
ALLOWED_IP_LIST = ('192.168.1.100')

-- CIDR notation
ALLOWED_IP_LIST = ('10.0.0.0/8', '172.16.0.0/12')

-- Multiple specific IPs
ALLOWED_IP_LIST = ('203.0.113.10', '203.0.113.11', '203.0.113.12')

-- Allow all (effectively disables the policy — not recommended)
ALLOWED_IP_LIST = ('0.0.0.0/0')
```

---

## Applying Network Policies

Network policies can be applied at two levels: **account-level** and **user-level**. User-level policies take precedence over account-level policies.

### Account-Level Network Policy

Applies to all users connecting to the account.

```sql
-- Set account-level network policy (requires SECURITYADMIN or ACCOUNTADMIN)
ALTER ACCOUNT SET NETWORK_POLICY = corporate_access;

-- Remove account-level network policy
ALTER ACCOUNT UNSET NETWORK_POLICY;

-- Verify current account-level policy
SHOW PARAMETERS LIKE 'network_policy' IN ACCOUNT;
```

### User-Level Network Policy

Overrides the account-level policy for a specific user. Useful for service accounts that connect from different IP ranges.

```sql
-- Set a network policy for a specific user
ALTER USER etl_service_user SET NETWORK_POLICY = etl_access_policy;

-- Remove user-level policy (user falls back to account-level policy)
ALTER USER etl_service_user UNSET NETWORK_POLICY;

-- Verify user-level policy
SHOW PARAMETERS LIKE 'network_policy' IN USER etl_service_user;
```

### Precedence Rules

1. **User-level** network policy is checked first.
2. If no user-level policy exists, the **account-level** policy is applied.
3. If neither exists, all IP addresses are allowed (default behavior).

**Real-world example:** A company sets an account-level policy allowing only corporate office IPs. The ETL service account has a user-level policy that additionally allows the cloud VPC IP range where Airflow runs.

### Critical Safety Warning

```sql
-- DANGER: If you set a network policy that blocks your own IP, you will be locked out.
-- Always ensure your current IP is in the ALLOWED_IP_LIST before activating.

-- Check your current IP from within Snowflake
SELECT CURRENT_IP_ADDRESS();

-- Best practice: test with a user-level policy first before applying account-wide
ALTER USER test_user SET NETWORK_POLICY = new_restrictive_policy;
-- Verify test_user can still connect, then apply to account
ALTER ACCOUNT SET NETWORK_POLICY = new_restrictive_policy;
```

---

## Network Rules (2023+)

**Network rules** are a newer, more flexible mechanism introduced to replace or augment traditional network policies. They support not just IP addresses but also VPC/VNet identifiers and hostnames.

### Network Rule Types

| Type | Description | Use Case |
|------|-------------|----------|
| `IPV4` | IP address ranges | Traditional IP allowlisting |
| `AWSVPCEID` | AWS VPC Endpoint IDs | Restrict to specific AWS VPC endpoints |
| `AZURELINKID` | Azure Private Endpoint IDs | Restrict to specific Azure private endpoints |
| `HOST_PORT` | Hostnames and ports | External access (external functions, SCIM) |

### Creating and Using Network Rules

```sql
-- Create an IP-based network rule
CREATE NETWORK RULE corp_ip_rule
  TYPE = IPV4
  MODE = INGRESS
  VALUE_LIST = ('203.0.113.0/24', '198.51.100.0/24')
  COMMENT = 'Corporate IP ranges';

-- Create a VPC endpoint network rule
CREATE NETWORK RULE aws_vpc_rule
  TYPE = AWSVPCEID
  MODE = INGRESS
  VALUE_LIST = ('vpce-0abc1234def567890')
  COMMENT = 'Production VPC endpoint';

-- Create a network policy using network rules
CREATE NETWORK POLICY modern_policy
  ALLOWED_NETWORK_RULE_LIST = ('corp_ip_rule', 'aws_vpc_rule')
  BLOCKED_NETWORK_RULE_LIST = ()
  COMMENT = 'Policy using network rules';

-- Apply the policy
ALTER ACCOUNT SET NETWORK_POLICY = modern_policy;
```

### Egress Network Rules

Network rules with `MODE = EGRESS` control outbound traffic from Snowflake, used with external functions and external access integrations.

```sql
-- Create an egress rule for an external API
CREATE NETWORK RULE api_egress_rule
  TYPE = HOST_PORT
  MODE = EGRESS
  VALUE_LIST = ('api.example.com:443', 'webhook.example.com:443');

-- Use in an external access integration
CREATE EXTERNAL ACCESS INTEGRATION ext_api_access
  ALLOWED_NETWORK_RULES = (api_egress_rule)
  ENABLED = TRUE;
```

---

## AWS PrivateLink

AWS PrivateLink enables private connectivity between your AWS VPC and Snowflake without traffic traversing the public internet.

### How It Works

1. Snowflake exposes a **VPC endpoint service** in the same AWS region as your account.
2. You create a **VPC interface endpoint** in your VPC that connects to Snowflake's endpoint service.
3. DNS is configured to resolve Snowflake URLs to the private endpoint IP.
4. All traffic flows over AWS's private network backbone.

### Setup Steps

```sql
-- Step 1: Enable PrivateLink on your Snowflake account (requires ACCOUNTADMIN)
-- Contact Snowflake Support or use the self-service option if available

-- Step 2: Get PrivateLink configuration
USE ROLE ACCOUNTADMIN;
SELECT SYSTEM$GET_PRIVATELINK_CONFIG();
```

The output includes:
- `privatelink-account-name` — The PrivateLink-specific account URL
- `privatelink-vpce-id` — The service name for creating the VPC endpoint
- `privatelink-account-url` — The URL to use for connections
- `privatelink-ocsp-url` — OCSP endpoint for certificate validation

```sql
-- Step 3: In AWS, create a VPC Interface Endpoint using the service name from above
-- aws ec2 create-vpc-endpoint \
--   --vpc-id vpc-0abc123 \
--   --service-name com.amazonaws.vpce.us-east-1.vpce-svc-0def456 \
--   --subnet-ids subnet-0ghi789 \
--   --security-group-ids sg-0jkl012

-- Step 4: Authorize the endpoint in Snowflake
SELECT SYSTEM$AUTHORIZE_PRIVATELINK(
  'com.amazonaws.vpce.us-east-1.vpce-svc-0def456',
  'vpce-0abc1234def567890'
);

-- Step 5: Configure DNS to resolve *.privatelink.snowflakecomputing.com
-- to the VPC endpoint's private DNS

-- Step 6: (Optional) Block public access — only allow PrivateLink connections
CREATE NETWORK RULE private_only_rule
  TYPE = AWSVPCEID
  MODE = INGRESS
  VALUE_LIST = ('vpce-0abc1234def567890');

CREATE NETWORK POLICY private_only_policy
  ALLOWED_NETWORK_RULE_LIST = ('private_only_rule');

ALTER ACCOUNT SET NETWORK_POLICY = private_only_policy;
```

**Real-world example:** A healthcare company processes PHI (Protected Health Information) in Snowflake. To meet HIPAA requirements, they use AWS PrivateLink so that no patient data traverses the public internet, combined with a network policy that blocks all non-PrivateLink connections.

---

## Azure Private Link

Azure Private Link provides the equivalent private connectivity for Snowflake accounts hosted on Azure.

### Setup Overview

```sql
-- Step 1: Get the PrivateLink configuration
SELECT SYSTEM$GET_PRIVATELINK_CONFIG();
```

Output includes:
- `privatelink-pls-id` — The Private Link Service resource ID
- `privatelink-account-url` — The URL for private connections

```sql
-- Step 2: In Azure, create a Private Endpoint in your VNet
-- az network private-endpoint create \
--   --name snowflake-pe \
--   --resource-group myRG \
--   --vnet-name myVNet \
--   --subnet mySubnet \
--   --private-connection-resource-id <privatelink-pls-id> \
--   --connection-name snowflake-conn \
--   --manual-request true

-- Step 3: Approve the private endpoint connection in Snowflake
SELECT SYSTEM$AUTHORIZE_PRIVATELINK(
  '<azure-private-endpoint-resource-id>'
);

-- Step 4: Configure private DNS zone for
-- <account>.privatelink.snowflakecomputing.com
```

### Key Differences from AWS

| Aspect | AWS PrivateLink | Azure Private Link |
|--------|----------------|-------------------|
| Endpoint type | VPC Interface Endpoint | Private Endpoint |
| DNS configuration | Route 53 Private Hosted Zone | Azure Private DNS Zone |
| Identifier | VPC Endpoint ID (vpce-xxx) | Private Endpoint Resource ID |
| Cross-region | Same region only | Same region only |

---

## GCP Private Service Connect

For Snowflake accounts on GCP, **Private Service Connect** provides equivalent private connectivity.

### Setup Overview

```sql
-- Step 1: Retrieve Private Service Connect configuration
SELECT SYSTEM$GET_PRIVATELINK_CONFIG();
```

```sql
-- Step 2: In GCP, create a forwarding rule to the Snowflake service attachment
-- gcloud compute forwarding-rules create snowflake-psc \
--   --region=us-central1 \
--   --network=my-vpc \
--   --address=snowflake-psc-ip \
--   --target-service-attachment=<service-attachment-uri>

-- Step 3: Authorize in Snowflake
SELECT SYSTEM$AUTHORIZE_PRIVATELINK('<gcp-project-id>');

-- Step 4: Configure Cloud DNS for private resolution
```

---

## Internal Stages and Private Connectivity

When using PrivateLink, data loading and unloading via internal stages also needs to route through the private connection.

```sql
-- Internal stages use a separate endpoint for data transfer
-- The SYSTEM$GET_PRIVATELINK_CONFIG() output includes stage endpoints:
-- 'privatelink-internal-stage' — endpoint for internal stage access

-- For AWS, you may need a separate S3 VPC Gateway Endpoint
-- or the internal stage traffic routes through the PrivateLink connection

-- Verify connectivity to internal stage via private link
-- PUT/GET commands should work without public internet access
PUT file:///tmp/data.csv @my_internal_stage;
GET @my_internal_stage/data.csv file:///tmp/;
```

**Important:** If you block public access with a network policy, ensure your data loading tools (Snowpipe, COPY INTO) can reach Snowflake's internal stage endpoints via the private connection.

---

## SYSTEM$GET_PRIVATELINK_CONFIG

This system function returns the configuration details needed to set up private connectivity.

```sql
-- Must be called by ACCOUNTADMIN
USE ROLE ACCOUNTADMIN;
SELECT SYSTEM$GET_PRIVATELINK_CONFIG();
```

### Sample Output (AWS)

```json
{
  "regionless-snowsight-privatelink-url": "app-myorg.privatelink.snowflakecomputing.com",
  "privatelink-account-url": "myorg-myaccount.privatelink.snowflakecomputing.com",
  "privatelink-connection-ocsp-urls": "ocsp.myorg-myaccount.privatelink.snowflakecomputing.com",
  "privatelink-connection-urls": "myorg-myaccount.privatelink.snowflakecomputing.com",
  "privatelink-vpce-id": "com.amazonaws.vpce.us-east-1.vpce-svc-0abc123def456",
  "privatelink-ocsp-url": "ocsp.privatelink.snowflakecomputing.com",
  "privatelink_internal-stage-url": "sfc-ss-ds2-customer-stage.s3.us-east-1.amazonaws.com"
}
```

### Related System Functions

```sql
-- Authorize a private endpoint
SELECT SYSTEM$AUTHORIZE_PRIVATELINK('<endpoint_id>');

-- Revoke a private endpoint authorization
SELECT SYSTEM$REVOKE_PRIVATELINK('<endpoint_id>');

-- Check stage endpoint for private connectivity
SELECT SYSTEM$GET_PRIVATELINK_CONFIG();
```

---

## Tri-Secret Secure & Customer-Managed Keys

While primarily an encryption feature (covered in detail in the encryption topic), Tri-Secret Secure has network and access control implications.

### Overview

Tri-Secret Secure is an advanced security feature where a **customer-managed key** (CMK) in a cloud provider's KMS is combined with a **Snowflake-managed key** to create a composite master key. This gives the customer the ability to revoke Snowflake's access to their data at any time by disabling the CMK.

```sql
-- Tri-Secret Secure is configured at the account level
-- Requires Business Critical Edition or higher
-- Setup involves:
-- 1. Creating a KMS key in your cloud provider (AWS KMS, Azure Key Vault, GCP Cloud KMS)
-- 2. Granting Snowflake's service principal access to the key
-- 3. Configuring Snowflake to use the key via support ticket or self-service

-- Verify Tri-Secret Secure status
SELECT SYSTEM$GET_SNOWFLAKE_PLATFORM_INFO();
```

### Customer-Managed Key Setup (AWS Example)

```
1. Create a KMS key in your AWS account
2. Grant the Snowflake IAM role access to the key via key policy
3. Contact Snowflake Support with the KMS key ARN
4. Snowflake configures the composite key
5. Verify: all new data is encrypted with the composite key
```

**Network implication:** If using PrivateLink, the KMS traffic between Snowflake and your CMK also stays on the private network (within the same cloud provider's backbone).

---

## Security Best Practices

### Network Policy Best Practices

1. **Always set an account-level network policy** — Even a broad one is better than none.
2. **Test policies with user-level assignment first** before applying account-wide.
3. **Keep your own IP in the allowed list** — Lock yourself out and you will need Snowflake Support.
4. **Use CIDR ranges, not individual IPs** — Easier to maintain and less error-prone.
5. **Document all IP ranges** — Maintain a mapping of which ranges belong to which teams/services.
6. **Review network policies quarterly** — IP ranges change as infrastructure evolves.

### Private Connectivity Best Practices

7. **Use PrivateLink for production workloads** — Eliminates public internet exposure.
8. **Block public access after PrivateLink is verified** — Use a network policy with VPC endpoint rules.
9. **Configure DNS properly** — Incorrect DNS is the most common PrivateLink setup issue.
10. **Test OCSP connectivity** — Certificate validation must also work over the private connection.
11. **Plan for internal stage access** — Data loading paths must also route privately.

### General Security Best Practices

12. **Enable Tri-Secret Secure for sensitive data** — Gives you a "kill switch" for data access.
13. **Combine network policies with MFA** — Defense in depth.
14. **Monitor failed login attempts** — Use `SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY`.
15. **Use network rules (2023+) for more granular control** — They support VPC endpoints natively.

```sql
-- Monitor blocked connection attempts
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE ERROR_CODE IS NOT NULL
  AND IS_SUCCESS = 'NO'
ORDER BY EVENT_TIMESTAMP DESC
LIMIT 100;

-- Monitor connections by source IP
SELECT
  CLIENT_IP,
  USER_NAME,
  COUNT(*) AS connection_count,
  MIN(EVENT_TIMESTAMP) AS first_seen,
  MAX(EVENT_TIMESTAMP) AS last_seen
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE EVENT_TIMESTAMP > DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY CLIENT_IP, USER_NAME
ORDER BY connection_count DESC;
```

---

## Common Interview Questions

### Q1: What is a network policy in Snowflake and how does it work?

**Answer:** A network policy controls which IP addresses can connect to a Snowflake account. It uses an **ALLOWED_IP_LIST** (whitelist) and an optional **BLOCKED_IP_LIST** (exceptions within the whitelist). When set at the account level, it applies to all users. User-level policies can override account-level policies for specific users. If no policy is set, all IPs are permitted by default.

### Q2: What happens if both an account-level and user-level network policy exist?

**Answer:** The **user-level** network policy takes precedence. The account-level policy is ignored entirely for that user. This allows exceptions — for example, a service account may need access from a different IP range than the general corporate policy allows.

### Q3: What is AWS PrivateLink and why would you use it with Snowflake?

**Answer:** AWS PrivateLink creates a private connection between your AWS VPC and Snowflake's VPC through an interface endpoint. Traffic never leaves AWS's private network. You would use it to: (a) meet compliance requirements that prohibit public internet exposure (HIPAA, PCI-DSS), (b) reduce attack surface by eliminating public endpoints, (c) improve network latency by avoiding internet routing. It requires Snowflake Business Critical Edition or higher.

### Q4: How do you prevent all public internet access to Snowflake?

**Answer:** Three steps: (1) Set up PrivateLink/Private Link/Private Service Connect for your cloud provider. (2) Create a network policy that only allows connections from your private endpoint (using network rules with VPC endpoint IDs). (3) Apply the network policy at the account level. This ensures only traffic through the private connection is accepted.

### Q5: What is the difference between traditional network policies and network rules?

**Answer:** Traditional network policies only support IP address-based filtering. **Network rules** (introduced in 2023) support additional identifier types: AWS VPC Endpoint IDs, Azure Private Endpoint IDs, and hostnames. Network rules also support both ingress (incoming) and egress (outgoing) control. They are created as standalone objects and then referenced in network policies, enabling reuse and better organization.

### Q6: What is Tri-Secret Secure?

**Answer:** Tri-Secret Secure is a feature where a **composite master key** is created from a combination of a Snowflake-managed key and a customer-managed key (CMK) stored in the customer's cloud KMS. If the customer disables or deletes their CMK, Snowflake can no longer decrypt the data — effectively giving the customer a "kill switch." It requires Business Critical Edition or higher.

### Q7: How do you troubleshoot PrivateLink connectivity issues?

**Answer:** Common troubleshooting steps: (1) Verify DNS resolution — the Snowflake URL should resolve to a private IP in your VPC, not a public IP. (2) Check security group rules on the VPC endpoint. (3) Verify the endpoint is authorized in Snowflake with `SYSTEM$AUTHORIZE_PRIVATELINK`. (4) Test OCSP connectivity — certificate validation needs to work over the private path. (5) Check that internal stage endpoints are also accessible if doing data loading.

### Q8: What is the risk of applying a network policy incorrectly?

**Answer:** If you apply a network policy that does not include your current IP address, **you will be locked out** of the account. Recovery requires contacting Snowflake Support, which can take time. Best practice is to always verify your current IP with `SELECT CURRENT_IP_ADDRESS()` and test policies at the user level before applying account-wide.

### Q9: How do network rules handle egress traffic?

**Answer:** Egress network rules (MODE = EGRESS) control outbound connections from Snowflake to external services. They use the HOST_PORT type to specify which external hostnames and ports Snowflake can reach. This is used with external functions and external access integrations to limit where Snowflake can send data, following the principle of least privilege for outbound traffic.

### Q10: Can PrivateLink work across AWS regions?

**Answer:** No, AWS PrivateLink is **region-specific**. Your VPC and the Snowflake account must be in the same AWS region. For cross-region scenarios, you would need VPC peering or transit gateway to route traffic from a remote region's VPC to the VPC that has the PrivateLink endpoint.

---

## Tips

- **Always check `CURRENT_IP_ADDRESS()` before activating a network policy** — being locked out is the most common and painful mistake.
- **PrivateLink requires Business Critical Edition** (or higher). Standard and Enterprise editions do not support it.
- **DNS is the number one source of PrivateLink issues** — if the Snowflake URL resolves to a public IP, traffic is not going through PrivateLink even if the endpoint exists.
- **Network policies do not affect internal Snowflake operations** — features like replication, failover, and Snowpipe notifications use Snowflake's internal network.
- **Use `LOGIN_HISTORY` for security monitoring** — it records source IPs, client types, and error codes for every connection attempt.
- **Network rules are the future** — if you are on a recent Snowflake version, prefer network rules over raw IP lists in network policies for better flexibility and auditability.
- **Remember that BLOCKED_IP_LIST only blocks within the ALLOWED_IP_LIST** — it is not a standalone deny list. If ALLOWED_IP_LIST is empty, BLOCKED_IP_LIST has no effect.

---
