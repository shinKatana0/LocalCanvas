# Changelog

Notable changes, in user terms. The app and the gateway are one product with two
halves: they share a minor version and a single `api_version`, and
`docs/versioning.md` says what that means for compatibility.

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
