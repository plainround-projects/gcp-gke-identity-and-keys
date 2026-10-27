# Checkov

## 1. What it is

Checkov is a **security and compliance scanner** for infrastructure files. It reads Terraform, Dockerfiles, Kubernetes YAML and GitHub workflows and compares them with hundreds of built-in policies ("encrypt this", "do not allow public access", "set a user in the Dockerfile"). Each policy has an id like `CKV_GCP_62`. It runs offline on the files. Version 3.3.30 was used.

## 2. Why this repository uses it

The rule set asks for least privilege and checked infrastructure. Checkov catches risky settings that look fine to Terraform, and forces a recorded reason for every exception.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `.checkov.yaml` | Which frameworks to scan and which paths to skip. |
| `Makefile` | `make security` runs `checkov --config-file .checkov.yaml`; `make validate` includes it. |
| `infra/**/main.tf` | `#checkov:skip=ID:reason` comments inside resources record reviewed exceptions. |
| `.github/workflows/ci.yml` | Installs checkov 3.3.30 and runs `make validate`. |

## 4. How it works underneath

Checkov parses the files into a graph of resources, evaluates each policy against the matching resource type, and prints PASSED, FAILED or SKIPPED per check. A skip is written next to the resource as a comment `#checkov:skip=CKV_ID:reason`, which keeps the justification in the code review. The `secrets` framework looks for strings that resemble keys or passwords.

## 5. Walkthrough of this repository's use

`.checkov.yaml`

```yaml
# make security
directory:
  - .
framework:
  - terraform
  - kubernetes
  - kustomize
  - github_actions
  - secrets
skip-path:
  - .venv
  - infra/environments/lab/.terraform
quiet: true
compact: true
```

- `directory: [.]` scan the repository root; `skip-path` leaves out the virtual environment and downloaded Terraform files.
- `framework: [...]` lists the scanners to use for the file types in this repository.
- `quiet: true` and `compact: true` print only failures and keep output short.

Where the Terraform deviates from a policy, a comment records why:

- `CKV_GCP_65`, `CKV_GCP_66`, `CKV_GCP_69`, `CKV_GCP_12`, `CKV_GCP_61` on the cluster: Google Groups for RBAC and Binary Authorization need extra setup that a same-day lab does not have; Autopilot always runs the metadata server, enforces network policy and provides intranode visibility itself, and the provider rejects the matching settings.
- `CKV_GCP_82` on the key: `prevent_destroy` would block the same-day teardown.
- `CKV_GCP_62` on the bucket: no separate access-log bucket in a one-day lab; the data-access audit logs record every call.

The `kubernetes` and `kustomize` frameworks also scan `manifests/`; the pod sets resource limits, probes, a security context and a pinned image digest so those checks pass.

## 6. Try it yourself

```bash
checkov --version
```
Expected: `3.3.30`

```bash
make security
```
Expected: for each framework a line `Passed checks: N, Failed checks: 0, Skipped checks: M`. No `FAILED` lines.

Remove a skip to see the finding: delete one `#checkov:skip=` line in a module, run `checkov -d infra --framework terraform --quiet --compact`, read the `FAILED for resource: ...` block, then restore the line (`git checkout infra`).

## 7. Mistakes people make

- **Skipping a check with no reason.** Always write the reason after the id.
- **Skipping to get green.** Fix real problems; skip only reviewed trade-offs for a lab.
- **Scanning the virtual environment.** `skip-path` excludes it.
- **Treating "secrets" hits as certain.** They are heuristics; placeholders such as `"placeholder"` in tests are skipped with a note.

## 8. Check yourself

1. What does an id like `CKV_GCP_62` identify? *One checkov policy (here: bucket access logging).*
2. How do you record an accepted exception? *A `#checkov:skip=ID:reason` comment on the resource.*
3. Why must a skip carry a reason? *So a reviewer can judge it.*
4. What does the `secrets` framework look for? *Strings that look like passwords or keys.*
5. What does `quiet: true` change? *Only failures are printed in detail.*

## 9. Further reading

- Checkov documentation: <https://www.checkov.io/>
- Suppressing and skipping policies: <https://www.checkov.io/2.Basics/Suppressing%20and%20Skipping%20Policies.html>
- Policy index: <https://www.checkov.io/5.Policy%20Index/all.html>
