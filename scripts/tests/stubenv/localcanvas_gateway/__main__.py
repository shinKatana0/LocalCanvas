"""Test double for the gateway's process entry point.

It implements **the whole seam** the runtime scripts depend on, so every path
the scripts take through it is exercised by the suite. Nothing here is a
convenience shape invented for the tests: the commands, their arguments and
the JSON document below mirror what the gateway provides.

    <python> -m localcanvas_gateway config --config <path>
        the configuration seam (docs/runtime.md). Prints the loaded, validated,
        normalized configuration as one JSON document on stdout, exit 0; a
        human-readable message on stderr and a non-zero exit on failure.

    <python> -u -m localcanvas_gateway --config <path> [--host H] [--port P]
                                       [--endpoint URL] [--no-qr] [--no-mdns]
        serve, and print the mDNS status. With --no-qr it prints no pairing
        block: start.ps1 owns that.

    <python> -m localcanvas_gateway qr --endpoint <url>
        print the pairing payload and QR for an endpoint, and exit.

The validation in ``_load`` is a stand-in whose only job is to produce the
failure *shape* the scripts render -- one message naming the file and the
dotted key. The real validation lives in gateway/localcanvas_gateway/config.py
and belongs to nobody here. So is the reading: ``_parse_document`` below reads
a small, documented subset of YAML rather than importing PyYAML, because this
file runs on an interpreter that has no gateway on it and therefore nothing
the gateway installs (T-0312).

Behaviour is steered by environment variables so the tests can drive failure
paths without a second stub:

    LC_STUB_GATEWAY_MARKER   write this file on startup (launch tripwire)
    LC_STUB_GATEWAY_STREAMS  1 = report what this process's streams encode with
    LC_STUB_GATEWAY_UNENCODABLE
                             1 = log a line carrying U+25CB while starting up
    LC_STUB_GATEWAY_MDNS     ok | fail | silent      (default: ok)
    LC_STUB_GATEWAY_HANG     1 = never serve anything (readiness-timeout path)
    LC_STUB_GATEWAY_ALIEN    1 = answer /api/v1/info as a non-LocalCanvas service
                             html = answer it 200 with a web page, which is
                                    not JSON at all
                             empty-object = answer it 200 with {}, which names
                                    no service
    LC_STUB_CONFIG_MODE      ok | crash | garbage | absent   (default: ok)
    LC_STUB_CONFIG_DROP      remove this dotted field from the document
    LC_STUB_QR_MODE          ok | fail                       (default: ok)
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DISPLAY_NAME = "LocalCanvas test stub"
# Mirrors gateway/localcanvas_gateway/config.py::CONFIG_DOCUMENT_VERSION.
CONFIG_DOCUMENT_VERSION = 1
EXIT_OK = 0
EXIT_CONFIG = 2


# --------------------------------------------------------------------------
# The configuration seam
# --------------------------------------------------------------------------


class ConfigError(Exception):
    pass


def _mapping(source, data, name, required=True):
    if name not in data or data[name] is None:
        if required:
            raise ConfigError(f"{source}: {name}: required section is missing.")
        return {}
    value = data[name]
    if not isinstance(value, dict):
        raise ConfigError(f"{source}: {name}: expected a mapping of settings.")
    return value


def _need(source, mapping, key, dotted):
    if key not in mapping or mapping[key] is None:
        raise ConfigError(f"{source}: {dotted}: required setting is missing.")
    return mapping[key]


def _need_text(source, mapping, key, dotted):
    value = _need(source, mapping, key, dotted)
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{source}: {dotted}: expected a non-empty string, got {value!r}.")
    return value


def _under(root, value):
    """A relative launcher path is relative to comfy.root; an absolute stands."""
    if value is None:
        return None
    if os.path.isabs(value):
        return os.path.normpath(value)
    if not root:
        return None
    return os.path.normpath(os.path.join(root, value))


# --------------------------------------------------------------------------
# Reading the document, without PyYAML (T-0312)
# --------------------------------------------------------------------------
#
# WHY THIS IS NOT ``import yaml``. This file is run by
# scripts/tests/run_tests.py on a PLAIN interpreter that deliberately carries
# no gateway, and PyYAML is declared nowhere but gateway/pyproject.toml. The
# import made a gateway dependency a dependency of the script suite, and it was
# invisible for as long as it was: a maintainer's interpreter happened to have
# PyYAML system-wide, so every local run satisfied it. The first machine
# without it was public CI, where 12 of 13 script groups went red at once and
# every one of them PRINTED a product defect --
#
#     [FAIL] Configuration - could not be loaded
#            ... ModuleNotFoundError: No module named 'yaml'
#
# The scripts job's interpreter is a bare actions/setup-python, and it is worth
# more kept that way than any parser is: with this reader the whole script
# suite needs nothing but the standard library, on CI and on a stranger's
# machine alike, and run_tests.py refuses to start if that ever stops being
# true.
#
# WHAT THIS IS NOT. It is not a YAML implementation and must never grow into
# one. The real loader is gateway/localcanvas_gateway/config.py, it uses
# yaml.safe_load, it is tested by the gateway's own pytest suite against real
# PyYAML, and it belongs to nobody here. What this file owes the scripts is the
# configuration DOCUMENT and the failure SHAPE -- neither of which is a parser.
#
# WHAT IT READS -- the whole subset, and anything outside it is refused by line
# number rather than guessed at:
#
#   * mappings nested by indentation, ``key:`` opening a block and
#     ``key: value`` carrying a scalar; a key is a plain name;
#   * sequences of scalars, ``- value`` indented under their key, and the flow
#     spelling of the same thing, ``key: [a, b]``;
#   * blank lines, and a line whose first non-space character is ``#``;
#   * scalars: double- and single-quoted strings, the booleans, nulls and
#     plain decimal integers and floats PyYAML's own resolvers spell out
#     below, and anything else as the string it is written as.
#
# Two known differences from PyYAML, both documented rather than papered over:
# an unquoted scalar keeps everything to the end of its line (so a ``#`` inside
# a value must be quoted, as it should be anyway), and an integer is plain
# decimal (no ``0x``, no ``_``). Neither appears in a LocalCanvas configuration,
# and closing them would mean writing the implementation this is not.

_KEY_LINE = re.compile(r"^(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)[ \t]*:(?:[ \t]+(?P<value>.*?))?[ \t]*$")
_ITEM_LINE = re.compile(r"^-(?:[ \t]+(?P<value>.*?))?[ \t]*$")
_INTEGER = re.compile(r"^[-+]?[0-9]+$")
_FLOAT = re.compile(r"^[-+]?(?:[0-9]+\.[0-9]*|\.[0-9]+)$")
# The spellings PyYAML's implicit resolvers accept, and only those: PyYAML is a
# YAML 1.1 implementation, where `manage_comfy: yes` is true. A reader that
# made that the string "yes" would disagree with the gateway about a file the
# gateway accepts, which is the one thing this stand-in may never do.
_TRUE = frozenset(("true", "True", "TRUE", "yes", "Yes", "YES", "on", "On", "ON"))
_FALSE = frozenset(("false", "False", "FALSE", "no", "No", "NO", "off", "Off", "OFF"))
_NULL = frozenset(("~", "null", "Null", "NULL"))


def _unsupported(source, number, what):
    return ConfigError(
        f"{source}: line {number}: {what}. This test stub reads a small subset "
        "of YAML on purpose (see the note above _parse_document); the real "
        "loader is gateway/localcanvas_gateway/config.py."
    )


def _split_flow(source, number, text):
    """``a, "b, c", d`` -> the three items, commas inside quotes left alone."""
    items = []
    current = ""
    quote = ""
    for character in text:
        if quote:
            current += character
            if character == quote:
                quote = ""
        elif character in ('"', "'"):
            quote = character
            current += character
        elif character == ",":
            items.append(current)
            current = ""
        else:
            current += character
    if quote:
        raise _unsupported(source, number, "an unterminated string in a [flow sequence]")
    items.append(current)
    return items


def _scalar(source, number, text):
    # A flow sequence of scalars, `[ru, ja]`. It is in this subset because
    # config/examples/runtime.example.yaml -- the file the README tells a
    # stranger to copy -- writes one, and a reader that took it for the string
    # "[ru, ja]" would be the quiet kind of wrong this stand-in may not be.
    if text.startswith("["):
        if not text.endswith("]"):
            raise _unsupported(source, number, "an unterminated [flow sequence]")
        inner = text[1:-1].strip()
        if not inner:
            return []
        return [_scalar(source, number, item.strip())
                for item in _split_flow(source, number, inner)]
    if text.startswith("{"):
        raise _unsupported(source, number, "a {flow mapping}")
    if text.startswith('"'):
        if len(text) < 2 or not text.endswith('"'):
            raise _unsupported(source, number, "an unterminated double-quoted string")
        body = text[1:-1]
        out = []
        index = 0
        while index < len(body):
            character = body[index]
            if character != "\\":
                out.append(character)
                index += 1
                continue
            escape = body[index + 1:index + 2]
            if escape not in ('"', "\\", "/"):
                raise _unsupported(
                    source, number,
                    "the escape {!r} in a quoted string".format("\\" + escape))
            out.append(escape)
            index += 2
        return "".join(out)
    if text.startswith("'"):
        if len(text) < 2 or not text.endswith("'"):
            raise _unsupported(source, number, "an unterminated single-quoted string")
        return text[1:-1].replace("''", "'")
    if text in _NULL:
        return None
    if text in _TRUE:
        return True
    if text in _FALSE:
        return False
    if _INTEGER.match(text):
        return int(text)
    if _FLOAT.match(text):
        return float(text)
    return text


def _parse_document(source, text):
    """The document ``text`` holds, or ``None`` when it holds nothing.

    ``source`` is the file's path, and every complaint names it and a line, so
    a document this reader will not read says so instead of arriving as a
    stack trace or, worse, as a document quietly missing a key.
    """
    root = {}
    stack = [(0, root)]        # (indentation, the container opened at it)
    pending = None             # (indentation, container, key) awaiting a block
    content = False
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if line.lstrip(" ").startswith("\t"):
            raise _unsupported(source, number, "a tab in the indentation")
        content = True

        if pending is not None:
            held_indent, held_container, held_key = pending
            if indent > held_indent:
                block = [] if stripped.startswith("-") else {}
                held_container[held_key] = block
                stack.append((indent, block))
            else:
                # Nothing was indented under it, which is an empty value.
                held_container[held_key] = None
            pending = None

        while len(stack) > 1 and indent < stack[-1][0]:
            stack.pop()
        level, container = stack[-1]
        if indent != level:
            raise _unsupported(source, number, "unexpected indentation")

        if isinstance(container, list):
            match = _ITEM_LINE.match(stripped)
            if match is None:
                raise _unsupported(source, number, "expected a list item, '- value'")
            value = match.group("value")
            if value is None:
                raise _unsupported(source, number, "a list item with no value")
            container.append(_scalar(source, number, value))
            continue

        match = _KEY_LINE.match(stripped)
        if match is None:
            raise _unsupported(source, number, "expected 'key: value' or 'key:'")
        value = match.group("value")
        if value is None:
            pending = (indent, container, match.group("key"))
        else:
            container[match.group("key")] = _scalar(source, number, value)

    if pending is not None:
        pending[1][pending[2]] = None
    return root if content else None


def _load(path):
    """A stand-in for the gateway's loader: same document, same failure shape."""
    if not os.path.isfile(path):
        raise ConfigError(
            f"{path}: configuration file not found. Copy "
            "config/examples/runtime.example.yaml to config/local/runtime.yaml "
            "and edit it for this machine."
        )
    with open(path, "r", encoding="utf-8") as handle:
        data = _parse_document(path, handle.read())
    if not isinstance(data, dict):
        raise ConfigError(f"{path}: expected a mapping of configuration sections.")

    known = ("runtime", "comfy", "workflows", "gateway", "startup", "identity")
    unknown = sorted(key for key in data if key not in known)
    if unknown:
        raise ConfigError(
            f"{path}: (top level): unknown key {unknown[0]!r}. "
            f"Accepted here: {', '.join(repr(name) for name in known)}."
        )

    runtime = _mapping(path, data, "runtime")
    manage = _need(path, runtime, "manage_comfy", "runtime.manage_comfy")
    if not isinstance(manage, bool):
        raise ConfigError(
            f"{path}: runtime.manage_comfy: expected true or false, got {manage!r}."
        )

    # Sections are checked in the order the real loader checks them, so the
    # first complaint a user sees is the same one either way.
    comfy = _mapping(path, data, "comfy")
    launcher = comfy.get("launcher")
    if manage:
        _need(path, comfy, "root", "comfy.root")
        if not isinstance(launcher, dict):
            raise ConfigError(
                f"{path}: comfy.launcher: required when runtime.manage_comfy is true."
            )
        _need(path, launcher, "executable", "comfy.launcher.executable")
        _need(path, launcher, "script", "comfy.launcher.script")

    workflows = _mapping(path, data, "workflows")
    gateway = _mapping(path, data, "gateway")
    identity = _mapping(path, data, "identity")
    startup = _mapping(path, data, "startup", required=False)

    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(path))))
    registry = _need(path, workflows, "registry", "workflows.registry")
    if not os.path.isabs(registry):
        registry = os.path.join(repo_root, registry)

    root = comfy.get("root")
    launcher_document = None
    if isinstance(launcher, dict):
        launcher_document = {
            "executable": launcher["executable"],
            "script": launcher["script"],
            # Resolved here, exactly as the gateway resolves it: the scripts
            # combine comfy.root with a relative launcher path nowhere.
            "executable_path": _under(root, launcher["executable"]),
            "script_path": _under(root, launcher["script"]),
        }

    host = _need(path, comfy, "host", "comfy.host")
    port = _need(path, comfy, "port", "comfy.port")
    literal = "[{}]".format(host) if ":" in host and not host.startswith("[") else host

    # The document of gateway/localcanvas_gateway/config.py::config_document.
    # Every key is present; an optional value is null, never missing.
    return {
        "config_version": CONFIG_DOCUMENT_VERSION,
        "source": os.path.abspath(path),
        "repo_root": repo_root,
        "runtime": {"manage_comfy": manage},
        "comfy": {
            "host": host,
            "port": port,
            "base_url": "http://{}:{}".format(literal, port),
            "root": os.path.abspath(root) if root else None,
            "launcher": launcher_document,
            "extra_args": [str(item) for item in (comfy.get("extra_args") or [])],
        },
        "workflows": {"registry": registry},
        "gateway": {
            "host": _need(path, gateway, "host", "gateway.host"),
            "port": _need(path, gateway, "port", "gateway.port"),
        },
        "startup": {
            "comfy_timeout_seconds": float(startup.get("comfy_timeout_seconds") or 120),
            "gateway_timeout_seconds": float(startup.get("gateway_timeout_seconds") or 30),
        },
        "identity": {
            "display_name": _need_text(path, identity, "display_name", "identity.display_name")
        },
    }


