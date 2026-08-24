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
      1. Check if the driver is already installed.
      2. Download the official ZIP from silabs.com.
      3. Extract and run the correct installer (x64 or x86).
      4. Verify the driver is now registered.
      5. Detect any connected ESP32 device and report the COM port.
      6. Clean up temporary files.

    Design goals:
      - Windows 10 / Windows 11, PowerShell 5.1+ and PowerShell 7+.
      - Single portable script. No installation. No registry modifications.
      - Administrator rights required for driver installation.
      - Never terminates unexpectedly; every operation is guarded.

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
    Version : 1.0.0
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
        '^--?(help|\?)$'       { Get-Help -Detailed $MyInvocation.MyCommand.Path; exit 0 }
        default                { Write-Warning "Unknown argument ignored: $arg" }
    }
}

# ============================================================================
#  Script-wide state
# ============================================================================
$Script:Version   = '1.0.0'
$Script:NoColor   = [bool]($NoColor -or $env:NO_COLOR)
$Script:DriverUrl = 'https://www.silabs.com/documents/public/software/CP210x_Windows_Drivers.zip'
$Script:TempDir   = Join-Path $env:TEMP 'ESP32_Driver_Install'
$Script:ZipPath   = Join-Path $Script:TempDir 'CP210x_Windows_Drivers.zip'

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

function Wait-Exit {
    <# Pauses before exit so the user can read the output. #>
    Out-Line ''
    Out-Line '  Press any key to close ...' DarkGray
    try {
        if ($Host.UI.RawUI.KeyAvailable -ne $null) {
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
    } catch {
        # Fallback for hosts without RawUI (e.g. ISE, pipeline).
        Read-Host '  Press Enter to close'
    }
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
#  Driver detection
# ============================================================================

function Test-CP210xInstalled {
    <# Returns $true if any CP210x driver is already registered. #>

    # Method 1: Check PnP signed drivers.
    $pnp = Invoke-Safe {
        Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop |
            Where-Object { $_.DeviceName -match 'CP210' -or $_.InfName -match 'silabser' }
    }
    if ($pnp) { return $true }

    # Method 2: Check the driver store for the INF.
    $infStore = Invoke-Safe {
        Get-ChildItem "$env:SystemRoot\INF" -Filter 'oem*.inf' -ErrorAction SilentlyContinue |
            Where-Object {
                (Get-Content $_.FullName -TotalCount 30 -ErrorAction SilentlyContinue) -match 'silabser|CP210x'
            }
    }
    if ($infStore) { return $true }

    return $false
}

function Get-CP210xDriverVersion {
    <# Returns the installed driver version string or $null. #>
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
            if ($proc.ExitCode -eq 0) {
                Out-Status 'Installer completed successfully.' Green
                return $true
            } else {
                Out-Status "Installer exited with code $($proc.ExitCode). Trying INF method ..." Yellow
            }
        } catch {
            Out-Status "EXE installer failed: $($_.Exception.Message)" Yellow
            Out-Status 'Trying INF method ...' Yellow
        }
    }

    # Fallback: install via INF.
    $inf = Get-ChildItem -Path $ExtractPath -Filter 'silabser.inf' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $inf) {
        Out-Status 'Could not find silabser.inf in the package.' Red
        return $false
    }

    Out-KV 'INF path' $inf.FullName
    Out-Status 'Installing via pnputil ...'

    try {
        $result = & pnputil.exe /add-driver $inf.FullName /install 2>&1
        $resultText = $result -join "`n"
        if ($LASTEXITCODE -eq 0 -or $resultText -match 'successfully') {
            Out-Status 'INF driver installed successfully.' Green
            return $true
        } else {
            Out-Status "pnputil output: $resultText" Red
            return $false
        }
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
    Out-Line ''
    Out-Line ($Script:G.TL + ($Script:G.H * $inner) + $Script:G.TR) Cyan
    Out-Line ($Script:G.V + ('  ' + $banner).PadRight($inner) + $Script:G.V) Cyan
    Out-Line ($Script:G.V + ('  ' + $sub).PadRight($inner) + $Script:G.V) DarkCyan
    Out-Line ($Script:G.V + ('  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  |  ' + $env:COMPUTERNAME + '  |  PowerShell ' + $PSVersionTable.PSVersion).PadRight($inner) + $Script:G.V) DarkCyan
    Out-Line ($Script:G.BL + ($Script:G.H * $inner) + $Script:G.BR) Cyan

    # ---- Step 1: Admin check ------------------------------------------------
    Out-Step 1 $totalSteps 'Checking privileges'

    if (-not (Test-IsAdmin)) {
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
        } else {
            Out-Status 'No ESP32 device currently connected (this is normal if unplugged).' DarkGray
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
        Out-Status 'You can try manually:' Yellow
        Out-Status "  1. Open the folder: $extractPath" White
        Out-Status '  2. Right-click silabser.inf and select "Install"' White
        Out-Status '  3. Or run CP210xVCPInstaller_x64.exe as Administrator' White
        if (-not $KeepFiles) {
            Out-Status ''
            Out-Status 'Keeping temp files for manual install.' Yellow
        }
        Wait-Exit
        exit 1
    }

    # ---- Step 5: Verify -----------------------------------------------------
    Out-Step 5 $totalSteps 'Verifying installation'

    # Give Windows a moment to register the driver.
    Start-Sleep -Seconds 2

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
    } else {
        Out-Status 'No ESP32 device currently connected. Plug in your board to verify.' DarkGray
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
    Out-Line ($Script:G.V + ('  Time: ' + [math]::Round($stopwatch.Elapsed.TotalSeconds, 1) + 's').PadRight($inner) + $Script:G.V) DarkCyan
    Out-Line ($Script:G.BL + ($Script:G.H * $inner) + $Script:G.BR) DarkCyan
    Out-Line ''
}

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
