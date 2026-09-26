"""Assembling the FastAPI application.

Nine routes, all under ``/api/v1``, and nothing else -- no interactive docs,
no OpenAPI schema, no health page of our own invention.  The gateway is the one
LAN-facing surface on the machine and has no authentication in v0.1
(`docs/privacy-security.md`), so every endpoint that exists is one someone has
to have thought about.  ``GET /api/v1/info`` is the health page.
"""

from __future__ import annotations

import logging
import secrets
from contextlib import asynccontextmanager
from typing import AsyncIterator, Iterable, Optional

from fastapi import FastAPI

from .. import __version__
from ..comfy import ComfyClient, ComfyEvents
from ..config import RuntimeConfig
from ..jobs import JobStore
from ..media import ComfyInputResolver, MediaStore
from ..translation import LanguagePair, TranslationCapability, Translator
from ..translation.service import TranslationService, WarmUp
from ..workflows import Registry, load_registry
from . import events, info, jobs, media, workflows
from .errors import install_error_handlers
from .state import API_PREFIX, GatewayState

log = logging.getLogger(__name__)


def translation_summary(
    capability: TranslationCapability, warm_up: Optional[WarmUp] = None
) -> str:
    """One line saying what this PC can translate, for the startup banner.

    ASCII, because it is printed to a Windows console whose code page is not
    ours to choose (`__main__.py`), and short, because it is one line in a
    block a person reads at a glance: the pairs when there are pairs, and
    otherwise which of the two setup steps is missing -- the two that are
    fixed by two different commands.

    ``warm_up`` is what loading those models cost and which of them refused to
    load (T-0122).  It is optional because a capability can be described
    without one, and when there is nothing to say -- a PC that warmed nothing
    -- this line reads exactly as it did before warming existed.
    """

    if not capability.enabled:
        return "off"
    if capability.pairs:
        found = ", ".join(
            "{}->{}".format(source, target) for source, target in capability.pairs
        )
        # The trade this makes, priced, on the line the person at the PC is
        # already reading: the gateway started this much later so that the
        # first generation would not.
        if warm_up is not None and warm_up.loaded:
            found += " (models loaded in {:.1f}s)".format(warm_up.seconds)
        if warm_up is not None and warm_up.failed:
            found += "; {} would not load on this PC".format(_pairs_text(warm_up.failed))
        return found
    if not capability.installed:
        return "switched on, but not installed on this PC"
    if warm_up is not None and warm_up.failed:
        # Installed, and unusable.  Saying "no models are installed" here would
        # send the person to install what they already have.
        return "switched on, but {} would not load on this PC".format(
            _pairs_text(warm_up.failed)
        )
    return "switched on, but no language models are installed on this PC"


def _pairs_text(pairs: Iterable[LanguagePair]) -> str:
    return ", ".join("{}->{}".format(source, target) for source, target in pairs)


def build_gateway(
    config: RuntimeConfig,
    *,
    comfy: Optional[ComfyClient] = None,
    registry: Optional[Registry] = None,
    media_store: Optional[MediaStore] = None,
    translator: Optional[Translator] = None,
    instance_id: Optional[str] = None,
) -> GatewayState:
    """Load the registry and open the ComfyUI client for one configuration.

    A rejected workflow is logged and left out; one bad definition never stops
    the gateway from starting (`docs/workflow-schema.md`).

    ``instance_id`` names *this* process (`--instance-id`, validated by the
    CLI).  Left out -- which every caller but the CLI does -- a fresh one is
    generated here, so every gateway this function ever builds has one, and
    two built without an explicit id never collide on it.
    """

    loaded = registry if registry is not None else load_registry(config.workflows_registry)
    for diagnostic in loaded.diagnostics:
        log.warning("workflow rejected: %s", diagnostic)

    client = comfy if comfy is not None else ComfyClient(config.comfy.base_url)
    store = (
        media_store
        if media_store is not None
        else MediaStore(
            ttl_seconds=config.media.ttl_seconds,
            max_upload_bytes=config.media.max_upload_bytes,
            max_store_bytes=config.media.max_store_bytes,
        )
    )
    log.info(
        "temporary media store opened at %s (image %s MB, video %s MB, store %s MB, "
        "kept %s s)",
        store.root,
        config.media.max_image_megabytes,
        config.media.max_video_megabytes,
        config.media.max_store_megabytes,
        config.media.ttl_seconds,
    )
    jobs_store = JobStore(client)
    translation = TranslationService(config.prompt_translation, translator=translator)
    # The one expensive question about translation is asked here and never in a
    # request: reading which language models are installed reaches the backend,
    # and reaching the backend imports it.  Assembling a gateway happens before
    # it listens, so the PC that configured translation pays that once with
    # nobody waiting, and `GET /api/v1/info` then imports nothing at all
    # (T-0043).  On every other machine this walks nothing.
    translation.prepare()
    # And then load them, here, rather than in the first ``POST /api/v1/jobs``
    # that needs one.  Walking the models says which are installed; it does not
    # read one into memory, and the first sentence through a pair does -- 7.3 s
    # measured, past the app's 8 s job timeout, paid by whoever pressed
    # Generate first (T-0122).  A gateway is assembled before it listens, so
    # this is the moment at which that cost belongs, and a warm-up that fails
    # costs this PC its translation and nothing else.
    warm_up = translation.warm()
    capability = translation.capability()
    if config.prompt_translation.enabled:
        log.info(
            "prompt translation is on: %s -> %s, quoted literals %s",
            ", ".join(config.prompt_translation.sources),
            config.prompt_translation.target,
            "preserved" if config.prompt_translation.preserve_quoted_literals else "translated",
        )
        log.info(
            "prompt translation models on this PC: %s",
            translation_summary(capability, warm_up),
        )
    return GatewayState(
        config=config,
        registry=loaded,
        comfy=client,
        jobs=jobs_store,
        media=store,
        instance_id=instance_id if instance_id is not None else secrets.token_hex(16),
        # The seam `workflows/binding.py` left for LCM-006, filled once, here.
        # Nothing else in the gateway decides what a media field binds to.
        media_resolver=ComfyInputResolver(store, client),
        # Built whatever the configuration says; it is the service that knows
        # it is switched off.  Constructing it imports no translation backend
        # (`translation/backends.py`).
        translation=translation,
        # Built here, started by the lifespan below: a gateway that is only
        # assembled -- by a test, or by the CLI printing its configuration --
        # opens no socket to ComfyUI.
        events=ComfyEvents(client.events_url, jobs_store),
    )


def create_app(state: GatewayState) -> FastAPI:
    """The application serving `docs/api.md`, and only that."""

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        if state.events is not None:
            # Nothing waits for it to connect, and nothing fails if it never
            # does: it carries progress, and progress is optional by contract.
            state.events.start()
        yield
        if state.events is not None:
            state.events.stop()
        # The media store owns a temporary directory holding someone's
        # photographs.  A gateway that exits leaves nothing of theirs behind.
        state.media.close()

    app = FastAPI(
        title="LocalCanvas gateway",
        version=__version__,
        # No /docs, /redoc or /openapi.json: the contract lists the endpoints.
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )
    app.state.gateway = state
    install_error_handlers(app)
    app.include_router(info.router, prefix=API_PREFIX)
    app.include_router(workflows.router, prefix=API_PREFIX)
    app.include_router(media.router, prefix=API_PREFIX)
    app.include_router(jobs.router, prefix=API_PREFIX)
    app.include_router(events.router, prefix=API_PREFIX)
    return app


__all__ = ["build_gateway", "create_app", "translation_summary"]
