// What a phone says of a host's protocol, and offers (found
// while comparing the five versions): a phone's host card said SSH for a
// Mosh, an Eternal Terminal and a serial host; and a phone's host form offered
// all six protocols, of which Mosh, Eternal Terminal and an iPhone's local
// shell cannot be opened there (a session to one failed). Since 4.0 the app
// has its own Mosh client, so a phone offers Mosh too.)

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 10, 16);
    for (final (id, protocol) in [('h-mosh', 'mosh'), ('h-et', 'et'), ('h-serial', 'serial'), ('h-ssh', 'ssh')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id.substring(2),
            host: '192.168.10.${protocol.length}',
            protocol: Value(protocol),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() async {
    debugHostFormOnComputer = null;
    debugHostFormLocalShell = null;
    await db.close();
  });

  Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: home),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    return c;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  testWidgets("a phone's host card names a Mosh, an Eternal Terminal and a serial host's protocol (each said SSH)",
      (tester) async {
    final hosts = [for (final id in ['h-mosh', 'h-et', 'h-serial', 'h-ssh']) (await db.connectionsDao.getById(id))!];
    await pump(
      tester,
      ListView(children: [
        for (final h in hosts)
          PhoneHostRow(
            host: ConnectionWithDetails(connection: h),
            open: false,
            health: null,
            pinned: false,
            actions: PhoneHostActions(connect: () {}, edit: () {}),
          ),
      ]),
    );
    for (final label in ['Mosh', 'ET', 'Serial']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // SSH, what most hosts are, is not tagged.
    expect(find.text('SSH'), findsNothing);
    await finish(tester);
  });

  /// The protocols the form offers, by their pills' words.
  List<String> offered(WidgetTester tester) {
    return [
      for (final word in ['SSH', en.connectionEditProtocolSftpShort, 'Mosh', en.connectionEditProtocolEtShort, 'Telnet',
        en.connectionEditProtocolSerialShort, en.connectionEditProtocolLocalShort])
        if (find.text(word).evaluate().isNotEmpty) word,
    ];
  }

  testWidgets("a phone's host form offers what a phone can open; a host's own protocol is shown whatever it is",
      (tester) async {
    debugHostFormOnComputer = false;
    debugHostFormLocalShell = false;
    await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}));
    expect(offered(tester), ['SSH', 'SFTP', 'Mosh', 'Telnet', en.connectionEditProtocolSerialShort],
        reason: 'SFTP only and Mosh (the app\'s own client, 4.0) on every device; not Eternal Terminal, nor a local '
            'shell that this phone has none of');
    await finish(tester);

    await pump(tester, ConnectionEditScreen(connectionId: 'h-mosh', inDialog: true, onClose: () {}));
    expect(offered(tester), ['SSH', 'SFTP', 'Mosh', 'Telnet', en.connectionEditProtocolSerialShort], reason: 'its own');
    await finish(tester);

    debugHostFormLocalShell = true;
    await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}));
    expect(offered(tester), contains(en.connectionEditProtocolLocalShort), reason: "an Android phone's local shell");
    expect(offered(tester), isNot(contains(en.connectionEditProtocolEtShort)));
    await finish(tester);
  });

  testWidgets("a computer's host form offers all seven", (tester) async {
    debugHostFormOnComputer = true;
    debugHostFormLocalShell = true;
    await pump(tester, ConnectionEditScreen(inDialog: true, onClose: () {}));
    expect(offered(tester), hasLength(7));
    await finish(tester);
  });

  testWidgets("a host that is SFTP only: its card says SFTP where an SSH host's says nothing", (tester) async {
    final at = DateTime(2026, 10, 30);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-sftp',
          label: 'files-01',
          host: '192.0.2.20',
          protocol: const Value('sftp'),
          createdAt: at,
          updatedAt: at,
        ));
    final host = (await db.connectionsDao.getById('h-sftp'))!;
    await pump(
      tester,
      PhoneHostRow(
        host: ConnectionWithDetails(connection: host),
        open: false,
        health: null,
        pinned: false,
        actions: PhoneHostActions(connect: () {}, edit: () {}),
      ),
    );
    expect(find.text('SFTP'), findsOneWidget);
    await finish(tester);
  });
}
