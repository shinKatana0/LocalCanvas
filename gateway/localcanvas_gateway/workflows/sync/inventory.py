"""The inventory: what LocalCanvas knew about the user's workflows last time.

One JSON document, developer-local, at the path the configuration names.  It is
the only thing this stage of the sync writes, and it is written under two rules
that come from the same place -- a curator runs this over a folder they care
about, and a run that goes wrong must leave them exactly where they were:

* **atomically.**  The document is written to a temporary file beside the
  target and then swapped in with :func:`os.replace`, which is atomic on both
  Windows and POSIX.  The destination is never opened for writing, so an
  interrupted run -- a full disk, a power cut, ``Ctrl+C`` between two writes --
  cannot leave half an inventory where a whole one was.
* **never replaced by something invalid.**  The serialised text is read back
  and checked against the same reader that will load it next time *before* the
  swap.  If that check fails, nothing is swapped: the previous inventory is
  still the previous inventory, and the run says so.

Reading is deliberately forgiving in one direction only.  An inventory that
cannot be parsed is reported and treated as empty -- the alternative is
refusing to run at all because of a file this tool wrote -- but an inventory
that parses is trusted to the letter, including keys this version does not
know: see ``preserve_manual_metadata`` in `config.py`.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

from .errors import InventoryError

#: Bumped when the document's shape changes.  Its consumer is the next run of
#: this same tool, which has to be able to tell "written by a version that
#: spelled things differently" from "corrupt".
#:
#: Not bumped for a key that is purely added.  A version this reader refuses is
#: an inventory treated as empty, which means every workflow reported as new,
#: every id reallocated and every ``first_seen`` lost -- a heavy price, and the
#: wrong one when an older document is read perfectly well: the key is simply
#: absent, and an absent record already has a defined meaning everywhere it is
#: read.  The bump is for a shape an older or newer reader would half-read
#: *wrongly*, not for one it would read as saying less.
INVENTORY_VERSION = 1

#: The keys this version writes on an entry.  Anything else found on an entry
#: is the user's own, and ``preserve_manual_metadata`` decides its fate.
KNOWN_ENTRY_KEYS = (
    "id",
    "state",
    "format",
    "source_root",
    "source_path",
    "source_relative",
    "content_hash",
    "canonical_hash",
    "size_bytes",
    "aliases",
    "reason",
    "first_seen",
    "last_seen",
    "conversion",
    "generated_labels",
    "generated_help",
    "generated_presentation",
    "generated_fingerprint",
    "generated_with_contract",
)


@dataclass
class InventoryEntry:
    """One workflow as the inventory remembers it."""

    id: str
    state: str
    format: str
    source_root: str
    source_path: str
    source_relative: str
    content_hash: str
    canonical_hash: Optional[str] = None
    size_bytes: int = 0
    aliases: List[Dict[str, Any]] = field(default_factory=list)
    reason: Optional[str] = None
    first_seen: str = ""
    last_seen: str = ""
    #: How this workflow's API graph was obtained, when it was not simply the
    #: file itself: the conversion status, the deterministic category of a
    #: failure, and which ComfyUI produced a success.  ``None`` for an
    #: API-format export, which needed no conversion at all -- present and null
    #: rather than absent, so a reader never has to ask whether the key is
    #: there.
    conversion: Optional[Dict[str, Any]] = None
    #: ``{field id: label}`` as **this importer generated it** the last time it
    #: wrote this workflow's definition -- not what is in the definition now,
    #: which is what a curator may have rewritten.  It is the only thing that
    #: can tell "the curator wrote this" from "we wrote this last Tuesday", and
    #: `definitions.py` explains at length why neither of the two simpler
    #: questions can (T-0110).  Empty when this run has nothing to say about a
    #: workflow's labels, which a reader must treat as "no record", never as
    #: "no label was generated".
    generated_labels: Dict[str, str] = field(default_factory=dict)
    #: ``{field id: help}`` as **this importer generated it** the last time it
    #: wrote this workflow's definition, and the same kind of record as
    #: ``generated_labels`` above, for the same reason (T-0131): a one-line
    #: hint is written for every field the vocabulary knows, on every run, so
    #: presence in the definition cannot tell curation from generation.
    #:
    #: A field the vocabulary said nothing about has **no entry**, which is the
    #: same "no record" every reader here already understands.  Kept apart from
    #: the labels rather than merged into one record: they are two different
    #: sentences about one field, and a merged record could answer for the
    #: wrong one.
    generated_help: Dict[str, str] = field(default_factory=dict)
    #: ``{presentation key: value}`` as **this importer generated it** the last
    #: time it wrote this workflow's definition -- ``short_description``,
    #: ``how_to_use``, ``best_for`` and every other key the catalogue emitted,
    #: each value a string or a list of strings exactly as generated (T-0274).
    #: The same kind of record as the two above and for the same reason: a
    #: generated definition carries those keys, so presence in the file cannot
    #: tell a sentence a curator wrote from one the catalogue wrote, and without
    #: a record no improvement to the catalogue could ever reach a definition
    #: that already exists.
    #:
    #: A key the catalogue did not emit has **no entry**, which is "no record"
    #: for that key, exactly as a field with no hint has no entry above.
    generated_presentation: Dict[str, Any] = field(default_factory=dict)
    #: A fingerprint of the definition **this importer would write for this
    #: workflow on its own** -- with no curated file and no remembered labels
    #: -- the last time that definition was written, or found already equal to
    #: what this importer writes (T-0246).  ``None`` is "no record": an
    #: inventory written before the key existed, or a workflow whose definition
    #: has never been written.
    #:
    #: It is what lets an improvement to the importer reach a workflow whose
    #: file did not change.  The source bytes say the *workflow* is the same;
    #: this says whether what the importer makes *of* it is the same, and a
    #: definition is written again only when it is not.  Like the two records
    #: above it describes the importer's own output and never a curator's, and
    #: it moves by the same runs they do: one that wrote the definition, or one
    #: that found the file on disk already byte for byte what it would write.
    generated_fingerprint: Optional[str] = None
    #: Whether the ComfyUI the run that recorded ``generated_fingerprint`` talked
    #: to declared what its inputs accept -- a runtime contract informed that
    #: definition -- or not; ``None`` for no record (T-0252).  Moved with the
    #: fingerprint and only with it.
    #:
    #: It exists because a run without a contract generates *less*: no declared
    #: bounds, no declared types.  Its fingerprint then differs from one taken
    #: with a contract although nothing about the importer changed, and
    #: rewriting on that difference would strip a definition of what the
    #: better-informed run put there.  So a run with no contract never rewrites
    #: an unchanged definition this flag says was made with one.
    generated_with_contract: Optional[bool] = None
    #: Keys the current version does not know, kept verbatim so that a note a
    #: curator added by hand survives the next run.
    extra: Dict[str, Any] = field(default_factory=dict)

    def to_document(self) -> Dict[str, Any]:
        document: Dict[str, Any] = dict(self.extra)
        document.update(
            {
                "id": self.id,
                "state": self.state,
                "format": self.format,
                "source_root": self.source_root,
                "source_path": self.source_path,
                "source_relative": self.source_relative,
                "content_hash": self.content_hash,
                "canonical_hash": self.canonical_hash,
                "size_bytes": self.size_bytes,
                "aliases": list(self.aliases),
                "reason": self.reason,
                "first_seen": self.first_seen,
                "last_seen": self.last_seen,
                "conversion": (
                    dict(self.conversion) if self.conversion is not None else None
                ),
                # In the order the labels were generated, which is the plan's
                # own field order and is stable for the same graph.  Sorting
                # here would be a second order to keep in step with nothing,
                # and re-ordering between runs would churn the file.
                "generated_labels": dict(self.generated_labels),
                "generated_help": dict(self.generated_help),
                # In the catalogue's own key order, for the reason above.  A
                # list is copied, so the document never shares one with the
                # entry.
                "generated_presentation": {
                    key: list(value) if isinstance(value, list) else value
                    for key, value in self.generated_presentation.items()
                },
                "generated_fingerprint": self.generated_fingerprint,
                "generated_with_contract": self.generated_with_contract,
            }
        )
        return document


@dataclass(frozen=True)
class Inventory:
    """A whole inventory document, parsed."""

    entries: Tuple[InventoryEntry, ...] = ()
    #: Why the file on disk could not be used, when it could not.  The run
    #: carries on with an empty inventory and reports this.
    problem: Optional[str] = None

    def by_content_hash(self) -> Dict[str, InventoryEntry]:
        return {entry.content_hash: entry for entry in reversed(self.entries)}

    def by_canonical_hash(self) -> Dict[str, InventoryEntry]:
        return {
            entry.canonical_hash: entry
            for entry in reversed(self.entries)
            if entry.canonical_hash
        }

    def by_source_path(self) -> Dict[str, InventoryEntry]:
        return {
            os.path.normcase(entry.source_path): entry for entry in reversed(self.entries)
        }


def read_inventory(path) -> Inventory:
    """Load the inventory at ``path``.

    A file that is not there is not a problem: the first run of a new
    installation has none, and that is the ordinary case rather than an error.
    """

    target = Path(path)
    try:
        raw = target.read_bytes()
    except FileNotFoundError:
        return Inventory()
    except OSError as exc:
        return Inventory(
            problem="the inventory at {} could not be read ({}); this run "
            "treated it as empty, so every workflow is reported as new.".format(
                target, exc.strerror or exc
            )
        )
    try:
        document = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return Inventory(
            problem="the inventory at {} is not readable JSON ({}); this run "
            "treated it as empty, so every workflow is reported as new.".format(
                target, exc
            )
        )
    problem = _document_problem(document)
    if problem is not None:
        return Inventory(
            problem="the inventory at {} is not a LocalCanvas inventory ({}); this "
            "run treated it as empty, so every workflow is reported as new.".format(
                target, problem
            )
        )
    return Inventory(entries=tuple(_entry(item) for item in document["workflows"]))


def build_document(entries, *, generated: str, config_source: str) -> Dict[str, Any]:
    """The document that will be written, as data.

    Separate from writing it so that a test -- and the dry run -- can have the
    exact bytes a real run would produce without a real run producing them.
    """

    return {
        "inventory_version": INVENTORY_VERSION,
        "generated": generated,
        "config": config_source,
        "workflows": [entry.to_document() for entry in entries],
    }


def serialise(document: Mapping[str, Any]) -> str:
    """The document as the text that goes on disk.

    ``sort_keys=False`` on purpose: the key order is the order this module
    writes them in, which is stable, and sorting would put ``aliases`` before
    ``id``.  ``ensure_ascii`` keeps the file readable in any editor and its
    bytes independent of the machine's code page.
    """

    return json.dumps(document, indent=2, ensure_ascii=True, sort_keys=False) + "\n"


def write_inventory(path, document: Mapping[str, Any]) -> Path:
    """Write ``document`` to ``path``, atomically, or leave what is there.

    Raises :class:`InventoryError` for every failure, having changed nothing at
    ``path`` in every one of them.
    """

    target = Path(path)
    try:
        text = serialise(document)
    except (TypeError, ValueError) as exc:
        raise InventoryError(
            "the inventory could not be turned into JSON ({}); {} was left as it "
            "was.".format(exc, target)
        ) from exc

    # Read back what would be written, with the same reader that will load it
    # next run.  A document that does not survive its own round trip never
    # reaches the disk.
    problem = _document_problem(_reparse(text))
    if problem is not None:
        raise InventoryError(
            "the inventory this run produced is not a valid inventory ({}); {} "
            "was left as it was.".format(problem, target)
        )

    try:
        target.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise InventoryError(
            "the folder for the inventory could not be created ({}): {}".format(
                exc.strerror or exc, target.parent
            )
        ) from exc

    temporary = target.with_name(target.name + ".{}.tmp".format(os.getpid()))
    try:
        with open(temporary, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as exc:
        _discard(temporary)
        raise InventoryError(
            "the inventory could not be written ({}); {} was left as it was.".format(
                exc.strerror or exc, target
            )
        ) from exc

    try:
        # The swap.  Named through a module attribute so that a test can prove
        # this is what happens -- a write that opened the destination directly
        # would pass every assertion about the resulting content and still have
        # had a window in which the file was half a document.
        _replace(str(temporary), str(target))
    except OSError as exc:
        _discard(temporary)
        raise InventoryError(
            "the inventory could not replace the previous one ({}); {} was left "
            "as it was.".format(exc.strerror or exc, target)
        ) from exc
    return target


#: The one call that makes the write atomic, bound here rather than called
#: through ``os.`` so that it can be substituted in a test without reaching
#: into the ``os`` module every other module in the process shares.
_replace = os.replace


# --------------------------------------------------------------------------
# Internals
# --------------------------------------------------------------------------


def _reparse(text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        return "not JSON: {}".format(exc)


def _document_problem(document: Any) -> Optional[str]:
    if not isinstance(document, dict):
        return "the top level is not a JSON object"
    if document.get("inventory_version") != INVENTORY_VERSION:
        return "inventory_version is {!r}, expected {!r}".format(
            document.get("inventory_version"), INVENTORY_VERSION
        )
    workflows = document.get("workflows")
    if not isinstance(workflows, list):
        return "'workflows' is not a list"
    for index, item in enumerate(workflows):
        if not isinstance(item, dict):
            return "workflows[{}] is not an object".format(index)
        for required in ("id", "state", "content_hash", "source_path"):
            if not isinstance(item.get(required), str) or not item[required]:
                return "workflows[{}] has no usable {!r}".format(index, required)
    return None


def _entry(item: Mapping[str, Any]) -> InventoryEntry:
    aliases = item.get("aliases")
    return InventoryEntry(
        id=str(item["id"]),
        state=str(item["state"]),
        format=str(item.get("format") or ""),
        source_root=str(item.get("source_root") or ""),
        source_path=str(item["source_path"]),
        source_relative=str(item.get("source_relative") or ""),
        content_hash=str(item["content_hash"]),
        canonical_hash=(
            str(item["canonical_hash"]) if item.get("canonical_hash") else None
        ),
        size_bytes=int(item["size_bytes"]) if isinstance(item.get("size_bytes"), int) else 0,
        aliases=list(aliases) if isinstance(aliases, list) else [],
        reason=str(item["reason"]) if item.get("reason") else None,
        first_seen=str(item.get("first_seen") or ""),
        last_seen=str(item.get("last_seen") or ""),
        conversion=(
            dict(item["conversion"]) if isinstance(item.get("conversion"), dict) else None
        ),
        generated_labels=_string_record(item.get("generated_labels")),
        generated_help=_string_record(item.get("generated_help")),
        generated_presentation=_presentation_record(item.get("generated_presentation")),
        generated_fingerprint=(
            item["generated_fingerprint"]
            if isinstance(item.get("generated_fingerprint"), str)
            and item["generated_fingerprint"]
            else None
        ),
        generated_with_contract=(
            item["generated_with_contract"]
            if isinstance(item.get("generated_with_contract"), bool)
            else None
        ),
        extra={
            key: value for key, value in item.items() if key not in KNOWN_ENTRY_KEYS
        },
    )


def _string_record(raw: Any) -> Dict[str, str]:
    """One ``{field id: text}`` record, keeping only what is one.

    Both records this entry carries -- the generated labels and the generated
    one-line hints -- are read through here, because the rule is the same for
    each and having it in one place is what keeps it the same.

    Anything that is not a string keyed by a string is dropped rather than
    coerced.  A record this cannot read is a record this does not have, and the
    rule for a missing one -- ``definitions.py``, "when there is no record" --
    is to preserve what the curator's file says.  Coercing a number into
    ``'40'`` here would instead invent a record and could hand somebody's own
    label back to the generator.
    """

    if not isinstance(raw, Mapping):
        return {}
    return {
        key: value
        for key, value in raw.items()
        if isinstance(key, str) and isinstance(value, str)
    }


def _presentation_record(raw: Any) -> Dict[str, Any]:
    """The ``{presentation key: value}`` record, keeping only what is one.

    The catalogue writes a presentation value as a string or as a list of
    strings, so those are the two shapes kept, and nothing is coerced -- for
    :func:`_string_record`'s reason: a record this cannot read is a record this
    does not have, whose rule is to keep what the file says, while a coerced
    one could hand somebody's own sentence back to the generator.
    """

    if not isinstance(raw, Mapping):
        return {}
    record: Dict[str, Any] = {}
    for key, value in raw.items():
        if not isinstance(key, str):
            continue
        if isinstance(value, str):
            record[key] = value
        elif isinstance(value, list) and all(isinstance(item, str) for item in value):
            record[key] = list(value)
    return record


def _discard(path: Path) -> None:
    try:
        os.unlink(str(path))
    except OSError:
        # The temporary file is litter, not the failure being reported.
        pass


__all__ = [
    "INVENTORY_VERSION",
    "KNOWN_ENTRY_KEYS",
    "Inventory",
    "InventoryEntry",
    "build_document",
    "read_inventory",
    "serialise",
    "write_inventory",
]
