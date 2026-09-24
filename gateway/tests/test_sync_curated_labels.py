"""A label somebody wrote, and a label nobody touched (T-0110).

``read_curated`` already kept a definition's ``name``, its ``presentation`` and
its ``translation``.  It did not keep the ``label`` of a field, so a sync
overwrote hand-written labels while keeping the prose that named them, and the
file ended up contradicting itself.

The rule this file holds is not "what is in the file wins", because a generated
definition writes a label for **every** field and presence would therefore
prove nothing.  It is:

    file label == the label this importer generated last time  ->  refresh it
    file label != that label                                   ->  keep it
    nothing remembered at all                                  ->  keep it

so both halves have to be true at once, and the second one is the half the two
simpler rules fail:

* **a hand-written label survives** a sync that genuinely rewrites the file --
  ``bind`` moved, ``default`` changed, and the label still says what a person
  typed;
* **an untouched label is refreshed when the generator's output changes**,
  proved by *changing what the generator produces* and watching the definition
  follow.  A rule that took "present in the file" or "differs from what we
  would generate now" as curation freezes it here instead;
* the two happen **in one file in one run**: the curated field keeps its words
  while the field beside it follows the generator;
* **with no record the file wins**, so a run after the inventory is deleted
  destroys nothing -- shown against a control run that kept the inventory and
  did refresh;
* a record value that is not a label is **dropped and never coerced**, proved
  on the collision that makes the difference: the curator's own label is the
  text the coercion would have produced;
* the record follows **the file** and not the run, by both doors -- a sync that
  skipped a definition, and a sync whose write was refused -- because a record
  advanced past a file nobody wrote freezes every label in it for good;
* a curated label for a field that no longer exists resurrects nothing and
  stops nothing;
* the record itself never reaches the definition, and adding it changed
  ``name``, ``presentation`` and ``translation`` in no way at all -- a
  differential between the two code paths, not an assertion about one;
* two runs over the same bytes still produce byte-identical YAML.

Every graph here is built in this file, out of node types that exist nowhere
else.  Nothing depends on a real ComfyUI, a real model or a real node pack, and
no model, family or vendor is named.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional

import pytest
import yaml

from localcanvas_gateway.workflows import load_registry
from localcanvas_gateway.workflows.sync import (
    WorkflowState,
    analyse,
    analysis as analysis_module,
    definitions as definitions_module,
    describe,
    run_sync,
)
from sync_fixtures import SyncWorkspace, write_json

FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


# ==========================================================================
# The graph, and the two ways of changing it
# ==========================================================================


def picture_graph(*, steps: int = 24) -> Dict[str, Any]:
    """One ordinary generation: two prompts, a canvas, a sampler, a save."""

    return {
        "1": {
            "class_type": "ExampleWeightsLoader",
            "inputs": {"ckpt_name": "chosen-weights.safetensors"},
        },
        "2": {
            "class_type": "ExampleEmptyCanvas",
            "inputs": {"width": 768, "height": 512, "batch_size": 1},
        },
        "3": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "a quiet street at dawn", "clip": ["1", 1]},
        },
        "4": {
            "class_type": "ExampleTextEncode",
            "inputs": {"text": "blurry, low quality", "clip": ["1", 1]},
        },
        "5": {
            "class_type": "ExampleSampler",
            "inputs": {
                "seed": 12345,
                "steps": steps,
                "cfg": 6.5,
                "denoise": 1.0,
                "model": ["1", 0],
                "positive": ["3", 0],
                "negative": ["4", 0],
                "latent_image": ["2", 0],
            },
        },
        "6": {
            "class_type": "ExampleDecode",
            "inputs": {"samples": ["5", 0], "vae": ["1", 2]},
        },
        "7": {"class_type": "ExampleSaveImage", "inputs": {"images": ["6", 0]}},
    }


def renumbered(graph: Dict[str, Any], offset: int = 700) -> Dict[str, Any]:
    """The same graph with every node id moved, and every wire moved with it.

    Used so that "the definition really was rewritten" is a fact about
    ``bind``, which cannot survive a renumbering, rather than a claim.
    """

    mapping = {node: str(int(node) + offset) for node in graph}
    moved: Dict[str, Any] = {}
    for node, body in graph.items():
        inputs: Dict[str, Any] = {}
        for name, value in body["inputs"].items():
            if isinstance(value, list) and len(value) == 2 and value[0] in mapping:
                inputs[name] = [mapping[value[0]], value[1]]
            else:
                inputs[name] = value
        moved[mapping[node]] = {"class_type": body["class_type"], "inputs": inputs}
    return moved


#: What the generator produces for this graph today, verbatim.  Asserted rather
#: than derived: a test that computed the expected label from the code under
#: test would pass whatever that code decided.
GENERATED = {
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

#: What a person might type over one of them.  No generator produces either.
BY_HAND_PROMPT = "Say what you want to see"
BY_HAND_NEGATIVE = "Things to leave out"


# ==========================================================================
# Helpers
# ==========================================================================


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def sync_once(
    workspace: SyncWorkspace,
    graph: Dict[str, Any],
    *,
    name: str = "one",
    sync: Optional[Mapping[str, bool]] = None,
):
    """Write the graph into the source folder and run one whole sync."""

    folder = workspace.sources[0] if workspace.sources else workspace.add_source()
    write_json(folder / "{}.json".format(name), graph)
    workspace.write_config(sync=sync)
    return run_sync(workspace.load(), now=FIXED)


def definition_path(workspace: SyncWorkspace, workflow_id: str = "one") -> Path:
    return workspace.repo / "config" / "local" / "workflows" / "{}.yaml".format(
        workflow_id
    )


def labels_in(path: Path) -> Dict[str, str]:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    return {item["id"]: item["label"] for item in document["inputs"]}


def field_in(path: Path, field_id: str) -> Dict[str, Any]:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    found = [item for item in document["inputs"] if item["id"] == field_id]
    assert found, "no field {!r}; there are {}".format(
        field_id, [item["id"] for item in document["inputs"]]
    )
    return found[0]


def rewrite_labels(path: Path, replacements: Mapping[str, str]) -> None:
    """Edit the labels of an existing definition, as a curator would.

    The file is loaded and dumped, so what comes back is a definition somebody
    edited and not one this test composed: every other key keeps the value the
    sync wrote.
    """

    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    unknown = set(replacements) - {item["id"] for item in document["inputs"]}
    assert not unknown, "nothing to edit: {}".format(sorted(unknown))
    for item in document["inputs"]:
        if item["id"] in replacements:
            item["label"] = replacements[item["id"]]
    path.write_text(
        yaml.safe_dump(document, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )


def remembered_labels(workspace: SyncWorkspace, workflow_id: str = "one") -> Dict[str, str]:
    entries = workspace.read_inventory()["workflows"]
    found = [entry for entry in entries if entry["id"] == workflow_id]
    assert found, [entry["id"] for entry in entries]
    return found[0]["generated_labels"]


def change_what_the_generator_produces(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make ``analysis.py`` produce different labels, without editing it.

    This is the whole point of the card: an improvement to the generator has to
    reach a catalogue that already exists.  A test that only asserts the
    current text can never show that, so the generator is genuinely changed
    here and the definition has to follow it.
    """

    original = analysis_module._label
    monkeypatch.setattr(
        analysis_module, "_label", lambda role: "Control for " + original(role).lower()
    )


