<#
.SYNOPSIS
    Installs VIPM on a Windows machine that already has LabVIEW installed
    and licensed (e.g. the GitLab `adaptive-win32` runner).

.DESCRIPTION
    Standalone equivalent of the `install-vipm` stage in .gitlab-ci.yml:
      1. Installs NI Package Manager (VIPM's installer prerequisite).
      2. Installs VIPM silently (/exenoui /qn is the only fully
         non-interactive invocation; other flags hang the installer).
      3. Seeds Settings.ini so `vipm refresh` does not hang on first-launch
         setup.

    Run from an elevated PowerShell session.
#>

[CmdletBinding()]
param(
    # Where downloaded installers are staged.
    [string]$TempDir = $env:TEMP
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$NipmUrl = 'https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager25.8.0.exe'
$VipmUrl = 'https://packages.jki.net/vipm/preview/vipm-setup-latest-preview.exe'

# 1. NI Package Manager --------------------------------------------------------
Write-Output 'Installing NI Package Manager...'
$nipm = Join-Path $TempDir 'NIPackageManager.exe'
Invoke-WebRequest -Uri $NipmUrl -OutFile $nipm
$p = Start-Process -Wait -PassThru -FilePath $nipm -ArgumentList '--passive', '--accept-eulas', '--prevent-reboot'
# NI installers: 0 = success, 3010 / -125071 = success but reboot needed.
if ($p.ExitCode -notin 0, 3010, -125071) { throw "NIPM install failed: $($p.ExitCode)" }

# 2. VIPM ----------------------------------------------------------------------
Write-Output 'Installing VIPM...'
$vipm = Join-Path $TempDir 'vipm-setup.exe'
Invoke-WebRequest -Uri $VipmUrl -OutFile $vipm
$p = Start-Process -Wait -PassThru -FilePath $vipm -ArgumentList '/exenoui', '/qn'
if ($p.ExitCode -ne 0) { throw "VIPM install failed: $($p.ExitCode)" }

# 3. Seed Settings.ini ---------------------------------------------------------
Write-Output "Moving setting.ini file"
Move-Item -Path "C:\Scripts\Settings.ini" -Destination "C:\ProgramData\JKI\VIPM"
icacls "C:\ProgramData\JKI\VIPM\Settings.ini" /grant "Everyone:(F)"

Write-Output 'VIPM install complete.'
