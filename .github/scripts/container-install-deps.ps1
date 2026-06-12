# Runs INSIDE the stock NI LabVIEW container.
#
# Strategy: VIPM's package_install drives LabVIEW over VI Server (TCP 3363).
# VIPM itself launches LabVIEW.exe with NO arguments, which CRASHES in this
# container (crashpad_handler spawns moments later); LabVIEWCLI's launch
# survives because of its flags (`LabVIEW.exe --headless -labviewcli`).
# A MassCompile keep-alive also fails: it keeps LabVIEW's UI thread busy so
# VI Server never services VIPM's requests.
#
# So: launch an IDLE headless LabVIEW ourselves (--headless, falling back to
# --headless -labviewcli), verify the process survives and VI Server listens
# on 3363, run `vipm version` -> `vipm refresh`, align VIPM's live [Targets]
# entry (port 3363, Tested=TRUE, active), restart the VIPM Desktop so it
# re-reads settings, then run a real `vipm install <dragon>` against the live
# instance. Every dependency declared in the dragon file is verified via
# `vipm list --installed`. Finally LabVIEW is shut down so the build step
# starts from a clean session. A background watcher logs every LabVIEW /
# LabVIEWCLI / crashpad_handler spawn throughout, so crashes and rogue VIPM
# launches are observable.
#
# Template-quality: the dragon file is the single source of truth for both the
# pinned LabVIEW version and the dependency list. Nothing package-specific is
# hardcoded here.

$ErrorActionPreference = 'Stop'

$vipmExe  = 'C:\Program Files\JKI\VI Package Manager\support\vipm.exe'
$dragon   = 'C:\workspace\Source\Simple_Project.dragon'
$niDir    = 'C:\Program Files\National Instruments'
$settings = 'C:\ProgramData\JKI\VIPM\Settings.ini'
$targetFile = 'C:\workspace\lv-target.txt'

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

