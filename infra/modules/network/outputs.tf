output "network" {
  description = "Self link of the network."
  value       = google_compute_network.this.self_link
}

output "subnetwork" {
  description = "Self link of the node subnet."
  value       = google_compute_subnetwork.nodes.self_link
}

output "pods_range_name" {
  description = "Name of the secondary range for pods."
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the secondary range for services."
  value       = "services"
}
