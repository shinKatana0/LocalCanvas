"""``config/local/workflow-sources.yaml``: what it accepts and how it refuses.

A configuration error is the first thing a new user meets, so it is held to the
same standard as the runtime configuration: it names the file, the dotted key,
what was expected and what was there, and for the one error that will happen
most -- the file is not there yet -- it names the example to copy.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from localcanvas_gateway.workflows.sync import (
    EXAMPLE_RELATIVE_PATH,
    SyncConfigError,
    load_sources_config,
)
from sync_fixtures import SyncWorkspace

REPO_ROOT = Path(__file__).resolve().parents[2]
EXAMPLE_CONFIG = REPO_ROOT / "config" / "examples" / "workflow-sources.example.yaml"


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def test_the_example_config_is_what_the_loader_accepts(tmp_path: Path) -> None:
    """The shipped example loads -- with only its one path edited.

    The acceptance criterion is "copy the example, edit one path, run it", so
    this test does exactly that: the file's own bytes, with the ``sources``
    path replaced by a real folder and nothing else touched.  A example that
    drifts out of step with the loader fails here rather than in a user's
    terminal.
    """

    workspace = SyncWorkspace(tmp_path)
    folder = workspace.add_source()
    text = EXAMPLE_CONFIG.read_text(encoding="utf-8")
    placeholder = '"C:/path/to/ComfyUI/user/default/workflows"'
    assert placeholder in text, "the example no longer carries the placeholder path"
    edited = text.replace(placeholder, '"{}"'.format(str(folder).replace("\\", "/")))
    workspace.config_path.write_text(edited, encoding="utf-8")

    config = load_sources_config(workspace.config_path)

    assert [source.path for source in config.sources] == [folder]
    assert config.sources[0].recursive is True
    assert config.output.inventory == workspace.inventory_path
    assert config.sync.detect_duplicates is True
    assert config.sync.detect_removed is True
    assert config.sync.preserve_manual_metadata is True


def checkout_spellings(root: Path) -> list[str]:
    """Every way the example could write ``root`` or the directory holding it.

    Backslash, forward slash, and the doubled backslash a string literal
    carries; the caller compares lower-cased, which covers the fourth form.
    The holding directory counts too -- a bare repository root still says where
    the user keeps their work -- but never a bare drive or ``/``, which
    would match every absolute path ever written.
    """

    locations = [root]
    parent = root.parent
    if parent != root and parent.name:
        locations.append(parent)
    spellings: set[str] = set()
    for location in locations:
        text = str(location)
        spellings.add(text)
        spellings.add(text.replace("\\", "/"))
        spellings.add(text.replace("\\", "\\\\"))
    return sorted(spellings)


def test_the_example_names_no_real_machine() -> None:
    """The example is generic, in every line of it.

    The checkout is derived here, never written down. This test used to carry
    the user's checkout location as two literals, forward-slashed and
    doubled-backslashed -- a forbidden-list that stated the very value it was
    defending, and so a leak of exactly the kind it existed to prevent
    (T-0340 rework 2). Derived, it guards more and reveals nothing: on a
    stranger's clone it tests their root instead of ours.

    This checks the one file it is about. The whole exported tree is held to
    the same rule by PublicTreeNamesNoCheckoutTests in
    ``scripts/tests/run_tests.py``, which is what caught the literals here.
    """

    text = EXAMPLE_CONFIG.read_text(encoding="utf-8")
    lowered = text.lower()
    forbidden = ["users/", "\\users\\", "localcanvas\\.venv"]
    forbidden += [spelling.lower() for spelling in checkout_spellings(REPO_ROOT)]
    for needle in forbidden:
        assert needle not in lowered, "the example carries a real path: " + needle


def test_a_missing_config_names_the_example_to_copy(workspace: SyncWorkspace) -> None:
    missing = workspace.repo / "config" / "local" / "not written yet.yaml"

    with pytest.raises(SyncConfigError) as caught:
        load_sources_config(missing)

    message = str(caught.value)
    assert str(missing) in message
    assert EXAMPLE_RELATIVE_PATH in message
    assert "config/local/workflow-sources.yaml" in message
    assert "Copy-Item" in message


def test_a_relative_output_path_is_measured_from_the_repository_root(
    workspace: SyncWorkspace,
) -> None:
    workspace.add_source()
    workspace.write_config()

    config = workspace.load()

    assert config.repo_root == workspace.repo
    assert config.output.definitions == workspace.repo / "config" / "local" / "workflows"
    assert (
        config.output.imported_api
        == workspace.repo / "config" / "local" / "imported-workflows"
    )
    assert config.output.inventory == workspace.inventory_path


def test_an_absolute_output_path_stands(workspace: SyncWorkspace) -> None:
    workspace.add_source()
    elsewhere = workspace.base / "somewhere else" / "inventory.json"
    workspace.write_config(inventory=str(elsewhere).replace("\\", "/"))

    assert workspace.load().output.inventory == elsewhere


def test_a_relative_source_path_is_refused_and_says_why(workspace: SyncWorkspace) -> None:
    """A source folder lives outside the repository; a relative path has no anchor."""

    workspace.write_config(
        body="\n".join(
            [
                "sources:",
                '  - path: "workflows/examples"',
                "output:",
                '  definitions: "config/local/workflows"',
                '  imported_api: "config/local/imported-workflows"',
                '  inventory: "config/local/workflow-inventory.json"',
                "",
            ]
        )
    )

    with pytest.raises(SyncConfigError) as caught:
        workspace.load()

    message = str(caught.value)
    assert "sources[0].path" in message
    assert "ABSOLUTE" in message
    assert "never searches the machine" in message


@pytest.mark.parametrize(
    "spelling",
    [
        "/workflows/mine",          # rooted, but on no particular drive
        "workflows/mine",           # plainly relative
        "./workflows",              # relative, dressed up
    ],
)
def test_every_non_absolute_spelling_is_refused(
    workspace: SyncWorkspace, spelling: str
) -> None:
    """On Windows a rooted path is not an absolute one.

    ``\\workflows`` names a folder on whichever drive happens to be current,
    which is exactly the kind of value that works on the machine it was written
    on and nowhere else.  ``ntpath.isabs`` calls it absolute; this must not.
    """

    import os

    if os.name != "nt" and spelling.startswith("/"):
        pytest.skip("a rooted path is genuinely absolute on this platform")
    workspace.write_config(
        body="\n".join(
            [
                "sources:",
                '  - path: "{}"'.format(spelling),
                "output:",
                '  definitions: "config/local/workflows"',
                '  imported_api: "config/local/imported-workflows"',
                '  inventory: "config/local/workflow-inventory.json"',
                "",
            ]
        )
    )

    with pytest.raises(SyncConfigError, match="ABSOLUTE"):
        workspace.load()


def test_an_unknown_key_is_an_error_that_lists_what_is_accepted(
    workspace: SyncWorkspace,
) -> None:
    folder = workspace.add_source()
    workspace.write_config(
        body="\n".join(
            [
                "sources:",
                '  - path: "{}"'.format(str(folder).replace("\\", "/")),
                "    recursively: true",
                "output:",
                '  definitions: "config/local/workflows"',
                '  imported_api: "config/local/imported-workflows"',
                '  inventory: "config/local/workflow-inventory.json"',
                "",
            ]
        )
    )

    with pytest.raises(SyncConfigError) as caught:
        workspace.load()

    message = str(caught.value)
    assert "'recursively'" in message
    assert "'recursive'" in message, "the message does not list what is accepted"


@pytest.mark.parametrize(
    "body, expected",
    [
        ("", "the file is empty"),
        ("- one\n- two\n", "expected a mapping of configuration sections"),
        ("sources: [\n", "not valid YAML"),
        ("output:\n  definitions: a\n  imported_api: b\n  inventory: c\n",
         "sources: required section is missing"),
        ("sources: []\noutput:\n  definitions: a\n  imported_api: b\n  inventory: c\n",
         "the list is empty"),
        ("sources: \"C:/x\"\noutput:\n  definitions: a\n  imported_api: b\n  inventory: c\n",
         "expected a list of source folders"),
    ],
)
def test_a_malformed_config_says_what_is_wrong(
    workspace: SyncWorkspace, body: str, expected: str
) -> None:
    workspace.write_config(body=body)

    with pytest.raises(SyncConfigError) as caught:
        workspace.load()

    assert expected in str(caught.value)
    assert str(workspace.config_path) in str(caught.value)


def test_a_missing_output_section_is_refused(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    workspace.write_config(
        body='sources:\n  - path: "{}"\n'.format(str(folder).replace("\\", "/"))
    )

    with pytest.raises(SyncConfigError) as caught:
        workspace.load()

    message = str(caught.value)
    assert "output: required section is missing" in message
    assert "'inventory'" in message


def test_the_sync_switches_default_to_on_and_can_be_turned_off(
    workspace: SyncWorkspace,
) -> None:
    workspace.add_source()
    workspace.write_config(
        sync={
            "detect_duplicates": False,
            "detect_removed": False,
            "preserve_manual_metadata": False,
        }
    )

    options = workspace.load().sync

    assert options.detect_duplicates is False
    assert options.detect_removed is False
    assert options.preserve_manual_metadata is False


def test_a_switch_that_is_not_a_boolean_is_refused(workspace: SyncWorkspace) -> None:
    folder = workspace.add_source()
    workspace.write_config(
        body="\n".join(
            [
                "sources:",
                '  - path: "{}"'.format(str(folder).replace("\\", "/")),
                "output:",
                '  definitions: "config/local/workflows"',
                '  imported_api: "config/local/imported-workflows"',
                '  inventory: "config/local/workflow-inventory.json"',
                "sync:",
                '  detect_removed: "yes please"',
                "",
            ]
        )
    )

    with pytest.raises(SyncConfigError) as caught:
        workspace.load()

    assert "sync.detect_removed: expected true or false" in str(caught.value)


def test_a_source_path_with_spaces_survives(tmp_path: Path) -> None:
    workspace = SyncWorkspace(tmp_path)
    folder = workspace.add_source("a folder with several spaces in it")
    workspace.write_config()

    config = workspace.load()

    assert config.sources[0].path == folder
    assert " " in str(config.sources[0].path)
