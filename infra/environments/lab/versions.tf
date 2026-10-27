terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
  }

  # Local state is enough for a one-day lab. For shared use, add a gcs backend (see backend.tf.example).
}

provider "google" {
  project = var.project_id
  region  = var.region
}
