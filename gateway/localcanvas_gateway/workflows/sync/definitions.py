"""Writing one generated definition, and never breaking a working one.

An :class:`~localcanvas_gateway.workflows.sync.analysis.ImportPlan` goes in; a
YAML definition and a copy of the graph it describes come out, in the two
folders ``workflow-sources.yaml`` names and nowhere else.

Three rules, and they are the reason this is a module of its own.

**It passes the real loader before it replaces anything.**  The generated
definition and the graph are written into a staging directory laid out with
exactly the same relative distance between them as their final home, and
``load_registry`` -- the loader the gateway itself runs, not a second
implementation of its rules -- has to accept it there.  Only then is anything
swapped into place.  A generated definition that would be rejected therefore
never gets the chance to replace one that works, which is the failure
isolation T-0053 established, applied to the thing this card produces.

**The swap is one atomic step.**  The copy of the graph is named after its own
content, so a changed workflow writes a *new* file and the old one stays
exactly where the old definition still points.  Replacing the YAML is then the
single moment the workflow changes over, and it is an ``os.replace``.  There
is no window in which a definition points at a graph that does not match it.

**A definition a person has edited is not overwritten behind their back.**  A
workflow whose bytes have not changed keeps the definition it has, byte for
byte, **as long as this importer would still generate the same definition from
it** -- the curator's own words in it are worth more than a regeneration that
would produce the same fields.  Whether it would is answered by a fingerprint
of what this importer writes for the plan on its own (:func:`generated_fingerprint`,
recorded in the inventory as ``InventoryEntry.generated_fingerprint``).  When
the importer has changed -- a better analysis, a new bound, a new hint -- or no
fingerprint was ever recorded, the definition goes through exactly the path a
changed workflow's does (T-0246).  A workflow that is new, or whose graph
really did change, is written -- and even then, **what is
already written in the definition wins**: :func:`read_curated` reads the file
on disk first, and its ``name`` and its ``translation`` block are carried into
the new definition verbatim.  Keys it does *not* hold are filled from what this
run generated, so a curator who deleted a key gets it back and a key the
generator only learned to produce later still arrives.

That rule is deliberately the simple one, and it is still the whole rule for
``name`` and ``translation``.  It cannot be the rule for anything the generator
writes into every definition on every run, as the next paragraphs explain --
and that is every field's ``label`` and ``help``, and every ``presentation``
key the catalogue emits.

**A label is the first thing that rule cannot be applied to**, and the reason is
worth spelling out here because two plausible alternatives are both wrong
(T-0110).  Every generated definition writes a ``label`` for *every* field,
always -- so "present in the file" proves nothing about who wrote it, and
taking presence as curation would freeze every label at its first write and
stop any later improvement to the generator ever reaching a catalogue that
already exists.  The other tempting question, "does it differ from what the
generator would produce *now*", re-reads yesterday's generated label as
curation the moment the generator changes, so it breaks precisely when the code
improves.

So a label is compared against **what this importer generated on its own last
run**, remembered per workflow and field id in the inventory
(``InventoryEntry.generated_labels``):

    file label == last generated label  ->  not curated: regenerate freely
    file label != last generated label  ->  curated: keep it verbatim

That stays correct in both directions when the generator changes: an untouched
label still equals what was stored, so it refreshes to the new text, and a
hand-edited one still differs, so it is kept.  ``inputs`` is otherwise
regenerated exactly as before -- ``bind``, ``type``, ``default`` and the bounds
describe the graph.

**``help`` is the second key of that shape, and it takes the same rule**
(T-0131).  A field's one-line hint comes from `semantics.py`'s vocabulary --
its input name first and, only where that says nothing, the role the wiring
proved (T-0131-02) -- so the generator writes one for every
field it has a sentence for, on every run -- presence in the file proves
nothing about who wrote it, exactly as it proves nothing for a label.  Under
the ``presentation`` rule an improved sentence would never reach a catalogue
that already exists, and the vocabulary would be unimprovable from the first
import onward.  So ``help`` is compared against
``InventoryEntry.generated_help`` the same way, with one difference that is
not a difference in the rule: the generated value may be **nothing at all**.
A field the vocabulary has no sentence for is written with no ``help`` key --
not ``help: ""``, not ``help: null`` -- on the principle ``min``/``max``/``step``
already follow: a key nobody set is not written.  A sentence the curator wrote
is written to the file and, like a curated label, is never recorded.

**Every ``presentation`` key the catalogue generates takes the same rule,
key by key** (T-0274).  `catalog.py` writes ``short_description``,
``how_to_use``, ``best_for`` and the rest on every run, so a sentence in the
file proves nothing about who wrote it -- and under "what is already written
wins" an improved or withdrawn catalogue sentence would never reach a
definition that exists.  So each key is compared against
``InventoryEntry.generated_presentation``, the catalogue's own value from the
run that last wrote the file: equal means nobody touched it, and this run's
value replaces it -- or, when the catalogue no longer emits that key, the key
is removed rather than left behind; different means somebody wrote it, and it
is kept verbatim.  The keys the catalogue never generates
(``catalog.CURATOR_ONLY``) and keys the schema does not know are never in the
record, so they are always the curator's.  Whole values are compared, a list
as a list.

**With no stored record at all, the file's label -- and its help, and each of
its presentation keys -- is preserved.**  A person can always delete the inventory, and doing so must not
become an act of destruction: with no record this cannot prove a label was
generated, and overwriting something a person may have written is the worse of
the two errors by a wide margin.  The price is that a label preserved this way
then looks curated for good -- the record now says what the generator produced,
and the file says what was preserved.

**Getting the generated labels, help and presentation back is an explicit
request, not an act of deleting a file** (T-0116, T-0274).
``--regenerate-labels`` (``-RegenerateLabels`` on
``scripts/sync-workflows.ps1``) makes one run write every importable definition
with each field's label and help, and every presentation key the catalogue
generates, generated afresh -- ``regenerate_labels`` below -- and records what
it generated, so the run after it starts from a record that matches the file.
It is about those keys and nothing else: ``name``, ``translation``, the
presentation keys the catalogue never generates and any key the schema does not
know are carried from the file exactly as always, and the rule above is
unchanged for every run that does not ask.  Deleting the inventory was the way to force a re-import before
that flag existed, which is what made "a definition with no record" a routine
state; with the flag it is an anomaly, and the rule above is what keeps even
the anomaly safe.  Deleting the *definition* still discards a curator's edits,
as the header above says.

A definition on disk that cannot be read is neither ignored nor overwritten:
that one workflow is reported with the reason and **nothing is written**, so
the run carries on and not one word anybody wrote is lost.  Discarding text we
could not read would be exactly the silent loss the rule above exists to
prevent.

The prose itself is written elsewhere -- a workflow's own by `catalog.py`, a
field's one-line hint by `semantics.py`'s vocabulary.  This module merges and
writes it, and composes no sentence of its own.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Tuple

import yaml

from ..registry import load_registry
from . import semantics
from .analysis import ImportPlan, PlannedField
from .catalog import CURATOR_ONLY, PRESENTATION_ORDER
from .config import OutputPaths

#: The first lines of every generated definition.  No date, no machine, no
#: version: a header that changed between two runs over the same bytes would
#: make "the same workflow generates the same definition" untestable, and it
#: is a property worth more than a timestamp.
GENERATED_HEADER = (
    "# Generated by the LocalCanvas workflow sync from the workflow named below.\n"
    "# Edit it freely -- it is yours. A later sync writes this file again when the\n"
    "# workflow it came from has changed, or when this importer now reads that\n"
    "# unchanged workflow differently. Either way it keeps the name, presentation,\n"
    "# translation setting and every field label and help line you wrote, and\n"
    "# generates everything else again from the workflow.\n"
)


@dataclass(frozen=True)
class DefinitionPlan:
    """One definition, rendered, with the two paths it will occupy."""

    workflow_id: str
    definition_path: Path
    graph_path: Path
    #: How the definition names the graph: a path relative to the YAML, which
    #: is the only form `docs/workflow-schema.md` accepts.
    workflow_relative: str
    yaml_text: str
    graph_bytes: bytes
    #: :func:`generated_fingerprint` of this same plan, taken from the same
    #: inputs this definition was rendered from -- what the inventory records
    #: once this definition is on disk.  Never a fingerprint of ``yaml_text``,
    #: which carries whatever the curator's file contributed.
    fingerprint: str = ""


@dataclass(frozen=True)
class DefinitionWrite:
    """What happened to one workflow's definition in this run."""

    workflow_id: str
    #: Where the definition is, or would be.  Present even when nothing was
    #: written, so a dry run can say where a real one would put it.
    path: Optional[Path]
    written: bool = False
    #: Why nothing was written although nothing went wrong -- a dry run, or a
    #: definition that is already there for a workflow that has not changed.
    skipped: Optional[str] = None
    #: Why nothing was written *and* something is wrong.  A workflow with a
    #: problem here still has whatever definition it had before.
    problem: Optional[str] = None
    #: Why a definition was written although its workflow did not change: this
    #: importer now generates something different from it (T-0246).  In a run
    #: asked to regenerate labels, what that request did to this definition --
    #: for every definition it wrote, whatever its workflow's state (T-0116).
    #: ``None`` for every other write.
    rewritten: Optional[str] = None
    #: A dry run's answer to "would a real run write this definition?".  Never
    #: true outside a dry run, where ``written`` already answers it.
    would_write: bool = False
    #: The words a run asked to regenerate labels replaced -- or, on a dry
    #: run, would replace -- in this definition (T-0116): one
    #: :class:`ReplacedWords` per field whose label or help, and per
    #: presentation key (T-0274), a run without that request would have kept.  Empty for every other run.  Like
    #: ``would_write``, data for the summary line and not a key of the
    #: document: the sentence in ``rewritten`` or ``skipped`` already lists them.
    replaced: Tuple["ReplacedWords", ...] = ()
    #: True when a run asked to regenerate labels left this definition alone
    #: anyway, because a rule that protects the file won (T-0252's keep for
    #: want of a contract).  Data for the summary line, like ``replaced``.
    regeneration_withheld: bool = False
    #: What this run's evidence produced, before anything already written in
    #: the definition on disk was carried over it.  What the run *decided*,
    #: which is not the same question as what is now in the file.
    presentation: Mapping[str, Any] = field(default_factory=dict)
    #: One sentence per ``presentation`` key the evidence could not settle, so
    #: the curator is told what is theirs to write.
    notes: Tuple[str, ...] = ()

    def to_document(self) -> Dict[str, Any]:
        return {
            "path": str(self.path) if self.path is not None else None,
            "written": self.written,
            "skipped": self.skipped,
            "problem": self.problem,
            "rewritten": self.rewritten,
            "presentation": dict(self.presentation),
            "notes": list(self.notes),
        }


