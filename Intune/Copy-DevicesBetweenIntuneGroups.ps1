<#
.SYNOPSIS
    Copy all device members from one Intune / Entra group into another.

.DESCRIPTION
    Reads every device member of a source group and adds them to a target group.
    Built to run reliably against a large tenant:

      - Resilient request wrapper retries on throttling (HTTP 429) using the
        Retry-After header where Graph provides it, falling back to exponential backoff.
      - Retries transient server errors (500/502/503/504) with backoff.
      - Auto-reconnects if the access token expires mid-run (HTTP 401).
      - Pages through the full source membership via @odata.nextLink (not capped at
        the first 100/999 results).
      - Skips devices already in the target group, and writes Added / AlreadyPresent /
        Failed logs so the run is auditable.

.PARAMETER sourceGroupName
    Set inline below. Display name of the group to copy members FROM.

.PARAMETER targetGroupName
    Set inline below. Display name of the group to copy members TO.

.EXAMPLE
    # Edit the three variables in the User Input Section, then run:
    .\Copy-DevicesBetweenIntuneGroups.ps1

.NOTES
    Author:       Matt Hughes
    Last Updated: 28 May 2026

    Connection rewritten to use an explicit ClientID / TenantID App Registration
    (matching the Bulk Add script) to fix intermittent Graph drops on long runs.

    Requires: Microsoft.Graph module (auto-installed if missing).
#>

#============================= User Input Section ==============================

$sourceGroupName = "Intune-SourceDevices"          # copy members FROM this group
$targetGroupName = "App-Install-TargetGroup"        # copy members TO this group

$logDir = "C:\Temp"

#============================= Connection Settings =============================
# Delegated auth via a dedicated App Registration (replace with your own IDs).
$clientId = "11111111-1111-1111-1111-111111111111"
$tenantId = "00000000-0000-0000-0000-000000000000"

#============================= Module Setup ====================================
Clear-Host
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "====== Copy Devices Between Intune Groups =========================" -ForegroundColor Magenta
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop'

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "Microsoft.Graph module not found. Installing..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
}

Import-Module Microsoft.Graph.Authentication -Force

#============================= Connect to Graph ================================
# Wrapped in a function so the retry logic can re-invoke it on token expiry
function Connect-Graph {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}  # clear stale session
    Connect-MgGraph -ClientID $clientId -TenantID $tenantId -NoWelcome

    $ctx = Get-MgContext
    if (-not $ctx) {
        Write-Host "[ERROR] Failed to connect to Microsoft Graph. Exiting." -ForegroundColor Red
        exit 1
    }
    return $ctx
}

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
$context = Connect-Graph
Write-Host "[OK] Connected as: $($context.Account)" -ForegroundColor Green
Write-Host "[OK] TenantId:     $($context.TenantId)" -ForegroundColor Green

#============================= Resilient Request Wrapper =======================
# Central wrapper for every Graph call so retry/backoff logic lives in one place.
# Retries on 429 (throttle), transient 5xx, and reconnects on 401 token expiry.

function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $Method,
        [string] $Body,
        [int]    $MaxRetries = 5
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($Body) {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -Body $Body -ContentType "application/json" -ErrorAction Stop
            } else {
                return Invoke-MgGraphRequest -Uri $Uri -Method $Method -ErrorAction Stop
            }
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            $msg    = $_.Exception.Message

            # "Already exists" is a real outcome the caller wants to handle, not a
            # retryable error - bubble it straight up rather than burning retries on it
            if (($_ | Out-String) -like '*added object references already exist*') { throw }

            if ($attempt -ge $MaxRetries) {
                throw   # out of retries - let the caller log it as a failure
            }

            switch ($status) {
                401 {
                    # Token expired part-way through a long run - reconnect and try again
                    Write-Host "    [AUTH] Token expired - reconnecting..." -ForegroundColor Yellow
                    $script:context = Connect-Graph
                }
                429 {
                    # Throttled - honour Graph's Retry-After header if present, else exponential backoff
                    $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds
                    if (-not $retryAfter -or $retryAfter -lt 1) { $retryAfter = [Math]::Pow(2, $attempt) }
                    Write-Host "    [THROTTLE] 429 - waiting $retryAfter s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $retryAfter
                }
                { $_ -in 500,502,503,504 } {
                    # Transient server-side error - back off and retry
                    $wait = [Math]::Pow(2, $attempt)
                    Write-Host "    [TRANSIENT] $status - retry in $wait s..." -ForegroundColor DarkYellow
                    Start-Sleep -Seconds $wait
                }
                default { throw }   # genuine error (404 etc.) - don't retry, surface it
            }
        }
    }
}

#============================= Find Groups =====================================

Write-Host ""
Write-Host "[SEARCH] Finding groups..." -ForegroundColor Cyan

