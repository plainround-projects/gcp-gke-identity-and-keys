variable "project_id" {
  description = "Id of the existing project."
  type        = string
}

variable "services" {
  description = "APIs to enable."
  type        = list(string)

  validation {
    condition     = alltrue([for s in var.services : can(regex("\\.googleapis\\.com$", s))])
    error_message = "Every service must end in .googleapis.com."
  }
}
