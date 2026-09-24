/// A workflow whose fields changed on the PC reaches the form (T-0236).
///
/// A list arriving through `refresh()` or `reload()` marks every cached schema
/// stale. The chosen workflow's is asked for again at once, any other's the next
/// time it is chosen, and the answer is laid beside the cached one:
///
/// * the same schema keeps the form — the very object;
/// * a changed one gets a new form, with what still fits carried over and what
///   does not dropped, and the old form is disposed;
/// * a failure keeps the old form and says nothing.
///
/// The fake decodes a **fresh** `WorkflowDetail` from its JSON body on every
/// request, so "the same schema" is never the same object: a form kept after a
/// re-read was kept because the two compared equal by value, not because the
/// fake handed back what it had handed back before. Its detail request can be
/// held open, and what a held request answers is decided when it is made — the
/// order a real transport has, where the PC answers with the schema it had
/// when it was asked.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/connection/connection_controller.dart';
import 'package:localcanvas/connection/endpoint.dart';
import 'package:localcanvas/connection/gateway_client.dart';
import 'package:localcanvas/media/media_field_controller.dart';
import 'package:localcanvas/media/media_selection.dart';
import 'package:localcanvas/theme/theme.dart';
import 'package:localcanvas/ui/keys.dart';
import 'package:localcanvas/ui/shell/connected_shell.dart';
import 'package:localcanvas/workflows/workflow_api.dart';
import 'package:localcanvas/workflows/workflow_draft_store.dart';
import 'package:localcanvas/workflows/workflow_form.dart';
import 'package:localcanvas/workflows/workflow_models.dart';
import 'package:localcanvas/workflows/workflow_settings_store.dart';
import 'package:localcanvas/workflows/workflow_setup_store.dart';
import 'package:localcanvas/workflows/workflows_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/fakes.dart';
import 'support/generation_fakes.dart';
import 'support/l10n.dart';
import 'support/media_fakes.dart';
import 'support/workflow_payloads.dart';

const String txt2img = 'example_txt2img';
const String img2img = 'example_img2img';

/// What the user typed, and what must survive a changed schema.
const String typed = 'a harbour at dawn, the lamps still lit';

/// txt2img as the curator changed it on the PC, one change per case:
///
/// * `strength` — **added**, a float defaulting to 0.75;
/// * `guidance` — **removed**;
/// * `steps` — **retyped** from an integer to a select of `fast`/`slow`;
/// * `negative_prompt` — **retyped** from prose to a boolean;
/// * `width` — its range **narrowed** to at most 1024;
/// * `sampler` — the `dpmpp_2m` option **removed**.
///
/// `prompt`, `height` and `seed` are untouched.
Map<String, Object?> changedTxt2img() {
  final body = txt2imgDetail();
  final inputs = <Object?>[];
  for (final raw in body['inputs']! as List<Object?>) {
    final field = Map<String, Object?>.from(raw! as Map<String, Object?>);
    switch (field['id']) {
      case 'guidance':
        continue;
      case 'steps':
        field
          ..['type'] = 'select'
          ..['default'] = 'fast'
          ..remove('min')
          ..remove('max')
          ..['options'] = <Object?>[
            <String, Object?>{'value': 'fast', 'label': 'Fast'},
            <String, Object?>{'value': 'slow', 'label': 'Slow'},
          ];
      case 'negative_prompt':
        field
          ..['type'] = 'boolean'
          ..['default'] = false;
      case 'width':
        field['max'] = 1024;
      case 'sampler':
        field['options'] = <Object?>[
          for (final option in field['options']! as List<Object?>)
            if ((option! as Map<String, Object?>)['value'] != 'dpmpp_2m')
              option,
        ];
    }
    inputs.add(field);
  }
  inputs.insert(1, <String, Object?>{
    'id': 'strength',
    'label': 'Strength',
    'type': 'float',
    'required': false,
    'section': 'main',
    'default': 0.75,
    'min': 0.0,
    'max': 1.0,
    'step': 0.05,
  });
  return <String, Object?>{...body, 'inputs': inputs};
}

/// A PC whose schemas the test edits between requests.
class EditablePc implements WorkflowsApi {
  final Map<String, Map<String, Object?>> bodies = <String, Map<String, Object?>>{
    txt2img: txt2imgDetail(),
    img2img: img2imgDetail(),
  };

  final List<String> detailCalls = <String>[];
  int listCalls = 0;

  /// The next detail request fails with this, while it is set.
  WorkflowsFailure? detailFailure;

  /// Holds the next detail request until completed; taken by that request.
  Completer<void>? detailHold;

  @override
  Future<List<WorkflowSummary>> list(Endpoint endpoint) async {
    listCalls++;
    return WorkflowSummary.listFromJson(registryOf(bodies.values.toList()));
  }

  @override
  Future<WorkflowDetail> detail(Endpoint endpoint, String workflowId) async {
    detailCalls.add(workflowId);
    // Decided when asked: a held request answers with what the PC had then.
    final body = bodies[workflowId];
    final failure = detailFailure;
    final gate = detailHold;
    detailHold = null;
    if (gate != null) await gate.future;
    if (failure != null) throw failure;
    if (body == null) {
      throw const WorkflowsFailure.refused(code: 'workflow_not_found');
    }
    // A new object every time, decoded from the wire body.
    return WorkflowDetail.tryFromJson(body)!;
  }
}

/// The autosave's clock, moved by hand.
class HandClock {
  _HandTimer? _pending;

  Timer schedule(Duration delay, void Function() onFire) =>
      _pending = _HandTimer(onFire);

  bool get isWaiting => _pending?.isActive ?? false;

  void elapse() {
    final timer = _pending;
    if (timer == null || !timer.isActive) fail('nothing was waiting');
    _pending = null;
    timer.fire();
  }
}

class _HandTimer implements Timer {
  _HandTimer(this._onFire);

  final void Function() _onFire;
  bool _active = true;

  void fire() {
    _active = false;
    _onFire();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// The real settings store, whose next `load` can be held open.
class HeldSettingsStore extends PreferencesWorkflowSettingsStore {
  Completer<void>? loadHold;
  int loads = 0;

  @override
  Future<Map<String, Object?>> load(String workflowId) async {
    loads++;
    final gate = loadHold;
    loadHold = null;
    if (gate != null) await gate.future;
    return super.load(workflowId);
  }
}

/// A refresh, and then what it started behind itself — the chosen workflow's
/// schema re-read, which [WorkflowsController.refresh] does not wait for —
/// let run out.
Future<WorkflowsFailure?> refreshed(WorkflowsController controller) async {
  final failure = await controller.refresh();
  await pumpEventQueue();
  return failure;
}

/// txt2img changed a second time, differently from [changedTxt2img]: a
/// `clarity` field added to the original, and no `strength`.
Map<String, Object?> changedAgainTxt2img() {
  final body = txt2imgDetail();
  return <String, Object?>{
    ...body,
    'inputs': <Object?>[
      ...body['inputs']! as List<Object?>,
      <String, Object?>{
        'id': 'clarity',
        'label': 'Clarity',
        'type': 'boolean',
        'required': false,
        'section': 'main',
        'default': true,
      },
    ],
  };
}

List<String> fieldIds(WorkflowsController controller) =>
    controller.selectedDetail!.inputs.map((f) => f.id).toList();

/// Records every key a parser reads out of a JSON body, by path —
/// `inputs[].options[].label` — without knowing anything about the parser.
class KeyReads {
  final Set<String> paths = <String>{};

  Object? wrap(Object? value, String path) {
    if (value is Map) {
      return _ReadRecordingMap(this, value.cast<String, Object?>(), path);
    }
    if (value is List) {
      return <Object?>[for (final item in value) wrap(item, '$path[]')];
    }
    return value;
  }
}

class _ReadRecordingMap extends MapBase<String, Object?> {
  _ReadRecordingMap(this._reads, this._inner, this._path);

  final KeyReads _reads;
  final Map<String, Object?> _inner;
  final String _path;

  String _at(Object? key) => _path.isEmpty ? '$key' : '$_path.$key';

  @override
  Object? operator [](Object? key) {
    _reads.paths.add(_at(key));
    return _reads.wrap(_inner[key], _at(key));
  }

  @override
  bool containsKey(Object? key) {
    _reads.paths.add(_at(key));
    return _inner.containsKey(key);
  }

  @override
  void operator []=(String key, Object? value) => throw UnsupportedError('');

  @override
  void clear() => throw UnsupportedError('');

  @override
  Iterable<String> get keys => _inner.keys;

  @override
  Object? remove(Object? key) => throw UnsupportedError('');
}

bool isDisposed(ChangeNotifier notifier) {
  try {
    ChangeNotifier.debugAssertNotDisposed(notifier);
    return false;
  } on FlutterError {
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final studio = Endpoint.tryParse('192.0.2.42')!;
  final elsewhere = Endpoint.tryParse('192.0.2.77')!;

  late EditablePc pc;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    pc = EditablePc();
  });

  WorkflowsController controllerFor({
    WorkflowSettingsStore? settings,
    WorkflowDraftStore? drafts,
    WorkflowSetupStore? setups,
    HandClock? clock,
  }) {
    final controller = WorkflowsController(
      api: pc,
      settings: settings,
      drafts: drafts,
      setups: setups,
      draftTimerFactory: clock == null ? Timer.new : clock.schedule,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  /// Opens txt2img and fills in one value for every case [changedTxt2img]
  /// has, plus two that stay valid.
  Future<WorkflowFormController> openAndFill(
    WorkflowsController controller,
  ) async {
    await controller.load(studio);
    await controller.select(txt2img);
    final form = controller.form!;
    form
      ..setEntry('prompt', typed)
      ..setEntry('negative_prompt', 'blurry')
      ..setEntry('guidance', '9.5')
      ..setEntry('steps', '30')
      ..setEntry('width', '1536')
      ..setEntry('height', '1024')
      ..setEntry('sampler', 'dpmpp_2m')
      ..setEntry('seed', '12345');
    expect(form.validate().isReady, isTrue, reason: 'valid before the change');
    return form;
  }

  /// Every value the user left, and nothing else, as the old schema reads it.
  void expectUntouched(WorkflowFormController form) {
    expect(form.text('prompt'), typed);
    expect(form.entry('guidance'), '9.5');
    expect(form.entry('steps'), '30');
    expect(form.entry('width'), '1536');
    expect(form.entry('sampler'), 'dpmpp_2m');
    expect(form.entry('seed'), '12345');
  }

  /// What the new form must hold after [changedTxt2img] arrived.
  void expectCarriedOver(WorkflowFormController form) {
    expect(form.detail.inputs.map((f) => f.id), contains('strength'));
    // Added: at its default.
    expect(form.entry('strength'), '0.75');
    // Removed: gone from the form and from what it would send or keep.
    expect(form.entry('guidance'), isNull);
    expect(form.draftableValues().containsKey('guidance'), isFalse);
    expect(form.validate().inputs.containsKey('guidance'), isFalse);
    // Retyped: nothing of the old kind is kept, the new default stands.
    expect(form.entry('steps'), 'fast');
    expect(form.entry('negative_prompt'), false);
    // Narrowed range, removed option: the default, not the invalid value.
    expect(form.entry('width'), '768');
    expect(form.entry('sampler'), 'euler');
    // Still valid: kept.
    expect(form.text('prompt'), typed);
    expect(form.entry('height'), '1024');
    expect(form.entry('seed'), '12345');
    final validated = form.validate();
    expect(validated.isReady, isTrue, reason: 'nothing invalid was carried');
    expect(validated.inputs['strength'], 0.75);
    expect(validated.inputs['steps'], 'fast');
    expect(validated.inputs['width'], 768);
  }

  group('through refresh()', () {
    test('the same schema keeps the form, its values, and costs no extra '
        'notifications — and a changed one, in the same run, does not', () async {
      final controller = controllerFor(settings: PreferencesWorkflowSettingsStore());
      final form = await openAndFill(controller);
      final detail = controller.selectedDetail;
      var notifications = 0;
      controller.addListener(() => notifications++);
      final asked = pc.detailCalls.length;

      expect(await refreshed(controller), isNull);

      expect(
        pc.detailCalls.sublist(asked),
        <String>[txt2img],
        reason: 'the schema really was asked for again',
      );
      expect(identical(controller.form, form), isTrue);
      expect(identical(controller.selectedDetail, detail), isTrue);
      expectUntouched(form);
      // The refresh's own two: running, then done. The re-read adds none.
      expect(notifications, 2);

      // The same run, with the PC's schema changed: the path above was
      // reachable, and only equality kept the form.
      pc.bodies[txt2img] = changedTxt2img();
      notifications = 0;
      expect(await refreshed(controller), isNull);

      expect(identical(controller.form, form), isFalse);
      expect(
        notifications,
        3,
        reason: 'running, done, then the swap once the schema answered',
      );
    });

    test('a changed schema: added at its default, removed dropped, retyped '
        'and now-invalid values dropped, still-valid values kept', () async {
      final controller = controllerFor(settings: PreferencesWorkflowSettingsStore());
      final old = await openAndFill(controller);
      old
        ..advancedOpen = true
        ..freezeSeed = true;
      pc.bodies[txt2img] = changedTxt2img();

      await refreshed(controller);

      final fresh = controller.form!;
      expect(identical(fresh, old), isFalse);
      expect(controller.selectedDetail!.inputs.map((f) => f.id), contains('strength'));
      expect(identical(fresh.detail, controller.selectedDetail), isTrue);
      expectCarriedOver(fresh);
      // Neither a field nor a setting, and both carried: the section the user
      // had open stays open, and a frozen seed stays frozen.
      expect(fresh.advancedOpen, isTrue);
      expect(fresh.freezeSeed, isTrue);
      expect(isDisposed(old), isTrue, reason: 'the old form is disposed');
      expect(isDisposed(fresh), isFalse);
    });

    test('My defaults are laid under what the old form carried, as when a '
        'workflow is opened', () async {
      final settings = PreferencesWorkflowSettingsStore();
      await settings.save(
        txt2img,
        <String, Object?>{'strength': 0.4, 'height': 512},
        declaredFields: <String>{'strength', 'height'},
      );
      final controller = controllerFor(settings: settings);
      final old = await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();

      await refreshed(controller);

      final fresh = controller.form!;
      expect(identical(fresh, old), isFalse);
      // A new field with a saved default arrives at that default...
      expect(fresh.entry('strength'), '0.4');
      expect(fresh.hasMyDefaults, isTrue);
      // ...and what the user had on screen still wins over a saved one.
      expect(fresh.entry('height'), '1024');
    });

    test('the translation switch comes as it stands, both ways', () async {
      final settings = PreferencesWorkflowSettingsStore();
      final controller = controllerFor(settings: settings);
      final old = await openAndFill(controller);
      old.translatePrompt = false;
      pc.bodies[txt2img] = changedTxt2img();

      await refreshed(controller);
      expect(identical(controller.form, old), isFalse);
      expect(controller.form!.translatePrompt, isFalse);

      // Saved off, switched back on for now: the "on" in force is carried,
      // not the saved "off".
      await settings.saveTranslateOverride(txt2img, false);
      final second = controller.form!..translatePrompt = true;
      pc.bodies[txt2img] = txt2imgDetail();
      await refreshed(controller);
      expect(identical(controller.form, second), isFalse);
      expect(controller.form!.translatePrompt, isTrue);
      expect(controller.form!.durableTranslatePrompt, isFalse);
    });

    test('the autosave writes from the new form, the swap itself writes '
        'nothing, and the old form is disposed', () async {
      final clock = HandClock();
      final controller = controllerFor(
        settings: PreferencesWorkflowSettingsStore(),
        drafts: PreferencesWorkflowDraftStore(),
        clock: clock,
      );
      final old = await openAndFill(controller);
      expect(clock.isWaiting, isTrue);
      clock.elapse();
      await pumpEventQueue();
      pc.bodies[txt2img] = changedTxt2img();

      await refreshed(controller);

      final fresh = controller.form!;
      expect(identical(fresh, old), isFalse);
      expect(isDisposed(old), isTrue);
      expect(clock.isWaiting, isFalse, reason: 'a swap is not a user change');

      fresh.setEntry('strength', '0.5');
      expect(clock.isWaiting, isTrue, reason: 'the new form is watched');
      clock.elapse();
      await pumpEventQueue();

      final stored = await SharedPreferencesAsync().getAll();
      expect(stored['localcanvas.draft.$txt2img.strength'], 0.5);
      expect(stored['localcanvas.draft.$txt2img.prompt'], typed);
      expect(stored['localcanvas.draft.$txt2img.steps'], 'fast');
    });

    test('saved setups are untouched, and apply to the new form', () async {
      final setups = PreferencesWorkflowSetupStore();
      final controller = controllerFor(
        settings: PreferencesWorkflowSettingsStore(),
        setups: setups,
      );
      await openAndFill(controller);
      final saved = await controller.saveSetup(workflowId: txt2img, name: 'Dawn');
      final listed = controller.setupsFor(txt2img);
      expect(listed, hasLength(1));
      pc.bodies[txt2img] = changedTxt2img();

      await refreshed(controller);

      expect(identical(controller.setupsFor(txt2img), listed), isTrue);
      expect(await setups.load(txt2img), hasLength(1));
      controller.form!.setEntry('prompt', 'something else');
      controller.applySetup(saved!);
      expect(controller.form!.text('prompt'), typed);
      expect(controller.form!.entry('steps'), 'fast', reason: 'dropped again');
    });

    test('the new list is applied and announced without waiting for the '
        'schema; meanwhile the old form stays and nothing loads in its place',
        () async {
      final controller = controllerFor(settings: PreferencesWorkflowSettingsStore());
      final old = await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      pc.bodies['imported'] = renamed(
        img2imgDetail(),
        id: 'imported',
        name: 'Imported',
      );
      final announced = <(int, bool)>[];
      controller.addListener(
        () => announced.add((
          controller.workflows.length,
          controller.isRefreshing,
        )),
      );
      final gate = pc.detailHold = Completer<void>();

      var returned = false;
      final refreshing = controller.refresh().then((failure) {
        returned = true;
        return failure;
      });
      await pumpEventQueue();

      expect(pc.detailCalls.last, txt2img, reason: 'the schema is held');
      expect(returned, isTrue, reason: 'refresh() did not wait for it');
      expect(await refreshing, isNull);
      expect(controller.isRefreshing, isFalse);
      expect(controller.workflows, hasLength(3));
      expect(
        announced.last,
        (3, false),
        reason: 'the new list reached listeners before the schema answered',
      );
      expect(controller.phase, RegistryPhase.ready);
      expect(controller.isLoadingDetail, isFalse);
      expect(identical(controller.form, old), isTrue);
      expect(controller.selectedDetail!.inputs.map((f) => f.id), isNot(contains('strength')));
      // Still usable while it runs, and what is typed now is carried.
      old.setEntry('prompt', '$typed, and gulls');

      gate.complete();
      await pumpEventQueue();

      expect(identical(controller.form, old), isFalse);
      expect(controller.form!.text('prompt'), '$typed, and gulls');
    });

    test('a schema that could not be read again keeps the old form, says '
        'nothing, and is asked for again when chosen', () async {
      final controller = controllerFor(settings: PreferencesWorkflowSettingsStore());
      final old = await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      pc.detailFailure = const WorkflowsFailure.unreachable();
      final asked = pc.detailCalls.length;

      expect(await refreshed(controller), isNull);

      expect(pc.detailCalls.length, asked + 1, reason: 'it was asked, and failed');
      expect(identical(controller.form, old), isTrue);
      expect(isDisposed(old), isFalse);
      expect(controller.selectedId, txt2img);
      expect(controller.detailFailure, isNull);
      expectUntouched(old);

      // Still stale: choosing it again asks again, and this time it arrives.
      pc.detailFailure = null;
      await controller.select(txt2img);
      expect(pc.detailCalls.length, asked + 2);
      expect(identical(controller.form, old), isFalse);
      expectCarriedOver(controller.form!);
    });

    test('a workflow not on screen is asked for again when it is chosen, '
        'showing its old form meanwhile; a fresh chosen one changes nothing',
        () async {
      final controller = controllerFor(settings: PreferencesWorkflowSettingsStore());
      final oldTxt = await openAndFill(controller);
      await controller.select(img2img);
      final img = controller.form!;
      pc.bodies[txt2img] = changedTxt2img();
      final asked = pc.detailCalls.length;

      await refreshed(controller);

      expect(
        pc.detailCalls.sublist(asked),
        <String>[img2img],
        reason: 'only the chosen workflow is asked for at once',
      );
      expect(identical(controller.form, img), isTrue);

      final gate = pc.detailHold = Completer<void>();
      final selecting = controller.select(txt2img);
      expect(controller.selectedId, txt2img);
      expect(identical(controller.form, oldTxt), isTrue, reason: 'shown at once');
      expect(controller.isLoadingDetail, isFalse);
      await pumpEventQueue();
      expect(pc.detailCalls.last, txt2img);

      gate.complete();
      await selecting;
      expect(identical(controller.form, oldTxt), isFalse);
      expectCarriedOver(controller.form!);
      expect(isDisposed(oldTxt), isTrue);

      // Fresh now: choosing it again asks nothing and says nothing.
      final form = controller.form;
      final calls = pc.detailCalls.length;
      var notifications = 0;
      controller.addListener(() => notifications++);
      await controller.select(txt2img);
      expect(pc.detailCalls.length, calls);
      expect(notifications, 0);
      expect(identical(controller.form, form), isTrue);
    });

    test('an answer overtaken by a change of server writes nothing', () async {
      final controller = controllerFor();
      await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      final gate = pc.detailHold = Completer<void>();
      final refreshing = controller.refresh();
      await pumpEventQueue();
      expect(pc.detailCalls.last, txt2img, reason: 'the changed schema is out');

      // Another server, serving the old schema, and the same workflow opened.
      pc.bodies[txt2img] = txt2imgDetail();
      await controller.load(elsewhere);
      await controller.select(txt2img);
      final there = controller.form!..setEntry('prompt', 'typed over there');

      gate.complete();
      expect(await refreshing, isNull);
      await pumpEventQueue();

      expect(identical(controller.form, there), isTrue);
      expect(isDisposed(there), isFalse);
      expect(controller.selectedDetail!.inputs.map((f) => f.id), isNot(contains('strength')));
      expect(controller.form!.text('prompt'), 'typed over there');
    });

    test('...including one overtaken while My defaults were being read',
        () async {
      final settings = HeldSettingsStore();
      final controller = controllerFor(settings: settings);
      await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      final gate = settings.loadHold = Completer<void>();
      final refreshing = controller.refresh();
      await pumpEventQueue();
      expect(pc.detailCalls.last, txt2img, reason: 'the schema arrived');

      pc.bodies[txt2img] = txt2imgDetail();
      await controller.load(elsewhere);
      await controller.select(txt2img);
      final there = controller.form!;

      gate.complete();
      await refreshing;
      await pumpEventQueue();

      expect(identical(controller.form, there), isTrue);
      expect(controller.selectedDetail!.inputs.map((f) => f.id), isNot(contains('strength')));
    });
  });

  test('two re-reads of one workflow: the one that swapped first stands, and '
      'the later one, still reading My defaults, writes nothing', () async {
    final settings = HeldSettingsStore();
    final controller = controllerFor(settings: settings);
    final oldTxt = await openAndFill(controller);
    await controller.select(img2img);
    pc.bodies[txt2img] = changedTxt2img();
    await refreshed(controller);

    // First choice of the stale workflow: its rebuild is held on the store.
    final gate = settings.loadHold = Completer<void>();
    final first = controller.select(txt2img);
    await pumpEventQueue();
    expect(identical(controller.form, oldTxt), isTrue, reason: 'still held');

    // Away and back: a second re-read, which is let through.
    await controller.select(img2img);
    await controller.select(txt2img);
    final swapped = controller.form!;
    expect(identical(swapped, oldTxt), isFalse);
    expect(isDisposed(oldTxt), isTrue);

    gate.complete();
    await first;
    await pumpEventQueue();

    expect(identical(controller.form, swapped), isTrue);
    expect(isDisposed(swapped), isFalse);
    expectCarriedOver(swapped);
  });

  // The token each re-read carries, driven on every path that starts one. Each
  // holds a slow answer and lets something newer happen before it lands.
  group('a late answer writes nothing', () {
    test('select(): a stale re-read overtaken by a Refresh on the same server '
        'does not swap the form back to the older schema', () async {
      final controller = controllerFor();
      await openAndFill(controller);
      await controller.select(img2img);
      pc.bodies[txt2img] = changedTxt2img();
      await refreshed(controller);

      // Chosen while stale: its re-read is held, answering `strength`.
      final gate = pc.detailHold = Completer<void>();
      final selecting = controller.select(txt2img);
      await pumpEventQueue();
      expect(pc.detailCalls.last, txt2img, reason: 'the older answer is out');

      // A Refresh reads a newer list, and its own re-read swaps to `clarity`.
      pc.bodies[txt2img] = changedAgainTxt2img();
      expect(await refreshed(controller), isNull);
      final newer = controller.form!;
      expect(fieldIds(controller), contains('clarity'));

      gate.complete();
      await selecting;
      await pumpEventQueue();

      expect(identical(controller.form, newer), isTrue);
      expect(isDisposed(newer), isFalse);
      expect(fieldIds(controller), contains('clarity'));
      expect(fieldIds(controller), isNot(contains('strength')));
    });

    test('select(): a stale re-read from one server, landing after the same '
        'workflow was opened on another', () async {
      final controller = controllerFor();
      await openAndFill(controller);
      await controller.select(img2img);
      pc.bodies[txt2img] = changedTxt2img();
      await refreshed(controller);

      final gate = pc.detailHold = Completer<void>();
      final selecting = controller.select(txt2img);
      await pumpEventQueue();
      expect(pc.detailCalls.last, txt2img, reason: 'the changed schema is out');

      pc.bodies[txt2img] = txt2imgDetail();
      await controller.load(elsewhere);
      await controller.select(txt2img);
      final there = controller.form!;
      expect(fieldIds(controller), isNot(contains('strength')));

      gate.complete();
      await selecting;
      await pumpEventQueue();

      expect(identical(controller.form, there), isTrue);
      expect(isDisposed(there), isFalse);
      expect(fieldIds(controller), isNot(contains('strength')));
    });

    test('reload(): an older re-read overtaken by a newer list does not swap '
        'the form back', () async {
      final controller = controllerFor();
      await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      final gate = pc.detailHold = Completer<void>();
      await controller.reload();
      await pumpEventQueue();
      expect(pc.detailCalls.last, txt2img, reason: 'the older answer is out');

      pc.bodies[txt2img] = changedAgainTxt2img();
      await controller.reload();
      await pumpEventQueue();
      final newer = controller.form!;
      expect(fieldIds(controller), contains('clarity'));

      gate.complete();
      await pumpEventQueue();

      expect(identical(controller.form, newer), isTrue);
      expect(fieldIds(controller), contains('clarity'));
      expect(fieldIds(controller), isNot(contains('strength')));
    });

    test('refresh(): an older re-read overtaken by a newer list does not swap '
        'the form back', () async {
      final controller = controllerFor();
      await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      final gate = pc.detailHold = Completer<void>();
      expect(await refreshed(controller), isNull);
      expect(pc.detailCalls.last, txt2img, reason: 'the older answer is out');

      pc.bodies[txt2img] = changedAgainTxt2img();
      expect(await refreshed(controller), isNull);
      final newer = controller.form!;
      expect(fieldIds(controller), contains('clarity'));

      gate.complete();
      await pumpEventQueue();

      expect(identical(controller.form, newer), isTrue);
      expect(fieldIds(controller), contains('clarity'));
      expect(fieldIds(controller), isNot(contains('strength')));
    });
  });

  group('through reload()', () {
    test('the same schema keeps the form, with no extra notification; a '
        'changed one is swapped with one', () async {
      final controller = controllerFor(settings: PreferencesWorkflowSettingsStore());
      final form = await openAndFill(controller);
      var notifications = 0;
      controller.addListener(() => notifications++);
      final asked = pc.detailCalls.length;

      await controller.reload();
      await pumpEventQueue();

      expect(pc.detailCalls.sublist(asked), <String>[txt2img]);
      expect(identical(controller.form, form), isTrue);
      expectUntouched(form);
      expect(notifications, 2, reason: 'loading, then ready');

      pc.bodies[txt2img] = changedTxt2img();
      notifications = 0;
      await controller.reload();
      await pumpEventQueue();

      expect(identical(controller.form, form), isFalse);
      expect(notifications, 3, reason: 'loading, ready, then the swap');
      expectCarriedOver(controller.form!);
      expect(isDisposed(form), isTrue);
    });

    test('a failure keeps the old form', () async {
      final controller = controllerFor();
      final old = await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      pc.detailFailure = const WorkflowsFailure.unreachable();

      await controller.reload();
      await pumpEventQueue();

      expect(controller.phase, RegistryPhase.ready);
      expect(identical(controller.form, old), isTrue);
      expect(controller.detailFailure, isNull);
      expectUntouched(old);
    });

    test('an answer overtaken by a change of server writes nothing', () async {
      final controller = controllerFor();
      await openAndFill(controller);
      pc.bodies[txt2img] = changedTxt2img();
      final gate = pc.detailHold = Completer<void>();
      await controller.reload();
      await pumpEventQueue();
      expect(pc.detailCalls.last, txt2img);

      pc.bodies[txt2img] = txt2imgDetail();
      await controller.load(elsewhere);
      await controller.select(txt2img);
      final there = controller.form!;

      gate.complete();
      await pumpEventQueue();

      expect(identical(controller.form, there), isTrue);
      expect(controller.selectedDetail!.inputs.map((f) => f.id), isNot(contains('strength')));
    });
  });

  group('value equality of a schema', () {
    test('every key the parser reads has a variant, and every variant makes '
        'two schemas differ', () {
      Map<String, Object?> withInput(
        String fieldId,
        Map<String, Object?> Function(Map<String, Object?> field) change,
      ) {
        final body = txt2imgDetail();
        return <String, Object?>{
          ...body,
          'inputs': <Object?>[
            for (final raw in body['inputs']! as List<Object?>)
              if ((raw! as Map<String, Object?>)['id'] == fieldId)
                change(Map<String, Object?>.from(raw as Map<String, Object?>))
              else
                raw,
          ],
        };
      }

      Map<String, Object?> withSeed(String key, Object? value) =>
          withInput('seed', (field) => field..[key] = value);

      Map<String, Object?> withFirstSamplerOption(String key, Object? value) =>
          withInput('sampler', (field) {
            final options = <Object?>[
              ...field['options']! as List<Object?>,
            ];
            options[0] = <String, Object?>{
              ...options[0]! as Map<String, Object?>,
              key: value,
            };
            return field..['options'] = options;
          });

      Map<String, Object?> withPresentation(String key, Object? value) {
        final body = txt2imgDetail();
        return <String, Object?>{
          ...body,
          'presentation': <String, Object?>{
            ...body['presentation']! as Map<String, Object?>,
            key: value,
          },
        };
      }

      Map<String, Object?> withTop(String key, Object? value) =>
          <String, Object?>{...txt2imgDetail(), key: value};

      final base = txt2imgDetail();
      final withFps = withSeed('duration', <String, Object?>{'fps': 24});

      // The same workflow with every optional key taken out, at every level —
      // only `id` on the workflow and on each field and `value` on each option
      // stay, plus the containers that lead to them (`presentation`, `inputs`,
      // `options`, `duration`), each emptied the same way. A key read only
      // when another is absent — a fallback such as `badge ?? json['tag']` —
      // is read on this body and on no other.
      Object? stripped(Object? value, Set<String> keep) {
        if (value is! Map) return value;
        return <String, Object?>{
          for (final entry in value.entries)
            if (keep.contains(entry.key)) entry.key: entry.value,
        };
      }

      const containers = <String>{'presentation', 'inputs', 'options', 'duration'};
      final bare = <String, Object?>{
        ...stripped(withFps, <String>{'id', ...containers})!
            as Map<String, Object?>,
        'presentation': <String, Object?>{},
        'inputs': <Object?>[
          for (final field in (withFps['inputs']! as List<Object?>)
              .cast<Map<String, Object?>>())
            <String, Object?>{
              ...stripped(field, <String>{'id'})! as Map<String, Object?>,
              if (field['options'] is List)
                'options': <Object?>[
                  for (final option in field['options']! as List<Object?>)
                    stripped(option, <String>{'value'}),
                ],
              if (field['duration'] is Map) 'duration': <String, Object?>{},
            },
        ],
      };

      // Which keys the parser reads, recorded while it reads them — over the
      // base body, over one whose seed has a duration (so the nested `fps` is
      // reached), and over the bare body above. Nothing here repeats what the
      // parser does.
      //
      // Stated limit: only branches these three bodies take are recorded. A
      // key read only when a present key has some particular value (say, one
      // read only for `type: select`, or only when a number is negative) can
      // still escape; the bare body closes the fallback-on-absence case.
      final reads = KeyReads();
      for (final body in <Map<String, Object?>>[base, withFps, bare]) {
        WorkflowDetail.tryFromJson(reads.wrap(body, ''));
      }
      expect(
        WorkflowDetail.tryFromJson(bare)!.inputs.length,
        (base['inputs']! as List<Object?>).length,
        reason: 'the bare body is still a workflow with every field in it',
      );

      // Each variant is a pair of bodies that must parse to unequal schemas,
      // keyed by the path of the one key it changes.
      final variants = <String, (Map<String, Object?>, Map<String, Object?>)>{
        'id': (base, withTop('id', 'renamed_id')),
        'name': (base, withTop('name', 'Renamed')),
        'input_summary': (base, withTop('input_summary', 'Changed')),
        'required_media': (base, withTop('required_media', <Object?>['image'])),
        'presentation': (base, withTop('presentation', null)),
        'presentation.group': (base, withPresentation('group', 'Edit')),
        'presentation.category': (base, withPresentation('category', 'Other')),
        'presentation.badge': (base, withPresentation('badge', 'NEW')),
        'presentation.short_description': (
          base,
          withPresentation('short_description', 'Other'),
        ),
        'presentation.best_for': (
          base,
          withPresentation('best_for', <Object?>['x']),
        ),
        'presentation.how_to_use': (
          base,
          withPresentation('how_to_use', 'Other'),
        ),
        'presentation.input_summary': (
          base,
          withPresentation('input_summary', 'Changed'),
        ),
        'presentation.example_prompt': (
          base,
          withPresentation('example_prompt', 'Other'),
        ),
        'presentation.not_ideal_for': (
          base,
          withPresentation('not_ideal_for', <Object?>['x']),
        ),
        'inputs': (
          base,
          withTop(
            'inputs',
            (txt2imgDetail()['inputs']! as List<Object?>).sublist(1),
          ),
        ),
        'inputs[].id': (base, withSeed('id', 'seed2')),
        'inputs[].label': (base, withSeed('label', 'Seed!')),
        'inputs[].type': (base, withSeed('type', 'float')),
        'inputs[].required': (base, withSeed('required', true)),
        'inputs[].section': (base, withSeed('section', 'main')),
        'inputs[].default': (base, withSeed('default', 7)),
        'inputs[].help': (base, withSeed('help', 'other')),
        'inputs[].min': (base, withSeed('min', 1)),
        'inputs[].max': (base, withSeed('max', 99)),
        'inputs[].step': (base, withSeed('step', 2)),
        'inputs[].options': (
          base,
          withSeed('options', <Object?>[
            <String, Object?>{'value': 1, 'label': 'One'},
          ]),
        ),
        'inputs[].options[].value': (
          base,
          withFirstSamplerOption('value', 'euler_renamed'),
        ),
        'inputs[].options[].label': (
          base,
          withFirstSamplerOption('label', 'Euler!'),
        ),
        'inputs[].role': (base, withSeed('role', null)),
        'inputs[].pair': (base, withSeed('pair', 'width')),
        'inputs[].duration': (base, withFps),
        'inputs[].duration.fps': (
          withFps,
          withSeed('duration', <String, Object?>{'fps': 25}),
        ),
      };

      expect(
        reads.paths.difference(variants.keys.toSet()),
        isEmpty,
        reason: 'a key the parser reads has no variant here: add one',
      );
      expect(
        variants.keys.toSet().difference(reads.paths),
        isEmpty,
        reason: 'a variant for a key the parser does not read',
      );
      for (final entry in variants.entries) {
        final (left, right) = entry.value;
        final a = WorkflowDetail.tryFromJson(left)!;
        final b = WorkflowDetail.tryFromJson(right)!;
        expect(a == b, isFalse, reason: entry.key);
      }

      final parsed = WorkflowDetail.tryFromJson(base)!;
      expect(WorkflowDetail.tryFromJson(txt2imgDetail()), parsed);
      // Field order is part of a schema.
      expect(
        WorkflowDetail.tryFromJson(
              withTop(
                'inputs',
                (txt2imgDetail()['inputs']! as List<Object?>).reversed.toList(),
              ),
            ) ==
            parsed,
        isFalse,
      );
      // `default: null` against no `default` at all: only hasDefault differs.
      expect(
        WorkflowDetail.tryFromJson(withSeed('default', null)) ==
            WorkflowDetail.tryFromJson(
              withInput('seed', (field) => field..remove('default')),
            ),
        isFalse,
      );
      // Option values and defaults are compared as JSON values, deeply.
      final listDefault = WorkflowDetail.tryFromJson(
        withSeed('default', <Object?>[1, <String, Object?>{'a': 2}]),
      );
      expect(
        WorkflowDetail.tryFromJson(
          withSeed('default', <Object?>[1, <String, Object?>{'a': 2}]),
        ),
        listDefault,
      );
      expect(
        WorkflowDetail.tryFromJson(
              withSeed('default', <Object?>[1, <String, Object?>{'a': 3}]),
            ) ==
            listDefault,
        isFalse,
      );
      // A key this app does not read cannot make two schemas differ.
      expect(WorkflowDetail.tryFromJson(withTop('something_new', true)), parsed);
    });
  });

  // Design decision on T-0236: the old form's media controller is handed to
  // the new form where the same field id is still media of the same kind.
  group('chosen media across a changed schema', () {
    late ScriptedMediaPicker picker;
    late ScriptedMediaApi uploads;
    late WorkflowsController controller;

    /// Everything reported through FlutterError while a test ran. A
    /// ChangeNotifier reports a listener that throws here rather than to the
    /// caller — a disposed form still listening to a handed controller is
    /// reported this way — so each test ends by asserting it is empty.
    late List<String> reported;

    setUp(() async {
      reported = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (details) =>
          reported.add(details.exceptionAsString());
      addTearDown(() => FlutterError.onError = previous);
      picker = ScriptedMediaPicker();
      uploads = ScriptedMediaApi();
      controller = WorkflowsController(
        api: pc,
        mediaPicker: picker,
        mediaApi: uploads,
        settings: PreferencesWorkflowSettingsStore(),
      );
      addTearDown(controller.dispose);
      await controller.load(studio);
      await controller.select(img2img);
    });

    /// img2img with one field added: `source_image` is still an image.
    Map<String, Object?> withAddedField() {
      final body = img2imgDetail();
      return <String, Object?>{
        ...body,
        'inputs': <Object?>[
          ...body['inputs']! as List<Object?>,
          <String, Object?>{
            'id': 'added',
            'label': 'Added',
            'type': 'boolean',
            'required': false,
            'section': 'advanced',
            'default': true,
          },
        ],
      };
    }

    /// img2img whose `source_image` is now a clip.
    Map<String, Object?> withSourceAsVideo() {
      final body = img2imgDetail();
      return <String, Object?>{
        ...body,
        'inputs': <Object?>[
          for (final raw in body['inputs']! as List<Object?>)
            if ((raw! as Map<String, Object?>)['id'] == 'source_image')
              <String, Object?>{
                ...(raw as Map<String, Object?>),
                'type': 'video',
              }
            else
              raw,
        ],
      };
    }

    test('a settled picture survives: the same controller, the same upload',
        () async {
      final old = controller.form!;
      final media = old.media('source_image')!;
      picker.answers = <MediaSelection?>[tempSelection()];
      await media.choose();
      expect(media.phase, MediaPhase.ready);
      final uploaded = media.mediaId;
      pc.bodies[img2img] = withAddedField();

      await refreshed(controller);

      final fresh = controller.form!;
      expect(identical(fresh, old), isFalse, reason: 'the schema changed');
      expect(identical(fresh.media('source_image'), media), isTrue);
      expect(media.phase, MediaPhase.ready);
      expect(media.mediaId, uploaded);
      expect(fresh.validate().issueFor('source_image'), isNull);
      expect(
        fresh.validate().inputs['source_image'],
        <String, Object?>{'media_id': uploaded},
      );
      expect(uploads.calls, 1, reason: 'nothing is sent twice');
      expect(reported, isEmpty);
    });

    test('an upload in flight across the swap lands in the new form',
        () async {
      final old = controller.form!;
      final media = old.media('source_image')!;
      picker.answers = <MediaSelection?>[tempSelection()];
      uploads.manual = true;
      final choosing = media.choose();
      await pumpEventQueue();
      expect(media.phase, MediaPhase.uploading);
      pc.bodies[img2img] = withAddedField();

      await refreshed(controller);
      final fresh = controller.form!;
      expect(identical(fresh, old), isFalse);
      expect(identical(fresh.media('source_image'), media), isTrue);
      expect(media.phase, MediaPhase.uploading);
      expect(
        fresh.validate().issueFor('source_image')?.kind,
        FieldIssueKind.mediaNotReady,
      );

      var told = 0;
      fresh.addListener(() => told++);
      uploads.finish();
      await choosing;

      expect(media.phase, MediaPhase.ready);
      expect(media.mediaId, 'm-3f9c1a-1');
      expect(told, greaterThan(0), reason: 'the new form hears it land');
      expect(
        fresh.validate().inputs['source_image'],
        <String, Object?>{'media_id': 'm-3f9c1a-1'},
      );
      expect(uploads.calls, 1);
      expect(reported, isEmpty);
    });

    test('the old form\'s dispose leaves the handed controller alive, and '
        'the new form owns it', () async {
      final old = controller.form!;
      final media = old.media('source_image')!;
      picker.answers = <MediaSelection?>[tempSelection()];
      await media.choose();
      pc.bodies[img2img] = withAddedField();

      await refreshed(controller);

      expect(isDisposed(old), isTrue);
      expect(isDisposed(media), isFalse);
      expect(old.media('source_image'), isNull, reason: 'given away');
      // Still usable where it now lives.
      final fresh = controller.form!;
      var told = 0;
      fresh.addListener(() => told++);
      media.remove();
      expect(told, greaterThan(0));
      expect(fresh.validate().issueFor('source_image')?.kind, FieldIssueKind.missing);

      // Owned by the new form: disposed with it, not before — a change of
      // server disposes every form.
      await controller.load(elsewhere);
      expect(isDisposed(fresh), isTrue);
      expect(isDisposed(media), isTrue);
      expect(reported, isEmpty);
    });

    test('a kind change is not handed over: the field is empty, and the old '
        'controller goes with the old form, its upload abandoned', () async {
      final old = controller.form!;
      final media = old.media('source_image')!;
      picker.answers = <MediaSelection?>[tempSelection()];
      uploads.manual = true;
      final choosing = media.choose();
      await pumpEventQueue();
      expect(media.phase, MediaPhase.uploading);
      pc.bodies[img2img] = withSourceAsVideo();

      await refreshed(controller);

      final fresh = controller.form!;
      expect(identical(fresh, old), isFalse);
      final now = fresh.media('source_image')!;
      expect(identical(now, media), isFalse);
      expect(now.kind, MediaKind.video);
      expect(now.selection, isNull);
      expect(now.phase, MediaPhase.empty);
      expect(isDisposed(media), isTrue);

      // No cancel exists: the request runs out, and its answer reaches nobody.
      uploads.finish();
      await choosing;
      expect(uploads.calls, 1);
      expect(now.phase, MediaPhase.empty);
      expect(now.mediaId, isNull);
      expect(reported, isEmpty);
    });

    test('a handed choice is checked again where it now lives: one whose file '
        'is gone is dropped, as a vanished file is', () async {
      final old = controller.form!;
      final media = old.media('source_image')!;
      final selection = tempSelection();
      picker.answers = <MediaSelection?>[selection];
      uploads.failure = const MediaFailure.unreachable();
      await media.choose();
      expect(media.phase, MediaPhase.failed, reason: 'so it is re-checked');

      // Off screen while the list is re-read, so the refresh's own media
      // check runs while the file is still there.
      await controller.select(txt2img);
      pc.bodies[img2img] = withAddedField();
      await refreshed(controller);
      expect(media.selection, isNotNull);
      File((selection.source as FileMediaSource).path).deleteSync();

      await controller.select(img2img);

      final fresh = controller.form!;
      expect(identical(fresh, old), isFalse);
      expect(identical(fresh.media('source_image'), media), isTrue);
      expect(media.selection, isNull);
      expect(media.phase, MediaPhase.empty);
      expect(reported, isEmpty);
    });
  });

  group('on screen', () {
    /// The shell, connected, with txt2img chosen and [typed] in its prompt.
    Future<WorkflowsController> shellOnTxt2img(WidgetTester tester) async {
      tester.view.physicalSize = const Size(420, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final workflows = WorkflowsController(api: pc);
      addTearDown(workflows.dispose);
      final connection = ConnectionController(
        client: ScriptedGatewayClient(
          (e) => HandshakeSucceeded(e, testIdentity()),
        ),
        store: InMemoryEndpointStore(),
        discovery: silentDiscovery(),
        retryDelay: Duration.zero,
      );
      addTearDown(connection.dispose);
      await connection.connectTo(studio);
      final session = testSession(connection: connection, workflows: workflows);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: testDelegates,
          supportedLocales: testLocales,
          theme: lcDarkTheme(),
          home: ConnectedShell(session: session),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.chooseWorkflow));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LcKeys.workflowCard(txt2img)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(LcKeys.field('prompt')), typed);
      await tester.pumpAndSettle();
      return workflows;
    }

    testWidgets('the form stays while the schema is asked for, then shows the '
        'new field with the words kept', (tester) async {
      final workflows = await shellOnTxt2img(tester);
      final old = workflows.form!;
      expect(find.byKey(LcKeys.field('strength')), findsNothing);

      pc.bodies[txt2img] = changedTxt2img();
      final gate = pc.detailHold = Completer<void>();
      unawaited(workflows.refresh());
      await tester.pump();
      await tester.pump();

      expect(pc.detailCalls.last, txt2img);
      expect(find.byKey(LcKeys.workflowForm), findsOneWidget);
      expect(find.byKey(LcKeys.workflowsLoading), findsNothing);
      expect(find.text(typed), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(identical(workflows.form, old), isFalse);
      expect(isDisposed(old), isTrue);
      expect(find.byKey(LcKeys.field('strength')), findsOneWidget);
      expect(find.text(typed), findsOneWidget);

      // The screen is bound to the new form: typing reaches it.
      await tester.enterText(find.byKey(LcKeys.field('prompt')), 'retyped');
      await tester.pumpAndSettle();
      expect(workflows.form!.text('prompt'), 'retyped');
    });

    testWidgets('the chosen workflow\'s open details show the schema held now, '
        'not the one they first showed', (tester) async {
      final workflows = await shellOnTxt2img(tester);
      await tester.tap(find.byKey(LcKeys.selectedWorkflowToggle));
      await tester.pumpAndSettle();
      final defaults = find.byKey(LcKeys.workflowHelpDefaults);
      Finder inDefaults(String text) =>
          find.descendant(of: defaults, matching: find.text(text));
      expect(defaults, findsOneWidget);
      expect(inDefaults('Guidance'), findsOneWidget);
      expect(inDefaults('Strength'), findsNothing);

      pc.bodies[txt2img] = changedTxt2img();
      unawaited(workflows.refresh());
      await tester.pumpAndSettle();

      expect(
        find.byKey(LcKeys.field('strength')),
        findsOneWidget,
        reason: 'the form was swapped',
      );
      expect(inDefaults('Strength'), findsOneWidget);
      expect(inDefaults('Guidance'), findsNothing, reason: 'removed on the PC');
      expect(tester.takeException(), isNull);
    });
  });
}
