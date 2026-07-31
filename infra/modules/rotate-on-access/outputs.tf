output "grace_period_hours" {
  description = "Configured grace period."
  value       = var.grace_period_hours
}

output "excluded_object_ids" {
  description = "Object IDs whose reads never trigger a rotation."
  value       = local.excluded_object_ids
}

output "worst_case_exposure_hours" {
  description = "Upper bound between a credential being read and being replaced: the grace period plus one schedule interval."
  value       = var.grace_period_hours + var.schedule_interval_hours
}
