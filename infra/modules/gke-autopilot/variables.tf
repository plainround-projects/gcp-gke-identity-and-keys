variable "project_id" {
  description = "Project that owns the cluster."
  type        = string
}

variable "name" {
  description = "Cluster name."
  type        = string
}

variable "region" {
  description = "Region of the cluster."
  type        = string
}

variable "network" {
  description = "Self link of the VPC network."
  type        = string
}

variable "subnetwork" {
  description = "Self link of the subnet."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods."
  type        = string
}

variable "services_range_name" {
  description = "Secondary range name for services."
  type        = string
}

variable "master_cidr" {
  description = "A /28 for the control plane's private side, not used by anything else."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_cidrs" {
  description = "Ranges allowed to reach the API endpoint, name => CIDR. Your own address as /32 is enough."
  type        = map(string)

  validation {
    condition     = length(var.master_authorized_cidrs) > 0 && alltrue([for c in values(var.master_authorized_cidrs) : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Give at least one valid CIDR block, and never 0.0.0.0/0."
  }
}

variable "release_channel" {
  description = "RAPID, REGULAR or STABLE."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "deletion_protection" {
  description = "Refuse to delete the cluster. False in a sandbox so the teardown works."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels for the cluster."
  type        = map(string)
  default     = {}
}
