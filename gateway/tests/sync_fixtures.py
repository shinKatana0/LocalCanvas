"""Shared scaffolding for the workflow sync tests.

Two habits are built into the workspace rather than remembered test by test:

* **every path contains a space.**  The repository's script suite does the same,
  and for the same reason -- a path with a space is the ordinary case on
  Windows, and a suite whose paths have none proves nothing about it.
* **the source tree and the output tree are separate directories**, so a test
  that says "nothing was written into the sources" is asking a question the
  workspace can actually answer.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Tuple

from localcanvas_gateway.workflows.sync import load_sources_config

#: The smallest thing that is unmistakably an API-format graph.
#:
#: The loader's value ends in a weights suffix on purpose.  The importer reads
#: every literal input of a graph and refuses to guess: a bare ``PLACEHOLDER``
#: is a string it can prove nothing about, and every workflow built on this
#: fixture would be ``NEEDS_REVIEW`` -- which is the importer's own rule, not
#: an accident, and would make this fixture useless for the tests about
#: discovery, identity and the inventory that use it.  With a suffix it is
#: what it was always meant to be: a loader naming a file, which the importer
#: locks and nobody ever sees.
API_GRAPH: Dict[str, Any] = {
    "10": {
        "class_type": "ExampleLoader",
        "inputs": {"name": "PLACEHOLDER.safetensors"},
    },
    "20": {"class_type": "ExampleSampler", "inputs": {"seed": 0, "model": ["10", 0]}},
}

#: The smallest thing that is unmistakably the editor's own save format.
UI_GRAPH: Dict[str, Any] = {
    "last_node_id": 2,
    "last_link_id": 1,
    "nodes": [
        {"id": 1, "type": "ExampleLoader", "widgets_values": ["PLACEHOLDER"]},
        {"id": 2, "type": "ExampleSampler", "widgets_values": [0]},
    ],
    "links": [[1, 1, 0, 2, 0, "MODEL"]],
    "version": 0.4,
}


def api_graph(seed: int = 0) -> Dict[str, Any]:
    """An API graph that differs from every other seed's."""

    graph = json.loads(json.dumps(API_GRAPH))
    graph["20"]["inputs"]["seed"] = seed
    return graph


def write_json(path: Path, document: Any, *, indent: Optional[int] = None) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(document, indent=indent), encoding="utf-8")
    return path


