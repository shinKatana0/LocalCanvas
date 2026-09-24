"""The source boundary: only the configured folders are ever read.

Reading only what the user names is the reason this file is the longest of
the sync tests.
Two guards hold the boundary (`sync/discovery.py`), and they are tested one at
a time, because two guards that are only ever tested together are one guard
with a spare: remove either and the suite must go red.

  * **guard 1 -- a reparse point is never followed.**  Its own failure is a
    junction *inside* the root: containment cannot see anything wrong with it,
    because everything it points at is contained, and yet following it reports
    the same files twice.
  * **guard 2 -- the resolved path must be inside the resolved root.**  Its own
    failure is a ``..`` segment or a link out of the root, which the reparse
    check would let through if it were relaxed.

Windows makes one of these cheap and the other conditional: a directory
junction needs no elevation and no Developer Mode, so the junction tests really
run here; a symbolic link needs one of the two, so those tests say so and skip
when the machine will not make one.  Every test that depends on a link first
proves the link exists.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from localcanvas_gateway.workflows.sync import discovery
from localcanvas_gateway.workflows.sync import SyncSourceError, is_contained, scan_root
from sync_fixtures import (
    API_GRAPH,
    api_graph,
    make_junction,
    make_symlink,
    write_json,
)


@pytest.fixture()
def root(tmp_path: Path) -> Path:
    folder = tmp_path / "my workflows"
    folder.mkdir()
    return folder


def names(scan) -> list:
    return [candidate.relative for candidate in scan.candidates]


# ==========================================================================
# Guard 2 alone: the containment predicate
# ==========================================================================


def test_containment_accepts_the_root_and_what_is_under_it(root: Path) -> None:
    (root / "a folder").mkdir()
    assert is_contained(root, root) is True
    assert is_contained(root / "a folder", root) is True
    assert is_contained(root / "a folder" / "deep.json", root) is True


def test_containment_collapses_dot_dot_before_deciding(root: Path) -> None:
    """``<root>/sub/../../outside`` is outside, however it is spelled."""

    (root / "sub").mkdir()
    assert is_contained(root / "sub" / ".." / "inside.json", root) is True
    assert is_contained(root / "sub" / ".." / ".." / "outside.json", root) is False
    assert is_contained(root / ".." / "sibling" / "f.json", root) is False


def test_containment_is_not_a_prefix_match(tmp_path: Path) -> None:
    """``<root>-backup`` is not inside ``<root>``, and a ``startswith`` says it is.

    The mistake this guards is one line long and looks right; the repository's
    script suite already carries the same note about ``stubenv`` and
    ``stubenv-other``.
    """

    root = tmp_path / "my workflows"
    root.mkdir()
    for name in ("my workflows-2", "my workflows backup", "my workflowsX"):
        trap = tmp_path / name
        trap.mkdir()
        assert str(trap).startswith(str(root)), "the trap is not set up: " + name
        assert is_contained(trap, root) is False, name
        assert is_contained(trap / "inside.json", root) is False, name


def test_containment_sees_through_a_junction_that_leaves_the_root(
    root: Path, tmp_path: Path
) -> None:
    """Guard 2 on its own, on the case guard 1 also catches.

    Proving guard 2 in isolation means asking it directly about a path that
    only its own mechanism -- resolution -- can see through.  A junction is
    that path: nothing about the name says it leaves the root.
    """

    outside = tmp_path / "somewhere else"
    outside.mkdir()
    write_json(outside / "secret.json", api_graph(9))
    link = root / "shortcut"
    if not make_junction(link, outside):
        pytest.skip("this machine would not create a directory junction")
    assert (link / "secret.json").exists(), "the junction does not lead anywhere"

    assert is_contained(link, root) is False
    assert is_contained(link / "secret.json", root) is False


def test_containment_refuses_what_it_cannot_resolve(root: Path) -> None:
    assert is_contained("\0not a path", root) is False


# ==========================================================================
# Guard 1 alone: a reparse point is never followed
# ==========================================================================


def test_a_junction_inside_the_root_is_not_descended_into(root: Path) -> None:
    """Guard 1 on its own: containment has nothing to object to here.

    The junction points at a folder *inside* the root, so every path reached
    through it resolves inside the root and guard 2 is satisfied.  Only guard 1
    stops the walk, and if it were removed ``real/deep.json`` would be reported
    twice under two different relative paths.
    """

    (root / "real").mkdir()
    write_json(root / "real" / "deep.json", api_graph(1))
    link = root / "the same folder again"
    if not make_junction(link, root / "real"):
        pytest.skip("this machine would not create a directory junction")
    assert (link / "deep.json").exists(), "the junction does not lead anywhere"
    assert is_contained(link, root) is True, "guard 2 has nothing to object to here"

    scan = scan_root(str(root), root)

    assert names(scan) == ["real/deep.json"]
    assert any("reparse point" in item.reason for item in scan.skipped)


def test_a_symlinked_file_inside_the_root_is_not_read(root: Path) -> None:
    """The same, for a file link that guard 2 also has nothing against."""

    write_json(root / "real.json", api_graph(1))
    link = root / "the same file again.json"
    if not make_symlink(link, root / "real.json", directory=False):
        pytest.skip(
            "this machine will not create a symbolic link without elevation or "
            "Developer Mode"
        )
    assert link.exists(), "the symlink does not lead anywhere"
    assert is_contained(link, root) is True, "guard 2 has nothing to object to here"

    scan = scan_root(str(root), root)

    assert names(scan) == ["real.json"]


# ==========================================================================
# The two together, on the escape they exist for
# ==========================================================================


def test_a_workflow_outside_the_root_is_never_read(root: Path, tmp_path: Path) -> None:
    outside = tmp_path / "not a source"
    outside.mkdir()
    write_json(outside / "planted.json", api_graph(7))
    write_json(root / "mine.json", api_graph(1))

    scan = scan_root(str(root), root)

    assert names(scan) == ["mine.json"]
    assert all("planted.json" not in str(item.path) for item in scan.candidates)


def test_a_root_spelled_with_dot_dot_still_reads_only_that_root(
    root: Path, tmp_path: Path
) -> None:
    outside = tmp_path / "not a source"
    outside.mkdir()
    write_json(outside / "planted.json", api_graph(7))
    write_json(root / "mine.json", api_graph(1))
    (root / "sub").mkdir()

    spelled = root / "sub" / ".."
    scan = scan_root(str(spelled), spelled)

    assert scan.root == root.resolve()
    assert names(scan) == ["mine.json"]


def test_a_junction_out_of_the_root_reads_nothing_through_it(
    root: Path, tmp_path: Path
) -> None:
    outside = tmp_path / "somewhere else"
    outside.mkdir()
    write_json(outside / "planted.json", api_graph(7))
    write_json(root / "mine.json", api_graph(1))
    if not make_junction(root / "shortcut", outside):
        pytest.skip("this machine would not create a directory junction")
    assert (root / "shortcut" / "planted.json").exists()

    scan = scan_root(str(root), root)

    assert names(scan) == ["mine.json"]
    assert any("shortcut" in item.path for item in scan.skipped)


def test_a_symlinked_directory_out_of_the_root_reads_nothing_through_it(
    root: Path, tmp_path: Path
) -> None:
    outside = tmp_path / "somewhere else"
    outside.mkdir()
    write_json(outside / "planted.json", api_graph(7))
    write_json(root / "mine.json", api_graph(1))
    if not make_symlink(root / "shortcut", outside):
        pytest.skip(
            "this machine will not create a symbolic link without elevation or "
            "Developer Mode"
        )
    assert (root / "shortcut" / "planted.json").exists()

    scan = scan_root(str(root), root)

    assert names(scan) == ["mine.json"]


# ==========================================================================
# Ordering, recursion and selection
# ==========================================================================


def test_the_order_is_the_trees_and_never_the_filesystems(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The same tree, read in the opposite order, produces the same list.

    ``_entries`` is replaced with one that hands back exactly what the
    filesystem gave, reversed.  If the walk stopped sorting, this test would be
    the one that noticed -- and it could not be made to pass by the fixture,
    because the fixture is the same tree in both halves.
    """

    for name in ("zulu.json", "alpha.json", "middle.json"):
        write_json(root / name, api_graph(1))
    (root / "sub folder").mkdir()
    write_json(root / "sub folder" / "beta.json", api_graph(2))

    forwards = names(scan_root(str(root), root))

    original = discovery._entries
    monkeypatch.setattr(
        discovery, "_entries", lambda directory: list(reversed(original(directory)))
    )
    backwards = names(scan_root(str(root), root))

    assert forwards == backwards
    assert forwards == ["alpha.json", "middle.json", "sub folder/beta.json", "zulu.json"]


def test_recursive_false_reads_one_folder_only(root: Path) -> None:
    write_json(root / "top.json", api_graph(1))
    (root / "sub").mkdir()
    write_json(root / "sub" / "deep.json", api_graph(2))

    assert names(scan_root(str(root), root, recursive=True)) == [
        "sub/deep.json",
        "top.json",
    ]
    assert names(scan_root(str(root), root, recursive=False)) == ["top.json"]


def test_only_json_files_are_opened_and_the_name_decides_nothing_else(
    root: Path,
) -> None:
    """Selection is by extension; classification never is.

    Discovery has to choose what is worth opening in a folder that also holds
    thumbnails and notes.  What a chosen file *is* remains a question about its
    content -- ``test_sync_engine`` holds that half.
    """

    write_json(root / "a workflow.json", api_graph(1))
    (root / "notes.txt").write_text("not a workflow", encoding="utf-8")
    (root / "preview.png").write_bytes(b"\x89PNG\r\n")

    assert names(scan_root(str(root), root)) == ["a workflow.json"]


def test_a_path_with_spaces_works_all_the_way_down(tmp_path: Path) -> None:
    root = tmp_path / "my ComfyUI workflows"
    (root / "a nested folder").mkdir(parents=True)
    write_json(root / "a nested folder" / "one more workflow.json", API_GRAPH)

    scan = scan_root(str(root), root)

    assert names(scan) == ["a nested folder/one more workflow.json"]
    assert scan.candidates[0].path.exists()


