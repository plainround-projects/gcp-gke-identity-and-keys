# `terraform test` (native Terraform tests)

## 1. What it is

`terraform test` is a built-in Terraform command that runs test files ending in `.tftest.hcl`. Each file contains `run` blocks. A run executes a plan (or an apply) with chosen variable values and then checks **assertions**: true/false conditions about the result. With a **mock provider** the whole thing runs offline: Terraform pretends to be Google instead of calling it. The feature needs Terraform 1.7 or newer (mock providers) and is used here with 1.17.

## 2. Why this repository uses it

The "no credentials needed" rule: the least-privilege wiring (which identity gets which role on what, and in what order) can be tested on a laptop. A test fails if a module grants the wrong role, a bad variable is accepted, the principal string changes, or a setting regresses.

## 3. Where it appears

| Path | What it checks |
| --- | --- |
| `infra/modules/kms-key/tests/key.tftest.hcl` | Rotation and the 24-hour destruction window; only the listed member may use the key. |
| `infra/modules/cmek-bucket/tests/bucket.tftest.hcl` | The key is the bucket's default; private bucket; only `objectUser`. |
| `infra/modules/gke-autopilot/tests/cluster.tftest.hcl` | Autopilot, private nodes, restricted endpoint, no client certificate, bad ranges rejected. |
| `infra/modules/network/tests/network.tftest.hcl` | Private Google Access, flow logs, explicit deny-all rule. |
| `infra/modules/audit-logs/tests/audit.tftest.hcl` | Data-access logs for Cloud Storage. |
| `infra/modules/project-services/tests/services.tftest.hcl` | APIs enabled, bad names rejected. |
| `infra/environments/lab/tests/principal.tftest.hcl` | The pod principal equals the literal the Python test asserts; only that principal uses the bucket and only the storage agent uses the key. |
| `Makefile` | `test-terraform` loops over every folder that has a `tests/` directory. |

## 4. How it works underneath

Terraform loads the module in the current folder, applies the test's `variables`, and for each `run` makes a plan (`command = plan`) in memory. `mock_provider "google" {}` replaces the real provider: computed attributes (emails, URLs, ids) get random placeholder values, and nothing leaves your machine. Assertions are evaluated against resource attributes (inside a module under test) or module outputs (from an environment). `expect_failures = [var.name]` states that this run *should* fail validation of that variable; the run passes only if it does.

Two limits shape the tests: placeholders are random strings, so an assertion cannot compare an email to a literal; and a list in a variable differs from a tuple literal, so comparisons use `tolist(...)` or `jsonencode(...)`.

## 5. Walkthrough of this repository's use

`infra/modules/kms-key/tests/key.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id                  = "example-sandbox-0000"
  location                    = "europe-west1"
  key_ring_name               = "files"
  key_name                    = "files-key"
  encrypter_decrypter_members = { storage_agent = "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com" }
}

run "the_key_rotates_and_waits_24_hours_before_destruction" {
  command = plan

  assert {
    condition     = google_kms_crypto_key.this.rotation_period == "7776000s" && google_kms_crypto_key.this.destroy_scheduled_duration == "86400s"
    error_message = "90-day rotation and a 24-hour destruction window are the defaults."
  }
}

run "only_the_listed_member_may_use_the_key" {
```

- `mock_provider "google" {}`: use the fake provider.
- `variables { ... }` at the top gives defaults to every run.
- `run "name" { command = plan; assert { condition = ...; error_message = ... } }`: one test. `condition` is any expression; the run fails with the message if it is false. `alltrue([for ... : ...])` checks every item of a collection.

A rejection test:

`infra/modules/kms-key/tests/key.tftest.hcl`

```hcl
run "a_destruction_window_under_24_hours_is_rejected" {
  command = plan

  variables {
    destroy_scheduled_duration = "3600s"
  }
```

`expect_failures = [var.destroy_scheduled_duration]` says this run must fail that variable's validation. If the module ever accepted `3600s`, this test would fail.

The environment test checks the string both languages must agree on:

`infra/environments/lab/tests/principal.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id              = "example-sandbox-0000"
  project_number          = "123456789012"
  master_authorized_cidrs = { laptop = "203.0.113.7/32" }

  storage_service_agent_email = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
}

# The same literal is asserted in tests/unit/domain/test_principal.py: Terraform and the Python tool must agree.
run "the_pod_principal_uses_the_project_number_and_the_pool_of_the_project_id" {
  command = plan

  assert {
    condition     = output.reader_writer_principal == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"
    error_message = "The principal must be built from the number, the pool and the subject."
  }
}

run "the_project_id_in_place_of_the_number_is_rejected" {
```