@dataclass(frozen=True)
class ReplacedWords:
    """One label, help line or presentation key a run asked to regenerate replaced.

    ``key`` is ``"label"`` or ``"help"``, with ``field`` the field's id -- or
    ``"presentation"``, with ``field`` the presentation key's name (T-0274).
    ``was`` is what the definition on disk said, and a run without the request
    would have kept; ``now`` is what this run generated, ``None`` for a help
    line the vocabulary has no sentence for, or a presentation key the
    catalogue does not emit, which is then written with no such key at all.  A
    presentation value may be a list of strings; a label or help line is
    always a string.
    """

    field: str
    key: str
    was: Any
    now: Optional[Any]


@dataclass(frozen=True)
class CuratedDefinition:
    """A definition already on disk, as the words its owner wrote.

    Only the parts a curator writes prose into are read back: ``name``, the
    whole ``presentation`` block, the ``translation`` policy and the ``label``
    and ``help`` of each field.  The rest of ``inputs`` -- ``bind``, ``type``,
    ``default``, the bounds -- and ``workflow`` are regenerated every time,
    because they describe the graph and the graph is what changed.
    """

    document: Mapping[str, Any]

    def has(self, key: str) -> bool:
        return key in self.document

    @property
    def presentation(self) -> Mapping[str, Any]:
        value = self.document.get("presentation")
        return value if isinstance(value, dict) else {}

    @property
    def labels(self) -> Dict[str, str]:
        """``{field id: label}`` as the file on disk says, and nothing else.

        Anything that is not a string label under a string id is skipped: a
        field the schema would reject is not a label to preserve, and the
        loader that refuses the file is what tells the curator about it.  An id
        this run no longer produces is simply never asked for, so a label left
        behind by a field that has gone cannot resurrect it or stop the import.
        """

        return self._strings("label")

    @property
    def help_lines(self) -> Dict[str, str]:
        """``{field id: help}`` as the file on disk says, and nothing else.

        ``help`` is optional, so a field without one simply has no entry --
        which is the same thing "this field has no help" means everywhere
        else, and is why it needs no separate spelling.
        """

        return self._strings("help")

    def _strings(self, key: str) -> Dict[str, str]:
        inputs = self.document.get("inputs")
        if not isinstance(inputs, list):
            return {}
        written: Dict[str, str] = {}
        for item in inputs:
            if not isinstance(item, dict):
                continue
            identifier = item.get("id")
            value = item.get(key)
            if isinstance(identifier, str) and isinstance(value, str):
                written[identifier] = value
        return written


