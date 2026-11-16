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
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_sign_in.dart';

/// "Test full connection" in the host editor, for a host whose key has a
/// password saved with it (3.0, accounts per host): a host that does not
/// take the key gets the password after it, as a connection does; a
/// password only left from before the identity became a key is never sent.
///
/// The editor dials for itself, so the host is played on the loopback
/// address.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  const saved = 'correct-horse-battery';
  final pem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();

  /// The editor of the saved host web-01 at [port] of the loopback address,
  /// signed in to with the key deploy-key, which has [saved] saved with it,
  /// tried after it where [afterKey].
  Future<void> openEditor(WidgetTester tester, int port, {required bool afterKey}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_id-deploy': pem,
      'identity_password_id-deploy': saved,
    });
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() async {
      final at = DateTime(2026, 10, 15);
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'id-deploy',
            label: 'deploy-key',
            username: 'deploy',
            authMethod: 'publicKey',
            passwordAfterKey: Value(afterKey),
            createdAt: at,
          ));
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h-web',
            label: 'web-01',
            host: InternetAddress.loopbackIPv4.address,
            port: Value(port),
            identityId: const Value('id-deploy'),
            createdAt: at,
            updatedAt: at,
          ));
    });
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ConnectionEditScreen(inDialog: true, onClose: () {}, connectionId: 'h-web')),
      ),
    ));
    await _settle(tester);
  }

  /// Presses "Test full connection" and waits for what the test says,
  /// trusting the host's key where it is asked about: whether it succeeded.
  Future<bool> fullTest(WidgetTester tester) async {
    await tester.tap(find.text(en.zestHostTestFull));
    bool said() =>
        find.text(en.connectionFailed).evaluate().isNotEmpty || find.text(en.connectionSuccessful).evaluate().isNotEmpty;
    for (var i = 0; i < 300 && !said(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 10));
      final trust = find.text(en.connectionEditTrustAndTest);
      if (trust.evaluate().isNotEmpty) {
        await tester.tap(trust);
        await tester.pump(const Duration(milliseconds: 400));
      }
    }
    expect(said(), isTrue, reason: 'the test has not said anything');
    return find.text(en.connectionSuccessful).evaluate().isNotEmpty;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  /// A host that takes keys and passwords and not the key, played on the
  /// loopback address until it lets the client in or [over] says the test
  /// is over; what it saw is in [signIn] once [played] is over.
  Future<({PlayedListener listener, PlayedSignIn signIn, Future<void> played})> playedHost(
      WidgetTester tester, {bool Function()? over}) async {
    late PlayedListener listener;
    late Future<void> played;
    final signIn = PlayedSignIn(ways: ['publickey', 'password'], password: saved);
    await tester.runAsync(() async {
      listener = await PlayedListener.bind();
      played = () async {
        final host = PlayedServer(line: await listener.line());
        await host.greet();
        await signIn.play(host, over: over);
      }()
          .then((_) {}, onError: (Object _) {});
    });
    return (listener: listener, signIn: signIn, played: played);
  }

  testWidgets('a host that does not take the key: the test signs in with the password saved with it, after the key',
      (tester) async {
    final host = await playedHost(tester);
    await openEditor(tester, host.listener.port, afterKey: true);
    expect(await fullTest(tester), isTrue);
    await tester.runAsync(() => host.played.timeout(const Duration(seconds: 15)));
    expect(host.signIn.seen, ['key?', 'password:$saved']);
    await finish(tester);
  });

  testWidgets('a password only left from before the identity became a key is never sent', (tester) async {
    var said = false;
    final host = await playedHost(tester, over: () => said);
    await openEditor(tester, host.listener.port, afterKey: false);
    expect(await fullTest(tester), isFalse);
    said = true;
    await tester.runAsync(() => host.played.timeout(const Duration(seconds: 15)).then((_) {}, onError: (Object _) {}));
    expect(host.signIn.seen, ['key?']);
    await finish(tester);
  });

  group('the rule a test goes by, in an Orchard', () {
    /// Whether the password goes, by what the screen says of the key and
    /// the address, and what was asked and read on the way.
    Future<(String?, List<String>)> goes({
      bool mayReveal = true,
      bool asksAgain = false,
      bool chosenHere = false,
      bool itIsThem = true,
    }) async {
      final steps = <String>[];
      final password = await testPasswordAfterKey(
        mayReveal: () async => mayReveal,
        asksAgain: () async => asksAgain,
        addressChosenHere: () async => chosenHere,
        itIsThem: () async {
          steps.add('asked whether it is them');
          return itIsThem;
        },
        read: () async {
          steps.add('read');
          return saved;
        },
      );
      return (password, steps);
    }

    /// What [outcome] came to: the password and the steps (each on a line of
    /// its own: a list in a record is never equal to another).
    Future<void> expectGoes(Future<(String?, List<String>)> outcome, String? password, List<String> steps,
        {String? reason}) async {
      final (got, took) = await outcome;
      expect(got, password, reason: reason);
      expect(took, steps, reason: reason);
    }

    test('one this account may see goes, and is read; one it may not see is not even read', () async {
      await expectGoes(goes(), saved, ['read']);
      await expectGoes(goes(mayReveal: false), null, []);
    });

    test('one from a Crate that asks again goes to an address chosen here once the person confirms it is them',
        () async {
      await expectGoes(goes(asksAgain: true, chosenHere: true), saved, ['asked whether it is them', 'read']);
      await expectGoes(goes(asksAgain: true, chosenHere: true, itIsThem: false), null, ['asked whether it is them']);
      await expectGoes(goes(asksAgain: true), saved, ['read'], reason: "the host's own address: not asked");
      await expectGoes(goes(chosenHere: true), saved, ['read'], reason: 'a Crate that does not ask again');
    });
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
