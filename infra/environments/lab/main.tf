locals {
  services = [
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "storage.googleapis.com",
  ]

  # The pod's identity under Workload Identity Federation for GKE: the project NUMBER, the pool of the project ID,
  # the namespace and the Kubernetes service account. The Python tool builds the same string (gke-triage principal).
  pod_principal = "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.kubernetes_service_account}"

  # Cloud Storage reads and writes the key with its own service agent, not with the pod's identity.
  storage_service_agent_email = var.storage_service_agent_email != "" ? var.storage_service_agent_email : one(data.google_storage_project_service_account.gcs[*].email_address)
  storage_service_agent       = "serviceAccount:${local.storage_service_agent_email}"
}

# Asking for the service agent also creates it, which must happen before it can be granted a role on the key.
# Skipped when the email is given (the offline plan and the tests do that).
data "google_storage_project_service_account" "gcs" {
  count = var.storage_service_agent_email == "" ? 1 : 0

  project = var.project_id

  depends_on = [module.services]
}

module "services" {
  source = "../../modules/project-services"

  project_id = var.project_id
  services   = local.services
}

module "network" {
  source = "../../modules/network"

  project_id = var.project_id
  name       = "lab"
  region     = var.region

  depends_on = [module.services]
}

module "cluster" {
  source = "../../modules/gke-autopilot"

  project_id              = var.project_id
  name                    = "demo"
  region                  = var.region
  network                 = module.network.network
  subnetwork              = module.network.subnetwork
  pods_range_name         = module.network.pods_range_name
  services_range_name     = module.network.services_range_name
  master_authorized_cidrs = var.master_authorized_cidrs
  labels                  = var.labels
}

# Step 1, in the order the lesson gives: the key, the service agent's right to use it, then the bucket.
module "key" {
  source = "../../modules/kms-key"

  project_id                  = var.project_id
  location                    = var.region
  key_ring_name               = "files"
  key_name                    = "files-key"
  labels                      = var.labels
  encrypter_decrypter_members = { storage_agent = local.storage_service_agent }

  depends_on = [module.services]
}

module "bucket" {
  source = "../../modules/cmek-bucket"

  project_id    = var.project_id
  name          = "${var.project_id}-files"
  location      = var.region
  kms_key_id    = module.key.id
  labels        = var.labels
  force_destroy = true

  # Step 2: the pod's principal reads and writes this bucket and nothing else. It holds no role on the key.
  object_users = { reader_writer = local.pod_principal }

  # Creating the bucket fails unless the service agent may already use the key.
  depends_on = [module.key]
}

# Step 3 looks for the denial in the data-access audit log, which is off by default for Cloud Storage.
module "audit" {
  source = "../../modules/audit-logs"

  project_id = var.project_id

  depends_on = [module.services]
}
