import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/features/triggers/trigger_pattern_check.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart' show WorkflowStep;
import 'package:zestssh/providers/terminal_providers.dart'
    show UnattendedSignInStopped, connectionFailureText, hostEndedText, noCommandReason, reachedByAllHosts;
import 'package:zestssh/services/command_output.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/providers/snippet_providers.dart'
    show
        ParsedVariable,
        VariableType,
        defaultSeedValues,
        kMaskedValueShown,
        parseVariablesWithOptions,
        variablesStillToFill;
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/error_translator.dart' show ConnectionError, ConnectionErrorType;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/shell_fill.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/identity_secret_store.dart';

class AutomationResult {
  final bool success;
  final String output;
  final String error;
  final int? exitCode;
  final Duration elapsed;

  /// True when this run was BLOCKED because it was an unattended (headless)
  /// run against a credential the user has not opted in to unattended use.
  /// Distinguishes "the credential is walled off" from an ordinary failure so
  /// the UI can show the amber "Needs credentials" outcome instead of red
  /// "Failed", and so the run is recorded rather than silently dropped.
  final bool needsCredentials;

  /// True when the snippet it was asked to run is not among the snippets
  /// (deleted or renamed): nothing ran. A workflow stops at such a step,
  /// whatever its step is set to do when it fails.
  final bool snippetMissing;

  /// True when the snippet has a variable the app would ask a person for and
  /// was given no value: nothing ran, and a workflow stops at such a step, for
  /// `rm -rf ${DIR}/*` with DIR blank is a command nobody wrote.
  final bool variablesMissing;

  const AutomationResult({
    required this.success,
    required this.output,
    required this.error,
    this.exitCode,
    required this.elapsed,
    this.needsCredentials = false,
    this.snippetMissing = false,
    this.variablesMissing = false,
  });

  @override
  String toString() =>
      'AutomationResult(success=$success, exitCode=$exitCode, '
      'elapsed=${elapsed.inMilliseconds}ms, '
      'output=${output.length} chars, error=${error.length} chars'
      '${needsCredentials ? ', needsCredentials' : ''})';
}

/// How a command that a task ran came out, from how it ended: its exit
/// status ([exitCode]), the signal that ended it ([signal], as the host
/// named it), what ended its connection under it ([cutOffBy]: null for a
/// command whose session the host closed in order), or that it had not
/// ended when the time allowed for it was up ([stillRunning]).
///
/// With an exit status, the status says. With none, the command is no
/// success where a signal ended it, its connection ended under it, or it
/// had not ended in time: the error text says which, behind what the
/// command printed as errors. A host that reports no status for a command
/// that ended, while its connection stands (there are devices that never
/// do), is taken at its word that the command ran, as it always was.
///
/// (A command with no exit status counted as one that succeeded whatever
/// had happened to it: a task whose connection dropped half way, whose
/// command was killed, or whose command was still running, was recorded as
/// done.)
AutomationResult commandResult(
  AppLocalizations l10n, {
  required String stdout,
  required String stderr,
  required int? exitCode,
  required String? signal,
  required Object? cutOffBy,
  bool stillRunning = false,
  required Duration elapsed,
}) {
  final cutShort = exitCode != null
      ? null
      : signal != null
          ? l10n.automationSvcEndedBySignal(shownHostText(signal))
          : cutOffBy != null
              ? l10n.automationSvcConnectionEnded
              : stillRunning
                  ? l10n.automationSvcStillRunning
                  : null;
  // Why the connection ended, where the host said.
  final why = cutOffBy == null ? null : hostEndedText(l10n, cutOffBy);
  return AutomationResult(
    success: exitCode == 0 || (exitCode == null && cutShort == null),
    output: stdout,
    error: cutShort == null
        ? stderr
        : [if (stderr.trim().isNotEmpty) stderr.trimRight(), cutShort, ?why].join('\n'),
    exitCode: exitCode,
    elapsed: elapsed,
  );
}

/// How far a command that is run with nobody watching had come: what its
/// time was up at, where it was up.
enum TaskStage { connecting, signingIn, starting, running }

/// What is said of a command whose time was up before it had started
/// ([stage] is not [TaskStage.running]): which of the three it was still
/// at, and how long it was [allowed]. (It said "Timeout:" and what this
/// code calls the step, in English: "Authentication timed out".)
String timeUpBeforeItRan(AppLocalizations l10n, TaskStage stage, Duration allowed) {
  final time = l10n.autoWizTimeoutSeconds(allowed.inSeconds);
  return switch (stage) {
    TaskStage.connecting => l10n.automationSvcTimedOutConnecting(time),
    TaskStage.signingIn => l10n.automationSvcTimedOutSigningIn(time),
    _ => l10n.automationSvcTimedOutStarting(time),
  };
}

/// What is said of a command that could not be run because the connection
/// to its host could not be made, or the sign-in failed: what a session that
/// failed the same way is told, of this host. Where that is no more than
/// that something unexpected happened, what was thrown stands under it. (It
/// was what was thrown and nothing else: "SocketException: ... errno =
/// 1225", "SSHAuthFailError(All authentication methods failed)".)
String couldNotRunText(Object e, {required String host, required int port, String? username}) {
  final said = ConnectionError.translate(connectionFailureText(e), host: host, port: port, username: username);
  return switch (said.type) {
    ConnectionErrorType.unknown || ConnectionErrorType.sshProtocol => '${said.description}\n$e',
    _ => said.description,
  };
}

/// How far a task's command had come, for what is said where its time is up
/// first ([AutomationService._timeUp]).
class _TaskProgress {
  TaskStage stage = TaskStage.connecting;

  /// What the command has printed so far, from the moment it runs.
  CommandOutput? printed;
  CommandOutput? printedAsErrors;
}

