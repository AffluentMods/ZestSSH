import 'dart:async';

import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/utils/error_translator.dart' as translator show ConnectionError, ConnectionErrorType;
import 'package:zestssh/utils/type_name.dart';

/// Why a session picked for a file pane did not become ready: [said] in the
/// app's language, [happened] what happened, for the report. (3.0: before,
/// it was English made up on the spot, "Session vanished", "SSH session
/// disconnected before SFTP open", shown as it was.)
class SessionNotReady implements Exception, HasTypeName {
  const SessionNotReady(this.said, this.happened);

  final String said;
  final String happened;

  @override
  String toString() => happened;

  @override
  String get typeName => 'SessionNotReady';
}

/// Waits until the session [read] gives is connected and returns it, or
/// throws [SessionNotReady]: it is gone, it failed to connect (said as its
/// connection failure is said), it disconnected, or it is not connected by
/// [timeout]. [read] is asked every [every].
Future<SessionState> waitForSessionReady(
  SessionState? Function() read, {
  Duration timeout = const Duration(seconds: 30),
  Duration every = const Duration(milliseconds: 200),
}) async {
  final stopAt = DateTime.now().add(timeout);
  while (true) {
    final state = read();
    if (state == null) {
      throw SessionNotReady(gl10n.sftpSessionClosedBeforeOpen, 'The session was closed while it connected');
    }
    if (state.status == SessionStatus.connected) return state;
    if (state.status == SessionStatus.error) {
      final raw = state.errorMessage ?? '';
      final why = translator.ConnectionError.translate(
        raw,
        host: state.host,
        port: state.port,
        username: state.username,
      );
      // What the app itself said is the message: its title only says that
      // the connection failed.
      final said = why.type == translator.ConnectionErrorType.saidByApp ? why.description : why.title;
      throw SessionNotReady(said, raw.isEmpty ? 'The connection failed' : raw);
    }
    if (state.status == SessionStatus.disconnected) {
      throw SessionNotReady(gl10n.sftpSessionClosedBeforeOpen, 'The session disconnected before SFTP opened');
    }
    if (DateTime.now().isAfter(stopAt)) {
      throw SessionNotReady(
        gl10n.sftpSessionNotConnectedYet,
        'The session was not connected after ${timeout.inSeconds} s',
      );
    }
    await Future<void>.delayed(every);
  }
}
