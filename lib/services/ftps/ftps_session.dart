// An FTPS host's session (3.4): its connection, held where an SSH session holds its shell, so
// the session list, its tab, Close and Reconnect treat it as any files-only session. It has no
// terminal: the file browser opens on it ([FtpsPaneFileSource]).
import 'dart:async';
import 'dart:typed_data';

import 'package:zest_native/ftps.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// How a certificate no authority vouches for is put to the person: [previous] is the
/// fingerprint kept before (a changed certificate) with when it was trusted, or null (a first
/// one). [teamPin]: what a team's pin adds to it (3.4), as to an SSH host key's question: the
/// team pinned another certificate ([TeamPinPrompt.pinned]), or the person may pin this one for
/// everyone in the host's Crate ([TeamPinPrompt.forEveryone], their choice). True: trust it.
typedef FtpsCertificateQuestion = Future<bool> Function({
  required String host,
  required int port,
  required FtpsCertificate certificate,
  String? previous,
  DateTime? previousTrustedAt,
  TeamPinPrompt? teamPin,
});

/// An FTPS host of a team (3.4): its team's pins ([TeamHostKeys], an Orchard's database) and
/// the host, whose Crate's pins are the ones that count for it.
class FtpsTeamPins {
  const FtpsTeamPins(this.pins, {required this.hostId});

  final TeamHostKeys pins;
  final String hostId;

  /// The certificate the team pinned for [host]:[port] in the host's Crate, or null. A pin of
  /// an SSH host key at that address is no certificate's (one port speaks one protocol).
  Future<TeamHostKeyPin?> certificatePin(String host, int port) async {
    final pin = await pins.pinFor(host, port, crateId: await pins.crateOfHost(hostId));
    return pin != null && pin.isCertificate && pin.certificateSha256 != null ? pin : null;
  }
}

/// [FtpsTrust] over the known hosts: a certificate kept like an SSH host key
/// ([KnownHostsService.trustCertificate]), and the question asked like one (the host key queue
/// and its dialogs). A no is said as a host key not accepted, so a session ends as quietly as
/// when an SSH host key is turned down.
///
/// A team's host ([team], 3.4) goes by its team's pin as an SSH host does: a certificate the
/// team pinned in the host's Crate is the one trusted, on every member's device, with no
/// question; another one (that no public authority vouches for) stops the connection unless
/// this account may edit the pin's Crate, and then the question is the team's, and a yes
/// replaces the pin for everyone. With no pin, someone who may edit the host's Crate is offered
/// to pin the certificate for everyone as they trust it.
class KnownHostsFtpsTrust implements FtpsTrust {
  KnownHostsFtpsTrust(this.knownHosts, this.question, {this.onAdopted, this.team});

  final KnownHostsService knownHosts;
  final FtpsCertificateQuestion question;

  /// The host's team's pins; null for a host of a person's own space.
  final FtpsTeamPins? team;

  /// Told once when a certificate another device kept (it came with sync) is
  /// confirmed here for the first time, as a synced host key is told.
  final void Function(String host, int port, HostKeyProvenance from)? onAdopted;

  /// The connection to [host]:[port] showed [cert] and was made: the kept
  /// certificate's last seen time moves on, and a synced one is told of once
  /// ([onAdopted]).
  Future<void> connected(String host, int port, FtpsCertificate cert) async {
    final from = await knownHosts.confirmCertificate(host, port, cert.sha256);
    if (from != null) onAdopted?.call(host, port, from);
  }

  @override
  Future<String?> pinnedFor(String host, int port) async =>
      (await team?.certificatePin(host, port))?.certificateSha256 ?? await knownHosts.pinnedCertificate(host, port);

