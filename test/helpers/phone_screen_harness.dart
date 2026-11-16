import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

import '../visual/shots_util.dart';

/// A phone's screen drawn as a phone shows it: [size] wide and tall, its status
/// bar [top] high and its navigation bar [bottom] high (the screen's padding, as
/// Android gives an app that draws edge to edge), in the app's own theme and
/// fonts, over a database with a host, a key, a snippet, a forward, a trigger,
/// a command run, an automation run and a workflow (all made up). Shared by the
/// tests that look at where a phone's screens put what can be tapped.
class PhoneScreenHarness {
  PhoneScreenHarness._();

  /// Draws [screen]; what failed while it was drawn is added to [problems].
  /// Call [takeDown] after looking at it.
  static Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(412, 915),
    double top = 40,
    double bottom = 48,
    List<String>? problems,
  }) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => ['wifi'],
    );
    messenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(top: top, bottom: bottom);
    tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById('default_dark');
    AppColors.applyTheme(theme.colorScheme);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() => _seed(db));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
        databaseSessionProvider.overrideWith(
          (ref) => DatabaseSessionNotifier()..seed(db),
        ),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
        syncHealthClockProvider.overrideWith(
          (ref) => Stream.value(DateTime(2026, 10, 17, 12)),
        ),
      ],
    );
    _container = container;
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => screen),
        GoRoute(
          path: '/:rest(.*)',
          builder: (_, state) => Scaffold(body: Text(state.uri.toString())),
        ),
      ],
    );
    _router = router;
    final reported = FlutterError.onError;
    FlutterError.onError = (details) =>
        problems?.add(details.exceptionAsString().split('\n').first);
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            theme: theme.toThemeData(),
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
    } finally {
      FlutterError.onError = reported;
    }
  }

  static ProviderContainer? _container;
  static GoRouter? _router;

  /// Takes the screen down again, and its timers with it.
  static Future<void> takeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    _container?.dispose();
    _router?.dispose();
    _container = null;
    _router = null;
    await tester.pump(const Duration(minutes: 10));
  }

  /// What can be tapped on screen and sits in a system bar: under the status bar
  /// ([top]) or the navigation bar ([bottom]) of a screen [height] tall. Only what
  /// is pinned counts: a row of a list may scroll under a bar and back.
  static List<String> tappablesUnderBars(
    WidgetTester tester, {
    required double height,
    double top = 40,
    double bottom = 48,
  }) {
    final found = <String>[];
    for (final element in find.byWidgetPredicate(_tappable).evaluate()) {
      final box = element.renderObject;
      if (box is! RenderBox || !box.hasSize || !box.attached || box.size.isEmpty) {
        continue;
      }
      if (_inAScrollable(element)) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.bottom <= 0 || rect.top >= height) continue; // off the screen
      if (rect.top < top || rect.bottom > height - bottom) {
        found.add(
          '${_describe(element.widget)} at ${rect.top.toStringAsFixed(0)}..${rect.bottom.toStringAsFixed(0)}',
        );
      }
    }
    return found;
  }

  static bool _tappable(Widget w) =>
      (w is InkWell && w.onTap != null) ||
      (w is ButtonStyleButton && w.onPressed != null) ||
      (w is IconButton && w.onPressed != null) ||
      (w is GestureDetector && w.onTap != null) ||
      (w is ListTile && w.onTap != null);

  static bool _inAScrollable(Element element) {
    var inside = false;
    element.visitAncestorElements((a) {
      if (a.widget is Scrollable) {
        inside = true;
        return false;
      }
      return true;
    });
    return inside;
  }

  static String _describe(Widget w) {
    final text = switch (w) {
      ButtonStyleButton(:final child) => child is Text ? child.data : null,
      IconButton(:final tooltip) => tooltip,
      _ => null,
    };
    return '${w.runtimeType}${text == null ? '' : ' "$text"'}';
  }
}

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

/// A few rows, so screens show rows (all made up).
Future<void> _seed(AppDatabase db) async {
  final now = DateTime(2026, 10, 17, 12);
  await db
      .into(db.connections)
      .insert(
        ConnectionsCompanion.insert(
          id: 'c1',
          label: 'web-01',
          host: '192.168.10.21',
          port: const Value(22),
          createdAt: now,
          updatedAt: now,
        ),
      );
  await db
      .into(db.identities)
      .insert(
        IdentitiesCompanion.insert(
          id: 'i1',
          label: 'deploy key',
          username: 'alex',
          authMethod: 'key',
          keyType: const Value('ssh-ed25519'),
          createdAt: now,
        ),
      );
  await db
      .into(db.snippets)
      .insert(
        SnippetsCompanion.insert(
          id: 's1',
          label: 'Disk usage',
          command: 'df -h',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await db
      .into(db.portForwardRules)
      .insert(
        PortForwardRulesCompanion.insert(
          id: 'p1',
          connectionId: 'c1',
          type: 'local',
          bindPort: 8080,
          remoteHost: 'localhost',
          remotePort: 80,
          createdAt: now,
        ),
      );
  await db
      .into(db.terminalTriggers)
      .insert(
        TerminalTriggersCompanion.insert(
          id: 't1',
          name: 'Build failed',
          pattern: 'ERROR',
          createdAt: now,
        ),
      );
  await db
      .into(db.commandHistory)
      .insert(
        CommandHistoryCompanion.insert(
          id: 'h1',
          command: 'sudo systemctl restart nginx',
          createdAt: now,
        ),
      );
  await db
      .into(db.automationHistory)
      .insert(
        AutomationHistoryCompanion.insert(
          id: 'a1',
          timestamp: DateTime(2026, 9, 28, 12),
          action: 'execute',
          connectionId: 'c1',
          command: 'uptime',
          success: true,
          elapsedMs: 120,
        ),
      );
  await db
      .into(db.workflows)
      .insert(
        WorkflowsCompanion.insert(id: 'w1', name: 'Deploy web', createdAt: now),
      );
}
