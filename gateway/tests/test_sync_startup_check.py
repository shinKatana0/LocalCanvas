"""What the startup check says about an editor-format workflow (T-0350).

``scripts/start.ps1`` runs the engine as ``sync --dry-run --no-convert``: it
converts nothing, contacts nothing and writes nothing.  Before T-0350 that left
every canvas ``NEEDS_API_EXPORT`` and nothing more, so a canvas somebody had
just saved in ComfyUI was never offered for sync, and one the last sync had
imported perfectly well was reported as "needs a look" on every start.

The engine now says, beside the unchanged states, what the inventory knows
about each canvas it did not convert: the ``unconverted_editor`` block.  These
tests hold four things about it:

* a new, an edited, an imported-and-untouched and a not-imported canvas get the
  four different answers, decided from the inventory the **real** converting
  sync wrote -- the first run of each test is the production engine, the
  production bridge, a stand-in browser process and a stand-in ComfyUI;
* the check itself converts nothing: the bridge class is replaced by one that
  fails the test if it is ever built, and the output tree is byte-identical;
* the states are exactly what they were, so ``sync-workflows.ps1 -NoConvert``
  reports what it always reported;
* an inventory from before the change loads, and needs no migration.
"""

from __future__ import annotations

import io
import json
from pathlib import Path
from typing import Any, Dict

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows.sync import cli, run_sync
from localcanvas_gateway.workflows.sync.engine import EDITOR_HISTORY_KEYS
from localcanvas_gateway.workflows.sync.report import report_document
from bridge_fixtures import Browser, converted_graph, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, api_graph, tree_snapshot, write_json

ZEROES = {key: 0 for key in EDITOR_HISTORY_KEYS}


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


@pytest.fixture()
def comfy():
    with FakeComfy() as running:
        yield running


class _NoBridge:
    """Stands in for ``ConversionBridge`` in the check, and must never be built."""

    built = 0

    def __init__(self, *args: Any, **kwargs: Any) -> None:  # pragma: no cover
        type(self).built += 1
        raise AssertionError("the startup check built a conversion bridge")


def check(workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch) -> Dict[str, Any]:
    """The startup check exactly as start.ps1 runs it, through the CLI.

    ``--runtime-config`` names a file that does not exist on purpose: even with
    no endpoint to find, ``--no-convert`` must be what keeps the bridge away,
    and the stand-in class fails the test if anything builds one.
    """

    _NoBridge.built = 0
    monkeypatch.setattr(cli, "ConversionBridge", _NoBridge)
    before = tree_snapshot(workspace.output_tree)
    sources_before = {str(folder): tree_snapshot(folder) for folder in workspace.sources}
    out, err = io.StringIO(), io.StringIO()
    code = cli.main(
        [
            "--config", str(workspace.config_path),
            "--runtime-config", str(workspace.base / "no runtime.yaml"),
            "--dry-run",
            "--no-convert",
        ],
        out=out,
        err=err,
    )
    assert code in (0, 1), err.getvalue()
    assert _NoBridge.built == 0
    # Nothing written, and no source touched.
    assert tree_snapshot(workspace.output_tree) == before
    assert {str(folder): tree_snapshot(folder) for folder in workspace.sources} == sources_before
    return json.loads(out.getvalue())


def converting_sync(workspace, tmp_path, monkeypatch, comfy, *, ok=True):
    """A real sync, through the real bridge, that ComfyUI answers."""

    answer = (
        {"ok": True, "output": converted_graph(3)}
        if ok
        else {"ok": False, "name": "TypeError", "message": "a node is missing"}
    )
    browser = Browser(tmp_path, monkeypatch, default=answer)
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)
    return report


# ==========================================================================
# The four answers
# ==========================================================================


