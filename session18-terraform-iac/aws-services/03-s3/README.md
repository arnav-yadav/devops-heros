# S3 — Simple Storage Service

## What is S3?

S3 is object storage: you store **objects** (files plus metadata) in **buckets**
(flat containers), and retrieve them over HTTP. It is not a filesystem — there is
no appending to an object and no partial rewrite. You replace the whole thing.

It is regional, effectively unlimited, and durable to **99.999999999%** (eleven
nines) by replicating across multiple Availability Zones.

## Buckets

- Bucket names live in one **global** namespace — if someone else has taken
  `test-bucket`, you cannot have it in any account or region.
- 3–63 characters, lowercase, numbers, hyphens. No underscores, no uppercase.
- A bucket is created in one region and the data stays there.
- Default limit of 100 buckets per account (raisable).

This is why Terraform configs usually use `bucket_prefix` instead of `bucket`, or
append a random suffix — a hard-coded name will eventually collide.

```hcl
resource "aws_s3_bucket" "demo" {
  bucket_prefix = "session18-demo-"
}
```

## Objects

| Part | Notes |
|---|---|
| Key | the full name, e.g. `logs/2026/01/app.log` |
| Value | the data, up to 5 TB |
| Metadata | content type, cache control, custom headers |
| Version ID | present when versioning is on |
| ETag | usually the MD5 — a change detector |

**There are no real folders.** The console renders `logs/2026/` as a folder, but
the key is one flat string containing slashes. "Renaming a folder" means copying
every object under that prefix and deleting the originals.

Anything over 100 MB should use **multipart upload** — parallel parts, resumable,
required above 5 GB.

## Storage classes

| Class | Retrieval | Min duration | Use |
|---|---|---|---|
| Standard | instant | — | active data |
| Intelligent-Tiering | instant | — | unpredictable access; auto-moves |
| Standard-IA | instant | 30 days | backups, older logs |
| One Zone-IA | instant | 30 days | re-creatable data; one AZ only |
| Glacier Instant | instant | 90 days | archives needing instant reads |
| Glacier Flexible | minutes–hours | 90 days | true archives |
| Glacier Deep Archive | ~12 hours | 180 days | compliance, 7-year retention |

Infrequent-access classes are cheaper per GB but add a **per-GB retrieval
charge** and a minimum storage duration. Data deleted before the minimum is
billed for the full period anyway, so moving short-lived objects to IA can cost
*more*. Intelligent-Tiering avoids having to predict.

## Versioning

Keeps every version of an object under the same key.

```bash
aws s3api put-bucket-versioning --bucket my-bucket \
  --versioning-configuration Status=Enabled
```

- Protects against accidental overwrite **and** deletion.
- A "delete" writes a zero-byte **delete marker**; the data is still there and
  still billed.
- Once enabled, versioning can only be *suspended*, never switched off.
- Combine with **MFA Delete** for genuinely tamper-resistant buckets.

The cost trap: without a lifecycle rule to expire noncurrent versions, a
frequently-overwritten bucket grows without bound.

## Lifecycle policies

Rules that transition or expire objects automatically by age and prefix.

```json
{
  "Rules": [{
    "ID": "log-retention",
    "Filter": {"Prefix": "logs/"},
    "Status": "Enabled",
    "Transitions": [
      {"Days": 30,  "StorageClass": "STANDARD_IA"},
      {"Days": 90,  "StorageClass": "GLACIER"}
    ],
    "Expiration": {"Days": 365},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 30}
  }]
}
```

Also worth setting everywhere:
`AbortIncompleteMultipartUpload` — failed uploads leave invisible parts that are
billed forever otherwise.

## Encryption

**At rest** — on by default since 2023 (SSE-S3).

| Mode | Keys managed by | Notes |
|---|---|---|
| SSE-S3 | AWS | default, free |
| SSE-KMS | you, via KMS | auditable, per-key access control, KMS charges |
| SSE-C | you, sent per request | AWS stores no key |
| Client-side | you | encrypted before it ever leaves your machine |

For SSE-KMS at high request rates, enable **S3 Bucket Keys** — it cuts KMS calls
and cost dramatically.

**In transit** — TLS. Enforce it with a bucket policy denying
`aws:SecureTransport: false`.

## Bucket policies

Resource-based JSON attached to the bucket. Unlike IAM policies, they can grant
access to other accounts and to anonymous users.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyUnencryptedTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::my-bucket",
      "arn:aws:s3:::my-bucket/*"
    ],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}}
  }]
}
```

**Block Public Access** is on by default at account and bucket level and
overrides any policy that would make objects public. Leave it on. The standard
way to serve public content is CloudFront with an Origin Access Control, not a
public bucket — nearly every "S3 data leak" headline is a bucket someone opened
deliberately.

Access controls, in order of preference: IAM policies -> bucket policies ->
presigned URLs -> ACLs (legacy; disable them with Object Ownership set to
"bucket owner enforced").

## Common use cases

- Static website hosting, fronted by CloudFront
- Backups, database dumps, disaster recovery
- Data lakes queried in place by Athena
- Log aggregation (ALB, CloudTrail, VPC flow logs all write to S3)
- **Terraform remote state**, with versioning on and locking enabled
- Media storage and distribution
- Serving user uploads via presigned URLs, so traffic never touches your servers
