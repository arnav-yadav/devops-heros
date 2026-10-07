# FQDN in Kubernetes

## What is an FQDN?

A **Fully Qualified Domain Name** is a domain name that specifies a host's exact
location in the DNS hierarchy, all the way up to the root. It is unambiguous:
there is nothing left to guess or append.

```
backend.default.svc.cluster.local
└─────┘ └─────┘ └─┘ └───────────┘
  host    ns    type   cluster domain
```

A **partially** qualified name like `backend` only works if something fills in
the rest — which is exactly what Kubernetes does for Pods, via the search
domains in `/etc/resolv.conf`.

---

## Kubernetes Service DNS

Every Service gets a DNS A record automatically, the moment it is created. No
registration, no configuration. Pods talk to Services by name, never by IP,
because Service IPs are stable but opaque and Pod IPs change constantly.

```bash
kubectl get svc backend
# NAME      TYPE        CLUSTER-IP      PORT(S)
# backend   ClusterIP   10.96.142.31    80/TCP
```

`backend.default.svc.cluster.local` resolves to `10.96.142.31`.

---

## The naming convention

```
<service-name>.<namespace>.svc.<cluster-domain>
```

| Part | Example | Notes |
|---|---|---|
| `<service-name>` | `backend` | the Service's `metadata.name` |
| `<namespace>` | `default` | the namespace the Service lives in |
| `svc` | `svc` | fixed — marks this as a Service record |
| `<cluster-domain>` | `cluster.local` | cluster-wide default, configurable at install time |

Pods have their own form, with dots in the IP replaced by dashes:

```
10-244-1-7.default.pod.cluster.local
```

In practice nobody uses Pod DNS directly — it is Services you address.

---

## Namespace-based DNS and short names

A Pod's `/etc/resolv.conf` looks like this:

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

The `search` list is why short names work. From a Pod in `default`:

| You write | Resolves to | Works? |
|---|---|---|
| `backend` | `backend.default.svc.cluster.local` | yes, same namespace |
| `backend.default` | `backend.default.svc.cluster.local` | yes |
| `backend.default.svc` | `backend.default.svc.cluster.local` | yes |
| `backend.default.svc.cluster.local` | itself | yes, always |

From a Pod in a **different** namespace, bare `backend` does **not** resolve —
the first search domain is that Pod's own namespace. Cross-namespace traffic must
qualify at least the namespace:

```
# Pod in "frontend" namespace calling a Service in "backend" namespace
curl http://api.backend.svc.cluster.local
curl http://api.backend          # also fine
curl http://api                  # FAILS - looks for api.frontend.svc...
```

This is the single most common DNS mistake in Kubernetes: a name that works in
dev (everything in `default`) breaks in production (split into namespaces).

> **`ndots:5`** means any name with fewer than 5 dots is tried against the search
> domains *first*, before being treated as absolute. So looking up
> `api.example.com` (2 dots) causes four failed cluster lookups before the real
> one succeeds. For external-heavy workloads this is a measurable latency cost;
> the fix is a trailing dot (`api.example.com.`) or a custom `dnsConfig`.

---

## Pod-to-Service communication

```
Pod  --"backend"-->  CoreDNS  -->  10.96.142.31 (ClusterIP)
                                        |
                                   kube-proxy / iptables
                                        |
                        +---------------+---------------+
                        v               v               v
                   Pod 10.244.1.5  Pod 10.244.1.6  Pod 10.244.2.3
```

1. The application resolves `backend`.
2. CoreDNS returns the Service's stable ClusterIP.
3. The connection goes to that virtual IP.
4. `kube-proxy` rules rewrite the destination to one of the ready backing Pods.

The ClusterIP is virtual — nothing actually listens on it. It exists only as a
load-balancing rule in the node's packet filter, which is why you can ping a Pod
but often cannot ping a ClusterIP.

---

## Examples

```bash
# Same namespace
curl http://backend

# Different namespace
curl http://backend.production

# Fully qualified
curl http://backend.default.svc.cluster.local

# Named port on a Service
curl http://backend.default.svc.cluster.local:8080

# Headless Service: returns the Pod IPs, not a ClusterIP
nslookup backend-headless.default.svc.cluster.local

# StatefulSet Pod - stable per-Pod DNS
# <pod>.<headless-svc>.<ns>.svc.cluster.local
curl http://mysql-0.mysql.default.svc.cluster.local

# ExternalName Service - returns a CNAME to an outside host
# svc "db" with externalName: db.example.com
nslookup db.default.svc.cluster.local
```

### Verifying from inside the cluster

```bash
kubectl run dnsutils --rm -it --restart=Never \
  --image=busybox:1.36 -- sh

/ # nslookup backend
/ # nslookup backend.default.svc.cluster.local
/ # cat /etc/resolv.conf
/ # wget -qO- http://backend
```
