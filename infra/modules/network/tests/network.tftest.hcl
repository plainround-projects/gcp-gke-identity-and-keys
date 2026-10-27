mock_provider "google" {}

variables {
  project_id = "example-sandbox-0000"
  name       = "lab"
  region     = "europe-west1"
}

run "nodes_reach_google_apis_without_external_addresses_and_flows_are_logged" {
  command = plan

  assert {
    condition     = google_compute_subnetwork.nodes.private_ip_google_access && length(google_compute_subnetwork.nodes.log_config) == 1
    error_message = "The subnet needs Private Google Access and flow logs."
  }
}

run "everything_not_allowed_is_denied_explicitly_and_logged" {
  command = plan

  assert {
    condition     = google_compute_firewall.deny_all_ingress.priority == 65534 && length(google_compute_firewall.deny_all_ingress.log_config) == 1
    error_message = "A logged deny-all rule at the lowest priority is expected."
  }
}

run "the_network_is_custom_mode" {
  command = plan

  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false
    error_message = "Subnets are created explicitly."
  }
}

run "a_bad_range_is_rejected" {
  command = plan

  variables {
    pods_cidr = "not-a-cidr"
  }

  expect_failures = [var.pods_cidr]
}
