"""Discovery and loading of a workflow registry.

The registry root is **configuration, never a fixed path** (``workflows.registry``
in ``config/local/runtime.yaml``, see `docs/runtime.md`).  Nothing in this
package knows a default location, and the caller always supplies the root.

Ordering
--------
Filesystem enumeration order is not a rule: it varies by filesystem, by
platform and by the order files happened to be written.  So:

* workflows are sorted by ``id`` ascending in **plain Unicode codepoint order**
  (Python's default ``str`` comparison), never locale-aware collation, which
  varies by machine;
* diagnostics are sorted the same way, by workflow id first
  (:attr:`Diagnostic.sort_key`).

Two runs over the same registry therefore produce byte-identical output.

Failure behaviour
-----------------
* **Registry-fatal** -- the root is missing, is not a directory, or cannot be
  read: :class:`~localcanvas_gateway.workflows.errors.RegistryError` is raised,
  because a half-empty registry that looks successful is worse than a failure.
* **Workflow-isolated** -- one definition is malformed or invalid: it is
  omitted, every other workflow still loads, and a diagnostic says why.
* An **empty** root is not an error.  It is an empty registry.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple, Union

from .definition import LoadedDefinition, load_definition
from .diagnostics import Diagnostic
from .errors import RegistryError
from .model import WorkflowDefinition

#: Definition files are recognized by extension, case-insensitively.
DEFINITION_SUFFIXES = (".yaml", ".yml")


@dataclass(frozen=True)
class Registry:
    """Every workflow that loaded, and every reason one did not."""

    root: Path
    workflows: Tuple[WorkflowDefinition, ...] = ()
    diagnostics: Tuple[Diagnostic, ...] = ()

    def __len__(self) -> int:
        return len(self.workflows)

    def __iter__(self) -> Iterator[WorkflowDefinition]:
        return iter(self.workflows)

    @property
    def ids(self) -> Tuple[str, ...]:
        return tuple(workflow.id for workflow in self.workflows)

    def get(self, workflow_id: str) -> Optional[WorkflowDefinition]:
        for workflow in self.workflows:
            if workflow.id == workflow_id:
                return workflow
        return None

    def summary_view(self) -> List[dict]:
        """The picker-level list.  Carries no node id (`docs/api.md`)."""

        return [workflow.summary_view() for workflow in self.workflows]


def load_registry(root: Union[str, Path]) -> Registry:
    """Load and validate every workflow definition under ``root``.

    Raises :class:`RegistryError` when the root itself is unusable.
    """

    root_path = Path(root)
    _check_root(root_path)

    loaded: List[LoadedDefinition] = []
    for path in _iter_definition_files(root_path):
        loaded.append(load_definition(path))

    workflows, diagnostics = _resolve(loaded)
    return Registry(root=root_path, workflows=workflows, diagnostics=diagnostics)


def _check_root(root: Path) -> None:
    if not root.exists():
        raise RegistryError("workflow registry root does not exist: {}".format(root))
    if not root.is_dir():
        raise RegistryError("workflow registry root is not a directory: {}".format(root))


def _iter_definition_files(root: Path) -> List[Path]:
    """Every YAML definition under ``root``, sorted for a stable diagnostic order.

    Directories whose name starts with a dot are skipped: an editor's or a
    tool's private directory is not a curator's workflow folder.
    """

    def _raise(error: OSError) -> None:
        raise error

    found: List[Path] = []
    try:
        for dirpath, dirnames, filenames in os.walk(str(root), onerror=_raise):
            dirnames[:] = sorted(name for name in dirnames if not name.startswith("."))
            for name in sorted(filenames):
                if name.startswith("."):
                    continue
                if name.lower().endswith(DEFINITION_SUFFIXES):
                    found.append(Path(dirpath) / name)
    except OSError as exc:
        raise RegistryError(
            "workflow registry root cannot be read: {} ({})".format(root, exc.strerror or exc)
        ) from exc
    return found


def _resolve(
    loaded: List[LoadedDefinition],
) -> Tuple[Tuple[WorkflowDefinition, ...], Tuple[Diagnostic, ...]]:
    """Apply cross-definition rules, then order everything deterministically."""

    diagnostics: List[Diagnostic] = []
    for item in loaded:
        diagnostics.extend(item.diagnostics)

    # Keyed off the id each definition *claims*, not off the ones that happened
    # to validate.  A claimant that is independently broken still claims the id,
    # and skipping it here would mean that fixing an unrelated typo in one file
    # flips the other workflow from working to both-rejected.
    by_id: Dict[str, List[LoadedDefinition]] = {}
    for item in loaded:
        if item.workflow_id:
            by_id.setdefault(item.workflow_id, []).append(item)

    duplicated = {
        workflow_id: claimants
        for workflow_id, claimants in by_id.items()
        if len(claimants) > 1
    }

    for workflow_id, claimants in duplicated.items():
        # Never silently pick a winner: a user editing workflow A and seeing
        # nothing change because workflow B shadowed it has no way to find out.
        files = sorted(str(claimant.source) for claimant in claimants)
        for claimant in claimants:
            others = [name for name in files if name != str(claimant.source)]
            diagnostics.append(
                Diagnostic(
                    source=claimant.source,
                    workflow_id=workflow_id,
                    message=(
                        "duplicate workflow id {!r}, also declared in {}; all {} definitions "
                        "claiming this id are rejected".format(
                            workflow_id, ", ".join(others), len(claimants)
                        )
                    ),
                )
            )

    workflows: List[WorkflowDefinition] = [
        item.workflow
        for item in loaded
        if item.workflow is not None and item.workflow.id not in duplicated
    ]

    workflows.sort(key=lambda workflow: workflow.id)
    diagnostics.sort(key=lambda diagnostic: diagnostic.sort_key)
    return tuple(workflows), tuple(diagnostics)


__all__ = ["Registry", "load_registry", "DEFINITION_SUFFIXES"]
