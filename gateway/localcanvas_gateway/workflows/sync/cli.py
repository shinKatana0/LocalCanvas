"""``python -m localcanvas_gateway.workflows sync`` -- the curator's engine.

Reached as a subcommand of the offline validator that was already there, and
run by ``scripts/sync-workflows.ps1``.  The gateway never imports it -- it
happens to live in the same package, exactly as ``workflows/cli.py`` does.

**It is no longer offline, and that is the whole of T-0084.**  Reading a folder,
hashing it, classifying it and comparing it with the last run still touch
nothing but the disk.  But a workflow saved in ComfyUI's *editor* format is a
canvas rather than an execution, and turning one into the other is something
only the ComfyUI that saved it can do -- so when there is such a workflow, this
asks the user's own ComfyUI (``bridge.py``, `docs/privacy-security.md`).  A tree
of API-format exports still never opens a socket.

    python -m localcanvas_gateway.workflows sync --config <path> [--dry-run]
        [--no-convert] [--regenerate-labels]

One JSON document on stdout and exit 0 or 1; a human-readable ``[FAIL]`` block
on stderr and exit 2 when the run could not happen at all.  The three codes are
the ones the module already uses:

* ``0`` -- the sync ran and nothing needs attention;
* ``1`` -- the sync ran and at least one workflow needs attention;
* ``2`` -- fatal, in two kinds (T-0225).  No configuration, a malformed one,
  an unreadable source root, two roots that overlap, or an output inside a
  source: each is found before the run writes anything, so nothing was
  changed.  Or an inventory that could not be written: the inventory is
  written last, so definitions, imported graphs and conversion snapshots this
  run wrote may already be on disk.  Only that second kind's ``[FAIL]`` block
  carries the line ``engine.INVENTORY_NOT_WRITTEN_MARKER``, which is how
  ``scripts/sync-workflows.ps1`` tells the two apart.
"""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Optional, Sequence, TextIO, Union

from .bridge import ConversionBridge
from .config import CONFIG_RELATIVE_PATH, load_sources_config
from .engine import run_sync
from .errors import SyncError
from .report import render

EXIT_OK = 0
EXIT_ATTENTION = 1
EXIT_FATAL = 2

#: Where the ComfyUI endpoint is written down.  There is exactly one definition
#: of what ``runtime.yaml`` means and it is the gateway's own loader
#: (`docs/runtime.md`, "The configuration seam"); this reads it through that
#: loader rather than adding a second reader, and the PowerShell front end
#: still parses no YAML.
RUNTIME_CONFIG_RELATIVE_PATH = "config/local/runtime.yaml"