def moved_on(labels: Mapping[str, str]) -> Dict[str, str]:
    """The same fields, labelled the way the changed generator labels them."""

    return {
        field_id: "Control for " + label.lower() for field_id, label in labels.items()
    }


def only_workflow(report):
    assert len(report.workflows) == 1, [item.state for item in report.workflows]
    return report.workflows[0]


# ==========================================================================
# The generator, before anything is preserved
# ==========================================================================


def test_the_fixture_labels_are_what_this_importer_generates() -> None:
    """The table above is measured, so every later assertion means something.

    Without this, a test that says "the label is still 'Prompt'" could be
    satisfied by a fixture that never produced anything else.
    """

    plan = analyse(picture_graph())
    assert not plan.problems, plan.problems
    assert {item.id: item.label for item in plan.fields} == GENERATED


def test_the_changed_generator_really_produces_different_labels(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The lever the refresh tests pull, proved to move before it is used.

    An "it was refreshed" test is worthless if the generator's output never
    changed: the old text and the new one would be the same string.
    """

    change_what_the_generator_produces(monkeypatch)
    plan = analyse(picture_graph())
    produced = {item.id: item.label for item in plan.fields}

    assert produced == moved_on(GENERATED)
    assert produced["prompt"] == "Control for prompt"
    for field_id, label in GENERATED.items():
        assert produced[field_id] != label, field_id


# ==========================================================================
# A label somebody wrote
# ==========================================================================


def test_a_hand_written_label_survives_a_sync_that_rewrites_the_definition(
    workspace: SyncWorkspace,
) -> None:
    """The defect itself.  The file is really rewritten, and the words stay.

    ``bind`` and ``default`` are asserted as well, because "the label survived"
    would also be true of a run that wrote nothing at all -- and a run that
    wrote nothing is a different bug, not this fix.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)
    assert labels_in(definition) == GENERATED
    assert field_in(definition, "steps")["default"] == 24
    assert field_in(definition, "prompt")["bind"] == [{"node": "3", "input": "text"}]

    rewrite_labels(
        definition,
        {"prompt": BY_HAND_PROMPT, "negative_prompt": BY_HAND_NEGATIVE},
    )

    report = sync_once(workspace, renumbered(picture_graph(steps=40)))

    assert only_workflow(report).definition.written is True
    after = labels_in(definition)
    assert after["prompt"] == BY_HAND_PROMPT
    assert after["negative_prompt"] == BY_HAND_NEGATIVE
    assert after["seed"] == "Seed", "a label nobody touched was not regenerated"
    assert after["steps"] == "Steps"

    # The file really was rewritten from the new graph, so the two labels above
    # survived a regeneration rather than an absence of one.
    assert field_in(definition, "steps")["default"] == 40
    assert field_in(definition, "prompt")["bind"] == [{"node": "703", "input": "text"}]

    registry = load_registry(definition.parent)
    assert registry.diagnostics == ()
    fields = {item.id: item.label for item in registry.workflows[0].inputs}
    assert fields["prompt"] == BY_HAND_PROMPT


