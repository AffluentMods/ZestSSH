import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/ssh_cert/ssh_cert_signer.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/l10n/time_text.dart';

/// What a session says of a sign-in it could not get ready, before any
/// connection is made (3.0, found while what is said of a sign-in that did
/// not happen was put right): a key that is not on this device, a passphrase
/// that did not open it, a certificate that ran out or is not here, and a
/// key in an SSH agent with nothing here to name it by.
///
/// Each was said, as the app's own words, in English in every language, and
/// in the words of the code: "Certificate identity ... has no cert blob in
/// secure storage. Re-import the cert or change authMethod to "publicKey"
/// if you want bare-key auth."
///
/// Nothing is connected to: the host is an address that is none, and every
/// one of these stops before a connection is made.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  // A key with a passphrase from the SSH package's fixtures.
  final locked = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/id_ed25519').readAsStringSync();
  final ranOutAt = DateTime.utc(2026, 10, 4, 14, 30);
  late String keyPem;
  late String ranOut;
  late AppDatabase tree;
  late ProviderContainer container;
  // The log of the connection that failed last.
  var log = <String>[];

  setUpAll(() async {
    await initializeDateFormatting();
    keyPem = (await KeyGenerationService().generateEd25519(comment: 'deploy')).privatePem;
    final authority = SSHKeyPair.fromPem((await KeyGenerationService().generateEd25519(comment: 'authority')).privatePem);
    // A certificate for that key which ran out on 4 October 2026.
    ranOut = base64.encode(SshCertSigner.issue(
      params: SshCertIssueParams(
        subjectPublicKeyBlob: SSHKeyPair.fromPem(keyPem).single.toPublicKey().encode(),
        subjectAlgorithm: SshCertAlgorithm.ed25519,
        serial: 1,
        type: SshCertType.user,
        keyId: 'deploy',
        principals: const ['deploy'],
        validAfter: DateTime.utc(2026, 9, 1),
        validBefore: ranOutAt,
      ),
      caKey: authority.single,
    ));
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_id-ran-out': keyPem,
      'identity_cert_id-ran-out': ranOut,
      'identity_key_id-no-cert': keyPem,
      'identity_key_id-locked': locked,
    });
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
    for (final (id, label, method, publicKey) in <(String, String, String, String?)>[
      ('id-no-key', 'backup key', 'publicKey', null),
      ('id-locked', 'laptop key', 'publicKey', null),
      ('id-ran-out', 'deploy key', 'certificate', null),
      ('id-no-cert', 'release key', 'certificate', null),
      ('id-agent-none', 'token key', 'hardwareToken', null),
      ('id-agent-short', 'token key', 'hardwareToken', 'ssh-ed25519'),
      ('id-agent-unread', 'token key', 'hardwareToken', 'ssh-ed25519 not*base64 deploy@example.com'),
    ]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: label,
            username: 'deploy',
            authMethod: method,
            publicKeyData: Value(publicKey),
            // An agent of this machine is never asked: the name of a pipe that is not there.
            agentSocketPath: Value(method == 'hardwareToken' ? r'\\.\pipe\zestssh-test-no-such-agent' : null),
            createdAt: at,
          ));
    }
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  /// What a session to the host web-01 says of how it failed, where its
  /// sign-in is [identity].
  Future<ConnectionError> saidWith(String identity) async {
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          // An address that is none: nothing is to be connected to.
          host: '192.0.2.10',
          port: const Value(22),
          identityId: Value(identity),
          createdAt: at,
          updatedAt: at,
        ));
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    final clock = Stopwatch()..start();
    while (stateOf(id)?.status != SessionStatus.error) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('it did not fail: ${stateOf(id)?.status}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final s = stateOf(id)!;
    log = List.of(s.connectionLog);
    expect(log.where((line) => line.startsWith('tcp_connect:')), isEmpty, reason: 'no connection was made');
    final shown = ConnectionError.translate(s.errorMessage!, host: s.host, port: s.port, username: s.username);
    expect(shown.type, ConnectionErrorType.saidByApp);
    await sessions().endSession(id);
    return shown;
  }

  test('a key whose private key is not on this device', () async {
    expect(
      (await saidWith('id-no-key')).description,
      'The private key of "backup key" is not on this device: it was removed, or its import did not finish. Open '
      'the key and import its private key again.',
    );
  });

  test('a passphrase that does not open the key, asked for and given wrong', () async {
    final asked = <String>[];
    container.listen(passphrasePromptProvider, (_, request) {
      if (request == null) return;
      asked.add('${request.username}@${request.host}');
      request.completer.complete(const PassphrasePromptResult(passphrase: 'not the passphrase'));
    });
    expect(
      (await saidWith('id-locked')).description,
      'The passphrase did not open the private key of "laptop key". Connect again to enter it once more.',
    );
    expect(asked, ['deploy@192.0.2.10'], reason: 'asked once');
  });

  test('a certificate that ran out: when, in this device\'s time, and where a new one is added', () async {
    final when = DateFormat.yMMMd('en').add_jm().formatPlain(ranOutAt.toLocal());
    expect(
      (await saidWith('id-ran-out')).description,
      'The certificate of the key "deploy key" ran out on $when. Have a new one issued, then add it in the key\'s '
      "editor on a phone, or on a computer's Keys page with Import certificate or Generate certificate.",
    );
  });

  test('a key that signs in with a certificate, with none on this device: said as that, and the key not offered '
      'without it', () async {
    expect(
      (await saidWith('id-no-cert')).description,
      'The key "release key" signs in with a certificate, and this device has none for it. Add one in the key\'s '
      "editor on a phone, or on a computer's Keys page with Import certificate or Generate certificate; one added on "
      'another device comes here with its key once this device syncs. The key was not offered without its '
      'certificate.',
    );
  });

  test('a key in an SSH agent with no public key here to name it by, or one that cannot be read', () async {
    const sentence = 'The key "token key" is held by an SSH agent, and its public key, which names it to the agent, '
        'is missing here or cannot be read. Add the key again under Keys, with Connect via ssh-agent.';
    for (final identity in ['id-agent-none', 'id-agent-short', 'id-agent-unread']) {
      expect((await saidWith(identity)).description, sentence, reason: identity);
      // Which of the two it was is in the connection's log, on one line.
      final lines = log.where((line) => line.startsWith('identity: ERROR')).toList();
      expect(lines, hasLength(1), reason: identity);
      expect(
        lines.single,
        identity == 'id-agent-unread'
            ? startsWith('identity: ERROR - the public key on file for the agent key cannot be read - FormatException')
            : 'identity: ERROR - no public key on file for the agent key',
        reason: identity,
      );
      expect(lines.single, isNot(contains('\n')), reason: identity);
      await (tree.delete(tree.connections)..where((c) => c.id.equals('h-web'))).go();
    }
  });

  test('in the app\'s language, with the day as that language writes it', () async {
    final de = lookupAppLocalizations(const Locale('de'));
    L10nGlobal.update(de);
    addTearDown(() => L10nGlobal.update(en));
    expect((await saidWith('id-no-key')).description, de.connKeyNotOnDevice('backup key'));
    await (tree.delete(tree.connections)..where((c) => c.id.equals('h-web'))).go();
    final when = DateFormat.yMMMd('de').add_jm().formatPlain(ranOutAt.toLocal());
    expect(when, isNot(DateFormat.yMMMd('en').add_jm().formatPlain(ranOutAt.toLocal())));
    expect((await saidWith('id-ran-out')).description, de.connCertRanOut('deploy key', when));
  });

  test('while recording, the name of the key is masked', () async {
    Redactor.instance
      ..clearNames()
      ..enabled = true
      ..level = RedactLevel.layout
      ..registerNames(['backup key', 'release key']);
    addTearDown(() => Redactor.instance
      ..clearNames()
      ..enabled = false);
    for (final identity in ['id-no-key', 'id-no-cert']) {
      final sentence = (await saidWith(identity)).description;
      expect(sentence, isNot(contains('backup key')));
      expect(sentence, isNot(contains('release key')));
      expect(sentence, anyOf(startsWith('The private key of "'), startsWith('The key "')));
      await (tree.delete(tree.connections)..where((c) => c.id.equals('h-web'))).go();
    }
  });

  test('every language says them its own way, with the key\'s name, and the names the Keys page has', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final sentences = [
        l10n.connKeyNotOnDevice('deploy key'),
        l10n.connKeyPassphraseWrong('deploy key'),
        l10n.connCertRanOut('deploy key', '4 October'),
        l10n.connCertNotOnDevice('deploy key'),
        l10n.connAgentKeyNotOnFile('deploy key'),
      ];
      expect(sentences.toSet(), hasLength(5), reason: '$locale');
      for (final sentence in sentences) {
        expect(sentence, contains('deploy key'), reason: '$locale');
      }
      expect(l10n.connCertRanOut('deploy key', '4 October'), contains('4 October'), reason: '$locale');
      for (final ofACertificate in [l10n.connCertRanOut('deploy key', '4 October'), l10n.connCertNotOnDevice('deploy key')]) {
        expect(ofACertificate, contains(l10n.zestKeysImportCertificate), reason: '$locale');
        expect(ofACertificate, contains(l10n.zestKeysGenerateCertificate), reason: '$locale');
      }
      expect(l10n.connAgentKeyNotOnFile('deploy key'), contains(l10n.zestKeysConnectAgent), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      final english = [
        en.connKeyNotOnDevice('deploy key'),
        en.connKeyPassphraseWrong('deploy key'),
        en.connCertRanOut('deploy key', '4 October'),
        en.connCertNotOnDevice('deploy key'),
        en.connAgentKeyNotOnFile('deploy key'),
      ];
      for (var i = 0; i < sentences.length; i++) {
        expect(sentences[i], isNot(english[i]), reason: '$locale');
      }
    }
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
