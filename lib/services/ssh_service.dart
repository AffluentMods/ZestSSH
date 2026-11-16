import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/fido/fido_key_pair.dart';
import 'package:zestssh/services/fido/fido_signer.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/error_translator.dart' show withAlgorithmsOffered;
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// Abstract interface for shell-providing protocols.
///
/// Both [SshService] and future Mosh/Telnet/LocalShell implementations
/// implement this interface so the terminal layer doesn't care which
/// transport is underneath.
abstract class ShellService {
  Future<void> connect();
  Future<void> disconnect();
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  void write(Uint8List data);
  void resize(int width, int height);
  bool get isConnected;
  Stream<bool> get connectionState;

  /// True when the most recent disconnect was the REMOTE SHELL PROCESS
  /// ending (user typed `exit`, pressed Ctrl+D, or the process was
  /// signalled) rather than the transport dropping out from under us.
  /// Lets the session layer close the tab on a clean exit instead of
  /// auto-reconnecting (which only makes sense for an unexpected drop).
  bool get exitedCleanly;

  /// True if this is a real, encrypted SSH session. Drives the "secure"
  /// padlock, SSH-only affordances, snippet-reuse, and monitor liveness.
  ///
  /// True for BOTH the in-isolate [SshService] and the worker-hosted
  /// `WorkerSshService` (Design B), so those cosmetic gates keep working when a
  /// terminal runs on a worker isolate. Defaults false so local-shell / demo /
  /// serial transports are unaffected (they show no padlock today, unchanged).
  ///
  /// NOTE: this is deliberately NOT a "can do SFTP / port-forward" signal.
  /// Those features need the live in-process [SSHClient] and still gate on
  /// `is SshService`, which a worker session is not.
  bool get isEncryptedSsh => false;
}

/// A shell that can say why its connection ended (3.0): a
/// session whose connection dropped says so, and why, where it is shown.
abstract interface class ShellEndReason {
  /// Why the connection ended: what the network said when it broke, or
  /// [hostClosedConnection] when the host closed it. Completes once it has
  /// ended (null when that is not known).
  Future<String?> get endReason;
}

/// A [ShellService] that can run one command beside its shell, on the same
/// connection, and give back what it printed: what a snippet's list of a
/// host's own (`$[DOCKER]`, `$[TMUX]`) is read from.
abstract interface class ShellOneOff {
  /// What [command] printed, trimmed; null where it could not be run or did
  /// not finish within [timeout].
  Future<String?> runOnce(String command, {Duration timeout = const Duration(seconds: 10)});
}

/// A [ShellService] that says how its shell ended, where the shell ended by
/// itself ([ShellService.exitedCleanly]): the host's word of it.
abstract interface class ShellExit {
  /// The exit status the shell ended with. Null where a signal ended it,
  /// where the host said nothing of how it ended, and while it runs.
  int? get exitCode;

  /// The signal that ended the shell, as the host named it ("TERM", "HUP").
  /// Null where none did.
  String? get exitSignal;
}

/// [ShellEndReason.endReason] when the host closed the connection.
const hostClosedConnection = 'Connection closed by the host';

/// [ShellEndReason.endReason] when the connection was given up because the
/// host stopped answering: keep-alives went unanswered, and nothing else
/// came from it (a network that drops everything, a host that froze).
const hostStoppedAnswering = 'The host stopped answering';

/// [ShellEndReason.endReason] when the connection was ended over the host's
/// key while it was open ([SSHHostkeyError.duringRekey]): the host asked for
/// new keys and showed another key than the one the session began with, or
/// could not sign with it. A host keeps its key while a session is open, so
/// this is somebody who has got into the connection, or a server that is
/// broken: it is said as that, and the session is not connected to again by
/// itself.
const hostKeyFailedAtNewKeys = 'The host key was not the session\'s own when new keys were taken';

/// [ShellEndReason.endReason] when the connection was ended because what
/// came over it did not pass its check ([SSHPacketError.damaged]): a packet
/// was changed or damaged on the way, by a line that is failing or by
/// whoever sits on it, or the two sides stopped protecting their packets
/// the same way, and nothing of it was used.
const hostDataDamaged = 'What came from the host did not pass its check';

/// What [ShellEndReason.endReason] begins with when it was not the host's
/// own connection that ended, but the one to a jump host on the way to it
/// ([endedAtJumpHost]).
const _atJumpHost = 'At the jump host ';

/// [ShellEndReason.endReason] of a session whose way went through the jump
/// host [label] (as the app names that host), when the connection to that
/// jump host ended: [reason] is why, as it is said of any connection that
/// ends ([endReasonOf], [hostClosedConnection]). The host's own connection
/// went with it, and has nothing of its own to say: it was said to have
/// been closed by the host, whatever had happened to the jump host's (its
/// key failed when new keys were taken, say, which somebody on the line to
/// the jump host can bring about).
String endedAtJumpHost(String label, String reason) => '$_atJumpHost${jsonEncode(label)}: $reason';

/// The jump host whose connection ended and why, where [endReason] says
/// that ([endedAtJumpHost]); null where it is the reason of a host's own
/// connection, or none.
({String label, String reason})? jumpHostEnded(String? endReason) {
  if (endReason == null) return null;
  final said = _atJumpHostSaid.firstMatch(endReason);
  if (said == null) return null;
  try {
    return (label: jsonDecode(said[1]!) as String, reason: said[2]!);
  } on FormatException {
    return null;
  }
}

// (The label as a JSON string: whatever a host is named, it ends where its quote does.)
final _atJumpHostSaid = RegExp('^${RegExp.escape(_atJumpHost)}("(?:[^"\\\\]|\\\\.)*"): (.*)\$', dotAll: true);

/// What a connection's log says of the connection to the jump host [label]
/// when it has ended by itself, with what it ended with ([error]; null
/// where it was closed with nothing said).
String jumpHostEndLogLine(String label, Object? error) => error == null
    ? 'jump: The jump host $label closed its connection'
    : 'jump: The connection to the jump host $label ended - ${endLogLine(error) ?? asLogLine('$error')}';

/// Why the connection that ended did: [endReason] itself, or the reason of
/// the jump host's connection where that is the one that ended
/// ([jumpHostEnded]). For whoever acts on a reason whichever connection it
/// is of: a key that failed when new keys were taken is not connected to
/// again by itself, at the host or at a jump host.
String? endReasonItself(String? endReason) => jumpHostEnded(endReason)?.reason ?? endReason;

/// What [ShellEndReason.endReason] begins with when the host ended the
/// connection and said why; what follows is what it said ([hostSaid]).
const _hostEndedSaying = 'The host ended the connection: ';

/// What the host said when it ended the connection, where [endReason] is
/// one of those ([endReasonOf]); null otherwise.
String? hostSaid(String? endReason) => endReason != null && endReason.startsWith(_hostEndedSaying)
    ? endReason.substring(_hostEndedSaying.length)
    : null;

/// What ends a line, steers a terminal or cannot be shown: the control
/// characters of both sets, and the line and paragraph separators.
final _controls = RegExp(r'[\x00-\x1f\x7f\u0080-\u009f\u2028\u2029]');

/// What turns the direction of the text around it (embeddings, overrides,
/// isolates): it is not seen, and can make a sentence read as another one.
final _directionMarks = RegExp(r'[\u202a-\u202e\u2066-\u2069]');

/// [text] as text and nothing else: a space for each of [_controls], and
/// the [_directionMarks] out.
String _asText(String text) => text.replaceAll(_directionMarks, '').replaceAll(_controls, ' ');

