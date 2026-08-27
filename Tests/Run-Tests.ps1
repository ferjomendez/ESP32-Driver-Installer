#Requires -Version 5.1
<#
.SYNOPSIS
    Dependency-free test harness for Install-ESP32Driver.ps1.

.DESCRIPTION
    Runs entirely offline and touches nothing on the system: every test either
    exercises a pure function or feeds a captured pnputil fixture from
    Tests/fixtures. No driver is installed, no download is made.

    Deliberately does not use Pester: Windows ships Pester 3.4.0, whose syntax
    is incompatible with modern Pester, and requiring PSGallery would defeat the
    "single portable script" goal of this project.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$Script:Passed   = 0
$Script:Failed   = 0
$Script:Failures = @()

# ============================================================================
#  Assertions
# ============================================================================

function Assert-Equal {
    param($Expected, $Actual, [string]$What = 'value')
    if ($Expected -ne $Actual) {
        throw "$What`: expected [$Expected], got [$Actual]"
    }
}

function Assert-True {
    param($Condition, [string]$What = 'condition')
    if (-not $Condition) { throw "$What`: expected true, got [$Condition]" }
}

function Assert-False {
    param($Condition, [string]$What = 'condition')
    if ($Condition) { throw "$What`: expected false, got [$Condition]" }
}

function Assert-Null {
    param($Value, [string]$What = 'value')
    if ($null -ne $Value) { throw "$What`: expected null, got [$Value]" }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $Script:Passed++
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
    } catch {
        $Script:Failed++
        $Script:Failures += "$Name -> $($_.Exception.Message)"
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
        Write-Host ('         ' + $_.Exception.Message) -ForegroundColor DarkGray
    }
}

function Write-Group {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
}

# ============================================================================
#  Load the script under test (functions only)
# ============================================================================

$Script:Root       = Split-Path -Parent $PSScriptRoot
$Script:UnderTest  = Join-Path $Script:Root 'Install-ESP32Driver.ps1'
$Script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'

if (-not (Test-Path $Script:UnderTest)) {
    Write-Host "Cannot find script under test: $Script:UnderTest" -ForegroundColor Red
    exit 1
}

$env:ESP32_DRIVER_TEST_MODE = '1'
try {
    . $Script:UnderTest
} finally {
    Remove-Item Env:\ESP32_DRIVER_TEST_MODE -ErrorAction SilentlyContinue
}

function Get-Fixture {
    param([string]$Name)
    $path = Join-Path $Script:FixtureDir $Name
    if (-not (Test-Path $path)) { throw "Missing fixture: $Name" }
    Get-Content -Path $path -Raw -Encoding UTF8
}

function New-TempTree {
    <# Builds a throwaway folder tree. $Files is a hashtable of relative path -> content. #>
    param([hashtable]$Files)
    $root = Join-Path $env:TEMP ('esp32test_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    foreach ($rel in $Files.Keys) {
        $full = Join-Path $root $rel
        $dir  = Split-Path -Parent $full
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $full -Value $Files[$rel] -Encoding ASCII
    }
    return $root
}

Write-Host ''
Write-Host '  ESP32 Driver Installer - test suite' -ForegroundColor White
Write-Host "  Under test: $Script:UnderTest" -ForegroundColor DarkGray

# ============================================================================
#  Convert-DpinstExitCode
#
#  CP210xVCPInstaller_x64.exe is Microsoft DPInst 2.1 (verified via the EXE's
#  VersionInfo). DPInst does NOT return 0 on success - it returns a bitmask:
#     bits  0-6  number of driver packages that could not be installed
#     bit   7    a reboot is required
#     bits  8-14 number of packages copied to the driver store
#     bits 16-22 number of packages installed on devices
#     bit  31    an error occurred
#  Exit code 0 therefore means "nothing was installed", not "success".
# ============================================================================

Write-Group 'Convert-DpinstExitCode'

Test-Case 'exit code 0 means nothing was installed, not success' {
    $r = Convert-DpinstExitCode -ExitCode 0
    Assert-Equal 'NothingInstalled' $r.Status 'Status'
}

