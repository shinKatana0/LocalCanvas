"""What can go wrong, split the way the caller has to act on it.

Two kinds, and the split is the point (T-0053, failure isolation: one bad
workflow must never take the whole run down with it):

* a **fatal** problem -- no configuration, a malformed one, a source root that
  cannot be read -- stops the whole run, because nothing after it would mean
  anything.  It is raised.
* a **per-workflow** problem -- unparseable JSON, a file that vanished mid-run
  -- stops that one workflow and nothing else.  It is never raised: it becomes
  a state and a reason on that workflow's entry, so one bad file can never
  hide the good ones.
"""

from __future__ import annotations


class SyncError(Exception):
    """A fatal problem: the run cannot produce a meaningful answer."""


class SyncConfigError(SyncError):
    """The workflow sources configuration is missing, unreadable or invalid."""


class SyncSourceError(SyncError):
    """A configured source root does not exist or cannot be read."""


class InventoryError(SyncError):
    """The inventory could not be written, and the previous one still stands."""


__all__ = ["SyncError", "SyncConfigError", "SyncSourceError", "InventoryError"]