# ==========================================================================
# A label nobody touched -- the half both rejected rules fail
# ==========================================================================


def test_an_untouched_label_is_refreshed_when_the_generator_changes(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Change what the generator produces, and the definition has to follow.

    This is the criterion the card turns on, and it kills both rejected rules
    at once.  "Present in the file is curated" freezes every one of these
    labels for ever, because a generated definition always writes one.
    "Differs from what we would generate now is curated" freezes them the
    moment the generator changes -- which is exactly the moment under test.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)
    assert labels_in(definition) == GENERATED
    assert remembered_labels(workspace) == GENERATED

    change_what_the_generator_produces(monkeypatch)
    report = sync_once(workspace, picture_graph(steps=40))

    assert only_workflow(report).definition.written is True
    assert labels_in(definition) == moved_on(GENERATED)
    assert labels_in(definition)["prompt"] == "Control for prompt"
    assert remembered_labels(workspace) == moved_on(GENERATED)


def test_one_curated_label_and_one_untouched_go_opposite_ways_in_one_run(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The decision is per field, in one file, in one sync.

    Both halves in a single run, so neither a rule that keeps everything nor a
    rule that keeps nothing can pass this: the curated field must not move and
    the field beside it must.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)
    rewrite_labels(definition, {"prompt": BY_HAND_PROMPT})

    change_what_the_generator_produces(monkeypatch)
    sync_once(workspace, picture_graph(steps=40))

    after = labels_in(definition)
    assert after["prompt"] == BY_HAND_PROMPT
    assert after["negative_prompt"] == "Control for negative prompt"
    assert after["steps"] == "Control for steps"

    # And what is remembered is what the *generator* produced, never what was
    # written: remembering the curator's own words would hand them back to the
    # generator on the very next run.
    assert remembered_labels(workspace)["prompt"] == "Control for prompt"


