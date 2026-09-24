# LocalCanvas — Android app

The Flutter client. It talks to a LocalCanvas gateway over HTTP and nothing
else; the contracts it implements live in `../docs/`.

Android is the only target, so there is no `ios/`, `web/` or desktop folder.

## Working on it

```
flutter pub get
flutter analyze
flutter test
```

The tests need no device, no emulator and no gateway: the connection layer is
driven against a `dart:io` server on loopback, and discovery, storage and the
handshake all arrive through constructor arguments that a test can replace.

Developed and tested against Flutter 3.47.0 / Dart 3.13.0 (stable); the package
declares `sdk: ^3.13.0`.

Building an APK additionally needs the Android SDK licences accepted on the
machine (`flutter doctor --android-licenses`), which is a one-off legal
agreement for whoever owns it and is not something a script here will do on
their behalf. The build commands, where the APK lands and what signing you get
are in the user
guide, [`docs/user-guide.md`](../docs/user-guide.md#5-installing-the-app). A release
APK has been built here, universal and per-ABI, to verify that each one is named
`LocalCanvas-<version>.apk`.

## Where things are

| Path | What lives there |
|---|---|
| `lib/theme/` | The token set, and the two themes built from it. |
| `lib/connection/` | The base endpoint, the identity handshake, discovery, the remembered server, and the one controller that drives them. |
| `lib/ui/` | The startup experience, the connect screen and the adaptive shell. |
| `lib/main.dart` | The only place the real HTTP client, preference store and platform discovery are named. |
| `tool/` | `generate_launcher_icons.py` — the launcher icon, as geometry rather than as five PNGs nobody can regenerate. It writes every density and the adaptive icon; `--check` says whether the committed assets are still what it produces. Needs any Python 3.9+ and nothing else. |