try {
    # ---- 1. Parse the dragon file (single source of truth) -------------------
    if (-not (Test-Path $dragon)) { throw "dragon file not found: $dragon" }
    $dragonYear = $null
    $deps = @()
    $inDeps = $false
    foreach ($line in (Get-Content $dragon)) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $inDeps = ($Matches[1] -eq 'vipm.dependencies'); continue }
        if ($line -match '^\s*labview-version\s*=\s*"?(\d{4})"?') { $dragonYear = [int]$Matches[1] }
        if ($inDeps -and $line -match '^\s*([A-Za-z0-9_\-\.]+)\s*=') { $deps += $Matches[1] }
    }
    if ($deps.Count -eq 0) { throw "no [vipm.dependencies] entries found in $dragon" }
    Write-Host "Dragon pins LabVIEW $dragonYear; dependencies: $($deps -join ', ')"

    # ---- 2. Discover installed LabVIEW dev systems ---------------------------
    $installed = @(Get-ChildItem $niDir -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path (Join-Path $_.FullName 'LabVIEW.exe')) -and ($_.Name -match 'LabVIEW (\d{4})$') } |
        ForEach-Object { [int]($_.Name -replace 'LabVIEW ', '') } | Sort-Object)
    if ($installed.Count -eq 0) { throw "no LabVIEW dev systems found under $niDir" }
    Write-Host "Installed LabVIEW versions: $($installed -join ', ')"

    # ---- 3. LabVIEW versions VIPM can see (Settings.ini [Targets]) -----------
    $visible = @()
    $inTargets = $false
    if (Test-Path $settings) {
        foreach ($line in (Get-Content $settings)) {
            if ($line -match '^\[(.+)\]') { $inTargets = ($Matches[1] -eq 'Targets') }
            if ($inTargets -and $line -match 'Versions \d+="(\d+)\.\d+') { $visible += (2000 + [int]$Matches[1]) }
        }
    }
    Write-Host "VIPM-visible LabVIEW versions: $(if ($visible) { $visible -join ', ' } else { '(none parsed)' })"

    # ---- 4. Choose the target: dragon-pinned if usable, else newest ----------
    $candidates = @($installed | Where-Object { ($visible.Count -eq 0) -or ($visible -contains $_) })
    if ($candidates.Count -eq 0) { $candidates = $installed }
    $year = if ($dragonYear -and ($candidates -contains $dragonYear)) { $dragonYear }
            else { ($candidates | Measure-Object -Maximum).Maximum }
    $lvDir = Join-Path $niDir "LabVIEW $year"
    $lvExe = Join-Path $lvDir 'LabVIEW.exe'
    Write-Host "Target: LabVIEW $year (64-bit) at $lvExe"
    Set-Content -Path $targetFile -Value $year -Force

    # ---- 5. Enable VI Server in the target's LabVIEW.ini ---------------------
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


    # ---- 7. IDLE headless keep-alive LabVIEW ----------------------------------
    $kaProc = Start-IdleLabVIEW $lvExe @('--headless') 'variant A (--headless)' 6
    if (-not $kaProc) {
        $kaProc = Start-IdleLabVIEW $lvExe @('--headless', '-labviewcli') 'variant B (--headless -labviewcli)' 6
    }
    if (-not $kaProc) {
        throw 'no headless LabVIEW launch variant stayed alive with port 3363 open'
    }
    Write-Host "Idle keep-alive LabVIEW established (PID $($kaProc.Id))."
    Start-Sleep -Seconds 20   # let LabVIEW settle before VIPM connects

    # ---- 8. vipm version -> vipm refresh (required order) ---------------------
    Write-Host '== vipm version =='
    & $vipmExe version
    Write-Host "vipm version exit code: $LASTEXITCODE"
    Write-Host '== vipm refresh =='
    & $vipmExe refresh
    if ($LASTEXITCODE -ne 0) { throw "vipm refresh failed with exit code $LASTEXITCODE" }

    # ---- 9. Align VIPM's live target entry with the held-open LabVIEW ---------
    # VIPM connects to the port configured on ITS target entry; make sure the
    # entry for our LabVIEW says port 3363, Tested=TRUE, Disabled=FALSE, and is
    # the active target, then restart the VIPM Desktop so it re-reads settings.
    $content = @(Get-Content $settings)
    $targetIdx = $null
    $targetVer = $null
    $inTargets = $false
    foreach ($l in $content) {
        if ($l -match '^\[(.+)\]') { $inTargets = ($Matches[1] -eq 'Targets') }
        elseif ($inTargets -and $l -match '^Versions (\d+)="((\d+)\.[^"]*)"') {
            if ((2000 + [int]$Matches[3]) -eq $year) { $targetIdx = [int]$Matches[1]; $targetVer = $Matches[2] }
        }
    }
    if ($null -eq $targetIdx) {
        Write-Host "WARNING: no [Targets] entry found for LabVIEW $year; leaving Settings.ini untouched."
    } else {
        Write-Host "Aligning [Targets] entry $targetIdx ($targetVer): port 3363, Tested=TRUE, Disabled=FALSE, active."
        $aligned = foreach ($l in $content) {
            if ($l -match '^Ports="<size\(s\)=(\d+)>\s*([^"]*)"') {
                $vals = @($Matches[2].Trim() -split '\s+')
                if ($vals.Count -gt $targetIdx) { $vals[$targetIdx] = '3363' }
                'Ports="<size(s)=' + $Matches[1] + '> ' + ($vals -join ' ') + '"'
            }
            elseif ($l -match "^Tested $targetIdx=")   { "Tested $targetIdx=`"TRUE`"" }
            elseif ($l -match "^Disabled $targetIdx=") { "Disabled $targetIdx=`"FALSE`"" }
            elseif ($l -match '^Connection Timeout=')  { 'Connection Timeout="600"' }
            elseif ($l -match '^Active Target\.Version=') { "Active Target.Version=`"$targetVer`"" }
            else { $l }
        }
        Set-Content -Path $settings -Value $aligned -Force

        Write-Host '== restarting VIPM Desktop so it re-reads settings =='
        Stop-Process -Name 'VI Package Manager' -Force -ErrorAction SilentlyContinue
        Stop-Process -Name 'vipm' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10

    }
    if ($kaProc.HasExited) { throw 'keep-alive LabVIEW died before the install started' }

    # ---- 10. Real vipm install of the dragon file -----------------------------
    # --yes: skip [y/N] prompt; --timeout 1500: replace ~180s default; version/
    # bitness flags: the dragon's pin is only honored when that LabVIEW exists,
    # otherwise we explicitly retarget the held-open LabVIEW.
    Write-Host "== vipm install $dragon (LabVIEW $year, 64-bit) =="
    & $vipmExe -v --timeout 1500 --labview-version $year --labview-bitness 64 install --yes $dragon
    $rc = $LASTEXITCODE
    Write-Host "vipm install exit code: $rc"
    if ($rc -ne 0) {
        throw "vipm install failed with exit code $rc"
    }

    # ---- 11. Verify EVERY dragon dependency is genuinely installed ------------
    Write-Host '== vipm list --installed =='
    $listOut = (& $vipmExe --labview-version $year --labview-bitness 64 list --installed) | Out-String
    Write-Host $listOut
    if ($LASTEXITCODE -ne 0) { throw "vipm list --installed failed with exit code $LASTEXITCODE" }
    foreach ($d in $deps) {
        if ($listOut -notmatch [regex]::Escape($d)) {
            throw "dependency '$d' from the dragon file is NOT reported installed"
        }
        Write-Host "VERIFIED installed: $d"
    }

    # ---- 12. Tear down the keep-alive so the build gets a clean LabVIEW -------
    Write-Host '== shutting down keep-alive LabVIEW =='
    Stop-Process -Name 'LabVIEW' -Force -ErrorAction SilentlyContinue
    $gone = $false
    for ($i = 0; $i -lt 12; $i++) {
        if (-not (Get-Process -Name 'LabVIEW' -ErrorAction SilentlyContinue)) { $gone = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $gone) { throw 'LabVIEW still running 60s after Stop-Process' }
    # Drop autosave/recovery leftovers so the build's LabVIEW launch cannot
    # stall on an "autorecover?" prompt after the forced kill.
    Get-ChildItem "$env:USERPROFILE\Documents" -Directory -Filter 'LabVIEW Data*' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem $_.FullName -Directory -Filter 'LVAutoSave*' -Recurse -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    Write-Host 'Keep-alive stopped; dependencies installed and verified.'
    exit 0
}
catch {
    Write-Host "FATAL (container-install-deps): $($_ | Out-String)"
    exit 1
}
