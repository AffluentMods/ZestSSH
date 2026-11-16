import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/utils/file_manager.dart' show debugRestrictFileToOwner;

/// The app's file transfers against a real OpenSSH server: that a file goes
/// up and comes back the same, and what becomes of a transfer whose
/// connection breaks under it (3.0, the SSH core's audit: SFTP requests
/// that waited for ever). A transfer under way on a connection that dropped
/// never ended, and could not be cancelled; whatever was asked of that file
/// pane afterwards waited too. Each ends now, said as the connection lost,
/// and what the transfer was to replace is as it was.
///
/// The server is the second one tool/test_sshd.sh starts (127.0.0.1:2297,
/// which asks for new keys every megabyte and has SFTP); its own client key
/// logs in. Skips itself when the server is not running, or was started
/// before it had SFTP. Override the location with ZESTSSH_TEST_SSHD_HOST /
/// ZESTSSH_TEST_REKEY_SSHD_PORT / _USER / _DIR.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  const reset = SocketException('Connection reset by peer');
  const lost = 'The connection to the server was lost.';
  String? unavailable;
  var folders = 0;

  Future<(SSHClient, _Gated)> connect() async {
    final key = SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()).single;
    final socket = _Gated(await SSHSocket.connect(host, port));
    final client = SSHClient(socket, username: user, identities: [key]);
    await client.authenticated;
    return (client, socket);
  }

  Future<String> run(SSHClient client, String command) async =>
      utf8.decode(await client.run(command).timeout(const Duration(seconds: 15))).trim();

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      if (!File('$dir/client_ed25519').existsSync()) {
        unavailable = 'the test key is not there';
        return;
      }
      final (client, _) = await connect();
      try {
        (await client.sftp()).close();
      } on SSHChannelRequestError {
        unavailable = 'the test sshd at $host:$port has no SFTP: start it again with tool/test_sshd.sh';
      } finally {
        client.close();
      }
    } catch (_) {
      unavailable = 'no test sshd at $host:$port';
    }
  });

  /// A folder of this test's own on the host, and one on this device; both
  /// removed when the test ends.
  Future<(String, Directory)> folders2() async {
    final remote = '/tmp/zest-app-sftp-test-$pid-${folders++}';
    final (client, _) = await connect();
    await run(client, 'mkdir -p $remote');
    client.close();
    final local = await Directory.systemTemp.createTemp('zest-app-sftp-test');
    addTearDown(() async {
      final (cleaner, _) = await connect();
      await run(cleaner, 'rm -rf $remote');
      cleaner.close();
      await local.delete(recursive: true);
    });
    return (remote, local);
  }

  /// [size] bytes that do not repeat soon.
  Uint8List bytes(int size) {
    final out = Uint8List(size);
    var x = 0x2545F491;
    for (var i = 0; i < size; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      out[i] = x >> 16;
    }
    return out;
  }

  /// What [transfer] ended with (null where it went through), given twenty
  /// seconds to end.
  Future<Object?> endOf(Future<void> transfer) async {
    Object? failure;
    var ended = false;
    unawaited(transfer.then<void>((_) => ended = true, onError: (Object e) {
      failure = e;
      ended = true;
    }));
    final clock = Stopwatch()..start();
    while (!ended && clock.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ended, isTrue, reason: 'it ends, where it waited for ever');
    return failure;
  }

  test('a file uploaded and downloaded again is the same file', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (remote, local) = await folders2();
    final content = bytes(2 * 1024 * 1024 + 512 * 1024 + 123);
    final source = File('${local.path}/app.bin')..writeAsBytesSync(content);

    final (client, _) = await connect();
    addTearDown(client.close);
    final sftp = SftpService(client);
    await sftp.open();
    await sftp.uploadFileFromPath(source.path, '$remote/app.bin').timeout(const Duration(seconds: 60));
    expect((await sftp.stat('$remote/app.bin')).size, content.length);
    expect((await sftp.listDirectory(remote)).map((entry) => entry.name), ['app.bin'], reason: 'and nothing half done');

    final back = File('${local.path}/back.bin');
    await sftp.downloadFileToPath('$remote/app.bin', back.path).timeout(const Duration(seconds: 60));
    expect(back.readAsBytesSync(), content);
    expect(local.listSync().map((f) => f.uri.pathSegments.last).toSet(), {'app.bin', 'back.bin'});
    await sftp.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  // Found in a security review: on macOS and Linux a file only its owner may read on the host (a key
  // at 600) landed readable by everyone here.
  test('a file only its owner may read on the host is kept to its owner here, before a byte of it is written; one '
      'others may read is not', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (remote, local) = await folders2();
    final (client, _) = await connect();
    addTearDown(client.close);
    await run(client, 'printf secret > $remote/id_key && chmod 600 $remote/id_key && '
        'printf notes > $remote/notes.txt && chmod 644 $remote/notes.txt');
    final kept = <(String, int)>[];
    SftpService.debugKeepsOwnerOnly = true;
    debugRestrictFileToOwner = (file) async {
      kept.add((file.uri.pathSegments.last, file.lengthSync()));
      return true;
    };
    addTearDown(() {
      SftpService.debugKeepsOwnerOnly = null;
      debugRestrictFileToOwner = null;
    });
    final sftp = SftpService(client);
    await sftp.open();
    await sftp.downloadFileToPath('$remote/id_key', '${local.path}/id_key').timeout(const Duration(seconds: 60));
    await sftp.downloadFileToPath('$remote/notes.txt', '${local.path}/notes.txt').timeout(const Duration(seconds: 60));
    expect(kept, [('id_key.zestpart', 0)], reason: 'the key alone, while it held nothing yet');
    expect(File('${local.path}/id_key').readAsStringSync(), 'secret');
    expect(File('${local.path}/notes.txt').readAsStringSync(), 'notes');

    // Where a download does not keep modes (Windows), nothing is asked of it.
    SftpService.debugKeepsOwnerOnly = false;
    kept.clear();
    await sftp.downloadFileToPath('$remote/id_key', '${local.path}/again').timeout(const Duration(seconds: 60));
    expect(kept, isEmpty);
    await sftp.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a download under way when the network breaks ends, is said as the connection lost, and leaves the file it '
      'was to replace as it was', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (remote, local) = await folders2();
    final content = bytes(3 * 1024 * 1024);
    final staged = File('${local.path}/staged.bin')..writeAsBytesSync(content);
    final (writer, _) = await connect();
    final writing = SftpService(writer);
    await writing.open();
    await writing.uploadFileFromPath(staged.path, '$remote/report.bin').timeout(const Duration(seconds: 60));
    await writing.close();
    writer.close();
    // What the download is to replace on this device.
    final target = File('${local.path}/report.bin')..writeAsStringSync('the report as it was');

    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final (client, socket) = await connect();
      final sftp = SftpService(client);
      await sftp.open();
      var broke = false;
      final failure = await endOf(sftp.downloadFileToPath('$remote/report.bin', target.path,
          onProgress: (transferred, total) {
        if (broke || transferred < 256 * 1024) return;
        broke = true;
        socket.breakWith(reset);
      }));
      expect(broke, isTrue, reason: 'it was under way');
      expect(failure, isNotNull);
      expect(sftpErrorMessage(failure!, name: 'report.bin', op: SftpOp.download, l10n: en), lost);
      expect(target.readAsStringSync(), 'the report as it was');

      // What is asked of that file pane afterwards ends at once, the same way.
      final listing = await endOf(sftp.listDirectory(remote));
      expect(listing, isNotNull);
      expect(sftpErrorMessage(listing!, op: SftpOp.list, l10n: en), lost);
      await sftp.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, (error, stack) => uncaught.add(error));
    expect(uncaught, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an upload under way when the network breaks ends the same way, and the file on the host it was to replace '
      'is as it was', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (remote, local) = await folders2();
    final (setup, _) = await connect();
    await run(setup, 'printf %s "the settings as they were" > $remote/app.conf');
    final source = File('${local.path}/app.conf')..writeAsBytesSync(bytes(3 * 1024 * 1024));

    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final (client, socket) = await connect();
      final sftp = SftpService(client);
      await sftp.open();
      var broke = false;
      final failure = await endOf(sftp.uploadFileFromPath(source.path, '$remote/app.conf',
          onProgress: (transferred, total) {
        if (broke || transferred < 256 * 1024) return;
        broke = true;
        socket.breakWith(reset);
      }));
      expect(broke, isTrue, reason: 'it was under way');
      expect(failure, isNotNull);
      expect(sftpErrorMessage(failure!, name: 'app.conf', op: SftpOp.upload, l10n: en), lost);
      await sftp.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }, (error, stack) => uncaught.add(error));
    expect(uncaught, isEmpty);

    expect(await run(setup, 'cat $remote/app.conf'), 'the settings as they were');
    setup.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// A connection to the server whose network can be made to break.
class _Gated implements SSHSocket {
  _Gated(this._inner) {
    _sub = _inner.stream.listen(_out.add, onError: _out.addError, onDone: _out.close);
  }

  final SSHSocket _inner;
  final _out = StreamController<Uint8List>();
  late final StreamSubscription<Uint8List> _sub;

  void breakWith(Object error) => _out.addError(error);

  @override
  Stream<Uint8List> get stream => _out.stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() {
    _sub.cancel();
    _inner.destroy();
  }
}
