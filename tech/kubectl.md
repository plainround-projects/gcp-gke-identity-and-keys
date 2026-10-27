# kubectl

## 1. What it is

`kubectl` is the command-line client for Kubernetes. It reads your connection settings (the **kubeconfig** file, `~/.kube/config`), sends requests to the cluster's API server, and prints the answers. This repository was checked with kubectl 1.35.3, which includes **kustomize** (see `kustomize.md`).

## 2. Why this repository uses it

To deploy the manifests, run the lesson's test **inside the pod**, read the pod and secret lists, and render the manifests offline to check them.

## 3. Where it appears

| Path | Command |
| --- | --- |
| `scripts/deploy.sh` | `kubectl apply -k manifests/base`, `kubectl -n demo rollout status deploy/files`. |
| `scripts/lib.sh` | `pod_test`: `kubectl -n demo exec deploy/files -- sh -c '...'`. |
| `scripts/prove.sh` | `kubectl -n demo get secrets -o name`, `kubectl exec ... ls`. |
| `scripts/break-wrong-sa.sh` | `kubectl apply -k manifests/overlays/wrong-identity`. |
| `scripts/restore-role.sh` | `kubectl -n demo get pods -l app=files`. |
| `scripts/teardown.sh` | `kubectl delete -k ... --ignore-not-found`. |
| `Makefile` | `make lint-manifests` runs `kubectl kustomize` on both overlays. |

## 4. How it works underneath

`gcloud container clusters get-credentials demo --region=REGION` writes a cluster entry and a login method into kubeconfig. After that every kubectl command uses it. `-n demo` selects the namespace. `apply` sends the desired state; Kubernetes works out the difference. `exec` opens a stream into a running container and runs a command there; everything after `--` is the command, not kubectl options. `rollout status` waits until a Deployment has finished updating.

## 5. Walkthrough of this repository's use

`scripts/lib.sh`

```bash
# The lesson's test, run again after every change, from inside the pod. Prints the command's output and exit status.
pod_test() {
  local deployment="${1:-files}"
  kubectl -n demo exec "deploy/$deployment" -- sh -c "echo hello > /tmp/a.txt && gcloud storage cp /tmp/a.txt gs://$BUCKET/a.txt && gcloud storage cat gs://$BUCKET/a.txt"
}
```

- `kubectl -n demo exec "deploy/$deployment" -- sh -c "..."`: run in a pod of that Deployment (kubectl picks one). `sh -c "string"` runs the string as a shell script inside the pod.
- The script writes `hello` to `/tmp/a.txt`, copies it to the bucket with `gcloud storage cp`, and reads it back with `gcloud storage cat`. The `&&` between commands stops at the first failure. Because this runs in the pod, the tool uses the pod's identity.

`scripts/deploy.sh`

```bash
gcloud container clusters get-credentials demo --region="$REGION"
kubectl apply -k "$ROOT/manifests/base"
kubectl -n demo rollout status deploy/files --timeout=300s
```

- `apply -k DIR` applies a **kustomization** (a directory with a `kustomization.yaml`).
- `rollout status deploy/files --timeout=300s` waits up to five minutes for the pod to be ready.

`scripts/prove.sh`

```bash
check "kubectl get secrets shows no credential" test -z "$(kubectl -n demo get secrets -o name)"
check "no key file exists in the pod" bash -c "! kubectl -n demo exec deploy/files -- sh -c 'ls /tmp/*.json /var/run/secrets 2>/dev/null' | grep -q ."
check "no key was ever created for any service account in the project" \
```

`-o name` prints only object names, so an empty result means there are none; the test passes when the output is empty.

## 6. Try it yourself

```bash
kubectl version --client
```
Expected: `Client Version: v1.35.3` (any recent 1.3x works) and a Kustomize version.

```bash
kubectl kustomize manifests/overlays/wrong-identity | grep -E "^  name: files"
```
Expected: `  name: files` and `  name: files-default` (the two Deployments).

```bash
shellcheck scripts/*.sh && echo clean
```
Expected: `clean`.

## 7. Mistakes people make

- **Running against the wrong cluster.** Check `kubectl config current-context`.
- **Forgetting `-n`.** Without it kubectl looks in the `default` namespace.
- **Mixing kubectl options after `--`.** Everything after `--` goes to the command in the container.
- **Using `kubectl exec` to change a pod and expecting it to stay.** Pods are replaced; change the manifest.
- **Restarting a pod after a permission change.** Not needed here; the next request already sees it.

## 8. Check yourself

1. What does `-n demo` select? *The namespace.*
2. What does everything after `--` in `exec` mean? *The command to run inside the container.*
3. What does `apply -k` apply? *A kustomization directory.*
4. How does kubectl know which cluster to talk to? *From the kubeconfig file.*
5. What does `rollout status` do? *Waits until the Deployment has finished rolling out.*

## 9. Further reading

- kubectl reference: <https://kubernetes.io/docs/reference/kubectl/>
- Cheat sheet: <https://kubernetes.io/docs/reference/kubectl/quick-reference/>
- `gcloud container clusters get-credentials`: <https://cloud.google.com/sdk/gcloud/reference/container/clusters/get-credentials>
