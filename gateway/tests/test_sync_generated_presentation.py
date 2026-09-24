"""A presentation sentence the catalogue wrote is remembered as the catalogue's (T-0274).

Before this card every ``presentation`` key already in a definition was kept,
whoever wrote it -- so a sentence `catalog.py` generated, and later improved or
withdrew, stayed in every existing definition for good.  The labels and the
help lines had long had a record of what the importer generated (T-0110,
T-0131); the presentation had none.  Now it has one,
``InventoryEntry.generated_presentation``, and each key follows T-0110's rule:

* **the file still says what the catalogue last generated** -- nobody touched
  it, so a changed sentence is regenerated, and a sentence the catalogue no
  longer emits is **removed**;
* **the file says something else** -- a curator wrote it, and it is kept
  verbatim, through as many catalogue changes as there are;
* **there is no record** -- an inventory from before this card -- and what the
  file says is kept, exactly as before this card;
* the keys the catalogue never generates are the curator's, always.

``--regenerate-labels`` now covers the presentation the catalogue generates as
well, lists every key it replaced verbatim and counts them; the name and the
translation setting are still kept, and a dry run writes and records nothing.

The fingerprint (T-0246) is unchanged in meaning: a curator's presentation
edit does not move it.

Every expected word is written out in this file rather than computed by the
code under test.  Every graph is built here, out of node types that exist
nowhere else; no model, family or vendor is named.  The catalogue is changed
by wrapping ``engine.describe``, never by editing `catalog.py`, and each lever
is measured before it is pulled.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence

import pytest
import yaml

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import WorkflowState, analyse, run_sync
from localcanvas_gateway.workflows.sync import definitions as definitions_module
from localcanvas_gateway.workflows.sync import engine as engine_module
from localcanvas_gateway.workflows.sync.catalog import Catalog, CatalogEntry, describe
from localcanvas_gateway.workflows.sync.definitions import generated_fingerprint
from localcanvas_gateway.workflows.sync.engine import KEPT_NOTICE, REWRITTEN_NOTICE
from localcanvas_gateway.workflows.sync.inventory import read_inventory
from localcanvas_gateway.workflows.sync.report import report_document, summary_line
from sync_fixtures import SyncWorkspace, write_json

T1 = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
T2 = datetime(2026, 2, 3, 4, 5, 6, tzinfo=timezone.utc)
T3 = datetime(2026, 3, 4, 5, 6, 7, tzinfo=timezone.utc)
T4 = datetime(2026, 4, 5, 6, 7, 8, tzinfo=timezone.utc)
T5 = datetime(2026, 5, 6, 7, 8, 9, tzinfo=timezone.utc)

#: A moment long before any run here, stamped on a definition so a write --
#: which sets the current time -- cannot go unseen.
LONG_AGO_NS = 978_307_200 * 1_000_000_000

#: What `catalog.py` generates for ``lantern_graph`` today, measured once and
#: then written out -- never derived from the code under test.
GENERATED_SUMMARY = (
    "A written description goes in; a still image comes out. Negative prompt, "
    "Batch size and 6 more settings are kept under Advanced."
)
GENERATED_BEST_FOR = [
    "Turning a written description into a picture",
    "Reproducing an exact result by keeping its seed",
    "Choosing the size of the result",
    "Steering the result away from what you do not want",
]
GENERATED_HOW_TO_USE = (
    "Describe the subject, the setting and the light you want to see. Use the "
    "negative prompt for anything you do not want in the result. Set the width "
    "and the height before you generate. Keep the seed to get the same result "
    "again, or change it for a different one."
)
GENERATED_PRESENTATION = {
    "group": "Create",
    "badge": "TXT2IMG",
    "short_description": GENERATED_SUMMARY,
    "best_for": GENERATED_BEST_FOR,
    "how_to_use": GENERATED_HOW_TO_USE,
    "input_summary": "Prompt only",
    "example_prompt": "a lantern on a quay",
}

#: What an improved catalogue says instead.  No generator produces these.
IMPROVED_SUMMARY = "Words go in and one picture comes out, lit like a lantern."
IMPROVED_BEST_FOR = ["Night scenes", "Lamplit portraits"]
IMPROVED_HOW_TO_USE = "Name the light first. Then name what it falls on."
AGAIN_SUMMARY = "A second improvement, so a curated sentence is tested twice."

#: What a person types over the generated words.
BY_HAND_SUMMARY = "My own words about the quay pictures."
BY_HAND_BEST_FOR = ["The quay at dusk", "Lamps in the rain"]
BY_HAND_CATEGORY = "Harbour studies"
BY_HAND_NOT_IDEAL_FOR = ["Daylight"]
BY_HAND_NAME = "My lantern pictures"
BY_HAND_TRANSLATION = {"mode": "off"}


# ==========================================================================
# The graph, the workspace, and the levers
# ==========================================================================


def lantern_graph(*, steps: int = 18) -> Dict[str, Any]:
    return {
        "1": {
            "class_type": "LanternWeightsReader",
            "inputs": {"ckpt_name": "lantern-weights.safetensors"},
        },
        "2": {
            "class_type": "LanternBlankCanvas",
            "inputs": {"width": 768, "height": 512, "batch_size": 1},
        },
        "3": {
            "class_type": "LanternTextEncode",
            "inputs": {"text": "a lantern on a quay", "clip": ["1", 1]},
        },
        "4": {
            "class_type": "LanternTextEncode",
            "inputs": {"text": "haze", "clip": ["1", 1]},
        },
        "5": {
            "class_type": "LanternSampler",
            "inputs": {
                "seed": 31,
                "steps": steps,
                "cfg": 6.0,
                "denoise": 1.0,
                "model": ["1", 0],
                "positive": ["3", 0],
                "negative": ["4", 0],
                "latent_image": ["2", 0],
            },
        },
        "6": {
            "class_type": "LanternDecode",
            "inputs": {"samples": ["5", 0], "vae": ["1", 2]},
        },
        "7": {"class_type": "LanternSaveImage", "inputs": {"images": ["6", 0]}},
    }


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def sync(
    workspace: SyncWorkspace,
    now: datetime,
    *,
    regenerate_labels: bool = False,
    dry_run: bool = False,
):
    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "lantern.json", lantern_graph())
    workspace.write_config()
    return run_sync(
        workspace.load(), now=now, dry_run=dry_run, regenerate_labels=regenerate_labels
    )


def definition_path(workspace: SyncWorkspace) -> Path:
    return workspace.repo / "config" / "local" / "workflows" / "lantern.yaml"


def only(report):
    assert len(report.workflows) == 1, [item.state for item in report.workflows]
    return report.workflows[0]


def loaded(path: Path) -> Dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def presentation_in(path: Path) -> Dict[str, Any]:
    return dict(loaded(path).get("presentation") or {})


def edit(path: Path, change) -> None:
    """Edit a definition as a curator would: load it, change it, save it."""

    document = loaded(path)
    change(document)
    path.write_text(
        yaml.safe_dump(document, sort_keys=False, allow_unicode=True), encoding="utf-8"
    )


def entry(workspace: SyncWorkspace) -> Dict[str, Any]:
    found = workspace.read_inventory()["workflows"]
    assert len(found) == 1, found
    return found[0]


def rewrite_inventory(workspace: SyncWorkspace, change) -> None:
    document = workspace.read_inventory()
    for item in document["workflows"]:
        change(item)
    workspace.inventory_path.write_text(json.dumps(document, indent=2), encoding="utf-8")


def age(path: Path) -> int:
    os.utime(str(path), ns=(LONG_AGO_NS, LONG_AGO_NS))
    assert path.stat().st_mtime_ns == LONG_AGO_NS
    return LONG_AGO_NS


def change_the_catalogue(
    monkeypatch: pytest.MonkeyPatch,
    *,
    replace: Optional[Mapping[str, Any]] = None,
    drop: Sequence[str] = (),
) -> None:
    """The catalogue now says something else for some keys, and nothing for others.

    Every other key, and every note, is the real catalogue's.  Replacing the
    lever rather than editing `catalog.py` is what makes this a change in the
    generator and not in the fixture.
    """

    replacing = dict(replace or {})
    original = engine_module.describe

    def describe_differently(plan, document):
        catalog = original(plan, document)
        entries = []
        for item in catalog.entries:
            if item.key in drop:
                continue
            if item.key in replacing:
                item = CatalogEntry(
                    key=item.key, value=replacing[item.key], evidence=item.evidence
                )
            entries.append(item)
        return Catalog(entries=tuple(entries), notes=catalog.notes)

    monkeypatch.setattr(engine_module, "describe", describe_differently)


# ==========================================================================
# The levers, measured before they are pulled
# ==========================================================================


def test_the_table_above_is_what_the_catalogue_generates() -> None:
    graph = lantern_graph()
    plan = analyse(graph)
    assert not plan.problems, plan.problems
    assert describe(plan, graph).presentation == GENERATED_PRESENTATION
    for key in ("category", "not_ideal_for"):
        assert key not in GENERATED_PRESENTATION, key


def test_the_catalogue_lever_really_changes_and_drops_keys(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    change_the_catalogue(
        monkeypatch,
        replace={"short_description": IMPROVED_SUMMARY, "best_for": IMPROVED_BEST_FOR},
        drop=("how_to_use",),
    )
    graph = lantern_graph()
    produced = engine_module.describe(analyse(graph), graph).presentation
    assert produced["short_description"] == IMPROVED_SUMMARY != GENERATED_SUMMARY
    assert produced["best_for"] == IMPROVED_BEST_FOR != GENERATED_BEST_FOR
    assert "how_to_use" not in produced
    assert produced["input_summary"] == "Prompt only"


# ==========================================================================
# The record
# ==========================================================================


def test_what_the_catalogue_generated_is_recorded_and_read_back(
    workspace: SyncWorkspace,
) -> None:
    """Written to the inventory on disk, lists as lists, and read back."""

    report = sync(workspace, T1)
    assert only(report).definition.written is True
    assert presentation_in(definition_path(workspace)) == GENERATED_PRESENTATION

    recorded = entry(workspace)
    assert recorded["generated_presentation"] == GENERATED_PRESENTATION
    assert isinstance(recorded["generated_presentation"]["best_for"], list)
    # The reader, not only the writer.
    read = read_inventory(workspace.inventory_path).entries[0]
    assert read.generated_presentation == GENERATED_PRESENTATION


def test_a_curated_sentence_is_never_recorded_as_the_catalogues(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The file carries the curator's words; the record carries the catalogue's.

    Two catalogue changes, because it is the *second* one that would undo a
    curated sentence the first had recorded as the catalogue's own.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(
        definition,
        lambda document: document["presentation"].update(
            short_description=BY_HAND_SUMMARY, best_for=list(BY_HAND_BEST_FOR)
        ),
    )

    with monkeypatch.context() as changed:
        change_the_catalogue(
            changed,
            replace={
                "short_description": IMPROVED_SUMMARY,
                "best_for": IMPROVED_BEST_FOR,
                "how_to_use": IMPROVED_HOW_TO_USE,
            },
        )
        first = sync(workspace, T2)
    item = only(first)
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    assert presentation_in(definition)["how_to_use"] == IMPROVED_HOW_TO_USE, (
        "the run did not write the catalogue's change"
    )
    assert presentation_in(definition)["short_description"] == BY_HAND_SUMMARY
    assert presentation_in(definition)["best_for"] == BY_HAND_BEST_FOR
    assert entry(workspace)["generated_presentation"]["short_description"] == (
        IMPROVED_SUMMARY
    )
    assert entry(workspace)["generated_presentation"]["best_for"] == IMPROVED_BEST_FOR

    with monkeypatch.context() as changed_again:
        change_the_catalogue(
            changed_again,
            replace={"short_description": AGAIN_SUMMARY, "best_for": ["Once more"]},
        )
        second = sync(workspace, T3)
    assert only(second).definition.written is True
    assert presentation_in(definition)["how_to_use"] == GENERATED_HOW_TO_USE
    assert presentation_in(definition)["short_description"] == BY_HAND_SUMMARY
    assert presentation_in(definition)["best_for"] == BY_HAND_BEST_FOR


def test_a_write_that_failed_does_not_move_the_record_past_the_file(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A refused write leaves the record describing the file that is there.

    Advanced anyway, the record would say the improved sentence while the file
    still says the old one: the old one would read as curated from then on,
    and the next run that does write would keep it.  Both halves are asserted.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    intact = definition.read_bytes()
    change_the_catalogue(monkeypatch, replace={"short_description": IMPROVED_SUMMARY})

    def refuse_the_definition(source: str, target: str) -> None:
        if str(target).endswith(".yaml"):
            raise OSError(13, "Permission denied")
        os.replace(source, target)

    with monkeypatch.context() as failing:
        failing.setattr(definitions_module, "_replace", refuse_the_definition)
        report = sync(workspace, T2)
    item = only(report)
    assert item.definition.written is False
    assert item.definition.problem is not None
    assert definition.read_bytes() == intact, "the write was not actually refused"
    assert entry(workspace)["generated_presentation"]["short_description"] == (
        GENERATED_SUMMARY
    ), "the record moved past a file this run never wrote"

    report = sync(workspace, T3)
    assert only(report).definition.written is True
    assert presentation_in(definition)["short_description"] == IMPROVED_SUMMARY


def test_a_record_that_is_not_a_presentation_value_is_dropped_and_never_coerced(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A list holding a number is no record at all, so the file's words stay.

    Coerced, ``[7]`` would become ``['7']`` -- exactly what the curator's file
    says -- and the curator's list would be handed back to the catalogue.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, lambda document: document["presentation"].update(best_for=["7"]))

    def poison(item: Dict[str, Any]) -> None:
        item["generated_presentation"]["best_for"] = [7]
        item["generated_presentation"]["badge"] = 3

    rewrite_inventory(workspace, poison)
    read = read_inventory(workspace.inventory_path).entries[0]
    assert "best_for" not in read.generated_presentation
    assert "badge" not in read.generated_presentation
    assert read.generated_presentation["short_description"] == GENERATED_SUMMARY

    change_the_catalogue(
        monkeypatch,
        replace={"best_for": IMPROVED_BEST_FOR, "short_description": IMPROVED_SUMMARY},
    )
    report = sync(workspace, T2)
    assert only(report).definition.written is True
    assert presentation_in(definition)["short_description"] == IMPROVED_SUMMARY
    assert presentation_in(definition)["best_for"] == ["7"]


def test_the_record_survives_a_run_in_which_its_workflow_was_missing(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An entry no file explained this run is carried forward, record and all.

    Lost, the record would come back empty with the workflow: every generated
    sentence would then read as having no record, and be frozen.
    """

    sync(workspace, T1)
    source = workspace.sources[0] / "lantern.json"
    parked = workspace.outside / "lantern.json"
    source.replace(parked)
    missing = run_sync(workspace.load(), now=T2)
    assert [item.state for item in missing.workflows] == [
        WorkflowState.REMOVED_FROM_SOURCE
    ]
    assert entry(workspace)["generated_presentation"] == GENERATED_PRESENTATION

    parked.replace(source)
    change_the_catalogue(monkeypatch, replace={"short_description": IMPROVED_SUMMARY})
    back = run_sync(workspace.load(), now=T3)
    assert only(back).definition.written is True
    assert presentation_in(definition_path(workspace))["short_description"] == (
        IMPROVED_SUMMARY
    )


