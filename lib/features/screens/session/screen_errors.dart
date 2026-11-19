// How a remote screen that did not open, or stopped, is said (4.0):
// each kind with its words and, where the person can do something about it,
// its code (ZS-1801 to ZS-1811, docs/ERROR-CODES.md). What the engine or the
// SSH host said in English goes to the connection log and Copy details; no
// password is ever in it.
import 'package:zest_native/screen.dart' show ScreenCloseReason, ScreenClosed, ScreenSession;
import 'package:zest_ssh_core/dartssh2.dart' show SSHChannelOpenError;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/type_name.dart';

/// How long a screen's server has, once its connection is open, to finish
/// connecting: one that takes the connection and then says nothing is closed
/// then (ZS-1828), not waited on for ever.
const kScreenHandshakeTimeout = Duration(seconds: 60);

enum ScreenFailureKind {
  /// Nothing listens at the screen's address on the carrier (ZS-1801).
  nothingAnswers,

  /// The carrier's SSH server does not allow the screen's channel (ZS-1802).
  forwardingRefused,

  /// The VNC server refused the password (ZS-1803).
  passwordRefused,

  /// The VNC server offers no security this app takes, or TLS or the protocol
  /// failed (ZS-1804).
  noSecurity,

  /// The certificate is not the one trusted, after the question (ZS-1805).
  certificateChanged,

  /// No socket at the path on the carrier (ZS-1806).
  socketMissing,

  /// The VNC server ended the session (no code: nothing is wrong).
  serverEnded,

  /// The carrier is not in the screen's space any more, or is no SSH host
  /// (ZS-1808). Never read as a screen reached directly: its address is as
  /// the carrier saw it.
  carrierGone,

  /// An X program's host has no Xvnc or no xauth (ZS-1809, 4.0):
  /// [ScreenFailure.hint] is the install command for its package manager,
  /// where it has one the app knows.
  xProgramToolsMissing,

  /// An X program's private X server did not start on its host (ZS-1810):
  /// no temporary folder, Xvnc stopped, no answer from the host script, a
  /// login shell that is not a Unix one.
  xProgramFailed,

  /// An X program ended as it started (ZS-1811), with
  /// [ScreenFailure.exitStatus] (127: not found on the host);
  /// [ScreenFailure.hint] is the program's name.
  xProgramEnded,

  /// RDP: the server did not take the user name and password (ZS-1812).
  rdpSignInRefused,

  /// RDP: the server has no Network Level Authentication and the host asks
  /// for it (ZS-1813).
  rdpNlaMissing,

  /// RDP: the server signs in with Network Level Authentication only and
  /// the host says without (ZS-1814).
  rdpNlaRequired,

  /// RDP: the server says the account is locked out (ZS-1815).
  rdpAccountLocked,

  /// RDP: the server says the account is turned off (ZS-1816).
  rdpAccountDisabled,

  /// RDP: the server says the password has expired or must be changed
  /// first (ZS-1817).
  rdpPasswordExpired,

  /// RDP: the account may not sign in over Remote Desktop, said at the
  /// sign-in or as the server ended the session (ZS-1818).
  rdpAccountNotAllowed,

  /// RDP: the same account signed in elsewhere and took the session
  /// (ZS-1819).
  rdpTakenOver,

  /// RDP: the server's licensing refused the session (ZS-1820).
  rdpLicence,

  /// The team's rule lets its remote screens open through an SSH host only,
  /// and this one connects directly (ZS-1821). Nothing was dialled.
  teamSshOnly,

  /// RDP: the server ended the session (no code: nothing is wrong on this
  /// side); [ScreenFailure.hint] is the engine's name for why, where the
  /// server said (idle, signed_out, shutdown and the others of the engine's
  /// SERVER_ENDINGS).
  rdpEnded,

