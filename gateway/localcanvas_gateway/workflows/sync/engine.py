"""One sync run: discover, hash, classify, analyse, write, and report.

What this file does **not** contain, so that reading it is not misleading: not
one rule about what a node input means.  Which inputs a user should see, what
they are called and which of them are one control is decided in
`analysis.py` and `semantics.py`; putting a definition on disk without
breaking the one already there is `definitions.py`.  This module is the run --
the order the stages happen in, and what each workflow's state ends up being.

Four properties are the reason this file is shaped the way it is:

* **source files are read-only artefacts.**  Nothing here opens a source file
  for writing, renames one, deletes one or normalises one in place, and the
  configuration is refused outright if any output path lies inside a source
  folder -- so there is no path by which a later change could start writing
  there by accident.
* **one bad workflow never stops the good ones.**  A file that cannot be read
  or parsed becomes a state and a reason on its own entry; only a missing
  configuration or an unreadable root stops the run.
* **a source that disappears never deletes anything.**  It is reported, and the
  inventory entry stands until the user acts on it.
* **nothing is imported on a guess.**  A graph carrying an input this cannot
  classify with confidence becomes ``NEEDS_REVIEW`` and produces no definition
  at all, rather than a definition with a field id that was invented.  Every
  id here is a key a user's defaults, drafts and saved setups hang off, and a
  wrong one fails silently in both directions.

The stage order changed once and it matters
===========================================
A workflow saved in ComfyUI's **editor** format is not an execution, and
LocalCanvas does not turn one into the other -- ``bridge.py`` asks the user's
own ComfyUI to do it (`docs/privacy-security.md`, "Converting a workflow
through the user's own ComfyUI").  So a run now goes

    classify -> convert -> analyse -> duplicates -> history -> write

and **analysis is after conversion, never inside classification**.  Anything
this run says about what a workflow exposes, which custom nodes it needs or
what media it takes is said about the API graph that will actually be run --
for an API-format export that is the file, and for an editor one it is what
ComfyUI converted.  Analysing before conversion would have meant analysing a
canvas, which is exactly the guessing the bridge exists to avoid.

A conversion that fails writes nothing and produces no graph: the workflow
keeps ``NEEDS_API_EXPORT`` and gains the bridge's own reason, which names the
category and what to do about it.  There is no path here that reaches a
definition from a conversion that did not work.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

from .analysis import SELECT_FIELD_TYPE, ImportPlan, analyse
from .bridge import (
    Conversion,
    ConversionBridge,
    ConversionStatus,
    api_bytes,
)
from .catalog import Catalog, describe, readable_name
from .classify import (
    ATTENTION_STATES,
    Classification,
    WorkflowFormat,
    WorkflowState,
    classify,
    content_hash,
)
from .config import SourcesConfig
from .contract import RuntimeContract
from .definitions import (
    DefinitionPlan,
    DefinitionWrite,
    ReplacedWords,
    build_definition,
    generated_fingerprint,
    generated_help,
    generated_labels,
    generated_presentation,
    read_curated,
    replaced_by_regeneration,
    write_definition,
)
from .discovery import Candidate, RootScan, is_contained, resolve_root, scan_root
from .errors import InventoryError, SyncConfigError
from .inventory import (
    Inventory,
    InventoryEntry,
    build_document,
    read_inventory,
    write_inventory,
)
from .snapshots import (
    read_snapshot,
    snapshot_document,
    snapshot_path,
    write_snapshot,
)

#: Printed by the front end when a run changed nothing because it was asked
#: not to.  Defined once, here, and carried to the script in the report: the
#: sentence is part of the contract and there must be exactly one copy of it.
DRY_RUN_NOTICE = "Dry run — no files changed."

#: The same sentence for a terminal that cannot carry an em dash.
#:
#: This is not a second wording -- it is the same sentence, and the front end
#: prints the one above wherever the stream can represent it.  It exists
#: because of a rule this repository already settled once, in `pairing.py`:
#: **the rendering adapts to the stream; the stream is never adapted to it.**
#: A Windows console is commonly cp437, cp866 or cp1251, and the alternatives
#: to this line are both worse -- writing raw UTF-8 bytes into such a console
#: puts mojibake in front of the user, and switching the console's code page
#: from inside a script changes state the script does not own and leaves it
#: changed if the script is interrupted.  An em dash that degrades to a hyphen
#: on the terminals that cannot draw one costs nothing and changes nothing.
DRY_RUN_NOTICE_ASCII = "Dry run - no files changed."

#: The report's own shape version, for the same reason the inventory has one.
REPORT_VERSION = 1

#: The line that tells the front end which kind of fatal failure this is (T-0225).
#:
#: Every other fatal failure -- a missing or malformed configuration, a source
#: root that cannot be read, overlapping roots, an output inside a source -- is
#: raised before this run writes a single file.  An inventory that cannot be
#: written is the one that is not: the inventory is written last, after the
#: conversion snapshots, the imported graphs and the definitions.  So its
#: ``[FAIL]`` block carries this line, on its own, and
#: ``scripts/sync-workflows.ps1`` reads it to decide which closing sentence is
#: true.  A token rather than the sentence below, so the wording can change
#: without the front end silently falling back to "nothing was written".
INVENTORY_NOT_WRITTEN_MARKER = "[INVENTORY_NOT_WRITTEN]"

#: What that failure means for the files this run already wrote.
INVENTORY_NOT_WRITTEN_NOTICE = (
    "The inventory could not be written, and it is written last: definitions, "
    "imported workflow graphs and conversion snapshots this run wrote may "
    "already be on disk. The next successful sync will record them."
)

#: `docs/workflow-schema.md`: an id is ``[a-z0-9_-]``.
_ID_ALLOWED = re.compile(r"[^a-z0-9_-]+")
_FALLBACK_ID = "workflow"


@dataclass
class SyncedWorkflow:
    """One workflow, as this run sees it."""

    id: str
    state: WorkflowState
    classification: Optional[Classification]
    candidate: Optional[Candidate]
    reason: Optional[str] = None
    aliases: List[Dict[str, Any]] = field(default_factory=list)
    first_seen: str = ""
    last_seen: str = ""
    extra: Dict[str, Any] = field(default_factory=dict)
    #: ``{field id: label}`` this importer generated the last time it wrote
    #: this workflow's definition, read from the inventory and written back to
    #: it.  Replaced only by a run that actually writes the file: a definition
    #: this run left alone still holds the labels of the run that *did* write
    #: it, and a record moved on ahead of the file would read every one of them
    #: as curated for ever (T-0110).
    generated_labels: Dict[str, str] = field(default_factory=dict)
    #: ``{field id: help}`` this importer generated the last time it wrote this
    #: workflow's definition, carried exactly as ``generated_labels`` above is
    #: and moved by exactly the same runs, for the reason spelled out there.
    generated_help: Dict[str, str] = field(default_factory=dict)
    #: ``{presentation key: value}`` the catalogue generated the last time this
    #: importer wrote this workflow's definition (T-0274), carried exactly as
    #: ``generated_labels`` is and moved by exactly the same runs.
    generated_presentation: Dict[str, Any] = field(default_factory=dict)
    #: The fingerprint of what this importer generated on its own the last time
    #: this workflow's definition was written -- ``None`` for no record -- read
    #: from the inventory and written back to it (T-0246).  Moved by the same
    #: runs, and only those, that move the three records above.
    generated_fingerprint: Optional[str] = None
    #: Whether a runtime contract informed the definition that fingerprint was
    #: taken of -- ``None`` for no record -- carried and moved with it (T-0252).
    generated_with_contract: Optional[bool] = None
    #: Filled for a REMOVED_FROM_SOURCE entry, which has no candidate.
    remembered: Optional[InventoryEntry] = None
    #: The inventory entry this run matched this file to, or ``None`` for a
    #: file the last run did not know, and whether it matched by content --
    #: the same bytes, or the same canonical document -- rather than only by
    #: its path.  Set by :func:`_match_against_history` for every file it
    #: considers, whatever that file's state, so that an editor-format workflow
    #: this run did not convert can still be said to be new, edited, or the
    #: very file the last run imported (T-0350, :func:`editor_history`).
    history: Optional[InventoryEntry] = None
    history_by_content: bool = False
    #: For an editor-format workflow no conversion was attempted for and no
    #: entry was matched to: the entry that records this file as one of its
    #: *aliases* -- a byte-identical copy the last sync folded into it.
    #: Matched by content only.  Set by :func:`_match_editor_aliases`; read
    #: only by :func:`editor_history`.
    alias_of: Optional[InventoryEntry] = None
    #: Filled for an EXACT_DUPLICATE: the workflow this one is a copy of.
    duplicate_of: Optional["SyncedWorkflow"] = None
    #: What the graph turned out to hold: the logical fields, what is not
    #: exposed, and every reason it could not be read with confidence.
    plan: Optional[ImportPlan] = None
    #: What happened to this workflow's definition file in this run.
    definition: Optional[DefinitionWrite] = None
    #: The source bytes, kept so the imported copy of the graph is the file
    #: itself and not a re-serialisation of it -- which would not hash to the
    #: content this run classified.
    raw: Optional[bytes] = None
    #: What the bridge did about this workflow, for an editor-format source.
    #: ``None`` for an API-format export: nothing was asked of ComfyUI about
    #: it, which is not the same as having asked and been refused.
    conversion: Optional[Conversion] = None
    #: The API graph this workflow is imported *from*, and the three forms of
    #: it every later stage needs.  For an API-format export this is the file;
    #: for an editor one it is what ComfyUI converted, and the identity of the
    #: workflow -- its ``content_hash`` -- stays the source file's either way.
    #: All three are set together or not at all: a workflow with a graph is a
    #: workflow this run may import, and there is no half-state.
    graph: Optional[bytes] = None
    graph_document: Optional[Mapping[str, Any]] = None
    graph_hash: str = ""

    @property
    def importable(self) -> bool:
        """Is there an API graph to work from at all?"""

        return self.graph_document is not None


@dataclass
class SyncReport:
    """Everything one run has to say, as data.

    Rendered by ``scripts/sync-workflows.ps1`` and by nothing else: the words a
    user reads are written here, in Python, so that there is one place where
    they are decided and one place where they are tested.
    """

    config: SourcesConfig
    dry_run: bool
    generated: str
    scans: Tuple[RootScan, ...]
    workflows: Tuple[SyncedWorkflow, ...]
    warnings: Tuple[str, ...]
    inventory_path: Path
    inventory_written: bool
    #: How many inputs the ComfyUI this run talked to declares a finite list of
    #: choices for, or ``None`` when this run had no ComfyUI to ask.  ``None``
    #: and ``0`` are different answers: no contract, against a contract that
    #: settled nothing.
    runtime_declared: Optional[int] = None
    #: Whether this run was asked to generate every field label and help line
    #: again (``--regenerate-labels``, T-0116).  The summary line says so only
    #: when it was, so a run that was not asked reports exactly as before.
    regenerate_labels: bool = False

    @property
    def runtime_fields(self) -> int:
        """Logical fields whose choices came from the runtime contract.

        Counted from the plans and not from the contract: what a run resolved
        is how many controls it produced, never how many lists a ComfyUI
        happens to declare.  A ``select`` has no other source in this
        importer -- a graph carries the value a node has and never the list it
        accepts -- so this is exactly the contract's contribution.
        """

        return sum(
            1
            for item in self.workflows
            if item.plan is not None
            for planned in item.plan.fields
            if planned.type == SELECT_FIELD_TYPE
        )

    @property
    def runtime_refused_as_file_names(self) -> int:
        """Inputs whose declared choices were refused for naming files.

        The number that stops the headline lying.  Without it, a run in which
        this ComfyUI declared a list for every held-back input and every one of
        them turned out to be a file picker is indistinguishable from a run in
        which it declared nothing at all: both show no fields and a pile of
        workflows needing review, and the two need opposite actions -- look at
        the workflows, or look at why the runtime said nothing.
        """

        return sum(
            len(item.plan.refused_as_file_names)
            for item in self.workflows
            if item.plan is not None
        )

    @property
    def attention(self) -> Tuple[SyncedWorkflow, ...]:
        return tuple(item for item in self.workflows if item.state in ATTENTION_STATES)

    def counts(self) -> Dict[str, int]:
        counts = {state.value: 0 for state in WorkflowState}
        for item in self.workflows:
            counts[item.state.value] += 1
        return counts

    @property
    def exit_code(self) -> int:
        return 1 if self.attention else 0

    @property
    def definitions_written(self) -> int:
        return sum(
            1
            for item in self.workflows
            if item.definition is not None and item.definition.written
        )

    @property
    def definitions_would_write(self) -> int:
        """How many definitions a real run over the same state would write.

        Only a dry run has an answer that differs from
        :attr:`definitions_written`, which is the answer a real run gives.
        """

        if not self.dry_run:
            return self.definitions_written
        return sum(
            1
            for item in self.workflows
            if item.definition is not None and item.definition.would_write
        )

    @property
    def words_replaced(self) -> Tuple[ReplacedWords, ...]:
        """What a request to regenerate replaced that a normal run would have kept.

        Labels, help lines and presentation keys (T-0274) -- and only those a
        run without the request would have carried from the file; words nobody
        touched follow the generator on any run and are not counted.

        On a dry run, what a real run would replace.  Only definitions that
        were written -- or would be -- count: a write that failed replaced
        nothing, and a definition kept for want of a contract was not touched.
        """

        return tuple(
            words
            for item in self.workflows
            if item.definition is not None
            and (item.definition.written or item.definition.would_write)
            for words in item.definition.replaced
        )

    @property
    def definitions_not_regenerated(self) -> int:
        """Definitions a run asked to regenerate labels left alone anyway.

        The no-contract keep (T-0252) wins over the request, and this is how
        many times it did.
        """

        if not self.regenerate_labels:
            return 0
        return sum(
            1
            for item in self.workflows
            if item.definition is not None and item.definition.regeneration_withheld
        )

    @property
    def definitions_failed(self) -> int:
        return sum(
            1
            for item in self.workflows
            if item.definition is not None and item.definition.problem
        )

    def conversion_counts(self) -> Dict[str, int]:
        """How many editor workflows ended in each bridge status.

        Only workflows the bridge was actually asked about are counted, so a
        registry of API exports reports four zeroes rather than a row of
        numbers about a capability it never used.
        """

        counts = {status.value: 0 for status in ConversionStatus}
        for item in self.workflows:
            if item.conversion is not None:
                counts[item.conversion.status.value] += 1
        return counts

    def unconverted_editor_counts(self) -> Dict[str, int]:
        """What history says about the editor workflows this run did not convert.

        The startup check (``scripts/start.ps1``, T-0350) runs with no bridge,
        so every editor-format workflow in it ends ``NEEDS_API_EXPORT`` -- and a
        check that stopped there would never offer a canvas a user just saved
        for sync, and would call one the last sync imported perfectly well
        "needs a look" on every start for ever.  This is the answer it needs
        instead, decided from the inventory alone: nothing is converted, nothing
        is contacted, and the states above are left exactly as they are.

        Only workflows no conversion was *attempted* for are counted, so a run
        that had a bridge reports only zeroes.  See :func:`editor_history` for
        what each key means.
        """

        counts = {key: 0 for key in EDITOR_HISTORY_KEYS}
        for item in self.workflows:
            verdict = editor_history(item)
            if verdict is not None:
                counts[verdict] += 1
        return counts

    @property
    def comfy_identity(self):
        """The ComfyUI that converted anything in this run, or ``None``."""

        for item in self.workflows:
            if item.conversion is not None and item.conversion.identity is not None:
                return item.conversion.identity
        return None


#: The five answers :func:`editor_history` gives, in the order they are reported.
EDITOR_HISTORY_KEYS = ("new", "changed", "unchanged", "retry", "attention")

#: The states an inventory entry records for a workflow the run that wrote it
#: imported.  For an editor-format workflow that means ComfyUI converted it.
_IMPORTED_STATES = (
    WorkflowState.NEW.value,
    WorkflowState.CHANGED.value,
    WorkflowState.UNCHANGED.value,
)


def editor_history(workflow: SyncedWorkflow) -> Optional[str]:
    """``new`` / ``changed`` / ``unchanged`` / ``attention``, or ``None``.

    ``None`` for anything that is not an editor-format workflow this run left
    unconverted -- an API export, a file that is not a workflow, or a canvas
    the bridge was asked about (whose own state already says what happened).

    For the rest, the answer is the one :func:`_match_against_history` gives an
    API export, read from the entry it matched:

    * ``new`` -- the last run did not know this file;
    * ``changed`` -- it matched only by its path, so the content is different;
    * ``unchanged`` -- the same content, and the entry records an importable
      state: the last run imported it.  Nothing about it needs anybody;
    * ``retry`` -- the same content, recorded ``NEEDS_API_EXPORT`` for a reason
      that was not the file's: the conversion record says ``unavailable`` (no
      browser, ComfyUI not reachable, its frontend never ready -- the bridge
      could not run at all), or there is no record, because that run had no
      ComfyUI to ask.  Offered again, like a new file: the cause may be gone;
    * ``attention`` -- the same content, and the entry records a failure that
      *was* about the file: ComfyUI was asked and refused this graph
      (``failed``), the converted graph could not be read with confidence, the
      file is not a workflow -- or the entry was carried forward as removed,
      which no longer says which of those it was.  Reported, and not offered
      again until the file is edited.

    A file matches an entry through the entry's own path and content, or --
    for a byte-identical copy the last sync recorded as an EXACT_DUPLICATE --
    through one of the entry's ``aliases`` (:func:`_match_editor_aliases`),
    and is then judged by that entry exactly as above.

    An inventory written before this existed records exactly these fields --
    ``state``, ``conversion`` and ``aliases`` have been in every entry since
    conversion was added -- so it needs no migration: an editor workflow it
    recorded as imported is ``unchanged`` at once.  An entry from before
    conversion existed carries no conversion record, so one recorded
    ``NEEDS_API_EXPORT`` there reads as ``retry``: no ComfyUI was ever asked.
    """

    classification = workflow.classification
    if classification is None or classification.format is not WorkflowFormat.UI:
        return None
    if workflow.conversion is not None:
        return None
    entry, by_content = workflow.history, workflow.history_by_content
    if entry is None and workflow.alias_of is not None:
        entry, by_content = workflow.alias_of, True
    if entry is None:
        return "new"
    if not by_content:
        return "changed"
    if entry.state in _IMPORTED_STATES:
        return "unchanged"
    if entry.state == WorkflowState.NEEDS_API_EXPORT.value:
        conversion = entry.conversion if isinstance(entry.conversion, dict) else None
        if conversion is None or conversion.get("status") == _RUN_WIDE_FAILURE:
            return "retry"
    return "attention"


#: The conversion status that means the bridge could not run at all -- a cause
#: about the machine (browser, ComfyUI, its frontend), never about one graph.
#: ``failed`` is the other one: ComfyUI was asked about this graph and refused.
_RUN_WIDE_FAILURE = ConversionStatus.UNAVAILABLE.value


def _match_editor_aliases(
    workflows: Sequence[SyncedWorkflow], previous: Inventory
) -> None:
    """Find the entry a byte-identical copy of a canvas was folded into.

    A sync that converts groups two identical canvases before it looks at
    history, so the copy never claims an entry: it is written as an alias on
    the canonical one.  A run that converts nothing cannot group them -- a
    canvas is not importable until it is converted -- so both reach
    :func:`_match_against_history`, the first claims the entry, and the copy
    would read as new on every start, however many syncs recorded it.  So an
    editor workflow no entry was matched to is looked up among the entries'
    aliases, by content.  Nothing else reads this, and no state, id or entry is
    changed by it.

    **By content only, never by the alias's path.**  An alias claims no entry
    of its own, so a sync meets an *edited* copy as a file no entry explains
    and records it as ``NEW`` under an id of its own.  Matching the path here
    would call the same file "changed" -- a number the sync would then
    contradict.  Both are offered either way; the check says what the sync
    will say.
    """

    by_content: Dict[str, InventoryEntry] = {}
    for entry in previous.entries:
        for alias in entry.aliases:
            if not isinstance(alias, dict):
                continue
            digest = alias.get("content_hash")
            if isinstance(digest, str) and digest:
                by_content.setdefault(digest, entry)
    if not by_content:
        return
    for workflow in workflows:
        classification = workflow.classification
        if (
            classification is None
            or classification.format is not WorkflowFormat.UI
            or workflow.conversion is not None
            or workflow.history is not None
        ):
            continue
        workflow.alias_of = by_content.get(classification.content_hash)


def run_sync(
    config: SourcesConfig,
    *,
    dry_run: bool = False,
    now: Optional[datetime] = None,
    bridge: Optional[ConversionBridge] = None,
    regenerate_labels: bool = False,
) -> SyncReport:
    """Perform one sync over ``config`` and return what it found.

    ``now`` is injectable so that a test can assert two runs over the same tree
    produce byte-identical output.  With a real clock the timestamps differ and
    the comparison would be about the clock rather than about the ordering.

    ``bridge`` is what turns an editor-format workflow into an executable one by
    asking the user's own ComfyUI.  It is injected rather than built here for
    the same reason: it owns a browser and a socket, and a run has to be
    drivable without either.  ``None`` means conversion was not offered at all,
    and every editor workflow then keeps ``NEEDS_API_EXPORT`` with the standing
    instruction -- **never** an inferred graph.

    ``regenerate_labels`` is the explicit request to write every importable
    definition with its field labels and help generated afresh, replacing the
    curated ones for this run and recording what was generated (T-0116).
    Without it nothing about a run differs from before that request existed.
    """

    moment = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    stamp = moment.replace(microsecond=0).isoformat().replace("+00:00", "Z")

    # Resolved, and checked against each other and against the output paths,
    # BEFORE a single byte is read: a configuration that would have written
    # into a source folder must fail without having touched anything.
    roots = tuple(
        (source, resolve_root(source.declared, source.path)) for source in config.sources
    )
    _reject_overlapping_roots(roots)
    _reject_outputs_inside_sources(config, roots)

    scans = tuple(
        scan_root(source.declared, source.path, recursive=source.recursive)
        for source in config.sources
    )

    previous = read_inventory(config.output.inventory)
    warnings: List[str] = []
    if previous.problem:
        warnings.append(previous.problem)

    seen: List[SyncedWorkflow] = []
    for scan in scans:
        for candidate in scan.candidates:
            seen.append(_examine(candidate))

    # The editor-format workflows, converted by ComfyUI itself -- before
    # anything is analysed, because what analysis has to describe is the graph
    # that will really run.
    _convert(
        seen, config, bridge=bridge, dry_run=dry_run, stamp=stamp, warnings=warnings
    )
    contract = _runtime_contract(bridge)
    _analyse(seen, contract=contract)

    if config.sync.detect_duplicates:
        _mark_duplicates(seen)

    used = _match_against_history(seen, previous, stamp)
    _match_editor_aliases(seen, previous)

    _allocate_ids(seen, previous)

    # After the ids and before the inventory: a definition that could not be
    # written is a state this run has to record, and the id it is written
    # under is the one just allocated.
    _generate_definitions(
        seen,
        config,
        dry_run=dry_run,
        has_contract=contract is not None,
        # Whether this run would normally have had a contract: it is given one
        # exactly when it establishes a ComfyUI identity, which it only tries
        # for an editor-format workflow (T-0094).  Consulted only for an
        # inventory that predates the contract record.
        expects_contract=any(
            item.classification is not None
            and item.classification.format is WorkflowFormat.UI
            for item in seen
        ),
        regenerate_labels=regenerate_labels,
    )

    workflows: List[SyncedWorkflow] = list(seen)
    workflows.extend(_carry_forward(previous, used, config, stamp))

    # One canonical entry per distinct content: a duplicate is a row in the
    # report, so the user is told about it, and an alias on the canonical
    # entry rather than an entry of its own.
    entries = [
        _entry_for(item, config, stamp)
        for item in workflows
        if item.state is not WorkflowState.EXACT_DUPLICATE
    ]
    document = build_document(
        entries, generated=stamp, config_source=str(config.source)
    )

    written = False
    if not dry_run:
        try:
            write_inventory(config.output.inventory, document)
        except InventoryError as exc:
            # Too late for "nothing was changed": the files above are written.
            # The inventory's own reason stays the headline; the marker and
            # the notice say what that means for them.
            raise InventoryError(
                "\n".join(
                    (str(exc), INVENTORY_NOT_WRITTEN_MARKER, INVENTORY_NOT_WRITTEN_NOTICE)
                )
            ) from exc
        written = True

    return SyncReport(
        config=config,
        dry_run=dry_run,
        generated=stamp,
        scans=scans,
        workflows=tuple(workflows),
        warnings=tuple(warnings),
        inventory_path=config.output.inventory,
        inventory_written=written,
        runtime_declared=contract.declared if contract is not None else None,
        regenerate_labels=regenerate_labels,
    )


# --------------------------------------------------------------------------
# The configuration checks that need the filesystem
# --------------------------------------------------------------------------


def _reject_overlapping_roots(roots: Sequence[Tuple[Any, Path]]) -> None:
    """Two roots may not be the same folder, nor one inside the other.

    Nested roots are not a harmless duplicate: the same file would be found
    twice, under two different relative paths, and the second copy would then
    be reported as an exact duplicate of the first -- an invented problem in
    the user's folder that they cannot fix, because there is only one file.
    """

    for index, (source, root) in enumerate(roots):
        for other_source, other_root in roots[:index]:
            if is_contained(root, other_root) or is_contained(other_root, root):
                raise SyncConfigError(
                    "sources: {!r} and {!r} are the same folder or one is inside "
                    "the other ({} and {}). List each folder once: a file found "
                    "under both would be reported twice.".format(
                        other_source.declared, source.declared, other_root, root
                    )
                )


def _reject_outputs_inside_sources(
    config: SourcesConfig, roots: Sequence[Tuple[Any, Path]]
) -> None:
    """Nothing LocalCanvas writes may live inside a folder it reads.

    Your workflow folder is yours.  An output written into it would be picked
    up by the next run as a workflow, would appear in your ComfyUI browser, and
    -- the part that matters -- would make "LocalCanvas never modifies a source
    folder" false by construction rather than by accident.
    """

    for key, path in config.output.as_tuple():
        for source, root in roots:
            if is_contained(path, root):
                raise SyncConfigError(
                    "{}: {}: this is inside the source folder {!r}. LocalCanvas "
                    "never writes anything into a folder it reads: your workflow "
                    "files are yours and are only ever read. Point this at a "
                    "folder outside every source, for example under "
                    "config/local/.".format(config.source, key, source.declared)
                )


# --------------------------------------------------------------------------
# One file
# --------------------------------------------------------------------------


def _examine(candidate: Candidate) -> SyncedWorkflow:
    """Read and classify one candidate.  Never raises.

    Only what the bytes themselves decide.  An API-format export already has
    its graph and gets it here; an editor-format one does not have a graph at
    all yet, and getting one is :func:`_convert`'s business.
    """

    try:
        raw = candidate.path.read_bytes()
    except OSError as exc:
        return SyncedWorkflow(
            id="",
            state=WorkflowState.INVALID,
            classification=None,
            candidate=candidate,
            reason="this file could not be read ({}).".format(exc.strerror or exc),
        )
    classification = classify(raw)
    state = classification.state
    workflow = SyncedWorkflow(
        id="",
        state=state if state is not None else WorkflowState.NEW,
        classification=classification,
        candidate=candidate,
        reason=classification.reason,
        raw=raw,
    )
    if classification.importable and classification.document is not None:
        workflow.graph = raw
        workflow.graph_document = classification.document
        workflow.graph_hash = classification.content_hash
    return workflow


# --------------------------------------------------------------------------
# Conversion -- the only way an editor workflow becomes an executable one
# --------------------------------------------------------------------------

#: Said about an editor workflow when no bridge was offered to this run at all.
#: It is the pre-existing instruction and it stays exactly true: without a
#: ComfyUI to ask, exporting by hand really is the only way.
CONVERSION_NOT_OFFERED = (
    "this is a ComfyUI editor (UI format) workflow, and this run had no ComfyUI "
    "to ask, so it was not converted and nothing was written for it. Either run "
    "the sync with ComfyUI available, or open it in ComfyUI and use Workflow -> "
    "Export (API) to save the API-format copy yourself. LocalCanvas never "
    "converts one into the other on its own: that needs the node definitions of "
    "the exact ComfyUI build that saved it, and a wrong guess would run and "
    "produce the wrong result."
)


def _convert(
    workflows: Sequence[SyncedWorkflow],
    config: SourcesConfig,
    *,
    bridge: Optional[ConversionBridge],
    dry_run: bool,
    stamp: str,
    warnings: List[str],
) -> None:
    """Get an API graph for every editor-format workflow, or say why not.

    Three things happen here and the order of them is the cost of the feature:

    1. **nothing at all** when no source is in editor format.  A tree of
       API exports never touches ComfyUI, never opens a socket and never
       launches a browser -- which is what the sync did before this existed;
    2. **the remembered conversion**, when the source bytes and the ComfyUI
       are both the ones a snapshot was made against.  This needs the ComfyUI
       identity but not a browser, which is why the identity comes from
       ComfyUI's own HTTP surface: a run with nothing new to convert costs one
       pair of HTTP requests;
    3. **a real conversion**, which is where the browser is launched -- once,
       for the whole run, on the first workflow that actually needs it.

    A dry run may do all three.  It may not *write* the third one down: see
    ``dry_run`` below, which is the only thing it changes.
    """

    targets = [
        item
        for item in workflows
        if item.classification is not None
        and item.classification.format is WorkflowFormat.UI
    ]
    if not targets:
        return

    if bridge is None:
        for item in targets:
            item.reason = CONVERSION_NOT_OFFERED
        return

    identity = None
    identity_failure: Optional[Conversion] = None
    try:
        identity = bridge.ensure_identity()
    except Exception as exc:  # noqa: BLE001 - BridgeError, and nothing else escapes
        identity_failure = _bridge_failure(exc)

    #: What this run has already established about a given source content, so
    #: that two byte-identical sources are one conversion **and say the same
    #: thing about themselves**.
    #:
    #: It is consulted before the snapshot cache, and that order is the point.
    #: The other way round, the second of two identical canvases found the
    #: snapshot the first had just written and was reported as ``REUSED`` --
    #: which the run then rendered as "reused from an earlier run" on a first
    #: run over a folder that had never been synced. It also meant the second
    #: rewrote the first's snapshot with its own ``source_path`` in it, so the
    #: cache depended on which file the scan happened to reach last.
    #:
    #: Per-source provenance is unaffected: it lives on each workflow's own
    #: conversion record and in the inventory, as the canonical entry plus an
    #: alias carrying the other file's path and hash.
    converted_this_run: Dict[str, Conversion] = {}

    for item in targets:
        classification = item.classification
        assert classification is not None
        if identity_failure is not None:
            _record_conversion(item, identity_failure)
            continue

        assert identity is not None
        already = converted_this_run.get(classification.content_hash)
        if already is not None:
            _record_conversion(item, already)
            continue

        path = snapshot_path(
            config.output,
            source_hash=classification.content_hash,
            identity_digest=identity.digest,
        )
        snapshot, _miss = read_snapshot(
            path,
            source_hash=classification.content_hash,
            identity_digest=identity.digest,
        )
        if snapshot is not None:
            reused = Conversion(
                status=ConversionStatus.REUSED,
                document=snapshot.document,
                identity=identity,
            )
            converted_this_run[classification.content_hash] = reused
            _record_conversion(item, reused)
            continue

        assert item.raw is not None
        result = bridge.convert(item.raw, content_hash=classification.content_hash)
        converted_this_run[classification.content_hash] = result
        _record_conversion(item, result)
        if not result.succeeded or result.document is None or dry_run:
            # A dry run persists nothing -- not an inventory, not a definition,
            # and not this.  Converting in order to *say* what would import is
            # the point of a dry run; remembering it would be a write, and the
            # one promise a dry run makes is that it does not make any.
            continue
        problem = write_snapshot(
            path,
            snapshot_document(
                document=result.document,
                source_hash=classification.content_hash,
                source_path=str(item.candidate.path) if item.candidate else "",
                source_relative=item.candidate.relative if item.candidate else "",
                identity=identity,
                converted_at=stamp,
            ),
        )
        if problem is not None:
            # A warning about this run, never a note on the entry: anything put
            # on ``extra`` is treated as something the curator wrote by hand and
            # is preserved for ever, and "the cache could not be written once"
            # is exactly what must not become permanent.
            warnings.append(
                "{}: {}".format(item.candidate.relative if item.candidate else item.id,
                                problem)
            )


def _record_conversion(workflow: SyncedWorkflow, result: Conversion) -> None:
    """Attach one bridge result, and let it decide the workflow's fate.

    A success gives the workflow the graph every later stage works from.  A
    failure gives it a reason and **no graph at all**: the state stays
    ``NEEDS_API_EXPORT``, no definition is generated, and no API JSON exists
    anywhere for it to be written from.
    """

    workflow.conversion = result
    if result.succeeded and result.document is not None:
        workflow.graph_document = result.document
        workflow.graph = api_bytes(result.document)
        workflow.graph_hash = content_hash(workflow.graph)
        workflow.state = WorkflowState.NEW
        workflow.reason = None
        return
    workflow.state = WorkflowState.NEEDS_API_EXPORT
    workflow.reason = result.detail


def _bridge_failure(exc: Exception) -> Conversion:
    """One whole-run bridge failure, as the answer every workflow gets.

    Deliberately not raised: a ComfyUI that is not running is a thing to report
    about every editor workflow, not a reason for the sync to stop and say
    nothing about the API exports that were perfectly fine.
    """

    category = getattr(exc, "category", None)
    detail = getattr(exc, "detail", None)
    return Conversion(
        status=ConversionStatus.UNAVAILABLE,
        category=category or "BRIDGE_ERROR",
        detail=detail or "the conversion bridge could not run ({}).".format(exc),
    )


# --------------------------------------------------------------------------
# Analysis -- of the graph that will run, never of a canvas
# --------------------------------------------------------------------------


def _runtime_contract(bridge: Optional[ConversionBridge]) -> Optional[RuntimeContract]:
    """What the ComfyUI this run actually talked to declares, or ``None``.

    Asked of the bridge and never fetched here, so there is exactly one place
    in this program that opens a connection to the user's ComfyUI.  It is also
    why a run with nothing to convert gets ``None``: the bridge never probed,
    so no identity was established, and a registry of API exports still costs
    a user who does not need conversion exactly nothing -- not a browser and
    not an HTTP request.

    ``getattr`` rather than a call, because a bridge is injected and a test's
    stand-in is entitled to be smaller than the real thing.  A bridge that
    cannot answer is a run without a contract, which is a run behaving exactly
    as it did before this existed.
    """

    if bridge is None:
        return None
    ask = getattr(bridge, "runtime_contract", None)
    if ask is None:
        return None
    return ask()


def _analyse(
    workflows: Sequence[SyncedWorkflow], *, contract: Optional[RuntimeContract] = None
) -> None:
    """Read every importable graph.  Pure, writes nothing, never raises.

    After conversion, so that an editor workflow is analysed as the API graph
    ComfyUI produced from it.  A workflow with no graph -- invalid, ambiguous,
    or one the bridge could not convert -- is not analysed at all, because
    there is nothing to analyse and inventing something to say about it is the
    whole class of mistake this sync refuses to make.

    ``contract`` is what that same ComfyUI declares its inputs accept.  It can
    only ever settle an input the graph left unsettled: `analysis.py` holds
    that ordering, and this module does not get a say in it.
    """

    for workflow in workflows:
        if workflow.graph_document is None:
            continue
        workflow.plan = analyse(workflow.graph_document, contract=contract)
        if workflow.plan.needs_review:
            workflow.state = WorkflowState.NEEDS_REVIEW
            workflow.reason = workflow.plan.review_reason


# --------------------------------------------------------------------------
# Duplicates
# --------------------------------------------------------------------------


def _mark_duplicates(workflows: Sequence[SyncedWorkflow]) -> None:
    """One canonical entry per distinct content; the rest become aliases.

    Only importable workflows are grouped.  Two identical *broken* files are
    two broken files: folding one behind the other would hide half the problem
    and leave the user fixing the same thing twice.  That is why this runs
    **after** conversion rather than before: two identical editor workflows
    ComfyUI refuses are two refusals, each reported against its own file, and
    grouping them on their bytes first would have hidden one of them behind
    the other.  Two that convert are one workflow, and the conversion was done
    once -- the bridge remembers what it has already been asked.

    The key is still the **source** content, never the converted graph: it is
    the file the user has, and it is what their next edit changes.

    Nothing is deleted, nothing is moved, and no two workflows are ever merged
    because their names look alike -- only identical content counts.
    """

    canonical: Dict[str, SyncedWorkflow] = {}
    for workflow in workflows:
        classification = workflow.classification
        if classification is None or not workflow.importable:
            continue
        key = classification.canonical_hash or classification.content_hash
        first = canonical.get(key)
        if first is None:
            canonical[key] = workflow
            continue
        candidate = workflow.candidate
        assert candidate is not None
        first.aliases.append(
            {
                "source_root": str(candidate.root),
                "source_path": str(candidate.path),
                "source_relative": candidate.relative,
                "content_hash": classification.content_hash,
            }
        )
        workflow.state = WorkflowState.EXACT_DUPLICATE
        workflow.duplicate_of = first
        workflow.reason = (
            "this file has exactly the same content as {}. That one is the "
            "canonical copy; this one is recorded as an alias of it, and neither "
            "file is touched.".format(
                first.candidate.path if first.candidate else "another source file"
            )
        )


# --------------------------------------------------------------------------
# History
# --------------------------------------------------------------------------


def _match_against_history(
    workflows: Sequence[SyncedWorkflow],
    previous: Inventory,
    stamp: str,
) -> Dict[int, bool]:
    """Decide NEW / CHANGED / UNCHANGED, and carry each id forward.

    Identity is content, never the file name.  A file that was renamed but
    holds the same bytes matches on its hash and is UNCHANGED; two files that
    happen to share a name in two different folders match on neither and are two
    workflows.  Only when no content matches does the source path decide, and
    then it means "the file at this path was edited".

    That has to be true of the run and not merely of each file in turn, which is
    why this is two passes over every candidate rather than one decision per
    candidate.  With one pass, a file examined earlier could claim an entry by
    its **path** that a file examined later would have claimed by its
    **content** -- rename ``m.json`` to ``z.json`` and write something else at
    ``m.json``, and the id follows the path; rename it to ``0first.json``
    instead and the id follows the content.  Which file inherits the id would
    depend on how the names happen to sort.

    Nothing is lost either way: every entry survives the run.  It matters
    because the id is what a user's defaults, saved setups and imported profile
    are keyed on, so an id inheriting to the wrong content silently attaches
    somebody's saved settings to a different workflow.  Content is therefore
    resolved for every candidate first, and the path only claims what is left.

    Returns the entries this run accounted for, so that
    :func:`_carry_forward` knows which ones no file explains any more.
    """

    used: Dict[int, bool] = {}
    considered: List[SyncedWorkflow] = []
    for workflow in workflows:
        workflow.last_seen = stamp
        workflow.first_seen = stamp
        if workflow.duplicate_of is not None:
            # A duplicate is not a workflow of its own -- it is an alias on the
            # canonical entry -- so it never claims an inventory entry. If it
            # did, it would claim the entry of whatever used to live at its
            # path, and that entry would then vanish from the inventory without
            # ever being reported: a silent deletion, which is the one thing
            # this run must never do.
            continue
        if workflow.classification is None:
            continue
        considered.append(workflow)

    by_content = previous.by_content_hash()
    by_canonical = previous.by_canonical_hash()
    by_path = previous.by_source_path()

    #: ``(entry, matched_by_content)`` for each considered workflow, or None.
    found: List[Optional[Tuple[InventoryEntry, bool]]] = [None] * len(considered)

    # Phase 1 -- content, across every candidate, before any path is consulted.
    for index, workflow in enumerate(considered):
        classification = workflow.classification
        assert classification is not None
        entry = by_content.get(classification.content_hash)
        if entry is None or id(entry) in used:
            entry = (
                by_canonical.get(classification.canonical_hash)
                if classification.canonical_hash
                else None
            )
        if entry is None or id(entry) in used:
            continue
        used[id(entry)] = True
        found[index] = (entry, True)

    # Phase 2 -- the path, over what content did not claim.
    for index, workflow in enumerate(considered):
        if found[index] is not None or workflow.candidate is None:
            continue
        entry = by_path.get(os.path.normcase(str(workflow.candidate.path)))
        if entry is None or id(entry) in used:
            continue
        used[id(entry)] = True
        found[index] = (entry, False)

    for index, workflow in enumerate(considered):
        matched = found[index]
        if matched is None:
            continue
        entry, matched_content = matched
        workflow.history = entry
        workflow.history_by_content = matched_content
        workflow.id = entry.id
        workflow.first_seen = entry.first_seen or stamp
        workflow.extra = dict(entry.extra)
        workflow.generated_labels = dict(entry.generated_labels)
        workflow.generated_help = dict(entry.generated_help)
        workflow.generated_presentation = dict(entry.generated_presentation)
        workflow.generated_fingerprint = entry.generated_fingerprint
        workflow.generated_with_contract = entry.generated_with_contract
        if workflow.state is not WorkflowState.NEW:
            # A file that needs attention keeps saying so, whatever it used to be.
            continue
        workflow.state = (
            WorkflowState.UNCHANGED if matched_content else WorkflowState.CHANGED
        )

    return used


def _carry_forward(
    previous: Inventory,
    used: Mapping[int, bool],
    config: SourcesConfig,
    stamp: str,
) -> List[SyncedWorkflow]:
    """Entries no source file accounted for this run.

    They are kept.  A workflow file that is gone from the user's folder -- moved
    to another disk, renamed while ComfyUI was closed, on a drive that is not
    plugged in today -- is reported, and that is all: deleting what LocalCanvas
    derived from it because the file was not there for one run would destroy
    work the user did on this side of the fence.
    """

    carried: List[SyncedWorkflow] = []
    for entry in previous.entries:
        if id(entry) in used:
            continue
        state = (
            WorkflowState.REMOVED_FROM_SOURCE
            if config.sync.detect_removed
            else _state_or_default(entry.state)
        )
        reason = entry.reason
        if config.sync.detect_removed:
            reason = (
                "no file under any configured source folder holds this workflow "
                "any more. Nothing has been deleted: this entry stands until you "
                "act on it. Its last known source was {}.".format(entry.source_path)
            )
        carried.append(
            SyncedWorkflow(
                id=entry.id,
                state=state,
                classification=None,
                candidate=None,
                reason=reason,
                aliases=list(entry.aliases),
                first_seen=entry.first_seen,
                last_seen=entry.last_seen,
                extra=dict(entry.extra),
                generated_labels=dict(entry.generated_labels),
                generated_help=dict(entry.generated_help),
                generated_presentation=dict(entry.generated_presentation),
                generated_fingerprint=entry.generated_fingerprint,
                generated_with_contract=entry.generated_with_contract,
                remembered=entry,
            )
        )
    carried.sort(key=lambda item: (item.id.casefold(), item.id))
    return carried


def _state_or_default(value: str) -> WorkflowState:
    try:
        return WorkflowState(value)
    except ValueError:
        return WorkflowState.NEEDS_REVIEW


# --------------------------------------------------------------------------
# Ids
# --------------------------------------------------------------------------


def _allocate_ids(workflows: Sequence[SyncedWorkflow], previous: Inventory) -> None:
    """Give every workflow a LocalCanvas id, once, and keep it.

    An id is allocated when a workflow is first seen and then travels with it,
    which is what lets CHANGED mean anything: an id derived from the content
    would change whenever the content did, and every edit would look like a
    different workflow.  The first id is derived from the file name because
    that is the only human-readable thing available -- a name is a starting
    point for an id, and never the thing that decides identity.
    """

    taken = {workflow.id for workflow in workflows if workflow.id}
    taken.update(entry.id for entry in previous.entries)
    for workflow in workflows:
        if workflow.id or workflow.duplicate_of is not None:
            continue
        workflow.id = _unique(_slug(workflow.candidate), taken)
        taken.add(workflow.id)
    # A duplicate is the same workflow as its canonical copy, so it wears the
    # same id rather than an invented one of its own.
    for workflow in workflows:
        if workflow.duplicate_of is not None:
            workflow.id = workflow.duplicate_of.id


def _slug(candidate: Optional[Candidate]) -> str:
    if candidate is None:
        return _FALLBACK_ID
    stem = Path(candidate.relative).stem
    slug = _ID_ALLOWED.sub("-", stem.casefold()).strip("-")
    return slug or _FALLBACK_ID


def _unique(slug: str, taken) -> str:
    if slug not in taken:
        return slug
    index = 2
    while "{}-{}".format(slug, index) in taken:
        index += 1
    return "{}-{}".format(slug, index)


# --------------------------------------------------------------------------
# The definitions
# --------------------------------------------------------------------------

#: The states a definition is generated for.  A duplicate is not one of them:
#: it is an alias of its canonical copy, which writes the one definition they
#: share, and a second write under the same id would be two runs racing over
#: one file.
_IMPORT_STATES = (WorkflowState.NEW, WorkflowState.CHANGED, WorkflowState.UNCHANGED)

#: Said about a definition this run deliberately left alone.
KEPT_NOTICE = (
    "this workflow has not changed, so the definition already on disk was left "
    "exactly as it is -- including anything you have written in it."
)

#: What a definition written again for an unchanged workflow keeps and what it
#: replaces -- measured on ``build_definition``, not recalled: ``name`` and
#: ``translation`` are carried from the file whoever wrote them; a ``label``,
#: a ``help`` and a ``presentation`` key (T-0274) are carried when they differ
#: from what this importer last generated, or when there is no record of that;
#: and everything else -- the field list, each field's ``type``, ``section``,
#: ``default``, ``options``, bounds, ``bind`` and any key the builder does not
#: write -- comes from the workflow again.  An untouched generated presentation
#: key is therefore not "kept from the file": it follows the catalogue.
_REWRITE_REPLACES = (
    "the list of fields and each field's type, section, default, choices, "
    "limits and bindings"
)
_REWRITE_KEEPS = (
    "its name, its translation setting, and every presentation key, field "
    "label and help line you wrote"
)

#: Said about a definition written again although its workflow did not change.
REWRITTEN_NOTICE = (
    "this workflow file has not changed, but this importer now reads it "
    "differently, so its definition was written again. Kept from the file: "
    + _REWRITE_KEEPS
    + ". Everything else was generated again from the workflow -- "
    + _REWRITE_REPLACES
    + " -- so an edit you made to any of those was replaced."
)

#: Said about an unchanged workflow's definition that a run with no runtime
#: contract left alone because the definition on disk was made with one
#: (T-0252).  Without a contract this run generates less -- no declared bounds,
#: no declared types -- so a difference it finds says nothing about the
#: importer, and writing on it would take away what the better-informed run
#: put there.
NO_CONTRACT_KEPT_NOTICE = (
    "this workflow has not changed, and this run had no answer from ComfyUI "
    "about what its inputs accept, which the definition on disk was generated "
    "with -- so the definition was left exactly as it is, including anything "
    "you have written in it. A run with ComfyUI available writes it again if "
    "this importer now reads the workflow differently."
)

#: The same, for an inventory written before the contract was recorded: the
#: definition on disk *may* have been generated with a contract, and this run
#: would normally have had one, so it is kept on the same reasoning.
NO_CONTRACT_MAYBE_KEPT_NOTICE = (
    "this workflow has not changed, and this run had no answer from ComfyUI "
    "about what its inputs accept, which the definition on disk may have been "
    "generated with -- so the definition was left exactly as it is, including "
    "anything you have written in it. A run with ComfyUI available writes it "
    "again if this importer now reads the workflow differently."
)

#: Said about a definition a dry run did not write.
DRY_RUN_DEFINITION_NOTICE = "a dry run writes nothing, so this was not written."

#: The opening of every sentence a run asked to regenerate labels says about a
#: definition (T-0116).  Loud on purpose: this is the one request that takes a
#: curator's words out of a file, and each workflow says it happened.  Since
#: T-0274 the request covers the presentation the catalogue generates as well.
REGENERATED_OPENING = (
    "this run was asked to generate the field labels, help lines and "
    "presentation again"
)

#: What that request leaves alone, said once for both forms of the sentence:
#: the two things it never covers, and the presentation keys nothing generates.
_REGENERATION_KEEPS = (
    "A name or translation setting you wrote, and any presentation key this "
    "importer never generates,"
)

#: Said about a definition that request wrote; ``{replaced}`` is
#: :func:`replaced_sentence`'s account of what it took out of the file.
REGENERATED_NOTICE = (
    REGENERATED_OPENING
    + ", so it kept none of them from the definition on disk: {replaced}. "
    + _REGENERATION_KEEPS
    + " was kept as always."
)

#: The dry run's form: what a real run with the same request would do.
DRY_RUN_REGENERATED_NOTICE = (
    REGENERATED_OPENING
    + ", so a real run would keep none of them from the definition on disk: "
    "{replaced}. "
    + _REGENERATION_KEEPS
    + " would be kept as always. A dry run writes nothing, so this was not "
    "written."
)

#: Said when what that request generates is already, byte for byte, the
#: definition on disk -- so it replaced nothing and wrote nothing.
REGENERATED_ALREADY_NOTICE = (
    REGENERATED_OPENING
    + ", and the result is exactly the definition already on disk, so nothing "
    "was written and nothing you wrote was replaced."
)

#: Appended to the no-contract keep (T-0252) when the run was asked to
#: regenerate labels: the keep wins, and the request not being carried out for
#: this workflow is said rather than left to be noticed.
REGENERATED_NOT_DONE_NOTICE = (
    " This run was asked to generate the field labels, help lines and "
    "presentation again, "
    "and did not for this workflow: writing it without that answer from ComfyUI "
    "would also have taken away what its fields accept. Run it again with "
    "ComfyUI available."
)

#: The same, after the keep for an inventory with no contract record
#: (``NO_CONTRACT_MAYBE_KEPT_NOTICE``): the definition only *may* have been made
#: with that answer, so the loss is said as a possibility, not a fact.
REGENERATED_MAYBE_NOT_DONE_NOTICE = (
    " This run was asked to generate the field labels, help lines and "
    "presentation again, "
    "and did not for this workflow: the definition may have been made with "
    "ComfyUI's answer about what its fields accept, and writing it without that "
    "answer could have taken that away. Run it again with ComfyUI available."
)

#: The dry run's form of ``REWRITTEN_NOTICE``: what a real run would do, and
#: that this one did not.
DRY_RUN_REWRITE_NOTICE = (
    "this workflow file has not changed, but this importer now reads it "
    "differently, so a real run would write its definition again. It would "
    "keep from the file: "
    + _REWRITE_KEEPS
    + ". Everything else would be generated again from the workflow -- "
    + _REWRITE_REPLACES
    + " -- so an edit you made to any of those would be replaced. A dry run "
    "writes nothing, so this was not written."
)

#: Said about the conversions a dry run made, and it is the distinction the
#: whole dry-run promise turns on.  A dry run **does** ask ComfyUI, because
#: otherwise it could not say which workflows would import -- and it keeps
#: none of the answer.  A reader who saw "66 converted" under a dry run and no
#: sentence like this one would reasonably conclude that sixty-six snapshots
#: had just been written.  ASCII, like every other sentence that crosses the
#: seam into a Windows console.
DRY_RUN_CONVERSION_NOTICE = (
    "a dry run converts in order to see what would import, and keeps none of "
    "it: nothing was remembered and nothing was written."
)


def _generate_definitions(
    workflows: Sequence[SyncedWorkflow],
    config: SourcesConfig,
    *,
    dry_run: bool,
    has_contract: bool = False,
    expects_contract: bool = False,
    regenerate_labels: bool = False,
) -> None:
    """Turn every importable graph into a definition on disk.

    A failure here is per workflow, like every other failure in this run: the
    workflow says why it needs looking at, whatever definition it had before
    is still there, and every other workflow is written regardless.

    ``has_contract`` is whether this run's ComfyUI declared what its inputs
    accept; it is recorded with every definition written, and it is what stops
    a run without one rewriting an unchanged definition made with one (T-0252).
    ``expects_contract`` answers the same question for an inventory that
    predates that record -- see :func:`_kept_for_want_of_a_contract`.

    ``regenerate_labels`` (T-0116) changes three things and nothing else: an
    unchanged definition is not kept on an equal fingerprint, every definition
    is built with its labels, help and generated presentation keys (T-0274)
    generated afresh, and each one says so with what it replaced.  The keep for
    want of a contract still wins -- the request is about words, and carrying
    it out without a contract would take away more than words.
    """

    for workflow in workflows:
        plan = workflow.plan
        if plan is None or plan.needs_review or workflow.duplicate_of is not None:
            continue
        if workflow.state not in _IMPORT_STATES:
            continue
        candidate = workflow.candidate
        classification = workflow.classification
        if candidate is None or classification is None or workflow.graph is None:
            continue

        target = config.output.definitions / "{}.yaml".format(workflow.id)

        # The prose first, from the plan and the graph and from nothing else --
        # `catalog.py` cannot see this file's name, and the readable name below
        # is computed separately and feeds `name` alone.
        catalog = describe(plan, workflow.graph_document or {})
        name = _display_name(candidate, workflow.id)

        # An unchanged workflow whose definition is on disk keeps it, byte for
        # byte, while this importer would still generate the same definition
        # from it.  The question is asked of what the importer generates **on
        # its own**, never of the file: a curator's edit must not read as the
        # importer having changed, and the importer having changed must reach
        # the definition even though nobody touched the workflow (T-0246).
        rewriting = False
        if workflow.state is WorkflowState.UNCHANGED and target.exists():
            fingerprint = generated_fingerprint(
                workflow_id=workflow.id,
                name=name,
                plan=plan,
                digest=workflow.graph_hash,
                output=config.output,
                presentation=catalog.presentation,
            )
            same_as_recorded = (
                fingerprint is not None
                and fingerprint == workflow.generated_fingerprint
            )
            if same_as_recorded and not regenerate_labels:
                workflow.definition = DefinitionWrite(
                    workflow_id=workflow.id, path=target, skipped=KEPT_NOTICE
                )
                continue
            # A different fingerprint from a run that knows less than the one
            # that wrote the file is not the importer having changed.  File and
            # record stay exactly as they are (T-0252) -- and a request to
            # regenerate labels does not override that, and says so.  An equal
            # fingerprint needs no such keep: what this run generates is then
            # what the better-informed run did, so writing it loses nothing.
            kept_because = (
                None
                if same_as_recorded
                else _kept_for_want_of_a_contract(
                    workflow,
                    has_contract=has_contract,
                    expects_contract=expects_contract,
                )
            )
            if kept_because is not None:
                workflow.definition = DefinitionWrite(
                    workflow_id=workflow.id,
                    path=target,
                    skipped=(
                        kept_because
                        + (
                            REGENERATED_MAYBE_NOT_DONE_NOTICE
                            if kept_because == NO_CONTRACT_MAYBE_KEPT_NOTICE
                            else REGENERATED_NOT_DONE_NOTICE
                        )
                        if regenerate_labels
                        else kept_because
                    ),
                    regeneration_withheld=regenerate_labels,
                )
                continue
            # A different fingerprint, or none recorded -- an inventory an
            # older importer wrote.  From here on this is exactly the path a
            # changed workflow takes, so the curator's words are kept by the
            # very rules that keep them there.
            rewriting = True

        # Then whatever is already written on disk, which wins over all of it.
        # A file that is there and cannot be read stops this workflow and
        # leaves it exactly as it is: it may hold words somebody wrote.
        curated, problem = read_curated(target)
        if problem is not None:
            _definition_failed(workflow, problem, target, catalog)
            continue

        built, problem = build_definition(
            workflow_id=workflow.id,
            name=name,
            plan=plan,
            # The graph that will run, and the hash *of that graph* -- which
            # for a converted workflow is not the source file's hash, and the
            # imported copy is named after its own content or nothing on disk
            # means what it says.
            graph_bytes=workflow.graph,
            digest=workflow.graph_hash,
            output=config.output,
            presentation=catalog.presentation,
            curated=curated,
            # What this importer generated into that very file last time, so a
            # label the curator rewrote can be told from one nobody touched.
            remembered_labels=workflow.generated_labels,
            # And the same for the one-line hints, so a sentence the curator
            # rewrote can be told from one the vocabulary wrote.
            remembered_help=workflow.generated_help,
            # And the same for each presentation key the catalogue wrote, so a
            # sentence the curator rewrote can be told from one it wrote
            # (T-0274).
            remembered_presentation=workflow.generated_presentation,
            # Unless this run was asked to set all three aside (T-0116).
            regenerate_labels=regenerate_labels,
        )
        if built is None:
            _definition_failed(workflow, problem, target, catalog)
            continue

        # What that request takes out of the file: asked of the rule it sets
        # aside, against the same file and the same records.
        replaced = (
            replaced_by_regeneration(
                plan,
                curated,
                remembered_labels=workflow.generated_labels,
                remembered_help=workflow.generated_help,
                presentation=catalog.presentation,
                remembered_presentation=workflow.generated_presentation,
            )
            if regenerate_labels
            else ()
        )

        if rewriting and _already_on_disk(built):
            # What would be written is what is there, byte for byte, graph and
            # all: a fingerprint recorded by no importer at all, or a change in
            # the importer that this workflow's definition does not show.  So
            # nothing is written and nothing is reported as written -- and,
            # because the file now provably *is* this importer's output for
            # this plan, the records say so, which is what lets the next run
            # keep it on the fingerprint alone.  Never on a dry run.
            if not dry_run:
                _record_generated(
                    workflow,
                    plan,
                    built,
                    presentation=catalog.presentation,
                    has_contract=has_contract,
                )
            workflow.definition = DefinitionWrite(
                workflow_id=workflow.id,
                path=target,
                skipped=(
                    REGENERATED_ALREADY_NOTICE if regenerate_labels else KEPT_NOTICE
                ),
            )
            continue

        if dry_run:
            if regenerate_labels:
                said = DRY_RUN_REGENERATED_NOTICE.format(
                    replaced=replaced_sentence(replaced, dry_run=True)
                )
            elif rewriting:
                said = DRY_RUN_REWRITE_NOTICE
            else:
                said = DRY_RUN_DEFINITION_NOTICE
            workflow.definition = DefinitionWrite(
                workflow_id=workflow.id,
                path=built.definition_path,
                skipped=said,
                would_write=True,
                presentation=catalog.presentation,
                notes=catalog.notes,
                replaced=replaced,
            )
            continue

        problem = write_definition(built)
        if problem is not None:
            _definition_failed(workflow, problem, built.definition_path, catalog)
            continue
        # The file on disk is now this run's, so the record becomes this run's
        # too -- and only now, **after** the write succeeded.  Paths above leave
        # without writing, and each must leave the record describing what is
        # really in the file: the definition kept on an equal fingerprint (whose
        # record already says so), the one found already byte for byte what
        # this run would write (recorded there, because it provably is), and
        # the one whose write was refused -- a full disk, a permission, a file
        # held open -- which must not be recorded at all.  A record
        # advanced past a file that never changed would read every field as
        # curated from then on, and no later improvement to the generator would
        # ever reach that definition again.  That failure is also silent: the
        # run reports the write, and would report nothing about the record.
        #
        # A dry run cannot reach this line, and it would not matter if it did:
        # it returns above, and ``run_sync`` writes no inventory at all for one.
        _record_generated(
            workflow,
            plan,
            built,
            presentation=catalog.presentation,
            has_contract=has_contract,
        )
        if regenerate_labels:
            # Said about every definition the request wrote, a new one
            # included: "none of yours was replaced" is also an answer.
            rewritten = REGENERATED_NOTICE.format(
                replaced=replaced_sentence(replaced, dry_run=False)
            )
        elif rewriting:
            rewritten = REWRITTEN_NOTICE
        else:
            rewritten = None
        workflow.definition = DefinitionWrite(
            workflow_id=workflow.id,
            path=built.definition_path,
            written=True,
            rewritten=rewritten,
            presentation=catalog.presentation,
            notes=catalog.notes,
            replaced=replaced,
        )


def replaced_sentence(replaced: Sequence[ReplacedWords], *, dry_run: bool) -> str:
    """What a run asked to regenerate labels took out of one definition.

    Counted and then listed verbatim, field by field, so the curator can put
    back a word they wanted from the report alone.
    """

    verb = "would be" if dry_run else "were"
    if not replaced:
        # Said of exactly what is counted -- what a run without the request
        # would have kept -- and of nothing wider: a label or a presentation
        # sentence nobody touched may well differ from this run's, and it
        # follows the generator on any run.
        return (
            "no label, help line or presentation key that a run without this "
            "request would have kept differed from what this run generated, so "
            "nothing you wrote {} replaced".format("would be" if dry_run else "was")
        )
    labels = sum(1 for item in replaced if item.key == "label")
    hints = sum(1 for item in replaced if item.key == "help")
    keys = sum(1 for item in replaced if item.key == "presentation")
    counted = []
    if labels:
        counted.append("{} label{}".format(labels, "" if labels == 1 else "s"))
    if hints:
        counted.append("{} help line{}".format(hints, "" if hints == 1 else "s"))
    if keys:
        counted.append("{} presentation key{}".format(keys, "" if keys == 1 else "s"))
    details = "; ".join(_replaced_detail(item) for item in replaced)
    return "{} that a run without this request would have kept {} replaced ({})".format(
        _listed(counted), verb, details
    )


def _replaced_detail(item: ReplacedWords) -> str:
    """One replacement, verbatim: what the file said, and what took its place."""

    if item.key == "presentation":
        return "presentation key '{}': {} -> {}".format(
            item.field,
            _quoted(item.was),
            _quoted(item.now) if item.now is not None else "removed",
        )
    return "{} of '{}': {} -> {}".format(
        item.key,
        item.field,
        _quoted(item.was),
        _quoted(item.now) if item.now is not None else "no help line",
    )


def _quoted(value: Any) -> str:
    """A value as the report quotes it: a string in quotes, a list item by item."""

    if isinstance(value, (list, tuple)):
        return "[{}]".format(", ".join(_quoted(item) for item in value))
    return "'{}'".format(value)


def _listed(parts: Sequence[str]) -> str:
    """``a``, ``a and b``, ``a, b and c``."""

    if len(parts) <= 2:
        return " and ".join(parts)
    return "{} and {}".format(", ".join(parts[:-1]), parts[-1])


def _record_generated(
    workflow: SyncedWorkflow,
    plan: ImportPlan,
    built: DefinitionPlan,
    *,
    presentation: Mapping[str, Any],
    has_contract: bool,
) -> None:
    """Make the records describe the definition that is now on disk.

    One place for all five, so no path can move one of them and not the
    others: labels, hints, the presentation the catalogue generated (T-0274),
    the fingerprint and whether a contract informed it are one statement --
    "this is what the importer produced for the file that is there, and from
    what".  ``presentation`` is the catalogue's own mapping, never the block
    that was written.
    """

    workflow.generated_labels = generated_labels(plan)
    workflow.generated_help = generated_help(plan)
    workflow.generated_presentation = generated_presentation(presentation)
    workflow.generated_fingerprint = built.fingerprint
    workflow.generated_with_contract = has_contract


def _kept_for_want_of_a_contract(
    workflow: SyncedWorkflow, *, has_contract: bool, expects_contract: bool
) -> Optional[str]:
    """Why an unchanged definition must not be rewritten by this run, or ``None``.

    The four cases the rule was decided on (T-0252):

    * this run has a contract -- compare as usual, whatever was recorded;
    * neither this run nor the record had one -- compare as usual;
    * the record was made without one and this run has one -- compare, which
      rewrites: the evidence is better;
    * **this run has none and the record was made with one -- keep**, file and
      record exactly as they are.

    An inventory written before the flag existed says nothing either way.  It
    is read as "made with one" when this run would normally have had a
    contract -- it holds an editor-format workflow, the only thing a run asks
    ComfyUI's identity for -- because then a missing contract means ComfyUI was
    unreachable or not asked, and the file may well carry what it declared.  A
    run that never has a contract (API-format exports only) compares as
    usual, or no change to the importer could ever reach that catalogue.
    """

    if has_contract:
        return None
    recorded = workflow.generated_with_contract
    if recorded is True:
        return NO_CONTRACT_KEPT_NOTICE
    if recorded is None and expects_contract:
        return NO_CONTRACT_MAYBE_KEPT_NOTICE
    return None


def _already_on_disk(built: DefinitionPlan) -> bool:
    """Is exactly this definition, and exactly its graph, already in place?

    Both files, because the definition names the graph: a YAML that matches
    beside a graph that is gone is a definition that does not load.  A file
    that cannot be read is not "already there".
    """

    try:
        return (
            built.definition_path.read_bytes() == built.yaml_text.encode("utf-8")
            and built.graph_path.read_bytes() == built.graph_bytes
        )
    except OSError:
        return False


def _definition_failed(
    workflow: SyncedWorkflow,
    problem: Optional[str],
    path: Optional[Path],
    catalog: Optional[Catalog] = None,
) -> None:
    """Record a definition that was not written, and say so in the run."""

    message = problem or "the definition could not be generated."
    workflow.definition = DefinitionWrite(
        workflow_id=workflow.id,
        path=path,
        problem=message,
        presentation=catalog.presentation if catalog is not None else {},
        notes=catalog.notes if catalog is not None else (),
    )
    workflow.state = WorkflowState.NEEDS_REVIEW
    workflow.reason = message


def _display_name(candidate: Candidate, workflow_id: str) -> str:
    """The name a generated definition carries: the curator's file, tidied.

    A tidied echo of somebody's own file name is honest -- it is what they see
    in ComfyUI, with the underscores and the ordering prefix taken out.  A
    claim about what model the file uses would not be, and none is made: the
    stem reaches :func:`~localcanvas_gateway.workflows.sync.catalog.readable_name`
    and nothing else in the definition, and the prose generator beside it
    cannot see a file name at all.
    """

    stem = readable_name(Path(candidate.relative).stem)
    return stem or workflow_id


# --------------------------------------------------------------------------
# The inventory entry
# --------------------------------------------------------------------------


def _entry_for(
    workflow: SyncedWorkflow, config: SourcesConfig, stamp: str
) -> InventoryEntry:
    classification = workflow.classification
    candidate = workflow.candidate
    remembered = workflow.remembered
    return InventoryEntry(
        id=workflow.id,
        state=workflow.state.value,
        format=(
            classification.format.value
            if classification is not None
            else (remembered.format if remembered else WorkflowFormat.INVALID.value)
        ),
        source_root=str(candidate.root) if candidate else (
            remembered.source_root if remembered else ""
        ),
        source_path=str(candidate.path) if candidate else (
            remembered.source_path if remembered else ""
        ),
        source_relative=candidate.relative if candidate else (
            remembered.source_relative if remembered else ""
        ),
        content_hash=(
            classification.content_hash
            if classification is not None
            else (remembered.content_hash if remembered else content_hash(b""))
        ),
        canonical_hash=(
            classification.canonical_hash
            if classification is not None
            else (remembered.canonical_hash if remembered else None)
        ),
        size_bytes=candidate.size if candidate else (
            remembered.size_bytes if remembered else 0
        ),
        aliases=list(workflow.aliases),
        reason=workflow.reason,
        first_seen=workflow.first_seen or stamp,
        last_seen=workflow.last_seen or stamp,
        # Provenance: how this workflow's graph was obtained, and by which
        # ComfyUI.  Carried forward for an entry no file explained this run, so
        # that a workflow on an unplugged drive does not lose the record of
        # where its imported graph came from.
        conversion=(
            workflow.conversion.to_document()
            if workflow.conversion is not None
            else (remembered.conversion if remembered is not None else None)
        ),
        # Written unconditionally, and *that* is what keeps it: this is the
        # tool's record of its own output and never a note a curator left, so
        # the switch on the line below has no say in it.  Listing it in
        # ``KNOWN_ENTRY_KEYS`` is belt and braces, not the guard -- it keeps
        # the record out of ``extra``, where it would read as one of the user's
        # own keys, while ``inventory._entry`` sets this field explicitly
        # whatever that tuple happens to hold.
        generated_labels=dict(workflow.generated_labels),
        generated_help=dict(workflow.generated_help),
        generated_presentation=dict(workflow.generated_presentation),
        generated_fingerprint=workflow.generated_fingerprint,
        generated_with_contract=workflow.generated_with_contract,
        extra=dict(workflow.extra) if config.sync.preserve_manual_metadata else {},
    )


__all__ = [
    "CONVERSION_NOT_OFFERED",
    "DRY_RUN_CONVERSION_NOTICE",
    "DRY_RUN_DEFINITION_NOTICE",
    "DRY_RUN_NOTICE",
    "DRY_RUN_NOTICE_ASCII",
    "DRY_RUN_REWRITE_NOTICE",
    "EDITOR_HISTORY_KEYS",
    "KEPT_NOTICE",
    "NO_CONTRACT_KEPT_NOTICE",
    "NO_CONTRACT_MAYBE_KEPT_NOTICE",
    "DRY_RUN_REGENERATED_NOTICE",
    "REGENERATED_ALREADY_NOTICE",
    "REGENERATED_MAYBE_NOT_DONE_NOTICE",
    "REGENERATED_NOTICE",
    "REGENERATED_NOT_DONE_NOTICE",
    "REGENERATED_OPENING",
    "REPORT_VERSION",
    "REWRITTEN_NOTICE",
    "SyncReport",
    "SyncedWorkflow",
    "editor_history",
    "run_sync",
]
