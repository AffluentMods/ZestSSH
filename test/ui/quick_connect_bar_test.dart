import 'package:drift/drift.dart' hide Column, isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;

/// The phone's quick connect bar (3.0): `user@host:port` read as everywhere
/// it is typed (an IPv6 address in brackets too), and the user typed is the
/// one the session signs in as. A host saved with that address is connected
/// to with its own account where no user is typed or the one typed is its
/// key's; with one of its other accounts whose user it is; else as the user
/// typed, with a key of that user where there is one, never with the host's
/// own key (another account's). Before, the host's key's user signed in,
/// whatever was typed. A new address is saved, with a key of the user
/// typed. What goes wrong is said in words, in every language.

/// Sessions asked for: the host, the user typed, the account chosen.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final asked = <({Connection host, String? user, String? account})>[];
  var held = 0;

  @override
  int get occupiedSessionSlots => held;

  @override
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) {
    asked.add((host: connection, user: usernameOverride, account: asAccount));
    return 'session-${asked.length}';
  }
}

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 10, 16);

  late AppDatabase db;
  late _Sessions sessions;
  late List<String> pages;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // Messages as a phone shows them, on screen.
    debugTopSnackBarOnPhone = true;
  });

  tearDown(() async {
    debugTopSnackBarOnPhone = null;
    try {
      await db.close();
    } catch (_) {/* closed by the test already */}
  });

  /// Keys of root, deploy and ops; web-01 (signed in as root by default,
  /// deploy its other account) and an IPv6 host with no key.
  Future<void> seed() async {
    for (final (id, user) in [('i-root', 'root'), ('i-deploy', 'deploy'), ('i-ops', 'ops')]) {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: id, label: '$user key', username: user, authMethod: 'publicKey', createdAt: at));
    }
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-web', label: 'web-01', host: 'web-01.example.com', identityId: const Value('i-root'), createdAt: at, updatedAt: at));
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-v6', label: 'v6', host: '2001:db8::1', port: const Value(2222), createdAt: at, updatedAt: at));
    await db.hostAccountsDao.setOtherAccounts('h-web', ['i-deploy']);
  }

  Future<void> pump(WidgetTester tester, {bool pro = true, Map<String, Object> settings = const {}}) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(settings);
    final prefs = await SharedPreferences.getInstance();
    pages = [];
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => const Scaffold(body: Column(children: [QuickConnectBar()]))),
      GoRoute(
          path: '/terminal/:id',
          builder: (context, state) {
            pages.add(state.uri.toString());
            return const Scaffold(body: Text('terminal'));
          }),
      GoRoute(
          path: Routes.upgrade,
          builder: (context, state) {
            pages.add(state.uri.toString());
            return const Scaffold(body: Text('upgrade'));
          }),
    ]);
    addTearDown(router.dispose);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      activeSessionsProvider.overrideWith(_Sessions.new),
      isProProvider.overrideWith((ref) => _Plan(pro)),
    ]);
    addTearDown(c.dispose);
    sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Types [text] in the bar and connects, back on the bar afterwards.
  Future<void> connect(WidgetTester tester, String text) async {
    if (find.byType(QuickConnectBar).evaluate().isEmpty) {
      GoRouter.of(tester.element(find.text('terminal'))).go('/');
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
  }

  /// Types [text] in the bar and connects, where a question comes up first
  /// (the bar's wheel turns behind it: it never settles).
  Future<void> connectAsked(WidgetTester tester, String text) async {
    if (find.byType(QuickConnectBar).evaluate().isEmpty) {
      GoRouter.of(tester.element(find.text('terminal'))).go('/');
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a saved host found by its address: its own account where no user is typed, or the one typed is its '
      "key's; one of its other accounts whose user it is; else as the user typed, with a key of that user, never the "
      "host's own", (tester) async {
    await seed();
    await pump(tester);
    expect(find.text(l10n.phoneHostsSearchHint), findsOneWidget);

    await connect(tester, 'web-01.example.com');
    expect((sessions.asked.last.host.id, sessions.asked.last.user, sessions.asked.last.account), ('h-web', null, null));
    expect(pages.last, '/terminal/session-1');

    await connect(tester, 'root@web-01.example.com');
    expect((sessions.asked.last.host.id, sessions.asked.last.user, sessions.asked.last.account), ('h-web', 'root', null));

    await connect(tester, 'deploy@web-01.example.com');
    expect((sessions.asked.last.host.id, sessions.asked.last.account), ('h-web', 'i-deploy'),
        reason: 'its other account, deploy');

    await connect(tester, 'ops@web-01.example.com:22');
    final ops = sessions.asked.last;
    expect(ops.host.id, startsWith('quick_'), reason: "not the saved host, whose key is root's");
    expect((ops.host.host, ops.host.port, ops.host.identityId, ops.user, ops.account),
        ('web-01.example.com', 22, 'i-ops', 'ops', null));

    await connect(tester, 'nobody@web-01.example.com');
    expect((sessions.asked.last.host.id.startsWith('quick_'), sessions.asked.last.host.identityId, sessions.asked.last.user),
        (true, null, 'nobody'));
    expect(await db.connectionsDao.getAll(), hasLength(2), reason: 'nothing saved again');
    expect(pages, hasLength(5));
  });

  testWidgets('a new address is saved, with a key of the user typed, and connected to; an IPv6 address in brackets is '
      'found as saved', (tester) async {
    await seed();
    await pump(tester);
    await connect(tester, 'deploy@203.0.113.7:2200');
    final saved = (await db.connectionsDao.getAll()).singleWhere((c) => c.host == '203.0.113.7');
    expect((saved.port, saved.label, saved.identityId), (2200, 'deploy@203.0.113.7:2200', 'i-deploy'));
    expect((sessions.asked.single.host.id, sessions.asked.single.user), (saved.id, 'deploy'));

    await connect(tester, 'ops@[2001:db8::1]:2222');
    expect((sessions.asked.last.host.id, sessions.asked.last.user), ('h-v6', 'ops'), reason: 'a host with no key');
    await connect(tester, '[2001:db8::1]:2222');
    expect((sessions.asked.last.host.id, sessions.asked.last.user), ('h-v6', null));
    expect(await db.connectionsDao.getAll(), hasLength(3));
  });

  // Found while comparing the five versions: Settings' port
  // for new connections was read by nothing, and an address typed with no
  // port was saved and reached on 22.
  testWidgets('an address typed with no port is saved and reached on the port Settings gives new connections',
      (tester) async {
    await seed();
    await pump(tester, settings: {'default_port': 2222});
    await connect(tester, 'deploy@203.0.113.8');
    final saved = (await db.connectionsDao.getAll()).singleWhere((c) => c.host == '203.0.113.8');
    expect(saved.port, 2222);
    expect(sessions.asked.single.host.id, saved.id);
    await connect(tester, 'deploy@203.0.113.9:22');
    expect((await db.connectionsDao.getAll()).singleWhere((c) => c.host == '203.0.113.9').port, 22,
        reason: 'a port typed is that port');
  });

  // Found while comparing the five versions: a saved Telnet
  // host typed in the bar was connected to with no word, where the host list
  // asks first (nothing encrypts it, a password typed in it among the rest);
  // and one typed with a user not its key's was reached over SSH, on its
  // Telnet port.
  testWidgets("a saved Telnet host is asked about first, in the host list's words, Cancel opening nothing; a user "
      'typed with it opens the host itself', (tester) async {
    await seed();
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-tel',
        label: 'switch',
        host: 'switch.example.com',
        port: const Value(23),
        protocol: const Value('telnet'),
        identityId: const Value('i-root'),
        createdAt: at,
        updatedAt: at));
    await pump(tester);
    await connectAsked(tester, 'switch.example.com:23');
    expect(find.text(l10n.homeTelnetWarningTitle), findsOneWidget);
    expect(find.text(l10n.homeTelnetWarningBody), findsOneWidget);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(sessions.asked, isEmpty);
    expect(pages, isEmpty);

    await connectAsked(tester, 'switch.example.com:23');
    await tester.tap(find.text(l10n.homeTelnetConnectAnyway));
    await tester.pumpAndSettle();
    expect((sessions.asked.single.host.id, sessions.asked.single.user), ('h-tel', null));
    expect(pages, ['/terminal/session-1']);

    await connectAsked(tester, 'ops@switch.example.com:23');
    expect(find.text(l10n.homeTelnetWarningTitle), findsOneWidget, reason: "ops is not its key's user: still Telnet");
    await tester.tap(find.text(l10n.homeTelnetConnectAnyway));
    await tester.pumpAndSettle();
    expect((sessions.asked.last.host.id, sessions.asked.last.host.protocol), ('h-tel', 'telnet'));

    await connect(tester, 'web-01.example.com');
    expect(find.text(l10n.homeTelnetWarningTitle), findsNothing, reason: 'an SSH host: nothing asked');
    expect(sessions.asked.last.host.id, 'h-web');
    expect(await db.connectionsDao.getAll(), hasLength(3), reason: 'nothing saved');
  });

  testWidgets('what names no host is said in words, and nothing is connected to', (tester) async {
    await seed();
    await pump(tester);
    await connect(tester, 'deploy@web 01');
    expect(find.text(l10n.quickConnectV3InvalidHostFormat), findsOneWidget);
    await connect(tester, 'deploy@web-01:70000');
    expect(sessions.asked, isEmpty);
    expect(pages, isEmpty);
  });

  testWidgets("the free plan's limit is said, in words, with the way to more", (tester) async {
    await seed();
    await pump(tester, pro: false);
    sessions.held = 99;
    await connect(tester, 'root@web-01.example.com');
    expect(sessions.asked, isEmpty);
    expect(find.text(l10n.hostsHomeFreeTierLimit), findsOneWidget);
    await tester.tap(find.text(l10n.upgrade));
    await tester.pumpAndSettle();
    expect(pages, [Routes.upgrade]);
  });

  testWidgets('a failure before anything is connected is said in words, with its details', (tester) async {
    await seed();
    await pump(tester);
    await tester.runAsync(db.close);
    await connect(tester, 'deploy@203.0.113.7');
    expect(find.text(l10n.quickConnectNotStarted), findsOneWidget);
    expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
    expect(sessions.asked, isEmpty);
  });

  // Found in a code review: a word typed in the bar connected to the
  // first saved host with it anywhere in its name, address, user or group,
  // so "root" or "pi" opened whichever host came first.
  testWidgets('a word names a saved host only when it is one host: its name or address exactly, or the only one '
      'with it in it; else what was typed is dialed', (tester) async {
    await seed();
    for (final (id, label, host) in [('h-pihole', 'pi-hole', 'pihole-box'), ('h-rpi', 'raspberrypi', 'rpi4')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id, label: label, host: host, identityId: const Value('i-root'), createdAt: at, updatedAt: at));
    }
    await pump(tester);

    await connect(tester, 'pi');
    expect(sessions.asked.last.host.id, isNot(anyOf('h-pihole', 'h-rpi', 'h-web')),
        reason: 'two hosts have "pi" in them: neither is meant, "pi" is dialed');
    expect(sessions.asked.last.host.host, 'pi');

    await connect(tester, 'root');
    expect(sessions.asked.last.host.host, 'root', reason: 'three hosts sign in as root: none is meant');

    await connect(tester, 'PI-HOLE');
    expect(sessions.asked.last.host.id, 'h-pihole', reason: 'its name, exactly');

    await connect(tester, 'rpi4');
    expect(sessions.asked.last.host.id, 'h-rpi', reason: 'its address, exactly');

    await connect(tester, 'raspb');
    expect(sessions.asked.last.host.id, 'h-rpi', reason: 'the only host with it in it');
  });

  test('savedHostNamedAs: an exact name before an exact address before the only one with it in it', () async {
    for (final (id, label, address) in [('a', 'nas', 'storage'), ('b', 'storage', 'nas2'), ('c', 'build', 'ci')]) {
      await db.into(db.connections).insert(
          ConnectionsCompanion.insert(id: id, label: label, host: address, createdAt: at, updatedAt: at));
    }
    final hosts = await db.connectionsDao.watchAllWithDetails().first;
    expect(savedHostNamedAs(hosts, 'NAS')?.connection.id, 'a');
    expect(savedHostNamedAs(hosts, 'storage')?.connection.id, 'b', reason: 'a name before an address');
    expect(savedHostNamedAs(hosts, 'ci')?.connection.id, 'c');
    expect(savedHostNamedAs(hosts, 'na'), isNull, reason: 'two hosts with it in them');
    expect(savedHostNamedAs(hosts, 'bui')?.connection.id, 'c');
    expect(savedHostNamedAs(hosts, 'nas.local'), isNull, reason: 'an address');
    expect(savedHostNamedAs(hosts, 'zzz'), isNull);
  });
}