#: The name of that file, on its own.  The path above is where it sits in the
#: shipped layout; this is what is looked for **beside a named configuration**.
RUNTIME_CONFIG_FILENAME = "runtime.yaml"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m localcanvas_gateway.workflows sync",
        description=(
            "Read the workflow folders named in the sources configuration, "
            "classify what is in them and record the result. Source files are "
            "only ever read. (This word is read as a subcommand, so a registry "
            "root that is itself called 'sync' has to be given to the validator "
            "as './sync'.)"
        ),
    )
    parser.add_argument(
        "--config",
        default=CONFIG_RELATIVE_PATH,
        metavar="PATH",
        help="the workflow sources configuration (default: {})".format(
            CONFIG_RELATIVE_PATH
        ),
    )
    parser.add_argument(
        "--repo-root",
        default=None,
        metavar="PATH",
        help=(
            "what a relative output path is measured against; by default the "
            "repository the configuration file sits in"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="do everything except write: no inventory, no file of any kind",
    )
    parser.add_argument(
        "--runtime-config",
        default=None,
        metavar="PATH",
        help=(
            "the runtime configuration, read only for the ComfyUI endpoint an "
            "editor-format workflow is converted through (default: {} beside "
            "the --config file, i.e. {} for the shipped layout)".format(
                RUNTIME_CONFIG_FILENAME, RUNTIME_CONFIG_RELATIVE_PATH
            )
        ),
    )
    parser.add_argument(
        "--comfy-url",
        default=None,
        metavar="URL",
        help=(
            "convert editor-format workflows through the ComfyUI at this "
            "address instead of the one in the runtime configuration"
        ),
    )
    parser.add_argument(
        "--no-convert",
        action="store_true",
        help=(
            "do not ask ComfyUI to convert anything; editor-format workflows "
            "are reported as needing an API export, exactly as before"
        ),
    )
    parser.add_argument(
        "--regenerate-labels",
        action="store_true",
        help=(
            "write every importable definition with each field's label and help "
            "line, and every presentation key the importer generates, generated "
            "again, replacing the ones a normal run keeps as yours; the name, the "
            "translation setting and any presentation key the importer never "
            "generates are kept. The report lists every replaced label, help "
            "line and presentation key a normal run would have kept"
        ),
    )
    return parser


def main(
    argv: Optional[Sequence[str]] = None,
    *,
    out: Optional[TextIO] = None,
    err: Optional[TextIO] = None,
) -> int:
    import sys

    stdout = out if out is not None else sys.stdout
    stderr = err if err is not None else sys.stderr
    args = build_parser().parse_args(list(argv or []))

    try:
        config = load_sources_config(args.config, repo_root=args.repo_root)
    except SyncError as exc:
        _fail(stderr, str(exc))
        return EXIT_FATAL

    bridge = None if args.no_convert else _bridge(args)
    try:
        report = run_sync(
            config,
            dry_run=args.dry_run,
            bridge=bridge,
            regenerate_labels=args.regenerate_labels,
        )
    except SyncError as exc:
        _fail(stderr, str(exc))
        return EXIT_FATAL
    finally:
        # The browser and its temporary profile are ours, and they go whatever
        # happened -- including when the run failed on something else entirely.
        if bridge is not None:
            bridge.close()

    print(render(report), file=stdout)
    return EXIT_ATTENTION if report.attention else EXIT_OK


def runtime_config_path(
    config: Union[str, Path],
    runtime_config: Optional[Union[str, Path]] = None,
) -> Path:
    """Which ``runtime.yaml`` a run that named ``config`` reads.

    **Naming a configuration determines the run.**  The runtime configuration
    is resolved *beside* the sources configuration the caller named -- in the
    same directory -- and never from the repository root the process happens to
    be standing in.  Anything else means a file nobody named can change the
    answer of a run that named its own (T-0107): the sync then read the
    endpoint of the machine it ran on while working entirely inside a temporary
    workspace, and whether ComfyUI happened to be listening changed the report.

    The shipped default needs no special case, and deliberately gets none.
    ``config/local/workflow-sources.yaml`` has ``config/local`` for a parent, so
    the sibling of the default *is* ``config/local/runtime.yaml`` -- the same
    file, resolved the same way, whether or not ``--config`` was given.  One
    rule, and no branch that could be written backwards.

    ``runtime_config`` is the explicit override and wins outright when given;
    ``scripts/sync-workflows.ps1`` always passes one, so the front end is not
    affected by this at all.

    A sibling that is not there means **no runtime**: the caller gets whatever
    the loader says about a missing file, and there is no second place to look.
    A fallback to the repository root would restore exactly the behaviour this
    rule exists to remove, and would do it silently.
    """

    if runtime_config is not None:
        return Path(runtime_config)
    return Path(config).parent / RUNTIME_CONFIG_FILENAME


def _bridge(args) -> Optional[ConversionBridge]:
    """The conversion bridge, or ``None`` when there is no endpoint to use.

    A missing or unreadable ``runtime.yaml`` is **not** a fatal error here.
    The sync's own configuration is a different file with a different audience
    (`config.py`), and a curator reading a folder should not be stopped by the
    configuration of a gateway they have not set up yet: every editor workflow
    is then reported as needing an export, which is exactly what happened
    before this capability existed.
    """

    if args.comfy_url:
        return ConversionBridge(args.comfy_url)
    from ...config import ConfigError, load_config  # noqa: PLC0415

    try:
        runtime = load_config(runtime_config_path(args.config, args.runtime_config))
    except (ConfigError, OSError):
        return None
    return ConversionBridge(runtime.comfy.base_url)


def _fail(stream: TextIO, message: str) -> None:
    """The failure shape the runtime scripts already render.

    A ``[FAIL]`` headline and indented detail, so the front end can print the
    loader's own words instead of inventing a message of its own -- the same
    contract ``Read-LcConfig`` reads in ``scripts/lib/Common.ps1``.
    """

    lines = str(message).splitlines() or [""]
    print("[FAIL] {}".format(lines[0]), file=stream, flush=True)
    for line in lines[1:]:
        print("       {}".format(line), file=stream, flush=True)


__all__ = [
    "EXIT_ATTENTION",
    "EXIT_FATAL",
    "EXIT_OK",
    "RUNTIME_CONFIG_FILENAME",
    "RUNTIME_CONFIG_RELATIVE_PATH",
    "build_parser",
    "main",
    "runtime_config_path",
]
