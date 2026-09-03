# Ensure script is run as Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "You must run this script as Administrator!"
    Exit
}

# --- CONFIGURATION ---
$RepoRoot = "C:\Users\brogun.NELSON.000\Desktop\automatic-driver-app-installer"
$LocalInstallerDir = Join-Path $RepoRoot "backupinstallers"
$GitHubJsonUrl = "https://raw.githubusercontent.com/tesladog/automatic-driver-app-installer/main/databace.json"
# ---------------------

# Setup Logging & Desktop Workspace Directory
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$LogDir = Join-Path $DesktopPath "HardwareScript_Logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $LogDir "DeploymentLog_$Timestamp.txt"

function Write-Log {
    param($Message, $Color = "White")
    $CleanMessage = $Message -replace '\x1b\[[0-9;]*m', ''
    $FormattedMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $CleanMessage"
    Add-Content -Path $LogFile -Value $FormattedMessage
    Write-Host $Message -ForegroundColor $Color
}

Clear-Host
Write-Log "==========================================" "Cyan"
Write-Log "     HARDWARE-TARGETED APP DEPLOYER       " "Cyan"
Write-Log "==========================================" "Cyan"
Write-Log "Scanning system hardware and software status..." "Yellow"

# 1. Query system components via CIM
$Manufacturer     = (Get-CimInstance Win32_ComputerSystem).Manufacturer
$Model            = (Get-CimInstance Win32_ComputerSystem).Model
$VideoControllers = (Get-CimInstance Win32_VideoController).Name -join " "
$Processor        = (Get-CimInstance Win32_Processor).Name

# Display Hardware Audit Results to User and Log
Write-Log "`n[Hardware Audit Results]" "Magenta"
Write-Log "  System Manufacturer : $Manufacturer" "Gray"
Write-Log "  System Model        : $Model" "Gray"
Write-Log "  Processor (CPU)     : $Processor" "Gray"
Write-Log "  Graphics (GPU)      : $VideoControllers" "Gray"
Write-Log "------------------------------------------" "Cyan"

# 2. Automatically Download Database from GitHub Raw URL
Write-Log "Fetching latest database from GitHub repository..." "Cyan"
try {
    $ToolDatabase = Invoke-RestMethod -Uri $GitHubJsonUrl -UseBasicParsing -ErrorAction Stop
    Write-Log "Successfully loaded database from GitHub." "Green"
} catch {
    Write-Log "Failed to download database from GitHub: $_" "Red"
    # Fallback to local file if offline
    $LocalJsonPath = Join-Path $RepoRoot "databace.json"
    if (Test-Path $LocalJsonPath) {
        Write-Log "Loading local fallback database..." "Yellow"
        $ToolDatabase = Get-Content -Path $LocalJsonPath -Raw | ConvertFrom-Json
    } else {
        Write-Log "Local fallback database not found either." "Red"
        $ToolDatabase = @()
    }
}

# Pull installed software from Registry for match checking
$InstalledRegistryApps = Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                          "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                         Select-Object DisplayName

$MasterApps = [System.Collections.Generic.List[PSCustomObject]]::new()

function Test-AppInstalled ($App) {
    $IsInstalled = $false
    $WingetCheck = winget list --id $App.Id --exact --accept-source-agreements 2>$null
    if ($WingetCheck -match [regex]::Escape($App.Id)) { $IsInstalled = $true }
    
    if (-not $IsInstalled -and $App.MatchKeys) {
        foreach ($Key in $App.MatchKeys) {
            if ($InstalledRegistryApps.DisplayName -match [regex]::Escape($Key)) { $IsInstalled = $true; break }
        }
    }
    if (-not $IsInstalled -and $App.MatchPaths) {
        foreach ($Path in $App.MatchPaths) {
            if (Test-Path $Path) { $IsInstalled = $true; break }
        }
    }
    return $IsInstalled
}

# Filter database dynamically based on hardware audit results
foreach ($Tool in $ToolDatabase) {
    $MatchFound = $false
    
    if ($Tool.Manufacturer -and $Manufacturer -match $Tool.Manufacturer) { $MatchFound = $true }
    if ($Tool.ProcessorMatch -and $Processor -match $Tool.ProcessorMatch) { $MatchFound = $true }
    if ($Tool.VideoMatch -and $VideoControllers -match $Tool.VideoMatch) { $MatchFound = $true }
    
    if ($MatchFound) {
        $MasterApps.Add($Tool)
    }
}

