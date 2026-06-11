<#
.SYNOPSIS
    Installs the full VIPM package stack on a fresh Windows machine.

.DESCRIPTION
    Standalone equivalent of the `install-packages` job in
    .github/workflows/labview-windows.yaml. Mirrors each step:
      1. Install NI Package Manager.
      2. Install the NI LabVIEW 2020 SP1 64-bit Runtime (VIPM's prerequisite)
         via nipkg.
      3. Install VIPM silently (/exenoui /qn).
      4. Seed Settings.ini (staged from Downloads via C:\Scripts).
      5. vipm version.
      6. vipm refresh.

    Run from an elevated PowerShell session.
#>

[CmdletBinding()]
param(
    # Where downloaded installers are staged.
    [string]$TempDir = $env:TEMP
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$nipkg   = "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe"
$vipmBin = "C:\Program Files\JKI\VI Package Manager\support"
$vipmExe = "$vipmBin\vipm.exe"

# 1. Install NI Package Manager ------------------------------------------------
Write-Output 'Installing NI Package Manager...'
$exe = Join-Path $TempDir 'NIPackageManager.exe'
Invoke-WebRequest -Uri "https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager25.8.0.exe" -OutFile $exe
$p = Start-Process -Wait -PassThru -FilePath $exe -ArgumentList "--passive", "--accept-eulas", "--prevent-reboot"
# NI installers: 0 = success, 3010 / -125071 = success but reboot needed.
if ($p.ExitCode -notin 0, 3010, -125071) { throw "NIPM install failed: $($p.ExitCode)" }

# 2. Install NI LabVIEW 2020 SP1 Runtime (VIPM prerequisite) -------------------
Write-Output 'Installing NI LabVIEW 2020 SP1 Runtime...'
& $nipkg feed-add --name=lvrte2020 "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020-runtime-engine/20.1/released"
& $nipkg feed-add --name=lvrte2020-critical "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020-runtime-engine/20.1/released-critical"
& $nipkg update
& $nipkg install --accept-eulas --assume-yes ni-labview-2020-runtime-engine
# -125071 = reboot needed; packages are installed, but we cannot reboot here.
if ($LASTEXITCODE -notin 0, -125071) { throw "nipkg install failed: $LASTEXITCODE" }

# 3. Install VIPM --------------------------------------------------------------
Write-Output 'Installing VIPM...'
$exe = Join-Path $TempDir 'vipm-setup.exe'
Invoke-WebRequest -Uri "https://packages.jki.net/vipm/preview/vipm-setup-latest-preview.exe" -OutFile $exe
# /exenoui /qn is the only fully non-interactive invocation; other flag
# combinations hang the installer.
$p = Start-Process -Wait -PassThru -FilePath $exe -ArgumentList "/exenoui", "/qn"
if ($p.ExitCode -ne 0) { throw "VIPM install failed: $($p.ExitCode)" }
# Add VIPM to PATH for this session (the workflow appends to GITHUB_PATH).
$env:PATH = "$vipmBin;$env:PATH"

# 4. Seed VIPM Settings.ini ----------------------------------------------------
# Without a Settings.ini, "vipm refresh" hangs on first-launch setup.
Write-Output 'Seeding VIPM Settings.ini...'
New-Item -ItemType Directory -Force -Path "C:\Scripts" | Out-Null
Copy-Item -Path "$env:USERPROFILE\Downloads\Settings.ini" -Destination "C:\Scripts\Settings.ini" -Force
New-Item -ItemType Directory -Force -Path "C:\ProgramData\JKI\VIPM" | Out-Null
Copy-Item -Path "C:\Scripts\Settings.ini" -Destination "C:\ProgramData\JKI\VIPM\Settings.ini" -Force

# 5. VIPM version --------------------------------------------------------------
& $vipmExe version

# 6. VIPM refresh --------------------------------------------------------------
& $vipmExe refresh

Write-Output 'install-packages complete.'
