# Workflow registry and schema contract

A workflow is **two files**:

1. a ComfyUI **API-format** workflow JSON, exported from the user's own ComfyUI;
2. a **YAML definition** that describes it to humans and maps user-facing fields
   onto node inputs.

Adding a workflow is adding those two files and nothing else. **No source change,
ever.**

## Why mapping is explicit

LocalCanvas does not introspect a graph to guess which inputs a user should see.
Automatic introspection is an explicit non-goal: it produces a debug UI, exposes
parameters nobody should touch, and breaks whenever a custom node changes. The
curator decides what is worth exposing. That decision is the product.

**The gateway never introspects. The importer is not the gateway.**
`scripts/sync-workflows.ps1` reads a graph once, off the serving path, and
writes a definition file — the same two files a curator would have written by
hand, in the same format, editable afterwards and never regenerated over. That
is a starting point offered to the curator, not a decision taken from them: what
ships to the phone is still whatever the YAML says, and a curator who edits it
wins. Where the importer cannot establish what an input means it marks the
workflow for review rather than guessing, which is this rule holding rather than
bending. Nothing in the running gateway reads a graph to decide what to show.

## Layout

    workflows/
      examples/
        example_workflow.yaml
        example_workflow_api.json

Personal workflows and their assets live under `config/local/` (gitignored) or
are otherwise kept out of the public repository unless deliberately
redistributable. The registry root is configurable; it is not a fixed path.

## Definition

```yaml
id: example_workflow          # unique, stable, [a-z0-9_-]; the API key
name: Example Workflow        # display name
workflow: example_workflow_api.json   # relative to this YAML

presentation:
  group: Create               # picker grouping, free-form
  category: Photoreal         # secondary descriptor
  badge: TXT2IMG              # short type marker

  short_description: >
    General-purpose photorealistic generation.

  best_for:
    - Portraits
    - Cinematic scenes

  how_to_use: >
    Describe the subject, environment, lighting and composition.
    Defaults normally work well.

  input_summary: Prompt only

  example_prompt: >
    A rainy Tokyo alley at night, cinematic lighting,
    wet asphalt reflections, 35mm photography

  not_ideal_for:
    - Anime character consistency

inputs:
  - id: prompt
    label: Prompt
    type: multiline
    required: true
    section: main
    bind:
      node: "76"
      input: text

  - id: steps
    label: Steps
    type: integer
    default: 20
    min: 1
    max: 50
    section: advanced
    bind:
      node: "31"
      input: steps
```

`group`, `category` and `badge` are **data, not an enumeration in code**.
"Recommended / Create / Edit / Video / Enhance" and "TXT2IMG / IMG2IMG / VIDEO /
UPSCALE" are conventions the examples follow; workflow processing must not
branch on their values. An unknown group renders as its own section.

## Field types (v0.1)

| `type` | Value | Control |
|---|---|---|
| `string` | string | single-line text |
| `multiline` | string | multi-line text |
| `integer` | int | numeric control, `min`/`max`/`step` |
| `float` | float | numeric control, `min`/`max`/`step` |
| `boolean` | bool | switch |
| `select` | one of `options` | selector |
| `image` | uploaded media ref | image picker with preview |
| `video` | uploaded media ref | video picker with thumbnail |

Common keys. Required on every field: `id`, `label`, `type`, `bind`. Optional:
`required` (default `false`), `section` (`main` | `advanced`, default `main`),
`default`, `help` (a one-line hint, written by a curator **and** by the
importer — see below), `translatable` (default `false`).

Type-specific: `min` / `max` / `step` (numeric); `options` as a list of
`{value, label}` (select), where `label` may be omitted and defaults to the
value written as text; `role: seed` (integer, adds a Random affordance);
`pair: width|height` (integer, hints paired layout); `duration: {fps: N}`
(integer, hints that the number counts frames and may also be read as a time).

`role`, `pair` and `duration` are **presentation hints only**. A renderer that
ignores them still produces a correct, usable form.

### `help` — one line saying what the knob does

`help` is a one-line hint. It renders under the control in small muted text and
is what makes a necessary ComfyUI word legible: `docs/ui-ux.md` asks for "no raw
ComfyUI terminology unless genuinely necessary", and `sampler_name` is genuinely
necessary, because it is what the graph calls it.

A curator may write one on any field. **The importer also writes one**, from a
generic vocabulary of ComfyUI input names — so a definition it generates arrives
explained rather than bare.

- **It is looked up on the graph's own input name**, from the field's `bind`
  targets, and never on the field's `id`: an id may carry a disambiguating
  suffix where two controls share a role, and every one of those would be
  missed. Where a field binds several inputs the graph calls by different
  names, nothing is written — one sentence cannot describe two of them.
