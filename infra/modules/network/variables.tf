variable "project_id" {
  description = "Project that owns the network."
  type        = string
}

variable "name" {
  description = "Network name; the subnet is NAME-nodes."
  type        = string
}

variable "region" {
  description = "Region of the subnet."
  type        = string
}

variable "nodes_cidr" {
  description = "Primary range of the subnet (nodes)."
  type        = string
  default     = "10.10.0.0/24"

  validation {
    condition     = can(cidrhost(var.nodes_cidr, 0))
    error_message = "nodes_cidr must be a CIDR block."
  }
}

variable "pods_cidr" {
  description = "Secondary range for pods."
  type        = string
  default     = "10.20.0.0/18"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a CIDR block."
  }
}

variable "services_cidr" {
  description = "Secondary range for services."
  type        = string
  default     = "10.30.0.0/22"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a CIDR block."
  }
}
