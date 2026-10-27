mock_provider "google" {}

variables {
  project_id = "example-sandbox-0000"
  services   = ["container.googleapis.com", "cloudkms.googleapis.com"]
}

run "each_listed_api_is_enabled_and_left_enabled_on_destroy" {
  command = plan

  assert {
    condition     = length(google_project_service.enabled) == 2 && alltrue([for s in google_project_service.enabled : s.disable_on_destroy == false])
    error_message = "Two APIs, none disabled on destroy."
  }
}

run "a_name_that_is_not_an_api_is_rejected" {
  command = plan

  variables {
    services = ["container"]
  }

  expect_failures = [var.services]
}
