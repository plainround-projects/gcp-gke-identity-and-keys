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

## Every Terraform file, module by module

The earlier sections explained the language by examples. This part covers every file of `infra/`, so that nothing is left out. First the vocabulary that every file uses.

- A **file** ending in `.tf` is read by Terraform together with all other `.tf` files in the same folder, as one configuration. The names `main.tf`, `variables.tf`, `outputs.tf` and `versions.tf` are only a convention for what goes where.
- A **block** is `type "label" "label" { ... }`. `resource "google_folder" "this" { ... }` declares a thing to manage; `google_folder` is its type, `this` is a name you choose to refer to it (`google_folder.this`). `variable`, `output`, `locals`, `module`, `data` and `terraform` are other block types.
- An **argument** is `name = value` inside a block. Values can be text in double quotes, numbers, `true`/`false`, lists `[...]`, and maps/objects `{ key = value }`.
- A **type** says what a variable may hold: `string`, `bool`, `number`, `list(string)` (a list of texts), `map(string)` (named texts), `object({ ... })` (a fixed set of named fields of given types), and `optional(type, default)` inside an object (a field that may be left out).
- An **expression** computes a value: `var.x` reads a variable, `local.x` a local, `module.m.out` a module's output, `resource_type.name.attribute` a resource's attribute. Functions are called like `length(list)`.
- `# ...` starts a comment.

The six modules all have the same `versions.tf`:

`infra/modules/network/versions.tf`

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0, < 9.0"
    }
  }
}
```

- `required_version = ">= 1.9"`: Terraform itself must be at least 1.9.
- `required_providers` says which plug-in provides the resources: `source = "hashicorp/google"` is its address in the public registry; `version = ">= 8.0, < 9.0"` allows any 8.x release. A module declares a window, and the environment's `~> 8.8` and lock file choose the exact version.

### Module `project-services`

`infra/modules/project-services/variables.tf`

```hcl
variable "project_id" {
  description = "Id of the existing project."
  type        = string
}

variable "services" {
  description = "APIs to enable."
  type        = list(string)

  validation {
    condition     = alltrue([for s in var.services : can(regex("\\.googleapis\\.com$", s))])
    error_message = "Every service must end in .googleapis.com."
  }
}
```

- `project_id`: the existing project. `services`: a list of API names. The check `alltrue([for s in var.services : can(regex("\\.googleapis\\.com$", s))])` builds a true/false for each name: does it end in `.googleapis.com`? (In an HCL string `\\.` is one backslash and a dot; the regular expression `\.` means a real dot, see `regular-expressions.md`.)

`infra/modules/project-services/main.tf`

```hcl
resource "google_project_service" "enabled" {
  for_each = toset(var.services)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
```

`for_each = toset(var.services)` makes one `google_project_service` per name; `toset` removes duplicates and makes the names the keys. `disable_on_destroy = false` leaves an API on when Terraform removes the setting, which keeps other things from breaking during teardown.

`infra/modules/project-services/outputs.tf`

```hcl
output "enabled_services" {
  description = "APIs enabled by this module."
  value       = sort([for s in google_project_service.enabled : s.service])
}
```

`sort([for s in google_project_service.enabled : s.service])` is the sorted list of enabled API names; the test compares against it.

### Module `network`

`infra/modules/network/variables.tf`

```hcl
variable "project_id" {
  description = "Project that owns the network."
  type        = string
}

variable "name" {
  description = "Network name; the subnet is NAME-nodes."
  type        = string
}

variable "region" {
  description = "Region of the subnet."
  type        = string
}

variable "nodes_cidr" {
  description = "Primary range of the subnet (nodes)."
  type        = string
  default     = "10.10.0.0/24"

  validation {
    condition     = can(cidrhost(var.nodes_cidr, 0))
    error_message = "nodes_cidr must be a CIDR block."
  }
}

variable "pods_cidr" {
  description = "Secondary range for pods."
  type        = string
  default     = "10.20.0.0/18"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a CIDR block."
  }
}

