import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/utils/type_name.dart';

/// The most an answer of ZestSSH Cloud's API may be: its answers are small.
const kMaxApiReplyBytes = 16 * 1024 * 1024;

/// The most of an answer that carries records: sync's, a team's, and whatever
/// comes from an address that is not the API (a person's own store).
const kMaxBulkReplyBytes = 128 * 1024 * 1024;

/// An answer longer than a request's cap: it was stopped there, not read
/// (ZS-1108). What a request with no limit of its own could otherwise hold in
/// memory has no end but the device's. Not an [http.ClientException]: something
/// answered, so it is not said as a service that could not be reached.
class CloudReplyTooLarge implements Exception, HasTypeName {
  const CloudReplyTooLarge(this.cap, this.url);

  final int cap;
  final Uri url;

  @override
  String toString() =>
      ErrorCodes.withCode('The answer of ${url.host} is longer than the $cap bytes it may be, and was not read.', ErrorCodes.cloudReplyTooLarge);

  @override
  String get typeName => 'CloudReplyTooLarge';
}

/// Hears how an exchange with ZestSSH Cloud went: the HTTP status that came
/// back, or what was thrown when nothing did.
typedef CloudExchangeListener = void Function(int? status, Object? error);

/// Thrown, with no request made, for an address with no host: what a request
/// is made of in a build that names no service (a community build, whose
/// SYNC_API_BASE_URL is empty: lib/config/official_identity.dart). It is a
/// [http.ClientException], so whatever takes a connection that failed takes
/// this, and nothing of the app's has to know of it to be safe.
class NoServiceInThisBuild extends http.ClientException implements Exception, HasTypeName {
  NoServiceInThisBuild(Uri url) : super('This build is set up for no service at this address', url);

  @override
  String toString() => 'This build of the app is set up for no service to ask: nothing was sent.';

  @override
  String get typeName => 'NoServiceInThisBuild';
}

/// An HTTP client that tells [listener] how each request went that
/// [watches] says is one of ZestSSH Cloud's, and is otherwise the client it
/// wraps: nothing is changed, delayed or retried, and what is thrown is
/// thrown on. Its two rules: no answer is read past a cap ([kMaxApiReplyBytes]),
/// as requests have a timeout and no limit of their own; and no request is
/// made to an address with no host ([NoServiceInThisBuild]).
///
/// Every part of the app that talks to the service does so through one
/// client (lib/services/pinned_http_client.dart), so this is the one place
/// from which the app can know how the service stands without each of those
/// parts having to say so (lib/services/cloud/cloud_reach.dart).
class ObservedClient extends http.BaseClient {
  ObservedClient(this._inner, {required this.watches, required this.listener});

  final http.Client _inner;

  /// Whether a request to this address is one to tell [listener] about.
  final bool Function(Uri url) watches;

  /// Who is told, as it stands at the moment a request ends; null while
  /// nobody listens.
  final CloudExchangeListener? Function() listener;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host.isEmpty) throw NoServiceInThisBuild(request.url);
    // A build that is not the release and was pointed at a service says so to
    // that service, so its reports and tickets can be told from the release's
    // own. The release sends nothing more than it did.
    if (!zestOfficial && watches(request.url)) {
      request.headers.putIfAbsent('X-ZestSSH-Build', () => 'community');
    }
    if (!watches(request.url)) return _capped(await _inner.send(request), request.url, kMaxBulkReplyBytes);
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (e) {
      _tell(null, e);
      rethrow;
    }
    _tell(response.statusCode, null);
    final path = request.url.path;
    return _capped(response, request.url, path.contains('/sync') || path.contains('/orchards') ? kMaxBulkReplyBytes : kMaxApiReplyBytes);
  }

  /// [response] with its body stopped at [cap] bytes, with [CloudReplyTooLarge]:
  /// at once where it says it is longer, as it comes where it says nothing.
  static http.StreamedResponse _capped(http.StreamedResponse response, Uri url, int cap) {
    final said = response.contentLength;
    if (said != null && said > cap) {
      unawaited(response.stream.listen(null).cancel());
      throw CloudReplyTooLarge(cap, url);
    }
    var seen = 0;
    final body = response.stream.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        seen += chunk.length;
        if (seen > cap) {
          sink.addError(CloudReplyTooLarge(cap, url));
          sink.close();
        } else {
          sink.add(chunk);
        }
      },
    ));
    return http.StreamedResponse(
      body,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  void _tell(int? status, Object? error) {
    try {
      listener()?.call(status, error);
    } catch (_) {
      // Whoever listens never stands between a request and its caller.
    }
  }

  @override
  void close() => _inner.close();
}

/// Whether [url] is a request to the service at [apiBase] that says
/// something about how the service stands. Its health check is left out:
/// that is the question the app asks when it wants to know, and its answer
/// is read where it is asked.
bool isCloudExchange(Uri url, {required String apiBase}) {
  final api = Uri.tryParse(apiBase);
  if (api == null || api.host.isEmpty) return false;
  if (url.host.toLowerCase() != api.host.toLowerCase()) return false;
  if (url.hasPort && api.hasPort && url.port != api.port) return false;
  return !url.path.endsWith('/health');
}
