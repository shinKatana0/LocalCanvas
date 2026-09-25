# Runtime orchestration contract

`scripts/start.ps1` is a **runtime orchestrator**, not a gateway launcher. It is
the one command a user runs.

## Configuration

Real configuration: `config/local/runtime.yaml` — **gitignored**.
Public template: `config/examples/runtime.example.yaml`.

Typed fields for everything common — including `workflows.registry`, the root
the workflow registry loads from (`docs/workflow-schema.md`); `extra_args` only
for additional ComfyUI CLI arguments. Paths containing spaces must work — quote
every interpolated path in PowerShell, and never build a command line by naive
string concatenation.

No original-developer path may appear as a default, an example or a fallback.
Startup fails with a clear message when required configuration is missing; it
never guesses a ComfyUI location, and it never searches the machine for one.

## Python environments

Two Python environments exist on this kind of machine and they are **not
interchangeable**. Conflating them is how a working ComfyUI gets broken by
someone installing a gateway dependency.

| Environment | Owner | Contents |
|---|---|---|
| ComfyUI's Python | the **user** | ComfyUI and its custom nodes. Often an embedded/portable build. |
| `.venv/` at the repo root | **LocalCanvas** | the gateway's dependencies, and nothing else. |

Rules:

- The gateway runs from its **own project-local virtual environment**, `.venv/`,
  created by LocalCanvas's own setup.
- **Gateway dependencies are never installed into ComfyUI's Python** — not into
  an embedded interpreter, not into a portable build, not "just this once".
  The user's ComfyUI environment is theirs, and LocalCanvas does not write to it.
- The two environments stay independent. Neither is on the other's path, and
  neither imports from the other. LocalCanvas talks to ComfyUI over HTTP, which
  is the only coupling there is.
- `.venv/` is gitignored.

### Interpreter selection must be explicit and observable

A Windows machine commonly has several Python installations, and `py` resolves
to the **newest installed** version rather than a supported one. That is exactly
how a script silently builds an environment on an interpreter nobody intended.

- **Do not casually rely on bare `py`** (or bare `python`) to pick an
  interpreter when several are installed. `py` resolves to the newest installed
  version, which is not necessarily a supported one.
- Interpreter selection is explicit: once `.venv/` exists, scripts invoke
  `.venv\Scripts\python.exe` **directly** — never a bare `python`, never `py`,
  never an activated-shell assumption.
- Creating `.venv/` selects its base interpreter deliberately — a configured
  path, or an explicit `py -3.x` version selector — and never silently accepts
  whatever answers first.
- **Setup and startup print the interpreter path and version actually in use.**
  A version mismatch should be visible in the terminal, not discovered later
  from an import error.
- `doctor.ps1` reports the same, and reports when `.venv/` is missing, broken,
  or built on an unsupported version.

### Supported Python versions

**Python 3.10 through 3.13** — `requires-python = ">=3.10,<3.14"`, declared in
one place, `gateway/pyproject.toml`, and stated in the README. It was chosen from
the actual compatibility of the gateway's real dependency set: FastAPI, uvicorn,
httpx, websockets, zeroconf, segno and PyYAML all support 3.10, so nothing forced
the floor up.

The two constraints that shaped it, kept here because they bind any future
change to the range: it is a **conservative range, not one pinned patch
version** — a public project that demands an exact patch release is broken for
everyone else; and it **includes Python 3.10** unless a concrete dependency
proves otherwise, in which case that dependency and the reason are named rather
than the floor being raised quietly. The ceiling is honesty rather than policy:
nothing has been run on 3.14. Raise it once the suite has passed there.

`setup.ps1` builds `.venv/` on the **floor** of the range by default — it tries
explicit `py -3.x` selectors lowest-supported-first — so the floor is a tested
guarantee rather than a claim.

## Two modes

### Managed — `runtime.manage_comfy: true`

1. Load `config/local/runtime.yaml`; report clearly if absent or invalid.
2. Probe the configured ComfyUI endpoint for health.
3. **If already healthy, reuse it** — do not launch a second instance, and do
   not take ownership of it.
4. Otherwise build the launch command from `comfy.root`, `comfy.launcher.*`
   and `comfy.extra_args`.
