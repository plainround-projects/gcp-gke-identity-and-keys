output "name" {
  description = "Cluster name."
  value       = google_container_cluster.this.name
}

output "location" {
  description = "Cluster region."
  value       = google_container_cluster.this.location
}

output "workload_pool" {
  description = "The workload identity pool of the project: PROJECT_ID.svc.id.goog."
  value       = "${var.project_id}.svc.id.goog"
}
