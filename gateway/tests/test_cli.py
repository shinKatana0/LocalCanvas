"""The offline validation entry point.

A curator must be able to check a definition without starting a generation, so
nothing here may need ComfyUI, a gateway or a network.
"""

from __future__ import annotations

import io

import pytest

from conftest import EXAMPLES_ROOT, PROMPT_FIELD
from localcanvas_gateway.workflows.cli import main


def run(*argv):
    stream = io.StringIO()
    code = main([str(item) for item in argv], stream=stream)
    return code, stream.getvalue()


def test_a_valid_registry_exits_zero_and_lists_what_loaded(builder):
    builder.add("one", PROMPT_FIELD, workflow_id="one")
    builder.add("two", PROMPT_FIELD, workflow_id="two")

    code, output = run(builder.root)

    assert code == 0
    assert "[ OK ] one" in output
    assert "[ OK ] two" in output
    assert "[FAIL]" not in output
    assert "2 workflows loaded, 0 rejected" in output


def test_the_published_examples_validate_offline():
    code, output = run(EXAMPLES_ROOT)

    assert code == 0, output
    assert "3 workflows loaded, 0 rejected" in output


def test_a_rejected_workflow_exits_one_and_prints_the_reason(builder):
    builder.add("good", PROMPT_FIELD, workflow_id="good")
    bad = builder.add(
        "bad",
        """
        - id: steps
          label: Steps
          type: integer
          bind: {node: "999", input: steps}
        """,
        workflow_id="bad",
    )

    code, output = run(builder.root)

    assert code == 1
    assert "[ OK ] good" in output
    assert str(bad) in output
    assert "'999'" in output
    assert "'steps'" in output
    assert "1 workflow loaded, 1 rejected" in output


def test_quiet_prints_problems_only(builder):
    builder.add("good", PROMPT_FIELD, workflow_id="good")
    builder.add("bad", PROMPT_FIELD, workflow_id="bad", write_json=False)

    code, output = run("--quiet", builder.root)

    assert code == 1
    assert "[ OK ]" not in output
    assert "[FAIL]" in output


def test_an_unusable_root_exits_two(tmp_path):
    code, output = run(tmp_path / "nowhere")

    assert code == 2
    assert "[FAIL]" in output
    assert "does not exist" in output


def test_an_empty_root_exits_zero(tmp_path):
    empty = tmp_path / "empty registry"
    empty.mkdir()

    code, output = run(empty)

    assert code == 0
    assert "0 workflows loaded, 0 rejected" in output


def test_the_root_argument_is_required():
    with pytest.raises(SystemExit):
        main([], stream=io.StringIO())
