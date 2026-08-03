# Docker Desktop WSL2 VHDX Shrink Guide

## Comprehensive Technical Reference for AI Engineers

This guide provides an in-depth explanation of why Docker Desktop WSL2 virtual disks grow without bound, why standard cleanup commands fail to reclaim space, and how to reliably shrink the VHDX file using proven techniques.

---

## Table of Contents

1. [Understanding the Problem](#understanding-the-problem)
2. [WSL2 Storage Architecture](#wsl2-storage-architecture)
3. [Why Standard Cleanup Fails](#why-standard-cleanup-fails)
4. [Root Cause Analysis](#root-cause-analysis)
5. [Solution Overview](#solution-overview)
6. [Step-by-Step Manual Process](#step-by-step-manual-process)
7. [Automated Script Usage](#automated-script-usage)
8. [Sparse Mode Deep Dive](#sparse-mode-deep-dive)
9. [Prevention Strategies](#prevention-strategies)
10. [Troubleshooting Guide](#troubleshooting-guide)
11. [FAQ](#faq)
12. [References](#references)

---

## Understanding the Problem

### The Symptom

You notice your disk space steadily decreasing despite not downloading large files. Investigation reveals a massive file:

```
C:\Users\<Username>\AppData\Local\Docker\wsl\disk\docker_data.vhdx
```

This file may be 50GB, 100GB, or even 200GB+ in size.

### The Paradox

You run cleanup commands:

```powershell
docker system prune -a --volumes
docker builder prune --all
```

Docker reports gigabytes freed. But the VHDX file size remains unchanged.

### The Reality

WSL2 virtual disks are designed to **auto-expand** as needed but **never auto-shrink**. This is a fundamental architectural decision in WSL2, not a bug.

---

## WSL2 Storage Architecture

### How Docker Desktop Uses WSL2

Docker Desktop on Windows can use two backends:

1. **Hyper-V** (legacy)
2. **WSL2** (recommended, default since Docker Desktop 3.x)

When using WSL2 backend, Docker creates one or more Linux distributions:

| Distribution | Purpose |
|--------------|---------|
| `docker-desktop` | Core Docker engine and runtime |
| `docker-desktop-data` | Container data, images, volumes (on some versions) |

### VHDX File Location

The WSL2 distributions store their filesystems in VHDX (Virtual Hard Disk) files:

```
%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx
```

Or in older versions:

```
%LOCALAPPDATA%\Docker\wsl\data\ext4.vhdx
```

### Storage Behavior

```
┌─────────────────────────────────────────────────────────────┐
│                    VHDX File Behavior                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Initial Size:     1 GB                                    │
│                     ▼                                       │
│   After builds:     50 GB  (expanded automatically)         │
│                     ▼                                       │
│   After prune:      50 GB  (NO automatic shrink!)           │
│                     ▼                                       │
│   After more work:  100 GB (continues expanding)            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Why Standard Cleanup Fails

### What `docker system prune` Actually Does

When you run:

```bash
docker system prune -a --volumes
```

Docker removes:

- Stopped containers
- Unused networks
- Dangling images
- All unused images
- All volumes not used by containers
- Build cache

These files are deleted **inside the Linux filesystem** (ext4 inside the VHDX).

### What Happens at the VHDX Level

The VHDX file is a **dynamically expanding virtual disk**. It works like this:

1. **Expansion**: When Linux needs more space, VHDX grows automatically
2. **Deletion**: When files are deleted in Linux, blocks are marked as free inside ext4
3. **No Shrink**: VHDX does NOT release blocks back to Windows NTFS

This means:

- Linux sees: 10GB used, 40GB free
- Windows sees: 50GB VHDX file (no change)

### The Sparse Mode Exception

Recent versions of WSL2 support **sparse VHDX files**. When enabled:

- Deleted blocks CAN be released back to Windows
- Requires explicit enablement
- Not always reliable on all Windows builds

---

## Root Cause Analysis

### Common Causes of Extreme Growth

| Cause | Description | Impact |
| ------- | ------------- | -------- |
| **Large base images** | Using `ubuntu:latest` instead of `alpine` | +500MB per image |
| **Build cache** | BuildKit caches all intermediate layers | Can exceed 50GB |
| **Model files** | AI/ML checkpoints stored in containers | 2-20GB per model |
| **Volumes** | Accumulated logs, data, experiments | Unbounded |
| **Dangling images** | Failed builds leave orphan layers | Accumulates silently |
| **Multi-stage leaks** | Not cleaning intermediate stages | Doubles image size |

### AI/ML Specific Issues

Machine learning workflows are particularly prone to VHDX bloat:

```dockerfile
# This Dockerfile creates massive images

FROM nvidia/cuda:12.0-base
# CUDA base: ~3GB

RUN pip install torch torchvision torchaudio
# PyTorch with CUDA: ~6GB

COPY models/ /app/models/
# LLM weights: ~10-70GB

COPY dataset/ /app/dataset/
# Training data: ~50GB+
```

Each rebuild creates new layers. Even with cleanup, the VHDX retains all the space.

---

## Solution Overview

### The Only Guaranteed Solution

The only 100% reliable way to shrink a WSL2 VHDX is to **rebuild the distro**:

```
Export → Unregister → Delete → Import (optional) → Restart
```

This creates a fresh VHDX containing only the actual data.

### Solution Comparison

| Method | Reliability | Data Preservation | Complexity |
| -------- | ------------- | ------------------- | ------------ |
| `docker prune` | Does not shrink VHDX | Yes | Low |
| Sparse mode | Partial shrink | Yes | Medium |
| DiskPart compact | Requires Hyper-V | Yes | High |
| Optimize-VHD | Requires Hyper-V | Yes | Medium |
| **Export/Import** | **100% reliable** | **Yes** | **Medium** |
| Unregister only | 100% reliable | No | Low |

---

## Step-by-Step Manual Process

### Prerequisites

- Administrator PowerShell
- Docker Desktop closed (or will be stopped by the script)
- Sufficient temp space for export (full reset only)
- **Free space checks (automatic):**
  - VHDX host drive (usually C:): ≥ 5 GB free for compaction
  - Work/temp drive: ≥ 2 GB free (safe mode); largest VHDX + 5 GB for export/full reset
  - When C: is below 10 GB free, temp/export files are placed on another drive (for example `E:\docker-wsl-work`)

### Step 1: Check Current State

```powershell
# List WSL distros
wsl --list --verbose

# Check VHDX size
Get-ChildItem "$env:LOCALAPPDATA\Docker\wsl\disk" | 
    Select-Object Name, @{N='SizeGB';E={[math]::Round($_.Length/1GB,2)}}
```

### Step 2: Shutdown WSL

```powershell
wsl --shutdown

# Verify all stopped
wsl --list --verbose
```

### Step 3: Export the Distro

```powershell
# Export with progress indication
wsl --export docker-desktop "$env:TEMP\docker.tar"

# Check export size
Get-Item "$env:TEMP\docker.tar" | 
    Select-Object @{N='SizeGB';E={[math]::Round($_.Length/1GB,2)}}
```

### Step 4: Unregister the Distro

```powershell
# This removes the bloated VHDX
wsl --unregister docker-desktop

# Verify removal
wsl --list --verbose
```

### Step 5: Delete Orphan VHDX

```powershell
# Check if VHDX still exists
$vhdxPath = "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
if (Test-Path $vhdxPath) {
    Remove-Item $vhdxPath -Force
    Write-Host "Deleted orphan VHDX"
}
```

### Step 6: Restart Docker Desktop

```powershell
# Start Docker Desktop
Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"

# Wait for distro to be recreated
Start-Sleep -Seconds 60
wsl --list --verbose
```

### Step 7: Verify Shrink

```powershell
# Check new VHDX size
Get-ChildItem "$env:LOCALAPPDATA\Docker\wsl\disk" | 
    Select-Object Name, @{N='SizeGB';E={[math]::Round($_.Length/1GB,2)}}
```

---

## Automated Script Usage

### Basic Usage

```powershell
# Run from repository root
.\scripts\shrink-docker-wsl.ps1
```

### Advanced Options

```powershell
# Low C: drive — auto-picks another drive for temp/export (or force E:)
.\scripts\shrink-docker-wsl.ps1 -PruneDocker -WorkFolder E:\docker-wsl-work

# Custom minimum free space thresholds (GB)
.\scripts\shrink-docker-wsl.ps1 -PruneDocker -MinHostFreeGB 8 -MinWorkFreeGB 4
# Skip export (fresh start, lose all Docker data)
.\scripts\shrink-docker-wsl.ps1 -SkipExport -Force

# Keep export as backup
.\scripts\shrink-docker-wsl.ps1 -KeepExport -ExportPath "D:\Backups\docker.tar"

# Custom distro name
.\scripts\shrink-docker-wsl.ps1 -DockerDistroName "docker-desktop-data"
```

### Script Workflow

```
┌─────────────────────────────────────────────────────────────┐
│                    Script Execution Flow                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────┐                                          │
│  │ Prerequisites │ Check admin, WSL, Docker                 │
│  └──────┬───────┘                                          │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │   Shutdown   │ wsl --shutdown                           │
│  └──────┬───────┘                                          │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │    Export    │ wsl --export docker-desktop docker.tar   │
│  └──────┬───────┘                                          │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │  Unregister  │ wsl --unregister docker-desktop          │
│  └──────┬───────┘                                          │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │ Delete VHDX  │ Remove-Item docker_data.vhdx             │
│  └──────┬───────┘                                          │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │   Restart    │ Start Docker Desktop                     │
│  └──────┬───────┘                                          │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │ Enable Sparse│ wsl --manage --set-sparse true           │
│  └──────┬───────┘                                          │
│         ▼                                                   │
│  ┌──────────────┐                                          │
│  │  TRIM Drive  │ defrag C: /L                             │
│  └──────────────┘                                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Sparse Mode Deep Dive

### What is Sparse Mode?

Sparse files are a Windows NTFS feature where empty blocks don't consume physical disk space. When enabled for WSL2:

1. Deleted blocks inside Linux are marked as sparse
2. Windows can reclaim these blocks
3. VHDX file size can decrease over time

### Enabling Sparse Mode

```powershell
# Shutdown WSL first
wsl --shutdown

# Enable sparse mode
wsl --manage docker-desktop --set-sparse true

# On some Insider builds, you need --allow-unsafe
wsl --manage docker-desktop --set-sparse true --allow-unsafe
```

### Verifying Sparse Status

```powershell
# Check if file is sparse
fsutil sparse queryflag "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"

# Expected output for sparse:
# This file is set as sparse
```

### Triggering Space Reclamation

After enabling sparse mode, run:

```powershell
# SSD TRIM operation
defrag C: /L

# Or for specific drive
defrag D: /L
```

### Sparse Mode Limitations

| Issue | Description |
| ------- | ------------- |
| **Windows build dependency** | Some Insider builds disable sparse due to corruption risk |
| **Not retroactive** | Enabling sparse doesn't immediately shrink existing data |
| **Fragmentation** | Heavy use can lead to filesystem fragmentation |
| **Incomplete reclaim** | May not reclaim all theoretically available space |

---

## Prevention Strategies

### 1. Use Multi-Stage Builds

```dockerfile
# BAD: Single stage with everything
FROM python:3.11
RUN pip install torch transformers datasets
COPY . /app

# GOOD: Multi-stage, minimal final image
FROM python:3.11 AS builder
RUN pip install torch transformers datasets

FROM python:3.11-slim AS runtime
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY app/ /app/
```

### 2. Aggressive .dockerignore

```dockerignore
# AI/ML artifacts
*.pt
*.pth
*.ckpt
*.safetensors
*.bin
*.h5
checkpoints/
models/
pretrained/

# Data
datasets/
data/
*.csv
*.parquet
*.json

# Development
.git/
.venv/
__pycache__/
*.pyc
.pytest_cache/
.mypy_cache/
node_modules/
```

### 3. BuildKit Cache Mounts

```dockerfile
# syntax=docker/dockerfile:1.4

FROM python:3.11-slim

# Use cache mount for pip
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install torch transformers accelerate

# Use cache mount for apt
RUN --mount=type=cache,target=/var/cache/apt \
    apt-get update && apt-get install -y libgl1
```

### 4. Regular Maintenance Schedule

```powershell
# Weekly maintenance script
# Run as scheduled task

# Step 1: Prune Docker
docker system prune -a --volumes -f
docker builder prune --all -f

# Step 2: Check disk usage
$usage = docker system df --format "{{.TotalCount}}: {{.Size}}"
Write-Host "Docker usage: $usage"

# Step 3: If VHDX > threshold, alert
$vhdxSize = (Get-Item "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx").Length / 1GB
if ($vhdxSize -gt 40) {
    Write-Warning "VHDX size ($([math]::Round($vhdxSize,2)) GB) exceeds threshold. Consider running shrink script."
}
```

### 5. Volume Strategy

```yaml
# docker-compose.yml
# Use bind mounts for large data instead of Docker volumes

services:
  ml-training:
    image: my-ml-image
    volumes:
      # Mount large data from outside Docker
      - D:/ml-data/datasets:/data:ro
      - D:/ml-data/checkpoints:/checkpoints
      
      # Use tmpfs for cache that doesn't need persistence
      - type: tmpfs
        target: /tmp
        tmpfs:
          size: 2G
```

### 6. WSL Configuration

Create `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
# Limit memory to prevent runaway processes
memory=12GB

# Limit CPU
processors=6

# Limit swap
swap=4GB

# Enable localhost forwarding
localhostForwarding=true

# Enable sparse VHD for new distros
sparseVhd=true
```

---

## Troubleshooting Guide

### Problem: "Distro not found"

**Symptom:**

```
wsl --export docker-desktop docker.tar
There is no distribution with the supplied name.
```

**Solution:**

```powershell
# List actual distro names
wsl --list --all --verbose

# Common alternatives
# - docker-desktop-data
# - docker-desktop
# - Docker-WSL
```

### Problem: Export hangs or fails

**Symptom:** Export command never completes or crashes.

**Solutions:**

1. Ensure Docker Desktop is fully closed
2. Check available temp space
3. Try export to a different drive
4. Kill any Docker processes:

```powershell
Get-Process | Where-Object { $_.Name -like "*docker*" } | Stop-Process -Force
wsl --shutdown
```

### Problem: Sparse mode fails

**Symptom:**

```
Sparse VHD support is currently disabled due to potential data corruption.
```

**Solution:**

```powershell
# Use the allow-unsafe flag
wsl --manage docker-desktop --set-sparse true --allow-unsafe
```

### Problem: VHDX file locked

**Symptom:** Cannot delete VHDX file, "file in use" error.

**Solutions:**

```powershell
# 1. Shutdown WSL completely
wsl --shutdown
Start-Sleep -Seconds 5

# 2. Stop Docker service
Stop-Service -Name "com.docker.service" -Force

# 3. Check for holding processes
handle64.exe docker_data.vhdx

# 4. If still locked, restart Windows
```

### Problem: Docker won't start after shrink

**Symptom:** Docker Desktop shows errors after running shrink script.

**Solutions:**

```powershell
# Option 1: Reset Docker WSL data
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Docker\wsl" -ErrorAction SilentlyContinue
# Then restart Docker Desktop

# Option 2: Full Docker reset
# Docker Desktop > Settings > Reset to factory defaults

# Option 3: Reinstall Docker Desktop
```

---

## FAQ

### Q: Will I lose my containers and images?

**A:** If you use the export/import method, your Docker environment is preserved. If you skip export or unregister without exporting, you will lose all Docker data.

### Q: How often should I shrink?

**A:** Depends on your usage:

- Heavy AI development: Monthly or when > 50GB
- Standard development: Every 2-3 months
- Light usage: When disk space becomes an issue

### Q: Can I move the VHDX to another drive?

**A:** Yes, Docker Desktop Settings > Resources > Advanced > Disk Image Location. However, moving a large VHDX often fails. Shrink first, then move.

### Q: C: drive is almost full — can shrink use E: or D:?

**A:** Partially:

- **Temp scripts and export files** — yes. The shrink script auto-selects a drive with enough free space (for example `E:\docker-wsl-work`) when C: is low. Use `-WorkFolder E:\docker-wsl-work` to force it.
- **VHDX compaction** — must have free space on the **same drive** as `docker_data.vhdx` (usually C:). If that check fails, free space on C: and re-run.

If every drive is below the required threshold, the script exits with how much space to free before retrying.

### Q: Does this affect my WSL2 Ubuntu distro?

**A:** No. This only affects the `docker-desktop` distro. Your Ubuntu and other distros are separate.

### Q: Is sparse mode safe?

**A:** Microsoft disabled it by default on some builds due to potential corruption. Using `--allow-unsafe` has been stable for most users, but maintain backups of important data.

### Q: Why not just use Hyper-V backend?

**A:** WSL2 backend offers:

- Better performance for Linux containers
- Smaller memory footprint
- Faster startup times
- Better file system performance

The VHDX growth issue is the main downside.

---

## References

### Microsoft Documentation

- [WSL Configuration](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
- [WSL Disk Management](https://learn.microsoft.com/en-us/windows/wsl/disk-space)
- [VHDX Format](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/manage-virtual-hard-disks)

### Docker Documentation

- [Docker Desktop WSL2 Backend](https://docs.docker.com/desktop/wsl/)
- [Docker System Prune](https://docs.docker.com/engine/reference/commandline/system_prune/)
- [BuildKit Cache Management](https://docs.docker.com/build/cache/)

### Related Tools

- [wsl-vhdx-shrink (community script)](https://github.com/mikemaccana/compact-wsl2-disk)
- [Docker Desktop Alternatives: Rancher Desktop, Podman Desktop]

---

## Changelog

### v1.0.0 (2024)

- Initial release
- Complete shrink script with export/import workflow
- Sparse mode enablement
- Comprehensive documentation

---

<div align="center">

**Maintained by AI infrastructure engineers who understand the pain of disk bloat.**

</div>
