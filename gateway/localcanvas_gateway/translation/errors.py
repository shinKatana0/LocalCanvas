"""What the app is told when translation was asked for and could not happen.

The rule these three exist to enforce (T-0040): **untranslated text is never
passed off as translated.**  If a submission asked for translation and the
gateway could not do it, that is an error with a code the app can branch on --
not a shrug, and never a quiet fall back to sending the original text into a
generation the user believes was translated.

The second rule is the one that has no code at all: **there is no cloud
fallback.**  No error here is recoverable by reaching a network service,
because LocalCanvas has none to reach and must never acquire one
(`docs/privacy-security.md`).  Every message therefore names something the
person at the PC can install, which is the only thing that fixes it.

The messages are written for the phone (`docs/api.md`) and still carry the
command, because the person reading it is usually the person who owns the PC,
and a message that says only "translation is unavailable" makes them go and
look for a log.
"""

from __future__ import annotations

from typing import Optional

from ..errors import ApiError

#: How the optional extra is installed, written the way `docs/runtime.md` says
#: interpreters are named in this project: explicitly, never a bare ``python``.
INSTALL_COMMAND = '.venv\\Scripts\\python.exe -m pip install "./gateway[translation]"'


def model_command(source: str, target: str) -> str:
    """The explicit setup step that installs one language pair.

    ``argospm`` ships with the translation extra.  Naming it is what keeps
    model downloads an explicit setup step and never something a generation
    request triggers.
    """

    return "argospm update && argospm install translate-{}_{}".format(source, target)


class TranslationUnavailable(ApiError):
    """The translation backend is not installed, or is not a local one."""

    def __init__(self, message: str, field: Optional[str] = None) -> None:
        super().__init__(
            status_code=500,
            code="translation_unavailable",
            message=message,
            field=field,
        )


class TranslationModelMissing(ApiError):
    """The backend is installed, but the language pair is not."""

    def __init__(self, source: str, target: str, field: Optional[str] = None) -> None:
        super().__init__(
            status_code=500,
            code="translation_model_missing",
            message=(
                "The {}-to-{} translation model is not installed on the PC. "
                "Install it there with: {}".format(source, target, model_command(source, target))
            ),
            field=field,
        )
        self.source = source
        self.target = target


class TranslationFailed(ApiError):
    """The backend was there and raised.  The detail is logged on the PC."""

    def __init__(self, message: str, field: Optional[str] = None) -> None:
        super().__init__(
            status_code=500,
            code="translation_failed",
            message=message,
            field=field,
        )


def backend_missing() -> TranslationUnavailable:
    """Prompt translation is switched on and the extra was never installed."""

    return TranslationUnavailable(
        "Prompt translation is switched on, but it is not installed on the PC. "
        "Install it there with: {}".format(INSTALL_COMMAND)
    )


__all__ = [
    "INSTALL_COMMAND",
    "TranslationFailed",
    "TranslationModelMissing",
    "TranslationUnavailable",
    "backend_missing",
    "model_command",
]
