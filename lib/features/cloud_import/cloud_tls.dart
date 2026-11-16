/// Cloud import (3.0): Proxmox usually answers with its own self-signed
/// certificate. Instead of switching checks off, the import shows that
/// certificate's SHA-256 fingerprint (as Proxmox shows it under the node's
/// System > Certificates), and only when the person confirms it matches does
/// it trust exactly that certificate, for that address, from then on.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as c;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/utils/host_address.dart';

/// A certificate the system does not trust, as shown for the person to
/// compare.
class CloudCertificate {
  const CloudCertificate({required this.sha256, required this.subject, required this.issuer, this.validUntil});

  /// `AB:CD:...`, upper-case pairs, as Proxmox shows it.
  final String sha256;
  final String subject;
  final String issuer;
  final DateTime? validUntil;
}

/// The SHA-256 fingerprint of a certificate's DER bytes, as `AB:CD:...`.
String certificateFingerprint(List<int> der) {
  final hex = c.sha256.convert(der).toString().toUpperCase();
  return [for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2)].join(':');
}

/// [typed] (a fingerprint pasted from Proxmox or `pvenode cert info`, any
/// case, with or without colons or spaces) as `AB:CD:...`, or null when it
/// is not a SHA-256 fingerprint.
String? normalizeFingerprint(String typed) {
  final hex = typed.replaceAll(RegExp(r'[\s:]'), '').toUpperCase();
  if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(hex)) return null;
  return [for (var i = 0; i < 64; i += 2) hex.substring(i, i + 2)].join(':');
}

/// Connects to [base] and returns its certificate when the system does not
/// trust it, or null when it does (nothing to confirm). Reads nothing else.
Future<CloudCertificate?> probeCertificate(Uri base, {Duration timeout = const Duration(seconds: 10)}) async {
  X509Certificate? seen;
  try {
    final socket = await SecureSocket.connect(
      base.host,
      base.port,
      timeout: timeout,
      onBadCertificate: (cert) {
        seen = cert;
        return false;
      },
    );
    socket.destroy();
    return null;
  } on HandshakeException catch (e) {
    final cert = seen;
    if (cert == null) throw CloudError(CloudErrorKind.certificate, detail: 'https://${hostWithPort(base.host, base.port)}\n$e');
    return CloudCertificate(
      sha256: certificateFingerprint(cert.der),
      subject: cert.subject,
      issuer: cert.issuer,
      validUntil: cert.endValidity,
    );
  } on SocketException catch (e) {
    throw CloudError(CloudErrorKind.offline, detail: 'https://${hostWithPort(base.host, base.port)}\n$e');
  } on TimeoutException {
    throw CloudError(CloudErrorKind.timeout, detail: 'https://${hostWithPort(base.host, base.port)}\nNo answer within ${timeout.inSeconds} seconds.');
  }
}

/// An HTTP client that, beyond the certificates the system trusts, accepts
/// exactly one more: the one with fingerprint [pinned], and only from
/// [base]'s host and port. With no pin it is an ordinary client.
http.Client pinnedCloudClient(Uri base, {String? pinned}) {
  final client = HttpClient();
  if (pinned != null) {
    client.badCertificateCallback =
        (cert, host, port) => host == base.host && port == base.port && certificateFingerprint(cert.der) == pinned;
  }
  return IOClient(client);
}
