"""An importer change reaches a definition whose workflow did not change (T-0246).

Before this card an ``UNCHANGED`` workflow -- the same source bytes as last
time -- kept its definition whenever one was on disk, so an improvement to the
analysis reached only the workflows somebody happened to re-save.  Now each
inventory entry records a fingerprint of the definition **this importer would
write for the plan on its own**, and:

    UNCHANGED, fingerprint equal                 ->  kept, byte for byte
    UNCHANGED, fingerprint different or absent   ->  written again, through the
                                                     path a CHANGED one takes

What this file holds, each against the mistake it guards:

* a real importer change -- a bound the analysis did not declare before --
  writes the unchanged definition again, and the curator's label, help line
  and name survive it verbatim; without the change the file is not touched,
  asserted on its bytes **and** on an mtime set far in the past, so a write
  would have been seen;
* the fingerprint is the importer's alone: a curator's edit on a definition
  written *with* a curated file present is kept on the next run, which it
  cannot be if curated input reached the fingerprint; two workspaces at
  different paths, synced at different moments, record the same value;
* an inventory an older importer wrote, with no fingerprint: written once, and
  then kept -- kept on the fingerprint, proved by an edit the byte comparison
  would have undone;
* a failed write leaves the old fingerprint, and the next run tries again;
* a dry run writes nothing, records nothing, and says what would be written;
* the summary counts definitions written, beside the counts it already had;
* what the rewrite sentence claims is kept and replaced is measured here, key
  by key, rather than trusted.

Every graph is built in this file out of invented node types.  Nothing depends
on a real ComfyUI, model or node pack.
"""

from __future__ import annotations

import dataclasses
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

import pytest
import yaml

import localcanvas_gateway.workflows.sync.engine as engine_module
from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import (
    WorkflowState,
    analyse,
    definitions as definitions_module,
    report_document,
    run_sync,
    summary_line,
)
from localcanvas_gateway.workflows.sync.bridge import (
    CATEGORY_COMFY_UNREACHABLE,
    BridgeError,
    ComfyIdentity,
    Conversion,
    ConversionStatus,
)
from localcanvas_gateway.workflows.sync.contract import read_object_info
from localcanvas_gateway.workflows.sync.engine import (
    DRY_RUN_DEFINITION_NOTICE,
    DRY_RUN_REWRITE_NOTICE,
    KEPT_NOTICE,
    NO_CONTRACT_KEPT_NOTICE,
    NO_CONTRACT_MAYBE_KEPT_NOTICE,
    REWRITTEN_NOTICE,
)
from sync_fixtures import UI_GRAPH, SyncWorkspace, tree_snapshot, write_json

#: Four different moments.  Every run in a scenario gets its own, so a
#: timestamp that reached the fingerprint would change it between two runs.
T1 = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
T2 = datetime(2026, 2, 3, 4, 5, 6, tzinfo=timezone.utc)
T3 = datetime(2026, 3, 4, 5, 6, 7, tzinfo=timezone.utc)
T4 = datetime(2026, 4, 5, 6, 7, 8, tzinfo=timezone.utc)

#: A moment long before any run here, stamped on a definition so that a write
#: -- which sets the current time -- cannot go unseen, however fast it is.
LONG_AGO_NS = 978_307_200 * 1_000_000_000

#: What a person types over the generated words.  No generator produces these.
BY_HAND_LABEL = "What to picture"
BY_HAND_HELP = "Lower is looser, higher is stricter."
BY_HAND_NAME = "My evening scenes"
BY_HAND_SUMMARY = "Written by me, about this workflow."

#: The bound the simulated importer change adds.  The analysis today declares
#: none for this field, which the lever test below measures before use.
NEW_MAXIMUM = 150


# ==========================================================================
# The graph and the importer change
# ==========================================================================


def scene_graph(*, steps: int = 24) -> Dict[str, Any]:
    """One ordinary generation, out of node types that exist nowhere else."""

    return {
        "1": {
            "class_type": "SceneWeightsReader",
            "inputs": {"ckpt_name": "scene-weights.safetensors"},
        },
        "2": {
            "class_type": "SceneBlankCanvas",
            "inputs": {"width": 640, "height": 480, "batch_size": 1},
        },
        "3": {
            "class_type": "SceneTextEncode",
            "inputs": {"text": "a lighthouse in fog", "clip": ["1", 1]},
        },
        "4": {
            "class_type": "SceneTextEncode",
            "inputs": {"text": "noise, smear", "clip": ["1", 1]},
        },
        "5": {
            "class_type": "SceneSampler",
            "inputs": {
                "seed": 777,
                "steps": steps,
                "cfg": 5.5,
                "denoise": 1.0,
                "model": ["1", 0],
                "positive": ["3", 0],
                "negative": ["4", 0],
                "latent_image": ["2", 0],
            },
        },
        "6": {
            "class_type": "SceneDecode",
            "inputs": {"samples": ["5", 0], "vae": ["1", 2]},
        },
        "7": {"class_type": "SceneSaveImage", "inputs": {"images": ["6", 0]}},
    }


