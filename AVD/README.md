# Intune, SCCM & AVD PowerShell Toolkit

A curated set of PowerShell scripts I've built and refined while running enterprise
endpoint management at scale — Microsoft Intune, SCCM/MECM, Azure Virtual Desktop,
Entra ID and Microsoft Graph. These come out of real day-to-day work managing a
~9,000-device estate through an SCCM-to-Intune co-management migration.

Everything here uses delegated Graph auth (interactive browser sign-in) or standard
SCCM cmdlets. All tenant IDs, app registration IDs, group IDs and organisation-specific
names have been replaced with placeholders — update them for your own environment
before running. Each script has comment-based help (run `Get-Help .\Script.ps1 -Full`).

## What's inside

### Intune
- **Add-BulkDevicesToIntuneGroup** — bulk-add devices to an Entra security group from a
  text file, using fast `$filter` queries, with optional group creation. Logs Added /
  AlreadyPresent / Failed.
- **Copy-DevicesBetweenIntuneGroups** — copy device membership between two groups, built
  for scale: throttling (429) retry with Retry-After, transient-error backoff,
  auto-reconnect on token expiry, and full pagination.
- **Set-IntunePrimaryUser-BulkFromCSV** — bulk-reassign the Intune primary user on devices
  from a CSV, using the current supported Graph method, skipping no-op rows and logging
  every action.

### SCCM
- **Migrate-SCCMCollectionToIntuneGroup** — bridge ConfigMgr and Graph: read an SCCM
  collection's devices and add them to an Intune group (creating it if needed). The core
  of SCCM-to-Intune co-management migration work.
- **Compare-SCCMCollectionVsIntuneGroup** — reconciliation report: which devices are in
  both, SCCM-only, or Intune-only. Read-only; uses hashtables for fast lookups and pages
  the full membership. Pairs with the migration script above.

### AVD
- **Create-AVD-SessionHosts-DynamicGroup** — create (or reuse) an Entra dynamic device
  group whose membership rule targets AVD session hosts by name — the cloud equivalent of
  an SCCM WQL collection — then polls while Entra populates membership.

### Remediations
Intune Proactive Remediation detect/remediate pair (detection exits 1 to trigger
remediation, 0 when healthy).

- **Detect-WUTelemetry** — collect a full Windows Update health picture (failed update
  events parsed for error code/KB, OS vs Store failures separated, Microsoft endpoint
  connectivity tests, service state, pending reboots) into JSON.
- **Remediate-WUTelemetry** — the standard WU component reset (stop services, clear
  SoftwareDistribution/catroot2, re-register DLLs, winsock reset, rescan) plus a
  self-cleaning scheduled task.

### Reporting
- **Run-FullPatchReport** — end-to-end orchestrator that chains the ring-audit and
  KB-compliance scripts into a single CRQ-ready report, skipping steps gracefully when
  their inputs aren't present.

## Notes

- Graph scripts expect an App Registration with the relevant delegated permissions
  consented. Swap the placeholder `ClientId` / `TenantId` for your own.
- SCCM scripts assume the ConfigMgr PowerShell module is available and you're connected
  to your site.
- Written and maintained by Matt Hughes — 20+ years in enterprise endpoint and
  application management.
