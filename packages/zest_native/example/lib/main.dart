// ZestSSH 4.0 spike, developer only (never shipped): a VNC or RDP desktop drawn in Flutter,
// carried by zest_ssh_core's own SSH connection. VNC: a direct-streamlocal@openssh.com channel to
// the server's VNC Unix socket; RDP: a direct-tcpip channel to the RDP port as the SSH server
// sees it. Either is bridged to the Rust screen engine (packages/zest_native, features "vnc" and
// "rdp", which this app's pubspec turns on through the build hook); no local port is opened.
//
// Fields start from the environment (nothing is stored): ZS_PROTOCOL (vnc or rdp), ZS_SSH_HOST,
// ZS_SSH_PORT (2240), ZS_USER, ZS_PASSWORD, ZS_TILE (256; 0 = one image). VNC: ZS_VNC_SOCKET
// (/run/zestscreens/vnc.sock), ZS_VNC_PASSWORD, ZS_VNC_ENCODINGS (comma separated). RDP:
// ZS_RDP_HOST (127.0.0.1, as the SSH server sees it), ZS_RDP_PORT (13389), ZS_RDP_USER and
// ZS_RDP_PASSWORD (the SSH ones when not given), ZS_RDP_PIN (the certificate's SHA-256; without
// it the first connection shows the certificate's and offers to trust it), ZS_RDP_SIZE (WxH; the
// window's size when not given), ZS_RDP_FOLLOW=1 (resize the desktop with the window),
// ZS_RDP_GRAPHICS (gfx, the default: the graphics pipeline and RemoteFX; remotefx: RemoteFX surface
// commands only; bitmap: no codec, day 3's bitmap updates), ZS_RDP_H264 (avc444, the default: H.264
// in the graphics pipeline through Windows' Media Foundation decoder, AVC420 and AVC444; avc420:
// AVC420 only, converted to RGBA by us; off: no H.264).
// ZS_AUTOCONNECT=1 connects at start; ZS_SELFTEST=1 then runs the measurements and input checks
// of selftest.dart, writing JSON lines to ZS_SCREEN_LOG and a PNG of the window's content to
// ZS_SCREEN_SHOT; ZS_TOUCHTEST=1 adds the touch, zoom and soft keyboard checks after them
// (ZS_SELFTEST=touch runs those alone). ZS_BG_GRACE_S (60): how long a session stays open while
// the app is in the background (frames left in the engine meanwhile); after it the session and
// the SSH connection end cleanly and the app connects again when it comes back. A session the
// system ends meanwhile (Android 15 cuts a background app's sockets after about 5 s) also
// connects again on return. While hidden the session is paused (zest_screen_pause: VNC asks for
// nothing and turns continuous updates off, RDP sends Suppress Output) and resumed on return.
// ZS_CONTINUOUS_UPDATES=0 turns VNC's continuous updates off (one request per update, the
// fallback); ZS_FEED_DELAY_MS delays what the channel receives by that many milliseconds before
// the engine sees it (a longer round trip, to measure what continuous updates save).
//
// X (day 9): ZS_PROTOCOL=x11 is SSH X11 forwarding (x11_forward.dart): the program ZS_X_PROGRAM
// (xterm) runs on the host with x11-req and its windows go to the local X server ZS_X11_DISPLAY
// (DISPLAY-style; the test servers' stand-in is 127.0.0.1:41) with its cookie ZS_X11_COOKIE (hex;
// empty when it has no access control), untrusted (-X) unless ZS_X11_TRUSTED=1; the view then
// shows that local X server through its VNC socket (ZS_VNC_SOCKET, ZS_VNC_PASSWORD), standing in for
// the user's own screen. ZS_PROTOCOL=xprog is "X program in a VNC tab" (x_program.dart): ZS_X_PROGRAM
// in a private Xvnc on the host, shown here. ZS_SELFTEST=1 runs selftest.dart's runX in both.
//
// On Android the settings come from a JSON file in the app's files folder, on iOS from the same file
// in the app's Documents folder (env.dart). ZS_ORIENTATION=landscape keeps a phone in landscape (the
// iOS simulator runs headless on the Mac mini, where nothing can turn it).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_ssh_core/zest_ssh_core.dart';

