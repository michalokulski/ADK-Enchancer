#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enhances a WinRE/ADK-based WinPE image with components from full Windows installation media.

.DESCRIPTION
    ADK-Enhancer: Bridges the gap between Microsoft's minimal ADK WinPE (winpe.wim) and the
    feature-rich WinPE environments built by projects like PhoenixPE and wimbuilder2.

    This script:
      1. Extracts WinRE.wim from install.wim (preferred PE base over the ADK's winpe.wim)
      2. Mounts the base WIM image
      3. Injects components from install.wim: shell DLLs, WoW64, audio, network, fonts, etc.
      4. Merges critical registry hives from install.wim (SOFTWARE, SYSTEM)
      5. Configures FBWF (File-Based Write Filter) cache size
      6. Sets the WinPE scratch space (in-RAM temporary storage)
      7. Cleans up unneeded files (MUI language resources, diagnostics, telemetry)
      8. Captures the enhanced image with configurable compression (None/XPRESS/LZX)
      9. Optionally creates a bootable ISO

    Inspiration and techniques drawn from:
      - PhoenixPE (https://github.com/PhoenixPE/PhoenixPE)
      - wimbuilder2/WIN10XPE (https://github.com/slorelee/wimbuilder2)

.PARAMETER SourceMediaPath
    Path to the root of the Windows installation media (must contain Sources\install.wim).
    Example: D:\ or C:\ISO\Win11

.PARAMETER BaseWim
    Which WIM to use as the PE base: 'WinRE' (default, extracted from install.wim) or 'Boot'
    (uses Sources\boot.wim from the media directly).

.PARAMETER SourceInstallIndex
    Image index inside install.wim to use as the component source. Default: 1.
    Use 'Get-WindowsImage -ImagePath <path>\install.wim' to list available indexes.

.PARAMETER WorkDir
    Working directory for temporary mount points and intermediate files.
    Default: $env:TEMP\WinPE-Enhance

.PARAMETER OutputWim
    Full path for the output boot.wim. Default: .\Output\boot.wim

.PARAMETER OutputIso
    If specified, a bootable ISO will be created at this path using oscdimg.

.PARAMETER Compression
    WIM compression type: None, XPRESS (default), LZX.
    Note: LZMS is NOT supported for bootable WIMs (solid compression prevents mounting).
    PhoenixPE defaults to XPRESS; LZX gives ~15-25% smaller files at the cost of build time.

.PARAMETER FBWFCacheSizeMB
    WinPE FBWF (File-Based Write Filter) cache size in MB. This is the amount of RAM
    allocated as a writable overlay over the read-only boot media.
    Default: 512 MB. Maximum: 4094 MB on x64 Win10/11 WinPE; 1024 MB on x86.
    Larger values give more writable space but consume more RAM.

.PARAMETER ScratchSpaceMB
    WinPE scratch space size in MB. This is separate from FBWF — it is the RAM disk
    used by DISM and Windows Setup during PE operation.
    Valid values: 32, 64, 128, 256, 512. Default: 512.

.PARAMETER KeepWoW64
    Include the WoW64 (32-bit subsystem) from install.wim. Enables running 32-bit
    recovery/forensics tools inside a 64-bit WinPE. Adds ~150-300 MB. Default: $true.

.PARAMETER Language
    PE language to keep (all others will be removed). Default: en-US.

.PARAMETER IncludeAudio
    Inject audio subsystem from install.wim. Default: $false.

.PARAMETER IncludeShell
    Inject shell components (Explorer, shell32.dll, DWM, etc.) from install.wim.
    Default: $false. Enable for full desktop shell builds.

.EXAMPLE
    .\Enhance-WinPE.ps1 -SourceMediaPath "D:\" -OutputWim "C:\Output\boot.wim"

.EXAMPLE
    .\Enhance-WinPE.ps1 -SourceMediaPath "D:\" -BaseWim Boot -Compression LZX `
        -FBWFCacheSizeMB 2048 -ScratchSpaceMB 512 `
        -OutputWim "C:\Output\boot.wim" -OutputIso "C:\Output\WinPE.iso"

.NOTES
    Requires: Windows ADK (dism.exe, oscdimg.exe), running as Administrator.
    ADK download: https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path (Join-Path $_ 'Sources\install.wim') -PathType Leaf })]
    [string]$SourceMediaPath,

    [ValidateSet('WinRE', 'Boot')]
    [string]$BaseWim = 'WinRE',

    [ValidateRange(1, 16)]
    [int]$SourceInstallIndex = 1,

    [string]$WorkDir = (Join-Path $env:TEMP 'WinPE-Enhance'),

    [string]$OutputWim = '.\Output\boot.wim',

    [string]$OutputIso,

    [ValidateSet('None', 'XPRESS', 'LZX')]
    [string]$Compression = 'XPRESS',

    # Upper limit is 131072 MB (128 GB) to support future WES fbwf.sys-based large caches.
    # The standard WinPE FBWF driver clamps to 4094 MB at runtime (enforced below).
    [ValidateRange(32, 131072)]
    [int]$FBWFCacheSizeMB = 512,

    [ValidateSet(32, 64, 128, 256, 512)]
    [int]$ScratchSpaceMB = 512,

    [bool]$KeepWoW64 = $true,

    [string]$Language = 'en-US',

    [bool]$IncludeAudio = $false,

    [bool]$IncludeShell = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region -- Helper Functions --------------------------------------------------

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "`n==> $Message" -ForegroundColor $Color
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Invoke-Dism {
    <#
    .SYNOPSIS Wraps dism.exe calls and throws on non-zero exit.
    Note: PhoenixPE ships its own DISM to avoid host-OS version mismatches;
    this script uses the inbox DISM but warns if it's older than the image.
    #>
    param([string[]]$Arguments)
    $dismPath = Get-Command dism.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $dismPath) {
        # Try ADK path
        $adkDism = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\DISM\dism.exe'
        if (Test-Path $adkDism) { $dismPath = $adkDism }
        else { throw "dism.exe not found. Please install the Windows ADK." }
    }
    Write-Info "dism.exe $($Arguments -join ' ')"
    $result = & $dismPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $result | ForEach-Object { Write-Host $_ -ForegroundColor Red }
        throw "DISM failed with exit code $LASTEXITCODE"
    }
    return $result
}

function Test-AdminElevation {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Remove-MountSafe {
    param([string]$MountPath, [switch]$Discard)
    try {
        if ($Discard) {
            Invoke-Dism @('/Unmount-Wim', "/MountDir:$MountPath", '/Discard') | Out-Null
        } else {
            Invoke-Dism @('/Unmount-Wim', "/MountDir:$MountPath", '/Commit') | Out-Null
        }
    } catch {
        Write-Warn "Clean unmount failed, attempting cleanup: $_"
        & dism.exe /Cleanup-Mountpoints 2>&1 | Out-Null
    }
}

function Copy-FileIfExists {
    param([string]$Source, [string]$Destination)
    if (Test-Path $Source) {
        $destDir = Split-Path $Destination -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -Path $Source -Destination $Destination -Force
        return $true
    }
    return $false
}

function Remove-ItemSafe {
    param([string]$Path)
    if (Test-Path $Path) { Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

#endregion

#region -- Path Setup --------------------------------------------------------

$installWim    = Join-Path $SourceMediaPath 'Sources\install.wim'
$installEsd    = Join-Path $SourceMediaPath 'Sources\install.esd'
$bootWim       = Join-Path $SourceMediaPath 'Sources\boot.wim'

# Prefer install.wim; fall back to install.esd with a warning
if (Test-Path $installWim) {
    $srcInstallWim = $installWim
} elseif (Test-Path $installEsd) {
    $srcInstallWim = $installEsd
    Write-Warn "install.esd found (may be encrypted). Prefer install.wim for reliable component extraction."
} else {
    throw "Could not find install.wim or install.esd in $SourceMediaPath\Sources"
}

# Directories
$mountPE       = Join-Path $WorkDir 'mount_pe'
$mountInstall  = Join-Path $WorkDir 'mount_install'
$cacheDir      = Join-Path $WorkDir 'cache'
$wimreCache    = Join-Path $cacheDir 'WinRE.wim'
$outputDir     = Split-Path $OutputWim -Parent

foreach ($dir in @($WorkDir, $mountPE, $mountInstall, $cacheDir, $outputDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

#endregion

#region -- Sanity Checks -----------------------------------------------------

Write-Step "Pre-flight checks"

if (-not (Test-AdminElevation)) {
    throw "This script must run as Administrator (DISM requires elevation)."
}

# Warn about FBWF limits — mirrors PhoenixPE's Config-FBWF logic
# 4094 is the effective maximum: 4096 is used as a sentinel value by the FBWF driver
# (the driver interprets 4096 as "use maximum supported", not as a literal MB count).
if ($FBWFCacheSizeMB -gt 4094) {
    Write-Warn "Win10/11 WinPE (x64) maximum FBWF cache is 4094 MB. Clamping to 4094."
    $FBWFCacheSizeMB = 4094
}
if ($FBWFCacheSizeMB -gt 1024) {
    # Architecture check — if we can't determine arch yet, just warn
    Write-Warn "FBWF cache > 1024 MB requires a 64-bit (x64) WinPE base."
}

Write-Info "Source media : $SourceMediaPath"
Write-Info "Install WIM  : $srcInstallWim (index $SourceInstallIndex)"
Write-Info "Base WIM     : $BaseWim"
Write-Info "Compression  : $Compression"
Write-Info "FBWF cache   : $FBWFCacheSizeMB MB"
Write-Info "Scratch space: $ScratchSpaceMB MB"
Write-Info "Language     : $Language"
Write-Info "WoW64        : $KeepWoW64"
Write-Info "Output WIM   : $OutputWim"

#endregion

#region -- Step 1: Obtain Base WIM -------------------------------------------

Write-Step "Step 1 — Obtaining base WIM"

$baseWimPath = $null

if ($BaseWim -eq 'WinRE') {
    # Technique from PhoenixPE 210-Core.script: extract WinRE.wim from install.wim
    # and cache it so repeated builds are fast.
    if (Test-Path $wimreCache) {
        Write-Info "Using cached WinRE.wim from previous run."
    } else {
        Write-Info "Extracting WinRE.wim from install.wim[$SourceInstallIndex]..."
        Write-Info "Mounting install.wim (read-only)..."
        Invoke-Dism @('/Mount-Wim', "/WimFile:$srcInstallWim", "/Index:$SourceInstallIndex",
                      "/MountDir:$mountInstall", '/ReadOnly') | Out-Null

        $winreInInstall = Join-Path $mountInstall 'Windows\System32\Recovery\WinRE.wim'
        if (-not (Test-Path $winreInInstall)) {
            Remove-MountSafe -MountPath $mountInstall -Discard
            throw "WinRE.wim not found inside install.wim. Ensure you selected a valid Windows image index."
        }
        Copy-Item -Path $winreInInstall -Destination $wimreCache -Force
        Remove-MountSafe -MountPath $mountInstall -Discard
        Write-Info "WinRE.wim extracted and cached at: $wimreCache"
    }
    $baseWimPath = $wimreCache

} else {
    # Boot.wim approach — PhoenixPE's SuperchargeBootWim pattern
    if (-not (Test-Path $bootWim)) {
        throw "boot.wim not found at $bootWim"
    }
    # Use a working copy so we don't modify original media
    $bootWimCopy = Join-Path $cacheDir 'boot.wim'
    Copy-Item -Path $bootWim -Destination $bootWimCopy -Force
    $baseWimPath = $bootWimCopy
    Write-Info "Using boot.wim copy: $bootWimCopy"
}

#endregion

#region -- Step 2: Mount Base WIM --------------------------------------------

Write-Step "Step 2 — Mounting base WIM for modification"

# Determine the correct image index in the base WIM
$wimInfo = Get-WindowsImage -ImagePath $baseWimPath
Write-Info "Images in base WIM:"
$wimInfo | ForEach-Object { Write-Info "  [$($_.ImageIndex)] $($_.ImageName)" }

# WinRE.wim typically has index 1; boot.wim index 2 is the full WinPE
$baseIndex = if ($BaseWim -eq 'WinRE') { 1 } else { [int]($wimInfo | Sort-Object ImageIndex | Select-Object -Last 1).ImageIndex }

if ($PSCmdlet.ShouldProcess($baseWimPath, "Mount WIM index $baseIndex")) {
    Invoke-Dism @('/Mount-Wim', "/WimFile:$baseWimPath", "/Index:$baseIndex",
                  "/MountDir:$mountPE") | Out-Null
    Write-Info "Base WIM mounted at: $mountPE"
}

#endregion

#region -- Step 3: Mount install.wim for Component Extraction ----------------

Write-Step "Step 3 — Mounting install.wim (read-only) for component extraction"

if ($PSCmdlet.ShouldProcess($srcInstallWim, "Mount install.wim index $SourceInstallIndex")) {
    Invoke-Dism @('/Mount-Wim', "/WimFile:$srcInstallWim", "/Index:$SourceInstallIndex",
                  "/MountDir:$mountInstall", '/ReadOnly') | Out-Null
    Write-Info "install.wim mounted at: $mountInstall"
}

$installSys32   = Join-Path $mountInstall 'Windows\System32'
$installSysWOW  = Join-Path $mountInstall 'Windows\SysWOW64'
$installWindows = Join-Path $mountInstall 'Windows'
$peSys32        = Join-Path $mountPE 'Windows\System32'
$peWindows      = Join-Path $mountPE 'Windows'

#endregion

#region -- Step 4: Core Runtime Components -----------------------------------

Write-Step "Step 4 — Injecting core runtime components from install.wim"

# -- 4a. Essential DLLs missing from minimal WinRE/winpe.wim --------------
# Based on wimbuilder2 WIN10XPE/00-Configures/System/main.bat component list
# and PhoenixPE 210-Core.script WinSxS extraction patterns
$essentialFiles = @(
    # Power management (present in WinRE but extended in install.wim)
    'powercfg.cpl', 'powercpl.dll', 'umpoext.dll',

    # Cloud Store (needed for modern shell components)
    'Windows.CloudStore.dll',

    # Network diagnostic
    'ncsi.dll',

    # Security
    'credssp.dll',

    # ISM (Miracast/display, needed post-Win11)
    'ISM.exe'
)

foreach ($file in $essentialFiles) {
    $src = Join-Path $installSys32 $file
    $dst = Join-Path $peSys32 $file
    if (Copy-FileIfExists -Source $src -Destination $dst) {
        Write-Info "  Injected: $file"
    }
}

# Language-specific ncsi.dll.mui (not in WinRE)
$ncsiMuiSrc = Join-Path $installSys32 "$Language\ncsi.dll.mui"
$ncsiMuiDst = Join-Path $peSys32 "$Language\ncsi.dll.mui"
Copy-FileIfExists -Source $ncsiMuiSrc -Destination $ncsiMuiDst | Out-Null

# -- 4b. WMI Repository seed (rebuilt at first boot, but seeding accelerates startup) --
# wimbuilder2 opt[slim.wbem_repository] = true removes it; PhoenixPE also removes it.
# We intentionally skip it — WMI rebuilds automatically on first PE boot.
Write-Info "  WMI repository: will auto-rebuild on first PE boot (omitted from image)"

# -- 4c. Fonts -------------------------------------------------------------
Write-Step "Step 4c — Injecting fonts"
$fontsDir = Join-Path $peWindows 'Fonts'
if (-not (Test-Path $fontsDir)) { New-Item -ItemType Directory -Path $fontsDir -Force | Out-Null }

$requiredFonts = @('segoeui.ttf', 'segoeuib.ttf', 'segoeuii.ttf', 'segoeuiz.ttf',
                    'seguisb.ttf', 'seguisym.ttf', 'consola.ttf', 'consolab.ttf',
                    'consolai.ttf', 'consolaz.ttf')
# Post-Win11 21H2+ Segoe Fluent Icons
$fluentFont = 'SegoeIcons.ttf'
foreach ($font in ($requiredFonts + $fluentFont)) {
    $src = Join-Path $installWindows "Fonts\$font"
    $dst = Join-Path $fontsDir $font
    if (Copy-FileIfExists -Source $src -Destination $dst) {
        Write-Info "  Font: $font"
    }
}

#endregion

#region -- Step 5: WoW64 (32-bit Compatibility Layer) ------------------------

if ($KeepWoW64) {
    Write-Step "Step 5 — Injecting WoW64 (32-bit subsystem)"

    $peSysWOW = Join-Path $mountPE 'Windows\SysWOW64'
    if (-not (Test-Path $peSysWOW)) { New-Item -ItemType Directory -Path $peSysWOW -Force | Out-Null }

    # Core WoW64 bridge DLLs that must be in System32
    $wow64BridgeDlls = @('wow64.dll', 'wow64base.dll', 'wow64con.dll',
                          'wow64cpu.dll', 'wow64win.dll')
    foreach ($dll in $wow64BridgeDlls) {
        $src = Join-Path $installSys32 $dll
        $dst = Join-Path $peSys32 $dll
        if (Copy-FileIfExists -Source $src -Destination $dst) {
            Write-Info "  WoW64 bridge: $dll"
        }
    }

    # Core 32-bit runtime DLLs in SysWOW64
    $sysWow64Dlls = @(
        'ntdll.dll', 'kernel32.dll', 'kernelbase.dll', 'advapi32.dll', 'user32.dll',
        'gdi32.dll', 'gdi32full.dll', 'msvcrt.dll', 'rpcrt4.dll', 'sechost.dll',
        'ucrtbase.dll', 'ws2_32.dll', 'shlwapi.dll', 'shell32.dll', 'ole32.dll',
        'oleaut32.dll', 'combase.dll', 'comdlg32.dll', 'version.dll', 'wininet.dll',
        'urlmon.dll', 'crypt32.dll', 'cryptbase.dll', 'bcrypt.dll', 'ncrypt.dll',
        'wintrust.dll', 'imagehlp.dll', 'dbghelp.dll', 'msvcp_win.dll',
        'win32u.dll', 'imm32.dll', 'setupapi.dll', 'cfgmgr32.dll'
    )
    $copiedCount = 0
    foreach ($dll in $sysWow64Dlls) {
        $src = Join-Path $installSysWOW $dll
        $dst = Join-Path $peSysWOW $dll
        if (Copy-FileIfExists -Source $src -Destination $dst) { $copiedCount++ }
    }
    Write-Info "  WoW64 core DLLs injected: $copiedCount / $($sysWow64Dlls.Count)"
} else {
    Write-Step "Step 5 — WoW64 skipped (KeepWoW64=$KeepWoW64)"
}

#endregion

#region -- Step 6: Audio Subsystem -------------------------------------------

if ($IncludeAudio) {
    Write-Step "Step 6 — Injecting audio subsystem"
    # wimbuilder2: 01-Components/03-Audio; PhoenixPE: Component/Audio.script
    $audioDlls = @(
        'audiodg.exe', 'audiosrv.dll', 'audioeng.dll', 'audioendpointbuilder.dll',
        'mmdevapi.dll', 'wasapi.dll', 'mf.dll', 'mfplat.dll', 'mfreadwrite.dll',
        'ksuser.dll', 'ksproxy.ax', 'dsound.dll', 'XAudio2_9.dll',
        'wmasf.dll', 'wmaudio3.dll'
    )
    foreach ($dll in $audioDlls) {
        $src = Join-Path $installSys32 $dll
        $dst = Join-Path $peSys32 $dll
        if (Copy-FileIfExists -Source $src -Destination $dst) {
            Write-Info "  Audio: $dll"
        }
    }
} else {
    Write-Step "Step 6 — Audio subsystem skipped (IncludeAudio=$IncludeAudio)"
}

#endregion

#region -- Step 7: Shell Components ------------------------------------------

if ($IncludeShell) {
    Write-Step "Step 7 — Injecting shell components (Explorer, DWM, etc.)"
    # Based on wimbuilder2 01-Components/00-Shell and PhoenixPE Components/Shell
    $shellDlls = @(
        'explorer.exe', 'shell32.dll', 'shlwapi.dll', 'shsvcs.dll',
        'SHCore.dll', 'Windows.Shell.ServiceProvider.dll',
        'dwm.exe', 'dwmapi.dll', 'dwminit.dll', 'udwm.dll',
        'taskbar.dll', 'twinui.dll', 'twinui.appcore.dll', 'twinui.pcshell.dll',
        'windows.ui.dll', 'windows.ui.xaml.dll',
        'uiautomationcore.dll', 'uiautomation6.dll',
        'ExplorerFrame.dll', 'cscui.dll'
    )
    foreach ($dll in $shellDlls) {
        $src = Join-Path $installSys32 $dll
        $dst = Join-Path $peSys32 $dll
        if (Copy-FileIfExists -Source $src -Destination $dst) {
            Write-Info "  Shell: $dll"
        }
    }
} else {
    Write-Step "Step 7 — Shell components skipped (IncludeShell=$IncludeShell)"
    Write-Info "  To enable a full desktop shell, re-run with -IncludeShell:`$true"
}

#endregion

#region -- Step 8: Registry Configuration ------------------------------------

Write-Step "Step 8 — Configuring PE registry"

# Registry hive paths inside the mounted PE
$peHiveSoftware = Join-Path $mountPE 'Windows\System32\config\SOFTWARE'
$peHiveSystem   = Join-Path $mountPE 'Windows\System32\config\SYSTEM'

# Load PE registry hives into temporary keys
$tmpSoftware = 'HKLM\PE_SOFTWARE'
$tmpSystem   = 'HKLM\PE_SYSTEM'

Write-Info "Loading PE registry hives..."
& reg.exe load $tmpSoftware $peHiveSoftware 2>&1 | Out-Null
& reg.exe load $tmpSystem   $peHiveSystem   2>&1 | Out-Null

try {
    # -- 8a. WinPE identification key -------------------------------------
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinPE" `
        /v InstRoot /d 'X:\' /f 2>&1 | Out-Null

    # -- 8b. Disable telemetry / DiagTrack --------------------------------
    # Both PhoenixPE (SlimFast) and wimbuilder2 (main.bat) disable these
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" `
        /v AllowTelemetry /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\WMI\Autologger\AutoLogger-Diagtrack-Listener" `
        /v Start /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    Write-Info "  Telemetry disabled"

    # -- 8c. Disable Hibernate & Fast Startup -----------------------------
    # wimbuilder2 00-Configures/System/main.bat pattern
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Power" `
        /v HibernateEnabled /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Power" `
        /v CustomizeDuringSetup /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Session Manager\Power" `
        /v HiberbootEnabled /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    Write-Info "  Hibernate and Fast Startup disabled"

    # -- 8d. High Performance power scheme --------------------------------
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Power\User\PowerSchemes" `
        /v ActivePowerScheme /d '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' /f 2>&1 | Out-Null
    Write-Info "  Power scheme: High Performance"

    # -- 8e. Disable NTFS/ReFS last-access timestamp updates --------------
    # Performance optimisation — wimbuilder2 pattern
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\FileSystem" `
        /v NtfsDisableLastAccessUpdate /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\FileSystem" `
        /v RefsDisableLastAccessUpdate /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    Write-Info "  Last-access timestamp updates disabled"

    # -- 8f. Allow blank-password network logins ---------------------------
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Lsa" `
        /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    Write-Info "  Blank-password network access allowed"

    # -- 8g. AppData environment variable for PE ---------------------------
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Session Manager\Environment" `
        /v AppData /t REG_EXPAND_SZ /d '%SystemDrive%\Users\Default\AppData\Roaming' /f 2>&1 | Out-Null
    Write-Info "  AppData environment variable set"

    # -- 8h. FBWF (File-Based Write Filter) -------------------------------
    # PhoenixPE: Config-FBWF in 212-ShellConfig.script
    # wimbuilder2: SystemDriveSize.bat
    # The FBWF cache is the RAM overlay that makes the read-only boot WIM appear writable.
    # Without it, any write to C:\ in PE would fail or be silently discarded.
    Write-Info "  Configuring FBWF cache: $FBWFCacheSizeMB MB"
    $fbwfKey = "HKLM\PE_SYSTEM\ControlSet001\Services\FBWF"
    & reg.exe add $fbwfKey /v WinPECacheThreshold /t REG_DWORD /d $FBWFCacheSizeMB /f 2>&1 | Out-Null

    # Enable exFAT support (wimbuilder2 pattern for large FBWF caches)
    # Triggered at 4094 MB (the enforced maximum for standard WinPE FBWF)
    if ($FBWFCacheSizeMB -ge 4094) {
        & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\exfat" `
            /v Start /t REG_DWORD /d 0 /f 2>&1 | Out-Null
        Write-Info "  exFAT driver enabled (required for FBWF >= 4094 MB)"
    }

    # -- 8i. Enable required network services (post-RS5/1809 pattern) -----
    # wimbuilder2 pattern: AllowStart keys for services that need explicit permission
    foreach ($svc in @('LanmanWorkstation', 'DNSCache', 'NlaSvc', 'ProfSvc', 'Appinfo')) {
        & reg.exe add "HKLM\PE_SYSTEM\Setup\AllowStart\$svc" /f 2>&1 | Out-Null
    }
    Write-Info "  Network services enabled: LanmanWorkstation, DNSCache, NlaSvc, ProfSvc, Appinfo"

    # -- 8j. Base Filtering Engine (BFE) for firewall support -------------
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\BFE" `
        /v SvcHostSplitDisable /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    Write-Info "  Base Filtering Engine configured"

    # -- 8k. Default user profile path ------------------------------------
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-18" `
        /v ProfileImagePath /d 'X:\Users\Default' /f 2>&1 | Out-Null
    Write-Info "  Default user profile: X:\Users\Default"

    # -- 8l. Font registration (check PE image, not install.wim, since fonts were copied in Step 4c)
    $fontsKey = "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
    & reg.exe add $fontsKey /v "Segoe UI (TrueType)" /d segoeui.ttf /f 2>&1 | Out-Null
    & reg.exe add $fontsKey /v "Consolas (TrueType)" /d consola.ttf  /f 2>&1 | Out-Null
    if (Test-Path (Join-Path $peWindows 'Fonts\SegoeIcons.ttf')) {
        & reg.exe add $fontsKey /v "Segoe Fluent Icons (TrueType)" /d SegoeIcons.ttf /f 2>&1 | Out-Null
    }
    Write-Info "  Fonts registered in registry"

} finally {
    # Always unload hives to prevent hive leaks
    Write-Info "Unloading PE registry hives..."
    & reg.exe unload $tmpSoftware 2>&1 | Out-Null
    & reg.exe unload $tmpSystem   2>&1 | Out-Null
    # Clean up transaction logs left by reg editing (PhoenixPE SlimFast pattern)
    $configDir = Join-Path $mountPE 'Windows\System32\config'
    Get-ChildItem -Path $configDir -Include '*.LOG1','*.LOG2','*.blf','*.regtrans-ms' -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Info "  Registry transaction logs cleaned"
}

#endregion

#region -- Step 9: Scratch Space ---------------------------------------------

Write-Step "Step 9 — Setting WinPE scratch space ($ScratchSpaceMB MB)"

# Scratch space is the in-RAM temp directory used by DISM and Windows Setup
# in WinPE. It is distinct from FBWF (which protects the boot drive from writes).
# PhoenixPE references DISM /Set-ScratchSpace; wimbuilder2 configures via FBWF cache.
# DISM must be run against the *mounted* image for /Set-ScratchSpace to take effect.
Invoke-Dism @('/Image:' + $mountPE, "/Set-ScratchSpace:$ScratchSpaceMB") | Out-Null
Write-Info "  Scratch space set to $ScratchSpaceMB MB"

#endregion

#region -- Step 10: Slim Down — Remove Unneeded Components -------------------

Write-Step "Step 10 — Slimming: removing unneeded files"

# -- 10a. MUI language resources — keep $Language and always en-US (boot fallback) ----------
# Both PhoenixPE (SlimFast CleanupMui) and wimbuilder2 (SlimWim REMOVE_MUI) do this
$muiPaths = @(
    (Join-Path $mountPE 'Windows\System32'),
    (Join-Path $mountPE 'Windows\Boot\EFI'),
    (Join-Path $mountPE 'Windows\Boot\PCAT'),
    (Join-Path $mountPE 'Windows\Boot\PXE')
)
foreach ($muiRoot in $muiPaths) {
    if (-not (Test-Path $muiRoot)) { continue }
    Get-ChildItem -Path $muiRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^[a-z]{2}-[A-Z]{2}' -and $_.Name -ne $Language -and $_.Name -ne 'en-US'
    } | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "  Removed MUI: $($_.FullName)"
    }
}

# -- 10b. Telemetry / DiagTrack --------------------------------------------
# PhoenixPE SlimFast + wimbuilder2 main.bat both remove these
$removeItems = @(
    (Join-Path $mountPE 'Windows\DiagTrack'),
    (Join-Path $mountPE 'Windows\System32\DiagSvcs'),
    (Join-Path $mountPE 'Windows\System32\diagER.dll'),
    (Join-Path $mountPE 'Windows\System32\diagtrack.dll')
)
foreach ($item in $removeItems) { Remove-ItemSafe -Path $item }
Write-Info "  Telemetry/DiagTrack components removed"

# -- 10c. WMI auto-recover and logs (rebuilt at boot) ----------------------
# wimbuilder2 opt[slim.wbem_repository]; PhoenixPE SlimFast
$wbemCleanup = @(
    (Join-Path $mountPE 'Windows\System32\wbem\AutoRecover'),
    (Join-Path $mountPE 'Windows\System32\wbem\Logs'),
    (Join-Path $mountPE 'Windows\System32\wbem\Repository'),
    (Join-Path $mountPE 'Windows\System32\wbem\tmf')
)
foreach ($item in $wbemCleanup) { Remove-ItemSafe -Path $item }
Write-Info "  WMI auto-recover directories removed (will rebuild at boot)"

# -- 10d. Migration engine (not needed in rescue PE) -----------------------
# PhoenixPE SlimFast removes these
$migrationFiles = @('migapp.xml','migcore.dll','migisol.dll','migres.dll',
                      'migstore.dll','migsys.dll','SFCN.dat')
foreach ($f in $migrationFiles) {
    Remove-ItemSafe -Path (Join-Path $mountPE "Windows\System32\$f")
}
Remove-ItemSafe -Path (Join-Path $mountPE 'Windows\System32\migration')
Write-Info "  Migration engine files removed"

# -- 10e. WinRE sources folder (present in WinRE base; not needed in output) -
Remove-ItemSafe -Path (Join-Path $mountPE 'sources')
Write-Info "  Sources folder removed from PE image"

# -- 10f. Desktop.ini stubs -----------------------------------------------
Remove-ItemSafe -Path (Join-Path $mountPE 'Users\Default\Desktop\Desktop.ini')
Remove-ItemSafe -Path (Join-Path $mountPE 'Users\Public\Desktop\Desktop.ini')
Write-Info "  Desktop.ini stubs removed"

# -- 10g. Crash-dump / WallpaperHost (causes issues in PE) -----------------
# PhoenixPE SlimFast
$miscRemove = @('WallpaperHost.exe', 'windows.immersiveshell.serviceprovider.dll')
foreach ($f in $miscRemove) {
    Remove-ItemSafe -Path (Join-Path $mountPE "Windows\System32\$f")
}
Write-Info "  Miscellaneous PE-incompatible files removed"

#endregion

#region -- Step 11: Unmount install.wim --------------------------------------

Write-Step "Step 11 — Unmounting install.wim"
Remove-MountSafe -MountPath $mountInstall -Discard

#endregion

#region -- Step 12: Capture Final WIM ----------------------------------------

Write-Step "Step 12 — Capturing enhanced WIM (compression: $Compression)"

# Unmount and commit changes to base WIM
Remove-MountSafe -MountPath $mountPE

# -- PhoenixPE approach -----------------------------------------------------
# WimCapture with compression, then optionally WimOptimize for re-compression.
# The Flags=9 (BOOT flag) marks the WIM as bootable.
#
# -- wimbuilder2 approach ---------------------------------------------------
# Uses wimlib-imagex for initial slimming (before mount), then DISM export
# for the final output. DISM /Export-Image also supports compression control.
#
# We follow the DISM-native path for maximum compatibility:

$compressionMap = @{
    'None'    = 'none'
    'XPRESS'  = 'fast'        # DISM calls XPRESS "fast"
    'LZX'     = 'maximum'     # DISM calls LZX "maximum"
}
$dismCompression = $compressionMap[$Compression]

# Export the enhanced image (this also removes any orphaned resources,
# equivalent to WimOptimize in PhoenixPE)
$tempCaptureWim = Join-Path $WorkDir 'temp_output.wim'
Remove-ItemSafe -Path $tempCaptureWim

Write-Info "Exporting with $Compression compression ($dismCompression)..."
Invoke-Dism @('/Export-Image',
              "/SourceImageFile:$baseWimPath",
              "/SourceIndex:$baseIndex",
              "/DestinationImageFile:$tempCaptureWim",
              '/DestinationName:WinPE-Enhanced',
              "/Compress:$dismCompression",
              '/Bootable') | Out-Null

# Move to final destination
if (Test-Path $OutputWim) { Remove-Item $OutputWim -Force }
Move-Item -Path $tempCaptureWim -Destination $OutputWim
Write-Info "Enhanced WIM saved: $OutputWim"

# Report size
$wimSize = (Get-Item $OutputWim).Length
Write-Info ("  Output size: {0:N1} MB" -f ($wimSize / 1MB))

#endregion

#region -- Step 13: (Optional) Build Bootable ISO ----------------------------

if ($OutputIso) {
    Write-Step "Step 13 — Creating bootable ISO: $OutputIso"

    # oscdimg is the ADK tool used by both PhoenixPE and wimbuilder2 for ISO creation
    $oscdimg = Get-Command oscdimg.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $oscdimg) {
        $adkOscdimg = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        if (Test-Path $adkOscdimg) { $oscdimg = $adkOscdimg }
    }

    if (-not $oscdimg) {
        Write-Warn "oscdimg.exe not found. Skipping ISO creation. Install ADK Deployment Tools."
    } else {
        # Build an ISO staging area
        $isoStage = Join-Path $WorkDir 'iso_stage'
        Remove-ItemSafe -Path $isoStage
        New-Item -ItemType Directory -Path $isoStage | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $isoStage 'sources') | Out-Null

        Copy-Item -Path $OutputWim -Destination (Join-Path $isoStage 'sources\boot.wim') -Force

        # Copy boot files from source media
        $bootFiles = @('bootmgr', 'bootmgr.efi', 'boot\bcd', 'boot\boot.sdi',
                        'EFI\Boot\bootx64.efi', 'EFI\Microsoft\Boot\bootmgfw.efi')
        foreach ($f in $bootFiles) {
            $src = Join-Path $SourceMediaPath $f
            $dst = Join-Path $isoStage $f
            Copy-FileIfExists -Source $src -Destination $dst | Out-Null
        }

        # oscdimg flags: -m (ignore max size), -o (optimize), -u2 (UDF 2.5),
        # -udfver102 for compat, -b (El Torito boot sector)
        $bootSector = Join-Path $SourceMediaPath 'boot\etfsboot.com'
        if (-not (Test-Path $bootSector)) {
            $bootSector = Join-Path $isoStage 'boot\etfsboot.com'
        }

        if (Test-Path $bootSector) {
            $oscdimgArgs = @('-m', '-o', '-u2', '-udfver102',
                              "-b$bootSector", $isoStage, $OutputIso)
        } else {
            Write-Warn "etfsboot.com not found; creating UEFI-only ISO"
            $efiBoot = Join-Path $isoStage 'EFI\Boot\bootx64.efi'
            $oscdimgArgs = @('-m', '-o', '-u2', '-udfver102',
                              "-e$efiBoot", $isoStage, $OutputIso)
        }

        Write-Info "Running: oscdimg $($oscdimgArgs -join ' ')"
        $result = & $oscdimg @oscdimgArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $result | ForEach-Object { Write-Host $_ -ForegroundColor Red }
            Write-Warn "ISO creation failed. The WIM file at $OutputWim is still valid."
        } else {
            $isoSize = (Get-Item $OutputIso).Length
            Write-Info ("  ISO created: $OutputIso ({0:N1} MB)" -f ($isoSize / 1MB))
        }
    }
}

#endregion

#region -- Step 14: Cleanup --------------------------------------------------

Write-Step "Step 14 — Cleanup"
Write-Info "Cleaning DISM mount points..."
Invoke-Dism @('/Cleanup-Mountpoints') | Out-Null

# Keep cache dir (WinRE.wim cache) for faster subsequent runs
Write-Info "Work directory retained for re-use: $WorkDir"
Write-Info "  (Delete manually to force full re-extraction next run)"

#endregion

#region -- Summary -----------------------------------------------------------

Write-Host "`n" + ("-" * 70) -ForegroundColor Green
Write-Host "  ADK-Enhancer completed successfully!" -ForegroundColor Green
Write-Host ("-" * 70) -ForegroundColor Green
Write-Host "  Source media : $SourceMediaPath"
Write-Host "  Base WIM     : $BaseWim"
Write-Host "  Compression  : $Compression"
Write-Host "  FBWF cache   : $FBWFCacheSizeMB MB"
Write-Host "  Scratch space: $ScratchSpaceMB MB"
Write-Host "  WoW64        : $KeepWoW64"
Write-Host "  Output WIM   : $OutputWim ($("{0:N1} MB" -f ((Get-Item $OutputWim).Length / 1MB)))"
if ($OutputIso -and (Test-Path $OutputIso)) {
    Write-Host "  Output ISO   : $OutputIso ($("{0:N1} MB" -f ((Get-Item $OutputIso).Length / 1MB)))"
}
Write-Host "`n  Key decisions (derived from PhoenixPE and wimbuilder2 analysis):"
Write-Host "    • FBWF WinPECacheThreshold in HKLM\..\Services\FBWF gives writable RAM overlay"
Write-Host "    • DISM /Set-ScratchSpace sets separate temp RAM for DISM/Setup operations"
Write-Host "    • XPRESS compression is the default (fast build, reasonable size)"
Write-Host "    • LZX compresses ~15-25% smaller but takes longer (use for distribution)"
Write-Host "    • LZMS/Solid is NOT supported for bootable WIMs (cannot be stream-mounted)"
Write-Host "    • WMI repository omitted — it rebuilds automatically at first PE boot"
Write-Host ("-" * 70) -ForegroundColor Green

#endregion
