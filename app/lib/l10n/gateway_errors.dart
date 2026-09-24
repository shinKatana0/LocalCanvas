/// The gateway's refusals, in this app's words rather than the server's.
///
/// `docs/api.md` contracts the two halves of an error: **`code` is "a stable
/// token a client may branch on"** and `message` is what a person reads. Until
/// this file existed the app showed the `message` — which is the gateway's
/// English, drawn inside an interface that may not be in English. A Russian
/// user met an English sentence the first time an upload was refused, and no
/// amount of translating the app would have fixed it.
///
/// So the app branches on the code and writes its own sentence. What it gives
/// up by doing so is the detail the gateway put in the sentence — the size
/// limit in `file_too_large`, for one — and that is the deliberate trade:
/// a limit nobody can read is worth less than a refusal they can.
///
/// **An unknown code falls back to the server's words rather than swallowing
/// them.** A gateway newer than this app, a code this file has not caught up
/// with, an error from a route nobody anticipated — in all three the honest
/// answer is the sentence the server sent, even in the wrong language. An
/// untranslated message a person can quote to whoever runs the PC is worth
/// more than a generic one they cannot.
library;

import 'app_localizations.dart';

/// This app's own sentence for [code], or `null` for a code it does not know.
///
/// `null` is the caller's signal to fall back to the gateway's `message`.
String? gatewayErrorSentence(L l, String? code) => switch (code?.trim()) {
  'unsupported_media_type' => l.gatewayErrorUnsupportedMediaType,
  // A HEIC or HEIF photo (T-0127): the gateway knows the format, so the
  // sentence can say what to choose instead. A gateway older than this code
  // answers `unsupported_media_type` above and keeps that sentence.
  'unsupported_image_heic' => l.gatewayErrorUnsupportedImageHeic,
  'empty_upload' => l.gatewayErrorEmptyUpload,
  'invalid_filename' => l.gatewayErrorInvalidFilename,
  'file_too_large' => l.gatewayErrorFileTooLarge,
  'media_kind_mismatch' => l.gatewayErrorMediaKindMismatch,
  'workflow_not_found' => l.gatewayErrorWorkflowNotFound,
  _ => null,
};

/// Every code this app has a sentence of its own for.
///
/// Exported so a test can walk it rather than restate it, and so that a code
/// added above without a sentence, or a sentence without a code, is a
/// disagreement something can notice.
const List<String> kTranslatedGatewayErrorCodes = <String>[
  'unsupported_media_type',
  'unsupported_image_heic',
  'empty_upload',
  'invalid_filename',
  'file_too_large',
  'media_kind_mismatch',
  'workflow_not_found',
];

/// What a refusal reads as: this app's sentence for the code, the gateway's
/// own words when there is no such sentence, and a plain statement that no
/// reason came back when there are no words either.
String refusalSentence(L l, {String? code, String? serverMessage}) {
  final own = gatewayErrorSentence(l, code);
  if (own != null) return own;
  final quoted = serverMessage?.trim();
  if (quoted != null && quoted.isNotEmpty) return quoted;
  return l.serverRefusedNoReason;
}
