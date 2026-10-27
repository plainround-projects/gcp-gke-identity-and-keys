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
