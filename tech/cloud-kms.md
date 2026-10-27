# Cloud KMS (and customer-managed encryption keys)

## 1. What it is

Cloud KMS (Key Management Service) stores and uses encryption keys for you. A **key ring** is a named group of keys in one location. A **key** has **versions**; each version holds actual key material and has a state: `ENABLED`, `DISABLED`, `DESTROY_SCHEDULED` or `DESTROYED`. One version is the **primary** (used for new encryption). You never see the key material; you ask KMS to encrypt or decrypt.

By default Google encrypts everything you store with keys it manages. A **customer-managed encryption key (CMEK)** is a key in your own Cloud KMS that you tell a service to use instead. You then control who can use it, when it rotates, and whether it works at all.

## 2. Why this repository uses it

The lesson's third break: disable the key version and reads of existing objects fail with an error that points at the key, not at IAM. The key is a "kill switch" for the data, and a new way for access to fail.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `infra/modules/kms-key/main.tf` | Creates the key ring `files`, key `files-key` (90-day rotation, 24-hour destruction window) and lets the Cloud Storage service agent use it. |
| `infra/modules/cmek-bucket/main.tf` | Sets the key as the bucket's default encryption key. |
| `infra/environments/lab/main.tf` | Looks up the Cloud Storage service agent, grants it the key role, and orders key before bucket. |
| `scripts/break-key.sh`, `restore-key.sh` | Disable and re-enable version 1 with `gcloud kms keys versions ...`. |
| `src/gke_triage/domain/triage.py` | Recognizes the key errors. |

## 4. How it works underneath

- Cloud Storage uses **envelope encryption**: each object is encrypted with a data key, and the data key is wrapped (encrypted) by your KMS key. To read an object, Cloud Storage asks KMS to unwrap the data key. If your key version is disabled, the unwrap fails and the object cannot be read, although IAM allowed the read.
- Cloud Storage does this with its own **service agent**, a Google-run identity `service-PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com`. That agent needs `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the key. The pod does not. The agent must exist and hold the role *before* a bucket with that default key can be created.
- **Rotation** creates a new primary version on a schedule (here every 90 days). Old versions stay enabled so old data stays readable.
- **Destruction** is two-step: a version in `DESTROY_SCHEDULED` can still be restored until the scheduled time passes (at least 24 hours here), and after `DESTROYED` the material is gone for good. A key ring cannot be deleted.
- Bucket and key must be in the same location.

## 5. Walkthrough of this repository's use

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
```

- `purpose = "ENCRYPT_DECRYPT"`: a symmetric key for encrypting data.
- `rotation_period = var.rotation_period`: `7776000s` is 90 days.
- `destroy_scheduled_duration`: how long a destroy request waits before the version is really destroyed; the variable refuses anything under `86400s` (24 hours).
- `version_template`: `GOOGLE_SYMMETRIC_ENCRYPTION` with `protection_level = "SOFTWARE"` (keys held in software, not in a hardware module).
- The `#checkov:skip=CKV_GCP_82` line records why `prevent_destroy` is not set: it would block the same-day teardown.
- `google_kms_crypto_key_iam_member` grants the role on this one key to each listed member (the Cloud Storage service agent).

The ordering rule (key before bucket):

`infra/environments/lab/main.tf`

```hcl
# Asking for the service agent also creates it, which must happen before it can be granted a role on the key.
# Skipped when the email is given (the offline plan and the tests do that).
data "google_storage_project_service_account" "gcs" {
  count = var.storage_service_agent_email == "" ? 1 : 0

  project = var.project_id

  depends_on = [module.services]
```

`data "google_storage_project_service_account"` asks Google for the agent's email, which also creates the agent. Then:

`infra/environments/lab/main.tf`

```hcl
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
```

`depends_on = [module.key]` makes Terraform finish the key and its grant before it creates the bucket.

The break:

`scripts/break-key.sh`

```bash
gcloud kms keys versions list --key=files-key --keyring=files --location="$REGION"
gcloud kms keys versions disable 1 --key=files-key --keyring=files --location="$REGION"
echo "waiting 60 seconds for the change to propagate"
sleep 60
```

## 6. Try it yourself

```bash
cd infra/modules/kms-key && terraform init -backend=false -input=false >/dev/null && terraform test
```
Expected: `Success! 3 passed, 0 failed.` (rotation and destruction window defaults; only the listed member may use the key; a window under 24 hours is rejected).

```bash
.venv/bin/gke-triage classify tests/fixtures/key-disabled.txt | head -2
```
Expected: `layer:       key` and `cause:       key disabled`.

```bash
.venv/bin/gke-triage classify tests/fixtures/key-access-denied.txt | head -3
```
Expected: `layer:       key`, `cause:       key access denied` and `permission:  cloudkms.cryptoKeyVersions.useToEncrypt` (the Cloud Storage service agent lacks the key role).

With a project (not run here): `gcloud kms keys versions list --key=files-key --keyring=files --location=europe-west1` prints each version's state.

## 7. Mistakes people make

- **Not authorizing the Cloud Storage service agent on the key before creating the bucket.** The bucket creation fails.
- **Giving the pod a role on the key.** It does not use the key.
- **Destroying a version "to clean up".** After the waiting period the data encrypted with it is gone for good.
- **Disabling the key and testing only a write.** A write may use another version; the read test is the one that shows the kill switch.
- **Putting key and bucket in different regions.**
- **Forgetting the cost of keys and operations.** Small, but not zero.

## 8. Check yourself

1. What does disabling a key version do to existing objects? *They become unreadable until it is enabled again.*
2. Who uses the key when a pod reads the bucket? *The Cloud Storage service agent, not the pod.*
3. What does rotation do? *Creates a new primary version; old versions stay usable.*
4. Can a destroyed version be recovered? *No.*
5. Why does the module refuse a window under 24 hours? *That is the shortest allowed scheduled destruction time.*

## 9. Further reading

- Cloud KMS: <https://cloud.google.com/kms/docs>
- CMEK for Cloud Storage: <https://cloud.google.com/storage/docs/encryption/customer-managed-keys>
- Key lifecycle: <https://cloud.google.com/kms/docs/key-states>
- Terraform `google_kms_crypto_key`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/kms_crypto_key>
