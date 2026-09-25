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
| `LocalCanvas.Launcher/Shell/` | The tray shell: the icon, its menu, the dialogs and a placeholder status window, all rendering the view model. |
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
  failure; a script that outlives its timeout is left running, never ended.
- The Gateway and ComfyUI are probed every 5 seconds (2-second timeout, no
  proxy). Two failed Gateway probes in a row are *Gateway down*: detected
  within 2 × 5 s + 2 × 2 s of the Gateway going away. There is no automatic
  restart.
- When Windows signs out or shuts down, the launcher stops what LocalCanvas
  started through `stop.ps1`, holding the session for at most 25 seconds with
  the reason "Stopping LocalCanvas". Best effort: Windows may end it sooner.
- Log: `.runtime\launcher.log` (or under `LOCALCANVAS_RUNTIME_DIR`), capped at
  1 MB with one previous generation kept. Nothing is sent anywhere.
