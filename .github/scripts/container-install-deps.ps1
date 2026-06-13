# Runs INSIDE the stock NI LabVIEW container.
#
# Installs the dragon file's dependencies into EVERY LabVIEW dev system present
# in the image (not just one), so the later build step can produce a build-spec
# output per LabVIEW version. For an EXE the version makes no difference, but
# for lvlibs / packed libraries (e.g. VeriStand custom devices for RT targets)
# the saved LabVIEW version determines downstream compatibility, so users need
# the artifact built with their exact LabVIEW version.
#
# Strategy (per version): VIPM's package_install drives LabVIEW over VI Server
# (TCP 3363). VIPM itself launches LabVIEW.exe with NO arguments, which CRASHES
# in this container; LabVIEWCLI's launch survives because of its flags
# (`LabVIEW.exe --headless -labviewcli`). A MassCompile keep-alive also fails:
# it keeps LabVIEW's UI thread busy so VI Server never services VIPM. So we
# launch an IDLE headless LabVIEW ourselves, verify port 3363, run
# `vipm version` -> `vipm refresh`, align VIPM's live [Targets] entry to that
# LabVIEW (port 3363, Tested=TRUE, active) and restart VIPM Desktop, then run a
# real `vipm install <dragon>` and verify every dependency via
# `vipm list --installed`.
#
# Template-quality: the dragon file is the single source of truth for the
# dependency list. Nothing package-specific is hardcoded.

$ErrorActionPreference = 'Stop'

$vipmExe   = 'C:\Program Files\JKI\VI Package Manager\support\vipm.exe'
$dragon    = 'C:\workspace\Source\Simple_Project.dragon'
$niDir     = 'C:\Program Files\National Instruments'
$settings  = 'C:\ProgramData\JKI\VIPM\Settings.ini'
$targetsFile = 'C:\workspace\lv-targets.txt'   # newline-separated list of built versions

function Test-Port3363 {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', 3363, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(2000) -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

# Launches LabVIEW with the given args; returns the process only if it
# survives 60s AND VI Server opens port 3363 within $portWaitMinutes.
function Start-IdleLabVIEW {
    param([string]$exe, [string[]]$argList, [string]$label, [int]$portWaitMinutes)
    Write-Host "== keep-alive launch $label : $exe $($argList -join ' ') =="
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru
    Write-Host "LabVIEW PID $($proc.Id); verifying survival (60s)..."
    for ($i = 1; $i -le 6; $i++) {
        Start-Sleep -Seconds 10
        if ($proc.HasExited) {
            Write-Host "$label DIED after ~$($i * 10)s (exit code $($proc.ExitCode))"
            return $null
        }
    }
    Write-Host "$label survived 60s; waiting for VI Server port 3363 (up to $portWaitMinutes min)..."
    $deadline = (Get-Date).AddMinutes($portWaitMinutes)
    while ((Get-Date) -lt $deadline) {
        if (Test-Port3363) { Write-Host "$label : port 3363 OPEN"; return $proc }
        if ($proc.HasExited) {
            Write-Host "$label exited (code $($proc.ExitCode)) while waiting for the port"
            return $null
        }
        Start-Sleep -Seconds 10
    }
    Write-Host "$label : port 3363 did not open in $portWaitMinutes min; killing PID $($proc.Id)"
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    return $null
}

function Stop-AllLabVIEW {
    Stop-Process -Name 'LabVIEW' -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 12; $i++) {
        if (-not (Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)) { return }
        Start-Sleep -Seconds 5
    }
    throw 'LabVIEW still running 60s after Stop-Process'
}

