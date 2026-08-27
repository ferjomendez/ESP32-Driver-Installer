#Requires -Version 5.1
<#
.SYNOPSIS
    ESP32 Driver Installer - Installs the Silicon Labs CP210x USB to UART
    Bridge VCP driver required by most ESP32 development boards.

.DESCRIPTION
    Downloads the official CP210x VCP driver package directly from Silicon
    Labs (silabs.com) and runs the installer. Covers the full CP210x family:
    CP2102, CP2102N, CP2104, CP2105 and CP2108.

    Workflow:
      1. Check if the driver is already installed (via pnputil).
      2. Download the official ZIP from silabs.com.
      3. Extract and run the correct installer (x64 or x86).
      4. Verify the driver is now registered.
      5. Detect any connected ESP32 device and report the COM port.
      6. Clean up temporary files.

    Design goals:
      - Windows 10 / Windows 11, PowerShell 5.1+ and PowerShell 7+.
      - Single portable script. No installation. No registry modifications.
      - Administrator rights required; the script relaunches itself elevated.
      - Never terminates unexpectedly; every operation is guarded.
      - Locale independent: no decision is made by matching English words in
        the output of Windows tools.

.PARAMETER Force
    Reinstall the driver even if it is already detected (also accepted
    as --force).

.PARAMETER NoColor
    Disable colored console output (also accepted as --nocolor).
    The NO_COLOR environment variable is honored as well.

.PARAMETER Ascii
    Use plain ASCII borders instead of Unicode box drawing (also --ascii).

.PARAMETER KeepFiles
    Do not delete the downloaded ZIP and extracted folder after
    installation (also accepted as --keep).

.EXAMPLE
    .\Install-ESP32Driver.ps1
    Check and install the CP210x driver if missing.

.EXAMPLE
    .\Install-ESP32Driver.ps1 -Force
    Force a reinstallation even if the driver is already present.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-ESP32Driver.ps1
    Run from a standard terminal without changing the global policy.

.NOTES
    Name    : ESP32 Driver Installer
    Version : 1.1.0
    Author  : ferjomendez
    License : MIT
    Source  : Silicon Labs CP210x VCP Drivers
              https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers
    Exit    : 0 on success, 1 on failure.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$Force,
    [switch]$NoColor,
    [switch]$Ascii,
    [switch]$KeepFiles,
    # Internal: set when the script relaunches itself elevated, to stop a UAC loop.
    [switch]$Elevated,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ============================================================================
#  GNU-style argument compatibility (--force, --nocolor, --ascii, --keep)
# ============================================================================
foreach ($arg in @($ExtraArgs)) {
    if ([string]::IsNullOrWhiteSpace($arg)) { continue }
    switch -Regex ($arg) {
        '^--?force$'           { $Force    = $true }
        '^--?no-?color$'       { $NoColor  = $true }
        '^--?ascii$'           { $Ascii    = $true }
        '^--?keep(-?files)?$'  { $KeepFiles = $true }
        '^--?(help|\?)$'       {
            # $MyInvocation.MyCommand.Path is empty when the script was piped in
            # rather than run from a file, and Get-Help would then fail.
            if ($MyInvocation.MyCommand.Path) {
                Get-Help -Detailed $MyInvocation.MyCommand.Path
            } else {
                Write-Host 'Usage: Install-ESP32Driver.ps1 [-Force] [-NoColor] [-Ascii] [-KeepFiles]'
            }
            exit 0
        }
        default                { Write-Warning "Unknown argument ignored: $arg" }
    }
}

