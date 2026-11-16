import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/certs/team_certificate_login.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline, requireCratesOpenIn;
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardServiceProvider;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart' show connectionResolverProvider;
import 'package:zestssh/providers/ssh_cert_providers.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/reconnect_cannot_help.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/type_name.dart';

/// Credentials resolved for a NON-INTERACTIVE (headless) SSH connect. Same
/// record shape `ActiveSessionsNotifier._resolveIdentity` returns, so the two
/// paths can share the jump-chain builder.
typedef SilentCreds = ({
  String username,
  String? password,
  List<SSHKeyPair>? keyPairs,
});

/// Outcome of trying to open a headless exec client for a monitored host.
enum MonitorExecOutcome {
  /// Authenticated exec client is ready ([MonitorExecResult.service] set).
  ok,

  /// The host's saved credentials can't authenticate without a prompt
  /// (no identity, no saved password, encrypted key with no saved
  /// passphrase, hardware-token/agent auth). Never a socket was opened.
  needsCredentials,

  /// A new or changed host key was presented. A headless poll refuses to
  /// trust it - the user must open a terminal to review/verify.
  needsHostKeyReview,

  /// The host isn't monitorable at all (e.g. not an SSH protocol).
  notEligible,

  /// The connect/auth attempt failed for another reason (network, 2FA
  /// required, timeout). [MonitorExecResult.failedWith] is what it failed
  /// with.
  error,

  /// The host refused the sign-in: none of the keys or the password it was
  /// offered was accepted, or it ended the connection while it was being
  /// signed in to and said that it does (too many failed sign-ins). Trying
  /// again ends the same way until the saved credentials change, and every
  /// try is one more refused sign-in in the host's log.
  /// [MonitorExecResult.failedWith] as for [error].
  signInRefused,

  /// The connection got as far as the host, or as a jump host on the way,
  /// and ended over something else that no timer changes
  /// ([reconnectCannotHelp]): a key the host showed and the SSH core
  /// refused by itself (the host could not prove it to be its own, or it is
  /// no key a host has), a group for the key exchange that is not taken,
  /// no algorithm of one kind in common with what the host was offered,
  /// or a key of the app's own that could not sign. Dialled again it ends
  /// the same way, and every time is one more connection that ended before
  /// sign-in in the host's log. [MonitorExecResult.failedWith] as for
  /// [error].
  endsTheSame,
}

/// Result of [SshConnectionFactory]-driven headless connect. On [ok] the
/// caller owns [service] and MUST call `service.disconnect()` when done.
class MonitorExecResult {
  final MonitorExecOutcome outcome;

  /// Non-null only when [outcome] is [MonitorExecOutcome.ok].
  final SshService? service;

  /// Short, NON-localized note for [MonitorExecOutcome.notEligible]: why the
  /// host is not one to monitor.
  final String? detail;

  /// What the connect failed with ([MonitorExecOutcome.error],
  /// [MonitorExecOutcome.signInRefused] and
  /// [MonitorExecOutcome.endsTheSame]): the error itself, a jump host's
  /// failure as that ([JumpHostFailure]). Whoever shows the host puts it
  /// into words, as a session that failed the same way is given them, and
  /// it goes into the report that can be copied.
  final Object? failedWith;

  /// Whether the key that is to be looked at
  /// ([MonitorExecOutcome.needsHostKeyReview]) is another than the one this
  /// device trusts for the host, or than the one its team pinned: false
  /// where this device has seen no key of the host's before.
  final bool hostKeyChanged;

  const MonitorExecResult._(this.outcome, {this.service, this.detail, this.failedWith, this.hostKeyChanged = false});

  factory MonitorExecResult.ok(SshService service) =>
      MonitorExecResult._(MonitorExecOutcome.ok, service: service);
  factory MonitorExecResult.needsCredentials() =>
      const MonitorExecResult._(MonitorExecOutcome.needsCredentials);
  factory MonitorExecResult.needsHostKeyReview({required bool changed}) =>
      MonitorExecResult._(MonitorExecOutcome.needsHostKeyReview, hostKeyChanged: changed);
  factory MonitorExecResult.notEligible([String? detail]) =>
      MonitorExecResult._(MonitorExecOutcome.notEligible, detail: detail);
  factory MonitorExecResult.error(Object failedWith) =>
      MonitorExecResult._(MonitorExecOutcome.error, failedWith: failedWith);
  factory MonitorExecResult.signInRefused(Object failedWith) =>
      MonitorExecResult._(MonitorExecOutcome.signInRefused, failedWith: failedWith);
  factory MonitorExecResult.endsTheSame(Object failedWith) =>
      MonitorExecResult._(MonitorExecOutcome.endsTheSame, failedWith: failedWith);
}

