/// The rule that a filename may be shown and a reference may not
/// (`docs/ui-ux.md`), and the small amount of formatting around it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/media/media_selection.dart';

import 'support/l10n.dart';
import 'support/media_fakes.dart';

void main() {
  group('what may be called a filename', () {
    test('a name survives, whichever separator the platform used', () {
      expect(humanFilename('IMG_0142.jpg'), 'IMG_0142.jpg');
      expect(
        humanFilename('/storage/emulated/0/DCIM/Camera/IMG_0142.jpg'),
        'IMG_0142.jpg',
      );
      expect(
        humanFilename(r'C:\Users\someone\Pictures\a photo.png'),
        'a photo.png',
      );
      expect(humanFilename('  spaced.mp4  '), 'spaced.mp4');
    });

    test('a reference is refused outright, not mined for a last segment', () {
      // The tail of each of these would pass a naive basename check and none
      // of them is a name a person could act on.
      expect(humanFilename('content://media/external/images/media/1024'), null);
      expect(
        humanFilename(
          'content://com.android.providers.media.documents/document/'
          'image%3A1024',
        ),
        null,
      );
      expect(humanFilename('file:///data/user/0/app/cache/x.jpg'), null);
      expect(humanFilename('primary:Pictures'), null);
      expect(humanFilename('C:'), null);
    });

    test('a real name inside a document id is still a real name', () {
      // The contract's rule is about directories, not about colons: the tail
      // of `primary:Pictures/holiday.jpg` is the one part a person can act on,
      // and dropping it would also drop the names this exists to preserve.
      expect(humanFilename('primary:Pictures/holiday.jpg'), 'holiday.jpg');
    });

    test('nothing human left means nothing, not an empty label', () {
      expect(humanFilename(null), null);
      expect(humanFilename(''), null);
      expect(humanFilename('   '), null);
      expect(humanFilename('/storage/emulated/0/DCIM/'), null);
    });
  });

  group('what the panel is allowed to say', () {
    test('a nameless selection reads as a sentence, never as its reference',
        () {
      final selection = tempSelection(named: false);
      final path = (selection.source as dynamic).path as String;

      expect(selection.displayName(en), 'Chosen picture');
      expect(selection.displayName(en), isNot(contains(path)));
      expect(selection.displayName(en), isNot(contains('/')));
      expect(selection.displayName(en), isNot(contains(r'\')));
    });

    test('a nameless clip says clip, because that is what it is', () {
      final selection = tempSelection(kind: MediaKind.video, named: false);
      expect(selection.displayName(en), 'Chosen clip');
    });

    test('a named selection shows its name', () {
      expect(tempSelection().displayName(en), 'IMG_0142.jpg');
    });
  });

  group('size and duration, only where they are known', () {
    test('sizes read the way a gallery writes them', () {
      expect(formatByteCount(en, 0), '0 bytes');
      expect(formatByteCount(en, 999), '999 bytes');
      // One byte is a byte (T-0152).
      expect(formatByteCount(en, 1), '1 byte');
      expect(formatByteCount(en, 2), '2 bytes');
      expect(formatByteCount(en, 1000), '1.0 kB');
      expect(formatByteCount(en, 2481923), '2.5 MB');
      expect(formatByteCount(en, 48000000), '48 MB');
      expect(formatByteCount(en, 3200000000), '3.2 GB');
    });

    test('a small size agrees with its number in Russian (T-0152)', () {
      // Russian has three forms for whole numbers, and the one a number takes
      // depends on its last digit AND on whether it is in the teens - which is
      // why 11 and 21 are here, not only 1, 3 and 5.
      const Map<int, String> expected = <int, String>{
        0: '0 байт',
        1: '1 байт',
        2: '2 байта',
        3: '3 байта',
        4: '4 байта',
        5: '5 байт',
        11: '11 байт',
        12: '12 байт',
        21: '21 байт',
        22: '22 байта',
        25: '25 байт',
        999: '999 байт',
      };
      expected.forEach((count, words) {
        expect(formatByteCount(ru, count), words, reason: '$count');
      });
    });

    test('durations read as a clock', () {
      expect(formatMediaDuration(const Duration(seconds: 7)), '0:07');
      expect(formatMediaDuration(const Duration(seconds: 64)), '1:04');
      expect(
        formatMediaDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03',
      );
    });

    test('an unknown duration leaves no gap behind it', () {
      final clip = tempSelection(kind: MediaKind.video, bytes: 2481923);
      expect(clip.detailLine(en), '2.5 MB');

      final timed = tempSelection(
        kind: MediaKind.video,
        bytes: 2481923,
        duration: const Duration(seconds: 7),
      );
      expect(timed.detailLine(en), '0:07 · 2.5 MB');
    });

    test('nothing known at all is an empty line, not a row of dashes', () {
      final selection = tempSelection(knownSize: false);
      expect(selection.detailLine(en), isEmpty);
    });
  });
}