variable "services_cidr" {
  description = "Secondary range for services."
  type        = string
  default     = "10.30.0.0/22"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a CIDR block."
  }
}
```

Three address ranges with defaults (nodes `10.10.0.0/24`, pods `10.20.0.0/18`, services `10.30.0.0/22`; see `vpc-networking.md`). Each has the same check: `can(cidrhost(var.pods_cidr, 0))` is true only if the text is a valid range.

`infra/modules/network/main.tf`

```hcl
resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = var.name
  auto_create_subnetworks = false
}

# GKE adds its own allow rules for the cluster. Everything else is denied explicitly, with logging, at the lowest priority.
resource "google_compute_firewall" "deny_all_ingress" {
  project   = var.project_id
  name      = "${var.name}-deny-all-ingress"
  network   = google_compute_network.this.id
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Private Google Access lets nodes without external addresses reach Google APIs and gcr.io, which the pod needs.
resource "google_compute_subnetwork" "nodes" {
  project                  = var.project_id
  name                     = "${var.name}-nodes"
  region                   = var.region
  network                  = google_compute_network.this.id
  ip_cidr_range            = var.nodes_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}
```

- `google_compute_network.this`: a network with `auto_create_subnetworks = false` (custom mode: no subnets until you create them).
- `deny_all_ingress`: priority 65534, direction `INGRESS`, `source_ranges = ["0.0.0.0/0"]` (every address), a `deny` block for `protocol = "all"`, and `log_config` so each denial is recorded. A lower priority number wins; 65534 is almost the last. GKE adds its own allow rules for the cluster at higher priority.
- `nodes`: the subnet. `private_ip_google_access = true` lets nodes without a public address reach Google APIs. Two `secondary_ip_range` blocks create the named extra ranges `pods` and `services` that the cluster will use. `log_config` turns on flow logs: every 10 minutes, half of the connections sampled, all metadata.

`infra/modules/network/outputs.tf`

```hcl
output "network" {
  description = "Self link of the network."
  value       = google_compute_network.this.self_link
}

output "subnetwork" {
  description = "Self link of the node subnet."
  value       = google_compute_subnetwork.nodes.self_link
}

output "pods_range_name" {
  description = "Name of the secondary range for pods."
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range for services."
  value       = "services"
}
```

The network and subnet **self links** (full URLs) feed the cluster; the two range names are constants the cluster module needs.

### Module `gke-autopilot`

`infra/modules/gke-autopilot/variables.tf`

```hcl
variable "project_id" {
  description = "Project that owns the cluster."
  type        = string
}

variable "name" {
  description = "Cluster name."
  type        = string
}

variable "region" {
  description = "Region of the cluster."
  type        = string
}

variable "network" {
  description = "Self link of the VPC network."
  type        = string
}

variable "subnetwork" {
  description = "Self link of the subnet."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for services."
  type        = string
}

variable "master_cidr" {
  description = "A /28 for the control plane's private side, not used by anything else."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  description = "Ranges allowed to reach the API endpoint, name => CIDR. Your own address as /32 is enough."
  type        = map(string)

  validation {
    condition     = length(var.master_authorized_cidrs) > 0 && alltrue([for c in values(var.master_authorized_cidrs) : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Give at least one valid CIDR block, and never 0.0.0.0/0."
  }
}

variable "release_channel" {
  description = "RAPID, REGULAR or STABLE."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "deletion_protection" {
  description = "Refuse to delete the cluster. False in a sandbox so the teardown works."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels for the cluster."
  type        = map(string)
  default     = {}
}
```

- `project_id`, `name`, `region`, `network`, `subnetwork`, the two range names: plain texts the cluster needs. `master_cidr` is a `/28` for the control plane's private side (default `172.16.0.0/28`).
- `master_authorized_cidrs` is a map from a name to a range. The check: at least one entry (`length(...) > 0`) and every value is a valid range (`can(cidrhost(c, 0))`) that is **not** `0.0.0.0/0` (the whole internet). `&&` means "and".
- `release_channel` must be one of three words. `deletion_protection` defaults to false so the lab can be torn down. `labels` is a map of texts.

`infra/modules/gke-autopilot/main.tf`

```hcl
resource "google_container_cluster" "this" {
  #checkov:skip=CKV_GCP_65:Google Groups for RBAC needs a Workspace or Cloud Identity group; the lab uses the owner's own identity
  #checkov:skip=CKV_GCP_66:Binary Authorization needs an attestor and a policy; the lab runs one Google-published image pinned by digest
  #checkov:skip=CKV_GCP_69:Autopilot always runs the GKE metadata server and rejects a node_config block
  #checkov:skip=CKV_GCP_61:Autopilot runs Dataplane V2, which gives intranode visibility itself, and the provider rejects enable_intranode_visibility with enable_autopilot
  #checkov:skip=CKV_GCP_12:Autopilot runs Dataplane V2, which enforces NetworkPolicy; the cluster has no network_policy block to set
  project  = var.project_id
  name     = var.name
  location = var.region

  # Autopilot manages nodes, turns on Workload Identity Federation for GKE and applies hardening defaults.
  enable_autopilot    = true
  deletion_protection = var.deletion_protection
  resource_labels     = var.labels

  network    = var.network
  subnetwork = var.subnetwork

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Nodes get no external address; the API endpoint stays public but only the listed ranges may reach it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
    }
  }

  # No client certificate is issued; users authenticate with their Google identity.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  release_channel {
    channel = var.release_channel
  }

  # Control-plane and workload logs go to Cloud Logging, where the denials are found.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
}
```

- The five `#checkov:skip=` comments each name a checkov rule and a reason (see `checkov.md`).
- `enable_autopilot = true` makes Google manage the nodes (see `gke-autopilot.md`). `deletion_protection`, `resource_labels` come from variables.
- `ip_allocation_policy` names the secondary ranges for pods and services.
- `private_cluster_config`: `enable_private_nodes = true` gives nodes no public address; `enable_private_endpoint = false` keeps the API endpoint reachable from outside (but only from the authorized ranges); `master_ipv4_cidr_block` is the control plane's private range.
- `master_authorized_networks_config` with a `dynamic "cidr_blocks"` writes one block per entry of the map; `cidr_blocks.key` is the name and `cidr_blocks.value` the range.
- `master_auth { client_certificate_config { issue_client_certificate = false } }`: no client certificate is created; users sign in with their Google identity.
- `release_channel { channel = ... }` chooses how fast Google upgrades the cluster. `logging_config { enable_components = [...] }` sends system and workload logs to Cloud Logging, where the lesson looks for denials.

`infra/modules/gke-autopilot/outputs.tf`

```hcl
output "name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "location" {
  description = "Cluster region."
  value       = google_container_cluster.this.location
}

output "workload_pool" {
  description = "The workload identity pool of the project: PROJECT_ID.svc.id.goog."
  value       = "${var.project_id}.svc.id.goog"
}
```

The name, the location, and the workload pool name `PROJECT_ID.svc.id.goog` (built from the variable, not read from the cluster).

### Module `kms-key`

`infra/modules/kms-key/variables.tf`

```hcl
variable "project_id" {
  description = "Project that owns the key ring."
  type        = string
}

variable "location" {
  description = "Location of the key ring; a regional bucket needs a key in the same region."
  type        = string
}

variable "key_ring_name" {
  description = "Key ring name. Key rings cannot be deleted once created."
  type        = string
}

variable "key_name" {
  description = "Key name."
  type        = string
}

variable "rotation_period" {
  description = "How often a new key version becomes primary, in seconds with an s suffix (90 days by default)."
  type        = string
  default     = "7776000s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.rotation_period))
    error_message = "rotation_period must be a number of seconds ending in s, for example 7776000s."
  }
}

variable "destroy_scheduled_duration" {
  description = "How long a version waits between a destroy request and the irreversible destruction (at least 24 hours)."
  type        = string
  default     = "86400s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.destroy_scheduled_duration)) && tonumber(trimsuffix(var.destroy_scheduled_duration, "s")) >= 86400
    error_message = "destroy_scheduled_duration must be at least 86400s (24 hours)."
  }
}

variable "encrypter_decrypter_members" {
  description = "Members that may use the key to encrypt and decrypt (the Cloud Storage service agent), keyed by a fixed label."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Labels for the key."
  type        = map(string)
  default     = {}
}
```

- `rotation_period` is a number of seconds with an `s` (default `7776000s`, 90 days); `can(regex("^[0-9]+s$", ...))` enforces the shape.
- `destroy_scheduled_duration` default `86400s` (24 hours). The check `tonumber(trimsuffix(var.destroy_scheduled_duration, "s")) >= 86400` removes the `s`, turns the text into a number and demands at least a day: the shortest waiting time Google allows.
- `encrypter_decrypter_members` is a map from a fixed label to a member text; default empty.

`infra/modules/kms-key/main.tf`

```hcl
resource "google_kms_key_ring" "this" {
  project  = var.project_id
  name     = var.key_ring_name
  location = var.location
}

resource "google_kms_crypto_key" "this" {
  #checkov:skip=CKV_GCP_82:prevent_destroy would block the same-day teardown this lab ends with; a production key sets it
  name     = var.key_name
  key_ring = google_kms_key_ring.this.id
  purpose  = "ENCRYPT_DECRYPT"
  labels   = var.labels

  rotation_period = var.rotation_period

  # The shortest scheduled-destruction window (24 hours): a destroyed version cannot be recovered after it.
  destroy_scheduled_duration = var.destroy_scheduled_duration

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }
}

# Cloud Storage reads and writes the key with its own service agent, not with the pod's identity.
resource "google_kms_crypto_key_iam_member" "encrypter_decrypter" {
  for_each = var.encrypter_decrypter_members

  crypto_key_id = google_kms_crypto_key.this.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = each.value
}
```

See `cloud-kms.md` for what each part means. In Terraform terms: a key ring, a key in it with `purpose = "ENCRYPT_DECRYPT"`, the rotation and destruction settings, a `version_template` (algorithm and protection level), and one IAM binding per member (`for_each`).

`infra/modules/kms-key/outputs.tf`

```hcl
output "id" {
  description = "Key resource name, projects/P/locations/L/keyRings/R/cryptoKeys/K."
  value       = google_kms_crypto_key.this.id
}

output "key_name" {
  description = "Key name."
  value       = google_kms_crypto_key.this.name
}

output "key_ring_name" {
  description = "Key ring name."
  value       = google_kms_key_ring.this.name
}

output "encrypter_decrypter_members" {
  description = "Members that may use the key."
  value       = sort(values(var.encrypter_decrypter_members))
}
```

The key's full resource name (`id`), its short name, the ring's name, and the sorted members.

### Module `cmek-bucket`

`infra/modules/cmek-bucket/variables.tf`

```hcl
variable "project_id" {
  description = "Project that owns the bucket."
  type        = string
}

variable "name" {
  description = "Globally unique bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.name))
    error_message = "name must be 3-63 characters: lowercase letters, digits, dot, underscore and hyphen."
  }
}

variable "location" {
  description = "Bucket location; must match the key's location."
  type        = string
}

variable "kms_key_id" {
  description = "Resource name of the customer-managed key used as the bucket's default."
  type        = string
}

variable "object_users" {
  description = "Members that may read and write objects (roles/storage.objectUser on the bucket), keyed by a fixed label."
  type        = map(string)
  default     = {}
}

variable "force_destroy" {
  description = "Delete the bucket even when it holds objects. True only for a sandbox."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels for the bucket."
  type        = map(string)
  default     = {}
}
```

The bucket-name check is Google's rule (3 to 63 characters; lowercase letters, digits, dot, underscore, hyphen). `kms_key_id` is the key's resource name. `object_users` maps a fixed label to a member. `force_destroy` is true only in a lab.

`infra/modules/cmek-bucket/main.tf`

```hcl
resource "google_storage_bucket" "this" {
  #checkov:skip=CKV_GCP_62:A one-day lab needs no separate access-log bucket; the data-access audit logs record every call
  project  = var.project_id
  name     = var.name
  location = var.location
  labels   = var.labels

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy

  # Every new object is encrypted with this key unless the writer names another. The caller authorizes the Cloud Storage
  # service agent on the key first (kms-key module) and passes the dependency through depends_on.
  encryption {
    default_kms_key_name = var.kms_key_id
  }

  versioning {
    enabled = true
  }
}

# The pod's principal gets read and write of objects on this one bucket. It needs no role on the key.
resource "google_storage_bucket_iam_member" "object_user" {
  for_each = var.object_users

  bucket = google_storage_bucket.this.name
  role   = "roles/storage.objectUser"
  member = each.value
}
```

The `encryption { default_kms_key_name = ... }` block makes every new object use the customer-managed key (see `cloud-storage.md` and `cloud-kms.md`). The IAM binding gives `roles/storage.objectUser` to each member, on this bucket only.

`infra/modules/cmek-bucket/outputs.tf`

```hcl
output "name" {
  description = "Bucket name."
  value       = google_storage_bucket.this.name
}

output "object_users" {
  description = "Members granted roles/storage.objectUser on the bucket."
  value       = sort(values(var.object_users))
}
```

### Module `audit-logs`

`infra/modules/audit-logs/variables.tf`

```hcl
variable "project_id" {
  description = "Project whose Cloud Storage data access is logged."
  type        = string
}

variable "log_types" {
  description = "Audit log types to enable."
  type        = list(string)
  default     = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]

  validation {
    condition     = alltrue([for t in var.log_types : contains(["ADMIN_READ", "DATA_READ", "DATA_WRITE"], t)])
    error_message = "log_types may contain ADMIN_READ, DATA_READ and DATA_WRITE."
  }
}
```

`log_types` defaults to the three types and is checked against that list.

`infra/modules/audit-logs/main.tf`

```hcl
# Data-access audit logs record who read or wrote which object, including the denied calls step 3 looks for.
# They are off by default for Cloud Storage. This resource owns the audit configuration of the service in the project.
resource "google_project_iam_audit_config" "storage" {
  project = var.project_id
  service = "storage.googleapis.com"

  dynamic "audit_log_config" {
    for_each = toset(var.log_types)
    content {
      log_type = audit_log_config.value
    }
  }
}
```

`dynamic "audit_log_config"` with `for_each = toset(var.log_types)` writes one block per type; `audit_log_config.value` is the type. See `cloud-logging-audit-logs.md`.

`infra/modules/audit-logs/outputs.tf`

```hcl
output "log_types" {
  description = "Enabled audit log types."
  value       = sort(var.log_types)
}
```

### The `lab` environment

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
}

