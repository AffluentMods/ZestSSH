import 'dart:async';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
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
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A question of a sign-in that outlived what asked it (found in a final review).
/// A password prompt stayed on screen through a change of account (a browser
/// sign-in finishing, a session revoked): answered with Save it wrote the password into
/// the next account, which synced it, and the dial went on against that account's known
/// hosts. Now an answer that comes once the session was ended, or another database is
/// open, saves nothing and dials nothing, and a question waiting its turn is not asked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 10, 31);

  late AppDatabase tree;
  late ProviderContainer container;
  late ServerSocket door;
  late int dialled;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {'ask_before_trusting_keys': true});
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
    dialled = 0;
    door = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    door.listen((socket) {
      dialled++;
      socket.destroy();
    });
  });

  tearDown(() async {
    await door.close();
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);

  Future<PasswordPromptRequest> asked() async {
    final clock = Stopwatch()..start();
    while (container.read(passwordPromptProvider) == null) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for the question');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return container.read(passwordPromptProvider)!;
  }

  /// Long enough for a dial to reach the door, or the next question to be put.
  Future<void> settled() => Future<void>.delayed(const Duration(milliseconds: 400));

  Future<Connection> savedHost(String id, {String? keyId}) async {
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
        id: id, label: id, host: '127.0.0.1', port: Value(door.port), createdAt: at, updatedAt: at, identityId: Value(keyId)));
    return (await tree.connectionsDao.getById(id))!;
  }

  const answer = PasswordPromptResult(password: 'made-up-secret', saveToIdentity: true);

  test('an answer that was not outlived: the password is saved, and the dial goes on', () async {
    final id = sessions().startSession(await savedHost('h1'), usernameOverride: 'deploy')!;
    (await asked()).completer.complete(answer);
    await settled();
    expect(dialled, greaterThan(0));
    expect((await tree.identitiesDao.getAll()).single.authMethod, 'password');
    await sessions().endSession(id);
  });

  for (final (how, end) in <(String, Future<void> Function(String id))>[
    ('every session was ended (a change of account)', (_) => sessions().endAllSessions()),
    ('its session was ended', (id) => sessions().endSession(id)),
  ]) {
    test('answered with Save after $how: nothing is saved or dialled', () async {
      final id = sessions().startSession(await savedHost('h1'), usernameOverride: 'deploy')!;
      final request = await asked();
      await end(id);
      request.completer.complete(answer);
      await settled();
      expect(await tree.identitiesDao.getAll(), isEmpty);
      expect((await tree.connectionsDao.getById('h1'))!.identityId, isNull);
      expect(dialled, 0);
      expect(container.read(activeSessionsProvider)[id]?.status, anyOf(isNull, SessionStatus.disconnected));
    });
  }

  test('a key with no saved password: the password is not saved with it', () async {
    await tree.into(tree.identities).insert(
        IdentitiesCompanion.insert(id: 'k1', label: 'pw', username: 'u', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    sessions().startSession(await savedHost('h1', keyId: 'k1'));
    final request = await asked();
    await sessions().endAllSessions();
    request.completer.complete(answer);
    await settled();
    final secrets = SecureStorageIdentitySecrets(container.read(secureStorageProvider), sealedBy: tree);
    expect(await secrets.read('k1', IdentitySecret.password), isNull);
    expect(dialled, 0);
  });

  test('the next account open, with no session ended: nothing goes into its database', () async {
    final next = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(next.close);
    await next.into(next.connections).insert(ConnectionsCompanion.insert(
        id: 'h1', label: 'theirs', host: 'theirs.example.com', createdAt: at, updatedAt: at));
    sessions().startSession(await savedHost('h1'), usernameOverride: 'deploy');
    final request = await asked();
    await container.read(databaseSessionProvider.notifier).swap(next);
    request.completer.complete(answer);
    await settled();
    expect(await next.identitiesDao.getAll(), isEmpty);
    expect((await next.connectionsDao.getById('h1'))!.identityId, isNull);
    expect(dialled, 0);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
  });

  test('a question waiting its turn is not put to whoever is here by then', () async {
    sessions().startSession(await savedHost('h1'), usernameOverride: 'deploy');
    final first = await asked();
    sessions().startSession(await savedHost('h2'), usernameOverride: 'deploy');
    await settled();
    await sessions().endAllSessions();
    first.completer.complete(null);
    await settled();
    expect(container.read(passwordPromptProvider), isNull);
    expect(dialled, 0);
  });

  group('a host key answered after it', () {
    final key = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => i)));

    Future<int> pinned() async => (await tree.customSelect('SELECT 1 FROM known_hosts').get()).length;

    /// The verifier run, its question answered yes, [over] saying by then whether the try is over.
    Future<bool> trust({required bool over}) async {
      await savedHost('h1');
      final queue = container.read(hostKeyVerificationQueueProvider.notifier);
      var answered = false;
      final sub = container.listen<List<HostKeyVerification>>(hostKeyVerificationQueueProvider, (_, next) {
        for (final v in next) {
          answered = true;
          scheduleMicrotask(() => queue.resolve(v, true));
        }
      });
      addTearDown(sub.close);
      final verifier = sessions().debugHostKeyVerifier(
          connectionId: 'h1', dialedHost: 'h1.example.com', dialedPort: 22, ended: () => answered && over);
      return verifier('h1.example.com', 22, key);
    }

    test('is trusted while the try goes on', () async {
      expect(await trust(over: false), isTrue);
      expect(await pinned(), 1);
    });

    test('is trusted nowhere once it is over, and the dial stops', () async {
      await expectLater(trust(over: true), throwsA(isA<ConnectionCancelledException>()));
      expect(await pinned(), 0);
    });
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
