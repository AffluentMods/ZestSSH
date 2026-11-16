import 'dart:async';
import 'dart:convert';
import 'dart:io' show sleep;
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/desktop/screen_pane.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_probe.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart' show HostsHomePage;
import 'package:zestssh/features/screens/xprogram/x_program_dialog.dart';
import 'package:zestssh/features/screens/xprogram/x_program_recent.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart' show xProgramInstallCommand;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/desktop_shell.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart' show accountSetupNeedsAttentionProvider;
import 'package:zestssh/ui/screens/settings/remote_screens_settings.dart';
import 'package:zestssh/ui/screens/terminal/widgets/host_key_changed_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/screens/screen_clipboard_test.dart' show FakeClipboardIo;
import '../features/screens/view/screen_view_fixture.dart' show settleFrames;
import 'shots_util.dart';

/// Pictures of remote screens (4.0, steps 1 and 2) on a computer and a phone,
/// dark (Graphite), with the real fonts. The screen tabs run on the fake
/// engine (zest_native's FakeScreenNative) and show a made-up desktop drawn
/// here, never a real screenshot; every host, address and program is made up:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/remote_screens_shots_test.dart
///
/// Pictures land in build/shots/remote-screens-4.0/.
const _dir = 'remote-screens-4.0';

/// The computer's pictures are taken as on a computer (its controls' sizes).
final _computer = TargetPlatformVariant.only(TargetPlatform.windows);

const _computerSize = Size(1440, 900);
const _phoneSize = Size(412, 915);

// ---------------------------------------------------------------------------
// The made-up remote picture.

/// What the fake remote shows: a desktop with two windows, or an X program
/// (xterm) on its own display.
enum _Scene { desktop, xterm }

var _scene = _Scene.desktop;

/// A tile decoder that paints the made-up scene at the tile's size instead of
/// its pixels (widget tests have no engine thread; see screen_view_fixture's
/// syncDecode).
Future<ui.Image> _paintScene(ScreenTile t) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(t.width.toDouble(), t.height.toDouble());
  switch (_scene) {
    case _Scene.desktop:
      _paintDesktop(canvas, size);
    case _Scene.xterm:
      _paintXterm(canvas, size);
  }
  final picture = recorder.endRecording();
  final image = picture.toImageSync(t.width, t.height);
  picture.dispose();
  return image;
}

/// The whole picture as one tile (its pixels unused: [_paintScene] draws it).
ScreenTile _wholeTile(int width, int height) => ScreenTile(0, 0, width, height, Uint8List(width * height * 4));

double _textWidth(InlineSpan span) {
  final p = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
  final w = p.width;
  p.dispose();
  return w;
}

void _text(Canvas c, InlineSpan span, Offset at) {
  final p = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
  p.paint(c, at);
  p.dispose();
}

TextSpan _sans(String s, double size, Color color, {FontWeight weight = FontWeight.w400}) =>
    TextSpan(text: s, style: TextStyle(fontFamily: 'GeistSans', fontSize: size, color: color, fontWeight: weight));

TextStyle _mono(double size, Color color) => TextStyle(fontFamily: 'JetBrainsMono', fontSize: size, color: color, height: 1.35);

/// A window with its title bar: [paintBody] draws inside it.
void _window(Canvas c, Rect r, double s, String title,
    {required Color bar, required Color body, required Color ink, required void Function(Rect body) paintBody}) {
  final rr = RRect.fromRectAndRadius(r, Radius.circular(10 * s));
  c.drawRRect(
      rr.shift(Offset(0, 12 * s)),
      Paint()
        ..color = const Color(0x77000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 24 * s));
  c.save();
  c.clipRRect(rr);
  c.drawRect(r, Paint()..color = body);
  final barRect = Rect.fromLTWH(r.left, r.top, r.width, 38 * s);
  c.drawRect(barRect, Paint()..color = bar);
  final t = _sans(title, 13.5 * s, ink, weight: FontWeight.w500);
  _text(c, t, Offset(r.center.dx - _textWidth(t) / 2, r.top + 10 * s));
  for (var i = 0; i < 3; i++) {
    c.drawCircle(Offset(r.right - (18 + i * 24) * s, r.top + 19 * s), 6.5 * s,
        Paint()..color = i == 0 ? const Color(0xFFE5534B) : ink.withValues(alpha: 0.35));
  }
  paintBody(Rect.fromLTRB(r.left, barRect.bottom, r.right, r.bottom));
  c.restore();
}