/// What a headless connect that failed is told as:
///
/// - a host key to review where that is why ([hostKeyNeedsReview];
///   [hostKeyChanged] where it is another key than the one trusted, and not
///   the first this device sees of the host);
/// - a sign-in the host refused, where it took none of the keys or the
///   password it was offered, or ended the connection while it was being
///   signed in to and said that it does ([hostRefusedSignIn]);
/// - a connection that ended over something else no timer changes
///   ([reconnectCannotHelp]: a key of the host's that the SSH core refused
///   by itself, a group for the key exchange that is not taken, nothing in
///   common with what the host was offered, a key of the app's own that
///   could not sign), which was tried again by the timer
///   for as long as the host was monitored;
/// - and an error otherwise (the network, a time-out, a connection the host
///   closed with nothing said), which alone is worth trying again by a
///   timer.
///
/// What a jump host on the way failed with ([JumpHostFailure]) is told as
/// the same failure of the host would be: a sign-in it refused is a refused
/// sign-in, where every try is one more in that jump host's log. The error
/// is kept as it came, the jump host's failure as that, so that what is
/// shown of it can say which jump host it was.
MonitorExecResult monitorExecFailure(
  Object error, {
  required bool hostKeyNeedsReview,
  bool hostKeyChanged = false,
}) {
  if (hostKeyNeedsReview) return MonitorExecResult.needsHostKeyReview(changed: hostKeyChanged);
  final cause = error is JumpHostFailure ? error.cause : error;
  if (hostRefusedSignIn(cause)) return MonitorExecResult.signInRefused(error);
  if (reconnectCannotHelp(cause)) return MonitorExecResult.endsTheSame(error);
  return MonitorExecResult.error(error);
}

/// A host that Server Monitor is connected to was asked for its figures and
/// gave none of them, which is what a connection that has been lost looks
/// like. [said] is the app's own sentence for it.
class MonitorNoFigures implements Exception, HasTypeName {
  const MonitorNoFigures(this.said);

  final String said;

  @override
  String toString() => said;

  @override
  String get typeName => 'MonitorNoFigures';
}

/// Thrown by the silent hop-credential resolver when a jump host in a
/// monitored chain can't be resolved without a prompt. [openExecClient]
/// catches it and reports [MonitorExecOutcome.needsCredentials].
class NotSilentlyPollableException implements Exception, HasTypeName {
  NotSilentlyPollableException(this.hostLabel);
  final String hostLabel;
  @override
  String toString() =>
      'Host "$hostLabel" cannot be polled without an interactive prompt';

  @override
  String get typeName => 'NotSilentlyPollableException';
}

/// Mutable flag the [SshConnectionFactory.buildTrustOnlyHostKeyVerifier]
/// closure writes into so the caller can tell a host-key rejection apart from
/// a generic auth failure after `connectExec()` throws.
class HostKeyReviewSignal {
  bool needsReview = false;
  bool changed = false;
}

/// Provides the non-interactive (headless) credential + host-key policy the
/// agentless Server Monitor poller uses. Mirrors the interactive connect
/// flow's identity loading and host-key verification, but NEVER prompts,
/// never auto-trusts a new/changed key, and never hits the 2-minute password
/// prompt completer.
final sshConnectionFactoryProvider = Provider<SshConnectionFactory>((ref) {
  return SshConnectionFactory(ref);
});

/// The host a background connection is made to, where its key is checked
/// ([SshConnectionFactory.buildTrustOnlyHostKeyVerifier]): its id (its
/// Crate's team pins are the ones that count for it), the address and port
/// it is dialled at, the jump route its key is trusted under (null for one
/// dialled directly), and the address and port it is saved with, under which
/// its card shows a changed key.
typedef TrustTarget = ({String hostId, String host, int port, String? viaScope, String savedHost, int savedPort});

class SshConnectionFactory {
  SshConnectionFactory(this._ref);
  final Ref _ref;

  /// Whether [connection] can be polled headlessly with its saved credentials
  /// - i.e. [resolveCredentialsSilently] would return non-null. Cheap-ish
  /// pre-filter the poller uses to avoid opening a socket for a host that
  /// would otherwise need an interactive prompt.
  ///
  /// Only `ssh` hosts are ever monitorable (localShell/mosh/telnet/serial are
  /// not). Silent iff: a password identity WITH a saved password; OR a
  /// key/certificate identity whose stored key is unencrypted or has a saved
  /// passphrase (and, for certificates, a present, unexpired cert blob).
  ///
  /// The key is the one a poll signs in with: where the device is on a
  /// network that gives the host another key, that one
  /// ([_keyOnThisNetwork]). (The host's own key was looked at: a host whose
  /// own key could not sign in by itself was held at "needs credentials"
  /// though the network's could, and one whose own key could was dialled
  /// though the network's could not.)
  Future<bool> canPollSilently(Connection connection) async {
    if (connection.protocol != 'ssh') return false;
    return (await resolveCredentialsSilently(await _keyOnThisNetwork(connection))) != null;
  }