Test-Case 'package copied to store and installed on device is success' {
    $r = Convert-DpinstExitCode -ExitCode 0x00010100
    Assert-Equal 'Success' $r.Status 'Status'
    Assert-Equal 1 $r.CopiedToStore 'CopiedToStore'
    Assert-Equal 1 $r.InstalledOnDevices 'InstalledOnDevices'
    Assert-False $r.RebootRequired 'RebootRequired'
}

Test-Case 'reboot bit is reported without turning success into failure' {
    $r = Convert-DpinstExitCode -ExitCode 0x00000180
    Assert-Equal 'Success' $r.Status 'Status'
    Assert-True $r.RebootRequired 'RebootRequired'
    Assert-Equal 1 $r.CopiedToStore 'CopiedToStore'
}

Test-Case 'error bit 31 is a failure' {
    $r = Convert-DpinstExitCode -ExitCode 0x80000001
    Assert-Equal 'Failure' $r.Status 'Status'
}

Test-Case 'error bit 31 arriving as a negative Int32 is still a failure' {
    # Start-Process reports ExitCode as Int32, so 0x80000000 arrives as -2147483648.
    $r = Convert-DpinstExitCode -ExitCode -2147483648
    Assert-Equal 'Failure' $r.Status 'Status'
}

Test-Case 'a failed package count alone is a failure' {
    $r = Convert-DpinstExitCode -ExitCode 0x00000001
    Assert-Equal 'Failure' $r.Status 'Status'
    Assert-Equal 1 $r.FailedPackages 'FailedPackages'
}

Test-Case 'raw code is exposed as hex for diagnostics' {
    $r = Convert-DpinstExitCode -ExitCode 0x00010100
    Assert-Equal '0x00010100' $r.CodeHex 'CodeHex'
}

# ============================================================================
#  Find-DriverInf
#
#  The official ZIP ships slabvcp.inf. The original script looked for
#  silabser.inf (which is the .sys name, not the .inf name), so the INF
#  fallback could never succeed.
# ============================================================================

Write-Group 'Find-DriverInf'

