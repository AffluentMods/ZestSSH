import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zest_native/ftps.dart';
import 'package:zest_ssh_core/dartssh2.dart'
    show SSHClient, SSHKeyPair, SSHSocket, SSHAuthAbortError, SSHAuthFailError, SSHHostkeyError;
import 'package:zest_native/screen.dart' show ScreenChannel;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart' show AppDatabase, Connection;
import 'package:zestssh/features/hosts/widgets/host_card.dart' show screenCarrierKind;
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart' show EffectiveTestConfig;
import 'package:zestssh/features/orchards/certs/team_certificate_login.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart' show TeamHostKeys;
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardServiceProvider;
import 'package:zestssh/features/orchards/orchard_service.dart' show TeamCertificateUnavailable;
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline, requireCratesOpenIn;
import 'package:zestssh/features/orchards/rules/reveal_gate.dart' show confirmItIsYou;
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_requests.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart'
    show ScreenFailure, ScreenFailureKind, screenFailureText;
import 'package:zestssh/features/screens/session/screen_probe.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart' show openDirectScreenSocket;
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/session/screen_team_rules.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart'
    show activeSessionsProvider, connectionFailureText, hostKeyNotAcceptedText;
import 'package:zestssh/services/fido/fido_key_pair.dart';
import 'package:zestssh/services/ftps/ftps_session.dart' show FtpsTeamPins;
import 'package:zestssh/services/known_hosts_service.dart' show HostKeyVerifyResult;
import 'package:zestssh/services/sftp_error_messages.dart' show sftpStartFailure;
import 'package:zestssh/services/sftp_service.dart' show sftpFirstFolder;
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart'
    show HostKeyNotAccepted, HostKeyRefusal, SSHHostKey, SshService, openSshSocket;
import 'package:zestssh/ui/screens/terminal/widgets/server_question_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/sign_in_link_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/host_address.dart' show hostWithPort;
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/type_name.dart';

/// What a connection test found: the verdict, what to say of it, and the
/// report behind "Copy details" where there is one.
class HostTestResult {
  const HostTestResult({required this.success, required this.message, this.detail});

  final bool success;
  final String message;

  /// Raw technical text (an SSH library string, a socket trace) behind a
  /// "Copy details" button. Null when [message] already tells the whole story.
  final String? detail;
}

/// How long a connection test gives a host to answer its sign-in, outside of
/// what its person is asked (and longer where the host has started asking,
/// or has given them a link to open).
const kConnectionTestPatience = Duration(seconds: 8);

/// The two connection tests of a host, in one place with all their gates: the
/// editor's footer and network rows run them on what is typed, the host panel
/// on what is saved. They lived in the editor's
/// state, about 300 lines of them.
///
/// Neither keeps a session: Test reachability only opens a socket, Test full
/// connection signs in and closes. Each answers with what to show, or null
/// where it ends without a verdict (the person declined to confirm it is them,
/// or cancelled a server's question). [onStarted] is told once a test really
/// begins: what is refused before dialling never calls it.
class HostTester {
  const HostTester({
    required this.context,
    required this.ref,
    this.hostId,
    this.compatibilityMode = false,
    this.sftpOnly = false,
    this.addressTypedHere = true,
    required this.addressChosenHere,
    this.wouldGoUnwatched = testWouldGoUnwatchedIn,
    this.requireCratesOpen = requireCratesOpenIn,
    this.screenTeamRules = screenTeamRulesIn,
    this.showSignInNotice,
    this.ftps = false,
    this.ftpsImplicit = false,
    this.ftpsNative = const RustFtpsNative(),
    this.screenSocket,
    this.screenRdp = false,
    this.screenRdpNla = true,
    this.openScreenRoute,
    this.openScreenDirect,
  });

  /// The team's rules about remote screens in force for a space
  /// ([screenTest] dials no screen directly where they say through an SSH
  /// host only).
  final Future<ScreenTeamRules> Function(AppDatabase db) screenTeamRules;

  /// A remote screen's socket on its carrier (4.0), where it is reached at
  /// one rather than at an address and port ([screenTest]).
  final String? screenSocket;

  /// The remote screen is an RDP host's ([screenTest] then reads an RDP
  /// server's answer to the connection request), and whether the host signs
  /// in with Network Level Authentication ([screenRdpNla]) or without.
  final bool screenRdp;
  final bool screenRdpNla;

  /// Signs in to a screen's carrier and gives the route to the screen on it
  /// (a test's fake); the app's own sign-in where null
  /// (ActiveSessionsNotifier.openScreenProbe).
  final Future<ScreenProbeRoute> Function(Connection carrier, ScreenTarget target)? openScreenRoute;

  /// Opens the socket to a screen reached directly (a test's fake).
  final Future<ScreenChannel> Function(String host, int port, Duration timeout)? openScreenDirect;

  /// An FTPS host (3.4): reach, TLS and sign-in over FTPS rather
  /// than SSH ([ftpsImplicit]: TLS from the first byte).
  final bool ftps;
  final bool ftpsImplicit;

  /// What FTPS goes through (the Rust library; a test's fake).
  final FtpsNative ftpsNative;

  /// Where its questions are asked (a host key, a server's sign-in question,
  /// that it is them).
  final BuildContext context;
  final WidgetRef ref;

  /// The saved host being tested; null for one not saved yet.
  final String? hostId;

  /// What a session to this host would offer: with Compatibility mode on, also
  /// what an old server needs.
  final bool compatibilityMode;

  /// A host that is SFTP only: its SFTP is opened and its first folder listed,
  /// as a session to it does, and no terminal is asked for.
  final bool sftpOnly;

  /// Whether what it tests was typed here (the editor), not saved (the panel):
  /// what it says of a password kept from the person goes by that.
  final bool addressTypedHere;