def test_the_record_follows_the_file_and_not_the_run(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The record describes the file on disk, whichever run put it there.

    Before T-0246 an unchanged workflow kept its definition whatever this run
    would have generated, and this test held that such a skip left the record
    alone.  T-0246 reverses the premise: the same bytes with a changed generator
    now write the definition again.  What must still be true is the invariant
    underneath -- the record moves with the file and never ahead of or behind
    it -- so both halves are asserted on the rewrite: the file refreshed *and*
    the record with it.  The door where a write does not happen is held by
    ``test_a_write_that_failed_does_not_move_the_record_past_the_file``.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)
    before = definition.read_bytes()

    change_what_the_generator_produces(monkeypatch)

    # The same bytes again: UNCHANGED, and written again because the
    # generator now produces other labels.
    report = sync_once(workspace, picture_graph())
    item = only_workflow(report)
    assert item.state is WorkflowState.UNCHANGED
    assert item.definition.written is True
    assert definition.read_bytes() != before
    assert labels_in(definition) == moved_on(GENERATED)
    assert remembered_labels(workspace) == moved_on(GENERATED), (
        "the record did not follow the file it describes"
    )

    # Now the workflow really changes, and the untouched labels must still
    # refresh -- which they cannot if the run above overwrote the record.
    sync_once(workspace, picture_graph(steps=40))
    assert labels_in(definition) == moved_on(GENERATED)


# ==========================================================================
# No record at all
# ==========================================================================


def test_a_write_that_failed_does_not_move_the_record_past_the_file(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The other door into the freeze, and the one nothing was watching.

    A definition that could not be written -- a full disk, a permission, the
    file held open by an editor -- leaves the previous one on disk untouched.
    If the record advanced anyway, it would describe a file that does not
    exist: every field would read ``file != record`` from then on, every label
    would be curated, and no later improvement to the generator would ever
    reach that definition again.  The run reports the failed write; it would
    report nothing at all about the record, so the damage is silent and
    permanent.

    The skipped-definition case is a different path -- an UNCHANGED workflow
    never enters the loop that writes -- so it cannot stand in for this one.
    The third case the code names, a dry run, is unreachable and is left
    untested on purpose: a dry run returns before this point and ``run_sync``
    writes no inventory for one at all.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)
    intact = definition.read_bytes()
    assert labels_in(definition) == GENERATED

    change_what_the_generator_produces(monkeypatch)

    def refuse_the_definition(source: str, target: str) -> None:
        if str(target).endswith(".yaml"):
            raise OSError(13, "Permission denied")
        os.replace(source, target)

    with monkeypatch.context() as failing:
        # The atomic swap itself, which the module binds as an attribute so a
        # test can substitute it.  Failing here is a write that genuinely did
        # not happen, not a report of one.
        failing.setattr(definitions_module, "_replace", refuse_the_definition)
        report = sync_once(workspace, picture_graph(steps=40))

    item = only_workflow(report)
    assert item.definition.written is False
    assert item.definition.problem is not None
    assert item.state is WorkflowState.NEEDS_REVIEW
    assert definition.read_bytes() == intact, "the write was not actually refused"

    # The file still holds the labels of the run that last wrote it, so the
    # record must still hold them too.
    assert remembered_labels(workspace) == GENERATED, (
        "the record moved past a file this run never wrote"
    )

    # And the proof that it matters: the next run that does write must still be
    # able to refresh those labels.
    report = sync_once(workspace, picture_graph(steps=50))
    assert only_workflow(report).definition.written is True
    assert labels_in(definition) == moved_on(GENERATED)