# ==========================================================================
# The rule, key by key
# ==========================================================================


def test_an_untouched_sentence_follows_the_catalogue_when_it_changes(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    change_the_catalogue(
        monkeypatch,
        replace={"short_description": IMPROVED_SUMMARY, "best_for": IMPROVED_BEST_FOR},
    )

    report = sync(workspace, T2)
    item = only(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    after = presentation_in(definition)
    assert after["short_description"] == IMPROVED_SUMMARY
    assert after["best_for"] == IMPROVED_BEST_FOR
    assert after["how_to_use"] == GENERATED_HOW_TO_USE
    assert entry(workspace)["generated_presentation"] == dict(
        GENERATED_PRESENTATION,
        short_description=IMPROVED_SUMMARY,
        best_for=IMPROVED_BEST_FOR,
    )
    assert not load_registry(definition.parent).diagnostics

    # And the run after it has nothing left to do.
    before = definition.read_bytes()
    stamp = age(definition)
    again = sync(workspace, T3)
    assert only(again).definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp


def test_a_sentence_the_catalogue_stopped_writing_is_removed(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The card's own case: a withdrawn short_description does not stay behind."""

    sync(workspace, T1)
    definition = definition_path(workspace)
    assert presentation_in(definition)["short_description"] == GENERATED_SUMMARY
    change_the_catalogue(monkeypatch, drop=("short_description", "best_for"))

    report = sync(workspace, T2)
    assert only(report).definition.written is True
    after = presentation_in(definition)
    assert "short_description" not in after
    assert "best_for" not in after
    assert after["how_to_use"] == GENERATED_HOW_TO_USE
    recorded = entry(workspace)["generated_presentation"]
    assert "short_description" not in recorded
    assert "best_for" not in recorded
    assert not load_registry(definition.parent).diagnostics


def test_a_curated_sentence_is_kept_verbatim_whether_changed_or_withdrawn(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(
        definition,
        lambda document: document["presentation"].update(
            short_description=BY_HAND_SUMMARY, best_for=list(BY_HAND_BEST_FOR)
        ),
    )
    change_the_catalogue(
        monkeypatch,
        replace={"short_description": IMPROVED_SUMMARY, "how_to_use": IMPROVED_HOW_TO_USE},
        drop=("best_for",),
    )

    report = sync(workspace, T2)
    assert only(report).definition.written is True
    after = presentation_in(definition)
    assert after["how_to_use"] == IMPROVED_HOW_TO_USE, "nothing was regenerated"
    assert after["short_description"] == BY_HAND_SUMMARY
    assert after["best_for"] == BY_HAND_BEST_FOR


def test_with_no_record_every_presentation_key_in_the_file_is_kept(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An inventory from before this card changes nothing about the file.

    Two workspaces that differ in one act -- the record taken out of one -- and
    the same catalogue change: the one with the record follows it, the one
    without keeps every sentence it has, exactly as before this card.
    """

    control = SyncWorkspace(tmp_path / "control")
    for space in (workspace, control):
        sync(space, T1)
    rewrite_inventory(workspace, lambda item: item.pop("generated_presentation"))
    assert "generated_presentation" not in entry(workspace)
    before = definition_path(workspace).read_bytes()

    change_the_catalogue(
        monkeypatch,
        replace={"short_description": IMPROVED_SUMMARY, "how_to_use": IMPROVED_HOW_TO_USE},
        drop=("best_for",),
    )
    with_record = sync(control, T2)
    without_record = sync(workspace, T2)

    assert only(with_record).definition.written is True
    assert presentation_in(definition_path(control))["short_description"] == IMPROVED_SUMMARY
    assert "best_for" not in presentation_in(definition_path(control))

    item = only(without_record)
    assert item.state is WorkflowState.UNCHANGED
    assert definition_path(workspace).read_bytes() == before
    assert presentation_in(definition_path(workspace)) == GENERATED_PRESENTATION
    assert item.definition.written is False
    assert item.definition.skipped == KEPT_NOTICE
    # The file is now provably what this importer writes for this plan, so the
    # record describes what the catalogue generated -- and the sentences kept
    # without a record read as the curator's from here on, as T-0110's labels
    # do; -RegenerateLabels is the way back.
    improved = dict(
        GENERATED_PRESENTATION,
        short_description=IMPROVED_SUMMARY,
        how_to_use=IMPROVED_HOW_TO_USE,
    )
    del improved["best_for"]
    assert entry(workspace)["generated_presentation"] == improved


def test_a_key_the_catalogue_did_not_emit_last_time_is_the_curators(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No record *of that key* is no record: a badge somebody added stays.

    The catalogue emits no badge on the first run, the curator writes one, and
    the catalogue then starts emitting one of its own.
    """

    with monkeypatch.context() as without_a_badge:
        change_the_catalogue(without_a_badge, drop=("badge",))
        sync(workspace, T1)
    definition = definition_path(workspace)
    assert "badge" not in presentation_in(definition)
    assert "badge" not in entry(workspace)["generated_presentation"]
    edit(definition, lambda document: document["presentation"].update(badge="LAMPS"))

    report = sync(workspace, T2)
    assert entry(workspace)["generated_presentation"]["badge"] == "TXT2IMG", (
        "the catalogue did not start emitting a badge"
    )
    assert presentation_in(definition)["badge"] == "LAMPS"
    # Written again for another reason, the badge is still the curator's.
    change_the_catalogue(monkeypatch, replace={"how_to_use": IMPROVED_HOW_TO_USE})
    report = sync(workspace, T3)
    assert only(report).definition.written is True
    assert presentation_in(definition)["how_to_use"] == IMPROVED_HOW_TO_USE
    assert presentation_in(definition)["badge"] == "LAMPS"


def test_the_keys_the_catalogue_never_writes_are_always_the_curators(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``category`` and ``not_ideal_for``: kept by a rewrite and by the flag.

    Even an inventory edited by hand to name them as generated changes nothing
    -- only a key the catalogue generates can ever have been the catalogue's.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(
        definition,
        lambda document: document["presentation"].update(
            category=BY_HAND_CATEGORY, not_ideal_for=list(BY_HAND_NOT_IDEAL_FOR)
        ),
    )

    def claim_them(item: Dict[str, Any]) -> None:
        item["generated_presentation"]["category"] = BY_HAND_CATEGORY
        item["generated_presentation"]["not_ideal_for"] = list(BY_HAND_NOT_IDEAL_FOR)

    rewrite_inventory(workspace, claim_them)
    change_the_catalogue(monkeypatch, replace={"how_to_use": IMPROVED_HOW_TO_USE})

    report = sync(workspace, T2)
    assert only(report).definition.written is True
    after = presentation_in(definition)
    assert after["how_to_use"] == IMPROVED_HOW_TO_USE
    assert after["category"] == BY_HAND_CATEGORY
    assert after["not_ideal_for"] == BY_HAND_NOT_IDEAL_FOR

    flagged = sync(workspace, T3, regenerate_labels=True)
    after = presentation_in(definition)
    assert after["category"] == BY_HAND_CATEGORY
    assert after["not_ideal_for"] == BY_HAND_NOT_IDEAL_FOR
    assert only(flagged).definition.replaced == ()


def test_a_label_the_catalogue_quotes_brings_its_untouched_prose_with_it(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The catalogue's prose names field labels, so a relabel reaches the prose.

    ``input_summary`` says "Prompt only" because the prompt's label is
    "Prompt".  A generator that relabels the prompt now brings the untouched
    summary along, where before this card it froze the old label in the prose.
    """

    from localcanvas_gateway.workflows.sync import analysis as analysis_module

    sync(workspace, T1)
    definition = definition_path(workspace)
    original = analysis_module._label
    monkeypatch.setattr(
        analysis_module,
        "_label",
        lambda role: "Scene text" if role == "prompt" else original(role),
    )

    report = sync(workspace, T2)
    assert only(report).definition.written is True
    assert presentation_in(definition)["input_summary"] == "Scene text only"


# ==========================================================================
# The fingerprint means what it meant
# ==========================================================================


def test_a_presentation_only_edit_does_not_move_the_fingerprint(
    workspace: SyncWorkspace,
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    fingerprint = entry(workspace)["generated_fingerprint"]
    assert fingerprint.startswith("sha256:")

    def curate_the_presentation(document: Dict[str, Any]) -> None:
        document["presentation"].update(
            short_description=BY_HAND_SUMMARY,
            best_for=list(BY_HAND_BEST_FOR),
            category=BY_HAND_CATEGORY,
        )
        del document["presentation"]["how_to_use"]

    edit(definition, curate_the_presentation)
    before = definition.read_bytes()
    stamp = age(definition)

    report = sync(workspace, T2)
    item = only(report)
    assert item.definition.written is False
    assert item.definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert entry(workspace)["generated_fingerprint"] == fingerprint
    assert entry(workspace)["generated_presentation"] == GENERATED_PRESENTATION

    # Asked of the function itself, from the same inputs a run gives it.
    graph = lantern_graph()
    plan = analyse(graph)
    config = workspace.load()
    digest = item.graph_hash
    assert generated_fingerprint(
        workflow_id="lantern",
        name=engine_module._display_name(item.candidate, item.id),
        plan=plan,
        digest=digest,
        output=config.output,
        presentation=describe(plan, graph).presentation,
    ) == fingerprint


# ==========================================================================
# The flag
# ==========================================================================


def curate_everything(document: Dict[str, Any]) -> None:
    document["name"] = BY_HAND_NAME
    document["translation"] = dict(BY_HAND_TRANSLATION)
    document["presentation"].update(
        short_description=BY_HAND_SUMMARY,
        best_for=list(BY_HAND_BEST_FOR),
        category=BY_HAND_CATEGORY,
    )


def test_the_flag_regenerates_the_presentation_and_lists_every_key_it_replaced(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Curated keys a normal run keeps; the flag replaces or removes them, loudly.

    ``how_to_use`` is curated and then withdrawn by the catalogue, so it is
    removed; ``short_description`` and ``best_for`` are curated and replaced.
    The name, the translation setting and ``category`` stay.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)

    def curate_and_rewrite_the_steps(document: Dict[str, Any]) -> None:
        curate_everything(document)
        document["presentation"]["how_to_use"] = "Mine."

    edit(definition, curate_and_rewrite_the_steps)
    change_the_catalogue(monkeypatch, drop=("how_to_use",))

    normal = sync(workspace, T2)
    assert only(normal).definition.written is True
    kept = presentation_in(definition)
    assert kept["short_description"] == BY_HAND_SUMMARY
    assert kept["best_for"] == BY_HAND_BEST_FOR
    assert kept["how_to_use"] == "Mine."

    regenerated = sync(workspace, T3, regenerate_labels=True)
    item = only(regenerated)
    assert item.definition.written is True
    document = loaded(definition)
    assert document["name"] == BY_HAND_NAME
    assert document["translation"] == BY_HAND_TRANSLATION
    assert document["presentation"] == {
        "group": "Create",
        "category": BY_HAND_CATEGORY,
        "badge": "TXT2IMG",
        "short_description": GENERATED_SUMMARY,
        "best_for": GENERATED_BEST_FOR,
        "input_summary": "Prompt only",
        "example_prompt": "a lantern on a quay",
    }
    assert not load_registry(definition.parent).diagnostics
    recorded = dict(GENERATED_PRESENTATION)
    del recorded["how_to_use"]
    assert entry(workspace)["generated_presentation"] == recorded

    assert item.definition.rewritten == (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so it kept none of them from the definition on disk: "
        "3 presentation keys that a run without this request would have kept "
        "were replaced (presentation key 'short_description': 'My own words about "
        "the quay pictures.' -> 'A written description goes in; a still image "
        "comes out. Negative prompt, Batch size and 6 more settings are kept "
        "under Advanced.'; presentation key 'best_for': ['The quay at dusk', "
        "'Lamps in the rain'] -> ['Turning a written description into a "
        "picture', 'Reproducing an exact result by keeping its seed', 'Choosing "
        "the size of the result', 'Steering the result away from what you do "
        "not want']; presentation key 'how_to_use': 'Mine.' -> removed). A name "
        "or translation setting you wrote, and any presentation key this "
        "importer never generates, was kept as always."
    )
    said = report_document(regenerated)
    assert said["workflows"][0]["definition"]["rewritten"] == item.definition.rewritten
    assert said["summary"] == (
        "1 workflow found, 1 importable (0 new, 0 changed, 1 unchanged), "
        "1 definition written, labels, help and presentation generated again on "
        "request: 0 labels, 0 help lines and 3 presentation keys were replaced, "
        "nothing needs attention."
    )

    before = definition.read_bytes()
    after = sync(workspace, T4)
    assert only(after).definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before


def test_the_flag_does_not_count_prose_nobody_touched(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """What is counted is what a normal run would have kept -- no wider.

    The catalogue changes a sentence nobody edited: the record equals the file,
    so a normal run would follow it too, and the flag counts nothing.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    change_the_catalogue(monkeypatch, replace={"short_description": IMPROVED_SUMMARY})

    report = sync(workspace, T2, regenerate_labels=True)
    item = only(report)
    assert item.definition.written is True
    assert presentation_in(definition)["short_description"] == IMPROVED_SUMMARY
    assert item.definition.replaced == ()
    assert (
        "0 labels, 0 help lines and 0 presentation keys were replaced"
    ) in summary_line(report)


def test_a_dry_run_with_the_flag_writes_nothing_records_nothing_and_lists_it(
    workspace: SyncWorkspace,
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate_everything)
    # The record is taken out first, so a dry run that recorded would be seen:
    # with it in place it would record exactly what is already there.
    rewrite_inventory(workspace, lambda item: item.pop("generated_presentation"))
    stamp = age(definition)
    tree_before = workspace.output_snapshot()
    inventory_before = workspace.inventory_path.read_bytes()

    report = sync(workspace, T2, regenerate_labels=True, dry_run=True)
    item = only(report)

    assert workspace.output_snapshot() == tree_before
    assert workspace.inventory_path.read_bytes() == inventory_before
    assert definition.stat().st_mtime_ns == stamp
    assert report.inventory_written is False
    assert item.generated_presentation == {}
    assert item.definition.written is False
    assert item.definition.would_write is True
    assert item.definition.skipped == (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so a real run would keep none of them from the "
        "definition on disk: 2 presentation keys that a run without this request "
        "would have kept would be replaced (presentation key 'short_description': "
        "'My own words about the quay pictures.' -> 'A written description goes "
        "in; a still image comes out. Negative prompt, Batch size and 6 more "
        "settings are kept under Advanced.'; presentation key 'best_for': ['The "
        "quay at dusk', 'Lamps in the rain'] -> ['Turning a written description "
        "into a picture', 'Reproducing an exact result by keeping its seed', "
        "'Choosing the size of the result', 'Steering the result away from what "
        "you do not want']). A name or translation setting you wrote, and any "
        "presentation key this importer never generates, would be kept as "
        "always. A dry run writes nothing, so this was not written."
    )
    assert summary_line(report) == (
        "1 workflow found, 1 importable (0 new, 0 changed, 1 unchanged), "
        "1 definition would be written, labels, help and presentation generated "
        "again on request: 0 labels, 0 help lines and 2 presentation keys would "
        "be replaced, nothing needs attention."
    )

    # And there really was something to replace.
    real = sync(workspace, T3, regenerate_labels=True)
    assert only(real).definition.written is True
    assert presentation_in(definition)["short_description"] == GENERATED_SUMMARY
    assert entry(workspace)["generated_presentation"] == GENERATED_PRESENTATION
    assert loaded(definition)["name"] == BY_HAND_NAME
