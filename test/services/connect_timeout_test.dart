import 'dart:io';

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
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

/// Settings' connection timeout (found while comparing the
/// five versions): a computer's Settings has "Connection timeout" under
/// Connection defaults, and nothing read it. A session's connection, a jump
/// host's, a console server's and Server Monitor's gave up after 15
/// seconds whatever it said, and a host form's test after 5.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String keyPem;
  late AppDatabase tree;
  late ProviderContainer container;
  late List<(String, int, Duration)> opened;

  setUpAll(() async {
    keyPem = (await KeyGenerationService().generateEd25519(comment: 'deploy')).privatePem;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem});
    SharedPreferences.setMockInitialValues(const {'connection_timeout': 42});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(tree),
      treeDatabaseProvider.overrideWithValue(tree),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    opened = [];
    // Nothing is dialled: what would be is written down, and refused.
    SshService.debugOpenSocket = (host, port, timeout) async {
      opened.add((host, port, timeout));
      throw const SocketException('Connection refused');
    };
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: 'id-deploy',
          label: 'deploy key',
          username: 'deploy',
          authMethod: 'publicKey',
          createdAt: at,
        ));
    for (final (id, address, protocol, via) in [
      ('h-web', '192.0.2.21', 'ssh', null),
      ('h-bastion', '192.0.2.10', 'ssh', null),
      ('h-db', '192.0.2.31', 'ssh', 'h-bastion'),
      ('h-console', '192.0.2.40', 'serial', null),
    ]) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id.substring(2),
            host: address,
            port: Value(protocol == 'serial' ? 3001 : 22),
            protocol: Value(protocol),
            identityId: const Value('id-deploy'),
            connectViaId: Value(via),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() async {
    SshService.debugOpenSocket = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  Future<Connection> host(String id) async => (await tree.connectionsDao.getById(id))!;

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  const given = Duration(seconds: 42);

  test("a session's connection is given the time Settings gives", () async {
    final id = sessions().startSession(await host('h-web'))!;
    await until(() => opened.isNotEmpty, 'the connection');
    expect(opened.single, ('192.0.2.21', 22, given), reason: 'it was 15 seconds');
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.error, 'the failure');
    await sessions().endSession(id);
  });

  test("a jump host's, the first of the way", () async {
    final id = sessions().startSession(await host('h-db'))!;
    await until(() => opened.isNotEmpty, 'the connection');
    expect(opened.single, ('192.0.2.10', 22, given));
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.error, 'the failure');
    await sessions().endSession(id);
  });

  test("a console server's", () async {
    final id = sessions().startSession(await host('h-console'))!;
    await until(() => opened.isNotEmpty, 'the connection');
    expect(opened.single, ('192.0.2.40', 3001, given));
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.error, 'the failure');
    await sessions().endSession(id);
  });

  test("Server Monitor's, and a run's on hosts", () async {
    await sessions().openExecClient(await host('h-web'));
    expect(opened.single, ('192.0.2.21', 22, given));
    opened.clear();
    await expectLater(sessions().openRunClient(await host('h-web')), throwsA(anything));
    expect(opened.single, ('192.0.2.21', 22, given));
  });

  testWidgets("a host form's tests, of reaching it and of signing in (they were 5 seconds)", (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final en = lookupAppLocalizations(const Locale('en'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: ConnectionEditScreen(connectionId: 'h-web', inDialog: true, onClose: () {})),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    Future<void> press(String button) async {
      final at = find.text(button).first;
      await tester.ensureVisible(at);
      await tester.tap(at);
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await press(en.zestHostTestFull);
    expect(opened.single, ('192.0.2.21', 22, given));
    opened.clear();
    await press(en.zestHostTestReachability);
    expect(opened.single, ('192.0.2.21', 22, given));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
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