  @override
  Future<bool> ask(FtpsCertificate presented, {required String host, required int port, String? previous}) async {
    final team = this.team;
    final pinned = await team?.certificatePin(host, port);
    if (team != null && pinned != null) {
      // Not the certificate the team pinned: only someone who may edit the pin's Crate can
      // replace it, for everyone; anyone else is told who can.
      final mayReplace = await team.pins.mayPinIn(pinned.crateId);
      final crate = await team.pins.crateName(pinned.crateId);
      final yes = await question(
        host: host,
        port: port,
        certificate: presented,
        previous: pinned.fingerprint,
        teamPin: TeamPinPrompt(crateName: crate, mayChange: mayReplace, pinned: true),
      );
      if (!mayReplace) {
        throw HostKeyNotAccepted(HostKeyRefusal.pinnedOther, host: host, port: port, crate: crate, certificate: true);
      }
      if (!yes) throw HostKeyNotAccepted(HostKeyRefusal.declinedChanged, host: host, port: port, certificate: true);
      await team.pins.pinCertificate(host, port, presented.der, crateId: pinned.crateId!);
      return true;
    }
    // No pin: someone who may edit the host's Crate may pin it for everyone there.
    TeamPinPrompt? offer;
    String? crateId;
    if (team != null) {
      crateId = await team.pins.crateOfHost(team.hostId);
      if (await team.pins.mayPinIn(crateId)) {
        offer = TeamPinPrompt(crateName: await team.pins.crateName(crateId), mayChange: true, pinned: false);
      }
    }
    final before = previous == null ? null : await knownHosts.certificateInfo(host, port);
    final yes = await question(
      host: host,
      port: port,
      certificate: presented,
      previous: before?.fingerprint,
      previousTrustedAt: before?.trustedAt,
      teamPin: offer,
    );
    if (!yes) {
      throw HostKeyNotAccepted(
        previous == null ? HostKeyRefusal.declinedNew : HostKeyRefusal.declinedChanged,
        host: host,
        port: port,
        certificate: true,
      );
    }
    if (offer != null && offer.forEveryone) {
      await team!.pins.pinCertificate(host, port, presented.der, crateId: crateId!);
    }
    return true;
  }

  @override
  Future<void> remember(String host, int port, FtpsCertificate cert) =>
      knownHosts.trustCertificate(host, port, sha256Hex: cert.sha256, der: cert.der);
}

/// The session of an FTPS host: an [FtpsClient] where an SSH session has its shell. Its output
/// streams stay empty (there is no terminal); a NOOP every [keepAlive] keeps an idle connection
/// open (servers end one after a few minutes) and finds one that has gone.
class FtpsShellService implements ShellService, ShellEndReason {
  FtpsShellService({
    required this.options,
    required this.trust,
    this.native = const RustFtpsNative(),
    this.keepAlive = const Duration(seconds: 60),
    this.onLog,
  });

  final FtpsConnectOptions options;
  final FtpsTrust trust;
  final FtpsNative native;
  final Duration keepAlive;
  final void Function(String line)? onLog;

  FtpsClient? _client;
  Timer? _ticker;
  bool _ended = false;
  Future<FtpsClient>? _reconnecting;
  final _state = StreamController<bool>.broadcast();
  final _endReason = Completer<String?>();

  /// The connection, once [connect] has made it.
  FtpsClient? get client => _client;

  @override
  Future<void> connect() async {
    onLog?.call('ftps: Connecting to ${options.host}:${options.port} '
        '(${options.implicitTls ? 'implicit TLS' : 'AUTH TLS'})');
    final client = await FtpsClient.connectTrusting(options, trust, native: native);
    _client = client;
    final kept = trust;
    if (kept is KnownHostsFtpsTrust) {
      try {
        await kept.connected(options.host, options.port, client.certificate);
      } catch (e) {
        AppLogger.warning('FTPS: the kept certificate was not updated (${errorKind(e)})');
      }
    }
    onLog?.call('ftps: Signed in over TLS; certificate ${client.certificate.fingerprint}'
        '${client.certificate.byAuthority ? ' (signed by a public authority)' : ''}');
    _state.add(true);
    _ticker = Timer.periodic(keepAlive, (_) => _keepAlive());
  }