def read_curated(path: Path) -> Tuple[Optional[CuratedDefinition], Optional[str]]:
    """What the definition at ``path`` already says, or why it cannot be read.

    A missing file is neither -- there is nothing to preserve and nothing is
    wrong, so both halves come back empty.

    A file that is *there* and cannot be read is a problem, and deliberately
    so.  It may hold words somebody wrote, and this run cannot tell: writing
    over it would destroy them silently, which is the one outcome this module
    exists to prevent.  So the caller reports this workflow and writes nothing
    -- the file stays exactly as it is, and the run carries on with the others.
    """

    if not path.exists():
        return None, None
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return None, _unreadable(path, str(exc))
    try:
        document = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return None, _unreadable(path, _yaml_detail(exc))
    if document is None:
        return CuratedDefinition(document={}), None
    if not isinstance(document, dict):
        return None, _unreadable(
            path, "its top level is a {} and a definition is a mapping".format(
                type(document).__name__
            )
        )
    raw = document.get("presentation")
    if raw is not None and not isinstance(raw, dict):
        return None, _unreadable(
            path,
            "its 'presentation' is a {} and the schema makes it a "
            "mapping".format(type(raw).__name__),
        )
    return CuratedDefinition(document=document), None


def _unreadable(path: Path, detail: str) -> str:
    return (
        "the definition already at {} could not be read ({}), and it may hold "
        "words you wrote. Nothing was written and that file was not touched: "
        "fix it, or delete it and run the sync again.".format(path, detail)
    )


def _yaml_detail(exc: yaml.YAMLError) -> str:
    return " ".join(str(exc).split())


def graph_file_name(workflow_id: str, digest: str) -> str:
    """The name of the imported copy of a graph: its id and its content.

    Content-addressed on purpose.  A workflow that changed writes a new file
    beside the old one instead of over it, so the definition that is still on
    disk still points at the graph it was validated against, right up to the
    instant the new definition replaces it.
    """

    hexadecimal = digest.split(":")[-1]
    return "{}.{}.json".format(workflow_id, hexadecimal[:12])


