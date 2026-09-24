"""Reading a user's own ComfyUI workflow folder, once, from a command line.

A curator tool, not part of the running gateway.  It lives in this package
because the schema knowledge it needs is here and must not be written a second
time in another language, exactly as ``workflows/cli.py`` does.

**Starting the gateway loads not one line of it.**  That is the rule, it is
about *when* rather than about *who*, and it is what makes an import from
outside this subpackage legal at all: an importer must make it **inside the
function that needs it**, never at module level.

There are exactly two such callers, and a third needs a reason:

* ``workflows/cli.py``, inside the function that handles the ``sync``
  subcommand -- the original one;
* ``api/workflows.py``, inside ``_localised``, which is reached only by a
  request that asked for a language other than English (T-0143).  It needs
  `semantics.py`'s help vocabulary to tell a generated hint from a curated one
  and to say the generated one in the language that was asked for.

The second one is a **widening of the rule's one existing exception, not a
breach of it**, and it is asserted rather than promised:
``test_asking_for_a_workflow_in_english_never_loads_the_importer`` builds the
application in a fresh interpreter and requires this package to be absent from
``sys.modules``, then runs the localising function and requires it to be
present.

That it takes a paragraph to say is itself the argument for **T-0146**, which
proposes moving the vocabulary to a runtime-side module so that the serving
path imports two tables and two functions rather than the whole curator tool.
Until then, this is the shape.

What one run does:

* **discover** the workflow files under the folders
  ``config/local/workflow-sources.yaml`` names, and never one step outside them
  (`discovery.py`);
* **hash** each one, because a workflow's identity is its content and never its
  file name (`classify.py`);
* **classify** it from that content: the API format LocalCanvas can use, the
  editor's UI format that has to be exported again, or something a person has
  to look at;
* **convert** an editor-format workflow into an executable one -- by asking the
  user's own ComfyUI to do it, in its own frontend, in a browser that can
  resolve nothing but loopback (`bridge.py`, `snapshots.py`,
  `docs/privacy-security.md`).  LocalCanvas does not convert one into the
  other itself and never will: that needs the node definitions of the exact
  build that saved it, and a wrong guess runs and produces the wrong result;
* **compare** it with the inventory of the last run, and record what changed
  (`engine.py`, `inventory.py`);
* **read** an importable graph for the logical inputs a person would set --
  which of them are one control, which are structural and must never be shown,
  and which cannot be decided at all (`semantics.py`, `analysis.py`);
* **describe** it for a person -- a readable name, what goes in, what comes
  out, what it is good for and an example prompt, each key paired with the
  evidence rule that produced it and omitted where no rule fired
  (`catalog.py`);
* **write** a `docs/workflow-schema.md` definition for each of them, but only
  after the gateway's own registry loader has accepted it, carrying over
  everything a curator has already written in the definition on disk
  (`definitions.py`).

What it deliberately does not do: modify, rename, move or normalise a single
source file; write anything inside a source folder; infer an API graph from a
canvas by itself; reach anything over a network except the one ComfyUI it was
given; or guess.  Where the evidence in a graph does not settle what an input
is, the workflow needs review and no definition is written -- an invented field
id is a key somebody's saved settings hang off, and getting it wrong fails
silently in both directions.
"""

