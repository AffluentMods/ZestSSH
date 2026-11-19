import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process;

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:xterm/xterm.dart';
import 'package:zestssh/services/review_prompt.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/activity/activity_notes.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart' show ShareTerminal;
import 'package:zestssh/features/sharing/share_messages.dart' show ShareScreen;
import 'package:zestssh/features/sharing/terminal_snapshot.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/password_manager_requests.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/port_forward_messages.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/jump_host_gate_notice.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_folder_providers.dart';
import 'package:zestssh/services/settings_service.dart' show terminalScrollbackLines;
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/utils/shell_fill.dart';
import 'package:zestssh/providers/ssh_cert_providers.dart';
import 'package:zestssh/features/broadcast/typed_line.dart';
import 'package:zestssh/models/work_tab.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/hardware_token/os_agent_key_pair.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart' show SshCertificate;
import 'package:zestssh/services/ssh_cert/ssh_certificate_keypair.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/services/demo_shell_service.dart';
import 'package:zestssh/services/local_shell_service.dart';
import 'package:zestssh/services/eternal_terminal_service.dart';
import 'package:zestssh/services/mosh/builtin_mosh_service.dart';
import 'package:zestssh/services/mosh/mosh_bootstrap.dart';
import 'package:zestssh/services/mosh_service.dart';
import 'package:zestssh/services/shell_client_missing.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/reconnect_cannot_help.dart';
import 'package:zestssh/config/feature_flags.dart';
import 'package:zestssh/services/worker/worker_protocol.dart';
import 'package:zestssh/services/worker/worker_ssh_service.dart';
import 'package:zestssh/services/foreground_service.dart';
import 'package:zestssh/features/command_history/command_capture.dart';
import 'package:zestssh/features/command_history/history_suggester.dart';
import 'package:zestssh/features/command_history/autocomplete_sources.dart';
import 'package:zestssh/features/command_history/shell_integration_parser.dart';
import 'package:zestssh/features/terminal/osc52_clipboard.dart';
import 'package:zestssh/features/tmux/tmux_inband_watcher.dart';
import 'package:zestssh/features/hosts/pending_files.dart';
import 'package:zestssh/features/hosts/state/kex_refused_hosts.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform;
import 'package:zestssh/services/port_forward_service.dart';
import 'package:zestssh/services/session_transcript_service.dart';
import 'package:zestssh/services/session_log_service.dart';
import 'package:zestssh/services/serial_service.dart';
import 'package:zestssh/services/telnet_service.dart';
import 'package:zest_native/ftps.dart' show FtpsConnectOptions, FtpsException;
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zest_native/screen.dart' show ScreenChannel, ScreenNative, ScreenProtocol;
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/session/rdp_account.dart';
import 'package:zestssh/features/screens/model/rdp_gateway_offered.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_gateway_route.dart';
import 'package:zestssh/features/screens/session/screen_probe.dart' show ScreenProbeRoute, SshScreenProbeRoute;
import 'package:zestssh/features/screens/session/screen_clipboard.dart' show screenClipboardOnFor;
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_console.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_guest_of.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart' show CloudField, cloudAccountStoreProvider;
import 'package:zestssh/features/cloud_import/cloud_machine.dart' show CloudProvider;
import 'package:zestssh/features/cloud_import/cloud_scans.dart' show proxmoxBase, proxmoxTokenValue;
import 'package:zestssh/features/screens/session/screen_team_rules.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart' show xProgramName;
import 'package:zestssh/features/screens/session/screen_trust.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/ui/widgets/broadcast_dangerous_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/connection_error_view.dart' show connectionFailureReport;
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/services/os_detection_service.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/error_translator.dart' as translator
    show ConnectionError, ConnectionErrorType, compatibilityModePlace, saidByApp, withKeysPassedOver, withSignInWays;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/leftover_copies.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/router/router.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/features/orchards/certs/team_certificate_login.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardServiceProvider;
import 'package:zestssh/features/orchards/orchard_service.dart'
    show ActivityKind, OrchardService, ScreenSessionLogLines, TeamCertificateUnavailable, screenLogKind;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/confirmed_destinations.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline, requireCratesOpenIn;
import 'package:zestssh/features/orchards/rules/reveal_gate.dart' show askConfirmItIsYou;
import 'package:zestssh/features/orchards/session_spaces.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart' show teamMayNotOpenWith;
import 'package:zestssh/features/orchards/team_host_commands.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/watch_gate.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/run/run_client.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/utils/utf8_chunks.dart';
import 'package:zestssh/utils/wsl_key_file.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/l10n/time_text.dart';
import 'package:zestssh/services/fido/fido_key_pair.dart';
import 'package:zestssh/services/fido/fido_words.dart';
import 'package:zestssh/providers/output_batch.dart';

// Whether a try is worth making again is asked here, of a session that
// dropped, and by Server Monitor: the rule has one home.
export 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart' show TeamPinPrompt;
export 'package:zestssh/services/reconnect_cannot_help.dart' show reconnectCannotHelp;

/// Thrown when the user cancels a connection prompt (password, host key, etc.)
/// to abort the entire connection flow gracefully.
class ConnectionCancelledException implements Exception, HasTypeName {
  @override
  String toString() => 'Connection cancelled by user';

  @override
  String get typeName => 'ConnectionCancelledException';
}

/// Thrown when SSH authentication fails in a way we can explain to the user
/// (e.g. key not found, wrong passphrase, server rejected all auth methods).
class SSHAuthFailedException implements Exception, HasTypeName {
  final String message;

  /// For a login that could get no team certificate where an owner can
  /// sign one directly: the Crate that takes it, so that whatever shows
  /// the failure can offer that (certificateFromOwnerOfferProvider).
  final ({String orchardId, String crateId})? handover;

  const SSHAuthFailedException(this.message, {this.handover});
  @override
  String toString() => message;

  @override
  String get typeName => 'SSHAuthFailedException';
}

/// What stops the sign-in of a run with nobody there (automation, 3.0): a
/// key not allowed for unattended runs, or what only a person could answer
/// (a password, a key's passphrase, a server's own question). Said as its
/// [message], as a sign-in that failed is; a task counts it as a run that
/// needs credentials.
class UnattendedSignInStopped extends SSHAuthFailedException {
  const UnattendedSignInStopped(super.message);

  @override
  String get typeName => 'UnattendedSignInStopped';
}

/// [error], which came up at a jump host while [stage] was being done, as a
/// failure of that jump host. What is no failure of a jump host passes as it
/// is: the person cancelling a question, what the app refuses by itself (an
/// Orchard's rules, a Crate closed on this device), a jump host that nobody
/// is there to give its sign-in details where the app connects by itself
/// ([NotSilentlyPollableException]), and a failure of a jump host further
/// out, which has its name already.
Object jumpHostFailureOf(
  Object error, {
  required String label,
  required String host,
  required int port,
  String? username,
  required JumpStage stage,
  String? onward,
}) {
  if (error is JumpHostFailure ||
      error is ConnectionCancelledException ||
      error is SshPromptCancelled ||
      error is OrchardAccessRefused ||
      error is CrateClosedOffline ||
      error is NotSilentlyPollableException) {
    return error;
  }
  return JumpHostFailure(
    label: label,
    host: host,
    port: port,
    username: username,
    stage: stage,
    cause: error,
    onward: onward,
  );
}

/// What is said of a jump host that failed: which it was, what it failed at,
/// and why, in the words the same failure of a host has, with the jump
/// host's own address in them.
String jumpHostFailureText(AppLocalizations l10n, JumpHostFailure f) {
  final cause = f.cause;
  final next = f.onward ?? '';
  if (f.stage == JumpStage.onward && cause is SSHChannelOpenError) {
    // 1: it will not pass connections on. 2: it tried, and could not.
    if (cause.code == 1) return l10n.jumpHostForwardRefused(f.label, next);
    final said = shownHostText(cause.description);
    if (cause.code == 2 && said.isNotEmpty) return l10n.jumpHostCannotReachNext(f.label, next, said);
  }
  // It ended the connection itself, saying why: its words, as the jump host's.
  final ended = hostEndedText(l10n, cause, jumpHost: f.label);
  if (ended != null) return ended;
  final why =
      translator.ConnectionError.translate(connectionFailureText(cause), host: f.host, port: f.port, username: f.username)
          .description;
  return switch (f.stage) {
    JumpStage.details => l10n.jumpHostNoDetails(f.label, why),
    JumpStage.reach => l10n.jumpHostNotReached(f.label, why),
    JumpStage.signIn => l10n.jumpHostNoSignIn(f.label, why),
    JumpStage.onward => l10n.jumpHostNoWayOn(f.label, next, why),
  };
}

/// What is said of why the connection to [name] ended, by [cause], which
/// is the reason of that connection itself ([endReasonOf],
/// [hostClosedConnection]): [name] is a host, or the jump host whose
/// connection it was. [keyFailed] is what is said where its key failed
/// when new keys were taken.
({String sentence, String? tip}) connectionEndSaid(
  AppLocalizations l10n,
  String? cause,
  String name, {
  required String keyFailed,
}) {
  if (cause == hostClosedConnection) return (sentence: l10n.connectionLostByHost(name), tip: null);
  if (cause == hostStoppedAnswering) {
    return (sentence: l10n.connectionLostNoAnswer(name), tip: l10n.connectionLostNoAnswerTip);
  }
  // What came from it did not pass its check: said as that, with what it can mean.
  if (cause == hostDataDamaged) {
    return (sentence: l10n.connectionLostDamaged(name), tip: l10n.connectionLostDamagedTip);
  }
  // Its key failed when new keys were taken: said as that, with what to do.
  if (cause == hostKeyFailedAtNewKeys) return (sentence: keyFailed, tip: null);
  // It ended the connection itself, and said why: its own words, as its own.
  final said = hostSaid(cause);
  if (said != null) return (sentence: l10n.connectionLostHostSaid(name, said), tip: null);
  if (cause != null) {
    final translated = translator.ConnectionError.translate(cause);
    if (translated.type == translator.ConnectionErrorType.networkError ||
        translated.type == translator.ConnectionErrorType.timeout) {
      return (sentence: l10n.connectionLostNetwork(name), tip: translated.tip);
    }
  }
  return (sentence: l10n.connectionLostEnded(name), tip: null);
}

/// What is said of a jump host whose connection ended while the host
/// behind it was being connected to ([JumpHostEndedOnTheWay]): that, and
/// why its connection ended, in the words a session that dropped has for
/// the same end ([connectionEndSaid]).
String jumpHostEndedOnTheWayText(AppLocalizations l10n, JumpHostEndedOnTheWay e) {
  final cause = e.cause;
  final why = connectionEndSaid(
    l10n,
    cause == null ? hostClosedConnection : endReasonOf(cause),
    e.label,
    keyFailed: l10n.connJumpHostKeyFailedAtNewKeys(e.label),
  ).sentence;
  return '${l10n.jumpHostEndedOnTheWay(e.label)} $why';
}

/// Whether [e], which dialling a jump host failed with, is a failure that
/// the end of an earlier jump host's connection brings about: reaching
/// it, signing in to it and its way on all go over the jump hosts before
/// it. Its sign-in details are read on this device, and a question that
/// its person closed is their own doing: neither is.
@visibleForTesting
bool failedOverEarlierJumpHosts(Object e) => e is JumpHostFailure && e.stage != JumpStage.details;

/// Of the jump hosts that were signed in to ([clients], in the order they
/// were dialled, called by [labels]): the first whose connection has ended
/// by itself, as what connecting on through it failed with ([during] is
/// what it failed with as far as the next one on the way knows). Null
/// where none has. Asked before any of them is closed.
Future<JumpHostEndedOnTheWay?> _jumpHostEndedWhileDialling(
  List<SSHClient> clients,
  List<String> labels,
  Object during,
) async {
  for (var i = 0; i < clients.length; i++) {
    if (!clients[i].isClosed) continue;
    final cause = await clients[i].done.then<Object?>((_) => null, onError: (Object error) => error);
    return JumpHostEndedOnTheWay(label: labels[i], cause: cause, during: during);
  }
  return null;
}

/// What a login with the team certificate key [identity] (in the Orchard
/// database [db]) connects with: this device's key with a certificate from
/// the key's Crate. What keeps it from one is thrown as the app's own words
/// for it ([SSHAuthFailedException]), with the Crate an owner can sign one
/// for directly where that gets around it ([teamCertificateFailure]): never
/// a password prompt instead, and never "could not be reached" for whatever
/// went wrong.
Future<SSHKeyPair> teamCertificateSignIn(
  OrchardService service,
  AppDatabase db,
  Identity identity, {
  void Function(String line)? onLog,
}) async {
  try {
    return await teamCertificateLogin(service, db, identity, onLog: onLog);
  } catch (e) {
    onLog?.call(e is TeamCertificateUnavailable
        ? 'identity: No team certificate (${e.problem.name})'
        : 'identity: ERROR getting a team certificate - $e');
    final failed = await teamCertificateFailure(gl10n, e, db, identity);
    throw SSHAuthFailedException(failed.message, handover: failed.handover);
  }
}

/// [e] as a failed connection keeps it for the screens that show it: what
/// the app itself wrote for the person ([SSHAuthFailedException],
/// [HostSkippedOnNetworkException], what an Orchard's rules refuse:
/// [OrchardAccessRefused], a Crate closed on this device:
/// [CrateClosedOffline], jump hosts that cannot be followed:
/// [JumpChainBroken], and a host that gave Server Monitor no figures:
/// [MonitorNoFigures]) is marked as that, so that it is shown as it is
/// and not taken for a library's error text. So is what the app says of a
/// host that signed the person in and then started no session
/// ([SshNoSessionException], [noSessionText]): the library's own text for
/// that ("Failed to start pty") was shown as an unexpected error. And so is
/// what a host said when it ended the connection ([hostEndedText]), and
/// what is said of a jump host whose connection ended while the host
/// behind it was being connected to ([jumpHostEndedOnTheWayText]).
String connectionFailureText(Object e) {
  if (e is JumpHostFailure) return translator.saidByApp(jumpHostFailureText(gl10n, e));
  if (e is JumpHostEndedOnTheWay) return translator.saidByApp(jumpHostEndedOnTheWayText(gl10n, e));
  final ended = hostEndedText(gl10n, e);
  if (ended != null) return translator.saidByApp(ended);
  // A host's key that was not accepted: nothing was sent to the host, and
  // the server closed nothing.
  final unaccepted = hostKeyNotAccepted(e);
  if (unaccepted != null) return translator.saidByApp(hostKeyNotAcceptedText(gl10n, unaccepted));
  // A sign-in that ended with its connection is said as what ended the
  // connection, where that is known: a network that broke, a key exchange
  // that found nothing in common, a server that is none. (Each was "the
  // server closed the connection before completing login": the error of a
  // sign-in that was cut off does not print why.) Not a server that ended
  // the connection with a message and no words in it, which did close it.
  if (e is SSHAuthAbortError) {
    final reason = e.reason;
    if (reason != null && reason is! SSHDisconnectError) {
      return connectionFailureText(reason);
    }
  }
  // An FTPS host's connection (3.4): a server without TLS, a refused sign-in,
  // no answer in time, or what the server or the library said.
  if (e is FtpsException) return translator.saidByApp(ftpsFailureText(gl10n, e));
  // A remote screen's (4.0): nothing at its address, forwarding refused, its
  // password, its security or certificate, its socket (ZS-1801 to ZS-1806).
  if (e is ScreenFailure) return translator.saidByApp(screenFailureText(gl10n, e));
  return switch (e) {
    // A sign-in that the server refused, with what was tried and what the
    // server takes, where it said: whatever shows it says which it was.
    SSHAuthFailError(
      :final methodsTried,
      :final serverTakes?,
      :final keysPassedOver,
      :final serverSignatureAlgorithms
    ) =>
      translator.withSignInWays(
        // (And the keys that were not offered at all, where there are any.)
        translator.withKeysPassedOver('$e', keysPassedOver, serverSignatureAlgorithms),
        methodsTried,
        serverTakes,
      ),
    // The app ended the sign-in itself: on Windows the agent's pipe is served
    // by another account's program, so nothing was asked of it.
    AgentSignInAborted(pipeNotYours: true) =>
      translator.saidByApp(ErrorCodes.withCode(gl10n.agentPipeNotYours, ErrorCodes.agentPipeNotYours)),
    // The app ended the sign-in itself: the agent or hardware key that holds
    // its key did not sign.
    AgentSignInAborted(:final keyNotLoaded) =>
      translator.saidByApp(keyNotLoaded ? gl10n.connAgentKeyNotLoaded : gl10n.connAgentCouldNotSign),
    // The app ended the sign-in itself: the security key held to the phone
    // or plugged into it did not sign.
    FidoSignInAborted(:final failure) => translator.saidByApp(fidoSignInEndedText(gl10n, failure)),
    // A key that is on a security key was asked to sign with nobody there
    // to hold the key (a task that runs by itself).
    SSHKeyOnSecurityKeyError() => translator.saidByApp(gl10n.fidoKeyOnSecurityKey),
    // The SSH core held back the signature a key of the app's own made: it
    // was not the key's own (a key file whose numbers do not fit each
    // other). Nothing was sent to the host with that key.
    SSHKeySignError() => translator.saidByApp(gl10n.connKeyCouldNotSign),
    SshNoSessionException(:final kind) => translator.saidByApp(noSessionText(gl10n, kind)),
    // The host named a group too short for the key exchange: with both
    // lengths, and what would mend it. Where Compatibility mode takes such
    // a group and was not on, the host offers only an outdated key
    // exchange: said as that, with the switch and where it is, and that it
    // is not recommended and only for an old server that cannot be
    // updated. (A group that is none for another reason is said as the SSH
    // core says it, in the details.)
    SSHKexGroupError(tooShort: true, :final bits, :final shortestTaken) => translator.saidByApp(
        compatibilityModeTakesGroup(e)
            ? gl10n.connKexGroupOutdated(bits, shortestTaken, translator.compatibilityModePlace(gl10n))
            : gl10n.connKexGroupTooShort(bits, shortestTaken)),
    // What came from the host under keys did not pass its check: said as
    // that, with the two things it can mean and what tells them apart. (It
    // was an error "during the SSH handshake", with a word about the
    // host's SSH version.)
    SSHPacketError(damaged: true) => translator.saidByApp(gl10n.connPacketDamaged),
    // The host broke the order of the strict key exchange it had named:
    // said as that, with the two things it can be.
    SSHHandshakeError(strictOrderBroken: true) => translator.saidByApp(gl10n.connStrictOrderBroken),
    // The host sent its version and then nothing of the key exchange: said
    // as that, with what does it (a firewall that inspects SSH) and the
    // switch that may get through. (It waited for the sign-in to run out of
    // time, and said that.)
    SSHHandshakeError(kexUnanswered: true) =>
      translator.saidByApp(gl10n.connKexUnanswered(translator.compatibilityModePlace(gl10n))),
    // A key exchange with no algorithm of one kind in common: with what
    // each side offered of it, and what Compatibility mode would add, so
    // that whatever shows it says what there is to do, and whoever reads
    // its details sees what the host wants.
    SSHHandshakeError(nothingInCommon: true) => nothingInCommonText(e),
    // A Mosh or Eternal Terminal host whose client is not here: what is
    // missing and how to install it (it was an unexpected error).
    ShellClientMissing() => translator.saidByApp(shellClientMissingText(gl10n, e)),
    // The built-in Mosh client (4.0): mosh-server did not start on the host
    // (not installed, no UTF-8 locale, something else it said), or nothing
    // answered over UDP (the firewall, with the ports to open).
    MoshStartFailure() => translator.saidByApp(moshStartFailureText(gl10n, e)),
    MoshSessionFailure() => translator.saidByApp(moshSessionFailureText(gl10n, e)),
    SSHAuthFailedException() ||
    HostSkippedOnNetworkException() ||
    OrchardAccessRefused() ||
    CrateClosedOffline() ||
    JumpChainBroken() ||
    MonitorNoFigures() =>
      translator.saidByApp('$e'),
    _ => '$e',
  };
}

/// The password saved with [identity]'s key, for a server that did not take
/// the key and asks for a password (3.0, accounts per host): read now, and
/// only now, under the rules a password key's own password goes by. An
/// Orchard password this account may not see goes only to a host it cannot
/// change, and one from a Crate that asks again goes to a host it may
/// change only once the person confirms it is them ([askItIsYou]):
/// either refusal stops the sign-in with its words, as it does for a
/// password key. Where none can be read, or none is saved, it is asked for
/// ([askForIt], with why where it could not be read), as a password key's
/// is, and saved with the key where they say so and this account may change
/// the key. A question the person cancels ends it with
/// [ConnectionCancelledException].
Future<String> passwordAfterKeyIn(
  AppDatabase db,
  Identity identity, {
  required String connectionId,
  required String host,
  required int port,
  required String username,
  required IdentityCrudNotifier crud,
  required Future<bool> Function(String destination) askItIsYou,
  required Future<PasswordPromptResult?> Function(String? why) askForIt,
  ConnectionLogCallback? onLog,
  ScreenCarrierRoute? carrier,
}) async {
  onLog?.call('identity: The server asks for a password: the one saved with the key...');
  await requirePasswordHostIn(db, identity.id, connectionId, carrierId: carrier?.id);
  if (await passwordAsksAgainIn(db, identity.id, connectionId, carrierId: carrier?.id)) {
    onLog?.call("identity: The key's Crate asks again before its password goes to this address...");
    final confirmed = await confirmPasswordDestination(db,
        identityId: identity.id, host: host, port: port, via: carrier?.via, ask: askItIsYou);
    if (!confirmed) {
      onLog?.call('identity: Not confirmed, so the password was not sent');
      throw OrchardAccessRefused(gl10n.orchardPasswordNotConfirmed);
    }
  }
  String? why;
  try {
    final saved = await crud.getPassword(identity.id);
    if (saved != null) {
      onLog?.call('identity: Password saved with the key loaded for $username');
      return saved;
    }
    onLog?.call('identity: No password is saved with the key, asking for it...');
  } on CrateClosedOffline {
    // Its Crate closed on this device meanwhile (its offline limit): none of
    // its secrets goes, and none is asked for in its place.
    rethrow;
  } catch (e) {
    // What failed is named by its kind (or by what the system's storage
    // said), never by words that could carry what was being read.
    onLog?.call('identity: The password saved with the key could not be read (${signInReadFailure(e)}), asking for it...');
    why = gl10n.connSavedPasswordUnreadable;
  }
  final result = await askForIt(why);
  if (result == null) {
    onLog?.call('identity: User cancelled password prompt');
    throw ConnectionCancelledException();
  }
  if (result.saveToIdentity && await mayEditIn(db, 'key', identity.id)) {
    try {
      await crud.setPassword(identity.id, result.password);
      onLog?.call('identity: Password saved with the key');
    } catch (_) {
      onLog?.call('identity: WARNING - could not save the password with the key');
    }
  }
  return result.password;
}

/// The RD Gateway an RDP host goes through, where its options name one this version reads.
ScreenGateway? screenGatewayOf(Connection connection) {
  if (connection.protocol != ConnectionProtocol.rdp.name) return null;
  final gateway = ScreenOptions.decode(connection.screenOptions).gateway;
  return gateway != null && gateway.readable ? gateway : null;
}

/// The SSH host a remote screen is reached through, as the password rules
/// see it (4.0): its id, whose Crate's switches count as the screen's own
/// ([requirePasswordHostIn]), and its route ([screenViaScope]: its address
/// and port), part of where the password goes ([confirmPasswordDestination]).
typedef ScreenCarrierRoute = ({String? id, String? via});

/// [connection]'s carrier where it is a remote screen reached through one,
/// else null. A carrier that is not there any more still names its id (its
/// switches are none), with no route.
Future<ScreenCarrierRoute?> screenCarrierRouteIn(AppDatabase db, Connection connection) async {
  final id = connection.connectViaId;
  if (!ConnectionProtocol.storedIsScreen(connection.protocol)) return null;
  // An RDP host through an RD Gateway: no carrier's switches, but the gateway's address is part
  // of where the password goes (a host pointed at another gateway asks again).
  final gateway = id == null ? screenGatewayOf(connection) : null;
  if (gateway != null) return (id: null, via: screenViaScope(carrierHost: gateway.host, carrierPort: gateway.port));
  if (id == null) return null;
  final carrier = await db.connectionsDao.getById(id);
  return (id: id, via: carrier == null ? null : screenViaScope(carrierHost: carrier.host, carrierPort: carrier.port));
}

/// What making a saved sign-in ready failed with ([e]), as a log line may
/// say it: the kind of the failure and no more ([errorKind]), since what
/// such a failure prints can carry what was being read, a piece of a key
/// file among it; but for a failure of the device's secure storage, which
/// is said with the system's code and words for it: nothing was read there,
/// and those are what tell one such failure from another.
@visibleForTesting
String signInReadFailure(Object e) => e is PlatformException
    ? asLogLine('PlatformException: ${e.code}${e.message == null ? '' : ': ${e.message}'}')
    : errorKind(e);

/// The error of a host's key that was not accepted in [e], where that is
/// what [e] is or what ended its sign-in: of the host itself, or of a jump
/// host on the way to it.
SSHHostkeyError? hostKeyNotAccepted(Object e) => switch (e) {
      JumpHostFailure(:final cause) => hostKeyNotAccepted(cause),
      SSHHostkeyError() => e,
      SSHAuthAbortError(reason: final SSHHostkeyError reason) => reason,
      _ => null,
    };

/// Whether [e] is a host's key that its person was shown and did not
/// accept ([HostKeyNotAccepted]): they said no themselves, or were told at
/// the key why nothing more could be done. Not a key that a run with
/// nobody there met (automation, 3.0): nobody was shown it, and the
/// session says why it stopped.
bool hostKeyDeclinedByItsPerson(Object e) => switch (hostKeyNotAccepted(e)) {
      HostKeyNotAccepted(why: HostKeyRefusal.unknownUnattended || HostKeyRefusal.changedUnattended) => false,
      HostKeyNotAccepted() => true,
      _ => false,
    };

/// What is said of a host's key that was not accepted, by why
/// ([HostKeyNotAccepted]), with the address that showed it (masked while
/// recording). A key that the SSH core refused by itself, before anybody
/// was asked, is said as what was wrong with it ([SSHHostkeyError.fault]):
/// a key the host could not prove to be its own, something that is no key
/// a host has, or a key that failed when new keys were taken. A key of
/// which no more is known than that a check did not accept it is said as
/// that.
String hostKeyNotAcceptedText(AppLocalizations l10n, SSHHostkeyError e) {
  if (e is! HostKeyNotAccepted) {
    // Refused on a connection that was open, whatever was wrong with it
    // then: of that one it is not true that nothing was sent.
    if (e.duringRekey) return l10n.connHostKeyFailedAtNewKeys;
    return switch (e.fault) {
      SSHHostkeyFault.notSigned => l10n.connHostKeyNotSigned,
      SSHHostkeyFault.noKey => l10n.connHostKeyNoKey,
      SSHHostkeyFault.changed => l10n.connHostKeyFailedAtNewKeys,
      // An RSA key that is too short: with both lengths, and that
      // Compatibility mode takes such a key. (One that was made without
      // its lengths is said as what it is besides.)
      SSHHostkeyFault.tooShort => switch ((e.bits, e.shortestTaken)) {
          (final int bits, final int least) => l10n.connHostKeyTooShort(bits, least),
          _ => l10n.connHostKeyNoKey,
        },
      null => l10n.connHostKeyNotAcceptedPlain,
    };
  }
  final where = Redactable.address(e.host).display;
  return switch (e.why) {
    HostKeyRefusal.declinedNew => l10n.connHostKeyDeclined(where),
    HostKeyRefusal.declinedChanged => l10n.connHostKeyChangedDeclined(where),
    // What the question itself says of it, and who can do something.
    HostKeyRefusal.pinnedOther => e.certificate
        ? '${l10n.teamCertificateMismatchBanner(where, e.crate ?? '')} ${l10n.teamCertificateAskEditor(e.crate ?? '')}'
        : '${l10n.teamHostKeyMismatchBanner(where, e.crate ?? '')} ${l10n.teamHostKeyAskEditor(e.crate ?? '')}',
    HostKeyRefusal.unknownUnattended => l10n.automationSvcHostKeyUnknown,
    HostKeyRefusal.changedUnattended => l10n.automationSvcHostKeyChanged,
  };
}

/// What is said of a connection that the host ended while it was being
/// made, saying why (too many sign-in tries, too many connections): its
/// own words, as its own, where "the server closed the connection" was all
/// there was. Words that came before the host's key was approved, or before
/// any keys at all, can be anybody's on the way: they are said as that.
/// Null where [e] is not such an end, or came with no words. Where it was
/// a jump host on the way that ended it, [jumpHost] is its name, and the
/// words are said as that jump host's.
String? hostEndedText(AppLocalizations l10n, Object e, {String? jumpHost}) {
  final ended = switch (e) {
    SSHAuthAbortError(reason: final SSHDisconnectError reason) => reason,
    SSHDisconnectError() => e,
    _ => null,
  };
  if (ended == null) return null;
  final said = shownHostText(ended.description);
  if (said.isEmpty) return null;
  if (jumpHost != null) {
    return ended.authentic
        ? l10n.jumpHostEndedSaying(jumpHost, said)
        : l10n.jumpHostEndedUnverifiedSaying(jumpHost, said);
  }
  return ended.authentic ? l10n.connHostEndedSaying(said) : l10n.connEndedUnverifiedSaying(said);
}

/// How long before a shell's end something sent into it counts as what
/// ended it: `exit` and Enter, Ctrl+D, a command that ends the session.
const kOwnExitWindow = Duration(seconds: 10);

/// Whether a shell that ended by itself ended at its person's hand:
/// something was typed into it, or sent into it for them, within
/// [kOwnExitWindow] before it ended. Such a session is closed with its tab,
/// as its person meant. Any other end is the host's doing (an account with
/// no shell, which prints a notice and leaves; a limit on idle time;
/// someone there ending the session; a host going down): that session stays
/// in its place, as ended, with how it ended and what the host said last.
bool endedAtOwnHand({required DateTime? lastInput, required DateTime endedAt}) =>
    lastInput != null && endedAt.difference(lastInput) <= kOwnExitWindow;

/// The clock sessions go by. (The tests set it.)
@visibleForTesting
DateTime Function() sessionClock = DateTime.now;

/// The sessions that are files only ([ActiveSessionsNotifier.isFilesOnly]),
/// connected or on their way, as the sessions stand: they come and go with
/// the sessions, whose list changes with each.
final filesOnlySessionsProvider = Provider<Set<String>>((ref) {
  ref.watch(activeSessionsProvider);
  return ref.read(activeSessionsProvider.notifier).filesOnlySessionIds;
});

/// The sessions that are remote screens ([ActiveSessionsNotifier.isScreen],
/// 4.0), connected or on their way: no shell, nothing typed into them as
/// text (a broadcast, a snippet pass them over).
final screenSessionsProvider = Provider<Set<String>>((ref) {
  ref.watch(activeSessionsProvider);
  return ref.read(activeSessionsProvider.notifier).screenSessionIds;
});

/// How a host gave a session no terminal, where the session's shell ended
/// by itself: what is shown in its place then offers its files ("Open its
/// files", "Make this host SFTP only").
enum TerminalRefusal {
  /// Its server said it gives files only ([sftpOnlyServerWords]).
  sftpOnly,

  /// Its shell ended the moment it opened ([kShellAtOnce]), before anything
  /// was typed: what a server that gives files only and says nothing does,
  /// and an account with no shell of its own (whose files can often be
  /// opened all the same).
  closedAtOnce,
}

/// How soon after a session started its shell may end, and still be taken
/// for a host that gives no terminal ([TerminalRefusal.closedAtOnce]).
const kShellAtOnce = Duration(seconds: 3);

/// Whether every session to a host of [protocol] is files only: a host saved
/// as SFTP only. (An SSH host's session is made one by "Open its files",
/// [ActiveSessionsNotifier.openFilesInstead].)
bool opensFilesOnly(String protocol) =>
    protocol == ConnectionProtocol.sftp.name || ConnectionProtocol.storedIsFtps(protocol);

/// What is said of [host] where it is listed for something that needs a
/// terminal (a monitor, a run, a snippet, a broadcast, a forward), and it is
/// SFTP only, FTPS or a remote screen (4.0, VNC): null for any other host,
/// which is listed as it is. A screen's session is never files only
/// ([opensFilesOnly]), and no task runs a command on it ([runsCommands]).
String? noTerminalReason(Connection host, AppLocalizations l10n) => host.protocol == ConnectionProtocol.sftp.name
    ? l10n.hostSftpOnlyNoTerminal
    : ConnectionProtocol.storedIsFtps(host.protocol)
        ? l10n.hostFtpsNoTerminal
        : ConnectionProtocol.storedIsScreen(host.protocol)
            ? l10n.hostScreenNoTerminal
            : null;

/// Whether a session for [host] would be a Telnet connection, which nothing
/// encrypts and which carries no SFTP and no port forward. Where a feature
/// needs one of those (SFTP, the Files host pickers, a saved forward), such a
/// host is refused before anything connects, rather than opened unasked over
/// Telnet only to be told then that the feature cannot run.
bool isTelnetHost(Connection host) => host.protocol == ConnectionProtocol.telnet.name;

/// Whether a task (a workflow's step, a scheduled or a linked command) can run
/// a command on a host of [protocol]: it does so over SSH, whatever the host
/// is opened with. A host that speaks Mosh or Eternal Terminal is saved with its
/// SSH port, and a serial host is reached over SSH at its console server, where
/// a task runs on the console server itself, never on the device on its serial
/// line, as far as that server takes a command at all. A host that is SFTP only
/// refuses one, and Telnet, this device's own shell and the demo have no SSH of
/// theirs to run one over.
bool runsCommands(String protocol) =>
    protocol == ConnectionProtocol.ssh.name ||
    protocol == ConnectionProtocol.mosh.name ||
    protocol == ConnectionProtocol.et.name ||
    protocol == ConnectionProtocol.serial.name;

/// Whether All hosts and a group take in a host of [protocol]: what
/// [runsCommands], but for a serial host, which a task runs on where it names
/// one. The port of a console server is most often a serial line with no shell
/// on it, where a command meant for every server would fail, or wait out its
/// time, on every run.
bool reachedByAllHosts(String protocol) => runsCommands(protocol) && protocol != ConnectionProtocol.serial.name;

/// What is said of [host] where it is listed for a task's command, or where
/// one comes to it: null for a host that can run one ([runsCommands]).
String? noCommandReason(Connection host, AppLocalizations l10n) => runsCommands(host.protocol)
    ? null
    : noTerminalReason(host, l10n) ?? l10n.hostNoCommandsNotSsh;

/// What is said of [host] where it is listed for Run on hosts: null for a host
/// it can run on, which is SSH alone ([ActiveSessionsNotifier.openRunClient]).
/// The Server monitor counted the others, and they then failed with these words.
String? noRunOnHostsReason(Connection host, AppLocalizations l10n) => host.protocol == ConnectionProtocol.ssh.name
    ? null
    : noTerminalReason(host, l10n) ?? l10n.runOnHostsSshOnly;

/// How a host gave a session no terminal, from how its shell ended: [said]
/// is what the host printed last, [connectedAt] when the session started,
/// [endedAt] when its shell ended, [lastInput] when its person last typed
/// into it (null: never). Null where it is a shell that ran and ended.
TerminalRefusal? terminalRefusalAtEnd({
  required String said,
  required DateTime connectedAt,
  required DateTime endedAt,
  required DateTime? lastInput,
}) {
  if (saysSftpOnly(said)) return TerminalRefusal.sftpOnly;
  final lasted = endedAt.difference(connectedAt);
  if (lastInput == null && !lasted.isNegative && lasted <= kShellAtOnce) return TerminalRefusal.closedAtOnce;
  return null;
}

/// The last [count] rows of what [terminal] holds, from the top.
Iterable<String> lastRows(Terminal terminal, [int count = 60]) sync* {
  final lines = terminal.buffer.lines;
  for (var i = lines.length > count ? lines.length - count : 0; i < lines.length; i++) {
    yield lines[i].toString();
  }
}

/// What is said of a host that signed the person in and then did not start
/// the session, by what it did not give ([NoSessionKind]): what happened,
/// and what it usually means.
String noSessionText(AppLocalizations l10n, NoSessionKind kind) => switch (kind) {
      NoSessionKind.terminal => l10n.connNoTerminal,
      NoSessionKind.shell => l10n.connNoShell,
      NoSessionKind.session => l10n.connNoSession,
      NoSessionKind.other => l10n.connNoSessionOther,
      NoSessionKind.closed => l10n.connNoSessionClosed,
    };

/// Thrown when a per-host network override marks the host as "skip on this
/// network." The SSH connect flow aborts cleanly with a friendly, localized
/// message instead of attempting a doomed socket. Its [toString] returns the
/// bare message (no `Exception:` prefix) so it renders cleanly when surfaced
/// through the same error-dialog / notification path as any other connect
/// failure.
class HostSkippedOnNetworkException implements Exception, HasTypeName {
  final String message;
  const HostSkippedOnNetworkException(this.message);
  @override
  String toString() => message;

  @override
  String get typeName => 'HostSkippedOnNetworkException';
}

// ── Terminal title per session ──────────────────────────────────

/// The most of a title a host sets (OSC 0 or 2) that is shown.
const kTerminalTitleMax = 120;

/// A title a host set, as it is shown: no control characters, none of the
/// direction overrides or invisible characters that could make it read other
/// than it is, at most [kTerminalTitleMax] characters ([cleanServerText]). It
/// was shown as the host sent it.
String cleanTerminalTitle(String title) => cleanServerText(title, maxLength: kTerminalTitleMax);

/// Tracks the terminal title (set by SSH server via OSC escape sequence).
/// Updated dynamically as the server changes it (e.g. showing CWD, hostname).
final terminalTitleProvider =
    StateProvider.family<String?, String>((ref, sessionId) => null);

/// The most names of a folder autocomplete looks through.
const kCompletionListedNames = 20000;

/// How often it is said that a host used the forwarded agent, at most, per host.
const kAgentSignedSaidEvery = Duration(minutes: 1);

/// Whether the session is asking whether to start tmux control mode, something
/// in its output having asked for it with nobody having asked for tmux
/// ([TmuxInbandWatcher]). [ActiveSessionsNotifier.answerTmuxStart] answers.
final tmuxStartQuestionProvider =
    StateProvider.family<bool, String>((ref, sessionId) => false);

// ── Terminal-friendly word separators ────────────────────────────

/// Custom word separators for double-click word selection.
///
/// Unlike the xterm defaults, we keep `.`, `:`, `/`, `-`, `_`, `@`, `~`
/// as word characters so that paths (`/var/log/syslog`), hostnames
/// (`server.example.com`), IPs (`192.168.1.1`), and email addresses
/// (`user@host.com`) are selected as complete words on double-click.
final _terminalWordSeparators = <int>{
  0, // null
  0x20, // space
  0x09, // tab
  0x22, // "
  0x27, // '
  0x28, // (
  0x29, // )
  0x5B, // [
  0x5D, // ]
  0x7B, // {
  0x7D, // }
  0x3B, // ;
  0x7C, // |
  0x3C, // <
  0x3E, // >
  0x60, // `
  0x2C, // ,
  0x21, // !
  0x3F, // ?
  0x23, // #
  0x26, // &
};

/// Detect the correct xterm platform for platform-specific terminal behaviour.
TerminalTargetPlatform _detectPlatform() {
  if (Platform.isAndroid) return TerminalTargetPlatform.android;
  if (Platform.isMacOS) return TerminalTargetPlatform.macos;
  if (Platform.isWindows) return TerminalTargetPlatform.windows;
  if (Platform.isLinux) return TerminalTargetPlatform.linux;
  return TerminalTargetPlatform.unknown;
}

