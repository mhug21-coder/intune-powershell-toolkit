<#
.SYNOPSIS
    End-to-end runner for patch compliance and update-ring audit reporting.

.DESCRIPTION
    Orchestrates the full patch-reporting workflow in a single run, calling three
    scripts in sequence and gracefully skipping steps when their inputs aren't present:

      1. Report-PatchStatus.ps1          -> update-ring attribution per device
      2. External KB compliance script   -> KB-level compliance (optional, if present)
      3. Join-PatchAndRingReports.ps1     -> merges the two into a CRQ-ready report

    Sub-scripts are called relative to this script's own location ($PSScriptRoot), so
    the whole set can live in one folder and be run from anywhere. All outputs go to
    C:\TEMP. If the optional compliance data isn't available the runner still produces
    the ring audit on its own rather than failing.

.PARAMETER SkipIntuneExportCheck
    Skip the check that DevicesWithInventory.csv exists. Use when you only want the
    ring audit and not the KB compliance step.

.PARAMETER ExternalScriptPath
    Path to the optional external KB-compliance script (step 2). Defaults to the
    current folder.

.EXAMPLE
    # Export Intune devices first (see prereq below), then:
    .\Run-FullPatchReport.ps1

.NOTES
    Author : Matt Hughes
    ASCII-only, PowerShell 5.1 safe.

    Prereq for the compliance step: export Intune devices to
    C:\TEMP\IntunePatchingReport\DevicesWithInventory.csv
    (Intune portal > Devices > All devices > Export)
#>

param(
    [switch]$SkipIntuneExportCheck,
    [string]$ExternalScriptPath = ".\Manually_Create_Intune_Patch_Compliance_Calculation_Using_PowerShell.ps1"
)

$ErrorActionPreference = 'Stop'

# --- Paths ---
$ringAuditFolder    = "C:\TEMP\RingAudit"
$compReportFolder   = "C:\TEMP\IntunePatchingReport"
$deviceExportFile   = "$compReportFolder\DevicesWithInventory.csv"
$ringCsv            = "$ringAuditFolder\PatchStatus.csv"
$complianceCsv      = "$compReportFolder\Final_Patching_Report.csv"
$combinedCsv        = "$ringAuditFolder\CombinedPatchRingReport.csv"

# --- Ensure folders exist ---
New-Item -ItemType Directory -Path $ringAuditFolder  -Force | Out-Null
New-Item -ItemType Directory -Path $compReportFolder -Force | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Patch Status & Ring Audit - End-to-End Runner" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# CHECK: Intune device export
# =============================================================================
# The KB-compliance step needs an exported device inventory. If it's missing we
# don't fail - we just flag it and fall back to a ring-audit-only run.
$runCompliance = Test-Path $deviceExportFile
if (-not $runCompliance -and -not $SkipIntuneExportCheck) {
    Write-Host "[!] Intune device export not found at:" -ForegroundColor Yellow
    Write-Host "    $deviceExportFile" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    To get compliance data, do this first:" -ForegroundColor Yellow
    Write-Host "    1. Intune portal > Devices > All devices > Export" -ForegroundColor Yellow
    Write-Host "    2. Save the CSV as: $deviceExportFile" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    Proceeding with ring audit only (the external compliance script will be skipped)." -ForegroundColor Yellow
    Write-Host ""
}

# =============================================================================
# STEP 1 - Ring audit
# =============================================================================
Write-Host "[STEP 1/3] Running ring audit (Report-PatchStatus.ps1)..." -ForegroundColor Magenta
Write-Host ""

# Call sub-scripts relative to this runner's own folder so the set is portable
& "$PSScriptRoot\Report-PatchStatus.ps1" -OutputPath $ringCsv

if (-not (Test-Path $ringCsv)) {
    Write-Host "[!] Ring audit did not produce expected output. Stopping." -ForegroundColor Red
    return
}

# =============================================================================
# STEP 2 - the external compliance script
# =============================================================================
if ($runCompliance) {
    Write-Host ""
    Write-Host "[STEP 2/3] Running external KB compliance script..." -ForegroundColor Magenta
    Write-Host ""

    if (Test-Path $ExternalScriptPath) {
        & $ExternalScriptPath
    } else {
        Write-Host "[!] External compliance script not found at: $ExternalScriptPath" -ForegroundColor Yellow
        Write-Host "    Skipping step 2." -ForegroundColor Yellow
        $runCompliance = $false
    }
} else {
    Write-Host ""
    Write-Host "[STEP 2/3] Skipped (no device export file)." -ForegroundColor Yellow
    Write-Host ""
}

# =============================================================================
# STEP 3 - Join
# =============================================================================
if ($runCompliance -and (Test-Path $complianceCsv)) {
    Write-Host ""
    Write-Host "[STEP 3/3] Joining reports..." -ForegroundColor Magenta
    Write-Host ""

    & "$PSScriptRoot\Join-PatchAndRingReports.ps1" `
        -RingReport       $ringCsv `
        -ComplianceReport $complianceCsv `
        -OutputPath       $combinedCsv
} else {
    Write-Host ""
    Write-Host "[STEP 3/3] Skipped (no compliance data to join)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Ring audit CSV is available at: $ringCsv" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Done." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Outputs:" -ForegroundColor Cyan
Write-Host "  Ring audit  : $ringCsv"
if (Test-Path $complianceCsv) { Write-Host "  Compliance  : $complianceCsv" }
if (Test-Path $combinedCsv)   { Write-Host "  Combined    : $combinedCsv" }
Write-Host ""