def definition_document(
    plan: ImportPlan,
    *,
    workflow_id: str,
    name: str,
    workflow_relative: str,
    presentation: Optional[Mapping[str, Any]] = None,
    curated: Optional[CuratedDefinition] = None,
    remembered_labels: Optional[Mapping[str, str]] = None,
    remembered_help: Optional[Mapping[str, str]] = None,
    regenerate_labels: bool = False,
    remembered_presentation: Optional[Mapping[str, Any]] = None,
) -> Dict[str, Any]:
    """The definition as plain data, in the order it will be written.

    ``curated`` is what the definition on disk already says.  Its ``name`` and
    ``translation`` win outright; its labels, help lines and presentation keys
    win when the records below say they are somebody's own.  Key order is this
    function's, never the order the two sources happened to be written in, so
    two runs over the same bytes produce byte-identical YAML.

    ``remembered_labels`` is the record this importer left of the labels **it**
    generated when it last wrote this file, and it is consulted for nothing but
    the labels -- see the module docstring for why a label cannot use the
    "already written wins" rule.  ``remembered_help`` is the same record for the
    one-line hints, and ``remembered_presentation`` for the presentation keys
    (T-0274), each kept apart so that none can answer another's question.  All
    three are state and never content: no key of any reaches the document this
    returns.

    ``regenerate_labels`` is the explicit request to set those rules aside for
    this one document (T-0116): every field's label and help, and every
    presentation key the catalogue generates, are this run's, whatever the file
    and the records say.  ``name``, ``translation``, the presentation keys in
    ``catalog.CURATOR_ONLY`` and keys the schema does not know are not touched
    by it.
    """

    document: Dict[str, Any] = {
        "id": workflow_id,
        "name": curated.document["name"]
        if curated is not None and curated.has("name")
        else name,
        "workflow": workflow_relative,
    }
    merged = _merge_presentation(
        presentation,
        curated,
        remembered_presentation,
        regenerate=regenerate_labels,
    )
    if merged:
        document["presentation"] = merged
    if regenerate_labels:
        # Nothing the file says about a label or a help line is consulted at
        # all, so none of it can reach the document.
        written: Dict[str, str] = {}
        written_help: Dict[str, str] = {}
    else:
        written = curated.labels if curated is not None else {}
        written_help = curated.help_lines if curated is not None else {}
    remembered = dict(remembered_labels or {})
    remembered_hints = dict(remembered_help or {})
    document["inputs"] = [
        _field_document(
            item,
            label=_field_label(item, written, remembered),
            help_text=_field_help(item, written_help, remembered_hints),
        )
        for item in plan.fields
    ]
    if curated is not None and curated.has("translation"):
        document["translation"] = curated.document["translation"]
    return document


def replaced_by_regeneration(
    plan: ImportPlan,
    curated: Optional[CuratedDefinition],
    *,
    remembered_labels: Optional[Mapping[str, str]] = None,
    remembered_help: Optional[Mapping[str, str]] = None,
    presentation: Optional[Mapping[str, Any]] = None,
    remembered_presentation: Optional[Mapping[str, Any]] = None,
) -> Tuple[ReplacedWords, ...]:
    """What ``regenerate_labels`` takes out of the definition on disk.

    Exactly the labels, help lines and presentation keys a run **without** the
    request would have carried into the new document and that differ from what
    this run generated -- asked of the very functions that decide it,
    :func:`_field_label`, :func:`_field_help` and :func:`_merge_presentation`,
    so this cannot drift from the rule it reports on.  A label equal to the
    generated one is not "replaced"; nor is a field the file does not have.  In
    field order, each field's label before its help, and then the presentation
    keys in the order they are written.
    """

    if curated is None:
        return ()
    written = curated.labels
    written_help = curated.help_lines
    remembered = dict(remembered_labels or {})
    remembered_hints = dict(remembered_help or {})
    replaced = []
    for item in plan.fields:
        kept = _field_label(item, written, remembered)
        if kept != item.label:
            replaced.append(
                ReplacedWords(field=item.id, key="label", was=kept, now=item.label)
            )
        generated = _generated_help(item)
        kept_help = _field_help(item, written_help, remembered_hints)
        if kept_help is not None and kept_help != generated:
            replaced.append(
                ReplacedWords(field=item.id, key="help", was=kept_help, now=generated)
            )
    kept_presentation = _merge_presentation(
        presentation, curated, remembered_presentation, regenerate=False
    )
    regenerated = _merge_presentation(
        presentation, curated, remembered_presentation, regenerate=True
    )
    for key, was in kept_presentation.items():
        now = regenerated.get(key)
        if key not in regenerated or now != was:
            replaced.append(
                ReplacedWords(field=key, key="presentation", was=was, now=now)
            )
    return tuple(replaced)