/// [text], which a host wrote, as it can be shown in a sentence of the
/// app's: on one line, with nothing in it that steers a terminal, turns
/// the sentence around or cannot be shown, and not longer than a few lines
/// would be. It is shown as what was said, and is never taken for anything
/// else.
String shownHostText(String text) {
  final oneLine = _asText(text).replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= 200 ? oneLine : '${oneLine.substring(0, 197)}...';
}

/// [text] as one line of a connection's log. What the SSH library says of a
/// connection can carry what the host wrote (why it ended the connection,
/// its version line), and that is the host's to choose: it makes no lines
/// of its own in the log, and no line without end.
String asLogLine(String text) {
  final line = _asText(text);
  return line.length <= 2000 ? line : '${line.substring(0, 1997)}...';
}

/// Why a connection that ended with [error] ended, as a session keeps it
/// ([ShellEndReason.endReason]): that the host stopped answering, that its
/// key failed when new keys were taken, that what came from it did not pass
/// its check, what the host said when it ended the connection itself, or
/// what the library says of it.
String endReasonOf(Object error) {
  if (error is SSHNoAnswerError) return hostStoppedAnswering;
  if (error is SSHPacketError && error.damaged) return hostDataDamaged;
  // (A host key that is refused at the start of a connection ends no
  // session: it is what the library says of it, like anything else.)
  if (error is SSHHostkeyError && error.duringRekey) return hostKeyFailedAtNewKeys;
  if (error is SSHDisconnectError) {
    // A session is under keys whose host key was approved, so what ends it
    // is the host's own. Anything else is not said as the host's words.
    if (!error.authentic) return shownHostText(error.message);
    final said = shownHostText(error.description);
    // With no words of its own, it is a host that closed the connection.
    return said.isEmpty ? hostClosedConnection : '$_hostEndedSaying$said';
  }
  return '$error';
}

/// The reason code of a host that ended a connection because it has too
/// many of them (RFC 4253, 11.1): the one a later try may not be told.
const _tooManyConnections = 12;

/// Whether [error], which a try of connecting ended with, is the host
/// saying no to the sign-in: it took none of the keys or the password it
/// was offered ([SSHAuthFailError]), or it ended the connection while it
/// was being signed in to and said that it does ([SSHDisconnectError]:
/// OpenSSH's "Too many authentication failures", once it has refused as
/// many keys as it allows a connection). The next try would be told the
/// same, and each one is one more failed sign-in in the host's log: ten of
/// them in three minutes is what gets an
/// address banned.
///
/// Not this: a connection that ended while it was being signed in to with
/// nothing said (a host that is starting, or busy), and a host that said it
/// has too many connections, which the next try may find otherwise.
bool hostRefusedSignIn(Object error) {
  if (error is SSHAuthFailError) return true;
  final ended = error is SSHAuthAbortError ? error.reason : null;
  return ended is SSHDisconnectError && ended.reasonCode != _tooManyConnections;
}

/// [e], a key exchange that ended with no algorithm of one kind in common
/// ([SSHHandshakeError.nothingInCommon]), as a failed connection keeps it
/// and as a report says it: what it prints, with what each side offered of
/// that kind, and what Compatibility mode has of it that was not offered
/// and that the server offers ([withAlgorithmsOffered]). Whoever shows it
/// knows from the last whether the mode is worth turning on: it adds
/// nothing where the connection was made with it, and nothing where the
/// server offers none of what it has.
String nothingInCommonText(SSHHandshakeError e) => withAlgorithmsOffered(
      '$e',
      offered: e.offered ?? const <String>[],
      serverOffers: e.otherSideOffered ?? const <String>[],
      modeAdds: compatibilityModeAdds(e),
    );

/// What Compatibility mode has, of the kind [e] found nothing in common of,
/// that was not offered and that the server offers: empty where the mode
/// would not have connected.
List<String> compatibilityModeAdds(SSHHandshakeError e) {
  final offered = e.offered ?? const <String>[];
  final serverOffers = e.otherSideOffered ?? const <String>[];
  final withMode = SshService.buildAlgorithms(compatibility: true);
  // (No two kinds of algorithm share a name: what the server offers of one kind is among none of the others.)
  final modeHas = [
    for (final algorithm in withMode.kex) algorithm.name,
    for (final algorithm in withMode.hostkey) algorithm.name,
    for (final algorithm in withMode.cipher) algorithm.name,
    for (final algorithm in withMode.mac) algorithm.name,
  ];
  return [
    for (final name in modeHas)
      if (!offered.contains(name) && serverOffers.contains(name)) name,
  ];
}

/// Whether [error], the end of a connection made without Compatibility mode,
/// is a host refusing it for an old key exchange that the mode would have
/// taken: nothing of one kind in common that the mode has, or a group the
/// mode takes. (A jump host's failure is the jump host's, not the host's.)
bool refusedForOldKeyExchange(Object error) => switch (error) {
      SSHKexGroupError(tooShort: true) => compatibilityModeTakesGroup(error),
      SSHHandshakeError(nothingInCommon: true) => compatibilityModeAdds(error).isNotEmpty,
      _ => false,
    };

/// Whether Compatibility mode would have taken the group that [e] refused
/// as too short: the group is as long as the mode takes
/// ([SSHAlgorithms.minDhGroupBits] of [SshService.buildAlgorithms]), and
/// the connection that refused it asked for more, so it was made without
/// the mode. Such a host offers only an outdated key exchange, and the
/// person is told that the mode can connect to it. A group shorter than
/// the mode takes, or one refused with the mode on, is said as too short
/// and no more.
bool compatibilityModeTakesGroup(SSHKexGroupError e) {
  final withMode = SshService.buildAlgorithms(compatibility: true).minDhGroupBits;
  return e.tooShort && e.bits >= withMode && e.shortestTaken > withMode;
}

/// What a session keeps as why it ended when its host ended its shell and
/// its person had not asked for that; what follows is how it ended and what
/// the host said last ([sessionEndedCause], [sessionEnded]).
const _hostEndedSession = 'The host ended the session';

/// Why a session ended, as the session keeps it, when its host ended its
/// shell: with [exitCode], or by [signal], or with nothing said of how, and
/// with [said], the last the host printed (rows as text, one to a line).
String sessionEndedCause({int? exitCode, String? signal, String said = ''}) {
  final how = signal != null
      ? ' (signal ${_signalName(signal)})'
      : exitCode != null
          ? ' (exit status $exitCode)'
          : '';
  return said.isEmpty ? '$_hostEndedSession$how' : '$_hostEndedSession$how:\n$said';
}

/// How the shell ended and what the host said last, where [cause] is one of
/// [sessionEndedCause]'s; null otherwise.
({int? exitCode, String? signal, String said})? sessionEnded(String? cause) {
  if (cause == null || !cause.startsWith(_hostEndedSession)) return null;
  var rest = cause.substring(_hostEndedSession.length);
  int? exitCode;
  String? signal;
  if (rest.startsWith(' (')) {
    final end = rest.indexOf(')');
    if (end < 0) return null;
    final how = rest.substring(2, end);
    if (how.startsWith('exit status ')) {
      exitCode = int.tryParse(how.substring('exit status '.length));
      if (exitCode == null) return null;
    } else if (how.startsWith('signal ')) {
      signal = how.substring('signal '.length);
    } else {
      return null;
    }
    rest = rest.substring(end + 1);
  }
  if (rest.isEmpty) return (exitCode: exitCode, signal: signal, said: '');
  if (!rest.startsWith(':\n')) return null;
  return (exitCode: exitCode, signal: signal, said: rest.substring(2));
}

