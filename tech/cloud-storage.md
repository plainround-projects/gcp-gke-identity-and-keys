# Cloud Storage

## 1. What it is

Cloud Storage is Google Cloud's **object store**. You keep **objects** (files plus a name and some details) in **buckets** (named containers). There are no real folders: `a.txt` is a flat name. Access is decided by IAM roles on the bucket, and every object is encrypted at rest; with a customer-managed key (see `cloud-kms.md`) you control that encryption.

## 2. Why this repository uses it

The pod reads and writes one bucket with its own identity. The bucket is the thing whose access is broken three ways: a wrong identity, a missing role, and a disabled key.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `infra/modules/cmek-bucket/main.tf` | Creates the bucket with the key as its default and grants `objectUser` to the pod's principal. |
| `infra/environments/lab/main.tf` | Instantiates it as `PROJECT_ID-files`. |
| `scripts/lib.sh` | `pod_test` writes and reads `a.txt` with `gcloud storage cp` and `cat`. |
| `scripts/deploy.sh` | Uploads `first.txt` and prints its `kms_key`. |
| `scripts/break-*.sh`, `restore-*.sh` | Remove and restore the bucket role. |

## 4. How it works underneath

- A request names a bucket and object. Cloud Storage checks IAM (does this caller hold a role containing the permission, such as `storage.objects.create` or `storage.objects.get`?), then encrypts or decrypts with the bucket's key through its service agent.
- **Roles** are bundles of permissions. `roles/storage.objectUser` lets a caller create, read, update, delete and list objects in the bucket. It is broader than `objectCreator` or `objectViewer` and narrower than `storage.admin`.
- **Uniform bucket-level access** switches off per-object ACLs so IAM alone decides. **Public access prevention** blocks public sharing. **Versioning** keeps old versions of objects.
- A denial message names the principal, the permission and the resource: `... does not have storage.objects.create access to the Google Cloud Storage object. Permission 'storage.objects.create' denied on resource (or it may not exist).`

## 5. Walkthrough of this repository's use

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
```

- `location = var.location` must equal the key's location.
- `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"` and `versioning` are the safety settings.
- `encryption { default_kms_key_name = var.kms_key_id }` makes new objects use the customer-managed key unless the writer names another.
- `force_destroy` lets a lab teardown delete a bucket that still holds objects.
- The comments record two ordering facts: the service agent must already be allowed to use the key, so the environment passes `depends_on`.

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

The pod's principal (not a service account email: a `principal://...` string) gets `roles/storage.objectUser` on this bucket.

The lesson's test, run inside the pod:

`scripts/lib.sh`

```bash
# The lesson's test, run again after every change, from inside the pod. Prints the command's output and exit status.
pod_test() {
  local deployment="${1:-files}"
  kubectl -n demo exec "deploy/$deployment" -- sh -c "echo hello > /tmp/a.txt && gcloud storage cp /tmp/a.txt gs://$BUCKET/a.txt && gcloud storage cat gs://$BUCKET/a.txt"
}
```

- `gcloud storage cp /tmp/a.txt gs://BUCKET/a.txt` uploads; `gcloud storage cat gs://BUCKET/a.txt` prints the object. Both need the pod's identity to hold the role.
- After the key is disabled, reading an object written *before* the break fails with a key error; that is why `break-key.sh` reads `first.txt`.

`scripts/deploy.sh`

```bash
echo "bucket encryption key:"
echo hi | gcloud storage cp - "gs://$BUCKET/first.txt"
gcloud storage objects describe "gs://$BUCKET/first.txt" --format='value(kms_key)'
```

## 6. Try it yourself

```bash
cd infra/modules/cmek-bucket && terraform init -backend=false -input=false >/dev/null && terraform test
```
Expected: `Success! 2 passed, 0 failed.`

```bash
grep -n "storage.objects" tests/fixtures/*.txt | cut -c1-110
```
Expected: lines from `wrong-service-account.txt` (`storage.objects.create`) and `missing-role.txt` (`storage.objects.get`) showing the permission in a real denial message.

```bash
.venv/bin/gke-triage classify tests/fixtures/missing-role.txt | sed -n 3,4p | cut -c1-110
```
Expected: the `principal:` line ending `.../sa/reader-writer` and `permission:  storage.objects.get`.

With a project (not run here): `gcloud storage objects describe gs://BUCKET/first.txt --format='value(kms_key)'` prints the key version used.

## 7. Mistakes people make

- **Assuming a missing bucket role is an authentication problem.** The caller authenticated; IAM found no role.
- **Creating the bucket before the key's grant.** The creation fails.
- **Putting the bucket in a different region from its key.**
- **Giving `storage.admin` on the project.** Too broad; here the role is on the bucket.
- **Testing only writes after disabling the key.** A write may use another version.

## 8. Check yourself

1. What does `objectUser` allow? *Create, read, update, delete and list objects in that bucket.*
2. What decides who can read here? *IAM roles only, because uniform access is on.*
3. What three things does a denial message name? *The principal, the permission and the resource.*
4. What does `default_kms_key_name` do? *Makes the key the default for new objects.*
5. Why must bucket and key share a location? *A regional bucket can only use a key in its region.*

## 9. Further reading

- Cloud Storage: <https://cloud.google.com/storage/docs>
- IAM roles for Cloud Storage: <https://cloud.google.com/storage/docs/access-control/iam-roles>
- Uniform bucket-level access: <https://cloud.google.com/storage/docs/uniform-bucket-level-access>
- Terraform `google_storage_bucket`: <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/storage_bucket>