  /// A Proxmox guest's console did not open (4.0): [ScreenFailure.hint]
  /// is why (a [ProxmoxConsoleFailure]'s name, or `noAccount`: the account
  /// is not on this device). No code: each says what to do.
  proxmoxConsole,

  /// RDP: an RD Gateway did not let the session through (4.0), or
  /// the host goes through one this version does not open:
  /// [ScreenFailure.hint] is the engine's name for why (`gateway_sign_in`,
  /// `gateway_not_allowed`, `gateway_target`, `gateway_sign_in_kind`,
  /// `gateway_consent`, `gateway_old`, `gateway_reauth`, `gateway_none`,
  /// `gateway_refused`) or the app's (`gateway_unavailable`). ZS-1822 to
  /// ZS-1827 by it.
  rdpGateway,

  /// The screen's server took the connection and did not finish connecting
  /// in time (ZS-1828): it said nothing more, or stopped half way.
  handshakeTimeout,

  /// Anything else ([ScreenCloseReason.internal]).
  stopped,
}

/// A remote screen that did not open, or stopped: [kind], and what was said
/// of it in English ([detail], for the log and Copy details).
class ScreenFailure implements Exception, HasTypeName {
  const ScreenFailure(this.kind, this.detail,
      {this.carrier, this.address, this.hint, this.exitStatus, this.rdp = false});

  final ScreenFailureKind kind;
  final String detail;

  /// The carrier's name and the screen's address on it, where they are part
  /// of what is said.
  final String? carrier;
  final String? address;

  /// For an X program: the install command ([ScreenFailureKind.xProgramToolsMissing]),
  /// or the program's name ([ScreenFailureKind.xProgramEnded]). For an RDP
  /// session its server ended ([ScreenFailureKind.rdpEnded]): the engine's
  /// name for why.
  final String? hint;

  /// How an X program that ended as it started ended.
  final int? exitStatus;

  /// The screen is an RDP host's: what is said of it names RDP where the
  /// sentence names the kind of server ("the RDP server is not running
  /// there").
  final bool rdp;

  /// This failure as an RDP host's.
  ScreenFailure asRdp() => rdp
      ? this
      : ScreenFailure(kind, detail, carrier: carrier, address: address, hint: hint, exitStatus: exitStatus, rdp: true);

  /// The code the person can look up, or null.
  ErrorCode? get code => switch (kind) {
    ScreenFailureKind.nothingAnswers => ErrorCodes.screenNothingAnswers,
    ScreenFailureKind.forwardingRefused => ErrorCodes.screenForwardingRefused,
    ScreenFailureKind.passwordRefused => ErrorCodes.screenPasswordRefused,
    ScreenFailureKind.noSecurity => ErrorCodes.screenNoSecurity,
    ScreenFailureKind.certificateChanged => ErrorCodes.screenCertificateChanged,
    ScreenFailureKind.socketMissing => ErrorCodes.screenSocketMissing,
    ScreenFailureKind.carrierGone => ErrorCodes.screenCarrierGone,
    ScreenFailureKind.xProgramToolsMissing => ErrorCodes.xProgramToolsMissing,
    ScreenFailureKind.xProgramFailed => ErrorCodes.xProgramFailed,
    ScreenFailureKind.xProgramEnded => ErrorCodes.xProgramEnded,
    ScreenFailureKind.rdpSignInRefused => ErrorCodes.screenRdpSignInRefused,
    ScreenFailureKind.rdpNlaMissing => ErrorCodes.screenRdpNlaMissing,
    ScreenFailureKind.rdpNlaRequired => ErrorCodes.screenRdpNlaRequired,
    ScreenFailureKind.rdpAccountLocked => ErrorCodes.screenRdpAccountLocked,
    ScreenFailureKind.rdpAccountDisabled => ErrorCodes.screenRdpAccountDisabled,
    ScreenFailureKind.rdpPasswordExpired => ErrorCodes.screenRdpPasswordExpired,
    ScreenFailureKind.rdpAccountNotAllowed => ErrorCodes.screenRdpAccountNotAllowed,
    ScreenFailureKind.rdpTakenOver => ErrorCodes.screenRdpTakenOver,
    ScreenFailureKind.rdpLicence => ErrorCodes.screenRdpLicence,
    ScreenFailureKind.teamSshOnly => ErrorCodes.screenTeamSshOnly,
    ScreenFailureKind.rdpGateway => switch (hint) {
        'gateway_sign_in' => ErrorCodes.screenGatewaySignIn,
        'gateway_not_allowed' => ErrorCodes.screenGatewayNotAllowed,
        'gateway_target' => ErrorCodes.screenGatewayTarget,
        'gateway_sign_in_kind' || 'gateway_consent' || 'gateway_old' || 'gateway_reauth' => ErrorCodes.screenGatewayUnsupported,
        'gateway_unavailable' => ErrorCodes.screenGatewayUnavailable,
        _ => ErrorCodes.screenGatewayRefused,
      },
    ScreenFailureKind.handshakeTimeout => ErrorCodes.screenHandshakeTimeout,
    _ => null,
  };