# Asking for the service agent also creates it, which must happen before it can be granted a role on the key.
# Skipped when the email is given (the offline plan and the tests do that).
data "google_storage_project_service_account" "gcs" {
  count = var.storage_service_agent_email == "" ? 1 : 0

  project = var.project_id

  depends_on = [module.services]
}

module "services" {
  source = "../../modules/project-services"

  project_id = var.project_id
  services   = local.services
}

module "network" {
  source = "../../modules/network"

  project_id = var.project_id
  name       = "lab"
  region     = var.region

  depends_on = [module.services]
}

module "cluster" {
  source = "../../modules/gke-autopilot"

  project_id              = var.project_id
  name                    = "demo"
  region                  = var.region
  network                 = module.network.network
  subnetwork              = module.network.subnetwork
  pods_range_name         = module.network.pods_range_name
  services_range_name     = module.network.services_range_name
  master_authorized_cidrs = var.master_authorized_cidrs
  labels                  = var.labels
}

# Step 1, in the order the lesson gives: the key, the service agent's right to use it, then the bucket.
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
}

# Step 3 looks for the denial in the data-access audit log, which is off by default for Cloud Storage.
module "audit" {
  source = "../../modules/audit-logs"

  project_id = var.project_id

  depends_on = [module.services]
}
```

- `locals`: the seven APIs the lab needs; `pod_principal`, the exact text that the Python tool also builds (the project **number**, the pool of the project **id**, the namespace and the service account); and the storage service agent's email, which is the given variable or, when empty, looked up with the `data` block. `var.x != "" ? var.x : one(data...[*].email_address)` is a conditional; `[*]` turns the zero-or-one copies into a list and `one(list)` takes the single element.
- The `data "google_storage_project_service_account"` block reads (and creates) Cloud Storage's service agent. `count = ... ? 0 : 1` skips it when the email is given, which is how the offline plan and the tests run. `depends_on = [module.services]` waits for the APIs.
- Each `module` block gives values to a module's variables. `module.network.network` reads another module's output; that creates the order.
- Step order in the file follows the lesson: the key first, then the bucket, which `depends_on` the key because creating a bucket with a default key fails unless the service agent may already use it.
- `module "audit"` turns on the data-access logs that step 3 reads.

`infra/environments/lab/versions.tf`

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
  }

  # Local state is enough for a one-day lab. For shared use, add a gcs backend (see backend.tf.example).
}

provider "google" {
  project = var.project_id
  region  = var.region
}
```

