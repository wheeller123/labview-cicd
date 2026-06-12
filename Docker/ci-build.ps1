# Runs INSIDE the stock NI LabVIEW container (nationalinstruments/labview:latest-windows).
# The workflow has already downloaded, SHA256-verified and extracted
# oglib_array-6.0.1.20.vip to C:\workspace\_oglib. This script copies the
# OpenG payload into LabVIEW 2026's user.lib (what a VIPM install of
# File Group 0 would do; the package has no dependencies), then builds the
# test_build spec and verifies the EXE genuinely exists.

$ErrorActionPreference = 'Stop'

$labviewDir  = 'C:\Program Files\National Instruments\LabVIEW 2026'
$projectPath = 'C:\workspace\Source\Simple_Project.lvproj'
$payloadSrc  = 'C:\workspace\_oglib\File Group 0\user.lib\_OpenG.lib'
# test_build spec: Bld_localDestDir=../Build relative to Source/ => repo-root Build\
$expectedExe = 'C:\workspace\Build\Application.exe'

if (-not (Test-Path $payloadSrc)) { throw "OpenG payload not found at $payloadSrc" }

# Install the OpenG array library payload into user.lib.
Copy-Item -Path $payloadSrc -Destination (Join-Path $labviewDir 'user.lib') -Recurse -Force

# Build, pinning the container's LabVIEW 2026 explicitly.
& LabVIEWCLI -LogToConsole TRUE `
    -OperationName ExecuteBuildSpec `
    -ProjectPath $projectPath `
    -BuildSpecName 'test_build' `
    -LabVIEWPath (Join-Path $labviewDir 'LabVIEW.exe') `
    -Headless
if ($LASTEXITCODE -ne 0) { throw "ExecuteBuildSpec failed with exit code $LASTEXITCODE" }

# Verify the build genuinely produced the EXE.
if (-not (Test-Path $expectedExe)) { throw "Build output missing: $expectedExe" }
$exe = Get-Item $expectedExe
Write-Host "BUILD OK: $($exe.FullName) ($($exe.Length) bytes)"
