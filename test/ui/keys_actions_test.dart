import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zest_ssh_core/src/ssh_message.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/key_action_dialogs.dart';
import 'package:zestssh/features/keys/key_agent.dart';
import 'package:zestssh/features/keys/replace_key_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/hardware_token/os_ssh_agent.dart'
    show AgentPipeNotYours, AgentPipeServer, OsAgentException;
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';
import 'package:zestssh/utils/redactor.dart';

/// The four actions of a key's details on the Keys page (3.0):
/// its passphrase (shown from what the
/// device kept, never by reading the key; Check, Add one, Change, Remove,
/// the new one typed twice), Add to agent (a fake system agent here, which
/// reads the request as an agent does; never the agent of the computer the
/// test runs on), Export (OpenSSH files, a new passphrase typed twice), and
/// Replace on all hosts (its button and its dialog). And a key replaced in
/// the editor by one with no passphrase drops the passphrase the old one
/// kept (it made the key unreadable at every sign-in).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late SharedPreferences prefs;
  late _FakeAgent agent;
  late String plainPem;
  late String plainLine;
  late String plainFp;

  setUpAll(() async {
    final made = await KeyGenerationService().generateEd25519(comment: 'ops');
    plainPem = made.privatePem;
    plainLine = made.publicOpenSSH.trim();
    plainFp = made.fingerprint;
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    agent = _FakeAgent();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, bool Function() done, String what) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(done(), isTrue, reason: what);
  }

  /// One SSH key on three hosts, with [pem] and, where given, the
  /// passphrase kept with it.
  Future<String> seed(WidgetTester tester, {String? pem, String? kept}) async {
    late String id;
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      id = await crud.create(
        label: 'Ops laptop',
        username: 'ops',
        authMethod: 'publicKey',
        keyType: 'ed25519',
        publicKeyFingerprint: plainFp,
        publicKeyData: plainLine,
        privateKeyPem: pem ?? plainPem,
        keyPassphrase: kept,
      );
      final now = DateTime.now();
      for (var i = 0; i < 3; i++) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: 'h$i',
              label: 'web-0$i',
              host: '192.168.10.${21 + i}',
              identityId: Value(id),
              createdAt: now,
              updatedAt: now,
            ));
      }
    });
    return id;
  }

  Future<void> pump(WidgetTester tester, {Widget? child}) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        localStateStoreProvider.overrideWithValue(LocalStateStore(db)),
        systemAgentProvider.overrideWithValue(agent),
        syncIsActiveProvider.overrideWith((ref) async => true),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child ?? const KeysView()),
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

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Ops laptop'));
    await settle(tester);
  }

  String passphraseRow(WidgetTester tester) {
    final row = find.byKey(const ValueKey('keys-inspector-passphrase'));
    return tester.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).map((t) => t.data).join(' | ');
  }

  testWidgets('the passphrase: not known until checked, then None with Add one; added (typed twice), Set with Change and Remove',
      (tester) async {
    final id = await seed(tester);
    await pump(tester);
    await open(tester);
    expect(passphraseRow(tester), contains(l10n.keysActPassphraseUnknown));
    expect(passphraseRow(tester), contains(l10n.keysActPassphraseCheck));

    await tapKey(tester, 'keys-passphrase-check');
    expect(passphraseRow(tester), contains(l10n.keysActPassphraseNone));
    expect(find.byKey(const ValueKey('keys-passphrase-add')), findsOneWidget);

    await tapKey(tester, 'keys-passphrase-add');
    expect(find.text(l10n.keysPassAddTitle), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('keys-passphrase-new')), 'correct horse');
    await tester.enterText(find.byKey(const ValueKey('keys-passphrase-again')), 'correct hors');
    await tester.pump();
    expect(find.text(l10n.keysActMismatch), findsOneWidget);
    // Not the same: the main button is off.
    final save = find.byKey(const ValueKey('keys-passphrase-save'));
    await tester.tap(save, warnIfMissed: false);
    await settle(tester);
    expect(find.text(l10n.keysPassAddTitle), findsOneWidget, reason: 'nothing saved');
    await tester.enterText(find.byKey(const ValueKey('keys-passphrase-again')), 'correct horse');
    await tester.pump();
    expect(find.text(l10n.keysPassKeepOn), findsOneWidget, reason: 'kept with the key, as now');
    await tester.tap(save);
    await until(tester, () => find.text(l10n.keysPassAddTitle).evaluate().isEmpty, 'the dialog closed');
    await settle(tester);

    final stored = (await tester.runAsync<String?>(() => crud.getPrivateKey(id)))!;
    expect(OpenSSHKeyFile.isSealed(stored), isTrue);
    expect(SSHKeyPair.fromPem(stored, 'correct horse'), hasLength(1));
    expect(await tester.runAsync(() => crud.getKeyPassphrase(id)), 'correct horse');
    expect(passphraseRow(tester), contains(l10n.keysActPassphraseSet));
    expect(find.byKey(const ValueKey('keys-passphrase-change')), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-passphrase-remove')), findsOneWidget);

    // Remove: the key open again, nothing kept beside it.
    await tapKey(tester, 'keys-passphrase-remove');
    expect(find.text(l10n.keysPassRemoveBody), findsOneWidget);
    expect(find.byKey(const ValueKey('keys-passphrase-kept')), findsOneWidget, reason: 'the kept one opens it');
    await tester.tap(save);
    await until(tester, () => find.text(l10n.keysPassRemoveTitle).evaluate().isEmpty, 'the dialog closed');
    await settle(tester);
    expect(OpenSSHKeyFile.isSealed((await tester.runAsync<String?>(() => crud.getPrivateKey(id)))!), isFalse);
    expect(await tester.runAsync(() => crud.getKeyPassphrase(id)), isNull);
    expect(passphraseRow(tester), contains(l10n.keysActPassphraseNone));
    await finish(tester);
  });

  testWidgets('a sealed key whose passphrase is not kept: changing it asks for the current one, and a wrong one is said',
      (tester) async {
    final id = await seed(tester, pem: OpenSSHKeyFile.rewrite(plainPem, newPassphrase: 'old one'));
    await pump(tester);
    await open(tester);
    await tapKey(tester, 'keys-passphrase-check');
    expect(passphraseRow(tester), contains(l10n.keysActPassphraseSet));
    await tapKey(tester, 'keys-passphrase-change');
    expect(find.byKey(const ValueKey('keys-passphrase-current')), findsOneWidget);
    expect(find.text(l10n.keysPassKeepOff), findsOneWidget, reason: 'none was kept: none is, as now');
    await tester.enterText(find.byKey(const ValueKey('keys-passphrase-current')), 'not it');
    await tester.enterText(find.byKey(const ValueKey('keys-passphrase-new')), 'new one');
    await tester.enterText(find.byKey(const ValueKey('keys-passphrase-again')), 'new one');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('keys-passphrase-save')));
    await until(tester, () => find.text(l10n.keysActWrongPassphrase).evaluate().isNotEmpty, 'the wrong one said');
    expect(SSHKeyPair.fromPem((await tester.runAsync<String?>(() => crud.getPrivateKey(id)))!, 'old one'), hasLength(1),
        reason: 'nothing written');
    await tester.enterText(find.byKey(const ValueKey('keys-passphrase-current')), 'old one');
    await tester.tap(find.byKey(const ValueKey('keys-passphrase-save')));
    await until(tester, () => find.text(l10n.keysPassChangeTitle).evaluate().isEmpty, 'the dialog closed');
    expect(SSHKeyPair.fromPem((await tester.runAsync<String?>(() => crud.getPrivateKey(id)))!, 'new one'), hasLength(1));
    expect(await tester.runAsync(() => crud.getKeyPassphrase(id)), isNull);
    await finish(tester);
  });

  testWidgets('Add to agent: kept for 8 hours, the agent given the key; then SSH agent says Loaded, and In agent counts it',
      (tester) async {
    await seed(tester);
    await pump(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('keys-filter-inAgent')), matching: find.text('0')), findsOneWidget);
    await open(tester);
    expect(find.descendant(of: find.byKey(const ValueKey('keys-inspector-agent')), matching: find.text(l10n.keysActAgentNotLoaded)),
        findsOneWidget);
    await tapKey(tester, 'keys-add-to-agent');
    expect(find.text(l10n.keysAgentAddTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keys-agent-lifetime')));
    await settle(tester);
    await tester.tap(find.text(l10n.keysAgentEightHours).last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('keys-agent-add')));
    await until(tester, () => find.text(l10n.keysAgentAddTitle).evaluate().isEmpty, 'the dialog closed');
    await settle(tester);
    expect(agent.lifetimes, [8 * 3600]);
    expect(agent.comments, ['Ops laptop']);
    expect(agent.held, {plainFp});
    expect(find.descendant(of: find.byKey(const ValueKey('keys-inspector-agent')), matching: find.text(l10n.keysActAgentLoaded)),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('keys-filter-inAgent')), matching: find.text('1')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Add to agent: an agent that is not there, or says no to a time limit, is said with words', (tester) async {
    await seed(tester);
    agent.reachable = false;
    await pump(tester);
    await open(tester);
    await tapKey(tester, 'keys-add-to-agent');
    await tester.tap(find.byKey(const ValueKey('keys-agent-add')));
    await until(tester, () => find.text(l10n.keysAgentNoAgent).evaluate().isNotEmpty, 'no agent said');
    agent.reachable = true;
    agent.refusesLifetime = true;
    await tester.tap(find.byKey(const ValueKey('keys-agent-lifetime')));
    await settle(tester);
    await tester.tap(find.text(l10n.keysAgentOneHour).last);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('keys-agent-add')));
    await until(tester, () => find.byKey(const ValueKey('keys-agent-error')).evaluate().isNotEmpty &&
        find.textContaining('time limit').evaluate().isNotEmpty, 'the time limit refused');
    await finish(tester);
  });

  testWidgets("Add to agent: an agent's pipe that another account's program serves is said as that, with its code, "
      'and the key is not given', (tester) async {
    await seed(tester);
    agent.pipeNotYours = true;
    await pump(tester);
    await open(tester);
    await tapKey(tester, 'keys-add-to-agent');
    await tester.tap(find.byKey(const ValueKey('keys-agent-add')));
    final said = ErrorCodes.withCode(l10n.agentPipeNotYours, ErrorCodes.agentPipeNotYours);
    await until(tester, () => find.text(said).evaluate().isNotEmpty, 'the pipe of another account said');
    expect(said, endsWith('(ZS-1701)'));
    expect(find.text(l10n.keysAgentNoAgent), findsNothing, reason: 'not said as an agent that is not there');
    expect(agent.held, isEmpty);
    expect(find.text(l10n.keysAgentAddTitle), findsOneWidget, reason: 'the dialog stays, with the message');
    await finish(tester);
  });

  testWidgets('a phone has no system agent: Add to agent is not offered', (tester) async {
    await seed(tester);
    await tester.pumpWidget(const SizedBox());
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        localStateStoreProvider.overrideWithValue(LocalStateStore(db)),
        systemAgentProvider.overrideWithValue(null),
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
    await open(tester);
    expect(find.byKey(const ValueKey('keys-add-to-agent')), findsNothing);
    expect(find.byKey(const ValueKey('keys-inspector-agent')), findsNothing);
    expect(find.byKey(const ValueKey('keys-export')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Export: with a new passphrase typed twice, the private file opens with it; the public file is its line',
      (tester) async {
    final id = await seed(tester);
    final identity = (await tester.runAsync(() => db.identitiesDao.getById(id)))!;
    final out = <String, List<int>>{};
    await pump(
      tester,
      child: KeyExportDialog(
        keyToExport: identity,
        onWrite: (files, {subject, written}) async {
          out.addAll(files);
          written?.call();
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('keys-export-protection')));
    await settle(tester);
    await tester.tap(find.text(l10n.keysExportNewPassphrase).last);
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('keys-export-passphrase-new')), 'for the file');
    await tester.enterText(find.byKey(const ValueKey('keys-export-passphrase-again')), 'for the fil');
    await tester.pump();
    expect(find.text(l10n.keysActMismatch), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keys-export-go')), warnIfMissed: false);
    await settle(tester);
    expect(out, isEmpty, reason: 'not the same twice: nothing written');
    await tester.enterText(find.byKey(const ValueKey('keys-export-passphrase-again')), 'for the file');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('keys-export-go')));
    await until(tester, () => out.isNotEmpty, 'the files written');
    final names = keyExportFileNames(identity);
    expect(out.keys, [names.private, names.public]);
    expect(names.private, 'Ops_laptop_ed25519');
    final private = utf8.decode(out[names.private]!);
    expect(OpenSSHKeyFile.isSealed(private), isTrue);
    final opened = SSHKeyPair.fromPem(private, 'for the file').single;
    expect('${opened.name} ${base64.encode(opened.toPublicKey().encode())}', plainLine.split(' ').take(2).join(' '));
    expect(utf8.decode(out[names.public]!), '$plainLine\n');
    await finish(tester);
  });

  testWidgets('Export: with no passphrase it warns; public only writes the public file alone', (tester) async {
    final id = await seed(tester, pem: OpenSSHKeyFile.rewrite(plainPem, newPassphrase: 'kept'), kept: 'kept');
    final identity = (await tester.runAsync(() => db.identitiesDao.getById(id)))!;
    final out = <String, List<int>>{};
    await pump(
      tester,
      child: KeyExportDialog(
        keyToExport: identity,
        onWrite: (files, {subject, written}) async => out.addAll(files),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('keys-export-protection')));
    await settle(tester);
    await tester.tap(find.text(l10n.keysExportNoPassphrase).last);
    await settle(tester);
    expect(find.byKey(const ValueKey('keys-export-open-warning')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keys-export-go')));
    await until(tester, () => out.isNotEmpty, 'the files written');
    final private = utf8.decode(out[keyExportFileNames(identity).private]!);
    expect(OpenSSHKeyFile.isSealed(private), isFalse, reason: 'opened with the kept passphrase, written open');
    await finish(tester);
  });

  testWidgets('Replace on all hosts: its button names the hosts; its dialog says the steps and lists them', (tester) async {
    await seed(tester);
    await pump(tester);
    await open(tester);
    expect(find.text(l10n.keysActReplaceOnHosts(3)), findsOneWidget);
    expect(l10n.keysActReplaceOnHosts(3), 'Replace on all 3 hosts…');
    expect(l10n.keysActReplaceOnHosts(1), 'Replace on its host…');
    await tapKey(tester, 'keys-replace-on-hosts');
    expect(find.byType(ReplaceKeyDialog), findsOneWidget);
    expect(find.text(l10n.keysReplaceStepProve), findsOneWidget);
    expect(find.text(l10n.keysReplaceStepMake('Ops laptop (new)')), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      expect(find.byKey(ValueKey('keys-replace-host-h$i')), findsOneWidget);
    }
    expect(find.text(l10n.keysReplaceStart(3)), findsOneWidget);
    await finish(tester);
  });

  test("a phone's key menu offers Export, the passphrase and Replace on all hosts for a key the vault holds, "
      'and no Add to agent (a phone has no system agent)', () {
    final phone = File('lib/ui/screens/home/home_screen.dart').readAsStringSync();
    expect(phone, contains('if (canAddToSystemAgent(identity)) ...['));
    for (final (key, call) in const [
      ('phone-key-export', 'showKeyExport(context, ref, identity)'),
      ('phone-key-passphrase', 'showKeyPassphrase(context, ref, identity, KeyPassphraseMode.add)'),
      ('phone-key-replace', 'showReplaceKey(context, identity)'),
    ]) {
      expect(phone, contains("ValueKey('$key')"));
      expect(phone, contains(call));
    }
    expect(phone, isNot(contains('showAddToAgent')));
  });

  testWidgets('a key replaced in the editor by one with no passphrase drops the passphrase the old one kept', (tester) async {
    final id = await seed(tester, pem: OpenSSHKeyFile.rewrite(plainPem, newPassphrase: 'old'), kept: 'old');
    // The key's setup (the editor's own dialog, drawn in the test's font of
    // square letters) runs wider than its row: that is the font, not what
    // this test is about.
    final reported = FlutterError.onError;
    FlutterError.onError = (details) {
      if ('${details.exception}'.contains('overflowed')) return;
      reported?.call(details);
    };
    addTearDown(() => FlutterError.onError = reported);
    await pump(tester);
    await open(tester);
    await tapKey(tester, 'keys-inspector-edit');
    await tester.ensureVisible(find.text(l10n.zestKeysReplaceKey));
    await tester.tap(find.text(l10n.zestKeysReplaceKey));
    await settle(tester);
    await tester.tap(find.text(l10n.identityGenerateKey));
    await until(tester, () => find.text(l10n.identityGenerateKey).evaluate().isEmpty, 'the new key made');
    await settle(tester);
    await tester.tap(find.text(l10n.save).last);
    await until(tester, () => true, 'saved');
    await settle(tester);
    final pem = (await tester.runAsync<String?>(() => crud.getPrivateKey(id)))!;
    expect(OpenSSHKeyFile.isSealed(pem), isFalse, reason: 'the new key, with no passphrase');
    expect(await tester.runAsync(() => crud.getKeyPassphrase(id)), isNull,
        reason: 'the old key\'s passphrase beside an open key made it unreadable at every sign-in');
    expect(SSHKeyPair.fromPem(pem), hasLength(1));
    await finish(tester);
  });
}

/// A system agent played here: it reads each request as an SSH agent does,
/// and holds the keys it is given.
class _FakeAgent implements SystemAgent {
  @override
  Future<void> remove(Set<String> fingerprints) async {}

  final held = <String>{};
  final lifetimes = <int?>[];
  final comments = <String>[];
  var reachable = true;
  var refusesLifetime = false;
  var pipeNotYours = false;

  @override
  Future<Set<String>> fingerprints() async => {...held};

  @override
  Future<void> add(Uint8List request) async {
    if (!reachable) throw const AgentAddFailed(AgentAddRefusal.noAgent);
    if (pipeNotYours) throw AgentAddFailed(AgentAddRefusal.pipeNotYours, AgentPipeNotYours(AgentPipeServer.otherAccount));
    final r = SSHMessageReader(request);
    final kind = r.readUint8();
    expect(kind, anyOf(SSHAgentProtocol.addIdentity, SSHAgentProtocol.addIdConstrained));
    final type = r.readUtf8();
    expect(type, 'ssh-ed25519');
    final public = r.readString();
    r.readString();
    comments.add(r.readUtf8());
    int? lifetime;
    if (kind == SSHAgentProtocol.addIdConstrained) {
      expect(r.readUint8(), SSHAgentProtocol.constrainLifetime);
      lifetime = r.readUint32();
      if (refusesLifetime) throw OsAgentException('The agent did not take the key (reply type 5)');
    }
    lifetimes.add(lifetime);
    final blob = (SSHMessageWriter()
          ..writeUtf8(type)
          ..writeString(public))
        .takeBytes();
    held.add(OpenSSHKeySerializer.fingerprintFromBlob(blob));
  }
}
