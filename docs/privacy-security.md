# Privacy and security contract

## What LocalCanvas contains

**None of:** telemetry, analytics, crash-reporting SaaS, cloud generation
providers, remote relays, account requirements, or any cloud dependency for
normal generation.

Normal generation must work **with WAN unavailable**. That is a claim to be
*proven by running the procedure below*, not one to be asserted from the
architecture — and until someone has run it, the honest form of the sentence is
"designed to", not "does". At v0.1 acceptance that procedure had not been run:
it needs a phone, a router and someone to unplug the uplink. Say so wherever the
claim appears rather than letting the design stand in for the evidence.

## Accurate public wording

The sentence the project uses, and the reason it is worded this way:

> LocalCanvas itself requires no cloud service and communicates only with the
> configured LocalCanvas gateway during normal operation.

It is a claim about **LocalCanvas's own code**. It is scoped deliberately.

**Do NOT claim** that LocalCanvas guarantees third-party ComfyUI custom nodes
never reach the Internet. It cannot. Custom nodes are arbitrary code in someone
else's process: they can download models, phone home or check for updates, and
LocalCanvas neither sandboxes nor inspects them. Any wording implying otherwise
is a defect in the documentation and must be fixed like one.

Architecture is not proof of zero egress. Do not confuse the two anywhere in
the repository, in the README, or in a release note.

## LAN-first deployment posture

    Android app ──LAN──► Gateway ──localhost──► ComfyUI ──► GPU
                          │
                    the only LAN-facing surface

- **ComfyUI is preferably bound to localhost** (`127.0.0.1`). It has no
  authentication and should not be on the LAN.
- **The gateway is the single LAN-facing surface.** It binds `0.0.0.0` (or a
  chosen interface) on its configured port because a phone must reach it.
- The gateway has **no authentication in v0.1**. Its threat model is therefore
  explicitly *a trusted home LAN*, and the README says so plainly rather than
  implying a security property it does not have.

Exposing the gateway to the Internet is out of scope and is documented as
unsupported. Remote access, authentication, certificate management, reverse
proxy configuration and Internet threat modelling are v0.1 non-goals
(`docs/transport-boundary.md`).

## Hardening guidance to provide

- Recommend ComfyUI bound to localhost, and have `doctor.ps1` **report when it
  is not**.
- Windows Firewall guidance: allow the gateway port on Private networks only,
  never on Public.
- `doctor.ps1` reports posture. It names, in these words: **ComfyUI binding**
  (and separately a `--listen` argument that contradicts it), the **endpoint** a
  phone would use and whether that endpoint is actually on the LAN, the
  **firewall** profile for the gateway port, the **LAN address**, **mDNS**, and
  the **strict LAN mode** state. Reading the firewall port filters needs
  elevation on Windows; without it doctor says so and says what to check by
  hand, rather than reporting a posture it could not see.
- **Strict LAN mode** — a real machine-level enforcement mechanism, below.

## Strict LAN mode (required capability)

Firewall *guidance* tells a user what to do. **Strict LAN mode actually does
it**, at the Windows firewall level, and can be undone.

This is a required v0.1 capability. It is *optional for a public user to
enable* — most people will never touch it — but it must be implemented and
verified, because being able to put the generation machine into a state where
no traffic leaves the local network is a primary requirement of this project.

    scripts/strict-lan.ps1 enable
    scripts/strict-lan.ps1 status
    scripts/strict-lan.ps1 verify
    scripts/strict-lan.ps1 disable

The exact command shape may be refined during implementation; the semantics
below may not.

### Semantics

**`enable`** — block non-local / WAN traffic at the machine firewall level,
while preserving everything LocalCanvas actually needs:

- the LAN path between phone and gateway on its configured port;
- local mDNS / DNS-SD discovery, where technically possible;
- local infrastructure the machine cannot function without — DHCP, DNS to a LAN
  resolver, ARP/NDP, and the default gateway itself where required.

That last point is where honesty matters most. A machine that reaches its own
LAN router for DNS is not fully isolated from anything the router forwards, and
a mode that silently allowed such traffic while claiming total isolation would
be lying. **`enable` states explicitly which local infrastructure traffic it is
permitting and why**, and `status` repeats it.

Rules that bind every subcommand:

- **Reversible.** `disable` restores the prior state. Rules are created under a
  clearly identifiable LocalCanvas group so they can be found and removed
  precisely; pre-existing user firewall policy is never destroyed or rewritten
  out from under the user.
- **Never silent.** No subcommand modifies firewall policy without printing
  exactly what it is changing, before or as it changes it. Not a summary
  afterwards — the actual rules.
- **`status`** reports whether strict mode is on, which rules LocalCanvas owns,
  and what is permitted. Read-only.
- **`verify`** is the proof step, and it must prove **both halves**: that the
  configured LocalCanvas LAN path still works while strict mode is enabled,
  **and** that non-local connectivity is actually unavailable. Neither half is
  sufficient alone — a mode that blocks everything including the phone is not a
  success, and a mode that reports "enabled" while WAN still works is worse.
  `verify` reports what it tested and what it could not test.
- Elevation is required to change firewall policy. A subcommand that needs it
  and does not have it says so plainly rather than half-applying a policy.
- **The collateral effect is disclosed.** This is a *machine-level* control: it
  blocks non-local traffic for everything on that PC, not just for ComfyUI —
  the browser, Windows Update and every unrelated application lose Internet
  access while it is enabled. `enable` says so before applying, `status` repeats
  it, and the README says it too. A feature whose rule is "never change anything
  without saying what it changed" cannot leave its most visible consequence
  unsaid.

### Plan first — every subcommand has a dry run

Every subcommand takes `-Plan`. It computes and prints exactly what the
subcommand would do and changes nothing at all:

    ./scripts/strict-lan.ps1 enable -Plan     # the rules, in full, applied to nothing
    ./scripts/strict-lan.ps1 disable -Plan    # exactly which rules would be removed
    ./scripts/strict-lan.ps1 verify -Plan     # what it would probe, probing nothing

Read `enable -Plan` before you ever run `enable`. It is the same computation the
real run uses — the rule set is a pure function of your configuration and this
machine's addresses, routes and resolvers — so what it prints is what you get.

`-Json` prints the same thing as one machine-readable document. `-FactsFile`
plans against a *described* network instead of this one, which is useful for
seeing what would happen elsewhere; a plan computed that way is never applied.

### Documented limitations

Strict LAN mode is a **network-level control on this machine**. It is not a sandbox
and not a proof of intent, and the documentation must say so:

- It constrains traffic; it does not inspect or vet code. A custom node still
  runs with whatever access the firewall leaves open.
- Anything permitted for the LAN to function is, by definition, permitted —
  including whatever a LAN DNS resolver or router chooses to forward. Strict
  mode permits your default gateway at its own address, so a name your router
  resolves recursively is still resolved.
- It governs this machine only. It says nothing about the phone, the router, or
  any other device on the network.
- The rules are a **snapshot** of the addresses, routes and resolvers this
  machine had when you enabled them. Move the PC to another network, or take a
  DHCP lease in a different subnet, and the permitted LAN in those rules is the
  old one — the phone will stop reaching the gateway. `status` prints the
  subnets the rules were built for; `disable` then `enable` rebuilds them.
- A resolver that is **not** on your LAN — a public DNS service configured on
  the adapter, say — is not permitted, and `enable` names it before applying.
  Name resolution through it will fail while strict mode is on. That is the
  honest trade: permitting it would be a hole through the middle of the feature.
- It is not a substitute for the WAN-disabled verification below, which tests a
  physically different condition. Strict mode blocks egress from inside;
  unplugging the uplink removes the path entirely. Both are documented, and
  neither is presented as the other.

**Strict LAN mode still does not let LocalCanvas guarantee that arbitrary
third-party ComfyUI custom nodes never access the Internet.** It makes such
access *fail* while enabled on this machine, which is a different and weaker
claim than a guarantee about the code itself, and the wording must stay weaker.

## The WAN-disabled verification procedure

This is the v0.1 acceptance test for "normal generation works with WAN
unavailable". It needs no elevation, changes nothing on the PC, and takes about
fifteen minutes. Follow it exactly; each step says what a pass looks like.

**What you need:** the PC with ComfyUI, the phone with LocalCanvas installed,
both on the same LAN, and physical access to whatever provides your Internet
connection.

