# Architecture contract

## Topology (v0.1)

    Android app  (Flutter)
        │  HTTP + WebSocket, LAN
        ▼
    LocalCanvas Gateway  (FastAPI, PC)
        │  HTTP + WebSocket, localhost
        ▼
    ComfyUI  (user's existing installation)
        │
        ▼
    GPU

Three processes, one machine boundary. The Android app talks only to the
gateway. The gateway talks only to ComfyUI and the local filesystem.

## Boundaries

**App ↔ gateway.** The only network boundary that crosses machines. Its whole
surface is `docs/api.md`. The app holds one piece of connection state: a
*base endpoint*. Everything else it fetches.

**Gateway ↔ ComfyUI.** A localhost boundary. The gateway owns every ComfyUI
detail: the API-format graph, node ids, prompt submission, the ComfyUI
WebSocket, history lookup, output file locations. **None of that crosses to the
app.** The app receives presentation-level workflow descriptions and typed
fields; it never sees or reasons about a node graph.

**Gateway ↔ configuration.** The gateway reads the workflow registry
(`docs/workflow-schema.md`) and runtime configuration (`docs/runtime.md`). It
contains no knowledge of any specific model, checkpoint, custom node or
workflow. Adding a workflow is adding two files, never editing source.

## Why the gateway exists

It could be argued the app should call ComfyUI directly. It must not:

1. ComfyUI *can* stay bound to localhost, with only the gateway LAN-facing
   (`docs/privacy-security.md`). The binding is the user's to choose; the
   topology is what makes the safe choice possible, and `doctor.ps1` reports
   when it has not been made.
2. The node graph must never reach the phone. The gateway is where a curated
   YAML definition is turned into a filled-in API graph.
3. Job identity, media uploads and reconnect semantics need a server-side owner
   that outlives a dropped mobile connection (`docs/recovery.md`).

## Component responsibilities

### `app/` — Flutter, Android only
Connection state and endpoint persistence; discovery, QR and manual entry;
workflow browsing and help; dynamic form rendering from the field schema; media
selection and upload; generation lifecycle display; result view, save and share.

Model-agnostic and workflow-agnostic. It renders what the registry describes.

### `gateway/` — FastAPI, Python
Runs from its own project-local `.venv/`, never from ComfyUI's Python
(`docs/runtime.md`). Serves `docs/api.md`. Loads and validates the workflow registry. Accepts media
uploads into a temporary store. Optionally translates the text fields a workflow
marks translatable — see below. Binds field values into a copy of the workflow
JSON. Submits to ComfyUI, tracks jobs, streams state, supports cancellation,
serves results. Advertises itself over mDNS. Renders the QR pairing payload
for the terminal (there is no HTTP pairing page — `docs/connection.md`).

#### Prompt translation is a gateway stage, before binding

    inputs → validate → translate → bind → ComfyUI

One stage, in one place. Not in the app, not per workflow, not per model, and
never after binding — the graph carries the *effective* text, while the
**original** the user typed stays canonical and is what the app shows, what a
draft stores and what Generate Again resubmits (`docs/api.md`).

Three properties are architectural rather than incidental:

- **It is local, and there is no fallback that is not.** Translation runs from a
  model on the PC. No request reaches a network, no failure is recoverable by
  reaching a service, and none may ever be added: LocalCanvas is local-first,
  and a prompt is the most personal text a user writes
  (`docs/privacy-security.md`). Models are installed by an explicit setup step.
- **The backend is an optional extra, never a base dependency.** It costs about
  a gigabyte, so a user who does not want translation must not download it to
  run LocalCanvas. The gateway therefore imports it lazily and its whole test
  suite runs without it.
- **The workflow decides which fields are natural language.** The gateway never
  infers it from a value. A model name, a filename, a select identifier or a
  number cannot be reached by this stage at all (`docs/workflow-schema.md`).

### `scripts/` — PowerShell, Windows first-class
`start.ps1`, `stop.ps1`, `status.ps1`, `doctor.ps1`, `strict-lan.ps1`. Runtime
orchestration, process ownership and interpreter selection (`docs/runtime.md`);
machine-level LAN enforcement (`docs/privacy-security.md`).

### `config/`
`config/examples/` — public, redistributable examples.
`config/local/` — the user's real configuration. **Gitignored.**

### `workflows/`
`workflows/examples/` — public example workflow definitions and their
API-format JSON. Personal workflow assets stay in `config/local/` or are
otherwise kept out of the public repository unless deliberately redistributable.

## Non-negotiables

- No original-developer path, model, custom node or node id becomes an
  architectural assumption.
- The app never needs a source change to work with a different user's ComfyUI.
- The gateway never introspects an arbitrary workflow to guess its inputs.
  Mapping is explicit and configuration-driven, always.
- The maintainers' task-management tooling is a development control surface and
  never a runtime dependency. Nothing under `app/`, `gateway/`, `config/`,
  `workflows/` or `scripts/` may import, invoke or require it.
- LocalCanvas never installs into, or writes to, the user's ComfyUI environment.
  The only coupling between the two is HTTP.
  The optional bootstrap in `comfy/` keeps the same boundary for a
  machine that has **no** ComfyUI: it installs one only where none exists,
  records what it installed beside it, and treats any installation it did not
  create as read-only — it refuses to write inside, update or repair one, and
  that refusal is tested in both installation layouts.
