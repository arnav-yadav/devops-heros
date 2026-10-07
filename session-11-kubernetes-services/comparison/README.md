# Kubernetes Object Comparison

## Deployment vs ReplicaSet

| | Deployment | ReplicaSet |
|---|---|---|
| **Purpose** | Declarative updates for Pods | Keep N identical Pods running |
| **Pod management** | Indirect — creates and owns ReplicaSets | Direct — creates and owns Pods |
| **Scaling** | `kubectl scale deploy/...`, or an HPA | `kubectl scale rs/...`, rarely done by hand |
| **Rolling updates** | Yes — the whole point of it | **No** — replacing the template does not roll Pods |
| **Rollback** | `kubectl rollout undo` | None |

### The relationship

A Deployment does not manage Pods. It manages **ReplicaSets**, and each ReplicaSet
manages Pods:

```
Deployment  (strategy, history, rollback)
    └── ReplicaSet v2   (3 Pods)   <- current
    └── ReplicaSet v1   (0 Pods)   <- kept for rollback
```

Changing the Pod template creates a *new* ReplicaSet and scales the old one down
gradually. The old ReplicaSet is retained at zero replicas, which is what makes
`kubectl rollout undo` possible — it simply scales the previous one back up.

You almost never create a ReplicaSet directly. Use a Deployment.

---

## Deployment vs DaemonSet vs StatefulSet

| | Deployment | DaemonSet | StatefulSet |
|---|---|---|---|
| **Use case** | Stateless apps | One Pod per node | Stateful apps needing identity |
| **Pod creation** | Random order, parallel | One per node, automatically on new nodes | **Ordered**: 0, then 1, then 2 |
| **Pod names** | `web-5d6676989b-82mf2` (random) | `agent-<node-hash>` | `mysql-0`, `mysql-1` (stable) |
| **Scaling** | Any count | Follows node count — not set manually | Ordered up, reverse order down |
| **Networking** | Service load-balances across Pods | Usually host networking or hostPort | Headless Service gives each Pod its own DNS |
| **Storage** | Usually shared or none | hostPath to node-local data | `volumeClaimTemplates` — one PVC per Pod |
| **Deletion** | Any order | With the node | Reverse ordinal |
| **Examples** | Web APIs, frontends | Fluent Bit, node-exporter, CNI agents | PostgreSQL, Kafka, Elasticsearch |

The distinction that matters: a StatefulSet Pod keeps its **identity** across
restarts. `mysql-0` always reattaches to the same PersistentVolumeClaim and
resolves at the same DNS name, so a replica knows which peer is the primary. A
Deployment Pod has no identity — it is interchangeable, which is exactly why it
scales so easily.

A DaemonSet is scaled by the **cluster**, not by you. Add a node, get a Pod.

---

## ReplicaSet vs Service

These are not alternatives; they solve unrelated problems.

| | ReplicaSet | Service |
|---|---|---|
| **Responsibility** | *How many* Pods exist | *How to reach* the Pods |
| **Watches** | Pod count vs desired | Pod labels vs its selector |
| **Creates** | Pods | A stable virtual IP and DNS name |
| **If it is missing** | Pods are never replaced | Pods run but nothing can find them |

### Why a Service is required

Pod IPs are ephemeral. A Pod that restarts gets a new IP; a ReplicaSet replacing
a failed Pod gives you a different IP again. Nothing can hard-code them.

A Service provides a **stable ClusterIP and DNS name** that never changes, and
continuously tracks which Pods currently match its selector.

### How traffic reaches a Pod

```
client ──"backend"──> CoreDNS ──> 10.96.142.31  (the Service's ClusterIP)
                                        │
                              kube-proxy iptables/IPVS rules
                                        │
                     ┌──────────────────┼──────────────────┐
                     ▼                  ▼                  ▼
              Pod 10.244.1.5     Pod 10.244.1.6     Pod 10.244.2.3
```

1. The name resolves to the Service's ClusterIP.
2. That IP is virtual — nothing listens on it. It exists only as a packet-filter
   rule on each node, which is why you often cannot ping it.
3. `kube-proxy` rewrites the destination to one **ready** Pod.

Step 3 is where the two objects meet. The ReplicaSet decides which Pods exist;
the Service's **endpoints** list decides which of them receive traffic — and only
Pods passing their readiness probe are included.

> `kubectl get endpoints <service>` returning `<none>` while Pods are `Running`
> is the classic symptom: the Service's selector does not match the Pod labels.
