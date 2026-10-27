# Data-access audit logs record who read or wrote which object, including the denied calls step 3 looks for.
# They are off by default for Cloud Storage. This resource owns the audit configuration of the service in the project.
resource "google_project_iam_audit_config" "storage" {
  project = var.project_id
  service = "storage.googleapis.com"

  dynamic "audit_log_config" {
    for_each = toset(var.log_types)
    content {
      log_type = audit_log_config.value
    }
  }
}
