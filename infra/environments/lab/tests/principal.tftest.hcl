mock_provider "google" {}

variables {
  project_id              = "example-sandbox-0000"
  project_number          = "123456789012"
  master_authorized_cidrs = { laptop = "203.0.113.7/32" }

  storage_service_agent_email = "service-123456789012@gs-project-accounts.iam.gserviceaccount.com"
}

# The same literal is asserted in tests/unit/domain/test_principal.py: Terraform and the Python tool must agree.
run "the_pod_principal_uses_the_project_number_and_the_pool_of_the_project_id" {
  command = plan

  assert {
    condition     = output.reader_writer_principal == "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"
    error_message = "The principal must be built from the number, the pool and the subject."
  }
}

run "the_project_id_in_place_of_the_number_is_rejected" {
  command = plan

  variables {
    project_number = "example-sandbox-0000"
  }

  expect_failures = [var.project_number]
}

run "only_the_pod_principal_uses_the_bucket_and_only_the_storage_agent_uses_the_key" {
  command = plan

  assert {
    condition     = module.bucket.object_users == tolist(["principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"])
    error_message = "The bucket lists exactly the pod principal."
  }

  assert {
    condition     = module.key.encrypter_decrypter_members == tolist(["serviceAccount:service-123456789012@gs-project-accounts.iam.gserviceaccount.com"])
    error_message = "The key lists exactly the Cloud Storage service agent."
  }
}

run "the_bucket_is_in_the_same_region_as_the_key_and_named_after_the_project" {
  command = plan

  assert {
    condition     = output.bucket == "example-sandbox-0000-files" && output.region == "europe-west1"
    error_message = "Bucket name and region follow the variables."
  }
}
