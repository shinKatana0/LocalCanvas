# Gateway ↔ app API contract

Version `v1`. All paths are under `{base_endpoint}/api/v1`. JSON in, JSON out.
Read `docs/transport-boundary.md` before changing anything here.

## Identity handshake — `GET /api/v1/info`

The first call after obtaining an endpoint, from every connection path. Cheap,
unauthenticated, safe to poll.

```json
{
  "service": "localcanvas",
  "api_version": 1,
  "gateway_version": "0.1.0",
  "instance_id": "3f9a2b7c1d4e6f8091a2b3c4d5e6f708",
  "display_name": "My Generation PC",
  "comfy": { "status": "ready", "detail": null },
  "jobs": { "active": 0 },
  "capabilities": {
    "cancel": true, "media_upload": true, "events": true,
    "translation": { "enabled": true, "installed": true,
                     "pairs": [ { "source": "ru", "target": "en" } ] }
  }
}
```

`comfy.status` — `ready` | `starting` | `unavailable`. `detail` is a short
human-readable string when not `ready`, never a stack trace.

`instance_id` — 32 lowercase hex characters identifying **this running
process**, not this build. It changes on every gateway start (`--instance-id`
on the command line names one explicitly; left out, the gateway generates one)
and is how something watching from outside — a launcher or process monitor — tells
this gateway apart from a different one that happens to be listening on the
same port. A client that only needs compatibility keeps checking `service` and
`api_version`, exactly as before this key existed.

`jobs.active` — how many jobs this gateway currently has in state `queued` or
`running`. Read from the gateway's own job store, not from ComfyUI, so it costs
nothing extra on top of the `comfy.status` probe this endpoint already makes.

**The client MUST reject a response whose `service` is not exactly
`"localcanvas"`**, and MUST refuse to treat an arbitrary HTTP service as a
gateway. A reachable host that fails this check is reported as *"Not a
LocalCanvas server"*, which is a different message from *"unreachable"*.

**Compatibility:** the client declares the `api_version` it supports. A gateway
reporting a different major version is reported as incompatible with the
versions named, not silently used.

`capabilities` lets the client hide affordances the gateway does not offer —
notably a Cancel button when `cancel` is false.

`capabilities.translation` describes the prompt translation stage **on this
PC**, so that a client can say what will happen to a prompt *before* it is
submitted rather than discovering it from an error afterwards:

- `enabled` — the stage is switched on in this machine's configuration
  (`prompt_translation` in `docs/runtime.md`);
- `installed` — the optional backend is present on this PC. Separate from
  `enabled` on purpose: "the extra was never installed" and "it is installed
  and switched off" are different situations, and only the first is fixed by
  `pip install ./gateway[translation]`;
- `pairs` — the `{source, target}` language pairs this gateway would really
  use: its configured sources, minus any whose model is not installed.
  Empty whenever nothing would be translated.

`enabled` and `installed` are answered afresh on every call. `pairs` is read
**once, when the gateway starts**: finding out which models are installed means
reaching the translation backend, and reaching it costs the ~1 GB import, which
is not something a handshake inside the client's timeout may pay. A model
installed while the gateway runs therefore appears after a restart — the same
explicit setup step that installed it — and the gateway prints what it found in
its startup output.

**The block never carries a model name, a file path or the backend's name.**
It is a description of capability, in two booleans and ISO language codes, and
it is read by an unrelated user's phone (`docs/privacy-security.md`).

**A missing `translation` key means "this gateway is older than the feature",
not "off".** A client must treat it as *unknown* and behave as it did before
the key existed; reading absence as `false` would state as fact something the
gateway never said.

## Workflow registry

`GET /api/v1/workflows` → the presentation-level list used to build the picker:

```json
{ "workflows": [ { "id": "...", "name": "...", "presentation": { ... },
                   "input_summary": "Prompt only", "required_media": ["image"] } ] }
```

`GET /api/v1/workflows/{id}` → one workflow, including its full `inputs` field
schema (`docs/workflow-schema.md`). It repeats the summary fields, `input_summary`
among them, so a client that deep-links to one workflow needs only this call.

