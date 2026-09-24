# Example workflows

Three complete, valid LocalCanvas workflow definitions, one for each shape the
app supports:

| Files | Shape | Shows |
|---|---|---|
| `example_txt2img.yaml` + `example_txt2img_api.json` | prompt only | text, numbers, a select, presentation hints |
| `example_img2img.yaml` + `example_img2img_api.json` | image input | the `image` field type |
| `example_video.yaml` + `example_video_api.json` | video input | the `video` field type, a boolean |

Everything in them is placeholder content. No model name, no real checkpoint
file, no path from anybody's machine. They are here to be read and copied, not
run: point the JSON at your own export before expecting a picture.

Check them at any time — this needs no ComfyUI and no network:

```powershell
# From the repository root.
.\.venv\Scripts\python.exe -m localcanvas_gateway.workflows workflows\examples
```

## Adding your own workflow

A workflow is **two files, and no source change ever**:

1. **The graph.** In ComfyUI, export your workflow in **API format** (Save (API
   Format) / "Export (API)"). The file looks like this — a flat object whose
   keys are node ids:

   ```json
   {
     "20": { "class_type": "CLIPTextEncode",
             "inputs": { "text": "a placeholder prompt", "clip": ["10", 1] } }
   }
   ```

   The *UI* export, the one with `nodes` and `links` arrays, is a different
   file and is rejected with a message saying so.

2. **The definition.** A YAML file next to it that names the workflow, says how
   to present it, and maps each user-facing field onto one node input:

   ```yaml
   id: my_workflow                 # unique, lowercase letters, digits, _ and -
   name: My Workflow               # what the app shows
   workflow: my_workflow_api.json  # relative to this YAML file

   inputs:
     - id: prompt
       label: Prompt
       type: multiline
       required: true
       bind:
         node: "20"                # the node id from the JSON
         input: text               # the key inside that node's "inputs"
   ```

Put both files in your registry folder (`workflows.registry` in
`config/local/runtime.yaml`) and restart the gateway. That folder is scanned
recursively, so subfolders are fine.

### Choosing what to expose

LocalCanvas never guesses which inputs matter — that is the point. Expose the
few things you actually change, give them names a person understands, and leave
the rest of the graph alone. A field you do not declare keeps whatever value
your export already has.

### The field types

| `type` | Value | Extra keys |
|---|---|---|
| `string` | one line of text | — |
| `multiline` | several lines of text | — |
| `integer` | whole number | `min`, `max`, `step`, `role: seed`, `pair: width\|height` |
| `float` | number | `min`, `max`, `step` |
| `boolean` | on / off | — |
| `select` | one of `options` | `options:` list of `{value, label}` |
| `image` | a picture the user picks | — |
| `video` | a clip the user picks | — |

Every field also takes `label` (required), `required` (default `false`),
`section` (`main` or `advanced`, default `main`), `help`, and `default` —
except `image` and `video`, which take no `default`: their value is an upload,
not a path.

`role: seed` and `pair: width|height` are hints for the form. A renderer that
ignores them still produces a correct form.

### Binding

```yaml
bind:
  node: "40"     # node id, as it appears in the API JSON
  input: steps   # the key inside that node's "inputs"
```

Node ids are strings in the API format. Writing `node: 40` works too — both name
the same node — but quoting them is the clearer habit.

At generation time the gateway deep-copies your JSON and writes each value at
`node -> inputs -> input`. Your file on disk is never touched.

An input that is *wired to another node* looks like `["10", 1]` in the JSON.
That is a connection, not a value, and binding a field to it is rejected: the
graph would break.

### Two rules that will catch you out

**A key LocalCanvas does not recognise is an error, not a comment.** Write
`defualt: 20` and the definition is rejected, with a message naming the key and
listing the ones that are allowed. A typo that was quietly ignored would show up
much later as a field that does nothing, so it is refused up front. The same
goes for the same key written twice in one block: YAML would keep only the
second, and one of your two lines would silently do nothing.

**Two fields may not bind to the same node input.** Only one of them could win,
and which one would be an accident of ordering. Give each field its own input.

### When something is wrong

A bad definition is skipped with a message naming the file, the workflow, the
field and the problem — the rest of your workflows still load. Run the
validation command above and fix what it prints.

### The presentation block

Optional, but it is what a picker and the in-app help show. Fill in enough that
you still understand the workflow months later without opening ComfyUI:

```yaml
presentation:
  group: Create              # picker grouping, free-form
  category: Photoreal        # secondary descriptor
  badge: TXT2IMG             # short type marker
  short_description: >
    One sentence on what this is for.
  best_for: [ Portraits, Cinematic scenes ]
  how_to_use: >
    What to type, and which knob to reach for first.
  input_summary: Prompt only
  example_prompt: >
    A rainy alley at night, cinematic lighting
  not_ideal_for: [ Anime character consistency ]
```

`group`, `category` and `badge` are free text. Nothing in LocalCanvas branches
on their values, so an unfamiliar group simply renders as its own section.

The full contract is [`docs/workflow-schema.md`](../../docs/workflow-schema.md).