/// What OpenSSH's server prints when a session asks for a shell or a command
/// where the server gives files only (ForceCommand internal-sftp), before it
/// ends the session with the status 1 (session.c, do_child).
const sftpOnlyServerWords = 'This service allows sftp connections only.';

/// Whether [said], what a host printed as it ended a session, is its server
/// saying it gives files only ([sftpOnlyServerWords]).
bool saysSftpOnly(String said) => said.toLowerCase().contains('allows sftp connections only');

/// The name of a signal as a host wrote it, as it can stand in a sentence:
/// its letters, digits and the few marks such names have, and nothing else.
String _signalName(String signal) => shownHostText(signal).replaceAll(RegExp('[^A-Za-z0-9+_@.-]'), '');

/// The last of what stands in [rows] (a terminal's rows, from the top), as
/// it can be quoted beside a sentence of the app's: the last [most] rows
/// that are not empty, each as text and nothing else ([shownHostText]), one
/// to a line.
String lastWords(Iterable<String> rows, {int most = 6}) {
  final said = [
    for (final row in rows)
      if (shownHostText(row).isNotEmpty) shownHostText(row),
  ];
  return said.skip(said.length > most ? said.length - most : 0).join('\n');
}

/// What goes into a connection's log when it ended with [error], beside
/// what the session says of it ([endReasonOf]): how long nothing came, the
/// reason code a host gave with its words, what the SSH core found of a
/// packet that was changed on the way, and what it found wrong with a
/// host's key by itself, at the start of the connection or when new keys
/// were taken. Null where there is nothing more to say: a key that the app
/// or its person did not accept is in the log by then.
String? endLogLine(Object error) => switch (error) {
      SSHNoAnswerError() => 'ssh_keepalive: ${error.message}',
      SSHPacketError(damaged: true) => 'ssh_session: ${error.message}',
      SSHDisconnectError() => 'ssh_session: ${shownHostText(error.message)}',
      SSHHostkeyError(fault: _?) => error.duringRekey
          ? 'ssh_hostkey: Host key REJECTED when new keys were taken - ${asLogLine(error.message)}'
          : 'ssh_hostkey: Host key REJECTED - ${asLogLine(error.message)}',
      _ => null,
    };

/// What a host that had signed someone in did not give them.
enum NoSessionKind {
  /// No terminal (a key or an account that may have none).
  terminal,

  /// No shell.
  shell,

  /// No session at all (an account kept for forwarding, a host that allows
  /// no more sessions).
  session,

  /// Something else the session was to have, or the host closed what was
  /// opened for the session without answering.
  other,

  /// The connection closed before the session had started, with nothing
  /// said of why (a network that breaks says so itself, and is said as
  /// that).
  closed,
}

/// A host signed the person in and then did not start the session. The
/// connection has been closed by the time this is thrown: nothing would
/// hold it, the session it was made for not being there.
class SshNoSessionException implements Exception, HasTypeName {
  const SshNoSessionException(this.kind, this.cause);

  final NoSessionKind kind;

  /// What the SSH library said of it, for the report.
  final Object cause;

  /// [error], thrown where a shell was asked for on a connection that had
  /// signed in, as no session having started; null where it is something
  /// else (a network that broke under the question, a time-out), which is
  /// said as what it is.
  static SshNoSessionException? of(Object error) => switch (error) {
        SSHChannelOpenError() => SshNoSessionException(NoSessionKind.session, error),
        SSHChannelRequestError(message: 'Failed to start pty') => SshNoSessionException(NoSessionKind.terminal, error),
        SSHChannelRequestError(message: 'Failed to start shell') => SshNoSessionException(NoSessionKind.shell, error),
        SSHChannelRequestError() => SshNoSessionException(NoSessionKind.other, error),
        // What the library says of a connection that closed with no error:
        // "Connection closed before the request was answered", "Connection
        // closed while waiting for channel open", "Transport is closed".
        SSHStateError(:final message) when message.toLowerCase().contains('closed') =>
          SshNoSessionException(NoSessionKind.closed, error),
        _ => null,
      };

  /// For a log and a report. What the person is told is the app's to say,
  /// in their language (connectionFailureText).
  @override
  String toString() => 'No session after sign-in (${kind.name}): $cause';

  @override
  String get typeName => 'SshNoSessionException';
}

/// Callback invoked when the remote host presents its key.
/// Return `true` to accept. To reject the connection, return `false`, or
/// throw a [HostKeyNotAccepted] that says why: the connection then ends
/// with it, and whoever shows the failure can say which it was.
typedef HostKeyVerifyCallback = Future<bool> Function(
    String host, int port, SSHHostKey hostKey);

/// A [HostKeyVerifyCallback] for a connection that may go through jump
/// hosts, told for a jump host on the way which saved host it is ([hostId],
/// its id): a team's pinned key (3.0) counts only for the hosts
/// of the pin's own Crate, and a jump host's Crate need not be that of the
/// host it leads to. Without [hostId] the key is the connection's own host's.
typedef ChainHostKeyVerifyCallback = Future<bool> Function(
    String host, int port, SSHHostKey hostKey, {String? hostId});

/// Why a host's key was not accepted.
enum HostKeyRefusal {
  /// Its person was shown a key this device had not seen for the host, and
  /// did not accept it.
  declinedNew,

  /// Its person was shown another key than the one this device trusts for
  /// the host, and did not accept it.
  declinedChanged,

  /// It is not the key the team pinned for the host, and this account may
  /// not replace the pin: its person was shown that, and could do nothing.
  pinnedOther,

  /// A session opened by a run with nobody there (automation, 3.0) met a
  /// key this device does not trust yet for the host: a new key is not
  /// taken when nobody is there to check it, and nobody was asked.
  unknownUnattended,

  /// A session opened by a run with nobody there met another key than the
  /// one this device (or its team) trusts for the host; nobody was asked.
  changedUnattended,
}

/// A host's key that its person was shown and that was not accepted, and
/// why: they said no to it, or were told at the key that nothing can be
/// done. A check of a host's key throws it in place of answering no; the SSH
/// library ends the connection with what such a check throws, so a sign-in
/// that was cut off for it has it as its reason.
///
/// (The check answered no, and the connection ended with the library's
/// "Hostkey verification failed", whichever of these it was: shown as "the
/// server closed the connection before completing login" to somebody who
/// had just said no to the key themselves.)
class HostKeyNotAccepted extends SSHHostkeyError {
  HostKeyNotAccepted(this.why, {required this.host, required this.port, this.crate, this.certificate = false})
      : super('The host key of $host:$port was not accepted (${why.name})');

  final HostKeyRefusal why;

  /// Whose key it was: the address and port that showed it.
  final String host;
  final int port;

  /// The Crate the team's pin is in ([HostKeyRefusal.pinnedOther]).
  final String? crate;

  /// What was not accepted is an FTPS server's TLS certificate (3.4), not an
  /// SSH host key: said in a certificate's words.
  final bool certificate;
}

/// Optional callback for reporting connection progress messages.
typedef ConnectionLogCallback = void Function(String message);

/// What the connection log says when a key signed something through the agent
/// forwarded to a host. (A worker isolate has only its log to say it with.)
const kAgentSignedLogLine = 'ssh_agent: A key here signed something for the host through the forwarded agent';

/// Opens the connection to [host]:[port], giving up after [timeout]: every
/// SSH connection the app makes to a host goes through here (a session's,
/// a jump host's, a console server's, Server Monitor's, a host form's
/// test), with the time Settings gives (Connection timeout, which nothing
/// read: each gave up after 15 seconds, a host form's test after 5).
Future<SSHSocket> openSshSocket(String host, int port, Duration timeout) {
  final open = SshService.debugOpenSocket;
  if (open != null) return open(host, port, timeout);
  return SSHSocket.connect(host, port, timeout: timeout);
}