  /// Whether a test with a config sends to an address this account chose (3.0):
  /// one from a Crate that asks again goes there only once the
  /// person confirms it is them.
  final Future<bool> Function(EffectiveTestConfig cfg) addressChosenHere;

  /// The rules of a team's signed record: whether a test would go to a watched
  /// Crate's host or with one of its keys, and that the Crates it uses are open.
  /// (A test's own stands in.)
  final Future<bool> Function(AppDatabase db, {String? hostId, String? keyId}) wouldGoUnwatched;
  final Future<void> Function(AppDatabase db, {String? hostId, String? keyId}) requireCratesOpen;

  /// Shows a login banner with a link the test's sign-in waits on, and
  /// completes with true where its person cancels: the app's dialog where
  /// null (a test's own stands in).
  final Future<bool> Function(SignInNoticeRequest request)? showSignInNotice;

  /// A trailing advisory appended to a successful test when the effective
  /// config routes through a jump chain. The probe connects DIRECTLY to the
  /// target host:port - it does not tunnel through the jump chain - so this
  /// clarifies that the result reflects a direct path, not the real route.
  String _jumpNote(AppLocalizations l10n, EffectiveTestConfig cfg) {
    if (cfg.jumpChain.isEmpty) return '';
    return ' ${l10n.connectionTestJumpDirectNote}';
  }

  /// What a test that failed with [e] shows: what a failed connection says
  /// of the same failure, with the report of it behind "Copy details"
  /// ([connectionTestFailed]).
  HostTestResult _failed(AppLocalizations l10n, Object e, EffectiveTestConfig cfg) {
    final said = connectionTestFailed(
      l10n,
      e,
      host: cfg.host.trim(),
      port: cfg.port,
      username: cfg.username,
    );
    return HostTestResult(success: false, message: said.message, detail: said.report);
  }

  /// Reachability check - TCP only. Confirms the host:port is open
  /// and the network path works. Does NOT verify SSH auth, so a
  /// success here means "we could open a socket", not "your
  /// credentials are correct" (that's [fullConnection]).
  ///
  /// This is the safer of the two tests because it doesn't expose
  /// any credentials. Use it when you don't want any auth attempt
  /// to hit the server's logs.
  Future<HostTestResult?> reachability(EffectiveTestConfig cfg, {VoidCallback? onStarted}) async {
    final l10n = AppLocalizations.of(context)!;
    final host = cfg.host.trim();
    final port = cfg.port;

    if (host.isEmpty) {
      return HostTestResult(success: false, message: l10n.connectionHostRequired);
    }

    if (port < 1 || port > 65535) {
      return HostTestResult(success: false, message: l10n.connectionPortInvalid);
    }

    onStarted?.call();
    if (ftps) return _ftpsTest(cfg, signIn: false);

    final stopwatch = Stopwatch()..start();

    try {
      final socket = await openSshSocket(host, port, Duration(seconds: ref.read(connectionTimeoutProvider)));
      final tcpMs = stopwatch.elapsedMilliseconds;
      socket.destroy();

      stopwatch.stop();

      return HostTestResult(
        success: true,
        message: l10n.connectionEditReachableResult(tcpMs, _jumpNote(l10n, cfg)),
      );
    } on SocketException catch (e) {
      stopwatch.stop();
      return _failed(l10n, e, cfg);
    } on TimeoutException {
      stopwatch.stop();
      return HostTestResult(success: false, message: l10n.connectionTimedOut);
    } catch (e) {
      stopwatch.stop();
      final friendly = describeNetworkError(e, subject: l10n.errSubjectHost);
      return HostTestResult(success: false, message: friendly.message, detail: friendly.detail);
    }
  }

