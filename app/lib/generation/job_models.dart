/// What the gateway says about a job (`docs/api.md`).
///
/// The five server states and nothing else. `uploading`, `connecting`,
/// `reconnecting` and `interrupted` are the client's own and never appear
/// here — a snapshot carrying one would be a gateway asserting something only
/// the phone can know.
///
/// One rule is enforced here rather than described: **progress is real or it
/// is absent**. [JobProgress] can only be built from two integers the gateway
/// sent, and there is no constructor that takes a fraction, a percentage or a
/// duration. A client that wanted to fabricate a ramp would have to change
/// this file to do it.
library;

import 'package:flutter/foundation.dart';

import '../l10n/app_localizations.dart';
import 'translation.dart';

/// The only states the gateway asserts (`docs/api.md`).
enum JobState {
  queued,
  running,
  completed,
  failed,
  cancelled;

  /// The gateway is still working on it.
  bool get isInFlight => this == JobState.queued || this == JobState.running;

  /// Nothing more will happen to it.
  bool get isFinished => !isInFlight;

  /// Reads a state name, or `null` for anything this build does not know.
  ///
  /// An unknown name is never guessed into `running`: a job whose state cannot
  /// be read is a job whose state we do not know.
  static JobState? tryParse(Object? value) => switch (value) {
    'queued' => JobState.queued,
    'running' => JobState.running,
    'completed' => JobState.completed,
    'failed' => JobState.failed,
    'cancelled' => JobState.cancelled,
    _ => null,
  };
}

/// Real progress, as ComfyUI reported it through the gateway.
///
/// There is exactly one way to obtain one — [tryFromJson], from two integers
/// on the wire. Absence is `null`, which the interface renders as an
/// indeterminate bar (`docs/recovery.md`).
@immutable
class JobProgress {
  const JobProgress({required this.step, required this.total});

  /// The step the gateway said it was on.
  final int step;

  /// The number of steps the gateway said there are.
  final int total;

  /// What a determinate bar draws. Clamped for drawing only; [step] and
  /// [total] stay exactly as they arrived.
  double get fraction => (step / total).clamp(0.0, 1.0);

  /// `Step 7 of 24` — the two numbers, never a percentage this app computed
  /// and never a time estimate, because neither was reported.
  ///
  /// It takes the localisations rather than holding a sentence, so the numbers
  /// keep arriving from the gateway and only the frame around them is this
  /// app's (T-0142).
  String label(L l) => l.generationProgressStep(step, total);

  /// Reads `{"step": 7, "total": 24}`.
  ///
  /// Returns `null` for anything else, including a `total` of zero: a
  /// denominator that cannot produce a fraction is not progress, and inventing
  /// one is the failure this whole file exists to prevent.
  static JobProgress? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final step = json['step'];
    final total = json['total'];
    if (step is! int || total is! int) return null;
    if (total <= 0 || step < 0) return null;
    return JobProgress(step: step, total: total);
  }

  @override
  bool operator ==(Object other) =>
      other is JobProgress && other.step == step && other.total == total;

  @override
  int get hashCode => Object.hash(step, total);
}

/// One output of a finished job.
///
/// [path] is a reference relative to the base endpoint and is resolved through
/// `Endpoint.resolvePath` wherever it is used — never concatenated
/// (`docs/transport-boundary.md` §3).
@immutable
class JobResultRef {
  const JobResultRef({
    required this.index,
    required this.kind,
    required this.mediaType,
    required this.path,
    this.width,
    this.height,
    this.durationSeconds,
  });

  final int index;

  /// `image` or `video` as the gateway named it. Anything else is carried
  /// through as text rather than forced into one of the two.
  final String kind;

  /// The `Content-Type` the bytes will arrive with.
  final String mediaType;

  /// The reference the bytes are fetched at.
  final String path;

  /// Optional and normally absent (`docs/api.md`): the app sizes media from
  /// the media itself and never guesses a dimension.
  final int? width;
  final int? height;
  final double? durationSeconds;

  bool get isImage => kind == 'image' || mediaType.startsWith('image/');
  bool get isVideo => kind == 'video' || mediaType.startsWith('video/');

