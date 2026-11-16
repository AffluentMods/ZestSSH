import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:zestssh/services/sync_service.dart' show SyncException;
import 'package:zestssh/services/sync/sync_failure.dart';

/// A response whose body was read under a hard size cap.
class CappedResponse {
  final int statusCode;
  final Uint8List bodyBytes;
  final Map<String, String> headers;
  const CappedResponse(this.statusCode, this.bodyBytes, this.headers);
}

/// A client whose every answer is read under a hard [maxBytes] cap: for the
/// small answers of a server (a status, an acknowledgement), where the caller
/// uses the plain `get` and `post` of a client, which read the whole body
/// before any check of their own. The cap is checked against the advertised
/// Content-Length first, then against the running total as the body comes
/// in, so a body with a false or no length does not pass either; over it the
/// reading ends with a [SyncException] and what follows is not taken.
///
/// The client it wraps is lent: closing this one does not close it.
class CappedClient extends http.BaseClient {
  CappedClient(this._inner, this.maxBytes);

  final http.Client _inner;
  final int maxBytes;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final resp = await _inner.send(request);
    final declared = resp.contentLength;
    if (declared != null && declared > maxBytes) {
      // Let go of the body without reading it.
      unawaited(resp.stream.listen((_) {}).cancel());
      throw SyncFailure.storeTooLarge('Server answer too large ($declared bytes), refused');
    }
    var total = 0;
    final body = resp.stream.map((chunk) {
      total += chunk.length;
      if (total > maxBytes) {
        throw SyncFailure.storeTooLarge('Server answer over the $maxBytes-byte limit, refused');
      }
      return chunk;
    });
    return http.StreamedResponse(
      http.ByteStream(body),
      resp.statusCode,
      contentLength: resp.contentLength,
      request: resp.request,
      headers: resp.headers,
      isRedirect: resp.isRedirect,
      persistentConnection: resp.persistentConnection,
      reasonPhrase: resp.reasonPhrase,
    );
  }

  @override
  void close() {}
}

/// Send [request] and read its body while enforcing a hard [maxBytes] cap,
/// so a hostile or misconfigured bring-your-own store cannot OOM the client
/// with a multi-gigabyte response. The cap is checked BEFORE buffering:
/// first against the advertised Content-Length, then against the running
/// total as chunks stream in (a lying/absent Content-Length can't get past
/// the streaming check). Throws [SyncException] if the cap is exceeded.
Future<CappedResponse> sendCapped(
  http.Client client,
  http.BaseRequest request,
  int maxBytes, {
  // Hard deadline so a dead socket after a long idle can't hang the sync
  // forever. Applied to the initial send AND as a per-chunk idle timeout on
  // the streamed body, so a stalled read fails fast instead of blocking.
  Duration timeout = const Duration(seconds: 30),
}) async {
  final http.StreamedResponse resp;
  try {
    resp = await client.send(request).timeout(timeout);
  } on TimeoutException {
    throw SyncFailure.storeNoAnswerInTime('Store request timed out after ${timeout.inSeconds}s');
  }

  final declared = resp.contentLength;
  if (declared != null && declared > maxBytes) {
    throw SyncFailure.storeTooLarge('Store response too large ($declared bytes), refused');
  }

  final builder = BytesBuilder(copy: false);
  var total = 0;
  try {
    await for (final chunk in resp.stream.timeout(timeout)) {
      total += chunk.length;
      if (total > maxBytes) {
        throw SyncFailure.storeTooLarge('Store response over the $maxBytes-byte limit, refused');
      }
      builder.add(chunk);
    }
  } on TimeoutException {
    throw SyncFailure.storeNoAnswerInTime('Store response stalled for ${timeout.inSeconds}s');
  }

  return CappedResponse(resp.statusCode, builder.toBytes(), resp.headers);
}
