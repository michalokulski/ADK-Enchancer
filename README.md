# ADK-Enhancer

## Overview

ADK-Enhancer is a project aimed at bridging the gap between Microsoft's Windows Assessment and Deployment Kit (ADK) WinPE and the richer WinPE environments achievable using full Windows installation media. This repository documents research into why mature WinPE build systems prefer full installation media and outlines how the ADK-based approach can be enhanced.

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

---

## References

- [PhoenixPE Repository](https://github.com/PhoenixPE/PhoenixPE) — WinPE build framework using PEBakery; source config in `Projects/PhoenixPE/100-ConfigSource.script`, core build in `Projects/PhoenixPE/Core/210-Core.script`
- [slorelee/wimbuilder2 Repository](https://github.com/slorelee/wimbuilder2) — WinPE build framework; ADK components in `Projects/WIN10XPE/01-ADK_OCs/` (developer/optional), full-media workflow in `Projects/WIN10XPE/main.bat`
- [Microsoft ADK Documentation](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
- [WinPE Optional Components Reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/winpe-add-packages--optional-components-reference)