/// SSH implementation of [ShellService] using `zest_ssh_core` (the
/// in-house SSH library that replaced dartssh2).
class SshService implements ShellService, ShellEndReason, ShellExit, ShellOneOff {
  /// How a test opens a connection in place of the network ([openSshSocket]).
  /// Null in the app.
  @visibleForTesting
  static Future<SSHSocket> Function(String host, int port, Duration timeout)? debugOpenSocket;

  final String host;
  final int port;

  /// How long the connection to [host] may take to open (Settings).
  final Duration connectTimeout;
  final String username;

  /// Credential fields - cleared after authentication to minimize the window
  /// during which sensitive material is resident in memory. See [_clearCredentials].
  List<SSHKeyPair>? _keyPairs;
  String? _password;

  /// Fetches the password saved with the key, for a server that does not
  /// take the key and takes passwords (3.0, accounts per host): called only
  /// then, and at most once.
  Future<String?> Function()? _passwordAfterKey;

  final bool zlibCompression;
  final bool forwardAgent;
  final int keepAliveSeconds;
  final HostKeyVerifyCallback onHostKeyVerify;
  final ConnectionLogCallback? onLog;

  /// Shows the server's keyboard-interactive questions (a one-time code, a
  /// new password) to the person. Null for a connection nobody is watching,
  /// which answers them empty and so fails closed.
  final ServerQuestionAsker? onServerQuestion;

  /// Shows a login banner with a link in it to the person while the sign-in
  /// waits on it ([SignInNotice]: Tailscale SSH's "check" mode), and says
  /// whether they cancelled. Null for a connection nobody is watching: the
  /// banner then waits for the shell as every banner does, and the sign-in
  /// gets no more time.
  final SignInNoticeShower? onSignInNotice;

  /// When true, the client advertises legacy algorithms (CBC ciphers,
  /// `hmac-md5`, the SHA-1 key exchanges; never DH group 1) in addition to
  /// the modern defaults. Required
  /// for older OpenSSH servers - notably default Proxmox LXC templates
  /// (Ubuntu 18.04 / Debian 10 base images), OpenWrt routers, and any
  /// OpenSSH < 7.6 install. Modern algorithms remain first in preference
  /// order so a server that supports them still picks the strong option.
  final bool compatibilityMode;

  /// Optional pre-connected socket (e.g. from a jump host tunnel).
  /// When provided, [connect] uses this instead of [SSHSocket.connect].
  final SSHSocket? tunnelSocket;

  /// Optional intermediate jump-host SSH clients to clean up on
  /// disconnect.  Order is "nearest first": index 0 is the host
  /// the tunnel socket is forwarded through, index 1 is its own
  /// jump host, etc.  Closing them in order tears the chain down
  /// cleanly.  Empty list = no jump chain (direct connection).
  final List<SSHClient> jumpClients;

  /// What the app calls each of [jumpClients]' hosts, in the same order:
  /// said where a session ends because the connection to one of them did
  /// ([endedAtJumpHost]). A jump host that is given no name is called by
  /// its place on the way.
  final List<String> jumpLabels;

  /// The underlying SSH client. Exposed for SFTP and port forwarding.
  SSHClient? _client;

  /// The server's pre-auth banner (SSH_MSG_USERAUTH_BANNER: the "authorised
  /// users only" notice many hosts show), held until the shell opens so it
  /// lands in the terminal ahead of the first prompt, like OpenSSH prints it.
  String? _pendingBanner;

  /// Access the SSH client for SFTP/port forwarding.
  /// Throws if not connected.
  SSHClient get client {
    if (_client == null) throw StateError('SSH not connected');
    return _client!;
  }

  /// Whether the host refused agent forwarding on this connection
  /// A key signed something through the agent forwarded to this host, which it
  /// can ask for with no question while it is connected.
  final void Function()? onAgentSigned;

  /// ([forwardAgent] was on, and its server, or the key that signed in,
  /// allows none). The session is there all the same, without the agent.
  bool get agentForwardingRefused => _client?.agentForwardingRefused ?? false;

  // ── Negotiated algorithm surface ────────────────────────────────
  //
  // These read the SSH core's per-connection diagnostics, which record
  // the algorithms actually agreed during key exchange. All are null
  // until KEX completes (and after disconnect), so callers must treat a
  // null as "unavailable" and omit the row rather than fabricate one.
  // We never name the diagnostics type here so nothing new has to be
  // exported from the core's public barrel.

  /// Negotiated key-exchange algorithm (e.g. `curve25519-sha256`), or null.
  String? get negotiatedKex => _client?.diagnostics.negotiatedKex;

  /// Negotiated symmetric cipher (e.g. `chacha20-poly1305@openssh.com`), or null.
  String? get negotiatedCipher => _client?.diagnostics.negotiatedCipher;

  /// Negotiated MAC algorithm, or null. Empty/absent for AEAD ciphers
  /// (ChaCha20-Poly1305, AES-GCM) that authenticate inline.
  String? get negotiatedMac => _client?.diagnostics.negotiatedMac;

  /// Negotiated host-key algorithm (e.g. `ssh-ed25519`), or null.
  String? get negotiatedHostKeyAlgorithm =>
      _client?.diagnostics.negotiatedHostKey;

  /// The server's version line (e.g. `SSH-2.0-OpenSSH_9.6`), or null.
  String? get serverVersion => _client?.remoteVersion;

  /// How the session signed in (`publickey`, `password`,
  /// `keyboard-interactive`), or null.
  String? get signedInWith => _client?.diagnostics.authMethodSucceeded;

  SSHSession? _shell;
  Timer? _keepAliveTimer;
  final _connectionStateController = StreamController<bool>.broadcast();
  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  bool _isConnected = false;
  bool _disposed = false;

  SshService({
    required this.host,
    required this.port,
    required this.username,
    List<SSHKeyPair>? keyPairs,
    String? password,
    Future<String?> Function()? passwordAfterKey,
    this.zlibCompression = false,
    this.forwardAgent = false,
    this.keepAliveSeconds = 15,
    this.compatibilityMode = false,
    this.connectTimeout = const Duration(seconds: 15),
    required this.onHostKeyVerify,
    this.onLog,
    this.onAgentSigned,
    this.onServerQuestion,
    this.onSignInNotice,
    this.tunnelSocket,
    List<SSHClient>? jumpClients,
    List<String>? jumpLabels,
  })  : jumpClients = jumpClients ?? const [],
        jumpLabels = jumpLabels ?? const [],
        _keyPairs = keyPairs,
        _password = password,
        _passwordAfterKey = passwordAfterKey;

  /// Build the [SSHAlgorithms] set the SSHClient will offer.
  ///
  /// Default (compatibility OFF): the library's modern defaults - no
  /// CBC, no MD5, no DH group-1.
  ///
  /// Compatibility ON: modern defaults FIRST (so strong algorithms still
  /// win when supported), with legacy options appended for older servers.
  ///
  /// Exposed (no leading underscore) so the jump-host path in
  /// terminal_providers can build the same algorithm set for
  /// intermediate hops when the target requires compatibility mode.
  static SSHAlgorithms buildAlgorithms({required bool compatibility}) =>
      _buildAlgorithms(compatibility: compatibility);