def test_with_no_record_every_label_in_the_file_is_preserved(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Deleting the inventory forces a re-import.  It must destroy nothing.

    Two workspaces, the same scenario in both, differing in one act: one of
    them loses its inventory.  Without the control run this would prove only
    that something was preserved; with it, the deletion is shown to be the
    cause, because the run that kept its inventory refreshed the same label in
    the same sync.
    """

    kept = SyncWorkspace(tmp_path / "with the record")
    lost = SyncWorkspace(tmp_path / "without the record")

    for workspace in (kept, lost):
        sync_once(workspace, picture_graph())
        rewrite_labels(definition_path(workspace), {"prompt": BY_HAND_PROMPT})
        assert remembered_labels(workspace) == GENERATED

    lost.inventory_path.unlink()
    assert not lost.inventory_path.exists()

    change_what_the_generator_produces(monkeypatch)
    for workspace in (kept, lost):
        sync_once(workspace, picture_graph(steps=40))

    # The control: with the record, an untouched label followed the generator.
    assert labels_in(definition_path(kept))["negative_prompt"] == (
        "Control for negative prompt"
    )

    # And with no record, nothing in the file was overwritten -- not the words
    # a person wrote, and not a label this run cannot prove was its own.
    without = labels_in(definition_path(lost))
    assert without["prompt"] == BY_HAND_PROMPT
    assert without["negative_prompt"] == "Negative prompt"
    assert without == dict(GENERATED, prompt=BY_HAND_PROMPT)


def test_a_label_preserved_with_no_record_stays_until_the_definition_is_deleted(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The price of preserving on no record, and the way out of it.

    The generator changes, and only then does the inventory go.  The run that
    follows cannot prove the labels in the file were its own, so it keeps them
    -- and from then on they differ from what it has recorded, so they read as
    curated for good.  That is the documented consequence of choosing the safe
    error, and the documented remedy is deleting the definition, which the
    generated header already says discards a curator's edits.  Both halves are
    here, because a rule nothing can fail on is not a rule.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)
    assert labels_in(definition) == GENERATED

    change_what_the_generator_produces(monkeypatch)
    workspace.inventory_path.unlink()

    # Nothing proves these labels were ours, so every one of them is kept.
    sync_once(workspace, picture_graph(steps=40))
    assert labels_in(definition) == GENERATED
    assert remembered_labels(workspace) == moved_on(GENERATED)

    # And they go on being kept, because they no longer match the record.
    sync_once(workspace, picture_graph(steps=50))
    assert labels_in(definition) == GENERATED

    # The way back is the one the file's own header describes.
    definition.unlink()
    report = sync_once(workspace, picture_graph(steps=60))
    assert only_workflow(report).definition.written is True
    assert labels_in(definition) == moved_on(GENERATED)


def test_the_record_is_not_a_note_the_user_wrote_and_does_not_depend_on_that_switch(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """``preserve_manual_metadata`` is about the user's own keys, not ours.

    What keeps the record is the unconditional write in ``_entry_for``, and
    that is the guard this test kills: gate that one line on the switch and
    every label in every definition freezes as soon as somebody turns it off,
    with the switch's name as the only clue.

    Listing the key in ``KNOWN_ENTRY_KEYS`` is belt and braces and **not** the
    protection, so this test does not claim it is.  ``inventory._entry`` reads
    the field explicitly whatever that tuple holds, and ``to_document`` starts
    from ``extra`` and then overwrites the known keys, so the explicit value
    wins either way; membership only keeps the record out of ``extra``, where
    it would read as one of the user's own keys.
    """

    sync_once(workspace, picture_graph(), sync={"preserve_manual_metadata": False})
    definition = definition_path(workspace)
    assert remembered_labels(workspace) == GENERATED

    rewrite_labels(definition, {"prompt": BY_HAND_PROMPT})
    change_what_the_generator_produces(monkeypatch)
    sync_once(
        workspace, picture_graph(steps=40), sync={"preserve_manual_metadata": False}
    )

    after = labels_in(definition)
    assert after["prompt"] == BY_HAND_PROMPT
    assert after["negative_prompt"] == "Control for negative prompt"


def test_an_inventory_written_before_this_record_existed_is_still_the_inventory(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An added key is not a version bump, and this is why it must not be one.

    An inventory the reader refuses is an inventory treated as empty: every
    workflow new, every id reallocated, every ``first_seen`` gone.  So an entry
    written before the record existed has to go on being read -- keeping its id
    and its history -- while the absent record means what an absent record
    always means, and the labels in the file are preserved.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)

    document = json.loads(workspace.inventory_path.read_text(encoding="utf-8"))
    entry = document["workflows"][0]
    del entry["generated_labels"]
    first_seen = entry["first_seen"]
    workspace.inventory_path.write_text(json.dumps(document), encoding="utf-8")

    change_what_the_generator_produces(monkeypatch)
    report = sync_once(workspace, picture_graph(steps=40))

    item = only_workflow(report)
    assert item.state is WorkflowState.CHANGED, (
        "the old inventory was thrown away rather than read"
    )
    assert item.id == "one"
    after = workspace.read_inventory()["workflows"][0]
    assert after["first_seen"] == first_seen
    assert labels_in(definition) == GENERATED


def test_an_unreadable_record_is_no_record_rather_than_a_wrong_one(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A record that is not ``{field id: label}`` is not half-believed.

    Hand-edited, half-written, or written by something else: whatever it is, a
    value that is not a label cannot show that a label was ours, so the file
    keeps what it says.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)

    document = json.loads(workspace.inventory_path.read_text(encoding="utf-8"))
    document["workflows"][0]["generated_labels"] = {
        "prompt": 24,
        "negative_prompt": "Negative prompt",
    }
    workspace.inventory_path.write_text(json.dumps(document), encoding="utf-8")

    change_what_the_generator_produces(monkeypatch)
    sync_once(workspace, picture_graph(steps=40))

    after = labels_in(definition)
    assert after["prompt"] == "Prompt", "a record that is not a label was believed"
    assert after["negative_prompt"] == "Control for negative prompt", (
        "the readable half of the record was thrown away with the unreadable half"
    )


def test_a_record_that_is_not_a_label_is_dropped_and_never_coerced(
    workspace: SyncWorkspace,
) -> None:
    """The collision the drop exists to prevent, built so that it can happen.

    Dropping a value only *matters* where coercing it would have changed the
    answer, and that needs the coerced text to be exactly what the file says.
    So the curator here names a field after the number they always use -- a
    label of ``40`` -- while the record for that field holds the integer
    ``40``.  ``str(40)`` is ``'40'``: coerce, and the record appears to say
    "we wrote that", and their word is handed back to the generator.

    A record whose value is a number cannot have come from this importer, which
    only ever records the string it generated, so the only reading that is
    ever right is "no record for this field".
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)
    rewrite_labels(definition, {"steps": "40"})

    document = json.loads(workspace.inventory_path.read_text(encoding="utf-8"))
    stored = document["workflows"][0]["generated_labels"]
    stored["steps"] = 40
    assert str(stored["steps"]) == labels_in(definition)["steps"], (
        "the coerced record would not have collided, so nothing is under test"
    )
    workspace.inventory_path.write_text(json.dumps(document), encoding="utf-8")

    report = sync_once(workspace, picture_graph(steps=40))

    # The file really was rewritten, so the label below survived a
    # regeneration rather than an absence of one.
    assert only_workflow(report).definition.written is True
    assert field_in(definition, "steps")["default"] == 40

    assert labels_in(definition)["steps"] == "40", (
        "a number in the record was read as the label we last generated"
    )
    assert labels_in(definition)["seed"] == "Seed"