  /// [connection] with the key the network the device is on gives it, as
  /// ActiveSessionsNotifier.openExecClient signs in; as it is saved where no
  /// network gives it one, or where that cannot be read (the poll falls
  /// back to the same).
  Future<Connection> _keyOnThisNetwork(Connection connection) async {
    try {
      final resolved =
          await _ref.read(connectionResolverProvider).resolve(connection.id).timeout(const Duration(seconds: 5));
      return connection.copyWith(identityId: Value(resolved.identityKeyId));
    } catch (_) {
      return connection;
    }
  }

  /// Resolve [connection]'s credentials WITHOUT any interactive prompt.
  ///
  /// Mirrors `ActiveSessionsNotifier._resolveIdentity` but returns `null`
  /// wherever that method would call `_promptForPassword` /
  /// `_promptForPassphrase` (or otherwise lacks silent credentials), so it can
  /// NEVER reach the 2-minute prompt completer. Uses the same
  /// `identitiesDao.getById` + `identityCrud.getPassword/getPrivateKey/
  /// getKeyPassphrase` reads as the interactive path.
  Future<SilentCreds?> resolveCredentialsSilently(
      Connection connection) async {
    final identityId = connection.identityId;
    // No identity → the interactive path would prompt for a password.
    if (identityId == null) return null;

    final identity =
        await _ref.read(identitiesDaoProvider).getById(identityId);
    if (identity == null) return null;

    final username = identity.username;
    final crud = _ref.read(identityCrudProvider);

    // A key in a watched Crate signs in only to that Crate's hosts, in a
    // session someone watches (3.0): never silently.
    try {
      await requireWatchedKeyHostIn(_ref.read(databaseProvider), identity.id, connection.id);
    } on OrchardAccessRefused {
      return null;
    }
    // Nothing signs in to a host, or with a key, of a Crate that its own
    // offline limit has closed on this device (rules/crate_offline.dart).
    try {
      await requireCratesOpenIn(_ref.read(databaseProvider), hostId: connection.id, keyId: identity.id);
    } on CrateClosedOffline {
      return null;
    }

    switch (identity.authMethod) {
      case 'password':
        // An Orchard password this account may not see goes only to a host
        // it cannot change (3.0); otherwise the host is not
        // silently pollable.
        final db = _ref.read(databaseProvider);
        try {
          await requirePasswordHostIn(db, identity.id, connection.id);
        } on OrchardAccessRefused {
          return null;
        }
        // Nor is one from a Crate that asks again, to a host it may change
        // (3.0): the person confirms it is them first, and nobody is here
        // to ask.
        if (await passwordAsksAgainIn(db, identity.id, connection.id)) return null;
        final password = await crud.getPassword(identity.id);
        // No saved password → would prompt. Not silently pollable.
        if (password == null) return null;
        return (username: username, password: password, keyPairs: null);

      case 'publicKey':
      case 'certificate':
        final pem = await crud.getPrivateKey(identity.id);
        if (pem == null) return null; // key missing
        final passphrase = await crud.getKeyPassphrase(identity.id);
        List<SSHKeyPair> keyPairs;
        try {
          keyPairs = SSHKeyPair.fromPem(pem, passphrase);
        } on SSHKeyDecryptError {
          // Encrypted key with no (correct) saved passphrase → would prompt.
          return null;
        } catch (e) {
          AppLogger.debug('Monitor: silent key load failed for '
              '${identity.id}: $e');
          return null;
        }
        if (identity.authMethod == 'certificate') {
          // Fail closed exactly like the interactive path: a certificate
          // identity with no cert blob (or an expired one) is not pollable
          // rather than silently downgrading to bare-key auth.
          final cert = await _ref
              .read(sshCertServiceProvider)
              .loadCertForIdentity(identity.id);
          if (cert == null || keyPairs.isEmpty) return null;
          final exp = cert.validBeforeOrNull;
          if (exp != null && DateTime.now().toUtc().isAfter(exp)) return null;
          keyPairs = [
            for (final inner in keyPairs)
              SshCertificateKeyPair(innerKey: inner, certificate: cert),
          ];
        }
        // The password saved with the key, tried after it where the host
        // does not take the key (3.0, accounts per host), where it may go
        // with nobody to ask: not one an Orchard keeps from this account to
        // a host it may change, nor one from a Crate that asks again to
        // such a host. The key alone otherwise, and where it cannot be
        // read.
        String? passwordAfterKey;
        if (identity.passwordAfterKey) {
          final db = _ref.read(databaseProvider);
          try {
            await requirePasswordHostIn(db, identity.id, connection.id);
            if (!await passwordAsksAgainIn(db, identity.id, connection.id)) {
              passwordAfterKey = await crud.getPassword(identity.id);
            }
          } on OrchardAccessRefused {
            passwordAfterKey = null;
          } catch (e) {
            AppLogger.debug('Monitor: the password saved with a key could not be read: ${errorKind(e)}');
            passwordAfterKey = null;
          }
        }
        return (username: username, password: passwordAfterKey, keyPairs: keyPairs);

      case kTeamCertificateAuth:
        // A team certificate (3.0): only one already on this
        // device. Nobody is here to wait for an owner, so nothing is asked.
        try {
          final keyPair = await teamCertificateLogin(
              _ref.read(orchardServiceProvider), _ref.read(databaseProvider), identity,
              ask: false);
          return (username: username, password: null, keyPairs: [keyPair]);
        } catch (_) {
          return null;
        }

      case 'hardwareToken':
        // Agent / token-backed signing can require a physical touch or PIN
        // prompt at sign time - never silently pollable.
        return null;

      case 'passwordManager':
        // Fetched from the person's password manager, which may ask them
        // (3.0): never in the background.
        return null;

      default:
        return null;
    }
  }

