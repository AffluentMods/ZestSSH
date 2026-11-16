import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/authorized_keys_edit.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/features/run/run_client.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show activeSessionsProvider;
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/command_text.dart';

// Replace on all hosts (3.0):
// a key rotated across every host that signs in with it. A new key of the
// same kind (or the one picked) is made, and then, for each host, on its
// own and never stopping the others:
//
//   1. it is signed in to as its sessions are, with the old key, and its
//      authorized_keys is read: a host whose old key's line has options
//      (from=, command=...) is left alone, before anything is changed;
//   2. the new key is added to it, as Install on hosts adds a key;
//   3. a NEW connection is made with the new key alone (no password, no
//      question answered), which proves the new key lets it in;
//   4. only then is the old key's exact line taken out of authorized_keys
//      (authorized_keys_edit.dart: the key's bytes compared, every other
//      line kept to the byte, the file's permissions kept, written only if
//      it is still the file that was read);
//   5. the host's saved login is pointed at the new key (its own key, the
//      other accounts it lists, and the networks that name the old key for
//      it).
//
// A host that fails at a step keeps the old key working: the old line goes
// only after the new key proved itself there. Hosts reached through a jump
// host, a team's hosts, and hosts that sign in with another key on the
// network the device is on are skipped, with why. Running it again uses the
// same new key ([ReplaceKeyLinks]) and finishes the hosts that were not done:
// those still sign in with the old key.

/// How far one host is.
enum ReplaceStep { waiting, signingIn, reading, adding, proving, removing, pointing, done, skipped, failed, stopped }

/// Why a host was skipped or failed, or what is to be known of one done.
enum ReplaceWhy {
  /// Not an SSH host.
  notSsh,

  /// Reached through a jump host: the new key could not be proved on the
  /// same way.
  jumpHost,

  /// A team's host: its key is the team's.
  teamHost,

  /// On the network the device is on, the host signs in with another key.
  otherKeyHere,

  /// Set to be skipped on the network the device is on.
  notOnThisNetwork,

  /// The sign-in with the old key did not work.
  signInFailed,

  /// authorized_keys could not be read.
  unreadableFile,

  /// authorized_keys is a link: never written through.
  linkFile,

  /// The old key's line has options: the person's to change.
  oldWithOptions,

  /// A line that holds the old key could not be read.
  oldUnreadable,

  /// The new key was not added.
  notAdded,

  /// The new key did not sign in.
  proofFailed,

  /// authorized_keys changed while it was being edited: nothing written.
  changedMeanwhile,

  /// The new key was not in authorized_keys after it was added.
  newKeyMissing,

  /// authorized_keys was not written (or not as it should have been).
  notWritten,

  /// The host's saved login was not changed.
  notPointed,

  /// Done, and the old key was not in authorized_keys: it may be let in
  /// from somewhere else.
  oldNotFound,

  /// Stopped before its turn.
  stopped,
}

/// One host's part.
@immutable
class ReplaceHost {
  const ReplaceHost({required this.host, this.step = ReplaceStep.waiting, this.why, this.details, this.removed = 0, this.user});

  final Connection host;
  final ReplaceStep step;
  final ReplaceWhy? why;

  /// What failed, as text for Copy details (never a secret: what the host
  /// printed as errors, or what was thrown).
  final String? details;

  /// How many lines of the old key were taken out.
  final int removed;

  /// The account signed in to as.
  final String? user;

  bool get over => step == ReplaceStep.done || step == ReplaceStep.skipped || step == ReplaceStep.failed || step == ReplaceStep.stopped;

  bool get going => !over && step != ReplaceStep.waiting;

  ReplaceHost to(ReplaceStep step, {ReplaceWhy? why, String? details, int? removed, String? user}) => ReplaceHost(
        host: host,
        step: step,
        why: why,
        details: details,
        removed: removed ?? this.removed,
        user: user ?? this.user,
      );
}

