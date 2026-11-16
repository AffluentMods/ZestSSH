import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zest_native/mosh.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/mosh/mosh_bootstrap.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// How a built-in Mosh session hears from its server: what the session's
/// chrome shows as "last contact" when the server has gone quiet.
@immutable
class MoshLink {
  const MoshLink({this.lastHeard, this.srttMs});

  /// How long ago the server was last heard; null before it answered.
  final Duration? lastHeard;

  /// The smoothed round trip, in milliseconds.
  final int? srttMs;

  /// Silence after which "last contact" is shown: the server's heartbeat
  /// comes every 3 seconds, so this is three missed (and the app's words for
  /// a time say seconds from 10 on).
  static const quietAfter = Duration(seconds: 10);

  /// Whether the server has gone quiet long enough to say so.
  bool get quiet => lastHeard != null && lastHeard! >= quietAfter;

  @override
  bool operator ==(Object other) => other is MoshLink && other.lastHeard == lastHeard && other.srttMs == srttMs;

  @override
  int get hashCode => Object.hash(lastHeard, srttMs);
}

/// A shell whose Mosh link can be watched (the built-in client's).
abstract interface class MoshLinkSource {
  ValueListenable<MoshLink> get moshLink;
}

/// Why a built-in Mosh session failed once mosh-server had started.
enum MoshSessionProblem {
  /// Nothing came back over UDP: a firewall, most often.
  noAnswer,

  /// The server speaks another protocol version, or the key was refused, or
  /// the client stopped by itself.
  failed,

  /// No UDP socket could be opened on this device.
  network,
}

class MoshSessionFailure implements Exception, HasTypeName {
  const MoshSessionFailure(this.problem, {this.port, this.detail = ''});
  final MoshSessionProblem problem;

  /// The UDP port mosh-server listened on.
  final int? port;

  /// What the client said (English, for the details; no key in it).
  final String detail;

  ErrorCode get code => switch (problem) {
        MoshSessionProblem.noAnswer => ErrorCodes.moshNoAnswer,
        MoshSessionProblem.failed || MoshSessionProblem.network => ErrorCodes.moshSessionFailed,
      };

  @override
  String toString() => 'MoshSessionFailure: ${problem.name}${detail.isEmpty ? '' : ': $detail'}';

  @override
  String get typeName => 'MoshSessionFailure';
}

/// The words for [e], in the person's language, with its code.
String moshSessionFailureText(AppLocalizations l10n, MoshSessionFailure e) {
  final said = switch (e.problem) {
    MoshSessionProblem.noAnswer => l10n.connMoshNoAnswer('${e.port ?? 0}'),
    MoshSessionProblem.failed || MoshSessionProblem.network => l10n.connMoshSessionFailed,
  };
  final text = ErrorCodes.withCode(said, e.code);
  return e.detail.isEmpty ? text : '$text\n\n${e.detail}';
}

/// Where a built-in Mosh session's server is: started over SSH, with the
/// addresses its UDP may be sent to.
typedef MoshServerReady = ({MoshServerStart start, List<String> addresses});

/// A Mosh session through the app's own client (4.0): mosh-server is started
/// over SSH by [bootstrap] (which closes its SSH connection when it is
/// done), then the Rust client ([native]) speaks Mosh to it over UDP. The
/// server's screen comes out of [stdout] as terminal output; typing and the
/// terminal's size go to the server. The session survives a change of
/// network (roaming) and sleep; while the server is not heard, [moshLink]
/// says for how long.
///
/// No local echo prediction yet: what is typed shows when the server has
/// echoed it, as over SSH.
class BuiltinMoshService implements ShellService, ShellEndReason, MoshLinkSource {
  BuiltinMoshService({
    required this.bootstrap,
    MoshNative? native,
    this.onLog,
    this.firstAnswer = const Duration(seconds: 15),
  }) : native = native ?? RustMoshNative();

  /// Starts mosh-server and says where it is.
  final Future<MoshServerReady> Function() bootstrap;
  final MoshNative native;
  final ConnectionLogCallback? onLog;

  /// How long the server's first answer over UDP is waited for.
  final Duration firstAnswer;

