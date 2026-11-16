// How a remote screen's VeNCrypt certificate is trusted (4.0): on first
// use, as an FTPS server's is (lib/services/ftps/ftps_session.dart), kept with
// the known hosts as a TLS certificate (x509-sha256), and for a screen reached
// through its carrier SSH host, kept for that route alone. The engine never
// trusts a certificate by itself: with the right pin it connects, otherwise it
// closes with the certificate, the session asks here, and on a yes connects
// again pinned. No authority's word counts here: a pin alone.
import 'package:zest_native/screen.dart' as engine show ScreenCertificate, ScreenTrust;
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/providers/changed_host_keys_provider.dart' show normalizeKnownHost;
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show HostKeyNotAccepted, HostKeyRefusal;

/// A certificate a VNC server showed in its VeNCrypt TLS handshake: its SHA-256
/// (64 lower-case hexadecimal digits) and the certificate itself (DER).
class ScreenCertificate {
  const ScreenCertificate({required this.sha256, required this.der, this.subject, this.notAfter});

  final String sha256;
  final List<int> der;

  /// What the question may show beside the fingerprint, when the engine gave it.
  final String? subject;
  final DateTime? notAfter;

  /// Its fingerprint as server tools print it (`openssl x509 -fingerprint -sha256`).
  String get fingerprint => KnownHostsService.certificateFingerprint(sha256);
}

/// The route a screen's certificate is kept for: the carrier's normalized
/// host and port ([carrierHost]:[carrierPort]), as a host key behind a jump
/// host is scoped; null for a screen reached directly. Two screens at
/// localhost:5900 behind two carriers are two routes.
String? screenViaScope({String? carrierHost, int? carrierPort}) =>
    carrierHost == null || carrierPort == null ? null : '${normalizeKnownHost(carrierHost)}:$carrierPort';

/// How a certificate is put to the person, as FTPS's question is: [previous]
/// is the fingerprint kept before (a changed certificate) with when it was
/// trusted, or null (a first one); [teamPin] what a team's pin adds to it.
/// True: trust it.
typedef ScreenCertificateQuestion = Future<bool> Function({
  required String host,
  required int port,
  required ScreenCertificate certificate,
  String? viaScope,
  String? previous,
  DateTime? previousTrustedAt,
  TeamPinPrompt? teamPin,
});

/// A remote screen of a team: its team's pins ([TeamHostKeys]) and the
/// screen, whose Crate's pins are the ones that count for it.
class ScreenTeamPins {
  const ScreenTeamPins(this.pins, {required this.hostId});

  final TeamHostKeys pins;
  final String hostId;

  /// The certificate the team pinned for [host]:[port] on the route
  /// [viaScope] in the screen's Crate, or null. A pin of an SSH host key at
  /// that address is no certificate's.
  Future<TeamHostKeyPin?> certificatePin(String host, int port, {String? viaScope}) async {
    final pin = await pins.pinFor(host, port, viaScope: viaScope, crateId: await pins.crateOfHost(hostId));
    return pin != null && pin.isCertificate && pin.certificateSha256 != null ? pin : null;
  }
}

/// A remote screen's certificate over the known hosts, for one route
/// ([viaScope]: the carrier's, [screenViaScope]; null when direct). The same
/// rules as FTPS's ([KnownHostsFtpsTrust]):
///
/// * the pin kept for the address, port and route connects with no question;
/// * any other is asked about through the host key queue and its dialogs
///   (in red when one was kept before), and a no ends the session as quietly
///   as a host key turned down ([HostKeyNotAccepted], `certificate: true`);
/// * a team's screen ([team]) goes by the team's pin in its Crate: another
///   certificate stops it unless this account may edit the pin's Crate, and
///   then a yes replaces the pin for everyone; with no pin, someone who may
///   edit the Crate is offered to pin it for everyone.
class KnownHostsScreenTrust {
  KnownHostsScreenTrust(this.knownHosts, this.question, {this.viaScope, this.team, this.onAdopted});

  final KnownHostsService knownHosts;
  final ScreenCertificateQuestion question;
  final String? viaScope;

  /// The screen's team's pins; null for a screen of a person's own space.
  final ScreenTeamPins? team;

  /// Told once when a certificate another device kept (it came with sync) is
  /// confirmed here for the first time, as a synced host key is told.
  final void Function(String host, int port, HostKeyProvenance from)? onAdopted;

