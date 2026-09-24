# LocalCanvas user guide

**English** · [Русский](user-guide.ru.md) · [日本語](user-guide.ja.md)

Everything you need from an empty folder to a picture on your phone. Read
[README.md](../README.md) first if you have not: it says what LocalCanvas is and
what it deliberately is not.

Every PowerShell line below is written as you would type it at the root of the
repository.

---

## 1. Before you start

On the PC that will run the generation:

| You need | Why |
|---|---|
| **Windows 10 or 11** | The runtime scripts are PowerShell and the host side is Windows-only at v0.1. |
| **PowerShell 7 or newer** (`pwsh`) | Windows PowerShell 5.1 is not supported. `winget install --id Microsoft.PowerShell`, or <https://aka.ms/powershell>. |
| **git** | Step one is cloning this repository, and the optional ComfyUI bootstrap clones too. A ComfyUI portable user may well not have it: `winget install --id Git.Git`, or <https://git-scm.com/download/win>. |
| **Python 3.10 – 3.13** | The gateway's declared range is `>=3.10,<3.14`, from <https://www.python.org/downloads/>. LocalCanvas builds its own `.venv/` and never installs into ComfyUI's Python. With no supported Python on the PC, setup stops before it creates anything and tells you to install one. |
| **ComfyUI**, working, with a GPU | LocalCanvas runs *your* workflows; it does not replace ComfyUI. |
| **Google Chrome or Microsoft Edge** | Only to convert workflows saved with ComfyUI's **Save**. Workflows exported with **Export (API)** need no browser. |
| **Flutter** (stable) and the **Android SDK** | Only to build the Android app yourself. The longest install here: follow Flutter's own Windows guide, <https://docs.flutter.dev/get-started/install>, which covers the Android SDK too; then `flutter doctor --android-licenses`. Section 5. |
| An **Android phone** on the same Wi-Fi | The thing you will actually use. **Android 7.0 (API 24)** or newer — the minimum the release build declares. |

On a machine with several Pythons installed, you do not have to pick one:
`setup.ps1` selects an interpreter inside the supported range, and prints which
one it chose and what version it got.

**What has been tested.** Public CI (GitHub Actions, `windows-latest`, no real
ComfyUI) runs the gateway's tests on Python 3.10 and 3.13, `flutter analyze` and
`flutter test` for the app, and the PowerShell script tests, on every push to
`main` and every pull request. By hand, the maintainer has tested pairing and
generation on one foldable phone over Wi-Fi against a real ComfyUI; nothing
automated covers that path. Uploading a picture or clip has not yet been
confirmed working from a phone. Prompt translation, discovery (mDNS) reaching a
phone, and the doctor's elevated firewall check have only been exercised
against fakes. Of the ComfyUI bootstrap profiles, only Minimal is validated
(section 2).

## 2. Getting ComfyUI

### You already have one — this is the normal case

Nothing to do. LocalCanvas never writes into a ComfyUI it did not install, never
adds a package to its Python, and never edits its configuration. The only
coupling between the two is HTTP.

### You do not have one — the optional bootstrap

```powershell
pwsh .\comfy\setup.ps1 -Profile Minimal -DryRun
pwsh .\comfy\setup.ps1 -Profile Minimal
```

The dry run prints every action it would take and writes nothing at all — not
one directory. The real run clones ComfyUI at a pinned revision (about 7 MiB
transferred, about 31 MiB on disk) and creates its `user/default/workflows`
folder. Run it twice and the second run says everything is already complete and
changes nothing.

**Where it installs.** With no `-ComfyRoot`, the root is
`%LOCALAPPDATA%\LocalCanvas\comfyui` — on a typical machine
`C:\Users\<you>\AppData\Local\LocalCanvas\comfyui`. Inside it:

