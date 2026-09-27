# LocalCanvas

**English** · [Русский](README.ru.md) · [日本語](README.ja.md)

**ComfyUI for building workflows. LocalCanvas for using them.**

LocalCanvas is an Android app for the ComfyUI workflows you already have. Pick a
workflow on your phone, type a prompt, add a picture or clip if the workflow
takes one (see [Known limitations](#known-limitations)), and press Generate. You
never see a node graph.

    Android app
        │  your Wi-Fi / LAN
        ▼
    LocalCanvas Gateway    ← the only thing on your network
        │  localhost
        ▼
    ComfyUI  →  GPU

- **Local-first.** Everything runs on your PC and your own network.
- **Works with your existing ComfyUI.** Nothing is installed into it.
- **An Android front end** that shows each workflow as a simple form.
- **Workflow import and sync** from your ComfyUI workflow folder.
- **No LocalCanvas cloud and no account.**

**What it is not** — deliberately, and for good: no accounts, login or
authentication; no cloud sync, remote access over the Internet or cloud
generation; no plugin marketplace or SDK; no workflow or node-graph editor; no
gateway that guesses a workflow's inputs at run time; no AI prompt enhancer or
embedded LLM; no database-backed history or server-side media library; no
multi-user support; no Kubernetes; no iOS app and no web front end.

## Screenshots

| On a phone | Unfolded |
| --- | --- |
| <img src="docs/assets/screenshot-phone-generating.jpg" alt="The app on a phone: a workflow picked, a prompt typed, a generation running" width="260"> | <img src="docs/assets/screenshot-unfolded-result.jpg" alt="The app on an unfolded foldable: the form on the left, the finished picture on the right" width="420"> |

<img src="docs/assets/screenshot-unfolded-ready.jpg" alt="The same two-pane layout before a generation has been started" width="420">

## Requirements

- **Windows 10 or 11.**
- **ComfyUI, already working.** No ComfyUI yet? The optional
  [Minimal bootstrap](docs/user-guide.md#1-install) installs one — it downloads
  no models and builds no Python environment.
- **PowerShell 7 or newer** (`pwsh`). Windows PowerShell 5.1 is not supported.
  `LocalCanvas.exe` runs first-time setup for you in a PowerShell window it
  opens itself, so you do not have to open `pwsh` yourself for that step.
  `winget install --id Microsoft.PowerShell` if it is missing.
- **Python 3.10 – 3.13, already installed** (from
  <https://www.python.org/downloads/>). Setup builds LocalCanvas's own
  environment from the Python it finds.
- **Google Chrome or Microsoft Edge**, to convert workflows saved with ComfyUI's
  **Save**.
- **An Android phone** (Android 7.0 or newer) on the same network.
- Only to build the Android app yourself: **Flutter** and the **Android SDK**
  (see [Android app](#android-app)). The command-line path (below) needs no
  **git** either — the zip already has `scripts\` in it; `git` is only for
  cloning this repository instead of downloading a zip, or for building the
  app.

## Download

From this repository's **Releases** page (once one is published):

- **`LocalCanvas-0.2.0-windows-x64.zip`** — the Windows package. One
  self-contained `LocalCanvas.exe`; the machine that runs it needs no .NET
  installed.
- **`LocalCanvas-0.1.5-arm64-v8a.apk`** — the Android app. Unchanged in this
  release, and it works with this Gateway; see [Android app](#android-app).

## Quick start

1. Have ComfyUI running, on the PC you will run LocalCanvas on — unless you
   plan to tell setup to let LocalCanvas start it for you (step 4).
2. Download `LocalCanvas-0.2.0-windows-x64.zip` and extract it — anywhere, on
   that same PC.
3. Double-click `LocalCanvas.exe`, inside the extracted `LocalCanvas` folder.
4. First run asks to run setup — click **Run setup**. It opens a PowerShell
   window and asks two short questions (do you start ComfyUI yourself, and
   where is your ComfyUI folder); LocalCanvas continues on its own once it has
   finished, finds your workflows and offers to sync them.
5. Install the app on your phone — see [Android app](#android-app).
6. Right-click the new tray icon — on Windows 11 it may be under the hidden
   icons **^** arrow — and choose **Open status** for the address and a
   pairing QR code.
7. Open the app, scan the QR code (or type the address), pick a workflow, type
   a prompt, press **Generate**.

LocalCanvas now lives in the system tray. The [user guide](docs/user-guide.md)
walks through every step, the tray icon and menu, and what to do when
something goes wrong.

**Smart App Control.** `LocalCanvas.exe` is not code-signed. On a PC with
Smart App Control (a Windows Security setting) turned on, Windows blocks it
outright — there is no "Run anyway". The
[command-line path](docs/user-guide.md#14-advanced-command-line) runs fine
under Smart App Control, because it runs through Microsoft-signed `pwsh`.

## Daily use

Double-click `LocalCanvas.exe` again, or just leave it in the tray — a second
launch brings the first one's status window to the front instead of starting a
second copy. The tray icon tells you what is happening: a green check when
LocalCanvas is ready, an amber spinner while it starts, a red "x" if the
Gateway goes down. **Right-click** it for Restart Gateway, Sync workflows, Open
status and Exit; the [user guide](docs/user-guide.md#4-the-tray) has the full
menu and every icon.

Choosing **Exit** from the tray menu stops what LocalCanvas started; an
external ComfyUI it did not start is left running. If the icon shows a red
×, right-click it and choose **Restart Gateway**.

## Adding or changing workflows

1. Create or edit a workflow in ComfyUI and **Save** it (or **Export (API)** —
   both work).
2. Start LocalCanvas (or leave it running) with ComfyUI running (unless you
   chose to let LocalCanvas start it).
3. It reports a workflow change and offers **Sync now**. Or right-click the
   tray icon any time and choose **Sync workflows**.
4. If the app was already open and the workflow is not listed, tap
   **Refresh the list** (↻) at the top of **Choose a workflow**.

Nothing watches the folder in the background: changes are picked up on the next
start, on **Sync workflows**, or from the command line (the
[user guide](docs/user-guide.md#6-adding-or-updating-workflows) shows both).

A workflow LocalCanvas cannot read with confidence is held as `NEEDS_REVIEW`,
never guessed — the [user guide](docs/user-guide.md#6-adding-or-updating-workflows)
says what to do about one.

## Android app

**Get the APK.** Where this repository publishes one, download it from its
**Releases** page. Or build it yourself with Flutter and the Android SDK, from
`app/`:

```powershell
flutter pub get
flutter build apk --release --split-per-abi
```

Most phones want the `arm64-v8a` APK. Android will ask you to allow installing
from the app you opened it with — this is a sideload, not a store install. The
APK is debug-signed (a test-signed build), so uninstall LocalCanvas before
installing one built elsewhere. Details:
[user guide](docs/user-guide.md#5-connecting-your-phone).

**Connect.** Open **Open status** in the tray for the address and a pairing QR
code (the command-line path prints the same QR in its own window). Scan it,
type the address (`192.0.2.42`, `192.0.2.42:7801` or `http://192.0.2.42:7801` —
use your PC's own), or pick the PC from the list the app finds, where your
router allows discovery. More:
[Connecting your phone](docs/user-guide.md#5-connecting-your-phone).

**Windows Firewall.** The first time LocalCanvas starts the Gateway, Windows
may ask whether to allow it on the network: allow **Private networks** only.
The gateway has no login, so keep it on a trusted home network. If the phone
cannot reach the PC, the firewall is the usual reason.

## Privacy

No telemetry, no analytics, no crash reporting, no accounts, no cloud
generation. The app talks only to your gateway, and the gateway only to your
ComfyUI. The Windows tray launcher adds nothing to that: the only network calls
it makes on its own are loopback health checks against the Gateway and the
ComfyUI it is watching — started by it or not. This is a promise about
LocalCanvas's own code, **not about third-party ComfyUI custom nodes**, which
can do whatever their authors wrote — see [SECURITY.md](SECURITY.md).

## Known limitations

- The PC side is **Windows only**.
- `LocalCanvas.exe` is unsigned; a PC with Smart App Control on blocks it and
  needs the command-line path instead (see Quick start above).
- The maintainer has tested pairing and generation by hand on one foldable
  phone over Wi-Fi against a real ComfyUI. Nothing automated covers that path.
- Uploading a picture or clip has not yet been confirmed working from a phone.
- Prompt translation, and discovery (mDNS) reaching a phone, have only been
  exercised against fakes.
- A workflow held as `NEEDS_REVIEW` needs a person to decide what to expose.

More on what has been tested: [user guide](docs/user-guide.md#1-install).
Something not working? See
[When something is wrong](docs/user-guide.md#13-when-something-is-wrong).

## More

- [User guide](docs/user-guide.md) — the full manual
  ([Русский](docs/user-guide.ru.md), [日本語](docs/user-guide.ja.md)).
- [Command line](docs/user-guide.md#14-advanced-command-line) — everything
  above without the tray, for scripting or a PC with no desktop session.
- [CONTRIBUTING.md](CONTRIBUTING.md) — running the tests.
- [SECURITY.md](SECURITY.md) — the security model and reporting a problem.
- [CHANGELOG.md](CHANGELOG.md) — what changed.
- [LICENSE](LICENSE) — MIT.
