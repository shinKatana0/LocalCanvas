"""Test double for the curator commands package.

Only ``__main__`` exists here, and that is deliberate: the seam
``scripts/sync-workflows.ps1`` uses is a process boundary --

    <python> -m localcanvas_gateway.workflows sync --config <path> [--dry-run]

-- and the script must never reach across it any other way. There is nothing
importable to reach for.
"""

__all__ = []