`~> 8.8` allows 8.8 and later 8.x. The `provider "google"` block sets the project and region for every resource. The comment says local state is enough for a one-day lab.

`infra/environments/lab/variables.tf`

```hcl
variable "project_id" {
  description = "Id of the lab project (created by scripts/create-project.sh)."
  type        = string
}

variable "project_number" {
  description = "Number of the lab project. The workload identity principal and the Cloud Storage service agent contain it, and it is not the project id."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must contain digits only; use gcloud projects describe PROJECT_ID --format='value(projectNumber)'."
  }
}

variable "region" {
  description = "Region for the cluster, the key ring and the bucket (the key and the bucket must match)."
  type        = string
  default     = "europe-west1"
}

variable "master_authorized_cidrs" {
  description = "Ranges allowed to reach the cluster's API endpoint, name => CIDR. Your own address as a /32."
  type        = map(string)
}

variable "storage_service_agent_email" {
  description = "Email of the Cloud Storage service agent (service-PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com). Leave empty to look it up, which also creates the agent; give it only to plan without credentials."
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Kubernetes namespace of the service."
  type        = string
  default     = "demo"
}

variable "kubernetes_service_account" {
  description = "Kubernetes service account that gets the bucket role."
  type        = string
  default     = "reader-writer"
}

variable "labels" {
  description = "Labels applied to every resource that supports them."
  type        = map(string)
  default = {
    environment = "lab"
    project     = "gke-identity-and-keys"
    managed-by  = "terraform"
  }
}
```

