"""``python -m localcanvas_gateway`` -- the gateway's command-line seam.

    python -m localcanvas_gateway --config <path> [--host H] [--port P]
                                  [--endpoint URL] [--instance-id ID]
                                  [--no-mdns] [--no-qr]
    python -m localcanvas_gateway config --config <path>
    python -m localcanvas_gateway qr --config <path> [--endpoint URL]
                                     [--png PATH] [--scale N]

**This CLI is a seam another component depends on** (`scripts/*.ps1`), so
``--config``, ``--host`` and ``--port`` keep their meaning.  ``--host`` and
``--port`` override the configured gateway bind address; everything else comes
from the configuration file, and nothing is guessed when it is absent.

``config`` is the configuration seam in `docs/runtime.md`: the scripts never
parse YAML and never re-validate it, they run this and read one JSON document
from stdout.  Nothing else is written to stdout by that subcommand -- a stray
banner line would make the document unparseable for its only consumer.

Who owns the terminal when both halves could print
--------------------------------------------------
`docs/runtime.md` gives ``start.ps1`` the endpoint and the readiness block:
it decides the address, passes it down as ``--endpoint``, and prints the
Endpoint / Discovery / QR block itself, once.  So **``--endpoint`` is also how
this process is told it is not the one talking to the user**: given one, it
publishes mDNS and serves, and prints no block of its own.  Run without it --
a developer starting the gateway by hand -- it works out an endpoint, prints
the block and the QR, and is the only thing on the screen.

The interpreter path and version are printed before anything else, because a
Windows machine usually has several Pythons and a version mismatch should be
visible in the terminal rather than discovered later from an import error
(`docs/runtime.md`).

``--instance-id`` names *this process*, not this build: something watching the
gateway from outside (a launcher or process monitor) needs to tell one running
gateway apart from a different one that happens to be listening on the same
port.  It is 32 lowercase hex characters, checked before anything else runs;
left out, one is generated (`secrets.token_hex(16)`), so every gateway that
ever serves has an id whether or not anyone asked for a particular one.  It is
printed once at startup and carried in `GET /api/v1/info` (`docs/api.md`).

Failures print as a ``[FAIL]`` block naming what was attempted and what
happened.  A traceback is never the primary failure UX; the exit code carries
the outcome:

* ``0`` -- the command did what it was asked;
* ``2`` -- configuration or the workflow registry could not be used.
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import secrets
import sys
from typing import Any, Callable, Optional, Sequence, TextIO

from . import __version__
from .api import API_VERSION, build_gateway, create_app, translation_summary
from .config import ConfigError, RuntimeConfig, config_document, load_config
from .discovery import Advertisement, advertise, lan_address
from .pairing import pairing_payload, pairing_qr_for_stream, pairing_qr_png
from .translation import Translator
from .workflows import RegistryError

log = logging.getLogger(__name__)

EXIT_OK = 0
EXIT_CONFIG = 2

#: What ``--instance-id`` accepts.  32 lowercase hex characters -- the same
#: shape ``secrets.token_hex(16)`` produces, so a generated id and a supplied
#: one are indistinguishable to anything reading `GET /api/v1/info`.
_INSTANCE_ID_PATTERN = re.compile(r"[0-9a-f]{32}")


def _instance_id_argument(value: str) -> str:
    # argparse prepends "argument --instance-id: " to this message itself, so
    # the flag's name is not repeated here -- naming it twice is what a
    # person actually saw before this fix.
    if not _INSTANCE_ID_PATTERN.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "must be exactly 32 lowercase hex characters, got {!r}".format(value)
        )
    return value


def _positive_int_argument(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer") from exc
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m localcanvas_gateway",
        description="Start the LocalCanvas gateway.",
    )
    parser.add_argument(
        "--config",
        required=True,
        metavar="PATH",
        help="path to runtime.yaml (config/local/runtime.yaml)",
    )
    parser.add_argument(
        "--host", default=None, help="override the configured gateway bind address"
    )
    parser.add_argument(
        "--port", default=None, type=int, help="override the configured gateway port"
    )
    parser.add_argument(
        "--endpoint",
        default=None,
        metavar="URL",
        help="the endpoint a phone should use; advertised and encoded in the QR",
    )
    parser.add_argument(
        "--instance-id",
        type=_instance_id_argument,
        default=None,
        metavar="ID",
        help="this process's identity, 32 lowercase hex characters; generated when omitted",
    )
    parser.add_argument(
        "--no-mdns", action="store_true", help="do not advertise the gateway over mDNS"
    )
    parser.add_argument(
        "--no-qr", action="store_true", help="do not print the pairing QR code"
    )
    return parser


def build_qr_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m localcanvas_gateway qr",
        description="Print the pairing QR code for an endpoint and exit.",
    )
    parser.add_argument("--config", default=None, metavar="PATH", help="path to runtime.yaml")
    parser.add_argument("--endpoint", default=None, metavar="URL", help="the endpoint to encode")
    parser.add_argument(
        "--wide",
        action="store_true",
        help=(
            "force the full-size ASCII rendering; without it the output stream's "
            "encoding decides whether half blocks can be drawn"
        ),
    )
    parser.add_argument(
        "--png",
        default=None,
        metavar="PATH",
        help="write the QR as a PNG to this path instead of drawing it in the terminal",
    )
    parser.add_argument(
        "--scale",
        type=_positive_int_argument,
        default=None,
        metavar="N",
        help="pixels per PNG module (default: sized to roughly 300-400 px); needs --png",
    )
    return parser


def build_config_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m localcanvas_gateway config",
        description="Print the validated configuration as one JSON document.",
    )
    parser.add_argument(
        "--config", required=True, metavar="PATH", help="path to runtime.yaml"
    )
    return parser


def main(
    argv: Optional[Sequence[str]] = None,
    *,
    out: Optional[TextIO] = None,
    err: Optional[TextIO] = None,
    serve: Optional[Callable[..., None]] = None,
    advertiser: Optional[Callable[..., Advertisement]] = None,
    translator: Optional[Translator] = None,
) -> int:
    """Entry point.

    ``serve``, ``advertiser`` and ``translator`` are injectable so that the CLI
    can be exercised without binding a socket, touching a multicast network, or
    depending on which optional packages happen to be installed on the machine
    it runs on.  Each defaults to the real thing when it is not given: uvicorn,
    zeroconf, and -- one layer down, where the gateway is assembled and where
    ``comfy``, ``registry`` and ``media_store`` get theirs too -- the local
    translation backend (`api/app.py`, `translation/service.py`).

    A translator given here is the one the gateway is built with, which is what
    lets a caller state the PC it is talking about: a machine with the optional
    translation extra installed and one without it are two different startup
    banners, and neither of them is a property of the machine running the test.
    """

    argv = list(sys.argv[1:] if argv is None else argv)
    stdout = out if out is not None else sys.stdout
    stderr = err if err is not None else sys.stderr

    if argv and argv[0] == "qr":
        return _qr_command(argv[1:], stdout, stderr)
    if argv and argv[0] == "config":
        return _config_command(argv[1:], stdout, stderr)
    return _serve_command(
        argv, stdout, stderr, serve or _uvicorn_serve, advertiser or advertise, translator
    )


# --------------------------------------------------------------------------
# The config subcommand -- the seam scripts/*.ps1 consume
# --------------------------------------------------------------------------


def _config_command(argv: Sequence[str], out: TextIO, err: TextIO) -> int:
    """One JSON document on stdout, or a human message on stderr and non-zero.

    Nothing else is ever written to stdout here: its consumer pipes this into
    ``ConvertFrom-Json`` with no fallback reader (`docs/runtime.md`).
    """

    args = build_config_parser().parse_args(argv)
    try:
        config = load_config(args.config)
    except ConfigError as exc:
        _fail(err, "Configuration could not be loaded", str(exc))
        return EXIT_CONFIG

    _print(out, json.dumps(config_document(config), indent=2, sort_keys=False))
    return EXIT_OK


# --------------------------------------------------------------------------
# Serving
# --------------------------------------------------------------------------


def _serve_command(
    argv: Sequence[str],
    out: TextIO,
    err: TextIO,
    serve: Callable[..., None],
    advertiser: Callable[..., Advertisement],
    translator: Optional[Translator] = None,
) -> int:
    args = build_parser().parse_args(argv)

    _print(out, "[INFO] Interpreter: {} (Python {})".format(sys.executable, _python_version()))
    _print(out, "[INFO] Gateway version: {} (API v{})".format(__version__, API_VERSION))

    # Named once, here, so the id in the banner and the id `GET /api/v1/info`
    # reports for the whole life of this process are the same value -- never
    # regenerated on the way into `build_gateway` below.
    instance_id = args.instance_id or secrets.token_hex(16)
    _print(out, "[INFO] Instance: {}".format(instance_id))

    try:
        config = load_config(args.config)
    except ConfigError as exc:
        _fail(err, "Configuration could not be loaded", str(exc))
        return EXIT_CONFIG
    _print(out, "[ OK ] Configuration loaded: {}".format(config.source))

    try:
        state = build_gateway(config, translator=translator, instance_id=instance_id)
    except RegistryError as exc:
        _fail(
            err,
            "The workflow registry could not be read",
            "{}\n       Check workflows.registry in {}.".format(exc, config.source),
        )
        return EXIT_CONFIG

    rejected = len({diagnostic.source for diagnostic in state.registry.diagnostics})
    _print(
        out,
        "[ OK ] Workflows: {} loaded{}, from {}".format(
            len(state.registry.workflows),
            ", {} rejected".format(rejected) if rejected else "",
            config.workflows_registry,
        ),
    )
    for diagnostic in state.registry.diagnostics:
        _print(out, "[WARN] {}".format(diagnostic))

    # What the stage found when it was prepared, a moment ago and not in a
    # request (`api/app.py`).  Printed because it is the one line that tells
    # the person at this PC whether the prompts they type will be translated,
    # and because a cost worth paying is a cost worth showing.
    #
    # The models were also *loaded* a moment ago, before this process listens
    # (T-0122), so the same line carries what that cost and names a pair that
    # refused to load.  On a PC with nothing to warm there is nothing extra to
    # say and the line is the one it has always been.
    capability = state.translation.capability()
    warm_up = state.translation.warm_up
    _print(
        out,
        "[{}] Translation: {}".format(
            "WARN"
            if capability.enabled and (not capability.pairs or warm_up.failed)
            else " OK ",
            translation_summary(capability, warm_up),
        ),
    )

    host = args.host or config.gateway.host
    port = args.port or config.gateway.port

    # An endpoint we were given is an endpoint someone else is already telling
    # the user about (`docs/runtime.md`, "Who owns the endpoint and the pairing
    # block"), so the block below is theirs to print, not ours.
    endpoint = args.endpoint or _endpoint(host, port)
    owns_terminal = args.endpoint is None

    advertisement: Optional[Advertisement] = None
    if not args.no_mdns:
        advertisement = _advertise(config, port, endpoint, out, advertiser, owns_terminal)

    if owns_terminal and not args.no_qr:
        if endpoint:
            _print(out, "")
            _print(out, "       QR pairing:")
            _print(out, "       {}".format(pairing_payload(endpoint)))
            # The rendering follows the stream we are about to write to: this
            # branch runs when nobody redirected us, but "owns the terminal"
            # is not the same claim as "the terminal can draw half blocks".
            _print(out, pairing_qr_for_stream(endpoint, out))
        else:
            _print(out, "[WARN] QR pairing: no endpoint could be determined; pass --endpoint.")

    _print(out, "[INFO] Listening on {}:{}".format(host, port))
    if owns_terminal and endpoint:
        _print(out, "[INFO] Endpoint: {}".format(endpoint))

    try:
        serve(create_app(state), host=host, port=port)
    finally:
        if advertisement is not None:
            advertisement.close()
        state.comfy.close()
    return EXIT_OK


def _advertise(
    config: RuntimeConfig,
    port: int,
    endpoint: Optional[str],
    out: TextIO,
    advertiser: Callable[..., Advertisement],
    owns_terminal: bool,
) -> Optional[Advertisement]:
    """Publish the service.  The address advertised is the endpoint's, if given."""

    try:
        advertisement = advertiser(
            display_name=config.identity.display_name,
            port=port,
            gateway_version=__version__,
            api_version=API_VERSION,
            address=_address_of(endpoint),
        )
    except Exception as exc:  # zeroconf raises several unrelated types
        # Multicast is blocked on plenty of real networks.  That is a normal
        # outcome (`docs/connection.md`), not a reason to refuse to serve.
        log.warning("mDNS advertisement failed: %s", exc)
        if owns_terminal:
            _print(out, "[WARN] Discovery: mDNS unavailable ({})".format(exc))
        return None
    log.info("mDNS: advertising %r on port %s", config.identity.display_name, port)
    if owns_terminal:
        _print(
            out, "[ OK ] Discovery: mDNS active as {!r}".format(config.identity.display_name)
        )
    return advertisement


