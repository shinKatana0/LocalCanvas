"""One sync run: classification, identity, the nine states, and what is written.

The properties this file exists to hold, in the order the design states them:

* only the configured folders are read (`test_sync_discovery.py` holds the
  mechanism; the one test here checks it end to end through a real run);
* source bytes are unchanged by a real sync;
* format is decided by content, never by a file name;
* all nine states are produced by tests that construct each situation;
* identity is content: a renamed file with identical bytes is UNCHANGED, and
  two files with the same name in two folders are two workflows;
* REMOVED_FROM_SOURCE deletes nothing;
* exact duplicates collapse to one entry with the others as aliases;
* ordering is deterministic and independent of the filesystem's;
* ``dry_run`` writes nothing;
* one invalid workflow stops nothing, and never replaces a valid inventory;
* the inventory is written atomically;
* nothing opens a socket.
"""

from __future__ import annotations

import json
import os
import socket
from datetime import datetime, timezone
from pathlib import Path

import pytest

from localcanvas_gateway.workflows.sync import (
    SyncConfigError,
    SyncSourceError,
    WorkflowState,
    inventory as inventory_module,
    run_sync,
)
from localcanvas_gateway.workflows.sync.engine import CONVERSION_NOT_OFFERED
from localcanvas_gateway.workflows.sync.errors import InventoryError
from sync_fixtures import (
    API_GRAPH,
    UI_GRAPH,
    SyncWorkspace,
    api_graph,
    states,
    tree_snapshot,
    write_json,
)

#: A fixed moment, so that "the same tree twice" is a statement about ordering
#: rather than about the clock.
FIXED = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def state_of(report, relative: str) -> str:
    return states(report)[relative]


def entry_ids(workspace: SyncWorkspace):
    return [entry["id"] for entry in workspace.read_inventory()["workflows"]]


# ==========================================================================
# Format is decided by content
# ==========================================================================


def test_the_file_name_never_decides_the_format(workspace: SyncWorkspace) -> None:
    """Two files whose names say the opposite of what they hold.

    ``looks like an api export_api.json`` holds the editor's format, and
    ``just a graph.json`` holds the executable one.  A classifier that read the
    name would get both of these backwards.
    """

    folder = workspace.add_source()
    write_json(folder / "looks like an api export_api.json", UI_GRAPH)
    write_json(folder / "just a graph.json", API_GRAPH)
    workspace.write_config()

    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert state_of(report, "looks like an api export_api.json") == "NEEDS_API_EXPORT"
    assert state_of(report, "just a graph.json") == "NEW"


def test_a_ui_export_is_told_exactly_what_to_do_about_it(
    workspace: SyncWorkspace,
) -> None:
    """With no ComfyUI to ask, the standing instruction, and no guess.

    A run given no bridge is a run that cannot convert -- there is nothing to
    convert *with* -- so the answer is the one that was always true: export it
    from ComfyUI yourself. What must never appear is a graph derived from the
    canvas, and ``test_no_converter_is_offered_or_attempted`` below holds that.
    """

    folder = workspace.add_source()
    write_json(folder / "editor save.json", UI_GRAPH)
    workspace.write_config()

    report = run_sync(workspace.load(), dry_run=True, now=FIXED, bridge=None)
    item = report.workflows[0]

    assert item.state is WorkflowState.NEEDS_API_EXPORT
    assert item.reason == CONVERSION_NOT_OFFERED
    assert "Workflow -> Export (API)" in item.reason
    assert "never converts one into the other" in item.reason
    # Nothing was asked of anything, which is not the same as having asked and
    # been refused: those two must not look alike in the report.
    assert item.conversion is None


