"""The two kinds of fatal sync failure, and what each one may say (T-0225).

``python -m localcanvas_gateway.workflows sync`` exits 2 when a run cannot
finish.  Every cause but one is found before the run writes a single file, and
for those "nothing was changed" is true.  The one exception is an inventory
that cannot be written: the inventory is written last, after the conversion
snapshots, the imported graphs and the definitions, so by then those files can
already be on disk.  Its ``[FAIL]`` block says so, and carries a marker line
the PowerShell front end reads to choose its closing sentence.

The claim "may already be on disk" is proved here by looking at the files, and
"the next successful sync will record them" by running that sync.
"""

from __future__ import annotations

import io
import json
import shutil
from pathlib import Path
from typing import Any, List, Optional

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows.sync import cli
from localcanvas_gateway.workflows.sync.classify import content_hash
from localcanvas_gateway.workflows.sync.engine import (
    INVENTORY_NOT_WRITTEN_MARKER,
    INVENTORY_NOT_WRITTEN_NOTICE,
)
from localcanvas_gateway.workflows.sync.snapshots import cache_directory
from bridge_fixtures import Browser, converted_graph, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, api_graph, tree_snapshot, write_json

#: Written out here rather than imported, so a change to the wording is a
#: change this test has to be told about.
MARKER = "[INVENTORY_NOT_WRITTEN]"
NOTICE = (
    "The inventory could not be written, and it is written last: definitions, "
    "imported workflow graphs and conversion snapshots this run wrote may "
    "already be on disk. The next successful sync will record them."
)

#: The configured inventory path, made unwritable by being a folder.  Nothing
#: is patched: the swap into place fails in the operating system.
INVENTORY_AS_FOLDER = "config/local/inventory that is a folder"


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


@pytest.fixture()
def comfy():
    with FakeComfy() as running:
        yield running


def run_cli(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch, bridge: Optional[Any]
):
    """``cli.main`` over the workspace, with ``bridge`` as the one it builds."""

    monkeypatch.setattr(cli, "_bridge", lambda args: bridge)
    out, err = io.StringIO(), io.StringIO()
    try:
        code = cli.main(["--config", str(workspace.config_path)], out=out, err=err)
    finally:
        if bridge is not None:
            bridge.close()
    return code, out.getvalue(), err.getvalue()


def files_under(folder: Path) -> List[str]:
    return sorted(tree_snapshot(folder))


def test_the_wording_is_the_one_this_test_was_written_for() -> None:
    assert INVENTORY_NOT_WRITTEN_MARKER == MARKER
    assert INVENTORY_NOT_WRITTEN_NOTICE == NOTICE


