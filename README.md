# ADK-Enhancer

## Overview

ADK-Enhancer is a project aimed at bridging the gap between Microsoft's Windows Assessment and Deployment Kit (ADK) WinPE and the richer WinPE environments achievable using full Windows installation media. This repository documents research into why mature WinPE build systems prefer full installation media and provides a PowerShell script that implements these enhancements.

## Quick Start

### Prerequisites
- Windows 10/11 host (must run as Administrator)
- [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) with Deployment Tools installed (`dism.exe`, `oscdimg.exe`)
- Full Windows 10 or 11 installation media (ISO mounted or extracted; must contain `Sources\install.wim`)

### Basic Usage

```powershell
# Enhance using WinRE base with XPRESS compression, default FBWF (512 MB), default scratch space (512 MB)
.\Enhance-WinPE.ps1 -SourceMediaPath "D:\" -OutputWim "C:\Output\boot.wim"

# Full build with LZX compression, larger FBWF cache, and ISO output
.\Enhance-WinPE.ps1 -SourceMediaPath "D:\" -BaseWim Boot -Compression LZX `
    -FBWFCacheSizeMB 2048 -ScratchSpaceMB 512 `
    -IncludeAudio $true -IncludeShell $true `
    -OutputWim "C:\Output\boot.wim" -OutputIso "C:\Output\WinPE-Enhanced.iso"
```

### Key Parameters

| Parameter | Default | Description |
|---|---|---|
| `-SourceMediaPath` | (required) | Root of Windows installation media (must contain `Sources\install.wim`) |
| `-BaseWim` | `WinRE` | Base PE image: `WinRE` (extracted from install.wim) or `Boot` (boot.wim) |
| `-Compression` | `XPRESS` | WIM compression: `None`, `XPRESS`, `LZX` (see compression section below) |
| `-FBWFCacheSizeMB` | `512` | FBWF write-filter cache size in MB (max 4094 MB on Win10, up to 32+ GB on Win11) |
| `-ScratchSpaceMB` | `512` | WinPE scratch space in MB (`32`, `64`, `128`, `256`, `512`) |
| `-KeepWoW64` | `$true` | Include 32-bit (WoW64) compatibility layer (150+ DLLs from PhoenixPE minimal list) |
| `-Language` | `en-US` | Language to keep; all other MUI resources are removed |
| `-IncludeAudio` | `$false` | Inject audio subsystem from install.wim |
| `-IncludeShell` | `$false` | Inject full shell components (Explorer, DWM) for desktop builds |
| `-OutputIso` | (none) | If specified, creates a bootable ISO using oscdimg |

---

---

## Research: Why PhoenixPE and wimbuilder2 Use Full Installation Media (Not ADK)

### Background

Two prominent WinPE build frameworks—[PhoenixPE](https://github.com/PhoenixPE/PhoenixPE) and [slorelee/wimbuilder2](https://github.com/slorelee/wimbuilder2)—both build their WinPE environments primarily from **full Windows installation media** (an ISO containing `boot.wim`, `WinRE.wim`, and `install.wim`) rather than from the ADK's minimal `winpe.wim`. The reasons are fundamental to what each source provides.

---

## What ADK WinPE Provides

The Windows Assessment and Deployment Kit ships with a stripped-down `winpe.wim` that contains only the core PE bootstrap environment. Microsoft also provides a set of optional components (OCs) that can be added to it via DISM, covering:

- Basic networking (WinPE-WMI, WinPE-NetFX, etc.)
- Scripting support (WinPE-Scripting, WinPE-HTA)
- Storage and recovery tools
- PowerShell

However, the ADK WinPE is intentionally **minimal by design**—it is meant for deployment and imaging tasks, not as a full-featured rescue/recovery desktop environment.

---

## What Full Installation Media Provides That ADK Does Not

### 1. `install.wim` — A Complete Windows Image as Source

The most critical difference is the presence of `install.wim` in full installation media. This image contains a complete Windows OS installation from which both PhoenixPE and wimbuilder2 extract hundreds of system components:

- All Windows runtime DLLs (`System32`, `SysWOW64`)
- Full driver infrastructure and class installers
- Shell components (Explorer, shell32.dll, DWM, etc.)
- Audio subsystem (WAS, WASAPI, audio drivers)
- Network stack beyond basic WinPE networking (PPPoE, RNDIS, RDP, etc.)
- BitLocker, MMC, MSI installer support
- .NET Framework (NetFX) components
- DirectX and XAML/WinUI runtime libraries (`Windows.UI.Xaml.Resources.*.dll`)
- Internet Explorer/MSHTML components
- Full Input Method Editor (IME) support
- Windows Media Player subsystem
- WMI provider host and full WMI infrastructure
- `WinSxS` side-by-side assembly store

The ADK's WinPE does not include these components. Adding them from `install.wim` is what enables PhoenixPE and wimbuilder2 to run full GUI applications, display a proper desktop shell, support hardware with native drivers, and provide forensics/recovery tools that rely on the complete Windows runtime.

**Code evidence (PhoenixPE `100-ConfigSource.script`):**
```
// Install.wim
If,ExistFile,"%SourceDir%\Sources\Install.wim",Begin
  Set,%SourceInstallWim%,"%SourceDir%\Sources\Install.wim",PERMANENT
