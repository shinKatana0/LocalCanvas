# LocalCanvas gateway

The PC-side half of LocalCanvas: the HTTP API the Android app talks to
([`docs/api.md`](../docs/api.md)), the workflow registry behind it
([`docs/workflow-schema.md`](../docs/workflow-schema.md)), and the ComfyUI client
that does the generating.

    localcanvas_gateway/
      config.py      config/local/runtime.yaml, typed and validated
      workflows/     the workflow registry: load, validate, bind
      comfy/         ComfyUI's HTTP protocol and event socket -- and a fake of both
      jobs.py        the job store and its five states
      media.py       the temporary media store, and what a media_id binds to
      validation.py  submitted values against a workflow's field schema
      api/           the FastAPI app: nine endpoints, one error shape
      discovery.py   mDNS advertisement of _localcanvas._tcp
      pairing.py     the QR pairing payload, rendered for a terminal

**The gateway is the only component that knows ComfyUI exists.** Node ids, the
API-format graph, history lookup and output file locations stop here; the app
receives fields, never a graph.

## Environment

The gateway runs from LocalCanvas's own project-local `.venv/`, never ComfyUI's
Python ([`docs/runtime.md`](../docs/runtime.md)). Interpreter selection is
explicit — a Windows machine usually has several Pythons, and a bare `py` picks
the newest rather than a supported one.

`scripts\setup.ps1` is the supported way to build it — it selects the base
interpreter explicitly, prints what it got, and installs the gateway into
`.venv/` and nowhere else:

```powershell
.\scripts\setup.ps1 -Dev        # -Dev also installs the test extra
```

By hand, if you want a second environment or a particular interpreter:

```powershell
# From the repository root. Use the interpreter you mean, not whatever answers.
C:\Python310\python.exe -m venv .venv
.\.venv\Scripts\python.exe --version          # print what you actually got
.\.venv\Scripts\python.exe -m pip install .\gateway
.\.venv\Scripts\python.exe -m pip install pytest     # for the tests
```

Supported: Python **3.10 through 3.13** (`requires-python = ">=3.10,<3.14"`). The
floor is where development and testing happen, so it is a tested guarantee; the
ceiling is honesty rather than policy — nothing here has been run on 3.14, and on
Windows a bare `py` reaches for the newest interpreter installed, which is
exactly how an untested one gets picked. Raise it once the suite has passed
there.

Installing the package — rather than pointing `PYTHONPATH` at `gateway/` — is
what makes `python -m localcanvas_gateway` and the offline validator run from
anywhere.

### Dependencies, and why each one is here

| Package | Why |
|---|---|
| **fastapi**, **uvicorn** | the HTTP surface in `docs/api.md`, and the server that runs it |
| **python-multipart** | `POST /api/v1/media` is `multipart/form-data`; Starlette parses a form only when this is installed, so it is a hard requirement of that endpoint rather than an optional extra |
| **PyYAML** | `runtime.yaml` and workflow definitions are YAML |
| **httpx** | the ComfyUI client; also what FastAPI's `TestClient` uses, so the tests need no second HTTP library |
| **websockets** | both sides of `WS /api/v1/jobs/{id}/events` — uvicorn serves a socket only when an implementation is installed (without one `capabilities.events` would be a lie), and this is also the client that reads progress off ComfyUI's own socket, the only place ComfyUI reports it |
| **zeroconf** | mDNS advertisement of `_localcanvas._tcp` (`docs/connection.md`) |
| **segno** | QR pairing rendered locally. Pure Python, no dependencies of its own, and no image library needed to draw into a terminal — `docs/connection.md` forbids any hosted or external QR service |
| **pytest** | the tests, and nothing else. The only one that is an extra (`gateway[test]`); everything above is a runtime dependency |

## Running it

```powershell
.\.venv\Scripts\python.exe -m localcanvas_gateway --config config\local\runtime.yaml
```

| Flag | Meaning |
|---|---|
| `--config PATH` | **required.** The runtime configuration. Nothing is guessed when it is absent. |
| `--host`, `--port` | override the configured gateway bind address |
| `--endpoint URL` | the endpoint a phone should use; advertised over mDNS and encoded in the QR |
| `--no-mdns`, `--no-qr` | opt out of discovery or the printed QR |

It prints the interpreter path and version first, then what it loaded, then the
endpoint. Exit code `2` means the configuration or the workflow registry could
not be used; the message says which, and no traceback is printed at the user.

### Two subcommands, both seams for `scripts/*.ps1`

```powershell
.\.venv\Scripts\python.exe -m localcanvas_gateway config --config <path>
.\.venv\Scripts\python.exe -m localcanvas_gateway qr --endpoint <url>
```

`config` prints the fully-loaded, validated, normalized configuration as **one
JSON document on stdout** and exits 0; on failure it prints a human message on
stderr and exits non-zero. This is the configuration seam in
[`docs/runtime.md`](../docs/runtime.md): the PowerShell scripts never parse YAML
and never re-validate it, because two readers of one file drift apart and start
disagreeing about which files are valid. Every documented key is always present
— `null` rather than missing — paths are absolute, `comfy.base_url` is composed
here, and the launcher is already resolved against `comfy.root`. Nothing else is
ever written to stdout by that subcommand.

