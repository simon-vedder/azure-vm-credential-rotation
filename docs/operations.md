# Operations

## First run

Do these in order. The tool changes local administrator credentials; being careless
here means locking yourself out of machines.

1. **Deploy with `dry_run = true`.** The schedule runs, discovers, reports, changes
   nothing.
2. **Tag one machine you can afford to lose.**
   `az vm update --ids <id> --set tags.CredentialRotation=enabled`
3. **Start the runbook by hand and read the whole output.** Check that it found the
   machine, resolved the right admin username and the right secret name.
4. **Turn off dry run for that one machine**, let it rotate, then *use* the credential:
   RDP or SSH in with what is now in the vault. Dry run is the automation variable
   `CR_DryRun`; redeploy with `dryRun=false`, or flip it in place:

   ```bash
   az automation variable update -g rg-credential-rotation --automation-account-name aa-credential-rotation \
     --name CR_DryRun --value '"false"'
   ```
5. **Then widen the tag.**

## Everyday tasks

**Rotate one machine now**

```bash
az automation runbook start \
  --resource-group rg-credential-rotation \
  --automation-account-name aa-credential-rotation \
  --name Invoke-CredentialRotation
```

To force a specific machine rather than waiting for its expiry date, bring the date
forward — the same mechanism access-driven rotation uses:

```bash
az keyvault secret set-attributes --vault-name kv-creds \
  --name "vm01-azureadmin-pw" --expires "$(date -u -v+1H '+%Y-%m-%dT%H:%M:%SZ')"
```

**Stop rotating a machine**

```bash
az vm update --ids <id> --set tags.CredentialRotationHold=true     # temporary
az vm update --ids <id> --remove tags.CredentialRotation           # permanent
```

**During an incident.** If someone needs sustained access to a local account, set the
hold tag *before* they read the credential. Otherwise the read pulls the expiry date
forward and the credential is replaced under them mid-incident.

## When something goes wrong

**A machine keeps being skipped.** Almost always powered off. The workbook's *stuck*
panel shows how long. A machine skipped for longer than the threshold will have its
secret expire — the value stays readable (Key Vault allows `get` on expired secrets,
deliberately, for recovery), but it stops being rotated on schedule and starts showing
up as overdue.

**A rotation failed.** The job is marked Failed and the output names the machine. Most
common causes: guest agent unhealthy, extension provisioning already in progress, or
the VM stopped mid-run. All are retried next run; nothing needs to be done by hand.

**A rotation was interrupted.** A `<name>-pending` secret with `State=pending` means a
run died between applying a credential and storing it. The next run resumes it
automatically. Do not delete the pending secret — it may hold the only copy of the
credential the machine is currently using.

**The credential in the vault does not work.** Check `<name>-pending` first. If it is
open, the machine probably has *that* value; try it before doing anything drastic. Then
check whether someone changed the password out of band.

**Locked out entirely.** Serial console through Azure Bastion, or reset via the
VMAccess extension from the portal. Both need the VM running.

## Health checks worth running

The queries in [`queries/`](../queries) are the starting point:

- `overdue-secrets.kql` — credentials past or near expiry that were not rotated. This
  is the check that matters; a job that never ran produces no failures.
- `rotation-timeline.kql` — reads correlated with rotations, with the exposure window.
- `accessed-secrets.kql` — the query the runbook itself uses. Run it after your first
  manual read to confirm the column names match your workspace.

The last point is worth repeating: the `AZKVAuditLogs` schema differs from the legacy
`AzureDiagnostics` one, and access-driven rotation depends on it. Verify it once, on a
real workspace, before relying on it.

## Things that will surprise someone eventually

- **A hardened guest may expire the password first.** The tool sets a credential; it does not
  read the guest's own aging policy. If the machine enforces a maximum password age shorter
  than `validityDays` - the CIS STIG image for Ubuntu uses 60 days against a default of 90 -
  the password expires in the guest weeks before anything schedules a rotation. Set
  `validityDays` below the shortest maximum age in the estate.
- **Copies of credentials go stale.** Anything written into a CMDB, a wiki or a
  personal password manager stops working after a rotation, silently. Point people at
  the vault rather than at a copy.
- **Reading a credential schedules its replacement.** That is the design, and it is
  not obvious to a colleague who just wanted to check something.
- **Applications reading secrets do not trigger rotation** — reads without a UPN claim
  are ignored on purpose, because rotating under a running workload breaks it. They are
  still visible in the workbook, and an application holding a VM administrator password
  is worth a question of its own.