- `project_id` and `project_number`: the number must be digits only (the validation message tells you the command that prints it).
- `region` defaults to `europe-west1`; the key and the bucket must share it.
- `master_authorized_cidrs` is required: your own address as a `/32` (one address).
- `storage_service_agent_email` defaults to empty (look it up).
- `namespace` (default `demo`) and `kubernetes_service_account` (default `reader-writer`) name the pod's identity.
- `labels` has a default of three labels applied to every resource that supports them.

`infra/environments/lab/outputs.tf`

```hcl
output "cluster_name" {
  description = "Cluster name, for gcloud container clusters get-credentials."
  value       = module.cluster.name
}

output "region" {
  description = "Region of the cluster, the key and the bucket."
  value       = var.region
}

output "bucket" {
  description = "The encrypted bucket."
  value       = module.bucket.name
}

output "key" {
  description = "Resource name of the customer-managed key."
  value       = module.key.id
}

output "workload_pool" {
  description = "The project's workload identity pool."
  value       = module.cluster.workload_pool
}

output "reader_writer_principal" {
  description = "The IAM member that holds roles/storage.objectUser on the bucket."
  value       = local.pod_principal
}
```

The values the scripts and the learner need after `apply`: the cluster name for `get-credentials`, the region, the bucket, the key, the workload pool and the pod's principal.

