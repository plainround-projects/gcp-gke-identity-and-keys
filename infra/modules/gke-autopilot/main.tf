resource "google_container_cluster" "this" {
  #checkov:skip=CKV_GCP_65:Google Groups for RBAC needs a Workspace or Cloud Identity group; the lab uses the owner's own identity
  #checkov:skip=CKV_GCP_66:Binary Authorization needs an attestor and a policy; the lab runs one Google-published image pinned by digest
  #checkov:skip=CKV_GCP_69:Autopilot always runs the GKE metadata server and rejects a node_config block
  #checkov:skip=CKV_GCP_61:Autopilot runs Dataplane V2, which gives intranode visibility itself, and the provider rejects enable_intranode_visibility with enable_autopilot
  #checkov:skip=CKV_GCP_12:Autopilot runs Dataplane V2, which enforces NetworkPolicy; the cluster has no network_policy block to set
  project  = var.project_id
  name     = var.name
  location = var.region

  # Autopilot manages nodes, turns on Workload Identity Federation for GKE and applies hardening defaults.
  enable_autopilot    = true
  deletion_protection = var.deletion_protection
  resource_labels     = var.labels

  network    = var.network
  subnetwork = var.subnetwork

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Nodes get no external address; the API endpoint stays public but only the listed ranges may reach it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        display_name = cidr_blocks.key
        cidr_block   = cidr_blocks.value
      }
    }
  }

  # No client certificate is issued; users authenticate with their Google identity.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  release_channel {
    channel = var.release_channel
  }

  # Control-plane and workload logs go to Cloud Logging, where the denials are found.
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
}
