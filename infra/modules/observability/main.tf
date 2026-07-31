###############################################################################
# observability - the audit trail
#
# Answers one question end to end: who read a credential, when, and when was it
# replaced afterwards.
#
# Two halves. Key Vault's own audit log supplies the reads for free once diagnostic
# settings point at a workspace. The rotations come from the runbook, written to a
# custom table through the Logs Ingestion API.
#
# This module is also a prerequisite for rotate-on-access: the workspace it creates
# is what the runbook queries to learn that a credential was read at all.
###############################################################################

locals {
  create_workspace = var.log_analytics_workspace_id == null
  workspace_id     = local.create_workspace ? azurerm_log_analytics_workspace.this[0].id : var.log_analytics_workspace_id

  # Invoke-AzOperationalInsightsQuery wants the workspace GUID, not the resource ID.
  workspace_guid = local.create_workspace ? azurerm_log_analytics_workspace.this[0].workspace_id : var.log_analytics_workspace_guid

  table_name  = "CredentialRotation_CL"
  stream_name = "Custom-CredentialRotation_CL"

  # Must match New-RotationRecord in the module.
  columns = [
    { name = "TimeGenerated", type = "datetime" },
    { name = "SecretName", type = "string" },
    { name = "VMName", type = "string" },
    { name = "ResourceGroupName", type = "string" },
    { name = "SubscriptionId", type = "string" },
    { name = "OSType", type = "string" },
    { name = "CredentialType", type = "string" },
    { name = "TriggerReason", type = "string" },
    { name = "TriggeredBy", type = "string" },
    { name = "Result", type = "string" },
    { name = "StartedAt", type = "datetime" },
    { name = "DurationMs", type = "int" },
    { name = "PreviousSecretVersion", type = "string" },
    { name = "NewSecretVersion", type = "string" },
    { name = "Detail", type = "string" },
  ]
}

resource "azurerm_log_analytics_workspace" "this" {
  count = local.create_workspace ? 1 : 0

  name                = var.workspace_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.retention_days
  tags                = var.tags
}

###############################################################################
# who read a credential
#
# log_analytics_destination_type = "Dedicated" is what routes audit events into the
# resource-specific AZKVAuditLogs table instead of the generic AzureDiagnostics one.
# The runbook's query and everything in queries/ assume that table. Change this and
# the column names change with it.
###############################################################################

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                           = "credential-rotation-audit"
  target_resource_id             = var.key_vault_id
  log_analytics_workspace_id     = local.workspace_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AuditEvent"
  }
}

resource "azurerm_monitor_diagnostic_setting" "automation" {
  name                       = "credential-rotation-jobs"
  target_resource_id         = var.automation_account_id
  log_analytics_workspace_id = local.workspace_id

  enabled_log {
    category = "JobLogs"
  }

  enabled_log {
    category = "JobStreams"
  }
}

###############################################################################
# what the rotation did
#
# Logs Ingestion API, not the HTTP Data Collector API - the latter retires on
# 14 September 2026.
###############################################################################

resource "azapi_resource" "rotation_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = local.table_name
  parent_id = local.workspace_id

  body = {
    properties = {
      schema = {
        name        = local.table_name
        description = "One record per credential rotation attempt. Contains no credential material - only secret version identifiers."
        columns     = local.columns
      }
      retentionInDays      = var.retention_days
      totalRetentionInDays = var.retention_days
    }
  }
}

resource "azurerm_monitor_data_collection_endpoint" "this" {
  name                = var.data_collection_endpoint_name
  resource_group_name = var.resource_group_name
  location            = var.location
  description         = "Ingestion endpoint for credential rotation records."
  tags                = var.tags
}

resource "azurerm_monitor_data_collection_rule" "this" {
  name                        = var.data_collection_rule_name
  resource_group_name         = var.resource_group_name
  location                    = var.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.this.id
  description                 = "Routes credential rotation records into ${local.table_name}."
  tags                        = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = local.workspace_id
      name                  = "workspace"
    }
  }

  data_flow {
    streams       = [local.stream_name]
    destinations  = ["workspace"]
    output_stream = local.stream_name
    transform_kql = "source"
  }

  stream_declaration {
    stream_name = local.stream_name

    dynamic "column" {
      for_each = local.columns
      content {
        name = column.value.name
        type = column.value.type
      }
    }
  }

  depends_on = [azapi_resource.rotation_table]
}

###############################################################################
# permissions and wiring
###############################################################################

resource "azurerm_role_assignment" "workspace_reader" {
  scope                = local.workspace_id
  principal_id         = var.automation_principal_id
  role_definition_name = "Log Analytics Reader"
  description          = "Query the audit log to find credentials that were read."
}

resource "azurerm_role_assignment" "metrics_publisher" {
  scope                = azurerm_monitor_data_collection_rule.this.id
  principal_id         = var.automation_principal_id
  role_definition_name = "Monitoring Metrics Publisher"
  description          = "Write rotation records through the data collection rule."
}

# Switches the feature on in the runbook without redeploying it.
resource "azurerm_automation_variable_string" "settings" {
  for_each = {
    CR_WorkspaceId            = local.workspace_guid
    CR_DataCollectionEndpoint = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
    CR_DataCollectionRuleId   = azurerm_monitor_data_collection_rule.this.immutable_id
    CR_StreamName             = local.stream_name
  }

  name                    = each.key
  resource_group_name     = var.resource_group_name
  automation_account_name = var.automation_account_name
  value                   = each.value
  encrypted               = false
}

resource "azurerm_application_insights_workbook" "this" {
  count = var.deploy_workbook ? 1 : 0

  name                = var.workbook_uuid
  resource_group_name = var.resource_group_name
  location            = var.location
  display_name        = "Credential access and rotation"
  description         = "Who read which credential, when it was replaced, and how long the exposure window was."
  source_id           = lower(local.workspace_id)
  category            = "workbook"
  tags                = var.tags

  data_json = templatefile("${path.module}/workbook.json", {
    workspace_id = local.workspace_id
  })
}
