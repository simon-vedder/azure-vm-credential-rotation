###############################################################################
# Full deployment: calendar rotation, audit trail and rotation after use.
#
# The three modules stack. core works alone; observability adds the workspace, the
# custom table and the workbook; rotate-on-access switches on the behaviour that
# makes the audit trail worth having.
#
# Worst case between someone reading a credential and it being replaced is the
# grace period plus one schedule interval - 14 hours with the values below. If that
# is too long, shorten the schedule interval first; it is the cheaper of the two.
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100, < 5.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">= 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

locals {
  schedule_interval_hours = 6
  grace_period_hours      = 8
}

module "rotation" {
  source = "../../modules/core"

  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  automation_account_name = var.automation_account_name

  key_vault_id   = data.azurerm_key_vault.this.id
  key_vault_name = data.azurerm_key_vault.this.name
  vm_scopes      = var.vm_scopes

  threshold_days          = 14
  validity_days           = 90
  schedule_interval_hours = local.schedule_interval_hours
  dry_run                 = var.dry_run

  tags = var.tags
}

module "observability" {
  source = "../../modules/observability"

  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  key_vault_id            = data.azurerm_key_vault.this.id
  automation_account_id   = module.rotation.automation_account_id
  automation_account_name = module.rotation.automation_account_name
  automation_principal_id = module.rotation.principal_id

  retention_days = var.retention_days

  tags = var.tags
}

module "rotate_on_access" {
  source = "../../modules/rotate-on-access"

  resource_group_name     = azurerm_resource_group.this.name
  automation_account_name = module.rotation.automation_account_name
  automation_principal_id = module.rotation.principal_id

  schedule_interval_hours = local.schedule_interval_hours
  grace_period_hours      = local.grace_period_hours
  access_lookback_hours   = local.schedule_interval_hours * 4

  # The workspace has to exist before the runbook is told to query it.
  depends_on = [module.observability]
}

output "worst_case_exposure_hours" {
  description = "Upper bound between a credential being read and being replaced."
  value       = module.rotate_on_access.worst_case_exposure_hours
}

output "next_steps" {
  value = <<-EOT

    Deployed. Before this does anything:

      1. Tag the VMs you want rotated:
           az vm update --ids <id> --set tags.CredentialRotation=enabled

      2. Dry run, and read the output:
           az automation runbook start \
             --resource-group ${azurerm_resource_group.this.name} \
             --automation-account-name ${module.rotation.automation_account_name} \
             --name ${module.rotation.runbook_name} \
             --parameters DryRun=true

      3. Set dry_run = false and apply again.

    Verify the audit trail once a rotation has happened. Read a secret yourself,
    wait for ingestion, then check that the query in queries/accessed-secrets.kql
    finds your read - the column names in AZKVAuditLogs are the one part of this
    that has to be confirmed against a live workspace.

    Worst case exposure with these settings: ${module.rotate_on_access.worst_case_exposure_hours} hours.
  EOT
}
