import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_tester.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardSummariesProvider;
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline;
import 'package:zestssh/features/orchards/spaces.dart' show OrchardSpace;
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart' show EffectiveTestConfig;
import 'package:zestssh/features/hosts/widgets/host_card.dart' show HostCard;
import 'package:zestssh/features/hosts/widgets/host_test_views.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_panel.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

/// The host panel's Test reachability and Test full connection,
/// through the one [HostTester] the editor's run through; and a
/// workspace's panel on the same page (a click on its card connected everything
/// at once).
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final started = <String>[];

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      dynamic space}) {
    started.add(connection.id);
    return null;
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String protocol = 'ssh',
    int port = 22,
    bool withWorkspace = false,
    String? keyAuth,
    List<Override> extra = const [],
  }) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    tester.view.physicalSize = const Size(1500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 9, 24);
    await tester.runAsync(() async {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'c0',
            label: 'web-01',
            host: '127.0.0.1',
            port: Value(port),
            protocol: Value(protocol),
            identityId: Value(keyAuth == null ? null : 'k1'),
            createdAt: now,
            updatedAt: now,
          ));
      if (keyAuth != null) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: 'k1',
              label: 'deploy',
              username: 'deploy',
              authMethod: keyAuth,
              createdAt: now,
              updatedAt: Value(now),
            ));
      }
      if (withWorkspace) {
        final group = SavedTabGroup(
          id: 'w1',
          name: 'Ops',
          tabs: [TabSnapshot(paneTreeOfConnIds: PaneLeaf(id: 'l1', sessionIds: const ['c0']))],
          hostNames: const {'c0': 'web-01'},
        );
        await LocalStateStore(db).write('desktop_saved_tab_groups', jsonEncode([group.toJson()]));
      }
    });
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionTimeoutProvider.overrideWith((ref) => 10),
      ...extra,
    ]);
    addTearDown(c.dispose);
    if (withWorkspace) c.read(savedTabGroupsProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: HostsHomePage(onConnectTo: (ConnectionWithDetails i) {}, onOpenTmux: (ConnectionWithDetails i) {}),
        ),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return c;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Future<void> openHostPanel(WidgetTester tester) async {
    await tester.tap(find.text('web-01').first);
    await settle(tester);
    expect(find.byKey(const ValueKey('host-panel-c0')), findsOneWidget);
  }

  group("the panel's two tests", () {
    testWidgets('a host that answers: reachable, said under the buttons, and it can be dismissed', (tester) async {
      final server = await tester.runAsync(() => ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
      addTearDown(() => server!.close());
      server!.listen((s) => s.destroy());
      await pump(tester, port: server.port);
      await openHostPanel(tester);
      final reach = find.byKey(const ValueKey('host-panel-test-reachability'));
      expect(reach, findsOneWidget);
      expect(find.byKey(const ValueKey('host-panel-test-full')), findsOneWidget);
      expect(find.text(en.zestHostTestReachability), findsOneWidget);
      await tester.ensureVisible(reach);
      await tester.pump();
      await tester.tap(reach);
      await settle(tester);
      expect(find.byKey(const ValueKey('host-panel-test-result')), findsOneWidget);
      expect(find.text(en.connectionSuccessful), findsOneWidget);
      expect(find.textContaining('ms'), findsWidgets, reason: 'how long it took');
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('host-panel-test-result')),
        matching: find.byType(IconButton),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('host-panel-test-result')), findsNothing);
      await finish(tester);
    });

    testWidgets('a host that does not answer: says so, with Copy details', (tester) async {
      // A port that was free a moment ago: nothing listens on it.
      final closed = await tester.runAsync(() async {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = s.port;
        await s.close();
        return port;
      });
      await pump(tester, port: closed!);
      await openHostPanel(tester);
      final reach = find.byKey(const ValueKey('host-panel-test-reachability'));
      await tester.ensureVisible(reach);
      await tester.pump();
      await tester.tap(reach);
      // (A port nobody listens on takes Windows a few seconds to refuse.)
      for (var i = 0; i < 100 && find.byKey(const ValueKey('host-panel-test-result')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(en.connectionFailed), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('host-panel-test-result')), matching: find.byType(CopyDetailsButton)),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('a host that closes at once ends the full test, in the words of a failed connection', (tester) async {
      final server = await tester.runAsync(() => ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
      addTearDown(() => server!.close());
      server!.listen((s) => s.destroy());
      await pump(tester, port: server.port);
      await openHostPanel(tester);
      final full = find.byKey(const ValueKey('host-panel-test-full'));
      await tester.ensureVisible(full);
      await tester.pump();
      await tester.tap(full);
      await settle(tester);
      await settle(tester);
      expect(find.text(en.connectionFailed), findsOneWidget);
      await finish(tester);
    });

    // The real thing: the WSL test sshd (tool/test_sshd.sh), whose key this
    // device has never seen. Nothing is signed in with before it is trusted.
    final sshPort = int.tryParse(Platform.environment['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
    Future<bool> sshdUp(WidgetTester tester) async =>
        await tester.runAsync(() async {
          try {
            (await Socket.connect('127.0.0.1', sshPort, timeout: const Duration(seconds: 2))).destroy();
            return true;
          } on SocketException {
            return false;
          }
        }) ??
        false;

    Future<void> untilSaid(WidgetTester tester, Finder what) async {
      for (var i = 0; i < 120 && what.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(what, findsWidgets);
    }

    testWidgets('the full test on a real host whose key it does not know: the question comes first, and No sends nothing',
        (tester) async {
      if (!await sshdUp(tester)) {
        markTestSkipped('the test sshd is not running on $sshPort');
        return;
      }
      await pump(tester, port: sshPort);
      await openHostPanel(tester);
      final full = find.byKey(const ValueKey('host-panel-test-full'));
      await tester.ensureVisible(full);
      await tester.pump();
      await tester.tap(full);
      await untilSaid(tester, find.text(en.connectionEditUnknownHostKey));
      expect(find.byKey(const ValueKey('host-panel-test-result')), findsNothing, reason: 'it waits for the answer');
      await tester.tap(find.text(en.cancel).last);
      await untilSaid(tester, find.byKey(const ValueKey('host-panel-test-result')));
      expect(find.text(en.connectionEditHostKeyUntrusted), findsOneWidget, reason: 'no sign-in was tried: none could fail');
      await finish(tester);
    });

    testWidgets('and Yes signs in as it would, and says what the host answered', (tester) async {
      if (!await sshdUp(tester)) {
        markTestSkipped('the test sshd is not running on $sshPort');
        return;
      }
      await pump(tester, port: sshPort);
      await openHostPanel(tester);
      final full = find.byKey(const ValueKey('host-panel-test-full'));
      await tester.ensureVisible(full);
      await tester.pump();
      await tester.tap(full);
      await untilSaid(tester, find.text(en.connectionEditUnknownHostKey));
      await tester.tap(find.text(en.connectionEditTrustAndTest));
      await untilSaid(tester, find.byKey(const ValueKey('host-panel-test-result')));
      // No key saved on this host: the sign-in is refused, and that is the verdict.
      expect(find.text(en.connectionFailed), findsOneWidget);
      expect(find.text(en.connectionEditHostKeyUntrusted), findsNothing);
      await finish(tester);
    });

    for (final (protocol, shown) in [
      ('ssh', true),
      ('sftp', true),
      ('mosh', true),
      ('et', true),
      ('serial', true),
      ('telnet', false),
      ('localShell', false),
    ]) {
      testWidgets('on a $protocol host: ${shown ? 'there' : 'not there'}', (tester) async {
        await pump(tester, protocol: protocol);
        await openHostPanel(tester);
        expect(find.byKey(const ValueKey('host-panel-test-reachability')), shown ? findsOneWidget : findsNothing);
        expect(find.byKey(const ValueKey('host-panel-sftp')), protocol == 'localShell' ? findsNothing : findsOneWidget,
            reason: 'a local shell has no SFTP');
        await finish(tester);
      });
    }

    test('hostProtocolCanBeTested goes by the stored name, whatever its case', () {
      expect(hostProtocolCanBeTested('SSH'), isTrue);
      expect(hostProtocolCanBeTested('localShell'), isFalse);
    });
  });

  group('HostTester', () {
    testWidgets('refused before it begins: said, and nothing is started', (tester) async {
      late BuildContext at;
      late WidgetRef widgetRef;
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Consumer(builder: (context, ref, _) {
            at = context;
            widgetRef = ref;
            return const SizedBox();
          }),
        ),
      ));
      var began = 0;
      final tester_ = HostTester(context: at, ref: widgetRef, addressChosenHere: (_) async => true);
      final empty = await tester_.reachability(const EffectiveTestConfig(host: ' ', port: 22), onStarted: () => began++);
      expect(empty!.success, isFalse);
      expect(empty.message, en.connectionHostRequired);
      final badPort = await tester_.fullConnection(const EffectiveTestConfig(host: 'web-01', port: 0), onStarted: () => began++);
      expect(badPort!.message, en.connectionPortInvalid);
      expect(began, 0);
    });

    // Every gate before a sign-in, at a host that counts who rings: none is rung.
    group('the full test is refused before anything is dialled', () {
      late ServerSocket door;
      late int rang;
      late BuildContext at;
      late WidgetRef widgetRef;
      var began = 0;

      Future<void> gates(WidgetTester tester, {String? keyAuth, List<Override> extra = const []}) async {
        began = 0;
        rang = 0;
        final bound = await tester.runAsync(() => ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
        door = bound!;
        addTearDown(() => door.close());
        door.listen((s) {
          rang++;
          s.destroy();
        });
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final now = DateTime(2026, 9, 24);
        if (keyAuth != null) {
          await tester.runAsync(() => db.into(db.identities).insert(IdentitiesCompanion.insert(
                id: 'k1',
                label: 'deploy',
                username: 'deploy',
                authMethod: keyAuth,
                createdAt: now,
                updatedAt: Value(now),
              )));
        }
        await tester.pumpWidget(ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(prefs),
            databaseProvider.overrideWithValue(db),
            treeDatabaseProvider.overrideWithValue(db),
            ...extra,
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Consumer(builder: (context, ref, _) {
              at = context;
              widgetRef = ref;
              return const SizedBox();
            }),
          ),
        ));
      }

      Future<HostTestResult?> run(
        WidgetTester tester, {
        bool typedHere = true,
        Future<bool> Function(AppDatabase, {String? hostId, String? keyId})? unwatched,
        Future<void> Function(AppDatabase, {String? hostId, String? keyId})? open,
        String? key,
      }) async {
        final result = await tester.runAsync(() => HostTester(
              context: at,
              ref: widgetRef,
              hostId: 'c0',
              addressTypedHere: typedHere,
              addressChosenHere: (_) async => true,
              wouldGoUnwatched: unwatched ?? (db, {hostId, keyId}) async => false,
              requireCratesOpen: open ?? (db, {hostId, keyId}) async {},
            ).fullConnection(
              EffectiveTestConfig(host: '127.0.0.1', port: door.port, identityKeyId: key),
              onStarted: () => began++,
            ));
        // Anything dialled would have rung by now.
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
        return result;
      }

      void refused(HostTestResult? result, String said) {
        expect(result!.success, isFalse);
        expect(result.message, said);
        expect(rang, 0, reason: 'nothing was dialled');
        expect(began, 0, reason: 'it never began');
      }

      testWidgets("a watched Crate's host or key", (tester) async {
        await gates(tester);
        String? askedHost;
        refused(
          await run(tester, unwatched: (db, {hostId, keyId}) async {
            askedHost = hostId;
            return true;
          }),
          en.watchedNoTest,
        );
        expect(askedHost, 'c0');
      });

      testWidgets('a Crate its own offline limit has closed: in the words a connection gets', (tester) async {
        await gates(tester);
        refused(
          await run(tester, open: (db, {hostId, keyId}) async {
            throw const CrateClosedOffline(crateId: 'crate-1', hours: 24, message: 'Closed on this device.');
          }),
          'Closed on this device.',
        );
      });

      // An account of a team, its rules not to be read: the password is kept
      // from it, by the gate itself.
      final teamWithoutRules = <Override>[
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace('team-1')),
        orchardSummariesProvider.overrideWith((ref) async => throw StateError('not read')),
      ];

      testWidgets("a key's password kept from this account: from the editor, of what was typed there", (tester) async {
        await gates(tester, keyAuth: 'password', extra: teamWithoutRules);
        refused(await run(tester, key: 'k1'), en.orchardTestNeedsReveal);
      });

      testWidgets("a key's password kept from this account: from the panel, with no word of anything typed", (tester) async {
        await gates(tester, keyAuth: 'password', extra: teamWithoutRules);
        refused(await run(tester, key: 'k1', typedHere: false), en.hostPanelTestNeedsReveal);
        expect(en.hostPanelTestNeedsReveal, isNot(contains('typed')));
      });

      testWidgets('a key with no password to keep goes on: the gate is only for passwords', (tester) async {
        await gates(tester, keyAuth: 'publicKey', extra: teamWithoutRules);
        final result = await run(tester, key: 'k1');
        expect(result!.success, isFalse, reason: 'the door closes at once');
        expect(began, 1);
        expect(rang, 1);
      });

      testWidgets('with nothing against it, it goes', (tester) async {
        await gates(tester);
        await run(tester);
        expect(began, 1);
        expect(rang, 1);
      });
    });

    testWidgets("the panel's own button says so in the panel's words: nothing was typed there", (tester) async {
      await pump(tester, keyAuth: 'password', extra: [
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace('team-1')),
        orchardSummariesProvider.overrideWith((ref) async => throw StateError('not read')),
      ]);
      await openHostPanel(tester);
      final full = find.byKey(const ValueKey('host-panel-test-full'));
      await tester.ensureVisible(full);
      await tester.pump();
      await tester.tap(full);
      await settle(tester);
      expect(find.text(en.hostPanelTestNeedsReveal), findsOneWidget);
      expect(find.text(en.orchardTestNeedsReveal), findsNothing);
      await finish(tester);
    });

    test('the password saved with a key follows the same rules', () async {
      var reads = 0;
      Future<String?> asked({bool may = true, bool again = false, bool chosen = true, bool them = false}) =>
          testPasswordAfterKey(
            mayReveal: () async => may,
            asksAgain: () async => again,
            addressChosenHere: () async => chosen,
            itIsThem: () async => them,
            read: () async {
              reads++;
              return 'made-up';
            },
          );
      expect(await asked(may: false), isNull);
      expect(await asked(again: true), isNull, reason: 'declined');
      expect(reads, 0, reason: 'not read where it may not go');
      expect(await asked(again: true, them: true), 'made-up');
      expect(await asked(again: true, chosen: false), 'made-up', reason: 'to the saved address, nothing is asked');
      expect(await asked(), 'made-up');
    });
  });

  group("a host's right-click menu", () {
    // The menu, and its Tools (4.0: the menu grouped), where tmux is.
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.text('web-01').first, buttons: kSecondaryButton);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('host-menu-tools')));
      await settle(tester);
    }

    for (final (protocol, offered) in [('ssh', true), ('localShell', false), ('sftp', false), ('telnet', false)]) {
      testWidgets('on a $protocol host: tmux ${offered ? 'is' : 'is not'} offered', (tester) async {
        await pump(tester, protocol: protocol);
        await openMenu(tester);
        expect(find.text(en.commonConnect), findsWidgets, reason: 'the menu is open');
        expect(find.text(en.termTbTmux), offered ? findsOneWidget : findsNothing);
        await finish(tester);
      });
    }
  });

  test('a session speaks SSH by its shell: before it has one, nothing says so, whatever its host is', () {
    expect(const SessionState(status: SessionStatus.connecting, connectionId: 'a-saved-local-shell').speaksSsh, isFalse);
    expect(const SessionState(status: SessionStatus.connecting, connectionId: 'local_1').speaksSsh, isFalse);
  });

  // A design review: a click on a workspace's card
  // connected every pane; its edit was a small floating popup.
  group('a workspace card on the Hosts page', () {
    Future<_Sessions> pumpWithWorkspace(WidgetTester tester) async {
      final c = await pump(tester, withWorkspace: true);
      await settle(tester);
      expect(find.byKey(const ValueKey('workspace-card-w1')), findsOneWidget);
      return c.read(activeSessionsProvider.notifier) as _Sessions;
    }

    testWidgets('a click opens its panel and connects nothing', (tester) async {
      final sessions = await pumpWithWorkspace(tester);
      await tester.tap(find.byKey(const ValueKey('workspace-card-w1')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(sessions.started, isEmpty);
      await tester.tap(find.byKey(const ValueKey('workspace-panel-close')));
      await settle(tester);
      expect(find.byType(WorkspacePanel), findsNothing);
      await finish(tester);
    });

    testWidgets('a double click opens the workspace', (tester) async {
      final sessions = await pumpWithWorkspace(tester);
      final card = find.byKey(const ValueKey('workspace-card-w1'));
      await tester.tap(card);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(card);
      await settle(tester);
      expect(sessions.started, ['c0']);
      await finish(tester);
    });

    testWidgets('Open workspace in the panel opens it', (tester) async {
      final sessions = await pumpWithWorkspace(tester);
      await tester.tap(find.byKey(const ValueKey('workspace-card-w1')));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('workspace-panel-open')));
      await settle(tester);
      expect(sessions.started, ['c0']);
      await finish(tester);
    });

    testWidgets('Esc closes the panel', (tester) async {
      await pumpWithWorkspace(tester);
      await tester.tap(find.byKey(const ValueKey('workspace-card-w1')));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.byType(WorkspacePanel), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(WorkspacePanel), findsNothing);
      await finish(tester);
    });

    testWidgets('a right click opens it on its editor; a host picked takes its place', (tester) async {
      await pumpWithWorkspace(tester);
      final card = find.byKey(const ValueKey('workspace-card-w1'));
      await tester.tap(card, buttons: 2);
      await settle(tester);
      expect(find.byType(WorkspacePanel), findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-panel-edit')), findsNothing, reason: 'it is the editor already');
      await tester.tap(find.byType(HostCard).first);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.byType(WorkspacePanel), findsNothing, reason: 'its place is taken');
      expect(find.byKey(const ValueKey('host-panel-c0')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the pencil opens the editor every time, and a click on the same card leaves it as it is', (tester) async {
      await pumpWithWorkspace(tester);
      final card = find.byKey(const ValueKey('workspace-card-w1'));
      final edit = find.byKey(const ValueKey('workspace-panel-edit'));
      await tester.tap(card, buttons: 2);
      await settle(tester);
      expect(edit, findsNothing, reason: 'the editor');

      // A click on the same card: what is being edited stays.
      await tester.tap(card);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(edit, findsNothing, reason: 'still the editor');

      // Its Close goes back to the details; the pencil opens the editor again,
      // which a panel that stayed the same did not.
      await tester.tap(find.text(en.cancel).last);
      await settle(tester);
      expect(edit, findsOneWidget, reason: 'the details');
      await tester.tap(card, buttons: 2);
      await settle(tester);
      expect(edit, findsNothing, reason: 'the editor again');
      await finish(tester);
    });
  });
}