5. Launch ComfyUI.
6. Record the PID in `.runtime/comfy.pid` — **only because LocalCanvas started
   it**.
7. Wait for readiness with a **real HTTP probe** against ComfyUI, polling until
   `startup.comfy_timeout_seconds`.
8. **A fixed sleep is never the readiness contract.** Not as a substitute, not
   as a supplement that masks a failing probe.
9. On timeout: fail clearly, stating the endpoint probed and the timeout used,
   and stop — no gateway is started.
10. **Check the configured workflow sources, cheaply**: classify them
    new / changed / removed from their content, converting nothing, writing
    nothing and contacting ComfyUI for nothing. Skipped entirely with
    `-SkipWorkflowCheck`, and not an error when no source list is configured.
    A workflow saved in ComfyUI's **editor** format (what **Save** writes) is
    counted exactly like an API export: **new** when the inventory does not
    know it, **changed** when its content differs from what the inventory
    recorded, and not reported at all when the last sync imported that same
    content — including a byte-identical copy the last sync recorded as an
    alias of it. One whose last conversion could not even be attempted, for a
    reason that was not the file's (no browser, ComfyUI or its frontend not
    ready, or a sync with no ComfyUI to ask), is **offered again** as
    `N not converted last time`, with the same question. It is counted as
    needing a look only while the last sync could not import it because of the
    file itself (ComfyUI refused that graph, or its converted graph could not
    be read with confidence) and the file has not changed since; that line
    names `pwsh .\scripts\sync-workflows.ps1` as the command that imports it.
    The check decides all of this from the inventory alone; the conversion
    itself happens only in a sync.
11. **Sync only if that was asked for**: the question `Sync workflows now?
    [Y/n]` at a genuinely interactive session, `-SyncWorkflows` in advance, and
    **never** on a session that cannot be asked — which is told what changed,
    given the command, and started on the catalogue it already has. A sync runs
    the existing `sync-workflows.ps1` pipeline — the same importer, converting
    editor-format workflows through the running ComfyUI and an installed
    Chrome or Edge — and its *attention* code is not a failure: a workflow that
    could not be converted is reported with its reason and what to do,
    `pwsh .\scripts\sync-workflows.ps1` is named as the way to try again, and
    LocalCanvas starts on everything else.
12. Start the gateway only after ComfyUI is ready.
13. Wait for gateway readiness (`GET /api/v1/info`) up to
    `startup.gateway_timeout_seconds`; record `.runtime/gateway.pid`.
14. Publish the mDNS service.
15. Make QR pairing available.
16. Print the final endpoint.

Steps 10 and 11 come **after** ComfyUI and **before** the gateway, and both
halves of that are the design: converting an editor-format workflow needs a
running ComfyUI, and the gateway reads the catalogue once when it starts, so a
sync accepted here is in place before it does.

### External — `runtime.manage_comfy: false`

1. **Never launch ComfyUI, and never terminate one LocalCanvas did not start.**
   No PID is recorded for an external backend. One carve-out, and only one: a
   record left by an *earlier managed run* is kept and honoured, so a ComfyUI
   LocalCanvas itself started can still be stopped after the user switches modes.
   The alternative is orphaning it forever. The gate is ownership proof, never
   the mode setting.
2. Verify the configured backend is reachable and usable.
3. **Check the workflow sources and optionally sync**, exactly as steps 10 and
   11 of the managed list: same cheap classification, same question, same
   refusal to sync a session that cannot be asked.
4. Start the gateway only when the backend is usable.
5. Fail cleanly when it is not, naming the endpoint that failed.

## The configuration seam

There is **one** definition of what `runtime.yaml` means, and it lives in the
gateway. The PowerShell scripts never parse YAML and never re-validate it.

The seam is a process boundary, not an import:

    .venv\Scripts\python.exe -m localcanvas_gateway config --config <path>

It prints the fully-loaded, validated, normalized configuration as a single JSON
document on stdout and exits 0. On failure it prints a human-readable message and
exits non-zero; the scripts render that message and stop.

Rules:

- **Required, never optional.** If the loader is missing or fails to import, that
  is a clear failure telling the user to run `setup.ps1` — never a fallback to a
  second reader. A fallback means two definitions of the configuration that drift
  apart, so the same file is accepted by one half and rejected by the other, with
  different messages. That has already happened once in this project.
