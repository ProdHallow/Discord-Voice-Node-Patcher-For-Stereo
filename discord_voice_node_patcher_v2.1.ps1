<#

.SYNOPSIS

    Discord Voice Quality Patcher - Enhanced Audio Settings v2.4

.DESCRIPTION

    Patches Discord's voice node to enable high-quality audio streaming with configurable gain.

    Automatically requests Administrator privileges if needed.

.PARAMETER AudioGainMultiplier

    Audio gain multiplier (1-10). Default is 1 (unity gain, no amplification)

.PARAMETER SkipBackup

    Skip creating a backup of the original file

.PARAMETER NoGUI

    Skip GUI and use command-line parameters

.PARAMETER Restore

    Restore from most recent backup

.PARAMETER ListBackups

    List all available backups

.EXAMPLE

    .\DiscordVoicePatcher.ps1

    Launches GUI for configuration (auto-elevates if needed)

.EXAMPLE

    .\DiscordVoicePatcher.ps1 -NoGUI -AudioGainMultiplier 3

    Patches with 3x gain without showing GUI

.EXAMPLE

    .\DiscordVoicePatcher.ps1 -Restore

    Restores from most recent backup

.NOTES

    v2.4 - Code cleanup and optimization, preserved original patching logic

#>



[CmdletBinding()]

param(

    [ValidateRange(1, 10)]

    [int]$AudioGainMultiplier = 1,

    

    [switch]$SkipBackup,

    [switch]$NoGUI,

    [switch]$Restore,

    [switch]$ListBackups

)



$ErrorActionPreference = "Stop"



#region Auto-Elevation

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())

$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)