// ── Session state ────────────────────────────────────────────────

/// Represents one active terminal session.
class TerminalSession {
  final String id;
  final String connectionId;
  final Terminal terminal;
  final ShellService shell;
  final DateTime startedAt;

  TerminalSession({
    required this.id,
    required this.connectionId,
    required this.terminal,
    required this.shell,
    required this.startedAt,
  });
}

/// Current state of a terminal session.
enum SessionStatus { connecting, connected, disconnected, error }

/// Whether the host [connectionId] is open: any session to it is connected
/// or on its way. A host can have several sessions (a duplicate, a pane
/// split off it); it is open while one of them is.
bool hostIsOpen(Map<String, SessionState> sessions, String connectionId) => sessions.values.any((s) =>
    s.connectionId == connectionId &&
    (s.status == SessionStatus.connected || s.status == SessionStatus.connecting));

/// How many sessions quitting the app ends: every one connected or on its
/// way, a terminal's, an SFTP pane's, one that only runs port forwards, a
/// hidden one. Quitting asks about them, and so does an update's restart,
/// with the same count.
int openSessionCount(Map<String, SessionState> sessions) => sessions.values
    .where((s) => s.status == SessionStatus.connected || s.status == SessionStatus.connecting)
    .length;

/// A session's terminal as a live view sees it (3.0, session sharing).
class _SessionShareTerminal implements ShareTerminal {
  _SessionShareTerminal(this._sessions, this._sessionId);

  final ActiveSessionsNotifier _sessions;
  final String _sessionId;

  @override
  ShareScreen snapshot() {
    final terminal = _sessions._terminalOf(_sessionId);
    if (terminal == null) return const ShareScreen(columns: 80, rows: 24, text: '');
    return ShareScreen(
      columns: terminal.viewWidth.clamp(1, 1000),
      rows: terminal.viewHeight.clamp(1, 500),
      text: terminalSnapshot(terminal),
    );
  }

  @override
  void type(Uint8List bytes) => _sessions._typeFromShare(_sessionId, bytes);
}

class SessionState {
  final SessionStatus status;
  final TerminalSession? session;
  final String? errorMessage;

  /// The connection ID - available in all states (connecting, connected, etc.)
  final String? connectionId;

  /// Human-readable connection label (e.g. "My Server").
  final String connectionLabel;

  /// Live log of connection progress messages shown on the connecting screen.
  final List<String> connectionLog;

  /// Connection details for error display.
  final String? host;
  final int? port;
  final String? username;

  /// Whether an auto-reconnect loop is currently active for this session.
  final bool isReconnecting;

  /// Current auto-reconnect attempt number (1-based).
  final int reconnectAttempt;

  /// Maximum reconnect attempts before giving up.
  final int maxRetries;

  /// Connection color index (for tab color dot).
  final int colorIndex;

  /// Optional custom connection colour (ARGB int). Overrides [colorIndex] for
  /// the tab colour when non-null; null falls back to the index.
  final int? colorValue;

  /// Whether this session is hidden from the pane/tab view.
  /// The session stays alive but isn't shown in any pane.
  /// Clicking it in the sidebar or re-connecting restores it.
  final bool isHidden;

  /// Its connection went without being asked to (not an exit, not a
  /// Disconnect or a Close): a computer shows it in its place, with why and
  /// Reconnect, while it is [SessionStatus.disconnected] (3.0).
  final bool dropped;

  /// Why its connection dropped, once the connection says (what the network
  /// said when it broke, or `hostClosedConnection`); null when not known.
  /// What the last try of connecting again said is [errorMessage].
  final String? dropCause;

  /// When its terminal last started, kept once its connection has gone (the
  /// [session] goes with it): [startedAt] reads it then.
  final DateTime? lastStartedAt;

  const SessionState({
    required this.status,
    this.session,
    this.errorMessage,
    this.connectionId,
    this.connectionLabel = '',
    this.connectionLog = const [],
    this.host,
    this.port,
    this.username,
    this.isReconnecting = false,
    this.reconnectAttempt = 0,
    this.maxRetries = 10,
    this.colorIndex = 0,
    this.colorValue,
    this.isHidden = false,
    this.dropped = false,
    this.dropCause,
    this.lastStartedAt,
  });

  /// When it started: its terminal's start while it is open, and after its
  /// connection has gone too, so the phone's Sessions tab tells two sessions
  /// to one host apart by it. Null for
  /// one that never opened.
  DateTime? get startedAt => session?.startedAt ?? lastStartedAt;

  /// Whether it speaks SSH, which tmux control mode and SFTP run over: by its
  /// shell. Before it has one nothing says so: a saved local shell has an id like
  /// any host's, so the header's buttons for them showed on it while it started.
  /// A remote screen reached through an SSH host is encrypted by it, but has
  /// no shell on it: no tmux or SFTP of its own (4.0).
  bool get speaksSsh {
    final shell = session?.shell;
    return shell != null && shell is! ScreenShellService && shell.isEncryptedSsh;
  }

  /// Return a copy with an appended log message.
  /// Upper bound on [connectionLog]. The log is copied on every append (this
  /// state is immutable), so it must stay small: an unbounded list fed by the
  /// SSH core's per-packet trace grew to hundreds of thousands of lines during
  /// a folder upload, copied in full on each line.
  static const int maxConnectionLogLines = 500;

  SessionState withLog(String message) => SessionState(
        status: status,
        session: session,
        errorMessage: errorMessage,
        connectionId: connectionId,
        connectionLabel: connectionLabel,
        connectionLog: connectionLog.length < maxConnectionLogLines
            ? [...connectionLog, message]
            : [
                ...connectionLog.sublist(
                    connectionLog.length - maxConnectionLogLines + 1),
                message,
              ],
        host: host,
        port: port,
        username: username,
        isReconnecting: isReconnecting,
        reconnectAttempt: reconnectAttempt,
        maxRetries: maxRetries,
        colorIndex: colorIndex,
        colorValue: colorValue,
        isHidden: isHidden,
        dropped: dropped,
        dropCause: dropCause,
        lastStartedAt: lastStartedAt,
      );

  /// Return a copy with updated reconnect state.
  SessionState copyWith({
    SessionStatus? status,
    TerminalSession? session,
    String? errorMessage,
    String? connectionId,
    String? connectionLabel,
    List<String>? connectionLog,
    String? host,
    int? port,
    String? username,
    bool? isReconnecting,
    int? reconnectAttempt,
    int? maxRetries,
    int? colorIndex,
    int? colorValue,
    bool? isHidden,
    bool? dropped,
    String? dropCause,
    DateTime? lastStartedAt,
  }) =>
      SessionState(
        status: status ?? this.status,
        session: session ?? this.session,
        errorMessage: errorMessage ?? this.errorMessage,
        connectionId: connectionId ?? this.connectionId,
        connectionLabel: connectionLabel ?? this.connectionLabel,
        connectionLog: connectionLog ?? this.connectionLog,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        isReconnecting: isReconnecting ?? this.isReconnecting,
        reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
        maxRetries: maxRetries ?? this.maxRetries,
        colorIndex: colorIndex ?? this.colorIndex,
        colorValue: colorValue ?? this.colorValue,
        isHidden: isHidden ?? this.isHidden,
        dropped: dropped ?? this.dropped,
        dropCause: dropCause ?? this.dropCause,
        lastStartedAt: lastStartedAt ?? this.lastStartedAt,
      );

  factory SessionState.initial() =>
      const SessionState(status: SessionStatus.disconnected);

  factory SessionState.connecting(
    String connectionId, {
    String connectionLabel = '',
    String? host,
    int? port,
    String? username,
    int colorIndex = 0,
    int? colorValue,
  }) =>
      SessionState(
        status: SessionStatus.connecting,
        connectionId: connectionId,
        connectionLabel: connectionLabel,
        host: host,
        port: port,
        username: username,
        colorIndex: colorIndex,
        colorValue: colorValue,
      );

  factory SessionState.connected(
    TerminalSession session, {
    List<String> connectionLog = const [],
    String connectionLabel = '',
    String? host,
    int? port,
    String? username,
    int colorIndex = 0,
    int? colorValue,
  }) =>
      SessionState(
        status: SessionStatus.connected,
        session: session,
        connectionId: session.connectionId,
        connectionLog: connectionLog,
        connectionLabel: connectionLabel,
        host: host,
        port: port,
        username: username,
        colorIndex: colorIndex,
        colorValue: colorValue,
      );

  factory SessionState.error(
    String message, {
    String? connectionId,
    List<String> connectionLog = const [],
    String connectionLabel = '',
    String? host,
    int? port,
    String? username,
  }) =>
      SessionState(
        status: SessionStatus.error,
        errorMessage: message,
        connectionId: connectionId,
        connectionLog: connectionLog,
        connectionLabel: connectionLabel,
        host: host,
        port: port,
        username: username,
      );

  /// A session whose connection is gone. [errorMessage] says why when that is
  /// known (what the last try to connect again said, while connecting again
  /// by itself), and the [connectionLog] goes with it for its report.
  factory SessionState.disconnected({
    String? connectionId,
    String connectionLabel = '',
    String? host,
    int? port,
    String? errorMessage,
    List<String> connectionLog = const [],
    String? username,
    bool dropped = false,
    String? dropCause,
  }) =>
      SessionState(
        status: SessionStatus.disconnected,
        connectionId: connectionId,
        connectionLabel: connectionLabel,
        host: host,
        port: port,
        errorMessage: errorMessage,
        connectionLog: connectionLog,
        username: username,
        dropped: dropped,
        dropCause: dropCause,
      );
}

// ── Password prompt ──────────────────────────────────────────────

/// Completer-based callback for interactive password prompt.
///
/// When the connection needs a password but none is saved, this is set
/// by the provider. The terminal screen picks it up and shows a dialog.
class PasswordPromptRequest {
  final String host;
  final String username;
  final int attempt;
  final String? errorHint;
  final Completer<PasswordPromptResult?> completer;

  /// Whether the password may be kept with a key of the host ("Save to
  /// identity"): not for a host that is not saved (Quick connect), which
  /// has nowhere to keep it.
  final bool offerSave;

  /// Whether the user name is asked for too, above the password: an RDP
  /// host with no key (4.0), which has nobody to sign in as until its
  /// person says. [username] is empty then.
  final bool askUsername;

  PasswordPromptRequest({
    required this.host,
    required this.username,
    this.attempt = 1,
    this.errorHint,
    required this.completer,
    this.offerSave = true,
    this.askUsername = false,
  });
}

/// Result returned from the password prompt dialog.
class PasswordPromptResult {
  final String password;
  final bool saveToIdentity;

  /// The user name typed, where it was asked for
  /// ([PasswordPromptRequest.askUsername]); null otherwise.
  final String? username;

  const PasswordPromptResult({
    required this.password,
    this.saveToIdentity = false,
    this.username,
  });
}

/// Provider for pending password prompt dialogs.
final passwordPromptProvider =
    StateProvider<PasswordPromptRequest?>((ref) => null);

// ── Connection error for user-facing dialog ─────────────────────

/// The hosts whose last try of connecting failed for want of a team
/// certificate that an owner can sign directly, by connection id, each with
/// the Crate that takes it (3.0). Whatever shows the failure offers
/// "Certificate from an owner" from this. Gone again when the host
/// connects, or fails for another reason.
final certificateFromOwnerOfferProvider =
    StateProvider<Map<String, ({String orchardId, String crateId})>>((ref) => const {});

/// The hosts whose last try of connecting was refused because their Crate
/// is closed on this device by its offline limit, by connection id, each
/// with that Crate (3.0). Whatever shows the failure offers "Offline pass
/// from an owner" from this. Gone again when the host connects, or fails
/// for another reason.
final offlinePassOfferProvider =
    StateProvider<Map<String, ({String orchardId, String crateId})>>((ref) => const {});

/// A connection that could not be made, as a computer's dialog shows it
/// (ConnectionFailedDialog). What kind of failure it was is read from
/// [errorMessage] by whatever shows it, as every other screen of a failed
/// connection does. (It also kept what the program calls the type of what
/// was thrown, which was the kind in that dialog's report: another name in
/// a build made for release, and never the kind the other screens' reports
/// have.)
class ConnectionError {
  final String host;
  final int port;
  final String errorMessage;
  final String? connectionLabel;

  /// The SSH login username, when one is known at failure time (a quick-connect
  /// override). Fed to [maskConnectionLine] so a bare username in an error line
  /// or a log line is masked in recording mode, not just the `user@host` forms
  /// the free-text scan already catches.
  final String? username;

  final List<String> connectionLog;

  /// Session id of the failed session. The dialog uses this to end the
  /// session immediately when it opens, so the red error tab doesn't
  /// linger in the tab bar after the user dismisses the dialog. The
  /// "Connection Lost" tab UI is redundant with the dialog + home view.
  final String? sessionId;

  /// Connection (host) id. Used by the Retry path to start a fresh
  /// session even after the failed one is ended.
  final String? connectionId;

  ConnectionError({
    required this.host,
    required this.port,
    required this.errorMessage,
    this.connectionLabel,
    this.username,
    this.connectionLog = const [],
    this.sessionId,
    this.connectionId,
  });
}

/// Holds the last connection error for user-facing display.
/// Set by [ActiveSessionsNotifier] on failure, cleared when the dialog is dismissed.
final connectionErrorProvider =
    StateProvider<ConnectionError?>((ref) => null);

// ── SSH key passphrase prompt ───────────────────────────────────

/// Request to prompt the user for an SSH key passphrase.
class PassphrasePromptRequest {
  final String host;
  final String username;
  final Completer<PassphrasePromptResult?> completer;

  PassphrasePromptRequest({
    required this.host,
    required this.username,
    required this.completer,
  });
}

/// Result returned from the passphrase prompt dialog.
class PassphrasePromptResult {
  final String passphrase;
  final bool savePassphrase;

  const PassphrasePromptResult({
    required this.passphrase,
    this.savePassphrase = false,
  });
}

/// Provider for pending passphrase prompt dialogs.
final passphrasePromptProvider =
    StateProvider<PassphrasePromptRequest?>((ref) => null);

// ── Host key verification ────────────────────────────────────────

/// Completer-based callback for host key verification.
///
/// When connecting, the SSH layer calls this with the host key.
/// The terminal screen picks this up and shows a dialog.
/// The user's response resolves the Completer, which unblocks
/// the SSH handshake.
class HostKeyVerification {
  final String host;
  final int port;
  final SSHHostKey hostKey;
  final String fingerprint;
  final bool isChanged; // true = key changed (danger), false = new host

  /// The previously-trusted fingerprint (changed case only). Null on the
  /// first-connection path, or when the stored record is a legacy digest whose
  /// real fingerprint is unknown.
  final String? expectedFingerprint;

  /// When [expectedFingerprint] was first trusted (changed case only).
  final DateTime? expectedTrustedAt;

  /// The received key type (e.g. 'ssh-ed25519'), used to suggest the correct
  /// server-side verification command in the changed-key dialog.
  final String keyType;

  final Completer<bool> completer;

  /// Team-pinned host keys (3.0): null outside an Orchard, and
  /// where this account neither pins nor meets a pin.
  final TeamPinPrompt? teamPin;

  /// An FTPS server's TLS certificate (3.4) rather than an SSH host key: the
  /// same question, in a certificate's words. [fingerprint] is its SHA-256
  /// as server tools print it.
  final bool certificate;

  /// A remote screen's VeNCrypt certificate (4.0; [certificate] too): the
  /// first connection's question says it is a screen's, and [host]:[port]
  /// is the VNC server as its carrier ([via], the carrier's label) sees it.
  final bool screen;
  final String? via;

  /// The name of the saved host the question is about, where it has one
  /// that its address does not say (a remote screen "desk-01" at
  /// localhost:5900): the question names it.
  final String? name;

  HostKeyVerification({
    this.certificate = false,
    this.screen = false,
    this.via,
    this.name,
    required this.host,
    required this.port,
    required this.hostKey,
    required this.fingerprint,
    required this.isChanged,
    required this.completer,
    this.expectedFingerprint,
    this.expectedTrustedAt,
    this.teamPin,
    String? keyType,
  }) : keyType = keyType ?? hostKey.type;
}

/// Serialized queue of pending host-key verifications.
///
/// Concurrent connections - a workspace opening several hosts at once - each
/// enqueue their own verification; the UI shows the HEAD and, once the user
/// answers it, advances to the next, so every untrusted host gets its own
/// prompt. This replaced a single-slot provider where a second concurrent
/// verification silently overwrote the first and the dialog's busy-guard then
/// dropped it, leaving that session hung forever waiting for an answer nobody
/// was ever asked for ("only one host asks for its key").
class HostKeyVerificationQueue
    extends StateNotifier<List<HostKeyVerification>> {
  HostKeyVerificationQueue() : super(const []);

  /// The verification currently awaiting the user, or null when idle.
  HostKeyVerification? get current => state.isEmpty ? null : state.first;

  void enqueue(HostKeyVerification verification) {
    state = [...state, verification];
  }

  /// Resolve [verification] with the user's answer and drop it from the queue
  /// so the next pending one becomes [current]. Idempotent: resolving an
  /// already-answered or already-removed entry is a no-op.
  void resolve(HostKeyVerification verification, bool accepted) {
    if (!verification.completer.isCompleted) {
      verification.completer.complete(accepted);
    }
    state = state.where((v) => !identical(v, verification)).toList();
  }
}

final hostKeyVerificationQueueProvider = StateNotifierProvider<
    HostKeyVerificationQueue, List<HostKeyVerification>>(
  (ref) => HostKeyVerificationQueue(),
);

/// The verification the UI should be showing right now: the head of the
/// queue, or null when nothing is pending. Listeners react to this exactly as
/// they did to the old single-slot provider - it changes whenever the head
/// advances - while the queue behind it guarantees nothing is dropped.
final hostKeyVerificationProvider = Provider<HostKeyVerification?>((ref) {
  final queue = ref.watch(hostKeyVerificationQueueProvider);
  return queue.isEmpty ? null : queue.first;
});

// ── Mobile Soft Key Modifier ─────────────────────────────────────

/// Global modifier state from the mobile soft keyboard toolbar.
/// When Ctrl/Alt is toggled on the toolbar and the user types on the
/// system keyboard, the onOutput handler transforms the character.
final mobileSoftKeyModifierProvider =
    StateProvider<SoftKeyModifier>((ref) => SoftKeyModifier.none);

// ── Broadcast: asking before a risky command runs everywhere ─────

/// Asks the person before the risky command [command] is run on every
/// terminal that types together ([targetHostNames], besides the one it was
/// typed into; [targetHostIds] the saved hosts they are, where they are):
/// true to run it there, false not to, and null when there is no window to ask
/// in.
typedef BroadcastConfirm = Future<bool?> Function(
  String command,
  List<DangerousCommandMatch> matches,
  List<String> targetHostNames,
  List<String?> targetHostIds,
);

/// How the person is asked ([BroadcastConfirm]): the dialog, in the app's
/// window. (A provider, so that a test can answer in the person's place.)
final broadcastConfirmProvider = Provider<BroadcastConfirm>((ref) {
  return (command, matches, targetHostNames, targetHostIds) async {
    // Providers have no BuildContext of their own: the router's navigator
    // has one.
    final ctx = ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return null;
    return showBroadcastDangerousDialog(
      ctx,
      command: command,
      matches: matches,
      targetHostNames: targetHostNames,
      targetHostIds: targetHostIds,
    );
  };
});

// ── Active sessions ──────────────────────────────────────────────

/// Map of active terminal sessions by session ID.
/// Whether a dropped session is told of as a computer tells of it. Null in the
/// app (the system it runs on decides).
@visibleForTesting
bool? debugConnectionLostOnComputer;

/// Whether a terminal's bell rings as a computer's does. Null in the app.
@visibleForTesting
bool? debugBellOnComputer;

final activeSessionsProvider =
    StateNotifierProvider<ActiveSessionsNotifier, Map<String, SessionState>>(
  (ref) => ActiveSessionsNotifier(ref),
);

/// A captured command awaiting its OSC 133 result (exit code + duration). Holds
/// the history row-id future because the insert is async, plus a mutable start
/// time so an OSC 133 ;C (command actually began) can refine it over the initial
/// Enter timestamp.
class _PendingCmd {
  _PendingCmd(this.idFuture, this.start);
  final Future<String> idFuture;
  DateTime start;
}

/// Outcome of trying to start a saved port-forward rule from the sidebar.
/// [notAllowed]: the host's Crate does not allow port forwarding
/// (3.0).
enum StartForwardResult { started, noSession, error, notAllowed }

/// Reactive union of forward-rule ids currently active across all sessions.
/// The [ActiveSessionsNotifier] keeps this in sync (on start/stop/auto-start
/// and session teardown) so the Port Forwarding sidebar's Start/Stop buttons
/// and ACTIVE/SAVED split reflect the live truth rather than a proxy.
final activeForwardIdsProvider = StateProvider<Set<String>>((ref) => {});

class ActiveSessionsNotifier extends StateNotifier<Map<String, SessionState>> {
  final Ref _ref;

  /// The space each host's sessions were opened from (3.0).
  late final SessionSpaces _spaces = SessionSpaces(_ref);

  AppDatabase? _sessionDb(String connectionId) => _spaces.database(connectionId);

  AppDatabase _readDb(String connectionId) => _spaces.readDatabase(connectionId);

  /// Whether the host [connectionId]'s Crate lets this account use [what]
  /// (SFTP, port forwarding, agent forwarding), in the space its sessions
  /// belong to (3.0). Always in your Tree, and for a quick connect
  /// (no saved host, so nothing of a Crate's); never once an Orchard the
  /// session came from has closed.
  Future<bool> hostAllows(String? connectionId, String what) =>
      hostAllowsIn(connectionId == null ? null : _sessionDb(connectionId), connectionId, what);

  /// The keys and their secrets of [db]'s space.
  IdentityCrudNotifier _identityCrudFor(AppDatabase db) => IdentityCrudNotifier(
        db.identitiesDao,
        IdentitySecretStore.forDatabase(db, _ref.read(secureStorageProvider)),
        db.connectionsDao,
      );

  /// Track sessions being intentionally disconnected to suppress notifications.
  final _intentionalDisconnects = <String>{};

  /// The try of connecting each session is at, while it runs: [endSession] and
  /// [disconnectSession] take it away. ([_intentionalDisconnects] goes after two
  /// seconds, and a connection can take longer.) What a try has made by then is
  /// nobody's, and goes ([_dropEndedTry]).
  final _connectTries = <String, Object>{};

  /// Stream subscriptions per session for cleanup.
  final _stdoutSubscriptions = <String, StreamSubscription>{};
  final _connectionStateSubscriptions = <String, StreamSubscription>{};

  /// Each session's output between two frames ([OutputBatch]): drawn and
  /// read once every 16 ms.
  final _outputBatches = <String, OutputBatch>{};

  /// Per-session command-history reconstructors (Squeezed feature). Only touched
  /// when the user is Pro and recording is enabled.
  final _cmdCaptures = <String, CommandCapture>{};

  /// History suggestions (3.0), per session.
  final _suggesters = <String, HistorySuggester>{};

  /// [sessionId]'s history suggestions: from its own space's history (an
  /// Orchard session's from that Orchard's), only while history is kept here,
  /// suggestions are on and the screen is not being recorded.
  HistorySuggester _suggesterFor(String sessionId, Connection connection) => _suggesters.putIfAbsent(
        sessionId,
        () => HistorySuggester(
          lookup: (typed) async {
            final db = _sessionDb(connection.id);
            final fromHistory =
                await db?.commandHistoryDao.latestStartingWith(typed, preferConnectionId: connection.id);
            return fromHistory ?? await _autocomplete(sessionId, typed, db);
          },
          enabled: () => _ref.read(historySuggestionsActiveProvider),
        ),
      );

  /// Inline autocomplete past history (3.2): a path on the host being typed
  /// (`/` or `~/`, from its folder's listing), a saved host after `ssh`, then
  /// a saved snippet. Null when none fits.
  Future<String?> _autocomplete(String sessionId, String typed, AppDatabase? db) async {
    final path = pathBeingTyped(typed);
    if (path != null) {
      final names = await _completionListing(sessionId, path.folder);
      final done = names == null ? null : completePath(typed, names);
      if (done != null) return done;
    }
    final ssh = completeSshTarget(typed, _ref.read(connectionsWithDetailsProvider).valueOrNull ?? const []);
    if (ssh != null) return ssh;
    final snippets = await db?.snippetsDao.getAll();
    return snippets == null ? null : completeFromSnippets(typed, snippets);
  }

  /// A folder's listing on [sessionId]'s host, for completing paths: asked
  /// once in a while over the session's own connection (SFTP), kept for a
  /// few seconds. Null where the host offers no SFTP or the session has no
  /// SSH connection; the session stops asking after a failure.
  Future<List<(String, bool)>?> _completionListing(String sessionId, String folder) async {
    final key = '$sessionId\u0000$folder';
    final kept = _completionListings[key];
    if (kept != null && DateTime.now().difference(kept.at) < kCompletionListingKeptFor) return kept.names;
    if (_completionSftpOff.contains(sessionId)) return null;
    final shell = state[sessionId]?.session?.shell;
    if (shell is! SshService) return null;
    try {
      final sftp = await (_completionSftp[sessionId] ??= shell.client.sftp());
      // (A suggestion is not worth a million names, and the timeout stops only
      // the wait: this is what bounds a listing that goes on.)
      final items = await sftp.listdir(folder, maxNames: kCompletionListedNames).timeout(const Duration(seconds: 3));
      final names = [for (final i in items) (i.filename, i.attr.isDirectory)];
      keepCompletionListing(_completionListings, key, names, DateTime.now());
      return names;
    } catch (_) {
      _completionSftpOff.add(sessionId);
      _completionSftp.remove(sessionId);
      return null;
    }
  }

  /// When the forwarded agent's signing was last said, per host.
  final _agentSignedSaidAt = <String, DateTime>{};

  /// A host had a key sign something through the agent forwarded to it, which
  /// it can do with no question for as long as it is connected. Said quietly,
  /// and at most once a minute per host: a `git pull` signs several times, and
  /// asking would be no use (the person chose to forward it, and a program on
  /// the other end asks when it asks). It is the only trace there is.
  void _agentSigned(Connection connection, ConnectionLogCallback? log) {
    final now = sessionClock();
    final last = _agentSignedSaidAt[connection.id];
    if (last != null && now.difference(last) < kAgentSignedSaidEvery) return;
    _agentSignedSaidAt[connection.id] = now;
    log?.call(kAgentSignedLogLine);
    if (!mounted) return;
    _notify().info(gl10n.agentSignedNotice(Redactable.host(connection.label).display));
  }

  /// [_agentSigned], for a test with no agent to ask.
  @visibleForTesting
  void debugAgentSigned(Connection connection, ConnectionLogCallback? log) => _agentSigned(connection, log);

  /// Autocomplete's SFTP channel per session, the listings it gave, and the
  /// sessions it failed on.
  final _completionSftp = <String, Future<SftpClient>>{};
  final _completionListings = <String, ({DateTime at, List<(String, bool)> names})>{};
  final _completionSftpOff = <String>{};
  final _tmuxWatchers = <String, TmuxInbandWatcher>{};

  /// Where a viewer's keys go while they hold the keyboard of a shared
  /// session (3.0), by session.
  final _shareTypers = <String, void Function(Uint8List bytes)>{};

  /// Session sharing (3.0): what a live view of [sessionId] is shown and
  /// where a viewer's keys are typed; null when the session has no terminal.
  /// A session waiting for someone to watch it (3.0) has one
  /// before it is connected: an empty screen, until its own takes over.
  ShareTerminal? shareTerminalOf(String sessionId) =>
      state[sessionId]?.session == null && SessionWatches.of(sessionId) == null
          ? null
          : _SessionShareTerminal(this, sessionId);

  /// The database the host [connectionId]'s sessions work in (their space),
  /// or null when that space has closed.
  AppDatabase? sessionDatabaseOf(String connectionId) => _sessionDb(connectionId);

  /// The space [connectionId]'s sessions work in, where one has opened (the
  /// tabs say where a host comes from: a team's vault or Personal).
  Space? spaceOfConnection(String connectionId) => _spaces.spaceOf(connectionId);

  Terminal? _terminalOf(String sessionId) => state[sessionId]?.session?.terminal;

  /// How long a connection to a host may take to open: Settings' Connection
  /// timeout.
  Duration get _connectTimeout => Duration(seconds: _ref.read(connectionTimeoutProvider).clamp(1, 600));

  /// When a terminal's bell last rang: a program that rings it in a burst (a
  /// binary file printed) rings it once.
  DateTime? _bellRangAt;

  /// A terminal's bell, where Settings leaves it on, as the switch is when it
  /// rings (it was read once, when the session opened): a buzz on a phone,
  /// the system's alert sound on a computer, where a buzz is nothing (the
  /// bell did nothing there).
  void _ringBell() {
    if (!mounted || !_ref.read(bellEnabledProvider)) return;
    final now = DateTime.now();
    final last = _bellRangAt;
    if (last != null && now.difference(last) < const Duration(milliseconds: 250)) return;
    _bellRangAt = now;
    if (debugBellOnComputer ?? isDesktopPlatform) {
      SystemSound.play(SystemSoundType.alert);
    } else {
      HapticFeedback.heavyImpact();
    }
  }

  /// A session dropped by itself, where Settings says to tell of it (its
  /// "Connection lost" switch, which nothing read: a phone told of it either
  /// way, and a computer never did). A phone's system notification; on a
  /// computer one of the app's notices, unless the session is on screen in
  /// the tab in front, whose pane says so itself, and the system's
  /// notification too where its person turned that on and the window is not
  /// in front (4.0: the pane is not seen from the tray).
  void _tellConnectionLost(String sessionId, String label) {
    if (!_ref.read(notifyConnectionLostProvider)) return;
    if (!(debugConnectionLostOnComputer ?? isDesktopPlatform)) {
      unawaited(NotificationService.showConnectionLost(connectionLabel: label));
      return;
    }
    unawaited(NotificationService.onComputer(() => NotificationService.showConnectionLost(connectionLabel: label)));
    // (Through the container: the tabs listen to the sessions, and a debug
    // build refuses this provider's own ref a read the other way round.)
    final inFront =
        _ref.container.read(workTabsProvider).activeTab?.terminalSessionIds.contains(sessionId) ?? false;
    if (inFront) return;
    _ref.read(notificationCenterProvider.notifier).warning(
          gl10n.connectionLostTitle,
          // (The host's name masked in recording mode, as a phone's says it.)
          body: gl10n.connectionLostEnded(Redactable.host(label).display),
        );
  }

  /// The tmux side of [sessionId]'s tab. It listens to the sessions (tmux
  /// mode ends when its session goes), so it is read through the container:
  /// a debug build refuses a read that goes the other way round through this
  /// provider's own ref, although nothing here is read while either of the
  /// two is being built.
  TmuxSessionHost _tmuxHostOf(String sessionId) => _ref.container.read(tmuxHostProvider(sessionId));

  void _typeFromShare(String sessionId, Uint8List bytes) {
    // Nobody else types into a session while its owner's app is locked.
    if (_ref.read(isAppLockedProvider)) return;
    _shareTypers[sessionId]?.call(bytes);
  }

  /// Per-session OSC 133 / OSC 7 parser (Phase 2b record extension). Feeds exit
  /// code, duration and working directory onto history entries when the remote
  /// shell emits shell integration; otherwise it produces nothing.
  final _shellIntegration = <String, ShellIntegrationParser>{};

  /// Last working directory reported by OSC 7 per session, stamped onto the NEXT
  /// captured command (that is the directory it runs in).
  final _sessionCwd = <String, String>{};

  /// The most-recently captured command per session awaiting its exit code +
  /// duration from a later OSC 133 ;D. Holds the row-id future (the DB insert is
  /// async) so the ;D handler can await it before writing the result.
  final _pendingCmd = <String, _PendingCmd>{};

  /// The line typed into each session since its last line end (Doc-3 Part C
  /// / C1): everything typed there, by the person or by a broadcast from
  /// another terminal, so that a destructive command can be caught and
  /// confirmed BEFORE its Enter is multiplied across every host. It is the
  /// line of the terminal that would RUN it: followed for every session,
  /// broadcast or not (a few characters kept per keystroke), because a line
  /// may be begun before a broadcast starts and entered after. It is NOT the
  /// wire stream and never gates the session's own execution.
  final _typedLines = <String, TypedLine>{};

  /// The values typed with dots (`${VAR:secret}`) filled into what was typed into
  /// each session, in every way they can stand in a command ([filledForms]), while
  /// the session is there: the shell keeps the line, and an arrow brings it back.
  /// The question before a broadcast shows them masked ([_riskyIn]), and history
  /// does not keep what holds them ([_captureCommand]).
  final _filledSecrets = <String, Set<String>>{};

  /// What is about to be typed into [terminal] has [secrets] filled into it: told to
  /// the session whose typing goes there.
  void noteFilledSecrets(Terminal terminal, Iterable<String> secrets) {
    for (final id in state.keys) {
      if (identical(_typingTerminal(id), terminal) || identical(state[id]?.session?.terminal, terminal)) {
        _filledSecrets.putIfAbsent(id, () => <String>{}).addAll(secrets.expand(filledForms).where((f) => f.isNotEmpty));
        return;
      }
    }
  }

  /// Whether [line] holds any of the session [sessionId]'s values.
  bool _holdsFilledSecret(String line, String sessionId) =>
      _filledSecrets[sessionId]?.any(line.contains) ?? false;

  /// How many forms of its values the session [sessionId] keeps.
  @visibleForTesting
  int filledSecretsKept(String sessionId) => _filledSecrets[sessionId]?.length ?? 0;

  /// When something was last sent into a session's shell at its person's
  /// hand: typed there (or into a terminal that types together with it, or
  /// into a tmux pane of it), or sent for them ([sendInput]). What a shell
  /// that ends is told apart by ([endedAtOwnHand]). Not what the terminal
  /// answers by itself, nor what the app types when a session starts, nor
  /// what someone watching a shared session types: a session they end is
  /// not one its person ended.
  final _lastInputAt = <String, DateTime>{};

  void _noteInput(String sessionId) => _lastInputAt[sessionId] = sessionClock();

  /// When something was last sent into the session [sessionId] at its
  /// person's hand; null where nothing was.
  @visibleForTesting
  DateTime? debugLastInput(String sessionId) => _lastInputAt[sessionId];

  /// Sends [bytes] into the shell of the session [sessionId] for its
  /// person: a snippet they ran, a key that is no text, what another app
  /// handed over for them. The one door for all of that, so that the
  /// session knows when something was last sent at its person's hand.
  /// [atStart] is for what the app types as a session starts (a command it
  /// was opened to run): sent the same, and not counted as its person's
  /// hand on a session that was running. Returns whether there was a shell
  /// to send into.
  bool sendInput(String sessionId, Uint8List bytes, {bool atStart = false}) {
    final shell = state[sessionId]?.session?.shell;
    // (A session that is files only has no shell to type into, nor has a
    // remote screen: its keys go to its picture.)
    if (shell == null || _filesOnly.contains(sessionId) || _screens.contains(sessionId)) return false;
    shell.write(bytes);
    _noteLinesEntered(sessionId, utf8.decode(bytes, allowMalformed: true));
    if (!atStart) _noteInput(sessionId);
    return true;
  }

  /// What was sent into each session for its person since the last line end
  /// ([_noteLinesEntered]). (A window of its own sends its keys one by one.)
  final _sentLines = <String, TypedLine>{};

  /// The app typed [typed] into the session for its person (a snippet, a host's
  /// start-up command, the keys of a window of its own): tmux control mode that
  /// it starts is asked for, as with what is typed by hand
  /// ([TmuxInbandWatcher.lineEntered]).
  void _noteLinesEntered(String sessionId, String typed) {
    final entered = _sentLines.putIfAbsent(sessionId, TypedLine.new).feed(typed);
    final watcher = _tmuxWatchers[sessionId];
    if (watcher == null) return;
    for (final line in entered) {
      watcher.lineEntered(line.text);
    }
  }

  /// The person answered whether to start tmux control mode in [sessionId]
  /// ([tmuxStartQuestionProvider]).
  void answerTmuxStart(String sessionId, bool start) => _tmuxWatchers[sessionId]?.answer(start);

  /// Focused sessions whose broadcast Enter is currently HELD behind an open
  /// destructive-command confirm dialog (C1). While an id is present here we
  /// suppress further broadcast fan-out from that session so nothing races the
  /// modal - belt-and-suspenders on top of the modal barrier already capturing
  /// keyboard focus.
  final _broadcastConfirmPending = <String>{};

  /// Active reconnect timers per session for cancellation.
  final _reconnectTimers = <String, Timer>{};

  /// Auto-eviction timers for failed sessions. Indexed by sessionId
  /// so a retry / new attempt for the same id cancels the pending
  /// eviction - without this, a 2-second eviction scheduled during
  /// the original failure would fire while the retry is still
  /// connecting, evicting a healthy session.
  final _evictionTimers = <String, Timer>{};

  /// The account each session signs in with where it is not its host's
  /// default (3.0, accounts per host: "Connect as"): that identity's id. A
  /// session of the default has none here. Kept while the session is, so
  /// that connecting it again signs in with the same account.
  final _accountOf = <String, String>{};

  /// Sessions opened by a run with nobody there (automation's "open", 3.0):
  /// they sign in only with keys allowed for unattended runs, and ask
  /// nothing. Kept while the session is, for connecting it again.
  final _unattended = <String>{};

  /// Sessions brought back as the app starts, with no click for them, until they
  /// have connected ([startRestoredSession]).
  final _restored = <String>{};
  var _startingRestored = false;

  /// Dropped sessions whose person asked to connect them again ([reconnectNow]),
  /// until they have tried.
  final _reconnectAsked = <String>{};

  /// Whether nobody may be at [sessionId] as it connects, for what it would ask
  /// them: a run with nobody there, one brought back as the app started, one that
  /// connects again by itself. Called once for each try, whose marks it takes.
  bool _nobodyAt(String sessionId) {
    final restored = _restored.remove(sessionId);
    final asked = _reconnectAsked.remove(sessionId);
    if (restored || _unattended.contains(sessionId)) return true;
    return (state[sessionId]?.isReconnecting ?? false) && !asked;
  }

  /// Sessions that are files only (SFTP-only hosts): signed in as SSH, with
  /// no terminal and no shell asked for ([SshService.connectForFiles]), and
  /// shown as their files. A host saved as SFTP only has every session so;
  /// any other SSH host one opened for its files once ("Open its files",
  /// [openFilesInstead]). Kept while the session is, for connecting it again.
  final _filesOnly = <String>{};

  /// Sessions whose host gave them no terminal ([TerminalRefusal]), as they
  /// ended: what is shown in their place offers their files. Until they are
  /// connected again, or closed.
  final _terminalRefusals = <String, TerminalRefusal>{};

  /// Why an RDP session's server ended it, where the server said
  /// ([screenEndOf]), by the session's id, until it connects again or goes.
  final _screenEnds = <String, ScreenFailure>{};

  /// Whether [sessionId] is files only: no terminal, its files instead.
  bool isFilesOnly(String sessionId) => _filesOnly.contains(sessionId);

  /// Sessions that are remote screens (4.0, a VNC host's): a picture
  /// reached through the host's carrier SSH host ([ScreenShellService]), no
  /// terminal. Kept while the session is, for connecting it again.
  final _screens = <String>{};