  static JobResultRef? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final index = json['index'];
    final path = json['path'];
    if (index is! int || path is! String || path.trim().isEmpty) return null;
    final kind = json['kind'];
    final mediaType = json['media_type'];
    final duration = json['duration_seconds'];
    return JobResultRef(
      index: index,
      kind: kind is String ? kind : '',
      mediaType: mediaType is String ? mediaType : 'application/octet-stream',
      path: path.trim(),
      width: json['width'] is int ? json['width'] as int : null,
      height: json['height'] is int ? json['height'] as int : null,
      durationSeconds: duration is num ? duration.toDouble() : null,
    );
  }

  static List<JobResultRef> listFrom(Object? json) {
    if (json is! List) return const <JobResultRef>[];
    final results = <JobResultRef>[];
    for (final entry in json) {
      final result = JobResultRef.tryFromJson(entry);
      if (result != null) results.add(result);
    }
    return results;
  }
}

/// `GET /api/v1/jobs/{job_id}` — the authoritative job state.
///
/// This is the proof `docs/recovery.md` demands before the app claims a
/// generation is still alive. Its absence — a 404 — is an answer too, and that
/// answer is a `null` snapshot, never an optimistic guess.
@immutable
class JobSnapshot {
  const JobSnapshot({
    required this.jobId,
    required this.state,
    this.workflowId,
    this.progress,
    this.results = const <JobResultRef>[],
    this.errorMessage,
  });

  final String jobId;
  final JobState state;
  final String? workflowId;

  /// Present only when the gateway reported real numbers.
  final JobProgress? progress;

  final List<JobResultRef> results;

  /// A human sentence when the job failed. Never a stack trace (`docs/api.md`).
  final String? errorMessage;

  bool get hasResults => results.isNotEmpty;

  /// Reads a snapshot body.
  ///
  /// [fallbackJobId] is used when the body omits `job_id`, which the cancel
  /// reply is allowed to do — it is answering about a job the caller named. A
  /// body with no readable `state` is not a snapshot at all.
  static JobSnapshot? tryFromJson(Object? json, {String? fallbackJobId}) {
    if (json is! Map) return null;
    final state = JobState.tryParse(json['state']);
    if (state == null) return null;
    final id = json['job_id'];
    final jobId = id is String && id.trim().isNotEmpty
        ? id.trim()
        : fallbackJobId;
    if (jobId == null) return null;
    final workflowId = json['workflow_id'];
    return JobSnapshot(
      jobId: jobId,
      state: state,
      workflowId: workflowId is String ? workflowId : null,
      progress: JobProgress.tryFromJson(json['progress']),
      results: JobResultRef.listFrom(json['results']),
      errorMessage: readErrorMessage(json['error']),
    );
  }

  /// The user-facing sentence out of an `error` field, in either of the two
  /// shapes the contract uses: a bare string, or the `{code, message, field}`
  /// envelope.
  static String? readErrorMessage(Object? error) {
    if (error is String && error.trim().isNotEmpty) return error.trim();
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    return null;
  }

  /// The stable token out of the same envelope, or `null` for the bare-string
  /// shape and for anything without one.
  ///
  /// `docs/api.md` calls this "a stable token a client may switch on", which
  /// is exactly what the app does with it: it is the difference between
  /// showing a person a refusal in their own language and showing them the
  /// gateway's English.
  static String? readErrorCode(Object? error) {
    if (error is Map) {
      final code = error['code'];
      if (code is String && code.trim().isNotEmpty) return code.trim();
    }
    return null;
  }
}

/// `POST /api/v1/jobs` — `201 Created`, and the id recovery depends on.
@immutable
class JobSubmission {
  const JobSubmission({
    required this.jobId,
    required this.state,
    this.translation = TranslationReport.none,
  });

  final String jobId;
  final JobState state;

  /// What the gateway did to this submission's own text (`docs/api.md`).
  ///
  /// It is on the submission and nowhere else, because that is where the
  /// contract puts it: a snapshot answers about a job's state, not about the
  /// text that started it. [TranslationReport.none] — the ordinary case — is
  /// what a gateway with the stage switched off reports.
  final TranslationReport translation;

  static JobSubmission? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['job_id'];
    if (id is! String || id.trim().isEmpty) return null;
    // A gateway that answers 201 without naming a state has still created a
    // job, and `queued` is what 201 means (`docs/api.md`).
    return JobSubmission(
      jobId: id.trim(),
      state: JobState.tryParse(json['state']) ?? JobState.queued,
      translation: TranslationReport.fromJson(json['translation']),
    );
  }
}
