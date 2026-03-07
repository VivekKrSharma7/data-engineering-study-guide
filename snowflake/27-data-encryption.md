# Data Encryption (End-to-End, Key Rotation)

[Back to Snowflake Index](./README.md)

---

## 1. Overview

Snowflake provides comprehensive, built-in encryption for all data -- both at rest and in transit. Unlike many platforms where encryption must be configured manually, Snowflake encrypts everything by default with no performance penalty and no additional cost. Understanding the encryption architecture, key hierarchy, and advanced features like Tri-Secret Secure is critical for senior Data Engineers, especially in industries with strict compliance requirements (HIPAA, PCI-DSS, SOC 2, FedRAMP).

---

## 2. End-to-End Encryption

Snowflake implements **end-to-end encryption (E2EE)**, meaning data is encrypted at every stage of its lifecycle:

1. **In transit** -- Data moving between client and Snowflake, and between internal Snowflake components.
2. **At rest** -- Data stored in Snowflake's cloud storage layer (S3, Azure Blob, GCS).
3. **During processing** -- Data remains encrypted in cloud storage; decryption occurs only in the compute layer's memory.

```
Client App ──[TLS 1.2]──> Snowflake Service Layer ──[TLS 1.2]──> Cloud Storage
                                                                    │
                                                              [AES-256 at rest]
```

**Key principle:** Customers never need to manage encryption for data within Snowflake. It is always on, always encrypted, and cannot be disabled.

---

## 3. Encryption at Rest (AES-256)

All data stored in Snowflake is encrypted using **AES-256** (Advanced Encryption Standard with 256-bit keys), one of the strongest symmetric encryption algorithms available.

### What gets encrypted at rest:

| Data Type | Encrypted? |
|---|---|
| Table data (micro-partitions) | Yes (AES-256) |
| Temporary and transient table data | Yes (AES-256) |
| Time Travel data | Yes (AES-256) |
| Fail-safe data | Yes (AES-256) |
| Query results cache | Yes (AES-256) |
| Internal stage files | Yes (AES-256) |
| Metadata | Yes (AES-256) |

### How it works:

- Each micro-partition file is encrypted with its own unique **file key**.
- File keys are themselves encrypted by a **table master key**.
- This ensures that compromising one key does not expose the entire dataset.

---

## 4. Encryption in Transit (TLS 1.2)

All network communication in Snowflake is encrypted using **TLS 1.2** (Transport Layer Security) or higher.

### Communication channels protected:

- **Client to Snowflake:** JDBC, ODBC, Python connector, SnowSQL, web UI -- all use TLS 1.2+.
- **Snowflake to cloud storage:** Internal communication between compute nodes and the storage layer.
- **Snowflake to external stages:** When loading/unloading to S3, Azure Blob, or GCS.
- **Replication traffic:** Data replicated across regions or clouds.

```sql
-- Verify your connection uses TLS (from query history)
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE IS_SUCCESS = 'YES'
ORDER BY EVENT_TIMESTAMP DESC
LIMIT 10;
-- Check the CLIENT_IP and REPORTED_CLIENT_TYPE columns for connection details
```

> **Important:** Snowflake does not support unencrypted connections. TLS is mandatory and cannot be disabled.

---

## 5. Snowflake Encryption Key Hierarchy

Snowflake uses a **hierarchical key model** with four levels, providing defense in depth:

```
┌──────────────────────────────────┐
│          Root Key                │  (Snowflake HSM - Hardware Security Module)
│   (Top of hierarchy)            │
└──────────┬───────────────────────┘
           │ encrypts
┌──────────▼───────────────────────┐
│     Account Master Key           │  (One per Snowflake account)
│   (Unique to each account)       │
└──────────┬───────────────────────┘
           │ encrypts
┌──────────▼───────────────────────┐
│      Table Master Key            │  (One per table, rotated periodically)
│   (Unique to each table)         │
└──────────┬───────────────────────┘
           │ encrypts
┌──────────▼───────────────────────┐
│         File Key                 │  (One per micro-partition file)
│   (Unique to each file)          │
└──────────────────────────────────┘
```

### Key Details:

| Key Level | Scope | Storage | Rotation |
|---|---|---|---|
| **Root Key** | Global (Snowflake-wide) | Hardware Security Module (HSM) | Managed by Snowflake |
| **Account Master Key** | Per account | Encrypted in HSM | Annually (automatic) |
| **Table Master Key** | Per table | Encrypted by account master key | Annually (automatic) |
| **File Key** | Per micro-partition | Encrypted by table master key | New key per file (immutable) |