| What | Where |
|---|---|
| The ComfyUI checkout — this is the ComfyUI that section 3 asks you for | `<root>\ComfyUI` |
| Your workflow folder, which section 3 finds by itself | `<root>\ComfyUI\user\default\workflows` |
| The record of what was installed | `<root>\localcanvas-bootstrap.json` |

Pass `-ComfyRoot "D:\somewhere"` to put it elsewhere. You do not have to retype
any of it: `pwsh .\scripts\setup.ps1` in section 3 offers this location as the
answer to *where is your ComfyUI*, so you press Enter. The dry run prints the
paths in full if you want to read them first — the `Root:` line at the top, then
one `[PLAN]` line per action, and a closing block that repeats **the ComfyUI
checkout and the install record**; the workflow folder appears in the plan
above, not in that block.

The `user/default/workflows` folder exists from the moment the bootstrap
finishes, so the importer in section 4 has something to read even before you have
saved a workflow.

**What it does not do, stated plainly:** it downloads no models and builds no
Python environment. Before that ComfyUI will start you still have to install a
supported Python yourself, install ComfyUI's own `requirements.txt` (several
gigabytes, and choosing the CUDA build that matches your GPU is your decision),
obtain the models your workflows need, and start ComfyUI.

Only the **Minimal** profile is supported at v0.1. The manifest format also
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

## 3. Install and start LocalCanvas

```powershell
pwsh .\scripts\setup.ps1
pwsh .\scripts\start.ps1
```

Those two commands are a first run, whole. You copy no template, you open no
YAML file, and the number of configuration files you edit by hand is **zero**.
Setup does not need ComfyUI running; `start.ps1` does (or starts it itself,
if you chose that).

### What the first run does

`setup.ps1` chooses a Python inside the supported range and prints which one and
what version. (If there is none, it stops before creating anything and tells you
to install Python 3.10 – 3.13 from <https://www.python.org/downloads/>, or to
name one with `-PythonExe`.) It builds `.venv/` at the repository root, installs
the gateway into it — always as `.venv\Scripts\python.exe -m pip`, so it cannot write into
ComfyUI's Python — and checks that what it can import is *this* checkout rather
than a copy left somewhere else. Then it asks its questions, writes your
configuration, reads that configuration back the way `start.ps1` will read it,
prints a status table, and names what to run next.

### The two questions

1. **"Do you start ComfyUI yourself, or should LocalCanvas start it for you?"**
   Asked first, because the answer decides what else is needed. It is offered as
   `1  I start ComfyUI myself` and `2  LocalCanvas starts ComfyUI for me`, and
   **1** is what Enter gives you.
   * **1 — external mode** (`-Mode External`). LocalCanvas never launches
     ComfyUI and never stops it; it verifies the address answers before it
     starts the gateway, and that is all. No launcher has to be worked out at
     all, which is why this mode needs the least from you.
   * **2 — managed mode** (`-Mode Managed`). LocalCanvas may start ComfyUI for
     you, reuses one that is already running rather than starting a second, and
     only ever stops one it started itself. It starts it with the Python that is
     already beside your ComfyUI — `python_embeded\python.exe` for a portable
     build, `venv\Scripts\python.exe` or `.venv\Scripts\python.exe` for a clone
     — which setup reads off the installation and writes into
     `comfy.launcher`. It installs nothing into that interpreter. If there is
     none, setup **refuses** rather than guessing: *"There is no Python beside
     ... to start ComfyUI with ... LocalCanvas will not guess at an interpreter
     it has not found. Nothing has been written to config."*, and it names
     `-Mode External` as the way on.
2. **"Where is your ComfyUI?"** The folder holding `main.py`, or the folder
   holding *that* folder for a portable build. Both layouts are recognised and
   whatever you type is validated. This one cannot be inferred: LocalCanvas
   scans no drive, walks no directory tree and reads no registry. If you
   installed ComfyUI with the bootstrap in section 2, its location is offered as
   the default and you press Enter.