def change_the_importer(monkeypatch: pytest.MonkeyPatch) -> None:
    """The analysis now declares an upper bound on ``steps``.

    A monkeypatched analysis, never an edited one: the engine's own reference
    to ``analyse`` is wrapped, so what changes is exactly what an improved
    `analysis.py` would change -- the plan -- and nothing downstream of it is
    touched.
    """

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


# ==========================================================================
# Helpers
# ==========================================================================


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def sync(
    workspace: SyncWorkspace,
    now: datetime,
    *,
    graph: Optional[Dict[str, Any]] = None,
    dry_run: bool = False,
):
    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "scene.json", graph if graph is not None else scene_graph())
    workspace.write_config()
    return run_sync(workspace.load(), now=now, dry_run=dry_run)


def definition_path(workspace: SyncWorkspace) -> Path:
    return workspace.repo / "config" / "local" / "workflows" / "scene.yaml"


def only(report):
    assert len(report.workflows) == 1, [item.state for item in report.workflows]
    return report.workflows[0]


def loaded(path: Path) -> Dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


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
    """The three curated words the card names, plus a presentation line."""

    document["name"] = BY_HAND_NAME
    document.setdefault("presentation", {})["short_description"] = BY_HAND_SUMMARY
    set_input(document, "prompt", "label", BY_HAND_LABEL)
    set_input(document, "cfg", "help", BY_HAND_HELP)


def entry(workspace: SyncWorkspace) -> Dict[str, Any]:
    workflows = workspace.read_inventory()["workflows"]
    assert len(workflows) == 1, workflows
    return workflows[0]


def recorded(workspace: SyncWorkspace) -> Optional[str]:
    return entry(workspace).get("generated_fingerprint")


def age(path: Path) -> int:
    """Stamp ``path`` as written long ago, and return that stamp."""

    os.utime(str(path), ns=(LONG_AGO_NS, LONG_AGO_NS))
    assert path.stat().st_mtime_ns == LONG_AGO_NS
    return LONG_AGO_NS


def forget_the_fingerprint(workspace: SyncWorkspace) -> None:
    """The inventory as an importer from before this card wrote it."""

    document = workspace.read_inventory()
    for item in document["workflows"]:
        del item["generated_fingerprint"]
        del item["generated_with_contract"]
    workspace.inventory_path.write_text(json.dumps(document, indent=2), encoding="utf-8")


# ==========================================================================
# The levers, measured before they are pulled
# ==========================================================================


