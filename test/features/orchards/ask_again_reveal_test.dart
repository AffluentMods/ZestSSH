import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/orchard_db_fixture.dart';

/// A Crate that asks again (3.0): its keys' secrets are not read
/// until the person confirms it is them (the device's PIN or a fingerprint,
/// or the app's PIN on a device without either); declined, they stay unread;
/// a device with no way to ask says so and shows nothing.

const _orchard = kFixtureOrchardId;
const _askCrate = '77777777-7777-4777-8777-777777777777';

class _CountingCrud extends IdentityCrudNotifier {
  _CountingCrud(AppDatabase db)
      : super(db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);

  final reads = <String>[];

  @override
  Future<String?> getPassword(String id) {
    reads.add('password:$id');
    return super.getPassword(id);
  }

  @override
  Future<String?> getPrivateKey(String id) {
    reads.add('privateKey:$id');
    return super.getPrivateKey(id);
  }
}

/// The device's own check: whether it has one, and what the person answers.
class _FakeAuth extends Fake implements LocalAuthentication {
  _FakeAuth({this.supported = true});

  final bool supported;
  bool answer = false;
  var asked = 0;
  AuthenticationOptions? options;

  @override
  Future<bool> isDeviceSupported() async => supported;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #authenticate) {
      asked++;
      options = invocation.namedArguments[#options] as AuthenticationOptions?;
      return Future<bool>.value(answer);
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late _CountingCrud crud;
  late OrchardSummary summary;
  late String key;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
        await seedOrchardAsOwner(db);
        await db.customStatement(
            'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation, confirm_reveal) '
            "VALUES (?, 'Prod', 'use', ?, 1, 1)",
            [_askCrate, jsonEncode(switchList(levelSwitches(CrateLevel.use)))]);
        crud = _CountingCrud(db);
        key = await crud.create(label: 'prod', username: 'deploy', authMethod: 'password', password: 'hunter2-prod');
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        await db.customStatement(
            "INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('key', ?, ?, 1)",
            [key, _askCrate]);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
        summary = await readOrchardSummary(db, _orchard);
        crud.reads.clear();
      });

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, _FakeAuth auth) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(_orchard)),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        itemCratesProvider('key').overrideWith((ref) => Stream.value({key: _askCrate})),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        localAuthProvider.overrideWithValue(auth),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Column(children: [
            Expanded(child: IdentityEditScreen(identityId: key, embedded: true, onClose: (_) {})),
            const Text('open'),
          ]),
        ),
      ),
    ));
    await frames(tester);
  }

  bool toasted(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.text('open')));
    // A long message is split into a title and the rest below it.
    return container
        .read(notificationCenterProvider)
        .history
        .any((n) => n.title == message || n.body == message || '${n.title} ${n.body}' == message);
  }

  testWidgets('its secrets are read only once the person confirms it is them', (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    final auth = _FakeAuth();
    await open(tester, auth);

    expect(summary.crates.firstWhere((c) => c.id == _askCrate).confirmReveal, isTrue);
    expect(crud.reads, isEmpty, reason: 'not read before the person confirms');
    expect(find.text(l10n.orchardRevealAskAgain), findsOneWidget);
    expect(find.textContaining('hunter2'), findsNothing);
    expect(find.byTooltip(l10n.save), findsNothing, reason: 'nothing to save over what is hidden');

    // Declined: still unread.
    await tester.tap(find.byKey(const ValueKey('secret-show')));
    await frames(tester);
    expect(auth.asked, 1);
    expect(auth.options?.biometricOnly, isFalse, reason: "the device's PIN counts too");
    expect(crud.reads, isEmpty);
    expect(toasted(tester, l10n.orchardRevealNotConfirmed), isTrue);

    // Confirmed: read and shown behind the usual eye toggle.
    auth.answer = true;
    await tester.tap(find.byKey(const ValueKey('secret-show')));
    await frames(tester);
    expect(crud.reads, contains('password:$key'));
    expect(find.byKey(const ValueKey('secret-hidden')), findsNothing);
    final field = tester.widget<EditableText>(find.byWidgetPredicate((w) => w is EditableText && w.obscureText));
    expect(field.controller.text, 'hunter2-prod');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a device with no screen lock and no app PIN cannot confirm, says so, and shows nothing',
      (tester) async {
    await build(tester);
    addTearDown(() => tester.runAsync(db.close));
    final auth = _FakeAuth(supported: false);
    await open(tester, auth);
    await tester.tap(find.byKey(const ValueKey('secret-show')));
    await frames(tester);
    expect(auth.asked, 0);
    expect(crud.reads, isEmpty);
    expect(toasted(tester, l10n.orchardRevealNoWay), isTrue);
    expect(find.byKey(const ValueKey('secret-hidden')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  test('the desktop key editor: shown once confirmed, and that is not a change to save', () async {
    final c = KeyEditController();
    addTearDown(c.dispose);
    final at = DateTime(2026, 9, 24);
    final identity = Identity(
      id: 'k',
      label: 'prod',
      username: 'deploy',
      authMethod: 'password',
      usesAgent: false,
      colorIndex: 0,
      isDefault: false,
      allowUnattended: false,
      passwordAfterKey: false,
      createdAt: at,
      updatedAt: at,
    );
    c.bind(identity, secretsHidden: true, askAgain: true);
    expect((c.secretsHidden, c.askAgain, c.isDirty), (true, true, false));
    c.showSecrets(password: 'hunter2-prod');
    expect((c.secretsHidden, c.askAgain, c.isDirty), (false, false, false));
    expect(c.passwordController.text, 'hunter2-prod');
    c.passwordController.text = 'changed';
    expect(c.isDirty, isTrue, reason: 'an edit after it still is');
  });
}
