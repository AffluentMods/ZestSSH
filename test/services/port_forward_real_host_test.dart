import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/port_forward_service.dart';
import 'package:zestssh/services/socks5_service.dart';

/// Port forwards through a real OpenSSH server (the first one
/// tool/test_sshd.sh starts, 127.0.0.1:2299), with a small program on the
/// host for the other end of each. Skips itself when the server is not
/// running, or the host has no python3 for that program.
///
/// A forward handed on whatever came from either side as fast as it came,
/// with nothing holding it back: where the reader on one side was slower
/// than the writer on the other (a download through a forward that is saved
/// to a slow disk, or stopped for a while), everything the writer could send
/// was taken, and waited in this app's memory. It took the end of either way
/// for the end of both, so whoever said that it had sent everything lost the
/// answer. And the proxy (SOCKS 5) listened to a program's connection anew
/// for each part of what it says, which a socket allows once: no program
/// ever got further than the proxy's first answer.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  String? unavailable;
  final onHost = '/tmp/zest-app-forward-test-$pid.py';

  /// What the program on the host said of an error of its own, by what it
  /// says otherwise, and the session it runs in.
  final failedWith = Expando<StringBuffer>();
  final sessionOf = Expando<SSHSession>();

  /// How many bytes a test sends that gets them all back while it sends:
  /// half a megabyte, in pieces of 65536. (With two megabytes going each way
  /// at once, the way from this machine into its Linux side, where the test
  /// server is, stopped for good more often than not: seen with a forward
  /// from the host, never with one megabyte, and never on a way around it.
  /// That is this machine's, and nothing of a forward's.)
  const echoed = 8 * 65536;

  // The other end of a forward, on the host. It ends with the session that
  // started it.
  //
  // As what a forward leads to, it listens on a port of its own choosing,
  // says which, and then:
  //   echo [P]    sends back what comes, to every connection, until that
  //               connection's other side says that no more comes; says
  //               "over" for each that has ended (on the port P, where one
  //               is given)
  //   firm        the same, but it does not end its side when it is told
  //               that no more comes: it sees whether what it sends is still
  //               taken then, and says "over" once it is not, or "still
  //               open" where it is for three seconds
  //   six         the same, on the host's IPv6 loopback address ("none"
  //               where it has none)
  //   send N T    sends N bytes to one connection as fast as they are taken;
  //               after T seconds it says how many were taken so far, and
  //               "done" when all are, or "broken" when it could send no more
  //   take T      reads nothing from one connection for T seconds, then reads
  //               to the end and says how many bytes came
  //   quiet       says at once that it sends nothing, reads to the end and
  //               says how many bytes came
  //   late T      lets nobody in for T seconds (whoever connects waits), and
  //               is firm from then on
  //   late T take S   lets nobody in for T seconds, reads nothing from a
  //               connection for S more, then reads to its end and says how
  //               many bytes came
  //   shut T      lets nobody in for T seconds, and then is gone: whoever
  //               was waiting is refused then
  // As what connects to a forwarded port P on the host:
  //   there P N   sends N bytes, says that no more comes, reads to the end
  //               and says how many came back, and whether they are the same
  //   many P K    K connections one after the other, a byte there and back
  //               on each; says how many got theirs back
  //   nowhere P   waits for the end of what comes ("no end came" after
  //               twenty seconds), then sees whether what it sends is still
  //               taken: "gone" or "still open"
  //   hold P      says "in" once connected, and "ended" at the end of it
  //   knock P     says whether the port takes a connection
  //   free        says a port that nothing listens on
  const program = '''
import os, socket, sys, threading, time
mode = sys.argv[1]

def watch():
    try:
        sys.stdin.buffer.read()
    finally:
        os._exit(0)
threading.Thread(target=watch, daemon=True).start()

def say(*words):
    print(*words, flush=True)

def serve(family=socket.AF_INET, address='127.0.0.1', backlog=64, port=0):
    s = socket.socket(family)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((address, port))
    s.listen(backlog)
    return s

def echo(c):
    try:
        while True:
            d = c.recv(65536)
            if not d:
                break
            c.sendall(d)
    except OSError:
        pass
    c.close()
    say('over')

def firm(c):
    try:
        while True:
            d = c.recv(65536)
            if not d:
                break
            c.sendall(d)
        end = time.time() + 3
        while time.time() < end:
            c.sendall(b'x')
            time.sleep(0.1)
    except OSError:
        say('over')
        return
    say('still open')

def each(s, what):
    while True:
        c, _ = s.accept()
        threading.Thread(target=what, args=(c,), daemon=True).start()

def echo_all(s):
    each(s, echo)

def to_the_end(c):
    got = 0
    while True:
        d = c.recv(65536)
        if not d:
            return got
        got += len(d)

if mode == 'echo':
    s = serve(port=int(sys.argv[2]) if len(sys.argv) > 2 else 0)
    say(s.getsockname()[1])
    echo_all(s)
elif mode == 'firm':
    s = serve()
    say(s.getsockname()[1])
    each(s, firm)
elif mode == 'six':
    try:
        s = serve(socket.AF_INET6, '::1')
    except OSError:
        say('none')
        sys.exit(0)
    say(s.getsockname()[1])
    echo_all(s)
elif mode == 'send':
    total, wait = int(sys.argv[2]), float(sys.argv[3])
    s = serve()
    say(s.getsockname()[1])
    c, _ = s.accept()
    piece = b'0' * 65536
    sent = 0
    said = False
    start = time.time()
    c.settimeout(0.1)
    try:
        while sent < total:
            if not said and time.time() - start >= wait:
                say('taken', sent)
                said = True
            try:
                sent += c.send(piece[:min(len(piece), total - sent)])
            except socket.timeout:
                pass
    except OSError:
        say('broken', sent)
        sys.exit(0)
    if not said:
        say('taken', sent)
    say('done', sent)
    c.close()
elif mode == 'take':
    wait = float(sys.argv[2])
    s = serve()
    say(s.getsockname()[1])
    c, _ = s.accept()
    time.sleep(wait)
    say('came', to_the_end(c))
    c.close()
elif mode == 'quiet':
    s = serve()
    say(s.getsockname()[1])
    c, _ = s.accept()
    c.shutdown(socket.SHUT_WR)
    say('came', to_the_end(c))
    c.close()
elif mode == 'late':
    wait = float(sys.argv[2])
    hold = float(sys.argv[4]) if len(sys.argv) > 4 else None
    # Those who wait to be let in are this program's own: whoever else
    # connects now is not answered until some of them have been let in.
    # (They send nothing and never end, so nothing is said of them.)
    s = serve(backlog=0)
    own = []
    for _ in range(4):
        f = socket.socket()
        f.setblocking(False)
        f.connect_ex(s.getsockname())
        own.append(f)
    say(s.getsockname()[1])
    time.sleep(wait)
    def take(c):
        time.sleep(hold)
        say('came', to_the_end(c))
    each(s, firm if hold is None else take)
elif mode == 'shut':
    s = serve(backlog=0)
    own = []
    for _ in range(4):
        f = socket.socket()
        f.setblocking(False)
        f.connect_ex(s.getsockname())
        own.append(f)
    say(s.getsockname()[1])
    time.sleep(float(sys.argv[2]))
    os._exit(0)
elif mode == 'there':
    port, total = int(sys.argv[2]), int(sys.argv[3])
    sent = bytes((i * 31) & 255 for i in range(65536)) * (total // 65536)
    c = socket.create_connection(('127.0.0.1', port), timeout=30)
    back = bytearray()
    def read():
        while True:
            d = c.recv(65536)
            if not d:
                break
            back.extend(d)
    reading = threading.Thread(target=read)
    reading.start()
    c.sendall(sent)
    c.shutdown(socket.SHUT_WR)
    reading.join()
    say('back', len(back), bytes(back) == sent)
elif mode == 'many':
    port, count = int(sys.argv[2]), int(sys.argv[3])
    through = 0
    for _ in range(count):
        try:
            c = socket.create_connection(('127.0.0.1', port), timeout=10)
            c.sendall(b'x')
            c.shutdown(socket.SHUT_WR)
            got = b''
            while True:
                d = c.recv(16)
                if not d:
                    break
                got += d
            c.close()
            if got == b'x':
                through += 1
        except OSError:
            pass
    say('through', through)
elif mode == 'nowhere':
    try:
        c = socket.create_connection(('127.0.0.1', int(sys.argv[2])), timeout=20)
    except OSError:
        say('refused')
        sys.exit(0)
    try:
        while c.recv(16):
            pass
    except socket.timeout:
        say('no end came')
        sys.exit(0)
    except OSError:
        say('gone')
        sys.exit(0)
    try:
        end = time.time() + 3
        while time.time() < end:
            c.sendall(b'x')
            time.sleep(0.1)
    except OSError:
        say('gone')
        sys.exit(0)
    say('still open')
elif mode == 'hold':
    c = socket.create_connection(('127.0.0.1', int(sys.argv[2])), timeout=20)
    c.settimeout(None)
    say('in')
    try:
        while c.recv(16):
            pass
    except OSError:
        pass
    say('ended')
elif mode == 'knock':
    try:
        socket.create_connection(('127.0.0.1', int(sys.argv[2])), timeout=5).close()
        say('accepted')
    except OSError:
        say('refused')
elif mode == 'free':
    s = serve()
    say(s.getsockname()[1])
    s.close()
''';

  Future<SSHClient> connect({String key = 'client_ed25519'}) async {
    final client = SSHClient(
      await SSHSocket.connect(host, port, timeout: const Duration(seconds: 5)),
      username: user,
      identities: SSHKeyPair.fromPem(File('$dir/$key').readAsStringSync()),
    );
    addTearDown(client.close);
    await client.authenticated.timeout(const Duration(seconds: 20));
    return client;
  }

  setUpAll(() async {
    try {
      (await Socket.connect(host, port, timeout: const Duration(seconds: 2))).destroy();
      if (!File('$dir/client_ed25519').existsSync()) {
        unavailable = 'the test key is not there';
        return;
      }
      final client = SSHClient(
        await SSHSocket.connect(host, port),
        username: user,
        identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
      );
      try {
        final has = utf8.decode(await client.run('command -v python3 >/dev/null && echo yes; true')).trim();
        if (has != 'yes') {
          unavailable = 'the host has no python3 for the other end of the forwards';
          return;
        }
        final writing = await client.execute('cat > $onHost');
        writing.stdin.add(Uint8List.fromList(utf8.encode(program)));
        await writing.stdin.close();
        await writing.done.timeout(const Duration(seconds: 10));
      } finally {
        client.close();
      }
    } catch (_) {
      unavailable = 'no test sshd at $host:$port';
    }
  });

  tearDownAll(() async {
    if (unavailable != null) return;
    try {
      final client = SSHClient(
        await SSHSocket.connect(host, port),
        username: user,
        identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
      );
      await client.run('rm -f $onHost');
      client.close();
    } catch (_) {}
  });

  /// The program on the host, started with [arguments]: what it says, a
  /// line at a time.
  Future<StreamIterator<String>> hostRuns(SSHClient client, String arguments) async {
    final session = await client.execute('python3 $onHost $arguments');
    addTearDown(session.close);
    final said = StreamIterator(
        session.stdout.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
    final complaints = failedWith[said] = StringBuffer();
    session.stderr.cast<List<int>>().transform(utf8.decoder).listen(complaints.write);
    sessionOf[said] = session;
    return said;
  }

  /// Ends the program on the host that says [said], and with it whatever it
  /// listened on.
  Future<void> endsNow(StreamIterator<String> said) async {
    sessionOf[said]!.close();
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  /// What a forward service says of connections that are not made, as it
  /// says it.
  List<ForwardTrouble> saidBy(PortForwardService forwards) {
    final said = <ForwardTrouble>[];
    final listening = forwards.troubles.listen(said.add);
    addTearDown(listening.cancel);
    return said;
  }

  /// A connection to [local] that is made and ends with nothing having come:
  /// the forward could not make it.
  Future<void> isNotMade(int local) async {
    final held = Held(await Socket.connect(InternetAddress.loopbackIPv4, local));
    await held.ended.future.timeout(const Duration(seconds: 20));
    held.socket.destroy();
    expect(held.came, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  /// The next line the program on the host says.
  Future<String> next(StreamIterator<String> said, {Duration within = const Duration(seconds: 20)}) async {
    final bool more;
    try {
      more = await said.moveNext().timeout(within);
    } on TimeoutException {
      fail('the program on the host said nothing for ${within.inSeconds} seconds. ${failedWith[said]}');
    }
    expect(more, isTrue, reason: 'the program on the host said no more. ${failedWith[said]}');
    return said.current;
  }

  /// The program on the host as what a forward leads to: the port it
  /// listens on, and what it says after that.
  Future<(int, StreamIterator<String>)> farEndOf(SSHClient client, String arguments) async {
    final said = await hostRuns(client, arguments);
    return (int.parse(await next(said)), said);
  }

  /// A port on this device that nothing listens on now.
  Future<int> freePort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final free = probe.port;
    await probe.close();
    return free;
  }

  /// A port on the host that nothing listens on now.
  Future<int> freePortOnHost(SSHClient client) async => int.parse(await next(await hostRuns(client, 'free')));

  /// A forward from a port on this device to [remotePort] on the host:
  /// its service, where it is `f1`, and the port it listens on here.
  Future<(PortForwardService, int)> forwardTo(SSHClient client, int remotePort) async {
    final forwards = PortForwardService(client);
    addTearDown(forwards.dispose);
    final local = await freePort();
    await forwards.startLocalForward(
      PortForward(id: 'f1', type: PortForwardType.local, bindPort: local, remoteHost: '127.0.0.1', remotePort: remotePort),
    );
    return (forwards, local);
  }

  /// A proxy on this device for whatever the host can reach: its service,
  /// where it is `d1`, and the port it listens on.
  Future<(PortForwardService, int)> proxyThrough(SSHClient client) async {
    final forwards = PortForwardService(client);
    addTearDown(forwards.dispose);
    final local = await freePort();
    await forwards.startDynamicForward(
      PortForward(id: 'd1', type: PortForwardType.dynamic, bindPort: local, remoteHost: '', remotePort: 0),
    );
    return (forwards, local);
  }

  /// A program's connection to a port on this device.
  Future<Held> connectTo(int local) async {
    final held = Held(await Socket.connect(InternetAddress.loopbackIPv4, local));
    addTearDown(held.socket.destroy);
    return held;
  }

  group('from a port on this device to one the host can reach:', () {
    test('what goes in at one end comes out at the other, both ways, and a second connection has its own', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      final (_, local) = await forwardTo(client, remotePort);

      Future<List<int>> thereAndBack(int seed) async {
        final sent = List.generate(300000, (i) => (i * 7 + seed) & 0xff);
        final held = await connectTo(local);
        held.socket.add(sent);
        final back = await held.take(sent.length);
        expect(back, sent);
        return back;
      }

      final both = await Future.wait([thereAndBack(1), thereAndBack(2)]);
      expect(both[0][1000], isNot(both[1][1000]), reason: 'each connection has its own bytes back');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('whoever has sent all it has and says so still gets the answer, and the far end is told that no more '
        'comes', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      final (_, local) = await forwardTo(client, remotePort);

      final sent = Uint8List.fromList(List.generate(echoed, (i) => (i * 13) & 0xff));
      final held = await connectTo(local);
      held.socket.add(sent);
      // Finished sending: this end's writing side is closed, its reading side stays open for the answer. (The
      // far end sends everything back, and ends its side when it is told that no more comes.)
      await held.socket.close();
      await held.ended.future.timeout(const Duration(seconds: 30));
      expect(held.came.length, sent.length, reason: 'the answer was cut off');
      expect(held.came.last, sent.last);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a far end that says at once that it sends nothing is still sent everything', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, said) = await farEndOf(client, 'quiet');
      final (_, local) = await forwardTo(client, remotePort);

      const total = 8 * 1024 * 1024;
      final held = await connectTo(local);
      // This end hears that nothing comes, and goes on sending.
      await held.ended.future.timeout(const Duration(seconds: 20));
      final piece = Uint8List(64 * 1024);
      for (var sent = 0; sent < total; sent += piece.length) {
        held.socket.add(piece);
      }
      await held.socket.close();
      expect(await next(said, within: const Duration(seconds: 60)), 'came $total',
          reason: 'the end of it was cut off');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a far end that sends faster than this end reads is held back: what it sent does not pile up here, and '
        'all of it comes once it is read', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      const total = 64 * 1024 * 1024;
      final (remotePort, said) = await farEndOf(client, 'send $total 3');
      final (_, local) = await forwardTo(client, remotePort);

      // Whoever is at this end reads nothing for a while.
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, local);
      addTearDown(socket.destroy);
      var came = 0;
      final ended = Completer<void>();
      final reading = socket.listen((data) => came += data.length, onDone: ended.complete);
      reading.pause();

      final taken = await next(said, within: const Duration(seconds: 30));
      expect(taken, startsWith('taken '));
      // What the far end got rid of in three seconds, with nobody reading: what fits on the way (the windows
      // and buffers of both connections), and not the sixty-four megabytes.
      expect(int.parse(taken.split(' ')[1]), lessThan(16 * 1024 * 1024),
          reason: 'it was all taken, and waited in this app: $taken');

      // And once this end reads, all of it comes.
      reading.resume();
      await ended.future.timeout(const Duration(seconds: 60));
      expect(came, total);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('this end sending faster than the far end reads is held back the same way', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      const total = 64 * 1024 * 1024;
      final (remotePort, said) = await farEndOf(client, 'take 3');
      final (_, local) = await forwardTo(client, remotePort);

      final held = await connectTo(local);
      // Sixty-four megabytes, handed over as fast as they are taken: how many were after two seconds, with the
      // far end reading nothing yet.
      var handedOver = 0;
      var stillSending = true;
      final sending = () async {
        final piece = Uint8List(64 * 1024);
        while (handedOver < total) {
          held.socket.add(piece);
          await held.socket.flush();
          handedOver += piece.length;
        }
        stillSending = false;
        await held.socket.close();
      }();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(stillSending, isTrue, reason: 'all of it was taken, and waited in this app');
      expect(handedOver, lessThan(16 * 1024 * 1024),
          reason: 'so much was taken with nobody reading: $handedOver bytes');

      // And once the far end reads, all of it goes through.
      await sending.timeout(const Duration(seconds: 90));
      expect(await next(said, within: const Duration(seconds: 60)), 'came $total');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a program at this end that goes away in the middle of it: the far end is stopped, and is not sent on '
        'into nothing', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      const total = 64 * 1024 * 1024;
      final (remotePort, said) = await farEndOf(client, 'send $total 60');
      final (_, local) = await forwardTo(client, remotePort);

      final held = await connectTo(local);
      await held.atLeast(1024 * 1024);
      // It stops reading, and then is gone, with what had come for it unread.
      held.reading.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      held.socket.destroy();

      final end = await next(said);
      expect(end, startsWith('broken '), reason: 'the far end went on sending to nobody');
      expect(int.parse(end.split(' ')[1]), lessThan(total));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a program at this end that is gone all at once, with nothing on its way to it: the connection on the '
        'host ends, and what broke it here is nothing the host is sent', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, said) = await farEndOf(client, 'echo');
      final (_, local) = await forwardTo(client, remotePort);

      // It sends, and never reads the answer: all of that has come and waits for it when it goes.
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, local);
      socket.add(Uint8List(32 * 1024));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      socket.destroy();

      expect(await next(said), 'over', reason: 'the connection on the host was left open');
      // The connection to the host is as it was: another goes through.
      final held = await connectTo(local);
      held.socket.add([1, 2, 3]);
      expect(await held.take(3), [1, 2, 3]);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('it goes on taking connections: a hundred and fifty, one after the other', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      final (_, local) = await forwardTo(client, remotePort);

      // More than a forward takes at a time: each that has ended is one it no longer counts.
      expect(150, greaterThan(maxForwardConnectionsPerRule));
      for (var i = 0; i < 150; i++) {
        final held = Held(await Socket.connect(InternetAddress.loopbackIPv4, local));
        held.socket.add([i & 0xff]);
        await held.socket.close();
        await held.ended.future.timeout(const Duration(seconds: 20));
        held.socket.destroy();
        expect(held.came, [i & 0xff], reason: 'connection ${i + 1} was not let through');
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('where the host cannot connect to what the forward leads to, the connection here ends; and once it can, '
        'the forward is there for it, however many times it could not', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final nobodyThere = await freePortOnHost(client);
      final (_, local) = await forwardTo(client, nobodyThere);

      // More times than a forward takes connections at once: each that ended is one it no longer counts.
      expect(140, greaterThan(maxForwardConnectionsPerRule));
      for (var i = 0; i < 140; i++) {
        final held = Held(await Socket.connect(InternetAddress.loopbackIPv4, local));
        held.socket.add([1, 2, 3]);
        await held.ended.future.timeout(const Duration(seconds: 20));
        held.socket.destroy();
        expect(held.came, isEmpty);
      }

      // Now something listens there.
      await farEndOf(client, 'echo $nobodyThere');
      final held = await connectTo(local);
      held.socket.add([1, 2, 3]);
      expect(await held.take(3), [1, 2, 3]);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('it says when the host cannot connect to where it leads, with what the host said: once, and again '
        'when it had worked in between, or was stopped and started', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final nobodyThere = await freePortOnHost(client);
      final (forwards, local) = await forwardTo(client, nobodyThere);
      final said = saidBy(forwards);

      await isNotMade(local);
      expect(said, hasLength(1));
      expect(said.single.forward.id, 'f1');
      final answer = said.single.error as SSHChannelOpenError;
      expect(answer.code, 2);
      expect(answer.description.toLowerCase(), contains('refused'));

      // A program that goes on trying does not make it be said again.
      await isNotMade(local);
      await isNotMade(local);
      expect(said, hasLength(1));

      // Something listens there now: a connection is made, and nothing is said of that.
      final (_, farEnd) = await farEndOf(client, 'echo $nobodyThere');
      final held = await connectTo(local);
      held.socket.add([1, 2, 3]);
      expect(await held.take(3), [1, 2, 3]);
      held.socket.destroy();
      expect(said, hasLength(1));

      // It is gone again: that is news.
      await endsNow(farEnd);
      await isNotMade(local);
      expect(said, hasLength(2));
      await isNotMade(local);
      expect(said, hasLength(2));

      // Stopped and started again, it says it anew.
      await forwards.stopForward('f1');
      await forwards.startLocalForward(
        PortForward(id: 'f1', type: PortForwardType.local, bindPort: local, remoteHost: '127.0.0.1', remotePort: nobodyThere),
      );
      await isNotMade(local);
      expect(said, hasLength(3));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('it says when the host passes no connections on for this key', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      if (!File('$dir/client_noforward_ed25519').existsSync()) {
        return markTestSkipped('the key that may not forward is not there: run tool/test_sshd.sh again');
      }
      final client = await connect(key: 'client_noforward_ed25519');
      final (forwards, local) = await forwardTo(client, port);
      final said = saidBy(forwards);

      await isNotMade(local);
      await isNotMade(local);
      expect(said, hasLength(1));
      expect((said.single.error as SSHChannelOpenError).code, 1);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stopped, it says nothing of a connection the host gives up on afterwards', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'shut 1.5');
      final (forwards, local) = await forwardTo(client, remotePort);
      final said = saidBy(forwards);

      final held = await connectTo(local);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(held.ended.isCompleted, isFalse, reason: 'the far end answered at once: this shows nothing');
      await forwards.stopForward('f1');
      // The far end is gone a second later, and the host says so after that.
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(said, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stopping it ends its connections, and it takes no new ones', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, said) = await farEndOf(client, 'firm');
      final (forwards, local) = await forwardTo(client, remotePort);

      final held = await connectTo(local);
      held.socket.add([1, 2, 3]);
      expect(await held.take(3), [1, 2, 3]);

      await forwards.stopForward('f1');
      await held.ended.future.timeout(const Duration(seconds: 10));
      expect(await next(said), 'over', reason: 'the connection on the host was left open');
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, local), throwsA(isA<SocketException>()));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stopped while the host is still connecting for someone: that connection ends too, and is not left open '
        'on the host', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, said) = await farEndOf(client, 'late 2');
      final (forwards, local) = await forwardTo(client, remotePort);

      final held = await connectTo(local);
      held.socket.add([7]);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(held.came, isEmpty, reason: 'the far end let it in at once: this shows nothing');
      expect(held.ended.isCompleted, isFalse);

      await forwards.stopForward('f1');
      await held.ended.future.timeout(const Duration(seconds: 3));
      // The host gets through a little later, to a forward that is no longer there.
      expect(await next(said), 'over');
      expect(held.came, isEmpty, reason: 'it went on after the forward was stopped');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('a proxy for whatever the host can reach (SOCKS 5):', () {
    /// Asks the proxy for a connection to [address], written as the
    /// protocol writes it (its kind first), and [to]: the program's end of
    /// it, and what the proxy answered.
    Future<(Held, int)> ask(int proxy, List<int> address, int to) async {
      final held = await connectTo(proxy);
      // The program says which version it speaks and that it signs in with nothing; the proxy agrees.
      held.socket.add([5, 1, 0]);
      expect(await held.take(2), [5, 0]);
      // It asks to be connected; the proxy says whether it is.
      held.socket.add([5, 1, 0, ...address, to >> 8, to & 0xff]);
      final answer = await held.take(10);
      expect([answer[0], ...answer.sublist(2)], [5, 0, 1, 0, 0, 0, 0, 0, 0]);
      return (held, answer[1]);
    }

    Future<void> thereAndBack(Held held, {int bytes = 200000}) async {
      final sent = List.generate(bytes, (i) => (i * 11) & 0xff);
      held.socket.add(sent);
      expect(await held.take(sent.length), sent);
    }

    const loopback = [1, 127, 0, 0, 1];

    test('a program is let through to where it asks, by its address, and what it sends comes back from there',
        () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      final (_, proxy) = await proxyThrough(client);

      final (held, answer) = await ask(proxy, loopback, remotePort);
      expect(answer, 0, reason: 'connected');
      // From here on it is the connection it asked for.
      await thereAndBack(held, bytes: echoed);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('by a name the host knows, and by an IPv6 address', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      final (_, proxy) = await proxyThrough(client);

      final name = ascii.encode('localhost');
      final (byName, answer) = await ask(proxy, [3, name.length, ...name], remotePort);
      expect(answer, 0);
      await thereAndBack(byName);

      final six = await hostRuns(client, 'six');
      final sixPort = await next(six);
      if (sixPort == 'none') return markTestSkipped('the host has no IPv6 loopback address');
      final (bySix, answer6) = await ask(proxy, [4, ...List.filled(15, 0), 1], int.parse(sixPort));
      expect(answer6, 0);
      await thereAndBack(bySix);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('what a program says may come a byte at a time, or all at once with what it sends behind it', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      final (_, proxy) = await proxyThrough(client);
      final request = [5, 1, 0, ...loopback, remotePort >> 8, remotePort & 0xff];

      // A byte at a time.
      final slow = await connectTo(proxy);
      for (final byte in [5, 1, 0]) {
        slow.socket.add([byte]);
        await slow.socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await slow.take(2), [5, 0]);
      for (final byte in request) {
        slow.socket.add([byte]);
        await slow.socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect((await slow.take(10))[1], 0);
      await thereAndBack(slow);

      // All at once: nothing of it is lost, and what was sent behind the request goes where it asked.
      final hasty = await connectTo(proxy);
      final sent = List.generate(50000, (i) => (i * 3) & 0xff);
      hasty.socket.add([5, 1, 0, ...request, ...sent]);
      expect(await hasty.take(2), [5, 0]);
      expect((await hasty.take(10))[1], 0);
      expect(await hasty.take(sent.length), sent);
      await thereAndBack(hasty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('where there is nowhere to go the program is told, as far as the protocol can say it, and its connection '
        'ends', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (_, proxy) = await proxyThrough(client);
      Future<void> ends(Held held) async {
        await held.ended.future.timeout(const Duration(seconds: 10));
        expect(held.came, isEmpty, reason: 'nothing more was said');
      }

      // It can only sign in with a password: no way of signing in that the proxy takes.
      final password = await connectTo(proxy);
      password.socket.add([5, 1, 2]);
      expect(await password.take(2), [5, 0xff]);
      await ends(password);

      // An older version of the protocol: nothing this proxy could say would be understood.
      final four = await connectTo(proxy);
      four.socket.add([4, 1, 0, 80, 127, 0, 0, 1, 0]);
      await ends(four);

      // It asks the proxy to listen for it, or to pass packets on: commands this proxy has not.
      for (final command in [2, 3]) {
        final held = await connectTo(proxy);
        held.socket.add([5, 1, 0]);
        expect(await held.take(2), [5, 0]);
        held.socket.add([5, command, 0, ...loopback, 0, 80]);
        expect(await held.take(10), [5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
        await ends(held);
      }

      // What it asks for is in another version than what it began with.
      final mixed = await connectTo(proxy);
      mixed.socket.add([5, 1, 0]);
      expect(await mixed.take(2), [5, 0]);
      mixed.socket.add([4, 1, 0, ...loopback, 0, 80]);
      expect(await mixed.take(10), [5, 1, 0, 1, 0, 0, 0, 0, 0, 0]);
      await ends(mixed);

      // A kind of address there is none of.
      final kind = await connectTo(proxy);
      kind.socket.add([5, 1, 0]);
      expect(await kind.take(2), [5, 0]);
      kind.socket.add([5, 1, 0, 9, 1, 2, 3, 4, 0, 80]);
      expect(await kind.take(10), [5, 8, 0, 1, 0, 0, 0, 0, 0, 0]);
      await ends(kind);

      // A port on the host that nothing listens on: the host could not connect there.
      final (nobody, answer) = await ask(proxy, loopback, await freePortOnHost(client));
      expect(answer, 4);
      await ends(nobody);

      // The connection to the host has ended: the proxy failed.
      client.close();
      await client.done.timeout(const Duration(seconds: 10));
      final (after, answerAfter) = await ask(proxy, loopback, 80);
      expect(answerAfter, 1);
      await ends(after);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a host that passes no connections on for this key: the program is told that it is not allowed',
        () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      if (!File('$dir/client_noforward_ed25519').existsSync()) {
        return markTestSkipped('the key that may not forward is not there: run tool/test_sshd.sh again');
      }
      final client = await connect(key: 'client_noforward_ed25519');
      final (_, proxy) = await proxyThrough(client);

      final (held, answer) = await ask(proxy, loopback, port);
      expect(answer, 2);
      await held.ended.future.timeout(const Duration(seconds: 10));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the proxy says when the host passes no connections on at all, once; a place the host cannot connect '
        'to is that place\'s, and the program that asked is told', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      if (!File('$dir/client_noforward_ed25519').existsSync()) {
        return markTestSkipped('the key that may not forward is not there: run tool/test_sshd.sh again');
      }
      final refused = await connect(key: 'client_noforward_ed25519');
      final (refusing, refusingProxy) = await proxyThrough(refused);
      final saidOfRefusing = saidBy(refusing);
      for (var i = 0; i < 2; i++) {
        final (held, answer) = await ask(refusingProxy, loopback, port);
        expect(answer, 2);
        await held.ended.future.timeout(const Duration(seconds: 10));
      }
      expect(saidOfRefusing, hasLength(1));
      expect(saidOfRefusing.single.forward.id, 'd1');
      expect((saidOfRefusing.single.error as SSHChannelOpenError).code, 1);

      final client = await connect();
      final (forwards, proxy) = await proxyThrough(client);
      final said = saidBy(forwards);
      final (nobody, answer) = await ask(proxy, loopback, await freePortOnHost(client));
      expect(answer, 4);
      await nobody.ended.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(said, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a program that does not say where it wants to go is not kept for ever, and one that has said it is',
        () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      Socks5ProxyServer.debugHandshakeWithin = const Duration(milliseconds: 1500);
      addTearDown(() => Socks5ProxyServer.debugHandshakeWithin = const Duration(seconds: 30));
      final (_, proxy) = await proxyThrough(client);

      // One that was let through goes on for as long as it likes.
      final (through, answer) = await ask(proxy, loopback, remotePort);
      expect(answer, 0);

      final clock = Stopwatch()..start();
      // Nothing at all; half of the first part; the first part, and then nothing.
      final silent = await connectTo(proxy);
      final half = await connectTo(proxy);
      half.socket.add([5]);
      final stopped = await connectTo(proxy);
      stopped.socket.add([5, 1, 0]);
      expect(await stopped.take(2), [5, 0]);
      for (final held in [silent, half, stopped]) {
        await held.ended.future.timeout(const Duration(seconds: 10));
        expect(held.came, isEmpty);
      }
      expect(clock.elapsedMilliseconds, greaterThan(1000), reason: 'they were given no time');

      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(through.ended.isCompleted, isFalse);
      await thereAndBack(through);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('what the forward shows of itself: how many connections it has, and how many bytes went through', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, _) = await farEndOf(client, 'echo');
      final (forwards, proxy) = await proxyThrough(client);
      final shown = forwards.getSocks5Server('d1')!;
      expect((shown.activeConnections, shown.bytesTransferred), (0, 0));

      final (held, answer) = await ask(proxy, loopback, remotePort);
      expect(answer, 0);
      expect(shown.activeConnections, 1);
      await thereAndBack(held, bytes: 100000);
      expect(shown.bytesTransferred, 200000, reason: 'there and back, and nothing of what the proxy itself says');

      // The program is done, and says so: once the far end has ended its side too, it is no longer counted.
      await held.socket.close();
      await held.ended.future.timeout(const Duration(seconds: 10));
      await until(() => shown.activeConnections == 0);
      expect(shown.bytesTransferred, 200000);

      // One that goes away before it has said where it wants to go is no longer counted either, and not
      // only once it has been given up on.
      final leaver = await connectTo(proxy);
      leaver.socket.add([5, 1, 0]);
      expect(await leaver.take(2), [5, 0]);
      expect(shown.activeConnections, 1);
      leaver.socket.destroy();
      await until(() => shown.activeConnections == 0);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('what a program sends before it is let through, and faster than the far end reads once it is, waits '
        'where it is and not in this app; all of it arrives', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      const total = 64 * 1024 * 1024;
      final (remotePort, said) = await farEndOf(client, 'late 2 take 3');
      final (_, proxy) = await proxyThrough(client);

      final held = await connectTo(proxy);
      held.socket.add([5, 1, 0]);
      expect(await held.take(2), [5, 0]);
      // It asks, and does not wait for the answer before it sends.
      held.socket.add([5, 1, 0, ...loopback, remotePort >> 8, remotePort & 0xff]);
      var handedOver = 0;
      var stillSending = true;
      final sending = () async {
        final piece = Uint8List(64 * 1024);
        while (handedOver < total) {
          held.socket.add(piece);
          await held.socket.flush();
          handedOver += piece.length;
        }
        stillSending = false;
        await held.socket.close();
      }();

      // The host has not connected for it yet.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(held.came, isEmpty, reason: 'the far end let it in at once: this shows nothing');
      expect(stillSending, isTrue, reason: 'all of it was taken before the program was let through');
      expect(handedOver, lessThan(16 * 1024 * 1024));

      // It is let through, to a far end that reads nothing yet.
      expect((await held.take(10))[1], 0);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(stillSending, isTrue, reason: 'all of it was taken, with the far end reading nothing');
      expect(handedOver, lessThan(16 * 1024 * 1024));

      // And then all of it goes through.
      await sending.timeout(const Duration(seconds: 90));
      expect(await next(said, within: const Duration(seconds: 60)), 'came $total');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a program that goes away in the middle of it is no longer counted, and the far end is stopped', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      const total = 64 * 1024 * 1024;
      final (remotePort, said) = await farEndOf(client, 'send $total 60');
      final (forwards, proxy) = await proxyThrough(client);
      final shown = forwards.getSocks5Server('d1')!;

      final (held, answer) = await ask(proxy, loopback, remotePort);
      expect(answer, 0);
      await held.atLeast(1024 * 1024);
      held.reading.pause();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      held.socket.destroy();

      expect(await next(said), startsWith('broken '), reason: 'the far end went on sending to nobody');
      await until(() => shown.activeConnections == 0);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stopping it ends every connection, one that is being connected and one that is still saying where it '
        'wants to go among them; nothing is left open on the host, and it takes no new ones', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (remotePort, said) = await farEndOf(client, 'late 2');
      final (echoPort, echoSaid) = await farEndOf(client, 'echo');
      final (forwards, proxy) = await proxyThrough(client);
      final shown = forwards.getSocks5Server('d1')!;

      // One was let through.
      final (through, answer) = await ask(proxy, loopback, echoPort);
      expect(answer, 0);
      await thereAndBack(through, bytes: 1000);
      // One has asked, and waits for the host to connect.
      final asked = await connectTo(proxy);
      asked.socket.add([5, 1, 0]);
      expect(await asked.take(2), [5, 0]);
      asked.socket.add([5, 1, 0, ...loopback, remotePort >> 8, remotePort & 0xff]);
      // One has not said yet where it wants to go.
      final saying = await connectTo(proxy);
      saying.socket.add([5, 1, 0]);
      expect(await saying.take(2), [5, 0]);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(asked.came, isEmpty, reason: 'the far end let it in at once: this shows nothing');
      expect(shown.activeConnections, 3);

      await forwards.stopForward('d1');
      for (final held in [through, asked, saying]) {
        await held.ended.future.timeout(const Duration(seconds: 3));
      }
      expect(shown.activeConnections, 0);
      expect(await next(echoSaid), 'over', reason: 'the connection that was let through was left open on the host');
      await expectLater(Socket.connect(InternetAddress.loopbackIPv4, proxy), throwsA(isA<SocketException>()));
      // The host gets through a little later, for a proxy that is no longer there.
      expect(await next(said), 'over');
      expect(asked.came, isEmpty, reason: 'it was answered after the proxy was stopped');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('from a port on the host to one this device can reach:', () {
    /// A port on this device that sends back what comes, to every
    /// connection, and ends each when its other side has said that no more
    /// comes: the port, and every connection it has taken, with whether
    /// that one has ended.
    Future<(int, List<Held>)> echoHere() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final taken = <Held>[];
      server.listen((socket) {
        addTearDown(socket.destroy);
        taken.add(Held(socket, echo: true));
      });
      return (server.port, taken);
    }

    /// A forward from [hostPort] on the host to [localPort] on this device:
    /// its service, where it is `r1`.
    Future<PortForwardService> forwardFrom(SSHClient client, int hostPort, int localPort) async {
      final forwards = PortForwardService(client);
      addTearDown(forwards.dispose);
      await forwards.startRemoteForward(
        PortForward(
          id: 'r1',
          type: PortForwardType.remote,
          bindAddress: '127.0.0.1',
          bindPort: localPort,
          remoteHost: '127.0.0.1',
          remotePort: hostPort,
        ),
      );
      return forwards;
    }

    test('what a program on the host sends to the port there comes out here, and it gets the answer after it has '
        'said that no more comes', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (here, _) = await echoHere();
      final hostPort = await freePortOnHost(client);
      await forwardFrom(client, hostPort, here);

      final said = await hostRuns(client, 'there $hostPort $echoed');
      expect(await next(said, within: const Duration(seconds: 60)), 'back $echoed True');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('it goes on taking connections: a hundred and fifty, one after the other', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (here, taken) = await echoHere();
      final hostPort = await freePortOnHost(client);
      await forwardFrom(client, hostPort, here);

      expect(150, greaterThan(maxForwardConnectionsPerRule));
      final said = await hostRuns(client, 'many $hostPort 150');
      expect(await next(said, within: const Duration(seconds: 120)), 'through 150');
      expect(taken, hasLength(150));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('nothing listens here: whoever connected on the host is not left with a connection that takes what it '
        'sends', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final hostPort = await freePortOnHost(client);
      await forwardFrom(client, hostPort, await freePort());

      final said = await hostRuns(client, 'nowhere $hostPort');
      expect(await next(said, within: const Duration(seconds: 40)), 'gone');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('it says when this device cannot connect to where it leads: once, and again when it had worked in '
        'between', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final hostPort = await freePortOnHost(client);
      final here = await freePort();
      final forwards = await forwardFrom(client, hostPort, here);
      final said = saidBy(forwards);

      for (var i = 0; i < 2; i++) {
        expect(await next(await hostRuns(client, 'nowhere $hostPort'), within: const Duration(seconds: 40)), 'gone');
      }
      expect(said, hasLength(1));
      expect(said.single.forward.id, 'r1');
      expect(said.single.error, isA<SocketException>());

      // Something listens here now: a connection is made.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, here);
      server.listen((socket) => Held(socket, echo: true));
      expect(await next(await hostRuns(client, 'there $hostPort 65536'), within: const Duration(seconds: 40)),
          'back 65536 True');
      expect(said, hasLength(1));

      // And no longer: that is news.
      await server.close();
      expect(await next(await hostRuns(client, 'nowhere $hostPort'), within: const Duration(seconds: 40)), 'gone');
      expect(said, hasLength(2));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('stopping it ends its connections, and the host no longer listens', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (here, taken) = await echoHere();
      final hostPort = await freePortOnHost(client);
      final forwards = await forwardFrom(client, hostPort, here);

      final said = await hostRuns(client, 'hold $hostPort');
      expect(await next(said), 'in');
      await until(() => taken.length == 1);

      await forwards.stopForward('r1');
      expect(await next(said), 'ended');
      await taken.single.ended.future.timeout(const Duration(seconds: 10));
      expect(await next(await hostRuns(client, 'knock $hostPort')), 'refused');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stopped while this end is still being connected to for someone: that connection does not come through',
        () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final (here, taken) = await echoHere();
      final hostPort = await freePortOnHost(client);
      // This end takes its time to answer.
      final dialled = Completer<void>();
      final goOn = Completer<void>();
      final asItIs = PortForwardService.debugLocalDial;
      addTearDown(() => PortForwardService.debugLocalDial = asItIs);
      PortForwardService.debugLocalDial = (host, port) async {
        dialled.complete();
        await goOn.future;
        return asItIs(host, port);
      };
      final forwards = await forwardFrom(client, hostPort, here);

      final said = await hostRuns(client, 'hold $hostPort');
      expect(await next(said), 'in');
      await dialled.future.timeout(const Duration(seconds: 10));

      await forwards.stopForward('r1');
      goOn.complete();
      expect(await next(said), 'ended', reason: 'it came through after the forward was stopped');
      // Whatever was connected to here for it has ended too.
      await until(() => taken.length == 1);
      await taken.single.ended.future.timeout(const Duration(seconds: 10));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('stopped, it says nothing of this end not being connected to afterwards', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final hostPort = await freePortOnHost(client);
      // This end takes its time, and then refuses.
      final dialled = Completer<void>();
      final goOn = Completer<void>();
      final asItIs = PortForwardService.debugLocalDial;
      addTearDown(() => PortForwardService.debugLocalDial = asItIs);
      PortForwardService.debugLocalDial = (host, port) async {
        dialled.complete();
        await goOn.future;
        throw const SocketException('Connection refused');
      };
      final forwards = await forwardFrom(client, hostPort, await freePort());
      final saidOfIt = saidBy(forwards);

      final said = await hostRuns(client, 'hold $hostPort');
      expect(await next(said), 'in');
      await dialled.future.timeout(const Duration(seconds: 10));
      await forwards.stopForward('r1');
      goOn.complete();
      expect(await next(said), 'ended');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(saidOfIt, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

/// Waits until [holds], for no longer than ten seconds.
Future<void> until(bool Function() holds) async {
  final clock = Stopwatch()..start();
  while (!holds()) {
    if (clock.elapsed > const Duration(seconds: 10)) fail('it did not come to hold');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// One end of a connection, as a test holds it: what came and was not taken
/// yet, and whether it has ended. With [echo] it sends back what comes
/// instead, and ends its side when the other has said that no more comes.
class Held {
  Held(this.socket, {bool echo = false}) {
    void over() {
      if (!ended.isCompleted) ended.complete();
    }

    if (echo) {
      socket.cast<List<int>>().pipe(socket).then((_) => over(), onError: (Object _) => over());
    } else {
      reading = socket.listen(came.addAll, onDone: over, onError: (Object _) => over());
    }
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> reading;
  final came = <int>[];
  final ended = Completer<void>();

  /// Waits until [count] bytes have come and are held.
  Future<void> atLeast(int count) async {
    final clock = Stopwatch()..start();
    while (came.length < count) {
      if (ended.isCompleted || clock.elapsed > const Duration(seconds: 30)) {
        fail('${came.length} of the $count bytes that were to come did, and no more');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// The next [count] bytes that came.
  Future<List<int>> take(int count) async {
    await atLeast(count);
    final taken = came.sublist(0, count);
    came.removeRange(0, count);
    return taken;
  }
}
