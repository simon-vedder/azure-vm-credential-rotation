# Threat model

What this protects against, what it does not, and what it introduces.

## What it protects against

**A credential that never changes.** The base case: a password set at deployment,
still valid three years later, present in every backup, image and handover document
made since. Calendar rotation bounds that exposure to the validity period.

**A credential that has been used.** Once someone reads a password out of the vault it
has been in a clipboard, a terminal scrollback, an RDP client, possibly a screen share
or a ticket. Access-driven rotation shortens that window from months to hours.

**Silent access.** Even without rotation, the audit trail answers "who had the local
administrator password for this machine in September" — a question that is otherwise
unanswerable in most estates.

## What it does not protect against

**An attacker with the rotating identity.** The automation identity can install
extensions on every VM in scope, which is code execution as SYSTEM or root. Compromise
it and rotation is the least of your problems. Scope it narrowly, and treat the
automation account as a Tier 0 asset.

**An attacker already on the machine.** Rotating the password does not evict a session,
a scheduled task, a service account or an implanted key. Rotation is hygiene, not
incident response.

**Credentials outside Key Vault.** Copies in a CMDB, a wiki or a colleague's password
manager go stale silently after a rotation. That is a feature for security and a
support call for operations — see [operations.md](operations.md).

**Reads that are not `SecretGet`.** Someone with Key Vault Contributor can grant
themselves access, back up a secret, or read it from a replica. The audit trail
records the grant, but the access query looks for reads.

## What it introduces

These are real costs, not hypotheticals.

### VMAccess recreates deleted accounts

The extension takes the username from the VM's OS profile. **If that account no longer
exists on the machine, VMAccess creates it — as a local administrator.**

Somebody may have removed or disabled that account on purpose, as part of hardening or
an offboarding. This tool will quietly restore it on the next rotation, and the audit
trail will show a successful rotation rather than a re-created admin account.

*Mitigation:* remove the tag from machines whose OS-profile account should not exist,
and treat `Missing` rotations on old machines as worth a look.

*Measured, 2026-09-08* (`tests/manual/Invoke-RenamedAccountProbe.ps1`): on Windows the
extension created a new account under the OS-profile name (RID 1000, Administrators) beside
the renamed original (RID 500) and reported `Rotated`. On Linux `useradd` refused, because
the renamed account still owned the uid and the home directory, and the rotation was
recorded as `Failed` with the value still staged. Details in
[KNOWN-ISSUES](../KNOWN-ISSUES.md#the-account-was-renamed-inside-the-guest).

### VMAccess restores passwordless sudo on Linux

The extension writes `/etc/sudoers.d/waagent` with `<user> ALL = (ALL) NOPASSWD: ALL` for the
account named in the OS profile. Where cloud-init already granted that, nothing changes. Where
somebody took it away on purpose, **every rotation puts it back**.

*Measured, 2026-09-08*: both sudoers files were removed, one rotation was run, and `waagent`
came back with `NOPASSWD: ALL`. See
[KNOWN-ISSUES](../KNOWN-ISSUES.md#what-a-rotation-changes-besides-the-credential).

*Mitigation:* keep such machines out of scope, or let configuration management reassert the
sudoers policy after a rotation. There is no switch on the extension for this.

### The identity needs extension-install rights

Virtual Machine Contributor cannot be narrowed further for this purpose — setting a
credential on a running VM has no lower-privilege path. A custom role limited to
`Microsoft.Compute/virtualMachines/extensions/write` on the VMAccess publisher is not
expressible in Azure RBAC, which does not filter on extension type.

*Mitigation:* assign at resource-group scope, one group per trust boundary. Do not
assign at subscription or management-group scope for convenience.

### SSH rotation can break access

`remove_prior_keys` wipes every entry in `authorized_keys`. `reset_ssh` can restore
`sshd_config` to its default and undo hardening. Most examples on the internet set both
to true; **this project defaults both to false**, which means a rotated key is *added*
alongside existing ones rather than replacing them.

That is the safer default and the weaker guarantee: an old key stays valid until
someone removes it. If this tool genuinely owns every key on a machine, turn
`remove_prior_keys` on and accept the blast radius.

### The vault becomes a single point of failure

Every credential for every opted-in machine sits in one vault, reachable by one
identity. That concentration is the point — it is also worth soft-delete, purge
protection, private endpoints and diagnostic settings, none of which this project
configures for you.

### Rotation can interrupt work

Changing a password does not end an established RDP or SSH session, but it breaks
reconnects, UAC elevation and anything that re-authenticates. The grace period exists
for this. During an incident — when someone actually needs the local account — set
`CredentialRotationHold=true` and take the tag off afterwards.

## Data handling

- The rotation records contain **no credential material**. Secret *versions* are
  recorded so a rotation can be correlated with the vault's audit log, but a version
  identifier is not a secret.
- Job output carries VM names, secret names and usernames — not values. Anyone with
  read access to the automation account or the workspace sees that metadata.
- The staging secret holds a real credential for the duration of a rotation, and
  remains readable if a rotation is interrupted. It is closed on the next successful
  run.
- `AZKVAuditLogs` records the UPN and source IP of everyone who reads a credential.
  In the EU that is personal data under GDPR; the workspace retention setting is your
  retention policy, so choose it deliberately.
