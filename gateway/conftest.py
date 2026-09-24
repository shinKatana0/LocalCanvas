"""Make the gateway package importable from the source tree.

The tests run against `gateway/localcanvas_gateway` directly, so no install
step stands between editing a module and running the suite.
"""

import sys
from pathlib import Path

GATEWAY_ROOT = Path(__file__).resolve().parent
if str(GATEWAY_ROOT) not in sys.path:
    sys.path.insert(0, str(GATEWAY_ROOT))