def generated_labels(plan: ImportPlan) -> Dict[str, str]:
    """``{field id: label}`` exactly as this run's generator produced it.

    What goes into the record, and deliberately *not* what goes into the file:
    a label the curator wrote is written to the file and is not recorded here,
    or the very next run would read the record back as its own work and
    overwrite them.  Recording what was generated is what makes "the curator
    changed this" answerable at all.
    """

    return {item.id: item.label for item in plan.fields}


def generated_help(plan: ImportPlan) -> Dict[str, str]:
    """``{field id: help}`` exactly as this run's vocabulary produced it.

    The same record ``generated_labels`` keeps, for the same reason and with
    the same exclusion: a sentence the curator wrote goes into the file and
    never in here, or the next run would read it back as its own work.

    A field the vocabulary said nothing about has **no entry** -- not an empty
    string.  An empty entry would say "we generated a blank line last time",
    and a curator who then wrote one would find it treated as ours.
    """

    produced: Dict[str, str] = {}
    for item in plan.fields:
        text = _generated_help(item)
        if text is not None:
            produced[item.id] = text
    return produced


def generated_presentation(presentation: Optional[Mapping[str, Any]]) -> Dict[str, Any]:
    """``{presentation key: value}`` exactly as this run's catalogue produced it.

    The record the other two keep, for the presentation block (T-0274), with
    the same exclusion: a key the curator wrote goes into the file and never in
    here.  ``presentation`` is the catalogue's own mapping, never the merged
    block that is written.  A key the catalogue did not emit has no entry, and
    a list is copied, so the record shares nothing with the catalogue.
    """

    return {
        key: list(value) if isinstance(value, (list, tuple)) else value
        for key, value in (presentation or {}).items()
    }


def _generated_help(item: PlannedField) -> Optional[str]:
    """The vocabulary's sentence for this field, or ``None``.

    Two lookups, in this order, and the order is the whole design:

    1. the **graph's own input name**, taken from ``targets``.  Never the
       field's id: T-0097 mints ``strength_clip-<hash>`` where one role covers
       two controls the wiring tells apart, and a lookup on the id would miss
       every such field.  Stripping the suffix back off with a string
       operation would be re-inventing, badly, a mapping ``targets`` already
       carries exactly.
    2. **only if that found nothing**, the role `analysis.py` minted, which
       for a field with no disambiguating suffix is its id (T-0131-02).  This
       is the fallback for the fields named by the *wiring* rather than by an
       input -- a negative prompt whose own input is called ``text``, which no
       input-name table can ever answer, because ``text`` is equally the
       positive prompt's.  The keys of that table are roles and a test holds
       them to ``analysis._ROLE_ORDER``, so the fallback cannot widen into
       "key on the id", which is the rule step 1 rejected on measured grounds.
       An exact match only: a ``negative_prompt-<hash>`` gets nothing rather
       than a guess about which of two prompts it is.

    Step 1 is never overridden.  A field whose input name is known takes that
    sentence and step 2 is not reached, so a sentence can never come from the
    second table while the first had an answer.

    **Targets that disagree on the input name get nothing at all**, from
    either table.  One field may drive several node inputs, and one sentence
    cannot honestly describe two differently-named ones -- so silence, which is
    what the schema means by an absent ``help``.

    That absolute reading is a **decision**, taken deliberately and not by
    oversight, and it was measured before it was taken: in a representative
    test catalogue, no field binding more than one input disagreed on the
    input name.  So refusing the role fallback here as well as the
    input-name lookup costs exactly nothing today, and it keeps the guard a
    statement about how well this field is understood rather than one about
    which table happens to hold a key.  Revisit it with a real graph in hand,
    not on the strength of the code looking asymmetric.
    """

    names = {name for _node, name in item.targets}
    if len(names) != 1:
        return None
    from_input_name = semantics.help_for(next(iter(names)))
    if from_input_name is not None:
        return from_input_name
    return semantics.help_for_role(item.id)


def _field_label(
    item: PlannedField, written: Mapping[str, str], remembered: Mapping[str, str]
) -> str:
    """This field's label: the curator's if it is theirs, ours otherwise.

    Three questions, in this order, and each of them decides a different case:

    * the file says nothing about this field -- a new field, or a definition
      that is not there at all -- so there is nothing to preserve;
    * the file says something and **no record of what we generated exists**, so
      it is preserved.  There is no evidence it was ours, and the run that
      finds no record is the run right after somebody deleted the inventory --
      which is no longer how a re-import is forced (``--regenerate-labels`` is,
      T-0116), but remains something a person can do;
    * there is a record, and the file still says what we last wrote -- nobody
      touched it, so this run's label replaces it and an improved generator
      reaches a catalogue that already exists.  Anything else is somebody's own
      words and is kept verbatim.
    """

    label = written.get(item.id)
    if label is None:
        return item.label
    last_generated = remembered.get(item.id)
    if last_generated is None:
        return label
    if label == last_generated:
        return item.label
    return label