if (-not $isAdmin) {

    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow

    

    try {

        $arguments = @(

            "-NoProfile",

            "-ExecutionPolicy", "Bypass",

            "-File", "`"$PSCommandPath`""

        )

        

        if ($PSBoundParameters.ContainsKey('AudioGainMultiplier')) {

            $arguments += "-AudioGainMultiplier", $AudioGainMultiplier

        }

        if ($SkipBackup) { $arguments += "-SkipBackup" }

        if ($NoGUI) { $arguments += "-NoGUI" }

        if ($Restore) { $arguments += "-Restore" }

        if ($ListBackups) { $arguments += "-ListBackups" }

        

        Start-Process -FilePath "powershell.exe" `

                      -ArgumentList $arguments `

                      -Verb RunAs

        exit 0

        

    } catch {

        Write-Host "ERROR: Failed to elevate to administrator" -ForegroundColor Red

        Write-Host "Please run PowerShell as Administrator manually" -ForegroundColor Yellow

        Read-Host "Press Enter to exit"

        exit 1

    }

}

#endregion



#region Configuration

$Script:Config = @{

    # Audio Settings

    SampleRate          = 48000

    Bitrate             = 382

    Channels            = "Stereo"

    AudioGainMultiplier = $AudioGainMultiplier

    SkipBackup          = $SkipBackup.IsPresent

    

    # Discord Settings

    DiscordVersion      = 9219

    ProcessName         = "Discord.exe"

    ProcessBaseName     = "Discord"

    ModuleName          = "discord_voice.node"

    

    # Paths

    TempDir             = Join-Path $env:TEMP "DiscordVoicePatcher"

    BackupDir           = Join-Path $env:TEMP "DiscordVoicePatcher\Backups"

    LogFile             = Join-Path $env:TEMP "DiscordVoicePatcher\patcher.log"

    ConfigFile          = Join-Path $env:TEMP "DiscordVoicePatcher\config.json"

    

    # Backup Management

    MaxBackupCount      = 10

    

    # File Validation

    ExpectedFileSize    = @{

        Min = 14000000

        Max = 18000000

    }

    

    # Binary Offsets (Discord version specific)

    Offsets             = @{

        CreateAudioFrameStereo            = 0x116C91

        AudioEncoderOpusConfigSetChannels = 0x3A0B64

        MonoDownmixer                     = 0xD6319

        EmulateStereoSuccess1             = 0x520CFB

        EmulateStereoSuccess2             = 0x520D07

        EmulateBitrateModified            = 0x52115A

        SetsBitrateBitrateValue           = 0x522F81

        SetsBitrateBitwiseOr              = 0x522F89

        Emulate48Khz                      = 0x520E63

        HighPassFilter                    = 0x52CF70

        HighpassCutoffFilter              = 0x8D64B0

        DcReject                          = 0x8D6690

        DownmixFunc                       = 0x8D2820

        AudioEncoderOpusConfigIsOk        = 0x3A0E00

        ThrowError                        = 0x2B3340

    }

}



# Cached Discord process info

$Script:DiscordInfo = $null

#endregion



#region Logging Functions

function Write-Banner {

    Write-Host "=============================================================" -ForegroundColor Cyan

    Write-Host "                                                             " -ForegroundColor Cyan

    Write-Host "        Discord Voice Quality Patcher v2.4                   " -ForegroundColor Cyan

    Write-Host "        48kHz | 382kbps | Stereo | Configurable Gain        " -ForegroundColor Cyan

    Write-Host "                                                             " -ForegroundColor Cyan

    Write-Host "=============================================================" -ForegroundColor Cyan

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

    

    if ($Script:Config.LogFile) {

        try {

            Add-Content -Path $Script:Config.LogFile -Value $logMessage -ErrorAction SilentlyContinue

        } catch { }

    }

    

    $color = switch ($Level) {

        'Success' { 'Green' }

        'Warning' { 'Yellow' }

        'Error'   { 'Red' }

        default   { 'White' }

    }

    

    $prefix = switch ($Level) {

        'Success' { '[OK]' }

        'Warning' { '[!!]' }

        'Error'   { '[XX]' }

        default   { '[--]' }

    }

    

    Write-Host "$prefix $Message" -ForegroundColor $color

}



function Show-Settings {

    Write-Host "=======================================" -ForegroundColor Cyan

    Write-Host "  Current Patch Configuration" -ForegroundColor Cyan

    Write-Host "=======================================" -ForegroundColor Cyan

    Write-Host "  Sample Rate:    $($Script:Config.SampleRate) Hz" -ForegroundColor White

    Write-Host "  Bitrate:        $($Script:Config.Bitrate) kbps" -ForegroundColor White

    Write-Host "  Channels:       $($Script:Config.Channels)" -ForegroundColor White

    Write-Host "  Audio Gain:     $($Script:Config.AudioGainMultiplier)x" -ForegroundColor $(

        if ($Script:Config.AudioGainMultiplier -le 2) { 'Green' }

        elseif ($Script:Config.AudioGainMultiplier -le 5) { 'Yellow' }

        else { 'Red' }

    )

    Write-Host "=======================================" -ForegroundColor Cyan

    Write-Host ""

}

#endregion



#region Helper Functions

<#

.SYNOPSIS

    Converts user-facing gain multiplier to internal value.

.DESCRIPTION

    Formula: actual_gain = channels + internal_multiplier

    For stereo (2 channels): actual_gain = 2 + (user - 2) = user

    

    Examples:

      User=1  -> Internal=-1 -> Actual=2+(-1)=1 (unity)

      User=2  -> Internal=0  -> Actual=2+0=2

      User=10 -> Internal=8  -> Actual=2+8=10

#>

function Get-InternalMultiplier {

    param([int]$UserMultiplier)

    return $UserMultiplier - 2

}



function Test-Configuration {

    if ($Script:Config.AudioGainMultiplier -lt 1 -or $Script:Config.AudioGainMultiplier -gt 10) {

        throw "Audio gain multiplier must be between 1 and 10"

    }

    return $true

}



function Save-UserConfig {

    try {

        $configData = @{

            LastGainMultiplier = $Script:Config.AudioGainMultiplier

            LastBackupEnabled  = -not $Script:Config.SkipBackup

            LastPatchDate      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        }

        

        $configData | ConvertTo-Json | Out-File $Script:Config.ConfigFile -Force

        Write-Log "Configuration saved" -Level Info

    } catch {

        Write-Log "Failed to save config: $($_.Exception.Message)" -Level Warning

    }

}



function Get-UserConfig {

    try {

        if (Test-Path $Script:Config.ConfigFile) {

            $configData = Get-Content $Script:Config.ConfigFile | ConvertFrom-Json

            Write-Log "Loaded previous configuration" -Level Info

            return $configData

        }

    } catch {

        Write-Log "Could not load config file" -Level Warning

    }

    return $null

}



function Test-FileIntegrity {

    param([string]$FilePath)

    

    if (-not (Test-Path $FilePath)) {

        Write-Log "File not found: $FilePath" -Level Error

        return $false

    }

    

    $fileInfo = Get-Item $FilePath

    $fileSize = $fileInfo.Length

    

    Write-Log "File size: $([Math]::Round($fileSize / 1MB, 2)) MB" -Level Info

    

    if ($fileSize -lt $Script:Config.ExpectedFileSize.Min -or 

        $fileSize -gt $Script:Config.ExpectedFileSize.Max) {

        Write-Log "Warning: File size outside expected range" -Level Warning

        Write-Host "    Expected: $([Math]::Round($Script:Config.ExpectedFileSize.Min / 1MB, 1))-$([Math]::Round($Script:Config.ExpectedFileSize.Max / 1MB, 1)) MB" -ForegroundColor Yellow

        Write-Host "    Actual: $([Math]::Round($fileSize / 1MB, 2)) MB" -ForegroundColor Yellow

        

        $response = Read-Host "    Continue anyway? (y/N)"

        if ($response -notin @('y', 'Y')) {

            return $false

        }

    }

    

    return $true

}

#endregion



#region Discord Process Discovery

function Get-DiscordProcessInfo {

    param([switch]$Force)

    

    if ($Script:DiscordInfo -and -not $Force) {

        return $Script:DiscordInfo

    }

    

    try {

        $process = Get-Process -Name $Script:Config.ProcessBaseName -ErrorAction SilentlyContinue |

            Select-Object -First 1

        

        if (-not $process) {

            $Script:DiscordInfo = $null

            return $null

        }

        

        $voiceModule = $process.Modules | 

            Where-Object { $_.ModuleName -eq $Script:Config.ModuleName } |

            Select-Object -First 1

        

        $versionInfo = $null

        if ($process.Path -and (Test-Path $process.Path)) {

            $versionInfo = (Get-Item $process.Path).VersionInfo

        }

        

        $Script:DiscordInfo = @{

            Process       = $process

            ProcessId     = $process.Id

            Path          = $process.Path

            Version       = if ($versionInfo) { $versionInfo.ProductVersion } else { "Unknown" }

            VoiceNodePath = if ($voiceModule) { $voiceModule.FileName } else { $null }

            IsRunning     = $true

        }

        

        return $Script:DiscordInfo

        

    } catch {

        Write-Log "Error getting Discord process info: $($_.Exception.Message)" -Level Warning

        $Script:DiscordInfo = $null

        return $null

    }

}



function Test-DiscordRunning {

    $info = Get-DiscordProcessInfo -Force

    

    if (-not $info) {

        Write-Log "Discord is not running" -Level Error

        Write-Host "    Please start Discord before running the patcher" -ForegroundColor Yellow

        return $false

    }

    

    Write-Log "Discord is running (PID: $($info.ProcessId))" -Level Success

    return $true

}



function Find-VoiceNodePath {

    $info = Get-DiscordProcessInfo

    

    if (-not $info -or -not $info.VoiceNodePath) {

        return $null

    }

    

    return $info.VoiceNodePath

}

#endregion



#region Backup Management

function Get-BackupList {

    if (-not (Test-Path $Script:Config.BackupDir)) {

        return @()

    }

    

    $backups = Get-ChildItem -Path $Script:Config.BackupDir -Filter "discord_voice.node.*.backup" |

        Sort-Object LastWriteTime -Descending |

        ForEach-Object {

            @{

                Path = $_.FullName

                Date = $_.LastWriteTime

                Size = $_.Length

                Name = $_.Name

            }

        }

    

    return $backups

}



function Show-BackupList {

    $backups = Get-BackupList

    

    if ($backups.Count -eq 0) {

        Write-Host "No backups found" -ForegroundColor Yellow

        return

    }

    

    Write-Host ""

    Write-Host "=======================================================" -ForegroundColor Cyan

    Write-Host "  Available Backups" -ForegroundColor Cyan

    Write-Host "=======================================================" -ForegroundColor Cyan

    

    for ($i = 0; $i -lt $backups.Count; $i++) {

        $backup = $backups[$i]

        $sizeMB = [Math]::Round($backup.Size / 1MB, 2)

        Write-Host "  [$($i+1)] $($backup.Date.ToString('yyyy-MM-dd HH:mm:ss')) - $sizeMB MB" -ForegroundColor White

    }

    

    Write-Host "=======================================================" -ForegroundColor Cyan

    Write-Host ""

}



function Restore-FromBackup {

    param([string]$BackupPath = $null)

    

    Write-Banner

    Write-Log "Starting restore process..." -Level Info

    

    if (-not $BackupPath) {

        $backups = Get-BackupList

        

        if ($backups.Count -eq 0) {

            Write-Log "No backups found" -Level Error

            return $false

        }

        

        Show-BackupList

        

        $selection = Read-Host "Select backup to restore (1-$($backups.Count)) or Enter for most recent"

        

        if ([string]::IsNullOrWhiteSpace($selection)) {

            $BackupPath = $backups[0].Path

            Write-Log "Using most recent backup" -Level Info

        } else {

            $index = 0

            if (-not [int]::TryParse($selection, [ref]$index)) {

                Write-Log "Invalid selection" -Level Error

                return $false

            }

            $index--

            if ($index -lt 0 -or $index -ge $backups.Count) {

                Write-Log "Invalid selection" -Level Error

                return $false

            }

            $BackupPath = $backups[$index].Path

        }

    }

    

    $discordInfo = Get-DiscordProcessInfo -Force

    if (-not $discordInfo) {

        Write-Log "Discord is not running. Please start Discord first." -Level Error

        return $false

    }

    

    $voiceNodePath = $discordInfo.VoiceNodePath

    if (-not $voiceNodePath) {

        Write-Log "Could not find discord_voice.node" -Level Error

        return $false

    }

    

    Write-Log "Target: $voiceNodePath" -Level Info

    Write-Log "Backup: $BackupPath" -Level Info

    

    Write-Host ""

    Write-Host "Warning: This will replace the current discord_voice.node with the backup" -ForegroundColor Yellow

    $confirm = Read-Host "Continue? (y/N)"

    

    if ($confirm -notin @('y', 'Y')) {

        Write-Log "Restore cancelled" -Level Warning

        return $false

    }

    

    Write-Log "Closing Discord..." -Level Info

    try {

        $discordInfo.Process | Stop-Process -Force

        Start-Sleep -Seconds 2

    } catch {

        Write-Log "Failed to close Discord" -Level Error

        return $false

    }

    

    try {

        Copy-Item -Path $BackupPath -Destination $voiceNodePath -Force

        Write-Log "File restored successfully!" -Level Success

        Write-Host ""

        Write-Host "=======================================" -ForegroundColor Green

        Write-Host "  Restore Complete!" -ForegroundColor Green

        Write-Host "=======================================" -ForegroundColor Green

        Write-Host "  You can now restart Discord" -ForegroundColor White

        Write-Host "=======================================" -ForegroundColor Green

        return $true

    } catch {

        Write-Log "Restore failed: $($_.Exception.Message)" -Level Error

        return $false

    }

}



function Backup-VoiceNode {

    param([string]$SourcePath)

    

    if ($Script:Config.SkipBackup) {

        Write-Log "Skipping backup (user requested)" -Level Warning

        return $true

    }

    

    try {

        if (-not (Test-Path $Script:Config.BackupDir)) {

            New-Item -ItemType Directory -Path $Script:Config.BackupDir -Force | Out-Null

        }

        

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

        $backupPath = Join-Path $Script:Config.BackupDir "discord_voice.node.$timestamp.backup"

        

        Copy-Item -Path $SourcePath -Destination $backupPath -Force

        Write-Log "Backup created: $backupPath" -Level Success

        

        $backups = Get-BackupList

        if ($backups.Count -gt $Script:Config.MaxBackupCount) {

            $backups | Select-Object -Skip $Script:Config.MaxBackupCount | ForEach-Object {

                Remove-Item $_.Path -Force

                Write-Log "Removed old backup: $($_.Name)" -Level Info

            }

        }

        

        return $true

    } catch {

        Write-Log "Failed to create backup: $($_.Exception.Message)" -Level Error

        return $false

    }

}

#endregion



#region GUI Functions

function Show-ConfigurationGUI {

    Add-Type -AssemblyName System.Windows.Forms

    Add-Type -AssemblyName System.Drawing

    

    $previousConfig = Get-UserConfig

    $discordInfo = Get-DiscordProcessInfo

    $detectedVersion = if ($discordInfo) { $discordInfo.Version } else { "Not running" }

    

    $form = New-Object System.Windows.Forms.Form

    $form.Text = "Discord Voice Patcher Configuration v2.4"

    $form.ClientSize = New-Object System.Drawing.Size(520, 480)

    $form.StartPosition = "CenterScreen"

    $form.FormBorderStyle = "FixedDialog"

    $form.MaximizeBox = $false

    $form.MinimizeBox = $false

    $form.BackColor = [System.Drawing.Color]::FromArgb(44, 47, 51)

    $form.ForeColor = [System.Drawing.Color]::White

    

    $titleLabel = New-Object System.Windows.Forms.Label

    $titleLabel.Location = New-Object System.Drawing.Point(20, 20)

    $titleLabel.Size = New-Object System.Drawing.Size(480, 30)

    $titleLabel.Text = "Discord Voice Quality Patcher"

    $titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)

    $titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(88, 101, 242)

    $form.Controls.Add($titleLabel)

    

    $subtitleLabel = New-Object System.Windows.Forms.Label

    $subtitleLabel.Location = New-Object System.Drawing.Point(20, 55)

    $subtitleLabel.Size = New-Object System.Drawing.Size(480, 40)

    $subtitleLabel.Text = "48kHz | 382kbps | Stereo | Configurable Gain`nDetected Discord: $detectedVersion"

    $subtitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $subtitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 187, 190)

    $form.Controls.Add($subtitleLabel)

    

    $separator1 = New-Object System.Windows.Forms.Label

    $separator1.Location = New-Object System.Drawing.Point(20, 105)

    $separator1.Size = New-Object System.Drawing.Size(480, 2)

    $separator1.BorderStyle = "Fixed3D"

    $form.Controls.Add($separator1)

    

    $gainLabel = New-Object System.Windows.Forms.Label

    $gainLabel.Location = New-Object System.Drawing.Point(20, 125)

    $gainLabel.Size = New-Object System.Drawing.Size(480, 25)

    $gainLabel.Text = "Audio Gain Multiplier"

    $gainLabel.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)

    $form.Controls.Add($gainLabel)

    

    $valueLabel = New-Object System.Windows.Forms.Label

    $valueLabel.Location = New-Object System.Drawing.Point(20, 160)

    $valueLabel.Size = New-Object System.Drawing.Size(480, 35)

    $valueLabel.Text = "1x (Unity Gain - No Amplification)"

    $valueLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)

    $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(87, 242, 135)

    $valueLabel.TextAlign = "MiddleCenter"

    $form.Controls.Add($valueLabel)

    

    $slider = New-Object System.Windows.Forms.TrackBar

    $slider.Location = New-Object System.Drawing.Point(30, 205)

    $slider.Size = New-Object System.Drawing.Size(460, 45)

    $slider.Minimum = 1

    $slider.Maximum = 10

    $slider.TickFrequency = 1

    

    $initialValue = if ($previousConfig -and $AudioGainMultiplier -eq 1) { 

        $previousConfig.LastGainMultiplier 

    } else { 

        $AudioGainMultiplier 

    }

    $slider.Value = [Math]::Max(1, [Math]::Min(10, $initialValue))

    $slider.BackColor = [System.Drawing.Color]::FromArgb(44, 47, 51)

    

    $slider.Add_ValueChanged({

        $multiplier = $slider.Value

        

        if ($multiplier -eq 1) {

            $valueLabel.Text = "1x (Unity Gain - No Amplification)"

        } else {

            $valueLabel.Text = "${multiplier}x Amplification"

        }

        

        if ($multiplier -le 2) {

            $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(87, 242, 135)

        } elseif ($multiplier -le 5) {

            $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(254, 231, 92)

        } else {

            $valueLabel.ForeColor = [System.Drawing.Color]::FromArgb(237, 66, 69)

        }

    })

    

    # Trigger initial update

    $slider.Value = $slider.Value

    

    $form.Controls.Add($slider)

    

    $scaleLabel = New-Object System.Windows.Forms.Label

    $scaleLabel.Location = New-Object System.Drawing.Point(30, 255)

    $scaleLabel.Size = New-Object System.Drawing.Size(460, 20)

    $scaleLabel.Text = "1x      2x      3x      4x      5x      6x      7x      8x      9x     10x"

    $scaleLabel.Font = New-Object System.Drawing.Font("Consolas", 8)

    $scaleLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 152, 157)

    $form.Controls.Add($scaleLabel)

    

    $infoLabel = New-Object System.Windows.Forms.Label

    $infoLabel.Location = New-Object System.Drawing.Point(20, 285)

    $infoLabel.Size = New-Object System.Drawing.Size(480, 40)

    $infoLabel.Text = "Warning: Recommended 1-2x for most users`nValues above 5x may cause severe distortion and clipping"

    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $infoLabel.ForeColor = [System.Drawing.Color]::FromArgb(185, 187, 190)

    $form.Controls.Add($infoLabel)

    

    $separator2 = New-Object System.Windows.Forms.Label

    $separator2.Location = New-Object System.Drawing.Point(20, 330)

    $separator2.Size = New-Object System.Drawing.Size(480, 2)

    $separator2.BorderStyle = "Fixed3D"

    $form.Controls.Add($separator2)

    

    $backupCheckbox = New-Object System.Windows.Forms.CheckBox

    $backupCheckbox.Location = New-Object System.Drawing.Point(20, 342)

    $backupCheckbox.Size = New-Object System.Drawing.Size(480, 25)

    $backupCheckbox.Text = "Create backup before patching (Strongly Recommended)"

    $backupCheckbox.Checked = if ($previousConfig) { 

        $previousConfig.LastBackupEnabled 

    } else { 

        -not $Script:Config.SkipBackup 

    }

    $backupCheckbox.ForeColor = [System.Drawing.Color]::White

    $backupCheckbox.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $form.Controls.Add($backupCheckbox)

    

    if ($previousConfig) {

        $historyLabel = New-Object System.Windows.Forms.Label

        $historyLabel.Location = New-Object System.Drawing.Point(20, 370)

        $historyLabel.Size = New-Object System.Drawing.Size(480, 20)

        $historyLabel.Text = "Last patched: $($previousConfig.LastPatchDate) with $($previousConfig.LastGainMultiplier)x gain"

        $historyLabel.Font = New-Object System.Drawing.Font("Segoe UI", 8)

        $historyLabel.ForeColor = [System.Drawing.Color]::FromArgb(150, 152, 157)

        $form.Controls.Add($historyLabel)

    }

    

    $restoreButton = New-Object System.Windows.Forms.Button

    $restoreButton.Location = New-Object System.Drawing.Point(20, 425)

    $restoreButton.Size = New-Object System.Drawing.Size(90, 35)

    $restoreButton.Text = "Restore"

    $restoreButton.BackColor = [System.Drawing.Color]::FromArgb(79, 84, 92)

    $restoreButton.ForeColor = [System.Drawing.Color]::White

    $restoreButton.FlatStyle = "Flat"

    $restoreButton.Font = New-Object System.Drawing.Font("Segoe UI", 10)

    $restoreButton.Cursor = [System.Windows.Forms.Cursors]::Hand

    $restoreButton.Add_Click({

        $form.Hide()

        Restore-FromBackup

        Read-Host "Press Enter to continue"

        $form.Close()

    })

    $form.Controls.Add($restoreButton)

    

    $patchButton = New-Object System.Windows.Forms.Button

    $patchButton.Location = New-Object System.Drawing.Point(300, 425)

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

    

    $cancelButton = New-Object System.Windows.Forms.Button

    $cancelButton.Location = New-Object System.Drawing.Point(410, 425)

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

    

    try {

        $result = $form.ShowDialog()

        

        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {

            return $form.Tag

        }

        

        return $null

    } finally {

        $form.Dispose()

    }

}