# Backtick escapes $filter so PowerShell leaves it in the URL instead of expanding it
$srcUri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$sourceGroupName'"
$tgtUri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$targetGroupName'"

$sourceGroup = (Invoke-GraphWithRetry -Uri $srcUri -Method GET).value | Select-Object -First 1
$targetGroup = (Invoke-GraphWithRetry -Uri $tgtUri -Method GET).value | Select-Object -First 1

if (-not $sourceGroup) { Write-Host "[ERROR] Source group not found: $sourceGroupName" -ForegroundColor Red; Disconnect-MgGraph; exit 1 }
if (-not $targetGroup) { Write-Host "[ERROR] Target group not found: $targetGroupName" -ForegroundColor Red; Disconnect-MgGraph; exit 1 }

Write-Host "[OK] Source: $sourceGroupName ($($sourceGroup.id))" -ForegroundColor Green
Write-Host "[OK] Target: $targetGroupName ($($targetGroup.id))" -ForegroundColor Green

#============================= Get Source Devices ==============================

Write-Host ""
Write-Host "[INFO] Reading devices from source group..." -ForegroundColor Cyan

# $top=999 pulls the max page size; the do/while follows @odata.nextLink so we get
# the complete membership even when it spans multiple pages
$uri = "https://graph.microsoft.com/v1.0/groups/$($sourceGroup.id)/members?`$top=999"
$allDevices = @()

do {
    $response = Invoke-GraphWithRetry -Uri $uri -Method GET
    # A group can hold users and devices - keep only device objects
    $devices  = $response.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.device' }
    $allDevices += $devices
    $uri = $response.'@odata.nextLink'   # null when there are no more pages, ending the loop
    Write-Host "  Found $($allDevices.Count) devices so far..." -ForegroundColor Gray
} while ($uri)

Write-Host "[OK] Total devices to copy: $($allDevices.Count)" -ForegroundColor Green

if ($allDevices.Count -eq 0) {
    Write-Host "[INFO] Nothing to copy. Exiting." -ForegroundColor Yellow
    Disconnect-MgGraph
    exit 0
}

#============================= Log File Setup ==================================

if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$timestamp      = Get-Date -Format "yyyyMMdd-HHmmss"   # stamp logs so re-runs don't overwrite
$addedLogPath   = Join-Path $logDir "CopyDevices-Added-$timestamp.txt"
$alreadyLogPath = Join-Path $logDir "CopyDevices-AlreadyPresent-$timestamp.txt"
$failedLogPath  = Join-Path $logDir "CopyDevices-Failed-$timestamp.txt"

#============================= Add to Target ===================================

Write-Host ""
Write-Host "Adding devices to target group..." -ForegroundColor Yellow
Write-Host "--------------------------------------------------------------------"

$added = 0; $skipped = 0; $failed = 0
$counter = 0

foreach ($device in $allDevices) {
    $counter++
    $name = $device.displayName
    Write-Host "[$counter/$($allDevices.Count)] $name... " -NoNewline

    # Membership is added by POSTing the device's directory URL to the target's members/$ref endpoint
    $addUri = "https://graph.microsoft.com/v1.0/groups/$($targetGroup.id)/members/`$ref"
    $body   = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($device.id)" } | ConvertTo-Json -Depth 3

    try {
        Invoke-GraphWithRetry -Uri $addUri -Method POST -Body $body | Out-Null
        Write-Host "Added" -ForegroundColor Green
        Add-Content -Path $addedLogPath -Value $name
        $added++
    }
    catch {
        # Treat "already a member" as a skip, not a failure
        if (($_ | Out-String) -like '*added object references already exist*') {
            Write-Host "Already there" -ForegroundColor Cyan
            Add-Content -Path $alreadyLogPath -Value $name
            $skipped++
        }
        else {
            Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red
            Add-Content -Path $failedLogPath -Value $name
            $failed++
        }
    }
}

#============================= Summary =========================================

Write-Host ""
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host " SUMMARY" -ForegroundColor Magenta
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "  Total processed:  $($allDevices.Count)" -ForegroundColor White
Write-Host "  Added:            $added"   -ForegroundColor Green
Write-Host "  Already present:  $skipped" -ForegroundColor Cyan
Write-Host "  Failed:           $failed"  -ForegroundColor Red
Write-Host ""
Write-Host "  Logs:" -ForegroundColor White
Write-Host "    Added:           $addedLogPath"   -ForegroundColor Gray
Write-Host "    Already Present: $alreadyLogPath" -ForegroundColor Gray
Write-Host "    Failed:          $failedLogPath"  -ForegroundColor Gray
Write-Host "====================================================================" -ForegroundColor Magenta

Disconnect-MgGraph
Write-Host "[OK] Disconnected from Graph. Done." -ForegroundColor Green