A **third** question is asked only when `user\default\workflows` — ComfyUI's own
place for workflows — is not inside the folder you named. When it is there, it
is found and nothing is asked.

Nothing else is asked, because nothing else has to be: the display name comes
from the computer's name, ComfyUI's address from ComfyUI's own default
`127.0.0.1:8188`, the gateway's from `0.0.0.0:7801`, the launcher is read off
the installation you named, the registry is `config/local/workflows`, and the
`startup`, `media` and `prompt_translation` sections are left out entirely
because every value in them already equals the gateway's own default.

**ComfyUI does not have to be running while you do this.** Setup makes one
bounded request to the address it inferred, and if nothing answers it prints

    [INFO] ComfyUI did not answer at http://127.0.0.1:8188.
           That is expected if it is not running yet. If it IS running, the
           address is wrong: check comfy.host and comfy.port in <your config>.

and finishes anyway, exit 0. A failed probe is never treated as a failed setup —
it cannot tell "not started yet" from "wrong address", so it says both.

Two files are written, both in the gitignored `config/local/`, so your paths
never enter a commit:

| File | What it holds |
|---|---|
| `config/local/runtime.yaml` | Mode, your ComfyUI, the addresses, the registry, this PC's display name. |
| `config/local/workflow-sources.yaml` | The one folder LocalCanvas reads your workflows from. |

[`config/examples/runtime.example.yaml`](../config/examples/runtime.example.yaml)
is the reference for everything those files can hold — every setting, what it
means, and what happens if you leave it out. Read it when you want to change
something setup wrote. Two values are worth knowing about before you edit them
by hand:

- **`comfy.root`** must be an absolute path. LocalCanvas never guesses one.
- **`comfy.launcher.executable`** and **`comfy.launcher.script`** are **relative
  to `comfy.root`** — `python_embeded/python.exe` and `ComfyUI/main.py` for a
  portable build, `venv/Scripts/python.exe` and `main.py` for a plain clone. An
  absolute path is taken as written; a bare name like `python` is **not** one
  and does not work, because it would be read as `<root>\python`. Setup reads
  both values off the installation you pointed it at, which is why you do not
  have to get this right by hand.

### Answering in advance

Every question has a parameter, so an unattended run is never left waiting: it
is told what is missing, names the parameter that supplies it, and exits.

```powershell
pwsh .\scripts\setup.ps1 -Mode External -ComfyRoot "C:\path\to\ComfyUI"
```

| Parameter | Answers |
|---|---|
| `-Mode External` / `-Mode Managed` | Question 1. `External` alone is enough for a complete run. |
| `-ComfyRoot "C:\path\to\ComfyUI"` | Question 2. |
| `-WorkflowSource "C:\path\to\workflows"` | Question 3. |
| `-ComfyHost`, `-ComfyPort` | Where ComfyUI listens, when it is not `127.0.0.1:8188`. |
| `-PythonExe`, `-VenvPath`, `-Recreate`, `-Dev` | Which interpreter, where the environment goes, rebuild it, add the test extra. |

### Running setup again

It is idempotent, and a second run on a healthy installation prints the same
status table and `Nothing to change.` It asks nothing. It checks the gateway in
`.venv/` locally, and when that check passes it installs nothing — it prints
`Gateway already installed from this checkout - nothing to install` — so it
works offline too. Only when the check finds a problem does it reinstall the
gateway, and it says why. **A configuration file that is already there is left
exactly as it is** — yours is yours, whatever you put in it. It touches
no workflow, downloads no model and writes nothing inside ComfyUI.

One thing a re-run does not repair by itself: an environment built on an
interpreter outside the supported range. That is refused with `-Recreate` named,
because rebuilding is the only thing that can fix it.

If setup could not work out where your workflows are, the status table says
`Workflow sources   not configured` and prints the command that finishes the
job — `pwsh .\scripts\setup.ps1 -WorkflowSource '<your workflow folder>'`. That
run writes the source list and changes nothing else.

