# SQL Server Service Broker

[Back to SQL Server Index](./README.md)

---

## Table of Contents

1. [Overview](#overview)
2. [Core Architecture](#core-architecture)
3. [Message Types](#message-types)
4. [Contracts](#contracts)
5. [Queues](#queues)
6. [Services](#services)
7. [Conversations and Dialogs](#conversations-and-dialogs)
8. [Dialog Security](#dialog-security)
9. [Activation Stored Procedures](#activation-stored-procedures)
10. [Poison Message Handling](#poison-message-handling)
11. [Use Cases for Asynchronous Processing](#use-cases-for-asynchronous-processing)
12. [Service Broker vs External Message Queues](#service-broker-vs-external-message-queues)
13. [Performance Considerations](#performance-considerations)
14. [Troubleshooting](#troubleshooting)
15. [Common Interview Questions](#common-interview-questions)
16. [Tips for the Interview](#tips-for-the-interview)

---

## Overview

**SQL Server Service Broker** is a native message-based communication framework built into the SQL Server Database Engine. It provides reliable, asynchronous, transactional message delivery between services — either within the same database, across databases on the same instance, or across instances.

### Key Characteristics

- **Transactional:** Sending and receiving messages participates in the current transaction. If the transaction rolls back, the message send/receive is rolled back too.
- **Ordered delivery:** Messages within a conversation are guaranteed to be received in the exact order they were sent.
- **Exactly-once delivery:** Each message is delivered exactly once within a conversation.
- **Asynchronous:** The sender does not wait for the receiver to process the message.
- **Built-in:** No external middleware required; it ships with every edition of SQL Server (including Express).
- **Persistent:** Messages are stored in internal tables (queues) within the database, so they survive server restarts.

---

## Core Architecture

Service Broker uses a layered architecture:

```
+-------------------+     +-------------------+
|  Initiator Side   |     |   Target Side     |
|                   |     |                   |
|  Application      |     |  Application      |
|       |           |     |       ^           |
|       v           |     |       |           |
|  BEGIN DIALOG     |     |  RECEIVE          |
|  SEND MESSAGE ----|---->|---- from Queue    |
|                   |     |                   |
|  [Service]        |     |  [Service]        |
|  [Queue]          |     |  [Queue]          |
|  [Contract]       |     |  [Contract]       |
|  [Message Types]  |     |  [Message Types]  |
+-------------------+     +-------------------+
```

### Component Hierarchy

1. **Message Types** define the format/validation of messages
2. **Contracts** define which message types can be sent by which participant (initiator or target)
3. **Queues** are internal tables that store messages
4. **Services** bind a queue to one or more contracts, providing a named endpoint
5. **Conversations (Dialogs)** are the channels through which messages flow between two services

---

## Message Types

A **message type** defines the name and validation for a message payload.

```sql
-- Create message types
CREATE MESSAGE TYPE [//MyApp/RequestMessage]
    VALIDATION = WELL_FORMED_XML;

CREATE MESSAGE TYPE [//MyApp/ResponseMessage]
    VALIDATION = WELL_FORMED_XML;
```

### Validation Options

| Validation | Description |
|-----------|-------------|
| `NONE` | No validation; body is treated as opaque binary (`varbinary(max)`) |
| `EMPTY` | Message body must be NULL (zero-length); used for signal messages |
| `WELL_FORMED_XML` | Body must be well-formed XML but is not validated against a schema |
| `VALID_XML WITH SCHEMA COLLECTION` | Body must validate against the specified XML schema collection |

### Naming Convention

By convention, message type names use a URL-like format (e.g., `//MyCompany/MyApp/OrderRequest`). This is purely a naming convention — no actual HTTP calls are made.

---

## Contracts

A **contract** defines the rules for a conversation: which message types can be sent and by which side (initiator, target, or any).

```sql
CREATE CONTRACT [//MyApp/ProcessingContract] (
    [//MyApp/RequestMessage]   SENT BY INITIATOR,
    [//MyApp/ResponseMessage]  SENT BY TARGET
);
```

### Sent By Options

| Option | Meaning |
|--------|---------|
| `SENT BY INITIATOR` | Only the service that began the dialog can send this message type |
| `SENT BY TARGET` | Only the receiving service can send this message type |
| `SENT BY ANY` | Either side can send this message type |

### Default Contract

SQL Server provides a built-in `[DEFAULT]` contract that allows any well-formed XML message to be sent by either side. It is generally better to define explicit contracts for clarity and enforcement.

---

## Queues

A **queue** is an internal table managed by Service Broker that stores messages waiting to be processed.

```sql
-- Create queues
CREATE QUEUE dbo.InitiatorQueue
    WITH STATUS = ON,
    RETENTION = OFF;

CREATE QUEUE dbo.TargetQueue
    WITH STATUS = ON,
    RETENTION = OFF,
    ACTIVATION (
        STATUS = ON,
        PROCEDURE_NAME = dbo.ProcessTargetMessage,
        MAX_QUEUE_READERS = 5,
        EXECUTE AS SELF
    );
```

### Queue Properties

| Property | Description |
|----------|-------------|
| `STATUS` | ON/OFF — when OFF, messages accumulate but cannot be received |
| `RETENTION` | ON/OFF — when ON, messages are retained in the queue even after being received (useful for debugging; impacts performance) |
| `ACTIVATION` | Configures automatic activation of a stored procedure when messages arrive |
| `POISON_MESSAGE_HANDLING` | STATUS ON/OFF — controls automatic poison message detection (SQL Server 2008+) |

### Querying a Queue

Queues can be queried like tables (read-only):

```sql
-- View messages currently in the queue
SELECT
    conversation_handle,
    message_type_name,
    message_body,
    queuing_order,
    service_name,
    validation
FROM dbo.TargetQueue;

-- Count pending messages
SELECT COUNT(*) FROM dbo.TargetQueue;

-- View queue metadata
SELECT * FROM sys.service_queues WHERE name = 'TargetQueue';
```

---

## Services

A **service** is a named endpoint that binds a queue to one or more contracts. Services are what conversations connect to.

```sql
-- Create services
CREATE SERVICE [//MyApp/InitiatorService]
    ON QUEUE dbo.InitiatorQueue;
    -- Initiator services don't need contracts listed (they initiate, not receive initial messages)

CREATE SERVICE [//MyApp/TargetService]
    ON QUEUE dbo.TargetQueue
    ([//MyApp/ProcessingContract]);
    -- Target services must list the contracts they accept
```

### Important Rules

- A **target service** must list the contracts it is willing to accept in conversations
- An **initiator service** does not need to list contracts (it specifies the contract when beginning the dialog)
- A service is bound to exactly **one queue**, but a queue can serve **multiple services**
- Multiple contracts can be listed on a single service

---

## Conversations and Dialogs

A **conversation** (specifically a **dialog**) is a reliable, ordered, bidirectional communication channel between two services.

### Starting a Conversation

```sql
DECLARE @ConversationHandle UNIQUEIDENTIFIER;

BEGIN DIALOG CONVERSATION @ConversationHandle
    FROM SERVICE [//MyApp/InitiatorService]
    TO SERVICE '//MyApp/TargetService'
    ON CONTRACT [//MyApp/ProcessingContract]
    WITH ENCRYPTION = OFF;
```

### Sending Messages

```sql
SEND ON CONVERSATION @ConversationHandle
    MESSAGE TYPE [//MyApp/RequestMessage]
    (N'<Request><OrderID>12345</OrderID></Request>');
```

### Receiving Messages

```sql
DECLARE @ConversationHandle UNIQUEIDENTIFIER;
DECLARE @MessageType SYSNAME;
DECLARE @MessageBody XML;

WAITFOR (
    RECEIVE TOP(1)
        @ConversationHandle = conversation_handle,
        @MessageType = message_type_name,
        @MessageBody = CAST(message_body AS XML)
    FROM dbo.TargetQueue
), TIMEOUT 5000;  -- Wait up to 5 seconds

IF @MessageType = N'//MyApp/RequestMessage'
BEGIN
    -- Process the message
    -- Send a response
    SEND ON CONVERSATION @ConversationHandle
        MESSAGE TYPE [//MyApp/ResponseMessage]
        (N'<Response><Status>Processed</Status></Response>');
END
ELSE IF @MessageType = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
BEGIN
    END CONVERSATION @ConversationHandle;
END
ELSE IF @MessageType = N'http://schemas.microsoft.com/SQL/ServiceBroker/Error'
BEGIN
    END CONVERSATION @ConversationHandle;
    -- Log the error
END
```

### Ending Conversations

Both sides must end the conversation:

```sql
-- Initiator or Target ends their side
END CONVERSATION @ConversationHandle;

-- End with error
END CONVERSATION @ConversationHandle
    WITH ERROR = 500 DESCRIPTION = 'Processing failed';
```

**Critical:** Always end conversations. Failing to end both sides leads to **conversation endpoint leaks** — metadata accumulates in `sys.conversation_endpoints` and can degrade performance.

### System Message Types

Service Broker sends internal messages you must handle:

| Message Type | When Sent |
|-------------|-----------|
| `http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog` | When the other side calls END CONVERSATION |
| `http://schemas.microsoft.com/SQL/ServiceBroker/Error` | When the other side ends with an error, or a system error occurs |
| `http://schemas.microsoft.com/SQL/ServiceBroker/DialogTimer` | When a conversation timer fires |

---

## Dialog Security

Service Broker provides two levels of security for cross-instance communication:

### Transport Security

Secures the network connection between two SQL Server instances:

```sql
-- Create a transport security endpoint
CREATE ENDPOINT ServiceBrokerEndpoint
    STATE = STARTED
    AS TCP (LISTENER_PORT = 4022)
    FOR SERVICE_BROKER (
        AUTHENTICATION = WINDOWS,  -- Or CERTIFICATE
        ENCRYPTION = REQUIRED
    );
```

### Dialog Security

Secures individual conversations end-to-end using certificates:

```sql
-- On the initiator instance
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'StrongPassword123!';

CREATE CERTIFICATE InitiatorCert
    WITH SUBJECT = 'Initiator Certificate';

-- Exchange certificates between instances
-- (Export initiator cert, import on target; export target cert, import on initiator)

-- Create remote service binding
CREATE REMOTE SERVICE BINDING [//MyApp/TargetBinding]
    TO SERVICE '//MyApp/TargetService'
    WITH USER = TargetProxyUser,
         ANONYMOUS = OFF;
```

### Within Same Instance

For communication within the same database or same instance, dialog security is typically not needed. Set `ENCRYPTION = OFF` on the dialog for simplicity:

```sql
BEGIN DIALOG CONVERSATION @Handle
    FROM SERVICE [//MyApp/InitiatorService]
    TO SERVICE '//MyApp/TargetService'
    ON CONTRACT [//MyApp/ProcessingContract]
    WITH ENCRYPTION = OFF;
```

---

## Activation Stored Procedures

**Activation** is Service Broker's mechanism for automatically launching stored procedures to process messages when they arrive in a queue.

### Internal Activation

SQL Server automatically starts instances of a stored procedure when:
1. Messages arrive in the queue AND no reader is currently processing
2. The number of messages grows faster than current readers can process (up to `MAX_QUEUE_READERS`)

```sql
-- Activation stored procedure pattern
CREATE PROCEDURE dbo.ProcessTargetMessage
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ConversationHandle UNIQUEIDENTIFIER;
    DECLARE @MessageType SYSNAME;
    DECLARE @MessageBody VARBINARY(MAX);

    WHILE (1 = 1)
    BEGIN
        BEGIN TRANSACTION;

        WAITFOR (
            RECEIVE TOP(1)
                @ConversationHandle = conversation_handle,
                @MessageType = message_type_name,
                @MessageBody = message_body
            FROM dbo.TargetQueue
        ), TIMEOUT 5000;

        IF @@ROWCOUNT = 0
        BEGIN
            COMMIT TRANSACTION;
            BREAK;  -- No more messages; exit the loop and let activation restart if needed
        END

        IF @MessageType = N'//MyApp/RequestMessage'
        BEGIN
            -- Process the message
            DECLARE @xml XML = CAST(@MessageBody AS XML);

            -- Do work here...

            -- Send response
            SEND ON CONVERSATION @ConversationHandle
                MESSAGE TYPE [//MyApp/ResponseMessage]
                (N'<Response><Status>OK</Status></Response>');
        END
        ELSE IF @MessageType = N'http://schemas.microsoft.com/SQL/ServiceBroker/EndDialog'
        BEGIN
            END CONVERSATION @ConversationHandle;
        END
        ELSE IF @MessageType = N'http://schemas.microsoft.com/SQL/ServiceBroker/Error'
        BEGIN
            -- Log error details
            END CONVERSATION @ConversationHandle;
        END

        COMMIT TRANSACTION;
    END
END;
GO

-- Configure activation on the queue
ALTER QUEUE dbo.TargetQueue
    WITH ACTIVATION (
        STATUS = ON,
        PROCEDURE_NAME = dbo.ProcessTargetMessage,
        MAX_QUEUE_READERS = 5,
        EXECUTE AS SELF
    );
```

### Key Activation Design Points

1. **Use a WHILE loop with WAITFOR and TIMEOUT** — The procedure should loop, processing messages until the queue is empty, then exit. Service Broker will restart it when new messages arrive.
2. **Process in a transaction** — RECEIVE is transactional. If the transaction rolls back, the message goes back to the queue.
3. **MAX_QUEUE_READERS** — Controls the maximum number of concurrent instances of the activation procedure. Set based on processing capacity.
4. **EXECUTE AS** — The security context the procedure runs under.

### External Activation

For scenarios where processing should happen outside SQL Server (e.g., a .NET application):

- SQL Server sends an **activation event notification** to an external application
- The external application connects and runs RECEIVE
- Requires the **Service Broker External Activator** (separate download) or custom implementation using `SqlDependency` / event notifications

---

## Poison Message Handling

A **poison message** is a message that causes the processing transaction to roll back repeatedly, creating an infinite loop.

### Default Behavior (SQL Server 2008+)

If a transaction that receives a message from a queue rolls back **5 times**, Service Broker automatically:

1. **Disables the queue** (`STATUS = OFF`)
2. Raises a `Broker:Queue Disabled` event notification

This prevents the poison message from consuming resources indefinitely.

### Handling Poison Messages

```sql
-- Check if a queue is disabled
SELECT name, is_receive_enabled
FROM sys.service_queues
WHERE name = 'TargetQueue';

-- Re-enable after investigation
ALTER QUEUE dbo.TargetQueue WITH STATUS = ON;

-- Disable automatic poison message handling (handle it yourself)
ALTER QUEUE dbo.TargetQueue
    WITH POISON_MESSAGE_HANDLING (STATUS = OFF);
```

### Custom Poison Message Handling

When you disable automatic handling, implement your own:

```sql
CREATE PROCEDURE dbo.ProcessWithPoisonHandling
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ConversationHandle UNIQUEIDENTIFIER;
    DECLARE @MessageType SYSNAME;
    DECLARE @MessageBody VARBINARY(MAX);

    WHILE (1 = 1)
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            WAITFOR (
                RECEIVE TOP(1)
                    @ConversationHandle = conversation_handle,
                    @MessageType = message_type_name,
                    @MessageBody = message_body
                FROM dbo.TargetQueue
            ), TIMEOUT 5000;

            IF @@ROWCOUNT = 0
            BEGIN
                COMMIT TRANSACTION;
                BREAK;
            END

            -- Process message...
            -- (processing logic here)

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;

            -- Log to an error table
            BEGIN TRANSACTION;

            INSERT INTO dbo.PoisonMessageLog (
                conversation_handle, message_type, message_body, error_message, log_date
            )
            VALUES (
                @ConversationHandle, @MessageType, @MessageBody, ERROR_MESSAGE(), GETDATE()
            );

            -- End the conversation with an error to remove the poison message
            END CONVERSATION @ConversationHandle
                WITH ERROR = 999 DESCRIPTION = N'Poison message detected';

            COMMIT TRANSACTION;
        END CATCH
    END
END;
```

---

## Use Cases for Asynchronous Processing

### 1. Audit Logging

Decouple audit trail writes from the main transaction to reduce latency:

```sql
-- In the main procedure, after the business operation:
SEND ON CONVERSATION @AuditDialogHandle
    MESSAGE TYPE [//MyApp/AuditMessage]
    (N'<Audit><Action>OrderCreated</Action><UserID>42</UserID><Timestamp>'
     + CONVERT(VARCHAR(30), GETDATE(), 126) + '</Timestamp></Audit>');
-- Main transaction commits fast; audit is written asynchronously
```

### 2. Email / Notification Dispatch

Send emails asynchronously without blocking the user transaction:

```sql
-- Queue an email request
SEND ON CONVERSATION @NotificationHandle
    MESSAGE TYPE [//MyApp/EmailRequest]
    (N'<Email><To>user@example.com</To><Subject>Order Confirmed</Subject></Email>');
-- Activation procedure calls sp_send_dbmail or external API
```

### 3. Cross-Database Data Synchronization

Reliably propagate changes from one database to another:

```sql
-- In DB_Source, after INSERT:
SEND ON CONVERSATION @SyncHandle
    MESSAGE TYPE [//MyApp/DataSync]
    (@ChangedDataXml);
-- Target database processes and applies changes
```

### 4. Long-Running Process Offloading

- Report generation
- Complex calculations
- Data aggregation and ETL steps
- File processing triggers

### 5. Reliable Work Queuing (Job Queue Pattern)

Use Service Broker as a database-native job queue with guaranteed delivery and transactional safety — no external queue infrastructure required.

---

## Service Broker vs External Message Queues

| Aspect | Service Broker | External Queues (RabbitMQ, Kafka, Azure Service Bus) |
|--------|---------------|------------------------------------------------------|
| **Installation** | Built into SQL Server; no additional infrastructure | Requires separate infrastructure |
| **Transactional integration** | Fully transactional with SQL Server DML (same ACID transaction) | Requires distributed transaction or outbox pattern |
| **Message ordering** | Guaranteed within a conversation | Varies (partition-level ordering in Kafka, FIFO queues in SQS/ASB) |
| **Throughput** | Moderate (thousands/sec); can become a bottleneck at extreme scale | High (millions/sec for Kafka) |
| **Cross-platform** | SQL Server only | Language/platform agnostic |
| **Monitoring** | Limited built-in tooling; relies on DMVs and catalog views | Rich dedicated dashboards and monitoring |
| **Ecosystem** | SQL Server specific | Large ecosystems, connectors, client libraries |
| **Learning curve** | Significant; many concepts, debugging is harder | Varies; generally better documentation and community |
| **Reliability** | Backed by SQL Server database — messages survive restarts, failover | Depends on broker configuration (durable queues, replication) |
| **Use case fit** | Intra-database or intra-SQL Server async processing | Enterprise-wide event streaming, microservices, polyglot systems |

### When to Choose Service Broker

- You need **transactional message delivery** tightly coupled with database operations
- Communication is **within SQL Server** (same instance or between instances)
- You want **zero additional infrastructure**
- Throughput requirements are moderate
- The team is SQL Server-focused

### When to Choose External Queues

- **Cross-platform** communication (different languages, services, cloud)
- **High throughput** requirements (hundreds of thousands or millions of messages/sec)
- You need a **pub/sub** model (Service Broker is point-to-point dialog only)
- **Rich ecosystem** with monitoring, dead-letter queues, delayed delivery, etc.
- Microservices architecture

---

## Performance Considerations

### Message Size

- Keep messages **small** — ideally under a few KB
- Large XML messages cause excessive parsing overhead
- For large payloads, store the data in a table and send only a reference (ID) in the message

### Conversation Lifetime

- **Reuse conversations** when sending many messages to the same service (reduces overhead of conversation setup)
- **Do not create a new conversation per message** — each conversation has setup/teardown cost and metadata in `sys.conversation_endpoints`
- For fire-and-forget patterns, use **conversation groups** and conversation recycling

### Conversation Endpoint Cleanup

```sql
-- Find leaked conversation endpoints
SELECT
    state_desc,
    COUNT(*) AS endpoint_count
FROM sys.conversation_endpoints
GROUP BY state_desc;

-- Clean up stuck conversations (use with caution)
-- End conversations in DISCONNECTED_OUTBOUND or ERROR state
DECLARE @handle UNIQUEIDENTIFIER;
DECLARE endpoint_cursor CURSOR FOR
    SELECT conversation_handle
    FROM sys.conversation_endpoints
    WHERE state_desc IN ('DISCONNECTED_OUTBOUND', 'ERROR');

OPEN endpoint_cursor;
FETCH NEXT FROM endpoint_cursor INTO @handle;

WHILE @@FETCH_STATUS = 0
BEGIN
    END CONVERSATION @handle WITH CLEANUP;
    FETCH NEXT FROM endpoint_cursor INTO @handle;
END

CLOSE endpoint_cursor;
DEALLOCATE endpoint_cursor;
```

### Queue Performance

- **Multiple queue readers** (`MAX_QUEUE_READERS`) process messages in parallel, but watch for lock contention on the queue's internal table
- **RECEIVE with TOP(n)** — batch receive multiple messages in one call to reduce overhead
- Ensure the **activation procedure** is efficient; a slow procedure backs up the queue
- Monitor queue depth: a continuously growing queue indicates processing cannot keep up

### Service Broker and tempdb

Service Broker uses **tempdb for internal operations** (conversation tracking, message forwarding). Heavy Service Broker usage can increase tempdb contention.

---

## Troubleshooting

### Is Service Broker Enabled?

```sql
-- Check if Service Broker is enabled for the database
SELECT name, is_broker_enabled, service_broker_guid
FROM sys.databases
WHERE name = 'MyDatabase';

-- Enable Service Broker (requires exclusive access)
ALTER DATABASE MyDatabase SET ENABLE_BROKER;

-- If database was restored or attached, you may need:
ALTER DATABASE MyDatabase SET NEW_BROKER;  -- Generates new broker GUID
-- OR
ALTER DATABASE MyDatabase SET ENABLE_BROKER WITH ROLLBACK IMMEDIATE;
```

### Messages Not Being Delivered

**Checklist:**

1. Is the queue enabled? `SELECT is_receive_enabled FROM sys.service_queues WHERE name = 'TargetQueue';`
2. Are there messages in the transmission queue? `SELECT * FROM sys.transmission_queue;` (the `transmission_status` column shows errors)
3. Is activation enabled? Check `sys.service_queues` for `is_activation_enabled`
4. Is the conversation in a valid state? Check `sys.conversation_endpoints`
5. For cross-database: are routes configured?
6. For cross-instance: is the Service Broker endpoint created and started?

### Key Diagnostic Views

```sql
-- Messages waiting to be transmitted (cross-database/instance)
SELECT
    conversation_handle,
    to_service_name,
    transmission_status,  -- Error message if delivery failed
    enqueue_time,
    message_body
FROM sys.transmission_queue;

-- Conversation endpoints (all active conversations)
SELECT
    conversation_handle,
    state_desc,
    far_service,
    lifetime,
    is_initiator
FROM sys.conversation_endpoints;

-- Queue monitors (activation status)
SELECT
    q.name AS queue_name,
    qm.state,
    qm.tasks_waiting,
    qm.last_activated_time,
    qm.last_empty_rowset_time
FROM sys.dm_broker_queue_monitors qm
JOIN sys.service_queues q ON qm.queue_id = q.object_id;

-- Activated tasks currently running
SELECT * FROM sys.dm_broker_activated_tasks;

-- Service Broker endpoint connections (cross-instance)
SELECT * FROM sys.dm_broker_connections;
```

### Common Errors and Resolutions

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| Messages stuck in `sys.transmission_queue` | Route misconfiguration or endpoint not started | Check routes (`sys.routes`), check endpoint (`sys.service_broker_endpoints`) |
| Queue gets disabled automatically | Poison message (5 rollbacks) | Investigate the failing message; fix the processing procedure; re-enable queue |
| `transmission_status` shows "Classification failed" | Missing or incorrect route | Create or fix the route for the target service |
| Dialog security errors | Certificate not exchanged properly | Verify certificates, remote service bindings, and master keys |
| Messages delivered but not processed | Activation procedure not configured or failing silently | Check activation configuration; test the procedure manually |
| Conversation endpoints accumulating | Conversations not being properly ended on both sides | Ensure both initiator and target call END CONVERSATION |

### Routing for Cross-Database / Cross-Instance

```sql
-- Route for same-instance, different database
CREATE ROUTE [TargetRoute]
    WITH SERVICE_NAME = '//MyApp/TargetService',
         BROKER_INSTANCE = 'target-database-broker-guid',
         ADDRESS = 'LOCAL';

-- Route for remote instance
CREATE ROUTE [RemoteTargetRoute]
    WITH SERVICE_NAME = '//MyApp/TargetService',
         BROKER_INSTANCE = 'remote-broker-guid',
         ADDRESS = 'TCP://remote-server:4022';

-- View existing routes
SELECT * FROM sys.routes;
```

---

## Common Interview Questions

### Q1: What is SQL Server Service Broker and when would you use it?

**A:** Service Broker is SQL Server's built-in, transactional, asynchronous messaging framework. It provides guaranteed, ordered, exactly-once message delivery between services. I would use it for: decoupling long-running processes from user-facing transactions (e.g., async audit logging, email dispatch), reliable work queuing within SQL Server, and cross-database data synchronization. Its key advantage over external queues is full transactional integration — sending a message and modifying data happen in the same ACID transaction.

### Q2: How does Service Broker guarantee message ordering and exactly-once delivery?

**A:** **Ordering** is guaranteed within a **conversation** (dialog). Messages sent on a conversation are assigned sequence numbers, and Service Broker delivers them in sequence order on the target queue, even if they arrive out of order at the network level. **Exactly-once** delivery is achieved through conversation state tracking and sequence numbers — duplicate messages are detected and discarded. If a RECEIVE is rolled back, the message returns to the queue and will be received again (but this is retry, not duplication).

### Q3: What is a poison message in Service Broker and how is it handled?

**A:** A poison message is one that causes the receiving transaction to roll back repeatedly. After **5 consecutive rollbacks** involving the same message, Service Broker automatically disables the queue and raises a `Broker:Queue Disabled` event. To handle this proactively: implement TRY/CATCH in your activation procedure, log failed messages to an error table, end the problem conversation with an error code, and continue processing. You can also disable automatic poison message handling and implement your own retry/dead-letter logic.

### Q4: Explain the relationship between message types, contracts, services, and queues.

**A:** **Message types** define what a message looks like (name + validation). **Contracts** define which message types are allowed in a conversation and who can send them (initiator, target, or any). **Queues** are internal tables where messages are physically stored. **Services** are named endpoints that bind a queue to contracts — the target service declares which contracts it accepts. When you BEGIN DIALOG, you specify the initiator service, target service, and contract. Messages sent on that dialog must conform to the contract's rules.

### Q5: How do activation stored procedures work?

**A:** When messages arrive in a queue and no reader is currently processing them, Service Broker automatically launches the activation stored procedure. It monitors the queue — if messages accumulate faster than the current readers process them, it launches additional instances up to `MAX_QUEUE_READERS`. When the queue is empty and the procedure exits (after WAITFOR TIMEOUT), the activated task shuts down. The procedure should be written with a WHILE loop that receives and processes messages until the queue is empty, then exits.

### Q6: What happens to Service Broker messages if SQL Server crashes?

**A:** Messages in queues are **fully durable** — they are stored in internal database tables and are subject to the same transaction log and recovery mechanisms as any other data. If a message was sent within a committed transaction, it will be in the queue after crash recovery. If the send was in an uncommitted transaction, it will be rolled back. This durability is a major advantage over in-memory queues.

### Q7: How do you troubleshoot messages not being delivered?

**A:** My troubleshooting sequence: (1) Check `sys.transmission_queue` — if messages are stuck here, the `transmission_status` column shows the error. (2) Verify Service Broker is enabled on the database (`is_broker_enabled` in `sys.databases`). (3) Check the queue is enabled (`is_receive_enabled` in `sys.service_queues`). (4) Verify routes in `sys.routes`. (5) For cross-instance, check the Service Broker endpoint is started and network connectivity. (6) Check `sys.conversation_endpoints` for conversation state. (7) Use `sys.dm_broker_queue_monitors` to verify activation is working.

### Q8: Compare Service Broker with using an external message queue like RabbitMQ or Kafka.

**A:** Service Broker's strengths: full ACID transactional integration with SQL Server (no two-phase commit or outbox pattern needed), zero additional infrastructure, guaranteed ordering within conversations. Its weaknesses: moderate throughput (not suitable for millions of messages/sec), SQL Server-only ecosystem, limited monitoring tools, point-to-point only (no pub/sub). External queues like Kafka offer massive throughput, cross-platform support, pub/sub, rich monitoring, and large communities — but require separate infrastructure and cannot participate directly in a SQL Server transaction. Choose Service Broker for SQL Server-centric async processing; choose external queues for enterprise-wide event-driven architectures.

### Q9: What is the significance of conversation endpoints and why do they need cleanup?

**A:** Every active conversation creates entries in `sys.conversation_endpoints` on both sides. These track conversation state, sequence numbers, and security context. If conversations are not properly ended (both sides must call END CONVERSATION), endpoints accumulate indefinitely. Thousands of orphaned endpoints consume memory and slow down internal lookups. To clean up, identify endpoints in states like `DISCONNECTED_OUTBOUND` or `ERROR` and end them with `END CONVERSATION ... WITH CLEANUP`. Prevention: always handle `EndDialog` and `Error` system message types in your activation procedures and always end your side of the conversation.

### Q10: Can Service Broker be used across Availability Group replicas?

**A:** Yes, but with caveats. Service Broker conversations are stored in the database and fail over with the AG. However, for **cross-instance** Service Broker communication, the routing configuration must account for the AG listener. You configure routes pointing to the AG listener name/IP. After failover, the new primary resumes Service Broker processing. **Within the same database**, conversations work seamlessly after failover. One challenge: if the database was restored (which happens during AG setup), you may need `ALTER DATABASE SET NEW_BROKER` or `ENABLE_BROKER` to ensure the broker GUID is correct on all replicas.

---

## Tips for the Interview

1. **Service Broker is niche but impressive.** Many SQL Server professionals have never used it. If you can speak about it fluently with real examples, it differentiates you significantly at the senior level.

2. **Lead with the "transactional" advantage.** The number one differentiator is that SEND participates in the current transaction. With external queues, you need outbox patterns or risk message loss/duplication. This is the key architectural reason to choose Service Broker.

3. **Know the anti-patterns.** Creating a new conversation per message, not ending conversations, not handling system messages (EndDialog/Error), and sending large payloads as message bodies. Mentioning what NOT to do shows real-world experience.

4. **Be honest about limitations.** Service Broker has a steep learning curve, limited tooling, and debugging can be painful. Acknowledging this shows maturity and real experience, not just theoretical knowledge.

5. **Have a concrete use case ready.** "We used Service Broker to decouple audit logging from our OLTP transactions, reducing commit latency by 40%" is much more compelling than "it does async messaging."

6. **Know the troubleshooting flow.** If asked "messages aren't being delivered, what do you check?" — walk through: `sys.transmission_queue`, broker enabled, queue enabled, routes, endpoints, activation status. This systematic approach impresses interviewers.

7. **Understand why it fell out of favor.** Service Broker was more popular in the 2008-2012 era. With the rise of cloud, microservices, and dedicated message brokers (Kafka, RabbitMQ, Azure Service Bus), it is used less frequently. Being able to articulate when it is still the right choice (SQL Server-centric workloads, transactional safety, no external dependencies) shows strategic thinking.

8. **Connect it to the bigger picture.** Service Broker relates to other SQL Server concepts: it uses the transaction log (WAL), stores messages in internal tables (storage engine), and can impact tempdb. Drawing these connections shows a holistic understanding of SQL Server internals.