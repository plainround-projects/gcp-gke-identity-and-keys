variable "project_id" {
  description = "Project whose Cloud Storage data access is logged."
  type        = string
}

variable "log_types" {
  description = "Audit log types to enable."
  type        = list(string)
  default     = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]

  validation {
    condition     = alltrue([for t in var.log_types : contains(["ADMIN_READ", "DATA_READ", "DATA_WRITE"], t)])
    error_message = "log_types may contain ADMIN_READ, DATA_READ and DATA_WRITE."
  }
}
