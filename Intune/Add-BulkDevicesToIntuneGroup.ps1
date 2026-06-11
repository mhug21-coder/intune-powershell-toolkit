<#
.SYNOPSIS
    Bulk add devices to an Intune / Entra ID group via Microsoft Graph (delegated auth).

.DESCRIPTION
    Reads a list of device names from a text file (one per line) and adds the matching
    Entra ID device objects to a target security group. Uses a dedicated App Registration
    for delegated auth, so it relies on permissions already consented rather than prompting
    for new consent each run.

    The script is safe to re-run: devices already in the group are detected and skipped
    rather than erroring, and every device is written to one of three timestamped logs
    (Added / AlreadyPresent / Failed) so a run is fully auditable.

.PARAMETER targetGroupName
    Set inline below. The display name of the destination security group. If it doesn't
    exist, the script offers to create it as a new security group.

.PARAMETER deviceListPath
    Set inline below. Path to a .txt file containing one device name per line.

.EXAMPLE
    # Edit the two variables in the User Input Section, then run:
    .\Add-BulkDevicesToIntuneGroup.ps1

.NOTES
    Author : Matt Hughes
    Updated: May 2026

    Change history:
    - Switched from the default "Microsoft Graph Command Line Tools" client to a
      dedicated App Registration (permissions already consented)
    - Replaced full-tenant group enumeration with a $filter query (much faster on a
      large tenant — avoids pulling every group back to find one)
    - Added group-creation option if the target group doesn't exist

    Requires: Microsoft.Graph.Authentication module (auto-installed if missing).
#>

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
$ErrorActionPreference = 'Stop'

#============================= User Input Section ==============================
# >> UPDATE THESE TWO LINES FOR EACH RUN <<
$targetGroupName = "Windows_Update_Ring_3_Production"   # destination security group
$deviceListPath  = "C:\Temp\DeviceNames.txt"            # one device name per line

#============================= Graph Auth Config ===============================
# Delegated auth via a dedicated App Registration.
# A browser sign-in prompt appears on first run — sign in with your Org credentials.
# Replace these placeholder GUIDs with your own App Registration / tenant IDs.
#===============================================================================
$ClientId = "11111111-1111-1111-1111-111111111111"
$TenantId = "00000000-0000-0000-0000-000000000000"

#============================= Setup ==========================================
Clear-Host
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "=== Bulk Add Devices to Intune Group (v4) =========================" -ForegroundColor Magenta
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

# Fail fast if the input file is missing rather than connecting to Graph first
if (-not (Test-Path $deviceListPath)) {
    Write-Host "[ERROR] Device list file not found: $deviceListPath" -ForegroundColor Red
    return
}

# Load device names, dropping blank lines and trimming stray whitespace
$deviceList = Get-Content -Path $deviceListPath |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { $_.Trim() }

if (-not $deviceList -or $deviceList.Count -eq 0) {
    Write-Host "[ERROR] Device list is empty. Exiting." -ForegroundColor Red
    return
}

Write-Host "[INFO] Loaded $($deviceList.Count) devices from file" -ForegroundColor Cyan

#============================= Log File Paths =================================
# Logs are written next to the input file, stamped with run time so re-runs don't overwrite
$deviceListDir  = Split-Path -Path $deviceListPath
$deviceListBase = [System.IO.Path]::GetFileNameWithoutExtension($deviceListPath)
$timestamp      = Get-Date -Format "yyyyMMdd-HHmmss"
$addedLogPath   = Join-Path $deviceListDir "$deviceListBase-Added-$timestamp.txt"
$failedLogPath  = Join-Path $deviceListDir "$deviceListBase-Failed-$timestamp.txt"
$alreadyLogPath = Join-Path $deviceListDir "$deviceListBase-AlreadyPresent-$timestamp.txt"

#============================= Connect to Microsoft Graph =====================
Write-Host ""
Write-Host "[AUTH] Connecting to Microsoft Graph (Delegated Auth)..." -ForegroundColor Yellow

# Install the Graph module on first use if it isn't already present
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host "[SETUP] Installing Microsoft.Graph module..." -ForegroundColor Yellow
    Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# Clear any stale token/session so we always get a clean, predictable sign-in
try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}

try {
    Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -NoWelcome -ErrorAction Stop

    $ctx = Get-MgContext
    Write-Host "[OK] Connected as: $($ctx.Account) via App: $($ctx.ClientId)" -ForegroundColor Green
} catch {
    # Most connection failures are consent/sign-in related — surface a checklist rather than a raw stack trace
    Write-Host "[ERROR] Failed to connect to Graph: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "[!] Checklist:" -ForegroundColor Yellow
    Write-Host "    - Did the browser sign-in prompt appear?" -ForegroundColor Yellow
    Write-Host "    - Did you sign in with your Org account?" -ForegroundColor Yellow
    Write-Host "    - Has admin consent been granted on this App Registration?" -ForegroundColor Yellow
    return
}

