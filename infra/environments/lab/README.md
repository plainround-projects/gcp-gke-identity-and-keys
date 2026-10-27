# lab environment

The composition for a same-day lab project: APIs, network, Autopilot cluster, KMS key, encrypted bucket with the pod's role, and the Cloud Storage audit logs. Every module is in `../../modules`.

## Variables

See `variables.tf`; `lab.tfvars.example` shows every value with placeholders. `scripts/create-project.sh` writes the real `lab.tfvars` (git-ignored). `project_number` is the number, not the id. `master_authorized_cidrs` must be your own address as a /32 (never `0.0.0.0/0`; a module rule rejects it).

## Validate without credentials

```bash
cd infra/environments/lab
terraform init -backend=false
terraform validate
GOOGLE_OAUTH_ACCESS_TOKEN=offline-placeholder terraform plan -var-file=lab.tfvars.example   # 17 resources to add, no API call
terraform test                                                                             # principal, key and bucket wiring
```

The offline plan works because the Cloud Storage service agent's email is given in the example variables file (a real run leaves it empty so Terraform looks it up, which also creates the agent), and nothing else reads from Google Cloud.

## Outputs

`cluster_name`, `region`, `bucket`, `key`, `workload_pool`, `reader_writer_principal`.

## State

Local. For shared use copy `backend.tf.example` to `backend.tf`, create the bucket (versioning on) and run `terraform init -migrate-state`.
