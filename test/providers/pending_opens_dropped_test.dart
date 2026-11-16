import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pending_files.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

/// A host's files asked for from a phone's host sheet before it was
/// connected (sftpPendingConnectionProvider), or tmux from a host's badge
/// (tmuxPendingConnectionProvider), are opened by its terminal once its
/// session is up. When that connection was not made, the request stayed:
/// the next session to that host, started any other way and at any later
/// time, opened its files by itself.
///
/// Against a port of this machine that nothing listens on, so the connection
/// is refused, with no server needed. The hosts have no key: the password
/// asked for is given (and the connection then fails), or not (cancelled).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  late int closedPort;

  setUpAll(() async {
    // A port that was free a moment ago: nothing answers on it.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    closedPort = probe.port;
    await probe.close();
  });

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
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    final at = DateTime(2026, 10, 1);
    for (final id in ['h-web', 'h-db']) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id,
            host: '127.0.0.1',
            port: Value(closedPort),
            createdAt: at,
            updatedAt: at,
          ));
    }
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  /// Answers every password question with [password]; null cancels it.
  void answering(String? password) {
    container.listen(passwordPromptProvider, (_, asked) {
      if (asked == null || asked.completer.isCompleted) return;
      Future<void>.microtask(() => asked.completer
          .complete(password == null ? null : PasswordPromptResult(password: password)));
    });
  }

  Future<void> failed(String sessionId) async {
    final clock = Stopwatch()..start();
    while (stateOf(sessionId) != null && stateOf(sessionId)!.status != SessionStatus.error) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for the connection to fail');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('files asked for on a host whose connection fails are asked no longer', () async {
    answering('not-a-real-password');
    container.read(sftpPendingConnectionProvider.notifier).state = 'h-web';
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await failed(id);
    expect(container.read(sftpPendingConnectionProvider), isNull,
        reason: 'the next session to this host would open its files by itself');
  });

  test('files asked for on a host whose connection is cancelled are asked no longer', () async {
    answering(null);
    container.read(sftpPendingConnectionProvider.notifier).state = 'h-web';
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await failed(id);
    expect(container.read(sftpPendingConnectionProvider), isNull);
  });

  test('tmux asked for on a host whose connection fails is asked no longer', () async {
    answering('not-a-real-password');
    container.read(tmuxPendingConnectionProvider.notifier).state = 'h-web';
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await failed(id);
    expect(container.read(tmuxPendingConnectionProvider), isNull);
  });

  test('another host whose connection fails leaves the request for this one', () async {
    answering('not-a-real-password');
    container.read(sftpPendingConnectionProvider.notifier).state = 'h-web';
    final id = sessions().startSession((await tree.connectionsDao.getById('h-db'))!)!;
    await failed(id);
    expect(container.read(sftpPendingConnectionProvider), 'h-web');
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