  /// Full-stack connection test: TCP → SSH transport → KEX →
  /// authentication. Loads the selected identity (key / password) and attempts
  /// to authenticate. Disconnects immediately once auth resolves - does not
  /// open a shell.
  ///
  /// This is the only way to verify "my credentials actually work
  /// for this host" without committing to a real session. Use it
  /// after editing an identity / password to make sure the change
  /// took effect.
  ///
  /// SECURITY: this DOES send your credentials to the server.
  /// Reachability-only is preferable when you'd rather not log
  /// auth attempts on a sensitive host.
  Future<HostTestResult?> fullConnection(EffectiveTestConfig cfg, {VoidCallback? onStarted}) async {
    final l10n = AppLocalizations.of(context)!;
    final host = cfg.host.trim();
    final port = cfg.port;
    if (host.isEmpty) {
      return HostTestResult(success: false, message: l10n.connectionHostRequired);
    }
    if (port < 1 || port > 65535) {
      return HostTestResult(success: false, message: l10n.connectionPortInvalid);
    }

    // Sessions to a watched Crate's hosts run only while someone watches
    // them (3.0): no test signs in to one, or with one of its keys.
    if (await wouldGoUnwatched(ref.read(databaseProvider), hostId: hostId, keyId: cfg.identityKeyId)) {
      return HostTestResult(success: false, message: l10n.watchedNoTest);
    }
    if (!context.mounted) return null;

    // Nor does a test sign in to a host, or with a key, of a Crate that its
    // own offline limit has closed on this device: said before anything is
    // dialled, in the words a connection would get.
    try {
      await requireCratesOpen(ref.read(databaseProvider), hostId: hostId, keyId: cfg.identityKeyId);
    } on CrateClosedOffline catch (e) {
      return HostTestResult(success: false, message: e.message);
    }
    if (!context.mounted) return null;

    // An Orchard password this account may not see is never sent to an
    // address typed here (3.0).
    final testIdentityId = cfg.identityKeyId;
    if (testIdentityId != null) {
      final identity = await ref.read(identitiesDaoProvider).getById(testIdentityId);
      if (identity?.authMethod == 'password' && !await mayRevealKeyNow(ref, testIdentityId)) {
        return HostTestResult(
          success: false,
          message: addressTypedHere ? l10n.orchardTestNeedsReveal : l10n.hostPanelTestNeedsReveal,
        );
      }
      // One from a Crate that asks again goes to an address chosen here only
      // once the person confirms it is them; declined, no test.
      if (identity?.authMethod == 'password' &&
          await revealAsksAgainNow(ref, testIdentityId) &&
          await addressChosenHere(cfg)) {
        if (!context.mounted) return null;
        if (!await confirmItIsYou(context, ref, sending: true)) return null;
      }
    }
    if (!context.mounted) return null;

    onStarted?.call();
    if (ftps) return _ftpsTest(cfg, signIn: true);

    final stopwatch = Stopwatch()..start();
    SSHSocket? sshSocket;
    SSHClient? client;
    KeyboardInteractiveAnswerer? answerer;
    // Set true if the presented host key isn't an already-trusted known
    // host - so the catch below can explain the failure instead of leaking
    // a raw error, and (critically) so we never send credentials first.
    var hostKeyUntrusted = false;
    // Set where the key shown is another than the one the team pinned for
    // this host: said in the words a connection says it in.
    HostKeyNotAccepted? pinnedOther;
    try {
      sshSocket = await openSshSocket(host, port, Duration(seconds: ref.read(connectionTimeoutProvider)));
      final tcpMs = stopwatch.elapsedMilliseconds;

      // Build identity material from the current form selection.
      final identitiesDao = ref.read(identitiesDaoProvider);
      final crud = ref.read(identityCrudProvider);

      String username = 'root';
      String? password;
      List<SSHKeyPair>? keyPairs;
      // The password saved with a key, fetched only where the host does not
      // take the key and asks for a password (3.0, accounts per host).
      Future<String?> Function()? passwordAfterKey;

      // Credentials always come from the effective config's identity (the
      // base identity for the footer test, or a network row's overriding
      // identity for "Test as this network").
      final effectiveIdentityId = cfg.identityKeyId;
      if (effectiveIdentityId != null) {
        final identity = await identitiesDao.getById(effectiveIdentityId);
        if (identity != null) {
          username = identity.username;
          if (identity.authMethod == 'password') {
            password = await crud.getPassword(identity.id);
          } else if (identity.authMethod == 'publicKey' ||
              identity.authMethod == 'certificate') {
            final pem = await crud.getPrivateKey(identity.id);
            if (pem != null) {
              final passphrase = await crud.getKeyPassphrase(identity.id);
              // (A security key's key file signs through the phone, or the
              // system's agent on a computer: fido_key_pair.dart.)
              keyPairs = withSecurityKeySigners(SSHKeyPair.fromPem(pem, passphrase), label: cfg.host.trim());
            }
            if (identity.passwordAfterKey) {
              passwordAfterKey = () => _testPasswordAfterKey(identity.id, cfg);
            }
          } else if (identity.authMethod == kTeamCertificateAuth) {
            // A team certificate (3.0): asked for when there is
            // none, and waited on briefly. What stops it is said as a
            // login says it (it was "an unexpected error").
            try {
              keyPairs = [
                await teamCertificateLogin(ref.read(orchardServiceProvider), ref.read(databaseProvider), identity,
                    wait: const Duration(seconds: 5)),
              ];
            } catch (e) {
              throw ConnectionTestSaid(teamCertificateFailureMessage(gl10n, e, identity.username), e);
            }
          } else if (identity.authMethod == 'passwordManager') {
            // From the person's password manager (3.0), as a
            // connection gets it: the person is watching the test.
            password = await managedPassword(
              identitiesDao.attachedDatabase,
              identity,
              username: identity.username,
              host: host,
              port: port,
              managers: ref.read(passwordManagersProvider),
              asker: PromptedAsker(ref.read),
            );
          }
        }
      }

      // An explicit username from the effective config (a network row that
      // overrides the SSH username) wins over the identity-derived one. Null
      // or empty means "no override" - keep the identity's username (or the
      // 'root' default), preserving the footer test's original behaviour.
      final overrideUsername = cfg.username?.trim();
      if (overrideUsername != null && overrideUsername.isNotEmpty) {
        username = overrideUsername;
      }

      final knownHostsService = ref.read(knownHostsServiceProvider);

      // Keyboard-interactive through the shared answerer: the saved password
      // only for a real password prompt, and a 2FA code or any other server
      // question from the person, who is watching the test. The auth clock
      // stops while they answer.
      final deadline = AuthDeadline.within(kConnectionTestPatience);
      final questionsWithdrawn = Completer<void>();
      final testUsername = username;
      final laterPassword = passwordAfterKey;
      answerer = KeyboardInteractiveAnswerer(
        password: password,
        // The clock stops while it is fetched: that can ask the person.
        passwordAfterKey: laterPassword == null ? null : () => deadline.whileAsking(laterPassword),
        ask: (question) => deadline.whileAsking(
            () => _askServerQuestion(host, port, testUsername, question)),
        withdrawn: questionsWithdrawn.future,
        onServerActive: () => deadline.relax(kServerQuestionPatience),
      );
      // A login banner with a link the sign-in waits on (Tailscale SSH's
      // check) is shown on this screen, as its questions are, and the host
      // is given the time it takes to open it and approve.
      final links = SignInLinkBanners(
        (notice) => _showSignInNotice(host, port, testUsername, notice),
        deadline: deadline,
        withdrawn: questionsWithdrawn.future,
      );

      client = SSHClient(
        sshSocket,
        username: username,
        identities: keyPairs,
        // What a session to this host would offer: with the editor's
        // Compatibility mode switch on, also what an old server needs. (The
        // test offered what a host without the mode is offered whatever the
        // switch said, so turning the switch on, as the test's own tip says
        // to, changed nothing of what the test then said.)
        algorithms: SshService.buildAlgorithms(compatibility: compatibilityMode),
        onPasswordRequest: password != null
            ? () async => password
            // Asked only once the host did not take the key.
            : laterPassword != null
                ? () => sendPasswordAfterKey(answerer!, null)
                : null,
        onUserInfoRequest: answerer.handler,
        onUserauthBanner: links.banner,
        // SECURITY: never transmit the account's real password/key to an
        // UNVERIFIED host. Previously this test disabled host-key
        // verification, so an on-path attacker (public Wi-Fi, ARP/DNS
        // spoof) could present their own key, complete the handshake as a
        // MITM, and harvest the credential the test then sent. We now
        // verify the presented key against known_hosts and accept ONLY an
        // already-trusted match - a one-shot verify that never persists a
        // TOFU entry. A new or changed key fails the test closed, before
        // auth, so no secret ever reaches an unverified server.
        onVerifyHostKey: (type, keyBlob) async {
          final hk = SSHHostKey(type: type, bytes: keyBlob);
          // A team's host: the key its vault pinned, where there is one, as
          // a session goes by it and as an FTPS host's test goes by the
          // pinned certificate. The pinned key is trusted; any other stops
          // the test before anything is sent, whoever asks: a pin is replaced
          // in a connection, which shows both fingerprints. (Without this a
          // member who had never connected to the host, so with no row of
          // their own for it, was asked about another key as about a new
          // host's, and on a yes the test signed in to it: found in a security
          // review.)
          final db = ref.read(databaseProvider);
          final id = hostId;
          if (db.isOrchard && id != null) {
            final team = TeamHostKeys(db);
            final pin = await team.pinFor(host, port, crateId: await team.crateOfHost(id));
            if (pin != null) {
              if (pin.matches(hk)) return true;
              pinnedOther = HostKeyNotAccepted(HostKeyRefusal.pinnedOther,
                  host: host, port: port, crate: await team.crateName(pin.crateId));
              hostKeyUntrusted = true;
              return false;
            }
          }
          // verify() returns a record; comparing the record itself to the
          // enum was always false, so a test against an already-trusted host
          // was refused as if its key were unknown.
          // (The Test shows no notice of where a synced key came from: that
          // is left for the first session, tellsPerson: false.)
          final result = (await knownHostsService.verify(host, port, hk, tellsPerson: false)).result;
          if (result == HostKeyVerifyResult.trusted) return true;
          if (result == HostKeyVerifyResult.newHost) {
            // Untrusted-but-not-changed: show the fingerprint and let the
            // user approve it (same trust decision as a real connect) before
            // any credential is sent. We do NOT persist the trust - a test
            // is one-shot. This keeps testing a brand-new host possible
            // while still never sending creds to an unverified server.
            if (!context.mounted) return false;
            // With the clock stopped, as a real connect asks: reading a
            // fingerprint against the server's takes longer than the 8
            // seconds the server is given, and a test trusted after them
            // failed as "Auth timed out after 8s" (seen in an emulator
            // check).
            final approved = await deadline.whileAsking(() => _confirmHostKey(knownHostsService.getFingerprint(hk)));
            if (approved) return true;
          }
          // New-and-declined, or a CHANGED key (possible MITM): refuse.
          hostKeyUntrusted = true;
          return false;
        },
      );

      // Bound the auth wait - some servers hang on bad creds rather
      // than rejecting cleanly. Time spent answering doesn't count.
      if (!context.mounted) return null;
      try {
        // Its 8 seconds are said as those; a host that was given longer
        // (it asked something, or gave a link to open) as any sign-in that
        // timed out.
        await deadline.wait(links.orCancelled(client.authenticated),
            onTimeout: () => deadline.limit > kConnectionTestPatience
                ? SignInTimedOut(deadline.limit)
                : TimeoutException(l10n.connectionEditAuthTimedOut8s));
      } finally {
        if (!questionsWithdrawn.isCompleted) questionsWithdrawn.complete();
      }

      // A host that is SFTP only: its SFTP is opened and its first folder
      // listed, as a session to it does, and no terminal is asked for. Where
      // that fails the test says why in SFTP's words, with its report.
      if (sftpOnly) {
        try {
          await sftpFirstFolder(client);
        } catch (e, stack) {
          stopwatch.stop();
          final said = sftpStartFailure(e, l10n: l10n);
          return HostTestResult(
            success: false,
            message: said,
            detail: ErrorReport.build(what: said, where: 'Testing a host that is SFTP only', error: e, stack: stack),
          );
        }
      }
      stopwatch.stop();
      final totalMs = stopwatch.elapsedMilliseconds;

      return HostTestResult(
        success: true,
        message: sftpOnly
            ? l10n.connectionTestSftpWorks(tcpMs, totalMs, _jumpNote(l10n, cfg))
            : l10n.connectionEditAuthSuccessResult(tcpMs, totalMs, _jumpNote(l10n, cfg)),
      );
    } on TeamCertificateUnavailable catch (e) {
      stopwatch.stop();
      final user = cfg.identityKeyId == null
          ? ''
          : (await ref.read(identitiesDaoProvider).getById(cfg.identityKeyId!))?.username ?? '';
      return HostTestResult(success: false, message: teamCertificateMessage(l10n, e, user));
    } on SSHAuthFailError catch (e) {
      stopwatch.stop();
      return _failed(l10n, e, cfg);
    } on SSHAuthAbortError catch (e) {
      stopwatch.stop();
      // Another key than the team's pin (the core ends the sign-in with it).
      final pinned = pinnedOther;
      if (pinned != null) return HostTestResult(success: false, message: hostKeyNotAcceptedText(l10n, pinned));
      // Cancelling the server's question ends the test without a verdict.
      return answerer?.cancelled == true ? null : _failed(l10n, e, cfg);
    } on SocketException catch (e) {
      stopwatch.stop();
      return _failed(l10n, e, cfg);
    } on SshPromptCancelled {
      // Cancelled at a login banner's link: no verdict, as for a question.
      stopwatch.stop();
      return null;
    } on SignInTimedOut catch (e) {
      stopwatch.stop();
      return _failed(l10n, e, cfg);
    } on TimeoutException catch (e) {
      stopwatch.stop();
      return HostTestResult(success: false, message: e.message ?? l10n.connectionTimedOut);
    } catch (e) {
      stopwatch.stop();
      final pinned = pinnedOther;
      if (pinned != null) {
        return HostTestResult(success: false, message: hostKeyNotAcceptedText(l10n, pinned));
      }
      if (hostKeyUntrusted) {
        return HostTestResult(success: false, message: l10n.connectionEditHostKeyUntrusted);
      }
      return _failed(l10n, e, cfg);
    } finally {
      try {
        client?.close();
      } catch (_) {}
      try {
        sshSocket?.destroy();
      } catch (_) {}
    }
  }

