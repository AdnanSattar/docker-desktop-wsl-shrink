<#
.SYNOPSIS
    Docker Desktop WSL2 VHDX Shrink Script
    Safely shrinks Docker Desktop's virtual disk from 100GB+ down to minimal size.

.DESCRIPTION
    This script performs a safe export-unregister-import cycle on the Docker Desktop
    WSL2 distro to reclaim disk space. WSL2 virtual disks auto-expand but never
    auto-shrink. This is the only reliable way to reclaim space.

    The workflow:
    1. Shutdown all WSL instances
    2. Export docker-desktop distro to a tar file (preserves data)
    3. Unregister the distro (removes the bloated VHDX)
    4. Delete orphan VHDX files
    5. Restart Docker Desktop (recreates fresh compact VHDX)
    6. Enable sparse mode for future maintenance
    7. Trigger Windows TRIM to release freed space

.PARAMETER DockerDistroName
    Name of the Docker WSL distro. Default: "docker-desktop"

.PARAMETER ExportPath
    Path for the export tar file. Default: "$env:TEMP\docker_desktop_export.tar"

.PARAMETER WslDiskFolder
    Path to Docker's WSL disk folder. Default: "$env:LOCALAPPDATA\Docker\wsl\disk"

.PARAMETER SkipExport
    Skip the export step. Use only if you don't need to preserve Docker data.

.PARAMETER Force
    Continue even if export fails. WARNING: May result in data loss.

.PARAMETER KeepExport
    Keep the export tar file after completion. Useful for backup purposes.

.EXAMPLE
    .\shrink-docker-wsl.ps1
    Run with default settings. Exports, shrinks, and restores docker-desktop.

.EXAMPLE
    .\shrink-docker-wsl.ps1 -SkipExport -Force
    Skip export and force shrink. Use when you want a completely fresh Docker environment.

.EXAMPLE
    .\shrink-docker-wsl.ps1 -KeepExport -ExportPath "D:\Backup\docker-backup.tar"
    Shrink and keep the export as a backup.

.NOTES
    Author: Adnan Sattar
    Version: 1.0.0
    Requires: PowerShell 5.1+, Windows 10/11, Docker Desktop with WSL2 backend
    Run as: Administrator
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Name of the Docker WSL distro")]
    [string]$DockerDistroName = "docker-desktop",

    [Parameter(HelpMessage = "Name of the Docker data WSL distro (images/volumes)")]
    [string]$DockerDataDistroName = "docker-desktop-data",

    [Parameter(HelpMessage = "Path for the export tar file")]
    [string]$ExportPath = "$env:TEMP\docker_desktop_export.tar",

    [Parameter(HelpMessage = "Path to Docker's WSL disk folder")]
    [string]$WslDiskFolder = "$env:LOCALAPPDATA\Docker\wsl\disk",

    [Parameter(HelpMessage = "Path to Docker's WSL data folder (contains ext4.vhdx)")]
    [string]$WslDataFolder = "$env:LOCALAPPDATA\Docker\wsl\data",

    [Parameter(HelpMessage = "Skip the export step")]
    [switch]$SkipExport,

    [Parameter(HelpMessage = "Continue even if export fails")]
    [switch]$Force,

    [Parameter(HelpMessage = "Keep the export tar file after completion")]
    [switch]$KeepExport
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Known VHDX file names used by Docker Desktop
$KnownVhdxNames = @(
    "docker_data.vhdx",
    "ext4.vhdx",
    "data.vhdx"
)

# Docker Desktop executable paths
$DockerDesktopPaths = @(
    "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
    "${env:ProgramFiles(x86)}\Docker\Docker\Docker Desktop.exe",
    "$env:LOCALAPPDATA\Docker\Docker Desktop.exe"
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=" * 70 -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor White
    Write-Host "=" * 70 -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    $color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        default { "Gray" }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $color
}

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-WslDistros {
    $output = wsl.exe --list --all --quiet 2>$null
    if ($output) {
        return $output | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    }
    return @()
}