  /// When each screen session connected, for its team log's last line.
  final _screenConnectedAt = <String, DateTime>{};

  /// Whether [sessionId] is a remote screen's: what shows it is the screen's
  /// view, which talks to its [ScreenShellService.session].
  bool isScreen(String sessionId) => _screens.contains(sessionId);

  /// The remote screens that are RDP's (the others are VNC's, an X program's
  /// among them).
  final _rdpScreens = <String>{};

  /// Whether [sessionId] is an RDP host's screen: what names its kind says
  /// RDP ([ScreenTag]).
  bool isRdpScreen(String sessionId) => _rdpScreens.contains(sessionId);

  /// X programs (4.0) by session: a screen of the SSH host itself,
  /// whose private Xvnc and program the host script starts ([XProgramTarget]).
  /// Each is a tab of its own, never reused, never restored at the next
  /// start (the program ended with the app), and connecting again runs the
  /// program again.
  final _xPrograms = <String, XProgramTarget>{};

  /// Whether [sessionId] is an X program's screen.
  bool isXProgram(String sessionId) => _xPrograms.containsKey(sessionId);

  /// The name of the program of an X program's screen ("xterm"); null for any
  /// other session. What its tab says of its end names it.
  String? xProgramNameOf(String sessionId) => _xPrograms[sessionId]?.name;

  /// The sessions that are a Proxmox guest's console (4.0),
  /// by session: opened from the imported host, through its Proxmox
  /// account, in a tab of their own as an X program's.
  final _consoles = <String, ProxmoxGuest>{};

  /// Whether [sessionId] is a Proxmox guest's console.
  bool isConsole(String sessionId) => _consoles.containsKey(sessionId);

  /// How a console is opened (tests give their own): the real one reaches
  /// Proxmox with the account's token.
  Future<ProxmoxConsole> Function({required Uri base, required String token, required ProxmoxGuest guest, String? pin})?
      debugOpenConsole;

  /// What [sessionId] of [connection] is called: the host's label, or for an
  /// X program the program's name on it ("xterm on gw").
  String _sessionLabel(String sessionId, Connection connection) {
    final host = connection.label.isNotEmpty ? connection.label : hostWithPort(connection.host, connection.port);
    if (_consoles.containsKey(sessionId)) return gl10n.consoleTabLabel(host);
    final x = _xPrograms[sessionId];
    return x == null ? host : gl10n.xProgramTabLabel(xProgramName(x.program), host);
  }

  /// The sessions that are remote screens, connected or on their way.
  Set<String> get screenSessionIds => Set.unmodifiable(_screens);

  /// Remote screens closed cleanly in the background (iOS, which suspends an
  /// app and takes its sockets: ScreenBackgroundKeeper): shown as paused in
  /// their place, connected again when the app is back, and no longer paused
  /// once connected, ended or failed.
  final _parkedScreens = <String>{};

  /// Whether [sessionId] is a remote screen closed in the background.
  bool isParkedScreen(String sessionId) => _parkedScreens.contains(sessionId);

  /// The remote screens closed in the background.
  Set<String> get parkedScreenIds => Set.unmodifiable(_parkedScreens);

  /// Closes the remote screen [sessionId] cleanly while the app is in the
  /// background, its carrier SSH too, and keeps it in its place as paused:
  /// not dropped (nobody is told it was lost, nothing connects again by
  /// itself until the app is back), not ended (its tab and pane stay).
  Future<void> parkScreen(String sessionId) async {
    if (!_screens.contains(sessionId) || state[sessionId]?.status != SessionStatus.connected) return;
    _parkedScreens.add(sessionId);
    await disconnectSession(sessionId);
    // Closed for good now (nothing of it listens any more): a return within
    // the next moments connects it again at once.
    _intentionalDisconnects.remove(sessionId);
    _reconnectCancelled.remove(sessionId);
    final now = state[sessionId];
    if (now != null && mounted) {
      state = {...state, sessionId: now.withLog('screen: Closed while the app is in the background; connects again on return')};
    }
  }

  /// The engine a screen session runs on, for tests (a fake); the Rust one
  /// in the app.
  @visibleForTesting
  ScreenNative? debugScreenNative;

  /// Opens the socket of a screen reached with no SSH host, for tests (the
  /// address and port asked for); a real socket in the app.
  @visibleForTesting
  Future<ScreenChannel> Function(String host, int port)? debugOpenScreenSocket;

  /// Whether [sessionId] is an FTPS host's (3.4): files only, over FTPS
  /// rather than SFTP, so what names it says FTPS.
  bool isFtps(String sessionId) => state[sessionId]?.session?.shell is FtpsShellService;

  /// The sessions that are files only, connected or on their way: nothing
  /// is typed into them (a broadcast passes them over).
  Set<String> get filesOnlySessionIds => Set.unmodifiable(_filesOnly);

  /// How [sessionId]'s host gave it no terminal, where it did; null for any
  /// other session.
  TerminalRefusal? terminalRefusalOf(String sessionId) => _terminalRefusals[sessionId];

  /// Why [sessionId]'s RDP server ended the session, where it gave a reason
  /// the app has words for (idle too long, the account signed in elsewhere,
  /// signed out, shutting down, its licences: ZS-1818 to ZS-1820 and the
  /// uncoded ones of [screenFailureText]); null for any other session, and
  /// for an end the server gave no reason for. What shows the ended session
  /// says this in place of "the host ended the session".
  ScreenFailure? screenEndOf(String sessionId) => _screenEnds[sessionId];

  /// The account [sessionId] was opened with where it is not its host's
  /// default: what opening it again (Duplicate) passes on.
  String? accountOf(String sessionId) => _accountOf[sessionId];

  /// Opens [connection] in another session signed in as [sessionId] is (the
  /// account it was opened with): a split of it.
  String? startLike(String sessionId, Connection connection) {
    // An X program's (4.0): the same program again, in a screen of
    // its own, never the host's terminal.
    final x = _xPrograms[sessionId];
    if (x != null) return _startSession(connection, space: _spaces.spaceOf(connection.id), xProgram: x);
    // A console's: the console again.
    final console = _consoles[sessionId];
    if (console != null) return _startSession(connection, space: _spaces.spaceOf(connection.id), console: console);
    return startSession(connection,
        allowDuplicate: true, asAccount: _accountOf[sessionId], space: _spaces.spaceOf(connection.id));
  }

  /// Opens [sessionId]'s host in another session signed in as it is
  /// (Duplicate). The host is read from its own space, whichever is on
  /// screen. Null where the host is gone, or no session may be opened.
  Future<String?> openLike(String sessionId) async {
    final connId = state[sessionId]?.connectionId;
    if (connId == null) return null;
    final connection = await _sessionDb(connId)?.connectionsDao.getById(connId);
    if (connection == null || !mounted) return null;
    return startLike(sessionId, connection);
  }

  /// Opens [sessionId]'s host for its files in a session of their own, signed
  /// in as it is, on a connection of its own and with no terminal ("Open SFTP
  /// on its own", from the SFTP dock of a session whose connection dropped,
  /// 4.0). A session of the host's files that is open already is the one
  /// given. The host is read from its own space. Null where the host is gone
  /// (or never saved: a Quick connect), or no session may be opened.
  Future<String?> openFilesLike(String sessionId) async {
    final connId = state[sessionId]?.connectionId;
    if (connId == null) return null;
    final connection = await _sessionDb(connId)?.connectionsDao.getById(connId);
    if (connection == null || !mounted) return null;
    return _startSession(connection,
        asAccount: _accountOf[sessionId], space: _spaces.spaceOf(connId), filesOnly: true);
  }

  /// When each session's connection last dropped by itself ([droppedAt]).
  final _droppedAt = <String, DateTime>{};

  /// When [sessionId]'s connection dropped, while it is not connected again:
  /// what its SFTP dock says (4.0). Null for a session that is connected, or
  /// whose connection never dropped by itself.
  DateTime? droppedAt(String sessionId) {
    final s = state[sessionId];
    if (s == null || s.status == SessionStatus.connected) return null;
    return _droppedAt[sessionId];
  }

  /// Ends [sessionId] and opens its host again in a new session, signed in
  /// as it was (Reconnect of a session that is open). The host is read from
  /// its own space, before the session ends: a phone's screen of a session
  /// that is gone goes back to the list, and the session that took its place
  /// was not shown. Null where the host is gone (the session then stays as
  /// it is), or no session may be opened.
  Future<String?> openAgain(String sessionId) async {
    final connId = state[sessionId]?.connectionId;
    if (connId == null) return null;
    // Read before it ends, which forgets it.
    final account = _accountOf[sessionId];
    final xProgram = _xPrograms[sessionId];
    final console = _consoles[sessionId];
    final space = _spaces.spaceOf(connId);
    final connection = await _sessionDb(connId)?.connectionsDao.getById(connId);
    if (connection == null || !mounted) return null;
    unawaited(endSession(sessionId, byThePerson: false));
    // An X program's: the same program again (4.0).
    if (xProgram != null) return _startSession(connection, space: space, xProgram: xProgram);
    if (console != null) return _startSession(connection, space: space, console: console);
    return startSession(connection, allowDuplicate: true, asAccount: account, space: space);
  }

  /// Opens [connectionId] in a new session as a session of it that is gone
  /// was: signed in as [account] (another of its accounts; its own where
  /// null), in the space its sessions work in. For a connection that failed,
  /// which is let go of two seconds after it failed while a phone's screen
  /// still says why, with Try again. Null where the host is gone, or no
  /// session may be opened.
  Future<String?> openHostAgain(String connectionId, {String? account}) async {
    final space = _spaces.spaceOf(connectionId);
    final connection = await _sessionDb(connectionId)?.connectionsDao.getById(connectionId);
    if (connection == null || !mounted) return null;
    return startSession(connection, allowDuplicate: true, asAccount: account, space: space);
  }

  /// The networks' resolver for [connectionId]'s sessions, over its host's
  /// own space (sessions keep their space): the one every
  /// screen uses where that space is the one on screen. (It was always
  /// that one: a host of your Tree connected again while a team space was
  /// on screen was not found there, and connected with what is saved of it,
  /// not as the network it is on has it.)
  ConnectionResolver _resolverFor(String connectionId) {
    final db = _readDb(connectionId);
    AppDatabase? onScreen;
    try {
      onScreen = _ref.read(databaseProvider);
    } catch (_) {
      // Locked, or the space on screen has closed: its own space it is.
    }
    if (identical(db, onScreen)) return _ref.read(connectionResolverProvider);
    return connectionResolverOver(_ref, db);
  }

  /// [connection] as it is signed in to with [account], or as it is (its
  /// default) where [account] is null.
  static Connection _withAccount(Connection connection, String? account) =>
      account == null ? connection : connection.copyWith(identityId: Value(account));

  /// Sessions where auto-reconnect has been explicitly cancelled by the user.
  final _reconnectCancelled = <String>{};

  /// Port forward services per session - persisted across screen navigations.
  /// Keyed by session ID, created on first access, disposed on session close.
  final _portForwardServices = <String, PortForwardService>{};

  /// Get or create the [PortForwardService] for a session.
  ///
  /// The service is tied to the SSH client lifetime. It survives
  /// navigation (opening/closing the port forward screen) so that
  /// active forwards stay running and the UI reflects their status.
  PortForwardService? getPortForwardService(String sessionId) {
    final session = state[sessionId]?.session;
    // A session that is files only forwards nothing.
    if (session == null || _filesOnly.contains(sessionId)) return null;
    final shell = session.shell;
    if (shell is! SshService) return null;

    return _portForwardServices.putIfAbsent(
      sessionId,
      // A forward that runs and lets nothing through says so, once, with
      // why: its connections ended, and nobody was told anything.
      () => PortForwardService(shell.client)..troubles.listen(_tellForwardTrouble),
    );
  }

  void _tellForwardTrouble(ForwardTrouble trouble) {
    final t = gl10n;
    _notify().warning(
      t.pfTroubleTitle(runningForwardName(trouble.forward)),
      body: forwardTroubleSentence(t, trouble),
      details: forwardTroubleReport(trouble),
    );
  }

  // ── Saved port-forward control (desktop Port Forwarding sidebar) ──
  // The sidebar lists SAVED rules but doesn't own an SSH session, so these
  // bridge a rule to whichever live session serves its connection.

  PortForward _ruleToForward(PortForwardRule rule) {
    final type = rule.type == 'remote'
        ? PortForwardType.remote
        : rule.type == 'dynamic'
            ? PortForwardType.dynamic
            : PortForwardType.local;
    return PortForward(
      id: rule.id,
      type: type,
      // Every address of this device where "Allow other devices on my
      // network" is on (it changed only the command shown).
      bindAddress: PortForwardService.bindAddressFor(type, rule.bindAddress, gatewayPorts: rule.gatewayPorts),
      bindPort: rule.bindPort,
      remoteHost: PortForwardService.remoteHostFor(type, rule.remoteHost, gatewayPorts: rule.gatewayPorts),
      remotePort: rule.remotePort,
      label: rule.label,
      autoStart: rule.autoStart,
    );
  }

  /// A connected session id serving [connectionId], or null: one signed in
  /// as the host's own account where there is one, else one opened as
  /// another of its accounts (Connect as, 3.0). A forward saved for a host
  /// is for the host as it is set up; it went to whichever of its sessions
  /// came first, and so ran as the account that one was opened with.
  String? _connectedSessionFor(String connectionId) {
    String? asAnother;
    for (final e in state.entries) {
      // (Not one that is files only: nothing is forwarded on it.)
      if (e.value.connectionId == connectionId &&
          e.value.status == SessionStatus.connected &&
          !_filesOnly.contains(e.key)) {
        if (!_accountOf.containsKey(e.key)) return e.key;
        asAnother ??= e.key;
      }
    }
    return asAnother;
  }

  /// Union of active forward ids across every live session's service.
  Set<String> activeForwardRuleIds() {
    final ids = <String>{};
    for (final pf in _portForwardServices.values) {
      ids.addAll(pf.activeForwardIds);
    }
    return ids;
  }

  /// Push the current active-forward set into [activeForwardIdsProvider] so
  /// the sidebar's Start/Stop buttons reflect reality reactively.
  void refreshForwardStatus() {
    _ref.read(activeForwardIdsProvider.notifier).state =
        activeForwardRuleIds();
  }

  /// Start a saved forward rule on an existing connected session for its
  /// connection. Returns [StartForwardResult.noSession] when no live
  /// session serves the rule's host (the sidebar can't open one).
  Future<StartForwardResult> startSavedForward(PortForwardRule rule) async {
    if (!await hostAllows(rule.connectionId, CrateSwitches.forward)) return StartForwardResult.notAllowed;
    final sessionId = _connectedSessionFor(rule.connectionId);
    if (sessionId == null) return StartForwardResult.noSession;
    final pf = getPortForwardService(sessionId);
    if (pf == null) return StartForwardResult.noSession;
    try {
      await pf.startForward(_ruleToForward(rule));
      _forwardErrors.remove(rule.id);
      refreshForwardStatus();
      return StartForwardResult.started;
    } catch (e) {
      AppLogger.error('Failed to start saved forward ${rule.id}', e);
      _forwardErrors[rule.id] = e;
      refreshForwardStatus();
      return StartForwardResult.error;
    }
  }

  /// What starting each forward last threw, by rule id: what is said about
  /// it says why (3.0: every failure was said to be a port in
  /// use). Kept until it starts.
  final _forwardErrors = <String, Object>{};

  /// What starting [ruleId] last threw, when it failed.
  Object? lastForwardError(String ruleId) => _forwardErrors[ruleId];