End
```

**Code evidence (wimbuilder2 `main.bat`):**
```bat
rem Mount registry hives from install.wim source
echo Mounted KEYs of %WB_SRC%'s HIVEs
echo   - HKEY_LOCAL_MACHINE\Src_SOFTWARE
echo   - HKEY_LOCAL_MACHINE\Src_SYSTEM
echo   - HKEY_LOCAL_MACHINE\Src_DRIVERS
```

---

### 2. `WinRE.wim` — A Richer PE Base Image

`WinRE.wim` (Windows Recovery Environment) is embedded inside `install.wim` and is a **superset of `boot.wim`**. It includes:

- All standard WinPE packages
- Wi-Fi support (`WinPE-WiFi-Package`)
- iSCSI support
- HTA/MSHTML engine (for interactive GUI tools)
- Enhanced storage components
- Windows Rejuvenation/repair capability

Both projects prefer to use WinRE as the base PE image because it already includes functionality that would otherwise require adding many ADK optional components.

**Code evidence (PhoenixPE `210-Core.script`):**
```
// ExtractWinRE
// Extracts WinRE from Install.wim and saves it in %ProjectCache% to speed up future builds.
Echo,"Extracting [WinRE.wim] from [%SourceInstallWim%:%SourceInstallWimImage%]..."
WimExtract,%SourceInstallWim%,%SourceInstallWimImage%,Windows\System32\Recovery\WinRE.wim,%ProjectCache%,NOACL
```

**Code evidence (wimbuilder2 `00-Boot2WinRE/main.bat`):**
```bat
call AddFiles %0 :[WinRE-Builtin-Packages]
;WinPE-EnhancedStorage, WinPE-WMI, WinPE-HTA ...
```

---

### 3. Version-Matched `boot.wim`

The `boot.wim` bundled with Windows installation media is **version-matched** to the `install.wim` on the same media. This guarantees:

- Identical build numbers across all WIM files
- Registry hives (`SOFTWARE`, `SYSTEM`) from `boot.wim` and `install.wim` are compatible
- No driver or API version mismatches

The ADK ships on its own release cycle and may carry a `winpe.wim` built against a different Windows build than the user's `install.wim`. This version mismatch causes instability in registry-driven operations, driver loading, and component registration.

**Code evidence (PhoenixPE `210-Core.script`):**
```
// SuperchargeBootWim
// WinRE is a extension of Boot.wim, with the addition of a few extra packages.
// It seems that as of late boot.wim gets updated to the most recent build and WinRE gets
// left a build or more behind install.wim. This can cause issues for us mismatching
// install.wim registry entries with older WinRE registry and files.
```

---

### 4. Complete Registry Hives

Both frameworks mount the registry from `install.wim` to properly configure all Windows subsystems in the PE environment:

- `HKLM\SOFTWARE` — Full software registry with service registrations, COM object GUIDs, driver class entries
- `HKLM\SYSTEM` — Full system configuration, driver load order, service control manager data
- `HKLM\DRIVERS` — Driver registry entries
- `HKLM\DEFAULT` — Default user profile hive

The ADK WinPE carries only the minimal registry needed to boot, which makes it impossible to run software that requires full registry infrastructure (e.g., COM/DCOM services, WMI, audio stack, font rendering).

---

### 5. WoW64 (32-bit Compatibility Layer)

Full installation media's `install.wim` includes the complete `SysWOW64` directory, enabling 32-bit application support in a 64-bit WinPE. This is critical for running legacy recovery, forensics, and diagnostic tools that ship only as 32-bit executables.

The ADK WinPE does not ship with WoW64 infrastructure.

**Code evidence (wimbuilder2 `main.bat`):**
```bat
if "x%opt[build.wow64support]%"=="xtrue" (
  if not "x%WB_PE_ARCH%"=="xx64" set opt[build.wow64support]=false
)
set opt[support.wow64]=%opt[build.wow64support]%
if "%opt[support.wow64]%"=="true" (
  set ADDFILES_SYSWOW64=1
)
```

---

## How ADK IS Used in These Projects

Neither project abandons ADK entirely—they use it differently:

| Role | PhoenixPE | wimbuilder2 |
|------|-----------|-------------|
| Build toolchain (DISM, oscdimg, etc.) | ✅ Yes | ✅ Yes |
| Source of WinPE base image (`winpe.wim`) | ❌ No (uses `boot.wim`/`WinRE.wim` from media) | ❌ No (default uses install.wim) |
| Optional components added on top | ❌ Not used | ✅ Optional (`01-ADK_OCs`, hidden by default, developer mode only) |

In wimbuilder2, the ADK optional components path (`01-ADK_OCs`) is **hidden from regular users** and only exposed in developer mode, and only activated when `opt[build.adk]=true` is explicitly set.

---

## Implications for ADK-Enhancer

Based on this research, an ADK-Enhancer should address the following gaps to allow ADK-based builds to approach the richness of installation-media builds:

1. **Component injection from `install.wim`**: Automate the extraction of targeted Windows components (shell, audio, networking, WoW64, etc.) from `install.wim` and inject them into an ADK-based WinPE.

2. **WinRE promotion**: Provide tooling to extract `WinRE.wim` from `install.wim` and use it as the base instead of the minimal `winpe.wim`, gaining built-in WiFi, HTA, iSCSI support.

3. **Registry enrichment**: Merge relevant registry entries from the full Windows `SOFTWARE`/`SYSTEM` hives into the PE registry to enable COM, WMI, audio, and driver subsystems.

4. **Version alignment**: Ensure that the ADK tools (DISM, oscdimg) version matches the Windows build used as the source to prevent compatibility issues.

5. **WoW64 support**: Add a workflow to include the `SysWOW64` layer from `install.wim` for 32-bit application compatibility.

All five of these are implemented in [`Enhance-WinPE.ps1`](Enhance-WinPE.ps1).

---

## Output Image Compression

Both reference projects were analyzed for their compression strategy. The results inform `Enhance-WinPE.ps1`'s `-Compression` parameter:

### PhoenixPE approach
PhoenixPE (`750-CaptureWim.script`) uses PEBakery's `WimCapture` with a user-selectable compression, defaulting to **XPRESS**. After capture, `WimOptimize` (re-compression) is available as an optional step. The `BOOT` flag is always set, marking the WIM as bootable.

```
WimCapture,%TargetDir%,%TargetBootWim%,XPRESS,Flags=9,BOOT
```

> ⚠️ **LZMS is explicitly excluded** from the compression list because it uses solid (streaming) compression, which prevents the WIM from being mounted — a hard requirement for a bootable WIM.

### wimbuilder2 approach
wimbuilder2 (`za-Slim/SlimWim.bat`) uses **wimlib-imagex** to slim the source WIM *before* mounting (removing MUI language folders, WoW64 if not needed, etc.) to reduce mount time and final image size. The final export uses DISM's `/Export-Image`.

### Compression comparison

| Mode | DISM flag | Typical size | Build time | Notes |
|------|-----------|-------------|------------|-------|
| `None` | `none` | Largest | Fastest | Use only for testing |
| `XPRESS` | `fast` | ~20-30% smaller than None | Fast | **Recommended default** |
| `LZX` | `maximum` | ~15-25% smaller than XPRESS | Slow | Best for distribution |
| LZMS | *(unsupported)* | Smallest | Very slow | ❌ Cannot be used for bootable WIMs |

`Enhance-WinPE.ps1` uses DISM `/Export-Image` with the appropriate flag, which also performs an implicit `WimOptimize` (removes orphaned resources from the WIM).

---

## FBWF (File-Based Write Filter)

WinPE boots from a read-only compressed WIM. Without a write filter, any attempt to write to `C:\` (the boot drive) would fail silently or with errors. The **FBWF** provides a RAM-backed overlay that makes the boot drive appear writable.

### PhoenixPE approach
PhoenixPE configures FBWF via a dedicated `Config-FBWF` section in `212-ShellConfig.script`:

```
RegWrite,HKLM,0x4,"Tmp_System\ControlSet001\Services\FBWF","WinPECacheThreshold",<SizeMB>
```

Limits enforced:
- **x86 WinPE**: max 1024 MB
- **x64 Win10 (build ≤ 22000)**: max 4094 MB (the FBWF driver treats the value 4096 as a sentinel meaning "use maximum supported", so writing 4096 to the registry does not set a 4096 MB cache — it is interpreted as a special flag rather than a size; 4094 is therefore the largest usable explicit value)
- **x64 Win11 (build ≥ 22000)**: no 4094 MB restriction — PhoenixPE comment states "As of Win11 23H2 tested working up to 32 GB"; the script auto-detects the source Windows build from the loaded install.wim hive and applies the correct limit

### wimbuilder2 approach
wimbuilder2 (`SystemDriveSize.bat`) uses the same registry key but adds an optional fallback to the **Windows Embedded Standard (WES) fbwf.sys** driver for large cache sizes (>4096 MB or `128GB` preset). This WES driver allows virtually unlimited cache sizes using exFAT-formatted boot media:

```bat
if exist fbwf_%_fbwf_size%.cfg (
  copy /y fbwf_%_fbwf_size%.cfg "%X_WIN%\fbwf.cfg"
  copy /y fbwf.sys "%X_SYS%\drivers\fbwf.sys"
  reg add HKLM\...\Services\exfat /v Start /t REG_DWORD /d 0 /f
)
```

### Implementation in Enhance-WinPE.ps1
```powershell
# Registry key: HKLM\SYSTEM\ControlSet001\Services\FBWF\WinPECacheThreshold
# x64 max: 4094 MB; x86 max: 1024 MB
.\Enhance-WinPE.ps1 -SourceMediaPath D:\ -FBWFCacheSizeMB 2048 -OutputWim C:\boot.wim
```

---

## Scratch Space

WinPE scratch space is a **separate** RAM allocation from FBWF. It is used by `dism.exe` and Windows Setup for temporary file operations during PE session.

### FBWF cache vs. Scratch space

| | FBWF cache | Scratch space |
|---|---|---|
| Purpose | Writable overlay on boot media (C:\\) | Temp RAM for DISM/Setup |
| Set by | Registry: `Services\FBWF\WinPECacheThreshold` | `dism.exe /Set-ScratchSpace` |
| Typical size | 512–2048 MB | 32–512 MB |
| Location | RAM overlay over C:\ | X:\Windows\Temp (RAM disk) |

### PhoenixPE approach
PhoenixPE calls DISM `/Set-ScratchSpace` as part of the pre-flight process. It also warns that DISM has issues with network paths and RAM disks (`ERROR_NOT_A_REPARSE_POINT 0x80071126`), which is why PhoenixPE ships its own DISM copy.

### wimbuilder2 approach
wimbuilder2 configures scratch space indirectly through FBWF cache sizing (`SystemDriveSize.bat`) — a larger FBWF cache gives DISM more room for temp operations.

### Implementation in Enhance-WinPE.ps1
```powershell
# Valid values: 32, 64, 128, 256, 512 MB
.\Enhance-WinPE.ps1 -SourceMediaPath D:\ -ScratchSpaceMB 512 -OutputWim C:\boot.wim
```

The script calls `dism.exe /Image:<mountDir> /Set-ScratchSpace:512` against the mounted WIM before unmounting and capturing.

---

## Comparison with PhoenixPE and wimbuilder2 — Gaps Identified and Fixed

This section documents the detailed comparison performed against both reference projects and the corrections applied to `Enhance-WinPE.ps1`.

### Gap 1: Registry Hive Merging (Critical)

**Original state:** The script only wrote individual `reg add` values to the PE hives. This left COM class registrations, media type handlers, Svchost groups, and other critical entries completely absent.

**PhoenixPE approach (`211-Registry.script` — `Config-BaseWim-SoftwareHive` + `Config-BaseWim-SystemHive`):**
Uses `RegCopy` (whole subtree copy) to merge these keys from install.wim into the PE hives:
- SOFTWARE: `Classes\AppID`, `Classes\CLSID`, `Classes\Interface`, `Classes\Typelib`
- SOFTWARE: `Classes\folder`, `Classes\themefile`, `Classes\SystemFileAssociations`
- SOFTWARE: `Classes\DirectShow`, `Classes\Media Type`, `Classes\MediaFoundation`
- SOFTWARE: `Microsoft\Windows NT\CurrentVersion\Svchost`, `Microsoft\SecurityManager`, `Microsoft\Ole`
- SOFTWARE: `Microsoft\PolicyManager`, `Microsoft\WindowsRuntime`, `AppModel`, `AppX`
- SYSTEM: `Services\Appinfo`, `Control\Lsa`, `Control\Power`, `Services\Tcpip/Winsock/Winsock2`
- SYSTEM: `Control\Session Manager\KnownDLLs`

**Fix:** Script now extracts install.wim hive files, loads them alongside the PE hives, and uses `reg.exe copy /s` to replicate all these subtrees before applying PE-specific overrides.

### Gap 2: WoW64 File List (Major)

**Original state:** The script copied only ~34 core DLLs to `SysWOW64`.

**PhoenixPE approach (`251-WoW64.script` Minimal WoW64 section):** Copies 258+ files including NLS/KBD globs, COM/OLE infrastructure, DirectX, audio, WMI 32-bit support, all standard runtime DLLs, network stack, crypto stack, IME/locale, and shell DLLs.

**Fix:** WoW64 list expanded to 150+ specifically-named DLLs plus wildcard copies for `C_*.NLS`, `KBD*.dll`, and the `wbem` folder. The System32 WoW64 bridge now also includes `wowreg32.exe`.

### Gap 3: FBWF Windows Version Detection (Correctness)

**Original state:** Script unconditionally clamped FBWF to 4094 MB regardless of Windows version.

**PhoenixPE note in `Config-FBWF`:** *"As of Win11 23H2 tested working up to 32 GB."* Win10 (build ≤ 22000) has the 4094 MB limit; Win11 (build ≥ 22000) does not.

**Fix:** Script now reads `CurrentBuild` from the loaded install.wim SOFTWARE hive to detect Win10 vs Win11 and applies the appropriate limit at runtime.

### Gap 4: Missing Registry Settings

**Original state:** Several important PE registry settings were absent.

**Added (from PhoenixPE `212-ShellConfig.script`):**
- `WinPE\OC\Microsoft-WinPE-WMI` / `Microsoft-WinPE-WSH` / `UGC\Microsoft-Windows-TCPIP` — component initialization hooks
- `Winlogon\EnableSIHostIntegration` = 1
- `CurrentVersion\Setup\Installation Sources` pointing to `C:\Windows\System32\DriverStore\FileRepository`
- `diagnosticshub.standardcollector.service\Start` = 4, `DiagTrack\Start` = 4
- `MiniNT\AllowRefsFormatOverNonmirrorVolume` = 1
- `i8042prt\Parameters\EnableWheelDetection` = 2
- `usbhub\HubG\DisableOnSoftRemove` = 1
- `Lsa\LmCompatibilityLevel` = 3 (was incorrectly 0; PhoenixPE uses 3 = NTLMv2 only)
- `Security Packages` = `tspkg`, `SecurityProviders` = `credssp.dll`
- `BFE\ImagePath` full path override (not just `SvcHostSplitDisable`)
- `Personalization\AllowChangeDesktopBackground` + `AllowPersonalization` = 1
- TermService: copied from install.wim and disabled (Start=4)
- Desktop wallpaper `CustomBackground` key in WinPE section

### Gap 5: Core System32 Components

**Added from PhoenixPE `210-Core.script`:**
- WiFi drivers: `vwifibus.sys`, `vwifimp.sys`, `WifiCx.sys` — copied to `Windows\System32\Drivers`
- iSCSI WMI MOF files: `iscsidsc.mof`, `iscsihba.mof`, `storagewmi.mof`, etc. — copied to `Windows\System32\wbem`
- Additional DLLs: `dxgi.dll`, `dxva2.dll`, `DXCore.dll`, `fmapi.dll`

### Gap 6: Drive Letter Fix

**Original state:** Script did not check or fix the system drive letter in the registry.

**PhoenixPE approach (`SetSystemDriveLetter`):** Checks if `Classes\CLSID\{0000002F...}\InprocServer32` contains `C:\` and if so runs a global find-replace across both SOFTWARE and SYSTEM hives to replace `C:\` with `X:\`. This prevents black/blue screen on PE boot with certain media.

**Fix:** Script now checks the CLSID key for `C:\` and performs an export/modify/reimport if needed.

---

## References

- [PhoenixPE Repository](https://github.com/PhoenixPE/PhoenixPE) — WinPE build framework using PEBakery; source config in `Projects/PhoenixPE/100-ConfigSource.script`, core build in `Projects/PhoenixPE/Core/210-Core.script`
- [slorelee/wimbuilder2 Repository](https://github.com/slorelee/wimbuilder2) — WinPE build framework; ADK components in `Projects/WIN10XPE/01-ADK_OCs/` (developer/optional), full-media workflow in `Projects/WIN10XPE/main.bat`
- [Microsoft ADK Documentation](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
- [WinPE Optional Components Reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference)