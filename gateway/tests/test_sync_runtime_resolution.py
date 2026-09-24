"""Which ``runtime.yaml`` a sync run reads, and why it is never a surprise.

``sync/cli.py`` used to resolve ``config/local/runtime.yaml`` from wherever the
process happened to be standing, independently of the ``--config`` the caller
passed.  A run that named its own configuration was therefore still changed by
a file nobody named -- and because the file in question is gitignored, the
whole thing was invisible in a worktree and only appeared in the one checkout
that has a ``config/local/``.  That is T-0107.

**Every test in this file therefore builds the condition rather than inheriting
it.**  A repository-root-relative runtime configuration is *written* into a
temporary directory the run is made to stand in, so the hostile case exists on
every machine, in a worktree as much as in the main checkout.  A guard
that could not fail here would be the very defect it is guarding against.

Two further habits, both deliberate:

* **nothing in this file may reach a network.**  ``ConversionBridge`` is
  replaced by a recorder that notes the endpoint it was handed and then refuses
  to open anything.  A test whose verdict depends on whether ComfyUI happens to
  be running is not a gate, and that is half of what went wrong here.
* **no summary string is asserted for a run that found a runtime.**  Where a
  bridge exists the answer legitimately depends on what that bridge did, so
  those runs are compared with *each other* and never with a literal.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List

import pytest

from localcanvas_gateway import config as gateway_config
from localcanvas_gateway.workflows.sync import cli as sync_cli
from localcanvas_gateway.workflows.sync.cli import (
    RUNTIME_CONFIG_FILENAME,
    RUNTIME_CONFIG_RELATIVE_PATH,
    main as sync_main,
    runtime_config_path,
)
from localcanvas_gateway.workflows.sync.config import CONFIG_RELATIVE_PATH
from sync_fixtures import UI_GRAPH, SyncWorkspace, api_graph, write_json

#: The loader as it is before any test patches it, so a precondition check can
#: prove a fixture is loadable without being counted as a run's own reading.
LOAD_CONFIG = gateway_config.load_config

#: Two endpoints that cannot be mistaken for one another.  Which one a run ends
#: up holding is the whole question, so they differ in the port and the answer
#: names the file it came from.
ROOT_PORT = 8191
BESIDE_PORT = 8192
ELSEWHERE_PORT = 8193

ROOT_ENDPOINT = "http://127.0.0.1:{}".format(ROOT_PORT)
BESIDE_ENDPOINT = "http://127.0.0.1:{}".format(BESIDE_PORT)
ELSEWHERE_ENDPOINT = "http://127.0.0.1:{}".format(ELSEWHERE_PORT)


# ==========================================================================
# Fixtures: the condition, built rather than inherited
# ==========================================================================


def write_runtime(path: Path, *, port: int, comfy_root: Path) -> Path:
    """A complete, valid ``runtime.yaml`` whose endpoint identifies it.

    Written out here rather than borrowed from another test module: what makes
    this fixture useful is that two of them differ in exactly one value, and
    that is a property this file has to own.
    """

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                "runtime:",
                "  manage_comfy: false",
                "comfy:",
                '  root: "{}"'.format(str(comfy_root).replace("\\", "/")),
                '  host: "127.0.0.1"',
                "  port: {}".format(port),
                "  launcher:",
                '    executable: "python_embeded/python.exe"',
                '    script: "ComfyUI/main.py"',
                "workflows:",
                '  registry: "workflows/examples"',
                "gateway:",
                '  host: "0.0.0.0"',
                "  port: 7801",
                "identity:",
                '  display_name: "A Placeholder Name"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    return path


def write_sources(path: Path, *, source: Path) -> Path:
    """A sources configuration in the shipped shape, at ``path``."""

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                "sources:",
                '  - path: "{}"'.format(str(source).replace("\\", "/")),
                "    recursive: true",
                "output:",
                '  definitions: "config/local/workflows"',
                '  imported_api: "config/local/imported-workflows"',
                '  inventory: "config/local/workflow-inventory.json"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    return path


class RecordedBridge:
    """Everything a run asks of a bridge, and not one byte on the wire.

    ``ensure_identity`` refuses, which is precisely what the real one does when
    there is no ComfyUI to reach, so a run that built a bridge still produces a
    complete report -- and produces the *same* one on every machine, which the
    real bridge cannot promise.  ``convert`` is never reached after an identity
    failure (`engine.py`), so it is not offered at all: a call to it would be a
    test asserting something this file does not model.
    """

    def __init__(self, comfy_url: str) -> None:
        self.comfy_url = comfy_url
        self.closed = False

    def ensure_identity(self):
        raise RuntimeError("no bridge in this file is ever really opened")

    def close(self) -> None:
        self.closed = True


class Observed:
    """What a run reached for: every runtime configuration, every endpoint."""

    def __init__(self) -> None:
        self.runtime_configs: List[Path] = []
        self.bridges: List[str] = []

    def bridge(self, comfy_url: str, **kwargs: Any) -> RecordedBridge:
        self.bridges.append(comfy_url)
        return RecordedBridge(comfy_url)

    def forget(self) -> None:
        self.runtime_configs.clear()
        self.bridges.clear()


@pytest.fixture()
def observed(monkeypatch: pytest.MonkeyPatch) -> Observed:
    """Records which runtime configuration was read and which endpoint was taken.

    The loader is wrapped rather than replaced, so a path that really is there
    really is loaded and the recording says nothing the run did not do.
    """

    record = Observed()

    def recording_load_config(path, **kwargs):
        record.runtime_configs.append(Path(path))
        return LOAD_CONFIG(path, **kwargs)

    monkeypatch.setattr(gateway_config, "load_config", recording_load_config)
    monkeypatch.setattr(sync_cli, "ConversionBridge", record.bridge)
    return record


@pytest.fixture()
def repository_root_with_a_runtime(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> Path:
    """The main checkout, reproduced: ``config/local/runtime.yaml`` present.

    This is the environment the defect needs and a worktree does not have.
    Building it makes every guard below able to fail on any machine.
    """

    root = tmp_path / "a checkout that has a config local"
    write_runtime(
        root / "config" / "local" / RUNTIME_CONFIG_FILENAME,
        port=ROOT_PORT,
        comfy_root=tmp_path / "not a real comfy",
    )
    monkeypatch.chdir(root)
    return root


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    """An isolated workspace, somewhere else entirely from the checkout above."""

    return SyncWorkspace(tmp_path)


def run(*argv: Any):
    import io

    out, err = io.StringIO(), io.StringIO()
    code = sync_main([str(item) for item in argv], out=out, err=err)
    return code, out.getvalue(), err.getvalue()


def document_of(output: str) -> Dict[str, Any]:
    return json.loads(output)


# ==========================================================================
# The resolution itself
# ==========================================================================


def test_the_runtime_configuration_is_the_sibling_of_the_configuration_named(
    tmp_path: Path,
) -> None:
    """Named beside the named file, spelled out rather than described."""

    named = tmp_path / "a folder with spaces" / "my sources.yaml"

    assert runtime_config_path(named) == (
        tmp_path / "a folder with spaces" / "runtime.yaml"
    )
    assert runtime_config_path(str(named)) == (
        tmp_path / "a folder with spaces" / "runtime.yaml"
    )


def test_the_shipped_default_still_names_the_file_it_has_always_named() -> None:
    """Why the rule needs no special case for "``--config`` was not given".

    The sibling of ``config/local/workflow-sources.yaml`` *is*
    ``config/local/runtime.yaml``.  One rule covers both, so there is no branch
    on "was ``--config`` given" that could be written backwards -- and the
    default invocation resolves exactly what it resolved before.
    """

    assert runtime_config_path(CONFIG_RELATIVE_PATH) == Path(
        RUNTIME_CONFIG_RELATIVE_PATH
    )


def test_an_explicit_runtime_config_wins_over_the_sibling(tmp_path: Path) -> None:
    """``scripts/sync-workflows.ps1`` always passes one, and it must be obeyed."""

    named = tmp_path / "sources" / "my sources.yaml"
    explicit = tmp_path / "elsewhere" / "chosen runtime.yaml"

    assert runtime_config_path(named, explicit) == explicit
    assert runtime_config_path(named, str(explicit)) == explicit


# ==========================================================================
# The guard: a run that names its configuration is not changed by anything else
# ==========================================================================


def test_a_named_config_takes_its_runtime_from_beside_itself_and_not_from_the_root(
    repository_root_with_a_runtime: Path,
    workspace: SyncWorkspace,
    observed: Observed,
) -> None:
    """The regression guard, and the point of T-0107.

    It fails if the resolution goes back to the repository root, and it can
    fail here: the root-relative runtime configuration is proved present and
    loadable before the run, so "nothing was found" cannot be an accident of
    the machine.
    """

    # The condition, proved rather than assumed: reverting the resolution would
    # really find something, and that something is not what the caller named.
    assert Path(RUNTIME_CONFIG_RELATIVE_PATH).is_file()
    assert LOAD_CONFIG(RUNTIME_CONFIG_RELATIVE_PATH).comfy.base_url == ROOT_ENDPOINT

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "editor.json", UI_GRAPH)
    workspace.write_config()
    sibling = workspace.config_path.parent / RUNTIME_CONFIG_FILENAME
    assert not sibling.exists(), "the named configuration has no runtime beside it"

    code, output, _ = run("--config", workspace.config_path)

    assert observed.runtime_configs == [sibling], (
        "the run must read the runtime configuration beside the file it was "
        "given, and no other"
    )
    assert observed.bridges == [], (
        "an endpoint was taken from a file the caller never named"
    )
    assert code == 1
    assert document_of(output)["conversion"]["comfy"] is None


def test_a_missing_sibling_is_no_runtime_and_there_is_no_second_place_to_look(
    repository_root_with_a_runtime: Path,
    workspace: SyncWorkspace,
    observed: Observed,
) -> None:
    """A fallback to the repository root would restore the defect silently.

    So the count of places consulted is asserted, not merely the outcome: one
    attempt, at the sibling, and the run then behaves exactly as a run with no
    ComfyUI to ask -- which is the honest answer and the one the code already
    gave for a missing configuration.
    """

    assert LOAD_CONFIG(RUNTIME_CONFIG_RELATIVE_PATH).comfy.base_url == ROOT_ENDPOINT

    folder = workspace.add_source()
    write_json(folder / "editor.json", UI_GRAPH)
    workspace.write_config()
    sibling = workspace.config_path.parent / RUNTIME_CONFIG_FILENAME

    code, output, errors = run("--config", workspace.config_path)
    document = document_of(output)

    assert observed.runtime_configs == [sibling], (
        "one place was named and one place may be consulted"
    )
    assert Path(RUNTIME_CONFIG_RELATIVE_PATH) not in observed.runtime_configs, (
        "a fallback to the repository root would restore the defect silently"
    )
    assert observed.bridges == []
    # Not fatal: a curator reading a folder is not stopped by the absence of a
    # gateway configuration they have not written yet.
    assert code == 1
    assert errors == ""
    assert document["workflows"][0]["conversion"] is None
    assert "Workflow -> Export (API)" in document["attention"][0]["reason"]


# ==========================================================================
# The two assertions that failed in the main checkout, under that very
# condition.  Both are the originals from test_sync_cli.py, verbatim.
# ==========================================================================


def test_the_summary_is_the_same_where_a_root_relative_runtime_exists(
    repository_root_with_a_runtime: Path,
    workspace: SyncWorkspace,
    observed: Observed,
) -> None:
    assert LOAD_CONFIG(RUNTIME_CONFIG_RELATIVE_PATH).comfy.base_url == ROOT_ENDPOINT

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "editor.json", UI_GRAPH)
    workspace.write_config()

    _, output, _ = run("--config", workspace.config_path)
    summary = document_of(output)["summary"]

    assert "\n" not in summary
    assert summary == (
        "2 workflows found, 1 importable (1 new, 0 changed, 0 unchanged), "
        "1 definition written, 1 needs attention."
    )


def test_the_attention_verdict_is_the_same_where_a_root_relative_runtime_exists(
    repository_root_with_a_runtime: Path,
    workspace: SyncWorkspace,
    observed: Observed,
) -> None:
    assert LOAD_CONFIG(RUNTIME_CONFIG_RELATIVE_PATH).comfy.base_url == ROOT_ENDPOINT

    folder = workspace.add_source()
    write_json(folder / "one.json", api_graph(1))
    write_json(folder / "editor.json", UI_GRAPH)
    workspace.write_config()

    code, output, _ = run("--config", workspace.config_path)
    document = document_of(output)

    assert code == 1
    assert [item["state"] for item in document["attention"]] == ["NEEDS_API_EXPORT"]
    assert "Workflow -> Export (API)" in document["attention"][0]["reason"]


# ==========================================================================
# Normal use, shown by a differential rather than asserted
# ==========================================================================


def test_the_ordinary_layout_resolves_the_same_runtime_three_ways(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, observed: Observed
) -> None:
    """The differential: three invocations of the ordinary layout, compared.

    In the layout every user actually has, the sources configuration is
    ``config/local/workflow-sources.yaml`` and the runtime configuration sits
    beside it.  So:

    * **A** -- ``--config`` given, runtime derived (the new rule);
    * **B** -- ``--config`` given and ``--runtime-config`` spelled out as the
      repository-root-relative path (what the code did before this change);
    * **C** -- neither given, both defaulted.

    Nothing here asserts what the report *says*; it asserts that the three
    reports are the same report.  That is what "normal behaviour is unchanged"
    means, and an equality between measurements can fail in ways an assertion
    against a remembered string cannot.
    """

    root = tmp_path / "an ordinary checkout"
    source = tmp_path / "my workflows"
    source.mkdir(parents=True)
    write_json(source / "one.json", api_graph(1))
    write_json(source / "editor.json", UI_GRAPH)
    write_sources(root / "config" / "local" / "workflow-sources.yaml", source=source)
    write_runtime(
        root / "config" / "local" / RUNTIME_CONFIG_FILENAME,
        port=BESIDE_PORT,
        comfy_root=tmp_path / "not a real comfy",
    )
    monkeypatch.chdir(root)

    measurements = []
    for argv in (
        ("--config", CONFIG_RELATIVE_PATH, "--dry-run"),
        (
            "--config",
            CONFIG_RELATIVE_PATH,
            "--runtime-config",
            RUNTIME_CONFIG_RELATIVE_PATH,
            "--dry-run",
        ),
        ("--dry-run",),
    ):
        observed.forget()
        code, output, errors = run(*argv)
        document = document_of(output)
        document.pop("generated")
        measurements.append(
            (
                code,
                errors,
                list(observed.runtime_configs),
                list(observed.bridges),
                document,
            )
        )

    derived, spelled_out, defaulted = measurements

    # The endpoint really was taken from the runtime beside the configuration:
    # this is what proves the recorder above is able to record one at all, so
    # the empty lists asserted by the guards mean something.
    assert derived[3] == [BESIDE_ENDPOINT]
    assert derived[2] == [Path(RUNTIME_CONFIG_RELATIVE_PATH)]

    assert derived == spelled_out, "the derived runtime is not the one it used to be"
    assert derived == defaulted, "the default invocation changed"


def test_the_differential_would_notice_a_different_runtime(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, observed: Observed
) -> None:
    """The comparison above is only worth having if it can come out unequal.

    Same layout, same workflows, one difference: an explicit
    ``--runtime-config`` naming a *different* file.  The measurements must
    differ -- otherwise the equality asserted above is a property of the
    comparison rather than of the resolution.
    """

    root = tmp_path / "an ordinary checkout"
    source = tmp_path / "my workflows"
    source.mkdir(parents=True)
    write_json(source / "one.json", api_graph(1))
    write_sources(root / "config" / "local" / "workflow-sources.yaml", source=source)
    write_runtime(
        root / "config" / "local" / RUNTIME_CONFIG_FILENAME,
        port=BESIDE_PORT,
        comfy_root=tmp_path / "not a real comfy",
    )
    elsewhere = write_runtime(
        tmp_path / "elsewhere" / "another runtime.yaml",
        port=ELSEWHERE_PORT,
        comfy_root=tmp_path / "not a real comfy",
    )
    monkeypatch.chdir(root)

    run("--config", CONFIG_RELATIVE_PATH, "--dry-run")
    beside = (list(observed.runtime_configs), list(observed.bridges))

    observed.forget()
    run("--config", CONFIG_RELATIVE_PATH, "--runtime-config", elsewhere, "--dry-run")
    named = (list(observed.runtime_configs), list(observed.bridges))

    assert beside == ([Path(RUNTIME_CONFIG_RELATIVE_PATH)], [BESIDE_ENDPOINT])
    assert named == ([elsewhere], [ELSEWHERE_ENDPOINT])
    assert beside != named