# --- MASTER INVENTORY EVALUATION SCREEN ---
Clear-Host
Write-Log "==========================================" "Cyan"
Write-Log "     HARDWARE-TARGETED APP DEPLOYER       " "Cyan"
Write-Log "==========================================" "Cyan"
Write-Log "Scanning system hardware and software status..." "Yellow"

$EvaluatedApps = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($App in $MasterApps) {
    $IsInstalled = Test-AppInstalled $App
    $EvaluatedApps.Add([PSCustomObject]@{ Name = $App.Name; Id = $App.Id; LocalFile = $App.LocalFile; DownloadUrl = $App.DownloadUrl; IsInstalled = $IsInstalled })
}

Write-Log "`nHardware-Matched Tool Inventory Status:" "Magenta"
for ($i = 0; $i -lt $EvaluatedApps.Count; $i++) {
    $Num = $i + 1
    $StatusString = if ($EvaluatedApps[$i].IsInstalled) { "[ALREADY INSTALLED]" } else { "[NOT INSTALLED]" }
    $StatusColor  = if ($EvaluatedApps[$i].IsInstalled) { "DarkGray" } else { "Green" }
    
    Write-Host "  [$Num] $($EvaluatedApps[$i].Name) " -NoNewline
    Write-Host "$StatusString" -ForegroundColor $StatusColor
    Add-Content -Path $LogFile -Value "  [$Num] $($EvaluatedApps[$i].Name) $StatusString"
}

Write-Log ""
Write-Log "------------------------------------------" "Cyan"
Write-Log "Press [ENTER] to install ALL missing apps listed above," "Yellow"
Write-Log "OR input item numbers to exclude (e.g., 2), OR type '-f' to force-reinstall apps." "Yellow"
$UserInput = Read-Host "Your choice"

$AppsToInstall = [System.Collections.Generic.List[PSCustomObject]]::new()

# Handle Force-Install Menu Flag (-f)
if ($UserInput.Trim() -eq "-f") {
    Write-Host "`n[!] FORCE-INSTALL MODE ACTIVATED" -ForegroundColor Yellow
    Write-Host "Select which apps you want to force-reinstall (type numbers separated by commas, or press [ENTER] for ALL):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $EvaluatedApps.Count; $i++) {
        $Num = $i + 1
        Write-Host "  [$Num] $($EvaluatedApps[$i].Name)" -ForegroundColor Green
    }
    $ForceInput = Read-Host "Apps to force install"
    
    if ([string]::IsNullOrWhiteSpace($ForceInput)) {
        foreach ($App in $EvaluatedApps) { $AppsToInstall.Add($App) }
    } else {
        $ForceNums = $ForceInput -split ',' | ForEach-Object { $_.Trim() -as [int] }
        for ($i = 0; $i -lt $EvaluatedApps.Count; $i++) {
            if ($ForceNums -contains ($i + 1)) { $AppsToInstall.Add($EvaluatedApps[$i]) }
        }
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($UserInput)) {
        foreach ($App in $EvaluatedApps) {
            if (-not $App.IsInstalled) { $AppsToInstall.Add($App) } else { Write-Log "Skipping: $($App.Name) (Already installed)" "DarkGray" }
        }
    } else {
        $ExcludedNumbers = $UserInput -split ',' | ForEach-Object { $_.Trim() -as [int] }
        for ($i = 0; $i -lt $EvaluatedApps.Count; $i++) {
            $CurrentNum = $i + 1
            if ($ExcludedNumbers -notcontains $CurrentNum) {
                if (-not $EvaluatedApps[$i].IsInstalled) { $AppsToInstall.Add($EvaluatedApps[$i]) } else { Write-Log "Skipping: $($EvaluatedApps[$i].Name) (Already installed)" "DarkGray" }
            } else {
                Write-Log "Skipping: $($EvaluatedApps[$i].Name) (Excluded by user)" "DarkYellow"
            }
        }
    }
}

