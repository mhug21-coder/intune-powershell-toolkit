<#
.SYNOPSIS
    Compare the membership of an SCCM collection against an Intune / Entra group.

.DESCRIPTION
    Reconciliation report for SCCM-to-Intune migration. Pulls the device list from
    a named SCCM collection and the device members of an Intune security group, then
    reports a three-way breakdown:

      - devices in BOTH
      - devices in the SCCM collection but NOT the Intune group
      - devices in the Intune group but NOT the SCCM collection

    Uses hashtables for O(1) name lookups (fast even on large collections) and pages
    through the full Graph results via @odata.nextLink. All differences are written
    to a CSV, with the first 20 of each category printed to the console for a quick look.

.PARAMETER SCCMCollectionName
    Set inline below. Name of the SCCM device collection to compare.

.PARAMETER IntuneGroupName
    Set inline below. Display name of the Intune / Entra group to compare against.

.PARAMETER OutputCSV
    Set inline below. Path the differences CSV is written to.

.EXAMPLE
    # Set the SCCM site details and the collection/group names below, then run:
    .\Compare-SCCMCollectionVsIntuneGroup.ps1

.NOTES
    Author : Matt Hughes

    Read-only - this script reports differences, it does not change membership.
    Pair it with Migrate-SCCMCollectionToIntuneGroup.ps1 to action the gaps.

    Requires:
      - ConfigMgr console / PowerShell module on the machine running this
      - Microsoft.Graph module (auto-installed if missing)
      - Delegated scopes: Group.Read.All, Device.Read.All

    Update the placeholder SiteCode / SiteServer for your own environment.
#>

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
$ErrorActionPreference = 'SilentlyContinue'

#============================= User Input Section ==============================
# >> UPDATE THESE FOR YOUR ENVIRONMENT <<
$SiteCode           = "ABC"                     # your SCCM site code
$SiteServer         = "sccm-server.contoso.com" # your SCCM primary site server FQDN
$SCCMCollectionName = "Example Pilot Collection"
$IntuneGroupName    = "App-Device-Example-Group"
$OutputCSV          = "C:\Temp\ComparisonResults.csv"

#============================= Setup ==============================
Clear-Host
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host "======= Compare SCCM Collection vs Intune Group ==================" -ForegroundColor Magenta
Write-Host "====================================================================" -ForegroundColor Magenta
Write-Host ""

if (-not (Test-Path "C:\Temp")) {
    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
}

#============================= Connect to SCCM ==============================
Write-Host "[*] Connecting to SCCM..." -ForegroundColor Yellow

try {
    # Load the ConfigMgr module from the installed console path and map the site drive
    Import-Module (Join-Path $(Split-Path $env:SMS_ADMIN_UI_PATH) ConfigurationManager.psd1) -ErrorAction Stop

    if (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $SiteCode -Force -ErrorAction SilentlyContinue
    }

    $drive = New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction Stop
    Write-Host "[+] SCCM Drive created: $($drive.Name)" -ForegroundColor Green
    Set-Location "$($SiteCode):"   # SCCM cmdlets must run from the site drive
} catch {
    Write-Host "[-] Error connecting to SCCM: $_" -ForegroundColor Red
    exit
}

#============================= Get SCCM Collection Devices ==============================
Write-Host "[*] Retrieving devices from SCCM collection..." -ForegroundColor Yellow

$collection = Get-CMCollection -Name $SCCMCollectionName
if (-not $collection) {
    Write-Host "[-] SCCM Collection not found: $SCCMCollectionName" -ForegroundColor Red
    Set-Location C:
    exit
}

$sccmDevices = Get-CMDevice -CollectionId $collection.CollectionID
if (-not $sccmDevices) {
    Write-Host "[-] No devices found in collection: $SCCMCollectionName" -ForegroundColor Red
    Set-Location C:
    exit
}

Write-Host "[+] Found $($sccmDevices.Count) devices in SCCM collection" -ForegroundColor Green

# Load SCCM names into a hashtable for O(1) lookups during the comparison
$sccmDeviceNames = @{}
foreach ($device in $sccmDevices) {
    $sccmDeviceNames[$device.Name] = $true
}

Set-Location C:   # leave the SCCM drive before doing Graph work

#============================= Connect to Graph ==============================
Write-Host "`n[*] Connecting to Microsoft Graph..." -ForegroundColor Yellow

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Host "[*] Installing Microsoft.Graph module..." -ForegroundColor Yellow
    Install-Module -Name Microsoft.Graph -Scope CurrentUser -Force -ErrorAction Stop
}

# Delegated sign-in - read-only scopes are all this comparison needs
Connect-MgGraph -Scopes "Group.Read.All", "Device.Read.All" -ErrorAction Stop
Write-Host "[+] Connected to Graph" -ForegroundColor Green

