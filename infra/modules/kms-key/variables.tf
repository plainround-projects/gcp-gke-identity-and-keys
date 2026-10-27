variable "project_id" {
  description = "Project that owns the key ring."
  type        = string
}

variable "location" {
  description = "Location of the key ring; a regional bucket needs a key in the same region."
  type        = string
}

variable "key_ring_name" {
  description = "Key ring name. Key rings cannot be deleted once created."
  type        = string
}

variable "key_name" {
  description = "Key name."
  type        = string
}

variable "rotation_period" {
  description = "How often a new key version becomes primary, in seconds with an s suffix (90 days by default)."
  type        = string
  default     = "7776000s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.rotation_period))
    error_message = "rotation_period must be a number of seconds ending in s, for example 7776000s."
  }
}

variable "destroy_scheduled_duration" {
  description = "How long a version waits between a destroy request and the irreversible destruction (at least 24 hours)."
  type        = string
  default     = "86400s"

  validation {
    condition     = can(regex("^[0-9]+s$", var.destroy_scheduled_duration)) && tonumber(trimsuffix(var.destroy_scheduled_duration, "s")) >= 86400
    error_message = "destroy_scheduled_duration must be at least 86400s (24 hours)."
  }
}

variable "encrypter_decrypter_members" {
  description = "Members that may use the key to encrypt and decrypt (the Cloud Storage service agent), keyed by a fixed label."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Labels for the key."
  type        = map(string)
  default     = {}
}
