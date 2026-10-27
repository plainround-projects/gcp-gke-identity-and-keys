# kubernetes-validate

## 1. What it is

`kubernetes-validate` is a Python library that checks a Kubernetes manifest against the official **schema** of a chosen Kubernetes version, entirely offline. A schema (JSON Schema, here) is a machine-readable description of every field an object may have and its type. Version 1.37.0 is pinned in the dev lock file; it depends on `jsonschema`.

## 2. Why this repository uses it

There is no cluster to apply the manifests to. A typo such as `serviceAcountName`, a string where a number belongs, or a field that does not exist in the chosen version would only appear at deploy time. This check catches it in the unit tests.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `tests/unit/test_manifests.py` | `kubernetes_validate.validate(doc, "1.33", strict=True)` for every manifest. |
| `pyproject.toml` | `kubernetes-validate>=1.30` in the `dev` extra; a `mypy` override ignores its missing type information. |

## 4. How it works underneath

The package ships the Kubernetes API definitions for many versions. `validate(manifest, version, strict)` finds the schema for the manifest's `apiVersion` and `kind` in that version and runs `jsonschema` over the dictionary. With `strict=True`, fields that are not in the schema are errors (without it they are tolerated). A failure raises `kubernetes_validate.ValidationError` naming the problem.

## 5. Walkthrough of this repository's use

`tests/unit/test_manifests.py`

```python
K8S_VERSION = "1.33"


def load(path: str) -> list[dict[str, Any]]:
    return [doc for doc in yaml.safe_load_all((ROOT / path).read_text()) if doc]


def all_manifests() -> list[Path]:
    return sorted(p for p in ROOT.rglob("*.yaml") if p.name != "kustomization.yaml")


def deployment(path: str) -> dict[str, Any]:
    return next(doc for doc in load(path) if doc["kind"] == "Deployment")


@pytest.mark.parametrize("path", all_manifests(), ids=lambda p: str(p.relative_to(ROOT)))
def test_every_manifest_is_valid_against_the_kubernetes_schema(path):
    for doc in yaml.safe_load_all(path.read_text()):
        kubernetes_validate.validate(doc, K8S_VERSION, strict=True)
```

- `K8S_VERSION = "1.33"` fixes the Kubernetes version the manifests are validated against (the Autopilot cluster's release channel decides the real version; this is a conservative target).
- `all_manifests()` finds every `.yaml` under `manifests/` except the kustomization files (those are not Kubernetes objects).
- `@pytest.mark.parametrize("path", all_manifests(), ids=...)` runs one test per file, so a failure names the file.
- `yaml.safe_load_all` reads the documents; each goes to `validate`.

## 6. Try it yourself

```bash
.venv/bin/python -c "
import kubernetes_validate, yaml
doc = yaml.safe_load(open('manifests/base/serviceaccount.yaml'))
kubernetes_validate.validate(doc, '1.33', strict=True); print('valid')"
```
Expected: `valid`

```bash
.venv/bin/python -c "
import kubernetes_validate
bad = {'apiVersion': 'v1', 'kind': 'ServiceAccount', 'metadata': {'name': 'x'}, 'automountServiceAccountToken': 'maybe'}
kubernetes_validate.validate(bad, '1.33', strict=True)" 2>&1 | tail -1
```
Expected: a long `ValidationError` message that quotes the schema for the field (`'type': ['boolean', 'null']`) and ends with `On instance['automountServiceAccountToken']:` and `'maybe'`.

```bash
.venv/bin/python -m pytest tests/unit/test_manifests.py -q -p no:cacheprovider -k "valid_against"
```
Expected: `5 passed` (one per manifest file).

## 7. Mistakes people make

- **Validating without `strict=True`.** Misspelled fields pass silently.
- **Validating against the wrong version.** A field added later is rejected by an older schema.
- **Believing a valid manifest will run.** Schema validity does not check images, permissions or node capacity.
- **Validating `kustomization.yaml`.** It is not a Kubernetes object.

## 8. Check yourself

1. What does the library compare a manifest with? *The Kubernetes JSON schema of a chosen version.*
2. What does `strict=True` add? *Unknown fields are errors.*
3. Does it need a cluster? *No, it works offline.*
4. Why are `kustomization.yaml` files skipped? *They are not Kubernetes API objects.*
5. What does a valid result not prove? *That the pod will start or be allowed to run.*

## 9. Further reading

- kubernetes-validate: <https://pypi.org/project/kubernetes-validate/>
- Kubernetes API reference (1.33): <https://kubernetes.io/docs/reference/generated/kubernetes-api/v1.33/>
- JSON Schema: <https://json-schema.org/>