### Why a hierarchy?

- **Key isolation:** Compromising a file key exposes only one micro-partition.
- **Efficient rotation:** Rotating a table master key only requires re-encrypting file keys, not re-encrypting all data.
- **Performance:** File-level keys enable parallel encryption/decryption across micro-partitions.

---

## 6. Automatic Key Rotation

Snowflake automatically rotates encryption keys on an **annual basis** (every 365 days). This is enabled by default and requires no customer action.

### How automatic rotation works:

1. A new version of the **account master key** is generated.
2. A new version of each **table master key** is generated.
3. New **file keys** for newly written data use the new table master key.
4. Existing file keys are re-encrypted with the new table master key.
5. **The underlying data files are NOT re-encrypted** during standard rotation -- only the key wrapping changes.

```
Before rotation:
  File Key A ──encrypted by──> Table Master Key v1

After rotation:
  File Key A ──encrypted by──> Table Master Key v2  (re-wrapped)
  File Key B ──encrypted by──> Table Master Key v2  (new file)
```

### Monitoring key rotation:

```sql
-- Check encryption key information (requires ACCOUNTADMIN)
-- Key rotation status is visible in the Snowflake web UI under
-- Account > Security section, or via support for detailed audits.
```

---

## 7. Rekeying Data (Periodic Rekeying)

**Rekeying** goes beyond key rotation. While rotation re-wraps the file keys with new master keys, **rekeying actually re-encrypts the data files** with entirely new file keys.

### Why rekeying matters:

- Provides protection against scenarios where an old file key may have been compromised.
- Required by some compliance frameworks (e.g., PCI-DSS).
- Available on **Snowflake Enterprise Edition** and above.

### How rekeying works:

1. Snowflake generates new file keys.
2. Micro-partition data is decrypted with the old file key and re-encrypted with the new file key.
3. This happens automatically in the background with no downtime or performance impact to users.
4. Rekeying is triggered automatically when a key reaches a certain age after rotation.

```
Standard Rotation (all editions):
  Old File Key re-wrapped by New Master Key
  Data files unchanged

Rekeying (Enterprise+):
  New File Key generated
  Data files decrypted and re-encrypted with New File Key
```

> **Key interview point:** Rotation changes the envelope (key wrapping). Rekeying changes the actual data encryption. Both happen automatically.

---

## 8. Tri-Secret Secure (Customer-Managed Keys)

**Tri-Secret Secure** is Snowflake's most advanced encryption offering, available on **Business Critical Edition** and above. It creates a **composite master key** from two components:

1. **Snowflake-maintained key** -- managed by Snowflake in its HSM.
2. **Customer-managed key (CMK)** -- maintained by the customer in their own cloud KMS.

```
┌─────────────────────┐     ┌─────────────────────────┐
│  Customer-Managed    │     │  Snowflake-Managed       │
│  Key (Cloud KMS)     │     │  Key (Snowflake HSM)     │
│                      │     │                          │
│  AWS KMS / Azure     │     │  Internal HSM            │
│  Key Vault / GCP KMS │     │                          │
└──────────┬──────────┘     └──────────┬──────────────┘
           │                            │
           └──────────┬─────────────────┘
                      │
              ┌───────▼────────┐
              │ Composite      │
              │ Master Key     │
              │ (Account Level)│
              └────────────────┘
```

### Key benefits:

- **Customer controls access:** If the customer revokes or disables their CMK, Snowflake cannot decrypt any data -- effectively a "kill switch."
- **Regulatory compliance:** Meets requirements where the customer must maintain control of encryption keys.
- **No Snowflake unilateral access:** Neither party alone can access the data.

### Setup (AWS example):

```sql
-- Step 1: Create a KMS key in AWS
-- Step 2: Configure the key policy to allow Snowflake's AWS account access
-- Step 3: Contact Snowflake Support to enable Tri-Secret Secure
-- Step 4: Provide the KMS key ARN to Snowflake

-- Verify Tri-Secret Secure is active
-- This is visible in the Snowflake Account tab under Security settings
```

### Cloud-specific KMS integration:

| Cloud Provider | KMS Service | Key Type |
|---|---|---|
| AWS | AWS KMS | CMK (Customer Master Key) |
| Azure | Azure Key Vault | RSA 2048/3072/4096 |
| GCP | Cloud KMS | Symmetric encryption key |

---

## 9. Encryption for Stages

### Internal Stages

Data in internal stages is automatically encrypted using the same AES-256 encryption as table data.

