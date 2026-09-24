"""``GET /api/v1/info`` -- the identity handshake (`docs/api.md`).

Every connection path ends here (`docs/connection.md`), and the app calls it
again whenever it reconnects, so it is cheap: one readiness probe against
ComfyUI, no registry work, no job work.

``capabilities`` is a promise, so it says only what this build actually does.
The app shows a Cancel button on the strength of one of these words, a media
picker on another, and opens a socket on a third, so each stays true only while
the endpoint behind it does what it says (`docs/recovery.md`).
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Request

from .. import __version__
from .state import API_VERSION, gateway

log = logging.getLogger(__name__)

router = APIRouter()

#: What this build can do.  Flipping one of these without implementing it is
#: how an app ends up showing a dead button, so each names what makes it true:
#:
#: * ``cancel`` -- ``POST /api/v1/jobs/{id}/cancel`` is served, asks ComfyUI to
#:   stop by whichever mechanism the job's position requires, and reports the
#:   state that actually resulted;
#: * ``media_upload`` -- ``POST /api/v1/media`` is served and a media field
#:   binds;
#: * ``events`` -- ``WS /api/v1/jobs/{id}/events`` is served.  True says the
#:   socket exists, not that it is required: a client that ignores it loses
#:   nothing but latency, because every message on it is a field of the
#:   snapshot that ``GET /api/v1/jobs/{id}`` already answers.
#:
#: ``translation`` is not here, because it is not a fact about this build: it
#: is a fact about *this PC*, and it is read off the configured stage on every
#: call (:meth:`TranslationService.capability`).
CAPABILITIES = {
    "cancel": True,  # T-0007
    "media_upload": True,  # T-0006
    "events": True,  # T-0007
}


@router.get("/info")
def info(request: Request) -> dict:
    state = gateway(request)
    health = state.comfy.health()
    if health.log_detail:
        log.info("ComfyUI health: %s (%s)", health.status.value, health.log_detail)
    return {
        "service": "localcanvas",
        "api_version": API_VERSION,
        "gateway_version": __version__,
        "display_name": state.config.identity.display_name,
        "comfy": {"status": health.status.value, "detail": health.detail},
        "capabilities": {
            **CAPABILITIES,
            # The one capability that is a block rather than a word, because
            # "yes" and "no" cannot tell a PC where the extra was never
            # installed from one where it is installed and switched off --
            # and only the first of those is fixed by installing it (T-0043).
            "translation": state.translation.capability().to_view(),
        },
    }


__all__ = ["router", "CAPABILITIES"]
