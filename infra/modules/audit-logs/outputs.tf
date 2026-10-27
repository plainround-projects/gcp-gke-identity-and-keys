output "log_types" {
  description = "Enabled audit log types."
  value       = sort(var.log_types)
}