def _field_help(
    item: PlannedField, written: Mapping[str, str], remembered: Mapping[str, str]
) -> Optional[str]:
    """This field's one-line hint: the curator's if it is theirs, ours otherwise.

    The three questions of :func:`_field_label`, in the same order and for the
    same reasons.  What differs is only that "ours" may be *nothing*:

    * the file says nothing about this field -- so there is nothing to
      preserve, and the vocabulary's answer stands, absent or not;
    * the file says something and **no record exists** -- preserved, because
      nothing shows it was ours and the run with no record is the run right
      after somebody deleted the inventory;
    * there is a record and the file still says what we last wrote -- nobody
      touched it, so this run's vocabulary replaces it.  Including when this
      run's vocabulary has *dropped* the sentence: a line we generated and no
      longer stand behind is removed rather than left behind as a fossil.
      Anything else is somebody's own words and is kept verbatim.
    """

    generated = _generated_help(item)
    text = written.get(item.id)
    if text is None:
        return generated
    last_generated = remembered.get(item.id)
    if last_generated is None:
        return text
    if text == last_generated:
        return generated
    return text


def _merge_presentation(
    presentation: Optional[Mapping[str, Any]],
    curated: Optional[CuratedDefinition],
    remembered: Optional[Mapping[str, Any]] = None,
    *,
    regenerate: bool = False,
) -> Dict[str, Any]:
    """The curator's keys, and this run's wherever a key is not theirs.

    Each key the file holds is asked the three questions of
    :func:`_field_label`, against ``remembered`` -- what the catalogue
    generated for this file the last time it was written (T-0274):

    * **no record of that key** -- kept verbatim.  Nothing shows it was ours:
      an inventory from before the record existed, a key the catalogue never
      generates (``catalog.CURATOR_ONLY``), or one the catalogue did not emit
      last time;
    * **the file still says what we last wrote** -- nobody touched it, so this
      run's value replaces it, and when this run's catalogue no longer emits
      the key at all the key is **removed** rather than left behind as a
      sentence nobody stands behind;
    * **anything else** is somebody's own words, and is kept verbatim.

    A key the file does not hold is filled from this run, so a curator who
    deleted a key gets it back.

    ``regenerate`` is the ``--regenerate-labels`` request (T-0116, T-0274):
    the file is not consulted for any key the catalogue generates, so each is
    exactly this run's -- present or absent.  The keys in ``CURATOR_ONLY`` are
    not generated by anything, so there is nothing to regenerate them *from*,
    and they are carried like any other curator-only key.

    A key the curator wrote that this schema does not know is carried too,
    sorted after the known ones, whatever is asked.  Dropping it would be a
    silent edit of somebody's file; carrying it means the real loader refuses
    the definition and names the key, which is the message that actually helps.
    """

    generated = dict(presentation or {})
    written = dict(curated.presentation) if curated is not None else {}
    record = dict(remembered or {})
    extra = sorted(key for key in written if key not in PRESENTATION_ORDER)
    merged: Dict[str, Any] = {}
    for key in tuple(PRESENTATION_ORDER) + tuple(extra):
        if key in written:
            # Only a key the catalogue generates can ever have been ours, so
            # only such a key consults the record or the request at all -- a
            # record hand-edited to name any other key changes nothing.
            ours = key in PRESENTATION_ORDER and key not in CURATOR_ONLY
            if not ours:
                merged[key] = written[key]
                continue
            if not regenerate and (key not in record or written[key] != record[key]):
                merged[key] = written[key]
                continue
        if key in generated:
            merged[key] = generated[key]
    return merged


def _field_document(
    item: PlannedField,
    *,
    label: Optional[str] = None,
    help_text: Optional[str] = None,
) -> Dict[str, Any]:
    document: Dict[str, Any] = {
        "id": item.id,
        "label": item.label if label is None else label,
        "type": item.type,
    }
    if item.required:
        document["required"] = True
    document["section"] = item.section
    if item.options:
        # Value only.  `docs/workflow-schema.md` defaults a missing ``label``
        # to the value written as text, which is exactly what the runtime
        # declared and what the curator sees in ComfyUI; writing that same
        # text out a second time would be a label nobody chose, in a file a
        # curator is invited to edit.
        document["options"] = [{"value": option} for option in item.options]
    if item.has_default:
        document["default"] = item.default
    # Whatever `analysis.py` found usable, and nothing this module decides.  A
    # bound absent there is a bound the runtime did not declare or one the
    # schema could not carry, and either way the key is left out entirely --
    # writing ``min: null`` would be a limit nobody set, and the loader refuses
    # it besides.
    for key, bound in (
        ("min", item.minimum),
        ("max", item.maximum),
        ("step", item.step),
    ):
        if bound is not None:
            document[key] = bound
    # The same principle as the bounds above, and it is the whole of the rule:
    # a field the vocabulary has nothing true to say about carries **no**
    # ``help`` key.  Not ``help: ""`` and not ``help: null`` -- either would be
    # a blank line of muted text under the control, which costs a phone's
    # vertical space to teach nothing, and the second is refused by the loader
    # besides.
    #
    # ``is not None`` and not a truth test, which is not pedantry.  The
    # generator never produces an empty sentence, so an empty string can only
    # be a curator's -- somebody who deleted the words to switch the hint off.
    # Dropping the key would put their file back to "no help written", and the
    # very next run would helpfully write the sentence again.
    if help_text is not None:
        document["help"] = help_text
    if item.translatable:
        document["translatable"] = True
    if item.role_hint is not None:
        document["role"] = item.role_hint
    if item.pair is not None:
        document["pair"] = item.pair
    if item.duration_fps is not None:
        document["duration"] = {"fps": item.duration_fps}
    document["bind"] = [
        {"node": node, "input": name} for node, name in item.targets
    ]
    return document