from .analysis import (
    COMPUTATION_KIND,
    CONTROL_SECTIONS,
    DECLARED_DEFAULT_KIND,
    HIDDEN_SECTIONS,
    LOADING_CLASS_WORDS,
    LOAD_SETTING_KIND,
    LOCKED_KINDS,
    MODEL_ARCHITECTURE_KIND,
    MODEL_PATCH_KIND,
    NODE_SHAPE_KIND,
    SELECT_FIELD_TYPE,
    TECHNICAL_MEDIA_KIND,
    ControlRecord,
    ImportPlan,
    InputCandidate,
    NotExposed,
    PlannedField,
    analyse,
    class_words,
)
from .bridge import (
    LOOPBACK_ONLY_RESOLVER_RULE,
    ComfyIdentity,
    Conversion,
    ConversionBridge,
    ConversionStatus,
    browser_command,
    find_browser,
)
from .catalog import (
    PRESENTATION_ORDER,
    Catalog,
    CatalogEntry,
    describe,
    readable_name,
)
from .classify import (
    ATTENTION_STATES,
    EXPORT_INSTRUCTION,
    Classification,
    WorkflowFormat,
    WorkflowState,
    classify,
    content_hash,
)
from .config import (
    CONFIG_RELATIVE_PATH,
    EXAMPLE_RELATIVE_PATH,
    OutputPaths,
    SourceRoot,
    SourcesConfig,
    SyncOptions,
    load_sources_config,
)
from .contract import (
    ContractCache,
    RuntimeContract,
    declared_options,
    declared_structural_keys,
    names_files,
    read_object_info,
)
from .definitions import (
    GENERATED_HEADER,
    CuratedDefinition,
    DefinitionPlan,
    DefinitionWrite,
    build_definition,
    definition_document,
    generated_help,
    generated_labels,
    generated_presentation,
    graph_file_name,
    read_curated,
    render_definition,
    validate_definition,
    write_definition,
)
from .discovery import Candidate, RootScan, SkippedEntry, is_contained, scan_root
from .engine import (
    CONVERSION_NOT_OFFERED,
    DRY_RUN_CONVERSION_NOTICE,
    DRY_RUN_DEFINITION_NOTICE,
    DRY_RUN_NOTICE,
    DRY_RUN_NOTICE_ASCII,
    KEPT_NOTICE,
    SyncReport,
    SyncedWorkflow,
    run_sync,
)
from .errors import InventoryError, SyncConfigError, SyncError, SyncSourceError
from .inventory import Inventory, InventoryEntry, read_inventory, write_inventory
from .report import render, report_document, summary_line
from .snapshots import (
    Snapshot,
    cache_directory,
    read_snapshot,
    snapshot_document,
    snapshot_path,
    write_snapshot,
)

__all__ = [
    "ATTENTION_STATES",
    "COMPUTATION_KIND",
    "CONFIG_RELATIVE_PATH",
    "CONTROL_SECTIONS",
    "CONVERSION_NOT_OFFERED",
    "DECLARED_DEFAULT_KIND",
    "Candidate",
    "Catalog",
    "CatalogEntry",
    "Classification",
    "ComfyIdentity",
    "ContractCache",
    "ControlRecord",
    "Conversion",
    "ConversionBridge",
    "ConversionStatus",
    "CuratedDefinition",
    "DRY_RUN_CONVERSION_NOTICE",
    "DRY_RUN_DEFINITION_NOTICE",
    "DRY_RUN_NOTICE",
    "DRY_RUN_NOTICE_ASCII",
    "DefinitionPlan",
    "DefinitionWrite",
    "EXAMPLE_RELATIVE_PATH",
    "EXPORT_INSTRUCTION",
    "GENERATED_HEADER",
    "HIDDEN_SECTIONS",
    "ImportPlan",
    "InputCandidate",
    "Inventory",
    "KEPT_NOTICE",
    "LOADING_CLASS_WORDS",
    "LOAD_SETTING_KIND",
    "LOCKED_KINDS",
    "LOOPBACK_ONLY_RESOLVER_RULE",
    "MODEL_ARCHITECTURE_KIND",
    "MODEL_PATCH_KIND",
    "NODE_SHAPE_KIND",
    "NotExposed",
    "PlannedField",
    "InventoryEntry",
    "InventoryError",
    "OutputPaths",
    "PRESENTATION_ORDER",
    "RootScan",
    "RuntimeContract",
    "SELECT_FIELD_TYPE",
    "Snapshot",
    "SkippedEntry",
    "SourceRoot",
    "SourcesConfig",
    "SyncConfigError",
    "SyncError",
    "SyncOptions",
    "SyncReport",
    "SyncSourceError",
    "SyncedWorkflow",
    "TECHNICAL_MEDIA_KIND",
    "WorkflowFormat",
    "WorkflowState",
    "analyse",
    "browser_command",
    "build_definition",
    "class_words",
    "classify",
    "content_hash",
    "declared_options",
    "declared_structural_keys",
    "cache_directory",
    "definition_document",
    "describe",
    "find_browser",
    "generated_help",
    "generated_labels",
    "generated_presentation",
    "graph_file_name",
    "is_contained",
    "load_sources_config",
    "names_files",
    "read_curated",
    "read_inventory",
    "read_object_info",
    "read_snapshot",
    "readable_name",
    "render",
    "render_definition",
    "report_document",
    "run_sync",
    "scan_root",
    "snapshot_document",
    "snapshot_path",
    "summary_line",
    "validate_definition",
    "write_definition",
    "write_inventory",
    "write_snapshot",
]
