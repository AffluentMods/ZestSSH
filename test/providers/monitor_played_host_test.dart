import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The groups of the RFCs, and what a host answers a sign-in with, are not
// in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/kex/kex_dh.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart' show failedCheckSaid;
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_group_exchange.dart';
import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// Server Monitor's own connection to a host, in the background, where the
/// SSH core ends it by itself over something no timer changes (3.0, from
/// the SSH core's audit): a host that cannot prove its key, a host that
/// names a group for the key exchange that is not taken, and a key of the
/// app's own that cannot sign.
///
/// Each was told as a check that failed and is worth the next try, and the
/// monitor made that try by its timer for as long as the host was
/// monitored: every one a connection that ended before sign-in in the
/// host's log, which is what gets an address banned. They are told now as
/// what they are ([MonitorExecOutcome.endsTheSame]), and the monitor does
/// not dial such a host again by itself (test/providers/monitor_poll_test.dart).
///
/// And a key the monitor would not take: whether it is the first this
/// device sees of the host, or another than the one it trusts, is kept.
///
/// The monitor dials for itself, so the host is played on the loopback
/// address.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 15);
  late AppDatabase tree;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => tree.close());

  SSHKeyPair fromFile(String path) =>
      SSHKeyPair.fromPem(File('packages/zest_ssh_core/test/fixtures/$path').readAsStringSync()).single;

  /// Server Monitor's own connect to the host that [played] plays on the
  /// loopback address: how it is told, and how often its check of the
  /// host's key was asked. It signs in with [key], or with a password where
  /// none is given; [knows] is what its check says of the key the host
  /// shows (true: the one this device trusts; null: it has seen none of the
  /// host's; false: another than the one it trusts).
  Future<({MonitorExecResult told, int asked})> dialled(
    Future<void> Function(PlayedLine line) played, {
    SSHKeyPair? key,
    bool? knows = true,
  }) async {
    final listener = await PlayedListener.bind();
    final playing = () async {
      await played(await listener.line());
    }();
    final factory = _Signs(key, knows);
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      sshConnectionFactoryProvider.overrideWithValue(factory),
    ]);
    addTearDown(container.dispose);
    container.read(databaseSessionProvider.notifier).seed(tree);
    final at = DateTime(2026, 10, 1);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: listener.host,
          port: Value(listener.port),
          createdAt: at,
          updatedAt: at,
        ));
    final saved = (await tree.connectionsDao.getById('h-web'))!;
    final told = await container.read(activeSessionsProvider.notifier).openExecClient(saved).timeout(patience);
    addTearDown(() async => told.service?.disconnect());
    // What the played host waits for may never come: that ends with the connection.
    await playing.timeout(patience).then((_) {}, onError: (Object _) {});
    return (told: told, asked: factory.asked);
  }

  /// A host that shows the key in [pair] and signs with it something else
  /// than the exchange: what whoever has only the key's public half can do.
  Future<void> cannotProveItsKey(PlayedLine line, SSHKeyPair pair) => PlayedServer(
        line: line,
        hostKey: PlayedHostKey(
          'ssh-ed25519',
          pair.toPublicKey().encode(),
          (hash) => pair.sign(Uint8List.fromList(hash.reversed.toList())).encode(),
        ),
      ).exchangeKeys();

  /// Told as what no timer changes, with what the SSH core found kept for
  /// whoever shows the host, and said as a session that failed the same way
  /// is told.
  void expectEndsTheSame(({MonitorExecResult told, int asked}) outcome, String said) {
    expect(outcome.told.outcome, MonitorExecOutcome.endsTheSame, reason: '${outcome.told.failedWith}');
    expect(outcome.told.service, isNull);
    final failedWith = outcome.told.failedWith!;
    expect(reconnectCannotHelp(failedWith), isTrue);
    expect(failedCheckSaid(failedWith, host: 'web-01', port: 22), said);
  }

  test('a host that takes the sign-in: Server Monitor is connected to it', () async {
    final outcome = await dialled((line) => PlayedServer(line: line).letIn());
    expect(outcome.told.outcome, MonitorExecOutcome.ok, reason: '${outcome.told.failedWith}');
    expect(outcome.asked, 1);
  });

  test('a host that shows a key and cannot prove that it is its own: told as what no timer changes, with nobody '
      'asked about the key, and not as a key to look at', () async {
    final pair = fromFile('ssh-ed25519/ssh_host_ed25519_key');
    // (The monitor has seen no key of this host's: its check would have said so, had it been asked.)
    final outcome = await dialled((line) => cannotProveItsKey(line, pair), knows: null);
    expect(outcome.asked, 0);
    expectEndsTheSame(outcome, en.connHostKeyNotSigned);
    expect(hostKeyNotAccepted(outcome.told.failedWith!)?.fault, SSHHostkeyFault.notSigned);
  });

  test('a host that names a group of 1024 bits for the key exchange: told as what no timer changes', () async {
    final outcome = await dialled((line) async {
      final host = PlayedGroupExchange(line: line);
      await host.request();
      // The group of RFC 2409.
      final group = SSHKexDH.group1();
      await host.name(group.p, group.g);
    }, knows: null);
    expect(outcome.asked, 0);
    // (Without Compatibility mode, which takes such a group: said as a host that offers only an outdated key
    // exchange, with the switch and where it is.)
    expectEndsTheSame(outcome, en.connKexGroupOutdated(1024, 2048, 'Auth / Show advanced options'));
  });

  test('a key of the app\'s own that cannot sign: told as what no timer changes, and nothing is sent with it',
      () async {
    // A key file in which a number was changed: its primes no longer make its modulus.
    final real = fromFile('ssh-rsa/ssh_host_rsa_key') as OpenSSHRsaKeyPair;
    final damaged =
        OpenSSHRsaKeyPair(real.n, real.e, real.d, real.iqmp, real.p, real.q + BigInt.two, 'damaged');
    var signaturesSent = 0;
    SSH_Message_Userauth_Request? question;
    final outcome = await dialled((line) async {
      final host = PlayedServer(line: line);
      await host.greet();
      // The monitor asks which ways of signing in the host takes: keys only.
      await host.next(SSH_Message_Userauth_Request.messageId);
      host.send([SSH_Message_Userauth_Failure(methodsLeft: const ['publickey']).encode()]);
      // It asks about its key, and the host says that it would take it.
      final asked = SSH_Message_Userauth_Request.decode(await host.next(SSH_Message_Userauth_Request.messageId));
      question = asked;
      host.takesKey(asked);
      await host.settle();
      for (final payload in host.takeSent()) {
        if (payload[0] != SSH_Message_Userauth_Request.messageId) continue;
        if (SSH_Message_Userauth_Request.decode(payload).signature != null) signaturesSent++;
      }
    }, key: damaged);
    // (Looked at here: a check that fails in what plays the host ends with the connection, and is not seen.)
    expect(question, isNotNull, reason: 'the monitor did not ask about its key before it signed');
    expect(question!.methodName, 'publickey');
    expect(question!.signature, isNull);
    expect(signaturesSent, 0);
    expectEndsTheSame(outcome, en.connKeyCouldNotSign);
  });

  test('a key the monitor does not take is one to look at, kept as the first this device sees of the host or as '
      'another than the one it trusts', () async {
    for (final (knows, changed) in [(null, false), (false, true)]) {
      final outcome = await dialled(
        // The played host waits for the monitor's new keys, which do not come.
        (line) => PlayedServer(line: line).exchangeKeys(),
        knows: knows,
      );
      expect(outcome.asked, 1, reason: '$knows');
      expect((outcome.told.outcome, outcome.told.hostKeyChanged), (MonitorExecOutcome.needsHostKeyReview, changed),
          reason: '$knows');
      await tree.delete(tree.connections).go();
    }
  });
}

/// The saved sign-in of every host, with nobody asked, and Server Monitor's
/// check of a host's key as the test says it answers.
class _Signs implements SshConnectionFactory {
  _Signs(this.key, this.knows);

  final SSHKeyPair? key;

  /// What the check says of the key a host shows: true for the one this
  /// device trusts, null where it has seen none, false for another.
  final bool? knows;

  /// How often the check was asked.
  var asked = 0;

  @override
  Future<SilentCreds?> resolveCredentialsSilently(Connection connection) async => (
        username: 'deploy',
        password: key == null ? 'not-a-real-one' : null,
        keyPairs: key == null ? null : [key!],
      );

  @override
  ChainHostKeyVerifyCallback buildTrustOnlyHostKeyVerifier(HostKeyReviewSignal signal, {TrustTarget? target}) =>
      (_, _, _, {hostId}) async {
        asked++;
        if (knows == true) return true;
        // As the monitor's own check does: it takes nothing it does not trust, and says which it was.
        signal.needsReview = true;
        signal.changed = knows == false;
        return false;
      };

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
