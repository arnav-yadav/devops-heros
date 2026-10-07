# Kubernetes Volumes

Containers have an **ephemeral** filesystem. Anything written inside a container
is lost the moment that container is restarted or replaced — not just when the
Pod is deleted, but on any crash-and-restart. Volumes are how Kubernetes gives a
Pod storage that outlives the container.

```
Container filesystem   ->  dies with the container
emptyDir               ->  dies with the Pod
hostPath               ->  lives on one specific node
PersistentVolume       ->  lives independently of any Pod
```

---

## emptyDir

A scratch directory created when the Pod is assigned to a node and deleted when
the Pod is removed. It starts empty, and all containers in the Pod can share it.

```yaml
volumes:
  - name: cache
    emptyDir: {}
```

Lifetime is tied to the **Pod**, not the container. A container that crashes and
restarts still sees its data; deleting the Pod destroys it.

Use it for: scratch space, caches, and passing files between containers in the
same Pod (a sidecar writing logs that the main container reads).

Demo: `emptydir-pod.yaml`

```bash
kubectl apply -f emptydir-pod.yaml
kubectl exec -it emptydir-demo -- sh -c 'echo "Hello Kubernetes" > /data/message.txt'
kubectl exec emptydir-demo -- cat /data/message.txt     # Hello Kubernetes
kubectl delete pod emptydir-demo
kubectl apply -f emptydir-pod.yaml
kubectl exec emptydir-demo -- cat /data/message.txt     # No such file or directory
```

That final error is the whole point of the exercise.

---

## hostPath

Mounts a file or directory from the **node's own filesystem** into the Pod.

```yaml
volumes:
  - name: node-data
    hostPath:
      path: /tmp/hostpath-data
      type: DirectoryOrCreate
```

Data survives Pod deletion, but it is tied to one node. If the Pod is
rescheduled elsewhere it sees a different (probably empty) directory. On a
single-node cluster like Minikube that distinction is invisible, which makes
hostPath deceptively attractive.

Use it for: node-level agents that genuinely need host access — log collectors
reading `/var/log`, monitoring agents reading `/proc`. **Avoid it for application
data**; it breaks on any multi-node cluster and is a security risk, since it
exposes the host filesystem to the container.

Demo: `hostpath-pod.yaml`

---

## PersistentVolume (PV)

A piece of storage in the cluster, provisioned by an administrator or created
dynamically. It is a **cluster-scoped** object with a lifecycle independent of
any Pod.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: student-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /tmp/student-data
```

**Access modes**

| Mode | Meaning |
|---|---|
| `ReadWriteOnce` (RWO) | read-write by a single **node** |
| `ReadOnlyMany` (ROX) | read-only by many nodes |
| `ReadWriteMany` (RWX) | read-write by many nodes (needs NFS/CephFS-style backing) |

**Reclaim policy** — what happens when the claim is deleted: `Retain` keeps the
data for manual recovery, `Delete` removes the underlying storage.

---

## PersistentVolumeClaim (PVC)

A **request** for storage. The Pod references the claim, never the volume
directly. This is the key abstraction: the application asks for "5Gi of
read-write storage" and does not care whether it is backed by a local disk, EBS,
or NFS.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: student-pvc
spec:
  storageClassName: ""
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 500Mi
```

```
Pod  ->  PersistentVolumeClaim  ->  PersistentVolume  ->  real storage
```

> **The `storageClassName: ""` matters.** Omit it and the admission controller
> injects the cluster's *default* StorageClass, which dynamically provisions a
> brand-new volume — your hand-written PV is ignored and stays `Available`. An
> empty string explicitly means "no class", which is what lets a PVC bind to a
> statically-created PV. This is the single most common surprise in this topic.

---

## StorageClass

Describes a *kind* of storage the cluster can provision on demand, and names the
provisioner that does it.

```bash
kubectl get storageclass
```

```
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate
```

`VOLUMEBINDINGMODE` is worth knowing: `Immediate` binds the volume as soon as the
PVC is created, while `WaitForFirstConsumer` delays binding until a Pod is
scheduled — which matters on multi-zone clusters, so the disk is created in the
same zone as the Pod that will use it.

---

## Dynamic provisioning

With a StorageClass in place, no one has to pre-create PVs. The PVC names a
class, and the provisioner creates a matching PV automatically.

```yaml
spec:
  storageClassName: standard
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 500Mi
```

```bash
kubectl apply -f ../03-storageclass/pvc.yaml
kubectl get pvc    # Bound
kubectl get pv     # a pvc-<uuid> PV that nobody created by hand
```

| | Static | Dynamic |
|---|---|---|
| Who creates the PV | an administrator, in advance | the provisioner, on demand |
| PVC specifies | `storageClassName: ""` | a StorageClass name |
| Scales to many apps | poorly | well |
| Typical use | bare metal, pre-allocated disks | cloud, and anything self-service |

---

## Choosing

| Need | Use |
|---|---|
| Scratch space for one Pod | `emptyDir` |
| Share files between containers in a Pod | `emptyDir` |
| Read node logs or the Docker socket | `hostPath` |
| Data that must survive Pod deletion | PVC + PV |
| Self-service storage for many apps | StorageClass + dynamic provisioning |
| Databases, user uploads, anything stateful | PVC, almost always dynamic |