  /// Whether connecting again by itself cannot help: the person, or a change
  /// on a server, is needed first. (A screen that is not there yet may be
  /// starting: those are tried again.)
  bool get reconnectCannotHelp => switch (kind) {
    ScreenFailureKind.passwordRefused ||
    ScreenFailureKind.noSecurity ||
    ScreenFailureKind.certificateChanged ||
    ScreenFailureKind.forwardingRefused ||
    ScreenFailureKind.carrierGone ||
    ScreenFailureKind.xProgramToolsMissing ||
    ScreenFailureKind.xProgramFailed ||
    ScreenFailureKind.xProgramEnded ||
    ScreenFailureKind.rdpSignInRefused ||
    ScreenFailureKind.rdpNlaMissing ||
    ScreenFailureKind.rdpNlaRequired ||
    ScreenFailureKind.rdpAccountLocked ||
    ScreenFailureKind.rdpAccountDisabled ||
    ScreenFailureKind.rdpPasswordExpired ||
    ScreenFailureKind.rdpAccountNotAllowed ||
    // Never by itself: the two devices would take the session from each other.
    ScreenFailureKind.rdpTakenOver ||
    ScreenFailureKind.rdpLicence ||
    ScreenFailureKind.teamSshOnly ||
    // A console's: its account, token, rights or guest need a person first.
    ScreenFailureKind.proxmoxConsole ||
    ScreenFailureKind.rdpEnded ||
    ScreenFailureKind.serverEnded => true,
    // A gateway's refusal needs its account, its policies or this version
    // changed; only a PC it could not reach may be starting.
    ScreenFailureKind.rdpGateway => hint != 'gateway_target',
    _ => false,
  };

  /// The channel to the screen that [error] refused: SSH's channel open
  /// failure codes (RFC 4254 5.1) as what they mean for a screen.
  static ScreenFailure ofChannel(SSHChannelOpenError error, {required bool unix, String? carrier, String? address}) {
    final kind = switch (error.code) {
      1 || 3 => ScreenFailureKind.forwardingRefused,
      2 => unix ? ScreenFailureKind.socketMissing : ScreenFailureKind.nothingAnswers,
      _ => ScreenFailureKind.stopped,
    };
    return ScreenFailure(kind, 'the SSH host refused the channel (${error.code}: ${error.description})',
        carrier: carrier, address: address);
  }

