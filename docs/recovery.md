# Connection loss and job recovery contract

Connection loss is a **normal runtime condition**, not an exception. A phone
leaves Wi-Fi range, a PC sleeps, a router reboots, ComfyUI crashes. Each has a
different honest answer.

**The app must never sit indefinitely in a loading or generating state after the
gateway or machine is gone.** Every waiting state has a bound and an exit.

## Client lifecycle states

    disconnected · connecting · ready · uploading · queued ·
    generating · completed · failed · cancelled · reconnecting · interrupted

Server-side job states are only `queued | running | completed | failed |
cancelled` (`docs/api.md`). The rest are connection-flavoured and belong to the
client alone — with one mapping worth naming, because it is the only place the
two vocabularies describe the same thing: the client's `generating` **is** the
server's `running`. `interrupted` is the specific state meaning *we lost contact while
a job was in flight and do not yet know its fate* — it is never rendered as
though generation were still progressing.

## Four failures, four messages

| Condition | Detection | What the user is told |
|---|---|---|
| Gateway unreachable | handshake/request fails at transport | The LocalCanvas server can't be reached. |
| Gateway up, ComfyUI down | handshake succeeds, `comfy.status` ≠ `ready` | Connected, but ComfyUI isn't running. |
| Lost during generation | stream drops / request fails mid-job | Connection lost. Checking whether the generation survived. |
| Reconnecting / reconnected | bounded retry in progress / succeeded | subtle `Reconnecting...` → silent success |

Collapsing "gateway down" and "ComfyUI down" into one message is a defect: they
have different fixes, and the user is the one who has to apply them.

## Reconnect

**What starts it.** The automatic reconnect is armed by *losing contact with a
job the app is following* — the snapshot poll exhausts its failure budget. That
is where an unattended, silently-broken state can actually form, and so that is
where the app watches. There is no idle heartbeat in v0.1: with nothing in
flight, a gateway that goes away is discovered on the next action the user takes
(a registry refresh, a submit), which reports the failure with a **Try again**
and does not pretend to be connected. Stated here because it is a real bound on
"loss is detected", not something to be inferred from the absence of a
heartbeat.

Transient interruption:

1. Short **bounded** automatic reconnect with backoff — a handful of attempts
   over a few seconds, not an unbounded loop.
2. Meanwhile a subtle, non-modal `Reconnecting...` indicator. It does not blank
   the screen, discard the result on display, or block reading what is there.
3. If it fails, stop and show explicit recovery UI with real choices:
   **Reconnect** and **Choose another server**. Choosing another server while
   the automatic attempts are still running ends them.

**No infinite retry loops.** Retrying forever drains the battery and replaces a
decision the user could make with a spinner they cannot act on.

**The count is the person's to choose, inside a fixed bound.** The server block
offers the number of automatic attempts as a setting: **1 to 10, default 3**.
The bound is part of this contract, not a UI detail — no value outside it is
stored or used, and there is no "unlimited". The backoff schedule does not
change with it. A new count applies from the next reconnect; one already running
keeps the count it started with. The setting belongs to the device, like the
theme, and is not part of the portable profile.

A successful reconnect performs, in order:

1. retry the endpoint;
2. verify LocalCanvas identity;
3. verify API compatibility;
4. verify ComfyUI readiness;
5. refresh the workflow registry;
6. restore editable UI state.

## State that must survive

Across reconnect, fold/unfold and configuration change:

- the prompt text;
- the selected workflow;
- all Advanced values;
- selected media references, **while still valid** — an Android URI whose
  permission has lapsed is dropped, and the field returns to empty with the
  requirement visible, rather than failing later at upload;
- the previously completed result.

A user who typed a long prompt and lost Wi-Fi does not retype it.

If a refreshed registry no longer contains the selected workflow, say so and
keep the prompt; do not silently substitute another workflow. A workflow whose
fields changed on the PC opens with the new fields, keeping what still fits and
dropping what does not.

## Job recovery

Every submitted generation has a gateway-side `job_id`. It is the only thing
that makes recovery possible, so the client records it **the moment the submit
response arrives**, before anything else can fail.

It is held in session memory, not written to storage. That is deliberate — the
app keeps no history and no database (`docs/ui-ux.md`) — and it is also the
limit of this feature, stated rather than left to be discovered: recovery
survives a dropped connection, a reconnect, a fold and a configuration change,
and it does **not** survive Android killing the process. A relaunched app has no
job id and starts from nothing.

On reconnect with a job in flight, the client calls
`GET /api/v1/jobs/{job_id}`:

| Result | Meaning | Action |
|---|---|---|
| `running` | survived, still working | resume following it; re-attach the stream |
| `completed` | finished while we were away | show the result |
| `failed` | failed while we were away | show the error |
| `cancelled` | cancelled | show it as cancelled |
| `404` | gateway lost the job | report loss honestly |

### Honesty rule

**Never claim to resume a generation unless backend state proves it exists.**
No optimistic "still generating..." based on a client-side timer, and no
inferring survival from the gateway merely being reachable again. The snapshot
is the proof, and its absence is also an answer.

When a gateway or machine restart destroyed job state, the app says exactly:

> Generation state could not be recovered.

and offers **Generate Again** and editing the inputs — with the inputs still
populated, because they survived.

## Cancellation

Where the backend supports it (`capabilities.cancel`), Cancel is offered.
The resulting state is whatever actually happened: a job that completed before
the interrupt landed is reported as completed, with its result. **A cancel
request is not a cancelled outcome**, and the UI never asserts one for the other.

Where cancellation is unsupported, the affordance is absent rather than present
and inert.

## Progress

Real progress only, from ComfyUI's own reporting. When there is none, the UI is
honestly indeterminate. **Percentages are never fabricated**, and neither are
time estimates.