# Run Installations with Winget, Local Backup Fallback, Web Download Fallback, and Interactive Prompt
if ($AppsToInstall.Count -gt 0) {
    Write-Log "`nProceeding with application installation..." "Cyan"
    foreach ($App in $AppsToInstall) {
        Write-Log "`n------------------------------------------" "DarkCyan"
        Write-Log "Installing/Reinstalling: $($App.Name)..." "Yellow"
        
        $InstallSuccess = $false
        try {
            winget install --id $App.Id --silent --accept-package-agreements --accept-source-agreements --exact
            if ($LASTEXITCODE -eq 0) { 
                Write-Log "Successfully installed $($App.Name) via Winget." "Green"
                $InstallSuccess = $true
            }
        }
        catch {
            Write-Log "Winget execution error for $($App.Name): $_" "DarkYellow"
        }

        # Step 1: If Winget fails, check local backup folder
        if (-not $InstallSuccess) {
            $LocalExePath = if ($App.LocalFile) { Join-Path $LocalInstallerDir $App.LocalFile } else { $null }
            if ($LocalExePath -and (Test-Path $LocalExePath)) {
                Write-Log "Winget failed. Found local backup installer: $LocalExePath" "Yellow"
                Write-Log "Launching local installer..." "Cyan"
                Start-Process -FilePath $LocalExePath -Wait
                Write-Log "Finished local installation routine for $($App.Name)." "Green"
                $InstallSuccess = $true
            }
        }

        # Step 2: If local backup doesn't exist, check for DownloadUrl to pull to %TEMP%
        if (-not $InstallSuccess) {
            if ($App.DownloadUrl) {
                $TempInstallerPath = Join-Path $env:TEMP $App.LocalFile
                Write-Log "Winget and local backup failed. Downloading from web URL to temp: $TempInstallerPath" "Yellow"
                try {
                    Invoke-WebRequest -Uri $App.DownloadUrl -OutFile $TempInstallerPath -ErrorAction Stop
                    Write-Log "Download complete. Launching temporary installer..." "Cyan"
                    Start-Process -FilePath $TempInstallerPath -Wait
                    Write-Log "Finished temporary download installation for $($App.Name)." "Green"
                    
                    # Cleanup temp file
                    if (Test-Path $TempInstallerPath) {
                        Remove-Item $TempInstallerPath -Force -ErrorAction SilentlyContinue
                    }
                    $InstallSuccess = $true
                } catch {
                    Write-Log "Failed to download installer from web URL: $_" "Red"
                }
            }
        }

        # Step 3: If everything failed, prompt for GitHub issue creation and manual drag-and-drop
        if (-not $InstallSuccess) {
            Write-Log "All automated paths failed for $($App.Name)." "Red"
            
            $IssuePrompt = Read-Host "`n[!] Missing installer file for '$($App.Name)'. Would you like to create a GitHub Issue for this missing installer? (y/n)"
            if ($IssuePrompt -match "^y") {
                $IssueTitle = "Missing Installer Payload: $($App.Name)"
                $IssueBody = "Automated deployment script failed via Winget, local backup (`$($App.LocalFile)`), and direct URL download for system model: $Model ($Manufacturer)."
                
                # === CONFIGURE YOUR GITHUB DETAILS HERE ===
                $GitHubUser  = "Brogun"
                $RepoName    = "automatic-driver-app-installer"
                $GitHubToken = "YOUR_PERSONAL_ACCESS_TOKEN_HERE"
                # ==========================================

                if ([string]::IsNullOrWhiteSpace($GitHubToken) -or $GitHubToken -eq "YOUR_PERSONAL_ACCESS_TOKEN_HERE") {
                    Write-Log "GitHub Token not configured. Skipping automatic web issue creation." "DarkYellow"
                } else {
                    try {
                        Write-Log "Sending issue report directly to GitHub repository..." "Cyan"
                        $Uri = "https://api.github.com/repos/$GitHubUser/$RepoName/issues"
                        $Headers = @{
                            "Authorization" = "Bearer $GitHubToken"
                            "Accept"        = "application/vnd.github+json"
                            "User-Agent"    = "PowerShell-HardwareScript"
                        }
                        $Body = @{
                            "title" = $IssueTitle
                            "body"  = $IssueBody
                        } | ConvertTo-Json

                        $Response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $Body -ContentType "application/json"
                        Write-Log "Successfully created a GitHub Issue! Issue URL: $($Response.html_url)" "Green"
                    } catch {
                        Write-Log "Failed to create GitHub Issue via API: $_" "Red"
                    }
                }
            }
            
            # Manual fallback drag-and-drop prompt
            Write-Host "`n==================================================" -ForegroundColor Yellow
            Write-Host " MANUAL ACTION REQUIRED FOR: $($App.Name)" -ForegroundColor Red
            Write-Host " Please drag and drop your installer file into this window" -ForegroundColor Cyan
            Write-Host " OR install it manually right now, then press [ENTER] to continue..." -ForegroundColor Cyan
            Write-Host "==================================================" -ForegroundColor Yellow
            
            $ManualInput = Read-Host "Drag file here or press [ENTER] when finished"
            $CleanPath = $ManualInput.Trim("'", '"')
            
            if (-not [string]::IsNullOrWhiteSpace($CleanPath) -and (Test-Path $CleanPath)) {
                Write-Log "Launching dragged installer: $CleanPath" "Cyan"
                Start-Process -FilePath $CleanPath -Wait
                Write-Log "Finished manual/dragged installation for $($App.Name)." "Green"
            } else {
                Write-Log "Skipped or invalid file path provided. Moving forward..." "DarkYellow"
            }
        }
    }
} else {
    Write-Log "`nNo new vendor apps queued for installation." "Green"
}