`input_summary` is carried **twice** in both responses: at the top level, as
shown above, and inside `presentation` where the curator wrote it
(`docs/workflow-schema.md`). The top-level copy is the one a client should read,
because it is always present — it is `null` for a workflow whose `presentation`
omits it, while the copy inside `presentation` is simply absent in that case.
Treat it as nullable; a minimal workflow definition declares no summary at all.

**Node ids, node types and bindings are never present in either response.** The
`bind` block is gateway-side only. The app receives fields, not a graph.

### `Accept-Language` — the language of a field's `help`

A client may send `Accept-Language` on `GET /api/v1/workflows/{id}`. It carries
**one bare language tag — `en` or `ru` — with no region and no quality values**:
the app's interface language is a single choice, so there is nothing to
negotiate and no list to rank. Case is not significant; `RU` is `ru`.

It affects exactly one thing: a field's `help`, and only where that hint was
**generated** by the importer from the gateway's own vocabulary of one-line
sentences. Everything else in both responses is the curator's own content and
is never translated — `name`, `label`, and every key of `presentation`
(`short_description`, `best_for`, `how_to_use`, `input_summary`,
`example_prompt`, `not_ideal_for`).

**A hint the curator wrote is served untouched, in whatever language they wrote
it, whatever language was asked for.** The definition file carries one `help`
string per field and does not record who wrote it, so the gateway decides by
recomputing: a hint is generated if it is exactly what the English vocabulary
produces for that field, and anything else was written by a person.

**No definition file changes.** The YAML on the PC keeps carrying the English
line — which is also what a curator sees when they open it — and the
substitution happens on the way out.

The answer to anything this gateway cannot serve is **English**, never an error
and never an empty string:

- no `Accept-Language` header at all — the request an app built before this
  feature sends, and it gets byte-identical output to what it always got;
- a language the gateway does not have (`fr`);
- anything that is not a bare tag (`ru-RU`, `ru;q=0.9,en`), which this contract
  does not undertake to parse;
- a field whose sentence is missing from that language's table;
- **a hint written by an older vocabulary than the one the gateway is running.**
  The gateway recognises a generated hint by recomputing it, so a definition
  still carrying a sentence that has since been reworded no longer matches, is
  treated as the curator's, and is served exactly as the file has it — in
  English. It is per field and per catalogue: improving one English sentence
  un-localises that one line and nothing else. **Re-running the importer
  restores it**, in the same act that would have refreshed the English.

That last case is the price of not keeping a translation table on the user's
disk, and it is deliberate: the alternative is serving a *new* translation
beside an *old* original, which is worse than serving one language
consistently. Nothing breaks, and no version moves — it degrades to exactly
the behaviour that shipped before this feature.

**`api_version` does not move for this** (`docs/versioning.md`): it adds to the
wire and breaks nothing. An older app sends no header and is unaffected; a
newer app against an older gateway gets English, which is what it got before.
It is deliberately **not** announced in `capabilities` either: there is no
affordance for a client to hide, and a client that wants to know simply sends
the header and reads what comes back.

## Media upload — `POST /api/v1/media`

`multipart/form-data` → **201 Created**. Two parts, and the names are part of
the contract: the file part is named `file`, and `kind` (`image` | `video`)
accompanies it. Uploaded before job submission so that progress is observable
and a retried submit does not re-upload.

```json
{ "media_id": "m-3f9c1a", "kind": "image", "filename": "IMG_0142.jpg",
  "bytes": 2481923, "expires_at": "2026-09-02T19:41:00Z" }
```

Upload progress is a client-side property of the request body stream; the
gateway needs no progress endpoint.

The gateway owns the temporary media store and its lifetime. Media outlives job
submission but is not a library: no listing endpoint, no permanent store, no
server-side gallery.

## Jobs

### `POST /api/v1/jobs`

```json
{ "workflow_id": "example_workflow",
  "inputs": { "prompt": "a rainy alley at night",
              "steps": 24,
              "source_image": { "media_id": "m-3f9c1a" } } }
```

Keys are field `id`s from the workflow's schema. Media fields carry
`{"media_id": ...}`. The gateway validates against the schema — required,
type, range, select membership — and rejects with a field-attributed error
rather than passing bad values into ComfyUI.

One optional key sits beside `inputs`, and it is not a field:

```json
{ "workflow_id": "example_workflow", "inputs": { "…": "…" },
  "translation": { "mode": "off" } }
```