def test_no_converter_is_offered_or_attempted(workspace: SyncWorkspace) -> None:
    """A UI export leaves the run with nothing derived from it.

    The absence is only worth asserting because the run is one that genuinely
    writes: the API-format file beside it produces an inventory entry, so the
    run had both the means and the opportunity to write something for the UI
    one and did not.
    """

    folder = workspace.add_source()
    write_json(folder / "editor save.json", UI_GRAPH)
    write_json(folder / "usable.json", API_GRAPH)
    workspace.write_config()

    run_sync(workspace.load(), now=FIXED)

    written = workspace.read_inventory()["workflows"]
    assert workspace.inventory_path.exists(), "the run wrote nothing at all"
    assert [entry["id"] for entry in written] == ["editor-save", "usable"]
    editor = written[0]
    assert editor["state"] == "NEEDS_API_EXPORT"
    # Recorded, never converted.  Everything this run wrote belongs to the
    # API-format file beside it -- there is no copy, no definition and no
    # derived file of any kind carrying the editor export's name.
    derived = [
        name
        for name in workspace.output_names()
        if name != workspace.inventory_path.name
    ]
    assert derived, "the run wrote nothing derived at all, so this proves nothing"
    assert all(Path(name).name.startswith("usable") for name in derived), derived


# ==========================================================================
# All nine states
# ==========================================================================


def test_every_one_of_the_nine_states_is_produced(workspace: SyncWorkspace) -> None:
    """Each state is constructed from the situation that means it.

    Written as one test because the states are a partition: seeing them
    together is what shows that a file lands in exactly one of them, and that
    no situation quietly produces two.
    """

    folder = workspace.add_source()
    other = workspace.add_source("a second folder")
    workspace.write_config()

    # First run: something to be UNCHANGED, CHANGED and REMOVED next time.
    write_json(folder / "stays the same.json", api_graph(1))
    write_json(folder / "will be edited.json", api_graph(2))
    write_json(folder / "will be deleted.json", api_graph(3))
    run_sync(workspace.load(), now=FIXED)

    # Second run: every remaining state, constructed.
    (folder / "will be edited.json").write_text(
        json.dumps(api_graph(22)), encoding="utf-8"
    )
    (folder / "will be deleted.json").unlink()
    write_json(folder / "brand new.json", api_graph(4))
    write_json(other / "a copy of brand new.json", api_graph(4))
    write_json(folder / "editor save.json", UI_GRAPH)
    (folder / "not json at all.json").write_text("{ this is not json", encoding="utf-8")
    write_json(folder / "some other document.json", {"theme": "dark", "zoom": 1.5})
    write_json(
        folder / "inputs are a list.json",
        {"1": {"class_type": "ExampleLoader", "inputs": ["a", "b"]}},
    )

    report = run_sync(workspace.load(), now=FIXED)
    seen = states(report)

    assert seen["stays the same.json"] == "UNCHANGED"
    assert seen["will be edited.json"] == "CHANGED"
    assert seen["brand new.json"] == "NEW"
    assert seen["a copy of brand new.json"] == "EXACT_DUPLICATE"
    assert seen["editor save.json"] == "NEEDS_API_EXPORT"
    assert seen["not json at all.json"] == "INVALID"
    assert seen["some other document.json"] == "NEEDS_REVIEW"
    assert seen["inputs are a list.json"] == "UNSUPPORTED_INPUT"
    assert seen["<gone> will-be-deleted"] == "REMOVED_FROM_SOURCE"

    produced = {item.state.value for item in report.workflows}
    assert produced == {state.value for state in WorkflowState}, sorted(produced)