  final _stdout = StreamController<Uint8List>.broadcast();
  final _stderr = StreamController<Uint8List>.broadcast();
  final _state = StreamController<bool>.broadcast();
  final _link = ValueNotifier<MoshLink>(const MoshLink());
  final _endReason = Completer<String?>();
  int _handle = 0;
  bool _connected = false;
  bool _exitedCleanly = false;
  bool _closing = false;
  int _cols = 80;
  int _rows = 24;
  Completer<void>? _answered;
  final _closed = Completer<Map<String, Object?>>();
  int? _port;

  @override
  ValueListenable<MoshLink> get moshLink => _link;

  @override
  Future<void> connect() async {
    final ready = await bootstrap();
    _port = ready.start.port;
    onLog?.call('mosh: Speaking Mosh to ${ready.addresses.length == 1 ? 'the host' : '${ready.addresses.length} addresses of the host'} '
        'on UDP port ${ready.start.port} (the built-in client)');
    final request = jsonEncode({
      'addresses': ready.addresses,
      'port': ready.start.port,
      'key': ready.start.key,
      'cols': _cols,
      'rows': _rows,
      'first_answer_ms': firstAnswer.inMilliseconds,
    });
    _answered = Completer<void>();
    _handle = native.open(request, _onEvent);
    if (_handle == 0) {
      throw const MoshSessionFailure(MoshSessionProblem.failed, detail: 'the Mosh client refused to start');
    }
    // The first answer, or the end (the client gives up after [firstAnswer]).
    await Future.any([_answered!.future, _closed.future]);
    if (!_connected) {
      throw _failureOf(await _closed.future);
    }
  }

  MoshSessionFailure _failureOf(Map<String, Object?> closed) {
    final message = '${closed['message'] ?? ''}';
    return switch (closed['reason']) {
      'no_answer' => MoshSessionFailure(MoshSessionProblem.noAnswer, port: _port, detail: message),
      'network' => MoshSessionFailure(MoshSessionProblem.network, detail: message),
      _ => MoshSessionFailure(MoshSessionProblem.failed, detail: message),
    };
  }

  void _onEvent(int kind, int a, Uint8List? data) {
    switch (kind) {
      case MoshEventKind.hostBytes:
        if (data != null && !_stdout.isClosed) _stdout.add(data);
      case MoshEventKind.connected:
        _connected = true;
        _link.value = MoshLink(lastHeard: Duration.zero, srttMs: _link.value.srttMs);
        onLog?.call('mosh: The host answered over UDP');
        if (!_state.isClosed) _state.add(true);
        if (!(_answered?.isCompleted ?? true)) _answered!.complete();
      case MoshEventKind.status:
        final s = _json(data);
        final heard = s['last_heard_ms'];
        final srtt = s['srtt_ms'];
        _link.value = MoshLink(
          lastHeard: heard is int ? Duration(milliseconds: heard) : null,
          srttMs: srtt is int ? srtt : null,
        );
      case MoshEventKind.info:
        final s = _json(data);
        if (s.containsKey('new_local_port')) onLog?.call('mosh: No contact for a while: sending from a new local port');
        final foreign = s['foreign'];
        if (foreign is int && foreign > 0) {
          onLog?.call("mosh: $foreign datagrams from an address that is not the host's were dropped unopened");
        }
      case MoshEventKind.closed:
        final s = _json(data);
        AppLogger.info('Mosh session closed: ${s['reason']}');
        if (!_closed.isCompleted) _closed.complete(s);
        if (_connected) _ended(s);
        // CLOSED is the client's last word: its callback can go.
        native.release(_handle);
    }
  }

