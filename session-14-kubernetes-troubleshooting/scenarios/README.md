# Kubernetes Incident Triage Gauntlet

Five intentionally broken workloads. Each folder holds a `broken.yaml` (the
incident) and a `fixed.yaml` (the remediation). Deploy them all at once with:

```bash
bash triage_all.sh
kubectl get pods -l tier=triage-gauntlet
```

Every Pod carries the labels `tier=triage-gauntlet` and `scenario=<name>`, so the
whole gauntlet can be listed, watched and torn down with a single selector.

## The universal triage loop

```
GET  ->  DESCRIBE  ->  EVENTS  ->  LOGS  ->  EXEC  ->  FIX  ->  VERIFY
```

| Step | Command | Answers |
|---|---|---|
| GET | `kubectl get pods -o wide` | What state is it in? How many restarts? |
| DESCRIBE | `kubectl describe pod <pod>` | Why does Kubernetes think it failed? |
| EVENTS | `kubectl get events --sort-by=.lastTimestamp` | What happened, in order? |
| LOGS | `kubectl logs <pod>` / `--previous` | What did the *application* say? |
| EXEC | `kubectl exec -it <pod> -- sh` | Is the inside of the container sane? |

The single most useful rule: **`logs` tells you what the application said,
`describe` tells you what Kubernetes did.** A Pod that never started has no logs,
so `describe` is the only source of truth.

---

## Scenario 1 — CrashLoopBackOff

**Symptom:** `fail-1-crashloop-pod` cycles `Error` -> `CrashLoopBackOff`, restart
count climbing.

**Investigate**
```bash
kubectl get pod fail-1-crashloop-pod
kubectl logs fail-1-crashloop-pod
kubectl logs fail-1-crashloop-pod --previous
```

**Root cause:** the container reads `DATABASE_URL` from the environment, but the
manifest defines no `env:` block. The script writes `[FATAL ERROR]: DATABASE_URL
environment variable is MISSING!` to stderr and calls `sys.exit(1)`. A non-zero
exit under the default `restartPolicy: Always` produces CrashLoopBackOff, and the
backoff interval doubles on each retry.

**Fix:** supply the variable (`fixed.yaml` adds an `env:` block). In production
this would come from a ConfigMap or Secret, not a literal.

```bash
kubectl delete -f broken.yaml && kubectl apply -f scenario-1-crashloop/fixed.yaml
kubectl logs fail-1-crashloop-pod     # "Application started successfully!"
```

---

## Scenario 2 — ImagePullBackOff / ErrImagePull

**Symptom:** `fail-2-imagepull-pod` never starts; status `ErrImagePull`, then
`ImagePullBackOff`.

**Investigate**
```bash
kubectl describe pod fail-2-imagepull-pod | tail -20
```
`kubectl logs` is useless here — the container was never created, so there is
nothing to log. The answer is in the Events section.

**Root cause:** `image: yatri-api-service:v999-invalid-tag-does-not-exist`. The
name has no registry prefix, so Docker Hub is assumed, and no such
repository/tag exists. `ErrImagePull` is the first failure; `ImagePullBackOff` is
the kubelet backing off from retrying.

**Fix:** use a real, pullable image and an explicit tag.

> The same symptom with a *private* registry means a missing or wrong
> `imagePullSecrets` rather than a bad name — `describe` distinguishes the two
> (`not found` vs `unauthorized`).

---

## Scenario 3 — Pending

**Symptom:** `fail-3-pending-pod` sits in `Pending` indefinitely and is never
assigned to a node.

**Investigate**
```bash
kubectl describe pod fail-3-pending-pod | tail -15
kubectl get nodes
kubectl describe node minikube | grep -A 8 "Allocatable"
```

**Root cause:** `requests.cpu: "500"` means 500 **whole cores** (500m would be
half a core) and `requests.memory: "1000Gi"`. No node can satisfy that, so the
scheduler reports `FailedScheduling ... Insufficient cpu, Insufficient memory`.

`Pending` always means the *scheduler* could not place the Pod. The usual causes
are resource requests that exceed any node, an unsatisfiable nodeSelector or
affinity rule, a taint with no matching toleration, or an unbound PVC.

**Fix:** right-size the requests to `100m` / `64Mi`.

---

## Scenario 4 — DNS / service discovery failure

**Symptom:** this is the sneaky one — the Pod reports **`Running`** and looks
healthy. The failure is only visible in the logs, because the manifest ends the
curl with `|| true` and then sleeps.

**Investigate**
```bash
kubectl logs fail-4-dns-failure-pod
kubectl exec -it fail-4-dns-failure-pod -- nslookup postgres-db-wrong-name
kubectl exec -it fail-4-dns-failure-pod -- cat /etc/resolv.conf
kubectl get svc -A | grep postgres
kubectl get pods -n kube-system -l k8s-app=kube-dns
```

**Root cause:** the client resolves
`postgres-db-wrong-name.production.svc.cluster.local`. Both parts are wrong — no
Service by that name exists, and there is no `production` namespace. The
Kubernetes Service FQDN is:

```
<service-name>.<namespace>.svc.cluster.local
```

**Fix:** `fixed.yaml` creates the `postgres-db` Service the client is supposed to
talk to and corrects the FQDN to `postgres-db.default.svc.cluster.local`.

> A `Running` Pod is not a healthy Pod. Without a readiness probe, Kubernetes has
> no idea the application is failing.

---

## Scenario 5 — OOMKilled

**Symptom:** `fail-5-oomkilled-pod` restarts repeatedly and ends in
`CrashLoopBackOff` — which looks identical to scenario 1 from `kubectl get pods`.

**Investigate**
```bash
kubectl describe pod fail-5-oomkilled-pod | grep -A 6 "Last State"
```

**Root cause:** the container allocates 100 x 10MB = ~1GB while
`resources.limits.memory` is `20Mi`. The kernel OOM killer terminates it.

```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

**Exit code 137 = 128 + 9 (SIGKILL)** — the signature of an OOM kill. This is what
separates scenario 5 from scenario 1: scenario 1 exits `1` (the application chose
to quit), scenario 5 exits `137` (the kernel killed it). `kubectl logs` shows a
truncated, apparently-normal log in both cases, so **`describe` is the only way to
tell them apart.**

**Fix:** allocate within budget and set a limit that matches the real working set.

---

## Teardown

```bash
kubectl delete pods,svc,deploy -l tier=triage-gauntlet
```

## Symptom -> first command cheat sheet

| Symptom | Look at | Usual cause |
|---|---|---|
| `CrashLoopBackOff` | `logs --previous` | app exits non-zero: bad config, missing env |
| `OOMKilled` / exit 137 | `describe` -> Last State | memory limit too low |
| `ImagePullBackOff` | `describe` -> Events | bad image name/tag, or missing pull secret |
| `Pending` | `describe` -> Events | unschedulable: resources, taints, unbound PVC |
| `Running` but broken | `logs`, `exec` | wrong DNS name, wrong port, missing probe |
| Service returns nothing | `get endpoints` | selector does not match Pod labels |