/// A replacement: the old key, the new one, and each host's part.
@immutable
class ReplaceRun {
  const ReplaceRun({
    required this.oldId,
    required this.oldLabel,
    required this.hosts,
    this.newId,
    this.newLabel,
    this.running = false,
    this.failure,
  });

  final String oldId;
  final String oldLabel;
  final String? newId;
  final String? newLabel;
  final List<ReplaceHost> hosts;
  final bool running;

  /// What stopped it before any host (the new key could not be made).
  final Object? failure;

  int get done => hosts.where((h) => h.step == ReplaceStep.done).length;

  /// Whether every host is done.
  bool get allDone => hosts.isNotEmpty && hosts.every((h) => h.step == ReplaceStep.done);

  ReplaceRun copyWith({List<ReplaceHost>? hosts, bool? running, String? newId, String? newLabel, Object? failure}) => ReplaceRun(
        oldId: oldId,
        oldLabel: oldLabel,
        newId: newId ?? this.newId,
        newLabel: newLabel ?? this.newLabel,
        hosts: hosts ?? this.hosts,
        running: running ?? this.running,
        failure: failure,
      );
}

/// What a replacement runs on a host through: a sign-in with the host's
/// saved login.
abstract class ReplaceLink {
  /// The account, address and port signed in to (where the network the
  /// device is on sends it).
  String get user;
  String get address;
  int get port;

  /// Whether it came through a jump host.
  bool get throughJumpHost;

  /// Runs [command], giving it [input] to read, and what it printed.
  Future<({int? exitCode, Uint8List out, String err})> run(String command, {List<int>? input});

  Future<void> close();
}

/// How long a command of a replacement is given on a host.
const kReplaceCommandTimeout = Duration(seconds: 60);

/// The most a host may print for a command here (an authorized_keys file).
const kReplaceOutputMost = 4 * 1024 * 1024;

/// A [ReplaceLink] over a run's sign-in ([RunClient]).
class SshReplaceLink implements ReplaceLink {
  SshReplaceLink(this._client);

  final RunClient _client;

  SshService get _ssh => _client.ssh;

  @override
  String get user => _ssh.username;

  @override
  String get address => _ssh.host;

  @override
  int get port => _ssh.port;

  @override
  bool get throughJumpHost => _ssh.tunnelSocket != null || _ssh.jumpClients.isNotEmpty;

  @override
  Future<({int? exitCode, Uint8List out, String err})> run(String command, {List<int>? input}) async {
    final session = await _ssh.client.execute(CommandText.script(command)).timeout(kReplaceCommandTimeout);
    final out = BytesBuilder(copy: false);
    final err = BytesBuilder(copy: false);
    var tooMuch = false;
    final reading = session.stdout.listen((chunk) {
      if (out.length + chunk.length > kReplaceOutputMost) {
        tooMuch = true;
        session.close();
        return;
      }
      out.add(chunk);
    }).asFuture<void>();
    final errors = session.stderr.listen((chunk) {
      if (err.length < 64 * 1024) err.add(chunk);
    }).asFuture<void>();
    if (input != null) session.stdin.add(Uint8List.fromList(input));
    await session.stdin.close();
    await Future.wait([reading, errors, session.done]).timeout(kReplaceCommandTimeout);
    if (tooMuch) throw StateError('The host printed more than an authorized_keys file can be');
    return (exitCode: session.exitCode, out: out.takeBytes(), err: utf8.decode(err.takeBytes(), allowMalformed: true));
  }

  @override
  Future<void> close() async {
    final log = _client.teamLog;
    if (log != null) unawaited(TeamSessionLogs.end(log));
    await _ssh.disconnect();
  }
}

/// The new key a replacement of an old key made: kept on the device so a
/// replacement run again goes on with the same new key (`keys_replace:<old
/// id>` in the device's own encrypted state).
class ReplaceKeyLinks {
  ReplaceKeyLinks(this._store);

  final LocalStateStore Function() _store;

  static String _key(String oldId) => 'keys_replace:$oldId';