  /// The password saved with the key [identityId], for a test where the host
  /// did not take the key and asks for a password (3.0, accounts per host),
  /// by the rules a password key's own password goes by in a test: never an
  /// Orchard password this account may not see (3.0), and one from a
  /// Crate that asks again to an address chosen here only once the person
  /// confirms it is them. Otherwise none, and the test says what the
  /// host said of the key.
  Future<String?> _testPasswordAfterKey(String identityId, EffectiveTestConfig cfg) => testPasswordAfterKey(
        mayReveal: () => mayRevealKeyNow(ref, identityId),
        asksAgain: () => revealAsksAgainNow(ref, identityId),
        addressChosenHere: () => addressChosenHere(cfg),
        itIsThem: () async => context.mounted && await confirmItIsYou(context, ref, sending: true),
        read: () => ref.read(identityCrudProvider).getPassword(identityId),
      );

  /// Shows a server's sign-in question (a 2FA code) during a connection test.
  /// The test runs on this screen, so it asks directly instead of through
  /// the session queue.
  Future<List<String>?> _askServerQuestion(
      String host, int port, String username, ServerQuestion question) async {
    if (!context.mounted) return null;
    final request = ServerQuestionRequest(
      host: host,
      port: port,
      username: username,
      question: question,
    );
    unawaited(question.withdrawn.then((_) => request.cancel()));
    await Future.any<void>([
      showServerQuestionDialog(context, request),
      request.answer.then((_) {}),
    ]);
    request.cancel(); // no-op once answered
    return request.answer;
  }

