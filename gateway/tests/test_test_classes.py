"""The two classes of test, held by tests of their own (T-0156).

`conftest.py` makes two promises the public CI rests on: a deterministic test
can never reach the ports a live ComfyUI or gateway listens on, and an
integration test is skipped, with its reason printed, unless the run opts in.
Neither promise is visible in a green run -- a guard that never fires looks
exactly like one that is not installed -- so both are driven here.

Nothing here opens a connection to 8188 or 7801. The guard is exercised
through ``sys.audit``, which calls the installed hooks with the same event a
real ``socket.connect`` raises, and performs no network operation at all: if
the guard were missing, the call would simply return.
"""

from __future__ import annotations

import ast
import os
import socket
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import (
    INTEGRATION_SKIP_REASON,
    INTEGRATION_VARIABLE,
    LIVE_PORT_GUARD,
    LIVE_PORTS,
    LivePortRefused,
)

GATEWAY_ROOT = Path(__file__).resolve().parents[1]

#: A test the suite marks ``integration``; it has no network dependency, so
#: running it with the variable set contacts nothing.
INTEGRATION_NODE = (
    "tests/test_translation.py::"
    "test_the_real_argos_backend_translates_and_preserves_a_literal"
)


def _audited_connect(address) -> None:
    """Raise the event a socket connect raises, without any socket."""

    sys.audit("socket.connect", None, address)


@pytest.fixture
def forget_refusals():
    """Keep this file's deliberate attempts out of the per-test verdict."""

    before = len(LIVE_PORT_GUARD.attempts)
    yield
    del LIVE_PORT_GUARD.attempts[before:]


def test_the_live_ports_are_the_documented_defaults() -> None:
    assert LIVE_PORTS == {8188, 7801}


@pytest.mark.parametrize(
    "address",
    [
        ("127.0.0.1", 8188),
        ("127.0.0.1", 7801),
        ("localhost", 8188),
        ("192.0.2.42", 7801),
        ("::1", 8188, 0, 0),
    ],
)
def test_a_connect_to_a_live_port_is_refused_before_it_happens(
    address, forget_refusals
) -> None:
    before = len(LIVE_PORT_GUARD.attempts)

    with pytest.raises(LivePortRefused):
        _audited_connect(address)

    assert LIVE_PORT_GUARD.attempts[before:] == [address]


def test_the_refusal_is_not_an_oserror() -> None:
    """Client code turns an OSError into "unreachable" and carries on."""

    assert not issubclass(LivePortRefused, OSError)


@pytest.mark.parametrize("address", [("127.0.0.1", 8189), ("127.0.0.1", 0), "a-pipe-name"])
def test_any_other_destination_passes_untouched(address) -> None:
    before = len(LIVE_PORT_GUARD.attempts)

    _audited_connect(address)

    assert len(LIVE_PORT_GUARD.attempts) == before


def test_a_real_connection_elsewhere_still_works() -> None:
    """The guard sits on every connect in the run, so it must not break one."""

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        assert port not in LIVE_PORTS
        with socket.create_connection(("127.0.0.1", port), timeout=5):
            accepted, _ = listener.accept()
            accepted.close()


def _run_integration_node(enabled: bool) -> str:
    env = dict(os.environ)
    env.pop(INTEGRATION_VARIABLE, None)
    if enabled:
        env[INTEGRATION_VARIABLE] = "1"
    env["PYTHONPATH"] = str(GATEWAY_ROOT)
    result = subprocess.run(
        [sys.executable, "-m", "pytest", INTEGRATION_NODE, "-rs", "-p", "no:cacheprovider"],
        cwd=str(GATEWAY_ROOT),
        env=env,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=300,
    )
    return result.stdout + result.stderr


def test_an_integration_test_is_skipped_by_default_and_says_why() -> None:
    output = _run_integration_node(enabled=False)

    assert "1 skipped" in output, output
    assert INTEGRATION_SKIP_REASON in output, output


def test_the_variable_takes_the_integration_skip_away() -> None:
    """The control: the skip above must come from the variable, not the test.

    With the variable set the test is either run or skipped for a reason of its
    own (the translation extra absent), never for being integration.
    """

    output = _run_integration_node(enabled=True)

    assert INTEGRATION_SKIP_REASON not in output, output
    assert "1 passed" in output or "extra is not installed" in output, output


# ==========================================================================
# A second gate on an integration test decides before the integration one.
#
# pytest evaluates every ``skipif`` mark before any ``skip`` mark, and the
# integration skip is a ``skip`` mark conftest adds at collection. So a
# ``skipif`` on the same test wins whenever its condition is true, and the
# reason an ordinary run prints stops being "this is an integration test" --
# it becomes whatever that machine made true. Measured: with the translation
# extra installed the run above passed, and from a clean clone without it the
# same run read `1 failed, 2378 passed`.
#
# The check is static, over the source, so it holds for every test in the
# suite and not only for the one node the run above drives.
# ==========================================================================


def _decorator_mark_names(node: ast.AST) -> set:
    """The ``pytest.mark.NAME`` decorators on a function definition."""

    names = set()
    for decorator in getattr(node, "decorator_list", []):
        attribute = decorator.func if isinstance(decorator, ast.Call) else decorator
        if not isinstance(attribute, ast.Attribute):
            continue
        owner = attribute.value
        if isinstance(owner, ast.Attribute) and owner.attr == "mark":
            names.add(attribute.attr)
    return names


def integration_tests_with_a_second_gate(source: str) -> list:
    """Names of tests carrying both ``integration`` and a skip/skipif mark."""

    offenders = []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        marks = _decorator_mark_names(node)
        if "integration" in marks and (marks & {"skip", "skipif"}):
            offenders.append(node.name)
    return offenders


def test_no_integration_test_carries_a_second_skip_decorator() -> None:
    offenders = {}
    for path in sorted((GATEWAY_ROOT / "tests").glob("test_*.py")):
        found = integration_tests_with_a_second_gate(path.read_text(encoding="utf-8"))
        if found:
            offenders[path.name] = found

    assert offenders == {}, (
        "these tests would print a skip reason that depends on this machine "
        "rather than on the integration gate: {}".format(offenders)
    )


def test_the_check_above_sees_the_decorator_pair_it_is_looking_for() -> None:
    """The control: without it the check above passes by reading nothing."""

    both = (
        "@pytest.mark.integration\n"
        "@pytest.mark.skipif(missing, reason='x')\n"
        "def test_two_gates():\n    pass\n"
    )
    assert integration_tests_with_a_second_gate(both) == ["test_two_gates"]
    assert integration_tests_with_a_second_gate(
        "@pytest.mark.integration\ndef test_one_gate():\n    pass\n"
    ) == []
    assert integration_tests_with_a_second_gate(
        "@pytest.mark.skipif(missing, reason='x')\ndef test_plain():\n    pass\n"
    ) == []
    # The suite really does hold a test marked integration, so the sweep above
    # is reading files that can offend rather than an empty set.
    translation = (GATEWAY_ROOT / "tests" / "test_translation.py").read_text(
        encoding="utf-8"
    )
    assert "@pytest.mark.integration" in translation
