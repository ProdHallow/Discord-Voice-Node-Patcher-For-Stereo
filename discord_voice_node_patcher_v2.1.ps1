#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Discord Voice Quality Patcher - Enhanced Audio Settings
.DESCRIPTION
    Patches Discord's voice node to enable high-quality audio streaming with configurable gain
.PARAMETER AudioGainMultiplier
    Audio gain multiplier (1-10). Default is 1 (unity gain, no amplification)
.PARAMETER SkipBackup
    Skip creating a backup of the original file
.PARAMETER NoGUI
    Skip GUI and use command-line parameters
.EXAMPLE
    .\DiscordVoicePatcher.ps1
    Launches GUI for configuration
.EXAMPLE
    .\DiscordVoicePatcher.ps1 -NoGUI -AudioGainMultiplier 3
    Patches with 3x gain without showing GUI
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 10)]
    [int]$AudioGainMultiplier = 1,
    
    [switch]$SkipBackup,
    [switch]$NoGUI
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

#region Configuration
$Script:Config = @{
    # Audio Settings
    SampleRate          = 48000
    Bitrate             = 382
    Channels            = "Stereo"
    AudioGainMultiplier = $AudioGainMultiplier  # User-facing multiplier (1-10)
    SkipBackup          = $SkipBackup.IsPresent
    
    # Patch Version
    DiscordVersion = 9219
    
    # Paths
    TempDir   = "$env:TEMP\DiscordVoicePatcher"
    BackupDir = "$env:TEMP\DiscordVoicePatcher\Backups"
    LogFile   = "$env:TEMP\DiscordVoicePatcher\patcher.log"
    
    # Process Names
    ProcessName = "Discord.exe"
    ModuleName  = "discord_voice.node"
    
    # Memory Offsets (for Discord version 9219)
    # These offsets point to specific instructions in discord_voice.node that need patching
    Offsets = @{
        # Stereo Audio Configuration
        CreateAudioFrameStereo            = 0x116C91  # Enables creation of stereo audio frames
        AudioEncoderOpusConfigSetChannels = 0x3A0B64  # Sets Opus encoder to 2 channels
        MonoDownmixer                     = 0xD6319   # Disables mono downmix function
        EmulateStereoSuccess1             = 0x520CFB  # First stereo emulation flag
        EmulateStereoSuccess2             = 0x520D07  # Second stereo emulation flag
        
        # Bitrate Configuration
        EmulateBitrateModified   = 0x52115A  # Sets bitrate to 382kbps
        SetsBitrateBitrateValue  = 0x522F81  # Secondary bitrate location
        SetsBitrateBitwiseOr     = 0x522F89  # Bitrate validation
        
        # Sample Rate Configuration
        Emulate48Khz = 0x520E63  # Enables 48kHz sample rate
        
        # Audio Processing & Filters
        HighPassFilter       = 0x52CF70  # High-pass filter function
        HighpassCutoffFilter = 0x8D64B0  # Custom high-pass implementation
        DcReject             = 0x8D6690  # DC offset rejection filter
        DownmixFunc          = 0x8D2820  # Stereo-to-mono downmix (disabled)
        
        # Validation & Error Handling
        AudioEncoderOpusConfigIsOk = 0x3A0E00  # Opus config validation
        ThrowError                 = 0x2B3340  # Error throwing function
    }
}
#endregion

#region Helper Functions
function Get-InternalMultiplier {
    <#
    .SYNOPSIS
        Converts user-facing multiplier to internal multiplier value
    .DESCRIPTION
        Discord's base stereo gain is 2x. To achieve user's desired gain:
        Internal MULTIPLIER = UserGain - 2
        
        Examples:
        - User wants 1x (unity) → MULTIPLIER = -1 → Actual: 2 + (-1) = 1x ✓
        - User wants 5x         → MULTIPLIER = 3  → Actual: 2 + 3 = 5x ✓
        - User wants 10x        → MULTIPLIER = 8  → Actual: 2 + 8 = 10x ✓
    #>
    param([int]$UserMultiplier)
    
    return $UserMultiplier - 2
}

function Test-Configuration {
    <#
    .SYNOPSIS
        Validates the current configuration
    #>
    
    if ($Script:Config.AudioGainMultiplier -lt 1 -or $Script:Config.AudioGainMultiplier -gt 10) {
        throw "Audio gain multiplier must be between 1 and 10"
    }
    
    return $true
}
#endregion

