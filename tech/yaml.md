# YAML

## 1. What it is

YAML is a plain-text format for structured data, designed to be easy for people to read. It has three building blocks: **mappings** (`key: value` pairs), **sequences** (lists, one `- item` per line) and **scalars** (text, numbers, `true`/`false`). **Indentation with spaces** shows nesting; tabs are not allowed. Lines starting with `#` are comments.

## 2. Why this repository uses it

Kubernetes, Kustomize, GitHub Actions and the checkov scanner all take their instructions in YAML. This repository's manifests are the main case.

## 3. Where it appears

| Path | What it holds |
| --- | --- |
| `manifests/base/*.yaml` | Namespace, service account, deployment and network policy (see `kubernetes.md`). |
| `manifests/base/kustomization.yaml`, `manifests/overlays/wrong-identity/*.yaml` | The kustomization and the wrong-identity overlay (see `kustomize.md`). |
| `.github/workflows/ci.yml` | The CI jobs (see `github-actions.md`). |
| `.checkov.yaml` | Which scanners to run (see `checkov.md`). |
| `tests/unit/test_manifests.py` | Reads the manifests back as data (see `pyyaml.md`). |

## 4. How it works underneath

A program reads the text and builds data in memory: a mapping becomes a dictionary, a sequence becomes a list. The indentation is the structure, so one wrong space changes the meaning. Two traps: YAML parsers guess types (in YAML 1.1, which PyYAML and some other tools follow, bare `no`, `yes` and `on` become booleans and `22:22` becomes a number), and a value that contains `: ` or begins with `*` or `{` needs quotes.

Inline forms exist too: `[a, b]` is a list and `{x: 1}` a mapping on one line. A `|` after a key starts a block of literal lines (used for multi-line shell commands).

## 5. Walkthrough of this repository's use

A manifest's skeleton:

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
```

- Top-level keys `apiVersion`, `kind`, `metadata`, `spec` are mappings; `metadata.labels` is a mapping nested one level deeper (two more spaces).
- `replicas: 1` is a number; `app: files` a string.
- `selector.matchLabels` and `template.metadata.labels` both hold `app: files`.

A list of mappings:

`manifests/base/deployment.yaml`

```yaml
      containers:
        - name: tool
          image: gcr.io/google.com/cloudsdktool/google-cloud-cli:590.0.1-slim@sha256:2a5368c4f3e25f7e202ccbd7b63e4128380d8fd683266f7f015c5d0afcc8f3be
```

`containers:` is a sequence; each item starts with `- ` and is a mapping (`name`, `image`, ...). Inline forms appear too: `command: ["sleep", "infinity"]` is a list on one line, and `emptyDir: {}` is an empty mapping.

The kustomization is a short mapping with one list:

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

The workflow's skeleton:

`.github/workflows/ci.yml`

```yaml
jobs:
  python:
    name: Format, lint, types, import rules, unit and end-to-end tests with coverage, dependency audit
    runs-on: ubuntu-latest
    steps:
```

`python:` is a job name; under `steps:` each item begins with `- ` and is a mapping (`uses:`, `with:` or `run:`).

## The CI workflow, whole

`.github/workflows/ci.yml`

```yaml
name: ci

on: [push, pull_request]

permissions:
  contents: read

jobs:
  python:
    name: Format, lint, types, import rules, unit and end-to-end tests with coverage, dependency audit
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: make lint-python test-python test-e2e
      - run: make lint-manifests
      - run: make audit

  terraform:
    name: Terraform format, tflint, validate, offline plan, policy tests, checkov
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.17.0"
          terraform_wrapper: false
      - uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: v0.65.0
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - run: pip install checkov==3.3.30
      - run: make lint-terraform test-terraform validate
```

- `name: ci` names the workflow. `on: [push, pull_request]` starts it on every push and every pull request. `permissions: contents: read` gives its token read access to the repository and nothing else.
- `jobs:` has two jobs, `python` and `terraform`. They run at the same time, each on a fresh Ubuntu machine (`runs-on: ubuntu-latest`). Each `name:` is the label shown in the web page.
- A `steps` item is either `uses:` (a ready-made action, with `with:` for its inputs) or `run:` (a shell command). `actions/checkout@v4` copies the repository onto the machine; `actions/setup-python@v5` installs Python 3.12; `hashicorp/setup-terraform@v3` installs Terraform 1.17.0 (`terraform_wrapper: false` keeps the plain command); `terraform-linters/setup-tflint@v4` installs tflint `v0.65.0`; `pip install checkov==3.3.30` installs checkov at a fixed version.
- The `run:` lines call `make` targets, so CI runs exactly what you run: `make lint-python test-python test-e2e`, `make lint-manifests` (this one needs `kubectl`, which the Ubuntu runner already has), `make audit`, and `make lint-terraform test-terraform validate`.

## 6. Try it yourself

```bash
kubectl kustomize manifests/base >/dev/null && echo "manifests parse"
```
Expected: `manifests parse`.

```bash
.venv/bin/python -c "
import yaml
d = yaml.safe_load(open('manifests/base/deployment.yaml'))
print(d['kind'], d['spec']['replicas'], d['spec']['template']['spec']['containers'][0]['command'])"
```
Expected: `Deployment 1 ['sleep', 'infinity']`

```bash
actionlint .github/workflows/ci.yml && echo "workflow parses"
```
Expected: `workflow parses`.

## 7. Mistakes people make

- **Tabs for indentation.** Not allowed.
- **Inconsistent indentation** moving a key to the wrong parent.
- **Unquoted special values** (`yes`, `no`, `1.10`, `22:22`, version numbers). Quote them.
- **Forgetting the space after the colon** (`key:value` is a plain string).
- **Confusing a string with a list** (`command: a b` vs `command: [a, b]`). Check what the tool expects.

## 8. Check yourself

1. What shows nesting in YAML? *Indentation with spaces.*
2. How do you write a list item? *A line starting with `- `.*
3. Why quote values like `22:22`? *Unquoted, YAML 1.1 reads it as a number; quotes keep it text.*
4. What does `command: ["sleep", "infinity"]` mean? *A list of two items: the program and its argument.*
5. How do you comment a line? *Start it with `#`.*

## 9. Further reading

- YAML 1.2 specification: <https://yaml.org/spec/1.2.2/>
- Kubernetes object syntax: <https://kubernetes.io/docs/concepts/overview/working-with-objects/>
- Workflow syntax: <https://docs.github.com/en/actions/writing-workflows/workflow-syntax-for-github-actions>