def _uvicorn_serve(app: Any, *, host: str, port: int) -> None:
    import uvicorn

    # The terminal output above is the startup UX (`docs/runtime.md`); uvicorn's
    # own banner would talk over it.  Warnings and errors still come through.
    uvicorn.run(app, host=host, port=port, log_level="warning", access_log=False)


# --------------------------------------------------------------------------
# The qr subcommand
# --------------------------------------------------------------------------


def _qr_command(argv: Sequence[str], out: TextIO, err: TextIO) -> int:
    parser = build_qr_parser()
    args = parser.parse_args(argv)

    if args.scale is not None and args.png is None:
        # ``--scale`` is pixels *per PNG module*; without ``--png`` there is no
        # PNG for it to size, so silently ignoring it would let a typo'd
        # command look like it had done something.
        parser.error("--scale requires --png")

    endpoint = args.endpoint
    if endpoint is None:
        if args.config is None:
            _fail(err, "No endpoint to encode", "Pass --endpoint or --config.")
            return EXIT_CONFIG
        try:
            config = load_config(args.config)
        except ConfigError as exc:
            _fail(err, "Configuration could not be loaded", str(exc))
            return EXIT_CONFIG
        endpoint = _endpoint(config.gateway.host, config.gateway.port)

    if endpoint is None:
        _fail(
            err,
            "No endpoint to encode",
            "This machine's network address could not be determined. Pass --endpoint.",
        )
        return EXIT_CONFIG

    _print(out, pairing_payload(endpoint))

    if args.png is not None:
        # A file is written instead of drawn; the payload line above still
        # says what it encodes, which is the only text output this branch
        # owes anyone.
        try:
            pairing_qr_png(endpoint, args.png, scale=args.scale)
        except OSError as exc:
            _fail(err, "The QR image could not be written", str(exc))
            return EXIT_CONFIG
        return EXIT_OK

    # ``--wide`` is an instruction; without it the stream decides, so a
    # redirected run on a cp1251 machine prints a code instead of dying.
    _print(out, pairing_qr_for_stream(endpoint, out, wide=args.wide))
    return EXIT_OK


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------