#endregion



#region Environment Functions

function Initialize-Environment {

    Write-Log "Initializing environment..." -Level Info

    

    @($Script:Config.TempDir, $Script:Config.BackupDir) | ForEach-Object {

        if (-not (Test-Path $_)) {

            New-Item -ItemType Directory -Path $_ -Force | Out-Null

            Write-Log "Created directory: $_" -Level Info

        }

    }

    

    try {

        $discordVersion = if ($Script:DiscordInfo) { $Script:DiscordInfo.Version } else { "Unknown" }

        $logHeader = @"

=======================================

Discord Voice Patcher Log v2.4

=======================================

Started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Settings: $($Script:Config.AudioGainMultiplier)x gain, $($Script:Config.SampleRate)Hz, $($Script:Config.Bitrate)kbps

Discord Version: $discordVersion

=======================================



"@

        $logHeader | Out-File $Script:Config.LogFile -Force

    } catch {

        Write-Log "Could not create log file" -Level Warning

    }

}

#endregion



#region Compiler Functions

function Find-Compiler {

    Write-Log "Searching for C++ compiler..." -Level Info

    

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

        } catch { }

    }

    

    $gpp = Get-Command "g++" -ErrorAction SilentlyContinue

    if ($gpp) {

        Write-Log "Found MinGW g++" -Level Success

        return @{ Type = 'MinGW'; Path = $gpp.Source }

    }

    

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

    Write-Host "=======================================================" -ForegroundColor Yellow

    Write-Host "  No C++ Compiler Found" -ForegroundColor Yellow

    Write-Host "=======================================================" -ForegroundColor Yellow

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

    # Calculate internal multiplier

    # Formula: actual_gain = channels + MULTIPLIER

    # For stereo (2ch): actual = 2 + (UserGain - 2) = UserGain

    $internalMultiplier = Get-InternalMultiplier -UserMultiplier $Script:Config.AudioGainMultiplier

    

    $code = @"