- `storage_service_agent_email` is given in `variables`, so the lookup is skipped and nothing needs a real provider.
- `output.reader_writer_principal == "principal://..."` compares an output to a literal. The identical literal is asserted in `tests/unit/domain/test_principal.py`, so Terraform and Python cannot drift apart.

`infra/environments/lab/tests/principal.tftest.hcl`

```hcl
run "only_the_pod_principal_uses_the_bucket_and_only_the_storage_agent_uses_the_key" {
  command = plan

  assert {
    condition     = module.bucket.object_users == tolist(["principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"])
    error_message = "The bucket lists exactly the pod principal."
  }
```

`module.bucket.object_users == tolist([...])`: module outputs are lists, and `tolist` makes the literal the same type.

## Every test file, run by run

Words used below. A **`run` block** is one test. `command = plan` makes the plan in memory and checks it; no resource is created anywhere. An **`assert` block** has a `condition` (must be true) and an `error_message` (shown if it is false). `&&` means "and". `==` compares. A `variables` block at the top of the file sets the inputs of every run; a `variables` block inside a run replaces some of them for that run only. `expect_failures = [var.name]` turns the run around: it passes only if that variable's `validation` rejects the value. A resource created with `for_each` is a map, so `length(resource.name)` counts the copies. `mock_provider "google" {}` replaces the real provider with a fake one, so nothing contacts Google.

### `infra/modules/project-services/tests/services.tftest.hcl`

`infra/modules/project-services/tests/services.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id = "example-sandbox-0000"
  services   = ["container.googleapis.com", "cloudkms.googleapis.com"]
}

run "each_listed_api_is_enabled_and_left_enabled_on_destroy" {
  command = plan

  assert {
    condition     = length(google_project_service.enabled) == 2 && alltrue([for s in google_project_service.enabled : s.disable_on_destroy == false])
    error_message = "Two APIs, none disabled on destroy."
  }
}

run "a_name_that_is_not_an_api_is_rejected" {
  command = plan

  variables {
    services = ["container"]
  }

  expect_failures = [var.services]
}
```

- Run one: two APIs are enabled and every one has `disable_on_destroy == false`. `alltrue([for s in ... : ...])` checks each copy.
- Run two: a name that is not an API (it does not end in `.googleapis.com`) must be rejected.

### `infra/modules/network/tests/network.tftest.hcl`

`infra/modules/network/tests/network.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id = "example-sandbox-0000"
  name       = "lab"
  region     = "europe-west1"
}

run "nodes_reach_google_apis_without_external_addresses_and_flows_are_logged" {
  command = plan

  assert {
    condition     = google_compute_subnetwork.nodes.private_ip_google_access && length(google_compute_subnetwork.nodes.log_config) == 1
    error_message = "The subnet needs Private Google Access and flow logs."
  }
}

run "everything_not_allowed_is_denied_explicitly_and_logged" {
  command = plan

  assert {
    condition     = google_compute_firewall.deny_all_ingress.priority == 65534 && length(google_compute_firewall.deny_all_ingress.log_config) == 1
    error_message = "A logged deny-all rule at the lowest priority is expected."
  }
}

run "the_network_is_custom_mode" {
  command = plan

  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false
    error_message = "Subnets are created explicitly."
  }
}

run "a_bad_range_is_rejected" {
  command = plan

  variables {
    pods_cidr = "not-a-cidr"
  }

  expect_failures = [var.pods_cidr]
}
```

- Run one: the node subnet has Private Google Access on and one flow-log block.
- Run two: the deny rule has priority 65534 and one log block.
- Run three: the network is custom mode. Run four: a bad range for `pods_cidr` is rejected.

### `infra/modules/gke-autopilot/tests/cluster.tftest.hcl`

