variable "resource_group_name" {
  description = "Resource group for the workspace and data collection resources."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "key_vault_id" {
  description = "Key Vault whose audit log supplies the credential reads."
  type        = string
}

variable "automation_account_id" {
  description = "Automation account to collect job logs from. Output of the core module."
  type        = string
}

variable "automation_account_name" {
  description = "Automation account name, so this module can set its variables. Output of the core module."
  type        = string
}

variable "automation_principal_id" {
  description = "Managed identity of the automation account. Output of the core module."
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "Existing workspace to use. Leave null to create one."
  type        = string
  default     = null
}

variable "log_analytics_workspace_guid" {
  description = "Workspace GUID (the customer ID), required when supplying an existing workspace. The query API addresses workspaces by GUID, not by resource ID."
  type        = string
  default     = null

  validation {
    condition     = var.log_analytics_workspace_id == null || var.log_analytics_workspace_guid != null
    error_message = "When log_analytics_workspace_id is set, log_analytics_workspace_guid must be set too."
  }
}

variable "workspace_name" {
  description = "Name for the workspace, when this module creates one."
  type        = string
  default     = "log-credential-rotation"
}

variable "retention_days" {
  description = <<-EOT
    Retention for the workspace and the rotation table.

    Consider how long you would need to answer "who had access to this machine in
    month X". Thirty days is short for that question.
  EOT
  type        = number
  default     = 90

  validation {
    condition     = var.retention_days >= 30 && var.retention_days <= 730
    error_message = "retention_days must be between 30 and 730."
  }
}

variable "data_collection_endpoint_name" {
  description = "Name of the data collection endpoint."
  type        = string
  default     = "dce-credential-rotation"
}

variable "data_collection_rule_name" {
  description = "Name of the data collection rule."
  type        = string
  default     = "dcr-credential-rotation"
}

variable "deploy_workbook" {
  description = "Deploy the access-and-rotation workbook."
  type        = bool
  default     = true
}

variable "workbook_uuid" {
  description = "Workbook resource name. Must be a UUID; Azure uses it as the resource name, not the display name."
  type        = string
  default     = "9f2b7c14-3d8e-4a51-b6f0-2c7d9e134a88"
}

variable "tags" {
  description = "Tags applied to the resources this module creates."
  type        = map(string)
  default     = {}
}
