mock_provider "google" {}

variables {
  project_id = "example-sandbox-0000"
}

run "data_reads_and_writes_of_cloud_storage_are_logged" {
  command = plan

  assert {
    condition     = google_project_iam_audit_config.storage.service == "storage.googleapis.com" && length(google_project_iam_audit_config.storage.audit_log_config) == 3
    error_message = "Cloud Storage with three log types."
  }
}

run "an_unknown_log_type_is_rejected" {
  command = plan

  variables {
    log_types = ["EVERYTHING"]
  }

  expect_failures = [var.log_types]
}
