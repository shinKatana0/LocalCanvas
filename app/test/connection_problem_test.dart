/// Four conditions, four messages. Collapsing any two of them is the defect
/// this file exists to catch (`docs/recovery.md`).
library;

import 'package:flutter_test/flutter_test.dart';
import 'support/l10n.dart';
import 'package:localcanvas/connection/connection_problem.dart';

void main() {
  ConnectionNotice notice(ConnectionProblem problem) => describeProblem(
    problem,
    address: 'http://192.0.2.42:7801',
    serverName: 'Studio PC',
    serverApiVersion: 7,
    detail: 'It is not answering on its port.',
  );

  test('every problem produces a different sentence', () {
    final titles = ConnectionProblem.values.map((p) => notice(p).title).toSet();
    final messages =
        ConnectionProblem.values.map((p) => notice(p).message).toSet();

    expect(titles, hasLength(ConnectionProblem.values.length));
    expect(messages, hasLength(ConnectionProblem.values.length));
  });

  test('unreachable says nothing answered', () {
    final text = notice(ConnectionProblem.unreachable);
    expect(text.title(en), contains("can't be reached"));
    expect(text.message(en), contains('http://192.0.2.42:7801'));
    expect(text.isConnected, isFalse);
  });

  test('not-a-gateway says something answered but was not us', () {
    final text = notice(ConnectionProblem.notLocalCanvas);
    expect(text.title(en), contains("isn't a LocalCanvas server"));
    expect(text.message(en), contains('Something answered'));
    expect(text.isConnected, isFalse);
  });

  test('an incompatible version names both versions', () {
    final text = describeProblem(
      ConnectionProblem.incompatibleVersion,
      address: 'http://192.0.2.42:7801',
      serverApiVersion: 7,
      clientApiVersion: 1,
    );
    expect(text.message(en), contains('7'));
    expect(text.message(en), contains('1'));
    expect(text.isConnected, isFalse);
  });

  test('a down generator is the one condition that is still connected', () {
    final text = notice(ConnectionProblem.comfyUnavailable);
    // The exact sentence docs/recovery.md prescribes.
    expect(text.title(en), "Connected, but ComfyUI isn't running.");
    expect(text.message(en), contains('Studio PC'));
    expect(text.message(en), contains('It is not answering on its port.'));
    expect(text.isConnected, isTrue);
  });

  test('no message shows a status code or an exception', () {
    for (final problem in ConnectionProblem.values) {
      final text = notice(problem);
      for (final sentence in <String>[text.title(en), text.message(en)]) {
        expect(sentence, isNot(contains('Exception')));
        expect(sentence, isNot(contains('SocketException')));
        expect(sentence, isNot(matches(RegExp(r'\b(4\d\d|5\d\d)\b'))));
      }
    }
  });

  test('a message still reads when nothing is known about the address', () {
    final text = describeProblem(ConnectionProblem.unreachable);
    expect(text.message(en), contains('that address'));
    expect(text.message(en), isNot(contains('null')));
  });
}