#define MULTIPLIER $internalMultiplier

#define STEREO_CHANNELS 2



struct VoiceStateOffsets {

    static constexpr int BASE_OFFSET = -3553;

    static constexpr int FLAG_OFFSET = 3557;

    static constexpr int FILTER_STATE_1 = 160;

    static constexpr int FILTER_STATE_2 = 164;

    static constexpr int FILTER_STATE_3 = 184;

    static constexpr int FLAG_VALUE = 1002;

};



inline void InitializeVoiceState(int* hp_mem) {

    int* state_base = hp_mem + VoiceStateOffsets::BASE_OFFSET;

    *(state_base + VoiceStateOffsets::FLAG_OFFSET) = VoiceStateOffsets::FLAG_VALUE;

    *(int*)((char*)state_base + VoiceStateOffsets::FILTER_STATE_1) = -1;

    *(int*)((char*)state_base + VoiceStateOffsets::FILTER_STATE_2) = -1;

    *(int*)((char*)state_base + VoiceStateOffsets::FILTER_STATE_3) = 0;

}



inline void ApplyAudioGain(const float* in, float* out, int sample_count, int channels) {

    const float gain = static_cast<float>(channels + MULTIPLIER);

    for (int i = 0; i < sample_count; i++) {

        out[i] = in[i] * gain;

    }

}