def test_a_canvas_nobody_has_synced_is_new(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    folder = workspace.add_source()
    write_json(folder / "fresh canvas.json", ui_graph("fresh"))
    workspace.write_config()

    document = check(workspace, monkeypatch)

    assert document["unconverted_editor"] == dict(ZEROES, new=1)
    # The state is what it always was: the block is beside it, not instead.
    assert document["counts"]["NEEDS_API_EXPORT"] == 1
    assert document["counts"]["NEW"] == 0


def test_a_canvas_the_last_sync_imported_is_unchanged(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The line that used to recur on every start, gone -- and nothing asked."""

    folder = workspace.add_source()
    write_json(folder / "saved canvas.json", ui_graph("saved"))
    workspace.write_config()
    first = converting_sync(workspace, tmp_path, monkeypatch, comfy)
    assert [item.state.value for item in first.workflows] == ["NEW"]
    assert workspace.read_inventory()["workflows"][0]["format"] == "ui"

    requests_before = len(comfy.requests)
    document = check(workspace, monkeypatch)

    assert document["unconverted_editor"] == dict(ZEROES, unchanged=1)
    assert document["conversion"]["counts"] == {
        "converted": 0, "reused": 0, "failed": 0, "unavailable": 0,
    }
    assert len(comfy.requests) == requests_before


def test_a_renamed_or_reformatted_canvas_is_still_unchanged(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Identity is content, for a canvas exactly as for an API export."""

    folder = workspace.add_source()
    original = write_json(folder / "one.json", ui_graph("one"))
    workspace.write_config()
    converting_sync(workspace, tmp_path, monkeypatch, comfy)

    original.rename(folder / "renamed.json")
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, unchanged=1)

    write_json(folder / "renamed.json", ui_graph("one"), indent=4)
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, unchanged=1)