def render_definition(document: Dict[str, Any]) -> str:
    """The definition as the exact text that goes on disk.

    ``sort_keys=False`` because the order above is the order a person reads;
    ``allow_unicode`` because a prompt is written in somebody's own language
    and escaping it would make the file unreadable to its owner.
    """

    body = yaml.safe_dump(
        document,
        sort_keys=False,
        default_flow_style=False,
        allow_unicode=True,
        width=4096,
    )
    return GENERATED_HEADER + body


def build_definition(
    *,
    workflow_id: str,
    name: str,
    plan: ImportPlan,
    graph_bytes: bytes,
    digest: str,
    output: OutputPaths,
    presentation: Optional[Mapping[str, Any]] = None,
    curated: Optional[CuratedDefinition] = None,
    remembered_labels: Optional[Mapping[str, str]] = None,
    remembered_help: Optional[Mapping[str, str]] = None,
    regenerate_labels: bool = False,
    remembered_presentation: Optional[Mapping[str, Any]] = None,
) -> Tuple[Optional[DefinitionPlan], Optional[str]]:
    """Render one definition, or say why it cannot be placed."""

    definition_path = output.definitions / "{}.yaml".format(workflow_id)
    graph_path, relative, problem = _placement(workflow_id, digest, output)
    if problem is not None:
        return None, problem

    document = definition_document(
        plan,
        workflow_id=workflow_id,
        name=name,
        workflow_relative=relative,
        presentation=presentation,
        curated=curated,
        remembered_labels=remembered_labels,
        remembered_help=remembered_help,
        regenerate_labels=regenerate_labels,
        remembered_presentation=remembered_presentation,
    )
    return (
        DefinitionPlan(
            workflow_id=workflow_id,
            definition_path=definition_path,
            graph_path=graph_path,
            workflow_relative=relative,
            yaml_text=render_definition(document),
            graph_bytes=graph_bytes,
            fingerprint=_fingerprint_of_generated(
                plan,
                workflow_id=workflow_id,
                name=name,
                workflow_relative=relative,
                presentation=presentation,
            ),
        ),
        None,
    )


def generated_fingerprint(
    *,
    workflow_id: str,
    name: str,
    plan: ImportPlan,
    digest: str,
    output: OutputPaths,
    presentation: Optional[Mapping[str, Any]] = None,
) -> Optional[str]:
    """What this importer would write for ``plan`` on its own, as one string.

    The arguments are exactly :func:`build_definition`'s minus the four that
    carry somebody else's words -- ``curated``, ``remembered_labels``,
    ``remembered_help`` and ``remembered_presentation`` -- minus the request
    that sets them aside, and minus the graph's bytes, which ``digest``
    already stands for in the one place the definition mentions them.  So two
    runs that would generate the same definition from the same workflow agree
    here, whatever a curator has done to the file in between, and a run whose
    importer generates anything different -- a bound, a type, a label, a hint,
    a sentence of prose -- does not.

    ``None`` exactly when :func:`build_definition` would refuse to place the
    definition at all, which it then says why.
    """

    _graph_path, relative, problem = _placement(workflow_id, digest, output)
    if problem is not None:
        return None
    return _fingerprint_of_generated(
        plan,
        workflow_id=workflow_id,
        name=name,
        workflow_relative=relative,
        presentation=presentation,
    )


def _fingerprint_of_generated(
    plan: ImportPlan,
    *,
    workflow_id: str,
    name: str,
    workflow_relative: str,
    presentation: Optional[Mapping[str, Any]],
) -> str:
    """``sha256:`` over the canonical JSON of the importer's own document.

    The document is :func:`definition_document`'s -- the builder every written
    definition comes from, called with **no** ``curated`` and **no** remembered
    records, so there is no second copy of the rules to drift from the first.

    Why this representation, and not the alternatives:

    * **the document, not the rendered YAML.**  The YAML is a serialisation of
      it; hashing it would make a PyYAML upgrade that changes nothing but
      quoting read as "the importer reads every workflow differently" and put a
      rewrite in front of every definition in a catalogue.  The fixed header
      is not part of what the importer decides about a workflow either.
    * **canonical JSON: sorted keys, no whitespace, ASCII.**  A mapping's key
      order means nothing to the loader, so it is not allowed to mean anything
      here; lists keep their order, because the order of ``inputs``,
      ``options`` and ``bind`` does.  No custom encoder: every value in the
      document comes from a JSON graph, from the runtime's JSON answer or from
      this importer's own strings, so JSON can already carry each of them.
    * **nothing that varies between two runs over the same workflow.**  No
      timestamp reaches the document, and the one path in it is ``workflow``,
      relative to the definition and named after the graph's content -- the
      same for as long as the configured output folders and the graph are.
    * **sha256, prefixed with its name**, like every content hash this sync
      writes, so a later change of algorithm is a visible difference rather
      than a silent mismatch.
    """

    document = definition_document(
        plan,
        workflow_id=workflow_id,
        name=name,
        workflow_relative=workflow_relative,
        presentation=presentation,
    )
    canonical = json.dumps(
        document, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    )
    return "sha256:" + hashlib.sha256(canonical.encode("ascii")).hexdigest()