void _paintDesktop(Canvas c, Size size) {
  final s = size.width / 1600;
  final all = Offset.zero & size;
  c.drawRect(
      all,
      Paint()
        ..shader = ui.Gradient.linear(Offset.zero, Offset(size.width, size.height),
            const [Color(0xFF141B33), Color(0xFF1D4459), Color(0xFF2A7366)], const [0, 0.55, 1]));
  void glow(Offset at, double radius, Color color) => c.drawCircle(
      at, radius, Paint()..shader = ui.Gradient.radial(at, radius, [color, color.withValues(alpha: 0)]));
  glow(Offset(size.width * 0.84, size.height * 0.82), 520 * s, const Color(0x66FF7A1A));
  glow(Offset(size.width * 0.12, size.height * 0.18), 460 * s, const Color(0x557B5CFF));

  // The top bar.
  const white = Color(0xFFF2F2F2);
  c.drawRect(Rect.fromLTWH(0, 0, size.width, 30 * s), Paint()..color = const Color(0xD90B0F17));
  _text(c, _sans('Activities', 13 * s, white, weight: FontWeight.w500), Offset(16 * s, 7 * s));
  final clock = _sans('Mon 9 Nov   10:42', 13 * s, white, weight: FontWeight.w500);
  _text(c, clock, Offset(size.width / 2 - _textWidth(clock) / 2, 7 * s));
  for (var i = 0; i < 3; i++) {
    c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(size.width - (34 + i * 26) * s, 9 * s, 14 * s, 12 * s), Radius.circular(3 * s)),
        Paint()..color = white.withValues(alpha: 0.85));
  }

  // A terminal.
  _window(c, Rect.fromLTWH(110 * s, 96 * s, 800 * s, 470 * s), s, 'demo@desk-01: ~',
      bar: const Color(0xFF2A2D34), body: const Color(0xFF1B1D22), ink: const Color(0xFFE6E6E6), paintBody: (b) {
    const green = Color(0xFF7BD88F), blue = Color(0xFF6CB6FF), fg = Color(0xFFD7DAE0), dim = Color(0xFF8B919C);
    final st = _mono(15 * s, fg);
    TextSpan prompt(String cmd) => TextSpan(style: st, children: [
          TextSpan(text: 'demo@desk-01', style: st.copyWith(color: green)),
          const TextSpan(text: ':'),
          TextSpan(text: '~', style: st.copyWith(color: blue)),
          TextSpan(text: '\$ $cmd'),
        ]);
    final lines = <TextSpan>[
      prompt('uptime'),
      TextSpan(text: ' 10:42:07 up 12 days,  3:18,  1 user,  load average: 0.21, 0.18, 0.12', style: st),
      prompt('df -h /srv'),
      TextSpan(text: 'Filesystem      Size  Used Avail Use% Mounted on', style: st.copyWith(color: dim)),
      TextSpan(text: '/dev/sda2       916G  402G  468G  47% /srv', style: st),
      prompt('ls ~/projects'),
      TextSpan(style: st, children: [
        TextSpan(text: 'garden-planner  ', style: st.copyWith(color: blue)),
        TextSpan(text: 'photo-sorter  ', style: st.copyWith(color: blue)),
        const TextSpan(text: 'notes.md  todo.txt'),
      ]),
      prompt(''),
    ];
    var y = b.top + 14 * s;
    for (final l in lines) {
      _text(c, l, Offset(b.left + 16 * s, y));
      y += 15 * s * 1.35 + 2 * s;
    }
    // The cursor after the last prompt.
    final last = _textWidth(lines.last);
    c.drawRect(Rect.fromLTWH(b.left + 16 * s + last, y - (15 * 1.35 + 2) * s + 2 * s, 9 * s, 18 * s),
        Paint()..color = fg);
  });

  // A file manager.
  _window(c, Rect.fromLTWH(760 * s, 300 * s, 720 * s, 500 * s), s, 'Projects',
      bar: const Color(0xFFE9E9EC), body: const Color(0xFFFAFAFB), ink: const Color(0xFF2B2E35), paintBody: (b) {
    const ink = Color(0xFF2B2E35);
    final side = Rect.fromLTWH(b.left, b.top, 170 * s, b.height);
    c.drawRect(side, Paint()..color = const Color(0xFFF0F0F3));
    final places = ['Home', 'Documents', 'Downloads', 'Pictures', 'Music', 'Trash'];
    for (var i = 0; i < places.length; i++) {
      if (i == 1) {
        c.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(b.left + 8 * s, b.top + (14 + i * 34) * s, 154 * s, 28 * s), Radius.circular(6 * s)),
            Paint()..color = const Color(0x33FF7A1A));
      }
      _text(c, _sans(places[i], 13.5 * s, ink), Offset(b.left + 22 * s, b.top + (19 + i * 34) * s));
    }
    final items = [
      ('garden-planner', const Color(0xFF5B9BD5), true),
      ('photo-sorter', const Color(0xFF5B9BD5), true),
      ('backups', const Color(0xFF5B9BD5), true),
      ('recipes', const Color(0xFF5B9BD5), true),
      ('notes.md', const Color(0xFF9AA0AA), false),
      ('budget.ods', const Color(0xFF4FAE78), false),
      ('trip.pdf', const Color(0xFFE5534B), false),
      ('logo.png', const Color(0xFFFF7A1A), false),
    ];
    for (var i = 0; i < items.length; i++) {
      final col = i % 4, row = i ~/ 4;
      final x = side.right + (28 + col * 128) * s, y = b.top + (26 + row * 150) * s;
      final (name, color, folder) = items[i];
      final icon = Rect.fromLTWH(x + 22 * s, y, 64 * s, folder ? 50 * s : 64 * s);
      if (folder) {
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(icon.left, icon.top - 8 * s, 28 * s, 14 * s), Radius.circular(4 * s)),
            Paint()..color = color.withValues(alpha: 0.8));
      }
      c.drawRRect(RRect.fromRectAndRadius(icon, Radius.circular(7 * s)), Paint()..color = color);
      final label = _sans(name, 12.5 * s, ink);
      _text(c, label, Offset(x + 54 * s - _textWidth(label) / 2, y + 74 * s));
    }
  });

  // The dock.
  final dock = Rect.fromCenter(center: Offset(size.width / 2, size.height - 44 * s), width: 420 * s, height: 64 * s);
  c.drawRRect(RRect.fromRectAndRadius(dock, Radius.circular(18 * s)), Paint()..color = const Color(0x8C0B0F17));
  const apps = [Color(0xFFFF7A1A), Color(0xFF5B9BD5), Color(0xFF4FAE78), Color(0xFFA879E8), Color(0xFFE6A23C), Color(0xFF2A2D34)];
  for (var i = 0; i < apps.length; i++) {
    c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(dock.left + (22 + i * 66) * s, dock.top + 10 * s, 44 * s, 44 * s), Radius.circular(11 * s)),
        Paint()..color = apps[i]);
  }
}