  /// Shows a login banner with a link the test's sign-in waits on
  /// (Tailscale SSH's check) on this screen, as its questions are, until the
  /// sign-in is over or its person cancels; true where they cancel.
  Future<bool> _showSignInNotice(String host, int port, String username, SignInNotice notice) async {
    final request = SignInNoticeRequest(
      host: host,
      port: port,
      username: username,
      notice: notice,
      purpose: SignInNoticeFor.test,
    );
    final show = showSignInNotice;
    if (show != null) return show(request);
    if (!context.mounted) return false;
    await Future.any<void>([
      showSignInLinkDialog(context, request),
      request.cancelled.then((_) {}),
    ]);
    return request.cancelled;
  }

  /// An FTPS host's test (3.4), in three steps, each said with its
  /// time: the port answers (TCP), TLS with the server and the check of its
  /// certificate (no user name, no password: Rust's connect with no login),
  /// and, where [signIn], the sign-in with the user name and password of the
  /// host's key and a listing of its first folder (which needs the passive
  /// data ports: where they are closed, this is where it says so).
  ///
  /// Credentials go only to a server whose certificate is trusted: the one
  /// kept for the host, one an authority vouches for, or a new one the person
  /// accepts for this test alone (not kept: the test is one-shot, as an SSH
  /// host key's). A certificate that is not the one kept fails closed.
  Future<HostTestResult?> _ftpsTest(EffectiveTestConfig cfg, {required bool signIn}) async {
    final l10n = AppLocalizations.of(context)!;
    final host = cfg.host.trim();
    final port = cfg.port;
    final timeout = Duration(seconds: ref.read(connectionTimeoutProvider));
    final stopwatch = Stopwatch()..start();
    try {
      final socket = await openSshSocket(host, port, timeout);
      final tcpMs = stopwatch.elapsedMilliseconds;
      socket.destroy();

      final known = ref.read(knownHostsServiceProvider);
      // A team's host (3.4): the certificate its Crate pinned, where there is
      // one, as a connection goes by it.
      final db = ref.read(databaseProvider);
      final id = hostId;
      final teamPin = db.isOrchard && id != null
          ? await FtpsTeamPins(TeamHostKeys(db), hostId: id).certificatePin(host, port)
          : null;
      final pinned = teamPin?.certificateSha256 ?? await known.pinnedCertificate(host, port);
      final probe = FtpsConnectOptions(host: host, port: port, username: '', password: '', implicitTls: ftpsImplicit, timeout: timeout);
      var trustedHere = pinned;
      var certificateNew = false;
      final tlsStart = stopwatch.elapsedMilliseconds;
      try {
        await FtpsClient.probeTls(probe, pinnedSha256: pinned, native: ftpsNative);
      } on FtpsException catch (e) {
        final shown = e.certificate;
        if (e.kind != FtpsErrorKind.certificate || shown == null) rethrow;
        if (pinned != null) {
          // Not the one kept for the host: nothing is sent; a connection
          // shows both fingerprints and asks.
          return HostTestResult(success: false, message: l10n.ftpsTestCertificateNotKept);
        }
        certificateNew = true;
        if (signIn) {
          if (!context.mounted) return null;
          if (!await _confirmCertificate(host, port, shown.fingerprint)) {
            return HostTestResult(success: false, message: l10n.connectionEditHostKeyUntrusted);
          }
          trustedHere = shown.sha256;
        }
      }
      final tlsMs = stopwatch.elapsedMilliseconds - tlsStart;
      if (!signIn) {
        return HostTestResult(
          success: true,
          message: certificateNew ? l10n.ftpsTestReachableNewCertificate(tcpMs, tlsMs) : l10n.ftpsTestReachable(tcpMs, tlsMs),
        );
      }

      // The user name and password of the host's key.
      String? username = cfg.username?.trim();
      String? password;
      final keyId = cfg.identityKeyId;
      if (keyId != null) {
        final identity = await ref.read(identitiesDaoProvider).getById(keyId);
        if (identity != null) {
          if (username == null || username.isEmpty) username = identity.username;
          if (identity.authMethod == 'password') {
            password = await ref.read(identityCrudProvider).getPassword(identity.id);
          } else if (identity.authMethod == 'passwordManager') {
            password = await managedPassword(
              ref.read(identitiesDaoProvider).attachedDatabase,
              identity,
              username: identity.username,
              host: host,
              port: port,
              managers: ref.read(passwordManagersProvider),
              asker: PromptedAsker(ref.read),
            );
          }
        }
      }
      if (username == null || username.isEmpty || password == null) {
        return HostTestResult(success: false, message: l10n.connectionEditAuthFtps);
      }
      final client = await FtpsClient.connect(
        FtpsConnectOptions(
            host: host, port: port, username: username, password: password, implicitTls: ftpsImplicit, timeout: timeout),
        pinnedSha256: trustedHere,
        // A certificate accepted for this test alone, and no other.
        allowAuthority: !certificateNew,
        native: ftpsNative,
      );
      try {
        await client.list(client.home);
      } finally {
        await client.close();
      }
      stopwatch.stop();
      return HostTestResult(
        success: true,
        message: l10n.ftpsTestWorks(tcpMs, tlsMs, stopwatch.elapsedMilliseconds, _jumpNote(l10n, cfg)),
      );
    } on TimeoutException {
      // The socket's own clock, as the SSH reachability test says it.
      stopwatch.stop();
      return HostTestResult(success: false, message: l10n.connectionTimedOut);
    } catch (e) {
      // What a failed connection says of it, with its report behind "Copy details": an
      // FTPS host's own failures in FTPS's words (connectionFailureText, ftpsFailureText),
      // a socket's as SSH's.
      stopwatch.stop();
      return _failed(l10n, e, cfg);
    }
  }