/// Signs in to a saved host for a task as a session to it is signed in to
/// (ActiveSessionsNotifier.openRunClient): where the device is on a network,
/// as that network has the host (its address, port, key and jump hosts
/// there); through the jump hosts on the way; with its key's certificate;
/// and with the host's key checked against the known hosts of its own
/// space. A run with nobody there ([unattended]) signs in only with keys
/// allowed for unattended runs, and asks nobody anything: what it would ask
/// stops it ([UnattendedSignInStopped]). [onLog] hears how far it has come.
typedef TaskSignIn = Future<SshService> Function(Connection connection,
    {required bool unattended, ConnectionLogCallback? onLog});

/// Thrown by credential resolution when a headless/unattended run targets an
/// identity that has NOT been opted in to unattended use. Caught at the
/// command boundary and converted into an [AutomationResult] with
/// [AutomationResult.needsCredentials] set - the run is refused, recorded, and
/// never silently downgraded to another auth path.
class UnattendedBlockedException implements Exception, HasTypeName {
  const UnattendedBlockedException(this.identityId, this.identityLabel);

  final String identityId;
  final String identityLabel;

  @override
  String toString() =>
      'UnattendedBlockedException(identity "$identityLabel" not enabled for '
      'unattended runs)';

  @override
  String get typeName => 'UnattendedBlockedException';
}

/// Headless SSH command execution service.
///
/// Connects to a remote host, runs a single command via `SSHClient.execute()`,
/// captures stdout/stderr, and disconnects. Designed for automation flows
/// (deep links, snippets, scheduled tasks) where no PTY is needed.
/// [template] (a snippet's command) with each placeholder that [variables]
/// gives a value for replaced by that value, written as the place it lands in
/// takes it ([fillPlaceholders]), in one pass over the template. What runs from
/// a snippet is [snippetCommandToRun], which fills it with this.
///
/// Both forms a snippet is written with: `{{name}}`, as automation always
/// took, and the forms the rest of the app writes and fills
/// (resolveVariables, lib/providers/snippet_providers.dart): `${NAME}`,
/// `${NAME:-default}`, `${NAME:secret}` by the name, and the lists `$[a,b]`
/// and `${[a,b]}` by `[a,b]`. A workflow's snippet step asks for a value of
/// each `${NAME}` and saved it, and only `{{name}}` was filled, so the step
/// ran its snippet with the placeholders in it (found while checking the
/// 3.0 docs). A placeholder with no value is left as it is.
String withSnippetVariables(String template, Map<String, String> variables) =>
    fillPlaceholders(template, variables, doubleBraces: true);

/// What [template] is filled with, given [values]: each variable's default, at
/// every occurrence of it, and over it each value that is not blank (a step keeps
/// a blank for a field nobody filled in).
Map<String, String> _snippetFill(String template, Map<String, String>? values) => {
      ...defaultSeedValues(template),
      for (final e in (values ?? const <String, String>{}).entries)
        if (e.value.trim().isNotEmpty) e.key: e.value,
    };

/// The text that runs from a snippet's [template] and the [values] it has, the
/// one function that makes it: what a run sends (a link's, another app's, a
/// schedule's, a workflow step's), what a person's question checks, and what a
/// link's question shows. Every occurrence of a variable with a default takes the
/// default, as a run in a terminal does. They were two: the question checked
/// `mkdir -p '/tmp/a'; rm -rf '/tmp/a'/*`, the run sent the snippet as written,
/// `${DIR:-/tmp/a}` assigned nothing, and the shell ran `rm -rf /*` (found in an
/// independent review).
String snippetCommandToRun(String template, Map<String, String>? values) =>
    withSnippetVariables(template, _snippetFill(template, values));

/// [snippetCommandToRun] as a question shows it: the masked values out of sight.
String snippetCommandShown(String template, Map<String, String>? values) => withSnippetVariables(template, {
      ..._snippetFill(template, values),
      for (final v in parseVariablesWithOptions(template))
        if (v.secret && (values?[v.key] ?? '').trim().isNotEmpty) v.key: kMaskedValueShown,
    });

/// The variables a run of [template] with [values] needs a value for, in the
/// order they come: where someone can be asked (a person's run of a workflow,
/// workflowReadyToRun) they are asked for, and with nobody to ask nothing runs
/// ([AutomationService.runSnippet]), so both come to the same.
///
/// A value given blank (a field nobody filled in), and a list or a secret with
/// none, which only the app can fill. A plain `${NAME}` never given goes to the
/// shell as written (`${HOME}` is each host's own), and so does a blank default,
/// unless the command is a dangerous one with it empty: `rm -rf ${DIR}/*` must
/// never reach a shell with DIR blank. One with a default that is not blank takes
/// it.
List<ParsedVariable> snippetVariablesToAsk(String template, Map<String, String>? values) {
  final noValue = {for (final v in variablesStillToFill(template, values)) v.key};
  bool mayStayEmpty(ParsedVariable v) =>
      (v.hasDefault && v.defaultValue!.trim().isEmpty && (values?[v.key] ?? '').trim().isEmpty) ||
      (noValue.contains(v.key) && values?[v.key] == null && v.type == VariableType.freeText && !v.secret);
  final parsed = parseVariablesWithOptions(template);
  final maybe = [for (final v in parsed) if (mayStayEmpty(v)) v];
  final emptyIsDangerous = maybe.isNotEmpty &&
      DangerousCommandService.checkFilled(withSnippetVariables(template, {
        ..._snippetFill(template, values),
        for (final v in maybe) v.key: '',
      })).isNotEmpty;
  return [
    for (final v in parsed)
      if (mayStayEmpty(v) ? emptyIsDangerous : noValue.contains(v.key)) v,
  ];
}

