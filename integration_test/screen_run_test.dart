// The five-platform run of a remote screen (4.0), on a
// device: the app's own session path (ScreenShellService over an SshService
// signed in with no terminal, the Rust engine built for the device) and its
// own picture (ScreenController, ScreenView), against the WSL test servers
// (tool/remote_screens_test_servers.sh) through the test sshd to the VNC
// socket. It measures, and prints one line `ZSMEASURE {json}` and the
// picture as `ZSPNG <n> <base64>` lines for the runner to keep.
//
//   flutter test integration_test/screen_run_test.dart -d <device> \
//     --dart-define-from-file=<settings.json>
//
// The settings file (ZS_HOST, ZS_SSH_PORT, ZS_USER, ZS_PASSWORD,
// ZS_VNC_PASSWORD, ZS_SOCKET, ZS_RUN) holds the test account's passwords:
// made by the runner from the server's root-only file, never printed, and
// deleted after the run. With no ZS_HOST the test does nothing.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zest_native/screen.dart';

const _host = String.fromEnvironment('ZS_HOST');
const _sshPort = int.fromEnvironment('ZS_SSH_PORT', defaultValue: 2240);
const _user = String.fromEnvironment('ZS_USER', defaultValue: 'alex');
const _password = String.fromEnvironment('ZS_PASSWORD');
const _vncPassword = String.fromEnvironment('ZS_VNC_PASSWORD');
const _socket = String.fromEnvironment('ZS_SOCKET', defaultValue: '/run/zestscreens/vnc.sock');
const _run = String.fromEnvironment('ZS_RUN', defaultValue: 'run');

/// Refuses every certificate: a screen through SSH on the VNC socket has none.
class _NoCertificates implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;
  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => false;
  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('a remote screen through SSH, drawn by the app\'s view: connect, picture, input, pause, resume',
      (tester) async {
    if (_host.isEmpty) {
      debugPrint('ZS_HOST is not set: nothing to run');
      return;
    }
    SharedPreferences.setMockInitialValues({});
    final log = <String>[];
    final m = <String, Object?>{
      'run': _run,
      'when': DateTime.now().toUtc().toIso8601String(),
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'build': 'debug',
      'target': 'unix socket through ssh',
    };
    final clock = Stopwatch()..start();
    final carrier = SshService(
      host: _host,
      port: _sshPort,
      username: _user,
      password: _password,
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
    );
    final shell = ScreenShellService(
      target: const UnixSocketTarget(_socket),
      trust: _NoCertificates(),
      carrier: carrier,
      carrierLabel: 'wsl-test',
      password: _vncPassword,
      onLog: log.add,
    );
    await shell.connect();
    m['connect_ms'] = clock.elapsedMilliseconds;
    final s = shell.session!;
    final info = shell.connectedInfo!;
    m['security'] = info.security;
    m['screen'] = '${info.width}x${info.height}';

    final controller = ScreenController(s);
    final shot = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: RepaintBoundary(key: shot, child: ScreenView(controller: controller)),
      ),
    ));
    Future<void> until(bool Function() ok, String what, {Duration within = const Duration(seconds: 15)}) async {
      final sw = Stopwatch()..start();
      while (!ok()) {
        if (sw.elapsed > within) fail('waited $within for $what');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    await until(() => controller.framesShown > 0, 'the first picture');
    m['first_picture_ms'] = clock.elapsedMilliseconds;
    final view = tester.getRect(find.byType(ScreenView));
    m['view'] = '${view.width.round()}x${view.height.round()}';
    m['device_pixel_ratio'] = tester.view.devicePixelRatio;

    // The mouse moves over the picture (xeyes follows it): the view sends the pointer, the server
    // draws, the picture comes back.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: view.center);
    Future<void> wiggle(Duration d) async {
      final sw = Stopwatch()..start();
      var i = 0;
      while (sw.elapsed < d) {
        await mouse.moveTo(Offset(view.left + view.width * (0.1 + 0.8 * ((i * 37) % 100) / 100),
            view.top + view.height * (0.1 + 0.8 * ((i * 53) % 100) / 100)));
        i++;
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }

    const live = Duration(seconds: 5);
    var frames = controller.framesShown, inBytes = s.bytesIn, outBytes = s.bytesOut;
    await wiggle(live);
    m['live_s'] = live.inSeconds;
    m['live_frames_shown'] = controller.framesShown - frames;
    m['live_fps'] = double.parse(((controller.framesShown - frames) / live.inSeconds).toStringAsFixed(1));
    m['live_bytes_in'] = s.bytesIn - inBytes;
    m['live_kbps_in'] = ((s.bytesIn - inBytes) * 8 / 1000 / live.inSeconds).round();
    m['live_bytes_out'] = s.bytesOut - outBytes;
    expect(m['live_bytes_in'] as int, greaterThan(0));

    // The picture as shown, before the pause.
    final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    // Taken between frames: the last update painted, none waiting.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (var i = 0; i < 100 && boundary.debugNeedsPaint; i++) {
      await WidgetsBinding.instance.endOfFrame;
    }
    // (A Mac with no display draws nothing: its window has no size, and there is no picture to take.)
    try {
      final image = await boundary.toImage(pixelRatio: 1);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      image.dispose();
      final b64 = base64Encode(png);
      const chunk = 800;
      for (var i = 0, n = 0; i < b64.length; i += chunk, n++) {
        // ignore: avoid_print
        print('ZSPNG $n ${b64.substring(i, i + chunk > b64.length ? b64.length : i + chunk)}');
      }
    } on Exception catch (e) {
      m['picture_error'] = '$e';
    }

    // Paused (the tab hidden): what was on its way arrives, then nothing while the mouse moves.
    controller.pause();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    inBytes = s.bytesIn;
    outBytes = s.bytesOut;
    frames = controller.framesShown;
    await wiggle(const Duration(seconds: 3));
    m['paused_s'] = 3;
    m['paused_bytes_in'] = s.bytesIn - inBytes;
    m['paused_bytes_out'] = s.bytesOut - outBytes;
    m['paused_frames_shown'] = controller.framesShown - frames;
    expect(m['paused_bytes_in'], 0);

    final resumed = Stopwatch()..start();
    controller.resume();
    await until(() => controller.framesShown > frames, 'the picture after resume', within: const Duration(seconds: 5));
    m['resume_to_picture_ms'] = resumed.elapsedMilliseconds;
    await mouse.removePointer();

    final closing = Stopwatch()..start();
    await shell.disconnect();
    m['close_ms'] = closing.elapsedMilliseconds;
    m['carrier_closed'] = !carrier.isConnected;
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    for (final line in log) {
      expect(line.contains(_vncPassword) || line.contains(_password), isFalse, reason: 'a password in the log');
    }
    m['log_lines'] = log.length;
    // ignore: avoid_print
    print('ZSMEASURE ${jsonEncode(m)}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
