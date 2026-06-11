# 1. Install NI Package Manager ------------------------------------------------
Write-Output 'Installing NI Package Manager...'
$exe = Join-Path $env:TEMP 'NIPackageManager.exe'
Invoke-WebRequest -Uri "https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager25.8.0.exe" -OutFile $exe
$p = Start-Process -Wait -PassThru -FilePath $exe -ArgumentList "--passive", "--accept-eulas", "--prevent-reboot"
# NI installers: 0 = success, 3010 / -125071 = success but reboot needed.
if ($p.ExitCode -notin 0, 3010, -125071) { throw "NIPM install failed: $($p.ExitCode)" }

# 2. Install NI LabVIEW 2020 SP1 Runtime (VIPM prerequisite) -------------------
Write-Output 'Installing NI LabVIEW 2020 SP1 Runtime...'
& "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe" feed-add --name=lvrte2020 "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020-runtime-engine/20.1/released"
& "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe" feed-add --name=lvrte2020-critical "https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2020-runtime-engine/20.1/released-critical"
& "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe" update
& "C:\Program Files\National Instruments\NI Package Manager\nipkg.exe" install --accept-eulas --assume-yes ni-labview-2020-runtime-engine
# -125071 = reboot needed; packages are installed, but we cannot reboot here.
if ($LASTEXITCODE -notin 0, -125071) { throw "nipkg install failed: $LASTEXITCODE" }

# 3. Install VIPM --------------------------------------------------------------
Write-Output 'Installing VIPM...'
$exe = Join-Path $env:TEMP 'vipm-setup.exe'
Invoke-WebRequest -Uri "https://packages.jki.net/vipm/preview/vipm-setup-latest-preview.exe" -OutFile $exe
# /exenoui /qn is the only fully non-interactive invocation; other flag
# combinations hang the installer.
$p = Start-Process -Wait -PassThru -FilePath $exe -ArgumentList "/exenoui", "/qn"
if ($p.ExitCode -ne 0) { throw "VIPM install failed: $($p.ExitCode)" }
# Add VIPM to PATH for this session.
$env:PATH = "C:\Program Files\JKI\VI Package Manager\support;$env:PATH"

# 4. Seed VIPM Settings.ini ----------------------------------------------------
# Without a Settings.ini, "vipm refresh" hangs on first-launch setup.
Write-Output 'Seeding VIPM Settings.ini...'
New-Item -ItemType Directory -Force -Path "C:\Scripts" | Out-Null
Copy-Item -Path "$env:USERPROFILE\Downloads\Settings.ini" -Destination "C:\Scripts\Settings.ini" -Force
New-Item -ItemType Directory -Force -Path "C:\ProgramData\JKI\VIPM" | Out-Null
Copy-Item -Path "C:\Scripts\Settings.ini" -Destination "C:\ProgramData\JKI\VIPM\Settings.ini" -Force

# 5. VIPM version --------------------------------------------------------------
& "C:\Program Files\JKI\VI Package Manager\support\vipm.exe" version

# 6. VIPM refresh --------------------------------------------------------------
& "C:\Program Files\JKI\VI Package Manager\support\vipm.exe" refresh

Write-Output 'install-packages complete.'