  /// The new key made for [oldId]; null where none was, or the device's
  /// state cannot be read.
  Future<String?> newKeyOf(String oldId) async {
    try {
      return await _store().read(_key(oldId));
    } catch (_) {
      return null;
    }
  }

  Future<void> remember(String oldId, String newId) async {
    try {
      await _store().write(_key(oldId), newId);
    } catch (_) {/* a run again then makes another new key */}
  }

  Future<void> forget(String oldId) async {
    try {
      await _store().remove(_key(oldId));
    } catch (_) {/* nothing kept */}
  }
}

final replaceKeyLinksProvider = Provider<ReplaceKeyLinks>((ref) => ReplaceKeyLinks(() => ref.read(localStateStoreProvider)));

/// The kinds a new key may be made as.
const kReplaceKeyTypes = [KeyType.ed25519, KeyType.ecdsaP256, KeyType.rsa4096];

/// The kind of new key that matches [identity]'s: the same where it is one
/// of [kReplaceKeyTypes] (or the same family), Ed25519 otherwise.
KeyType replacementTypeFor(Identity identity) {
  final kind = (identity.keyType ?? '').toLowerCase();
  if (kind.contains('ecdsa') || kind.contains('nistp')) {
    return kind.contains('384') ? KeyType.ecdsaP384 : kind.contains('521') ? KeyType.ecdsaP521 : KeyType.ecdsaP256;
  }
  if (kind.contains('rsa')) return kind.contains('2048') ? KeyType.rsa2048 : KeyType.rsa4096;
  return KeyType.ed25519;
}

/// Why [host] is skipped before anything is done on it; null where it is
/// not ([old] the key being replaced). [space] is the space on screen.
Future<ReplaceWhy?> replaceSkipBefore(
  Connection host,
  Identity old, {
  required Space space,
  required ConnectionResolver resolver,
}) async {
  if (host.protocol != 'ssh') return ReplaceWhy.notSsh;
  if (space is OrchardSpace) return ReplaceWhy.teamHost;
  if (host.connectViaId != null) return ReplaceWhy.jumpHost;
  try {
    final resolved = await resolver.resolve(host.id).timeout(const Duration(seconds: 5));
    if (resolved.jumpChain.isNotEmpty) return ReplaceWhy.jumpHost;
    if (resolved.identityKeyId != old.id) return ReplaceWhy.otherKeyHere;
  } on HostUnreachableException {
    return ReplaceWhy.notOnThisNetwork;
  } catch (_) {
    // The base config is what a sign-in falls back to, as a session does.
  }
  return null;
}

/// Points [host]'s saved logins at [newId] in place of [oldId]: its own
/// key, the other accounts it lists, and each network's key for it.
Future<void> pointHostAtNewKey(AppDatabase db, Connection host, {required String oldId, required String newId}) async {
  final now = DateTime.now();
  await db.transaction(() async {
    if (host.identityId == oldId) {
      await db.connectionsDao.updateConnection(ConnectionsCompanion(
        id: Value(host.id),
        identityId: Value(newId),
        updatedAt: Value(now),
      ));
    }
    final others = await db.hostAccountsDao.otherAccountsOf(host.id);
    if (others.contains(oldId)) {
      await db.hostAccountsDao.setOtherAccounts(host.id, [
        for (final o in others)
          if (o != newId) o == oldId ? newId : o,
      ]);
    }
    for (final o in await db.networksDao.getOverridesForHost(host.id)) {
      if (o.identityId == oldId) {
        await db.networksDao.upsertOverride(o.copyWith(identityId: Value(newId), updatedAt: now).toCompanion(true));
      }
    }
  });
}

/// The steps of a replacement on one host, with what they are done with.
class ReplaceKeyDeps {
  const ReplaceKeyDeps({
    required this.openOld,
    required this.prove,
    required this.skipBefore,
    required this.point,
    this.authorizedKeys = kAuthorizedKeysFile,
  });

  /// Signs in to a host with its saved login (the old key).
  final Future<ReplaceLink> Function(Connection host) openOld;

