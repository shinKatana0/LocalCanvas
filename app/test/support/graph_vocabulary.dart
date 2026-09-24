/// The one scan for a graph's vocabulary in app code (T-0264).
///
/// The app has never received a workflow graph (`docs/workflow-schema.md`),
/// so code that names a node, a node's `class_type` or the graph itself is
/// code reaching for something that does not exist. Four test files guard
/// their stores with this scan; it lives here once, and each of them imports
/// it, so a shape freed or refused is freed or refused for all four at once.
///
/// [expectGraphScanHoldsItsShapes] is the scan's self-test. Every file that
/// imports the scan runs it against the `graphReadsIn` in its own scope, so a
/// file that shadowed this one with a private copy would be caught in that
/// file.
library;

import 'package:flutter_test/flutter_test.dart';

/// The source with its comments removed, so prose *about* a graph is not
/// mistaken for code that reaches into one.
String withoutComments(String source) => source
    .split('\n')
    .map((line) {
      final slashes = line.indexOf('//');
      return slashes < 0 ? line : line.substring(0, slashes);
    })
    .join('\n');

/// The only names containing `node` that the scan lets through (T-0189), each
/// for its own reason. A closed list: a name is freed by being written here,
/// never by resembling one of these.
const Map<String, String> frameworkNodeNames = <String, String>{
  // The object a widget takes keyboard focus through.
  'FocusNode': 'Flutter keyboard focus',
  // The accessibility tree's own entry, which a semantics test reads.
  'SemanticsNode': 'Flutter accessibility',
  // A tree view's entry, which T-0189's card names as being in the same trap.
  'TreeNode': 'a tree view entry',
  // The named argument a text field or a `Focus` takes a `FocusNode` by.
  'focusNode': 'the argument FocusNode is passed as',
};

/// `graph` where it is a word of its own: in any case where no letter comes
/// before it (`graph`, `'graph'`, `graphId`, `graph_id`, `_graph`,
/// `step2graph`), and with a
/// capital G wherever it stands, which is where a camelCase or SHOUTING name
/// starts a new word (`promptGraph`, `GraphRead`, `PROMPT_GRAPH`).
///
/// What it leaves is a lowercase `graph` directly after a letter — the tail of
/// a longer English word: `paragraph`, `RenderParagraph`, `telegraph`,
/// `photograph`, `Typography`. That rule is about position, so it would free
/// every such word alike — which is why [graphConceptWords] exists.
final RegExp _graphAsItsOwnWord = RegExp(
  '(?:(?<![A-Za-z])[Gg]|G)[Rr][Aa][Pp][Hh]',
);

/// The graph words the position rule above would let through, and which are
/// graph reads all the same, each for its own reason. A closed list: a word
/// is refused here by being written here (T-0264).
const Map<String, String> graphConceptWords = <String, String>{
  // ComfyUI nests one graph inside a workflow's graph and calls it this.
  'subgraph': 'a ComfyUI graph nested inside a workflow graph',
  // The key a workflow's JSON holds those nested graphs under.
  'subgraphs': 'the ComfyUI key the nested graphs are listed under',
};

/// Each word in [graphConceptWords] as a word of its own, by the same rule as
/// `graph` itself: in any case where no letter comes before it, and with a
/// capital first letter wherever it stands, which is where a camelCase name
/// starts a new word — and with no lowercase letter after it. So
/// `'subgraph'`, `Subgraph`, `subgraphId`, `subgraph_id`, `promptSubgraph`
/// and `innerSubgraphId` are all refused, and `subgraphs` is refused by its
/// own entry rather than by resembling `subgraph`.
final RegExp _graphConceptWord = RegExp(
  '(?:${[
    for (final word in graphConceptWords.keys)
      '(?:(?<![A-Za-z])${_anyCase(word[0])}|${word[0].toUpperCase()})'
          '${_anyCase(word.substring(1))}',
  ].join('|')})(?![a-z])',
);

/// [letters] as a pattern matching them in any case: `sub` is `[Ss][Uu][Bb]`.
String _anyCase(String letters) => <String>[
  for (final c in letters.split('')) '[${c.toUpperCase()}$c]',
].join();

/// A node's type, as ComfyUI spells it and as Dart would: `class_type` and
/// `classType`, in any case.
final RegExp _classType = RegExp('class_?type', caseSensitive: false);

/// Anything that would only be there to reach into a graph, by the word it
/// reads: `node`, `class_type`, `graph`, in that order.
///
/// * `node` is refused in any case and inside any longer name — `node_id`,
///   `nodes`, `nodeId`, `_node`, `targetNodeId`, `inputNodes`, `comfyNode`,
///   and a parameter named `node` — with exactly one exception (T-0189): the
///   four names in [frameworkNodeNames], and only as whole identifiers written
///   as they are here. They are removed from the code before it is scanned, so
///   `FocusNode` and `focusNode:` pass, while `_focusNode`, `FocusNodes`,
///   `focusNodeId` and `treenode` are not those names and are still refused.
/// * `class_type` is refused in any case, with or without its underscore, so
///   `classType` is the same read.
/// * `graph` is refused as a word of its own, never as the tail of a longer
///   word — see [_graphAsItsOwnWord] — except the words in
///   [graphConceptWords], which are refused by name.
List<String> graphReadsIn(String source) {
  final freed = RegExp('\\b(${frameworkNodeNames.keys.join('|')})\\b');
  final scanned = withoutComments(source).replaceAll(freed, ' ');
  return <String>[
    if (RegExp('node', caseSensitive: false).hasMatch(scanned)) 'node',
    if (_classType.hasMatch(scanned)) 'class_type',
    if (_graphAsItsOwnWord.hasMatch(scanned) ||
        _graphConceptWord.hasMatch(scanned))
      'graph',
  ];
}

/// A guarded file that takes keyboard focus the ordinary way (T-0189): the
/// four letters of `node` are in it several times over, and none is a read.
const String frameworkNodeSource = '''
class _PaneState extends State<Pane> {
  final FocusNode _x = FocusNode();
  SemanticsNode? semantics;
  TreeNode? tree;
  @override
  Widget build(BuildContext context) => TextField(focusNode: _x);
}
''';

/// A guarded file that lays out text: the five letters of `graph` are in it
/// several times over, and none is a read.
const String paragraphSource = '''
final RenderParagraph paragraph = RenderParagraph(span);
const telegraph = 'a telegraph line', photograph = 'photograph';
final TextStyle body = Theme.of(context).typography.englishLike.bodyMedium!;
''';

/// Sources the scan must pass, each with the letters it must look past.
const Map<String, String> notGraphReads = <String, String>{
  frameworkNodeSource: 'node',
  'final FocusNode _x;': 'node',
  paragraphSource: 'graph',
  "final p = 'paragraph';": 'graph',
  "final t = 'telegraph';": 'graph',
  'class _Lines extends RenderParagraph {}': 'graph',
  'final Typography type = Typography.material2021();': 'graph',
};

/// Read shapes the scan must refuse, each with the one word it reads.
const Map<String, String> graphReads = <String, String>{
  // A node, in each shape one takes — a node inside a longer name included,
  // since only the names written in [frameworkNodeNames] are freed, and only
  // whole.
  "final id = field['node_id'];": 'node',
  "final inputs = prompt['node'];": 'node',
  "final all = workflow['nodes'];": 'node',
  'final nodeId = field.id;': 'node',
  'for (final node in prompt.values) {}': 'node',
  'onKeyEvent: (FocusNode node, KeyEvent e) => handled': 'node',
  'final id = field.targetNodeId;': 'node',
  "final inputs = workflow['inputNodes'];": 'node',
  "final t = field['comfyNode'];": 'node',
  'final _node = prompt[id];': 'node',
  "final ids = field['focusNodeIds'];": 'node',
  // Freed whole and as written: a private name ending in one of them is not
  // that name, and neither is one spelled in another case.
  'final _focusNode = FocusNode();': 'node',
  "final t = field['treenode'];": 'node',
  // A node's type, as the graph spells it and as Dart would.
  "final type = entry['class_type'];": 'class_type',
  'final type = entry.classType;': 'class_type',
  "final type = entry['ClassType'];": 'class_type',
  // The graph itself, as a word of its own however it is written.
  "final g = workflow['graph'];": 'graph',
  'final graph = workflow.prompt;': 'graph',
  'final id = entry.graphId;': 'graph',
  "final id = entry['graph_id'];": 'graph',
  'final _graph = workflow.prompt;': 'graph',
  'final g = workflow.promptGraph;': 'graph',
  'final Graph g = read(workflow);': 'graph',
  'const PROMPT_GRAPH = 0;': 'graph',
  // Only a letter makes it a tail: a digit or an underscore does not.
  'final g = workflow.step2graph;': 'graph',
  // The graph words the position rule would free, refused by name.
  "final inner = workflow['subgraph'];": 'graph',
  "final all = definitions['subgraphs'];": 'graph',
  'final Subgraph inner = read(workflow);': 'graph',
  'final id = entry.subgraphId;': 'graph',
  // A capital first letter starts a word wherever it stands, as G does.
  'final s = workflow.promptSubgraph;': 'graph',
  'final s = definitions.nestedSubgraphs;': 'graph',
  'final id = entry.innerSubgraphId;': 'graph',
};

/// The scan's self-test, run against [scan] — the `graphReadsIn` in the
/// calling file's scope, so what is proved is the scan that file really uses.
void expectGraphScanHoldsItsShapes(List<String> Function(String) scan) {
  notGraphReads.forEach((source, letters) {
    // The letters really are in it, so the clean answer is the scan telling
    // a word apart, and not a scan that never saw the letters.
    expect(
      RegExp(letters, caseSensitive: false).hasMatch(source),
      isTrue,
      reason: source,
    );
    expect(scan(source), isEmpty, reason: source);
  });
  graphReads.forEach((source, word) {
    expect(scan(source), <String>[word], reason: source);
  });
}
