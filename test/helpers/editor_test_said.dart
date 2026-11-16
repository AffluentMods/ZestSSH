import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart' show connectionTestFailed;

/// What a connection test of the host editor says of [e], which it failed
/// with ([connectionTestFailed]): the sentence under "Connection failed".
String editorTestSaid(
  AppLocalizations l10n,
  Object e, {
  String? host,
  bool? onAComputer,
}) =>
    connectionTestFailed(l10n, e, host: host, onAComputer: onAComputer).message;

/// What the report behind its "Copy details" has under the error as what
/// cut the sign-in off, with whatever of it runs on to more lines. Null
/// where the report says nothing of that, and where the test has no report.
String? editorTestCutOffBy(AppLocalizations l10n, Object e) {
  final report = connectionTestFailed(l10n, e).report;
  if (report == null) return null;
  const lead = '  What cut it off: ';
  final lines = report.split('\n');
  final at = lines.indexWhere((line) => line.startsWith(lead));
  if (at == -1) return null;
  final more = lines.skip(at + 1).takeWhile((line) => line.startsWith('  '));
  return [lines[at].substring(lead.length), ...more.map((line) => line.substring(2))].join('\n');
}