  /// Signs in again with [keys] alone, on the way [link] came; throws where
  /// they are not let in.
  final Future<void> Function(ReplaceLink link, Connection host, List<SSHKeyPair> keys) prove;

  final Future<ReplaceWhy?> Function(Connection host, Identity old) skipBefore;

  final Future<void> Function(Connection host, {required String oldId, required String newId}) point;

  /// The account's authorized keys file, from its home folder.
  final String authorizedKeys;
}

/// The new key alone proves itself: a connection of its own to the
/// address [link] reached, signed in with [keys] and nothing else (no
/// password, no answer to a server's question), the host's key checked
/// against the keys this device trusts (never learned here). Throws where it
/// is not let in with the key.
Future<void> proveNewKey(Ref ref, ReplaceLink link, Connection host, List<SSHKeyPair> keys) async {
  final signal = HostKeyReviewSignal();
  final verify = ref.read(sshConnectionFactoryProvider).buildTrustOnlyHostKeyVerifier(
        signal,
        target: (hostId: host.id, host: link.address, port: link.port, viaScope: null, savedHost: host.host, savedPort: host.port),
      );
  final proof = SshService(
    host: link.address,
    port: link.port,
    username: link.user,
    keyPairs: keys,
    compatibilityMode: host.compatibilityMode,
    keepAliveSeconds: 0,
    onHostKeyVerify: verify,
  );
  try {
    await proof.connectExec();
    if (proof.signedInWith != 'publickey') {
      throw StateError('The host let the new connection in without the key (${proof.signedInWith})');
    }
  } finally {
    await proof.disconnect();
  }
}

/// The steps as the app does them: signed in to as sessions are
/// (ActiveSessionsNotifier.openRunClient), the new key proved on its own
/// connection, the saved logins of the space on screen changed; on the
/// authorized keys file [authorizedKeys] (a test's own).
ReplaceKeyDeps replaceKeyDepsOf(Ref ref, {String authorizedKeys = kAuthorizedKeysFile}) => ReplaceKeyDeps(
      authorizedKeys: authorizedKeys,
      openOld: (host) async {
        ref.read(activeSessionsProvider.notifier).runStarting([host.id]);
        return SshReplaceLink(await ref.read(activeSessionsProvider.notifier).openRunClient(host));
      },
      prove: (link, host, keys) => proveNewKey(ref, link, host, keys),
      skipBefore: (host, old) => replaceSkipBefore(
        host,
        old,
        space: ref.read(activeSpaceProvider),
        resolver: ref.read(connectionResolverProvider),
      ),
      point: (host, {required oldId, required newId}) =>
          pointHostAtNewKey(ref.read(databaseProvider), host, oldId: oldId, newId: newId),
    );

/// How many hosts are worked on at once.
const kReplaceAtOnce = 3;

/// Replaces a key on its hosts; one replacement at a time, kept until the
/// next.
class ReplaceKeyNotifier extends StateNotifier<ReplaceRun?> {
  ReplaceKeyNotifier(this._ref, this._deps, {this.atOnce = kReplaceAtOnce}) : super(null);

  final Ref _ref;
  final ReplaceKeyDeps _deps;
  final int atOnce;

  var _round = 0;

  /// The old key's line, its bytes, the new key's line and its key pairs,
  /// for the run going (and a run again).
  Uint8List? _oldBlob;
  String? _newLine;
  Uint8List? _newBlob;
  List<SSHKeyPair>? _newKeys;
  Identity? _old;

