# Versioning and compatibility contract

The app and the gateway are shipped from one repository but installed
separately: the gateway lives on a PC, the app on a phone, and they are updated
by different acts on different days. So a person will, sooner or later, point
some app at some gateway. This document says which pairs are allowed to work,
which are refused, and what a change to either side costs.

## Three numbers, three different jobs

| Number | Where it lives | What it is for |
|---|---|---|
| `api_version` | integer, `GET /api/v1/info` | **The compatibility gate.** The only number that decides whether an app and a gateway will talk. |
| `gateway_version` | semver, `GET /api/v1/info` | What the gateway *is*. Reported to a person, never branched on. |
| app version | semver, `app/pubspec.yaml` | What the app *is*. Shown to a person and used to name the APK. |

**Only `api_version` gates anything.** `gateway_version` and the app version are
labels: they tell a person what they have, they appear in a bug report, and they
name a file. No code decides anything from them, and none should start.

That split already exists in the implementation and this document does not
introduce it: `kSupportedApiVersion` in `app/lib/connection/gateway_identity.dart`
is compared for exact equality, and `docs/api.md` requires that a gateway
reporting a different version is "reported as incompatible with the versions
named, not silently used".

## The compatibility rule

> **An app and a gateway work together if and only if their `api_version`
> matches exactly. Nothing else is consulted, and no mismatch is worked around.**

A mismatch is a refusal that names both numbers, not a degraded mode. This is
deliberate: the alternative is an app that half-works against a gateway it does
not understand, which is a worse failure than not connecting, and harder to
report.

## Which change moves which number

**A new feature that adds to the wire and breaks nothing** — a new optional
field, a new endpoint old clients never call, a new capability. `api_version`
does **not** move. The feature is announced in `capabilities` **where there is an
affordance to hide** — an absent key already means "not offered"
(`docs/api.md`), so an older app simply does not show the button, the picker or
the socket. Move the changed side's own semver and ship it alone.

Not every additive change has one. A gateway that answers a request header an
older client never sends is offering nothing a client could show or hide: the
old client gets what it always got, and a client that wants to know can send the
header and compare. `capabilities` is for affordances, not for an inventory of
everything the server can do. The first real case in this project was a
header-driven addition where announcing it would have described a capability no
button depends on.

**A change that an older app cannot survive** — a field removed or renamed, a
meaning changed, a response reshaped, a request the gateway will no longer
accept. `api_version` moves by one. Every older app is now refused, by name.

**A fix that changes nothing on the wire.** Patch version of the side that
changed. Nothing else moves, and the two sides need not move together.

## The shared minor line

> **The app and the gateway share a minor version. Two components with the same
> `0.MINOR` are designed to work together and agree on `api_version`. Patch
> numbers move independently.**

So `app 0.2.3` and `gateway 0.2.0` are a supported pair; `app 0.1.7` and
`gateway 0.2.0` are not, and the refusal will say so. A person does not have to
know what `api_version` is — they compare the two middle numbers.

**Never ship a minor in which the two disagree on `api_version`.** That is the
whole content of the rule and the one thing to hold.

## Breaking the contract on purpose: the sequence

This is the case that prompted the rule, and the order matters.

1. **Bump `api_version` in the gateway** as part of the change that breaks it.
   Every existing app is now refused. That is correct and is the point: the
   refusal is loud, immediate, and names both versions.
2. **Implement the app side against the new `api_version`.** This is the step
   that restores compatibility.
3. **Bump both to the same new minor** — `0.2.0` on each — and ship them
   together.

**Bumping a version number never restores compatibility.** Implementing the
contract does. The version bump is how the repository *records* that the work
was done, so that a person holding two artifacts can tell without reading code.
A version raised ahead of the implementation is a lie in the one place a person
has no way to check.

**Steps 1 and 2 may sit in one card or several, but they land together.** `main`
is not left in a state where the app in this repository cannot talk to the
gateway in this repository. If a breaking change is large enough to want
splitting, split it behind the bump: `api_version` moves in the commit that
completes the pair, not in the one that starts it.

## What this deliberately does not do

- **No version negotiation.** The gateway does not serve two API versions at
  once, and the app does not speak two. One number, exact match. A compatibility
  shim is a subsystem, and this project's scope rules forbid building one for a
  hypothetical future.
- **No compatibility range.** No "app supports api_version 1–2". The moment a
  range exists, every future change has to be reasoned about against every
  member of it, and the refusal message stops being simple.
- **No independent product names.** The app and the gateway are one product with
  two halves. They do not get separate release cycles or separate changelogs.

## Where the numbers are set

| | |
|---|---|
| `api_version` served | the gateway's `/api/v1/info` handler |
| `api_version` accepted | `kSupportedApiVersion`, `app/lib/connection/gateway_identity.dart` |
| gateway semver | the gateway package's own version |
| app semver | `version:` in `app/pubspec.yaml` — also the APK filename |

Changing `api_version` means changing **both** of the first two, in the same
change. One without the other is the defect this document exists to prevent.

## v0.1

At v0.1 the state is: `api_version` is **1**, the gateway is **0.1.x**, the app
is **0.1.x**, and they agree. The app's version carried Flutter's template
`1.0.0` for a while before it was corrected — which was harmless only because
nothing branches on it, and is exactly the kind of drift the table at the top of
this document exists to stop.