extern "C" void __cdecl hp_cutoff(

    const float* in, int cutoff_Hz, float* out, int* hp_mem,

    int len, int channels, int Fs, int arch)

{

    InitializeVoiceState(hp_mem);

    ApplyAudioGain(in, out, channels * len, channels);

}



extern "C" void __cdecl dc_reject(

    const float* in, float* out, int* hp_mem,

    int len, int channels, int Fs)

{

    InitializeVoiceState(hp_mem);

    ApplyAudioGain(in, out, channels * len, channels);

}

"@

    

    return $code

}



function Get-PatcherSourceCode {

    $offsets = $Script:Config.Offsets

    

    $code = @"

#include <windows.h>

#include <tlhelp32.h>

#include <psapi.h>

#include <iostream>

#include <string>



#define DISCORD_VERSION $($Script:Config.DiscordVersion)

#define SAMPLE_RATE $($Script:Config.SampleRate)

#define BITRATE $($Script:Config.Bitrate)

#define AUDIO_GAIN $($Script:Config.AudioGainMultiplier)



extern "C" void dc_reject(const float*, float*, int*, int, int, int);

extern "C" void hp_cutoff(const float*, int, float*, int*, int, int, int, int);



namespace Offsets {

    constexpr uint32_t CreateAudioFrameStereo = $('0x{0:X}' -f $offsets.CreateAudioFrameStereo);

    constexpr uint32_t AudioEncoderOpusConfigSetChannels = $('0x{0:X}' -f $offsets.AudioEncoderOpusConfigSetChannels);

    constexpr uint32_t MonoDownmixer = $('0x{0:X}' -f $offsets.MonoDownmixer);

    constexpr uint32_t EmulateStereoSuccess1 = $('0x{0:X}' -f $offsets.EmulateStereoSuccess1);

    constexpr uint32_t EmulateStereoSuccess2 = $('0x{0:X}' -f $offsets.EmulateStereoSuccess2);

    constexpr uint32_t EmulateBitrateModified = $('0x{0:X}' -f $offsets.EmulateBitrateModified);

    constexpr uint32_t SetsBitrateBitrateValue = $('0x{0:X}' -f $offsets.SetsBitrateBitrateValue);

    constexpr uint32_t SetsBitrateBitwiseOr = $('0x{0:X}' -f $offsets.SetsBitrateBitwiseOr);

    constexpr uint32_t Emulate48Khz = $('0x{0:X}' -f $offsets.Emulate48Khz);

    constexpr uint32_t HighPassFilter = $('0x{0:X}' -f $offsets.HighPassFilter);

    constexpr uint32_t HighpassCutoffFilter = $('0x{0:X}' -f $offsets.HighpassCutoffFilter);

    constexpr uint32_t DcReject = $('0x{0:X}' -f $offsets.DcReject);

    constexpr uint32_t DownmixFunc = $('0x{0:X}' -f $offsets.DownmixFunc);

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

        

        printf("  [1/4] Enabling stereo audio...\n");

        PatchBytes(Offsets::EmulateStereoSuccess1, "\x02", 1);

        PatchBytes(Offsets::EmulateStereoSuccess2, "\xEB", 1);

        PatchBytes(Offsets::CreateAudioFrameStereo, "\x49\x89\xC5\x90", 4);

        PatchBytes(Offsets::AudioEncoderOpusConfigSetChannels, "\x02", 1);

        PatchBytes(Offsets::MonoDownmixer, "\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\xE9", 13);

        

        printf("  [2/4] Setting bitrate to 382kbps...\n");

        PatchBytes(Offsets::EmulateBitrateModified, "\x90\xD4\x05", 3);

        PatchBytes(Offsets::SetsBitrateBitrateValue, "\x90\xD4\x05\x00\x00", 5);

        PatchBytes(Offsets::SetsBitrateBitwiseOr, "\x90\x90\x90", 3);

        

        printf("  [3/4] Enabling 48kHz sample rate...\n");

        PatchBytes(Offsets::Emulate48Khz, "\x90\x90\x90", 3);

        

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

        printf("  Discord Voice Quality Patcher v2.4\n");

        printf("================================================\n");

        printf("  Target:  %s\n", modulePath.c_str());

        printf("  Version: %d\n", DISCORD_VERSION);

        printf("  Config:  %dkHz, %dkbps, Stereo, %dx gain\n", 

               SAMPLE_RATE/1000, BITRATE, AUDIO_GAIN);

        printf("================================================\n\n");

        

        TerminateProcess(process, 0);

        if (!WaitForDiscordClose()) {

            TerminateAllDiscordProcesses();

            Sleep(500);

        }

        

        printf("Opening file for patching...\n");

        HANDLE file = CreateFileA(modulePath.c_str(), GENERIC_READ | GENERIC_WRITE,

                                  0, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);

        

        if (file == INVALID_HANDLE_VALUE) {

            printf("ERROR: Cannot open file (Error: %d)\n", GetLastError());

            printf("Make sure you're running as Administrator\n");

            return false;

        }

        

        LARGE_INTEGER fileSize;

        if (!GetFileSizeEx(file, &fileSize)) {

            printf("ERROR: Cannot get file size\n");

            CloseHandle(file);

            return false;

        }

        

        printf("File size: %lld bytes\n", fileSize.QuadPart);

        

        void* fileData = VirtualAlloc(nullptr, fileSize.QuadPart, 

                                      MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);

        if (!fileData) {

            printf("ERROR: Cannot allocate memory\n");

            CloseHandle(file);

            return false;

        }

        

        DWORD bytesRead;

        if (!ReadFile(file, fileData, fileSize.QuadPart, &bytesRead, NULL)) {

            printf("ERROR: Cannot read file\n");

            VirtualFree(fileData, 0, MEM_RELEASE);

            CloseHandle(file);

            return false;

        }

        

        if (!ApplyPatches(fileData)) {

            VirtualFree(fileData, 0, MEM_RELEASE);

            CloseHandle(file);

            return false;

        }

        

        printf("\nWriting patched file...\n");

        SetFilePointer(file, 0, NULL, FILE_BEGIN);

        DWORD bytesWritten;

        if (!WriteFile(file, fileData, fileSize.QuadPart, &bytesWritten, NULL)) {

            printf("ERROR: Cannot write file (Error: %d)\n", GetLastError());

            VirtualFree(fileData, 0, MEM_RELEASE);

            CloseHandle(file);

            return false;

        }

        

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

    SetConsoleTitle("Discord Voice Patcher v2.4");

    

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

    

    return $code

}



function New-SourceFiles {

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

    Write-Banner

    

    if ($ListBackups) {

        Show-BackupList

        return $true

    }

    

    if ($Restore) {

        $result = Restore-FromBackup

        return $result

    }

    

    if (-not $NoGUI) {

        Write-Log "Opening configuration GUI..." -Level Info

        Write-Host ""

        

        $guiResult = Show-ConfigurationGUI

        

        if ($null -eq $guiResult) {

            Write-Log "User cancelled operation" -Level Warning

            return $false

        }

        

        $Script:Config.AudioGainMultiplier = $guiResult.Multiplier

        $Script:Config.SkipBackup = $guiResult.SkipBackup

        

        Write-Host ""

    }

    

    try {

        Test-Configuration | Out-Null

    } catch {

        Write-Log "Invalid configuration: $($_.Exception.Message)" -Level Error

        return $false

    }

    

    Show-Settings

    

    Initialize-Environment

    

    if (-not (Test-DiscordRunning)) {

        Read-Host "Press Enter to exit"

        return $false

    }

    

    $voiceNodePath = Find-VoiceNodePath

    if (-not $voiceNodePath) {

        Write-Log "Could not find discord_voice.node" -Level Error

        Read-Host "Press Enter to exit"

        return $false

    }

    

    Write-Log "Found voice node: $voiceNodePath" -Level Success

    

    if (-not (Test-FileIntegrity -FilePath $voiceNodePath)) {

        Read-Host "Press Enter to exit"

        return $false

    }

    

    if (-not (Backup-VoiceNode -SourcePath $voiceNodePath)) {

        if (-not $Script:Config.SkipBackup) {

            Read-Host "Press Enter to exit"

            return $false

        }

    }

    

    $compiler = Find-Compiler

    if (-not $compiler) {

        Read-Host "Press Enter to exit"

        return $false

    }

    

    $sourceFiles = New-SourceFiles

    if (-not $sourceFiles) {

        Read-Host "Press Enter to exit"

        return $false

    }

    

    $executable = Invoke-Compilation -Compiler $compiler -SourceFiles $sourceFiles

    if (-not $executable) {

        Read-Host "Press Enter to exit"

        return $false

    }

    

    Save-UserConfig

    

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



try {

    $success = Start-Patching

    

    Write-Host ""

    if ($success) {

        Write-Host "=======================================" -ForegroundColor Green

        Write-Host "  Patching completed successfully!" -ForegroundColor Green

        Write-Host "=======================================" -ForegroundColor Green

    } else {

        Write-Host "=======================================" -ForegroundColor Red

        Write-Host "  Patching failed or was cancelled" -ForegroundColor Red

        Write-Host "=======================================" -ForegroundColor Red

    }

    Write-Host ""

    

    Read-Host "Press Enter to exit"

    if ($success) { exit 0 } else { exit 1 }

    

} catch {

    Write-Host ""

    Write-Host "=======================================" -ForegroundColor Red

    Write-Host "  FATAL ERROR" -ForegroundColor Red

    Write-Host "=======================================" -ForegroundColor Red

    Write-Log "Unhandled error: $($_.Exception.Message)" -Level Error

    Write-Host ""

    Write-Host $_.ScriptStackTrace -ForegroundColor Red

    Write-Host ""

    Read-Host "Press Enter to exit"

    exit 1

}

#endregion