# --- BULLETPROOF DEVICE MANAGER CHECK (Ignores PS/2 Ghosts & Phantoms) ---
Write-Log "`n------------------------------------------" "Cyan"
Write-Log "Checking Device Manager for active hardware with true error codes..." "Yellow"

$TrueProblemDevices = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { 
    $_.Present -eq $true -and 
    $_.ConfigManagerErrorCode -and 
    $_.ConfigManagerErrorCode -ne 0 -and 
    $_.ConfigManagerErrorCode -ne "CM_PROB_PHANTOM" -and
    $_.ConfigManagerErrorCode -ne "CM_PROB_DEVICE_NOT_THERE" -and
    $_.Status -ne "Degraded"
}

$FilteredDevices = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($TrueProblemDevices) {
    foreach ($Dev in $TrueProblemDevices) {
        $Class = $Dev.Class
        $Name = $Dev.FriendlyName
        
        if ($Class -in @("WPD", "Volume", "VolumeSnapshot", "SoftwareDevice", "Monitor", "CDROM", "Image", "SoftwareComponent") -or 
            $Name -match "Ventoy|VTOYEFI|VirtualBox|Seagate|PNY|SanDisk|Kingchuxing|SABRENT|WD Elements|XTU") {
            continue
        }
        $FilteredDevices.Add($Dev)
    }
}

if ($FilteredDevices.Count -gt 0) {
    Write-Log "`n[!] Active hardware found with actual driver faults:" "Red"
    foreach ($Dev in $FilteredDevices) {
        Write-Log "  - $($Dev.FriendlyName) [Class: $($Dev.Class)] (Error Code: $($Dev.ConfigManagerErrorCode))" "Yellow"
    }
    
    $SnappyPrompt = Read-Host "`nDo you want Snappy Driver Installer Origin to find and fix these missing drivers? (y/n)"
    if ($SnappyPrompt -match "^y") {
        Write-Log "Queuing Snappy Driver Installer Origin download and deployment..." "Cyan"
        $SDIOApp = [PSCustomObject]@{ Name = "Snappy Driver Installer Origin"; Id = "BadPointer.SnappyDriverInstallerOrigin" }
        
        try {
            winget install --id $SDIOApp.Id --silent --accept-package-agreements --accept-source-agreements --exact
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Successfully installed Snappy Driver Installer Origin." "Green"
            } else {
                Write-Log "Failed to deploy Snappy Driver Installer automatically." "DarkYellow"
            }
        } catch {
            Write-Log "Error installing Snappy Driver: $_" "Red"
        }
    } else {
        Write-Log "Skipped Snappy Driver Installer deployment." "DarkYellow"
    }
} else {
    Write-Log "`n[OK] Device Manager is completely clean! No active devices have missing or broken drivers." "Green"
}

Write-Log "`nDeployment and diagnostic process complete. Log saved to: $LogFile" "Cyan"
