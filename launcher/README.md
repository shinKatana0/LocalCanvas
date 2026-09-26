# LocalCanvas.exe — the Windows launcher

`LocalCanvas.exe` starts LocalCanvas and keeps it in the Windows system tray:
ComfyUI started or reused, the workflow folders checked, the Gateway started
and its health watched. It lives at the root of the LocalCanvas folder, beside
`scripts\`, and refuses to run anywhere else.

**It owns no process logic.** Every lifecycle action is a call of one of the
scripts through its machine interface (`docs/runtime.md`, "Machine
interface"): `start.ps1 -Component Comfy|Gateway`, `sync-workflows.ps1`,
`stop.ps1` and `status.ps1`, each with `-Json`. It never starts ComfyUI or the
Gateway itself, never stops a process, and never looks one up by name or
port. The one thing it does itself is read-only HTTP: the Gateway is healthy
only when `GET /api/v1/info` answers as LocalCanvas with the instance id the
start reported.

## Layout

| Path | What it is |
|---|---|
| `LocalCanvas.Launcher/Core/` | Everything with a decision in it, free of Windows Forms: the script runner, the health probe, the lifecycle controller and its `TrayViewModel`. |
| `LocalCanvas.Launcher/Shell/` | The tray shell: the state icons, the menu, the dialogs and the status window, all rendering the view model, plus two small OS conveniences (opening the logs folder, the shutdown-block window) that touch no lifecycle logic. |
| `LocalCanvas.Launcher/Resources/Icons/` | The `.ico` files the tray, the status window and the exe itself use -- generated, not drawn by hand; see `launcher/tools/generate-icons.ps1`. |
| `LocalCanvas.Launcher.Tests/` | xUnit tests: the controller against a fake runtime, the health probe against real loopback listeners, the script runner against real PowerShell 7, two real launches, and end-to-end runs on the real scripts with their stub Gateway and ComfyUI. |

## Build, test, publish

Requires the .NET 10 SDK. From the repository root:

```powershell
dotnet test launcher\LocalCanvas.Launcher.sln
dotnet publish launcher\LocalCanvas.Launcher -p:PublishProfile=win-x64
```

The publish output is one self-contained `LocalCanvas.exe` under
`launcher\LocalCanvas.Launcher\bin\publish\win-x64\`; the machine that runs it
needs no .NET installed.

The end-to-end tests need PowerShell 7 and a Python 3.10–3.13 for the stubs:
`LOCALCANVAS_TEST_PYTHON`, or whatever `py -3.10` (…`-3.13`) names. Without
them those tests are skipped and say what was not verified. The two-launch
test is skipped when a LocalCanvas launcher is already running in the session.
Tests use ephemeral loopback ports only.

**Developer option:** `LocalCanvas.exe --root <folder>` runs a build against
another LocalCanvas folder — a checkout, from the build output directory. The
folder must contain `scripts\start.ps1`. It is not a user setting.

## Behaviour worth knowing

- One launcher per Windows session (mutex `Local\LocalCanvas.Launcher`). A
  second launch asks the first to open its status window and ends without
  running any script.
- Script calls run with no window, standard input closed, one at a time. A
  timeout, a crash or anything but one JSON document on standard output is a
  failure. A script that outlives its timeout is never ended: the launcher
  waits a further grace period (for a start, the configured startup timeout)
  for it to end by itself, and runs nothing beside it while it is running --
  in particular never `stop.ps1`, which would find absent what the start is
  about to create.
- The Gateway and ComfyUI are probed every 5 seconds (2-second timeout, no
  proxy). Two failed Gateway probes in a row are *Gateway down*: detected
  within 2 × (5 s + 2 s) = 14 s of the Gateway going away, since the wait
  starts after each probe ends and a failed probe may use its whole timeout.
  There is no automatic restart.
- When Windows signs out or shuts down, the launcher stops what LocalCanvas
  started through `stop.ps1`, holding the session for at most 45 seconds. It
  registers the shutdown block reason "Stopping LocalCanvas" for that time, so
  Windows shows it and waits for the user rather than ending the launcher
  after its usual few seconds. A script call still running at that moment is
  waited for first; the time kept back for `stop.ps1` and `status.ps1` is 1.5
  times what they last took in this session (at least 10 s, at most two thirds
  of the budget). If the call is still running then, nothing is stopped
  beside it. Either way `status.ps1` then confirms what is still running, and
  the log says exactly that -- including, when it could not finish in time,
  that nothing was confirmed. Best effort: the user can end the session sooner.
- An Exit asked for while a script call is still running waits for it, and the
  tray says "Exiting…" from the moment it is asked.
- An exit is reported as complete only when `stop.ps1` accounted for both the
  Gateway and ComfyUI, or when `status.ps1` confirmed it; otherwise the user is
  told what is, or may still be, running.
- Log: `.runtime\launcher.log` (or under `LOCALCANVAS_RUNTIME_DIR`), capped at
  1 MB with one previous generation kept. Nothing is sent anywhere.
- The tray icon is told apart by shape as well as colour, not only colour: a
  green disc with a check (Ready), an amber disc with a spinner arc (Starting,
  Restarting), an amber disc with two circular arrows (Syncing), an
  amber/yellow triangle with "!" (Attention), a red disc with "x" (Gateway
  down, and a startup Failure -- both mean the phone cannot use LocalCanvas
  right now), and a plain grey disc (Stopping). Restart Gateway is shown bold
  in the tray menu while the Gateway is down. One balloon is shown on
  entering the Gateway-down state, not on every failed health poll after it.
- The status window shows the Gateway's published endpoint with a Copy
  address button and a pairing QR image, generated on demand by the gateway
  package's own `qr` command run hidden through the same PowerShell seam as
  the configuration read above; a QR that could not be produced falls back to
  the address on its own. Restart Gateway appears there only while the
  Gateway is down. Open logs folder opens `.runtime` in Explorer through the
  shell's own `ShellExecute` -- not a process LocalCanvas has to account for.