def test_an_unsupported_input_names_the_node_and_what_was_wrong(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(
        folder / "odd.json",
        {"77": {"class_type": "ExampleSampler", "inputs": ["seed", "steps"]}},
    )
    workspace.write_config()

    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert report.workflows[0].state is WorkflowState.UNSUPPORTED_INPUT
    reason = report.workflows[0].reason
    assert "'77'" in reason
    assert "ExampleSampler" in reason
    assert "inputs[<name>]" in reason


def test_a_needs_review_document_says_what_it_could_not_tell(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "half exported.json", {"1": {"inputs": {"a": 1}}})
    workspace.write_config()

    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert report.workflows[0].state is WorkflowState.NEEDS_REVIEW
    assert "class_type" in report.workflows[0].reason


# ==========================================================================
# Identity is content
# ==========================================================================


def test_a_renamed_file_with_the_same_bytes_is_the_same_workflow(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    original = folder / "an old name.json"
    write_json(original, api_graph(5))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    first_id = entry_ids(workspace)[0]

    original.rename(folder / "a completely different name.json")
    report = run_sync(workspace.load(), now=FIXED)

    assert state_of(report, "a completely different name.json") == "UNCHANGED"
    assert entry_ids(workspace) == [first_id]
    entry = workspace.read_inventory()["workflows"][0]
    assert entry["source_relative"] == "a completely different name.json"


def test_the_same_name_in_two_folders_is_two_workflows(
    workspace: SyncWorkspace,
) -> None:
    first = workspace.add_source("first folder")
    second = workspace.add_source("second folder")
    write_json(first / "portrait.json", api_graph(1))
    write_json(second / "portrait.json", api_graph(2))
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    assert [item.state.value for item in report.workflows] == ["NEW", "NEW"]
    identifiers = entry_ids(workspace)
    assert len(identifiers) == 2
    assert len(set(identifiers)) == 2, identifiers
    paths = {entry["source_path"] for entry in workspace.read_inventory()["workflows"]}
    assert paths == {str(first / "portrait.json"), str(second / "portrait.json")}


@pytest.mark.parametrize("renamed_to", ["0 first.json", "z last.json"])
def test_which_file_inherits_the_id_does_not_depend_on_the_names(
    workspace: SyncWorkspace, renamed_to: str
) -> None:
    """Content decides who inherits the id, in both sort orders.

    The situation is one move: the known workflow ``m.json`` is renamed, and
    something else is saved at the name it used to have. Two files, two
    possible claims on one inventory entry -- one by content, one by path.

    Run with a new name that sorts *before* ``m.json`` and again with one that
    sorts *after*, and the answer has to be the same both times. That is the
    assertion, and it is why the parameters exist: a run that resolved each file
    in turn would hand the id to whichever claim it happened to reach first, so
    a plain "a renamed file is UNCHANGED" test passes on it and this one does
    not. The id is what My defaults and Saved setups are keyed on, so inheriting
    it to the wrong content attaches somebody's saved settings to a different
    workflow.
    """

    folder = workspace.add_source()
    write_json(folder / "m.json", api_graph(1))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    assert entry_ids(workspace) == ["m"]

    (folder / "m.json").rename(folder / renamed_to)
    write_json(folder / "m.json", api_graph(99))
    report = run_sync(workspace.load(), now=FIXED)

    seen = states(report)
    # The file that still holds the original bytes is the original workflow,
    # wherever its name sorts.
    assert seen[renamed_to] == "UNCHANGED"
    assert seen["m.json"] == "NEW"
    carried = {
        item.candidate.relative: item.id
        for item in report.workflows
        if item.candidate is not None
    }
    assert carried[renamed_to] == "m"
    assert carried["m.json"] != "m"
    # And nothing was lost: two entries, two ids, both content hashes recorded.
    document = workspace.read_inventory()["workflows"]
    assert len({entry["id"] for entry in document}) == 2
    assert all(entry["content_hash"] for entry in document)


def test_an_id_survives_the_content_changing(workspace: SyncWorkspace) -> None:
    """CHANGED means anything only because the id does not move with the bytes."""

    folder = workspace.add_source()
    path = folder / "evolving.json"
    write_json(path, api_graph(1))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    before = entry_ids(workspace)

    path.write_text(json.dumps(api_graph(99)), encoding="utf-8")
    report = run_sync(workspace.load(), now=FIXED)

    assert state_of(report, "evolving.json") == "CHANGED"
    assert entry_ids(workspace) == before


def test_two_files_that_differ_only_in_formatting_are_one_workflow(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "compact.json", api_graph(1))
    write_json(folder / "pretty printed.json", api_graph(1), indent=4)
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    values = sorted(item.state.value for item in report.workflows)
    assert values == ["EXACT_DUPLICATE", "NEW"]
    assert (folder / "compact.json").read_bytes() != (
        folder / "pretty printed.json"
    ).read_bytes(), "the fixture wrote the same bytes twice"


def test_two_workflows_are_never_merged_because_their_names_are_alike(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "portrait.json", api_graph(1))
    write_json(folder / "portrait (copy).json", api_graph(2))
    write_json(folder / "portrait 2.json", api_graph(3))
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    assert [item.state.value for item in report.workflows] == ["NEW", "NEW", "NEW"]
    assert len(set(entry_ids(workspace))) == 3


# ==========================================================================
# Duplicates
# ==========================================================================


def test_exact_duplicates_leave_one_entry_with_the_others_as_aliases(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "a.json", api_graph(1))
    write_json(folder / "b.json", api_graph(1))
    write_json(folder / "c.json", api_graph(1))
    before = tree_snapshot(folder)
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    entries = workspace.read_inventory()["workflows"]
    assert len(entries) == 1, entries
    aliases = [alias["source_relative"] for alias in entries[0]["aliases"]]
    assert aliases == ["b.json", "c.json"]
    duplicates = [
        item for item in report.workflows if item.state is WorkflowState.EXACT_DUPLICATE
    ]
    assert len(duplicates) == 2
    assert all("neither file is touched" in item.reason for item in duplicates)
    # No source file is deleted, moved or rewritten to make a duplicate go away.
    assert tree_snapshot(folder) == before
    assert sorted(path.name for path in folder.iterdir()) == ["a.json", "b.json", "c.json"]


def test_duplicate_detection_can_be_turned_off(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    write_json(folder / "a.json", api_graph(1))
    write_json(folder / "b.json", api_graph(1))
    workspace.write_config(sync={"detect_duplicates": False})

    report = run_sync(workspace.load(), now=FIXED)

    assert [item.state.value for item in report.workflows] == ["NEW", "NEW"]
    assert len(workspace.read_inventory()["workflows"]) == 2


def test_a_duplicate_never_takes_an_entry_away_from_the_file_it_replaced(
    workspace: SyncWorkspace,
) -> None:
    """A workflow overwritten with a copy of another one is still reported.

    The situation: two workflows were known, and then one of them was replaced
    by a copy of the other -- one file overwritten with the other's content,
    which is an ordinary "save as" gone slightly wrong.  The surviving file is
    now an exact duplicate, and a duplicate is an alias on the canonical entry
    rather than an entry of its own.

    So if the duplicate were allowed to claim the inventory entry that used to
    live at its path, that entry would be dropped from the inventory without a
    word -- a silent deletion, which is exactly what this run must never do.
    It is reported instead, and nothing is lost.
    """

    folder = workspace.add_source()
    write_json(folder / "a first.json", api_graph(1))
    write_json(folder / "b second.json", api_graph(2))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    assert sorted(entry_ids(workspace)) == ["a-first", "b-second"]

    (folder / "b second.json").write_text(json.dumps(api_graph(1)), encoding="utf-8")
    report = run_sync(workspace.load(), now=FIXED)

    seen = states(report)
    assert seen["a first.json"] == "UNCHANGED"
    assert seen["b second.json"] == "EXACT_DUPLICATE"
    assert seen["<gone> b-second"] == "REMOVED_FROM_SOURCE"
    # Nothing was dropped: both ids are still there, and the one whose content
    # is gone still carries what was known about it.
    document = workspace.read_inventory()["workflows"]
    by_id = {entry["id"]: entry for entry in document}
    assert sorted(by_id) == ["a-first", "b-second"]
    assert by_id["b-second"]["content_hash"]
    assert by_id["a-first"]["aliases"][0]["source_relative"] == "b second.json"


def test_two_identical_broken_files_are_both_reported(
    workspace: SyncWorkspace,
) -> None:
    """A duplicate never hides a problem: both bad files still say they are bad."""

    folder = workspace.add_source()
    (folder / "one.json").write_text("{ broken", encoding="utf-8")
    (folder / "two.json").write_text("{ broken", encoding="utf-8")
    workspace.write_config()

    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert [item.state.value for item in report.workflows] == ["INVALID", "INVALID"]


# ==========================================================================
# A source that disappears
# ==========================================================================


def test_a_removed_source_deletes_nothing(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    write_json(folder / "gone tomorrow.json", api_graph(1))
    write_json(folder / "still here.json", api_graph(2))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    before = entry_ids(workspace)

    (folder / "gone tomorrow.json").unlink()
    report = run_sync(workspace.load(), now=FIXED)

    assert states(report)["<gone> gone-tomorrow"] == "REMOVED_FROM_SOURCE"
    after = entry_ids(workspace)
    assert sorted(after) == sorted(before), "an entry was deleted"
    entry = next(
        item for item in workspace.read_inventory()["workflows"]
        if item["id"] == "gone-tomorrow"
    )
    assert entry["state"] == "REMOVED_FROM_SOURCE"
    assert "Nothing has been deleted" in entry["reason"]
    assert entry["content_hash"], "what was known about it was thrown away"


def test_detect_removed_off_leaves_the_entry_exactly_as_it_was(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "gone tomorrow.json", api_graph(1))
    workspace.write_config(sync={"detect_removed": False})
    run_sync(workspace.load(), now=FIXED)
    before = workspace.read_inventory()["workflows"]

    (folder / "gone tomorrow.json").unlink()
    report = run_sync(workspace.load(), now=FIXED)

    assert [item.state.value for item in report.workflows] == ["NEW"]
    assert workspace.read_inventory()["workflows"] == before


# ==========================================================================
# Source immutability
# ==========================================================================


def test_a_real_sync_changes_not_one_byte_of_a_source_folder(
    workspace: SyncWorkspace,
) -> None:
    """Hashed before and after, and the run is one that really writes.

    Both halves matter.  Without the second assertion the first would be a
    statement about a run that did nothing at all, which no implementation
    could fail.
    """

    folder = workspace.add_source()
    second = workspace.add_source("another folder with a space")
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "sub folder" / "two.json", api_graph(2))
    write_json(folder / "a ui export.json", UI_GRAPH)
    (folder / "broken.json").write_text("{ nope", encoding="utf-8")
    (folder / "notes.txt").write_text("a note of my own", encoding="utf-8")
    write_json(second / "three.json", api_graph(3))
    workspace.write_config()

    before_first = tree_snapshot(folder)
    before_second = tree_snapshot(second)
    assert len(before_first) == 5, before_first

    report = run_sync(workspace.load(), now=FIXED)

    assert workspace.inventory_path.exists(), "this run wrote nothing, so it proves nothing"
    assert len(report.workflows) == 5
    assert tree_snapshot(folder) == before_first
    assert tree_snapshot(second) == before_second


def test_an_output_path_inside_a_source_folder_is_refused(
    workspace: SyncWorkspace,
) -> None:
    """The rule made structural: nothing can be written there, ever.

    Checked for each of the three output paths in turn, because a check that
    only covers the inventory would let a later card start writing definitions
    into the user's own folder.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    inside = str(folder).replace("\\", "/")
    for key, arguments in (
        ("output.definitions", {"definitions": inside + "/lc definitions"}),
        ("output.imported_api", {"imported_api": inside + "/lc api"}),
        ("output.inventory", {"inventory": inside + "/lc inventory.json"}),
    ):
        workspace.write_config(**arguments)
        with pytest.raises(SyncConfigError) as caught:
            run_sync(workspace.load(), now=FIXED)
        message = str(caught.value)
        assert key in message, key
        assert "never writes anything into a folder it reads" in message
    assert sorted(path.name for path in folder.iterdir()) == ["one.json"]


def test_the_refusal_happens_before_anything_is_read_or_written(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config(
        inventory=str(folder).replace("\\", "/") + "/lc inventory.json"
    )

    with pytest.raises(SyncConfigError):
        run_sync(workspace.load(), now=FIXED)

    assert workspace.output_snapshot() == {}


def test_two_source_folders_may_not_overlap(workspace: SyncWorkspace) -> None:
    outer = workspace.add_source("outer folder")
    inner = outer / "inner folder"
    inner.mkdir()
    write_json(inner / "one.json", api_graph(1))
    workspace.write_config(sources=[outer, inner])

    with pytest.raises(SyncConfigError) as caught:
        run_sync(workspace.load(), now=FIXED)

    assert "one is inside the other" in str(caught.value)


# ==========================================================================
# The dry run
# ==========================================================================


def test_a_dry_run_writes_nothing_and_a_real_one_does(
    workspace: SyncWorkspace,
) -> None:
    """The whole output tree, hashed before and after.

    The second half is what makes the first half mean something: the same tree
    and the same configuration, run for real, must differ.  Otherwise "nothing
    changed" would be true of an implementation that cannot write at all.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "two.json", api_graph(2))
    workspace.write_config()
    (workspace.output_tree / "something else of mine.txt").write_text(
        "not the sync's", encoding="utf-8"
    )

    before = workspace.output_snapshot()
    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert workspace.output_snapshot() == before
    assert report.inventory_written is False
    assert [item.state.value for item in report.workflows] == ["NEW", "NEW"], (
        "the dry run found nothing, so writing nothing proves nothing"
    )

    run_sync(workspace.load(), now=FIXED)

    assert workspace.output_snapshot() != before
    assert workspace.inventory_path.exists()


def test_a_dry_run_creates_no_folder_either(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config(inventory="config/local/a new folder/inventory.json")

    run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert not (workspace.output_tree / "a new folder").exists()


def test_a_dry_run_after_a_real_one_leaves_the_inventory_alone(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    before = workspace.inventory_path.read_bytes()

    write_json(folder / "two.json", api_graph(2))
    report = run_sync(workspace.load(), dry_run=True, now=FIXED)

    assert workspace.inventory_path.read_bytes() == before
    assert len(report.workflows) == 2, "the dry run did not even see the new file"


# ==========================================================================
# Determinism
# ==========================================================================


def test_the_same_tree_produces_byte_identical_output_twice(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    for name in ("zulu.json", "alpha.json", "a folder/mike.json", "a folder/bravo.json"):
        write_json(folder / name, api_graph(len(name)))
    workspace.write_config()

    run_sync(workspace.load(), now=FIXED)
    first = workspace.inventory_path.read_bytes()
    # From the same starting state, not from the one the first run left: two
    # runs over an unchanged tree differ in their states (NEW then UNCHANGED),
    # and that difference is the point of the inventory rather than a defect.
    workspace.inventory_path.unlink()
    run_sync(workspace.load(), now=FIXED)
    second = workspace.inventory_path.read_bytes()

    assert first == second
    # The order is the tree's own: relative paths, compared case-insensitively,
    # so "a folder/bravo.json" precedes "alpha.json" -- and precedes it on
    # every machine, which is the whole point.
    assert entry_ids(workspace) == [
        "bravo",
        "mike",
        "alpha",
        "zulu",
    ], entry_ids(workspace)


def test_the_order_does_not_depend_on_the_filesystems(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    from localcanvas_gateway.workflows.sync import discovery

    folder = workspace.add_source()
    for name in ("zulu.json", "alpha.json", "middle.json"):
        write_json(folder / name, api_graph(len(name)))
    workspace.write_config()

    run_sync(workspace.load(), now=FIXED)
    forwards = workspace.inventory_path.read_bytes()

    workspace.inventory_path.unlink()
    original = discovery._entries
    monkeypatch.setattr(
        discovery, "_entries", lambda directory: list(reversed(original(directory)))
    )
    run_sync(workspace.load(), now=FIXED)

    assert workspace.inventory_path.read_bytes() == forwards


# ==========================================================================
# Failure isolation and the inventory
# ==========================================================================


def test_one_invalid_workflow_does_not_stop_the_others(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    (folder / "aaa broken.json").write_text("{ not json", encoding="utf-8")
    write_json(folder / "bbb fine.json", api_graph(1))
    write_json(folder / "ccc fine.json", api_graph(2))
    workspace.write_config()

    report = run_sync(workspace.load(), now=FIXED)

    assert [item.state.value for item in report.workflows] == [
        "INVALID",
        "NEW",
        "NEW",
    ]
    assert entry_ids(workspace) == ["aaa-broken", "bbb-fine", "ccc-fine"]


def test_a_workflow_that_became_invalid_never_costs_the_inventory_its_others(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "good.json", api_graph(1))
    write_json(folder / "was good.json", api_graph(2))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)

    (folder / "was good.json").write_text("{ broken now", encoding="utf-8")
    run_sync(workspace.load(), now=FIXED)

    document = workspace.read_inventory()
    assert document["inventory_version"] == 1
    by_id = {entry["id"]: entry for entry in document["workflows"]}
    assert by_id["good"]["state"] == "UNCHANGED"
    assert by_id["was-good"]["state"] == "INVALID"


def test_an_unreadable_source_root_is_fatal_and_writes_nothing(
    workspace: SyncWorkspace,
) -> None:
    workspace.add_source()
    workspace.write_config(sources=[workspace.base / "a folder that is not there"])

    with pytest.raises(SyncSourceError):
        run_sync(workspace.load(), now=FIXED)

    assert workspace.output_snapshot() == {}


def test_a_corrupt_inventory_is_reported_and_the_run_continues(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()
    workspace.inventory_path.parent.mkdir(parents=True, exist_ok=True)
    workspace.inventory_path.write_text("this is not JSON at all", encoding="utf-8")

    report = run_sync(workspace.load(), now=FIXED)

    assert [item.state.value for item in report.workflows] == ["NEW"]
    assert report.warnings, "the corrupt inventory was replaced without a word"
    assert "not readable JSON" in report.warnings[0]
    assert workspace.read_inventory()["inventory_version"] == 1


def test_the_inventory_is_swapped_into_place_and_never_written_over(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The atomicity, proved by taking the swap away.

    ``os.replace`` is the whole of the guarantee: the destination is never
    opened for writing, so an interrupted run cannot truncate it.  With the
    swap made to fail, a write that had opened the destination directly would
    have left it damaged; this one has to leave the previous document exactly
    as it was, and leave no temporary file behind either.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    before = workspace.inventory_path.read_bytes()
    assert before, "there was no previous inventory to protect"

    write_json(folder / "two.json", api_graph(2))

    def refuse(source, destination):
        raise OSError(13, "Access is denied")

    monkeypatch.setattr(inventory_module, "_replace", refuse)
    with pytest.raises(InventoryError) as caught:
        run_sync(workspace.load(), now=FIXED)

    assert "was left as it was" in str(caught.value)
    assert workspace.inventory_path.read_bytes() == before
    assert [name for name in workspace.output_names() if name.endswith(".tmp")] == [], (
        "a temporary file was left behind"
    )


def test_invalid_content_never_replaces_a_valid_inventory(
    workspace: SyncWorkspace,
) -> None:
    """The second interlock: the text is validated before the swap.

    Separate from the one above, and it fails on its own: the swap here works
    perfectly and is simply never reached, because the document does not
    survive its own round trip.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    before = workspace.inventory_path.read_bytes()

    with pytest.raises(InventoryError) as caught:
        inventory_module.write_inventory(
            workspace.inventory_path,
            {"inventory_version": 1, "workflows": [{"id": "", "state": "NEW"}]},
        )

    assert "not a valid inventory" in str(caught.value)
    assert workspace.inventory_path.read_bytes() == before
    assert [name for name in workspace.output_names() if name.endswith(".tmp")] == []


def test_a_document_that_cannot_be_serialised_leaves_the_previous_one(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)
    before = workspace.inventory_path.read_bytes()

    with pytest.raises(InventoryError, match="could not be turned into JSON"):
        inventory_module.write_inventory(
            workspace.inventory_path,
            {"inventory_version": 1, "workflows": [], "extra": {1, 2}},
        )

    assert workspace.inventory_path.read_bytes() == before


# ==========================================================================
# Manual metadata
# ==========================================================================


def test_a_note_added_by_hand_survives_the_next_run(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()
    run_sync(workspace.load(), now=FIXED)

    document = workspace.read_inventory()
    document["workflows"][0]["my note"] = "the one I actually use"
    workspace.inventory_path.write_text(json.dumps(document), encoding="utf-8")

    run_sync(workspace.load(), now=FIXED)

    assert workspace.read_inventory()["workflows"][0]["my note"] == (
        "the one I actually use"
    )


def test_preserve_manual_metadata_off_drops_it(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config(sync={"preserve_manual_metadata": False})
    run_sync(workspace.load(), now=FIXED)

    document = workspace.read_inventory()
    document["workflows"][0]["my note"] = "the one I actually use"
    workspace.inventory_path.write_text(json.dumps(document), encoding="utf-8")

    run_sync(workspace.load(), now=FIXED)

    assert "my note" not in workspace.read_inventory()["workflows"][0]


# ==========================================================================
# No network, at all
# ==========================================================================


def test_a_sync_with_no_bridge_never_opens_a_socket(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A guard that can fire: every way of opening one is booby-trapped.

    The sabotage is proved to work at the end of the test, on this very
    process, so this is not an assertion about a mechanism that was quietly
    disabled.

    Since T-0084 the sync *can* reach a ComfyUI, and this is the statement of
    exactly when: only through a bridge it was handed.  The tree below includes
    an editor-format workflow -- the one kind that would need converting -- so
    the run had every reason to reach for a network and still did not.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "editor.json", UI_GRAPH)
    (folder / "broken.json").write_text("{ nope", encoding="utf-8")
    workspace.write_config()

    def refuse(*args, **kwargs):
        raise AssertionError("the sync opened a socket")

    monkeypatch.setattr(socket, "socket", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)

    report = run_sync(workspace.load(), now=FIXED)

    assert len(report.workflows) == 3
    assert workspace.inventory_path.exists()
    with pytest.raises(AssertionError, match="opened a socket"):
        socket.socket()


#: The modules in the sync package allowed to reach the network.  Named here
#: rather than implied, so that adding a third is a decision somebody has to
#: make in this file (T-0084).  Everything that decides what a workflow *means*
#: -- the classifier, the importer, the catalogue, the engine -- stays offline,
#: and the lint below is what keeps that true as the package grows.
#:
#: ``bridge.py`` is the capability; ``browser_fake.py`` is the stand-in browser
#: the tests launch, and a program pretending to be a browser is a network
#: program by definition -- the same trade ``comfy/fake.py`` already makes.
_NETWORK_MODULES = ("bridge.py", "browser_fake.py")


def test_only_the_bridge_reaches_the_network_in_the_sync_package() -> None:
    """Read as source, so a network import that is never executed still fails.

    Anchored to a symbol that has to exist: if a module is renamed away, the
    anchor is missing and this fails loudly rather than passing over an empty
    list of files.

    The exception is a single named file and is asserted in **both**
    directions: every other module must be clean, and ``bridge.py`` must
    actually contain the import -- otherwise the day the bridge is rewritten to
    reach the network some other way, this lint would go on passing while
    guarding nothing.
    """

    from localcanvas_gateway.workflows import sync as package

    folder = Path(package.__file__).resolve().parent
    sources = sorted(folder.glob("*.py"))
    names = {path.name for path in sources}
    assert names == {
        "__init__.py",
        "analysis.py",
        "bridge.py",
        "browser_fake.py",
        "catalog.py",
        "classify.py",
        "cli.py",
        "config.py",
        "contract.py",
        "definitions.py",
        "discovery.py",
        "engine.py",
        "errors.py",
        "inventory.py",
        "report.py",
        "semantics.py",
        "snapshots.py",
    }, sorted(names)
    assert set(_NETWORK_MODULES) <= names, "a named module was renamed away"

    offline = [path for path in sources if path.name not in _NETWORK_MODULES]
    joined = "\n".join(path.read_text(encoding="utf-8") for path in offline)
    assert "def run_sync(" in joined, "the engine was renamed; this lint scanned nothing"
    assert "def analyse(" in joined, "the importer was renamed; this lint scanned nothing"
    assert "def describe(" in joined, "the catalogue was renamed; this lint scanned nothing"
    assert (
        "def read_object_info(" in joined
    ), "the runtime contract was renamed; this lint scanned nothing"
    libraries = (
        "import socket",
        "import http",
        "import urllib",
        "import requests",
        "import httpx",
        "import aiohttp",
        "import ftplib",
        "import smtplib",
        "webbrowser",
    )
    for library in libraries:
        assert library not in joined, "the sync package imports " + library

    # The other direction: each exception is a real one.  A module that stopped
    # importing anything network-shaped would mean this lint had quietly become
    # an assertion about nothing.
    for name in _NETWORK_MODULES:
        source = (folder / name).read_text(encoding="utf-8")
        assert any(library in source for library in libraries), (
            "{} reaches the network by some other means now; this lint's "
            "exception no longer describes anything".format(name)
        )


def test_the_gateway_does_not_import_the_sync_engine_at_run_time() -> None:
    """A curator tool that happens to share the package, and nothing more.

    Proved in a process of its own, because this one has already imported the
    engine to test it.
    """

    import subprocess
    import sys

    gateway_root = Path(__file__).resolve().parents[1]
    probe = (
        "import sys;"
        "import localcanvas_gateway;"
        "import localcanvas_gateway.workflows;"
        "import localcanvas_gateway.api;"
        "import localcanvas_gateway.workflows.cli;"
        "loaded=[name for name in sys.modules if '.sync' in name];"
        "print(loaded)"
    )
    result = subprocess.run(
        [sys.executable, "-c", probe],
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHONPATH": str(gateway_root)},
        timeout=180,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "[]", result.stdout