`infra/environments/lab/lab.tfvars.example`

```hcl
# Copy to lab.tfvars and edit. The values below are placeholders; `make plan` uses this file as it is.
project_id     = "example-sandbox-0000"
project_number = "123456789012" # gcloud projects describe PROJECT_ID --format='value(projectNumber)'. Not the project id.
region         = "europe-west1"

# Leave empty on a real run: Terraform looks the agent up (which also creates it). Set only for the offline plan.
storage_service_agent_email = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"

# Who may reach the cluster's API endpoint. Replace with your own address as a /32 (203.0.113.0/24 is a documentation range).
master_authorized_cidrs = {
  laptop = "203.0.113.7/32"
}
```

A `.tfvars` file gives values to variables (`name = value`). This example is what `make plan` uses, so it holds placeholders: the example project id, number `123456789012`, a service-agent email that matches the number (so the data lookup is skipped), and the documentation address `203.0.113.7/32`. Copy it to `lab.tfvars` and edit for a real run.

`infra/environments/lab/backend.tf.example`

```hcl
# Copy to backend.tf for remote state. The bucket is created by hand, with versioning, before `terraform init`.
terraform {
  backend "gcs" {
    bucket = "EXAMPLE-terraform-state"
    prefix = "gcp-gke-identity-and-keys/lab"
  }
}
```

