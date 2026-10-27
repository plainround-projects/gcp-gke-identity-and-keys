output "name" {
  description = "Bucket name."
  value       = google_storage_bucket.this.name
}

output "object_users" {
  description = "Members granted roles/storage.objectUser on the bucket."
  value       = sort(values(var.object_users))
}
