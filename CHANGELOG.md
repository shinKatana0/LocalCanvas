# Changelog

Notable changes, in user terms. The app and the gateway are one product with two
halves: they share a minor version and a single `api_version`, and
`docs/versioning.md` says what that means for compatibility.

## v0.2.0 — the Windows tray launcher

Launcher **0.2.0** (new) · Gateway **0.1.1 → 0.1.2** · App **0.1.5** (unchanged) ·
`api_version` **1** (unchanged)

### `LocalCanvas.exe`

- **A one-click Windows launcher.** Download
  `LocalCanvas-0.2.0-windows-x64.zip`, extract it, double-click
  `LocalCanvas.exe`. It runs first-time setup for you in a PowerShell window
  it opens itself, then starts ComfyUI and the Gateway and settles into the
  system tray: a status icon, a menu (Restart Gateway, Sync workflows, Open
  status, Exit) and a status window with the pairing address, a QR code and
  the workflow count. Nothing new was added to the runtime to make this
  possible — the launcher only calls the same `start.ps1`, `stop.ps1`,
  `sync-workflows.ps1` and `status.ps1` the command line always has, through
  their `-Json` machine interface.
- **The command line is unaffected and unremoved.** Every script keeps
  working exactly as before; the launcher is a second front end for the same
  runtime, not a replacement for the first one. It is now the *Advanced*
  path.
- **One launcher per Windows session.** A second double-click brings the
  first one's status window forward instead of starting a second copy.
- **Ownership and shutdown are unchanged in substance.** Exit stops only what
  LocalCanvas started, through `stop.ps1`; an external or reused ComfyUI is
  left running. Signing out or shutting down Windows stops LocalCanvas the
  same way, automatically, with up to 45 seconds held for it. Under heavy
  load, a Gateway start still in progress when that budget ends is left
  running rather than interrupted, and is reported as such.
- **Unsigned.** This project holds no code-signing certificate, so
  `LocalCanvas.exe` is unsigned. On a PC with Smart App Control turned on,
  Windows blocks it outright, with no "Run anyway" — use the command-line
  path there, or a PC where it is off. This is a stated limitation, not a
  bug: see [README.md](README.md#known-limitations).

### Upgrading from v0.1.5

If a v0.1.5 gateway is still running when you start v0.2.0, it is refused —
not silently reused. `start.ps1` (and so the launcher) reports
`Port 7801 is already in use` and names the fix:
`pwsh .\scripts\stop.ps1 -Component Gateway`. Stop it once, then start again.

### Gateway 0.1.2

- `GET /api/v1/info` now reports an `instance_id` and `jobs.active`, so a
  caller can tell one gateway process from another that happens to answer on
  the same port, and can tell whether it is safe to restart without asking.
- The gateway process itself accepts `--instance-id` (`start.ps1` sets it on
  every launch, so a caller's readiness check can tell this instance's answer
  from any other one on the same port), and its `qr` command accepts `--png`
  to write the pairing QR as an image — both additive, and both what the
  launcher's own tray uses. `api_version` does not move: these are additions
  an older app survives without noticing.

## v0.1.5 — first public release

App **0.1.5** (build 6) · Gateway **0.1.1** · `api_version` **1** · tag `v0.1.5`

The first release. Everything below is new, because there was nothing before it.

### Using your own workflows from your phone

- **A workflow importer instead of hand-written YAML.** `scripts\sync-workflows.ps1`
  reads the ComfyUI workflow folder you name, converts files saved from ComfyUI's
  editor through your own running ComfyUI, and writes a definition for each
  workflow it can read with confidence. `-DryRun` reads everything and writes
  nothing. Your workflow files are only ever read.
- **A workflow it cannot read with confidence is held, not guessed** — reported
  with a sentence naming exactly what could not be decided, and never imported
  anyway.
- **A generated definition is yours to edit.** A later run keeps the name, the
  presentation, the translation setting and every label and help line you wrote,
  and regenerates only what came from the workflow.

### The Android app

- **Four ways to connect**: the remembered server, mDNS discovery, a QR code the
  PC prints in its own terminal, and typing the address. No hosted pairing
  service is involved in any of them.
- **Forms drawn from your workflow definitions**, with the few fields that matter
  in Main and the rest behind Advanced.
- **Pictures and clips as inputs**, with real byte-level upload progress. A HEIC
  or HEIF photo is converted to JPEG on the phone before it is uploaded, decided
  from the file's bytes rather than its name; every other file is uploaded
  untouched.
- **Results**: full-screen view, video playback, save to the gallery, Android's
  own share sheet, and Generate Again — which varies the seed and writes the new
  number into the field, or reuses it exactly with Freeze seed.
- **My defaults, drafts and saved setups**, three separate things: what you always
  want, what you were in the middle of, and combinations you chose to name.
- **A portable profile** — your settings and setups as one file you can move to
  another phone. Nothing about a server and nothing you generated is in it.
- **Optional prompt translation on the PC.** Write in Russian or Japanese and have
  the PC translate into the language your workflows expect. Quoted text is never
  translated, and your original words are always what the app shows and what
  Generate Again resubmits.
- **Reconnect and job recovery**, so a dropped Wi-Fi connection does not lose a
  generation that is already running. When the app cannot tell whether a job
  survived, it says so.

### Running it on the PC

- `scripts\setup.ps1` builds LocalCanvas's own `.venv/` on an interpreter it
  selects and prints. It never installs into ComfyUI's Python.
- `scripts\start.ps1` starts ComfyUI (only when you asked it to manage one),
  waits on a real readiness probe rather than a fixed sleep, starts the gateway
  and prints the endpoint and QR code.
- `scripts\stop.ps1` stops only what LocalCanvas itself started, and says so when
  it leaves a ComfyUI running.
- `scripts\status.ps1` and `scripts\doctor.ps1` are read-only: they start
  nothing, write no file and change nothing. The doctor's exit code agrees with
  its body, and a check it could not make is never reported as one that passed.
- `scripts\strict-lan.ps1` is an optional, reversible machine-level enforcement
  of LAN-only operation. Every subcommand has a `-Plan` form that changes
  nothing.

### For people who do not have ComfyUI yet

- `comfy\setup.ps1 -Profile Minimal` clones ComfyUI at a pinned revision (about
  7 MiB transferred, about 31 MiB on disk) and creates its workflows folder. It
  downloads no models and builds no Python environment, and it never touches a
  ComfyUI it did not install.
- `comfy\doctor.ps1` answers one question about any ComfyUI — will *this* one
  work with LocalCanvas — from real requests to it.

### Privacy

- No telemetry, no analytics, no crash reporting, no accounts, no cloud
  generation, no hosted QR service. `docs/privacy-security.md` states each claim
  and its evidence, including the two third-party Android components that ship
  with the app.

### Known limitations at v0.1

- The host side is Windows only, and needs PowerShell 7 or newer.
- There is no authentication: v0.1 is for a trusted home LAN. See
  [SECURITY.md](SECURITY.md).
- The Recommended and Video bootstrap profiles are experimental and not
  validated for this release.
- The Android project's Kotlin code has no automated tests of its own.
- Public CI runs the deterministic suites only; tests that need a real ComfyUI
  are opt-in and do not run there.
