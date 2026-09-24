"""Workflow definitions the API tests submit against.

Kept out of ``conftest.py`` because they are data, not fixtures: one prompt-only
workflow with a field of every non-media type, and one that needs an image.
"""

from __future__ import annotations

#: One field per validation rule the gateway enforces, bound to the graph in
#: ``conftest.DEFAULT_GRAPH``.
EVERY_FIELD = """
- id: prompt
  label: Prompt
  type: multiline
  required: true
  bind:
    node: "20"
    input: text

- id: steps
  label: Steps
  type: integer
  default: 20
  min: 1
  max: 50
  section: advanced
  bind:
    node: "30"
    input: steps

- id: guidance
  label: Guidance
  type: float
  default: 6.0
  min: 1.0
  max: 20.0
  section: advanced
  bind:
    node: "30"
    input: cfg

- id: enabled
  label: Enabled
  type: boolean
  default: true
  section: advanced
  bind:
    node: "30"
    input: enabled

- id: mode
  label: Mode
  type: select
  default: fast
  options:
    - value: fast
      label: Fast
    - value: slow
      label: Slow
  section: advanced
  bind:
    node: "30"
    input: mode
"""

#: One logical field standing for two graph inputs (T-0045).  Kept apart from
#: ``EVERY_FIELD`` so that the tests about the field schema keep their exact
#: list, and this one is only about what a multi-target field shows the app.
MULTI_TARGET_FIELD = """
- id: prompt
  label: Prompt
  type: multiline
  required: true
  bind:
    - {node: "20", input: text}
    - {node: "10", input: name}
"""

#: A workflow whose value comes from an upload, which this build cannot accept.
IMAGE_FIELD = """
- id: source_image
  label: Source image
  type: image
  required: true
  bind:
    node: "40"
    input: image
"""

PRESENTATION = """
group: Create
category: Example
badge: TXT2IMG
short_description: A test workflow.
input_summary: Prompt only
"""