  static Map<String, Object?> _json(Uint8List? data) {
    if (data == null) return const {};
    try {
      final v = jsonDecode(utf8.decode(data));
      return v is Map<String, Object?> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  void _ended(Map<String, Object?> closed) {
    if (!_connected) return;
    _connected = false;
    final reason = closed['reason'];
    // The shell on the host ended (exit, Ctrl+D): the session closes as an
    // SSH one does when its shell ends.
    _exitedCleanly = reason == 'server_closed' || reason == 'local';
    if (!_endReason.isCompleted) {
      _endReason.complete(switch (reason) {
        'server_closed' => hostClosedConnection,
        'local' => null,
        _ => '${closed['message'] ?? reason}',
      });
    }
    if (!_state.isClosed) _state.add(false);
  }

  @override
  void write(Uint8List data) {
    if (_handle != 0 && !_closing) native.keys(_handle, data);
  }

  @override
  void resize(int width, int height) {
    if (width <= 0 || height <= 0) return;
    if (width == _cols && height == _rows && _handle != 0) return;
    _cols = width;
    _rows = height;
    if (_handle != 0 && !_closing) native.resize(_handle, width, height);
  }

  @override
  Future<void> disconnect() async {
    if (_closing) return;
    _closing = true;
    if (_handle != 0 && !_closed.isCompleted) {
      native.close(_handle);
      // The client tells the server, which ends the shell, and waits for
      // its word up to two seconds.
      await _closed.future.timeout(const Duration(seconds: 3), onTimeout: () => const {'reason': 'local'});
    }
    if (_connected) _ended(const {'reason': 'local'});
    if (!_endReason.isCompleted) _endReason.complete(null);
    await _stdout.close();
    await _stderr.close();
    await _state.close();
  }

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => _exitedCleanly;

  @override
  Future<String?> get endReason => _endReason.future;

  @override
  bool get isEncryptedSsh => false;
}

/// Whether this device opens Mosh hosts with the app's own client: always on
/// a phone, a tablet and Windows (they have no mosh program of their own to
/// run, or only through WSL); on a Mac and Linux unless Settings says to use
/// the mosh program installed there ([preferSystem]).
bool moshUsesBuiltIn({required bool preferSystem}) {
  if (Platform.isAndroid || Platform.isIOS || Platform.isWindows) return true;
  return !preferSystem;
}

/// Whether Settings offers the choice of the system's mosh program: on a Mac
/// and on Linux only.
bool get moshSystemClientOffered => Platform.isMacOS || Platform.isLinux;

/// Where a Mosh session's UDP goes: the address the SSH connection reached
/// ([sshPeer]), alone, when it was made directly. mosh-server binds to the
/// address SSH came in on (`-s`), and a second lookup of the name could
/// give another one. Through a jump host the SSH connection's peer is the
/// jump host, so [host] is resolved on this device instead
/// ([moshAddressesOf]), and the log says so.
Future<List<String>> moshUdpAddresses({
  required String? sshPeer,
  required String host,
  Future<List<InternetAddress>> Function(String host)? lookup,
  ConnectionLogCallback? onLog,
}) async {
  if (sshPeer != null && sshPeer.isNotEmpty) {
    onLog?.call('mosh: UDP goes to $sshPeer, the address the SSH connection reached');
    return [sshPeer];
  }
  onLog?.call('mosh: Through a jump host: UDP goes to what $host resolves to on this device');
  return moshAddressesOf(host, lookup: lookup);
}

/// The addresses a Mosh session's UDP goes to for [host] when no SSH
/// connection reached it directly (through a jump host): the host itself
/// where it is an address, else what its name resolves to here, in order
/// (the client sends to all of them until one answers, and then to that one
/// alone), four at most.
Future<List<String>> moshAddressesOf(String host, {Future<List<InternetAddress>> Function(String host)? lookup}) async {
  final bare = host.startsWith('[') && host.endsWith(']') ? host.substring(1, host.length - 1) : host;
  final literal = InternetAddress.tryParse(bare);
  if (literal != null) return [literal.address];
  final List<InternetAddress> found;
  try {
    found = await (lookup ?? InternetAddress.lookup)(bare);
  } on SocketException catch (e) {
    throw MoshSessionFailure(MoshSessionProblem.network, detail: 'the host name did not resolve: ${e.message}');
  }
  final out = <String>[];
  for (final a in found) {
    if (!out.contains(a.address)) out.add(a.address);
    if (out.length == 4) break;
  }
  if (out.isEmpty) throw const MoshSessionFailure(MoshSessionProblem.network, detail: 'the host name did not resolve');
  return out;
}
