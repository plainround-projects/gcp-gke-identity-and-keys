variable "project_id" {
  description = "Project that owns the bucket."
  type        = string
}

variable "name" {
  description = "Globally unique bucket name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.name))
    error_message = "name must be 3-63 characters: lowercase letters, digits, dot, underscore and hyphen."
  }
}

variable "location" {
  description = "Bucket location; must match the key's location."
  type        = string
}

variable "kms_key_id" {
  description = "Resource name of the customer-managed key used as the bucket's default."
  type        = string
}

variable "object_users" {
  description = "Members that may read and write objects (roles/storage.objectUser on the bucket), keyed by a fixed label."
  type        = map(string)
  default     = {}
}

variable "force_destroy" {
  description = "Delete the bucket even when it holds objects. True only for a sandbox."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels for the bucket."
  type        = map(string)
  default     = {}
}
