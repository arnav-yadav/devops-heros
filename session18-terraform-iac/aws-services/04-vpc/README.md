# VPC — Virtual Private Cloud

## What is a VPC?

A VPC is your own logically isolated network inside AWS. You choose the IP range,
carve it into subnets, and control routing and firewalling. Nothing reaches your
resources unless you build a path for it.

A VPC is **regional** and spans every Availability Zone in that region; a subnet
lives in exactly **one** AZ.

```
Region
└── VPC  10.0.0.0/16
    ├── AZ-a
    │   ├── public subnet   10.0.1.0/24   -> Internet Gateway
    │   └── private subnet  10.0.11.0/24  -> NAT Gateway
    └── AZ-b
        ├── public subnet   10.0.2.0/24
        └── private subnet  10.0.12.0/24
```

## CIDR

Classless Inter-Domain Routing notation: `10.0.0.0/16` means the first 16 bits
are the network, leaving 16 bits — 65,536 addresses.

| CIDR | Addresses | Usable in AWS |
|---|---|---|
| /16 | 65,536 | 65,531 |
| /24 | 256 | 251 |
| /28 | 16 | 11 |

**AWS reserves 5 addresses in every subnet**: network address, VPC router,
DNS, future use, and broadcast. A `/28` is the smallest subnet allowed, a `/16`
the largest VPC.

Use private ranges (RFC 1918): `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.

> Plan the range before you build. A VPC CIDR cannot be shrunk, and overlapping
> CIDRs make future VPC peering impossible. Give each environment its own
> non-overlapping block.

## Subnets

A subnet is a slice of the VPC CIDR pinned to one AZ.

The distinction between public and private is **not a setting** — it is purely
routing:

| | Public subnet | Private subnet |
|---|---|---|
| Route table has | `0.0.0.0/0 -> igw-xxx` | `0.0.0.0/0 -> nat-xxx` (or nothing) |
| Inbound from internet | possible | impossible |
| Outbound to internet | direct | via NAT |
| Typical contents | load balancers, bastions, NAT | app servers, databases |

`map_public_ip_on_launch` auto-assigns public IPs — useful in a public subnet,
wrong everywhere else.

## Route tables

A set of rules matching destination CIDRs to targets. Every subnet is associated
with exactly one route table (the VPC's "main" one by default).

```
Destination      Target      Meaning
10.0.0.0/16      local       intra-VPC; always present, cannot be removed
0.0.0.0/0        igw-abc123  everything else -> internet
10.1.0.0/16      pcx-def456  peered VPC
```

Most specific prefix wins, so a `/24` route beats a `/16`.

## Internet Gateway (IGW)

A horizontally-scaled, highly available component that connects the VPC to the
internet. One per VPC, free.

Three things must all be true for an instance to be internet-reachable:

1. An IGW is attached to the VPC.
2. The subnet's route table sends `0.0.0.0/0` to it.
3. The instance has a public or Elastic IP.

Miss any one and connectivity fails — this is the most common VPC debugging
exercise.

## NAT Gateway

Lets private-subnet resources make **outbound** connections (package updates, API
calls) while blocking all inbound ones.

- Lives in a **public** subnet and needs an Elastic IP.
- Managed and scalable to 45 Gbps.
- **Not free** — hourly charge plus per-GB processing. The single biggest
  surprise on most AWS bills.
- Zonal: for real high availability you need one per AZ, which multiplies cost.

Cheaper alternatives: **VPC Gateway Endpoints** for S3 and DynamoDB (free, and
they keep traffic off the NAT entirely) and Interface Endpoints for other
services.

| | NAT Gateway | NAT Instance |
|---|---|---|
| Management | AWS | you |
| HA | per-AZ, automatic | you build it |
| Cost | higher | an EC2 instance |
| Security groups | not applicable | applicable |

## Security Groups

Instance-level, **stateful**, allow-only. Return traffic is automatic. Rules may
reference other security groups, which is how tiered architectures are expressed
without IP addresses.

## Network ACLs

Subnet-level, **stateless**, with both allow and deny rules evaluated in numbered
order (lowest first, first match wins).

Because they are stateless, you must explicitly allow return traffic — usually
the **ephemeral port range 1024–65535** for outbound responses. Forgetting that
is why "the NACL looks right but nothing works".

The default NACL allows everything; a custom one denies everything until you add
rules.

| | Security Group | Network ACL |
|---|---|---|
| Level | instance / ENI | subnet |
| State | stateful | stateless |
| Rules | allow only | allow + deny |
| Evaluation | all rules together | numbered, first match |
| Typical role | primary control | coarse guardrail, IP blocklists |

Use security groups as the real control; reach for NACLs to block a specific
range or to add a subnet-wide backstop.

## Putting it together

```
Internet
   |
 [IGW]
   |
Public subnet  10.0.1.0/24   ALB, NAT Gateway
   |                              |
   |                          (outbound only)
   v                              v
Private subnet 10.0.11.0/24   app servers
   |
Private subnet 10.0.21.0/24   RDS (no internet route at all)
```

Checklist for a working design: non-overlapping CIDR, at least two AZs, public
subnets only for things that must face the internet, databases in subnets with no
`0.0.0.0/0` route, VPC endpoints for S3/DynamoDB, and flow logs enabled for
debugging.
