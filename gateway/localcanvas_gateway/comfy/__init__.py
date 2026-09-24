"""Everything that knows ComfyUI exists.

The gateway is the only component aware of ComfyUI (`docs/architecture.md`), and
this package is the only part of the gateway aware of its protocol -- HTTP,
and the event socket progress is reported on.  Node
ids, the API-format graph, ``/history`` lookup and output file locations stop
here: nothing in :mod:`localcanvas_gateway.api` speaks in ComfyUI's terms.

Nothing here imports from ComfyUI's Python, and nothing here touches ComfyUI's
filesystem.  The only coupling is the network (`docs/runtime.md`).
"""

from .client import (
    READY_TTL_SECONDS,
    RESULT_CHUNK_BYTES,
    RESULT_TIMEOUT,
    ComfyClient,
    ComfyError,
    ComfyHealth,
    ComfyStatus,
    ComfySubmitRejected,
    ExecutionError,
    HistoryEntry,
    OutputFile,
    QueuePlace,
    ResultStream,
    UploadedInput,
)
from .events import ComfyEvents, JobSink

__all__ = [
    "READY_TTL_SECONDS",
    "ComfyEvents",
    "JobSink",
    "RESULT_CHUNK_BYTES",
    "RESULT_TIMEOUT",
    "ComfyClient",
    "ComfyError",
    "ComfyHealth",
    "ComfyStatus",
    "ComfySubmitRejected",
    "ExecutionError",
    "HistoryEntry",
    "OutputFile",
    "QueuePlace",
    "ResultStream",
    "UploadedInput",
]
