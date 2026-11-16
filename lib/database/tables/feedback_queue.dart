import 'package:drift/drift.dart';

/// Reports that could not be sent (help/feedback/support spec, section 3b),
/// kept until a later launch delivers them.
///
/// In the SQLCipher database on purpose: a bug report is free text that
/// routinely names hosts, and a plaintext copy in preferences would be the
/// one place such text sat at rest outside the vault. Device-local: never in
/// the synced blob and never in a `.zest` backup. Text only; the screenshot
/// is dropped from a queued report.
@DataClassName('FeedbackQueueRow')
class FeedbackQueue extends Table {
  /// The report's nonce (uuid), so a retry deduplicates on the server.
  TextColumn get nonce => text().withLength(min: 1, max: 64)();

  /// The report as JSON (`FeedbackReport.toJson(includeScreenshot: false)`
  /// plus `createdAt`).
  TextColumn get payload => text()();

  /// Epoch milliseconds when it was queued; the oldest go first past the cap.
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {nonce};
}
