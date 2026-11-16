import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

/// A statement of the ZestSSH status service (3.0): whether the ZestSSH
/// Cloud API answered when the service asked it, and since when it has not,
/// signed with a key this app knows.
///
/// The service runs apart from the API (a Cloudflare Worker,
/// infra/status_worker). It is asked only after the app's own request to
/// the API got no answer, and nothing about the person or the device is sent
/// to it. What it says does two things. It tells three situations apart that
/// look the same from inside one device: the service is down, the service is
/// up and this network does not let the device reach it, the device is not
/// reaching the internet at all. And "down", being signed, is proof of an
/// outage: an Orchard's offline limit does not count that time against the
/// device (lib/features/orchards/rules/orchard_rules.dart).
///
/// A statement is believed only when ALL of this holds: it is well formed,
/// it is about this app's service, it is signed by one of the keys compiled
/// into the app, it does not ask to be believed for longer than an hour, and
/// its time is now, by this device's clock, give or take a few minutes. So
/// an old "down" cannot be shown again later, a statement about another
/// service is nothing, and whoever does not hold a key can say nothing at
/// all.
class CloudStatement {
  const CloudStatement({
    required this.down,
    required this.at,
    required this.until,
    required this.since,
    required this.keyId,
  });

  /// The API did not answer the service (true), or did (false).
  final bool down;

  /// When the service asked, and until when its statement may be believed,
  /// in seconds since the epoch, by the service's clock.
  final int at;
  final int until;

  /// Since when the API has been down, as far as the service knows: never
  /// later than [at], and [at] itself when it was found down this moment.
  /// 0 when it is up.
  final int since;

  /// The name of the key that signed it.
  final String keyId;

  /// What goes first in the bytes that are signed (the Worker's DOMAIN).
  static const domain = 'zestssh.status.v1';

  /// The longest a statement may ask to be believed.
  static const maxHolds = Duration(hours: 1);

  /// How far this device's clock and the service's may differ.
  static const clockSlack = Duration(minutes: 5);

  /// The longest an answer of the service is: a statement is a few hundred
  /// characters, and what a network puts in its place (the sign-in page of
  /// a guest Wi-Fi) is not read at all.
  static const maxLength = 2048;

  static final Ed25519 _ed25519 = Ed25519();

  /// The text that is signed: the fields, one to a line, after [domain].
  static String canonical({
    required String service,
    required bool down,
    required int at,
    required int until,
    required int since,
    required String keyId,
  }) =>
      [domain, service, down ? 'down' : 'up', '$at', '$until', '$since', keyId].join('\n');

  /// Reads [body] (what the service answered) and believes it only as said
  /// above: about [service], signed by one of [keys] (the name of a key to
  /// its 32 public bytes), holding at [nowSeconds]. Null for anything else,
  /// and never a failure: a statement that cannot be believed is no
  /// statement.
  static Future<CloudStatement?> read(
    String body, {
    required String service,
    required Map<String, List<int>> keys,
    required int nowSeconds,
  }) async {
    if (body.length > maxLength) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final v = decoded['v'], said = decoded['service'], state = decoded['state'];
    final at = decoded['at'], until = decoded['until'], since = decoded['since'];
    final keyId = decoded['key'], sig = decoded['sig'];
    if (v != 1) return null;
    if (said is! String || said != service) return null;
    if (state != 'up' && state != 'down') return null;
    final down = state == 'down';
    if (at is! int || until is! int || at <= 0 || until <= at) return null;
    if (until - at > maxHolds.inSeconds) return null;
    // Down is since a time no later than its own; up has no since.
    if (since is! int || since < 0) return null;
    if (down ? (since == 0 || since > at) : since != 0) return null;
    // A key the app has no public half for signs nothing it believes.
    if (keyId is! String) return null;
    final publicKey = keys[keyId];
    if (publicKey == null) return null;
    if (sig is! String) return null;
    final List<int> signature;
    try {
      signature = base64Decode(sig);
    } on FormatException {
      return null;
    }

    // Its time is now: not yet to come, and not over.
    final slack = clockSlack.inSeconds;
    if (at > nowSeconds + slack || until < nowSeconds - slack) return null;

    // (A signature or a key of the wrong length does not check out, or
    // cannot be checked at all: either way it is not believed.)
    final signed = utf8.encode(
      canonical(service: said, down: down, at: at, until: until, since: since, keyId: keyId),
    );
    final bool genuine;
    try {
      genuine = await _ed25519.verify(
        signed,
        signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
      );
    } catch (_) {
      return null;
    }
    if (!genuine) return null;
    return CloudStatement(down: down, at: at, until: until, since: since, keyId: keyId);
  }

  @override
  String toString() =>
      'CloudStatement(${down ? 'down since $since' : 'up'} at $at, believed until $until, $keyId)';
}

/// Where the status service is and which keys sign for it, as compiled into
/// the app. With no address or no key the service is not asked and nothing
/// is ever believed: the app then says what it can know by itself.
class CloudStatusConfig {
  const CloudStatusConfig({required this.url, required this.service, required this.keys});

  /// Nothing is asked.
  const CloudStatusConfig.none()
      : url = '',
        service = '',
        keys = const {};

  /// The address of the service's one question (".../v1/now").
  final String url;

  /// The host a statement must be about.
  final String service;

  /// The keys that may sign: the name of each to its 32 public bytes.
  final Map<String, List<int>> keys;

  bool get isSet => url.isNotEmpty && service.isNotEmpty && keys.isNotEmpty;
}

/// How long the status service is given to answer.
const Duration kCloudStatusTimeout = Duration(seconds: 6);

/// Asks the status service how the API stands: its statement when it gives
/// one that can be believed, null for everything else (not set up, no
/// answer, an answer that is no statement or does not check out). Nothing
/// goes with the question: no sign-in, no identifier.
Future<CloudStatement?> askCloudStatus(
  CloudStatusConfig config, {
  required http.Client client,
  required int Function() nowSeconds,
}) async {
  if (!config.isSet) return null;
  try {
    final response = await client.get(Uri.parse(config.url)).timeout(kCloudStatusTimeout);
    if (response.statusCode != 200) return null;
    return await CloudStatement.read(response.body,
        service: config.service, keys: config.keys, nowSeconds: nowSeconds());
  } catch (_) {
    return null;
  }
}