### Then start it

```powershell
pwsh .\scripts\start.ps1
```

It loads the configuration, makes sure ComfyUI is genuinely ready (a real polled
HTTP probe, never a fixed sleep), checks your workflow folder as section 4
describes, starts the gateway, and prints your endpoint and a QR code in the
terminal. **Keep that window open** while you use the phone: closing it stops
the gateway too.

**Unlike setup, this one needs ComfyUI up.** In external mode — answer 1, the
default — LocalCanvas never starts it for you, so a ComfyUI that is not
answering ends the run with `ComfyUI is not reachable` and exit 4, before any
gateway is started. In managed mode it starts ComfyUI itself and waits for it.

**Setup imports no workflow.** The first `start.ps1` is where they arrive: it
finds everything in your folder as new and offers to import it (section 4).

To look the machine over at any point — before or after — `pwsh
.\scripts\doctor.ps1` is read-only and diagnoses everything at once (section 13).

## 4. Your workflows

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

### Adding or changing a workflow

1. Create or edit the workflow in ComfyUI, and save it into your workflow
   folder.
2. If LocalCanvas is running, stop it — `pwsh .\scripts\stop.ps1`, or close the
   window you started it in. The gateway reads the catalogue once, when it
   starts, so a running one would not see the change.
3. With ComfyUI running (unless you chose to let LocalCanvas start it), run
   `pwsh .\scripts\start.ps1`.
4. It finds the workflow and asks:

       [WARN] Workflows: 1 new
              Sync workflows now? [Y/n]

   Press Enter (yes). The import runs, and then LocalCanvas starts.
5. If the app was already open and the workflow is not listed, tap
   **Refresh the list** (↻) at the top of **Choose a workflow**.

Nothing watches your folder in the background. A change is picked up when you
run `start.ps1`, or when you import by hand (below) — never on its own.

### What every start checks

`start.ps1` looks at your folders before it starts the gateway. The check reads
each file and compares its **content** with what was imported last time, so
re-saving a workflow without changing it counts as unchanged. It converts
nothing, writes nothing, and asks ComfyUI for nothing.

It is not free, and the number is worth knowing if your folder is large:
measured at about **4 to 5.5 seconds for 250 workflows**, scaling linearly at
roughly **14 to 19 ms each** — so about 8 to 10 seconds for 500. It is a range
because two careful measurements of the same code, on different machines and
folders, disagreed by about a quarter.

| What the check finds | What happens |
|---|---|
| Nothing new and nothing edited | `Workflows: unchanged - nothing new and nothing edited` and LocalCanvas starts. No sync, no conversion, no question. |
| Something new or edited, at a terminal | A one-line summary such as `Workflows: 1 new, 2 changed`, then `Sync workflows now? [Y/n]`. **Enter means yes.** |
| Something new or edited, nobody to ask | No prompt and no wait. It says what changed, names `pwsh .\scripts\sync-workflows.ps1`, and starts on the catalogue it already has. |

Answering **yes** runs the same importer as "Importing by hand" below, and then
startup continues. Answering anything else declines: nothing is written, and
LocalCanvas starts on the catalogue it already has.

A session "nobody can ask" is a scheduled task, a CI step, a pipe, or a
`-NonInteractive` shell. LocalCanvas never syncs on its own in one, because a
ComfyUI save is often an experiment or a half-finished graph and a phone should
not start showing it by surprise.

Two switches, when you already know the answer:

```powershell
pwsh .\scripts\start.ps1 -SyncWorkflows      # sync whatever changed, no question
pwsh .\scripts\start.ps1 -SkipWorkflowCheck  # do not look at the folders at all
```

`-SyncWorkflows` still runs the cheap check first, so a folder nobody touched
costs exactly what it costs without the switch. `-SkipWorkflowCheck` is for a
very large folder on a slow disk, or a start where you know nothing changed.
They contradict each other: passing both is refused, with nothing started.

