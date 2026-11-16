/// A single automation execution log entry.
class AutomationLogEntry {
  final String id;
  final DateTime timestamp;
  final String action; // execute, snippet, batch, connect
  final String connectionId;
  final String command;
  final String? snippetName;
  final String stdout;
  final String stderr;
  final int? exitCode;
  final bool success;
  final int elapsedMs;

  const AutomationLogEntry({
    required this.id,
    required this.timestamp,
    required this.action,
    required this.connectionId,
    required this.command,
    this.snippetName,
    required this.stdout,
    required this.stderr,
    this.exitCode,
    required this.success,
    required this.elapsedMs,
  });
}
