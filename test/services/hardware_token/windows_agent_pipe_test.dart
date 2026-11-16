import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';
import 'package:zestssh/services/hardware_token/windows_pipe_ffi.dart';
import 'package:zestssh/services/key_generation_service.dart';

/// The SSH agent's pipe on a real Windows (found in a
/// security review), served from this test's own process by a
/// pipe of a name of its own (never the computer's agent): the app opens it
/// so that its server may only identify it, asks Windows who serves it before
/// a byte is sent, uses it where that is this account, and sends nothing
/// where it is another's. Windows only: skipped elsewhere.
void main() {
  final skip = Platform.isWindows ? null : 'Windows named pipes only';

  tearDown(() {
    debugAgentPipeServerIdentity = null;
    // A server whose client never came waits for one: one comes and goes, so
    // that its isolate ends.
    for (final server in _PipeServer.waiting()) {
      try {
        WindowsNamedPipe.open(server.name).close();
      } catch (_) {}
    }
  });

  test('Windows names this account as the server of a pipe this process serves', () async {
    final server = await _PipeServer.start();
    final pipe = WindowsNamedPipe.open(server.name);
    final PipeServerIdentity who;
    try {
      who = pipe.serverIdentity();
    } finally {
      pipe.close();
    }
    expect(who.ownUser, startsWith('S-1-5-'));
    expect(who.serverProcessUser, who.ownUser, reason: 'the server is this very process');
    expect(who.pipeOwner, isNotNull, reason: 'the pipe this process made is owned by it (or by Administrators, elevated)');
    expect(agentPipeServerVerdict(who), AgentPipeServer.trusted);
    expect(await server.done, 0, reason: 'asking Windows sends the server nothing');
  }, skip: skip);

  test('the server may identify the person, never act as them (SECURITY_IDENTIFICATION)', () async {
    final server = await _PipeServer.start();
    final agent = await OsSshAgent.open(socketPath: server.name);
    await agent.close();
    await server.done;
    // SecurityIdentification is 1; Windows' default for a pipe opened with no
    // such flags is SecurityImpersonation, 2.
    expect(server.impersonationLevels, [1]);
  }, skip: skip);

  test('a pipe served by this account is used: Add to agent gives it the key', () async {
    final server = await _PipeServer.start();
    final made = await KeyGenerationService().generateEd25519(comment: 'x');
    final request = SSHAgentProtocol.addIdentityRequest(SSHKeyPair.fromPem(made.privatePem).single, comment: 'deploy');
    final agent = await OsSshAgent.open(socketPath: server.name);
    try {
      await addIdentityToOsAgent(agent, request);
    } finally {
      await agent.close();
    }
    await server.done;
    expect(server.requests.last, request);
  }, skip: skip);

  test('a pipe served as another account, or by one Windows will not name, is closed with nothing sent', () async {
    for (final (stand, expected) in [
      ((PipeServerIdentity read) => PipeServerIdentity(ownUser: read.ownUser, serverProcessUser: '${read.ownUser}0'),
          AgentPipeServer.otherAccount),
      ((PipeServerIdentity read) => PipeServerIdentity(ownUser: read.ownUser, pipeOwner: 'S-1-5-19'),
          AgentPipeServer.otherAccount),
      ((PipeServerIdentity read) => PipeServerIdentity(ownUser: read.ownUser, pipeOwner: read.ownUser),
          AgentPipeServer.unconfirmed),
      ((PipeServerIdentity read) => const PipeServerIdentity(), AgentPipeServer.unconfirmed),
    ]) {
      final server = await _PipeServer.start();
      debugAgentPipeServerIdentity = stand;
      Object? thrown;
      try {
        await OsSshAgent.open(socketPath: server.name);
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<AgentPipeNotYours>().having((e) => e.verdict, 'verdict', expected));
      expect(await server.done, 0, reason: 'not even the list request of the probe');
      expect(server.requests, isEmpty);
    }
  }, skip: skip);
}

/// A pipe served by an isolate of this process, speaking the agent protocol:
/// an empty list of keys, and yes to anything else. It serves one client.
class _PipeServer {
  _PipeServer._(this.name);

  final String name;
  final requests = <Uint8List>[];
  final impersonationLevels = <int>[];
  final _done = Completer<int>();

  /// How many bytes the server read in all, once its client is gone.
  Future<int> get done => _done.future.timeout(const Duration(seconds: 20));

  static final _started = <_PipeServer>[];

  /// The servers still waiting for their client.
  static Iterable<_PipeServer> waiting() => _started.where((s) => !s._done.isCompleted);