- Where the input name says nothing, and only then, the **role** the importer
  minted from the wiring is consulted. That is the one case an input name can
  never answer: a text encoder's own input is called `text` in every graph, and
  which of them is the negative prompt is decided by the wiring alone. The
  input-name lookup is never overridden by this one.
- **A field the vocabulary has nothing true to say about is written with no
  `help` key at all** — not `help: ""`, not `help: null`. A blank line of muted
  text under a control costs space on a phone and teaches nothing.
- **Regeneration follows the `label` rule and not the "already written wins"
  rule.** A generated definition carries a hint on every field the vocabulary
  knows, so presence in the file cannot tell curation from generation. The
  importer therefore compares what is in the file against what **it** generated
  when it last wrote that file, remembered in its own inventory: equal means
  nobody touched it, so an improved sentence reaches a catalogue that already
  exists; different means somebody wrote it, and it is kept verbatim. With no
  remembered record at all — the run after the inventory is deleted, for
  instance — what the file says is preserved, so deleting the inventory does
  not bring generated labels or help lines back; deleting the definition does,
  and discards every edit in it. A sentence a curator wrote is never recorded
  as the importer's own.

### `duration` — a frame count that may be shown as a time

```yaml
- id: length
  label: Length
  type: integer
  min: 25
  max: 121
  step: 4
  duration:
    fps: 24
  bind:
    node: "42"
    input: length
```

`duration` says: this integer counts frames, and the workflow plays them at the
declared rate. A renderer may then show `≈ 1.04 s at 24 fps` beside the frame
count, so a user picking the length of a clip is not asked to think in frames
alone.

- It is legal on `integer` only. On any other type it is an error, the same way
  `translatable` is an error off `string`/`multiline`.
- `fps` is required inside it, is the only key it accepts, and must be a finite
  number greater than zero.
- **It is declared, never inferred.** A field called `length`, `frames`,
  `video_length` or anything else switches nothing on by itself; neither does a
  value range that happens to look like a frame count. The gateway never reads a
  frame rate out of the graph to fill `fps` in — at run time the hint is read
  from this file and from nowhere else. The **importer** may write one, once,
  and only from a rate the graph itself declares on a frame-rate input: it
  derives nothing from a field's name, and where a graph declares no rate or
  more than one it writes no `duration` at all. What it produces is a
  declaration in the YAML, which a curator can correct or delete. A workflow
  that does not declare
  `duration` renders exactly as it did before this hint existed — an inferred
  duration over a field that turned out to be a latent count, a batch size or a
  loop counter is a confident lie, and this schema does not tell one.
- **The value never changes.** What is validated, bound and sent to ComfyUI is
  the frame count, unmodified. A duration is a *reading* of that number and
  never a substitute for it: nothing submitted carries seconds, and no frame
  count is ever rounded on the way out.
- `min` / `max` / `step` keep binding, and they bind the frame count. A duration
  is therefore offerable only when it maps onto a legal frame count exactly:
  with the example above, 1 s (24 frames) is not offerable at all, because 24 is
  not reachable from 25 in steps of 4, while 25, 29, 33 … frames are — so the
  offerable readings are ≈ 1.04 s, ≈ 1.21 s, ≈ 1.38 s and so on.
- A workflow that also exposes its frame rate as a user-editable field declares
  that field as an ordinary `integer`. `duration` presents one field; it does
  not couple two.

## Translation

`translatable: true` marks a field as **natural language the gateway may
translate** before binding (`docs/api.md`). It is allowed on `string` and
`multiline` only; on any other type it is an error, because a select identifier,
a filename, a path or a number is not prose. It is a gateway-side decision and
is not part of the field schema the app receives.

Nothing is inferred: a field the curator does not mark is never translated,
whatever its value looks like. This is what keeps model names, checkpoints, LoRA
filenames, samplers and schedulers out of a translator's reach.

A workflow can also opt out entirely:

```yaml
translation:
  mode: off      # auto (default) | off
```

`auto` means "whatever the gateway is configured to do"; `off` means this
workflow's text is never translated, whatever the machine's configuration says.
There is no `on` — a workflow cannot switch on a stage the machine has not been
configured for. YAML reads a bare `off` as the boolean false, so `off` and
`"off"` are accepted as the same setting and a curator never has to know the
difference.

The schema is extensible — a later `mask` or multi-image type would be new `type`
values and nothing more. v0.1 does not implement them.

## Binding

```yaml
bind:
  node: "76"      # node id as a STRING, as it appears in the API JSON
  input: text     # the input key inside that node's "inputs"
```

At submit time the gateway deep-copies the workflow JSON and writes each supplied
value at `prompt[node]["inputs"][input]`. Media fields bind to the value ComfyUI
expects for a loader input — the gateway resolves an uploaded `media_id` to that
value; the app never learns what it is.

### One field may drive several node inputs