# ============================================================================
#  Script-wide state
# ============================================================================
$Script:Version         = '1.1.0'
$Script:NoColor         = [bool]($NoColor -or $env:NO_COLOR)
$Script:DriverUrl       = 'https://www.silabs.com/documents/public/software/CP210x_Windows_Drivers.zip'
$Script:TempDir         = Join-Path $env:TEMP 'ESP32_Driver_Install'
$Script:ZipPath         = Join-Path $Script:TempDir 'CP210x_Windows_Drivers.zip'
$Script:DriverEnumCache = $null
$Script:RebootRequired  = $false
$Script:LastInfPath     = $null

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if ($Ascii) {
    $Script:G = @{ TL = '+'; TR = '+'; BL = '+'; BR = '+'; H = '-'; V = '|' }
} else {
    $Script:G = @{
        TL  = [string][char]0x2554; TR = [string][char]0x2557
        BL  = [string][char]0x255A; BR = [string][char]0x255D
        H   = [string][char]0x2550; V  = [string][char]0x2551
    }
}

# ============================================================================
#  Core helpers
# ============================================================================

function Test-IsAdmin {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-Safe {
    param([scriptblock]$Script, $Default = $null)
    try { & $Script } catch { $Default }
}

function Invoke-SelfElevate {
    <#
        Relaunches this script in an elevated window, forwarding the original
        switches. Returns $true if a new elevated process was started.

        Returns $false - leaving the caller to print the manual instructions -
        when relaunching is impossible or refused:
          - already running as a relaunched child ($Elevated), so UAC cannot loop
          - no script file to relaunch (piped from the web, dot-sourced)
          - the user dismissed the UAC prompt
    #>
    if ($Elevated) { return $false }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) { return $false }

    $psExe = Invoke-Safe { (Get-Process -Id $PID).Path }
    if ([string]::IsNullOrWhiteSpace($psExe)) { return $false }

    # Start-Process joins ArgumentList with spaces without quoting, so the
    # script path has to be quoted here or any space in it breaks the relaunch.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Elevated')
    if ($Force)     { $argList += '-Force' }
    if ($NoColor)   { $argList += '-NoColor' }
    if ($Ascii)     { $argList += '-Ascii' }
    if ($KeepFiles) { $argList += '-KeepFiles' }

    Out-Status 'Requesting Administrator privileges ...' Yellow
    try {
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Out-Status 'Administrator approval was denied or cancelled.' Yellow
        return $false
    }
}

function Wait-Exit {
    <# Pauses before exit so the user can read the output. #>
    Out-Line ''
    Out-Line '  Press any key to close ...' DarkGray
    cmd /c pause >$null 2>&1
}

# ============================================================================
#  Console output pipeline
# ============================================================================

