"""LocalCanvas never follows an options route (T-0187).

Some runtimes declare a ``COMBO`` whose choices are not in ``/object_info`` at
all: the mapping beside the type name carries a ``remote`` route the browser
calls when it draws the widget.  The decision is that such a spec declares
**nothing**, and that the importer makes **no** request to the route -- what
the runtime states in ``/object_info`` is the whole of what is read.

Both halves are shown able to fail: the reader does read the same input once an
``options`` list sits beside the route, and the stand-in ComfyUI's request
recorder does record a request to the route when one is made.

Every class name, input name, value and route below is invented.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List
from urllib.error import HTTPError
from urllib.request import urlopen

import pytest

from localcanvas_gateway.comfy.fake import FakeComfy
from localcanvas_gateway.workflows.sync import run_sync
from localcanvas_gateway.workflows.sync.contract import (
    declared_numeric,
    declared_options,
    declared_string,
    declared_structural_keys,
    read_object_info,
)
from localcanvas_gateway.workflows.sync.report import report_document
from localcanvas_gateway.workflows.sync.semantics import Exposure, classify

from bridge_fixtures import Browser, make_bridge, ui_graph
from sync_fixtures import SyncWorkspace, write_json

SAMPLER = "ExampleRemoteSampler"
UNSETTLED = "mixing"
ROUTE = "/example/listing/choices"


def remote_spec(**extra: Any) -> List[Any]:
    config: Dict[str, Any] = {
        "remote": {"route": ROUTE, "refresh_button": True},
        "multiselect": False,
    }
    config.update(extra)
    return ["COMBO", config]


def graph() -> Dict[str, Any]:
    return {
        "1": {
            "class_type": SAMPLER,
            "inputs": {"seed": 7, UNSETTLED: "steady", "positive": ["2", 0]},
        },
        "2": {"class_type": "ExampleTextEncode", "inputs": {"text": "a quiet street at dawn"}},
    }


def test_a_route_and_no_options_declares_nothing() -> None:
    spec = remote_spec()

    assert declared_options(spec) is None
    assert declared_numeric(spec) is None
    assert declared_structural_keys(spec) is None
    assert declared_string(spec) is None
    contract = read_object_info(
        {SAMPLER: {"input": {"required": {UNSETTLED: spec}}, "output": ["LATENT"]}},
        identity_digest="sha256:remote",
    )
    assert contract.declares(SAMPLER, UNSETTLED) is False
    assert contract.options_for(SAMPLER, UNSETTLED) is None

    # The reader can see this input: an options list beside the route is read.
    beside = remote_spec(options=["steady", "drifting"])
    assert declared_options(beside) == ("steady", "drifting")


@pytest.fixture()
def workspace(tmp_path: Path) -> SyncWorkspace:
    return SyncWorkspace(tmp_path)


def test_a_whole_run_never_requests_the_route(
    workspace: SyncWorkspace, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    assert classify(UNSETTLED, "steady").exposure is Exposure.UNCERTAIN

    folder = workspace.add_source()
    write_json(folder / "a canvas.json", ui_graph("one"))
    workspace.write_config()
    browser = Browser(tmp_path, monkeypatch, default={"ok": True, "output": graph()})
    with FakeComfy() as comfy:
        comfy.installed_nodes = (SAMPLER,)
        comfy.node_inputs = {SAMPLER: {UNSETTLED: remote_spec()}}
        with make_bridge(comfy.base_url, browser) as bridge:
            report = run_sync(workspace.load(), bridge=bridge)
        during = list(comfy.requests)

        # The recorder is one that would have seen it.
        with pytest.raises(HTTPError):
            urlopen(comfy.base_url + ROUTE, timeout=5)
        assert comfy.requests[len(during):] == ["GET " + ROUTE]

    assert "GET /object_info" in during, "the run never read the declaration"
    assert sorted(set(during)) == ["GET /object_info", "GET /system_stats"]
    assert report.workflows[0].state.value == "NEEDS_REVIEW"
    assert report_document(report)["runtime_contract"]["declared"] == 0