import 'env.dart';
import 'screen_view.dart';
import 'selftest.dart';
import 'x11_forward.dart';
import 'x_program.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (env['ZS_ORIENTATION'] == 'landscape') {
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  }
  runApp(const ScreenSpikeApp());
}

class ScreenSpikeApp extends StatelessWidget {
  const ScreenSpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ZestSSH screen spike',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFFFF7A1A), brightness: Brightness.dark),
        home: const ScreenSpikePage(),
      );
}

class ScreenSpikePage extends StatefulWidget {
  const ScreenSpikePage({super.key});

  @override
  State<ScreenSpikePage> createState() => _ScreenSpikePageState();
}

class _ScreenSpikePageState extends State<ScreenSpikePage> {
  final _env = env;
  late final _host = TextEditingController(text: _env['ZS_SSH_HOST'] ?? '');
  late final _port = TextEditingController(text: _env['ZS_SSH_PORT'] ?? '2240');
  late final _user = TextEditingController(text: _env['ZS_USER'] ?? '');
  late final _password = TextEditingController(text: _env['ZS_PASSWORD'] ?? '');
  late final _socket = TextEditingController(text: _env['ZS_VNC_SOCKET'] ?? '/run/zestscreens/vnc.sock');
  late final _vncPassword = TextEditingController(text: _env['ZS_VNC_PASSWORD'] ?? '');
  late final _tile = TextEditingController(text: _env['ZS_TILE'] ?? '256');
  late String _protocol = switch (_env['ZS_PROTOCOL']) { 'rdp' => 'rdp', 'x11' => 'x11', 'xprog' => 'xprog', _ => 'vnc' };
  late final _xProgram = TextEditingController(text: _env['ZS_X_PROGRAM'] ?? 'xterm');
  late final _x11Display = TextEditingController(text: _env['ZS_X11_DISPLAY'] ?? _env['DISPLAY'] ?? '127.0.0.1:0');
  late final _x11Cookie = TextEditingController(text: _env['ZS_X11_COOKIE'] ?? '');
  late bool _x11Trusted = _env['ZS_X11_TRUSTED'] == '1';
  late final _rdpHost = TextEditingController(text: _env['ZS_RDP_HOST'] ?? '127.0.0.1');
  late final _rdpPort = TextEditingController(text: _env['ZS_RDP_PORT'] ?? '13389');
  late final _rdpUser = TextEditingController(text: _env['ZS_RDP_USER'] ?? '');
  late final _rdpPassword = TextEditingController(text: _env['ZS_RDP_PASSWORD'] ?? '');
  late final _rdpPin = TextEditingController(text: _env['ZS_RDP_PIN'] ?? '');
  late bool _follow = _env['ZS_RDP_FOLLOW'] == '1';

  /// The certificate a refused connection showed, to trust with one click.
  String? _offerPin;

  final _viewKey = GlobalKey();
  final _shotKey = GlobalKey();
  final _focus = FocusNode();
  SSHClient? _ssh;
  X11Forwarder? _x11;
  SSHSession? _x11Session;
  XProgram? _xprog;

  /// What the X modes add to the stats line.
  String _note = '';
  ScreenSession? _session;
  ScreenController? _controller;
  SoftKeyboard? _keyboard;
  late final AppLifecycleListener _lifecycle;
  Timer? _bgTimer;
  int _bgSinceUs = 0;
  int _bgBytesIn = 0;