`qr` prints the pairing payload and its QR and exits, for a script that wants
the code without starting a server.

### Who prints the endpoint

`scripts/start.ps1` is the command a user actually runs, and
[`docs/runtime.md`](../docs/runtime.md) gives it both the endpoint and the
terminal block that shows it. **Passing `--endpoint` is therefore also how this
process is told it is not the one talking to the user:** given one, it publishes
mDNS and serves, and prints no Endpoint / Discovery / QR block of its own. Run
by hand without it, it works the endpoint out, prints the block and the QR, and
is the only thing on the screen.

## Tests

```powershell
.\.venv\Scripts\python.exe -m pytest gateway\tests
```

`gateway/conftest.py` puts `gateway/` on `sys.path`, so the tests run against
the source tree whether or not the package is installed.

Every ComfyUI-facing test runs against `localcanvas_gateway.comfy.fake`, a local
HTTP server that answers with ComfyUI's own response shapes. It lives in the
package rather than in `tests/` so that later cards and the runtime scripts can
point at it too. **No test needs a GPU, a model, or a real ComfyUI.**

## Validating a registry offline

A curator can check their definitions without starting a generation — nothing
in this package contacts ComfyUI or the network:

```powershell
# From anywhere, once the package is installed into .venv.
.\.venv\Scripts\python.exe -m localcanvas_gateway.workflows workflows\examples
```

Exit codes: `0` every definition is valid, `1` at least one was rejected (the
reasons are printed), `2` the registry root itself is unusable.

## What the API guarantees

- **No ComfyUI concept crosses the boundary.** No node id, node type or `bind`
  block appears in any response; the presentation and binding views are separate
  objects, so a leak takes a deliberate mistake rather than a forgotten filter.
- **No absolute URL names the gateway's own host.** Results are referenced by
  path (`/api/v1/jobs/{id}/result/{n}`), resolved by the client against its
  configured base endpoint (`docs/transport-boundary.md` §3).
- **`capabilities` is honest.** Each word is backed by an endpoint that does
  what it says: `media_upload` by `POST /api/v1/media` and a media field that
  really binds, `cancel` by `POST /api/v1/jobs/{id}/cancel`, `events` by
  `WS /api/v1/jobs/{id}/events`. The app hides an affordance rather than
  offering one that does nothing, so a word here is a promise.
- **The event stream is an optimization, never the source of truth.** Every
  message on `WS /api/v1/jobs/{id}/events` is a field of the snapshot that
  `GET /api/v1/jobs/{id}` already answers, sent earlier. Nothing is queued for
  a socket that is not there, no event is replayed on reconnect, and a client
  that never opens one misses nothing. Dropping every socket leaves a working
  product; a test proves it by tearing one down mid-generation and recovering
  the result, bytes included, from the snapshot alone.
- **A cancel request is not a cancelled outcome.** The endpoint reads before it
  acts, so a generation that finished first is reported as **completed, with
  its result**, and ComfyUI is not asked to stop anything. A prompt still
  waiting is removed with `POST /queue`, because ComfyUI's `/interrupt` stops
  only what is executing — and `/interrupt` is sent only after `/queue` has
  said the running slot holds this gateway's own prompt, so a cancel never
  stops somebody else's generation. What is reported afterwards is read back
  from `/history`, including the interrupt ComfyUI files under the same status
  string it uses for a crash and which is not one.
- **An uploaded file reaches ComfyUI over HTTP, never over the filesystem.**
  The gateway holds it in a temporary store of its own and hands it to
  ComfyUI's `POST /upload/image`, then binds the name *and subfolder ComfyUI
  answered with*. No ComfyUI input directory is configured, composed or
  searched for. The store is not a library: no listing endpoint, no permanent
  store, no gallery, and a file that has expired makes the job that references
  it fail with `media_expired`, attributed to the field, so the app can ask for
  it again.
- **What ComfyUI keeps is in one folder the user can empty.** ComfyUI offers no
  way to delete an input file, and LocalCanvas never writes to or deletes from
  a user's ComfyUI installation — so those copies accumulate. They are all
  asked into a single `localcanvas/` subfolder rather than scattered among the
  user's own inputs, which is what makes clearing them one action. Stated, not
  quietly true ([`docs/privacy-security.md`](../docs/privacy-security.md)).
- **The store's limits are configuration.** `media.max_image_megabytes`,
  `max_video_megabytes`, `max_store_megabytes` and `ttl_seconds` in
  `runtime.yaml`; the section is optional and absent means the shipped
  defaults, never "no limit". Nobody edits source to send a longer clip.
- **A result streams.** The output bytes pass through the gateway a chunk at a
  time and are never assembled in it, so serving a video costs no more memory
  than serving a thumbnail, and the ComfyUI read is given a budget sized for
  one.
