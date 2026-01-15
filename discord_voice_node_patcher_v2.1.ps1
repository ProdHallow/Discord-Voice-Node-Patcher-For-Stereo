<#
.SYNOPSIS
    Discord Voice Quality Patcher v2.5 - Patches Discord for high-quality audio (48kHz/382kbps/Stereo)
.PARAMETER AudioGainMultiplier
    Audio gain multiplier (1-10). Default is 1 (unity gain)
.PARAMETER SkipBackup
    Skip creating a backup of the original file
.PARAMETER NoGUI
    Skip GUI and use command-line parameters
.PARAMETER Restore
    Restore from most recent backup
.PARAMETER ListBackups
    List all available backups
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 10)][int]$AudioGainMultiplier = 1,
    [switch]$SkipBackup,
    [switch]$NoGUI,
    [switch]$Restore,
    [switch]$ListBackups
)

$ErrorActionPreference = "Stop"

#region Auto-Elevation
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
    try {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        if ($PSBoundParameters.ContainsKey('AudioGainMultiplier')) { $arguments += "-AudioGainMultiplier", $AudioGainMultiplier }
        if ($SkipBackup) { $arguments += "-SkipBackup" }
        if ($NoGUI) { $arguments += "-NoGUI" }
        if ($Restore) { $arguments += "-Restore" }
        if ($ListBackups) { $arguments += "-ListBackups" }
        Start-Process powershell.exe -ArgumentList $arguments -Verb RunAs
        exit 0
    } catch {
        Write-Host "ERROR: Failed to elevate. Please run as Administrator manually." -ForegroundColor Red
        Read-Host "Press Enter to exit"; exit 1
    }
}
#endregion

#region Configuration
$Script:GainExplicitlySet = $PSBoundParameters.ContainsKey('AudioGainMultiplier')
$Script:Config = @{
    SampleRate = 48000; Bitrate = 382; Channels = "Stereo"
    AudioGainMultiplier = $AudioGainMultiplier; SkipBackup = $SkipBackup.IsPresent
    DiscordVersion = 9219; DiscordVersionPattern = "^1\.0\.92"
    ProcessName = "Discord.exe"; ProcessBaseName = "Discord"; ModuleName = "discord_voice.node"
    TempDir = "$env:TEMP\DiscordVoicePatcher"; BackupDir = "$env:TEMP\DiscordVoicePatcher\Backups"
    LogFile = "$env:TEMP\DiscordVoicePatcher\patcher.log"; ConfigFile = "$env:TEMP\DiscordVoicePatcher\config.json"
    MaxBackupCount = 10; ExpectedFileSize = @{ Min = 14000000; Max = 18000000 }
    Offsets = @{
        CreateAudioFrameStereo = 0x116C91; AudioEncoderOpusConfigSetChannels = 0x3A0B64
        MonoDownmixer = 0xD6319; EmulateStereoSuccess1 = 0x520CFB; EmulateStereoSuccess2 = 0x520D07
        EmulateBitrateModified = 0x52115A; SetsBitrateBitrateValue = 0x522F81; SetsBitrateBitwiseOr = 0x522F89
        Emulate48Khz = 0x520E63; HighPassFilter = 0x52CF70; HighpassCutoffFilter = 0x8D64B0
        DcReject = 0x8D6690; DownmixFunc = 0x8D2820; AudioEncoderOpusConfigIsOk = 0x3A0E00; ThrowError = 0x2B3340
    }
}
$Script:DiscordInfo = $null
#endregion

#region Logging
function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Info','Success','Warning','Error')][string]$Level = 'Info')
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $Script:Config.LogFile -Value "[$timestamp] [$Level] $Message" -ErrorAction SilentlyContinue
    $colors = @{ Success = 'Green'; Warning = 'Yellow'; Error = 'Red'; Info = 'White' }
    $prefixes = @{ Success = '[OK]'; Warning = '[!!]'; Error = '[XX]'; Info = '[--]' }
    Write-Host "$($prefixes[$Level]) $Message" -ForegroundColor $colors[$Level]
}

function Write-Banner {
    Write-Host "`n===== Discord Voice Quality Patcher v2.5 =====" -ForegroundColor Cyan
    Write-Host "     48kHz | 382kbps | Stereo | Gain Config" -ForegroundColor Cyan
    Write-Host "=============================================`n" -ForegroundColor Cyan
}

