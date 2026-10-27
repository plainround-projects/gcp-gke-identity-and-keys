# Technology notes

One file per technology this repository uses, written for a reader who has never met it. Each file explains what the thing is, why the repository uses it, where it appears, how it works, then walks through this repository's own files line by line, with commands you can run and questions to check yourself.

## Ten minutes? Read these three

1. [workload-identity-federation.md](workload-identity-federation.md): how a pod gets a Google identity with no key, and why "permission denied" is not "not logged in".
2. [cloud-kms.md](cloud-kms.md): the customer-managed key, who uses it, and the kill switch.
3. [kubernetes.md](kubernetes.md): the pod, its service account and the settings that keep it keyless and locked down.

## Reading order

**The language and how the project is built**

| File | Role |
| --- | --- |
| [python.md](python.md) | The language of the `gke-triage` tool and the tests (3.12+). |
| [regular-expressions.md](regular-expressions.md) | The patterns that recognize error messages and validate identifiers. |
| [argparse.md](argparse.md) | The command-line interface of `gke-triage`. |
| [json.md](json.md) | The audit-log export the tool reads. |
| [pyproject-toml.md](pyproject-toml.md) | `pyproject.toml` and TOML: metadata and every tool's settings. |
| [pip-lock-files.md](pip-lock-files.md) | Virtual environment, hash-pinned lock files, `uv`, `pip-audit`. |
| [make.md](make.md) | The `Makefile`. |
| [bash.md](bash.md) | The runbook scripts under `scripts/`. |
| [unix-command-line-tools.md](unix-command-line-tools.md) | `grep`, `sed`, `tee`, `find` and friends. |
| [git.md](git.md) | The history and `.gitignore`. |
| [editorconfig.md](editorconfig.md) | One formatting habit for every editor. |

**Google Cloud**

| File | Role |
| --- | --- |
| [workload-identity-federation.md](workload-identity-federation.md) | Keyless identity for pods. |
| [iam-and-service-accounts.md](iam-and-service-accounts.md) | Roles, bindings and principals. |
| [gke-autopilot.md](gke-autopilot.md) | The cluster. |
| [cloud-storage.md](cloud-storage.md) | The bucket. |
| [cloud-kms.md](cloud-kms.md) | The key. |
| [cloud-logging-audit-logs.md](cloud-logging-audit-logs.md) | Finding the denial. |
| [vpc-networking.md](vpc-networking.md) | The network under the cluster. |
| [gcloud-cli.md](gcloud-cli.md) | The command-line tool the scripts use. |

**Kubernetes**

| File | Role |
| --- | --- |
| [kubernetes.md](kubernetes.md) | The objects in `manifests/`. |
| [kustomize.md](kustomize.md) | Base and overlay. |
| [kubectl.md](kubectl.md) | The client. |
| [yaml.md](yaml.md) | The format of the manifests. |
| [pyyaml.md](pyyaml.md) | Reading the manifests in tests. |
| [kubernetes-validate.md](kubernetes-validate.md) | Checking them against the schema, offline. |

**Infrastructure as code**

| File | Role |
| --- | --- |
| [terraform.md](terraform.md) | The code in `infra/`. |
| [terraform-test.md](terraform-test.md) | Offline tests with a mock provider. |
| [tflint.md](tflint.md) | Linter for the Terraform. |
| [checkov.md](checkov.md) | Security scanner and recorded exceptions. |

**Tests and quality gates**

| File | Role |
| --- | --- |
| [pytest.md](pytest.md) | The test runner and coverage. |
| [ruff.md](ruff.md) | Linter and formatter. |
| [mypy.md](mypy.md) | Type checker. |
| [import-linter.md](import-linter.md) | Enforces the layer rule. |
| [shellcheck.md](shellcheck.md) | Linter for the shell scripts. |
| [github-actions.md](github-actions.md) | The CI workflow that runs it all. |

The notes describe the code as it is. When the code changes, update the file that quotes it.