  /// The Test of a remote screen (4.0): reachability, with no VNC password
  /// sent. Through its carrier ([EffectiveTestConfig.jumpChain]'s one SSH
  /// host): the carrier signed in as a screen's is, the channel to the
  /// screen's address and port, or its socket ([screenSocket]), opened on it,
  /// and the VNC server's greeting read (its version and the security types it
  /// offers), then closed before a type is chosen. Directly: the socket, the
  /// greeting and VeNCrypt's subtypes, stopped before TLS (the certificate is
  /// checked, and asked about, when connecting). A screen of a watched Crate,
  /// or one through a watched Crate's SSH host, is not tested, as it is not
  /// connected to.
  Future<HostTestResult?> screenTest(EffectiveTestConfig cfg, {VoidCallback? onStarted}) async {
    final l10n = AppLocalizations.of(context)!;
    final carrierId = cfg.jumpChain.isEmpty ? null : cfg.jumpChain.first;
    final address = cfg.host.trim();
    final socket = carrierId == null ? null : screenSocket?.trim();
    final unix = socket != null && socket.isNotEmpty;
    if (!unix) {
      if (carrierId == null && address.isEmpty) return HostTestResult(success: false, message: l10n.connectionHostRequired);
      if (cfg.port < 1 || cfg.port > 65535) return HostTestResult(success: false, message: l10n.connectionPortInvalid);
    }
    final db = ref.read(databaseProvider);
    // The team's rule "through an SSH host only": a screen that connects
    // directly is not dialled by the Test either (ZS-1821).
    if (carrierId == null && (await screenTeamRules(db)).sshOnly) {
      return HostTestResult(
          success: false,
          message: screenFailureText(l10n, const ScreenFailure(ScreenFailureKind.teamSshOnly, 'screens_ssh_only')));
    }
    if (await wouldGoUnwatched(db, hostId: hostId)) {
      return HostTestResult(success: false, message: l10n.watchedNoTest);
    }
    Connection? carrier;
    if (carrierId != null) {
      carrier = await db.connectionsDao.getById(carrierId);
      if (carrier == null || !screenCarrierKind(carrier.protocol)) {
        return HostTestResult(success: false, message: l10n.screenCarrierGone);
      }
      if (await wouldGoUnwatched(db, hostId: carrier.id, keyId: carrier.identityId)) {
        return HostTestResult(success: false, message: l10n.watchedNoTest);
      }
      try {
        await requireCratesOpen(db, hostId: carrier.id, keyId: carrier.identityId);
      } on CrateClosedOffline catch (e) {
        return HostTestResult(success: false, message: e.message);
      }
    }
    if (!context.mounted) return null;
    onStarted?.call();
    final timeout = Duration(seconds: ref.read(connectionTimeoutProvider));
    final stopwatch = Stopwatch()..start();
    final shownAddress = Redactable.address(unix
            ? socket
            : hostWithPort(address.isEmpty ? 'localhost' : address, cfg.port))
        .display;
    try {
      if (carrier == null) {
        final channel = await (openScreenDirect ?? openDirectScreenSocket)(address, cfg.port, timeout);
        try {
          if (screenRdp) {
            final answer = await readRdpAnswer(channel, nla: screenRdpNla, timeout: timeout);
            return _rdpAnswered(l10n, answer, () => l10n.screenTestRdpReachableDirect(stopwatch.elapsedMilliseconds));
          }
          final g = await readRfbGreeting(channel, vencrypt: true, timeout: timeout);
          final ms = stopwatch.elapsedMilliseconds;
          final subtypes = g.vencryptSubtypes;
          if (subtypes == null || !g.vencryptTaken) {
            final offered = subtypes == null
                ? g.securityTypes.map(rfbSecurityName).join(', ')
                : 'VeNCrypt (${subtypes.map(vencryptSubtypeName).join(', ')})';
            return HostTestResult(
                success: false,
                message: ErrorCodes.withCode(l10n.screenTestNoTls(offered), ErrorCodes.screenNoSecurity));
          }
          return HostTestResult(
            success: true,
            message: l10n.screenTestReachableDirect(
                ms, g.version, subtypes.where(vencryptSubtypesTaken.contains).map(vencryptSubtypeName).join(', ')),
          );
        } finally {
          await _closeQuietly(channel);
        }
      }
      final name = Redactable.host(carrier.label.isNotEmpty ? carrier.label : hostWithPort(carrier.host, carrier.port)).display;
      final target = unix ? UnixSocketTarget(socket) : TcpTarget(address.isEmpty ? 'localhost' : address, cfg.port);
      final open = openScreenRoute ?? ref.read(activeSessionsProvider.notifier).openScreenProbe;
      final route = await open(carrier, target);
      final sshMs = stopwatch.elapsedMilliseconds;
      try {
        final channel = await route.open();
        try {
          if (screenRdp) {
            final answer = await readRdpAnswer(channel, nla: screenRdpNla, timeout: timeout);
            return _rdpAnswered(
                l10n,
                answer,
                () => l10n.screenTestRdpReachable(
                    name, sshMs, shownAddress, stopwatch.elapsedMilliseconds - sshMs));
          }
          final g = await readRfbGreeting(channel, timeout: timeout);
          final vncMs = stopwatch.elapsedMilliseconds - sshMs;
          final offered = g.securityTypes.map(rfbSecurityName).join(', ');
          if (!g.offersOneTaken) {
            return HostTestResult(
                success: false,
                message: ErrorCodes.withCode(l10n.screenTestNothingTaken(offered), ErrorCodes.screenNoSecurity));
          }
          return HostTestResult(
            success: true,
            message: l10n.screenTestReachable(name, sshMs, shownAddress, g.version, vncMs, offered),
          );
        } finally {
          await _closeQuietly(channel);
        }
      } finally {
        await route.close();
      }
    } on RfbNotVnc catch (e) {
      return HostTestResult(success: false, message: l10n.screenTestNotVnc(shownAddress), detail: 'answered: ${e.said}');
    } on RdpNotRdp catch (e) {
      return HostTestResult(success: false, message: l10n.screenTestRdpNotRdp(shownAddress), detail: 'answered: ${e.said}');
    } on RfbRefused catch (e) {
      return HostTestResult(success: false, message: l10n.screenTestTurnedAway(e.reason));
    } on TimeoutException {
      return HostTestResult(success: false, message: l10n.connectionTimedOut);
    } catch (e) {
      // What a screen that does not open says (ZS-1801, ZS-1802, ZS-1806),
      // and the carrier's own sign-in failures in SSH's words.
      return _failed(l10n, screenRdp && e is ScreenFailure ? e.asRdp() : e, cfg);
    } finally {
      stopwatch.stop();
    }
  }