```sql
-- Upload to internal stage (automatically encrypted)
PUT file:///data/customers.csv @my_stage AUTO_COMPRESS=TRUE;

-- The file is encrypted at rest in Snowflake's cloud storage
-- No additional configuration needed
```

### External Stages

For external stages, you must ensure encryption is properly configured on the cloud storage side.

```sql
-- AWS S3 external stage with server-side encryption
CREATE OR REPLACE STAGE my_s3_stage
  URL = 's3://my-bucket/data/'
  STORAGE_INTEGRATION = my_s3_integration
  ENCRYPTION = (TYPE = 'AWS_SSE_S3');

-- AWS S3 with KMS encryption
CREATE OR REPLACE STAGE my_kms_stage
  URL = 's3://my-bucket/secure-data/'
  STORAGE_INTEGRATION = my_s3_integration
  ENCRYPTION = (TYPE = 'AWS_SSE_KMS' KMS_KEY_ID = 'arn:aws:kms:us-east-1:123456789:key/abcd-1234');

-- Azure external stage with encryption
CREATE OR REPLACE STAGE my_azure_stage
  URL = 'azure://myaccount.blob.core.windows.net/mycontainer/data/'
  STORAGE_INTEGRATION = my_azure_integration
  ENCRYPTION = (TYPE = 'AZURE_CSE' MASTER_KEY = 'base64encodedkey...');

-- GCS external stage
CREATE OR REPLACE STAGE my_gcs_stage
  URL = 'gcs://my-bucket/data/'
  STORAGE_INTEGRATION = my_gcs_integration
  ENCRYPTION = (TYPE = 'GCS_SSE_KMS' KMS_KEY_ID = 'projects/my-proj/locations/us/keyRings/ring1/cryptoKeys/key1');
```

### Encryption types for stages:

| Cloud | Encryption Type | Description |
|---|---|---|
| AWS | `AWS_SSE_S3` | Server-side encryption with S3-managed keys |
| AWS | `AWS_SSE_KMS` | Server-side encryption with KMS-managed keys |
| AWS | `AWS_CSE` | Client-side encryption (customer manages keys) |
| Azure | `AZURE_CSE` | Client-side encryption |
| GCS | `GCS_SSE_KMS` | Server-side encryption with Cloud KMS keys |
| Any | `SNOWFLAKE_FULL` | Snowflake-managed encryption (internal stages only) |

---

## 10. Client-Side Encryption for Data Loading

For maximum security, data can be encrypted **before** it reaches Snowflake using client-side encryption.

### AWS S3 Client-Side Encryption:

```sql
-- Create a stage with client-side encryption
CREATE OR REPLACE STAGE encrypted_stage
  URL = 's3://my-bucket/encrypted/'
  CREDENTIALS = (AWS_KEY_ID = '...' AWS_SECRET_KEY = '...')
  ENCRYPTION = (TYPE = 'AWS_CSE' MASTER_KEY = 'base64EncodedMasterKey');

-- Load data -- Snowflake handles decryption transparently
COPY INTO my_table
  FROM @encrypted_stage
  FILE_FORMAT = (TYPE = CSV);
```

### How client-side encryption works:

1. **Encrypt locally:** Data is encrypted on the client using the master key before upload.
2. **Upload encrypted:** Encrypted data is uploaded to cloud storage.
3. **Snowflake decrypts:** During COPY INTO, Snowflake uses the master key (provided in stage definition) to decrypt.
4. **Re-encrypted at rest:** Once loaded, data is re-encrypted using Snowflake's internal encryption.

```
Client ──[encrypt with master key]──> Cloud Storage (encrypted blob)
                                            │
Snowflake COPY INTO ──[decrypt with master key]──> Compute Layer
                                                        │
                                            [re-encrypt with AES-256]──> Snowflake Storage
```

### Best practices for client-side encryption:

- Rotate the client-side master key periodically.
- Store the master key securely (e.g., in a secrets manager, not in code).
- Use client-side encryption when compliance requires data to be encrypted before leaving your environment.

---