`infra/modules/gke-autopilot/tests/cluster.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id              = "example-sandbox-0000"
  name                    = "demo"
  region                  = "europe-west1"
  network                 = "https://www.googleapis.com/compute/v1/projects/example-sandbox-0000/global/networks/lab"
  subnetwork              = "https://www.googleapis.com/compute/v1/projects/example-sandbox-0000/regions/europe-west1/subnetworks/lab-nodes"
  pods_range_name         = "pods"
  services_range_name     = "services"
  master_authorized_cidrs = { laptop = "203.0.113.7/32" }
}

run "autopilot_with_private_nodes_and_a_restricted_endpoint" {
  command = plan

  assert {
    condition     = google_container_cluster.this.enable_autopilot && google_container_cluster.this.private_cluster_config[0].enable_private_nodes
    error_message = "Autopilot with private nodes is expected."
  }

  assert {
    condition     = length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 1
    error_message = "Exactly the given range may reach the endpoint."
  }
}

run "no_client_certificate_is_issued" {
  command = plan

  assert {
    condition     = google_container_cluster.this.master_auth[0].client_certificate_config[0].issue_client_certificate == false
    error_message = "Client certificates must stay off."
  }
}

run "the_pool_name_is_the_project_id_and_svc_id_goog" {
  command = plan

  assert {
    condition     = output.workload_pool == "example-sandbox-0000.svc.id.goog"
    error_message = "The workload pool is PROJECT_ID.svc.id.goog."
  }
}

run "an_open_endpoint_is_rejected" {
  command = plan

  variables {
    master_authorized_cidrs = { everyone = "0.0.0.0/0" }
  }

  expect_failures = [var.master_authorized_cidrs]
}

run "no_range_at_all_is_rejected" {
  command = plan

  variables {
    master_authorized_cidrs = {}
  }

  expect_failures = [var.master_authorized_cidrs]
}
```

- Run one (two asserts): Autopilot is on, nodes are private, and exactly one authorized range exists. `[0]` picks the first (only) copy of a nested block.
- Run two: no client certificate is issued. Run three: the pool name is `PROJECT_ID.svc.id.goog`.
- Runs four and five: a range of `0.0.0.0/0`, and an empty map, are both rejected by the same variable.

### `infra/modules/kms-key/tests/key.tftest.hcl`

`infra/modules/kms-key/tests/key.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id                  = "example-sandbox-0000"
  location                    = "europe-west1"
  key_ring_name               = "files"
  key_name                    = "files-key"
  encrypter_decrypter_members = { storage_agent = "serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com" }
}

run "the_key_rotates_and_waits_24_hours_before_destruction" {
  command = plan

  assert {
    condition     = google_kms_crypto_key.this.rotation_period == "7776000s" && google_kms_crypto_key.this.destroy_scheduled_duration == "86400s"
    error_message = "90-day rotation and a 24-hour destruction window are the defaults."
  }
}

run "only_the_listed_member_may_use_the_key" {
  command = plan

  assert {
    condition     = length(google_kms_crypto_key_iam_member.encrypter_decrypter) == 1 && alltrue([for b in google_kms_crypto_key_iam_member.encrypter_decrypter : b.role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"])
    error_message = "One encrypterDecrypter binding on the key, nothing broader."
  }
}

run "a_destruction_window_under_24_hours_is_rejected" {
  command = plan

  variables {
    destroy_scheduled_duration = "3600s"
  }

  expect_failures = [var.destroy_scheduled_duration]
}
```

- Run one: rotation is `7776000s` and the destruction wait is `86400s`.
- Run two: one IAM binding exists and its role is the encrypter/decrypter role.
- Run three: a destruction window under 24 hours is rejected.

### `infra/modules/cmek-bucket/tests/bucket.tftest.hcl`

`infra/modules/cmek-bucket/tests/bucket.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id = "example-sandbox-0000"
  name       = "example-sandbox-0000-files"
  location   = "europe-west1"
  kms_key_id = "projects/example-sandbox-0000/locations/europe-west1/keyRings/files/cryptoKeys/files-key"
  object_users = {
    reader_writer = "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"
  }
}

run "the_key_is_the_buckets_default_and_the_bucket_is_private" {
  command = plan

  assert {
    condition     = google_storage_bucket.this.encryption[0].default_kms_key_name == var.kms_key_id && google_storage_bucket.this.public_access_prevention == "enforced" && google_storage_bucket.this.uniform_bucket_level_access
    error_message = "Default key, no public access, uniform access."
  }
}

run "only_object_user_is_granted_and_only_on_the_bucket" {
  command = plan

  assert {
    condition     = length(google_storage_bucket_iam_member.object_user) == 1 && alltrue([for b in google_storage_bucket_iam_member.object_user : b.role == "roles/storage.objectUser"])
    error_message = "One objectUser binding on the bucket."
  }
}
```

- Run one: the key is the bucket's default (`encryption[0].default_kms_key_name == var.kms_key_id`) and the bucket is private. Run two: one binding, `roles/storage.objectUser`, on the bucket only.

### `infra/modules/audit-logs/tests/audit.tftest.hcl`

