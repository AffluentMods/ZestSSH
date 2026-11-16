import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

import '../../packages/zest_ssh_core/test/src/played_listener.dart';

/// A host whose key is not on this device (deleted elsewhere while the host
/// was kept as it was; in a team space, a key of a Crate this device cannot
/// use) says so, before anything is dialled (3.0). It signed in with
/// nothing: the default user, no key, and the host's own refusal.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  test('a host whose key is not on this device says so, and nothing is dialled', () async {
    final listener = await PlayedListener.bind();
    addTearDown(listener.close);
    final at = DateTime(2026, 10, 16);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web',
          host: listener.host,
          port: Value(listener.port),
          identityId: const Value('k-gone'),
          createdAt: at,
          updatedAt: at,
        ));
    final sessions = container.read(activeSessionsProvider.notifier);
    final id = sessions.startSession((await tree.connectionsDao.getById('h-web'))!)!;
    SessionState? state() => container.read(activeSessionsProvider)[id];
    final clock = Stopwatch()..start();
    while (state()?.status != SessionStatus.error && state()?.status != SessionStatus.disconnected) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for the refusal');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(state()?.errorMessage, contains(en.connKeyNotHere));
    await expectLater(listener.line().timeout(const Duration(milliseconds: 400)), throwsA(isA<TimeoutException>()));
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

class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
