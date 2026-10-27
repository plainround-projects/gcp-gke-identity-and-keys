# Kubernetes (the objects in the manifests)

## 1. What it is

Kubernetes is a system that runs containers across a group of machines and keeps them in the state you describe. You write **manifests** (YAML files) that describe objects; the cluster's control plane makes reality match. A **cluster** is the control plane plus its machines (**nodes**). The objects used here:

- **Namespace**: a named area inside the cluster that groups objects (`demo`).
- **ServiceAccount**: an identity for pods, inside the cluster (`reader-writer`).
- **Pod**: one or more containers that run together. The smallest thing Kubernetes runs.
- **Deployment**: keeps a chosen number of identical pods running and replaces them when they die or change.
- **NetworkPolicy**: a firewall rule between pods.

## 2. Why this repository uses it

The lesson's pod runs the Google Cloud command-line tool and sleeps, so the learner can run storage commands inside it and see which identity they use. The manifests make the keyless design visible: which service account, no secret, no token mounted, restricted permissions.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `manifests/base/namespace.yaml` | Namespace `demo` with pod-security labels. |
| `manifests/base/serviceaccount.yaml` | Service account `reader-writer`. |
| `manifests/base/deployment.yaml` | Deployment `files`: the pod that runs as `reader-writer`. |
| `manifests/base/networkpolicy.yaml` | Denies all ingress to pods in the namespace. |
| `manifests/overlays/wrong-identity/files-default.yaml` | The same pod without a service account name, so it runs as `default` (break one). |
| `tests/unit/test_manifests.py` | Checks all of the above as data. |

## 4. How it works underneath

You send a manifest to the cluster's **API server** (`kubectl apply`). The API server stores it. Controllers notice the difference between what you asked for and what exists, and act: the Deployment controller creates pods; the scheduler picks a node; the node's agent (kubelet) pulls the image and starts the container. Everything is a loop of "observe, compare, fix".

Objects find each other by **labels** (key/value tags). A Deployment's `selector.matchLabels` must match the labels in its pod template; that is how it knows which pods are its own.

A pod's identity inside the cluster is its **service account**. If the manifest names none, the pod runs as the namespace's `default` service account. By default Kubernetes also mounts a token for that account into the pod; setting `automountServiceAccountToken: false` stops that.

**Pod Security Standards** are built-in rules with three levels. The namespace label `pod-security.kubernetes.io/enforce: restricted` makes the cluster refuse any pod that does not meet the strictest level.

## 5. Walkthrough of this repository's use

### Namespace and service account

`manifests/base/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    app.kubernetes.io/part-of: gke-identity-and-keys
    pod-security.kubernetes.io/enforce: restricted
```

- Every manifest starts with `apiVersion` (which API group and version), `kind` (the object type) and `metadata` (name and labels).
- The label `pod-security.kubernetes.io/enforce: restricted` turns on the strictest pod rules for this namespace.

`manifests/base/serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: reader-writer
  namespace: demo
  labels:
    app.kubernetes.io/part-of: gke-identity-and-keys
automountServiceAccountToken: false
```

There is **no annotation and no secret**. The service account is only a name: Google IAM is told about it separately, by the bucket policy (see `workload-identity-federation.md`). `automountServiceAccountToken: false` means pods using it do not get a Kubernetes API token, because they do not call the Kubernetes API.

### The pod

`manifests/base/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: files
  namespace: demo
  labels:
    app: files
    app.kubernetes.io/part-of: gke-identity-and-keys
spec:
  replicas: 1
  selector:
    matchLabels:
      app: files
  template:
    metadata:
      labels:
        app: files
    spec:
      serviceAccountName: reader-writer # the overlay wrong-identity deploys a copy without this line
      automountServiceAccountToken: false # credentials come from the metadata server, not a mounted token
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: tool
          image: gcr.io/google.com/cloudsdktool/google-cloud-cli:590.0.1-slim@sha256:2a5368c4f3e25f7e202ccbd7b63e4128380d8fd683266f7f015c5d0afcc8f3be
          imagePullPolicy: Always
          livenessProbe:
            exec:
              command: ["true"]
          readinessProbe:
            exec:
              command: ["true"]
          command: ["sleep", "infinity"]
          env:
            - name: HOME
              value: /tmp
            - name: CLOUDSDK_CONFIG
              value: /tmp/gcloud
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 250m
              memory: 256Mi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
```

Line by line:

- `replicas: 1` one pod. `selector.matchLabels` and `template.metadata.labels` both say `app: files`, tying the Deployment to its pod.
- `serviceAccountName: reader-writer` runs the pod as that account. The overlay's copy omits this line.
- `automountServiceAccountToken: false`: no Kubernetes token in the pod.
- Pod `securityContext`: `runAsNonRoot: true`, `runAsUser/runAsGroup: 10001` (an unprivileged user) and `seccompProfile: RuntimeDefault` (the container runtime's default filter for system calls).
- `image: ...:590.0.1-slim@sha256:...` the Google Cloud CLI image, pinned by version tag *and* digest. `imagePullPolicy: Always` makes the node check the registry on every start.
- `command: ["sleep", "infinity"]` starts a process that does nothing, keeping the container alive so you can `kubectl exec` into it.
- `env`: `HOME=/tmp` and `CLOUDSDK_CONFIG=/tmp/gcloud` point the tool at the writable folder.
- Container `securityContext`: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true` (the container cannot write to its own file system), `capabilities.drop: ["ALL"]` (no special Linux powers).
- `livenessProbe` and `readinessProbe` run `true` in the container. A **probe** is a periodic check; "liveness" restarts a dead container, "readiness" decides whether it receives traffic. For a pod that only sleeps, "can the container run a command" is the honest check.
- `resources.requests` and `limits` ask for and cap 250 milli-CPU (a quarter of a core) and 256 MiB of memory. On Autopilot, requests are what you are billed for.
- `volumeMounts` mounts the `tmp` volume at `/tmp`; `volumes: tmp: emptyDir: {}` is an empty folder that lives as long as the pod. It gives a writable place while the rest of the file system is read-only.

### The firewall rule

`manifests/base/networkpolicy.yaml`

```yaml
# The pod serves nothing, so nothing may connect to it. Egress stays open: the pod must reach the metadata server and
# the Google APIs, and a restrictive egress policy is easy to get subtly wrong without a cluster to test on.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: demo
  labels:
    app.kubernetes.io/part-of: gke-identity-and-keys
spec:
  podSelector: {}
  policyTypes:
    - Ingress
```

`podSelector: {}` selects every pod in the namespace. `policyTypes: [Ingress]` with no `ingress:` rules means no incoming connections are allowed. Outgoing traffic stays open, because the pod must reach the metadata server and the Google APIs.

### The deliberately wrong copy

`manifests/overlays/wrong-identity/files-default.yaml`

```yaml
metadata:
  name: files-default
  namespace: demo
  labels:
    app: files-default
    app.kubernetes.io/part-of: gke-identity-and-keys
spec:
  replicas: 1
  selector:
    matchLabels:
      app: files-default
  template:
    metadata:
      labels:
        app: files-default
    spec:
      automountServiceAccountToken: false
```

It is the same pod without `serviceAccountName`, named `files-default`. A test asserts the two pods differ only in that line.

## 6. Try it yourself

```bash
kubectl kustomize manifests/base | grep -E "^kind:|^  name:"
```
Expected: `kind: Namespace`, `name: demo`, `kind: ServiceAccount`, `name: reader-writer`, `kind: Deployment`, `name: files`, `kind: NetworkPolicy`, `name: default-deny-ingress`.

```bash
.venv/bin/python -m pytest tests/unit/test_manifests.py -q -p no:cacheprovider
```
Expected: `16 passed`.

```bash
.venv/bin/python - <<'PY'
import yaml
a = yaml.safe_load(open("manifests/base/deployment.yaml"))["spec"]["template"]["spec"]
b = yaml.safe_load(open("manifests/overlays/wrong-identity/files-default.yaml"))["spec"]["template"]["spec"]
print(a.get("serviceAccountName"), b.get("serviceAccountName"))
PY
```
Expected: `reader-writer None`

With a cluster (not run here): `kubectl -n demo get pods`, `kubectl -n demo get secrets` (expected `No resources found in demo namespace.`).

## 7. Mistakes people make

- **Leaving out `serviceAccountName`.** The pod runs as `default`; that is the lesson's break one.
- **Labels that do not match the selector.** The Deployment then manages nothing.
- **Running as root with a writable root file system.** The pod here is restricted.
- **Pulling `:latest`.** The image here is pinned by digest.
- **Expecting a NetworkPolicy to work without a policy-capable network.** Autopilot enforces it (Dataplane V2).
- **Mounting the service account token when you never call the API.** It is turned off.

## 8. Check yourself

1. What identity does a pod use if none is named? *The namespace's `default` service account.*
2. How does a Deployment find its pods? *Its selector matches the pod template's labels.*
3. What does `readOnlyRootFilesystem: true` do? *The container cannot write to its own file system except mounted volumes.*
4. What is `emptyDir` for here? *A writable `/tmp` that lasts as long as the pod.*
5. What does `policyTypes: [Ingress]` with no rules do? *Blocks all incoming connections to the selected pods.*

## 9. Further reading

- Kubernetes documentation: <https://kubernetes.io/docs/home/>
- Pods: <https://kubernetes.io/docs/concepts/workloads/pods/>
- Deployments: <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>
- Pod Security Standards: <https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- NetworkPolicy: <https://kubernetes.io/docs/concepts/services-networking/network-policies/>
- Schema checked in the tests: Kubernetes 1.33
