# 🎙️ Discord Voice Node Patcher

**Studio-grade audio for Discord: 48kHz • 382kbps • True Stereo**

![Version](https://img.shields.io/badge/Version-3.0-5865F2?style=flat-square)
![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?style=flat-square)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?style=flat-square)

---

## ⬇️ Download & Run

### Option 1: One-Click BAT (Recommended)

[**📥 Download DiscordVoicePatcher.bat**](https://github.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/releases/latest)

Just download and double-click. Always runs the latest version.

---

### Option 2: One-Liner (No Download)

```powershell
irm https://raw.githubusercontent.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/main/discord_voice_node_patcher_v2.1.ps1 | iex
```

Paste into PowerShell and press Enter.

---

## ⚠️ Requirement

**You need a C++ compiler.** Install one of these first:

| Compiler | Download |
|----------|----------|
| **Visual Studio** (Recommended) | [Download](https://visualstudio.microsoft.com/downloads/) — Select "Desktop development with C++" |
| MinGW-w64 | [Download](https://www.mingw-w64.org/downloads/) |
| LLVM/Clang | [Download](https://releases.llvm.org/download.html) |

---

## ✨ What It Does

| Before | After |
|:------:|:-----:|
| 24 kHz | **48 kHz** |
| ~64 kbps | **382 kbps** |
| Mono | **True Stereo** |
| Fixed gain | **1x-10x Adjustable** |

Works with: **Discord Stable, Canary, PTB, Development, Vencord, BetterDiscord, Equicord, Lightcord**

---

## 🆕 What's New in v3.0

| Feature | Description |
|---------|-------------|
| **Auto Voice Module Download** | Downloads compatible voice files from GitHub — no more version mismatch errors |
| **Universal Compatibility** | Works regardless of Discord version installed |
| **Auto-Relaunch** | Checkbox to automatically restart Discord after patching |
| **Improved Slider** | Gain slider now responds to click, drag, and keyboard input |

---

<details>
<summary><h2>📖 Full Documentation</h2></summary>

### GUI Features

- **Client Dropdown** — Auto-detects all installed Discord variants
- **Gain Slider** — Adjust volume from 1x to 10x
- **Auto-Relaunch** — Automatically restart Discord after patching (enabled by default)
- **Patch All** — Fix every client with one click
- **Backup/Restore** — Automatic backups before patching

### Command Line

```powershell
.\script.ps1                      # Open GUI
.\script.ps1 -FixAll              # Patch all clients (no GUI)
.\script.ps1 -FixClient "Canary"  # Patch specific client
.\script.ps1 -Restore             # Restore from backup
.\script.ps1 -ListBackups         # Show backups
.\script.ps1 -AudioGainMultiplier 3  # Set gain level
```

### Gain Guide

| Level | Use Case | Safety |
|:-----:|----------|:------:|
| 1-2x | Normal use | ✅ Safe |
| 3-4x | Quiet sources | ⚠️ Caution |
| 5-10x | Maximum boost | ❌ May distort |

### File Locations

| Path | Purpose |
|------|---------|
| `%TEMP%\DiscordVoicePatcher\` | Logs, config, compiled patcher |
| `%TEMP%\DiscordVoicePatcher\Backups\` | Auto-backups (max 10) |

</details>

<details>
<summary><h2>🔧 Troubleshooting</h2></summary>

| Problem | Solution |
|---------|----------|
| "No compiler found" | Install Visual Studio with C++ workload |
| "Discord not found" | Make sure Discord is running |
| "Access denied" | Script auto-elevates, just accept the prompt |
| Audio distorted | Lower gain to 1-2x |
| No effect after patch | Restart Discord completely |

### View Logs
```powershell
notepad "$env:TEMP\DiscordVoicePatcher\patcher.log"
```

### Restore Original
```powershell
irm https://raw.githubusercontent.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/main/discord_voice_node_patcher_v2.1.ps1 | iex
# Then select "Restore" in the GUI
```

</details>

<details>
<summary><h2>📋 Changelog</h2></summary>

### v3.0 (Current) — Major Release
- 🚀 **NEW:** Automatic voice module replacement from GitHub
  - Downloads compatible discord_voice files from ProdHallow/voice-backup
  - Ensures binary offsets always match (no more version mismatch errors)
  - Works regardless of Discord version installed
- 🚀 **NEW:** Auto-relaunch checkbox — automatically restart Discord after patching
- 🐛 **FIXED:** Gain slider now responds to all input types (click, drag, keyboard)
- 🐛 **FIXED:** Replaced minified C++ code with clean original code (fixes Discord crash on voice join)
- ⚠️ **Breaking Change:** Patches are now applied to known-compatible module files rather than arbitrary Discord versions

### v2.6.2
- 🐛 Fixed MSVC compilation error ("Cannot open source file")
- ✨ Added auto-update system
- ✨ Added BAT launcher

### v2.6.1
- 🐛 Fixed empty string parameter error
- 🐛 Fixed array handling issues
- 🐛 Fixed GUI variable scoping

### v2.6.0
- ✨ Multi-client detection (9 Discord variants)
- ✨ "Patch All" button
- ✨ CLI batch mode (`-FixAll`, `-FixClient`)

### v2.5
- ✨ Disk-based detection (no voice channel needed)
- ✨ Auto-elevation

[View full changelog →](https://github.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/releases)

</details>

<details>
<summary><h2>🔬 Technical Details</h2></summary>

### How It Works (v3.0)

1. Downloads compatible voice module files from GitHub backup repository
2. Closes Discord processes
3. Backs up existing voice module (for rollback)
4. Replaces voice module files with compatible versions
5. PowerShell generates C++ patcher code with your settings
6. Compiles to an executable using your C++ compiler
7. Applies binary patches at specific memory offsets
8. Optionally relaunches Discord

### What Gets Patched

| Component | Change |
|-----------|--------|
| Stereo | Disables mono downmix |
| Bitrate | Removes 64kbps cap → 382kbps |
| Sample Rate | Bypasses 24kHz limit → 48kHz |
| Audio Processing | Replaces filters with gain control |

### Offset Table

```
0x520CFB  EmulateStereoSuccess1   → 02
0x520D07  EmulateStereoSuccess2   → EB (JMP)
0x116C91  CreateAudioFrameStereo  → 49 89 C5 90
0x3A0B64  OpusConfigChannels      → 02
0x52115A  BitrateModified         → 90 D4 05 (382kbps)
0x520E63  Emulate48Khz            → 90 90 90
```

</details>

---

## 👥 Credits

**Offsets & Research** — Cypher · Oracle  
**Script & GUI** — Claude (Anthropic)  
**Enhancements** — ProdHallow

---

> ⚠️ **Disclaimer:** Modifies Discord files. Use at your own risk. Re-run after Discord updates. Not affiliated with Discord Inc.

<div align="center">

**[Report Issue](https://github.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/issues)** · **[Releases](https://github.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/releases)** · **[Source Code](https://github.com/ProdHallow/Discord-Voice-Node-Patcher-For-Stereo/blob/main/discord_voice_node_patcher_v2.1.ps1)**

</div>