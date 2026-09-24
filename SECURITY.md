# Security

## What LocalCanvas is designed for

A **trusted home LAN**, and nothing wider. v0.1 has **no authentication**, and
that is a design decision rather than an omission: the whole product is one
gateway on your own network, reachable by your own phone.

- ComfyUI should stay bound to `127.0.0.1`. `scripts\doctor.ps1` checks that
  binding and tells you when it is wrong.
- The **gateway is the only LAN-facing surface**. Allow its port through Windows
  Firewall on **Private** networks only, never on Public.
- **Do not expose the gateway to the Internet.** Remote access is not supported
  in v0.1 and no part of it has been built or threat-modelled. There is no
  account system, no token system and no reverse-proxy management, deliberately.

An optional, reversible machine-level enforcement of LAN-only operation ships
with the project; `docs/privacy-security.md` describes it in full, including its
limits. It is a network control, not a sandbox.

## What is outside the trust boundary

**Third-party ComfyUI custom nodes.** They are arbitrary code running inside
ComfyUI's process. LocalCanvas does not sandbox them, does not inspect them and
does not pretend to. Every privacy claim LocalCanvas makes is about LocalCanvas's
own code — the app, the gateway and the scripts — and is worded narrowly for
exactly this reason.

**Your ComfyUI installation itself.** LocalCanvas never installs into it, never
writes to it and never edits its configuration; the only coupling between the two
is HTTP. What that ComfyUI does is yours to know.

**Your network.** Anyone on the same LAN can reach an unauthenticated gateway.
That is the model. If your network is not one you trust, LocalCanvas as it stands
is not the right tool.

## What LocalCanvas does not do

No telemetry, no analytics, no crash reporting, no accounts, no cloud
generation, no hosted QR or pairing service. The claims and the evidence for each
are in `docs/privacy-security.md`, including the two third-party Android
components that ship with the app and what they add to its manifest.

## Reporting a problem

Report security problems through **GitHub's private vulnerability reporting** on
this repository (the *Security* tab → *Report a vulnerability*). That keeps the
report private until there is something to say publicly. There is no separate
mailbox for this project.

When you report, please **do not attach**:

- your `config/local/` files, or any part of them — they hold your paths and your
  machine's layout;
- private workflow files, definitions or API-format graphs;
- API keys, tokens or credentials of any kind;
- full logs without reading them first.

A description of what happens, the exit code, and the one line that matters are
almost always enough. If a reproduction genuinely needs a workflow, reduce it to
the smallest one that still shows the problem.

## Supported versions

v0.1 is the current release, and the project enters maintenance mode at it: bug
fixes, security fixes and minimal compatibility fixes. Older pre-release states
are not supported.

`docs/versioning.md` explains how the app and the gateway are kept compatible —
one `api_version`, exact match, no negotiation — so an update to one half tells
you plainly when the other must move too.
