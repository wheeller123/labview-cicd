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

$VipmUrl = 'https://packages.jki.net/vipm/preview/vipm-setup-latest-preview.exe'

Write-Output 'Installing VIPM...'
$vipm = Join-Path $TempDir 'vipm-setup.exe'
Invoke-WebRequest -Uri $VipmUrl -OutFile $vipm
$p = Start-Process -Wait -PassThru -FilePath $vipm -ArgumentList '/exenoui', '/qn'
if ($p.ExitCode -ne 0) { throw "VIPM install failed: $($p.ExitCode)" }

Write-Output "Moving setting.ini file"
Move-Item -Path "C:\Scripts\Settings.ini" -Destination "C:\ProgramData\JKI\VIPM"
icacls "C:\ProgramData\JKI\VIPM\Settings.ini" /grant "Everyone:(F)"

Write-Output 'Refreshing VIPM...'
& "C:\Program Files\JKI\VI Package Manager\support\vipm.exe" refresh

Write-Output 'VIPM install complete.'