def test_the_simulated_importer_change_really_changes_what_is_generated(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Without this, "written again" could be a claim about a no-op."""

    plain = {item.id: item for item in analyse(scene_graph()).fields}
    assert not analyse(scene_graph()).problems
    assert plain["steps"].maximum is None
    assert plain["prompt"].label != BY_HAND_LABEL

    change_the_importer(monkeypatch)
    changed = {item.id: item for item in engine_module.analyse(scene_graph()).fields}
    assert changed["steps"].maximum == NEW_MAXIMUM
    assert {key: value for key, value in changed.items() if key != "steps"} == {
        key: value for key, value in plain.items() if key != "steps"
    }


def test_the_fixture_writes_a_generated_help_line_the_curator_can_replace(
    workspace: SyncWorkspace,
) -> None:
    """The curated help line replaces a generated one, not an absence."""

    sync(workspace, T1)
    written = field(definition_path(workspace), "cfg")
    assert isinstance(written.get("help"), str) and written["help"]
    assert written["help"] != BY_HAND_HELP
    assert field(definition_path(workspace), "prompt")["label"] != BY_HAND_LABEL


# ==========================================================================
# Decision 2 and 3: kept while equal, written again when not
# ==========================================================================


def test_without_an_importer_change_the_curated_definition_is_not_touched(
    workspace: SyncWorkspace,
) -> None:
    """Fingerprint equal: kept exactly as before this card, on bytes and mtime.

    The curator also changed a ``default`` -- something a rewrite replaces --
    so this is the fingerprint keeping the file, not a rewrite that happened to
    come out the same.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)
    edit(definition, lambda document: set_input(document, "steps", "default", 33))
    before = definition.read_bytes()
    stamp = age(definition)

    report = sync(workspace, T2)

    item = only(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is False
    assert item.definition.skipped == KEPT_NOTICE
    assert item.definition.rewritten is None
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert field(definition, "steps")["default"] == 33


def test_an_importer_change_writes_the_unchanged_definition_again_keeping_curated_words(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The defect itself, and the three curated words asserted verbatim."""

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)
    before = definition.read_bytes()
    stamp = age(definition)
    fingerprint_before = recorded(workspace)
    assert fingerprint_before is not None
    assert "max" not in field(definition, "steps")

    change_the_importer(monkeypatch)
    report = sync(workspace, T2)

    item = only(report)
    assert item.state is WorkflowState.UNCHANGED, "the source identity moved"
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    assert item.definition.skipped is None
    assert definition.read_bytes() != before
    assert definition.stat().st_mtime_ns != stamp

    # The importer's change arrived ...
    assert field(definition, "steps")["max"] == NEW_MAXIMUM
    # ... and the curator's words stayed, verbatim.
    document = loaded(definition)
    assert document["name"] == BY_HAND_NAME
    assert document["presentation"]["short_description"] == BY_HAND_SUMMARY
    assert field(definition, "prompt")["label"] == BY_HAND_LABEL
    assert field(definition, "cfg")["help"] == BY_HAND_HELP

    assert recorded(workspace) not in (None, fingerprint_before)
    registry = load_registry(definition.parent)
    assert registry.diagnostics == ()

    # And in the report, where the script reads it.
    said = report_document(report)["workflows"][0]["definition"]
    assert said["written"] is True
    assert said["rewritten"] == REWRITTEN_NOTICE


def test_an_edit_made_after_a_rewrite_is_kept_by_the_next_run(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The recorded fingerprint is the importer's own, whatever the file held.

    The rewrite here happens **with a curated file present**, so a fingerprint
    that took curated input would record something the importer alone never
    generates -- and the next run, finding it different, would write again and
    replace the ``default`` the curator changed afterwards.  Every run has its
    own moment, so a timestamp in the fingerprint fails the same way.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)

    change_the_importer(monkeypatch)
    rewrite = sync(workspace, T2)
    assert only(rewrite).definition.written is True

    edit(definition, lambda document: set_input(document, "steps", "default", 35))
    before = definition.read_bytes()
    stamp = age(definition)

    report = sync(workspace, T3)

    item = only(report)
    assert item.definition.written is False
    assert item.definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert field(definition, "steps")["default"] == 35


def test_the_fingerprint_depends_on_neither_the_moment_nor_the_place_nor_the_curator(
    tmp_path: Path,
) -> None:
    """The same workflow, the same importer: the same fingerprint.

    Two workspaces at different absolute paths, synced at different moments,
    one of them rewritten over a curated file by a changed workflow.  All three
    record one value, because all three would generate one definition on their
    own.
    """

    plain = SyncWorkspace(tmp_path / "first place")
    elsewhere = SyncWorkspace(tmp_path / "a second, other place")
    curated = SyncWorkspace(tmp_path / "curated place")

    sync(plain, T1, graph=scene_graph(steps=40))
    sync(elsewhere, T4, graph=scene_graph(steps=40))

    sync(curated, T2, graph=scene_graph(steps=24))
    edit(definition_path(curated), curate)
    changed = sync(curated, T3, graph=scene_graph(steps=40))
    assert only(changed).state is WorkflowState.CHANGED
    assert loaded(definition_path(curated))["name"] == BY_HAND_NAME

    assert recorded(plain) is not None
    assert recorded(plain) == recorded(elsewhere) == recorded(curated)
    assert recorded(plain).startswith("sha256:")


# ==========================================================================
# No fingerprint recorded -- an inventory an older importer wrote
# ==========================================================================


def test_with_no_fingerprint_a_definition_the_importer_now_reads_differently_is_written_once(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Written once, then kept -- and kept on the fingerprint.

    Between the second and third run the curator changes a ``default``.  A
    run that decided on the bytes alone would find the file different from
    what it generates and write it again; one that decides on the recorded
    fingerprint keeps it.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)
    forget_the_fingerprint(workspace)
    assert "generated_fingerprint" not in entry(workspace)

    change_the_importer(monkeypatch)
    first = sync(workspace, T2)
    item = only(first)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    assert field(definition, "steps")["max"] == NEW_MAXIMUM
    assert field(definition, "prompt")["label"] == BY_HAND_LABEL
    assert recorded(workspace) is not None

    edit(definition, lambda document: set_input(document, "steps", "default", 36))
    before = definition.read_bytes()
    stamp = age(definition)

    second = sync(workspace, T3)
    assert only(second).definition.written is False
    assert only(second).definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp


def test_with_no_fingerprint_a_definition_already_equal_is_left_alone_and_recorded(
    workspace: SyncWorkspace,
) -> None:
    """Nothing to write is not reported as a write, and the record still lands.

    The importer did not change, so what it would write is what is on disk.
    The run touches nothing and counts nothing -- and records the fingerprint,
    which the next run then keeps a curator's later edit on.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    forget_the_fingerprint(workspace)
    before = definition.read_bytes()
    stamp = age(definition)

    report = sync(workspace, T2)
    item = only(report)
    assert item.definition.written is False
    assert item.definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert report.definitions_written == 0
    assert recorded(workspace) is not None

    edit(definition, lambda document: set_input(document, "steps", "default", 37))
    before = definition.read_bytes()
    report = sync(workspace, T3)
    assert only(report).definition.written is False
    assert definition.read_bytes() == before


# ==========================================================================
# Decision 6: recorded only after a successful write
# ==========================================================================


def test_a_failed_write_leaves_the_old_fingerprint_and_the_next_run_tries_again(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    intact = definition.read_bytes()
    fingerprint_before = recorded(workspace)
    assert fingerprint_before is not None

    change_the_importer(monkeypatch)

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
    assert recorded(workspace) == fingerprint_before

    retry = sync(workspace, T3)
    again = only(retry)
    assert again.state is WorkflowState.UNCHANGED
    assert again.definition.written is True
    assert again.definition.rewritten == REWRITTEN_NOTICE
    assert field(definition, "steps")["max"] == NEW_MAXIMUM
    assert recorded(workspace) not in (None, fingerprint_before)


# ==========================================================================
# Decision 5: the dry run
# ==========================================================================


def test_a_dry_run_writes_nothing_records_nothing_and_says_what_would_be_written(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    sync(workspace, T1)
    definition = definition_path(workspace)
    edit(definition, curate)
    fingerprint_before = recorded(workspace)
    inventory_before = workspace.inventory_path.read_bytes()
    tree_before = tree_snapshot(workspace.output_tree)
    stamp = age(definition)

    change_the_importer(monkeypatch)
    report = sync(workspace, T2, dry_run=True)

    item = only(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is False
    assert item.definition.would_write is True
    assert item.definition.skipped == DRY_RUN_REWRITE_NOTICE
    assert item.generated_fingerprint == fingerprint_before, "the dry run recorded"
    assert workspace.inventory_path.read_bytes() == inventory_before
    assert tree_snapshot(workspace.output_tree) == tree_before
    assert definition.stat().st_mtime_ns == stamp

    assert summary_line(report) == (
        "1 workflow found, 1 importable (0 new, 0 changed, 1 unchanged), "
        "1 definition would be written, nothing needs attention."
    )
    said = report_document(report)["workflows"][0]["definition"]
    assert said["skipped"] == DRY_RUN_REWRITE_NOTICE

    # The same state, for real: the write the dry run described does happen,
    # so the silence above was the dry run's and not an absence of anything
    # to write.
    real = sync(workspace, T3)
    assert only(real).definition.written is True
    assert tree_snapshot(workspace.output_tree) != tree_before
    assert recorded(workspace) not in (None, fingerprint_before)


def test_a_dry_run_counts_only_what_would_really_be_written(
    workspace: SyncWorkspace,
) -> None:
    sync(workspace, T1)
    forget_the_fingerprint(workspace)

    kept = sync(workspace, T2, dry_run=True)
    assert only(kept).definition.would_write is False
    assert only(kept).definition.skipped == KEPT_NOTICE
    assert "0 definitions would be written" in summary_line(kept)
    assert "generated_fingerprint" not in entry(workspace), "the dry run recorded"

    other = SyncWorkspace(workspace.base.parent / "brand new")
    new = sync(other, T1, dry_run=True)
    assert only(new).definition.skipped == DRY_RUN_DEFINITION_NOTICE
    assert "1 definition would be written" in summary_line(new)
    assert not other.inventory_path.exists()


# ==========================================================================
# Decision 4: the summary line
# ==========================================================================


def test_the_summary_line_counts_definitions_written_beside_the_counts_it_had(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    first = sync(workspace, T1)
    assert summary_line(first) == (
        "1 workflow found, 1 importable (1 new, 0 changed, 0 unchanged), "
        "1 definition written, nothing needs attention."
    )

    kept = sync(workspace, T2)
    assert summary_line(kept) == (
        "1 workflow found, 1 importable (0 new, 0 changed, 1 unchanged), "
        "0 definitions written, nothing needs attention."
    )

    change_the_importer(monkeypatch)
    rewritten = sync(workspace, T3)
    assert summary_line(rewritten) == (
        "1 workflow found, 1 importable (0 new, 0 changed, 1 unchanged), "
        "1 definition written, nothing needs attention."
    )
    assert report_document(rewritten)["summary"] == summary_line(rewritten)
    assert report_document(rewritten)["definitions"]["written"] == 1


def test_the_summary_counts_every_definition_written_in_the_plural(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", scene_graph(steps=20))
    write_json(folder / "two.json", scene_graph(steps=30))
    workspace.write_config()
    report = run_sync(workspace.load(), now=T1)
    assert summary_line(report) == (
        "2 workflows found, 2 importable (2 new, 0 changed, 0 unchanged), "
        "2 definitions written, nothing needs attention."
    )


# ==========================================================================
# The sentence, measured
# ==========================================================================


def test_what_the_rewrite_sentence_says_is_kept_and_replaced_is_what_happens(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Every clause of ``REWRITTEN_NOTICE``, against the file it describes.

    Kept: the name, the translation setting, and a presentation key, a label
    and a help line the curator wrote.  Generated again: the list of fields, and each
    field's type, section, default, choices, limits and bindings.

    ``cfg`` is made a choice from the first run on, by the same kind of
    wrapped analysis as the importer change, because nothing in a graph alone
    produces a list of choices -- and "choices" is a clause like any other.
    """

    original = engine_module.analyse

    def cfg_is_a_choice(document, **kwargs):
        plan = original(document, **kwargs)
        fields = tuple(
            dataclasses.replace(item, type="select", options=(5.5, 7.0))
            if item.id == "cfg"
            else item
            for item in plan.fields
        )
        return dataclasses.replace(plan, fields=fields)

    monkeypatch.setattr(engine_module, "analyse", cfg_is_a_choice)

    sync(workspace, T1)
    definition = definition_path(workspace)
    generated = loaded(definition)
    generated_steps = field(definition, "steps")
    generated_seed = field(definition, "seed")
    assert field(definition, "cfg")["options"] == [{"value": 5.5}, {"value": 7.0}]

    def curate_everything(document: Dict[str, Any]) -> None:
        curate(document)
        set_input(document, "cfg", "options", [{"value": 5.5}])
        document["translation"] = {"mode": "off"}
        set_input(document, "steps", "default", 31)
        set_input(document, "steps", "section", "main")
        set_input(document, "steps", "min", 5)
        set_input(document, "seed", "type", "string")
        set_input(document, "seed", "bind", [{"node": "99", "input": "seed"}])
        document["inputs"] = [
            item for item in document["inputs"] if item["id"] != "denoise"
        ]

    edit(definition, curate_everything)

    change_the_importer(monkeypatch)
    report = sync(workspace, T2)
    assert only(report).definition.rewritten == REWRITTEN_NOTICE

    after = loaded(definition)
    # Kept from the file.
    assert after["name"] == BY_HAND_NAME
    assert after["presentation"]["short_description"] == BY_HAND_SUMMARY
    assert after["translation"] == {"mode": "off"}
    assert field(definition, "prompt")["label"] == BY_HAND_LABEL
    assert field(definition, "cfg")["help"] == BY_HAND_HELP
    # Generated again from the workflow.
    assert [item["id"] for item in after["inputs"]] == [
        item["id"] for item in generated["inputs"]
    ]
    steps = field(definition, "steps")
    assert steps["default"] == generated_steps["default"]
    assert steps["section"] == generated_steps["section"]
    assert steps.get("min") == generated_steps.get("min")
    assert steps["max"] == NEW_MAXIMUM
    seed = field(definition, "seed")
    assert seed["type"] == generated_seed["type"]
    assert seed["bind"] == generated_seed["bind"]
    assert field(definition, "cfg")["options"] == [{"value": 5.5}, {"value": 7.0}]
    assert load_registry(definition.parent).diagnostics == ()
    assert (
        "Kept from the file: its name, its translation setting, and every "
        "presentation key, field label and help line you wrote."
    ) in REWRITTEN_NOTICE


# ==========================================================================
# The header says it, and does not move the fingerprint
# ==========================================================================


def test_the_header_says_when_a_definition_is_written_again_and_what_it_keeps(
    workspace: SyncWorkspace,
) -> None:
    sync(workspace, T1)
    text = definition_path(workspace).read_text(encoding="utf-8")
    header = "".join(
        line[2:] + " " for line in text.splitlines() if line.startswith("# ")
    )
    assert text.startswith(definitions_module.GENERATED_HEADER)
    assert "has changed, or when this importer now reads that unchanged workflow differently" in header
    assert (
        "keeps the name, presentation, translation setting and every field label "
        "and help line you wrote"
    ) in header


def test_the_header_text_does_not_change_the_fingerprint(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A different header, different bytes -- the same fingerprint.

    And a header change alone therefore never rewrites a definition that has a
    fingerprint recorded: the next run keeps the file with the old header.
    """

    plain = SyncWorkspace(tmp_path / "this header")
    other = SyncWorkspace(tmp_path / "another header")

    sync(plain, T1)
    with monkeypatch.context() as patched:
        patched.setattr(
            definitions_module, "GENERATED_HEADER", "# A different header.\n"
        )
        sync(other, T1)
    assert definition_path(plain).read_bytes() != definition_path(other).read_bytes()
    assert definition_path(other).read_text(encoding="utf-8").startswith(
        "# A different header.\n"
    )
    assert recorded(plain) is not None
    assert recorded(plain) == recorded(other)

    before = definition_path(plain).read_bytes()
    with monkeypatch.context() as patched:
        patched.setattr(
            definitions_module, "GENERATED_HEADER", "# A different header.\n"
        )
        report = sync(plain, T2)
    assert only(report).definition.skipped == KEPT_NOTICE
    assert definition_path(plain).read_bytes() == before


# ==========================================================================
# The identical-output shortcut: what it records, and what it checks
# ==========================================================================


def relabel_cfg_in_the_importer(monkeypatch: pytest.MonkeyPatch) -> str:
    """The importer now generates a different label for ``cfg`` only.

    ``cfg`` and not ``prompt``: the catalogue's generated presentation names the
    prompt's label (``input_summary: Prompt only``), and since T-0274 an
    untouched generated presentation key follows the catalogue -- so relabelling
    the prompt now rightly changes the file, and the file could never come out
    byte-identical, which is the whole premise of the shortcut test below.
    ``cfg``'s label appears in no presentation key of this graph.
    """

    original = engine_module.analyse
    relabelled = "Guidance"

    def analyse_with_a_new_label(document, **kwargs):
        plan = original(document, **kwargs)
        fields = tuple(
            dataclasses.replace(item, label=relabelled) if item.id == "cfg" else item
            for item in plan.fields
        )
        return dataclasses.replace(plan, fields=fields)

    monkeypatch.setattr(engine_module, "analyse", analyse_with_a_new_label)
    return relabelled


def test_the_identical_output_shortcut_records_this_runs_contract_state(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Review comment 1: the shortcut records ``False`` from a run with none.

    An API-format catalogue never has a runtime contract.  A curator replaced
    cfg's label -- edited in the text, so the file stays exactly what the
    builder renders -- and the importer then changes only that generated
    label.  The fingerprint differs, the curated label is kept, the file comes
    out byte-identical, and the shortcut records.  Recorded as made *with* a
    contract, every later run of this catalogue would keep the file for want
    of one, and no importer change would ever reach it again; so the next
    importer change is asserted to be written.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    assert entry(workspace)["generated_with_contract"] is False
    text = definition.read_text(encoding="utf-8")
    generated_line = "- id: cfg\n  label: Cfg\n"
    assert text.count(generated_line) == 1, "the fixture's cfg label moved"
    definition.write_bytes(
        text.replace(generated_line, "- id: cfg\n  label: {}\n".format(BY_HAND_LABEL))
        .encode("utf-8")
    )
    before = definition.read_bytes()
    stamp = age(definition)
    fingerprint_before = recorded(workspace)

    relabelled = relabel_cfg_in_the_importer(monkeypatch)
    report = sync(workspace, T2)

    # The shortcut really was taken: the fingerprint moved, nothing was written.
    item = only(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is False
    assert item.definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert recorded(workspace) not in (None, fingerprint_before)
    assert entry(workspace)["generated_labels"]["cfg"] == relabelled
    # And what it recorded is this run's contract state.
    assert entry(workspace)["generated_with_contract"] is False

    change_the_importer(monkeypatch)
    after = sync(workspace, T3)
    assert only(after).definition.written is True
    assert only(after).definition.rewritten == REWRITTEN_NOTICE
    assert field(definition, "steps")["max"] == NEW_MAXIMUM
    assert field(definition, "cfg")["label"] == BY_HAND_LABEL


def test_with_no_fingerprint_a_deleted_graph_is_put_back(
    workspace: SyncWorkspace,
) -> None:
    """Review comment 2: an equal YAML beside a missing graph is not "on disk".

    The first run after upgrading has no fingerprint; the definition's YAML is
    exactly what the builder renders, but the imported graph it names has been
    deleted.  Recording and writing nothing would leave a definition that does
    not load, kept on an equal fingerprint for good.
    """

    sync(workspace, T1)
    definition = definition_path(workspace)
    graph = (definition.parent / loaded(definition)["workflow"]).resolve()
    original = graph.read_bytes()
    forget_the_fingerprint(workspace)
    yaml_before = definition.read_bytes()
    graph.unlink()
    assert not graph.exists()
    registry = load_registry(definition.parent)
    assert registry.diagnostics != (), "a missing graph loads; nothing is under test"

    report = sync(workspace, T2)

    assert only(report).state is WorkflowState.UNCHANGED
    assert graph.exists(), "the imported graph was not put back"
    assert graph.read_bytes() == original
    assert definition.read_bytes() == yaml_before
    assert load_registry(definition.parent).diagnostics == ()
    assert recorded(workspace) is not None


# ==========================================================================
# T-0252: a run without a runtime contract
# ==========================================================================
#
# A catalogue with one API-format export and one editor-format workflow: the
# editor workflow is what makes a run establish a ComfyUI identity, and with it
# a contract -- which the API export is then analysed with.  A run with no
# ComfyUI to ask (``-NoConvert``, or a ComfyUI that cannot be reached) analyses
# the same export with no contract and generates less.

#: What the stand-in ComfyUI declares for the sampler in ``scene_graph``.
DECLARED_STEPS = {"min": 1, "max": 200, "step": 1}
DECLARED_CFG = {"min": 0.0, "max": 30.0, "step": 0.5}
OBJECT_INFO = {
    "SceneSampler": {
        "input": {
            "required": {
                "steps": ["INT", dict(DECLARED_STEPS)],
                "cfg": ["FLOAT", dict(DECLARED_CFG)],
            }
        },
        "output": [],
        "name": "SceneSampler",
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
            status=ConversionStatus.CONVERTED, document=scene_graph(steps=31)
        )


class UnreachableComfy:
    """A ComfyUI that is not running: the identity probe fails."""

    def ensure_identity(self):
        raise BridgeError(CATEGORY_COMFY_UNREACHABLE, "connection refused")

    def runtime_contract(self):
        return None

    def convert(self, raw, *, content_hash):  # pragma: no cover - never reached
        raise AssertionError("a run that has no identity converts nothing")


def mixed_sync(workspace: SyncWorkspace, now: datetime, bridge):
    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "api.json", scene_graph())
    write_json(folder / "canvas.json", UI_GRAPH)
    workspace.write_config()
    return run_sync(workspace.load(), now=now, bridge=bridge)


def api_item(report):
    found = [
        item for item in report.workflows
        if item.candidate is not None and item.candidate.relative == "api.json"
    ]
    assert len(found) == 1, [item.id for item in report.workflows]
    return found[0]


def api_definition(workspace: SyncWorkspace) -> Path:
    return workspace.repo / "config" / "local" / "workflows" / "api.yaml"


def api_entry(workspace: SyncWorkspace) -> Dict[str, Any]:
    found = [e for e in workspace.read_inventory()["workflows"] if e["id"] == "api"]
    assert len(found) == 1
    return found[0]


RECORD_KEYS = (
    "generated_fingerprint", "generated_with_contract", "generated_labels",
    "generated_help",
)


def record_of(workspace: SyncWorkspace) -> Dict[str, Any]:
    entry_now = api_entry(workspace)
    return {key: entry_now[key] for key in RECORD_KEYS}


def limits(path: Path, field_id: str) -> Dict[str, Any]:
    found = field(path, field_id)
    return {key: found.get(key) for key in ("min", "max", "step")}


def test_the_stand_in_comfyui_really_declares_the_limits_a_run_without_it_lacks(
    workspace: SyncWorkspace,
) -> None:
    """The lever: with the contract the export carries limits, without none."""

    with_contract = mixed_sync(workspace, T1, ComfyWithAContract())
    item = api_item(with_contract)
    assert item.definition.written is True
    assert limits(api_definition(workspace), "steps") == DECLARED_STEPS
    assert limits(api_definition(workspace), "cfg") == DECLARED_CFG
    assert api_entry(workspace)["generated_with_contract"] is True

    other = SyncWorkspace(workspace.base.parent / "never a contract")
    without = mixed_sync(other, T1, None)
    assert api_item(without).definition.written is True
    assert limits(api_definition(other), "steps") == {"min": None, "max": None, "step": None}
    assert api_entry(other)["generated_with_contract"] is False


@pytest.mark.parametrize(
    "no_contract",
    [pytest.param(lambda: None, id="no-convert"),
     pytest.param(UnreachableComfy, id="comfyui-unreachable")],
)
def test_a_run_without_a_contract_keeps_an_unchanged_definition_made_with_one(
    workspace: SyncWorkspace, no_contract
) -> None:
    """T-0252 itself: the limits survive, byte for byte, and so does the record.

    The run without a contract really does generate less -- its plan for the
    export has no limit on ``steps`` -- so the file surviving is this rule's
    doing and not an absence of anything to write.
    """

    mixed_sync(workspace, T1, ComfyWithAContract())
    definition = api_definition(workspace)
    before = definition.read_bytes()
    stamp = age(definition)
    record_before = record_of(workspace)
    assert record_before["generated_with_contract"] is True

    report = mixed_sync(workspace, T2, no_contract())

    item = api_item(report)
    assert item.state is WorkflowState.UNCHANGED
    planned = {planned.id: planned for planned in item.plan.fields}
    assert planned["steps"].maximum is None, "this run was not without a contract"
    assert item.definition.written is False
    assert item.definition.skipped == NO_CONTRACT_KEPT_NOTICE
    assert definition.read_bytes() == before
    assert definition.stat().st_mtime_ns == stamp
    assert limits(definition, "steps") == DECLARED_STEPS
    assert record_of(workspace) == record_before
    assert report.definitions_written == 0
    said = report_document(report)["workflows"]
    assert [w["definition"]["skipped"] for w in said if w["id"] == "api"] == [
        NO_CONTRACT_KEPT_NOTICE
    ]

    # ComfyUI back: the record is intact, so the fingerprint is equal again.
    back = mixed_sync(workspace, T3, ComfyWithAContract())
    assert api_item(back).definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before


def test_a_dry_run_without_a_contract_would_not_write_it_either(
    workspace: SyncWorkspace,
) -> None:
    mixed_sync(workspace, T1, ComfyWithAContract())
    report = run_sync(workspace.load(), now=T2, dry_run=True)
    item = api_item(report)
    assert item.definition.would_write is False
    assert item.definition.skipped == NO_CONTRACT_KEPT_NOTICE
    assert "0 definitions would be written" in summary_line(report)


def test_with_a_contract_an_importer_change_still_rewrites_a_definition_made_with_one(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Contract now: compare as before -- the rule does not freeze anything."""

    mixed_sync(workspace, T1, ComfyWithAContract())
    change_the_importer(monkeypatch)

    report = mixed_sync(workspace, T2, ComfyWithAContract())
    item = api_item(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    assert field(api_definition(workspace), "steps")["max"] == NEW_MAXIMUM
    assert api_entry(workspace)["generated_with_contract"] is True


def test_neither_run_with_a_contract_compares_as_before(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Both without: an importer change still reaches the definition."""

    mixed_sync(workspace, T1, None)
    assert api_entry(workspace)["generated_with_contract"] is False
    change_the_importer(monkeypatch)

    report = mixed_sync(workspace, T2, None)
    item = api_item(report)
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    assert field(api_definition(workspace), "steps")["max"] == NEW_MAXIMUM
    assert api_entry(workspace)["generated_with_contract"] is False


def test_a_definition_made_without_a_contract_is_written_again_once_there_is_one(
    workspace: SyncWorkspace,
) -> None:
    """No contract recorded, contract now: the better evidence is written."""

    mixed_sync(workspace, T1, None)
    definition = api_definition(workspace)
    assert limits(definition, "steps") == {"min": None, "max": None, "step": None}

    report = mixed_sync(workspace, T2, ComfyWithAContract())
    item = api_item(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True
    assert item.definition.rewritten == REWRITTEN_NOTICE
    assert limits(definition, "steps") == DECLARED_STEPS
    assert api_entry(workspace)["generated_with_contract"] is True


def test_an_inventory_from_before_the_contract_record_is_kept_by_a_run_that_lacks_one(
    workspace: SyncWorkspace,
) -> None:
    """No record either way, and a run that would normally have had a contract.

    The catalogue holds an editor-format workflow, so a missing contract means
    ComfyUI was not there -- and the definition on disk may carry what it
    declared.  Kept, and said so.  The same inventory in an API-only catalogue
    compares as usual: ``test_with_no_fingerprint_a_definition_the_importer_now_reads_differently_is_written_once``.
    """

    mixed_sync(workspace, T1, ComfyWithAContract())
    forget_the_fingerprint(workspace)
    definition = api_definition(workspace)
    before = definition.read_bytes()

    report = mixed_sync(workspace, T2, None)
    item = api_item(report)
    assert item.definition.written is False
    assert item.definition.skipped == NO_CONTRACT_MAYBE_KEPT_NOTICE
    assert definition.read_bytes() == before
    assert api_entry(workspace)["generated_fingerprint"] is None
    assert api_entry(workspace)["generated_with_contract"] is None

    # And the first run with the contract settles it.
    settled = mixed_sync(workspace, T3, ComfyWithAContract())
    assert api_item(settled).definition.written is False
    assert api_item(settled).definition.skipped == KEPT_NOTICE
    assert definition.read_bytes() == before
    assert api_entry(workspace)["generated_with_contract"] is True
