# Intune, SCCM & AVD PowerShell Toolkit

PowerShell scripts for enterprise endpoint management — Microsoft Intune, SCCM/MECM,
Azure Virtual Desktop, Entra ID and Microsoft Graph. Built while running a
estate through an SCCM-to-Intune migration.

## Folders

- **Intune** — device and group management via Microsoft Graph
- **SCCM** — collection work and SCCM-to-Intune migration
- **AVD** — Azure Virtual Desktop dynamic groups
- **Remediations** — Intune Proactive Remediation detect/remediate pairs
- **Reporting** — patch compliance and update-ring reporting

## Scripts

**Intune**
- `Add-BulkDevicesToIntuneGroup.ps1` — add devices to a group from a text file
- `Copy-DevicesBetweenIntuneGroups.ps1` — copy membership between two groups
- `Set-IntunePrimaryUser-BulkFromCSV.ps1` — bulk-update primary users from a CSV

**SCCM**
- `Migrate-SCCMCollectionToIntuneGroup.ps1` — move an SCCM collection's devices into an Intune group
- `Compare-SCCMCollectionVsIntuneGroup.ps1` — compare a collection against a group

**AVD**
- `Create-AVD-SessionHosts-DynamicGroup.ps1` — create a dynamic group for AVD session hosts

**Remediations**
- `Detect-WUTelemetry.ps1` — collect Windows Update health as JSON
- `Remediate-WUTelemetry.ps1` — reset Windows Update components

**Reporting**
- `Run-FullPatchReport.ps1` — run the full patch + ring report end to end

## Notes

- Graph scripts use delegated sign-in. Replace the placeholder `ClientId` / `TenantId`
  with your own.
- SCCM scripts need the ConfigMgr module and your site code / server.
- All tenant IDs, group names and host names are placeholders — update them for your
  environment before running.

Maintained by Matt Hughes.