def test_an_edited_canvas_is_changed(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    folder = workspace.add_source()
    path = write_json(folder / "edited canvas.json", ui_graph("edited", seed=1))
    workspace.write_config()
    converting_sync(workspace, tmp_path, monkeypatch, comfy)

    write_json(path, ui_graph("edited", seed=2))
    document = check(workspace, monkeypatch)

    assert document["unconverted_editor"] == dict(ZEROES, changed=1)


def test_a_canvas_comfy_could_not_convert_still_needs_a_look(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Not offered again on every start, and not hidden either."""

    folder = workspace.add_source()
    path = write_json(folder / "refused canvas.json", ui_graph("refused"))
    workspace.write_config()
    first = converting_sync(workspace, tmp_path, monkeypatch, comfy, ok=False)
    assert [item.state.value for item in first.workflows] == ["NEEDS_API_EXPORT"]

    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, attention=1)

    # Editing it is what makes it worth offering again.
    write_json(path, ui_graph("refused", seed=9))
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, changed=1)


def test_every_answer_in_one_folder_beside_api_exports(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The block counts canvases only; an API export is counted where it always was."""

    folder = workspace.add_source()
    kept = write_json(folder / "kept.json", ui_graph("kept"))
    edited = write_json(folder / "edited.json", ui_graph("edited", seed=1))
    write_json(folder / "export.json", api_graph(1))
    workspace.write_config()
    converting_sync(workspace, tmp_path, monkeypatch, comfy)
    assert kept.exists()

    write_json(edited, ui_graph("edited", seed=2))
    write_json(folder / "brand new.json", ui_graph("brand new"))
    write_json(folder / "another export.json", api_graph(2))
    document = check(workspace, monkeypatch)

    assert document["unconverted_editor"] == {
        "new": 1, "changed": 1, "unchanged": 1, "retry": 0, "attention": 0,
    }
    assert document["counts"]["NEEDS_API_EXPORT"] == 3
    assert document["counts"]["NEW"] == 1
    assert document["counts"]["UNCHANGED"] == 1


# ==========================================================================
# What does not change
# ==========================================================================


def test_a_run_with_a_bridge_counts_no_unconverted_canvas(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Every canvas it saw was asked about; its own state says what happened."""

    folder = workspace.add_source()
    write_json(folder / "a.json", ui_graph("a"))
    write_json(folder / "b.json", ui_graph("b"))
    workspace.write_config()

    report = converting_sync(workspace, tmp_path, monkeypatch, comfy)

    assert report_document(report)["unconverted_editor"] == ZEROES


def test_an_api_only_folder_reports_zeroes(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    folder = workspace.add_source()
    write_json(folder / "export.json", api_graph(1))
    workspace.write_config()

    assert check(workspace, monkeypatch)["unconverted_editor"] == ZEROES


# ==========================================================================
# An inventory written before T-0350
# ==========================================================================


def _older_inventory(workspace: SyncWorkspace, entries) -> None:
    """An inventory in the shape a version before conversion existed wrote.

    No ``conversion`` key and none of the ``generated_*`` records -- the
    oldest shape the reader accepts -- so this is the strictest version of
    "an old inventory still loads".
    """

    workspace.inventory_path.parent.mkdir(parents=True, exist_ok=True)
    workspace.inventory_path.write_text(
        json.dumps(
            {
                "inventory_version": 1,
                "generated": "2026-01-01T00:00:00Z",
                "config": str(workspace.config_path),
                "workflows": list(entries),
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def _old_entry(workspace, identifier, path: Path, state: str) -> Dict[str, Any]:
    from localcanvas_gateway.workflows.sync.classify import classify

    classification = classify(path.read_bytes())
    return {
        "id": identifier,
        "state": state,
        "format": "ui",
        "source_root": str(path.parent),
        "source_path": str(path),
        "source_relative": path.name,
        "content_hash": classification.content_hash,
        "canonical_hash": classification.canonical_hash,
        "size_bytes": path.stat().st_size,
        "aliases": [],
        "reason": None,
        "first_seen": "2026-01-01T00:00:00Z",
        "last_seen": "2026-01-01T00:00:00Z",
    }


def test_an_older_inventory_loads_and_needs_no_migration(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Imported before: unchanged at once.  Never converted: offered again."""

    folder = workspace.add_source()
    imported = write_json(folder / "imported.json", ui_graph("imported"))
    never = write_json(folder / "never converted.json", ui_graph("never"))
    workspace.write_config()
    _older_inventory(
        workspace,
        [
            _old_entry(workspace, "imported", imported, "UNCHANGED"),
            _old_entry(workspace, "never-converted", never, "NEEDS_API_EXPORT"),
        ],
    )

    document = check(workspace, monkeypatch)

    assert document["warnings"] == [], document["warnings"]
    # An entry from before conversion existed has no conversion record: no
    # ComfyUI was ever asked, which is not the file's fault, so it is offered.
    assert document["unconverted_editor"] == dict(ZEROES, unchanged=1, retry=1)
    # Both kept their ids: the entries were read, not treated as absent.
    assert sorted(item["id"] for item in document["workflows"]) == [
        "imported", "never-converted",
    ]


def test_an_entry_carried_forward_as_removed_is_reported_when_it_returns(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A carried-forward entry no longer says whether it was imported."""

    folder = workspace.add_source()
    back = write_json(folder / "back again.json", ui_graph("back"))
    workspace.write_config()
    _older_inventory(
        workspace, [_old_entry(workspace, "back-again", back, "REMOVED_FROM_SOURCE")]
    )

    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, attention=1)


# ==========================================================================
# Accepted: the importer's canvas is what the gateway serves
# ==========================================================================


def test_a_new_canvas_the_sync_imports_is_served_by_the_gateway(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy, builder, gateway_factory,
) -> None:
    """New in the check, imported by the one importer, then in the app's list.

    The sync writes its definitions into the very folder the gateway is built
    on, so what is asserted at the end is the gateway's own answer about the
    registry the sync produced -- not the sync's claim that it wrote a file.
    """

    folder = workspace.add_source()
    write_json(folder / "just saved.json", ui_graph("just saved"))
    workspace.write_config(definitions=str(builder.root).replace("\\", "/"))

    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, new=1)

    report = converting_sync(workspace, tmp_path, monkeypatch, comfy)
    assert [item.state.value for item in report.workflows] == ["NEW"]
    assert report.definitions_written == 1

    harness = gateway_factory()
    served = [item["id"] for item in harness.client.get("/api/v1/workflows").json()["workflows"]]
    assert served == ["just-saved"], served

    # And the start after that: nothing to report, nothing to offer.
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, unchanged=1)


# ==========================================================================
# Rework: duplicates, and a failure that was not the file's (T-0350 review)
# ==========================================================================


def test_two_identical_canvases_are_both_new_and_then_both_unchanged(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """A copy is recorded as an alias of the entry, and is matched as one.

    Without that the copy reads as new on every start for ever -- a sync
    records it as an EXACT_DUPLICATE, which claims no entry of its own, so
    nothing a sync does can make the prompt stop.
    """

    folder = workspace.add_source()
    write_json(folder / "portrait.json", ui_graph("twin"))
    write_json(folder / "portrait copy.json", ui_graph("twin"))
    workspace.write_config()

    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, new=2)

    first = converting_sync(workspace, tmp_path, monkeypatch, comfy)
    assert sorted(item.state.value for item in first.workflows) == ["EXACT_DUPLICATE", "NEW"]
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, unchanged=2)

    second = converting_sync(workspace, tmp_path, monkeypatch, comfy)
    assert sorted(item.state.value for item in second.workflows) == [
        "EXACT_DUPLICATE", "UNCHANGED"]
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, unchanged=2)


def test_an_edited_copy_counts_as_what_the_next_sync_will_call_it(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The copy recorded as an alias, edited: offered, and counted as the sync counts it.

    Which file is the alias is read from the inventory, not assumed from the
    names, and the sync that follows is the referee: the check must say what
    that sync then says.
    """

    folder = workspace.add_source()
    write_json(folder / "portrait.json", ui_graph("twin"))
    write_json(folder / "portrait copy.json", ui_graph("twin"))
    workspace.write_config()
    converting_sync(workspace, tmp_path, monkeypatch, comfy)
    entries = workspace.read_inventory()["workflows"]
    assert len(entries) == 1 and len(entries[0]["aliases"]) == 1, entries
    alias = Path(entries[0]["aliases"][0]["source_path"])

    write_json(alias, ui_graph("twin", seed=5))
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(
        ZEROES, unchanged=1, new=1)

    after = converting_sync(workspace, tmp_path, monkeypatch, comfy)
    assert sorted(item.state.value for item in after.workflows) == ["NEW", "UNCHANGED"]
    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, unchanged=2)


def unavailable_sync(workspace: SyncWorkspace, comfy: FakeComfy):
    """A real sync whose bridge cannot run at all: no browser on this machine.

    ``candidates=()`` and no program: the production bridge looks for a
    browser, finds none, and every canvas is recorded ``unavailable`` --
    the run-wide failure, which is about the machine and not about the file.
    """

    with make_bridge(comfy.base_url, candidates=()) as bridge:
        return run_sync(workspace.load(), bridge=bridge)


def test_a_canvas_a_run_wide_failure_left_unconverted_is_offered_again(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "unlucky canvas.json", ui_graph("unlucky"))
    workspace.write_config()
    first = unavailable_sync(workspace, comfy)
    assert [item.state.value for item in first.workflows] == ["NEEDS_API_EXPORT"]
    recorded = workspace.read_inventory()["workflows"][0]["conversion"]
    assert recorded["status"] == "unavailable", recorded

    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, retry=1)


def test_a_canvas_comfy_refused_is_not_offered_again(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The content failure: ComfyUI was asked about this graph and said no."""

    folder = workspace.add_source()
    write_json(folder / "refused canvas.json", ui_graph("refused"))
    workspace.write_config()
    converting_sync(workspace, tmp_path, monkeypatch, comfy, ok=False)
    recorded = workspace.read_inventory()["workflows"][0]["conversion"]
    assert recorded["status"] == "failed", recorded

    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, attention=1)


def test_a_canvas_a_sync_without_comfyui_recorded_is_offered_again(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No bridge at all (no runtime.yaml, or -NoConvert): not the file's fault."""

    folder = workspace.add_source()
    write_json(folder / "never asked.json", ui_graph("never"))
    workspace.write_config()
    run_sync(workspace.load(), bridge=None)
    entry = workspace.read_inventory()["workflows"][0]
    assert entry["state"] == "NEEDS_API_EXPORT" and entry["conversion"] is None, entry

    assert check(workspace, monkeypatch)["unconverted_editor"] == dict(ZEROES, retry=1)