# Installs the dragon dependencies into a single LabVIEW version. Throws on
# failure so the caller can record it.
function Install-DepsForVersion {
    param([int]$year, [string[]]$deps)

    $lvDir = Join-Path $niDir "LabVIEW $year"
    $lvExe = Join-Path $lvDir 'LabVIEW.exe'
    Write-Host ""
    Write-Host "##########[ Installing deps into LabVIEW $year ]##########"

    # --- Enable VI Server in this version's LabVIEW.ini ---
    $serverKeys = [ordered]@{
        'server.tcp.enabled'           = 'True'
        'server.tcp.port'              = '3363'
        'server.tcp.access'            = '"+*"'
        'server.vi.access'             = '"+*"'
        'server.app.propertiesEnabled' = 'True'
        'server.vi.propertiesEnabled'  = 'True'
        'server.vi.callsEnabled'       = 'True'
        'ShowWelcomeOnLaunch'          = 'False'
    }
    $iniPath = Join-Path $lvDir 'LabVIEW.ini'
    $lines = if (Test-Path $iniPath) { @(Get-Content $iniPath) } else { @() }
    if ($lines -notcontains '[LabVIEW]') { $lines = @('[LabVIEW]') + $lines }
    foreach ($k in $serverKeys.Keys) {
        $lines = @($lines | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($k))\s*=" })
    }
    $idx = [array]::IndexOf($lines, '[LabVIEW]')
    $inject = @($serverKeys.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
    $tail = if ($idx + 1 -le $lines.Count - 1) { $lines[($idx + 1)..($lines.Count - 1)] } else { @() }
    $lines = @($lines[0..$idx]) + $inject + @($tail)
    Set-Content -Path $iniPath -Value $lines -Encoding Ascii -Force
    Write-Host "VI Server enabled in $iniPath (port 3363)."

    # --- Idle headless keep-alive LabVIEW ---
    $kaProc = Start-IdleLabVIEW $lvExe @('--headless') 'variant A (--headless)' 6
    if (-not $kaProc) {
        $kaProc = Start-IdleLabVIEW $lvExe @('--headless', '-labviewcli') 'variant B (--headless -labviewcli)' 6
    }
    if (-not $kaProc) {
        throw "LabVIEW $year : no headless launch variant stayed alive with port 3363 open"
    }
    Write-Host "Idle keep-alive LabVIEW established (PID $($kaProc.Id))."
    Start-Sleep -Seconds 20

    # --- vipm version -> vipm refresh (required order) ---
    Write-Host '== vipm version =='
    & $vipmExe version
    Write-Host "vipm version exit code: $LASTEXITCODE"
    Write-Host '== vipm refresh =='
    & $vipmExe refresh
    if ($LASTEXITCODE -ne 0) { throw "vipm refresh failed with exit code $LASTEXITCODE" }

    # --- Align VIPM's live [Targets] entry for this version to port 3363 ---
    $content = @(Get-Content $settings)
    $targetIdx = $null; $targetVer = $null; $inTargets = $false
    foreach ($l in $content) {
        if ($l -match '^\[(.+)\]') { $inTargets = ($Matches[1] -eq 'Targets') }
        elseif ($inTargets -and $l -match '^Versions (\d+)="((\d+)\.[^"]*)"') {
            if ((2000 + [int]$Matches[3]) -eq $year) { $targetIdx = [int]$Matches[1]; $targetVer = $Matches[2] }
        }
    }
    if ($null -eq $targetIdx) {
        Write-Host "WARNING: no [Targets] entry found for LabVIEW $year; leaving Settings.ini untouched."
    } else {
        Write-Host "Aligning [Targets] entry $targetIdx ($targetVer): port 3363, Tested=TRUE, active."
        $aligned = foreach ($l in $content) {
            if ($l -match '^Ports="<size\(s\)=(\d+)>\s*([^"]*)"') {
                $vals = @($Matches[2].Trim() -split '\s+')
                if ($vals.Count -gt $targetIdx) { $vals[$targetIdx] = '3363' }
                'Ports="<size(s)=' + $Matches[1] + '> ' + ($vals -join ' ') + '"'
            }
            elseif ($l -match "^Tested $targetIdx=")     { "Tested $targetIdx=`"TRUE`"" }
            elseif ($l -match "^Disabled $targetIdx=")   { "Disabled $targetIdx=`"FALSE`"" }
            elseif ($l -match '^Connection Timeout=')    { 'Connection Timeout="600"' }
            elseif ($l -match '^Active Target\.Version=') { "Active Target.Version=`"$targetVer`"" }
            else { $l }
        }
        Set-Content -Path $settings -Value $aligned -Force
        Write-Host '== restarting VIPM Desktop so it re-reads settings =='
        Stop-Process -Name 'VI Package Manager' -Force -ErrorAction SilentlyContinue
        Stop-Process -Name 'vipm' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10
    }
    if ($kaProc.HasExited) { throw "LabVIEW $year : keep-alive died before the install started" }

    # --- Real vipm install of the dragon file into this version ---
    Write-Host "== vipm install $dragon (LabVIEW $year, 64-bit) =="
    & $vipmExe -v --timeout 1500 --labview-version $year --labview-bitness 64 install --yes $dragon
    if ($LASTEXITCODE -ne 0) { throw "vipm install (LabVIEW $year) failed with exit code $LASTEXITCODE" }

    # --- Verify EVERY dragon dependency is genuinely installed ---
    Write-Host '== vipm list --installed =='
    $listOut = (& $vipmExe --labview-version $year --labview-bitness 64 list --installed) | Out-String
    Write-Host $listOut
    if ($LASTEXITCODE -ne 0) { throw "vipm list --installed (LabVIEW $year) failed with exit code $LASTEXITCODE" }
    foreach ($d in $deps) {
        if ($listOut -notmatch [regex]::Escape($d)) {
            throw "dependency '$d' is NOT reported installed for LabVIEW $year"
        }
        Write-Host "VERIFIED installed (LabVIEW ${year}): $d"
    }

    # --- Tear down so the next version (and the build) start clean ---
    Stop-AllLabVIEW
    Get-ChildItem "$env:USERPROFILE\Documents" -Directory -Filter 'LabVIEW Data*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem $_.FullName -Directory -Filter 'LVAutoSave*' -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    Write-Host "LabVIEW $year : dependencies installed and verified."
}

try {
    # ---- Parse the dragon file (single source of truth for the dep list) -----
    if (-not (Test-Path $dragon)) { throw "dragon file not found: $dragon" }
    $deps = @()
    $inDeps = $false
    foreach ($line in (Get-Content $dragon)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $inDeps = ($Matches[1] -eq 'vipm.dependencies'); continue }
        if ($inDeps -and $line -match '^\s*([A-Za-z0-9_\-\.]+)\s*=') { $deps += $Matches[1] }
    }
    if ($deps.Count -eq 0) { throw "no [vipm.dependencies] entries found in $dragon" }
    Write-Host "Dragon dependencies: $($deps -join ', ')"

    # ---- Discover EVERY installed LabVIEW dev system -------------------------
    $installed = @(Get-ChildItem $niDir -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path (Join-Path $_.FullName 'LabVIEW.exe')) -and ($_.Name -match 'LabVIEW (\d{4})$') } |
        ForEach-Object { [int]($_.Name -replace 'LabVIEW ', '') } | Sort-Object)
    if ($installed.Count -eq 0) { throw "no LabVIEW dev systems found under $niDir" }
    Write-Host "Installing deps into ALL LabVIEW versions: $($installed -join ', ')"

    # ---- Install into each version; record which succeeded -------------------
    $built = @()
    foreach ($year in $installed) {
        Install-DepsForVersion -year $year -deps $deps
        $built += $year
    }

    Set-Content -Path $targetsFile -Value ($built -join "`n") -Force
    Write-Host ""
    Write-Host "Dependency install complete for: $($built -join ', ')"
    exit 0
}
catch {
    Write-Host "FATAL (container-install-deps): $($_ | Out-String)"
    exit 1
}
