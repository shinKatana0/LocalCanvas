# UI / UX contract

**Visual quality is part of the v0.1 Definition of Done**
(`docs/definition-of-done.md`, items 15 and 32-34). A functionally complete app
that looks like a debug tool does not pass.

## What this must not look like

Debug UI. An engineering frontend. A generic admin dashboard. A raw Material
sample with default colors and default spacing.

## Visual direction

Flutter **Material 3** is the accessibility and component foundation — semantics,
contrast, touch targets, text scaling. The look on top of it is a restrained
modern creative tool.

- **dark-first**, with a complete light theme derived from the same tokens;
- graphite / neutral surfaces;
- **one** restrained accent, used for action and state — not for decoration;
- strong typographic hierarchy doing the work borders usually do;
- generous whitespace;
- ~16–20dp radii where appropriate;
- minimal borders;
- no heavy gradients, no decorative glassmorphism, no AI-neon/cyberpunk cliché,
  no cluttered dashboard;
- no raw ComfyUI terminology unless genuinely necessary.

**Generated media is the hero.** When a result exists, controls visually recede:
the image or video gets the space, the emphasis and the contrast.

## Which of the two a person gets

**The system's setting is the default, and the user may override it.** Three
choices, no more: light, dark, and follow the system. A first run that has never
been told anything follows the system, which is what a phone user already
expects and what every other app on the device does.

The choice is **device-local**. It is not part of the portable profile
(`workflow_profile.dart`), because that document is described to the user as
their saved settings and setups, and a screen preference is neither: it belongs
to the phone the eyes are in front of, not to the workflows. The profile's own
sentence stays true without being reworded.

The override is **remembered across launches** — a preference a user has to set
again every time is not a preference — and it is stored the way every other
device-local choice in this app is stored.

## Capping text scale

**The app scales with the system's text size. One exception is permitted, and it
is a trade rather than a preference.**

A control whose label cannot wrap — a Material chip carries `softWrap: false` —
and whose text is one word with nowhere to break can reach a width no pane has.
The alternatives are all worse than a cap: fading the end of the word out is the
defect this was fixed for twice and leaves nothing on screen to notice;
truncating is the same thing with a mark; and a control that overflows its pane
is not a layout.

So a cap is allowed **only** where:

- the alternative is text a person cannot read at all, measured, not assumed;
- it applies to the one control that needs it and nothing else in the app;
- the bound is **derived from the measurement** and asserted by a test, not
  chosen for looking about right;
- and the capped size is still **larger than the default**, so the reader who
  set a bigger size still gets one.

It is never a way to avoid designing a layout. Where a control can be given a
form that wraps — a vertical list of choices rather than a row of chips — that is
the better answer and the cap should go.

The first case was the appearance and language controls at v0.1. **A second
locale created the failure, on a control that second locale required**, and the
matrix that found it was built at the same time — so it was caught on the way in
rather than after shipping, which is the whole reason to add the row before the
translations.

Both halves of it come from the second language. `Системная` is nine characters
where `System` is six, and the `English` chip that fails alongside it is a
label the language control introduced: before there were two languages there was
no chip to draw it on. An earlier draft of this section claimed the control was
already unreadable in English on `main`; re-measuring the pre-change revision
disproved that — every label was drawn whole at every width and scale — and the
claim is withdrawn rather than softened.

Figures for this case are deliberately not quoted here, because they are taken
with the test toolkit's fixed-advance font and not the shipped face. A number
measured by a test harness is evidence about the layout's arithmetic, not a
product fact, and this document should not quote it as one.

## Tokens

A **minimal** centralized set: spacing, radii, typography, surfaces, semantic
colors. Light and dark are two values of the same tokens.

That is the whole design system. **Do not build a design-system project** — no
component library, no theming framework, no token pipeline, no variant matrix.

## Startup experience

Required, and part of visual acceptance.

**Never:** a blank white screen, the default Flutter splash, an abrupt
debug-looking transition, or a heavy multi-second intro.

Target: **~0.8–1.5s** under normal conditions; immediate perceived
responsiveness; consistent with the app's own theme; correct in dark and light;
**no external runtime assets or services**.

Sequence:

1. the LocalCanvas mark — a simple geometric canvas/flow symbol — appears;
2. a subtle scale/fade or line-formation;
3. the `LocalCanvas` wordmark resolves;
4. a smooth transition into the app shell.

Built from **native Flutter animation primitives**. Do not add a large animation
framework, a particle system, shader work, or a Lottie dependency for this.
Do not build an animation architecture.

**The animation must never delay readiness.** It runs while connection work
proceeds. If connection is still in flight when the intro ends, it transitions
naturally into a polished `Connecting...` state — the splash is never held
artificially to finish an effect, and readiness is never gated on a frame count.

## Adaptive / foldable layout

Adapt on **available width**. Never on hard-coded device models, and never on
"is this a foldable".

**Compact** — a single column. Idle, it reads as the creation flow: workflow ·
prompt · media inputs · Advanced · Generate. Once a generation is running or a
result exists, that surface is **hoisted above the controls** rather than
appended below them — "generated media is the hero" wins over source order, and
a result the user has to scroll past the form to find is not one. The two rules
conflict only in this layout, and this is how the conflict is settled.