  /// Open a session for the forward's host if none is connected, wait for it to
  /// come up, then start the forward. Runs entirely in the notifier because the
  /// Port Forwarding sidebar unmounts the instant a session is created (it only
  /// shows when no session tab is active), so a widget-side wait would be
  /// disposed mid-connect. Fire-and-forget from the UI; this reports its own
  /// outcome to the notification center.
  ///
  /// Handles the sharp edges the sidebar Start button can't: the free-tier
  /// session cap (startSession returns null), a user cancelling the host-key /
  /// password prompt (the session key vanishes with no error), a connect that
  /// hangs on an unanswered host-key prompt (bounded wait), and auto-start
  /// having already started this same forward on connect (would otherwise throw
  /// and misreport as "port in use").
  Future<void> connectThenStartForward(PortForwardRule rule) async {
    // Not where the host's Crate forbids it: no session is opened for it.
    if (!await hostAllows(rule.connectionId, CrateSwitches.forward)) {
      _reportForwardOutcome(rule, StartForwardResult.notAllowed);
      return;
    }
    // Already connected to this host: just start the forward.
    if (_connectedSessionFor(rule.connectionId) != null) {
      _reportForwardOutcome(rule, await startSavedForward(rule));
      return;
    }

    // Said in the app's language, the names masked in recording mode (3.0:
    // before, in English, a failed connection's raw error as it was).
    final t = gl10n;
    final name = forwardDisplayName(rule);
    final conn =
        await _ref.read(connectionsDaoProvider).getById(rule.connectionId);
    if (conn == null) {
      _notify().error(t.pfStartFailedTitle(name), body: t.pfHostGone);
      return;
    }
    // A host that is SFTP only forwards nothing: said, and nothing opened.
    final noTerminal = noTerminalReason(conn, t);
    if (noTerminal != null) {
      _notify().warning(t.pfStartFailedTitle(name), body: noTerminal);
      return;
    }
    // Nor does a Telnet host: no unencrypted session is opened for a forward
    // that cannot run on it.
    if (isTelnetHost(conn)) {
      _notify().warning(t.pfStartFailedTitle(name), body: t.pfNoForwarding);
      return;
    }

    final sessionId = startSession(conn);
    if (sessionId == null) {
      // Free-tier concurrent-session cap (startSession returns null on breach).
      _notify().warning(t.pfStartFailedTitle(name), body: t.pfSessionLimitBody(freeSessionLimit));
      return;
    }

    final hostLabel = Redactable.host(conn.label.isNotEmpty ? conn.label : conn.host).display;
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final st = state[sessionId];
      if (st == null) {
        // The user cancelled a host-key / password prompt: the session was
        // removed with no error state. They opted out; stay silent.
        return;
      }
      if (st.status == SessionStatus.error) {
        final error = st.errorMessage ?? '';
        final why = translator.ConnectionError.translate(error,
            host: Redactable.address(conn.host).display, port: conn.port);
        _notify().error(t.pfStartFailedTitle(name),
            body: why.description,
            details: connectionFailureReport(title: why.title, error: error, kind: why.type.name, log: st.connectionLog));
        return;
      }
      if (st.status == SessionStatus.connected) {
        // Auto-start may already have started this forward on connect. Starting
        // it again throws (and startSavedForward misreports it as a port
        // conflict), so treat an already-active rule as success.
        refreshForwardStatus();
        if (activeForwardRuleIds().contains(rule.id)) {
          _reportForwardOutcome(rule, StartForwardResult.started);
        } else {
          _reportForwardOutcome(rule, await startSavedForward(rule));
        }
        return;
      }
    }
    // Still 'connecting' after the wait (e.g. an unanswered host-key prompt).
    _notify().info(t.pfStartFailedTitle(name), body: t.pfStillConnecting(hostLabel));
  }

  NotificationCenter _notify() =>
      _ref.read(notificationCenterProvider.notifier);

  void _reportForwardOutcome(PortForwardRule rule, StartForwardResult result) {
    final t = gl10n;
    final name = forwardDisplayName(rule);
    switch (result) {
      case StartForwardResult.started:
        _notify().success(t.pfStartedTitle, body: t.pfStartedBody(name));
      case StartForwardResult.error:
        final error = _forwardErrors[rule.id];
        _notify().error(t.pfStartFailedTitle(name),
            body: error == null ? t.pfFailedOther : forwardFailureSentence(t, error, rule),
            details: error == null ? null : forwardFailureReport(rule, error));
      case StartForwardResult.noSession:
        // Connected, but the session can't forward (non-SSH protocol).
        _notify().warning(t.pfStartFailedTitle(name), body: t.pfNoForwarding);
      case StartForwardResult.notAllowed:
        _notify().warning(gl10n.orchardForwardNotAllowed);
    }
  }

  /// Stop a saved forward wherever it is running.
  Future<void> stopSavedForward(String ruleId) async {
    for (final pf in _portForwardServices.values) {
      if (pf.isActive(ruleId)) {
        await pf.stopForward(ruleId);
      }
    }
    refreshForwardStatus();
  }

  ActiveSessionsNotifier(this._ref) : super({}) {
    // A session log that stops (disk full, folder gone) says so in that
    // session's connection log rather than failing silently.
    SessionLogService.onError = _addLog;
  }

  /// Start a new terminal session for a connection.
  ///
  /// Returns the session ID immediately (non-blocking).
  /// The actual SSH/Telnet connection happens asynchronously
  /// and updates the session state as it progresses.
  ///
  /// If [allowDuplicate] is false (default) and a session for the same
  /// connection is already active or connecting, returns its ID instead.
  /// Set [allowDuplicate] to true for explicit "Duplicate Session" action.
  ///
  /// [usernameOverride] allows Quick Connect to pass a parsed username
  /// (e.g. from `ops@192.168.10.30`) that takes priority over the default
  /// username when no identity is attached to the connection.
  ///
  /// [asAccount] signs in with that identity, one of the host's other
  /// accounts (3.0, accounts per host: "Connect as"); the host's default
  /// where it is null or is the default. A session open with another
  /// account is not the one to reuse.
  ///
  /// [unattended]: opened by a run with nobody there (automation's "open",
  /// 3.0): it signs in only with keys allowed for unattended runs (the
  /// host's key on this network, and every jump host's), and asks nothing;
  /// what would be asked stops it, and says so.
  ///
  /// A host saved as SFTP only opens files only, with no terminal
  /// ([isFilesOnly]); an SSH host's session is made one by "Open its files"
  /// ([openFilesInstead]). A session open with a terminal is not the one to
  /// reuse for files only, nor the other way round.
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) =>
      _startSession(connection,
          allowDuplicate: allowDuplicate,
          usernameOverride: usernameOverride,
          initialCommand: initialCommand,
          asAccount: asAccount,
          unattended: unattended,
          space: space);

  /// Opens [xProgram] on the SSH host [connection] in a screen tab of its own
  /// (4.0: "Open an X program..."): its session id, or null where the
  /// plan's session limit is reached, as [startSession].
  String? startXProgram(Connection connection, XProgramTarget xProgram, {Space? space}) =>
      _startSession(connection, space: space, xProgram: xProgram);

  /// Opens the console of the Proxmox guest [connection] was imported from
  /// (its cloud link names it) in a screen tab of its own (4.0: "Open
  /// console"): its session id, or null where the plan's session limit is
  /// reached, or the host names no guest.
  String? startConsole(Connection connection, {Space? space}) {
    final guest = proxmoxGuestOf(connection);
    if (guest == null) return null;
    return _startSession(connection, space: space, console: guest);
  }

  String? _startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
    XProgramTarget? xProgram,
    ProxmoxGuest? console,
    bool filesOnly = false,
  }) {
    final account = asAccount == connection.identityId ? null : asAccount;
    // An X program (4.0) is a screen of the SSH host itself, in a
    // tab of its own every time: never the host's terminal reused, nor the
    // other way round. [filesOnly]: an SSH host's files in a session of
    // their own ([openFilesLike]).
    final files = xProgram == null && console == null && (filesOnly || opensFilesOnly(connection.protocol));
    if (xProgram != null || console != null) allowDuplicate = true;
    // The space this host is opened from: its sessions keep working in it
    // (3.0). [space] where a session of the host opens another
    // (Duplicate, a split, Reconnect): the one that works in; it was the
    // space on screen, so a host of your Tree opened again while a team
    // space was on screen had its keys and jump hosts looked for there.
    _spaces.opened(connection.id, space: space);
    if (!allowDuplicate) {
      // ── Prevent duplicate sessions for the same connection ──
      for (final entry in state.entries) {
        final s = entry.value;
        if (s.connectionId == connection.id &&
            _accountOf[entry.key] == account &&
            _filesOnly.contains(entry.key) == files &&
            !_xPrograms.containsKey(entry.key) &&
            !_consoles.containsKey(entry.key) &&
            (s.status == SessionStatus.connected ||
             s.status == SessionStatus.connecting)) {
          // If the existing session was hidden (the user closed its
          // terminal-tab X earlier), unhide it now - the caller is
          // explicitly asking to re-open this connection, so they
          // expect a visible terminal, not a silently no-op'd click.
          if (s.isHidden) {
            state = {
              ...state,
              entry.key: s.copyWith(isHidden: false),
            };
          }
          AppLogger.info(
            'Reusing existing session ${entry.key} for ${connection.id}',
          );
          return entry.key;
        }
      }
    }

    // ── Service-layer session limit enforcement ──
    // Defense in depth: mirrors the UI check so programmatic / off-UI call
    // sites still enforce the free-tier session cap. This reads the
    // client-side entitlement bool and, like every local gate, is bypassable
    // by a modified/patched client - it is NOT a security boundary. The only
    // asset that must be truly protected (Cloud Sync server storage) is
    // enforced server-side per request.
    // Returns null instead of throwing to prevent crashes at unchecked call sites.
    final isPro = _ref.read(isProProvider);
    if (!isPro) {
      // [occupiedSessionSlots] excludes sessions the user has already started
      // closing, so opening a new one reclaims a closing session's slot at
      // once instead of blocking until the close delay elapses.
      if (occupiedSessionSlots >= freeSessionLimit) {
        AppLogger.warning(
          'Session limit reached ($freeSessionLimit). Blocked at service layer.',
        );
        return null;
      }
    }

    final sessionId =
        '${connection.id}_${DateTime.now().millisecondsSinceEpoch}';
    if (account != null) _accountOf[sessionId] = account;
    if (unattended) _unattended.add(sessionId);
    if (_startingRestored) _restored.add(sessionId);
    if (files) _filesOnly.add(sessionId);
    if (ConnectionProtocol.storedIsScreen(connection.protocol)) _screens.add(sessionId);
    if (connection.protocol == ConnectionProtocol.rdp.name) _rdpScreens.add(sessionId);
    if (xProgram != null) {
      _screens.add(sessionId);
      _xPrograms[sessionId] = xProgram;
    }
    if (console != null) {
      _screens.add(sessionId);
      _consoles[sessionId] = console;
    }

    // Set state to connecting immediately (with connectionId and label)
    final label = _sessionLabel(sessionId, connection);
    state = {
      ...state,
      sessionId: SessionState.connecting(
        connection.id,
        connectionLabel: label,
        host: connection.host,
        port: connection.port,
        username: usernameOverride,
        colorIndex: connection.colorIndex,
        colorValue: connection.colorValue,
      ),
    };

    // Kick off the async connection in the background
    _connectAsync(sessionId, _withAccount(connection, account),
        usernameOverride: usernameOverride, initialCommand: initialCommand);

    return sessionId;
  }

  /// [startSession] for a session brought back as the app starts, with no click
  /// for it: what a team's host would type as it connects is not asked about, and
  /// is not typed without a yes from before.
  String? startRestoredSession(Connection connection) {
    _startingRestored = true;
    try {
      return startSession(connection, allowDuplicate: true);
    } finally {
      _startingRestored = false;
    }
  }

  /// Append a log message to a session's connection log.
  void _addLog(String sessionId, String message) {
    final current = state[sessionId];
    if (current != null && mounted) {
      state = {...state, sessionId: current.withLog(message)};
    }
  }

  /// The actual async connection logic. Updates state as it progresses.
  Future<void> _connectAsync(
    String sessionId,
    Connection connection, {
    String? usernameOverride,
    String? initialCommand,
  }) async {
    SessionWatch? watch;
    final nobodyThere = _nobodyAt(sessionId);
    final thisTry = _connectTries[sessionId] = Object();
    bool endedMeanwhile() => !mounted || !identical(_connectTries[sessionId], thisTry);
    try {
      final label = _sessionLabel(sessionId, connection);

      _addLog(sessionId, 'init: Preparing connection to ${connection.host}:${connection.port}');

      // Files only (an SFTP-only host, or "Open its files"): no terminal and
      // no shell, its SFTP instead. A watched session keeps the connection
      // out of reach of all that works beside its terminal, files too, so a
      // host whose sessions are watched has no files to open: said before
      // anything is asked of anyone or dialled.
      final filesOnly = _filesOnly.contains(sessionId);
      if (filesOnly && await hostIsWatchedIn(_readDb(connection.id), connection.id)) {
        throw OrchardAccessRefused(gl10n.filesOnlyWatched);
      }
      // A remote screen (4.0) cannot be watched yet: one whose host, or the
      // SSH host it is reached through, is in a watched Crate is refused,
      // before anything is asked of anyone or dialled.
      final screen = _screens.contains(sessionId);
      if (screen) {
        // (An X program's carrier is its host itself.)
        await refuseScreenWhereWatched(_readDb(connection.id), connection.id,
            // (A console has none: it is reached through the Proxmox API.)
            carrierId: _xPrograms.containsKey(sessionId) || _consoles.containsKey(sessionId)
                ? null
                : connection.connectViaId,
            refusal: ErrorCodes.withCode(gl10n.screenWatched, ErrorCodes.screenWatched));
      }

      // Session moderation (3.0): a session to a host in a watched
      // Crate starts only once someone else who manages the Crate is
      // watching it. Nothing is connected before that, not even a jump host
      // on the way.
      watch = await _ref.read(watchGateProvider).open(
            sessionId,
            connectionId: connection.id,
            hostLabel: label,
            db: _sessionDb(connection.id),
            log: (line) => _addLog(sessionId, line),
          );
      if (endedMeanwhile()) {
        _watchNeverStarted(sessionId, watch);
        return;
      }
      final watched = watch;

      final ownShell = await _createShell(
        connection,
        onLog: (msg) => _addLog(sessionId, msg),
        usernameOverride: usernameOverride,
        accountChosen: _accountOf.containsKey(sessionId),
        unattended: _unattended.contains(sessionId),
        filesOnly: filesOnly,
        ended: endedMeanwhile,
        xProgram: _xPrograms[sessionId],
        console: _consoles[sessionId],
      );
      // The try lets go of the session (finally) without waiting for the close; unchanged.
      // ignore: unawaited_return_in_try_block
      if (endedMeanwhile()) return _dropEndedTry(sessionId, connection.id, ownShell);
      // Everything typed into a session goes through its shell. A watched
      // session's holds it back while nobody watches, and keeps the
      // connection itself out of reach of what works beside the terminal.
      final ShellService shell = watched == null ? ownShell : WatchedShell(ownShell, watched);
      watched?.onNote = (note) => _watchNoted(sessionId, note);

      _addLog(sessionId, 'shell: Configuring terminal emulator');
      // Scrollback is now honored from Settings (it used to be hard-pinned to
      // 50k, so the Settings control did nothing). A value <= 0 means
      // "unlimited": xterm has no null sentinel, so it maps to a very large
      // cap, as does any larger number. Default stays 50k for heavy build-log
      // users; a row that has left the screen keeps only what it holds.
      final scrollback = _ref.read(scrollbackLinesProvider);
      final terminal = Terminal(
        maxLines: terminalScrollbackLines(scrollback),
        platform: _detectPlatform(),
        wordSeparators: _terminalWordSeparators,
        onBell: _ringBell,
        onTitleChange: (title) {
          // Track terminal title changes (hostname, CWD, etc.): the host's
          // own text, shown as a title is ([cleanTerminalTitle]).
          if (mounted) {
            _ref.read(terminalTitleProvider(sessionId).notifier).state = cleanTerminalTitle(title);
          }
        },
        onPrivateOSC: (code, args) => handlePrivateOsc(sessionId, code, args),
      );
      // A code the terminal could not carry out is passed over, and said once
      // per session where it can be looked up.
      var codeFailureSaid = false;
      terminal.onWriteError = (error, stack) {
        if (codeFailureSaid) return;
        codeFailureSaid = true;
        AppLogger.error('The terminal passed over a code from the host', error, stack);
        _addLog(sessionId, 'terminal: a code from the host could not be carried out and was passed over');
      };

      // Session log to file: opened here so the header carries the target
      // and the first bytes of output are already captured. A reconnect
      // of the same session appends to the file it started.
      // (A remote screen writes nothing there: it has no text.)
      if (_ref.read(sessionLogEnabledProvider) && !screen) {
        // The resolved login name lives on the SSH service (a saved
        // connection's username comes from its identity); other shells
        // (mosh, telnet, local) log the target without one.
        final user = ownShell is SshService ? ownShell.username : usernameOverride;
        final logPath = await SessionLogService.start(
          sessionId,
          label: label,
          target: '${user == null || user.isEmpty ? '' : '$user@'}'
              '${connection.host}:${connection.port}',
          directory: _ref.read(sessionLogDirectoryProvider),
          timestamps: _ref.read(sessionLogTimestampsProvider),
        );
        if (logPath != null) _addLog(sessionId, 'log: writing to $logPath');
      }

      // Team session logs (3.0): a session to a host in a Crate
      // whose owners log sessions is logged for them. Decided here, before
      // any output, so none is missed; the log itself starts in the
      // background.
      final teamDb = _sessionDb(connection.id);
      if (teamDb != null && teamDb.isOrchard) {
        await startTeamSessionLogFor(_ref.read(orchardServiceProvider), teamDb, sessionId,
            connectionId: connection.id,
            label: label,
            host: connection.host,
            port: connection.port,
            // An RDP host's: the account of its key, where it names one (one
            // that is asked for is said in the log once it signed in).
            user: ownShell is SshService
                ? ownShell.username
                : ownShell is ScreenShellService
                    ? switch (ownShell.keyAccount) {
                        final String account => ScreenSessionLogLines.account(account),
                        null => null,
                      }
                    : usernameOverride,
            // A remote screen's log has its header and how it went, never its
            // picture ([ScreenSessionLogLines]).
            kind: screen ? screenLogKind(rdp: connection.protocol == ConnectionProtocol.rdp.name) : null);
      }

      // Wire shell stdout → terminal with output throttling: drawn, and read
      // by the transcript, the logs, the alert rules and the two counters,
      // once every 16 ms (~1 frame) with that batch's text ([OutputBatch]).
      // One decoder for the connection's output: a character that two reads
      // cut in two is put together, where each read decoded on its own
      // showed it as replacement characters.
      final utf8Chunks = Utf8Chunks();
      // A connection made again for this session closes the old batch first.
      _outputBatches.remove(sessionId)?.close();
      final batch = OutputBatch(
        draw: (shown) {
          terminal.write(shown);
          // Session sharing (3.0): those watching a live view of this
          // session get exactly what the terminal was just given.
          SessionShares.output(sessionId, shown);
          // The echo of what was typed may be on screen now.
          _suggesters[sessionId]?.output(_cmdCaptures[sessionId], terminal);
        },
        read: (text, bytes) {
          // Feed to transcript recorder (no-op if not recording)
          SessionTranscriptService.appendOutput(sessionId, text);
          // Session log to file (no-op unless this session opened one).
          SessionLogService.append(sessionId, text);
          // Its team's log (no-op unless one is open or starting).
          TeamSessionLogs.append(sessionId, text);
          // Trigger / highlight rules: scan output for NOTIFY matches. Cheap
          // no-op unless the user has notify rules configured. A line cut
          // in two by a batch is put together by the rules' own scanner.
          _ref.read(triggerRuntimeProvider).processOutput(sessionId, connection.id, text);
          // Signal data activity for UI pulse animation, and the
          // received-byte total for the session-details panel: one write each
          // a batch, where each chunk wrote both.
          if (mounted) {
            _ref.read(sessionDataActivityProvider(sessionId).notifier).state++;
            _ref.read(sessionBytesReceivedProvider(sessionId).notifier).state += bytes;
          }
        },
      );
      _outputBatches[sessionId] = batch;

      // Everything below the tmux demux: ordinary terminal bytes.
      void handleOutput(Uint8List data) {
          final text = utf8Chunks.decode(data);
          // Its batch is set first, so that nothing below it can stop the
          // screen (with the text left behind by something that threw, a
          // session's screen stood still for good, up to 3.2.7).
          batch.add(text, data.length);

          // OSC 133 / OSC 7 shell integration (Phase 2b): enrich the last
          // captured command with exit code, duration and working directory
          // when the remote shell emits it. A plain shell emits nothing.
          _processShellIntegration(sessionId, text);
      }

      // In-band tmux: the session's own bytes are watched for the control
      // mode marker (`tmux -CC` typed here, or on a host reached through this
      // shell). Outside control mode this is one byte scan per chunk and the
      // bytes go straight to handleOutput; inside it the tab shows the tmux
      // workspace and this channel carries tmux commands instead of keys.
      final watcher = TmuxInbandWatcher(
        sendBytes: (bytes) => shell.write(Uint8List.fromList(bytes)),
        onPassthrough: handleOutput,
        onEnter: (c) => _tmuxHostOf(sessionId).attachInband(
              c,
              forceExit: () => _tmuxWatchers[sessionId]?.forcePassthrough(),
            ),
        onExit: (_) => _tmuxHostOf(sessionId).inbandEnded(),
        onAsking: (asking) {
          if (mounted) _ref.read(tmuxStartQuestionProvider(sessionId).notifier).state = asking;
        },
        scrollback: scrollback <= 0 ? 20000 : scrollback.clamp(500, 20000),
        platform: _detectPlatform(),
        log: AppLogger.debug,
      );
      _tmuxWatchers[sessionId] = watcher;

      _stdoutSubscriptions[sessionId] = shell.stdout.listen(
        (data) {
          watcher.addBytes(
            data,
            // tmux's control mode turns this channel into one for commands
            // and draws the panes here: a watched session's stays a
            // terminal, which is what is watched.
            enabled: watched == null && _ref.read(tmuxAutoDetectProvider),
          );
        },
        onDone: () {
          // Flush any remaining buffered data on stream close
          watcher.finish();
          // A character the output ended inside of shows as one replacement.
          batch.finish(utf8Chunks.finish());
          if (identical(_outputBatches[sessionId], batch)) _outputBatches.remove(sessionId);
        },
      );

      // Wire terminal input → shell (with broadcast fan-out).
      // On mobile, the soft keyboard toolbar sets Ctrl/Alt modifiers
      // that must be applied to system-keyboard input.
      terminal.onOutput = (data) {
        // What this is: something typed here by the person, something typed
        // here because it was typed into another terminal that broadcasts
        // (received), a report of the mouse, or the terminal's own answer
        // to something its host asked (where the cursor is, what kind of
        // terminal this is). Only the first is the person's typing in this
        // pane: the soft keys of a phone, a history suggestion, and the
        // broadcast to other hosts belong to it alone. An answer goes to
        // the host that asked and nowhere else: sent on to other hosts, it
        // was typed into whatever ran there, and a dialog took it for keys.
        final origin = terminal.outputOrigin;
        final typedEvent = terminal.outputTyped;
        final received = _broadcastReceiving.contains(sessionId);
        final typedHere = origin == TerminalOutputOrigin.typed && !received;
        String transformed = data;
        if (typedHere) {
          final modifier = _ref.read(mobileSoftKeyModifierProvider);
          if (modifier == SoftKeyModifier.ctrl && data.length == 1) {
            final code = data.toUpperCase().codeUnitAt(0) - 64;
            if (code >= 1 && code <= 26) {
              transformed = String.fromCharCode(code);
            }
            _ref.read(mobileSoftKeyModifierProvider.notifier).state =
                SoftKeyModifier.none;
          } else if (modifier == SoftKeyModifier.alt && data.length == 1) {
            transformed = '\x1B$data';
            _ref.read(mobileSoftKeyModifierProvider.notifier).state =
                SoftKeyModifier.none;
          }
          // A history suggestion on screen (3.0): Right arrow sends the rest
          // of it, as if typed. Until then none of it was sent anywhere.
          transformed = _suggesterFor(sessionId, connection).input(transformed, terminal);
        }
        // In tmux control mode this channel carries tmux COMMANDS, so raw
        // keys must never reach it (a stray Enter detaches, and text would
        // be parsed as commands). They go to the focused pane instead.
        final tmuxWatcher = _tmuxWatchers[sessionId];
        final inTmux = tmuxWatcher != null && tmuxWatcher.inControl;
        if (inTmux) {
          final c = tmuxWatcher.controller!;
          final paneId = c.activeWindow?.activePaneId;
          if (paneId != null) c.sendText(paneId, transformed);
        } else {
          // LOCAL/FOCUSED session ALWAYS gets its input immediately and
          // unconditionally - the broadcast gate below only ever affects the
          // fan-out to OTHER hosts, never this session's own execution.
          //
          // SECURITY: encode as UTF-8, never `.codeUnits`.
          //
          // `String.codeUnits` yields UTF-16 units and `Uint8List.fromList`
          // silently TRUNCATES each to 8 bits, so any character above U+00FF
          // was rewritten into an unrelated control byte on the wire:
          // 'ě' (U+011B) became 0x1B = ESC, 'Ċ' (U+010A) became 0x0A = Enter.
          // Typing or pasting ordinary non-Latin text could therefore
          // synthesise escape sequences and newlines - i.e. execute commands
          // the user never entered.
          shell.write(Uint8List.fromList(utf8.encode(transformed)));
        }

        // An answer of the terminal's own, or the mouse, is no command and
        // is nobody else's.
        if (origin != TerminalOutputOrigin.typed) return;
        for (final line in _typedLines.putIfAbsent(sessionId, TypedLine.new).feed(transformed)) {
          tmuxWatcher?.lineEntered(line.text);
        }
        _noteInput(sessionId);

        // What was received is not typed on from here: it is no command of
        // this terminal's to record, there is no suggestion for it, and it
        // is not broadcast a second time.
        if (received) {
          if (!inTmux) _followReceived(sessionId, terminal, transformed);
          return;
        }

        if (!inTmux) {
          // Command history capture (Squeezed feature; device toggle). Feeds
          // the input to the per-session reconstructor, which records a
          // command only for a trusted, echoed, non-sensitive line - passwords
          // are never echoed, so they are never captured.
          _captureCommand(sessionId, connection, terminal, transformed);
          _suggesterFor(sessionId, connection).typed(_cmdCaptures[sessionId], terminal);
        }

        // Broadcast to the terminals that type together with this one. What
        // is typed into the others: what was typed here, by what the person
        // did (so each terminal sends it the way ITS program asked: an arrow
        // key, a paste's brackets); where this terminal changed it on the way
        // (a soft key held on a phone, a suggestion taken), the text it
        // became.
        _broadcastTyped(
          sessionId,
          transformed,
          typedEvent != null && transformed == data ? typedEvent : TypedText(transformed),
        );
      };

      // Wire terminal resize → shell.
      //
      // This fires INSIDE the layout phase (xterm RenderTerminal.performLayout)
      // on every window resize, for every mounted TerminalView, and drives a
      // synchronous SSH window-change send. On a half-closed channel that send
      // can throw; swallow it so a resize can never fault the layout pass (the
      // new size still applies to the local grid). Logged, not surfaced.
      terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        try {
          shell.resize(width, height);
        } catch (e) {
          AppLogger.warning('Terminal resize send failed for $sessionId: $e');
        }
        // A live view of this session follows its size.
        SessionShares.resized(sessionId, width, height);
      };

      // Session sharing (3.0): keys from a viewer the person sharing handed
      // the keyboard to. Typed into THIS session only: never fanned out to
      // other hosts (broadcast), never kept as this person's command
      // history. While the tab shows tmux in control mode this channel
      // carries tmux commands, so nothing from a viewer is typed.
      _shareTypers[sessionId] = (bytes) {
        final tmuxWatcher = _tmuxWatchers[sessionId];
        if (tmuxWatcher != null && tmuxWatcher.inControl) return;
        shell.write(bytes);
      };

      // Ended while this was made ready: it is not dialled.
      // The try lets go of the session (finally) without waiting for the close; unchanged.
      // ignore: unawaited_return_in_try_block
      if (endedMeanwhile()) return _dropEndedTry(sessionId, connection.id, shell);
      _addLog(sessionId, 'connect: Initiating connection...');
      if (filesOnly) {
        // Signed in with no terminal and no shell asked for: the server of
        // a host that gives files only refuses both. (What it is opened with
        // is always an SSH connection: _createShell makes one for it.)
        if (ownShell is! SshService) throw StateError('A session that is files only needs an SSH connection');
        await ownShell.connectForFiles(notice: gl10n.sessionFilesOnlyLine);
      } else {
        await shell.connect();
      }
      // When the shell started: one that ends at once is a host that gives
      // no terminal (terminalRefusalAtEnd).
      final connectedAt = sessionClock();

      // Ended while it connected (a change of profile ended all sessions, or its person
      // closed it): this connection holds a login that nothing else would ever close.
      // The try lets go of the session (finally) without waiting for the close; unchanged.
      // ignore: unawaited_return_in_try_block
      if (endedMeanwhile()) return _dropEndedTry(sessionId, connection.id, shell);
      // From here on, nobody watching means typing is held.
      watched?.connected();

      // "Forward agent" is on for this host, and the host refused it. The
      // session is there all the same (it used to fail for that); its person
      // is told, so that keys not being found from that host has a reason.
      if (ownShell is SshService && ownShell.agentForwardingRefused) {
        _notify().warning(gl10n.agentRefusedTitle(Redactable.host(label).display), body: gl10n.agentRefusedBody);
      }

      // A Hosts-panel tmux badge was clicked on a host that was not
      // connected: open tmux now that it is. (Not in a session with no
      // terminal: it stays asked for until a terminal opens.)
      if (!filesOnly && !screen && _ref.read(tmuxPendingConnectionProvider) == connection.id) {
        _ref.read(tmuxPendingConnectionProvider.notifier).state = null;
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          final host = _tmuxHostOf(sessionId);
          if (!host.active) host.begin();
        });
      }

      // Monitor disconnect and notify (only for unexpected disconnects)
      _connectionStateSubscriptions[sessionId] =
          shell.connectionState.listen((connected) {
        if (!connected && mounted) {
          // Tear down the port-forward service first so the bound
          // local ServerSockets are released. Without this, an
          // unexpected disconnect (network change, server-side kill,
          // mid-flight EOF) leaves `127.0.0.1:<port>` listening
          // forever even though its parent SSH client is dead, and
          // the user can't free the port short of force-quitting the
          // app. `endSession` and `_maybeAutoReconnect` already do
          // this same cleanup on their controlled paths - this
          // closes the gap on the unsolicited-disconnect path.
          //
          // Safe to call before auto-reconnect because reconnect
          // re-creates the service lazily via `getPortForwardService`
          // and re-applies forwards through `_autoStartPortForwards`
          // after the new SSH session settles.
          _portForwardServices.remove(sessionId)?.dispose();
          refreshForwardStatus();
          // A shared session's share ends when its connection does, whether
          // it comes back or not: what comes back is another shell, and
          // nobody else watches it or types into it without being asked
          // again. What the host said last and is not on screen yet (it
          // waits a moment to be drawn with what follows) is shown first,
          // here and to whoever watches. (With what waited for an answer about
          // tmux control mode: there is nothing left to answer about.)
          watcher.answer(false);
          batch.flushNow();
          _shareTypers.remove(sessionId);
          SessionWatches.end(sessionId);
          SessionShares.sessionClosed(sessionId);
          // The shell ended by itself: that is no dropped connection, and
          // connecting again by itself (the old behavior) just reopened a
          // shell that had ended.
          if (shell.exitedCleanly &&
              !_intentionalDisconnects.contains(sessionId)) {
            // AT ITS PERSON'S HAND: they typed `exit`, pressed Ctrl+D, ran
            // what ends the session. Tear the session down and remove its
            // tab/pane, exactly like the close button does.
            if (endedAtOwnHand(lastInput: _lastInputAt[sessionId], endedAt: sessionClock())) {
              // Remove the session from its work tab's pane tree (closes
              // the tab if it was the last session in it). No-op on
              // platforms / layouts without a pane tree.
              _ref.read(workTabsProvider.notifier).removeSession(sessionId);
              // Full teardown: cancels reconnect timers, disconnects the
              // (already-exited) shell, drops the session from state.
              // Fire-and-forget - we're inside a stream callback.
              // ignore: discarded_futures
              endSession(sessionId);
              return;
            }
            // THE HOST'S DOING: nobody here had asked for it. The session
            // stays in its place, as ended, with how it ended and the last
            // the host said. (Its tab was closed at once, whoever ended it:
            // an account that prints a notice and leaves was never read,
            // and a session ended by a limit on idle time was just gone.)
            // Nothing connects again by itself: what ended it would end it
            // again.
            final how = ownShell is ShellExit ? ownShell as ShellExit : null;
            final said = lastWords(lastRows(terminal));
            final cause = sessionEndedCause(
              exitCode: how?.exitCode,
              signal: how?.exitSignal,
              said: said,
            );
            // A host that gives no terminal: its server said it allows SFTP
            // only, or the shell ended as it opened. What shows the session
            // offers its files then.
            final refusal = ownShell is SshService
                ? terminalRefusalAtEnd(
                    said: said, connectedAt: connectedAt, endedAt: sessionClock(), lastInput: _lastInputAt[sessionId])
                : null;
            if (refusal != null) _terminalRefusals[sessionId] = refusal;
            // An RDP server says why it ends a session; a VNC one cannot.
            if (ownShell is ScreenShellService && ownShell.protocol == ScreenProtocol.rdp) {
              final closed = ownShell.closedWith;
              if (closed != null && closed.detail != null) {
                _screenEnds[sessionId] = ScreenFailure.ofClosed(closed, rdp: true);
              }
            }
            _droppedAt[sessionId] = sessionClock();
            final ended = state[sessionId];
            final endedState = SessionState.disconnected(
              connectionId: connection.id,
              connectionLabel: label,
              host: connection.host,
              port: connection.port,
              connectionLog: ended?.connectionLog ?? const [],
              dropped: true,
              dropCause: cause,
            ).copyWith(
              colorIndex: ended?.colorIndex,
              colorValue: ended?.colorValue,
              isHidden: ended?.isHidden,
              lastStartedAt: ended?.startedAt,
            );
            state = {
              ...state,
              // (How it ended is the log's last line, as for any session.)
              sessionId: (refusal == null
                      ? endedState
                      : endedState.withLog('ended: The host gave no terminal (${refusal.name}): its files are offered'))
                  .withLog('ended: ${asLogLine(cause)}'),
            };
            _syncForegroundService();
            return;
          }

          final before = state[sessionId];
          _droppedAt[sessionId] = sessionClock();
          state = {
            ...state,
            // Dropped: shown in its place with why and Reconnect. Its colour
            // and whether it is hidden stay (both were lost here, so a
            // tab's colour changed when its connection dropped), and when
            // it started.
            sessionId: SessionState.disconnected(
              connectionId: connection.id,
              connectionLabel: label,
              host: connection.host,
              port: connection.port,
              connectionLog: before?.connectionLog ?? const [],
              dropped: true,
            ).copyWith(
              colorIndex: before?.colorIndex,
              colorValue: before?.colorValue,
              isHidden: before?.isHidden,
              lastStartedAt: before?.startedAt,
            ),
          };
          // Why it dropped, once the connection says (a moment after it
          // does, or never: then it stays unsaid).
          if (shell is ShellEndReason) {
            unawaited((shell as ShellEndReason)
                .endReason
                .timeout(const Duration(seconds: 2), onTimeout: () => null)
                .then((cause) => _noteDropCause(sessionId, cause)));
          }
          // Update foreground service (may stop if no sessions left)
          _syncForegroundService();

          // Only for unexpected disconnects, and as Settings says.
          if (!_intentionalDisconnects.contains(sessionId)) {
            _tellConnectionLost(sessionId, label);
            // Trigger auto-reconnect if enabled. Never for a watched
            // session: connecting again needs someone watching again, and
            // that is asked for by the person, not by a timer.
            if (watched == null) _maybeAutoReconnect(sessionId, connection.id);
          }
        }
      });

      final session = TerminalSession(
        id: sessionId,
        connectionId: connection.id,
        terminal: terminal,
        shell: shell,
        startedAt: DateTime.now(),
      );

      // Preserve the log and colorIndex in the connected state
      final currentState = state[sessionId];
      final currentLog = currentState?.connectionLog ?? [];
      state = {
        ...state,
        sessionId: SessionState.connected(
          session,
          connectionLog: [...currentLog, 'ready: Session established ✓'],
          connectionLabel: label,
          host: connection.host,
          port: connection.port,
          // Who it is signed in as (the identity's username for a saved
          // host, which was never said: the session told only Quick
          // Connect's).
          username: ownShell is SshService ? ownShell.username : (currentState?.username ?? usernameOverride),
          colorIndex: currentState?.colorIndex ?? connection.colorIndex,
          colorValue: currentState?.colorValue ?? connection.colorValue,
        ),
      };
      AppLogger.info('Session $sessionId connected');

      // Connected: nothing to offer for a certificate it did not get before,
      // nor for a Crate that was closed.
      _offerCertificateFromOwner(connection.id, null);
      _offerOfflinePass(connection.id, null);
      // Nor is it refused for an old key exchange any more (3.4).
      _ref.read(kexRefusedHostsProvider.notifier).connected(connection.id);

      // Stamp last-connected so "last used" reflects desktop sessions too. Host
      // cards + the Keys/identity screen derive last-used from
      // MAX(connections.lastConnected); previously only the mobile + quick-
      // connect paths touched it, so a desktop-only user always saw "never".
      _sessionDb(connection.id)?.connectionsDao.touchLastConnected(connection.id);

      // A connection to a team's host: a note while its owners record
      // activity.
      final orchardDb = _sessionDb(connection.id);
      if (orchardDb != null && orchardDb.isOrchard) {
        unawaited(noteActivityIn(_ref.read(orchardServiceProvider), orchardDb, ActivityKind.connect,
            itemKind: 'host', itemKey: connection.id, name: connection.label));
      }

      // A session with no terminal has no shell for what is typed into one
      // as it starts (its variables, its startup command and snippet), and
      // nothing runs on its host: no forwards, no command that reads its
      // system (its server answers each with "sftp connections only").
      if (screen) {
        // Its team's log, where its Crate logs sessions: what it holds, and
        // that the screen connected.
        _screenConnectedAt[sessionId] = sessionClock();
        // Back after the background closed it: no longer paused.
        _parkedScreens.remove(sessionId);
        TeamSessionLogs.append(sessionId,
            '${ScreenSessionLogLines.notRecordedFor(rdp: connection.protocol == ConnectionProtocol.rdp.name)}\n');
        TeamSessionLogs.append(sessionId,
            '${ScreenSessionLogLines.connected(viaCarrier: ownShell is ScreenShellService && ownShell.viaCarrier)}\n');
        // RDP with NLA: which account the server let in.
        final account = ownShell is ScreenShellService ? ownShell.signedInAs : null;
        if (account != null) TeamSessionLogs.append(sessionId, '${ScreenSessionLogLines.signedIn(account)}\n');
        // A clipboard this device shares from the start (its person turned
        // it on before) is said too; each change after is said as it is made.
        if (ownShell is ScreenShellService &&
            screenClipboardOnFor(_ref.read(sharedPreferencesProvider), ownShell.options,
                inTeam: ownShell.inTeam, connectionId: ownShell.connectionId)) {
          TeamSessionLogs.append(sessionId, '${ScreenSessionLogLines.clipboard(on: true)}\n');
        }
      } else if (!filesOnly) {
        final db = _sessionDb(connection.id);
        if (db == null || db.isOrchard) {
          // A team's host: what its record types is its person's to allow.
          await _typeTeamConnectCommands(sessionId, shell, terminal, db, connection,
              initialCommand: initialCommand, nobodyThere: nobodyThere);
        } else {
          // Inject environment variables if configured
          _injectEnvVars(sessionId, label, shell, connection.envVars);

          // On-connect commands, once the shell is live (same post-connect
          // channel as env vars). An explicit [initialCommand] - SFTP "Open
          // terminal here" cd'ing into the folder the pane was showing - is a
          // contextual override and wins outright; otherwise run the host's own
          // configured startup command and its "Run snippet on connect", both
          // stored on the record.
          if (initialCommand != null && initialCommand.isNotEmpty) {
            _injectInitialCommand(sessionId, shell, initialCommand);
          } else {
            await _injectConnectCommands(sessionId, shell, connection);
          }
        }
      }

      // What was typed may have waited for its person: a session ended by now starts
      // nothing more.
      if (endedMeanwhile()) return;

      // Start or update the Android foreground service
      _syncForegroundService();

      // Auto-start pre-configured port forwards for this connection
      if (shell is SshService && !filesOnly) {
        _autoStartPortForwards(sessionId, connection.id);
      }

      // Detect remote OS in the background (non-blocking, fire-and-forget).
      // Only runs once per connection - skips if already cached.
      if (shell is SshService && !filesOnly) {
        _detectRemoteOs(connection.id, shell.client);
      }
    } on ConnectionCancelledException {
      // User cancelled a prompt (password, host key, etc.) - silently
      // remove the connecting session without showing an error state.
      _watchNeverStarted(sessionId, watch);
      if (endedMeanwhile()) {
        _endedTryStopped(sessionId, connection.id);
        return;
      }
      _dropPendingOpens(connection.id);
      _dropCancelledSession(sessionId);
    } on SshPromptCancelled {
      // The same for a server's own sign-in question (a 2FA code).
      _watchNeverStarted(sessionId, watch);
      if (endedMeanwhile()) {
        _endedTryStopped(sessionId, connection.id);
        return;
      }
      _dropPendingOpens(connection.id);
      _dropCancelledSession(sessionId);
    } on SessionWatchCancelled {
      // The same when nobody was asked to watch, or the wait was given up.
      _dropPendingOpens(connection.id);
      _dropCancelledSession(sessionId);
    } catch (e, stack) {
      _watchNeverStarted(sessionId, watch);
      // Ended while it connected: nobody is waiting to hear how that went.
      if (endedMeanwhile()) {
        AppLogger.info('Session $sessionId was ended while it connected, and the try failed (${errorKind(e)})');
        _dropPendingOpens(connection.id);
        return;
      }
      // A try of connecting again by itself keeps them: the loop goes on.
      if (!(state[sessionId]?.isReconnecting ?? false)) _dropPendingOpens(connection.id);
      // A host's key that its person was shown and did not accept: they
      // said no themselves, as when they cancel a question, and nothing
      // failed that they have to be told of. (A session that is being
      // connected again stays, and says it: nobody may be looking.)
      if (hostKeyDeclinedByItsPerson(e) && !(state[sessionId]?.isReconnecting ?? false)) {
        _dropCancelledSession(sessionId);
        return;
      }
      AppLogger.error('Failed to start session', e, stack);
      if (mounted) {
        // The key of a jump host on the way can take a certificate as well.
        final failedWith = e is JumpHostFailure ? e.cause : e;
        _offerCertificateFromOwner(
            connection.id, failedWith is SSHAuthFailedException ? failedWith.handover : null);
        _offerOfflinePass(connection.id, e);
        // Refused for an old key exchange that Compatibility mode would
        // take: its card says so, and a bulk edit offers the mode for it
        // (3.4). A jump host's refusal is the jump host's.
        if (!connection.compatibilityMode && refusedForOldKeyExchange(e)) {
          _ref.read(kexRefusedHostsProvider.notifier).refused(connection.id);
        }
        final label = _sessionLabel(sessionId, connection);
        final errorState = state[sessionId];
        final currentLog = errorState?.connectionLog ?? [];
        // A try of connecting again by itself that failed (3.0):
        // the session stays, its connection gone, with what this try said,
        // and the loop tries again or gives up (_scheduleReconnectAttempt).
        // It was taken for a new connection that failed: the session was
        // removed 2 s later, and on a computer the failure dialog ended it at
        // once, so the loop never got past its first try.
        if (errorState != null && errorState.isReconnecting) {
          if (reconnectCannotHelp(e)) _reconnectEnds.add(sessionId);
          state = {
            ...state,
            sessionId: SessionState.disconnected(
              connectionId: connection.id,
              connectionLabel: label,
              host: connection.host,
              port: connection.port,
              errorMessage: connectionFailureText(e),
              connectionLog: [...currentLog, 'error: $e'],
              username: usernameOverride,
              dropped: true,
              dropCause: errorState.dropCause,
            ).copyWith(
              isReconnecting: true,
              reconnectAttempt: errorState.reconnectAttempt,
              maxRetries: errorState.maxRetries,
              colorIndex: errorState.colorIndex,
              colorValue: errorState.colorValue,
              isHidden: errorState.isHidden,
              lastStartedAt: errorState.startedAt,
            ),
          };
          return;
        }
        // Briefly mark as error so any pane currently rendering this
        // session can show a quick error banner - but keep the
        // lifecycle short. The fix for the +N-badge-balloon-on-failed
        // -auth bug is auto-removing this session after ~2s so the
        // work-tab listener cleans up the leaf, the badge count drops,
        // and the pane disappears. The notification system carries
        // the error message itself; persisting the dead session in
        // the tree was the bug.
        state = {
          ...state,
          sessionId: SessionState.error(
            connectionFailureText(e),
            connectionId: connection.id,
            connectionLog: [...currentLog, 'error: $e'],
            connectionLabel: label,
            host: connection.host,
            port: connection.port,
          ).copyWith(
            colorIndex: errorState?.colorIndex ?? connection.colorIndex,
            colorValue: errorState?.colorValue ?? connection.colorValue,
          ),
        };

        // Surface error to the UI via connectionErrorProvider. Pass the
        // sessionId + connectionId so the dialog can close the failed
        // tab when it opens (avoiding red-tab-pile-up) and Retry can
        // start a fresh session even after the old one is gone.
        final fullLog = [...currentLog, 'error: $e'];
        _ref.read(connectionErrorProvider.notifier).state = ConnectionError(
          host: connection.host,
          port: connection.port,
          errorMessage: connectionFailureText(e),
          connectionLabel: label,
          // usernameOverride is the quick-connect username the user typed; a
          // saved connection's username lives on its identity, and those forms
          // reach the log as `user@host`, which the free-text scan masks.
          username: usernameOverride,
          connectionLog: fullLog,
          sessionId: sessionId,
          connectionId: connection.id,
        );

        // Auto-evict dead sessions after a short visibility window. The
        // [WorkTabsNotifier] watches `activeSessionsProvider` and
        // fires `removeSession` on every key disappearing from the
        // map, which prunes the leaf out of the pane tree and
        // recomputes the +N badge. Without this eviction, every
        // failed connect attempt accumulates in the tab forever
        // (a tab showed "log-store +6" with only 2 visible panes).
        //
        // SECURITY: cancel any prior eviction timer for the same
        // sessionId before scheduling a new one. Reusing a sessionId
        // (e.g. retry path) would otherwise let an old timer fire
        // 2s into the retry's lifetime and evict a healthy
        // connecting session.
        _evictionTimers.remove(sessionId)?.cancel();
        _evictionTimers[sessionId] =
            Timer(const Duration(seconds: 2), () {
          _evictionTimers.remove(sessionId);
          if (!mounted) return;
          final current = state[sessionId];
          // Only evict if it's still in the error state we set -
          // the user may have retried (which would have changed
          // the status to connecting) or dismissed manually.
          if (current?.status == SessionStatus.error) {
            _accountOf.remove(sessionId);
            _unattended.remove(sessionId);
            _restored.remove(sessionId);
            _reconnectAsked.remove(sessionId);
            _filesOnly.remove(sessionId);
            _screens.remove(sessionId);
            _rdpScreens.remove(sessionId);
            _xPrograms.remove(sessionId);
            _consoles.remove(sessionId);
            _parkedScreens.remove(sessionId);
            _terminalRefusals.remove(sessionId);
            _screenEnds.remove(sessionId);
            _droppedAt.remove(sessionId);
            final updated = Map<String, SessionState>.from(state)
              ..remove(sessionId);
            state = updated;
          }
        });
      }
    } finally {
      if (identical(_connectTries[sessionId], thisTry)) _connectTries.remove(sessionId);
    }
  }

  /// A try of connecting [sessionId] that stopped at a question of its sign-in after it
  /// was ended ([_connectTries]): the session has gone, or a newer try has it, and neither
  /// is dropped as a person's cancel would be.
  void _endedTryStopped(String sessionId, String connectionId) {
    AppLogger.info('Session $sessionId was ended while its sign-in asked');
    if (!mounted || !_connectTries.containsKey(sessionId)) _dropPendingOpens(connectionId);
  }

  /// A try of connecting [sessionId] that was ended while it ran ([_connectTries]): what
  /// it made goes, its connection above all: that login would stay live, with nothing
  /// left holding it, until the app quits. (A newer try of the same session has the rest
  /// as its own by now.)
  Future<void> _dropEndedTry(String sessionId, String connectionId, ShellService shell) async {
    AppLogger.info('Session $sessionId was ended while it connected');
    if (!mounted || !_connectTries.containsKey(sessionId)) {
      _stdoutSubscriptions.remove(sessionId)?.cancel();
      _outputBatches.remove(sessionId)?.close();
      _disposeCaptureState(sessionId);
      _dropPendingOpens(connectionId);
    }
    try {
      await shell.disconnect();
    } catch (e) {
      AppLogger.warning('A connection that was ended did not close by itself (${errorKind(e)})');
    }
  }

  /// Keeps, for whatever shows this host's failure, that a certificate can
  /// be had from an owner directly ([offer], the Crate that takes it), or
  /// that it no longer can (null): the host connected, or failed for
  /// another reason.
  void _offerCertificateFromOwner(String connectionId, ({String orchardId, String crateId})? offer) {
    final offers = _ref.read(certificateFromOwnerOfferProvider);
    if (offer == null && !offers.containsKey(connectionId)) return;
    _ref.read(certificateFromOwnerOfferProvider.notifier).state = {
      for (final e in offers.entries)
        if (e.key != connectionId) e.key: e.value,
      connectionId: ?offer,
    };
  }

  /// Keeps, for whatever shows this host's failure, that an owner can sign
  /// an offline pass for the Crate that refused the connection ([failure] a
  /// [CrateClosedOffline] that names its Orchard), or that there is nothing
  /// of the kind to offer (anything else): the host connected, or failed
  /// for another reason, or its Crate was held until a set time that has
  /// come, which no pass opens.
  void _offerOfflinePass(String connectionId, Object? failure) {
    final offer = switch (failure) {
      CrateClosedOffline(:final orchardId?, :final crateId, accessOver: false) =>
        (orchardId: orchardId, crateId: crateId),
      _ => null,
    };
    final offers = _ref.read(offlinePassOfferProvider);
    if (offer == null && !offers.containsKey(connectionId)) return;
    _ref.read(offlinePassOfferProvider.notifier).state = {
      for (final e in offers.entries)
        if (e.key != connectionId) e.key: e.value,
      connectionId: ?offer,
    };
  }

  /// A watched session (3.0) whose connection was not made after
  /// all: its watch is over, and those asked to watch are told the session
  /// closed.
  void _watchNeverStarted(String sessionId, SessionWatch? watch) {
    if (watch == null) return;
    _shareTypers.remove(sessionId);
    SessionWatches.end(sessionId);
    SessionShares.sessionClosed(sessionId);
  }

  /// A connection to [connectionId] that was not made: what was asked to
  /// open once it was up (its files from a phone's host sheet, tmux from a
  /// host's badge) is asked no longer. Kept, the next session to that host
  /// opened them by itself, whenever and however it was started.
  void _dropPendingOpens(String connectionId) {
    if (!mounted) return;
    final files = _ref.read(sftpPendingConnectionProvider.notifier);
    if (files.state == connectionId) files.state = null;
    final tmux = _ref.read(tmuxPendingConnectionProvider.notifier);
    if (tmux.state == connectionId) tmux.state = null;
  }

  /// Lets the held session [sessionId] go on with nobody watching, where
  /// ZestSSH Cloud cannot be reached and this account may go on then (3.0,
  /// the outage work): [WatchGate.goOnUnwatched], which asks for the reason
  /// and keeps what is reported first, and throws where it may not.
  Future<void> goOnUnwatched(String sessionId) async {
    final session = state[sessionId];
    final connectionId = session?.connectionId;
    if (session == null || connectionId == null) return;
    await _ref.read(watchGateProvider).goOnUnwatched(
          sessionId,
          hostLabel: session.connectionLabel,
          db: _sessionDb(connectionId),
          log: (line) => _addLog(sessionId, line),
        );
  }

  /// Whether the held session [sessionId] could go on with nobody watching
  /// now ([WatchGate.mayGoOnUnwatched]): for whatever shows it.
  Future<bool> mayGoOnUnwatched(String sessionId) async {
    final connectionId = state[sessionId]?.connectionId;
    if (connectionId == null) return false;
    return _ref.read(watchGateProvider).mayGoOnUnwatched(sessionId, db: _sessionDb(connectionId));
  }

  /// What happens to a watched session once it runs (3.0): its
  /// team's log gets a line, the person is told, and one that nobody
  /// watched for too long is closed here.
  void _watchNoted(String sessionId, WatchNote note) {
    final l10n = gl10n;
    final line = switch (note) {
      WatchNote.held => l10n.watchLogHeld,
      WatchNote.watchedAgain => l10n.watchLogWatchedAgain,
      WatchNote.closedUnwatched => l10n.watchLogClosed,
      WatchNote.unwatched => l10n.watchLogUnwatched,
    };
    TeamSessionLogs.append(sessionId, '\r\n[ZestSSH] $line\r\n');
    watchNoticeHandler?.call(sessionId, note);
    if (note == WatchNote.closedUnwatched) unawaited(endSession(sessionId, byThePerson: false));
  }

  /// Inject environment variables into the shell session.
  ///
  /// Parses the JSON-encoded [envVarsJson] string and sends
  /// `export KEY=VALUE` commands to the shell. Values are single-quoted
  /// to prevent shell expansion. Runs silently before the user sees the prompt.
  ///
  /// A value with a control character in it is not typed: it would act as a
  /// key on the way in, quotes or no quotes ([CommandText.mayBeTyped]), and a
  /// host's settings can come from an import or a shared link. The person is
  /// told which, by name, and the rest is set.
  void _injectEnvVars(String sessionId, String label, ShellService shell, String envVarsJson) {
    if (envVarsJson.isEmpty) return;
    try {
      final Map<String, dynamic> vars = jsonDecode(envVarsJson) as Map<String, dynamic>;
      if (vars.isEmpty) return;
      final buffer = StringBuffer();
      final refused = <String>[];
      for (final entry in vars.entries) {
        final key = entry.key;
        final value = entry.value.toString();
        // Validate key: must be a valid shell variable name
        if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(key)) continue;
        if (!CommandText.mayBeTyped(value)) {
          refused.add(key);
          continue;
        }
        buffer.write('export $key=${CommandText.quoted(value)}; ');
      }
      if (refused.isNotEmpty) {
        final names = refused.join(', ');
        _addLog(sessionId, 'env: not set, a control character in the value: $names');
        final title = gl10n.envVarNotTypedTitle(names);
        _notify().warning(
          title,
          body: gl10n.envVarNotTypedBody(Redactable.host(label).display),
          details: ErrorReport.build(what: title, where: "Setting a host's environment variables as a session starts"),
        );
      }
      if (buffer.isEmpty) return;
      // Enter runs the exports; the screen is cleared after them so they do not
      // clutter the person's first prompt.
      final cmd = CommandText.entered('${buffer}clear');
      shell.write(Uint8List.fromList(utf8.encode(cmd)));
      AppLogger.info('Injected ${vars.length} environment variable(s)');
    } catch (e) {
      AppLogger.error('Failed to inject environment variables', e);
    }
  }

  /// What a team's host types as a session of it starts, in the Orchard database
  /// [db] (null: it has closed since, and nothing can be read of it), once its
  /// person has allowed this exact text on this host ([TeamConnectCommands]).
  /// What is allowed from before is typed at once; otherwise the person is asked,
  /// with the session already open behind the question, and until the answer
  /// nothing is typed. Where nobody may be there ([nobodyThere]), or what it would
  /// type is too long to show, nothing is asked, nothing is typed, and the
  /// terminal says so. [initialCommand] is the person's own, typed either way.
  Future<void> _typeTeamConnectCommands(
    String sessionId,
    ShellService shell,
    Terminal terminal,
    AppDatabase? db,
    Connection connection, {
    String? initialCommand,
    required bool nobodyThere,
  }) async {
    final own = initialCommand != null && initialCommand.isNotEmpty;
    if (own) _injectInitialCommand(sessionId, shell, initialCommand);
    if (db == null) return;
    final TeamConnectCommands commands;
    try {
      commands = await teamConnectCommandsOf(db, connection, startup: !own);
    } catch (e) {
      AppLogger.error('Failed to read what a team host types as it connects', e);
      return;
    }
    if (commands.isEmpty) return;

    void type() {
      if (commands.variables.isNotEmpty) _injectEnvVars(sessionId, connection.label, shell, connection.envVars);
      if (commands.startup != null) _injectInitialCommand(sessionId, shell, commands.startup!);
      if (commands.snippet != null) _injectInitialCommand(sessionId, shell, commands.snippet!);
    }

    void notRun(String why) {
      final line = '\r\n[ZestSSH] $why\r\n';
      terminal.write(line);
      TeamSessionLogs.append(sessionId, line);
      _addLog(sessionId, 'team: $why');
    }

    final use = commands.useOn(connection.id);
    if (await teamCommandsAllowedIn(db, use)) {
      type();
      return;
    }
    if (commands.tooLong) {
      notRun(gl10n.teamCommandsNotRunLong);
      return;
    }
    if (nobodyThere) {
      notRun(gl10n.teamCommandsNotRunNobody);
      return;
    }
    // Not waited for: the session is open, and what follows (its forwards, its
    // status) does not wait on a question that may stand two minutes.
    unawaited(() async {
      try {
        final yes = await askTeamCommands(
          _ref.read,
          TeamCommandsRequest(
            hostLabel: connection.label.isNotEmpty ? connection.label : connection.host,
            address: hostWithPort(connection.host, connection.port),
            commands: commands,
          ),
        );
        // The session it was asked for may be gone by the answer.
        final stillOpen = mounted && state[sessionId]?.status == SessionStatus.connected && shell.isConnected;
        if (yes) {
          await rememberTeamCommandsIn(db, use);
          if (stillOpen) type();
        } else if (stillOpen) {
          notRun(gl10n.teamCommandsNotRunDeclined);
        }
      } catch (e) {
        // (The app closing under the question, its Orchard locking.) Nothing was
        // typed that was not said yes to.
        AppLogger.warning('A question about a team host\'s commands ended unanswered: $e');
      }
    }());
  }

  /// Types a command into a freshly-connected shell and enters it (the `cd`
  /// behind SFTP's "Open terminal here", a host's start-up command, its
  /// snippet on connect): one Enter per line end, and one at the end.
  void _injectInitialCommand(String sessionId, ShellService shell, String command) {
    try {
      shell.write(
          Uint8List.fromList(utf8.encode(CommandText.entered(command))));
      _noteLinesEntered(sessionId, CommandText.entered(command));
    } catch (e) {
      AppLogger.error('Failed to inject initial command', e);
    }
  }

  /// Run a host's configured on-connect commands once its shell is live: the
  /// free-text [Connections.startupCommand] first, then its "Run snippet on
  /// connect" ([Connections.snippetId]) when that snippet is safe to auto-run.
  ///
  /// A snippet is auto-run only when it needs no interactive input: any snippet
  /// carrying a list/secret/no-default variable, or one flagged
  /// confirm-before-run, is skipped, because there is nobody to prompt
  /// mid-connect. `${VAR:-default}` placeholders take their defaults, every
  /// occurrence ([commandWithDefaults]): left to the shell, a `${VAR}` beside one
  /// was empty.
  Future<void> _injectConnectCommands(
    String sessionId,
    ShellService shell,
    Connection connection,
  ) async {
    final startup = connection.startupCommand?.trim() ?? '';
    if (startup.isNotEmpty) {
      _injectInitialCommand(sessionId, shell, startup);
    }

    final snippetId = connection.snippetId;
    if (snippetId == null || snippetId.isEmpty) return;
    try {
      final snippet = await _readDb(connection.id).snippetsDao.getById(snippetId);
      if (snippet == null) return;
      if (!snippetRunsUnattended(snippet.command,
          confirmBeforeRun: snippet.confirmBeforeRun)) {
        AppLogger.info(
          'On-connect snippet "${snippet.label}" skipped: it needs '
          'confirmation or variable input',
        );
        return;
      }
      _injectInitialCommand(sessionId, shell, commandWithDefaults(snippet.command));
    } catch (e) {
      AppLogger.error('Failed to run on-connect snippet', e);
    }
  }

  /// Record a run command into synced history (Squeezed feature). Reconstructs
  /// the line from keystrokes and records only a trusted, echoed, non-sensitive
  /// command (see [CommandCapture]). A cheap no-op for non-Pro users or when
  /// recording is switched off.
  void _captureCommand(
    String sessionId,
    Connection connection,
    Terminal terminal,
    String input,
  ) {
    if (!_ref.read(isProProvider)) return;
    if (!_ref.read(commandHistoryEnabledProvider)) return;
    final capture = _cmdCaptures.putIfAbsent(sessionId, CommandCapture.new);
    final cmd = capture.onInput(input, () {
      try {
        // Reconstruct the FULL logical cursor line, joining any wrapped
        // continuation rows, so a command longer than the terminal is wide is
        // seen whole by the echo check (reading only the last row dropped
        // every wrapped command from history).
        final buf = terminal.buffer;
        return joinLogicalLine(
          buf.absoluteCursorY,
          (y) => buf.lines[y].toString(),
          (y) => buf.lines[y].isWrapped,
        );
      } catch (_) {
        return '';
      }
    });
    if (cmd != null) {
      // A value typed with dots is never in what is synced, opted in or not: the
      // Inspector's Run again read one out from here, and recording mode with it.
      if (_holdsFilledSecret(cmd, sessionId)) return;
      // Secret policy: unless the user opted in to recording secret-bearing
      // commands, drop ones whose arguments look like they carry a secret.
      // (Passwords typed at a hidden prompt are already excluded by the echo
      // check inside CommandCapture, regardless of this opt-in.)
      if (!_ref.read(commandHistoryIncludeSensitiveProvider) &&
          commandLooksSensitive(cmd)) {
        return;
      }
      final at = DateTime.now();
      // Into the session's own space: an Orchard session's commands never
      // land in your Tree's history.
      final historyDb = _sessionDb(connection.id);
      if (historyDb == null) return;
      final idFuture = historyDb.commandHistoryDao.record(
            command: cmd,
            connectionId: connection.id,
            hostLabel: connection.label,
            cwd: _sessionCwd[sessionId],
            at: at,
          );
      // Await the exit code + duration from a later OSC 133 ;D, if the shell
      // emits one. A new command replaces any prior pending: a command with no
      // ;D before the next one simply never gets a result, which is correct for
      // a shell without integration.
      _pendingCmd[sessionId] = _PendingCmd(idFuture, at);
    }
  }

  /// Feed a session's stdout to its OSC 133 / OSC 7 parser and apply the results:
  /// the terminal's folder for everyone ([terminalFolderProvider], 4.0: the
  /// SFTP dock goes to it and can follow it), and for command history the
  /// working directory stamped for the next command, the pending command's
  /// start refined on ;C, and its exit code + duration written on ;D. What
  /// history keeps is gated on the same Pro + recording toggle as capture; the
  /// scan itself costs one search for ESC per chunk where no OSC comes.
  void _processShellIntegration(String sessionId, String text) {
    final parser =
        _shellIntegration.putIfAbsent(sessionId, ShellIntegrationParser.new);
    final events = parser.addOutput(text);
    if (events.isEmpty) return;
    final recording = _ref.read(isProProvider) && _ref.read(commandHistoryEnabledProvider);
    for (final e in events) {
      switch (e) {
        case OscCwd(:final path):
          // Told only when it changed: many shells say it at every prompt.
          if (mounted) {
            final folder = _ref.read(terminalFolderProvider(sessionId).notifier);
            if (folder.state != path) folder.state = path;
          }
          if (recording) _sessionCwd[sessionId] = path;
        case OscCommandStart() when !recording:
        case OscCommandEnd() when !recording:
          break;
        case OscCommandStart():
          _pendingCmd[sessionId]?.start = DateTime.now();
        case OscCommandEnd(:final exitCode):
          final pending = _pendingCmd.remove(sessionId);
          if (pending == null) break;
          final durationMs =
              DateTime.now().difference(pending.start).inMilliseconds;
          final historyConnection = state[sessionId]?.connectionId;
          final dao = historyConnection == null
              ? null
              : _sessionDb(historyConnection)?.commandHistoryDao;
          if (dao == null) break;
          // The insert is a fast local write that ran before this ;D, so the id
          // future is normally already resolved; await it to stay race-safe.
          pending.idFuture.then((id) => dao.updateResult(
                id,
                exitCode: exitCode,
                durationMs: durationMs >= 0 ? durationMs : null,
              ));
        case OscPromptStart():
          break; // nothing to attach
      }
    }
  }

  /// Drop all per-session command-history capture state: the keystroke
  /// reconstructor, the OSC shell-integration parser, the last working directory
  /// and any command still awaiting its result. Called from every session
  /// teardown path.
  void _disposeCaptureState(String sessionId) {
    // A remote screen's team log ends with how long it lasted.
    final screenFrom = _screenConnectedAt.remove(sessionId);
    if (screenFrom != null) {
      TeamSessionLogs.append(sessionId, '${ScreenSessionLogLines.ended(sessionClock().difference(screenFrom))}\n');
    }
    unawaited(SessionLogService.end(sessionId));
    unawaited(TeamSessionLogs.end(sessionId));
    // A shared session's share ends with it: those watching are told the
    // session closed. A watched session's watch is over too (also one
    // still waiting for someone to join: closing its tab gives up).
    _shareTypers.remove(sessionId);
    SessionWatches.end(sessionId);
    SessionShares.sessionClosed(sessionId);
    _tmuxWatchers.remove(sessionId)?.dispose();
    _sentLines.remove(sessionId);
    _cmdCaptures.remove(sessionId);
    _suggesters.remove(sessionId);
    final completionSftp = _completionSftp.remove(sessionId);
    if (completionSftp != null) unawaited(completionSftp.then((s) => s.close(), onError: (Object _) {}));
    _completionSftpOff.remove(sessionId);
    _completionListings.removeWhere((key, _) => key.startsWith('$sessionId\u0000'));
    _shellIntegration.remove(sessionId);
    _sessionCwd.remove(sessionId);
    // Connected again, it is another shell, which says its own folder.
    if (mounted) _ref.read(terminalFolderProvider(sessionId).notifier).state = null;
    _pendingCmd.remove(sessionId);
    _osc52IgnoredLogged.remove(sessionId);
  }

  /// Sessions that already logged one "remote copy ignored" line, so a
  /// program that yanks on every keystroke does not fill the connection log.
  final _osc52IgnoredLogged = <String>{};

  /// OSC sequences the emulator does not handle itself, for a plain session
  /// or a tmux pane of it. Today that is only OSC 52 (remote copy to the
  /// local clipboard); everything else is dropped. See [Osc52] for why the
  /// read-back form is refused and why writes are opt-in.
  void handlePrivateOsc(String sessionId, String code, List<String> args) {
    if (code != Osc52.code) return;
    if (Osc52.isQuery(args)) {
      _addLog(sessionId, 'osc52: clipboard read request refused');
      return;
    }
    if (!_ref.read(osc52ClipboardProvider)) {
      // Off by default: say so once, so a user wondering why a yank never
      // reached the clipboard finds the switch.
      if (_osc52IgnoredLogged.add(sessionId)) {
        _addLog(
          sessionId,
          'osc52: remote copy ignored (off in Settings > Terminal)',
        );
      }
      return;
    }
    final text = Osc52.decode(args);
    if (text == null) return;
    Clipboard.setData(ClipboardData(text: text));
    _addLog(sessionId, 'osc52: ${text.length} characters copied to the clipboard');
  }

  /// The forwards a session is starting by itself, by rule id: another
  /// session of the host that connects meanwhile leaves them to it.
  final _forwardsStarting = <String>{};

  /// [_autoStartPortForwards], for tests of two sessions that start them at
  /// once.
  @visibleForTesting
  Future<void> debugAutoStartPortForwards(String sessionId, String connectionId) =>
      _autoStartPortForwards(sessionId, connectionId);

  /// Auto-start pre-configured port forward rules for a connection. Port
  /// forwarding is free (22 October 2026); the host's Crate must allow it.
  Future<void> _autoStartPortForwards(
    String sessionId,
    String connectionId,
  ) async {
    // Gate: the host's Crate must allow it (3.0).
    if (!await hostAllows(connectionId, CrateSwitches.forward)) {
      AppLogger.info('Skipping auto-start port forwards: not allowed in this Crate');
      return;
    }

    try {
      final dao = _readDb(connectionId).portForwardRulesDao;

      // Resolve the currently-active Network so we only auto-start
      // rules pinned to it (or to "all networks").  We read the
      // detected-network provider non-blocking - if detection
      // hasn't completed yet, treat the active network as null,
      // which the DAO interprets as "only fire un-pinned rules".
      final detected = _ref.read(detectedNetworkProvider).valueOrNull;
      final activeNetworkId = detected?.id;

      final rules = await dao.getAutoStartRulesForNetwork(
          connectionId, activeNetworkId);
      if (rules.isEmpty) return;

      final pfService = getPortForwardService(sessionId);
      if (pfService == null) return;
      for (final rule in rules) {
        // A forward another session of the host already has up, or is
        // starting (two that connect at once), is left to it: a second
        // session started it again, found its port taken, and said that it
        // could not be started.
        if (activeForwardRuleIds().contains(rule.id) || !_forwardsStarting.add(rule.id)) continue;
        try {
          final type = rule.type == 'remote'
              ? PortForwardType.remote
              : rule.type == 'dynamic'
                  ? PortForwardType.dynamic
                  : PortForwardType.local;
          final forward = PortForward(
            id: rule.id,
            type: type,
            bindAddress: PortForwardService.bindAddressFor(type, rule.bindAddress, gatewayPorts: rule.gatewayPorts),
            bindPort: rule.bindPort,
            remoteHost: PortForwardService.remoteHostFor(type, rule.remoteHost, gatewayPorts: rule.gatewayPorts),
            remotePort: rule.remotePort,
            label: rule.label,
            autoStart: true,
          );
          await pfService.startForward(forward);
          _forwardErrors.remove(rule.id);
          AppLogger.info(
            'Auto-started port forward: ${rule.label ?? forward.description}',
          );
        } catch (e) {
          // Told, with why: it was only logged, so a forward set to start
          // with the connection was simply not there (3.0).
          _forwardErrors[rule.id] = e;
          _reportForwardOutcome(rule, StartForwardResult.error);
          AppLogger.error(
            'Failed to auto-start port forward ${rule.label ?? rule.id}',
            e,
          );
        } finally {
          _forwardsStarting.remove(rule.id);
        }
      }
      refreshForwardStatus();
    } catch (e) {
      AppLogger.error('Failed to load auto-start port forwards', e);
    }
  }

  // ── Remote OS detection ──────────────────────────────────────

  /// Detect the remote OS in the background and cache the result.
  ///
  /// Skips detection if the connection already has a cached OS.
  /// Runs asynchronously so it never blocks the connection flow.
  Future<void> _detectRemoteOs(String connectionId, SSHClient client) async {
    try {
      final cache = _ref.read(osDetectionCacheProvider.notifier);
      if (!cache.has(connectionId)) {
        final osKind = await OsDetectionService.detect(client);
        if (!mounted) return;
        cache.set(connectionId, osKind);
        AppLogger.info('Detected OS for $connectionId: ${osKind.name}');
      }
      // The host keeps its system's icon where it has none, so every device
      // shows it (3.2).
      await keepDetectedHostIcons(
        dao: _ref.read(connectionsDaoProvider),
        crud: _ref.read(connectionCrudProvider),
        seen: _ref.read(osDetectionCacheProvider),
        onlyId: connectionId,
      );
    } catch (e) {
      AppLogger.warning('OS detection failed for $connectionId: $e');
    }
  }

  // ── Auto-reconnect logic ─────────────────────────────────────

  /// Maximum number of reconnect attempts.
  static const _maxReconnectAttempts = 10;

  /// Sessions whose last try of connecting again ended in a way no further
  /// try changes ([reconnectCannotHelp]): noted where the try fails, read
  /// where the next one would be set.
  final _reconnectEnds = <String>{};

  /// Calculate exponential backoff delay: 2s, 4s, 8s, 16s, capped at 30s.
  Duration _reconnectDelay(int attempt) {
    final debug = debugReconnectDelay;
    if (debug != null) return debug;
    final seconds = (2 << (attempt - 1)).clamp(2, 30);
    return Duration(seconds: seconds);
  }

  /// Every wait between tries of connecting again, for tests (which cannot
  /// wait the real two seconds and more). Null in the app.
  @visibleForTesting
  static Duration? debugReconnectDelay;

  /// Removes a session whose connect the user cancelled, without an error.
  void _dropCancelledSession(String sessionId) {
    AppLogger.info('Session $sessionId cancelled by user');
    _filesOnly.remove(sessionId);
    _screens.remove(sessionId);
    _rdpScreens.remove(sessionId);
    _xPrograms.remove(sessionId);
    _consoles.remove(sessionId);
    _parkedScreens.remove(sessionId);
    _terminalRefusals.remove(sessionId);
    _screenEnds.remove(sessionId);
    _droppedAt.remove(sessionId);
    if (mounted) {
      final updated = Map<String, SessionState>.from(state);
      updated.remove(sessionId);
      state = updated;
    }
  }

  /// Check whether auto-reconnect should fire and start the loop.
  void _maybeAutoReconnect(String sessionId, String connectionId) {
    if (!mounted) return;
    if (_intentionalDisconnects.contains(sessionId)) return;
    if (_reconnectCancelled.contains(sessionId)) return;

    final autoReconnect = _ref.read(autoReconnectEnabledProvider);
    if (!autoReconnect) return;

    startAutoReconnect(sessionId);
  }

  /// Begin the auto-reconnect loop for a session.
  ///
  /// Retries with exponential backoff up to [_maxReconnectAttempts].
  void startAutoReconnect(String sessionId) {
    final current = state[sessionId];
    if (current == null) return;
    final connectionId = current.connectionId;
    if (connectionId == null) return;

    // Cancel any existing reconnect timer for this session
    _reconnectTimers[sessionId]?.cancel();
    _reconnectCancelled.remove(sessionId);

    // Start at attempt 1
    _scheduleReconnectAttempt(sessionId, connectionId, 1);
  }

  /// Why [sessionId]'s connection dropped, said by the connection a moment
  /// after it did: kept while it is still dropped and nothing said it before.
  void _noteDropCause(String sessionId, String? cause) {
    if (cause == null || !mounted) return;
    final now = state[sessionId];
    if (now == null || !now.dropped || now.dropCause != null) return;
    state = {
      ...state,
      sessionId: now.copyWith(dropCause: cause).withLog('dropped: $cause'),
    };
    // The host's key failed while the session was open, or the key of a
    // jump host on the way to it: somebody may have got into the
    // connection. Connecting again is for its person to do, who is told
    // what happened: a session that came back by itself, with the right
    // key again, would leave nothing of it to see.
    if (endReasonItself(cause) == hostKeyFailedAtNewKeys) stopAutoReconnect(sessionId);
  }

  /// Connect a dropped session again now, in its place: its tab and pane
  /// stay, and the loop of connecting again by itself starts with a try at
  /// once (Reconnect where a dropped session is shown).
  void reconnectNow(String sessionId) {
    final current = state[sessionId];
    if (current == null) return;
    final connectionId = current.connectionId;
    if (connectionId == null) return;
    if (current.status == SessionStatus.connected || current.status == SessionStatus.connecting) return;
    _reconnectTimers[sessionId]?.cancel();
    _reconnectCancelled.remove(sessionId);
    _reconnectAsked.add(sessionId);
    _scheduleReconnectAttempt(sessionId, connectionId, 1, delay: Duration.zero);
  }

  /// "Open its files", for a session whose host gave it no terminal
  /// ([terminalRefusalOf]): the session is connected again in its place,
  /// files only this time; its tab, its pane and its screen stay. The host
  /// is left as it is, so the next session to it asks for a terminal again
  /// ([makeHostSftpOnly] changes that).
  void openFilesInstead(String sessionId) {
    final current = state[sessionId];
    if (current == null || current.connectionId == null) return;
    _filesOnly.add(sessionId);
    _terminalRefusals.remove(sessionId);
    _screenEnds.remove(sessionId);
    reconnectNow(sessionId);
  }

  /// "Make this host SFTP only", for a session whose host gave it no
  /// terminal: the host is saved as SFTP only, in its own space, so that
  /// every session to it opens its files from now on, on every device it
  /// syncs to, and this session is opened so ([openFilesInstead]). False,
  /// and nothing changed, where the host is not saved (Quick connect), is
  /// gone, or is in a Crate that does not let this account change it.
  Future<bool> makeHostSftpOnly(String sessionId) async {
    final connectionId = state[sessionId]?.connectionId;
    if (connectionId == null) return false;
    final db = _sessionDb(connectionId);
    if (db == null) return false;
    final host = await db.connectionsDao.getById(connectionId);
    if (host == null || !await mayEditIn(db, 'host', connectionId)) return false;
    await db.connectionsDao.updateConnection(ConnectionsCompanion(
      id: Value(connectionId),
      protocol: Value(ConnectionProtocol.sftp.name),
      updatedAt: Value(DateTime.now()),
    ));
    if (mounted) openFilesInstead(sessionId);
    return true;
  }

  /// Schedule a single reconnect attempt after the appropriate delay
  /// ([delay] when given).
  void _scheduleReconnectAttempt(
    String sessionId,
    String connectionId,
    int attempt, {
    Duration? delay,
  }) {
    if (!mounted) return;
    if (attempt > _maxReconnectAttempts) {
      // Max retries reached - update state so UI shows failure
      final current = state[sessionId];
      if (current != null) {
        state = {
          ...state,
          sessionId: current.copyWith(
            isReconnecting: false,
            reconnectAttempt: attempt - 1,
          ),
        };
      }
      AppLogger.info(
        'Auto-reconnect for $sessionId gave up after ${attempt - 1} attempts',
      );
      return;
    }

    // Update state to show reconnecting status
    final current = state[sessionId];
    if (current != null) {
      state = {
        ...state,
        sessionId: current.copyWith(
          isReconnecting: true,
          reconnectAttempt: attempt,
          maxRetries: _maxReconnectAttempts,
        ),
      };
    }

    final wait = delay ?? _reconnectDelay(attempt);
    AppLogger.info(
      'Auto-reconnect $sessionId: attempt $attempt/$_maxReconnectAttempts '
      'in ${wait.inSeconds}s',
    );

    _reconnectTimers[sessionId] = Timer(wait, () async {
      if (!mounted) return;
      if (_reconnectCancelled.contains(sessionId)) return;
      if (_intentionalDisconnects.contains(sessionId)) return;

      // Check if session was already reconnected or removed
      final sessionState = state[sessionId];
      if (sessionState == null) return;
      if (sessionState.status == SessionStatus.connected ||
          sessionState.status == SessionStatus.connecting) {
        return;
      }

      try {
        // The host's own space, even if another is on screen now.
        final db = _sessionDb(connectionId);
        if (db == null) {
          AppLogger.warning('Auto-reconnect: the host\'s Orchard is closed');
          return;
        }
        final dao = db.connectionsDao;
        final connection = await dao.getById(connectionId);
        if (connection == null) {
          AppLogger.warning(
            'Auto-reconnect: connection $connectionId no longer exists',
          );
          return;
        }

        // Clean up old subscriptions and port forward service
        _stdoutSubscriptions.remove(sessionId)?.cancel();
        _disposeCaptureState(sessionId);
        _connectionStateSubscriptions.remove(sessionId)?.cancel();
        _outputBatches.remove(sessionId)?.close();
        _typedLines.remove(sessionId);
        _broadcastConfirmPending.remove(sessionId);
        _portForwardServices.remove(sessionId)?.dispose();
        refreshForwardStatus();
        // What its last shell's end said of its host is about that one.
        _terminalRefusals.remove(sessionId);
        _screenEnds.remove(sessionId);
        // A host made SFTP only since: its files, from now on.
        if (opensFilesOnly(connection.protocol) && !_xPrograms.containsKey(sessionId) && !_consoles.containsKey(sessionId)) {
          _filesOnly.add(sessionId);
        }
        if (ConnectionProtocol.storedIsScreen(connection.protocol)) _screens.add(sessionId);
        if (connection.protocol == ConnectionProtocol.rdp.name) _rdpScreens.add(sessionId);
        // Update state to connecting
        final label = _sessionLabel(sessionId, connection);
        state = {
          ...state,
          sessionId: SessionState.connecting(
            connectionId,
            connectionLabel: label,
            host: connection.host,
            port: connection.port,
          ).copyWith(
            isReconnecting: true,
            reconnectAttempt: attempt,
            maxRetries: _maxReconnectAttempts,
            // Its colour, whether it is hidden and why it dropped stay
            // through the tries.
            colorIndex: sessionState.colorIndex,
            colorValue: sessionState.colorValue,
            isHidden: sessionState.isHidden,
            dropCause: sessionState.dropCause,
          ),
        };

        // An account chosen for the session (Connect as) is signed in with
        // again, unless the host has had it taken off since: its default is.
        final account = _accountOf[sessionId];
        if (account != null && !(await db.hostAccountsDao.otherAccountsOf(connectionId)).contains(account)) {
          _accountOf.remove(sessionId);
        }

        // Attempt the connection (reuses existing _connectAsync)
        await _connectAsync(sessionId, _withAccount(connection, _accountOf[sessionId]));

        // If we get here and session is connected, reconnect succeeded
        if (mounted) {
          final postState = state[sessionId];
          if (postState?.status == SessionStatus.connected) {
            // Clear reconnect state
            state = {
              ...state,
              sessionId: postState!.copyWith(
                isReconnecting: false,
                reconnectAttempt: 0,
              ),
            };
            AppLogger.info('Auto-reconnect $sessionId succeeded on attempt $attempt');
            return;
          }
          // Connection failed (error state): the next try, unless this one
          // ended in a way no further try changes. Then the session stays
          // as it is, dropped, with what the host said, which try this was
          // (the failed try wrote both) and Reconnect.
          if (_reconnectEnds.remove(sessionId)) {
            if (postState != null) {
              state = {...state, sessionId: postState.copyWith(isReconnecting: false)};
            }
            AppLogger.info('Auto-reconnect $sessionId stopped at attempt $attempt: trying again cannot help');
            return;
          }
          _scheduleReconnectAttempt(sessionId, connectionId, attempt + 1);
        }
      } catch (e) {
        AppLogger.error('Auto-reconnect attempt $attempt failed', e);
        if (mounted && !_reconnectCancelled.contains(sessionId)) {
          _scheduleReconnectAttempt(sessionId, connectionId, attempt + 1);
        }
      }
    });
  }

  /// Stop the auto-reconnect loop for a session.
  void stopAutoReconnect(String sessionId) {
    _reconnectTimers[sessionId]?.cancel();
    _reconnectTimers.remove(sessionId);
    _reconnectCancelled.add(sessionId);

    final current = state[sessionId];
    if (current != null && mounted) {
      state = {
        ...state,
        sessionId: current.copyWith(
          isReconnecting: false,
        ),
      };
    }
  }

  /// Disconnect and clean up a session. [byThePerson]: the person ended it
  /// (closed it, typed exit); false where the app did (opened it again,
  /// closed it unwatched, a viewer's request, every session at once), which
  /// is never a session to count toward asking for a rating.
  Future<void> endSession(String sessionId, {bool byThePerson = true}) async {
    // Mark as intentional before disconnecting to suppress notification
    _intentionalDisconnects.add(sessionId);
    _connectTries.remove(sessionId);

    // Cancel any active auto-reconnect
    _reconnectTimers[sessionId]?.cancel();
    _reconnectTimers.remove(sessionId);
    _reconnectCancelled.add(sessionId);

    // Cancel stream subscriptions, timers, and port forward service
    _stdoutSubscriptions.remove(sessionId)?.cancel();
    _disposeCaptureState(sessionId);
    _connectionStateSubscriptions.remove(sessionId)?.cancel();
    _outputBatches.remove(sessionId)?.close();
    _typedLines.remove(sessionId);
    _filledSecrets.remove(sessionId);
    _lastInputAt.remove(sessionId);
    _broadcastConfirmPending.remove(sessionId);
    _portForwardServices.remove(sessionId)?.dispose();
    refreshForwardStatus();
    // Cancel a pending eviction timer too - disconnecting before
    // the 2s eviction fire would otherwise leave the timer running
    // and evict the session later (potentially after a retry has
    // reused the same id).
    _evictionTimers.remove(sessionId)?.cancel();
    _accountOf.remove(sessionId);
    _unattended.remove(sessionId);
    _restored.remove(sessionId);
    _reconnectAsked.remove(sessionId);
    _filesOnly.remove(sessionId);
    _screens.remove(sessionId);
    _rdpScreens.remove(sessionId);
    _xPrograms.remove(sessionId);
    _consoles.remove(sessionId);
    _parkedScreens.remove(sessionId);
    _terminalRefusals.remove(sessionId);
    _screenEnds.remove(sessionId);
    _droppedAt.remove(sessionId);

    final sessionState = state[sessionId];
    final connId = sessionState?.connectionId;
    // A recording of the session is saved as it ends: it was left in memory
    // and lost (and a phone threw it away as the session's screen closed).
    final recording = SessionTranscriptService.isRecording(sessionId)
        ? _saveRecordingAsItEnds(sessionId, sessionState?.connectionLabel)
        : null;
    if (sessionState?.session != null) {
      await sessionState!.session!.shell.disconnect();
    }
    state = {
      ...state,
      sessionId: SessionState.disconnected(connectionId: connId),
    };

    // Update foreground service (may stop if no sessions left)
    _syncForegroundService();
    await recording;
    if (byThePerson) _maybeAskForRating(sessionId, sessionState);

    // Remove from state after a brief delay so UI can show disconnected
    Future.delayed(const Duration(seconds: 2), () {
      _intentionalDisconnects.remove(sessionId);
      _reconnectCancelled.remove(sessionId);
      // The entry is gone for good: a later session with this id (none in
      // practice, ids are unique) starts its own log file.
      SessionLogService.forget(sessionId);
      if (mounted) {
        final updated = Map<String, SessionState>.from(state);
        updated.remove(sessionId);
        state = updated;
      }
    });
  }

  /// A session the person kept open a while and closed themselves went
  /// well: on a phone, the stores' rating prompt may be asked for, by its
  /// own rules (lib/services/review_prompt.dart). Never for one that failed
  /// or never connected.
  void _maybeAskForRating(String sessionId, SessionState? ended) {
    final session = ended?.session;
    if (ended?.status != SessionStatus.connected || session == null) return;
    // A server reached, not this device's own shell or the demo.
    if (session.shell is LocalShellService || session.shell is DemoShellService) return;
    final othersOpen = state.entries.any((e) =>
        e.key != sessionId && (e.value.status == SessionStatus.connected || e.value.status == SessionStatus.connecting));
    try {
      unawaited(_ref.read(reviewPromptProvider).sessionEnded(
            lasted: DateTime.now().difference(session.startedAt),
            byThePerson: true,
            othersOpen: othersOpen,
          ));
    } catch (e) {
      // (No settings store here: a test's scope. Nothing to ask then.)
      AppLogger.info('Rating prompt not considered: $e');
    }
  }

  /// Saves the recording of [sessionId] as its session ends, to the
  /// transcripts folder (as stopping a recording on a phone does), stops it,
  /// and says where it went, or that it could not be saved and why.
  Future<void> _saveRecordingAsItEnds(String sessionId, String? label) async {
    final path = await SessionTranscriptService.saveToFile(sessionId);
    final why = SessionTranscriptService.lastSaveError;
    SessionTranscriptService.stopRecording(sessionId);
    if (!mounted) return;
    final t = gl10n;
    final host = Redactable.host(label ?? '').display;
    if (path != null) {
      _notify().success(t.transcriptSavedTitle,
          body: t.transcriptSessionEndedSaved(host, Redactable.freeText(path).display));
    } else {
      _notify().error(t.transcriptSessionEndedNotSaved(host), details: '${why ?? 'Not saved'}');
    }
  }

  /// Drop a session's SSH connection but KEEP its entry in the list.
  ///
  /// Unlike [endSession] - which tears the session down and removes it from
  /// state after a short delay - this leaves the session in the
  /// `disconnected` state so it stays visible and can be manually
  /// reconnected later. Used by the mobile bulk "Disconnect" action, which
  /// is distinct from bulk "Close" (that ends + removes).
  Future<void> disconnectSession(String sessionId) async {
    final current = state[sessionId];
    if (current == null) return;
    // Already disconnected - nothing to drop.
    if (current.status == SessionStatus.disconnected) return;

    // Mark as intentional so the connection-lost notification and the
    // auto-reconnect loop are suppressed - this is a user-requested drop.
    _intentionalDisconnects.add(sessionId);
    _connectTries.remove(sessionId);

    // Cancel any active auto-reconnect.
    _reconnectTimers[sessionId]?.cancel();
    _reconnectTimers.remove(sessionId);
    _reconnectCancelled.add(sessionId);

    // Cancel stream subscriptions, timers, and the port-forward service so
    // bound local sockets are released - same cleanup as [endSession], just
    // without removing the session entry afterwards.
    _stdoutSubscriptions.remove(sessionId)?.cancel();
    _disposeCaptureState(sessionId);
    _connectionStateSubscriptions.remove(sessionId)?.cancel();
    _outputBatches.remove(sessionId)?.close();
    _typedLines.remove(sessionId);
    // (Connected again, it is another shell: nothing was typed into that one.)
    _lastInputAt.remove(sessionId);
    _broadcastConfirmPending.remove(sessionId);
    _portForwardServices.remove(sessionId)?.dispose();
    refreshForwardStatus();
    _evictionTimers.remove(sessionId)?.cancel();

    final connId = current.connectionId;
    if (current.session != null) {
      await current.session!.shell.disconnect();
    }

    // Keep the entry - just flip it to disconnected, with when it started.
    state = {
      ...state,
      sessionId: SessionState.disconnected(
        connectionId: connId,
        connectionLabel: current.connectionLabel,
        host: current.host,
        port: current.port,
      ).copyWith(lastStartedAt: current.startedAt),
    };

    // Update foreground service (may stop if no sessions left connected).
    _syncForegroundService();

    // Clear the intentional-disconnect / reconnect-cancelled markers after a
    // short delay so a later genuine reconnect of this id isn't suppressed.
    Future.delayed(const Duration(seconds: 2), () {
      _intentionalDisconnects.remove(sessionId);
      _reconnectCancelled.remove(sessionId);
    });
  }

  /// End all active sessions.
  Future<void> endAllSessions() async {
    final sessionIds = state.keys.toList();
    for (final sessionId in sessionIds) {
      await endSession(sessionId, byThePerson: false);
    }
  }

  /// Reorder sessions by moving the entry at [oldIndex] to [newIndex].
  ///
  /// Only affects the visible order (Dart Maps preserve insertion order).
  /// [filteredKeys] should be the list of session keys in their current
  /// display order (e.g. excluding detached sessions).
  void reorderSessions(List<String> filteredKeys, int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= filteredKeys.length ||
        newIndex < 0 ||
        newIndex >= filteredKeys.length) {
      return;
    }

    final reordered = List<String>.from(filteredKeys);
    final key = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, key);

    // Rebuild the map preserving entries not in filteredKeys at their
    // original position, but reordering the filtered keys.
    final newMap = <String, SessionState>{};
    final reorderedSet = reordered.toSet();

    // First, insert reordered keys
    for (final k in reordered) {
      final v = state[k];
      if (v != null) newMap[k] = v;
    }
    // Then, append any keys that weren't in the filtered list (detached, etc.)
    for (final entry in state.entries) {
      if (!reorderedSet.contains(entry.key)) {
        newMap[entry.key] = entry.value;
      }
    }
    state = newMap;
  }

  /// Hide a session - removes it from pane tabs but keeps it alive.
  void hideSession(String sessionId) {
    final current = state[sessionId];
    if (current == null) return;
    state = {...state, sessionId: current.copyWith(isHidden: true)};
  }

  /// Unhide a session - makes it visible in pane tabs again.
  void unhideSession(String sessionId) {
    final current = state[sessionId];
    if (current == null) return;
    state = {...state, sessionId: current.copyWith(isHidden: false)};
  }

  /// Get count of active (connected or connecting) sessions.
  int get activeSessionCount {
    return state.values
        .where((s) =>
            s.status == SessionStatus.connected ||
            s.status == SessionStatus.connecting)
        .length;
  }

  /// Sessions genuinely holding a concurrency slot, which is what the free
  /// tier limit is checked against (NOT [activeSessionCount], which the UI
  /// uses to show how many sessions are live).
  ///
  /// A session the user has already started closing is in
  /// [_intentionalDisconnects] the instant its teardown begins (endSession /
  /// disconnectSession add it BEFORE the async `shell.disconnect()`), so its
  /// status can still read `connected` for the moment the disconnect takes.
  /// Excluding those here means closing a session frees its slot immediately:
  /// a user at the cap can close one and open another without waiting out the
  /// close delay, and the new session and the closing one settle in parallel.
  /// Only ACTUALLY live sessions (connected/connecting and not on their way
  /// out) are counted, so this never displaces a session that is staying open.
  int get occupiedSessionSlots {
    return state.entries
        .where((e) =>
            (e.value.status == SessionStatus.connected ||
                e.value.status == SessionStatus.connecting) &&
            !_intentionalDisconnects.contains(e.key))
        .length;
  }

  /// Count only fully connected sessions (not connecting/disconnected).
  int get _connectedSessionCount {
    return state.values
        .where((s) => s.status == SessionStatus.connected)
        .length;
  }

  /// Sync the Android foreground service with the current connected count.
  ///
  /// Starts the service when the first session connects, updates the
  /// notification text as sessions come and go, and stops the service
  /// when the last session disconnects.
  void _syncForegroundService() {
    final count = _connectedSessionCount;
    if (count > 0) {
      ForegroundService.start(
        connectionCount: count,
        sessionNames: notificationSessionLines(
            state.values.where((s) => s.status == SessionStatus.connected).map((s) => s.connectionLabel)),
      );
    } else {
      ForegroundService.stop();
    }
  }

  /// A test's own shell for a connection (one that drops without a word, for
  /// instance); null, as always in the app, for the real one.
  @visibleForTesting
  ShellService? Function(Connection connection)? debugShellFor;

  /// Create the appropriate [ShellService] for the connection's protocol.
  /// [filesOnly]: a session with no terminal (an SFTP-only host, or an SSH
  /// host's files opened once), always on an SSH connection of this isolate,
  /// which its SFTP is opened on. [ended]: whether this try of connecting is over
  /// ([_connectTries]), which a question of its sign-in asks when it is answered
  /// ([_askedFor]).
  Future<ShellService> _createShell(
    Connection connection, {
    ConnectionLogCallback? onLog,
    String? usernameOverride,
    bool accountChosen = false,
    bool unattended = false,
    bool filesOnly = false,
    bool Function()? ended,
    XProgramTarget? xProgram,
    ProxmoxGuest? console,
  }) async {
    // A host saved in a Crate that its own offline limit has closed on this
    // device does not connect, whatever it speaks (3.0,
    // rules/crate_offline.dart). Its key is asked about where keys are read.
    await requireCratesOpenIn(_readDb(connection.id), hostId: connection.id);
    // A team's host never opens a shell on this computer, however its record
    // came here (one saved before the record was refused, an older device's). A
    // terminal of this device is opened in the person's own space
    // (openLocalTerminal), never in a team's.
    if (teamMayNotOpenWith(connection.protocol)) {
      final db = _sessionDb(connection.id);
      if (db == null || db.isOrchard) {
        throw OrchardAccessRefused(ErrorCodes.withCode(gl10n.teamHostLocalShellRefused, ErrorCodes.teamHostLocalShell));
      }
    }
    final debugShell = debugShellFor?.call(connection);
    if (debugShell != null) return debugShell;
    final protocol = connection.protocol;

    // An X program (4.0): a screen of this SSH host itself.
    if (xProgram != null) {
      return _createXProgramShell(connection, xProgram, onLog: onLog, unattended: unattended, ended: ended);
    }
    // A Proxmox guest's console (4.0): through the host's Proxmox
    // account, not the host itself.
    if (console != null) return _createConsoleShell(connection, console, onLog: onLog);

    // A remote screen (4.0, VNC or RDP): through its carrier SSH host, signed
    // in with no terminal, or directly (VNC over VeNCrypt TLS only; RDP always
    // inside TLS). Which engine it is for is the host's protocol, told to the
    // shell below, so an RDP host is never spoken VNC to.
    if (ConnectionProtocol.storedIsScreen(protocol)) {
      return _createScreenShell(connection, onLog: onLog, unattended: unattended, ended: ended);
    }

    // FTPS (3.4): files only, over FTP with TLS, never SSH. The user name and
    // the password of the host's key (asked where none is saved); the
    // certificate checked as a host key is.
    if (ConnectionProtocol.storedIsFtps(protocol)) {
      final creds = await _resolveIdentity(
        connection,
        onLog: onLog,
        usernameOverride: usernameOverride,
        unattended: unattended,
        ended: ended,
      );
      var password = creds.password ?? await creds.passwordAfterKey?.call();
      if (password == null) {
        if (unattended) throw UnattendedSignInStopped(gl10n.unattendedNobodyToAsk);
        final asked = await _promptForPassword(connection.host, creds.username,
            offerSave: false, ended: _askedFor(connection.id, ended));
        if (asked == null) throw ConnectionCancelledException();
        password = asked.password;
      }
      final known = _spaces.knownHosts(connection.id);
      if (known == null) throw ConnectionCancelledException();
      return FtpsShellService(
        options: FtpsConnectOptions(
          host: connection.host,
          port: connection.port,
          username: creds.username,
          password: password,
          implicitTls: connection.protocol == ConnectionProtocol.ftpsImplicit.name,
          timeout: _connectTimeout,
        ),
        trust: KnownHostsFtpsTrust(
          known,
          _askAboutCertificate(connection.id, ended),
          // A certificate another device kept, confirmed here for the first
          // time: told once with that device and day, as a synced host key is.
          onAdopted: (host, port, from) => _ref.read(hostKeyProvenanceProvider.notifier).state =
              HostKeyProvenanceEvent(
                  host: host, port: port, device: from.device, recordedAt: from.recordedAt, certificate: true),
          // A team's host (3.4): its Crate's pinned certificate, as an SSH
          // host's pinned key.
          team: switch (_spaces.database(connection.id)) {
            final db? when db.isOrchard => FtpsTeamPins(TeamHostKeys(db), hostId: connection.id),
            _ => null,
          },
        ),
        onLog: onLog,
      );
    }

    // Files only: SSH's sign-in, as for any SSH host (its network, its jump
    // hosts, its key and Compatibility mode), on a connection of this
    // isolate, which is what its SFTP needs (a worker's makes a terminal).
    if (filesOnly) {
      onLog?.call('sftp: Opening files only (SFTP): no terminal');
      return _createSshShell(connection,
          ended: ended,
          onLog: onLog,
          usernameOverride: usernameOverride,
          accountChosen: accountChosen,
          forCommands: true,
          unattended: unattended);
    }

    if (protocol == 'demo') {
      onLog?.call('demo: Opening demo terminal');
      return DemoShellService();
    }

    if (protocol == 'localShell') {
      onLog?.call('shell: Opening local shell process');
      if (!LocalShellService.isAvailable) {
        throw UnsupportedError(
          'Local shell is not available on this platform (iOS sandbox).',
        );
      }
      return LocalShellService();
    }

    if (protocol == 'mosh') {
      // The app's own Mosh client (4.0): on a phone, a tablet and Windows
      // always, on a Mac and Linux unless Settings says to use the mosh
      // program installed there. mosh-server is started over this host's SSH
      // sign-in (its key, network, jump hosts and Compatibility mode), then
      // the session is UDP to it.
      if (moshUsesBuiltIn(preferSystem: _ref.read(moshSystemClientProvider))) {
        onLog?.call('mosh: Opening with the built-in Mosh client');
        return BuiltinMoshService(
          onLog: onLog,
          bootstrap: () => _startMoshServer(connection,
              onLog: onLog,
              usernameOverride: usernameOverride,
              accountChosen: accountChosen,
              unattended: unattended,
              ended: ended),
        );
      }
      onLog?.call('mosh: Checking if mosh is installed...');
      final moshAvailable = await MoshService.isAvailable();
      if (!moshAvailable) {
        // What is missing and how to install it ([shellClientMissingText]).
        throw ShellClientMissing(ShellClient.mosh, onPhone: Platform.isAndroid || Platform.isIOS);
      }
      final creds = await _resolveIdentity(
        connection,
        onLog: onLog,
        usernameOverride: usernameOverride,
        unattended: unattended,
        ended: ended,
      );
      onLog?.call('mosh: Launching mosh session to ${connection.host}');
      return MoshService(
        host: connection.host,
        port: connection.port,
        username: creds.username,
        sshIdentityPath: await _resolveIdentityKeyPath(connection),
      );
    }

    if (protocol == 'et') {
      onLog?.call('et: Checking if the Eternal Terminal client is installed...');
      if (!await EternalTerminalService.isAvailable()) {
        throw ShellClientMissing(ShellClient.eternalTerminal, onPhone: Platform.isAndroid || Platform.isIOS);
      }
      final creds = await _resolveIdentity(
        connection,
        onLog: onLog,
        usernameOverride: usernameOverride,
        unattended: unattended,
        ended: ended,
      );
      onLog?.call('et: Launching Eternal Terminal session to ${connection.host}');
      return EternalTerminalService(
        host: connection.host,
        port: connection.port,
        username: creds.username,
        sshIdentityPath: await _resolveIdentityKeyPath(connection),
      );
    }

    if (protocol == 'telnet') {
      onLog?.call('⚠️  WARNING: Telnet transmits ALL data (including passwords) in PLAINTEXT.');
      onLog?.call('⚠️  Anyone on the network can intercept your session. Use SSH instead.');
      onLog?.call('telnet: Connecting to ${connection.host}:${connection.port}');
      return TelnetService(
        host: connection.host,
        port: connection.port,
        connectTimeout: _connectTimeout,
      );
    }

    if (protocol == 'serial') {
      onLog?.call('serial: Connecting to console server ${connection.host}:${connection.port}');
      onLog?.call('serial: Serial-over-SSH - traffic is encrypted');
      final credentials = await _resolveIdentity(
        connection,
        onLog: onLog,
        usernameOverride: usernameOverride,
        unattended: unattended,
        ended: ended,
      );
      return SerialOverSshService(
        host: connection.host,
        port: connection.port,
        username: credentials.username,
        password: credentials.password,
        passwordAfterKey: credentials.passwordAfterKey,
        keyPairs: credentials.keyPairs,
        serialConfig: SerialConfig.cisco(), // Default; UI can customize later
        compatibilityMode: connection.compatibilityMode,
        connectTimeout: _connectTimeout,
        onHostKeyVerify: _buildHostKeyVerifier(connectionId: connection.id, unattended: unattended, ended: ended),
        onLog: onLog,
        onServerQuestion: _serverQuestions(
          unattended: unattended,
          host: connection.host,
          port: connection.port,
          username: credentials.username,
          ended: _askedFor(connection.id, ended),
        ),
        // A console server's login banner with a link its sign-in waits on
        // goes to the person, as a host's does.
        onSignInNotice: unattended
            ? null
            : signInNoticeShower(_ref, host: connection.host, port: connection.port, username: credentials.username),
      );
    }

    // SSH (default)
    return _createSshShell(connection,
        onLog: onLog,
        usernameOverride: usernameOverride,
        accountChosen: accountChosen,
        unattended: unattended,
        ended: ended);
  }

  /// Starts mosh-server on [connection]'s host for the built-in Mosh client
  /// (4.0): signed in as an SSH session to it would be (with no terminal),
  /// mosh-server run once by name or where package managers put it, and the
  /// SSH connection closed again: the Mosh session is UDP from here on, to
  /// the address the SSH connection reached ([moshUdpAddresses]). Through a
  /// jump host mosh-server is not bound to the address SSH came in on, which
  /// is the jump host's way in, and the host's name is resolved here.
  Future<MoshServerReady> _startMoshServer(
    Connection connection, {
    ConnectionLogCallback? onLog,
    String? usernameOverride,
    bool accountChosen = false,
    bool unattended = false,
    bool Function()? ended,
  }) async {
    final shell = await _createSshShell(connection,
        onLog: onLog,
        usernameOverride: usernameOverride,
        accountChosen: accountChosen,
        forCommands: true,
        unattended: unattended,
        ended: ended);
    final ssh = shell as SshService;
    try {
      await ssh.connectExec();
      final start = await startMoshServer(
        (command) async {
          final session = await ssh.client.execute(command);
          return collectMoshCommand(
            stdout: session.stdout,
            stderr: session.stderr,
            done: session.done,
            exitCode: () => session.exitCode,
          );
        },
        bindToSsh: ssh.jumpClients.isEmpty,
        onLog: onLog,
      );
      // The address SSH reached (direct), or the name resolved here (through a jump host).
      final addresses = await moshUdpAddresses(sshPeer: ssh.peerAddress, host: ssh.host, onLog: onLog);
      return (start: start, addresses: addresses);
    } finally {
      await ssh.disconnect();
    }
  }

  /// The SSH hosts a remote screen can be reached through (its carrier).
  static final _carrierProtocols = {
    ConnectionProtocol.ssh.name,
    ConnectionProtocol.mosh.name,
    ConnectionProtocol.et.name,
  };

  /// The host editor's Test of a remote screen reached through [carrier]
  /// (4.0): the carrier signed in as a screen's is (its key, its network and
  /// jump hosts, its questions; no terminal or shell), and a route that opens
  /// the channel to [target] on it. Its caller closes it.
  Future<ScreenProbeRoute> openScreenProbe(Connection carrier, ScreenTarget target,
      {ConnectionLogCallback? onLog}) async {
    if (!_carrierProtocols.contains(carrier.protocol)) {
      throw ScreenFailure(ScreenFailureKind.carrierGone, 'its SSH host (${carrier.id}) is no SSH host');
    }
    final shell = await _createSshShell(carrier, onLog: onLog, forCommands: true);
    final ssh = shell as SshService;
    try {
      await ssh.connectForScreen();
    } catch (_) {
      await ssh.disconnect();
      rethrow;
    }
    return SshScreenProbeRoute(ssh, target,
        carrierLabel: carrier.label.isNotEmpty ? carrier.label : hostWithPort(carrier.host, carrier.port));
  }

  /// A remote screen's session (4.0). The carrier, the SSH host it is
  /// reached through ([Connection.connectViaId]), is signed in to as a
  /// session to it would be, with its own network, host key, Compatibility
  /// mode and jump hosts (those gated as always), but with no terminal, and
  /// it is no jump host of the screen's: remote screens are free, and so is
  /// the hop to them. The carrier is in the screen's own space, and its
  /// Crate's offline limit and keys go as a hop's do. The VNC password comes
  /// from the screen's key; with none, it is asked for once the server wants
  /// one, and may be saved with the host once the server took it. The
  /// certificate of a screen with VeNCrypt is trusted on first use, kept for
  /// the carrier's route ([screenViaScope]).
  Future<ShellService> _createScreenShell(
    Connection connection, {
    ConnectionLogCallback? onLog,
    bool unattended = false,
    bool Function()? ended,
  }) async {
    final db = _readDb(connection.id);
    // The team's two rules about remote screens (screen_team_rules.dart), as
    // this device holds itself to them. Nothing shared with its screens: the
    // clipboard is locked off for this session whatever the host says, so no
    // view offers it and an RDP session is given no clipboard channel at all.
    final teamRules = await screenTeamRulesIn(db);
    final saved = ScreenOptions.decode(connection.screenOptions);
    final options = teamRules.lockRedirections ? saved.copyWith(clipboardLocked: true) : saved;
    String nameOf(Connection c) => c.label.isNotEmpty ? c.label : hostWithPort(c.host, c.port);
    Connection? carrier;
    final carrierId = connection.connectViaId;
    // Through an SSH host only: one that connects directly is refused before
    // its key is read or anything is dialled.
    if (carrierId == null && teamRules.sshOnly) {
      throw const ScreenFailure(
          ScreenFailureKind.teamSshOnly, 'the team opens remote screens through an SSH host only (screens_ssh_only)');
    }
    if (carrierId != null) {
      carrier = await db.connectionsDao.getById(carrierId);
      if (carrier == null || !_carrierProtocols.contains(carrier.protocol)) {
        throw ScreenFailure(ScreenFailureKind.carrierGone, 'its SSH host ($carrierId) is not in its space, or no SSH host');
      }
      _spaces.opened(carrier.id, space: _spaces.spaceOf(connection.id));
      await requireCratesOpenIn(db, hostId: carrier.id, keyId: carrier.identityId);
    }
    final target = ScreenTarget.of(connection, options);

    // The VNC password (and a user name, for Apple's sign-in and VeNCrypt's
    // X509Plain) from the screen's key; for RDP, the account's name and
    // password, the name written with its domain where it has one.
    final rdp = connection.protocol == ConnectionProtocol.rdp.name;
    // Through an RD Gateway (4.0). A host whose settings name one is
    // never opened without it: where this build offers none, the gateway
    // cannot be read, or an SSH host is chosen too, it is refused before its
    // key is read or anything is dialled.
    final gateway = rdp ? options.gateway : null;
    if (gateway != null) {
      final why = !_ref.read(rdpGatewayOfferedProvider)
          ? 'this build opens no RD Gateway'
          : !gateway.readable
              ? 'its RD Gateway is in a form this version cannot read'
              : carrierId != null
                  ? 'it names both an RD Gateway and an SSH host to reach it through'
                  : null;
      if (why != null) {
        throw ScreenFailure(ScreenFailureKind.rdpGateway, why, hint: 'gateway_unavailable', rdp: true);
      }
    }
    final gatewaySignsInAsPc = gateway != null && gateway.keyId == null;
    String? username;
    String? domain;
    String? password;
    if (connection.identityId != null) {
      final creds = await _resolveIdentity(connection, onLog: onLog, unattended: unattended, ended: ended);
      username = creds.username.isEmpty ? null : creds.username;
      // Without NLA no password is the app's to send: none is fetched (unless
      // an RD Gateway signs in with it).
      if (!rdp || options.nla || gatewaySignsInAsPc) password = creds.password ?? await creds.passwordAfterKey?.call();
    }
    if (rdp && username != null) {
      final account = rdpAccount(username);
      username = account.username.isEmpty ? null : account.username;
      domain = account.domain;
    }
    // Network Level Authentication signs in as someone. A host with no key to
    // say who (or a key with no user name) asks its person for the account,
    // name and password together; with nobody there, there is nobody to sign
    // in as, and the server would be asked with an empty name.
    final noAccount = rdp && (options.nla || gatewaySignsInAsPc) && username == null;
    if (noAccount && unattended) {
      throw const ScreenFailure(ScreenFailureKind.stopped, 'the host has no key with a user name to sign in as');
    }
    PasswordPromptResult? asked;
    ScreenPasswordAsker? askPassword;
    ScreenAccountAsker? askAccount;
    if (noAccount) {
      askAccount = ({required bool again}) async {
        final answer = await _promptForPassword(nameOf(connection), '',
            why: again ? gl10n.screenRdpAccountAgain : gl10n.screenRdpAccountWhy,
            // No key to keep it with: the host's editor is where a key is given.
            offerSave: false,
            askUsername: true,
            ended: _askedFor(connection.id, ended));
        final name = answer?.username?.trim() ?? '';
        if (answer == null || name.isEmpty) throw ConnectionCancelledException();
        return (username: name, password: answer.password);
      };
    } else if (password == null && !unattended && (!rdp || options.nla || gatewaySignsInAsPc)) {
      askPassword = ({required bool again}) async {
        final answer = await _promptForPassword(nameOf(connection), username ?? '',
            // An RDP account's password is not a VNC password of 8 characters.
            why: rdp
                ? (again ? gl10n.screenRdpPasswordAgain : gl10n.screenRdpPasswordWhy)
                : (again ? gl10n.screenPasswordAgain : gl10n.screenPasswordWhy),
            offerSave: !connection.id.startsWith('quick_'),
            ended: _askedFor(connection.id, ended));
        if (answer == null) throw ConnectionCancelledException();
        asked = answer;
        return answer.password;
      };
    }

    final known = _spaces.knownHosts(connection.id);
    if (known == null) throw ConnectionCancelledException();
    // The PC's certificate is kept for its route: through its SSH host, or through its RD Gateway
    // (the same name behind two gateways, or reached directly too, is two PCs).
    final via = carrier != null
        ? screenViaScope(carrierHost: carrier.host, carrierPort: carrier.port)
        : gateway != null
            ? screenViaScope(carrierHost: gateway.host, carrierPort: gateway.port)
            : null;
    final routeTrust = ScreenRouteTrust(
      KnownHostsScreenTrust(
        known,
        _askAboutScreenCertificate(connection.id, ended,
            via: carrier != null ? nameOf(carrier) : gateway?.host,
            // (A screen opened from a typed address has no name of its own.)
            name: connection.label.isNotEmpty && connection.label != connection.host ? connection.label : null),
        viaScope: via,
        team: db.isOrchard ? ScreenTeamPins(TeamHostKeys(db), hostId: connection.id) : null,
        onAdopted: (host, port, from) => _ref.read(hostKeyProvenanceProvider.notifier).state = HostKeyProvenanceEvent(
            host: host, port: port, device: from.device, recordedAt: from.recordedAt, certificate: true),
      ),
      host: connection.host,
      port: connection.port,
    );

    // The gateway's own sign-in, where it has a key of its own (its account
    // here, by the vault's rules as the host's key), and its certificate,
    // asked about and kept under the gateway's address, apart from the PC's.
    ScreenGatewayRoute? gatewayRoute;
    ScreenRouteTrust? gatewayTrust;
    if (gateway != null) {
      String? gwUser;
      String? gwPassword;
      String? gwDomain;
      final keyId = gateway.keyId;
      if (keyId != null) {
        final creds = await _resolveIdentity(connection.copyWith(identityId: Value(keyId)),
            onLog: onLog, unattended: unattended, ended: ended);
        final account = rdpAccount(creds.username);
        gwUser = account.username.isEmpty ? null : account.username;
        gwDomain = account.domain;
        gwPassword = creds.password ?? await creds.passwordAfterKey?.call();
        if (gwUser == null || gwPassword == null) {
          throw const ScreenFailure(ScreenFailureKind.rdpGateway, "the gateway's key has no user name or no password",
              hint: 'gateway_sign_in', rdp: true);
        }
      }
      gatewayRoute = ScreenGatewayRoute(
          host: gateway.host,
          port: gateway.port,
          sameSignIn: keyId == null,
          username: gwUser,
          password: gwPassword,
          domain: gwDomain);
      gatewayTrust = ScreenRouteTrust(
        KnownHostsScreenTrust(
            known, _askAboutScreenCertificate(connection.id, ended, name: gl10n.screenGatewayCertificateName(nameOf(connection)))),
        host: gateway.host,
        port: gateway.port,
      );
    }

    SshService? carrierSsh;
    if (carrier != null) {
      onLog?.call('screen: Reaching the screen through ${nameOf(carrier)} (SSH, no terminal)');
      final shell = await _createSshShell(carrier, onLog: onLog, forCommands: true, unattended: unattended, ended: ended);
      // (With no terminal, a connection is always made in this isolate.)
      carrierSsh = shell as SshService;
    }
    return ScreenShellService(
      target: target,
      protocol: rdp ? ScreenProtocol.rdp : ScreenProtocol.vnc,
      trust: routeTrust,
      carrier: carrierSsh,
      carrierLabel: carrier == null ? null : nameOf(carrier),
      username: username,
      domain: domain,
      password: password,
      askPassword: askPassword,
      askAccount: askAccount,
      onPasswordAccepted: () => _saveScreenPassword(connection, asked, onLog),
      onTlsConnected: (sha) => unawaited(routeTrust.connected(sha)),
      shared: options.shared,
      options: options,
      inTeam: db.isOrchard,
      connectionId: connection.id,
      native: debugScreenNative,
      onLog: onLog,
      gateway: gatewayRoute,
      gatewayTrust: gatewayTrust,
      openDirect: debugOpenScreenSocket,
      connectTimeout: _connectTimeout,
    );
  }

  /// The options of a screen that keeps none of its own (an X program's, a
  /// Proxmox guest's console): a new host's ([ScreenOptions.forNewHost]),
  /// so on a computer this device's clipboard goes to the remote only when
  /// its person pastes into the picture, as for a host made now; locked off
  /// under the team's rule that shares nothing, as any screen's.
  static ScreenOptions _sessionScreenOptions(ScreenTeamRules rules) =>
      rules.lockRedirections ? ScreenOptions.forNewHost.copyWith(clipboardLocked: true) : ScreenOptions.forNewHost;

  /// An X program's screen (4.0): [connection], an SSH host, signed in
  /// to as a remote screen's carrier is (its network, host key, Compatibility
  /// mode, jump hosts gated as always, its Crate's offline limit and keys; no
  /// terminal, no shell), then the host script run on it ([XProgramRun]) and
  /// the private Xvnc's socket opened through the same connection, with VNC
  /// security None and no certificate ([XProgramScreenTrust]).
  Future<ShellService> _createXProgramShell(
    Connection connection,
    XProgramTarget xProgram, {
    ConnectionLogCallback? onLog,
    bool unattended = false,
    bool Function()? ended,
  }) async {
    if (!_carrierProtocols.contains(connection.protocol)) {
      throw const ScreenFailure(ScreenFailureKind.xProgramFailed, 'an X program runs on an SSH host only');
    }
    final db = _readDb(connection.id);
    final name = connection.label.isNotEmpty ? connection.label : hostWithPort(connection.host, connection.port);
    // An X program's screen is a remote screen of the team's SSH host: the
    // team's rule that shares nothing with them locks its clipboard too.
    // Read before the host is signed in to, so nothing is left connected
    // where the team's database cannot be read.
    final teamRules = await screenTeamRulesIn(db);
    final shell = await _createSshShell(connection, onLog: onLog, forCommands: true, unattended: unattended, ended: ended);
    return ScreenShellService(
      target: xProgram,
      trust: const XProgramScreenTrust(),
      carrier: shell as SshService,
      carrierLabel: name,
      options: _sessionScreenOptions(teamRules),
      inTeam: db.isOrchard,
      connectionId: connection.id,
      native: debugScreenNative,
      onLog: onLog,
      connectTimeout: _connectTimeout,
    );
  }

  /// A Proxmox guest's console (4.0): the account this
  /// device keeps for the host's Proxmox cluster (its token and its
  /// confirmed certificate, in secure storage), the console asked of the API
  /// as the session opens. No VNC certificate question: the VNC is inside
  /// the API's TLS. Refused under the team rule that opens remote screens
  /// through an SSH host only. Its clipboard follows the team's rules as
  /// any screen's.
  Future<ShellService> _createConsoleShell(Connection connection, ProxmoxGuest guest, {ConnectionLogCallback? onLog}) async {
    final db = _readDb(connection.id);
    final teamRules = await screenTeamRulesIn(db);
    if (teamRules.sshOnly) {
      throw const ScreenFailure(
          ScreenFailureKind.teamSshOnly, 'the team opens remote screens through an SSH host only (screens_ssh_only)');
    }
    final accounts = await _ref.read(cloudAccountStoreProvider).load();
    final account = accounts
        .where((a) => a.provider == CloudProvider.proxmox)
        .where((a) => switch (proxmoxBase(a.fields[CloudField.url] ?? '')) { final base? => guest.isOn(base), null => false })
        .firstOrNull;
    final base = account == null ? null : proxmoxBase(account.fields[CloudField.url] ?? '');
    if (account == null || base == null) {
      throw ScreenFailure(ScreenFailureKind.proxmoxConsole, 'no Proxmox account for ${guest.host}:${guest.port} on this device',
          hint: 'noAccount');
    }
    final token = proxmoxTokenValue(account.fields[CloudField.token] ?? '');
    if (token == null) {
      throw const ScreenFailure(ScreenFailureKind.proxmoxConsole, 'the account keeps no API token', hint: 'signIn');
    }
    final pin = account.fields[CloudField.pin];
    onLog?.call('screen: Through the Proxmox account kept on this device for ${guest.host}:${guest.port}');
    final open = debugOpenConsole;
    return ScreenShellService(
      target: ProxmoxConsoleTarget(guest),
      trust: const XProgramScreenTrust(),
      openConsole: open != null
          ? () => open(base: base, token: token, guest: guest, pin: pin)
          : () => openProxmoxConsole(base: base, token: token, guest: guest, client: proxmoxClient(base, pinned: pin)),
      options: _sessionScreenOptions(teamRules),
      inTeam: db.isOrchard,
      connectionId: connection.id,
      native: debugScreenNative,
      onLog: onLog,
      connectTimeout: _connectTimeout,
    );
  }

  /// A password asked for a remote screen, that its server took: saved as a
  /// key of the screen's where its person ticked "Save" and may change the
  /// host (in a team's space, by its rules).
  Future<void> _saveScreenPassword(Connection connection, PasswordPromptResult? asked, ConnectionLogCallback? onLog) async {
    if (asked == null || !asked.saveToIdentity || connection.id.startsWith('quick_')) return;
    final db = _readDb(connection.id);
    if (!await mayEditIn(db, 'host', connection.id)) return;
    final label = connection.label.isNotEmpty ? connection.label : connection.host;
    final identityId = await _identityCrudFor(db).create(
      label: 'VNC $label',
      username: '',
      authMethod: 'password',
      password: asked.password,
    );
    await ConnectionCrudNotifier(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao)
        .update(id: connection.id, identityId: identityId);
    onLog?.call("identity: Saved the screen's password as a key");
  }

  /// How a remote screen's VeNCrypt certificate is asked about (4.0): as an
  /// FTPS server's is ([_askAboutCertificate]), in a screen's words, through
  /// which SSH host ([via]).
  ScreenCertificateQuestion _askAboutScreenCertificate(String connectionId, bool Function()? ended,
      {String? via, String? name}) {
    final gone = _askedFor(connectionId, ended);
    return ({required host, required port, required certificate, viaScope, previous, previousTrustedAt, teamPin}) async {
      final completer = Completer<bool>();
      if (previous != null) await _ref.read(changedHostKeysProvider.notifier).markChanged(host, port);
      _ref.read(hostKeyVerificationQueueProvider.notifier).enqueue(HostKeyVerification(
            certificate: true,
            screen: true,
            via: via,
            name: name,
            host: host,
            port: port,
            hostKey: SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: Uint8List.fromList(certificate.der)),
            fingerprint: certificate.fingerprint,
            isChanged: previous != null,
            expectedFingerprint: previous,
            expectedTrustedAt: previousTrustedAt,
            completer: completer,
            teamPin: teamPin,
          ));
      final yes = await completer.future;
      if (gone()) throw ConnectionCancelledException();
      if (yes && previous != null) await _ref.read(changedHostKeysProvider.notifier).resolve(host, port);
      return yes;
    };
  }

  /// Resolve identity credentials for a connection.
  ///
  /// [usernameOverride] is used when Quick Connect parses a username from
  /// `user@host` format. It takes priority over the default 'root' when
  /// no identity is attached, but an identity's username always wins.
  ///
  /// Throws [ConnectionCancelledException] if the user cancels the
  /// password prompt, which aborts the entire connection flow, and where a
  /// question is answered after [ended] says the try is over, or another
  /// account has come ([_askedFor]): nothing of that answer is saved or used.
  Future<
      ({
        String username,
        String? password,
        // The password saved with a key, fetched only once a server did not
        // take the key and asks for a password (3.0, accounts per host).
        Future<String?> Function()? passwordAfterKey,
        List<SSHKeyPair>? keyPairs,
        // Design B worker path: the raw private-key PEM(s) + the RESOLVED
        // passphrase, so a worker isolate can re-parse the key and sign there
        // (parsed SSHKeyPair objects cannot cross an isolate). Only populated
        // for plain 'publicKey' auth; empty for password / certificate /
        // hardwareToken (the latter two cannot be reconstructed from a PEM and
        // keep the worker path disqualified via [authMethod]).
        List<String> keyPems,
        String? keyPassphrase,
        String authMethod,
      })> _resolveIdentity(
    Connection connection, {
    ConnectionLogCallback? onLog,
    String? usernameOverride,
    bool unattended = false,
    bool Function()? ended,
  }) async {
    final gone = _askedFor(connection.id, ended);
    // A run with nobody there ([unattended]) asks nothing: what would be
    // asked stops the sign-in instead, and says so. An answer that comes once
    // the try is over ([gone]) stops it too: saved, it would go into the next
    // account, which syncs it, and the dial would go on against that account's
    // known hosts.
    Future<T> toPerson<T>(Future<T> Function() question) async {
      if (unattended) throw UnattendedSignInStopped(gl10n.unattendedNobodyToAsk);
      final answer = await question();
      if (gone()) {
        onLog?.call('identity: Ended while it asked, so nothing was saved');
        throw ConnectionCancelledException();
      }
      return answer;
    }

    // Use the override from Quick Connect parsing, or fall back to default
    String username = usernameOverride ?? _ref.read(defaultUsernameProvider);
    String? password;
    Future<String?> Function()? passwordAfterKey;
    List<SSHKeyPair>? keyPairs;
    // Worker-path raw credentials (see the return record doc above).
    List<String> workerKeyPems = const [];
    String? workerKeyPassphrase;
    String resolvedAuthMethod = 'none';

    // Nothing signs in to a host, or with a key, of a Crate that its own
    // offline limit has closed on this device: the host a session is for,
    // and every hop on the way to it, since each comes through here.
    await requireCratesOpenIn(_readDb(connection.id), hostId: connection.id, keyId: connection.identityId);

    if (connection.identityId != null) {
      onLog?.call('identity: Loading credentials...');
      final identityDb = _readDb(connection.id);
      final identityDao = identityDb.identitiesDao;
      final identity = await identityDao.getById(connection.identityId!);

      if (identity != null) {
        username = identity.username;
        final identityCrud = _identityCrudFor(identityDb);
        // A key in a watched Crate signs in only to that Crate's hosts,
        // whose sessions are the ones that are watched (3.0).
        await requireWatchedKeyHostIn(identityDb, identity.id, connection.id);
        // The key's name in what is said of it, masked while recording.
        final keyLabel = Redactable.keyName(identity.label).display;
        // A run with nobody there signs in only with a key allowed for
        // unattended runs (Keys: Allow unattended runs): not with the one
        // this host takes on this network, nor a jump host's, where they
        // are not. (Its host's own key alone was checked.)
        if (unattended && !identity.allowUnattended) {
          onLog?.call('identity: ERROR - $keyLabel is not allowed for unattended runs');
          throw UnattendedSignInStopped(gl10n.unattendedKeyNotAllowed(keyLabel));
        }

        try {
          if (identity.authMethod == 'password') {
            resolvedAuthMethod = 'password';
            // An Orchard password this account may not see goes only to a
            // host it cannot change (3.0).
            // A remote screen's carrier counts as the screen does (4.0).
            final carrier = await screenCarrierRouteIn(identityDb, connection);
            await requirePasswordHostIn(identityDb, identity.id, connection.id, carrierId: carrier?.id);
            // One from a Crate that asks again goes to a host it may change
            // only once the person confirms it is them, and is not read
            // before then: once for each address it goes to, on this
            // device. A host pointed somewhere new asks again, and so
            // does a screen reached through another carrier.
            if (await passwordAsksAgainIn(identityDb, identity.id, connection.id, carrierId: carrier?.id)) {
              onLog?.call("identity: The key's Crate asks again before its password goes to this address...");
              final confirmed = await confirmPasswordDestination(
                identityDb,
                identityId: identity.id,
                host: connection.host,
                port: connection.port,
                via: carrier?.via,
                ask: (destination) => toPerson(() => askConfirmItIsYou(_ref, destination: destination)),
              );
              if (!confirmed) {
                onLog?.call('identity: Not confirmed, so the password was not sent');
                throw OrchardAccessRefused(gl10n.orchardPasswordNotConfirmed);
              }
            }
            password = await identityCrud.getPassword(identity.id);
            if (password != null) {
              onLog?.call('identity: Password credentials loaded for $username');
            } else {
              // No saved password - prompt the user
              onLog?.call('identity: No saved password, prompting...');
              final result = await toPerson(() => _promptForPassword(
                    connection.host,
                    username,
                    ended: gone,
                  ));
              if (result == null) {
                onLog?.call('identity: User cancelled password prompt');
                throw ConnectionCancelledException();
              }
              password = result.password;
              // Saved back only where the key's Crate lets this account
              // change it (3.0).
              if (result.saveToIdentity && await mayEditIn(identityDb, 'key', identity.id)) {
                await identityCrud.setPassword(identity.id, result.password);
                onLog?.call('identity: Password saved to identity');
              }
            }
          } else if (identity.authMethod == 'publicKey' ||
              identity.authMethod == 'certificate') {
            resolvedAuthMethod = identity.authMethod;
            final pem = await identityCrud.getPrivateKey(identity.id);
            if (pem != null) {
              // Only plain public-key auth can cross to a worker as raw PEM;
              // a certificate also needs its cert blob, so it stays in-isolate.
              if (identity.authMethod == 'publicKey') {
                workerKeyPems = [pem];
              }
              final passphrase =
                  await identityCrud.getKeyPassphrase(identity.id);
              // The key file as keys. A file that is no key the app can
              // read (it is damaged, or of a kind the app does not know)
              // stops the sign-in and says so. What reading it failed with
              // is named by its kind and never printed: it can carry a
              // piece of the file. (It was printed into the connection's
              // log, and a password was asked for in the key's place.)
              // (A security key's key file among them signs through the
              // phone's own conversation with the key, or the system's agent
              // on a computer: fido_key_pair.dart.)
              final signInTo = connection.label.isNotEmpty ? connection.label : connection.host;
              List<SSHKeyPair> read(String? passphrase) {
                try {
                  return withSecurityKeySigners(SSHKeyPair.fromPem(pem, passphrase), label: signInTo);
                } on SSHKeyDecryptError {
                  rethrow;
                } catch (e) {
                  onLog?.call('identity: ERROR - the private key cannot be read (${errorKind(e)})');
                  AppLogger.warning('The private key of a sign-in could not be read: ${errorKind(e)}');
                  throw SSHAuthFailedException(gl10n.connKeyUnreadable(keyLabel));
                }
              }

              try {
                keyPairs = read(passphrase);
                workerKeyPassphrase = passphrase;
                onLog?.call('identity: Public key loaded for $username');
              } on SSHKeyDecryptError {
                // Key is encrypted but we don't have the passphrase (or it's wrong).
                // Prompt the user for the passphrase specifically.
                onLog?.call('identity: Key is encrypted, prompting for passphrase...');
                final result = await toPerson(() => _promptForPassphrase(
                      connection.host,
                      username,
                      ended: gone,
                    ));
                if (result == null) {
                  throw ConnectionCancelledException();
                }
                keyPairs = withSecurityKeySigners(SSHKeyPair.fromPem(pem, result.passphrase), label: signInTo);
                workerKeyPassphrase = result.passphrase;
                onLog?.call('identity: Public key decrypted for $username');
                // Save the passphrase if the user opted in, where the key's
                // Crate lets this account change it (3.0).
                if (result.savePassphrase && await mayEditIn(identityDb, 'key', identity.id)) {
                  try {
                    await identityCrud.setKeyPassphrase(
                        identity.id, result.passphrase);
                    onLog?.call('identity: Passphrase saved to identity');
                  } catch (_) {
                    onLog?.call(
                        'identity: WARNING - could not save passphrase');
                  }
                }
              }

              // If this identity has an attached SSH certificate, wrap
              // every loaded keypair so the cert is presented to the
              // server during userauth. The wrapper validates that the
              // cert matches the underlying private key, so a mismatched
              // cert raises a clear error here instead of failing
              // mid-handshake.
              if (identity.authMethod == 'certificate') {
                // A certificate that cannot be read, or that was made for
                // another key, stops the sign-in and says so: the key is
                // not offered without it, and no password is asked for in
                // its place. (A password was, and one typed there signed in
                // without the certificate.) Where the device's secure
                // storage did not hand it over, that is said as that below.
                Never unusable(Object e) {
                  onLog?.call('identity: ERROR - the certificate cannot be used with this key (${errorKind(e)})');
                  throw SSHAuthFailedException(gl10n.connCertUnusable(keyLabel));
                }

                final SshCertificate? cert;
                try {
                  cert = await _ref.read(sshCertServiceProvider).loadCertForIdentity(identity.id);
                } on PlatformException {
                  rethrow;
                } catch (e) {
                  unusable(e);
                }
                if (cert != null && keyPairs.isNotEmpty) {
                  // Validate expiry up front - failing fast saves a
                  // round-trip and gives the user a precise error.
                  //
                  // SECURITY NOTE: this check uses the local system
                  // clock. If the local clock is wrong (NTP spoofing
                  // on a hostile network, manual tampering), an
                  // expired cert may slip through here. The SSH
                  // server performs its own validity check using its
                  // own clock - the server's decision is the
                  // authoritative one. Recommend that admins issue
                  // short-lived certs (hours / days, not months) so
                  // a clock-skew window is too small to exploit.
                  final exp = cert.validBeforeOrNull;
                  if (exp != null && DateTime.now().toUtc().isAfter(exp)) {
                    throw SSHAuthFailedException(gl10n.connCertRanOut(
                      keyLabel,
                      DateFormat.yMMMd(gl10n.localeName).add_jm().formatPlain(exp.toLocal()),
                    ));
                  }
                  try {
                    keyPairs = [
                      for (final inner in keyPairs) SshCertificateKeyPair(innerKey: inner, certificate: cert),
                    ];
                  } catch (e) {
                    unusable(e);
                  }
                  onLog?.call(
                      'identity: Certificate attached (cert key id "${cert.keyId}", '
                      'principals: ${cert.principalsLabel})');
                } else if (cert == null) {
                  // SECURITY: fail closed. The user explicitly asked
                  // for certificate auth - silently downgrading to
                  // bare-key auth would let an attacker who deletes
                  // the cert blob bypass the cert requirement.
                  onLog?.call(
                      'identity: ERROR - authMethod is "certificate" '
                      'but no cert blob found in secure storage. '
                      'Refusing to silently downgrade.');
                  throw SSHAuthFailedException(gl10n.connCertNotOnDevice(keyLabel));
                }
              }
            } else {
              // Key not found - tell the user clearly instead of silently
              // falling back to password (which may not work).
              onLog?.call('identity: ERROR - private key not found in storage');
              throw SSHAuthFailedException(gl10n.connKeyNotOnDevice(keyLabel));
            }
          } else if (identity.authMethod == kTeamCertificateAuth) {
            // A team certificate (3.0): this device's own key with
            // a certificate the key's Crate's authority signed for it, asked
            // for and waited on when there is none. Never a password prompt
            // instead: every failure here says why and stops.
            resolvedAuthMethod = kTeamCertificateAuth;
            keyPairs = [
              await teamCertificateSignIn(_ref.read(orchardServiceProvider), identityDb, identity, onLog: onLog),
            ];
            onLog?.call('identity: Team certificate attached for $username');
          } else if (identity.authMethod == 'hardwareToken') {
            resolvedAuthMethod = 'hardwareToken';
            // Agent-backed identity: the private key lives in the OS
            // ssh-agent (which may itself be backed by a YubiKey / smart
            // card / FIDO2 token). We never see the key material - we
            // hand the userauth path an OsAgentKeyPair that proxies
            // signing through the agent socket.
            final pubLine = identity.publicKeyData;
            // Its public key names it to the agent: without one that can be
            // read, there is nothing to ask the agent for.
            final parts = (pubLine ?? '').trim().split(RegExp(r'\s+'));
            if (parts.length < 2) {
              onLog?.call('identity: ERROR - no public key on file for the agent key');
              throw SSHAuthFailedException(gl10n.connAgentKeyNotOnFile(keyLabel));
            }
            try {
              final blob = base64.decode(parts[1]);
              keyPairs = [
                OsAgentKeyPair(
                  publicKeyBlob: Uint8List.fromList(blob),
                  algorithm: parts[0],
                  comment: identity.label,
                  // Whose agent (3.0): 1Password's or Bitwarden's
                  // where this device has it, unless set here.
                  socketPath: agentSocketHere(identity.agentSource, override: identity.agentSocketPath),
                ),
              ];
              onLog?.call(
                  'identity: Hardware-token / agent identity ready '
                  '(${parts[0]}). The agent will be contacted at sign time.');
            } catch (e) {
              onLog?.call('identity: ERROR - the public key on file for the agent key cannot be read - ${asLogLine('$e')}');
              throw SSHAuthFailedException(gl10n.connAgentKeyNotOnFile(keyLabel));
            }
          } else if (identity.authMethod == 'passwordManager') {
            // A password in the person's password manager (3.0):
            // fetched now, used once and never kept; on a phone, typed or
            // filled by the phone's password manager. Never saved here.
            resolvedAuthMethod = 'password';
            final String? fetched;
            try {
              fetched = await managedPassword(
                identityDb,
                identity,
                username: username,
                host: connection.host,
                port: connection.port,
                managers: _ref.read(passwordManagersProvider),
                // With nobody there, nobody is asked: the run stops at the
                // first question, as at every other one (toPerson).
                asker: unattended
                    ? NobodyToAsk(() => UnattendedSignInStopped(gl10n.unattendedNobodyToAsk))
                    : PromptedAsker(_ref.read),
                onLog: onLog,
              );
            } on PasswordRefMissing {
              throw SSHAuthFailedException(gl10n.pmRefMissing(identity.label));
            } on PasswordRefNotAllowed {
              onLog?.call('identity: Not allowed, so the password was not fetched');
              throw OrchardAccessRefused(gl10n.pmNotAllowed);
            }
            if (fetched == null) {
              onLog?.call('identity: Stopped: no password from the password manager');
              throw ConnectionCancelledException();
            }
            // Its own question to the person may have outlived the try as well.
            if (gone()) throw ConnectionCancelledException();
            password = fetched;
          }
          // A key's own password, tried after the key where a server does
          // not take the key and takes passwords (3.0, accounts per host):
          // fetched only then, and only where one was saved with the key as
          // that.
          if (identity.passwordAfterKey && kKeysWithPasswordAfter.contains(identity.authMethod)) {
            final signingIn = username;
            passwordAfterKey = () =>
                _passwordAfterKeyFor(identityDb, identity, connection, signingIn, onLog: onLog, toPerson: toPerson, ended: gone);
          }
        } catch (e, stack) {
          if (e is ConnectionCancelledException) rethrow;
          if (e is SSHAuthFailedException) rethrow;
          // An Orchard's rules refused the credentials: never a prompt instead.
          if (e is OrchardAccessRefused) rethrow;
          // A password manager's key is never asked for here and saved:
          // whatever went wrong, it stops.
          if (identity.authMethod == 'passwordManager') {
            onLog?.call('identity: ERROR getting the password from the password manager - $e');
            throw SSHAuthFailedException(gl10n.pmFailed);
          }
          if (e is SSHKeyDecryptError) {
            // Second decrypt attempt also failed (wrong passphrase)
            onLog?.call('identity: ERROR - wrong passphrase for encrypted key');
            AppLogger.error('Key decryption failed after passphrase prompt', e, stack);
            throw SSHAuthFailedException(gl10n.connKeyPassphraseWrong(keyLabel));
          }
          // What it failed with is named by its kind, and by what the
          // system's storage said where that is what failed: the words of
          // anything else can carry what was being read.
          final failed = signInReadFailure(e);
          onLog?.call('identity: ERROR reading credentials ($failed)');
          AppLogger.error('A saved sign-in could not be read', failed, stack);
          // Only a saved password is asked for in its place, and with why
          // (secure storage failing is common on Windows). A key, a
          // certificate or a key in an agent that could not be made ready
          // stops here: a password in its place is another sign-in than the
          // one that was chosen. (Every kind of sign-in fell back to a
          // password prompt, with no word of why.)
          if (identity.authMethod != 'password') {
            throw SSHAuthFailedException(gl10n.connSignInNotLoaded(keyLabel));
          }
          onLog?.call('identity: The saved password could not be read, asking for it...');
          final result = await toPerson(() => _promptForPassword(
                connection.host,
                username,
                why: gl10n.connSavedPasswordUnreadable,
                ended: gone,
              ));
          if (result == null) {
            throw ConnectionCancelledException();
          }
          password = result.password;
          if (result.saveToIdentity && await mayEditIn(_readDb(connection.id), 'key', identity.id)) {
            try {
              final identityCrud = _identityCrudFor(_readDb(connection.id));
              await identityCrud.setPassword(identity.id, result.password);
              onLog?.call('identity: Password saved to identity');
            } catch (_) {
              // If saving also fails, at least we have the password for this session
              onLog?.call('identity: WARNING - could not save password to secure storage');
            }
          }
        }
      } else {
        // The key this host signs in with is not on this device (deleted
        // elsewhere while this host was kept as it was; in a team space, a
        // key of a Crate this device cannot use): said, where it signed in
        // with nothing (the default user, no key).
        onLog?.call('identity: ERROR - the key this host signs in with is not on this device');
        throw SSHAuthFailedException(gl10n.connKeyNotHere);
      }
    } else {
      // No identity at all - prompt for password (quick connect scenario)
      onLog?.call('identity: No identity set, connecting as $username');
      // A host that is not saved (Quick connect) has nowhere to keep the
      // password: it is not offered. (Saving it made a key linked to
      // nothing, a new one each time.)
      final saved = !connection.id.startsWith('quick_');
      final result = await toPerson(() => _promptForPassword(
            connection.host,
            username,
            offerSave: saved,
            ended: gone,
          ));
      if (result == null) {
        onLog?.call('identity: User cancelled password prompt');
        throw ConnectionCancelledException();
      }
      password = result.password;
      resolvedAuthMethod = 'password';

      // Create and save identity if user checked "Save to identity" (in an
      // Orchard, where this account may change the host).
      if (saved && result.saveToIdentity && await mayEditIn(_readDb(connection.id), 'host', connection.id)) {
        final identityCrud = _identityCrudFor(_readDb(connection.id));
        final identityId = await identityCrud.create(
          label: '$username@${connection.host}',
          username: username,
          authMethod: 'password',
          password: result.password,
        );
        // Associate the new identity with this connection
        final connectionDb = _readDb(connection.id);
        final connectionCrud = ConnectionCrudNotifier(
          connectionDb.connectionsDao,
          connectionDb.portForwardRulesDao,
          connectionDb.connectionTagsDao,
        );
        await connectionCrud.update(
          id: connection.id,
          identityId: identityId,
        );
        onLog?.call(
          'identity: Saved as "$username@${connection.host}"',
        );
      }
    }

    return (
      username: username,
      password: password,
      passwordAfterKey: passwordAfterKey,
      keyPairs: keyPairs,
      keyPems: workerKeyPems,
      keyPassphrase: workerKeyPassphrase,
      authMethod: resolvedAuthMethod,
    );
  }

  /// The password saved with [identity]'s key, for a server that did not
  /// take the key and asks for a password ([passwordAfterKeyIn]), with the
  /// app's own questions: whether it is the person, where a Crate asks
  /// again, and the password, where none can be read. Each question goes
  /// through [toPerson], which a run with nobody there refuses.
  Future<String> _passwordAfterKeyFor(
    AppDatabase db,
    Identity identity,
    Connection connection,
    String username, {
    ConnectionLogCallback? onLog,
    required Future<T> Function<T>(Future<T> Function() question) toPerson,
    required bool Function() ended,
  }) async =>
      passwordAfterKeyIn(
        db,
        identity,
        connectionId: connection.id,
        host: connection.host,
        port: connection.port,
        username: username,
        crud: _identityCrudFor(db),
        askItIsYou: (destination) => toPerson(() => askConfirmItIsYou(_ref, destination: destination)),
        askForIt: (why) => toPerson(() => _promptForPassword(connection.host, username, why: why, ended: ended)),
        onLog: onLog,
        carrier: await screenCarrierRouteIn(db, connection),
      );

  /// Show an interactive password prompt via the UI layer.
  ///
  /// Sets [passwordPromptProvider] and waits for the dialog result.
  /// Returns `null` if the user cancels or the dialog times out. [why] is
  /// shown in the question where a password that is saved is asked for all
  /// the same.
  Future<PasswordPromptResult?> _promptForPassword(
    String host,
    String username, {
    String? why,
    bool offerSave = true,
    bool askUsername = false,
    bool Function()? ended,
  }) =>
      _oneQuestionAtATime(
          () => _askForPassword(host, username, why: why, offerSave: offerSave, askUsername: askUsername),
          ended: ended);

  /// Questions of a sign-in to its person, a password or a key's passphrase,
  /// are asked one at a time (3.0, Run on hosts): two connections that ask
  /// at once (hosts opened together, a run on many hosts) each get their own
  /// question, in turn, each with its own time to be answered. (The second
  /// took the first's place, and the first went unanswered until its time
  /// ran out.) A host's key and a server's own questions wait their turn
  /// already (HostKeyVerificationQueue, ServerQuestionQueue). One whose try
  /// is over by its turn ([ended]) is not asked: the person looking may be
  /// the next account's.
  Future<T> _oneQuestionAtATime<T>(Future<T> Function() ask, {bool Function()? ended}) {
    final turn = _questionAsked.then<T>((_) {
      if (ended?.call() ?? false) throw ConnectionCancelledException();
      return ask();
    });
    _questionAsked = turn.then((_) {}, onError: (Object _) {});
    return turn;
  }

  Future<void> _questionAsked = Future.value();

  Future<PasswordPromptResult?> _askForPassword(
    String host,
    String username, {
    String? why,
    bool offerSave = true,
    bool askUsername = false,
  }) async {
    AppLogger.info('Password prompt requested for $username@$host');
    final completer = Completer<PasswordPromptResult?>();
    _ref.read(passwordPromptProvider.notifier).state = PasswordPromptRequest(
      host: host,
      username: username,
      errorHint: why,
      completer: completer,
      offerSave: offerSave,
      askUsername: askUsername,
    );
    // Timeout after 2 minutes to prevent permanent hangs if the dialog
    // fails to show (e.g. no terminal screen mounted to display it).
    final result = await completer.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        AppLogger.warning('Password prompt timed out for $username@$host');
        return null;
      },
    );
    _ref.read(passwordPromptProvider.notifier).state = null;
    return result;
  }

  /// Show an interactive passphrase prompt for encrypted SSH keys.
  ///
  /// Similar to [_promptForPassword] but asks for the key passphrase
  /// and offers to save it to the identity's secure storage.
  Future<PassphrasePromptResult?> _promptForPassphrase(
    String host,
    String username, {
    bool Function()? ended,
  }) =>
      _oneQuestionAtATime(() => _askForPassphrase(host, username), ended: ended);

  Future<PassphrasePromptResult?> _askForPassphrase(
    String host,
    String username,
  ) async {
    AppLogger.info('Passphrase prompt requested for $username@$host');
    final completer = Completer<PassphrasePromptResult?>();
    _ref.read(passphrasePromptProvider.notifier).state =
        PassphrasePromptRequest(
      host: host,
      username: username,
      completer: completer,
    );
    final result = await completer.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        AppLogger.warning('Passphrase prompt timed out for $username@$host');
        return null;
      },
    );
    _ref.read(passphrasePromptProvider.notifier).state = null;
    return result;
  }

  /// Build a host key verification callback.
  ///
  /// Respects the [askBeforeTrustingKeysProvider] setting:
  /// - When off: auto-accept new (unknown) hosts without prompting.
  /// - Changed keys ALWAYS prompt regardless of the setting.
  ///
  /// Keys are checked against, and trusted into, the known hosts of the
  /// space [connectionId]'s sessions belong to (3.0): a reconnect
  /// while another space is on screen must not read that space's trust or
  /// leave an Orchard host's key in the Tree. When that space has closed
  /// (locked, or an Orchard that left this device) nothing is trusted.
  /// [_buildHostKeyVerifier], for tests of what a connect trusts.
  @visibleForTesting
  ChainHostKeyVerifyCallback debugHostKeyVerifier(
          {required String connectionId,
          String? dialedHost,
          int? dialedPort,
          bool unattended = false,
          bool Function()? ended}) =>
      _buildHostKeyVerifier(
        connectionId: connectionId,
        targetBaseHost: dialedHost,
        targetBasePort: dialedPort,
        targetDialedHost: dialedHost,
        targetDialedPort: dialedPort,
        unattended: unattended,
        ended: ended,
      );

  /// Whether what a question of a sign-in was asked for has gone by the time it is
  /// answered: this notifier, the try it belongs to ([ended]: its session was ended, as
  /// every session is at a change of account), or the database the host was read from (the
  /// next account's is open now, and a run with no session has no try to end).
  bool Function() _askedFor(String connectionId, bool Function()? ended) {
    final db = _sessionDb(connectionId);
    return () => !mounted || (ended?.call() ?? false) || !identical(_sessionDb(connectionId), db);
  }

  /// Who a server's own question at sign-in (a code, a password prompt
  /// where none is saved) goes to: the person ([serverQuestionAsker]); for a
  /// run with nobody there ([unattended], automation, 3.0) nobody, and the
  /// sign-in stops, saying so, where it showed the question on the screen to
  /// whoever was there and waited for an answer.
  ServerQuestionAsker _serverQuestions({
    required bool unattended,
    required String host,
    required int port,
    required String username,
    required bool Function() ended,
  }) {
    if (unattended) return (_) => Future<List<String>?>.error(UnattendedSignInStopped(gl10n.unattendedHostAsked));
    final ask = serverQuestionAsker(_ref, host: host, port: port, username: username);
    // An answer that comes once the try is over ([_askedFor]) goes to no server: as
    // if it was cancelled.
    return (question) async {
      final answer = await ask(question);
      return ended() ? null : answer;
    };
  }

  /// How an FTPS server's certificate that no authority vouches for is asked
  /// about (3.4): as a host key is, in the same queue and dialogs, in a
  /// certificate's words; a changed one is told to the notification centre as
  /// a changed key is. An answer that comes once the try is over trusts
  /// nothing.
  FtpsCertificateQuestion _askAboutCertificate(String connectionId, bool Function()? ended) {
    final gone = _askedFor(connectionId, ended);
    return ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async {
      final completer = Completer<bool>();
      if (previous != null) await _ref.read(changedHostKeysProvider.notifier).markChanged(host, port);
      _ref.read(hostKeyVerificationQueueProvider.notifier).enqueue(HostKeyVerification(
            certificate: true,
            host: host,
            port: port,
            hostKey: SSHHostKey(type: KnownHostsService.certificateKeyType, bytes: certificate.der),
            fingerprint: certificate.fingerprint,
            isChanged: previous != null,
            expectedFingerprint: previous,
            expectedTrustedAt: previousTrustedAt,
            completer: completer,
            teamPin: teamPin,
          ));
      final yes = await completer.future;
      if (gone()) throw ConnectionCancelledException();
      if (yes && previous != null) await _ref.read(changedHostKeysProvider.notifier).resolve(host, port);
      return yes;
    };
  }

  ChainHostKeyVerifyCallback _buildHostKeyVerifier({
    required String connectionId,
    String? targetBaseHost,
    int? targetBasePort,
    String? targetDialedHost,
    int? targetDialedPort,
    String? targetViaScope,
    bool unattended = false,
    bool Function()? ended,
  }) {
    // A question answered once the try is over ([_askedFor]) trusts nothing, and the
    // dial stops: a key would be trusted for an account that never saw it.
    final gone = _askedFor(connectionId, ended);
    void stopIfGone() {
      if (gone()) throw ConnectionCancelledException();
    }

    final knownHostsService = _spaces.knownHosts(connectionId);
    // (The host's space has closed: nothing is trusted there. A session of
    // such a host is stopped before it connects, so this is not reached.)
    if (knownHostsService == null) return (host, port, hostKey, {hostId}) async => false;
    final askBeforeTrusting = _ref.read(askBeforeTrustingKeysProvider);
    // Team-pinned host keys (3.0): the pins of the Orchard the
    // host's sessions belong to.
    final sessionDb = _spaces.database(connectionId);
    final team = sessionDb != null && sessionDb.isOrchard ? TeamHostKeys(sessionDb) : null;
    Future<String> crateName(String? crateId) async {
      if (crateId == null || sessionDb == null) return '';
      final row = await sessionDb.customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?',
          variables: [Variable<String>(crateId)]).getSingleOrNull();
      return row?.read<String?>('name') ?? '';
    }

    // A network override (or the resolver) can dial an endpoint different from
    // the connection's saved host:port. `targetOverridden` is true only when
    // that happened for the TARGET (jump hosts pass none of these args, so
    // their host-key behavior is unchanged).
    final targetOverridden = targetBaseHost != null &&
        targetBasePort != null &&
        targetDialedHost != null &&
        targetDialedPort != null &&
        (normalizeKnownHost(targetDialedHost) !=
                normalizeKnownHost(targetBaseHost) ||
            targetDialedPort != targetBasePort);

    return (host, port, hostKey, {String? hostId}) async {
      // Is this callback verifying the (possibly overridden) TARGET endpoint,
      // as opposed to a jump host along the way?
      final isTargetEndpoint = targetDialedHost != null &&
          normalizeKnownHost(host) == normalizeKnownHost(targetDialedHost) &&
          port == targetDialedPort;
      // Scope the TARGET's trust by its jump route so the same host:port
      // reached via different jump hosts doesn't collide into one record; jump
      // hops themselves stay unscoped (NULL), matching pre-v32 behavior.
      final viaScope = isTargetEndpoint ? targetViaScope : null;

      // F2 changed-key badge keying: the host card is keyed by the saved
      // (base) host:port, so record/clear the badge under the base identity
      // when we're on the target's overridden endpoint. Jump hosts and the
      // non-overridden target keep dialed==base, so this is a no-op there.
      final badgeHost =
          (isTargetEndpoint && targetOverridden) ? targetBaseHost : host;
      final badgePort =
          (isTargetEndpoint && targetOverridden) ? targetBasePort : port;

      // A key the team pinned here is trusted without a prompt; any
      // other key stops the connection until someone who may edit the pin's
      // Crate checks it and replaces the pin. A pin counts only for the
      // hosts of its own Crate: the one looked for is that of the host the
      // key is for (a jump host on the way is [hostId]), so a pin another
      // Crate made for the same address is not this host's.
      final pin = team == null
          ? null
          : await team.pinFor(host, port, viaScope: viaScope, crateId: await team.crateOfHost(hostId ?? connectionId));
      if (pin != null) {
        if (pin.matches(hostKey)) return true;
        // A run with nobody there (automation, 3.0) asks nothing: another
        // key than the team's stops it.
        if (unattended) {
          await _ref.read(changedHostKeysProvider.notifier).markChanged(badgeHost, badgePort);
          throw HostKeyNotAccepted(HostKeyRefusal.changedUnattended, host: host, port: port);
        }
        final mayReplace = await team!.mayPinIn(pin.crateId);
        final completer = Completer<bool>();
        await _ref.read(changedHostKeysProvider.notifier).markChanged(badgeHost, badgePort);
        _ref.read(hostKeyVerificationQueueProvider.notifier).enqueue(HostKeyVerification(
              host: host,
              port: port,
              hostKey: hostKey,
              fingerprint: knownHostsService.getFingerprint(hostKey),
              isChanged: true,
              expectedFingerprint: pin.fingerprint,
              completer: completer,
              teamPin: TeamPinPrompt(crateName: await crateName(pin.crateId), mayChange: mayReplace, pinned: true),
            ));
        final replaced = await completer.future;
        stopIfGone();
        if (!mayReplace) {
          throw HostKeyNotAccepted(HostKeyRefusal.pinnedOther,
              host: host, port: port, crate: await crateName(pin.crateId));
        }
        if (!replaced) throw HostKeyNotAccepted(HostKeyRefusal.declinedChanged, host: host, port: port);
        await team.pin(host, port, hostKey, viaScope: viaScope, crateId: pin.crateId!);
        await knownHostsService.trustHost(host, port, hostKey, viaScope: viaScope);
        await _ref.read(changedHostKeysProvider.notifier).resolve(badgeHost, badgePort);
        return true;
      }
      // No pin yet: someone who may edit the host's Crate can trust the key
      // for everyone in it when they trust it here.
      TeamPinPrompt? offer;
      String? pinCrate;
      if (team != null && isTargetEndpoint) {
        pinCrate = await team.crateOfHost(connectionId);
        if (await team.mayPinIn(pinCrate)) {
          offer = TeamPinPrompt(crateName: await crateName(pinCrate), mayChange: true, pinned: false);
        }
      }
      Future<void> pinIfChosen() async {
        if (offer != null && offer.forEveryone) {
          await team!.pin(host, port, hostKey, viaScope: viaScope, crateId: pinCrate!);
        }
      }

      // A run with nobody there tells no one: a key that came by sync or from
      // a backup stays to be pointed out at the person's own first session.
      final outcome = await knownHostsService.verify(host, port, hostKey,
          viaScope: viaScope, tellsPerson: !unattended);
      final result = outcome.result;

      // SECURITY: when an override reroutes the target to a NEW address, its
      // key is unknown there so verify() returns `newHost` (never `changed`)
      // and - with "ask before trusting" off - would auto-accept SILENTLY,
      // turning a network profile into a transparent MITM. Force the
      // interactive prompt in that case so the user sees the actually-dialed
      // address before trusting it.
      final forcePrompt = isTargetEndpoint && targetOverridden;

      switch (result) {
        case HostKeyVerifyResult.trusted:
          // First local confirmation of a key ADOPTED from the vault: surface
          // its provenance once (non-blocking), so a synced fingerprint is
          // never trusted silently. Connection proceeds either way.
          final prov = outcome.adoptedFrom;
          if (prov != null) {
            _ref.read(hostKeyProvenanceProvider.notifier).state =
                HostKeyProvenanceEvent(
              host: host,
              port: port,
              device: prov.device,
              recordedAt: prov.recordedAt,
            );
          }
          return true;

        case HostKeyVerifyResult.newHost:
          // A run with nobody there (automation, 3.0) takes no new key: not
          // asked, and not trusted by itself whatever "ask before trusting"
          // is, as automation's own runs never did.
          if (unattended) throw HostKeyNotAccepted(HostKeyRefusal.unknownUnattended, host: host, port: port);
          // Auto-accept new hosts if the user disabled the prompt - UNLESS
          // this is an override-rerouted target, which must always be shown.
          if (!askBeforeTrusting && !forcePrompt) {
            await knownHostsService.trustHost(host, port, hostKey,
                viaScope: viaScope);
            // Notify the UI so a brief toast is shown - the user should
            // know when a new host key is silently trusted.
            _ref.read(hostKeyAutoAcceptProvider.notifier).state =
                HostKeyAutoAcceptEvent(
              host: host,
              port: port,
              keyType: hostKey.type,
              fingerprint: knownHostsService.getFingerprint(hostKey),
            );
            return true;
          }
          // Fall through to prompt
          final newCompleter = Completer<bool>();
          final newFingerprint = knownHostsService.getFingerprint(hostKey);

          // Enqueue rather than overwrite: several hosts connecting at once
          // each get their own prompt in turn. The dialog resolves + dequeues.
          _ref.read(hostKeyVerificationQueueProvider.notifier).enqueue(
            HostKeyVerification(
              host: host,
              port: port,
              hostKey: hostKey,
              fingerprint: newFingerprint,
              isChanged: false,
              completer: newCompleter,
              teamPin: offer,
            ),
          );

          final newAccepted = await newCompleter.future;
          stopIfGone();
          if (!newAccepted) throw HostKeyNotAccepted(HostKeyRefusal.declinedNew, host: host, port: port);

          await knownHostsService.trustHost(host, port, hostKey, viaScope: viaScope);
          await pinIfChosen();
          return true;

        case HostKeyVerifyResult.changed:
          // Changed keys ALWAYS prompt - this is a security-critical event.
          final changedCompleter = Completer<bool>();
          final changedFingerprint = knownHostsService.getFingerprint(hostKey);
          // Pull the previously-trusted fingerprint + trust date so the
          // warning can show BOTH keys side by side and when the old one was
          // trusted.
          final expected = await knownHostsService
              .trustedKeyInfo(host, port, hostKey.type, viaScope: viaScope);

          // Persist the unresolved changed-key condition so the host card can
          // surface it without a fresh connection attempt (F2). Set on detect;
          // cleared below only if the user explicitly trusts the new key.
          await _ref
              .read(changedHostKeysProvider.notifier)
              .markChanged(badgeHost, badgePort);
          // A run with nobody there asks nothing: stopped, its host card
          // showing the changed key.
          if (unattended) throw HostKeyNotAccepted(HostKeyRefusal.changedUnattended, host: host, port: port);

          _ref.read(hostKeyVerificationQueueProvider.notifier).enqueue(
            HostKeyVerification(
              host: host,
              port: port,
              hostKey: hostKey,
              fingerprint: changedFingerprint,
              isChanged: true,
              expectedFingerprint: expected?.fingerprint,
              expectedTrustedAt: expected?.trustedAt,
              completer: changedCompleter,
              teamPin: offer,
            ),
          );

          final changedAccepted = await changedCompleter.future;
          stopIfGone();
          if (!changedAccepted) throw HostKeyNotAccepted(HostKeyRefusal.declinedChanged, host: host, port: port);

          await knownHostsService.trustHost(host, port, hostKey, viaScope: viaScope);
          await pinIfChosen();
          // Resolved - stop warning on the host card.
          await _ref.read(changedHostKeysProvider.notifier).resolve(badgeHost, badgePort);
          return true;
      }
    };
  }

  /// Resolve the SSH private key path for a connection's identity.
  ///
  /// If the identity uses public key auth, writes the PEM to a temporary
  /// file and returns the path. The caller is responsible for cleanup
  /// (MoshService handles this on disconnect).
  ///
  /// Returns `null` if the identity doesn't use public key auth or has
  /// no private key stored.
  Future<String?> _resolveIdentityKeyPath(Connection connection) async {
    if (connection.identityId == null) return null;

    final keyDb = _readDb(connection.id);
    final identityDao = keyDb.identitiesDao;
    final identity = await identityDao.getById(connection.identityId!);
    if (identity == null || identity.authMethod != 'publicKey') return null;
    // A key file on disk is the key itself: an Orchard key reached at
    // Connect never becomes one (3.0).
    await requireRevealIn(keyDb, identity.id, refusal: keyFileRefusal);
    // Nor does a watched Crate's key go to any host but its own.
    await requireWatchedKeyHostIn(keyDb, identity.id, connection.id);

    final identityCrud = _identityCrudFor(keyDb);
    final pem = await identityCrud.getPrivateKey(identity.id);
    if (pem == null) return null;

    // On Windows, Mosh and Eternal Terminal run inside WSL: the key is
    // written there, where their ssh reads it, and what a crash left there
    // goes first (wsl_key_file.dart; they were handed its path in Windows,
    // which ssh in WSL cannot open).
    if (Platform.isWindows) {
      await clearLeftoverKeysInWsl();
      return writeKeyInWsl(pem);
    }

    // What a crash left of earlier ones (a key in the clear among them) is
    // removed first: a session's own is removed when it ends, but where the
    // app was ended before that it stays (as it does at start-up).
    await clearLeftoverCopies();

    // Write PEM to a secure temporary file for mosh's SSH subprocess.
    // Security: set restrictive permissions BEFORE writing the key content
    // to prevent a race window where the key is readable by other users.
    final tempDir = await Directory.systemTemp.createTemp('zestssh_mosh_');
    final keyFile = File('${tempDir.path}/id_key');

    try {
      // Create the file empty first, then lock down permissions before
      // writing the key. If we CAN'T confirm the file is locked down, abort
      // rather than write a plaintext key with unknown permissions.
      await keyFile.create();

      final permExit = (await Process.run('chmod', ['600', keyFile.path])).exitCode;
      if (permExit != 0) {
        throw StateError(
            'Failed to restrict mosh key file permissions (exit $permExit)');
      }

      await keyFile.writeAsString(pem);
      return keyFile.path;
    } catch (e) {
      // Any failure past createTemp: delete the whole dir so a partially
      // written / world-readable key never survives.
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {/* best effort */}
      rethrow;
    }
  }

  /// Build an SshService with identity credentials.
  ///
  /// If the connection has a `connectViaId` (jump host), this builds
  /// the FULL chain - each hop's own `connectViaId` is followed
  /// recursively until we hit a connection with no jump host.  We
  /// guard against cycles (A → B → A) with a visited set so a
  /// misconfiguration can't hang the connect path forever.
  // Returns a [ShellService]: normally a [SshService], but a DIRECT,
  // terminal-only session with the worker flag on returns a [WorkerSshService]
  // whose transport runs on its own isolate (Design B). The caller already
  // treats the result as a ShellService; SFTP/port-forward/exec consumers gate
  // on `is SshService`, which a worker session is deliberately not, so those
  // features correctly stay on the in-isolate path.
  Future<ShellService> _createSshShell(
    Connection connection, {
    ConnectionLogCallback? onLog,
    String? usernameOverride,
    bool accountChosen = false,
    bool forCommands = false,
    bool unattended = false,
    bool Function()? ended,
    SignInNoticeFor noticeFor = SignInNoticeFor.session,
  }) async {
    // ── Network resolution (per-host overrides + skip-host) ──────────────
    //
    // Route the SSH connect through the ConnectionResolver so per-host
    // network overrides (address / port / username / identity / jump chain)
    // and "skip on this network" actually take effect at connect time.
    //
    // GUARD (critical, non-negotiable): a resolver failure must NEVER be able
    // to break a base connection.
    //   • HostUnreachableException (skip-host) → abort cleanly with a
    //     friendly, localized message. We never open a socket.
    //   • ANY other error (StateError for an unknown/edge host id, a detector
    //     failure, a timeout, a resolver bug, …) → log it and fall back to
    //     the EXACT base `connection` config, i.e. behave precisely as this
    //     flow did before the resolver was ever wired in.
    ResolvedConnection? resolved;
    try {
      resolved = await _resolverFor(connection.id)
          .resolve(connection.id)
          // Defensive cap: resolve() consults the network detector
          // (connectivity / SSID), which lives OFF the critical connect path.
          // If it ever hangs, time out and fall back to the base config
          // rather than wedging the connection forever. try/catch below
          // turns the resulting TimeoutException into that fallback.
          .timeout(const Duration(seconds: 5));
    } on HostUnreachableException catch (e) {
      // The user explicitly marked this host unreachable on the current
      // network. Surface a friendly, localized message through the same error
      // path every other connect failure uses (the catch in _connectAsync
      // populates connectionErrorProvider + fires the notification). Do NOT
      // touch a socket - just abort.
      onLog?.call(
        'network: "${e.hostName}" is set to skip on "${e.networkName}"',
      );
      throw HostSkippedOnNetworkException(
        _skipHostMessage(e.hostName, e.networkName),
      );
    } catch (e) {
      // Resolver bug, DB edge, deleted host id, detector failure, timeout,
      // etc. Falling back to the base config keeps the critical connect path
      // alive no matter what the (newer) resolver does.
      AppLogger.warning(
        'Network resolver failed for connection "${connection.id}"; '
        'falling back to base connection config: $e',
      );
      resolved = null; // explicit: use the base config unchanged
    }

    // Effective endpoint. In the no-override case AND the fallback case these
    // equal the base fields verbatim, so the common path is byte-identical.
    final effectiveHost = resolved?.address ?? connection.host;
    final effectivePort = resolved?.port ?? connection.port;

    // Feed the RESOLVED identity + address into the credential loader so an
    // override that swaps the SSH key actually loads that key, and so
    // password / passphrase prompts name the address we're truly dialing.
    // In the no-override / fallback case we pass the untouched `connection`,
    // so credential loading is byte-identical to before this change.
    // An account chosen for this session (Connect as, [accountChosen]) is
    // signed in with on any network: a network's identity stands in for the
    // host's default, not for it.
    final credConnection = resolved == null
        ? connection
        : connection.copyWith(
            host: effectiveHost,
            port: effectivePort,
            identityId: Value(accountChosen ? connection.identityId : resolved.identityKeyId),
          );
    final creds = await _resolveIdentity(
      credConnection,
      onLog: onLog,
      usernameOverride: usernameOverride,
      unattended: unattended,
      ended: ended,
    );

    // Username precedence. The expression below is exactly:
    //     override.username > identity.username > usernameOverride > default
    // Reasoning:
    //   • resolved.username == override.username ?? identity.username ?? ''
    //     (the identity here is the RESOLVED identity, same row creds loaded).
    //   • creds.username    == identity.username (if identity present)
    //                          else usernameOverride ?? default.
    // So when resolved.username is non-empty it is either the override's
    // username (which must win) or the identity's username; when it's empty
    // there is neither an override username nor an identity, and we fall
    // through to creds.username, preserving the quick-connect usernameOverride
    // precedence. In the no-override case resolved.username == creds.username
    // (same identity) or '' → creds.username, so this is byte-identical.
    // NOTE: a network-override username therefore beats a quick-connect
    // usernameOverride - see the report for the one edge a human should eyeball.
    // An account chosen for the session signs in as its own user.
    final effectiveUsername =
        (!accountChosen && resolved != null && resolved.username.isNotEmpty)
            ? resolved.username
            : creds.username;

    // Scope the target's host-key trust by the jump route ([_targetViaScope]).
    final targetViaScope = await _targetViaScope(connection, resolved);

    final hostKeyVerifier = _buildHostKeyVerifier(
      connectionId: connection.id,
      targetBaseHost: connection.host,
      targetBasePort: connection.port,
      targetDialedHost: effectiveHost,
      targetDialedPort: effectivePort,
      targetViaScope: targetViaScope,
      unattended: unattended,
      ended: ended,
    );

    SSHSocket? tunnelSocket;
    final jumpClients = <SSHClient>[];
    final jumpLabels = <String>[];
    // What a chain of jump hosts gives: the way to the host, the jump hosts
    // it goes through, and what each of them is called.
    void through(_JumpChainResult chain) {
      tunnelSocket = chain.targetSocket;
      jumpClients.addAll(chain.clients);
      jumpLabels.addAll(chain.labels);
    }

    // ── Jump chain ───────────────────────────────────────────────────────
    //
    // resolved.jumpChain semantics (see ConnectionResolver):
    //   • no override → [connection.connectViaId] (or [] when none): this
    //     captures ONLY the immediate hop. The full multi-hop chain (A→B→C)
    //     is still discovered by following each hop's OWN connectViaId - the
    //     legacy recursive model. We MUST keep that to stay byte-identical
    //     for existing multi-hop hosts.
    //   • override present → the override's explicit chain (jumpHostId → [id],
    //     jumpHostChain → verbatim, or [] meaning "no jump on this network").
    //
    // So we only dial the resolved chain EXPLICITLY when a network override
    // actually changed the jump routing; otherwise we run the exact legacy
    // recursion (just aimed at the effective, possibly-overridden endpoint).
    final baseChain = connection.connectViaId != null
        ? <String>[connection.connectViaId!]
        : const <String>[];
    final jumpChangedByOverride =
        resolved != null && !_sameJumpChain(resolved.jumpChain, baseChain);

    // Free-tier gate. Jump-host routing, the base Connect Via chain and any
    // per-network override chain alike, is a Squeezed feature. Only the base
    // field was ever locked (in the editor), so an override chain, or a
    // connectViaId that arrived by sync or import, still routed for a free
    // user. Decide it here, the one place a chain is dialed: a gated chain
    // falls back to a direct connection and raises a one-time notice naming
    // the source, so it degrades loudly rather than silently.
    final gateSkip = ConnectionResolver.jumpGateSkip(
      isPro: _ref.read(isProProvider),
      baseHasConnectVia: connection.connectViaId != null,
      overrideChangedJump: jumpChangedByOverride,
      overrideChain: resolved?.jumpChain ?? const <String>[],
      networkName: resolved?.network.name,
    );

    if (gateSkip != null) {
      onLog?.call('jump: Jump host routing needs Squeezed; connecting directly.');
      _raiseJumpGateNotice(connection, gateSkip);
    } else if (jumpChangedByOverride) {
      // `resolved` is promoted non-null here: jumpChangedByOverride is a final
      // bool whose definition includes `resolved != null`, so flow analysis
      // knows it can't be null inside this branch.
      if (resolved.jumpChain.isNotEmpty) {
        onLog?.call('jump: Building jump host chain (network override)…');
        final chain = await _buildJumpChain(
          connection,
          hostKeyVerifier,
          onLog,
          targetHost: effectiveHost,
          targetPort: effectivePort,
          override: (chain: resolved.jumpChain, network: resolved.network.name),
          unattended: unattended,
          ended: ended,
          noticeFor: noticeFor,
        );
        through(chain);
      }
      // else: the override explicitly CLEARED the jump → direct connection.
    } else if (connection.connectViaId != null) {
      // No jump override (or the resolver fell back) → legacy recursive path.
      // Hop resolution is byte-identical to before; the final tunnel just
      // targets the effective endpoint (== base host/port when nothing was
      // overridden), so an address/port override with a base jump still works.
      onLog?.call('jump: Building jump host chain…');
      final chain = await _buildJumpChain(
        connection,
        hostKeyVerifier,
        onLog,
        targetHost: effectiveHost,
        targetPort: effectivePort,
        unattended: unattended,
        ended: ended,
        noticeFor: noticeFor,
      );
      through(chain);
    }

    // S2: a connection with no explicit keepalive (keepAliveSeconds == 0)
    // falls back to the global setting (default 30s; 0 there = disabled).
    final effectiveKeepAlive = connection.keepAliveSeconds > 0
        ? connection.keepAliveSeconds
        : _ref.read(keepaliveIntervalProvider);
    // Agent forwarding only where the host's Crate allows it (3.0).
    final forwardAgent = connection.forwardAgent && await hostAllows(connection.id, CrateSwitches.agent);

    // The in-isolate session (also the Design B worker's graceful fallback).
    SshService buildInIsolate() => SshService(
          host: effectiveHost,
          port: effectivePort,
          username: effectiveUsername,
          password: creds.password,
          passwordAfterKey: creds.passwordAfterKey,
          keyPairs: creds.keyPairs,
          zlibCompression: connection.zlibCompression,
          forwardAgent: forwardAgent,
          keepAliveSeconds: effectiveKeepAlive,
          compatibilityMode: connection.compatibilityMode,
          connectTimeout: _connectTimeout,
          onLog: onLog,
          onAgentSigned: () => _agentSigned(connection, onLog),
          // A 2FA code or other server question goes to the person (not
          // for a run with nobody there: it stops).
          onServerQuestion: _serverQuestions(
            unattended: unattended,
            host: effectiveHost,
            port: effectivePort,
            username: effectiveUsername,
            ended: _askedFor(connection.id, ended),
          ),
          // A login banner with a link the sign-in waits on (Tailscale SSH's
          // check) goes to the person; with nobody there it waits for the
          // shell, as every banner does.
          onSignInNotice: unattended
              ? null
              : signInNoticeShower(_ref,
                  host: effectiveHost, port: effectivePort, username: effectiveUsername, purpose: noticeFor),
          tunnelSocket: tunnelSocket,
          jumpClients: jumpClients,
          jumpLabels: jumpLabels,
          onHostKeyVerify: hostKeyVerifier,
        );

    // ── Design B: connection-isolation worker path ──────────────────────
    //
    // Route ONLY a DIRECT (no jump chain / no tunnel socket), terminal-only
    // session whose auth method can cross to a worker (password, or a plain
    // public key we hold the PEM for) onto a dedicated worker isolate. SFTP,
    // port-forward, jump chains, certificate + hardware-token auth all stay
    // on the in-isolate path. Guarded by the flag (default OFF), so production
    // is unaffected until it is deliberately enabled.
    // (Nor a key with a password saved with it: that is fetched where the
    // session runs, when a server asks for it.)
    // Nor a connection with no terminal ([forCommands]: Run on hosts, and a
    // session that is files only): the worker makes a terminal's.
    final workerEligible = kWorkerConnectionIsolation &&
        !forCommands &&
        tunnelSocket == null &&
        jumpClients.isEmpty &&
        creds.passwordAfterKey == null &&
        (creds.authMethod == 'password' ||
            (creds.authMethod == 'publicKey' && creds.keyPems.isNotEmpty));

    if (workerEligible) {
      onLog?.call(
          'worker: running this session on a connection worker isolate');
      return WorkerSshService(
        onAgentSigned: () => _agentSigned(connection, onLog),
        params: ConnectParams(
          host: effectiveHost,
          port: effectivePort,
          username: effectiveUsername,
          compatibilityMode: connection.compatibilityMode,
          zlibCompression: connection.zlibCompression,
          forwardAgent: forwardAgent,
          keepAliveSeconds: effectiveKeepAlive,
        ),
        keyPems: creds.keyPems,
        passphrase: creds.keyPassphrase,
        password: creds.password,
        forwardAgent: forwardAgent,
        onHostKeyVerify: hostKeyVerifier,
        onLog: onLog,
        // As the in-isolate session's: a login banner's link goes to the
        // person, never for a run with nobody there.
        onSignInNotice: unattended
            ? null
            : signInNoticeShower(_ref,
                host: effectiveHost, port: effectivePort, username: effectiveUsername, purpose: noticeFor),
        fallbackFactory: buildInIsolate,
      );
    }

    return buildInIsolate();
  }

  /// [connectionIds] are about to be run on (3.0, Run on hosts): each is
  /// run in the space on screen now, as a session opened now would be, and
  /// stays in it for the run and for running it again, whatever space is on
  /// screen by the time its turn comes.
  void runStarting(Iterable<String> connectionIds) {
    for (final id in connectionIds) {
      _spaces.opened(id);
    }
  }

  /// A connection to [connection] for running commands on it without a
  /// terminal (3.0, Run on hosts): signed in as a session to it would be
  /// (the network the device is on, the jump hosts on the way, its default
  /// account, its space's rules; a password, a server's question or a
  /// host's key that is new asked of its person), with no terminal, and not
  /// counted as a session. SSH only. A team's host has it noted as a
  /// connection is, and logged for its team where its Crate logs
  /// sessions ([RunClient.teamLog]). Throws what stops it, as a
  /// session's connect does ([connectionFailureText] says it). The caller
  /// ends it ([SshService.disconnect]) and its team's log
  /// ([TeamSessionLogs.end]).
  ///
  /// For a run with nobody there ([unattended]: automation's tasks, 3.0) it
  /// signs in only with keys allowed for unattended runs, asks nobody
  /// anything (what it would ask stops it: [UnattendedSignInStopped], a
  /// host's key this device does not trust), and is no use of the host by
  /// its person ("last used"). [space], where it is given, is the space the
  /// host is run in (automation's: your Tree), whatever is on screen; else
  /// the one it was filed under when the run started ([runStarting]).
  Future<RunClient> openRunClient(Connection connection,
      {ConnectionLogCallback? onLog, bool unattended = false, Space? space}) async {
    // A host that is SFTP only runs no command: its server refuses one.
    final noTerminal = noTerminalReason(connection, gl10n);
    if (noTerminal != null) throw SSHAuthFailedException(noTerminal);
    if (connection.protocol != 'ssh') {
      throw SSHAuthFailedException(gl10n.runOnHostsSshOnly);
    }
    if (space != null) _spaces.opened(connection.id, space: space);
    // A host of a Crate whose sessions are watched is run on only in a
    // session someone watches.
    if (await hostIsWatchedIn(_readDb(connection.id), connection.id)) {
      throw OrchardAccessRefused(gl10n.runOnHostsWatched);
    }
    final shell = await _createSshShell(connection,
        onLog: onLog, forCommands: true, unattended: unattended, noticeFor: SignInNoticeFor.run);
    final ssh = shell as SshService;
    try {
      await ssh.connectExec();
    } catch (_) {
      await ssh.disconnect();
      rethrow;
    }
    // A run is a use of the host, as a session is ("last used"); one that
    // runs by itself is not its person's.
    final db = _sessionDb(connection.id);
    if (db != null && !unattended) unawaited(db.connectionsDao.touchLastConnected(connection.id));
    if (db == null || !db.isOrchard) return RunClient(ssh);
    // A team's host: a note while its owners record activity, and the
    // run logged for them where they log its sessions, decided before
    // the command runs.
    final service = _ref.read(orchardServiceProvider);
    unawaited(noteActivityIn(service, db, ActivityKind.connect,
        itemKind: 'host', itemKey: connection.id, name: connection.label));
    final logId = 'run_${connection.id}_${DateTime.now().microsecondsSinceEpoch}';
    await startTeamSessionLogFor(service, db, logId,
        connectionId: connection.id,
        label: connection.label.isNotEmpty ? connection.label : hostWithPort(connection.host, connection.port),
        host: connection.host,
        port: connection.port,
        user: ssh.username);
    return RunClient(ssh, teamLog: TeamSessionLogs.isLogged(logId) ? logId : null);
  }

  /// Open an AUTHENTICATED SSH client for [connection] with NO PTY, for the
  /// agentless Server Monitor poller.
  ///
  /// Runs the same network-resolution + jump-chain + algorithm path as
  /// [_createSshShell] (its steps 1-4) but with the NON-INTERACTIVE credential
  /// resolver + TRUST-ONLY host-key verifier from [SshConnectionFactory], then
  /// authenticates via [SshService.connectExec] (no `shell()`). It therefore
  /// NEVER prompts, NEVER opens a terminal tab, and (because it doesn't touch
  /// [state]) NEVER counts against the terminal-session cap.
  ///
  /// Returns a [MonitorExecResult]. On [MonitorExecOutcome.ok] the caller owns
  /// the returned [SshService] and MUST call `disconnect()` when done. The
  /// expected "can't poll this host" cases (missing creds, unverified host
  /// key, wrong protocol) are reported as outcomes, not thrown.
  /// Free-tier jump gate: hand the notice to `app.dart`, which shows it once
  /// per host and source (persisted) with an Upgrade action. Raised on every
  /// gated connect; the once-only memory lives with the listener.
  void _raiseJumpGateNotice(Connection connection, JumpGateSkip skip) {
    final source =
        skip.fromOverride ? (skip.networkName ?? 'override') : 'base';
    _ref.read(jumpHostGateNoticeProvider.notifier).state = JumpHostGateNotice(
      key: '${connection.id}:$source',
      hostLabel:
          connection.label.isNotEmpty ? connection.label : connection.host,
      fromOverride: skip.fromOverride,
      networkName: skip.networkName,
    );
  }

  Future<MonitorExecResult> openExecClient(Connection connection) async {
    if (connection.protocol != 'ssh') {
      return MonitorExecResult.notEligible('protocol=${connection.protocol}');
    }
    // A session to a watched Crate's host runs only while someone watches
    // it (3.0): the app makes no connection to one by itself.
    if (await hostIsWatchedIn(_readDb(connection.id), connection.id)) {
      return MonitorExecResult.notEligible('sessions in its Crate are watched');
    }
    // Nor to a host, or with a key, of a Crate that its own offline limit
    // has closed on this device.
    try {
      await requireCratesOpenIn(_readDb(connection.id), hostId: connection.id, keyId: connection.identityId);
    } on CrateClosedOffline {
      return MonitorExecResult.notEligible('its Crate is closed on this device');
    }

    final factory = _ref.read(sshConnectionFactoryProvider);

    // ── Step 1: network resolution (same guard/fallback as _createSshShell)
    ResolvedConnection? resolved;
    try {
      resolved = await _resolverFor(connection.id)
          .resolve(connection.id)
          .timeout(const Duration(seconds: 5));
    } on HostUnreachableException {
      // The host is explicitly skipped on the current network - nothing to
      // poll right now (not an error, not a credential problem).
      return MonitorExecResult.notEligible('skipped on current network');
    } catch (e) {
      // Resolver edge/bug/timeout → fall back to the base config, exactly as
      // the interactive connect path does.
      AppLogger.warning(
          'Monitor: resolver failed for "${connection.id}", using base: $e');
      resolved = null;
    }

    final effectiveHost = resolved?.address ?? connection.host;
    final effectivePort = resolved?.port ?? connection.port;
    final credConnection = resolved == null
        ? connection
        : connection.copyWith(
            host: effectiveHost,
            port: effectivePort,
            identityId: Value(resolved.identityKeyId),
          );

    // ── Step 2: silent credential resolution for the TARGET ─────────────
    final creds = await factory.resolveCredentialsSilently(credConnection);
    if (creds == null) return MonitorExecResult.needsCredentials();

    final effectiveUsername =
        (resolved != null && resolved.username.isNotEmpty)
            ? resolved.username
            : creds.username;

    // Any jump hop that can't be resolved silently aborts the whole poll (the
    // _buildJumpChain cleanup-on-throw tears down partial connections).
    Future<SilentCreds> resolveHopSilently(Connection hop) async {
      final hopCreds = await factory.resolveCredentialsSilently(hop);
      if (hopCreds == null) {
        throw NotSilentlyPollableException(
            hop.label.isNotEmpty ? hop.label : hop.host);
      }
      return hopCreds;
    }

    // ── Step 3: trust-only host-key verifier ────────────────────────────
    // The host's key is looked for under the jump route it is reached by, as
    // a session looks for it, and its card is marked under the address it is
    // saved with; a jump host's on the way, as itself.
    final signal = HostKeyReviewSignal();
    final hostKeyVerifier = factory.buildTrustOnlyHostKeyVerifier(
      signal,
      target: (
        hostId: connection.id,
        host: effectiveHost,
        port: effectivePort,
        viaScope: await _targetViaScope(connection, resolved),
        savedHost: connection.host,
        savedPort: connection.port,
      ),
    );

    SSHSocket? tunnelSocket;
    final jumpClients = <SSHClient>[];

    // ── Step 4: jump chain (same override-vs-legacy split as _createSshShell)
    final baseChain = connection.connectViaId != null
        ? <String>[connection.connectViaId!]
        : const <String>[];
    final jumpChangedByOverride =
        resolved != null && !_sameJumpChain(resolved.jumpChain, baseChain);

    // Same Free-tier jump gate as the interactive connect: a monitored host
    // behind a bastion is polled directly on the free tier. The notice shares
    // the interactive path's one-time key, so it never repeats what a connect
    // already said, and it explains a poll that then fails.
    final gateSkip = ConnectionResolver.jumpGateSkip(
      isPro: _ref.read(isProProvider),
      baseHasConnectVia: connection.connectViaId != null,
      overrideChangedJump: jumpChangedByOverride,
      overrideChain: resolved?.jumpChain ?? const <String>[],
      networkName: resolved?.network.name,
    );

    SshService? service;
    try {
      if (gateSkip != null) {
        _raiseJumpGateNotice(connection, gateSkip);
      } else if (jumpChangedByOverride) {
        // `resolved` is promoted non-null: jumpChangedByOverride is a final
        // bool whose definition includes `resolved != null`.
        if (resolved.jumpChain.isNotEmpty) {
          final chain = await _buildJumpChain(
            connection,
            hostKeyVerifier,
            null,
            targetHost: effectiveHost,
            targetPort: effectivePort,
            override: (chain: resolved.jumpChain, network: resolved.network.name),
            hopCredentialResolver: resolveHopSilently,
          );
          tunnelSocket = chain.targetSocket;
          jumpClients.addAll(chain.clients);
        }
        // else: override explicitly cleared the jump → direct connection.
      } else if (connection.connectViaId != null) {
        final chain = await _buildJumpChain(
          connection,
          hostKeyVerifier,
          null,
          targetHost: effectiveHost,
          targetPort: effectivePort,
          hopCredentialResolver: resolveHopSilently,
        );
        tunnelSocket = chain.targetSocket;
        jumpClients.addAll(chain.clients);
      }

      service = SshService(
        host: effectiveHost,
        port: effectivePort,
        username: effectiveUsername,
        password: creds.password,
        keyPairs: creds.keyPairs,
        zlibCompression: connection.zlibCompression,
        // No agent forwarding, whatever the host's switch says. The switch
        // is for a session its person works in, to reach a next host from
        // there. This connection is made in the background and only reads
        // figures: it has no use for the agent, and forwarding it would let
        // the host use the person's keys for as long as it is monitored.
        forwardAgent: false,
        // S2: same effective-keepalive resolution as the interactive path -
        // fall back to the global setting when the connection has none.
        keepAliveSeconds: connection.keepAliveSeconds > 0
            ? connection.keepAliveSeconds
            : _ref.read(keepaliveIntervalProvider),
        compatibilityMode: connection.compatibilityMode,
        connectTimeout: _connectTimeout,
        tunnelSocket: tunnelSocket,
        jumpClients: jumpClients,
        onHostKeyVerify: hostKeyVerifier,
      );

      // Authenticate WITHOUT a PTY. A rejected host key throws here; [signal]
      // distinguishes that from a generic auth/network failure.
      await service.connectExec();
      return MonitorExecResult.ok(service);
    } on NotSilentlyPollableException {
      await _teardownExecAttempt(service, jumpClients);
      return MonitorExecResult.needsCredentials();
    } catch (e) {
      await _teardownExecAttempt(service, jumpClients);
      return monitorExecFailure(e, hostKeyNeedsReview: signal.needsReview, hostKeyChanged: signal.changed);
    }
  }

  /// The jump route [connection]'s key is trusted under (the nearest jump
  /// host's saved host:port), null for a host dialled directly: so two
  /// different servers at the same host:port, reached through different jump
  /// hosts, keep SEPARATE trust records instead of colliding into a false
  /// "Host key changed". [resolved] is the host as the network the device is
  /// on has it, where that was read.
  Future<String?> _targetViaScope(Connection connection, ResolvedConnection? resolved) async {
    final baseChain = connection.connectViaId != null ? <String>[connection.connectViaId!] : const <String>[];
    final String? nearestHopId = resolved != null && !_sameJumpChain(resolved.jumpChain, baseChain)
        // jumpChain is ordered nearest-to-target FIRST (see _buildJumpChain),
        // so .first is the last-mile hop that actually dials the target - the
        // right thing to scope trust by (and it matches the legacy
        // connectViaId path). .last would be the outermost hop.
        ? (resolved.jumpChain.isNotEmpty ? resolved.jumpChain.first : null)
        : connection.connectViaId;
    if (nearestHopId == null) return null;
    final hop = await _readDb(connection.id).connectionsDao.getById(nearestHopId);
    return hop == null ? 'via:$nearestHopId' : '${normalizeKnownHost(hop.host)}:${hop.port}';
  }

  /// Tear down a failed [openExecClient] attempt. When [service] exists its
  /// own `disconnect()` closes the jump chain too; otherwise close any stray
  /// jump clients (normally already cleaned up by [_buildJumpChain]).
  Future<void> _teardownExecAttempt(
      SshService? service, List<SSHClient> jumpClients) async {
    if (service != null) {
      try {
        await service.disconnect();
      } catch (_) {/* best-effort */}
      return;
    }
    for (final c in jumpClients) {
      try {
        c.close();
      } catch (_) {/* best-effort */}
    }
  }

  // ── Broadcast input gating (Doc-3 Part C / C1) ──────────────────────
  //
  // Broadcast mode fans the FOCUSED session's keystrokes out to every other
  // terminal in the group LIVE, one character at a time. So by the time the
  // user presses Enter the target shells already have the whole command typed
  // at their prompt - only the newline actually EXECUTES it. The newline is
  // therefore the exact lever to gate: if the line it would run on a target
  // is destructive (and the existing dangerous-command protection is on), we
  // HOLD the newline's fan-out, confirm the blast radius by host NAME, and
  // only then send it. None of this ever touches the focused session's own
  // input - that was already written to its shell before we were called.

  /// Fan one chunk of focused-session input ([data] as this terminal sent
  /// it, [replay] what the person did) out to the targets, gating a
  /// destructive Enter (C1).
  ///
  /// Only ever invoked when broadcast is ENABLED - a no-op path otherwise.
  void _handleBroadcastInput(
    String focusedId,
    String data,
    TerminalTyped replay,
  ) {
    // A confirm dialog for this session is already open - hold everything
    // until it resolves. The modal barrier normally blocks further typing;
    // this is belt-and-suspenders.
    if (_broadcastConfirmPending.contains(focusedId)) return;

    if (_ref.read(dangerousCommandProtectionProvider)) {
      final risky = _riskyLineOf(focusedId, data);
      if (risky != null) {
        // HOLD this chunk's entire fan-out; confirm across every target by
        // name before releasing it.
        _confirmBroadcastThenFanOut(focusedId, risky.$1, risky.$2, replay);
        return;
      }
    }

    // No line is entered by this chunk (live typing / partial paste: the
    // targets get the keystrokes typed at their prompt but nothing executes
    // until a newline is entered), or none of them is destructive.
    _fanOutBroadcast(focusedId, replay);
  }

  /// The first destructive line that [data], typed into the targets of the
  /// focused session, would run on one of them, with why; null when there is
  /// none.
  ///
  /// A chunk enters one line or several: a typed Enter, or a multi-line paste
  /// (Terminal.paste collapses newlines to \r and delivers the whole blob as
  /// one chunk). Every line is looked at, so a multi-line paste cannot smuggle
  /// a shutdown past a benign first line.
  ///
  /// The first line it enters is the one already standing at each target's
  /// prompt, which is that TARGET's own ([_typedLines]: begun in another
  /// pane, or before the broadcast started, it is still the line that runs).
  /// Where the typing alone does not tell what it is (Tab completed it, an
  /// arrow recalled it from the shell's history, which is each host's own),
  /// the line the target's screen shows is looked at as well. That is the
  /// best there is: an echo still on its way is not on the screen yet.
  (String, List<DangerousCommandMatch>)? _riskyLineOf(String focusedId, String data) {
    // Nobody connected receives it: nothing runs anywhere else, and there
    // is nothing to ask about.
    final receivers = _receiversOf(focusedId).toList();
    if (receivers.isEmpty) return null;
    // The lines after the first are the same for every target.
    final entered = TypedLine().feed(data);
    if (entered.isEmpty) return null;
    final secrets = {
      ...?_filledSecrets[focusedId],
      for (final id in receivers) ...?_filledSecrets[id],
    };
    for (final targetId in receivers) {
      final line = (_typedLines[targetId] ?? TypedLine()).firstEntered(data)!;
      final typed = _riskyIn(line.text, secrets);
      if (typed != null) return typed;
      if (line.followed) continue;
      final terminal = _typingTerminal(targetId);
      // (A program that fills the screen has no command line on it.)
      if (terminal == null || terminal.isUsingAltBuffer) continue;
      final shown = _riskyIn(_cursorLineOf(terminal), secrets);
      if (shown != null) return shown;
    }
    for (final line in entered.skip(1)) {
      final typed = _riskyIn(line.text, secrets);
      if (typed != null) return typed;
    }
    return null;
  }

  /// [line], where the rules find something in it, as the question shows it: the
  /// masked values [secrets] out of sight, in the command and in what is said of it.
  (String, List<DangerousCommandMatch>)? _riskyIn(String line, Set<String> secrets) {
    final text = line.trim();
    final matches = DangerousCommandService.checkFilled(text);
    if (matches.isEmpty) return null;
    final shown = _withMasked(text, secrets);
    return (shown, DangerousCommandService.asShown(text, shown, matches));
  }

  /// [text] with [secrets] masked, the longest first: one form may hold another.
  String _withMasked(String text, Set<String> secrets) {
    var masked = text;
    for (final s in secrets.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      masked = masked.replaceAll(s, kMaskedValueShown);
    }
    return masked;
  }

  /// The whole line the cursor of [terminal] is on, wrapped rows joined.
  String _cursorLineOf(Terminal terminal) {
    try {
      final buf = terminal.buffer;
      return joinLogicalLine(
        buf.absoluteCursorY,
        (y) => buf.lines[y].toString(),
        (y) => buf.lines[y].isWrapped,
      );
    } catch (_) {
      return '';
    }
  }

  /// The sessions that get what is typed into [sessionId] besides itself
  /// (broadcast_provider.dart: the others of its tab on screen, unless it is
  /// left out; on a phone, the sessions picked), as things stand this
  /// moment. SECURITY (blast radius): this is asked at every keystroke and
  /// follows the tab, so a session that left its group gets nothing more
  /// and sends nothing more.
  Set<String> _broadcastPeers(String sessionId) {
    // (Read from the container: the tabs, and so who types together, follow
    // the sessions, and reading them through this provider's own ref would
    // make each depend on the other.)
    final read = _ref.container.read;
    final broadcast = read(broadcastModeProvider);
    // No tab broadcasts (nothing at all, or a phone's picked sessions): the
    // tabs, and the other windows, are not asked for. (A phone has neither.)
    // A session that is files only has no shell: nothing is typed into it.
    if (broadcast.tabs.isEmpty) {
      return {
        for (final id in broadcastPeers(broadcast, const WorkTabsState(), sessionId))
          if (!_filesOnly.contains(id)) id,
      };
    }
    return broadcastPeers(
      broadcast,
      read(workTabsProvider),
      sessionId,
      away: {...read(detachedSessionsProvider), ..._filesOnly},
    );
  }

  /// What the person typed into the session [sessionId] ([data], as this
  /// terminal sent it; [replay], what they did) goes to the terminals that
  /// type together with it. The fan-out of a destructive command's Enter is
  /// held for confirmation first (C1) - see [_handleBroadcastInput].
  /// The sessions that get what is typed into [focusedId] now: those of its
  /// peers ([_broadcastPeers]) that are connected and not hidden. What is
  /// typed, the question before a risky command and the hosts it names all
  /// go by them.
  Iterable<String> _receiversOf(String focusedId) sync* {
    for (final id in _broadcastPeers(focusedId)) {
      final s = state[id];
      if (s == null || s.isHidden || s.status != SessionStatus.connected) continue;
      yield id;
    }
  }

  void _broadcastTyped(String sessionId, String data, TerminalTyped replay) {
    if (_broadcastPeers(sessionId).isEmpty) return;
    _handleBroadcastInput(sessionId, data, replay);
  }

  /// What the person typed into a tmux pane of the session [sessionId]
  /// (tmux_session_host.dart hands it on): it is broadcast like anything
  /// typed into the session's own terminal.
  void typedInTmuxPane(String sessionId, String data, TerminalTyped typed) {
    _typedLines.putIfAbsent(sessionId, TypedLine.new).feed(data);
    _noteInput(sessionId);
    // (What a pane was sent by a broadcast goes no further.)
    if (_broadcastReceiving.contains(sessionId)) return;
    _broadcastTyped(sessionId, data, typed);
  }

  /// The tmux integrations there are, by session (each puts itself here:
  /// tmux_session_host.dart). While one is live its workspace has the
  /// keyboard, not the session's own terminal behind it.
  final _tmuxHosts = <String, TmuxSessionHost>{};

  void tmuxHostCreated(TmuxSessionHost host) => _tmuxHosts[host.sessionId] = host;

  void tmuxHostDisposed(TmuxSessionHost host) {
    if (identical(_tmuxHosts[host.sessionId], host)) _tmuxHosts.remove(host.sessionId);
  }

  /// The terminal that typing into the session [sessionId] goes to: the
  /// tmux pane in front while the session shows tmux (null while tmux has
  /// none), its own terminal otherwise. (On 2.2.1 a broadcast was written to
  /// the shell behind the tmux workspace, where nobody saw it run.)
  Terminal? _typingTerminal(String sessionId) {
    final host = _tmuxHosts[sessionId];
    if (host != null && host.live) return host.controller?.activeWindow?.activeTerminal;
    return state[sessionId]?.session?.terminal;
  }

  /// The sessions something is being typed into right now because it was
  /// typed into another one. Their own output handler reads it: what they
  /// are sent this way is typed there, and goes no further.
  final Set<String> _broadcastReceiving = {};

  /// Types [replay] into every CONNECTED terminal that types together with
  /// the focused session, each through its own terminal: that one sends it
  /// the way its program asked, and to where its typing goes (its shell, or
  /// the tmux pane in front while it shows tmux). Who receives is read anew,
  /// so a change made while a confirm dialog was open is respected.
  void _fanOutBroadcast(String focusedId, TerminalTyped replay) {
    final secrets = _filledSecrets[focusedId];
    for (final targetId in _receiversOf(focusedId)) {
      final target = _typingTerminal(targetId);
      if (target == null) continue;
      // (What was typed here stands at its prompt now as well.)
      if (secrets != null) _filledSecrets.putIfAbsent(targetId, () => <String>{}).addAll(secrets);
      final nested = !_broadcastReceiving.add(targetId);
      try {
        replay.typeInto(target);
      } finally {
        if (!nested) _broadcastReceiving.remove(targetId);
      }
    }
  }

  /// Something was typed into the session [sessionId] by a broadcast: its
  /// line is followed, so that what the person types there next is read
  /// right, but it is no command of this terminal's to record (history
  /// holds a command once, for the terminal it was typed into), and there
  /// is no suggestion for it.
  void _followReceived(String sessionId, Terminal terminal, String input) {
    // (One being looked up is not shown either: the line it was looked up
    // for is no longer the line.)
    terminal.ghostText = null;
    _cmdCaptures.putIfAbsent(sessionId, CommandCapture.new).onReceived(input);
  }

  /// Show the destructive-broadcast confirm dialog, then either fan the held
  /// Enter out (confirmed) or leave the other hosts un-executed (cancelled).
  ///
  /// The focused session is NOT involved - it already ran the command locally.
  Future<void> _confirmBroadcastThenFanOut(
    String focusedId,
    String command,
    List<DangerousCommandMatch> matches,
    TerminalTyped held,
  ) async {
    // Snapshot the target host NAMES so the dialog can show WHO this hits -
    // every connected session in the group except the focused one.
    final targetNames = <String>[];
    final targetIds = <String?>[];
    for (final id in _receiversOf(focusedId)) {
      final st = state[id]!;
      final label =
          st.connectionLabel.isNotEmpty ? st.connectionLabel : (st.host ?? id);
      targetNames.add(label);
      targetIds.add(st.connectionId);
    }

    _broadcastConfirmPending.add(focusedId);
    bool? proceed;
    try {
      proceed = await _ref.read(broadcastConfirmProvider)(command, matches, targetNames, targetIds);
    } finally {
      _broadcastConfirmPending.remove(focusedId);
    }

    if (!mounted) return;

    if (proceed == true) {
      // Confirmed → fan the held Enter out, executing the command on every
      // target still connected.
      _fanOutBroadcast(focusedId, held);
    } else {
      // Cancelled, or there was no window to ask in (FAIL CLOSED: a
      // destructive command is never multiplied across hosts without an
      // explicit confirmation) → do NOT broadcast the Enter. The targets are
      // left with the command TYPED but un-executed at their prompts; clear
      // it with Ctrl-U so a stray later keystroke can't detonate it. (With
      // nobody to ask the line used to be left standing there, and the next
      // Enter that was broadcast ran it.)
      _clearBroadcastTargetLines(focusedId);
    }
  }

  /// Send Ctrl-U (kill-line) to every connected broadcast target except the
  /// focused session - used on a cancelled destructive broadcast to wipe the
  /// dangerous command the live fan-out already typed at their prompts.
  void _clearBroadcastTargetLines(String focusedId) {
    // (Ctrl-U as text: it goes where the target's typing goes.)
    _fanOutBroadcast(focusedId, const TypedText('\x15'));
  }

  /// Build the localized "host is set to skip on {network}" message for the
  /// skip-host abort.
  ///
  /// Providers have no BuildContext of their own, so we reach AppLocalizations
  /// through the router's navigator context - the same pattern app.dart uses
  /// for deep-link dialogs. Falls back to English if no localized context is
  /// available yet (e.g. cold start), never throwing.
  String _skipHostMessage(String hostName, String networkName) {
    try {
      final ctx = _ref
          .read(routerProvider)
          .routerDelegate
          .navigatorKey
          .currentContext;
      if (ctx != null) {
        final l10n = AppLocalizations.of(ctx);
        if (l10n != null) {
          return l10n.connectHostSkippedOnNetwork(hostName, networkName);
        }
      }
    } catch (_) {
      // Any localization lookup failure → fall through to the English default.
    }
    return '$hostName is set to skip on the $networkName network.';
  }

  /// Walk the `connectViaId` chain from [target] backwards, dialing
  /// hops in order from the OUTERMOST (farthest from target) inward.
  ///
  /// Order is critical: if target A → B → C, we first dial C
  /// directly, authenticate, then dial B THROUGH C, authenticate,
  /// and finally forward-tcpip from B to A's `host:port`.  The
  /// returned socket is what the caller hands to [SshService] as
  /// `tunnelSocket`; the returned client list is the full set of
  /// intermediate clients (in close-order, nearest-first) so the
  /// caller can dispose them cleanly when the session ends.
  ///
  /// [targetHost] / [targetPort] override the endpoint the innermost hop
  /// tunnels to (the resolved address/port from a network override). When
  /// null they default to `target.host` / `target.port` - the legacy behavior.
  ///
  /// [override] carries an EXPLICIT, ordered (nearest-to-target first) list of
  /// jump-host connection ids coming from a network override, with the name
  /// of that network. When provided the list is dialed verbatim and is NOT
  /// expanded via each hop's own connectViaId - the override's list is taken
  /// to BE the complete chain. When null we fall back to the legacy recursive
  /// connectViaId walk.
  ///
  /// A chain that cannot be followed (a jump host that is no longer there,
  /// jump hosts that lead back to one already on the way) is a
  /// [JumpChainBroken], thrown before anything is dialled; what goes wrong at
  /// a jump host while it is dialled is a [JumpHostFailure].
  Future<_JumpChainResult> _buildJumpChain(
    Connection target,
    ChainHostKeyVerifyCallback hostKeyVerifier,
    ConnectionLogCallback? onLog, {
    String? targetHost,
    int? targetPort,
    ({List<String> chain, String network})? override,
    Future<SilentCreds> Function(Connection hop)? hopCredentialResolver,
    bool unattended = false,
    bool Function()? ended,
    SignInNoticeFor noticeFor = SignInNoticeFor.session,
  }) async {
    // A caller must never hand us an empty explicit chain - "no jump" is
    // expressed by not calling this method at all. Guarding here keeps the
    // `prevClient!` deref at the end of step 3 safe.
    assert(override == null || override.chain.isNotEmpty);
    String nameOf(Connection c) => c.label.isNotEmpty ? c.label : c.host;

    // 1. Resolve the linear chain target ← B ← C ← … (target first,
    //    outermost jump last).  Cycle detection bails out on a repeat.
    final connDao = _readDb(target.id).connectionsDao;
    final chain = <Connection>[target];
    final visited = <String>{target.id};

    if (override != null) {
      // EXPLICIT chain from a network override. Loaded verbatim in the given
      // order (nearest-to-target first, matching resolved.jumpChain). We do
      // NOT recurse into each hop's connectViaId - the override IS the chain.
      for (final hopId in override.chain) {
        final hop = await connDao.getById(hopId);
        if (hop == null) {
          throw JumpChainBroken(gl10n.jumpHostGoneInNetwork(nameOf(target), override.network));
        }
        if (!visited.add(hopId)) {
          throw JumpChainBroken(gl10n.jumpHostCircleInNetwork(nameOf(target), nameOf(hop), override.network));
        }
        chain.add(hop);
      }
    } else {
      // LEGACY recursive model: follow each hop's own connectViaId until a
      // hop has none.  Cycle detection bails out on a repeat.
      var cursor = target;
      while (cursor.connectViaId != null) {
        final next = await connDao.getById(cursor.connectViaId!);
        if (next == null) {
          // Broken chain (jump host deleted).  Fail loudly so the user
          // can fix the misconfiguration rather than silently falling
          // through to a direct connection that might bypass the
          // intended hop.
          throw JumpChainBroken(gl10n.jumpHostGoneDirect(nameOf(cursor)));
        }
        if (!visited.add(next.id)) {
          throw JumpChainBroken(gl10n.jumpHostCircle(nameOf(target), nameOf(next)));
        }
        chain.add(next);
        cursor = next;
      }
    }

    // A remote screen or an FTPS host is never a hop (found in a 4.0
    // security review): it would be dialled as an SSH server at its
    // address, offered its own key's password, through its carrier.
    for (final hop in chain.skip(1)) {
      if (ConnectionProtocol.kindClassOf(hop.protocol) != ConnectionProtocol.kindClassShell) {
        throw JumpChainBroken(gl10n.jumpHostNotSsh(nameOf(hop), nameOf(target)));
      }
    }

    // Session moderation (3.0): a host in a watched Crate is never
    // a hop. What goes through a hop is a tunnel, which nobody could watch.
    final chainDb = _readDb(target.id);
    for (final hop in chain.skip(1)) {
      if (await hostIsWatchedIn(chainDb, hop.id)) {
        throw OrchardAccessRefused(gl10n.watchedHostNoJump(hop.label.isNotEmpty ? hop.label : hop.host));
      }
      // Nor is a host, or a key, of a Crate that its own offline limit has
      // closed on this device: asked before anything is dialled, whoever
      // gives the hops their credentials.
      await requireCratesOpenIn(chainDb, hostId: hop.id, keyId: hop.identityId);
    }

    // 2. Dial from the OUTERMOST jump inward.  The last entry in
    //    `chain` is the outermost; reversing gives dial order.
    //    On each hop we tunnel through the previous client.
    //
    // [hopCredentialResolver] lets a headless caller (the agentless monitor
    // poller) supply a NON-INTERACTIVE credential loader per hop; when null
    // (the interactive default) we use `_resolveIdentity`, which may prompt.
    // The dial loop + first tunnel are wrapped so that if ANY hop fails
    // (missing creds, auth timeout, unreachable), the jump clients dialed so
    // far are torn down instead of leaking.
    SSHClient? prevClient;
    final clientsByOrder = <SSHClient>[]; // dial order
    final labelsByOrder = <String>[]; // what each of them is called
    final SSHSocket tunnelSocket;

    /// What went wrong at the jump host [at] while [stage] was being done,
    /// as a failure of that jump host ([jumpHostFailureOf]), with a line of
    /// it in the connection's log.
    Object atJumpHost(Connection at, JumpStage stage, Object error, {String? username, Connection? onward}) {
      final failure = jumpHostFailureOf(
        error,
        label: nameOf(at),
        host: at.host,
        port: at.port,
        username: username,
        stage: stage,
        onward: onward == null ? null : nameOf(onward),
      );
      if (failure is JumpHostFailure) {
        onLog?.call('jump: ${failure.label} failed (${stage.name}) - ${asLogLine('$error')}');
      }
      return failure;
    }

    try {
      for (var i = chain.length - 1; i >= 1; i--) {
        final hop = chain[i];
        onLog?.call(
            'jump: Connecting to ${hop.label} (${hop.host}:${hop.port})');
        // Jump hops never run on a worker isolate, so they only need the three
        // core credential fields. Coerce _resolveIdentity's richer record down
        // to SilentCreds so both branches share one type.
        final SilentCreds hopCreds;
        // The password saved with the hop's key, fetched only where the hop
        // does not take the key (3.0, accounts per host); a headless chain
        // has its credentials as they are.
        Future<String?> Function()? hopPasswordAfterKey;
        try {
          if (hopCredentialResolver != null) {
            hopCreds = await hopCredentialResolver(hop);
          } else {
            final r = await _resolveIdentity(hop, onLog: onLog, unattended: unattended, ended: ended);
            hopCreds =
                (username: r.username, password: r.password, keyPairs: r.keyPairs);
            hopPasswordAfterKey = r.passwordAfterKey;
          }
        } catch (e) {
          throw atJumpHost(hop, JumpStage.details, e);
        }

        final SSHSocket socket;
        if (prevClient == null) {
          // First (outermost) hop: direct TCP.
          try {
            socket = await openSshSocket(hop.host, hop.port, _connectTimeout);
          } catch (e) {
            throw atJumpHost(hop, JumpStage.reach, e, username: hopCreds.username);
          }
        } else {
          // Subsequent hops: tunnel through the previous client. Where that
          // fails, it is the jump host before this one that did not open
          // the way to it.
          try {
            socket = await prevClient.forwardLocal(hop.host, hop.port);
          } catch (e) {
            throw atJumpHost(chain[i + 1], JumpStage.onward, e, onward: hop);
          }
        }

        // Keyboard-interactive through the shared answerer. A hop the person
        // is connecting through can ask them (a 2FA code on a bastion); the
        // monitor's headless chain has nobody to ask and fails closed.
        final hopDeadline = AuthDeadline();
        final hopQuestionsWithdrawn = Completer<void>();
        final hopAsk = hopCredentialResolver == null
            ? _serverQuestions(
                unattended: unattended,
                host: hop.host,
                port: hop.port,
                username: hopCreds.username,
                ended: _askedFor(hop.id, ended),
              )
            : null;
        final laterAtHop = hopPasswordAfterKey;
        final hopAnswerer = KeyboardInteractiveAnswerer(
          password: hopCreds.password,
          passwordAfterKey: laterAtHop == null ? null : () => hopDeadline.whileAsking(laterAtHop),
          ask: hopAsk == null
              ? null
              : (question) =>
                  hopDeadline.whileAsking(() => hopAsk(question)),
          withdrawn: hopQuestionsWithdrawn.future,
          onServerActive: () => hopDeadline.relax(kServerQuestionPatience),
          onLog: onLog,
        );
        // A login banner with a link the hop's sign-in waits on (Tailscale
        // SSH's check on a jump host) goes to the person, naming the jump
        // host and where it leads, as a session's own does; a chain with
        // nobody there (a run nobody watches, the monitor's) gets no more
        // time.
        final hopLinks = SignInLinkBanners(
          hopCredentialResolver == null && !unattended
              ? signInNoticeShower(
                  _ref,
                  host: hop.host,
                  port: hop.port,
                  username: hopCreds.username,
                  jumpHost: nameOf(hop),
                  onward: nameOf(target),
                  purpose: noticeFor,
                )
              : null,
          deadline: hopDeadline,
          withdrawn: hopQuestionsWithdrawn.future,
          onLog: onLog,
        );

        final hopClient = SSHClient(
          socket,
          username: hopCreds.username,
          identities: signingOffTheClock(hopCreds.keyPairs, hopDeadline),
          // Honor the TARGET's compatibility setting for every hop in
          // the chain - if the final destination needs CBC, any
          // intermediate hop that's also legacy will negotiate fine
          // because compat mode keeps modern algorithms first.
          algorithms: SshService.buildAlgorithms(
            compatibility: target.compatibilityMode || hop.compatibilityMode,
          ),
          onPasswordRequest: hopCreds.password != null
              ? () => hopCreds.password!
              : laterAtHop != null
                  ? () => sendPasswordAfterKey(hopAnswerer, onLog)
                  : null,
          // Only a genuine, non-echoed password prompt gets the password
          // (isRealPasswordPrompt, once); a 2FA code comes from the person.
          // This path used to answer a "passcode" prompt with the password.
          onUserInfoRequest: hopAnswerer.handler,
          onUserauthBanner: (message) {
            onLog?.call('jump: ${hop.label} sent a login banner');
            hopLinks.banner(message);
          },
          onVerifyHostKey: (String type, Uint8List fingerprint) async {
            final sshHostKey = SSHHostKey(type: type, bytes: fingerprint);
            // (The clock stops while its person is asked about this key,
            // as in SshService for the host itself.) The jump host is named:
            // its own Crate's team pin is the one that counts for it.
            return hopDeadline.whileAsking(() => hostKeyVerifier(hop.host, hop.port, sshHostKey, hostId: hop.id));
          },
        );
        try {
          await hopDeadline.wait(hopLinks.orCancelled(hopClient.authenticated));
        } catch (e) {
          hopClient.close();
          if (hopAnswerer.cancelled || hopLinks.cancelled) throw const SshPromptCancelled();
          // What stopped the password saved with its key from going is what
          // the jump host's sign-in is said as (an Orchard's rule, or its
          // person cancelling), as where its sign-in details were read; and
          // so is a question that a run with nobody there could not answer.
          final stopped = hopAnswerer.stoppedBy;
          if (stopped != null) throw atJumpHost(hop, JumpStage.details, stopped);
          throw atJumpHost(hop, JumpStage.signIn, e, username: hopCreds.username);
        } finally {
          if (!hopQuestionsWithdrawn.isCompleted) {
            hopQuestionsWithdrawn.complete();
          }
        }
        onLog?.call('jump: Authenticated to ${hop.label}');
        clientsByOrder.add(hopClient);
        labelsByOrder.add(nameOf(hop));
        prevClient = hopClient;
      }

      // 3. The NEAREST jump host (chain[1]) forwards to the actual
      //    target's host:port.  `prevClient` is guaranteed non-null
      //    here because chain.length >= 2 (target + ≥1 jump).
      //    The endpoint is the EFFECTIVE address/port (resolved network
      //    override when present; otherwise the base host/port, so the legacy
      //    path is byte-identical).
      final tunnelHost = targetHost ?? target.host;
      final tunnelPort = targetPort ?? target.port;
      onLog?.call('jump: Opening tunnel to $tunnelHost:$tunnelPort');
      try {
        tunnelSocket = await prevClient!.forwardLocal(tunnelHost, tunnelPort);
      } catch (e) {
        // The jump host nearest the host did not open the way to it.
        throw atJumpHost(chain[1], JumpStage.onward, e, onward: target);
      }
      onLog?.call('jump: Tunnel established');
    } catch (e) {
      // Before anything is closed here: a jump host that had been signed in
      // to and whose connection has ended by itself since. That is what
      // went wrong then, whatever the next one on the way failed with: it
      // saw its line close, and was said to have failed itself.
      final ended = failedOverEarlierJumpHosts(e)
          ? await _jumpHostEndedWhileDialling(clientsByOrder, labelsByOrder, e)
          : null;
      // Tear down any hops already dialed so a mid-chain failure doesn't leak
      // live SSH transports (nearest-first, matching disconnect order).
      for (final c in clientsByOrder.reversed) {
        try {
          c.close();
        } catch (_) {/* already-closed clients throw during cleanup */}
      }
      if (ended != null) {
        onLog?.call(jumpHostEndLogLine(ended.label, ended.cause));
        throw ended;
      }
      rethrow;
    }

    // 4. Return clients in CLOSE order - nearest-first.  Dial order
    //    was outermost-first, so we reverse.
    return _JumpChainResult(
      targetSocket: tunnelSocket,
      clients: clientsByOrder.reversed.toList(growable: false),
      labels: labelsByOrder.reversed.toList(growable: false),
    );
  }
}

