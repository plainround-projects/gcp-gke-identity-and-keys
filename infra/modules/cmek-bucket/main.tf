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
