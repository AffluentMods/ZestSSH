import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/mosh_testing.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations_en.dart';
import 'package:zestssh/services/mosh/builtin_mosh_service.dart';
import 'package:zestssh/services/mosh/mosh_bootstrap.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A built-in Mosh session (4.0) over a fake of the Rust client: what the
/// session hands the client (the server's address, port, key, the terminal's
/// size), what comes back (the screen as terminal output, the link's status),
/// how it ends, and the errors with their codes.
void main() {
  const key = 'gtwzcEPcVFEmGb/8f6cB6g';
  final l10n = AppLocalizationsEn();

  Future<MoshServerReady> ready() async =>
      (start: const MoshServerStart(port: 60001, key: key), addresses: ['192.0.2.10', '2001:db8::10']);

  test('connects once the server answers, with the address, port, key and size', () async {
    final native = FakeMoshNative(onOpen: (s) => s.connect());
    final log = <String>[];
    final m = BuiltinMoshService(bootstrap: ready, native: native, onLog: log.add);
    m.resize(132, 43);
    final states = <bool>[];
    m.connectionState.listen(states.add);
    await m.connect();
    expect(m.isConnected, isTrue);
    expect(native.last.request['addresses'], ['192.0.2.10', '2001:db8::10']);
    expect(native.last.request['port'], 60001);
    expect(native.last.request['key'], key);
    expect((native.last.request['cols'], native.last.request['rows']), (132, 43));
    expect(log.join('\n'), isNot(contains(key)), reason: 'the key is never logged');
    await Future<void>.delayed(Duration.zero);
    expect(states, [true]);
    expect(m.isEncryptedSsh, isFalse);
  });

  test('the screen comes out as terminal output; typing and the size go to the client', () async {
    final native = FakeMoshNative(onOpen: (s) => s.connect());
    final m = BuiltinMoshService(bootstrap: ready, native: native);
    final out = <int>[];
    m.stdout.listen(out.addAll);
    await m.connect();
    native.last.output('\x1b[H\x1b[2J\$ ');
    await Future<void>.delayed(Duration.zero);
    expect(utf8.decode(out), '\x1b[H\x1b[2J\$ ');
    m.write(Uint8List.fromList(utf8.encode('ls\r')));
    m.resize(100, 30);
    m.resize(100, 30);
    m.resize(0, 30);
    expect(native.last.typed.toBytes(), utf8.encode('ls\r'));
    expect(native.last.resizes, [(100, 30)], reason: 'the same size once, a zero size never');
  });

  test('the link: quiet from 10 seconds without a word from the server', () async {
    final native = FakeMoshNative(onOpen: (s) => s.connect());
    final m = BuiltinMoshService(bootstrap: ready, native: native);
    await m.connect();
    native.last.status(lastHeardMs: 1200, srttMs: 35);
    await Future<void>.delayed(Duration.zero);
    expect(m.moshLink.value.quiet, isFalse);
    expect(m.moshLink.value.srttMs, 35);
    native.last.status(lastHeardMs: 12000);
    await Future<void>.delayed(Duration.zero);
    expect(m.moshLink.value.quiet, isTrue);
    expect(m.moshLink.value.lastHeard, const Duration(seconds: 12));
  });

  test('the shell on the host ending ends the session as a clean exit', () async {
    final native = FakeMoshNative(onOpen: (s) => s.connect());
    final m = BuiltinMoshService(bootstrap: ready, native: native);
    final states = <bool>[];
    m.connectionState.listen(states.add);
    await m.connect();
    native.last.closeWith('server_closed', 'the session ended on the host');
    await Future<void>.delayed(Duration.zero);
    expect(m.isConnected, isFalse);
    expect(m.exitedCleanly, isTrue);
    expect(await m.endReason, hostClosedConnection);
    expect(native.last.released, isTrue, reason: 'the callback goes after CLOSED');
    expect(states, [true, false]);
  });

  test('the client failing after it connected is a drop, not a clean exit, and says why', () async {
    final native = FakeMoshNative(onOpen: (s) => s.connect());
    final m = BuiltinMoshService(bootstrap: ready, native: native);
    await m.connect();
    native.last.closeWith('protocol', 'the server speaks Mosh protocol version 3, which this client does not');
    await Future<void>.delayed(Duration.zero);
    expect(m.exitedCleanly, isFalse);
    expect(await m.endReason, contains('version 3'));
  });

  test('nothing answers over UDP: ZS-1007 with the port and the ports to open', () async {
    final native = FakeMoshNative(onOpen: (s) => s.closeWith('no_answer', 'no answer from mosh-server on UDP port 60001 within 15 s'));
    final m = BuiltinMoshService(bootstrap: ready, native: native);
    final e = await _sessionFailure(m.connect);
    expect(e.problem, MoshSessionProblem.noAnswer);
    expect(e.port, 60001);
    expect(e.code, ErrorCodes.moshNoAnswer);
    final text = moshSessionFailureText(l10n, e);
    expect(text, contains('port 60001'));
    expect(text, contains('UDP ports 60000 to 61000'));
    expect(text, contains('(ZS-1007)'));
    expect(m.isConnected, isFalse);
    expect(native.last.released, isTrue);
  });

  test('other failures before an answer: ZS-1008 with what the client said', () async {
    for (final reason in ['network', 'key', 'protocol', 'internal']) {
      final native = FakeMoshNative(onOpen: (s) => s.closeWith(reason, 'it said $reason'));
      final m = BuiltinMoshService(bootstrap: ready, native: native);
      final e = await _sessionFailure(m.connect);
      expect(e.code, ErrorCodes.moshSessionFailed, reason: reason);
      expect(moshSessionFailureText(l10n, e), contains('it said $reason'));
    }
    final refused = BuiltinMoshService(bootstrap: ready, native: FakeMoshNative(refuse: true));
    expect((await _sessionFailure(refused.connect)).code, ErrorCodes.moshSessionFailed);
  });

  test('a failure to start mosh-server comes through as it is', () async {
    final m = BuiltinMoshService(
      bootstrap: () async => throw const MoshStartFailure(MoshStartProblem.notInstalled),
      native: FakeMoshNative(),
    );
    await expectLater(m.connect(), throwsA(isA<MoshStartFailure>()));
  });

  test('disconnect tells the client and waits for its CLOSED, then closes its streams', () async {
    final native = FakeMoshNative(onOpen: (s) => s.connect());
    final m = BuiltinMoshService(bootstrap: ready, native: native);
    await m.connect();
    final done = Completer<void>();
    m.stdout.listen((_) {}, onDone: done.complete);
    await m.disconnect();
    expect(native.last.closed, isTrue);
    expect(native.last.released, isTrue);
    expect(m.isConnected, isFalse);
    expect(m.exitedCleanly, isTrue);
    await done.future.timeout(const Duration(seconds: 1));
    // Typing after the end goes nowhere, and a second disconnect does nothing.
    m.write(Uint8List.fromList([1]));
    await m.disconnect();
    expect(native.last.typed.length, 0);
  });

  test('where a Mosh session opens with the app\'s own client', () {
    final own = Platform.isAndroid || Platform.isIOS || Platform.isWindows;
    expect(moshUsesBuiltIn(preferSystem: false), isTrue);
    expect(moshUsesBuiltIn(preferSystem: true), own ? isTrue : isFalse,
        reason: 'only a Mac and Linux may choose their own mosh program');
    expect(moshSystemClientOffered, Platform.isMacOS || Platform.isLinux);
  });

  group('the addresses UDP goes to', () {
    test('a direct connection: the address SSH reached, alone, never a second lookup', () async {
      var looked = 0;
      final log = <String>[];
      final found = await moshUdpAddresses(
        sshPeer: '192.0.2.6',
        host: 'demo.example',
        lookup: (_) async {
          looked++;
          return [InternetAddress('192.0.2.5'), InternetAddress('192.0.2.6')];
        },
        onLog: log.add,
      );
      expect(found, ['192.0.2.6'], reason: 'a name with two addresses, SSH connected to the second: the second alone');
      expect(looked, 0);
      expect(log.single, contains('the address the SSH connection reached'));
    });

    test('through a jump host (no peer of its own): the name resolved here, and the log says so', () async {
      final log = <String>[];
      final found = await moshUdpAddresses(
        sshPeer: null,
        host: 'demo.example',
        lookup: (_) async => [InternetAddress('192.0.2.5'), InternetAddress('192.0.2.6')],
        onLog: log.add,
      );
      expect(found, ['192.0.2.5', '192.0.2.6']);
      expect(log.single, contains('Through a jump host'));
    });

    test('an address is itself; a name what it resolves to, in order, each once, four at most', () async {
      expect(await moshAddressesOf('192.0.2.7'), ['192.0.2.7']);
      expect(await moshAddressesOf('[2001:db8::1]'), ['2001:db8::1']);
      final found = await moshAddressesOf('demo.example', lookup: (_) async => [
            InternetAddress('2001:db8::5'),
            InternetAddress('192.0.2.5'),
            InternetAddress('192.0.2.5'),
            InternetAddress('192.0.2.6'),
            InternetAddress('192.0.2.7'),
            InternetAddress('192.0.2.8'),
          ]);
      expect(found, ['2001:db8::5', '192.0.2.5', '192.0.2.6', '192.0.2.7']);
    });

    test('a name that does not resolve is ZS-1008', () async {
      final e = await _sessionFailure(
          () => moshAddressesOf('nowhere.example', lookup: (_) async => throw const SocketException('no such host')));
      expect(e.code, ErrorCodes.moshSessionFailed);
      final none = await _sessionFailure(() => moshAddressesOf('nowhere.example', lookup: (_) async => []));
      expect(none.problem, MoshSessionProblem.network);
    });
  });
}

Future<MoshSessionFailure> _sessionFailure(Future<Object?> Function() f) async {
  try {
    await f();
  } on MoshSessionFailure catch (e) {
    return e;
  }
  fail('no MoshSessionFailure');
}
