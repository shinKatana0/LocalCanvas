"""Test double for the gateway package.

Placed on PYTHONPATH by scripts/tests/run_tests.py so that the runtime scripts
can be driven through their real seams --

    <python> -m localcanvas_gateway config --config <path>
    <python> -u -m localcanvas_gateway --config <path> --host H --port P
                                       --endpoint URL --no-qr
    <python> -m localcanvas_gateway qr --endpoint <url>

-- without the gateway half of T-0003 being installed. It is never importable
in a real run: .venv contains the real package, and this directory is on no
path but the harness's.

Everything the scripts consume lives in ``__main__``; there is no importable
loader here on purpose, because the seam is a process boundary and the scripts
must never reach across it any other way.
"""

__version__ = "0.0.0-test-stub"