function Out-Line {
    param([string]$Text = '', [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if ($Script:NoColor) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}

function Out-KV {
    param([string]$Label, [string]$Value, [ConsoleColor]$ValueColor = [ConsoleColor]::White)
    $prefix = '  ' + $Label.PadRight(26) + ' '
    if ($Script:NoColor) {
        Write-Host ($prefix + $Value)
    } else {
        Write-Host $prefix -NoNewline -ForegroundColor DarkGray
        Write-Host $Value -ForegroundColor $ValueColor
    }
}

function Out-SectionHeader {
    param([string]$Title)
    $inner = 66
    Out-Line ''
    Out-Line ($Script:G.TL + ($Script:G.H * $inner) + $Script:G.TR) DarkCyan
    $text = '  ' + $Title.ToUpperInvariant()
    if ($text.Length -gt $inner) { $text = $text.Substring(0, $inner) }
    Out-Line ($Script:G.V + $text.PadRight($inner) + $Script:G.V) Cyan
    Out-Line ($Script:G.BL + ($Script:G.H * $inner) + $Script:G.BR) DarkCyan
}

function Out-Status {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Out-Line "  $Message" $Color
}

function Out-Step {
    param([int]$Number, [int]$Total, [string]$Message)
    Out-Line ''
    Out-Line "  [$Number/$Total] $Message" White
}

# ============================================================================
#  Installer result decoding
# ============================================================================

function Convert-DpinstExitCode {
    <#
        CP210xVCPInstaller_x64.exe / _x86.exe are Microsoft DPInst 2.1
        (Driver Package Installer). DPInst does not return 0 on success - it
        returns a bitmask:

            bits  0-6   packages that could not be installed
            bit   7     a reboot is required
            bits  8-14  packages copied to the driver store
            bits 16-22  packages installed on devices
            bit  31     an error occurred

        Exit code 0 therefore means "nothing was installed", not "success".
    #>
    param([Parameter(Mandatory = $true)][long]$ExitCode)

    # Start-Process reports ExitCode as Int32, so 0x80000000 arrives negative.
    $u = [uint32]([int64]$ExitCode -band 0xFFFFFFFFL)

    $failed    = [int]($u -band 0x7F)
    $reboot    = [bool]($u -band 0x80)
    $copied    = [int](($u -shr 8)  -band 0x7F)
    $installed = [int](($u -shr 16) -band 0x7F)
    $errorBit  = [bool](($u -shr 31) -band 1)

    $status = if ($errorBit -or $failed -gt 0) {
        'Failure'
    } elseif ($installed -gt 0 -or $copied -gt 0) {
        'Success'
    } else {
        'NothingInstalled'
    }

    [pscustomobject]@{
        Status             = $status
        RebootRequired     = $reboot
        FailedPackages     = $failed
        CopiedToStore      = $copied
        InstalledOnDevices = $installed
        CodeHex            = '0x{0:X8}' -f $u
    }
}

function Find-DriverInf {
    <#
        Returns the CP210x INF inside an extracted package, or $null.

        The official ZIP ships slabvcp.inf - silabser is the name of the .sys,
        not the .inf. Rather than hard-coding either name, pick the INF whose
        body identifies a CP210x driver, so a future rename of the package
        cannot break the fallback again.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidates = Get-ChildItem -Path $Path -Filter '*.inf' -Recurse -File -ErrorAction SilentlyContinue
    foreach ($inf in $candidates) {
        $body = Invoke-Safe { Get-Content -Path $inf.FullName -Raw -ErrorAction Stop }
        if ($body -and $body -match 'CP210x|silabser') { return $inf }
    }
    return $null
}

# ============================================================================
#  Driver detection
#
#  pnputil /enum-drivers is the source of truth here, not Win32_PnPSignedDriver:
#  that WMI class only lists drivers bound to devices that are currently
#  present, so it reports "not installed" whenever the board is unplugged.
# ============================================================================

function Get-CP210xEnumBlocks {
    <#
        Splits pnputil /enum-drivers output into per-driver blocks and returns
        those belonging to a CP210x driver.

        Matching is anchored on INF file names, the provider value and the Ports
        class GUID - never on field labels. pnputil translates its labels
        ("Driver Version" -> "Version del controlador") but not the data, so
        label matching silently breaks on non-English Windows.
    #>
    param([string]$EnumText)

    if ([string]::IsNullOrWhiteSpace($EnumText)) { return @() }

    $blocks = ($EnumText -replace "`r`n", "`n") -split "`n{2,}"
    return @($blocks | Where-Object {
        ($_ -match '\b(?:slabvcp|silabser)\.inf\b') -or
        ($_ -match 'Silicon Lab' -and $_ -match '4d36e978-e325-11ce-bfc1-08002be10318')
    })
}

function Test-CP210xInstalledFromEnum {
    <# Returns $true if pnputil output shows a CP210x driver in the driver store. #>
    param([string]$EnumText)
    return (@(Get-CP210xEnumBlocks -EnumText $EnumText).Count -gt 0)
}

function Get-CP210xVersionFromEnum {
    <#
        Returns the newest installed CP210x driver version, or $null.
        The version line's label is localized but its value is not, so the
        four-part number is read positionally from within the matching block.
    #>
    param([string]$EnumText)

    $found = New-Object System.Collections.ArrayList
    foreach ($block in (Get-CP210xEnumBlocks -EnumText $EnumText)) {
        foreach ($m in [regex]::Matches($block, '\b\d+\.\d+\.\d+\.\d+\b')) {
            $v = $null
            if ([version]::TryParse($m.Value, [ref]$v)) { [void]$found.Add($v) }
        }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object -Descending | Select-Object -First 1).ToString()
}

function Get-DriverStoreEnum {
    <#
        Returns the raw text of pnputil /enum-drivers, cached for the run.

        Cached because the previous implementation queried Win32_PnPSignedDriver
        up to four times at ~8s each - about 33s of apparent freeze with no
        output. pnputil answers in well under a second.

        Call Reset-DriverStoreCache after installing to force a fresh read.
    #>
    if ($null -ne $Script:DriverEnumCache) { return $Script:DriverEnumCache }

    $Script:DriverEnumCache = Invoke-Safe {
        # No 2>&1 here: with $ErrorActionPreference = 'Stop', redirecting a
        # native command's stderr turns each line into an ErrorRecord and
        # aborts the script.
        (& pnputil.exe /enum-drivers) -join "`n"
    } ''

    return $Script:DriverEnumCache
}

function Reset-DriverStoreCache {
    $Script:DriverEnumCache = $null
}

function Test-CP210xInstalled {
    <# Returns $true if any CP210x driver is registered in the driver store. #>

    if (Test-CP210xInstalledFromEnum -EnumText (Get-DriverStoreEnum)) { return $true }

    # Secondary signal, kept for the rare case where pnputil is unavailable.
    # On its own this is unreliable: Win32_PnPSignedDriver only lists drivers
    # bound to devices that are currently present.
    $pnp = Invoke-Safe {
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -match 'CP210' -or $_.InfName -match 'silabser' }
    }
    return [bool]$pnp
}

function Get-CP210xDriverVersion {
    <# Returns the newest installed driver version string, or $null. #>

    $version = Get-CP210xVersionFromEnum -EnumText (Get-DriverStoreEnum)
    if ($version) { return $version }

    $drv = Invoke-Safe {
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -match 'CP210' -or $_.InfName -match 'silabser' } |
            Select-Object -First 1
    }
    if ($drv -and $drv.DriverVersion) { return $drv.DriverVersion }
    return $null
}

