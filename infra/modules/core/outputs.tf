output "automation_account_id" {
  description = "Resource ID of the automation account."
  value       = azurerm_automation_account.this.id
}

output "automation_account_name" {
  description = "Name of the automation account."
  value       = azurerm_automation_account.this.name
}

output "principal_id" {
  description = "Object ID of the managed identity. Other modules grant it access and exclude it from access detection."
  value       = azurerm_automation_account.this.identity[0].principal_id
}

output "runbook_name" {
  description = "Name of the rotation runbook, for manual and on-demand starts."
  value       = azurerm_automation_runbook.rotation.name
}

output "resource_group_name" {
  description = "Resource group holding the automation account."
  value       = var.resource_group_name
}
