"""Turning every failure into the one documented error shape.

`docs/api.md` allows exactly one body for a non-2xx response::

    {"error": {"code": "...", "message": "...", "field": null}}

Four handlers cover every way a response can fail, so there is no path by which
FastAPI's own default body -- or worse, a traceback -- reaches the app:

* :class:`~localcanvas_gateway.errors.ApiError`, raised deliberately;
* Starlette's ``HTTPException``, which is what an unmatched route or a wrong
  method produces;
* FastAPI's ``RequestValidationError``, whose default 422 body is a list of
  pydantic error dictionaries and is not this contract;
* anything else at all, which becomes a plain 500 whose message says nothing
  about the exception.  **The traceback is logged on the PC**, which is where
  it is useful and where it stays.
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from ..errors import ApiError, error_payload

log = logging.getLogger(__name__)

#: What a bare HTTP status means when nothing more specific was raised.
#: 422 is deliberately absent: FastAPI's own 422 arrives as a
#: ``RequestValidationError`` and is handled below, so an entry here would be
#: an unreachable line pretending to be a policy.
_STATUS_CODES = {
    404: ("not_found", "That is not something this server has."),
    405: ("method_not_allowed", "That request is not something this server accepts."),
}


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.to_payload())

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        code, message = _STATUS_CODES.get(
            exc.status_code, ("request_failed", "The request could not be completed.")
        )
        return JSONResponse(
            status_code=exc.status_code, content=error_payload(code, message, None)
        )

    @app.exception_handler(RequestValidationError)
    async def _validation_error(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        log.info("rejected request to %s: %s", request.url.path, exc)
        return JSONResponse(
            status_code=400,
            content=error_payload(
                "invalid_request",
                "The request could not be understood. Expected JSON.",
                None,
            ),
        )

    @app.exception_handler(Exception)
    async def _unexpected(request: Request, exc: Exception) -> JSONResponse:
        # The detail belongs in the PC's log, never in the body.
        log.exception("unhandled error serving %s", request.url.path)
        return JSONResponse(
            status_code=500,
            content=error_payload(
                "internal_error",
                "Something went wrong on the LocalCanvas server.",
                None,
            ),
        )


__all__ = ["install_error_handlers"]