- The scripts apply **no** defaults, no required-key checks and no type coercion
  of their own. Everything is decided on the Python side and arrives decided.
- A process boundary is chosen over importing the package so the scripts depend
  on a stable *document shape* rather than on Python class internals.

`sync-workflows.ps1` does not go through this command, and that is not an
exception to the rule: it reads a **second** configuration file,
`workflow-sources.yaml`, whose one definition lives in the gateway's sync engine
and is reached across the same kind of process boundary (see
[`sync-workflows.ps1`](#sync-workflowsps1) below). It parses no YAML either.

## Who owns the endpoint and the pairing block

Both halves can compute a LAN address, and two answers is one too many.

- **`start.ps1` decides the endpoint** and passes it down as
  `--endpoint <url>`. The gateway advertises and encodes exactly what it is
  given and never guesses its own address.
- **`start.ps1` owns the terminal block** shown below — it is printed once, by
  the script, after the gateway is ready.
- The gateway performs the mechanics: it publishes mDNS for the life of the
  process, and renders the QR on request
  (`python -m localcanvas_gateway qr --endpoint <url>`). It does not print its
  own copy of the readiness block when started by `start.ps1`.

## Process ownership

**Never kill by name.** Not `python.exe`, not "a ComfyUI process", not "a
process on port 8188". A user's other Python work is not ours to end.

    .runtime/          (gitignored)
      comfy.pid        written ONLY when LocalCanvas launched ComfyUI itself
      gateway.pid      written ONLY when LocalCanvas launched the gateway

A PID file alone is not proof of ownership — PIDs are reused. Record enough
alongside it to verify identity before signalling (process start time, and the
image path), and treat a mismatch as "not ours" and leave it alone.

**The identity is read from the process itself**, by PID, through
`Win32_Process` (its executable path, command line and creation time) — never
from `.Path` or `MainModule.FileName`, which resolve through the main module and
were measured returning `ntdll.dll` for a ComfyUI that had been serving for
minutes. A wrong answer is worse than none, because it is acted upon.

**What happens to the record** depends on what the evidence proves:

- **mismatch** — the PID is worn by a *different* executable. Proved not ours:
  the process is left alone, and the record, which describes a process that is
  gone, is removed.
- **unproven** — the identity could not be read, none was recorded, or the start
  times disagree. *Not proved* ours: the process is left alone **and the record
  is kept.** Deleting it is what turned "owned but unverifiable" into "unowned
  forever" and leaked a running ComfyUI.

`stop.ps1` stops only owned processes and then clears their PID files. **If
ComfyUI was reused rather than launched, `stop.ps1` leaves it running** and says
so. A stale PID file for a process that no longer exists is cleaned up quietly.

## Scripts

| Script | Contract |
|---|---|
| `start.ps1` | The orchestration above. |
| `stop.ps1` | Stop only owned processes; leave a reused ComfyUI running. |
| `status.ps1` | What is running, what LocalCanvas owns, ComfyUI health, gateway health, the endpoint. Read-only. |
| `doctor.ps1` | Diagnose before things go wrong: config present and parseable, the gateway virtualenv and its interpreter, ComfyUI path/launcher exist, ports free or held by us, gateway reachable, LAN address detected, mDNS working, firewall posture, ComfyUI binding, strict-LAN state (`docs/privacy-security.md`). Read-only, changes nothing. |
| `sync-workflows.ps1` | Read the workflow folders named in `config/local/workflow-sources.yaml`, and write a definition for each workflow that can be imported. Source files are only ever read. `-DryRun` writes nothing. Never starts ComfyUI or the gateway. Contract below. |
| `strict-lan.ps1` | `enable` / `status` / `verify` / `disable`. Machine-level Windows firewall enforcement of LAN-only operation, reversible and never silent. Full contract in `docs/privacy-security.md`. |

**`doctor.ps1`'s exit code agrees with its body**, with the same three
codes as `comfy/doctor.ps1`: **0** when every check it could make came back clean,
**2** when nothing failed but at least one check could not be made **or came back
with a warning worth acting on**, **3** when something failed. A check that can only be made from an elevated shell — reading
the firewall's port filters — and was run unelevated is reported on its own line
as *not measured, needs Administrator* and does **not** turn a clean run into a 2:
running unelevated is the documented way to run it.
One case keeps the project-wide rule instead: a configuration that is missing or
cannot be loaded exits **2**, as every script does, although it prints a failure
line — nothing after it could be checked, so no check was made.

`doctor.ps1` and `status.ps1` are read-only in the strict sense: they start
nothing, write no file, and do not create `.runtime/` in order to report on it.

Every `strict-lan.ps1` subcommand takes **`-Plan`**, which prints exactly what
it would change and changes nothing — that is the form to read first, and the
form the tests drive. The rule set itself is computed by a pure function of the
configuration document and this machine's addresses, routes and resolvers
(`scripts/lib/StrictLan.ps1`), separately from the thin shim that applies it, so
the decision can be tested exhaustively without a rule ever existing. `-Json`
prints the same as one document; `-FactsFile` plans against a *described
machine* rather than this one -- its interfaces, gateways, resolvers and,
optionally, the LocalCanvas rules it already carries (`owned_rules`, which
decides the reported state) -- and such a plan is never applied.

### `sync-workflows.ps1`

A thin front end. It resolves the interpreter (`.venv\Scripts\python.exe`, or
`-PythonExe`), runs the gateway's sync engine and renders the one JSON document
it prints:

    <python> -m localcanvas_gateway.workflows sync --config <path> --runtime-config <path> [--dry-run] [--no-convert] [--regenerate-labels]

**Two configuration files, and neither is read in PowerShell.**

- `config/local/workflow-sources.yaml` (`-Config`; template
  `config/examples/workflow-sources.example.yaml`) is the script's own: which
  folders to read and where to write. Its one reader is the engine
  (`localcanvas_gateway/workflows/sync/config.py`), not `Read-LcConfig`, which
  is `runtime.yaml`'s seam.
- `config/local/runtime.yaml` is always passed — the repository's own, unless
  `-RuntimeConfig` names another — and the engine reads it through the
  gateway's own configuration loader for one value only: the ComfyUI address an editor-format workflow is converted through. A missing
  or unloadable `runtime.yaml` is not an error here — conversion is simply not
  offered, and every editor-format workflow is reported as `NEEDS_API_EXPORT`.

**Relative output paths are measured from a root derived from where the
configuration file is**, never from the current directory: the directory two
levels above the file, so `<repo>/config/local/workflow-sources.yaml` gives
`<repo>`. That is a rule, not a search. It applies to `output.definitions`,
`output.imported_api` and `output.inventory`; a `sources` path must be absolute.
The engine accepts `--repo-root PATH` to override the root for anyone driving it
directly; the script never passes it. Because `sync` is read as a subcommand of
`python -m localcanvas_gateway.workflows`, a registry root literally named
`sync` is given to the offline validator as `./sync`.

**`-DryRun` writes nothing** — no inventory, no definition, no imported graph, no
remembered conversion — but it does ask ComfyUI to convert editor-format
workflows, so that it can say what would import. `-NoConvert` asks ComfyUI
nothing. The script never starts ComfyUI or the gateway; a conversion launches
an already-installed browser, which the engine closes when the run ends
(`docs/privacy-security.md`).

**Every workflow ends a run in exactly one of nine states.** Five need attention —
`INVALID`, `NEEDS_API_EXPORT`, `NEEDS_REVIEW`, `UNSUPPORTED_INPUT`,
`REMOVED_FROM_SOURCE` — and four are normal outcomes: `NEW`, `CHANGED`,
`UNCHANGED`, `EXACT_DUPLICATE`. A graph the engine cannot read with confidence
is `NEEDS_REVIEW`, with a sentence naming the node and input, and gets no
definition; there is no override that imports it anyway.

**A run that converts nothing still says what the inventory knows about each
editor-format workflow.** Under `--no-convert` every such workflow stays
`NEEDS_API_EXPORT`, exactly as before; beside the states, the report's
`unconverted_editor` block counts them as `new` (not in the inventory),
`changed` (matched only by its path), `unchanged` (the same content, recorded
with an importable state — the last sync imported it), `retry` (the same
content, recorded `NEEDS_API_EXPORT` with a conversion status of `unavailable`
— the bridge could not run at all — or with no conversion record, because that
sync had no ComfyUI to ask) or `attention` (the same content, recorded as
anything else: `failed`, which is ComfyUI refusing that graph, `NEEDS_REVIEW`,
or an entry carried forward as removed). A file no entry claims is also looked
up among the entries' `aliases` by content, so a byte-identical copy the last
sync recorded as an `EXACT_DUPLICATE` is judged by the entry it is an alias
of; an *edited* copy stays `new`, which is what the next sync calls it. It is
what `start.ps1`'s check counts a canvas by — `retry` is offered like `new`
and `changed` — and it needs nothing new in the inventory: `state`,
`conversion` and `aliases` are in every entry already, so an inventory written
before it existed is read as it stands. An entry from before conversion
existed has no conversion record, so a canvas it recorded as `NEEDS_API_EXPORT`
is `retry`. A run that had a bridge reports only zeroes, because every
editor-format workflow in it was asked about and its state says what happened.

**An `UNCHANGED` workflow's definition is written again when this importer now
reads the workflow differently** — decided by a fingerprint, recorded in the
inventory, of the definition the importer generates on its own — and is left
byte for byte as it is otherwise. The rewrite keeps the definition's name,
presentation, translation setting and every field label and help line a curator
wrote, generates everything else from the workflow again, and leaves the
workflow `UNCHANGED`; the summary line counts every definition a run wrote. A run
that has no answer from ComfyUI about what its inputs accept (`-NoConvert`, or
ComfyUI unreachable) never rewrites one the inventory records as generated with
that answer; a definition with no such record at all (an inventory from before
the record existed) is kept by such a run too when the catalogue holds an
editor-format workflow, since that run would otherwise have had the answer.

**`-RegenerateLabels` (`--regenerate-labels`) is how the generated field labels,
help lines and presentation are brought back.** A run given it writes every
importable definition with each field's label and help line, and every
presentation key the importer generates, generated afresh, replacing the ones a
curator wrote, and records what it generated, so the next run without it writes
nothing. The name, the translation setting and any presentation key the
importer never generates (`category`, `not_ideal_for`) are kept as always. Each
definition's report lists, verbatim, every label, help line and presentation key
it replaced that a run without the flag would have kept, and the summary line
counts them; one nobody changed follows the generator on any run and is not in
that list. With `-DryRun` nothing is written or
recorded and the report says what would be replaced. The keep described above
for a run with no answer from ComfyUI still applies, and the report says so.
Deleting `workflow-inventory.json` is not the way to force this: a definition
with no record keeps every label, help line and presentation key in it.

**Exit codes:**

- **0** — the sync ran and no workflow needs attention;
- **3** — the sync ran and at least one workflow is in one of the five attention
  states. The engine itself exits 1 here; the script reports it as 3;
- **2** — the run could not happen: the interpreter was not found, or the engine
  exited 2 — the sources configuration is missing or invalid, a source folder
  cannot be read, two source folders overlap, an output path lies inside a source
  folder, or the inventory could not be written. The engine's own `[FAIL]` lines
  are printed as it wrote them;
- **1** — something unexpected: the engine exited with any other code, printed
  nothing, or printed something that is not a JSON document, or the script
  itself failed.

## Machine interface

The scripts are also driven by a program -- a launcher that runs them with no
window and standard input from the null device, and acts on their exit codes
and on one JSON document each prints. **A launcher owns no process logic: it
never starts, stops or signals a LocalCanvas process itself.** Everything it
needs is here, with the ownership rules above unchanged -- PID, start time and
image path; stop by exact PID; an external or reused ComfyUI is never stopped;
an `unproven` record is kept; never by name, never by port.

### `-Component`

| Script | `-Component` | Does |
|---|---|---|
| `start.ps1` | `All` (default) | Everything in "Two modes", exactly as without the switch. |
| `start.ps1` | `Comfy` | The configuration and the ComfyUI step only: external verify, or managed reuse / launch with its ownership record. No workflow check, no gateway. |
| `start.ps1` | `Gateway` | The configuration and the gateway step only. ComfyUI is neither probed nor required, its record is not read, and no workflow check runs. |
| `stop.ps1` | `All` (default) | Both roles, exactly as without the switch. |
| `stop.ps1` | `Gateway` | The gateway role only. The ComfyUI record is neither read nor touched. |

`-SyncWorkflows` and `-SkipWorkflowCheck` stay valid with `All` and are refused
with `Comfy` or `Gateway` -- exit **2**, as two contradictory switches are.

So the launcher's flows are: daily start `start.ps1 -Component Comfy` →
`sync-workflows.ps1 -DryRun -NoConvert` (the cheap check) → a sync only if the
user agrees → `start.ps1 -Component Gateway`; *restart the gateway* is
`stop.ps1 -Component Gateway` then `start.ps1 -Component Gateway` (the gateway
reads the catalogue once, at start); exit is `stop.ps1`.

### Gateway instance identity

Every gateway `start.ps1` launches is given a fresh **instance id** -- 128 bits
from the operating system's CSPRNG, written as 32 lowercase hex digits -- as
`--instance-id <id>`, and echoes it as `instance_id` in `GET /api/v1/info`
(`docs/api.md`). The gateway's ownership record carries it, with the endpoint
the gateway was told to publish: `instance_id`, `published_endpoint`, `is_lan`
and `local_only_reason`, added after the fields above. They are additive: a
record written before they existed still loads, and still proves ownership for
a stop.

### Readiness is identity-verified

"Something answers `/api/v1/info` as LocalCanvas" says a LocalCanvas gateway is
on the port, not that it is the one this run started. So:

- **Before launching**, the gateway port is checked on the probe host. If
  anything answers HTTP there at all, or the port accepts a TCP connection,
  nothing is launched: exit **5**, `Port <N> is already in use`, saying when the
  answer is another LocalCanvas gateway's and naming the fix -- stop it
  (`stop.ps1 -Component Gateway`, if LocalCanvas started it) or change
  `gateway.port`. The process on the port is never looked up and never touched.
- **Ready** means a 2xx `/api/v1/info` that identifies as LocalCanvas, carries
  *this* instance id, and arrives while the process this run started has not
  exited -- the exit is checked after each probe and before its answer is
  trusted. A LocalCanvas answer with another id is not ready. On a timeout, or
  when the child exits, the child is stopped by its PID, its record removed,
  and the exit is **5**, as before.
- **Reuse.** A gateway whose record is `running` is reused only when its
  `/api/v1/info` answers with the instance id its record carries. A record
  with no instance id (written before them) or one that does not answer with
  it is reported and not reused; nothing is stopped, the record is kept, and
  the start goes on to the port check -- which refuses while that gateway
  holds the port. A proven-ours gateway that is still running is never
  replaced by a second launch, because that would overwrite the only record
  that lets `stop.ps1` stop it.

The check and the launch are two steps, so a port can still be taken between
them; the identity check is what closes that window -- a gateway that loses
the bind exits, and an answer from whatever won it does not carry our id.

### `-Json`

`start.ps1`, `stop.ps1`, `status.ps1` and `sync-workflows.ps1` take `-Json`.
Standard output then carries **exactly one JSON document and nothing else**:
one line, UTF-8 without a byte-order mark (non-ASCII characters are written as
`\u` escapes, so the bytes are ASCII whatever the console's code page). Every
human line -- the same lines as without the switch -- goes to standard error,
where a caller can keep it as details. Exit codes are unchanged, and a
document is printed on every exit path. Nobody is asked anything: a `-Json`
start syncs only with `-SyncWorkflows`, and otherwise reports the change.

Every document carries:

| Key | Value |
|---|---|
| `result_version` | `1` |
| `ok` | `true` when the script did its job |
| `exit_code` | the process exit code |
| `error` | `null`, or `{"what", "detail", "fix"}` -- the failure the script reported, in its own words; `detail` is one string, lines joined with `\n`, or `null` |

and then, per script:

- **`start.ps1`** -- `component`; `comfy`: `{status: ready|unreachable|failed|skipped,
  url, ownership: owned|reused|external|none, pid}`; `gateway`: `{status:
  ready|reused|failed|skipped, probe_url, instance_id, pid, published_endpoint,
  is_lan, local_only_reason}`; `workflows` (`null` unless `-Component All`):
  `{status: checked|failed|skipped|not_configured|not_reached}` and, for a check
  that ran or failed, its fields -- `ok`, `new`, `changed`, `retry`, `removed`,
  `unchanged`, `attention`, `total`, `changes`, `elapsed_ms`, `what`, `detail`,
  `fix` -- and `sync: {answer: yes|no|unasked|not_needed, exit_code,
  definitions_written}`. `ok` is `exit_code == 0`.
- **`stop.ps1`** -- `component`; `roles.gateway` and `roles.comfy`, each
  `{state_before, action, result, pid}`: `state_before` is the
  `Resolve-LcOwnedProcess` state (`none`, `stale`, `unreadable`, `mismatch`,
  `unproven`, `running`); `action` is `none`, `record_removed`, `record_kept` or
  `stop`, and `skipped` for a role this run does not handle; `result` is
  `Stop-LcOwnedProcess`'s outcome (`exited`, `terminated`, `still-running`) for
  a stop, else `null`.
- **`status.ps1`** -- still strictly read-only, and the document creates
  nothing: `config_ok`, `mode` (`managed`|`external`), `comfy: {url, healthy,
  ownership}`, `gateway: {probe_url, reachable, identity: localcanvas|foreign|none,
  instance_id, instance_matches_record, ownership, pid, published_endpoint}`.
  `ownership` is the `Resolve-LcOwnedProcess` state; `instance_matches_record`
  is `null` unless both the answer and the record carry an id;
  `published_endpoint` is the record's when there is one.
- **`sync-workflows.ps1`** -- compact, never the engine's whole report:
  `dry_run`, `no_convert`, `counts` and `unconverted_editor` (the engine's),
  `changes`, `attention`, `new`, `changed`, `retry`, `removed` -- computed by
  the same code as `start.ps1`'s check, so the two never disagree --
  `attention_items` (`{id, state, reason}`, the reason's first line, at most
  50), `attention_items_total`, `definitions_written` and `summary` (the
  engine's line). `ok` is `true` for exit 0 and for exit 3, where the sync ran
  and some workflows need a look.

## Startup output

Concise and polished. Target shape:

    LocalCanvas

    [INFO] Configuration loaded

    [INFO] Starting ComfyUI...
    [ OK ] ComfyUI ready at http://127.0.0.1:8188

    [ OK ] Workflows: unchanged - nothing new and nothing edited
           12 workflow file(s) checked in 740 ms; nothing was converted and
           nothing was written.

    [INFO] Starting LocalCanvas Gateway...
    [ OK ] Gateway ready

    [ OK ] LocalCanvas is ready

           Endpoint:
           http://<your-PC-address>:7801

           Discovery:
           mDNS active

           QR pairing:
           available

           ComfyUI:
           localhost only

When ComfyUI was reused, say so instead of claiming to have started it. The
workflow line is one of four: unchanged (above), a one-line
`New / Changed / Removed` summary with or without the question that follows it,
`not checked (-SkipWorkflowCheck)`, or `no folder is configured yet`.

**`start.ps1`'s exit codes.**

| Exit | Meaning |
|---|---|
| **0** | LocalCanvas is ready. |
| **1** | Unexpected — anything this contract does not name. |
| **2** | The configuration could not be loaded, or two switches contradict each other. |
| **3** | Managed ComfyUI could not be started or did not become ready. |
| **4** | An external ComfyUI is not reachable. |
| **5** | The gateway could not be started or did not become ready. |
| **6** | The workflow layer could not be established **and** there is no catalogue to fall back on. No gateway is started. |

**6 is deliberately not 2 or 3**: a broken workflow layer is neither a broken
configuration nor a backend that is down, and a script keyed on the difference
has to be able to tell them apart. A workflow layer that fails *with* a usable
catalogue is not an exit code at all — it reports, keeps every definition as it
was, and starts.

## Failure output

**A raw PowerShell stack trace is never the primary failure UX.** A failure
states what was being attempted, what actually happened, and the one most likely
fix:

    [FAIL] ComfyUI did not become ready within 120s
           Probed: http://127.0.0.1:8188
           ComfyUI was started by LocalCanvas (PID 18244) and is still running.
           Check its console output, or raise startup.comfy_timeout_seconds.

Full diagnostics may go to a log file for the curious; the terminal gets the
human-readable version.
