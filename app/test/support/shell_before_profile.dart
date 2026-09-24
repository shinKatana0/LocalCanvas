/// What the connected shell drew **before** the portable profile existed.
///
/// This is a photograph of the pre-change code path, not a description of the
/// current one. It was captured by pumping the shell at the state
/// [shellFingerprint] documents, on the tree as it stood at commit `55846b3`
/// — before a single line of `lib/` was touched by T-0052 — and it is
/// committed on its own, ahead of the change, so that the claim "a build with
/// no profile actions renders as it did" is checked against what the old code
/// actually produced rather than against what the new code happens to do.
///
/// A test that pinned the *new* tree to itself would pass however much the
/// interface had moved, which is the failure this file exists to prevent.
///
/// **When a later card deliberately changes the shell**, the photograph is
/// edited line by line and the edit is annotated where it sits — never
/// re-taken from the current tree, which would throw away everything it is
/// for. Two cards have done so: T-0144, four lines, and T-0154, three lines,
/// both marked below.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everything of the shell that a person could point at: the keys the app
/// gives its own widgets, the words on screen in the order they are drawn,
/// whether each button is pressable, and the position of every switch.
///
/// Deliberately not every widget in the tree. A count of `Padding`s would
/// change with a Flutter upgrade and say nothing about this app; a missing
/// sentence, a button that has gone grey and a switch that has moved are
/// exactly what "renders as before" is a claim about.
List<String> shellFingerprint(WidgetTester tester) => <String>[
  for (final widget in tester.allWidgets) ...<String>[
    if (widget.key case final ValueKey<String> key)
      if (key.value.startsWith('lc.')) 'key ${key.value}',
    if (widget is Text && widget.data != null) 'text ${widget.data}',
    if (widget is ButtonStyleButton) 'button ${widget.onPressed != null}',
    if (widget is Switch) 'switch ${widget.value}',
  ],
];

/// The shell with one workflow chosen, the three stores present, the server
/// disclosure open, and nothing saved for anyone — the ordinary first run.
const List<String> kShellBeforeProfile = <String>[
  'key lc.shell.compact',
  'key lc.shell.controls',
  'key lc.shell.server-details.toggle',
  'text Studio PC',
  'text Ready',
  'key lc.shell.server-details',
  'text Address',
  'text http://192.0.2.42:7801',
  'text Server version',
  'text 0.1.0',
  'text API version',
  'text 1 (this app speaks 1)',
  'text Generator',
  'text Running',
  'button true',
  'text Check again',
  'button true',
  'text Choose another server',
  'key lc.workflows.selected',
  // T-0144, and the only four lines of this photograph that have been
  // touched since it was taken. The chosen workflow's block gained the
  // inline disclosure the server block has always had, so a `toggle` key
  // appears on its header, and the "What this does" button it replaces —
  // three lines, `key lc.workflows.selected.help` / `button true` /
  // `text What this does` — is gone. Every other line below is still the
  // pre-change tree's own output, unedited.
  'key lc.workflows.selected.toggle',
  'text Example Text to Image',
  'text Prompt only',
  'text TXT2IMG',
  'key lc.workflows.change',
  'button true',
  'text Change',
  'key lc.form',
  'key lc.form.row.prompt',
  // T-0154, and the only other lines of this photograph that have been
  // touched. Each field's label line — its name, the requirement, and
  // whatever small affordance sits at the far end — was an unkeyed `Row`
  // whose children could not give, and it overflowed in Russian at a 2.0
  // text scale. It gained a key of its own so that a test can ask *that
  // line* whether anything on it ran past its edge, which is why one line
  // appears here under each `lc.form.row.*`. Nothing else moved: the words
  // below each of them are in the order the pre-change tree drew them.
  'key lc.form.row.prompt.label',
  'text Prompt',
  'text Required',
  'key lc.form.field.prompt',
  'key lc.form.use-example',
  'button true',
  'text Use example',
  'text What you want to see.',
  'key lc.form.quote-hint',
  'text Text inside "quotes" is preserved.',
  'key lc.form.row.width',
  'key lc.form.row.width.label', // T-0154, as above.
  'text Width',
  'text 768',
  'key lc.form.field.width',
  'key lc.form.row.height',
  'key lc.form.row.height.label', // T-0154, as above.
  'text Height',
  'text 768',
  'key lc.form.field.height',
  'key lc.form.advanced.toggle',
  'text Advanced',
  'text 5 settings',
  'key lc.form.defaults.save',
  'button true',
  'text Save settings as my defaults',
  'key lc.form.defaults.workflow',
  'button true',
  'text Reset settings to workflow defaults',
  'key lc.form.setups.save',
  'button true',
  'text Save prompt and settings as a setup',
  'key lc.form.generate',
  'button false',
  'text Generate',
  'key lc.form.generate.reason',
  'text Generate needs Prompt.',
  'key lc.shell.content',
  'key lc.creation.idle',
  'text Ready when you are',
  'text What you generate with Example Text to Image appears here.',
];
