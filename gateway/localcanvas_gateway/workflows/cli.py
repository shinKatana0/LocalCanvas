"""Offline curator commands.

    python -m localcanvas_gateway.workflows <registry root>
    python -m localcanvas_gateway.workflows sync --config <path> [--dry-run]

A curator can check a definition, or read their own ComfyUI workflow folder,
without starting a generation: nothing here contacts ComfyUI or the network.
Exit codes are meant for scripts, and both commands use the same three:

* ``0`` -- nothing needs attention (an empty registry or folder included);
* ``1`` -- something does: a definition was rejected, or a workflow could not
  be imported.  The reasons are printed;
* ``2`` -- the run could not happen at all: an unusable registry root, a
  missing or malformed sources configuration, an unreadable source folder.

``sync`` is dispatched by hand rather than by an argparse subparser, and this
is why: the registry root above is a bare positional argument, so a subparser
would make ``<root>`` and a subcommand name the same token and every existing
invocation would become ambiguous.  Reading the first word instead keeps
``python -m localcanvas_gateway.workflows <root>`` meaning exactly what it
always meant.
"""

from __future__ import annotations

import argparse
from typing import List, Optional, Sequence, TextIO

from .errors import RegistryError
from .registry import load_registry

#: The word that selects the sync engine.  A registry root spelled exactly like
#: this would be shadowed, which is why it is a word no folder is called and
#: why the alternative -- a subparser -- is not used (see the module docstring).
SYNC_COMMAND = "sync"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m localcanvas_gateway.workflows",
        description="Validate a LocalCanvas workflow registry offline.",
    )
    parser.add_argument(
        "root",
        help="the registry root: the folder holding your workflow YAML definitions",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="print only problems and the summary",
    )
    return parser


def main(
    argv: Optional[Sequence[str]] = None,
    stream: Optional[TextIO] = None,
    err: Optional[TextIO] = None,
) -> int:
    import sys

    out = stream if stream is not None else sys.stdout
    argv = list(sys.argv[1:] if argv is None else argv)

    if argv and argv[0] == SYNC_COMMAND:
        # Imported here and nowhere else. The sync engine is a curator tool
        # that happens to share this package; importing it at module level
        # would put it into every process that validates a registry, and into
        # the gateway's own import graph through it.
        from .sync.cli import main as sync_main

        return sync_main(argv[1:], out=out, err=err)

    args = build_parser().parse_args(argv)

    try:
        registry = load_registry(args.root)
    except RegistryError as exc:
        print("[FAIL] {}".format(exc), file=out)
        return 2

    lines: List[str] = []
    for diagnostic in registry.diagnostics:
        lines.append("[FAIL] {}".format(diagnostic))
    if not args.quiet:
        for workflow in registry.workflows:
            lines.append(
                "[ OK ] {} ({} field{}) - {}".format(
                    workflow.id,
                    len(workflow.inputs),
                    "" if len(workflow.inputs) == 1 else "s",
                    workflow.source,
                )
            )
    for line in lines:
        print(line, file=out)

    print(
        "\n{} workflow{} loaded, {} rejected, from {}".format(
            len(registry.workflows),
            "" if len(registry.workflows) == 1 else "s",
            len({diagnostic.source for diagnostic in registry.diagnostics}),
            registry.root,
        ),
        file=out,
    )
    return 1 if registry.diagnostics else 0


__all__ = ["SYNC_COMMAND", "main", "build_parser"]