  /// Replaces [old] on [hosts], making the new key as [type] with [newLabel]
  /// where none was made for it before ([ReplaceKeyLinks]). Not while one
  /// runs.
  Future<void> start(Identity old, List<Connection> hosts, {required KeyType type, required String newLabel}) async {
    if (state?.running ?? false) return;
    _old = old;
    state = ReplaceRun(oldId: old.id, oldLabel: old.label, hosts: [for (final h in hosts) ReplaceHost(host: h)], running: true);
    try {
      final crud = _ref.read(identityCrudProvider);
      final oldLine = await crud.publicLineOf(old);
      _oldBlob = blobOfPublicLine(oldLine);
      if (_oldBlob == null) throw StateError('The old key has no public key');
      final made = await _newKey(old, type: type, label: newLabel);
      if (!mounted) return;
      state = state?.copyWith(newId: made.id, newLabel: made.label);
    } catch (e) {
      if (mounted) state = state?.copyWith(running: false, failure: e);
      return;
    }
    await _go([for (var i = 0; i < hosts.length; i++) i]);
  }

  /// Runs the hosts that are not done again.
  Future<void> again() async {
    final last = state;
    if (last == null || last.running || _old == null || _newKeys == null) return;
    final which = [for (var i = 0; i < last.hosts.length; i++) if (last.hosts[i].step != ReplaceStep.done) i];
    if (which.isEmpty) return;
    state = last.copyWith(
      hosts: [
        for (var i = 0; i < last.hosts.length; i++)
          which.contains(i) ? ReplaceHost(host: last.hosts[i].host) : last.hosts[i],
      ],
      running: true,
    );
    await _go(which);
  }

  /// Stops after the hosts being worked on now: those whose turn has not
  /// come are not started (a host is never left halfway through a step).
  void stop() {
    final now = state;
    if (now == null || !now.running) return;
    _round++;
    state = now.copyWith(
      hosts: [for (final h in now.hosts) h.step == ReplaceStep.waiting ? h.to(ReplaceStep.stopped, why: ReplaceWhy.stopped) : h],
      running: now.hosts.any((h) => h.going),
    );
  }

  /// After every host is done: the old key deleted from the vault
  /// ([deleteOld]), or kept and named [replacedLabel].
  Future<void> finish({required bool deleteOld, required String replacedLabel}) async {
    final run = state;
    if (run == null || run.running) return;
    final crud = _ref.read(identityCrudProvider);
    if (deleteOld) {
      await crud.delete(run.oldId);
    } else {
      await crud.update(id: run.oldId, label: replacedLabel);
    }
    await _ref.read(replaceKeyLinksProvider).forget(run.oldId);
    if (mounted) state = null;
  }

  /// Forgets a run that is over.
  void clear() {
    if (!(state?.running ?? false)) state = null;
  }

  /// The new key: the one made for [old] before, where it is still there,
  /// else a new one.
  Future<({String id, String label})> _newKey(Identity old, {required KeyType type, required String label}) async {
    final crud = _ref.read(identityCrudProvider);
    final links = _ref.read(replaceKeyLinksProvider);
    final keptId = await links.newKeyOf(old.id);
    if (keptId != null) {
      final kept = await _ref.read(identitiesDaoProvider).getById(keptId);
      final pem = kept == null ? null : await crud.getPrivateKey(keptId);
      if (kept != null && pem != null) {
        _useNewKey(pem, await crud.getKeyPassphrase(keptId), kept.publicKeyData ?? await crud.publicLineOf(kept));
        return (id: kept.id, label: kept.label);
      }
    }
    final made = await KeyGenerationService().generate(type, comment: label);
    // What signs in with the key goes with it: its user, its colour, the
    // password tried after it, and whether unattended runs may use it (the
    // hosts it signs in to will be signed in to with the new one).
    final afterKey = old.passwordAfterKey;
    final id = await crud.create(
      label: label,
      username: old.username,
      authMethod: AuthMethod.publicKey.name,
      keyType: type.name,
      publicKeyFingerprint: made.fingerprint,
      publicKeyData: made.publicOpenSSH,
      privateKeyPem: made.privatePem,
      password: afterKey ? await crud.getPassword(old.id) : null,
      passwordAfterKey: afterKey,
      colorIndex: old.colorIndex,
      colorValue: old.colorValue,
      allowUnattended: old.allowUnattended,
    );
    await links.remember(old.id, id);
    _useNewKey(made.privatePem, null, made.publicOpenSSH);
    return (id: id, label: label);
  }

