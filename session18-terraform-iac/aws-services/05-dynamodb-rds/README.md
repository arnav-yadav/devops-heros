# DynamoDB & RDS — Database Services

AWS splits managed databases into two broad families: **DynamoDB** (NoSQL,
serverless, key-value) and **RDS** (managed relational engines). They solve
different problems, and choosing by habit rather than access pattern is the usual
mistake.

---

# DynamoDB

## NoSQL

A fully managed key-value and document database. There is no server, no version
to patch, and no connection pool — you call an HTTP API authenticated by IAM.

It gives single-digit millisecond latency at effectively any scale, but only if
you query the way it expects. DynamoDB is **not** a relational database with a
different syntax: there are no joins, and ad-hoc queries are not possible.

| | DynamoDB (NoSQL) | RDS (SQL) |
|---|---|---|
| Schema | per-item, flexible | fixed, enforced |
| Joins | none | yes |
| Scaling | horizontal, automatic | vertical, plus read replicas |
| Query flexibility | only by key | any SQL |
| Design driven by | access patterns | data normalisation |

## Tables, items, attributes

```
Table: Orders
  Item: { "CustomerId": "C-1001",      <- partition key
          "OrderId":    "2026-03-14#1", <- sort key
          "Total":      149.99,
          "Items":      [{"sku":"A1","qty":2}] }
```

- **Table** — a collection of items. No fixed schema beyond the key.
- **Item** — one row, max **400 KB**. Larger payloads go in S3 with a pointer.
- **Attribute** — one field. Items in the same table need not share attributes.

## Partition key

The **partition key** (hash key) determines which physical partition stores the
item. DynamoDB hashes it and distributes data across partitions.

Choosing it well is the single most important design decision:

- High cardinality and even access. `CustomerId` is usually good.
- A **hot partition** — say `Status` with values `active`/`inactive` — throttles
  the whole table no matter how much capacity you provision.
- If you only have a partition key, it must be unique per item.

## Sort key

The optional second half of a composite primary key. Items sharing a partition
key are stored together, **sorted** by the sort key, which enables range queries:

```
Query: CustomerId = "C-1001" AND OrderId BETWEEN "2026-01" AND "2026-03"
```

This is why composite keys often encode a timestamp or a type prefix
(`ORDER#2026-03-14`) — it turns "get everything for this customer in this period"
into one efficient read.

**Secondary indexes** add more access patterns:

| | LSI | GSI |
|---|---|---|
| Partition key | same as table | any attribute |
| Created | only at table creation | any time |
| Consistency | strong available | eventual only |

## Capacity and features

- **On-demand** — pay per request, no planning. Best default.
- **Provisioned** — cheaper at steady, predictable load; supports autoscaling.
- **TTL** — automatic expiry of items by timestamp attribute, free.
- **Streams** — a change log that can trigger Lambda.
- **DAX** — in-memory cache, microsecond reads.
- **Global tables** — multi-region active-active replication.
- **PITR** — point-in-time restore to any second in the last 35 days.

## DynamoDB use cases

- Session stores and user profiles
- Shopping carts
- IoT and telemetry ingestion
- Leaderboards and gaming state
- Any workload with known access patterns and extreme scale

Avoid it when you need ad-hoc reporting, joins across entities, or transactions
spanning many tables — that is RDS territory.

---

# RDS — Relational Database Service

## Relational database

Managed relational databases. AWS handles provisioning, patching, backups,
replication and failover; you keep the schema, the queries and the indexes.

RDS is not "a database in the cloud" so much as "a database you no longer have to
operate". You still cannot SSH to the host.

## Supported engines

| Engine | Notes |
|---|---|
| PostgreSQL | the usual default for new work |
| MySQL | widest ecosystem compatibility |
| MariaDB | MySQL fork |
| Oracle | licence: bring your own, or included |
| SQL Server | several editions |
| **Aurora** (MySQL/PostgreSQL compatible) | AWS-built; separates compute from a distributed storage layer, up to 5x MySQL throughput, 15 read replicas, auto-scaling storage, optional Serverless v2 |

## DB instances

An instance = engine + instance class + storage.

- **Instance class** — same families as EC2 (`db.t4g.micro`, `db.r6g.xlarge`).
  Memory matters more than CPU for most databases.
- **Storage** — `gp3` general purpose, `io1/io2` for high IOPS, with autoscaling
  available so you do not have to pre-size.
- **Parameter groups** hold engine settings (the equivalent of `postgresql.conf`);
  **option groups** hold engine features.

Scaling is **vertical** — change the instance class, which takes a restart (or a
failover on Multi-AZ). You cannot shard an RDS instance by configuration.

## Security

1. Put it in **private subnets**, inside a DB subnet group spanning at least two AZs.
2. Security group allowing only the application tier's security group on the DB port.
3. `publicly_accessible = false`. Always.
4. **Encryption at rest** with KMS — can only be enabled at creation; converting
   later means a snapshot-and-restore.
5. **TLS in transit**, enforced with `rds.force_ssl`.
6. **IAM database authentication** for token-based logins instead of passwords.
7. Credentials in **Secrets Manager**, with automatic rotation.

## Backups

| | Automated backups | Manual snapshots |
|---|---|---|
| Schedule | daily + transaction logs | on demand |
| Retention | 0–35 days | until deleted |
| Restore granularity | **any second** in the window (PITR) | that snapshot |
| Deleted with the instance | yes | no |

Retention of `0` disables backups entirely — never do this in production. A
restore always creates a **new instance**; it does not restore in place.

## Multi-AZ

A **synchronous standby** in a second Availability Zone.

- Automatic failover in roughly 60–120 seconds; the endpoint DNS is repointed, so
  applications reconnect rather than reconfigure.
- The standby serves **no traffic** — Multi-AZ is for availability, not
  performance.
- Backups are taken from the standby, removing the I/O hit from the primary.
- Multi-AZ *DB cluster* deployments add two readable standbys.

## Read replicas

**Asynchronous** copies that serve read traffic.

- Up to 5 (15 for Aurora); can be cross-region.
- **Eventually consistent** — replica lag is real, so read-after-write against a
  replica may return stale data.
- Can be promoted to a standalone primary (a manual action, useful for migrations
  or regional DR).

| | Multi-AZ | Read replica |
|---|---|---|
| Replication | synchronous | asynchronous |
| Purpose | availability | read scaling |
| Serves reads | no | yes |
| Failover | automatic | manual promotion |
| Same region | yes | optional |

They are complementary: Multi-AZ for resilience, read replicas for load.

## RDS use cases

- Transactional application backends needing ACID guarantees
- Anything with an existing relational schema and SQL queries
- Reporting and analytics over normalised data
- Lift-and-shift of on-premises databases
- Aurora Serverless v2 for spiky or unpredictable workloads

---

## Choosing between them

| Requirement | Pick |
|---|---|
| Joins, ad-hoc SQL, reporting | RDS |
| Strict schema and constraints | RDS |
| Known access patterns, extreme scale | DynamoDB |
| Single-digit ms at any volume | DynamoDB |
| Serverless, no capacity planning | DynamoDB (or Aurora Serverless v2) |
| Multi-region active-active | DynamoDB global tables |
| Existing SQL application | RDS |

The honest rule of thumb: if you cannot list your access patterns up front,
you want RDS.
