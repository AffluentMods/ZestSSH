import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
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
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_detail_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_inspector_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/ui/widgets/app_lock_offer.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/utils/redactor.dart';
import '../a11y/a11y_checks.dart';

/// The Keys page on a computer as its design
/// draws it: one table under NAME, FINGERPRINT, USED BY, LAST USED and
/// ADDED, in the sections SSH keys, Saved passwords, SSH agent and
/// Certificates, each with its own actions on its line; the filters All,
/// Unused and In agent with their counts; and a picked row's details beside
/// the list, public facts only, its secrets read only behind Edit,
/// the editor kept as it was.

/// Counts every read of a secret.
class _CountingCrud extends IdentityCrudNotifier {
  _CountingCrud(super.dao, super.secrets, super.connections);

  int secretReads = 0;

  @override
  Future<String?> getPassword(String id) {
    secretReads++;
    return super.getPassword(id);
  }

  @override
  Future<String?> getPrivateKey(String id) {
    secretReads++;
    return super.getPrivateKey(id);
  }
}

const _fp = 'SHA256:Aq65otBkqZ3mV8xLr2Tn7wYc4HdP0sJfWRjtuK';
const _line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoOnlyKeyMaterialForTheTests ops@laptop';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late _CountingCrud crud;
  late SharedPreferences prefs;
  late List<String?> copied;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    copied = [];
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Two SSH keys (one on fifteen hosts, one on none), two saved passwords
  /// (one on none), two keys in the agent (one a security key).
  Future<void> seed(WidgetTester tester, {bool agentKeys = true}) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = _CountingCrud(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        final now = DateTime.now();
        final ops = await crud.create(
            label: 'Ops laptop',
            username: 'ops',
            authMethod: 'publicKey',
            keyType: 'ssh-ed25519',
            publicKeyFingerprint: _fp,
            publicKeyData: _line,
            privateKeyPem: 'demo-only, never read by the details');
        await crud.create(
            label: 'Spare key', username: 'ops', authMethod: 'publicKey', keyType: 'ssh-ed25519', publicKeyFingerprint: 'SHA256:short');
        final nodes = await crud.create(label: 'Cluster nodes', username: 'root', authMethod: 'password', password: 'demo-only');
        await crud.create(label: 'Old box', username: 'admin', authMethod: 'password', password: 'demo-only');
        for (final (label, type) in [if (agentKeys) ...const [('ops@mac-studio', 'ssh-ed25519'), ('yubikey', 'sk-ssh-ed25519@openssh.com')]]) {
          final id = await crud.create(label: label, username: 'ops', authMethod: 'hardwareToken', keyType: type);
          await db.identitiesDao.updateIdentity(IdentitiesCompanion(id: Value(id), usesAgent: const Value(true)));
        }
        for (var i = 0; i < 15; i++) {
          await db.into(db.connections).insert(ConnectionsCompanion.insert(
                id: 'h$i',
                label: 'web-${(i + 1).toString().padLeft(2, '0')}',
                host: '10.50.0.${21 + i}',
                identityId: Value(ops),
                lastConnected: Value(i == 0 ? now.subtract(const Duration(hours: 2)) : null),
                createdAt: now,
                updatedAt: now,
              ));
        }
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'n1', label: 'node-1', host: '10.50.5.11', identityId: Value(nodes), createdAt: now, updatedAt: now));
      });

  Future<void> pump(WidgetTester tester, {Size size = const Size(1500, 1000), bool lockOffer = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String?);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        appLockOfferEnabledProvider.overrideWithValue(lockOffer),
        syncIsActiveProvider.overrideWith((ref) async => true),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: KeysView()),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(db.close);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  test('a public key line for a narrow pane: its type, the start of its key and its comment', () {
    expect(shortPublicLine(_line), 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5… ops@laptop');
  });

  testWidgets('a fingerprint in a cell is whole where its column holds it, else cut in its middle, both ends kept',
      (tester) async {
    Iterable<String> cells() => find
        .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('keys-row-fingerprint-'))
        .evaluate()
        .map((e) => (e.widget as Text).data!);
    // Wide: whole (it was cut to "SHA256:Aq65otBkq…WRjtuK" with half the
    // row empty, as a design review found).
    await seed(tester);
    await pump(tester, size: const Size(2600, 1000));
    expect(cells(), containsAll([_fp, 'SHA256:short']));
    await finish(tester);
    // Narrow: as much of it as fits, from both ends.
    await seed(tester);
    await pump(tester, size: const Size(1100, 1000));
    final cut = cells().firstWhere((t) => t.startsWith('SHA256:Aq65'));
    expect(cut, contains('…'));
    expect(cut, endsWith('tuK'));
    expect(cut.length, lessThan(_fp.length));
    await finish(tester);
  });

  testWidgets('one table: the columns, the four sections in order with their own actions, each row as the design '
      'says it', (tester) async {
    await seed(tester);
    await pump(tester);
    for (final head in [l10n.keysUiColName, l10n.keysUiColFingerprint, l10n.keysUiColUsedBy, l10n.keysUiColLastUsed, l10n.keysUiColAdded]) {
      expect(find.text(head.toUpperCase()), findsOneWidget, reason: head);
    }
    final order = [
      for (final s in ['ssh', 'passwords', 'agent', 'certificates']) tester.getTopLeft(find.byKey(ValueKey('keys-section-$s'))).dy,
    ];
    expect(order, [...order]..sort(), reason: 'SSH keys, Saved passwords, SSH agent, Certificates');
    expect(find.text(l10n.keysUiSectionSavedPasswords.toUpperCase()), findsOneWidget);
    expect(find.text(l10n.keysUiSectionAgent.toUpperCase()), findsOneWidget);
    // Each section's own actions on its line; an empty section's line.
    expect(find.byKey(const ValueKey('pm-add-from')), findsOneWidget);
    expect(find.text(l10n.keysUiFromPasswordManager), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-agent-what')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-cert-generate')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-cert-import')), findsOneWidget);
    expect(find.text(l10n.keysUiEmptyCertificates), findsOneWidget);

    // The rows.
    expect(find.text('ED25519'), findsNWidgets(2), reason: "a key's algorithm as its tag");
    expect(find.textContaining(RegExp(r'^SHA256:Aq65.*tuK$')), findsOneWidget, reason: 'its fingerprint, both ends');
    expect(find.text(l10n.keysUiHosts(15)), findsOneWidget);
    expect(find.text(l10n.keysUiHosts(1)), findsOneWidget);
    expect(find.text(l10n.keysUiHosts(0)), findsNWidgets(4));
    expect(find.text(l10n.keysUiInYourVault), findsNWidgets(2), reason: 'a saved password has no fingerprint');
    expect(find.text(l10n.keysUiLivesInAgent), findsNWidgets(2));
    expect(find.text(l10n.keysUiTagAgent.toUpperCase()), findsOneWidget);
    expect(find.text(l10n.keysUiTagHardware.toUpperCase()), findsOneWidget, reason: 'a security key (sk-)');
    expect(find.text('root'), findsOneWidget, reason: "a password's user beside its name");

    // What is this? says what the agent is.
    await tapKey(tester, 'keys-agent-what');
    expect(find.text(l10n.zestKeysAgentHelp), findsOneWidget);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    await finish(tester);
  });

  testWidgets('a large tablet has no SSH agent (4.0): New offers no Connect via ssh-agent, and '
      'the SSH agent section shows only where keys of an agent came from another device, with no way to connect one',
      (tester) async {
    debugTouchLayout = true;
    addTearDown(() => debugTouchLayout = null);
    // Two keys of a computer's agent, here by sync: they stay listed.
    await seed(tester);
    await pump(tester);
    expect(find.byKey(const ValueKey('keys-section-agent')), findsOneWidget);
    expect(find.text('yubikey'), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-agent-what')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('keys-new-identity')));
    await settle(tester);
    expect(find.text(l10n.zestKeysNewPassword), findsOneWidget);
    expect(find.text(l10n.zestKeysConnectAgent), findsNothing);
    expect(find.text(l10n.zestKeysImportCertificate), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);
    await finish(tester);
    // None: no section at all.
    await seed(tester, agentKeys: false);
    await pump(tester);
    expect(find.byKey(const ValueKey('keys-section-ssh')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-section-agent')), findsNothing);
    expect(find.text(l10n.keysUiSectionAgent.toUpperCase()), findsNothing);
    expect(find.byKey(const ValueKey('keys-section-certificates')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the filters: All, Unused and In agent with their counts, each narrowing the table', (tester) async {
    await seed(tester);
    await pump(tester);
    Finder segment(String name) => find.byKey(ValueKey('keys-filter-$name'));
    expect(find.descendant(of: segment('all'), matching: find.text('6')), findsOneWidget);
    expect(find.descendant(of: segment('unused'), matching: find.text('4')), findsOneWidget);
    expect(find.descendant(of: segment('inAgent'), matching: find.text('2')), findsOneWidget);
    expect(find.text(l10n.keysUiFilterInAgent), findsOneWidget);

    await tester.tap(segment('inAgent'));
    await settle(tester);
    expect(find.text('yubikey'), findsOneWidget);
    expect(find.text('Ops laptop'), findsNothing);
    expect(find.byKey(const ValueKey('keys-section-ssh')), findsNothing, reason: 'an empty section is left out');

    await tester.tap(segment('unused'));
    await settle(tester);
    expect(find.text('Spare key'), findsOneWidget);
    expect(find.text('Old box'), findsOneWidget);
    expect(find.text('Ops laptop'), findsNothing);
    expect(find.text('Cluster nodes'), findsNothing);

    await tester.tap(segment('unused'));
    await settle(tester);
    expect(find.text('Ops laptop'), findsOneWidget, reason: 'tapped again, all');

    // The filter box.
    await tester.enterText(find.byType(TextField).first, 'cluster');
    await settle(tester);
    expect(find.text('Cluster nodes'), findsOneWidget);
    expect(find.text('Ops laptop'), findsNothing);
    await finish(tester);
  });

  testWidgets("a picked key's details: public facts only, no secret read; Edit opens the editor, which reads them; "
      'closed, back to the details, then to the whole list', (tester) async {
    await seed(tester);
    await pump(tester);
    expect(find.byType(KeysInspectorPane), findsNothing, reason: 'nothing picked: the list has the width');
    expect(find.byType(KeysDetailPane), findsNothing);

    await tester.tap(find.text('Ops laptop'));
    await settle(tester);
    expect(find.byType(KeysInspectorPane), findsOneWidget);
    expect(crud.secretReads, 0, reason: 'nothing secret is read to show the details');
    expect(find.byKey(const ValueKey('keys-inspector-subtitle')), findsOneWidget);
    expect(find.descendant(of: find.byType(KeysInspectorPane), matching: find.text(_fp)), findsOneWidget,
        reason: 'the whole fingerprint');
    expect(find.text(shortPublicLine(_line)), findsOneWidget);
    expect(find.descendant(of: find.byType(KeysInspectorPane), matching: find.text(l10n.keysUiInYourVault)),
        findsOneWidget);
    expect(find.text(l10n.keysUiSyncOn), findsOneWidget);
    expect(find.text(l10n.keysUiNotAllowed), findsOneWidget, reason: 'unattended runs off');
    expect(find.byKey(const ValueKey('keys-install-on-hosts')), findsOneWidget);

    // USED BY: the first six, then all fifteen.
    expect(find.byKey(const ValueKey('keys-inspector-host-h0')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-inspector-host-h14')), findsNothing);
    await tapKey(tester, 'keys-inspector-show-all');
    expect(find.byKey(const ValueKey('keys-inspector-host-h14')), findsOneWidget);
    expect(find.text('ops@10.50.0.21'), findsOneWidget);

    // Copy public key, and the fingerprint's own copy.
    await tapKey(tester, 'keys-copy-public');
    expect(copied.last, _line);
    await tester.ensureVisible(find.byKey(const ValueKey('keys-inspector-fingerprint')));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('keys-inspector-fingerprint')), matching: find.byType(IconButton)));
    await settle(tester);
    expect(copied.last, _fp);
    expect(crud.secretReads, 0);

    await tapKey(tester, 'keys-inspector-edit');
    expect(find.byType(KeysDetailPane), findsOneWidget, reason: 'the editor, kept as it was');
    expect(find.byType(KeysInspectorPane), findsNothing);
    expect(crud.secretReads, greaterThan(0), reason: 'the editor loads the private key');

    // Its close: back to the details, the draft and its secrets let go.
    await tester.tap(find.byTooltip(l10n.close).first);
    await settle(tester);
    expect(find.byType(KeysInspectorPane), findsOneWidget);

    await tapKey(tester, 'keys-inspector-close');
    expect(find.byType(KeysInspectorPane), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await finish(tester);
  });

  testWidgets("a saved password's details: where it is kept, no install, Move to a password manager; the more menu",
      (tester) async {
    await seed(tester);
    await pump(tester);
    await tester.tap(find.text('Cluster nodes'));
    await settle(tester);
    expect(find.descendant(of: find.byType(KeysInspectorPane), matching: find.text(l10n.keysUiInYourVault)),
        findsOneWidget);
    expect(find.byKey(const ValueKey('keys-install-on-hosts')), findsNothing);
    expect(find.byKey(const ValueKey('keys-copy-public')), findsNothing);
    expect(find.byKey(const ValueKey('pm-move')), findsOneWidget, reason: 'your own password, on a computer');
    expect(find.text('root@10.50.5.11'), findsOneWidget);

    await tapKey(tester, 'keys-inspector-more');
    expect(find.byKey(const ValueKey('keys-inspector-duplicate')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-inspector-delete')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-inspector-replace')), findsNothing, reason: 'a password has no key to replace');
    await tester.tapAt(const Offset(5, 5));
    await settle(tester);

    // An agent's key lives in the agent.
    await tester.tap(find.text('yubikey'));
    await settle(tester);
    expect(find.descendant(of: find.byType(KeysInspectorPane), matching: find.text(l10n.keysUiLivesInAgent)),
        findsOneWidget);
    expect(find.text(l10n.keysUiSystemAgent), findsOneWidget);
    expect(crud.secretReads, 0);
    await finish(tester);
  });

  testWidgets('New identity: a new key is composed in the editor; closed unsaved, nothing is open', (tester) async {
    await seed(tester);
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('keys-new-identity')));
    await settle(tester);
    expect(find.text(l10n.zestKeysNewPassword), findsOneWidget);
    expect(find.text(l10n.keysListGenerateSshKeyEd25519), findsOneWidget);
    expect(find.text(l10n.zestKeysConnectAgent), findsOneWidget);
    expect(find.text(l10n.zestKeysImportCertificate), findsOneWidget);
    await tester.tap(find.text(l10n.zestKeysNewPassword));
    await settle(tester);
    expect(find.byType(KeysDetailPane), findsOneWidget);
    // The list's "New key" button says the same words, so the editor's title
    // is looked for inside the editor.
    expect(find.descendant(of: find.byType(KeysDetailPane), matching: find.text(l10n.zestKeysNewIdentityTitle)),
        findsOneWidget);
    await tester.tap(find.byTooltip(l10n.close).first);
    await settle(tester);
    expect(find.byType(KeysDetailPane), findsNothing);
    expect(find.byType(KeysInspectorPane), findsNothing);
    await finish(tester);
  });

  // 4.0, platform parity gap 10: the computer's Keys page offers the app lock
  // after the first password or private key saved, once, as a phone's key
  // editor does.
  testWidgets('a first saved password offers the app lock, once; Not now is the answer for good', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await seed(tester);
      await pump(tester, lockOffer: true);
      Future<void> newPassword(String name) async {
        await tester.tap(find.byKey(const ValueKey('keys-new-identity')));
        await settle(tester);
        await tester.tap(find.text(l10n.zestKeysNewPassword));
        await settle(tester);
        final fields = find.descendant(of: find.byType(KeysDetailPane), matching: find.byType(TextField));
        await tester.enterText(fields.at(0), name);
        await tester.enterText(fields.at(1), 'deploy');
        await tester.enterText(fields.at(2), 'demo-only');
        await settle(tester);
        await tester.tap(find.text(l10n.save).last);
        await settle(tester);
      }

      await newPassword('Build box');
      expect(find.text(l10n.appLockOfferTitleComputer), findsOneWidget);
      expect(find.text(l10n.appLockOfferBodyComputer('Windows Hello')), findsOneWidget);
      await tester.tap(find.text(l10n.notNow));
      await settle(tester);
      expect(find.text(l10n.appLockOfferTitleComputer), findsNothing);
      expect(prefs.getBool('app_lock_offered'), isTrue);
      expect((await tester.runAsync(() => db.identitiesDao.getAll()))!.map((i) => i.label), contains('Build box'));

      await newPassword('Second box');
      expect(find.text(l10n.appLockOfferTitleComputer), findsNothing);
      await finish(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // The 4.0 accessibility pass: the Keys page, its list and
  // a picked key's details, holds to the checks every screen of the pass
  // does: names, 32 square targets, readable words.
  testWidgets("the Keys page and a key's details: names, targets, contrast (the 4.0 accessibility pass)", (tester) async {
    final handle = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await seed(tester);
      await pump(tester);
      final failures = await a11yCheck(tester, computer: true, where: 'Keys');
      final row = find.text('Ops laptop').first;
      await tester.tap(row);
      await settle(tester);
      failures.addAll(await a11yCheck(tester, computer: true, where: 'Keys, a key picked'));
      expect(failures, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    }
    await finish(tester);
  });
}
