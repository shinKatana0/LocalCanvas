# LocalCanvas user guide

**English** · [Русский](user-guide.ru.md) · [日本語](user-guide.ja.md)

Everything you need from an empty folder to a picture on your phone. Read
[README.md](../README.md) first if you have not: it says what LocalCanvas is and
what it deliberately is not.

`LocalCanvas.exe`, the Windows tray launcher, is the normal way to run
LocalCanvas from v0.2.0 on. Sections 1 – 6 follow that path. Everything it does
is a call of the same scripts the command line uses — nothing in this guide
that was true of the command-line path stopped being true, it is just no
longer the first thing you are shown. Section 14 is that command line, kept in
full for troubleshooting, unattended use, and the PCs where the launcher does
not run (see [Known limitations](#16-known-limitations)).

Every PowerShell line below is written as you would type it at the root of the
LocalCanvas folder.

---

## 1. Install

On the PC that will run the generation:

| You need | Why |
|---|---|
| **Windows 10 or 11** | The host side is Windows-only at v0.2. |
| **ComfyUI**, working, with a GPU | LocalCanvas runs *your* workflows; it does not replace ComfyUI. |
| **PowerShell 7 or newer** (`pwsh`) and **Python 3.10 – 3.13** | `LocalCanvas.exe` runs first-time setup itself, in a PowerShell window it opens on its own (section 2), and setup builds LocalCanvas's own `.venv/` from the Python it finds — you never open either tool yourself. Windows PowerShell 5.1 is not supported. `winget install --id Microsoft.PowerShell`, or <https://aka.ms/powershell>; Python from <https://www.python.org/downloads/>. |
| **Google Chrome or Microsoft Edge** | Only to convert workflows saved with ComfyUI's **Save**. Workflows exported with **Export (API)** need no browser. |
| An **Android phone** on the same Wi-Fi | The thing you will actually use. **Android 7.0 (API 24)** or newer — the minimum the release build declares. |
| **git** | Needed for the command-line path (section 14): it runs from a `git clone` of this repository, not from the downloaded zip. The zip install — `LocalCanvas.exe` and its tray — needs no git at all. |
| **Flutter** and the **Android SDK** | Only for building the Android app yourself (section 5). |

On a machine with several Pythons installed, you do not have to pick one:
setup selects an interpreter inside the supported range, and prints which one
it chose and what version it got.

**What has been tested.** Public CI (GitHub Actions, `windows-latest`, no real
ComfyUI) runs the gateway's tests on Python 3.10 and 3.13, `flutter analyze` and
`flutter test` for the app, the PowerShell script tests, and the launcher's own
.NET tests, on every push to `main` and every pull request. By hand, the
maintainer has tested pairing and generation on one foldable phone over Wi-Fi
against a real ComfyUI; nothing automated covers that path. Uploading a
picture or clip has not yet been confirmed working from a phone. Prompt
translation, discovery (mDNS) reaching a phone, and the doctor's elevated
firewall check have only been exercised against fakes. Of the ComfyUI
bootstrap profiles, only Minimal is validated (below). The tray launcher has
not been exercised on a PC with Smart App Control turned off — the maintainer's
own PC has it on — so the EXE path itself is unverified end to end; the
command-line path (section 14) is what the maintainer actually runs.

### Download and extract

From this repository's **Releases** page: `LocalCanvas-0.2.0-windows-x64.zip`.
Extract it anywhere on the PC — the folder you extract it to is where
LocalCanvas lives from then on; nothing else on the machine is touched. Inside
is one `LocalCanvas` folder holding `LocalCanvas.exe` beside `scripts\`,
`config\` and everything else it needs. `LocalCanvas.exe` has to stay in that
folder: moved out on its own, it refuses to run — a dialog titled
**"LocalCanvas.exe must stay in the LocalCanvas folder."** names the
`scripts\start.ps1` it looked for beside itself and could not find.

The zip is self-contained: `LocalCanvas.exe` needs no .NET installed on the
machine that runs it. PowerShell 7 and Python (above) are still needed —
LocalCanvas builds its own environment from them the first time it runs
(section 2).

### Getting ComfyUI

**You already have one — this is the normal case.** Nothing to do. LocalCanvas
never writes into a ComfyUI it did not install, never adds a package to its
Python, and never edits its configuration. The only coupling between the two
is HTTP.

**You do not have one — the optional bootstrap.**

```powershell
pwsh .\comfy\setup.ps1 -Profile Minimal -DryRun
pwsh .\comfy\setup.ps1 -Profile Minimal
```

(Run from a PowerShell 7 window, from a `git clone` of this repository —
section 14. There is no tray equivalent: getting ComfyUI this way is
command-line only, on both install paths.) The dry run prints every
action it would take and writes nothing at all — not one directory. The real
run clones ComfyUI at a pinned revision (about 7 MiB transferred, about 31 MiB
on disk) and creates its `user/default/workflows` folder. Run it twice and the
second run says everything is already complete and changes nothing.

**Where it installs.** With no `-ComfyRoot`, the root is
`%LOCALAPPDATA%\LocalCanvas\comfyui` — on a typical machine
`C:\Users\<you>\AppData\Local\LocalCanvas\comfyui`. Inside it:

| What | Where |
|---|---|
| The ComfyUI checkout — this is the ComfyUI that section 2 asks you for | `<root>\ComfyUI` |
| Your workflow folder, which section 2 finds by itself | `<root>\ComfyUI\user\default\workflows` |
| The record of what was installed | `<root>\localcanvas-bootstrap.json` |

Pass `-ComfyRoot "D:\somewhere"` to put it elsewhere. You do not have to retype
any of it: setup offers this location as the answer to *where is your
ComfyUI* (section 2), so you press Enter. The dry run prints the paths in full
if you want to read them first — the `Root:` line at the top, then one
`[PLAN]` line per action, and a closing block that repeats **the ComfyUI
checkout and the install record**; the workflow folder appears in the plan
above, not in that block.

The `user/default/workflows` folder exists from the moment the bootstrap
finishes, so the importer (section 6) has something to read even before you
have saved a workflow.

**What it does not do, stated plainly:** it downloads no models and builds no
Python environment. Before that ComfyUI will start you still have to install a
supported Python yourself, install ComfyUI's own `requirements.txt` (several
gigabytes, and choosing the CUDA build that matches your GPU is your decision),
obtain the models your workflows need, and start ComfyUI.

Only the **Minimal** profile is supported at v0.2. The manifest format also
describes Recommended and Video profiles; they are experimental, they have not
been validated for this release, and LocalCanvas ships no models under any of
them.

To ask whether a ComfyUI — yours or a bootstrapped one — will work with
LocalCanvas:

```powershell
pwsh .\comfy\doctor.ps1
```

It is read-only and every answer comes from a real request to the running
ComfyUI. It exits **0** (COMPATIBLE), **2** (UNKNOWN — nothing failed, but at
least one check could not be made) or **3** (NOT COMPATIBLE). A check that could
not be made is never reported as a check that passed, so a ComfyUI that is not
running gives UNKNOWN rather than a clean bill of health.

## 2. First run

**Have ComfyUI running first**, unless you are about to tell setup to let
LocalCanvas start it for you (question 1, below) — external mode never
starts it, so first run needs it already up, and fails if it is not (see
"When setup finishes"). Then double-click `LocalCanvas.exe`, inside the
extracted `LocalCanvas` folder.

**If setup has not run yet** — no `.venv\Scripts\python.exe`, or no
`config\local\runtime.yaml` — a dialog appears:

> **LocalCanvas setup is required before first use.**
>
> Setup runs scripts\setup.ps1 in a PowerShell window. LocalCanvas continues
> when it has finished.
>
> **[Run setup]** [Cancel]

Choose **Run setup**. It opens a visible PowerShell window running
`scripts\setup.ps1` — the same script the command-line path runs (section 14),
so what it asks is exactly the same whether you started it from the tray or
typed it yourself.

(Every custom button in these dialogs — **Run setup**, **Sync now**, **Later**,
**Restart**, **Exit**, and headings and body text generally — is always
English, whatever your Windows language. **Cancel** and **Close** are the two
exceptions: they are Windows' own stock buttons, and follow Windows' own
display language.)

### The two questions

1. **"Do you start ComfyUI yourself, or should LocalCanvas start it for you?"**
   Asked first, because the answer decides what else is needed. It is offered
   as `1  I start ComfyUI myself` and `2  LocalCanvas starts ComfyUI for me`,
   and **1** is what Enter gives you.
   * **1 — external mode.** LocalCanvas never launches ComfyUI and never
     stops it; it verifies the address answers before it starts the gateway,
     and that is all. No launcher has to be worked out at all, which is why
     this mode needs the least from you.
   * **2 — managed mode.** LocalCanvas may start ComfyUI for you, reuses one
     that is already running rather than starting a second, and only ever
     stops one it started itself. It starts it with the Python that is
     already beside your ComfyUI — `python_embeded\python.exe` for a portable
     build, `venv\Scripts\python.exe` or `.venv\Scripts\python.exe` for a
     clone — which setup reads off the installation and writes into
     `comfy.launcher`. It installs nothing into that interpreter. If there is
     none, setup **refuses** rather than guessing, and names external mode as
     the way on.
2. **"Where is your ComfyUI?"** The folder holding `main.py`, or the folder
   holding *that* folder for a portable build. Both layouts are recognised and
   whatever you type is validated. This one cannot be inferred: LocalCanvas
   scans no drive, walks no directory tree and reads no registry. If you
   installed ComfyUI with the bootstrap in section 1, its location is offered
   as the default and you press Enter.

A **third** question is asked only when `user\default\workflows` — ComfyUI's
own place for workflows — is not inside the folder you named. When it is
there, it is found and nothing is asked.

Nothing else is asked, because nothing else has to be — the display name comes
from the computer's name, ComfyUI's address from its own default
`127.0.0.1:8188`, the gateway's from `0.0.0.0:7801`.

Two configuration files are written, both in the gitignored `config\local\`,
so your paths never enter a commit: `config\local\runtime.yaml` (mode, your
ComfyUI, the addresses, this PC's display name) and
`config\local\workflow-sources.yaml` (the one folder LocalCanvas reads your
workflows from).
[`config/examples/runtime.example.yaml`](../config/examples/runtime.example.yaml)
is the reference for everything `runtime.yaml` can hold.

### When setup finishes

Before the window closes it prints what it would tell a command-line user to
type next — **"Next, start LocalCanvas:"** followed by
`pwsh .\scripts\start.ps1`, and, if your workflows are already configured,
**"To bring your ComfyUI workflows in:"** followed by
`pwsh .\scripts\sync-workflows.ps1`. **None of that is for you: just press
Enter.** Those two lines are for the command-line path (section 14); from the
tray, LocalCanvas starts itself for you the moment the window closes, and
offers the workflow sync if there is one to offer (below), rather than
running either for you unasked.

The window then prints a blank line and **"Press Enter to close this
window"**. Read it, press Enter, and the window closes. LocalCanvas then
continues on its own:

- **Setup succeeded, and ComfyUI answers** — it goes straight on to verify
  ComfyUI (or start it, in managed mode), check your workflow folder, and
  start the Gateway.
- **Setup succeeded, but ComfyUI does not answer** (external mode only —
  LocalCanvas never starts ComfyUI for you in that mode) — the tray shows
  **Could not start**, a dialog titled **"LocalCanvas could not start."**
  says **"ComfyUI is not reachable."**, and LocalCanvas closes. Start
  ComfyUI and double-click `LocalCanvas.exe` again (section 13).
- **Setup did not succeed** — the tray shows **Could not start**, and a dialog
  titled **"Setup did not finish."** names why (it could not be opened, it
  ended with an exit code, or it finished but LocalCanvas is still not set
  up) and suggests starting LocalCanvas again to retry, or running
  `scripts\setup.ps1` yourself in PowerShell 7 to see what it needs. Retrying
  is the safe next step for a zip install; running the script by hand is the
  command-line path (section 14), which is meant to be used from a
  `git clone` — Windows can refuse a script run by hand from inside the
  extracted zip folder. Nothing was started.

Choosing **Cancel** on the first dialog instead starts nothing and LocalCanvas
exits.

**Once setup exists, this dialog never appears again.** A later double-click
goes straight to daily use (section 3).

### Workflows on first start

If your workflow folder has anything new for LocalCanvas to see, it asks:

> **N workflow changes detected.**
>
> Sync now imports them before the Gateway starts. Later starts LocalCanvas on
> the workflows it already has; nothing is changed.
>
> **[Sync now]** [Later]

Section 6 covers what "sync" means and what happens to a workflow LocalCanvas
cannot read with confidence. Once the Gateway is up, the tray icon turns to a
green check: LocalCanvas is Ready. Install the app on your phone (section 5)
and use **Open status** in the tray (section 4) for the address and a pairing
QR code.

## 3. Daily start

Double-click `LocalCanvas.exe` again — that is the whole of it. There is at
most one LocalCanvas per Windows sign-in session: double-clicking again while
the first one is still running never starts a second copy. It asks the first
one to bring its **Open status** window to the front, and ends without running
a single script.

The tray icon walks through the same states every start:

| Icon | State | Tooltip says |
|---|---|---|
| Amber disc, open spinner arc | Starting | `LocalCanvas — Starting…` |
| Green disc, check | Ready | `LocalCanvas — Ready` |
| Amber/yellow triangle, "!" | Ready, but a workflow needs a look | `LocalCanvas — Ready (N workflows need a look)` |
| Red disc, "x" | Gateway down, or startup failed | `LocalCanvas — Gateway down` / `LocalCanvas — Could not start` |
| Amber disc, two circular arrows | Syncing (section 6) | `LocalCanvas — Syncing workflows…` |
| Amber disc, open spinner arc (same as Starting) | Restarting the Gateway (section 4) | `LocalCanvas — Restarting the Gateway…` |
| Plain grey disc | Stopping (Exit under way) | `LocalCanvas — Exiting…` |

If the Gateway you already had running still answers correctly, it is reused
rather than started again — the same is true of ComfyUI in managed mode, or of
one you are already running yourself in external mode. LocalCanvas never
starts a second copy of either.

Once Ready, the Gateway and ComfyUI are checked every 5 seconds (a 2-second
timeout, no proxy). Two failed Gateway checks in a row — so within about 14
seconds of it actually going away — turn the icon red and put LocalCanvas into
the *Gateway down* state; there is no automatic restart. The first time that
happens you get one notification:

> **Gateway down**
>
> The LocalCanvas Gateway stopped. Right-click the tray icon and choose
> Restart Gateway.

— once per time it goes down, not on every failed check after it. Section 4
has the tray menu in full, including **Restart Gateway**.

## 4. The tray

**Finding the icon.** On Windows 11, a new tray icon is commonly hidden
under the small **^** arrow ("Show hidden icons") next to the clock the
first time it appears — click that arrow if you do not see LocalCanvas. Or
skip hunting for it: double-clicking `LocalCanvas.exe` again opens **Open
status** just the same (section 3).

Right-click the icon for the menu, always in this order:

    LocalCanvas                       (bold, not clickable)
    Gateway: <status>
    ComfyUI: <status>
    Workflows: <status>
    ───────────────────────
    Restart Gateway
    Sync workflows
    Open status
    ───────────────────────
    Exit

Double-clicking the icon opens **Open status** directly.

**The three status lines**, read straight off the running LocalCanvas:

- **Gateway:** `Starting…`, `Ready`, `Restarting…`, `DOWN`, `Stopping…` or
  `Not running`.
- **ComfyUI:** `Ready`, `Down`, `Starting…` or `Unknown`, with `(external)`
  appended whenever LocalCanvas did not start it itself — reused or truly
  external, either way it will not be stopped for you (section 15).
- **Workflows:** a count, with `(N need a look)` appended when something needs
  attention, `(check did not complete)` if the check itself failed, or
  `(no folder configured)` if none is set up yet.

**Restart Gateway** and **Sync workflows** are only enabled while LocalCanvas
is Ready or showing that a workflow needs a look, or while the Gateway is
down — never mid-start, mid-restart, mid-sync or mid-exit. While the Gateway
is down, **Restart Gateway** is shown in **bold**: it is the thing to try
first.

**The icon's shape**, not only its colour, says which state you are in: a
**green disc with a check** (Ready); an **amber disc with an open spinner
arc** (Starting, Restarting); an **amber disc with two circular arrows**
(Syncing); an **amber/yellow triangle with "!"** (a workflow needs a look —
the Gateway itself is fine); a **red disc with "x"** (Gateway down, or the
startup itself failed — either way the phone cannot use LocalCanvas right
now); a **plain grey disc** (Stopping).

### Open status

A small window with more room than the menu gives:

- **Gateway** status, with a **Restart Gateway** button right beside it while
  it is down (hidden the rest of the time).
- **Endpoint**, a **Copy address** button, and a pairing **QR code** — the
  same address the phone connects to (section 5). The QR is generated on
  request; if it could not be produced, the address is shown on its own.
- **ComfyUI** status.
- **Workflows**: how many are ready, and how many need a look.
- A **problem** line, shown only when there is one.
- **Log**, naming `.runtime\launcher.log`.
- At the bottom, side by side: **Open logs folder** and **Close**. Close
  dismisses the window; LocalCanvas keeps running, and the next
  **Open status** (or double-click) reopens the same window rather than
  building a new one.

### Exit, and the confirmations

**Exit** stops what LocalCanvas started — through the same `stop.ps1` the
command-line path uses (section 15) — then closes the tray. An external
ComfyUI, or one LocalCanvas only reused, is never stopped for you.

If the Gateway reports a generation still running, both **Restart Gateway**
and **Exit** ask first, rather than interrupting it silently:

> **A generation may still be running. Restart the Gateway anyway?**
>
> **[Restart]** [Cancel]

(for Exit: **"A generation may still be running. Exit LocalCanvas anyway?"**,
with **[Exit]** and **[Cancel]** — Cancel is the default either way). Choosing
Cancel leaves everything running and untouched. From the moment Exit is under
way — even while a command it
asked for earlier is still finishing — the tray tooltip already says
`LocalCanvas — Exiting…`.

If LocalCanvas could not confirm that everything it started actually stopped,
a dialog titled **"LocalCanvas could not stop everything it started."** names
what is, or may still be, running, and points at `status.ps1` and `stop.ps1`
(section 15) to check and finish the job by hand.

## 5. Connecting your phone

### Installing the app

There is no APK in the repository itself. Where the repository publishes a
release, its **Releases** page is the simplest place to get one: download
`LocalCanvas-0.1.5-arm64-v8a.apk` and install it as below — the app is
unchanged in this release, so its own version stays 0.1.5 even though the
Windows side moved to 0.2.0. Otherwise, build it yourself.

**Build it yourself**, from `app/`:

```powershell
flutter pub get
flutter build apk --release --split-per-abi
```

If Flutter is not on the machine yet, **start from Flutter's own Windows
guide** — <https://docs.flutter.dev/get-started/install> — which installs the
SDK and walks you through the Android side (Android Studio brings the Android
SDK with it). It is the longest step in this guide, and the only one that
installs a whole toolchain rather than one program.

Afterwards `flutter doctor` lists whatever is still missing, and
`flutter doctor --android-licenses` is the one-off step that accepts the Android
SDK licences — an agreement between you and Google, which is why no script here
does it for you. When `flutter doctor` is happy about the Android toolchain, the
two commands above will work.

The APKs land in `app/build/app/outputs/flutter-apk/`, one per ABI, each named
`LocalCanvas-<version>-<abi>.apk`; most phones want `arm64-v8a`. Install one
with `flutter install`, `adb install`, or by copying the file to the phone —
where Android will ask you to allow installs from whatever app you copied it
with, because this is a sideload and not a store install.

**Builds from CI.** The repository's **APK** workflow
(`.github/workflows/apk.yml`) runs the same build on every push to `main` and
on demand. Where you can see a run of it, the artefact
**`LocalCanvas-apk-debug-signed`** at the bottom of the run page is a zip
holding the three APKs. Artefacts are kept **14 days**, so do not bookmark one.

**Every APK here is debug-signed.** The project configures no release signing,
so the release build type carries the debug signing configuration, and every
build — yours or CI's — is signed with an Android debug key. It is a build to
sideload: not a verified or distributable release artefact, not signed by the
project, and no more trustworthy than one you build yourself. The debug key is
generated per machine and a later run does not reproduce it, so installing a
newer APK over an older one built elsewhere can fail with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` — uninstall LocalCanvas first, which takes
its stored settings with it: export your profile beforehand (section 11) if
you care about them.

### Connecting

Open the app with the PC running. There are four ways in, none privileged, and
all of them end in the same handshake before an endpoint is accepted:

1. **The remembered server** — the last endpoint that worked is tried on launch.
2. **On this network** — the gateway advertises itself over mDNS and the app
   lists what it finds. Some routers and VPNs suppress multicast; that is a
   normal outcome and the app simply offers the other three.
3. **Scan pairing code** — the QR from **Open status** in the tray (section 4),
   or from `start.ps1`'s own window on the command-line path (section 14).
   LocalCanvas's own side of this is local: no QR service, no shortener, no
   secret in the payload. Reading the code with the camera is Google ML Kit,
   which has its own network and data behaviour
   ([`privacy-security.md`](privacy-security.md)).
4. **Enter address** — always offered. `192.0.2.42`, `192.0.2.42:7801`
   and `http://192.0.2.42:7801` all work (with your PC's own address); the
   default port is 7801.

If something answers but is not LocalCanvas, or speaks a different API version,
the app says which and what to do about it.

**Windows Firewall, which is the likeliest thing in the way.** The gateway is a
new program listening on a port, and Windows blocks that from the network until
somebody allows it. The first time LocalCanvas starts the Gateway you should
get the *Windows Defender Firewall* dialog: tick **Private networks**, and not
Public — the gateway has no authentication and belongs on your own LAN only.
If no dialog appeared, or it was dismissed, everything on the PC still looks
correct and the phone still cannot reach it: the QR code scans, the address is
right, and the connection times out.

`pwsh .\scripts\doctor.ps1` (section 14) reports the gateway's port and
whether anything is listening on it — but it diagnoses the checkout it runs
from, so this is only useful on the command-line install, run from the same
`git clone` LocalCanvas is running from, never a fresh one. For a zip
install, check the tray's status lines or **Open status** (section 4)
instead. It reports the firewall rules themselves
only from an elevated prompt — run unelevated, which is the documented way, it
says *not measured, needs Administrator* rather than guessing. Windows' own
**Windows Defender Firewall with Advanced Security** is where an existing rule
can be checked or corrected by hand, and
[`privacy-security.md`](privacy-security.md) describes the optional
`scripts\strict-lan.ps1`, which goes further and is reversible.

## 6. Adding or updating workflows

Setup already wrote `config/local/workflow-sources.yaml` and named your ComfyUI
workflow folder in it — in a default install, `user/default/workflows` inside
the ComfyUI folder. Two promises that file is the whole of: **the folders you
list are the only folders LocalCanvas ever reads**, and **your workflow files
are only ever read** — nothing renames, moves, deletes or rewrites one.

### Save or Export (API) — both work

ComfyUI writes a workflow in one of two shapes, and LocalCanvas takes both:

| In ComfyUI you used | What LocalCanvas does with it |
|---|---|
| **Save** (the usual way) | Converts it through your own running ComfyUI, in a Chrome or Edge already on the PC, when it imports it. |
| **Workflow → Export (API)** (older ComfyUI: *Save (API Format)*) | Imports it as it is. No browser needed. |

So the only thing a workflow saved with **Save** asks of you is that **ComfyUI
is running, and Chrome or Edge is installed, when the import runs.** The
browser is headless, with a throwaway profile of its own, so nothing appears on
your screen.

### The everyday flow, from the tray

1. Create or edit the workflow in ComfyUI, and save it into your workflow
   folder.
2. With ComfyUI running (unless you chose to let LocalCanvas start it), start
   LocalCanvas or leave it running — either way it looks at your folder before
   it starts, or you ask it to look with **Sync workflows** while it already
   is.
3. A change found while LocalCanvas is starting is offered as the **"N
   workflow changes detected."** dialog (section 2) — accepting it imports
   before the Gateway itself starts, so there is nothing to restart and no
   summary dialog; the Gateway simply starts on the catalogue that import
   just wrote.
4. At any other time — LocalCanvas already running — right-click the tray
   icon and choose **Sync workflows** yourself. This path shows a summary
   when it is done — **"Workflow sync completed."** /
   `Updated: N · Needs review: N` — and, if any definition was actually
   written, restarts the Gateway on its own afterwards so the phone sees the
   new workflow: the Gateway reads the catalogue once, when it starts, and
   this is the one moment after startup that matters.
5. If the app was already open and the workflow is not listed, tap
   **Refresh the list** (↻) at the top of **Choose a workflow**.

Nothing watches your folder in the background. A change is picked up on the
next start, on **Sync workflows**, or by running the importer yourself from
the command line (section 14) — never on its own.

### When a workflow could not be imported

A workflow saved with **Save** that could not be converted is handled by *why*:

- **Offered again next time.** When the conversion could not even be
  attempted — no Chrome or Edge, or ComfyUI not ready — the next check offers
  it again as part of the change count. Fix the reason (start ComfyUI, install
  a browser) and sync again.
- **Needs a look.** When ComfyUI refused that graph, or LocalCanvas could not
  read the converted graph with confidence, the Workflows line in the tray
  says `(N need a look)` until the file changes. The command-line dry run
  (section 14) names each one and the reason; fix it in ComfyUI and save it
  again — a changed file is offered again like any other.

A workflow LocalCanvas has imported is not reported again while it stays the
same. **A workflow you deleted from your ComfyUI folder** is reported as no
longer there on every check. **Nothing is ever deleted from the catalogue
automatically** — `detect_removed: false` in
`config/local/workflow-sources.yaml` turns that report off, for a folder that
lives on a drive you do not always have plugged in.

### Writing a definition yourself

**A workflow it cannot read with confidence is held, not guessed.** It is
reported as `NEEDS_REVIEW` with a sentence naming exactly what could not be
decided — for a graph, the node and the input — and no definition is written
for it. Every other workflow imports regardless, and there is no switch to
import it anyway. Two ways out, and which is better depends on that sentence:

1. **Change the workflow so the question goes away.** Often it is a node used
   in a way the importer cannot read as an input — rewire or replace it in
   ComfyUI, save, and sync again.
2. **Write that one definition yourself.** A definition is a small YAML file
   in `config/local/workflows` next to the generated ones: the format is
   [`workflow-schema.md`](workflow-schema.md), and
   [`../workflows/examples/`](../workflows/examples/) holds three complete
   worked ones — prompt-only, image-input and video-input — to copy from. The
   importer leaves a definition you wrote alone.

**A generated definition is yours to edit too.** A later sync rewrites it only
when the workflow behind it changed, and keeps the name, presentation,
translation setting and every label and help line you wrote. To get the
generated ones back, `sync-workflows.ps1 -RegenerateLabels` (section 14).

Check the folder before you restart the Gateway — without ComfyUI, a GPU or a
network:

```powershell
.\.venv\Scripts\python.exe -m localcanvas_gateway.workflows config\local\workflows
```

    [ OK ] my-portrait (11 fields) - config\local\workflows\my-portrait.yaml
    2 workflows loaded, 0 rejected, from config\local\workflows

A definition it rejects is named with the file, the workflow and the problem;
the rest still load.

## 7. Generating

Pick a workflow, and the app draws the form that workflow declares. Type your
prompt, fill anything else it asks for, press **Generate**.

While it runs you see honest states — uploading, queued, generating — with real
progress where the backend reports it and an indeterminate indicator where it
does not. Never an invented percentage. **Cancel** is there where the workflow
supports it.

The result opens large. You can view it almost full screen, **Save** it to your
gallery, **Share** it through Android's own share sheet, and press **Generate
Again**.

**Generate Again and the seed.** It varies the seed of every field whose role is
a seed and writes the new number into the field, so the seed on screen is always
the seed that was sent. Nothing else in the form changes. Advanced carries a
**Freeze seed** switch, off by default, which makes Generate Again reuse the
seed exactly.

Stepping back through this session's results is small in-memory state: a bounded
list, no bytes kept, nothing written down, and nothing left after the app
closes. There is no gallery and no database-backed history — by decision.

### Working from a picture or a clip

A workflow whose definition exposes an image or a video input shows a picker.
Choose a photo or a clip, see it previewed, replace it or remove it, and watch
real byte progress while it uploads.

**HEIC photos are handled for you.** Modern Samsung and iPhone cameras save HEIC
by default. LocalCanvas looks at the file's *bytes*, not its name, and converts a
HEIC or HEIF photo to JPEG **on the phone** before uploading. Every other file
passes through byte for byte — a PNG keeps its transparency, a JPEG is not
re-encoded. If the phone has no HEIF decoder or the decode fails, the original is
uploaded and the gateway refuses it with a message naming the format (section
13).

**Video results** get a local preview and playback, plus Save and Share. Large
clips take longer to upload; `media.max_video_megabytes` in
`config/local/runtime.yaml` is the limit the gateway enforces, and the refusal
message names it.

Uploaded files live in a temporary store on the PC with a lifetime of their own
(`media.ttl_seconds`, an hour by default). A generation that refers to a file
which has already expired says so and asks for it again rather than failing
mysteriously.

## 8. Main and Advanced

Each workflow shows the few fields that matter first and keeps the rest behind
**Advanced**. Which is which comes from the workflow's definition, not from the
app guessing: the app understands field *types* and *presentation* and knows
nothing about models, checkpoints or node graphs. Grouping is configuration too —
the section names come from your definitions, and an unknown group renders as its
own section. A filter above the workflow cards narrows the list to one group, or
back to **All**.

## 9. Drafts, My defaults and Saved setups

Three different things, on purpose:

- **My defaults** — *what do I always want?* **Save settings as my defaults**
  records the current values for that workflow; **Reset settings to my defaults**
  brings them back, and **Reset settings to workflow defaults** goes back to what
  the curator declared.
- **Drafts** — *what was I in the middle of?* One per workflow, kept
  automatically and overwritten. It brings your prose and settings back; a media
  field comes back empty on purpose, because an uploaded file's id has usually
  expired by the time a draft is read again, and the form asks for the picture
  again.
- **Setups** — named combinations you chose to keep. Save the settings alone, or
  the prompt and the settings together, then name, rename or forget them.

## 10. Writing your prompt in your own language

Optional, off by default, and it runs on your PC. With `prompt_translation`
switched on in `config/local/runtime.yaml`, a prompt written in a language you
listed under `sources` is translated into `target` before the generation is
built. Recognition is by script: a prompt with no Cyrillic and no kana is left
exactly as you typed it. Anything inside `"double quotes"` is never given to the
translator, so a sign or a name stays as written.

It needs an install of its own, roughly a gigabyte, into LocalCanvas's own
`.venv/` and nowhere near ComfyUI — plus one language pair per language you
write in. `--editable` matters: it keeps the gateway installed from this
checkout, the way setup installed it.

```powershell
.\.venv\Scripts\python.exe -m pip install --editable ".\gateway[translation]"
.\.venv\Scripts\argospm.exe update
.\.venv\Scripts\argospm.exe install translate-ru_en
```

Nothing is downloaded while you generate; that install is the only download, and
it happens because you asked for it. The same commands are in the comments
beside the `prompt_translation` block in `config/examples/runtime.example.yaml`,
where the rest of the settings are explained. Switching it on without installing
them does not fail quietly: the app says what is missing before you press
Generate, and a prompt that needs translating reports exactly which install is
absent. Which pairs you have is read when the gateway starts and printed in its
startup output (`Translation: ru->en`), so a pair installed while it is running
is picked up the next time the Gateway restarts — from the tray's **Restart
Gateway**, or the next `start.ps1`.

Your original text is always what the app shows, what a draft stores and what
Generate Again resubmits. The translation never replaces your words.

## 11. Moving to another phone

**Your profile** is your saved settings and setups as one file. Export it, move
the file however you like, and import it on the other phone. Nothing about a
server and nothing you have generated is in it, and an import removes nothing
that is already there — use **Reset settings to my defaults** to apply what you
imported. Appearance and app language belong to the device and are deliberately
not in the profile. A profile written by a newer LocalCanvas is refused by name
rather than half-read.

## 12. Status and recovery

**On the PC.** The tray's three status lines and **Open status** (section 4)
are the everyday way to see what LocalCanvas thinks is running. Once
LocalCanvas is Ready, the Gateway and ComfyUI are each probed every 5 seconds
(2-second timeout); two failed Gateway probes in a row — about 14 seconds —
are what turns the icon red. Nothing is restarted automatically; **Restart
Gateway** is a deliberate action, always yours to take. On the command-line
install, `pwsh .\scripts\status.ps1` gives the same read-only information
without a tray to open — what is up, what LocalCanvas owns, and the endpoint
— for the `git clone` it runs from; `pwsh .\scripts\doctor.ps1` diagnoses
that same checkout at once (section 13). Both read the checkout they run
from, so neither tells you anything about a zip install — for that, the
tray's status lines and **Open status**, above, are the diagnostic.

**On the phone.** If Wi-Fi drops mid-generation, the app reconnects
automatically — 1 to 10 attempts, 3 by default, settable per device — and then
asks the gateway whether the job survived. If it cannot tell, it says so
rather than guessing, because a job that finished while you were disconnected
is not the same as one that never ran.

## 13. When something is wrong

**The setup-required dialog's `[Cancel]`, or a setup that did not finish.**
Nothing was started either way. Cancel leaves LocalCanvas exited; a setup that
did not finish shows **"Setup did not finish."** naming why, and suggests
starting LocalCanvas again to retry, or running `pwsh .\scripts\setup.ps1`
from a PowerShell 7 window to see what it needs directly (section 2).
LocalCanvas has already exited by this point, so starting `LocalCanvas.exe`
again is the safe first move for a zip install; running the script by hand
is the command-line path (section 14), meant to be used from a `git clone`
— Windows can refuse a script run by hand from inside the extracted zip
folder.

**A gateway left over from before v0.2.0 is still running.** Upgrading while
an older LocalCanvas gateway is running is refused, not silently reused:
`start.ps1` (and so the tray) reports `Port 7801 is already in use` and names
the fix — `pwsh .\scripts\stop.ps1 -Component Gateway` — then stop it once and
start again.

**Some Windows security configurations may warn about or block unsigned
executables, and Smart App Control may block `LocalCanvas.exe`.** On a
PC with Smart App Control on, Windows may refuse to run an unsigned executable —
when it does, there is no "Run anyway" dialog to click through. `LocalCanvas.exe` is
unsigned. Use the command-line path instead (section 14): it runs through
`pwsh`, which is Microsoft-signed and unaffected. LocalCanvas does not ask you
to weaken Windows security to run it. Turning Smart App Control off is a
Windows Security setting on that PC, not something LocalCanvas can do for
you, and this guide gives no advice either way about doing so.

**Windows blocked a script downloaded as part of the zip ("cannot be loaded",
or a security warning naming the internet zone).** Files extracted from a zip
downloaded from the internet carry a Mark of the Web. `LocalCanvas.exe` needs
nothing done about it: every script it runs, it runs with
`-ExecutionPolicy Bypass`, which is unaffected by the mark. A script you run
yourself, directly from PowerShell, is not — for running scripts by hand, use
a `git clone` of the repository instead (section 14): files from a clone
carry no Mark of the Web.

**A script refuses to start: "cannot be run because it contained a `#requires`
statement".** You are running it in Windows PowerShell 5.1, which LocalCanvas
does not support — every script here needs PowerShell 7 or newer, and
`LocalCanvas.exe` itself looks only for `pwsh.exe`, never for
`powershell.exe`. If it cannot find PowerShell 7 at all, it says so before
anything is started: **"PowerShell 7 is required. Install PowerShell 7 and
start LocalCanvas again."**, with `winget install --id Microsoft.PowerShell
--source winget` as the fix. If you are instead running a script by hand and
see the `#requires` refusal, that message comes from Windows itself, so it
appears in your system's language, it is wrapped to your window width (the
version numbers in it may be split across two lines), and it calls the
requirement "Windows PowerShell 7.0" — no such product exists. What you need
is PowerShell 7, whose command is `pwsh`. To see which one you are in:

```powershell
$PSVersionTable.PSVersion
```

One more thing, if you call these scripts from a script of your own: the
refusal is an error and not an exit code, so test `$?` rather than
`$LASTEXITCODE`.

**Run the doctor first.** This is the command-line install's own tool
(section 14): it diagnoses the `git clone` it runs from, so run it from the
same clone, not a fresh one. For a zip install, the tray's status lines,
**Open status** and **Open logs folder** (section 4) are the diagnostic
instead.

```powershell
pwsh .\scripts\doctor.ps1
```

It starts nothing, writes no file and changes nothing. Its exit code:

| Exit | Meaning |
|---|---|
| **0** | Every check it could make came back clean. |
| **2** | Nothing failed, but at least one check could not be made or came back as a warning worth acting on. A missing or unreadable configuration is also a 2. |
| **3** | Something failed. |

On a complete run the closing summary accounts for every check and the exit code
is the one that summary was drawn from. **Two failures end the run early and
print no summary at all**: no `.venv/` yet, and a configuration that could not be
loaded. Each prints its own `[FAIL]` line with the fix, and then stops, because
nothing below it could be diagnosed — the missing environment exits 3 and the
unreadable configuration exits 2, as every script here does with a configuration
it cannot read.

Reading the firewall's port filters needs an elevated prompt. Run unelevated —
which is the documented way to run it — that one check is reported as *not
measured, needs Administrator* and does not turn a clean run into a 2.

**Setup says there is no supported Python.** Install Python 3.10 – 3.13 from
<https://www.python.org/downloads/> and run setup again, or (command-line path,
section 14) name an interpreter with `-PythonExe`. Nothing was created.

**`start.ps1` says `ComfyUI is not reachable` and exits 4** (from the tray:
**"LocalCanvas could not start."** / **"ComfyUI is not reachable."**, and the
launcher closes). ComfyUI is not running, or `comfy.host`/`comfy.port` in
`config/local/runtime.yaml` is wrong. In external mode LocalCanvas never
starts ComfyUI for you: start it, then try again — double-click
`LocalCanvas.exe` again, or run `start.ps1` again.

**"That photo is in HEIC format, which LocalCanvas cannot use yet."** The phone
could not decode the HEIC itself, so the original reached the gateway and was
refused. Choose a JPEG or PNG, or turn off high-efficiency (HEIC) photos in the
camera settings.

**A workflow is missing from the app, or the app shows none.** With ComfyUI
running, sync from the tray or run `pwsh .\scripts\sync-workflows.ps1 -DryRun`
(section 14) and read the report. A workflow listed as `NEEDS_REVIEW` was held
because something could not be decided with confidence, and the line says
what. A workflow listed as `NEEDS_API_EXPORT` was saved with **Save** and there
was no running ComfyUI (or no Chrome or Edge) to convert it — fix that and sync
again. If you synced while the Gateway was already running from the command
line rather than through the tray, stop and start it: it reads the catalogue
once, when it starts (the tray does this restart for you automatically —
section 6). Then tap **Refresh the list** in the app.

**Every check says `N workflow file(s) need a look`.** ComfyUI refused to
convert those files, or LocalCanvas could not read them with confidence, or
they are not workflows at all. `pwsh .\scripts\sync-workflows.ps1 -DryRun`
names each one and the reason; fix it in ComfyUI and save it again, and the
next check offers it (section 6).

**A workflow is reported as `no longer in your folder`.** You deleted it from
ComfyUI; LocalCanvas never removes a definition on its own. The report is
driven by the entry in `config/local/workflow-inventory.json`, so removing
that entry is what ends it — deleting the definition in
`config/local/workflows` does not (measured). Or set `detect_removed: false`
in `config/local/workflow-sources.yaml` to stop being told at all.

**`start.ps1` exits 6.** The workflow layer could not be established, and
either there is no catalogue to start on or you answered no to
`Start LocalCanvas anyway? [Y/n]` at a terminal, so no gateway was started —
the message above it says what happened. Fix what it names and run
`pwsh .\scripts\sync-workflows.ps1`.

**The phone cannot find the PC.** mDNS is suppressed on plenty of home networks.
Use the QR code or type the address; neither depends on mDNS. If those do not
reach the PC either, it is the firewall: check that the gateway's port is
allowed through Windows Firewall on **Private** networks (section 5).

**"Connected, but ComfyUI isn't running."** The gateway answered and ComfyUI did
not. Start ComfyUI on the PC, or check `comfy.host`/`comfy.port` in
`config/local/runtime.yaml`.

**The connection dropped mid-generation.** See section 12.

## 14. Advanced command line

Everything above runs through `LocalCanvas.exe`. It touches the runtime by no
other means than the calls described here: the same scripts, with `-Json`
and, on `start.ps1` and `stop.ps1`, `-Component`. Those two flags are new in
this release, added so the launcher could drive the scripts unattended —
and they are available on the command line too, though an ordinary CLI run
normally needs neither. The gateway's own instance identity and the port
check that refuses to start a second gateway onto one already in use are
new as well, and apply to every start regardless of path, so that one
running instance can always be told from another. Use this path when
Smart App Control blocks the exe (section 13), when you are on a PC without a
desktop session to put a tray icon on, when you script LocalCanvas from
something else, or just because you prefer it — it was the whole of LocalCanvas
before v0.2.0 and still is exactly as capable.

**Getting the scripts.**

```powershell
git clone https://github.com/shinKatana0/LocalCanvas.git LocalCanvas
cd LocalCanvas
```

The command-line path is meant to be used from a `git clone` — files from a
clone carry no Mark of the Web. The zip is for `LocalCanvas.exe`, not for
running scripts by hand.

### Install and start

```powershell
pwsh .\scripts\setup.ps1
pwsh .\scripts\start.ps1
```

Those two commands are a first run, whole — the same setup described in
section 2, in the same PowerShell window it always was, just not opened for
you. You copy no template, you open no YAML file, and the number of
configuration files you edit by hand is **zero**. Setup does not need ComfyUI
running; `start.ps1` does (or starts it itself, if you chose that).

`setup.ps1` chooses a Python inside the supported range and prints which one
and what version. (If there is none, it stops before creating anything and
tells you to install Python 3.10 – 3.13, or to name one with `-PythonExe`.) It
builds `.venv/` at the repository root, installs the gateway into it — always
as `.venv\Scripts\python.exe -m pip`, so it cannot write into ComfyUI's Python
— and checks that what it can import is *this* checkout rather than a copy
left somewhere else. Then it asks its two questions (section 2), writes your
configuration, reads it back the way `start.ps1` will, prints a status table,
and names what to run next.

**Answering in advance.** Every question has a parameter, so an unattended run
is never left waiting: it is told what is missing, names the parameter that
supplies it, and exits.

```powershell
pwsh .\scripts\setup.ps1 -Mode External -ComfyRoot "C:\path\to\ComfyUI"
```

| Parameter | Answers |
|---|---|
| `-Mode External` / `-Mode Managed` | Question 1. `External` alone is enough for a complete run. |
| `-ComfyRoot "C:\path\to\ComfyUI"` | Question 2. |
| `-WorkflowSource "C:\path\to\workflows"` | Question 3, when it is asked. |
| `-ComfyHost`, `-ComfyPort` | Where ComfyUI listens, when it is not `127.0.0.1:8188`. |
| `-PythonExe`, `-VenvPath`, `-Recreate`, `-Dev` | Which interpreter, where the environment goes, rebuild it, add the test extra. |

**Running setup again.** It is idempotent, and a second run on a healthy
installation prints the same status table and `Nothing to change.` It asks
nothing, and reinstalls the gateway only when its own check finds a problem.
**A configuration file that is already there is left exactly as it is.** If
setup could not work out where your workflows are, the status table says
`Workflow sources   not configured` and prints the command that finishes the
job: `pwsh .\scripts\setup.ps1 -WorkflowSource '<your workflow folder>'`.

**Then start it.**

```powershell
pwsh .\scripts\start.ps1
```

It loads the configuration, makes sure ComfyUI is genuinely ready (a real
polled HTTP probe, never a fixed sleep), checks your workflow folder, starts
the gateway, and prints your endpoint and a QR code in the terminal. **Keep
that window open** while you use the phone: closing it stops the gateway too
— this is the one real difference from the tray, which keeps running once you
close its window and stops only on Exit or sign-out.

**Unlike setup, this one needs ComfyUI up.** In external mode LocalCanvas
never starts it for you, so a ComfyUI that is not answering ends the run with
`ComfyUI is not reachable` and exit 4, before any gateway is started. In
managed mode it starts ComfyUI itself and waits for it.

On every start it checks your workflow folder, the same check the tray runs:

| What the check finds | What happens |
|---|---|
| Nothing new and nothing edited | `Workflows: unchanged - nothing new and nothing edited` and LocalCanvas starts. No sync, no conversion, no question. |
| Something new or edited, at a terminal | A one-line summary such as `Workflows: 1 new, 2 changed`, then `Sync workflows now? [Y/n]`. **Enter means yes.** |
| Something new or edited, nobody to ask | No prompt and no wait. It says what changed, names `pwsh .\scripts\sync-workflows.ps1`, and starts on the catalogue it already has. |

A session "nobody can ask" is a scheduled task, a CI step, a pipe, or a
`-NonInteractive` shell. Measured at about **4 to 5.5 seconds for 250
workflows** (roughly 14–19 ms each), so about 8 to 10 seconds for 500.

```powershell
pwsh .\scripts\start.ps1 -SyncWorkflows      # sync whatever changed, no question
pwsh .\scripts\start.ps1 -SkipWorkflowCheck  # do not look at the folders at all
```

They contradict each other: passing both is refused, with nothing started.

### Importing by hand

```powershell
pwsh .\scripts\sync-workflows.ps1 -DryRun
pwsh .\scripts\sync-workflows.ps1
```

**Start ComfyUI first** — for `-DryRun` too. The dry run writes nothing, but it
really asks ComfyUI to convert workflows saved with **Save**, so that it can say
what would import; with nothing answering it can spend up to four minutes
before giving up on such a file. `-NoConvert` is the fast report that asks
ComfyUI nothing and lists every such file as `NEEDS_API_EXPORT`.

The dry run names every workflow it would import, every one it would hold for
review, and every one it could not convert, with the reason. The real run
writes:

| What | Where |
|---|---|
| The definitions you can read and edit | `config/local/workflows` |
| Its own copies of the API-format graphs | `config/local/imported-workflows` |
| What was found this run | `config/local/workflow-inventory.json` |

With `-DryRun`, `-RegenerateLabels` lists exactly what it would replace and
writes nothing; without it, it replaces every generated label with a fresh one
(section 6).

**The gateway reads the catalogue once, when it starts.** A sync you run while
it is already running is not seen until you restart it:

```powershell
pwsh .\scripts\stop.ps1
pwsh .\scripts\start.ps1
```

(The tray does this restart for you automatically, section 6.) An importer run
that fails, and a check that could not run at all, are both treated the same
way: the definitions you already have are left exactly as they were. At a
terminal it then asks `Start LocalCanvas anyway? [Y/n]`, defaulting to yes;
with nobody to ask it reports and carries on. It stops, with exit code **6**
and no gateway started, only when there is *no* catalogue to fall back on, or
when you answer no.

### Stopping and status from the command line

```powershell
pwsh .\scripts\stop.ps1
pwsh .\scripts\status.ps1
```

See section 15 for what each stops and reports, whichever path started
LocalCanvas.

### Getting ComfyUI, and diagnosing the machine

`comfy\setup.ps1` and `comfy\doctor.ps1` are command-line only, on both
install paths (section 1 has them in full). `scripts\doctor.ps1` (section
13) is command-line only too, and — like `status.ps1` (section 12) —
diagnoses the checkout it runs from: for a zip install, its tray equivalent
is the tray's status lines, **Open status** and **Open logs folder**, never
a fresh `git clone`.

## 15. Stopping, and an external ComfyUI

**From the tray:** right-click and choose **Exit** (section 4). **From the
command line:**

```powershell
pwsh .\scripts\stop.ps1
```

Either way it stops only processes LocalCanvas itself started. If it reused a
ComfyUI you already had running, or you are in external mode, it leaves it
alone and says so — the tray's ComfyUI line says `(external)` for exactly this
reason (section 4). Closing the window you ran `start.ps1` in also stops the
Gateway. The tray icon has no such window of its own to close, and closing
**Open status** does not stop anything either — it only hides that window
(section 4). Choosing **Exit** from the tray menu is the only way to stop
what the tray started.

**Signing out or shutting down Windows** with the tray running stops
LocalCanvas the same way Exit does, automatically, and Windows is asked to
wait up to 45 seconds for it — it shows **"Stopping LocalCanvas"** and holds
the sign-out screen for you rather than ending the launcher after its usual
few seconds. That is a best effort, not a guarantee: under heavy load, a
Gateway start that is still under way when that budget runs out is left
running rather than interrupted, and is reported as such rather than silently
lost track of.

**One thing is yours to clean either way:** getting an input file to a loader
node means handing it to ComfyUI's own upload endpoint, and ComfyUI keeps it.
LocalCanvas puts them all in a single `localcanvas/` subfolder of ComfyUI's
input directory so you can empty it in one action — it cannot delete them
itself.

## 16. Known limitations

- The PC side is **Windows only**.
- `LocalCanvas.exe` is unsigned. Some Windows security configurations may
  warn about or block unsigned executables; Smart App Control may block it,
  with no "Run anyway". The command-line path (section 14) is
  unaffected and is what the maintainer actually runs day to day. LocalCanvas
  does not ask you to weaken Windows security to run it.
- The tray launcher itself has not been exercised end to end on a PC with
  Smart App Control off — see "What has been tested" in section 1.
- The maintainer has tested pairing and generation by hand on one foldable
  phone over Wi-Fi against a real ComfyUI. Nothing automated covers that path.
- Uploading a picture or clip has not yet been confirmed working from a phone.
- Prompt translation, and discovery (mDNS) reaching a phone, have only been
  exercised against fakes.
- A workflow held as `NEEDS_REVIEW` needs a person to decide what to expose.

---

## More

- [SECURITY.md](../SECURITY.md) — the security model and how to report a problem.
- [`privacy-security.md`](privacy-security.md) — the privacy claims in full,
  including the optional machine-level strict LAN mode.
- [`workflow-schema.md`](workflow-schema.md) — the definition format, if you want
  to edit one the importer wrote, or write one by hand.
- [`../workflows/examples/README.md`](../workflows/examples/README.md) — three
  complete worked examples: prompt-only, image-input and video-input.
- [`connection.md`](connection.md), [`recovery.md`](recovery.md) — pairing,
  reconnect and job recovery, in full.
