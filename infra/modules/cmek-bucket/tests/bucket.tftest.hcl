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
