# Connection, discovery and pairing contract

The app's entire connection state is one **base endpoint**. Four ways to get one;
none is privileged in the API layer (`docs/transport-boundary.md` §5).

## Endpoint normalization

Accepted and normalized:

| Input | Normalized |
|---|---|
| `192.0.2.42` | `http://192.0.2.42:7801` |
| `192.0.2.42:7801` | `http://192.0.2.42:7801` |
| `http://192.0.2.42:7801` | unchanged |
| `https://generation.example.com` | unchanged, port implied by scheme |

Default scheme `http`. Default port `7801`, applied when a port is absent **and
the scheme is (or defaults to) `http`** — an explicit `https` endpoint implies
443 and is left alone, which is why the table above shows
`https://generation.example.com` unchanged. Read per-component the two rules
looked contradictory; this is the reading that makes every row above true, and
it is the one the client implements.

Trailing slashes and an accidentally pasted `/api/v1` suffix are trimmed. IPv6
literals in brackets are accepted.

**Rejection is for input this client cannot express** — never for being public,
non-RFC1918 or HTTPS. That means unparseable text, a scheme other than `http` or
`https`, and an address carrying credentials (v0.1 has no authentication, and
silently dropping a userinfo component would connect somewhere the user did not
ask for). Nothing else is refused, and the UI may note that v0.1 officially
targets local deployments without enforcing it by refusing input.

## 1. Remembered endpoint

The last endpoint that *successfully completed the identity handshake* is
persisted (endpoint, display name, last-success time). On launch:

1. Try it, with a **short bounded** attempt — a few seconds, not a spinner
   forever.
2. On success, go straight to the app. This is the common case and must feel
   immediate.
3. On failure, one short bounded retry (the router-just-woke-up case).
4. Then fall through to discovery.
5. Manual entry always remains available as a fallback.

**No infinite reconnect loops.** Bounded attempts, then an explicit UI with a
decision for the user.

Only a successful handshake updates the remembered endpoint — a typo the user
never connected to is never persisted over a working one.

## 2. mDNS / DNS-SD discovery

Service type — the DNS-SD type `_localcanvas._tcp` in the `.local` domain. Its
two halves spell it differently and both are correct: the gateway registers the
fully-qualified `_localcanvas._tcp.local.` that `zeroconf` requires, and the app
asks Android's own DNS-SD stack for the bare `_localcanvas._tcp` that
`NsdManager` requires. Same service, two API spellings; neither side may be
"corrected" into the other's form.

    _localcanvas._tcp.local.     as the gateway registers it
    _localcanvas._tcp            as the Android client asks for it

TXT metadata, small and useful only:

| Key | Meaning |
|---|---|
| `name` | configured `identity.display_name` |
| `port` | gateway port |
| `version` | gateway version |
| `api` | API version |

No cloud discovery. No external registry. No Firebase. No account-based pairing.

The app lists discovered gateways by display name. **A discovered service is a
candidate, not a connection**: the identity handshake still runs before the
endpoint is accepted or persisted.

Discovery is expected to be unreliable in the real world — some Android
networks, some routers and some VPN configurations suppress multicast. That is
a normal outcome, not a bug, and the UI must degrade to QR and manual entry
without dead-ending. Discovery is never a dependency of the API layer.

**But a failure must always say why.** "Expected to be unreliable" is precisely
what let a real defect hide: the app shipped asking Android for DNS-SD without
declaring the permission that allows it, failed on every launch, and looked like
the expected kind of failure for as long as nobody could see the reason. A
discovery failure that reaches the user without its cause teaches nobody
anything — least of all when failure is normal. The reason belongs on the screen
or, at minimum, in the log, naming which stage produced it.

### The permission this requires on Android

The app must declare `CHANGE_WIFI_MULTICAST_STATE`. Android's Wi-Fi stack drops
multicast frames not addressed to the device unless a `WifiManager.MulticastLock`
is held, and below T extensions 7 the app must take that lock itself. The DNS-SD
plugin takes it on the app's behalf — but only if the permission is granted, and
it refuses to start a discovery at all otherwise, throwing before it reaches
`NsdManager`. There is no version check on that refusal, so it applies to every
Android this app supports.

It is an install-time permission at protection level *normal*: it costs the user
nothing and shows no dialogue.

`NEARBY_WIFI_DEVICES` is **not** required and must not be declared. It governs
the Wi-Fi scanning APIs — `WifiP2pManager`, Wi-Fi Aware, RTT, local-only
hotspot — and not DNS-SD through `NsdManager`; the SDK's own
`@RequiresPermission` metadata puts it on 29 methods, none of them `NsdManager`'s.
The confusion is easy to fall into, because `WifiP2pManager` has a
`discoverServices()` of its own. Declaring it would mean a runtime permission
dialogue on a screen that asks the user for nothing, in exchange for nothing.

The permissions a build actually ships are the **merged** manifest's, not the
source manifest's — plugin manifests merge in. Check the built artifact.

## 3. Local QR pairing

Fully local. **No external QR service, no URL shortener, no cloud pairing, no
hosted redirect.**

Payload — a LocalCanvas-specific URI carrying connection information only:

    localcanvas://connect?endpoint=http://192.0.2.42:7801

It is **not** an OS-registered deep link: nothing claims the `localcanvas`
scheme in the Android manifest, and the payload is only ever read through the
app's own scanner. Registering the scheme would be a second, unscanned way in
and is not something v0.1 needs.

How to obtain it: `start.ps1` prints the payload and renders the QR **in the
terminal** (`python -m localcanvas_gateway qr --endpoint <url>` prints it on its
own). v0.1 serves no HTTP pairing page — the terminal is where the person
starting LocalCanvas already is.

App flow: scan → parse → **verify identity via the handshake** → save → connect.
A QR that parses but fails the handshake reports that plainly and saves nothing.

**No secret goes in the QR.** v0.1 has no authentication, so there is nothing to
put there, and a future authenticated remote pairing must not be built by
smuggling a credential into an ordinary URL — it would need its own security
design, which does not exist yet.

## 4. Manual entry

Always available, from every state, including as the escape hatch when discovery
finds nothing. Accepts the forms above. On a failed connection it distinguishes,
in the message the user reads:

- **unreachable** — nothing answered;
- **not a LocalCanvas server** — something answered but failed the handshake;
- **incompatible version** — a gateway, wrong API version, both named;
- **ComfyUI unavailable** — a healthy gateway whose backend is down
  (`docs/recovery.md`).

## Identity handshake

Every path ends in `GET /api/v1/info` (`docs/api.md`). Verified: `service` is
exactly `localcanvas`, `api_version` is supported, and `comfy.status` is
recorded. **An arbitrary HTTP endpoint is never treated as a compatible
gateway.**
