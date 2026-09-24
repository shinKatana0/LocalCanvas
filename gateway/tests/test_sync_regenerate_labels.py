"""Generating the labels and help again is a request, not deleting a file (T-0116).

T-0110 keeps a field label the inventory holds no record of generating, because
it cannot prove the label was the importer's.  That rule stays exactly as it
is.  What changes is the *occasion* for it: forcing a re-import used to mean
deleting the inventory, which made "a definition with no record" routine and
turned stale generated labels into curated ones.  ``--regenerate-labels`` is
the explicit request instead, and this file holds what it promises:

* **a curated label and help line survive a normal run and are replaced by a
  run with the flag**, verbatim before and after -- while the name, the
  presentation and the translation setting are kept by that same run;
* the run with the flag **records what it generated**, so the run after it
  writes nothing;
* it is **loud**: each definition says, word for word, what was replaced, and
  the summary line counts it;
* **a dry run with the flag writes nothing and records nothing**, and says
  exactly what a real run would replace;
* the keep for want of a runtime contract (T-0252) **still wins** over the
  request, and says that the request was not carried out -- except where the
  fingerprint is equal, when nothing is lost by carrying it out;
* the command line takes the flag, and without it the report says nothing
  about it.

Every expected word is written out in this file rather than computed by the
code under test.  Every graph is built here, out of node types that exist
nowhere else; no model, family or vendor is named.
"""

from __future__ import annotations

import dataclasses
import io
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict

import pytest
import yaml

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import WorkflowState, analyse, run_sync
from localcanvas_gateway.workflows.sync import engine as engine_module
from localcanvas_gateway.workflows.sync import semantics as semantics_module
from localcanvas_gateway.workflows.sync.bridge import (
    ComfyIdentity,
    Conversion,
    ConversionStatus,
)
from localcanvas_gateway.workflows.sync.cli import main as sync_main
from localcanvas_gateway.workflows.sync.contract import read_object_info
from localcanvas_gateway.workflows.sync.definitions import (
    generated_help,
    generated_labels,
)
from localcanvas_gateway.workflows.sync.engine import (
    KEPT_NOTICE,
    NO_CONTRACT_KEPT_NOTICE,
    NO_CONTRACT_MAYBE_KEPT_NOTICE,
    REWRITTEN_NOTICE,
)
from localcanvas_gateway.workflows.sync.report import report_document, summary_line
from sync_fixtures import UI_GRAPH, SyncWorkspace, write_json

T1 = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
T2 = datetime(2026, 2, 3, 4, 5, 6, tzinfo=timezone.utc)
T3 = datetime(2026, 3, 4, 5, 6, 7, tzinfo=timezone.utc)
T4 = datetime(2026, 4, 5, 6, 7, 8, tzinfo=timezone.utc)

#: A moment long before any run here, stamped on a definition so a write --
#: which sets the current time -- cannot go unseen.
LONG_AGO_NS = 978_307_200 * 1_000_000_000

#: What a person types over the generated words.  No generator produces these.
BY_HAND_LABEL = "What to picture"
BY_HAND_HELP = "Lower is looser, higher is stricter."
BY_HAND_NAME = "My harbour scenes"
BY_HAND_SUMMARY = "Written by me, about this workflow."
BY_HAND_TRANSLATION = {"mode": "off"}

#: What this importer generates for ``harbour_graph`` today, measured and then
#: written out -- never derived from the code under test.
GENERATED_LABELS = {
    "prompt": "Prompt",
    "negative_prompt": "Negative prompt",
    "batch_size": "Batch size",
    "cfg": "Cfg",
    "denoise": "Denoise",
    "height": "Height",
    "seed": "Seed",
    "steps": "Steps",
    "width": "Width",
}
GENERATED_HELP = {
    "prompt": "Describe what you want to see. More detail gives more to go on.",
    "negative_prompt": (
        "What to keep out of the result. Leave it empty if nothing comes to mind."
    ),
    "batch_size": "How many pictures to make in one go. More at once needs more memory.",
    "cfg": "How closely your words are followed. Too high looks harsh and overcooked.",
    "denoise": "How much of the starting picture is redrawn. Lower keeps more of it.",
    "height": "How tall the result is, in pixels. Bigger costs more time and memory.",
    "seed": "The starting point for the randomness. The same number repeats a result.",
    "steps": "How much work goes into the result. More steps, more detail, more waiting.",
    "width": "How wide the result is, in pixels. Bigger costs more time and memory.",
}

