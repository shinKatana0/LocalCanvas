"""What every request handler needs, assembled once at startup.

Held on ``app.state`` rather than in module globals so that a test can build a
second gateway around a second fake ComfyUI without the two seeing each other.
"""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import Request

from typing import Optional

from ..comfy import ComfyClient, ComfyEvents
from ..config import RuntimeConfig
from ..jobs import JobStore
from ..media import MediaStore
from ..translation.service import TranslationService
from ..workflows import MediaValueResolver, Registry

#: Every path in this contract lives under it (`docs/api.md`).
API_PREFIX = "/api/v1"

#: The major API version the app negotiates against (`docs/api.md`).
API_VERSION = 1


@dataclass(frozen=True)
class GatewayState:
    """The gateway's live parts."""

    config: RuntimeConfig
    registry: Registry
    comfy: ComfyClient
    jobs: JobStore
    media: MediaStore
    #: Generated once per process (`--instance-id`, or `secrets.token_hex(16)`
    #: when it was not given), so that whoever is watching this gateway can
    #: tell it apart from a different process on the same port (`api/info.py`).
    instance_id: str
    #: What fills ``workflows.binding``'s seam for this gateway.  Held here
    #: rather than reached for inside the submit handler, so that the one place
    #: a media value is decided is visible in the wiring.
    media_resolver: MediaValueResolver
    #: The stage between validation and binding (`docs/api.md`).  Always
    #: present, and switched off by its own configuration rather than by being
    #: absent -- so there is one place that decides whether a submission is
    #: translated, and it is the configuration.
    translation: TranslationService
    #: The subscription to ComfyUI's event socket, where real progress comes
    #: from.  Optional because it is an optimization: a gateway built without
    #: one serves every documented endpoint and reports ``progress`` as null.
    events: Optional[ComfyEvents] = None


def gateway(request: Request) -> GatewayState:
    return request.app.state.gateway


__all__ = ["API_PREFIX", "API_VERSION", "GatewayState", "gateway"]