A **backend** says where the state file lives. By default it is local. `backend "gcs"` keeps it in a Cloud Storage bucket (`bucket`, plus a `prefix` for the folder inside). The file ends in `.example` so Terraform ignores it; copy it to `backend.tf` to use it.

### The lock file

`infra/environments/lab/.terraform.lock.hcl`

```hcl
# This file is maintained automatically by "terraform init".
# Manual edits may be lost in future updates.

provider "registry.terraform.io/hashicorp/google" {
  version     = "8.8.1"
  constraints = ">= 8.0.0, ~> 8.8, < 9.0.0"
  hashes = [
    "h1:cj2w8+P7qqGDbhG+PIJcXmtu0CMBNLqdTNLpLgvhJrw=",
    "zh:1510c0a5ec95676bf9df8f4c4798eb21f1ddb49f1d0bfc52e323fcdec5240bad",
    "zh:18122322d83564567bfa8c4075f1b33263bf30217345c4cf967e5d9fb7df6134",
    "zh:3468de1e43ad4bee6d5191c23be7dbb39f6c1559027c598f99869f7e7fe180ba",
    "zh:55bfd12669b8dd9913e5ee00df060c3f53c2976a92291262c02eaa0504e6b5d4",
    "zh:5b643a92495934a22c594aca095eace27c817d83ef896042e4360b87216285df",
    "zh:5e9326c8392700c2d8a998b19ff253b7fcbe01a39e14c5518233da1b98d4d99b",
    "zh:9522b2ed7cd335488c7a91509bb70cf134a318b697c38255ed184209d11f0436",
    "zh:a55f6fb2f998b39dad5bb107c4c1b7ff022aa54cc77fe31e98d3ae8894833ce4",
    "zh:a7509f8d1db99156bbf1b72e1acc25ccf093a8fd4af264464e1b054e90a87eb8",
    "zh:b3ad9d84fc076f71cdd1574ca417e7b565b79a2d1e7afcc5ec211f1aaa8c0227",
    "zh:f569b65999264a9416862bca5cd2a6177d94ccb0424f3a4ef424428912b9cb3c",
    "zh:fd2a9f9741792a11d7f1fa9affe080c8b40b93e5f6a0b61cb25dfcd9c87dc44e",
  ]
}
```

`terraform init` writes this file. It records the exact provider version chosen, the constraints that led to it, and `hashes`: fingerprints of the provider's package, so a tampered download is refused. Commit it so everybody gets the same provider. Each module's own lock file is not committed (`.gitignore`), because modules are only used through the environment.

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