`translation` switches the translation stage **off for that one submission**.
Its whole vocabulary is the word `off`: there is no `on` and no `auto`, because
a client cannot switch on a stage the machine has not been configured for —
the same rule the workflow schema already states (`docs/workflow-schema.md`).
A workflow with `translation: {mode: off}` and a PC with no backend installed
therefore both stay off whatever a request says.

- **Absent** means "whatever this PC and this workflow already decided". Every
  client written before this key sends exactly that, and is unaffected.
- **Per submission and stateless.** The gateway remembers nothing: the next
  submission is translated exactly as it would have been. Remembering the
  choice is the client's job.
- Anything other than `{"mode": "off"}` is refused with `invalid_request` and
  `field: "translation"` rather than ignored — a client that believed it had
  switched translation *on* would otherwise be told a confident lie.

A submission that switched the stage off is answered with `"translation":
{"applied": false, "fields": {}}` — the same shape as a machine where the stage
never ran, because from the graph's point of view nothing was translated
either way.

Response `201 Created`:

```json
{ "job_id": "j-8f21", "state": "queued", "created_at": "...",
  "translation": { "applied": false, "fields": {} } }
```

201 rather than 200: a job is created and immediately addressable at
`/api/v1/jobs/{job_id}`.

### Prompt translation — a gateway stage, before binding