- **No fabricated progress.** ComfyUI reports execution progress on its own
  WebSocket and nowhere else, so the gateway subscribes to it and passes the
  reported step count through unchanged. When that socket is absent, refuses,
  or says something unusable, `progress` is `null` — the documented answer for
  "no real progress". Nothing derives a percentage from elapsed time, from a
  queue position, or from a repaired pair of numbers.
- **An unknown `job_id` is a 404.** The job store is in-process, so a restart
  really does lose it, and saying so is what lets the app tell the user rather
  than showing a generation that will never finish (`docs/recovery.md`).
- **Errors are one shape**, `{error: {code, message, field}}`, with a message
  written for the person holding the phone. Tracebacks are logged on the PC and
  never returned — including for a failure nobody anticipated, which becomes a
  plain 500 in the same envelope.
- **A backend failure is translated, not forwarded.** ComfyUI's exception text
  reaches the app as a human sentence plus at most a short bounded reason. The
  path rule is exact: **no directory component ever crosses; a bare filename
  may** — `C:\Program Files\ComfyUI\models\sd xl.safetensors` becomes
  `sd xl.safetensors`, because the filename says *which* model is missing and
  the layout of someone's disk means nothing on a phone. Node class names go
  too, and a message carrying a stack trace contributes no reason at all — a
  custom node re-raising with `format_exc()` puts one where the `traceback`
  field never being read does not help. The whole of what ComfyUI said goes to
  the PC log, where someone can act on it.
- **`GET /api/v1/info` is cheap to poll.** Producing ComfyUI's `/object_info` is
  not cheap for ComfyUI — it walks every node class and enumerates model
  directories — so a `ready` answer is reused for a couple of seconds. Only
  `ready`: `starting` and `unavailable` are answers the user is waiting to see
  change.
- **Validation is field-attributed and happens first.** A value the schema
  rejects never reaches ComfyUI.

## What the registry guarantees

- **The registry root is configuration.** It comes from `workflows.registry` in
  `config/local/runtime.yaml`; no path is hardcoded anywhere in this package.
- **Deterministic order.** Workflows are sorted by `id` ascending in plain
  Unicode codepoint order — Python's default `str` comparison, never
  locale-aware collation, and never filesystem enumeration order. Diagnostics
  are sorted the same way, so two runs over one registry print the same bytes.
- **One broken workflow never takes the registry down.** A malformed or invalid
  definition is omitted with a diagnostic; every valid workflow still loads. An
  unreadable registry *root*, by contrast, raises `RegistryError`: a half-empty
  registry that looks successful is worse than a failure. An empty root is an
  empty registry, not an error.
- **Duplicate ids reject every claimant.** Two definitions claiming one `id`
  means both are rejected, with a diagnostic naming the id and the other files.
  Nothing is silently shadowed.
- **Node ids are strings.** ComfyUI's API format keys nodes as JSON strings and
  a YAML author will sometimes write `node: 76`; both name the same node.
- **The source graph is never mutated.** `bind_values()` deep-copies first, so
  two concurrent jobs against one workflow cannot see each other's values.
- **Two views, kept apart.** `summary_view()` / `detail_view()` are what the app
  may receive; node ids and `bind` blocks live in `bindings` and `graph` and
  stay gateway-side.

## What configuration guarantees

- **No ComfyUI location is ever guessed or searched for.** There is no default
  root and no "usual place". In managed mode the location is required and named;
  in external mode it is simply absent. `comfy.root` must be **absolute** —
  there is nothing a relative one could be measured from, and resolving it
  against a directory nobody named would be exactly the guess this rule forbids.
  (`workflows.registry` may be relative, because the repository root is its
  documented base.)
- **Errors name the file, the key and what was expected**, so a configuration
  mistake is fixable from the message alone.
- **An unknown key is an error, not a comment.** `manage_comfu: true` silently
  ignored would be a mode nobody chose; the message lists the accepted keys.
- **Paths with spaces are ordinary.** Nothing splits a configured path.

## Validation beyond the letter of the contract

`docs/workflow-schema.md` leaves a few choices open. Where it does, this
implementation takes the strict option, because a mistyped key that is silently
ignored becomes a field that quietly does nothing at generation time:

- unknown keys are rejected at the definition, `presentation`, field, `bind` and
  option level, and the diagnostic lists the allowed keys;
- two fields may not bind to the same node input;
- `default: null` is rejected — omit the key instead;
- a required field may not declare an empty default;
- a media field (`image`, `video`) may not declare a `default` at all: its value
  is an uploaded media reference, not a path;
- `workflow:` must be a path relative to the definition file, so a definition
  never carries an absolute machine-specific path;
- `bind.input` must name an input that holds a literal value. An input wired to
  another node's output (`["12", 0]` in the API format) is not bindable, and
  binding one would break the graph.

One rule is looser than the contract's wording rather than stricter: a select
option's `label` may be omitted, and then falls back to its `value`. A one-word
option does not need to be written twice.

Submitted **values** are checked against exactly the four rules `docs/api.md`
names — required, type, range, select membership. `step` is a control hint for
the numeric widget, not a constraint, so a value off its grid is not rejected.
