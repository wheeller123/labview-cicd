# Runs INSIDE the stock NI LabVIEW container, AFTER container-install-deps.ps1
# has VIPM-installed the dragon dependencies into every LabVIEW version.
#
# Builds the test_build spec with EACH LabVIEW version and saves the output to
# Build\<year>\ so the user can download the artifact built with their exact
# LabVIEW version. For an EXE the version is irrelevant, but for lvlibs / packed
# libraries (e.g. VeriStand custom devices for RT targets) the saved LabVIEW
# version determines downstream compatibility.

try {
    $ErrorActionPreference = 'Stop'

    $cliExe      = 'C:\Program Files (x86)\National Instruments\Shared\LabVIEW CLI\LabVIEWCLI.exe'
    $targetsFile = 'C:\workspace\lv-targets.txt'
    $projectPath = 'C:\workspace\Source\Simple_Project.lvproj'
    $buildSpec   = 'test_build'
    # test_build spec: Bld_localDestDir=../Build relative to Source/ => C:\workspace\Build
    $rawBuildDir = 'C:\workspace\Build'
    $expectedExe = Join-Path $rawBuildDir 'Application.exe'

    if (-not (Test-Path $targetsFile)) { throw "missing $targetsFile (install step did not run?)" }
    $years = @(Get-Content $targetsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($years.Count -eq 0) { throw "no LabVIEW versions listed in $targetsFile" }
    Write-Host "Building '$buildSpec' with LabVIEW versions: $($years -join ', ')"

    foreach ($year in $years) {
        $lvExe = "C:\Program Files\National Instruments\LabVIEW $year\LabVIEW.exe"
        if (-not (Test-Path $lvExe)) { throw "LabVIEW.exe not found: $lvExe" }
        Write-Host ""
        Write-Host "##########[ Building with LabVIEW $year ]##########"

        # Clear the spec's destination so each version's output is clean.
        if (Test-Path $rawBuildDir) { Remove-Item $rawBuildDir -Recurse -Force }

        & $cliExe -LogToConsole TRUE `
            -OperationName ExecuteBuildSpec `
            -ProjectPath $projectPath `
            -BuildSpecName $buildSpec `
            -LabVIEWPath $lvExe `
            -Headless
        if ($LASTEXITCODE -ne 0) { throw "ExecuteBuildSpec (LabVIEW $year) failed with exit code $LASTEXITCODE" }

        if (-not (Test-Path $expectedExe)) { throw "build output missing for LabVIEW ${year}: $expectedExe" }
        if ((Get-Item $expectedExe).Length -le 0) { throw "build output empty for LabVIEW ${year}: $expectedExe" }

        # Move this version's output into a per-version folder.
        $verDir = "C:\workspace\Build-$year"
        if (Test-Path $verDir) { Remove-Item $verDir -Recurse -Force }
        Move-Item -Path $rawBuildDir -Destination $verDir -Force
        Write-Host "BUILD OK (LabVIEW ${year}): $verDir ($((Get-Item (Join-Path $verDir 'Application.exe')).Length) bytes)"
    }

    Write-Host ""
    Write-Host "All builds complete: $($years.ForEach({ "Build-$_" }) -join ', ')"
    exit 0
}
catch {
    Write-Host "FATAL (container-build): $($_ | Out-String)"
    exit 1
}
