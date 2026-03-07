# Encryption (TDE, Always Encrypted, Column-Level)

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [SQL Server Encryption Hierarchy](#sql-server-encryption-hierarchy)
2. [Transparent Data Encryption (TDE)](#transparent-data-encryption-tde)
3. [TDE Operational Considerations](#tde-operational-considerations)
4. [Always Encrypted](#always-encrypted)
5. [Always Encrypted with Secure Enclaves](#always-encrypted-with-secure-enclaves)
6. [Column-Level Encryption (ENCRYPTBYKEY)](#column-level-encryption-encryptbykey)
7. [Cell-Level Encryption](#cell-level-encryption)
8. [Backup Encryption](#backup-encryption)
9. [SSL/TLS for Connections](#ssltls-for-connections)
10. [Common Interview Questions](#common-interview-questions)
11. [Tips](#tips)

---

## SQL Server Encryption Hierarchy

SQL Server uses a layered encryption hierarchy where each key is protected by the key above it.

```
Windows OS Level
  |
  +-- DPAPI (Data Protection API)
        |
        +-- Service Master Key (SMK)
              |  - One per instance
              |  - Created automatically at installation
              |  - Stored encrypted by DPAPI
              |
              +-- Database Master Key (DMK)
                    |  - One per database (optional, created manually)
                    |  - Stored encrypted by SMK
                    |
                    +-- Certificates / Asymmetric Keys
                          |
                          +-- Symmetric Keys
                          |     |
                          |     +-- Data (column-level encryption)
                          |
                          +-- Database Encryption Key (DEK)
                                |
                                +-- Data Files, Log Files, tempdb (TDE)
```

### Key Concepts

- **Service Master Key (SMK):** The root of the encryption hierarchy. Created automatically when SQL Server is installed. Protected by DPAPI. If this is lost or corrupted, all downstream encryption is affected. Back it up immediately after installation.
- **Database Master Key (DMK):** Created per database as needed. Protected by the SMK (and optionally by a password). Required before you can create certificates or asymmetric keys in a database.
- **Certificates:** Contain a public/private key pair. Used to protect symmetric keys, sign modules, and serve as the TDE protector.
- **Symmetric Keys:** Used for actual data encryption (column-level). Symmetric encryption is faster than asymmetric.

```sql
-- Back up the Service Master Key (do this immediately!)
BACKUP SERVICE MASTER KEY
TO FILE = 'D:\SecureBackups\SMK.key'
ENCRYPTION BY PASSWORD = 'SMK_Backup_P@ss!';

-- Create a Database Master Key
USE [YourDatabase];
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'DMK_P@ss!';

-- Back up the Database Master Key
BACKUP MASTER KEY
TO FILE = 'D:\SecureBackups\YourDB_DMK.key'
ENCRYPTION BY PASSWORD = 'DMK_Backup_P@ss!';
```

---

## Transparent Data Encryption (TDE)

TDE encrypts the **data at rest** -- the physical database files (.mdf, .ndf, .ldf) on disk. It provides protection against physical theft of drives or backup media. TDE is transparent to the application: no code changes are needed.

### How TDE Works

1. A **Database Encryption Key (DEK)** is created inside the user database.
2. The DEK is protected by a **certificate** (or asymmetric key) stored in the `master` database.
3. SQL Server encrypts and decrypts data pages in real-time as they are written to and read from disk.
4. The encryption uses AES-256 (default) or Triple DES.

### Enabling TDE

```sql
-- Step 1: Create a Database Master Key in master
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'M@sterKey_P@ss!';

-- Step 2: Create a certificate in master
CREATE CERTIFICATE TDE_Certificate
WITH SUBJECT = 'TDE Certificate for Production',
EXPIRY_DATE = '2030-12-31';

-- Step 3: Back up the certificate and private key IMMEDIATELY
BACKUP CERTIFICATE TDE_Certificate
TO FILE = 'D:\SecureBackups\TDE_Certificate.cer'
WITH PRIVATE KEY (
    FILE = 'D:\SecureBackups\TDE_Certificate_Key.pvk',
    ENCRYPTION BY PASSWORD = 'Cert_Backup_P@ss!'
);

-- Step 4: Create the DEK in the user database
USE [YourDatabase];
CREATE DATABASE ENCRYPTION KEY
WITH ALGORITHM = AES_256
ENCRYPTION BY SERVER CERTIFICATE TDE_Certificate;

-- Step 5: Enable TDE
ALTER DATABASE [YourDatabase] SET ENCRYPTION ON;
```

### Monitoring TDE Status

```sql
-- Check TDE status for all databases
SELECT
    db.name,
    dek.encryption_state,
    CASE dek.encryption_state
        WHEN 0 THEN 'No DEK'
        WHEN 1 THEN 'Unencrypted'
        WHEN 2 THEN 'Encryption in progress'
        WHEN 3 THEN 'Encrypted'
        WHEN 4 THEN 'Key change in progress'
        WHEN 5 THEN 'Decryption in progress'
        WHEN 6 THEN 'Protection change in progress'
    END AS encryption_state_desc,
    dek.encryption_scan_state_desc,
    dek.percent_complete,
    dek.key_algorithm,
    dek.key_length
FROM sys.dm_database_encryption_keys dek
JOIN sys.databases db ON dek.database_id = db.database_id;
```

---

## TDE Operational Considerations

### TDE and tempdb

When TDE is enabled on **any** database on the instance, `tempdb` is automatically encrypted. This impacts all databases on the instance, even non-TDE ones, because their spill operations and temp tables in tempdb are now encrypted. There is a measurable (typically small) CPU overhead.

```sql
-- Verify tempdb encryption
SELECT db_name(database_id), encryption_state
FROM sys.dm_database_encryption_keys
WHERE database_id = 2;  -- tempdb
```

### TDE and Backup Encryption

TDE-encrypted database backups are also encrypted. You **must** have the certificate (with its private key) to restore the backup on a different server.

```sql
-- On the target server, restore the certificate first
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'Target_M@sterKey!';

CREATE CERTIFICATE TDE_Certificate
FROM FILE = 'D:\SecureBackups\TDE_Certificate.cer'
WITH PRIVATE KEY (
    FILE = 'D:\SecureBackups\TDE_Certificate_Key.pvk',
    DECRYPTION BY PASSWORD = 'Cert_Backup_P@ss!'
);

-- Now you can restore the TDE-encrypted backup
RESTORE DATABASE [YourDatabase]
FROM DISK = 'D:\Backups\YourDatabase.bak'
WITH MOVE 'YourDatabase_Data' TO 'D:\Data\YourDatabase.mdf',
     MOVE 'YourDatabase_Log' TO 'D:\Logs\YourDatabase.ldf';
```

**Critical:** If you lose the certificate, you cannot restore the backup. Period. There is no recovery mechanism. Back up the certificate and store it securely (separate from the backup media).

### TDE Performance Impact

- **CPU overhead:** Typically 2-5% for most workloads. The encryption/decryption happens at the buffer pool level (I/O layer).
- **No impact on queries:** TDE is invisible to the query optimizer. Indexes, query plans, and execution are unaffected.
- **Backup compression still works** with TDE, but compressed+encrypted backups are slightly larger than compressed-only backups because encrypted data compresses less efficiently.
- **Initial encryption scan:** When you first enable TDE, SQL Server performs a background scan to encrypt all existing data. This is I/O intensive and can be monitored via `percent_complete`.

### TDE Limitations

- TDE does **not** protect data in memory. A sysadmin can query the data in plain text.
- TDE does **not** protect data in transit (use SSL/TLS for that).
- TDE does **not** protect against a compromised SQL login -- if someone has SELECT permission, they see plain data.
- TDE encrypts the entire database; you cannot choose specific tables.
- FILESTREAM data is **not** encrypted by TDE.

---

## Always Encrypted

Always Encrypted protects sensitive data so that **even the DBA cannot see it in plain text**. The data is encrypted inside the client application and remains encrypted in SQL Server at rest, in memory, and in transit.

### Architecture

```
Client Application                     SQL Server
+-------------------+                  +-------------------+
| Column Master Key |                  | Encrypted Data    |
| (Windows Cert     |                  | (ciphertext only) |
|  Store, Azure KV) |                  |                   |
|         |         |                  |                   |
| Column Encryption |  -- Encrypted -> |                   |
| Key (CEK)         |     Values       |                   |
| (encrypts data    |  <-- Encrypted --|                   |
|  client-side)     |      Results     |                   |
+-------------------+                  +-------------------+
```

### Key Components

- **Column Master Key (CMK):** The top-level key, stored **outside** SQL Server (Windows Certificate Store, Azure Key Vault, or HSM). SQL Server only stores metadata pointing to it.
- **Column Encryption Key (CEK):** Stored in SQL Server, encrypted by the CMK. The actual encryption key used on column data. The CEK can only be decrypted by the client that has access to the CMK.

### Encryption Types

| Type | Behavior | Supports Equality Comparisons | Supports Range Queries | Security |
|---|---|---|---|---|
| **Deterministic** | Same plaintext always produces same ciphertext | Yes (equality joins, WHERE =, GROUP BY, DISTINCT) | No | Lower (pattern analysis possible) |
| **Randomized** | Same plaintext produces different ciphertext each time | No | No | Higher |

### Setting Up Always Encrypted

```sql
-- Step 1: Create a Column Master Key (metadata in SQL Server)
CREATE COLUMN MASTER KEY [CMK_Auto1]
WITH (
    KEY_STORE_PROVIDER_NAME = 'MSSQL_CERTIFICATE_STORE',
    KEY_PATH = 'CurrentUser/My/A1B2C3D4E5F6...'
);

-- Step 2: Create a Column Encryption Key
CREATE COLUMN ENCRYPTION KEY [CEK_Auto1]
WITH VALUES (
    COLUMN_MASTER_KEY = [CMK_Auto1],
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x01700000016...
);

-- Step 3: Create a table with encrypted columns
CREATE TABLE [dbo].[Patients] (
    PatientID INT IDENTITY(1,1) PRIMARY KEY,
    SSN CHAR(11) COLLATE Latin1_General_BIN2
        ENCRYPTED WITH (
            COLUMN_ENCRYPTION_KEY = [CEK_Auto1],
            ENCRYPTION_TYPE = DETERMINISTIC,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        ),
    FirstName NVARCHAR(50),
    LastName NVARCHAR(50),
    DateOfBirth DATE
        ENCRYPTED WITH (
            COLUMN_ENCRYPTION_KEY = [CEK_Auto1],
            ENCRYPTION_TYPE = RANDOMIZED,
            ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256'
        )
);
```

### Client-Side Connection

The application must enable Always Encrypted in the connection string:

```
Server=myserver;Database=mydb;Column Encryption Setting=Enabled;
```

The client driver (ADO.NET, JDBC, ODBC) handles encryption/decryption transparently. The CMK must be accessible to the client application.

### What the DBA Sees

```sql
-- Even a sysadmin sees only ciphertext
SELECT SSN, DateOfBirth FROM dbo.Patients;
-- Result:
-- SSN: 0x016A00000163...  (binary ciphertext)
-- DateOfBirth: 0x016A00000163...  (binary ciphertext)
```

---

## Always Encrypted with Secure Enclaves

Standard Always Encrypted has significant limitations: no range queries, no LIKE, no pattern matching, no sorting on encrypted columns. **Secure enclaves** solve this.

### How It Works

A secure enclave is a protected region of memory within the SQL Server process that is shielded from the OS and DBAs. The CEK is loaded into the enclave (in plain text, but only inside the enclave), enabling server-side computations on encrypted data.

### Capabilities Unlocked by Enclaves

- **Range comparisons** (>, <, >=, <=, BETWEEN) on encrypted columns
- **LIKE** pattern matching on encrypted columns
- **Sorting** (ORDER BY) on encrypted columns
- **In-place encryption** (encrypt existing columns without moving data to the client)
- **Rich query operations** previously impossible with Always Encrypted

### Configuration

```sql
-- Requires SQL Server with enclave support (VBS or SGX)
-- Set enclave type in sp_configure
EXEC sp_configure 'column encryption enclave type', 1;  -- 1 = VBS
RECONFIGURE;

-- Client connection string must include attestation
-- Server=myserver;Database=mydb;
-- Column Encryption Setting=Enabled;
-- Enclave Attestation Url=https://attestation.example.com;
```

### Enclave-Enabled Key Setup

```sql
-- Create an enclave-enabled CMK
CREATE COLUMN MASTER KEY [CMK_Enclave]
WITH (
    KEY_STORE_PROVIDER_NAME = 'MSSQL_CERTIFICATE_STORE',
    KEY_PATH = 'CurrentUser/My/B2C3D4E5F6...',
    ENCLAVE_COMPUTATIONS (SIGNATURE = 0x1A2B3C...)
);

-- CEK created with an enclave-enabled CMK inherits enclave capability
CREATE COLUMN ENCRYPTION KEY [CEK_Enclave]
WITH VALUES (
    COLUMN_MASTER_KEY = [CMK_Enclave],
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x01700000016...
);
```

---

## Column-Level Encryption (ENCRYPTBYKEY)

Unlike TDE (whole database) or Always Encrypted (client-side), column-level encryption is done in T-SQL and gives you granular control over which columns are encrypted and who can decrypt them.

### Setting Up Symmetric Key Encryption

```sql
-- Step 1: Ensure a Database Master Key exists
USE [YourDatabase];
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'DMK_P@ss!';

-- Step 2: Create a certificate to protect the symmetric key
CREATE CERTIFICATE EncryptionCert
WITH SUBJECT = 'Column Encryption Certificate';

-- Step 3: Create a symmetric key
CREATE SYMMETRIC KEY DataEncryptionKey
WITH ALGORITHM = AES_256
ENCRYPTION BY CERTIFICATE EncryptionCert;
```

### Encrypting Data

```sql
-- Open the symmetric key
OPEN SYMMETRIC KEY DataEncryptionKey
DECRYPTION BY CERTIFICATE EncryptionCert;

-- Insert encrypted data
INSERT INTO dbo.Employees (EmployeeID, EncryptedSSN)
VALUES (1, ENCRYPTBYKEY(KEY_GUID('DataEncryptionKey'), '123-45-6789'));

-- Update existing data to encrypt it
UPDATE dbo.Employees
SET EncryptedSSN = ENCRYPTBYKEY(KEY_GUID('DataEncryptionKey'), PlainSSN);

-- Close the key when done
CLOSE SYMMETRIC KEY DataEncryptionKey;
```

### Decrypting Data

```sql
-- Open the symmetric key
OPEN SYMMETRIC KEY DataEncryptionKey
DECRYPTION BY CERTIFICATE EncryptionCert;

-- Decrypt
SELECT
    EmployeeID,
    CONVERT(VARCHAR(11),
        DECRYPTBYKEY(EncryptedSSN)
    ) AS SSN
FROM dbo.Employees;

CLOSE SYMMETRIC KEY DataEncryptionKey;
```

### Key Differences from Always Encrypted

| Aspect | Column-Level (ENCRYPTBYKEY) | Always Encrypted |
|---|---|---|
| Encryption location | SQL Server (T-SQL) | Client application |
| DBA can see plain text | Yes (if they have key access) | No |
| Application changes | Encrypt/decrypt calls in SQL | Connection string change only |
| Performance | Decrypt per-row (can be slow) | Minimal server overhead |
| Data type of encrypted column | VARBINARY | Original type (metadata-only) |
| Query capability | Limited (encrypted = VARBINARY) | Deterministic allows equality |

---

## Cell-Level Encryption

Cell-level encryption is a variant of column-level encryption where different cells in the same column can be encrypted with different keys. This enables row-level encryption policies.

### Example: Different Keys per Department

```sql
-- Create department-specific symmetric keys
CREATE SYMMETRIC KEY HR_Key
WITH ALGORITHM = AES_256
ENCRYPTION BY CERTIFICATE EncryptionCert;

CREATE SYMMETRIC KEY Finance_Key
WITH ALGORITHM = AES_256
ENCRYPTION BY CERTIFICATE EncryptionCert;

-- Encrypt salary differently based on department
OPEN SYMMETRIC KEY HR_Key
DECRYPTION BY CERTIFICATE EncryptionCert;
OPEN SYMMETRIC KEY Finance_Key
DECRYPTION BY CERTIFICATE EncryptionCert;

UPDATE dbo.Employees
SET EncryptedSalary = CASE
    WHEN Department = 'HR'
        THEN ENCRYPTBYKEY(KEY_GUID('HR_Key'), CAST(Salary AS VARCHAR(20)))
    WHEN Department = 'Finance'
        THEN ENCRYPTBYKEY(KEY_GUID('Finance_Key'), CAST(Salary AS VARCHAR(20)))
END;

CLOSE ALL SYMMETRIC KEYS;
```

### Use Case

Cell-level encryption is rare in practice but relevant when regulatory requirements mandate that different teams can only decrypt their own data, even within the same table. More commonly, you would use row-level security combined with column-level encryption.

---

## Backup Encryption

SQL Server 2014+ supports native backup encryption, independent of TDE.

```sql
-- Create a certificate for backup encryption (if not using TDE cert)
USE master;
CREATE CERTIFICATE BackupEncryptionCert
WITH SUBJECT = 'Backup Encryption Certificate';

-- Back up the certificate
BACKUP CERTIFICATE BackupEncryptionCert
TO FILE = 'D:\SecureBackups\BackupEncryptionCert.cer'
WITH PRIVATE KEY (
    FILE = 'D:\SecureBackups\BackupEncryptionCert.pvk',
    ENCRYPTION BY PASSWORD = 'Backup_Cert_P@ss!'
);

-- Encrypted backup
BACKUP DATABASE [YourDatabase]
TO DISK = 'D:\Backups\YourDatabase_Encrypted.bak'
WITH COMPRESSION,
     ENCRYPTION (
         ALGORITHM = AES_256,
         SERVER CERTIFICATE = BackupEncryptionCert
     ),
     STATS = 10;
```

### Backup Encryption vs TDE

| Feature | TDE | Backup Encryption |
|---|---|---|
| Encrypts data files on disk | Yes | No |
| Encrypts backup files | Yes (inherits from TDE) | Yes (explicitly) |
| Non-TDE database backup encrypted | No | Yes |
| Requires Enterprise edition | Yes (pre-2019) | No (Standard 2014+) |
| Performance overhead at runtime | Yes (small) | Only during backup |

**Practical use:** If you only need encrypted backups (e.g., for offsite storage) and do not need data-at-rest encryption on the live database, backup encryption is a lighter-weight alternative to TDE.

---

## SSL/TLS for Connections

TDE and Always Encrypted protect data at rest. **SSL/TLS** protects data **in transit** between the client and SQL Server.

### Enabling TLS

1. **Install a certificate** on the SQL Server host (from a trusted CA or internal PKI).
2. **Configure SQL Server** to use the certificate via SQL Server Configuration Manager.
3. **Optionally force encryption** so all connections must use TLS.

```
SQL Server Configuration Manager:
  -> SQL Server Network Configuration
    -> Protocols for MSSQLSERVER
      -> Properties -> Flags tab:
        Force Encryption = Yes
      -> Certificate tab:
        Select the installed certificate
```

### Client-Side Configuration

```
-- Connection string with encrypted connection
Server=myserver;Database=mydb;Encrypt=True;TrustServerCertificate=False;
```

- **`Encrypt=True`**: Forces the client to request an encrypted connection.
- **`TrustServerCertificate=False`**: The client validates the server certificate against its trusted CA list. Always set to False in production.

### TLS Versions

- SQL Server 2016+ supports TLS 1.2 natively.
- SQL Server 2012/2014 require patches for TLS 1.2 support.
- **Disable TLS 1.0 and 1.1** on the server via Windows registry for compliance.

### Real-World Scenario

For a healthcare application subject to HIPAA:
- TDE encrypts data at rest on the SQL Server.
- SSL/TLS encrypts data in transit between the application and database.
- Always Encrypted protects PHI columns so even DBAs cannot see Social Security Numbers or medical record numbers.
- Backup encryption ensures offsite backup tapes are protected.

---

## Common Interview Questions

### Q1: Explain the SQL Server encryption hierarchy from top to bottom.

**A:** At the top is the Windows DPAPI, which protects the Service Master Key (SMK). The SMK is created automatically per instance and protects Database Master Keys (DMK) in each database. The DMK protects certificates and asymmetric keys. Certificates protect symmetric keys (for column-level encryption) and Database Encryption Keys (for TDE). Each layer protects the layer below it. Losing any key in the chain without a backup means losing access to everything it protects downstream.

### Q2: What is TDE and what does it NOT protect against?

**A:** TDE (Transparent Data Encryption) encrypts the physical database files on disk using a Database Encryption Key (DEK) protected by a certificate in the master database. It protects against physical theft of drives or backup media. However, TDE does NOT protect against: a compromised SQL login (authorized users see plain text), data in memory (data is decrypted when read into the buffer pool), data in transit (use TLS for that), or a malicious DBA. TDE is transparent to the application -- no code changes needed.

### Q3: What happens to tempdb when you enable TDE on any database?

**A:** tempdb is automatically encrypted. Since all databases share tempdb for spill operations, temp tables, sort operations, and hash joins, SQL Server must encrypt it to prevent TDE-protected data from being exposed through tempdb. This means even non-TDE databases on the same instance experience a slight overhead from tempdb encryption. Disabling TDE on all user databases will cause tempdb to become unencrypted after a service restart.

### Q4: Compare TDE and Always Encrypted. When would you choose each?

**A:** TDE encrypts the entire database at rest and is transparent to applications. It protects against physical media theft but not against users with query access. Always Encrypted encrypts specific columns and the encryption/decryption happens client-side, meaning even sysadmins and DBAs cannot see the plain text data. Choose TDE when you need compliance-driven at-rest encryption with zero application changes. Choose Always Encrypted when you need to protect specific sensitive columns (SSN, credit card numbers) from privileged database users. They can be used together for defense in depth.

### Q5: Explain the difference between deterministic and randomized encryption in Always Encrypted.

**A:** Deterministic encryption always produces the same ciphertext for a given plaintext value, which allows equality comparisons (WHERE SSN = @param), joins, GROUP BY, and DISTINCT on encrypted columns. Randomized encryption produces different ciphertext each time, making pattern analysis impossible but disabling all server-side comparisons. Use deterministic for columns you need to search or join on (like SSN lookup). Use randomized for columns that only need to be retrieved and displayed (like date of birth, medical notes).

### Q6: You need to restore a TDE-encrypted backup to a new server. What do you need?

**A:** You need three things on the target server: (1) a Database Master Key in the master database, (2) the same certificate (with its private key) that was used to encrypt the DEK, and (3) the backup file itself. You must first restore the certificate from its backup file using `CREATE CERTIFICATE ... FROM FILE ... WITH PRIVATE KEY`. Without the certificate and its private key, the backup is permanently inaccessible. This is why backing up the TDE certificate and storing it securely (separate from the database backups) is absolutely critical.

### Q7: What is the role of the Column Master Key (CMK) vs the Column Encryption Key (CEK) in Always Encrypted?

**A:** The CMK is the top-level protection key stored outside SQL Server (in Windows Certificate Store, Azure Key Vault, or an HSM). SQL Server only stores metadata about where the CMK lives. The CEK is stored in SQL Server, encrypted by the CMK. The CEK is the key that actually encrypts and decrypts the column data, but it can only be used by a client application that has access to the CMK to decrypt it first. This separation ensures SQL Server never has access to the plain text CEK and therefore can never decrypt the data.

### Q8: How would you implement a comprehensive encryption strategy for a financial services database?

**A:** I would implement defense in depth with multiple layers:
1. **TDE** on the database for at-rest encryption of all data files, meeting baseline compliance requirements.
2. **Always Encrypted** for the most sensitive columns (account numbers, SSNs, PII) with the CMK stored in Azure Key Vault, ensuring even DBAs cannot access this data.
3. **Backup encryption** using a separate certificate, ensuring offsite backups are protected even if stored on third-party media.
4. **TLS 1.2+ enforced** on the SQL Server instance for all connections, protecting data in transit.
5. **Strict key management:** All certificates and keys backed up to a secure, separate location. Key rotation scheduled annually. Access to Azure Key Vault restricted to application service principals only.
6. Regular auditing of key access and encryption status using SQL Server Audit and Extended Events.

---

## Tips

- **Back up your certificates and keys on Day 1.** Store them in a completely separate, secure location from your database backups. Without the certificate, TDE-encrypted backups are unrecoverable.
- **Test certificate restoration on a different server.** Do not assume your certificate backup is valid until you have actually restored a TDE database with it.
- **Always Encrypted is not free.** It shifts processing to the client, changes your query patterns (no server-side range queries without enclaves), and adds complexity to key management. Use it for specific high-sensitivity columns, not everything.
- **Deterministic encryption leaks patterns.** If an encrypted column has low cardinality (e.g., Yes/No), an attacker can potentially infer values through frequency analysis. Randomized encryption eliminates this risk.
- **TDE does not protect you from SQL injection.** An attacker who gains query access through the application sees decrypted data, because TDE operates at the I/O layer. Always Encrypted would protect those columns.
- **Key rotation is a real-world operational task.** Plan for it. TDE certificate rotation requires re-encrypting the DEK. Always Encrypted CMK rotation requires re-encrypting all CEKs. Column-level symmetric key rotation requires re-encrypting all data.
- **In cloud environments, use Azure Key Vault** or equivalent for all key storage. It provides HSM-backed protection, access logging, and automated rotation.
- **Performance testing is essential.** Column-level encryption with `ENCRYPTBYKEY`/`DECRYPTBYKEY` can be costly at scale because it operates row by row. If you need to decrypt millions of rows, consider whether a different approach (Always Encrypted, application-layer encryption) is more appropriate.
- **In interviews, emphasize layered security.** No single encryption feature solves all threats. The best answer combines TDE (at rest), TLS (in transit), and Always Encrypted (from privileged users) based on the specific threat model.