function Get-CP210xComPorts {
    <# Returns an array of COM port names where CP210x devices are connected. #>
    $ports = Invoke-Safe {
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.Name -match 'CP210' -and $_.Name -match 'COM\d+' } |
            ForEach-Object {
                if ($_.Name -match '(COM\d+)') { $Matches[1] }
            }
    } @()
    return $ports
}

# ============================================================================
#  Other USB-to-UART bridges
#
#  Not every ESP32 board uses a Silicon Labs chip. Boards built around WCH
#  (CH340 / CH9102), FTDI, or the native USB peripheral of the ESP32-S2/S3/C3
#  will never bind to the CP210x driver. Saying "no ESP32 connected" in that
#  case is misleading: the board is plugged in and usually already working.
# ============================================================================

function Get-UsbUartVendorInfo {
    <#
        Identifies the USB-to-UART bridge behind a PnP device id, or returns
        $null when the device is not a known bridge.
    #>
    param([string]$DeviceID)

    if ([string]::IsNullOrWhiteSpace($DeviceID)) { return $null }

    # Deliberately requires the "VID_" form. Bluetooth device ids carry a
    # different "_VID&nnnn" field that must not be treated as a USB vendor id.
    if ($DeviceID -notmatch '(?i)VID_([0-9A-F]{4})') { return $null }

    $vid = $Matches[1].ToUpperInvariant()
    $vendor = switch ($vid) {
        '10C4'  { 'Silicon Labs' }
        '1A86'  { 'WCH' }
        '0403'  { 'FTDI' }
        '303A'  { 'Espressif' }
        default { $null }
    }
    if (-not $vendor) { return $null }

    [pscustomobject]@{
        Vid      = $vid
        Vendor   = $vendor
        IsCP210x = ($vid -eq '10C4')
    }
}

