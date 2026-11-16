import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/worker/worker_protocol.dart';
import 'package:zestssh/services/worker/worker_ssh_service.dart';

/// Why a connection on a worker isolate ended (3.0): what the
/// worker said when it failed after connecting; nothing when it only says
/// the shell went.
void main() {
  WorkerSshService service() => WorkerSshService(
        params: const ConnectParams(host: '10.50.0.5', port: 22, username: 'demo'),
        keyPems: const [],
        passphrase: null,
        password: null,
        forwardAgent: false,
        onHostKeyVerify: (_, _, _) async => true,
        fallbackFactory: () => throw StateError('no fallback here'),
      );

  test('an error after connecting is why it ended', () async {
    final worker = service();
    expect(worker, isA<ShellEndReason>());
    worker.debugHandle(const WorkerConnectionState(true));
    worker.debugHandle(const WorkerError('SocketException: Connection reset by peer'));
    expect(await worker.endReason, 'SocketException: Connection reset by peer');
    // What it said first stands.
    worker.debugHandle(const WorkerExited(false));
    expect(await worker.endReason, 'SocketException: Connection reset by peer');
  });

  test('a shell that went with nothing said: not known', () async {
    final worker = service();
    worker.debugHandle(const WorkerConnectionState(true));
    worker.debugHandle(const WorkerExited(false));
    expect(await worker.endReason, isNull);
  });
}