/// Result of walking the `connectViaId` chain.
class _JumpChainResult {
  _JumpChainResult({required this.targetSocket, required this.clients, required this.labels});
  final SSHSocket targetSocket;
  final List<SSHClient> clients;

  /// What each of [clients]' jump hosts is called, in the same order: for
  /// a session to say which of them it was whose connection ended.
  final List<String> labels;
}

/// Element-for-element equality for two ordered jump-host id lists. Used to
/// decide whether a network override actually CHANGED the jump routing versus
/// merely echoing the base config - the latter must stay on the legacy
/// recursive path so multi-hop base chains remain byte-identical.
bool _sameJumpChain(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ── Data reception tracking (for UI pulse animation) ─────────────

/// Tracks the last stdout data timestamp per session.
///
/// Incremented each time stdout data arrives from the server.
/// The terminal screen uses this to drive a pulse animation on the
/// connection status dot when the session is actively receiving data.
final sessionDataActivityProvider =
    StateProvider.family<int, String>((ref, sessionId) => 0);

/// Cumulative count of bytes RECEIVED from the server (stdout) for a session.
///
/// This is an honest app-layer counter: the SSH transport doesn't expose a
/// bidirectional byte total, so this reflects received shell output only -
/// never present it as a full "bytes transferred" figure. The desktop
/// session-details panel reads it for its "Data received" row.
final sessionBytesReceivedProvider =
    StateProvider.family<int, String>((ref, sessionId) => 0);

// ── Convenience provider for a specific session ──────────────────

/// Get the current session state by session ID.
final sessionStateProvider =
    Provider.family<SessionState?, String>((ref, sessionId) {
  final sessions = ref.watch(activeSessionsProvider);
  return sessions[sessionId];
});

/// How long a folder's listing for path completion is used again.
const kCompletionListingKeptFor = Duration(seconds: 20);

/// Keeps [names], the listing of the folder [key] names, in [listings] as of
/// [now], and drops every listing there older than
/// [kCompletionListingKeptFor]: none is used past that. They were dropped
/// only when their session closed, one of up to 20,000 names for every folder
/// a session ever completed in (found in a code audit).
void keepCompletionListing(Map<String, ({DateTime at, List<(String, bool)> names})> listings, String key,
    List<(String, bool)> names, DateTime now) {
  listings.removeWhere((_, v) => now.difference(v.at) >= kCompletionListingKeptFor);
  listings[key] = (at: now, names: names);
}
