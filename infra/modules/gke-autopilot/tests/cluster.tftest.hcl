mock_provider "google" {}

variables {
  project_id              = "example-sandbox-0000"
  name                    = "demo"
  region                  = "europe-west1"
  network                 = "https://www.googleapis.com/compute/v1/projects/example-sandbox-0000/global/networks/lab"
  subnetwork              = "https://www.googleapis.com/compute/v1/projects/example-sandbox-0000/regions/europe-west1/subnetworks/lab-nodes"
  pods_range_name         = "pods"
  services_range_name     = "services"
  master_authorized_cidrs = { laptop = "203.0.113.7/32" }
}

run "autopilot_with_private_nodes_and_a_restricted_endpoint" {
  command = plan

  assert {
    condition     = google_container_cluster.this.enable_autopilot && google_container_cluster.this.private_cluster_config[0].enable_private_nodes
    error_message = "Autopilot with private nodes is expected."
  }

  assert {
    condition     = length(google_container_cluster.this.master_authorized_networks_config[0].cidr_blocks) == 1
    error_message = "Exactly the given range may reach the endpoint."
  }
}

run "no_client_certificate_is_issued" {
  command = plan

  assert {
    condition     = google_container_cluster.this.master_auth[0].client_certificate_config[0].issue_client_certificate == false
    error_message = "Client certificates must stay off."
  }
}

run "the_pool_name_is_the_project_id_and_svc_id_goog" {
  command = plan

  assert {
    condition     = output.workload_pool == "example-sandbox-0000.svc.id.goog"
    error_message = "The workload pool is PROJECT_ID.svc.id.goog."
  }
}

run "an_open_endpoint_is_rejected" {
  command = plan

  variables {
    master_authorized_cidrs = { everyone = "0.0.0.0/0" }
  }

  expect_failures = [var.master_authorized_cidrs]
}

run "no_range_at_all_is_rejected" {
  command = plan

  variables {
    master_authorized_cidrs = {}
  }

  expect_failures = [var.master_authorized_cidrs]
}
