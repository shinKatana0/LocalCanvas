"""``POST /api/v1/media`` -- one file, uploaded before the job that uses it.

`docs/api.md` puts the upload *before* submission for two reasons the app can
feel: progress is a property of the request body, so a real byte count exists
without a progress endpoint; and a submission that has to be retried -- a
dropped connection, a ComfyUI that was not ready -- costs nothing extra,
because the file is already here.

**One endpoint, and no others.**  There is no ``GET /media``, no
``GET /media/{id}``, no delete: the gateway holds media, it does not publish it
(`docs/api.md` -- "not a library: no listing endpoint, no permanent store, no
server-side gallery").  Anything the app needs to know about a file it uploaded
is in the answer it got.

The body is never held whole in memory.  It is read in chunks straight to the
store's disk, and the size ceiling is applied while that happens, so an
oversized video is refused partway rather than after arriving.

``file`` and ``kind`` are declared optional and checked here rather than by
FastAPI's own required-field machinery, whose refusal is a 400 saying "expected
JSON" -- true of every other endpoint in this contract and false of this one.
A missing part is answered in the documented shape, naming the part that was
missing.
"""

from __future__ import annotations

import logging
from typing import Iterator, Optional

from fastapi import APIRouter, File, Form, Request, UploadFile

from ..errors import ApiError
from ..media import CHUNK_BYTES
from .state import gateway

log = logging.getLogger(__name__)

router = APIRouter()


@router.post("/media", status_code=201)
def upload_media(
    request: Request,
    file: Optional[UploadFile] = File(default=None),
    kind: Optional[str] = Form(default=None),
) -> dict:
    """Store one uploaded file and answer with its ``media_id`` document."""

    if file is None:
        raise ApiError(
            status_code=400,
            code="invalid_request",
            message="No file arrived with that upload.",
            field="file",
        )

    state = gateway(request)
    item = state.media.store(
        kind=kind,
        filename=file.filename,
        content_type=file.content_type,
        chunks=_chunks(file),
    )
    return item.to_view()


def _chunks(file: UploadFile) -> Iterator[bytes]:
    """The uploaded body, a piece at a time.

    ``UploadFile`` is backed by a spooled temporary file, so this is where a
    large upload stops being the framework's problem and starts being read
    deliberately -- never with ``.read()`` and no argument, which is the line
    that would put a phone's video in the gateway's memory.
    """

    while True:
        chunk = file.file.read(CHUNK_BYTES)
        if not chunk:
            return
        yield chunk


__all__ = ["router"]