#============================= Find or Create Group ============================
Write-Host ""
Write-Host "[SEARCH] Searching for group: $targetGroupName" -ForegroundColor Cyan

# Backtick escapes $filter so PowerShell doesn't treat it as a variable — it's part of the Graph URL
$groupResponse = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$targetGroupName'" -Method GET
$targetGroupId = $groupResponse.value[0].id

if (-not $targetGroupId) {
    Write-Host "[WARN] Group '$targetGroupName' not found." -ForegroundColor Yellow
    $createGroup = Read-Host "Create it as a new security group? (Y/N)"

    if ($createGroup -eq 'Y') {
        try {
            # mailNickname must be alphanumeric, so strip anything else out of the display name
            $groupBody = @{
                displayName     = $targetGroupName
                mailEnabled     = $false
                securityEnabled = $true
                mailNickname    = ($targetGroupName -replace '[^a-zA-Z0-9]', '').ToLower()
            } | ConvertTo-Json

            $createGroupResponse = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups" -Method POST -Body $groupBody -ContentType "application/json" -ErrorAction Stop
            $targetGroupId = $createGroupResponse.id
            Write-Host "[OK] Group created: $targetGroupName (ID: $targetGroupId)" -ForegroundColor Green
        } catch {
            Write-Host "[ERROR] Failed to create group: $_" -ForegroundColor Red
            Disconnect-MgGraph
            return
        }
    } else {
        Write-Host "[EXIT] Cannot continue without a target group." -ForegroundColor Red
        Disconnect-MgGraph
        return
    }
} else {
    Write-Host "[OK] Found group: $targetGroupName (ID: $targetGroupId)" -ForegroundColor Green
}

#============================= Process Devices ================================
Write-Host ""
Write-Host "[*] Processing devices..." -ForegroundColor Yellow
Write-Host "================================================"

$successCount = 0
$alreadyCount = 0
$failureCount = 0

foreach ($currentDeviceName in $deviceList) {
    Write-Host ""
    Write-Host "--> $currentDeviceName"

    # Resolve the device name to its Entra object ID (needed for the group membership call)
    try {
        $deviceLookupResponse = Invoke-MgGraphRequest `
            -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=displayName eq '$currentDeviceName'" `
            -Method GET -ErrorAction Stop
    } catch {
        Write-Host "    [FAIL] Device lookup error: $($_.Exception.Message)" -ForegroundColor Red
        Add-Content -Path $failedLogPath -Value $currentDeviceName
        $failureCount++
        continue
    }

    $currentDeviceId = $deviceLookupResponse.value[0].id

    # No match means the device isn't registered in Entra — log and move on
    if (-not $currentDeviceId) {
        Write-Host "    [WARN] Not found in Entra ID" -ForegroundColor Yellow
        Add-Content -Path $failedLogPath -Value $currentDeviceName
        $failureCount++
        continue
    }

    # Group membership is added by POSTing the object's directory URL to the group's members/$ref endpoint
    $addToGroupUrl = "https://graph.microsoft.com/v1.0/groups/$targetGroupId/members/`$ref"
    $jsonPayload = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$currentDeviceId"
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-MgGraphRequest -Uri $addToGroupUrl -Method POST -Body $jsonPayload -ContentType "application/json" -ErrorAction Stop
        Write-Host "    [ADDED]" -ForegroundColor Green
        Add-Content -Path $addedLogPath -Value $currentDeviceName
        $successCount++
    } catch {
        # Graph returns an error when the device is already a member; treat that as a skip, not a failure
        $fullErrorText = $_ | Out-String
        if ($fullErrorText -like '*already exist*') {
            Write-Host "    [SKIP] Already in group" -ForegroundColor Cyan
            Add-Content -Path $alreadyLogPath -Value $currentDeviceName
            $alreadyCount++
        } else {
            Write-Host "    [FAIL] $($_.Exception.Message)" -ForegroundColor Red
            Add-Content -Path $failedLogPath -Value $currentDeviceName
            $failureCount++
        }
    }
}

#============================= Summary ========================================
$totalProcessed = $successCount + $alreadyCount + $failureCount

Write-Host ""
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "====================================================================" -ForegroundColor Cyan
Write-Host "  Total Devices Processed: $totalProcessed"
Write-Host "  Devices Added:           $successCount" -ForegroundColor Green
Write-Host "  Already in Group:        $alreadyCount" -ForegroundColor Cyan
Write-Host "  Devices Failed:          $failureCount" -ForegroundColor Red
Write-Host ""
Write-Host "  Log Files:"
Write-Host "    Added:          $addedLogPath"
Write-Host "    Already Present: $alreadyLogPath"
Write-Host "    Failed:         $failedLogPath"
Write-Host "====================================================================" -ForegroundColor Cyan

#============================= Cleanup ========================================
Disconnect-MgGraph
Write-Host ""
Write-Host "[OK] Disconnected from Graph. Done." -ForegroundColor Green
