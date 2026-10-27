# Terraform (and its HCL language)

## 1. What it is

Terraform is a command-line tool that builds cloud infrastructure from text files. You **describe** what should exist (a bucket, a service account, a Cloud Run service) in files written in **HCL** (HashiCorp Configuration Language), and Terraform works out what to create, change or delete to make reality match. A **provider** is a plug-in that knows one platform's API; here `hashicorp/google` (version 8.8.x). A **resource** is one thing Terraform manages. The **state** is a file in which Terraform remembers what it created. This repository was built with Terraform 1.17.0 and requires 1.9 or newer.

## 2. Why this repository uses it

The lesson needs a cluster, a key, an encrypted bucket and one precise role binding. Written as code, those pieces and their order (key first, then bucket) can be reviewed, repeated, tested without a cloud account, and removed with one command.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `infra/modules/*/` | Six reusable pieces (`project-services`, `network`, `gke-autopilot`, `kms-key`, `cmek-bucket`, `audit-logs`), each with `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, a README and tests. |
| `infra/environments/lab/` | The composition: calls the modules and wires them together. |
| `infra/environments/lab/lab.tfvars.example` | Example values for the offline plan. |
| `infra/environments/lab/.terraform.lock.hcl` | Pins the exact provider version and checksums. |
| `infra/environments/lab/backend.tf.example` | How to keep state in a bucket (not used by default). |
| `scripts/deploy.sh`, `create-project.sh`, `teardown.sh` | Run `terraform init`, `apply` and `destroy`. |

## 4. How it works underneath

1. `terraform init` downloads the provider into a hidden `.terraform/` folder and records its version and hashes in `.terraform.lock.hcl`. With `-backend=false` it does not set up remote state, so it needs no credentials.
2. `terraform validate` checks that the files are well formed and the arguments exist, without contacting any cloud.
3. `terraform plan` reads the files and the **state**, asks the provider what exists, and prints what it would change: `+` create, `~` change, `-` destroy. A resource that does not exist yet needs no cloud call, which is why this repository can plan offline (the one `data` source is skipped when its value is supplied, as the example variables file does). The provider still needs *a* token to start, so `make plan` sets a placeholder `GOOGLE_OAUTH_ACCESS_TOKEN`.
4. `terraform apply` performs the plan and writes the new state. `terraform destroy` removes everything in the state.

Terraform builds a **dependency graph**: if resource B uses `A.id`, B waits for A. When two things are related without a visible reference, you add `depends_on`. Values that are only known after creation are shown as `(known after apply)`.

A **module** is a folder of Terraform files used as a function: variables in, outputs out. The environment calls modules with `module "name" { source = "..." }`.

## 5. Walkthrough of this repository's use

### Version pins

`infra/environments/lab/versions.tf`

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
```

`required_version` refuses an older Terraform. `required_providers` names the provider, its registry address and the allowed versions: `~> 8.8` means 8.8 or newer but below 9.0. The modules use the wider window `>= 8.0, < 9.0`; the environment's lock file decides the exact version. The `provider "google"` block below it sets the project and region.

### Variables with checks

`infra/environments/lab/variables.tf`

```hcl
variable "project_number" {
  description = "Number of the lab project. The workload identity principal and the Cloud Storage service agent contain it, and it is not the project id."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must contain digits only; use gcloud projects describe PROJECT_ID --format='value(projectNumber)'."
  }
```

A `variable` is an input. The `validation` block runs when the plan is made: `can(regex("^[0-9]+$", var.project_number))` is true only if the text is digits. A project id in this place stops the plan with your message, which is exactly the lesson's common mistake.

### Locals, string building and a conditional lookup

`infra/environments/lab/main.tf`

```hcl
locals {
  services = [
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
  ]

  # The pod's identity under Workload Identity Federation for GKE: the project NUMBER, the pool of the project ID,
  # the namespace and the Kubernetes service account. The Python tool builds the same string (gke-triage principal).
  pod_principal = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.kubernetes_service_account}"

  # Cloud Storage reads and writes the key with its own service agent, not with the pod's identity.
  storage_service_agent_email = var.storage_service_agent_email != "" ? var.storage_service_agent_email : one(data.google_storage_project_service_account.gcs[*].email_address)
  storage_service_agent       = "serviceAccount:${local.storage_service_agent_email}"
```

- `locals` are named values computed once.
- `"${var.project_number}"` inside a string substitutes a value, so `pod_principal` is built with the project number and the project id exactly where the format needs them.
- `var.x != "" ? var.x : one(data.google_storage_project_service_account.gcs[*].email_address)` is a conditional (`condition ? a : b`): use the given email, or look it up. `[*]` turns a zero-or-one-element `count` resource into a list, and `one(list)` returns its single element (or null).

`infra/environments/lab/main.tf`