  /// The session ended because the app stayed in the background: connect again on return.
  bool _reconnectOnResume = false;
  int? _resumedUs;
  String _status = '';
  String _stats = '';
  Timer? _statsTimer;
  final Map<String, int> _connectMs = {};

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
    if (_env['ZS_AUTOCONNECT'] == '1') WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
  }

  /// Background and back: frames stay in the engine while hidden (it merges them, nothing is
  /// drawn); after ZS_BG_GRACE_S the session ends cleanly; back in front, the latest picture is
  /// taken at once, or the app connects again.
  void _onLifecycle(AppLifecycleState state) {
    final now = ScreenSession.nowUs();
    final c = _controller, s = _session;
    log({'event': 'lifecycle', 'state': state.name, 'at_us': now, 'session_open': s != null && !s.isClosed});
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      if (c == null || c.paused) return;
      c.paused = true;
      s?.pause();
      _bgSinceUs = now;
      _bgBytesIn = s?.bytesIn ?? 0;
      final grace = int.tryParse(_env['ZS_BG_GRACE_S'] ?? '') ?? 60;
      _bgTimer?.cancel();
      _bgTimer = Timer(Duration(seconds: grace), () {
        log({'event': 'background_close', 'after_s': grace, 'bytes_in_meanwhile': (_session?.bytesIn ?? 0) - _bgBytesIn});
        _disconnect();
        _reconnectOnResume = true;
        if (mounted) setState(() => _status = 'Closed after $grace s in the background');
      });
    } else if (state == AppLifecycleState.resumed) {
      _bgTimer?.cancel();
      if (c != null && c.paused) {
        log({
          'event': 'resumed_open',
          'background_ms': (now - _bgSinceUs) ~/ 1000,
          'bytes_in_meanwhile': (s?.bytesIn ?? 0) - _bgBytesIn,
          'session_open': s != null && !s.isClosed,
        });
        _resumedUs = now;
        c.painted.clear();
        c.paused = false;
        s?.resume();
      } else if (_reconnectOnResume) {
        _reconnectOnResume = false;
        _resumedUs = now;
        _connect();
      }
    }
  }

  void log(Map<String, Object?> line) {
    final text = jsonLine(line);
    debugPrint(text);
    final path = _env['ZS_SCREEN_LOG'];
    if (path != null && path.isNotEmpty) File(path).writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
  }

  Future<void> _connect() async {
    setState(() => _status = 'Connecting...');
    final sw = Stopwatch()..start();
    try {
      X11Forwarder? fwd;
      if (_protocol == 'x11') {
        final cookie = _x11Cookie.text.trim();
        fwd = X11Forwarder(
          display: X11Display.parse(_x11Display.text.trim()),
          real: cookie.isEmpty ? const X11Auth.none() : X11Auth.cookie(hexBytes(cookie)),
          trusted: _x11Trusted,
          log: (m) {
            if (m['event'] == 'x11_channel') _connectMs.putIfAbsent('x11_first_channel', () => sw.elapsedMilliseconds);
            log(m);
          },
        );
        // -X: the Untrusted cookie from the local X server's SECURITY extension (before SSH).
        await fwd.start();
        _connectMs['x11_local_ready'] = sw.elapsedMilliseconds;
        _x11 = fwd;
      }
      final socket = await SSHSocket.connect(_host.text.trim(), int.parse(_port.text.trim()),
          timeout: const Duration(seconds: 10));
      _connectMs['tcp'] = sw.elapsedMilliseconds;
      // Spike: the test server's host key is accepted as it is (the app checks it through
      // KnownHostsService, as for every SSH host).
      final ssh = SSHClient(socket,
          username: _user.text.trim(),
          onPasswordRequest: () => _password.text,
          onVerifyHostKey: (_, _) => true,
          onX11Forward: fwd?.handle);
      await ssh.authenticated;
      // When and why the SSH connection ends (for the background checks).
      unawaited(ssh.done.then((_) => log({'event': 'ssh_done', 'at_us': ScreenSession.nowUs()}),
          onError: (Object e) => log({'event': 'ssh_done', 'error': '$e', 'at_us': ScreenSession.nowUs()})));
      _connectMs['ssh_authenticated'] = sw.elapsedMilliseconds;
      final rdp = _protocol == 'rdp';
      final SSHForwardChannel channel;
      final ScreenConnectOptions request;
      final tile = int.tryParse(_tile.text.trim()) ?? 256;
      if (rdp) {
        final target = _rdpHost.text.trim();
        channel = await ssh.forwardLocal(target, int.parse(_rdpPort.text.trim()));
        final (w, h) = _rdpSize();
        request = ScreenConnectOptions(
          protocol: ScreenProtocol.rdp,
          username: _rdpUser.text.isEmpty ? _user.text.trim() : _rdpUser.text.trim(),
          password: _rdpPassword.text.isEmpty ? _password.text : _rdpPassword.text,
          tlsPin: _rdpPin.text.trim().isNotEmpty ? _rdpPin.text.trim() : null,
          serverName: target,
          width: w,
          height: h,
          tileSize: tile,
          rdpGraphics: (_env['ZS_RDP_GRAPHICS'] ?? '').isNotEmpty ? _env['ZS_RDP_GRAPHICS'] : null,
          rdpH264: (_env['ZS_RDP_H264'] ?? '').isNotEmpty ? _env['ZS_RDP_H264'] : null,
        );
      } else if (_protocol == 'xprog') {
        // The X program in a private Xvnc on the host, the size of this window.
        final (w, h) = _rdpSize();
        final x = await XProgram.start(ssh, _xProgram.text.trim(), w, h);
        _connectMs['x_program_ready'] = sw.elapsedMilliseconds;
        _xprog = x;
        log({'event': 'x_program', 'display': x.display, 'size': '${w}x$h'});
        x.lines.listen((m) {
          log({'event': 'x_program_line', ...m});
          if (m.containsKey('exited') && mounted) setState(() => _status = 'The X program ended (${m['exited']})');
        });
        channel = await ssh.forwardLocalUnix(x.socketPath);
        request = ScreenConnectOptions.vnc(tileSize: tile);
      } else {
        channel = await ssh.forwardLocalUnix(_socket.text.trim());
        final encodings = _env['ZS_VNC_ENCODINGS'];
        request = ScreenConnectOptions.vnc(
          continuousUpdates: _env['ZS_CONTINUOUS_UPDATES'] == '0' ? false : null,
          password: _vncPassword.text.isNotEmpty ? _vncPassword.text : null,
          tileSize: tile,
          encodings: encodings != null && encodings.isNotEmpty ? encodings.split(',') : null,
        );
      }
      _connectMs['channel_open'] = sw.elapsedMilliseconds;
      final session = ScreenSession.open(request);
      final delay = int.tryParse(_env['ZS_FEED_DELAY_MS'] ?? '') ?? 0;
      session.attach(delay > 0 ? _delayed(channel.stream, Duration(milliseconds: delay)) : channel.stream, channel.sink,
          connectionDone: ssh.done);
      final controller = ScreenController(session)
        ..scancodeText = rdp
        ..followViewSize = rdp && _follow
        ..onClosed = (why) {
          log({'event': 'closed', 'why': why});
          if (!mounted) return;
          // Ended while in the background (Android 15 cuts a background app's sockets about 5 s
          // after it leaves the screen, unless a foreground service holds the process): clean up
          // and connect again when the app comes back.
          if (_controller?.paused ?? false) {
            _bgTimer?.cancel();
            _disconnect();
            _reconnectOnResume = true;
            setState(() => _status = 'Closed in the background: $why');
            return;
          }
          // A certificate not trusted yet: back to the form, which offers to trust it.
          final pin = RegExp(r'certificate not trusted: SHA-256 ([0-9a-f]{64})').firstMatch(why)?.group(1);
          if (pin != null) {
            _disconnect();
            setState(() {
              _offerPin = pin;
              _status = "The server's certificate is not trusted yet.";
            });
          } else {
            setState(() => _status = 'Closed: $why');
          }
        };
      session.events.listen((e) {
        if (e is ScreenConnected) {
          _connectMs['screen_connected'] = sw.elapsedMilliseconds;
          log({'event': 'connected', ...e.info, 'connect_ms': Map.of(_connectMs)});
        }
        if (e is ScreenResized) {
          log({'event': 'resized', 'width': e.width, 'height': e.height, 'at_us': ScreenSession.nowUs()});
        }
        if (e is ScreenClipboard) log({'event': 'clipboard', 'text': e.text});
        if (e is ScreenInfo) log({'event': 'info', ...e.info, 'at_us': ScreenSession.nowUs()});
        if (e is ScreenClosed) {
          log({'event': 'closed_reason', 'reason': e.reason.name, 'message': e.message, 'at_us': ScreenSession.nowUs()});
        }
      });
      if (fwd != null) {
        // The program, its windows forwarded to the local X server shown in this view.
        final t = sw.elapsedMilliseconds;
        final x11Session = await ssh.execute(_xProgram.text.trim(), x11: fwd.config);
        _connectMs['x11_exec'] = sw.elapsedMilliseconds - t;
        _x11Session = x11Session;
        unawaited(x11Session.done.then((_) {
          log({'event': 'x11_program_done', 'exit': x11Session.exitCode});
          if (mounted) setState(() => _status = 'The X program ended (${x11Session.exitCode})');
        }));
        _note = fwd.trusted ? 'X11 trusted (-Y)' : 'X11 untrusted (-X)';
      }
      var first = true;
      controller.addListener(() {
        // The first picture after coming back from the background.
        final r = _resumedUs;
        if (r != null && controller.painted.isNotEmpty) {
          _resumedUs = null;
          log({'event': 'resume_first_frame', 'ms': (controller.painted.first.paintedUs - r) / 1000});
        }
        if (first) {
          first = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _connectMs['first_frame_painted'] = sw.elapsedMilliseconds;
            log({'event': 'first_frame', 'connect_ms': Map.of(_connectMs)});
            final ready = _connectMs['x_program_ready'];
            if (ready != null) {
              _note = 'X program ready in ${ready - (_connectMs['ssh_authenticated'] ?? 0)} ms, '
                  'first frame ${_connectMs['first_frame_painted']} ms';
            }
            if (_env['ZS_SELFTEST'] == '1' || _env['ZS_SELFTEST'] == 'touch') unawaited(_selftest());
          });
        }
      });
      setState(() {
        _ssh = ssh;
        _session = session;
        _controller = controller;
        _keyboard = SoftKeyboard(controller);
        _status = '';
      });
      // A phone: the whole screen for the desktop (Android 15 draws apps under the system bars;
      // a swipe from the edge brings them back for a moment).
      if (Platform.isAndroid || Platform.isIOS) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateStats());
    } catch (e) {
      setState(() => _status = 'Failed: $e');
      log({'event': 'failed', 'error': '$e'});
    }
  }

  /// [input], each chunk handed on [delay] later (in order): a longer round trip for measurements.
  static Stream<Uint8List> _delayed(Stream<Uint8List> input, Duration delay) {
    late final StreamController<Uint8List> out;
    StreamSubscription<Uint8List>? sub;
    out = StreamController<Uint8List>(
      onListen: () {
        sub = input.listen(
          (d) => Timer(delay, () => out.isClosed ? null : out.add(d)),
          onError: (Object e) => Timer(delay, () => out.isClosed ? null : out.addError(e)),
          onDone: () => Timer(delay, () => out.close()),
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () => sub?.cancel(),
    );
    return out.stream;
  }

  /// The desktop size asked for at connect: ZS_RDP_SIZE, else the window's size.
  (int, int) _rdpSize() {
    final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(_env['ZS_RDP_SIZE'] ?? '');
    if (m != null) return (int.parse(m.group(1)!), int.parse(m.group(2)!));
    final size = MediaQuery.sizeOf(context);
    // No size yet (the app started with the screen off): a common desktop size.
    if (size.isEmpty) return (1280, 720);
    if (Platform.isAndroid || Platform.isIOS) {
      // A phone: a desktop of the screen's shape, 720 pixels on its short side (the view's own
      // size would be a tiny desktop; zoom shows the detail).
      final long = (720 * size.longestSide / size.shortestSide).floor() & ~1;
      return size.width >= size.height ? (long, 720) : (720, long);
    }
    // RDP's widths are even: the one at or under the window's, so the picture stays at 1:1 (and a
    // pixel less in height: the view can come out a fraction smaller than the window).
    return (size.width.floor() & ~1, (size.height - 1).floor());
  }

  int _shown = 0;
  void _updateStats() {
    final c = _controller;
    if (c == null || !mounted) return;
    final now = ScreenSession.nowUs();
    final recent = c.painted.skip(_shown).where((f) => now - f.paintedUs < 1000000).toList();
    _shown = c.painted.length;
    final lat = recent.map((f) => (f.paintedUs - f.firstChangeUs) / 1000).toList()..sort();
    setState(() => _stats = '${c.width} x ${c.height}   ${recent.length} fps   '
        '${lat.isEmpty ? '' : 'update to painted ${lat[lat.length ~/ 2].toStringAsFixed(1)} ms'}');
  }

  Future<void> _selftest() async {
    final c = _controller!;
    final t = SelfTest(
      session: _session!,
      controller: c,
      viewKey: _viewKey,
      shotKey: _shotKey,
      log: log,
    );
    if (_env['ZS_SELFTEST'] != 'touch') {
      if (_protocol == 'x11' || _protocol == 'xprog') {
        await t.runX(_env['ZS_SCREEN_SHOT']);
      } else if (_protocol == 'rdp') {
        await t.runRdp(_env['ZS_SCREEN_SHOT']);
      } else {
        await t.run(_env['ZS_SCREEN_SHOT']);
      }
    }
    if (_env['ZS_TOUCHTEST'] == '1' || _env['ZS_SELFTEST'] == 'touch') {
      await t.runTouch(keyboard: _keyboard!, rdp: _protocol == 'rdp');
    }
  }

  void _disconnect() {
    _statsTimer?.cancel();
    _keyboard?.hide();
    _keyboard = null;
    if (Platform.isAndroid || Platform.isIOS) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _session?.close();
    _x11Session?.close();
    _x11Session = null;
    unawaited(_x11?.close());
    _x11 = null;
    _xprog?.close();
    _xprog = null;
    _ssh?.close();
    _controller?.dispose();
    setState(() {
      _session = null;
      _controller = null;
      _ssh = null;
    });
  }

  @override
  void dispose() {
    _bgTimer?.cancel();
    _lifecycle.dispose();
    _disconnect();
    super.dispose();
  }

  Widget _field(TextEditingController c, String label, {bool secret = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(controller: c, obscureText: secret, decoration: InputDecoration(labelText: label)),
      );

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        body: Center(
          child: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
              const Text('Remote screen spike (developer only)', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'vnc', label: Text('VNC')),
                  ButtonSegment(value: 'rdp', label: Text('RDP')),
                  ButtonSegment(value: 'x11', label: Text('X11')),
                  ButtonSegment(value: 'xprog', label: Text('Run X program')),
                ],
                selected: {_protocol},
                onSelectionChanged: (s) => setState(() => _protocol = s.first),
              ),
              const SizedBox(height: 8),
              _field(_host, 'SSH host'),
              _field(_port, 'SSH port'),
              _field(_user, 'SSH user'),
              _field(_password, 'SSH password', secret: true),
              if (_protocol == 'vnc') ...[
                _field(_socket, 'VNC Unix socket on the server'),
                _field(_vncPassword, 'VNC password', secret: true),
              ] else if (_protocol == 'xprog') ...[
                _field(_xProgram, 'X program to run on the server'),
              ] else if (_protocol == 'x11') ...[
                _field(_xProgram, 'X program to run on the server'),
                _field(_x11Display, 'Local X server (DISPLAY)'),
                _field(_x11Cookie, 'Its MIT-MAGIC-COOKIE-1, hex (empty: none)', secret: true),
                CheckboxListTile(
                  value: _x11Trusted,
                  onChanged: (v) => setState(() => _x11Trusted = v ?? false),
                  title: const Text('Trusted (-Y): remote programs get full access to this X server'),
                  contentPadding: EdgeInsets.zero,
                ),
                _field(_socket, "Test only: the local X server's VNC socket, to see it"),
                _field(_vncPassword, 'Its VNC password', secret: true),
              ] else ...[
                _field(_rdpHost, 'RDP host, as the SSH server sees it'),
                _field(_rdpPort, 'RDP port'),
                _field(_rdpUser, 'RDP user (the SSH user when empty)'),
                _field(_rdpPassword, 'RDP password (the SSH password when empty)', secret: true),
                _field(_rdpPin, 'Certificate SHA-256 (trusted)'),
                CheckboxListTile(
                  value: _follow,
                  onChanged: (v) => setState(() => _follow = v ?? false),
                  title: const Text('Resize the desktop with the window'),
                  contentPadding: EdgeInsets.zero,
                ),
              ],
              _field(_tile, 'Tile size (0 = whole screen)'),
              const SizedBox(height: 8),
              FilledButton(onPressed: _connect, child: const Text('Connect')),
              if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_status)),
              if (_offerPin != null) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText('SHA-256 $_offerPin', style: const TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () {
                    _rdpPin.text = _offerPin!;
                    setState(() => _offerPin = null);
                    _connect();
                  },
                  child: const Text('Trust this certificate and connect'),
                ),
              ],
            ]),
          ),
        ),
      );
    }
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(child: _screen(controller)),
        Positioned(top: MediaQuery.paddingOf(context).top + 4, right: 4, child: _toolbar(controller)),
      ]),
    );
  }

  /// Touch mode, the soft keyboard, back to fit, disconnect (small, top right).
  Widget _toolbar(ScreenController c) {
    final kb = _keyboard;
    Widget button(IconData icon, String tip, VoidCallback onPressed, {bool on = false}) => IconButton.filledTonal(
          isSelected: on,
          tooltip: tip,
          iconSize: 20,
          visualDensity: VisualDensity.compact,
          onPressed: onPressed,
          icon: Icon(icon),
        );
    final touch = c.touchMode == TouchMode.touch;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      button(touch ? Icons.touch_app : Icons.mouse, touch ? 'Touch (switch to Mouse pointer)' : 'Mouse pointer (switch to Touch)',
          () {
        setState(() => c.touchMode = touch ? TouchMode.pointer : TouchMode.touch);
        c.resetZoom();
      }),
      button(Icons.keyboard, 'Keyboard', () {
        if (kb == null) return;
        setState(() => kb.shown ? kb.hide() : kb.show());
      }, on: kb?.shown ?? false),
      button(Icons.fit_screen, 'Fit', c.resetZoom),
      button(Icons.close, 'Disconnect', _disconnect),
    ]);
  }

  Widget _screen(ScreenController controller) {
    return RepaintBoundary(
        key: _shotKey,
        child: Stack(children: [
          Positioned.fill(child: RemoteScreenView(key: _viewKey, controller: controller, focusNode: _focus)),
          Positioned(
            left: 8,
            bottom: 8,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(_status.isEmpty ? [_stats, if (_note.isNotEmpty) _note].join('   ') : _status,
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ),
        ]),
      );
  }
}