  /// The SHA-256 the engine is to accept at [host]:[port] on this route: the
  /// team's pin, else the one kept on this device; null for none (the first
  /// handshake then closes with the certificate, to [ask] about).
  Future<String?> pinnedFor(String host, int port) async =>
      (await team?.certificatePin(host, port, viaScope: viaScope))?.certificateSha256 ??
      await knownHosts.pinnedCertificate(host, port, viaScope: viaScope);

  /// [presented] is not the pinned certificate (or none is pinned): asks, and
  /// returns true to connect again pinned to it ([remember] keeps it). Throws
  /// [HostKeyNotAccepted] on a no, or where a team's pin may not be replaced.
  Future<bool> ask(ScreenCertificate presented, {required String host, required int port}) async {
    final team = this.team;
    final pinned = await team?.certificatePin(host, port, viaScope: viaScope);
    if (team != null && pinned != null) {
      final mayReplace = await team.pins.mayPinIn(pinned.crateId);
      final crate = await team.pins.crateName(pinned.crateId);
      final yes = await question(
        host: host,
        port: port,
        certificate: presented,
        viaScope: viaScope,
        previous: pinned.fingerprint,
        teamPin: TeamPinPrompt(crateName: crate, mayChange: mayReplace, pinned: true),
      );
      if (!mayReplace) {
        throw HostKeyNotAccepted(HostKeyRefusal.pinnedOther, host: host, port: port, crate: crate, certificate: true);
      }
      if (!yes) throw HostKeyNotAccepted(HostKeyRefusal.declinedChanged, host: host, port: port, certificate: true);
      await team.pins.pinCertificate(host, port, presented.der, viaScope: viaScope, crateId: pinned.crateId!);
      return true;
    }
    TeamPinPrompt? offer;
    String? crateId;
    if (team != null) {
      crateId = await team.pins.crateOfHost(team.hostId);
      if (await team.pins.mayPinIn(crateId)) {
        offer = TeamPinPrompt(crateName: await team.pins.crateName(crateId), mayChange: true, pinned: false);
      }
    }
    final before = await knownHosts.certificateInfo(host, port, viaScope: viaScope);
    final yes = await question(
      host: host,
      port: port,
      certificate: presented,
      viaScope: viaScope,
      previous: before?.fingerprint,
      previousTrustedAt: before?.trustedAt,
      teamPin: offer,
    );
    if (!yes) {
      throw HostKeyNotAccepted(
        before == null ? HostKeyRefusal.declinedNew : HostKeyRefusal.declinedChanged,
        host: host,
        port: port,
        certificate: true,
      );
    }
    if (offer != null && offer.forEveryone) {
      await team!.pins.pinCertificate(host, port, presented.der, viaScope: viaScope, crateId: crateId!);
    }
    return true;
  }

  /// Keeps [cert] as the certificate of [host]:[port] on this route.
  Future<void> remember(String host, int port, ScreenCertificate cert) =>
      knownHosts.trustCertificate(host, port, sha256Hex: cert.sha256, der: cert.der, viaScope: viaScope);

  /// The screen connected showing [cert]: the kept certificate's last seen
  /// time moves on, and a synced one is told of once ([onAdopted]).
  Future<void> connected(String host, int port, ScreenCertificate cert) async {
    final from = await knownHosts.confirmCertificate(host, port, cert.sha256, viaScope: viaScope);
    if (from != null) onAdopted?.call(host, port, from);
  }
}

/// The engine's certificate rule ([engine.ScreenTrust]) for the screen at
/// [host]:[port] on [trust]'s route: what the session's two-pass connect
/// asks while it opens.
class ScreenRouteTrust implements engine.ScreenTrust {
  ScreenRouteTrust(this.trust, {required this.host, required this.port});

  final KnownHostsScreenTrust trust;
  final String host;
  final int port;

  /// The certificate as the known hosts keep it.
  static ScreenCertificate of(engine.ScreenCertificate shown) => ScreenCertificate(
        sha256: shown.sha256.toLowerCase(),
        der: shown.der,
        subject: shown.subject.isEmpty ? null : shown.subject,
        notAfter: shown.notAfter,
      );

  @override
  Future<String?> pinned() => trust.pinnedFor(host, port);

  @override
  Future<bool> ask(engine.ScreenCertificate presented, {String? previous}) => trust.ask(of(presented), host: host, port: port);

  @override
  Future<void> remember(engine.ScreenCertificate cert) => trust.remember(host, port, of(cert));

  /// Connected with the certificate whose SHA-256 is [sha256].
  Future<void> connected(String sha256) =>
      trust.connected(host, port, ScreenCertificate(sha256: sha256.toLowerCase(), der: const []));
}