def _placement(
    workflow_id: str, digest: str, output: OutputPaths
) -> Tuple[Path, str, Optional[str]]:
    """Where the imported graph goes, and how the definition names it.

    One copy of the rule, shared by the definition and by its fingerprint, so
    the two can never disagree about the one path the definition carries.
    """

    graph_path = output.imported_api / graph_file_name(workflow_id, digest)
    try:
        relative = os.path.relpath(str(graph_path), str(output.definitions))
    except ValueError:
        return graph_path, "", (
            "the imported copy of this workflow would live on a different drive "
            "from its definition ({} and {}), and a definition may only name a "
            "graph by a path relative to itself. Put output.definitions and "
            "output.imported_api on one drive.".format(
                output.imported_api, output.definitions
            )
        )
    return graph_path, relative.replace("\\", "/"), None


def validate_definition(plan: DefinitionPlan) -> Optional[str]:
    """Load the generated definition with the real registry loader.

    Everything is staged first, at the same relative distance the two files
    will really have, so what is validated is what will exist and not an
    approximation of it.  The staging directory's name begins with a dot,
    which is exactly what ``load_registry`` skips, so a run of the gateway's
    own loader over the definitions folder can never see one.
    """

    parent = plan.definition_path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix=".lc-sync-stage-", dir=str(parent)))
    except OSError as exc:
        return "the definitions folder could not be prepared ({}): {}".format(
            exc.strerror or exc, parent
        )

    try:
        depth = _parent_steps(plan.workflow_relative)
        root = stage
        for _ in range(depth):
            root = root / "below"
        definitions = root / "definitions"
        definitions.mkdir(parents=True, exist_ok=True)

        staged_yaml = definitions / plan.definition_path.name
        staged_graph = Path(
            os.path.normpath(str(definitions / plan.workflow_relative))
        )
        staged_graph.parent.mkdir(parents=True, exist_ok=True)
        staged_graph.write_bytes(plan.graph_bytes)
        staged_yaml.write_bytes(plan.yaml_text.encode("utf-8"))

        registry = load_registry(definitions)
        if registry.diagnostics:
            return "the definition this run generated does not load: " + "; ".join(
                diagnostic.message for diagnostic in registry.diagnostics
            )
        if len(registry.workflows) != 1:
            return (
                "the definition this run generated produced {} workflows, and "
                "exactly one was expected.".format(len(registry.workflows))
            )
        return None
    except OSError as exc:
        return "the generated definition could not be checked ({}).".format(
            exc.strerror or exc
        )
    finally:
        shutil.rmtree(str(stage), ignore_errors=True)


def write_definition(plan: DefinitionPlan) -> Optional[str]:
    """Put the graph and then the definition in place.  Nothing else writes.

    The order is the point: the graph first, under a name derived from its own
    content, so that until the last line of this function the definition on
    disk and the graph it names are still the pair that was working.
    """

    problem = validate_definition(plan)
    if problem is not None:
        return problem
    try:
        _place(plan.graph_path, plan.graph_bytes)
        _place(plan.definition_path, plan.yaml_text.encode("utf-8"))
    except OSError as exc:
        return (
            "the definition could not be written ({}); {} was left as it "
            "was.".format(exc.strerror or exc, plan.definition_path)
        )
    return None


def _place(path: Path, data: bytes) -> None:
    """Write ``data`` at ``path`` atomically, or not at all.

    A file that already holds these bytes is left alone: rewriting it would
    change its timestamp and tell every tool watching the folder that
    something happened when nothing did.
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() == data:
        return
    temporary = path.with_name(path.name + ".{}.tmp".format(os.getpid()))
    try:
        with open(str(temporary), "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        _replace(str(temporary), str(path))
    except OSError:
        try:
            os.unlink(str(temporary))
        except OSError:
            pass
        raise


#: The one call that makes the swap atomic, bound here rather than reached
#: through ``os.`` so a test can substitute it without touching the module
#: every other part of the process shares.  ``inventory.py`` does the same.
_replace = os.replace


def _parent_steps(relative: str) -> int:
    """How many ``..`` the relative path starts with."""

    steps = 0
    for part in relative.replace("\\", "/").split("/"):
        if part == "..":
            steps += 1
        elif part not in ("", "."):
            break
    return steps


__all__ = [
    "GENERATED_HEADER",
    "CuratedDefinition",
    "DefinitionPlan",
    "DefinitionWrite",
    "build_definition",
    "definition_document",
    "generated_fingerprint",
    "generated_help",
    "generated_labels",
    "generated_presentation",
    "graph_file_name",
    "ReplacedWords",
    "read_curated",
    "render_definition",
    "replaced_by_regeneration",
    "validate_definition",
    "write_definition",
]
