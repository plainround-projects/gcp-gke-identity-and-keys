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
