import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';

/// "Save to identity" on the question for a password (3.0, found while
/// checking a list of suspected faults in signing in). For a host that is
/// not saved (a computer's Quick connect) it made a key with the password,
/// and then linked it to a host that is not there: a key linked to nothing,
/// a new one each time. Now such a host is not offered it, and nothing is
/// saved for one; a saved host with no key is, as before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  group('the sign-in', () {
    late AppDatabase tree;
    late ProviderContainer container;
    late int nowhere;

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
      // A port where nothing answers: the session fails once it has its password.
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      nowhere = socket.port;
      await socket.close();
    });

    tearDown(() async {
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

    Future<void> gone(String id) async {
      final clock = Stopwatch()..start();
      while (true) {
        final s = container.read(activeSessionsProvider)[id];
        if (s == null || s.status == SessionStatus.error || s.status == SessionStatus.disconnected) return;
        if (clock.elapsed > const Duration(seconds: 30)) fail('waited for the session to fail');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('a host that is not saved: not offered, and nothing is saved even where it is asked to be', () async {
      final target = parseQuickTarget('deploy@127.0.0.1:$nowhere')!;
      final id = sessions().startSession(quickConnectionOf(target), usernameOverride: target.user)!;
      final request = await asked();
      expect(request.offerSave, isFalse);
      request.completer.complete(const PasswordPromptResult(password: 'made-up-secret', saveToIdentity: true));
      await gone(id);
      expect(await tree.identitiesDao.getAll(), isEmpty, reason: 'no key linked to nothing');
    });

    test('a saved host with no key: offered, and the password is kept with a key of the host', () async {
      final at = DateTime(2026, 10, 16);
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-bare', label: 'bare', host: '127.0.0.1', port: Value(nowhere), createdAt: at, updatedAt: at));
      final id = sessions().startSession((await tree.connectionsDao.getById('h-bare'))!, usernameOverride: 'deploy')!;
      final request = await asked();
      expect(request.offerSave, isTrue);
      request.completer.complete(const PasswordPromptResult(password: 'made-up-secret', saveToIdentity: true));
      await gone(id);
      final key = (await tree.identitiesDao.getAll()).single;
      expect((key.username, key.authMethod), ('deploy', 'password'));
      expect((await tree.connectionsDao.getById('h-bare'))!.identityId, key.id);
    });
  });

  group('the question', () {
    Future<void> open(WidgetTester tester, PasswordPromptRequest request) async {
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          theme: AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: PasswordPromptDialog(request: request)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    PasswordPromptRequest asked({required bool offerSave}) => PasswordPromptRequest(
          host: '203.0.113.10',
          username: 'deploy',
          completer: Completer<PasswordPromptResult?>(),
          offerSave: offerSave,
        );

    testWidgets('offers "Save" only where the password may be kept', (tester) async {
      await open(tester, asked(offerSave: false));
      expect(find.text(en.passwordPromptSaveToIdentity), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      await open(tester, asked(offerSave: true));
      expect(find.text(en.passwordPromptSaveToIdentity), findsOneWidget);
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