  Future<void> _keepAlive() async {
    final c = _client;
    if (c == null || _ended || _reconnecting != null) return;
    try {
      await c.noop();
    } on FtpsException catch (e) {
      // A transfer running on this connection answers busy: it is alive.
      if (e.kind == FtpsErrorKind.busy) return;
      AppLogger.info('FTPS keep-alive failed (${e.kind.name}); connecting again once');
      // Once, as the file browser does on its next action ([reconnect]); the session ends
      // only where that fails too.
      try {
        await reconnect();
      } catch (_) {
        _lost(e.message);
      }
    } catch (e) {
      _lost('$e');
    }
  }

  /// Connects again, once at a time (3.4, stage 2): a dropped connection, found by the file
  /// browser's next action or the keep-alive, is made again with the same sign-in and the same
  /// trust, so a certificate already trusted is not asked about again (a changed one is, as on
  /// any connection). The new connection takes the old one's place; the old one is closed. Not
  /// after the session was ended.
  Future<FtpsClient> reconnect() {
    if (_ended) return Future.error(const FtpsException(FtpsErrorKind.closed, 'the session has ended'));
    return _reconnecting ??= _connectAgain().whenComplete(() => _reconnecting = null);
  }

  Future<FtpsClient> _connectAgain() async {
    final old = _client;
    onLog?.call('ftps: The connection dropped; connecting again to ${options.host}:${options.port}');
    final fresh = await FtpsClient.connectTrusting(options, trust, native: native);
    if (_ended) {
      unawaited(fresh.close());
      throw const FtpsException(FtpsErrorKind.closed, 'the session has ended');
    }
    _client = fresh;
    unawaited(old?.close());
    onLog?.call('ftps: Connected again over TLS; certificate ${fresh.certificate.fingerprint}');
    return fresh;
  }

  void _lost(String why) {
    if (_ended) return;
    _ended = true;
    _ticker?.cancel();
    if (!_endReason.isCompleted) _endReason.complete(why);
    _state.add(false);
    unawaited(_client?.close());
  }

  @override
  Future<void> disconnect() async {
    _ended = true;
    _ticker?.cancel();
    if (!_endReason.isCompleted) _endReason.complete(null);
    final c = _client;
    _client = null;
    _state.add(false);
    await c?.close();
  }

  @override
  Stream<Uint8List> get stdout => const Stream.empty();

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => _client != null && !_ended;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => false;

  @override
  bool get isEncryptedSsh => false;

  @override
  Future<String?> get endReason => _endReason.future;
}

/// What is said of an FTPS connection that failed, in the person's language, with a code where
/// one helps: a server without TLS (ZS-1606) and one that does not answer in time (ZS-1607).
/// Said from its kind (and a refusal's reply code) only: what the server or the library said
/// is English, and goes to Copy details with the error, never into the sentence.
String ftpsFailureText(AppLocalizations l10n, FtpsException e) => switch (e.kind) {
  FtpsErrorKind.noTls => ErrorCodes.withCode(l10n.ftpsNoTls, ErrorCodes.ftpsNoTls),
  FtpsErrorKind.login => l10n.ftpsLoginRefused,
  FtpsErrorKind.timeout => ErrorCodes.withCode(l10n.ftpsTimedOut, ErrorCodes.ftpsTimedOut),
  FtpsErrorKind.resolve => l10n.ftpsHostNotFound,
  FtpsErrorKind.refused => l10n.ftpsRefused,
  FtpsErrorKind.connection || FtpsErrorKind.closed => l10n.ftpsConnectionLost,
  FtpsErrorKind.tls => l10n.ftpsTlsFailed,
  FtpsErrorKind.certificate => l10n.ftpsCertificateNotTrusted,
  FtpsErrorKind.reply when e.code != null => l10n.ftpsServerRefusedCode(e.code!),
  FtpsErrorKind.protocol => l10n.ftpsReplyUnreadable,
  _ => l10n.ftpsFailed,
};