1. **Check the posture, with the Internet still up.**

       ./scripts/doctor.ps1

   Read the report. `ComfyUI binding` must say **localhost only** — if it says
   `NOT bound to localhost`, stop and fix that first (`comfy.host` in
   `config/local/runtime.yaml`, and any `--listen` in `comfy.extra_args`).
   `LAN address` must show an address. Note it; that is what the phone will use.

2. **Start LocalCanvas and pair the phone.**

       ./scripts/start.ps1

   Scan the QR code, or type the endpoint the script printed. Confirm the app
   connects and the workflow registry loads. Everything from here on is the
   same session — do not restart anything.

3. **Take the Internet away, and leave the LAN up.** Unplug the WAN cable from
   the router, or turn off the router's Internet connection (often "disconnect"
   or "disable WAN" in its admin page). Do **not** turn off Wi-Fi, and do not
   unplug the PC or the phone: the LAN itself must keep working, or the test
   proves nothing about LocalCanvas.

   Confirm the Internet really is gone: on the phone, open any web page in a
   browser and see it fail. Confirm the LAN is still up: the app must still show
   the gateway as connected.

4. **Run the three generations, end to end.** From the phone, in this order:

   - a **prompt-only** workflow — text in, image out;
   - an **image-input** workflow — pick a photo from the phone, generate;
   - a **video-input** workflow — pick a clip from the phone, generate.

   Each must run to completion and show its result. Progress must update as it
   runs, not jump from nothing to done.

5. **Save and share a result.** Use the app's own save action to write a result
   to the phone's gallery, then share it to any offline target (a file manager,
   for instance). Confirm the saved file opens.

6. **Reconnect the WAN** and confirm the app keeps working. This is not part of
   the claim, but it catches a machine left in an odd state by step 3.

If any step needed the Internet, it failed. Say which step, and why.

**What this proves:** LocalCanvas's own operation needs no WAN — the app, the
gateway, discovery, pairing, generation, progress, results and saving all work
with the uplink physically gone.

**What it does not prove:** that a given ComfyUI custom node never egresses. A
node that downloads a model on first use will simply fail with the WAN down,
which is a fact about that node, not about LocalCanvas. Report the distinction;
do not blur it. And a **pass** here says nothing about what those nodes do when
the Internet *is* available — that is exactly the claim LocalCanvas does not
make.

### It is a different test from `strict-lan.ps1 verify`

Both are **to be** run, and neither substitutes for the other. Neither had been
run at v0.1 acceptance: the procedure needs a phone, a router and an unplugged
uplink, and a live `verify` needs strict mode actually enabled, which needs
elevation. Written as a requirement on whoever releases this, not as a record of
something that happened.

| | What it does | What it shows |
|---|---|---|
| WAN-disabled procedure | Removes the path entirely | LocalCanvas needs no Internet at all |
| `strict-lan.ps1 verify` | Leaves the path and blocks egress from inside | The machine's own firewall is really enforcing LAN-only, and the LAN path still works |

`verify` proves both halves — that the LocalCanvas LAN path still works while
strict mode is enabled, **and** that non-local connectivity is unavailable — and
prints what it could not test, which includes: only outbound TCP to a handful of
public addresses was attempted; a failed connection is equally consistent with
having no Internet at all; whatever the router forwards on this machine's behalf
is permitted by design; and nothing about the phone, the router or any other
device on the network was tested.

## Data handling

- Uploaded media is temporary, gateway-managed, and not a library. No
  server-side media library, no database-backed history.
- **One exception the user should know about, because it is theirs to clean.**
  Getting an input file to a loader node means handing it to ComfyUI's own
  upload endpoint — the only way that does not require LocalCanvas to know
  ComfyUI's filesystem layout, which `docs/architecture.md` forbids. ComfyUI
  then keeps that file in its input directory, and exposes no way to delete it.
  So LocalCanvas *asks* for a **single `localcanvas/` subfolder** of that
  directory — `subfolder` on `POST /upload/image` is a request, not a location,
  and ComfyUI answers with where it actually put the file. LocalCanvas never
  writes into ComfyUI's filesystem itself and never composes a path into it. The
  files accumulate, LocalCanvas cannot reap them, and asking for one folder is
  what makes them clearable in one action. This is documented rather than
  quietly true.
- Results live in the current session and in whatever the user explicitly saves
  to their own device.