function Get-OtherUsbUartPorts {
    <#
        Given a set of PnP entities, returns the connected USB-to-UART bridges
        that are NOT CP210x devices, with the COM port each one holds.
    #>
    param($Entities)

    $result = New-Object System.Collections.ArrayList
    foreach ($e in @($Entities)) {
        if (-not $e) { continue }

        $info = Get-UsbUartVendorInfo -DeviceID $e.DeviceID
        if (-not $info -or $info.IsCP210x) { continue }

        # No (COMx) suffix means Windows has not assigned a port yet.
        if ($e.Name -match '\((COM\d+)\)') {
            [void]$result.Add([pscustomobject]@{
                Name   = $e.Name
                Port   = $Matches[1]
                Vid    = $info.Vid
                Vendor = $info.Vendor
            })
        }
    }
    return @($result)
}

function Get-ConnectedUsbUartBridges {
    <# Queries the live system for connected non-CP210x USB-to-UART bridges. #>
    $entities = Invoke-Safe { Get-CimInstance Win32_PnPEntity -ErrorAction Stop } @()
    return @(Get-OtherUsbUartPorts -Entities $entities)
}

function Out-OtherBridgeHint {
    <#
        Prints an explanation when a board is connected through a bridge other
        than a CP210x. Returns $true if anything was reported.
    #>
    $others = @(Get-ConnectedUsbUartBridges)
    if ($others.Count -eq 0) { return $false }

    Out-Status 'No CP210x device connected.' DarkGray
    Out-Status 'Found another USB-to-UART bridge instead:' Yellow
    foreach ($o in $others) {
        Out-KV 'Device' $o.Name Yellow
        Out-KV 'Port'   $o.Port Yellow
        Out-KV 'Vendor' ('{0} (VID_{1}) - not Silicon Labs' -f $o.Vendor, $o.Vid) Yellow
    }

    Out-Line ''
    Out-Status 'This board does not use a CP210x chip, so the Silicon Labs' White
    Out-Status 'driver will not bind to it. It already has a COM port, so you' White
    Out-Status 'can point your IDE at the port listed above.' White

    foreach ($vendor in ($others | Select-Object -ExpandProperty Vendor -Unique)) {
        switch ($vendor) {
            'WCH' {
                Out-Status 'If it stops working, install the WCH CH340/CH9102 driver from wch.cn.' DarkGray
            }
            'FTDI' {
                Out-Status 'If it stops working, install the FTDI VCP driver from ftdichip.com.' DarkGray
            }
            'Espressif' {
                Out-Status 'This board uses the ESP32 native USB peripheral. No driver is needed.' DarkGray
            }
        }
    }

    return $true
}

# ============================================================================
#  Download and install
# ============================================================================

function Get-DriverPackage {
    <# Downloads the official ZIP from Silicon Labs. Returns $true on success. #>
    try {
        if (-not (Test-Path $Script:TempDir)) {
            New-Item -ItemType Directory -Path $Script:TempDir -Force | Out-Null
        }

        Out-Status 'Downloading from silabs.com ...'
        Out-KV 'URL' $Script:DriverUrl

        # Use BITS if available (shows progress), fall back to Invoke-WebRequest.
        $useBits = $null -ne (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue)

        if ($useBits) {
            Start-BitsTransfer -Source $Script:DriverUrl -Destination $Script:ZipPath -ErrorAction Stop
        } else {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Script:DriverUrl -OutFile $Script:ZipPath -UseBasicParsing -ErrorAction Stop
        }

        $size = (Get-Item $Script:ZipPath).Length
        Out-KV 'Downloaded' ('{0:N1} MB' -f ($size / 1MB)) Green
        return $true
    } catch {
        Out-Status "Download failed: $($_.Exception.Message)" Red
        return $false
    }
}

