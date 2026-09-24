"""A whole sync run over editor-format workflows.

``test_sync_bridge.py`` is about the boundary; this is about the run around it:
what is written, what is reused, what a dry run does, and what one workflow's
failure does to the others.

Every run here goes through the production engine, the production bridge, a
real stand-in browser process and a real stand-in ComfyUI.  The only
substitution is which program is launched as the browser.
"""

from __future__ import annotations

import io
import json
from pathlib import Path
from typing import Any, Dict, List

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows.sync import run_sync
from localcanvas_gateway.workflows.sync import cli
from localcanvas_gateway.workflows.sync.errors import SyncConfigError
from localcanvas_gateway.workflows.sync.bridge import (
    CATEGORY_COMFY_UNREACHABLE,
    CATEGORY_CONVERSION_REJECTED,
    CATEGORY_NOT_IMPORTABLE,
    ConversionStatus,
)
from localcanvas_gateway.workflows.sync.classify import content_hash
from localcanvas_gateway.workflows.sync.engine import DRY_RUN_CONVERSION_NOTICE
from localcanvas_gateway.workflows.sync.report import report_document
from localcanvas_gateway.workflows.sync.snapshots import (
    cache_directory,
    snapshot_path,
)
from bridge_fixtures import (
    Browser,
    CountingPopen,
    converted_graph,
    make_bridge,
    ui_graph,
)
from sync_fixtures import (
    API_GRAPH,
    SyncWorkspace,
    api_graph,
    states,
    tree_snapshot,
    write_json,
)

FIXED = None  # the engine's own clock; these tests never compare two runs' bytes


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


@pytest.fixture()
def comfy():
    with FakeComfy() as running:
        yield running


def by_relative(report) -> Dict[str, Any]:
    return {
        item.candidate.relative: item
        for item in report.workflows
        if item.candidate is not None
    }


def cache_files(workspace: SyncWorkspace) -> List[str]:
    folder = cache_directory(workspace.load().output)
    if not folder.exists():
        return []
    return sorted(path.name for path in folder.iterdir())


# ==========================================================================
# The ordinary case: an editor workflow becomes an importable one
# ==========================================================================


def test_an_editor_workflow_is_converted_and_imported(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The whole point of the card, end to end and on disk.

    What is asserted is not only the state: the definition on disk must name
    the imported graph, and that graph must be the one the browser produced --
    traced by the nonce, which nothing in this process could have invented.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph(3)}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.state.value == "NEW"
    assert item.conversion.status is ConversionStatus.CONVERTED
    assert item.definition is not None and item.definition.written

    imported = sorted((workspace.output_tree / "imported-workflows").glob("*.json"))
    assert len(imported) == 1, imported
    graph = json.loads(imported[0].read_text(encoding="utf-8"))
    assert graph["10"]["_meta"]["produced_by"] == browser.saw()["nonce"]
    assert graph["20"]["inputs"]["seed"] == 3

    # The definition points at that file by a relative path, as the schema
    # requires, and the file is named after its own content.
    definition = (workspace.output_tree / "workflows" / "a-canvas.yaml").read_text(
        encoding="utf-8"
    )
    assert imported[0].name in definition
    assert content_hash(imported[0].read_bytes()).split(":")[1][:12] in imported[0].name


