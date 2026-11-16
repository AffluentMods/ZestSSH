import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/worker/worker_protocol.dart';

/// Design B worker protocol.
///
/// These tests pin two properties the isolate boundary depends on:
///   1. every command and event survives a `toWire()` -> `fromWire()` round
///      trip with all fields intact (a dropped field is how a worker silently
///      stops honouring, say, a resize or an auth answer);
///   2. every wire form contains ONLY values a `SendPort` can carry, so a future
///      field of a non-transmissible type is caught here, in a fast unit test,
///      instead of blowing up at runtime the first time it is sent.
void main() {
  group('ConnectParams', () {
    test('round-trips all fields, including non-default options', () {
      const params = ConnectParams(
        host: 'jump.example.net',
        port: 2222,
        username: 'deploy',
        compatibilityMode: true,
        zlibCompression: true,
        forwardAgent: true,
        keepAliveSeconds: 30,
      );
      final back = ConnectParams.fromWire(params.toWire());
      expect(back, params);
      expect(back.host, 'jump.example.net');
      expect(back.port, 2222);
      expect(back.username, 'deploy');
      expect(back.compatibilityMode, isTrue);
      expect(back.zlibCompression, isTrue);
      expect(back.forwardAgent, isTrue);
      expect(back.keepAliveSeconds, 30);
    });

    test('defaults survive the round trip', () {
      const params =
          ConnectParams(host: 'h', port: 22, username: 'u');
      final back = ConnectParams.fromWire(params.toWire());
      expect(back, params);
      expect(back.compatibilityMode, isFalse);
      expect(back.keepAliveSeconds, 0);
    });
  });

  group('WorkerCommand', () {
    test('WorkerConnect carries the full ConnectParams', () {
      const cmd = WorkerConnect(ConnectParams(
        host: 'srv',
        port: 22,
        username: 'root',
        compatibilityMode: true,
      ));
      final back = WorkerCommand.fromWire(cmd.toWire());
      expect(back, isA<WorkerConnect>());
      expect((back as WorkerConnect).params, cmd.params);
    });

    test('WorkerWrite preserves the exact bytes', () {
      final cmd = WorkerWrite(Uint8List.fromList([0, 27, 91, 65, 255]));
      final back = WorkerCommand.fromWire(cmd.toWire());
      expect(back, isA<WorkerWrite>());
      expect((back as WorkerWrite).data, orderedEquals([0, 27, 91, 65, 255]));
    });

    test('WorkerResize preserves width and height', () {
      const cmd = WorkerResize(120, 40);
      final back = WorkerCommand.fromWire(cmd.toWire()) as WorkerResize;
      expect(back.width, 120);
      expect(back.height, 40);
    });

    test('WorkerDisconnect round-trips', () {
      final back = WorkerCommand.fromWire(const WorkerDisconnect().toWire());
      expect(back, isA<WorkerDisconnect>());
    });

    test('WorkerHostKeyReply preserves id and verdict', () {
      const cmd = WorkerHostKeyReply(7, false);
      final back = WorkerCommand.fromWire(cmd.toWire()) as WorkerHostKeyReply;
      expect(back.id, 7);
      expect(back.accepted, isFalse);
    });

    test('WorkerPasswordReply preserves a null password (skip method)', () {
      const cmd = WorkerPasswordReply(3, null);
      final back = WorkerCommand.fromWire(cmd.toWire()) as WorkerPasswordReply;
      expect(back.id, 3);
      expect(back.password, isNull);
    });

    test('WorkerPasswordReply preserves a real password', () {
      const cmd = WorkerPasswordReply(3, 'hunter2');
      final back = WorkerCommand.fromWire(cmd.toWire()) as WorkerPasswordReply;
      expect(back.password, 'hunter2');
    });

    test('WorkerUserInfoReply preserves ordered responses', () {
      const cmd = WorkerUserInfoReply(9, ['pw', '', '123456']);
      final back = WorkerCommand.fromWire(cmd.toWire()) as WorkerUserInfoReply;
      expect(back.id, 9);
      expect(back.responses, orderedEquals(['pw', '', '123456']));
    });

    test('WorkerSignInCancel round-trips (3.4.1)', () {
      final back = WorkerCommand.fromWire(const WorkerSignInCancel().toWire());
      expect(back, isA<WorkerSignInCancel>());
    });

    test('an unknown command tag fails loudly', () {
      expect(() => WorkerCommand.fromWire(['bogus']),
          throwsA(isA<ArgumentError>()));
    });

    test('every command wire form is SendPort-safe', () {
      final commands = <WorkerCommand>[
        const WorkerConnect(
            ConnectParams(host: 'h', port: 22, username: 'u')),
        WorkerWrite(Uint8List.fromList([1, 2, 3])),
        const WorkerResize(80, 24),
        const WorkerDisconnect(),
        const WorkerHostKeyReply(1, true),
        const WorkerPasswordReply(1, 'x'),
        const WorkerPasswordReply(1, null),
        const WorkerUserInfoReply(1, ['a', 'b']),
        const WorkerSignInCancel(),
      ];
      for (final c in commands) {
        _assertWireSafe(c.toWire(), c.runtimeType.toString());
      }
    });
  });

  group('WorkerEvent', () {
    test('WorkerReady round-trips', () {
      final back = WorkerEvent.fromWire(const WorkerReady().toWire());
      expect(back, isA<WorkerReady>());
    });

    test('WorkerStdout preserves the exact bytes', () {
      final evt = WorkerStdout(Uint8List.fromList([104, 105, 10]));
      final back = WorkerEvent.fromWire(evt.toWire()) as WorkerStdout;
      expect(back.data, orderedEquals([104, 105, 10]));
    });

    test('WorkerStderr preserves the exact bytes', () {
      final evt = WorkerStderr(Uint8List.fromList([255, 0]));
      final back = WorkerEvent.fromWire(evt.toWire()) as WorkerStderr;
      expect(back.data, orderedEquals([255, 0]));
    });

    test('WorkerConnectionState preserves the flag', () {
      final back = WorkerEvent.fromWire(const WorkerConnectionState(true).toWire())
          as WorkerConnectionState;
      expect(back.connected, isTrue);
    });

    test('WorkerLog preserves the message', () {
      final back = WorkerEvent.fromWire(const WorkerLog('ssh_hostkey: ok').toWire())
          as WorkerLog;
      expect(back.message, 'ssh_hostkey: ok');
    });

    test('WorkerHostKeyRequest preserves id, type and key blob', () {
      final evt = WorkerHostKeyRequest(
          42, 'ssh-ed25519', Uint8List.fromList([9, 8, 7]));
      final back = WorkerEvent.fromWire(evt.toWire()) as WorkerHostKeyRequest;
      expect(back.id, 42);
      expect(back.type, 'ssh-ed25519');
      expect(back.keyBlob, orderedEquals([9, 8, 7]));
    });

    test('WorkerPasswordRequest preserves the id', () {
      final back = WorkerEvent.fromWire(const WorkerPasswordRequest(5).toWire())
          as WorkerPasswordRequest;
      expect(back.id, 5);
    });

    test('WorkerUserInfoRequest preserves prompts with their echo flags', () {
      const evt = WorkerUserInfoRequest(11, 'Two-factor', [
        (promptText: 'Password:', echo: false),
        (promptText: 'Verification code:', echo: true),
      ]);
      final back = WorkerEvent.fromWire(evt.toWire()) as WorkerUserInfoRequest;
      expect(back.id, 11);
      expect(back.name, 'Two-factor');
      expect(back.prompts, hasLength(2));
      expect(back.prompts[0].promptText, 'Password:');
      expect(back.prompts[0].echo, isFalse);
      expect(back.prompts[1].promptText, 'Verification code:');
      expect(back.prompts[1].echo, isTrue);
    });

    test('WorkerExited preserves the clean flag', () {
      final back =
          WorkerEvent.fromWire(const WorkerExited(true).toWire()) as WorkerExited;
      expect(back.clean, isTrue);
    });

    test('WorkerError preserves the message', () {
      final back = WorkerEvent.fromWire(const WorkerError('auth failed').toWire())
          as WorkerError;
      expect(back.message, 'auth failed');
    });

    test('WorkerSignInNotice preserves the cleaned banner and its link, or none (3.4.1)', () {
      final back = WorkerEvent.fromWire(
          const WorkerSignInNotice('To authenticate, visit: https://login.example.com/a/1', 'https://login.example.com/a/1')
              .toWire()) as WorkerSignInNotice;
      expect(back.text, 'To authenticate, visit: https://login.example.com/a/1');
      expect(back.link, 'https://login.example.com/a/1');
      final none = WorkerEvent.fromWire(const WorkerSignInNotice('words', null).toWire()) as WorkerSignInNotice;
      expect(none.link, isNull);
    });

    test('an unknown event tag fails loudly', () {
      expect(
          () => WorkerEvent.fromWire(['bogus']), throwsA(isA<ArgumentError>()));
    });

    test('every event wire form is SendPort-safe', () {
      final events = <WorkerEvent>[
        const WorkerReady(),
        WorkerStdout(Uint8List.fromList([1])),
        WorkerStderr(Uint8List.fromList([2])),
        const WorkerConnectionState(false),
        const WorkerLog('x'),
        WorkerHostKeyRequest(1, 't', Uint8List.fromList([3])),
        const WorkerPasswordRequest(1),
        const WorkerUserInfoRequest(
            1, 'n', [(promptText: 'p', echo: false)]),
        const WorkerExited(false),
        const WorkerError('e'),
        const WorkerSignInNotice('t', 'https://l.example/a'),
        const WorkerSignInNotice('t', null),
      ];
      for (final e in events) {
        _assertWireSafe(e.toWire(), e.runtimeType.toString());
      }
    });
  });
}

/// Asserts [value] is composed only of types a `SendPort` can transmit between
/// isolates: null, num, bool, String, [Uint8List], and Lists/Maps of the same.
/// Records are checked structurally by the protocol's own flattening, so they
/// never reach the wire form directly. Anything else (a custom object, a
/// closure) would throw at send time, so catching it here is the point.
void _assertWireSafe(Object? value, String context) {
  if (value == null ||
      value is num ||
      value is bool ||
      value is String ||
      value is Uint8List) {
    return;
  }
  if (value is List) {
    for (final e in value) {
      _assertWireSafe(e, context);
    }
    return;
  }
  if (value is Map) {
    value.forEach((k, v) {
      _assertWireSafe(k, context);
      _assertWireSafe(v, context);
    });
    return;
  }
  fail('$context has a non-SendPort-safe wire value: '
      '${value.runtimeType} ($value)');
}
