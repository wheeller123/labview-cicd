# VIPM + LabVIEW CI Guide — proven recipes and hard-won findings

> Handoff document for AI assistants / engineers. Everything below was proven
> on real CI runs in this repo (June 2026). Follow it to install LabVIEW
> dependencies with **VIPM (latest preview CLI)** and compile **LabVIEW build
> specs** in CI without rediscovering ~30 failed runs' worth of dead ends.

---

## TL;DR — the two working pipelines

| Pipeline | Where | Status |
|---|---|---|
| **NI Docker container build** (no LabVIEW license needed) | `.github/workflows/ni-docker.yml` + `.github/scripts/container-*.ps1` | ✅ proven green (runs 27425083219, 27426398028) |
| **Bare-runner VIPM stack** (no LabVIEW dev system; VIPM CLI only) | `.github/workflows/labview-windows.yaml` | ✅ proven green |
| GitLab on self-hosted runner with licensed LabVIEW | `.gitlab-ci.yml` | partially proven (VIPM stack ✅; dragon/build needs a licensed runner) |

The **NI Docker pipeline is the template**: any project's `.dragon` file drives
the dependency install; nothing package-specific is hardcoded.

---

## 1. The NI Docker pipeline (template) — how and WHY it works

### Architecture
1. `windows-latest` GitHub runner → `docker run` NI's official image
   `nationalinstruments/labview:latest-windows` (LabVIEW 2026, pre-licensed
   for headless CI; Server 2022 base; ~13 min pull).
2. One **detached container** (`docker run -d --name lv ... ping -t localhost`)
   + `docker exec` per stage, so VIPM install, dependency install and build
   share state.
3. Three scripts run inside the container, in order:
   - `container-setup-vipm.ps1` — install NIPM + VIPM preview, seed
     Settings.ini, `vipm version` → `vipm refresh`
   - `container-install-deps.ps1` — parse dragon, keep-alive LabVIEW,
     `vipm install --yes <dragon>`, verify
   - `container-build.ps1` — `LabVIEWCLI ExecuteBuildSpec`, verify EXE

### THE critical discovery (read this before changing anything)
**VIPM launches `LabVIEW.exe` with NO arguments, and a plain (GUI) LabVIEW
launch CRASHES inside the container** — `crashpad_handler.exe` spawns ~2 s
after the LabVIEW process (verified by polling `Win32_Process`). This is why
every naive `vipm install` attempt hangs at `Installing 1 package...` until
the timeout: VIPM is waiting forever for a LabVIEW that crashed at startup.

LabVIEWCLI's LabVIEW launches survive because it passes `--headless
-labviewcli`.

**The fix that works:** before `vipm install`, launch an **idle**
`LabVIEW.exe --headless` yourself (it survives and, with the right
LabVIEW.ini, opens VI Server on TCP 3363). VIPM then talks to the live
instance and the install completes in **~80 seconds**.

Things that do NOT work (all tested — don't retry):
- Plain `Start-Process LabVIEW.exe` → instant crash (see above).
- Holding LabVIEW open with a **MassCompile** keep-alive → LabVIEW's UI
  thread is busy; VI Server never services VIPM; install times out.
- Letting VIPM "test"/launch the target itself → crash, timeout.
- `vipm install` of a dragon pinning LabVIEW 2023 → the image's
  "LabVIEW 2023/2024/2025" dirs are **stubs without LabVIEW.exe**; only
  **LabVIEW 2026** is a real dev system. Override with
  `--labview-version 2026 --labview-bitness 64`.

### Mandatory VIPM command order
```
vipm version          # warms up VIPM Desktop
vipm refresh          # populates the package catalog (Desktop + CLI + NIPM)
vipm --labview-version 2026 --labview-bitness 64 --timeout 1500 install --yes <file.dragon>
vipm --labview-version 2026 --labview-bitness 64 list --installed   # VERIFY each dep
```

### VIPM CLI gotchas (2026.x preview)
- `install <file>` **prompts `Continue? [y/N]`** and silently cancels in CI →
  always pass `--yes` (`-y`).
- Default operation timeout is ~180 s in CI → pass `--timeout 1500` (or env
  `VIPM_TIMEOUT`).
- vipm writes info lines (e.g. `Auto-detected LabVIEW ...`) to **stderr** →
  NEVER combine `2>&1` with `$ErrorActionPreference='Stop'` (PowerShell turns
  stderr lines into terminating NativeCommandError). Check `$LASTEXITCODE`.
- `vipm list` needs `--installed` (bare `list` errors).
- The dragon file is INI-like: `labview-version = 2023` under `[project]`,
  deps under `[vipm.dependencies]` as `name = "version"`. Parse it to know
  what to verify after install.

### VIPM installer (the .exe, not the CLI)
- NIPM first (VIPM's prerequisite):
  `https://download.ni.com/support/nipkg/products/ni-package-manager/installers/NIPackageManager25.8.0.exe`
  with `--passive --accept-eulas --prevent-reboot`.
  Exit codes **0, 3010, -125071** (reboot deferred) and **-125083**
  (sub-package custom action failed) all mean "effectively installed" —
  verify the target exe exists instead of trusting the code.
- VIPM preview:
  `https://packages.jki.net/vipm/preview/vipm-setup-latest-preview.exe`
  with **exactly** `/exenoui /qn`. Any other flag combo (`/log`, `/v"..."`,
  omitting `/exenoui`) makes the installer hang forever.
- CLI lands at `C:\Program Files\JKI\VI Package Manager\support\vipm.exe`
  (not on PATH).

