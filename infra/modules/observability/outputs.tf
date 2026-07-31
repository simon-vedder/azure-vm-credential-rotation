output "workspace_id" {
  description = "Resource ID of the Log Analytics workspace."
  value       = local.workspace_id
}

output "workspace_guid" {
  description = "Workspace GUID, used by the query API and by the rotate-on-access module."
  value       = local.workspace_guid
}

output "data_collection_endpoint" {
  description = "Logs ingestion endpoint the runbook posts records to."
  value       = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
}

output "data_collection_rule_immutable_id" {
  description = "Immutable ID of the data collection rule. This, not the resource ID, is what the ingestion URL needs."
  value       = azurerm_monitor_data_collection_rule.this.immutable_id
}

output "table_name" {
  description = "Custom table holding the rotation records."
  value       = local.table_name
}