function Expand-DriverPackage {
    <# Extracts the ZIP. Returns the extraction folder path or $null. #>
    try {
        $extractPath = Join-Path $Script:TempDir 'CP210x_Drivers'
        if (Test-Path $extractPath) {
            Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Expand-Archive -Path $Script:ZipPath -DestinationPath $extractPath -Force -ErrorAction Stop
        Out-Status 'Package extracted.' Green
        return $extractPath
    } catch {
        Out-Status "Extraction failed: $($_.Exception.Message)" Red
        return $null
    }
}

function Install-CP210xDriver {
    <# Runs the installer EXE or falls back to INF install. Returns $true on success. #>
    param([string]$ExtractPath)

    # Determine architecture.
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $exeName = "CP210xVCPInstaller_$arch.exe"

    # Search for the installer recursively (folder structure may vary between versions).
    $installer = Get-ChildItem -Path $ExtractPath -Filter $exeName -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($installer) {
        Out-KV 'Installer' $installer.Name
        Out-KV 'Architecture' $arch
        Out-Status 'Running installer (this may take a few seconds) ...'

        try {
            $proc = Start-Process -FilePath $installer.FullName -ArgumentList '/S' `
                -Wait -PassThru -ErrorAction Stop

            # The EXE is Microsoft DPInst, which returns a bitmask rather than
            # 0-on-success. See Convert-DpinstExitCode.
            $r = Convert-DpinstExitCode -ExitCode $proc.ExitCode
            Out-KV 'Installer result' ('{0} ({1})' -f $r.Status, $r.CodeHex)

            switch ($r.Status) {
                'Success' {
                    Out-Status 'Installer completed successfully.' Green
                    if ($r.InstalledOnDevices -gt 0) {
                        Out-KV 'Installed on devices' $r.InstalledOnDevices Green
                    }
                    if ($r.CopiedToStore -gt 0) {
                        Out-KV 'Copied to driver store' $r.CopiedToStore Green
                    }
                    $Script:RebootRequired = $r.RebootRequired
                    if ($r.RebootRequired) {
                        Out-Status 'A restart is required to finish the installation.' Yellow
                    }
                    Reset-DriverStoreCache
                    return $true
                }
                'NothingInstalled' {
                    Out-Status 'Installer reported nothing to install. Trying INF method ...' Yellow
                }
                default {
                    Out-Status "Installer reported $($r.FailedPackages) failed package(s). Trying INF method ..." Yellow
                }
            }
        } catch {
            Out-Status "EXE installer failed: $($_.Exception.Message)" Yellow
            Out-Status 'Trying INF method ...' Yellow
        }
    }

    # Fallback: install via INF. The package ships slabvcp.inf, so the INF is
    # located by content rather than by a hard-coded file name.
    $inf = Find-DriverInf -Path $ExtractPath

    if (-not $inf) {
        Out-Status 'Could not find a CP210x INF in the package.' Red
        return $false
    }

    $Script:LastInfPath = $inf.FullName
    Out-KV 'INF path' $inf.FullName
    Out-Status 'Installing via pnputil ...'

    try {
        # No 2>&1: under $ErrorActionPreference = 'Stop' that turns native
        # stderr into a terminating error. Success is decided by the exit code
        # and by re-reading the driver store - never by matching the word
        # "successfully", which is localized.
        $result = & pnputil.exe /add-driver $inf.FullName /install
        $code   = $LASTEXITCODE
        Reset-DriverStoreCache

        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED.
        if ($code -eq 3010) { $Script:RebootRequired = $true }

        if ($code -eq 0 -or $code -eq 3010 -or (Test-CP210xInstalled)) {
            Out-Status 'INF driver installed successfully.' Green
            if ($Script:RebootRequired) {
                Out-Status 'A restart is required to finish the installation.' Yellow
            }
            return $true
        }

        Out-KV 'pnputil exit code' $code Red
        Out-Status "pnputil output: $($result -join ' ')" Red
        return $false
    } catch {
        Out-Status "INF install failed: $($_.Exception.Message)" Red
        return $false
    }
}

function Remove-TempFiles {
    <# Cleans up downloaded files. #>
    if ($KeepFiles) {
        Out-Status "Temporary files kept at: $($Script:TempDir)" DarkGray
        return
    }
    try {
        if (Test-Path $Script:TempDir) {
            Remove-Item $Script:TempDir -Recurse -Force -ErrorAction Stop
            Out-Status 'Temporary files removed.' DarkGray
        }
    } catch {
        Out-Status "Cleanup note: could not remove $($Script:TempDir)" DarkGray
    }
}

# ============================================================================
#  MAIN
# ============================================================================

function Invoke-ESP32DriverInstaller {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $totalSteps = 5

    # Banner.
    $banner = 'ESP32 DRIVER INSTALLER v' + $Script:Version
    $sub    = 'Silicon Labs CP210x USB to UART Bridge VCP Driver'
    $inner  = 66

    # Build info line, trimming PowerShell version if needed.
    $psVer    = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    $infoLine = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  |  ' + $env:COMPUTERNAME + '  |  PS ' + $psVer
    $authorLine = 'github.com/ferjomendez'

    Out-Line ''
    Out-Line ($Script:G.TL + ($Script:G.H * $inner) + $Script:G.TR) Cyan
    foreach ($entry in @(
        @{ Text = $banner;    Color = 'Cyan' },
        @{ Text = $sub;       Color = 'DarkCyan' },
        @{ Text = $infoLine;  Color = 'DarkCyan' },
        @{ Text = $authorLine; Color = 'DarkCyan' }
    )) {
        $padded = '  ' + $entry.Text
        if ($padded.Length -gt $inner) { $padded = $padded.Substring(0, $inner) }
        Out-Line ($Script:G.V + $padded.PadRight($inner) + $Script:G.V) $entry.Color
    }
    Out-Line ($Script:G.BL + ($Script:G.H * $inner) + $Script:G.BR) Cyan

    # ---- Step 1: Admin check ------------------------------------------------
    Out-Step 1 $totalSteps 'Checking privileges'

    if (-not (Test-IsAdmin)) {
        Out-Status 'Not running as Administrator.' Yellow

        if (Invoke-SelfElevate) {
            Out-Status 'Continuing in a new Administrator window.' Green
            $stopwatch.Stop()
            exit 0
        }

        Out-Status 'This script requires Administrator privileges to install drivers.' Red
        Out-Status 'Right-click PowerShell and select "Run as administrator", then try again.' Yellow
        $stopwatch.Stop()
        Wait-Exit
        exit 1
    }
    Out-Status 'Running as Administrator.' Green

    # ---- Step 2: Pre-check --------------------------------------------------
    Out-Step 2 $totalSteps 'Checking for existing CP210x driver'

    $alreadyInstalled = Test-CP210xInstalled
    $currentVersion   = Get-CP210xDriverVersion

    if ($alreadyInstalled -and -not $Force) {
        Out-Status 'CP210x driver is already installed.' Green
        if ($currentVersion) { Out-KV 'Driver version' $currentVersion Green }

        $ports = Get-CP210xComPorts
        if ($ports.Count -gt 0) {
            Out-KV 'ESP32 detected on' ($ports -join ', ') Green
        } elseif (-not (Out-OtherBridgeHint)) {
            Out-Status 'No CP210x device currently connected (this is normal if unplugged).' DarkGray
        }

        Out-Line ''
        Out-Status 'Nothing to do. Use -Force to reinstall.' DarkGray
        $stopwatch.Stop()
        Out-Line ''
        Out-Line "  Completed in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s" DarkGray
        Wait-Exit
        exit 0
    }

    if ($alreadyInstalled -and $Force) {
        Out-Status 'Driver already present. Reinstalling because -Force was specified.' Yellow
        if ($currentVersion) { Out-KV 'Current version' $currentVersion }
    } else {
        Out-Status 'No CP210x driver detected. Proceeding with installation.' White
    }

    # ---- Step 3: Download ---------------------------------------------------
    Out-Step 3 $totalSteps 'Downloading driver package'

    $downloaded = Get-DriverPackage
    if (-not $downloaded) {
        Out-Line ''
        Out-Status 'Installation aborted. Could not download the driver package.' Red
        Out-Status 'Check your internet connection or download manually from:' Yellow
        Out-Status 'https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers' Yellow
        Remove-TempFiles
        Wait-Exit
        exit 1
    }

    # ---- Step 4: Extract and install ----------------------------------------
    Out-Step 4 $totalSteps 'Installing driver'

    $extractPath = Expand-DriverPackage
    if (-not $extractPath) {
        Remove-TempFiles
        Wait-Exit
        exit 1
    }

    $installed = Install-CP210xDriver -ExtractPath $extractPath
    if (-not $installed) {
        Out-Line ''
        Out-Status 'Automatic installation failed.' Red
        $infName = if ($Script:LastInfPath) { Split-Path -Leaf $Script:LastInfPath } else { 'slabvcp.inf' }
        $arch    = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        Out-Status 'You can try manually:' Yellow
        Out-Status "  1. Open the folder: $extractPath" White
        Out-Status "  2. Right-click $infName and select `"Install`"" White
        Out-Status "  3. Or run CP210xVCPInstaller_$arch.exe as Administrator" White
        if (-not $KeepFiles) {
            Out-Status ''
            Out-Status 'Keeping temp files for manual install.' Yellow
        }
        Wait-Exit
        exit 1
    }

    # ---- Step 5: Verify -----------------------------------------------------
    Out-Step 5 $totalSteps 'Verifying installation'

    # Give Windows a moment to register the driver, then read the store again
    # rather than trusting the pre-install snapshot.
    Start-Sleep -Seconds 2
    Reset-DriverStoreCache

    $verified = Test-CP210xInstalled
    $newVersion = Get-CP210xDriverVersion

    if ($verified) {
        Out-Status 'CP210x driver installed and verified.' Green
        if ($newVersion) { Out-KV 'Driver version' $newVersion Green }
    } else {
        Out-Status 'Driver files were copied but verification could not confirm registration.' Yellow
        Out-Status 'Try reconnecting your ESP32 board or restarting the computer.' Yellow
    }

    $ports = Get-CP210xComPorts
    if ($ports.Count -gt 0) {
        Out-KV 'ESP32 detected on' ($ports -join ', ') Green
    } elseif (-not (Out-OtherBridgeHint)) {
        Out-Status 'No CP210x device currently connected. Plug in your board to verify.' DarkGray
    }

    # ---- Cleanup ------------------------------------------------------------
    Remove-TempFiles

    # ---- Summary ------------------------------------------------------------
    $stopwatch.Stop()
    Out-Line ''
    $inner = 66
    Out-Line ($Script:G.TL + ($Script:G.H * $inner) + $Script:G.TR) DarkCyan
    $statusText = if ($verified) { 'INSTALLATION COMPLETE' } else { 'INSTALLATION FINISHED (VERIFY MANUALLY)' }
    Out-Line ($Script:G.V + ('  ' + $statusText).PadRight($inner) + $Script:G.V) Green
    if ($Script:RebootRequired) {
        Out-Line ($Script:G.V + '  Restart required to finish'.PadRight($inner) + $Script:G.V) Yellow
    }
    Out-Line ($Script:G.V + ('  Time: ' + [math]::Round($stopwatch.Elapsed.TotalSeconds, 1) + 's').PadRight($inner) + $Script:G.V) DarkCyan
    Out-Line ($Script:G.BL + ($Script:G.H * $inner) + $Script:G.BR) DarkCyan
    Out-Line ''
}

# When dot-sourced by the test harness, stop here and expose the functions only.
if (-not $env:ESP32_DRIVER_TEST_MODE) {
    try {
        Invoke-ESP32DriverInstaller
        Wait-Exit
        exit 0
    } catch {
        Write-Host ''
        Write-Host "ESP32 Driver Installer encountered an unexpected error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        Wait-Exit
        exit 1
    }
}
