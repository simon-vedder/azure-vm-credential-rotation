###############################################################################
# rotate-on-access
#
# Turns on rotation after use.
#
# Deliberately thin. The logic lives in the runbook; this module is the switch and
# its settings. That is what makes it independently deployable: add it and reads
# start pulling expiry dates forward, remove it and the system falls back to plain
# calendar rotation without anything else changing.
#
# Requires the observability module, because the mechanism is a query against the
# Key Vault audit log in the workspace it creates.
###############################################################################

locals {
  # The automation account reads its own staged secrets during recovery. Those reads
  # carry no upn claim and are already filtered out, but excluding the identity
  # explicitly means the tool can never trigger itself.
  excluded_object_ids = distinct(concat([var.automation_principal_id], var.additional_excluded_object_ids))

  settings = {
    CR_AccessRotationEnabled = "true"
    CR_GracePeriodHours      = tostring(var.grace_period_hours)
    CR_AccessLookbackHours   = tostring(var.access_lookback_hours)
    CR_ExcludeObjectId       = join(",", local.excluded_object_ids)
  }
}

resource "azurerm_automation_variable_string" "settings" {
  for_each = local.settings

  name                    = each.key
  resource_group_name     = var.resource_group_name
  automation_account_name = var.automation_account_name
  value                   = each.value
  encrypted               = false

  lifecycle {
    precondition {
      # Log Analytics ingestion lags by minutes, and a read that lands just after a
      # run must still be visible to the next one. A lookback shorter than the gap
      # between runs drops those reads silently - the worst kind of failure here,
      # because nothing reports it.
      condition     = var.access_lookback_hours > var.schedule_interval_hours
      error_message = "access_lookback_hours (${var.access_lookback_hours}) must exceed schedule_interval_hours (${var.schedule_interval_hours}), otherwise reads between runs are missed. Twice the interval is a reasonable starting point."
    }
  }
}