#: The bound the simulated importer change adds, so a normal run really writes.
NEW_MAXIMUM = 150


# ==========================================================================
# The graph, the workspace, and the levers
# ==========================================================================


def harbour_graph(*, seed: int = 4242, sampler: str = "HarbourSampler") -> Dict[str, Any]:
    return {
        "1": {
            "class_type": "HarbourWeightsReader",
            "inputs": {"ckpt_name": "harbour-weights.safetensors"},
        },
        "2": {
            "class_type": "HarbourBlankCanvas",
            "inputs": {"width": 512, "height": 512, "batch_size": 1},
        },
        "3": {
            "class_type": "HarbourTextEncode",
            "inputs": {"text": "a harbour at night", "clip": ["1", 1]},
        },
        "4": {
            "class_type": "HarbourTextEncode",
            "inputs": {"text": "grain, blur", "clip": ["1", 1]},
        },
        "5": {
            "class_type": sampler,
            "inputs": {
                "seed": seed,
                "steps": 20,
                "cfg": 7.0,
                "denoise": 1.0,
                "model": ["1", 0],
                "positive": ["3", 0],
                "negative": ["4", 0],
                "latent_image": ["2", 0],
            },
        },
        "6": {
            "class_type": "HarbourDecode",
            "inputs": {"samples": ["5", 0], "vae": ["1", 2]},
        },
        "7": {"class_type": "HarbourSaveImage", "inputs": {"images": ["6", 0]}},
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
    write_json(folder / "harbour.json", harbour_graph())
    workspace.write_config()
    return run_sync(
        workspace.load(),
        now=now,
        dry_run=dry_run,
        regenerate_labels=regenerate_labels,
    )


def definition_path(workspace: SyncWorkspace, workflow_id: str = "harbour") -> Path:
    return workspace.repo / "config" / "local" / "workflows" / "{}.yaml".format(
        workflow_id
    )


def only(report):
    assert len(report.workflows) == 1, [item.state for item in report.workflows]
    return report.workflows[0]


def loaded(path: Path) -> Dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def labels_in(path: Path) -> Dict[str, str]:
    return {item["id"]: item["label"] for item in loaded(path)["inputs"]}


def help_in(path: Path) -> Dict[str, str]:
    return {
        item["id"]: item["help"] for item in loaded(path)["inputs"] if "help" in item
    }


def field(path: Path, field_id: str) -> Dict[str, Any]:
    found = [item for item in loaded(path)["inputs"] if item["id"] == field_id]
    assert found, field_id
    return found[0]


def edit(path: Path, change) -> None:
    """Edit a definition as a curator would: load it, change it, save it."""

    document = loaded(path)
    change(document)
    path.write_text(
        yaml.safe_dump(document, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


def set_input(document: Dict[str, Any], field_id: str, key: str, value: Any) -> None:
    for item in document["inputs"]:
        if item["id"] == field_id:
            item[key] = value
            return
    raise AssertionError(field_id)


def curate(document: Dict[str, Any]) -> None:
    """A label, a help line, and the three things the flag must not touch."""

    document["name"] = BY_HAND_NAME
    document.setdefault("presentation", {})["short_description"] = BY_HAND_SUMMARY
    document["translation"] = dict(BY_HAND_TRANSLATION)
    set_input(document, "prompt", "label", BY_HAND_LABEL)
    set_input(document, "cfg", "help", BY_HAND_HELP)


def entry(workspace: SyncWorkspace, workflow_id: str = "harbour") -> Dict[str, Any]:
    found = [e for e in workspace.read_inventory()["workflows"] if e["id"] == workflow_id]
    assert len(found) == 1, workspace.read_inventory()["workflows"]
    return found[0]


def age(path: Path) -> int:
    os.utime(str(path), ns=(LONG_AGO_NS, LONG_AGO_NS))
    assert path.stat().st_mtime_ns == LONG_AGO_NS
    return LONG_AGO_NS


def change_the_importer(monkeypatch: pytest.MonkeyPatch) -> None:
    """The analysis now declares an upper bound on ``steps`` -- and no label."""

    original = engine_module.analyse

    def analyse_with_a_bound(document, **kwargs):
        plan = original(document, **kwargs)
        fields = tuple(
            dataclasses.replace(item, maximum=NEW_MAXIMUM)
            if item.id == "steps"
            else item
            for item in plan.fields
        )
        return dataclasses.replace(plan, fields=fields)

    monkeypatch.setattr(engine_module, "analyse", analyse_with_a_bound)


def change_the_labels(monkeypatch: pytest.MonkeyPatch) -> None:
    """The generator now labels every field differently (T-0110's lever)."""

    from localcanvas_gateway.workflows.sync import analysis as analysis_module

    original = analysis_module._label
    monkeypatch.setattr(
        analysis_module, "_label", lambda role: "Control for " + original(role).lower()
    )


# ==========================================================================
# The levers, measured before they are pulled
# ==========================================================================


def test_the_tables_above_are_what_this_importer_generates() -> None:
    plan = analyse(harbour_graph())
    assert not plan.problems, plan.problems
    assert generated_labels(plan) == GENERATED_LABELS
    assert generated_help(plan) == GENERATED_HELP
    assert GENERATED_LABELS["prompt"] != BY_HAND_LABEL
    assert GENERATED_HELP["cfg"] != BY_HAND_HELP


def test_the_changed_generator_really_produces_different_labels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    change_the_labels(monkeypatch)
    produced = generated_labels(analyse(harbour_graph()))
    assert produced["seed"] == "Control for seed"
    for field_id, label in GENERATED_LABELS.items():
        assert produced[field_id] != label, field_id


# ==========================================================================
# The flag itself
# ==========================================================================


def test_curated_words_survive_a_normal_run_and_the_flag_replaces_them(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The card's first criterion, end to end, in four runs.

    The normal run genuinely writes the file -- the importer gained a bound --
    so the curated words surviving it is the preservation rule at work and not
    an absence of a write.  The run with the flag then replaces exactly those
    two and the curated presentation key (T-0274), keeps the name and the
    translation, records what it generated, and says what it did; the run
    after it writes nothing.
    """

    first = sync(workspace, T1)
    definition = definition_path(workspace)
    assert only(first).definition.written is True
    assert labels_in(definition) == GENERATED_LABELS
    assert help_in(definition) == GENERATED_HELP

    edit(definition, curate)
    change_the_importer(monkeypatch)

    # -- a normal run: the file is written again, and the words survive ----
    normal = sync(workspace, T2)
    item = only(normal)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    assert field(definition, "steps")["max"] == NEW_MAXIMUM, "the normal run did not write"
    assert labels_in(definition)["prompt"] == BY_HAND_LABEL
    assert help_in(definition)["cfg"] == BY_HAND_HELP
    assert loaded(definition)["presentation"]["short_description"] == BY_HAND_SUMMARY
    assert "generated again" not in summary_line(normal)

    # -- the run with the flag --------------------------------------------
    regenerated = sync(workspace, T3, regenerate_labels=True)
    item = only(regenerated)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True

    document = loaded(definition)
    assert labels_in(definition) == GENERATED_LABELS
    assert labels_in(definition)["prompt"] == "Prompt"
    assert help_in(definition) == GENERATED_HELP
    assert help_in(definition)["cfg"] == (
        "How closely your words are followed. Too high looks harsh and overcooked."
    )
    assert document["name"] == BY_HAND_NAME
    # Since T-0274 the request covers the presentation the catalogue generates.
    assert document["presentation"]["short_description"] == (
        "A written description goes in; a still image comes out. Negative "
        "prompt, Batch size and 6 more settings are kept under Advanced."
    )
    assert document["translation"] == BY_HAND_TRANSLATION
    assert field(definition, "steps")["max"] == NEW_MAXIMUM
    assert not load_registry(definition.parent).diagnostics

    # What it recorded is what it generated, and the fingerprint is the one
    # a plain rewrite of this plan records.
    recorded = entry(workspace)
    assert recorded["generated_labels"] == GENERATED_LABELS
    assert recorded["generated_help"] == GENERATED_HELP
    assert recorded["generated_fingerprint"] == item.generated_fingerprint
    assert recorded["generated_fingerprint"].startswith("sha256:")

    assert item.definition.rewritten == (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so it kept none of them from the definition on "
        "disk: 1 label, 1 help line and 1 presentation key that a run without "
        "this request would have kept were replaced (label of 'prompt': 'What to "
        "picture' -> 'Prompt'; help of 'cfg': 'Lower is looser, higher is "
        "stricter.' -> 'How closely your words are followed. Too high looks "
        "harsh and overcooked.'; presentation key 'short_description': 'Written "
        "by me, about this workflow.' -> 'A written description goes in; a still "
        "image comes out. Negative prompt, Batch size and 6 more settings are "
        "kept under Advanced.'). A name or translation setting you wrote, and "
        "any presentation key this importer never generates, was kept as always."
    )
    said = report_document(regenerated)
    assert said["workflows"][0]["definition"]["rewritten"] == item.definition.rewritten
    assert said["summary"] == (
        "1 workflow found, 1 importable (0 new, 0 changed, 1 unchanged), "
        "1 definition written, labels, help and presentation generated again on "
        "request: 1 label, 1 help line and 1 presentation key were replaced, "
        "nothing needs attention."
    )

    # -- the run after it writes nothing ----------------------------------
    before = definition.read_bytes()
    stamp = age(definition)
    inventory_before = entry(workspace)
    after = sync(workspace, T4)
    item = only(after)
    assert item.definition.written is False
    assert item.definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    after_entry = entry(workspace)
    for key in (
        "generated_labels", "generated_help", "generated_presentation",
        "generated_fingerprint",
    ):
        assert after_entry[key] == inventory_before[key], key
    assert "0 definitions written" in summary_line(after)


def test_the_stale_labels_a_deleted_inventory_froze_are_put_right_by_the_flag(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The ambiguity the card was filed about, and its way out.

    The generator changes and the inventory is deleted: the run that follows
    cannot prove the file's labels were its own, so it keeps them (T-0110,
    unchanged) and records the new ones -- the file and the record now
    disagree for good.  The flag is what brings the file back to the
    generator, and after it the record and the file agree again.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    assert labels_in(definition) == GENERATED_LABELS

    change_the_labels(monkeypatch)
    workspace.inventory_path.unlink()

    frozen = sync(workspace, T2)
    assert only(frozen).definition.written is True
    assert labels_in(definition) == GENERATED_LABELS, "T-0110's preservation rule moved"
    assert entry(workspace)["generated_labels"]["seed"] == "Control for seed"
    # The catalogue names two of those labels in its prose, and with no record
    # that prose is frozen exactly as the labels are (T-0274).
    assert loaded(definition)["presentation"]["input_summary"] == "Prompt only"
    assert entry(workspace)["generated_presentation"]["input_summary"] == (
        "Control for prompt only"
    )

    regenerated = sync(workspace, T3, regenerate_labels=True)
    item = only(regenerated)
    assert item.definition.written is True
    assert labels_in(definition) == {
        field_id: "Control for " + label.lower()
        for field_id, label in GENERATED_LABELS.items()
    }
    assert entry(workspace)["generated_labels"] == labels_in(definition)
    assert entry(workspace)["generated_presentation"] == loaded(definition)["presentation"]
    assert item.definition.rewritten.startswith(
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so it kept none of them from the definition on disk: "
        "9 labels and 2 presentation keys that a run without this request would "
        "have kept were replaced (label of 'prompt': "
        "'Prompt' -> 'Control for prompt'; label of 'negative_prompt': "
        "'Negative prompt' -> 'Control for negative prompt'; "
    )
    assert item.definition.rewritten.endswith(
        "presentation key 'short_description': 'A written description goes in; a "
        "still image comes out. Negative prompt, Batch size and 6 more settings "
        "are kept under Advanced.' -> 'A written description goes in; a still "
        "image comes out. Control for negative prompt, Control for batch size and "
        "6 more settings are kept under Advanced.'; presentation key "
        "'input_summary': 'Prompt only' -> 'Control for prompt only'). A name or "
        "translation setting you wrote, and any presentation key this importer "
        "never generates, was kept as always."
    )
    assert (
        "9 labels, 0 help lines and 2 presentation keys were replaced"
    ) in summary_line(regenerated)

    before = definition.read_bytes()
    again = sync(workspace, T4)
    assert only(again).definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before


def test_with_the_inventory_gone_the_flag_writes_the_records_and_the_fingerprint(
    workspace: SyncWorkspace,
) -> None:
    """Records and fingerprint that did not exist are there after the flag."""

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)
    workspace.inventory_path.unlink()

    report = sync(workspace, T2, regenerate_labels=True)
    item = only(report)
    assert item.state is WorkflowState.NEW
    assert item.definition.written is True
    assert labels_in(definition) == GENERATED_LABELS
    assert help_in(definition) == GENERATED_HELP
    assert loaded(definition)["name"] == BY_HAND_NAME

    recorded = entry(workspace)
    assert recorded["generated_labels"] == GENERATED_LABELS
    assert recorded["generated_help"] == GENERATED_HELP
    assert recorded["generated_fingerprint"].startswith("sha256:")

    before = definition.read_bytes()
    after = sync(workspace, T3)
    assert only(after).definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before


def test_a_help_line_with_no_generated_sentence_goes_and_an_emptied_one_comes_back(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The two shapes a replaced help line can take, said as they happened.

    ``help: ""`` is how a curator switches a hint off, and a normal run keeps
    it; the flag writes the sentence back.  A curator's sentence on a field the
    vocabulary no longer has one for is kept by a normal run; the flag removes
    the key, and the report says "no help line" rather than an empty quote.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)

    def switch_off_and_write(document: Dict[str, Any]) -> None:
        set_input(document, "steps", "help", "")
        set_input(document, "seed", "help", BY_HAND_HELP)

    edit(definition, switch_off_and_write)
    thinner = dict(semantics_module.INPUT_HELP)
    del thinner["seed"]
    monkeypatch.setattr(semantics_module, "INPUT_HELP", thinner)
    assert "seed" not in generated_help(analyse(harbour_graph())), "the lever did not move"

    report = sync(workspace, T2, regenerate_labels=True)
    item = only(report)
    assert item.definition.written is True
    assert help_in(definition)["steps"] == GENERATED_HELP["steps"]
    assert "help" not in field(definition, "seed")
    assert item.definition.rewritten == (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so it kept none of them from the definition on disk: "
        "2 help lines that a run without this request would have kept were "
        "replaced (help of 'seed': 'Lower is looser, higher is stricter.' -> no "
        "help line; help of 'steps': '' -> 'How much work goes into the result. "
        "More steps, more detail, more waiting.'). A name or translation setting "
        "you wrote, and any presentation key this importer never generates, was "
        "kept as always."
    )


def test_a_definition_with_nothing_curated_says_nothing_was_replaced(
    workspace: SyncWorkspace,
) -> None:
    """New, or already the generator's own: the request is still reported."""

    report = sync(workspace, T1, regenerate_labels=True)
    item = only(report)
    assert item.state is WorkflowState.NEW
    assert item.definition.written is True
    assert item.definition.rewritten == (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so it kept none of them from the definition on disk: "
        "no label, help line or presentation key that a run without this request "
        "would have kept differed from what this run generated, so nothing you "
        "wrote was replaced. A name or translation setting you wrote, and any "
        "presentation key this importer never generates, was kept as always."
    )
    assert labels_in(definition_path(workspace)) == GENERATED_LABELS
    assert summary_line(report) == (
        "1 workflow found, 1 importable (1 new, 0 changed, 0 unchanged), "
        "1 definition written, labels, help and presentation generated again on "
        "request: 0 labels, 0 help lines and 0 presentation keys were replaced, "
        "nothing needs attention."
    )


def test_labels_nobody_touched_follow_the_generator_and_are_not_counted_as_replaced(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """What is counted is what a run without the flag would have kept -- no wider.

    The generator changes all nine labels and nobody edited any of them: the
    record still equals the file, so a normal run would refresh them too.  The
    flag run changes all nine in the file, counts none of them, and the
    sentence must say exactly that much -- not that no label differed, which
    would be false here (T-0116 review, defect 1).
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    assert labels_in(definition) == GENERATED_LABELS
    assert entry(workspace)["generated_labels"] == GENERATED_LABELS
    change_the_labels(monkeypatch)

    report = sync(workspace, T2, regenerate_labels=True)
    item = only(report)
    assert item.definition.written is True
    after = labels_in(definition)
    changed = [
        field_id for field_id, label in GENERATED_LABELS.items()
        if after[field_id] != label
    ]
    assert len(changed) == 9, after
    assert after["seed"] == "Control for seed"

    assert item.definition.replaced == ()
    assert item.definition.rewritten == (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so it kept none of them from the definition on disk: "
        "no label, help line or presentation key that a run without this request "
        "would have kept differed from what this run generated, so nothing you "
        "wrote was replaced. A name or translation setting you wrote, and any "
        "presentation key this importer never generates, was kept as always."
    )
    assert "no label or help line in it differed" not in item.definition.rewritten
    assert (
        "labels, help and presentation generated again on request: 0 labels, "
        "0 help lines and 0 presentation keys were replaced"
    ) in summary_line(report)


def test_the_flag_on_a_definition_that_is_already_the_generators_writes_nothing(
    workspace: SyncWorkspace,
) -> None:
    """Unchanged, uncurated, and no fingerprint yet: the identical-output path.

    The flag skips the fingerprint keep, so the definition is built again --
    and is byte for byte what is there, so nothing is written, the records are
    set on a real run, and neither is on a dry run.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    document = workspace.read_inventory()
    for item in document["workflows"]:
        del item["generated_fingerprint"]
    workspace.inventory_path.write_text(json.dumps(document, indent=2), encoding="utf-8")
    before = definition.read_bytes()
    stamp = age(definition)
    already = (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, and the result is exactly the definition already on "
        "disk, so nothing "
        "was written and nothing you wrote was replaced."
    )

    dry = sync(workspace, T2, regenerate_labels=True, dry_run=True)
    item = only(dry)
    assert item.definition.skipped == already
    assert item.definition.written is False
    assert item.generated_fingerprint is None, "a dry run recorded a fingerprint"
    assert "fingerprint" not in json.dumps(entry(workspace))

    real = sync(workspace, T3, regenerate_labels=True)
    item = only(real)
    assert item.definition.skipped == already
    assert item.definition.written is False
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert entry(workspace)["generated_fingerprint"].startswith("sha256:")


# ==========================================================================
# The dry run
# ==========================================================================


def test_a_dry_run_with_the_flag_writes_nothing_records_nothing_and_lists_it(
    workspace: SyncWorkspace,
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)
    # The records this importer keeps are taken out first.  With them in place,
    # a dry run that recorded would record exactly what is already there, and
    # "nothing was recorded" could not be told from "the same was recorded".
    document = workspace.read_inventory()
    for item in document["workflows"]:
        del item["generated_labels"]
        del item["generated_help"]
        del item["generated_presentation"]
        del item["generated_fingerprint"]
    workspace.inventory_path.write_text(json.dumps(document, indent=2), encoding="utf-8")
    stamp = age(definition)
    tree_before = workspace.output_snapshot()
    inventory_before = workspace.inventory_path.read_bytes()
    recorded_before = entry(workspace)
    assert "generated_labels" not in recorded_before

    report = sync(workspace, T2, regenerate_labels=True, dry_run=True)
    item = only(report)

    assert workspace.output_snapshot() == tree_before
    assert workspace.inventory_path.read_bytes() == inventory_before
    assert definition.stat().st_mtime_ns == stamp
    assert report.inventory_written is False
    # Nothing recorded in memory either: the records the run carries are the
    # ones it read.
    assert item.state is WorkflowState.UNCHANGED
    assert item.generated_labels == {}
    assert item.generated_help == {}
    assert item.generated_presentation == {}
    assert item.generated_fingerprint is None

    assert item.definition.written is False
    assert item.definition.would_write is True
    assert item.definition.skipped == (
        "this run was asked to generate the field labels, help lines and "
        "presentation again, so a real run would keep none of them from the "
        "definition on disk: 1 label, 1 help line and 1 presentation key that a "
        "run without this request would have kept would be replaced (label of "
        "'prompt': 'What to picture' -> 'Prompt'; help of 'cfg': 'Lower is "
        "looser, higher is stricter.' -> 'How closely your words are followed. "
        "Too high looks harsh and overcooked.'; presentation key "
        "'short_description': 'Written by me, about this workflow.' -> 'A written "
        "description goes in; a still image comes out. Negative prompt, Batch "
        "size and 6 more settings are kept under Advanced.'). A name or "
        "translation setting you wrote, and any presentation key this importer "
        "never generates, would be kept as always. A dry run writes nothing, so "
        "this was not written."
    )
    assert summary_line(report) == (
        "1 workflow found, 1 importable (0 new, 0 changed, 1 unchanged), "
        "1 definition would be written, labels, help and presentation generated "
        "again on request: 1 label, 1 help line and 1 presentation key would be "
        "replaced, nothing needs attention."
    )

    # And there really was something to replace.
    real = sync(workspace, T3, regenerate_labels=True)
    assert only(real).definition.written is True
    assert labels_in(definition)["prompt"] == "Prompt"


# ==========================================================================
# T-0252's keep still wins
# ==========================================================================

OBJECT_INFO = {
    "HarbourSampler": {
        "input": {
            "required": {
                "steps": ["INT", {"min": 1, "max": 200, "step": 1}],
                "cfg": ["FLOAT", {"min": 0.0, "max": 30.0, "step": 0.5}],
            }
        },
        "output": [],
        "name": "HarbourSampler",
    }
}


class ComfyWithAContract:
    """A reachable ComfyUI: an identity, a contract, and one conversion."""

    def ensure_identity(self):
        self.identity = ComfyIdentity.build(
            comfyui_version="0.0.0-test", frontend_version="0.0.0-test",
            node_types=sorted(OBJECT_INFO),
        )
        return self.identity

    def runtime_contract(self):
        identity = getattr(self, "identity", None)
        if identity is None:
            return None
        return read_object_info(OBJECT_INFO, identity_digest=identity.digest)

    def convert(self, raw, *, content_hash):
        return Conversion(
            status=ConversionStatus.CONVERTED, document=harbour_graph(seed=99)
        )


def mixed_sync(
    workspace: SyncWorkspace,
    now: datetime,
    bridge,
    *,
    sampler: str = "HarbourSampler",
    regenerate_labels: bool = False,
):
    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "api.json", harbour_graph(sampler=sampler))
    write_json(folder / "canvas.json", UI_GRAPH)
    workspace.write_config()
    return run_sync(
        workspace.load(), now=now, bridge=bridge, regenerate_labels=regenerate_labels
    )


def api_item(report):
    found = [
        item for item in report.workflows
        if item.candidate is not None and item.candidate.relative == "api.json"
    ]
    assert len(found) == 1, [item.id for item in report.workflows]
    return found[0]


def test_without_a_contract_the_flag_does_not_take_away_what_one_declared(
    workspace: SyncWorkspace,
) -> None:
    """The keep for want of a contract wins, and says the request was not met."""

    mixed_sync(workspace, T1, ComfyWithAContract())
    definition = definition_path(workspace, "api")
    assert field(definition, "steps")["max"] == 200, "the contract did not reach the file"
    edit(definition, lambda document: set_input(document, "prompt", "label", BY_HAND_LABEL))
    before = definition.read_bytes()
    stamp = age(definition)
    recorded_before = entry(workspace, "api")
    assert recorded_before["generated_with_contract"] is True

    report = mixed_sync(workspace, T2, None, regenerate_labels=True)
    item = api_item(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is False
    assert item.definition.skipped == NO_CONTRACT_KEPT_NOTICE + (
        " This run was asked to generate the field labels, help lines and "
        "presentation again, and did not for this workflow: writing it without that answer from ComfyUI "
        "would also have taken away what its fields accept. Run it again with "
        "ComfyUI available."
    )
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    after = entry(workspace, "api")
    for key in (
        "generated_labels", "generated_help", "generated_presentation",
        "generated_fingerprint", "generated_with_contract",
    ):
        assert after[key] == recorded_before[key], key
    assert (
        "labels, help and presentation generated again on request: 0 labels, 0 "
        "help lines and 0 presentation keys were replaced, 1 definition left as it "
        "was for want of an answer from ComfyUI"
    ) in summary_line(report)


def test_without_a_contract_record_the_flag_does_not_override_the_maybe_keep(
    workspace: SyncWorkspace,
) -> None:
    """An inventory from before the contract record, a run without ComfyUI.

    The catalogue holds an editor-format workflow, so this run would normally
    have had a contract, and the definition may have been made with one: T-0252
    keeps it.  The flag must not lift that keep -- on the first flag run after
    upgrading without ComfyUI it would take the declared limits away -- and the
    sentence says the definition *may* have been made with that answer.
    """

    mixed_sync(workspace, T1, ComfyWithAContract())
    definition = definition_path(workspace, "api")
    assert field(definition, "steps")["max"] == 200, "the contract did not reach the file"
    edit(definition, lambda document: set_input(document, "prompt", "label", BY_HAND_LABEL))
    # The inventory as an importer from before the contract record wrote it.
    document = workspace.read_inventory()
    for item in document["workflows"]:
        item.pop("generated_fingerprint", None)
        item.pop("generated_with_contract", None)
    workspace.inventory_path.write_text(json.dumps(document, indent=2), encoding="utf-8")
    before = definition.read_bytes()
    stamp = age(definition)
    recorded_before = entry(workspace, "api")
    assert "generated_with_contract" not in recorded_before

    report = mixed_sync(workspace, T2, None, regenerate_labels=True)
    item = api_item(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is False
    assert item.definition.skipped == NO_CONTRACT_MAYBE_KEPT_NOTICE + (
        " This run was asked to generate the field labels, help lines and "
        "presentation again, and did not for this workflow: the definition may have been made with "
        "ComfyUI's answer about what its fields accept, and writing it without that "
        "answer could have taken that away. Run it again with ComfyUI available."
    )
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert field(definition, "steps")["max"] == 200
    assert labels_in(definition)["prompt"] == BY_HAND_LABEL
    after = entry(workspace, "api")
    for key in ("generated_labels", "generated_help", "generated_presentation",
                "generated_fingerprint", "generated_with_contract"):
        assert after.get(key) == recorded_before.get(key), key
    assert (
        "labels, help and presentation generated again on request: 0 labels, 0 "
        "help lines and 0 presentation keys were replaced, 1 definition left as it "
        "was for want of an answer from ComfyUI"
    ) in summary_line(report)


def test_without_a_contract_the_flag_still_runs_where_the_fingerprint_is_equal(
    workspace: SyncWorkspace,
) -> None:
    """Equal fingerprint: nothing the contract declared can be lost, so no keep.

    The export's sampler is one the stand-in ComfyUI declares nothing about,
    so its plan is the same with or without the contract -- measured, by a
    normal run without a contract keeping it on the fingerprint alone.
    """

    mixed_sync(workspace, T1, ComfyWithAContract(), sampler="UndeclaredSampler")
    definition = definition_path(workspace, "api")
    assert entry(workspace, "api")["generated_with_contract"] is True
    edit(definition, lambda document: set_input(document, "prompt", "label", BY_HAND_LABEL))

    normal = mixed_sync(workspace, T2, None, sampler="UndeclaredSampler")
    assert api_item(normal).definition.skipped == KEPT_NOTICE, "the fingerprint is not equal"

    report = mixed_sync(
        workspace, T3, None, sampler="UndeclaredSampler", regenerate_labels=True
    )
    item = api_item(report)
    assert item.definition.written is True
    assert labels_in(definition)["prompt"] == "Prompt"
    assert "left as it was" not in summary_line(report)


# ==========================================================================
# The command line
# ==========================================================================


def run_cli(*argv):
    out, err = io.StringIO(), io.StringIO()
    code = sync_main([str(item) for item in argv], out=out, err=err)
    return code, out.getvalue(), err.getvalue()


def test_the_command_line_flag_reaches_the_run_and_its_absence_leaves_no_trace(
    workspace: SyncWorkspace,
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)

    code, output, _ = run_cli("--config", workspace.config_path)
    assert code == 0
    plain = json.loads(output)
    assert "generated again" not in plain["summary"]
    assert "asked to generate" not in output
    assert labels_in(definition)["prompt"] == BY_HAND_LABEL

    code, output, _ = run_cli(
        "--config", workspace.config_path, "--regenerate-labels", "--dry-run"
    )
    assert code == 0
    assert (
        "1 label, 1 help line and 1 presentation key would be replaced"
    ) in json.loads(output)["summary"]
    assert labels_in(definition)["prompt"] == BY_HAND_LABEL

    code, output, _ = run_cli("--config", workspace.config_path, "--regenerate-labels")
    assert code == 0
    said = json.loads(output)
    assert "1 label, 1 help line and 1 presentation key were replaced" in said["summary"]
    assert said["workflows"][0]["definition"]["rewritten"].startswith(
        "this run was asked to generate the field labels, help lines and "
        "presentation again"
    )
    assert labels_in(definition)["prompt"] == "Prompt"