### When a workflow could not be imported

A workflow saved with **Save** that could not be converted is handled by *why*:

- **Offered again next time.** When the conversion could not even be
  attempted — no Chrome or Edge, or ComfyUI not ready — the next start offers
  it again, as `N not converted last time`, with the same
  `Sync workflows now? [Y/n]` question. Fix the reason (start ComfyUI, install
  a browser) and answer yes.
- **Needs a look.** When ComfyUI refused that graph, or LocalCanvas could not
  read the converted graph with confidence, every start says
  `N workflow file(s) need a look` until the file changes. Run
  `pwsh .\scripts\sync-workflows.ps1 -DryRun` to see which workflow and why,
  fix it in ComfyUI and save it again — a changed file is offered again like
  any other.

A workflow LocalCanvas has imported is not reported again while it stays the
same.

**A workflow you deleted from your ComfyUI folder** is reported as
`no longer in your folder` on every start. **Nothing is ever deleted from the
catalogue automatically.** The report is driven by
`config/local/workflow-inventory.json`, the record of what was found, so what
ends it is removing that workflow's entry from there — deleting the definition
in `config/local/workflows` stops the phone seeing the workflow but leaves the
report where it was. `detect_removed: false` in
`config/local/workflow-sources.yaml` turns the report off altogether, which is
what that setting is for when the folder lives on a drive you do not always
have plugged in.

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
review, and every one it could not convert, with the reason. That is the report
to read when a workflow does not turn up on the phone. Its
`Converted by ComfyUI` line counts what was converted, reused from an earlier
run, refused and not attempted. The real run writes:

| What | Where |
|---|---|
| The definitions you can read and edit | `config/local/workflows` |
| Its own copies of the API-format graphs | `config/local/imported-workflows` |
| What was found this run | `config/local/workflow-inventory.json` |

A generated definition is yours to edit. A later run rewrites it only when the
workflow behind it changed, and keeps the name, presentation, translation
setting and every label and help line you wrote. To get the generated ones back,
add `-RegenerateLabels`; with `-DryRun` it lists exactly what it would replace
and writes nothing.

**A workflow it cannot read with confidence is held, not guessed.** It is
reported as `NEEDS_REVIEW` with a sentence naming exactly what could not be
decided — for a graph, the node and the input — and no definition is written for
it. Every other workflow imports regardless, and there is no switch to import it
anyway. Two ways out, and which is better depends on that sentence:

1. **Change the workflow so the question goes away.** Often it is a node used in
   a way the importer cannot read as an input — rewire or replace it in ComfyUI,
   save, and sync again.
2. **Write that one definition yourself.** A definition is a small YAML file in
   `config/local/workflows` next to the generated ones: the format is
   [`workflow-schema.md`](workflow-schema.md), and
   [`../workflows/examples/`](../workflows/examples/) holds three complete
   worked ones — prompt-only, image-input and video-input — to copy from. The
   importer leaves a definition you wrote alone.

Either way, check the folder before you restart the gateway — without ComfyUI, a
GPU or a network:

```powershell
.\.venv\Scripts\python.exe -m localcanvas_gateway.workflows config\local\workflows
```

    [ OK ] my-portrait (11 fields) - config\local\workflows\my-portrait.yaml
    2 workflows loaded, 0 rejected, from config\local\workflows

A definition it rejects is named with the file, the workflow and the problem;
the rest still load.

### When the sync itself goes wrong

An importer run that fails, and a check that could not run at all, are both
treated the same way: **the definitions you already have are left exactly as
they were**, and LocalCanvas tells you how many of them there are. At a terminal
it then asks `Start LocalCanvas anyway? [Y/n]`, defaulting to yes; with nobody
to ask it reports and carries on. It stops, with exit code **6** and no gateway
started, only when there is *no* catalogue to fall back on — the app would
otherwise connect and find nothing to generate with — or when you answer no to
that question.