`infra/modules/audit-logs/tests/audit.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id = "example-sandbox-0000"
}

run "data_reads_and_writes_of_cloud_storage_are_logged" {
  command = plan

  assert {
    condition     = google_project_iam_audit_config.storage.service == "storage.googleapis.com" && length(google_project_iam_audit_config.storage.audit_log_config) == 3
    error_message = "Cloud Storage with three log types."
  }
}

run "an_unknown_log_type_is_rejected" {
  command = plan

  variables {
    log_types = ["EVERYTHING"]
  }

  expect_failures = [var.log_types]
}
```

- Run one: the audit configuration is for `storage.googleapis.com` and has three log blocks. Run two: an unknown log type is rejected.

### `infra/environments/lab/tests/principal.tftest.hcl`

`infra/environments/lab/tests/principal.tftest.hcl`

```hcl
mock_provider "google" {}

variables {
  project_id              = "example-sandbox-0000"
  project_number          = "123456789012"
  master_authorized_cidrs = { laptop = "203.0.113.7/32" }

  storage_service_agent_email = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
}

# The same literal is asserted in tests/unit/domain/test_principal.py: Terraform and the Python tool must agree.
run "the_pod_principal_uses_the_project_number_and_the_pool_of_the_project_id" {
  command = plan

  assert {
    condition     = output.reader_writer_principal == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"
    error_message = "The principal must be built from the number, the pool and the subject."
  }
}

run "the_project_id_in_place_of_the_number_is_rejected" {
  command = plan

  variables {
    project_number = "example-sandbox-0000"
  }

  expect_failures = [var.project_number]
}

run "only_the_pod_principal_uses_the_bucket_and_only_the_storage_agent_uses_the_key" {
  command = plan

  assert {
    condition     = module.bucket.object_users == tolist(["principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"])
    error_message = "The bucket lists exactly the pod principal."
  }

  assert {
    condition     = module.key.encrypter_decrypter_members == tolist(["serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"])
    error_message = "The key lists exactly the Cloud Storage service agent."
  }
}

run "the_bucket_is_in_the_same_region_as_the_key_and_named_after_the_project" {
  command = plan

  assert {
    condition     = output.bucket == "example-sandbox-0000-files" && output.region == "europe-west1"
    error_message = "Bucket name and region follow the variables."
  }
}
```

- The top `variables` give the example project and a storage-agent email, so the `data` lookup is skipped and no real provider is needed.
- Run one compares the principal output with the exact literal that `tests/unit/domain/test_principal.py` also asserts: Terraform and Python must build the same text.
- Run two puts the project id where the number belongs: the variable's validation must reject it.
- Run three checks the lists: the bucket has exactly the pod principal, the key exactly the service agent. `tolist([...])` makes the literal the same type as the output.
- Run four: the bucket is `example-sandbox-0000-files` and the region `europe-west1`.

## 6. Try it yourself

```bash
cd infra/modules/kms-key && terraform init -backend=false -input=false >/dev/null && terraform test
```
Expected: `Success! 3 passed, 0 failed.`

```bash
cd infra/environments/lab && terraform init -backend=false -input=false >/dev/null && terraform test
```
Expected: `Success! 4 passed, 0 failed.`

Break one on purpose: in `infra/modules/cmek-bucket/main.tf` change `"roles/storage.objectUser"` to `"roles/storage.objectAdmin"`, run `terraform test` in that module, read the failure message, then undo the change (`git checkout infra`).

```bash
make test-terraform
```
Expected: `== infra/modules/...` headings and a `Success!` line for each of the six modules and the environment.

## 7. Mistakes people make

- **Comparing against random mock values.** Override the module or resource first.
- **Comparing a list with a tuple literal.** Use `tolist()`.
- **Forgetting `expect_failures`.** A validation error would fail the whole run.
- **Testing the provider, not your logic.** Assert your wiring (who gets which role), not that Terraform works.
- **Believing a mock proves Google accepts it.** It does not; `scripts/prove.sh` does that against a real project.

## 8. Check yourself

1. What does `mock_provider` do? *Replaces the real provider so nothing contacts the cloud.*
2. What does `expect_failures` mean? *The run passes only if that variable's validation fails.*
3. Why does the environment test set `storage_service_agent_email`? *So the lookup is skipped and no real provider is needed.*
4. Which command runs all tests of a module? *`terraform test` in that folder.*
5. Why `tolist(...)`? *To make a literal the same type as the output.*

## 9. Further reading

- `terraform test`: <https://developer.hashicorp.com/terraform/language/tests>
- Mock providers: <https://developer.hashicorp.com/terraform/language/tests/mocking>
- Command reference: <https://developer.hashicorp.com/terraform/cli/commands/test>
