terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100, < 5.0"
    }
    # Log Analytics custom tables have no first-class azurerm resource; azapi talks
    # to the ARM API directly.
    azapi = {
      source  = "azure/azapi"
      version = ">= 2.0"
    }
  }
}