### Settings.ini (without it, `vipm refresh` hangs forever)
Seed `C:\ProgramData\JKI\VIPM\Settings.ini` BEFORE first vipm use. Use
`Docs/Settings.ini` as the donor, with these transforms:
- `Mass Compile After Package Install?="TRUE"` → `"FALSE"` (mass compile
  blows the install timeout),
- `Connection Timeout="120"` → `"600"`,
- **rewrite the `[Targets]` section** to describe the LabVIEWs actually on
  the machine (name/version/path), all with `Ports` 3363 and `Tested="TRUE"`
  — so VIPM never tries to launch LabVIEW to "test" a target.
  `container-setup-vipm.ps1` does this generically by scanning
  `C:\Program Files\National Instruments\LabVIEW *\LabVIEW.exe`.

### LabVIEW.ini (VI Server) — required for VIPM and LabVIEWCLI
Tokens MUST sit under a `[LabVIEW]` section header (a fresh install has no
ini at all; tokens outside the section are ignored):
```ini
[LabVIEW]
server.tcp.enabled=True
server.tcp.port=3363
server.tcp.access="+*"
server.vi.access="+*"
server.app.propertiesEnabled=True
server.vi.propertiesEnabled=True
server.vi.callsEnabled=True
ShowWelcomeOnLaunch=False
```

### Building the spec
```powershell
LabVIEWCLI -LogToConsole TRUE -OperationName ExecuteBuildSpec `
  -ProjectPath C:\workspace\Source\Simple_Project.lvproj `
  -BuildSpecName test_build `
  -LabVIEWPath "C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe" `
  -Headless
```
- Pin with `-LabVIEWPath` (not `-LabVIEWVersion`).
- A LabVIEW **2023** project builds fine under **2026** (auto-upgrade on load).
- `Bld_localDestDir=../Build` in the .lvproj resolves relative to `Source/` →
  output lands at **repo-root `Build\Application.exe`**, not `Source\Build\`.
- Kill the keep-alive LabVIEW and delete `LVAutoSave*` dirs before building,
  or the build's LabVIEW may stall on an autorecover prompt.

### GitHub-runner Docker quirks
- `windows-latest` intermittently boots with the Docker daemon **down**
  (actions/runner-images#13729): `Start-Service docker` + wait loop.
- The NI image does **not fit on C:** — set docker `data-root` to `D:\docker`
  in `C:\ProgramData\docker\config\daemon.json` before pulling.
- Never pass multi-line `powershell -Command` through `docker run`/`exec` —
  `$`-variables get mangled and commands silently no-op (this produced false
  greens). Mount the repo and run scripts with `-File`.
- Job timeout ≥ 90 min (pull ~13 min; total ~25 min when healthy).

### Keep the job honest (false greens happened repeatedly)
- Propagate `$LASTEXITCODE` after EVERY native call; `throw` on non-zero.
- After the install: verify each dragon dependency appears in
  `vipm list --installed`.
- After the build: verify the EXE exists and is non-empty.
- `upload-artifact` with `if-no-files-found: error`.
- NEVER `exit 0` mid-script to clear a benign exit code on GitLab — GitLab
  concatenates all script lines into one .ps1 and `exit` skips the rest of
  the job (use `cmd /c "exit 0"` to reset `$LASTEXITCODE` instead).

---

## 2. Bare windows-latest runner (no Docker) — what is/isn't possible

Proven ✅: install NIPM → LabVIEW **2020 SP1 runtime** (VIPM's MSI
prerequisite; without it the VIPM installer exits **1603** with
`AI_MISSING_PREREQS`) via nipkg feeds
(`.../ni-l/ni-labview-2020-runtime-engine/20.1/released[-critical]`) → VIPM
`/exenoui /qn` → seed Settings.ini → `vipm version` → `vipm refresh`.
See `.github/workflows/labview-windows.yaml`.

NOT possible on a hosted runner: `vipm install <dragon>` and build-spec
compiles. They need a **licensed** LabVIEW dev system. LabVIEW 2023
(`ni-labview-2023-core-en` from feed `.../ni-l/ni-labview-2023/23.3/released`)
installs fine and `ni-labview-2023-deployable-license` exists, but LabVIEW
still parks on its activation window; auto-clicking "Begin 7-Day Trial"
(coordinate click) licenses it and VI Server opens — yet VIPM still failed to
complete installs there. Use the Docker pipeline or a licensed self-hosted
runner instead.

nipkg exit code **-125071** = "reboot needed", packages ARE installed —
treat as success (runner can't reboot).

---

## 3. Self-hosted runner with licensed LabVIEW (GitLab `.gitlab-ci.yml`)

Same VIPM stack as §2 (skip the LabVIEW-runtime feed if LabVIEW is present);
then the vipm version/refresh order, then
`vipm --labview-version <YYYY> --labview-bitness 64 install --yes <dragon>`
(the year must match an installed-and-VIPM-visible LabVIEW; refresh AFTER
LabVIEW is installed or VIPM reports `Available targets: <none>`), then
LabVIEWCLI. If installs hang at "Connecting to LabVIEW", apply the §1
findings (VI Server ini, target ports in Settings.ini, idle pre-launched
LabVIEW).

---

## 4. Known-good reference runs (in wheeller123/labview-cicd)

| Run | What it proves |
|---|---|
| 27313062576 | bare-runner VIPM stack first green |
| 27379079048 | container build green via .vip extraction (superseded) |
| 27425083219 | **first genuine `vipm install` green in container** |
| 27426398028 | final tidied template green on main |

## 5. Stress-test note
`vipm refresh` on a long-lived machine degraded to a permanent hang state
after ~40 consecutive successes (every failure = hang at "Refreshing VIPM
Desktop package list...", never an error exit). On persistent runners, wrap
refresh with a timeout + VIPM-Desktop-kill + retry. Script:
`stress-test-vipm-refresh.py`.
