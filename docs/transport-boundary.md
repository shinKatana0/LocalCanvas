# Transport independence boundary

## The rule

**LAN-only operation is a v0.1 deployment and security policy. It is not a
property of the application protocol.**

v0.1 ships LAN-first and must work fully with WAN unavailable. But the contracts
between app and gateway are written so that pointing the app at

    https://generation.example.com

instead of

    http://192.0.2.42:7801

would be a deployment change, not a redesign.

## What v0.1 does NOT build

No remote-access implementation. Specifically absent, deliberately: accounts,
login, authentication, OAuth, token systems, certificate management, reverse
proxy configuration or management, relays, tunnels, cloud discovery, and
"transport factory" abstractions added for a future that has not arrived.

Remote Internet access and Internet threat modelling are explicit non-goals.
A future authenticated remote deployment would need its own security design,
and that design does not exist yet. **Preserve the boundary; build nothing.**

## The five rules that preserve it

These cost nothing today and are what a future remote endpoint depends on.

### 1. One configured base endpoint, no inferred host

The app holds a single **base endpoint** — scheme, host, port. Every request
URL is derived from it. No component reconstructs a host from anything else.

Forbidden anywhere in app or gateway code: a hardcoded `192.168.*` **used as an
endpoint, a host or a default**, assumptions that the endpoint is RFC1918,
assumptions of `http` over `https`, assumptions of a non-default port,
assumptions that the transport is Wi-Fi, and any assumption that the mobile
client can reach ComfyUI or `localhost` itself. An address in a *hint*, an error
message or a documentation example is none of those things and is allowed —
telling someone what an address looks like is how the manual-entry field is
usable at all.

### 2. Scheme-derived WebSocket

The WebSocket URL is derived from the base endpoint's scheme:
`http` → `ws`, `https` → `wss`. Never hardcode `ws://`.

### 3. Relative result and media references

The gateway returns result and media references as **paths relative to the
configured base endpoint**, never as absolute URLs containing a host it guessed
about itself.

    "path": "/api/v1/jobs/j-8f21/result/0"          correct
    "path": "http://192.0.2.42:7801/api/..."      forbidden

A gateway that names its own host in a payload breaks the moment it sits behind
anything. This is the single most common way this kind of boundary is lost.

**Resolution rule.** The client resolves such a path by stripping its leading
slash and appending it to the configured base endpoint, **preserving any path
component that endpoint carries**. It does not treat the value as root-absolute
against the origin.

    base  https://generation.example.com/localcanvas
    path  /api/v1/jobs/j-8f21/result/0
    URL   https://generation.example.com/localcanvas/api/v1/jobs/j-8f21/result/0

Naive root-absolute joining would produce
`https://generation.example.com/api/v1/...` and silently drop the `/localcanvas`
prefix — the exact breakage this rule exists to prevent, arriving only once the
gateway sits behind a path-mounted proxy. Today, with a base endpoint that has
no path component, both readings agree; that is precisely why the rule has to be
written down now rather than discovered later.

The same rule applies to every path the API returns, not only results.

### 4. Validation rejects malformed input, not non-private input

Endpoint normalization accepts and normalizes:

    192.0.2.42              → http://192.0.2.42:7801
    192.0.2.42:7801         → http://192.0.2.42:7801
    http://192.0.2.42:7801  → unchanged
    https://generation.example.com → unchanged (port implied by scheme)

An endpoint is rejected only for being **unexpressible by this client** —
unparseable text, a scheme that is not `http`/`https`, or an address carrying
credentials that v0.1 has no way to honour and must not silently discard. Never
for being public, non-RFC1918 or HTTPS. The UI may *say* that v0.1 officially
targets local deployments. The client architecture must not enforce that by
rejection.

### 5. Discovery is one way in, not the way in

mDNS is one of four ways to obtain an endpoint (`docs/connection.md`). It is
never a dependency of the API layer. Removing discovery entirely must leave a
fully working app driven by a manually entered endpoint — because on a remote
deployment, that is exactly the situation.

## What is allowed to be LAN-shaped

The *deployment*, not the protocol: gateway binding guidance, Windows Firewall
guidance, mDNS advertisement, the QR payload's practical content, and the
documentation's LAN-only verification procedure (`docs/privacy-security.md`).

## Review test

For any change to the app/gateway contract, ask: *if the endpoint were
`https://generation.example.com`, would this still work?* If the answer is no,
and the reason is not authentication (which v0.1 does not have), the change has
broken the boundary.
