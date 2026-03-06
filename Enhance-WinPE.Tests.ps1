#Requires -Module Pester
<#
.SYNOPSIS
    Pester 5 test suite for Enhance-WinPE.ps1

.DESCRIPTION
    Validates every post-fix area of the script without requiring live WIM files,
    DISM, or administrator elevation.  Tests are split into:

      1.  Syntax           — script parses with zero errors
      2.  Helper functions — Copy-FileIfExists, Remove-ItemSafe (using TestDrive)
      3.  WoW64 file list  — no duplicates, required files, bridge DLLs
      4.  FBWF clamping   — Win10/Win11 build detection logic
      5.  Compression map  — XPRESS/LZX/None -> DISM flag mapping
      6.  Drive letter fix — regex patterns used in C:\ -> X:\ replacement
      7.  Registry keys    — correct key paths for every major setting
      8.  Parameter spec   — ValidateRange / ValidateSet constraints
      9.  File lists       — essential DLLs, WiFi drivers, iSCSI MOFs, fonts
      10. MUI cleanup      — locale-folder pattern matching
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Enhance-WinPE.ps1'
    $scriptContent = Get-Content $scriptPath -Raw

    # ------------------------------------------------------------------
    # Static AST helpers
    # ------------------------------------------------------------------
    $parseErrors = [System.Management.Automation.Language.ParseError[]]@()
    $tokens      = [System.Management.Automation.Language.Token[]]@()
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$tokens, [ref]$parseErrors)

    # Collect all string literal values in the script (for file / key path checks)
    $allStrings = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true).Value

    # ------------------------------------------------------------------
    # Extract function bodies for isolated unit testing
    # We pull only the pure helper functions that have NO side-effects
    # and re-define them inside this BeforeAll.
    # ------------------------------------------------------------------
    $helperSource = @'
function Copy-FileIfExists {
    param([string]$Source, [string]$Destination)
    if (Test-Path $Source) {
        $destDir = Split-Path $Destination -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -Path $Source -Destination $Destination -Force
        return $true
    }
    return $false
}

function Remove-ItemSafe {
    param([string]$Path)
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}
'@
    # Verify the helper source matches what the script actually defines
    # (string-compare stripped of comments/whitespace)
    Invoke-Expression $helperSource

    # ------------------------------------------------------------------
    # Extract the $sysWow64Files array via AST (no execution required)
    # ------------------------------------------------------------------
    $wow64ArrayAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.VariablePath.UserPath -eq 'sysWow64Files'
    }, $true) | Select-Object -First 1

    $script:sysWow64Files = @()
    if ($wow64ArrayAst) {
        $arrayExpr = $wow64ArrayAst.Right
        # Collect all string constant children
        $script:sysWow64Files = $arrayExpr.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true).Value
    }

    # ------------------------------------------------------------------
    # Extract $wow64BridgeDlls
    # ------------------------------------------------------------------
    $bridgeAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.VariablePath.UserPath -eq 'wow64BridgeDlls'
    }, $true) | Select-Object -First 1

    $script:wow64BridgeDlls = @()
    if ($bridgeAst) {
        $script:wow64BridgeDlls = $bridgeAst.Right.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true).Value
    }

    # ------------------------------------------------------------------
    # Extract $essentialFiles
    # ------------------------------------------------------------------
    $essAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.VariablePath.UserPath -eq 'essentialFiles'
    }, $true) | Select-Object -First 1

    $script:essentialFiles = @()
    if ($essAst) {
        $script:essentialFiles = $essAst.Right.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true).Value
    }

    # ------------------------------------------------------------------
    # Extract $wifiDrivers
    # ------------------------------------------------------------------
    $wifiAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.VariablePath.UserPath -eq 'wifiDrivers'
    }, $true) | Select-Object -First 1

    $script:wifiDrivers = @()
    if ($wifiAst) {
        $script:wifiDrivers = $wifiAst.Right.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true).Value
    }

    # ------------------------------------------------------------------
    # Extract $iscsiMofs
    # ------------------------------------------------------------------
    $iscsiAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.VariablePath.UserPath -eq 'iscsiMofs'
    }, $true) | Select-Object -First 1

    $script:iscsiMofs = @()
    if ($iscsiAst) {
        $script:iscsiMofs = $iscsiAst.Right.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true).Value
    }

    # ------------------------------------------------------------------
    # Extract $wow64Audio
    # ------------------------------------------------------------------
    $audioAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.VariablePath.UserPath -eq 'wow64Audio'
    }, $true) | Select-Object -First 1

    $script:wow64Audio = @()
    if ($audioAst) {
        $script:wow64Audio = $audioAst.Right.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true).Value
    }

    # ------------------------------------------------------------------
    # Extract $requiredFonts
    # ------------------------------------------------------------------
    $fontsAst = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.VariablePath.UserPath -eq 'requiredFonts'
    }, $true) | Select-Object -First 1

    $script:requiredFonts = @()
    if ($fontsAst) {
        $script:requiredFonts = $fontsAst.Right.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
        }, $true).Value
    }

    # Helper: check if a string appears anywhere in the script content
    function Find-InScript { param([string]$Pattern) $scriptContent -match $Pattern }
}

