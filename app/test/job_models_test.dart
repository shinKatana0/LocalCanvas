/// What the app is allowed to believe about a job (`docs/api.md`).
///
/// Most of this file is about one thing: there is no way to obtain a
/// [JobProgress] except from two integers the gateway sent. Every shape that
/// is *nearly* progress — a percentage, a fraction, a ratio out of zero, a
/// count with no total — has to come back `null`, because each of them is a
/// plausible place for a fabricated number to enter.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:localcanvas/generation/job_models.dart';

import 'support/l10n.dart';

void main() {
  group('job state', () {
    test('reads the five the gateway asserts', () {
      expect(JobState.tryParse('queued'), JobState.queued);
      expect(JobState.tryParse('running'), JobState.running);
      expect(JobState.tryParse('completed'), JobState.completed);
      expect(JobState.tryParse('failed'), JobState.failed);
      expect(JobState.tryParse('cancelled'), JobState.cancelled);
    });

    test('a client-side state is not a server state', () {
      // These belong to the phone. A gateway that sent one is not understood,
      // and an unknown state is never guessed into a running one.
      for (final name in <String>[
        'uploading',
        'connecting',
        'reconnecting',
        'interrupted',
        'canceled',
        '',
      ]) {
        expect(JobState.tryParse(name), isNull, reason: name);
      }
      expect(JobState.tryParse(null), isNull);
      expect(JobState.tryParse(3), isNull);
    });
  });

  group('progress is real or it is absent', () {
    test('two integers make progress, and keep their own numbers', () {
      final progress = JobProgress.tryFromJson(<String, Object?>{
        'step': 7,
        'total': 24,
      });

      expect(progress, isNotNull);
      expect(progress!.step, 7);
      expect(progress.total, 24);
      expect(progress.fraction, closeTo(7 / 24, 1e-9));
      expect(progress.label(en), 'Step 7 of 24');
    });

    test('everything that is not two integers is nothing at all', () {
      final notProgress = <Object?>[
        null,
        'running',
        <String, Object?>{},
        // No denominator: a step with nothing to divide by is not a fraction.
        <String, Object?>{'step': 7},
        <String, Object?>{'total': 24},
        // A denominator that cannot produce one either.
        <String, Object?>{'step': 0, 'total': 0},
        <String, Object?>{'step': 1, 'total': -4},
        <String, Object?>{'step': -1, 'total': 24},
        // A percentage is not what the contract sends, and reading one as a
        // step would invent the other half of the fraction.
        <String, Object?>{'percent': 42},
        <String, Object?>{'fraction': 0.42},
        // Text that merely looks like numbers.
        <String, Object?>{'step': '7', 'total': '24'},
        <String, Object?>{'step': 7.0, 'total': 24.0},
      ];
      for (final json in notProgress) {
        expect(JobProgress.tryFromJson(json), isNull, reason: '$json');
      }
    });

    test('a step past the total draws inside the bar and still reports itself',
        () {
      final progress = JobProgress.tryFromJson(<String, Object?>{
        'step': 30,
        'total': 24,
      })!;

      expect(progress.fraction, 1.0);
      // Clamped for drawing only; the numbers shown are the gateway's.
      expect(progress.label(en), 'Step 30 of 24');
    });
  });

  group('the snapshot', () {
    test('reads the whole document', () {
      final snapshot = JobSnapshot.tryFromJson(<String, Object?>{
        'job_id': 'j-8f21',
        'workflow_id': 'example_workflow',
        'state': 'completed',
        'progress': null,
        'results': <Object?>[
          <String, Object?>{
            'index': 0,
            'kind': 'image',
            'media_type': 'image/png',
            'path': '/api/v1/jobs/j-8f21/result/0',
          },
        ],
        'error': null,
      })!;

      expect(snapshot.jobId, 'j-8f21');
      expect(snapshot.workflowId, 'example_workflow');
      expect(snapshot.state, JobState.completed);
      expect(snapshot.progress, isNull);
      expect(snapshot.results.single.isImage, isTrue);
      expect(snapshot.errorMessage, isNull);
    });

    test('a body with no readable state is not a snapshot', () {
      expect(JobSnapshot.tryFromJson(null), isNull);
      expect(JobSnapshot.tryFromJson(<String, Object?>{'job_id': 'j-1'}), isNull);
      expect(
        JobSnapshot.tryFromJson(<String, Object?>{
          'job_id': 'j-1',
          'state': 'nearly-done',
        }),
        isNull,
      );
    });

    test('an error arrives as a sentence, in either shape the contract uses',
        () {
      final envelope = JobSnapshot.tryFromJson(<String, Object?>{
        'job_id': 'j-1',
        'state': 'failed',
        'error': <String, Object?>{
          'code': 'model_missing',
          'message': 'A model this workflow needs is missing.',
        },
      })!;
      expect(envelope.errorMessage, 'A model this workflow needs is missing.');

      final bare = JobSnapshot.tryFromJson(<String, Object?>{
        'job_id': 'j-1',
        'state': 'failed',
        'error': 'A model this workflow needs is missing.',
      })!;
      expect(bare.errorMessage, 'A model this workflow needs is missing.');
    });

    test('results that cannot be read are dropped, not half-built', () {
      final snapshot = JobSnapshot.tryFromJson(<String, Object?>{
        'job_id': 'j-1',
        'state': 'completed',
        'results': <Object?>[
          <String, Object?>{'index': 0},
          <String, Object?>{'path': '/api/v1/jobs/j-1/result/1'},
          <String, Object?>{
            'index': 2,
            'kind': 'video',
            'media_type': 'video/mp4',
            'path': '/api/v1/jobs/j-1/result/2',
          },
        ],
      })!;

      expect(snapshot.results, hasLength(1));
      expect(snapshot.results.single.isVideo, isTrue);
    });
  });

  group('the submission', () {
    test('needs an id, and takes 201 to mean queued when nothing else is said',
        () {
      final submission = JobSubmission.tryFromJson(<String, Object?>{
        'job_id': 'j-8f21',
      })!;
      expect(submission.jobId, 'j-8f21');
      expect(submission.state, JobState.queued);

      expect(JobSubmission.tryFromJson(<String, Object?>{'state': 'queued'}),
          isNull);
      expect(JobSubmission.tryFromJson(<String, Object?>{'job_id': '  '}),
          isNull);
    });
  });
}
