import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/cloud/observed_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/profiles/keychain.dart';

/// HTTP client with TLS certificate handling for the sync API.
///
/// ZestSSH Cloud presents a valid public (Cloudflare/Let's Encrypt)
/// certificate, so honest connections are validated by the system CA store
/// and never reach [HttpClient.badCertificateCallback], which fires only when
/// that validation FAILS. There every certificate is refused, whatever the
/// host.
///
/// A version before 1.7 kept the hash of a certificate it was shown on first
/// contact (trust on first use), and only ever of one that had failed the
/// system's checks: a proxy's, or an attacker's on the way. Later builds no
/// longer kept new ones, but let a certificate that failed the checks through
/// where its hash was kept, so a device that had once met an attacker went on
/// trusting them (found in a security review of the client). The
/// hashes are deleted as the app starts ([init]), and nothing is let through.
class PinnedHttpClient {
  /// Where a version before 1.7 kept certificate hashes; deleted at [init].
  static const _legacyPinsKey = 'pinned_cert_hashes';

  static const _secureStorage = oldCertificateHashesKeychain;

  /// Called as the app starts, before any request: deletes the certificate
  /// hashes a version before 1.7 kept (see the class).
  static Future<void> init() async {
    try {
      if (await _secureStorage.read(key: _legacyPinsKey) != null) {
        await _secureStorage.delete(key: _legacyPinsKey);
        AppLogger.info('Certificate hashes kept by an old build deleted');
      }
    } catch (e) {
      AppLogger.warning('Old certificate hashes not deleted: $e');
    }
  }

  static http.Client? _cachedClient;

  /// Who hears how each exchange with ZestSSH Cloud went: the status that
  /// came back, or what was thrown when nothing did. The app sets it as it
  /// starts (its CloudReachService, lib/services/cloud/cloud_reach.dart);
  /// until then, and in tests, nobody listens.
  static CloudExchangeListener? onExchange;

  /// ZestSSH Cloud's API, or the SYNC_API_BASE_URL a build names: requests
  /// to it are the ones [onExchange] hears of.
  static String get _apiBase => kZestApiBase;

  /// The HTTP client for ZestSSH Cloud: certificates validated by the system
  /// CA store alone; a standard `http.Client` where `dart:io`'s HttpClient
  /// cannot be made.
  static http.Client get client {
    if (_cachedClient != null) return _cachedClient!;

    try {
      _cachedClient = ObservedClient(
        IOClient(newHttpClient()),
        watches: (url) => isCloudExchange(url, apiBase: _apiBase),
        listener: () => onExchange,
      );
    } catch (e) {
      AppLogger.warning('HTTP client with the certificate rules unavailable: $e');
      _cachedClient = http.Client();
    }

    return _cachedClient!;
  }

  /// A new `dart:io` client with the same certificate rules as [client],
  /// for a connection [client] cannot make: the Orchards live line, a
  /// WebSocket (`WebSocket.connect(..., customClient: ...)`).
  static HttpClient newHttpClient() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..badCertificateCallback = refuseBadCertificate;

  /// A certificate that failed the system's checks: refused, whatever the
  /// host (see the class).
  static bool refuseBadCertificate(X509Certificate cert, String host, int port) {
    AppLogger.error('TLS certificate validation failed for $host:$port');
    return false;
  }

  /// Reset the cached client (for testing or config changes).
  static void reset() {
    _cachedClient?.close();
    _cachedClient = null;
  }
}