  /// A session that ended with [closed] (before it connected, or after); for
  /// an RDP host ([rdp]) in RDP's own kinds, by the name the engine gives
  /// what happened ([ScreenClosed.detail]): its sign-in refused, and why
  /// where the server said; the two ways a host's NLA setting does not fit
  /// its server; and a session the server ended, with its reason. What VNC
  /// calls "no security this app accepts" has no RDP twin: any other
  /// protocol or TLS failure of an RDP host is said as it came. A name this
  /// app does not know (a newer engine's) is the plain kind.
  static ScreenFailure ofClosed(ScreenClosed closed, {bool rdp = false}) {
    // An RD Gateway's own refusals (its certificate is a certificate's).
    final gateway = rdp && closed.reason != ScreenCloseReason.certificate && (closed.detail?.startsWith('gateway_') ?? false);
    final kind = closed.detail == ScreenSession.handshakeTimedOut
        ? ScreenFailureKind.handshakeTimeout
        : gateway
        ? ScreenFailureKind.rdpGateway
        : switch (closed.reason) {
      ScreenCloseReason.auth when rdp => switch (closed.detail) {
          'account_locked' => ScreenFailureKind.rdpAccountLocked,
          'account_disabled' => ScreenFailureKind.rdpAccountDisabled,
          'password_expired' => ScreenFailureKind.rdpPasswordExpired,
          'account_restricted' => ScreenFailureKind.rdpAccountNotAllowed,
          _ => ScreenFailureKind.rdpSignInRefused,
        },
      ScreenCloseReason.auth => ScreenFailureKind.passwordRefused,
      ScreenCloseReason.serverClosed when rdp => switch (closed.detail) {
          'replaced' => ScreenFailureKind.rdpTakenOver,
          'licence' => ScreenFailureKind.rdpLicence,
          'not_allowed' => ScreenFailureKind.rdpAccountNotAllowed,
          _ => ScreenFailureKind.rdpEnded,
        },
      ScreenCloseReason.certificate => ScreenFailureKind.certificateChanged,
      ScreenCloseReason.tls || ScreenCloseReason.protocol when rdp => switch (closed.detail) {
          'nla_missing' => ScreenFailureKind.rdpNlaMissing,
          'nla_required' => ScreenFailureKind.rdpNlaRequired,
          _ => ScreenFailureKind.stopped,
        },
      ScreenCloseReason.tls || ScreenCloseReason.protocol => ScreenFailureKind.noSecurity,
      ScreenCloseReason.serverClosed => ScreenFailureKind.serverEnded,
      _ => ScreenFailureKind.stopped,
    };
    final sha = closed.sha256;
    return ScreenFailure(kind, '${closed.reason.name}: ${closed.message}${sha == null ? '' : ' (sha256 $sha)'}',
        hint: kind == ScreenFailureKind.rdpEnded || gateway ? closed.detail : null, rdp: rdp);
  }

  @override
  String get typeName => 'ScreenFailure';

  @override
  String toString() => 'ScreenFailure(${kind.name}: $detail)';
}

