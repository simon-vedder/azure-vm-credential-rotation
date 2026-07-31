# When not to use this

Most people who land here should use something else. This page is the honest filter.

## Use Windows LAPS instead

If a Windows machine is **Entra-joined, hybrid-joined or AD-joined**, Windows LAPS is
the answer. It is part of the operating system, costs nothing, and does several things
this project cannot:

- rotates the password automatically **after it is used**, natively
- stores it in Entra ID or Active Directory, not in a vault you have to secure
- enforces retrieval through a directory permission model with its own audit trail
- needs no extension, no runbook, no managed identity, no schedule

The catch is the join requirement. LAPS has no story for a standalone Azure VM,
because there is no directory to store the password in.

## Use Entra login for Azure VMs instead

Better still, do not issue a local credential at all.
[Entra login for Azure VMs](https://learn.microsoft.com/en-us/entra/identity/devices/howto-vm-sign-in-azure-ad-windows)
works for Windows and Linux, supports Conditional Access and MFA, and replaces local
accounts with directory identities. A credential that does not exist cannot leak,
cannot be rotated late, and does not need this repository.

If you can deploy the extension across your estate, do that first and come back only
for the machines that are left.

## Use a PAM product instead

If you need session recording, approval workflows, credential checkout, or rotation
across more than Azure VMs, this is not that. CyberArk, Delinea, HashiCorp Vault and
Teleport solve a bigger problem and are worth their price when you have it.

This project deliberately implements one slice: issue, rotate, record. If you find
yourself adding approval flows to it, you have outgrown it.

## Use dynamic credentials instead

The strongest version of this idea is to stop storing credentials altogether:
generate one when someone asks, set it, hand it over, expire it a few hours later.
HashiCorp Vault's SSH secrets engine does exactly that, and Teleport goes further with
short-lived certificates.

This repository is the scheduled-rotation step on the way there. See
[ADR 0003](decisions/0003-expiry-date-as-single-signal.md) for why the design leaves
room for that and what would have to change.

---

## So who is this for

Everything the options above cannot reach:

| situation | why the alternatives do not apply |
|---|---|
| Standalone Azure VMs, no directory join | LAPS requires a join |
| **Linux SSH keys** | no native Azure rotation exists at all; Entra login replaces keys, it does not rotate them |
| Jump boxes, DMZ hosts, isolated workloads | often deliberately not joined |
| Appliance and vendor images | you do not control what runs on them |
| Customer tenants without identity integration | not yours to change |
| Break-glass local accounts on otherwise-managed machines | must work when the directory does not |

The Linux row is the strongest case. Windows has LAPS; SSH keys on Azure VMs have
nothing, and a key that was generated at deployment and never touched again is the
normal state of most estates.

## And one honest caveat

Rotating a credential is the second-best outcome. The best is not having one. If
reading this page makes you realise you could enable Entra login instead, that is the
better afternoon's work — and this project will still be here for whatever is left
over.
