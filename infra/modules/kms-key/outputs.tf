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