# ==========================================================================
# A label whose field is gone
# ==========================================================================


def test_a_curated_label_for_a_field_that_is_gone_changes_nothing(
    workspace: SyncWorkspace,
) -> None:
    """It does not come back, and it does not stop the import.

    T-0100 locks inputs that must never be exposed, so a label left behind by a
    field that no longer exists is the ordinary case rather than an odd one.
    """

    sync_once(workspace, picture_graph())
    definition = definition_path(workspace)

    document = yaml.safe_load(definition.read_text(encoding="utf-8"))
    document["inputs"].append(
        {
            "id": "a_field_that_went_away",
            "label": "Something I named once",
            "type": "integer",
            "section": "advanced",
            "bind": [{"node": "5", "input": "gone"}],
        }
    )
    for item in document["inputs"]:
        if item["id"] == "prompt":
            item["label"] = BY_HAND_PROMPT
    definition.write_text(
        yaml.safe_dump(document, sort_keys=False, allow_unicode=True), encoding="utf-8"
    )

    report = sync_once(workspace, picture_graph(steps=40))

    item = only_workflow(report)
    assert item.definition.problem is None
    assert item.definition.written is True
    after = labels_in(definition)
    assert "a_field_that_went_away" not in after
    assert after["prompt"] == BY_HAND_PROMPT
    assert set(after) == set(GENERATED)
    assert "Something I named once" not in definition.read_text(encoding="utf-8")

    registry = load_registry(definition.parent)
    assert registry.diagnostics == ()


