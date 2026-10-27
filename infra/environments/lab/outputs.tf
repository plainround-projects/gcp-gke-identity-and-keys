output "cluster_name" {
  description = "Cluster name, for gcloud container clusters get-credentials."
  value       = module.cluster.name
}

output "region" {
  description = "Region of the cluster, the key and the bucket."
  value       = var.region
}

output "bucket" {
  description = "The encrypted bucket."
  value       = module.bucket.name
}

output "key" {
  description = "Resource name of the customer-managed key."
  value       = module.key.id
}

output "workload_pool" {
  description = "The project's workload identity pool."
  value       = module.cluster.workload_pool
}

output "reader_writer_principal" {
  description = "The IAM member that holds roles/storage.objectUser on the bucket."
  value       = local.pod_principal
}
