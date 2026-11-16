// The port Settings gives new connections (found while
// comparing the five versions): a computer's Settings has a "Default SSH
// port" under Connection defaults, and nothing read it. A new host's form
// said 22, and so did choosing SSH, Mosh or Eternal Terminal again; a host
// typed with no port (quick connect) was reached on 22.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  test('a host typed with no port is on the port given; one typed with a port on that one', () {
    QuickTarget t(String s) => parseQuickTarget(s, defaultPort: 2222)!;
    expect((t('web-01').host, t('web-01').port), ('web-01', 2222));
    expect((t('deploy@192.168.10.21').user, t('deploy@192.168.10.21').port), ('deploy', 2222));
    expect(t('[2001:db8::1]').port, 2222);
    expect(t('ssh://deploy@web-01/').port, 2222);
    expect(t('web-01:22').port, 22, reason: 'what is typed');
    expect(t('deploy@[2001:db8::1]:2200').port, 2200);
    expect(parseQuickTarget('web-01')!.port, 22, reason: 'with none given, 22');
  });

  test("a computer's Settings offers no default sign-in method, which nothing could read (a host signs in as its "
      'account says)', () {
    final code = File('lib/ui/screens/desktop/widgets/settings_inline_view.dart').readAsStringSync();
    expect(code, contains('l10n.settingsInlineDefaultSshPort'));
    expect(code, isNot(contains('settingsInlineDefaultAuthMethod')), reason: 'its row, and its line in the search');
  });

  group("a host's form", () {
    late AppDatabase db;

    Future<void> pump(WidgetTester tester, {String? connectionId}) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (arguments, events) {}));
      tester.view.physicalSize = const Size(1300, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({'default_port': 2222});
      final prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final now = DateTime(2026, 10, 16);
      if (connectionId != null) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: connectionId,
              label: 'web-01',
              host: '192.168.10.21',
              port: const Value(22),
              createdAt: now,
              updatedAt: now,
            ));
      }
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
          home: Scaffold(body: ConnectionEditScreen(connectionId: connectionId, inDialog: true, onClose: () {})),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    String port(WidgetTester tester) =>
        tester.widget<TextFormField>(find.byKey(const ValueKey('host-port'))).controller!.text;

    Future<void> choose(WidgetTester tester, String protocol) async {
      await tester.ensureVisible(find.text(protocol).first);
      await tester.tap(find.text(protocol).first);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(hours: 1));
    }

    testWidgets("a new host's port is the one Settings gives, and so is SSH's, Mosh's and Eternal Terminal's when "
        "one is chosen; Telnet's is 23",
        (tester) async {
      await pump(tester);
      expect(port(tester), '2222', reason: 'it said 22');
      await choose(tester, 'Telnet');
      expect(port(tester), '23');
      await choose(tester, 'Mosh');
      expect(port(tester), '2222', reason: 'its SSH port');
      await choose(tester, 'Telnet');
      await choose(tester, lookupAppLocalizations(const Locale('en')).connectionEditProtocolEtShort);
      expect(port(tester), '2222', reason: 'its SSH port');
      await choose(tester, 'Telnet');
      await choose(tester, 'SSH');
      expect(port(tester), '2222');
      await finish(tester);
    });

    testWidgets('a saved host keeps its own port', (tester) async {
      await pump(tester, connectionId: 'c1');
      expect(port(tester), '22');
      await finish(tester);
    });
  });
}
