# gcp-gke-identity-and-keys

A GKE Autopilot cluster whose pod reads and writes an encrypted Cloud Storage bucket with no service account key anywhere, defined in Terraform, plus a small tool that tells the three ways that access fails (identity, authorization, key) apart from the error text or the audit log.

| | |
| --- | --- |
| **Lesson** | `/prep/gcp/project-gke-identity-and-keys`, "Keyless access to an encrypted bucket from GKE" (`data-structure-explainer/src/content/tracks/gcp/16-project-gke-identity-and-keys.md` in the Plainround app) |
| **Planned hours** | 10 |
| **Level** | Intermediate |
| **Architecture** | [ARCHITECTURE.md](ARCHITECTURE.md), decisions in [docs/adr](docs/adr) |
| **Author** | Sumit Srivastava |

## What is here

- `infra/`: Terraform (`google` provider `~> 8.8`), six modules and one environment, `lab`: the APIs, a VPC, an Autopilot cluster, a KMS key ring and key, the encrypted bucket with the pod's role, and the Cloud Storage data-access audit logs.
- `manifests/`: Kustomize. `base/` is the namespace, the `reader-writer` Kubernetes service account, the pod (`files`) and a network policy. `overlays/wrong-identity/` adds `files-default`, the same pod on the default service account (break one).
- `src/gke_triage/`: the `gke-triage` command: `classify` an error text, `audit` a Cloud Logging export, `table` the triage table from captured errors, `principal` and `check-binding` for the workload identity principal. Standard library only.
- `scripts/`: the lesson's runbook as the exact `gcloud`, `kubectl` and `terraform` commands: deploy, prove, three break scripts and their restores, teardown.
- `tests/`: unit tests (classifier, principal, manifests, Terraform guardrails), end-to-end tests of the program, and `tests/fixtures/` with the lesson's error texts.

**No Google Cloud project exists yet, so nothing has run on a cluster.** Everything that can be checked without one is: the Terraform is validated, planned offline and tested against a mock provider; the manifests are schema-validated and rendered; the classifier is tested on the lesson's own error texts. The six steps need the project; the commands for them are ready (see "Done when").

## Prerequisites

| Tool | Version | Used for |
| --- | --- | --- |
| Python | 3.12 or 3.13 (tested with 3.13; CI uses 3.12) | the `gke-triage` tool and tests |
| GNU Make | 3.81 or newer | every command below |
| Terraform | 1.9 or newer (tested with 1.17.0) | `make lint`, `make test`, `make validate`, deploy |
| tflint | 0.65 or newer (Google ruleset 0.41.0 via `tflint --init`) | `make lint` |
| checkov | 3.x (`uv tool install checkov` or `pip install checkov`) | `make validate` |
| kubectl | 1.30 or newer (the Kustomize renderer is built in) | `make lint`, deploy, the break scripts |
| shellcheck | 0.9 or newer | `make lint` |
| Google Cloud CLI (`gcloud`) with the GKE auth plugin | current | only the deploy steps |
| A Google Cloud billing account | a free-trial or paid one | only the deploy steps |

No Docker is needed. For the deploy steps you need Owner on the lab project you create.

## Run it on this machine (no cloud account)

```bash
make install        # .venv from the hash-pinned lock file
make test           # 70+ unit tests and the Terraform tests; the tool, the manifests and the guardrails
make test-e2e           # the program as a subprocess over the lesson's error texts
.venv/bin/gke-triage classify tests/fixtures/wrong-service-account.txt
.venv/bin/gke-triage table tests/fixtures
.venv/bin/gke-triage audit tests/fixtures/audit-log.json
.venv/bin/gke-triage principal --project-id example-sandbox-0000 --project-number 123456789012
```

`classify` on the first fixture prints:

```text
layer:       authorization
cause:       default service account
principal:   principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/default
permission:  storage.objects.create
first check: print the principal in the error: is it the account you meant?
fix:         set serviceAccountName on the pod to the account that holds the bucket role
```

## Test

```bash
make lint           # ruff, ruff format, mypy --strict, import-linter, shellcheck, terraform fmt -check, tflint, kustomize render
make test           # unit tests with coverage (domain + application >= 95%) and the Terraform tests with a mock provider
make validate       # terraform init -backend=false + validate on every module and the environment, an offline plan, checkov
make test-e2e       # the command-line program as a subprocess
make audit          # pip-audit over the locked dependencies
make check          # lint + test + validate
```

## Deploy to your own project

Put the project values in `.env` (copy `.env.example`; `MASTER_AUTHORIZED_CIDR` is your own public address as a `/32`), then:

```bash
scripts/create-project.sh    # gcloud projects create, gcloud billing projects link, writes infra/environments/lab/lab.tfvars
scripts/deploy.sh            # terraform apply (cluster, key, bucket, role, audit logs), get-credentials, kubectl apply -k manifests/base
scripts/prove.sh             # steps 1 and 2: the key, the principal, the keyless read/write, no secrets
scripts/break-wrong-sa.sh    # step 3: the default service account
scripts/break-missing-role.sh && scripts/restore-role.sh    # step 4
scripts/break-key.sh && scripts/restore-key.sh              # step 5
scripts/triage-table.sh      # step 6: the table from your captured errors
scripts/teardown.sh          # step 6: terraform destroy, delete the project
```

The commands the scripts run, for reading (variables as in the lesson; `PROJECT_NUMBER` is the number, not the id):

```bash
terraform -chdir=infra/environments/lab apply -var-file=lab.tfvars
gcloud container clusters get-credentials demo --region=$REGION
kubectl apply -k manifests/base
PRINCIPAL=principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/demo/sa/reader-writer
kubectl -n demo exec deploy/files -- sh -c 'echo hello > /tmp/a.txt && gcloud storage cp /tmp/a.txt gs://'$BUCKET'/a.txt && gcloud storage cat gs://'$BUCKET'/a.txt'
gcloud storage buckets remove-iam-policy-binding gs://$BUCKET --member=$PRINCIPAL --role=roles/storage.objectUser
gcloud kms keys versions disable 1 --key=files-key --keyring=files --location=$REGION
```

Terraform does the lesson's `gcloud kms`, `gcloud storage service-agent --authorize-cmek` and `buckets create --default-encryption-key` steps; the scripts keep the lesson's `gcloud` commands for the parts you break and fix by hand.

### Cost

The lesson's register is a same-day lab with everything deleted at the end. The cost is mostly the cluster:

| Resource | Cost while it runs |
| --- | --- |
| GKE Autopilot cluster management fee | about 0.10 US dollars per hour per cluster; one cluster per billing account is covered by a monthly free-tier credit, so it may cost nothing |
| Autopilot pod resources | about 0.03 US dollars per hour for the pod (more for the second pod during step 3) |
| Cloud KMS key | cents per month per active key version, plus cents per 10,000 operations |
| Cloud Storage, Cloud Logging, the VPC | a few objects, a few log lines, no external addresses, no NAT: cents |

Expect roughly 1 US dollar for a four-hour session and about 3 to 4 US dollars for a whole day without the free credit. Check the current prices before relying on these figures. Run `scripts/teardown.sh` the same day: it destroys the cluster and the bucket and deletes the project (30 days to complete, undoable with `gcloud projects undelete`). Key versions are destroyed 24 hours after a destroy request and cannot be recovered after that; a key ring can never be deleted, which is one more reason to use a project you throw away.

## Done when

The lesson's six steps, each with its proof. "Local" runs on this machine now; "needs the project" means only a real project and cluster can show it, and the command is ready.

| Step | Done when | Proof |
| --- | --- | --- |
| 1 | An object uploaded to the bucket shows your key as its encryption key. | **Local:** `terraform test` asserts the bucket's default key is the module's key and that only the Cloud Storage service agent may use it; `tests/unit/test_infrastructure_policy.py` asserts the bucket depends on the key being authorized first. **Needs the project:** `scripts/deploy.sh` ends by printing `gcloud storage objects describe gs://BUCKET/first.txt --format='value(kms_key)'`, and `scripts/prove.sh` checks it names `cryptoKeys/files-key`. |
| 2 | The service reads and writes the bucket, `kubectl get secrets` shows no credential file, and the logs show the identity you expected. | **Local:** `tests/unit/test_manifests.py` asserts the pod uses `reader-writer`, mounts no token, no secret volume, no `GOOGLE_APPLICATION_CREDENTIALS`; the Terraform principal equals `WorkloadPrincipal.uri` (a shared literal in a Python and a Terraform test); `gke-triage check-binding` catches the project id used for the number. **Needs the project:** `scripts/prove.sh` runs the lesson's test inside the pod, checks `kubectl -n demo get secrets` is empty, no key file in the pod, no user-managed key on any service account, and prints the principal from the audit log. |
| 3 | You find the permission-denied entry for the default service account, and you can say why it authenticated but was not authorized. | **Local:** `manifests/overlays/wrong-identity` is the lesson's copy without `serviceAccountName`, tested to differ from the real pod only in that line; `gke-triage classify tests/fixtures/wrong-service-account.txt` says `authorization / default service account`, and `gke-triage audit tests/fixtures/audit-log.json` extracts the principal ending `sa/default` and the permission from an audit entry. **Needs the project:** `scripts/break-wrong-sa.sh` applies the overlay, saves the real error to `captures/wrong-service-account.txt` and the real audit entries to `captures/wrong-service-account-audit.json`, and classifies both. The reason: the pod got a token (identity), but IAM found no role for `sa/default` on the bucket (authorization). |
| 4 | The denial names the missing permission on the bucket, and putting the role back fixes it without a restart. | **Local:** the classifier extracts `storage.objects.get` and the `sa/reader-writer` principal from the fixture. **Needs the project:** `scripts/break-missing-role.sh` removes the binding and captures the error; `scripts/restore-role.sh` adds it back, reruns the test and shows the pod's `RESTARTS` is still 0. |
| 5 | Reads of existing objects fail with an error that points at the key, not at IAM, and re-enabling the version restores access. | **Local:** the classifier separates the key failure from IAM on the fixtures (layer `key`, no principal); `modules/kms-key` is tested for rotation and a 24-hour destruction window. **Needs the project:** `scripts/break-key.sh` disables version 1 and reads `first.txt`, an object written before the break; `scripts/restore-key.sh` enables it. The real key error text must be captured from your run: the rules match "Cloud KMS key ... disabled/destroyed" and `cloudkms.*` permission denials; add your text as a fixture if it differs. |
| 6 | The table has three rows with real error text, and the project is scheduled for deletion (key versions are destroyed only after a waiting period). | **Local:** `make test-e2e` renders the table (`gke-triage table`) with one row per captured text and the layer for each. **Needs the project:** `scripts/triage-table.sh` renders your three captured errors into [docs/triage-table.md](docs/triage-table.md) format; `scripts/teardown.sh` ends by printing `DELETE_REQUESTED`. |