## 11. Real-World Scenario: Compliance Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    HIPAA-Compliant Data Pipeline                 │
│                                                                 │
│  Source System                                                  │
│  ├── Data encrypted at rest (source DB encryption)              │
│  │                                                              │
│  ├── Extract via secure API (TLS 1.2)                          │
│  │                                                              │
│  ├── Client-side encryption (AWS_CSE) before upload to S3      │
│  │                                                              │
│  ├── S3 bucket with SSE-KMS encryption                         │
│  │                                                              │
│  ├── Snowflake COPY INTO (decrypts CSE, re-encrypts AES-256)  │
│  │                                                              │
│  ├── Snowflake at-rest encryption (AES-256, key hierarchy)     │
│  │                                                              │
│  ├── Tri-Secret Secure (customer + Snowflake composite key)    │
│  │                                                              │
│  ├── Annual automatic key rotation + periodic rekeying         │
│  │                                                              │
│  └── Column-level security (Dynamic Data Masking) for PHI      │
└─────────────────────────────────────────────────────────────────┘
```

---

## 12. Common Interview Questions & Answers

### Q1: How does Snowflake handle encryption at rest, and what algorithm is used?

**A:** Snowflake encrypts all data at rest using AES-256 encryption. This is always on and cannot be disabled. It uses a hierarchical key model: a root key protects account master keys, which protect table master keys, which protect individual file keys. Each micro-partition has its own unique file key, ensuring fine-grained encryption isolation.

### Q2: Explain Snowflake's encryption key hierarchy.

**A:** The hierarchy has four levels: (1) Root Key -- stored in an HSM, protects everything; (2) Account Master Key -- one per account, encrypts table master keys; (3) Table Master Key -- one per table, encrypts file keys; (4) File Key -- one per micro-partition file, encrypts the actual data. This design enables efficient key rotation (re-wrapping keys without re-encrypting data) and limits blast radius if a key is compromised.

### Q3: What is the difference between key rotation and rekeying?

**A:** Key rotation (available on all editions) generates new master keys and re-wraps existing file keys with the new master keys -- the underlying data files are not re-encrypted. Rekeying (Enterprise Edition+) goes further by generating new file keys and re-encrypting the actual data files. Both happen automatically. Rekeying provides stronger protection but is more resource-intensive.

### Q4: What is Tri-Secret Secure and when would you use it?

**A:** Tri-Secret Secure (Business Critical Edition+) combines a Snowflake-managed key with a customer-managed key (from AWS KMS, Azure Key Vault, or GCP Cloud KMS) to create a composite master key. Neither party alone can access the data. It is used in highly regulated industries (finance, healthcare) where the customer must maintain control over encryption keys and have the ability to revoke access (a "kill switch").

### Q5: How is data encrypted during loading from external stages?

**A:** Data in transit is protected by TLS 1.2. For external stages, Snowflake supports multiple encryption types: server-side encryption (SSE-S3, SSE-KMS for AWS; similar for Azure/GCS) and client-side encryption (AWS_CSE, AZURE_CSE). With client-side encryption, data is encrypted before leaving the customer's environment. After loading, Snowflake re-encrypts the data using its own AES-256 encryption and key hierarchy.

### Q6: Can a customer disable encryption in Snowflake?

**A:** No. Encryption is always on in Snowflake. All data at rest is encrypted with AES-256, all data in transit uses TLS 1.2+, and these cannot be disabled. This is a fundamental architectural decision that ensures security by default.

### Q7: How often does Snowflake rotate encryption keys?

**A:** Snowflake automatically rotates account master keys and table master keys annually (every 365 days). For Enterprise Edition and above, periodic rekeying of data also occurs automatically. Customers can contact Snowflake to request more frequent rotation if required by compliance policies.

### Q8: How does Tri-Secret Secure act as a "kill switch"?

**A:** If a customer disables or deletes their customer-managed key in their cloud KMS, the composite master key can no longer be constructed. Snowflake becomes unable to decrypt any data in the account. This effectively renders all data inaccessible, providing the customer with ultimate control. Restoring the key restores access (if the key was disabled, not deleted).

---

## 13. Tips for Interviews and Practice

- **Encryption is not optional** in Snowflake. Know that it is always on and uses AES-256 at rest and TLS 1.2+ in transit.
- **Understand the key hierarchy deeply.** Be able to draw it and explain why each level exists (isolation, efficient rotation, blast radius control).
- **Distinguish rotation from rekeying.** This is a common interview differentiator. Rotation = re-wrap keys. Rekeying = re-encrypt data.
- **Know the edition requirements:** Key rotation is all editions; rekeying is Enterprise+; Tri-Secret Secure is Business Critical+.
- **Client-side encryption** is the answer to "How do I ensure data is encrypted before it leaves my environment?"
- **Tri-Secret Secure** is the answer to "How do I maintain control over encryption keys?" and "How can I guarantee Snowflake cannot access my data unilaterally?"
- **For compliance discussions:** Be ready to explain how Snowflake encryption meets HIPAA, PCI-DSS, SOC 2, and FedRAMP requirements.
- **Temporary and transient tables** are still encrypted -- they simply have reduced Time Travel and no Fail-safe. Do not confuse reduced durability with reduced security.

---
