"""The HTTP surface described by `docs/api.md`.

Nothing in this package knows what ComfyUI is.  It serves presentation views
from the registry and snapshots from the job store; the ComfyUI protocol lives
one layer down, in :mod:`localcanvas_gateway.comfy`.
"""

from .app import build_gateway, create_app, translation_summary
from .state import API_PREFIX, API_VERSION, GatewayState

__all__ = [
    "API_PREFIX",
    "API_VERSION",
    "GatewayState",
    "build_gateway",
    "create_app",
    "translation_summary",
]
