# Contributing

LocalCanvas is a small project that reaches v0.1 and then enters maintenance
mode: bug fixes, security fixes and minimal compatibility fixes. Please read
[README.md](README.md)'s *What it is not* before proposing a feature — the
non-goals there are binding, not aspirational.

## Getting a development environment

On Windows, with PowerShell 7+ and Python 3.10–3.13:

```powershell
pwsh .\scripts\setup.ps1 -Dev
```

`-Dev` installs the gateway's test extra alongside it. It creates `.venv/` at the
repository root, selects a base interpreter explicitly, and prints which one it
chose. It never installs anything into ComfyUI's Python.

With no `config/local/runtime.yaml` yet it also asks the two questions
[README.md](README.md) describes and writes that file. None of the three test
suites reads it, so a contributor who has no ComfyUI at all can answer in advance
and be asked nothing:

```powershell
pwsh .\scripts\setup.ps1 -Dev -Mode External
```

That run writes a configuration with no ComfyUI in it, says so in its status
table, and exits 0.

## Running the tests

There are three suites, and none of them needs a GPU, a model, a phone or a real
ComfyUI.

### The gateway

```powershell
.\.venv\Scripts\python.exe -m pytest gateway\tests
```

Everything the ComfyUI client does is exercised against a protocol-faithful fake
that speaks real HTTP on a real socket, so nothing here is a stub of the code
under test. Tests that genuinely need a real ComfyUI, a real browser or machine
state outside the test's control mark themselves `integration` and skip with the
reason printed, unless `LOCALCANVAS_INTEGRATION=1` is set.

### The app

```powershell
cd app
flutter pub get
flutter analyze
flutter test
```

`flutter analyze` must come back with no issues; it is part of CI and not
advisory. The Kotlin side of the Android project has no automated tests of its
own — that is a known gap, stated rather than papered over.

### The PowerShell runtime scripts

This suite drives the real scripts against stub backends, in throwaway
directories. Run it with a **plain** interpreter, never
`.venv\Scripts\python.exe`: it shadows the gateway with a stub on `PYTHONPATH`,
and one of its tests works by removing that stub, which an interpreter carrying
the installed gateway defeats. The suite refuses such an interpreter rather than
producing a misleading pass.

Run one group at a time, the way CI does:

```powershell
python scripts\tests\run_tests.py --ci-group comfy-models
```

An unknown or missing group name exits 2 and prints the list. Running the script
with no `--ci-group` runs every group in one process; the suite's own notes put
that at about an hour on the machine it was measured on, and a single group at up
to about six minutes, so a group is what you want while you work.

## What CI runs

`.github/workflows/ci.yml`, on `windows-latest`, for every push to `main` and
every pull request:

| Job | What |
|---|---|
| `gateway` | `pytest`, on Python **3.10** and **3.13** — the floor and the ceiling of `requires-python`. |
| `app` | `flutter pub get`, `flutter analyze`, `flutter test` on the pinned Flutter version. |
| `scripts` | `run_tests.py --ci-group <name>`, one job per group, thirteen in parallel. |

Nothing in CI talks to a real ComfyUI, a developer's network or a self-hosted
machine, and nothing uses a secret. `LOCALCANVAS_INTEGRATION` is deliberately not
set there, so the integration class stays skipped.

Every test class belongs to exactly one script group, and the suite holds that
itself — a new class cannot silently fall out of CI.

A second workflow, `.github/workflows/apk.yml` (**APK** in the Actions tab),
builds the Android app: `flutter build apk --release --split-per-abi` on
`windows-latest`, attached to the run as the artefact
`LocalCanvas-apk-debug-signed` and kept for 14 days. It runs on push to `main`
and on demand, **not** on pull requests, and it is a workflow of its own so a
build that takes minutes does not stand in front of the test signal. It uses no
secret either: there is no release signing in this project, so what it attaches
is debug-signed, exactly like a release build on your own machine
([README.md](README.md) says what that means for installing one).

## The contracts worth knowing before you change anything

`docs/` holds the design contracts the implementation is held to. A change that
contradicts one of them is a change to that document first, deliberately, not in
passing.

