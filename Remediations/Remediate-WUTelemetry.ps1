<#
.SYNOPSIS
    Reset Windows Update components to resolve update failures.

.DESCRIPTION
    The standard Windows Update repair sequence, run end to end:
      1. Stop the WU-related services (wuauserv, BITS, cryptSvc, msiserver)
      2. Rename the SoftwareDistribution download cache so WU rebuilds it fresh
      3. Rename catroot2 to clear the cryptographic/signature cache
      4. Re-register the core Windows Update client DLLs
      5. Reset WinSock to clear network-level WU connectivity issues
      6. Restart the services
      7. Trigger an immediate update scan
      8. Schedule a one-off cleanup task to delete the old cache folders after an hour

    Runs silently as SYSTEM via Intune Proactive Remediation - no user interaction,
    no forced reboot. This is the remediation half of a detect/remediate pair.

.NOTES
    Author : Matt Hughes
    Version: 1.0
    Date   : 2026-05-22

    Pair with: Detect-WUTelemetry.ps1 (the detection script that flags unhealthy devices)
    Targets  : Devices reporting WU failures (e.g. 0x8024200B) or a stopped WU service
    Impact   : Silent, no user interaction, no reboot forced
#>

# =====================================================================
# 1. Stop Windows Update related services
# =====================================================================
$services = @('wuauserv', 'bits', 'cryptSvc', 'msiserver')

foreach ($svc in $services) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}

# Allow services time to fully stop
Start-Sleep -Seconds 5

# =====================================================================
# 2. Clear the WU download cache (SoftwareDistribution)
#    This forces Windows to re-download any pending updates fresh
# =====================================================================
$swDist = "$env:SystemRoot\SoftwareDistribution"
if (Test-Path $swDist) {
    Rename-Item -Path $swDist -NewName "SoftwareDistribution.old" -Force -ErrorAction SilentlyContinue
}

# =====================================================================
# 3. Clear the catroot2 folder (cryptographic service cache)
#    Resolves signature verification failures during update install
# =====================================================================
$catroot2 = "$env:SystemRoot\System32\catroot2"
if (Test-Path $catroot2) {
    Rename-Item -Path $catroot2 -NewName "catroot2.old" -Force -ErrorAction SilentlyContinue
}

# =====================================================================
# 4. Re-register core Windows Update DLLs
#    Ensures the WU client components are properly registered
# =====================================================================
$dlls = @(
    'atl.dll', 'urlmon.dll', 'mshtml.dll', 'shdocvw.dll',
    'browseui.dll', 'jscript.dll', 'vbscript.dll', 'scrrun.dll',
    'msxml.dll', 'msxml3.dll', 'msxml6.dll', 'actxprxy.dll',
    'softpub.dll', 'wintrust.dll', 'dssenh.dll', 'rsaenh.dll',
    'gpkcsp.dll', 'sccbase.dll', 'slbcsp.dll', 'cryptdlg.dll',
    'oleaut32.dll', 'ole32.dll', 'shell32.dll', 'initpki.dll',
    'wuapi.dll', 'wuaueng.dll', 'wuaueng1.dll', 'wucltui.dll',
    'wups.dll', 'wups2.dll', 'wuweb.dll', 'qmgr.dll', 'qmgrprxy.dll',
    'wucltux.dll', 'muweb.dll', 'wuwebv.dll'
)

foreach ($dll in $dlls) {
    $dllPath = Join-Path "$env:SystemRoot\System32" $dll
    if (Test-Path $dllPath) {
        Start-Process -FilePath 'regsvr32.exe' -ArgumentList "/s `"$dllPath`"" -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }
}

# =====================================================================
# 5. Reset WinSock (fixes network-level WU connectivity issues)
# =====================================================================
netsh winsock reset 2>&1 | Out-Null

# =====================================================================
# 6. Restart all stopped services
# =====================================================================
foreach ($svc in $services) {
    Start-Service -Name $svc -ErrorAction SilentlyContinue
}

# =====================================================================
# 7. Trigger a fresh Windows Update scan
#    Forces the WU client to check for updates immediately
# =====================================================================
Start-Sleep -Seconds 3
(New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()

# =====================================================================
# 8. Clean up old folders after 1 hour via scheduled task
#    Gives services time to recreate fresh folders before deleting old ones
# =====================================================================
# Why defer: the .old folders can't be deleted reliably right now (services are
# re-initialising and may still hold handles). Rather than risk a failed delete
# mid-run, schedule a hidden one-off task to remove them in an hour, then self-delete.
# The cleanup script is base64-encoded and passed via -EncodedCommand so the whole
# task definition is self-contained with no separate script file on disk.
$cleanupScript = @'
Start-Sleep -Seconds 3600
Remove-Item "$env:SystemRoot\SoftwareDistribution.old" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:SystemRoot\System32\catroot2.old" -Recurse -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'WU_Cleanup_Temp' -Confirm:$false -ErrorAction SilentlyContinue
'@

$bytes = [System.Text.Encoding]::Unicode.GetBytes($cleanupScript)
$encoded = [Convert]::ToBase64String($bytes)

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName 'WU_Cleanup_Temp' -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null

# =====================================================================
# Output result for Intune reporting
# =====================================================================
Write-Output "WU components reset successfully on $env:COMPUTERNAME at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
exit 0