**A LocalCanvas field is one logical user input, not one ComfyUI node input.** A
graph routinely carries the same user concept in several places: one prompt
feeding two conditioning nodes, one seed in a sampler's `seed` and a second
sampler's `noise_seed`, one source image loaded twice. The user sets it once, so
`bind` also accepts a **list** of targets:

```yaml
bind:
  - {node: "12", input: image}
  - {node: "37", input: image}
```

A single mapping is exactly a one-element list — every definition written
against the single-target form keeps working, unchanged. The value is written
into **every** target, unmodified: one value, several places in the graph, no
transformation between them. The order is the order the author wrote, so a
failure is reproducible and a diff is readable.

The presentation view is untouched by any of this. A field with three targets
looks to the app exactly like a field with one: a node id, a node type and a
`bind` block never cross the boundary (`docs/architecture.md`).

Node ids are strings because ComfyUI's API format keys them as strings. A YAML
integer `76` and a JSON key `"76"` name the same node, and validation normalizes
the integer form to the string form. It does so silently: the loader has two
outcomes, accept and reject, and no warning tier — the binding is correct either
way, so there is nothing to warn about. Quoting node ids is still the clearer
habit.

## Validation

Registry load validates, and refuses a bad definition rather than failing at
generation time. This is the whole rule set, not a sample:

**Required keys.** `id`, `name`, `workflow` and `inputs` at the definition
level; `id`, `label`, `type` and `bind` on every field; `node` and `input`
inside every `bind` target. `inputs` may be an empty list, which is how a
workflow with no user-facing fields is written; a field with no `bind` is
refused, because a field that maps onto nothing does nothing.

**Identity and files.**

- `id` non-empty, matching the allowed charset, and unique across the registry.
  A duplicate rejects **every** definition claiming that id, never a silently
  chosen winner — a curator editing one file and seeing nothing change would
  have no way to find out which other file had shadowed it;
- `workflow` is a path *relative to the definition file* — a rooted or
  drive-qualified path is refused, so a definition never carries an absolute
  machine-specific path — and resolves to a readable file that parses as
  ComfyUI API-format JSON.

**Fields.**

- every `inputs[].id` unique within the workflow;
- an unrecognised key is an **error, not a comment**, at the definition, field,
  `bind`, `options[]` and `presentation` levels — the message names the key and
  lists the allowed ones. A typo that was quietly ignored would surface much
  later as a field that does nothing;
- the same key written twice in one YAML block is refused too: YAML keeps only
  the last, so one of the two lines would silently do nothing;
- `select` has a non-empty `options` list, each `value` scalar and unique;
  `label` is optional and defaults to the value written as text;
- `min`/`max`/`step` are coherent: `step` greater than zero, `min` not greater
  than `max`;
- `default` satisfies the field's own type, range and `options`; `default: null`
  is refused — omit the key when there is no default;
- a `required` field may not declare an **empty-string** default — that is the
  precise rule, and it is the whole of it. A required number defaulting to `0`
  is not refused, because nothing here can tell a meaningless zero from a meant
  one;
- media fields are `image` or `video` only, and declare no `default` at all:
  their value is an uploaded reference, not a path;
- `translatable` is a boolean, and only a `string` or `multiline` field may
  carry it; `translation.mode` is `auto` or `off`, and `translation` accepts no
  other key;
- `duration` is a mapping, and only an `integer` field may carry it; it accepts
  the single key `fps`, which is required and must be a finite number greater
  than zero.

**Bindings.** Every rule below is applied **per target**, and a diagnostic names
which one failed: `bind` for the single-mapping form, `bind[1]` for the second
entry of a list.

- `bind` is either a mapping or a non-empty list of mappings. `bind: []` is
  refused — a field that binds to nothing cannot do anything, and saying so at
  load beats a mystery at generation time;
- every `bind.node` exists in that JSON, and `bind.input` exists on that node;
- `bind.input` may not name an input that is **wired to another node's output**
  — that is a connection, not a value, and overwriting it would break the graph;
- two fields may not bind to the same `(node, input)`: only one could win, and
  which one would be an accident of ordering;
- one field may not name the same `(node, input)` twice. A repeated target is
  refused rather than deduplicated: it does nothing, and it is a mistake in a
  file a human wrote by hand.

A workflow failing validation is **omitted from the registry with a clear
diagnostic**, and the rest of the registry still loads. One broken workflow
never takes the whole app down.

Validation is available offline as part of the runtime tooling, so a curator can
check a definition without starting a generation.

## Rules

- Never expose a node input just because it exists.
- Never name a model family, checkpoint or custom node in application logic.
- Never let a node id reach the app.
- Every production workflow fills in enough of `presentation` that a user
  returning months later understands it without reading documentation or opening
  ComfyUI (`docs/ui-ux.md`).