  void _useNewKey(String pem, String? passphrase, String? publicLine) {
    _newKeys = SSHKeyPair.fromPem(pem, passphrase);
    final line = installLine(publicLine) ?? installLine(publicKeyLineOfPairs(_newKeys!));
    if (line == null) throw StateError('The new key has no public key');
    _newLine = line;
    _newBlob = blobOfPublicLine(line);
  }

  Future<void> _go(List<int> which) async {
    final round = ++_round;
    final queue = [...which];
    Future<void> worker() async {
      while (queue.isNotEmpty && round == _round && mounted) {
        await _one(queue.removeAt(0));
      }
    }

    await Future.wait([for (var i = 0; i < atOnce && i < which.length; i++) worker()]);
    if (!mounted) return;
    final now = state;
    if (now != null && !now.hosts.any((h) => h.going)) state = now.copyWith(running: false);
  }

  void _set(int index, ReplaceHost Function(ReplaceHost h) change) {
    final now = state;
    if (now == null || !mounted) return;
    state = now.copyWith(hosts: [for (var i = 0; i < now.hosts.length; i++) i == index ? change(now.hosts[i]) : now.hosts[i]]);
  }

  Future<void> _one(int index) async {
    final host = state!.hosts[index].host;
    final old = _old!;
    final newId = state!.newId!;
    void to(ReplaceStep step, {ReplaceWhy? why, String? details, int? removed, String? user}) =>
        _set(index, (h) => h.to(step, why: why, details: details, removed: removed, user: user));

    to(ReplaceStep.signingIn);
    final skip = await _deps.skipBefore(host, old);
    if (skip != null) return to(ReplaceStep.skipped, why: skip);
    final ReplaceLink link;
    try {
      link = await _deps.openOld(host);
    } catch (e) {
      return to(ReplaceStep.failed, why: ReplaceWhy.signInFailed, details: '$e');
    }
    try {
      to(ReplaceStep.reading, user: link.user);
      if (link.throughJumpHost) return to(ReplaceStep.skipped, why: ReplaceWhy.jumpHost);
      // Read first: a host whose old key's line has options is left as it
      // is, before the new key is added.
      final (before, beforeErrors) = await _read(link);
      switch (before) {
        case null:
          return to(ReplaceStep.failed, why: ReplaceWhy.unreadableFile, details: beforeErrors);
        case AuthorizedKeysIsLink():
          return to(ReplaceStep.skipped, why: ReplaceWhy.linkFile);
        case AuthorizedKeysFile(:final bytes):
          final check = removeKeyLines(bytes, _oldBlob!);
          if (check.withOptions.isNotEmpty) {
            return to(ReplaceStep.skipped, why: ReplaceWhy.oldWithOptions, details: _lines(check.withOptions));
          }
          if (check.unreadable.isNotEmpty) {
            return to(ReplaceStep.skipped, why: ReplaceWhy.oldUnreadable, details: _lines(check.unreadable));
          }
        case AuthorizedKeysMissing():
          break;
      }

      to(ReplaceStep.adding);
      final added = await link.run(installKeyCommandFor(_deps.authorizedKeys), input: utf8.encode('$_newLine\n'));
      final said = latin1.decode(added.out);
      if (added.exitCode != 0 || !(said.contains(kKeyAdded) || said.contains(kKeyThere))) {
        return to(ReplaceStep.failed, why: ReplaceWhy.notAdded, details: _said(added.exitCode, added.err));
      }

      to(ReplaceStep.proving);
      try {
        await _deps.prove(link, host, _newKeys!);
      } catch (e) {
        return to(ReplaceStep.failed, why: ReplaceWhy.proofFailed, details: '$e');
      }

      // Proved: the old key's line goes, from the file as it is now.
      to(ReplaceStep.removing);
      final (now, nowErrors) = await _read(link);
      var removed = 0;
      switch (now) {
        case AuthorizedKeysFile(:final bytes, :final sum):
          final edit = removeKeyLines(bytes, _oldBlob!, keep: _newBlob);
          if (edit.withOptions.isNotEmpty) {
            return to(ReplaceStep.failed, why: ReplaceWhy.oldWithOptions, details: _lines(edit.withOptions));
          }
          if (edit.unreadable.isNotEmpty) {
            return to(ReplaceStep.failed, why: ReplaceWhy.oldUnreadable, details: _lines(edit.unreadable));
          }
          if (!edit.keepsNewKey) return to(ReplaceStep.failed, why: ReplaceWhy.newKeyMissing);
          if (edit.removed.isNotEmpty) {
            final wrote = await link.run(writeAuthorizedKeysCommand(sum, _deps.authorizedKeys), input: edit.bytes);
            final out = latin1.decode(wrote.out);
            if (out.contains(kAkChanged)) return to(ReplaceStep.failed, why: ReplaceWhy.changedMeanwhile);
            final written = RegExp('$kAkWritten ([0-9]+ [0-9]+)').firstMatch(out)?.group(1);
            if (wrote.exitCode != 0 || written != posixCksum(edit.bytes)) {
              return to(ReplaceStep.failed, why: ReplaceWhy.notWritten, details: _said(wrote.exitCode, wrote.err));
            }
            removed = edit.removed.length;
          }
        case AuthorizedKeysIsLink():
          return to(ReplaceStep.failed, why: ReplaceWhy.linkFile);
        case AuthorizedKeysMissing():
          return to(ReplaceStep.failed, why: ReplaceWhy.newKeyMissing);
        case null:
          return to(ReplaceStep.failed, why: ReplaceWhy.unreadableFile, details: nowErrors);
      }

      to(ReplaceStep.pointing, removed: removed);
      try {
        await _deps.point(host, oldId: old.id, newId: newId);
      } catch (e) {
        return to(ReplaceStep.failed, why: ReplaceWhy.notPointed, details: '$e', removed: removed);
      }
      to(ReplaceStep.done, why: removed == 0 ? ReplaceWhy.oldNotFound : null, removed: removed);
    } catch (e) {
      to(ReplaceStep.failed, why: ReplaceWhy.signInFailed, details: '$e');
    } finally {
      unawaited(link.close().catchError((Object _) {}));
    }
  }