def test_an_inventory_that_cannot_be_written_says_the_files_may_be_on_disk(
    workspace: SyncWorkspace,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Exit 2 after the files were placed, in the words that are true for it.

    One API export and one editor-format workflow, so the run writes all three
    kinds of file the notice names: two definitions, two imported graphs and
    one conversion snapshot.
    """

    folder = workspace.add_source()
    write_json(folder / "an export.json", api_graph(1))
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config(inventory=INVENTORY_AS_FOLDER)
    inventory = workspace.repo / INVENTORY_AS_FOLDER
    inventory.mkdir(parents=True)

    output = workspace.load().output
    assert files_under(workspace.output_tree) == [workspace.config_path.name], (
        "the output tree held files before the run, so finding them after it "
        "would prove nothing"
    )

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph(3)}
    )
    code, stdout, stderr = run_cli(
        workspace, monkeypatch, make_bridge(comfy.base_url, browser)
    )

    assert code == cli.EXIT_FATAL, stderr
    assert stdout == "", "a run that failed printed a report"

    lines = stderr.splitlines()
    assert len(lines) == 3, stderr
    # The inventory's own reason stays the headline, exactly as before.
    assert lines[0].startswith("[FAIL] the inventory could not "), stderr
    assert "was left as it was" in lines[0], stderr
    assert str(inventory) in lines[0], stderr
    # The marker is a line of its own; the notice follows it, whole.
    assert lines[1] == "       " + MARKER, stderr
    assert lines[2] == "       " + NOTICE, stderr

    # And the notice is true: the files it names are on disk.
    definitions = sorted(output.definitions.glob("*.yaml"))
    assert [path.name for path in definitions] == ["a-canvas.yaml", "an-export.yaml"]
    graphs = sorted(output.imported_api.glob("*.json"))
    assert len(graphs) == 2, graphs
    for definition in definitions:
        text = definition.read_text(encoding="utf-8")
        named = [graph for graph in graphs if graph.name in text]
        assert len(named) == 1, (definition.name, [graph.name for graph in graphs])
    source_hash = content_hash((folder / "a canvas.json").read_bytes())
    snapshots = sorted(cache_directory(output).glob("*.json"))
    assert len(snapshots) == 1, snapshots
    assert snapshots[0].name.startswith(source_hash.split(":")[-1][:16] + ".")

    # The inventory itself was left as it was: still the folder, and empty.
    assert inventory.is_dir()
    assert list(inventory.iterdir()) == []
    assert [name for name in files_under(workspace.output_tree) if name.endswith(".tmp")] == []

    # "The next successful sync will record them."
    shutil.rmtree(str(inventory))
    placed = {path.name: path.read_bytes() for path in definitions}
    browser_again = Browser(
        tmp_path / "again", monkeypatch, default={"ok": True, "output": converted_graph(3)}
    )
    code, stdout, stderr = run_cli(
        workspace, monkeypatch, make_bridge(comfy.base_url, browser_again)
    )
    assert code in (cli.EXIT_OK, cli.EXIT_ATTENTION), stderr
    assert stderr == ""
    recorded = json.loads(inventory.read_text(encoding="utf-8"))
    entries = {entry["id"]: entry for entry in recorded["workflows"]}
    assert sorted(entries) == ["a-canvas", "an-export"]
    for workflow_id, entry in entries.items():
        assert entry["generated_fingerprint"], (workflow_id, entry)
        assert (output.definitions / (workflow_id + ".yaml")).read_bytes() == placed[
            workflow_id + ".yaml"
        ]
    assert entries["a-canvas"]["conversion"], entries["a-canvas"]


def no_configuration(workspace: SyncWorkspace) -> None:
    workspace.add_source()


def malformed_configuration(workspace: SyncWorkspace) -> None:
    workspace.add_source()
    workspace.write_config(body="sources: [\n")


def missing_source_folder(workspace: SyncWorkspace) -> None:
    workspace.write_config(sources=[workspace.base / "no such folder"])


def overlapping_sources(workspace: SyncWorkspace) -> None:
    outer = workspace.add_source("outer")
    inner = outer / "inner"
    inner.mkdir()
    workspace.write_config(sources=[outer, inner])


def output_inside_a_source(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    workspace.write_config(
        definitions=str(folder / "definitions").replace("\\", "/")
    )


@pytest.mark.parametrize(
    "arrange",
    [
        no_configuration,
        malformed_configuration,
        missing_source_folder,
        overlapping_sources,
        output_inside_a_source,
    ],
)
def test_every_other_fatal_failure_writes_nothing_and_carries_no_marker(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch, arrange
) -> None:
    """The first kind keeps its block: no marker, and nothing on disk.

    Each source folder holds a workflow a run would import, so a failure found
    after the writes would leave a definition behind.
    """

    arrange(workspace)
    for folder in workspace.sources:
        write_json(folder / "an export.json", api_graph(1))
    before = tree_snapshot(workspace.base)

    code, stdout, stderr = run_cli(workspace, monkeypatch, None)

    assert code == cli.EXIT_FATAL, stderr
    assert stdout == ""
    assert stderr.startswith("[FAIL] "), stderr
    assert MARKER not in stderr, stderr
    assert "written last" not in stderr, stderr
    assert tree_snapshot(workspace.base) == before


def test_a_run_that_can_write_its_inventory_says_nothing_of_the_kind(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The control for both tests above: the same tree, with an inventory path
    that can be written, exits 0 and writes the files and the inventory."""

    folder = workspace.add_source()
    write_json(folder / "an export.json", api_graph(1))
    workspace.write_config()

    code, stdout, stderr = run_cli(workspace, monkeypatch, None)

    assert code == cli.EXIT_OK, stderr
    assert stderr == ""
    assert workspace.inventory_path.is_file()
    assert (workspace.output_tree / "workflows" / "an-export.yaml").is_file()
