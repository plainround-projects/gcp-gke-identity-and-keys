# PyYAML

## 1. What it is

PyYAML is a Python library that reads and writes YAML (see `yaml.md`). `yaml.safe_load(text)` turns YAML text into Python dictionaries, lists, strings and numbers. "Safe" means it builds only plain data and never runs code hidden in the file. Version 6.0.3 is pinned in the lock file.

## 2. Why this repository uses it

The tests check the Kubernetes manifests as **data**: is the pod's service account the right one, is there a secret volume, is the image pinned? To do that they must read the YAML files. PyYAML is a development dependency, not part of the `gke-triage` program, which has no run-time dependencies. `types-PyYAML` gives `mypy` the type information.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `tests/unit/test_manifests.py` | Loads each manifest with `yaml.safe_load_all` and asserts properties. |
| `pyproject.toml` | Lists `pyyaml` and `types-PyYAML` in the `dev` extra. |

## 4. How it works underneath

PyYAML parses the text into a tree of YAML nodes and converts each node to a Python object: a mapping becomes a `dict`, a sequence a `list`, a plain scalar a `str`, `int`, `float`, `bool` or `None` depending on how it looks. A file with several documents separated by `---` is read with `safe_load_all`, which yields one object per document.

## 5. Walkthrough of this repository's use

`tests/unit/test_manifests.py`

```python
ROOT = Path(__file__).resolve().parents[2] / "manifests"
K8S_VERSION = "1.33"


def load(path: str) -> list[dict[str, Any]]:
    return [doc for doc in yaml.safe_load_all((ROOT / path).read_text()) if doc]


def all_manifests() -> list[Path]:
    return sorted(p for p in ROOT.rglob("*.yaml") if p.name != "kustomization.yaml")


def deployment(path: str) -> dict[str, Any]:
```

- `yaml.safe_load_all(path.read_text())` returns each document of the file; `if doc` skips empty ones.
- `load(path)` returns a list of dictionaries; `deployment(path)` picks the first one whose `kind` is `Deployment` with `next(... for ... if ...)`, a generator expression that stops at the first match.

The assertions use the data directly:

`tests/unit/test_manifests.py`

```python
def test_the_service_deployment_runs_as_the_reader_writer_account_in_the_demo_namespace():
    spec = deployment("base/deployment.yaml")
    assert spec["metadata"]["namespace"] == "demo"
    assert spec["spec"]["template"]["spec"]["serviceAccountName"] == "reader-writer"


def test_the_wrong_identity_copy_has_no_service_account_name_so_it_runs_as_default():
```

`spec["spec"]["template"]["spec"]["serviceAccountName"]` follows the same nesting the YAML has: Deployment, its pod template, the pod's spec.

## 6. Try it yourself

```bash
.venv/bin/python -c "
import yaml
d = yaml.safe_load(open('manifests/base/serviceaccount.yaml'))
print(d['kind'], d['metadata']['name'], d['automountServiceAccountToken'])"
```
Expected: `ServiceAccount reader-writer False`

```bash
.venv/bin/python -c "
import yaml
print([d['kind'] for d in yaml.safe_load_all(open('manifests/base/deployment.yaml'))])"
```
Expected: `['Deployment']`

```bash
.venv/bin/python -c "import yaml; print(yaml.safe_load('a: no\nb: 22:22\nc: \"22:22\"\nd: 1.10'))"
```
Expected: `{'a': False, 'b': 1342, 'c': '22:22', 'd': 1.1}`. PyYAML follows YAML 1.1: bare `no` becomes `False`, `22:22` becomes the number 1342 (a base-60 time), and `1.10` loses its zero. The quoted `"22:22"` stays text. Quote values that must stay text.

## 7. Mistakes people make

- **Using `yaml.load` without a loader.** It can construct arbitrary objects. Use `safe_load`.
- **Forgetting multi-document files.** `safe_load` fails on `---`; use `safe_load_all`.
- **Letting values change type.** Quote anything that must stay text.
- **Putting data checks in prose.** Here they are tests.

## 8. Check yourself

1. What does "safe" mean in `safe_load`? *Only plain data types are built; no code runs.*
2. Which function reads a file with several `---` documents? *`yaml.safe_load_all`.*
3. What Python type is a YAML mapping? *`dict`.*
4. Why is PyYAML only a development dependency? *Only the tests read YAML; the program does not.*
5. What does `next(x for x in items if ...)` return? *The first matching item.*

## 9. Further reading

- PyYAML documentation: <https://pyyaml.org/wiki/PyYAMLDocumentation>
- YAML 1.1 specification (the version PyYAML follows): <https://yaml.org/spec/1.1/>