  /// What a connection's log says compatibility mode adds: what
  /// [buildAlgorithms] appends to the defaults (it said DH group-1, which
  /// compatibility mode does not offer).
  static const compatibilityLogLine = 'ssh_compat: Legacy algorithm support enabled '
      '(CBC ciphers, hmac-md5, the SHA-1 key exchanges and key exchange groups of 1024 bits included; '
      'never DH group 1)';

  static SSHAlgorithms _buildAlgorithms({required bool compatibility}) {
    if (!compatibility) return const SSHAlgorithms();
    return const SSHAlgorithms(
      kex: [
        // Post-quantum hybrids first, exactly as in the strict default
        // profile: compatibility mode only APPENDS legacy algorithms.
        SSHKexType.mlkem768x25519,
        SSHKexType.sntrup761x25519,
        SSHKexType.sntrup761x25519OpenSSH,
        SSHKexType.x25519,
        SSHKexType.x25519Iana,
        SSHKexType.nistp521,
        SSHKexType.nistp384,
        SSHKexType.nistp256,
        SSHKexType.dhGexSha256,
        SSHKexType.dh14Sha256,
        SSHKexType.dh14Sha1,
        SSHKexType.dhGexSha1,
        // dh1Sha1 (1024-bit DH Group 1) dropped even from compat: Group 14
        // (2048-bit) is universally supported by anything speaking SSH-2, so
        // Group 1 buys no real compatibility and is factorable by a
        // well-resourced adversary.
      ],
      hostkey: [
        SSHHostkeyType.ed25519,
        SSHHostkeyType.rsaSha512,
        SSHHostkeyType.rsaSha256,
        SSHHostkeyType.rsaSha1,
        SSHHostkeyType.ecdsa521,
        SSHHostkeyType.ecdsa384,
        SSHHostkeyType.ecdsa256,
      ],
      cipher: [
        // Modern (AEAD + CTR) first. Prefer the 256-bit key over the
        // 128-bit one so a compat server offering both still negotiates the
        // stronger cipher.
        SSHCipherType.chacha20poly1305,
        SSHCipherType.aes256ctr,
        SSHCipherType.aes128ctr,
        // AES-GCM where the strict profile has it: after what was offered
        // before it, and before anything this mode adds.
        SSHCipherType.aes256gcm,
        SSHCipherType.aes128gcm,
        // Legacy CBC fallbacks for older OpenSSH / Proxmox LXC templates
        SSHCipherType.aes128cbc,
        SSHCipherType.aes192cbc,
        SSHCipherType.aes256cbc,
      ],
      mac: [
        SSHMacType.hmacSha512Etm,
        SSHMacType.hmacSha256Etm,
        SSHMacType.hmacSha512,
        SSHMacType.hmacSha256,
        SSHMacType.hmacSha1,
        SSHMacType.hmacSha512_96,
        SSHMacType.hmacSha256_96,
        // Legacy add-on
        SSHMacType.hmacMd5,
      ],
      // An RSA key of the app's own may also sign with the first kind of
      // RSA signature, with SHA-1, which is all that a server older than
      // OpenSSH 7.2 knows. The two with SHA-2 stay first, so a host that
      // takes one of them is never signed in to with SHA-1.
      rsaSignatures: [
        SSHRsaSignatureType.sha512,
        SSHRsaSignatureType.sha256,
        SSHRsaSignatureType.sha1,
      ],
      // An RSA host key of any length, as every version before 3.0 took
      // one with the mode or without: an old router or switch may have one
      // of 768 bits, or 512, and can make no other. Without the mode a key
      // under 2048 bits is not taken (the SSH core's own rule since 3.3.0,
      // NIST's floor until 2030; OpenSSH's is 1024).
      minRsaHostKeyBits: 0,
      // A group exchange asks for and takes a group of 1024 bits, which is
      // all an old OpenSSH or an embedded device may have: without the mode
      // nothing under 2048 bits is asked for or taken (the SSH core's own
      // rule, which is OpenSSH's), and such a server could not be connected
      // to at all. A group of 1024 bits can be broken by whoever has the
      // means; the core never goes under it.
      minDhGroupBits: 1024,
    );
  }

  /// Clear credential material from memory after authentication succeeds.
  /// Dart strings are immutable and GC-collected so we cannot truly zero them,
  /// but dropping the reference makes the data eligible for collection and
  /// prevents accidental access from other code paths post-auth.
  void _clearCredentials() {
    _password = null;
    _keyPairs = null;
    _passwordAfterKey = null;
  }

