###############################################################################
# Minimal deployment: calendar-driven rotation only.
#
# What you get: a runbook on a schedule that rotates credentials as they approach
# their expiry date, and stores them in an existing Key Vault. No audit trail, no
# rotation after use.
#
# This is the honest starting point. Run it in dry-run mode against a handful of
# tagged VMs, read the job output, then set dry_run to false.
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100, < 5.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = var.key_vault_resource_group
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

module "rotation" {
  source = "../../modules/core"

  resource_group_name     = azurerm_resource_group.this.name
  location                = azurerm_resource_group.this.location
  automation_account_name = var.automation_account_name

  key_vault_id   = data.azurerm_key_vault.this.id
  key_vault_name = data.azurerm_key_vault.this.name

  # Narrow on purpose. Virtual Machine Contributor here means extension install
  # rights, which is code execution on every VM in scope.
  vm_scopes = var.vm_scopes

  threshold_days          = 14
  validity_days           = 90
  schedule_interval_hours = 6

  # Leave this on until you have read one run's output.
  dry_run = var.dry_run

  tags = var.tags
}

output "next_steps" {
  value = <<-EOT

    Deployed. Before this does anything:

      1. Tag the VMs you want rotated:
           az vm update --ids <id> --set tags.CredentialRotation=enabled

      2. Start the runbook by hand and read the output:
           az automation runbook start \
             --resource-group ${azurerm_resource_group.this.name} \
             --automation-account-name ${module.rotation.automation_account_name} \
             --name ${module.rotation.runbook_name} \
             --parameters DryRun=true

      3. When the output looks right, set dry_run = false and apply again.

    To stop rotation for a single machine without removing the tag:
      az vm update --ids <id> --set tags.CredentialRotationHold=true
  EOT
}
