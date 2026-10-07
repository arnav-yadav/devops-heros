# Capturing Submission Evidence — A Practical Guide

How to produce screenshot evidence for the DevOps course sessions without
spending a day on it, and the traps that cost time the first time round.

The deliverable per session is a `Submission.md`: a heading per sub-topic and a
screenshot under each, with images in a flat `assets/` folder. Nothing more.

---

## 1. Decisions to make before you start

| Decision | What was chosen | Why |
|---|---|---|
| How to screenshot | Render real command output offscreen | Driving a visible terminal hijacks the machine for hours |
| Which repo is authoritative | `devops-heros` only | It is the graded submission; other repos are scratch |
| Terraform scope | `init` / `fmt` / `validate`, no `apply` | `apply` needs a real AWS account |
| Reuse existing work | Yes, aggressively | Half of sessions 16–20 already existed in other repos |
| Writing style | Heading + images, no prose | Match what was already submitted for sessions 10–12 |

The one worth dwelling on is the first. The obvious approach — open Terminal,
run commands, press Cmd-Shift-4 — does not survive 100 screenshots. The approach
that works is: **run the real command, capture its real stdout, render that text
to a PNG that looks like a terminal.** The commands and output are genuine; only
the photograph is synthesised. Be upfront about that distinction.

---

## 2. Prerequisites

```bash
minikube start
minikube addons enable metrics-server     # HPA will not work without it
minikube addons enable ingress
brew install hashicorp/tap/terraform      # NOT `brew install terraform` - removed from core
```

Check before starting, because each has bitten:

```bash
kubectl top nodes          # must return numbers, not an error
df -h /                    # need ~10GB free; Terraform providers are ~780MB each
helm list -A               # stale releases cause NodePort collisions
docker system df           # a corrupted container record breaks compose
```

---

## 3. The capture harness

Three small files. Put them outside the repo.

**`render.py`** — turns a transcript into a terminal-styled PNG via headless Chrome.
Input is JSON: `{"title", "out_png", "steps":[{"cwd","cmd","out"}]}`. It wraps
each line at 168 columns, draws a macOS title bar and a coloured prompt, and sizes
the image to the content so there is no dead space:

```python
height = 38 + 14 + nlines * 19.5 + 14     # titlebar + padding + lines
subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                "--force-device-scale-factor=2",
                f"--screenshot={out}", f"--window-size=1390,{height}",
                f"file://{page}"])
```

**`cap.sh`** — the driver:

```bash
step_begin                      # start a new transcript
step <dir> "<command>"          # runs it FOR REAL, appends cmd + output
shot ss42                       # renders the accumulated steps to assets/ss42.png
pageshot ss43 <url> [w] [h]     # headless screenshot of a real web page
```

`step` is just `out=$(cd "$cwd" && eval "$cmd" 2>&1)`. Everything in the image
actually ran.

**`pageshot.py`** — headless Chrome against a URL. Two flags matter:
`--blink-settings=preferredColorScheme=1` (otherwise pages render in dark mode)
and `--virtual-time-budget=20000` for JS-heavy UIs like Grafana and ArgoCD.

### Numbering

Screenshots are `ss<N>.png`, globally sequential, no padding, no session prefix.
Allocate a contiguous block per session and pass explicit names — see the
subshell trap below.

---

## 4. Traps that cost real time

**Use explicit screenshot names, not a counter function.**

```bash
n() { echo "ss$((B++))"; }
shot $(n)        # WRONG - $() is a subshell, B never increments,
                 # all four shots overwrite ss59
```

**Never run two cluster-mutating captures concurrently.** One script's teardown
(`kubectl delete -l tier=...`) deleted a pod another was waiting on. Serialise
anything that touches the cluster.

**Python in a container buffers stdout.** A pod that prints and then loops
forever shows *nothing* in `kubectl logs`. Add `flush=True` or your "fixed" pod
looks broken.

**`kubectl logs --previous` needs the pod to have actually restarted.** Wait for
`CrashLoopBackOff`, not `Error`, or there is no previous container to read.

**Check the chart's pod labels before writing a selector.** These charts label
pods `app: {{ .Release.Name }}`, so `-l app=app-chart` matches nothing and the
screenshot silently shows an empty list.

**macOS `awk` has no `strftime`.** Use `awk -v ts="$(date +%H:%M:%S)"`.

**macOS has no `setsid` and no `timeout`.** Use `nohup ... &` and `pkill -f`.

**HPA will sit at `<unknown>/50%` for the first 2–5 minutes.** That is the CPU
initialisation window, not a fault. Separately, scale-**down** waits a 5-minute
stabilisation window after load stops — do not assume it is broken.

**A single load generator will not move CPU on a static nginx page.** Run 3–4
in-cluster pods. Generating load through `kubectl port-forward` proxies every
request via the API server and caps throughput far below the target — always
generate load from *inside* the cluster.

**`terraform init` copies a ~780MB provider per directory.** Nine lab
directories is ~7GB and, on this machine, 16 minutes *each*. Run `fmt -check`
across all of them (instant, no provider needed) and `validate` only where the
brief actually requires it.

**Browser extensions cannot reach `localhost`.** Claude in Chrome screenshots
public pages fine but fails on loopback and private IPs. Use headless Chrome for
anything local; use the extension only for public URLs.

---

