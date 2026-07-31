variable "subscription_id" {
  description = "Subscription to deploy into."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create."
  type        = string
  default     = "rg-credential-rotation"
}

variable "location" {
  description = "Azure region."
  type        = string
  default     = "switzerlandnorth"
}

variable "automation_account_name" {
  description = "Name of the automation account."
  type        = string
  default     = "aa-credential-rotation"
}

variable "key_vault_name" {
  description = "Existing Key Vault that stores the credentials. Must have RBAC authorisation enabled."
  type        = string
}

variable "key_vault_resource_group" {
  description = "Resource group of that Key Vault."
  type        = string
}

variable "vm_scopes" {
  description = "Resource IDs where the identity may manage VMs."
  type        = list(string)
}

variable "retention_days" {
  description = "Workspace and rotation table retention. Think about how far back you would need to answer who had access."
  type        = number
  default     = 90
}

variable "dry_run" {
  description = "Report without changing anything. Start with true."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for the created resources."
  type        = map(string)
  default     = {}
}