#region GUI Functions
function Show-ConfigurationGUI {
    <#
    .SYNOPSIS
        Displays GUI for user to configure patch settings
    .OUTPUTS
        Hashtable with Multiplier and SkipBackup values, or $null if cancelled
    #>
    
    # Create form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Discord Voice Patcher Configuration"
    $form.ClientSize = New-Object System.Drawing.Size(520, 420)  # Use ClientSize to ensure proper internal space
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(44, 47, 51)
    $form.ForeColor = [System.Drawing.Color]::White
    
    # Title
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)
    $titleLabel.Size = New-Object System.Drawing.Size(480, 30)
    $titleLabel.Text = "Discord Voice Quality Patcher"
    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(88, 101, 242)
    $form.Controls.Add($titleLabel)
    
    # Subtitle
    $subtitleLabel = New-Object System.Windows.Forms.Label
    $subtitleLabel.Location = New-Object System.Drawing.Point(20, 55)
    $subtitleLabel.Size = New-Object System.Drawing.Size(480, 20)
    $subtitleLabel.Text = "48kHz | 382kbps | Stereo | Configurable Gain"
    $subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 187, 190)
    $form.Controls.Add($subtitleLabel)
    
    # Separator
    $separator1 = New-Object System.Windows.Forms.Label
    $separator1.Location = New-Object System.Drawing.Point(20, 85)
    $separator1.Size = New-Object System.Drawing.Size(480, 2)
    $separator1.BorderStyle = "Fixed3D"
    $form.Controls.Add($separator1)
    
    # Gain Section Title
    $gainLabel = New-Object System.Windows.Forms.Label
    $gainLabel.Location = New-Object System.Drawing.Point(20, 105)
    $gainLabel.Size = New-Object System.Drawing.Size(480, 25)
    $gainLabel.Text = "Audio Gain Multiplier"
    $gainLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($gainLabel)
    
    # Current Value Display
    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.Location = New-Object System.Drawing.Point(20, 140)
    $valueLabel.Size = New-Object System.Drawing.Size(480, 35)
    $valueLabel.Text = "1x (Unity Gain - No Amplification)"
    $valueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(87, 242, 135)
    $valueLabel.TextAlign = "MiddleCenter"
    $form.Controls.Add($valueLabel)
    
    # Slider
    $slider = New-Object System.Windows.Forms.TrackBar
    $slider.Location = New-Object System.Drawing.Point(30, 185)
    $slider.Size = New-Object System.Drawing.Size(460, 45)
    $slider.Minimum = 1
    $slider.Maximum = 10
    $slider.TickFrequency = 1
    $slider.Value = [Math]::Max(1, [Math]::Min(10, $Script:Config.AudioGainMultiplier))
    $slider.BackColor = [System.Drawing.Color]::FromArgb(44, 47, 51)
    
    # Slider value change event
    $slider.Add_ValueChanged({
        $multiplier = $slider.Value
        
        # Update display text
        if ($multiplier -eq 1) {
            $valueLabel.Text = "1x (Unity Gain - No Amplification)"
        } else {
            $valueLabel.Text = "${multiplier}x Amplification"
        }
        
        # Color coding based on safety
        if ($multiplier -le 2) {
            $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(87, 242, 135)  # Green - Safe
        } elseif ($multiplier -le 5) {
            $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(254, 231, 92)  # Yellow - Moderate
        } else {
            $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(237, 66, 69)   # Red - High risk
        }
    })
    
    $form.Controls.Add($slider)
    
    # Scale markers (moved down 5px to prevent overlap with slider)
    $scaleLabel = New-Object System.Windows.Forms.Label
    $scaleLabel.Location = New-Object System.Drawing.Point(30, 235)
    $scaleLabel.Size = New-Object System.Drawing.Size(460, 20)
    $scaleLabel.Text = "1x      2x      3x      4x      5x      6x      7x      8x      9x     10x"
    $scaleLabel.Font = New-Object System.Drawing.Font("Consolas", 8)
    $scaleLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 152, 157)
    $form.Controls.Add($scaleLabel)
    
    # Info/Warning text (adjusted position)
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Location = New-Object System.Drawing.Point(20, 265)
    $infoLabel.Size = New-Object System.Drawing.Size(480, 40)
    $infoLabel.Text = "⚠ Recommended: 1-2x for most users`n" +
                      "⚠ Warning: Values above 5x may cause severe distortion and clipping"
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $infoLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 187, 190)
    $form.Controls.Add($infoLabel)
    
    # Separator
    $separator2 = New-Object System.Windows.Forms.Label
    $separator2.Location = New-Object System.Drawing.Point(20, 310)
    $separator2.Size = New-Object System.Drawing.Size(480, 2)
    $separator2.BorderStyle = "Fixed3D"
    $form.Controls.Add($separator2)
    
    # Backup checkbox
    $backupCheckbox = New-Object System.Windows.Forms.CheckBox
    $backupCheckbox.Location = New-Object System.Drawing.Point(20, 322)
    $backupCheckbox.Size = New-Object System.Drawing.Size(480, 25)
    $backupCheckbox.Text = "✓ Create backup before patching (Strongly Recommended)"
    $backupCheckbox.Checked = -not $Script:Config.SkipBackup
    $backupCheckbox.ForeColor = [System.Drawing.Color]::White
    $backupCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($backupCheckbox)
    
    # Patch button
    $patchButton = New-Object System.Windows.Forms.Button
    $patchButton.Location = New-Object System.Drawing.Point(300, 365)
    $patchButton.Size = New-Object System.Drawing.Size(100, 35)
    $patchButton.Text = "Patch"
    $patchButton.BackColor = [System.Drawing.Color]::FromArgb(88, 101, 242)
    $patchButton.ForeColor = [System.Drawing.Color]::White
    $patchButton.FlatStyle = "Flat"
    $patchButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $patchButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $patchButton.Add_Click({
        $form.Tag = @{
            Multiplier = $slider.Value
            SkipBackup = -not $backupCheckbox.Checked
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($patchButton)
    
    # Cancel button
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Location = New-Object System.Drawing.Point(410, 365)
    $cancelButton.Size = New-Object System.Drawing.Size(90, 35)
    $cancelButton.Text = "Cancel"
    $cancelButton.BackColor = [System.Drawing.Color]::FromArgb(79, 84, 92)
    $cancelButton.ForeColor = [System.Drawing.Color]::White
    $cancelButton.FlatStyle = "Flat"
    $cancelButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $cancelButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $cancelButton.Add_Click({
        $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Close()
    })
    $form.Controls.Add($cancelButton)
    
    # Show form and return result
    $result = $form.ShowDialog()
    
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        return $form.Tag
    }
    
    return $null
}
#endregion

#region Logging Functions
function Write-Banner {
    Write-Host @"
╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║         Discord Voice Quality Patcher v2.1                    ║
║         48kHz | 382kbps | Stereo | Configurable Gain         ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan
    Write-Host ""
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    try {
        Add-Content -Path $Script:Config.LogFile -Value $logMessage -ErrorAction SilentlyContinue
    } catch {
        # Silently fail if can't write to log
    }
    
    # Console output
    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   { 'White' }
    }
    
    $prefix = switch ($Level) {
        'Success' { '[✓]' }
        'Warning' { '[!]' }
        'Error'   { '[✗]' }
        default   { '[•]' }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Show-Settings {
    Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Current Patch Configuration" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Sample Rate:    $($Script:Config.SampleRate) Hz" -ForegroundColor White
    Write-Host "  Bitrate:        $($Script:Config.Bitrate) kbps" -ForegroundColor White
    Write-Host "  Channels:       $($Script:Config.Channels)" -ForegroundColor White
    Write-Host "  Audio Gain:     $($Script:Config.AudioGainMultiplier)x" -ForegroundColor $(
        if ($Script:Config.AudioGainMultiplier -le 2) { 'Green' }
        elseif ($Script:Config.AudioGainMultiplier -le 5) { 'Yellow' }
        else { 'Red' }
    )
    Write-Host "═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}
#endregion

#region Environment Functions
function Initialize-Environment {
    Write-Log "Initializing environment..." -Level Info
    
    # Create directories
    @($Script:Config.TempDir, $Script:Config.BackupDir) | ForEach-Object {
        if (-not (Test-Path $_)) {
            New-Item -ItemType Directory -Path $_ -Force | Out-Null
            Write-Log "Created directory: $_" -Level Info
        }
    }
    
    # Initialize log file
    try {
        @"
═══════════════════════════════════════
Discord Voice Patcher Log
═══════════════════════════════════════
Started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Settings: $($Script:Config.AudioGainMultiplier)x gain, $($Script:Config.SampleRate)Hz, $($Script:Config.Bitrate)kbps
═══════════════════════════════════════

"@ | Out-File $Script:Config.LogFile -Force
    } catch {
        Write-Log "Could not create log file" -Level Warning
    }
}

function Test-DiscordRunning {
    $processes = Get-Process -Name ($Script:Config.ProcessName -replace '\.exe$', '') -ErrorAction SilentlyContinue
    
    if (-not $processes) {
        Write-Log "Discord is not running" -Level Error
        Write-Host "    Please start Discord before running the patcher" -ForegroundColor Yellow
        return $false
    }
    
    Write-Log "Discord is running (PID: $($processes[0].Id))" -Level Success
    return $true
}

function Backup-VoiceNode {
    param([string]$SourcePath)
    
    if ($Script:Config.SkipBackup) {
        Write-Log "Skipping backup (user requested)" -Level Warning
        return $true
    }
    
    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $backupPath = Join-Path $Script:Config.BackupDir "discord_voice.node.$timestamp.backup"
        
        Copy-Item -Path $SourcePath -Destination $backupPath -Force
        Write-Log "Backup created: $backupPath" -Level Success
        return $true
    } catch {
        Write-Log "Failed to create backup: $($_.Exception.Message)" -Level Error
        return $false
    }
}
#endregion

#region Compiler Functions
function Find-Compiler {
    Write-Log "Searching for C++ compiler..." -Level Info
    
    # Try MSVC (Visual Studio)
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        try {
            $vsPath = & $vsWhere -latest -property installationPath 2>$null
            if ($vsPath) {
                $vcvarsPath = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
                if (Test-Path $vcvarsPath) {
                    Write-Log "Found Visual Studio" -Level Success
                    return @{ Type = 'MSVC'; Path = $vcvarsPath }
                }
            }
        } catch {
            # Continue to next compiler
        }
    }
    
    # Try MinGW
    $gpp = Get-Command "g++" -ErrorAction SilentlyContinue
    if ($gpp) {
        Write-Log "Found MinGW g++" -Level Success
        return @{ Type = 'MinGW'; Path = $gpp.Source }
    }
    
    # Try Clang
    $clang = Get-Command "clang++" -ErrorAction SilentlyContinue
    if ($clang) {
        Write-Log "Found Clang" -Level Success
        return @{ Type = 'Clang'; Path = $clang.Source }
    }
    
    Write-Log "No C++ compiler found" -Level Error
    Show-CompilerInstallHelp
    return $null
}

function Show-CompilerInstallHelp {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  No C++ Compiler Found" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Please install one of the following:" -ForegroundColor White
    Write-Host ""
    Write-Host "  1. Visual Studio (Recommended)" -ForegroundColor Cyan
    Write-Host "     https://visualstudio.microsoft.com/downloads/" -ForegroundColor Gray
    Write-Host "     Install 'Desktop development with C++' workload" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. MinGW-w64" -ForegroundColor Cyan
    Write-Host "     https://www.mingw-w64.org/downloads/" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. LLVM/Clang" -ForegroundColor Cyan
    Write-Host "     https://releases.llvm.org/download.html" -ForegroundColor Gray
    Write-Host ""
}
#endregion

#region Source Code Generation
function Get-AmplifierSourceCode {
    <#
    .SYNOPSIS
        Generates the C++ amplifier/gain control source code
    #>
    
    $internalMultiplier = Get-InternalMultiplier -UserMultiplier $Script:Config.AudioGainMultiplier
    
    return @"
/*
 * Audio Gain Amplifier Module
 * 
 * User-selected gain: $($Script:Config.AudioGainMultiplier)x
 * Internal multiplier: $internalMultiplier
 * 
 * Calculation:
 *   Discord's base stereo processing applies 2x gain
 *   To get the user's desired Nx gain: MULTIPLIER = N - 2
 *   Final gain = channels + MULTIPLIER = 2 + $internalMultiplier = $($Script:Config.AudioGainMultiplier)x
 * 
 * Examples:
 *   1x (unity)  → MULTIPLIER = -1 → gain = 2 + (-1) = 1x
 *   2x          → MULTIPLIER = 0  → gain = 2 + 0 = 2x
 *   5x          → MULTIPLIER = 3  → gain = 2 + 3 = 5x
 *   10x         → MULTIPLIER = 8  → gain = 2 + 8 = 10x
 */

#define MULTIPLIER $internalMultiplier
#define STEREO_CHANNELS 2

// Voice state memory structure offsets
struct VoiceStateOffsets {
    static constexpr int BASE_OFFSET = -3553;
    static constexpr int FLAG_OFFSET = 3557;
    static constexpr int FILTER_STATE_1 = 160;
    static constexpr int FILTER_STATE_2 = 164;
    static constexpr int FILTER_STATE_3 = 184;
    static constexpr int FLAG_VALUE = 1002;
};

// Initialize Discord's voice processing state
inline void InitializeVoiceState(int* hp_mem) {
    int* state_base = hp_mem + VoiceStateOffsets::BASE_OFFSET;
    *(state_base + VoiceStateOffsets::FLAG_OFFSET) = VoiceStateOffsets::FLAG_VALUE;
    *(int*)((char*)state_base + VoiceStateOffsets::FILTER_STATE_1) = -1;
    *(int*)((char*)state_base + VoiceStateOffsets::FILTER_STATE_2) = -1;
    *(int*)((char*)state_base + VoiceStateOffsets::FILTER_STATE_3) = 0;
}

// Apply gain to audio samples
inline void ApplyAudioGain(const float* in, float* out, int sample_count, int channels) {
    const float gain = static_cast<float>(channels + MULTIPLIER);
    for (int i = 0; i < sample_count; i++) {
        out[i] = in[i] * gain;
    }
}

// High-pass cutoff filter (replaced with gain control)
extern "C" void __cdecl hp_cutoff(
    const float* in, int cutoff_Hz, float* out, int* hp_mem,
    int len, int channels, int Fs, int arch)
{
    InitializeVoiceState(hp_mem);
    ApplyAudioGain(in, out, channels * len, channels);
}

// DC rejection filter (replaced with gain control)
extern "C" void __cdecl dc_reject(
    const float* in, float* out, int* hp_mem,
    int len, int channels, int Fs)
{
    InitializeVoiceState(hp_mem);
    ApplyAudioGain(in, out, channels * len, channels);
}
"@
}

function Get-PatcherSourceCode {
    <#
    .SYNOPSIS
        Generates the main C++ patcher source code
    #>
    
    $offsets = $Script:Config.Offsets
    
    return @"
/*
 * Discord Voice Quality Patcher
 * Version: 2.1
 * 
 * Patches discord_voice.node to enable:
 *   - Stereo audio output
 *   - 48kHz sample rate
 *   - 382kbps Opus bitrate
 *   - $($Script:Config.AudioGainMultiplier)x audio gain
 */

#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <iostream>
#include <string>

// Configuration
#define DISCORD_VERSION $($Script:Config.DiscordVersion)
#define SAMPLE_RATE $($Script:Config.SampleRate)
#define BITRATE $($Script:Config.Bitrate)
#define AUDIO_GAIN $($Script:Config.AudioGainMultiplier)

// External audio functions
extern "C" void dc_reject(const float*, float*, int*, int, int, int);
extern "C" void hp_cutoff(const float*, int, float*, int*, int, int, int, int);

// Memory offsets for Discord v$($Script:Config.DiscordVersion)
namespace Offsets {
    // Stereo configuration
    constexpr uint32_t CreateAudioFrameStereo = $('0x{0:X}' -f $offsets.CreateAudioFrameStereo);
    constexpr uint32_t AudioEncoderOpusConfigSetChannels = $('0x{0:X}' -f $offsets.AudioEncoderOpusConfigSetChannels);
    constexpr uint32_t MonoDownmixer = $('0x{0:X}' -f $offsets.MonoDownmixer);
    constexpr uint32_t EmulateStereoSuccess1 = $('0x{0:X}' -f $offsets.EmulateStereoSuccess1);
    constexpr uint32_t EmulateStereoSuccess2 = $('0x{0:X}' -f $offsets.EmulateStereoSuccess2);
    
    // Bitrate configuration
    constexpr uint32_t EmulateBitrateModified = $('0x{0:X}' -f $offsets.EmulateBitrateModified);
    constexpr uint32_t SetsBitrateBitrateValue = $('0x{0:X}' -f $offsets.SetsBitrateBitrateValue);
    constexpr uint32_t SetsBitrateBitwiseOr = $('0x{0:X}' -f $offsets.SetsBitrateBitwiseOr);
    
    // Sample rate
    constexpr uint32_t Emulate48Khz = $('0x{0:X}' -f $offsets.Emulate48Khz);
    
    // Audio processing
    constexpr uint32_t HighPassFilter = $('0x{0:X}' -f $offsets.HighPassFilter);
    constexpr uint32_t HighpassCutoffFilter = $('0x{0:X}' -f $offsets.HighpassCutoffFilter);
    constexpr uint32_t DcReject = $('0x{0:X}' -f $offsets.DcReject);
    constexpr uint32_t DownmixFunc = $('0x{0:X}' -f $offsets.DownmixFunc);
    
    // Validation
    constexpr uint32_t AudioEncoderOpusConfigIsOk = $('0x{0:X}' -f $offsets.AudioEncoderOpusConfigIsOk);
    constexpr uint32_t ThrowError = $('0x{0:X}' -f $offsets.ThrowError);
    
    constexpr uint32_t FILE_OFFSET_ADJUSTMENT = 0xC00;
};

class DiscordPatcher {
private:
    HANDLE process;
    std::string modulePath;
    
    bool TerminateAllDiscordProcesses() {
        printf("Closing Discord...\n");
        HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == INVALID_HANDLE_VALUE) return false;
        
        PROCESSENTRY32 entry = {sizeof(PROCESSENTRY32)};
        while (Process32Next(snapshot, &entry)) {
            if (strcmp(entry.szExeFile, "$($Script:Config.ProcessName)") == 0) {
                HANDLE proc = OpenProcess(PROCESS_TERMINATE, FALSE, entry.th32ProcessID);
                if (proc) {
                    TerminateProcess(proc, 0);
                    CloseHandle(proc);
                }
            }
        }
        CloseHandle(snapshot);
        return true;
    }
    
    bool WaitForDiscordClose(int maxAttempts = 10) {
        for (int i = 0; i < maxAttempts; i++) {
            HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot == INVALID_HANDLE_VALUE) return false;
            
            PROCESSENTRY32 entry = {sizeof(PROCESSENTRY32)};
            bool found = false;
            
            while (Process32Next(snapshot, &entry)) {
                if (strcmp(entry.szExeFile, "$($Script:Config.ProcessName)") == 0) {
                    found = true;
                    break;
                }
            }
            CloseHandle(snapshot);
            if (!found) return true;
            Sleep(100);
        }
        return false;
    }
    
    bool ApplyPatches(void* fileData) {
        printf("\nApplying patches:\n");
        
        auto PatchBytes = [&](uint32_t offset, const char* bytes, size_t len) {
            memcpy((char*)fileData + (offset - Offsets::FILE_OFFSET_ADJUSTMENT), bytes, len);
        };
        
        // Stereo patches
        printf("  [1/4] Enabling stereo audio...\n");
        PatchBytes(Offsets::EmulateStereoSuccess1, "\x02", 1);
        PatchBytes(Offsets::EmulateStereoSuccess2, "\xEB", 1);
        PatchBytes(Offsets::CreateAudioFrameStereo, "\x49\x89\xC5\x90", 4);
        PatchBytes(Offsets::AudioEncoderOpusConfigSetChannels, "\x02", 1);
        PatchBytes(Offsets::MonoDownmixer, "\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\xE9", 13);
        
        // Bitrate patches
        printf("  [2/4] Setting bitrate to 382kbps...\n");
        PatchBytes(Offsets::EmulateBitrateModified, "\x90\xD4\x05", 3);
        PatchBytes(Offsets::SetsBitrateBitrateValue, "\x90\xD4\x05\x00\x00", 5);
        PatchBytes(Offsets::SetsBitrateBitwiseOr, "\x90\x90\x90", 3);
        
        // Sample rate
        printf("  [3/4] Enabling 48kHz sample rate...\n");
        PatchBytes(Offsets::Emulate48Khz, "\x90\x90\x90", 3);
        
        // Audio processing
        printf("  [4/4] Injecting custom audio processing...\n");
        PatchBytes(Offsets::HighPassFilter, "\x48\xB8\x10\x9E\xD8\xCF\x08\x02\x00\x00\xC3", 11);
        PatchBytes(Offsets::HighpassCutoffFilter, (const char*)hp_cutoff, 0x100);
        PatchBytes(Offsets::DcReject, (const char*)dc_reject, 0x1B6);
        PatchBytes(Offsets::DownmixFunc, "\xC3", 1);
        PatchBytes(Offsets::AudioEncoderOpusConfigIsOk, "\x48\xC7\xC0\x01\x00\x00\x00\xC3", 8);
        PatchBytes(Offsets::ThrowError, "\xC3", 1);
        
        printf("  All patches applied successfully!\n");
        return true;
    }
    
public:
    DiscordPatcher(HANDLE proc, const std::string& path) 
        : process(proc), modulePath(path) {}
    
    bool PatchFile() {
        printf("\n================================================\n");
        printf("  Discord Voice Quality Patcher\n");
        printf("================================================\n");
        printf("  Target:  %s\n", modulePath.c_str());
        printf("  Version: %d\n", DISCORD_VERSION);
        printf("  Config:  %dkHz, %dkbps, Stereo, %dx gain\n", 
               SAMPLE_RATE/1000, BITRATE, AUDIO_GAIN);
        printf("================================================\n\n");
        
        // Close Discord
        TerminateProcess(process, 0);
        if (!WaitForDiscordClose()) {
            TerminateAllDiscordProcesses();
            Sleep(500);
        }
        
        // Open file
        printf("Opening file for patching...\n");
        HANDLE file = CreateFileA(modulePath.c_str(), GENERIC_READ | GENERIC_WRITE,
                                  0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        
        if (file == INVALID_HANDLE_VALUE) {
            printf("ERROR: Cannot open file (Error: %d)\n", GetLastError());
            printf("Make sure you're running as Administrator\n");
            return false;
        }
        
        // Get file size
        LARGE_INTEGER fileSize;
        if (!GetFileSizeEx(file, &fileSize)) {
            printf("ERROR: Cannot get file size\n");
            CloseHandle(file);
            return false;
        }
        
        printf("File size: %lld bytes\n", fileSize.QuadPart);
        
        // Allocate memory
        void* fileData = VirtualAlloc(nullptr, fileSize.QuadPart, 
                                      MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (!fileData) {
            printf("ERROR: Cannot allocate memory\n");
            CloseHandle(file);
            return false;
        }
        
        // Read file
        DWORD bytesRead;
        if (!ReadFile(file, fileData, fileSize.QuadPart, &bytesRead, NULL)) {
            printf("ERROR: Cannot read file\n");
            VirtualFree(fileData, 0, MEM_RELEASE);
            CloseHandle(file);
            return false;
        }
        
        // Apply patches
        if (!ApplyPatches(fileData)) {
            VirtualFree(fileData, 0, MEM_RELEASE);
            CloseHandle(file);
            return false;
        }
        
        // Write patched file
        printf("\nWriting patched file...\n");
        SetFilePointer(file, 0, NULL, FILE_BEGIN);
        DWORD bytesWritten;
        if (!WriteFile(file, fileData, fileSize.QuadPart, &bytesWritten, NULL)) {
            printf("ERROR: Cannot write file (Error: %d)\n", GetLastError());
            VirtualFree(fileData, 0, MEM_RELEASE);
            CloseHandle(file);
            return false;
        }
        
        // Cleanup
        VirtualFree(fileData, 0, MEM_RELEASE);
        CloseHandle(file);
        
        printf("\n================================================\n");
        printf("  SUCCESS! Patching Complete!\n");
        printf("================================================\n");
        printf("  You can now restart Discord\n");
        printf("  Audio will be %dx amplified\n", AUDIO_GAIN);
        printf("================================================\n\n");
        
        return true;
    }
};

int main() {
    SetConsoleTitle("Discord Voice Patcher");
    
    printf("Searching for Discord process...\n");
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        printf("ERROR: Cannot create process snapshot\n");
        system("pause");
        return 1;
    }
    
    PROCESSENTRY32 entry = {sizeof(PROCESSENTRY32)};
    while (Process32Next(snapshot, &entry)) {
        if (strcmp(entry.szExeFile, "$($Script:Config.ProcessName)") == 0) {
            printf("Found Discord (PID: %d)\n", entry.th32ProcessID);
            
            HANDLE process = OpenProcess(PROCESS_ALL_ACCESS, FALSE, entry.th32ProcessID);
            if (!process) {
                printf("ERROR: Cannot open process (run as Administrator)\n");
                continue;
            }
            
            HMODULE modules[1024];
            DWORD bytesNeeded;
            if (!EnumProcessModules(process, modules, sizeof(modules), &bytesNeeded)) {
                printf("ERROR: Cannot enumerate modules\n");
                CloseHandle(process);
                continue;
            }
            
            printf("Searching for $($Script:Config.ModuleName)...\n");
            
            for (DWORD i = 0; i < bytesNeeded / sizeof(HMODULE); i++) {
                char moduleName[MAX_PATH];
                if (GetModuleBaseNameA(process, modules[i], moduleName, sizeof(moduleName))) {
                    if (strcmp(moduleName, "$($Script:Config.ModuleName)") == 0) {
                        char modulePath[MAX_PATH];
                        GetModuleFileNameExA(process, modules[i], modulePath, MAX_PATH);
                        
                        CloseHandle(snapshot);
                        DiscordPatcher patcher(process, modulePath);
                        bool success = patcher.PatchFile();
                        CloseHandle(process);
                        
                        system("pause");
                        return success ? 0 : 1;
                    }
                }
            }
            
            CloseHandle(process);
        }
    }
    
    CloseHandle(snapshot);
    printf("\nERROR: Could not find Discord or $($Script:Config.ModuleName)\n");
    printf("Please make sure Discord is running\n\n");
    system("pause");
    return 1;
}
"@
}