/// An X program on its own display: xterm, at the display's size.
void _paintXterm(Canvas c, Size size) {
  final s = size.width / 1320;
  c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0E1013));
  const green = Color(0xFF7BD88F), blue = Color(0xFF6CB6FF), fg = Color(0xFFD7DAE0), dim = Color(0xFF8B919C);
  const ok = Color(0xFF4FAE78);
  final st = _mono(16 * s, fg);
  TextSpan prompt(String cmd) => TextSpan(style: st, children: [
        TextSpan(text: 'deploy@web-01', style: st.copyWith(color: green)),
        const TextSpan(text: ':'),
        TextSpan(text: '~', style: st.copyWith(color: blue)),
        TextSpan(text: '\$ $cmd'),
      ]);
  final lines = <TextSpan>[
    prompt('systemctl status nginx --no-pager'),
    TextSpan(style: st, children: [
      TextSpan(text: '● ', style: st.copyWith(color: ok)),
      const TextSpan(text: 'nginx.service - A high performance web server and a reverse proxy server'),
    ]),
    TextSpan(text: '     Loaded: loaded (/lib/systemd/system/nginx.service; enabled; preset: enabled)', style: st),
    TextSpan(style: st, children: [
      const TextSpan(text: '     Active: '),
      TextSpan(text: 'active (running)', style: st.copyWith(color: ok)),
      const TextSpan(text: ' since Mon 2026-11-09 08:14:52 UTC; 2h 27min ago'),
    ]),
    TextSpan(text: '       Docs: man:nginx(8)', style: st),
    TextSpan(text: '   Main PID: 1204 (nginx)', style: st),
    TextSpan(text: '      Tasks: 5 (limit: 9440)', style: st),
    TextSpan(text: '     Memory: 7.9M', style: st),
    TextSpan(text: '        CPU: 1.204s', style: st),
    TextSpan(text: '', style: st),
    prompt('ls /var/www'),
    TextSpan(style: st, children: [
      TextSpan(text: 'html  shop  status', style: st.copyWith(color: blue)),
    ]),
    prompt('tail -n 3 /var/log/nginx/access.log'),
    TextSpan(text: '10.0.0.15 - - [09/Nov/2026:10:41:58 +0000] "GET /shop/ HTTP/2.0" 200 5120', style: st.copyWith(color: dim)),
    TextSpan(text: '10.0.0.15 - - [09/Nov/2026:10:42:01 +0000] "GET /shop/cart HTTP/2.0" 200 2311', style: st.copyWith(color: dim)),
    TextSpan(text: '10.0.0.22 - - [09/Nov/2026:10:42:05 +0000] "GET /status HTTP/2.0" 204 0', style: st.copyWith(color: dim)),
    prompt(''),
  ];
  var y = 10 * s;
  final step = 16 * s * 1.35;
  for (final l in lines) {
    _text(c, l, Offset(10 * s, y));
    y += step;
  }
  c.drawRect(Rect.fromLTWH(10 * s + _textWidth(lines.last), y - step + 2 * s, 10 * s, 19 * s), Paint()..color = fg);
}

