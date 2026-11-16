import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/inspector_panel.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// What a session's details say protects it (3.0, from the SSH core's
/// audit): the cipher, and a MAC only where the cipher has one beside it.
///
/// The details of a session name its key exchange, its cipher, its MAC and
/// its kind of host key, as the SSH core says them. chacha20-poly1305, which
/// the app prefers and most hosts have, checks its packets by itself: there
/// is no MAC. The core named the MAC that the two sides' lists had in common
/// all the same, so the details of nearly every session had a row "MAC" with
/// an algorithm that protected nothing of it.
///
/// With the app's own service signed in to a host played by the test, and
/// the Inspector's Session tab shown for it.
class _Health extends ConnectionHealthNotifier {}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);

  /// The app's own service in a shell on a played host that speaks [suite].
  Future<SshService> inAShell(PlayedSuite suite) async {
    final server = PlayedServer(suite: suite);
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
    );
    final connecting = ssh.connect().timeout(patience);
    unawaited(connecting.then((_) {}, onError: (_) {}));
    await server.letIn();
    final channel = await server.confirmChannel();
    expect((await channel.nextRequest()).requestType, 'pty-req');
    server.send([channel.success]);
    expect((await channel.nextRequest()).requestType, 'shell');
    server.send([channel.success, channel.data('deploy@web-01:~\$ ')]);
    await connecting;
    return ssh;
  }

  /// The Session tab of the Inspector for a session whose shell is [ssh].
  Future<void> shown(WidgetTester tester, SshService ssh) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      snippetsProvider.overrideWith((ref) => Stream.value(const <Snippet>[])),
      dangerousCommandProtectionProvider.overrideWith((ref) => true),
    ]);
    addTearDown(container.dispose);
    container.read(inspectorTabProvider.notifier).state = InspectorTab.session;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(children: [
            const Spacer(),
            InspectorPanel(
              sessionId: 's1',
              sessionState: SessionState(
                status: SessionStatus.connected,
                connectionId: 'c1',
                connectionLabel: 'web-01',
                host: 'web-01.example.com',
                port: 22,
                username: 'deploy',
                session: TerminalSession(
                  id: 's1',
                  connectionId: 'c1',
                  terminal: Terminal(),
                  shell: ssh,
                  startedAt: DateTime(2026, 10, 10),
                ),
              ),
              onClose: () {},
            ),
          ]),
        ),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a session under the cipher the app prefers: the details name the cipher, and no MAC', (tester) async {
    final ssh = (await tester.runAsync(() => inAShell(PlayedSuite.chacha)))!;
    addTearDown(() => tester.runAsync(ssh.disconnect));

    await shown(tester, ssh);
    expect(find.text(en.sessionDetailsCipher), findsOneWidget);
    expect(find.text('chacha20-poly1305@openssh.com'), findsOneWidget);
    expect(find.text(en.sessionDetailsMac), findsNothing, reason: 'a row for a MAC, where the cipher has none');
    expect(find.textContaining('hmac'), findsNothing);
    // The rows around it are there as they were.
    expect(find.text(en.sessionDetailsKeyExchange), findsOneWidget);
    expect(find.text(en.sessionDetailsHostKey), findsOneWidget);
    // And what the service says of it, which the row is made from.
    expect(ssh.negotiatedCipher, 'chacha20-poly1305@openssh.com');
    expect(ssh.negotiatedMac, '');
  });

  testWidgets('a session under a cipher with a MAC beside it: the details name both', (tester) async {
    final ssh = (await tester.runAsync(() => inAShell(PlayedSuite.ctrEtm)))!;
    addTearDown(() => tester.runAsync(ssh.disconnect));
    expect(ssh.negotiatedCipher, 'aes256-ctr');
    expect(ssh.negotiatedMac, 'hmac-sha2-256-etm@openssh.com');

    await shown(tester, ssh);
    expect(find.text(en.sessionDetailsCipher), findsOneWidget);
    expect(find.text('aes256-ctr'), findsOneWidget);
    expect(find.text(en.sessionDetailsMac), findsOneWidget);
    expect(find.text('hmac-sha2-256-etm@openssh.com'), findsOneWidget);
  });
}
