"""Exceptions raised by the workflow registry.

Two failure classes exist, and they behave differently on purpose
(``docs/workflow-schema.md``):

* **registry-fatal** -- the configured registry root is missing, is not a
  directory, or cannot be read.  Nothing about the registry can be trusted, so
  loading raises :class:`RegistryError` instead of returning a half-empty
  registry that looks successful.
* **workflow-isolated** -- one definition is malformed or fails validation.
  That workflow is omitted, every valid workflow still loads, and the reason is
  reported as a :class:`~localcanvas_gateway.workflows.diagnostics.Diagnostic`.
  No exception is raised.
"""


class WorkflowRegistryError(Exception):
    """Base class for every error this package raises."""


class RegistryError(WorkflowRegistryError):
    """Registry-fatal: the registry root itself cannot be used."""


class BindingError(WorkflowRegistryError):
    """A value map cannot be bound into a workflow graph."""


__all__ = ["WorkflowRegistryError", "RegistryError", "BindingError"]
