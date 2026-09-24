"""The conversion bridge: what it asks, what it refuses, and what it never does.

Every test here drives the **production** bridge -- its own temporary profile,
its own argument list, its own port-file wait, its own WebSocket, its own CDP
conversation -- against a stand-in browser that is a real program on a real
socket (``workflows/sync/browser_fake.py``) and a stand-in ComfyUI that is a
real HTTP server (``comfy/fake.py``).  Nothing between
``ConversionBridge.convert`` and the wire is mocked.

The five properties `docs/privacy-security.md` makes requirements of this
capability each have a test in the first section, and each of those tests is
written so that removing the thing it guards makes it fail.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Dict

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows.sync import bridge as bridge_module
from localcanvas_gateway.workflows.sync.bridge import (
    BROWSER_CANDIDATES,
    BROWSER_FLAGS,
    CATEGORY_BROWSER_NOT_FOUND,
    CATEGORY_COMFY_NOT_READY,
    CATEGORY_COMFY_UNREACHABLE,
    CATEGORY_BRIDGE_ERROR,
    CATEGORY_BROWSER_NOT_STARTED,
    CATEGORY_CONVERSION_REJECTED,
    CATEGORY_FRONTEND_NOT_READY,
    CATEGORY_NOT_IMPORTABLE,
    CONVERT_MARKER,
    LOOPBACK_ONLY_RESOLVER_RULE,
    NO_PROXY_FLAG,
    ComfyIdentity,
    ConversionStatus,
    browser_command,
    conversion_expression,
    find_browser,
    no_browser_reason,
)
from localcanvas_gateway.workflows.sync.browser_fake import NAME_NOT_RESOLVED
from sync_fixtures import make_junction
from bridge_fixtures import (
    Beacon,
    Browser,
    CountingPopen,
    converted_graph,
    make_bridge,
    ui_graph,
)


@pytest.fixture()
def comfy():
    with FakeComfy() as running:
        yield running


def one(bridge, graph: Dict[str, Any]):
    raw = json.dumps(graph).encode("utf-8")
    from localcanvas_gateway.workflows.sync.classify import content_hash  # noqa: PLC0415

    return bridge.convert(raw, content_hash=content_hash(raw))


# ==========================================================================
# The two strings that ARE the boundary
# ==========================================================================
#
# Everything else in this file surrounds the boundary; nothing else touches the
# expressions themselves, and the stand-in browser does not execute JavaScript,
# so a change inside them reaches no assertion at all.  Measured on the code as
# it was reviewed: `graphToPrompt()` -> `queuePrompt(0)`, `prompt.output` ->
# `prompt.workflow`, and the readiness gate deleted -- 41 passed, every time.
# The first of those would queue a generation on the user's GPU for every
# workflow in their folder, during what they were told is an import.
#
# So these read the strings, the way `test_only_the_bridge_reaches_the_network_
# in_the_sync_package` reads its modules and the script suite reads the `.ps1`
# for `Start-Process`.  Each is anchored on something that has to be there, so
# a rename or an emptied constant fails loudly instead of scanning nothing.


def test_the_conversion_expression_asks_for_the_prompt_and_never_submits_it() -> None:
    """The one string that decides whether an import generates.

    ``graphToPrompt`` asks the frontend what the graph *would* submit;
    ``queuePrompt`` submits it. They are one token apart, and ComfyUI's own
    *Export (API)* menu item takes exactly the half taken here -- its
    ``exportWorkflow`` does ``graphToPrompt()`` and serialises ``output``.
    """

    expression = conversion_expression('{"id": "x", "nodes": []}')

    # Anchors first: if these are gone the expression is not what this test
    # thinks it is, and every assertion below would be about nothing.
    assert "window.app" in expression
    assert "loadGraphData" in expression
    assert CONVERT_MARKER in expression

    assert "graphToPrompt()" in expression
    assert "prompt.output" in expression

    # And the half that must never appear. Asserted against the expression a
    # real workflow produces, not against the template, because the workflow's
    # own text is embedded in it.
    for forbidden in ("queuePrompt", "queue_prompt", "/prompt", "api/prompt"):
        assert forbidden not in expression, forbidden

    # `prompt.workflow` is the other half of what graphToPrompt returns -- the
    # canvas. Taking it instead would make every conversion fail while the
    # suite stayed green, so it is named here rather than left to `output`.
    assert "prompt.workflow" not in expression


def test_the_bridge_never_names_the_call_that_would_generate() -> None:
    """Read as source, so a submission that is never executed still fails.

    The expression above is the one a workflow travels in; this is the whole
    module, because a second call site added anywhere else would be just as
    much of a generation.
    """

    source = Path(bridge_module.__file__).read_text(encoding="utf-8")

    assert "def conversion_expression(" in source, (
        "the expression builder was renamed; this lint scanned nothing"
    )
    assert "graphToPrompt" in source, (
        "the boundary is not named in this module any more; this lint scanned "
        "nothing"
    )
    for forbidden in ("queuePrompt", "queue_prompt"):
        assert forbidden not in source, (
            "bridge.py names " + forbidden + ", which submits a graph for "
            "execution. Exporting must never generate."
        )


def test_the_frontend_is_not_asked_to_convert_before_it_is_ready(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The readiness gate, exercised rather than described.

    A page whose node types have not registered converts a graph into
    nonsense -- every node type is unknown, so every node comes back without a
    ``class_type``. Deleting the gate left the whole suite green, because
    nothing made the page slow. This does: the stand-in browser answers "not
    yet" to the first few probes, and the conversion still succeeds because the
    bridge waited.
    """

    browser = Browser(
        tmp_path,
        monkeypatch,
        ready_after=5,
        default={"ok": True, "output": converted_graph(4)},
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.CONVERTED
    assert result.document["20"]["inputs"]["seed"] == 4

    saw = browser.saw()
    assert saw["ready_probes"] == 6, saw["ready_probes"]
    # The order is the property: every "not yet" came before the conversion,
    # and there was exactly one conversion after them.
    assert saw["expressions"] == ["ready"] * 6 + [
        item for item in saw["expressions"] if item.startswith("convert")
    ]
    assert len([item for item in saw["expressions"] if item.startswith("convert")]) == 1


def test_a_frontend_that_never_becomes_ready_is_actionable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The realistic failure on a large installation, and what to do about it."""

    browser = Browser(
        tmp_path,
        monkeypatch,
        ready_after=10_000,
        default={"ok": True, "output": converted_graph()},
    )
    timeouts = bridge_module.BridgeTimeouts(
        comfy_probe=5.0, browser_start=30.0, page_target=30.0,
        frontend_ready=1.0, conversion=10.0, browser_stop=10.0,
    )
    with make_bridge(comfy.base_url, browser, timeouts=timeouts) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.UNAVAILABLE
    assert result.category == CATEGORY_FRONTEND_NOT_READY
    assert result.document is None
    assert "did not finish loading" in result.detail
    assert "Nothing was converted and nothing was written" in result.detail
    assert "open ComfyUI in a browser yourself" in result.detail
    assert "-NoConvert" in result.detail


def test_a_browser_that_dies_at_once_is_actionable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """A program that exits instead of publishing a debugging port."""

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(
        comfy.base_url, browser, program=(sys.executable, "-c", "raise SystemExit(3)")
    ) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.UNAVAILABLE
    assert result.category == CATEGORY_BROWSER_NOT_STARTED
    assert result.document is None
    assert "exited before it published a debugging port" in result.detail
    assert "Nothing was converted and nothing was written" in result.detail
    assert "Chrome or Edge starts normally" in result.detail
    assert not browser.launched, "the stand-in browser should not have run at all"


def test_a_browser_that_stops_answering_is_actionable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The transport category, reached by a browser that refuses mid-run.

    ``refuse_after=1`` lets the readiness probe through and refuses the
    conversion, which is what a page navigating out from under an evaluation
    really does.
    """

    browser = Browser(
        tmp_path,
        monkeypatch,
        refuse_after=1,
        default={"ok": True, "output": converted_graph()},
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        first = one(bridge, ui_graph("a"))
        second = one(bridge, ui_graph("b"))

    assert first.status is ConversionStatus.UNAVAILABLE
    assert first.category == CATEGORY_BRIDGE_ERROR
    assert first.document is None
    assert "Execution context was destroyed" in first.detail
    assert "Nothing was written for it" in first.detail
    assert "-NoConvert" in first.detail
    # And it is a fact about the run, not about this graph: the next workflow
    # is told the same thing rather than being blamed for it.
    assert second.category == CATEGORY_BRIDGE_ERROR


def test_every_category_this_module_can_produce_is_asserted_somewhere() -> None:
    """The set is closed, so a new one cannot arrive untested and unworded.

    Three of the eight were asserted nowhere when this card was first reviewed.
    A category is what a person quotes; one nothing tests is one nothing keeps
    honest.
    """

    from localcanvas_gateway.workflows.sync import bridge as module  # noqa: PLC0415

    categories = {
        name: value
        for name, value in vars(module).items()
        if name.startswith("CATEGORY_") and isinstance(value, str)
    }
    assert len(categories) == 8, sorted(categories)

    here = Path(__file__).read_text(encoding="utf-8")
    beside = (Path(__file__).parent / "test_sync_conversion.py").read_text(
        encoding="utf-8"
    )
    # By the constant's name or by its value: the tests import the constants,
    # so a name is the ordinary way one appears, and a literal is accepted so
    # that a test asserting the token a user would quote also counts.
    for name, value in sorted(categories.items()):
        assert name in here or name in beside or value in here or value in beside, name

    # Every category that does not compose an instruction of its own carries
    # one from the table, and every one of those says what to do next.
    values = set(categories.values())
    for category, action in module.ACTIONS.items():
        assert category in values, category
        assert "-NoConvert" in action or "run this sync again" in action, category


# ==========================================================================
# The five properties docs/privacy-security.md makes requirements
# ==========================================================================


def test_the_launch_command_is_exactly_this() -> None:
    """The cage, asserted as a list rather than described in prose.

    Verbatim and in order, because every element of it is a promise somebody
    can quietly drop.  The two that are privacy claims are named separately
    below so that a diff that removes one is unmistakable.
    """

    command = browser_command(
        ("C:\\browsers\\chrome.exe",),
        profile_dir="C:\\temp\\a profile",
        url="http://127.0.0.1:8188",
    )

    assert command == (
        "C:\\browsers\\chrome.exe",
        "--headless=new",
        "--disable-gpu",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-default-apps",
        "--disable-extensions",
        "--disable-sync",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-client-side-phishing-detection",
        "--metrics-recording-only",
        "--no-service-autorun",
        "--password-store=basic",
        "--use-mock-keychain",
        "--mute-audio",
        "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE localhost , "
        "EXCLUDE 127.0.0.1 , EXCLUDE ::1",
        "--no-proxy-server",
        "--remote-debugging-port=0",
        "--user-data-dir=C:\\temp\\a profile",
        "http://127.0.0.1:8188",
    )

    # The two privacy flags, named: the rule that stops a public name being
    # resolved, and the one that stops a configured proxy resolving it instead.
    assert LOOPBACK_ONLY_RESOLVER_RULE in command
    assert NO_PROXY_FLAG in command
    assert "--headless=new" in BROWSER_FLAGS


def test_the_resolver_rule_is_what_stops_the_page_reaching_out(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """A guard that fires: with the rule the request never happens, without it it does.

    Both halves are in one test on purpose.  The second half is what makes the
    first mean anything -- an assertion that a server received no request is
    worth nothing until the same setup has been shown to deliver one.

    What this proves is that **LocalCanvas asks for the cage**, which is the
    part LocalCanvas owns and the part that can regress. That a real Chrome
    honours ``--host-resolver-rules`` was measured against a real Chrome and a
    real ComfyUI (`docs/privacy-security.md`); no unit test can re-prove it.
    """

    with Beacon() as beacon:
        outbound = [{"host": "a-public-model-host", "url": beacon.url}]

        caged = Browser(
            tmp_path / "caged",
            monkeypatch,
            default={"ok": True, "output": converted_graph()},
            outbound=outbound,
        )
        with make_bridge(comfy.base_url, caged) as bridge:
            assert one(bridge, ui_graph()).succeeded
        assert caged.saw()["outbound"] == [
            {"host": "a-public-model-host", "outcome": NAME_NOT_RESOLVED}
        ]
        assert beacon.hits == [], "the caged browser reached the beacon"

        # The same run with the rule taken out of the command LocalCanvas
        # builds. Mutating the constant is the whole-decision mutation: there
        # is one rule, and this is it gone.
        monkeypatch.setattr(
            bridge_module, "LOOPBACK_ONLY_RESOLVER_RULE", "--a-flag-that-cages-nothing"
        )
        loose = Browser(
            tmp_path / "loose",
            monkeypatch,
            default={"ok": True, "output": converted_graph()},
            outbound=outbound,
        )
        with make_bridge(comfy.base_url, loose) as bridge:
            assert one(bridge, ui_graph()).succeeded
        assert loose.saw()["outbound"] == [
            {"host": "a-public-model-host", "outcome": "RESPONSE"}
        ]
        assert beacon.hits == ["/beacon"], "the uncaged browser reached nothing"


def test_the_browser_is_found_on_the_machine_and_never_fetched() -> None:
    """Discovery is a list of local paths checked with ``isfile``, and no more."""

    looked_at = []

    def exists(path: str) -> bool:
        looked_at.append(path)
        return path.endswith("second.exe")

    assert find_browser(("first.exe", "second.exe", "third.exe"), exists=exists) == (
        "second.exe",
    )
    # It stopped at the first one that was there rather than collecting them.
    assert looked_at == ["first.exe", "second.exe"]
    assert find_browser(("nothing.exe",), exists=lambda path: False) is None

    # Nothing in the shipped list is a thing that could be downloaded.
    for candidate in BROWSER_CANDIDATES:
        assert os.path.isabs(candidate), candidate
        assert "://" not in candidate, candidate
    assert no_browser_reason(("a.exe",)).startswith("no installed browser was found")
    assert "never downloads one" in no_browser_reason(("a.exe",))


def test_a_run_uses_a_temporary_profile_of_its_own_and_removes_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The user's browser profile is never named, and ours does not survive."""

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        assert one(bridge, ui_graph()).succeeded
        profile = browser.saw()["profile_dir"]
        assert Path(profile).is_dir(), "the profile did not exist while it was in use"

    assert profile, "no profile directory was passed at all"
    assert Path(profile).parent == Path(tempfile.gettempdir()), profile
    assert "localcanvas-conversion-" in Path(profile).name
    assert not Path(profile).exists(), "the temporary profile outlived the run"


def test_only_a_profile_this_module_made_is_ever_deleted(tmp_path: Path) -> None:
    """The safety catch on the one recursive delete in the package.

    Nothing in the shipped code passes a path from outside -- the only value
    that reaches the removal is one ``mkdtemp`` returned moments earlier. The
    check exists because of what an *edit* could do, and that is not
    hypothetical: while this card was under review, a mutation asking "can the
    user's own browser profile be used?" pointed ``--user-data-dir`` at a real
    Chrome profile, and the ``close()`` that followed deleted it.

    Both halves, so the refusal is a decision and not an accident of the
    fixture: a directory this module made is removed, and five that it did not
    are left exactly where they are.

    **Each refusal is decided by a different one of the conditions**, which is
    the whole reason the fixture looks like this. An earlier version of this
    test had four cases and every one of them was refused for having the wrong
    name, so dropping the "sits directly in the temporary directory" condition
    left the suite green -- two guards over one property, only one of them
    tested. The two cases carrying the real prefix are the ones that reach the
    depth condition, and they exist for that alone.

    Nothing here ever names a real browser profile. Every directory is one this
    test made, under ``tmp_path`` or the system temporary directory.
    """

    prefix = bridge_module.PROFILE_PREFIX

    ours = tempfile.mkdtemp(prefix=prefix)
    (Path(ours) / "Preferences").write_text("{}", encoding="utf-8")
    assert bridge_module.is_own_profile(ours)
    assert bridge_module.remove_own_profile(ours) is True
    assert not Path(ours).exists()

    # Someone else's, one condition at a time. The comment on each says which
    # condition is the *only* one refusing it.
    elsewhere = tmp_path / "User Data"                    # no prefix, not in temp
    elsewhere.mkdir()

    wrong_name = Path(tempfile.mkdtemp(prefix="chrome-user-data-"))  # prefix only

    planted = tmp_path / (prefix + "planted")             # DEPTH only: right
    planted.mkdir()                                        # name, wrong parent

    deep = Path(tempfile.mkdtemp(prefix=prefix)) / (prefix + "inner")
    deep.mkdir()                                           # DEPTH only: right
                                                           # name, one level down
    made = [elsewhere, wrong_name, planted, deep]
    for path in made:
        (path / "Preferences").write_text("mine", encoding="utf-8")

    try:
        # The two that are refused for their *depth* alone would be accepted by
        # every other condition, so this is the assertion that a dropped depth
        # check fails on.
        assert planted.name.startswith(prefix) and deep.name.startswith(prefix)
        assert planted.is_dir() and deep.is_dir()

        for path in made:
            assert bridge_module.is_own_profile(str(path)) is False, path
            assert bridge_module.remove_own_profile(str(path)) is False, path
            assert (path / "Preferences").read_text(encoding="utf-8") == "mine", path

        # A path that is not a directory at all, and one that is empty.
        not_a_directory = Path(tempfile.mkdtemp(prefix=prefix))
        file_path = not_a_directory / "x"
        file_path.write_text("", encoding="utf-8")
        assert bridge_module.remove_own_profile(str(file_path)) is False
        assert bridge_module.remove_own_profile("") is False
    finally:
        shutil.rmtree(str(wrong_name), ignore_errors=True)
        shutil.rmtree(str(deep.parent), ignore_errors=True)


def test_a_link_planted_in_the_temp_directory_does_not_borrow_its_answer(
    tmp_path: Path,
) -> None:
    """The resolution half, which the conditions above cannot reach.

    A directory junction *inside* the temporary directory, carrying the right
    prefix, pointing at somewhere else entirely. Every condition answers yes
    about the link itself; only resolving it first sees that what it names does
    not live in the temporary directory at all. Without the resolution the
    removal would follow the junction and delete the target's contents -- which
    is exactly the shape of the incident this guard was added for.

    The target is a directory this test made under ``tmp_path``, so a broken
    guard destroys nothing but the fixture and fails loudly. A junction is used
    rather than a symbolic link because it needs no elevation on Windows; where
    one cannot be made, this skips and says so rather than passing quietly.
    """

    target = tmp_path / "somebody elses data"
    target.mkdir()
    (target / "Preferences").write_text("mine", encoding="utf-8")

    link = Path(tempfile.gettempdir()) / (
        bridge_module.PROFILE_PREFIX + "link-" + uuid.uuid4().hex
    )
    if not make_junction(link, target):
        pytest.skip("this machine cannot create a directory junction")

    try:
        # It passes every check that looks at the name and the shape.
        assert link.name.startswith(bridge_module.PROFILE_PREFIX)
        assert link.is_dir()
        assert link.parent == Path(tempfile.gettempdir())

        assert bridge_module.is_own_profile(str(link)) is False
        assert bridge_module.remove_own_profile(str(link)) is False
        assert (target / "Preferences").read_text(encoding="utf-8") == "mine"
    finally:
        # rmdir removes the reparse point; rmtree would walk through it.
        try:
            os.rmdir(str(link))
        except OSError:
            pass


def test_no_prompt_is_ever_queued_in_order_to_export(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """Nothing is submitted -- and the recorder that says so is shown to work.

    The second half is the point. ``comfy.requests`` staying free of a
    ``POST /prompt`` means nothing until the same fake has been made to record
    one, so the stand-in browser is scripted to queue a prompt and the recorder
    catches it.
    """

    browser = Browser(
        tmp_path / "quiet",
        monkeypatch,
        default={"ok": True, "output": converted_graph()},
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        assert one(bridge, ui_graph()).succeeded

    assert [item for item in comfy.requests if item.endswith("/prompt")] == []
    assert comfy.submissions == []
    assert sorted({item for item in comfy.requests}) == [
        "GET /object_info",
        "GET /system_stats",
    ]

    noisy = Browser(
        tmp_path / "noisy",
        monkeypatch,
        default={"ok": True, "output": converted_graph()},
        queue=comfy.base_url,
    )
    with make_bridge(comfy.base_url, noisy) as bridge:
        assert one(bridge, ui_graph()).succeeded

    assert [item for item in comfy.requests if item.endswith("/prompt")] == [
        "POST /prompt"
    ], "the recorder cannot see a queued prompt, so its silence proves nothing"


def test_the_bridge_opens_no_file_at_all(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """Sources reach the bridge as bytes; it has no path to read or write.

    The read-only promise is kept by construction rather than by care: there is
    no filesystem path in :meth:`ConversionBridge.convert`'s signature, so a
    future change that wanted to rewrite a source would have to add one.
    """

    import inspect  # noqa: PLC0415

    signature = inspect.signature(bridge_module.ConversionBridge.convert)
    assert list(signature.parameters) == ["self", "raw", "content_hash"]

    source = tmp_path / "a workflow.json"
    source.write_text(json.dumps(ui_graph()), encoding="utf-8")
    before = source.read_bytes()

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        assert one(bridge, json.loads(before.decode("utf-8"))).succeeded

    assert source.read_bytes() == before


# ==========================================================================
# The output came from ComfyUI, and is checked before it is believed
# ==========================================================================


def test_the_converted_graph_is_the_one_the_browser_produced(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """Traced by a value only the stand-in browser could know.

    It invents a nonce at start-up and stamps it into every node it converts.
    Nothing in this process knows it beforehand, so a graph carrying it came
    through the socket -- and the companion test below shows what happens to
    this assertion when the bridge stops going through it.
    """

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph(7)}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        result = one(bridge, ui_graph())

    nonce = browser.saw()["nonce"]
    assert nonce, "the stand-in browser recorded no nonce"
    assert result.status is ConversionStatus.CONVERTED
    assert result.document["10"]["_meta"]["produced_by"] == nonce
    assert result.document["20"]["inputs"]["seed"] == 7
    # And the bridge really did hand the source over: the browser recorded one
    # conversion request, not just a readiness probe.
    assert [item for item in browser.saw()["expressions"] if item.startswith("convert")]


def test_a_bridge_that_answered_from_itself_would_carry_no_such_trace(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The mutation the test above dies on, made explicit.

    A bridge whose ``convert`` returns a canned graph passes every assertion
    about shape, state and importability -- and fails on the trace, because it
    never went near the boundary. That is exactly the fault injection the card
    names, written down so nobody has to guess whether the guard bites.
    """

    canned = converted_graph(7)

    def fabricate(self, raw, *, content_hash):  # noqa: ARG001
        return bridge_module.Conversion(
            status=ConversionStatus.CONVERTED, document=canned
        )

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph(7)}
    )
    monkeypatch.setattr(bridge_module.ConversionBridge, "convert", fabricate)
    with make_bridge(comfy.base_url, browser) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.CONVERTED, "the mutation was not applied"
    assert "_meta" not in result.document["10"], (
        "the canned answer carries a trace it could not have; the guard above "
        "would not distinguish it"
    )
    assert not browser.launched, "a fabricating bridge should not even launch one"


def test_a_node_with_no_class_type_is_a_failure_and_not_an_import(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """Measured against a real ComfyUI: an unknown node converts to this.

    ``graphToPrompt`` succeeds and produces a node with no ``class_type`` at
    all. Believing a success flag would import a graph that cannot run, so the
    result is put back through the same ``classify()`` a hand-made export faces.
    """

    browser = Browser(
        tmp_path,
        monkeypatch,
        default={"ok": True, "output": {"1": {"inputs": {"UNKNOWN": "x"}}}},
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.FAILED
    assert result.category == CATEGORY_NOT_IMPORTABLE
    assert result.document is None, "a failed conversion produced a graph"
    assert "carries no 'class_type'" in result.detail
    assert "not installed in this ComfyUI" in result.detail


def test_an_empty_canvas_is_a_failure_and_not_an_empty_import(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """Also measured: an empty canvas converts into ``{}``, which is not a graph."""

    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": {}})
    with make_bridge(comfy.base_url, browser) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.FAILED
    assert result.category == CATEGORY_NOT_IMPORTABLE
    assert result.document is None


def test_a_refusal_from_the_frontend_keeps_its_own_name(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """ComfyUI's own error, relayed rather than reworded.

    ``InvalidLinkError`` is what a real frontend raises for a link to a node
    that is not there, measured. A user searching for that word must find it in
    the report.
    """

    browser = Browser(
        tmp_path,
        monkeypatch,
        default={
            "ok": False,
            "name": "InvalidLinkError",
            "message": "No link found in parent graph for id [1] slot [0] samples",
        },
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.FAILED
    assert result.category == CATEGORY_CONVERSION_REJECTED
    assert result.document is None
    assert "InvalidLinkError" in result.detail
    assert "No link found in parent graph" in result.detail


def test_a_subgraph_conversion_is_taken_exactly_as_comfyui_expanded_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The node ids ComfyUI produces for a subgraph survive untouched.

    Measured against a real installation: a workflow whose canvas holds a
    subgraph converts into nodes named ``<container>:<inner>``. Nothing here
    flattens, renames or reinterprets them -- they are keys in the graph that
    will run, and a helpful tidy-up would break every binding in it.
    """

    expanded = {
        "9": {"class_type": "SaveImage", "inputs": {"images": ["57:8", 0]}},
        "57:8": {"class_type": "VAEDecode", "inputs": {"samples": ["57:3", 0]}},
        "57:3": {"class_type": "KSampler", "inputs": {"seed": 1}},
    }
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": expanded})
    with make_bridge(comfy.base_url, browser) as bridge:
        result = one(bridge, ui_graph())

    assert result.succeeded
    assert sorted(result.document) == ["57:3", "57:8", "9"]
    assert result.document["9"]["inputs"]["images"] == ["57:8", 0]


# ==========================================================================
# When the bridge cannot run at all
# ==========================================================================


def test_an_unreachable_comfyui_is_actionable_and_launches_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Named command, plain statement, and no browser started for nothing."""

    with FakeComfy() as running:
        dead_url = running.base_url
    # The server is stopped, so the port is free and the address refuses.

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    launcher = CountingPopen()
    with make_bridge(dead_url, browser, popen=launcher) as bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.UNAVAILABLE
    assert result.category == CATEGORY_COMFY_UNREACHABLE
    assert result.document is None
    assert "scripts\\start.ps1" in result.detail
    assert "was not converted" in result.detail
    assert "nothing was guessed" in result.detail
    assert launcher.count == 0, "a browser was launched for a ComfyUI that is not there"
    assert not browser.launched


def test_a_comfyui_still_loading_is_told_apart_from_one_that_is_not_there(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Two situations, two actions: start it, or wait for it.

    They must not share a message. Telling somebody to run ``start.ps1``
    against a ComfyUI that is already running and importing custom nodes is
    advice that ends in two of them.
    """

    with FakeComfy(ready=False) as running:
        browser = Browser(
            tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
        )
        launcher = CountingPopen()
        with make_bridge(running.base_url, browser, popen=launcher) as bridge:
            result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.UNAVAILABLE
    assert result.category == CATEGORY_COMFY_NOT_READY
    assert "has not finished loading its nodes" in result.detail
    assert "Wait until ComfyUI has finished starting" in result.detail
    assert "start.ps1" not in result.detail
    assert launcher.count == 0


def test_no_installed_browser_is_actionable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    bridge = make_bridge(comfy.base_url, candidates=("C:\\nowhere\\browser.exe",))
    with bridge:
        result = one(bridge, ui_graph())

    assert result.status is ConversionStatus.UNAVAILABLE
    assert result.category == CATEGORY_BROWSER_NOT_FOUND
    assert result.document is None
    assert "Install Google Chrome or Microsoft Edge" in result.detail


def test_the_whole_run_stops_at_the_first_unavailability_and_says_so_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Every workflow gets the same answer, and ComfyUI is asked once.

    A dead ComfyUI is one fact about the run, not sixty-six facts about
    workflows -- and probing it once per workflow would make a slow failure out
    of an instant one.
    """

    with FakeComfy() as running:
        dead_url = running.base_url

    probes = []

    def counted(url: str, timeout: float):
        probes.append(url)
        raise OSError("refused")

    bridge = bridge_module.ConversionBridge(dead_url, get_json=counted)
    with bridge:
        first = one(bridge, ui_graph("a"))
        second = one(bridge, ui_graph("b"))

    assert first.category == second.category == CATEGORY_COMFY_UNREACHABLE
    assert len(probes) == 1, probes


# ==========================================================================
# Identity -- what a cached conversion is keyed on
# ==========================================================================


def test_the_identity_moves_when_the_installed_nodes_do() -> None:
    """The thing that changes what a conversion *means* is the node set."""

    base = ComfyIdentity.build(
        comfyui_version="1.0", frontend_version="2.0", node_types=["A", "B"]
    )
    same_order = ComfyIdentity.build(
        comfyui_version="1.0", frontend_version="2.0", node_types=["B", "A"]
    )
    added = ComfyIdentity.build(
        comfyui_version="1.0", frontend_version="2.0", node_types=["A", "B", "C"]
    )
    newer = ComfyIdentity.build(
        comfyui_version="1.1", frontend_version="2.0", node_types=["A", "B"]
    )
    frontend = ComfyIdentity.build(
        comfyui_version="1.0", frontend_version="2.1", node_types=["A", "B"]
    )
    packaged = ComfyIdentity.build(
        comfyui_version="1.0",
        frontend_version="2.0",
        node_types=["A", "B"],
        packages={"comfyui-frontend-package": "2.0.1"},
    )

    assert base.digest == same_order.digest, "the order of a set changed the identity"
    assert len({base.digest, added.digest, newer.digest, frontend.digest,
                packaged.digest}) == 5
    assert base.node_type_count == 2
    assert base.digest.startswith("sha256:")


def test_the_identity_keeps_nothing_machine_specific(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """``/system_stats`` carries an absolute path; none of it is recorded.

    Real ComfyUI reports ``system.argv``, which on the machine this was written
    on holds the user's own directory. The identity is four fields and a
    digest, and this is the test that keeps it that way.
    """

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    with make_bridge(comfy.base_url, browser) as bridge:
        one(bridge, ui_graph())
        identity = bridge.identity

    assert identity is not None
    assert sorted(identity.to_document()) == [
        "comfyui_version",
        "digest",
        "frontend_version",
        "node_type_count",
    ]
    assert identity.comfyui_version == "fake"
    assert identity.frontend_version == "fake-frontend"
    rendered = json.dumps(identity.to_document())
    assert ":\\" not in rendered and "argv" not in rendered


def test_two_identical_sources_cost_one_conversion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, comfy: FakeComfy
) -> None:
    """The same bytes twice: asked once, answered twice, recorded twice."""

    browser = Browser(
        tmp_path, monkeypatch, default={"ok": True, "output": converted_graph()}
    )
    graph = ui_graph()
    with make_bridge(comfy.base_url, browser) as bridge:
        first = one(bridge, graph)
        second = one(bridge, graph)

    assert first.succeeded and second.succeeded
    assert first.document == second.document
    conversions = [
        item for item in browser.saw()["expressions"] if item.startswith("convert")
    ]
    assert len(conversions) == 1, conversions