### The gateway reads the catalogue once, when it starts

That is why a sync you accept at startup is in place before the gateway is
started, and why one you run *while* it is running is not. To pick those up:

```powershell
pwsh .\scripts\stop.ps1
pwsh .\scripts\start.ps1
```

If you hand-wrote `config/local/runtime.yaml` before `setup.ps1` existed, check
`workflows.registry` as well: it has to name the folder the importer writes to,
`config/local/workflows`. A configuration setup wrote already names it.

## 5. Installing the app

There is no APK in the repository itself. Where the repository publishes a
release, its **Releases** page is the simplest place to get one: download the
APK there and install it as below. Otherwise, build it yourself.

### Build it yourself

From `app/`:

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
`LocalCanvas-<version>-<abi>.apk`; most phones want `arm64-v8a`. Install one with `flutter install`,
`adb install`, or by copying the file to the phone — where Android will ask you
to allow installs from whatever app you copied it with, because this is a
sideload and not a store install.

### Builds from CI

The repository's **APK** workflow (`.github/workflows/apk.yml`) runs the same
build on every push to `main` and on demand. Where you can see a run of it, the
artefact **`LocalCanvas-apk-debug-signed`** at the bottom of the run page is a
zip holding the three APKs. Artefacts are kept **14 days**, so do not bookmark
one.

### Every APK here is debug-signed

**The project configures no release signing**, so the release build type carries
the debug signing configuration, and every build — yours or CI's — is signed
with an Android debug key. It is a build to sideload: not a verified or distributable
release artefact, not signed by the project, and no more trustworthy than one
you build yourself.

That has a consequence worth knowing before you install anything. **The debug
key is generated per machine, and a later run does not reproduce it** — a CI
runner's differs from your PC's, and from the next run's — and Android refuses an
update signed by a different key, with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE` (*signatures do not match*). So installing
a newer APK over an older one can fail, and the way through is to uninstall
LocalCanvas first, which takes the app's stored settings with it: export your
profile beforehand (section 12) if you care about them.

To check a signature yourself, use `apksigner verify --print-certs`; these APKs
carry no v1/JAR signature at all (the app's minimum SDK is 24), so
`keytool -printcert -jarfile` answers *Not a signed jar file* and tells you
nothing.

## 6. Connecting over Wi-Fi

Open the app with the PC running. There are four ways in, none privileged, and
all of them end in the same handshake before an endpoint is accepted:

1. **The remembered server** — the last endpoint that worked is tried on launch.
2. **On this network** — the gateway advertises itself over mDNS and the app
   lists what it finds. Some routers and VPNs suppress multicast; that is a
   normal outcome and the app simply offers the other three.
3. **Scan pairing code** — the QR `start.ps1` printed. Entirely local: no QR
   service, no shortener, no secret in the payload.
4. **Enter address** — always offered. `192.0.2.42`, `192.0.2.42:7801`
   and `http://192.0.2.42:7801` all work (with your PC's own address); the
   default port is 7801.

If something answers but is not LocalCanvas, or speaks a different API version,
the app says which and what to do about it.

**Windows Firewall, which is the likeliest thing in the way.** The gateway is a
new program listening on a port, and Windows blocks that from the network until
somebody allows it. The first time you run `start.ps1` you should get the
*Windows Defender Firewall* dialog: tick **Private networks**, and not Public —
the gateway has no authentication and belongs on your own LAN only. If no
dialog appeared, or it was dismissed, everything on the PC still looks correct
and the phone still cannot reach it: the QR code scans, the address is right,
and the connection times out.

`pwsh .\scripts\doctor.ps1` reports the gateway's port and whether anything is
listening on it. It reports the firewall rules themselves only from an elevated
prompt — run unelevated, which is the documented way, it says *not measured,
needs Administrator* rather than guessing. Windows' own **Windows Defender
Firewall with Advanced Security** is where an existing rule can be checked or
corrected by hand, and [`privacy-security.md`](privacy-security.md) describes
the optional `scripts\strict-lan.ps1`, which goes further and is reversible.

