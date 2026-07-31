variable "resource_group_name" {
  description = "Resource group holding the automation account. Output of the core module."
  type        = string
}

variable "automation_account_name" {
  description = "Automation account to configure. Output of the core module."
  type        = string
}

variable "automation_principal_id" {
  description = "Managed identity of the automation account, excluded from access detection so the tool cannot trigger itself. Output of the core module."
  type        = string
}

variable "schedule_interval_hours" {
  description = "Hours between rotation runs. Must match the core module, and is used to sanity-check the lookback window."
  type        = number
  default     = 6
}

variable "grace_period_hours" {
  description = <<-EOT
    How long a reader keeps working credentials before the replacement kicks in.

    A password change does not end an established RDP or SSH session, but it does
    break reconnects, elevation and anything that re-authenticates. Too short and
    you interrupt the person mid-task; too long and the point is lost. Eight hours
    covers a working day.

    Set to 0 to rotate at the next run with no grace period at all.
  EOT
  type        = number
  default     = 8

  validation {
    condition     = var.grace_period_hours >= 0 && var.grace_period_hours <= 168
    error_message = "grace_period_hours must be between 0 and 168."
  }
}

variable "access_lookback_hours" {
  description = <<-EOT
    How far back each run looks for credential reads.

    Must be longer than the schedule interval so no read falls between two runs.
    Overlapping windows are harmless: bringing an expiry date forward is idempotent,
    and a date that is already early enough is left alone.
  EOT
  type        = number
  default     = 24

  validation {
    condition     = var.access_lookback_hours >= 1 && var.access_lookback_hours <= 720
    error_message = "access_lookback_hours must be between 1 and 720."
  }
}

variable "additional_excluded_object_ids" {
  description = <<-EOT
    Further object IDs whose reads must not trigger rotation.

    Reads without a upn claim are already ignored, which covers service principals
    and managed identities. Use this for break-glass accounts or a monitoring
    identity that authenticates as a user.
  EOT
  type        = list(string)
  default     = []
}
