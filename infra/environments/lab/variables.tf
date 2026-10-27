variable "project_id" {
  description = "Id of the lab project (created by scripts/create-project.sh)."
  type        = string
}

variable "project_number" {
  description = "Number of the lab project. The workload identity principal and the Cloud Storage service agent contain it, and it is not the project id."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must contain digits only; use gcloud projects describe PROJECT_ID --format='value(projectNumber)'."
  }
}

variable "region" {
  description = "Region for the cluster, the key ring and the bucket (the key and the bucket must match)."
  type        = string
  default     = "europe-west1"
}

variable "master_authorized_cidrs" {
  description = "Ranges allowed to reach the cluster's API endpoint, name => CIDR. Your own address as a /32."
  type        = map(string)
}

variable "storage_service_agent_email" {
  description = "Email of the Cloud Storage service agent (service-PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com). Leave empty to look it up, which also creates the agent; give it only to plan without credentials."
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Kubernetes namespace of the service."
  type        = string
  default     = "demo"
}

variable "kubernetes_service_account" {
  description = "Kubernetes service account that gets the bucket role."
  type        = string
  default     = "reader-writer"
}

variable "labels" {
  description = "Labels applied to every resource that supports them."
  type        = map(string)
  default = {
    environment = "lab"
    project     = "gke-identity-and-keys"
    managed-by  = "terraform"
  }
}