// ---------------------------------------------------------------------------
// The computer's shell (as test/visual/shell_shots_test.dart has it).

/// Quiet stand-ins for the desktop plugins the shell calls.
void _stubPlugins() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
    switch (call.method) {
      case 'isMaximized':
      case 'isFullScreen':
      case 'isMinimized':
        return false;
      default:
        return null;
    }
  });
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
}

/// A VNC server's side of a Test, all in memory (screen_probe_test's).
class _Server {
  _Server(List<int> said) {
    input.add(Uint8List.fromList(said));
    output.stream.listen((_) {});
  }

  final input = StreamController<Uint8List>();
  final output = StreamController<List<int>>();

  ScreenChannel get channel => ScreenChannel(input.stream, output.sink);
}

class _Route implements ScreenProbeRoute {
  _Route(this.server);
  final _Server server;

  @override
  Future<ScreenChannel> open() async {
    // As long as a VNC server on the LAN takes to greet (the result says it).
    sleep(const Duration(milliseconds: 23));
    return server.channel;
  }

  @override
  Future<void> close() async {}
}

List<int> _banner(String v) => ascii.encode('RFB $v\n');

/// Sessions the harness sets directly, some of them remote screens.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> sessions) => state = sessions;

  final screens = <String>{};
  final xPrograms = <String>{};

  /// What the VNC server behind a Test says.
  List<int> greeting = const [];

  @override
  bool isScreen(String sessionId) => screens.contains(sessionId);

  @override
  bool isXProgram(String sessionId) => xPrograms.contains(sessionId);

  @override
  String? xProgramNameOf(String sessionId) => xPrograms.contains(sessionId) ? 'xterm' : null;

  @override
  Future<ScreenProbeRoute> openScreenProbe(Connection carrier, ScreenTarget target, {ConnectionLogCallback? onLog}) async {
    // As long as signing in to the SSH host on the LAN takes (the result says it).
    sleep(const Duration(milliseconds: 184));
    return _Route(_Server(greeting));
  }
}

/// A live-looking SSH shell that sends nothing anywhere.
class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

/// A fixed Juiced account (hosted Cloud), without RevenueCat or the backend.
class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Health extends ConnectionHealthNotifier {}

class _ScreenTrust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;
  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => true;
  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

const _demoAccount = UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex');

/// The made-up hosts: four SSH hosts and two remote screens behind them.
Future<AppDatabase> _seeded() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final at = DateTime(2026, 11, 8);
  Future<void> add(String id, String label, String host,
          {String protocol = 'ssh', int port = 22, String? via, String? options, int? color}) =>
      db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            port: Value(port),
            protocol: Value(protocol),
            connectViaId: Value(via),
            screenOptions: Value(options),
            colorValue: Value(color),
            lastConnected: Value(at),
            createdAt: at,
            updatedAt: at,
          ));
  await add('c-web', 'web-01', '10.0.0.21', color: 0xFFFF7A1A);
  await add('c-db', 'db-01', '10.0.0.31');
  await add('c-nas', 'nas', '10.0.0.12', color: 0xFF4F9D69);
  await add('c-pihole', 'pihole', '10.0.0.53');
  await add('c-desk', 'desk-01', 'localhost', protocol: 'vnc', port: 5900, via: 'c-web', options: '{"v":1}');
  await add('c-media', 'media-pc', 'localhost', protocol: 'vnc', port: 5901, via: 'c-nas', options: '{"v":1}');
  return db;
}

/// An RDP host (4.0), reached directly, for the pictures of its editor
/// (added where they are taken, so the other pictures keep their hosts).
Future<void> _addRdpHost(AppDatabase db) => db.into(db.connections).insert(ConnectionsCompanion.insert(
      id: 'c-pc',
      label: 'office-pc',
      host: '10.0.0.40',
      port: const Value(3389),
      protocol: const Value('rdp'),
      screenOptions: const Value('{"v":1,"scaling":"remote_resize"}'),
      createdAt: DateTime(2026, 11, 13),
      updatedAt: DateTime(2026, 11, 13),
    ));

const _osKinds = {
  'os_kind_c-web': 'ubuntu',
  'os_kind_c-db': 'debian',
  'os_kind_c-nas': 'debian',
  'os_kind_c-pihole': 'raspbian',
};

/// A terminal with a prompt, like a fresh session.
Terminal _terminal(String user, String host) {
  final t = Terminal(maxLines: 1000);
  t.resize(160, 40);
  const g = '\x1b[32m', b = '\x1b[34m', o = '\x1b[0m';
  t.write('Welcome to Ubuntu 24.04.3 LTS (GNU/Linux 6.8.0-124-generic x86_64)\r\n\r\n');
  t.write('$g$user@$host$o:$b~$o\$ ');
  return t;
}