def _config_command(argv):
    mode = os.environ.get("LC_STUB_CONFIG_MODE", "ok")
    if mode == "absent":
        # An older gateway, whose CLI has no `config` command at all.
        print(
            "usage: python -m localcanvas_gateway [-h] --config PATH\n"
            "python -m localcanvas_gateway: error: unrecognized arguments: config",
            file=sys.stderr,
            flush=True,
        )
        return EXIT_CONFIG

    parser = argparse.ArgumentParser(prog="python -m localcanvas_gateway config")
    parser.add_argument("--config", required=True)
    args = parser.parse_args(argv)

    if mode == "crash":
        print("[FAIL] Configuration could not be loaded", file=sys.stderr, flush=True)
        print("       the loader refused this file", file=sys.stderr, flush=True)
        return EXIT_CONFIG
    if mode == "garbage":
        print("this is not JSON", flush=True)
        return EXIT_OK

    try:
        document = _load(args.config)
    except ConfigError as exc:
        print("[FAIL] Configuration could not be loaded", file=sys.stderr, flush=True)
        for line in str(exc).splitlines():
            print(f"       {line}", file=sys.stderr, flush=True)
        return EXIT_CONFIG
    dropped = os.environ.get("LC_STUB_CONFIG_DROP")
    if dropped:
        # A gateway one version out of step with the scripts: the document
        # is valid JSON and loads fine, but a field the scripts consume is
        # simply not in it.
        node = document
        segments = dropped.split(".")
        for segment in segments[:-1]:
            node = node.get(segment) or {}
        node.pop(segments[-1], None)

    json.dump(document, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
    return EXIT_OK


# --------------------------------------------------------------------------
# The qr subcommand
# --------------------------------------------------------------------------


def _qr_command(argv):
    parser = argparse.ArgumentParser(prog="python -m localcanvas_gateway qr")
    parser.add_argument("--config", default=None)
    parser.add_argument("--endpoint", default=None)
    parser.add_argument("--wide", action="store_true")
    args = parser.parse_args(argv)

    if os.environ.get("LC_STUB_QR_MODE") == "fail":
        print("[FAIL] No endpoint to encode", file=sys.stderr, flush=True)
        return EXIT_CONFIG
    if not args.endpoint:
        print("[FAIL] No endpoint to encode", file=sys.stderr, flush=True)
        return EXIT_CONFIG

    print(f"localcanvas://connect?endpoint={args.endpoint}", flush=True)
    print("  " + "#" * 21, flush=True)
    print("  #  [pairing QR]    #", flush=True)
    print("  " + "#" * 21, flush=True)
    return EXIT_OK


# --------------------------------------------------------------------------
# Serving
# --------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    alien = ""

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler's spelling
        path = self.path.split("?", 1)[0]
        content_type = "application/json"
        if path != "/api/v1/info":
            body = b'{"error":"not found"}'
            self.send_response(404)
        elif Handler.alien == "html":
            content_type = "text/html; charset=utf-8"
            body = b"<!doctype html><html><body>Sign in</body></html>"
            self.send_response(200)
        elif Handler.alien == "empty-object":
            body = b"{}"
            self.send_response(200)
        else:
            if Handler.alien == "1":
                doc = {"service": "something-else", "api_version": 1}
            else:
                doc = {
                    "service": "localcanvas",
                    "api_version": 1,
                    "gateway_version": "0.1.0",
                    "display_name": DISPLAY_NAME,
                    "comfy": {"status": "ready", "detail": None},
                    "capabilities": {"cancel": True, "media_upload": True, "events": True},
                }
            body = json.dumps(doc).encode("utf-8")
            self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


class _IPv6Server(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        # IPv6 only, as asyncio makes the real gateway's AF_INET6 listeners:
        # the IPv4 address is a listener of its own.
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()


def _servers(host, port):
    """One server per address ``host`` names, as the real gateway binds.

    uvicorn hands the host to asyncio's create_server, which binds every
    address getaddrinfo returns for it -- for "localhost" that is ::1 and
    127.0.0.1. A client that tries ::1 first (start.ps1's readiness probe
    does, T-0263) must find a listener there, or it waits out a refused
    connect. An IP literal binds exactly as it always did.
    """
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        return [ThreadingHTTPServer((host, port), Handler)]
    servers = []
    seen = set()
    for family, _type, _proto, _name, address in socket.getaddrinfo(
            host, port, socket.AF_UNSPEC, socket.SOCK_STREAM, 0, socket.AI_PASSIVE):
        if (family, address[0]) in seen:
            continue
        seen.add((family, address[0]))
        if family == socket.AF_INET6:
            servers.append(_IPv6Server((address[0], port), Handler))
        elif family == socket.AF_INET:
            servers.append(ThreadingHTTPServer((address[0], port), Handler))
    return servers


def _serve_command(argv):
    parser = argparse.ArgumentParser(prog="python -m localcanvas_gateway")
    parser.add_argument("--config", required=True)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=7801)
    parser.add_argument("--endpoint", default=None)
    parser.add_argument("--no-mdns", action="store_true")
    parser.add_argument("--no-qr", action="store_true")
    args = parser.parse_args(argv)

    marker = os.environ.get("LC_STUB_GATEWAY_MARKER")
    if marker:
        with open(marker, "a", encoding="utf-8") as handle:
            handle.write(
                f"{time.time()} pid={os.getpid()} {args.config} "
                f"{args.host}:{args.port} endpoint={args.endpoint} "
                f"no_qr={args.no_qr} no_mdns={args.no_mdns}\n"
            )

    if not os.path.isfile(args.config):
        print(f"config not found: {args.config}", file=sys.stderr, flush=True)
        return EXIT_CONFIG

    # The gateway is redirected by start.ps1 exactly as ComfyUI is, so it has
    # exactly the same exposure (T-0085). ASCII only, so the report itself
    # cannot be what fails.
    if os.environ.get("LC_STUB_GATEWAY_STREAMS") == "1":
        print(
            "[INFO] streams stdout={} stderr={} PYTHONIOENCODING={!r}".format(
                sys.stdout.encoding, sys.stderr.encoding,
                os.environ.get("PYTHONIOENCODING")),
            flush=True,
        )
    if os.environ.get("LC_STUB_GATEWAY_UNENCODABLE") == "1":
        # Unguarded on purpose: whether this survives is a fact about the
        # encoding the launcher declared, not about this file.
        print("[INFO] starting " + chr(0x25CB), flush=True)
        print("[INFO] starting " + chr(0x25CB), file=sys.stderr, flush=True)

    mdns = os.environ.get("LC_STUB_GATEWAY_MDNS", "ok")
    if not args.no_mdns:
        if mdns == "ok":
            print(
                "[ OK ] Discovery: mDNS active as _localcanvas._tcp.local "
                f"(name={DISPLAY_NAME!r}, port={args.port}, version=0.1.0, api=1)",
                flush=True,
            )
        elif mdns == "fail":
            print(
                "[WARN] Discovery: mDNS unavailable (multicast is not permitted "
                "on this machine)",
                flush=True,
            )

    # start.ps1 owns the readiness block; with --no-qr nothing of it is printed
    # here. Without the flag the gateway would render its own pairing block.
    if not args.no_qr and args.endpoint:
        print(f"       localcanvas://connect?endpoint={args.endpoint}", flush=True)

    if os.environ.get("LC_STUB_GATEWAY_HANG") == "1":
        # Alive, but never ready: the readiness probe must be what decides,
        # and it must time out rather than succeed by the passage of time.
        while True:
            time.sleep(3600)

    Handler.alien = os.environ.get("LC_STUB_GATEWAY_ALIEN", "")
    bind_host = "127.0.0.1" if args.host in ("0.0.0.0", "::", "*") else args.host
    for server in _servers(bind_host, args.port):
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        print(f"[INFO] Listening on {server.server_address[0]}:{args.port}", flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    return EXIT_OK


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv and argv[0] == "config":
        return _config_command(argv[1:])
    if argv and argv[0] == "qr":
        return _qr_command(argv[1:])
    return _serve_command(argv)


if __name__ == "__main__":
    sys.exit(main())