  /// What an RDP server's answer to the connection request means for this
  /// host: reachable ([reachable], its sentence) where it takes the host's way
  /// of signing in; else what a session would say, in the same words and with
  /// the same code (ZS-1813, ZS-1814), so that the editor's switch can be
  /// turned before the first connection.
  HostTestResult _rdpAnswered(AppLocalizations l10n, RdpAnswer answer, String Function() reachable) {
    final setting = l10n.connectionEditRdpWithoutNla;
    HostTestResult nlaMissing() => HostTestResult(
        success: false,
        message: ErrorCodes.withCode(l10n.screenRdpNlaMissing(setting), ErrorCodes.screenRdpNlaMissing));
    HostTestResult nlaRequired() => HostTestResult(
        success: false,
        message: ErrorCodes.withCode(l10n.screenRdpNlaRequired(setting), ErrorCodes.screenRdpNlaRequired));
    final failure = answer.failure;
    if (failure != null) {
      return switch (failure) {
        1 => nlaMissing(),
        5 || 6 => nlaRequired(),
        2 => HostTestResult(success: false, message: l10n.screenTestRdpNoTls),
        _ => HostTestResult(success: false, message: l10n.screenTestRdpRefused(failure)),
      };
    }
    final selected = answer.selected;
    // No answer about security, or RDP's own old encryption: a server
    // without TLS, which the app never talks to.
    if (selected == null || selected == 0) return HostTestResult(success: false, message: l10n.screenTestRdpNoTls);
    if (screenRdpNla) return answer.nla ? HostTestResult(success: true, message: reachable()) : nlaMissing();
    return selected == 1 ? HostTestResult(success: true, message: reachable()) : nlaRequired();
  }

  Future<void> _closeQuietly(ScreenChannel channel) async {
    try {
      await channel.output.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Closing what is gone already.
    }
  }