class AutomationService {
  /// Apply optional output filters to command result.
  ///
  /// Filters are applied in order: grep -> head -> tail.
  /// - [grepPattern]: keep only lines matching this pattern (case-insensitive).
  /// - [head]: take only the first N lines after grep.
  /// - [tail]: take only the last N lines after head.
  static String applyOutputFilters(
    String output, {
    String? grepPattern,
    int? head,
    int? tail,
  }) {
    if (grepPattern == null && head == null && tail == null) return output;

    var lines = output.split('\n');

    // 1. Grep: filter to lines matching the pattern (case-insensitive).
    //
    // Security: reject patterns that are too long (potential ReDoS) and
    // fall back to literal matching if the pattern is invalid regex.
    if (grepPattern != null && grepPattern.isNotEmpty) {
      // As plain text, where it is not run as a regular expression.
      List<String> literally() {
        final lower = grepPattern.toLowerCase();
        return lines.where((line) => line.toLowerCase().contains(lower)).toList();
      }

      // Dart's RegExp backtracks on this isolate, the one the screen and
      // every session share, and nothing can stop it once it runs: `(a+)+$`
      // on forty a's and a b holds the app for good. The pattern comes with
      // an automation request, so it is read first as the alerts' patterns
      // are (checkTriggerPattern, which works out from the pattern's shape
      // what it can cost), and one that could cost too much, or that the
      // reader cannot tell, is searched for as plain text. A rule of thumb
      // stood here before (a repeat inside a repeat), which `(a|aa)+$` and
      // the like passed (found in two security audits).
      // A line is matched as an alert's is: its
      // first [kTriggerMaxLineChars] characters at most.
      final check = grepPattern.length > 256
          ? TriggerPatternCheck.refusedOne
          : checkTriggerPattern(grepPattern, ignoreCase: true);
      RegExp? regex;
      if (!check.refused) {
        try {
          regex = RegExp(grepPattern, caseSensitive: false);
        } on FormatException {
          // Not a regular expression: plain text.
        }
      }
      final pattern = regex;
      lines = pattern == null ? literally() : lines.where((line) => pattern.hasMatch(check.bound(line))).toList();
    }

    // 2. Head: take only the first N lines
    if (head != null && head > 0 && lines.length > head) {
      lines = lines.sublist(0, head);
    }

    // 3. Tail: take only the last N lines
    if (tail != null && tail > 0 && lines.length > tail) {
      lines = lines.sublist(lines.length - tail);
    }

    return lines.join('\n');
  }

  /// [uri] as the log names it: its scheme and its host, never its path or
  /// its query, where a webhook's secret is (a chat service's hook carries its
  /// token there). The log kept the whole address, and a failure's error
  /// with it, and the log's last lines go into what Copy details copies
  /// (found in a security review of the client).
  @visibleForTesting
  static String webhookNamed(Uri? uri) =>
      uri == null || uri.host.isEmpty ? '(no address)' : '${uri.scheme}://${uri.host}';

  /// Send automation result to a webhook URL (fire-and-forget).
  ///
  /// Validates that [webhookUrl] uses HTTPS, then POSTs a JSON body with
  /// connection, command, stdout, stderr, exit_code, elapsed_ms, and timestamp.
  /// Does not block on the response -- failures are logged but never thrown.
  static Future<void> sendWebhook({
    required String webhookUrl,
    required String connection,
    required String command,
    required AutomationResult result,
  }) async {
    // Validate URL scheme
    final uri = Uri.tryParse(webhookUrl);
    if (uri == null || uri.scheme != 'https') {
      AppLogger.warning('Webhook skipped: URL must use https:// (got: ${webhookNamed(uri)})');
      return;
    }

    // SSRF guard: refuse literal internal targets so a webhook (which POSTs
    // command stdout/stderr) can't be pointed at loopback, RFC-1918 private
    // ranges, link-local, or the cloud metadata address (169.254.169.254).
    // Note: hostnames are not resolved here (avoids DNS-rebinding TOCTOU and
    // latency) - the common exploit uses a literal IP, which this blocks.
    if (isBlockedWebhookHost(uri.host)) {
      AppLogger.warning(
          'Webhook skipped: destination host is a private/loopback/'
          'link-local address (SSRF guard): ${uri.host}');
      return;
    }

    final body = jsonEncode({
      'connection': connection,
      'command': command,
      'stdout': result.output,
      'stderr': result.error,
      'exit_code': result.exitCode,
      'elapsed_ms': result.elapsed.inMilliseconds,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    // Fire and forget -- don't await the caller.
    //
    // SSRF hardening: disable redirect following. The host check above only
    // validates the ORIGINAL target; a public webhook endpoint could otherwise
    // reply 302 → http://169.254.169.254/… (or a private host) and the client
    // would happily follow, POSTing command stdout there and defeating the
    // guard. With followRedirects=false a 3xx is treated as a failure and the
    // validated origin is the only host we ever contact.
    final request = http.Request('POST', uri)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..body = body;
    final client = http.Client();
    unawaited(
      client.send(request).then((streamed) async {
        if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
          AppLogger.warning('Webhook redirect refused (${webhookNamed(uri)} → '
              '${webhookNamed(Uri.tryParse(streamed.headers['location'] ?? ''))}); not following to an '
              'unvalidated host');
        } else {
          AppLogger.info('Webhook sent to ${webhookNamed(uri)} (status=${streamed.statusCode})');
        }
        // Drain the body so the underlying socket is released.
        await streamed.stream.drain<void>();
      }).catchError((Object e) {
        AppLogger.warning('Webhook to ${webhookNamed(uri)} failed: ${errorKind(e)}');
      }).whenComplete(client.close),
    );
  }

  /// True if [host] is a literal IP in a loopback / private / link-local /
  /// metadata range (or an obvious localhost name) that a webhook must never
  /// target. Non-literal hostnames return false (not resolved here).
  ///
  /// Exposed for testing. Callers pass `Uri.host`, which strips the brackets
  /// from IPv6 literals (`[::1]` -> `::1`) before this classifier sees them.
  @visibleForTesting
  static bool isBlockedWebhookHost(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h.endsWith('.localhost')) return true;
    final addr = InternetAddress.tryParse(host);
    if (addr == null) {
      // Not a CANONICAL IP literal - but the OS resolver still accepts legacy
      // IP-in-disguise forms that tryParse does not: decimal (2130706433), hex
      // (0x7f000001), octal (0300.0.0.1) and short-form (127.1) all reach
      // 127.0.0.1 / internal hosts / the metadata endpoint and would otherwise
      // sail past this guard (SSRF exfiltration of SSH output). A real hostname's
      // rightmost label is alphabetic; an IP-obfuscation form's is numeric/hex,
      // so fail closed on those and trust only plain DNS-ish names.
      if (_looksLikeNumericIpForm(h)) return true;
      return false; // a genuine hostname (resolved by the caller)
    }
    if (addr.isLoopback || addr.isLinkLocal || addr.isMulticast) return true;
    final raw = addr.rawAddress;
    if (addr.type == InternetAddressType.IPv4 && raw.length == 4) {
      if (_isPrivateV4Octets(raw[0], raw[1])) return true;
    } else if (addr.type == InternetAddressType.IPv6 && raw.length == 16) {
      final b0 = raw[0];
      if ((b0 & 0xfe) == 0xfc) return true; // fc00::/7 unique-local
      if (b0 == 0xfe && (raw[1] & 0xc0) == 0x80) return true; // fe80::/10
      // IPv4-mapped ::ffff:a.b.c.d - re-check the embedded v4 address via the
      // SAME classifier so the two paths can never drift (was missing the
      // CGNAT check).
      final mapped = raw.take(10).every((x) => x == 0) &&
          raw[10] == 0xff &&
          raw[11] == 0xff;
      if (mapped && _isPrivateV4Octets(raw[12], raw[13])) return true;
    }
    return false;
  }