  /// Shared connect + authenticate core for [connect] and [connectExec]:
  /// builds the socket (or reuses a jump tunnel), offers the algorithm set,
  /// verifies the host key, and awaits userauth. Leaves [_client]
  /// authenticated with NO shell opened and credentials cleared.
  Future<void> _authenticate() async {
    AppLogger.info('SSH connecting to $username@$host:$port');

    final SSHSocket socket;
    if (tunnelSocket != null) {
      onLog?.call('tunnel: Using pre-established tunnel to $host:$port');
      socket = tunnelSocket!;
    } else {
      onLog?.call('Resolving $host...');
      socket = await openSshSocket(host, port, connectTimeout);
      // The address the host's name was resolved to and reached (a direct
      // connection's only): where a built-in Mosh session sends its UDP.
      if (socket is SSHSocketPeer) _peerAddress = (socket as SSHSocketPeer).remoteAddress;
    }
    onLog?.call('tcp_connect: Connected to $host:$port');
    onLog?.call('ssh_session: Starting SSH-2.0 protocol negotiation');

    // Capture credentials into local variables for the auth closures.
    // After authentication succeeds, _clearCredentials() drops the field
    // references so the values become eligible for GC.
    final localPassword = _password;
    final localKeyPairs = _keyPairs;
    final localPasswordAfterKey = _passwordAfterKey;

    final authMethod = localKeyPairs != null && localKeyPairs.isNotEmpty
        ? (localPasswordAfterKey != null ? 'publickey, then the password saved with the key' : 'publickey')
        : (localPassword != null ? 'password' : 'none');
    onLog?.call('ssh_auth: Authenticating as $username ($authMethod)');

    // Log the algorithms we're offering so we can diagnose negotiation failures
    final algos = _buildAlgorithms(compatibility: compatibilityMode);
    if (compatibilityMode) {
      onLog?.call(compatibilityLogLine);
    }
    onLog?.call('ssh_kex: Offering KEX: ${algos.kex.map((a) => a.name).join(", ")}');
    onLog?.call('ssh_cipher: Offering ciphers: ${algos.cipher.map((a) => a.name).join(", ")}');
    onLog?.call('ssh_mac: Offering MACs: ${algos.mac.map((a) => a.name).join(", ")}');

    // Build the agent handler when forwarding is enabled and we have keys.
    // SSHKeyPairAgent implements the in-memory agent protocol - it answers
    // identity and sign requests from the remote server using the same
    // key pairs that were used to authenticate this connection.
    final SSHAgentHandler? agent = forwardAgent && localKeyPairs != null && localKeyPairs.isNotEmpty
        ? SSHKeyPairAgent(localKeyPairs, onSigned: () => onAgentSigned?.call())
        : null;

    if (forwardAgent) {
      onLog?.call('ssh_agent: Agent forwarding ${agent != null ? "enabled" : "skipped (no keys)"}');
    }

    // The core's protocol trace goes to the user-visible connection log ONLY
    // until authentication succeeds: that is what it is for (KEX / host-key /
    // auth failures). After that every channel event still produced a trace
    // line, and each line went through `_addLog`, which republishes the whole
    // session state (a fresh sessions map, a copied log list, a rebuild of
    // every watcher). During a folder upload that was hundreds of thousands
    // of lines, an unbounded log list copied on every append, and the GC
    // pauses to match: the "still laggy" after the panel fix.
    var forwardDebugToLog = true;

    // Keyboard-interactive: the saved password for a real password prompt,
    // once; everything else to the person when someone is watching, empty
    // otherwise (ssh_auth_prompts.dart). The auth clock stops while they
    // answer, and a server that has started asking gets longer to reply (it
    // may be waiting on a push approval).
    final deadline = AuthDeadline();
    final questionsWithdrawn = Completer<void>();
    // A login banner with a link the sign-in waits on ([onSignInNotice]).
    final links = SignInLinkBanners(onSignInNotice, deadline: deadline, withdrawn: questionsWithdrawn.future, onLog: onLog);
    final serverQuestion = onServerQuestion;
    final answerer = KeyboardInteractiveAnswerer(
      password: localPassword,
      // The clock stops while it is fetched: that can ask the person.
      passwordAfterKey: localPasswordAfterKey == null
          ? null
          : () => deadline.whileAsking(localPasswordAfterKey),
      ask: serverQuestion == null
          ? null
          : (question) => deadline.whileAsking(() => serverQuestion(question)),
      withdrawn: questionsWithdrawn.future,
      onServerActive: () => deadline.relax(kServerQuestionPatience),
      onLog: onLog,
    );

    _client = SSHClient(
      socket,
      username: username,
      identities: signingOffTheClock(localKeyPairs, deadline),
      algorithms: algos,
      agentHandler: agent,
      onAgentForwardingRefused: () =>
          onLog?.call('ssh_agent: The host refused agent forwarding - the session goes on without it'),
      onUserauthBanner: (message) {
        _pendingBanner = message;
        onLog?.call('ssh_auth: Server sent a login banner');
        // A banner with a link the sign-in waits on (Tailscale SSH's check):
        // shown to the person now, not once the shell is open, and the
        // server given the time it takes them to open it and approve.
        links.banner(message);
      },
      printDebug: (msg) {
        if (!forwardDebugToLog) return;
        // Protocol-sensitive data (key exchange params) is not credential
        // material.
        AppLogger.info('dartssh2: $msg');
        if (msg != null) {
          onLog?.call('debug: ${asLogLine(msg)}');
        }
      },
      onPasswordRequest: localPassword != null
          ? () {
              onLog?.call('ssh_auth: Sending credentials');
              return localPassword;
            }
          // Asked only once the server did not take the key.
          : localPasswordAfterKey != null
              ? () => sendPasswordAfterKey(answerer, onLog)
              : null,
      // Keyboard-interactive (PAM, macOS, 2FA). Offered when there is a
      // saved password or someone to ask. The password goes only to a
      // prompt that isRealPasswordPrompt accepts: a 2FA "Verification code:"
      // is its own non-echoed prompt, and answering it with the password
      // would leak the password into the server's auth log. The worker path
      // (Design B) uses the same answerer, so the rules cannot drift.
      onUserInfoRequest: answerer.handler,
      onVerifyHostKey: (String type, Uint8List keyBlob) async {
        onLog?.call('ssh_hostkey: Verifying host key ($type)');
        final sshHostKey = SSHHostKey(type: type, bytes: keyBlob);
        // The clock stops while this is answered, as for a server's own
        // questions: where its person is asked whether to trust the key,
        // reading a fingerprint takes longer than a server is given to
        // reply, and the connection was closed under the question, before
        // sign-in (which a server logs, and may ban an address for).
        final bool accepted;
        try {
          accepted = await deadline.whileAsking(() => onHostKeyVerify(host, port, sshHostKey));
        } on HostKeyNotAccepted catch (e) {
          onLog?.call('ssh_hostkey: Host key REJECTED (${e.why.name})');
          rethrow;
        }
        onLog?.call(accepted
            ? 'ssh_hostkey: Host key accepted'
            : 'ssh_hostkey: Host key REJECTED');
        return accepted;
      },
      onAuthenticated: () {
        AppLogger.info('SSH authenticated to $host:$port');
        onLog?.call('ssh_auth: SSH_AUTH_SUCCESS - authenticated');
        // What was actually agreed, so a user can check the exchange (and
        // whether it was a post-quantum hybrid) from the connection log on
        // every platform, not only the desktop details panel.
        final kex = negotiatedKex;
        if (kex != null && kex.isNotEmpty) {
          final pq = SSHKexType.isPostQuantumName(kex) ? ' (post-quantum hybrid)' : '';
          onLog?.call('ssh_kex: Negotiated $kex$pq, '
              'cipher ${negotiatedCipher ?? '?'}, host key ${negotiatedHostKeyAlgorithm ?? '?'}');
        }
        forwardDebugToLog = false;
      },
      // S2: the effective keepalive is resolved by the caller (connection
      // value else the global setting). A value of 0 means the user disabled
      // keepalive - pass null so the core skips SSHKeepAlive entirely rather
      // than flooring to a minimum.
      keepAliveInterval:
          keepAliveSeconds > 0 ? Duration(seconds: keepAliveSeconds) : null,
    );

    // Why the connection ends, once it does: the transport's error when the
    // network broke, nothing when the host closed it (ShellEndReason).
    _client!.done.then(
      (_) => _endedItselfOrAtAJumpHost(hostClosedConnection),
      onError: (Object error) {
        // What exactly ended it is for the log; what the session says of
        // it is the app's to word.
        final line = endLogLine(error);
        if (line != null) onLog?.call(line);
        _endedItselfOrAtAJumpHost(endReasonOf(error));
      },
    );

    // Explicitly await authentication with a tight timeout.
    // This ensures wrong-password failures surface within seconds
    // rather than waiting for the full connection timeout or
    // server disconnect. dartssh2's `authenticated` future resolves
    // quickly when the server sends SSH_MSG_USERAUTH_FAILURE.
    try {
      await deadline.wait(links.orCancelled(_client!.authenticated));
      // Belt and braces with onAuthenticated: whichever fires first turns
      // the protocol-trace forwarding off.
      forwardDebugToLog = false;
    } catch (e) {
      final cancelled = answerer.cancelled || links.cancelled;
      if (!cancelled) {
        // Log the full error chain for debugging
        AppLogger.error('SSH auth failed: $e');
        onLog?.call('error: Auth failed - $e');
        if (e is SSHAuthAbortError && e.reason != null) {
          onLog?.call('error: Underlying cause - ${asLogLine('${e.reason}')}');
          AppLogger.error('SSH auth underlying cause: ${e.reason}');
        }
      }
      // Clean up the client on auth failure before rethrowing
      _clearCredentials();
      _client?.close();
      _client = null;
      // The person cancelled the server's question, or at its banner's link:
      // a cancel, not a failure.
      if (cancelled) throw const SshPromptCancelled();
      // So is closing the sheet that waits for a security key (a phone): the
      // key's sign-in was ended for good, so nothing else was tried, and it
      // is said as a cancel.
      if (e is FidoSignInAborted && e.failure.kind == FidoFailureKind.cancelled) throw const SshPromptCancelled();
      // What stopped the password saved with the key from going (an
      // Orchard's rule, or its person cancelling), or a question (a run with
      // nobody there to answer it): said as that.
      final stopped = answerer.stoppedBy;
      if (stopped != null) throw stopped;
      rethrow;
    } finally {
      // Close any question still showing: the sign-in is over either way.
      if (!questionsWithdrawn.isCompleted) questionsWithdrawn.complete();
    }

    // Security: drop credential references now that auth is complete.
    // The SSH library no longer needs the password or key material.
    _clearCredentials();
  }

