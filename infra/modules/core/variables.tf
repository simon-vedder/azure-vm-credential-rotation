variable "resource_group_name" {
  description = "Resource group that holds the automation account."
  type        = string
}

variable "location" {
  description = "Azure region for the automation account."
  type        = string
}

variable "automation_account_name" {
  description = "Name of the automation account to create."
  type        = string
}

variable "key_vault_id" {
  description = "Resource ID of the existing Key Vault that stores the credentials. Must have RBAC authorisation enabled."
  type        = string
}

variable "key_vault_name" {
  description = "Name of that Key Vault. Passed to the runbook, which addresses the vault by name."
  type        = string
}

variable "vm_scopes" {
  description = <<-EOT
    Scopes where the managed identity may manage VMs, as resource IDs - a resource
    group or a subscription.

    Keep this as narrow as possible. Virtual Machine Contributor includes installing
    extensions, which is code execution as SYSTEM or root on every VM in scope.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.vm_scopes) > 0
    error_message = "At least one scope is required, otherwise the runbook cannot reach any VM."
  }
}

variable "target_subscription_ids" {
  description = "Subscriptions the runbook processes. Empty means the automation account's own subscription only."
  type        = list(string)
  default     = []
}

variable "threshold_days" {
  description = <<-EOT
    Rotate when a credential expires within this many days.

    Give this comfortable headroom over the schedule interval. If a VM is powered off
    for a few days, the run keeps retrying, and a threshold that is too tight means
    the secret expires before the machine comes back.
  EOT
  type        = number
  default     = 14

  validation {
    condition     = var.threshold_days >= 1 && var.threshold_days <= 3650
    error_message = "threshold_days must be between 1 and 3650."
  }
}

variable "validity_days" {
  description = "Lifetime of a newly rotated credential, in days."
  type        = number
  default     = 90

  validation {
    condition     = var.validity_days >= 1 && var.validity_days <= 3650
    error_message = "validity_days must be between 1 and 3650."
  }
}

variable "schedule_interval_hours" {
  description = <<-EOT
    Hours between reconciliation runs.

    This is the upper bound on how long a credential marked for rotation waits. With
    access-driven rotation, total exposure is roughly the grace period plus this.
  EOT
  type        = number
  default     = 6

  validation {
    condition     = var.schedule_interval_hours >= 1 && var.schedule_interval_hours <= 24
    error_message = "Azure Automation schedules run at most hourly and at least daily; use 1 to 24."
  }
}

variable "schedule_timezone" {
  description = "IANA timezone for the schedule."
  type        = string
  default     = "Etc/UTC"
}

variable "enable_tag_name" {
  description = "VM tag that opts a machine in to rotation."
  type        = string
  default     = "CredentialRotation"
}

variable "enable_tag_value" {
  description = "Value that tag must carry."
  type        = string
  default     = "enabled"
}

variable "dry_run" {
  description = <<-EOT
    Run the schedule in -WhatIf mode: report what would be rotated, change nothing.

    Deploy with this set to true, read one run's output, then set it to false.
  EOT
  type        = bool
  default     = true
}

variable "log_verbose" {
  description = "Enable verbose runbook logging."
  type        = bool
  default     = false
}

variable "runbook_content" {
  description = "Override the runbook body. Leave null to use the committed artefact in dist/."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the resources this module creates."
  type        = map(string)
  default     = {}
}