/// What is said of [e] where a connection's failure is said, with its code.
String screenFailureText(AppLocalizations l10n, ScreenFailure e) {
  final carrier = e.carrier ?? '';
  final text = switch (e.kind) {
    ScreenFailureKind.nothingAnswers => e.rdp
        ? l10n.screenRdpNothingAnswers(e.address ?? '', carrier)
        : l10n.screenNothingAnswers(e.address ?? '', carrier),
    ScreenFailureKind.forwardingRefused => l10n.screenForwardingRefused(carrier),
    ScreenFailureKind.passwordRefused => l10n.screenPasswordRefused,
    ScreenFailureKind.noSecurity => l10n.screenNoSecurity,
    ScreenFailureKind.certificateChanged => l10n.screenCertificateNotTrusted,
    ScreenFailureKind.socketMissing => l10n.screenSocketMissing(e.address ?? '', carrier),
    ScreenFailureKind.serverEnded => l10n.screenServerEnded,
    ScreenFailureKind.carrierGone => l10n.screenCarrierGone,
    ScreenFailureKind.xProgramToolsMissing => switch (e.hint) {
        final String install => l10n.xProgramToolsMissing(carrier, install),
        null => l10n.xProgramToolsMissingNoInstaller(carrier),
      },
    ScreenFailureKind.xProgramFailed => l10n.xProgramFailed(carrier, e.detail),
    ScreenFailureKind.xProgramEnded => e.exitStatus == 127
        ? l10n.xProgramNotFound(e.hint ?? '', carrier)
        : l10n.xProgramEndedAtOnce(e.hint ?? '', '${e.exitStatus ?? ''}'),
    ScreenFailureKind.rdpSignInRefused => l10n.screenRdpSignInRefused,
    // The switch by the name the host's editor gives it, in this language.
    ScreenFailureKind.rdpNlaMissing => l10n.screenRdpNlaMissing(l10n.connectionEditRdpWithoutNla),
    ScreenFailureKind.rdpNlaRequired => l10n.screenRdpNlaRequired(l10n.connectionEditRdpWithoutNla),
    ScreenFailureKind.rdpAccountLocked => l10n.screenRdpAccountLocked,
    ScreenFailureKind.rdpAccountDisabled => l10n.screenRdpAccountDisabled,
    ScreenFailureKind.rdpPasswordExpired => l10n.screenRdpPasswordExpired,
    ScreenFailureKind.rdpAccountNotAllowed => l10n.screenRdpAccountNotAllowed,
    ScreenFailureKind.rdpTakenOver => l10n.screenRdpTakenOver,
    ScreenFailureKind.rdpLicence => l10n.screenRdpLicence,
    // The field by the name the host's editor gives it, in this language.
    ScreenFailureKind.teamSshOnly => l10n.screenTeamSshOnly(l10n.connectionEditScreenVia),
    ScreenFailureKind.rdpEnded => switch (e.hint) {
        'idle' => l10n.screenRdpEndedIdle,
        'logon_timeout' => l10n.screenRdpEndedLogonTimeout,
        'denied' => l10n.screenRdpEndedDenied,
        'fresh_credentials' => l10n.screenRdpEndedFreshCredentials,
        'admin_disconnected' || 'admin_signed_out' => l10n.screenRdpEndedByAdmin,
        'signed_out' => l10n.screenRdpEndedSignedOut,
        'disconnected' => l10n.screenRdpEndedDisconnected,
        'shutdown' || 'restart' => l10n.screenRdpEndedShutdown,
        _ => l10n.screenRdpServerEnded,
      },
    ScreenFailureKind.proxmoxConsole => switch (e.hint) {
        'noAccount' => l10n.proxmoxConsoleNoAccount,
        'signIn' => l10n.proxmoxConsoleSignIn,
        'permission' => l10n.proxmoxConsolePermission,
        'notFound' => l10n.proxmoxConsoleNotFound,
        'certificate' => l10n.proxmoxConsoleCertificate,
        'offline' || 'timeout' => l10n.proxmoxConsoleOffline,
        _ => l10n.proxmoxConsoleUnexpected,
      },
    // The host's field by the name its editor gives it, in this language.
    ScreenFailureKind.rdpGateway => switch (e.hint) {
        'gateway_sign_in' => l10n.screenGatewaySignInRefused(l10n.connectionEditScreenVia),
        'gateway_not_allowed' => l10n.screenGatewayNotAllowed,
        'gateway_target' => l10n.screenGatewayTarget,
        'gateway_sign_in_kind' || 'gateway_consent' || 'gateway_old' || 'gateway_reauth' => l10n.screenGatewayUnsupported,
        'gateway_unavailable' => l10n.screenGatewayUnavailable,
        _ => l10n.screenGatewayRefused,
      },
    ScreenFailureKind.handshakeTimeout =>
      l10n.screenHandshakeTimeout(kScreenHandshakeTimeout.inSeconds),
    ScreenFailureKind.stopped => l10n.screenStopped(e.detail),
  };
  final code = e.code;
  return code == null ? text : ErrorCodes.withCode(text, code);
}