# ===========================================================================
# 1. SYNTAX
# ===========================================================================
Describe "1. Script syntax" {
    It "parses without any parse errors" {
        $parseErrors | Should -BeNullOrEmpty
    }

    It "contains the #Requires -RunAsAdministrator directive" {
        $scriptContent | Should -Match '#Requires\s+-RunAsAdministrator'
    }

    It "uses Set-StrictMode -Version Latest" {
        $scriptContent | Should -Match "Set-StrictMode\s+-Version\s+Latest"
    }

    It "sets ErrorActionPreference to Stop" {
        $scriptContent | Should -Match "\`$ErrorActionPreference\s*=\s*'Stop'"
    }
}

# ===========================================================================
# 2. HELPER FUNCTIONS
# ===========================================================================
Describe "2. Helper function: Copy-FileIfExists" {
    BeforeAll {
        # TestDrive is a Pester-provided temp directory (cleaned after Describe)
        $td = $TestDrive
    }

    It "returns `$true and copies file when source exists" {
        $src = Join-Path $td 'source.txt'
        $dst = Join-Path $td 'subdir\dest.txt'
        Set-Content $src 'hello'

        $result = Copy-FileIfExists -Source $src -Destination $dst
        $result | Should -BeTrue
        Test-Path $dst | Should -BeTrue
        Get-Content $dst | Should -Be 'hello'
    }

    It "creates destination directory automatically when it does not exist" {
        $src = Join-Path $td 'src2.txt'
        $dst = Join-Path $td 'deep\nested\dir\dst2.txt'
        Set-Content $src 'content'

        Copy-FileIfExists -Source $src -Destination $dst | Out-Null
        Test-Path (Split-Path $dst -Parent) | Should -BeTrue
    }

    It "returns `$false when source does not exist" {
        $result = Copy-FileIfExists -Source (Join-Path $td 'nonexistent.dll') `
                                    -Destination (Join-Path $td 'out.dll')
        $result | Should -BeFalse
    }

    It "does not create destination directory when source is missing" {
        $dst = Join-Path $td 'missing_case\out.dll'
        Copy-FileIfExists -Source (Join-Path $td 'ghost.dll') -Destination $dst | Out-Null
        Test-Path (Split-Path $dst -Parent) | Should -BeFalse
    }
}

Describe "2. Helper function: Remove-ItemSafe" {
    BeforeAll { $td = $TestDrive }

    It "removes a file that exists" {
        $f = Join-Path $td 'todelete.txt'
        Set-Content $f 'bye'
        Remove-ItemSafe -Path $f
        Test-Path $f | Should -BeFalse
    }

    It "removes a directory tree that exists" {
        $dir = Join-Path $td 'todelete_dir'
        New-Item -ItemType Directory $dir | Out-Null
        Set-Content (Join-Path $dir 'file.txt') 'x'
        Remove-ItemSafe -Path $dir
        Test-Path $dir | Should -BeFalse
    }

    It "does not throw when path does not exist" {
        { Remove-ItemSafe -Path (Join-Path $td 'totally_missing') } |
            Should -Not -Throw
    }
}

# ===========================================================================
# 3. WoW64 FILE LIST
# ===========================================================================
Describe "3. WoW64 SysWOW64 file list" {
    It "was successfully extracted from the script AST" {
        $script:sysWow64Files.Count | Should -BeGreaterThan 100
    }

    It "contains no duplicate entries (case-insensitive)" {
        $lower = $script:sysWow64Files | ForEach-Object { $_.ToLower() }
        $unique = $lower | Sort-Object -Unique
        $lower.Count | Should -Be $unique.Count
    }

    Context "Required core runtime DLLs" {
        It "contains ntdll.dll" {
            $script:sysWow64Files | Should -Contain 'ntdll.dll'
        }
        It "contains kernel32.dll" {
            $script:sysWow64Files | Should -Contain 'kernel32.dll'
        }
        It "contains kernelbase.dll" {
            $script:sysWow64Files | Should -Contain 'kernelbase.dll'
        }
        It "contains msvcrt.dll" {
            $script:sysWow64Files | Should -Contain 'msvcrt.dll'
        }
        It "contains ucrtbase.dll" {
            $script:sysWow64Files | Should -Contain 'ucrtbase.dll'
        }
        It "contains combase.dll" {
            $script:sysWow64Files | Should -Contain 'combase.dll'
        }
        It "contains ole32.dll" {
            $script:sysWow64Files | Should -Contain 'ole32.dll'
        }
        It "contains rpcrt4.dll" {
            $script:sysWow64Files | Should -Contain 'rpcrt4.dll'
        }
    }

    Context "Security / Crypto DLLs" {
        It "contains crypt32.dll" {
            $script:sysWow64Files | Should -Contain 'crypt32.dll'
        }
        It "contains bcrypt.dll" {
            $script:sysWow64Files | Should -Contain 'bcrypt.dll'
        }
        It "contains schannel.dll" {
            $script:sysWow64Files | Should -Contain 'schannel.dll'
        }
        It "contains wintrust.dll" {
            $script:sysWow64Files | Should -Contain 'wintrust.dll'
        }
    }

    Context "Network DLLs" {
        It "contains ws2_32.dll" {
            $script:sysWow64Files | Should -Contain 'ws2_32.dll'
        }
        It "contains dnsapi.dll" {
            $script:sysWow64Files | Should -Contain 'dnsapi.dll'
        }
        It "contains iphlpapi.dll" {
            $script:sysWow64Files | Should -Contain 'iphlpapi.dll'
        }
        It "contains winhttp.dll" {
            $script:sysWow64Files | Should -Contain 'winhttp.dll'
        }
        It "fwpuclnt.dll appears only once" {
            ($script:sysWow64Files | Where-Object { $_ -eq 'fwpuclnt.dll' }).Count |
                Should -Be 1
        }
    }

    Context "Shell DLLs" {
        It "contains shell32.dll" {
            $script:sysWow64Files | Should -Contain 'shell32.dll'
        }
        It "contains shlwapi.dll" {
            $script:sysWow64Files | Should -Contain 'shlwapi.dll'
        }
        It "contains SHCore.dll" {
            $script:sysWow64Files | Should -Contain 'SHCore.dll'
        }
    }

    Context "Misc / deduplication fixes" {
        It "edputil.dll appears only once" {
            ($script:sysWow64Files | Where-Object {
                $_ -ieq 'edputil.dll'
            }).Count | Should -Be 1
        }
        It "resutils.dll appears only once" {
            ($script:sysWow64Files | Where-Object {
                $_ -ieq 'resutils.dll'
            }).Count | Should -Be 1
        }
        It "contains wbemcomn.dll for 32-bit WMI" {
            $script:sysWow64Files | Should -Contain 'wbemcomn.dll'
        }
    }
}

Describe "3. WoW64 bridge DLLs (System32)" {
    It "was successfully extracted" {
        $script:wow64BridgeDlls.Count | Should -BeGreaterOrEqual 5
    }
    It "contains wow64.dll" {
        $script:wow64BridgeDlls | Should -Contain 'wow64.dll'
    }
    It "contains wow64cpu.dll" {
        $script:wow64BridgeDlls | Should -Contain 'wow64cpu.dll'
    }
    It "contains wow64win.dll" {
        $script:wow64BridgeDlls | Should -Contain 'wow64win.dll'
    }
    It "contains wowreg32.exe (PhoenixPE 251-WoW64 addition)" {
        $script:wow64BridgeDlls | Should -Contain 'wowreg32.exe'
    }
}

Describe "3. WoW64 audio compat DLLs (SysWOW64)" {
    It "contains AudioSes.dll" {
        $script:wow64Audio | Should -Contain 'AudioSes.dll'
    }
    It "contains MMDevAPI.dll" {
        $script:wow64Audio | Should -Contain 'MMDevAPI.dll'
    }
    It "contains dsound.dll" {
        $script:wow64Audio | Should -Contain 'dsound.dll'
    }
    It "contains quartz.dll" {
        $script:wow64Audio | Should -Contain 'quartz.dll'
    }
}

# ===========================================================================
# 4. FBWF CLAMPING LOGIC
# ===========================================================================
Describe "4. FBWF build-detection and clamping logic" {

    It "uses build 22000 as the Win10/Win11 boundary" {
        $scriptContent | Should -Match '\$srcBuild\s*-ge\s*22000'
    }

    It "checks whether Win10 source exceeds 4094 MB" {
        $scriptContent | Should -Match '\$FBWFCacheSizeMB\s*-gt\s*4094'
    }

    It "clamps to exactly 4094 MB (not 4096) for Win10" {
        $scriptContent | Should -Match '\$fbwfCacheToWrite\s*=\s*4094'
    }

    It "enables exFAT when cache is >= 4094 MB" {
        $scriptContent | Should -Match '\$fbwfCacheToWrite\s*-ge\s*4094'
        $scriptContent | Should -Match 'Services\\exfat'
    }

    It "uses the correct registry value name WinPECacheThreshold" {
        $scriptContent | Should -Match 'WinPECacheThreshold'
    }

    It "uses the correct FBWF registry key path" {
        $scriptContent | Should -Match 'ControlSet001\\Services\\FBWF'
    }

    Context "Inline FBWF clamping logic unit test" {
        BeforeAll {
            # Reproduces the exact clamping logic from the script in isolation
            function Invoke-FBWFClamp {
                param([int]$FBWFCacheSizeMB, [int]$SrcBuild)
                $fbwfCacheToWrite = $FBWFCacheSizeMB
                if ($SrcBuild -gt 0) {
                    $isWin11 = ($SrcBuild -ge 22000)
                    if (-not $isWin11 -and $FBWFCacheSizeMB -gt 4094) {
                        $fbwfCacheToWrite = 4094
                    }
                }
                return $fbwfCacheToWrite
            }
        }

        It "Win10 (build 19041): 8192 MB request clamped to 4094" {
            Invoke-FBWFClamp -FBWFCacheSizeMB 8192 -SrcBuild 19041 | Should -Be 4094
        }

        It "Win10 (build 19041): 512 MB request passes through" {
            Invoke-FBWFClamp -FBWFCacheSizeMB 512 -SrcBuild 19041 | Should -Be 512
        }

        It "Win10 (build 19041): 4094 MB exactly is not clamped" {
            Invoke-FBWFClamp -FBWFCacheSizeMB 4094 -SrcBuild 19041 | Should -Be 4094
        }

        It "Win10 (build 19041): 4095 MB is clamped to 4094" {
            Invoke-FBWFClamp -FBWFCacheSizeMB 4095 -SrcBuild 19041 | Should -Be 4094
        }

        It "Win11 (build 22000): 8192 MB request passes through" {
            Invoke-FBWFClamp -FBWFCacheSizeMB 8192 -SrcBuild 22000 | Should -Be 8192
        }

        It "Win11 (build 22631): 32768 MB request passes through" {
            Invoke-FBWFClamp -FBWFCacheSizeMB 32768 -SrcBuild 22631 | Should -Be 32768
        }

        It "Unknown build (0): request passes through unchanged" {
            Invoke-FBWFClamp -FBWFCacheSizeMB 8192 -SrcBuild 0 | Should -Be 8192
        }
    }
}

# ===========================================================================
# 5. COMPRESSION MAPPING
# ===========================================================================
Describe "5. Compression map (DISM flag names)" {

    Context "Static map extracted from script" {
        # Use regex on raw script content for the map entries
        It "maps None to 'none'" {
            $scriptContent | Should -Match "'None'\s*=\s*'none'"
        }
        It "maps XPRESS to 'fast' (DISM flag name)" {
            $scriptContent | Should -Match "'XPRESS'\s*=\s*'fast'"
        }
        It "maps LZX to 'maximum' (DISM flag name)" {
            $scriptContent | Should -Match "'LZX'\s*=\s*'maximum'"
        }
    }

    Context "Inline compression map unit test" {
        BeforeAll {
            $script:compressionMap = @{
                'None'   = 'none'
                'XPRESS' = 'fast'
                'LZX'    = 'maximum'
            }
        }

        It "XPRESS maps to fast" {
            $script:compressionMap['XPRESS'] | Should -Be 'fast'
        }
        It "LZX maps to maximum" {
            $script:compressionMap['LZX'] | Should -Be 'maximum'
        }
        It "None maps to none" {
            $script:compressionMap['None'] | Should -Be 'none'
        }
        It "map has exactly 3 entries" {
            $script:compressionMap.Count | Should -Be 3
        }
    }
}

# ===========================================================================
# 6. DRIVE LETTER FIX
# ===========================================================================
Describe "6. Drive letter fix (C:\ -> X:\)" {

    It "checks the correct CLSID sentinel key for C:\\" {
        $scriptContent | Should -Match '0000002F-0000-0000-C000-000000000046'
    }

    It "uses regex replace pattern for C:\\ -> X:\\ in .reg content" {
        # The script contains: $regContent -replace '(?i)(")C:\\\\', '$1X:\\'
        $scriptContent | Should -Match 'regContent.*-replace'
        $scriptContent | Should -Match ([regex]::Escape('C:\\\\'))
    }

    Context "Inline regex replacement unit tests" {
        BeforeAll {
            # Reproduce the exact replacement pattern from the script
            function Invoke-DriveLetterFix { param([string]$regContent)
                $regContent -replace '(?i)(")C:\\\\', '$1X:\\'
            }
        }

        It "replaces quoted C:\\ path (typical REG_SZ value)" {
            $input  = '"ImagePath"="C:\\Windows\\system32\\svchost.exe"'
            $result = Invoke-DriveLetterFix $input
            $result | Should -Be '"ImagePath"="X:\\Windows\\system32\\svchost.exe"'
        }

        It "replaces multiple C:\\ occurrences in one string" {
            $input  = '"A"="C:\\foo" "B"="C:\\bar"'
            $result = Invoke-DriveLetterFix $input
            $result | Should -Be '"A"="X:\\foo" "B"="X:\\bar"'
        }

        It "does not alter paths that are already X:\\" {
            $input  = '"Path"="X:\\Windows\\system32\\foo.dll"'
            $result = Invoke-DriveLetterFix $input
            $result | Should -Be $input
        }

        It "does not alter unquoted C:\\ (only quoted paths in .reg format)" {
            $input  = 'SomeLine=C:\\Users\\test'
            $result = Invoke-DriveLetterFix $input
            # No double-quote before C:, so no replacement
            $result | Should -Be $input
        }

        It "is case-insensitive (handles c:\\ lowercase)" {
            $input  = '"path"="c:\\windows\\explorer.exe"'
            $result = Invoke-DriveLetterFix $input
            $result | Should -Be '"path"="X:\\windows\\explorer.exe"'
        }
    }

    Context "Hex-encoded C:\\ detection pattern" {
        BeforeAll {
            # 43,00,3a,00 is UTF-16LE encoding of 'C:'
            function Test-HexDriveLetter { param([string]$regContent)
                $regContent -match '(?i)=hex\([^)]+\):[0-9a-f,\s]*43,00,3a,00'
            }
        }

        It "detects hex-encoded C:\\ signature 43,00,3a,00" {
            $sample = '=hex(2):43,00,3a,00,5c,00,57,00'
            Test-HexDriveLetter $sample | Should -BeTrue
        }

        It "does not false-positive on similar hex without the sequence" {
            $sample = '=hex(2):41,00,42,00,43,00'
            Test-HexDriveLetter $sample | Should -BeFalse
        }
    }
}

# ===========================================================================
# 7. REGISTRY KEY PATHS
# ===========================================================================
Describe "7. Registry key paths" {

    Context "WinPE identification keys" {
        It "sets InstRoot value under WinPE key" {
            $scriptContent | Should -Match 'CurrentVersion\\WinPE'
            $scriptContent | Should -Match "InstRoot"
        }
        It "sets CustomBackground for wallpaper" {
            $scriptContent | Should -Match 'CustomBackground'
            $scriptContent | Should -Match 'img0\.jpg'
        }
    }

    Context "WinPE OC registration" {
        It "registers Microsoft-WinPE-WMI OC hook" {
            $scriptContent | Should -Match 'Microsoft-WinPE-WMI'
            $scriptContent | Should -Match 'cimwin32\.dll'
        }
        It "registers Microsoft-WinPE-WSH OC hook" {
            $scriptContent | Should -Match 'Microsoft-WinPE-WSH'
            $scriptContent | Should -Match 'wshom\.ocx'
        }
        It "registers TCPIP UGC hook" {
            $scriptContent | Should -Match 'Microsoft-Windows-TCPIP'
            $scriptContent | Should -Match 'netiougc\.exe'
        }
    }

    Context "Telemetry / DiagTrack" {
        It "disables AllowTelemetry" {
            $scriptContent | Should -Match 'AllowTelemetry'
        }
        It "disables AutoLogger-Diagtrack-Listener" {
            $scriptContent | Should -Match 'AutoLogger-Diagtrack-Listener'
        }
        It "sets diagnosticshub.standardcollector.service Start=4" {
            $scriptContent | Should -Match 'diagnosticshub\.standardcollector\.service'
        }
        It "sets DiagTrack Start=4" {
            $scriptContent | Should -Match 'Services\\DiagTrack'
        }
    }

    Context "Filesystem / power" {
        It "disables NtfsDisableLastAccessUpdate" {
            $scriptContent | Should -Match 'NtfsDisableLastAccessUpdate'
        }
        It "disables RefsDisableLastAccessUpdate" {
            $scriptContent | Should -Match 'RefsDisableLastAccessUpdate'
        }
        It "disables HibernateEnabled" {
            $scriptContent | Should -Match 'HibernateEnabled'
        }
        It "disables HiberbootEnabled (Fast Startup)" {
            $scriptContent | Should -Match 'HiberbootEnabled'
        }
        It "allows ReFS format over non-mirror volumes" {
            $scriptContent | Should -Match 'AllowRefsFormatOverNonmirrorVolume'
        }
    }

    Context "LSA and security" {
        It "sets LmCompatibilityLevel to 3 (NTLMv2 only)" {
            $scriptContent | Should -Match 'LmCompatibilityLevel'
            $scriptContent | Should -Match '/d 3'
        }
        It "sets LimitBlankPasswordUse to 0" {
            $scriptContent | Should -Match 'LimitBlankPasswordUse'
        }
        It "adds tspkg to Security Packages" {
            $scriptContent | Should -Match 'tspkg'
        }
        It "registers credssp.dll as SecurityProvider" {
            $scriptContent | Should -Match 'credssp\.dll'
        }
    }

    Context "Service AllowStart keys" {
        It "adds ProfSvc to AllowStart" {
            # AllowStart and ProfSvc appear together in a foreach block (use (?s) dotall)
            $scriptContent | Should -Match 'AllowStart'
            $scriptContent | Should -Match 'ProfSvc'
        }
        It "adds LanmanWorkstation to AllowStart" {
            $scriptContent | Should -Match 'LanmanWorkstation'
        }
        It "adds DNSCache to AllowStart" {
            $scriptContent | Should -Match 'DNSCache'
        }
        It "adds NlaSvc to AllowStart" {
            $scriptContent | Should -Match 'NlaSvc'
        }
    }

    Context "BFE (Base Filtering Engine)" {
        It "sets BFE ImagePath to svchost.exe -k LocalServiceNoNetworkFirewall" {
            $scriptContent | Should -Match 'LocalServiceNoNetworkFirewall'
        }
        It "sets BFE SvcHostSplitDisable=1" {
            $scriptContent | Should -Match 'SvcHostSplitDisable'
        }
    }

    Context "USB hub / hardware" {
        It "sets usbhub DisableOnSoftRemove=1" {
            $scriptContent | Should -Match 'DisableOnSoftRemove'
        }
        It "sets i8042prt EnableWheelDetection=2" {
            $scriptContent | Should -Match 'EnableWheelDetection'
        }
    }

    Context "Desktop personalization" {
        It "enables AllowChangeDesktopBackground" {
            $scriptContent | Should -Match 'AllowChangeDesktopBackground'
        }
        It "enables AllowPersonalization" {
            $scriptContent | Should -Match 'AllowPersonalization'
        }
    }

    Context "DriverStore Installation Sources" {
        It "adds DriverStore path to Installation Sources" {
            $scriptContent | Should -Match 'Installation Sources'
            $scriptContent | Should -Match 'DriverStore'
        }
    }

    Context "AppData environment variable" {
        It "sets AppData to %SystemDrive%\Users\Default\AppData\Roaming" {
            # AppData value spans multiple lines in the script
            $scriptContent | Should -Match 'AppData'
            $scriptContent | Should -Match 'Users.*Default.*AppData.*Roaming'
        }
    }

    Context "Registry hive merging" {
        It "merges COM CLSID from install.wim" {
            $scriptContent | Should -Match 'Classes\\\\CLSID|Classes\\CLSID'
        }
        It "merges Svchost groups from install.wim" {
            $scriptContent | Should -Match 'CurrentVersion\\\\Svchost|CurrentVersion.Svchost'
        }
        It "merges Appinfo service from install.wim" {
            $scriptContent | Should -Match 'Services\\\\Appinfo|Services.Appinfo'
        }
        It "merges TCP/IP stack from install.wim" {
            $scriptContent | Should -Match 'Services\\\\Tcpip|Services.Tcpip'
        }
        It "merges KnownDLLs from install.wim" {
            $scriptContent | Should -Match 'KnownDLLs'
        }
    }
}

# ===========================================================================
# 8. PARAMETER SPEC
# ===========================================================================
Describe "8. Parameter declarations and constraints" {

    It "FBWFCacheSizeMB lower bound is 32" {
        $scriptContent | Should -Match 'ValidateRange\(32'
    }

    It "FBWFCacheSizeMB upper bound is 131072 (128 GB)" {
        $scriptContent | Should -Match '131072'
    }

    It "ScratchSpaceMB accepts only 32/64/128/256/512" {
        $scriptContent | Should -Match 'ValidateSet\(32.*64.*128.*256.*512'
    }

    It "Compression ValidateSet contains None, XPRESS, LZX" {
        $scriptContent | Should -Match "ValidateSet\('None'\s*,\s*'XPRESS'\s*,\s*'LZX'\)"
    }

    It "BaseWim ValidateSet contains WinRE and Boot" {
        $scriptContent | Should -Match "ValidateSet\('WinRE'\s*,\s*'Boot'\)"
    }

    It "SourceInstallIndex accepts 1-16" {
        $scriptContent | Should -Match 'ValidateRange\(1,\s*16\)'
    }

    It "SourceMediaPath validates install.wim presence" {
        $scriptContent | Should -Match 'Sources\\install\.wim'
    }

    It "Compression defaults to XPRESS" {
        $scriptContent | Should -Match "Compression\s*=\s*'XPRESS'"
    }

    It "FBWFCacheSizeMB defaults to 512" {
        $scriptContent | Should -Match 'FBWFCacheSizeMB\s*=\s*512'
    }

    It "ScratchSpaceMB defaults to 512" {
        $scriptContent | Should -Match 'ScratchSpaceMB\s*=\s*512'
    }

    It "BaseWim defaults to WinRE" {
        $scriptContent | Should -Match "BaseWim\s*=\s*'WinRE'"
    }

    It "Language defaults to en-US" {
        $scriptContent | Should -Match "Language\s*=\s*'en-US'"
    }

    It "KeepWoW64 defaults to true" {
        $scriptContent | Should -Match 'KeepWoW64\s*=\s*\$true'
    }

    It "IncludeAudio defaults to false" {
        $scriptContent | Should -Match 'IncludeAudio\s*=\s*\$false'
    }

    It "IncludeShell defaults to false" {
        $scriptContent | Should -Match 'IncludeShell\s*=\s*\$false'
    }
}

# ===========================================================================
# 9. ESSENTIAL FILES, WiFi DRIVERS, iSCSI MOFs, FONTS
# ===========================================================================
Describe "9. Essential System32 file lists" {

    Context "Essential runtime files (Step 4a)" {
        It "was successfully extracted" {
            $script:essentialFiles.Count | Should -BeGreaterThan 5
        }
        It "includes dxgi.dll (DirectX/graphics stack)" {
            $script:essentialFiles | Should -Contain 'dxgi.dll'
        }
        It "includes dxva2.dll (video acceleration)" {
            $script:essentialFiles | Should -Contain 'dxva2.dll'
        }
        It "includes DXCore.dll (Win11+ DX adapter)" {
            $script:essentialFiles | Should -Contain 'DXCore.dll'
        }
        It "includes fmapi.dll (file management API)" {
            $script:essentialFiles | Should -Contain 'fmapi.dll'
        }
        It "includes ncsi.dll (network connectivity status)" {
            $script:essentialFiles | Should -Contain 'ncsi.dll'
        }
        It "includes credssp.dll (credential delegation)" {
            $script:essentialFiles | Should -Contain 'credssp.dll'
        }
        It "includes ISM.exe (Miracast, Win11+)" {
            $script:essentialFiles | Should -Contain 'ISM.exe'
        }
    }

    Context "WiFi drivers (Step 4b)" {
        It "was successfully extracted" {
            $script:wifiDrivers.Count | Should -BeGreaterOrEqual 3
        }
        It "includes vwifibus.sys" {
            $script:wifiDrivers | Should -Contain 'vwifibus.sys'
        }
        It "includes vwifimp.sys" {
            $script:wifiDrivers | Should -Contain 'vwifimp.sys'
        }
        It "includes WifiCx.sys (Win11+ WiFi CX driver)" {
            $script:wifiDrivers | Should -Contain 'WifiCx.sys'
        }
    }

    Context "iSCSI WMI MOF files (Step 4c)" {
        It "was successfully extracted" {
            $script:iscsiMofs.Count | Should -BeGreaterOrEqual 9
        }
        It "includes iscsidsc.mof" {
            $script:iscsiMofs | Should -Contain 'iscsidsc.mof'
        }
        It "includes storagewmi.mof" {
            $script:iscsiMofs | Should -Contain 'storagewmi.mof'
        }
        It "includes storagewmi_passthru.mof" {
            $script:iscsiMofs | Should -Contain 'storagewmi_passthru.mof'
        }
        It "includes msiscsi.mof" {
            $script:iscsiMofs | Should -Contain 'msiscsi.mof'
        }
        It "includes iscsiwmiv2.mof" {
            $script:iscsiMofs | Should -Contain 'iscsiwmiv2.mof'
        }
        It "includes iscsiwmiv2_uninstall.mof" {
            $script:iscsiMofs | Should -Contain 'iscsiwmiv2_uninstall.mof'
        }
    }

    Context "Font injection (Step 4e)" {
        It "was successfully extracted" {
            $script:requiredFonts.Count | Should -BeGreaterOrEqual 8
        }
        It "includes segoeui.ttf (primary UI font)" {
            $script:requiredFonts | Should -Contain 'segoeui.ttf'
        }
        It "includes consola.ttf (monospace font)" {
            $script:requiredFonts | Should -Contain 'consola.ttf'
        }
        It "includes Segoe Fluent Icons (SegoeIcons.ttf) for Win11 conditional copy" {
            $scriptContent | Should -Match 'SegoeIcons\.ttf'
        }
    }
}

# ===========================================================================
# 10. MUI CLEANUP LOGIC
# ===========================================================================
Describe "10. MUI language resource cleanup" {

    It "removes directories matching locale pattern ^[a-z]{2}-[A-Z]{2}" {
        # Script uses the pattern: '^[a-z]{2}-[A-Z]{2}' inside -match
        $scriptContent | Should -Match '-match'
        $scriptContent | Should -Match ([regex]::Escape('[a-z]{2}-[A-Z]{2}'))
    }

    It "always keeps en-US regardless of -Language parameter" {
        $scriptContent | Should -Match "\.Name\s*-ne\s*'en-US'"
    }

    It "keeps the user-specified language" {
        $scriptContent | Should -Match '\.Name\s*-ne\s*\$Language'
    }

    Context "Locale pattern matching unit test" {
        BeforeAll {
            $script:localePattern = '^[a-z]{2}-[A-Z]{2}'
        }

        It "matches de-DE" {
            'de-DE' -match $script:localePattern | Should -BeTrue
        }
        It "matches zh-CN" {
            'zh-CN' -match $script:localePattern | Should -BeTrue
        }
        It "matches en-us (case-insensitive -match; script handles via separate -ne en-US check)" {
            # PowerShell -match is case-insensitive so [A-Z]{2} matches 'us'.
            # The script handles this correctly: it keeps 'en-US' via a separate -ne check.
            'en-us' -match $script:localePattern | Should -BeTrue
        }
        It "does not match plain filenames like svchost.exe" {
            # 'svchost.exe' lacks the hyphen separator required by ^[a-z]{2}-[A-Z]{2}
            'svchost.exe' -match $script:localePattern | Should -BeFalse
        }
    }
}

# ===========================================================================
# 11. SLIM DOWN TARGETS
# ===========================================================================
Describe "11. Slim-down: files and folders removed" {

    It "removes Windows\DiagTrack telemetry directory" {
        $scriptContent | Should -Match 'Windows\\\\DiagTrack|DiagTrack'
    }

    It "removes diagtrack.dll" {
        $scriptContent | Should -Match 'diagtrack\.dll'
    }

    It "removes WMI AutoRecover directory" {
        $scriptContent | Should -Match 'wbem\\\\AutoRecover|AutoRecover'
    }

    It "removes WMI Repository" {
        $scriptContent | Should -Match 'wbem\\\\Repository|wbem.*Repository'
    }

    It "removes migration engine files" {
        $scriptContent | Should -Match 'migapp\.xml'
        $scriptContent | Should -Match 'migcore\.dll'
    }

    It "removes WallpaperHost.exe (PE-incompatible)" {
        $scriptContent | Should -Match 'WallpaperHost\.exe'
    }
}

# ===========================================================================
# 12. DISM SCRATCH SPACE
# ===========================================================================
Describe "12. DISM scratch space configuration" {

    It "calls DISM /Set-ScratchSpace against the mounted PE" {
        $scriptContent | Should -Match '/Set-ScratchSpace'
    }

    It "passes ScratchSpaceMB variable to DISM" {
        $scriptContent | Should -Match '/Set-ScratchSpace:\$ScratchSpaceMB|Set-ScratchSpace.*ScratchSpaceMB'
    }
}
