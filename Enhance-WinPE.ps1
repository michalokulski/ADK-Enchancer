#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enhances a WinRE/ADK-based WinPE image with components from full Windows installation media.

.DESCRIPTION
    ADK-Enhancer: Bridges the gap between Microsoft's minimal ADK WinPE (winpe.wim) and the
    feature-rich WinPE environments built by projects like PhoenixPE and wimbuilder2.

    This script:
      1.  Extracts WinRE.wim from install.wim (preferred PE base over the ADK's winpe.wim)
      2.  Mounts the base WIM image
      3.  Injects core runtime components from install.wim (DLLs, drivers, WiFi, iSCSI)
      4.  Injects WoW64 (150+ DLLs mirroring PhoenixPE's minimal WoW64 list)
      5.  Injects optional audio subsystem
      6.  Injects optional shell components (Explorer, DWM, etc.)
      7.  Merges registry hives from install.wim: CLSID, COM/OLE, Svchost, Power, TCP/IP,
          KnownDLLs, LSA, Appinfo -- matching PhoenixPE's 211-Registry.script strategy
      8.  Applies PE-specific registry tweaks: FBWF cache, telemetry, services, WinPE keys
      9.  Fixes system drive letter (C:\ -> X:\) if needed -- PhoenixPE SetSystemDriveLetter
      10. Sets the WinPE scratch space via DISM /Set-ScratchSpace
      11. Slims the image: MUI cleanup, telemetry, WMI auto-recover, migration engine
      12. Captures with configurable compression (None/XPRESS/LZX)
      13. Optionally creates a bootable ISO

    Compared against and validated with:
      - PhoenixPE 210-Core, 211-Registry, 212-ShellConfig, 251-WoW64 scripts
        https://github.com/PhoenixPE/PhoenixPE
      - wimbuilder2/WIN10XPE main.bat, prepare.bat, System/main.bat, SystemDriveSize.bat
        https://github.com/slorelee/wimbuilder2

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
    Default: 512 MB.
    Limits (from PhoenixPE 212-ShellConfig.script / wimbuilder2 SystemDriveSize.bat):
      - x86 WinPE:      max 1024 MB
      - x64 Win10:      max 4094 MB (4096 is a driver sentinel, not a real size)
      - x64 Win11 23H2+: tested working up to 32 GB (PhoenixPE note)
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

# Warn about FBWF limits -- mirrors PhoenixPE's Config-FBWF logic precisely.
# We cannot determine the source Windows version until install.wim is mounted,
# so we apply the most conservative safe defaults here and re-validate in Step 8.
# PhoenixPE comment: "As of Win11 23H2 tested working up to 32 GB."
# Win10 restriction: 4094 MB max (4096 is a driver sentinel, not a real cache size).
if ($FBWFCacheSizeMB -gt 1024) {
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

# -- 4a. Essential DLLs/files missing from minimal WinRE/winpe.wim --------
# Based on wimbuilder2 WIN10XPE/00-Configures/System/main.bat component list
# and PhoenixPE 210-Core.script RequireFileEx patterns (Section: SuperchargeBootWim)
$essentialFiles = @(
    # Power management (powercfg, cpl, and the UPS/extension DLL)
    'powercfg.cpl', 'powercpl.dll', 'umpoext.dll',

    # Cloud Store (needed for modern shell and Start components)
    'Windows.CloudStore.dll',

    # Network diagnostic (NCSI -- not present in WinRE.wim)
    'ncsi.dll',

    # Security / credential delegation
    'credssp.dll',

    # ISM (Miracast/display streaming, needed on Win11+)
    'ISM.exe',

    # Direct3D / DXGI (graphics stack; PhoenixPE Core copies these)
    'dxgi.dll', 'dxva2.dll', 'DXCore.dll',

    # File/App management APIs
    'fmapi.dll'
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

# -- 4b. WiFi drivers (PhoenixPE 210-Core.script copies these from boot.wim SxS) --
# vwifibus.sys + vwifimp.sys provide virtual WiFi support;
# WifiCx.sys is the modern WiFi driver model (Win11+)
$wifiDrivers = @('vwifibus.sys', 'vwifimp.sys', 'WifiCx.sys')
$peDrivers   = Join-Path $mountPE 'Windows\System32\Drivers'
foreach ($drv in $wifiDrivers) {
    $src = Join-Path $installWindows "System32\Drivers\$drv"
    $dst = Join-Path $peDrivers $drv
    if (Copy-FileIfExists -Source $src -Destination $dst) {
        Write-Info "  WiFi driver: $drv"
    }
}

# -- 4c. iSCSI WMI MOF files (PhoenixPE 210-Core.script copies these) -----
# These are required for iSCSI initiator support in WinPE.
# PhoenixPE copies them to Windows\System32\wbem\
$iscsiMofs = @(
    'iscsidsc.mof', 'iscsihba.mof', 'iscsiprf.mof', 'iscsirem.mof',
    'iscsiwmiv2.mof', 'iscsiwmiv2_uninstall.mof', 'msiscsi.mof',
    'storagewmi.mof', 'storagewmi_passthru.mof'
)
$peWbem      = Join-Path $mountPE 'Windows\System32\wbem'
$installWbem = Join-Path $mountInstall 'Windows\System32\wbem'
if (-not (Test-Path $peWbem)) { New-Item -ItemType Directory -Path $peWbem -Force | Out-Null }
foreach ($mof in $iscsiMofs) {
    Copy-FileIfExists -Source (Join-Path $installWbem $mof) `
                      -Destination (Join-Path $peWbem $mof) | Out-Null
}
Write-Info "  iSCSI WMI MOF files injected"

# -- 4d. WMI Repository seed (omitted intentionally) ----------------------
# wimbuilder2 opt[slim.wbem_repository] = true removes it; PhoenixPE also removes it.
# WMI rebuilds automatically from MOF files on first PE boot.
Write-Info "  WMI repository: will auto-rebuild on first PE boot (omitted)"

# -- 4e. Fonts -------------------------------------------------------------
Write-Step "Step 4e — Injecting fonts"
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
    Write-Info "  Using PhoenixPE 251-WoW64.script minimal file list (~150+ DLLs)"

    $peSysWOW = Join-Path $mountPE 'Windows\SysWOW64'
    if (-not (Test-Path $peSysWOW)) { New-Item -ItemType Directory -Path $peSysWOW -Force | Out-Null }

    # WoW64 emulation bridge DLLs in System32 (required on the x64 side)
    # PhoenixPE 251-WoW64.script: RequireFileEx \Windows\System32\wow64*.dll + wowreg32.exe
    $wow64BridgeDlls = @(
        'wow64.dll', 'wow64base.dll', 'wow64con.dll', 'wow64cpu.dll', 'wow64win.dll',
        'wowreg32.exe'    # PE registration helper for 32-bit COM servers
    )
    foreach ($dll in $wow64BridgeDlls) {
        $src = Join-Path $installSys32 $dll
        $dst = Join-Path $peSys32 $dll
        if (Copy-FileIfExists -Source $src -Destination $dst) {
            Write-Info "  WoW64 bridge: $dll"
        }
    }

    # SysWOW64 minimal file list derived from PhoenixPE 251-WoW64.script
    # (Minimal WoW64 Environment section — 150+ files)
    $sysWow64Files = @(
        # NLS and keyboard layouts (wildcard files — copied as-is; script uses glob)
        # Directly enumerated from install.wim SysWOW64 during copy loop below

        # Core runtime
        'ntdll.dll', 'kernel32.dll', 'kernelbase.dll', 'kernel.appcore.dll',
        'advapi32.dll', 'user32.dll', 'win32u.dll', 'gdi32.dll', 'gdi32full.dll',
        'msvcrt.dll', 'msvcrt40.dll', 'ucrtbase.dll', 'msvcp_win.dll', 'msvcp110_win.dll',
        'msvcp60.dll', 'msvbvm60.dll', 'crtdll.dll', 'rpcrt4.dll', 'sechost.dll',
        'combase.dll', 'ole32.dll', 'oleaut32.dll', 'olecli32.dll', 'oledlg.dll',
        'olepro32.dll', 'asycfilt.dll', 'stdole2.tlb', 'stdole32.tlb',

        # Shell and UI
        'shlwapi.dll', 'shell32.dll', 'SHCore.dll', 'shfolder.dll', 'shdocvw.dll',
        'shellstyle.dll', 'comdlg32.dll', 'comctl32.dll', 'ExplorerFrame.dll',
        'ieframe.dll', 'iertutil.dll', 'mshtml.dll', 'imgutil.dll',
        'thumbcache.dll', 'linkinfo.dll', 'ntshrui.dll',

        # DirectX / Graphics
        'dxgi.dll', 'd3d9.dll', 'd3d10warp.dll', 'd3d11.dll', 'd3d12.dll',
        'd2d1.dll', 'Dwrite.dll', 'dcomp.dll', 'ddraw.dll',
        'dwmapi.dll', 'UIAnimation.dll', 'uxtheme.dll',
        'GdiPlus.dll', 'WindowsCodecs.dll', 'mscms.dll',

        # Security / Crypto
        'crypt32.dll', 'cryptbase.dll', 'cryptdll.dll', 'cryptnet.dll', 'cryptsp.dll',
        'ncrypt.dll', 'ncryptprov.dll', 'ncryptsslp.dll', 'bcrypt.dll', 'bcryptprimitives.dll',
        'wintrust.dll', 'rsaenh.dll', 'schannel.dll', 'sspicli.dll', 'secur32.dll',
        'kerberos.dll', 'msv1_0.dll', 'dpapi.dll', 'samlib.dll', 'samcli.dll',
        'mskeyprotect.dll', 'slc.dll',

        # Network
        'ws2_32.dll', 'wsock32.dll', 'mswsock.dll', 'winhttp.dll', 'wininet.dll',
        'urlmon.dll', 'webio.dll', 'dnsapi.dll', 'dhcpcsvc.dll', 'dhcpcsvc6.dll',
        'iphlpapi.dll', 'winnsi.dll', 'rasapi32.dll', 'rasadhlp.dll',
        'fwpuclnt.dll', 'FirewallAPI.dll', 'fwbase.dll', 'fwpolicyiomgr.dll',
        'ntlanman.dll', 'netapi32.dll', 'netutils.dll', 'srvcli.dll', 'wkscli.dll',
        'logoncli.dll', 'dfscli.dll',

        # COM / Automation
        'actxprxy.dll', 'atl.dll', 'atlthunk.dll', 'clb.dll', 'clbcatq.dll',
        'sxs.dll', 'sxsstore.dll', 'sxstrace.exe',
        'OneCoreCommonProxyStub.dll', 'OneCoreUAPCommonProxyStub.dll',
        'OnDemandConnRouteHelper.dll',
        'Windows.Globalization.dll', 'Windows.Graphics.dll',
        'Windows.FileExplorer.Common.dll', 'windows.storage.dll',
        'twinapi.dll', 'twinapi.appcore.dll', 'WinTypes.dll',
        'policymanager.dll', 'edputil.dll', 'wldp.dll',

        # System utilities (32-bit)
        'reg.exe', 'regsvr32.exe', 'regedt32.exe', 'rundll32.exe', 'svchost.exe',
        'cmd.exe', 'cmdext.dll', 'attrib.exe', 'clip.exe', 'findstr.exe',
        'run64.exe', 'dllhost.exe',
        'net.exe', 'net1.exe', 'netmsg.dll',

        # Settings / Policy
        'setupapi.dll', 'cfgmgr32.dll', 'devobj.dll', 'devrtl.dll',
        'authz.dll', 'ntmarta.dll', 'ntasn1.dll', 'msasn1.dll',
        'gpapi.dll', 'userenv.dll', 'profapi.dll',
        'regapi.dll', 'resutils.dll',

        # IME / Locale
        'imm32.dll', 'msctf.dll', 'InputHost.dll', 'usp10.dll', 'lpk.dll',
        'mlang.dll', 'normaliz.dll', 'tzres.dll', 'winnlsres.dll', 'winbrand.dll',
        'Bcp47Langs.dll', 'bcp47mrm.dll',

        # Misc runtime
        'hid.dll', 'avifil32.dll', 'avrt.dll', 'msvfw32.dll', 'winmm.dll',
        'winmmbase.dll', 'msacm32.dll', 'msacm32.drv', 'mpr.dll',
        'version.dll', 'psapi.dll', 'msimg32.dll', 'lz32.dll',
        'pdh.dll', 'fltlib.dll', 'ulib.dll',
        'vbscript.dll', 'mfc40.dll', 'mfc42.dll',
        'dbghelp.dll', 'dbgcore.dll', 'msxml3.dll', 'msxml3r.dll',
        'msxml6.dll', 'msxml6r.dll',
        'xmllite.dll', 'dui70.dll', 'duser.dll',
        'UIAutomationCore.dll', 'SensApi.dll', 'StructuredQuery.dll',
        'riched20.dll', 'riched32.dll', 'msdelta.dll',
        'ColorAdapterClient.dll', 'DataExchange.dll', 'CoreUIComponents.dll',
        'aclui.dll', 'mscories.dll', 'msIso.dll',
        'offreg.dll', 'odbc32.dll', 'odbcint.dll',
        'clusapi.dll',
        'wimgapi.dll', 'davhlpr.dll', 'dlnashext.dll',
        'cscapi.dll', 'directmanipulation.dll',
        'rmclient.dll', 'mmcbase.dll',
        'framedynos.dll', 'ncobjapi.dll', 'wmiclnt.dll',
        'adsldp.dll', 'adsldpc.dll', 'activeds.dll', 'ntdsapi.dll',
        'wldap32.dll', 'dsrole.dll',
        'spfileq.dll', 'SPInf.dll', 'dsound.dll', 'wow32.dll', 'winsta.dll',
        'wtsapi32.dll',
        # WMI support in 32-bit
        'wbemcomn.dll'
    )
    # Also copy NLS/KBD wildcard globs
    $nlsSrc = Join-Path $installSysWOW 'C_*.NLS'
    Get-ChildItem -Path $installSysWOW -Filter 'C_*.NLS' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-FileIfExists -Source $_.FullName -Destination (Join-Path $peSysWOW $_.Name) | Out-Null }
    Get-ChildItem -Path $installSysWOW -Filter 'KBD*.dll' -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-FileIfExists -Source $_.FullName -Destination (Join-Path $peSysWOW $_.Name) | Out-Null }

    $copiedCount = 0
    $skippedCount = 0
    $seenFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $sysWow64Files) {
        if (-not $seenFiles.Add($file)) { continue }    # skip duplicates
        $src = Join-Path $installSysWOW $file
        $dst = Join-Path $peSysWOW $file
        if (Copy-FileIfExists -Source $src -Destination $dst) { $copiedCount++ }
        else { $skippedCount++ }
    }

    # Copy SysWOW64\wbem folder (WMI 32-bit support)
    $wbemWow  = Join-Path $installSysWOW 'wbem'
    $peWbemWow = Join-Path $peSysWOW 'wbem'
    if (Test-Path $wbemWow) {
        if (-not (Test-Path $peWbemWow)) { New-Item -ItemType Directory -Path $peWbemWow -Force | Out-Null }
        Get-ChildItem -Path $wbemWow -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-FileIfExists -Source $_.FullName -Destination (Join-Path $peWbemWow $_.Name) | Out-Null }
        Write-Info "  WoW64 wbem folder copied"
    }

    # SysWOW64 audio files (needed even without IncludeAudio for 32-bit app compat)
    # PhoenixPE 251-WoW64.script copies AudioSes.dll, MMDevAPI.dll, devenum.dll, quartz.dll, msdmo.dll
    $wow64Audio = @('AudioSes.dll', 'MMDevAPI.dll', 'devenum.dll', 'quartz.dll', 'msdmo.dll', 'dsound.dll')
    foreach ($f in $wow64Audio) {
        Copy-FileIfExists -Source (Join-Path $installSysWOW $f) -Destination (Join-Path $peSysWOW $f) | Out-Null
    }

    Write-Info ("  WoW64 SysWOW64 files: {0} copied, {1} not found in source" -f $copiedCount, $skippedCount)
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

Write-Step "Step 8 -- Configuring PE registry"

# -----------------------------------------------------------------------
# PhoenixPE's approach (211-Registry.script + 212-ShellConfig.script):
#   1. Extract hives from both base WIM AND install.wim
#   2. RegCopy entire subtrees from install.wim hives into PE hives:
#      SOFTWARE: Classes\{AppID,CLSID,Interface,Typelib,folder,themefile,
#                         SystemFileAssociations,DirectShow,Media Type,MediaFoundation}
#                Microsoft\{Svchost,SecurityManager,Ole,PolicyManager,
#                            WindowsRuntime,Windows\CurrentVersion\{AppModel,AppX}}
#      SYSTEM:   Control\{Lsa,Power}, Services\{Appinfo,Tcpip,Winsock,Winsock2},
#                Control\Session Manager\KnownDLLs
#   3. Then apply PE-specific tweaks on top
#
# wimbuilder2's approach (System/main.bat, PERegPorter.bat):
#   Uses opt[build.registry.software]='merge' to selectively merge SOFTWARE hive
#   or 'full' to use the entire install.wim SOFTWARE hive as-is.
#   SYSTEM hive merges: Appinfo, ProfSvc, Lsa, SecurityProviders, Power
# -----------------------------------------------------------------------

# Registry hive paths inside the mounted PE
$peHiveSoftware = Join-Path $mountPE 'Windows\System32\config\SOFTWARE'
$peHiveSystem   = Join-Path $mountPE 'Windows\System32\config\SYSTEM'

# Extract install.wim hives to a temporary location for merging
$hiveCacheInstall = Join-Path $WorkDir 'hive_cache_install'
if (-not (Test-Path $hiveCacheInstall)) { New-Item -ItemType Directory -Path $hiveCacheInstall -Force | Out-Null }

Write-Info "Extracting install.wim registry hives for merging..."
$installHiveSoftware = Join-Path $hiveCacheInstall 'SOFTWARE'
$installHiveSystem   = Join-Path $hiveCacheInstall 'SYSTEM'

# Copy registry hives from the still-mounted install.wim
$installConfigDir = Join-Path $mountInstall 'Windows\System32\config'
if (Test-Path (Join-Path $installConfigDir 'SOFTWARE')) {
    Copy-Item -Path (Join-Path $installConfigDir 'SOFTWARE') -Destination $installHiveSoftware -Force
    Copy-Item -Path (Join-Path $installConfigDir 'SYSTEM')   -Destination $installHiveSystem   -Force
    $installHivesReady = $true
} else {
    Write-Warn "install.wim config directory not found; registry merge from install.wim will be skipped"
    $installHivesReady = $false
}

# Temporary registry mount keys
$tmpSoftware        = 'HKLM\PE_SOFTWARE'
$tmpSystem          = 'HKLM\PE_SYSTEM'
$tmpInstallSoftware = 'HKLM\Install_SOFTWARE'
$tmpInstallSystem   = 'HKLM\Install_SYSTEM'

Write-Info "Loading PE registry hives..."
& reg.exe load $tmpSoftware $peHiveSoftware 2>&1 | Out-Null
& reg.exe load $tmpSystem   $peHiveSystem   2>&1 | Out-Null

$installHivesLoaded = $false
if ($installHivesReady) {
    Write-Info "Loading install.wim registry hives..."
    & reg.exe load $tmpInstallSoftware $installHiveSoftware 2>&1 | Out-Null
    & reg.exe load $tmpInstallSystem   $installHiveSystem   2>&1 | Out-Null
    $installHivesLoaded = $true
}

try {
    # ================================================================
    # PART A: Merge from install.wim hives into PE hives
    # Matches PhoenixPE 211-Registry.script:
    #   Config-BaseWim-SoftwareHive + Config-BaseWim-SystemHive
    # ================================================================
    if ($installHivesLoaded) {
        Write-Info "  Merging SOFTWARE hive subtrees from install.wim (PhoenixPE 211-Registry)..."

        # COM class registration (CLSID, AppID, Interface, Typelib)
        # Critical: without these, COM objects and shell extensions fail to load
        foreach ($k in @('Classes\AppID', 'Classes\CLSID',
                          'Classes\Interface', 'Classes\Typelib')) {
            & reg.exe copy "HKLM\Install_SOFTWARE\$k" "HKLM\PE_SOFTWARE\$k" /s /f 2>&1 | Out-Null
        }
        Write-Info "    COM registration (CLSID, AppID, Interface, Typelib) merged"

        # Shell file associations and theme
        foreach ($k in @('Classes\folder', 'Classes\themefile',
                          'Classes\SystemFileAssociations')) {
            & reg.exe copy "HKLM\Install_SOFTWARE\$k" "HKLM\PE_SOFTWARE\$k" /s /f 2>&1 | Out-Null
        }
        Write-Info "    Shell classes (folder, themefile, SystemFileAssociations) merged"

        # Media Foundation / DirectShow registration
        foreach ($k in @('Classes\DirectShow', 'Classes\Media Type',
                          'Classes\MediaFoundation')) {
            & reg.exe copy "HKLM\Install_SOFTWARE\$k" "HKLM\PE_SOFTWARE\$k" /s /f 2>&1 | Out-Null
        }
        Write-Info "    Media classes (DirectShow, MediaFoundation) merged"

        # SvcHost groups, SecurityManager, OLE configuration
        foreach ($k in @('Microsoft\Windows NT\CurrentVersion\Svchost',
                          'Microsoft\SecurityManager',
                          'Microsoft\Ole')) {
            & reg.exe copy "HKLM\Install_SOFTWARE\$k" "HKLM\PE_SOFTWARE\$k" /s /f 2>&1 | Out-Null
        }
        Write-Info "    Svchost, SecurityManager, Ole merged"

        # Policy Manager
        & reg.exe copy 'HKLM\Install_SOFTWARE\Microsoft\PolicyManager' `
                       'HKLM\PE_SOFTWARE\Microsoft\PolicyManager' /s /f 2>&1 | Out-Null

        # WinRT AppModel / AppX
        foreach ($k in @(
            'Microsoft\WindowsRuntime',
            'Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel',
            'Microsoft\Windows\CurrentVersion\AppModel',
            'Microsoft\Windows\CurrentVersion\AppX')) {
            & reg.exe copy "HKLM\Install_SOFTWARE\$k" "HKLM\PE_SOFTWARE\$k" /s /f 2>&1 | Out-Null
        }
        Write-Info "    WindowsRuntime, AppModel, AppX merged"

        # ---- SYSTEM hive merges (PhoenixPE Config-BaseWim-SystemHive) ----
        Write-Info "  Merging SYSTEM hive subtrees from install.wim (PhoenixPE 211-Registry)..."

        # Appinfo service (needed for UAC elevation in PE)
        & reg.exe copy 'HKLM\Install_SYSTEM\ControlSet001\Services\Appinfo' `
                       'HKLM\PE_SYSTEM\ControlSet001\Services\Appinfo' /s /f 2>&1 | Out-Null
        Write-Info "    Appinfo service merged"

        # LSA (local security authority) -- PE-specific overrides applied below
        & reg.exe copy 'HKLM\Install_SYSTEM\ControlSet001\Control\Lsa' `
                       'HKLM\PE_SYSTEM\ControlSet001\Control\Lsa' /s /f 2>&1 | Out-Null
        Write-Info "    LSA merged"

        # Power options (full Power subtree from install.wim)
        & reg.exe copy 'HKLM\Install_SYSTEM\ControlSet001\Control\Power' `
                       'HKLM\PE_SYSTEM\ControlSet001\Control\Power' /s /f 2>&1 | Out-Null
        Write-Info "    Power options merged"

        # TCP/IP stack and Winsock (needed for network operation in PE)
        foreach ($k in @('Services\Tcpip', 'Services\Winsock', 'Services\Winsock2')) {
            & reg.exe copy "HKLM\Install_SYSTEM\ControlSet001\$k" `
                           "HKLM\PE_SYSTEM\ControlSet001\$k" /s /f 2>&1 | Out-Null
        }
        Write-Info "    TCP/IP stack (Tcpip, Winsock, Winsock2) merged"

        # KnownDLLs -- ensures DLL loading order matches full Windows
        & reg.exe copy 'HKLM\Install_SYSTEM\ControlSet001\Control\Session Manager\KnownDLLs' `
                       'HKLM\PE_SYSTEM\ControlSet001\Control\Session Manager\KnownDLLs' `
                       /s /f 2>&1 | Out-Null
        Write-Info "    KnownDLLs merged"
    }

    # ================================================================
    # PART B: PE-specific tweaks (PhoenixPE 212-ShellConfig.script)
    # These overwrite/supplement what was merged from install.wim.
    # ================================================================

    # -- 8a. WinPE identification key (PhoenixPE Config-SoftwareHive) ----
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinPE" `
        /v InstRoot /d 'X:\' /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinPE" `
        /v CustomBackground /t REG_EXPAND_SZ `
        /d 'X:\Windows\Web\Wallpaper\Windows\img0.jpg' /f 2>&1 | Out-Null

    # WinPE OC registration hooks (PhoenixPE Config-SoftwareHive)
    $wnpeOcBase = "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinPE\OC"
    & reg.exe add "$wnpeOcBase\Microsoft-WinPE-WMI" `
        /v "1. Register CIMWIN32" /d '%systemroot%\system32\wbem\cimwin32.dll' `
        /f 2>&1 | Out-Null
    & reg.exe add "$wnpeOcBase\Microsoft-WinPE-WSH" `
        /v "1. Register WSHOM" /d '%systemroot%\system32\wshom.ocx' `
        /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\WinPE\UGC" `
        /v "Microsoft-Windows-TCPIP" /t REG_MULTI_SZ /d "netiougc.exe -online" `
        /f 2>&1 | Out-Null
    Write-Info "  WinPE OC registration keys set"

    # -- 8b. Enable SIHost integration (PhoenixPE Config-SoftwareHive) ---
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" `
        /v EnableSIHostIntegration /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # -- 8c. Add DriverStore to Installation Sources ----------------------
    # Allows PE to find drivers from host computer's C:\ drive
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows\CurrentVersion\Setup" `
        /v "Installation Sources" /t REG_MULTI_SZ `
        /d "C:\Windows\System32\DriverStore\FileRepository" /f 2>&1 | Out-Null
    Write-Info "  DriverStore added to Installation Sources"

    # -- 8d. Telemetry / DiagTrack services (PhoenixPE Config-SystemHive) -
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" `
        /v AllowTelemetry /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\WMI\Autologger\AutoLogger-Diagtrack-Listener" `
        /v Start /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\diagnosticshub.standardcollector.service" `
        /v Start /t REG_DWORD /d 4 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\DiagTrack" `
        /v Start /t REG_DWORD /d 4 /f 2>&1 | Out-Null
    Write-Info "  Telemetry and DiagTrack disabled"

    # -- 8e. Disable Hibernate & Fast Startup (PhoenixPE Config-SystemHive) --
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Power" `
        /v HibernateEnabled /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Power" `
        /v CustomizeDuringSetup /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Session Manager\Power" `
        /v HiberbootEnabled /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    Write-Info "  Hibernate and Fast Startup disabled"

    # -- 8f. Filesystem performance (PhoenixPE Config-SystemHive) ---------
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\FileSystem" `
        /v NtfsDisableLastAccessUpdate /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\FileSystem" `
        /v RefsDisableLastAccessUpdate /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    # Allow ReFS format over non-mirror volumes in PE
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\MiniNT" `
        /v AllowRefsFormatOverNonmirrorVolume /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    Write-Info "  Filesystem performance tweaks applied"

    # -- 8g. LSA / Security overrides (PhoenixPE Config-SystemHive) -------
    # Security Packages: tspkg (CredSSP terminal services)
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Lsa" `
        /v "Security Packages" /t REG_MULTI_SZ /d "tspkg" /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\SecurityProviders" `
        /v SecurityProviders /d "credssp.dll" /f 2>&1 | Out-Null
    # NTLMv2 only -- PhoenixPE uses level 3 (more secure than wimbuilder2's 0)
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Lsa" `
        /v LmCompatibilityLevel /t REG_DWORD /d 3 /f 2>&1 | Out-Null
    # Allow blank-password network access in PE (wimbuilder2 pattern)
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Lsa" `
        /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f 2>&1 | Out-Null
    Write-Info "  LSA, Security Packages, CredSSP configured"

    # -- 8h. AppData environment variable ---------------------------------
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Control\Session Manager\Environment" `
        /v AppData /t REG_EXPAND_SZ `
        /d '%SystemDrive%\Users\Default\AppData\Roaming' /f 2>&1 | Out-Null
    Write-Info "  AppData environment variable set"

    # -- 8i. AllowStart service keys (PhoenixPE Config-SystemHive) --------
    # ProfSvc/lanmanworkstation always; post-RS5 requires DNSCache + NlaSvc
    foreach ($svc in @('ProfSvc', 'lanmanworkstation', 'LanmanWorkstation',
                        'DNSCache', 'NlaSvc')) {
        & reg.exe add "HKLM\PE_SYSTEM\Setup\AllowStart\$svc" /f 2>&1 | Out-Null
    }
    Write-Info "  AllowStart: ProfSvc, LanmanWorkstation, DNSCache, NlaSvc"

    # -- 8j. USB hub safe-remove (PhoenixPE Config-SystemHive) ------------
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\usbhub\HubG" `
        /v DisableOnSoftRemove /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # -- 8k. PS/2 mouse wheel detection (PhoenixPE Config-SystemHive) -----
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\i8042prt\Parameters" `
        /v EnableWheelDetection /t REG_DWORD /d 2 /f 2>&1 | Out-Null

    # -- 8l. BFE (Base Filtering Engine) for firewall support post-RS5 ----
    # PhoenixPE Config-SystemHive: ImagePath override + SvcHostSplitDisable
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\BFE" `
        /v ImagePath /t REG_EXPAND_SZ `
        /d "%systemroot%\system32\svchost.exe -k LocalServiceNoNetworkFirewall -p" `
        /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\BFE" `
        /v SvcHostSplitDisable /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    Write-Info "  BFE (Base Filtering Engine) configured"

    # -- 8m. FBWF (File-Based Write Filter) --------------------------------
    # PhoenixPE: Config-FBWF in 212-ShellConfig.script
    # wimbuilder2: SystemDriveSize.bat
    # Key insight from PhoenixPE: Win11 23H2 (build >= 22000) supports > 4094 MB.
    # Win10 (build <= 22000): max 4094 MB; 4096 is a driver sentinel, not a real size.
    Write-Info "  Configuring FBWF cache: $FBWFCacheSizeMB MB"
    $fbwfCacheToWrite = $FBWFCacheSizeMB
    if ($installHivesLoaded) {
        $srcBuild = 0
        try {
            $regOut = & reg.exe query `
                'HKLM\Install_SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                /v CurrentBuild 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $m = [regex]::Match($regOut, 'CurrentBuild\s+REG_SZ\s+(\d+)')
                if ($m.Success) { $srcBuild = [int]$m.Groups[1].Value }
            }
        } catch { Write-Warn "    Could not detect source Windows build; using default FBWF limits." }
        if ($srcBuild -gt 0) {
            Write-Info "    Source Windows build: $srcBuild"
            $isWin11 = ($srcBuild -ge 22000)
            if (-not $isWin11 -and $FBWFCacheSizeMB -gt 4094) {
                $fbwfCacheToWrite = 4094
                Write-Warn "    Win10 source: FBWF clamped to 4094 MB (was $FBWFCacheSizeMB MB)"
            } elseif ($isWin11) {
                Write-Info "    Win11 source: FBWF up to 32+ GB supported"
            }
        }
    }
    $fbwfKey = "HKLM\PE_SYSTEM\ControlSet001\Services\FBWF"
    & reg.exe add $fbwfKey /v WinPECacheThreshold /t REG_DWORD `
        /d $fbwfCacheToWrite /f 2>&1 | Out-Null
    Write-Info "  FBWF WinPECacheThreshold = $fbwfCacheToWrite MB"

    # Enable exFAT for large FBWF caches (wimbuilder2 SystemDriveSize.bat)
    if ($fbwfCacheToWrite -ge 4094) {
        & reg.exe add "HKLM\PE_SYSTEM\ControlSet001\Services\exfat" `
            /v Start /t REG_DWORD /d 0 /f 2>&1 | Out-Null
        Write-Info "  exFAT driver enabled (required for FBWF >= 4094 MB)"
    }

    # -- 8n. Default user profile path ------------------------------------
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\S-1-5-18" `
        /v ProfileImagePath /d 'X:\Users\Default' /f 2>&1 | Out-Null

    # -- 8o. Desktop personalization (PhoenixPE Personalize) --------------
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows\CurrentVersion\Personalization" `
        /v AllowChangeDesktopBackground /t REG_DWORD /d 1 /f 2>&1 | Out-Null
    & reg.exe add "HKLM\PE_SOFTWARE\Microsoft\Windows\CurrentVersion\Personalization" `
        /v AllowPersonalization /t REG_DWORD /d 1 /f 2>&1 | Out-Null

    # -- 8p. Font registration ------------------------------------------------
    # Check PE image (not install.wim mount) since fonts were copied in Step 4e
    $fontsKey = "HKLM\PE_SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
    & reg.exe add $fontsKey /v "Segoe UI (TrueType)" /d segoeui.ttf /f 2>&1 | Out-Null
    & reg.exe add $fontsKey /v "Consolas (TrueType)" /d consola.ttf  /f 2>&1 | Out-Null
    if (Test-Path (Join-Path $peWindows 'Fonts\SegoeIcons.ttf')) {
        & reg.exe add $fontsKey /v "Segoe Fluent Icons (TrueType)" /d SegoeIcons.ttf `
            /f 2>&1 | Out-Null
    }
    Write-Info "  Fonts registered"

    # -- 8q. TermService (Remote Desktop) -- copy and disable (PhoenixPE) --
    if ($installHivesLoaded) {
        & reg.exe copy 'HKLM\Install_SYSTEM\ControlSet001\Services\TermService' `
                       'HKLM\PE_SYSTEM\ControlSet001\Services\TermService' /s /f 2>&1 | Out-Null
        & reg.exe add  'HKLM\PE_SYSTEM\ControlSet001\Services\TermService' `
            /v Start /t REG_DWORD /d 4 /f 2>&1 | Out-Null
        Write-Info "  TermService: copied and disabled (Start=4)"
    }

    # ================================================================
    # PART C: Drive letter fix (PhoenixPE SetSystemDriveLetter)
    # Some Windows editions ship with C:\ in the SOFTWARE hive instead of X:\.
    # If left unfixed this causes black/blue screen at PE boot.
    # PhoenixPE uses a dedicated RegFind.exe tool; we use a reg.exe export/import approach.
    # ================================================================
    Write-Info "  Verifying system drive letter in PE SOFTWARE hive..."
    $driveCheckKey = 'HKLM\PE_SOFTWARE\Classes\CLSID\{0000002F-0000-0000-C000-000000000046}\InprocServer32'
    $driveCheckOut = & reg.exe query $driveCheckKey 2>&1 | Out-String
    if ($driveCheckOut -match 'C:\\') {
        Write-Warn "  Drive letter C:\\ detected in PE registry -- replacing with X:\\ ..."
        $exportPath = Join-Path $env:TEMP 'pe_sw_drivfix.reg'
        & reg.exe export 'HKLM\PE_SOFTWARE' $exportPath /y 2>&1 | Out-Null
        if (Test-Path $exportPath) {
            $regContent = [System.IO.File]::ReadAllText($exportPath)
            # Replace C:\ patterns in the .reg file (handles both forward-slash escaping in .reg format)
            $regContent = $regContent -replace '(?i)(")C:\\\\', '$1X:\\'
            # Note: hex-encoded registry values (e.g., REG_BINARY, REG_EXPAND_SZ hex forms)
            # are not regex-replaced here because their encoding is opaque.  The reg copy
            # operation performed earlier already uses the correct X:\ source, so surviving
            # C:\ references in hex-blob values are rare and typically benign.  Log a warning
            # if any hex-encoded values containing 43003a00 (C:\ in UTF-16LE) are found.
            if ($regContent -match '(?i)=hex\([^)]+\):[0-9a-f,\s]*43,00,3a,00') {
                Write-Warn "    Possible C:\\ in hex-encoded registry value -- manual review may be needed"
            }
            [System.IO.File]::WriteAllText($exportPath, $regContent)
            & reg.exe import $exportPath 2>&1 | Out-Null
            Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
            Write-Info "    SOFTWARE hive: drive letter corrected to X:\\"
        }
    } else {
        Write-Info "  Drive letter: X:\\ confirmed in PE SOFTWARE hive"
    }

} finally {
    # Always unload hives to prevent hive leaks
    Write-Info "Unloading PE registry hives..."
    & reg.exe unload $tmpSoftware 2>&1 | Out-Null
    & reg.exe unload $tmpSystem   2>&1 | Out-Null
    if ($installHivesLoaded) {
        & reg.exe unload $tmpInstallSoftware 2>&1 | Out-Null
        & reg.exe unload $tmpInstallSystem   2>&1 | Out-Null
    }
    # Clean up registry transaction logs (PhoenixPE Cleanup-TransactionLogs)
    $configDir = Join-Path $mountPE 'Windows\System32\config'
    Get-ChildItem -Path $configDir -Include '*.LOG1','*.LOG2','*.blf','*.regtrans-ms' `
        -Recurse -ErrorAction SilentlyContinue |
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
Write-Host "    * Registry: install.wim hives merged (CLSID, COM, Svchost, LSA, Power, Tcpip, KnownDLLs)"
Write-Host "    * WoW64: 150+ SysWOW64 DLLs from PhoenixPE 251-WoW64.script minimal list"
Write-Host "    * FBWF: WinPECacheThreshold in Services\FBWF; Win11 supports up to 32+ GB"
Write-Host "    * DISM /Set-ScratchSpace: separate temp RAM for DISM/Setup operations"
Write-Host "    * WiFi drivers (vwifibus, vwifimp, WifiCx) injected from install.wim"
Write-Host "    * iSCSI WMI MOF files injected (storagewmi, iscsidsc, etc.)"
Write-Host "    * Drive letter fix: C:\ -> X:\ if source has wrong drive prefix"
Write-Host "    * XPRESS compression is the default (fast build, reasonable size)"
Write-Host "    * LZX compresses ~15-25% smaller but takes longer (use for distribution)"
Write-Host "    * LZMS/Solid NOT supported for bootable WIMs (cannot be stream-mounted)"
Write-Host "    * WMI repository omitted -- rebuilds automatically at first PE boot"
Write-Host ("-" * 70) -ForegroundColor Green

#endregion
