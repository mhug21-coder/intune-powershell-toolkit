<#
.SYNOPSIS
    Bulk update the Intune primary user on managed devices from a CSV.

.DESCRIPTION
    Reads a CSV of devices and reassigns the Intune primary user on each one via
    Microsoft Graph. Skips any row where the new user already matches the current
    user, logs every action (success and failure) to a timestamped text log, and
    continues past individual errors so one bad row doesn't stop the batch.

    Uses the current supported method for setting a primary user:
    POST deviceManagement/managedDevices('<id>')/users/$ref with an @odata.id
    reference to the target user. (The older PATCH/userId approach no longer works.)

.PARAMETER FilePath
    Set inline below. Path to the input CSV.

    The CSV must contain these columns:
      id                 - the Intune managedDevice ID
      DeviceName         - device name (used for logging/readability only)
      userPrincipalName  - the CURRENT primary user (UPN) - used to skip no-op rows
      NewUserName        - the NEW primary user's UPN - used to skip no-op rows
      NewUserID          - the NEW user's Entra object ID (this is what's actually assigned)

.EXAMPLE
    # Populate the CSV, set the paths in the User Input Section, then run:
    .\Set-IntunePrimaryUser-BulkFromCSV.ps1

.NOTES
    Version:       3.0
    Author:        Matt Hughes
    Creation Date: 28 Nov 2025
    Modified Date: 01 Dec 2025
    Change:        Updated to use POST /users/$ref method (current working API)

    Connects with delegated scopes (interactive sign-in). The signed-in account
    needs rights to manage devices and read users.
    Requires: Microsoft.Graph module (auto-installed if missing).
#>

cls
Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop'
$error.clear()   # clear error history so $error only reflects this run

# ==============================User Input Section Start==============================
$Path     = "C:\Temp\IntuneReporting\ChangePrimaryUser"                 # working/log folder
$FilePath = "C:\Temp\IntuneReporting\ChangePrimaryUser\InputFile.csv"   # input CSV (see .PARAMETER above)
# ==============================User Input Section End================================

$Inputfile = Import-Csv -Path $FilePath
$LogPath   = Join-Path -Path $Path -ChildPath "ChangePrimaryUser.txt"

# Create the log directory if it doesn't already exist
if (-not (Test-Path -Path $Path)) {
    New-Item -Path $Path -ItemType Directory -Force
}

# Create the log file if it doesn't already exist
if (-not (Test-Path -Path $LogPath)) {
    New-Item -Path $LogPath -ItemType File
}

# Helper: write the same line to console (coloured) and to the log file (timestamped)
function Write-Log {
    param (
        [string]$Message,
        [string]$Color = "White"
    )

    $FormattedLog = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $FormattedLog -ForegroundColor $Color
    $FormattedLog | Out-File -FilePath $LogPath -Append
}

Write-Log -Message "Script started" -Color "White"

# =======================
# Check & Install Microsoft.Graph Module
# =======================
if (-not (Get-Module -Name Microsoft.Graph -ListAvailable)) {
    Write-Host "Microsoft.Graph module not found. Installing..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
    Write-Host "Microsoft.Graph module installed successfully." -ForegroundColor Green
} else {
    Write-Host "Microsoft.Graph module is already installed." -ForegroundColor Green
}

# Only the Authentication sub-module is needed - everything else uses raw Graph requests
Write-Host "Importing Microsoft.Graph modules..." -ForegroundColor Yellow
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Write-Host "Microsoft.Graph.Authentication module imported successfully." -ForegroundColor Green

# =======================
# Connect to Microsoft Graph
# =======================
# Delegated sign-in requesting only the scopes this script needs. First run will
# prompt for consent if these scopes haven't been granted before.
try {
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All","User.Read.All","Directory.Read.All" -ErrorAction Stop
    Write-Host "Successfully connected to Microsoft Graph." -ForegroundColor Green
    Write-Log -Message "Successfully connected to Microsoft Graph" -Color "Green"
} catch {
    Write-Host "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -ForegroundColor Red
    Write-Log -Message "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Color "Red"
    return
}

# Total rows, used for the "x/y" progress counter
$totalDevices = $Inputfile.Count
Write-Log -Message "Total devices in CSV: $totalDevices" -Color "White"
Write-Host ""

$deviceCounter = 0

foreach ($In in $Inputfile) {
    $deviceCounter++

    # Skip rows where the new user is already the current user - nothing to change
    if ($In.NewUserName -eq $In.userPrincipalName) {
        $message = "Skipping update for $deviceCounter/$totalDevices devices - New and old user names are the same: $($In.NewUserName)"
        Write-Host $message -ForegroundColor Yellow
        Write-Log -Message $message -Color "Yellow"
        Write-Host "==============================================================================================================================================================="
        continue
    }

    $message = "Updating $deviceCounter/$totalDevices devices - New Primary User Name: $($In.NewUserName) / $($In.DeviceName) and Old Primary User Name $($In.userPrincipalName)..."
    Write-Host $message -ForegroundColor Yellow
    Write-Log -Message $message -Color "Yellow"

    # Current supported pattern: POST a $ref to the device's users collection.
    # Backtick escapes $ref so PowerShell leaves it in the URL rather than expanding it.
    $graphApiVersion = "v1.0"
    $Resource = "deviceManagement/managedDevices('$($In.id)')/users/`$ref"
    $uri = "https://graph.microsoft.com/$graphApiVersion/$Resource"

    # Body points at the NEW user by object ID via @odata.id
    $JSON = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/users/$($In.NewUserID)"
    } | ConvertTo-Json

    try {
        Invoke-MgGraphRequest -Method POST -Uri $uri -Body $JSON -ContentType "application/json"
        $successMessage = "Successfully updated the primary user."
        Write-Host $successMessage -ForegroundColor Green
        Write-Log -Message $successMessage -Color "Green"
        Write-Host "============================================================================================================================================================="
    } catch {
        # Log and continue - one failed device shouldn't halt the whole batch
        $errorMessage = "An error occurred: $_"
        Write-Host $errorMessage -ForegroundColor Red
        Write-Log -Message $errorMessage -Color "Red"
        if ($_.ErrorDetails) {
            $errorDetails = "Error Details:`n$($_.ErrorDetails)"
            Write-Host $errorDetails -ForegroundColor Red
            Write-Log -Message $errorDetails -Color "Red"
        }
    }
}

# =======================
# Disconnect from Microsoft Graph
# =======================
Disconnect-MgGraph
Write-Host "`nDisconnected from Microsoft Graph." -ForegroundColor DarkGray
Write-Log -Message "Disconnected from Microsoft Graph" -Color "White"

Write-Log -Message "Script completed" -Color "White"