SessionState _terminalSession(String id, String connectionId, String label) => SessionState(
      status: SessionStatus.connected,
      connectionId: connectionId,
      connectionLabel: label,
      host: '10.0.0.21',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: connectionId,
        terminal: _terminal('deploy', label),
        shell: _Shell(),
        startedAt: DateTime(2026, 11, 9, 9, 12),
      ),
    );

class _Harness {
  _Harness(this.key, this.container, this.db, this.native);
  final GlobalKey key;
  final ProviderContainer container;
  final AppDatabase db;
  final FakeScreenNative native;

  _Sessions get sessions => container.read(activeSessionsProvider.notifier) as _Sessions;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final graphite = BuiltInThemes.getById('graphite');

  setUpAll(() async {
    if (shotsEnabled) await loadShotFonts();
  });

  setUp(() {
    L10nGlobal.update(en);
    AppColors.applyTheme(graphite.colorScheme);
    _scene = _Scene.desktop;
    ScreenPane.debugDecodeTile = _paintScene;
    ScreenPane.debugClipboard = FakeClipboardIo()..text = 'kept here';
  });
  tearDown(() {
    ScreenPane.debugDecodeTile = null;
    ScreenPane.debugClipboard = null;
    debugHostFormOnComputer = null;
  });

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> snap(WidgetTester tester, GlobalKey key, String name, {double pixelRatio = 1.5}) =>
      saveShot(tester, key, '$_dir/$name', pixelRatio: pixelRatio);