**Expanded / unfolded** — two panes: controls left, active generation and result
right.

**Do not stretch the compact layout across a large screen.** A full-width
single column of form fields on an unfolded device is a failure of this contract.

**State survives fold/unfold and every size change** — prompt, workflow,
Advanced values, media selection, in-flight generation, displayed result. A fold
is a configuration change, not a restart, and losing a prompt to one is a defect
(`docs/recovery.md`).

## Workflow selection

**Not a bare technical dropdown.** Human-readable cards showing display name,
category, badge (TXT2IMG / IMG2IMG / VIDEO / UPSCALE) and short description.

Grouping is **configuration-driven** (`docs/workflow-schema.md`). Groups such as
Recommended / Create / Edit / Video / Enhance come from the YAML, and workflow
logic does not branch on those names. An unknown group renders as its own
section.

**The sections can be narrowed to one.** A filter above the cards
offers **All** — the default, and an option like any other, so a person who went
back to everything can see that they did — then one option per group the
connected gateway serves, in the registry's order, and the app's own word for
the workflows that declared no group. That nameless bucket stays reachable
whenever it has members, and is kept apart from a group a curator happens to have
named the same word. The filter branches on none of the group names. It appears
only when there is more than one group, because a filter whose every answer
shows the same list is noise, and it is not remembered: narrowing is about
looking, not about what was chosen, so the picker opens on All every time.

## Workflow help

Every production workflow explains itself **inside the app**: what it does, when
to choose it, what input it requires, how to use it, expected defaults, an
example prompt where useful, and optionally what it is not ideal for.

Surfaced through a polished details surface, in **one of two places decided by
the moment**, not by taste:

- **Browsing the picker**, a card explains itself in a **modal bottom sheet**.
  You are comparing things you have not chosen, and a sheet is the right form
  for a look that ends in going back.
- **Once a workflow is chosen**, its block explains itself **in place**, behind
  the same inline disclosure the connected server uses. You are working now, not
  choosing, and a modal that covers the form you are filling in is the wrong
  shape for that.

**It is the same content in both, because it is the same widget in both** — not
two accounts of one workflow that can drift apart. A person who reads the sheet
in the picker and then opens the block must not be told something different.

**Two blocks drawn alike must behave alike.** The selected-workflow block and the
connected-server block share a surface, a radius and a border, so they read as
one kind of thing; one of them disclosing inline while the other opened a modal
was a defect a user found by using the app, not a preference.

The bar: **a user returning after months understands the workflow without
opening external documentation or inspecting a node graph.**

## Dynamic forms

Rendered from the field schema. Main fields are visible; Advanced is collapsed
behind a clear affordance.

Natural controls, not a generic property grid: boolean → switch; select →
selector; numeric → an appropriate numeric control; seed → numeric value plus
**Random**; width/height → paired controls where useful.

Required-but-empty is shown as a **clear, non-punitive** requirement, and
Generate communicates why it is unavailable rather than failing silently.

Advanced settings exist because the curator chose them. **Do not surface a
parameter merely because ComfyUI has one.**

## Media input

Images and videos are first-class.

**Image:** Android media picker, preview, replace, remove, required-state
validation, upload progress.

**Video:** picker, preview/thumbnail where practical, filename, size and
duration where easily available, replace, remove, upload progress.

**Never show raw filesystem paths in normal UI.** A filename is human; a content
URI is not.

Upload progress is real byte progress, never a fake animation
(`docs/recovery.md`).

## Generation and results

States are legible and honest (`docs/recovery.md`): uploading, queued,
generating, and their outcomes. Real progress where it exists, indeterminate
where it does not, **never a fabricated percentage**. Cancel where supported.

**Generate Again and the seed.** Generate Again varies the seed of
every field whose role is `seed`, writing the new number **into the field**, so
the seed on screen is always the seed that was sent. Nothing else in the form
changes. Advanced carries a **Freeze seed** switch, off by default, that makes
Generate Again reuse the seed exactly. The first Generate is unchanged: it sends
whatever the field holds. A workflow with no seed role is unaffected, and a
renderer that ignores `role` still produces a correct form — it simply offers
neither Random nor Freeze seed (`docs/workflow-schema.md`).

**Image result:** large preview, Save, native Android Share, Generate Again.
**Video result:** local preview where practical, Save, Share where practical,
Generate Again.

**No database-backed history and no gallery.** Small in-session, in-memory state
is the whole feature.

Stepping back through the results of *this* session is that in-memory state, not
a gallery: a bounded list of job ids, no bytes kept, nothing written down, and
nothing left after the app closes. The two words above name what is forbidden —
a database, and a grid of everything you have ever made. They do not forbid
finding the picture you liked two generations ago, which is the ordinary way
Generate Again gets used.

Being able to compare is also what makes the loop honest. "Is this the same
picture?" is not a question a person can answer from memory one image at a time,
and asking them to is how a real difference goes unnoticed.

## Errors

Every expected error state is human-readable and actionable. No raw exception
text, no HTTP status codes, no ComfyUI internals as the user-facing message.
Each error names what happened and what the user can do about it.
