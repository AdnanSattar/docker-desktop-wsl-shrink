<div align="center">

# 🐳 Docker Desktop WSL2 VHDX Shrink Toolkit

### A battle-tested solution for controlling massive disk growth during AI development workflows

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](https://docs.microsoft.com/en-us/powershell/)
[![WSL2](https://img.shields.io/badge/WSL2-Supported-success?logo=linux&logoColor=white)](https://docs.microsoft.com/en-us/windows/wsl/)
[![Docker](https://img.shields.io/badge/Docker_Desktop-WSL_Backend-2496ED?logo=docker&logoColor=white)](https://www.docker.com/products/docker-desktop/)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?logo=windows&logoColor=white)](https://www.microsoft.com/windows)

<br />

**Shrink your Docker Desktop VHDX**

[Getting Started](#-quick-start) •
[Why This Exists](#-why-this-exists) •
[Documentation](docs/docker-wsl-vhdx-shrink-guide.md) •
[Best Practices](#-best-practices-for-ai-engineers)

</div>

---

## 📋 Table of Contents

- [Why This Exists](#-why-this-exists)
- [The Problem](#-the-problem)
- [Architecture Overview](#-architecture-overview)
- [Features](#-features)
- [Quick Start](#-quick-start)
- [Repository Structure](#-repository-structure)
- [How It Works](#-how-it-works)
- [Best Practices for AI Engineers](#-best-practices-for-ai-engineers)
- [Troubleshooting](#-troubleshooting)
- [Contributing](#-contributing)
- [License](#-license)

---

## 🎯 Why This Exists

Modern AI development workflows push Docker to the limit:

| Challenge | Impact |
|-----------|--------|
| Heavy multistage builds | Layers accumulate rapidly |
| Large language model weights | Multi-GB checkpoints stored in containers |
| BuildKit caching | Cache grows without bounds |
| Dataset volumes | Logs and preprocessed shards pile up |
| Frequent rebuilds | Each iteration adds to disk usage |

On Windows, all of this gets captured inside a growing WSL2 VHDX file.

**And it never shrinks by itself.**

This toolkit solves the problem cleanly with a one-click script.

---

## 🔴 The Problem

WSL2 stores each Linux distro inside an `ext4.vhdx` virtual disk. This VHDX is configured to **auto-expand** but **never auto-shrink**.

```
Before cleanup:  docker_data.vhdx = 150 GB  ❌
After cleanup:   docker_data.vhdx = 3 GB    ✅
```

Even running these commands does NOT reduce the physical disk footprint:

```powershell
docker system prune -a --volumes
docker builder prune --all
```

The files are deleted inside the Linux filesystem, but the Windows VHDX file remains bloated.

---

## 🏗 Architecture Overview

### Docker Desktop WSL2 Storage Architecture

<div align="center">

![Docker Desktop WSL2 Storage Architecture](assets/architecture-diagram-1.png)

</div>

Docker Desktop on Windows uses WSL2 to run the Linux-based Docker engine. All container data, images, and volumes are stored inside a dynamically expanding VHDX virtual disk file.

### The Problem: Auto-Expand, Never Shrink

<div align="center">

![The Problem - Auto Expand Never Shrink](assets/architecture-diagram-2.png)

</div>

WSL2 virtual disks automatically grow as you build images and create volumes, but they **never shrink automatically** when you delete data.

### The Solution: Safe Compaction First, Full Reset Only When Needed

<div align="center">

![The Solution Workflow](assets/architecture-diagram-3.png)

</div>

This toolkit implements two complementary strategies:

- **Non-destructive compaction (default)**  
  Clean up unused Docker data, run filesystem TRIM inside the WSL distro, then compact the VHDX with `Optimize-VHD` and trigger Windows TRIM. This **preserves your Docker images, containers, and volumes**.

- **Full reset (opt-in, destructive)**  
  For cases where you explicitly want a brand-new Docker environment, the script can export, unregister, and delete the VHDX, then let Docker Desktop recreate a fresh disk and optionally re-import the data distro.

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🔄 **One-click shrink (safe by default)** | Single PowerShell script that compacts VHDX without wiping Docker state |
| 🧹 **In-distro cleanup** | Optional `-PruneDocker` flag runs `docker system prune` / `docker builder prune` inside WSL |
| ✂️ **Non-destructive VHDX compaction** | Uses `fstrim` + `Optimize-VHD` to reclaim real Windows disk space |
| 💾 **Optional full reset mode** | `-FullReset` opt-in path for export/unregister/delete when you truly want a clean Docker slate |
| ⚡ **Sparse mode** | Enables WSL2 sparse VHDX for future maintenance (where supported) |
| 📊 **Progress reporting** | Clear status updates throughout the process |
| 🛡️ **Error handling** | Graceful failures with conservative defaults |
| 📖 **Full documentation** | Technical guide and troubleshooting included |

---

## 🚀 Quick Start

### Prerequisites

- Windows 10/11 with WSL2 enabled
- Docker Desktop installed and using WSL2 backend
- PowerShell 5.1 or later
- Administrator privileges

### Option 1: Safe, non-destructive shrink (recommended)

```powershell
# Clone the repository
git clone https://github.com/adnanss/docker-wsl-vhdx-cleanup.git
cd docker-wsl-vhdx-cleanup

# Run as Administrator (safe mode: preserves Docker images/containers/volumes)
powershell -ExecutionPolicy Bypass -File .\scripts\shrink-docker-wsl.ps1 -PruneDocker
```

This will:

- Optionally prune unused Docker data inside WSL (via `-PruneDocker`)
- Run filesystem TRIM (`fstrim -av`) inside the data distro
- Shut down WSL and compact the VHDX files with `Optimize-VHD -Mode Full`
- Trigger Windows TRIM on the host volume

### Option 2: Full reset (destructive, opt-in)

```powershell
# 1. Shutdown WSL
wsl --shutdown

﻿# 2. (Optional) Back up your Docker data via export/import or your own backup strategy.
#
# 3. Run the script in full reset mode (WARNING: this can reset Docker state)
powershell -ExecutionPolicy Bypass -File .\scripts\shrink-docker-wsl.ps1 -FullReset
```

Only use this mode if you **explicitly want a fresh Docker environment** or have backups of all important images/volumes.

---

## 📁 Repository Structure

```
docker-wsl-vhdx-cleanup/
│
├── 📄 README.md                    # This file
├── 📄 LICENSE                      # MIT License
├── 📄 CONTRIBUTING.md              # Contribution guidelines
├── 📄 .gitignore                   # Git ignore patterns
│
├── 📂 assets/
│   ├── architecture-diagram-1.png  # WSL2 Storage Architecture
│   ├── architecture-diagram-2.png  # The Problem Visualization
│   ├── architecture-diagram-3.png  # Solution Workflow
│   ├── architecture-diagram-4.png  # Sparse Mode Behavior
│   ├── architecture-diagram-5.png  # Script Execution Sequence
│   └── architecture-diagram-6.png  # Decision Tree
│
├── 📂 docs/
│   ├── docker-wsl-vhdx-shrink-guide.md   # Comprehensive technical guide
│   └── mermaid-diagram.md          # Architecture diagrams (Mermaid source)
│
├── 📂 scripts/
│   ├── shrink-docker-wsl.ps1       # Main shrink automation script
│   └── validate-wsl-state.ps1      # Diagnostic validation script
│
└── 📂 .github/
    ├── workflows/
    │   └── lint-scripts.yml        # CI validation for PowerShell
    └── ISSUE_TEMPLATE/
        ├── bug_report.md           # Bug report template
        └── feature_request.md      # Feature request template
```

---

## ⚙️ How It Works

### Script Execution Flow (Safe Mode: Default)

<div align="center">

![Script Execution Sequence](assets/architecture-diagram-5.png)

</div>

### Step 1: WSL + Docker cleanup

In safe mode, the script:

- Shuts down all WSL instances
- Optionally runs Docker cleanup **inside the data distro** (`docker-desktop-data`) when `-PruneDocker` is specified:

```powershell
wsl --shutdown
wsl -d docker-desktop-data -- docker system prune -a --volumes -f
wsl -d docker-desktop-data -- docker builder prune --all -f
```

### Step 2: Filesystem TRIM inside WSL

The script then runs `fstrim -av` inside the data distro to mark freed blocks as reclaimable:

```powershell
wsl -d docker-desktop-data -- sudo fstrim -av
```

This is what makes the subsequent VHDX compaction effective.

### Step 3: Compact the VHDX (non-destructive)

With WSL shut down, the script uses the Hyper-V module to compact the VHDX files **without deleting them**:

```powershell
Import-Module Hyper-V
Optimize-VHD -Path "$env:LOCALAPPDATA\Docker\wsl\data\ext4.vhdx" -Mode Full
```

### Step 4: Enable Sparse Mode

Where supported, the script enables WSL2 sparse mode on the VHDX, allowing better future reclamation:

```powershell
wsl --manage docker-desktop --set-sparse true --allow-unsafe
```

<div align="center">

![Sparse Mode Behavior](assets/architecture-diagram-4.png)

</div>

### Step 5: Trigger Windows TRIM

Finally, the script triggers Windows SSD trimming to release the freed space:

```powershell
defrag C: /L
```

---

## 🎓 Best Practices for AI Engineers

### 1. Build Optimization

```dockerfile
# Use multi-stage builds
FROM python:3.11-slim AS builder
COPY requirements.txt .
RUN pip install --user -r requirements.txt

FROM python:3.11-slim
COPY --from=builder /root/.local /root/.local
```

### 2. Effective .dockerignore

```dockerignore
# AI/ML specific ignores
*.pt
*.pth
*.ckpt
*.safetensors
checkpoints/
models/
datasets/
__pycache__/
.git/
node_modules/
```

### 3. BuildKit Cache Mounts

```dockerfile
# syntax=docker/dockerfile:1.4
FROM python:3.11-slim
RUN --mount=type=cache,target=/root/.cache \
    pip install torch transformers accelerate
```

### 4. Volume Strategy

```yaml
# docker-compose.yml - Use external volumes for large data
volumes:
  model-cache:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: D:/docker-volumes/models
```

### 5. Regular Maintenance

```powershell
# Run weekly or when disk usage exceeds threshold
docker system prune -a --volumes
docker builder prune --all --filter "until=168h"

# Check current usage
docker system df
```

### 6. WSL Configuration

Create or update `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
memory=12GB
processors=6
swap=4GB
localhostForwarding=true
```

---

## 🔧 Troubleshooting

### When Should You Run the Shrink Script?

<div align="center">

![Decision Tree - When to Shrink](assets/architecture-diagram-6.png)

</div>

### "Distro not found" error

```powershell
# List all WSL distros to find the correct name
wsl --list --all --verbose
```

### Sparse mode fails

```powershell
# Force sparse mode with unsafe flag (required on some Insider builds)
wsl --manage docker-desktop --set-sparse true --allow-unsafe
```

### VHDX still large after script

```powershell
# 1. Check Docker usage inside WSL
wsl -d docker-desktop-data -- docker system df

# 2. Run with aggressive prune (safe mode)
powershell -ExecutionPolicy Bypass -File .\scripts\shrink-docker-wsl.ps1 -PruneDocker

# 3. Verify sparse status
fsutil sparse queryflag "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"
```

If the VHDX is still significantly larger than the reported Docker data size, you may be limited by:

- Other non-Docker data stored inside the distro
- Lack of `Optimize-VHD` (Hyper-V module not available)

### Docker Desktop fails to start after cleanup or full reset

```powershell
# Reset Docker's WSL metadata (DESTRUCTIVE: this is similar to a full reset)
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\Docker\wsl" -ErrorAction SilentlyContinue

# Restart Docker Desktop - it will rebuild everything from scratch
```

For more detailed troubleshooting, see the [full technical guide](docs/docker-wsl-vhdx-shrink-guide.md).

---

## 🤝 Contributing

Contributions are welcome! If you have discovered:

- Additional WSL shrink techniques
- Sparse-mode behaviors on specific Windows builds
- Performance improvements for ML workloads

Please open an issue or submit a pull request.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">

**Built with practical experience from AI infrastructure engineering**

*Solving the problems that slow down ML development workflows*

</div>