  /// The computer's whole window, the app's shell in Graphite, as
  /// shell_shots_test's pumpShell draws it.
  Future<_Harness> pumpShell(WidgetTester tester, {Map<String, Object> prefsExtra = const {}}) async {
    _stubPlugins();
    realShadows();
    SharedPreferences.setMockInitialValues({
      'app_theme_id': 'graphite',
      if (kAppToTerminalThemeId['graphite'] != null) 'terminal_theme': kAppToTerminalThemeId['graphite']!,
      ..._osKinds,
      ...prefsExtra,
    });
    final prefs = await SharedPreferences.getInstance();
    final db = await _seeded();
    addTearDown(db.close);
    tester.view.physicalSize = _computerSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      localStateStoreProvider.overrideWithValue(LocalStateStore(db)),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => _demoAccount),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      syncedAvatarUrlProvider.overrideWith((ref) => SyncedAvatarNotifier()),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
      appThemeIdProvider.overrideWith((ref) => 'graphite'),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 11, 9, 10, 42))),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: graphite.toThemeData(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DesktopShell(),
        ),
      ),
    ));
    await settle(tester);
    return _Harness(key, container, db, FakeScreenNative());
  }

  Future<void> tearDownShell(WidgetTester tester) async {
    plainShadows();
    Redactor.instance.enabled = false;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 7));
  }

  /// A remote screen connected on the fake engine, [width] by [height].
  Future<(ScreenShellService, FakeScreenSession)> connectScreen(
      WidgetTester tester, _Harness h, String connectionId, {required int width, required int height}) async {
    final toServer = StreamController<List<int>>();
    final fromServer = StreamController<Uint8List>();
    addTearDown(() {
      unawaited(toServer.close());
      unawaited(fromServer.close());
    });
    final shell = ScreenShellService(
      target: const DirectTlsTarget('10.0.0.40', 5900),
      trust: _ScreenTrust(),
      native: h.native,
      connectionId: connectionId,
      openDirect: (_, _) async => ScreenChannel(fromServer.stream, toServer.sink),
    );
    final before = h.native.sessions.length;
    final connecting = shell.connect();
    for (var i = 0; i < 10; i++) {
      await tester.pump();
      if (h.native.sessions.length > before) break;
    }
    final engine = h.native.sessions.last;
    engine.connect(name: 'desk-01:0', width: width, height: height);
    await tester.pump();
    await connecting;
    return (shell, engine);
  }

  /// A connected screen session; an X program's is its SSH host's address.
  SessionState screenState(String id, String connectionId, String label, ScreenShellService shell,
          {String host = 'localhost', int port = 5900}) =>
      SessionState(
        status: SessionStatus.connected,
        connectionId: connectionId,
        connectionLabel: label,
        host: host,
        port: port,
        session: TerminalSession(
          id: id,
          connectionId: connectionId,
          terminal: Terminal(),
          shell: shell,
          startedAt: DateTime(2026, 11, 9, 10, 30),
        ),
      );

  /// Shows [sessionId]'s tab in front.
  Future<void> front(WidgetTester tester, _Harness h, String sessionId) async {
    await tester.pump();
    final tabs = h.container.read(workTabsProvider.notifier);
    final tab = tabs.tabContaining(sessionId);
    if (tab != null) tabs.setActiveTab(tab.id);
    h.container.read(v3ActiveSessionTabProvider.notifier).state = sessionId;
    h.container.read(desktopSelectedTabProvider.notifier).state = 0;
    await settle(tester);
  }

  /// web-01's terminal and desk-01's screen open, the screen in front with
  /// its picture.
  Future<FakeScreenSession> openDesk(WidgetTester tester, _Harness h) async {
    final (shell, engine) = await connectScreen(tester, h, 'c-desk', width: 1600, height: 1000);
    h.sessions.screens.add('s-desk');
    h.sessions.set({
      's-web': _terminalSession('s-web', 'c-web', 'web-01'),
      's-desk': screenState('s-desk', 'c-desk', 'desk-01', shell),
    });
    await front(tester, h, 's-desk');
    engine.frames.add(ScreenFrame(seq: 1, width: 1600, height: 1000, updates: 1, tiles: [_wholeTile(1600, 1000)]));
    engine.emit(ScreenEventKind.frame, a: 1);
    await settleFrames(tester);
    await settle(tester);
    return engine;
  }

  testWidgets('computer: a screen tab, connected, with its toolbar; its session panel (F8)', (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester);
    await openDesk(tester, h);
    expect(find.byKey(const ValueKey('screen-toolbar-clipboard')), findsOneWidget);
    // The status bar names the screen in front, not the SSH tab beside it.
    expect(tester.widget<Text>(find.byKey(const ValueKey('status-user-host'))).data, 'localhost:5900');
    await snap(tester, h.key, 'computer-screen-tab-connected');

    await tester.sendKeyEvent(LogicalKeyboardKey.f8);
    await settle(tester);
    if (find.byKey(const ValueKey('screen-panel')).evaluate().isEmpty) {
      // The picture did not have the keyboard: the toolbar's button opens the same panel.
      await tester.tap(find.byKey(const ValueKey('screen-toolbar-menu')));
      await settle(tester);
    }
    await snap(tester, h.key, 'computer-screen-tab-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets('computer: a screen tab under recording mode', (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester);
    await openDesk(tester, h);
    Redactor.instance.enabled = true;
    h.container.read(recordingModeProvider.notifier).state = true;
    await settle(tester);
    expect(find.byKey(const ValueKey('screen-recording-cover')), findsOneWidget);
    await snap(tester, h.key, 'computer-screen-tab-recording');
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets('computer: a screen tab that dropped and gave up; an X program that ended', (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester);
    h.sessions.screens.addAll({'s-desk', 's-x'});
    h.sessions.xPrograms.add('s-x');
    final nothing = connectionFailureText(const ScreenFailure(ScreenFailureKind.nothingAnswers,
        'the SSH host refused the channel (2: connect failed)',
        carrier: 'web-01', address: 'localhost:5900'));
    h.sessions.set({
      's-web': _terminalSession('s-web', 'c-web', 'web-01'),
      's-desk': SessionState.disconnected(
        connectionId: 'c-desk',
        connectionLabel: 'desk-01',
        host: 'localhost',
        port: 5900,
        errorMessage: nothing,
        connectionLog: const [
          'screen: Opening the screen at localhost:5900',
          'error: ScreenFailure(nothingAnswers: the SSH host refused the channel (2: connect failed))',
        ],
        dropped: true,
      ).copyWith(reconnectAttempt: 10, maxRetries: 10),
      's-x': SessionState.disconnected(
        connectionId: 'c-web',
        connectionLabel: en.xProgramTabLabel('xterm', 'web-01'),
        host: '10.0.0.21',
        port: 22,
        dropped: true,
        dropCause: sessionEndedCause(exitCode: 0),
      ),
    });
    await front(tester, h, 's-desk');
    await snap(tester, h.key, 'computer-screen-tab-dropped');
    await front(tester, h, 's-x');
    await snap(tester, h.key, 'computer-xprogram-tab-ended');
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets('computer: an X program tab, "xterm on web-01"', (tester) async {
    if (!shotsEnabled) return;
    _scene = _Scene.xterm;
    final h = await pumpShell(tester);
    // As the question sizes it: from the Hosts page it is asked on.
    final size = xProgramSizeFor(_computerSize, page: tester.getSize(find.byType(HostsHomePage)));
    final (shell, engine) = await connectScreen(tester, h, 'c-web', width: size.width, height: size.height);
    h.sessions.screens.add('s-x');
    h.sessions.xPrograms.add('s-x');
    h.sessions.set({
      's-web': _terminalSession('s-web', 'c-web', 'web-01'),
      's-x': screenState('s-x', 'c-web', en.xProgramTabLabel('xterm', 'web-01'), shell, host: '10.0.0.21', port: 22),
    });
    await front(tester, h, 's-x');
    engine.frames.add(ScreenFrame(
        seq: 1, width: size.width, height: size.height, updates: 1, tiles: [_wholeTile(size.width, size.height)]));
    engine.emit(ScreenEventKind.frame, a: 1);
    await settleFrames(tester);
    await settle(tester);
    expect(find.text(en.xProgramTabLabel('xterm', 'web-01')), findsWidgets);
    await snap(tester, h.key, 'computer-xprogram-tab-connected');
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets('computer: the host editor of a VNC host, and Test the screen', (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester);
    h.container.read(connectionEditorWidthProvider.notifier).state = 760;
    h.container.read(connectionEditorTargetProvider.notifier).state = const ConnectionEditorTarget(connectionId: 'c-desk');
    await settle(tester);
    expect(find.byKey(const ValueKey('host-edit-screen-reach'), skipOffstage: false), findsOneWidget);
    await snap(tester, h.key, 'computer-host-editor-vnc');
    final options = find.byKey(const ValueKey('host-edit-screen-view-only'), skipOffstage: false);
    await tester.ensureVisible(options);
    await settle(tester);
    await snap(tester, h.key, 'computer-host-editor-vnc-options');

    Future<void> test() async {
      await tester.tap(find.byKey(const ValueKey('host-edit-screen-test')));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      await settle(tester);
    }

    h.sessions.greeting = [..._banner('003.008'), 2, 2, 19];
    await test();
    expect(find.text(en.connectionSuccessful), findsOneWidget);
    await snap(tester, h.key, 'computer-screen-test-success');

    h.sessions.greeting = ascii.encode('HTTP/1.1 400 Bad Request\r\nServer: nginx\r\n\r\n');
    await test();
    expect(find.text(en.connectionFailed), findsOneWidget);
    await snap(tester, h.key, 'computer-screen-test-not-vnc');
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets('computer: the host editor of an RDP host', (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester);
    await _addRdpHost(h.container.read(databaseProvider));
    h.container.read(connectionEditorWidthProvider.notifier).state = 760;
    h.container.read(connectionEditorTargetProvider.notifier).state = const ConnectionEditorTarget(connectionId: 'c-pc');
    await settle(tester);
    expect(find.byKey(const ValueKey('host-edit-rdp-without-nla'), skipOffstage: false), findsOneWidget);
    await snap(tester, h.key, 'computer-host-editor-rdp');
    await tester.ensureVisible(find.byKey(const ValueKey('host-edit-screen-view-only'), skipOffstage: false));
    await settle(tester);
    await snap(tester, h.key, 'computer-host-editor-rdp-options');
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets('computer: Settings, Remote screens', (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester, prefsExtra: const {'settings_last_section': 'screens'});
    h.container.read(settingsPopupOpenProvider.notifier).state = true;
    await settle(tester);
    expect(find.text(en.settingsScreenMenuKey), findsWidgets);
    await snap(tester, h.key, 'computer-settings-remote-screens');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets('computer: Open an X program, with recent programs; a host without Xvnc (ZS-1809)', (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester);
    final recent = XProgramRecent(LocalStateStore(h.db));
    late Connection web;
    await tester.runAsync(() async {
      for (final p in ['xclock', 'virt-manager', 'gedit /etc/nginx/nginx.conf', 'xterm']) {
        await recent.used('c-web', p);
      }
      web = (await h.db.connectionsDao.getById('c-web'))!;
    });
    final context = tester.element(find.byType(DesktopShell));
    unawaited(showXProgramDialog(context, host: web));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('x-program-field')), 'xterm -fa Monospace -fs 12');
    await settle(tester);
    expect(find.text(en.xProgramRecentLabel), findsOneWidget);
    await snap(tester, h.key, 'computer-xprogram-dialog-recent');
    await tester.tap(find.text(en.cancel).last);
    await settle(tester);

    h.container.read(connectionErrorProvider.notifier).state = ConnectionError(
      host: '10.0.0.21',
      port: 22,
      errorMessage: connectionFailureText(ScreenFailure(ScreenFailureKind.xProgramToolsMissing,
          'the host script said ZSX missing Xvnc', carrier: 'web-01', hint: xProgramInstallCommand('apt-get'))),
      connectionLabel: en.xProgramTabLabel('xterm', 'web-01'),
      connectionId: 'c-web',
    );
    await settle(tester);
    expect(find.textContaining('ZS-1809'), findsWidgets);
    await snap(tester, h.key, 'computer-xprogram-error-zs1809');
    await tearDownShell(tester);
  }, variant: _computer);

  testWidgets("computer: a VeNCrypt screen's certificate, the first time", (tester) async {
    if (!shotsEnabled) return;
    final h = await pumpShell(tester);
    final context = tester.element(find.byType(DesktopShell));
    HostKeyVerification question({String? via, required String host}) => HostKeyVerification(
          certificate: true,
          screen: true,
          via: via,
          name: via == null ? null : 'desk-01',
          host: host,
          port: 5900,
          hostKey: SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: Uint8List(8)),
          fingerprint:
              KnownHostsService.certificateFingerprint('5c1e93a07b2f4d68e0a91c3b7f2264d8a5e0b913c47f6a2d8e05b1c9f3a7d260'),
          isChanged: false,
          completer: Completer<bool>(),
        );
    unawaited(askHostKeyTrust(context, question(host: '10.0.0.40')));
    await settle(tester);
    await snap(tester, h.key, 'computer-screen-certificate-first-use');
    await tester.tap(find.byKey(const ValueKey('host-key-new-reject')));
    await settle(tester);
    unawaited(askHostKeyTrust(context, question(host: 'localhost', via: 'web-01')));
    await settle(tester);
    await snap(tester, h.key, 'computer-screen-certificate-first-use-via');
    await tester.tap(find.byKey(const ValueKey('host-key-new-reject')));
    await settle(tester);
    await tearDownShell(tester);
  }, variant: _computer);

  // -------------------------------------------------------------------------
  // A phone (phone_screen_view_test's, connection_edit_vnc_test's and
  // remote_screens_settings_test's pumps).

  testWidgets('phone: the screen with its bar; the key bar; the menu', (tester) async {
    if (!shotsEnabled) return;
    // The menu's shadow drawn as a shadow, not as a black shape.
    realShadows();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final native = FakeScreenNative();
    final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
    final engine = native.sessions.single;
    engine.connect(name: 'desk-01:0', width: 1600, height: 1000);
    await tester.pump();
    addTearDown(session.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = _phoneSize;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: graphite.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: PhoneScreenView(
            sessionId: 's-desk',
            connectionId: 'c-desk',
            label: 'desk-01',
            session: session,
            options: ScreenOptions.defaults,
            onBack: () {},
            onDisconnect: () {},
            decodeTile: _paintScene,
            clipboardIo: FakeClipboardIo(),
          ),
        ),
      ),
    ));
    await tester.pump();
    engine.frames.add(ScreenFrame(seq: 1, width: 1600, height: 1000, updates: 1, tiles: [_wholeTile(1600, 1000)]));
    engine.emit(ScreenEventKind.frame, a: 1);
    await settleFrames(tester);
    expect(find.byKey(const ValueKey('screen-phone-toolbar')), findsOneWidget);
    await snap(tester, key, 'phone-screen-view-bar', pixelRatio: 2);

    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('screen-key-bar')), findsOneWidget);
    await snap(tester, key, 'phone-screen-view-keybar', pixelRatio: 2);
    await tester.tap(find.byKey(const ValueKey('screen-phone-keyboard')));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byKey(const ValueKey('screen-phone-more')));
    await tester.pumpAndSettle();
    await snap(tester, key, 'phone-screen-view-menu', pixelRatio: 2);
    await tester.tapAt(const Offset(20, 880));
    await tester.pumpAndSettle();
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('phone: the host editor of a VNC host', (tester) async {
    if (!shotsEnabled) return;
    debugHostFormOnComputer = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    final db = await _seeded();
    addTearDown(db.close);
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: graphite.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: ConnectionEditScreen(connectionId: 'c-desk')),
        ),
      ),
    ));
    await settle(tester);
    expect(find.byKey(const ValueKey('host-edit-screen-reach'), skipOffstage: false), findsOneWidget);
    await snap(tester, key, 'phone-host-editor-vnc', pixelRatio: 2);
    await tester.ensureVisible(find.byKey(const ValueKey('host-edit-screen-view-only'), skipOffstage: false));
    await settle(tester);
    await snap(tester, key, 'phone-host-editor-vnc-options', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });

  testWidgets('phone: the host editor of an RDP host', (tester) async {
    if (!shotsEnabled) return;
    debugHostFormOnComputer = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    final db = await _seeded();
    addTearDown(db.close);
    await _addRdpHost(db);
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(c.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: graphite.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: const Scaffold(body: ConnectionEditScreen(connectionId: 'c-pc')),
        ),
      ),
    ));
    await settle(tester);
    expect(find.byKey(const ValueKey('host-edit-screen-reach'), skipOffstage: false), findsOneWidget);
    await snap(tester, key, 'phone-host-editor-rdp', pixelRatio: 2);
    await tester.ensureVisible(find.byKey(const ValueKey('host-edit-screen-view-only'), skipOffstage: false));
    await settle(tester);
    await snap(tester, key, 'phone-host-editor-rdp-options', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });

  testWidgets("phone: Settings' Remote screens page", (tester) async {
    if (!shotsEnabled) return;
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => const RemoteScreensSettingsScreen())]);
    addTearDown(router.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          recordingModeProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: graphite.toThemeData(),
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(en.settingsScreenTouchDefault), findsOneWidget);
    await snap(tester, key, 'phone-settings-remote-screens', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