# ==========================================================================
# Fatal source problems
# ==========================================================================


def test_a_root_that_does_not_exist_is_fatal_and_says_so(tmp_path: Path) -> None:
    missing = tmp_path / "no such folder"

    with pytest.raises(SyncSourceError) as caught:
        scan_root(str(missing), missing)

    message = str(caught.value)
    assert str(missing) in message
    assert "does not exist" in message
    assert "never searches the machine" in message


def test_a_root_that_is_a_file_is_fatal(tmp_path: Path) -> None:
    a_file = tmp_path / "a workflow.json"
    write_json(a_file, API_GRAPH)

    with pytest.raises(SyncSourceError, match="not a folder"):
        scan_root(str(a_file), a_file)


def test_an_unreadable_subfolder_does_not_stop_the_rest(
    root: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One folder that cannot be listed is reported; the others still are read."""

    write_json(root / "mine.json", api_graph(1))
    (root / "locked").mkdir()
    write_json(root / "locked" / "hidden.json", api_graph(2))

    original = discovery._entries

    def refuse(directory):
        if os.path.basename(directory) == "locked":
            raise PermissionError(13, "Access is denied")
        return original(directory)

    monkeypatch.setattr(discovery, "_entries", refuse)

    scan = scan_root(str(root), root)

    assert names(scan) == ["mine.json"]
    assert any("could not be read" in item.reason for item in scan.skipped)