function Show-Settings {
    $gainColor = if ($Script:Config.AudioGainMultiplier -le 2) { 'Green' } elseif ($Script:Config.AudioGainMultiplier -le 5) { 'Yellow' } else { 'Red' }
    Write-Host "Config: $($Script:Config.SampleRate)Hz, $($Script:Config.Bitrate)kbps, $($Script:Config.Channels), " -NoNewline
    Write-Host "$($Script:Config.AudioGainMultiplier)x gain" -ForegroundColor $gainColor
    Write-Host ""
}
#endregion

#region Helpers
function Save-UserConfig {
    try {
        @{ LastGainMultiplier = $Script:Config.AudioGainMultiplier; LastBackupEnabled = -not $Script:Config.SkipBackup
           LastPatchDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss" } | ConvertTo-Json | Out-File $Script:Config.ConfigFile -Force
    } catch { Write-Log "Failed to save config: $_" -Level Warning }
}

function Get-UserConfig {
    try {
        if (Test-Path $Script:Config.ConfigFile) {
            $content = Get-Content $Script:Config.ConfigFile -Raw
            if ([string]::IsNullOrWhiteSpace($content)) { throw "Empty" }
            $cfg = $content | ConvertFrom-Json
            if (-not $cfg.PSObject.Properties['LastGainMultiplier']) { throw "Invalid" }
            return $cfg
        }
    } catch { Remove-Item $Script:Config.ConfigFile -Force -ErrorAction SilentlyContinue }
    return $null
}

function Test-FileIntegrity {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { Write-Log "File not found: $FilePath" -Level Error; return $false }
    $size = (Get-Item $FilePath).Length
    Write-Log "File size: $([Math]::Round($size / 1MB, 2)) MB" -Level Info
    if ($size -lt $Script:Config.ExpectedFileSize.Min -or $size -gt $Script:Config.ExpectedFileSize.Max) {
        Write-Log "Warning: File size outside expected range" -Level Warning
        if ((Read-Host "Continue anyway? (y/N)") -notin @('y', 'Y')) { return $false }
    }
    return $true
}

function Test-DiscordVersionCompatibility {
    param([string]$Version)
    if ([string]::IsNullOrEmpty($Version) -or $Version -eq "Unknown") { return $true }
    if ($Version -notmatch $Script:Config.DiscordVersionPattern) {
        Write-Log "Discord version '$Version' may not be compatible (expected ~$($Script:Config.DiscordVersion))" -Level Warning
        if ((Read-Host "Continue anyway? (y/N)") -notin @('y', 'Y')) { return $false }
    }
    return $true
}
#endregion

#region Discord Process
function Get-DiscordProcessInfo {
    param([switch]$Force)
    if ($Script:DiscordInfo -and -not $Force) { return $Script:DiscordInfo }
    try {
        $proc = Get-Process -Name $Script:Config.ProcessBaseName -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $proc) { $Script:DiscordInfo = $null; return $null }
        $voiceMod = $proc.Modules | Where-Object { $_.ModuleName -eq $Script:Config.ModuleName } | Select-Object -First 1
        $ver = if ($proc.Path -and (Test-Path $proc.Path)) { (Get-Item $proc.Path).VersionInfo.ProductVersion } else { "Unknown" }
        $Script:DiscordInfo = @{ Process = $proc; ProcessId = $proc.Id; Path = $proc.Path; Version = $ver
                                 VoiceNodePath = $(if ($voiceMod) { $voiceMod.FileName } else { $null }); IsRunning = $true }
        return $Script:DiscordInfo
    } catch { $Script:DiscordInfo = $null; return $null }
}

function Test-DiscordRunning {
    $info = Get-DiscordProcessInfo -Force
    if (-not $info) { Write-Log "Discord is not running. Please start Discord first." -Level Error; return $false }
    Write-Log "Discord running (PID: $($info.ProcessId))" -Level Success
    return $true
}
#endregion

#region Backup
function Get-BackupList {
    if (-not (Test-Path $Script:Config.BackupDir)) { return @() }
    Get-ChildItem $Script:Config.BackupDir -Filter "discord_voice.node.*.backup" | Sort-Object LastWriteTime -Descending |
        ForEach-Object { @{ Path = $_.FullName; Date = $_.LastWriteTime; Size = $_.Length; Name = $_.Name } }
}

function Show-BackupList {
    $backups = Get-BackupList
    if ($backups.Count -eq 0) { Write-Host "No backups found" -ForegroundColor Yellow; return }
    Write-Host "`n=== Available Backups ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $backups.Count; $i++) {
        Write-Host "  [$($i+1)] $($backups[$i].Date.ToString('yyyy-MM-dd HH:mm:ss')) - $([Math]::Round($backups[$i].Size / 1MB, 2)) MB"
    }
    Write-Host ""
}

function Restore-FromBackup {
    param([string]$BackupPath = $null)
    Write-Banner; Write-Log "Starting restore..." -Level Info
    if (-not $BackupPath) {
        $backups = Get-BackupList
        if ($backups.Count -eq 0) { Write-Log "No backups found" -Level Error; return $false }
        Show-BackupList
        $sel = Read-Host "Select backup (1-$($backups.Count)) or Enter for most recent"
        if ([string]::IsNullOrWhiteSpace($sel)) { $BackupPath = $backups[0].Path }
        else {
            $idx = 0; if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $backups.Count) {
                Write-Log "Invalid selection" -Level Error; return $false
            }
            $BackupPath = $backups[$idx - 1].Path
        }
    }
    $info = Get-DiscordProcessInfo -Force
    if (-not $info -or -not $info.VoiceNodePath) { Write-Log "Discord not running or voice node not found" -Level Error; return $false }
    Write-Log "Target: $($info.VoiceNodePath)" -Level Info
    if ((Read-Host "Replace current file with backup? (y/N)") -notin @('y', 'Y')) { return $false }
    try {
        $info.Process | Stop-Process -Force; Start-Sleep -Seconds 2
        Copy-Item -Path $BackupPath -Destination $info.VoiceNodePath -Force
        Write-Log "Restore complete! Restart Discord." -Level Success; return $true
    } catch { Write-Log "Restore failed: $_" -Level Error; return $false }
}

function Backup-VoiceNode {
    param([string]$SourcePath)
    if ($Script:Config.SkipBackup) { Write-Log "Skipping backup" -Level Warning; return $true }
    try {
        if (-not (Test-Path $Script:Config.BackupDir)) { New-Item -ItemType Directory -Path $Script:Config.BackupDir -Force | Out-Null }
        $backupPath = Join-Path $Script:Config.BackupDir "discord_voice.node.$(Get-Date -Format 'yyyyMMdd_HHmmss').backup"
        Copy-Item -Path $SourcePath -Destination $backupPath -Force
        Write-Log "Backup created" -Level Success
        $backups = Get-BackupList
        if ($backups.Count -gt $Script:Config.MaxBackupCount) {
            $backups | Select-Object -Skip $Script:Config.MaxBackupCount | ForEach-Object { Remove-Item $_.Path -Force }
        }
        return $true
    } catch { Write-Log "Backup failed: $_" -Level Error; return $false }
}
#endregion

#region GUI
function Show-ConfigurationGUI {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $prevCfg = Get-UserConfig
    $discordInfo = Get-DiscordProcessInfo
    $initGain = if ($prevCfg -and -not $Script:GainExplicitlySet) { [Math]::Max(1, [Math]::Min(10, $prevCfg.LastGainMultiplier)) } else { $Script:Config.AudioGainMultiplier }

    $form = New-Object Windows.Forms.Form -Property @{
        Text = "Discord Voice Patcher v2.5"; ClientSize = "520,450"; StartPosition = "CenterScreen"
        FormBorderStyle = "FixedDialog"; MaximizeBox = $false; MinimizeBox = $false
        BackColor = [Drawing.Color]::FromArgb(44,47,51); ForeColor = [Drawing.Color]::White
    }

    $newLabel = { param($x, $y, $w, $h, $text, $font, $color)
        $l = New-Object Windows.Forms.Label -Property @{ Location = "$x,$y"; Size = "$w,$h"; Text = $text }
        if ($font) { $l.Font = $font }
        if ($color) { $l.ForeColor = $color }
        $form.Controls.Add($l); $l
    }

    & $newLabel 20 20 480 30 "Discord Voice Quality Patcher" (New-Object Drawing.Font("Segoe UI", 16, [Drawing.FontStyle]::Bold)) ([Drawing.Color]::FromArgb(88,101,242))
    & $newLabel 20 55 480 35 "48kHz | 382kbps | Stereo`nDetected: $(if ($discordInfo) { $discordInfo.Version } else { 'Not running' })" (New-Object Drawing.Font("Segoe UI", 9)) ([Drawing.Color]::FromArgb(185,187,190))
    & $newLabel 20 105 480 25 "Audio Gain Multiplier" (New-Object Drawing.Font("Segoe UI", 12, [Drawing.FontStyle]::Bold)) $null

    $valueLabel = & $newLabel 20 135 480 30 "" (New-Object Drawing.Font("Segoe UI", 14, [Drawing.FontStyle]::Bold)) $null
    $valueLabel.TextAlign = [Drawing.ContentAlignment]::MiddleCenter

    $updateLabel = {
        param([int]$m)
        $valueLabel.Text = if ($m -eq 1) { "1x (Unity Gain)" } else { "${m}x Amplification" }
        $valueLabel.ForeColor = [Drawing.Color]::FromArgb($(if ($m -le 2) { "87,242,135" } elseif ($m -le 5) { "254,231,92" } else { "237,66,69" }))
    }

    $slider = New-Object Windows.Forms.TrackBar -Property @{
        Location = "30,175"; Size = "460,45"; Minimum = 1; Maximum = 10; TickFrequency = 1
        BackColor = [Drawing.Color]::FromArgb(44,47,51); Value = $initGain
    }
    $slider.Add_ValueChanged({ & $updateLabel $slider.Value })
    $form.Controls.Add($slider)
    & $updateLabel $initGain

    & $newLabel 30 225 460 20 "1x      2x      3x      4x      5x      6x      7x      8x      9x     10x" (New-Object Drawing.Font("Consolas", 8)) ([Drawing.Color]::FromArgb(150,152,157))
    & $newLabel 20 250 480 35 "Recommended: 1-2x. Values >5x may cause distortion." (New-Object Drawing.Font("Segoe UI", 9)) ([Drawing.Color]::FromArgb(185,187,190))

    $chk = New-Object Windows.Forms.CheckBox -Property @{
        Location = "20,295"; Size = "480,25"; Text = "Create backup before patching (Recommended)"
        Checked = $(if ($prevCfg) { $prevCfg.LastBackupEnabled } else { -not $Script:Config.SkipBackup })
        ForeColor = [Drawing.Color]::White; Font = New-Object Drawing.Font("Segoe UI", 9)
    }
    $form.Controls.Add($chk)

    if ($prevCfg.LastPatchDate) {
        & $newLabel 20 325 480 20 "Last: $($prevCfg.LastPatchDate) @ $($prevCfg.LastGainMultiplier)x" (New-Object Drawing.Font("Segoe UI", 8)) ([Drawing.Color]::FromArgb(150,152,157))
    }

    $btnStyle = { param($x, $text, $bg, $bold, $action)
        $b = New-Object Windows.Forms.Button -Property @{
            Location = "$x,390"; Size = "100,35"; Text = $text; FlatStyle = "Flat"
            BackColor = [Drawing.Color]::FromArgb($bg); ForeColor = [Drawing.Color]::White
            Font = New-Object Drawing.Font("Segoe UI", 10, $(if ($bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
            Cursor = [Windows.Forms.Cursors]::Hand
        }
        $b.Add_Click($action); $form.Controls.Add($b); $b
    }

    & $btnStyle 20 "Restore" "79,84,92" $false { $form.Tag = @{ Action = 'Restore' }; $form.DialogResult = "Abort"; $form.Close() }
    $patchBtn = & $btnStyle 290 "Patch" "88,101,242" $true { $form.Tag = @{ Action = 'Patch'; Multiplier = $slider.Value; SkipBackup = -not $chk.Checked }; $form.DialogResult = "OK"; $form.Close() }
    $cancelBtn = & $btnStyle 400 "Cancel" "79,84,92" $false { $form.DialogResult = "Cancel"; $form.Close() }

    $form.AcceptButton = $patchBtn; $form.CancelButton = $cancelBtn
    try { $null = $form.ShowDialog(); return $form.Tag } finally { $form.Dispose() }
}
#endregion

#region Environment & Compiler
function Initialize-Environment {
    @($Script:Config.TempDir, $Script:Config.BackupDir) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
    "=== Discord Voice Patcher Log ===`nStarted: $(Get-Date)`nGain: $($Script:Config.AudioGainMultiplier)x`n" | Out-File $Script:Config.LogFile -Force -ErrorAction SilentlyContinue
}

function Find-Compiler {
    Write-Log "Searching for C++ compiler..." -Level Info
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        try {
            $vsPath = & $vsWhere -latest -property installationPath 2>$null
            $vcvars = "$vsPath\VC\Auxiliary\Build\vcvars64.bat"
            if ($vsPath -and (Test-Path $vcvars)) { Write-Log "Found Visual Studio" -Level Success; return @{ Type = 'MSVC'; Path = $vcvars } }
        } catch { }
    }
    $gpp = Get-Command "g++" -ErrorAction SilentlyContinue
    if ($gpp) { Write-Log "Found MinGW g++" -Level Success; return @{ Type = 'MinGW'; Path = $gpp.Source } }
    $clang = Get-Command "clang++" -ErrorAction SilentlyContinue
    if ($clang) { Write-Log "Found Clang" -Level Success; return @{ Type = 'Clang'; Path = $clang.Source } }
    Write-Log "No C++ compiler found. Install Visual Studio, MinGW, or Clang." -Level Error
    return $null
}
#endregion

#region Source Code
function Get-AmplifierSourceCode {
    $m = $Script:Config.AudioGainMultiplier - 2
@"
#define MULTIPLIER $m
struct VS { static constexpr int B=-3553,F=3557,S1=160,S2=164,S3=184,V=1002; };
inline void Init(int* p) { int* s=p+VS::B; *(s+VS::F)=VS::V; *(int*)((char*)s+VS::S1)=-1; *(int*)((char*)s+VS::S2)=-1; *(int*)((char*)s+VS::S3)=0; }
inline void Gain(const float* i, float* o, int n, int c) { float g=(float)(c+MULTIPLIER); for(int x=0;x<n;x++) o[x]=i[x]*g; }
extern "C" void __cdecl hp_cutoff(const float* i,int,float* o,int* m,int l,int c,int,int) { Init(m); Gain(i,o,c*l,c); }
extern "C" void __cdecl dc_reject(const float* i,float* o,int* m,int l,int c,int) { Init(m); Gain(i,o,c*l,c); }
"@
}

function Get-PatcherSourceCode {
    $o = $Script:Config.Offsets; $c = $Script:Config
@"
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <cstdio>
#include <cstring>
#define VER $($c.DiscordVersion)
#define SR $($c.SampleRate)
#define BR $($c.Bitrate)
#define AG $($c.AudioGainMultiplier)
extern "C" void dc_reject(const float*,float*,int*,int,int,int);
extern "C" void hp_cutoff(const float*,int,float*,int*,int,int,int,int);
namespace O {
    constexpr uint32_t CAFS=$('0x{0:X}' -f $o.CreateAudioFrameStereo),AEOCS=$('0x{0:X}' -f $o.AudioEncoderOpusConfigSetChannels);
    constexpr uint32_t MD=$('0x{0:X}' -f $o.MonoDownmixer),ESS1=$('0x{0:X}' -f $o.EmulateStereoSuccess1),ESS2=$('0x{0:X}' -f $o.EmulateStereoSuccess2);
    constexpr uint32_t EBM=$('0x{0:X}' -f $o.EmulateBitrateModified),SBBV=$('0x{0:X}' -f $o.SetsBitrateBitrateValue),SBBO=$('0x{0:X}' -f $o.SetsBitrateBitwiseOr);
    constexpr uint32_t E48=$('0x{0:X}' -f $o.Emulate48Khz),HPF=$('0x{0:X}' -f $o.HighPassFilter),HPCF=$('0x{0:X}' -f $o.HighpassCutoffFilter);
    constexpr uint32_t DCR=$('0x{0:X}' -f $o.DcReject),DMF=$('0x{0:X}' -f $o.DownmixFunc),AEOK=$('0x{0:X}' -f $o.AudioEncoderOpusConfigIsOk),TE=$('0x{0:X}' -f $o.ThrowError);
    constexpr uint32_t ADJ=0xC00;
};
class P {
    HANDLE proc; std::string path;
    void Kill() { HANDLE s=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0); if(s==INVALID_HANDLE_VALUE)return;
        PROCESSENTRY32 e={sizeof(e)}; while(Process32Next(s,&e)) if(!strcmp(e.szExeFile,"$($c.ProcessName)")) { HANDLE p=OpenProcess(PROCESS_TERMINATE,0,e.th32ProcessID); if(p){TerminateProcess(p,0);CloseHandle(p);} } CloseHandle(s); }
    bool Wait(int n=10) { for(int i=0;i<n;i++){ HANDLE s=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0); if(s==INVALID_HANDLE_VALUE)return 0;
        PROCESSENTRY32 e={sizeof(e)}; bool f=0; while(Process32Next(s,&e)) if(!strcmp(e.szExeFile,"$($c.ProcessName)")){f=1;break;} CloseHandle(s); if(!f)return 1; Sleep(100); } return 0; }
    bool Patch(void* d) {
        auto W=[&](uint32_t off,const char* b,size_t l){ memcpy((char*)d+(off-O::ADJ),b,l); };
        printf("Patching...\n");
        W(O::ESS1,"\x02",1); W(O::ESS2,"\xEB",1); W(O::CAFS,"\x49\x89\xC5\x90",4); W(O::AEOCS,"\x02",1);
        W(O::MD,"\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\x90\xE9",13);
        W(O::EBM,"\x90\xD4\x05",3); W(O::SBBV,"\x90\xD4\x05\x00\x00",5); W(O::SBBO,"\x90\x90\x90",3);
        W(O::E48,"\x90\x90\x90",3); W(O::HPF,"\x48\xB8\x10\x9E\xD8\xCF\x08\x02\x00\x00\xC3",11);
        W(O::HPCF,(const char*)hp_cutoff,0x100); W(O::DCR,(const char*)dc_reject,0x1B6);
        W(O::DMF,"\xC3",1); W(O::AEOK,"\x48\xC7\xC0\x01\x00\x00\x00\xC3",8); W(O::TE,"\xC3",1);
        return 1;
    }
public:
    P(HANDLE p,const std::string& s):proc(p),path(s){}
    bool Run() {
        printf("\n=== Discord Patcher v2.5 ===\nTarget: %s\nConfig: %dkHz %dkbps %dx gain\n\n",path.c_str(),SR/1000,BR,AG);
        TerminateProcess(proc,0); if(!Wait()) { Kill(); Sleep(500); }
        HANDLE f=CreateFileA(path.c_str(),GENERIC_READ|GENERIC_WRITE,0,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
        if(f==INVALID_HANDLE_VALUE){ printf("ERROR: Can't open file\n"); return 0; }
        LARGE_INTEGER sz; GetFileSizeEx(f,&sz);
        void* d=VirtualAlloc(0,sz.QuadPart,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
        DWORD r; ReadFile(f,d,sz.QuadPart,&r,0);
        if(!Patch(d)){ VirtualFree(d,0,MEM_RELEASE); CloseHandle(f); return 0; }
        SetFilePointer(f,0,0,FILE_BEGIN); DWORD w; WriteFile(f,d,sz.QuadPart,&w,0);
        VirtualFree(d,0,MEM_RELEASE); CloseHandle(f);
        printf("\nSUCCESS! Restart Discord.\n"); return 1;
    }
};
int main() {
    SetConsoleTitle("Discord Patcher v2.5");
    HANDLE s=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0); if(s==INVALID_HANDLE_VALUE){ printf("ERROR\n"); system("pause"); return 1; }
    PROCESSENTRY32 e={sizeof(e)};
    while(Process32Next(s,&e)) if(!strcmp(e.szExeFile,"$($c.ProcessName)")) {
        HANDLE p=OpenProcess(PROCESS_ALL_ACCESS,0,e.th32ProcessID); if(!p) continue;
        HMODULE m[1024]; DWORD n; if(!EnumProcessModules(p,m,sizeof(m),&n)){ CloseHandle(p); continue; }
        for(DWORD i=0;i<n/sizeof(HMODULE);i++) { char nm[MAX_PATH]; if(GetModuleBaseNameA(p,m[i],nm,MAX_PATH) && !strcmp(nm,"$($c.ModuleName)")) {
            char mp[MAX_PATH]; GetModuleFileNameExA(p,m[i],mp,MAX_PATH); CloseHandle(s);
            P x(p,mp); bool ok=x.Run(); CloseHandle(p); system("pause"); return ok?0:1;
        }}
        CloseHandle(p);
    }
    CloseHandle(s); printf("ERROR: Discord not found\n"); system("pause"); return 1;
}
"@
}

function New-SourceFiles {
    Write-Log "Generating source files..." -Level Info
    try {
        $patcher = "$($Script:Config.TempDir)\patcher.cpp"; $amp = "$($Script:Config.TempDir)\amplifier.cpp"
        Get-PatcherSourceCode | Out-File $patcher -Encoding ASCII -Force
        Get-AmplifierSourceCode | Out-File $amp -Encoding ASCII -Force
        Write-Log "Source files created" -Level Success
        return @($patcher, $amp)
    } catch { Write-Log "Failed: $_" -Level Error; return $null }
}
#endregion

#region Compilation
function Invoke-Compilation {
    param([hashtable]$Compiler, [string[]]$SourceFiles)
    Write-Log "Compiling with $($Compiler.Type)..." -Level Info
    $exe = "$($Script:Config.TempDir)\DiscordVoicePatcher.exe"; $log = "$($Script:Config.TempDir)\build.log"
    try {
        switch ($Compiler.Type) {
            'MSVC' {
                "@echo off`ncall `"$($Compiler.Path)`"`ncl.exe /EHsc /O2 /std:c++17 `"$($SourceFiles -join '" "')`" /Fe`"$exe`" /link Psapi.lib" | Out-File "$($Script:Config.TempDir)\build.bat" -Encoding ASCII
                cmd /c "`"$($Script:Config.TempDir)\build.bat`" > `"$log`" 2>&1" | Out-Null
            }
            'MinGW' { & g++ -O2 -std=c++17 $SourceFiles -o $exe -lpsapi -static 2>&1 | Out-File $log -Force }
            'Clang' { & clang++ -O2 -std=c++17 $SourceFiles -o $exe -lpsapi 2>&1 | Out-File $log -Force }
        }
        if (Test-Path $exe) { Write-Log "Compilation successful!" -Level Success; return $exe }
        throw "Build failed"
    } catch { Write-Log "Compilation failed" -Level Error; if (Test-Path $log) { Get-Content $log | Write-Host }; return $null }
}
#endregion

#region Main
function Start-Patching {
    Write-Banner
    if ($ListBackups) { Show-BackupList; return $true }
    if ($Restore) { return Restore-FromBackup }

    if (-not $NoGUI) {
        Write-Log "Opening GUI..." -Level Info
        $result = Show-ConfigurationGUI
        if (-not $result) { Write-Log "Cancelled" -Level Warning; return $false }
        if ($result.Action -eq 'Restore') { return Restore-FromBackup }
        if ($result.Action -ne 'Patch') { Write-Log "Cancelled" -Level Warning; return $false }
        $Script:Config.AudioGainMultiplier = $result.Multiplier
        $Script:Config.SkipBackup = $result.SkipBackup
    }

    Show-Settings; Initialize-Environment
    if (-not (Test-DiscordRunning)) { Read-Host "Press Enter"; return $false }
    $info = Get-DiscordProcessInfo
    if ($info -and -not (Test-DiscordVersionCompatibility $info.Version)) { return $false }
    if (-not $info.VoiceNodePath) { Write-Log "Voice node not found" -Level Error; Read-Host "Press Enter"; return $false }
    Write-Log "Found: $($info.VoiceNodePath)" -Level Success
    if (-not (Test-FileIntegrity $info.VoiceNodePath)) { Read-Host "Press Enter"; return $false }
    if (-not (Backup-VoiceNode $info.VoiceNodePath) -and -not $Script:Config.SkipBackup) { Read-Host "Press Enter"; return $false }
    $compiler = Find-Compiler; if (-not $compiler) { Read-Host "Press Enter"; return $false }
    $src = New-SourceFiles; if (-not $src) { Read-Host "Press Enter"; return $false }
    $exe = Invoke-Compilation -Compiler $compiler -SourceFiles $src; if (-not $exe) { Read-Host "Press Enter"; return $false }
    Save-UserConfig
    Write-Log "Launching patcher..." -Level Info
    try { Start-Process -FilePath $exe -Wait -NoNewWindow; Write-Log "Complete!" -Level Success; return $true }
    catch { Write-Log "Failed: $_" -Level Error; return $false }
}

try {
    $success = Start-Patching
    Write-Host "`n$(if ($success) { 'SUCCESS!' } else { 'FAILED/CANCELLED' })" -ForegroundColor $(if ($success) { 'Green' } else { 'Red' })
    Read-Host "`nPress Enter to exit"
    exit $(if ($success) { 0 } else { 1 })
} catch {
    Write-Host "`nFATAL ERROR: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    Read-Host "Press Enter to exit"; exit 1
}
#endregion

<# ═══════════════════════════════════════════════════════════════════════════════
   DEVELOPER DOCUMENTATION
═══════════════════════════════════════════════════════════════════════════════

WHAT THIS DOES
  Patches discord_voice.node to enable: Stereo (vs mono), 382kbps (vs 64kbps),
  48kHz locked (vs negotiated), and configurable gain amplification.

HOW IT WORKS
  1. PowerShell generates C++ code with your settings
  2. Compiles to .exe (needs MSVC/MinGW/Clang)
  3. Exe finds Discord, terminates it, patches the file at specific offsets
  4. Custom audio functions get injected to replace Discord's filters

FILE LOCATION
  %LOCALAPPDATA%\Discord\app-X.X.XXXX\modules\discord_voice-X\discord_voice\

─────────────────────────────────────────────────────────────────────────────────
OFFSET TABLE (Discord v9219) - File offset = Memory offset - 0xC00
─────────────────────────────────────────────────────────────────────────────────
Offset     Name                    Patch                Purpose
─────────────────────────────────────────────────────────────────────────────────
0x520CFB   EmulateStereoSuccess1   02                   Pass stereo check
0x520D07   EmulateStereoSuccess2   EB                   JMP (skip mono branch)
0x116C91   CreateAudioFrameStereo  49 89 C5 90          Keep stereo pointer
0x3A0B64   OpusConfigChannels      02                   2 channels
0x0D6319   MonoDownmixer           90x12 + E9           NOP out downmix
0x52115A   BitrateModified         90 D4 05             382000 little-endian
0x522F81   BitrateValue            90 D4 05 00 00       Same
0x522F89   BitrateBitwiseOr        90 90 90             Remove cap
0x520E63   Emulate48Khz            90 90 90             Skip negotiation
0x52CF70   HighPassFilter          mov rax,addr;ret     Redirect to custom
0x8D64B0   HighpassCutoff          [hp_cutoff code]     256 bytes injected
0x8D6690   DcReject                [dc_reject code]     438 bytes injected
0x8D2820   DownmixFunc             C3                   RET (disable)
0x3A0E00   OpusConfigIsOk          mov rax,1;ret        Always valid
0x2B3340   ThrowError              C3                   Suppress errors

─────────────────────────────────────────────────────────────────────────────────
GAIN FORMULA
─────────────────────────────────────────────────────────────────────────────────
  actual_gain = channels + MULTIPLIER = 2 + (UserGain - 2) = UserGain
  
  User picks 1x → MULTIPLIER=-1 → 2+(-1)=1x | User picks 5x → MULTIPLIER=3 → 2+3=5x

─────────────────────────────────────────────────────────────────────────────────
INJECTED FUNCTIONS
─────────────────────────────────────────────────────────────────────────────────
hp_cutoff(in, cutoff_Hz, out, state, len, channels, Fs, arch)
dc_reject(in, out, state, len, channels, Fs)

Both call Init() to set magic values Discord expects, then apply gain:
  - Offset -3553+3557: set to 1002 (magic flag)
  - State vars at +160,+164,+184: set to -1,-1,0

─────────────────────────────────────────────────────────────────────────────────
FINDING OFFSETS FOR NEW DISCORD VERSIONS
─────────────────────────────────────────────────────────────────────────────────
Tools: IDA Pro, Ghidra (free), x64dbg

1. Search strings: "opus", "channels", "bitrate", "48000"
2. Opus init: find "mov ecx, 1" (channel count)
3. Stereo check: find "cmp eax, 1" + "jne"
4. Bitrate: find refs to 64000 (0xFA00)
5. Filters: float ops near "highpass" strings
6. Convert: file_offset = virtual_address - 0xC00

Pattern search example:
  $bytes = [IO.File]::ReadAllBytes($path)
  for ($i=0; $i -lt $bytes.Length-4; $i++) {
    if ($bytes[$i..($i+3)] -join ',' -eq '131,248,1,117') { "0x$($i.ToString('X'))" }
  }

─────────────────────────────────────────────────────────────────────────────────
CUSTOM MODS
─────────────────────────────────────────────────────────────────────────────────
Different bitrate (256kbps = 0x3E800 → 00 E8 03):
  W(O::EBM,"\x00\xE8\x03",3); W(O::SBBV,"\x00\xE8\x03\x00\x00",5);

Compressor (in C++):
  inline void Compress(float* io, int n, float thresh, float ratio) {
    for(int i=0;i<n;i++) { float m=fabsf(io[i]);
      if(m>thresh) io[i]=(io[i]>0?1:-1)*(thresh+(m-thresh)/ratio); }
  }

Passthrough (no processing):
  inline void Pass(const float* i, float* o, int n) { memcpy(o,i,n*4); }

─────────────────────────────────────────────────────────────────────────────────
TROUBLESHOOTING
─────────────────────────────────────────────────────────────────────────────────
Crash on startup    → Wrong offsets for your Discord version
No audio            → Init() magic values wrong
Distortion          → Gain too high (use 1-2x)
Compile error       → Need VS C++ workload, MinGW, or Clang
Access denied       → Close Discord fully, run as admin
No effect           → Wrong Discord variant (Stable/PTB/Canary are separate)

─────────────────────────────────────────────────────────────────────────────────
TOOLS
─────────────────────────────────────────────────────────────────────────────────
Disassemblers: Ghidra (free), IDA Pro, x64dbg
Hex editors:   HxD (free), 010 Editor
Opus codec:    https://opus-codec.org
PE format:     https://docs.microsoft.com/windows/win32/debug/pe-format

═══════════════════════════════════════════════════════════════════════════════ #>
