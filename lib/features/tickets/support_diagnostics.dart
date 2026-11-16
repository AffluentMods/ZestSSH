import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// How many of the app's last log lines "Include diagnostics" sends: all it
/// keeps (AppLogger.kKeptLines).
const int kDiagnosticsLogLines = AppLogger.kKeptLines;

/// What "Include diagnostics" sends with a report or a reply:
/// the app's version, the system, and the last lines
/// of this run's log, with host names, addresses, usernames, folders, keys and
/// passwords taken out first, as Copy details takes them out (ReportScrub).
/// Nothing is read from disk: the app keeps no log file, and these lines live
/// in memory only until it is closed.
///
/// The person sees exactly this text before it goes ("See exactly what's
/// sent"), and it goes only where they ticked the box. Support keeps it with
/// the ticket; it is never in the public post.
String supportDiagnostics(FeedbackContext context, {DateTime? now}) {
  final at = (now ?? DateTime.now()).toUtc().toIso8601String();
  final lines = <String>[
    'ZestSSH diagnostics',
    'App: ZestSSH ${context.appVersion} (${context.build})',
    'System: ${ReportScrub.scrub('${context.platform} ${context.osVersion}'.trim())}',
    'Language: ${context.locale}',
    'Plan: ${context.tier}',
    'Time: ${at.substring(0, 19)}Z',
  ];
  final log = AppLogger.recent(kDiagnosticsLogLines);
  if (log.isNotEmpty) {
    lines
      ..add('')
      ..add('Log, the last ${log.length} lines (oldest first):')
      ..addAll([for (final l in log) '  ${ReportScrub.scrub(l)}']);
  }
  lines
    ..add('')
    ..add(ErrorReport.kNotice);
  return lines.join('\n');
}

/// A diagnostics text's first line of facts, for the chip that stands for it
/// in a conversation ("v3.2.7, Windows 11"): its version and system lines.
String diagnosticsSummary(String diagnostics) {
  String? version;
  String? system;
  for (final line in diagnostics.split('\n').take(8)) {
    if (line.startsWith('App: ZestSSH ')) {
      version = line.substring('App: ZestSSH '.length).split(' ').first;
    } else if (line.startsWith('System: ')) {
      system = line.substring('System: '.length).trim();
    }
  }
  return [
    if (version != null && version.isNotEmpty) 'v$version',
    if (system != null && system.isNotEmpty) system,
  ].join(', ');
}
