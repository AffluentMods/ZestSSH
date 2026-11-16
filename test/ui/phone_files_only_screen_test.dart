import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_native/ftps.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

import 'sharing_ui_fakes.dart';

/// A session that is files only (an SFTP-only host) on a phone:
/// its screen has no terminal and no row of keys, says it
/// is files only, with Open its files, and its toolbar says SFTP where a
/// terminal's says what its shell calls it. An FTPS host's (3.4) says FTPS,
/// and its files open only where its vault's SFTP switch is on, as a
/// computer's file manager asks.
class _Sessions extends FakeSessions {
  _Sessions(super.ref);

  final files = <String>{};

  /// What the host's vault allows (every switch where null).
  Set<String>? allows;

  @override
  bool isFilesOnly(String sessionId) => files.contains(sessionId);

  @override
  Future<bool> hostAllows(String? connectionId, String what) async => allows?.contains(what) ?? true;
}

class _Trust implements FtpsTrust {
  @override
  Future<String?> pinnedFor(String host, int port) async => null;

  @override
  Future<bool> ask(FtpsCertificate presented, {required String host, required int port, String? previous}) async =>
      false;

  @override
  Future<void> remember(String host, int port, FtpsCertificate cert) async {}
}

/// A connected FTPS host's session (its shell never connected here).
SessionState _ftpsSession(String id, String label) {
  final s = connectedSession(id, label);
  return SessionState(
    status: s.status,
    connectionId: s.connectionId,
    connectionLabel: label,
    host: s.host,
    port: 21,
    username: s.username,
    session: TerminalSession(
      id: id,
      connectionId: s.connectionId!,
      terminal: Terminal(),
      shell: FtpsShellService(
        options: const FtpsConnectOptions(host: 'files.example.test', port: 21, username: 'demo', password: 'pw'),
        trust: _Trust(),
      ),
      startedAt: DateTime(2026, 11, 6, 9),
    ),
  );
}

class _Health extends ConnectionHealthNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  Future<_Sessions> pump(WidgetTester tester, {required bool filesOnly, bool ftps = false, Set<String>? allows}) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugPhoneKeysRow = true;
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    if (filesOnly) sessions.files.add('s1');
    sessions.allows = allows;
    sessions.show({'s1': ftps ? _ftpsSession('s1', 'files-01') : connectedSession('s1', 'files-01')});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: TerminalScreen(sessionId: 's1'),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return sessions;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
    debugDefaultTargetPlatformOverride = null;
    debugPhoneKeysRow = null;
  }

  testWidgets('files only: no terminal, no row of keys, what it is said, and its files to open', (tester) async {
    await pump(tester, filesOnly: true);
    expect(find.byType(TerminalView), findsNothing, reason: 'no keyboard is brought up for nothing');
    expect(find.byType(TerminalSoftKeyboard), findsNothing);
    expect(find.byKey(const ValueKey('terminal-files-only')), findsOneWidget);
    expect(find.text(en.sessionFilesOnlyLine), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-files-only-open')), findsOneWidget);
    expect(find.text(en.pillSftp), findsWidgets, reason: 'its toolbar says SFTP');
    await finish(tester);
  });

  testWidgets("an FTPS host's session says FTPS, never SFTP", (tester) async {
    await pump(tester, filesOnly: true, ftps: true);
    expect(find.byType(TerminalView), findsNothing);
    expect(find.text(en.sessionFilesOnlyLineFtps), findsOneWidget);
    expect(find.text(en.sessionFilesOnlyLine), findsNothing);
    expect(find.text('FTPS'), findsWidgets, reason: 'its toolbar says FTPS');
    expect(find.text(en.pillSftp), findsNothing);
    await finish(tester);
  });

  testWidgets("an FTPS host's files are not opened where its vault's SFTP switch is off, and it says why",
      (tester) async {
    debugTopSnackBarOnPhone = true;
    addTearDown(() => debugTopSnackBarOnPhone = null);
    await pump(tester, filesOnly: true, ftps: true, allows: const {'connect', 'forward'});
    await tester.tap(find.byKey(const ValueKey('terminal-files-only-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(en.orchardFtpsNotAllowed), findsOneWidget);
    await finish(tester);
  });

  testWidgets("a terminal's session is shown as before", (tester) async {
    await pump(tester, filesOnly: false);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(TerminalSoftKeyboard), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-files-only')), findsNothing);
    await finish(tester);
  });
}
