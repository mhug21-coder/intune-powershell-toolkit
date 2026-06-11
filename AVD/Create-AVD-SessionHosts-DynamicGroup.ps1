#Requires -Modules Microsoft.Graph.Groups

<#
.SYNOPSIS
    Create an Entra ID dynamic device group for a set of AVD session hosts.

.DESCRIPTION
    Creates (or reuses, if it already exists) an Entra ID dynamic device group whose
    membership rule targets AVD session-host devices by display-name prefix. This is
    the modern equivalent of an SCCM device collection built on a WQL query against an
    OU - here the equivalent logic lives in the group's dynamic membership rule, so
    hosts join automatically as they're named to the convention.

    After creating the group the script polls for a few minutes while Entra evaluates
    the rule and populates membership, then lists the devices that matched. The group
    is generic and reusable: assign any app that should target these session hosts to it.

.NOTES
    Author:  Matt Hughes
    Date:    2026-02-24
    Project: SCCM to Intune Migration - AVD Apps

    Requires delegated scope: Group.ReadWrite.All
    Update $MembershipRule with your own host-naming prefixes before running.
#>

# --- Configuration ---
$GroupName        = "AVD-CO-Session-Hosts"
$GroupDescription = "Dynamic device group for AVD session-host devices (migrated from SCCM collection)"

# Dynamic membership rule: match devices by host-name prefix. Replace these example
# prefixes with your own AVD host-naming convention. Each -startsWith clause is OR'd,
# so a device joins automatically if its name matches any one of them.
$MembershipRule   = '(device.displayName -startsWith "avd-co-01") or (device.displayName -startsWith "avd-co-02") or (device.displayName -startsWith "avd-co-03")'

# --- Connect to Graph ---
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "Group.ReadWrite.All"

# --- Check if group already exists (idempotent: safe to re-run) ---
Write-Host "Checking if group '$GroupName' already exists..." -ForegroundColor Cyan
$existingGroup = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue

if ($existingGroup) {
    Write-Host "Group '$GroupName' already exists (ID: $($existingGroup.Id)). Skipping creation." -ForegroundColor Yellow
    $group = $existingGroup
}
else {
    # --- Create the dynamic device group ---
    Write-Host "Creating dynamic device group '$GroupName'..." -ForegroundColor Cyan

    # GroupTypes "DynamicMembership" + a rule + processing "On" is what makes this
    # a rule-driven group rather than a static one you add members to manually
    $groupParams = @{
        DisplayName                   = $GroupName
        Description                   = $GroupDescription
        GroupTypes                    = @("DynamicMembership")
        SecurityEnabled               = $true
        MailEnabled                   = $false
        MailNickname                  = "AVD-CO-Session-Hosts"
        MembershipRule                = $MembershipRule
        MembershipRuleProcessingState = "On"
    }

    $group = New-MgGroup @groupParams
    Write-Host "Group created successfully. ID: $($group.Id)" -ForegroundColor Green
}

# --- Show what was created ---
Write-Host "`nGroup Details:" -ForegroundColor Cyan
Write-Host "  Name:            $($group.DisplayName)"
Write-Host "  ID:              $($group.Id)"
Write-Host "  Membership Rule: $MembershipRule"
Write-Host "  Processing:      $($group.MembershipRuleProcessingState)"

# --- Wait for dynamic membership to populate ---
# Entra doesn't evaluate the rule instantly - poll for a few minutes rather than
# assuming the group is populated the moment it's created
Write-Host "`nWaiting for dynamic membership to populate (this can take a few minutes)..." -ForegroundColor Yellow
$maxAttempts = 10
$attempt = 0

do {
    Start-Sleep -Seconds 30
    $attempt++
    $members = Get-MgGroupMember -GroupId $group.Id -All
    Write-Host "  Attempt $attempt/$maxAttempts - Members found: $($members.Count)" -ForegroundColor Gray
} while ($members.Count -eq 0 -and $attempt -lt $maxAttempts)

if ($members.Count -gt 0) {
    Write-Host "`n$($members.Count) devices found in group:" -ForegroundColor Green
    foreach ($member in $members) {
        # Resolve each member ID back to a device name for a readable list
        $device = Get-MgDevice -DeviceId $member.Id
        Write-Host "  - $($device.DisplayName)" -ForegroundColor Green
    }
}
else {
    Write-Host "`nNo devices found yet. Dynamic group may still be processing." -ForegroundColor Yellow
    Write-Host "Check Azure Portal > Entra ID > Groups > '$GroupName' > Members" -ForegroundColor Yellow
}

# --- Summary / next steps ---
Write-Host "`n--- NEXT STEPS ---" -ForegroundColor Cyan
Write-Host "1. Verify devices appear in the group in the Entra portal"
Write-Host "2. Assign the required app(s) as 'Required' to group '$GroupName'"
Write-Host "3. Monitor deployment in Intune > Apps > Monitor > App install status"
Write-Host "4. Once confirmed, mark the app's migration status as Complete"

Write-Host "`nDone." -ForegroundColor Green