  /// True when [host] looks like a NON-canonical IP literal (an IP in disguise)
  /// rather than a real DNS hostname: a hex form (`0x7f000001`), or any form
  /// whose rightmost dot-label is all-digits (`2130706433`, `127.1`,
  /// `0300.0.0.1`). Real hostnames end in an alphabetic TLD, so these are never
  /// legitimate webhook targets - the OS resolver would turn them into internal
  /// addresses. Called only after `InternetAddress.tryParse` has already
  /// rejected the host as a CANONICAL literal, so real public IPs are unaffected.
  static bool _looksLikeNumericIpForm(String host) {
    if (host.isEmpty) return true;
    if (host.contains('0x')) return true; // hex form
    final labels = host.split('.');
    final last = labels.isEmpty ? host : labels.last;
    return last.isNotEmpty && RegExp(r'^[0-9]+$').hasMatch(last);
  }

  /// The IPv4 private/reserved-range test, shared by the literal-IPv4 and the
  /// IPv4-mapped-IPv6 paths of [isBlockedWebhookHost].
  static bool _isPrivateV4Octets(int a, int b) {
    if (a == 0 || a == 10 || a == 127) return true; // this-net/private/loopback
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 169 && b == 254) return true; // 169.254.0.0/16 (metadata)
    if (a == 100 && b >= 64 && b <= 127) return true; // 100.64.0.0/10 CGNAT
    return false;
  }

  /// Max connections a single batch may target, and max SSH connections in
  /// flight at once within that batch.
  static const int _maxBatchConnections = 25;
  static const int _maxBatchConcurrency = 4;

  /// Max bytes buffered from a single stdout/stderr stream. A hostile or
  /// misbehaving server could otherwise stream unbounded output and OOM the
  /// app during a headless automation run.
  static const int _maxCollectedBytes = 1024 * 1024; // 1 MiB

  final AppDatabase _db;
  final FlutterSecureStorage _secureStorage;
  final List<SSHClient> _activeClients = [];
  final List<SshService> _signedIn = [];
  bool _disposed = false;

  /// How a saved host is signed in to ([TaskSignIn]): as a session to it is,
  /// in the app. Without it (tests of what a task does with a connection it
  /// was given) the host is dialled at the address it is saved with.
  final TaskSignIn? _signIn;

  AutomationService(this._db, this._secureStorage, {TaskSignIn? signIn}) : _signIn = signIn;

  /// The unattended-runs gate decision - the single source of the
  /// security-critical rule, so it stays unit-testable without a DB/SSH and is
  /// reused wherever a headless path resolves a credential. A headless run is
  /// blocked iff it targets an identity NOT opted in to unattended runs;
  /// interactive runs ([unattended] == false) are never blocked. Called by
  /// [_loadCredentials] here and by the automation provider's `open`-action
  /// handler (which uses the interactive session path and must gate explicitly).
  static bool unattendedBlocked({
    required bool unattended,
    required bool allowUnattended,
  }) =>
      unattended && !allowUnattended;

  /// Execute a command on a saved connection by ID or label.
  ///
  /// [unattended] MUST be `true` for any run that fires with no user present -
  /// scheduled workflows, `zestssh://` deep links, external intents, API-key
  /// automation. When true, the target identity's credential is only used if
  /// the user has opted that identity in to unattended runs; otherwise the run
  /// is refused with [AutomationResult.needsCredentials]. Interactive runs (the
  /// user clicked Run) and internal callers like the agentless monitor leave it
  /// at the default `false` and are never gated.
  Future<AutomationResult> executeCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async {
    _assertNotDisposed();

    final resolvedId = await resolveConnectionId(connectionId);
    if (resolvedId == null) {
      return AutomationResult(
        success: false,
        output: '',
        error: 'Connection not found: $connectionId',
        elapsed: Duration.zero,
      );
    }

    final connection = await _db.connectionsDao.getById(resolvedId);
    if (connection == null) {
      return AutomationResult(
        success: false,
        output: '',
        error: 'Connection not found: $resolvedId',
        elapsed: Duration.zero,
      );
    }

    // A host that cannot run a command (SFTP only, whose server refuses one;
    // one with no SSH to run it over): said, whatever a saved step says, and
    // nothing signs in to it.
    final cannot = noCommandReason(connection, gl10n);
    if (cannot != null) {
      return AutomationResult(success: false, output: '', error: cannot, elapsed: Duration.zero);
    }

    // Signed in to as a session to it is (3.0).
    final signIn = _signIn;
    if (signIn != null) {
      return _runSignedIn(connection, signIn, command: command, timeout: timeout, unattended: unattended);
    }

    final ({
      String username,
      String? password,
      List<SSHKeyPair>? keyPairs,
      String? passphrase,
    }) credentials;
    try {
      credentials =
          await _loadCredentials(connection.identityId, unattended: unattended);
    } on UnattendedBlockedException catch (e) {
      AppLogger.warning(
          'Automation: BLOCKED unattended run on "$connectionId" - identity '
          '${e.identityId} is not opted in to unattended runs');
      return AutomationResult(
        success: false,
        output: '',
        error: gl10n.automationSvcUnattendedNotEnabled(e.identityLabel),
        elapsed: Duration.zero,
        needsCredentials: true,
      );
    }

    return _execute(
      host: connection.host,
      port: connection.port,
      username: credentials.username,
      password: credentials.password,
      keyPairs: credentials.keyPairs,
      passphrase: credentials.passphrase,
      command: command,
      timeout: timeout,
      compatibilityMode: connection.compatibilityMode,
    );
  }

  /// Execute a command by explicit host/user/port (no saved connection needed).
  Future<AutomationResult> executeOnHost({
    required String host,
    required String username,
    int port = 22,
    String? password,
    required String command,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    _assertNotDisposed();

    return _execute(
      host: host,
      port: port,
      username: username,
      password: password,
      command: command,
      timeout: timeout,
    );
  }

  /// The hosts a workflow's [step] runs on now: all of them or a group's (those
  /// [reachedByAllHosts] says it reaches), or those it names, the one host
  /// where it names one, in the order it names them and without one deleted
  /// since. (One it names that cannot run a command stays, to say why when its
  /// turn comes: [executeCommand].)
  Future<List<Connection>> hostsOfStep(WorkflowStep step) async {
    _assertNotDisposed();
    final all = await _db.connectionsDao.getAll();
    if (step.targetAll) return [for (final c in all) if (reachedByAllHosts(c.protocol)) c];
    if (step.targetGroupId != null) {
      return [for (final c in all) if (c.groupId == step.targetGroupId && reachedByAllHosts(c.protocol)) c];
    }
    final byId = {for (final c in all) c.id: c};
    return [
      for (final id in step.targetIds.isNotEmpty ? step.targetIds : [?step.connectionId]) ?byId[id],
    ];
  }

  /// The snippet a task named [name] runs (upper and lower case alike), or null.
  Future<Snippet?> snippetNamed(String name) async {
    _assertNotDisposed();
    final lower = name.toLowerCase();
    for (final s in await _db.snippetsDao.getAll()) {
      if (s.label.toLowerCase() == lower) return s;
    }
    return null;
  }

  /// Run a saved snippet by name on a connection.
  ///
  /// What it sends is [snippetCommandToRun], and it refuses what
  /// [snippetVariablesToAsk] says needs a value. This enables external apps
  /// (Tasker, Shortcuts) to pass dynamic values into snippet templates.
  Future<AutomationResult> runSnippet({
    required String connectionId,
    required String snippetName,
    Map<String, String>? variables,
    Duration timeout = const Duration(seconds: 30),
    bool unattended = false,
  }) async {
    _assertNotDisposed();

    final snippet = await snippetNamed(snippetName);

    if (snippet == null) {
      // Said in the person's language, naming the snippet: it shows in
      // Automation history and in a workflow's run.
      return AutomationResult(
        success: false,
        output: '',
        error: gl10n.automationSnippetMissing(snippetName),
        elapsed: Duration.zero,
        snippetMissing: true,
      );
    }

    // A variable that needs a value and has none. A person's run asked before it
    // started (workflowReadyToRun, by the same rule). With nobody to ask, nothing
    // runs, and it says which.
    final unfilled = {
      for (final v in snippetVariablesToAsk(snippet.command, variables)) v.name,
      // `{{name}}`, automation's own form, given a blank value. (With none it
      // stays as written, which may be what the command means: a template of
      // another tool's.)
      for (final m in RegExp(r'\{\{(\w+)\}\}').allMatches(snippet.command))
        if (variables?[m[1]]?.trim().isEmpty ?? false) m[1]!,
    };
    if (unfilled.isNotEmpty) {
      return AutomationResult(
        success: false,
        output: '',
        error: gl10n.automationSnippetNeedsValue(snippet.label, unfilled.join(', ')),
        elapsed: Duration.zero,
        variablesMissing: true,
      );
    }

    // SECURITY: variables come from intent extras / deep-link query
    // params / cloud-synced automation state. None of those sources
    // are trusted to be benign. Every value MUST be written as the place
    // it lands in takes it - otherwise a value like `foo; rm -rf ~` is a
    // working shell-injection primitive that can run anything as the SSH
    // user - and the template is walked exactly once, so a substituted value
    // is never re-scanned for further placeholders ([fillPlaceholders], which
    // the snippet UI fills with as well, so the rules stay consistent).
    final command = snippetCommandToRun(snippet.command, variables);
    if (variables != null && variables.isNotEmpty) {
      AppLogger.info('Automation: running snippet "${snippet.label}" '
          'on connection $connectionId with ${variables.length} variable(s)');
    } else {
      AppLogger.info('Automation: running snippet "${snippet.label}" '
          'on connection $connectionId');
    }

    return executeCommand(
      connectionId: connectionId,
      command: command,
      timeout: timeout,
      unattended: unattended,
    );
  }

  /// Execute the same command on multiple connections.
  ///
  /// If [parallel] is true (default), all connections are executed concurrently
  /// via [Future.wait]. If false, they run sequentially in list order.
  /// Returns a map of connection ID/label to its [AutomationResult].
  Future<Map<String, AutomationResult>> executeBatch({
    required List<String> connectionIds,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    bool parallel = true,
    bool unattended = false,
  }) async {
    _assertNotDisposed();

    if (connectionIds.isEmpty) {
      return {};
    }

    // SECURITY: cap the batch size so a hostile/buggy intent can't fan out to
    // an unbounded number of connections at once.
    if (connectionIds.length > _maxBatchConnections) {
      AppLogger.warning('Automation: batch truncated from '
          '${connectionIds.length} to $_maxBatchConnections connections');
      connectionIds = connectionIds.sublist(0, _maxBatchConnections);
    }

    // SECURITY: never log the resolved command. By this point any {{VAR}}
    // placeholders (including secret/password values) are already substituted,
    // and the automation layer carries no secret metadata to redact them
    // selectively, so logging the interpolated text would leak credentials to
    // the app log. Log only its size + the batch shape.
    AppLogger.info('Automation: batch execute (${command.length} chars) on '
        '${connectionIds.length} connections (parallel=$parallel)');

    if (parallel) {
      // Bound in-flight SSH connections with a small worker pool rather than
      // launching every future at once - Future.wait over N hosts would open N
      // simultaneous TCP+SSH handshakes and could exhaust sockets/memory.
      final results = <String, AutomationResult>{};
      final queue = List<String>.from(connectionIds);
      final workerCount =
          queue.length < _maxBatchConcurrency ? queue.length : _maxBatchConcurrency;
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          final id = queue.removeAt(0);
          results[id] = await executeCommand(
            connectionId: id,
            command: command,
            timeout: timeout,
            unattended: unattended,
          );
        }
      }

      await Future.wait(List.generate(workerCount, (_) => worker()));
      return results;
    } else {
      final results = <String, AutomationResult>{};
      for (final id in connectionIds) {
        results[id] = await executeCommand(
          connectionId: id,
          command: command,
          timeout: timeout,
          unattended: unattended,
        );
      }
      return results;
    }
  }

  /// Resolve a connection by label (case-insensitive partial match) or ID.
  ///
  /// Returns the connection ID, or null if no match is found.
  /// Exact ID match takes priority, then exact case-insensitive label match.
  ///
  /// SECURITY: automation deliberately does NOT fall back to substring/partial
  /// matching. A partial match (query "prod" resolving to "prod-staging")
  /// would silently run a command on the WRONG host. Fuzzy matching is fine
  /// for interactive search, but automation must be exact-or-nothing.
  Future<String?> resolveConnectionId(String labelOrId) async {
    // Try exact ID match first
    final byId = await _db.connectionsDao.getById(labelOrId);
    if (byId != null) return byId.id;

    final all = await _db.connectionsDao.getAll();
    final normalizedQuery = labelOrId.toLowerCase();

    // Exact label match only
    for (final conn in all) {
      if (conn.label.toLowerCase() == normalizedQuery) return conn.id;
    }

    return null;
  }

  void dispose() {
    _disposed = true;
    for (final client in _activeClients) {
      try {
        client.close();
      } catch (_) {}
    }
    _activeClients.clear();
    for (final ssh in _signedIn) {
      unawaited(ssh.disconnect());
    }
    _signedIn.clear();
    AppLogger.info('AutomationService disposed');
  }

  // ── Private ────────────────────────────────────────────────────

  void _assertNotDisposed() {
    if (_disposed) throw StateError('AutomationService has been disposed');
  }

  /// One command on one host, as a task runs it, with the connection
  /// already made ([socket]): for the tests, which have no saved host to
  /// name and need a connection of their own making.
  @visibleForTesting
  Future<AutomationResult> debugExecute({
    required String host,
    required int port,
    required String username,
    List<SSHKeyPair>? keyPairs,
    required String command,
    Duration timeout = const Duration(seconds: 30),
    SSHSocket? socket,
  }) =>
      _execute(
        host: host,
        port: port,
        username: username,
        keyPairs: keyPairs,
        command: command,
        timeout: timeout,
        socket: socket,
      );

  Future<AutomationResult> _execute({
    required String host,
    required int port,
    required String username,
    String? password,
    List<SSHKeyPair>? keyPairs,
    String? passphrase,
    required String command,
    required Duration timeout,
    SSHSocket? socket,
    bool compatibilityMode = false,
  }) async {
    final stopwatch = Stopwatch()..start();
    final progress = _TaskProgress();
    SSHClient? client;
    // The host's key, where it was the reason nothing was run.
    HostKeyVerifyResult? keyRefused;

    try {
      AppLogger.info('Automation: connecting to $username@$host:$port');

      socket ??= await SSHSocket.connect(host, port,
              timeout: const Duration(seconds: 15))
          .timeout(timeout, onTimeout: () {
        throw TimeoutException('TCP connect timed out', timeout);
      });

      client = SSHClient(
        socket,
        username: username,
        identities: keyPairs ?? [],
        // What a session to the same host offers: with Compatibility mode on
        // for the host, also what an old server needs. (A task offered what
        // a host without the mode is offered, whatever the host was set to:
        // it failed at the key exchange where a session connects.)
        algorithms: SshService.buildAlgorithms(compatibility: compatibilityMode),
        onPasswordRequest: password != null ? () => password : null,
        // SECURITY: nobody is here to answer a 2FA code, so the shared
        // answerer gives the stored password only to a genuine password
        // prompt (once) and fails every other prompt closed (empty).
        onUserInfoRequest: KeyboardInteractiveAnswerer(password: password)
            .handler,
        onVerifyHostKey: (String type, Uint8List fingerprint) async {
          final key = await _verifyHostKey(host, port, type, fingerprint);
          if (key != HostKeyVerifyResult.trusted) keyRefused = key;
          return key == HostKeyVerifyResult.trusted;
        },
        keepAliveInterval: const Duration(seconds: 15),
      );
      _activeClients.add(client);
      progress.stage = TaskStage.signingIn;

      final remaining = timeout - stopwatch.elapsed;
      if (remaining.isNegative) {
        throw TimeoutException('Timed out before authentication', timeout);
      }

      await client.authenticated.timeout(remaining, onTimeout: () {
        throw TimeoutException('Authentication timed out', timeout);
      });

      AppLogger.info('Automation: authenticated, executing command');
      return await _runOn(client, command, timeout, () => timeout - stopwatch.elapsed, progress, stopwatch);
    } on TimeoutException catch (e) {
      stopwatch.stop();
      AppLogger.warning('Automation: timeout - ${e.message}');
      return _timeUp(progress, timeout, stopwatch);
    } catch (e, stack) {
      stopwatch.stop();
      AppLogger.error('Automation: execution failed', e, stack);
      return AutomationResult(
        success: false,
        output: '',
        // A key of the host that was not accepted is said as that, with what
        // to do: the library's "host key verification failed" says neither
        // which of the two it was nor that the host has to be connected to
        // once by hand.
        error: switch (keyRefused) {
          HostKeyVerifyResult.newHost => gl10n.automationSvcHostKeyUnknown,
          HostKeyVerifyResult.changed => gl10n.automationSvcHostKeyChanged,
          _ => couldNotRunText(e, host: host, port: port, username: username),
        },
        elapsed: stopwatch.elapsed,
      );
    } finally {
      if (client != null) {
        _activeClients.remove(client);
        client.close();
      }
    }
  }

  /// [command] on the saved host [connection], signed in to by [signIn] as
  /// a session to it is. (A task dialled the address the host is saved with
  /// and signed in with its own key: no network's settings, no jump host, no
  /// certificate; only the host's own key was checked for a run with nobody
  /// there; and the host's key was looked for as if the host were reached
  /// directly.)
  Future<AutomationResult> _runSignedIn(
    Connection connection,
    TaskSignIn signIn, {
    required String command,
    required Duration timeout,
    required bool unattended,
  }) async {
    final stopwatch = Stopwatch()..start();
    final progress = _TaskProgress();
    SshService? ssh;
    try {
      AppLogger.info('Automation: signing in to a saved host');
      // Over SSH whatever the host is opened with: a host that speaks mosh
      // or Eternal Terminal is saved with its SSH port, where a task always
      // ran.
      final opening = signIn(connection.copyWith(protocol: 'ssh'), unattended: unattended, onLog: (line) {
        // Connected to the host: what is left is the sign-in.
        if (line.startsWith('ssh_session: Starting')) progress.stage = TaskStage.signingIn;
      });
      final SshService signedIn;
      if (unattended) {
        signedIn = await opening.timeout(timeout, onTimeout: () {
          // Signed in after all, later: nothing is run there, and it is let go of.
          unawaited(opening.then((late) => late.disconnect(), onError: (Object _) {}));
          throw TimeoutException('Sign-in timed out', timeout);
        });
      } else {
        // Its person may be asked something, while which the sign-in's own
        // clock stops, as a session's does: the command's time starts once
        // it is signed in.
        signedIn = await opening;
      }
      ssh = signedIn;
      _signedIn.add(signedIn);
      final clock = unattended ? stopwatch : (Stopwatch()..start());
      AppLogger.info('Automation: signed in, executing command');
      return await _runOn(signedIn.client, command, timeout, () => timeout - clock.elapsed, progress, stopwatch);
    } on TimeoutException catch (e) {
      stopwatch.stop();
      AppLogger.warning('Automation: timeout - ${e.message}');
      return _timeUp(progress, timeout, stopwatch);
    } catch (e, stack) {
      stopwatch.stop();
      AppLogger.error('Automation: execution failed', e, stack);
      final cause = e is JumpHostFailure ? e.cause : e;
      return AutomationResult(
        success: false,
        output: '',
        // As a session that failed the same way says it: a host's key that
        // was not accepted, a jump host on the way, an Orchard's rule.
        error: couldNotRunText(e, host: connection.host, port: connection.port, username: ssh?.username),
        elapsed: stopwatch.elapsed,
        // What only a person could have given (a key allowed for runs with
        // nobody there, a password, a code): as where the host's own key is
        // not allowed.
        needsCredentials: cause is UnattendedSignInStopped,
      );
    } finally {
      final done = ssh;
      if (done != null) {
        _signedIn.remove(done);
        unawaited(done.disconnect());
      }
    }
  }

  /// [command] on [client], which is signed in, as a task runs it: what it
  /// printed, and how it ended. [left] is the time it has left; [progress]
  /// keeps how far it has come, for what is said where that is up first.
  Future<AutomationResult> _runOn(
    SSHClient client,
    String command,
    Duration timeout,
    Duration Function() left,
    _TaskProgress progress,
    Stopwatch stopwatch,
  ) async {
    progress.stage = TaskStage.starting;
    final authRemaining = left();
    if (authRemaining.isNegative) {
      throw TimeoutException('Timed out before command execution', timeout);
    }

    final session = await client.execute(CommandText.script(command)).timeout(
          authRemaining,
          onTimeout: () =>
              throw TimeoutException('Command execution timed out', timeout),
        );

    progress.stage = TaskStage.running;
    final out = progress.printed = CommandOutput(session.stdout, _maxCollectedBytes);
    final err = progress.printedAsErrors = CommandOutput(session.stderr, _maxCollectedBytes);

    final execRemaining = left();
    await Future.wait([out.ended, err.ended]).timeout(execRemaining, onTimeout: () {
      throw TimeoutException('Output collection timed out', timeout);
    });

    // A command can close what it prints to and go on running: then its
    // session is not over, and neither is the command.
    var stillRunning = false;
    await session.done.timeout(execRemaining, onTimeout: () {
      AppLogger.warning('Automation: session.done timed out, '
          'proceeding with collected output');
      stillRunning = true;
    });

    stopwatch.stop();
    final exitCode = session.exitCode;
    AppLogger.info('Automation: command completed '
        '(exit=$exitCode, ${stopwatch.elapsedMilliseconds}ms)');

    return commandResult(
      gl10n,
      stdout: out.text,
      stderr: err.text,
      exitCode: exitCode,
      signal: session.exitSignal?.signalName,
      // Whether the command's own session was cut off, not whether the
      // connection is over by now: a host may close the connection right
      // behind a command that ended in order.
      cutOffBy: session.endedBecause,
      stillRunning: stillRunning,
      elapsed: stopwatch.elapsed,
    );
  }

  /// What a task whose time was up says: what its command had printed by
  /// then, with that it had not ended, where it ran; else which step it was
  /// still at.
  AutomationResult _timeUp(_TaskProgress progress, Duration timeout, Stopwatch stopwatch) {
    final out = progress.printed;
    final err = progress.printedAsErrors;
    if (out != null && err != null) {
      // Its time was up while it ran: what it had printed until then is
      // the task's, with that it had not ended. (All of it was dropped,
      // and the task said "Timeout: Output collection timed out".)
      return commandResult(
        gl10n,
        stdout: out.text,
        stderr: err.text,
        exitCode: null,
        signal: null,
        cutOffBy: null,
        stillRunning: true,
        elapsed: stopwatch.elapsed,
      );
    }
    return AutomationResult(
      success: false,
      output: '',
      error: timeUpBeforeItRan(gl10n, progress.stage, timeout),
      elapsed: stopwatch.elapsed,
    );
  }

  /// Host key verification for automation: accept known, REJECT
  /// unknown.
  ///
  /// SECURITY: previously this auto-trusted new hosts because there's
  /// no UI to prompt during automation. That's a TOFU footgun - a
  /// MitM on a network the user has never connected to from this
  /// device would silently get their host key persisted as trusted,
  /// and every subsequent automated run would happily talk to the
  /// attacker.
  ///
  /// New behaviour: refuse to talk to a host we've never seen before
  /// during automation. The user must connect interactively at least
  /// once (via the regular host card) so they get a chance to verify
  /// the fingerprint via an out-of-band channel. After that, the
  /// known-hosts entry exists and automation works.
  Future<HostKeyVerifyResult> _verifyHostKey(
    String host,
    int port,
    String type,
    Uint8List fingerprint,
  ) async {
    final knownHostsService = KnownHostsService(_db.knownHostsDao);
    final hostKey = SSHHostKey(type: type, bytes: fingerprint);
    final result = (await knownHostsService.verify(host, port, hostKey, tellsPerson: false)).result;

    switch (result) {
      case HostKeyVerifyResult.trusted:
        break;
      case HostKeyVerifyResult.newHost:
        // SECURITY: refuse to TOFU-trust during automation. The
        // user can still connect interactively first to enrol the
        // host; after that this branch becomes [trusted].
        AppLogger.warning(
            'Automation: REFUSING to trust new host key for '
            '$host:$port ($type). Connect interactively from the '
            'hosts grid first so you can verify the fingerprint.');
      case HostKeyVerifyResult.changed:
        AppLogger.warning('Automation: REJECTING changed host key for '
            '$host:$port - possible MITM attack');
    }
    return result;
  }

  /// Load identity credentials from the database and secure storage.
  ///
  /// When [unattended] is true this is a headless run: the identity must have
  /// [Identity.allowUnattended] set or an [UnattendedBlockedException] is
  /// thrown BEFORE any secret is read from the keychain (fail-closed - a
  /// blocked run never even touches the stored credential). An identity-less
  /// connection (no saved credential to gate) is unaffected.
  /// [_loadCredentials], for tests of what a run carries.
  @visibleForTesting
  Future<({String username, String? password, List<SSHKeyPair>? keyPairs, String? passphrase})> loadCredentialsForTest(
          String? identityId,
          {bool unattended = false}) =>
      _loadCredentials(identityId, unattended: unattended);

  Future<
      ({
        String username,
        String? password,
        List<SSHKeyPair>? keyPairs,
        String? passphrase,
      })> _loadCredentials(String? identityId,
      {bool unattended = false}) async {
    if (identityId == null) {
      return (
        username: 'root',
        password: null,
        keyPairs: null,
        passphrase: null,
      );
    }

    final identity = await _db.identitiesDao.getById(identityId);
    if (identity == null) {
      AppLogger.warning(
          'Automation: identity $identityId not found, using defaults');
      return (
        username: 'root',
        password: null,
        keyPairs: null,
        passphrase: null,
      );
    }

    // ── Unattended gate (fail-closed) ──────────────────────────────
    // A headless run may only use a credential the user explicitly opted in.
    // Checked before reading any secret, so a blocked run never so much as
    // reads the keychain entry.
    if (unattendedBlocked(
        unattended: unattended, allowUnattended: identity.allowUnattended)) {
      throw UnattendedBlockedException(identity.id, identity.label);
    }

    // Read where the identity keeps them, opened where they are sealed
    // (SecretSeal): they were read from the storage as kept.
    final secrets = IdentitySecretStore.forDatabase(_db, _secureStorage);
    final password = await secrets.read(identity.id, IdentitySecret.password);
    final privateKeyPem = await secrets.read(identity.id, IdentitySecret.privateKey);
    final passphrase = await secrets.read(identity.id, IdentitySecret.passphrase);

    List<SSHKeyPair>? keyPairs;
    if (privateKeyPem != null) {
      try {
        keyPairs = SSHKeyPair.fromPem(privateKeyPem, passphrase);
      } catch (e) {
        AppLogger.error(
            'Automation: failed to load key for identity ${identity.id}', e);
      }
    }

    // Fail-closed against a silent auth downgrade. Switching an identity's
    // method never wipes the old secret, so a key/cert identity can still carry
    // a stale stored password; if we handed that password to `_execute`, a key
    // that failed to parse (keyPairs == null above) would quietly authenticate
    // BY PASSWORD with no user present - exactly the hardware-token incident's
    // failure shape. A key-based identity therefore never carries a password
    // into the connection; a bad key makes the run fail rather than downgrade.
    //
    // The same the other way (3.0): only a password key carries a
    // password, so an agent, team-certificate or password-manager key never
    // signs in with a stale stored one, and only a key type carries keys.
    //
    // But for a key with a password saved with it as that (3.0, accounts
    // per host): that one goes, after the key, to a server that does not
    // take the key, and only where the key itself could be read (a key that
    // could not be read still fails the run rather than signing in by
    // password alone).
    final isKeyBased = identity.authMethod == 'publicKey' ||
        identity.authMethod == 'certificate';
    final isPassword = identity.authMethod == 'password';
    final passwordAfterKey = isKeyBased && identity.passwordAfterKey && keyPairs != null;

    return (
      username: identity.username,
      password: isPassword || passwordAfterKey ? password : null,
      keyPairs: isKeyBased ? keyPairs : null,
      passphrase: passphrase,
    );
  }
}
