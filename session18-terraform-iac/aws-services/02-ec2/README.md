# EC2 — Elastic Compute Cloud

## What is EC2?

EC2 provides resizable virtual machines in AWS. You choose an operating system
image, a hardware shape, a network, and a firewall, and you get a server in a
minute or two. You are responsible for everything from the OS upwards — patching,
configuration, scaling.

It is the most flexible compute option and the one with the most operational
burden. Containers (ECS/EKS), Lambda and Fargate all exist to take parts of that
burden away.

## AMI — Amazon Machine Image

The template an instance boots from: operating system, pre-installed software,
and the block device mapping.

| Source | Use |
|---|---|
| AWS provided | Amazon Linux 2023, Ubuntu, Windows Server |
| Marketplace | vendor appliances |
| Custom | your own golden image, built with Packer |

AMIs are **region-specific** — the same logical image has a different AMI ID in
every region, which is why Terraform usually looks them up with a data source
rather than hard-coding an ID.

Baking a custom AMI with your application and dependencies pre-installed shortens
boot time and makes autoscaling predictable.

## Instance types

Named `family.generation.size`, e.g. `t3.micro`, `m7g.xlarge`.

| Family | Optimised for | Typical use |
|---|---|---|
| `t` | burstable | dev boxes, low-traffic sites |
| `m` | balanced | general-purpose app servers |
| `c` | compute | batch processing, game servers |
| `r`, `x` | memory | in-memory caches, big databases |
| `i`, `d` | storage | NoSQL, data warehouses |
| `p`, `g` | GPU | ML training, rendering |

A `g` suffix (`m7g`) means AWS Graviton (ARM) — noticeably cheaper per unit of
performance, provided your software runs on ARM.

> Burstable `t` instances earn CPU credits while idle and spend them under load.
> Exhaust the credits and the instance is throttled hard. This surprises people
> running steady workloads on `t3.micro`.

**Purchase options**

| Option | Discount | Trade-off |
|---|---|---|
| On-Demand | — | no commitment |
| Savings Plans / Reserved | up to ~72% | 1 or 3 year commitment |
| Spot | up to ~90% | can be reclaimed with 2 minutes' notice |
| Dedicated Host | premium | physical isolation, licence compliance |

## Key pairs

SSH public/private key pairs. AWS holds the public key and injects it into the
instance; **you** keep the private key, and AWS cannot recover it. Lose it and
the usual remedy is detaching the root volume and attaching it to another
instance.

```bash
chmod 400 my-key.pem
ssh -i my-key.pem ec2-user@<public-ip>      # Amazon Linux
ssh -i my-key.pem ubuntu@<public-ip>        # Ubuntu
```

Better: **AWS Systems Manager Session Manager**, which gives shell access with no
key pair, no open port 22, and no public IP — access is governed by IAM and
logged to CloudTrail.

## Security Groups

A stateful virtual firewall attached to an instance's network interface.

- **Stateful** — allow traffic in and the reply is automatically permitted.
- **Allow rules only.** There is no "deny"; anything not allowed is denied.
- Rules can reference **another security group** rather than a CIDR, which is the
  idiomatic way to say "the web tier may reach the database tier".

```
web-sg    : allow 443 from 0.0.0.0/0
app-sg    : allow 8080 from web-sg
db-sg     : allow 5432 from app-sg
```

That pattern keeps working as instances come and go, because it never mentions an
IP address.

| | Security Group | Network ACL |
|---|---|---|
| Scope | instance / ENI | subnet |
| State | stateful | stateless |
| Rules | allow only | allow and deny |
| Evaluation | all rules | in numbered order, first match |

## EBS — Elastic Block Store

Network-attached block storage that persists independently of the instance.

| Type | Use |
|---|---|
| `gp3` | default SSD; IOPS and throughput set independently of size |
| `io2` | high-IOPS, mission-critical databases |
| `st1` | throughput HDD, big sequential reads |
| `sc1` | cold HDD, archives |

Key properties: tied to one Availability Zone, snapshot-able to S3, encryptable
(enable encryption by default at the account level), and resizable live.

**Instance store** is different — physically attached NVMe, very fast, and
**wiped when the instance stops**. Use it for scratch and caches only.

By default the root EBS volume is deleted when the instance terminates; extra
volumes are not.

## Public vs private IP

| | Private IP | Public IP | Elastic IP |
|---|---|---|---|
| Scope | inside the VPC | internet | internet |
| Persists across stop/start | yes | **no** | yes |
| Cost | free | free while attached | charged when unattached |

An instance in a private subnet has no public IP and reaches the internet through
a **NAT Gateway**; inbound connections from the internet are impossible, which is
exactly what you want for application and database tiers.

The public IP changes every stop/start, which breaks DNS and SSH config — that is
what Elastic IPs are for, though a load balancer is usually the better answer.

## Instance lifecycle

```
pending -> running -> stopping -> stopped -> running ...
                   -> shutting-down -> terminated   (final)
```

| Action | Effect |
|---|---|
| **Stop** | shuts down; EBS root persists; public IP lost; no compute charge |
| **Reboot** | restart in place; keeps everything, including the public IP |
| **Terminate** | permanent; root volume deleted by default |
| **Hibernate** | RAM written to the root volume and restored on start |

Enable **termination protection** on anything that matters.

**User data** is a script that runs on first boot — the standard place to install
packages or register with a cluster.

## Common use cases

- Web and application servers behind an Application Load Balancer
- Auto Scaling groups across multiple AZs for resilience
- Batch and CI workloads on Spot instances
- Legacy or licensed software that cannot be containerised
- Bastion hosts (or better: Session Manager instead)
- Self-managed databases where RDS does not fit
