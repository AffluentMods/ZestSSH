import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
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

/// A saved sign-in that cannot be made ready is said as that, and no
/// password is asked for in its place (3.0; the SSH core's audit, found
/// while the way a sign-in is loaded was read).
///
/// A key whose file is damaged or of a kind the app does not know, a
/// certificate that was made for another key or cannot be read, and a key
/// that this device's secure storage did not hand over all ended the same
/// way: the app asked for a password, with no word of why. For a key that
/// signs in with a certificate, a password typed there signed in without
/// the certificate, which the app says elsewhere it never does. And the
/// connection's log, and the lines the app keeps for an error's details,
/// carried what the failure printed: for a key file that is damaged, a
/// piece of the file.
///
/// Nothing is connected to: the host is an address that is none, and every
/// one of these stops before a connection is begun, but for a password
/// that its person types.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  // What stands in a damaged key file where its key was: no secret, and told apart from everything else here.
  final fileText = base64.encode(utf8.encode('what-stood-in-the-key-file-' * 4));
  late String keyPem;
  late String forOtherKey;
  late AppDatabase tree;
  late ProviderContainer container;
  late _Storage storage;
  // What the app noted in its own log meanwhile: each line with what was caught beside it, as a line is kept for
  // an error's details.
  late List<String> noted;

  String certificateFor(String pem, SSHKeyPair authority) => base64.encode(SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: SSHKeyPair.fromPem(pem).single.toPublicKey().encode(),
          subjectAlgorithm: SshCertAlgorithm.ed25519,
          serial: 1,
          type: SshCertType.user,
          keyId: 'deploy',
          principals: const ['deploy'],
          validAfter: DateTime.utc(2026, 9, 1),
          validBefore: DateTime.utc(2036, 9, 1),
        ),
        caKey: authority,
      ));

  setUpAll(() async {
    final keys = KeyGenerationService();
    keyPem = (await keys.generateEd25519(comment: 'deploy')).privatePem;
    final otherPem = (await keys.generateEd25519(comment: 'other')).privatePem;
    final authority = SSHKeyPair.fromPem((await keys.generateEd25519(comment: 'authority')).privatePem);
    forOtherKey = certificateFor(otherPem, authority.single);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    noted = [];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final noting = Logger.root.onRecord.listen((record) => noted.add('${record.message} (${record.error})'));
    addTearDown(() {
      Logger.root.level = level;
      return noting.cancel();
    });
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _Storage({
      // A key file with what is no base64 where its key was.
      'identity_key_id-damaged':
          '-----BEGIN OPENSSH PRIVATE KEY-----\nNOT*BASE64*$fileText\n-----END OPENSSH PRIVATE KEY-----\n',
      'identity_key_id-no-pem': 'this is no key',
      'identity_key_id-unknown-kind': '-----BEGIN SOMETHING ELSE-----\n$fileText\n-----END SOMETHING ELSE-----\n',
      'identity_key_id-no-key-inside': '-----BEGIN RSA PRIVATE KEY-----\n$fileText\n-----END RSA PRIVATE KEY-----\n',
      'identity_key_id-cert-other': keyPem,
      'identity_cert_id-cert-other': forOtherKey,
      'identity_key_id-cert-damaged': keyPem,
      'identity_cert_id-cert-damaged': 'not*base64',
      'identity_key_id-key-unread': keyPem,
      'identity_password_id-pass-unread': 'not-a-real-password',
    });
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      secureStorageProvider.overrideWithValue(storage),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = false;
    final at = DateTime(2026, 10, 1);
    for (final (id, label, method) in <(String, String, String)>[
      ('id-damaged', 'laptop key', 'publicKey'),
      ('id-no-pem', 'laptop key', 'publicKey'),
      ('id-unknown-kind', 'laptop key', 'publicKey'),
      ('id-no-key-inside', 'laptop key', 'publicKey'),
      ('id-cert-other', 'deploy key', 'certificate'),
      ('id-cert-damaged', 'deploy key', 'certificate'),
      ('id-key-unread', 'backup key', 'publicKey'),
      ('id-pass-unread', 'web password', 'password'),
    ]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: label,
            username: 'deploy',
            authMethod: method,
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

  /// Whether a connection to the host was begun.
  bool wentOn(List<String> log) => log.any((line) => line.startsWith('Resolving '));

  /// How a session to the host web-01 ended whose sign-in is [identity]:
  /// what it said where it failed, what its person was asked where a
  /// password was asked for (they close the question, unless [typed] is
  /// what they type), and the log of the connection.
  Future<({ConnectionError? said, PasswordPromptRequest? asked, List<String> log})> ended(
    String identity, {
    String? typed,
  }) async {
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
    PasswordPromptRequest? asked;
    final asking = container.listen(passwordPromptProvider, (_, request) {
      if (request == null || asked != null) return;
      asked = request;
      request.completer.complete(typed == null ? null : PasswordPromptResult(password: typed));
    });
    // The log of the session as it grows: a session that is given up goes with its log.
    var log = <String>[];
    final host = (await tree.connectionsDao.getById('h-web'))!;
    final id = sessions().startSession(host)!;
    void keep(Map<String, SessionState> states) {
      final lines = states[id]?.connectionLog;
      if (lines != null && lines.length >= log.length) log = List.of(lines);
    }

    final logging = container.listen(activeSessionsProvider, (_, states) => keep(states));
    keep(container.read(activeSessionsProvider));
    final clock = Stopwatch()..start();
    // It fails, it is given up (its person closed a question), or it goes on to connect.
    while (true) {
      final s = stateOf(id);
      if (s == null || s.status == SessionStatus.error || wentOn(log)) break;
      if (clock.elapsed > const Duration(seconds: 20)) {
        fail('it neither failed nor went on: ${s.status}\n${log.join('\n')}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final s = stateOf(id);
    final said = s == null || s.status != SessionStatus.error
        ? null
        : ConnectionError.translate(s.errorMessage!, host: s.host, port: s.port, username: s.username);
    await sessions().endSession(id);
    asking.close();
    logging.close();
    await (tree.delete(tree.connections)..where((c) => c.id.equals('h-web'))).go();
    return (said: said, asked: asked, log: log);
  }

  const unreadable = 'The private key of "laptop key" on this device cannot be read: the file is damaged, or it is of '
      'a kind ZestSSH does not know. Open the key and import its private key again. Nothing was sent to the host.';

  test('a key whose file is damaged: said as that, with no password asked for and nothing connected to', () async {
    final it = await ended('id-damaged');
    expect(it.asked, isNull, reason: 'a password was asked for in place of the key');
    expect(it.said?.type, ConnectionErrorType.saidByApp);
    expect(it.said?.description, unreadable);
    expect(wentOn(it.log), isFalse);
  });

  test('nothing of the key file is in the connection\'s log or in what the app notes: what kind of failure it was '
      'is', () async {
    final it = await ended('id-damaged');
    expect(it.log, isNotEmpty);
    expect(noted, isNotEmpty);
    final kept = [...it.log, ...noted].join('\n');
    expect(kept, isNot(contains(fileText.substring(0, 16))), reason: 'a piece of the key file');
    expect(kept, isNot(contains('NOT*BASE64*')), reason: 'a piece of the key file');
    expect(it.log.where((line) => line.startsWith('identity: ERROR')),
        ['identity: ERROR - the private key cannot be read (FormatException)']);
    expect(noted, contains('The private key of a sign-in could not be read: FormatException (null)'));
  });

  test('so is a key file that is no key in any other way, each with its kind in the log', () async {
    for (final (identity, kind) in [
      ('id-no-pem', 'FormatException'),
      ('id-unknown-kind', 'UnsupportedError'),
      ('id-no-key-inside', 'SSHKeyDecodeError'),
    ]) {
      final it = await ended(identity);
      expect(it.asked, isNull, reason: identity);
      expect(it.said?.description, unreadable, reason: identity);
      expect(it.log.where((line) => line.startsWith('identity: ERROR')),
          ['identity: ERROR - the private key cannot be read ($kind)'],
          reason: identity);
      expect([...it.log, ...noted].join('\n'), isNot(contains(fileText.substring(0, 16))), reason: identity);
    }
  });

  test('a certificate that was made for another key, and one that cannot be read: said as that, the key not '
      'offered without it and no password asked for', () async {
    const unusable = 'The certificate of the key "deploy key" cannot be used: it was made for another key, or it is '
        "damaged. Add the right one in the key's editor on a phone, or on a computer's Keys page with Import "
        'certificate or Generate certificate. The key was not offered without its certificate.';
    for (final (identity, kind) in [('id-cert-other', 'ArgumentError'), ('id-cert-damaged', 'FormatException')]) {
      final it = await ended(identity);
      expect(it.asked, isNull, reason: '$identity: a password was asked for in place of the certificate');
      expect(it.said?.description, unusable, reason: identity);
      expect(it.log.where((line) => line.startsWith('identity: ERROR')),
          ['identity: ERROR - the certificate cannot be used with this key ($kind)'],
          reason: identity);
      expect(wentOn(it.log), isFalse, reason: identity);
    }
  });

  test('a key that this device\'s secure storage does not hand over: said as that, with no password asked for',
      () async {
    storage.failing.add('identity_key_id-key-unread');
    final it = await ended('id-key-unread');
    expect(it.asked, isNull, reason: 'a password was asked for in place of the key');
    expect(
      it.said?.description,
      'ZestSSH could not get "backup key" ready to sign in: reading it on this device failed. Connect again; if it '
      'keeps happening, restart ZestSSH. Nothing was sent to the host.',
    );
    // What the system's storage said is in the log: nothing was read there, and it tells one such failure
    // from another.
    const storageSaid = 'PlatformException: Exception encountered: read failed for identity_key_id-key-unread';
    expect(it.log.where((line) => line.startsWith('identity: ERROR')),
        ['identity: ERROR reading credentials ($storageSaid)']);
    expect(noted, contains('A saved sign-in could not be read ($storageSaid)'));
    expect(wentOn(it.log), isFalse);

    // So is a certificate that the storage does not hand over: that is no certificate that cannot be used.
    storage.failing.add('identity_cert_id-cert-other');
    final cert = await ended('id-cert-other');
    expect(cert.asked, isNull);
    expect(cert.said?.description, startsWith('ZestSSH could not get "deploy key" ready to sign in: '));
    expect(cert.log.where((line) => line.startsWith('identity: ERROR')), [
      'identity: ERROR reading credentials (PlatformException: Exception encountered: read failed for '
          'identity_cert_id-cert-other)',
    ]);
  });

  test('a saved password that cannot be read is asked for, with why; closed, nothing is connected to', () async {
    storage.failing.add('identity_password_id-pass-unread');
    final it = await ended('id-pass-unread');
    expect(it.asked, isNotNull);
    expect(it.asked!.errorHint, 'The saved password could not be read on this device, so it is asked for here.');
    expect((it.asked!.username, it.asked!.host), ('deploy', '192.0.2.10'));
    expect(it.said, isNull, reason: 'its person closed the question: nothing failed');
    expect(wentOn(it.log), isFalse);
    // And the connection's log says why it asked.
    expect(it.log.where((line) => line.startsWith('identity: ')).skip(1), [
      'identity: ERROR reading credentials (PlatformException: Exception encountered: read failed for '
          'identity_password_id-pass-unread)',
      'identity: The saved password could not be read, asking for it...',
    ]);
  });

  test('and with the password typed there, the connection is gone on with', () async {
    storage.failing.add('identity_password_id-pass-unread');
    final it = await ended('id-pass-unread', typed: 'not-a-real-password');
    expect(it.asked, isNotNull);
    expect(wentOn(it.log), isTrue);
    expect([...it.log, ...noted].join('\n'), isNot(contains('not-a-real-password')));
  });

  test('a saved password that can be read is not asked for', () async {
    final it = await ended('id-pass-unread');
    expect(it.asked, isNull);
    expect(wentOn(it.log), isTrue);
  });

  test('what reading a sign-in failed with, as a log says it: its kind and no more, but for what the system\'s '
      'storage said', () {
    // What reading a key file fails with prints a piece of the file: only its kind is said.
    Object? thrown;
    try {
      SSHKeyPair.fromPem(storage.values['identity_key_id-damaged']!);
    } catch (e) {
      thrown = e;
    }
    expect('$thrown', contains(fileText.substring(0, 16)), reason: 'what it prints carries the file');
    expect(signInReadFailure(thrown!), 'FormatException');
    expect(signInReadFailure(StateError('the key was: $fileText')), 'StateError');
    // The system's storage: its code and its words, on one line.
    expect(signInReadFailure(PlatformException(code: 'Exception encountered', message: 'Access is denied.')),
        'PlatformException: Exception encountered: Access is denied.');
    expect(signInReadFailure(PlatformException(code: '-25308')), 'PlatformException: -25308');
    expect(signInReadFailure(PlatformException(code: 'read', message: 'first\nsecond')),
        'PlatformException: read: first second');
  });

  test('each of the four sentences is said in every language, the first three with the name of the key', () {
    final said = <String, Set<String>>{};
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      for (final (name, sentence) in [
        ('unreadable', l10n.connKeyUnreadable('deploy key')),
        ('unusable', l10n.connCertUnusable('deploy key')),
        ('not loaded', l10n.connSignInNotLoaded('deploy key')),
      ]) {
        expect(sentence, contains('deploy key'), reason: '$name in $locale');
        expect(said.putIfAbsent(name, () => {}).add(sentence), isTrue, reason: '$name in $locale is said as another');
      }
      expect(said.putIfAbsent('asked', () => {}).add(l10n.connSavedPasswordUnreadable), isTrue,
          reason: 'the reason in $locale is said as another');
      expect(l10n.connSavedPasswordUnreadable.trim(), isNotEmpty);
    }
    expect(said.values.map((sentences) => sentences.length), everyElement(AppLocalizations.supportedLocales.length));
  });
}

/// The device's secure storage with what a test puts into it, and with
/// reads that fail where the test says so.
class _Storage implements FlutterSecureStorage {
  _Storage(this.values);

  final Map<String, String> values;

  /// The keys whose read fails, as a system's keychain fails.
  final failing = <String>{};

  @override
  Future<String?> read({
    required String key,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) async {
    if (failing.contains(key)) {
      throw PlatformException(code: 'Exception encountered', message: 'read failed for $key');
    }
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    Object? iOptions,
    Object? aOptions,
    Object? lOptions,
    Object? webOptions,
    Object? mOptions,
    Object? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