  /// [_authenticate], and where that fails, nothing this connection holds
  /// stays open. Whoever asked for the connection gets the failure and lets
  /// go of the service: the jump hosts it came through stayed signed in and
  /// kept alive after a sign-in that the host refused, with nothing left to
  /// close them. And where the connection to one of those jump hosts has
  /// ended by itself, that is the failure ([JumpHostEndedOnTheWay]): this
  /// connection saw its line close, which read as the host closing the
  /// connection before the sign-in was over.
  Future<void> _authenticateOrClose() async {
    _watchJumpHosts();
    try {
      await _authenticate();
    } catch (e) {
      final atJumpHost = await _jumpHostEndedOnTheWay(e);
      await disconnect();
      if (atJumpHost != null) throw atJumpHost;
      rethrow;
    }
  }

  @override
  Future<void> connect() async {
    await _authenticateOrClose();

    onLog?.call('ssh_channel: Opening PTY (xterm-256color)');
    try {
      _shell = await _client!.shell(
        pty: const SSHPtyConfig(type: 'xterm-256color'),
      );
    } catch (e) {
      // Signed in, and then no shell. Whoever asked for this connection gets
      // the failure and lets go of the service, so nothing would ever close
      // what is open by now: the connection, signed in and kept alive, and
      // the jump hosts it came through. They are closed here.
      onLog?.call('ssh_channel: No session - $e');
      final atJumpHost = await _jumpHostEndedOnTheWay(e);
      await disconnect();
      if (atJumpHost != null) throw atJumpHost;
      final noSession = SshNoSessionException.of(e);
      if (noSession != null) throw noSession;
      rethrow;
    }

    _isConnected = true;
    _connectionStateController.add(true);
    onLog?.call('ssh_session: Shell session established');
    AppLogger.info('SSH connected to $host:$port');

    _showBanner();

    // Forward shell stdout/stderr to our broadcast streams
    _stdoutSubscription = _shell!.stdout.listen(
      (data) => _stdoutController.add(data),
      onDone: _onShellOutputDone,
      onError: (error) {
        AppLogger.error('SSH stdout error', error);
        _ended('$error');
        _onDisconnected();
      },
    );

    _stderrSubscription = _shell!.stderr.listen(
      (data) => _stderrController.add(data),
    );
  }

