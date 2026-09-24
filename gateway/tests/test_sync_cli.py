"""The command surface ``scripts/sync-workflows.ps1`` consumes.

The engine is reached as a subcommand of the offline validator that was already
there, so the first thing this file holds is that the validator still behaves
exactly as it did.  The rest is the seam itself: one JSON document on stdout,
three exit codes, a failure the front end can print without rewording, and a
document that survives the trip across a Windows pipe.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from localcanvas_gateway.workflows.cli import main as module_main
from localcanvas_gateway.workflows.sync import DRY_RUN_NOTICE, DRY_RUN_NOTICE_ASCII
from localcanvas_gateway.workflows.sync.cli import main as sync_main
from sync_fixtures import UI_GRAPH, SyncWorkspace, api_graph, write_json

GATEWAY_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def run(*argv, entry=sync_main):
    out, err = io.StringIO(), io.StringIO()
    code = entry([str(item) for item in argv], out=out, err=err)
    return code, out.getvalue(), err.getvalue()


def run_module(*argv):
    out, err = io.StringIO(), io.StringIO()
    code = module_main([str(item) for item in argv], stream=out, err=err)
    return code, out.getvalue(), err.getvalue()


# ==========================================================================
# The existing command is untouched
# ==========================================================================


def test_the_offline_validator_still_takes_a_bare_registry_root(builder) -> None:
    """The pre-change behaviour, validated against the pre-change invocation.

    Adding a subcommand to a command whose only argument is a positional path
    is exactly how a working invocation stops working, so this is asserted on
    the old form rather than inferred from the new one.
    """

    from conftest import PROMPT_FIELD

    builder.add("one", PROMPT_FIELD, workflow_id="one")

    code, output, _ = run_module(builder.root)

    assert code == 0
    assert "[ OK ] one" in output
    assert "1 workflow loaded, 0 rejected" in output


def test_the_subcommand_word_is_the_only_thing_that_diverts(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()

    code, output, _ = run_module("sync", "--config", workspace.config_path)

    assert code == 0
    assert json.loads(output)["sync_report_version"] == 1


# ==========================================================================
# The seam
# ==========================================================================


def test_a_clean_run_prints_one_json_document_and_exits_zero(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()

    code, output, errors = run("--config", workspace.config_path)

    document = json.loads(output)
    assert code == 0
    assert errors == ""
    assert document["dry_run"] is False
    assert document["notice"] is None
    assert document["inventory"]["written"] is True
    assert [item["state"] for item in document["workflows"]] == ["NEW"]
    assert document["counts"]["NEW"] == 1
    assert document["attention"] == []


def test_a_workflow_that_needs_attention_exits_one(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "editor.json", UI_GRAPH)
    workspace.write_config()

    code, output, _ = run("--config", workspace.config_path)

    document = json.loads(output)
    assert code == 1
    assert [item["state"] for item in document["attention"]] == ["NEEDS_API_EXPORT"]
    assert "Workflow -> Export (API)" in document["attention"][0]["reason"]


def test_a_missing_config_exits_two_with_a_fail_block_on_stderr(
    workspace: SyncWorkspace,
) -> None:
    missing = workspace.repo / "config" / "local" / "not there.yaml"

    code, output, errors = run("--config", missing)

    assert code == 2
    assert output == "", "a fatal failure must not print half a document"
    lines = errors.splitlines()
    assert lines[0].startswith("[FAIL] ")
    assert str(missing) in lines[0]
    assert any("workflow-sources.example.yaml" in line for line in lines)
    assert all(line.startswith(("[FAIL] ", "       ")) for line in lines), lines


def test_an_unreadable_source_root_exits_two_and_is_not_a_workflow_problem(
    workspace: SyncWorkspace,
) -> None:
    """The split the design asks for, seen from outside.

    A folder that cannot be read stops the run with code 2; a file inside a
    folder that cannot be parsed is code 1 with the rest of the run intact.
    Same command, two clearly different answers.
    """

    workspace.write_config(sources=[workspace.base / "no such folder"])
    fatal, _, errors = run("--config", workspace.config_path)

    folder = workspace.add_source()
    (folder / "broken.json").write_text("{ nope", encoding="utf-8")
    write_json(folder / "fine.json", api_graph(1))
    workspace.write_config()
    per_workflow, output, _ = run("--config", workspace.config_path)

    assert fatal == 2
    assert "does not exist" in errors
    assert per_workflow == 1
    assert sorted(
        item["state"] for item in json.loads(output)["workflows"]
    ) == ["INVALID", "NEW"]


def test_the_dry_run_notice_travels_in_the_document(workspace: SyncWorkspace) -> None:
    """The exact sentence, defined once and asserted verbatim.

    Spelled out here rather than compared with the constant alone, so that a
    change to the constant fails a test instead of quietly redefining the
    contract the script prints.
    """

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()

    code, output, _ = run("--config", workspace.config_path, "--dry-run")

    document = json.loads(output)
    assert code == 0
    assert document["dry_run"] is True
    assert document["notice"] == "Dry run — no files changed."
    assert document["notice"] == DRY_RUN_NOTICE
    assert document["notice_ascii"] == "Dry run - no files changed."
    assert document["notice_ascii"] == DRY_RUN_NOTICE_ASCII
    assert document["notice_ascii"].isascii()
    # Two forms of one sentence, not two sentences: they differ in exactly one
    # character. The second exists because a Windows console is commonly cp437,
    # cp866 or cp1251 and has no em dash at all, and this repository decided
    # once -- for the pairing QR -- that the text adapts to the stream and never
    # the other way round. Both forms are decided here, in Python; the front end
    # only chooses between them.
    assert document["notice"].replace("—", "-") == document["notice_ascii"]
    assert document["inventory"]["written"] is False
    assert not workspace.inventory_path.exists()


def test_a_run_that_is_not_a_dry_one_carries_neither_form(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    workspace.write_config()

    _, output, _ = run("--config", workspace.config_path)
    document = json.loads(output)

    assert document["notice"] is None
    assert document["notice_ascii"] is None


def test_the_report_is_pure_ascii_on_the_wire(workspace: SyncWorkspace) -> None:
    """The document crosses a pipe into PowerShell, which decodes by code page.

    ``ensure_ascii`` is what makes that harmless: the em dash leaves here as
    ``\\u2014`` and is turned back into a character by ``ConvertFrom-Json``.
    Without it the same six bytes would arrive as mojibake on a console that is
    not set to UTF-8, and the one sentence the contract spells out would be
    wrong on exactly the machines this ships to.
    """

    folder = workspace.add_source()
    write_json(folder / "été workflow.json", api_graph(1))
    workspace.write_config()

    _, output, _ = run("--config", workspace.config_path, "--dry-run")

    assert "\\u2014" in output, "the notice was not escaped"
    assert output.isascii(), [ch for ch in output if not ch.isascii()][:10]
    assert json.loads(output)["notice"] == DRY_RUN_NOTICE


def test_the_document_names_its_own_shape_version(workspace: SyncWorkspace) -> None:
    workspace.add_source()
    workspace.write_config()

    _, output, _ = run("--config", workspace.config_path)
    document = json.loads(output)

    # Asserted key by key rather than by counting them: a shape refactor that
    # renamed one would keep the count and break the script.
    assert sorted(document) == [
        "attention",
        "config",
        "conversion",
        "counts",
        "definitions",
        "dry_run",
        "generated",
        "inventory",
        "notice",
        "notice_ascii",
        "repo_root",
        "runtime_contract",
        "sources",
        "summary",
        "sync_report_version",
        "unconverted_editor",
        "warnings",
        "workflows",
    ]
    assert sorted(document["counts"]) == [
        "CHANGED",
        "EXACT_DUPLICATE",
        "INVALID",
        "NEEDS_API_EXPORT",
        "NEEDS_REVIEW",
        "NEW",
        "REMOVED_FROM_SOURCE",
        "UNCHANGED",
        "UNSUPPORTED_INPUT",
    ]
    assert sorted(document["inventory"]) == ["path", "written"]
    assert sorted(document["definitions"]) == ["failed", "path", "written"]


def test_the_summary_is_one_line_a_person_can_read(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "editor.json", UI_GRAPH)
    workspace.write_config()

    _, output, _ = run("--config", workspace.config_path)
    summary = json.loads(output)["summary"]

    assert "\n" not in summary
    assert summary == (
        "2 workflows found, 1 importable (1 new, 0 changed, 0 unchanged), "
        "1 definition written, 1 needs attention."
    )


# ==========================================================================
# As an installed module, on a command line, with spaces everywhere
# ==========================================================================


def test_the_sync_runs_as_a_module_with_spaces_in_every_path(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source("a folder with spaces")
    write_json(folder / "a workflow with spaces.json", api_graph(1))
    workspace.write_config()

    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "localcanvas_gateway.workflows",
            "sync",
            "--config",
            str(workspace.config_path),
            "--dry-run",
        ],
        capture_output=True,
        text=True,
        encoding="ascii",
        env={**os.environ, "PYTHONPATH": str(GATEWAY_ROOT)},
        timeout=180,
    )

    assert result.returncode == 0, result.stderr
    document = json.loads(result.stdout)
    assert document["workflows"][0]["source_relative"] == "a workflow with spaces.json"
    assert document["notice"] == DRY_RUN_NOTICE
