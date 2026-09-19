# Ingress vs Ingress Controller

## What is Ingress?

**Ingress** is a Kubernetes API object that defines rules for routing external HTTP/HTTPS traffic to services inside the cluster.

It acts like a **routing configuration**.

For example:

```text
/api/users  →  user-service
/api/orders →  order-service
/          →  frontend-service
```

An Ingress can define:

* Host-based routing
* Path-based routing
* TLS/HTTPS configuration
* Routing rules for different Kubernetes Services

### Example

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
spec:
  rules:
    - host: example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 80
```

**Important:** Creating an Ingress object by itself does not route traffic.

---

## What is an Ingress Controller?

An **Ingress Controller** is the actual component that **implements and enforces the rules defined by Ingress resources**.

It watches the Kubernetes API for Ingress objects and configures a reverse proxy/load balancer accordingly.

Common Ingress Controllers include:

* NGINX Ingress Controller
* Traefik
* HAProxy
* Kong
* Istio

For example:

```text
                    Kubernetes Cluster
                           │
                    ┌──────▼──────┐
                    │    Ingress   │
                    │   (Rules)    │
                    └──────┬───────┘
                           │
                    ┌──────▼──────────┐
Internet ──────────►│ Ingress         │
                    │ Controller      │
                    │ (NGINX/Traefik) │
                    └──────┬──────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         frontend       api-service   user-service
```

---

## Key Difference

| Ingress                          | Ingress Controller                |
| -------------------------------- | --------------------------------- |
| Kubernetes API resource          | Running application/component     |
| Defines routing rules            | Implements routing rules          |
| Configuration                    | Traffic handler                   |
| Does not route traffic by itself | Actually routes traffic           |
| Created using YAML               | Installed/deployed in the cluster |
| Example: `Ingress` object        | Example: NGINX, Traefik           |

---

## Simple Analogy

Think of a **restaurant**:

* **Ingress** = The menu/instructions saying where each order should go.
* **Ingress Controller** = The waiter who actually reads those instructions and sends the order to the correct kitchen station.

So:

> **Ingress tells Kubernetes *where traffic should go*.**
> **Ingress Controller actually makes that routing happen.**

---

## How They Work Together

The complete flow is:

```text
User
  │
  ▼
Ingress Controller
  │
  │ reads
  ▼
Ingress Resource
  │
  │ routing rules
  ▼
Kubernetes Service
  │
  ▼
Pods
```

### In short

```text
Ingress
   ↓
"Route /api to api-service"

Ingress Controller
   ↓
"Okay, I'll actually route /api traffic there."
```

**Ingress = Rules**

**Ingress Controller = Implementation**