## 5. Per-session notes

### Session 13 — Storage, HPA, Probes
Budget ~45 min, mostly waiting on HPA windows.
- emptyDir: write a file, delete the pod, re-apply, show `No such file or directory`
- Static PV/PVC binding needs `storageClassName: ""` on **both** objects
- Probes: break the path to `/wrong-path`. A pod's probe spec is immutable, so
  `kubectl apply` is rejected — ship explicit `*-broken.yaml` files and recreate
- HPA: capture `<unknown>` → real % → scaled out → scaled back, with the
  `SuccessfulRescale` events for both directions

### Session 14 — Troubleshooting
Fast, no waiting. The useful contrast to capture:
- Broken Service selector: `ENDPOINTS <none>` beside two healthy `1/1 Running` pods
- CrashLoopBackOff (exit 1) vs OOMKilled (exit **137** = 128+9 SIGKILL) — these
  look identical in `kubectl get pods`; only `describe` separates them
- The DNS scenario reports `1/1 Running` while completely broken

### Session 15 — Helm
`helm template` needs no cluster. The rollback arc is the centrepiece:
install → upgrade to a bad tag → `ImagePullBackOff` → `helm history` →
`helm rollback 1` → history showing "Rollback to 1". `--atomic --timeout 60s`
blocks for the full 60 seconds before auto-rolling-back.

### Session 20 — Monitoring and GitOps
Richest browser evidence, entirely local.
- `03-prometheus` and `04-grafana` both bind `container_name: session20-prometheus`
  and port 9090 — they **cannot run together**
- Grafana ships with no datasource. Provision it (`provisioning/datasources/`)
  rather than clicking through the UI, and set `GF_AUTH_ANONYMOUS_ENABLED=true`
  so headless Chrome can capture the dashboard without logging in
- ArgoCD: patch `argocd-server` with `--insecure` and enable anonymous read-only
  access, otherwise you get a login page instead of the app
- Point the ArgoCD `Application` at **your own** public repo. A path inside the
  coursework repo works fine — no separate GitOps repo needed

### Sessions 18 / 19 — Terraform
Without an AWS account, `plan` fails at credential lookup. Capture that error
rather than skipping the step; it is the honest boundary:
```
Error: failed to refresh cached credentials, no EC2 IMDS role found
```

### Sessions 16 / 17 — CI/CD
Check what already exists before building anything. GitHub Actions only reads
`.github/workflows/` at the **repository root** — workflows nested inside session
folders never run, which is why they had no history.

---

## 6. Defects found in the course material

Worth checking in your own copy; all were fixed before capturing.

| File | Defect |
|---|---|
| `s14/mini-project/fixed-pod.yaml` | `image: ngninx:latest` — the "fixed" pod is itself broken |
| `s14/mini-project/service.yaml` | Ships with the broken selector already set, so the break/fix narrative has nothing to break |
| `s14/scenarios/` | No `README.md` (the script tells you to follow one) and no `fixed.yaml` for any scenario |
| `s13/02-persistent-storage/{pv,pvc}.yaml` | Missing `storageClassName: ""`, so the default class hijacks the claim |
| `s13/hpa/` | HPA targets a Deployment that exists nowhere; load generator cannot reach the CPU target |
| `s15/04-chart-yaml/README.md` | `helm lint my-app/` points at a non-existent directory |
| `s15/05-values-yaml/README.md` | Every command references `./chart`; the real path is `./my-app` |
| `s15/mini-project/values.yaml` | `replicaCount: 3` contradicts the README, making the scaling step a no-op |
| `s20/04-grafana` | No provisioned datasource |
| `s20/07-argocd`, `08-mini-project` | `repoURL` points at the instructor's repo / a `YOUR_USERNAME` placeholder |

**One thing that is *not* a defect:** `type = string` inside an `output` block is
valid in Terraform ≥ 1.13. `terraform validate` passes. Do not "fix" it.

---

## 7. Verification before submitting

```bash
# every referenced image exists, and no image is orphaned
grep -rhoE '/assets/ss[0-9]+\.png' --include='Submission.md' . \
  | sed 's|/assets/||' | sort -u -V > /tmp/refs.txt
while read -r f; do [ -f "assets/$f" ] || echo "MISSING $f"; done < /tmp/refs.txt
for f in assets/ss*.png; do grep -q "^$(basename $f)$" /tmp/refs.txt || echo "ORPHAN $f"; done

# watch for /assets//ssN.png - a doubled slash renders as a broken image on GitHub
grep -rn 'assets//' --include='Submission.md' .

# leave the environment clean
kubectl get all -A | grep -v 'kube-system\|ingress-nginx\|argocd'
helm list -A
docker compose down          # in each session-20 compose directory
```

---

## 8. What cannot be done locally

Be explicit about these in the write-up rather than leaving gaps unexplained.

- `terraform apply` / `destroy` — needs a real AWS account
- Session 19's VPC stack — LocalStack's free tier does not cover VPC/EC2
- CodeQL SAST — runs only on a GitHub runner; free on public repos, paid on private
- Docker Hub push — needs a `DOCKERHUB_TOKEN` repository secret
- Several browser screenshots are the stock nginx page, because the charts inject
  config as environment variables rather than into the HTML. Back those with
  `kubectl exec ... -- env | grep ...` instead of relying on the page
