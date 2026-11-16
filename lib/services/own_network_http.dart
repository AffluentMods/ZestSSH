/// Plain http, and where it may go.
///
/// One rule on every platform: a request that carries a credential (a WebDAV
/// password, a server token, a Prometheus login) may use plain `http://` only
/// to an address on the person's own network. Everything else is https.
///
/// A bug in 2.2.1: WebDAV sync over `http://` to a NAS worked on
/// Windows and was refused on Android. The app's rule was the same on both.
/// The phone refused because Flutter rejects EVERY http request when the
/// Android manifest forbids cleartext, and ours forbids it on purpose (so
/// that nothing in the app, a plugin or a web view can speak plain http by
/// accident). The manifest stays that strict. [withPlainHttpAllowed] lifts
/// the refusal for the one request this rule has let through, with the zone
/// value Flutter reads before it opens a connection.
library;

import 'dart:async';
import 'dart:io' show InternetAddress, InternetAddressType, SocketException;

import 'package:http/http.dart' as http;
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/type_name.dart';

/// Names that can only resolve inside a private network: none of them exists
/// in the public DNS root, so nobody outside can register one.
/// (`local` is mDNS; `home.arpa` RFC 8375; `internal` is reserved by ICANN
/// for private use; the rest are the long-standing private names RFC 6762
/// appendix G lists, which ICANN will not delegate.)
const _privateSuffixes = [
  'local',
  'localhost',
  'lan',
  'home',
  'home.arpa',
  'internal',
  'intranet',
  'private',
  'corp',
];

/// Whether [host] (a URL's host: a name or an address, no brackets) is on
/// the person's own network, where plain http is a reasonable choice:
///
///  * this device (`localhost`, 127.0.0.0/8, `::1`);
///  * a private IPv4 range (10/8, 172.16/12, 192.168/16), link-local
///    (169.254/16), or the shared range overlay networks such as Tailscale
///    hand out (100.64/10);
///  * IPv6 unique-local (`fc00::/7`) or link-local (`fe80::/10`);
///  * a name that only a private network can resolve: a single label with a
///    letter in it (`nas`), or one under a private suffix (`nas.lan`).
///
/// Anything else is treated as the public internet, including every way of
/// writing an address that is not plain dotted decimal (`2130706433`,
/// `0x7f.1`, `127.1`): a resolver may read those as any address at all.
bool isOwnNetworkHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  // A zone id (`fe80::1%eth0`) is not part of the address.
  final zone = h.indexOf('%');
  if (zone > 0) h = h.substring(0, zone);
  if (h.isEmpty) return false;

  final address = InternetAddress.tryParse(h);
  if (address != null) {
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      // Only the plain form counts. `010.0.0.1` reads as 10.0.0.1 to one
      // parser and as 8.0.0.1 (octal) to another: not worth guessing.
      return b.join('.') == h && _ownIPv4(b);
    }
    // An IPv4 address written as IPv6 (`::ffff:192.168.1.5`).
    final mapped = b.sublist(0, 10).every((x) => x == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff;
    if (mapped) return _ownIPv4(b.sublist(12));
    if (address.isLoopback) return true;
    if (b[0] & 0xfe == 0xfc) return true; // fc00::/7 unique-local
    if (b[0] == 0xfe && b[1] & 0xc0 == 0x80) return true; // fe80::/10
    return false;
  }

  // A name. Only letters, digits, hyphens and dots can be a real host name.
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (!RegExp(r'^[a-z0-9.-]+$').hasMatch(h)) return false;
  final labels = h.split('.');
  if (labels.any((l) => l.isEmpty)) return false;
  // Looks like a number in some base: a resolver may take it for an address.
  final last = labels.last;
  if (!RegExp(r'[a-z]').hasMatch(last) || last.startsWith('0x')) return false;
  if (labels.length == 1) return true;
  for (final suffix in _privateSuffixes) {
    if (h == suffix || h.endsWith('.$suffix')) return true;
  }
  return false;
}

bool _ownIPv4(List<int> b) {
  if (b[0] == 127) return true; // this device
  if (b[0] == 10) return true; // 10.0.0.0/8
  if (b[0] == 192 && b[1] == 168) return true; // 192.168.0.0/16
  if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true; // 172.16.0.0/12
  if (b[0] == 169 && b[1] == 254) return true; // link-local
  if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true; // 100.64.0.0/10
  return false;
}

/// Looks a host name up: its addresses, or none where it does not resolve.
typedef HostLookup = Future<List<InternetAddress>> Function(String host);

Future<List<InternetAddress>> _systemLookup(String host) async {
  try {
    return await InternetAddress.lookup(host);
  } on SocketException {
    // It does not resolve: nothing can be sent to it either.
    return const [];
  }
}

