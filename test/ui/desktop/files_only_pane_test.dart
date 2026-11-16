import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart';
import 'package:zestssh/ui/screens/desktop/widgets/sftp_dock.dart';

/// A session that is files only (an SFTP-only host) on a computer:
/// its tab is its files, full width, with no
/// terminal pane and no SFTP dock; its header says SFTP and offers neither
/// tmux nor SFTP; a terminal's session beside it is as it was.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final files = <String>{};

  void set(Map<String, SessionState> s) => state = s;

  @override
  bool isFilesOnly(String sessionId) => files.contains(sessionId);

  @override
  Set<String> get filesOnlySessionIds => files;
}

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

class _Health extends ConnectionHealthNotifier {}

SessionState _state(String id, String label) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: '192.0.2.20',
      port: 22,
      username: 'backup',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(),
        shell: _Shell(),
        startedAt: DateTime(2026, 10, 30),
      ),
    );

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester, {required bool filesOnly}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(c.dispose);
    final tabs = c.read(workTabsProvider.notifier);
    final sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
    if (filesOnly) sessions.files.add('s1');
    sessions.set({'s1': _state('s1', 'files-01')});
    tabs.setActiveTab(tabs.tabContaining('s1')!.id);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: DesktopTerminalArea(onConnectTo: (_) {}, onToggleSftp: (_) {}, onApplyLayout: (_) {}),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return c;
  }

  Finder byType(String name) => find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

  testWidgets('files only: the tab is its files, full width, with no terminal and no dock', (tester) async {
    await pump(tester, filesOnly: true);
    expect(byType('_SftpLeafPane'), findsOneWidget);
    expect(find.byType(SftpDockFrame), findsNothing, reason: 'not a dock beside a terminal');
    expect(find.byType(TerminalView), findsNothing);
    // (The stand-in's connection is none SFTP can open on: said in the pane.)
    expect(find.text(en.desktopSftpRequiresActive), findsOneWidget);
    // Its pane takes the whole width of the area.
    final area = tester.getSize(find.byType(DesktopTerminalArea));
    expect(tester.getSize(byType('_SftpLeafPane')).width, area.width);
    // The header says SFTP, and has no tmux and no SFTP button.
    expect(find.byKey(const ValueKey('session-files-only-s1')), findsOneWidget);
    expect(find.byType(FilesOnlyTag), findsOneWidget);
    expect(find.byTooltip(en.sessionHeaderSftpTooltip), findsNothing);
    expect(find.byType(SessionTmuxButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets("a terminal's session is shown as before", (tester) async {
    await pump(tester, filesOnly: false);
    expect(byType('_SftpLeafPane'), findsNothing);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(FilesOnlyTag), findsNothing);
    expect(find.byTooltip(en.sessionHeaderSftpTooltip), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