function New-SourceFiles {
    <#
    .SYNOPSIS
        Creates the C++ source files for compilation
    #>
    
    Write-Log "Generating source files..." -Level Info
    
    try {
        $patcherPath = Join-Path $Script:Config.TempDir "patcher.cpp"
        $amplifierPath = Join-Path $Script:Config.TempDir "amplifier.cpp"
        
        Get-PatcherSourceCode | Out-File -FilePath $patcherPath -Encoding ASCII -Force
        Get-AmplifierSourceCode | Out-File -FilePath $amplifierPath -Encoding ASCII -Force
        
        Write-Log "Source files created successfully" -Level Success
        return @($patcherPath, $amplifierPath)
    } catch {
        Write-Log "Failed to create source files: $($_.Exception.Message)" -Level Error
        return $null
    }
}
#endregion

#region Compilation
function Invoke-Compilation {
    <#
    .SYNOPSIS
        Compiles the C++ source files into an executable
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Compiler,
        
        [Parameter(Mandatory)]
        [string[]]$SourceFiles
    )
    
    Write-Log "Compiling with $($Compiler.Type)..." -Level Info
    
    $exePath = Join-Path $Script:Config.TempDir "DiscordVoicePatcher.exe"
    $buildLog = Join-Path $Script:Config.TempDir "build.log"
    
    try {
        switch ($Compiler.Type) {
            'MSVC' {
                $buildScript = @"
@echo off
call "$($Compiler.Path)"
cl.exe /EHsc /O2 /std:c++17 "$($SourceFiles -join '" "')" /Fe"$exePath" /link Psapi.lib
"@
                $buildScriptPath = Join-Path $Script:Config.TempDir "build.bat"
                $buildScript | Out-File $buildScriptPath -Encoding ASCII
                $null = cmd /c "`"$buildScriptPath`" > `"$buildLog`" 2>&1"
            }
            
            'MinGW' {
                & g++ -O2 -std=c++17 $SourceFiles -o $exePath -lpsapi -static 2>&1 | Out-File $buildLog
            }
            
            'Clang' {
                & clang++ -O2 -std=c++17 $SourceFiles -o $exePath -lpsapi 2>&1 | Out-File $buildLog
            }
        }
        
        if (Test-Path $exePath) {
            Write-Log "Compilation successful!" -Level Success
            return $exePath
        } else {
            throw "Executable not created"
        }
    } catch {
        Write-Log "Compilation failed" -Level Error
        Write-Host ""
        Write-Host "Build Log:" -ForegroundColor Yellow
        if (Test-Path $buildLog) {
            Get-Content $buildLog | Write-Host
        }
        return $null
    }
}
#endregion