#============================= Get Intune Group Members ==============================
Write-Host "[*] Finding Intune group and retrieving members..." -ForegroundColor Yellow

# Pull all groups and match locally. A $filter on displayName fails when the name
# contains an '&' (e.g. "Desktops & Laptops"), so local matching is the safe approach.
$allGroupsUri = "https://graph.microsoft.com/v1.0/groups"
$allGroups = @()

while ($allGroupsUri) {
    $response = Invoke-MgGraphRequest -Uri $allGroupsUri -Method GET
    $allGroups += $response.value
    $allGroupsUri = $response.'@odata.nextLink'   # page until there's no next link
}

$targetGroup = $allGroups | Where-Object { $_.displayName -eq $IntuneGroupName }

if (-not $targetGroup) {
    Write-Host "[-] Intune Group not found: $IntuneGroupName" -ForegroundColor Red
    Disconnect-MgGraph
    exit
}

Write-Host "[+] Found Intune group: $IntuneGroupName" -ForegroundColor Green

# Page through the full group membership
$intuneMembers = @()
$membersUri = "https://graph.microsoft.com/v1.0/groups/$($targetGroup.id)/members"

while ($membersUri) {
    $response = Invoke-MgGraphRequest -Uri $membersUri -Method GET
    $intuneMembers += $response.value
    $membersUri = $response.'@odata.nextLink'
}

Write-Host "[+] Found $($intuneMembers.Count) members in Intune group" -ForegroundColor Green

# Hashtable of Intune device names - keep device objects only (groups can hold users too)
$intuneDeviceNames = @{}
foreach ($member in $intuneMembers) {
    if ($member.'@odata.type' -eq '#microsoft.graph.device') {
        $intuneDeviceNames[$member.displayName] = $true
    }
}

#============================= Compare ==============================
Write-Host "`n[*] Comparing groups..." -ForegroundColor Cyan

$inSCCMNotInIntune = @()
$inIntuneNotInSCCM = @()
$inBoth = 0

# Walk the SCCM side: each device is either in both, or SCCM-only
foreach ($deviceName in $sccmDeviceNames.Keys) {
    if ($intuneDeviceNames.ContainsKey($deviceName)) {
        $inBoth++
    } else {
        $inSCCMNotInIntune += [PSCustomObject]@{
            DeviceName = $deviceName
            Location   = "In SCCM Collection Only"
        }
    }
}

# Walk the Intune side: anything not in SCCM is Intune-only
foreach ($deviceName in $intuneDeviceNames.Keys) {
    if (-not $sccmDeviceNames.ContainsKey($deviceName)) {
        $inIntuneNotInSCCM += [PSCustomObject]@{
            DeviceName = $deviceName
            Location   = "In Intune Group Only"
        }
    }
}

#============================= Results ==============================
Write-Host "`n================================================" -ForegroundColor Yellow
Write-Host "  COMPARISON RESULTS" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Yellow
Write-Host "SCCM Collection: $SCCMCollectionName ($($sccmDevices.Count) devices)" -ForegroundColor White
Write-Host "Intune Group:    $IntuneGroupName ($($intuneMembers.Count) members)" -ForegroundColor White
Write-Host ""
Write-Host "  Devices in BOTH:            $inBoth" -ForegroundColor Green
Write-Host "  In SCCM, NOT in Intune:     $($inSCCMNotInIntune.Count)" -ForegroundColor Cyan
Write-Host "  In Intune, NOT in SCCM:     $($inIntuneNotInSCCM.Count)" -ForegroundColor Yellow
Write-Host "================================================`n" -ForegroundColor Yellow

# Combine both difference sets and export
$allDifferences = @()
$allDifferences += $inSCCMNotInIntune
$allDifferences += $inIntuneNotInSCCM

if ($allDifferences.Count -gt 0) {
    $allDifferences | Export-Csv -Path $OutputCSV -NoTypeInformation
    Write-Host "[i] Differences exported to: $OutputCSV" -ForegroundColor Cyan

    # Print a preview of each side (first 20) so you don't have to open the CSV for a quick check
    if ($inSCCMNotInIntune.Count -gt 0) {
        Write-Host "`nFirst 20 devices in SCCM but NOT in Intune:" -ForegroundColor Cyan
        $inSCCMNotInIntune | Select-Object -First 20 | Format-Table DeviceName -AutoSize
    }

    if ($inIntuneNotInSCCM.Count -gt 0) {
        Write-Host "`nFirst 20 devices in Intune but NOT in SCCM:" -ForegroundColor Yellow
        $inIntuneNotInSCCM | Select-Object -First 20 | Format-Table DeviceName -AutoSize
    }
} else {
    Write-Host "[+] All devices match. No differences found." -ForegroundColor Green
}

#============================= Cleanup ==============================
Disconnect-MgGraph
Write-Host "`n[+] Comparison complete" -ForegroundColor Green
