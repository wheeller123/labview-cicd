# Runs INSIDE the stock NI LabVIEW container.
# Installs NI Package Manager + VIPM (preview CLI), seeds VIPM's Settings.ini
# (without it `vipm refresh` hangs on first-launch setup) with a CORRECT
# [Targets] section describing the LabVIEWs actually installed in this image
# (pre-tested, port 3363), then refreshes the package list.

function Get-InstalledLabVIEWs {
    @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path (Join-Path $_.FullName 'LabVIEW.exe')) -and ($_.Name -match 'LabVIEW \d{4}$') } |
        Sort-Object Name)
}

try {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $vipmExe = 'C:\Program Files\JKI\VI Package Manager\support\vipm.exe'
    $nipmUrl = 'https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager25.8.0.exe'
    $vipmUrl = 'https://packages.jki.net/vipm/preview/vipm-setup-latest-preview.exe'
    $settings = 'C:\ProgramData\JKI\VIPM\Settings.ini'

    if (Test-Path $vipmExe) {
        Write-Host 'VIPM already present; skipping installer downloads.'
    } else {
        Write-Host '== Installing NI Package Manager =='
        Invoke-WebRequest -Uri $nipmUrl -OutFile 'C:\nipm-setup.exe'
        $p = Start-Process -Wait -PassThru -FilePath 'C:\nipm-setup.exe' `
            -ArgumentList '--passive', '--accept-eulas', '--prevent-reboot'
        Write-Host "NIPM installer exit code: $($p.ExitCode)"
        if ($p.ExitCode -notin @(0, 3010, -125071, -125083)) {
            throw "NIPM installer failed with unexpected exit code $($p.ExitCode)"
        }

        Write-Host '== Installing VIPM (latest preview) =='
        Invoke-WebRequest -Uri $vipmUrl -OutFile 'C:\vipm-setup.exe'
        # /exenoui /qn is the ONLY reliably non-interactive flag combo.
        $p = Start-Process -Wait -PassThru -FilePath 'C:\vipm-setup.exe' `
            -ArgumentList '/exenoui', '/qn'
        Write-Host "VIPM installer exit code: $($p.ExitCode)"

        if (-not (Test-Path $vipmExe)) {
            throw "vipm.exe not found at $vipmExe after install"
        }
        Write-Host 'VIPM installed.'
    }

    Write-Host '== Seeding VIPM Settings.ini =='
    # Post-install mass compile would blow VIPM's install timeout; raise the
    # VI Server connection timeout for the slow containerized LabVIEW.
    $ini = Get-Content 'C:\workspace\Docs\Settings.ini'
    $ini = $ini -replace 'Mass Compile After Package Install\?="TRUE"', 'Mass Compile After Package Install?="FALSE"'

    # Replace the donor [Targets] section (describes the donor machine's
    # LabVIEW 2023) with one describing the LabVIEWs actually present here,
    # all pre-tested on VI Server port 3363, so VIPM never has to auto-create
    # or "test" a target by launching LabVIEW itself (a plain LabVIEW launch
    # dies instantly inside this container).
    $lvs = Get-InstalledLabVIEWs
    if ($lvs.Count -eq 0) { throw 'no LabVIEW installations found to build a [Targets] section from' }
    $n = $lvs.Count
    $versions = @()
    $targets = @('[Targets]', "Names.<size(s)>=`"$n`"")
    for ($i = 0; $i -lt $n; $i++) { $targets += "Names $i=`"LabVIEW`"" }
    $targets += "Versions.<size(s)>=`"$n`""
    for ($i = 0; $i -lt $n; $i++) {
        $exe = Join-Path $lvs[$i].FullName 'LabVIEW.exe'
        $vi = (Get-Item $exe).VersionInfo
        $versions += "$($vi.FileMajorPart).$($vi.FileMinorPart) (64-bit)"
        $targets += "Versions $i=`"$($versions[$i])`""
    }
    $targets += "Locations.<size(s)>=`"$n`""
    for ($i = 0; $i -lt $n; $i++) {
        $exe = Join-Path $lvs[$i].FullName 'LabVIEW.exe'
        $loc = '/' + $exe[0] + ($exe.Substring(2) -replace '\\', '/')
        $targets += "Locations $i=`"$loc`""
    }
    $targets += 'Ports="<size(s)=' + $n + '> ' + ((@('3363') * $n) -join ' ') + '"'
    $targets += "Tested.<size(s)>=`"$n`""
    for ($i = 0; $i -lt $n; $i++) { $targets += "Tested $i=`"TRUE`"" }
    $targets += "Disabled.<size(s)>=`"$n`""
    for ($i = 0; $i -lt $n; $i++) { $targets += "Disabled $i=`"FALSE`"" }
    $targets += 'Connection Timeout="600"'
    $targets += 'Active Target.Name="LabVIEW"'
    $targets += "Active Target.Version=`"$($versions[$n - 1])`""   # newest
    $targets += 'PingDelay(ms)="-1"'
    $targets += 'PingTimeout(ms)="60000"'
    $targets += "CommunityEdition.<size(s)>=`"$n`""
    for ($i = 0; $i -lt $n; $i++) { $targets += "CommunityEdition $i=`"FALSE`"" }

    # Splice: drop the donor [Targets] body, insert ours.
    $out = New-Object System.Collections.Generic.List[string]
    $inTargets = $false
    foreach ($line in $ini) {
        if ($line -match '^\[(.+)\]') {
            if ($Matches[1] -eq 'Targets') { $inTargets = $true; $targets | ForEach-Object { $out.Add($_) }; continue }
            $inTargets = $false
        }
        if (-not $inTargets) { $out.Add($line) }
    }
    New-Item -ItemType Directory -Force -Path 'C:\ProgramData\JKI\VIPM' | Out-Null
    Set-Content -Path $settings -Value $out -Force
    Write-Host 'Seeded Settings.ini with corrected [Targets] (port 3363, pre-tested).'

    Write-Host '== vipm version =='
    & $vipmExe version
    Write-Host "vipm version exit code: $LASTEXITCODE"

    Write-Host '== vipm refresh =='
    & $vipmExe refresh
    if ($LASTEXITCODE -ne 0) { throw "vipm refresh failed with exit code $LASTEXITCODE" }

    Write-Host 'VIPM setup complete.'
    exit 0
}
catch {
    Write-Host "FATAL (container-setup-vipm): $($_ | Out-String)"
    exit 1
}
