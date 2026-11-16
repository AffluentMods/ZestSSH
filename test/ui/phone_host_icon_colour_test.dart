import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';

/// A phone's host list (3.0): a host's chosen icon is in its own colour
/// unless the person had it follow the host's label or gave it a colour, the
/// same rule as on a computer.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);
}

const _blue = Color(0xFF3B82F6);
const _green = Color(0xFF22C55E);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (call) async => null);

  testWidgets('each host\'s icon in the colour its choice says', (tester) async {
    final debian = OsIcon.ownColor(OsCatalog.get('debian'));
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final now = DateTime(2026, 10, 8);
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
            id: 'g-web',
            name: 'Web',
            colorValue: Value(_blue.toARGB32()),
            createdAt: now,
            updatedAt: Value(now),
          ));
      for (final (id, label, iconColor) in <(String, String, int?)>[
        ('own', 'web-01', null),
        ('follows', 'web-02', HostIconColor.followsLabel),
        ('custom', 'db-primary', HostIconColor.custom(_green)),
      ]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: '192.168.10.${20 + label.length}',
              port: const Value(22),
              groupId: const Value('g-web'),
              iconId: const Value('debian'),
              iconColor: Value(iconColor),
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => null),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      recordingModeProvider.overrideWith((ref) => false),
      activeSessionsProvider.overrideWith(_Sessions.new),
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 8, 12))),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
      GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text('route ${state.uri.path}'))),
    ]);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        routerConfig: router,
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }

    Color glyph(String name) {
      final card = find.ancestor(of: find.text(name), matching: find.byType(PhoneHostRow));
      expect(card, findsOneWidget, reason: name);
      final icon = find.descendant(of: card, matching: find.byType(HostIcon));
      final svg = tester.widget<SvgPicture>(find.descendant(of: icon, matching: find.byType(SvgPicture)));
      for (final c in [_blue, _green, debian]) {
        if (svg.colorFilter == ColorFilter.mode(c, BlendMode.srcIn)) return c;
      }
      fail('$name: the glyph is in none of the colours of this test');
    }

    expect({debian, _blue, _green}.length, 3);
    expect(glyph('web-01'), debian, reason: 'its own, though its group is blue');
    expect(glyph('web-02'), _blue);
    expect(glyph('db-primary'), _green);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  });
}
