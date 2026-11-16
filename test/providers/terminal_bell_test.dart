import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';

/// A terminal's bell, as Settings says (found while comparing
/// the five versions). The bell buzzed, which a computer cannot do, so on a
/// computer it did nothing; its switch was read once, when a session opened;
/// a program that rang it in a burst buzzed for every ring; and a phone's
/// Settings had no switch for it, though the computer's switch, synced,
/// silenced a phone's bell with no way back there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase tree;
  late ProviderContainer container;
  late List<String> rang;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(activeSessionsProvider.notifier).debugShellFor = (connection) => _Shell();
    rang = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'HapticFeedback.vibrate' || call.method == 'SystemSound.play') {
        rang.add('${call.method} ${call.arguments}');
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    debugBellOnComputer = null;
    container.dispose();
    await tree.close();
  });

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 15)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A session open on web-01, and its terminal.
  Future<SessionState> connected() async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web1',
          label: 'web-01',
          host: '10.50.0.5',
          port: const Value(23),
          protocol: const Value('telnet'),
          createdAt: at,
          updatedAt: at,
        ));
    final host = (await tree.connectionsDao.getById('h-web1'))!;
    final id = container.read(activeSessionsProvider.notifier).startSession(host)!;
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected, 'the session');
    return container.read(activeSessionsProvider)[id]!;
  }

  /// A program rings the bell [times] times at once, and a moment passes.
  Future<void> ring(SessionState session, {int times = 1}) async {
    session.session!.terminal.write('\x07' * times);
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  test('on a phone it buzzes, once for a burst of rings, and not once its switch is off, with the session open',
      () async {
    debugBellOnComputer = false;
    final session = await connected();
    await ring(session);
    expect(rang, ['HapticFeedback.vibrate HapticFeedbackType.heavyImpact']);

    await ring(session, times: 8);
    expect(rang, hasLength(2), reason: 'a burst of rings is one');

    await container.read(settingsUpdaterProvider).setBellEnabled(false);
    await ring(session);
    expect(rang, hasLength(2), reason: 'the switch as it is when it rings');
  });

  test("on a computer, the system's alert sound (a buzz is nothing there)", () async {
    debugBellOnComputer = true;
    final session = await connected();
    await ring(session);
    expect(rang, ['SystemSound.play SystemSoundType.alert']);
  });

  testWidgets("a phone's Settings has the bell's switch", (tester) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: TerminalSettingsScreen(),
      ),
    ));
    await tester.pump();
    final bell = find.byKey(const ValueKey('settings-terminal-bell'));
    await tester.scrollUntilVisible(bell, 200);
    expect(container.read(bellEnabledProvider), isTrue);
    await tester.tap(bell);
    await tester.pump();
    expect(container.read(bellEnabledProvider), isFalse);
    expect(tester.widget<SwitchListTile>(bell).value, isFalse);
  });
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A shell that connects and stays.
class _Shell extends ShellService {
  final _state = StreamController<bool>.broadcast();
  bool _connected = false;

  @override
  Future<void> connect() async {
    _connected = true;
    _state.add(true);
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _state.add(false);
  }

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => false;
}
