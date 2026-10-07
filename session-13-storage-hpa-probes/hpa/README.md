# HPA Load Test — `yatri-backend`

A complete, self-contained Horizontal Pod Autoscaler exercise: a real HTTP
workload, a Service, an HPA, and a load generator that drives it.

## Files

| File | What it creates |
|---|---|
| `backend-deployment.yaml` | Deployment `yatri-backend` — a Python HTTP server on port 5000 serving `/healthz`, 2 replicas, `requests.cpu: 100m` |
| `backend-service.yaml` | ClusterIP Service `yatri-backend-service`, port 80 -> targetPort 5000 |
| `hpa-backend.yaml` | HPA `yatri-backend-hpa`, min 2 / max 10, scaling on **50% average CPU** |
| `load_generator.sh` | Port-forwards the Service and fires 10 parallel `curl` loops at `/healthz` |

Each request makes the server run 12,000 SHA-256 rounds. That is deliberate — a
static page served by nginx costs almost no CPU, so an HPA demo built on one
often refuses to scale at all. Here the CPU cost per request is real and the
utilisation figure moves within a minute.

## Prerequisites

The HPA reads CPU from the **metrics-server**. Without it, `TARGETS` stays
`<unknown>/50%` forever and nothing scales.

```bash
minikube addons enable metrics-server
kubectl top pods          # must return numbers before continuing
```

## Walkthrough

```bash
# 1. Deploy the workload and expose it
kubectl apply -f backend-deployment.yaml
kubectl apply -f backend-service.yaml
kubectl rollout status deploy/yatri-backend

# 2. Create the autoscaler
kubectl apply -f hpa-backend.yaml
kubectl get hpa yatri-backend-hpa
```

Give metrics-server 60–90 seconds. `TARGETS` must show a real percentage
(`cpu: 8%/50%`) and not `<unknown>` before the load test is meaningful.

```bash
# 3. Generate load (leave this running)
bash load_generator.sh

# 4. In a second terminal, watch it scale
kubectl get hpa -w
kubectl get pods -l app=yatri-backend -w
kubectl top pods -l app=yatri-backend
```

Stop the load generator with Ctrl-C and keep watching.

## What to expect

| Phase | Behaviour |
|---|---|
| Idle | 2 replicas, CPU ~5-10% |
| ~60-90 s under load | CPU climbs past 50%, HPA raises the replica count |
| Sustained load | scales toward `maxReplicas: 10`, in steps, not one jump |
| Load stops | CPU drops immediately, **replicas do not** |
| ~5 min after | scales back down to `minReplicas: 2` |

That last row is the part people misread as a broken HPA. The
`--horizontal-pod-autoscaler-downscale-stabilization` window defaults to **5
minutes**: the controller takes the *highest* recommendation from the last 5
minutes before scaling down, so a brief dip in traffic never causes a thrash.
Scaling up is fast; scaling down is deliberately slow.

The scaling arithmetic is:

```
desiredReplicas = ceil( currentReplicas x ( currentMetric / desiredMetric ) )
```

So 2 replicas averaging 100% CPU against a 50% target gives
`ceil(2 x (100/50))` = 4 replicas.

## Teardown

```bash
kubectl delete -f hpa-backend.yaml -f backend-service.yaml -f backend-deployment.yaml
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `TARGETS: <unknown>/50%` | metrics-server missing, or not scraped yet | enable the addon, wait 60-90 s |
| `failed to get cpu utilization: missing request for cpu` | container has no `resources.requests.cpu` | HPA needs a request to compute a percentage against |
| HPA exists but never scales | load too light | the CPU burn per request is what makes this demo work; check `kubectl top pods` |
| `deployments.apps "yatri-backend" not found` | Deployment not applied | apply `backend-deployment.yaml` first |