#region Main Execution
function Start-Patching {
    <#
    .SYNOPSIS
        Main patching workflow
    #>
    
    Write-Banner
    
    # Show GUI if not disabled
    if (-not $NoGUI) {
        Write-Log "Opening configuration GUI..." -Level Info
        Write-Host ""
        
        $guiResult = Show-ConfigurationGUI
        
        if ($null -eq $guiResult) {
            Write-Log "User cancelled operation" -Level Warning
            return $false
        }
        
        # Update config from GUI
        $Script:Config.AudioGainMultiplier = $guiResult.Multiplier
        $Script:Config.SkipBackup = $guiResult.SkipBackup
        
        Write-Host ""
    }
    
    # Validate configuration
    try {
        Test-Configuration | Out-Null
    } catch {
        Write-Log "Invalid configuration: $($_.Exception.Message)" -Level Error
        return $false
    }
    
    Show-Settings
    
    # Initialize environment
    Initialize-Environment
    
    # Check Discord is running
    if (-not (Test-DiscordRunning)) {
        Read-Host "Press Enter to exit"
        return $false
    }
    
    # Find compiler
    $compiler = Find-Compiler
    if (-not $compiler) {
        Read-Host "Press Enter to exit"
        return $false
    }
    
    # Generate source files
    $sourceFiles = New-SourceFiles
    if (-not $sourceFiles) {
        Read-Host "Press Enter to exit"
        return $false
    }
    
    # Compile
    $executable = Invoke-Compilation -Compiler $compiler -SourceFiles $sourceFiles
    if (-not $executable) {
        Read-Host "Press Enter to exit"
        return $false
    }
    
    # Run patcher
    Write-Host ""
    Write-Log "Launching patcher..." -Level Info
    Write-Host ""
    
    try {
        Start-Process -FilePath $executable -Wait -NoNewWindow
        Write-Host ""
        Write-Log "Patching complete!" -Level Success
        return $true
    } catch {
        Write-Log "Patcher execution failed: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# Entry Point
try {
    $success = Start-Patching
    
    Write-Host ""
    if ($success) {
        Write-Host "═══════════════════════════════════════" -ForegroundColor Green
        Write-Host "  Patching completed successfully!" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════" -ForegroundColor Green
    } else {
        Write-Host "═══════════════════════════════════════" -ForegroundColor Red
        Write-Host "  Patching failed or was cancelled" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════" -ForegroundColor Red
    }
    Write-Host ""
    
    Read-Host "Press Enter to exit"
    if ($success) { exit 0 } else { exit 1 }
    
} catch {
    Write-Host ""
    Write-Host "═══════════════════════════════════════" -ForegroundColor Red
    Write-Host "  FATAL ERROR" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════" -ForegroundColor Red
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level Error
    Write-Host ""
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}
#endregion