  static Future<_PipeServer> start() async {
    final name = '\\\\.\\pipe\\zestssh-test-agent-$pid-${Random().nextInt(1 << 32)}';
    final server = _PipeServer._(name);
    _started.add(server);
    final port = ReceivePort();
    final ready = Completer<void>();
    port.listen((message) {
      switch (message) {
        case ['ready']:
          ready.complete();
        case ['request', final TransferableTypedData bytes]:
          server.requests.add(bytes.materialize().asUint8List());
        case ['level', final int level]:
          server.impersonationLevels.add(level);
        case ['done', final int read]:
          server._done.complete(read);
          port.close();
        case ['failed', final String why]:
          if (!ready.isCompleted) ready.completeError(StateError(why));
          if (!server._done.isCompleted) server._done.completeError(StateError(why));
          port.close();
      }
    });
    await Isolate.spawn(_serve, [port.sendPort, name]);
    await ready.future.timeout(const Duration(seconds: 20));
    return server;
  }
}

// ── The server's side, in its own isolate (its reads block) ────────────────

const _pipeAccessDuplex = 0x3;
const _pipeRejectRemoteClients = 0x8;
const _errorPipeConnected = 535;
const _tokenQuery = 0x8;
const _tokenImpersonationLevel = 9;

void _serve(List<Object> args) {
  final out = args[0] as SendPort;
  final name = args[1] as String;
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final advapi32 = DynamicLibrary.open('advapi32.dll');
  final createNamedPipe = kernel32.lookupFunction<
      IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Uint32, Uint32, Uint32, Uint32, Pointer<Void>),
      int Function(Pointer<Utf16>, int, int, int, int, int, int, Pointer<Void>)>('CreateNamedPipeW');
  final connectNamedPipe = kernel32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Void>), int Function(int, Pointer<Void>)>('ConnectNamedPipe');
  final readFile = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
  final writeFile = kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
  final closeHandle = kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  final getLastError = kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  final getCurrentThread = kernel32.lookupFunction<IntPtr Function(), int Function()>('GetCurrentThread');
  final impersonate =
      advapi32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('ImpersonateNamedPipeClient');
  final revertToSelf = advapi32.lookupFunction<Int32 Function(), int Function()>('RevertToSelf');
  final openThreadToken = advapi32.lookupFunction<Int32 Function(IntPtr, Uint32, Int32, Pointer<IntPtr>),
      int Function(int, int, int, Pointer<IntPtr>)>('OpenThreadToken');
  final getTokenInformation = advapi32.lookupFunction<Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32, Pointer<Uint32>),
      int Function(int, int, Pointer<Void>, int, Pointer<Uint32>)>('GetTokenInformation');

  final namePtr = name.toNativeUtf16();
  final handle = createNamedPipe(namePtr, _pipeAccessDuplex, _pipeRejectRemoteClients, 1, 65536, 65536, 0, nullptr);
  calloc.free(namePtr);
  if (handle == -1) {
    out.send(['failed', 'CreateNamedPipeW failed: ${getLastError()}']);
    return;
  }
  out.send(['ready']);
  if (connectNamedPipe(handle, nullptr) == 0 && getLastError() != _errorPipeConnected) {
    out.send(['failed', 'ConnectNamedPipe failed: ${getLastError()}']);
    closeHandle(handle);
    return;
  }

  final count = calloc<Uint32>();
  final buffer = calloc<Uint8>(65536);
  var total = 0;

  /// [n] bytes, or null once the client is gone.
  Uint8List? read(int n) {
    final got = Uint8List(n);
    var have = 0;
    while (have < n) {
      if (readFile(handle, buffer, n - have, count, nullptr) == 0 || count.value == 0) return null;
      got.setRange(have, have + count.value, buffer.asTypedList(count.value));
      have += count.value;
      total += count.value;
    }
    return got;
  }

  void write(List<int> bytes) {
    final data = calloc<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    writeFile(handle, data, bytes.length, count, nullptr);
    calloc.free(data);
  }

  var first = true;
  while (true) {
    final head = read(4);
    if (head == null) break;
    final length = ByteData.sublistView(head).getUint32(0);
    final body = read(length);
    if (body == null) break;
    if (first) {
      // What the client let this server be: ImpersonateNamedPipeClient takes
      // a client that has written, and the level is that of its open.
      first = false;
      if (impersonate(handle) != 0) {
        final token = calloc<IntPtr>();
        final level = calloc<Uint32>();
        if (openThreadToken(getCurrentThread(), _tokenQuery, 1, token) != 0) {
          if (getTokenInformation(token.value, _tokenImpersonationLevel, level.cast(), 4, count) != 0) {
            out.send(['level', level.value]);
          }
          closeHandle(token.value);
        }
        revertToSelf();
        calloc.free(token);
        calloc.free(level);
      }
    }
    if (body[0] == SSHAgentProtocol.requestIdentities) {
      write([0, 0, 0, 5, 12, 0, 0, 0, 0]);
    } else {
      out.send(['request', TransferableTypedData.fromList([body])]);
      write([0, 0, 0, 1, SSHAgentProtocol.success]);
    }
  }
  calloc.free(count);
  calloc.free(buffer);
  closeHandle(handle);
  out.send(['done', total]);
}