  /// Build a headless, TRUST-ONLY host-key verifier: it accepts a key ONLY
  /// when [KnownHostsService.verify] already trusts it. A new or changed key
  /// aborts the connect (returns `false`) and records the reason in [signal]
  /// - it NEVER shows a dialog, NEVER calls `trustHost`, and NEVER
  /// auto-accepts. For a changed key it reuses `changedHostKeysProvider`'s
  /// `markChanged` so the host card's badge still lights, without blocking.
  ///
  /// [target] is the host the connection is made to: its key is looked for
  /// under the jump route it is reached by, as a session looks for it, and
  /// its card is marked under the address it is saved with; a jump host's
  /// on the way, as itself. (The host's key was looked for as if it were
  /// reached directly: a host behind a jump host never had its key found,
  /// and was compared with whatever server answers at its address directly,
  /// whose key, where this device trusts one, read as the host's changed.)
  ChainHostKeyVerifyCallback buildTrustOnlyHostKeyVerifier(HostKeyReviewSignal signal, {TrustTarget? target}) {
    final knownHosts = _ref.read(knownHostsServiceProvider);
    // Team-pinned host keys (3.0): a pinned key is trusted; any
    // other key there is refused and flagged, never learned in the background.
    final db = _ref.read(databaseProvider);
    final team = db.isOrchard ? TeamHostKeys(db) : null;
    return (host, port, hostKey, {String? hostId}) async {
      final isTarget =
          target != null && normalizeKnownHost(host) == normalizeKnownHost(target.host) && port == target.port;
      final viaScope = isTarget ? target.viaScope : null;
      final cardHost = isTarget ? target.savedHost : host;
      final cardPort = isTarget ? target.savedPort : port;
      // A pin counts only for the hosts of its own Crate: the host's, or a
      // jump host's on the way ([hostId]).
      final forHost = hostId ?? target?.hostId;
      final pin = team == null || forHost == null
          ? null
          : await team.pinFor(host, port, viaScope: viaScope, crateId: await team.crateOfHost(forHost));
      if (pin != null) {
        if (pin.matches(hostKey)) return true;
        signal.needsReview = true;
        signal.changed = true;
        await _ref.read(changedHostKeysProvider.notifier).markChanged(cardHost, cardPort);
        AppLogger.warning('Monitor: host key is not the one the team pinned for $host:$port - refusing');
        return false;
      }
      // Headless: only the verdict matters (no provenance notice in the
      // background). A synced key is trusted here, and left for the first
      // session a person opens to tell them of (tellsPerson: false).
      final result =
          (await knownHosts.verify(host, port, hostKey, viaScope: viaScope, tellsPerson: false)).result;
      switch (result) {
        case HostKeyVerifyResult.trusted:
          return true;
        case HostKeyVerifyResult.newHost:
          signal.needsReview = true;
          AppLogger.debug(
              'Monitor: refusing new host key for $host:$port (headless)');
          return false;
        case HostKeyVerifyResult.changed:
          signal.needsReview = true;
          signal.changed = true;
          // Light the changed-key badge (same store the interactive flow
          // uses) but never prompt or trust in the background.
          await _ref
              .read(changedHostKeysProvider.notifier)
              .markChanged(cardHost, cardPort);
          AppLogger.warning(
              'Monitor: host key CHANGED for $host:$port - refusing headless '
              'trust, flagged for review');
          return false;
      }
    };
  }
}