The gateway may translate natural-language fields into the generation language
before it writes them into the graph. It is **local** — a model on the PC, no
service, no network at request time — and it is **off unless configured**,
because the backend is an optional install (`prompt_translation` in
`docs/runtime.md`'s configuration file; `pip install ./gateway[translation]`).

The stage sits between validation and binding, and nowhere else:

    inputs → validate → **translate** → bind → ComfyUI

Two texts exist from here on, and the distinction is the contract:

- the **original** is what the user typed. It is canonical: it is what the app
  displays, what a draft and a saved setup store, and what Generate Again
  resubmits. The gateway never persists the other one as the user's prompt;
- the **effective** text is what was bound into the graph for this run.

`translation` is always present in the answer, and says what happened to the
submission's own text:

```json
"translation": {
  "applied": true,
  "fields": {
    "prompt": {
      "original": "…",
      "effective": "…",
      "translation": { "applied": true, "source": "ru", "target": "en" }
    }
  }
}
```

`fields` carries one entry per **translatable field the submission supplied**,
keyed by field id, whether or not that field's text was changed — so "nothing
was translated" is reported rather than left to be inferred. It is `{}` when the
stage did not run at all — switched off globally, `translation: {mode: off}` on
the workflow, or switched off by the submission itself — because the gateway
says nothing about fields it never looked at. `source` is `null` when nothing
was translated. No internal bookkeeping — spans, offsets, model names — ever
appears here.

Whether the stage will run at all is knowable in advance:
`capabilities.translation` in the handshake says whether it is switched on
here, whether the backend is installed, and which language pairs exist.

**Which fields.** Only the ones the workflow marks `translatable: true`, which
its schema allows on text fields alone (`docs/workflow-schema.md`). Never a
model name, checkpoint, VAE or LoRA filename, sampler, scheduler, select
identifier, path, filename, id, number or backend setting. The gateway does not
decide that a value "looks like a sentence".

**What is preserved, exactly.**

- **Text with no supported non-English content comes back byte-identical.** An
  optimised English prompt full of tags and weights is returned as typed: no
  normalisation, no paraphrase, no tidying of spacing.
- **Double-quoted literals are never given to the translator.** They are copied
  from the input to the output with their quote characters, so a sign, a name or
  a piece of typography survives exactly — in any language, including English.
  `\"` inside a literal is an escaped quote and does not close it.
- **The spacing and punctuation around a translated fragment survive.** Only the
  trimmed core of a fragment is translated; its leading and trailing whitespace
  is re-attached verbatim.
- **An unterminated quote runs to the end of the text.** This is the documented
  deterministic rule: from an unmatched `"` to the end of the input is treated as
  a protected literal and left untranslated. The character is never dropped and
  the gateway never guesses where the author meant to close the quote — the
  visible cost is that the tail is not translated.

**Language detection is script-based and conservative.** Cyrillic means Russian
is a candidate; hiragana or katakana mean Japanese is. Han characters alone are
ambiguous — they are Chinese too — and are never enough on their own. Text whose
language is not among the configured sources is left alone.

**Failure is an error, never a silent pass-through.** If translation was asked
for and could not run, the submission fails with one of the codes below and
nothing is sent to ComfyUI. Untranslated text is never passed off as translated,
and there is no cloud fallback — LocalCanvas has no service to fall back to and
must never acquire one (`docs/privacy-security.md`). Language models are
installed by an explicit setup step and are never downloaded by a request.

The three translation codes carry `field: null`. They say the gateway cannot
translate, not that a submitted value is wrong, and there is nothing for the
user to correct in the form. A prompt with no supported non-English content
never reaches the backend, so a user who does not need translation is never
stopped by an extra they never installed.

### `GET /api/v1/jobs/{job_id}` — state snapshot

The authoritative job state. Used for polling fallback and, critically, for
recovery after a dropped connection (`docs/recovery.md`).

```json
{ "job_id": "j-8f21", "workflow_id": "example_workflow",
  "state": "running",
  "progress": { "step": 7, "total": 24 },
  "results": [],
  "error": null }
```

**Server-side job states:** `queued` | `running` | `completed` | `failed` |
`cancelled`. These are the only states the gateway asserts. Connection-flavoured
states (`connecting`, `reconnecting`, `uploading`, `interrupted`) are client-side
and never appear here.

`progress` is present **only when ComfyUI reports real progress**. When it does
not, the field is `null` and the client shows indeterminate progress. Neither
side ever fabricates a percentage.

**A `job_id` the gateway does not know returns `404`.** That is the honest
signal that job state is gone, and the client renders it as such — it never
becomes a fake "still running".

### `POST /api/v1/jobs/{job_id}/cancel`

Requests interruption. Idempotent. **Returns the full job snapshot** — the same
document as `GET /api/v1/jobs/{job_id}`, not a bare state — so a job that
finished before the interrupt landed hands back its results in the same call and
the client needs no follow-up request to show them.

Honest about outcome: a job too far along to stop reports the state it actually
reached, and the client never shows "cancelled" for work that completed.

### `GET /api/v1/jobs/{job_id}/result/{index}`

The output bytes, with a correct `Content-Type`. Referenced from `results` by
**path relative to the base endpoint**, resolved by appending to that endpoint
and preserving any path component it carries (`docs/transport-boundary.md` §3):

```json
"results": [ { "index": 0, "kind": "image", "media_type": "image/png",
               "path": "/api/v1/jobs/j-8f21/result/0" } ]
```

`width`, `height` and (for video) `duration_seconds` are **optional** and are
normally absent. ComfyUI's history reports only filename, subfolder and type, so
learning a dimension would mean fetching and decoding every output on a path the
app polls. The client sizes media from the media itself. A gateway that does know
a dimension for free may include it; none is expected to.

## Event stream — `WS /api/v1/jobs/{job_id}/events`

Scheme derived from the base endpoint (`http`→`ws`, `https`→`wss`).

Messages are state deltas mirroring the snapshot shape:

```json
{ "type": "state",    "state": "running" }
{ "type": "progress", "step": 7, "total": 24 }
{ "type": "result",   "results": [ ... ] }
{ "type": "error",    "message": "human-readable, no stack trace" }
```

**The WebSocket is an optimization, never the source of truth.** Any client
that loses it falls back to `GET /api/v1/jobs/{job_id}`, and reconnect always
re-establishes truth from the snapshot, not from replayed events.

Close codes, because a client cannot otherwise tell refusal from a dropped
network: **1008** refuses the handshake for a job the gateway does not know —
the authoritative answer is the snapshot's 404, and the socket declines to
restate a fact the snapshot owns — and **1000** is the normal end, sent once the
generation is over and there is nothing further to say. No client-to-server
message is interpreted; the socket is one-way in practice.

## Errors

Non-2xx responses carry:

```json
{ "error": { "code": "workflow_not_found",
             "message": "That workflow is no longer available.",
             "field": null } }
```

`message` is end-user readable. `field` attributes validation errors to a form
field.

**The codes.** `code` is a stable token a client may branch on; `message` is
what a person reads. The set below is the whole set — a code that is not here is
a defect in one half or the other.

| Code | Status | When |
|---|---|---|
| `invalid_request` | 400 | a malformed request; `field` names the part at fault, e.g. a missing `file` or `kind` on an upload |
| `unknown_field`, `missing_field`, `out_of_range`, `invalid_choice`, `invalid_input` | 400 | submitted values against the workflow's field schema; `field` is always set |
| `workflow_not_found` | 404 | no such workflow in the registry |
| `workflow_unusable` | 500 | the workflow exists but its definition cannot be turned into a graph |
| `job_not_found` | 404 | no such job |
| `result_not_found` | 404 | no such result index on that job |
| `result_unavailable` | 502 | the index exists but the bytes could not be fetched from ComfyUI |
| `generation_failed` | — | carried in a failed job snapshot's `error`, never as an HTTP body |
| `comfy_unavailable` | 503 | a request needed the backend and the backend is not there. **Not** how the client tells gateway-down from ComfyUI-down: that is `comfy.status` in the `/info` handshake (`docs/recovery.md`), which the app reads. Both mechanisms exist; only the handshake is a connection-state decision |
| `comfy_rejected_workflow` | 502 | ComfyUI refused the submitted graph |
| `translation_unavailable` | 500 | translation is switched on and the backend is not installed on the PC, or is configured to answer from a remote service. The message names the install command |
| `translation_model_missing` | 500 | the backend is installed but the language pair is not. The message names the setup command that installs it |
| `translation_failed` | 500 | the local model was there and failed. The detail is logged on the PC |
| `not_found` | 404 | no such route |
| `method_not_allowed` | 405 | wrong method for a route |
| `request_failed` | any other bare HTTP status | nothing more specific was raised |
| `internal_error` | 500 | an unhandled exception; the detail goes to the PC's log, never to the body |

**Media error codes**, on `POST /api/v1/media` and on a job that references an
upload: `file_too_large` (with the limit in the message),
`unsupported_media_type`, `unsupported_image_heic` (415: the bytes are a HEIC
or HEIF photo, which the gateway does not store; the message says to choose a
JPEG or PNG, or to turn off high-efficiency (HEIC) photos in the camera
settings), `empty_upload`, `invalid_filename`,
`media_kind_mismatch` (an image sent to a video field, or the reverse),
`media_expired`, `media_not_found`, and `media_store_unavailable` (500).

`media_not_found` and `media_expired` split on what the gateway can state as
fact. A reference that does not even match the id shape the gateway issues is
`media_not_found`. A well-formed id the store does not hold is `media_expired` —
**including one that was never issued**, because reaped and never-issued are
indistinguishable from the outside and the user's next action is identical
either way. Guessing between them would be inventing a distinction the gateway
cannot observe.
A job referencing media the store no longer holds fails with `media_expired`
attributed to the field, so the app can clear that field and ask for it again
rather than reporting a mysterious generation failure. Stack traces are never the user-facing surface — the gateway logs them
locally instead.

**What may cross from ComfyUI.** A backend failure reaches the phone as a human
sentence plus, at most, a short bounded reason. The rule on paths, stated
precisely because a vaguer version of it shipped once and leaked:

> **No directory component ever crosses. A bare filename may.**

with one honest qualification: the **final** component of a path is treated as a
filename and may cross, even when it happens to name a directory. Text alone
cannot tell a leaf directory from an extension-less filename, and a rule that
dropped it would also drop the legitimate filenames this exists to preserve.
What escapes is one generic word — `checkpoints`, `share` — never the layout.

`D:/models/whatever.safetensors` becomes `whatever.safetensors`. The directory
layout of someone's PC means nothing on a phone and is nobody's business there;
the filename is the one part a user can act on — it tells them *which* model is
missing. This holds regardless of separators or spaces in the path, and
`C:\Program Files\ComfyUI\models\sd xl.safetensors` is the shape to test
against, because it is the most likely one on the target platform.

Also never crossing: node internals, and a stack trace — including one a custom
node buried inside its own exception message rather than in a `traceback` field.

Full detail goes to the PC log, where someone can act on it. This is a boundary,
so code and contract must state the *same* rule, and a test pins it.

## Rules this contract enforces

- No absolute URLs naming the gateway's own host in any payload.
- No ComfyUI concepts in any response.
- No fabricated progress.
- No endpoint rejects a request for being non-LAN.
- No authentication in v0.1 — and no half-built scaffolding for it either.