  /// The account's authorized_keys as the host gives it, and what it
  /// printed as errors where it could not be read.
  Future<(AuthorizedKeysRead?, String?)> _read(ReplaceLink link) async {
    final r = await link.run(readAuthorizedKeysCommand(_deps.authorizedKeys));
    final read = r.exitCode == 0 ? readAuthorizedKeysOutput(r.out) : null;
    return (read, read == null ? _said(r.exitCode, r.err) : null);
  }

  static String _said(int? exitCode, String err) => [
        if (exitCode != null) 'exit status $exitCode',
        if (err.trim().isNotEmpty) err.trim(),
      ].join('\n');

  static String _lines(List<int> numbers) => 'authorized_keys line ${numbers.join(', ')}';
}

/// The public key line of [keys]' first key.
String? publicKeyLineOfPairs(List<SSHKeyPair> keys) {
  if (keys.isEmpty) return null;
  return '${keys.first.name} ${base64.encode(keys.first.toPublicKey().encode())}';
}

/// The replacement of a key on its hosts, of this window: one at a time.
final replaceKeyRunProvider =
    StateNotifierProvider<ReplaceKeyNotifier, ReplaceRun?>((ref) => ReplaceKeyNotifier(ref, replaceKeyDepsOf(ref)));

/// [replaceKeyRunProvider] with its steps done by [deps] (tests).
Override replaceKeyRunWith(ReplaceKeyDeps Function(Ref ref) deps, {int atOnce = kReplaceAtOnce}) =>
    replaceKeyRunProvider.overrideWith((ref) => ReplaceKeyNotifier(ref, deps(ref), atOnce: atOnce));