function Get-DockerTargetDistro {
    param(
        [string[]]$Distros,
        [string]$EngineDistro,
        [string]$DataDistro
    )

    # Docker Desktop stores images/volumes in docker-desktop-data on most installs.
    # Prefer shrinking that when present; otherwise fall back to docker-desktop.
    if ($Distros -contains $DataDistro) {
        return [pscustomobject]@{
            Name = $DataDistro
            Kind = "Data"
        }
    }
    if ($Distros -contains $EngineDistro) {
        return [pscustomobject]@{
            Name = $EngineDistro
            Kind = "Engine"
        }
    }
    return $null
}

function Get-VhdxSize {
    param([string]$Path)
    if (Test-Path $Path) {
        $size = (Get-Item $Path).Length
        return [math]::Round($size / 1GB, 2)
    }
    return 0
}

function Find-DockerDesktop {
    foreach ($path in $DockerDesktopPaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    return $null
}

function Wait-ForDistro {
    param(
        [string]$DistroName,
        [int]$TimeoutSeconds = 180
    )
    
    $startTime = Get-Date
    $endTime = $startTime.AddSeconds($TimeoutSeconds)
    
    Write-Status "Waiting for '$DistroName' to appear (timeout: ${TimeoutSeconds}s)..."
    
    while ((Get-Date) -lt $endTime) {
        $distros = Get-WslDistros
        if ($distros -contains $DistroName) {
            Write-Status "'$DistroName' is now available" -Type "Success"
            return $true
        }
        Start-Sleep -Seconds 3
        Write-Host "." -NoNewline
    }
    
    Write-Host ""
    return $false
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

# Banner
Write-Host ""
Write-Host @"
    ____             __                _       _______ __       _____ __         _       __  
   / __ \____  _____/ /_____  _____   | |     / / ___// /      / ___// /_  _____(_)___  / /__
  / / / / __ \/ ___/ //_/ _ \/ ___/   | | /| / /\__ \/ /       \__ \/ __ \/ ___/ / __ \/ //_/
 / /_/ / /_/ / /__/ ,< /  __/ /       | |/ |/ /___/ / /___    ___/ / / / / /  / / / / / ,<   
/_____/\____/\___/_/|_|\___/_/        |__/|__//____/_____/   /____/_/ /_/_/  /_/_/ /_/_/|_|  
                                                                                              
                           WSL2 VHDX Shrink Toolkit v1.0.0
"@ -ForegroundColor Cyan

Write-Host ""

# ============================================================================
# STEP 0: PREREQUISITES CHECK
# ============================================================================

Write-Step "STEP 0: Checking Prerequisites"

# Check administrator privileges
if (-not (Test-Administrator)) {
    Write-Status "This script must be run as Administrator" -Type "Error"
    Write-Status "Right-click PowerShell and select 'Run as Administrator'" -Type "Info"
    exit 1
}
Write-Status "Running with Administrator privileges" -Type "Success"

# Check WSL availability
try {
    $wslVersion = wsl.exe --version 2>$null
    Write-Status "WSL is available" -Type "Success"
}
catch {
    Write-Status "WSL is not installed or not accessible" -Type "Error"
    exit 1
}

# Get current distros
$initialDistros = Get-WslDistros
Write-Status "Current WSL distros: $($initialDistros -join ', ')"

# Decide which distro to shrink (prefer data distro)
$target = Get-DockerTargetDistro -Distros $initialDistros -EngineDistro $DockerDistroName -DataDistro $DockerDataDistroName
$distroExists = $null -ne $target
if ($distroExists) {
    Write-Status "Target distro '$($target.Name)' selected ($($target.Kind))" -Type "Success"
    if ($target.Kind -eq "Engine") {
        Write-Status "Note: '$DockerDataDistroName' not found; shrinking engine distro only" -Type "Warning"
    }
}
else {
    Write-Status "No Docker WSL distros found ('$DockerDistroName' / '$DockerDataDistroName')" -Type "Warning"
    Write-Status "Will proceed to cleanup orphan VHDX files only"
}

# Check current VHDX size
$vhdxFiles = @()
foreach ($name in $KnownVhdxNames) {
    $path = Join-Path $WslDiskFolder $name
    if (Test-Path $path) {
        $size = Get-VhdxSize $path
        $vhdxFiles += [pscustomobject]@{
            Path = $path
            Size = $size
            Name = $name
        }
        Write-Status "Found: $name ($size GB)"
    }
}

if (Test-Path $WslDataFolder) {
    $dataVhdx = Join-Path $WslDataFolder "ext4.vhdx"
    if (Test-Path $dataVhdx) {
        $size = Get-VhdxSize $dataVhdx
        $vhdxFiles += [pscustomobject]@{
            Path = $dataVhdx
            Size = $size
            Name = "ext4.vhdx (data)"
        }
        Write-Status "Found: ext4.vhdx (data) ($size GB)"
    }
}

if ($vhdxFiles.Count -eq 0) {
    Write-Status "No VHDX files found in $WslDiskFolder or $WslDataFolder" -Type "Warning"
}

$totalSizeBefore = if ($vhdxFiles.Count -gt 0) {
    ($vhdxFiles | Measure-Object -Property Size -Sum).Sum
}
else {
    0
}
Write-Status "Total VHDX size before shrink: $totalSizeBefore GB" -Type "Info"

# ============================================================================
# STEP 1: SHUTDOWN WSL
# ============================================================================

Write-Step "STEP 1: Shutting Down WSL"

Write-Status "Stopping all WSL instances..."
wsl.exe --shutdown
Start-Sleep -Seconds 3
Write-Status "WSL shutdown complete" -Type "Success"

# ============================================================================
# STEP 2: EXPORT DISTRO (Optional)
# ============================================================================

Write-Step "STEP 2: Exporting Docker Desktop Distro"

$exportSucceeded = $false

if ($SkipExport) {
    Write-Status "Skipping export (SkipExport flag set)" -Type "Warning"
}
elseif (-not $distroExists) {
    Write-Status "Skipping export (distro does not exist)" -Type "Warning"
}
else {
    # Remove existing export file
    if (Test-Path $ExportPath) {
        Write-Status "Removing existing export file..."
        Remove-Item -Force $ExportPath
    }

    Write-Status "Exporting '$($target.Name)' to: $ExportPath"
    Write-Status "This may take several minutes depending on the distro size..."

    try {
        # Ensure WSL is fully stopped
        wsl.exe --shutdown
        Start-Sleep -Seconds 2

        # Perform export
        $exportOutput = wsl.exe --export $target.Name $ExportPath 2>&1
        
        if (Test-Path $ExportPath) {
            $exportSize = Get-VhdxSize $ExportPath
            Write-Status "Export completed successfully ($exportSize GB)" -Type "Success"
            $exportSucceeded = $true
        }
        else {
            throw "Export file was not created"
        }
    }
    catch {
        Write-Status "Export failed: $_" -Type "Error"
        
        if ($Force) {
            Write-Status "Force flag set - continuing despite export failure" -Type "Warning"
            Write-Status "WARNING: You may lose Docker data!" -Type "Warning"
        }
        else {
            Write-Status "Aborting to prevent data loss. Use -Force to override." -Type "Error"
            exit 1
        }
    }
}

# ============================================================================
# STEP 3: UNREGISTER DISTRO
# ============================================================================

Write-Step "STEP 3: Unregistering Docker Desktop Distro"

if ($distroExists) {
    Write-Status "Unregistering '$($target.Name)'..."
    
    try {
        wsl.exe --unregister $target.Name
        Start-Sleep -Seconds 2
        Write-Status "Distro unregistered successfully" -Type "Success"
    }
    catch {
        Write-Status "Failed to unregister distro: $_" -Type "Error"
        if (-not $Force) {
            exit 1
        }
    }
}
else {
    Write-Status "Distro already unregistered, skipping..." -Type "Info"
}

# If we shrank the data distro, import it back so images/volumes return.
if ($distroExists -and -not $SkipExport -and $exportSucceeded -and $target.Kind -eq "Data") {
    Write-Step "STEP 3b: Importing Docker Data Distro"

    try {
        if (-not (Test-Path $WslDataFolder)) {
            New-Item -ItemType Directory -Force -Path $WslDataFolder | Out-Null
        }

        Write-Status "Importing '$($target.Name)' back into: $WslDataFolder"
        wsl.exe --import $target.Name $WslDataFolder $ExportPath 2>&1 | Out-Null
        Write-Status "Import completed successfully" -Type "Success"
    }
    catch {
        Write-Status "Import failed: $_" -Type "Error"
        if (-not $Force) { exit 1 }
    }
}

# ============================================================================
# STEP 4: DELETE ORPHAN VHDX FILES
# ============================================================================

Write-Step "STEP 4: Removing Orphan VHDX Files"

$deletedSize = 0
$skipDataFolderDeletes = $false
if ($distroExists -and $target.Kind -eq "Data" -and -not $SkipExport -and $exportSucceeded) {
    # We just imported the data distro back. Deleting ext4.vhdx now would wipe images/volumes.
    $skipDataFolderDeletes = $true
    Write-Status "Skipping deletes under data folder to preserve images/volumes: $WslDataFolder" -Type "Info"
}

foreach ($vhdx in $vhdxFiles) {
    if (-not (Test-Path $vhdx.Path)) { continue }

    if ($skipDataFolderDeletes -and ($vhdx.Path -like (Join-Path $WslDataFolder "*"))) {
        Write-Status "Keeping: $($vhdx.Name) (data VHDX)" -Type "Info"
        continue
    }

    Write-Status "Deleting: $($vhdx.Name) ($($vhdx.Size) GB)"
    try {
        Remove-Item -Force $vhdx.Path
        $deletedSize += $vhdx.Size
        Write-Status "Deleted successfully" -Type "Success"
    }
    catch {
        Write-Status "Failed to delete: $_" -Type "Error"
    }
}

if ($deletedSize -gt 0) {
    Write-Status "Total space freed: $deletedSize GB" -Type "Success"
}
else {
    Write-Status "No VHDX files were deleted" -Type "Info"
}

# ============================================================================
# STEP 5: RESTART DOCKER DESKTOP
# ============================================================================

Write-Step "STEP 5: Restarting Docker Desktop"

$dockerDesktopPath = Find-DockerDesktop

if ($dockerDesktopPath) {
    Write-Status "Starting Docker Desktop from: $dockerDesktopPath"
    
    try {
        Start-Process -FilePath $dockerDesktopPath -WindowStyle Minimized
        Write-Status "Docker Desktop started" -Type "Success"
    }
    catch {
        Write-Status "Failed to start Docker Desktop: $_" -Type "Warning"
    }
}
else {
    Write-Status "Docker Desktop executable not found" -Type "Warning"
    Write-Status "Please start Docker Desktop manually"
    
    # Try starting the service instead
    try {
        $service = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
        if ($service) {
            Write-Status "Starting Docker service..."
            Start-Service -Name "com.docker.service"
        }
    }
    catch {
        Write-Status "Could not start Docker service: $_" -Type "Warning"
    }
}

# Wait for the distro(s) to be available
Write-Status "Waiting for Docker Desktop / WSL distros to be available..."
$distroRecreated = $false
if ($distroExists) {
    $distroRecreated = Wait-ForDistro -DistroName $target.Name -TimeoutSeconds 180
}
else {
    $distroRecreated = Wait-ForDistro -DistroName $DockerDistroName -TimeoutSeconds 180
}

if (-not $distroRecreated) {
    Write-Status "Distro did not appear within timeout" -Type "Warning"
    Write-Status "You may need to start Docker Desktop manually"
}

# ============================================================================
# STEP 6: ENABLE SPARSE MODE
# ============================================================================

Write-Step "STEP 6: Enabling Sparse Mode"

if ($distroRecreated) {
    Write-Status "Shutting down WSL for sparse mode conversion..."
    wsl.exe --shutdown
    Start-Sleep -Seconds 2

    $sparseTarget = if ($distroExists) { $target.Name } else { $DockerDistroName }
    Write-Status "Enabling sparse mode on '$sparseTarget'..."
    
    try {
        $sparseOutput = wsl.exe --manage $sparseTarget --set-sparse true --allow-unsafe 2>&1
        Write-Status "Sparse mode conversion requested" -Type "Success"
        Write-Status "Note: Some Windows builds may not fully support sparse mode" -Type "Info"
    }
    catch {
        Write-Status "Sparse mode conversion failed: $_" -Type "Warning"
        Write-Status "This is not critical - the shrink was still successful" -Type "Info"
    }
}
else {
    Write-Status "Skipping sparse mode (distro not available)" -Type "Warning"
}

# ============================================================================
# STEP 7: TRIGGER WINDOWS TRIM
# ============================================================================

Write-Step "STEP 7: Triggering Windows TRIM"

Write-Status "Running SSD optimization to release freed space..."

try {
    # Get the drive letter from the WslDiskFolder
    $driveLetter = (Split-Path -Qualifier $WslDiskFolder).TrimEnd(":")
    
    $defragOutput = defrag.exe "${driveLetter}:" /L 2>&1
    Write-Status "SSD TRIM completed" -Type "Success"
}
catch {
    Write-Status "TRIM operation failed or not applicable: $_" -Type "Warning"
    Write-Status "This is not critical on non-SSD drives" -Type "Info"
}

# ============================================================================
# STEP 8: CLEANUP AND SUMMARY
# ============================================================================

Write-Step "STEP 8: Cleanup and Summary"

# Cleanup export file if not keeping
if (-not $KeepExport -and (Test-Path $ExportPath)) {
    Write-Status "Removing temporary export file..."
    Remove-Item -Force $ExportPath
    Write-Status "Export file removed" -Type "Success"
}
elseif ($KeepExport -and (Test-Path $ExportPath)) {
    Write-Status "Export file kept at: $ExportPath" -Type "Info"
}

# Check new VHDX size
$newVhdxFiles = @()
foreach ($name in $KnownVhdxNames) {
    $path = Join-Path $WslDiskFolder $name
    if (Test-Path $path) {
        $size = Get-VhdxSize $path
        $newVhdxFiles += [pscustomobject]@{
            Path = $path
            Size = $size
            Name = $name
        }
    }
}

if (Test-Path $WslDataFolder) {
    $dataVhdx = Join-Path $WslDataFolder "ext4.vhdx"
    if (Test-Path $dataVhdx) {
        $size = Get-VhdxSize $dataVhdx
        $newVhdxFiles += [pscustomobject]@{
            Path = $dataVhdx
            Size = $size
            Name = "ext4.vhdx (data)"
        }
    }
}

$totalSizeAfter = if ($newVhdxFiles.Count -gt 0) {
    ($newVhdxFiles | Measure-Object -Property Size -Sum).Sum
}
else {
    0
}

# Check sparse status
$sparseStatus = "Unknown"
if ($newVhdxFiles.Count -gt 0) {
    $mainVhdx = $newVhdxFiles[0].Path
    try {
        $sparseOutput = fsutil.exe sparse queryflag $mainVhdx 2>&1
        if ($sparseOutput -match "set as sparse") {
            $sparseStatus = "Enabled"
        }
        else {
            $sparseStatus = "Disabled"
        }
    }
    catch {
        $sparseStatus = "Unknown"
    }
}

# Print summary
Write-Host ""
Write-Host "=" * 70 -ForegroundColor Green
Write-Host " SHRINK COMPLETE" -ForegroundColor White
Write-Host "=" * 70 -ForegroundColor Green
Write-Host ""
Write-Host "  Size Before:     $totalSizeBefore GB" -ForegroundColor Yellow
Write-Host "  Size After:      $totalSizeAfter GB" -ForegroundColor Green
Write-Host "  Space Saved:     $([math]::Round($totalSizeBefore - $totalSizeAfter, 2)) GB" -ForegroundColor Cyan
Write-Host "  Sparse Mode:     $sparseStatus" -ForegroundColor $(if ($sparseStatus -eq "Enabled") { "Green" } else { "Yellow" })
Write-Host ""

if ($newVhdxFiles.Count -gt 0) {
    Write-Host "  New VHDX files:" -ForegroundColor White
    foreach ($vhdx in $newVhdxFiles) {
        Write-Host "    - $($vhdx.Name): $($vhdx.Size) GB" -ForegroundColor Gray
    }
}

Write-Host ""
Write-Host "=" * 70 -ForegroundColor Green

# Final verification commands
Write-Host ""
Write-Host "Verification Commands:" -ForegroundColor Cyan
Write-Host "  wsl --list --verbose                    # Check WSL distros"
Write-Host "  docker system df                        # Check Docker disk usage"
Write-Host "  fsutil sparse queryflag <vhdx-path>     # Check sparse status"
Write-Host ""

Write-Status "Script completed successfully" -Type "Success"