def test_the_source_file_is_untouched_by_a_converting_run(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Hashed before and after, and the run is one that genuinely writes."""

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    write_json(folder / "nested" / "another canvas.json", ui_graph("two"))
    workspace.write_config()
    before = tree_snapshot(folder)
    assert len(before) == 2

    browser = Browser(
        tmp_path,
        monkeypatch,
        cases={
            "one": {"ok": True, "output": converted_graph(1)},
            "two": {"ok": True, "output": converted_graph(2)},
        },
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        run_sync(workspace.load(), bridge=bridge)

    assert tree_snapshot(folder) == before
    assert workspace.output_names(), "the run wrote nothing, so this proves nothing"


def test_the_analysis_reads_the_converted_graph_and_not_the_canvas(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Order of stages, asserted through what the importer ended up describing.

    The canvas names two nodes that do not survive conversion, and the
    converted graph names one node id the canvas never had. What the control
    inventory talks about is the second set -- so analysis ran on the graph
    that will really run.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    expanded = {
        "77:5": {
            "class_type": "ExampleLoader",
            "inputs": {"name": "PLACEHOLDER.safetensors"},
        },
        "77:6": {
            "class_type": "ExampleSampler",
            "inputs": {"seed": 4, "model": ["77:5", 0]},
        },
    }
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": expanded})
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.plan is not None, "nothing was analysed at all"
    nodes = sorted({record.node for record in item.plan.controls})
    assert nodes == ["77:5", "77:6"], nodes
    # The subgraph-shaped ids reach the definition's bindings untouched.
    document = report_document(report)
    fields = document["workflows"][0]["controls"]
    assert {entry["node"] for entry in fields} == {"77:5", "77:6"}


# ==========================================================================
# Failure: per workflow, with a category, and never any output
# ==========================================================================


def test_one_conversion_failure_does_not_block_the_others(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Three canvases, the middle one refused: the other two still import."""

    folder = workspace.add_source()
    write_json(folder / "first.json", ui_graph("first"))
    write_json(folder / "middle.json", ui_graph("middle"))
    write_json(folder / "last.json", ui_graph("last"))
    workspace.write_config()

    browser = Browser(
        tmp_path,
        monkeypatch,
        cases={
            "first": {"ok": True, "output": converted_graph(1)},
            "middle": {
                "ok": False,
                "name": "InvalidLinkError",
                "message": "No link found in parent graph for id [1] slot [0]",
            },
            "last": {"ok": True, "output": converted_graph(3)},
        },
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    seen = states(report)
    assert seen["first.json"] == "NEW"
    assert seen["last.json"] == "NEW"
    assert seen["middle.json"] == "NEEDS_API_EXPORT"

    failed = by_relative(report)["middle.json"]
    assert failed.conversion.category == CATEGORY_CONVERSION_REJECTED
    assert "InvalidLinkError" in failed.reason
    assert failed.definition is None, "a refused workflow got a definition"

    # No API JSON exists for it anywhere: not an imported graph, not a cached
    # snapshot, not a definition.
    written = workspace.output_names()
    assert not any("middle" in name for name in written), written
    assert [name for name in cache_files(workspace)], "nothing was cached at all"
    assert len(cache_files(workspace)) == 2, cache_files(workspace)


def test_a_graph_comfyui_could_not_make_usable_writes_nothing(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The measured shape: converted, and still not a runnable graph."""

    folder = workspace.add_source()
    write_json(folder / "unknown node.json", ui_graph("one"))
    workspace.write_config()

    browser = Browser(
        tmp_path,
        monkeypatch,
        default={"ok": True, "output": {"1": {"inputs": {"UNKNOWN": "x"}}}},
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["unknown node.json"]
    assert item.state.value == "NEEDS_API_EXPORT"
    assert item.conversion.category == CATEGORY_NOT_IMPORTABLE
    assert item.definition is None
    assert cache_files(workspace) == [], "a failed conversion was cached"
    assert (workspace.output_tree / "imported-workflows").exists() is False


def test_the_command_stops_the_browser_however_the_run_ends(
    workspace: SyncWorkspace, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The product path, which is not the one the other tests take.

    Everything else here uses ``make_bridge`` as a context manager, and the
    product does not: ``cli.main`` builds the bridge and closes it in a
    ``finally``. That ``finally`` is the only thing that stops the browser and
    removes the temporary profile when the command is what runs -- two things
    `docs/privacy-security.md` requires -- and deleting it left the whole suite
    green.

    Both endings, because a bridge left open by the failing path is the one
    that would go unnoticed: a run that succeeds, and a run whose engine
    raises after the bridge exists.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    closed: List[str] = []

    class Recording:
        def __init__(self, comfy_url, **kwargs):  # noqa: ARG002
            self.comfy_url = comfy_url

        def ensure_identity(self):
            from localcanvas_gateway.workflows.sync.bridge import (  # noqa: PLC0415
                ComfyIdentity,
            )

            return ComfyIdentity.build(
                comfyui_version="x", frontend_version="y", node_types=["A"]
            )

        def convert(self, raw, *, content_hash):  # noqa: ARG002
            from localcanvas_gateway.workflows.sync.bridge import (  # noqa: PLC0415
                Conversion,
            )

            return Conversion(
                status=ConversionStatus.CONVERTED, document=converted_graph()
            )

        def close(self):
            closed.append("closed")

    monkeypatch.setattr(cli, "ConversionBridge", Recording)

    code = cli.main(
        [
            "--config", str(workspace.config_path),
            "--comfy-url", "http://127.0.0.1:1",
        ],
        out=io.StringIO(),
        err=io.StringIO(),
    )
    assert code in (0, 1), code
    assert closed == ["closed"], "the command left the browser running"

    # The other ending. `run_sync` raising is how a fatal configuration
    # problem surfaces, and it happens after the bridge has been built.
    def explode(*args, **kwargs):
        raise SyncConfigError("the inventory could not be written")

    closed.clear()
    monkeypatch.setattr(cli, "run_sync", explode)
    code = cli.main(
        [
            "--config", str(workspace.config_path),
            "--comfy-url", "http://127.0.0.1:1",
        ],
        out=io.StringIO(),
        err=io.StringIO(),
    )
    assert code == cli.EXIT_FATAL
    assert closed == ["closed"], "a failing run left the browser running"


def test_a_failure_that_carries_a_graph_anyway_still_writes_nothing(
    workspace: SyncWorkspace,
) -> None:
    """The engine's own gate, proved without the bridge's.

    Two guards protect "a failed conversion produces no API JSON": the bridge
    refuses to return a graph it could not validate, and the engine writes only
    for a status that succeeded. Each has to fail a test on its own, or the
    second could be removed without anything noticing.

    So this hands the engine a result that is contradictory on purpose -- a
    failure with a graph attached, which the real bridge never produces -- and
    the engine must still write nothing. The bridge's half is held against the
    real boundary in ``test_sync_bridge.py``.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    class Contradictory:
        """A bridge whose failures come with a graph. Nothing else does this."""

        identity = None

        def ensure_identity(self):
            from localcanvas_gateway.workflows.sync.bridge import (  # noqa: PLC0415
                ComfyIdentity,
            )

            return ComfyIdentity.build(
                comfyui_version="x", frontend_version="y", node_types=["A"]
            )

        def convert(self, raw, *, content_hash):  # noqa: ARG002
            from localcanvas_gateway.workflows.sync.bridge import (  # noqa: PLC0415
                Conversion,
            )

            return Conversion(
                status=ConversionStatus.FAILED,
                document=converted_graph(1),
                category=CATEGORY_NOT_IMPORTABLE,
                detail="refused, and yet here is a graph",
            )

        def close(self):
            pass

    report = run_sync(workspace.load(), bridge=Contradictory())

    item = by_relative(report)["a canvas.json"]
    assert item.state.value == "NEEDS_API_EXPORT"
    assert item.definition is None
    assert cache_files(workspace) == [], "a failed conversion was cached"
    assert not (workspace.output_tree / "imported-workflows").exists()
    assert not (workspace.output_tree / "workflows").exists()


def test_an_unreachable_comfyui_reports_every_canvas_and_imports_the_rest(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The actionable state, and the API exports beside it still import.

    A ComfyUI that is not running is not a reason to stop the run: the
    workflows that need nothing from it are none the worse.
    """

    with FakeComfy() as running:
        dead_url = running.base_url

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    write_json(folder / "already exported.json", API_GRAPH)
    workspace.write_config()

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    launcher = CountingPopen()
    with make_bridge(dead_url, browser, popen=launcher) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    seen = states(report)
    assert seen["already exported.json"] == "NEW"
    assert seen["a canvas.json"] == "NEEDS_API_EXPORT"

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.UNAVAILABLE
    assert item.conversion.category == CATEGORY_COMFY_UNREACHABLE
    assert "scripts\\start.ps1" in item.reason
    assert "nothing was guessed" in item.reason
    assert launcher.count == 0
    # And nothing was invented for it: the only definition written belongs to
    # the file that was already an API export.
    definitions = sorted(
        path.name for path in (workspace.output_tree / "workflows").glob("*.yaml")
    )
    assert definitions == ["already-exported.yaml"]


# ==========================================================================
# Reuse without staleness
# ==========================================================================


def test_an_unchanged_source_reuses_its_snapshot_and_launches_no_browser(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The second run costs two HTTP requests and no browser at all.

    That is the whole reason the ComfyUI identity is read over HTTP rather than
    out of the page: a run with nothing new to convert must not pay for a
    browser to find that out.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    first = Browser(
        tmp_path / "first",
        monkeypatch,
        default={"ok": True, "output": converted_graph(5)},
    )
    launcher = CountingPopen()
    with make_bridge(comfy.base_url, first, popen=launcher) as bridge:
        run_sync(workspace.load(), bridge=bridge)
    assert launcher.count == 1, "the first run did not launch a browser"
    assert len(cache_files(workspace)) == 1

    second = Browser(
        tmp_path / "second",
        monkeypatch,
        default={"ok": True, "output": converted_graph(999)},
    )
    again = CountingPopen()
    with make_bridge(comfy.base_url, second, popen=again) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.REUSED
    assert item.state.value == "UNCHANGED"
    assert again.count == 0, "the second run launched a browser anyway"
    # The remembered conversion was used, not the new browser's answer -- which
    # was deliberately different, so the two cannot be confused.
    imported = sorted((workspace.output_tree / "imported-workflows").glob("*.json"))
    graph = json.loads(imported[0].read_text(encoding="utf-8"))
    assert graph["20"]["inputs"]["seed"] == 5


def test_a_changed_source_is_converted_again(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Edit the canvas and the remembered conversion stops applying."""

    folder = workspace.add_source()
    source = folder / "a canvas.json"
    write_json(source, ui_graph("one", seed=1))
    workspace.write_config()

    first = Browser(
        tmp_path / "first",
        monkeypatch,
        default={"ok": True, "output": converted_graph(11)},
    )
    with make_bridge(comfy.base_url, first) as bridge:
        run_sync(workspace.load(), bridge=bridge)

    write_json(source, ui_graph("one", seed=2))

    second = Browser(
        tmp_path / "second",
        monkeypatch,
        default={"ok": True, "output": converted_graph(22)},
    )
    launcher = CountingPopen()
    with make_bridge(comfy.base_url, second, popen=launcher) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.CONVERTED
    assert item.state.value == "CHANGED"
    assert launcher.count == 1
    assert len(cache_files(workspace)) == 2, "the old snapshot was overwritten"
    seeds = {
        json.loads(path.read_text(encoding="utf-8"))["20"]["inputs"]["seed"]
        for path in (workspace.output_tree / "imported-workflows").glob("*.json")
    }
    assert seeds == {11, 22}


def test_a_different_comfyui_is_converted_again(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Install a custom node and every remembered conversion stops applying.

    The identity is what makes this true, and the node set is the half of it
    that moves without a version number moving: a graph converted against a
    ComfyUI that has since gained or lost node classes was converted against
    definitions that are no longer there.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    with FakeComfy() as comfy:
        first = Browser(
            tmp_path / "first",
            monkeypatch,
            default={"ok": True, "output": converted_graph(11)},
        )
        with make_bridge(comfy.base_url, first) as bridge:
            run_sync(workspace.load(), bridge=bridge)
        assert len(cache_files(workspace)) == 1

        # The same ComfyUI, one custom node later.
        comfy.installed_nodes = ("SomeNewlyInstalledNode",)
        second = Browser(
            tmp_path / "second",
            monkeypatch,
            default={"ok": True, "output": converted_graph(22)},
        )
        launcher = CountingPopen()
        with make_bridge(comfy.base_url, second, popen=launcher) as bridge:
            report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.CONVERTED
    assert launcher.count == 1, "the stale snapshot was reused"
    assert len(cache_files(workspace)) == 2


def test_a_cache_that_cannot_be_written_warns_and_costs_only_speed(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The conversion happened; only remembering it did not.

    Constructed rather than simulated: a plain file sits where the cache
    directory would go, so creating it really fails. The workflow must still be
    imported -- a cache is an optimisation and its failure is not the run's --
    and the complaint must be a warning about this run rather than a note
    written on to the entry, which would be kept for ever as though a curator
    had typed it.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    imported = workspace.output_tree / "imported-workflows"
    imported.mkdir(parents=True, exist_ok=True)
    (imported / "converted").write_text("not a directory", encoding="utf-8")

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.CONVERTED
    assert item.definition is not None and item.definition.written
    assert item.state.value == "NEW"

    assert len(report.warnings) == 1, report.warnings
    assert "a canvas.json" in report.warnings[0]
    assert "converted again next time" in report.warnings[0]
    entry = workspace.read_inventory()["workflows"][0]
    assert "conversion_cache_problem" not in entry
    assert sorted(entry) == [
        "aliases",
        "canonical_hash",
        "content_hash",
        "conversion",
        "first_seen",
        "format",
        "generated_fingerprint",
        "generated_help",
        "generated_labels",
        "generated_presentation",
        "generated_with_contract",
        "id",
        "last_seen",
        "reason",
        "size_bytes",
        "source_path",
        "source_relative",
        "source_root",
        "state",
    ]


def test_a_snapshot_that_does_not_match_its_own_record_is_not_trusted(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Edit the cache by hand and it becomes a miss, never a wrong import.

    Three ways of tampering, each of which a name-only check would miss: a
    graph swapped inside the record, a record claiming different source bytes,
    and a record copied under another key's file name.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    browser = Browser(
        tmp_path / "first",
        monkeypatch,
        default={"ok": True, "output": converted_graph(11)},
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        run_sync(workspace.load(), bridge=bridge)

    cached = cache_directory(workspace.load().output) / cache_files(workspace)[0]
    record = json.loads(cached.read_text(encoding="utf-8"))
    record["api"]["20"]["inputs"]["seed"] = 4242  # the hash no longer matches
    cached.write_text(json.dumps(record), encoding="utf-8")

    second = Browser(
        tmp_path / "second",
        monkeypatch,
        default={"ok": True, "output": converted_graph(11)},
    )
    launcher = CountingPopen()
    with make_bridge(comfy.base_url, second, popen=launcher) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.CONVERTED
    assert launcher.count == 1, "a snapshot that fails its own hash was reused"
    assert item.conversion.document["20"]["inputs"]["seed"] == 11


def test_a_snapshot_from_another_comfyui_renamed_into_place_is_refused(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The identity is checked in the file's content, not only in its name.

    Two guards keep a stale conversion out: the snapshot is *looked up* under a
    name containing the ComfyUI identity, and the record inside it is checked
    against that identity when it is read. The first alone would be enough
    until somebody copies a file, so the second has to fail a test on its own
    -- which is what this constructs, by putting a snapshot made against one
    ComfyUI exactly where a snapshot made against another belongs.
    """

    folder = workspace.add_source()
    source = folder / "a canvas.json"
    write_json(source, ui_graph("one"))
    workspace.write_config()

    with FakeComfy() as comfy:
        first = Browser(
            tmp_path / "first",
            monkeypatch,
            default={"ok": True, "output": converted_graph(11)},
        )
        with make_bridge(comfy.base_url, first) as bridge:
            run_sync(workspace.load(), bridge=bridge)
        stale = cache_directory(workspace.load().output) / cache_files(workspace)[0]
        stale_bytes = stale.read_bytes()

        comfy.installed_nodes = ("SomeNewlyInstalledNode",)
        second = Browser(
            tmp_path / "second",
            monkeypatch,
            default={"ok": True, "output": converted_graph(22)},
        )
        with make_bridge(comfy.base_url, second) as bridge:
            run_sync(workspace.load(), bridge=bridge)

        # The name the *new* ComfyUI's snapshot lives under, with the old
        # ComfyUI's content put into it.
        fresh = [name for name in cache_files(workspace) if name != stale.name]
        assert len(fresh) == 1, cache_files(workspace)
        target = cache_directory(workspace.load().output) / fresh[0]
        target.write_bytes(stale_bytes)

        third = Browser(
            tmp_path / "third",
            monkeypatch,
            default={"ok": True, "output": converted_graph(33)},
        )
        launcher = CountingPopen()
        with make_bridge(comfy.base_url, third, popen=launcher) as bridge:
            report = run_sync(workspace.load(), bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.CONVERTED
    assert item.conversion.document["20"]["inputs"]["seed"] == 33
    assert launcher.count == 1, "a snapshot from another ComfyUI was believed"


def test_a_snapshot_renamed_to_another_key_is_refused(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """The file name is how it is found; the content is why it is believed."""

    folder = workspace.add_source()
    first_source = folder / "first.json"
    second_source = folder / "second.json"
    write_json(first_source, ui_graph("first"))
    write_json(second_source, ui_graph("second"))
    workspace.write_config()

    browser = Browser(
        tmp_path / "first",
        monkeypatch,
        cases={
            "first": {"ok": True, "output": converted_graph(1)},
            "second": {"ok": True, "output": converted_graph(2)},
        },
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        run_sync(workspace.load(), bridge=bridge)

    config = workspace.load()
    identity_digest = None
    folder_path = cache_directory(config.output)
    for path in folder_path.iterdir():
        identity_digest = json.loads(path.read_text(encoding="utf-8"))["comfy"]["digest"]
    assert identity_digest

    # Put the first workflow's snapshot where the second's belongs.
    first_path = snapshot_path(
        config.output,
        source_hash=content_hash(first_source.read_bytes()),
        identity_digest=identity_digest,
    )
    second_path = snapshot_path(
        config.output,
        source_hash=content_hash(second_source.read_bytes()),
        identity_digest=identity_digest,
    )
    second_path.write_bytes(first_path.read_bytes())

    again = Browser(
        tmp_path / "second",
        monkeypatch,
        cases={
            "first": {"ok": True, "output": converted_graph(1)},
            "second": {"ok": True, "output": converted_graph(2)},
        },
    )
    launcher = CountingPopen()
    with make_bridge(comfy.base_url, again, popen=launcher) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    reused = by_relative(report)
    assert reused["first.json"].conversion.status is ConversionStatus.REUSED
    assert reused["second.json"].conversion.status is ConversionStatus.CONVERTED
    assert reused["second.json"].conversion.document["20"]["inputs"]["seed"] == 2
    assert launcher.count == 1


# ==========================================================================
# A dry run persists nothing
# ==========================================================================


def test_a_dry_run_converts_and_still_writes_nothing(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """It says what would import, and leaves the disk exactly as it was.

    The second half is what makes the first mean anything: the same tree with
    the same bridge, run for real, writes an inventory, a definition, an
    imported graph and a snapshot. So the dry run had every opportunity to
    write each of those and took none of them.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()

    before = workspace.output_snapshot()
    browser = Browser(
        tmp_path / "dry", monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), dry_run=True, bridge=bridge)

    item = by_relative(report)["a canvas.json"]
    assert item.conversion.status is ConversionStatus.CONVERTED, (
        "the dry run did not convert, so it cannot have said what would import"
    )
    assert item.state.value == "NEW"
    assert item.definition is not None and not item.definition.written
    assert workspace.output_snapshot() == before, workspace.output_snapshot()
    assert cache_files(workspace) == []
    # And it says so, rather than leaving "1 converted" to be read as a write.
    document = report_document(report)
    assert document["conversion"]["counts"]["converted"] == 1
    assert document["conversion"]["notice"] == DRY_RUN_CONVERSION_NOTICE

    real = Browser(
        tmp_path / "real", monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, real) as bridge:
        run_sync(workspace.load(), bridge=bridge)

    after = workspace.output_snapshot()
    assert after != before
    assert len(cache_files(workspace)) == 1, "a real run cached nothing either"
    assert sorted(after) != sorted(before)


def test_a_dry_run_leaves_a_previous_snapshot_alone(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Reading the cache is not writing to it, and neither is missing it."""

    folder = workspace.add_source()
    source = folder / "a canvas.json"
    write_json(source, ui_graph("one"))
    workspace.write_config()

    browser = Browser(
        tmp_path / "real", monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        run_sync(workspace.load(), bridge=bridge)
    after_real = workspace.output_snapshot()

    write_json(source, ui_graph("one", seed=9))
    dry = Browser(
        tmp_path / "dry", monkeypatch, default={"ok": True, "output": converted_graph(9)}
    )
    with make_bridge(comfy.base_url, dry) as bridge:
        report = run_sync(workspace.load(), dry_run=True, bridge=bridge)

    assert by_relative(report)["a canvas.json"].conversion.status is (
        ConversionStatus.CONVERTED
    )
    assert workspace.output_snapshot() == after_real


# ==========================================================================
# Duplicates, and the provenance that survives them
# ==========================================================================


def test_two_identical_canvases_are_converted_once_and_each_is_recorded(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    write_json(folder / "the same canvas.json", ui_graph("one"))
    workspace.write_config()

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    seen = states(report)
    assert sorted(seen.values()) == ["EXACT_DUPLICATE", "NEW"]
    conversions = [
        item for item in browser.saw()["expressions"] if item.startswith("convert")
    ]
    assert len(conversions) == 1, conversions

    # One entry, and the other file recorded on it as an alias with its own
    # path and its own hash -- so neither source has been forgotten.
    entries = workspace.read_inventory()["workflows"]
    assert len(entries) == 1
    assert len(entries[0]["aliases"]) == 1
    assert entries[0]["aliases"][0]["source_path"].endswith("the same canvas.json")
    assert entries[0]["conversion"]["status"] == "converted"

    # A FIRST run must not tell anybody something was "reused from an earlier
    # run": there was no earlier run. Both files were converted in this one --
    # once, between them -- and that is what the counts and the sentence say.
    document = report_document(report)
    assert document["conversion"]["counts"] == {
        "converted": 2,
        "reused": 0,
        "failed": 0,
        "unavailable": 0,
    }
    assert "2 converted by ComfyUI (0 reused from an earlier run)" in document["summary"]

    # One snapshot, written by the first of the two and not rewritten by the
    # second -- otherwise its recorded source would be whichever file the scan
    # happened to reach last, and the cache would differ between two runs over
    # the same folder.
    assert len(cache_files(workspace)) == 1
    cached = cache_directory(workspace.load().output) / cache_files(workspace)[0]
    first_bytes = cached.read_bytes()
    assert json.loads(first_bytes)["source_relative"] == "a canvas.json"

    again = Browser(
        tmp_path / "again",
        monkeypatch,
        default={"ok": True, "output": converted_graph()},
    )
    launcher = CountingPopen()
    with make_bridge(comfy.base_url, again, popen=launcher) as bridge:
        second = run_sync(workspace.load(), bridge=bridge)
    assert cached.read_bytes() == first_bytes
    # And the second run is where "reused from an earlier run" becomes true.
    assert report_document(second)["conversion"]["counts"] == {
        "converted": 0,
        "reused": 2,
        "failed": 0,
        "unavailable": 0,
    }
    assert launcher.count == 0


def test_two_identical_canvases_that_are_refused_are_two_refusals(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """A broken workflow is never hidden behind a copy of itself.

    The existing principle, applied to the new stage: grouping identical bytes
    before asking ComfyUI about them would have reported one problem where
    there are two files to fix.
    """

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    write_json(folder / "the same canvas.json", ui_graph("one"))
    workspace.write_config()

    browser = Browser(
        tmp_path,
        monkeypatch,
        default={"ok": False, "name": "InvalidLinkError", "message": "no link"},
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    seen = states(report)
    assert sorted(seen) == ["a canvas.json", "the same canvas.json"]
    assert set(seen.values()) == {"NEEDS_API_EXPORT"}
    for item in report.workflows:
        assert item.conversion.category == CATEGORY_CONVERSION_REJECTED
        assert "InvalidLinkError" in item.reason
    assert len(workspace.read_inventory()["workflows"]) == 2


# ==========================================================================
# Provenance
# ==========================================================================


def test_the_inventory_records_how_each_graph_was_obtained(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Key by key, and null for a file that needed no conversion at all."""

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    write_json(folder / "already exported.json", API_GRAPH)
    workspace.write_config()

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        run_sync(workspace.load(), bridge=bridge)

    entries = {
        entry["id"]: entry for entry in workspace.read_inventory()["workflows"]
    }
    assert entries["already-exported"]["conversion"] is None

    conversion = entries["a-canvas"]["conversion"]
    assert sorted(conversion) == ["category", "comfy", "detail", "status"]
    assert conversion["status"] == "converted"
    assert conversion["category"] is None
    assert conversion["detail"] is None
    assert sorted(conversion["comfy"]) == [
        "comfyui_version",
        "digest",
        "frontend_version",
        "node_type_count",
    ]
    assert conversion["comfy"]["comfyui_version"] == "fake"
    assert conversion["comfy"]["digest"].startswith("sha256:")


def test_the_snapshot_on_disk_says_where_it_came_from(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    folder = workspace.add_source()
    source = folder / "a canvas.json"
    write_json(source, ui_graph("one"))
    workspace.write_config()

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        run_sync(workspace.load(), bridge=bridge)

    cached = cache_directory(workspace.load().output) / cache_files(workspace)[0]
    record = json.loads(cached.read_text(encoding="utf-8"))
    assert sorted(record) == [
        "api",
        "api_content_hash",
        "comfy",
        "converted_at",
        "snapshot_version",
        "source_content_hash",
        "source_path",
        "source_relative",
    ]
    assert record["source_path"] == str(source)
    assert record["source_relative"] == "a canvas.json"
    assert record["source_content_hash"] == content_hash(source.read_bytes())
    assert record["api"]["10"]["_meta"]["produced_by"] == browser.saw()["nonce"]


def test_the_report_says_what_was_converted_and_by_what(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    write_json(folder / "refused.json", ui_graph("bad"))
    write_json(folder / "already exported.json", API_GRAPH)
    workspace.write_config()

    browser = Browser(
        tmp_path,
        monkeypatch,
        cases={
            "one": {"ok": True, "output": converted_graph()},
            "bad": {"ok": False, "name": "InvalidLinkError", "message": "no link"},
        },
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    document = report_document(report)
    assert document["conversion"]["counts"] == {
        "converted": 1,
        "reused": 0,
        "failed": 1,
        "unavailable": 0,
    }
    assert document["conversion"]["comfy"]["comfyui_version"] == "fake"
    per_workflow = {item["source_relative"]: item for item in document["workflows"]}
    assert per_workflow["already exported.json"]["conversion"] is None
    assert per_workflow["a canvas.json"]["conversion"]["status"] == "converted"
    assert per_workflow["refused.json"]["conversion"] == {
        "status": "failed",
        "category": CATEGORY_CONVERSION_REJECTED,
        "detail": per_workflow["refused.json"]["conversion"]["detail"],
        "comfy": per_workflow["refused.json"]["conversion"]["comfy"],
    }
    assert "1 converted by ComfyUI (0 reused from an earlier run)" in document["summary"]
    assert "1 not converted" in document["summary"]


def test_a_registry_of_api_exports_never_touches_comfyui(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
    comfy: FakeComfy,
) -> None:
    """Nothing to convert, nothing asked, nothing launched.

    The capability costs a user who does not need it exactly nothing -- not a
    browser, not an HTTP request, not a line in the report about a ComfyUI they
    were not using.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "two.json", api_graph(2))
    workspace.write_config()

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    launcher = CountingPopen()
    with make_bridge(comfy.base_url, browser, popen=launcher) as bridge:
        report = run_sync(workspace.load(), bridge=bridge)

    assert sorted(states(report).values()) == ["NEW", "NEW"]
    assert launcher.count == 0
    assert comfy.requests == []
    assert report_document(report)["conversion"] == {
        "counts": {"converted": 0, "reused": 0, "failed": 0, "unavailable": 0},
        "notice": None,
        "comfy": None,
    }