## 7. Creating something

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

## 8. Working from a picture or a clip

A workflow whose definition exposes an image or a video input shows a picker.
Choose a photo or a clip, see it previewed, replace it or remove it, and watch
real byte progress while it uploads.

**HEIC photos are handled for you.** Modern Samsung and iPhone cameras save HEIC
by default. LocalCanvas looks at the file's *bytes*, not its name, and converts a
HEIC or HEIF photo to JPEG **on the phone** before uploading. Every other file
passes through byte for byte — a PNG keeps its transparency, a JPEG is not
re-encoded. If the phone has no HEIF decoder or the decode fails, the original is
uploaded and the gateway refuses it with a message naming the format (see
troubleshooting).

**Video results** get a local preview and playback, plus Save and Share. Large
clips take longer to upload; `media.max_video_megabytes` in
`config/local/runtime.yaml` is the limit the gateway enforces, and the refusal
message names it.

Uploaded files live in a temporary store on the PC with a lifetime of their own
(`media.ttl_seconds`, an hour by default). A generation that refers to a file
which has already expired says so and asks for it again rather than failing
mysteriously.

## 9. Main and Advanced

Each workflow shows the few fields that matter first and keeps the rest behind
**Advanced**. Which is which comes from the workflow's definition, not from the
app guessing: the app understands field *types* and *presentation* and knows
nothing about models, checkpoints or node graphs. Grouping is configuration too —
the section names come from your definitions, and an unknown group renders as its
own section. A filter above the workflow cards narrows the list to one group, or
back to **All**.

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
is picked up the next time you start it.

Your original text is always what the app shows, what a draft stores and what
Generate Again resubmits. The translation never replaces your words.

## 11. My defaults, drafts and saved setups

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

## 12. Moving to another phone

**Your profile** is your saved settings and setups as one file. Export it, move
the file however you like, and import it on the other phone. Nothing about a
server and nothing you have generated is in it, and an import removes nothing
that is already there — use **Reset settings to my defaults** to apply what you
imported. Appearance and app language belong to the device and are deliberately
not in the profile. A profile written by a newer LocalCanvas is refused by name
rather than half-read.

## 13. When something is wrong

**A script refuses to start: "cannot be run because it contained a `#requires`
statement".** You are running it in Windows PowerShell 5.1, which LocalCanvas
does not support — every script here needs PowerShell 7 or newer. Nothing was
read, written or started. That message comes from Windows itself, so it appears
in your system's language, it is wrapped to your window width (the version
numbers in it may be split across two lines), and it calls the requirement
"Windows PowerShell 7.0" — no such product exists. What you need is PowerShell
7, whose command is `pwsh`. Install it from <https://aka.ms/powershell>, or with
`winget install --id Microsoft.PowerShell`, and run the commands in this guide
from a `pwsh` window. To see which one you are in:

```powershell
$PSVersionTable.PSVersion
```

One more thing, if you call these scripts from a script of your own: the refusal
is an error and not an exit code, so test `$?` rather than `$LASTEXITCODE`.

**Run the doctor first.**

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
<https://www.python.org/downloads/> and run `pwsh .\scripts\setup.ps1` again,
or name an interpreter with `-PythonExe`. Nothing was created.

**Setup stops, naming a parameter.** It was run where nobody can answer its
questions, so it names the parameter that answers in advance — `-Mode`,
`-ComfyRoot`, `-WorkflowSource` (section 3) — and writes nothing.

**`start.ps1` says `ComfyUI is not reachable` and exits 4.** ComfyUI is not
running, or `comfy.host`/`comfy.port` in `config/local/runtime.yaml` is wrong.
In external mode LocalCanvas never starts ComfyUI for you: start it, then run
`start.ps1` again.