```hcl
data "google_storage_project_service_account" "gcs" {
  count = var.storage_service_agent_email == "" ? 1 : 0

  project = var.project_id

  depends_on = [module.services]
}
```

A `data` block reads something that already exists. This one asks Google for the Cloud Storage service agent (which also creates it). `count = ... ? 0 : 1` skips the lookup when the email is supplied, which is how the plan runs offline.

### Composition with explicit order

`infra/environments/lab/main.tf`

```hcl
module "key" {
  source = "../../modules/kms-key"

  project_id                  = var.project_id
  location                    = var.region
  key_ring_name               = "files"
  key_name                    = "files-key"
  labels                      = var.labels
  encrypter_decrypter_members = { storage_agent = local.storage_service_agent }

  depends_on = [module.services]
}

module "bucket" {
  source = "../../modules/cmek-bucket"

  project_id    = var.project_id
  name          = "${var.project_id}-files"
  location      = var.region
  kms_key_id    = module.key.id
  labels        = var.labels
  force_destroy = true

  # Step 2: the pod's principal reads and writes this bucket and nothing else. It holds no role on the key.
  object_users = { reader_writer = local.pod_principal }

  # Creating the bucket fails unless the service agent may already use the key.
  depends_on = [module.key]
```

Each argument sets a module variable. `module.key.id` reads that module's output. `depends_on = [module.key]` makes the bucket wait for the key and its grant, because a bucket with a default key cannot be created before the Cloud Storage service agent may use it, and no value flows between them that Terraform could see.

### Maps keyed by fixed labels, and dynamic blocks

`infra/modules/cmek-bucket/main.tf`

```hcl
# The pod's principal gets read and write of objects on this one bucket. It needs no role on the key.
resource "google_storage_bucket_iam_member" "object_user" {
  for_each = var.object_users

  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectUser"
  member = each.value
}
```

`for_each = var.object_users` creates one binding per entry. The key (`reader_writer`) is known when the plan is made; the member is the long principal string.

`infra/modules/gke-autopilot/main.tf`

```hcl
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
```

`dynamic` writes a nested block once per item of a collection.

### Outputs

`infra/environments/lab/outputs.tf`

```hcl
output "reader_writer_principal" {
  description = "The IAM member that holds roles/storage.objectUser on the bucket."
  value       = local.pod_principal
}
```

Outputs print after `apply`.

## 6. Try it yourself

```bash
terraform version
```
Expected: `Terraform v1.17.0` (1.9 or newer works for this repository).

```bash
terraform fmt -check -recursive infra; echo "exit=$?"
```
Expected: `exit=0` (all files are in canonical style).

```bash
cd infra/environments/lab && terraform init -backend=false -input=false >/dev/null && terraform validate
```
Expected: `Success! The configuration is valid.`

```bash
GOOGLE_OAUTH_ACCESS_TOKEN=placeholder terraform plan -input=false -lock=false -var-file=lab.tfvars.example | grep -E "^Plan"
```
Expected: `Plan: 17 to add, 0 to change, 0 to destroy.` Nothing is created. (The token only satisfies the provider's start-up; no call is made because the example file supplies the Cloud Storage service agent's email, so the data source is skipped.)

```bash
head -8 .terraform.lock.hcl
```
Expected: the provider address `registry.terraform.io/hashicorp/google`, `version = "8.8.1"` and the constraints.

## 7. Mistakes people make

- **Putting secrets in state.** State holds every attribute of every resource. This repository creates no secrets, and no keys.
- **Granting broad roles on the project.** Grant on the resource (see `workload-identity-federation.md`).
- **Editing the state by hand.** Use Terraform commands.
- **Using unknown values as `for_each` keys.** Key by fixed labels.
- **Committing `.terraform/` or `*.tfvars` with real ids.** `.gitignore` excludes them; only `*.tfvars.example` is tracked.
- **Not pinning the provider.** `.terraform.lock.hcl` is committed for the environment.
- **Running `apply` from an unknown directory or workspace.** The scripts `cd` into the environment first.

## 8. Check yourself

1. What does `terraform plan` change in the cloud? *Nothing; it only shows what apply would do.*
2. Why does `terraform init -backend=false` need no credentials? *It only downloads providers and sets up local files.*
3. What does `~> 8.8` allow? *8.8 and newer 8.x versions, not 9.0.*
4. What does `depends_on = [module.key]` do for the bucket? *Makes Terraform finish the key and its grant first, though no value flows between them.*
5. Why key `for_each` maps by fixed words? *Keys must be known at plan time; emails are not.*

## 9. Further reading

- Terraform documentation (v1.17): <https://developer.hashicorp.com/terraform/docs>
- Language reference: <https://developer.hashicorp.com/terraform/language>
- Data sources: <https://developer.hashicorp.com/terraform/language/data-sources>
- Google provider docs (8.x): <https://registry.terraform.io/providers/hashicorp/google/latest/docs>
