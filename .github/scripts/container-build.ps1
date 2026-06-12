# Runs INSIDE the stock NI LabVIEW container, AFTER container-install-deps.ps1
# has VIPM-installed the dragon dependencies into the target LabVIEW. Builds
# the test_build spec with that SAME LabVIEW version and verifies the EXE.

try {
    $ErrorActionPreference = 'Stop'

    $cliExe     = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $targetFile = 'C:\workspace\lv-target.txt'
    # test_build spec: Bld_localDestDir=../Build relative to Source/ => C:\workspace\Build
    $expectedExe = 'C:\workspace\Build\Application.exe'

    if (-not (Test-Path $targetFile)) { throw "missing $targetFile (install step did not run?)" }
    $year = (Get-Content $targetFile | Select-Object -First 1).Trim()
    $lvExe = "C:\Program Files\National Instruments\LabVIEW $year\LabVIEW.exe"
    if (-not (Test-Path $lvExe)) { throw "LabVIEW.exe not found: $lvExe" }
    Write-Host "Building with LabVIEW $year ($lvExe)"

    & $cliExe -LogToConsole TRUE `
        -OperationName ExecuteBuildSpec `
        -ProjectPath 'C:\workspace\Source\Simple_Project.lvproj' `
        -BuildSpecName 'test_build' `
        -LabVIEWPath $lvExe `
        -Headless
    if ($LASTEXITCODE -ne 0) { throw "ExecuteBuildSpec failed with exit code $LASTEXITCODE" }

    if (-not (Test-Path $expectedExe)) { throw "build output missing: $expectedExe" }
    $exe = Get-Item $expectedExe
    if ($exe.Length -le 0) { throw "build output is empty: $expectedExe" }
    Write-Host "BUILD OK: $($exe.FullName) ($($exe.Length) bytes)"
    exit 0
}
catch {
    Write-Host "FATAL (container-build): $($_ | Out-String)"
    exit 1
}