**"That photo is in HEIC format, which LocalCanvas cannot use yet."** The phone
could not decode the HEIC itself, so the original reached the gateway and was
refused. Choose a JPEG or PNG, or turn off high-efficiency (HEIC) photos in the
camera settings.

**A workflow is missing from the app, or the app shows none.** Run
`pwsh .\scripts\sync-workflows.ps1 -DryRun` with ComfyUI running, and read the
report. A workflow listed as `NEEDS_REVIEW` was held because something could not
be decided with confidence, and the line says what. A workflow listed as
`NEEDS_API_EXPORT` was saved with **Save** and there was no running ComfyUI (or
no Chrome or Edge) to convert it — fix that and sync again. If you synced while
the gateway was running, stop and start it: it reads the catalogue once, when it
starts. Then tap **Refresh the list** in the app.

**Every start says `N workflow file(s) need a look`.** ComfyUI refused to
convert those files, or LocalCanvas could not read them with confidence, or they
are not workflows at all. `pwsh .\scripts\sync-workflows.ps1 -DryRun` names each
one and the reason; fix it in ComfyUI and save it again, and the next start
offers it (section 4).

**Every start says `N not converted last time`.** Those workflows were saved with
**Save**, and the last import could not convert them — no Chrome or Edge, or
ComfyUI was not ready. Fix that and answer yes to `Sync workflows now? [Y/n]`.

**Every start says a workflow is `no longer in your folder`.** You deleted it
from ComfyUI; LocalCanvas never removes a definition on its own. The report is
driven by the entry in `config/local/workflow-inventory.json`, so removing that
entry is what ends it — deleting the definition in `config/local/workflows` does
not (measured). Or set `detect_removed: false` in
`config/local/workflow-sources.yaml` to stop being told at all.

**`start.ps1` exits 6.** The workflow layer could not be established, and
either there is no catalogue to start on or you answered no to
`Start LocalCanvas anyway? [Y/n]`, so no gateway was started — the message
above it says what happened. Fix what it names and run
`pwsh .\scripts\sync-workflows.ps1`.

**`start.ps1` says `Workflows: no folder is configured yet`, or
`sync-workflows.ps1` stops with `No workflow folder is configured yet` (exit 2,
no file written).** Setup could not tell where your
workflows are, so there is no `config/local/workflow-sources.yaml` yet. Name the
folder once:

```powershell
pwsh .\scripts\setup.ps1 -WorkflowSource '<your workflow folder>'
```

That run writes the source list and changes nothing else.

**The phone cannot find the PC.** mDNS is suppressed on plenty of home networks.
Use the QR code or type the address; neither depends on mDNS. If those do not
reach the PC either, it is the firewall: check that the gateway's port is
allowed through Windows Firewall on **Private** networks (section 6).

**"Connected, but ComfyUI isn't running."** The gateway answered and ComfyUI did
not. Start ComfyUI on the PC, or check `comfy.host`/`comfy.port` in
`config/local/runtime.yaml`.

**The connection dropped mid-generation.** The app reconnects automatically — 1
to 10 attempts, 3 by default, settable per device — and then asks the gateway
whether the job survived. If it cannot tell, it says so rather than guessing.

**What is running right now?**

```powershell
pwsh .\scripts\status.ps1
```

Read-only: what is up, what LocalCanvas owns, and the endpoint.

## 14. Stopping

```powershell
pwsh .\scripts\stop.ps1
```

It stops only processes LocalCanvas itself started. If it reused a ComfyUI you
already had running, or you are in external mode, it leaves it alone and says
so. Closing the window you ran `start.ps1` in also stops the gateway.

One thing is yours to clean: getting an input file to a loader node means handing
it to ComfyUI's own upload endpoint, and ComfyUI keeps it. LocalCanvas puts them
all in a single `localcanvas/` subfolder of ComfyUI's input directory so you can
empty it in one action — it cannot delete them itself.

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