Review checklist from the lesson, mapped: key on the object (1), keyless pod and empty `get secrets` (2), expected principal in the log (2), default account denial explained (3), restore without restart (4), key error points at the key (5), a triage table with real text (6), project scheduled for deletion and the 24-hour key rule known (6).

## Stretch goals

| Stretch | Built? |
| --- | --- |
| Rotate the key and show old objects stay readable with the old version until rewritten | Not built; [ARCHITECTURE.md](ARCHITECTURE.md#extending-it) lists the commands. The module already rotates every 90 days. |
| Restrict the pod's access to one object prefix with an IAM condition | Not built; the extension note says where the condition goes. |
| An IAM deny policy that blocks deleting objects except for a break-glass group | Not built; the extension note says what to add. |

## Project structure

```text
.
├── README.md  ARCHITECTURE.md  CHANGELOG.md  LICENSE
├── Makefile  pyproject.toml  requirements.lock  requirements-dev.lock
├── .env.example  .editorconfig  .shellcheckrc  .checkov.yaml
├── .github/workflows/ci.yml        python, manifests, terraform
├── src/gke_triage/
│   ├── domain/                     WorkloadPrincipal, classify (Layer, Cause, Finding), AuditDenial; imports nothing else
│   ├── application/                diagnose, SummarizeDenials, BuildTriageTable, the ports; imports domain
│   ├── infrastructure/             audit log JSON reader, capture directory reader; imports application, domain
│   └── interfaces/                 the gke-triage command; imports all below
├── tests/
│   ├── unit/                       domain, application, infrastructure, interfaces, manifests, Terraform guardrails
│   ├── e2e/                        the program as a subprocess
│   └── fixtures/                   the lesson's error texts and an audit log export
├── manifests/
│   ├── base/                       namespace, service account, pod, network policy
│   └── overlays/wrong-identity/    the default-account copy (break one)
├── infra/
│   ├── .tflint.hcl
│   ├── modules/                    project-services, network, gke-autopilot, kms-key, cmek-bucket, audit-logs (README and tests/ each)
│   └── environments/lab/           main.tf, variables.tf, outputs.tf, lab.tfvars.example, tests/
├── scripts/                        create-project, deploy, prove, break-*/restore-*, triage-table, teardown
├── captures/                       where the break scripts save your real error texts (git-ignored)
└── docs/                           adr/ and triage-table.md
```

Dependency rule: `interfaces` -> `infrastructure` -> `application` -> `domain`, never upward; `domain` and `application` may not import `pathlib`, `json`, `argparse` or `subprocess`. Both run in `make lint` through import-linter.

## What is simplified for teaching

- One environment (`lab`), local Terraform state, one region, one project, one pod that sleeps.
- No application code: the lesson's "service" is a `google-cloud-cli` pod, as the lesson says. The only program is the triage tool.
- The API endpoint is public but limited to your address; Binary Authorization, Google Groups for RBAC and a restrictive egress policy are out of scope (the checkov skips in the modules say so).
- The key is a software key with default settings; no HSM, no external key.

## Verification record

Last verified on 2026-10-27 on macOS with Python 3.13, Terraform 1.17.0, tflint 0.65.0 (ruleset google 0.41.0), checkov 3.3.30, kubectl 1.x. The commands and their results are in the build report. Not verified: any behavior on a real cluster or against real Google Cloud error text.

## License

MIT, Copyright (c) 2026 Sumit Srivastava. See [LICENSE](LICENSE).