# ==========================================================================
# The record is state, and stays out of the file
# ==========================================================================


#: Every key any field of this fixture's definition carries.  Verbatim, so a
#: key that appeared from anywhere -- the record included -- fails here.
FIXTURE_FIELD_KEYS = {
    "id",
    "label",
    "type",
    "required",
    "section",
    "default",
    # Written by the importer since T-0131, on every field whose graph input
    # name the vocabulary knows.  It belongs in this set for the same reason
    # every other key does -- it is a key of the schema, generated -- and the
    # record it is regenerated from, ``generated_help``, is state and must no
    # more appear in a definition than ``generated_labels`` may.
    "help",
    "translatable",
    "pair",
    "role",
    "bind",
}


def test_the_remembered_record_never_reaches_the_definition(
    workspace: SyncWorkspace,
) -> None:
    """An absence, after showing there was something present to leak.

    Two halves, because the schema rejects every key it does not know: a record
    written *into* the definition would be refused by the loader and nothing
    would be written at all, so "the text does not contain it" would be true of
    a run that failed.  The written flag is therefore asserted first, and the
    record is shown to be non-empty in the inventory -- without that, this
    would pass just as well against a run that remembered nothing.
    """

    sync_once(workspace, picture_graph())
    rewrite_labels(definition_path(workspace), {"prompt": BY_HAND_PROMPT})
    report = sync_once(workspace, picture_graph(steps=40))

    item = only_workflow(report)
    assert item.definition.problem is None
    assert item.definition.written is True

    definition = definition_path(workspace)
    stored = remembered_labels(workspace)
    assert stored == GENERATED, "there was no record for the definition to leak"

    text = definition.read_text(encoding="utf-8")
    assert "generated_labels" not in text
    document = yaml.safe_load(text)
    assert list(document) == ["id", "name", "workflow", "presentation", "inputs"]
    for entry in document["inputs"]:
        assert set(entry) <= FIXTURE_FIELD_KEYS, sorted(
            set(entry) - FIXTURE_FIELD_KEYS
        )


