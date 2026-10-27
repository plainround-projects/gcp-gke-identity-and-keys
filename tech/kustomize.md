# Kustomize

## 1. What it is

Kustomize combines and adjusts Kubernetes manifests without templating. A folder with a `kustomization.yaml` file lists the manifests ("resources") to include, and may add patches, name prefixes or labels. A **base** is the common set; an **overlay** is a folder that starts from a base and adds or changes things. The tool is built into `kubectl` (`kubectl kustomize DIR` prints the result; `kubectl apply -k DIR` applies it).

## 2. Why this repository uses it

The lesson needs the same pod twice: once correct, once without `serviceAccountName`. The base holds the correct pod; the overlay `wrong-identity` includes the base and adds the broken copy, so the learner applies it, watches the failure, and later deletes it.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `manifests/base/kustomization.yaml` | Lists the four base manifests. |
| `manifests/overlays/wrong-identity/kustomization.yaml` | Includes the base and one more manifest. |
| `Makefile` | `make lint-manifests` renders both. |
| `scripts/deploy.sh`, `break-wrong-sa.sh`, `teardown.sh` | Apply and delete with `-k`. |

## 4. How it works underneath

Kustomize reads the `resources:` list, loads each file or folder, and merges everything into one stream of objects separated by `---`. Paths are relative to the kustomization file. `../../base` goes up two folders to the base. Nothing is sent to a cluster by rendering.

## 5. Walkthrough of this repository's use

`manifests/base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - serviceaccount.yaml
  - deployment.yaml
  - networkpolicy.yaml
```

- `apiVersion` and `kind: Kustomization` identify the file type.
- `resources:` is the list of manifests in this folder, in the order written (kustomize sorts the output so a namespace comes before the objects that use it).

`manifests/overlays/wrong-identity/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - files-default.yaml
```

`../../base` pulls in the whole base, and `files-default.yaml` adds the extra Deployment. The overlay therefore renders namespace, service account, the correct pod, the network policy and the wrong pod.

## 6. Try it yourself

```bash
kubectl kustomize manifests/base | grep -c "^kind:"
```
Expected: `4`

```bash
kubectl kustomize manifests/overlays/wrong-identity | grep -c "^kind:"
```
Expected: `5`

```bash
make lint-manifests
```
Expected: no output and exit status 0.

## 7. Mistakes people make

- **A resource path that does not exist.** Rendering fails with an error naming the path.
- **Editing the rendered output** instead of the sources.
- **Forgetting that an overlay includes the base entirely.** Deleting the overlay also deletes the base objects unless you only delete the extra file (the teardown uses `--ignore-not-found`).
- **Mixing `apply -k` and `apply -f` for the same objects.** Stick to one.

## 8. Check yourself

1. What is a base? *The common set of manifests.*
2. What is an overlay? *A folder that includes a base and adds or changes things.*
3. What does `kubectl kustomize` do? *Renders the manifests to the screen without applying.*
4. What does `../../base` mean? *Two folders up, then `base`.*
5. How many objects does the overlay render? *Five.*

## 9. Further reading

- Kustomize: <https://kubectl.docs.kubernetes.io/references/kustomize/>
- In kubectl: <https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>
