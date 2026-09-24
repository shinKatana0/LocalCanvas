"""LocalCanvas gateway: the PC-side half of LocalCanvas.

    localcanvas_gateway.config      runtime configuration (`docs/runtime.md`)
    localcanvas_gateway.workflows   the workflow registry (`docs/workflow-schema.md`)
    localcanvas_gateway.comfy       ComfyUI's HTTP protocol, and a fake of it
    localcanvas_gateway.jobs        the job store and its five states
    localcanvas_gateway.api         the HTTP surface in `docs/api.md`
    localcanvas_gateway.discovery   mDNS advertisement (`docs/connection.md`)
    localcanvas_gateway.pairing     the QR pairing payload and its terminal render

Nothing is imported here: importing the package must not pull in FastAPI, and
the offline registry validator has to keep running in an environment that has
only PyYAML.

The version reported by ``GET /api/v1/info`` as ``gateway_version``.  It is
declared here and read from here by the packaging metadata's single source.
"""

__version__ = "0.1.1"

__all__ = ["__version__"]