- LocalCanvas sends no identifier about the user or their machine anywhere: it
  talks only to the configured gateway, and the gateway talks only to ComfyUI.
  This is a statement about LocalCanvas's own traffic — **not** a claim that
  nothing at all leaves the machine, which would contradict the custom-node
  limitation above.
- The QR payload carries connection information only, never a secret
  (`docs/connection.md`).
- **One third-party manifest entry, disclosed because our claims are precise.**
  The Android photo-picker plugin merges a disabled
  `com.google.android.gms.metadata.ModuleDependencies` service into the app's
  manifest, which asks Play services to install the backported photo-picker
  module. It is not LocalCanvas's code and it is not part of generation — normal
  generation still works with WAN unavailable, which is a runtime fact the
  WAN-disabled procedure tests — but it is a Play-mediated fetch that arrives
  with the app, and this project's wording is careful enough that it should be
  written down rather than left for someone to find in a merged manifest.
- **The share sheet adds a `FileProvider` and a broadcast receiver** to the
  merged manifest under this app's id. That is how Android's native share works —
  a receiver is how the system tells the app which target the user picked — and
  it carries no permission and no network of its own. Listed for the same reason
  as the entry above: this project's claims are narrow enough to be checked, so
  what ships should be findable in a document rather than only in a manifest.
- **The profile import's document picker adds nothing.** `file_selector`
  (via `file_selector_android`) contributes only a `uses-sdk` element to the
  merged release manifest — no permission, component or query — measured from the
  manifest merger's report of the 2026-09-16 release build. On Android it opens
  the system document picker, which grants access to the one file the user
  chooses.
- **Playing a clip result adds `android.permission.WAKE_LOCK`.** It
  comes from ExoPlayer (`androidx.media3:media3-exoplayer`, via `video_player`),
  not from LocalCanvas's code, and it is a normal install-time permission — no
  prompt — that lets playback hold the device awake. The player is handed a file
  the app already fetched from the gateway and makes no network request of its
  own. A before/after diff of the merged release manifest showed this as the
  only addition.

## Converting a workflow through the user's own ComfyUI

Importing a workflow saved in ComfyUI's **editor** format requires converting it
into the **API** format that actually executes. LocalCanvas does not and must not
do that itself: only the exact ComfyUI build that saved the graph knows its
installed custom node definitions, widget semantics and subgraph behaviour, and a
wrong guess runs and produces the wrong result silently. So the conversion is
performed by the user's own ComfyUI frontend, loaded in a browser LocalCanvas
drives locally (`docs/runtime.md`).

That capability creates an egress surface the rest of this document does not
cover, because for the first time **LocalCanvas itself causes third-party code to
run**: ComfyUI's frontend, every custom node's JavaScript, and whatever a browser
extension or resident security product injects into the page. Measured on a
developer machine while converting real workflows, an unmitigated page reached a
vendor release endpoint, issued a request to a public model host **naming a model
taken from inside the user's own workflow**, and had a script injected into it by
an antivirus agent.

A workflow's contents are the user's. Leaking them to a public host as a side
effect of *importing* them would contradict the claim at the top of this
document, so:

- **The browser LocalCanvas launches for conversion resolves nothing but
  loopback.** Non-loopback name resolution is disabled for that browser instance,
  so the page can reach the user's own ComfyUI and nothing else. This is a
  requirement, not a hardening option, and it is tested.
- **The browser is one already installed on the machine.** LocalCanvas downloads
  no browser, no frontend, no custom node and no model, and it never reaches the
  Internet to obtain any of them.
- **The profile is temporary and owned by the run**, and is removed afterwards.
  The user's own browser profile, history, extensions and sessions are never
  used.
- **Nothing is queued or generated in order to export.** Conversion asks the
  frontend what the graph *would* submit; it never submits it.
- **Source workflow files are opened read-only and are never rewritten**, and
  what LocalCanvas produces from them lives only under `config/local/`.

The honest scope of the claim is the same as everywhere else in this document: it
says that the browser LocalCanvas launches cannot resolve a non-loopback name. It
is **not** a claim about ComfyUI's own Python process, which is the user's and
may reach the network as it always could.

## Repository hygiene

`config/local/` and `.runtime/` are gitignored. **The public repository must
contain no original-developer machine configuration**: no real paths, no model
names, no personal workflow ids, no LAN addresses beyond illustrative examples.
This is checked at v0.1 acceptance.
