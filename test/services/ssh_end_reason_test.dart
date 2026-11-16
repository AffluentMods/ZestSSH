import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart' show connectionTestFailed;
import 'package:zestssh/utils/error_translator.dart';

import '../helpers/editor_test_said.dart';

/// A host that ends the connection and says why (3.0, from the SSH core's
/// audit): before it closes a connection of its own accord, a server says
/// so, with a reason in words. The SSH library dropped that unread, and the
/// app could say only that the connection had closed. The reason is kept
/// now, and said as what it is: the host's own words, where they came under
/// keys whose host key was approved, and what somebody sent, where they
/// came before that.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  final esc = String.fromCharCode(0x1b);
  final bell = String.fromCharCode(0x07);
  final csi = String.fromCharCode(0x9b);
  final lineSeparator = String.fromCharCode(0x2028);
  final paragraphSeparator = String.fromCharCode(0x2029);
  // "Read what follows from right to left", and the end of an isolate.
  final turnAround = String.fromCharCode(0x202e);
  final endOfIsolate = String.fromCharCode(0x2069);

  /// Whether [text] is text and nothing else.
  bool plain(String text) => text.runes.every((c) =>
      c >= 0x20 &&
      c != 0x7f &&
      !(c >= 0x80 && c <= 0x9f) &&
      c != 0x2028 &&
      c != 0x2029 &&
      !(c >= 0x202a && c <= 0x202e) &&
      !(c >= 0x2066 && c <= 0x2069));

  test('why a connection ended, as a session keeps it', () {
    expect(endReasonOf(SSHNoAnswerError(const Duration(seconds: 90), 3)), hostStoppedAnswering);

    final said = endReasonOf(SSHDisconnectError(11, 'Idle timeout: closing the session', authentic: true));
    expect(said, 'The host ended the connection: Idle timeout: closing the session');
    expect(hostSaid(said), 'Idle timeout: closing the session');

    // No words of its own: a host that closed the connection.
    expect(endReasonOf(SSHDisconnectError(11, '', authentic: true)), hostClosedConnection);
    expect(endReasonOf(SSHDisconnectError(11, ' \r\n\t', authentic: true)), hostClosedConnection);

    // Words that are not known to be the host's are never said as its own.
    // (A session is under keys whose host key was approved: this cannot be
    // what ends one, and is held all the same.)
    final sent = endReasonOf(SSHDisconnectError(11, 'Idle\r\ntimeout', authentic: false));
    expect(sent, 'The connection was ended before the server was verified, with: Idle timeout (reason code 11)');
    expect(hostSaid(sent), isNull);

    // Anything else is what the library says of it.
    final reset = SSHSocketError(const SocketException('Connection reset by peer'));
    expect(endReasonOf(reset), '$reset');
    for (final other in [null, hostClosedConnection, hostStoppedAnswering, '$reset', 'the host ended the connection: x']) {
      expect(hostSaid(other), isNull, reason: '$other');
    }
  });

  test('what a host wrote is shown on one line, with nothing in it that steers a terminal or turns the sentence '
      'around, and not without end', () {
    expect(shownHostText('Too many authentication failures'), 'Too many authentication failures');
    expect(shownHostText('  Maintenance at 22:00.\r\n\tSave your work.\n'), 'Maintenance at 22:00. Save your work.');
    // An escape sequence that would clear a terminal, a bell, and a control of the second set.
    expect(shownHostText('Locked$esc[2J out$bell${csi}31m now'), 'Locked [2J out 31m now');
    // Separators that end a line where a line feed is not let through.
    expect(shownHostText('Locked${lineSeparator}out${paragraphSeparator}now'), 'Locked out now');
    // What turns the text around is taken out, with no space in its place.
    expect(shownHostText('Access ${turnAround}den${endOfIsolate}ied'), 'Access denied');
    expect(shownHostText(''), '');
    expect(shownHostText(' \n '), '');
    expect(shownHostText('$turnAround$endOfIsolate'), '');
    // The character that deletes, between two sets of letters.
    expect(shownHostText('Locked${String.fromCharCode(0x7f)}out'), 'Locked out');
    final long = shownHostText('x' * 500);
    expect(long, hasLength(200));
    expect(long, endsWith('xxx...'));
    expect(shownHostText('x' * 200), 'x' * 200);
    expect(shownHostText('x' * 201), '${'x' * 197}...');
    // Letters of any alphabet stay, and so does what joins them: a word of
    // Persian with the mark that keeps two of its letters apart.
    final greeting = String.fromCharCodes([0x417, 0x430, 0x43a, 0x440, 0x44b, 0x442, 0x43e]);
    expect(shownHostText(greeting), greeting);
    final joined = String.fromCharCodes([0x645, 0x6cc, 0x200c, 0x62e, 0x648, 0x627, 0x647, 0x645]);
    expect(shownHostText(joined), joined);
  });

  test('a line of a connection\'s log makes no lines of its own, whatever a host put into it', () {
    expect(asLogLine('SSHTransport.closeWithError x'), 'SSHTransport.closeWithError x');
    // A line feed and a made-up line behind it: one line still.
    final forged = asLogLine('closed\r\nssh_auth: SSH_AUTH_SUCCESS - authenticated$esc[2J$lineSeparator${turnAround}x');
    expect(forged, 'closed  ssh_auth: SSH_AUTH_SUCCESS - authenticated [2J x');
    expect(plain(forged), isTrue);
    // Spaces are left as they are: a log line is not a sentence.
    expect(asLogLine('a   b '), 'a   b ');
    final long = asLogLine('x' * 5000);
    expect(long, hasLength(2000));
    expect(long, endsWith('xxx...'));
    expect(asLogLine('x' * 2000), 'x' * 2000);
    expect(asLogLine('x' * 2001), '${'x' * 1997}...');
  });

  test('what goes into the log when a connection ended: how long nothing came, and a host\'s reason with its code',
      () {
    expect(endLogLine(SSHNoAnswerError(const Duration(seconds: 90), 3)), startsWith('ssh_keepalive: '));
    expect(endLogLine(SSHNoAnswerError(const Duration(seconds: 90), 3)), contains('90'));
    expect(
      endLogLine(SSHDisconnectError(11, 'Idle timeout:\r\nclosing$esc[2J the session', authentic: true)),
      'ssh_session: The server ended the connection: Idle timeout: closing [2J the session (reason code 11)',
    );
    expect(endLogLine(SSHDisconnectError(11, '', authentic: true)),
        'ssh_session: The server ended the connection (reason code 11)');
    // Anything else says itself in the reason the session keeps.
    expect(endLogLine(SSHSocketError(const SocketException('Connection reset by peer'))), isNull);
    expect(endLogLine(StateError('anything')), isNull);
  });

  test('a packet that did not pass its check is why the session ended, with the core\'s words in the log; a packet '
      'the host itself sent wrongly is what the library says of it, as it was', () {
    const theCoreSays = 'A packet from the other side did not pass its check: it was changed or damaged on the way, or '
        'the two sides do not protect their packets the same way';
    final damaged = SSHPacketError(theCoreSays, damaged: true);
    final wrong = SSHPacketError('Malformed packet: no length');
    expect(endReasonOf(damaged), hostDataDamaged);
    expect(endReasonOf(wrong), '$wrong');
    expect(endLogLine(damaged), 'ssh_session: $theCoreSays');
    expect(endLogLine(wrong), isNull);
    // It is no word of a host's, no session that a host ended, and not any other end the app knows.
    expect(hostSaid(hostDataDamaged), isNull);
    expect(sessionEnded(hostDataDamaged), isNull);
    expect(plain(hostDataDamaged), isTrue);
    expect({hostDataDamaged, hostKeyFailedAtNewKeys, hostClosedConnection, hostStoppedAnswering}, hasLength(4));
  });

  test('a host key that the SSH core refused by itself: when new keys are taken it is why the session ended, and '
      'at the start it is the key the connection was never made with', () {
    final atTheStart = SSHHostkeyError('Signature verification failed', fault: SSHHostkeyFault.notSigned);
    final notSigned =
        SSHHostkeyError('Signature verification failed', fault: SSHHostkeyFault.notSigned, duringRekey: true);
    final changed = SSHHostkeyError('Host key changed during re-key', fault: SSHHostkeyFault.changed, duringRekey: true);
    final noKey = SSHHostkeyError('could not be read', fault: SSHHostkeyFault.noKey, duringRekey: true);
    // On a connection that was open: why the session ended, whatever was wrong with the key.
    for (final later in [notSigned, changed, noKey]) {
      expect(endReasonOf(later), hostKeyFailedAtNewKeys, reason: later.message);
    }
    // At the start no session ends: it is what the library says of it, as it was.
    expect(endReasonOf(atTheStart), '$atTheStart');
    expect(endReasonOf(atTheStart), contains('Signature verification failed'));
    expect(endReasonOf(SSHHostkeyError('Hostkey verification failed')), 'SSHHostkeyError(Hostkey verification failed)');
    // It is no word of a host's, and no session that a host ended.
    expect(hostSaid(hostKeyFailedAtNewKeys), isNull);
    expect(sessionEnded(hostKeyFailedAtNewKeys), isNull);
    expect(plain(hostKeyFailedAtNewKeys), isTrue);
    expect({hostKeyFailedAtNewKeys, hostClosedConnection, hostStoppedAnswering}, hasLength(3));

    // What the core found goes into the log in its own words, and says when.
    expect(endLogLine(changed),
        'ssh_hostkey: Host key REJECTED when new keys were taken - Host key changed during re-key');
    expect(endLogLine(notSigned),
        'ssh_hostkey: Host key REJECTED when new keys were taken - Signature verification failed');
    expect(endLogLine(atTheStart), 'ssh_hostkey: Host key REJECTED - Signature verification failed');
    // A key that its person, or the check of the app, did not accept is in the log by then.
    expect(endLogLine(SSHHostkeyError('Hostkey verification failed')), isNull);
    expect(endLogLine(HostKeyNotAccepted(HostKeyRefusal.declinedNew, host: 'web-01.example.com', port: 22)), isNull);
    // Whatever is in the core's words makes no line of its own in the log.
    final named = SSHHostkeyError('The host key is of the kind x\r\nssh_auth: made up', fault: SSHHostkeyFault.noKey);
    expect(endLogLine(named), 'ssh_hostkey: Host key REJECTED - The host key is of the kind x  ssh_auth: made up');
    expect(endLogLine(SSHHostkeyError('x' * 5000, fault: SSHHostkeyFault.noKey)),
        hasLength('ssh_hostkey: Host key REJECTED - '.length + 2000));
    final namedLater = SSHHostkeyError('The host key is of the kind x\r\nssh_auth: made up',
        fault: SSHHostkeyFault.noKey, duringRekey: true);
    expect(endLogLine(namedLater),
        'ssh_hostkey: Host key REJECTED when new keys were taken - The host key is of the kind x  ssh_auth: made up');
  });

  test('a connection being made that the host ended with a reason: its reason, said as its own', () {
    final tooMany = SSHDisconnectError(2, 'Too many authentication failures', authentic: true);
    const sentence = 'The host ended the connection. Its reason: Too many authentication failures';
    // While signing in, and while the session was being set up.
    for (final failure in <Object>[SSHAuthAbortError('Connection closed before authentication', tooMany), tooMany]) {
      final kept = connectionFailureText(failure);
      expect(kept, '$kSaidByApp$sentence', reason: '$failure');
      final shown = ConnectionError.translate(kept, host: 'web-01', port: 22, username: 'deploy');
      expect(shown.type, ConnectionErrorType.saidByApp);
      expect(shown.description, sentence);
    }
    // What it wrote is shown as shownHostText shows it.
    expect(connectionFailureText(SSHDisconnectError(2, 'Too many\r\ntries', authentic: true)),
        '${kSaidByApp}The host ended the connection. Its reason: Too many tries');
    // Words of the host's that begin as the app's own mark does are still the host's.
    expect(connectionFailureText(SSHDisconnectError(2, '${kSaidByApp}all is well', authentic: true)),
        '${kSaidByApp}The host ended the connection. Its reason: ${kSaidByApp}all is well');
  });

  test('ended with a reason before the host\'s key was checked: said as what was sent, never as the host\'s', () {
    final sent = SSHDisconnectError(12, 'Too many connections.\r\nTry again later', authentic: false);
    const sentence = 'The connection was ended before the host\'s key was checked. The reason that was sent, which '
        'may not be the host\'s own: Too many connections. Try again later';
    for (final failure in <Object>[SSHAuthAbortError('Connection closed before authentication', sent), sent]) {
      final kept = connectionFailureText(failure);
      expect(kept, '$kSaidByApp$sentence', reason: '$failure');
      expect(kept, isNot(contains('Its reason')));
      final shown = ConnectionError.translate(kept, host: 'web-01', port: 22, username: 'deploy');
      expect(shown.type, ConnectionErrorType.saidByApp);
      expect(shown.description, sentence);
    }
  });

  test('ended with no words, or by something else: as before', () {
    for (final authentic in [true, false]) {
      final silent = SSHAuthAbortError(
          'Connection closed before authentication', SSHDisconnectError(11, ' \r\n', authentic: authentic));
      expect(connectionFailureText(silent), '$silent');
      expect(ConnectionError.translate('$silent', host: 'web-01').type, ConnectionErrorType.authFailed);
    }
    final plainEnd = SSHAuthAbortError('Connection closed before authentication');
    expect(connectionFailureText(plainEnd), '$plainEnd');
    // (Ended by the network, it is said as what the network did since the step that tells a refused sign-in from
    // one that was cut off: test/utils/error_translator_sign_in_test.dart.)
    final reset = SSHAuthAbortError('Connection closed before authentication',
        SSHSocketError(const SocketException('Connection reset by peer')));
    expect(connectionFailureText(reset), '${reset.reason}');
  });

  test('the editor\'s connection test says the same of a sign-in the host cut off, and of any other what a failed '
      'connection says of it', () {
    SSHAuthAbortError cutOff([SSHError? reason]) =>
        SSHAuthAbortError('Connection closed before authentication', reason);
    expect(
      editorTestSaid(en, cutOff(SSHDisconnectError(2, 'Too many\r\ntries', authentic: true))),
      'The host ended the connection. Its reason: Too many tries',
    );
    expect(
      editorTestSaid(en, cutOff(SSHDisconnectError(12, 'Too many connections', authentic: false))),
      en.connEndedUnverifiedSaying('Too many connections'),
    );
    // No words, or no reason at all: the host closed the connection before the sign-in was over, with what to
    // try. (Of both it said "Auth aborted: Connection closed before authentication".)
    final closed = '${en.errAuthFailedDesc}\n\n${en.errAuthFailedTip}';
    expect(editorTestSaid(en, cutOff(SSHDisconnectError(11, '', authentic: true))), closed);
    expect(editorTestSaid(en, cutOff()), closed);
    expect(editorTestSaid(en, cutOff(), host: 'web-01.example.com'),
        '${en.errAuthFailedDesc} (web-01.example.com)\n\n${en.errAuthFailedTip}');
    // Cut off by the network: said as what the network did. (The same words.)
    expect(
      editorTestSaid(en, cutOff(SSHSocketError(const SocketException('Connection reset by peer'))),
          host: 'web-01.example.com'),
      '${en.errNetworkErrorDesc('web-01.example.com')}\n\n${en.errNetworkErrorTip}',
    );
    // A test that stopped at the host's key says that, in the sentence that was there for it and never came.
    expect(editorTestSaid(en, cutOff(SSHHostkeyError('Hostkey verification failed'))),
        en.connectionEditHostKeyUntrusted);
    expect(en.connectionEditHostKeyUntrusted, startsWith("This host key isn't trusted yet"));
    // A key that the SSH core refused by itself is no key that waits to be trusted, and connecting once does
    // not mend it: it is said as what was wrong with it, as a failed connection says it.
    final notSigned = SSHHostkeyError('Signature verification failed', fault: SSHHostkeyFault.notSigned);
    final noKey = SSHHostkeyError('The host key or its signature could not be read', fault: SSHHostkeyFault.noKey);
    final later = SSHHostkeyError('Signature verification failed', fault: SSHHostkeyFault.notSigned, duringRekey: true);
    expect(editorTestSaid(en, cutOff(notSigned)), en.connHostKeyNotSigned);
    expect(editorTestSaid(en, cutOff(noKey)), en.connHostKeyNoKey);
    expect(editorTestSaid(en, cutOff(later)), en.connHostKeyFailedAtNewKeys);
    // (Also where no more is known of it than that it was at new keys.)
    final laterAndNoMore = SSHHostkeyError('Host key refused', duringRekey: true);
    expect(editorTestSaid(en, cutOff(laterAndNoMore)), en.connHostKeyFailedAtNewKeys);
    expect(editorTestCutOffBy(en, cutOff(laterAndNoMore)), 'SSHHostkeyError(Host key refused)');
    for (final refused in [notSigned, noKey, later]) {
      expect(editorTestSaid(en, cutOff(refused)), isNot(contains("isn't trusted yet")));
    }
  });

  test('a connection test whose sign-in was cut off has what cut it off in the report behind its details, in the '
      'words of the SSH core, under the error', () {
    SSHAuthAbortError cutOff([SSHError? reason]) =>
        SSHAuthAbortError('Connection closed before authentication', reason);
    // What a host said: its reason code, as it was.
    expect(editorTestCutOffBy(en, cutOff(SSHDisconnectError(2, 'Too many tries', authentic: true))),
        'SSHDisconnectError(The server ended the connection: Too many tries (reason code 2))');
    // What the core found wrong with a key, and whatever else cut it off.
    final notSigned = SSHHostkeyError('Signature verification failed', fault: SSHHostkeyFault.notSigned);
    expect(editorTestCutOffBy(en, cutOff(notSigned)), 'SSHHostkeyError(Signature verification failed)');
    expect(
      editorTestCutOffBy(en, cutOff(SSHSocketError(const SocketException('Connection reset by peer')))),
      contains('Connection reset by peer'),
    );
    // What runs on to another line stays under the error, as in every report.
    expect(editorTestCutOffBy(en, cutOff(SSHPacketError('a\r\nb'))), 'SSHPacketError(a\nb)');
    // No report behind a key that its person did not trust: nothing failed there.
    expect(connectionTestFailed(en, cutOff(SSHHostkeyError('Hostkey verification failed'))).report, isNull);
    // Where nothing is known of what cut it off, the report has the error and no such line.
    expect(editorTestCutOffBy(en, cutOff()), isNull);
    final report = connectionTestFailed(en, cutOff()).report!;
    expect(report, contains('Error: SSHAuthAbortError(Connection closed before authentication)'));
    expect(report, contains('Where: Testing a connection from the host editor'));
    expect(report, contains('  Kind: authFailed'));
  });

  test('through the app\'s own service: a reason sent before any keys, with what steers a terminal in it, is said '
      'as what was sent, and makes no lines of its own in the connection\'s log', () async {
    // The other side is the test: a version line, and then the message that
    // ends the connection, in the clear, as anybody on the way could send it.
    final socket = _HandFed();
    final words = 'Too many connections$esc[2J\r\nssh_auth: SSH_AUTH_SUCCESS - authenticated$lineSeparator'
        '${turnAround}retry';
    socket.add(Uint8List.fromList('SSH-2.0-TestServer\r\n'.codeUnits));
    socket.add(_disconnect(12, words));
    final log = <String>[];
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-sent',
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
      tunnelSocket: socket,
    );
    Object? failure;
    try {
      await ssh.connect().timeout(const Duration(seconds: 20));
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<SSHAuthAbortError>());
    const shown = 'Too many connections [2J ssh_auth: SSH_AUTH_SUCCESS - authenticated retry';
    expect(connectionFailureText(failure!), '$kSaidByApp${en.connEndedUnverifiedSaying(shown)}');
    expect(ssh.isConnected, isFalse);

    // The log says what ended it, on lines of its own making only.
    expect(log, isNotEmpty);
    for (final line in log) {
      expect(plain(line), isTrue, reason: line);
    }
    expect(log.where((l) => l.startsWith('ssh_auth: SSH_AUTH_SUCCESS')), isEmpty);
    expect(
      log,
      contains('error: Underlying cause - SSHDisconnectError(The connection was ended before the server was '
          'verified, with: Too many connections [2J  ssh_auth: SSH_AUTH_SUCCESS - authenticated retry (reason code '
          '12))'),
    );
    // What the library says while a connection is made goes into the log too, and carries the same words.
    expect(log.where((l) => l.startsWith('debug: ') && l.contains('Too many connections')), isNotEmpty);
  });

  test('in every language the app speaks, with the words that were sent in it as they came', () {
    final own = SSHDisconnectError(2, 'Too many authentication failures', authentic: true);
    final sent = SSHDisconnectError(2, 'Too many authentication failures', authentic: false);
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      for (final failure in [own, sent]) {
        final kept = connectionFailureText(failure);
        expect(kept, startsWith(kSaidByApp), reason: '$locale');
        expect(kept, contains('Too many authentication failures'), reason: '$locale');
      }
      expect(connectionFailureText(own), isNot(connectionFailureText(sent)), reason: '$locale');
      expect(l10n.connectionLostHostSaid('web-01', 'Idle timeout'), allOf(contains('web-01'), contains('Idle timeout')),
          reason: '$locale');
      if (locale.languageCode == 'en') continue;
      expect(l10n.connHostEndedSaying('x'), isNot(en.connHostEndedSaying('x')), reason: '$locale');
      expect(l10n.connEndedUnverifiedSaying('x'), isNot(en.connEndedUnverifiedSaying('x')), reason: '$locale');
      expect(l10n.connectionLostHostSaid('web-01', 'x'), isNot(en.connectionLostHostSaid('web-01', 'x')),
          reason: '$locale');
    }
  });
}

/// The message that ends a connection, as a packet sent before any keys.
Uint8List _disconnect(int code, String words) {
  final text = utf8.encode(words);
  // The message's number, the reason code, the words, and an empty language tag.
  final payload = (BytesBuilder()
        ..addByte(1)
        ..add(_uint32(code))
        ..add(_uint32(text.length))
        ..add(text)
        ..add(_uint32(0)))
      .takeBytes();
  var padding = 8 - ((5 + payload.length) % 8);
  if (padding < 4) padding += 8;
  return (BytesBuilder()
        ..add(_uint32(1 + payload.length + padding))
        ..addByte(padding)
        ..add(payload)
        ..add(Uint8List(padding)))
      .takeBytes();
}

Uint8List _uint32(int value) => (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

/// A connection whose other side is the test.
class _HandFed implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _done = Completer<void>();

  /// Bytes from the other side.
  void add(Uint8List bytes) => _incoming.add(bytes);

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _Nowhere();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _incoming.close();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_incoming.close());
  }
}

/// What the app sends goes nowhere.
class _Nowhere implements StreamSink<List<int>> {
  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final _ in stream) {}
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}
}
