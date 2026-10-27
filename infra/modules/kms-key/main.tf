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