  /// Asks whether to go on with a test to [host]:[port], whose certificate
  /// ([fingerprint], as openssl prints it) no authority vouches for and none
  /// is kept: the certificate question's words. Not kept; the test is one-shot.
  Future<bool> _confirmCertificate(String host, int port, String fingerprint) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await showZestModal<bool>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.fileBadge,
          title: l10n.ftpsNewCertificateTitle,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.ftpsFirstConnection(Redactable.address(host).display, port),
                style: const TextStyle(fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 12),
              SelectableText(
                Redactable.fingerprint(fingerprint).display,
                key: const ValueKey('host-test-fingerprint'),
                style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
              ),
            ],
          ),
          secondaryKey: const ValueKey('host-test-cancel'),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(ctx).pop(false)),
          primaryKey: const ValueKey('host-test-trust'),
          primaryAction: (
            label: l10n.connectionEditTrustAndTest,
            icon: null,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ),
      ),
    );
    return ok ?? false;
  }

  /// Ask the user to trust an as-yet-unknown host key during a connection
  /// test - shows the SHA256 fingerprint. Returns true to proceed. Does NOT
  /// persist the trust; the test is one-shot.
  Future<bool> _confirmHostKey(String fingerprint) async {
    final l10n = AppLocalizations.of(context)!;
    // The app's dialog (the dialog rules, 3.4); closed without an answer
    // (Escape, outside it) is not trusted.
    final ok = await showZestModal<bool>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.keyRound,
          title: l10n.connectionEditUnknownHostKey,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.connectionEditUnknownHostKeyBody,
                style: const TextStyle(fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 12),
              SelectableText(
                Redactable.fingerprint(fingerprint).display,
                key: const ValueKey('host-test-fingerprint'),
                style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12),
              ),
            ],
          ),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(ctx).pop(false)),
          primaryKey: const ValueKey('host-test-trust'),
          primaryAction: (
            label: l10n.connectionEditTrustAndTest,
            icon: null,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ),
      ),
    );
    return ok ?? false;
  }
}

/// Whether a test from the host editor sends the password saved with a key
/// to a host that did not take the key (3.0, accounts per host), by the
/// rules a password key's own password goes by in a test, and the password
/// where it does: never an Orchard password this account may not see
/// ([mayReveal], 3.0); one from a Crate that asks again
/// ([asksAgain]) to an address chosen here ([addressChosenHere]) only once
/// the person confirms it is them ([itIsThem]). [read] reads it, and
/// only where it may go.
Future<String?> testPasswordAfterKey({
  required Future<bool> Function() mayReveal,
  required Future<bool> Function() asksAgain,
  required Future<bool> Function() addressChosenHere,
  required Future<bool> Function() itIsThem,
  required Future<String?> Function() read,
}) async {
  if (!await mayReveal()) return null;
  if (await asksAgain() && await addressChosenHere() && !await itIsThem()) return null;
  return read();
}

/// What a connection test of the editor says of what it failed with ([e]),
/// and the report of it for "Copy details".
///
/// It says what a failed connection says of the same failure
/// ([connectionFailureText], [ConnectionError.translate]): what went wrong
/// and, after it, what to try, for [host], [port] and [username]. So a
/// sign-in the host refused is said by what was tried and what the host
/// takes; one that was cut off, by what cut it off (what the host said
/// when it ended the connection, a group too short for the key exchange, a
/// key the host could not prove to be its own, a packet that did not pass
/// its check, nothing in common for the key exchange, a network that
/// broke); and a connection that could not be made, by why. One thing is
/// the editor's own: where its own check of the host's key answered no
/// (the key is not trusted on this device and was not approved for the
/// test), it says that, and has no report, since nothing failed. (Of a
/// host it has nothing in common with it says what a failed connection
/// says, by what the test offered: the tip to turn Compatibility mode on
/// where that would add something the host offers, and what the host
/// offers where it would not, as where the editor's switch is on.)
///
/// (The editor had words of its own for most of this: "Auth rejected by
/// server: All authentication methods failed" of every sign-in a host
/// refused, "Auth aborted: Connection closed before authentication" of
/// whatever cut a sign-in off that it had no sentence for, and what the
/// system says, in the system's language, of a port that nothing listens
/// on. And behind "Copy details" it kept one line, or nothing.)
@visibleForTesting
({String message, String? report}) connectionTestFailed(
  AppLocalizations l10n,
  Object e, {
  String? host,
  int? port,
  String? username,
  bool? onAComputer,
}) {
  if (e is SSHAuthAbortError) {
    final reason = e.reason;
    if (reason is SSHHostkeyError && !_refusedByTheCore(reason)) {
      return (message: l10n.connectionEditHostKeyUntrusted, report: null);
    }
  }
  final shown = ConnectionError.translate(
    connectionFailureText(e),
    host: host,
    port: port,
    username: username,
    onAComputer: onAComputer,
  );
  final tip = shown.tip;
  final message = tip == null ? shown.description : '${shown.description}\n\n$tip';
  return (
    message: message,
    report: ErrorReport.build(
      what: message,
      where: 'Testing a connection from the host editor',
      // Behind what the app said itself: what it was told.
      error: e is ConnectionTestSaid ? e.cause : e,
      details: 'Kind: ${shown.type.name}',
    ),
  );
}

/// Whether the SSH core refused the host's key by itself: it says what was
/// wrong with the key, or that it was at new keys. (The test's own check
/// answers no, and the core then says neither.)
bool _refusedByTheCore(SSHHostkeyError e) => e.fault != null || e.duringRekey;

/// What stopped a connection test, in words the app itself wrote for the
/// person: shown as they are ([saidByApp]), as a failed login shows them,
/// with what was caught behind them in the report ([connectionTestFailed]).
@visibleForTesting
class ConnectionTestSaid implements Exception, HasTypeName {
  const ConnectionTestSaid(this.message, this.cause);

  final String message;

  /// What was caught, for the details.
  final Object cause;

  @override
  String toString() => saidByApp(message);

  @override
  String get typeName => 'ConnectionTestSaid';
}
