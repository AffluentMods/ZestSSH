import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/desktop/widgets/quick_connect_v3.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;

/// Quick connect (3.0): what is typed, `user@host:port`, is read one way
/// everywhere it is typed (each box read it its own way, and an IPv6
/// address was cut at its first colon), and the user typed is the one the
/// session signs in as: a computer's Quick connect and its hosts' search box
/// dropped it and signed in as the default user. A host that is not saved
/// has the id the rest of the app knows as not saved.

Future<void> _loadFonts() async {
  for (final (family, files) in [
    ('GeistSans', ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf', 'GeistSans-Bold.ttf']),
    ('JetBrainsMono', ['JetBrainsMono-Regular.ttf', 'JetBrainsMono-Bold.ttf']),
  ]) {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File('assets/fonts/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load().timeout(const Duration(seconds: 30));
  }
}

/// Sessions asked for, kept here: the connection and the user typed.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final asked = <(Connection, String?)>[];

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
    asked.add((connection, usernameOverride));
    return 'session-${asked.length}';
  }
}

class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('what is typed', () {
    test('a host, a user, a port, ssh:// before it, an IPv6 address bare or in brackets', () {
      expect(parseQuickTarget('web-01.example.com'), const QuickTarget(host: 'web-01.example.com'));
      expect(parseQuickTarget(' deploy@web-01.example.com:2222 '),
          const QuickTarget(user: 'deploy', host: 'web-01.example.com', port: 2222));
      expect(parseQuickTarget('ssh://deploy@203.0.113.7/'), const QuickTarget(user: 'deploy', host: '203.0.113.7'));
      expect(parseQuickTarget('SSH://203.0.113.7:2200'), const QuickTarget(host: '203.0.113.7', port: 2200));
      expect(parseQuickTarget('root@[2001:db8::1]:2222'), const QuickTarget(user: 'root', host: '2001:db8::1', port: 2222));
      expect(parseQuickTarget('[2001:db8::1]'), const QuickTarget(host: '2001:db8::1'));
      expect(parseQuickTarget('2001:db8::5'), const QuickTarget(host: '2001:db8::5'), reason: 'bare, port 22');
      expect(parseQuickTarget('ops@::ffff:192.0.2.1'), const QuickTarget(user: 'ops', host: '::ffff:192.0.2.1'));
      expect(parseQuickTarget('me@corp@bastion.example.com'), const QuickTarget(user: 'me@corp', host: 'bastion.example.com'),
          reason: 'the last @ ends the user');
      expect(parseQuickTarget('web-01:65535')?.port, 65535);
      expect(parseQuickTarget('web-01:1')?.port, 1);
    });

    test('what names no host, no port from 1 to 65535, or no user is not read', () {
      for (final bad in [
        '',
        '   ',
        '@web-01',
        'web 01',
        'de ploy@web-01',
        'tab\tuser@web-01',
        'web/01',
        'web-01:0',
        'web-01:65536',
        'web-01:22a',
        'web-01:',
        'web-01:-1',
        'web-01:+22',
        '[2001:db8::1',
        '[2001:db8::1]x',
        '[2001:db8::1]x2222',
        '[2001:db8::1]:',
        '[web-01]',
        '[abc]',
        '2001:db8::zz',
        'ssh://',
        'a' * 254,
      ]) {
        expect(parseQuickTarget(bad), isNull, reason: bad);
      }
      expect(parseQuickTarget('a' * 253)?.host, hasLength(253));
    });

    // Found while comparing the five platforms' versions: Quick
    // connect handed on 'u@web' for 'u@web:22', and the shell, reading it
    // again with the port Settings gives new connections, reached that port.
    test('a port typed is kept as typed, 22 too: read again where new connections have another port, it is the same',
        () {
      expect(parseQuickTarget('u@web:22')!.typed, 'u@web:22');
      expect(parseQuickTarget(parseQuickTarget('u@web:22')!.typed, defaultPort: 2200)!.port, 22);
      expect(parseQuickTarget('[2001:db8::1]:22')!.typed, '[2001:db8::1]:22');
      expect(parseQuickTarget('u@web')!.typed, 'u@web', reason: 'none typed: none handed on, the default reached');
      expect(parseQuickTarget(parseQuickTarget('u@web')!.typed, defaultPort: 2200)!.port, 2200);
      expect(parseQuickTarget('u@web', defaultPort: 2200)!.typed, 'u@web:2200');
      expect(parseQuickTarget('u@web:22'), const QuickTarget(user: 'u', host: 'web'), reason: 'the same target');
    });

    test('as it would be typed again, and read back the same', () {
      for (final t in const [
        QuickTarget(host: 'web'),
        QuickTarget(user: 'u', host: 'web', port: 2222),
        QuickTarget(user: 'u', host: '2001:db8::1'),
        QuickTarget(host: '2001:db8::1', port: 2200),
      ]) {
        expect(parseQuickTarget(t.typed), t, reason: t.typed);
      }
      expect(const QuickTarget(user: 'u', host: '2001:db8::1', port: 2200).typed, 'u@[2001:db8::1]:2200');
      expect(const QuickTarget(host: 'web').typed, 'web');
      expect('${const QuickTarget(user: 'u', host: 'web', port: 2)}', 'u@web:2');
      // The same target, and not: each part counts.
      const target = QuickTarget(user: 'u', host: 'web', port: 2222);
      expect(target, const QuickTarget(user: 'u', host: 'web', port: 2222));
      expect(target.hashCode, const QuickTarget(user: 'u', host: 'web', port: 2222).hashCode);
      for (final other in const [
        QuickTarget(host: 'web', port: 2222),
        QuickTarget(user: 'u', host: 'mail', port: 2222),
        QuickTarget(user: 'u', host: 'web'),
      ]) {
        expect(target, isNot(other));
        expect(target.hashCode, isNot(other.hashCode));
      }
    });

    test('a host that is not saved: its id one the app knows as not saved, named as typed', () {
      final at = DateTime(2026, 10, 16, 9);
      final c = quickConnectionOf(const QuickTarget(user: 'deploy', host: '2001:db8::1', port: 2200), now: at);
      expect(c.id, startsWith('quick_'));
      expect((c.label, c.host, c.port, c.protocol), ('deploy@[2001:db8::1]', '2001:db8::1', 2200, 'ssh'));
      expect(c.identityId, isNull);
      expect(quickConnectionOf(const QuickTarget(host: 'web-01'), now: at).label, 'web-01');
      expect(quickConnectionOf(const QuickTarget(host: 'a'), now: at).id,
          isNot(quickConnectionOf(const QuickTarget(host: 'a'), now: at.add(const Duration(microseconds: 1))).id));
    });
  });

  group('on a computer', () {
    late _Sessions sessions;

    // Messages on screen, as a phone shows them (a computer's go to the
    // notification center).
    setUp(() => debugTopSnackBarOnPhone = true);
    tearDown(() => debugTopSnackBarOnPhone = null);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> pump(WidgetTester tester, Widget body) async {
      await tester.runAsync(_loadFonts);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      tester.view.physicalSize = const Size(1500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final now = DateTime(2026, 10, 15);
      await tester.runAsync(() => db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web', label: 'web-01', host: 'web-01.example.com', createdAt: now, updatedAt: now)));
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        healthChecksEnabledProvider.overrideWith((ref) => false),
        activeSessionsProvider.overrideWith(_Sessions.new),
        serverStatsProvider.overrideWith(_NoStats.new),
      ]);
      addTearDown(c.dispose);
      sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: body),
        ),
      ));
      await settle(tester);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(hours: 1));
    }

    Future<void> typeAndGo(WidgetTester tester, Finder field, String text) async {
      await tester.enterText(field, text);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settle(tester);
    }

    testWidgets('Quick connect hands on what was typed, an IPv6 address in brackets; no user, or no address, is '
        'said', (tester) async {
      final handed = <String>[];
      await pump(
          tester,
          Builder(
              builder: (context) => TextButton(
                  onPressed: () => QuickConnectV3.show(context, onConnect: handed.add), child: const Text('open'))));
      Future<void> typed(String text) async {
        await tester.tap(find.text('open'));
        await settle(tester);
        final field = find.descendant(of: find.byType(QuickConnectV3), matching: find.byType(TextField));
        await tester.enterText(field, text);
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.go);
        await settle(tester);
      }

      await typed('deploy@[2001:db8::1]:2222');
      expect(handed, ['deploy@[2001:db8::1]:2222']);
      expect(parseQuickTarget(handed.single), const QuickTarget(user: 'deploy', host: '2001:db8::1', port: 2222));
      await typed('203.0.113.7');
      expect(find.text(l10n.quickConnectV3SpecifyUserHost), findsOneWidget);
      await tester.enterText(find.descendant(of: find.byType(QuickConnectV3), matching: find.byType(TextField)),
          'deploy@203.0.113.7:99999');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settle(tester);
      expect(find.text(l10n.quickConnectV3InvalidHostFormat), findsOneWidget);
      expect(handed, hasLength(1));
      await finish(tester);
    });

    // Found as above: a 22 typed was handed on as no port.
    testWidgets('Quick connect hands on a port typed, 22 too, so the one Settings gives new connections does not take '
        'its place', (tester) async {
      final handed = <String>[];
      await pump(
          tester,
          Builder(
              builder: (context) => TextButton(
                  onPressed: () => QuickConnectV3.show(context, onConnect: handed.add), child: const Text('open'))));
      for (final text in ['deploy@203.0.113.8:22', 'deploy@203.0.113.9']) {
        await tester.tap(find.text('open'));
        await settle(tester);
        await typeAndGo(
            tester, find.descendant(of: find.byType(QuickConnectV3), matching: find.byType(TextField)), text);
      }
      expect(handed, ['deploy@203.0.113.8:22', 'deploy@203.0.113.9']);
      // Read as the shell reads it (DesktopShell._quickConnectUri), where new
      // connections are given 2200.
      expect(handed.map((h) => parseQuickTarget(h, defaultPort: 2200)!.port), [22, 2200]);
      await finish(tester);
    });

    testWidgets("the Hosts page's search box: as the user typed, a host that is not saved; an IPv6 address too; a "
        'name searched for', (tester) async {
      final connected = <Connection>[];
      await pump(tester, HostsHomePage(onConnectTo: (item) => connected.add(item.connection)));
      final bar = find.byType(TextField).first;
      await typeAndGo(tester, bar, 'deploy@[2001:db8::1]:2222');
      final (connection, user) = sessions.asked.single;
      expect(user, 'deploy');
      expect(connection.id, startsWith('quick_'), reason: 'the id the app knows as not saved');
      expect((connection.host, connection.port, connection.label), ('2001:db8::1', 2222, 'deploy@[2001:db8::1]'));
      await typeAndGo(tester, bar, '203.0.113.9');
      expect(sessions.asked.last.$2, isNull, reason: 'no user typed: the default');
      expect(sessions.asked.last.$1.host, '203.0.113.9');
      await typeAndGo(tester, bar, '2001:db8::7');
      expect(sessions.asked.last.$1.host, '2001:db8::7');
      await typeAndGo(tester, bar, 'web-01');
      expect(sessions.asked, hasLength(3), reason: 'a name: the saved host found');
      expect(connected.single.id, 'h-web');
      await finish(tester);
    });
  });
}
