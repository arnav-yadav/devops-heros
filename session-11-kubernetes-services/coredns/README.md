# CoreDNS

## What is CoreDNS?

CoreDNS is the DNS server that runs **inside** the Kubernetes cluster. It is a
flexible, plugin-based DNS server written in Go, and since Kubernetes 1.13 it has
been the default cluster DNS, replacing kube-dns.

It runs as an ordinary Deployment in `kube-system`, fronted by a Service with a
well-known ClusterIP that every Pod is configured to use as its nameserver.

```bash
kubectl get deploy,pods,svc -n kube-system -l k8s-app=kube-dns
```

```
deployment.apps/coredns   1/1     1            1
pod/coredns-559f6c778d-kftlm   1/1     Running
service/kube-dns   ClusterIP   10.96.0.10   53/UDP,53/TCP,9153/TCP
```

> The Service is still called `kube-dns` for backward compatibility, even though
> the software behind it is CoreDNS.

---

## Why Kubernetes uses CoreDNS

Pod IPs are ephemeral. A Pod that restarts gets a new IP; a Deployment that
scales replaces the set entirely. Hard-coding IPs is impossible, so the cluster
needs a naming layer that updates itself as Pods and Services come and go.

CoreDNS replaced kube-dns because:

| | kube-dns | CoreDNS |
|---|---|---|
| Processes | 3 containers (`kubedns`, `dnsmasq`, `sidecar`) | 1 |
| Architecture | fixed | plugin chain |
| Language | Go + C (dnsmasq) | pure Go |
| Memory | higher | lower |
| Extending it | hard | add a plugin line |

One process instead of three removed a whole class of failure modes, and the
plugin model means custom stub domains or rewrites are a config change rather
than a fork.

---

## How Service discovery works

1. A Service is created. The API server records it.
2. CoreDNS **watches** the API server for Service and Endpoint changes — it does
   not poll, and it does not keep a zone file on disk.
3. Its in-memory records update within a second or so.
4. Pods are configured by the kubelet with `nameserver 10.96.0.10` in
   `/etc/resolv.conf`, so every lookup goes to CoreDNS.

Different Service types produce different records:

| Service type | What DNS returns |
|---|---|
| ClusterIP | one A record -> the stable virtual IP |
| Headless (`clusterIP: None`) | one A record **per ready Pod** |
| ExternalName | a CNAME to the external hostname, no proxying |
| NodePort / LoadBalancer | same as ClusterIP internally |

Headless Services are what give StatefulSet Pods their stable identities:
`mysql-0.mysql.default.svc.cluster.local` always means that specific Pod.

---

## How a DNS query is resolved

A Pod in `default` runs `curl http://backend`:

```
1. resolv.conf:  nameserver 10.96.0.10
                 search default.svc.cluster.local svc.cluster.local cluster.local
                 options ndots:5

2. "backend" has 0 dots, which is < ndots:5
   -> try the search domains first, in order

3. Query: backend.default.svc.cluster.local  -> CoreDNS
4. CoreDNS kubernetes plugin matches the cluster.local zone
   -> looks up Service "backend" in namespace "default"
   -> returns A 10.96.142.31

5. The connection goes to 10.96.142.31; kube-proxy's iptables/IPVS rules
   DNAT it to one of the ready backing Pod IPs.
```

If the name had **not** matched the cluster zone — say `github.com` — the
`forward . /etc/resolv.conf` plugin would hand it to the node's upstream
resolver instead.

---

## CoreDNS configuration

CoreDNS is configured by a **Corefile**, stored in a ConfigMap:

```bash
kubectl get configmap coredns -n kube-system -o yaml
```

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

| Plugin | Role |
|---|---|
| `errors` | log errors |
| `health` / `ready` | liveness and readiness endpoints |
| `kubernetes` | **the important one** — serves the `cluster.local` zone from the API server |
| `prometheus` | metrics on :9153 |
| `forward` | send anything non-cluster to the upstream resolver |
| `cache` | cache answers for 30s |
| `loop` | detect and abort forwarding loops |
| `reload` | pick up Corefile edits without a restart |
| `loadbalance` | shuffle A records round-robin |

Plugins execute in a fixed order, not the order written. Editing the ConfigMap is
enough — `reload` applies it within about two minutes.

Per-Pod overrides are also possible without touching CoreDNS:

```yaml
spec:
  dnsPolicy: ClusterFirst
  dnsConfig:
    options:
      - name: ndots
        value: "2"
```

---

## Troubleshooting DNS

**1. Is CoreDNS running at all?**

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=50
```

**2. Can a Pod resolve anything?**

```bash
kubectl run dnsutils --rm -it --restart=Never --image=busybox:1.36 -- sh
/ # nslookup kubernetes.default      # the control plane Service, always exists
/ # nslookup backend.default.svc.cluster.local
/ # cat /etc/resolv.conf
```

If `kubernetes.default` fails, DNS itself is broken. If only *your* Service
fails, the Service is the problem.

**3. Does the Service actually have Endpoints?**

```bash
kubectl get endpoints backend
```

`<none>` means DNS is fine and the **selector doesn't match any Pod labels** —
by far the most common cause of "DNS is broken".

**4. Is it a short-name/namespace problem?**

A name that works in `default` but not elsewhere is a missing namespace
qualifier, not a DNS fault. Use `<svc>.<namespace>`.

**5. Is a NetworkPolicy blocking port 53?**

A default-deny egress policy blocks DNS unless UDP/TCP 53 to `kube-system` is
explicitly allowed. The symptom is a total resolution failure that looks exactly
like CoreDNS being down.

### Symptom table

| Symptom | Likely cause |
|---|---|
| Nothing resolves, anywhere | CoreDNS pods down/crashlooping, or NetworkPolicy blocking :53 |
| `kubernetes.default` resolves, your Service doesn't | wrong name, wrong namespace, or Service doesn't exist |
| Name resolves but connection refused | DNS is fine — check Endpoints, ports, and the app |
| Works in one namespace only | short name + search domain; qualify the namespace |
| External names fail, cluster names work | `forward` upstream unreachable |
| Intermittent failures | CoreDNS under-replicated or resource-starved; scale it up |

```bash
# quick health check
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=100 | grep -i error
kubectl -n kube-system describe configmap coredns
kubectl get endpoints kube-dns -n kube-system
```