def _endpoint(host: str, port: int) -> Optional[str]:
    """The address a phone would use, or ``None`` when it cannot be determined.

    A wildcard bind names no address, so the machine's own is asked for.  This
    is a *deployment* convenience for discovery and pairing, both of which
    `docs/transport-boundary.md` explicitly allows to be LAN-shaped; no payload
    the API returns is built from it.
    """

    address = lan_address(host)
    if address is None:
        return None
    return "http://{}:{}".format(address, port)


def _address_of(endpoint: Optional[str]) -> Optional[str]:
    if not endpoint:
        return None
    from urllib.parse import urlparse

    parsed = urlparse(endpoint)
    return parsed.hostname


def _python_version() -> str:
    return "{}.{}.{}".format(*sys.version_info[:3])


def _print(stream: TextIO, text: str) -> None:
    print(text, file=stream)
    # Flushed line by line: when the gateway is launched by a script its stdout
    # is a pipe, and Python would otherwise hold the whole startup banner in a
    # buffer until the process exits -- which is exactly when nobody needs it.
    stream.flush()


def _fail(stream: TextIO, attempted: str, detail: str) -> None:
    """A failure a person can act on.  No traceback, no Python vocabulary."""

    print("[FAIL] {}".format(attempted), file=stream)
    for line in str(detail).splitlines():
        print("       {}".format(line), file=stream)


def _configure_logging() -> None:
    """The gateway's own log at INFO; its HTTP client's chatter is not that.

    ``httpx`` logs one INFO line per request, and the gateway makes one per
    poll.  Left on, the terminal fills with ComfyUI URLs and the startup output
    `docs/runtime.md` specifies is lost in them.
    """

    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr
    )
    for noisy in ("httpx", "httpcore", "zeroconf"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


if __name__ == "__main__":  # pragma: no cover - process entry point
    _configure_logging()
    sys.exit(main())


__all__ = ["main", "build_parser", "build_qr_parser"]