/// How a name is looked up before plain http goes to it ([leadsToOwnNetwork]):
/// the system's resolver. The tests put one of their own here, so that none
/// of them asks the network (test/flutter_test_config.dart).
HostLookup ownNetworkLookup = _systemLookup;

/// Whether [host] is on the person's own network by where it leads, and not
/// only by how it is written ([isOwnNetworkHost], which it must pass first).
///
/// An address is what it is. A name is looked up, and every address it has
/// must be one of the own network's: `nas` and `nas.lan` are private by
/// their text, but a search domain or a split DNS can turn `nas` into
/// `nas.example.com` somewhere on the internet, and the WebDAV password, the
/// server token or the Prometheus login then crossed the internet in clear
/// (found in a security audit). A name that resolves to nothing passes:
/// nothing is sent to it.
///
/// The request that follows asks the resolver again, so a resolver that
/// answers one thing now and another a moment later is not stopped by this:
/// that is a hostile network, on which plain http to a private address is
/// read just as well.
Future<bool> leadsToOwnNetwork(String host, {HostLookup? lookup}) async {
  if (!isOwnNetworkHost(host)) return false;
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  final zone = h.indexOf('%');
  if (InternetAddress.tryParse(zone > 0 ? h.substring(0, zone) : h) != null) return true;
  final addresses = await (lookup ?? ownNetworkLookup)(h);
  return addresses.every((a) => isOwnNetworkHost(a.address));
}

/// What a typed address means for plain http.
enum PlainHttpUse {
  /// Not plain http (https, or no scheme, which is taken as https).
  none,

  /// Plain http to an address on the person's own network: allowed, and
  /// worth a note that the password travels unencrypted there.
  ownNetwork,

  /// Plain http to anything else: refused.
  refused,
}

/// How [url], as typed, would use plain http. See [isOwnNetworkHost].
PlainHttpUse plainHttpUseOf(String? url) {
  final u = (url ?? '').trim();
  if (!u.toLowerCase().startsWith('http://')) return PlainHttpUse.none;
  final host = Uri.tryParse(u)?.host ?? '';
  return isOwnNetworkHost(host) ? PlainHttpUse.ownNetwork : PlainHttpUse.refused;
}

/// Runs [body] with plain http allowed for the requests it starts.
///
/// On Android (and wherever the platform's own policy forbids cleartext)
/// Flutter throws "Non-https connection is not supported by the platform" for
/// any `http://` URL. It first reads this zone value, so the app can allow a
/// single request without opening the whole app to cleartext in its manifest.
/// Call it only for a URL the own-network rule has accepted.
T withPlainHttpAllowed<T>(T Function() body) =>
    runZoned(body, zoneValues: const {#flutter.io.allow_http: true});

/// Where a client may send plain http.
enum PlainHttp {
  /// Only to an address on the person's own network ([isOwnNetworkHost], and
  /// for a name where it leads: [leadsToOwnNetwork]). For anything that puts
  /// a credential on the wire.
  ownNetworkOnly,

  /// Anywhere. Only for requests that put no secret on the wire (signed S3
  /// requests, a Prometheus server that asks for no login).
  anywhere,
}

/// A plain-http request to an address that is not on the person's own
/// network was refused before anything was sent.
class PlainHttpRefused implements Exception, HasTypeName {
  const PlainHttpRefused(this.url);

  final Uri url;

  /// What to tell the person, in their language.
  String get message => gl10n.plainHttpOwnNetworkOnly;

  @override
  String toString() =>
      'Plain http refused: ${url.host} is not an address on your own network. '
      'Use https://.';

  @override
  String get typeName => 'PlainHttpRefused';
}

/// An HTTP client for an address the person typed in (their NAS, their own
/// server). https goes straight through. Plain http is checked against
/// [plainHttp] on every request, on every platform, and when it passes it is
/// sent with the platform's blanket refusal lifted for that request.
class OwnNetworkHttpClient extends http.BaseClient {
  OwnNetworkHttpClient({
    http.Client? inner,
    this.plainHttp = PlainHttp.ownNetworkOnly,
    bool closeInner = true,
    HostLookup? lookup,
  })  : _inner = inner ?? http.Client(),
        _closeInner = closeInner,
        _lookup = lookup;

  final http.Client _inner;
  final bool _closeInner;
  final PlainHttp plainHttp;

  /// How a name is looked up; none: [ownNetworkLookup].
  final HostLookup? _lookup;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    if (!url.isScheme('http')) return _inner.send(request);
    if (plainHttp == PlainHttp.ownNetworkOnly && !await leadsToOwnNetwork(url.host, lookup: _lookup)) {
      throw PlainHttpRefused(url);
    }
    return withPlainHttpAllowed(() => _inner.send(request));
  }

  @override
  void close() {
    if (_closeInner) _inner.close();
  }
}