| Contract | File |
|---|---|
| Architecture and component boundaries | `docs/architecture.md` |
| Why LAN-first is policy, not protocol | `docs/transport-boundary.md` |
| Gateway ↔ app API | `docs/api.md` |
| Workflow registry and field schema | `docs/workflow-schema.md` |
| Startup, process ownership, the scripts | `docs/runtime.md` |
| Pairing, discovery, QR | `docs/connection.md` |
| Reconnect and job recovery | `docs/recovery.md` |
| Visual direction, startup, foldables | `docs/ui-ux.md` |
| Privacy claims, strict LAN mode | `docs/privacy-security.md` |
| The v0.1 acceptance checklist | `docs/definition-of-done.md` |
| Versioning and compatibility | `docs/versioning.md` |

Four rules from those documents come up in almost every change:

1. **Generic by default, personal by configuration.** No developer's path, model
   name, custom node, workflow id or node id may appear in source, defaults,
   examples or documentation. Machine-specific values live in `config/local/`,
   which is gitignored; public examples live in `config/examples/`.
2. **No model family is named in application logic** — not in the app, not in the
   gateway. The app understands field *types* and *presentation*, never model
   families.
3. **An unrelated user must never have to change source code to run
   LocalCanvas.** Anything a user must edit is configuration.
4. **The app and the gateway are one product.** They share a minor version and a
   single `api_version` with an exact match and no negotiation; `docs/versioning.md`
   says what a breaking change costs.

Three more decide what the code may touch:

5. **Only what the user names is read.** The workflow importer reads the folders
   its sources file lists and nothing else — no scan of the machine, no walking
   up from a folder, no path followed out of a workflow file — and a source
   workflow is only ever read. A workflow that cannot be read with confidence is
   held as `NEEDS_REVIEW`, never guessed, and nothing leaves the catalogue
   automatically. Test fixtures are invented, or are trimmed captures of what
   ComfyUI's HTTP API declares; they are never files copied out of an
   installation or a user's workflow, and they name no model family.
6. **A user's ComfyUI is theirs.** LocalCanvas never installs into ComfyUI's
   Python and never writes inside a ComfyUI it did not install; the optional
   `comfy/` bootstrap writes only where it is told to install and to keep
   models, and refuses any of those that lies inside a ComfyUI it did not
   install. Otherwise HTTP is the only coupling. The gateway runs from
   LocalCanvas's own `.venv/`, and a script names the interpreter it uses
   rather than letting `py` pick one
   ([docs/runtime.md](docs/runtime.md#python-environments)).
7. **Nothing is built ahead of a need.** No abstraction for a hypothetical
   feature: a container for one setting, a credential store or a history nobody
   asked for waits until there is something real to put in it.

### Test safety

The suites run on contributors' own machines, next to their real ComfyUI.

- **Ephemeral loopback ports only.** An ordinary test never binds or contacts a
  real ComfyUI or gateway, including one on the default ports of the machine it
  runs on; only the opt-in `integration` tests described above use a real
  ComfyUI. In the gateway suite, `gateway/tests/conftest.py` makes an ordinary
  test that connects to port 8188 or 7801 fail before the socket connects.
- **Break a copy, never the tree.** A test that proves a guard by breaking the
  code breaks a copy in its own temporary directory, or patches it in memory for
  one block. Where the broken copy could do real damage — end a process, delete
  a directory, install a package, wait on standard input — the dangerous call is
  disarmed in the copy, and the copy is checked for it before anything runs it.
- **Nothing real is named.** A mutation or a fixture never points at a real
  location — a home directory, a browser profile, `Program Files` — only at the
  test's own workspace and the system temporary directory.
- **Delete only what you made.** Code that deletes checks where it is first, and
  touches only what it created itself.
- **Stop only what LocalCanvas started, and never by name**
  ([docs/runtime.md](docs/runtime.md#process-ownership)).
- **A test that cannot measure something skips**, naming what was therefore not
  verified; it never passes in silence.

## Reporting things

- **Security problems**: not an issue — see [SECURITY.md](SECURITY.md).
- **Bugs**: say what you ran, what you expected, what happened, and the exit
  code. `scripts\doctor.ps1`'s output is usually the most useful single thing to
  include, and it is read-only.
- **Please do not paste** your `config/local/` files, private workflows or
  credentials into a public issue.

## Licence

By contributing you agree that your contribution is licensed under the MIT
licence in [LICENSE](LICENSE).