Test-Case 'finds slabvcp.inf in the real package layout' {
    $tree = New-TempTree @{
        'slabvcp.inf'      = "[Version]`r`nProvider=Silicon Labs`r`n; Installation INF for Silicon Labs CP210x device"
        'dpinst.xml'       = '<dpinst/>'
        'x64\silabser.sys' = 'binary'
    }
    try {
        $inf = Find-DriverInf -Path $tree
        Assert-True ($null -ne $inf) 'an INF was found'
        Assert-Equal 'slabvcp.inf' $inf.Name 'INF name'
    } finally { Remove-Item $tree -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'also finds the INF if a future package renames it to silabser.inf' {
    $tree = New-TempTree @{
        'silabser.inf' = "[Version]`r`n; Silicon Labs CP210x driver"
    }
    try {
        $inf = Find-DriverInf -Path $tree
        Assert-Equal 'silabser.inf' $inf.Name 'INF name'
    } finally { Remove-Item $tree -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'ignores unrelated INF files' {
    $tree = New-TempTree @{
        'readme.inf' = "[Version]`r`nProvider=Some other vendor"
        'other.inf'  = "[Version]`r`nProvider=Realtek"
    }
    try {
        $inf = Find-DriverInf -Path $tree
        Assert-Null $inf 'result'
    } finally { Remove-Item $tree -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'finds the INF in a nested folder' {
    $tree = New-TempTree @{
        'CP210x_Drivers\pkg\slabvcp.inf' = "[Version]`r`n; Silicon Labs CP210x device"
    }
    try {
        $inf = Find-DriverInf -Path $tree
        Assert-Equal 'slabvcp.inf' $inf.Name 'INF name'
    } finally { Remove-Item $tree -Recurse -Force -ErrorAction SilentlyContinue }
}

# ============================================================================
#  Test-CP210xInstalledFromEnum
#
#  Win32_PnPSignedDriver only lists drivers bound to devices that are present,
#  so it reports "not installed" whenever the ESP32 board is unplugged.
#  pnputil /enum-drivers sees the driver store itself.
#
#  Parsing must key off INF file names and the provider value, never the field
#  labels: pnputil localizes its labels but not the data.
# ============================================================================

Write-Group 'Test-CP210xInstalledFromEnum'

Test-Case 'detects the driver in English pnputil output' {
    Assert-True (Test-CP210xInstalledFromEnum -EnumText (Get-Fixture 'pnputil-en-with-cp210x.txt')) 'detected'
}

Test-Case 'reports not installed when no CP210x driver is present' {
    Assert-False (Test-CP210xInstalledFromEnum -EnumText (Get-Fixture 'pnputil-en-without-cp210x.txt')) 'detected'
}

Test-Case 'is not fooled by the CH340 driver, a different USB-UART chip' {
    $text = Get-Fixture 'pnputil-en-without-cp210x.txt'
    Assert-True ($text -match 'ch341ser') 'fixture really contains the CH340 driver'
    Assert-False (Test-CP210xInstalledFromEnum -EnumText $text) 'detected'
}

Test-Case 'detects the driver on a Spanish Windows (localized labels)' {
    Assert-True (Test-CP210xInstalledFromEnum -EnumText (Get-Fixture 'pnputil-es-with-cp210x.txt')) 'detected'
}

Test-Case 'empty pnputil output is not a false positive' {
    Assert-False (Test-CP210xInstalledFromEnum -EnumText '') 'detected'
}

# ============================================================================
#  Get-CP210xVersionFromEnum
# ============================================================================

Write-Group 'Get-CP210xVersionFromEnum'

Test-Case 'returns the newest CP210x driver version, not the first one listed' {
    # The fixture lists 11.5.0.417 (Universal) and 6.7.4.261 (Legacy).
    Assert-Equal '11.5.0.417' (Get-CP210xVersionFromEnum -EnumText (Get-Fixture 'pnputil-en-with-cp210x.txt')) 'version'
}

Test-Case 'reads the version on a Spanish Windows too' {
    Assert-Equal '11.5.0.417' (Get-CP210xVersionFromEnum -EnumText (Get-Fixture 'pnputil-es-with-cp210x.txt')) 'version'
}

Test-Case 'does not pick up the version of an unrelated driver' {
    Assert-Null (Get-CP210xVersionFromEnum -EnumText (Get-Fixture 'pnputil-en-without-cp210x.txt')) 'version'
}

# ============================================================================
#  USB-to-UART vendor identification
#
#  Not every ESP32 board uses a Silicon Labs chip. Boards built around WCH
#  (CH340/CH9102), FTDI, or the ESP32-S2/S3/C3 native USB peripheral will never
#  bind to the CP210x driver, so reporting "no ESP32 connected" is misleading:
#  the board is connected and usually already working.
# ============================================================================

function New-FakeEntity {
    param([string]$Name, [string]$DeviceID)
    [pscustomobject]@{ Name = $Name; DeviceID = $DeviceID }
}

# Captured from a real machine with an ESP32 board plugged in.
$Script:RealEntities = @(
    New-FakeEntity 'USB-Enhanced-SERIAL CH9102 (COM4)' 'USB\VID_1A86&PID_55D4\5716013238'
    New-FakeEntity 'Standard Serial over Bluetooth link (COM7)' 'BTHENUM\{00001101-0000-1000-8000-00805F9B34FB}_LOCALMFG&0000\8&20B8917A&0&000000000000_00000000'
    New-FakeEntity 'Standard Serial over Bluetooth link (COM6)' 'BTHENUM\{00001101-0000-1000-8000-00805F9B34FB}_VID&00010075_PID&A013\8&20B8917A&0&F42B8CAF28AE_C00000000'
    New-FakeEntity 'Intel(R) Wireless Bluetooth(R)' 'USB\VID_8087&PID_0032\5&1B2C3D4E&0&10'
)

Write-Group 'Get-UsbUartVendorInfo'

Test-Case 'identifies a WCH bridge (CH340 / CH9102)' {
    $v = Get-UsbUartVendorInfo -DeviceID 'USB\VID_1A86&PID_55D4\5716013238'
    Assert-Equal '1A86' $v.Vid 'Vid'
    Assert-Equal 'WCH' $v.Vendor 'Vendor'
    Assert-False $v.IsCP210x 'IsCP210x'
}

Test-Case 'identifies an FTDI bridge' {
    Assert-Equal 'FTDI' (Get-UsbUartVendorInfo -DeviceID 'USB\VID_0403&PID_6001\A50285BI').Vendor 'Vendor'
}

Test-Case 'identifies the Espressif native USB peripheral' {
    Assert-Equal 'Espressif' (Get-UsbUartVendorInfo -DeviceID 'USB\VID_303A&PID_1001\7C:DF:A1').Vendor 'Vendor'
}

Test-Case 'identifies Silicon Labs and flags it as the CP210x family' {
    $v = Get-UsbUartVendorInfo -DeviceID 'USB\VID_10C4&PID_EA60\0001'
    Assert-Equal 'Silicon Labs' $v.Vendor 'Vendor'
    Assert-True $v.IsCP210x 'IsCP210x'
}

Test-Case 'matches the vendor id regardless of case' {
    Assert-Equal 'WCH' (Get-UsbUartVendorInfo -DeviceID 'usb\vid_1a86&pid_55d4\x').Vendor 'Vendor'
}

Test-Case 'returns nothing for a device that is not a known USB-UART bridge' {
    Assert-Null (Get-UsbUartVendorInfo -DeviceID 'BTHENUM\{00001101-0000-1000-8000-00805F9B34FB}_LOCALMFG&0000\8&1&0') 'result'
}

Test-Case 'returns nothing for an empty device id' {
    Assert-Null (Get-UsbUartVendorInfo -DeviceID '') 'result'
}

Write-Group 'Get-OtherUsbUartPorts'

Test-Case 'finds the CH9102 board that the CP210x filter misses' {
    $r = @(Get-OtherUsbUartPorts -Entities $Script:RealEntities)
    Assert-Equal 1 $r.Count 'number of bridges found'
    Assert-Equal 'COM4' $r[0].Port 'Port'
    Assert-Equal 'WCH' $r[0].Vendor 'Vendor'
    Assert-Equal 'USB-Enhanced-SERIAL CH9102 (COM4)' $r[0].Name 'Name'
}

Test-Case 'ignores Bluetooth serial ports, which are not boards' {
    $r = @(Get-OtherUsbUartPorts -Entities $Script:RealEntities)
    Assert-False ([bool]($r | Where-Object { $_.Name -match 'Bluetooth' })) 'any bluetooth entry'
}

Test-Case 'excludes CP210x devices, which are reported separately' {
    $entities = @(
        New-FakeEntity 'Silicon Labs CP210x USB to UART Bridge (COM3)' 'USB\VID_10C4&PID_EA60\0001'
        New-FakeEntity 'USB-Enhanced-SERIAL CH9102 (COM4)' 'USB\VID_1A86&PID_55D4\571'
    )
    $r = @(Get-OtherUsbUartPorts -Entities $entities)
    Assert-Equal 1 $r.Count 'number of bridges found'
    Assert-Equal 'COM4' $r[0].Port 'Port'
}

Test-Case 'skips a known bridge that has no COM port assigned yet' {
    # A board whose driver has not bound yet shows up without a (COMx) suffix.
    $entities = @(New-FakeEntity 'USB-Enhanced-SERIAL CH9102' 'USB\VID_1A86&PID_55D4\571')
    Assert-Equal 0 (@(Get-OtherUsbUartPorts -Entities $entities)).Count 'number of bridges found'
}

Test-Case 'returns nothing when no board is connected' {
    $entities = @(New-FakeEntity 'Standard Serial over Bluetooth link (COM7)' 'BTHENUM\x')
    Assert-Equal 0 (@(Get-OtherUsbUartPorts -Entities $entities)).Count 'number of bridges found'
}

Test-Case 'tolerates an empty device list' {
    Assert-Equal 0 (@(Get-OtherUsbUartPorts -Entities @())).Count 'number of bridges found'
}

# ============================================================================
#  Summary
# ============================================================================

Write-Host ''
Write-Host ('  ' + ('-' * 60)) -ForegroundColor DarkGray
if ($Script:Failed -eq 0) {
    Write-Host "  All $Script:Passed tests passed." -ForegroundColor Green
} else {
    Write-Host "  $Script:Passed passed, $Script:Failed FAILED." -ForegroundColor Red
    Write-Host ''
    foreach ($f in $Script:Failures) { Write-Host "    - $f" -ForegroundColor DarkGray }
}
Write-Host ''

exit ([int]($Script:Failed -gt 0))