def test_the_record_changes_the_label_and_nothing_else_in_the_document() -> None:
    """A differential between the two code paths, not a claim about one.

    The same plan, the same curated file and the same prose are rendered twice:
    once the way the document was built before this record existed
    (``remembered_labels`` absent), once with it.  ``name``, ``presentation``,
    ``translation``, and every part of ``inputs`` except the label must come
    out identical -- and the labels must differ, or the comparison is vacuous.
    """

    plan = analyse(picture_graph())
    catalog = describe(plan, picture_graph())
    curated = definitions_module.CuratedDefinition(
        document={
            "name": "Evening portraits",
            "presentation": {"badge": "EVENING", "group": "My own shelf"},
            "inputs": [
                # One the curator wrote, one an older generator wrote.
                {"id": "prompt", "label": BY_HAND_PROMPT},
                {"id": "seed", "label": "Random seed"},
            ],
            "translation": {"mode": "off"},
        }
    )
    #: What that older generator recorded: 'Random seed' was its own work, and
    #: 'Prompt' is what it wrote where the curator has since typed their own.
    record = dict(GENERATED, seed="Random seed")

    def build(remembered: Optional[Mapping[str, str]]) -> Dict[str, Any]:
        return definitions_module.definition_document(
            plan,
            workflow_id="one",
            name="One",
            workflow_relative="g.json",
            presentation=catalog.presentation,
            curated=curated,
            remembered_labels=remembered,
        )

    without = build(None)
    with_record = build(record)

    def unlabelled(document: Dict[str, Any]) -> Dict[str, Any]:
        copy = dict(document)
        copy["inputs"] = [
            {key: value for key, value in item.items() if key != "label"}
            for item in document["inputs"]
        ]
        return copy

    assert unlabelled(without) == unlabelled(with_record)
    assert list(without) == list(with_record), "the key order moved"
    assert without["name"] == with_record["name"] == "Evening portraits"
    assert without["presentation"] == with_record["presentation"]
    assert without["translation"] == with_record["translation"] == {"mode": "off"}

    # Not vacuous: the two do differ, and only in a label.  With no record the
    # file's 'Random seed' is preserved because nothing proves it was ours;
    # with the record it matches what we wrote last time and refreshes.
    labels_without = {item["id"]: item["label"] for item in without["inputs"]}
    labels_with = {item["id"]: item["label"] for item in with_record["inputs"]}
    assert labels_without != labels_with
    assert labels_without["seed"] == "Random seed"
    assert labels_with["seed"] == "Seed"
    assert labels_without["prompt"] == labels_with["prompt"] == BY_HAND_PROMPT


# ==========================================================================
# Determinism
# ==========================================================================


def test_the_record_adds_no_churn_to_the_yaml_or_to_the_inventory(
    tmp_path: Path,
) -> None:
    """The same scenario twice, in two workspaces, byte for byte.

    ``_definition_document`` promises that two runs over the same bytes produce
    identical YAML.  A record read back as a mapping is exactly the sort of
    thing that can reorder ``inputs`` between runs, so the whole scenario --
    generate, curate, regenerate -- is played out twice and compared as bytes,
    and the stored record is compared as *text* so that a different key order
    fails rather than compares equal.
    """

    produced: List[bytes] = []
    stored: List[str] = []
    for name in ("first time", "second time"):
        workspace = SyncWorkspace(tmp_path / name)
        sync_once(workspace, picture_graph())
        rewrite_labels(definition_path(workspace), {"prompt": BY_HAND_PROMPT})
        sync_once(workspace, renumbered(picture_graph(steps=40)))
        produced.append(definition_path(workspace).read_bytes())
        stored.append(json.dumps(remembered_labels(workspace)))

    assert produced[0] == produced[1]
    assert stored[0] == stored[1]
    assert json.loads(stored[0]) == GENERATED

    # And a third run over the very same bytes leaves the file alone entirely.
    workspace = SyncWorkspace(tmp_path / "third time")
    sync_once(workspace, picture_graph())
    rewrite_labels(definition_path(workspace), {"prompt": BY_HAND_PROMPT})
    sync_once(workspace, renumbered(picture_graph(steps=40)))
    settled = definition_path(workspace).read_bytes()
    sync_once(workspace, renumbered(picture_graph(steps=40)))
    assert definition_path(workspace).read_bytes() == settled
