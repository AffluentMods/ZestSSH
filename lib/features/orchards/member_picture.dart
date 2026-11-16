import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

// A member's picture is fetched by every teammate's device that shows them, and
// where it comes from is theirs to say: from a server of their own it told that
// server each teammate's address and when they looked, with no limit on what came
// back (found in a security review). So it comes only from the sign-in
// providers' picture hosts and this service's own avatars, the list the server
// keeps too, for a server that is older. Anything else shows the initials.

/// The API's address, whose own avatars are served at `/v1/avatar/<token>`.
String get _apiBase => kZestApiBase;

/// The most of a picture that is read.
const kMaxMemberPictureBytes = 1024 * 1024;

/// The most pixels of a picture that is decoded: a small file can say it is huge.
const kMaxMemberPicturePixels = 16 * 1000 * 1000;

/// Whether [url] is where a member's picture may come from: https, on a host
/// Google's or Apple's sign-in hands out pictures from, or this service's own
/// avatars. No address with a user or a port of its own.
bool isKnownPictureAddress(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.hasPort || uri.userInfo.isNotEmpty) return false;
  final host = uri.host.toLowerCase();
  if (host.endsWith('.googleusercontent.com') || host.endsWith('.cdn-apple.com') || host.endsWith('.apple.com')) {
    return true;
  }
  final api = Uri.tryParse(_apiBase);
  return api != null && host == api.host.toLowerCase() && uri.path.startsWith('/v1/avatar/');
}

/// How the pictures are fetched: the app's client, or a test's.
@visibleForTesting
http.Client? debugMemberPictureClient;

/// What was fetched, or is being, by address: a list of members has each many
/// times over.
final _pictures = <String, Future<Uint8List?>>{};
const _keptPictures = 100;

/// When a fetch gave no picture, by address: asked again after a while (a phone
/// out of signal for a moment does not lose a teammate's face until it restarts).
final _noPictureAt = <String, DateTime>{};
const _askAgainAfter = Duration(minutes: 5);

/// The faces of one account's teams are not kept for the next: a change of profile.
void forgetMemberPictures() {
  _pictures.clear();
  _noPictureAt.clear();
}

/// The picture at [url], or null where there is none to draw: not at a known
/// address, not answered with itself (a redirect goes nowhere), longer than
/// [kMaxMemberPictureBytes], or saying it is larger than
/// [kMaxMemberPicturePixels]. Fetched once.
Future<Uint8List?> memberPicture(String url) {
  if (!isKnownPictureAddress(url)) return Future.value();
  final had = _pictures[url];
  final none = _noPictureAt[url];
  if (had != null && (none == null || DateTime.now().difference(none) < _askAgainAfter)) return had;
  if (!_pictures.containsKey(url) && _pictures.length >= _keptPictures) _pictures.remove(_pictures.keys.first);
  _noPictureAt.remove(url);
  return _pictures[url] = _fetch(url).then((picture) {
    if (picture == null) _noPictureAt[url] = DateTime.now();
    return picture;
  });
}

/// Forgets what was fetched, for tests.
@visibleForTesting
void debugForgetMemberPictures() {
  _pictures.clear();
  _noPictureAt.clear();
}

Future<Uint8List?> _fetch(String url) async {
  try {
    final request = http.Request('GET', Uri.parse(url))..followRedirects = false;
    // (The client's own limits end what does not answer, or stops.)
    final response = await (debugMemberPictureClient ?? PinnedHttpClient.client).send(request);
    if (response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      return null;
    }
    final declared = response.contentLength;
    if (declared != null && declared > kMaxMemberPictureBytes) {
      unawaited(response.stream.drain<void>().catchError((Object _) {}));
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
      if (bytes.length > kMaxMemberPictureBytes) return null;
    }
    final picture = bytes.takeBytes();
    return await _saysItIsSmall(picture) ? picture : null;
  } catch (e) {
    // No picture: the initials.
    AppLogger.debug('A member picture was not loaded: ${errorKind(e)}');
    return null;
  }
}

/// Reads the size [bytes] say they are, without decoding them.
Future<bool> _saysItIsSmall(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final ui.ImageDescriptor descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
  } finally {
    buffer.dispose();
  }
  try {
    return descriptor.width * descriptor.height <= kMaxMemberPicturePixels;
  } finally {
    descriptor.dispose();
  }
}
