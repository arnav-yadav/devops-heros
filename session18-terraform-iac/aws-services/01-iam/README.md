# IAM — Identity and Access Management

## What is IAM?

IAM controls **who** can do **what** to **which** AWS resources. Every single API
call to AWS — console click, CLI command, or Terraform apply — is authenticated
and then authorised by IAM. It is a global service, not regional, and it is free.

Two questions on every request:

```
Authentication:  who are you?
Authorization:   are you allowed to do this to that resource?
```

## Users

An IAM **user** is a permanent identity for a person or a legacy application. It
has long-lived credentials: a console password, and/or an access key pair
(`AKIA...` + secret).

Those long-lived access keys are the single biggest source of AWS breaches —
committed to Git, pasted into CI config, left on laptops. The modern guidance is
to create as few IAM users as possible and use roles or IAM Identity Center
instead.

## Groups

A **group** is a collection of users that share a permission set. Attach policies
to the group, not the user.

```
Developers group  -> ReadOnlyAccess + S3 write on the dev bucket
   ├── alice
   └── bob
```

Groups cannot be nested, cannot contain roles, and are purely an administrative
convenience — a group is not an identity and nothing can "log in as" a group.

## Roles

A **role** is an identity with permissions but **no permanent credentials**. It
is assumed temporarily, and AWS hands back short-lived credentials (typically
1 hour) via STS.

This is the mechanism that replaces access keys:

| Instead of | Use |
|---|---|
| keys on an EC2 instance | an **instance profile** (an attached role) |
| keys in a Lambda function | the function's **execution role** |
| keys in a Kubernetes pod | **IRSA** — a role bound to a service account |
| keys in GitHub Actions | an **OIDC** trust relationship to a role |
| keys for a human | IAM Identity Center / assume-role |

A role has two policies: the **trust policy** (who may assume it) and the
**permissions policy** (what it may then do). Forgetting the trust policy is the
most common reason an assume-role fails.

## Policies

JSON documents listing permissions. The core shape:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadAppBucket",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-app-bucket",
        "arn:aws:s3:::my-app-bucket/*"
      ],
      "Condition": {
        "IpAddress": {"aws:SourceIp": "203.0.113.0/24"}
      }
    }
  ]
}
```

Note the two ARNs: bucket-level actions (`ListBucket`) target the bucket, while
object-level actions (`GetObject`) target `bucket/*`. Getting this wrong is the
classic "AccessDenied even though I allowed s3:*" mistake.

**Types**

| Type | Attached to | Notes |
|---|---|---|
| AWS managed | anything | maintained by AWS, e.g. `ReadOnlyAccess` |
| Customer managed | anything | your own, reusable, versioned — preferred |
| Inline | one identity | 1:1, deleted with the identity; avoid |
| Resource-based | the resource | e.g. S3 bucket policy; allows cross-account |

## Permissions and evaluation

Evaluation order, simplified:

```
1. Explicit DENY anywhere          -> DENIED   (always wins)
2. Explicit ALLOW                  -> ALLOWED
3. Nothing matched                 -> DENIED   (implicit deny)
```

Everything is denied by default. An explicit `Deny` can never be overridden by
any `Allow` — which is what makes Service Control Policies and permission
boundaries effective guardrails.

## Least privilege

Grant only the permissions actually needed, and no more.

```json
"Action": "s3:*",        "Resource": "*"                          // bad
"Action": "s3:GetObject", "Resource": "arn:aws:s3:::app/data/*"   // good
```

Practical route: start restrictive, run the workload, read the AccessDenied
errors, and widen deliberately. IAM Access Analyzer can generate a policy from
observed CloudTrail activity, which beats guessing.

## Best practices

1. **Lock away the root user.** Use it only for the handful of tasks that
   require it (closing the account, changing support plans). MFA it, and never
   create access keys for it.
2. **Enforce MFA** on every human identity.
3. **Prefer roles over users.** No long-lived access keys for workloads, ever.
4. **Use groups** for human permissions; never attach policies user by user.
5. **Rotate** any credential that must exist, and delete unused ones — the IAM
   credential report shows last-used dates.
6. **Permission boundaries** to cap what a delegated admin can grant.
7. **CloudTrail on**, so every API call is logged.
8. **Access Analyzer** to find resources exposed publicly or cross-account.
9. **Terraform the policies** so they are reviewed and version-controlled.

## Common use cases

| Need | Mechanism |
|---|---|
| EC2 app reads from S3 | instance profile with a scoped role |
| CI/CD deploys to AWS | GitHub OIDC -> role, no stored keys |
| Developers get read-only prod | group + `ReadOnlyAccess` |
| Vendor needs limited access | cross-account role with an ExternalId |
| Pod needs AWS access | IRSA service-account role |
| Stop anyone deleting prod | explicit `Deny` in an SCP |