class SyncWorkspace:
    """A repository root, one or more source folders, and a configuration."""

    def __init__(self, tmp_path: Path) -> None:
        self.base = tmp_path / "lc sync workspace"
        self.repo = self.base / "repo root"
        self.outside = self.base / "not a source"
        (self.repo / "config" / "local").mkdir(parents=True)
        self.outside.mkdir(parents=True)
        self.config_path = self.repo / "config" / "local" / "workflow sources.yaml"
        self.sources: List[Path] = []

    # -- building ----------------------------------------------------------

    def add_source(self, name: str = "my workflows") -> Path:
        folder = self.base / name
        folder.mkdir(parents=True, exist_ok=True)
        self.sources.append(folder)
        return folder

    def write_config(
        self,
        *,
        sources: Optional[Iterable[Any]] = None,
        definitions: str = "config/local/workflows",
        imported_api: str = "config/local/imported-workflows",
        inventory: str = "config/local/workflow-inventory.json",
        sync: Optional[Mapping[str, bool]] = None,
        body: Optional[str] = None,
    ) -> Path:
        if body is not None:
            self.config_path.write_text(body, encoding="utf-8")
            return self.config_path
        entries = list(sources) if sources is not None else list(self.sources)
        lines = ["sources:"]
        for entry in entries:
            if isinstance(entry, tuple):
                folder, recursive = entry
            else:
                folder, recursive = entry, True
            lines.append('  - path: "{}"'.format(str(folder).replace("\\", "/")))
            lines.append("    recursive: {}".format("true" if recursive else "false"))
        lines += [
            "output:",
            '  definitions: "{}"'.format(definitions),
            '  imported_api: "{}"'.format(imported_api),
            '  inventory: "{}"'.format(inventory),
        ]
        if sync is not None:
            lines.append("sync:")
            for key, value in sync.items():
                lines.append("  {}: {}".format(key, "true" if value else "false"))
        lines.append("")
        self.config_path.write_text("\n".join(lines), encoding="utf-8")
        return self.config_path

    def load(self):
        return load_sources_config(self.config_path)

    # -- looking -----------------------------------------------------------

    @property
    def inventory_path(self) -> Path:
        return self.repo / "config" / "local" / "workflow-inventory.json"

    @property
    def output_tree(self) -> Path:
        """Everything the configuration allows the sync to write into."""

        return self.repo / "config" / "local"

    def read_inventory(self) -> Dict[str, Any]:
        return json.loads(self.inventory_path.read_text(encoding="utf-8"))

    def output_snapshot(self) -> Dict[str, Tuple[int, str]]:
        """The output tree without the configuration file that lives beside it.

        A user keeps ``workflow-sources.yaml`` in ``config/local/`` and points
        the outputs at the same folder, which is the arrangement the shipped
        example produces -- so the configuration is genuinely in there, and it
        is not something the sync wrote.  Excluding it by name keeps "what did
        this run produce" an answerable question.
        """

        snapshot = tree_snapshot(self.output_tree)
        snapshot.pop(self.config_path.name, None)
        return snapshot

    def output_names(self) -> List[str]:
        return sorted(self.output_snapshot())


def tree_snapshot(root: Path) -> Dict[str, Tuple[int, str]]:
    """Every file under ``root``, by relative path, with size and content hash.

    Content rather than mtime: a filesystem's timestamp granularity is coarse
    enough that a fast test could rewrite a file and see the same stamp, and a
    tripwire that can be fooled by being quick is not a tripwire.
    """

    snapshot: Dict[str, Tuple[int, str]] = {}
    if not root.exists():
        return snapshot
    for current, directories, files in os.walk(str(root)):
        directories.sort()
        for name in sorted(files):
            path = Path(current) / name
            raw = path.read_bytes()
            relative = os.path.relpath(str(path), str(root)).replace("\\", "/")
            snapshot[relative] = (len(raw), hashlib.sha256(raw).hexdigest())
    return snapshot


def states(report) -> Dict[str, str]:
    """``{source file name: state}`` for everything the report mentions."""

    result = {}
    for item in report.workflows:
        if item.candidate is not None:
            result[item.candidate.relative] = item.state.value
        else:
            result["<gone> " + item.id] = item.state.value
    return result


def make_junction(link: Path, target: Path) -> bool:
    """Create a directory junction, or say it could not be created.

    A junction is the interesting case: unlike a symbolic link it needs no
    elevation and no Developer Mode on Windows, and ``os.path.islink`` answers
    False for one -- so a walk that skips only symlinks walks straight through
    it.  Returns False when this machine cannot make one, so the test that
    wants it can say why it was skipped rather than pass silently.
    """

    if os.name != "nt":
        return False
    try:
        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link), str(target)],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0 and link.exists()


def make_symlink(link: Path, target: Path, *, directory: bool = True) -> bool:
    """Create a symbolic link, or say it could not be created.

    On Windows this needs elevation or Developer Mode, so a False here is a
    fact about the machine and the test that wanted it says so and skips.
    """

    try:
        os.symlink(str(target), str(link), target_is_directory=directory)
    except (OSError, NotImplementedError, AttributeError):
        return False
    return True


__all__ = [
    "API_GRAPH",
    "UI_GRAPH",
    "SyncWorkspace",
    "api_graph",
    "make_junction",
    "make_symlink",
    "states",
    "tree_snapshot",
    "write_json",
]