  /// The login banner, first, dimmed, so it reads as the server's notice and
  /// not as shell output. The text is server-controlled: control bytes and
  /// escape sequences are stripped (OpenSSH does the same) so a hostile
  /// banner cannot drive the terminal.
  void _showBanner() {
    final banner = _pendingBanner;
    _pendingBanner = null;
    if (banner != null && banner.trim().isNotEmpty) {
      final clean = banner
          .replaceAll('\r\n', '\n')
          .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '')
          .trimRight()
          .replaceAll('\n', '\r\n');
      _stdoutController.add(
          Uint8List.fromList(utf8.encode('\x1b[2m$clean\x1b[0m\r\n')));
    }
  }

  /// Authenticate WITHOUT opening a PTY shell - used by the agentless Server
  /// Monitor poller, which runs one-shot stat commands via [client].execute()
  /// and never needs an interactive terminal (no PTY, so it never counts
  /// against the terminal-session cap). Reuses the EXACT socket / algorithm /
  /// host-key / userauth path as [connect]; the only difference is the absent
  /// shell() + stdout/stderr wiring. On success [client] is ready for
  /// [SSHClient.execute]; the caller owns teardown via [disconnect].
  Future<void> connectExec() async {
    await _authenticateOrClose();
    _isConnected = true;
    _connectionStateController.add(true);
    AppLogger.info('SSH exec-client ready for $host:$port (no PTY)');
  }

  /// The address this connection reached when it was made directly (no jump
  /// host, no tunnel): what [host] was resolved to and connected to. Null
  /// through a jump host or a tunnel, whose socket's peer is not the host.
  ///
  /// A proxied connection (SOCKS, HTTP CONNECT) must give null too, as a jump
  /// host does: its socket's peer is the proxy, and a built-in Mosh session
  /// sends its UDP to this address. The app has no such proxy today (Connect
  /// Via is a jump host, which comes in as [tunnelSocket]); one added later
  /// opens its socket as a tunnel does, or with one that is not an
  /// [SSHSocketPeer] (test/services/ssh_peer_address_test.dart holds this).
  String? get peerAddress => _peerAddress;
  String? _peerAddress;

  /// Whether this connection was made for files only ([connectForFiles]).
  bool get filesOnly => _filesOnly;
  bool _filesOnly = false;

  /// Signs in as [connect] does, and asks for no terminal and no shell: a
  /// session that is files only (an SFTP-only host, or "Open its files"),
  /// whose SFTP is opened on [client]. Unlike [connectExec] it is a session
  /// that stays: its end is said on [connectionState] as a dropped one is (a
  /// network that breaks, a host that closes it), and the host's notice
  /// before sign-in is shown, dimmed, as [connect] shows it, followed by
  /// [notice] (the app's own line saying the session is files only), so the
  /// session's terminal is never blank. Typing into it goes nowhere: there
  /// is no shell to take it.
  Future<void> connectForFiles({String? notice}) async {
    _filesOnly = true;
    await _authenticateOrClose();
    onLog?.call('ssh_session: Signed in for files only (SFTP): no terminal is asked for');
    _isConnected = true;
    _connectionStateController.add(true);
    AppLogger.info('SSH connected to $host:$port for files only (no PTY, no shell)');
    _showBanner();
    if (notice != null && notice.isNotEmpty) {
      _stdoutController.add(Uint8List.fromList(utf8.encode('\x1b[2m$notice\x1b[0m\r\n')));
    }
    // With no shell, the end of the connection itself is the end of the
    // session: the host closing it, or the network breaking under it.
    _client!.done.then((_) => _onDisconnected(), onError: (Object _) => _onDisconnected());
  }

  /// Signs in as [connect] does, for a remote screen (4.0) reached through
  /// this host: no terminal, no shell and no SFTP are asked for. The screen's
  /// channel is opened on [client] (direct-tcpip or direct-streamlocal), so
  /// no port is listened on here. The host's notice before sign-in is not
  /// shown: a screen has no terminal to show it in. The end of the
  /// connection is said on [connectionState], as a dropped one is.
  Future<void> connectForScreen() async {
    await _authenticateOrClose();
    onLog?.call('ssh_session: Signed in to reach a remote screen: no terminal or shell is asked for');
    _isConnected = true;
    _connectionStateController.add(true);
    AppLogger.info('SSH connected to $host:$port to carry a remote screen (no PTY, no shell)');
    _client!.done.then((_) => _onDisconnected(), onError: (Object _) => _onDisconnected());
  }

  /// The shell's output is over. How the shell ended is said before that (an
  /// exit status, a signal). Where the host said nothing of it, what is
  /// left to know is whether it closed the session in order (there are
  /// hosts that report no exit status at all) or the connection ended under
  /// the session: that is known once the session's channel is over, which is
  /// with the end of its output or a moment after.
  Future<void> _onShellOutputDone() async {
    final shell = _shell;
    var closedInOrder = false;
    if (shell != null && shell.exitCode == null && shell.exitSignal == null) {
      final over = await shell.done.then((_) => true).timeout(const Duration(seconds: 2), onTimeout: () => false);
      closedInOrder = over && shell.endedBecause == null;
    }
    _onDisconnected(closedInOrder: closedInOrder);
  }

  void _onDisconnected({bool closedInOrder = false}) {
    if (_isConnected) {
      _isConnected = false;
      _keepAliveTimer?.cancel();
      _keepAliveTimer = null;
      // Capture WHY we're disconnecting before notifying. A non-null
      // exitCode or exitSignal means the remote shell process itself
      // ended (exit / Ctrl+D / killed), and so does a session the host
      // closed in order with nothing said of how: the shell ended by
      // itself. A channel that ended with its connection is an unexpected
      // transport drop that should auto-reconnect.
      _exitCode = _shell?.exitCode;
      _exitSignal = _shell?.exitSignal?.signalName;
      _exitedCleanly = _exitCode != null || _exitSignal != null || closedInOrder;
      _connectionStateController.add(false);
      AppLogger.info(
        'SSH disconnected from $host:$port '
        '(exitedCleanly=$_exitedCleanly, exitCode=$_exitCode)',
      );
    }
  }

  bool _exitedCleanly = false;
  int? _exitCode;
  String? _exitSignal;

  @override
  bool get exitedCleanly => _exitedCleanly;

  @override
  int? get exitCode => _exitCode;

  @override
  String? get exitSignal => _exitSignal;

  final _endReason = Completer<String?>();

  @override
  Future<String?> get endReason => _endReason.future;

  @override
  Future<String?> runOnce(String command, {Duration timeout = const Duration(seconds: 10)}) async {
    try {
      // Read whole before it is decoded: a character's bytes may come in
      // two pieces. For so long and no longer, and so much and no more: a
      // timeout alone stopped only the wait, and what the host went on
      // sending went on piling up.
      final bytes = await client.runCapped(CommandText.script(command), maxBytes: runOnceMaxBytes, timeout: timeout);
      return utf8.decode(bytes, allowMalformed: true).trim();
    } catch (_) {
      return null;
    }
  }

  /// The most of a command's answer that [runOnce] reads.
  static const int runOnceMaxBytes = 1024 * 1024;

  void _ended(String? reason) {
    if (!_endReason.isCompleted) _endReason.complete(reason);
  }

  /// What each jump host's connection ended with, once it has (null: it
  /// was closed with nothing said), in the order of [jumpClients].
  var _jumpEnds = const <Future<Object?>>[];

  /// Which of the jump hosts' connections had ended when this connection
  /// closed them all ([_closeJumpHosts]): those ended by themselves. Null
  /// until then.
  List<bool>? _endedBeforeClosing;

  /// How long the end of this connection waits to hear that a jump host's
  /// connection ended, where none has: a jump host can close the way on a
  /// moment before it ends its connection.
  static const _jumpHostEndWait = Duration(milliseconds: 300);

  /// Watches each jump host's connection for its end, and says in the log
  /// of one that ends by itself (not of those this session closes when it
  /// is closed).
  void _watchJumpHosts() {
    _jumpEnds = [
      for (var at = 0; at < jumpClients.length; at++)
        jumpClients[at].done.then<Object?>((_) => null, onError: (Object error) => error).then((error) {
          if (_endedByItself(at)) onLog?.call(jumpHostEndLogLine(_jumpLabel(at), error));
          return error;
        }),
    ];
  }

  /// Whether the connection to the jump host at [at] has ended, and not by
  /// this session being closed.
  bool _endedByItself(int at) => _endedBeforeClosing?[at] ?? jumpClients[at].isClosed;

  String _jumpLabel(int at) => at < jumpLabels.length && jumpLabels[at].trim().isNotEmpty
      ? jumpLabels[at]
      : '${at + 1}';

  /// This connection has ended, for [reason] as far as it knows itself.
  /// Where it came through jump hosts and the connection to one of them
  /// has ended by itself, that is why, and is what is said
  /// ([endedAtJumpHost]): the way on went with it, and this connection saw
  /// no more than that its line closed. Of several that ended it is the
  /// one furthest from the host, whose end took the others with it: a
  /// connection is marked as ended before the ways it carries are closed,
  /// so this does not depend on which of them is heard of first.
  Future<void> _endedItselfOrAtAJumpHost(String reason) async {
    if (jumpClients.isNotEmpty && !_disposed && !jumpClients.any((c) => c.isClosed)) {
      await Future.any<void>([..._jumpEnds, Future<void>.delayed(_jumpHostEndWait)]);
    }
    final jump = await _jumpHostThatEnded();
    final error = jump?.error;
    _ended(jump == null
        ? reason
        : endedAtJumpHost(jump.label, error == null ? hostClosedConnection : endReasonOf(error)));
    // Whoever held this connection lets go of it once it has ended (a
    // session that dropped keeps nothing of it): the jump hosts it came
    // through stayed signed in and kept alive, with nothing left to close
    // them, and each time the session was connected to again one more
    // connection was made to each of them.
    _closeJumpHosts();
  }

  /// Closes the connections to the jump hosts, nearest the host first (each
  /// carries the way to the one before it), having noted which of them had
  /// ended by themselves ([_endedByItself]). Closing one that is closed
  /// does nothing.
  void _closeJumpHosts() {
    _noteEndedByThemselves();
    for (final c in jumpClients) {
      try {
        c.close();
      } catch (_) {
        // A connection that is closed already may say so; it is closed.
      }
    }
  }

  /// Before this connection closes anything itself: which jump hosts'
  /// connections have ended by themselves. The first note stands.
  void _noteEndedByThemselves() => _endedBeforeClosing ??= [for (final c in jumpClients) c.isClosed];

  /// The jump host whose connection has ended by itself, and what it ended
  /// with (null: closed, with nothing said): of several, the one furthest
  /// from the host. Null where none has.
  Future<({String label, Object? error})?> _jumpHostThatEnded() async {
    for (var at = jumpClients.length - 1; at >= 0; at--) {
      if (_endedByItself(at)) return (label: _jumpLabel(at), error: await _jumpEnds[at]);
    }
    return null;
  }

  /// What connecting failed with where the connection to a jump host on
  /// the way has ended by itself: that, and not [during], which is all this
  /// connection knows of it. Null where none has.
  Future<JumpHostEndedOnTheWay?> _jumpHostEndedOnTheWay(Object during) async {
    final jump = await _jumpHostThatEnded();
    return jump == null ? null : JumpHostEndedOnTheWay(label: jump.label, cause: jump.error, during: during);
  }

  @override
  bool get isEncryptedSsh => true;

  @override
  void write(Uint8List data) => _shell?.write(data);

  @override
  void resize(int width, int height) {
    _shell?.resizeTerminal(width, height);
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _disposed = true;
    // Before anything is closed here: which jump hosts' connections have
    // ended by themselves (_endedByItself).
    _noteEndedByThemselves();
    AppLogger.info('SSH disconnecting from $host:$port');
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    // Cancel subscriptions before closing the shell to avoid StateError
    // on broadcast controllers when listeners fire during shutdown.
    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _shell?.close();
    _client?.close();
    // Tear down the jump chain in order - nearest first.  Each
    // .close() drops the SSH transport AND closes any forwarded
    // sockets it owns (which is how the next hop in the chain is
    // kept alive), so closing the head ripples down the chain.
    _closeJumpHosts();
    _onDisconnected();
    // Close broadcast controllers to release listener resources.
    // The _disposed flag prevents double-close on rapid disconnect calls.
    _stdoutController.close();
    _stderrController.close();
    _connectionStateController.close();
  }

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;
}

/// Minimal wrapper for host key data from dartssh2.
class SSHHostKey {
  final String type;
  final Uint8List bytes;

  const SSHHostKey({required this.type, required this.bytes});
}
